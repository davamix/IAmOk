# Phase 6 — Away mode · handover

**Written:** 2026-09-01, at the end of the build-and-review session.
**Updated:** 2026-09-01, after the device run.
**Status:** Built, all five reviewers run, every finding applied, **and run on two AVDs — every
Phase 6 checklist row is answered.** **Not signed off**: the POCO refused to be installed to, and
two owner decisions are open.

This is the *what to do next* document. [phase-6-summary.md](phase-6-summary.md) is the *what
happened* one and is longer; read its **The gate review** section before touching anything, because
the gate found that the feature did not work and the fix changed both the client and the rules, and
then **The device run**, which is what the checklist rows were ticked from.

---

## Prompt to start the next session

> I'm continuing **Phase 6 — away mode** of the I Am Ok project. Read
> `docs/phases/phase-6-handover.md` first, then *The gate review* and *The device run* in
> `docs/phases/phase-6-summary.md`. Two things are settled and must not be re-derived: the gate
> scoped `from`'s immutability to a **period** rather than a person, in both
> `AwayRules.periodInForce` and `firestore.rules`; and the away feature has now been **driven end to
> end on two API 36 AVDs** — picker, both surfaces, both cancel shapes, the closed-app nudge, the
> offline queue and the v5 → v6 migration. The evidence is in `docs/testing/device-matrix.md` under
> *The Phase 6 away run*. Do not re-run those rows for their own sake.
>
> **The POCO F3 cannot be installed to.** Every attempt returns
> `INSTALL_FAILED_USER_RESTRICTED` — HyperOS's *Install via USB* developer toggle, which **cannot be
> set over adb** and needs a physical tap on the phone (Developer options → Install via USB; MIUI
> usually also wants a signed-in Mi account). Ask the owner to turn it on before planning anything
> that needs OEM hardware. Until then everything OEM-specific about this phase — HyperOS alarm
> survival, Doze, vendor trimming — is unmeasured, and the AVD rows do **not** cover it.
>
> **Three things are open and each needs a decision rather than a patch**, all recorded with their
> measurements: an away period set **offline** never reaches the setter's own phone until an
> unrelated reconcile (the screen contradicts its own *"Saved."* and the reminders keep firing); the
> picker title says *"the last day **you** are away"* on the **watcher's** phone; and
> `invite_service.dart` has no client-side timeout, so the pairing screens spin on the SDK's
> 60-second default.
>
> **Build against the local Firebase Emulator Suite**, as Phases 4, 5 and 6 did. A real Functions
> deploy is neither needed nor wanted and would still fail — the four 2nd-gen APIs are still
> missing, re-verified from the CLI on 2026-08-31. **Only one emulator script may run at a time**
> (ports 8080 / 9099 / 5001). `emulator-data/` now holds the **2026-09-01** export with both users,
> both links and the away document, exported with `firebase emulators:export emulator-data --force
> --project i-am-ok-c74ca` against the **running hub** — which is how to keep state when the suite
> was started detached and cannot receive a Ctrl-C. **Warm the Functions emulator with one `curl`
> before driving a phone**: the first callable of a session can die of a cold-start timeout and it
> looks exactly like an app fault.
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
| Device | **every Phase 6 row run 2026-09-01 on two API 36 AVDs. The POCO refused every install** |

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

### 1. The device run — DONE on AVDs, 2026-09-01, and blocked on the POCO

**Every row of the Phase 6 checklist is ticked**, including the Phase 5 carry item (the chooser's
second option, and six warning alarms confirmed armed from `dumpsys alarm`). The evidence, timings
and exact figures are in `docs/testing/device-matrix.md` under *The Phase 6 away run*. **Do not
re-run them for their own sake**; re-run one only when its code changes.

**What is still owed here is the POCO, and it needs a person.** `adb install` returns
`INSTALL_FAILED_USER_RESTRICTED` on every route — streamed install, and `pm install` from
`/data/local/tmp` — with the phone awake, unlocked, `adb_enabled=1`, and `dumpsys user` reporting
`Effective restrictions: none`. That is HyperOS's *Install via USB* gate and **adb cannot set it**.
This page used to say a retry works; it does not any more.

So the OEM half of this phase is unmeasured, and the AVD rows must not be read as covering it:
HyperOS alarm survival, Doze behaviour, vendor trimming, and a genuinely narrow screen. (The 360dp
day-cell floor *was* checked, by forcing `wm density 480` on an AVD — the cells measure exactly
48dp — but that is a layout answer, not an OEM one.)

`adb` is **not on PATH**. It is at `D:\Android\Sdk\platform-tools\adb.exe`.

**The rig this run leaves behind:** AVD `Medium_Phone_API_36.0` as **Mum** (watched, away until
1 Sep after the truncation) and a new AVD **`IAmOk_Watcher_36`** as **Ana** (watching Mum, and
watched by her). Both links exist because the carry item needs a Tap screen and a code at once.
Two instances of *one* AVD will not run unless **every** instance carries `-read-only`, which is why
a second AVD exists at all.

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

**b. Seven decisions — five from the gate, two added by the device run** — *Owed decisions this
phase opened and did not close*. Each is a case where **the code has already decided** and an
absence in that file would read as a free choice. The two new ones are the **picker title
addressing the wrong person on the watcher's phone**, and **an away period set offline saying
*"Saved."* while changing nothing on that phone** — the second is the sharper of the two and is the
same decision as *"nothing is said when a write lands"* seen from the other side:

| | |
|---|---|
| Extending a period in force | Unreachable in v1 — both controls flip to *end* while away. §12 says away may be *extended*. Either offer both actions, or record the limitation in §12 |
| The watcher row's cancel has no confirmation | The Tap screen's argument does not transfer: cancelling **truncates**, so a mis-tap on day 3 of a 14-day stay destroys 11 days, and what is loud is a warning waking the *rest* of the family |
| Nothing is said when a write lands | Fine on the Tap screen, whose away line is the confirmation. On the watcher row the only feedback is a status line changing under a reader who may not be looking |
| The writer nobody can name | An account with no display name writes `"Someone"`, suppressed at render. A real person called that loses their attribution |
| The spoken outcome strings | Now announced on both surfaces, reusing the rendered sentence. `screens.md`'s own rule is that spoken labels are approved copy like any other |

### 3. `onAwayChanged`'s trigger wiring — DONE 2026-09-01, from both ends

The infrastructure reviewer's finding was that nothing had ever dispatched a real event at the
`onDocumentWritten` registration, leaving `event.params.uid` and the **delete adapter** — the
cancellation path — unrun until the first deploy. Both are now executed:

**`functions/test/away_trigger_fires.mjs`, run as 3/3 of `tools/functions-test.ps1`.** Three writes,
not the two that were asked for: create, truncating **update**, delete. The update earns its place —
it is what separates this trigger from `onCheckInCreated`, and a copy-pasted `onDocumentCreated`
would silence every truncation while still looking wired. The assertion is two `cleared:false`, one
`cleared:true`, and the probe's uid in all three lines, which can only have come from the path.

**And it was mutation-checked rather than trusted.** With the delete replaced by another `set`, the
line count stays at three and the run **fails on the `cleared:true` clause** — exactly the failure a
bare count would have missed. Reverted immediately; `git status` clean.

**The device run then did it for real:** Ana cancelled Mum's period from her own phone and the
function logged `cleared:true, parties:2, tokens:2`, with the create logging `skippedSelf:1`.

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
  decisions rather than a coding mistake, so it needs a call rather than a patch. **The device run
  showed the mechanism**: a period queued at 11:04 and flushed at 11:06 carried `setAt` stamped at
  **flush** time, which is exactly the clock the rule is evaluated against while `from` is not.
- **`invite_service.dart` has no client-side timeout.** Neither callable is bounded, so the pairing
  screens spin on the SDK default — **60 s** (`cloud_functions_platform_interface` 6.0.6) — with
  nothing said. `AwayRepository` bounds every call at six seconds, and the gate *added* the missing
  bound to `AwayRepository.read` this phase for the same argument. Seen on a device when the
  Functions emulator's first invocation cold-started: the *Your code* screen showed a bare spinner
  and no explanation. Not a defect of this phase's code; it is the same class, one screen over.
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

**POCO F3 — connected, app STILL NOT INSTALLED, and it cannot be.** `1720f883`, `alioth_eea`,
Android 13 / API 33, HyperOS `OS1.0`. Every install route returns `INSTALL_FAILED_USER_RESTRICTED`;
HyperOS's *Install via USB* toggle is off and adb cannot set it. **This needs a physical tap before
the next session plans anything on it** — Developer options → *Install via USB* (MIUI usually also
wants a signed-in Mi account and a SIM). Nothing else about the phone changed.

**AVD `Medium_Phone_API_36.0`** — now **Mum, the watched person**, signed in as `emulator-mum`,
watched by Ana and watching her, away until 1 Sep (the truncated period), store at **v6**, forced
date cleared, `font_scale` back to 1.0 and density reset. Scratch rig; *Wipe store* resets it.

**AVD `IAmOk_Watcher_36` — new, created for this run** from
`system-images;android-36;google_apis_playstore;x86_64`, running as **Ana, the watcher**. It exists
because two instances of one AVD require **every** instance to carry `-read-only`, which the
already-running one did not. Keep it; a second identity is needed by every away row.

**`emulator-data/` is the 2026-09-01 export and it DOES contain this pairing** — both users, both
links, the away document. Exported with `firebase emulators:export emulator-data --force --project
i-am-ok-c74ca` **against the running hub**, which is the way to keep state when the suite was started
detached and so can never receive the Ctrl-C that `--export-on-exit` needs. Phase 5 lost its state
exactly there. `emulators.ps1` prints the export's date on import, so a stale one stays visible.

**Nothing is deployed.** `firebase functions:list` returns *No functions found*, re-verified
2026-08-31. `firestore.rules` **has changed this phase** and is **not deployed** — the live ruleset
is still the Phase 4 one. That matters for the ordering rule: `deploy-notes.md` says deploy rules
before any client build not pointed at the emulator, and a client built against the *old* rules would
have the set-once defect back, arriving as `permission-denied` → a refusal claiming the app cannot
change the away period.
