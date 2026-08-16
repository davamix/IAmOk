# Phase 3 — brief, and the exposure Phase 2 could not close

**Date:** 2026-08-17 · **Status:** Ready to start · **Phase 2 committed** as `9dbb2e7`

Phase 2 retired the OEM risk **for display-only alarms**, and in doing so found the thing that
threatens Phase 3 most. It is written up here in full, together with one open decision that should be
settled before the watcher alarm is written rather than after.

---

## Paste this as the first prompt

> I'm starting Phase 3 of the "I Am Ok" project. Read `docs/phases/phase-3-brief.md` first — it
> carries the exposure Phase 2 found and could not close, one decision to settle before writing the
> alarm, and the state to verify before writing anything. Then follow the reading order it gives.
>
> The watcher side is the half where a false claim costs everything, so prefer stopping to ask over
> guessing. If you think something in the brief is wrong, say so before implementing.

---

## Where things stand

Phase 2 built the four layers above the domain for the **watched** side, and verified them on the
POCO F3 with stock HyperOS power settings. `lib/` now has `domain/`, `data/`, `platform/`,
`application/`, `presentation/` and `copy/`.

| | |
|---|---|
| Commits | `5f07315`, `fa66c36`, `9dbb2e7` on `main`, not pushed |
| Tests | 524, all passing |
| Decision records | ADR-0001 … **ADR-0005** — all five binding |
| Phase 2 summary | [phase-2-summary.md](phase-2-summary.md) — read *Device testing* and *What to watch out for next* first; they are where Phase 3's problems are |

**What exists and Phase 3 will use:** `WatcherReconciler` and `WarningPolicy` (complete, from Phase
1), `LocalStore` with the full §6 watcher-cache schema (**written but nothing writes to it yet**),
`AlarmIds.warning(linkId, day)` and `AlarmIds.accessLost(linkId)`, `NotificationService` with the
`warnings` and `access` channels already created, `Clock`, and `PermissionService.delivery()`.

**What does not exist:** any background isolate, `android_alarm_manager_plus`, any watcher screen,
and any code that writes a `WatcherCache`.

### Verify before writing anything

```powershell
flutter analyze                                   # No issues found!
flutter test                                      # All tests passed!  (524)
dart run tools/models/away_warning_model.dart     # superseded: 4 failure(s)   decided: 0 failure(s)
pwsh -File tools/check-secrets-ignored.ps1        # OK - 19 paths ignored, 1 deliberately tracked
flutter build apk --debug                         # Built app-debug.apk
```

If the model line does not read `superseded: 4 / decided: 0`, stop — that is the ADR-0001 regression
guard and something has drifted. It also runs inside `flutter test`.

### Reading order

1. **[phase-2-summary.md](phase-2-summary.md)** — *Device testing* and *What to watch out for next*
   are the two sections Phase 3 depends on. The rest is context.
2. **`docs/architecture/ARCHITECTURE.md`** — §10 (the eight-step decision and the rolling window),
   §4 (isolates), §13 (health panel), §11 (time). Nothing may contradict it.
3. **`docs/architecture/decisions/`** — ADR-0001 through **ADR-0005**. ADR-0001 and ADR-0004 are
   the two Phase 3 executes; read them properly rather than skimming.
4. **`docs/PLAN.md`** — Phase 3's deliverables and exit criteria.
5. **`docs/ui-ux/screens.md`** — the four warning strings and the correction string, verbatim. Note
   its *"Still undecided, and owed before Phase 3 ships any of this"* list — see decision 2 below.
6. **`docs/testing/device-matrix.md`** — Phase 3 has a device exit criterion, and the section on
   reading alarms with `dumpsys` is not optional.

Then load `architecture-guidelines`, `testing-guidelines` and `ui-ux-guidelines`.

---

## The exposure Phase 2 found, which Phase 3 inherits without the fix

**Android cancels every one of an app's `AlarmManager` alarms when it is force-stopped, and nothing
tells the app.** Measured on the POCO F3:

```
fresh launch + reconcile  →  21 armed
force-stop                →   0 armed
reopen + reconcile        →   0 armed        ← before the fix: permanently inert
```

On HyperOS a force-stop is an **ordinary user action** — swiping from recents, "clear all", any task
killer. It is not an exotic state.

Phase 2's fix is that `reconcile()` re-asserts the whole desired set rather than the diff, so
reopening repairs everything. **That works because the watched person opens the app daily to tap.
The tap *is* the repair trigger.**

**Phase 3 has no equivalent, and this is the whole problem.** The watcher's alarm is logic-bearing,
and §13 argues in terms that a watcher never opens the app. After a force-stop:

- the warning alarms are gone;
- `BOOT_COMPLETED` will not help — a stopped app receives **no broadcasts at all**, and that state
  survives a reboot;
- FCM will not help either, for the same reason, so Phase 4 does not rescue this;
- `WorkManager` is cancelled by the same force-stop;
- nobody opens the app, so nothing triggers a repair.

The watcher goes permanently deaf, the family are told nothing, and **the failure is invisible from
both ends** — which is §17's High-severity silent failure, reached by one thumb.

Verified as having no manifest-side answer: the infrastructure review checked the boot receiver,
WorkManager, and a foreground service. Only the last works, and it costs a permanent notification,
a Play foreground-service-type declaration, and it contradicts *"the family are updated quietly"*.

---

## Decision 1 — settle the force-stop response BEFORE writing the watcher alarm

This is not a detail to discover halfway through. It changes what gets built.

**The candidates, honestly stated:**

| Option | Buys | Costs |
|---|---|---|
| **Accept + prevent + surface** — onboarding walks the family through Autostart / battery exemption / lock-in-recents; §13's health panel reports last-successful-reconcile age; dontkillmyapp.com link | No new mechanism. Matches what the design already plans for Phase 7. | The failure is still silent *while it is happening*. Prevention depends on a family member following instructions once. |
| **Foreground service** | Survives everything except an explicit force-stop, and makes the app visibly alive | A permanent notification on the watcher's phone, Play review for the service type, and it contradicts §1's "quiet" premise |
| **Un-defer §9's scheduled server function** | Server-side truth: it knows the check-in did not arrive and does not depend on the watcher's device running code | Cloud Scheduler, which HANDOVER.md ruled out and ARCHITECTURE.md §9 keeps as *"the documented escape hatch if §10's client alarms prove unreliable on real OEM hardware"*. **A force-stopped app does not receive FCM either**, so this only helps with a *notification-payload* message — which §1 rejects for the normal path. It would be a deliberate exception for the app-is-dead case. |

**My reading, offered rather than assumed:** ARCHITECTURE.md §14 names *"do alarms and data-only FCM
survive on Xiaomi with stock power settings"* as the trigger for un-deferring §9. Phase 2 answered
that **yes, for display-only alarms, when the app is not force-stopped**. That is genuinely good
news and it is not the whole question. Phase 3 measures the other half, and the sensible order is:

1. Build the watcher alarm on `android_alarm_manager_plus` as planned.
2. **Measure it on the POCO** — does the alarm isolate wake with the app swiped away, after a
   reboot, and after a day idle in Doze?
3. Then decide, with numbers rather than in the abstract.

So the decision to settle now is narrower: **agree that step 3 is a real gate with a real possible
outcome of "un-defer §9", rather than something to wave through.** If the measurement is bad, Phase 3
ends with an ADR and a scope change, not with a shipped warning that quietly does not fire.

Record the outcome as **ADR-0006** either way — including if the answer is "accept and prevent",
because that is exactly the kind of accepted risk ADR-0005 exists to stop being re-litigated.

---

## Decision 2 — the copy owed before any of this ships

`screens.md` names three items as *"owed before Phase 3 ships any of this"*, and they are all
user-visible:

- **The `contentTitle` / `contentText` split for all four warnings.** The reminders' split is settled
  and is the pattern to follow: title = "I Am Ok", body = the line. But the warnings' first words are
  load-bearing — *"No check-in…"* is a claim about her, *"Can't check on Mum —…"* is a claim about
  us — and the collapsed shade shows one line. Decide where the differentiator lives.
- **Where the refused notification routes on tap.** It says *"Open the app to see what to do."* There
  is no health panel until Phase 7, so decide what it opens now.
- **Whether the copy assumes "she".** Nothing in the domain captures a pronoun, so a watched father
  currently gets the wrong one throughout. This is cheap to fix now and expensive after translation.

Take these to the owner with concrete options rather than implementing a guess. Every approved string
goes in `screens.md` and through `uiux-reviewer`.

---

## Phase 3's own scope, unchanged

From PLAN.md. **Still fake local data — no Firebase.**

**Deliverables** — the alarm isolate (`android_alarm_manager_plus`), the self-verifying dead man's
switch, false-warning suppression, and the late-arrival correction.

**Exit criteria** — a warning fires when it should; is suppressed when a check-in is cached; is
suppressed when away covers the day; is replaced by a correction when a late check-in arrives; and
says something **different and honest** when the device cannot reach the network.

The domain for all of this **already exists and is tested**. Phase 3 is the edge: an isolate entry
point, persistence of `WatcherCache`, notification posting with the right ids, and a watcher surface.

---

## Carried non-negotiables

- **The alarm isolate is a bare isolate.** `@pragma('vm:entry-point')` top-level function, bootstraps
  what it needs, calls reconcile, exits. It shares no memory with the UI — no Riverpod, no in-memory
  cache. `test/domain/domain_purity_test.dart` has a **`bareIsolateSafe` list**; add the entry point
  and anything it reaches to it. The clock guard is an allowlist and already covers every file under
  `lib/`, so a `DateTime.now()` in the handler fails the build.
- **Never call `flutter_timezone` from the alarm isolate** (ADR-0002). Read `deviceTimezone` from
  `LocalStore`; the watched person's zone is on the link.
- **Apply `toCancel` before `toSchedule`.** `WatcherReconcileResult.warningsToReschedule` exists to
  make the trap visible. The watched side enforces the ordering inside `AlarmScheduler.apply`; do the
  same rather than trusting call sites.
- **Notification ids are `hash(link, D)`** — `AlarmIds.warning(linkId, day)`, both halves. A
  correction for one watched person must not touch a standing warning for another. Tested in
  `test/platform/alarm_ids_test.dart`.
- **Four warning outcomes, not three.** Which one fires is a correctness requirement.
- **`NotificationDelivery` now has a real producer.** `PermissionService.delivery(appInForeground:)`
  exists and `NotificationDelivery.from` decides. The Phase 2 brief's *"until they exist, pass
  `available`"* **no longer applies** — pass the real value, including the app's actual foreground
  state, or the whole of Decision 1 from Phase 2 is inert.
- **`warnAccessLost` never enters `warningsShownFor`** (ADR-0004). It lives in `accessLostSince` /
  `accessLostCause` / `accessLostNotifiedOn`.
- **Corrections and withdrawals are different channels.** A correction says she did check in; a
  withdrawal says nothing at all. Revocation withdraws; only a check-in for the warned day corrects.

---

## Traps Phase 2 paid for — do not re-learn these

- **Nothing inside the app can tell you what the OS actually holds.**
  `pendingNotificationRequests()` reads the notification plugin's own SharedPreferences, and no public
  API enumerates pending alarms. Ground truth is `adb shell dumpsys alarm` **written to a file and
  pulled** — piping it truncates and produced a false OEM finding once. Recipe in the device matrix.
- **The store records what you asked for, never what the platform holds.** Only one of those may be
  trusted. This is why Phase 2 asserts the whole desired set.
- **The API-level axis is a real gap.** Phase 2 shipped SQL that cannot parse below API 29 and it
  passed 500+ tests, because `sqflite_common_ffi` binds desktop SQLite and the only handset is API
  33. Phase 3 writes a lot of `WatcherCache` SQL. **`ON CONFLICT` and `RETURNING` are banned** by a
  source-level guard; an API 28 AVD run is owed.
- **A defect fixed is a defect to re-review.** Three times across two phases a fix introduced the next
  defect. The reviewers caught all three; the author caught none of them.
- **Boot recovery is delayed** (~76 s on this device). A check at 60 s reads zero and looks like a
  hard failure.
- **`upsertLink` cascades if written carelessly.** `INSERT OR REPLACE` deletes the row, and
  `watcher_cache` / `warnings_shown` cascade on delete — which would wipe every standing warning and
  the access-lost cadence anchor. Phase 3 is the first phase where that data actually exists.

---

## Already decided — do not re-open

- ADR-0001 … ADR-0005. If code disagrees, the code is wrong; if you believe an ADR is wrong, write
  ADR-0006 rather than diverging quietly.
- **The Tap screen says only who will be notified** (ADR-0005). Its rejection list is binding and a
  reviewer will flag the accepted exposure again — that is expected.
- The away cap is **31 days**; the rules clause is **`+32d`, deliberately slack**; the read-time
  sanity bound is **60 days**. Three numbers, three jobs.
- The access-lost cadence: day 0, 1, 3, then weekly, **as milestones passed rather than exact days**.
- The day is a local calendar label, never a UTC instant.
- Quiet confirm, loud miss. Away as one global document. No "away finished" message.
- `permission_handler` is deferred to Phase 7 (§15 records why).
- The scope boundary in `docs/HANDOVER.md` "Explicit non-goals".

---

## Protocol

1. Settle decisions 1 and 2 with the owner **before** writing the alarm.
2. Implement.
3. Run the reviewer agents — **all five** this time. `infrastructure-reviewer` matters here because
   `android_alarm_manager_plus` adds a plugin and a background entry point; it found the two most
   serious defects in Phase 2 and it was almost skipped.
4. **Measure on the POCO F3**, stock power settings first: does the alarm isolate wake with the app
   swiped from recents, after a reboot, and after a night idle in Doze? Read alarms with `dumpsys`.
5. Write `docs/phases/phase-3-summary.md`, with a device row per handset stating what actually
   happened. A checklist that records only passes is not evidence.
6. Stop for the owner's review before Phase 4.

Commit to `main` when the phase is done. Do not push unless asked.
