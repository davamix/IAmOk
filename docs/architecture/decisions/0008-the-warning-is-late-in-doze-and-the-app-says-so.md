# ADR-0008 — The warning is late in Doze; accept it, surface it, and do not promise a time

**Date:** 2026-08-20 · **Status:** **Accepted** — chosen by the owner over the two alternatives,
and **revisited in Phase 4** on a named trigger, not on a feeling. See *Revisit trigger*.
**Phase:** 3 (measured on hardware, five runs)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §9, §10, §13, §14

## Context

**Measured on the POCO F3, Android 13 / API 33, HyperOS OS1.0, stock power settings, app never on
the Doze whitelist.** Five runs, 2026-08-19 and 2026-08-20. Full evidence in
[`docs/testing/device-matrix.md`](../../testing/device-matrix.md).

**The warning does not arrive on time when the watcher's phone is in deep Doze.** It arrives when
the phone next leaves Doze — 3h31m late in the overnight run, and it would have been longer if the
phone had been picked up later.

Three things were established, in this order, and the third overturned the reading of the first two.

**AlarmManager is not the problem.** In every run the `PendingIntent` was delivered at the armed
second. Our alarms carry `flags=0x5` (`FLAG_ALLOW_WHILE_IDLE`), `exactAllowReason=policy_permission`,
and `device_idle=--` — Doze is not deferring the alarm.

**Nor is a cold service start.** The obvious hypothesis was that the Flutter engine could not be
started from a hibernated process. It was tested directly: deep forced Doze with the process alive
and `AlarmService started!` already logged three and a half minutes earlier. **Nothing ran.** Process
warmth is irrelevant.

**The block is the JobScheduler hop, and it has a name.** `AlarmBroadcastReceiver.onReceive` calls
`AlarmService.enqueueAlarmProcessing`, which is `JobIntentService.enqueueWork` — a JobScheduler job.
Thirteen seconds after the armed second, still in deep `IDLE`:

```
JOB #u0a612/1984: …androidalarmmanager.AlarmService
  Satisfied constraints:   DEADLINE BACKGROUND_NOT_RESTRICTED TARE_WEALTH WITHIN_QUOTA
  Unsatisfied constraints:                    <- none
  readyNotDozing: false                       <- the only thing holding it
  Pending work: #0, #1                        <- both links, queued
  Standby bucket: ACTIVE   Uid: active        Ready: false
```

The `temporaryAppAllowlistDuration=10000` our alarm carries covers **the broadcast**, which did run.
It does not extend across the hop to the job the broadcast enqueues.

**And the same device delivers a different local notification on time in the same Doze.** Thirty
minutes later, `flutter_local_notifications`' 12:00 reminder — whose alarm is *indistinguishable* in
`dumpsys alarm` and whose receiver calls `notificationManager.notify()` directly instead of
`enqueueWork()` — arrived at `when=12:00:00`, on the second, with `get deep` still `IDLE`.

So the finding is narrower than "Doze breaks local delivery":

> **Android delivers our alarms in Doze. Android renders our notifications in Doze. What does not
> survive Doze is one plugin's decision to hand the work to JobScheduler.**

## Decision

**Accept the deferral for now. Do not fix it in Phase 3, do not promise a time, and surface it.**

**1. The warning is documented as "the next time the phone is awake", not as a time.**

The app has never told a user *when* the warning arrives — `warningLocalTime` is not rendered on any
screen, only in the debug harness. That is now a property to preserve deliberately rather than an
accident. Nothing in `lib/copy/` may state or imply a delivery time.

The notification copy itself is unaffected: *"No check-in from Mum yesterday."* stays true whenever it
is delivered, **as long as the deferral does not cross midnight** — see consequence 4, which is the
part of this decision that carries real risk.

**2. §13's health panel gains a row for it (Phase 7).**

§13 already models the low-usage watcher as the case the panel exists for, and already carries a
*"Last update: 3 days ago"* item. The new row reports the same class of fact from the other side:
that this device defers background work while idle, and that a warning may therefore arrive late.
It is a disclosure, not a fix, and this ADR says so plainly.

**3. §14's trigger condition is reworded, because it is false as written.**

§14 names the trigger for un-deferring §9's scheduled Function as *"whether **alarms** and data-only
FCM actually survive on Xiaomi / Samsung / Huawei with stock power settings."* On this handset
**alarms survive** — delivered at the armed second, every run — and so does a notification posted
from a receiver. Left as written, the condition reads as met when the measurement says the opposite.

**4. §9's scheduled Function stays deferred, and this ADR is not the argument for un-deferring it.**

The escape hatch is still there and still cheap (§16). What has changed is that it is no longer the
*only* candidate, because the cause is a plugin hand-off rather than a platform limit.

## Consequences

**1. The guarantee is gone for exactly the reader §13 is written for.** A watcher who uses their
phone through the morning sees nothing different; the default `warningLocalTime` is 10:00, by which
time most phones are awake. A watcher whose phone sits untouched — the low-usage watcher the whole
health panel exists for — gets the warning whenever they next pick it up. That is the cost, stated
plainly rather than softened.

**2. Nothing the app says becomes false.** The decision is still made locally by an isolate that
reconciles first (§10, ADR-0001), so away precedence, the three-state refusal (ADR-0004) and the four
outcomes all keep working. A late warning is a *late* warning, not a wrong one.

**3. The health panel cannot report this while it is happening.** A queued JobScheduler job is not
observable from inside the app. The panel can only say "this device defers background work" as a
standing property, and report staleness after the fact.

**4. A deferral that crosses midnight silently DROPS a missed day. This is the sharp edge.**

> **MEASURED and FIXED, 2026-08-20 —
> [ADR-0009](0009-decide-about-every-completed-day.md).** It was real, and it was **wider than this
> consequence states**: `reconcile()` asked about exactly one day however long it had been since the
> previous run, so a phone in a drawer, a force-stop, a flat battery and a multi-day refused read
> dropped days with no Doze involved at all. That is why the fix is not "carry the armed day on the
> alarm" — after a force-stop there is no alarm left to carry anything. `reconcile()` now decides
> about every completed day it has not settled, bounded at seven. The paragraphs below are kept as
> the derivation that turned out to be right about the mechanism and too narrow about its reach.

Derived from the code, not yet measured on device, and flagged here because it is the one
consequence that is worse than lateness:

`WarningPolicy.decide` takes `D = lastCompletedDay(now, watchedZone)` — computed from **when the
isolate runs**, not from the day the alarm was armed for. That is deliberate (§3: a fire is a nudge
to reconcile, carrying no authority) and correct for every case except this one. So:

- an alarm armed for `D+1` at 10:00, asking about day `D`,
- deferred past midnight into `D+2`,
- runs, computes `D' = D+1`, and decides about **`D+1`**.

Day `D` is never decided about by that fire. The next day's alarm also asks about `D+1`, which
`warningsShownFor` now holds, so it is suppressed. **`D` is skipped, and nothing notices** — which is
the "silence it cannot detect in itself" failure this design spends everything avoiding.

This needs a 14-hour untouched phone from a 10:00 alarm, so it is not the common case. It is
reachable by a watcher who leaves the phone in a drawer for a day. **It is not mitigated by this
ADR** and should be measured with the harness's forced-date control before Phase 4 relies on the
current behaviour.

> That last sentence was overtaken. It was measured in `flutter test`, not on the device, for the
> reason `docs/testing/strategy.md` gives: a question about *logic* that needs a device to answer it
> is logic in the wrong layer. The device had already contributed the only part it could.

**5. This is reversible and cheap to revisit.** No data-model change, no migration, no one-way door
(§16). Nothing here forecloses either alternative.

## Revisit trigger — Phase 4, and this is a scheduled task rather than a note

This was first written as *"Accepted (provisional)"* with no trigger, which is how a holding position
quietly becomes permanent. The owner has now chosen option 3 deliberately, **and** fixed when it gets
re-opened.

**Phase 4 is the trigger, because Firebase is what makes the deciding measurements possible.** Two
questions are unanswerable today and become answerable then:

1. **Can a Flutter background engine start *and complete a Firestore read* inside the ~10-second
   temporary allowlist, cold, in deep Doze?** This is the whole of option 1's viability. It cannot be
   measured in Phase 3: there is no Firebase dependency and the release build carries no `INTERNET`,
   so there is nothing to time. The engine start alone is **295 ms** against that window — encouraging
   and *not* an answer, because a network round trip on a cold radio in Doze is a different order of
   cost.
2. **Does high-priority data-only FCM wake the background isolate in deep Doze on this handset?**
   This is already a Phase 4 exit criterion, and `docs/testing/device-matrix.md` now says to run it as
   this measurement rather than as a tick. `firebase_messaging` bypasses the JobScheduler hop with
   `startService()` **only for high-priority** messages, so the Function's priority is part of the
   test, not an implementation detail.

If (2) passes, a local isolate demonstrably *can* be woken inside Doze on this device, and the
argument for option 2 weakens considerably. If (1) also passes, option 1 becomes the cheap fix and
this ADR should be superseded rather than amended.

**Until then the decision stands and the app may not promise a delivery time.**

## What this does not close

Two measurements were run for the record and **neither is acted on here**. Both are written up in
[`docs/testing/device-matrix.md`](../../testing/device-matrix.md); their results are summarised
below because they change how the two alternatives should be weighed, and they were taken *after*
this decision was made rather than to justify it.

**A. The ten-second allowlist is granted in full — and the job still does not run.** Sampled twice a
second in forced deep Doze: `UID=10612 … +9s700ms` at 346 ms past the armed second, counting down to
`+75ms`, attributed to `AlarmBroadcastReceiver`. No warning arrived; releasing Doze 100 seconds later
produced it within 20 s. **So the exemption exists and the plugin cannot use it**, having already
handed the work to a scheduler that ignores it. A Flutter background engine starts in **295 ms**
against that window. **Still unmeasured, and not measurable on this build** (no Firebase, no
`INTERNET` in release): whether the §10 Firestore read also fits.

**B. `firebase_messaging` vendors a modified `JobIntentService` that bypasses JobScheduler for
high-priority messages**, calling `startService()` directly inside the FCM temporary allowlist, with
a documented fallback to the job path when the allowlist is not granted.

So the alternatives stay open, and neither is now a leap:

- **Deliver from the receiver**, as the reminders already demonstrably do and as
  `firebase_messaging` already does in production. Preserves §10 entirely. The remaining unknown is
  the network read, not the engine start.
- **§9's scheduled server-side Function**, at the cost §9 and ADR-0007 record — against the objection
  that a server deciding "no check-in" cannot see the watcher's local away cache, which §10's whole
  *verify before speaking* design rests on, and with the constraint that **it must use high-priority
  FCM** or it inherits the very defect it was reached for.

So this ADR records what the app does today and what it may not claim — **not** a final answer about
where the warning should come from. That answer is owed at the *Revisit trigger* above.

> **The line here used to read "the status above is marked provisional for that reason", and it had
> been false since the owner chose option 3.** The header says **Accepted**, with a named Phase 4
> trigger, which is the whole point of that decision: a holding position with no trigger is how one
> quietly becomes permanent. Corrected on entering Phase 4, when the trigger came due.
