// Drives the ONE part of `onAwayChanged` that nothing else executes: the
// registration itself.
//
// `functions/test/away_fan_out.test.js` imports `lib/away_fan_out.js` and calls
// `fanOutAwayChange` directly against a real emulated Firestore. That covers the
// fan-out thoroughly and covers the adapter above it not at all — the
// `onDocumentWritten` binding, `event.params.uid`, and the line that turns a
// Firestore event into an `AwayFact`:
//
//     const after = event.data?.after;
//     awayFactFrom(watchedUid, after?.exists === true ? after.data() : undefined)
//
// That expression is the CANCELLATION path, which the function's own docstring
// calls the one that matters most, *"because until every device hears about it
// their family stays silent."* Until this probe existed, the first execution of
// it would have been the first deploy.
//
// ## Why this is a script and an assertion in PowerShell rather than a test
//
// Same reason as `trigger_fires_once_per_day.mjs`, which this deliberately
// mirrors: with no links seeded the only observable effect is a LOG LINE. No
// push, no FCM credentials, nothing in Firestore to read back. The script
// writes and waits; `tools/functions-test.ps1` owns the captured stdout and
// makes the assertion.
//
// ## Three writes, not two, and each is a mutation check
//
// The handover asked for two lines — one `cleared:false` and one
// `cleared:true` — because a bare count would pass if the delete had silently
// done nothing. The UPDATE in the middle is the third, and it is the case that
// distinguishes this trigger from the other one: `onCheckInCreated` is
// `onDocumentCreated` and a second write to the same document must fire
// NOTHING, while away is a fixed document id where every extension and every
// truncation IS an update. Switch this registration to `onDocumentCreated` —
// the plausible copy-paste from the file above it — and the count falls from
// three to one, with the truncation and the cancellation both silent.
//
// So the expected answer is three lines: two `cleared:false` and one
// `cleared:true`, each naming this probe's uid, which is also what proves
// `event.params.uid` reads the path rather than the body.

import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

const host = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;
if (!host) throw new Error('FIRESTORE_EMULATOR_HOST is not set');
if (!projectId?.startsWith('demo-')) {
  throw new Error(`refusing to run against project "${projectId}"`);
}

// The watched person, whose away period this is. It appears in every expected
// log line, from `event.params.uid` — the document PATH, never the body.
export const UID = 'uid-away-probe';

// Whoever set it, and deliberately NOT the watched person: `setBy` is what the
// fan-out skips, so a probe that set away as itself would exercise the
// audience-is-empty branch on every write and never the ordinary one.
const SETTER = 'uid-away-probe-watcher';

// Generous, and sized the same way as the check-in probe: a slow machine should
// produce a slow pass rather than a false fail.
const SETTLE_MS = 6000;

const settle = () => new Promise((resolve) => setTimeout(resolve, SETTLE_MS));

initializeApp({ projectId });
const db = getFirestore();
const away = db.doc(`users/${UID}/shared/away`);

// The field set `validAwayShape` requires, written in full. The rules do not
// judge an admin write, but a document shaped like something no client could
// ever write would make the fan-out's reading of it prove less than it looks.
const period = (from, through) => ({
  from,
  through,
  setBy: SETTER,
  setByName: 'Ana',
  setAt: Timestamp.fromDate(new Date(`${from}T07:00:00Z`)),
  updatedAt: Timestamp.fromDate(new Date(`${from}T07:00:00Z`)),
});

console.log('probe: setting away (a CREATE)');
await away.set(period('2026-08-21', '2026-08-28'));
await settle();

console.log('probe: truncating it (an UPDATE - onDocumentCreated would miss this)');
await away.set(period('2026-08-21', '2026-08-24'));
await settle();

console.log('probe: cancelling (a DELETE - the adapter under test)');
await away.delete();
await settle();

console.log('probe: done');
await db.terminate();
