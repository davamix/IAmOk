# Phase 6 — Away mode · summary

**Date:** 2026-08-27 · **Status:** Built and tested against the emulator suite. **Not yet signed
off** — the reviewers have not run, and nothing here has been on a handset.

Start from [phase-6-brief.md](phase-6-brief.md) for what this phase was asked to do. This file is
what happened.

---

## The one-line story

Away had been designed into this app since Phase 1 and deliberately built up to — the domain type,
the rules, the `self_away` table and the `away` parameter on every policy all existed before this
phase started. What was missing was everything that makes it reachable by a person: a client write
path, the fifth Function, the picker, and any accessor for the table that had sat in the schema for
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
| `onAwayChanged` | The **fifth** Function. `onDocumentWritten`, fans out to every party, skips whoever acted |
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

`away_repository.dart` became reachable from both background entry points the moment the watched
reconcile started reading Firestore, and `domain_purity_test.dart` failed until it was declared. That
is exactly what that guard is for, and it found it before a review did.

### The exhaustive switch caught the missing row branch

Adding `WatchedRowKind.away` broke `watcher_screen.dart`'s build until the branch was written — which
is what `rowKind`'s docstring says it exists to do, having been written out twice once before with
nothing keeping the copies in step.

---

## Mutation testing

`AwayPeriod` had been on `mutate-dart.mjs`'s *"not mutated"* list for five phases, as a type nothing
read. The brief called its becoming live code *"a good moment to extend them"*, and that is done:
**eleven** new Dart mutations across `AwayPeriod`, `AwayRules`, `AwayRecord` and the watched
reconcile's away half, chosen for the direction that produces **no notification and no error**.

The driver's header no longer claims `AwayPeriod` is unmutated — that claim would have been false in
the commit that made it false, which is this repo's own recurring failure mode.

**Results, 2026-08-27: 25 mutations, 25 caught, 0 survived, 0 `DID NOT COMPILE`**, with **eight**
passing no-op controls — one per file, and each has to pass before anything in that group is scored.
That is the number *with* the compile gate the Phase 5 gate review added, which is the only version
of it worth quoting.

**All eleven new away mutations were caught**, including the four that matter most, each of which
produces silence rather than an error:

| Mutation | What it would cost |
|---|---|
| `covers`: `through` stops being inclusive | She is reminded three times on an away day, and every watcher is warned about it the next morning |
| `covers`: reads the document instead of the clamp | A ten-year away document is honoured for ten years, and **nothing can catch it** — the read succeeds every day, so nothing is stale |
| `hasExpiredOn`: off by one | The period outlives itself. This is the arithmetic the third exit criterion *is* |
| `cancelOn`: deletes rather than truncates | Days already spent away are retroactively un-covered, and the next device to refresh warns about one of them |

**The source was restored and the suite re-run afterwards** — `git diff lib/` is empty and 1 322
tests pass. That check is here because the Phase 5 gate found a **mutated build sitting in the tree**
with `git status` clean, and the runner now restores *and* rebuilds rather than only restoring.

---

## Verification

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | **1 322 passing** (1 202 at the start of the phase) |
| Functions | **102 passing** (83 before) — the runner globs `test/*.test.js`, and its own count is what says the new suite ran |
| `tsc --noEmit` | clean, at the pinned Node 22 types |
| Rules | untouched this phase; the away rules and their 27 tests were written in Phase 4 |
| Dart mutations | **25 caught, 0 survived, 0 did not compile**, 8 passing controls |
| Debug APK | *(owed — see below)* |
| Device | **nothing in this phase has been on a handset** |

---

## Still owed

**The device run.** Nothing here has run on a phone. The brief's own first instruction is still
outstanding and is now joined by this phase's:

1. **Press *Add someone*, take the second option, and confirm a warning alarm actually arms** — the
   Phase 5 gate defect that only a device proves.
2. Set away from the Tap screen; confirm reminders stop and the picker's labels read correctly at the
   largest font scale.
3. Set away from a **watcher's** phone; confirm the watched device's Tap screen names the watcher.
4. Cancel from either side; confirm both sides restore.
5. The third exit criterion **cannot be driven in a session** — it needs a device to sit offline
   across a period boundary. The arithmetic is asserted in tests; what a device would add is
   confidence that nothing else expires the cache.

**The reviewers have not run.** All five are owed at the gate: architecture (a new domain type, a new
repository, a background-closure change), security (a new client write path against the rules, and a
Function), UI/UX (a new screen and new copy), testing, infrastructure (the fifth Function, and a
schema migration).

**Copy approval.** The picker and refusal strings are **drafted, not approved** — listed in
`screens.md` under *Away picker → Copy* so approval has something to read. Two of them reuse
already-approved sentences verbatim rather than inventing siblings.

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
