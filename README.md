# I Am Ok

A daily "I'm OK" signal from an elderly person living alone to the family who watch over them.

One tap a day. When it happens, the family's phones update quietly. When a day passes with no tap,
each family member's phone raises a warning locally. There is also an away mode — a holiday, a
hospital stay — that suspends both sides for a bounded period.

It is **not** a health monitor and **not** an emergency-help app. It relays one notification
between two people. That boundary is deliberate and is not re-derived.

| | |
|---|---|
| Platform | Android only · Flutter · `io.github.davamix.i_am_ok` |
| Backend | Firebase — Auth, Firestore, Cloud Functions, FCM · `europe-west1` |
| Status | **Phase 0 of 9 complete.** Foundations only — no app code yet. |

## Documentation

Start at **[docs/README.md](docs/README.md)** — index, reading order, and current phase.

The design is [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md); the phase
plan and its review gates are [docs/PLAN.md](docs/PLAN.md).

## Building

```powershell
flutter analyze
flutter test
flutter build apk --debug
flutter run                    # r = hot reload, R = hot restart, q = quit
```

Release builds are currently **debug-signed** and are not shippable. A real signing config lands in
Phase 8.

## A note on `android/app/google-services.json`

It is committed on purpose. Its API key ships inside every APK, so anyone can extract it, and it
authorises nothing on its own — the actual controls are the Firestore security rules plus App
Check. Removing it protects nothing and breaks the build from a fresh clone.

What *is* secret — the release keystore, its passwords, and any service-account JSON — never enters
this repo. See [docs/security/secrets-policy.md](docs/security/secrets-policy.md).
