# I Am Ok

A daily "I'm OK" signal from an elderly person living alone to the family who watch over them.

One tap a day. When it happens, the family's phones update quietly. When a day passes with no tap,
each family member's phone raises a warning locally. There is also an away mode — a holiday, a
hospital stay — that suspends both sides for a bounded period.

It is **not** a health monitor and **not** an emergency-help app. It relays one notification
between two people. That boundary is deliberate and is not re-derived.

| | |
|---|---|
| Platform | Android only · Flutter · `io.github.davamix.i_am_ok` · minSdk 24 |
| Backend | Firebase — Auth, Firestore, Cloud Functions, FCM |
| Status | In development, not released. Where the work stands is in [docs/README.md](docs/README.md). |

## Documentation

Start at **[docs/README.md](docs/README.md)** — index, reading order, and the current phase. The
design is [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md); the phases and the
review gate between them are [docs/PLAN.md](docs/PLAN.md). Everything technical lives there — this
file is only how to get it building.

## Building

You need:

| | |
|---|---|
| Flutter | stable channel, Dart 3.13 or newer |
| Android SDK | platform 36, plus a device or AVD |
| JDK | 21 — the one bundled with Android Studio is fine |
| Node | 22 · only for the Cloud Functions and the security-rules tests |
| Firebase CLI | only for the local emulator suite |

Then, from a clone:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

`flutter doctor` reports Chrome and Visual Studio missing. Both are web and desktop targets that
this project does not build — ignore them.

Release builds are currently debug-signed and are not shippable; real signing arrives in Phase 8.

## Running locally

A plain `flutter run` builds against the real backend. Day-to-day work points the app at the
Firebase Emulator Suite instead, so nothing touches live data.

Start the emulators — Auth, Firestore and Functions. The script compiles the Functions TypeScript
first, so the emulator never serves a stale build, and it keeps its state between runs:

```powershell
npm --prefix functions install       # once
pwsh -File tools/emulators.ps1       # -Fresh to ignore saved state
```

It looks for a JDK and `adb` at this machine's paths; pass `-JavaHome` and `-Adb` if yours differ.

Then run the app with the emulator host baked in at compile time — `10.0.2.2` from an Android AVD,
or `127.0.0.1` from a USB-attached handset (give the script `-Device <serial>` and it sets up the
`adb reverse` for you):

```powershell
flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2 `
            --dart-define=IAMOK_EMULATOR_USER=emulator-mum `
            --dart-define=IAMOK_EMULATOR_NAME=Mum
```

The app connects two people, so pairing needs two devices — and each needs its **own**
`IAMOK_EMULATOR_USER`. Without it both sign in as the same person, and the pairing is correctly
refused.

Stop the suite with Ctrl-C. Anything else — a kill, a crash — discards that session's state with no
message at all.

### The other two suites

```powershell
pwsh -File tools/rules-test.ps1        # Firestore security rules
pwsh -File tools/functions-test.ps1    # Cloud Functions
```

Both start their own emulators and stop them again.

## What is not in this repo

The release keystore, its passwords, and any service-account key never enter version control — they
live outside the working tree. After any `.gitignore` change,
`pwsh -File tools/check-secrets-ignored.ps1` checks those guards are still in place.

`android/app/google-services.json` is committed on purpose. Its API key ships inside every APK, so
anyone can extract it, and it authorises nothing on its own — the real controls are the Firestore
security rules plus App Check. Removing it protects nothing and breaks the build from a fresh clone.
The full reasoning is in [docs/security/secrets-policy.md](docs/security/secrets-policy.md).
