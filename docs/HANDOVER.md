# I Am Ok — Session Handover

**Date:** 2026-08-14 · **Repo:** https://github.com/davamix/IAmOk (public) · **Branch:** `main` @ `e279ddd`

Context carried out of the setup session, for a new session that will plan the architecture.
Everything below is either verified against the machine, or an explicit decision the owner made.

---

## Where things stand

The Android project is scaffolded, builds, and is pushed. No app logic exists yet —
`lib/main.dart` is still the stock Flutter counter demo, and `pubspec.yaml` has no
dependencies beyond `cupertino_icons`. Nothing Firebase-related has been created.

| | |
|---|---|
| Local path | `f:\Development\IAmOk` |
| Dart package | `i_am_ok` (folder `IAmOk` is not a legal Dart identifier) |
| Platforms | Android only (`flutter create --platforms=android`) |
| Working tree | Clean, pushed |

Commits so far:

```
e279ddd  Changed the application label from default name to `I Am Ok`
b9618ca  Change application ID to io.github.davamix.i_am_ok
a91f027  Scaffold Android-only Flutter app
```

**Verified, not assumed:** `flutter build apk --debug` succeeds, and `aapt2 dump badging`
on the output reports `package: name='io.github.davamix.i_am_ok'`, `minSdkVersion:'24'`,
`targetSdkVersion:'36'`.

## Build configuration

| Setting | Value | Where |
|---|---|---|
| applicationId | `io.github.davamix.i_am_ok` | `android/app/build.gradle.kts:19` |
| namespace | `io.github.davamix.i_am_ok` | `android/app/build.gradle.kts:8` |
| Launcher label | `I Am Ok` | `android/app/src/main/AndroidManifest.xml` |
| compileSdk / targetSdk | 36 | Flutter defaults |
| minSdk | 24 (Android 7.0) | Flutter default |
| Java / Kotlin JVM target | 17 | `android/app/build.gradle.kts:13-15,43` |
| version | `1.0.0+1` | `pubspec.yaml` |
| Dart SDK constraint | `^3.13.0` | `pubspec.yaml` |

The org `io.github.davamix` is the GitHub-backed reverse-DNS convention — a namespace
genuinely controlled by the owner, chosen over the Play-rejected `com.example` placeholder.
**The applicationId is permanent once published to Play** and must not change again.

Release builds are currently **signed with the debug key**
(`android/app/build.gradle.kts:34-37`). Fine for sideloading; a real signing config is
required before any Play release.

Gradle wrapper scripts (`gradlew`, `gradlew.bat`, `gradle-wrapper.jar`) are **not** in the
repo — Flutter's generated `android/.gitignore` excludes them and the Flutter tool
regenerates them. This was confirmed by deleting `android/` and rebuilding successfully.
Only matters if CI later calls `./gradlew` directly instead of `flutter build`.

## Local environment

All verified on this machine. Nothing is missing for Android development.

| Tool | Version / location |
|---|---|
| Flutter | 3.47.0 stable, Dart 3.13.0, DevTools 2.60.0 — `F:\Flutter\flutter` |
| Android SDK | 36.1.0 — `D:\Android\Sdk` (`ANDROID_HOME` set) |
| Platforms | android-35, android-36, android-36.1 |
| Build-tools | 35.0.1, 36.0.0, 36.1.0, 37.0.0 |
| NDK | 28.2.13676358 |
| JDK | OpenJDK 21, bundled with Android Studio — `D:\Android\Android Studio\jbr` |
| Android Studio | 2024.3.2 (Flutter/Dart plugins **not** installed) |
| VS Code | Flutter extension installed — primary IDE |
| Emulator AVD | `Medium_Phone_API_36.0` |
| gh CLI | Authenticated as `davamix` |
| git identity | Daniel Valcarce · davamix@gmail.com |

`flutter doctor` reports two failures — **both irrelevant to this project**: Chrome missing
(web target only) and Visual Studio missing C++ components (Windows desktop target only).

`adb` and `java` are not on `PATH`. Flutter resolves both internally. For direct use:
`D:\Android\Sdk\platform-tools\adb.exe`.

## What the app is

A daily "I'm OK" signal from an elderly person living alone to family contacts who have
the app installed.

**Elderly side.** Opening the app and tapping once is the routine — like taking a pill. The
tap can happen at any time of day and notifies the contacts. If no tap has occurred, the app
shows escalating reminders at **12:00, 18:00, and 21:00** (12h, 6h, and 3h before the day
ends). The cycle restarts each day.

**Contact side.** Exactly two notifications exist:

- `Elderly tapped today at HH:MM` — on tap, any time of day
- `Elderly didn't tap yesterday` — the following day, if no tap arrived

## Explicit non-goals

The owner defined this boundary deliberately. **A new session must not re-derive the
architecture as though this were a safety-critical system.**

This is **not** a health monitor and **not** an emergency-help app. It relays a notification
from one person to another — nothing more.

- If the elderly person is incapacitated and cannot tap, detecting that is the **contacts'**
  responsibility — calling, or acting on the missing notification.
- If the app crashed and showed no reminder, noticing that is the **contacts'** responsibility.
- Phone off, dead battery, force-stopped app: **out of scope**, by decision.

The app may solve or mitigate problems it can genuinely reach (no internet, wrong clock,
reboot). It does not attempt to guarantee delivery in cases outside its control.

## Architecture decisions

### Firebase — decided

FCM, Firestore, Firebase Auth, Cloud Functions.

### Cloud Functions — required

Not optional. FCM requires service-account credentials to send, and those cannot ship inside
an APK (anyone can unzip one and extract them). The elderly device cannot push directly to
contact devices. Legacy FCM upstream/XMPP device-to-device messaging was deprecated in 2023
and shut down in 2024.

Scope is small — roughly one Firestore trigger:

```
onCreate  checkins/{uid}/days/{date}
  → read accepted links for uid
  → send FCM to each linked contact's tokens
```

**Note:** Cloud Functions requires the **Blaze (pay-as-you-go)** plan — a credit card is
needed, though free allowances mean effectively €0 at this scale.

### Cloud Scheduler — NOT required

This reversed an earlier recommendation. Server-side cron was proposed to detect *silence*
(a check-in that never happens). Given the non-goals above, that detection is not the app's
job, and the client-side design covers what remains.

The mechanism is a **dead man's switch**, implemented locally with `AlarmManager`:

- On receiving a tap notification for day *N*, the contact's app schedules a local alarm for
  day *N+1* that would fire "didn't tap yesterday"
- The next tap **cancels** that pending alarm and schedules a fresh one
- The warning only fires if no tap arrived to cancel it

`AlarmManager` fires even when the app isn't running, so this needs no server and no
background service. The elderly side works the same way: pre-schedule 12:00/18:00/21:00,
cancel all three on tap, re-arm for tomorrow.

Adding a scheduled function later is additive (~20 lines) and requires no data-model change,
so this decision is cheaply reversible.

### Data model — draft, not final

```
users/{uid}                          displayName, fcmTokens[], timezone
links/{linkId}                       elderlyUid, contactUid, status, createdAt
checkins/{uid}/days/{YYYY-MM-DD}     tappedAt, localDate, timezone
```

## Risks to handle in implementation

These are correctness issues *inside* the chosen design, not scope objections.

**Late FCM delivery causes false warnings.** A tap at 23:40 whose delivery is deferred to
08:00 (routine on Doze / battery-restricted phones) can arrive after the contact's warning
alarm already fired for a day that *was* checked in. Every incoming tap must carry the date
it belongs to, and if a warning for that date was already shown, replace it with a
correction. This is the most damaging possible bug — the family being told something false.

**Reboots wipe scheduled alarms.** Android clears all `AlarmManager` alarms on restart.
A `RECEIVE_BOOT_COMPLETED` receiver must re-arm both sides, or reminders silently stop after
any update-triggered reboot and nobody notices for days.

**Never trust device clocks.** Write `serverTimestamp()` for `tappedAt`. Define "the day" in
the **elderly person's timezone** and carry that timezone in the FCM payload, so a contact
abroad computes the same day boundary.

**Midnight is a soft boundary.** A tap at 00:05 Monday and another at 23:55 Tuesday means
~48h of real silence while both days read OK. Inherent to calendar-day check-ins; the
contact's "OK" means "sometime that day", not "within 24 hours".

**Android permissions** (targetSdk 36): `POST_NOTIFICATIONS` (runtime, API 33+), and exact
alarms. Android 14+ no longer auto-grants `SCHEDULE_EXACT_ALARM`; `USE_EXACT_ALARM` is
available to apps whose core purpose is alarms/reminders — this app plausibly qualifies,
but expect to justify it in Play review.

## Blocker inventory

| Problem | Handling | Approach |
|---|---|---|
| No internet, elderly | Solved, nearly free | Firestore offline persistence is **on by default** — a tap written offline queues to disk and syncs automatically. Do not build a retry queue |
| No internet, contact | Mitigate | Show connection state + "last update" on app open |
| Wrong device clock | Solve | Server timestamps only |
| Different timezones | Solve | Day boundary in elderly's tz, carried in payload |
| Reboot clears alarms | Solve | `BOOT_COMPLETED` re-arm |
| Notifications permission denied | Solve | Detect at launch; app is inert without it |
| Exact alarm revoked (A14+) | Detect | `canScheduleExactAlarms()`, deep-link to settings |
| FCM token rotation | Solve | `onTokenRefresh` → Firestore; prune rejected tokens |
| Late FCM → false warning | Mitigate | Late-arrival correction (see above) |
| DST / timezone change | Mitigate | `zonedSchedule` + `timezone` package, not raw offsets |
| App uninstalled | Detect | FCM returns `UNREGISTERED`; mark link stale |
| OEM battery killer | **Document** | Link dontkillmyapp.com in onboarding. Implementing per-OEM autostart handling is explicitly deferred |
| User force-stops app | **Document** | Alarms and FCM both dead; nothing to do |
| Phone off / dead battery | **Out of scope** | Human fallback, by decision |
| Elderly incapacitated | **Out of scope** | Explicitly not a health monitor |

## Open questions for the next session

Nothing below has been decided.

- **Authentication method.** Phone-number auth suits elderly users but costs money past the
  free tier. Invite codes / deep links are the alternative. Undecided.
- **Pairing flow.** How an elderly user invites a contact, and how consent is captured. Not
  designed.
- **Reminder scheduling ownership.** Local `AlarmManager` only, or local plus a high-priority
  FCM backup? High-priority FCM wakes devices from Doze; local alarms often don't. Trade-off
  not resolved.
- **Whether contacts should get a daily "all is well" push at all.** Raised as an
  alarm-fatigue risk — daily notifications that always say "fine" train people to dismiss
  them unread. A silent status the family can check, with loud notifications reserved for a
  missed check-in, was suggested as an alternative. Owner has not ruled.
- **Firebase project.** Not created. No `firebase_core` / `firebase_messaging` /
  `cloud_firestore` in `pubspec.yaml` yet.
- **Release signing config.** Still debug keys.
- **GDPR.** Health-adjacent data about vulnerable people, owner based in Spain. Store the
  minimum — a timestamp and a contact link. Not yet addressed.
- **UI/UX for elderly users.** Not started. Large tap target, high contrast, minimal chrome.
- **Testing on real OEM hardware.** The riskiest unknown. Notification reliability on
  Xiaomi/Samsung/Huawei cannot be validated on an emulator.

## Suggested next step

Two candidates, either defensible:

1. **Prove the risky part first** — build local notification scheduling on both sides with
   fake data and test on real Android hardware. Notification reliability is the single
   biggest threat to this app working at all, and it needs no backend to validate.
2. **Wire the backbone** — create the Firebase project, add the packages, and build the
   single relay function plus the check-in write.

Option 1 de-risks earlier.

## Commands

```powershell
# Run on emulator
flutter emulators --launch Medium_Phone_API_36.0
flutter run                    # r = hot reload, R = hot restart, q = quit

# Run on physical device (USB debugging + File transfer mode required)
flutter devices
flutter run

# Diagnose a device that won't appear
& "D:\Android\Sdk\platform-tools\adb.exe" devices

# Build
flutter build apk --debug
flutter build apk --release    # currently debug-signed
```

Physical device setup: enable Developer options (tap Build number 7×), enable USB debugging,
connect as **File transfer (MTP)** not charging-only, accept the on-device prompt.
Xiaomi/Redmi/POCO additionally require "Install via USB". Device must run Android 7.0+.
