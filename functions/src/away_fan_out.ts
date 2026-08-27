import type { Firestore } from 'firebase-admin/firestore';
import type { Message } from 'firebase-admin/messaging';

import type { PushSender } from './check_in_fan_out';

/**
 * The fan-out behind `onAwayChanged` (ARCHITECTURE.md §9, §12), with its two
 * dependencies handed in.
 *
 * ## It goes to EVERY party, which is what makes it different
 *
 * `onCheckInCreated` nudges watchers, because only a watcher acts on somebody
 * else's tap. Away is settable by **either side** — the watched person or any
 * accepted watcher — so a change made on one phone has to reach all the others,
 * *including the watched person's own device*, whose reminders are the thing
 * that must change. §9 says so in as many words: *"fan out a data-only nudge to
 * every party — all watchers and the watched device, since either may have made
 * the change."*
 *
 * ## The nudge carries no authority, and here that is load-bearing twice over
 *
 * §3: a push is *"something changed, reconcile now"* and nothing else. Losing
 * one costs latency, never correctness, because every device computes the away
 * period's end from `through` by arithmetic — §12's whole argument for there
 * being **no "away finished" message**. The original sketch had one, and losing
 * it left a watcher silent for ever, because silence is what away mode looks
 * like.
 *
 * So this function may be dropped entirely and the app still ends the away
 * period on the right day on every phone. That is the property to protect when
 * changing anything below.
 *
 * ## Whoever made the change is not told about it
 *
 * §12's notification table: away cancelled is announced to *"everyone except
 * whoever cancelled"*. They are looking at the screen they did it on. The uid
 * to skip comes from the **document**, not from the request — `setBy` is
 * rules-enforced (`setBy == request.auth.uid`, ADR-0003) and is therefore the
 * one trustworthy statement about who acted.
 *
 * On a **delete** there is no document and so no `setBy`, and nothing is
 * skipped. That is deliberate and it is the safe direction: the cost is one
 * redundant reconcile on the phone that cancelled, which §3 prices at zero,
 * while guessing wrong the other way would silently drop the nudge for somebody
 * who needs it.
 */

/** What changed at `users/{watchedUid}/shared/away`. */
export interface AwayFact {
  /** From the document path, so always present and never client-shaped. */
  readonly watchedUid: string;
  /**
   * `setBy` from the document **after** the write, or undefined when the
   * document was deleted.
   *
   * Rules-enforced to equal the writer's uid, which is what makes it usable as
   * "do not nudge this device". The name beside it is not authenticated
   * (ADR-0003) and is deliberately **not** carried: this payload is read by
   * nothing — see [messageFor].
   */
  readonly changedBy?: string;
  /** True when the document was removed rather than written. */
  readonly cleared: boolean;
}

/** One device to nudge. */
interface Recipient {
  readonly uid: string;
  readonly token: string;
}

/** Counts, for the trigger's log line and for the tests to assert on. */
export interface AwayFanOutResult {
  readonly parties: number;
  readonly tokens: number;
  readonly sent: number;
  readonly failed: number;
  readonly pruned: number;
  readonly skippedSelf: number;
  /**
   * Why the transport itself failed, if it did. Same field, same reasoning and
   * same measured cause as `FanOutResult.transportError`: *"the family were not
   * nudged"* has two completely different causes, and one line that cannot tell
   * them apart sends whoever is debugging to the wrong half of the system.
   *
   * A message, never an object — `sendEach` throws for credential and transport
   * faults, which carry no token, and a log is not the place to keep something
   * that can send a push to somebody's phone.
   */
  readonly transportError?: string;
}

const UNREGISTERED = 'messaging/registration-token-not-registered';

const SEND_BATCH_LIMIT = 500;

/**
 * A **separate** collapse key from the check-in nudge, deliberately.
 *
 * FCM keeps at most four collapse keys per offline device and drops the excess
 * unspecified. Sharing `iamok-checkin`'s key would let a burst of check-in
 * nudges collapse an away change out of the queue — and the two are not
 * interchangeable: a dropped check-in nudge costs a reconcile that the alarm
 * would do anyway at 10:00, while a dropped away nudge is the one whose absence
 * §12 spends a section on.
 *
 * One key for **all** away changes is still right, for the reason the check-in
 * key gives: a delivered nudge reconciles every link on the device rather than
 * the one named in the payload, so a later away change standing in for an
 * earlier one loses nothing at all.
 */
const COLLAPSE_KEY = 'iamok-away';

/**
 * A day, matching the check-in nudge.
 *
 * A queued away nudge that arrives later than this is about a period the
 * device's own reconcile has long since read for itself, so all it buys is a
 * wake-up on a phone that already knows.
 */
const NUDGE_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Reads what an away write left behind.
 *
 * `setBy` is taken only when it is a non-empty string. A malformed value means
 * *we do not know who did this*, which must degrade to nudging everybody rather
 * than to skipping an arbitrary device — the same direction the delete case
 * takes, for the same reason.
 */
export function awayFactFrom(
  watchedUid: string,
  after: Record<string, unknown> | undefined,
): AwayFact {
  if (after === undefined) return { watchedUid, cleared: true };
  const setBy = after['setBy'];
  return {
    watchedUid,
    changedBy:
      typeof setBy === 'string' && setBy.length > 0 ? setBy : undefined,
    cleared: false,
  };
}

/**
 * Nudges every party to [fact.watchedUid]'s away period, except whoever set it.
 *
 * Never throws for a delivery failure: one dead token must not stop the others
 * being told, and the trigger is deliberately not retried.
 */
export async function fanOutAwayChange(
  deps: { db: Firestore; sender: PushSender },
  fact: AwayFact,
): Promise<AwayFanOutResult> {
  const parties = await partyUids(deps.db, fact.watchedUid);

  // The watched person is a party to their own away period, always — even with
  // no watchers at all. Their reminders are what an away period suppresses, so
  // a watched device that is never nudged goes on asking somebody to tap three
  // times a day through a holiday a family member marked from another phone.
  const audience = parties.filter((uid) => uid !== fact.changedBy);
  const skippedSelf = parties.length - audience.length;

  if (audience.length === 0) {
    return {
      parties: parties.length,
      tokens: 0,
      sent: 0,
      failed: 0,
      pruned: 0,
      skippedSelf,
    };
  }

  const recipients = await collectTokens(deps.db, audience);
  if (recipients.length === 0) {
    return {
      parties: parties.length,
      tokens: 0,
      sent: 0,
      failed: 0,
      pruned: 0,
      skippedSelf,
    };
  }

  const { sent, failed, dead, transportError } = await send(
    deps.sender,
    recipients,
    fact,
  );
  const pruned = await pruneDeadTokens(deps.db, dead);

  return {
    parties: parties.length,
    tokens: recipients.length,
    sent,
    failed,
    pruned,
    skippedSelf,
    ...(transportError === undefined ? {} : { transportError }),
  };
}

/**
 * The watched person, plus every accepted watcher of them.
 *
 * **`status` is filtered here rather than in the query**, matching
 * `acceptedWatcherLinks`: the whole thing is then served by the automatic
 * single-field index on `watchedUid` and needs no composite index — one less
 * deploy artefact that can be missing in production and present locally.
 *
 * The filter is not an optimisation and must not be loosened. A revoked watcher
 * receiving this nudge would learn that the person they no longer watch has an
 * away period — *this specific home is empty between these dates*, which the
 * threat model rates High by inference — after the link that entitled them to
 * know it has gone.
 *
 * **The id check agrees with the rules.** `firestore.rules` authorises on the
 * document id `{watchedUid}_{watcherUid}`; a link whose id and body disagreed
 * would otherwise be nudged here about a document the rules would refuse it
 * every read of.
 */
async function partyUids(
  db: Firestore,
  watchedUid: string,
): Promise<string[]> {
  const snapshot = await db
    .collection('links')
    .where('watchedUid', '==', watchedUid)
    .get();

  const uids = new Set<string>([watchedUid]);
  for (const doc of snapshot.docs) {
    const data = doc.data();
    if (data['status'] !== 'accepted') continue;
    const watcherUid = data['watcherUid'];
    if (typeof watcherUid !== 'string' || watcherUid.length === 0) continue;
    if (doc.id !== `${watchedUid}_${watcherUid}`) continue;
    uids.add(watcherUid);
  }
  return [...uids];
}

/**
 * Every registered device of every uid in [uids].
 *
 * No token is skipped for being old and duplicates are not de-duplicated — both
 * for the reasons `collectTokens` in `check_in_fan_out.ts` sets out at length.
 * §13's watcher, the one who never opens the app, has by definition the stalest
 * token in the collection and is the reason FCM is in this design at all.
 */
async function collectTokens(
  db: Firestore,
  uids: string[],
): Promise<Recipient[]> {
  const perUid = await Promise.all(
    uids.map(async (uid) => {
      const tokens = await db.collection(`users/${uid}/tokens`).get();
      return tokens.docs.map((doc) => ({ uid, token: doc.id }));
    }),
  );
  return perUid.flat();
}

/**
 * The wire format: **data-only and high priority**, both non-negotiable.
 *
 * Data-only because a `notification` message is rendered by the system tray and
 * never reaches the app when it is closed — which is the only case FCM is here
 * for — and because it keeps every string a family reads under `lib/copy/`,
 * where the UI/UX guidelines govern it, rather than composed in a Cloud Function
 * nobody reviews for copy.
 *
 * High priority because `firebase_messaging` skips the JobScheduler hop with
 * `startService()` only for high-priority messages, and JobScheduler's
 * `readyNotDozing` gate is exactly what Phase 3 measured blocking the warning in
 * deep Doze (ADR-0008).
 *
 * **The payload says what changed about whom, and nothing the device decides
 * from.** No period, no `setByName`, no dates. `push_handler.dart` reads nothing
 * out of a message at all and `push_handler_test.dart` counts the identifier to
 * keep it that way: a forged push must not be able to move any answer, and an
 * away period is the one field where a forgery buys silence.
 */
function messageFor(recipient: Recipient, fact: AwayFact): Message {
  return {
    token: recipient.token,
    data: {
      // From the document path, so always present and always trustworthy.
      watchedUid: fact.watchedUid,
      kind: 'away',
      cleared: String(fact.cleared),
    },
    android: {
      priority: 'high',
      collapseKey: COLLAPSE_KEY,
      ttl: NUDGE_TTL_MS,
    },
  };
}

async function send(
  sender: PushSender,
  recipients: Recipient[],
  fact: AwayFact,
): Promise<{
  sent: number;
  failed: number;
  dead: Recipient[];
  transportError?: string;
}> {
  let sent = 0;
  let failed = 0;
  const dead: Recipient[] = [];
  let transportError: string | undefined;

  for (let start = 0; start < recipients.length; start += SEND_BATCH_LIMIT) {
    const batch = recipients.slice(start, start + SEND_BATCH_LIMIT);

    let response;
    try {
      response = await sender.sendEach(batch.map((r) => messageFor(r, fact)));
    } catch (error) {
      // Counted, recorded, and NOT rethrown — the counts above are still true
      // and are the diagnosis. Remaining batches are still attempted, and
      // **nothing is pruned**, because a batch that never reached FCM has told
      // us nothing about any token in it.
      failed += batch.length;
      transportError ??= error instanceof Error ? error.message : String(error);
      continue;
    }

    // Indexed rather than zipped: `BatchResponse` guarantees the responses are
    // in the order the messages went out, and that ordering is the only thing
    // tying a failure back to the document that must be pruned.
    batch.forEach((recipient, index) => {
      const result = response.responses[index];
      if (result === undefined) return;
      if (result.success) {
        sent += 1;
        return;
      }
      failed += 1;
      if (result.error?.code === UNREGISTERED) dead.push(recipient);
    });
  }

  return { sent, failed, dead, transportError };
}

/**
 * Deletes the token documents FCM reported as `UNREGISTERED`.
 *
 * **Only that code.** `messaging/invalid-argument` is the tempting second
 * candidate and it is a trap: FCM returns it for a malformed *message* too,
 * which is our own bug applied uniformly to every recipient, so pruning on it
 * would turn one bad deploy into every device in the fleet losing its push
 * registration at once.
 */
async function pruneDeadTokens(
  db: Firestore,
  dead: Recipient[],
): Promise<number> {
  const deleted = await Promise.all(
    dead.map(async (recipient) => {
      try {
        await db.doc(`users/${recipient.uid}/tokens/${recipient.token}`).delete();
        return true;
      } catch {
        return false;
      }
    }),
  );
  return deleted.filter(Boolean).length;
}
