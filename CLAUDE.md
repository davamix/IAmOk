# I Am Ok

Android-only Flutter app. An elderly person taps once a day; the family watching over them are
updated quietly. A missed day raises a warning locally on each watcher's phone. Not a health
monitor and not an emergency-help app — the non-goals in `docs/HANDOVER.md` are the boundary.

Read before working: **`docs/README.md`** (index, reading order, current phase) →
`docs/architecture/ARCHITECTURE.md` (the design; nothing may contradict it) → `docs/PLAN.md`
(the nine phases and the review gate between them). Working rules per topic are in
`.claude/skills/`; the five reviewers in `.claude/agents/` apply them at each gate.

Firebase project `i-am-ok-c74ca` · Firestore `europe-west1` · Native mode — all three permanent.

```powershell
flutter analyze
flutter test
flutter build apk --debug
flutter run                                         # device must be in File transfer (MTP) mode
pwsh -File tools/check-secrets-ignored.ps1          # after any .gitignore change
firebase firestore:databases:get "(default)" --project i-am-ok-c74ca   # :list has no Location column
```

`flutter doctor` reports Chrome and Visual Studio missing. Both are web/desktop-only targets that
this project does not build. Ignore them.

## Constraints

Every line below was paid for by a failure that already happened, written as
`CONSTRAINT. # date: what actually went wrong`. Add one **only** when something actually goes
wrong — never in anticipation. Delete any line that has not been triggered in 3 months. Ceiling is
about 18 lines; a long aspirational list here is the exact failure this format exists to prevent.

- Capture stdout and assert on its content before overwriting a file. # 2026-08-15: `firebase apps:sdkconfig --out <path>` crashed before writing and silently left the *previous* file in place. Reading it produced a confident, wrong conclusion — that the Google OAuth clients had never been created, when they had.
- On Windows **no** Firebase CLI exit code is a result — read the output. # 2026-08-15: `firebase apps:*` printed `√ success` then exited 9 with a libuv assertion in `src\win\async.c`; the work had already completed. Re-measured at the Phase 3 gate 2026-08-19, and this line was wrong in both halves: the crash is **intermittent** (`apps:list` crashed, exited 0, then crashed again in one session) and **not confined to `apps:*`** (`projects:list` crashes; `database:instances:list` did for one reviewer and not for me). "Every one of them" invites concluding the trap is fixed after one clean run.
- Download credentials into `.local/`, never into the working tree — and when you delete the thing a `.gitignore` line guards, keep the line. # 2026-08-15: an Admin SDK service-account JSON landed in `.credentials/`; deleting that folder took its ignore rule with it, leaving the next download unguarded.
- Read a big `dumpsys` by writing it to a file on the device and pulling it, never through the adb pipe. # 2026-08-17: `adb shell dumpsys alarm` piped into PowerShell returned a truncated buffer, so a count of our scheduled alarms came back as 3 of 21. That looked exactly like HyperOS silently trimming alarms and was about to be written up as an OEM finding. `shell "dumpsys alarm > /sdcard/a.txt"` then `pull` gave the true answer.
- The app's own record of what it scheduled is not evidence of what the platform holds. # 2026-08-17: a force-stop cancels every AlarmManager alarm and tells the app nothing, so a diff computed against `LocalStore` re-armed nothing and the app was permanently inert — 21 armed, force-stop, 0 armed, reopen and reconcile, still 0. Ask the platform, or assert the whole desired set.
- Two Dart isolates in one Android process do **not** get their own database connection, whatever the docstring says — never `close()` one an isolate did not exclusively open. # 2026-08-20: `sqflite`'s Android plugin keeps a **static** `_singleInstancesByPath`, so the alarm isolate's `LocalStore.open()` was handed the UI's connection and its `finally { close(); }` killed it. Every UI store call then threw `DatabaseException(database_closed 1)` for the life of the process. `local_store.dart` asserted the opposite — "they each hold their own connection; SQLite does the locking" — and 781 tests passed, because the suite runs one isolate and one engine.
- A harness that decides pass/fail by searching a subprocess's output must prove it can **read** that output, and carry a no-op control that has to pass. # 2026-08-25: a mutation runner on Windows collected `flutter test`'s stdout through Python's default cp1252 and the reader thread died on a UTF-8 byte, leaving the captured text empty. Absent "All tests passed!" reads as *the mutation was caught*, so all five mutations were reported `FAILS (good)` — a green report produced by the harness being broken, on the one tool whose entire job is to distrust a green suite. The traceback was printed and scrolled past above the results.

- **Every** FlutterFire API that takes an emulator host rewrites it on Android unless told not to — pass `automaticHostMapping: false` to each one, including the next. # 2026-08-26: `firebase_bootstrap.dart` passed it to Auth and Firestore and not to `useFunctionsEmulator`, which defaults it to `true` exactly as they do. On the POCO, over `adb reverse`, the phone signed in, wrote `users/{uid}` and rendered the pairing screen — then every callable went to `10.0.2.2`, which means nothing on a physical handset, so `redeemInvite` hung until it timed out and the Functions emulator logged *nothing at all*. Half the app working is what made it read as a backend fault rather than as a host never reached. Three plugins, three for three.
- Adding a Dart package can silently move a **transitive Firebase** one and break only the Android build. # 2026-08-26: `flutter pub add cloud_functions` re-resolved `firebase_core` 4.13.0 → 4.14.0, and `firebase_auth` 6.5.7 compiles against a symbol 4.14.0 dropped. `flutter analyze` and `flutter test` both stayed green; only `:firebase_auth:compileDebugJavaWithJavac` failed, in a plugin's own Java, from a change that touched neither. Build the debug APK after any dependency change, and read `pubspec.lock`'s diff rather than the `pub add` summary.
- Never derive a value that outlives the process from `Object.hash` or `hashCode`; hash it with code this repo owns and pin it with known values. # 2026-08-17: `AlarmIds` used `Object.hash`, which is seeded randomly per process, so every notification and alarm id changed on each app launch. Reminders fired two/two/three instead of one each, a tap could not cancel an earlier launch's alarms, and §10's correction — which retracts a false warning by replacing it at the same id — would have posted a second notification beside the one it was meant to remove. 524 tests passed throughout, because each compared two calls made inside one process.
