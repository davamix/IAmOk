# Phase 6 — Away mode · summary

**Date:** 2026-08-27 · **Status:** Built, reviewed by all five reviewers, and their findings
applied. **Not yet signed off** — nothing here has been on a handset, and the drafted picker and
refusal copy is owed the owner's approval.

**The gate found that the feature did not work.** Away could be set once per person and then never
again — see *The gate review* below, which is the part of this document to read first.

Start from [phase-6-brief.md](phase-6-brief.md) for what this phase was asked to do. This file is
what happened.

---

## The one-line story

Away had been designed into this app since Phase 1 and deliberately built up to — the domain type,
the rules, the `self_away` table and the `away` parameter on every policy all existed before this
phase started. What was missing was everything that makes it reachable by a person: a client write
path, the fourth Function, the picker, and any accessor for the table that had sat in the schema for
five versions with nothing reading it. **It is a feature now, not a retrofit, which is exactly what
PLAN.md set that arrangement up for.**

---

## The decision this phase opened with — **OWNER, taken 2026-08-27**

`screens.md` had carried this since Phase 3: `TapCopy.away` named nobody, while the same file
requires every surface that displays an away period to name who set it. The two contradicted, and
the string was frozen.

**Decision: name who set it *when it wasn't you*.**

| Who set it | The watched person reads |
|---|---|
| A watcher | *"Ana marked you away until Saturday 22. Your family isn't expecting a check-in."* |
| Herself | *"You're away until Saturday 22. Your family isn't expecting a check-in."* — the approved string, **unchanged** |
| Nobody nameable | The same unattributed string |

It reads the way a person speaks, and it keeps the already-approved string exactly as it was for the
case she did it herself. It was put **before** the Tap screen's away state was built, as the brief
required.

**It is the surface §17's mitigation depends on.** *One watcher silences the whole family by setting
away* is accepted by design, and the recorded control is `setByName` on every surface plus anyone
being able to cancel. This screen is read by the one person best placed to notice *"I am not away"*,
so a line here naming nobody would have left that mitigation resting on surfaces she never sees.

**The unattributed line is also the fallback**, and that is the right fallback rather than a
convenient one — see *A missing name may never cost the period* below.

---

## What was built

| | |
|---|---|
| `AwayRecord` | The away **document** — the period plus `setBy` / `setByName`. A separate type from `AwayPeriod`, deliberately |
| `AwayRead` | The watched side's three-state read. ADR-0004's split, on this side |
| `AwayOutcome` / `AwayRefusal` | What a write did, and why it did not land |
| `AwayRepository` | The direct client write and read, under the rules — the first client write to `firestore.rules` since Phase 4 |
| `LocalStore.selfAway` / `setSelfAway` | The accessors the `self_away` table waited five versions for |
| Schema **v6** | `away_set_by` / `away_set_by_name` on `watcher_cache`, so an offline watcher's row can still name who set the period |
| `onAwayChanged` | The **fourth** Function. `onDocumentWritten`, fans out to every party, skips whoever acted |
| The away picker | A screen, with the two frozen labels rendering live beneath the calendar |
| The Tap screen's away state | The line, and the live control with the separation `screens.md` required |
| The watcher list's away row and action | The branch `screens.md` named in Phase 3, above *"Everything OK"* |

**Test counts:** 1 322 Dart (1 202 before), 102 Functions (83 before), 75 rules (unchanged — the
away rules were already written and covered by 27 of them). `flutter analyze` clean.

---

## The design decisions taken, and why

### Attribution is a separate type from the period

`AwayPeriod`'s own docstring scopes it to *"from/through, containment, validity"* and says
attribution is document metadata for display and for the rules, **never an input to a decision**. So
`AwayRecord` carries the rest of the document, and every policy call site takes `away.period`.

Keeping them apart at the seam is the point. The moment a policy can see `setByName`, it can decide
from it — and that is the one field on this document [ADR-0003](../architecture/decisions/0003-away-attribution.md)
says cannot be authenticated.

### A missing name may never cost the period

ADR-0003's *Absence* case — an older build or an admin write omitting the field. `AwayRecord`
degrades to **unattributed**, never to *no away period*: dropping the period would warn a family
about days somebody really did mark away, which is the worst thing this app can do.

It falls out neatly, because the unattributed rendering is the **already-approved** string. It names
nobody because there is nobody to name.

The name is also **bounded on read**, which the rules cannot do — they bound only what this app's own
clients write, and ADR-0003 names a long clinical string as the injection that arrives by any other
door and reaches every family member's notification tray through this field.

### `AwayOutcome` has no "could not reach the server", and the absence is the decision

This is the one place the brief's anticipation was not followed, so it is stated plainly. The brief
expected *"a rejected period, a rules denial, a lost connection — three different sentences"*.
**There is no lost-connection refusal, and there must not be one.**

§8 chose a direct client write over a callable **on purpose**: *"a watcher can set away on a plane
and have it queue offline like any other write."* Firestore holds the mutation and replays it when
the connection returns, and the future the SDK returns completes only once the server has it. So a
write that has not confirmed is in one of two states the client **cannot tell apart** — still in
flight, or queued behind a dead radio — and both end with the write landing.

That makes *"could not reach the server"* a sentence this path can never truthfully say. Saying it
would tell somebody their family had not been told about a write that arrives ninety seconds later,
and the obvious response is to set the period again — a second write of the same thing, attributed to
the same person. `AwayOutcome.queued` is the honest name for the state that actually exists, and it
is **not a refusal**.

It is ADR-0004's *refused is not unreachable* one layer below where `PairingRefusal.serverFault` took
it, which is the pattern the brief asked to follow. `unavailable` and `deadline-exceeded` are
deliberately absent from `refusalForCode` for the same reason.

### Nothing is optimistically cached on the watcher side

A watcher writing somebody else's away document does **not** write their own cache. Only a read that
succeeded may replace `away` (ADR-0001 decision 1), and a write that was refused would otherwise
leave that watcher silenced about somebody for up to a month with **no notification and no error** —
the direction §12 calls the one failure this app cannot detect in itself.

The watched side does write its cache, through the reconcile, and the asymmetry is deliberate: its
failure direction is a false **warning**, which is loud and self-correcting.

### The watcher's away row is keyed on *her* today

Not on the day the warning decision is about. The decision is about `D` — the last completed day in
her zone — so a period starting today does not touch it, and a row keyed on `D` would read
*"Everything OK"* on the first day of a holiday, with a last-seen date about to stop moving for a
fortnight and nothing saying why.

`decision.day.next` is her today **by definition** — `WatcherReconciler` states that `daysToDecide`
always ends at `D` — so it is derived rather than carried. A second source for it would disagree
exactly at a watched-local midnight, which is where every day-boundary defect in this project has
been.

### `WatchedRowKind.away` sits *below* `warning`

They look mutually exclusive and are not. `warnUnverifiableAway` is a warning **about** an away
period this device could not re-verify, and it must render as the warning it is rather than as a calm
*"Away until Saturday"* claiming a certainty the read never established.

The exhaustive switch in `watcher_screen.dart` refused to compile until the branch was added, which
is what its docstring promised it would do.

### No confirmation step on cancelling away

A mis-tap on *"I'm not away"* fails **loud**: reminders and warnings come back, which is this app's
default-safe state, and setting away again is two taps. A confirmation dialog would be a third
surface on the screen `WatchedAudience` records this project refusing extra surfaces on.

The mis-tap worth defending against is the other direction — pressing **away** by accident, which is
silent — and that is what the separation below is for.

### Away got its visible separation in the same change that enabled it

`screens.md` required this ordering rather than suggesting it: the Tap screen now carries two
secondary controls of equal weight, `guidelines.md`'s mis-tap reasoning covers only distance from the
**tap target**, and shipping the look-alike pair and fixing it later is the one ordering that cannot
be undone for whoever has already used it.

A **divider**, not more whitespace. A rule is a signal a reader takes at a glance; a gap is one they
have to measure.

### The picker is a screen, not a dialog

A calendar plus two sentences plus a 48dp action does not fit a dialog at the largest system font
scale on a small phone, and a `Column` that overflows its constraint is clipped in release —
silently, with no stripe. That is the defect the Phase 5 gate measured in the *Add someone* sheet.

Its `lastDate` comes from `AwayRules.maxDaysAhead`, so the screen **cannot offer a day its own
validation would refuse** — which is why `AwayRefusal.rejectedPeriod` is reachable only by the
device's date moving underneath the reader, and not by anything they can press. An out-of-range
stored period is clamped rather than trusted, because `CalendarDatePicker` asserts on an
`initialDate` outside its bounds and the rules are deliberately slacker than `AwayRules`.

### `onAwayChanged` is `onDocumentWritten`

`onCheckInCreated` fires only on **create**, because the document id is the day and a second tap must
not re-announce it. Away is the opposite: the id is fixed at `shared/away`, so every meaningful
change is an update or a delete. Extending, truncating and cancelling would all be invisible to a
create-only trigger — and the cancellation matters most, because until every device hears about it
their family stays silent.

It goes to **every party**, including the watched device, whose reminders are what must change. It
skips whoever acted, from the document's own `setBy` — rules-enforced, so it is the one trustworthy
statement about who did it. A **delete** names nobody and skips nobody: the safe direction, because
one redundant reconcile costs a reconcile and a dropped nudge costs silence.

It has **its own collapse key**. FCM keeps at most four per offline device and drops the excess
unspecified, so sharing `iamok-checkin` would let a burst of check-in nudges collapse an away change
out of the queue — and they are not interchangeable.

**Losing every message it sends changes no answer.** Expiry is arithmetic against `through` on every
device, which is what §12 chose over an "away finished" message whose loss silenced a watcher for
ever. That is the property to protect when changing any of it.

---

## What the tests found

### An assertion I wrote was wrong, and the app was right

The clause-3 watcher test asserted that an away day stays `silent` on a phone that has been offline
for the whole period. It came back `warnUnverifiableAway`, and that is **correct**: six days without
a successful read is well past ADR-0001's two-day staleness bound, and §10 step 5 says silent *if
verified within two days*, otherwise the distinct unverifiable-away message.

Both halves are pinned now — inside the bound it is silent for the right *reason*
(`SilenceReason.awayVerified`, not merely "no warning fired"), and past it the away period is still
**named** rather than the family being told she missed a day.

### The purity guard caught the new repository entering the background closure

`away_repository.dart` became reachable from the background closure the moment the watched reconcile
started reading Firestore, and `domain_purity_test.dart` failed until it was declared.

**But it caught an *import*, not a call, and this paragraph said otherwise until the gate review.**
The closure is computed over what is reachable, so the file appears whether or not any background
entry point ever constructs one — and the FCM handler did not. That was a real defect no import
check could have found, and it is finding 2 below.

### The exhaustive switch caught the missing row branch

Adding `WatchedRowKind.away` broke `watcher_screen.dart`'s build until the branch was written — which
is what `rowKind`'s docstring says it exists to do, having been written out twice once before with
nothing keeping the copies in step.

---

## Mutation testing

`AwayPeriod` had been on `mutate-dart.mjs`'s *"not mutated"* list for five phases, as a type nothing
read. The brief called its becoming live code *"a good moment to extend them"*, and that is done —
then the gate review corrected which side of the app the extension belonged on.

**The first pass added eleven**, across `AwayPeriod`, `AwayRules`, `AwayRecord` and the **watched**
reconcile's away half. **The gate found that was the wrong side.** The watched side's failure is a
person being nagged through a holiday, which is loud; the silent failure lives in `WarningPolicy`
step 5 — the function that decides whether a family hears anything at all — and it had no mutation
coverage of any kind, for away or for anything else. Six more were added there and on
`WatcherCache.applyRead` and `LocalStore.setSelfAway`.

The summary also claimed all eleven were *"chosen for the direction that produces no notification and
no error"*. **Nine of eleven**: `validateCreate: retroactive away is allowed` and `validateUpdate:
from stops being immutable` both loosen a **write** guard, which is the loud direction.

The driver's header no longer claims `AwayPeriod` is unmutated, and no longer claims `WarningPolicy`
is either — corrected in the commits that made each false, which is this repo's own recurring
failure mode caught one commit later rather than one phase later.

### The harness refused to score twice before it scored, and both times it was right

Recorded because a harness whose entire job is to distrust a green result is worth more when its
refusals are written down than when its numbers are.

**1. The unmutated control came back RED.** I had been editing `lib/` and the test suite *while the
harness was running* — which is my mistake and would have been enough on its own. But the cause was
real: a migration test I had just "strengthened" was comparing `sqlite_master.sql` **text** between a
fresh install and an upgraded one. Those differ legitimately — a fresh store holds the `CREATE TABLE`
from `_schema`, an upgraded one holds the older statement with `ALTER TABLE … ADD COLUMN` appended —
so the assertion was about formatting rather than shape. The harness refused to score anything, which
is the guard's whole purpose: *"the unmutated suite is RED. Fix the tree before mutating it."* Now it
compares the table set and each table's columns.

**2. A mutation's `from` matched twice.** `honoured != null && honoured.covers(day)` appears in
`WarningPolicy`'s access-lost branch as well as in step 5, and the runner refused rather than editing
a line it might be misidentifying — *"a mutation that might be editing a different line than the one
it names cannot be scored."* Anchored on the `if (`.

Both refusals cost a re-run and nothing else. A harness that had guessed in either case would have
produced a number.

### Results

**2026-09-01: 31 mutations, 31 caught, 0 survived, 0 `DID NOT COMPILE`**, with **ten** passing no-op
controls — one per file, each of which has to pass before anything in that group is scored. That is
the number *with* the compile gate the Phase 5 gate review added, which is the only version worth
quoting.

**Seventeen of the 31 are away surfaces**: six on `AwayPeriod`/`AwayRules`, three on `AwayRecord`,
two on the watched reconcile, four on `WarningPolicy` step 5, one on `WatcherCache.applyRead` and one
on `LocalStore.setSelfAway`.

> **One mutation had to be rewritten, and why is worth keeping.** ADR-0001's gate on the watcher side
> — `if (read is! ReadSucceeded) return this;` — **cannot be mutated at all**: it is what narrows the
> type, and every line below it reads `read.checkInDays` and `read.away`, which do not exist on
> `FirestoreRead`. So every mutation of it stops the file compiling and the runner refuses to score
> it, correctly, because a mutation the compiler rejects proves nothing about the tests. Phase 5 hit
> the identical shape three times.
>
> That is **not** an unguarded property — the compiler enforces it, and the **watched-side twin**,
> where the gate is a plain boolean rather than a promotion, is mutated in this list and caught. The
> entry now covers a different real hazard in the same function: `lastConfirmedDay` losing its
> monotonicity, which would re-open a settled day and warn a family a second time about one they have
> already read and acted on.

The away mutations that matter most, each of which produces **silence** rather than an error:

| Mutation | What it would cost |
|---|---|
| `covers`: `through` stops being inclusive | She is reminded three times on an away day, and every watcher is warned about it the next morning |
| `covers`: reads the document instead of the clamp | A ten-year away document is honoured for ten years, and **nothing can catch it** — the read succeeds every day, so nothing is stale |
| `hasExpiredOn`: off by one | The period outlives itself. This is the arithmetic the third exit criterion *is* |
| `cancelOn`: deletes rather than truncates | Days already spent away are retroactively un-covered, and the next device to refresh warns about one of them |
| step 5: the two-day staleness bound becomes a month | ADR-0001's bound gone — a cached away buys **unlimited** silence, which is the defect that ADR was written for |
| step 5: a backwards clock silences the watcher | A device whose clock moved back honours a cached away on a verification that never happened |
| `setSelfAway(null)` becomes a no-op | A cancellation never lands locally: her reminders never return, and the only signal is their absence |

**The source was restored and the suite re-run afterwards** — `git diff lib/` is empty and the suite
passes. That check is here because the Phase 5 gate found a **mutated build sitting in the tree**
with `git status` clean.

---

## Verification

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | **1 354 passing** (1 202 at the start of the phase) |
| Functions | **102 passing** (83 before) — the runner globs `test/*.test.js`, and its own count is what says the new suite ran |
| `tsc --noEmit` | clean, at the pinned Node 22 types |
| Rules | **80 tests** (75 before). `firestore.rules` CHANGED this phase — see the gate review — and is **not deployed** |
| Dart mutations | **31 caught, 0 survived, 0 did not compile**, 10 passing controls |
| Debug APK | builds — three of them, from two trees, for the device run |
| Device | **run 2026-09-01 on two API 36 AVDs. Every Phase 6 row answered; the POCO refused to be installed to** — see *The device run* below |

---

## The gate review — all five reviewers, 2026-08-27

Run one at a time, results collected before anything was applied. They found **the feature did not
work**, plus two more defects that produce silence, plus a great deal that was true when written and
had stopped being.

Nothing came from a test failing. Every finding below came from reading a claim against the thing it
describes — which is what this project's gates keep proving is where the defects are.

### The one that mattered: away could be set once per person, and then never again

**Found independently by security, UI/UX and testing.** Nothing deletes the away document when a
period *ends* — deliberately, because the days already spent away must stay covered (ADR-0001
applied to the cache). So the record outlives the holiday, and both call sites passed it as
`existing`. `from` is immutable on update, so:

> A family takes a holiday in July. In August nobody can mark her away, from either phone, ever.
> The picker offers a day, the write is refused, and the sentence is *"That day does not work.
> Choose a day in the next month"* — about every day in the next month.

The rules said the same thing, so removing the client check would only have moved the failure to
`permission-denied` and a sentence claiming the app had lost access.

**Three documents said it worked.** §12: *"To go longer, set it again."* The threat model: *"a 31-day
cap forces deliberate renewal."* The rules guidelines: *"someone determined to stay away for 60 days
can set it twice, and that is the intended behaviour."* None of it was reachable.

**The fix is a scope correction, not a new rule.** ADR-0001 decision 6 froze `from` for the life of a
**period**, not of a person — its stated reason is that truncating an *in-progress* period rewrites a
document whose `from` is already past, and an ended period is not in progress. Both halves now carry
that distinction:

- `AwayRules.periodInForce` — a pure function in the domain, because it is a policy question. It was
  inline in the repository, which is why nothing could reach it.
- `firestore.rules` allows a fresh, non-retroactive `from` once the stored `through` is behind
  today. **Biased strict**, against that file's usual grain, and the comment says why: too permissive
  would let a new `from` land while a period still has a day to run, un-covering days already spent
  away — the false claim ADR-0001 exists to prevent. Too strict costs a few hours at a zone boundary.

Both new rules tests were **verified by reverting the clause**: they fail against the old rules and
pass against the new. My own test at `away_repository_test.dart` had pinned the broken half as
correct.

### The other two that produce silence

**`onAwayChanged` could not change a closed watched device.** `push_handler.dart` constructed
`WatchedReconcileService` without `away:`, so the FCM reconcile decided reminders from the very cache
the nudge came to replace. A watcher marks her away from another phone, hers stays in her pocket, and
she is reminded three times a day through the holiday. The cancellation direction is worse and is the
silent one. The Function nudged correctly the whole time.

The purity guard had caught this file entering the background closure — but it caught an **import**,
not a call, and this summary said otherwise. No import check could have found it.

**`AwayRepository.read` had no timeout while being awaited inside `tap()`.** Before this phase the
watched reconcile was entirely local. `WatchedReconcileService.tap` argues the exact point five lines
from where it now calls this: *"awaiting that on a phone with no signal would hang the tap — the one
action this app asks of an elderly person."* Bounded, reporting **unreachable**, which retains the
cache and so costs nothing in correctness.

### Claims that had stopped being true

Eleven, and most of them mine, written in the same commits that made them false:

| Said | Actually |
|---|---|
| `initialLastDay`: *"extending a holiday starts from where it ends"* | Both surfaces flip to *end* while away, so the picker is unreachable with a period in force. The path never existed |
| `_FakeAway`: *"only the two SDK calls are replaced"* | Both methods are fully overridden; it is a hand-written double and none of the production `write` runs. It decides how the exit-criterion result should be read |
| The clause-3 guard `expect(away.nextRead, …)` | Asserts what `setUp` assigned. Deleting the read from `_refreshedAway` entirely would have left it green. Now `expect(away.reads, greaterThan(0))` |
| *"All eleven mutations chosen for the silent direction"* | **Nine of eleven.** Two loosen a write guard, which is the loud direction |
| The mutation driver: `AwayPeriod` is unmutated | Corrected in the same commit that made it false — this repo's own recurring failure mode, caught one commit later this time |
| `OPEN-QUESTIONS.md` #11: the Tap screen *"naming the writer"* | It renders `setByName`, which ADR-0003 says **cannot be authenticated**. The detection is *"somebody marked you away"*, not *"this person did"* — and the mitigation argument rested on the second |
| The threat model's T6: *"an 'ends tomorrow' notice goes to all watchers"* | Not built. `endsTomorrowOn` has a passing test and no caller anywhere |
| `WatcherCopy.awayUntil` / `awayUntilBy` docstrings | **Swapped**, each over the other's function, on the field this project treats as load-bearing for §17. The code was always right |
| `AwayOutcome`: *"Both end the same way. The SDK will deliver it."* | False for a write the server later **rejects** — rolled back after `queued` was reported, with nothing surfacing it |
| `LocalStore.open()` *"unguarded in both entry points"* | **Three**, and this phase routed a new nudge kind through the third |
| `selfAway()`: *"returns null when the pair cannot form a valid period"* | `tryCreate` guards ordering only; `DayKey.parse` throws on a malformed label. Unreachable today, and narrower than it read |

### Copy that claimed more than the device knows

**`AwayCopy.queued` said *"when this phone is back online"*** — reached purely from a six-second
timeout, so a slow server on a phone with five bars says it. `AwayOutcome`'s docstring spends a
paragraph refusing to say *"could not reach the server"*; this said the same thing in the affirmative,
one file away. Now *"as soon as this phone can send it"*.

**`notPermitted` claimed permanent loss of access** for what is as likely a shape violation —
reachable whenever the cached period is stale — and named no next step.

**`"Someone marked you away until Saturday 22"`** reached the elderly person's screen. `Someone` names
a role, which `guidelines.md` forbids, and it is ADR-0003's *"?? marked you away"* wearing a word. It
also made the approved unattributed line unreachable for anything this app writes. Suppressed at
render.

**A name with no `setBy` behind it rendered attributed.** It is not evidence anybody acted, and it is
the case that could put her **own** name in front of *"marked you away"*, because the
self-suppression guard keys on the uid the document lacks. Two of my tests pinned it; both corrected.

### Accessibility floors that were breached

- **The Away control fell below the fold** at the largest font scale, in the away state — the one
  control a person needs in order to act on reading that somebody marked them away. My test measured
  `getSize` of a widget entirely outside the viewport, so it **could not fail**; it also pumped the
  non-away state, where the tallest element is absent. Fixed with a visible scrollbar and a test that
  asserts reachability.
- **The picker's day cells were below 48dp** on any phone narrower than 392dp — `(width − 56) / 7`,
  because 16dp of scroll-view padding stacked on `CalendarDatePicker`'s own 12dp.
- **The AppBar ellipsized the title at scale 1.0**, cutting the word *last* — the entire reason the
  title is worded that way. `AppBar` also clamps text scaling at 1.34, which breaks the floor
  outright. The title moved into the scrolling body.
- **Write outcomes were silent to a screen reader** on both surfaces. A blind watcher pressed *"End
  Mum's away period"*, the write was refused, and they heard nothing.

### Smaller, and all real

`_run` had no `try`, so one throw disabled the away control for the session with nothing said;
`cancel('')` threw *outside* `send`'s catch, because the document path is built before `send` is
called. `setByName` was bounded on read and not on write, so an empty or 200-character display name
became `permission-denied`. A whitespace-only `setByName` passed the rules and rendered as
unattributed — ADR-0003 rule 2 defeated by three spaces. Both surfaces rendered the **stored**
`through` while deciding on the **clamped** one. And the outcome-to-sentence switch was written out
twice, once per screen, which is the defect `WatchedRowKind` was extracted to stop.

### What the reviewers confirmed

Worth recording, because it is most of what they looked at. The `AwayPeriod`/`AwayRecord` split is
**type-enforced rather than conventional** — a policy call site that reaches for the record does not
compile. `AwayRead` as a third sealed type is justified: `checkInDays` is not inert on this path, it
is the shape of *"she has not tapped"*. `AwayOutcome` having no unreachable state is sound. The
`watchedToday = decision.day.next` derivation holds at every watched-local midnight, because
`daysToDecide` cannot return an empty list. The rolling window still extends to `through` + 7 and
cancels as well as creates. Domain purity holds across all twenty files. The fan-out payload carries
nothing to decide from, skips the actor from a rules-enforced field, filters revoked links,
cross-checks the link id against its body, prunes only `UNREGISTERED`, and uses its own collapse key.
The write's field set matches `validAwayShape` exactly. No client can write a `setBy` that is not the
caller. `firestore.rules` was byte-identical to Phase 4 before this gate, and the region, mode and
Android build config are unchanged. **No new 2nd-gen API is required** — `onDocumentWritten` and
`onDocumentCreated` are the same Eventarc provider — and the four missing ones are unchanged.
`maxInstances: 10` is right for this trigger, and for a different reason than `redeemInvite`'s cap:
that one is a security control, this one is only a cost bound, and throttling is safe here precisely
because dropping every message changes no answer.

### Left open, deliberately

- **The five owed decisions in `screens.md`** — extending a period in force, the watcher row's
  confirmation, the silent success, the unnameable writer, and the spoken outcome strings.
- **`onAwayChanged`'s trigger wiring has never been executed by anything.** The fan-out is tested
  against the real emulated Firestore; the `onDocumentWritten` registration and the delete adapter
  (`after?.exists === true ? after.data() : undefined`) are not. That adapter is the **cancellation**
  path. `tools/functions-test.ps1`'s probe covers `onCheckInCreated` only. Owed: a third run.
- **An away *create* queued offline across two UTC midnights is dropped** — `awayNotRetroactive` is
  evaluated at commit time with one day of slack, and `from` is a literal composed on the device. The
  person has already read *"Saved"*. Narrow, and it is the collision of two deliberate decisions
  rather than a coding mistake, so it needs a call rather than a patch.
- **The Firestore error classifier is now written twice**, and `OPEN-QUESTIONS.md` #5 named one site.
  Both are recorded now; hoisting them into one classifier is the cheaper fix and is not done.
- **The migration test covers v5 → v6 only**, and compares `watcher_cache` columns rather than the
  whole `sqlite_master`. A future step that dropped an entire table would pass it.

---

## The device run — 2026-09-01, 10:37–11:45

**Every Phase 6 checklist row is ticked, first on two AVDs and then, for the OEM half, on the
POCO.** The full write-up, with the timeline and the exact figures, is in `testing/device-matrix.md`
under *The Phase 6 away run* and *…and then the POCO*; this is what it changes about the phase.

**The POCO refused every install for the first hour.** `INSTALL_FAILED_USER_RESTRICTED`, on
`adb install` and on `pm install` from `/data/local/tmp`, with the phone awake and unlocked and
`dumpsys user` reporting no restrictions at all — HyperOS's *Install via USB* developer toggle,
which **cannot be set over adb**. This page's old note that a retry works is now false; a retry did
not help, and no adb-side workaround exists. The owner turned the toggle on and the same APK
installed first try, so the run below is two AVDs (Android 16 / API 36 — Mum and a second AVD
created as Ana) **and then the handset**, signed in as a third person, Pop, watched by Ana.

**What the run establishes that no test could.**

- **`onAwayChanged` reaches a closed app, and the gate's `push_handler` fix is real.** Mum's app
  killed; Ana marked her away; the phone came back as a new pid and, still closed, wrote
  `self_away` and **re-armed its reminders around the new away period**. Had the missing `away:`
  argument still been there, the FCM reconcile would have decided from the cache the nudge came to
  replace and the alarms would not have moved.
- **The trigger's delete adapter ran on a real cancellation** — `cleared:true, parties:2, tokens:2`
  — and the fan-out skipped the setter's own device on the create (`skippedSelf:1`), which is the
  rules-enforced `setBy` doing what §17 needs it to do.
- **§17's surface exists on a phone**: *"Ana marked you away until Thursday 3."*
- **Cancelling produces both shapes**: a **delete** on the day the period starts, and — with the
  harness forcing tomorrow — a **truncation** that rewrites `through` and keeps the days already
  spent away covered.
- **Reminders stop on away days and resume at `through` + 7**, read from `dumpsys alarm` rather than
  from `pending_alarms`, both when the app drove it and when the background isolate did.
- **The accessibility fixes hold on a device**: at `font_scale 2.0` the picker's title wraps instead
  of ellipsizing and both actions are reachable; at a forced **360dp** width the day cells measure
  **exactly 48dp**, the floor that used to be breached below 392dp.
- **The v5 → v6 migration passes on a real store** — built from `b79a7b6`, paired, upgraded in
  place: version 5 → 6, the two new columns added and already populated, every row intact.

**And it found something the tests are structurally unable to see.** An away period set **offline**
is reported *"Saved."* and then reaches nothing on the setter's own phone: `self_away` stays empty,
the away line does not appear, the control still reads *"I'm away"*, and the reminders for the away
days stay armed — until an unrelated reconcile happens to run. The watched side takes its away row
from a read-back, and the nudge that corrects every *other* device is deliberately not sent to the
setter, so the one phone certain not to be told is the one that wrote it. On the plane §8 names, it
goes on reminding her through the period she was just told was saved. **It needs a decision, not a
patch** — it is two deliberate choices colliding, and it lands on the owed decision about a write
that says nothing when it succeeds.

Two smaller things: the picker title says *"the last day **you** are away"* on the **watcher's**
phone, where she is choosing for somebody else; and `invite_service.dart` has **no client-side
timeout** at all, unlike `AwayRepository`, so the pairing screens spin on the SDK's 60-second default
with nothing said.

**What the POCO added, once it would take a build.** The OEM doubts were the reason to want it, and
none of them materialised at stock power settings: reminders armed **21 / 21** around an away period
(1–7 Sep → 5–11 Sep → back to 1–7 Sep after a cancellation), nothing trimmed by the vendor; and the
**closed-app nudge works in both directions on HyperOS** — app killed with `pidof` empty, then a
cancellation and later a creation each woke a new process, rewrote `self_away` and re-armed the
alarms without the app being opened. Then *"Ana marked you away until Thursday 3."* on the handset
itself, which is where §17's mitigation has to be read. Two smaller confirmations: the code expiry
rendered in **24-hour** format because the phone is set that way, and at 392.7dp the picker's day
cells measure **52.6dp**. Doze is still unmeasured, and away across a real period boundary still
needs a phone to sit offline overnight.

---

## Still owed

**The device run is done**, above, except for what a session cannot drive and what the POCO cannot
answer:

1. **Doze on the POCO.** The phone ran the away rows at stock power settings, screen on; nothing was
   measured with it idle overnight, and this project's own notes say `deviceidle force-idle` will
   not reach deep idle on this device from a screen-off state. That is the one OEM question the run
   did not close.
2. ~~The third exit criterion cannot be driven in a session.~~ **Driven 2026-09-01, in eleven
   minutes.** Aeroplane mode on the POCO for the whole run and the harness walking the clock: away
   on the last away day, **ended on the first day back**, with every Firestore read refused
   (`UNAVAILABLE`) rather than skipped, the cached row surviving the period's end, and the reminders
   armed again on the right day. The harness is the reason this cost minutes instead of days, which
   is the argument PLAN.md made for building it beside the first alarm. **All three exit criteria
   are now met on devices.** The *watcher's* half of the same clause — offline across the boundary,
   warning again on the first day back — is covered in the test file and on no device.

**The reviewers have run** — all five, one at a time, 2026-08-27, and every finding was applied; the
section above is what they found. *(This paragraph said "the reviewers have not run" until
2026-09-01. It was written before the gate and left standing after it, in the document whose own
subject is claims that stop being true. Corrected during the device run.)*

**Copy approval.** The picker and refusal strings are **drafted, not approved** — listed in
`screens.md` under *Away picker → Copy* so approval has something to read. Two of them reuse
already-approved sentences verbatim rather than inventing siblings. The device run adds one concrete
observation to that list: the picker title addresses the wrong person on the watcher's phone.

**The four away transition notifications.** §12's table and `testing/strategy.md`'s must-cover list
both name them — *"Ana marked Mum away until Sat 22 Aug"*, the cancellation notice, and the locally
scheduled *"ends tomorrow"*. They are **not built**. PLAN.md's Phase 6 deliverable list does not name
them, and `onAwayChanged` is useful without them — the nudge drives a reconcile, which updates both
surfaces silently and correctly, and that is what the exit criteria turn on. They are the natural
next increment and are recorded here rather than left to be discovered.

**Carried unchanged from Phase 4 and 5:** the first Functions deploy, App Check's console half, the
live-radio measurement, ADR-0008 option 1's cost, `Home.build`'s hang, and `InviteCode.forSpeaking`.

---

## What to watch out for next

**Away is the first feature here whose failure mode is silence**, and that does not stop being true
now that it is built. The tests are deliberately built around **ending** rather than starting, and
the mutations are chosen for the silent direction. Anything that changes `AwayPeriod.covers`,
`hasExpiredOn`, `cancelOn`, or the gate on replacing the away cache should be read as a change to
whether a family hears anything at all for up to 31 days.

**§12 has now been built against.** The brief predicted that §12 itself was this phase's most likely
source of a claim that had stopped being true — written against for six phases and built against for
none. It largely held up; what needed correcting was `screens.md`'s *"Phase 6, not Phase 3"* markers
and the mutation driver's own coverage claim, both updated here.

**The watcher's away write is the reachable half of `OPEN-QUESTIONS.md` #11.** A guessed link can now
set an away period from a screen rather than only from an API call. The register is updated: the
mitigation also got its first surface on the watched side in the same change, which is the half that
was missing.
