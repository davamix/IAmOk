# Phase 3 review — handover

**Written:** 2026-08-19 · **Head:** `bbe68d5` · **744 tests**, `flutter analyze` clean.

This document exists because the Phase 3 gate review ran long enough to span sessions. It records
what the reviewers found, what was fixed, what is still owed, and how to pick it up.

**Phase 3 is NOT signed off.** Three of five reviewers have run and been acted on; two have not run
at all, and the overnight Doze device criterion is unstarted.

---

## The one-line story

Five reviewers were launched at the Phase 3 gate. They found two criticals — one of them
independently by three of them — and roughly thirty further findings, on code whose self-review had
come out clean. Acting on those findings produced four more rounds, and **three of those rounds
found a defect introduced by the previous round's fix**. That pattern is the reason the remaining
reviewers should run before the Doze night rather than after.

---

## Commits, oldest first

| Commit | What |
|---|---|
| `13ab177` | Tier 1 — four false claims the watcher side made to a family |
| `00df78a` | Tier 2 — tests that could not fail, including the highest-value one |
| `da069b1` | Every finding from the **testing** review, including two that were lost to a compaction |
| `63f84b4` | Two more false claims from the **architecture** review, plus per-link isolation |
| `c347315` | The **UI/UX** review — the muted watcher's missing words, and a correction about the wrong day |
| `3355b3f` | Tier 3 — resume repaired only half the app; an unchecked notification payload |
| `c690b1b` | Tier 4 — the light palette missed this app's own contrast floor |
| `ee0beed` | Tier 5 — ADR-0007, and an ADR naming the wrong mechanism as its own guard |
| `bbe68d5` | The **architecture** re-review of Tiers 3-5 |

---

## Reviewer status

| Reviewer | Last run | Outcome |
|---|---|---|
| **architecture** | at `bbe68d5` | All findings fixed. **Has not seen `bbe68d5` itself.** |
| **testing** | at `da069b1` | All findings fixed. Has not seen the five commits since. |
| **uiux** | at `c347315` | All findings fixed. Has not seen the four commits since. |
| **security** | never, this round | Has seen none of it |
| **infrastructure** | never, this round | Has seen none of it |

### Standing rule

**Never run reviewers in parallel, and ask before running any.** Two parallel launches exhausted the
session limit. The working pattern is: run one, report, fix, ask before the next.

---

## The latest round — architecture on Tiers 3-5 (`bbe68d5`)

Its must-fix was a defect introduced two commits earlier while fixing a different one.

**A single failed link made the screen say *"You're not looking after anyone."*** The per-link
isolation added in `63f84b4` omits a link the reconcile threw on — and with one link, which is all of
Phase 3, "short list" *is* "empty list". The empty list makes a positive false claim, on the screen
the *lost access* notification routes to. Two aggravations: the `isEmpty` branch returned before the
warnings-off banner, so a muted watcher whose only link failed got neither; and the failure was
written to a settings key nothing reads.

*Fixed:* `WatcherState.unreconciled` carries them in-band and `_FailedRow` renders each one — a claim
about **us** in ADR-0004's shape, naming the person, with an honest next step. Deliberately not *"you
will not be warned"*, because the alarm may still be armed.

**The wrong guard was documented twice, in the same paragraph.** `ee0beed` replaced ADR-0006's false
claim that the lease serialises the access-lost cadence — with another false claim, that the
within-day dedupe does. It does not: `alreadyToday` sits *below* the transition and cause-change
branches, deliberately and per a recorded POCO F3 finding. What actually holds is a link-keyed
notification id plus both runs stamping the same day.

**`_reconcileBothSides` reconciles one side.** ADR-0007 cited it for both. Correct behaviour (the
watched side is repaired by `TapScreen`'s own observer), wrong name. Renamed to
`_reconcileWatcherSide`; ADR-0007 decision 3 now names both mechanisms.

**`uses24Hour` had two sources and the wrong one was authoritative** — the row and the notification
from the *same reconcile* could disagree about the same instant. Now one source:
`platformDispatcher.alwaysUse24HourFormat` on `ClockService`, awaited in `main()`, read off
`WatcherState` by the screen. The Tap screen's third formatter (*"9:14 AM"* against everywhere else's
*"9:14 am"*) folded into the same one.

**A second notification tap stacked a second `WatcherScreen`** — two lifecycle observers, two
reconciles per resume, and the first pop clearing the flag while one was still showing.
`WatcherScreen.isShowing` is now a counter owned by the screen, which also survives Phase 5's routing
on role.

Also fixed: the two health-flag writes sat outside the per-link isolation they were added beside;
`watched_zone_unknown` aggregated per-link data into a device-wide bool and moved onto
`WatchedPersonState` (the setting is gone); `main.dart` reached into `LocalStore` from a widget and
now goes through `AppServices.watches`; §5 and §6 amended for the new settings and `WatcherCopy`.

### One thing that could not be done as asked

The reviewer wanted three widget tests on `IAmOkApp`. **Pumping the app shell hangs**:
`WidgetTester` runs in a fake-async zone, `LocalStore` is real `sqflite` doing real I/O off that
zone, and the reconcile never completes — tests time out rather than fail. `runAsync` would let the
I/O through but takes the frame scheduler with it, and the Tap screen's indefinite progress
indicator rules out `pumpAndSettle` in any case.

`test/app_lifecycle_test.dart` asserts the two facts the shell *decides with* — `WatcherScreen
.isShowing` and `AppServices.watches` — and states this limit in its own docstring rather than
implying coverage it does not have. The three-line lifecycle glue stays on the device matrix.

---

## Known-open, carried deliberately

Nothing here is a false claim; all are honest gaps.

- **`link_reconcile_failed` and `warning_alarms_exact`** are written and read by nothing outside
  `dump`. §13's health panel consumes them in Phase 7.
- **`WatchedPersonState.zoneUnknown`** is computed and carried but no surface renders it. Same
  Phase 7 destination.
- **A warning erased by a force-stop is not re-posted** — `warningsShownFor` says it was shown.
  Accepted and recorded in ADR-0007 decision 4.
- **`ensureVisible` cannot reach a row far down a long list** — a lazy `ListView` never builds it.
  Mitigated with a cache extent; the real answer is fixed extents or a positioned list, and belongs
  with Phase 7's multi-person layout.
- **Screen-reader focus cannot be moved** to an arbitrary widget in Flutter. The tapped row is
  announced instead, and the code says so rather than implying focus.
- **§9's scheduled server-side function stays deferred.** ADR-0007 is the record of what that costs,
  and is now the strongest argument in the project for un-deferring it.

---

## Next steps, in order

1. **Run the remaining reviewers, one at a time, asking between each.** Suggested order:
   1. **testing** — most new material to check (`unreconciled` rows, the lifecycle file's honesty
      about its own limits, the contrast test, the 12-hour clock cases).
   2. **uiux** — four commits of new copy since it last ran: `couldNotCheckOn`,
      `couldNotCheckRemedy`, `warningsOff`, `showingPerson`, `couldNotCheck`, the "yet" removal, the
      dated `_moment` forms, the 12-hour variants.
   3. **security** — has seen none of this round. New material: the payload membership check, the
      untrusted-hint documentation on `NotificationRouter.tappedLink`, three new `LocalStore`
      settings, and `AppServices.watches`.
   4. **infrastructure** — has seen none of this round. New material: `onDowngrade`, the v1
      migration fixture, `AppTheme`, and the `contrastLevel` change.
   5. **architecture** — a short pass over `bbe68d5`, which it has not seen.
2. **Fix what they find**, committing per reviewer as before.
3. **Then the overnight Doze run** on the build you intend to keep. It is the last unobserved Phase 3
   device criterion.
4. **Then rewrite `docs/phases/phase-3-summary.md`** to record the settled state, and sign off the
   gate.

---

## Prompt to start the next session

> I'm continuing the Phase 3 gate review of the I Am Ok project. Read
> `docs/phases/phase-3-review-handover.md` first — it records what the five reviewers have found so
> far, what was fixed, and what is still owed. Then follow the reading order in `docs/README.md`.
>
> Head is `bbe68d5`, 744 tests pass, `flutter analyze` is clean. Three reviewers have run and been
> acted on; **testing, uiux, security, infrastructure and a short architecture re-pass are still
> owed**, and the overnight Doze device test is unstarted.
>
> Start with the **testing** reviewer. Run reviewers **one at a time** — never in parallel, that has
> twice exhausted the session limit — and after each one finishes, stop, report what it found, and
> ask me before running the next.
>
> Two things to carry with you. First, three of the last four review rounds found a defect introduced
> by the previous round's fix, so read your own recent changes as harshly as anything else. Second,
> this is the watcher side, where a false claim to a family is the worst bug the app can have —
> prefer stopping to ask over guessing, and if you think a finding is wrong, say so before acting on
> it rather than after.
