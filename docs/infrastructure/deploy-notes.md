# Deploy notes

**Date:** 2026-08-15 · **Status:** Nothing is deployed yet. First deploy is **Phase 4**.

What is provisioned, and how it was verified, is in
[firebase-setup-prompt.md](firebase-setup-prompt.md) — including two Windows CLI traps that cost
time during setup and are now also constraints in `CLAUDE.md`. Read that first.

## Project facts

**Verified from the CLI**, not read off a console summary:

| | Value |
|---|---|
| Project | `i-am-ok-c74ca` · number `744276314021` |
| Firestore | `europe-west1`, `FIRESTORE_NATIVE` — **both permanent** |
| Android app id | `1:744276314021:android:304a9d901675e9ee748a4c` |
| CLI auth | `davamix@gmail.com` |

**Intended, not yet provisioned** — Task 4 in
[firebase-setup-prompt.md](firebase-setup-prompt.md) is still open, so nothing below has been
confirmed against the project:

| | Value |
|---|---|
| Functions region | `europe-west1` — a settled decision (ARCHITECTURE.md §1), co-located with Firestore deliberately |
| Node runtime for Functions | 22 |

Always pass `--project i-am-ok-c74ca` explicitly. There is one project and no aliases; an implicit
project is a habit that eventually deploys to the wrong one.

## Verification, before and after any deploy

Independently verified, never read off a console summary:

```powershell
firebase projects:list
firebase firestore:databases:get "(default)" --project i-am-ok-c74ca   # Location + Type
firebase apps:list --project i-am-ok-c74ca
firebase apps:android:sha:list <appId> --project i-am-ok-c74ca
```

**`databases:get`, not `databases:list`.** `:list` prints Database Name, Edition and Type only —
it has **no location column**, so it cannot confirm the one setting that is permanent. Verified
2026-08-15: `Location │ europe-west1`, `Type │ FIRESTORE_NATIVE`, created 2026-08-15T15:32:35Z.

> **On Windows, Firebase CLI commands print `√ success` and then crash** with a libuv assertion in
> `src\win\async.c`, exiting 9 (or `-1073740791` — the same fault seen through a different shell).
> The work has already completed. **Read stdout — it is printed before the crash — and never judge
> by the exit code.** So "verify with a `:list`" means *read its output*, not *check that it
> succeeded*.
>
> **Two corrections, measured at the Phase 3 gate on 2026-08-19**, because this paragraph said
> "every `apps:*` command" and both halves of that were wrong:
>
> - **It is intermittent.** `firebase apps:list --project i-am-ok-c74ca`, run three times in one
>   shell session, crashed / exited 0 / crashed. A single clean run is not evidence the trap is gone.
> - **It is not confined to `apps:*`.** `projects:list` crashes too, and `database:instances:list`
>   crashed for one reviewer and exited 0 twice for the next person. Treat *every* Firebase CLI
>   command this way — which matters most in Phase 4, where the commands that count (`deploy`,
>   `functions:list`) are not `apps:*` at all.
>
> Likewise `apps:sdkconfig --out <path>` has crashed **before writing** and silently left the
> previous file in place. Capture stdout, assert on the content, then write.

## What gets deployed, and from where

Everything ships from this repo. **Nothing is edited in the Firebase console** — a console edit to
rules or config is silently overwritten by the next deploy, and the drift is invisible until
something breaks at a bad moment.

| Artifact | Command | Phase |
|---|---|---|
| Firestore rules | `firebase deploy --only firestore:rules --project i-am-ok-c74ca` | 4 |
| Firestore indexes | `firebase deploy --only firestore:indexes --project i-am-ok-c74ca` | 4, if any query needs one |
| Functions | `firebase deploy --only functions --project i-am-ok-c74ca` | 4 |
| A single Function | `firebase deploy --only functions:onCheckInCreated --project i-am-ok-c74ca` | 4 |

Deploy rules **before** the client code that depends on them. A client shipped against rules that
are not live yet fails in a way that looks like a client bug.

## Emulators — running, 2026-08-21

Rules and Functions are tested against the emulator suite, **never against the live project**, and
from Phase 4 the client is developed against it too.

```powershell
pwsh -File tools/emulators.ps1                    # auth + firestore + functions
pwsh -File tools/emulators.ps1 -Fresh             # ignore any saved state
pwsh -File tools/emulators.ps1 -Device 1720f883   # ...and expose it to that handset
pwsh -File tools/rules-test.ps1                   # the rules suite, start to shutdown
pwsh -File tools/functions-test.ps1               # the fan-out suite + the trigger probe
```

**Verified end to end**: the suite starts and all three ports accept connections — auth 9099,
firestore 8080, functions 5001 — with the Functions definitions loaded from source. Probed by
connecting to each port from inside `emulators:exec`, not read off the startup banner.

### The emulator runs as `i-am-ok-c74ca` — corrected 2026-08-21, after a false green

This said `demo-i-am-ok`, on the reasoning that Firebase treats a `demo-` prefix as a
guaranteed-offline project. **That reasoning does not apply to the app**, and acting on it produced
a device run that proved less than it appeared to.

The app takes its project id from `android/app/google-services.json` — that is how
`Firebase.initializeApp()` finds anything — so it reads and writes under **`i-am-ok-c74ca`**
whatever the emulator was started with. The Firestore emulator serves every project id it is asked
for, in separate namespaces, and **loads `firestore.rules` into only the one named by `--project`.**

So with `demo-i-am-ok`, every read and write the app made was judged by the emulator's permissive
default rules. Proved rather than suspected, by mutating the rules and re-probing:

| | `demo-i-am-ok` | `i-am-ok-c74ca` |
|---|---|---|
| started as `demo-i-am-ok` | opening `invites/` **took effect** | opening `invites/` **changed nothing** |
| started as `i-am-ok-c74ca` | changed nothing | **took effect** |

`tools/emulators.ps1` now passes `--project i-am-ok-c74ca`, and `tools/seed-link.ps1` defaults to
the same namespace — seeding into any other produces a link the app cannot see.

**What actually keeps the app off production** is not the project id. It is `FirebaseBootstrap`
calling `useAuthEmulator` and `useFirestoreEmulator`, which happens only when `IAMOK_EMULATOR_HOST`
was set at compile time, plus the debug-only cleartext grant without which those calls cannot
connect at all. The emulator itself never reaches production whatever it is called.

`tools/rules-test.ps1` still uses `demo-i-am-ok`, and there it is a real guarantee: that suite hands
its own project id to `initializeTestEnvironment`, so the rules and the namespace cannot disagree.

> **THREE scripts want the same ports, and only one may run** — `tools/emulators.ps1` (the dev
> suite), `tools/rules-test.ps1` and `tools/functions-test.ps1`. Stop whichever is up before
> starting another, or the second fails with *"Port 8080 is not open on localhost"*, which reads
> like a broken script rather than a busy port. This said "two" until Phase 4 added the third.

**Two prerequisites for this machine**, both handled by the scripts rather than left as knowledge:

- The Firestore emulator needs a **JDK on `PATH`**, and `java` is *not* on `PATH` here. Both scripts
  set it from the Android Studio JBR at `D:\Android\Android Studio\jbr`.
- Emulator export directories are git-ignored (`firebase-export-*/`, `emulator-data/`) because an
  `--export-on-exit` of real data would put check-in history in the repo.

### The local runtime is Node 24; the deployed one is Node 22

Measured, not assumed — the emulator says so on every start:

```
!  functions: Your requested "node" version "22" doesn't match your global version "24".
   Using node@24 from host.
```

`functions/package.json` pins `"engines": {"node": "22"}`, which is what Cloud Functions deploys
against. So **the emulator runs a newer runtime than production**, which is the classic direction
for "works locally": a Node 24 API that does not exist in 22 passes here and fails after deploy.
`tsc` cannot catch it — `@types/node` is not installed and the target is `es2023`, not a Node
version. Accepted for now because these functions do little beyond the Admin SDK; if that stops
being true, install Node 22 alongside and select it, rather than relaxing the engine pin.

### Reaching the emulators from a device

They bind to **127.0.0.1 only**, deliberately: a database with no authentication listening on every
interface of a home network is not something to arrange by accident.

| | How |
|---|---|
| **API 36 AVD** | `10.0.2.2` — the emulator's built-in alias for the host loopback |
| **POCO F3** | `tools/emulators.ps1 -Device 1720f883` sets up `adb reverse` over USB, after which the phone's own `127.0.0.1` reaches this machine |

`adb reverse` rather than a LAN bind: it opens no port to the network, it dies with the cable, and
everything else in this project already drives the POCO over USB. It does **not** survive a
reconnect — re-run the script if the device is unplugged.

## Prerequisites still outstanding

All Phase 4, all from [firebase-setup-prompt.md](firebase-setup-prompt.md):

- **Blaze plan** — required from the first Functions deploy onward. Free allowances mean
  effectively €0 at this scale, but a card must be on the account.
- **2nd-gen Functions APIs** — Cloud Functions, Cloud Build, Artifact Registry, Eventarc, Cloud
  Run, Pub/Sub, and the **Cloud Storage GCP API for build artifacts**. A 2nd-gen deploy fails
  confusingly if any one of them is missing; enable all of them before the first attempt.

  > **The Cloud Functions API is ENABLED — re-measured 2026-08-24/25, three clean runs:**
  >
  > ```
  > firebase functions:list --project i-am-ok-c74ca
  > No functions found in project i-am-ok-c74ca
  > ```
  >
  > That is a *successful call*, not a 403, and it replaces this block's previous contents — which
  > recorded `SERVICE_DISABLED` on 2026-08-21 and had been false ever since. It was the checklist
  > someone would read immediately before the first deploy, saying the opposite of the truth.
  > (The command probes the *v1* endpoint while our functions are 2nd-gen; not the discrepancy it
  > looks like, since both generations live behind the same `cloudfunctions.googleapis.com`.)
  >
  > **The other six APIs are still UNVERIFIED, and cannot be checked from this machine.** `gcloud`
  > is not installed, and the Firebase CLI exposes no read for them. So the honest statement is:
  > one of seven confirmed, six unknown. Establish the rest with a **dry run**, which validates and
  > builds without deploying and surfaces (and enables) what is missing:
  >
  > ```powershell
  > firebase deploy --only functions --dry-run --project i-am-ok-c74ca
  > ```
  >
  > It is not read-only — its own help says it may enable APIs on the target project — so it is the
  > owner's call, not something to run while exploring. Blaze status shows at
  > `console.firebase.google.com/project/i-am-ok-c74ca/usage/details`.
- **FCM v1 confirmed**, legacy server key confirmed unused.
- **App Check** with Play Integrity, registered and set to **monitoring only**. Enforcing before
  the client sends App Check tokens locks the app out of its own backend.

  > **Phase 4 ships the client half; the console half is still owed**, and it has a structural gate
  > nothing here had recorded. In order: register the Android app with the Play Integrity provider ·
  > register this install's **debug token**, which `AndroidDebugProvider` prints to logcat and which
  > `firebase appcheck:debugtokens:list` confirmed is **not registered** as of 2026-08-25 · leave
  > enforcement off everywhere · watch the metrics until attested traffic is what actually arrives.
  >
  > **Play Integrity requires the app to be known to Google Play.** A sideloaded, debug-signed build
  > cannot produce a valid verdict, so release attestation does not work until the app reaches at
  > least an internal test track. Enforcement is therefore a Phase 8-or-later decision for a reason
  > that has nothing to do with metrics, and should not be scheduled earlier than it can work.
- **Delete protection and point-in-time recovery are both OFF.** Read from
  `firestore:databases:get` on 2026-08-15: `DELETE_PROTECTION_DISABLED`,
  `POINT_IN_TIME_RECOVERY_DISABLED`, version retention 3600s. Cheap hardening on a database
  holding data about vulnerable people, and delete protection in particular has no downside at
  this scale. Decide both before the first real data lands.
- **Confirm Analytics, Realtime Database, and Cloud Storage *for Firebase* remain off** — data
  minimisation is a deliberate choice for an app holding data about vulnerable people. Note this is
  the *product*, and is not the same thing as the Cloud Storage GCP API above, which 2nd-gen
  Functions need for build artifacts. The two are easy to conflate and the instructions are not in
  conflict.

## Release builds

```powershell
flutter build apk --debug
flutter build apk --release      # currently DEBUG-SIGNED — not shippable
```

Release builds are signed with the debug key today. A real signing config, the release SHA
fingerprints registered in Firebase (required for Google Sign-In to work on a release build), and
a decision on Play App Signing all land in **Phase 8**. The keystore and its passwords live in
`.local/` and a password manager — never the repo. See
[../security/secrets-policy.md](../security/secrets-policy.md).

### Check the merged release permissions whenever a plugin is added

```powershell
flutter build apk --release
Select-String -Path build\app\outputs\logs\manifest-merger-release-report.txt -Pattern INTERNET
```

Expect **no output**. `docs/security/threat-model.md` states that a release build cannot transmit,
and that claim rests entirely on `INTERNET` being absent from the merged release manifest.

**A test cannot answer this.** `test/android_manifest_test.dart` holds the half that lives in this
repo — the source manifests, and a closed set of the permissions `main` declares — but a permission
can arrive from a **transitive AAR**, where the diff is in someone else's dependency and not in any
file here. That is not hypothetical: `flutter_local_notifications` merged `VIBRATE` in uninvited
during Phase 2 and it had to be declared after the fact. So the merged report is the only real
answer, and it needs a release build, which is why it is a command here rather than a test.

**Phase 4 removed the claim rather than the check, and it is done** — measured 2026-08-21, then
twice more as plugins arrived. Six permissions became fourteen: `INTERNET` and
`ACCESS_NETWORK_STATE` from Firebase, `USE_BIOMETRIC`/`USE_FINGERPRINT` from `androidx.biometric`
behind `firebase_auth` for a feature this app does not have, `READ_GSERVICES` from recaptcha,
`c2dm.permission.RECEIVE` from `firebase_messaging`, and — a recorded **null result** —
**nothing at all** from `firebase_app_check`. The re-derived claim lives in
`docs/security/threat-model.md`; the inventory and its dates live in
`test/android_manifest_test.dart`.

**Run this whenever a plugin is added**, including when you expect no change — a rule only honoured
when it finds something stops being run, which is how the App Check measurement came to be skipped
until the Phase 4 security review asked for it.
