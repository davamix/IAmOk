# Phase 6 — Away mode · handover

**Written:** 2026-09-01, at the end of the build-and-review session.
**Status:** Built, all five reviewers run, every finding applied. **Not signed off.**

This is the *what to do next* document. [phase-6-summary.md](phase-6-summary.md) is the *what
happened* one and is longer; read its **The gate review** section before touching anything, because
the gate found that the feature did not work and the fix changed both the client and the rules.

---

## Prompt to start the next session

> I'm continuing **Phase 6 — away mode** of the I Am Ok project. Read
> `docs/phases/phase-6-handover.md` first, then *The gate review* in
> `docs/phases/phase-6-summary.md` — the gate found that away could be set **once per person and
> then never again**, and the fix scoped `from`'s immutability to a **period** rather than a person
> in both `AwayRules.periodInForce` and `firestore.rules`. Do not re-derive that; it is settled and
> tested.
>
> **The work left is almost entirely on a device.** The POCO F3 is connected and the app is
> **not installed**. Nothing in Phase 6 has ever run on a handset, and the checklist is already
> written in `docs/testing/device-matrix.md` under *Per-device checklist → Phase 6*. Start there
> rather than writing a new one.
>
> **Build against the local Firebase Emulator Suite**, as Phases 4, 5 and 6 did. A real Functions
> deploy is neither needed nor wanted and would still fail — the four 2nd-gen APIs are still
> missing, re-verified from the CLI on 2026-08-31. **Only one emulator script may run at a time**
> (ports 8080 / 9099 / 5001), and a stale one **will** be left behind if a run is killed: the
> symptom is *"Port 8080 is not open on localhost"*, which reads like a broken script. Kill the
> `java` process holding the port.
>
> **Two owner decisions are owed before this phase can be signed off** — the drafted picker and
> refusal copy, and five layout/behaviour questions the gate surfaced. Both lists are in
> `docs/ui-ux/screens.md`. Do not decide them alone.

---

## Where things stand

**Seven commits on `main`, `b79a7b6..HEAD`.** Nothing pushed — this project commits to `main` and
pushes only when asked.

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | **1 354** (1 202 at the start of the phase) |
| Rules tests | **80** (75 before) |
| Functions tests | **102** (83 before) |
| `tsc --noEmit` | clean at the pinned Node 22 types |
| Debug APK | builds |
| Secrets guard | clean — 25 ignored, 6 deliberately tracked |
| Dart mutations | **31 caught, 0 survived, 0 did not compile**, 10 passing controls |
| Device | **nothing in this phase has been on a handset** |

**All three exit criteria are met in tests** — `test/application/away_exit_criteria_test.dart`,
driven end to end through both reconcilers and built around **ending** rather than starting, because
away is the first feature here whose failure mode is silence.

### The mutation harness, and what it cost to get a number

**31 mutations, 31 caught, 0 survived, 0 `DID NOT COMPILE`**, ten passing no-op controls, run
2026-09-01 on a clean tree. Seventeen of the 31 are away surfaces. Re-run with:

```powershell
node tools/mutate-dart.mjs
```

Roughly twenty minutes. **Do not edit `lib/` or `test/` while it runs.**

**It refused to score three times before it scored once, and every refusal was right.** Recorded
because a tool whose job is to distrust a green result is worth more when its refusals are written
down than when its numbers are:

1. **The unmutated control came back RED.** I had been editing the tree mid-run — my fault, and
   enough on its own — but the cause was real: a migration test I had just "strengthened" compared
   `sqlite_master.sql` **text** between a fresh install and an upgraded one, which differ
   legitimately (`CREATE TABLE` versus `CREATE` + `ALTER … ADD COLUMN`). It was asserting formatting,
   not shape. Now compares the table set and each table's columns.
2. **and 3. Two mutation `from` strings matched twice**, both in `WarningPolicy`, and the runner
   refused rather than editing a line it might be misidentifying. Each cost a full run to discover —
   which is why the fail-fast check below is worth doing.
4. **One mutation was refused as `DID NOT COMPILE`**, and this one is a fact about the code:
   ADR-0001's watcher-side gate, `if (read is! ReadSucceeded) return this;`, **cannot be mutated at
   all**, because it is what narrows the type — every line below reads `read.checkInDays` and
   `read.away`, which do not exist on `FirestoreRead`. The compiler enforces that property, and the
   watched-side twin (a plain boolean, not a promotion) *is* mutated and caught. The entry now covers
   `lastConfirmedDay` losing monotonicity instead.

**Before committing after any mutation run, check `git diff lib/` is empty**, and grep the mutated
lines back to their original form. The Phase 5 gate found a mutated build in the tree with
`git status` clean.

> **Worth doing.** `mutate-runner.mjs` refuses an ambiguous `from` **when it reaches that
> mutation** — up to twenty minutes in. Validating every `from` in the list *before the control runs*
> turns that into a two-second failure. Six lines: for each mutation, read its file, count
> occurrences, throw naming the file and the string unless it is exactly one. It changes no verdict;
> it only moves when the existing guard fires.

---

## What to do next, in order

### 1. The device run — this is the bulk of what is left

The POCO F3 is connected (`1720f883`, `alioth`, Android 13 / API 33, HyperOS `OS1.0`) and the app is
**not installed**, which is the state Phase 5 deliberately left it in.

`adb` is **not on PATH**. It is at `D:\Android\Sdk\platform-tools\adb.exe`.

**The full checklist is already written** — `docs/testing/device-matrix.md`, *Per-device checklist →
Phase 6*, written before the run so it is not shaped by whatever happened to be tried. Do not
rewrite it. It leads with a **Phase 5** item that no Phase 6 test can reach:

> Press **Add someone**, take the **second** option (*"Someone I look after"*), complete a pairing,
> and confirm a **warning alarm actually arms** — read `dumpsys alarm` off the device, not the app's
> own belief.

Then Phase 6's own rows: the picker at the largest font scale, reminders stopping on away days, the
Tap screen naming the watcher who set it, cancelling from either side, `onAwayChanged` reaching a
**closed** app, the offline-queued write, and the **v5 → v6 migration on a real store**.

**Traps that cost real time last phase, all still true:**

- **Every FlutterFire API that takes an emulator host rewrites it on Android** unless passed
  `automaticHostMapping: false`. Three plugins, three for three. The symptom is *half the app
  working*.
- **Read a big `dumpsys` by writing it to a file on the device and pulling it**, never through the
  adb pipe — it truncates and the truncation looks exactly like an OEM finding.
- **Pull the database with `adb exec-out run-as … cat`**, never a shell redirect; the redirect
  writes a zero-byte file and `adb pull` still reports success.
- **HyperOS refused the first `adb install`** with `INSTALL_FAILED_USER_RESTRICTED` and accepted a
  retry.
- **`adb reverse` dies with an adb *server* restart**, not only a cable unplug.
- **`--export-on-exit` runs only on a clean Ctrl-C.**
- **A force-stop cancels every AlarmManager alarm and tells the app nothing.**

**Two devices need two identities**: `--dart-define=IAMOK_EMULATOR_USER=…` and `…_NAME=…`, or both
phones sign in as the same person. `tools/emulators.ps1` prints the full command. The AVD
`Medium_Phone_API_36.0` is the other half of the rig.

**One clause cannot be driven in a session** and says so in the matrix: *"a device offline for the
whole period still ends away on the right day"* needs a phone to sit offline across a period
boundary. The debug harness's forced date is the intended route, and it shortens this from days to
minutes.

### 2. The two owner decision sets

Both are in `docs/ui-ux/screens.md`. **Do not decide them alone.**

**a. The drafted copy** — *Away picker → Copy*, which lists every string with what it says. The
picker title, `Save`, `Go back`, the queued sentence and the four refusals are **drafted, not
approved**. Two of them (`serverFault`, `notSignedIn`) reuse already-approved pairing sentences
verbatim and are the cheapest to approve.

**b. Five decisions the gate surfaced** — *Owed decisions this phase opened and did not close*. Each
is a case where **the code has already decided** and an absence in that file would read as a free
choice:

| | |
|---|---|
| Extending a period in force | Unreachable in v1 — both controls flip to *end* while away. §12 says away may be *extended*. Either offer both actions, or record the limitation in §12 |
| The watcher row's cancel has no confirmation | The Tap screen's argument does not transfer: cancelling **truncates**, so a mis-tap on day 3 of a 14-day stay destroys 11 days, and what is loud is a warning waking the *rest* of the family |
| Nothing is said when a write lands | Fine on the Tap screen, whose away line is the confirmation. On the watcher row the only feedback is a status line changing under a reader who may not be looking |
| The writer nobody can name | An account with no display name writes `"Someone"`, suppressed at render. A real person called that loses their attribution |
| The spoken outcome strings | Now announced on both surfaces, reusing the rendered sentence. `screens.md`'s own rule is that spoken labels are approved copy like any other |

### 3. `onAwayChanged`'s trigger wiring has never been executed by anything

Found by the infrastructure reviewer, and it is the last thing between this phase and a deploy that
would be the **first** execution of the away trigger's adapter.

`functions/test/away_fan_out.test.js` imports `lib/away_fan_out.js` and never `lib/index.js`. The
only place anything dispatches a real event is run 2 of `tools/functions-test.ps1`, whose probe is
`onCheckInCreated`-only. So the `onDocumentWritten` registration, `event.params.uid`, and above all
the **delete adapter** are unrun:

```ts
const after = event.data?.after;
const fact = awayFactFrom(watchedUid, after?.exists === true ? after.data() : undefined);
```

That is the **cancellation** path — the one the function's own docstring calls the one that matters
most, *"because until every device hears about it their family stays silent."*

Owed: a third run in `tools/functions-test.ps1`, same shape as run 2, asserting **two**
`onAwayChanged: fanned out` lines — one `cleared:false` and one `cleared:true`. A count alone would
pass if the delete had silently done nothing.

### 4. Smaller, and all recorded rather than forgotten

- **§12's four away transition notifications are not built.** Specified in §12 and in
  `screens.md`'s notification table, and named on `testing/strategy.md`'s must-cover list. PLAN.md's
  Phase 6 deliverable list does not name them and the exit criteria do not turn on them, so the
  deferral is defensible — but the **cancellation** notice is different in kind: once a period is
  truncated or deleted `setByName` is gone, so a watcher can silently end somebody's away period and
  no surface can ever say who did. That is a §17 gap, not a nicety.
- **An away *create* queued offline across two UTC midnights is dropped.** `awayNotRetroactive` is
  evaluated at commit time with one day of slack while `from` is a literal composed on the device,
  and the person has already read *"Saved"*. Narrow, and it is the collision of two deliberate
  decisions rather than a coding mistake, so it needs a call rather than a patch.
- **The Firestore error classifier is now written twice** — `FirestoreCheckInReader._classify` and
  `AwayRepository.classifyRead`, including the English-substring App Check match.
  `OPEN-QUESTIONS.md` #5 named one site and now names both; hoisting them into one classifier is the
  cheaper fix and is not done.
- **The migration test covers v5 → v6 only.** The v1–v4 ladder is still unexercised against a real
  file. No real user install exists, so the exposure is dev devices.
- **`AwayPeriod.endsTomorrowOn`** has a passing test and **no caller anywhere in `lib/`**. It will
  read as coverage of a feature that does not exist until the "ends tomorrow" notice lands.

**Carried unchanged from Phase 4 and 5:** the first Functions deploy, App Check's console half, the
live-radio measurement, what ADR-0008 option 1 costs, `Home.build`'s hang, and
`InviteCode.forSpeaking`.

---

## What changed at the gate, so it is not re-derived

Five reviewers, run one at a time. **Nothing came from a test failing** — every finding came from
reading a claim against the thing it describes.

**The feature did not work.** Away could be set once per person and then never again: nothing deletes
the document when a period *ends*, `from` was immutable on update, and both call sites passed the
stale cached period as `existing`. Refused client-side *and* by the rules, with copy blaming the
reader's choice of day. Three documents said it worked, including §12's *"to go longer, set it
again"*.

The fix is a **scope correction, not a new rule**: ADR-0001 decision 6 froze `from` for the life of a
*period*, not of a person — truncating an in-progress period is its stated reason, and an ended
period is not in progress.

- `AwayRules.periodInForce` — a pure function in the **domain**, because it is a policy question. It
  was inline in the repository, which is why nothing could reach it.
- `firestore.rules` admits a fresh, non-retroactive `from` once the stored `through` is behind
  today. **Biased strict**, against that file's usual grain, and the comment says why.
- Both new rules tests were **verified by reverting the clause** — they fail against the old rules.

**Two more defects that produce silence:** the FCM handler never passed `away:`, so `onAwayChanged`
could not change a **closed** watched device; and `AwayRepository.read` had no timeout while being
awaited inside `tap()`, which is the hang that file argues against five lines above.

**Eleven claims had stopped being true**, most written in the commits that made them false — the
list is in the summary. The sharpest: `AwayCopy.queued` said *"when this phone is back online"* one
file after `AwayOutcome` spends a paragraph refusing to say *"could not reach the server"*.

**Two tests of mine could not have failed** — a clause-3 guard asserting what `setUp` had assigned,
and a font-scale assertion measuring a widget entirely outside the viewport. Both corrected.

---

## The rig, as this session leaves it

**POCO F3 — connected, app UNINSTALLED.** `1720f883`, `alioth_eea`, Android 13 / API 33, HyperOS
`OS1.0`. Verified 2026-09-01. This is the state Phase 5 deliberately left it in, and it is a clean
starting point: a cold install is what the Phase 6 checklist wants anyway.

**AVD `Medium_Phone_API_36.0`** — held a paired *Mum*↔*Ana* state as of Phase 5. Scratch rig;
*Wipe store* resets it. Treat its contents as unverified after this long.

**`emulator-data/` is the 2026-08-25 export and does not contain that pairing.** Re-pair; do not try
to reconcile the two. `emulators.ps1` prints the export's date on import so this is visible rather
than silent.

**Nothing is deployed.** `firebase functions:list` returns *No functions found*, re-verified
2026-08-31. `firestore.rules` **has changed this phase** and is **not deployed** — the live ruleset
is still the Phase 4 one. That matters for the ordering rule: `deploy-notes.md` says deploy rules
before any client build not pointed at the emulator, and a client built against the *old* rules would
have the set-once defect back, arriving as `permission-denied` → a refusal claiming the app cannot
change the away period.
