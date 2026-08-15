# Device matrix

**Date:** 2026-08-15 · **Status:** Incomplete — the physical device rows are unfilled and are
**owed before Phase 2**, whose exit criteria cannot be met on an emulator.

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
| `Medium_Phone_API_36.0` | Emulator AVD | 36 | Verified present. Useless for the questions that matter — see below. |
| *(none recorded)* | Physical | — | **Owed.** |

```powershell
flutter emulators --launch Medium_Phone_API_36.0
flutter devices
& "D:\Android\Sdk\platform-tools\adb.exe" devices     # when a device will not appear
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

| Priority | Vendor | Why |
|---|---|---|
| 1 | **Whatever the watched person will actually use** | The only device that has to work. Everything else is generalisation. |
| 1 | **Whatever the watcher will actually use** | The auto-revoke risk lands here — a watcher may not open the app for weeks. |
| 2 | Xiaomi / Redmi / POCO (MIUI / HyperOS) | The most aggressive killer of background work. Also needs "Install via USB" enabled to sideload at all. |
| 2 | Samsung (One UI) | Largest install base; "Put unused apps to sleep" is on by default. |
| 3 | Huawei (EMUI) | Aggressive, and no Play Services — **FCM does not work at all**. Would need a decision, not a fix. |
| 4 | A stock-Android device (Pixel or similar) | The control. Distinguishes "our bug" from "their power manager". |

> **Fill in rows 1 and 1 before Phase 2 starts.** The design's two riskiest assumptions are about
> those two specific handsets, and testing a phone nobody in this family owns proves less than
> testing the one that matters.

### The API-level axis, which the vendor axis does not cover

Vendor spread alone is not enough, because the permission model this app depends on changes by API
level, and the watched person's phone is likely to be old — minSdk is 24 for a reason.

| API | What changes |
|---|---|
| 24–29 | The floor. No runtime notification permission at all. |
| 30 (11) | **Auto-revoke of permissions for unused apps** begins — the silent watcher-killer. |
| 31 (12) | `SCHEDULE_EXACT_ALARM` becomes revocable; `canScheduleExactAlarms()` starts mattering. |
| 33 (13) | `POST_NOTIFICATIONS` becomes a runtime permission. Without it the app is inert. |
| 34+ (14+) | Exact alarms no longer auto-granted; `USE_EXACT_ALARM` is the route, and Play review asks about it. |

The only device available today is API 36. Two modern handsets on Android 14+ would leave the
permission behaviour on an old phone — the app's actual target — completely unexercised. **Cover at
least one device at API 33 or below** alongside the vendor spread, or state explicitly that the
low-API path is untested and accept that risk.

## Per-device checklist

Run against **stock power settings first** — the default state is the one real users are in. Then,
if something fails, repeat with battery optimisation disabled to establish whether the failure is
fixable by onboarding guidance or not at all.

**Phase 2 — watched side**

- [ ] Reminders fire at 12:00, 18:00, 21:00 local
- [ ] A tap cancels the remaining reminders for that day
- [ ] Alarms survive a reboot
- [ ] The window re-arms for following days **without the app being opened**
- [ ] The tap target is disabled for the rest of the day and re-enables at local midnight
- [ ] Notification permission denial is detected and explained
- [ ] The debug harness works on-device: force date, fire alarm now, dump `LocalStore`, run
      `reconcile()`. Without it every later item on this page costs a day to verify.

**Phase 3 — watcher side**

- [ ] A warning fires when it should
- [ ] Suppressed when a check-in is cached
- [ ] Suppressed when an away period covers the day
- [ ] Replaced by a correction when a late check-in arrives
- [ ] A *different and honest* message when the device cannot reach the network
- [ ] The alarm isolate survives the app being swiped away from recents

**Phase 4 — end to end**

- [ ] A tap on one physical phone quietly updates a second physical phone
- [ ] Data-only FCM wakes the background isolate with the app closed
- [ ] Delivery still works after the device has been idle overnight (real Doze)

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
