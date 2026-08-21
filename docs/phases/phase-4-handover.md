# Phase 4 — handover

**Written:** 2026-08-21 · **Head:** `9ffea33` · **862 tests**, `flutter analyze` clean, both
`flutter build apk --debug` and `--release` succeed.

**Phase 4 is roughly half done.** PLAN.md steps 1, 2 and 3 are built and **proven on the POCO F3
against the emulator suite**. Steps 4–7 — the Function, FCM, App Check, and ADR-0008's revisit —
are not started. ADR-0009 landed on the way through and was not in the original plan.

This document is the state, the traps, and the prompt to continue.

---

## The one-line story

Two of the four things that went wrong this phase were **false greens**: work that looked
finished and was not. One was mine — the emulator was serving the app under a project namespace
where our security rules were not loaded, so every device run confirmed the write path and proved
nothing whatever about authorisation. The other was inherited — a leftover harness row was
answering the tier-1 read while the panel reported a real backend.

Both were found the same way: **mutating the thing under test and checking the answer changed.**
Neither would have been found by looking harder at a passing result.

---

## Commits, oldest first

| Commit | What |
|---|---|
| `a433c47` | `firestore.rules`, deployed before any client can write |
| `ca87bc5` | ADR-0009 — a gap no longer drops the days inside it |
| `e4967c6` | The local loop: emulator suite, and a `functions/` package to load into it |
| `8f13f46` | Firebase in all three isolates, and an identity that is an account |
| `a0dc307` | Cleartext to the emulator, debug builds only — proven on the POCO |
| `9ffea33` | Step 3: the check-in reaches Firestore and the watcher reads it back |

---

## Where PLAN.md's Phase 4 stands

| Step | State |
|---|---|
| **2 — `firestore.rules` + rules tests, deployed first** | **Done.** 73 emulator tests, mutation-checked. Live release `cloud.firestore` → ruleset `87c8784d-42b8-45c8-8bcc-76d295656157`, read back with an independent GET. |
| **1 — `firebase_core` + `google_sign_in`** | **Done, proven on hardware.** Sign-in against the Auth emulator, confirmed from three independent sources. |
| **3 — `users/{uid}`, tokens, check-in write, the `Source.server` read** | **Done, proven on hardware.** Full loop: tap → Firestore → watcher read → `lastConfirmedDay`. |
| **4 — `onCheckInCreated`, data-only FCM fan-out** | **Not started.** `functions/` exists as a TypeScript package on Node 22 with `europe-west1` pinned and no functions in it. |
| **5 — FCM wiring in both isolates** | **Not started.** `firebase_messaging` is not a dependency. `UserRepository.saveToken` is written and uncalled. |
| **6 — App Check, monitoring only** | **Not started.** |
| **7 — ADR-0008's revisit** | **Not started.** Needs step 5. |

**Exit criterion** — *a tap on one physical phone quietly updates a second physical phone* — is not
met. Its functional half needs steps 4 and 5; its second-real-device half is permanently substituted
by the AVD, per the decision recorded in `docs/testing/device-matrix.md`.

### Not in the plan, and done anyway

**[ADR-0009](../architecture/decisions/0009-decide-about-every-completed-day.md) — `reconcile()`
decides about every completed day it has not settled**, not only the most recent. This was
ADR-0008 consequence 4, owed as a measurement. It is real, and **wider than the ADR that raised
it**: the mechanism is not Doze at all, so a phone in a drawer, a force-stop, a flat battery and a
multi-day refused read all dropped days the same way. Owner chose to fix it in Phase 4.

---

## What is actually true right now

### Provisioned

- **Cloud Functions API is enabled.** `firebase functions:list --project i-am-ok-c74ca` returns
  *"No functions found"* — a successful call, not a 403. It read `SERVICE_DISABLED` for two checks
  before that, so **verify it again before the first deploy** rather than trusting this line.
- **Blaze** — assumed active because the API enabled, **not independently confirmed**.
- Firestore `europe-west1` / `FIRESTORE_NATIVE`, unchanged and re-verified.
- App Check: still not registered, so not enforcing. The rules are the whole defence.

### The local loop

```powershell
pwsh -File tools/emulators.ps1 -Device 1720f883   # auth 9099, firestore 8080, functions 5001
pwsh -File tools/rules-test.ps1                   # the 73 rules tests, start to shutdown
pwsh -File tools/seed-link.ps1 -WatchedUid <uid> -WatcherUid <uid>
flutter run --dart-define=IAMOK_EMULATOR_HOST=127.0.0.1   # POCO, via adb reverse
flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2    # the API 36 AVD
```

**The two emulator scripts cannot run at once** — same ports. Stop one before the other.

### Device and emulator state as left, 2026-08-21 14:10

- **POCO F3 `1720f883`** connected, unlocked, debug build installed, built with
  `--dart-define=IAMOK_EMULATOR_HOST=127.0.0.1`.
- `adb reverse` live for 9099 / 8080 / 5001. **It does not survive a cable unplug** — re-run
  `tools/emulators.ps1 -Device 1720f883`.
- **Emulator suite running**, started as `--project i-am-ok-c74ca`, holding: 1 user
  (`aQs7OSHzQ59OCQd8VqfFHwpIHE93`, Ana), 1 self-link, and one check-in for `2026-08-21`.
- The **simulated backend row is cleared**, so the app's reads go to Firestore.
- The AVD is **not** running.
- The Phase 3 links keyed to `local-watched-user` are orphaned by design — identity is an account
  now. The Tap screen said *"No one is set up to know you're OK"* until a real link was seeded, and
  that was correct.

---

## The four things that went wrong, and what they cost

### 1. The emulator served the app under a namespace with no rules — a FALSE GREEN

**The worst of the four, because everything looked like it was working.**

`tools/emulators.ps1` started the suite as `--project demo-i-am-ok`, on the reasoning that Firebase
treats a `demo-` prefix as a guaranteed-offline project. **That reasoning does not apply to the
app.** The app takes its project id from `android/app/google-services.json` — that is how
`Firebase.initializeApp()` finds anything — so it reads and writes under **`i-am-ok-c74ca`**
whatever the emulator was started with.

The Firestore emulator serves every project id it is asked for, **in separate namespaces**, and
loads `firestore.rules` into **only the one named by `--project`**. So the app's reads and writes
were being judged by the emulator's permissive default rules. A device run in that configuration
confirms the write path and says nothing at all about authorisation.

**How it was proved, and how to prove it again:** open `invites/` in `firestore.rules` (the rules
are hot-reloaded) and try a client write to both namespaces over REST *without* `Bearer owner`.

| | `demo-i-am-ok` | `i-am-ok-c74ca` |
|---|---|---|
| started as `demo-i-am-ok` | opening `invites/` **took effect** | **changed nothing** |
| started as `i-am-ok-c74ca` | changed nothing | **took effect** |

Fixed in `tools/emulators.ps1` and `tools/seed-link.ps1`. **What actually keeps the app off
production** is `FirebaseBootstrap` calling `useAuthEmulator`/`useFirestoreEmulator`, which needs
`IAMOK_EMULATOR_HOST` at compile time, plus the debug-only cleartext grant — not the project id.
`tools/rules-test.ps1` still uses `demo-i-am-ok` and there it is a real guarantee, because that
suite hands its own project id to `initializeTestEnvironment`.

### 2. A leftover harness row was answering the tier-1 read

`debug_simulated_backend` from the Phase 3 device sessions survived into Phase 4 and answered the
watcher's read instead of Firestore — **correctly, by design**, while the harness reported
`EMULATOR 127.0.0.1` and the reconcile reported a successful read. Both true; neither mentioning
that no backend was involved. The symptom was `confirmed -` after a check-in had demonstrably been
written.

The harness's identity panel now leads with **which backend is answering**, and *Clear the
simulated backend* no longer claims an outcome that stopped being true in Phase 4.

**`clearSelfUid()` does not clear this row**, deliberately — it is a debug setting, not account
data. Signing out does not restore Firestore.

### 3. Both Firebase plugins silently rewrite `127.0.0.1` → `10.0.2.2` on Android

They assume any Android device is the Android emulator. On the AVD that is a kindness; on a
**physical handset** it is wrong and quiet — `10.0.2.2` means nothing there, so nothing connects
and the log says only:

```
Mapping Firestore Emulator host "127.0.0.1" to "10.0.2.2".
```

`FirebaseBootstrap` passes `automaticHostMapping: false` to both, so `IAMOK_EMULATOR_HOST` means
exactly what it says on either device.

### 4. Android blocks cleartext, and the emulator suite is plain HTTP

```
[firebase_auth/unknown] Cleartext HTTP traffic to 127.0.0.1 not permitted
```

Denied by default since API 28. The grant is `android/app/src/debug/res/xml/network_security_config.xml`
— **two loopback hosts only, debug source set only**. `test/android_manifest_test.dart` asserts both
halves, including that `main` and `profile` carry no reference: a "move it to `main` so profile
builds work too" would ship an app permitted to send plaintext.

---

## Measurement traps that still apply

Everything in `phase-3-review-handover.md` § *Measurement traps learned on the device* still holds.
These are the ones this phase added or re-confirmed.

- **`exec-out screencap -p > file` is not the trap here; a locked screen is.** A black 15,580-byte
  PNG that is *byte-identical every time* means the display is off or secured, not that the app
  crashed. Check `dumpsys power | grep mWakefulness` before debugging the app. A real screenshot on
  this device is 60–250 KB.
- **`KEYCODE_MENU` opens the notification shade** and then `mCurrentFocus=NotificationShade` covers
  everything. `dumpsys window | grep mCurrentFocus` says what you are actually looking at.
- **The harness result panel is still the fastest diagnosis in the project.** It gave the cleartext
  cause in one shot, in full, with a stack. Scroll to it before forming any theory.
- **Read the emulator's own REST API rather than the app's report.** `Authorization: Bearer owner`
  bypasses rules the way the Admin SDK does. Every claim in this phase about what reached Firestore
  was checked that way, and the project namespace is part of the URL — which is how finding 1
  surfaced.
- **`run-as … sqlite3` does not work on this device** (`Permission denied`, no `sqlite3` binary).
  Read the store through the harness's *Dump LocalStore*, or pull the file per the Phase 3 note.
- **`selfUid` is read once, at launch.** Signing in from the harness does not change the running
  session's identity. Restart the app; the control says so.

---

## Design decisions taken this phase

Beyond ADR-0009, which has its own record:

**Sign-in has no screen, and that is recorded rather than accidental.** `ui-ux/screens.md` puts
onboarding in Phase 5 and specifies no sign-in surface. Inventing an un-designed elderly-facing one
now would be a screen the UI/UX guidelines have never approved, replaced within a phase. It is
driven from the debug harness, where nothing is user-visible and no copy is owed. **Phase 5 builds
the real one.**

**Identity lives in `LocalStore`, not in `FirebaseAuth.currentUser`.** Both are available in the
alarm isolate now that it initialises Firebase. The store wins because of how each *fails*: a
`currentUser` still being restored comes back null, the reconcile finds zero links, does nothing and
reports success — the silence §12 calls the one failure this app cannot detect in itself. A stale
row instead gets `permission-denied` on every read, which ADR-0004 turns into a visible access-lost
notice. Signed out is `LocalStore.signedOutUid`, a value rather than a null, so every query answers
"nothing" by construction rather than by a guard two dozen call sites must remember.

**The check-in write is fired, not awaited.** Its future completes only when the *server* has it, so
awaiting it on a phone with no signal would hang the one action this app asks of an elderly person.
Mutation-checked: awaiting it fails two tests.

**A failed link read leaves the local set alone** — ADR-0001's rule, second use. Clearing it would
disarm every warning alarm on the device: a dead man's switch turned off by a dropped connection.

**Links are seeded by a script, not by a harness control.** A harness control would be a client, and
a client is exactly what the rules refuse. `tools/seed-link.ps1` writes one the way `redeemInvite`
will, through the emulator's rules-bypassing REST API.

---

## Known-open, carried deliberately

- **`USE_BIOMETRIC` and `USE_FINGERPRINT`** arrive in the merged release manifest from
  `androidx.biometric` behind `firebase_auth`, for a feature this app does not have. Removable with
  `tools:node="remove"`; **deliberately not removed yet**, because stripping permissions off the auth
  libraries before sign-in had ever been proven on hardware would confound the first real
  measurement. Phase 8, with a device run behind it. Recorded in `docs/security/threat-model.md`.
- **The threat model's "nothing leaves the device" is retired**, re-derived rather than deleted. Six
  permissions became thirteen; what replaces the claim is narrower and true, including that
  `warnings_shown` never leaves the device.
- **The emulator runs Node 24; production deploys Node 22.** The classic "works locally" direction,
  and `tsc` cannot catch it. Accepted while the functions do little beyond the Admin SDK.
- **`UserRepository.saveToken` / `deleteToken` are written and uncalled.** They are shaped by rules
  that are already deployed and tested; step 5 calls them.
- Everything on `phase-3-review-handover.md`'s known-open list that Phase 4 has not touched.

---

## What Phase 4 still owes

1. **Step 4 — `onCheckInCreated`**, `europe-west1`, data-only, **high priority**. The priority is
   not an implementation detail: `firebase_messaging` bypasses the JobScheduler hop with
   `startService()` only for high-priority messages, and that is what ADR-0008's revisit turns on.
   Write and test it against the emulator first.
2. **Step 5 — FCM in both isolates**, including `saveToken` on sign-in and the background handler.
   The FCM isolate is the **third** entry point: it must call `FirebaseBootstrap.ensureInitialized()`
   and will be caught by `domain_purity_test.dart` if it reaches something a bare isolate cannot
   provide.
3. **Step 6 — App Check, monitoring only.** Enforcing before the client sends tokens locks the app
   out of its own backend.
4. **Step 7 / exit criterion 2 — the deciding measurement**, on the POCO in forced deep Doze,
   sampling `dumpsys deviceidle tempwhitelist` and `dumpsys jobscheduler` as the Phase 3 runs did.
   **Run it as a measurement, not a tick.**
5. **Deploy the rules again** if they change, and **deploy the Functions** — first Functions deploy
   of the project, so expect the 2nd-gen API surprises `deploy-notes.md` lists.
6. **Run the five reviewers at the gate**, one at a time, asking first. Phase 3's rate was ~30
   findings on code whose self-review came out clean, and four rounds in five introduced a defect
   while fixing another.
7. **Write `docs/phases/phase-4-summary.md`** and stop for the owner's review.

---

## Prompt to start the next session

> I'm continuing **Phase 4** of the I Am Ok project — the Firebase backbone. Read
> `docs/phases/phase-4-handover.md` first, especially **The four things that went wrong**, then
> `docs/phases/phase-3-review-handover.md` § *Measurement traps learned on the device*, then follow
> the reading order in `docs/README.md`.
>
> **Steps 1, 2 and 3 are done and proven on the POCO F3 against the emulator suite**: rules
> deployed before any client write existed, Firebase up in all three isolates, sign-in, `users/{uid}`,
> the check-in write, the link sync, and the real `Source.server` tier-1 read. The full loop was
> driven end to end on hardware — tap → `checkins/{uid}/days/2026-08-21` → the watcher's read →
> `lastConfirmedDay`. 862 tests, `flutter analyze` clean.
>
> **[ADR-0009](../architecture/decisions/0009-decide-about-every-completed-day.md) also landed** and
> was not in the plan. ADR-0008 consequence 4 was owed as a measurement; it is real and **wider than
> the ADR that raised it** — `reconcile()` asked about one day however long since the last run, so a
> drawer, a force-stop and a flat battery dropped days with no Doze anywhere near them. Now fixed:
> every completed day not yet settled, bounded at seven, with dated copy.
>
> **What remains is steps 4–7**, in PLAN.md's order: `onCheckInCreated`, FCM in both isolates, App
> Check in monitoring mode, and ADR-0008's revisit. **Work against the emulator as far as it goes**
> and touch the live project only when the local loop has nothing left to say. The owner asked for
> that explicitly.
>
> **Two of this phase's four problems were FALSE GREENS — work that looked finished and was not.**
> Both were found by mutating the thing under test and checking the answer changed, not by looking
> harder at a passing result. Carry that method:
>
> - The emulator was serving the app under a project namespace **where our rules were not loaded**,
>   because the app's project id comes from `google-services.json` and not from `--project`. Every
>   device run confirmed the write path and proved nothing about authorisation. Fixed — but if you
>   change how the emulator starts, **re-prove it the same way**: open `invites/` in the rules and
>   check a client write to `i-am-ok-c74ca` flips from denied to accepted.
> - A leftover `debug_simulated_backend` row was answering the tier-1 read while the harness said
>   `EMULATOR 127.0.0.1`. The panel now names what is answering. Look at that line before believing
>   any read result.
>
> **Three things that will cost you time otherwise:** both Firebase plugins silently rewrite
> `127.0.0.1` to `10.0.2.2` on Android (`automaticHostMapping: false` is why the POCO works);
> Android blocks cleartext to the emulator unless the debug-only network-security config is merged;
> and `selfUid` is read **once, at launch**, so signing in from the harness needs a restart.
>
> **The device is connected and the emulator suite is running** with a signed-in user, a self-link
> and today's check-in in it. `adb reverse` is live but does not survive a cable unplug. The two
> emulator scripts cannot run at the same time — same ports.
>
> **Exit criterion 2 — "data-only FCM wakes the background isolate with the app closed" — is also
> ADR-0008's deciding measurement. Run it as one, not as a tick.** The Function's priority is part
> of the test: `firebase_messaging` bypasses the JobScheduler hop with `startService()` **only for
> high-priority** messages. Put the POCO in forced deep Doze and sample
> `dumpsys deviceidle tempwhitelist` and `dumpsys jobscheduler`, as the Phase 3 runs did.
>
> Three things to carry with you. **Verify the measurement before you trust the result** — this
> phase produced two false greens and both survived a casual look. **Read recent commits at least as
> harshly as old code**, including mine. And this is the side where a false claim to a family is the
> worst bug the app can have — prefer stopping to ask over guessing, and if you think a finding is
> wrong, say so before acting on it rather than after.
