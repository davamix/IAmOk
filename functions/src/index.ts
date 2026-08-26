/**
 * Cloud Functions for I Am Ok — ARCHITECTURE.md §9.
 *
 * Four are required and one is optional; three of them are here.
 *
 * ## Two rules that hold for every function added here
 *
 * **Functions run with admin credentials and bypass `firestore.rules` entirely.**
 * The rules are not a safety net on this side of the wire, so every function
 * re-validates its own inputs. `redeemInvite` exists *because* the client cannot
 * be trusted to enforce single-use or expiry, and must not be allowed to read
 * another user's uid out of an invite.
 *
 * **A push is a nudge, never a command** (§3). Every message these send is
 * data-only and carries no authority: "something changed, reconcile now". Losing
 * one costs latency, never correctness — which is what stops a lost "away
 * finished" message from silencing a watcher permanently (§12).
 *
 * ## What goes here, and when
 *
 * | Function          | Trigger                             | Phase |
 * |-------------------|-------------------------------------|-------|
 * | `onCheckInCreated`| `checkins/{uid}/days/{date}` created | 4     |
 * | `createInvite`    | callable                            | 5     |
 * | `redeemInvite`    | callable                            | 5     |
 * | `onAwayChanged`   | `users/{uid}/shared/away` written    | 6     |
 *
 * `createInvite` was **not in §9's original table**, and adding it is what makes
 * §9 agree with §8 rather than a new decision — §8 has always said
 * `invites/{code}` is Function-written, and the deployed rules deny every client
 * write. ADR-0011 records it.
 *
 * Deliberately absent: a scheduled "who didn't check in" function. §9 and
 * ADR-0007 record what that costs and why the escape hatch stays shut.
 */

import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { logger, setGlobalOptions } from 'firebase-functions/v2';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

import type { PushSender } from './check_in_fan_out';
import { checkInFactFrom, fanOutCheckIn, isDayKey } from './check_in_fan_out';
import {
  INVITE_ALPHABET,
  INVITE_CODE_LENGTH,
  createInviteFor,
  redeemInviteFor,
} from './invites';

/**
 * `europe-west1`, co-located with Firestore, and **not** a per-function default
 * anyone can forget.
 *
 * The region is a settled decision (§1) taken for latency, EU data residency and
 * cost, and Firestore's own location is permanent (§16). A function deployed to
 * `us-central1` — the library default — would still work and would quietly move
 * every read of an EU citizen's check-in history across the Atlantic.
 */
setGlobalOptions({ region: 'europe-west1', maxInstances: 10 });

// Once, at module load, for every function in this file. The Admin SDK picks up
// `FIRESTORE_EMULATOR_HOST` from the environment by itself, which is what lets
// the emulator suite run this code unmodified.
initializeApp();

/**
 * FCM, resolved **at the send** rather than when the fan-out is composed.
 *
 * Not a style preference. There is no FCM emulator, so `getMessaging()` is the
 * one Admin SDK service the local loop cannot satisfy — and the local loop is
 * where this function is developed. Deferring it means a check-in whose watchers
 * have no registered device never touches FCM at all, which is what makes
 * `tools/functions-test.ps1`'s trigger check a clean run with no credentials
 * anywhere rather than a run whose only signal is an authentication error.
 */
const sender: PushSender = {
  sendEach: (messages) => getMessaging().sendEach(messages),
};

/**
 * A check-in landed; nudge every accepted watcher of the person who tapped.
 *
 * ## `onDocumentCreated`, not `onDocumentWritten`, and §7 depends on it
 *
 * The document id **is** the day, so a second tap on the same day is an
 * *update* and does not fire this at all. That is where the app's
 * once-per-day-push semantics come from: no duplicate nudge, and no dedupe
 * logic anywhere in the codebase.
 *
 * ## Not retried, deliberately
 *
 * v2 triggers do not retry unless asked, and this one must not ask. A retried
 * fan-out re-sends a nudge whose only effect is a reconcile the device would
 * have done anyway at alarm time (§3), so retrying buys nothing — while a poison
 * event that fails forever would burn instances against `maxInstances` and delay
 * every *other* person's nudge. The watcher's own pull is the safety net, and it
 * is a better one than a retry queue.
 *
 * ## Everything it can fail at, it swallows
 *
 * A throw here is invisible: no screen, no user, and the only reader of the log
 * is whoever is already debugging. What matters is that a failure to *push* is
 * never allowed to look like a failure to *check in* — the check-in document is
 * already written and durable before this runs, and it is the thing the whole
 * app decides from.
 */
export const onCheckInCreated = onDocumentCreated(
  'checkins/{uid}/days/{date}',
  async (event) => {
    const watchedUid = event.params.uid;
    const date = event.params.date;

    // Both guards re-validate what the rules already require, because functions
    // bypass the rules and an admin-written document is not held to them.
    if (!isDayKey(date)) {
      logger.warn('onCheckInCreated: ignoring non-day document id', { date });
      return;
    }

    const data = event.data?.data();
    if (data === undefined) {
      logger.warn('onCheckInCreated: created event carried no data', {
        watchedUid,
        date,
      });
      return;
    }

    try {
      const result = await fanOutCheckIn(
        { db: getFirestore(), sender },
        checkInFactFrom(watchedUid, date, data),
      );
      // **One line either way, and it always carries the counts.** A transport
      // fault comes back in `transportError` rather than as a throw, precisely
      // so that "the family were not nudged" can be told apart from "nobody is
      // linked" without a second investigation — see [FanOutResult].
      const line = { watchedUid, date, ...result };
      if (result.transportError === undefined) {
        logger.info('onCheckInCreated: fanned out', line);
      } else {
        logger.warn('onCheckInCreated: fanned out, transport failed', line);
      }
    } catch (error) {
      // Only a Firestore fault reaches here now. Counts and ids only — **never
      // a token**, which is enough to send a push to somebody's phone.
      logger.error('onCheckInCreated: fan-out failed', { watchedUid, date, error });
    }
  },
);

/**
 * The uid the callable was invoked as, or a refusal.
 *
 * `request.auth` is populated by the SDK from a verified Firebase ID token, so
 * this is the one identity either callable may act on. Nothing in the request
 * body is ever read as a uid: a `watchedUid` parameter would let anybody mint an
 * invite that pairs a stranger's phone to their own.
 */
function callerUid(auth: { uid: string } | undefined): string {
  if (auth === undefined || auth.uid.length === 0) {
    throw new HttpsError('unauthenticated', 'Sign in first.');
  }
  return auth.uid;
}

/**
 * **Expected outcomes come back as results, not as thrown errors.**
 *
 * A mistyped code, an expired one, and one somebody else already used are all
 * ordinary things a person does — not faults. Returning them as a `status` field
 * on a successful call makes the client's mapping **total**: every value has a
 * case, and a new status added here is a compile-time hole on the Dart side
 * rather than an unrecognised string falling through to the wrong sentence.
 *
 * That last part is not hypothetical in this repo. `OPEN-QUESTIONS.md` #5
 * records `_mentionsAppCheck` matching an **English substring** to decide which
 * message a family is shown, with anything unrecognised falling through to a
 * claim about the device that is false — §17's fleet-wide false alarm arriving
 * through the copy layer. A status enum crossing the wire is the version of that
 * which cannot mis-parse.
 *
 * `HttpsError` is kept for the two things that genuinely are faults: no
 * identity, and a database that did not answer.
 */
export const createInvite = onCall(async (request) => {
  const watchedUid = callerUid(request.auth);
  try {
    const result = await createInviteFor(getFirestore(), watchedUid, new Date());
    if ('status' in result) {
      logger.warn('createInvite: no profile for caller', { watchedUid });
      return { status: 'watched-profile-missing' };
    }
    // The code itself is **never logged**. It is a bearer credential for the
    // duration of its life: anyone holding it can become a watcher of this
    // person, which is the link graph the threat model calls the map of who is
    // vulnerable. Counts and uids only, exactly as the fan-out logs no token.
    logger.info('createInvite: issued', { watchedUid, reused: result.reused });
    return { status: 'created', ...result };
  } catch (error) {
    // **The error's `code`, never the error.** A Firestore Admin error embeds
    // the document path, and an `ALREADY_EXISTS` from `invites.doc(code)
    // .create()` renders the colliding code — which is somebody **else's live
    // invite**, since that is why it collided. The line three above promises no
    // code is ever logged; this is what makes that true rather than nearly true.
    logger.error('createInvite: failed', {
      watchedUid,
      code: (error as { code?: unknown }).code,
    });
    throw new HttpsError('internal', 'Could not create a code.');
  }
});

/**
 * Turns a code into a link, with the caller as the **watcher** (§9).
 *
 * The caller's uid is the watcher and is never taken from the request body; the
 * watched party comes out of the invite document, which no client may read (§8).
 *
 * **On a refusal nothing but a status is returned.** On success the result
 * carries `linkId`, which is `{watchedUid}_{watcherUid}` — so a redeemer does
 * learn the watched person's uid, and has to: it is what makes
 * `checkins/{watchedUid}/days/*` readable, which is the point of the link. §9's
 * rule is that the client never learns a uid **out of an invite**, and that
 * holds: no guess, no expired code and no consumed code reveals anything.
 */
export const redeemInvite = onCall(
  {
    // **The only rate limit in the system, and it is load-bearing.**
    //
    // `setGlobalOptions` gives every function `maxInstances: 10` and the 2nd-gen
    // default `concurrency: 80` — so deployed as-is this callable would accept
    // **800 concurrent** guesses. `OPEN-QUESTIONS.md` #11 accepts the guessing
    // risk on an argument with no rate term in it (32^6 codes, single-use,
    // 24-hour life), and at 800 in flight the expected time to a first hit falls
    // *inside* one code's lifetime rather than outside it. The arithmetic was
    // right about the keyspace and silent about the throughput.
    //
    // `concurrency: 1` with `maxInstances: 3` caps sustained attempts at roughly
    // fifteen a second. That costs a family nothing — pairing is a once-per
    // relationship call and a cold start on it is invisible — and it is what
    // makes #11's acceptance true rather than nearly true. It is not a
    // substitute for App Check enforcement; it is what holds until then.
    concurrency: 1,
    maxInstances: 3,
  },
  async (request) => {
  const watcherUid = callerUid(request.auth);

  // Shape-checked here as well as on the client, because functions bypass the
  // rules and the client is untrusted by definition. A code of the wrong shape
  // cannot match a document, so this is not a security boundary — it is what
  // keeps a 4 MB request body out of a Firestore document path.
  const raw = (request.data ?? {}) as Record<string, unknown>;
  const code = typeof raw['code'] === 'string' ? raw['code'].toUpperCase() : '';
  const wellFormed =
    code.length === INVITE_CODE_LENGTH &&
    [...code].every((char) => INVITE_ALPHABET.includes(char));
  if (!wellFormed) return { status: 'unknown-code' };

  try {
    const outcome = await redeemInviteFor(
      getFirestore(),
      code,
      watcherUid,
      new Date(),
    );
    // The **outcome**, never the code: a log line naming a live code is a log
    // line anyone with access to it can pair themselves with.
    logger.info('redeemInvite: decided', {
      watcherUid,
      status: outcome.status,
      ...(outcome.status === 'linked'
        ? { linkId: outcome.linkId, alreadyLinked: outcome.alreadyLinked }
        : {}),
    });
    return outcome;
  } catch (error) {
    // The code, never the error — see `createInvite` above. The path in a
    // Firestore error here is `invites/{code}`, which is the one string on this
    // call that is a bearer credential.
    logger.error('redeemInvite: failed', {
      watcherUid,
      code: (error as { code?: unknown }).code,
    });
    throw new HttpsError('internal', 'Could not use that code.');
  }
  },
);
