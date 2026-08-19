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
- [ ] Suppressed when a check-in is cached · suppressed when away covers the day · replaced by a
      correction · a different and honest message when unreachable — covered by tests and reachable
      from the harness, but **not yet driven end-to-end on the device**. The `warnOnline` path now
      has been; the other three have not.
- [x] **The warning alarm survives a reboot**, 2026-08-18 — 35 armed, rebooted, and the **identical
      35 instants** back at uptime 100 s (0 at 39 s, 59 s and 79 s, so poll for minutes). Restored by
      the plugin's `RebootBroadcastReceiver` from its own record: `last_reconcile_at` was unchanged
      afterwards, so **a reboot restores what was armed, not what should be** — only a reconcile
      repairs a divergence.
- [ ] **Two isolates contend for the reconcile lease and only one changes the alarm set** —
      [ADR-0006](../architecture/decisions/0006-reconcile-is-serialised-on-disk.md). Asserted in
      `test/data/local_store_lock_test.dart` across two connections to one file, but that runs on
      `sqflite_common_ffi`'s **desktop** SQLite; whether Android's honours `BEGIN EXCLUSIVE` the same
      way between two isolates is the same API-level gap that hid the UPSERT defect. Fire the alarm
      while the app is open in the foreground and confirm the store and `dumpsys` still agree.
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
