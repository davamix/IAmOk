/**
 * `onAwayChanged`'s fan-out, against the **real emulated Firestore**.
 *
 * Run with `pwsh -File tools/functions-test.ps1`, which starts the emulator and
 * puts the Android Studio JBR on PATH (`java` is not on PATH on this machine).
 *
 * The database is real and the transport is a fake, for the reasons
 * `check_in_fan_out.test.js` sets out: there is no FCM emulator and never will
 * be, so `PushSender` is the seam, and the one edge that leaves — whether Google
 * delivers a well-formed message — is measured on hardware at the phase gate.
 *
 * ## What is different about this fan-out, and therefore about this file
 *
 * The check-in nudge goes to **watchers**. This one goes to **every party**,
 * including the watched person's own device, because away is settable from
 * either side and the watched device's reminders are the thing that must change.
 * Two properties follow, and they are what most of this file asserts:
 *
 * - the watched person is always in the audience, even with no watchers at all;
 * - whoever made the change is **not** told about it (§12: "everyone except
 *   whoever cancelled").
 */

const assert = require('node:assert/strict');
const { after, before, beforeEach, describe, it } = require('node:test');

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const { awayFactFrom, fanOutAwayChange } = require('../lib/away_fan_out.js');

const MUM = 'uid-mum';
const ANA = 'uid-ana';
const BETO = 'uid-beto';
const CARLA = 'uid-carla';

const UNREGISTERED = 'messaging/registration-token-not-registered';

let db;

/** The same refusal as the sibling suite, for the same reason. */
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
  await db.terminate();
});

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

const allMessages = (sender) => sender.calls.flat();

async function seedLink({ watchedUid = MUM, watcherUid, status = 'accepted' }) {
  await db.doc(`links/${watchedUid}_${watcherUid}`).set({
    watchedUid,
    watcherUid,
    status,
    watchedName: 'Mum',
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
  cleared: false,
  ...overrides,
});

describe('awayFactFrom — what the write left behind', () => {
  it('a written document carries who set it', () => {
    const result = awayFactFrom(MUM, {
      from: '2026-08-15',
      through: '2026-08-22',
      setBy: ANA,
      setByName: 'Ana',
    });
    assert.equal(result.watchedUid, MUM);
    assert.equal(result.changedBy, ANA);
    assert.equal(result.cleared, false);
  });

  it('a deleted document is cleared and names nobody', () => {
    // Reached when somebody cancels on the day the period STARTS: §12 deletes
    // rather than truncating, because `through = from - 1` would break
    // `through >= from`.
    const result = awayFactFrom(MUM, undefined);
    assert.equal(result.cleared, true);
    assert.equal(result.changedBy, undefined);
  });

  it('a malformed setBy degrades to nudging everybody', () => {
    // "We do not know who did this" must never become "skip an arbitrary
    // device". Nudging one phone redundantly costs a reconcile, which §3 prices
    // at zero; dropping the nudge for somebody who needed it costs silence.
    for (const setBy of [undefined, '', 42, null, {}]) {
      assert.equal(awayFactFrom(MUM, { setBy }).changedBy, undefined);
    }
  });
});

describe('the audience is every party, not only the watchers', () => {
  it('the watched person is nudged even with no watchers at all', async () => {
    // Their reminders are what an away period suppresses. A watched device that
    // is never nudged goes on asking somebody to tap three times a day through
    // a holiday somebody else marked.
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact({ changedBy: ANA }));

    assert.equal(result.parties, 1);
    assert.equal(result.sent, 1);
    assert.deepEqual(
      allMessages(sender).map((m) => m.token),
      ['mum-phone'],
    );
  });

  it('every accepted watcher and the watched person are nudged', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    await seedToken(BETO, 'beto-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 3);
    assert.equal(result.sent, 3);
    assert.deepEqual(
      allMessages(sender)
        .map((m) => m.token)
        .sort(),
      ['ana-phone', 'beto-phone', 'mum-phone'],
    );
  });

  it('a REVOKED watcher is not nudged', async () => {
    // An away period says a specific home is empty between two dates, which the
    // threat model rates High by inference. A revoked watcher learning it would
    // be the link graph leaking after the link is gone.
    await seedLink({ watcherUid: ANA, status: 'revoked' });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 1);
    assert.deepEqual(
      allMessages(sender).map((m) => m.token),
      ['mum-phone'],
    );
  });

  it('a status this build does not know reads as revoked', async () => {
    await seedLink({ watcherUid: ANA, status: 'pending' });
    await seedToken(ANA, 'ana-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 1, 'anything but "accepted" is not permission');
  });

  it('a link whose id disagrees with its body is not nudged', async () => {
    // `firestore.rules` authorises on the document id. A link the rules would
    // refuse every read to must not be nudged about a document it cannot read.
    await db.doc(`links/${MUM}_someone-else`).set({
      watchedUid: MUM,
      watcherUid: CARLA,
      status: 'accepted',
      watchedName: 'Mum',
      watcherName: 'Carla',
      watchedTimezone: 'Europe/Madrid',
      activeFrom: '2026-08-01',
      warningLocalTime: '10:00',
      createdAt: Timestamp.fromDate(new Date('2026-08-01T09:00:00Z')),
    });
    await seedToken(CARLA, 'carla-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 1);
    assert.equal(allMessages(sender).length, 0);
  });

  it('a watcher of somebody else is untouched', async () => {
    await seedLink({ watchedUid: 'uid-dad', watcherUid: CARLA });
    await seedToken(CARLA, 'carla-phone');
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 1);
    assert.deepEqual(
      allMessages(sender).map((m) => m.token),
      ['mum-phone'],
    );
  });
});

describe('whoever made the change is not told about it', () => {
  it('a watcher who set it is skipped; everyone else is nudged', async () => {
    await seedLink({ watcherUid: ANA });
    await seedLink({ watcherUid: BETO });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    await seedToken(BETO, 'beto-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact({ changedBy: ANA }));

    assert.equal(result.skippedSelf, 1);
    assert.deepEqual(
      allMessages(sender)
        .map((m) => m.token)
        .sort(),
      ['beto-phone', 'mum-phone'],
      'Ana is looking at the screen she did it on',
    );
  });

  it('the watched person setting her own away is skipped', async () => {
    await seedLink({ watcherUid: ANA });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact({ changedBy: MUM }));

    assert.equal(result.skippedSelf, 1);
    assert.deepEqual(
      allMessages(sender).map((m) => m.token),
      ['ana-phone'],
    );
  });

  it('a DELETE names nobody, so nobody is skipped', async () => {
    // There is no document and therefore no `setBy`. The safe direction: one
    // redundant reconcile on the phone that cancelled, rather than a dropped
    // nudge for somebody who needed it.
    await seedLink({ watcherUid: ANA });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange(
      { db, sender },
      fact({ cleared: true }),
    );

    assert.equal(result.skippedSelf, 0);
    assert.equal(result.sent, 2);
  });

  it('skipping the only party sends nothing and is not an error', async () => {
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact({ changedBy: MUM }));

    assert.equal(result.parties, 1);
    assert.equal(result.skippedSelf, 1);
    assert.equal(result.tokens, 0);
    assert.equal(sender.calls.length, 0, 'FCM is not called with nothing to say');
  });
});

describe('the wire format', () => {
  it('is data-only, high priority, and carries nothing to decide from', async () => {
    // A `notification` block is rendered by the system tray and never reaches
    // the app when it is closed, which is the only case FCM is here for. High
    // priority is what skips the JobScheduler hop Doze holds (ADR-0008).
    //
    // No period and no `setByName`: §3 says a push is a nudge and carries no
    // authority, and an away period is the one field where a forged push buys
    // SILENCE — the direction this app cannot detect in itself.
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender();

    await fanOutAwayChange({ db, sender }, fact({ cleared: true }));

    const message = allMessages(sender)[0];
    assert.equal(message.notification, undefined, 'data-only');
    assert.equal(message.android.priority, 'high');
    assert.deepEqual(message.data, {
      watchedUid: MUM,
      kind: 'away',
      cleared: 'true',
    });
    for (const value of Object.values(message.data)) {
      assert.equal(typeof value, 'string', 'FCM rejects a non-string data value');
    }
  });

  it('uses its OWN collapse key, not the check-in one', async () => {
    // FCM keeps at most four collapse keys per offline device and drops the
    // excess unspecified. Sharing a key would let a burst of check-in nudges
    // collapse an away change out of the queue, and the two are not
    // interchangeable.
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender();

    await fanOutAwayChange({ db, sender }, fact());

    assert.equal(allMessages(sender)[0].android.collapseKey, 'iamok-away');
  });
});

describe('delivery failures', () => {
  it('prunes ONLY the token FCM reported as unregistered', async () => {
    await seedLink({ watcherUid: ANA });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-dead');
    const sender = recordingSender({ 'ana-dead': UNREGISTERED });

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.pruned, 1);
    assert.equal((await db.doc(`users/${ANA}/tokens/ana-dead`).get()).exists, false);
    assert.equal((await db.doc(`users/${MUM}/tokens/mum-phone`).get()).exists, true);
  });

  it('does NOT prune on any other error code', async () => {
    // `messaging/invalid-argument` is returned for a malformed MESSAGE too,
    // which is our own bug applied to every recipient at once. Pruning on it
    // would deregister the whole fleet from one bad deploy.
    await seedToken(MUM, 'mum-phone');
    const sender = recordingSender({ 'mum-phone': 'messaging/invalid-argument' });

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.pruned, 0);
    assert.equal(result.failed, 1);
    assert.equal((await db.doc(`users/${MUM}/tokens/mum-phone`).get()).exists, true);
  });

  it('a transport fault is recorded with the counts, and prunes nothing', async () => {
    // "The family were not nudged" has two completely different causes —
    // nobody is linked, and we could not reach FCM. One line that cannot tell
    // them apart sends whoever is debugging to the wrong half of the system.
    await seedLink({ watcherUid: ANA });
    await seedToken(MUM, 'mum-phone');
    await seedToken(ANA, 'ana-phone');
    const sender = {
      calls: [],
      async sendEach() {
        throw new Error('no credentials');
      },
    };

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.parties, 2);
    assert.equal(result.tokens, 2, 'the counts above the fault are still true');
    assert.equal(result.failed, 2);
    assert.equal(result.pruned, 0, 'a batch that never reached FCM says nothing about any token');
    assert.match(result.transportError, /no credentials/);
  });

  it('every device of a party is nudged, not just one', async () => {
    await seedToken(MUM, 'mum-phone');
    await seedToken(MUM, 'mum-tablet');
    const sender = recordingSender();

    const result = await fanOutAwayChange({ db, sender }, fact());

    assert.equal(result.tokens, 2);
    assert.equal(result.sent, 2);
  });
});
