# Phase 3 review — handover

**Written:** 2026-08-19 · **Head:** the UI/UX re-review commit · **770 tests**, `flutter analyze`
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

The UI/UX round then found that the *previous* fix to the same screen had shipped the one error phrase
`guidelines.md` bans by name, and that raising the contrast level to fix the light palette had pushed
a different pair — the button inside the warnings-off banner — from about 5:1 down to **2.33:1**.

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
| `7311a33` | The **testing** re-review at the gate |
| *this one* | The **UI/UX** re-review at the gate |

---

## Reviewer status

| Reviewer | Last run | Outcome |
|---|---|---|
| **uiux** | **at the gate, over `7311a33`** | All findings fixed — see the round below. |
| **testing** | at the gate, over `bbe68d5` | All findings fixed. Has not seen the UI/UX commit. |
| **architecture** | at `bbe68d5` | All findings fixed. **Has not seen `bbe68d5` itself**, nor the two gate commits since. |
| **security** | never, this round | Has seen none of it |
| **infrastructure** | never, this round | Has seen none of it |

### Standing rule

**Never run reviewers in parallel, and ask before running any.** Two parallel launches exhausted the
session limit. The working pattern is: run one, report, fix, ask before the next.

**And verify a finding before acting on it.** Both gate rounds so far produced at least one finding
whose severity moved once it was checked against the code: the UI/UX round estimated a contrast
failure at "roughly 3:1, treat as an estimate" and it measured **2.33:1, in both modes**; it also
filed the missing away row as a shipping defect when no user can reach that state until Phase 6.
Measuring took two minutes in each case.

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

## The gate round — UI/UX over `7311a33`

Two findings worth holding the gate for, both in material the reviewer had not seen, and both on
surfaces it had itself approved a round earlier.

**The watcher list shipped *"something went wrong"*.** `guidelines.md`'s Floors table bans that exact
phrase — *"Say what happened and what to do"* — and `WatcherCopy.couldNotCheckOn` contained it
verbatim, on the row a family member reaches by tapping the *lost access* notification, whose entire
justification (ADR-0004) is that it is actionable. Two other files quote the ban back in their own
comments, so the rule was known and applied everywhere except the one place a family would read it.

That is what a source-level test is for, and there now is one: `test/copy/copy_floors_test.dart`
reads `lib/copy/` as text and asserts the four bans that can be checked mechanically — the phrase,
exclamation marks, emoji, and numeric dates. Mutation-checked: reintroducing the string fails it.

**The button inside both warnings-off banners was illegible, and the previous round made it worse.**
A bare `TextButton` takes its label colour from `colorScheme.primary`, which is measured against
`surface` — not against the `errorContainer` painted behind it. The reviewer estimated ~3:1 and
flagged the number as an estimate; measured, it is **2.33:1 in light and 2.31:1 in dark**, against a
4.5 floor. `errorContainer` darkens as `contrastLevel` rises while `primary` does not move, so
`c690b1b` — the commit that raised the level to fix the light palette's AAA misses — pushed this pair
down. It is the one control that turns notifications back on, inside the banner that exists because
they are off. Both banners now set `foregroundColor` explicitly, asserted as a ratio in
`contrast_test.dart` and as wiring in both screens' widget tests.

Also fixed: *"It will try again."* was a promise the device cannot keep — `alarms.apply` is among the
throws the per-link guard catches, so a link whose window was never armed has nothing scheduled to
retry with, and the row told the reader to wait. The row carries a **"Try again"** control instead,
which also closes an accessibility floor breach (pull-to-refresh was the only route to retrying, and
a drag is the gesture a screen-reader user is least able to perform). The button sits *outside* the
row's `Semantics`/`ExcludeSemantics` pair, or it would be invisible to exactly the reader it was
added for — asserted with `matchesSemantics`. `screens.md` had **two contradictory approved strings**
for "Nobody is watched" and the shipped one matched neither; it also claimed the watcher list reads
`MediaQuery` live, which `bbe68d5` had made false. The single-digit 12-hour form (*"9:14 am"*, no
leading zero) was produced by the code and pinned in neither the tests nor `screens.md`. The
`isEmpty` early return still hid the warnings-off banner on an empty list. `NotificationCopy._time`'s
docstring still argued for the hard-coded 24-hour clock it no longer had.

### One finding whose severity moved on inspection

The reviewer filed the **missing away row** as a Medium shipping defect: a verified away period falls
through to *"Everything OK"*, while `screens.md` approves *"Away until Sat 22 Aug — set by Ana"*.

The behaviour is real, but no user can reach it. The Tap screen's *"I'm away"* action is
`onPressed: null` until Phase 6 and there is no backend to carry a period, so the state exists only
behind a debug-harness control. Building the row now would also produce an **unattributed** away
state — `AwayPeriod` has no `setBy`/`setByName` until Phase 6 — which the same guidelines forbid.
So it is recorded as a decision in `screens.md` and the phase summary rather than built, and it lands
in Phase 6 with the attribution that makes it honest.

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
   2. ~~**uiux**~~ — **done at the gate.** Ten findings, all fixed. The two that mattered were a
      banned error phrase shipping on the watcher list, and an illegible button in both warnings-off
      banners that the previous round had made worse.
   3. **security** — **next.** Has seen none of this round. New material: the payload membership check, the
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
> Head is the UI/UX re-review commit. 770 tests pass, `flutter analyze` is clean, and
> `flutter build apk --debug` succeeds. Three of the five reviewers have run and been acted on —
> testing and UI/UX most recently, both at the gate itself; **security, infrastructure and a short
> architecture re-pass over the three gate commits are still owed**, and the overnight Doze device
> test is unstarted.
>
> Start with the **security** reviewer. Run reviewers **one at a time** — never in parallel, that has
> twice exhausted the session limit — and after each one finishes, stop, report what it found, and
> ask me before running the next.
>
> Two things to carry with you. First, five of the last six review rounds found a defect introduced
> by the previous round's fix, so read your own recent changes as harshly as anything else. Second,
> this is the watcher side, where a false claim to a family is the worst bug the app can have —
> prefer stopping to ask over guessing, and if you think a finding is wrong, say so before acting on
> it rather than after.
