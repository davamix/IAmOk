# ADR-0009 — Decide about every completed day, not only the most recent

**Date:** 2026-08-20 · **Status:** Accepted
**Phase:** 4 (measured in Phase 4, defect present since Phase 3)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §10 · amends
[ADR-0008](0008-the-warning-is-late-in-doze-and-the-app-says-so.md) consequence 4 ·
`ui-ux/screens.md`

## Context

[ADR-0008](0008-the-warning-is-late-in-doze-and-the-app-says-so.md) consequence 4 recorded, as a
derivation from the code rather than a measurement:

> `WarningPolicy.decide` takes `D = lastCompletedDay(now, watchedZone)` — computed from **when the
> isolate runs**, not from the day the alarm was armed for. […] Day `D` is never decided about by
> that fire. […] **`D` is skipped, and nothing notices.**

**It is now measured**, in `test/domain/reconcile/deferred_past_midnight_test.dart`. Not on the
device, deliberately: `docs/testing/strategy.md`'s rule is that if a test needs a device to answer a
question about *logic*, the logic is in the wrong layer, and nothing here is device-shaped. The
device had already supplied the only part it could — that deferrals happen, and reached 3h31m
overnight on the POCO F3.

**And the finding is wider than the ADR that raised it.** ADR-0008 files this under the Doze
deferral. The mechanism is not Doze at all:

> `reconcile()` asks about exactly **one** day — the last completed one — however long it has been
> since the previous run.

So a Doze deferral crossing local midnight is one route in. The others need no Doze whatever:

- a phone in a drawer for three days drops two missed days;
- a **force-stop** that nobody undoes until Thursday drops every day in between — and here there is
  no alarm left to carry an armed day, because
  [ADR-0007](0007-a-force-stop-is-silent-and-total.md) established that a force-stop cancels all of
  them silently;
- a flat battery over a weekend;
- a multi-day **refused** read — a revoked link, an expired token, or the bad rules deploy §17
  rates as the fleet-wide case — during which nothing about the watched person is decided at all.

That last one matters for the shape of the fix: an approach that carried the armed day on the alarm
would close the deferral case and none of the rest.

**This is the failure class the app exists to prevent.** §10's asymmetry table rates a false claim
to a family as the worst bug this app can have, and §12 names the runner-up: *"silence is the one
failure this app cannot detect in itself."* A dropped day is that silence, arrived at by
arithmetic.

## Decision

**`reconcile()` decides about every completed day it has not decided about yet, oldest first,
bounded.**

**1. The window is `(lastDecidedDay, D]`, floored and capped.**

`WatcherCache` gains `lastDecidedDay` — the newest day this device has actually **settled**. The
window is every day after it, up to and including `D`, then:

- floored at `link.activeFrom`, because §7 says never warn about days before the link existed;
- floored again at `D - 6`, a **seven-day** look-back matching §10's seven-day rolling alarm
  window, so a device that has been unable to decide for a month does not wake up and post thirty
  notifications;
- and always non-empty, always ending at `D`, so every existing behaviour keyed on "the decision
  about D" is untouched.

In ordinary daily operation `lastDecidedDay` is `D - 1` and the window is exactly `{D}` — **the
common case is provably identical to the previous behaviour**, which is what makes this safe to
land on the warning path.

On a **first** reconcile `lastDecidedDay` is null and the window is `{D}`. A fresh install does not
retro-warn about days it was not watching.

**2. "Settled" is delivery-aware, and the pointer only advances over settled days.**

A day is settled when it was decided silent, or a warning for it is already standing, or a warning
was owed **and recorded as delivered**. A day whose warning was owed but could not be delivered —
`POST_NOTIFICATIONS` revoked, `NotificationDelivery.unavailable` — is **not** settled, and
`lastDecidedDay` stops below it rather than stepping over it. The pointer advances only across a
contiguous run of settled days, so a hole cannot be jumped.

This is the same rule `NotificationDelivery` already enforces for the access-lost cadence — *record
what was delivered, not what was decided* — applied to the new pointer, because the alternative
reintroduces the identical defect through a new field.

**3. A refused read does not advance the pointer.**

ADR-0004 is explicit that access loss is not a claim about the watched person and is recorded apart
from `warningsShownFor`. So days spent refused were never decided *about her*, and when access
comes back the window catches up on them: days she tapped are settled by the evidence the recovered
read carries, and days she genuinely missed are warned about. That is the correct outcome and it is
also a burst on recovery — bounded by the seven-day cap, and stated here rather than discovered.

**4. Catch-up posts only the outcomes that are claims about a *day*.**

`warnOnline` and `warnOffline` name a day nobody checked in: one message per missed day is one fact
per message. `warnUnverifiableAway` is not that — it is present tense, *this phone cannot check, and
she was marked away until Saturday*, a claim about the cache's staleness **now** rather than about
any day. Caught up across a six-day gap it would post six notifications differing only in a date
that is not what any of them is about.

**This was found by a test, not by reasoning, and the first implementation shipped it.** The
existing service test *"a cached away that cannot be re-verified speaks, honestly"* went from one
notification to six the moment the catch-up landed. That is the burst this ADR names as its main
cost, arriving in the one case where every extra copy carries no extra information.

So an older day with that outcome is **not posted and not settled**. The pointer stops below it and
the day is decided again once a read succeeds, on evidence rather than on a stale cache — silent if
the away really did cover it, warned if the away had been cancelled and she was expected to tap.
`warnAccessLost` cannot arise here at all: the refused branch owns it, with its own decaying
cadence.

**5. Copy: a warning names its day whenever "yesterday" would be false.**

Three of the four warning bodies hard-coded the word *yesterday*. Posting any of them about an
older day would be a false claim to a family in the message whose whole purpose is not to make one.

The fix is not new: `NotificationCopy.correctionBody` already faced exactly this — the correction
path has always been able to fire for several days at once — and already solves it with

```dart
final when = day == today.previous ? 'yesterday' : 'on ${_date(day)}';
```

The warning bodies now use the same idiom and the same `_date` formatter. Approved strings are in
`ui-ux/screens.md`.

A consequence worth stating because it changes an approved string for an existing case: a watcher
several zones from the watched person could already be told *"yesterday"* about a day that was not
theirs. Under this rule that message dates itself instead. The words got **more** true, on a path
where truth is the whole product.

## Consequences

**Bought.** The app stops silently dropping missed days. It closes the Doze deferral, the drawer,
the force-stop gap, the flat battery, and the recovery after a multi-day refusal — one mechanism for
all of them, which is what §3's *reconcile, don't mutate* is supposed to deliver and did not here.

**Paid, and this is the real cost: a burst.** Up to seven warning notifications can arrive at once
after a seven-day gap. §1's whole notification model is *quiet confirm, loud miss*, built so the
family is never trained to swipe the channel that matters — and a burst is exactly what trains
that. Two things bound it: the gap has to be genuine (each day in it is a day nobody knows about,
which is the thing worth being loud about), and the cap is seven. **A single summarising
notification** — *"No check-in from Mum on Monday 10, Tuesday 11 or Wednesday 12 August."* — was
the alternative and is deferred, not rejected: it needs plural copy approved against the
elderly-first guidelines, and it would make the notification id no longer per-day, which is what the
correction path uses to replace exactly one message. Revisit it with §13's health panel in Phase 7,
where the multi-day list layout is being designed anyway.

**Paid.** A schema migration to v4 for `last_decided_day`, and it must be idempotent — the
`onDowngrade` reasoning in `LocalStore` spells out what a bare `ALTER TABLE … ADD COLUMN` costs when
a rollback replays it. `WarningPolicy` gains a second entry point (`decideFor`, taking the day
explicitly) with `decide` delegating to it, so there is one body and no drift.

**Not paid.** No change to `WarningPolicy`'s per-day reasoning — the six ordered steps, ADR-0001's
precedence, ADR-0004's three-state verification — none of it moves. This changes *which days* the
policy is asked about, and nothing about what it answers.

**Reversing** costs the reconciler loop, the copy variant and the column. The column can stay
unread; nothing else migrates.

## Alternatives considered

**Accept it, as ADR-0008 did.** The honest option while it was believed to need a 14-hour untouched
phone from a 10:00 alarm. It stops being defensible once the same arithmetic drops days for a
force-stop and a flat battery — a *late* warning is what ADR-0008 accepted, and a *missing* one is a
different thing, which that ADR says itself.

**Carry the armed day on the alarm** and decide about that day when it has been overtaken. Smaller,
and it closes only the deferral: a force-stop cancels every alarm, so in the case ADR-0007 exists
for there is nothing left to carry anything. It also still needs the dated copy, so it buys none of
the cost back.

**Stop the ledger advancing past an undecided day, and pick up the oldest one next fire.** One
warning per fire, no burst — and a three-day gap then takes three days to report a Monday. On a
dead man's switch that is the wrong direction to be slow in.

**Warn about the whole gap in one summarising notification.** The best answer to the burst, and
deferred rather than rejected — see *Consequences*.
