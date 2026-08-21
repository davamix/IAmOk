// Drives the ONE premise the whole no-dedupe design rests on (§7):
//
//   the check-in document id IS the day, so a second tap the same day is an
//   UPDATE, `onDocumentCreated` does not fire, and no duplicate push goes out.
//
// Nothing in the app dedupes pushes. That is not an omission — it is a claim
// about Firestore triggers, and `docs/testing/strategy.md` says to test the
// premise rather than the absence.
//
// ## Why this is a script and an assertion in PowerShell rather than a test
//
// The only observable effect of the trigger firing is a LOG LINE. With no links
// seeded there is no push, no write, and nothing in Firestore to read back —
// which is deliberate: it means this run needs no FCM credentials and cannot be
// confused by one. So the script writes, waits, and exits; the assertion lives
// in `tools/functions-test.ps1`, which owns the emulator's captured stdout.
//
// **The mutation check is built in.** The run creates day 1, updates day 1, then
// creates day 2. A grep that found the same number of lines whichever of those
// happened would prove nothing, so the expected answer is two lines with two
// different dates — one per CREATE — and the update in the middle is the case
// that must add nothing.

import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

const host = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;
if (!host) throw new Error('FIRESTORE_EMULATOR_HOST is not set');
if (!projectId?.startsWith('demo-')) {
  throw new Error(`refusing to run against project "${projectId}"`);
}

const UID = 'uid-trigger-probe';
export const DAY_ONE = '2026-08-21';
export const DAY_TWO = '2026-08-22';

// Generous. Trigger dispatch in the emulator is normally well under a second;
// this is sized so a slow machine produces a slow pass rather than a false fail.
const SETTLE_MS = 6000;

const settle = () => new Promise((resolve) => setTimeout(resolve, SETTLE_MS));

initializeApp({ projectId });
const db = getFirestore();

const checkIn = (hour) => ({
  deviceTappedAt: Timestamp.fromDate(new Date(`2026-08-21T0${hour}:00:00Z`)),
  receivedAt: Timestamp.fromDate(new Date(`2026-08-21T0${hour}:00:01Z`)),
  timezone: 'Europe/Madrid',
});

console.log('probe: creating day one');
await db.doc(`checkins/${UID}/days/${DAY_ONE}`).set(checkIn(7));
await settle();

console.log('probe: tapping again on day one (an UPDATE — must fire nothing)');
await db.doc(`checkins/${UID}/days/${DAY_ONE}`).set(checkIn(9));
await settle();

console.log('probe: creating day two');
await db.doc(`checkins/${UID}/days/${DAY_TWO}`).set(checkIn(8));
await settle();

console.log('probe: done');
await db.terminate();
