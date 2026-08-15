# ADR-0001 — Refresh Firestore before the away cache decides

**Date:** 2026-08-15 · **Status:** Accepted · refined by
[ADR-0002](0002-clock-split.md) — `lastReconcileAt` is a timestamp, not a date, and the staleness
test compares calendar days. The decision below is unchanged.
**Phase:** 0 (found at the Phase 0 gate; implemented in Phases 3 and 6)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §8, §10, §12
**Model:** [`tools/models/away_warning_model.dart`](../../../tools/models/away_warning_model.dart) — 18 cases, runnable

## Context

§10's warning sequence consulted the **cached** away period at step 3 and returned
silent, and read Firestore at step 5. The same section then claimed:

> Step 5 is why the warning alarm keeps firing daily through an away period rather than being
> cancelled: each fire re-verifies against Firestore, so an away that is cancelled remotely is
> picked up at the next fire even if every push was lost.

Step 3 returns before step 5 runs. During an away period — the only time that claim
matters — step 5 was unreachable. The stated mechanism could not do the job assigned
to it.

**The failure.** A watcher cancels an away period early; the `onAwayChanged` nudge is
lost to Doze, throttling, or a force-stopped app; the watched person is home and stops
tapping. The watcher's phone silences itself until the *original* `through` date. In the
modelled scenario — away 1–4 Aug, cancelled on the 5th, Mum home and not tapping — the
first warning arrived on **22 August instead of the 6th: sixteen days of wrongful
silence**, and §17 already notes this state is indistinguishable from working, because
silence is what away mode looks like.

This is the failure §12 identifies and eliminates for the *scheduled* end of an away
period by making expiry arithmetic. Early **cancellation is not arithmetic** — it is an
event a device can only learn by reading — so the same hole reopened through the cancel
path. It also falsified §3's operating rule that losing a push "costs latency, never
correctness", and inverted §3's own tiering by reading tier 3 before attempting tier 1.

Two further defects surfaced only once the sequence was executable:

- **How a cancellation is *written* changes correctness.** §12 says cancellation
  "writes the same document" but never says what. Deleting it retroactively un-covers
  days that were genuinely away, so the fix alone produced a **false warning** about an
  elapsed away day — by this app's severity ordering, worse than the bug being fixed.
- **"Online" is not "the read succeeded."** A timeout, a permission denial, or an App
  Check rejection all occur while online. Clearing the cache on connectivity rather than
  on a successful read would wipe a legitimate away on a transient error and warn falsely.

## Decision

**1. Reconcile first, then decide.** The alarm attempts the Firestore read before any
cache is consulted. If and only if the read **succeeds**, the cached away period is
overwritten with what Firestore returned — *including overwriting it with nothing* —
`lastConfirmedDate` is refreshed, and `lastReconcileAt` is stamped. A failed read is not
an answer and never clears the cache.

**2. A stale cached away may not silence indefinitely.** It silences for at most
**2 days** without a successful re-verification. The alarm attempts a reconcile daily, so
exceeding that means three consecutive failures.

**3. Past the staleness bound, the watcher is told — with a distinct message.**

> *"Can't check on Mum — your phone has been offline since Tuesday 10:14. She was marked
> away until Saturday 22 August."*

It states both facts and claims neither. This follows §10's existing rule that silence is
a silent failure and the device must say what it actually knows.

**4. Evidence outranks doubt.** A recorded check-in for `D` settles the day before the
away reasoning runs. Tapping during an away day is allowed (§12), so a confirmed day stays
silent even when the cached away has gone stale.

**5. Cancellation truncates, it does not delete** — except when nothing has elapsed:

```dart
AwayPeriod? applyCancel(AwayPeriod a, Day cancelDay) {
  if (cancelDay <= a.from) return null;           // nothing elapsed — delete outright
  return AwayPeriod(a.from, cancelDay.minus(1));  // preserve the elapsed days
}
```

Truncating on the day an away *starts* would write `through = from - 1` and violate the §8
invariant `through >= from`, so that case deletes.

**6. Consequently, `from` is immutable after creation.** §8's `from >= today` can only be
a *create* rule: truncating an in-progress period rewrites a document whose `from` is
already in the past, and a blanket `from >= today` would reject the very write this ADR
requires.

## Consequences

**Bought.** Wrongful silence drops from 16 days to 0 in the modelled scenario, with no
spurious warnings. Losing an away-cancellation push costs latency again rather than
correctness, restoring §3's operating rule. Step 5 disappears into `reconcile()`, which is
*more* faithful to "reconcile, don't mutate" than the sequence it replaces — the alarm now
refreshes state, then decides purely from state.

**Paid.** One Firestore read per link per day at every alarm fire, whether or not an away
period is active — negligible at family scale, and noted in §8 as already accepted for the
watcher's `get()`. A watcher whose phone has been offline for more than two days during a
**genuine** holiday receives an unnecessary — though honest — notification. That cost is
accepted deliberately: offline, the device cannot distinguish "the away was cancelled and I
did not hear" from "the away is still on and I have not checked". The model proves it
(`S12` and `S13` produce identical output at every staleness setting, because the device
input is identical), so this is a choice about which error to prefer, not a gap to close.
It self-corrects the moment connectivity returns.

**Reversing** costs a `WarningPolicy` change and its tests. Nothing migrates. The
cancellation semantics in decision 5 are the sticky part: away documents written by an
older client would carry the delete semantics, which matters only if v1 ships before this
lands. It does not — no client exists yet.

## Alternatives considered

**Leave §10 as written.** Rejected: the model fails `S8`, `S9`, `S12`, `S13`, and the
16-day silence is the "app goes quiet and stays quiet" mode §17 rates as indistinguishable
from working.

**Keep the ordering, add a staleness bound to step 3 only.** Nearly the same behaviour and
a smaller edit, but it leaves step 5's negative path unspecified — nothing would ever clear
a stale cached away — and it keeps the tier inversion. Rejected as treating the symptom.

**Stay silent when offline with a stale away.** The conservative reading: never risk a
false alarm. Rejected because silence is the one failure this app cannot detect in itself,
and a watcher who believes they are being told nothing *because there is nothing to tell*
is exactly the person this app exists to inform.

**Cancel by deleting the document.** Simpler, and the natural reading of "cancel".
Rejected: it produced a spurious warning about a legitimately-away day in the model.
Truncation preserves the history the decision depends on.

**A shorter staleness bound (0 or 1 day).** Would speak sooner, but a single failed
reconcile is common on a phone in a pocket. Two days tolerates ordinary patchy signal while
still bounding the silence far below the 30-day away cap.
