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
- On Windows a `firebase apps:*` exit code is not a result. # 2026-08-15: every one of them prints `√ success` and then exits 9 with a libuv assertion in `src\win\async.c`. The work had already completed. Verify by reading the artifact or by running a `:list`.
- Download credentials into `.local/`, never into the working tree — and when you delete the thing a `.gitignore` line guards, keep the line. # 2026-08-15: an Admin SDK service-account JSON landed in `.credentials/`; deleting that folder took its ignore rule with it, leaving the next download unguarded.
