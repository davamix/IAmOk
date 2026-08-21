/**
 * Cloud Functions for I Am Ok — ARCHITECTURE.md §9.
 *
 * Three are required and one is optional; the first of them is here.
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
 * | `onAwayChanged`   | `users/{uid}/shared/away` written    | 6     |
 * | `redeemInvite`    | callable                            | 5     |
 *
 * Deliberately absent: a scheduled "who didn't check in" function. §9 and
 * ADR-0007 record what that costs and why the escape hatch stays shut.
 */

import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { logger, setGlobalOptions } from 'firebase-functions/v2';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';

import type { PushSender } from './check_in_fan_out';
import { checkInFactFrom, fanOutCheckIn, isDayKey } from './check_in_fan_out';

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
