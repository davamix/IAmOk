# Phase 6 — Away mode · handover

**Written:** 2026-09-01, at the end of the build-and-review session.
**Updated:** 2026-09-01, after the device run.
**Status:** Built, all five reviewers run, every finding applied, **run on two AVDs and then on the
POCO F3 — every Phase 6 checklist row answered, including the OEM half — and all seven owner
decisions taken and applied, 2026-09-01.** **Not signed off**: Doze is unmeasured, and §12's four
away transition notifications are specified and deliberately not built.

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
> end on two API 36 AVDs and then on the POCO F3** — picker, both surfaces, both cancel shapes, the
> closed-app nudge in both directions, the offline queue and the v5 → v6 migration. The evidence is
> in `docs/testing/device-matrix.md` under *The Phase 6 away run* and *…and then the POCO*. Do not
> re-run those rows for their own sake.
>
> **If the POCO refuses an install** with `INSTALL_FAILED_USER_RESTRICTED`, that is HyperOS's
> *Install via USB* developer toggle, which it revokes on its own schedule. **A retry does not fix
> it and adb cannot set it** — ask the owner for a physical tap (Developer options → Install via
> USB; MIUI usually also wants a signed-in Mi account). That cost an hour on 2026-09-01 before the
> run could touch the phone at all.
>
> **The owner's decisions are taken and applied** — the copy is approved, the picker title names the
> person on a watcher's phone, ending a period from the watcher's row asks first, that row says when
> a write lands, and a **queued** away write is now cached on the phone that wrote it. Do not
> re-open them; the answers and the questions they answered are both in `docs/ui-ux/screens.md`.
> **One thing is still recorded and undecided**: `invite_service.dart` has no client-side timeout,
> so the pairing screens spin on the SDK's 60-second default.
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
> **What is left before sign-off is Doze on the handset** — everything else ran with the screen on —
> and §12's four away transition notifications, which are specified and deliberately not built. The
> **cancellation** notice among them is different in kind and is written up as a §17 gap.

---

## Where things stand

**Seven commits on `main`, `b79a7b6..HEAD`.** Nothing pushed — this project commits to `main` and
pushes only when asked.

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | **1 370** (1 202 at the start of the phase; 1 354 before the owner's decisions were applied) |
| Rules tests | **80** (75 before) |
| Functions tests | **102** (83 before) |
| `tsc --noEmit` | clean at the pinned Node 22 types |
| Debug APK | builds |
| Secrets guard | clean — 25 ignored, 6 deliberately tracked |
| Dart mutations | **34 caught, 0 survived, 0 did not compile**, 13 passing controls |
| Device | **every Phase 6 row run 2026-09-01 — two API 36 AVDs, then the POCO F3 for the OEM half** |

**All three exit criteria are met in tests** — `test/application/away_exit_criteria_test.dart`,
driven end to end through both reconcilers and built around **ending** rather than starting, because
away is the first feature here whose failure mode is silence — **and now on devices too**, the third
of them on the POCO with aeroplane mode on and the harness walking the clock across the boundary.

### The mutation harness, and what it cost to get a number

**34 mutations, 34 caught, 0 survived, 0 `DID NOT COMPILE`**, thirteen passing no-op controls,
**re-run 2026-09-01 after the owner's decisions were applied**, on a clean tree. Twenty of the 34
are away surfaces. Re-run with:

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

**Three mutations were added with the owner's decisions**, because that code is silent-direction by
construction — if any of it stops working the phone quietly returns to saying *"Saved."* and then
contradicting itself, which is the state the device run measured:

| | What goes silently wrong |
|---|---|
| `_cacheQueued`: the negation dropped | Everything *but* a queued write is cached, so the one case that needed it is the one that loses it |
| `endAway`: `null` where `truncated` belongs | A queued shortening reads locally as a cancellation, and the days already spent away stop being covered |
| The away row discards the dialog's answer | The confirmation appears and *Go back* ends the period anyway — worse than no dialog, because it teaches the reader to press through |

All three were caught, which is what says the sixteen new tests are load-bearing rather than
decorative.

> **DONE, 2026-09-01.** `mutate-runner.mjs` refused an ambiguous `from` **when it reached that
> mutation** — up to twenty minutes in, twice at the gate. `validateAnchors(groups)` now runs
> **before anything else** in `mutate-dart.mjs` and throws naming every anchor that does not match
> exactly once. It changes no verdict; it moves when the existing guard fires, from twenty minutes
> to two seconds. Proved in both directions before it was committed: real anchors pass, and a
> missing one (0×) and an ambiguous one (12×) are both named in the same throw.

---

## What to do next, in order

### 1. The device run — DONE, 2026-09-01, on two AVDs and then on the POCO

**Every row of the Phase 6 checklist is ticked**, including the Phase 5 carry item (the chooser's
second option, and six warning alarms confirmed armed from `dumpsys alarm`), and **the OEM half was
then re-run on the handset**. The evidence, timings and exact figures are in
`docs/testing/device-matrix.md` under *The Phase 6 away run* and *…and then the POCO*. **Do not
re-run them for their own sake**; re-run one only when its code changes.

**What the POCO settled**, at stock power settings: reminders armed 21/21 around an away period with
nothing trimmed by the vendor, and the **closed-app nudge working in both directions** — a
cancellation and a creation each woke a killed app, rewrote `self_away` and re-armed the alarms
without the app being opened. Then *"Ana marked you away until Thursday 3."* on the handset itself.

**The third exit criterion is done too** — *"a device offline for the whole period still ends away on
the right day"*, run on the POCO on 2026-09-01 in eleven minutes with aeroplane mode on throughout
and the harness walking the clock across the boundary. Every read was refused (`UNAVAILABLE`), the
period ended by arithmetic on the first day back, the cached row survived, and the reminders came
back on the right day. All three criteria are now met on devices, not only in tests.

**What is still owed on the phone is Doze**, and only that: everything above ran with the screen on.
This page's own note says `deviceidle force-idle` will not reach deep idle on this device from a
screen-off state, so it needs a real overnight.

`adb` is **not on PATH**. It is at `D:\Android\Sdk\platform-tools\adb.exe`.

**The rig this run leaves behind:** AVD `Medium_Phone_API_36.0` as **Mum** (watched, away until
1 Sep after the truncation); a new AVD **`IAmOk_Watcher_36`** as **Ana** (watching Mum and Pop, and
watched by Mum); and the **POCO as Pop**, a third identity (`emulator-pop`, host `127.0.0.1` over
`adb reverse`), watched by Ana and away until 3 Sep as she set it. Two instances of *one* AVD will
not run unless **every** instance carries `-read-only`, which is why a second AVD exists at all.

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

### 2. The owner decisions — ALL TAKEN, 2026-09-01, and applied

Nothing here is owed any more. The answers, and where they live, are in
`docs/ui-ux/screens.md` under *Away picker → Copy* and *The decisions this phase opened*; the
questions are kept beside them, because a decision without the question it answered is unreadable a
year later.

**The copy is approved**, with one amendment: the picker title now names the person on a watcher's
phone (*"Choose the last day Mum is away"*), because sharing the Tap screen's *"you"* asked a
watcher about herself. The rest — `Save`, `Go back`, the queued sentence and the four refusals —
stands as drafted.

**The seven decisions, and what each one cost to apply:**

| | Decided | Where it landed |
|---|---|---|
| Extending a period in force | Record the limitation, revisit after ship | ARCHITECTURE.md §12, beside the sentence that says away may be extended |
| The watcher row's cancel | Add a confirmation, that row only | `_AwayRowActionState._confirmEnd`, `scrollable: true`, 48dp actions, *Go back* reused verbatim |
| Nothing is said when a write lands | Split the surfaces | The Tap screen stays silent; the watcher row says *"Saved. Mum is marked away."* and speaks it |
| The writer nobody can name | Keep as-is | No change |
| The spoken outcome strings | Approved as they stand | No change |
| The picker title | Name the person on the watcher's phone | `AwayCopy.pickerTitleFor`, `AwayPickerScreen.personName` |
| Away set offline says *"Saved."* | Cache it locally and re-arm | `WatchedNotifier._cacheQueued`, **watched side only** |

**The last one is the only one with teeth**, and it is bounded deliberately: a queued write goes
into `self_away` on the phone that wrote it, the reconcile re-derives the reminders from there, and
the first read that *succeeds* overrules it — including by saying there is no period at all. Being
wrong therefore **stops reminders**, which is the loud direction, rather than silencing anybody. The
watcher's cache still comes only from a read that succeeded, because there the same shortcut would
silence a watcher about somebody else for up to a month.

**16 new tests**, and the one that carries the decision is the negative: *Go back* must write
nothing. A confirmation that runs the action anyway is worse than none.

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

**POCO F3 — the app IS installed, signed in as Pop.** `1720f883`, `alioth_eea`, Android 13 / API 33,
HyperOS `OS1.0`, stock power settings, locale `es-ES`, 24-hour clock, 392.7dp wide. Watched by Ana,
away until 3 Sep as she set it, notifications granted. Built with `IAMOK_EMULATOR_HOST=127.0.0.1`,
so it needs `adb reverse` — run `tools/emulators.ps1 -Device 1720f883`, which sets it up and dies
with the cable. *Install via USB* is **on again**; if it stops being on, that is the toggle, and a
retry will not do it.

**AVD `Medium_Phone_API_36.0`** — now **Mum, the watched person**, signed in as `emulator-mum`,
watched by Ana and watching her, away until 1 Sep (the truncated period), store at **v6**, forced
date cleared, `font_scale` back to 1.0 and density reset. Scratch rig; *Wipe store* resets it.

**AVD `IAmOk_Watcher_36` — new, created for this run** from
`system-images;android-36;google_apis_playstore;x86_64`, running as **Ana, the watcher**. It exists
because two instances of one AVD require **every** instance to carry `-read-only`, which the
already-running one did not. Keep it; a second identity is needed by every away row.

**`emulator-data/` is the 2026-09-01 11:47 export and it DOES contain all of this** — Mum, Ana and
Pop, both of Ana's links, and the away documents. Exported with `firebase emulators:export
emulator-data --force --project i-am-ok-c74ca` **against the running hub**, which is the way to keep
state when the suite was started detached and so can never receive the Ctrl-C that `--export-on-exit`
needs. Phase 5 lost its state exactly there. The second export printed *"Export complete"* and then
exited 9 with the documented libuv assertion — read the output, not the code. `emulators.ps1` prints
the export's date on import, so a stale one stays visible.

**Nothing is deployed.** `firebase functions:list` returns *No functions found*, re-verified
2026-08-31. `firestore.rules` **has changed this phase** and is **not deployed** — the live ruleset
is still the Phase 4 one. That matters for the ordering rule: `deploy-notes.md` says deploy rules
before any client build not pointed at the emulator, and a client built against the *old* rules would
have the set-once defect back, arriving as `permission-denied` → a refusal claiming the app cannot
change the away period.
