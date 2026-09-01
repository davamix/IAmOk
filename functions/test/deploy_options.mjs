// The deploy-shaping options, asserted — no emulator, no network.
//
// `redeemInvite`'s `concurrency: 1, maxInstances: 3` is a **security control**,
// not a cost setting. `OPEN-QUESTIONS.md` #11 accepts the code-guessing risk on
// an argument with no rate term in it, and `threat-model.md` leans on this cap
// to make that acceptance true rather than nearly true: without it the callable
// inherits the global `maxInstances: 10` and the v2 default `concurrency: 80`,
// which is 800 concurrent guesses and moves the expected time to a first hit
// *inside* one code's 24-hour life.
//
// Until this file existed, both numbers were asserted by nothing anywhere in the
// repo — a number with a security argument attached and no test behind it. A
// tidy-up that harmonised the two option blocks, or a merge that dropped the
// per-function override, would have raised sustained guessing throughput by more
// than an order of magnitude with a diff nobody re-reads as the only evidence.
//
// It reads `__endpoint` off the BUILT module, which is what `firebase deploy`
// itself reads to shape the deployment — not the source text, which can say one
// thing while `lib/` says another.
import assert from 'node:assert/strict';

import { createInvite, onAwayChanged, onCheckInCreated, redeemInvite } from '../lib/index.js';

/** The deploy manifest firebase-functions attaches to each exported handler. */
function endpoint(fn, name) {
  const ep = fn?.__endpoint;
  assert.ok(
    ep,
    `${name} has no __endpoint — either it is no longer a firebase-functions ` +
      'handler, or lib/ is stale. Nothing below would mean anything.',
  );
  return ep;
}

const redeem = endpoint(redeemInvite, 'redeemInvite');

assert.equal(
  redeem.concurrency,
  1,
  'redeemInvite must serialise: OPEN-QUESTIONS.md #11 and threat-model.md both ' +
    'rest on this cap, and the v2 default is 80 per instance.',
);
assert.equal(
  redeem.maxInstances,
  3,
  'redeemInvite must cap instances at 3. Inheriting the global 10 raises ' +
    'sustained code-guessing from roughly fifteen attempts a second to a ' +
    'hundred and fifty.',
);

// The control for the two above. If the global block were the only thing in
// play, `redeemInvite` would read 10 and these would still be a pair of
// assertions about numbers that came from somewhere else — so assert that a
// function which does NOT override it genuinely differs.
const fanOut = endpoint(onAwayChanged, 'onAwayChanged');
assert.equal(
  fanOut.maxInstances,
  10,
  'onAwayChanged is supposed to take the global cap. If this is 3 the override ' +
    'has leaked, and if it is neither the global block has moved.',
);
assert.notEqual(
  redeem.maxInstances,
  fanOut.maxInstances,
  'the override is what this file exists to protect; if the two now agree it ' +
    'has been harmonised away.',
);

// Region is §1 and §16: Firestore's location is permanent, and a function in
// `us-central1` — the library default — would quietly move every read of an EU
// citizen's check-in history across the Atlantic.
for (const [name, fn] of [
  ['onCheckInCreated', onCheckInCreated],
  ['onAwayChanged', onAwayChanged],
  ['createInvite', createInvite],
  ['redeemInvite', redeemInvite],
]) {
  const ep = endpoint(fn, name);
  const region = Array.isArray(ep.region) ? ep.region : [ep.region];
  assert.deepEqual(
    region,
    ['europe-west1'],
    `${name} must deploy to europe-west1 (§1, §16), not ${JSON.stringify(ep.region)}.`,
  );
}

console.log('probe: done — 4 endpoints, redeemInvite capped at concurrency 1 / maxInstances 3');
