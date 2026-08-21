/**
 * Cloud Functions for I Am Ok — ARCHITECTURE.md §9.
 *
 * Three are required and one is optional; none is built yet. This file exists so
 * the **emulator suite has something to load**, which is what makes the local
 * loop complete before anything is pointed at the live project.
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
 * `onCheckInCreated` must send **high priority**, and that is not a detail:
 * `firebase_messaging` bypasses the JobScheduler hop with `startService()` only
 * for high-priority messages, and ADR-0008's revisit turns on whether a
 * background isolate can be woken inside deep Doze. A normal-priority message
 * would inherit the very defect the measurement is trying to escape.
 *
 * Deliberately absent: a scheduled "who didn't check in" function. §9 and
 * ADR-0007 record what that costs and why the escape hatch stays shut.
 */

import { setGlobalOptions } from 'firebase-functions/v2';

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
