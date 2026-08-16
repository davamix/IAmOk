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
| 24–29 | The floor. No runtime notification permission at all. | No |
| 30 (11) | **Auto-revoke of permissions for unused apps** begins — the silent watcher-killer. | **Yes** — POCO F3 |
| 31 (12) | `SCHEDULE_EXACT_ALARM` becomes revocable; `canScheduleExactAlarms()` starts mattering. | **Yes** — POCO F3 |
| 33 (13) | `POST_NOTIFICATIONS` becomes a runtime permission. Without it the app is inert. | **Yes** — POCO F3 |
| 34+ (14+) | Exact alarms no longer auto-granted; `USE_EXACT_ALARM` is the route, and Play review asks about it. | **No — real gap** |

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
| **Lock in recents** | Off | Swiping the app from recents kills it and its alarms. |
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
      instants across 7 days; a reminder arriving unattended at 12:00 is still unobserved*
- [x] A tap cancels the remaining reminders for that day
- [x] Alarms survive a reboot — **~76 s after `sys.boot_completed`, not immediately**
- [x] The window re-arms for following days **without the app being opened**
- [x] The tap target is disabled for the rest of the day and re-enables at local midnight
- [x] Notification permission denial is detected and explained
- [x] The debug harness works on-device: force date, fire alarm now, dump `LocalStore`, run
      `reconcile()`. Without it every later item on this page costs a day to verify.

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

**Phase 3 — watcher side**

- [ ] A warning fires when it should
- [ ] Suppressed when a check-in is cached
- [ ] Suppressed when an away period covers the day
- [ ] Replaced by a correction when a late check-in arrives
- [ ] A *different and honest* message when the device cannot reach the network
- [ ] The alarm isolate survives the app being swiped away from recents

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
