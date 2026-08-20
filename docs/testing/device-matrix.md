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

**Phase 4 — end to end.** PLAN.md's exit criterion is *"a tap on one physical phone quietly updates
a second physical phone"*, and only one physical phone exists today. Either a second handset is
found, or the criterion is met with the POCO plus the API 36 AVD as the second endpoint — which
proves the *functional* path but proves nothing about delivery reliability, since the emulator has
no OEM power manager. **Decide which before Phase 4, and record the choice**; quietly substituting
the emulator would weaken the exit criterion without saying so.

- [ ] A tap on one device quietly updates the other
- [ ] Data-only FCM wakes the background isolate with the app closed
- [ ] Delivery still works after the device has been idle overnight (real Doze) — **POCO only;
      the emulator cannot answer this**

**Phase 5 — pairing**

- [ ] Two phones pair from a **cold install** using only a shared code
- [ ] Each lands on the correct main screen from the two onboarding selections
- [ ] Both Skip paths work and leave a usable app

**Phase 6 — away mode**

- [ ] Away set from either side silences both sides everywhere
- [ ] Cancelling restores both
- [ ] **A device offline for the whole away period still ends away on the right day** — the check on
      the design's most subtle claim: expiry is arithmetic against `through`, not a transmitted
      message. Cannot be answered on one phone or in a unit test alone.
- [ ] Reminders for the first days back were armed *before* the trip and fire without the app being
      opened

**Ongoing**

- [ ] Permissions are still granted after the device has sat unused for several days
      (Android auto-revoke — the silent killer of an inactive watcher)
- [ ] Health panel reports every item correctly after a permission is revoked in Settings

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
