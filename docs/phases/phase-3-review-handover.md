# Phase 3 review — handover

**Written:** 2026-08-19 · **Head:** the testing re-review commit · **755 tests**, `flutter analyze`
clean, `flutter build apk --debug` succeeds.

This document exists because the Phase 3 gate review ran long enough to span sessions. It records
what the reviewers found, what was fixed, what is still owed, and how to pick it up.

**Phase 3 is NOT signed off.** Three of five reviewers have run and been acted on; two have not run
at all, and the overnight Doze device criterion is unstarted.

---

## The one-line story

Five reviewers were launched at the Phase 3 gate. They found two criticals — one of them
independently by three of them — and roughly thirty further findings, on code whose self-review had
come out clean. Acting on those findings produced five more rounds, and **four of those rounds found a
defect introduced by the previous round's fix**. The testing round continued the pattern: the commit
that fixed `uses24Hour`'s two sources left the setting written once at launch inside another call's
`try`, its only test-level coverage absent, and two docstrings broken — one still arguing for the read
it had just deleted.

That pattern is the reason the remaining reviewers should run before the Doze night rather than after,
and the reason each round now re-reads the previous round's diff first.

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
| *this one* | The **testing** re-review at the gate |

---

## Reviewer status

| Reviewer | Last run | Outcome |
|---|---|---|
| **testing** | **at the gate, over `bbe68d5`** | All findings fixed — see the round below. |
| **architecture** | at `bbe68d5` | All findings fixed. **Has not seen `bbe68d5` itself.** |
| **uiux** | at `c347315` | All findings fixed. Has not seen the five commits since. |
| **security** | never, this round | Has seen none of it |
| **infrastructure** | never, this round | Has seen none of it |

### Standing rule

**Never run reviewers in parallel, and ask before running any.** Two parallel launches exhausted the
session limit. The working pattern is: run one, report, fix, ask before the next.

---

## The architecture round on Tiers 3-5 (`bbe68d5`)

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
implying coverage it does not have.

> **Corrected by the testing review.** This paragraph ended *"The three-line lifecycle glue stays on
> the device matrix"*, and it was on no row of that matrix — the nearest row covers a **launch**,
> which is a different code path from a resume. The decision inside the glue has since been hoisted to
> `IAmOkApp.repairOnResume` and unit-tested; the wiring that remains now has its own unchecked matrix
> row.

---

## The gate round — testing over `bbe68d5`

Verdict: **coverage is adequate for Phase 3.** The mandatory list is complete, the purity guard is
stronger than `strategy.md` asks for, and the device evidence records failures rather than ticks.
Nine findings, all fixed, and the two that mattered were both new material from this review round.

**The 12-hour clock was asserted on the notification and on nothing else.** `watcher_screen_test`
declared `uses24Hour = true` and never passed `false` from any of its sixty tests, and the only
time-bearing assertion was `textContaining('This phone last checked')` — which passes for `10:00`,
`10:00 am` and `Sunday 10:00` alike. So the drift `bbe68d5` was written to prevent was caught by
nothing: `flutter_test` defaults `alwaysUse24HourFormat` to **false**, so restoring the `MediaQuery`
read would render `10:00 am` on the row under a notification reading `10:00`, with the suite green.

Underneath it, two real defects rather than only a gap. `LocalStore.uses24HourClock` had **no coverage
at any level**, and its docstring claimed *"The UI writes it on every resume"* when the single call
site was in `main()` — so a reader who changed the setting kept the old format for the life of the
process, and because that write shared a `try` with `flutter_timezone`, a plugin hiccup at launch left
a 12-hour device on the 24-hour default for the whole session. `_cacheDeviceFacts` now writes both
device facts, under **separate** guards, on launch and on every resume.

**The resume repair's decision lived where only a device could reach it.** Invert
`didChangeAppLifecycleState`'s guard and a force-stopped watcher never re-arms an alarm again — with
every test green and, as it turned out, no device row either. It is now
`IAmOkApp.repairOnResume`, a two-input predicate with its truth table asserted, and the wiring that
genuinely needs hardware is a matrix row instead of a claim in a docstring.

Also fixed: an announcement test that asserted a copy constant and passed with
`sendAnnouncement` deleted; a counter test that swapped the widget tree instead of pushing and popping,
so the two instances never coexisted; `phase-3-summary.md` claiming *"The five reviewers have now run
and reported"* with a stale test count beside it; `strategy.md` and the testing skill both calling a
**31-day** away period a *rejected* case when 31 is the longest allowed and 32 is rejected — a spec
that would walk the next reviewer into a false finding against correct code; two unasserted
`onSurfaceVariant` contrast pairs including the disabled tap target, which is the state that screen is
in most of the day; a "one seed" test that only checked that the brightnesses differed; a
process-global counter unwound by a line a failing test would skip; and the two docstrings `bbe68d5`
landed broken — one with its identifiers missing, one still arguing for the `MediaQuery` read it had
just removed.

Both blocker fixes were mutation-checked rather than assumed: the announcement test and the
guard-separation test were each confirmed to **fail** against the defect they describe, then the code
restored.

---

## Known-open, carried deliberately

Nothing here is a false claim; all are honest gaps.

- **`link_reconcile_failed` and `warning_alarms_exact`** are written and read by nothing outside
  `dump`. §13's health panel consumes them in Phase 7. (Both now have store round-trips as well as
  behavioural coverage through the service.)
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
   1. ~~**testing**~~ — **done at the gate.** Verdict: coverage adequate for Phase 3. Its two
      sign-off blockers (the unasserted 12-hour row, the resume guard only a device could reach) are
      fixed, along with seven lesser findings.
   2. **uiux** — **next.** Five commits of new copy since it last ran: `couldNotCheckOn`,
      `couldNotCheckRemedy`, `warningsOff`, `showingPerson`, `couldNotCheck`, the "yet" removal, the
      dated `_moment` forms, the 12-hour variants — and now the 12-hour row assertions, which pin the
      exact rendered strings it will want to check against `screens.md`.
   3. **security** — has seen none of this round. New material: the payload membership check, the
      untrusted-hint documentation on `NotificationRouter.tappedLink`, three new `LocalStore`
      settings, and `AppServices.watches`.
   4. **infrastructure** — has seen none of this round. New material: `onDowngrade`, the v1
      migration fixture, `AppTheme`, and `contrastLevel` (now public, so the contrast test can assert
      both schemes come from the seed at the declared level).
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
> Head is the testing re-review commit. 755 tests pass, `flutter analyze` is clean, and
> `flutter build apk --debug` succeeds. Three of the five reviewers have run and been acted on —
> testing most recently, at the gate itself; **uiux, security, infrastructure and a short architecture
> re-pass over `bbe68d5` are still owed**, and the overnight Doze device test is unstarted.
>
> Start with the **uiux** reviewer. Run reviewers **one at a time** — never in parallel, that has
> twice exhausted the session limit — and after each one finishes, stop, report what it found, and
> ask me before running the next.
>
> Two things to carry with you. First, four of the last five review rounds found a defect introduced
> by the previous round's fix, so read your own recent changes as harshly as anything else. Second,
> this is the watcher side, where a false claim to a family is the worst bug the app can have —
> prefer stopping to ask over guessing, and if you think a finding is wrong, say so before acting on
> it rather than after.
