# Device matrix

**Date:** 2026-08-17 · **Status:** Primary physical device confirmed **and exercised — Phase 2
passed every criterion here on stock power settings.** Sufficient for Phases 2–3; **Phase 4 needs a
second handset** and two coverage gaps are named below.

## Build targets

| | Value | Source |
|---|---|---|
| minSdk | **24** (Android 7.0) | Flutter default, verified via `aapt2 dump badging` |
| targetSdk / compileSdk | **36** | Flutter default |
| applicationId | `io.github.davamix.i_am_ok` | Permanent once published |
| Platforms | **Android only** | `flutter create --platforms=android` |

minSdk 24 matters here more than usual: the watched user's phone is likely to be old.

## Available now

| Device | Kind | Android | Notes |
|---|---|---|---|
| **POCO F3** — `M2012K11AG`, codename `alioth`, arm64 | **Physical** — the owner's own phone | **13 (API 33)** | Xiaomi **HyperOS `OS1.0`**, MIUI build `V816.0.6.0.TKHEUXM`, security patch 2024-03-01. Confirmed over adb 2026-08-15; **Phase 2 run 2026-08-17, all criteria pass on stock settings.** |
| `Medium_Phone_API_36.0` | Emulator AVD | 36 | Verified present. Useless for the questions that matter — see below. |

**This is the best possible primary device for this project, and that is not a compliment to the
phone.** It satisfies both priority-1 rows at once — it is a handset in real daily use — while
also being the priority-2 vendor the matrix singles out as the most aggressive killer of
background work. If the design survives here with stock settings, the OEM risk that Phases 2 and 3
exist to retire is largely retired.

```powershell
flutter devices
& "D:\Android\Sdk\platform-tools\adb.exe" devices -l          # when a device will not appear
& "D:\Android\Sdk\platform-tools\adb.exe" shell getprop ro.build.version.sdk
flutter emulators --launch Medium_Phone_API_36.0
```

## What the emulator cannot answer

Everything this matrix exists for. An emulator has no OEM power management, no Doze that behaves
like a real one, and no vendor app-killer. It will happily report that alarms fire perfectly and
data-only FCM always arrives, and that result carries no information about a real phone.

The riskiest unknown in the whole project, named in [HANDOVER.md](../HANDOVER.md) and unchanged by
the architecture pass: **do alarms and data-only FCM survive on Xiaomi / Samsung / Huawei with
stock power settings?**

## Devices worth covering

Priority order, by how much they threaten the design rather than by market share.

| Priority | Vendor | Status |
|---|---|---|
| 1 | **Whatever the watched person will actually use** | **Not yet identified.** The only device that has to work. |
| 1 | **Whatever the watcher will actually use** | **Covered** — the POCO F3 above is the owner's phone. Auto-revoke risk lands here. |
| 2 | Xiaomi / Redmi / POCO (MIUI / HyperOS) | **Covered by the same device.** Also needs "Install via USB" to sideload at all. |
| 2 | Samsung (One UI) | Not covered. Largest install base; "Put unused apps to sleep" is on by default. |
| 3 | Huawei (EMUI) | Not covered, and probably never — no Play Services, so **FCM does not work at all**. That is a decision, not a fix. |
| 4 | A stock-Android device (Pixel or similar) | Not covered. The control that distinguishes "our bug" from "their power manager". |

> **The watched person's handset is still unidentified**, and it is the one device that genuinely
> has to work. Not blocking Phases 2–3 — the POCO is a harsher environment than most, so passing
> there is strong evidence — but it should be identified before Phase 8, and ideally before Phase 4
> so the pairing flow is exercised on the hardware it will actually run on.

### The API-level axis, which the vendor axis does not cover

Vendor spread alone is not enough, because the permission model this app depends on changes by API
level, and the watched person's phone is likely to be old — minSdk is 24 for a reason.

| API | What changes | Covered? |
|---|---|---|
| 24–29 | The floor. No runtime notification permission at all. **Also: SQLite is older than 3.24 below API 29, so UPSERT (`ON CONFLICT … DO UPDATE`) is a parse error — and the test suite cannot see it, because `sqflite_common_ffi` binds a modern desktop SQLite.** A source-level guard is in `test/data/local_store_test.dart`; an API 28 AVD run is owed before Phase 4. | No |
| 30 (11) | **Auto-revoke of permissions for unused apps** begins — the silent watcher-killer. | **Yes** — POCO F3 |
| 31 (12) | `SCHEDULE_EXACT_ALARM` becomes revocable; `canScheduleExactAlarms()` starts mattering. | **Yes** — POCO F3 |
| 33 (13) | `POST_NOTIFICATIONS` becomes a runtime permission. Without it the app is inert. | **Yes** — POCO F3 |
| 34+ (14+) | Exact alarms no longer auto-granted; `USE_EXACT_ALARM` is the route, and Play review asks about it. | **No — real gap** |

One further known property, recorded so it is not a surprise: `flutter_local_notifications` computes
the fire instant in Java with `java.time`, which on API 24/25 is the **desugared** implementation
reading the *device's* tzdata — not `package:timezone`'s compiled-in database. On a phone that never
received a tz update the two can disagree around a DST-rule change, putting a reminder an hour out.
Low risk for Europe/Madrid, whose rules are stable.

**The API 34+ gap is the one to keep in view.** The app sets `targetSdk 36` but the only physical
device runs API 33, and several of these behaviours are gated on the *device's* API level rather
than on targetSdk. So the exact-alarm tightening that `USE_EXACT_ALARM` exists to satisfy — the
permission Play review will question at Phase 8 — is not exercised on hardware at all.

The `Medium_Phone_API_36.0` AVD covers the *framework* side of that gap (permission prompts, exact
alarm gating, auto-revoke) and is worth running for it. What it cannot cover is whether any of it
survives an OEM power manager, and no emulator ever will. Treat the emulator as the API-level
check and the POCO as the reliability check; neither substitutes for the other.

## HyperOS / MIUI — what makes this device the hard case

Xiaomi layers its own background management on top of Android's, and it is stricter. These are the
settings that decide whether this app works at all, and the reason the POCO is the right primary
target rather than a bad one.

| Setting | MIUI default for a sideloaded app | Effect if left alone |
|---|---|---|
| **Autostart** | **Off** | The app cannot be woken by an alarm or a broadcast after being swiped away or rebooted. This is separate from Android's battery optimisation and is the single most common cause of "my alarm app stopped working" on Xiaomi. |
| **Battery saver** (per-app) | "Battery saver" — restricted | Background work is throttled or killed. "No restrictions" is the permissive setting. |
| **Lock in recents** | Off | Kills the **process**. Measured 2026-08-18: it does **not** cancel alarms, does not clear notifications, and does not put the app in the stopped state — see the correction below. |
| **Install via USB** | Off | Cannot sideload at all until enabled. |
| **MIUI Optimization** (developer options) | On | Changes permission and notification behaviour in ways that do not match stock Android. |

**Test stock first, and record it.** The default state is the state real users are in, and the
design's actual question — from ARCHITECTURE.md §14 — is whether alarms and data-only FCM survive
*with stock power settings*. Only after recording what breaks should the settings be relaxed and
the run repeated. The difference between the two passes is the finding: it tells us whether the
onboarding needs to walk a family through Autostart, or whether the escape hatch in §9 (the
scheduled server-side function) has to be un-deferred.

This is also what the health panel and the dontkillmyapp.com link in onboarding exist for. If the
stock pass fails here, that is not a bug to fix — it is a documented platform reality, and the
product answer is guidance plus the §9 fallback.

## Per-device checklist

Run against **stock power settings first** — the default state is the one real users are in. Then,
if something fails, repeat with battery optimisation disabled to establish whether the failure is
fixable by onboarding guidance or not at all.

**Phase 2 — watched side** · **run 2026-08-17 on the POCO F3, stock power settings — all pass.**
Full evidence in [phase-2-summary.md](../phases/phase-2-summary.md).

- [x] Reminders fire at 12:00, 18:00, 21:00 local — *registered with `AlarmManager` at exactly those
      instants across 7 days.* **Observed unattended 2026-08-17 and it failed**: two / two / three
      notifications instead of one each, the extras being identical copies. Cause was `AlarmIds`
      deriving ids from `Object.hash`, which is seeded per process — fixed, and written up in
      [phase-2-summary.md](../phases/phase-2-summary.md).
- [x] A tap cancels the remaining reminders for that day — *within one process; reminders armed by an
      earlier launch were uncancellable until the id fix*
- [x] Alarms survive a reboot — **~76 s after `sys.boot_completed`, not immediately**
- [x] The window re-arms for following days **without the app being opened**
- [x] The tap target is disabled for the rest of the day and re-enables at local midnight
- [x] Notification permission denial is detected and explained
- [x] The debug harness works on-device: force date, fire alarm now, dump `LocalStore`, run
      `reconcile()`. Without it every later item on this page costs a day to verify.

**Phase 6 — away mode** · **NOT RUN. Nothing in Phase 6 has been on a handset.**

The feature is built and all three exit criteria are met in tests
(`test/application/away_exit_criteria_test.dart`); this list is what only a device answers. Written
before the run rather than after, so the checklist is not shaped by what happened to be tried.

**First, and carried from the Phase 5 gate** — it is a Phase 5 defect that no Phase 6 test can reach:

- [ ] Press **Add someone**, take the **second** option (*"Someone I look after"*), complete a
      pairing, and confirm a **warning alarm actually arms** — read `dumpsys alarm` off the device,
      not the app's own belief. The chooser's second option, the empty-audience 21:00 reminder and
      the fourth refusal are covered by tests and mutation only.

**Then Phase 6's own:**

- [ ] Set away from the Tap screen: the picker opens, both frozen labels read correctly and follow
      the selection, and **nothing clips at the largest system font scale**.
- [ ] Reminders stop on the away days — from `dumpsys alarm`, and the window still extends to
      `through` + 7 so the days back are already armed.
- [ ] The Tap screen's away line renders, the control reads *"I'm not away"*, and **the tap target
      is still enabled** — §12 allows tapping during away and the plausible bug is suppressing the
      write with the reminders.
- [ ] Set away from the **watcher's** phone for the watched person, and confirm the watched device's
      Tap screen names the watcher: *"Ana marked you away until …"*. This is the surface §17's
      mitigation depends on and the one thing no emulator run has ever exercised.
- [ ] The watcher's row reads *"Away until Sat 22 Aug — set by …"* and the away control switches to
      *"End …'s away period"*.
- [ ] Cancel from **either** side and confirm both restore — the truncation, not a delete, and the
      days already spent away stay covered.
- [ ] `onAwayChanged` reaches a **closed** app: away set on one phone, the other phone's app force-
      stopped, and the reconcile runs. Same shape as Phase 4's fan-out measurement, and the same
      caveat — over `adb reverse` this is loopback, not a radio.
- [ ] The write **queued offline**: aeroplane mode, set away, confirm the screen says
      *"Saved. Your family will see this when this phone is back online."* and that the period lands
      when the radio returns. §8 chose a direct client write for exactly this, and it is the claim
      `AwayOutcome.queued` makes.
- [ ] The **v5 → v6 migration on a real store**, the way the v4 → v5 one was run: install the
      previous build, pair, let a watcher cache exist, then install this build over it and pull the
      database. `LocalStore.open()` is unguarded in both background entry points, so a migration that
      throws is an app that cannot open its own store.

**Two of these need a second device, and they are listed again under *Owed on a second device*
below** — with a detail this list does not carry: the "reminders for the first days back fire without
the app being opened" check **must run on the POCO**, because it is watched-side alarm reliability on
real OEM hardware. Roles live on links (§1), so the POCO plays the *watched* person for that one
test, and **the role swap has to be recorded in the result** or the run reads as contradicting the
device table.

**Cannot be driven in a session, and that is stated rather than quietly skipped:**

- [ ] *"A device that was offline for the whole period still ends away on the right day."* It needs a
      phone to sit offline **across a period boundary**. The arithmetic is asserted in tests and
      mutation-checked from the silent direction; what a device would add is confidence that nothing
      *else* — an OEM cache wipe, a force-stop, a store migration — expires or resurrects the cached
      period. The debug harness can force the date, which shortens this from days to minutes and is
      the intended route.

### How to read the alarms — the only ground truth

**`dumpsys alarm` piped through adb truncates.** It returned 3 of 21 once and looked exactly like
HyperOS silently trimming alarms; it was a cut-off buffer. Write it to the device and pull it:

```powershell
& "D:\Android\Sdk\platform-tools\adb.exe" shell "dumpsys alarm > /sdcard/alarm.txt"
& "D:\Android\Sdk\platform-tools\adb.exe" pull /sdcard/alarm.txt .
```

Then count `origWhen <13 digits> whenElapsed <n> io.github.davamix.i_am_ok`.

**Nothing inside the app can answer this.** `pendingNotificationRequests()` reads the notification
plugin's own `SharedPreferences`, and no public Android API enumerates an app's pending alarms — so
the harness's *"Compare store against plugin record"* compares two app-local copies of the same
intent, which is a useful check and a different question. `dumpsys` is the only ground truth.

To poll for boot recovery, loop the above every 15 s for several minutes.

**Dismiss the harness's test notifications before reading the shade.** *"Fire ⟨slot⟩ reminder now"*
posts under a sentinel epoch day so it cannot collide with a real armed reminder — which also means
no reconcile ever cancels it, so it sits in the shade indefinitely looking exactly like a genuine
reminder. Use the harness's *"Dismiss test notifications"* control, which cancels those three ids and
leaves the armed window alone. On 2026-08-17 a leftover test notification was a live candidate
explanation for duplicate reminders and cost real time to rule out.

> **CORRECTION, 2026-08-18 — "swiping from recents" is not a force-stop on this device.**
>
> Phase 2 recorded that swiping the app from recents "kills it and its alarms", and the whole
> force-stop exposure has been reasoned about on that basis — that an ordinary thumb movement makes
> the watcher permanently deaf. Measured directly, with 35 alarms armed and 3 notifications standing:
>
> | Action | Process | Alarms | Notifications | `stopped` flag |
> |---|---|---|---|---|
> | **Clear all** in recents | killed | **35** | **3** | **false** |
> | `am force-stop` | killed | **0** | **0** | **true** |
>
> Clear-all is an **ordinary process kill**. The alarms survive, the notifications survive, and the
> app is *not* in the stopped state, so it still receives broadcasts and its alarms still fire — which
> the isolate test independently confirms from exactly that state (process gone, alarms intact).
>
> A force-stop is a different act: it cancels every alarm, **erases the standing notifications**, and
> sets `stopped=true`, after which the app receives nothing at all — including `BOOT_COMPLETED` —
> until launched by hand.
>
> **Both gestures measured, 2026-08-18.** The dismissal gesture on this phone is **horizontal** — a
> vertical swipe scrolls the carousel, which is why the first attempts changed nothing and proved
> nothing. Re-run with a horizontal swipe on the card: process killed, **35 alarms and 3 notifications
> intact, `stopped=false`** — identical to clear-all. The individual swipe and clear-all behave the
> same, and neither is a force-stop.
>
> **Two things this run established that anyone repeating it needs.**
>
> **A force-stop cancels every alarm the app has registered**, and nothing tells the app. Before the
> fix, reopening and reconciling re-armed *nothing*, because the diff was computed against the app's
> own store rather than against the platform — 21 armed → force-stop → 0 → reopen → still 0. On this
> handset that is an everyday action, not an exotic one. `reconcile()` now asserts the whole desired
> set, and the repair is verified on-device. **Any alarm test must therefore treat "was the app
> force-stopped" as a variable**, including a swipe from recents.
>
> **Boot recovery is delayed.** Checking at 60 s reads zero and looks like a hard failure; the alarms
> arrive at ~76 s. Poll for several minutes before concluding anything.
>
> **Counting registered alarms is not the same as watching one fire, and the difference cost a
> defect.** Every count in this run was taken from `dumpsys` inside one app session, and all of them
> were right: 21 alarms, at the right instants, cancelled correctly on a tap. The reminders then fired
> **two / two / three** when finally observed unattended, because the ids were regenerated on every
> launch and orphans accumulated. **A count taken within a single process cannot see an id that
> changes between processes.** Any run that spans an app restart must therefore compare the id set,
> not the count — and at least one criterion per phase should be observed arriving, not inferred from
> what is registered.
>
> **These two results do NOT compose, and the checklist above can be misread as saying they do.**
> A force-stopped app is in the stopped state and receives **no broadcasts at all, including
> `BOOT_COMPLETED`**, until the user launches it by hand — and that state survives a reboot. So
> "alarms survive a reboot" holds for an app that was *not* force-stopped, and force-stop + reboot
> still leaves zero alarms until the app is opened. Both rows were measured on a non-force-stopped
> app and both are true; the conjunction is not.

> **A fresh install strands one alarm the app can never cancel**, measured 2026-08-17 and reproduced.
> The first `reconcile()` runs before the device zone is cached, so it arms the window in **UTC**; the
> zone-corrected reconcile then replaces days that share an id and leaves behind any slot that was
> wanted only under UTC. Store said 18, `dumpsys` said 19. **So `pm clear` — not just relaunching —
> between runs**, or a measurement inherits it. Full write-up in
> [phase-2-summary.md](../phases/phase-2-summary.md).

**Phase 3 — watcher side** · **run 2026-08-17 on the POCO F3, stock power settings.** Full evidence
in [phase-3-summary.md](../phases/phase-3-summary.md).

- [x] **The alarm isolate wakes.** Armed two minutes out; `last_reconcile_at` moved to exactly the
      armed instant on both links with the app backgrounded — and again at 23:36:59 for an alarm
      armed at 23:36:58 with the **process killed beforehand**, where Android cold-started a new
      process (pid 22348) to run it. The timestamp is written inside the reconcile, so it is
      evidence our Dart ran rather than that a broadcast arrived.
- [x] Warning alarms are registered — 12 `AlarmBroadcastReceiver` entries, matching the store's 12
      exactly, at 10:00 Europe/Madrid across six days × two links
- [x] The three channels exist with `warnings` at **max** importance, separate from `access` —
      ADR-0004's structural half, asserted against the system's record rather than our constants
- [x] **Force-stop cancels every warning alarm** (12 → 0), exactly as it does the reminders. `am
      kill` does **not** — it is an ordinary process kill and leaves alarms armed. Anyone repeating
      these measurements needs that distinction.
- [x] Opening the app repairs **both** sides after a force-stop — 0/0 → 18 reminders and 12
      warnings. It did **not** before this run; see the summary.
- [x] **A warning arriving unattended** at its natural `warningLocalTime`, 2026-08-18 — app closed,
      OS started a fresh process, **two** notifications with the correct wording on the `warnings`
      channel. The equivalent of the check that found Phase 2's worst defect, and it found this
      phase's worst one too: the app-open reconcile was consuming the day as `redundant` and posting
      nothing. Notification ids were byte-identical across processes and a reinstall, which is
      `AlarmIds`' stability shown on hardware.
- [x] **All five of PLAN.md's Phase 3 exit criteria, driven end-to-end on the device**, 2026-08-20
      15:33–15:55, one build, one session, one process (pid 19814). Each fire is the **alarm isolate**
      deciding, not a UI reconcile. The earlier wording here was muddled — it listed four items and
      then said "the other three" — so all five are restated with their evidence:

      | # | Criterion | Fired | Evidence |
      |---|---|---|---|
      | 1 | Fires when it should | 15:33:00, 15:47:00 | *"No check-in from Mum yesterday."* + Granddad, `warnings_shown` = `warnOnline` |
      | 2 | Suppressed when a check-in is cached | 15:39:00 | **no** notification, `warnings_shown` empty, `last_confirmed_day=2026-08-19` |
      | 3 | Suppressed when away covers the day | 15:43:00 | **no** notification, `away=2026-08-17..2026-08-23` cached, `last_confirmed_day=None` |
      | 4 | Replaced by a correction | 15:50:16 | *"Correction: Mum did check in yesterday."* at **id 779565329** — the same id the warning held |
      | 5 | Different and honest when unreachable | 15:55:00 | *"…your phone has not been able to check even once."*, `warnings_shown` = `warnOffline` |

      **The suppressions carry a positive fingerprint, which is better than the plan expected.** A
      silence writes no notification and no ledger row, so the intent was to prove it only by
      contrast against the `warnOnline` control six minutes earlier. In fact the isolate's *cache
      write* distinguishes the two causes: case 2 records `last_confirmed_day`, case 3 records the
      away period and leaves `last_confirmed_day` null. So each silence is evidenced as the right
      silence, not merely as silence — without adding anything to the path that decides whether to
      alarm a family.

      **Criterion 4 also demonstrates §10's "reconcile every link, not the one armed for".** The
      alarm was armed for `links.first` only (Mum), and **both** people were corrected.

      **Criterion 5 confirms ADR-0001's rule in passing:** `last_reconcile_at` stayed **null** across
      the fire, because a read that *fails* is not an answer and may not refresh the cache.

      Method: no new harness code. `Arm the natural warning 3 minutes out` clears decision state and
      arms; the `Backend holds …` controls only touch the simulated backend, so they can be applied
      *after* it. Criterion 4 used `Arm a REAL warning alarm, 2 minutes out`, which arms through
      `warningAlarms.apply` with no reconcile and so disturbs neither backend nor standing warning.
      Every step was verified by reading the store, and the tray was confirmed empty of ours before
      each suppression run so that "no notification" meant something.
- [x] **The warning alarm survives a reboot**, 2026-08-18 — 35 armed, rebooted, and the **identical
      35 instants** back at uptime 100 s (0 at 39 s, 59 s and 79 s, so poll for minutes). Restored by
      the plugin's `RebootBroadcastReceiver` from its own record: `last_reconcile_at` was unchanged
      afterwards, so **a reboot restores what was armed, not what should be** — only a reconcile
      repairs a divergence.
- [x] **The alarm isolate reconciles while the UI is live, and the store and the platform still
      agree** — 2026-08-20 16:01–16:09, app in the **foreground** throughout, pid 19814.
      [ADR-0006](../architecture/decisions/0006-reconcile-is-serialised-on-disk.md).

      Three alarm fires with the UI open (16:01:04, 16:05:04, 16:08:00), one with two UI reconciles
      issued into the same second, and one with **20 back-to-back UI reconciles**. Afterwards:

      | | |
      |---|---|
      | Platform (`dumpsys alarm`, receiver-tag rule) | **12** warning alarms |
      | Store (`pending_alarms`) | **12** rows |
      | The two sets | **identical**, instant for instant |
      | `PRAGMA integrity_check` | ok |
      | `reconcile_lock` | released, no orphaned lease |
      | Exceptions in logcat | **none** — no `DatabaseException`, no nested-transaction error, no `database_closed` |
      | Duplicate notifications | none |

      **What this does NOT establish, stated plainly because the distinction is the whole point of
      the entry.** Concurrency was *induced*, not *proven*: nothing here demonstrates that two
      reconciles were ever inside the lease window simultaneously, and the mechanism cannot be
      observed from outside — a refused lease is caught by `acquireReconcileLock`'s
      `on DatabaseException` arm and returns `false` silently, and the lease row is deleted by the
      `finally`. So this is evidence of **absence of harm** under a live UI, not evidence that the
      exclusion fired.

      The prediction that remains untested on device, recorded so the next attempt can falsify it:
      with one shared connection each isolate holds its own Dart-side transaction lock, so a second
      `BEGIN EXCLUSIVE` should fail as a *nested* transaction rather than block on SQLite's
      cross-connection lock. Same outcome, different mechanism from the one ADR-0006 and
      `local_store_lock_test.dart` describe.

      Also observed, and worth knowing before timing another attempt: delivery on this device is
      **not reliably on the armed second when the app is in the foreground** — 16:01 and 16:05 both
      landed at **+4.5 s**, while every backgrounded fire earlier in the session (15:33–15:55) landed
      on the second. Two attempts at forcing an overlap missed for that reason.
- [x] **Tapping the *lost access* notification opens the watcher surface from a cold start**,
      2026-08-18 — process dead, tapped from the shade, app cold-started and opened the list with the
      right person's row highlighted and the cause-specific remediation showing.
- [x] **A force-stop erases standing notifications as well as alarms** — 4 → 0. The unread warning
      goes with them, and `accessLostNotifiedOn` still records it as delivered.
- [x] **A *resume* repairs the watcher side, not only a launch**, 2026-08-19 — `last_reconcile_at`
      advanced on both links across a plain background→resume with the process left alive, twice,
      which is the observer firing and the reconcile running. The **launch** half was re-measured on
      the post-gate build the same evening: force-stop took the platform to **0 warnings / 0
      reminders**, reopening restored **12 / 18**, and the store's `pending_alarms` agreed exactly.
      Not yet observed: alarms disappearing *while the app is alive* and being restored by a resume
      alone — the harness's "Cancel every alarm" could not be driven through `adb input tap`.

> **Counting pending alarms from `dumpsys alarm` needs the right lines.** Grepping the receiver name
> matches the **App Alarm history** section — entries with `reason=data_cleared` / `alarm_cancelled`
> — and not what is armed. A first pass at this run reported "18 reminders armed" from history lines
> on an app that had none. Pending alarms are the `RTC_WAKEUP #n: Alarm{… <package>}` lines, whose
> **following** line carries `tag=*walarm*:<package>/<receiver>`; count those. Same lesson as the
> truncated-pipe trap already recorded here: the measurement needs checking before the result does.

**Phase 3 — post-gate device pass, 2026-08-19**, on the six commits that closed the reviewer round.
Same POCO F3, Android 13 / API 33, HyperOS `OS1.0`, stock power settings.

- [x] **A fresh install arms the window at the device's wall times** — 18 reminders at 12:00 / 18:00
      / 21:00 **Europe/Madrid**, not UTC, with `device_timezone` cached before the first reconcile.
      The regression guard for the "19 alarms at UTC" defect, re-measured after `cacheDeviceFacts`
      moved in `main()`.
- [x] **The alarm isolate wakes on the post-gate build and picks the right message**, twice, from a
      process killed with `am kill`: *"No check-in from Mum yesterday."* (`warnOnline`) and *"No
      check-in received from Mum yesterday — your phone has not been able to check even once."*
      (`warnOffline`, never-reconciled variant), both on the `warnings` channel.
- [x] **A 12-hour device gets 12-hour times on the watcher row** — *"This phone last checked 10:34
      pm."* with the device set to 12-hour: no leading zero, lowercase suffix, time-only because the
      instant is today. The cached single source reaching the screen.
- [ ] **A 12-hour time inside an isolate-posted notification.** Not reached: the two harness controls
      that arm a real warning either force the backend to `succeeded` (no time in the message) or
      reset `lastReconcileAt` to null (the "not able to check even once" variant, also no time). Both
      are correct app behaviour. A harness control that leaves `lastReconcileAt` set while clearing
      only `warnedDays` would close it.
- [x] **Tapping a warning notification opens the watcher list**, with both rows rendering as one
      TalkBack utterance each — *"Mum. No check-in from Mum yesterday. This phone last checked 10:34
      pm."* That is `AppServices.resolveWatchedLink` routing on the new signature.
- [x] **The release build runs, and the debug harness is absent from it** — the "Debug harness"
      button present in the debug build does not appear. Reachability is nil by construction; this is
      that, observed.
- [x] **The release APK carries the pinned SDK levels and no `INTERNET`** — `aapt2 dump badging`:
      `compileSdkVersion='36'`, `minSdkVersion:'24'`, `targetSdkVersion:'36'`, and exactly six
      permissions (POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED, USE_EXACT_ALARM, SCHEDULE_EXACT_ALARM
      `maxSdkVersion='32'`, VIBRATE, WAKE_LOCK) plus androidx's
      `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. Stronger evidence than the merger report, since it
      is the shipped artifact. Alarms armed 12 / 18 under the release build too.
- [ ] **The cached 12/24-hour setting does not follow a plain resume** — see the finding below. Left
      unchecked because it is a real, if cosmetic, gap rather than a passing result.

> **FINDING — the clock format follows a cold start or a configuration change, not a resume.**
> With the device switched between 12- and 24-hour while the app was backgrounded, two successive
> background→resume cycles wrote the **stale** value, in **both** directions. A cold start wrote the
> correct one; so did a resume that followed a forced configuration change (dark mode). Flutter
> refreshes `platformDispatcher.alwaysUse24HourFormat` only on a configuration change, so
> `cacheDeviceFacts` re-writes the same stale value on resume.
>
> The **write** happens on resume; the **value** does not move. The zone half is unaffected —
> `flutter_timezone` is a live plugin call — though that was not measured, because setting the device
> zone needs a permission `adb` does not have.
>
> Consequence is cosmetic and never a false claim about a person, which is why it is recorded rather
> than urgently fixed. Documented in `LocalStore.uses24HourClock`; the live fix is a platform channel
> to `DateFormat.is24HourFormat`, which belongs with Phase 7.
>
> **Caveat on the method:** the setting was changed with `adb shell settings put system time_12_24`.
> A real toggle in the Settings UI might deliver a configuration change as a side effect, in which
> case a user would not see this. The mechanism — that a plain resume does not refresh the value — is
> what was measured, and it holds either way.

### The two measurements taken for ADR-0008 — recorded, not acted on

Both were run at the owner's request to inform the ADR. **Nothing was implemented on the strength of
either.** [ADR-0008](../architecture/decisions/0008-the-warning-is-late-in-doze-and-the-app-says-so.md)
records the decision they inform.

#### A. The temporary power allowlist IS granted, in full, and the job still does not run

**Measured 2026-08-20 14:42, POCO F3, forced deep Doze, fresh process (pid 15097).** Sampled
`dumpsys deviceidle tempwhitelist` on-device twice a second across the armed second, because
round-tripping each poll through adb is too slow for a ten-second window.

```
T 14:42:00.346  UID=10612: +9s700ms - broadcast:u0a612:…/AlarmBroadcastReceiver
T 14:42:04.871  UID=10612: +5s175ms - broadcast:u0a612:…/AlarmBroadcastReceiver
T 14:42:09.971  UID=10612:    +75ms - broadcast:u0a612:…/AlarmBroadcastReceiver
(gone by the next sample, ~14:42:10.5)
```

**The window is real, granted at the armed second, and lasts its full ten seconds** — first sample
346 ms after the second already shows 9.7 s remaining, so the grant landed essentially at 14:42:00.0.
It is attributed to `AlarmBroadcastReceiver`, our alarm's receiver.

**And the warning still did not arrive.** No notification at 14:43:26 — 84 seconds after the armed
second, `get deep` still `IDLE`. Doze was released at 14:43:44 and both warnings were in the tray by
14:44:04. Fifth reproduction of the same pattern.

> **So the temporary allowlist does not lift `readyNotDozing` for JobScheduler.** The app is handed a
> full ten seconds of exemption and the plugin cannot use it, because it has already given the work
> to a scheduler that ignores the exemption. The window is not missing. It is unused.

**Flutter background engine start cost, for scale against that window:**

| Measured | Duration |
|---|---|
| `Starting AlarmService…` → `AlarmService started!`, fresh process after `am kill` (14:39:19.794 → 14:39:20.089) | **295 ms** |
| Same pair on the session's first cold launch (11:10:11.447 → 11:10:12.979) | **1.53 s** |

Against a 10-second grant that is 6–34× headroom for the engine alone.

**What is NOT measured, and cannot be on this build.** Whether the *reconcile* — which does a
Firestore read (§10) — completes inside the same window. Phase 3 has **no Firebase dependency at
all** and the release build carries **no `INTERNET` permission**, so there is nothing to time. This
needs either the receiver path built or a throwaway spike, and it is the one remaining unknown for
the "deliver from the receiver" option. **Do not treat the headroom above as an answer to it** — a
network round trip on a cold radio in Doze is a different order of cost from starting an engine.

Worth carrying with it: §10 already has `warnOffline` for a read that fails, so losing the race
degrades to an honest, differently-worded warning rather than to silence. Whether that wording is
acceptable when the watcher's phone is merely dozing rather than genuinely offline is a **copy
question nobody has answered**, and it is the one that touches "never make a false claim".

#### B. `firebase_messaging` uses `JobIntentService` — and vendors a modified copy that bypasses it

**Source read at `firebase_messaging` 16.5.0**, pulled into the pub cache with `dart pub cache add`;
the package is not a dependency of this project. The answer is more useful than yes or no.

`FlutterFirebaseMessagingBackgroundService extends JobIntentService` — but **not** androidx's. The
package ships its own `JobIntentService.java` with an extra parameter androidx does not have:

```java
public static void enqueueWork(Context, Class, int jobId, Intent work, boolean useWakefulService)

static WorkEnqueuer getWorkEnqueuer(…, boolean useWakefulService) {
  if (Build.VERSION.SDK_INT >= 26 && !useWakefulService) {
    we = new JobWorkEnqueuer(context, cn, jobId);   // JobScheduler — what blocks in Doze
  } else we = new CompatWorkEnqueuer(context, cn);  // mContext.startService(intent) — direct
}
```

and `FlutterFirebaseMessagingReceiver` passes:

```java
FlutterFirebaseMessagingBackgroundService.enqueueMessageProcessing(
    context, onBackgroundMessageIntent,
    remoteMessage.getOriginalPriority() == RemoteMessage.PRIORITY_HIGH);
```

So **high-priority FCM starts the service directly and never creates a job**; normal-priority FCM
goes through JobScheduler and would be held in Doze exactly as our warning is. The package's own
comment names the trap this repo just measured:

> *"Can throw on API 26+ if useWakefulService=true and app is NOT whitelisted. One example is when an
> FCM high priority message is received the system will temporarily whitelist the app. However it is
> possible that it does not end up getting whitelisted so we need to catch this and fall back to a
> job service."*

**Two consequences for the ADR:**

- **Option 2 escapes the defect only if it uses high-priority FCM.** A data-only nudge at normal
  priority inherits it. That is a constraint on the design, not a detail of it.
- **Option 1's pattern is proven in production by a sibling plugin.** Starting a Flutter background
  engine directly from a broadcast receiver, inside a temporary power allowlist, with a fallback when
  the allowlist is absent, is what `firebase_messaging` does on every high-priority message.
  `android_alarm_manager_plus` calls androidx's `enqueueWork`, which offers no such option. Measured
  above: our receiver *is* allowlisted for the full ten seconds when it runs.

### FIXED 2026-08-20 — the alarm isolate closed the UI's database

**Found 2026-08-20 11:17 on the POCO F3, while setting the Doze experiment up.** After a warning
alarm fires *while the app process is alive*, every subsequent UI store operation throws:

```
Arm the natural warning 3 minutes out FAILED
DatabaseException(database_closed 1)
```

Reproduced on two different harness controls — "Arm the natural warning 3 minutes out" and "Dump
LocalStore", the latter with a stack through `LocalStore.dump` (`local_store.dart:947`). It is
**permanent for the life of the process**, not transient. The `1` is the database id: the UI's own
connection, opened at launch.

**Mechanism, read out of `sqflite_android` 2.4.3's source rather than guessed from the symptom.**

- `android_alarm_manager_plus` runs the background isolate **in the app's own process** —
  `AlarmService` has no `android:process=":remote"`.
- `SqflitePlugin.java` holds a **static** `_singleInstancesByPath` map (line 59), shared by every
  Flutter engine in that process.
- `onOpenDatabaseCall` (≈line 349): a second isolate opening the same path finds the existing entry
  and is handed back **the same `databaseId`**. It does not get a connection of its own.
- `onCloseDatabaseCall` (≈line 453): `close()` removes that id from `databaseMap` and closes the
  underlying `SQLiteDatabase`.

So `warningAlarmCallback`'s `finally { await store?.close(); }`
(`warning_alarm_handler.dart:101`) closes the connection **the UI is still holding**. The UI's
Dart-side `Database` keeps the now-dead id, and every later call fails.

**It falsifies a claim in the code.** `LocalStore.open()`'s docstring (`local_store.dart:56`) says:

> Called by **each** isolate that needs it — UI, alarm, and later FCM. They each hold their own
> connection to the same file; SQLite does the locking.

On Android, in-process, there is **one** connection, not two or three.

**Why 781 tests do not catch it.** The suite opens `sqflite_common_ffi` in a single isolate. This is
Android-plugin static-state behaviour that only exists on a device with two Flutter engines in one
process — the same shape as the `Object.hash` defect already in `CLAUDE.md`, where every test
compared two calls made inside one process.

**Consequences.** Confirmed: the UI's store is dead for the process lifetime after any warning alarm
fires, so watcher-list reads, the resume reconcile and every harness control throw. **Not measured,
but following from the same mechanism and worth checking before it is dismissed:** a tap on the
watched side after a warning alarm has fired, and what `transaction()` from two isolates does to one
shared connection — the `reconcile_lock` design is written on top of the "own connection" premise
that has just been falsified. The alarm isolate's *own* work completes correctly before it closes,
so **delivery of the warning itself is unaffected**; the damage is to the UI afterwards.

**FIXED, and verified on the device the same day.** The repair is the one `sqflite`'s own
documentation prescribes: the background isolate simply does not close a connection it shares.
`warningAlarmCallback`'s `finally { close(); }` is gone, `LocalStore.close()` now has no caller in
`lib/` and says why, and `domain_purity_test.dart` fails if a background entry point calls it —
verified to fail by reintroducing the call, not assumed.

**A second hazard was found in the same code and pinned.** `rollbackActiveTransactionOnOpen`
defaults to **true in debug and false in release**, and when true, opening the store from one isolate
**rolls back a transaction active in another**. The alarm isolate opens on every fire while the UI
writes through `_db.transaction`, so a debug build could silently roll back an in-flight UI write and
no release build would — meaning every device measurement this project has taken was of something
that does not ship. `LocalStore.open()` now pins it to `false`, which is what `sqflite` recommends
for an app that explicitly creates multiple isolates, and a second guard asserts it.

**Device proof, 2026-08-20 15:33.** Rebuilt, reinstalled, armed a natural warning, backgrounded, let
the alarm fire in the live process (pid 19814 throughout — `last_reconcile_at` 15:33:00,
`warnings_shown` written), then reopened the harness and ran **Dump LocalStore**: full JSON. That is
the identical sequence that produced `DatabaseException(database_closed 1)` twice earlier the same
day. 783 tests pass, `flutter analyze` clean.

### SETTLED — deep Doze blocks it with a WARM process, and the block is JobScheduler

**Measured 2026-08-20 11:25 on the POCO F3.** This is the experiment the three earlier runs could
not separate: **deep Doze with a warm process**. The answer is that **process warmth is irrelevant**
— the hypothesis carried forward from run 2 ("the cold service start is the cause") is **falsified**.

| | |
|---|---|
| Process | pid 6349, alive, **`AlarmService started!` logged at 11:21:49** — the background isolate was already initialised 3½ minutes before the alarm |
| Doze | `battery unplug` + `deviceidle force-idle`, screen off; `get deep` = **`IDLE`** throughout |
| Owed? | `warnings_shown` **empty**, `active_from` 2026-08-19 — a warning genuinely owed for the 19th |
| Armed | 11:25:00, confirmed in `dumpsys alarm` |
| Result | broadcast **on time**; **nothing ran**; warning arrived **11:28:47**, i.e. 3m47s late and only because Doze was released at 11:28:43 |

**The mechanism, read out of the platform rather than inferred from timing.** At 11:25:13, thirteen
seconds after the armed second, with the device still in deep `IDLE`:

```
JOB #u0a612/1984: io.github.davamix.i_am_ok/…androidalarmmanager.AlarmService
  Required constraints:    DEADLINE
  Satisfied constraints:   DEADLINE BACKGROUND_NOT_RESTRICTED TARE_WEALTH WITHIN_QUOTA
  Unsatisfied constraints:                      <-- none
  Implicit constraints:
    readyNotDozing: false                       <-- the only thing holding it
    readyDeadlineSatisfied: true
  Pending work:
    #0: Intent { … AlarmBroadcastReceiver (has extras) }
    #1: Intent { … AlarmBroadcastReceiver (has extras) }
  Standby bucket: ACTIVE      Uid: active
  Ready: false (job=false …)
```

So the chain is: **AlarmManager delivers the broadcast → `AlarmBroadcastReceiver.onReceive` calls
`AlarmService.enqueueAlarmProcessing` → `JobIntentService.enqueueWork` → a JobScheduler job → Doze
holds the job.** Both links' work items are sitting in the queue. Every *explicit* constraint is
satisfied; the single implicit one, `readyNotDozing`, is not.

**Why the 10-second allowlist does not save it.** Our alarm carries, in this session's own
`dumpsys alarm` capture:

```
flags=0x5  exactAllowReason=policy_permission  device_idle=--
idle-options=Bundle[{… temporaryAppAllowlistReasonCode=302,
                      temporaryAppAllowlistDuration=10000, …}]
```

That temporary allowlist covers **the broadcast**, and it did its job — `onReceive` ran at
11:25:00.039. It does **not** extend to the JobScheduler job the broadcast enqueues. The work is
handed across a boundary the exemption does not cross.

**The app was in the most favourable state Android offers and it still did not run.** `Standby
bucket: ACTIVE`, `Uid: active`, foreground three minutes earlier. That closes the obvious objection
that the experiment was contaminated by driving it by hand: a recently-used app is exactly the case
most likely to be let through, and it was not. A real night can only be worse.

**The release, which is the confirmation.** Doze was ended at 11:28:43 and nothing else was touched:

```
11:28:46.787  SmartPower…i_am_ok: idle->background R(service create …AlarmService) adj=0
11:28:47      both warnings posted, when=11:28:47
```

3.9 seconds after leaving Doze. That is run 2's **3h31m** reproduced in miniature and under control:
the work waits for the end of Doze, however long that is. All three channels agree on 11:28:47 —
`warnings_shown` gained 2026-08-19/`warnOnline` for both links, `last_reconcile_at` stamped
11:28:47, and both notifications carry `when=11:28:47` against an armed second of 11:25:00. The copy
was right — *"No check-in from Mum yesterday."* and the same for Granddad — which is the point: the
decision is correct, the delivery is late.

**Positive control, same session, same build.** At 11:15:00 with the device ACTIVE and the same warm
process, the identical setup delivered both warnings at `when=11:15:00` — punctual to the second.
So the path itself works; only Doze breaks it.

#### What this does and does not license

- It **does** settle the question the three earlier runs left open. Cold service start is not the
  cause. Deep Doze is, and it blocks at a named, observable gate.
- It is **forced** Doze again — but run 2 was a natural overnight and produced the same outcome, and
  the gate now has a name that is the same gate in both cases. The forced run adds the mechanism; the
  natural run supplies the realism.
- It does **not**, on its own, establish that the answer must be §9's server-side function. What is
  blocked is specifically the **`JobIntentService` hop inside `android_alarm_manager_plus`**, not
  "Dart at alarm time". Worth weighing before the ADR is written — see the open question below.

#### ANSWERED — the reminder path delivers ON TIME in the same deep Doze

**Measured 2026-08-20 12:00, thirty minutes after the run above, on the same device in the same
forced deep Doze.** This was the open question, and it is now closed: **Doze does not block local
delivery on this handset. The `JobIntentService` hop does.**

`flutter_local_notifications` schedules its reminders through AlarmManager exactly as
`android_alarm_manager_plus` does, and the two alarms are **indistinguishable** in `dumpsys alarm`:

```
tag=*walarm*:…/flutterlocalnotifications.ScheduledNotificationReceiver     <- reminder
tag=*walarm*:…/androidalarmmanager.AlarmBroadcastReceiver                  <- warning
both: type=RTC_WAKEUP  flags=0x5  exactAllowReason=policy_permission
      idle-options=Bundle[{… temporaryAppAllowlistDuration=10000, …}]
```

The **only** difference is what the receiver does with the broadcast:
`ScheduledNotificationReceiver.onReceive` calls `notificationManager.notify(...)` **directly**
(source read at 22.3.0); `AlarmBroadcastReceiver.onReceive` calls `enqueueWork` and hands it to
JobScheduler.

| | Warning, 11:25 | Reminder, 12:00 |
|---|---|---|
| Device | deep `IDLE`, forced | deep `IDLE`, forced — **still `IDLE` at 12:00:58** |
| Process | pid 6349, warm | pid 6349, **same process** |
| Alarm | `RTC_WAKEUP flags=0x5`, 10 s allowlist | **identical** |
| Delivery hop | receiver → `JobIntentService` → JobScheduler | receiver → `notify()`, **no job** |
| Broadcast | 11:25:00.039 — on time | 12:00:00.114 — on time |
| **Delivered** | **11:28:47** — only once Doze ended | **`when=12:00:00`** — on the second |

From logcat, the whole reminder path inside deep Doze:

```
12:00:00.008  SmartPower…i_am_ok: idle->background R(alarm start) adj=700
12:00:00.114  AlarmManager: mPendingIntent -> PendingIntentRecord{… i_am_ok broadcastIntent}
12:00:00.445  Launcher.ApplicationsMessage: update io.github.davamix.i_am_ok/ to 3
12:00:00.450  notification sound
```

`when=12:00:00` on channel `reminders`, body *"Remember to tap I'm OK today."* — the notification's
`when` is set by the plugin to `System.currentTimeMillis()` at post time, so it is the post time and
not a scheduled value. And `dumpsys jobscheduler` taken at 12:00:58 has **no live `JOB #` entry for
this package at all** — only history rows for the 11:15 and 11:28 runs. There was no job to defer.

#### What this means for the ADR — the trigger condition is not met as worded

ARCHITECTURE.md §14 names the trigger for un-deferring §9's scheduled Function as *"whether **alarms
and data-only FCM** actually survive on Xiaomi / Samsung / Huawei with stock power settings."*

**On this handset, alarms survive.** They are delivered at the armed second in deep Doze, every time,
in all five runs. A notification posted from the receiver reaches the user at the armed second in
deep Doze. What does not survive is one plugin's decision to hop through JobScheduler — which is a
property of `android_alarm_manager_plus`, not of Android's power management and not of this design.

So the options are wider than "go server-side", and the ADR should weigh at least these three:

1. **Deliver from the receiver, the way the reminders already do.** The warning needs Dart to run —
   it reads the store and decides — so this is not a copy-paste of the reminder path. What is
   *untested* is whether a Flutter background engine can be started from the receiver inside the
   10-second temporary allowlist, or whether a foreground service started under the exact-alarm
   exemption is needed. **Do not assume either way; it has not been measured.**
2. **§9's scheduled server-side Function**, at the cost ADR-0007 records.
3. **Accept the deferral and say so**, surfacing it in §13's health panel rather than promising a
   time the platform will not honour.

What is now settled is that option 1 is a *live* option rather than the dead end the previous
session's evidence implied. That is the reason this experiment was worth thirty minutes.

### RESULT — the overnight Doze run, 2026-08-20: the broadcast was on time, the isolate was 3h31m late

**The alarm did not decide anything at 05:00.** The broadcast was delivered exactly on time; the
service that runs the Dart isolate was not created until the phone was back in use.

```
05:00:00.334  SmartPower…i_am_ok: idle->background(659934ms) R(alarm start) adj=900
05:00:00.396  AlarmManager: mPendingIntent -> PendingIntentRecord{… i_am_ok broadcastIntent}
05:00:00.402  AlarmManager: mPendingIntent -> PendingIntentRecord{… i_am_ok broadcastIntent}
              … nothing …
08:31:16.021  SmartPower…i_am_ok: idle->background(192568ms)
              R(service create io.github.davamix.i_am_ok/…androidalarmmanager.AlarmService) adj=0
```

`AlarmService` is `android_alarm_manager_plus`'s own service — the thing that spins up the Flutter
engine and runs `warningAlarmCallback`. It was created **once** all night, at 08:31:16, and
`last_reconcile_at` was stamped 08:31:17. There is no `AlarmService` line at 05:00 in a buffer that
covers 00:26 onward in full, and no `notification_enqueue` from us at 05:00 either.

The device had been back in use since about 08:25 (battery broadcasts, other apps waking). So the
deferred work ran when the phone left Doze, **3h31m** after the alarm it belonged to.

This matches, and now explains, the forced-Doze observation recorded below: the broadcast arrives,
the service does not start. `setExactAndAllowWhileIdle` grants a temporary allowlist window — the
`idle-options` bundle on our own alarms shows `temporaryAppAllowlistDuration=10000`, ten seconds — and
the service start did not happen inside it.

**What was NOT observed, and why.** The run was contaminated: at **00:26:12** the app was brought to
the **foreground** by a person (`R(become foreground)`, `wm_on_resume_called`, a touch at
00:26:13.370, then `wm_finish_activity … app-request`). That resume ran the shell's watcher
reconcile, which posted both warnings and recorded 2026-08-19 in `warnings_shown`. By 05:00 the day
was already consumed, so a correctly-working isolate would have said nothing anyway. **The two
notifications in the tray are from 00:26, not from the alarm** — their `when` is
`1787178372424`/`…594`, which is 00:26:12 Madrid.

So this run establishes the **isolate deferral** and not the user-visible lateness of the warning
itself. Those are different claims and only the first is measured.

**Perspective before this is treated as fatal.** The product's default `warningLocalTime` is
**10:00**, watcher-local, and most watchers have used their phone by then — the device would not be
in Doze. 05:00 was chosen precisely because it is harsher, so that the mechanism could be observed
at all on the owner's daily driver. What the finding costs is the *guarantee*: a watcher whose phone
sits untouched — which §13 argues is exactly the low-usage watcher this app is for — gets the warning
whenever they next pick the phone up, not at the time the app promised.

**Owed next:** a clean re-run with the app left alone after setup, to see the notification itself
arrive late; and a run at the natural 10:00 to see whether ordinary morning use makes the deferral
disappear. If it reproduces, this is the trigger condition ARCHITECTURE.md §14 names for
un-deferring §9's scheduled server-side function, and ADR-0007 is the record of what that costs.

### The overnight Doze run — armed 2026-08-19 23:14, to fire 2026-08-20 05:00

Set up so the evidence survives without a live connection, and collected with
`pwsh -File tools/doze-collect.ps1` in the morning.

| | |
|---|---|
| Build | debug (`dd4dd03` + the docs commit), the one carrying the harness |
| Warning time | **05:00 Madrid**, set by writing `links.warning_local_time` directly and letting the app's own reconcile arm the window |
| Armed | 12 warning alarms, first pair **2026-08-20 05:00:00**, confirmed against `dumpsys alarm` |
| Owed? | `warnings_shown` holds **2026-08-18 only**. At 05:00 on the 20th the last completed Madrid day is the **19th**, which is unconsumed — so a warning is genuinely owed |
| Expected | *"No check-in from Mum yesterday."* and the same for Granddad, on the `warnings` channel |
| Baseline | `last_reconcile_at` = 2026-08-19 23:11:50 on both links; tray cleared of ours |
| Device | 24-hour, Europe/Madrid, night mode off, **not** on the Doze whitelist, stock power settings |

**05:00 rather than the natural 10:00**, because the POCO is the owner's daily phone and 10:00 is
after they would have picked it up — the run has to land while the device is genuinely untouched.

**Three independent channels**, because they fail differently: `warnings_shown` is only written when
something was *delivered*, `last_reconcile_at` is only stamped when the read *succeeded*, and the
tray can be cleared by the reader or by the OEM. All three moving is unambiguous; some moving is the
interesting case, which is why the script prints them separately rather than reducing them to a
pass/fail.

**Setting the warning time needed a direct store write.** `run-as` can read the app's private
directory but cannot write into it through a redirect, cannot use a heredoc (no writable temp), and
cannot read `/sdcard` under scoped storage. What works is streaming the bytes into the app's own
shell: `"cd …/databases
exec base64 -d > i_am_ok.db
<base64>" | adb shell run-as <pkg> sh`. Worth
recording — the harness cannot express an arbitrary warning time, and `adb input tap` on the harness
proved too unreliable to drive a multi-step setup.

### FINDING — under **forced** Doze the alarm was delivered and nothing ran

Measured 2026-08-19 22:56 while setting the overnight run up, with
`dumpsys battery unplug` + `dumpsys deviceidle force-idle`, screen off, app backgrounded, device
confirmed in deep `IDLE` throughout. A warning alarm was armed for 22:56 with the decision state
reset so a warning was owed.

**AlarmManager delivered it on time.** Doze did not defer it, and the alarm carried the right flags —
`flags=0x5` (FLAG_ALLOW_WHILE_IDLE), `exactAllowReason=policy_permission`, and its `device_idle`
policy was not holding it back. From logcat:

```
22:56:00.011 SmartPower.io.github.davamix.i_am_ok: idle->background(94016ms) R(alarm start) adj=700
22:56:00.067 AlarmManager: mPendingIntent -> PendingIntentRecord{… io.github.davamix.i_am_ok broadcastIntent}
22:56:00.067 AlarmManager: mPendingIntent -> PendingIntentRecord{… io.github.davamix.i_am_ok broadcastIntent}
22:56:03.014 SmartPower.io.github.davamix.i_am_ok: background->idle(3002ms) R(alarm start) adj=700
22:56:08.018 ProcessMemoryCleaner: Compact memory: io.github.davamix.i_am_ok … state=hibernation … isKilled=false
```

**And then nothing.** No notification, no `warnings_shown` row, no `last_reconcile_at` update, and no
Flutter or Dart line in logcat at all — against the same build which, forty minutes earlier and *not*
in Doze, woke from an `am kill`ed process and posted correctly twice. The app was given about three
seconds in `background` and put back to `idle`, then compacted into HyperOS's `hibernation` state.

**What this does and does not establish.**

- It is **forced** Doze, not a real overnight idle. `force-idle` is the standard simulation and it is
  not the same thing; HyperOS's SmartPower may behave differently after a genuine night.
- It is **one clean observation**. A second run was attempted and could not be set up, because the
  harness stopped responding to `adb input tap` — a tooling failure, not evidence either way.
- It does not distinguish *"the isolate never started"* from *"it started and was killed before it
  could write"*. The absence of any Flutter log line leans towards the first, but the plugin's
  `FlutterBackgroundExecutor` does log when it starts, and nothing was captured either way after the
  buffer had been cleared.
- What it does establish is that **the broadcast arriving is not the same as the warning arriving**,
  on this device, in this state. The Phase 3 evidence above tests the first; only this tests the
  second.

If the overnight run reproduces it, this is the trigger condition ARCHITECTURE.md §14 names for
un-deferring §9's scheduled server-side function, and ADR-0007 is the record of what that costs.

- [ ] **Device timezone change while backgrounded** — not run. `cmd time_zone_detector
      suggest_manual_time_zone` needs `SUGGEST_MANUAL_TIME_AND_ZONE`, which `adb` does not hold, so
      this needs a human changing the zone in Settings. Worth doing with the Doze run: change the
      zone, resume, and confirm `device_timezone` updated **and** the alarms re-armed at the new wall
      time.

## ADR-0008's deciding measurement — run 2026-08-21, and it answers both questions

**Phase 4 step 7, and exit criterion 2, run as one measurement rather than as a tick.** POCO F3,
Android 13 / HyperOS 1.0, **stock power settings**, app **killed**, device in **forced deep Doze**.
The `onCheckInCreated` fan-out running in the local functions emulator sent a **real** FCM message —
FCM has no emulator, so this half is always the live service.

### The result, and the mutation that proves it means something

Three runs of the same script, differing only in the Function's `android.priority`:

| `priority` | `deviceidle tempwhitelist` | process started | `watcher_cache.last_reconcile_at` |
|---|---|---|---|
| `'high'` | **granted, ~20 s** | yes | **moved** |
| `'normal'` | never, polled every 2 s for 40 s | **none** | **0 ms** |
| `'high'` (restored) | granted, ~20 s | yes | moved |

The platform states the reason in words, which is as direct as this gets:

```
UID=10612: +18s445ms - broadcast:u0a189:com.google.android.c2dm.intent.RECEIVE,reason:high-prio FCM
UID=10612:  +1s551ms - broadcast:u0a189:com.google.android.c2dm.intent.RECEIVE,reason:high-prio FCM
(gone by the next sample)
```

`dumpsys deviceidle get deep` read `IDLE` at every sample from +0 s to +40 s, so the device did not
leave deep Doze at any point in the window. **`priority: 'high'` is therefore load-bearing and not a
detail** — the normal-priority run is the same code, the same device, the same Doze, and it produced
nothing at all.

### Why `last_reconcile_at` is the evidence, and not a log line or a notification

`WatcherCache.applyRead` returns the cache **untouched** unless the read succeeded, and stamps
`lastReconcileAt` only inside that branch. So the value moving proves **both** of ADR-0008's
questions at once: a Flutter engine started, *and* it completed a Firestore read. Nothing else could
have moved it — the process was killed, the warning alarm is armed for 10:00, and the watched side's
reminders are display-only notifications that run no Dart at all.

**Except for one thing, which this phase had already been caught by once.**
`DebugBackendOverride` sits in *front* of the real reader in a debug build and returns a decoded
`SimulatedBackend` read whenever `debug_simulated_backend` holds a row — no socket, no Firebase —
and `applyRead` stamps `lastReconcileAt` exactly as it would after a real read. That is precisely
the leftover-harness-row false green recorded in `phase-4-handover.md`, and the first version of
this write-up did not mention it.

The measurement script now **refuses to run** unless the pulled database shows
`debug_simulated_backend` absent *and* `debug_clock_offset_ms` zero — the second because every
isolate reads that offset, so a forced date left set would make the latency figure arbitrary. Both
values are printed alongside the result, so the evidence carries its own disproof:

```
watcher_cache before: 2026-08-21|1787607553723|sim=none|offset=0
after                 2026-08-21|1787607578726|sim=none|offset=0
```

Raised by the Phase 4 testing review, which pointed out that the caveat list named the loopback
question and omitted this one — and that both attack the same half of the result.

The store is read by **pulling the database**, never by opening the app: opening it reconciles, which
would manufacture the very state change being measured.

```powershell
$adb = 'D:\Android\Sdk\platform-tools\adb.exe'   # NOT on PATH on this machine
$b64 = & $adb -s 1720f883 shell "run-as io.github.davamix.i_am_ok base64 databases/i_am_ok.db"
[IO.File]::WriteAllBytes("$env:TEMP\i_am_ok.db",
    [Convert]::FromBase64String((($b64 -join '') -replace '\s', '')))
python -c "import sqlite3;print(sqlite3.connect(r'$env:TEMP\i_am_ok.db').execute('PRAGMA integrity_check').fetchone()[0])"
```

That is the inverse of the documented write technique, and it works where `run-as … sqlite3` does
not — there is no `sqlite3` binary on this device. **Base64 rather than a redirect**, because
`run-as` cannot write through one; **`PRAGMA integrity_check` every time**, because a truncated
pull reads as a database with plausible-looking rows in it. Written out in full because this is the
*evidence* for ADR-0008's measurement, and evidence nobody can re-run is an assertion.

### The numbers

```
check-in created (device clock)  ->  reconcile STARTED          2 974 ms
                                     allowlist window            ~20 000 ms
FCM receiver -> Dart VM up                                       ~1 000 ms
Dart VM up -> FlutterFirebaseMessagingBackgroundService started  ~1 050 ms
```

`lastReconcileAt` is `clock.now()` taken at the *top* of reconcile, so 2 974 ms is delivery + engine
start + store open, with roughly seventeen seconds of allowlist still to run. The read itself
completed after that, and the proof it completed at all is that the cache row was rewritten.

**Re-run 2026-08-24 with the simulated-backend guard in place, and with App Check in the build:
10 359 ms**, on a handset that had been idle for three days.

**App Check was NOT in the build that produced 2 974 ms** — step 6 landed after the measurement
commit, and it now sits on this exact path: `FirebaseBootstrap.ensureInitialized()` awaits
`_activateAppCheck()` before `LocalStore.open()`, in the FCM background isolate. The controlled
comparison put it at **roughly +1.9 s** in a cold isolate (2 974 → 4 841 ms, same session, same
day). That is inside the budget and worth knowing before anyone adds a third thing to this path.

Note also that **no App Check debug token is registered** (`firebase appcheck:debugtokens:list`,
2026-08-25), so the debug provider's exchange is failing and being swallowed by design. The
live-radio run still owed below will therefore be the *first* to exercise App Check on a cold radio
in Doze — register the debug token first, or it measures a retry loop rather than the app. The allowlist did not appear until +8 s in that run against +2 s in the
first, so the extra seven seconds are **FCM delivery**, not the engine. Worth recording as a range
rather than a single number — *3–10 s from tap to reconcile, against a ~20 s grant* — because a
reader who takes 2 974 ms as the figure will conclude there is more headroom than there is. The
margin is comfortable; it is not enormous, and it is dominated by a leg this project does not
control.

**Foreground, for completeness** — a different code path, `onMessage` in the UI isolate rather than
`onBackgroundMessage`: reconciled in **397 ms**, with the process id unchanged before and after. The
unchanged pid is the part that matters; a new one would mean the background isolate did the work and
this proved nothing.

### What this does NOT settle, and it is the one thing left

**The Firestore read went to the emulator over `adb reverse` — a loopback socket, not a radio.**
ADR-0008 raises exactly this: *"a network round trip on a cold radio in Doze is a different order of
cost"*. Doze's network restrictions are applied per-uid and loopback is ordinarily exempt, so this
run cannot distinguish *the allowlist granted network* from *loopback was never blocked*.

The allowlist grant was directly observed, which weakens the objection considerably but does not
close it. **Closing it requires the same measurement against the LIVE project**, on a cold radio,
which is the first genuinely good reason this phase has had to point the app at production.

Until that runs, the honest statement is: **question 2 is answered yes; question 1 is answered yes
for everything except the real-radio round trip.**

### Does a Doze push show the user anything? Measured 2026-08-25 — and it found something else

The UI/UX review asked the one question ADR-0008's measurement never looked at: the allowlist grant
and the timing were recorded, but nobody looked at the **screen**. `firebase_messaging` reaches the
isolate through `startService()`, which on some OEM builds produces a *"running in the background"*
chip, and a payload with a `notification` block would be system-rendered.

Method: diff the exact **notification keys** for the package before and after, not a count — the tray
already held a warning from an earlier run, so a count proves nothing — and sample
`dumpsys activity services` every 2 s through the wake, because a foreground-service chip would
appear and vanish inside the window.

**The transport is silent.** No foreground service at any sample. Nothing system-rendered from the
payload, which follows from the fan-out sending no `notification` block at all — quiet-confirm holds
at the transport level, which is the strongest place it could hold.

**But a notification did appear, and it is the UI/UX review's M2 happening in front of us.**

```
channel=warnings  importance=5
android.text = "No check-in from Ana yesterday."
posted 2026-08-25 00:24:53 CEST
```

That is the app deciding, correctly, on its own channel, in its own approved copy — the self-linked
account had not checked in on the last completed day, so a warning was genuinely owed. What is new
is **when**: `Link.warningLocalTime` is 10:00, and this arrived at **00:24**, because a check-in was
written and a push woke the isolate. `WarningPolicy` owes a warning the moment `D` is complete;
`warningLocalTime` bounds only when the *alarm* asks.

So M2 is not a hypothetical any more. A watcher can be woken in the middle of the night by a warning
about a *past* day, triggered by somebody else tapping — and this run is the evidence that it is
reachable in ordinary use rather than only in an unlucky timezone pairing.

**Settled by the owner on 2026-08-25: a push may not post a warning before `warningLocalTime`.**

**Implemented 2026-08-25** — [ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md).
The warning channel is handed `NotificationDelivery.unavailable` until `now >= warningLocalTime` in
the watcher's zone, so nothing posts, nothing is recorded, `lastDecidedDay` does not advance, and the
alarm window is armed unchanged. Twelve tests in `watcher_reconcile_service_test.dart` pin the
composition and fourteen in `notification_delivery_not_before_test.dart` pin the function itself;
five of the twelve fail against a build with the gate removed, and the zone case fails against one
that resolves the hour in the watched person's zone (both mutation-checked 2026-08-25).

### The re-run — 2026-08-25 07:44–08:01, and it holds

POCO F3, **real clock, `debug_clock_offset_ms` = 0, `debug_simulated_backend` absent** — both read
out of the pulled store before and after, so the harness override that could have faked this was
provably not in the path.

**The instrument is `warningLocalTime`, not a forced date.** A second watched person (*Granddad*,
`activeFrom` 2026-08-20, no check-ins) was linked with the warning time set ahead of the real clock
and then moved, so the only thing that changed between the held run and the spoken one was the hour.
That is a cleaner mutation than shifting the clock: it leaves every other input — the day, the read,
the store, the actor — identical.

| Actor | Device time | vs `warningLocalTime` | Notification | `warnings_shown[2026-08-24]` | `last_decided_day` | today's alarm |
|---|---|---|---|---|---|---|
| App-open reconcile (UI, `available`) | 07:44:24 | before 08:30 | none | absent | null | armed 08:30 |
| **FCM push, app killed** | 07:49:01 | before 08:30 | **none** | **absent** | **null** | armed 08:30 |
| App-open reconcile (UI) | 07:51:28 | before 08:00 | none | absent | null | re-armed 08:00 |
| **Warning alarm isolate** | 08:01:00 | **past 08:00** | **posted** | **`warnOnline`** | **2026-08-24** | fired; window rolls on |

The push was real and the process was cold — `pidof` was empty before it and 6206 after, and the
platform named the reason itself:

```
UID=10612: +14s523ms - broadcast:u0a189:com.google.android.c2dm.intent.RECEIVE,reason:high-prio FCM
```

`last_reconcile_at` moved 07:44:24 → **07:49:01** on that push, which is what makes the silence mean
something: `applyRead` stamps it only inside the read-succeeded branch, so the isolate ran **and**
the Firestore read succeeded, and the warning was owed. It said nothing anyway.

Then, with nothing touched in between, the alarm at the watcher's own hour:

```
pkg=io.github.davamix.i_am_ok  channel=warnings  importance=5
android.title = "I Am Ok"
android.text  = "No check-in from Granddad yesterday."
```

**Late, never lost — measured, not argued.** The tray held nothing from this app at 07:44, 07:49 or
07:51, and held exactly this at 08:01.

**What this run does NOT establish.** Forced deep Doze could not be entered: `deviceidle force-idle`
stopped at `INACTIVE` at every attempt, because HyperOS parks the screen-off device in `Dozing`
wakefulness with a `DOZE_WAKE_LOCK` held by `DreamManagerService`. The device was screen-off,
unplugged (simulated) and the app killed, which is unattended but not Doze. Doze is not the variable
ADR-0010 turns on — the gate is a clock comparison — and ADR-0008's measurement already established
that a high-priority push wakes the isolate from deep Doze on this handset, so this was recorded
rather than chased. The `am kill` on the *second* half also did not take (HyperOS kept pid 6206
resident), so the 08:01 alarm ran in a resident process rather than a fresh one; the 07:49 push,
which is the half that matters, did not.

**The test premise was wrong first, and that is worth recording too.** The script asserted "today IS
checked in, so the reconcile has nothing to say" — while the seeded check-in was for 2026-08-21 and
the device clock had moved on to 2026-08-25. The reconcile was right and the assumption was stale,
which is the third time this phase that a measurement's premise, not its subject, was the thing at
fault.

### A row that changes under a screen reader — measured 2026-08-25 08:10, with TalkBack running

The other half of the same session, and it needed the *opposite* setup: the app **in front of the
reader**, on the watcher list, with a push arriving unasked.

Method: link a watched person with no check-ins so the row carries a warning, open the list, turn
TalkBack on, then write that person's missing day into Firestore. `onCheckInCreated` fans out, the
push lands in the foreground, `_onForegroundPush` refreshes with `userInitiated: false`, and the row
flips — which is exactly the case `NotificationDelivery.redundant` posts nothing for.

| | Read from |
|---|---|
| Row before — *"Pop. No check-in from Pop yesterday. This phone last checked 08:10."* | the accessibility tree (`uiautomator dump`), not the pixels |
| Row after — *"Pop. Everything OK Your phone last saw a check-in on Monday 24 August…"* | same |
| TalkBack spoke, 08:10:52.657 → 08:10:55.197 | `MediaFocusControl` audio focus for `USAGE_ASSISTANCE_ACCESSIBILITY/CONTENT_TYPE_SPEECH`, plus a `GoogleTTSServiceImpl` synthesis request |
| **Control: a push that changed no row, 08:12:44** — reconcile ran, **no speech at all** | the same log, and the store's `last_reconcile_at` proving the reconcile happened |

The control is what makes it evidence rather than a coincidence: the same actor, the same screen,
the same second-scale window, and the only difference is whether a row changed. Repeated once
(*Gran*, 08:14:24) with the same result.

**What it does not establish: the words.** TalkBack logs utterance text only at a log level its
default build does not use, so this run proves *that* it spoke and *when*, not *what*. The string is
asserted against the `SystemChannels.accessibility` platform message in `watcher_screen_test.dart`,
including the case where a warning lapses without a check-in and must **not** be announced.

### Announcements at API 36 — measured 2026-08-25 20:04, and the claim is false as stated

The post-gate review raised a real risk: Android 16 deprecates accessibility announcements, and if
that deprecation is a **no-op** then every announcement this app makes is silent on current Android
with nothing in the app or the suite able to see it — `WatcherCopy.checkedIn`,
`WatcherCopy.showingPerson`, and (since later the same day) the OK → warning announcement, which
speaks `NotificationCopy.warningBody` verbatim. Settled on the `Medium_Phone_API_36.0` AVD.

**They still speak.** Android 16, `ro.build.version.sdk=36`, TalkBack 16.0.0, and — read from
`dumpsys package`, not from `build.gradle.kts` — the **installed** app reports `targetSdk=36`. The
premise is verified from the platform, because the premise is the thing this measurement is about.

| | Announce dispatched | TalkBack speech focus | TTS synthesis |
|---|---|---|---|
| **Stimulus** — notification payload naming a real link | 1 | 1 | 1 |
| **Control** — identical intent, payload naming no link | **0** | **0** | **0** |
| Stimulus, repeated | 1 | 1 | 1 |
| Control, repeated | **0** | **0** | **0** |

The whole chain inside 8 ms, and the platform names its own API level in the middle of it:

```
20:04:36.931 W/AccessibilityBridge: Using AnnounceSemanticsEvent for accessibility is deprecated
                                    on Android. Migrate to using semantic properties…
20:04:36.934 I/MediaFocusControl:   requestAudioFocus() AA=USAGE_ASSISTANCE_ACCESSIBILITY/
                                    CONTENT_TYPE_SPEECH … callingPack=…marvin.talkback … sdk=36
20:04:36.939 I/GoogleTTSServiceImpl: Synthesis request for locale eng-USA
20:04:38.126 I/MediaFocusControl:   abandonAudioFocus()          <- spoke for 1.2 s
```

**The control is what makes it evidence, and this one is exact.** Both runs are the same
`am start -a SELECT_NOTIFICATION` against the same activity, differing in **one string** — the
payload. A payload naming no link makes `_onTapped` return at its `index < 0` guard, so the app
resumes identically and announces nothing. It produced total silence: no dispatch, no focus, no
synthesis. Driving the tap by replicating the notification's own intent
(`flutter_local_notifications` uses action `SELECT_NOTIFICATION` with extras `payload` and
`notificationId`) is what made an exactly-matched pair possible at all — a finger on the shade
changes the window as well as the payload.

**Two things that are true, and neither is "it works, move on".**

**1. `targetSdk` was never the trigger.** The deprecation is on Android's *behavior changes: all
apps* page, not the *apps targeting Android 16* page — it applies on Android 16 by **OS version**,
whatever the app targets. Pinning `targetSdk` at 35 would not have avoided it, and the original
write-up said it would.

**2. Flutter already reports this API as unsupported on Android — on every version.** The engine's
`AccessibilityBridge` sets `NO_ANNOUNCE` unconditionally on Android, so
`MediaQuery.supportsAnnounceOf` is **false here and always has been**, and Flutter's own widgets
(`InputDecorator`, `CalendarDatePicker`, `Autocomplete`) branch on it to `Semantics(liveRegion: true)`
instead. `SemanticsService.sendAnnouncement`'s docstring says to check that flag before calling —
this app does not, and both call sites would be no-ops the day the engine stops dispatching rather
than merely warning. It still dispatches today, and logs the warning above while doing it.

So the finding is not *"the risk was imaginary"*. It is *"the mechanism works today, and both the
platform and the framework have said in writing not to rely on it"* — which is the argument for
`liveRegion`, and the reason the OK → warning announcement is a mechanism question and not only a
copy one.

### The v4 → v5 migration, run on a real store — 2026-08-25 20:26

Not a contrived one. The API 36 AVD was carrying a store written by the **previous** build, so
installing the new APK over it exercised `onUpgrade` on a database with real rows in it — which is
the only version of this test that means anything, and it was free.

| | Before | After |
|---|---|---|
| `pragma user_version` | **4** | **5** |
| `corrections_owed` | absent | present, `(link_id, day)` |
| `links` | `granddad_`, `mum_` | **both still there** |

No `DatabaseException`, no `duplicate column name`, no `no migration to v5`, and the app went on to
reconcile and write two `watcher_cache` rows — so the store was not merely opened, it was **used**.
The premise was read out of the pulled database before the install rather than assumed from the
previous build's source.

This matters more than a schema change usually would: `LocalStore.open()` is unguarded in both entry
points, so a migration that throws means the app cannot open its store at all, and the only repair is
a reinstall — which destroys `warnings_shown` and produces a fresh round of false warnings to a
family. That is the failure `onUpgrade`'s idempotence comment is about.

### Pairing on two phones — 2026-08-26 11:12–11:28, and it found two defects

**There were TWO runs, and the write-up below reads as one until you notice the codes.** Run 1
(11:12–11:19) used code **`JJX 5VZ`** and is where both defects were found. Run 2 (11:25–11:28) was
a fresh cold install on both phones after the fixes, used code **`LWCUCQ`**, and is the one the
checklist rows above are ticked from. The timeline table further down is run 1 up to 11:19 and run 2
from 11:25; the two codes are not a contradiction, but nothing said so until the Phase 5 review read
the page against itself.

**Rig.** AVD `Medium_Phone_API_36.0` — **Android 16 / API 36**, stock — as **Mum, the watched
person** (`10.0.2.2`); POCO F3 — **Android 13 / HyperOS 1.0**, stock power settings — as **Ana, the
watcher** (`127.0.0.1` over `adb reverse`). Power settings are irrelevant to pairing and are recorded
because the per-device row format requires them. Emulator suite started detached with output
redirected to a file, per the `EPIPE` trap. Both devices **uninstalled first**, so both flows began
at sign-in.

**The measurement was verified before the result was believed**, and that check is the reason the run
means anything. Until this phase `AuthRepository._emulatorCredential` had a **hard-coded subject**, so
every emulator build signed in as the same person — two phones, one uid, and `redeemInvite` would
have refused the pairing as a self-link. `IAMOK_EMULATOR_USER` fixes it, and the fix was confirmed by
reading the accounts back out of Firestore rather than by trusting the build flags:

| uid | displayName | timezone | device |
|---|---|---|---|
| `APV0SSG3EZ4…` | Mum | `Europe/Paris` | AVD |
| `BORQFqEdPhm…` | Ana | `Europe/Madrid` | POCO |

Two distinct uids, so the run is about two people.

#### DEFECT 1 — every callable was sent to an address that does not exist on a handset

`redeemInvite` **hung until it timed out**, and the Functions emulator logged *nothing at all* — the
call never arrived. Auth and Firestore were working over the same `adb reverse`: the phone signed in,
wrote `users/{uid}` and rendered the pairing screen.

`useFunctionsEmulator` does the same `127.0.0.1 → 10.0.2.2` rewrite as the other two plugins and
defaults `automaticHostMapping` to `true`. `FirebaseBootstrap` passed `false` to Auth and Firestore
and **not** to Functions, so on a physical handset every callable went to an address that means
nothing there.

**Half the app working is what made it read as a backend fault** rather than as a host never reached.
Nothing in 1 141 Dart tests or 67 Functions tests could see it, and the AVD could not either —
`10.0.2.2` is *correct* there. It needed a physical handset, which is the whole argument for this
page. Fixed, and generalised into a `CLAUDE.md` line: three plugins, three for three, assume the next
one does it too.

#### DEFECT 2 — the summary screen was unreachable

With the callable fixed, the pairing worked and **both phones skipped screen 3 entirely**, going from
*"Skip for now"* straight to the Tap screen and the watcher list. Screen 3 is a Phase 5 deliverable
and no user ever saw it.

`OnboardingController._persist` invalidated the provider `homeRouteProvider` watches, so the moment a
question was answered **affirmatively** the route recomputed, found a role, and left onboarding. Every
piece was individually correct — the route was right, the answers were right — and the defect existed
only as *a screen a person never reaches*, which is a thing a suite of unit tests is structurally
unable to notice. The router is now told once, by `finish()`.

Both defects have regression tests. The second one's group asserts the route **while the flow is
running**, which is what the per-step tests could not see.

#### What passed, in order

| Time | What |
|---|---|
| 11:12 | Cold install, both phones. Sign-in screen on each. |
| 11:12 | Mum signs in → `users/{Mum}` written → question 1. |
| 11:14 | *"Add someone"* → `createInvite` in 351 ms → code shown as **`JJX 5VZ`**, expiry rendered *"It stops working at 11:14 am on Thursday 27 August."* — the AVD's own **12-hour** setting, honoured rather than hard-coded. |
| 11:15 | Ana skips question 1, types **`jjx5vz` in lower case** — the field upper-cases as she types. |
| 11:19 | `redeemInvite` → `status: linked`, `alreadyLinked: false`, 432 ms. |
| 11:19 | **Mum's phone, untouched, changes by itself** from *"Waiting for them to type it in."* to *"Ana will now know you're OK."* |
| — | *Both defects fixed here. Everything below is **run 2**: both phones uninstalled again, fresh sign-ins, code `LWCUCQ`.* |
| 11:25 | Both summaries: Ana *"You will be told if Mum misses a day."* (singular verb); Mum *"Ana will know you are OK when you tap each day."* + *"Tap once a day. That is all."* |
| 11:27 | Mum lands on the Tap screen; permission prompt; granted; **taps**. |
| 11:28 | Ana's list: *"Mum · Everything OK · Your phone last saw a check-in on Wednesday 26 August."* |

**The one-sitting design is the thing to keep.** Mum's phone noticing by itself is not a nicety: in
the sitting this flow assumes, the family member is holding the *other* phone, so a confirmation only
they can see leaves the person the app is for looking at an unchanged screen.

#### The rig as this session left it

**POCO F3 — the app is UNINSTALLED, deliberately.** It held an accepted link to a synthetic *Mum* on
a local emulator and **81 alarm entries** including armed warning alarms; the emulator has since been
stopped, so those alarms would have fired at 10:00 the next morning against a backend that no longer
answers and posted an offline notice about a person who does not exist — on the owner's personal
phone. Uninstalling is what stops that. **Phase 4's recorded POCO state — one self-link, 7 warning
alarms at 10:00 — is gone**, replaced by nothing; a future phase reinstalls.

**AVD — keeps the paired state**, signed in as *Mum* with an accepted link to *Ana*, onboarding
complete (`wants_to_be_watched=true`, `wants_to_watch=false`), and today's check-in recorded. It is a
scratch rig; *Wipe store* resets it.

**The emulator export did NOT run.** The suite was stopped by killing the process rather than by
`Ctrl-C`, so `emulator-data/` is still the 2026-08-25 export and today's users, invites and link are
**not** in it. The next `emulators.ps1` run starts from the older state and the AVD's local store will
reference uids the emulator no longer knows — re-pair rather than trying to reconcile it.

### Three HyperOS behaviours that cost time in this session

**`deviceidle force-idle` will not reach deep idle from a screen-off device.** It stops at
`INACTIVE`, every time, however many `step deep` calls follow. The cause is visible in
`dumpsys power`: HyperOS parks a screen-off device in `mWakefulness=Dozing` with a `DOZE_WAKE_LOCK`
held by `DreamManagerService`, and `mForceIdle` never flips. `doze_always_on` was already `0`, so
that is not the lever. ADR-0008's runs did reach deep idle, so it is reachable — just not by this
route, and not on demand.

**`am kill` does not reliably kill this app.** It worked before the first push (`pidof` empty) and
then would not touch pid 6206 through six attempts and an `am kill-all`, with the app backgrounded
and the screen off. Use `pidof` to check rather than assuming; do **not** reach for `am force-stop`
as a substitute while alarms matter — it cancels every one of them, and a force-stopped app stops
receiving FCM entirely.

**Pull the app's database with `adb exec-out`, never with a shell redirect.**
`adb shell "run-as <pkg> cat databases/i_am_ok.db > /sdcard/x.db"` creates the file, exits 0, and
`adb pull` then reports *"1 file pulled"* — of **zero bytes**. The same `cat` piped to `wc -c` returns
73728, so the data is readable and only the redirect fails. `adb exec-out run-as <pkg> cat
databases/i_am_ok.db > local.db` works and is binary-safe. This is the constraint about asserting on
content before trusting a file, in a new costume: check the byte count, or read a database that is
not there.

**Deleting a link from Firestore strands its warning alarms.** `LinkRepository.syncInto` calls
`replaceLinksFor`, so the local row disappears — and `reconcile()` iterates the links that exist, so
nothing ever cancels what the deleted one had armed. 27 orphaned alarms, in the store and on the
platform. **Revoking it instead cleans both**, because §10 step 1 is the designed path: set
`status: 'revoked'`, sync, reconcile, and the alarms and their store rows are torn down; only then
delete. Not a production path — links are revoked, never deleted — but it is the shape of a test rig
left behind for the next session.

## What one phone and an emulator can prove — decided 2026-08-20

PLAN.md's Phase 4 exit criterion is *"a tap on one **physical phone** quietly updates a **second
physical phone**"*, and **only one physical phone exists.** The choice was left open here with a
warning that *"quietly substituting the emulator would weaken the exit criterion without saying so"*.

**Decided: proceed with the POCO F3 + the `Medium_Phone_API_36.0` AVD**, and write down exactly what
that combination proves and what it does not. The criterion is met in its *functional* half and
explicitly **not** in its second-real-device half, which is listed below as owed rather than quietly
dropped.

### The direction is the decision

**POCO F3 = the watcher, the RECEIVING endpoint. AVD = the watched person, the TAPPING endpoint.**

The tap happens on the watched device; the update lands on the watcher. **The reliability-critical
endpoint is the receiver** — that is where FCM has to pierce Doze and wake a background isolate, and
it is the only side where an emulator's missing power manager would destroy the result rather than
merely limit it. With the POCO there, every check that carries risk still runs on real OEM hardware
and the AVD only has to write a check-in.

> **Never run it the other way round.** With the AVD receiving, *"data-only FCM wakes the background
> isolate"* would pass on a machine with no Doze and no vendor killer — the exact false green this
> section exists to prevent. If a run is ever done in that direction, it proves nothing and must not
> be ticked.

Prerequisite, verified rather than assumed: the AVD is `tag.id = google_apis_playstore` with
`PlayStore.enabled = true` (`~/.android/avd/Medium_Phone.avd/config.ini`), so **Google Sign-In and
FCM work on it**. An AOSP image would have made the whole arrangement impossible.

### RUNNABLE NOW — POCO + AVD

**Phase 4 — end to end.** All three, with the direction above.

> **Why the first two are still unticked when the section above records them passing.** They are
> not oversights, and they are not the same gap:
>
> - **The AVD never tapped.** Every run so far used an **admin REST write from the host** as the
>   other endpoint. That is a deliberate substitution and it is the *stronger* choice for the Doze
>   question — it isolates the receiving side completely — but it is not what these rows say. The
>   tapping endpoint being a real client, going through `firestore.rules`, is the half still owed.
> - **The read went over `adb reverse` loopback**, not a radio, so the network half of ADR-0008
>   question 1 is unproven against the live backend. See the caveat above.
>
> Ticking either now would record something that did not happen. Both are cheap once the AVD is
> running and the Functions are deployed.

- [ ] A tap on one device quietly updates the other — AVD taps → Firestore → `onCheckInCreated` →
      FCM → **POCO**
- [ ] **Data-only FCM wakes the background isolate with the app closed** — kill the app on the
      **POCO**, tap on the AVD. **This is also ADR-0008's deciding measurement, so run it as one.**
      `firebase_messaging` selects `startService()` over the JobScheduler hop **only for
      high-priority** messages (source-verified at 16.5.0), so confirm the Function sends high
      priority, put the POCO in forced deep Doze (`dumpsys battery unplug` + `deviceidle
      force-idle`), and sample `dumpsys deviceidle tempwhitelist` and `dumpsys jobscheduler` as the
      Phase 3 runs did. A pass is the first evidence that a local isolate **can** be woken inside
      Doze on this handset.
- [ ] Delivery still works after the device has been idle overnight (real Doze) — POCO as receiver;
      the AVD is not involved
- [x] **A push before `warningLocalTime` posts nothing, and the day is still owed** — 2026-08-25
      07:49, [ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md). App
      killed, real high-priority FCM, read succeeded (`last_reconcile_at` moved), **no notification**,
      the day absent from `warnings_shown` and `last_decided_day` still below `D`, today's alarm still
      armed. The same store then **posted** *"No check-in from Granddad yesterday."* at 08:01 when the
      alarm reached the watcher's own hour. Full table and the two things it does not establish — no
      forced deep Doze, and a resident process on the second half — in the section above.
- [x] **Announcements still reach TalkBack at `targetSdk 36`** — 2026-08-25 20:04, on the
      `Medium_Phone_API_36.0` AVD (Android 16, `ro.build.version.sdk=36`, TalkBack 16.0.0). **They do.
      The risk was real to raise and is false as stated**; neither shipped feature is silent. Method,
      the matched control, and the two things that are true and still matter are in *Announcements at
      API 36* below.
- [x] **A row that changes under a screen reader is announced — the warning → OK direction** —
      2026-08-25 08:10, with **TalkBack running**. A foreground push flipped a row from *"No check-in
      from Pop yesterday."* to *"Everything OK…"* (read out of the accessibility tree, before and
      after) and TalkBack took speech audio focus 1.7 s later. **Control, same run:** a second push
      that changed no row produced no speech at all. TalkBack does not log utterance **text** at its
      default level, so the device evidence is *spoke / did not speak*; the words themselves are
      pinned against `SystemChannels.accessibility` in `watcher_screen_test.dart`.

      **The direction is named because the other one has not been driven on hardware.** The
      OK → warning announcement was approved and built later the same day and goes through the
      identical `SemanticsService.sendAnnouncement` call, which the API 36 run above exercises — so
      the mechanism is established twice over and the residual risk is the app-side predicate, not
      the platform. It is covered at the widget level (`warnedSince`, six value-level cases and eight
      widget cases). Ticking this row for both directions would record a run that did not happen.

**Phase 5 — pairing.** All three, **run 2026-08-26 11:12–11:28, AVD ↔ POCO, against the emulator
suite.** Full write-up in *Pairing on two phones* below.

- [x] Two phones pair from a **cold install** using only a shared code — **AVD (Mum, watched) ↔ POCO
      (Ana, watcher)**. Both uninstalled first, so both flows started at sign-in. Code `LWCUCQ`
      created on the AVD, read off its screen, typed into the POCO **in lower case** — link
      `{Mum}_{Ana}` written by `redeemInvite` in 432 ms.
- [x] Each lands on the correct main screen from the two onboarding selections — **Mum → Tap screen**
      showing *"Ana will know you're OK."*; **Ana → watcher list** showing *"Mum · Everything OK"*.
- [x] Both Skip paths work and leave a usable app — Ana skipped question 1, Mum skipped question 2;
      both reached the summary and a working main screen.

> **What this run does NOT establish, stated rather than left to be assumed.** It went through the
> **emulator suite** over `adb reverse`, not the live project — which is what the phase brief
> instructed, and which means it says nothing about a deployed `redeemInvite`. And the exit criterion
> is about pairing, so nothing here re-measures Doze, FCM wake-up, or alarm delivery.

**Also closed by the same run — the AVD finally tapped**, which is the half Phase 4 left owed above.

- [x] **The AVD tapped as a real client** — 2026-08-26 11:27. `checkins/{Mum}/days/2026-08-26` written
      through `firestore.rules` by the app rather than by an admin REST write, `deviceTappedAt`
      09:27:42 UTC, `timezone` **`Europe/Paris`** (the AVD's own zone — the day is decided on the
      device, §11). `onCheckInCreated` then fired with `acceptedLinks: 1`, `tokens: 2`, `sent: 1`,
      `failed: 1`, `pruned: 1` — the **first end-to-end exercise of the `UNREGISTERED` pruning path**,
      against a genuinely stale token left by the previous install.
- [ ] The **receiving** half of Phase 4's row is still owed. Ana's list did show the check-in, but the
      app was **already running and on that screen**, so a foreground push and the resume reconcile
      cannot be told apart from the outside. The row above wants the app *killed*. Ticking it on this
      evidence would record a measurement that was not isolated.

**Phase 6 — away mode.** All four, one of them with a role swap. **The full Phase 6 checklist is in
*Per-device checklist* above**; these are the rows that specifically need a second handset.

- [ ] Away set from either side silences both sides everywhere
- [ ] Cancelling restores both
- [ ] **A device offline for the whole away period still ends away on the right day** — keep the
      **AVD** offline; the harness's forced-date control compresses the period so this need not take
      a real week
- [ ] Reminders for the first days back were armed *before* the trip and fire without the app being
      opened — **must run on the POCO**, because this is watched-side alarm reliability on real OEM
      hardware. Roles live on links (§1), so the POCO plays the watched person for this one test.
      **Record the role swap in the result**, or the run reads as if it contradicts the table above.

**Ongoing.** Both POCO, both need a human rather than adb.

- [ ] Permissions are still granted after the device has sat unused for several days
      (Android auto-revoke — the silent killer of an inactive watcher)
- [ ] Health panel reports every item correctly after a permission is revoked in Settings

**Still owed from Phase 3**, and not a second-device problem — it needs a person in Settings:

- [ ] **Device timezone change while backgrounded** — `cmd time_zone_detector
      suggest_manual_time_zone` needs `SUGGEST_MANUAL_TIME_AND_ZONE`, which `adb` does not hold.
      Change the zone, resume, and confirm `device_timezone` updated **and** the alarms re-armed at
      the new wall time.

### OWED UNTIL A SECOND REAL HANDSET EXISTS — do not attempt, do not tick

Every one of these is about the **watched/tapping** endpoint being a real phone, which is precisely
what the AVD cannot stand in for. They are listed so they can be picked up the day a second device
is available, rather than being rediscovered as a gap at Phase 8.

- [ ] **A real phone records a tap and syncs it under its own power management** — tapped offline,
      synced later, and still filed under the right day. §11's `serverTimestamp()` hazard is the
      reason this matters, and an emulator that is never really offline cannot exercise it.
- [ ] **The watched side's reminders fire on real OEM hardware overnight**, app never opened. Phase 2
      measured this on the POCO, but never on a *second* vendor.
- [ ] **Both endpoints in real Doze at the same time** — the actual overnight case. Today only one
      side can be, so the realistic scenario has never been run end to end.
- [ ] **The watched person's real handset**, the priority-1 row above — *"Not yet identified. The
      only device that has to work."* Likely old, so minSdk 24 and the elderly-first UI floors get
      their first honest test. Identify before Phase 8, ideally before Phase 5 so pairing is
      exercised on the hardware it will run on.
- [ ] **A second vendor** — Samsung One UI, whose "Put unused apps to sleep" is on by default.
- [ ] **A stock-Android control** (Pixel or similar) — the device that distinguishes "our bug" from
      "their power manager".

## Recording results

One row per device per phase in that phase's summary in [../phases/](../phases/), stating the
Android version, the OEM skin and its version, whether power settings were stock, and what
actually happened. A checklist that only records passes is not evidence; the failures are the
findings.

## Physical device setup

Enable Developer options (tap Build number 7×), enable USB debugging, connect as **File transfer
(MTP)** — not charging-only — and accept the on-device prompt. Xiaomi / Redmi / POCO additionally
require "Install via USB". Device must run Android 7.0 or later.

The POCO F3 is already set up and was confirmed connected on 2026-08-15:

```
M2012K11AG (mobile) • 1720f883 • android-arm64 • Android 13 (API 33)
```
