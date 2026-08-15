# Phase 0 — Foundations · summary

**Date:** 2026-08-15 · **Status:** Complete, awaiting owner review · **Next:** Phase 1, domain layer

Documentation, constraint, and review machinery. **No app code, no `pubspec.yaml` changes, no
Firebase calls** — `lib/` is still the stock Flutter counter and the only dependency is
`cupertino_icons`, exactly as it was.

---

## What was built

| | |
|---|---|
| `docs/` reorganised by topic | `architecture/` `security/` `ui-ux/` `testing/` `infrastructure/` `legal/` `phases/`, indexed by [docs/README.md](../README.md) |
| `ARCHITECTURE.md` moved | `docs/` → `docs/architecture/`, via `git mv` so history follows. All 14 cross-references updated. |
| `HANDOVER.md` marked historical | A banner table saying, section by section, what still stands and what is superseded |
| `CLAUDE.md` | Failure-log form. Overview + build commands, then **three** constraints |
| `.claude/skills/` | Five: architecture, security, ui-ux, testing, infrastructure guidelines |
| `.claude/agents/` | Five reviewers: `architecture-reviewer`, `security-reviewer`, `uiux-reviewer`, `testing-reviewer`, `infrastructure-reviewer` |
| `.gitignore` hardened | A `# Secrets` block, restoring the lost guard and widening it |
| `.local/` | Established as the private, never-committed area |
| `tools/check-secrets-ignored.ps1` | Makes the guard testable rather than assumed |
| Root `README.md` | Replaced the Flutter scaffold text |

New documents: [secrets-policy](../security/secrets-policy.md),
[threat-model](../security/threat-model.md),
[firestore-rules-guidelines](../security/firestore-rules-guidelines.md),
[ui-ux/guidelines](../ui-ux/guidelines.md), [ui-ux/screens](../ui-ux/screens.md),
[testing/strategy](../testing/strategy.md), [testing/device-matrix](../testing/device-matrix.md),
[infrastructure/deploy-notes](../infrastructure/deploy-notes.md),
[architecture/decisions/README](../architecture/decisions/README.md),
[legal/README](../legal/README.md).

---

## What was decided, and why

**`CLAUDE.md` has three constraints, not twelve to eighteen.** The target was a ceiling, and only
three real failures exist to date — the two Firebase CLI traps, and the `.credentials/` ignore-rule
regression. Padding to hit a line count would produce exactly the aspirational file the failure-log
pattern exists to prevent. The file states the ceiling and the three-month pruning rule so it grows
only when something actually goes wrong.

**No ADRs were retro-fitted.** Every pre-Phase-0 decision is already written down with its
reasoning, in better prose than a template would produce — ARCHITECTURE.md §1 and §16, PLAN.md's
locked decisions, and the secrets policy. Converting them would create a second, lower-quality copy
and a new opportunity for the two to drift. `decisions/README.md` establishes the format and says
plainly that **ADR-0001 is the first decision taken from Phase 1 onward**.

**The secrets split is stated as two exhaustive lists, not as caution.** Being vague here produces a
`docs-private/` folder full of things that ship in the APK anyway, plus a comfortable feeling backed
by nothing. `google-services.json` stays committed; the guard and the reviewer agent both carry an
explicit instruction *not* to report it, because over-reporting non-secrets is the specific failure
this policy was written against.

**`.local/` is ignored wholesale**, including its own README. "Never committed" is then literally
true rather than a convention with an exception.

**Reviewer agents are read-only.** They report; they do not edit. `infrastructure-reviewer` is
additionally forbidden from any state-changing Firebase command and must say what it could not
verify — which is the point of that review, given the CLI traps.

**The topic docs record only what is actually decided**, and mark the rest open. `screens.md` says
in its own header that an absence is not a free choice. `device-matrix.md` ships with its physical
device rows deliberately blank rather than invented.

**PLAN.md's status line was updated** — it read "Awaiting approval · No implementation started",
which is now false. Nothing else in PLAN.md or ARCHITECTURE.md was touched.

---

## Review, and what it changed

Three reviewers ran against the phase output. They found real defects; the following were fixed.

**The secrets guard was vacuous in one direction — the important one.** `git check-ignore` consults
the **index** by default and reports any *tracked* file as "not ignored" whatever the rules say.
`google-services.json` is tracked, so the check passed green even with `*.json` in `.gitignore` —
the exact regression the script exists to catch. Verified independently in a throwaway repo:

```
default    exit=1  → script reported "trackable"    ← wrong
--no-index exit=0  → correctly detected as ignored
```

Fixed: the trackable half now uses `--no-index`, asserts the file is still actually tracked, and
treats any exit code other than 0 or 1 as an error rather than as "trackable". The protective half
deliberately keeps the index-aware form, so an already-committed secret fails the run loudly. The
guard was then **proved to fail** by temporarily adding `*.json` — it does, and the docs claiming
"asserts both directions" are now true rather than aspirational.

**The 30-day away cap had drifted from ARCHITECTURE.md §8.** I had written `through <= from + 30d`;
§8 says `through <= request.time + 30d`. Identical while `from` is always today, divergent the
moment future-dated away is exposed — which §12 deliberately leaves the door open for. Corrected to
§8's form everywhere, with the divergence explained. `setBy` and `setByName` validation were marked
as **proposed additions** rather than presented as §8 content — and were subsequently adopted into
§8 by [ADR-0003](../architecture/decisions/0003-away-attribution.md), see open item 4 below.

**Missing secret patterns** added to both `.gitignore` and the guard: `.runtimeconfig.json`
(`functions:config:get` output), emulator export directories (an `--export-on-exit` of real data
would put check-in history in the repo), `client_secret_*.json`, `credentials.json`, `*.p12`,
`*.pem`, `*.pepk`. Five redundant `*-debug.log` lines removed — line 3's `*.log` already covers them.

**Distortions in the skills, fixed.** The layer diagram implied `Data → Platform edge`, a
dependency the design does not have. The warning path was restated as three checks instead of five,
**dropping the `link.activeFrom` guard** — its own §17 risk, and precisely the omission that ships
in Phase 3. The offline-honest-message rule was missing from the skill that gets loaded while code
is *written*, though the agent that reviews it had the rule. The away extension of the rolling
window — `through` + 7 — appeared nowhere outside ARCHITECTURE.md, and it is the mechanism that
lets the watched side stay display-only.

**Fifteen coverage gaps** in `testing/strategy.md`, now added: the rolling window (pure `Reconciler`
logic and the largest untested surface), permissions → health derivation, the device-clock day id,
`LocalStore` as its own test level, notification-id distinctness across multiple watched people,
the second-tap-same-day premise, cache-says-away-but-Firestore-says-cancelled, the FCM payload
carrying no authority, `redeemInvite` cases, `through >= from`, away transition recipients, tapping
during away, the debug harness as a gate item, `UNREGISTERED` pruning, and the soft-midnight
boundary asserted as an outcome rather than only used as an input.

**The `testing-reviewer` purity check was too narrow** — one grep for `DateTime.now()`. A domain
file importing `dart:io` or `package:flutter/material.dart` passed it and would then crash inside a
bare background isolate months later. Widened to the full set, plus `.toLocal()` as an implicit
timezone read, plus a check that domain tests use `package:test` and not `flutter_test`.
`architecture-reviewer` gained the Phase 1 rule PLAN.md calls non-negotiable: the policies take
their `away` argument from the first line.

**The HANDOVER banner blessed three contradicted sections** by omitting them, including "Exactly
two notifications exist" — the model ARCHITECTURE.md §1 replaces with quiet-confirm-loud-miss. It
also said the blocker inventory was "folded into §17", when §17 opens by declaring itself the
*delta*. Both corrected.

**Infrastructure doc fixes:** Cloud Storage appeared as both "enable it" and "confirm it is off" —
two different things (the GCP API for build artifacts vs the Firebase product), qualifiers
restored. Node 22 and the Functions region were listed among independently verified facts when they
are intended values under a task still marked *not done*; the table is now split. The
verification advice was circular — `apps:list` is itself an `apps:*` command and crashes the same
way, so "verify with a `:list`" now says *read its output*. The emulator section gained a phase
marker and the JDK-not-on-`PATH` prerequisite.

**Also fixed:** App Check was presented as a live control in the threat model's adversary table
when it is Phase 4, monitoring-only, and blocks nothing until enforcement; "ends tomorrow" went to
"every device" rather than to all watchers; "local 24h **matching the device format setting**" was
self-contradictory on a 12h device.

---

## Deferred, deliberately

- **Privacy policy and terms** — Phase 8. `legal/README.md` records what they must describe and the
  two questions that need answering first.
- **ADR-0001** — the first real decision from Phase 1.
- **Screen layouts and visual design** — behaviour and copy are decided; layout is not.
- **CI** — `flutter analyze` and `flutter test` run locally. Noted in `testing/strategy.md` as a
  decision rather than an oversight; the guard script is the natural first CI step.
- **A pre-commit hook for the secrets guard** — it currently runs when a human remembers.

---

## Open items, in the order they bite

### Owed before Phase 1

**Four defects in ARCHITECTURE.md, surfaced by review.** They need your ruling:

1. ~~**§10 steps 3 and 5 contradict each other.**~~ **RESOLVED — [ADR-0001](../architecture/decisions/0001-away-cache-precedence.md), 2026-08-15.**
   Confirmed executably: the sequence was modelled in
   [`tools/models/away_warning_model.dart`](../../tools/models/away_warning_model.dart) and the
   original ordering failed 4 of 18 cases, silencing a watcher for 16 days in the modelled
   scenario. The model also surfaced two defects invisible to a prose reading — cancellation must
   *truncate* rather than delete, and the cache may only be cleared by a read that **succeeded**,
   not merely by being online. §8, §10 and §12 amended; the model is now the executable
   specification for Phase 3.
2. ~~**§6 lists `ClockService` as a UI-isolate component**, but §10 requires the alarm isolate to
   compute `D`.~~ **RESOLVED — [ADR-0002](../architecture/decisions/0002-clock-split.md), 2026-08-15.**
   The row was two responsibilities sharing a cell: reading the instant (core Dart, needed
   everywhere) versus device-zone discovery and skew detection (a plugin and a server round-trip,
   UI-only). Split into `Clock` (all three isolates) and `ClockService` (UI). The device's IANA
   zone is now cached to `LocalStore` by the UI, so a bare isolate computes `D` with **no plugin
   access at all**. `LocalStore` also gained `watchedTimezone` — without it `D` was not computable
   from disk, which §10's offline branch requires — and `lastReconcileAt` was corrected to a
   timestamp, a defect inherited from ADR-0001.
3. ~~**§1 still reads "`europe-west1` / `eur3`"**~~ **RESOLVED — 2026-08-15, CLI-verified.**
   `firestore:databases:get "(default)"` reports `Location │ europe-west1`,
   `Type │ FIRESTORE_NATIVE`, created 2026-08-15T15:32:35Z. §1 corrected. Verifying it also
   exposed a defect in our own runbook: the documented check used `databases:list`, which prints
   no location column at all and therefore could never have confirmed the setting it claimed to.
   Fixed in four places. This is the CLAUDE.md "assert on content, not on the command" constraint
   paying for itself a second time.
4. ~~**§8's away validation omits `setBy == request.auth.uid` and `setByName`.**~~
   **RESOLVED — [ADR-0003](../architecture/decisions/0003-away-attribution.md), 2026-08-15.**
   Sharper than it first looked: §17 named `setByName` as the *entire* mitigation for an accepted
   risk, so leaving it unvalidated meant that mitigation ran on client goodwill. Adopted three
   free checks (`setBy == request.auth.uid` on create *and* update, `setByName` present/typed/
   bounded, `setAt`/`updatedAt == request.time`) and **explicitly rejected** the tempting
   display-name cross-check — users own their own `displayName`, so it costs a `get()` and proves
   nothing. §17 restated: `setBy` is the enforced identity, `setByName` is a label.

**All four are now closed**, as ADR-0001 through ADR-0003 plus a CLI verification. Two new items
surfaced while closing them:

- **Firestore has no delete protection and no point-in-time recovery.** Read off
  `firestore:databases:get` on 2026-08-15 while confirming the location:
  `DELETE_PROTECTION_DISABLED`, `POINT_IN_TIME_RECOVERY_DISABLED`, version retention 3600s. A
  one-command hardening on a database holding data about vulnerable people. Queued for Phase 4,
  not done unilaterally.
- **Cancelled versus expired away periods.** Cancel-as-truncate (ADR-0001) makes a cancelled
  period look identical to one that ran its course, but §12 has a distinct cancellation message.
  Derivable from the cache diff, so no schema change — but it needs a test or the wrong message
  ships. Recorded in the testing strategy.

### Owed before Phase 2

**The physical device rows in [device-matrix.md](../testing/device-matrix.md).** The two that
matter are the handset the watched person will actually use and the one the watcher will actually
use — the design's two riskiest assumptions are about those specific phones, and Phase 2's exit
criteria cannot be met on an emulator. Also worth covering **one device at API 33 or below**: the
permission model changes at API 30, 31, 33 and 34, the only device available today is API 36, and
the watched person's phone is likely to be old.

### Later

- **`redeemInvite` rate limiting** — threat model T3, Phase 5, when the callable is written.
- **Account deletion and GDPR** — threat model T9. Deleting a user leaves check-ins, an away
  document, and links the *other* party can read. Undecided; owed before Phase 8.
- **App Check enforcement** — Phase 4 provisions it in monitoring mode. Turning enforcement on is a
  separate, later step, gated on confirming real traffic is attested first.

---

## What to watch out for next

**The reviewer agents are not loadable in the session that created them.** The harness reads
`.claude/agents/` at startup, so this phase's reviews ran through general-purpose agents pointed at
the new definition files. They will be directly invocable as
`architecture-reviewer`, `security-reviewer`, `uiux-reviewer`, `testing-reviewer` and
`infrastructure-reviewer` in the next session. That is also the first real test of whether the
definitions work as written.

**Phase 1 is pure Dart and the discipline is the whole point.** No Flutter, no Firebase, no
`DateTime.now()`. The two rules most likely to be broken by a well-meaning shortcut are the
injected clock and the `away` argument on both policies from the first line. Both reviewers now
check for them explicitly.

**The guard script is only as good as its sample list.** Adding a pattern to `.gitignore` means
adding a sample path to `tools/check-secrets-ignored.ps1` too — a rule with no assertion is a rule
nobody notices losing, which is the shape of the failure that started this.

**`CLAUDE.md` should stay short.** Three lines is correct today. Add one only when something
actually goes wrong, and delete any line untriggered for three months.

---

## Verification

```
flutter analyze                        No issues found!
flutter test                           All tests passed!  (1 test — the stock scaffold)
tools/check-secrets-ignored.ps1        OK - 19 paths ignored, 1 deliberately tracked
                                       and proved to FAIL when a rogue *.json rule is added
git status                             clean after commit; no secret paths trackable
```

**Exit criteria from PLAN.md:** docs navigable from `docs/README.md` ✓ · agents invocable ✓ (next
session, see above) · `git status` clean with no secret paths trackable ✓.
