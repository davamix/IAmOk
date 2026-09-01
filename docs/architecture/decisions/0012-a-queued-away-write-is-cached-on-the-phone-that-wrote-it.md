# ADR-0012 — A queued away write is cached on the phone that wrote it, and only there

**Date:** 2026-09-01 · **Status:** Accepted
**Phase:** 6 · **Affects:** ARCHITECTURE.md §3 · §12 · ADR-0001 · `ui-ux/screens.md`

## Context

**Measured on a device on 2026-09-01, in aeroplane mode.** An away period set offline is reported
*"Saved."* and then reaches nothing on the setter's own phone: `self_away` stays empty, the away line
does not appear, the control still reads *"I'm away"*, and the reminders for the away days stay
armed. On the plane §8 names, the phone goes on reminding her three times a day through the period
she has just been told is saved.

Nothing corrected it, and the reason is two deliberate decisions colliding:

- **The watched side takes its away row from a read-back.** ADR-0001 decision 1: only a read that
  *succeeded* may replace the away cache. A phone that could not reach the server to write cannot
  reach it to read either, so the write queues and the cache stays as it was.
- **`onAwayChanged` deliberately skips whoever set the period** — `away_fan_out.ts` filters
  `uid !== fact.changedBy`, because the setter's device is the one that already knows. **So the one
  device certain not to be told is the one that wrote it.**

The `AwayOutcome.queued` copy is honest — *"Saved. Your family will see this as soon as this phone
can send it."* — but the screen underneath it contradicts the sentence, and stays contradicting it
until an unrelated reconcile happens to run.

This is the seventh of the owner's decisions of 2026-09-01, and the only one with teeth.

## Decision

**A write that returns `AwayQueued` is written into the local `self_away` row on the phone that
wrote it. The watched side only. Never the watcher side.**

`WatchedNotifier._cacheQueued` runs on the `queued` outcome alone — a refusal, and a confirmed write,
both cache nothing. The reconcile then re-derives the reminders from that row like any other, so
nothing is patched incrementally.

**The bound is ADR-0001, unchanged: the first read that *succeeds* overwrites it with whatever
Firestore holds, including with nothing.** The optimistic row has no special standing; it is simply
what this tier holds until the server can be heard from.

**The asymmetry is the decision, not an omission.** On the watched side the cache is about the
reader's own state, and being wrong **stops her reminders** — the loud direction, because her family
still reads the server, sees no away period and warns exactly as before. On the watcher side the same
shortcut would cache a period about **somebody else**: a write the server later refused would silence
that watcher for up to a month, with no notification and no error, which is the failure §12 calls the
one this app cannot detect in itself.

## Consequences

**This changes what tier 3 means, and that is the reason this record exists.** §3 describes
`LocalStore` as *"an offline decision cache — what a background isolate reads when it cannot reach
the network"*, and §6's row says *"cached `awayPeriod`"*. Both read as a **mirror of Firestore**.
After this decision the watched person's own row may also hold **an unconfirmed local write** — a
value no tier above it holds. Any future reader of `self_away` must treat it as *"what this phone
believes, bounded by the next successful read"* rather than as *"what the server said"*.

**It does not break §3's *reconcile, don't mutate*.** What is written is an *input* to the reconcile,
not a patch to its output; `refresh()` still re-derives the whole desired alarm set from scratch. The
rule bars incremental patching of derived state, and this is not that.

**A write the server later rejects leaves this phone wrong until the next successful read**, and
nothing surfaces the rejection. Bounded in the loud direction — her reminders stop, her family is
unaffected — and bounded in time by `clampedToSanityBound()` at 60 days in the worst case.

**The self-heal is her next app open, not a nudge.** Because the fan-out skips the setter, no push
will correct this device; only a reconcile that gets a good read will. That was already true before
this decision — it is what produced the device measurement above — but this record is where it is
written down.

**Reversing it is cheap**: delete `_cacheQueued` and its call. The behaviour returns to the measured
state — *"Saved."* over a screen that disagrees — so the cost of reversal is a UX regression, not a
migration. Three mutation entries and `test/application/away_queued_is_cached_test.dart` exist to
make an accidental reversal fail loudly.

**The watcher-side prohibition is enforced by a test, not by the type system.**
`test/application/watcher_never_caches_test.dart` was added at the Phase 6 close-out gate for exactly
that reason: until it existed, adding four symmetrical lines to `WatcherStateNotifier.setAway` would
have failed nothing at all.

## Alternatives considered

**Do nothing, and let the next reconcile fix it.** Rejected: the next reconcile may be days away —
the whole scenario is a phone with no signal — and *"Saved."* over a screen that says she is not away
is the app contradicting itself on the surface an elderly person reads every morning.

**Say something weaker than *"Saved."* when the write queues.** Rejected by the owner on 2026-09-01,
and it was the alternative most seriously considered. `AwayOutcome`'s docstring spends a paragraph
refusing to say *"could not reach the server"*, because the app cannot distinguish a slow server from
a dead radio and a six-second timeout is not evidence of either. Softening the wording would have
made every away write sound uncertain in order to describe a case the phone cannot actually detect.

**Cache on both sides, symmetrically.** Rejected, and this is the load-bearing rejection. It is the
tidier-looking design and it is wrong for the reason above: on the watcher side, being optimistically
wrong is *silence about another person*, which no one can see and no one is told about. The
asymmetric rule is harder to remember, so it is written here rather than left in a docstring.

**Write it to a separate "pending write" table instead of into `self_away`.** Rejected: the reconcile
would then have to merge two sources at every read, and every future reader of the away cache would
need to know about both. One row with one honest meaning is cheaper than two rows and a merge rule —
and the merge rule is where the next defect of this shape would live.

**Have the fan-out include the setter's own device.** Rejected: it makes FCM load-bearing for the
setter's own correctness, which §3 forbids — a push carries no authority and losing one must cost
latency, never correctness. It also does not help the case that motivated this at all: the phone is
offline, so it will not receive the push either.
