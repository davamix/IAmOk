import type { Firestore } from 'firebase-admin/firestore';
import type { BatchResponse, Message } from 'firebase-admin/messaging';

/**
 * The fan-out behind `onCheckInCreated` (ARCHITECTURE.md §9), with its two
 * dependencies handed in.
 *
 * ## Why this is separable from the trigger at all
 *
 * **There is no FCM emulator, and there never will be** — sending a push is the
 * one thing in this project that cannot be exercised locally. Everything else
 * this function does can: the link query, the accepted/revoked filter, the token
 * collection across watchers, the payload, and the `UNREGISTERED` pruning are
 * all Firestore work, and Firestore has an emulator that the Admin SDK talks to
 * for real.
 *
 * So the transport is an interface. `functions/test/check_in_fan_out.test.js`
 * runs everything below against the **real emulated Firestore** with a recording
 * sender in place of FCM, which leaves exactly one untested edge — whether
 * Google delivers a well-formed message — and that edge is measured on hardware
 * at the phase gate rather than asserted in a unit test.
 *
 * ## A push is a nudge, never a command (§3)
 *
 * Every field below is informational. The watcher's device re-reads Firestore
 * and decides for itself; losing a message costs latency, never correctness.
 * That is not a caveat on this file, it is the licence for most of the choices
 * in it — the collapse key, the TTL, and the decision not to retry all rest on
 * it.
 */

/**
 * The slice of `admin.messaging()` this file uses.
 *
 * Structural, so the real `Messaging` satisfies it with no adapter and no cast,
 * and a fake in a test is an object with one method.
 */
export interface PushSender {
  sendEach(messages: Message[]): Promise<BatchResponse>;
}

/** What a created `checkins/{uid}/days/{date}` document says. */
export interface CheckInFact {
  /** From the document path, so always present and never client-shaped. */
  readonly watchedUid: string;
  /** The document id, which **is** the day in the watched person's zone (§7). */
  readonly date: string;
  /** The client clock at the tap, ISO-8601, or absent if unreadable. */
  readonly deviceTappedAt?: string;
  /** The watched person's IANA zone at the moment of the tap, or absent. */
  readonly timezone?: string;
}

/** One watcher device to nudge, and the link that says so. */
interface Recipient {
  readonly watcherUid: string;
  readonly token: string;
  /** Denormalised on the link (§7); the watcher may not read `users/{watchedUid}`. */
  readonly watchedName: string;
}

/**
 * `YYYY-MM-DD` — the same shape `firestore.rules` requires of the document id.
 *
 * Re-checked here even though the rules already enforce it, because functions
 * bypass the rules and an admin-written document is not held to them —
 * `tools/seed-link.ps1` writes through exactly that door, and so does anything
 * the Firebase console does. A day label no client could ever read back is not
 * worth waking a fleet of phones for.
 */
export function isDayKey(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value);
}

/**
 * Reads a created check-in document into the facts the push carries.
 *
 * **Every field out of the document body is optional here and mandatory
 * nowhere.** `watchedUid` and `date` come from the document *path*, so they are
 * structurally present; anything else is a value some client wrote, and a
 * malformed one must degrade the payload rather than the delivery — FCM rejects
 * a non-string data value outright, which would fail the send for every
 * recipient at once.
 *
 * Separated from the trigger so the shaping is testable without an emulator,
 * an event, or the Admin SDK: `docs/testing/strategy.md`'s rule is that if a
 * test needs a device — or here, a deploy — to answer a question about logic,
 * the logic is in the wrong layer.
 */
export function checkInFactFrom(
  watchedUid: string,
  date: string,
  data: Record<string, unknown>,
): CheckInFact {
  const tappedAt = data['deviceTappedAt'];
  const timezone = data['timezone'];
  return {
    watchedUid,
    date,
    // Duck-typed rather than `instanceof Timestamp`: the value crosses a module
    // boundary, and an `instanceof` that silently fails against a second copy of
    // the SDK would drop the field with no error anywhere.
    deviceTappedAt: isTimestampLike(tappedAt)
      ? tappedAt.toDate().toISOString()
      : undefined,
    timezone: typeof timezone === 'string' ? timezone : undefined,
  };
}

function isTimestampLike(value: unknown): value is { toDate(): Date } {
  return (
    typeof value === 'object' &&
    value !== null &&
    'toDate' in value &&
    typeof (value as { toDate: unknown }).toDate === 'function'
  );
}

/** Counts, for the trigger's log line and for the tests to assert on. */
export interface FanOutResult {
  readonly acceptedLinks: number;
  readonly tokens: number;
  readonly sent: number;
  readonly failed: number;
  readonly pruned: number;

  /**
   * Why the transport itself failed, if it did — credentials, a network fault,
   * a batch FCM rejected outright.
   *
   * **This field exists because of what the counts looked like without it.**
   * A `sendEach` that throws used to propagate, so the trigger logged
   * `fan-out failed` and *nothing else*: not how many watchers were found, not
   * how many devices were registered, not whether the link query had even
   * matched. Those are the whole diagnosis. "The family were not nudged" has two
   * completely different causes — **nobody is linked** and **we could not
   * reach FCM** — and one line that cannot tell them apart sends whoever is
   * debugging to the wrong half of the system. Measured on the POCO F3,
   * 2026-08-21, where the emulator has no FCM credentials by construction and
   * the failure was the expected outcome.
   *
   * A message, never an object: `sendEach` throws for credential and transport
   * faults, which carry no token — per-token verdicts arrive in `responses`,
   * not as a throw — and a log is not the place to keep something that can send
   * a push to somebody's phone.
   */
  readonly transportError?: string;
}

/**
 * The only error code that means *this token is dead*.
 *
 * **Nothing else may delete a token, and the reason is a fleet-wide one.**
 * `messaging/invalid-argument` is the tempting second candidate and it is a
 * trap: FCM returns it both for a malformed token and for a malformed
 * *message*, and a malformed message is our own bug applied uniformly to every
 * recipient. Pruning on it would turn one bad deploy into every watcher in the
 * fleet losing their push registration at once — silently, since nothing on any
 * device says a token was removed. Everything transient (`unavailable`, quota,
 * auth) must obviously be left alone too.
 *
 * The cost of being wrong the other way is a stale row that gets sent to and
 * ignored, forever, at no charge.
 */
const UNREGISTERED = 'messaging/registration-token-not-registered';

/** `sendEach` throws above this, which would fail the whole fan-out. */
const SEND_BATCH_LIMIT = 500;

/**
 * One collapse key for **every** check-in nudge in the app, deliberately.
 *
 * FCM collapses only messages still queued for a device that is offline, and
 * keeps at most four collapse keys per device — beyond that it drops keys, and
 * which ones is unspecified. Keying per watched person would spend one slot each
 * and let a watcher with five relatives lose a nudge.
 *
 * A single key spends one slot and can never drop anything, because a delivered
 * nudge reconciles **all** of this device's links rather than the one named in
 * the payload — the same rule `warningAlarmCallback` follows for the alarm it
 * was armed for. So a nudge about Mum standing in for one about Dad loses
 * nothing at all: the device asks Firestore about both.
 */
const COLLAPSE_KEY = 'iamok-checkin';

/**
 * A day, past which a queued nudge is not worth waking a phone for.
 *
 * The default is four weeks. A nudge that arrives that late is about a day long
 * since settled by the watcher's own alarm-time read, so all it buys is a
 * wake-up on a phone that already knows. Short enough to matter, long enough to
 * cover an ordinary night with no signal.
 */
const NUDGE_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Nudges every accepted watcher of [fact.watchedUid] that a check-in landed.
 *
 * Never throws for a delivery failure — a watcher whose token is dead must not
 * stop the others being told, and the trigger is deliberately not retried.
 */
export async function fanOutCheckIn(
  deps: { db: Firestore; sender: PushSender },
  fact: CheckInFact,
): Promise<FanOutResult> {
  const links = await acceptedWatcherLinks(deps.db, fact.watchedUid);
  if (links.length === 0) {
    return { acceptedLinks: 0, tokens: 0, sent: 0, failed: 0, pruned: 0 };
  }

  const recipients = await collectTokens(deps.db, links);
  if (recipients.length === 0) {
    return { acceptedLinks: links.length, tokens: 0, sent: 0, failed: 0, pruned: 0 };
  }

  const { sent, failed, dead, transportError } =
    await send(deps.sender, recipients, fact);
  const pruned = await pruneDeadTokens(deps.db, dead);

  return {
    acceptedLinks: links.length,
    tokens: recipients.length,
    sent,
    failed,
    pruned,
    ...(transportError === undefined ? {} : { transportError }),
  };
}

/** A watcher named by an accepted link, with the name that link carries. */
interface WatcherLink {
  readonly watcherUid: string;
  readonly watchedName: string;
}

/**
 * The accepted links naming [watchedUid] as the watched party.
 *
 * **`status` is filtered here rather than in the query**, so the whole thing is
 * served by the automatic single-field index on `watchedUid` and needs no
 * composite index — one less deploy artefact that can be missing in production
 * and present locally. The filter itself is not an optimisation and must not be
 * loosened: a revoked watcher receiving a push would be told the name of the
 * person they no longer watch and the day they were verified alive, which is the
 * link graph leaking after the link is gone.
 *
 * Anything that is not exactly `"accepted"` reads as revoked, matching
 * `LinkRepository._decode` on the client: a status this build does not know must
 * never be treated as permission to speak about somebody.
 */
async function acceptedWatcherLinks(
  db: Firestore,
  watchedUid: string,
): Promise<WatcherLink[]> {
  const snapshot = await db
    .collection('links')
    .where('watchedUid', '==', watchedUid)
    .get();

  const accepted: WatcherLink[] = [];
  for (const doc of snapshot.docs) {
    const data = doc.data();
    if (data['status'] !== 'accepted') continue;
    const watcherUid = data['watcherUid'];
    if (typeof watcherUid !== 'string' || watcherUid.length === 0) continue;
    const watchedName = data['watchedName'];
    accepted.push({
      watcherUid,
      watchedName: typeof watchedName === 'string' ? watchedName : '',
    });
  }
  return accepted;
}

/**
 * Every registered device of every watcher in [links].
 *
 * ## No token is skipped for being old, and that is a decision
 *
 * `users/{uid}/tokens/{token}.updatedAt` exists so a Function *can* prune by
 * age, and this one deliberately does not send-skip by it. §13's watcher — the
 * one who never opens the app — is the reason FCM is in this design at all, and
 * their token is by definition the stalest one in the collection. An age filter
 * would silence exactly the person it is there to reach, and would do it
 * quietly. FCM's own `UNREGISTERED` is the authority on whether a token is dead;
 * a date is a guess about it.
 *
 * ## Duplicate tokens are not de-duplicated, also deliberately
 *
 * `deleteToken` is best-effort, so a device that signed out of one account and
 * into another can leave a live token under both uids. De-duplicating would send
 * once and then know only one of the two documents to prune, leaving the other
 * stale forever. Sending twice costs one redundant reconcile, which §3 prices at
 * zero, and keeps every response mapped to the exact document that produced it.
 */
async function collectTokens(
  db: Firestore,
  links: WatcherLink[],
): Promise<Recipient[]> {
  const perLink = await Promise.all(
    links.map(async (link) => {
      const tokens = await db.collection(`users/${link.watcherUid}/tokens`).get();
      return tokens.docs.map((doc) => ({
        watcherUid: link.watcherUid,
        token: doc.id,
        watchedName: link.watchedName,
      }));
    }),
  );
  return perLink.flat();
}

/**
 * The wire format: **data-only and high priority**, and neither is negotiable.
 *
 * **Data-only** — no `notification` block — because a `notification` message is
 * rendered by the system tray and never reaches the app when it is closed, which
 * is the only case FCM is here for (§3). It is also what keeps every string a
 * family reads under `lib/copy/`, decided on the device by the code the UI/UX
 * guidelines govern, rather than composed in a Cloud Function nobody reviews for
 * copy.
 *
 * **High priority** because `firebase_messaging` skips the JobScheduler hop with
 * `startService()` only for high-priority messages, and JobScheduler's
 * `readyNotDozing` gate is precisely what Phase 3 measured blocking the warning
 * in deep Doze (ADR-0008). A normal-priority nudge would inherit the very defect
 * the Phase 4 revisit exists to escape.
 */
function messageFor(recipient: Recipient, fact: CheckInFact): Message {
  const data: Record<string, string> = {
    // From the document path, so these two are always present and always
    // trustworthy. Everything below them came out of a document body.
    watchedUid: fact.watchedUid,
    date: fact.date,
    watchedName: recipient.watchedName,
  };
  // Omitted rather than sent empty when unreadable. FCM rejects a non-string
  // data value outright, which would fail the send for every recipient — so a
  // malformed check-in document must degrade the payload, never the delivery.
  if (fact.deviceTappedAt !== undefined) {
    data['deviceTappedAt'] = fact.deviceTappedAt;
  }
  if (fact.timezone !== undefined) data['tz'] = fact.timezone;

  return {
    token: recipient.token,
    data,
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
  fact: CheckInFact,
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

    let response: BatchResponse;
    try {
      response = await sender.sendEach(batch.map((r) => messageFor(r, fact)));
    } catch (error) {
      // **Counted, recorded, and NOT rethrown.** A transport fault is a fact
      // about FCM, not about this fan-out: the counts above it are still true
      // and are the diagnosis. The remaining batches are still attempted, in
      // case the fault was specific to this one — and nothing is pruned, because
      // a batch that never reached FCM has told us nothing about any token in
      // it. That last part is the fleet-wide rule again, from the other side.
      failed += batch.length;
      transportError ??= error instanceof Error ? error.message : String(error);
      continue;
    }

    // Indexed rather than zipped because `BatchResponse` guarantees the
    // responses are in the order the messages went out, and that ordering is the
    // only thing tying a failure back to the document that must be pruned.
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
 * An uninstall is the ordinary way a token dies and nothing runs on the device
 * to clean up after it, so this is the only path that ever removes those rows.
 * Failures are swallowed per document: a delete that loses a race with the
 * device re-registering the same token must not take the rest with it, and the
 * next check-in will report it dead again anyway.
 */
async function pruneDeadTokens(
  db: Firestore,
  dead: Recipient[],
): Promise<number> {
  const deleted = await Promise.all(
    dead.map(async (recipient) => {
      try {
        await db
          .doc(`users/${recipient.watcherUid}/tokens/${recipient.token}`)
          .delete();
        return true;
      } catch {
        return false;
      }
    }),
  );
  return deleted.filter(Boolean).length;
}
