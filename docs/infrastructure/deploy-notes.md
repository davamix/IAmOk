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
firebase firestore:databases:list --project i-am-ok-c74ca   # expect europe-west1 / FIRESTORE_NATIVE
firebase apps:list --project i-am-ok-c74ca
firebase apps:android:sha:list <appId> --project i-am-ok-c74ca
```

> **On Windows, `firebase apps:*` prints `√ success` and then exits 9** with a libuv assertion in
> `src\win\async.c`. The work has already completed. **Read stdout — it is printed before the
> crash — and never judge by the exit code.** Note the `:list` commands are themselves `apps:*` and
> crash the same way, so "verify with a `:list`" means *read its output*, not *check that it
> succeeded*. Likewise `apps:sdkconfig --out <path>` has crashed **before writing** and silently
> left the previous file in place. Capture stdout, assert on the content, then write.

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

## Emulators — Phase 4

Rules and Functions are tested against the emulator suite, never against the live project.

```powershell
firebase emulators:start --only firestore,functions,auth --project i-am-ok-c74ca
```

**Not runnable yet.** There is no `firebase.json` and no `functions/` directory, so this fails
today with a directory error — both arrive in Phase 4.

**Two prerequisites for this machine**, worth knowing before the first attempt rather than after:

- The Firestore emulator needs a **JDK on `PATH`**, and `java` is *not* on `PATH` here. The Android
  Studio JBR at `D:\Android\Android Studio\jbr` is the one to point at.
- Emulator export directories are git-ignored (`firebase-export-*/`, `emulator-data/`) because an
  `--export-on-exit` of real data would put check-in history in the repo.

## Prerequisites still outstanding

All Phase 4, all from [firebase-setup-prompt.md](firebase-setup-prompt.md):

- **Blaze plan** — required from the first Functions deploy onward. Free allowances mean
  effectively €0 at this scale, but a card must be on the account.
- **2nd-gen Functions APIs** — Cloud Functions, Cloud Build, Artifact Registry, Eventarc, Cloud
  Run, Pub/Sub, and the **Cloud Storage GCP API for build artifacts**. A 2nd-gen deploy fails
  confusingly if any one of them is missing; enable all of them before the first attempt.
- **FCM v1 confirmed**, legacy server key confirmed unused.
- **App Check** with Play Integrity, registered and set to **monitoring only**. Enforcing before
  the client sends App Check tokens locks the app out of its own backend.
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
