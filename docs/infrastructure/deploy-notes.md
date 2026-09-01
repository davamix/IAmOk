# Deploy notes

**Date:** 2026-08-15 · **Status, re-verified 2026-09-01:** **the repo is AHEAD of the live ruleset.**
A ruleset is deployed — `87c8784d-42b8-45c8-8bcc-76d295656157`, released 2026-08-20 — but Phase 6
changed `firestore.rules` on 2026-08-31 and **that change is not deployed**. The live source is
16 923 bytes against the repo's 19 142; it still carries the flat
`request.resource.data.from == resource.data.from` and has neither `setByName.trim()` nor
`awayPeriodEnded()`. **No Functions are deployed**; `firebase functions:list` returns *No functions
found*.

**This is the intended state until the final deployment.** The Firebase Local Emulator Suite is the
working surface for the rest of the build, and the repo will stay ahead of live by design; the drift
is not a defect and does not need closing now. What matters is the **ordering rule** below — rules
before any client not pointed at the emulator — because until it is replaced the live ruleset still
carries the **set-once defect** (a family that took a holiday in July can never mark that person away
again, arriving as `permission-denied` and surfaced as a refusal blaming the chosen day). Note in
passing that a plain `flutter build apk --debug` carries no `--dart-define=IAMOK_EMULATOR_HOST` and
so talks to `i-am-ok-c74ca`.

> **This header has now been wrong twice, in the same direction.** It said *"Nothing is deployed
> yet"* until 2026-08-26, five days after the rules went live; it said *"byte-identical"* until
> 2026-09-01, one day after they stopped being. That is the failure this file already catalogues
> below — *"the checklist someone would read immediately before the first deploy, saying the opposite
> of the truth"* — recurring in the file's own header, twice. Both times the project's record was
> **correct in the wrong file**: `phase-4-handover.md` then, and `phase-6-summary.md`,
> `phase-6-handover.md` and `phase-7-brief.md` now. Re-read the live ruleset back at every gate; the
> read-only command is at the bottom of this file.

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

| Artifact | Command | State |
|---|---|---|
| Firestore rules | `firebase deploy --only firestore:rules --project i-am-ok-c74ca` | **Deployed** 2026-08-20 |
| Firestore indexes | `firebase deploy --only firestore:indexes --project i-am-ok-c74ca` | Not needed yet — every query so far is single-field equality, which Firestore indexes automatically |
| Functions | `firebase deploy --only functions --project i-am-ok-c74ca` | **None deployed.** Four exist: `onCheckInCreated`, `createInvite`, `redeemInvite`, and `onAwayChanged` (Phase 6) |
| A single Function | `firebase deploy --only functions:redeemInvite --project i-am-ok-c74ca` | — |

Deploy rules **before** the client code that depends on them. A client shipped against rules that
are not live yet fails in a way that looks like a client bug.

**And deploy Functions before any client build that is not pointed at the emulator.** From Phase 5
the pairing flow — the *first screen a new user reaches* — is two callables. A client shipped ahead
of them gets a 404 (`not-found`), which `InviteService` maps to **`serverFault`** — *"That did not
work just now. Try again in a moment."* — for ever. Same class of failure as the rules rule above,
arriving through a different service, and nothing in this runbook named it until Phase 5.

**This paragraph said `couldNotReach` until the Phase 5 gate**, which the same commit that closed the
phase had already made false: `not-found` now falls through to `serverFault`. Corrected here rather
than left, because this file's own header records that its recurring failure is *the checklist
somebody reads immediately before the first deploy, saying the opposite of the truth*.

**And the ordering rule matters more now, not less.** The old sentence at least named a cause, false
though it was. `serverFault` deliberately claims nothing about either side — right for the reader,
and it leaves them nothing to report. Deploying in the wrong order now produces *"try again in a
moment"*, indefinitely, on every new phone, with nothing on screen to say why.

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

**`tsc` now catches it, and the sentence that used to stand here was wrong.** This paragraph said
*"`@types/node` is not installed"*. It was — `@types/node@26.2.0` came in transitively under
`firebase-admin`, four majors ahead of the deployed runtime, so the TypeScript program was typed
against **Node 26** while production ran **Node 22**. That is the same gap the paragraph describes,
one layer up and with the compiler agreeing rather than staying silent, and it went unread for as
long as the claim did.

Phase 5 made it load-bearing: `invites.ts` imports `node:crypto`, this project's first Node builtin.
A Node 23+ API would have type-checked clean, run clean in the emulator, and failed only after
deploy.

Pinned when Phase 5 closed, 2026-08-26:

```powershell
npm install --save-dev "@types/node@^22"     # from functions/, not with --prefix — see below
npx tsc --noEmit                             # clean at 22.20.1
```

> **Run it from inside `functions/`.** `npm --prefix functions install …` typed at a shell that is
> *already* in `functions/` resolves the prefix relative to the cwd and silently creates
> `functions/functions/` with its own `package.json` — no error, and `npm ls` then reports a
> package called `functions`. It happened on 2026-08-26 and was caught only by reading the output
> rather than the exit code.

The engine pin stays where it is: the target is `es2023`, not a Node version, so **the types are
what constrain the API surface** and they now match what deploys. The runtime gap itself remains —
if it ever needs closing, install Node 22 alongside and select it, rather than relaxing the engine
pin.

### Reaching the emulators from a device

They bind to **127.0.0.1 only**, deliberately: a database with no authentication listening on every
interface of a home network is not something to arrange by accident.

| | How |
|---|---|
| **API 36 AVD** | `10.0.2.2` — the emulator's built-in alias for the host loopback |
| **POCO F3** | `tools/emulators.ps1 -Device 1720f883` sets up `adb reverse` over USB, after which the phone's own `127.0.0.1` reaches this machine |

`adb reverse` rather than a LAN bind: it opens no port to the network, it dies with the cable, and
everything else in this project already drives the POCO over USB. It does **not** survive a
reconnect — re-run the script if the device is unplugged. It also dies with an adb **server**
restart, not only a cable unplug.

> **Every FlutterFire API that takes an emulator host rewrites `127.0.0.1` → `10.0.2.2` on Android
> unless passed `automaticHostMapping: false`.** Auth, Firestore and Functions all do it and all
> default it **on**; assume the next one does too.
>
> This is the moment it bites, which is why it is here as well as in `CLAUDE.md`. On the AVD the
> rewrite is a kindness. On a physical handset over `adb reverse` it is silent and wrong, and the
> symptom is **half the app working**: Phase 5 signed in, wrote `users/{uid}` and rendered the
> pairing screen, then every callable went to an address that means nothing on that phone and
> `redeemInvite` hung until it timed out with the Functions emulator logging nothing at all. It read
> as a backend fault for most of a session.
>
> `test/android_manifest_test.dart` now counts the wiring calls against the opt-outs, so a fourth
> service cannot be added without one.

**Two devices need two identities.** The Auth emulator is given a synthetic subject at compile time
(`IAMOK_EMULATOR_USER`), and it defaults to one value — so two phones built without it sign in as
**the same person**, and `redeemInvite` correctly refuses the self-link. That was a blocker for
Phase 5's exit criterion until it was parameterised:

```powershell
flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2 `
            --dart-define=IAMOK_EMULATOR_USER=emulator-mum `
            --dart-define=IAMOK_EMULATOR_NAME=Mum
```

The email is derived from the subject and must stay derived: the Auth emulator links a new provider
identity onto an existing account that shares an email address, which would collapse two subjects
back to one uid.

### The local Functions emulator CAN send real FCM, with no credentials set up

Measured 2026-08-21, and worth knowing before anyone goes looking for a service-account key.

**There is no FCM emulator and there never will be** — sending a push is the one thing in this
project that cannot be exercised locally. The expectation was therefore that `onCheckInCreated`
running in the emulator would fail at the transport with an authentication error, and that a real
end-to-end test would need either `gcloud auth application-default login` or an Admin SDK key in
`.local/`.

**Neither is needed.** With `gcloud` **not installed** and **no ADC file present**
(`%APPDATA%/gcloud/application_default_credentials.json` does not exist), the emulator fetched a
token and delivered:

```
!  Google API requested!
   - URL: "https://oauth2.googleapis.com/token"
>  {"acceptedLinks":1,"tokens":1,"sent":1,"failed":0,"pruned":0,…,"message":"onCheckInCreated: fanned out"}
```

The message arrived on the POCO F3. The **mechanism is inferred rather than verified**: the Firebase
CLI is logged in as `davamix@gmail.com`, and firebase-tools appears to hand the functions emulator
credentials derived from that login. What is *measured* is the outcome — a real push, from a local
function, with nothing provisioned by hand.

Two consequences:

- The local loop reaches **further than expected**: everything except the transport is emulated, and
  the transport is real. That is what made ADR-0008's deciding measurement possible without
  deploying anything.
- **It also means a careless local run can send real pushes to real devices.** Today that is only
  ever this project's own handset, because the token comes from `users/{uid}/tokens/…` in the
  *emulated* Firestore. It stops being harmless the moment the emulator is pointed at a namespace
  holding real tokens.

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
  > **SETTLED 2026-08-25 with `gcloud`, and four of them are MISSING.** The paragraph below said
  > this could not be checked from this machine. That was wrong: `gcloud` **is** installed
  > (Google Cloud SDK 581.0.0, authenticated, project already set to `i-am-ok-c74ca`), and
  > `gcloud services list --enabled` is read-only, costs nothing, and answers it outright.
  >
  > | | API | State |
  > |---|---|---|
  > | ✅ | Cloud Functions | `cloudfunctions.googleapis.com` — enabled |
  > | ✅ | Pub/Sub | `pubsub.googleapis.com` — enabled |
  > | ✅ | Cloud Storage (build artifacts) | `storage.googleapis.com` — enabled |
  > | ❌ | **Cloud Build** | `cloudbuild.googleapis.com` — **missing** |
  > | ❌ | **Artifact Registry** | `artifactregistry.googleapis.com` — **missing** |
  > | ❌ | **Eventarc** | `eventarc.googleapis.com` — **missing** |
  > | ❌ | **Cloud Run** | `run.googleapis.com` — **missing** |
  >
  > So **the first 2nd-gen deploy would fail as things stand**, and the confusing failure this
  > section warns about is not hypothetical — it is the state the project is in right now. Enabling
  > them is one command and **is a state change**, so it is the owner's call:
  >
  > ```powershell
  > gcloud services enable artifactregistry.googleapis.com cloudbuild.googleapis.com `
  >   eventarc.googleapis.com run.googleapis.com --project i-am-ok-c74ca
  > ```
  >
  > **Blaze is on** — also previously unverified, also read-only to check:
  > `gcloud billing projects describe i-am-ok-c74ca` returns `billingEnabled: true` on account
  > `01624A-39CA4E-9FAD40`. Enabling the four APIs above is therefore *billable* rather than
  > blocked: Artifact Registry charges for stored images and Cloud Build for build minutes, both
  > small at this scale but no longer free-tier-only. That is the reason to keep exercising
  > Functions against the **local emulator suite** until a deploy is actually needed.
  >
  > <details><summary>The superseded claim, kept because it is what the habit is for</summary>
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
  >
  > </details>
  >
  > **Why this was worth catching rather than working around.** The dry run above was proposed
  > *because* the state was believed unknowable, and it is a state change — it enables what is
  > missing as a side effect. The read-only answer was one command away the whole time. Two claims
  > in this file were false in the same sentence: that `gcloud` is not installed, and that the
  > Firebase CLI being limited made the question unanswerable.
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
  >
  > **For the two Phase 5 CALLABLES, enforcement is a code change and not the console toggle above.**
  > A 2nd-gen callable enforces App Check through `enforceAppCheck: true` in its `onCall` options,
  > deployed from this repo — the console switch does not reach it. Neither `createInvite` nor
  > `redeemInvite` sets it today, which is correct while no client is verified sending tokens.
  >
  > It matters because `OPEN-QUESTIONS.md` #11 and ADR-0011 both name App Check enforcement as *the*
  > designed control against `redeemInvite` guessing. Flipping the console switch and believing that
  > covered it would leave both callables wide open **while the register said the control was on** —
  > a control believed live and not live, which is worse than one known absent.
  >
  > Order, when it happens: verify the client is sending tokens → set the flag in
  > `functions/src/index.ts` → `firebase deploy --only functions` → then the console.
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
if ($LASTEXITCODE -ne 0) { throw 'release build FAILED - anything below is the PREVIOUS build' }

# Locate the merged manifest rather than hard-coding the path: it is an AGP
# implementation detail and it has moved before. Fail loudly if it moves again.
$m = (Get-ChildItem build\app\intermediates\merged_manifest\release -Recurse `
        -Filter AndroidManifest.xml | Select-Object -First 1).FullName
if (-not $m) { throw 'the merged manifest moved - find its new path before trusting this' }
$xml = Get-Content $m -Raw

# 1. permissions - counted from the manifest, which cannot double-count
[regex]::Matches($xml, '<uses-permission[^>]*android:name="([^"]+)"') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

# 2. components - including meta-data, which is how a plugin most often arrives
[regex]::Matches($xml,
  '<(provider|receiver|service|activity|activity-alias|meta-data|uses-library)[^>]*>') |
  ForEach-Object { $_.Value }
```

Expect the **thirteen** in `test/android_manifest_test.dart`, and no fourteenth.

> **Three corrections, all made at the Phase 5 gate review, and each is the same mistake in a
> different place: a check cited as evidence for something it structurally cannot see.**
>
> - **Step 1 read the merger report and got fourteen.** The report lists AndroidX's
>   `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` twice — once with `${applicationId}` unresolved and
>   once resolved — so the grep double-counted one permission. The manifest itself has **13**
>   distinct `<uses-permission>` elements. The repo's own arithmetic already disagreed with itself:
>   six declared plus seven merged is thirteen.
> - **Step 2's alternation had no `meta-data`**, while the finding it is cited for below —
>   `cloud_functions` contributing Firebase component registrars — is *entirely* meta-data. It could
>   not have seen what the paragraph says it measured.
> - **Neither step checked that the build succeeded, or that the files came from it.** Gradle marks
>   the merge task UP-TO-DATE and leaves the previous run's outputs in place, so a failed build
>   leaves both commands reading stale files and exiting 0. That is `CLAUDE.md`'s `--out` constraint
>   word for word, in a new place.
>
> **And read the merged manifest, not the merger report, for anything about a component.** The report
> lists attribute *names* without their *values* — it says `android:exported` was added and never
> what it was set to, which is the entire question you are asking.
>
> **The path is an AGP implementation detail.** `merged_manifest/release/` holds two byte-identical
> copies, under `outputReleaseAppLinkSettings/` and `processReleaseMainManifest/`; the layout already
> changed once between AGP 7 and 8, and this project is on AGP 9.1.0. Hence the glob and the throw
> rather than a literal.

> **Step 2 was added when Phase 5 closed, and step 1 was widened.** This block used to be a single
> `Select-String … -Pattern INTERNET` expecting no output — which had been wrong twice over since
> Phase 4 measured that a release build *does* hold `INTERNET`, merged in from Firebase. Worse, it
> greps for a **permission**, so it cannot see a plugin that adds a *component*: `share_plus`
> contributes a `ShareFileProvider` and a `SharePlusPendingIntent` receiver and not one permission,
> and the documented check would have reported a clean result.
>
> **Read the merged manifest, not the merger report, for anything about a component.** The report
> lists attribute *names* without their *values* — it says `android:exported` was added and never
> what it was set to, which is the entire question you are asking.

**A test cannot answer this.** `test/android_manifest_test.dart` holds the half that lives in this
repo — the source manifests, and a closed set of the permissions `main` declares — but a permission
can arrive from a **transitive AAR**, where the diff is in someone else's dependency and not in any
file here. That is not hypothetical: `flutter_local_notifications` merged `VIBRATE` in uninvited
during Phase 2 and it had to be declared after the fact. So the merged report is the only real
answer, and it needs a release build, which is why it is a command here rather than a test.

**Phase 4 removed the claim rather than the check, and it is done** — measured 2026-08-21, then
twice more as plugins arrived. Six permissions became thirteen: `INTERNET` and
`ACCESS_NETWORK_STATE` from Firebase, `USE_BIOMETRIC`/`USE_FINGERPRINT` from `androidx.biometric`
behind `firebase_auth` for a feature this app does not have, `READ_GSERVICES` from recaptcha,
`c2dm.permission.RECEIVE` from `firebase_messaging`, and — a recorded **null result** —
**nothing at all** from `firebase_app_check`. The re-derived claim lives in
`docs/security/threat-model.md`; the inventory and its dates live in
`test/android_manifest_test.dart`.

**Measured a fourth time when Phase 5 closed, 2026-08-26**, after `share_plus` and `cloud_functions`
were added, then **re-measured at the gate review**. Permissions: **thirteen, no change** — neither
plugin contributes one. Components: `share_plus` adds a `ShareFileProvider` and a
`SharePlusPendingIntent` receiver, **both `android:exported="false"`**, the provider's authority
scoped to this application id, plus a `FILE_PROVIDER_PATHS` meta-data — which is the thing that
actually bounds what the provider could expose, and is worth naming in a paragraph that argues it is
harmless. `cloud_functions` adds **three** `meta-data` Firebase registrars
(`FlutterFirebaseAppRegistrar`, `FunctionsRegistrar`, `FirebaseFunctionsKtxRegistrar`), not one.
Recorded with the rest in `test/android_manifest_test.dart`, including the note that the provider is
present and **unused** — this app shares text, never a file, so no URI is ever minted.

**Run this whenever a plugin is added**, including when you expect no change — a rule only honoured
when it finds something stops being run, which is how the App Check measurement came to be skipped
until the Phase 4 security review asked for it.
