# Phase 5 — handover

**Written:** 2026-08-26 · **Head:** `e8af581` · **1 161 Dart tests**, **75 Functions tests**,
**75 rules tests**, `flutter analyze` clean, `flutter build apk --debug` succeeds, secrets guard
clean, working tree clean.

> **HISTORICAL — Phase 5 was closed out and SIGNED OFF on 2026-08-26.** Every one of the six items
> below was taken, and all three owner decisions took the recommended option. **What actually
> happened is in [phase-5-summary.md](phase-5-summary.md) under *Closing the phase*** — read this
> file for the reasoning behind each suggestion, not for current state. It is deliberately frozen as
> written, the same way `phase-4-handover.md` is.
>
> Two things below did not survive contact. The suggested `Home.build` lint was written against a
> mutation that **does not compile** (`ref.watch(otherProvider)`), so it proves nothing — the real
> one is `screenFor(null)`. And the suggested home for the mutation harnesses became four files
> rather than two, because the engine is worth sharing and the Functions half needs a wrapper to find
> Java.

**Phase 5 is built, its exit criterion is met on two devices, and all five reviewers have run with
their findings applied. It is NOT signed off.**

This document is the state, what is left to close the phase, and a **suggested solution for every
open item** — written while the context was still in the room, so the next session does not have to
re-derive any of it. Where an item is the owner's decision that is said plainly, and the suggestion
is a recommendation rather than a plan.

Read [phase-5-summary.md](phase-5-summary.md) first for *what was built and why*. This file is
*what remains*.

---

## The one-line story

The phase was finished twice. The first time by a **device run**, which found two defects nothing in
1 141 tests could see. The second time by the **five reviewers**, who found fourteen more — almost
none of them from a test failing, one of them a defect my own same-day fix had made *latent rather
than absent*, and one of them found independently by two reviewers.

What is left is mostly **not code**: eleven of the fourteen fixes are in, and what remains is copy the
owner has to approve, two design decisions that are genuinely theirs, and four small pieces of
verification hygiene.

---

## Commits

| Commit | What |
|---|---|
| `a9882bb` | The Phase 5 brief (written at the end of Phase 4) |
| `8909f7c` | The phase: two callables, three screens, sign-in, routing, the route back — and the device run |
| `e8af581` | The review round: five reviewers, fourteen fixes |

---

## Verification, as it stands

```powershell
flutter analyze                                  # clean
flutter test                                     # 1 161 pass
flutter build apk --debug                        # builds
pwsh -File tools/check-secrets-ignored.ps1       # 25 ignored, 6 tracked
pwsh -File tools/functions-test.ps1              # 75 pass
pwsh -File tools/rules-test.ps1                  # 75 pass
```

**Only one emulator script may run at a time** — `emulators.ps1`, `rules-test.ps1` and
`functions-test.ps1` all want 8080 / 9099 / 5001, and the second one fails with *"port taken"* in a
way that reads as a broken script.

**42 mutations across two harnesses**, every one behaving as expected with a passing no-op control.
The harnesses were scratch scripts and are **not in the repo** — the infrastructure reviewer flagged
that as worth keeping, and it is listed under *Smaller open items* below.

---

## The device rig, as this session left it

**POCO F3 — the app is UNINSTALLED, deliberately.** It held an accepted link to a synthetic *Mum* on
a local emulator and 81 alarm entries including armed warning alarms; the emulator has since stopped,
so those alarms would have fired at 10:00 the next morning against a backend that no longer answers
and posted an offline notice about a person who does not exist — on the owner's personal phone.
**Phase 4's recorded POCO state is gone and is not restorable.**

**AVD `Medium_Phone_API_36.0`** — keeps the paired state: signed in as *Mum*, accepted link to *Ana*,
onboarding complete, today's check-in recorded. Scratch rig; *Wipe store* resets it.

**`emulator-data/` is the 2026-08-25 export.** The suite was killed rather than `Ctrl-C`'d, so
nothing from the device run is in it and the AVD's store references uids the emulator no longer
knows. **Re-pair; do not try to reconcile the two.** `emulators.ps1` now prints the export's date on
import so this is visible rather than silent.

---

## What is left to close Phase 5

Six items, in the order I would take them. **The first three are the owner's**; the rest are work.

---

### 1. Copy approval — every new user-visible string · **OWNER**

Nothing ships without it, and this is the largest set of new copy any phase has produced.

**Where it is:** `docs/ui-ux/screens.md`, sections *Sign-in*, *The three screens, as built*, *Making
a code*, *Using a code*, *Why a code did not work*, and *The summary*. Every string in
`lib/copy/onboarding_copy.dart` appears there verbatim — the UI/UX reviewer checked them character
by character and found no paraphrases.

**Suggested approach — take the two changed strings first**, because they are changes to copy that
was already approved, and both were forced by the same button:

| | Was | Now |
|---|---|---|
| `TapCopy.nobodyYet` | *"No one is set up to know you're OK. **Ask a family member to help you add someone.**"* | *"No one is set up to know you're OK."* |
| `WatcherCopy.nobody` | *"You're not looking after anyone. **Ask a family member to help you add someone.**"* | *"You're not looking after anyone."* |

The argument for both: `TapCopy.notificationsOff` records the rule that *"ask a family member" is the
dead-end wording and is only honest once there is nothing left to press*. There is now an **Add
someone** button directly beneath both lines. The alternative was to keep the sentence and not add
the button, which leaves a skipped first question as a dead end.

**Four strings are NOT yet in `screens.md`** and the UI/UX reviewer flagged them as owed either way —
add them to the file as part of this pass:

- the **summary's title** *"You're all set"*, **and the condition** it now renders under (only when
  there is something to report — see below);
- the **share message**, *"Use this code in the I Am Ok app to look after me: K7R TQX"*, which is the
  only string in the app that goes to somebody who may not have installed it. **Suggestion: add the
  expiry to it**, because a code sent by message and read the next morning fails with *"That code has
  expired."*;
- the **watcher-list button's label** on the Tap screen, currently `WatcherCopy.title` — *"People
  you're looking after"* — which is approved as a **screen title**, not as a control's label. A
  control's label should state the action;
- `summaryNothing` keeps the word *"yet"*, which two reviewers struck from its two siblings. It is
  defensible here — the summary is reached once, before anything has ever been set up — but the file
  explains the *"Skip for now"* exception at length and is silent on this one.

**One string I would not send as drafted.** `PairingRefusal.ownCode` says *"That is your own code.
Ask the person you are looking after for theirs."* — but the branch fires when somebody typed the
watched person's own code into the watched person's own phone, which is overwhelmingly the family
member holding the wrong handset. Telling them to *"ask the person you are looking after"* names a
relationship the reader does not have. **Suggested replacement**, owed approval like the rest:

> *"That code belongs to this phone. Type it into the other one."*

---

### 2. The cross-role dead end · **OWNER DECISION**

**What it is.** The Tap screen's *Add someone* opens only `ShareCodeScreen` (produce a code); the
watcher list's opens only `EnterCodeScreen` (use a code); and the watcher list is reachable from the
Tap screen only when the user is **already** a watcher. So somebody who skipped one of the two
onboarding questions can never take up that role — no error, nothing to press.

**Why it is yours.** Every fix adds a second action to the *watched person's* screen, and
`guidelines.md`'s first principle is one screen, one action, with `WatchedAudience` recording at
length how firmly this project refuses extra surfaces there. That is a product judgement, not an
implementation detail.

**Suggested solution — option A, a chooser behind *Add someone*.** Recommended.

The Tap screen's *Add someone* opens a two-option sheet instead of going straight to the code screen:

> **Add someone**
> — *Someone to look after me* → `ShareCodeScreen`
> — *Someone I look after* → `EnterCodeScreen`

It mirrors the two onboarding questions' framing (both about *other people*, never about role), it
reuses both existing screens, and it costs the elderly user nothing in daily use because they never
press this control. Two new strings, owed approval with the rest. The watcher list keeps its single
*"I have a code"* action, which is correct for that screen.

**Option B — make the watcher list always reachable** from the Tap screen once onboarding is
complete, so the route in is the list's own *"I have a code"*. No new copy. Costs a permanent second
icon on the watched person's screen, and contradicts PLAN.md, which specifies that button for a
both-roles user.

**Option C — accept it until Phase 7's UI pass**, recorded in `OPEN-QUESTIONS.md`. Cheapest, and
honest, but it leaves a real family able to get stuck.

---

### 3. The 21:00 reminder promises a family that may not exist · **OWNER DECISION**

**What it is.** `screens.md` still says *"Owed before Phase 5"*: the 21:00 reminder reads *"Please tap
I'm OK before the day ends, so your family knows you're well."* while the screen may simultaneously
say *"No one is set up to know you're OK."* The proposed resolution was *"an explicit acceptance once
onboarding guarantees pairing before reminders arm"* — and **onboarding does not guarantee that**: it
offers *Skip for now* on the screen that would produce it, and `HomeRoute.decide` routes a
both-skipped user to the Tap screen by design. The item is not closed, and this phase made it easier
to reach rather than harder.

**Suggested solution — an empty-audience variant.** Recommended, because it is the same rule as the
four warning messages: never claim more than the device knows.

`ReminderPolicy.remindersFor` takes no audience today. `WatchedReconciler` already holds a
`WatchedAudience`, so the value is one parameter away — thread `hasAudience` through and give
`NotificationCopy` a variant that drops the consequence clause:

> *"Please tap I'm OK before the day ends."*

That is a **subtraction** from an approved string, which is the same move `nobodyYet` just made, and
it needs no new sentence to be invented. The 12:00 and 18:00 bodies are unaffected — only the 21:00
one names a consequence.

**Option B — write the acceptance down** in `screens.md`: the reminder is about the habit, and the
words are close enough. Cheaper, and defensible; it just has to be *recorded* rather than left
reading as an open item that was quietly passed over.

Either way, `screens.md` must stop saying *"Owed before Phase 5"*.

---

### 4. `couldNotReach` is said when the server was reached and answered · **needs new copy**

**What it is.** ADR-0004's *refused is not unreachable* rule reappearing in a new place. Four paths
map to *"Could not reach the internet. Check your connection and try again."* where the phone
demonstrably reached the internet: a `HttpsError('internal')` from a failed transaction, any wire
status this build has no case for, a malformed `created` payload, and a `not-found` from a region
mismatch. It is a claim about the **device** that is false, and it names a next action — *check your
connection* — that cannot work.

**Suggested solution.** A fourth outcome, and one new sentence:

1. Add `serverFault` to `PairingRefusal` and `InviteRefusal`.
2. Copy — owed approval, and deliberately claiming nothing about either side:
   > *"That did not work just now. Try again in a moment."*
3. Extract the exception mapping so it is testable, which is the half that is untestable today —
   `static PairingRefusal refusalForCode(String code)`:
   - `unauthenticated` → `notSignedIn`
   - `unavailable`, `deadline-exceeded` → `couldNotReach`
   - everything else, including `internal` and `not-found` → `serverFault`
4. The `default:` branch of `pairingFrom` / `inviteFrom` → `serverFault` rather than `couldNotReach`.
5. Table-test `refusalForCode`. The status mapping was correctly lifted to a pure function in this
   phase; the exception mapping was not, and it sits inside an untestable `catch`.

`test/copy/onboarding_copy_test.dart` currently **pins** the false claim — it asserts that
`couldNotReach` names the internet — so that assertion moves to `serverFault`'s sibling.

---

### 5. `Home.build` — the one uncovered line in the routing wire

**What it is.** `Home.screenFor` is asserted as a pure mapping and the parameter it passes is
asserted too. The line that reads the provider — `screenFor(ref.watch(homeRouteProvider))` — is not:
it could read the wrong provider, or pass `null` unconditionally, and all 1 161 tests would pass.

**Why it is still open.** Pumping `Home` inside a real `ProviderContainer` **hangs with no output**,
which is the same behaviour `app_lifecycle_test.dart` records for pumping `IAmOkApp` and gives as its
reason for not doing so. It was attempted at the review and abandoned rather than left as a hanging
test; the gap is named in `test/presentation/onboarding_routing_test.dart` itself.

**Suggested solution — option A, a source lint.** Cheap, and this repo has two precedents for exactly
this shape (`domain_purity_test.dart`'s guards, and the `automaticHostMapping` counter added this
phase):

```dart
test('Home.build renders the route provider and nothing else', () {
  final code = File('lib/main.dart').readAsStringSync();
  expect(code, contains('screenFor(ref.watch(homeRouteProvider))'));
});
```

A lint, not a proof — and it stops the specific regression that would be invisible.

**Option B — diagnose the hang**, which would also unblock `app_lifecycle_test.dart` and is worth
more than this one line. It is most likely a pending timer or an unawaited future in a provider;
`tester.runAsync`, or pumping with an explicit duration rather than `pumpAndSettle`, are the first
things to try. Worth a timebox, not an open-ended hunt.

---

### 6. Four pieces of verification hygiene

**a. The release-manifest measurement is owed.** `deploy-notes.md` makes it a standing command
whenever a plugin is added, *"including when you expect no change — a rule only honoured when it
finds something stops being run."* Two plugins were added and it has not been run since 2026-08-21.

```powershell
flutter build apk --release
Select-String -Path build\app\outputs\logs\manifest-merger-release-report.txt -Pattern INTERNET
Select-String -Path build\app\outputs\logs\manifest-merger-release-report.txt `
  -Pattern 'ADDED from \[:share_plus\]|ADDED from \[:cloud_functions\]'
```

Expect: **no new permissions**, and **`share_plus` contributing `ShareFileProvider`**
(`android:exported="false"`). The infrastructure reviewer read the *debug* merge as a provisional
answer and got exactly that. Record the result — including a null result — in
`test/android_manifest_test.dart` beside the other three measurements, and note the new provider,
which the documented `Select-String INTERNET` check would miss because it greps for a permission.

**b. Pin `@types/node` to the deployed runtime.** 26.2.0 is in the TypeScript program while Cloud
Functions runs Node 22, and `deploy-notes.md:152` says the opposite (*"`@types/node` is not
installed"*). Newly load-bearing, because this phase added the project's first Node builtin import
(`node:crypto` in `invites.ts`): a Node 23+ API would type-check clean, run clean in the emulator,
and fail only after deploy.

```powershell
npm --prefix functions install --save-dev "@types/node@^22"
```

Then correct that line in `deploy-notes.md`.

**c. Two colour pairs are unmeasured.** `test/presentation/contrast_test.dart` asserts nine pairs and
neither `onPrimaryContainer`/`primaryContainer` — which is **the code block itself**, the single most
important thing on that screen to read and read aloud — nor `onSecondaryContainer`/
`secondaryContainer`, used by the Share button and the watcher empty-state button. Two `expect` lines,
in both light and dark.

**d. Keep the mutation harnesses.** They were scratch scripts, so *"42 mutations, all as expected,
passing no-op control"* is currently unreproducible — including the `CLAUDE.md` property that they can
read their own subprocess. Given that the previous phase's headline lesson was a harness producing a
green report *by being broken*, the harness is the one artefact worth keeping. Suggested home:
`tools/mutate-invites.mjs` and `tools/mutate-dart.mjs`, with the mutation lists in them.

---

## Smaller open items, all recorded rather than fixed

Each is a one-line fix or a small one; none is a false claim to a family. Listed so they are a
backlog rather than a rediscovery.

| | Suggested fix |
|---|---|
| A watcher-only user's launch runs **two overlapping watcher reconciles** — the shell's repair (`available`) and the list's own build (`redundant`) | Skip the launch repair once the settled route is `watcherList`; that screen reconciles itself. **Must never be wrong in the direction of not running** — see `main.dart`'s guard |
| An error in either routing input renders as a **permanent spinner with no retry** — `homeRouteProvider` returns null for both loading and error | Distinguish them, and reuse the failure-with-retry shape both main screens already have |
| `deviceFactsProvider` is in the right layer but the **wrong file** (the onboarding controller) | Move to `providers.dart` beside the other cross-cutting providers |
| `createInviteFor` is **not atomic** — two racing calls can leave two live codes | Hygiene, not a threat at these numbers. A transaction, or accept and record |
| An invite **cannot be withdrawn** once shared to the wrong person, and reuse actively prevents displacing it | Record the cost in ADR-0011's *Consequences*. A `cancelInvite` callable is cheap if ever wanted |
| The **system back button** exits from onboarding rather than stepping back, and back-from-summary leaves `completed: false` | `PopScope` on `OnboardingScreen`, routing back to the previous step |
| `AddSomeoneButton` and the Away control are **adjacent look-alikes**, and Away is inert only until Phase 6 | Separate them before Phase 6 enables Away, not after |
| The bottom band is a fixed 36% with a scroll inside; at the largest font scale both controls can fall below the fold with no affordance | Worth a look with Phase 7's layout work |
| Nothing exercises the **`onCall` wrappers** below a device run — `callerUid`, the shape gate, the `HttpsError` mapping | A third step in `functions-test.ps1`, modelled on `trigger_fires_once_per_day.mjs`, POSTing to the callable with and without a token |
| `redeemInvite: decided` writes `linkId` to Cloud Logging on every pairing | Keep it — `OPEN-QUESTIONS.md` #11 relies on it for abuse detection — but name it in the threat model's Assets table rather than leaving it implicit |

---

## NOT part of closing Phase 5

Carried from Phase 4 and unchanged by this phase. Listed so they are not mistaken for Phase 5 debt:

- **The first Functions deploy.** Still blocked on four missing 2nd-gen APIs (Cloud Build, Artifact
  Registry, Eventarc, Cloud Run — re-verified with `gcloud` on 2026-08-26). Enabling them is billable
  and is the owner's call. **Note the new ordering rule** now in `deploy-notes.md`: deploy Functions
  *before* any client build not pointed at the emulator, or every new user is told to check their
  internet connection for ever.
- **App Check's console half**, and the refusal-to-copy mapping verified against a real rejection.
  **For the two callables enforcement is `enforceAppCheck: true` in code, not the console toggle** —
  recorded in `deploy-notes.md` this phase.
- **The live-radio measurement**, which closes ADR-0008 question 1.
- **What ADR-0008 option 1 costs** — the only open *design* decision from Phase 4, and the owner asked
  for the number rather than the ADR.
- **The receiving half of Phase 4's end-to-end row.** The AVD tapping is now done; what is still owed
  is the *receiver* isolated, with the app killed.
- **Delete protection and PITR are both OFF**, and pairing is the feature that starts producing real
  data — `OPEN-QUESTIONS.md` #6's deadline stops being theoretical the moment this ships.

---

## Traps, if you touch a device

Everything below is written down elsewhere too; this is the short list.

- **Only one emulator script at a time** — three of them want the same three ports.
- **Two devices need two identities.** `--dart-define=IAMOK_EMULATOR_USER=…` and `…_NAME=…`; without
  them both phones sign in as the same person and `redeemInvite` correctly refuses the self-link.
  `emulators.ps1` now prints the full command.
- **Every FlutterFire API that takes an emulator host rewrites it on Android** unless passed
  `automaticHostMapping: false`. Three plugins, three for three. The symptom is *half the app
  working*. `android_manifest_test.dart` now counts the calls against the opt-outs.
- **`adb reverse` dies with an adb *server* restart**, not only a cable unplug.
- **`--export-on-exit` runs only on a clean Ctrl-C.** A kill discards everything since the last
  export with no message, and the next run prints *"Importing saved state"* over a stale directory.
- **HyperOS refused the first `adb install`** with `INSTALL_FAILED_USER_RESTRICTED` and accepted a
  retry — worth knowing before concluding the build is bad.
- **Pull the app's database with `adb exec-out run-as … cat`**, never a shell redirect: the redirect
  writes a zero-byte file and `adb pull` still reports success.

---

## Prompt to start the next session

> I'm **closing out Phase 5 — onboarding and pairing** of the I Am Ok project. Read
> `docs/phases/phase-5-handover.md` first — it carries the state, everything still open, and a
> suggested solution for each — then `docs/phases/phase-5-summary.md` for what was built and why, then
> follow the reading order in `docs/README.md`. `docs/OPEN-QUESTIONS.md` is the register; check its
> *Blocking-when* table rather than re-deriving any entry.
>
> **Where it stands.** Built, exit criterion met on two devices, all five reviewers run and their
> findings applied. Head `e8af581`. 1 161 Dart tests, 75 Functions tests, 75 rules tests, analyze
> clean, debug APK builds, secrets guard clean, working tree clean. **Not signed off.**
>
> **Build against the emulator suite**, as Phase 5 did. A 2nd-gen deploy would still fail — four
> prerequisite APIs are missing — and enabling them is billable and the owner's call.
>
> **Three things need the owner before the phase can close**, and they are the first three items in
> the handover: copy approval for every new string (including two changes to already-approved copy
> and four strings not yet in `screens.md`), the **cross-role dead end**, and the **21:00 reminder's
> promise to a family that may not exist**. Do not decide any of them alone; the handover carries a
> recommendation and the alternatives for each.
>
> **The rig.** The POCO F3 has **no app installed** and Phase 4's recorded state on it is gone. The
> AVD holds a paired *Mum*↔*Ana* state. `emulator-data/` does **not** contain that pairing, because
> the suite was killed rather than stopped — **re-pair rather than trying to reconcile them.**
>
> **The habit that found everything in this phase, twice over: run it on a device, and read a claim
> against the thing it describes.** Both device-run defects were invisible to the whole suite — one
> because the AVD makes the wrong address the right one, and one because the defect was *a screen
> nobody reaches*, which no unit test has a way to notice. Then five reviewers found fourteen more,
> almost none from a test failing, including a defect that my own fix earlier the same day had made
> latent rather than absent. When a mutation comes back unexpected, check whether the **mutation** was
> bad before concluding the test was: two of three were mine, and scoring them as caught would have
> been the harness lying.
