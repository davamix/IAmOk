/**
 * `createInvite` and `redeemInvite`, against the **real emulated Firestore**.
 *
 * Run with `pwsh -File tools/functions-test.ps1`, which starts the emulator and
 * puts the Android Studio JBR on PATH (`java` is not on PATH on this machine).
 *
 * ## Why the database is real here and not faked
 *
 * Everything that can be wrong about pairing is a database property: the
 * transaction that must not half-apply, the deterministic link id that makes a
 * second redemption idempotent, `create` failing on a collision, and the
 * `activeFrom` that decides which days a watcher may ever be warned about. A
 * fake would agree with whatever the code did. `docs/testing/strategy.md` puts
 * the `redeemInvite` transaction at this level by name.
 *
 * ## What this file is guarding against
 *
 * **A false claim to a family is the worst bug this app can have**, and pairing
 * is where a wrong link, a reused code, or a name attached to the wrong person
 * becomes exactly that. Every assertion below about *which* uid, *whose* zone
 * and *which* name is that risk, written down.
 *
 * CommonJS against `lib/`, for the reason `check_in_fan_out.test.js` gives: the
 * Functions emulator and Cloud Functions both load the compiled output, so a
 * test against `src/` tests something neither of them runs.
 */

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { after, before, beforeEach, describe, it } = require('node:test');

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const {
  INVITE_ALPHABET,
  INVITE_CODE_LENGTH,
  INVITE_TTL_MS,
  createInviteFor,
  dayKeyInZone,
  generateCode,
  redeemInviteFor,
} = require('../lib/invites.js');

// The same cast as the rules tests and the fan-out tests: roles live on links,
// so these are just uids.
const MUM = 'uid-mum';
const ANA = 'uid-ana';
const BETO = 'uid-beto';

const MADRID = 'Europe/Madrid';
const NOW = new Date('2026-08-26T09:00:00.000Z');

let db;

/**
 * Refuses to run unless the emulator is what we are pointed at.
 *
 * Copied deliberately from `check_in_fan_out.test.js` rather than shared: this
 * suite writes and deletes `links/` and `invites/` wholesale, and the cost of it
 * ever reaching the live project is a real family's link graph.
 */
function assertEmulator() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const projectId = process.env.GCLOUD_PROJECT;
  assert.ok(host, 'FIRESTORE_EMULATOR_HOST is not set — run tools/functions-test.ps1');
  assert.ok(
    projectId && projectId.startsWith('demo-'),
    `refusing to run against project "${projectId}" — expected a demo- project`,
  );
}

async function clear(collection) {
  const snapshot = await db.collection(collection).get();
  await Promise.all(snapshot.docs.map((doc) => doc.ref.delete()));
}

async function seedProfile(uid, displayName, timezone) {
  await db.doc(`users/${uid}`).set({
    displayName,
    timezone,
    createdAt: Timestamp.fromDate(NOW),
    lastSeenAt: Timestamp.fromDate(NOW),
  });
}

async function seedInvite(code, fields) {
  await db.doc(`invites/${code}`).set({
    watchedUid: MUM,
    createdAt: Timestamp.fromDate(NOW),
    expiresAt: Timestamp.fromMillis(NOW.getTime() + INVITE_TTL_MS),
    ...fields,
  });
}

before(async () => {
  assertEmulator();
  initializeApp();
  db = getFirestore();
});

after(async () => {
  await clear('invites');
  await clear('links');
});

beforeEach(async () => {
  await clear('invites');
  await clear('links');
  await clear('users');
  await seedProfile(MUM, 'Mum', MADRID);
  await seedProfile(ANA, 'Ana', MADRID);
  await seedProfile(BETO, 'Beto', MADRID);
});

describe('the code alphabet', () => {
  // The cross-language pin. Two copies of one alphabet in two languages is a
  // drift risk that no compiler can see, so it is asserted rather than trusted:
  // a code generated from a character the client rejects is a family reading out
  // a code their own app refuses to accept.
  it('matches lib/domain/entities/invite_code.dart character for character', () => {
    const dart = readFileSync(
      join(__dirname, '..', '..', 'lib', 'domain', 'entities', 'invite_code.dart'),
      'utf8',
    );
    const match = dart.match(/alphabet\s*=\s*'([A-Z0-9]+)'/);
    assert.ok(match, 'could not find the alphabet in invite_code.dart');
    assert.equal(match[1], INVITE_ALPHABET);

    const lengthMatch = dart.match(/int\s+length\s*=\s*(\d+)/);
    assert.ok(lengthMatch, 'could not find the code length in invite_code.dart');
    assert.equal(Number(lengthMatch[1]), INVITE_CODE_LENGTH);
  });

  it('omits exactly the four characters §7 names', () => {
    for (const banned of ['O', '0', 'I', '1']) {
      assert.ok(!INVITE_ALPHABET.includes(banned), `${banned} is in the alphabet`);
    }
  });

  // The property [generateCode]'s modulo rests on. It breaks silently the moment
  // somebody adds or removes a character, and the symptom would be a subtly
  // biased code nobody could see.
  it('has a length that divides 256, so byte % length is unbiased', () => {
    assert.equal(INVITE_ALPHABET.length, 32);
    assert.equal(256 % INVITE_ALPHABET.length, 0);
  });
});

describe('generateCode', () => {
  it('produces six characters, all from the alphabet', () => {
    for (let i = 0; i < 200; i++) {
      const code = generateCode();
      assert.equal(code.length, INVITE_CODE_LENGTH);
      for (const char of code) {
        assert.ok(INVITE_ALPHABET.includes(char), `${char} is not in the alphabet`);
      }
    }
  });

  it('maps every byte value onto the alphabet with no gaps', () => {
    // Injected randomness, so the mapping is asserted rather than sampled: byte
    // 0 and byte 255 are the two ends the modulo has to handle.
    const first = generateCode(() => Buffer.from([0, 0, 0, 0, 0, 0]));
    assert.equal(first, INVITE_ALPHABET[0].repeat(6));
    const last = generateCode(() => Buffer.from([255, 255, 255, 255, 255, 255]));
    assert.equal(last, INVITE_ALPHABET[255 % 32].repeat(6));
  });

  it('does not repeat itself across many draws', () => {
    const seen = new Set();
    for (let i = 0; i < 500; i++) seen.add(generateCode());
    // Not a randomness proof — a stuck generator is what this catches, and a
    // stuck generator is the failure that would pair every family to one code.
    assert.ok(seen.size > 490, `only ${seen.size} distinct codes in 500 draws`);
  });
});

describe('dayKeyInZone', () => {
  it('renders YYYY-MM-DD', () => {
    assert.equal(dayKeyInZone(new Date('2026-08-26T09:00:00Z'), 'UTC'), '2026-08-26');
  });

  // The whole reason `activeFrom` is computed in a named zone rather than in
  // whatever zone the server happens to be in.
  it('gives different days for two zones at the same instant', () => {
    const instant = new Date('2026-08-26T12:00:00Z');
    assert.equal(dayKeyInZone(instant, 'Pacific/Kiritimati'), '2026-08-27');
    assert.equal(dayKeyInZone(instant, 'Pacific/Niue'), '2026-08-26');
  });

  it('crosses local midnight in the named zone, not in UTC', () => {
    // 23:30 UTC is already the 27th in Madrid (UTC+2 in August).
    const instant = new Date('2026-08-26T23:30:00Z');
    assert.equal(dayKeyInZone(instant, 'UTC'), '2026-08-26');
    assert.equal(dayKeyInZone(instant, MADRID), '2026-08-27');
  });

  it('zero-pads single-digit months and days', () => {
    assert.equal(dayKeyInZone(new Date('2026-01-05T12:00:00Z'), 'UTC'), '2026-01-05');
  });

  it('returns null for a zone this runtime does not know', () => {
    assert.equal(dayKeyInZone(NOW, 'Middle/Earth'), null);
    assert.equal(dayKeyInZone(NOW, ''), null);
  });
});

describe('createInvite', () => {
  it('writes an invite owned by the caller, with a 24-hour expiry', async () => {
    const result = await createInviteFor(db, MUM, NOW);
    assert.equal(result.status, undefined, 'expected a created invite');
    assert.equal(result.reused, false);

    const doc = await db.doc(`invites/${result.code}`).get();
    assert.ok(doc.exists);
    assert.equal(doc.data().watchedUid, MUM);
    assert.equal(
      doc.data().expiresAt.toMillis() - NOW.getTime(),
      INVITE_TTL_MS,
      'the owner chose 24 hours',
    );
    assert.equal(doc.data().consumedBy, undefined);
  });

  it('refuses when the caller has no users/{uid} document', async () => {
    await db.doc(`users/${MUM}`).delete();
    const result = await createInviteFor(db, MUM, NOW);
    assert.equal(result.status, 'watched-profile-missing');
    const all = await db.collection('invites').get();
    assert.equal(all.size, 0, 'a refusal must not leave an invite behind');
  });

  it('reuses a live code rather than killing the one in use', async () => {
    const first = await createInviteFor(db, MUM, NOW);
    const second = await createInviteFor(db, MUM, new Date(NOW.getTime() + 60_000));
    assert.equal(second.code, first.code);
    assert.equal(second.reused, true);
    assert.equal(
      second.expiresAt,
      first.expiresAt,
      'reuse must not silently extend the window either',
    );
  });

  it('mints a new code once the live one has been consumed', async () => {
    const first = await createInviteFor(db, MUM, NOW);
    await db.doc(`invites/${first.code}`).update({
      consumedBy: ANA,
      consumedAt: Timestamp.fromDate(NOW),
    });
    const second = await createInviteFor(db, MUM, NOW);
    assert.notEqual(second.code, first.code);
    assert.equal(second.reused, false);
  });

  it('mints a new code once the live one has expired', async () => {
    const first = await createInviteFor(db, MUM, NOW);
    const later = new Date(NOW.getTime() + INVITE_TTL_MS + 1000);
    const second = await createInviteFor(db, MUM, later);
    assert.notEqual(second.code, first.code);
  });

  it('sweeps this caller\'s expired unconsumed invites while it is there', async () => {
    await seedInvite('AAAAAA', {
      expiresAt: Timestamp.fromMillis(NOW.getTime() - 1000),
    });
    await createInviteFor(db, MUM, NOW);
    // The sweep is fire-and-forget, so give the deletes a moment rather than
    // asserting on a race.
    await new Promise((resolve) => setTimeout(resolve, 300));
    const stale = await db.doc('invites/AAAAAA').get();
    assert.equal(stale.exists, false, 'an expired unconsumed invite is dead weight');
  });

  it('KEEPS an expired CONSUMED invite — it is the idempotence record', async () => {
    await seedInvite('BBBBBB', {
      expiresAt: Timestamp.fromMillis(NOW.getTime() - 1000),
      consumedBy: ANA,
      consumedAt: Timestamp.fromDate(NOW),
    });
    await createInviteFor(db, MUM, NOW);
    await new Promise((resolve) => setTimeout(resolve, 300));
    const kept = await db.doc('invites/BBBBBB').get();
    assert.equal(kept.exists, true, 'a retried redemption needs this to exist');
  });

  it('does not hand one person another person\'s live code', async () => {
    const mine = await createInviteFor(db, MUM, NOW);
    const theirs = await createInviteFor(db, ANA, NOW);
    assert.notEqual(theirs.code, mine.code);
    const doc = await db.doc(`invites/${theirs.code}`).get();
    assert.equal(doc.data().watchedUid, ANA);
  });
});

describe('redeemInvite', () => {
  it('creates the link, denormalising both names and the watched zone', async () => {
    await seedInvite('K7RTQX');
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);

    assert.equal(outcome.status, 'linked');
    assert.equal(outcome.linkId, `${MUM}_${ANA}`);
    assert.equal(outcome.alreadyLinked, false);
    assert.equal(outcome.watchedName, 'Mum');

    const link = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
    assert.equal(link.watchedUid, MUM);
    assert.equal(link.watcherUid, ANA);
    assert.equal(link.status, 'accepted');
    // §7: both directions, so neither party ever reads the other's users/{uid}.
    assert.equal(link.watchedName, 'Mum');
    assert.equal(link.watcherName, 'Ana', 'ADR-0005: the Tap screen names who is told');
    assert.equal(link.watchedTimezone, MADRID);
    assert.equal(link.warningLocalTime, '10:00');
  });

  it('marks the invite consumed by the redeemer', async () => {
    await seedInvite('K7RTQX');
    await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    const invite = (await db.doc('invites/K7RTQX').get()).data();
    assert.equal(invite.consumedBy, ANA);
    assert.ok(invite.consumedAt);
  });

  // The testing skill names this one: activeFrom in the WATCHED person's zone,
  // not the redeemer's. Getting it wrong westward makes the link active for a
  // day that has not happened where the watched person lives.
  it('sets activeFrom in the watched person\'s zone, not the redeemer\'s', async () => {
    await seedProfile(MUM, 'Mum', 'Pacific/Kiritimati'); // UTC+14
    await seedProfile(ANA, 'Ana', 'Pacific/Niue'); // UTC-11
    await seedInvite('K7RTQX');

    const instant = new Date('2026-08-26T12:00:00Z');
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, instant);

    assert.equal(outcome.activeFrom, '2026-08-27');
    const link = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
    assert.equal(link.activeFrom, '2026-08-27');
    assert.notEqual(link.activeFrom, '2026-08-26', "that is the redeemer's day");
  });

  it('rejects an unknown code', async () => {
    const outcome = await redeemInviteFor(db, 'ZZZZZZ', ANA, NOW);
    assert.equal(outcome.status, 'unknown-code');
    const links = await db.collection('links').get();
    assert.equal(links.size, 0);
  });

  it('rejects an expired code', async () => {
    await seedInvite('K7RTQX', {
      expiresAt: Timestamp.fromMillis(NOW.getTime() - 1),
    });
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    assert.equal(outcome.status, 'expired');
    const links = await db.collection('links').get();
    assert.equal(links.size, 0, 'an expired code must create nothing');
  });

  it('treats the expiry instant itself as expired', async () => {
    await seedInvite('K7RTQX', { expiresAt: Timestamp.fromDate(NOW) });
    assert.equal((await redeemInviteFor(db, 'K7RTQX', ANA, NOW)).status, 'expired');
  });

  it('rejects a code somebody else has already used', async () => {
    await seedInvite('K7RTQX');
    await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    const outcome = await redeemInviteFor(db, 'K7RTQX', BETO, NOW);
    assert.equal(outcome.status, 'consumed');
    const beto = await db.doc(`links/${MUM}_${BETO}`).get();
    assert.equal(beto.exists, false, 'a used code must not pair a second watcher');
  });

  // §7's idempotence, and the case the ordering of the checks exists for: a
  // client that retried after a dropped response must not be told the pairing
  // failed when it succeeded.
  it('is idempotent for the SAME watcher — a retry reports success', async () => {
    await seedInvite('K7RTQX');
    const first = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    const second = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);

    assert.equal(second.status, 'linked');
    assert.equal(second.alreadyLinked, true);
    assert.equal(second.linkId, first.linkId);
    assert.equal(second.watchedName, 'Mum');
    assert.equal(second.activeFrom, first.activeFrom);

    const links = await db.collection('links').get();
    assert.equal(links.size, 1, 'the deterministic id is what makes this one row');
  });

  it('a retry still reports success after the code has expired', async () => {
    await seedInvite('K7RTQX');
    await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    const later = new Date(NOW.getTime() + INVITE_TTL_MS + 60_000);
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, later);
    assert.equal(
      outcome.status,
      'linked',
      '"that code has expired" would be false about a pairing that happened',
    );
    assert.equal(outcome.alreadyLinked, true);
  });

  it('refuses a link to yourself', async () => {
    await seedInvite('K7RTQX');
    const outcome = await redeemInviteFor(db, 'K7RTQX', MUM, NOW);
    assert.equal(outcome.status, 'self');
    const links = await db.collection('links').get();
    assert.equal(links.size, 0);
  });

  it('refuses when the watched person has no profile', async () => {
    await seedInvite('K7RTQX');
    await db.doc(`users/${MUM}`).delete();
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    assert.equal(outcome.status, 'watched-profile-missing');
    assert.equal((await db.collection('links').get()).size, 0);
  });

  it('refuses when the REDEEMER has no profile', async () => {
    await seedInvite('K7RTQX');
    await db.doc(`users/${ANA}`).delete();
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    assert.equal(outcome.status, 'watcher-profile-missing');
    assert.equal(
      (await db.collection('links').get()).size,
      0,
      'a link with no watcherName cannot render the Tap screen (ADR-0005)',
    );
  });

  // `Link.tryWatchedZone` calls an unresolvable zone "a permanently silent
  // watcher, which is the one failure this app cannot detect in itself". Better
  // to refuse at the one moment a human is watching the screen.
  it('refuses a watched timezone this runtime cannot resolve', async () => {
    await seedProfile(MUM, 'Mum', 'Middle/Earth');
    await seedInvite('K7RTQX');
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    assert.equal(outcome.status, 'unusable-timezone');
    assert.equal((await db.collection('links').get()).size, 0);
  });

  it('rejects a malformed invite document rather than inventing a link', async () => {
    await db.doc('invites/K7RTQX').set({
      createdAt: Timestamp.fromDate(NOW),
      expiresAt: Timestamp.fromMillis(NOW.getTime() + INVITE_TTL_MS),
    });
    const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
    assert.equal(outcome.status, 'unknown-code');
    assert.equal((await db.collection('links').get()).size, 0);
  });

  it('treats a missing expiresAt as expired, never as unlimited', async () => {
    await db.doc('invites/K7RTQX').set({
      watchedUid: MUM,
      createdAt: Timestamp.fromDate(NOW),
    });
    assert.equal((await redeemInviteFor(db, 'K7RTQX', ANA, NOW)).status, 'expired');
  });

  describe('re-pairing after a revocation', () => {
    it('resets activeFrom to today so the gap is never warned about', async () => {
      await seedInvite('K7RTQX');
      await redeemInviteFor(db, 'K7RTQX', ANA, new Date('2026-08-01T09:00:00Z'));
      await db.doc(`links/${MUM}_${ANA}`).update({ status: 'revoked' });

      await seedInvite('M4PQRS');
      const outcome = await redeemInviteFor(db, 'M4PQRS', ANA, NOW);

      assert.equal(outcome.status, 'linked');
      assert.equal(outcome.activeFrom, '2026-08-26');
      const link = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
      assert.equal(link.status, 'accepted');
      assert.equal(
        link.activeFrom,
        '2026-08-26',
        'keeping the old date warns about days nobody was watching',
      );
    });

    it('preserves the watcher\'s chosen warning time and the original createdAt',
      async () => {
        await seedInvite('K7RTQX');
        await redeemInviteFor(db, 'K7RTQX', ANA, new Date('2026-08-01T09:00:00Z'));
        const original = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
        await db.doc(`links/${MUM}_${ANA}`).update({
          status: 'revoked',
          warningLocalTime: '08:30',
        });

        await seedInvite('M4PQRS');
        await redeemInviteFor(db, 'M4PQRS', ANA, NOW);

        const link = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
        assert.equal(
          link.warningLocalTime,
          '08:30',
          'resetting the hour silently moves when a family is told',
        );
        assert.equal(link.createdAt.toMillis(), original.createdAt.toMillis());
        assert.ok(link.acceptedAt.toMillis() >= NOW.getTime());
      });
  });

  // **The case a real family reaches, and the one the group above misses.**
  //
  // That group always seeds a NEW invite before re-pairing. But the old code is
  // still in the message thread it was shared in, and the consumed invite is
  // deliberately kept as the idempotence record — so re-typing it is the
  // available action, not an exotic one.
  describe('an old code after a revocation', () => {
    it('does NOT report a live pairing for a revoked link', async () => {
      await seedInvite('K7RTQX');
      await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
      await db.doc(`links/${MUM}_${ANA}`).update({ status: 'revoked' });

      const outcome = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);

      assert.notEqual(
        outcome.status,
        'linked',
        'a revoked watcher told "You are now looking after Mum" is a false ' +
          'claim: every read they make is still refused',
      );
      assert.equal(outcome.status, 'consumed');
    });

    it('and does not restore the link with a spent code', async () => {
      await seedInvite('K7RTQX');
      await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
      await db.doc(`links/${MUM}_${ANA}`).update({ status: 'revoked' });

      await redeemInviteFor(db, 'K7RTQX', ANA, NOW);

      const link = (await db.doc(`links/${MUM}_${ANA}`).get()).data();
      assert.equal(link.status, 'revoked', 'single-use means single-use');
    });

    it('a fresh code still re-pairs them — the refusal is about the CODE', async () => {
      await seedInvite('K7RTQX');
      await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
      await db.doc(`links/${MUM}_${ANA}`).update({ status: 'revoked' });

      await seedInvite('M4PQRS');
      const outcome = await redeemInviteFor(db, 'M4PQRS', ANA, NOW);

      assert.equal(outcome.status, 'linked');
      assert.equal((await db.doc(`links/${MUM}_${ANA}`).get()).data().status,
        'accepted');
    });
  });

  describe('a refusal must not burn the code', () => {
    // If a refactor ever marked the invite consumed before validating, a
    // `watcher-profile-missing` would destroy the family's only code and every
    // existing refusal test would stay green — they all assert on `links`.
    it('a refused redemption leaves the invite usable', async () => {
      await seedInvite('K7RTQX');
      await db.doc(`users/${ANA}`).delete();
      assert.equal(
        (await redeemInviteFor(db, 'K7RTQX', ANA, NOW)).status,
        'watcher-profile-missing',
      );

      await seedProfile(ANA, 'Ana', MADRID);
      assert.equal((await redeemInviteFor(db, 'K7RTQX', ANA, NOW)).status,
        'linked');
    });

    it('and leaves it unconsumed', async () => {
      await seedInvite('K7RTQX');
      await redeemInviteFor(db, 'K7RTQX', MUM, NOW); // self-link, refused
      const invite = (await db.doc('invites/K7RTQX').get()).data();
      assert.equal(invite.consumedBy, undefined);
    });
  });

  describe('single-use under contention', () => {
    // Single-use is the security claim the whole invite design rests on. The
    // transaction reads `inviteRef` first, so it should serialise — but nothing
    // proved it, and a future "fast path" read outside `runTransaction` would
    // produce two links from one code with the suite green.
    it('two watchers racing one code produce exactly ONE link', async () => {
      await seedInvite('K7RTQX');

      const outcomes = await Promise.all([
        redeemInviteFor(db, 'K7RTQX', ANA, NOW),
        redeemInviteFor(db, 'K7RTQX', BETO, NOW),
      ]);

      assert.deepEqual(
        outcomes.map((o) => o.status).sort(),
        ['consumed', 'linked'],
      );
      assert.equal((await db.collection('links').get()).size, 1);
    });
  });

  describe('the collision retry', () => {
    // `MAX_CODE_ATTEMPTS` and the injectable `randomBytes` exist for this, and
    // nothing exercised it. The file header claims the retry is exercised.
    it('mints a second code when the first one is taken', async () => {
      await seedInvite('AAAAAA');

      // Byte 0 maps to alphabet[0] = 'A', so the first draw collides.
      let draw = 0;
      const randomBytes = () =>
        Buffer.from(draw++ === 0 ? [0, 0, 0, 0, 0, 0] : [1, 1, 1, 1, 1, 1]);

      const result = await createInviteFor(db, ANA, NOW, randomBytes);

      assert.equal(result.status, undefined, 'expected a created invite');
      assert.notEqual(result.code, 'AAAAAA');
      assert.equal(result.code, INVITE_ALPHABET[1].repeat(6));
      assert.equal(draw, 2, 'exactly one retry');
    });

    it('gives up rather than looping for ever', async () => {
      // Every draw collides with a seeded invite.
      await seedInvite('AAAAAA');
      const randomBytes = () => Buffer.from([0, 0, 0, 0, 0, 0]);
      await assert.rejects(() => createInviteFor(db, ANA, NOW, randomBytes));
    });
  });

  describe('several watchers of one person', () => {
    it('each needs their own code, and each gets their own link', async () => {
      await seedInvite('K7RTQX');
      await seedInvite('M4PQRS');
      const one = await redeemInviteFor(db, 'K7RTQX', ANA, NOW);
      const two = await redeemInviteFor(db, 'M4PQRS', BETO, NOW);

      assert.equal(one.linkId, `${MUM}_${ANA}`);
      assert.equal(two.linkId, `${MUM}_${BETO}`);
      assert.equal((await db.collection('links').get()).size, 2);
    });
  });
});
