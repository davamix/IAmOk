# Phase 7 — UI/UX and the health panel · brief

**Opened:** 2026-09-01, at the end of Phase 6.

**Deliverables** (PLAN.md) — the watcher list (multiple watched people, status per row, away action),
**the health panel**, and cold-open state.

**Cold open** — an *unresolved* warning if one stands, otherwise *"Everything OK"* with the last
check-in time. The current state, **not the most recent warning ever fired**: a warning from three
weeks ago followed by three weeks of check-ins is history, not status.

---

## Read this first, because two of the three deliverables are largely built

Phase 6's brief opened by saying more of away existed than its deliverable list suggested, and that
turned out to be the most useful section in it. **The same is true here, more so.** The watcher list
has been built and rebuilt across Phases 3, 5 and 6; cold-open state is already what the list does.
If this phase is planned from the deliverable line alone it will re-implement two surfaces that work
and leave the one that does not exist until last.

| Deliverable | Where it actually stands |
|---|---|
| **The watcher list** | **Built.** Multiple people (`ListView` over `people` + `unreconciled`), a status per row, the away row and action, the tapped-row highlight, the lost-access remediation, announcements under TalkBack. Phase 6 added the away row and its two controls |
| **Cold-open state** | **Built, and tested as a rule** — `watcher_screen_test.dart`'s *"state, not history"* group asserts *"Everything OK"* plus the last day when no warning stands. Verify it end to end rather than build it |
| **The health panel** | **Does not exist.** No screen, no domain type, no route. This is the phase's real work |

**What exists of health today is two banners and a snapshot**: `PermissionSnapshot` carries
`notifications`, `exactAlarms` and `allGood`; the Tap screen shows a red band reading *"This phone
will not remind you to tap."* with *Turn reminders on*; the watcher screen shows *Turn warnings on*.
Both were seen working on hardware on 2026-09-01. §13's table has **eight rows** and those cover two
of them.

---

## Prompt to start the session

> I'm starting **Phase 7 — UI/UX and the health panel** of the I Am Ok project. Read
> `docs/phases/phase-7-brief.md` first, then follow the reading order in `docs/README.md`.
> `docs/phases/phase-6-summary.md` is the previous phase — read *The gate review*, *The device run*
> and *Still owed*. `docs/OPEN-QUESTIONS.md` lists what is deliberately unsettled, and **two of its
> entries become blockers in this phase**: #8 and #9. Read the *Blocking-when* table rather than
> re-deriving any of it.
>
> **Two of the three deliverables are already built** — the watcher list and cold-open state. The
> health panel does not exist at all. Start from *Read this first* in the brief so the phase is spent
> on the surface that is missing rather than on two that work.
>
> **Build and test against the local Firebase Emulator Suite**, as Phases 4, 5 and 6 did. A real
> Functions deploy is neither needed nor wanted here and would still fail — four 2nd-gen APIs are
> missing, enabling them is billable, and it is the owner's call.
>
> **Where Phase 6 left things.** Built, **the five reviewers run TWICE — once over the phase, once
> over the close-out** — every applied finding verified by reverting it, **run on two API 36 AVDs and
> then on the POCO F3** with every device-checklist row answered and all three exit criteria met on
> hardware, and **all seven owner decisions taken and applied**. 1 380 Dart tests, 102 Functions
> tests plus a fourth no-emulator run, 82 rules tests, 34/34 mutations caught, `flutter analyze`
> clean, debug APK builds, secrets guard clean. **Not signed off**: Doze on the handset is unmeasured,
> §12's four away transition notifications are specified and deliberately not built, and the second
> gate left **four decisions for the owner** — read *What Phase 6's second gate leaves on this desk*
> below before planning, because two of them are one edit away from Phase 7's own surfaces.
>
> **`firestore.rules` is CHANGED and NOT DEPLOYED**, and the live ruleset still carries the set-once
> defect. A plain `flutter build apk --debug` is a **production** client, so anything not built with
> `--dart-define=IAMOK_EMULATOR_HOST` will hit rules that refuse a second away period for ever.
> `deploy-notes.md` said the opposite until 2026-09-01 and is now correct.
>
> **The rig is warm and worth reusing.** Two AVDs and the POCO all have the app installed and paired
> — Mum (watched), Ana (watcher of both), Pop on the POCO (watched) — and `emulator-data/` holds the
> 2026-09-01 export of all of it. `tools/emulators.ps1 -Device 1720f883` sets up `adb reverse`.
> **Warm the Functions emulator with one `curl` before driving a phone.**
>
> **This phase opens with owner decisions** — see *The decisions this phase opens with*. Do not
> decide them alone.

---

## What Phase 6's second gate leaves on this desk

Five reviewers over the close-out, 2026-09-01. Nine findings applied, **four held for the owner**,
and a handful of observations that land squarely in this phase's surfaces. The full write-up is
`phase-6-summary.md`'s *The second gate*; what belongs here is the part Phase 7 will trip over.

**The four owner decisions — none is a Phase 7 deliverable, but two touch its screens:**

| | Why Phase 7 cares |
|---|---|
| `awayPeriodEnded()` is permissive west of UTC | Rules-only. Decide it before any deploy, not before any screen |
| `allow delete` is unconditional | Rules-only, but the **access matrix** in `firestore-rules-guidelines.md` currently disagrees with the file. Fix the disagreement before the health panel cites either |
| ~~`pickerTitleFor` has no fallback~~ | **Closed 2026-09-01, at the source.** A person whose Google account has no display name is now asked for one before `users/{uid}` is written, so no link can carry `Someone`. Phase 7 inherits **no work** here — but it inherits the rule: a name reaching a surface comes from `link.watchedName`, and the health panel's per-person rows will name people the same way |
| The queued-cache rule is not in ARCHITECTURE.md | Write it before the panel reads `self_away`, or the panel will be the second reader of a rule the design does not state |

**Two things this phase's own layout will meet:**

- **`WatcherScreen` has no midnight timer.** The Tap screen has one and holds a named
  `clockExemptions` entry for it. A watcher who leaves the list open across watched-local midnight
  gets a picker bounded to yesterday and a refusal about a day the screen just offered. A panel that
  renders *last sync* or *today's status* per row has exactly the same staleness, on more rows.
- **`emulator-data/` holds four accounts and four links, not three and two** — including a stale
  Phase-4 Ana and a deliberate **self-link**. A health panel driven off the imported rig will meet
  both on its first run, and a self-link is the row most likely to be assumed impossible.

**Two carried gaps worth knowing before the panel is designed**, both pre-dating Phase 6's close-out:

- The reconcile lock reads `away` and `checkedIn` **before** the lease and `pendingReminders`
  **after** it, under a comment saying reading before the lock *"is the whole defect"*. A panel
  reporting *last reconcile* will be reporting on this.
- The 6-second away read is on `build()`'s and `tap()`'s critical path, so a captive portal costs six
  seconds of bare spinner. Any *backend access* row in §13 is measuring that same call.

**And one habit this gate is the second piece of evidence for:** both times the reviewers ran, the
sharpest findings came from reading a claim against the thing it describes — not from a test failing.
`deploy-notes.md`, the recorder knob no test turned, and the migration claim that had been false for
days were all found that way, and the suite was green throughout.

---

## What already exists, and what emphatically does not

**Exists, and this phase must not rebuild it:**

- **`PermissionService`** — `notificationsEnabled()`, `canScheduleExactAlarms()`, `snapshot()`
  returning `PermissionSnapshot(notifications, exactAlarms)`, and `reminderDelivery()`.
- **`NotificationDelivery` and `WatcherDelivery`** — the domain's answer to *can this device
  actually post*, already threaded through both reconcilers and both screens. The health panel is a
  **reader** of this machinery, not a second implementation of it.
- **The two banners**, with approved copy, on both main screens.
- **Resume-time re-checking** — permissions are re-read on every app resume, which is §13's
  *"continuously observed state, not a one-time gate"* already true in the code.

**Does not exist:**

- Any **health screen or route**, and any domain type that says what *healthy* means. There is no
  `Health` anything in `lib/`.
- Six of §13's eight rows: battery optimisation, auto-revoke exemption, last sync, clock skew,
  backend access, background deferral.
- Any surface for **`warning_alarms_exact`** or **`WatchedPersonState.zoneUnknown`** — both are
  computed and stored, and read by nothing outside `dump()`.
- **Clock-skew detection itself.** Checked while writing this brief, because §13 lists a *clock skew*
  row and the natural assumption is that the value exists and needs a surface. It does not.
  `ClockService` has exactly two members — `deviceTimezone()` and `uses24HourClock()` — and nothing
  in `lib/` computes device-versus-server skew. **Three documents say otherwise**:
  [ADR-0002](../architecture/decisions/0002-clock-split.md) puts *"device-vs-server skew detection"*
  in `ClockService`'s row twice, ARCHITECTURE §11 says skew is *"detected, not silently corrected …
  on app open while online"*, and `.claude/skills/architecture-guidelines` repeats it. The only skew
  **signal** that exists is `receivedAt` on a check-in — `serverTimestamp()` beside the device's own
  `deviceTappedAt` — and nothing compares them. So that row is **build, not surface**, and the three
  documents need correcting either way.

### `OPEN-QUESTIONS.md` #8 is half true, and the half that changed is worth knowing

It says four fields are *"written and read by nothing outside `dump`"* and that §13's panel consumes
them in Phase 7. **Two of the four grew surfaces in Phases 5 and 6 and the entry did not notice:**

| Field | Now |
|---|---|
| `uses_24_hour_clock` | **Surfaced.** Every time on the watcher list renders in the device's own 12/24-hour setting — seen on hardware 2026-09-01: *"10:43 am"* on the AVDs, *"11:37"* on the POCO |
| `link_reconcile_failed` | **Surfaced.** `WatcherState.unreconciled` renders its own rows beneath the people, with *Try again* |
| `warning_alarms_exact` | Still nothing. Written by the watcher reconcile, read by `dump()` alone |
| `WatchedPersonState.zoneUnknown` | Still nothing. Carried through the service and never rendered |

**That entry was corrected on 2026-09-01, while this brief was being written**, rather than left for
this phase to inherit — it is the same failure mode Phase 6's gate found eleven times: a claim
written when it was true and left standing after it stopped being. The two rows that remain are what
the panel consumes.

---

## The design decisions already made — do not re-litigate these

- **§13 is the specification.** Eight rows, each with an API and a stated consequence. The panel
  shows green/red per item and is **always reachable** — not an onboarding step, because Android
  auto-resets permissions for unused apps and a watcher who never opens the app is exactly that user.
- **Backend access is not "offline".** [ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md):
  a **refused** read is a fault with a remedy — sign in again, update the app — and an unreachable
  one is neither a fault nor actionable. The panel must keep them apart, and the remediation text
  differs by refusal cause. `RefusedCause` and `WatcherCopy.accessLostRemedy` already exist.
- **Background deferral is amber and standing**, not actionable, and it **cannot report a deferral in
  progress** — a queued JobScheduler job is not observable from inside the app
  ([ADR-0008](../architecture/decisions/0008-the-warning-is-late-in-doze-and-the-app-says-so.md)).
  It states a property of the device; *Last sync* reports the consequence after the fact.
- **Colour is never the only signal** — every row carries text. `guidelines.md`'s floor, and it is
  the one most likely to be broken by a panel of green ticks.
- **One screen, one action** still governs the Tap screen. The health panel is reachable **from** it,
  not resident on it.

---

## The decisions this phase opens with — **OWNER**

Recorded here so they are put before anything is built, as Phase 6's away-line decision was.

1. **Where the health panel lives, and how an 80-year-old reaches it.** The Tap screen has one
   action by design and already carries a red band when something is wrong. Options: the band becomes
   the entry point (nothing new on screen when all is well); a permanent secondary control; or the
   panel is watcher-only, on the argument that the watched person's failures are already surfaced by
   the band and the watcher's are not. **This is the decision the phase turns on** — it decides
   whether the panel is a screen a family member opens or a thing the app shows when it matters.
2. **What the panel says when everything is fine.** *"Everything is working"* is a claim about a
   device that has not been tested since resume; saying nothing is worse for a watcher who opened it
   precisely to check. `guidelines.md` forbids claiming more than the device knows.
3. **Whether §12's four away transition notifications land here.** Deferred from Phase 6 with the
   deliverable list's backing, **except the cancellation notice**, which is a §17 gap: once a period
   is truncated `setByName` is gone, so a watcher can silently end somebody's away period and no
   surface can ever say who did.

---

## What Phase 6's close-out changed that this phase touches

- **`AppServices.awayDocument` is injectable**, and `watchedReconcile` uses that instance. The
  composition root now has one seam of this shape; a health panel that needs its own fakes should
  follow it rather than invent a second pattern.
- **A queued away write is cached on the phone that wrote it** (`WatchedNotifier._cacheQueued`),
  bounded by the rule that the first read to succeed overrules it. If the panel ever reports *"last
  sync"* or *"pending changes"*, this is the state it will have to describe honestly.
- **The watcher row now confirms before ending a period**, and says when a write lands. The Tap
  screen deliberately does neither. **The asymmetry is a decision**, recorded in `screens.md` — do
  not "harmonise" it.
- **The picker title names the person on a watcher's phone.** The same trap applies to every string
  this phase writes: a sentence that is right on one surface can name the wrong person on the other,
  and a widget test will not see it.

---

## Emulator-first, still

Nothing here needs a deploy. The panel reads device state and the local store; the only backend fact
it surfaces is *the last read was refused*, which the emulator can produce by revoking a link or
tightening a rule. `firestore.rules` **changed in Phase 6 and is not deployed** — that is fine while
everything points at the emulator, and it is the first thing to fix if any build is ever pointed
elsewhere (`deploy-notes.md`'s ordering rule).

---

## What is not a blocker

- **Doze on the handset**, carried from Phase 6. It affects what the *background deferral* row should
  say, not whether the panel can be built. If it is measured during this phase, that row can stop
  being a statement about the device class and become one about this device.
- The first Functions deploy, App Check's console half, the live-radio measurement, ADR-0008 option
  1's cost, and `InviteCode.forSpeaking` — all carried, none of them in the way.

---

## How this phase is expected to go wrong

**A panel of green ticks that is itself never checked.** The failure mode here is a health screen
that reports healthy because nothing tested the unhealthy path — the exact shape of the Phase 4
defect where `warningsShownFor` recorded a warning shown to nobody. Every row needs its red case
tested, and `strategy.md`'s rule applies with force: **assert the silent case as hard as the firing
one**.

**Claiming more than the device knows.** Six new rows means six new chances to say *"everything is
working"* about a permission the app last checked at resume, or to call a refusal an outage. The four
warning messages exist because this app already learned that lesson once.

**Rebuilding the watcher list.** It is built, it has been through three gates and two device runs,
and its row logic carries decisions — the away row's position above *"Everything OK"*, the keying on
*her* today, the exclusion of a revoked link from the away control — that a rewrite would quietly
drop.

**#9 will bite.** `ensureVisible` cannot reach a row far down a lazy list, and this phase is the one
that makes long lists real. The recorded answer is fixed extents or a positioned list; it is not
"add more cache extent".
