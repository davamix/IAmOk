/**
 * `onCheckInCreated`'s fan-out, against the **real emulated Firestore**.
 *
 * Run with `pwsh -File tools/functions-test.ps1`, which starts the emulator and
 * puts the Android Studio JBR on PATH (`java` is not on PATH on this machine).
 *
 * ## What is real here and what is not
 *
 * The **database is real** — the Admin SDK talking to the Firestore emulator, so
 * the link query, the `status` filter, the per-watcher token reads and the
 * `UNREGISTERED` deletes are exercised as they will run in production, including
 * the indexes they need. That is the half that can be wrong in a way no fake
 * would reveal.
 *
 * The **transport is a fake**, because there is no FCM emulator and never will
 * be. `PushSender` exists for exactly this reason. What that leaves untested is
 * one edge — whether Google delivers a well-formed message — and that edge is
 * measured on hardware at the phase gate, in deep Doze, rather than asserted
 * here.
 *
 * ## Why CommonJS, and why against `lib/` rather than `src/`
 *
 * The Functions emulator and Cloud Functions both load the **compiled output**,
 * so a test against `src/` would be testing something neither of them runs.
 * `functions/package.json` has no `"type": "module"`, so `.js` here is CommonJS,
 * which is what `tsc` emits — no interop guesswork in either direction.
 */

const assert = require('node:assert/strict');
const { after, before, beforeEach, describe, it } = require('node:test');

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const {
  checkInFactFrom,
  fanOutCheckIn,
  isDayKey,
} = require('../lib/check_in_fan_out.js');

// The same cast as the rules tests, for the same reason: roles live on links,
// so these are just uids and who is watched is a property of the link.
const MUM = 'uid-mum';
const ANA = 'uid-ana';
const BETO = 'uid-beto';
const CARLA = 'uid-carla';

const DAY = '2026-08-21';

const UNREGISTERED = 'messaging/registration-token-not-registered';

let db;

/**
 * Refuses to run unless the emulator is what we are pointed at.
 *
 * Belt and braces, and both halves earn their place. `FIRESTORE_EMULATOR_HOST`
 * is what actually routes the Admin SDK; the `demo-` project id is what the
 * Firebase tooling treats as guaranteed-offline. This suite writes and *deletes*
 * documents wholesale, so the cost of it ever reaching the live project is
 * losing real check-in history.
 */
function assertEmulator() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const projectId = process.env.GCLOUD_PROJECT;
  assert.ok(host, 'FIRESTORE_EMULATOR_HOST is not set — run tools/functions-test.ps1');
  assert.ok(
    projectId && projectId.startsWith('demo-'),
    `refusing to run against project "${projectId}" — expected a demo- project`,
  );
  return { host, projectId };
}

before(() => {
  const { projectId } = assertEmulator();
  initializeApp({ projectId });
  db = getFirestore();
});

beforeEach(async () => {
  const { host, projectId } = assertEmulator();
  const response = await fetch(
    `http://${host}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
    { method: 'DELETE' },
  );
  assert.equal(response.status, 200, 'could not clear the emulator between tests');
});

after(async () => {
  // Without this the gRPC channel keeps the process alive past the last test and
  // `emulators:exec` waits on it until the emulator is torn down under it.
  await db.terminate();
});

/** A `PushSender` that records instead of sending, and answers as told. */
function recordingSender(outcomes = {}) {
  return {
    calls: [],
    async sendEach(messages) {
      this.calls.push(messages);
      return {
        responses: messages.map((message) => {
          const code = outcomes[message.token];
          return code === undefined
            ? { success: true, messageId: `id-${message.token}` }
            : { success: false, error: { code } };
        }),
        successCount: messages.filter((m) => outcomes[m.token] === undefined).length,
        failureCount: messages.filter((m) => outcomes[m.token] !== undefined).length,
      };
    },
  };
}

/** Every message the sender saw, flattened across batches. */
const allMessages = (sender) => sender.calls.flat();

async function seedLink({ watchedUid = MUM, watcherUid, status = 'accepted', watchedName = 'Mum' }) {
  await db.doc(`links/${watchedUid}_${watcherUid}`).set({
    watchedUid,
    watcherUid,
    status,
    watchedName,
    watcherName: watcherUid,
    watchedTimezone: 'Europe/Madrid',
    activeFrom: '2026-08-01',
    warningLocalTime: '10:00',
    createdAt: Timestamp.fromDate(new Date('2026-08-01T09:00:00Z')),
    acceptedAt: Timestamp.fromDate(new Date('2026-08-01T09:00:00Z')),
  });
}

async function seedToken(uid, token) {
  await db.doc(`users/${uid}/tokens/${token}`).set({
    platform: 'android',
    updatedAt: Timestamp.fromDate(new Date('2026-08-20T09:00:00Z')),
  });
}

const fact = (overrides = {}) => ({
  watchedUid: MUM,
  date: DAY,
  deviceTappedAt: '2026-08-21T07:12:00.000Z',
  timezone: 'Europe/Madrid',
  ...overrides,
});

describe('fanOutCheckIn — who is told', () => {
  it('nudges every device of every accepted watcher', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(ANA, 'token-ana-phone');
    await seedToken(ANA, 'token-ana-tablet');
    await seedToken(BETO, 'token-beto');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.deepEqual(result, {
      acceptedLinks: 2,
      tokens: 3,
      sent: 3,
      failed: 0,
      pruned: 0,
    });
    assert.deepEqual(
      allMessages(sender).map((m) => m.token).sort(),
      ['token-ana-phone', 'token-ana-tablet', 'token-beto'],
    );
  });

  it('tells a REVOKED watcher nothing', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: CARLA, status: 'revoked' });
    await seedToken(ANA, 'token-ana');
    await seedToken(CARLA, 'token-carla');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.acceptedLinks, 1);
    assert.deepEqual(allMessages(sender).map((m) => m.token), ['token-ana']);
  });

  it('treats a status this build does not know as revoked', async () => {
    // The same direction `LinkRepository._decode` takes on the client: a status
    // a future build introduces must never be read as permission to speak about
    // somebody.
    await seedLink({ watcherUid: CARLA, status: 'pending' });
    await seedToken(CARLA, 'token-carla');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.acceptedLinks, 0);
    assert.equal(sender.calls.length, 0);
  });

  it('ignores links about somebody else', async () => {
    await seedLink({ watchedUid: 'uid-someone-else', watcherUid: ANA });
    await seedToken(ANA, 'token-ana');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.acceptedLinks, 0);
    assert.equal(sender.calls.length, 0);
  });

  it('skips a malformed link rather than failing the whole fan-out', async () => {
    await db.doc('links/broken').set({ watchedUid: MUM, status: 'accepted' });
    await seedLink({ watcherUid: ANA });
    await seedToken(ANA, 'token-ana');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.acceptedLinks, 1);
    assert.deepEqual(allMessages(sender).map((m) => m.token), ['token-ana']);
  });

  it('does not call the sender at all when nobody watches', async () => {
    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.deepEqual(result, {
      acceptedLinks: 0,
      tokens: 0,
      sent: 0,
      failed: 0,
      pruned: 0,
    });
    assert.equal(sender.calls.length, 0);
  });

  it('does not call the sender when the only watcher has no device registered', async () => {
    await seedLink({ watcherUid: ANA });

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.acceptedLinks, 1);
    assert.equal(result.tokens, 0);
    assert.equal(sender.calls.length, 0);
  });

  it('a watcher with no device does not stop the others being told', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(BETO, 'token-beto');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.sent, 1);
    assert.deepEqual(allMessages(sender).map((m) => m.token), ['token-beto']);
  });

  it('nudges the watched person when they watch themselves', async () => {
    // A self-link is what the debug harness uses to drive both roles from one
    // handset. It is not special-cased anywhere: the fan-out follows links, and
    // a link naming the same uid on both sides is an accepted link.
    await seedLink({ watchedUid: MUM, watcherUid: MUM });
    await seedToken(MUM, 'token-mum');

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.sent, 1);
    assert.deepEqual(allMessages(sender).map((m) => m.token), ['token-mum']);
  });
});

describe('fanOutCheckIn — what is sent', () => {
  it('is data-only and high priority', async () => {
    await seedLink({ watcherUid: ANA });
    await seedToken(ANA, 'token-ana');

    const sender = recordingSender();
    await fanOutCheckIn({ db, sender }, fact());
    const [message] = allMessages(sender);

    // Data-only: a `notification` block is rendered by the system tray and never
    // reaches a closed app, which is the only case FCM is here for (§3).
    assert.equal(message.notification, undefined);
    // High priority: `firebase_messaging` skips the JobScheduler hop with
    // `startService()` only for these, and that hop is what ADR-0008 measured
    // blocking the warning in deep Doze.
    assert.equal(message.android.priority, 'high');
    assert.equal(message.android.ttl, 24 * 60 * 60 * 1000);
    assert.equal(message.android.collapseKey, 'iamok-checkin');
  });

  it('carries the day, the person, and the tap as the device saw it', async () => {
    await seedLink({ watcherUid: ANA });
    await seedToken(ANA, 'token-ana');

    const sender = recordingSender();
    await fanOutCheckIn({ db, sender }, fact());
    const [message] = allMessages(sender);

    assert.deepEqual(message.data, {
      watchedUid: MUM,
      date: DAY,
      watchedName: 'Mum',
      deviceTappedAt: '2026-08-21T07:12:00.000Z',
      tz: 'Europe/Madrid',
    });
  });

  it('takes the name from each watcher’s own link', async () => {
    // §7 denormalises `watchedName` onto the link at redemption, so two watchers
    // can legitimately hold different labels for the same person. Each is told
    // the one their own link carries.
    await seedLink({ watcherUid: ANA, watchedName: 'Mum' });
    await seedLink({ watcherUid: BETO, watchedName: 'Rosa' });
    await seedToken(ANA, 'token-ana');
    await seedToken(BETO, 'token-beto');

    const sender = recordingSender();
    await fanOutCheckIn({ db, sender }, fact());

    const byToken = Object.fromEntries(
      allMessages(sender).map((m) => [m.token, m.data.watchedName]),
    );
    assert.deepEqual(byToken, { 'token-ana': 'Mum', 'token-beto': 'Rosa' });
  });

  it('omits a field it cannot read rather than sending a non-string', async () => {
    // FCM rejects a non-string data value outright, which fails the send for
    // every recipient at once. A malformed check-in document must degrade the
    // payload, never the delivery.
    await seedLink({ watcherUid: ANA });
    await seedToken(ANA, 'token-ana');

    const sender = recordingSender();
    await fanOutCheckIn(
      { db, sender },
      fact({ deviceTappedAt: undefined, timezone: undefined }),
    );
    const [message] = allMessages(sender);

    assert.deepEqual(message.data, {
      watchedUid: MUM,
      date: DAY,
      watchedName: 'Mum',
    });
    for (const value of Object.values(message.data)) {
      assert.equal(typeof value, 'string');
    }
  });

  it('sends in batches of at most 500, because sendEach throws above that', async () => {
    await seedLink({ watcherUid: ANA });
    const tokens = Array.from({ length: 501 }, (_, i) => `token-${String(i).padStart(4, '0')}`);
    for (let start = 0; start < tokens.length; start += 400) {
      const batch = db.batch();
      for (const token of tokens.slice(start, start + 400)) {
        batch.set(db.doc(`users/${ANA}/tokens/${token}`), {
          platform: 'android',
          updatedAt: Timestamp.fromDate(new Date('2026-08-20T09:00:00Z')),
        });
      }
      await batch.commit();
    }

    const sender = recordingSender();
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.tokens, 501);
    assert.equal(result.sent, 501);
    assert.deepEqual(sender.calls.map((c) => c.length), [500, 1]);
  });
});

describe('fanOutCheckIn — pruning dead tokens', () => {
  it('deletes exactly the token FCM reported UNREGISTERED', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(ANA, 'token-dead');
    await seedToken(ANA, 'token-live');
    await seedToken(BETO, 'token-beto');

    const sender = recordingSender({ 'token-dead': UNREGISTERED });
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.failed, 1);
    assert.equal(result.pruned, 1);
    assert.equal(result.sent, 2);

    const anaTokens = await db.collection(`users/${ANA}/tokens`).get();
    assert.deepEqual(anaTokens.docs.map((d) => d.id), ['token-live']);
    const betoTokens = await db.collection(`users/${BETO}/tokens`).get();
    assert.deepEqual(betoTokens.docs.map((d) => d.id), ['token-beto']);
  });

  it('deletes the row under the watcher it belongs to, not the first one seen', async () => {
    // The failure this guards is silencing the wrong family member. Both
    // watchers hold a token with the SAME id — a device that signed out of one
    // account and into another can leave exactly that — and only one is dead.
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(ANA, 'shared-token');
    await seedToken(BETO, 'shared-token');

    // Both messages carry the same token, so both come back UNREGISTERED and
    // both rows go. That is correct: the token really is dead, and it is
    // registered twice. What must NOT happen is one delete landing twice on the
    // same watcher and leaving the other row behind.
    const sender = recordingSender({ 'shared-token': UNREGISTERED });
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.pruned, 2);
    assert.equal((await db.collection(`users/${ANA}/tokens`).get()).size, 0);
    assert.equal((await db.collection(`users/${BETO}/tokens`).get()).size, 0);
  });

  it('prunes nothing for any other error code', async () => {
    // THE fleet-wide one. `messaging/invalid-argument` is returned both for a
    // malformed token and for a malformed message — and a malformed message is
    // our own bug, applied uniformly to every recipient. Pruning on it would
    // deregister every watcher in the fleet from one bad deploy.
    await seedLink({ watcherUid: ANA });
    await seedToken(ANA, 'token-a');
    await seedToken(ANA, 'token-b');
    await seedToken(ANA, 'token-c');

    const sender = recordingSender({
      'token-a': 'messaging/invalid-argument',
      'token-b': 'messaging/server-unavailable',
      'token-c': 'messaging/authentication-error',
    });
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.failed, 3);
    assert.equal(result.pruned, 0);
    assert.equal((await db.collection(`users/${ANA}/tokens`).get()).size, 3);
  });

  it('a failure for one watcher does not stop another being told', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(ANA, 'token-dead');
    await seedToken(BETO, 'token-beto');

    const sender = recordingSender({ 'token-dead': UNREGISTERED });
    const result = await fanOutCheckIn({ db, sender }, fact());

    assert.equal(result.sent, 1);
    assert.equal(result.failed, 1);
  });
});

describe('checkInFactFrom', () => {
  it('renders the device clock as ISO-8601, not the server clock', async () => {
    // §11's correction to HANDOVER.md, carried onto the wire: what the family is
    // shown is when the tap happened, never when the write arrived.
    const tappedAt = Timestamp.fromDate(new Date('2026-08-21T21:50:00.000Z'));
    const result = checkInFactFrom(MUM, DAY, {
      deviceTappedAt: tappedAt,
      receivedAt: Timestamp.fromDate(new Date('2026-08-22T06:00:00.000Z')),
      timezone: 'Europe/Madrid',
    });

    assert.deepEqual(result, {
      watchedUid: MUM,
      date: DAY,
      deviceTappedAt: '2026-08-21T21:50:00.000Z',
      timezone: 'Europe/Madrid',
    });
  });

  it('leaves out anything that is not the type it should be', async () => {
    const result = checkInFactFrom(MUM, DAY, {
      deviceTappedAt: 'not a timestamp',
      timezone: 42,
    });

    assert.equal(result.deviceTappedAt, undefined);
    assert.equal(result.timezone, undefined);
    assert.equal(result.watchedUid, MUM);
    assert.equal(result.date, DAY);
  });

  it('leaves out anything that is absent', async () => {
    const result = checkInFactFrom(MUM, DAY, {});
    assert.equal(result.deviceTappedAt, undefined);
    assert.equal(result.timezone, undefined);
  });
});

describe('isDayKey', () => {
  it('accepts a day label', async () => {
    assert.equal(isDayKey('2026-08-21'), true);
    assert.equal(isDayKey('1999-12-31'), true);
  });

  it('rejects anything else', async () => {
    for (const value of ['', '2026-8-21', '2026-08-21T00:00:00Z', 'today', '20260821', 'x2026-08-21', '2026-08-211']) {
      assert.equal(isDayKey(value), false, `expected "${value}" to be rejected`);
    }
  });
});
