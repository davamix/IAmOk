# ADR-0006 — `reconcile()` is serialised by a lease in the store

**Date:** 2026-08-17 · **Status:** Accepted
**Phase:** 3 (found verifying a Phase 2 fix on hardware; implemented in Phase 3)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §3, §4, §6, §10

## Context

§3's operating rule is *reconcile, don't mutate* — one idempotent function per side, called on app
open, on check-in, on FCM arrival, on alarm fire, and on boot. It says nothing about two of those
happening at once, and until Phase 3 nothing could: the watched side's only caller was the UI
isolate.

**Measured on the POCO F3 on 2026-08-17, and reproduced on a second fresh install.** After a clean
install of a build whose alarm ids were correct:

| | |
|---|---|
| `settings.device_timezone` | `Europe/Madrid` |
| `pending_alarms` rows | **18**, every one `Europe/Madrid` |
| `dumpsys alarm` | **19** |
| The extra | `2026-08-17 23:00 CEST` = 21:00 **UTC** |

On a fresh install `LocalStore.deviceTimezone()` is null, so the first `reconcile()` takes
[ADR-0002](0002-clock-split.md)'s documented UTC fallback and arms the window at UTC wall times. The
UI then resolves the zone, stores it, and reconciles again. For days already in the window that is
harmless and in fact intended — the id is `hash(day, slot)` and deliberately excludes the zone, so
the corrected schedule *replaces* the UTC one. But `(2026-08-17, night)` was wanted **only** under
UTC: 21:00 UTC was still an hour away while 21:00 CEST had passed. The corrected run did not want it,
and it was left armed.

It escaped `toCancel` because the two runs **overlapped**. `toCancel` is
`currentlyScheduled − desired` where `currentlyScheduled` is a snapshot of `pendingReminders()`, and
the second run read that snapshot before the first had written its own result. `build()` and the
resume-triggered `refresh()` both call `reconcile()`, and on a cold start they land within
milliseconds of each other.

The outcome is an alarm **the app can never cancel**: its day has left the desired window, so no
future reconcile will ever emit a cancel for it. That is the direction
`LocalStore.replacePendingReminders` names as the one that must never occur, and Phase 2's
whole-desired-set re-assertion cannot repair it — re-asserting what *should* exist says nothing about
what should not.

Cost here is genuinely low: §10 rates a spurious reminder as costing nothing, and this one carried
correct wording on the correct day. **The reason it is an ADR rather than a bug fix is what Phase 3
does next.** The same code path is about to carry a logic-bearing warning alarm belonging to a
watcher, where §10 rates a false fire as costing "everything", and Phase 4 adds a third caller in a
third isolate. Two concurrent watcher reconciles would also both advance
[ADR-0004](0004-refused-is-not-unreachable.md)'s access-lost cadence for the same milestone — day 0
consumed twice, so day 1 never fires.

## Decision

**1. `reconcile()` takes a lease in `LocalStore` before it changes any alarm, and releases it after.**
A `reconcile_lock` table holding an owner and an expiry, taken inside a `BEGIN EXCLUSIVE` transaction
so the compare-and-set is one atomic step rather than a read that races an upgrade.

**The lease is keyed by *scope*, not global, and the first version got that wrong.** The watched and
watcher sides are independent reconciles over **disjoint** alarm sets — `kind='reminder'` against
`kind='warning'`, different platform ids, nothing shared — and both run when the app opens. With one
row, the loser skipped its alarm work entirely:

```
force-stop, then open the app        reminders   warnings
  one global lease, watched won            18          0
  one global lease, watcher won             0         12
  per-scope lease                          18         12
```

Only the device showed it, and only after the app-open repair below existed to make both sides run at
once. **Serialising work that cannot conflict is not caution — it is a second way to leave alarms
unarmed**, which is precisely the outcome this decision exists to prevent. Scopes are `'watched'` and
`'watcher'`; a finer key is available if one ever needs splitting.

**2. The lock lives in the store because that is the only thing all three isolates can see.** §4 is
explicit that the UI, alarm and FCM isolates share no memory, so a Dart mutex in the UI isolate is
invisible to the two callers that matter most. §4 already names SQLite as the cross-isolate contract
and gives *"real cross-isolate locking"* as the reason it was chosen over `SharedPreferences`; this
is the first thing that actually depends on that property.

**3. It is a lease, not a lock.** A bare isolate being killed is its *normal ending*, not an error. A
lock held until explicit release would eventually be held forever by a process that no longer exists,
and the app would go silently inert — the one failure this design cannot detect in itself. The lease
is 30 seconds: longer than the slowest legitimate run, including the Firestore read Phase 4 adds
inside it, and short enough that a killed isolate costs at most one skipped reconcile.

**4. Reading state is never gated; only changing alarms is.** `reconcile()` always reads and returns
what the screen should show. A caller that got nothing back would render *"this phone could not get
ready"* for a condition that is not an error — the Phase 2 defect where a failure replaced the whole
screen, arriving by a new route.

**This split is what makes the same mechanism safe on the watcher side.** The alarm isolate must
always reach its warn/don't-warn decision, because silence is the failure this app cannot detect. It
is the *scheduling* it may skip, never the *speaking*. Phase 3 wires it that way.

**5. A live lease refuses everyone, including a caller presenting the same owner string.** The first
draft exempted the current holder so it could refresh rather than deadlock against itself. A test
caught what that actually buys: two runs whose tokens match — same label, same instant — are each
handed the lock, and the exclusion silently does not exist. Nothing in this design acquires twice, so
the exemption protected against nothing and disabled the mechanism under exactly the timing that
makes it necessary. Owners are therefore **unique per acquisition**, and exist only so that release
cannot free somebody else's lease.

**6. Failure to acquire is reported, never thrown** — including SQLite reporting the database busy.
From the caller's side those are the same fact: somebody else is working, so do not touch the alarm
set. Failing closed is the safe direction, because a skipped reconcile is repaired by the next one
and a concurrent one strands an alarm.

## Consequences

**Bought.** The platform's armed set and the store's belief about it can no longer diverge through
concurrency, which is asserted directly rather than inferred — the regression test runs a second
reconcile *inside* the first one's platform call, the same interleaving the device produced, and was
verified to fail against the unlocked implementation. Phase 3's alarm isolate and Phase 4's FCM
isolate inherit a mechanism that already exists and is already tested, rather than discovering the
need for one from a false warning on somebody's phone.

**Paid.** A schema version (v1 → v2, additive). One SQLite transaction per reconcile. A lease
duration that is a judgement call rather than a derived quantity — set it too short and a slow run
loses its lock mid-flight, which costs a skipped alarm update and no more. And a genuine new failure
mode: a reconcile that skips because another is running does *less* than the caller asked for. That
is safe only because `reconcile()` is idempotent and the holder is computing the same desired set
from the same store — if either stops being true, this decision needs revisiting.

**A consequence that had to be fixed in the same change, and this ADR first understated it.** The
UTC-fallback pass on a fresh install is not repaired by the lock — it is *entrenched* by it. Before
the lock, the zone-corrected run behind the first one quietly fixed the wall times while stranding
one alarm. With the lock that run is correctly refused as concurrent, so **nothing corrects them**.
Measured immediately after implementing this, on the same handset:

```
device_timezone   Europe/Madrid          ← already resolved and stored
pending_alarms    19 rows, Etc/UTC       ← store and platform agree: no orphan
alarms armed at   14:00 / 20:00 / 23:00 CEST
```

The exclusion worked exactly as designed and made the app worse: a 23:00 nudge to someone who may be
asleep, for the depth of the window, instead of one stray alarm at a correct time. **Trading a
recoverable failure for an unrecoverable one is not a fix**, and an earlier draft of this section
called the window "briefly" wrong, which was the mistake — with the lock in place there is nothing
brief about it.

So `WatchedStateNotifier.build()` now caches the device zone **before** the first reconcile, and the
UTC pass stops happening at all rather than being undone afterwards. Re-measured on a fresh install:
18 alarms at 12:00 / 18:00 / 21:00 Europe/Madrid, 18 matching store rows, lock released. That
ordering is part of this decision rather than a follow-up, because the lock is not safe to ship
without it.

**A gap this makes load-bearing.** Every other `LocalStore` test uses `inMemoryDatabasePath` — one
connection to a private database. The Phase 2 summary already flagged the absence of a
two-connections-to-one-file test and said it mattered from Phase 3. A lock tested on one connection
asserts nothing, so `test/data/local_store_lock_test.dart` opens two real stores on one real file.
That still runs on `sqflite_common_ffi`'s desktop SQLite, which is the same API-level axis that let
Phase 2 ship SQL that could not parse below API 29 with 500+ tests green. **A real two-isolate check
on hardware is owed**, and is on the Phase 3 device list.

**Reversing** costs the schema row and the calls around it. Nothing migrates; no stored data changes
shape.

## Alternatives considered

**An in-process Dart mutex, or single-flight in the Riverpod provider.** Covers everything that
actually races *today*, because the only caller is the UI isolate, and it is a few lines. Rejected as
having the wrong shape from the first day it ships: Phase 3 adds a caller the mutex cannot see, and
the symptom there is a stranded warning alarm rather than a stranded reminder. Building the narrow
version first would mean writing the real one anyway, after the code that depends on it.

**Do the whole reconcile inside one SQLite transaction.** Makes the read and the write atomic without
any new concept. Rejected: the platform calls sit between them, so it would hold a write transaction
across binder I/O and, from Phase 4, across a network read. It also inverts the ordering
`LocalStore.replacePendingReminders` argues for at length — the store is deliberately written *after*
the platform calls, so a crash leaves it believing less is armed than really is, which is the
recoverable direction.

**Derive `toCancel` from `pendingNotificationRequests()` instead of the store.** The orphan really is
in the plugin's own record, so this would have caught it. Rejected: that record is a flat list of
integer ids with no notion of what kind of notification each one is, so a watched-side reconcile
would cancel the watcher's standing warnings. It also reads the plugin's `SharedPreferences` rather
than `AlarmManager`, so it is a second app-local belief and not the platform's answer.

**Fix only the UTC fallback and call the race theoretical.** The cheapest option, and it would have
removed the one orphan actually observed. Rejected because the observation is evidence of a mechanism
rather than a list of one: any two callers whose desired sets differ strand an alarm the same way,
and Phase 3 is about to add a caller that runs while the app is closed and reports nothing.
