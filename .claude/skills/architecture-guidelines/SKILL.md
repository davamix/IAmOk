---
name: architecture-guidelines
description: Layering, isolate, and state-management rules for the I Am Ok app. Load before writing or changing any Dart under lib/, adding a package to pubspec.yaml, touching a background entry point (alarm or FCM isolate), or deciding where a piece of logic belongs.
---

# Architecture guidelines

Full design: `docs/architecture/ARCHITECTURE.md`. This is the working subset — the rules that get
broken in practice. When this file and ARCHITECTURE.md disagree, ARCHITECTURE.md wins and this file
is the bug.

## The three rules that matter most

**1. Every hard decision is a pure function in Domain.** What day is it, should a reminder exist,
should we warn, is this day inside an away period, is this a correction — all of it lives in
`domain/` as a pure function over explicit inputs. No `DateTime.now()`, no plugin calls, no I/O,
**no Flutter import**. The layers above supply inputs and execute the result.

This is not style. Two of the three isolates that run this app are bare — no Flutter widget tree,
no Riverpod, no UI state — and the domain layer is the only code that behaves identically in all
three. It is also what makes time-dependent logic testable in milliseconds instead of 24 hours.

**2. Reconcile, don't mutate.** There is exactly one idempotent `reconcile()` per side. It reads
current state, computes what alarms and status *should* exist, and makes reality match. It is
called on app open, on check-in, on FCM arrival, on alarm fire, and on boot. **No code path
incrementally patches state.** Reboot, late FCM, missed FCM, clock change, timezone change, reinstall, and away
transitions all collapse into that one path. A handler that adjusts state directly re-opens all
seven.

**3. Nothing is transmitted as a command.** Every FCM push is a data-only "something changed,
reconcile now" nudge carrying no authority. Losing one costs latency, never correctness. This is
what stops a lost "away finished" message from silencing a watcher forever.

## The isolate boundary

Three isolates, **sharing no memory**: UI, FCM background, alarm.

| | Entered by | Can see |
|---|---|---|
| UI | User opening the app | Everything |
| FCM background | `onBackgroundMessage`, app closed | Nothing from UI. Initialises Firebase itself. |
| Alarm | `android_alarm_manager_plus` callback | Nothing from UI. Initialises its own plugins. |

Consequences, all non-negotiable:

- Anything a background isolate needs is **on disk**. Riverpod providers, in-memory caches, and a
  live Firestore listener's state are invisible to it.
- The local store is **`sqflite`, never `SharedPreferences`** — real cross-isolate locking.
  `SharedPreferences` caches per isolate and needs `reload()` gymnastics that quietly fail.
- Both background entry points are top-level functions annotated `@pragma('vm:entry-point')` that
  bootstrap the minimum they need, call `reconcile()`, and exit.

## Layers

```
Presentation
     ↓
Application (Riverpod) ──→ Data ──┐
     │                            ├──→ Domain (pure — depends on nothing)
     └───────────→ Platform edge ─┘
```

Dependencies point inward. **Domain depends on nothing.** Data and Platform are peer layers, both
driven by Application and by the background isolate entry points; neither depends on the other, and
neither is called by Domain. A `package:flutter` or `package:cloud_firestore` import appearing
under `domain/` is a review failure, not a preference.

## Time

- **The day is decided on the device, at tap time.** The document id `YYYY-MM-DD` comes from the
  device clock in the device's timezone. There is no alternative that works offline.
- `deviceTappedAt` = client clock — what the family is shown, because it is what happened.
  `receivedAt` = `serverTimestamp()` — audit trail and the only skew signal.
- **Never use `serverTimestamp()` to decide the day.** It resolves when the write reaches the
  server. A tap at 23:50 with no signal, syncing at 08:00, would land on the wrong day. This
  corrects HANDOVER.md; see ARCHITECTURE.md §11.
- Clock skew is **detected and surfaced**, never silently corrected.
- Scheduling uses `timezone` + `flutter_timezone` and `zonedSchedule`. Never raw UTC offsets — DST
  breaks them.
- The day is defined in the **watched person's** timezone, carried on the link and in the payload.
  The watcher's alarm fires at *watcher-local* time but asks about the last completed
  *watched-local* day.

## Alarms — the asymmetry

| | Watched: reminders | Watcher: the warning |
|---|---|---|
| A false fire costs | Nothing | **Everything** — a false claim to a family |
| Mechanism | `flutter_local_notifications.zonedSchedule`, display only | `android_alarm_manager_plus`, wakes a Dart isolate |
| Verifies before speaking | No | **Yes** — five checks, in order |

The alarm isolate **reconciles first, then decides** — ARCHITECTURE.md §10, as amended by
ADR-0001. A runnable model of the whole thing, with 18 cases, is at
`tools/models/away_warning_model.dart`; run it before changing any of this.

**First, reconcile.** Attempt the read of `checkins/{watchedUid}/days/{D}` **and**
`users/{watchedUid}/shared/away`. If and only if it **succeeds**, overwrite the cached away with
what Firestore returned — *including overwriting it with nothing* — refresh `lastConfirmedDate`,
stamp `lastReconcileAt`.

> **A failed read is not an answer.** Timeouts, permission denials and App Check rejections all
> happen while online. Gate the cache overwrite on *the read succeeded*, never on connectivity —
> getting this wrong wipes a legitimate away on a transient error and warns falsely.

**Then decide**, computing `D` = the most recently **completed** day in the watched person's tz:

1. `D < link.activeFrom` → silent. Never warn about days before the link existed. **Easy to omit,
   and its own §17 risk — do not drop it.**
2. `lastConfirmedDate >= D` → silent. **Evidence outranks doubt** — this comes *before* the away
   check, because tapping during an away day is allowed.
3. `D` inside the cached away period → silent if verified within **2 days**; otherwise the
   distinct *"Can't check on Mum — your phone has been offline since … She was marked away
   until …"*.
4. Otherwise **warn**: the plain message if the read succeeded, the offline message if it did not.

**Three distinct outcomes, never two.** Silence would be a silent failure; a flat "she didn't check
in" is a claim the device cannot support; and an unverifiable away is neither of those. Which one
fires is a correctness requirement, not copy polish.

The warning alarm **keeps firing daily through an away period** rather than being cancelled, so
each fire re-verifies against Firestore and an away cancelled remotely is picked up even if every
push was lost. That only works because the refresh happens *before* the away cache is consulted —
the pre-ADR-0001 ordering short-circuited on the stale cache and silenced the watcher for as long
as the away had left to run.

**Cancelling an away truncates `through`; it does not delete the document** — except when nothing
has elapsed yet, where truncating would violate `through >= from` and it deletes instead. Deleting
mid-period retroactively un-covers days the person was legitimately away, and the next refresh
then warns about one of them.

Alarms are maintained as a **7-day rolling window** by `reconcile()`, not armed one day at a time —
nothing runs at midnight. **During an away period the window extends to `through` + 7 days, with
the away days simply absent from the desired set.** That is what lets the watched side stay
display-only: the reminders for the first days back are already scheduled before the person leaves,
so the app re-arms itself without anyone opening it. Cancelling and re-arming instead would be
cheaper and less correct.

Belt and braces: an incoming tap cancels the pending alarm (fast path) **and** the alarm re-derives
the answer at fire time (correct path). Either alone is a bug.

## Before adding a package

Check ARCHITECTURE.md §15 first — the intended set is already chosen. A new dependency needs a
reason, and if it pulls Flutter into the domain layer the answer is no.

## When you want to contradict the design

Do not do it quietly in code. Write a decision record — format and rules in
`docs/architecture/decisions/README.md` — and amend the affected ARCHITECTURE.md section. A
codebase that disagrees with its design document is worse than either alone.
