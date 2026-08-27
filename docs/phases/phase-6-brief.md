# Phase 6 — Away mode · brief

**Opened:** 2026-08-26, at the end of Phase 5.

**Deliverables** (PLAN.md) — `users/{uid}/shared/away`; rules validation (31-day cap — **deliberately
slack in the rules**, the exact check is `AwayRules`; no retroactive; `through >= from`); the
`onAwayChanged` fan-out; the Away button on the Tap screen (which becomes *"I'm not away"* while
active); and the away action on the watcher list.

**Exit criteria** — away set from **either side** silences **both** sides everywhere; cancelling
restores both; and a device that was offline for the whole period still ends away on the right day.

---

## Prompt to start the session

> I'm starting **Phase 6 — away mode** of the I Am Ok project. Read `docs/phases/phase-6-brief.md`
> first, then follow the reading order in `docs/README.md`. `docs/phases/phase-5-summary.md` is the
> previous phase — read its *Closing the phase* and *The gate review* sections, because three things
> settled there constrain this phase directly. `docs/OPEN-QUESTIONS.md` lists what is deliberately
> unsettled and **none of it blocks this phase**; check its *Blocking-when* table rather than
> re-deriving any entry.
>
> **Build and test against the local Firebase Emulator Suite**, as Phases 4 and 5 did. A real
> Functions deploy is neither needed nor wanted here, and it would currently fail — four prerequisite
> 2nd-gen APIs are missing, enabling them is billable, and it is the owner's call.
>
> **Where Phase 5 left things.** Complete and **signed off**, 2026-08-26. Its exit criterion was met
> on two devices; all three owner decisions were taken; the five reviewers ran **twice** — once over
> the phase, once over the close-out itself, which found four more defects in it. 1 202 Dart tests,
> 83 Functions tests, 75 rules tests, `flutter analyze` clean, debug and release APKs build, secrets
> guard clean, mutation harnesses in the repo and green.
>
> **Nothing from the last three commits has been on a handset.** The chooser behind *Add someone*,
> the empty-audience 21:00 reminder and the fourth refusal are covered by tests and mutation only.
> **The first thing to do on a device is press *Add someone*, take the second option, and confirm a
> warning alarm actually arms** — that is the defect the gate review found, and only a device proves
> the fix.
>
> **This phase opens with one owner copy decision**, which `screens.md` has marked *"Owed before
> Phase 6 ships the away picker"* since Phase 3. See *The decision this phase opens with*, below. Do
> not decide it alone.

---

## What already exists, and what emphatically does not

Away has been designed into this app since Phase 1 and deliberately built up to. **More of it exists
than you would expect, and the gaps are precise.**

**Exists and is load-bearing:**

| | |
|---|---|
| `AwayPeriod` (Domain) | `covers()`, `isAbsurd`, `clampedToSanityBound()`, and `tryCreate` for the parse boundary — a corrupt `through < from` must surface as *no valid away period*, never as an exception thrown inside an alarm isolate with seconds to live. `through >= from` is **unrepresentable**, not validated. |
| `AwayRules` (Domain) | `maxDaysAhead = 30` → `maxLengthInDays = 31`; `absurdLengthInDays = 60`; `validateCreate` / `validateUpdate` returning `AwayRejection?` (`retroactiveFrom`, `exceedsCap`, `fromChanged`). **The exact client-side cap.** |
| `firestore.rules` | The away validation **and** attribution rules are written, deployed and covered by **27 tests** in `rules-tests/away.test.mjs`. |
| The `away` parameter | Threaded through `ReminderPolicy.remindersFor`, `WarningPolicy.decideFor`, `WatchedReconciler.reconcile` and `WatcherReconciler` **since Phase 1**, required at every call site, with every production caller passing `null` and saying why. PLAN.md made that non-negotiable precisely so this phase is not a retrofit. |
| The watcher-side **read** | `FirestoreCheckInReader` already reads `users/{watchedUid}/shared/away`; absent means not away (§12). |
| `self_away` table | In `LocalStore`'s schema since v5, one row (`id = 0`), columns `from_day`, `through_day`, `set_by`, `set_by_name`. |
| Copy | The picker's labels are **frozen and approved**: *"Last day away: Saturday 22"* · *"Back on Sunday 23"*. `TapCopy.away(lastDay)`, `awayAction` (*"I'm away"*) and `notAwayAction` (*"I'm not away"*) all exist. |
| The Tap screen's control | `_AwayAction` is rendered, sized and placed, with `onPressed: null`. Present since Phase 2 so the layout it must live in was settled while the screen was simple. |

**Does not exist yet — this phase writes it:**

- **`LocalStore` has no `self_away` accessors.** The table is in the schema, in `dump()` and in
  `wipe()`, and **nothing reads or writes it**. That is the shape this project prefers: a table
  added with the schema so the feature is not a migration.
- **No away repository and no client write path.** Away is a **direct client write** under rules
  (§8, §12) — the first feature since Phase 4 to touch `firestore.rules` from the client side.
- **`onAwayChanged`** — the **fifth** Function. `functions/src/index.ts` lists it in its header table
  against Phase 6 and it is not implemented.
- **The away picker.** `screens.md` has the copy; the layout is marked *undesigned*.
- **The watcher list's away action.** The row content is decided; the action is not built.
- **`TapCopy.away` has no call site.** The Tap screen has no away *state* — only the inert control.
  `screens.md`'s state table now marks that row **"specified, not built; Phase 6"**.

---

## The design decisions already made — do not re-litigate these

**Away is one global state per watched person, anyone can set it, no approval** (§12, and the
ARCHITECTURE summary table). It is a property of the watched **person**, not of a pair. One document,
one truth — the alternative silences one watcher and warns another about the same holiday.

**No retroactive away, and `from` is immutable after creation** (ADR-0001 decision 6). `from` is
always **today**; the picker selects the **last away day** only. There is no future-dating in v1.

**The cap is 31 days counting `from`, expressed as `maxDaysAhead = 30`.** §12 said "30 days" for a
while and every calculation said 30 days *ahead*; the prose was corrected to the arithmetic rather
than the reverse, because nothing derives from the number.

**The rules are deliberately slack and the client check is exact, and they are not meant to match.**
`through <= request.time + 32d` in rules — they cannot compare a local date to a UTC instant — against
`AwayRules`' exact `today + 30`. A read-time sanity bound of **60 days** sits above anything the rules
can admit, because a bound at the exact cap would un-honour periods the server legitimately accepted
and warn a family about days they really did mark away.

**Tapping during an away day is still allowed.** Harmless, reassuring, and it writes a normal check-in
watchers see as usual. `ReminderPolicy`'s docstring names the plausible bug: suppressing the *write*
along with the reminders.

**Away suppresses reminders on the watched side and warnings on the watcher side**, and the
suppression is computed in the domain from a period, never from a flag someone set.

**Every surface that displays an away period names who set it** — *"Ana marked Mum away until Sat 22
Aug."* That is why `self_away` has `set_by` and `set_by_name`, and why the rules validate attribution
(`setBy == request.auth.uid`).

---

## The decision this phase opens with — **OWNER**

`screens.md` has carried this since Phase 3 and it comes due now:

> **Owed before Phase 6 ships the away picker:** `TapCopy.away` names nobody, while this file also
> says *"every surface that displays an away period names who set it"*. Those two contradict, and the
> string is frozen now. If a watcher marks her away, she should probably read who did.

`TapCopy.away` reads *"You're away until Saturday 22. Your family isn't expecting a check-in."* It is
**already-approved copy** with no call site, so changing it costs nothing yet — and it is exactly the
case that makes attribution matter, because a watcher can set it from her phone and the watched person
finds out from this line. **It is a copy decision, so it is the owner's.** Put it before building the
Tap screen's away state, not after.

---

## What Phase 5's close-out changed that this phase touches

Three couplings, all recent, all easy to trip over:

**1. `AlarmScheduler.apply` now takes a required `hasAudience`**, and away is the *other* input to the
same call. The flag selects the 21:00 reminder's wording — it drops *"so your family knows you're
well"* when no accepted link exists — and it deliberately does **not** ride on `ScheduledReminder`,
because that type's equality is diffed against a `LocalStore` snapshot with no audience column. Read
`alarm_scheduler.dart`'s docstring before changing what suppresses reminders. Its stated staleness
window is also worth knowing: the body follows the audience at the **next reconcile**, and a remote
link change triggers none.

**2. The Tap screen now has two secondary controls of equal weight, 20dp apart** — *Add someone*, then
*I'm away*. `guidelines.md`'s mis-tap reasoning is about distance from the **tap target**, which still
holds; what it does not consider is a nearer neighbour of the same weight. **Give Away visible
separation in the same change that enables it**, not after — recorded in `screens.md`. Shipping the
look-alike pair and fixing it later is the one ordering that cannot be undone for whoever has already
used it.

**3. `PairingRefusal.serverFault` is the pattern any new refusal copy should follow.** ADR-0004's
*refused is not unreachable*, one layer down: a sentence that claims nothing about either side, for
the case where the phone reached the backend and cannot act on the answer. Away's write path will need
its own refusals — a rejected period, a rules denial, a lost connection — and they are three different
sentences. The companion decision is where they render:
`PairingRefusalSurface.isAboutTheCode` splits refusals by **what they are a claim about**, because
`errorText` turns a field red and that is a second, wordless claim.

---

## Emulator-first, still

Same two reasons as Phase 5, both unchanged and both re-verified from the CLI on 2026-08-26:

1. **A 2nd-gen deploy would fail.** `cloudbuild`, `artifactregistry`, `eventarc` and `run` are all
   missing. Enabling them is billable and is the owner's call.
2. **It is not needed.** `tools/emulators.ps1` runs auth, firestore, functions and the UI;
   `tools/functions-test.ps1` and `tools/rules-test.ps1` exercise both halves.

> **Only one emulator script may run at a time** — `emulators.ps1`, `rules-test.ps1`,
> `functions-test.ps1` and `functions-mutate.ps1` all want ports 8080 / 9099 / 5001. The second one
> fails with *"Port 8080 is not open on localhost"*, which reads like a broken script rather than a
> busy port.

**Two devices need two identities**: `--dart-define=IAMOK_EMULATOR_USER=…` and `…_NAME=…`. Without
them both phones sign in as the same person. `emulators.ps1` prints the full command.

**The ordering rule matters more than it did.** `deploy-notes.md` says deploy Functions *before* any
client build not pointed at the emulator — and since Phase 5 remapped `not-found` to `serverFault`, a
client shipped ahead of the deploy now says *"That did not work just now. Try again in a moment."*
indefinitely, with nothing on screen to say why.

---

## What is not a blocker

`docs/OPEN-QUESTIONS.md` is the register, and **nothing in it triggers on this phase** — rows 8, 9 and
12 fire at Phase 7; 5 and 11 before App Check enforcement; 6 on the first real user data. Two are
worth carrying while building here:

- **Delete protection and PITR are both OFF** (#6), the only entry with a hard *external* deadline.
  This phase does not cross its trigger.
- **`OPEN-QUESTIONS.md` #11's blast radius is partly about away.** A guessed invite grants an accepted
  link, and an accepted link can **write** `users/{watchedUid}/shared/away` — so a stranger could set
  a ~32-day away period and suppress the missed-day warning for **every** watcher, renewably. That is
  silence rather than a false alarm, which is the direction this app cannot detect in itself. **This
  phase builds the surface that makes it reachable by a person rather than only by an API call.** Not
  a blocker; a reason to be careful about who can set away and what the watched person is told.

**Carried from Phase 4 and unchanged:** the first Functions deploy, App Check's console half, the
live-radio measurement, and what ADR-0008's option 1 costs — the only open *design* decision, and the
owner asked for the number rather than the ADR.

**Carried from Phase 5's gate review, all recorded and none blocking:** the `Home.build` hang (which
also blocks `app_lifecycle_test.dart` and is worth a timebox), `InviteCode.forSpeaking`, and the fact
that both mutation lists cover Phase 5 surfaces only — `DayKey`, `AwayPeriod`, `ReminderPolicy`,
`WarningPolicy`, both reconcilers and `firestore.rules` are unmutated. **`AwayPeriod` becoming live
code is a good moment to extend them.**

---

## The device rig, as Phase 5 left it

**POCO F3 — the app is UNINSTALLED, deliberately.** It held an accepted link to a synthetic *Mum* on a
local emulator and 81 alarm entries including armed warning alarms; the emulator has since stopped, so
those alarms would have fired against a backend that no longer answers and posted an offline notice
about a person who does not exist — on the owner's personal phone. **Phase 4's recorded POCO state is
gone and is not restorable.**

**AVD `Medium_Phone_API_36.0`** — holds a paired *Mum*↔*Ana* state: signed in as Mum, accepted link to
Ana, onboarding complete, today's check-in recorded. Scratch rig; *Wipe store* resets it.

**`emulator-data/` is the 2026-08-25 export and does NOT contain that pairing** — the suite was killed
rather than `Ctrl-C`'d. **Re-pair; do not try to reconcile the two.** `emulators.ps1` prints the
export's date on import so this is visible rather than silent.

**Traps that cost real time, all measured:**

- **Every FlutterFire API that takes an emulator host rewrites it on Android** unless passed
  `automaticHostMapping: false`. Three plugins, three for three; `android_manifest_test.dart` counts
  the calls against the opt-outs. The symptom is *half the app working*.
- **`--export-on-exit` runs only on a clean Ctrl-C.** A kill discards everything since the last export
  with no message.
- **`adb reverse` dies with an adb *server* restart**, not only a cable unplug.
- **HyperOS refused the first `adb install`** with `INSTALL_FAILED_USER_RESTRICTED` and accepted a
  retry.
- **Pull the app's database with `adb exec-out run-as … cat`**, never a shell redirect — the redirect
  writes a zero-byte file and `adb pull` still reports success.
- **Read a big `dumpsys` by writing it to a file on the device and pulling it**, never through the adb
  pipe.
- **A force-stop cancels every AlarmManager alarm and tells the app nothing.** Ask the platform, or
  assert the whole desired set.

---

## How this phase is expected to go wrong

**Away is the first feature whose failure mode is silence.** Every phase so far could fail loudly — a
warning that did not arrive, a screen that would not load, a code that would not redeem. An away
period that is honoured when it should not be, or that never ends, produces **no notification and no
error**, on both sides, for up to 31 days. §12 calls a permanently silent watcher *the one failure
this app cannot detect in itself*. Design the tests around ending, not around starting.

**The exit criterion's third clause is the hard one.** *"A device that was offline for the whole
period still ends away on the right day."* That is not a fan-out test — it is what happens when the
push never arrives, and it is where a cached away period outliving its own `through` day would be
invisible. `WatcherReconciler` already clamps and honours; the question is what the **cache** does.

**Two sides can now write the same document.** Away is settable by the watched person and by any
accepted watcher, and the rules permit both. Decide what happens when they disagree, and what each
party is told, before writing the write path.

**Read a claim against the thing it describes.** Across every review round in this project, almost
nothing has come from a test failing. Phase 5's gate review alone found five claims that had stopped
being true — a runbook describing a message the same commit had deleted, a threat-model row promising
a log query more than it would find, a permission count wrong for two phases while the same
docstring's own arithmetic disagreed with it, a command that could not see the thing it was cited as
having measured, and a copy file still saying its strings were *owed approval* in the commit that
approved them. **This phase's most likely version of that is §12 itself**, which has been written
against for six phases and built against for none.

**Verify the measurement before you trust the result, and distrust a green harness most.** Phase 4's
mutation runner reported five green results that were an encoding crash. Phase 5's rebuilt harness
reported **14/14 with no compile gate at all** — three of those mutations never compiled, and a Dart
compile error prints the red phrase verbatim. Both harnesses now refuse to score rather than guess;
when one reports `UNREADABLE`, the caller is usually wrong, and that refusal is what makes the cause
findable.

**When a mutation comes back unexpected, check whether the mutation is bad first.** Across two phases
the split is roughly even between real gaps and bad mutations — including one that *survived* because
a downstream guard returned the same status, which reads exactly like a test gap and is not one.

**A false claim to a family is the worst bug this app can have.** In this phase that is: telling
somebody their family is not expecting a check-in when it is, telling a watcher someone is away when
they are not, or saying nothing at all for a month. Prefer stopping to ask over guessing, and if you
think a finding is wrong, say so before acting on it rather than after.
