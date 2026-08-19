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

Phase 4 removes the claim rather than the check — `firebase_core` pulls in `play-services-basement`,
which declares `INTERNET`. When that lands, the threat model's statement has to be re-derived from
the code rather than inherited, and `android_manifest_test.dart` says so in its own docstring.
