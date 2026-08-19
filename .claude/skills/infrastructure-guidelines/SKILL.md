---
name: infrastructure-guidelines
description: Firebase CLI usage, deploy procedure, and the Windows CLI traps for the I Am Ok project. Load before running any firebase command, deploying rules or Functions, changing Firebase configuration, or touching the Android build and signing setup.
---

# Infrastructure guidelines

Sources: `docs/infrastructure/firebase-setup-prompt.md` (what is provisioned, independently
verified) and `docs/infrastructure/deploy-notes.md` (how anything gets deployed).

| | Value |
|---|---|
| Project | `i-am-ok-c74ca` · number `744276314021` |
| Firestore | `europe-west1`, `FIRESTORE_NATIVE` — **both permanent** |
| Functions region | `europe-west1`, co-located with Firestore, deliberately |
| Android app id | `1:744276314021:android:304a9d901675e9ee748a4c` |
| CLI auth | `davamix@gmail.com` |
| Node runtime | 22 |

**Always pass `--project i-am-ok-c74ca` explicitly.** There is one project and no aliases; an
implicit project is a habit that eventually deploys to the wrong one.

## Two Windows traps — both already cost time here

**1. Firebase CLI commands exit 9 on success.** They print `√ success` and then crash with
`Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), src\win\async.c`. The work has already
completed. **Never treat the exit code as the result — read stdout, which is printed before the
crash.** So "verify with a `:list`" means read its output, not check that it succeeded.

This named `apps:*` and called the crash universal until 2026-08-19, when the Phase 3 gate measured
it. Both halves were wrong. It is **intermittent** — `apps:list` crashed, exited 0, then crashed
again in one shell session, so a single clean run proves nothing — and it reaches commands outside
`apps:*`, including `projects:list`. Apply it to every Firebase command, which is what matters in
Phase 4 where `deploy` and `functions:list` are the ones that count.

**2. `apps:sdkconfig --out <path>` can crash before writing** and silently leave the *previous*
file in place. On 2026-08-15 that produced a confident, wrong conclusion — that the Google OAuth
clients had never been created, when they had. Capture stdout, assert on the content, then write:

```powershell
$out  = firebase apps:sdkconfig ANDROID <appId> --project i-am-ok-c74ca 2>$null
$json = ($out -join "`n").Substring((($out -join "`n")).IndexOf('{'))
# assert oauth_client count >= 1 BEFORE overwriting, then write
```

Generalise it: **capture stdout and validate the content before overwriting any file.**

Related, and not a bug: **OAuth clients take a minute or two to propagate** after the Google
provider is enabled. An empty `oauth_client: []` immediately afterwards is expected.

## Verify, never trust a summary

```powershell
firebase projects:list
firebase firestore:databases:get "(default)" --project i-am-ok-c74ca   # Location + Type
firebase apps:list --project i-am-ok-c74ca
firebase apps:android:sha:list <appId> --project i-am-ok-c74ca
```

**Use `databases:get`, never `databases:list`, to check the location.** `:list` prints only
Database Name, Edition and Type — there is no location column, so it silently cannot answer the
question. Verified 2026-08-15: `europe-west1`, `FIRESTORE_NATIVE`.

## Deploying

Everything ships **from this repo**. Nothing is edited in the Firebase console — a console edit is
silently overwritten by the next deploy and the drift stays invisible until something breaks at a
bad moment.

```powershell
firebase deploy --only firestore:rules --project i-am-ok-c74ca
firebase deploy --only functions --project i-am-ok-c74ca
firebase deploy --only functions:onCheckInCreated --project i-am-ok-c74ca
firebase emulators:start --only firestore,functions,auth --project i-am-ok-c74ca
```

**Deploy rules before the client code that depends on them.** A client shipped against rules that
are not live yet fails in a way that looks like a client bug.

Rules and Functions are tested against the **emulator suite**, never the live project.

## Outstanding prerequisites — all Phase 4

- **Blaze plan.** Required from the first Functions deploy. Free allowances mean ~€0 at this scale,
  but a card must be on the account.
- **2nd-gen Functions APIs** — Cloud Functions, Cloud Build, Artifact Registry, Eventarc, Cloud
  Run, Pub/Sub, and the Cloud Storage **GCP API** for build artifacts. A 2nd-gen deploy fails
  confusingly if any one is missing; enable all of them before the first attempt.
- **FCM v1 confirmed**, legacy server key confirmed unused.
- **App Check** with Play Integrity, **monitoring mode only**. Enforcing before the client sends
  App Check tokens locks the app out of its own backend. Until enforcement is on, App Check blocks
  nothing — the rules are the whole defence.
- **Confirm Analytics, Realtime Database, and Cloud Storage *for Firebase* stay off** — data
  minimisation, deliberate for an app holding data about vulnerable people. This is the *product*,
  not the Cloud Storage GCP API above that 2nd-gen Functions need; the two are easy to conflate.

## Android build

```powershell
flutter build apk --debug
flutter build apk --release      # currently DEBUG-SIGNED — not shippable
```

minSdk 24 · target/compileSdk 36 · JVM target 17 · applicationId `io.github.davamix.i_am_ok`,
**permanent once published**. Gradle wrapper scripts are intentionally not in the repo — Flutter
regenerates them. Only matters if CI ever calls `./gradlew` directly instead of `flutter build`.

Release signing, release SHA fingerprints in Firebase (required for Google Sign-In on a release
build), and the Play App Signing decision are all **Phase 8**.

## Credentials

`android/app/google-services.json` is committed **on purpose** — its key ships in the APK and
authorises nothing on its own. Service-account JSON and keystores go in `.local/` and never the
repo. After any `.gitignore` change run `pwsh -File tools/check-secrets-ignored.ps1`. Full
reasoning: `docs/security/secrets-policy.md`.
