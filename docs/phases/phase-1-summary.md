# Phase 1 — Domain layer · summary

**Date:** 2026-08-16 · **Status:** Complete and reviewed, awaiting owner review · **Next:** Phase 2,
watched side on real hardware

The specification, expressed as testable code. 14 files under `lib/domain/` and 15 test files,
**328 tests**. **No Flutter widgets, no Firebase, no sqflite, no platform edge, no `LocalStore`,
no `AlarmScheduler`, no UI.** `lib/main.dart` is still the stock Flutter counter scaffold,
untouched.

One new decision record came out of this phase:
**[ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md) — "reached and refused"
is not "could not reach"**, which amends §10, §13 and §17. See *Review* below.

---

## What was built

| Component | File | Is |
|---|---|---|
| `DayKey` | `time/day_key.dart` | A calendar day as a *label*, not an instant. Arithmetic moves in UTC so a day is always exactly one day; only `startOfDay` and `at` touch a zone. `lastCompletedDay(now, zone)` is §10 step 1. |
| `LocalTimeOfDay` | `time/local_time_of_day.dart` | `HH:mm` with no date and no zone — the three reminder slots and `link.warningLocalTime`. |
| `TimeZones` | `time/time_zones.dart` | IANA lookup over the compiled-in database. See decision 3. |
| `AwayPeriod` | `away/away_period.dart` | `from`/`through` (inclusive), containment, arithmetic expiry, and ADR-0001's `cancelOn`. |
| `AwayRules` | `away/away_period.dart` | §8's **period** validation group, with named rejections. |
| `Link` `CheckIn` `WatchStatus` | `entities/` | Deterministic link id, the device-clock day id, and the watcher-row derivation. |
| `ReminderPolicy` | `policy/reminder_policy.dart` | Which of 12/18/21 should exist for a day. |
| `WarningPolicy` | `policy/warning_policy.dart` | §10 as amended by ADR-0001 and ADR-0004. **Four** warning outcomes and a named `SilenceReason`. |
| `FirestoreRead` `WatcherCache` | `reconcile/` | Tier 1's result as a sealed type; tier 3 as an immutable value with `applyRead`. |
| `WatchedReconciler` `WatcherReconciler` | `reconcile/` | The two desired-state calculators. |

Two dependencies added: `timezone: ^0.11.1` and dev-only `test: ^1.31.1`.

---

## The three decisions you asked me to flag

### 1. `Clock` — Phase 1 defines no port, and should not

**Decision: the policies take explicit values. No `Clock` interface exists in the domain layer.**

ARCHITECTURE.md §5 and §6 both place `Clock` at the **Platform edge**, and ADR-0002 decision 1 says
in terms that "the domain layer still takes `now` as an explicit parameter and never reads a
clock". A port defined *in* `domain/` would be a dependency-inversion seam with no domain consumer:
nothing in this layer ever *calls* a clock, it only receives `DateTime now`. Defining the interface
here would also contradict §5's own diagram, which is the kind of quiet divergence that needs an
ADR rather than an import.

So every policy and both reconcilers take `required DateTime now`. `Clock` gets written in Phase 2,
at the edge, where it is read once per entry point and passed down.

### 2. Test framework — yes, a pubspec change

`docs/testing/strategy.md` requires plain `test` for domain tests, so `test: ^1.31.1` is now a dev
dependency alongside `flutter_test`. No conflict; the domain suite imports `package:test/test.dart`
and **nothing** imports `flutter_test`. They still run under `flutter test`, which is what the exit
criterion names. `test/widget_test.dart` (the stock scaffold test) still uses `flutter_test`, which
is correct for a widget test.

### 3. ADR-0002's open assumption — CONFIRMED, with a condition the ADR did not state

`package:timezone` 0.11.1 is pure Dart and needs no plugin registrant. Four checks, the last being
the one that settles it:

- no `flutter:` section in its pubspec and no dependency on `flutter` — a plain Dart package, not a
  Flutter plugin;
- no `android/` or `ios/` directory, and no `package:flutter` or `MethodChannel` anywhere in `lib/`;
- adding it generated no `.flutter-plugins-dependencies` file;
- **after a full `flutter build apk --debug`, `GeneratedPluginRegistrant.java` contains zero
  registrations.** There is no registrant that could be missing.

**The condition:** purity is a property of the *entry point*, not of the package. Only
`timezone/timezone.dart` and `timezone/data/latest.dart` are pure — the database is a compiled-in
`dart:typed_data` blob. `timezone/standalone.dart` imports `dart:io` and `dart:isolate` and reads
tzdata from a **file**; `timezone/browser.dart` pulls `package:http`. Importing `standalone.dart`
would put `dart:io` on the alarm path and silently re-open the failure ADR-0002 closed. Both are
banned by name in `test/domain/domain_purity_test.dart`, so this fails the build rather than
relying on anyone remembering.

Recorded in [ADR-0002](../architecture/decisions/0002-clock-split.md), whose "Rests on one
assumption" paragraph is now closed and dated, and in `pubspec.yaml` next to the dependency.

---

## What else was decided, and why

**The tz database initialises inside the domain layer.** `TimeZones.ensureInitialized()` is called
lazily by `TimeZones.location()`. It parses a compiled-in byte blob — no plugin, no I/O — so it
breaks no purity rule. The alternative is bootstrapping at an app-startup edge, and **the alarm
isolate never runs app startup**: it would throw at `getLocation`, the warning would never fire, and
silence is the one failure this app cannot detect in itself. The `_initialized` flag is a per-isolate
memo and is deliberately the only mutable static in the layer.

**`WarningPolicy` takes scalars, not the cache object.** ADR-0001's ordering is "refresh, then
decide", and the two steps are separate functions — `WatcherCache.applyRead` and
`WarningPolicy.decide` — composed by `WatcherReconciler`. Keeping the policy's inputs as explicit
scalars means it cannot re-read a stale value by accident, and the composition is what the 18-case
model port exercises.

**A named `SilenceReason`, not a bare "silent".** The testing strategy says assert the silent cases
as hard as the firing ones. A test asserting only "it was silent" passes just as happily against a
policy silent about everything. The enum lets tests assert *which rule* produced the silence — which
is what makes the "evidence outranks doubt" ordering (ADR-0001 decision 4) testable at all, since it
and the away branch both produce silence for different reasons.

**`shouldNotify` is separate from `decision.isWarning`.** The decision answers §10's question
("should this day be warned about"), which stays true on every later reconcile of the same day. The
reconciler answers the idempotence question. Without the split, opening the app would re-notify.

**Corrections match the warned day exactly.** Not "every standing warning at or below
`lastConfirmedDay`" — a missed Monday followed by a tapped Tuesday would satisfy that and retract a
warning that was **true**. Only a check-in for the warned day itself disproves it. Tested.

**Away attribution is not in `AwayPeriod`.** §5 scopes the type to "from/through, containment,
validity". ADR-0003's `setBy`/`setByName` are document metadata for display and for the rules, not
inputs to any decision, so they land with away mode in Phase 6. `AwayRules` now says explicitly that
it implements one of §8's two validation groups.

**The cap is 31 days, and the prose was corrected to the arithmetic.** Investigating the apparent
§8-vs-§12 conflict showed there was no conflict among the *calculations*: every arithmetic site in
the project — §8, the rules guidelines, `AwayRules`, the tests, the security skill and reviewer —
has always said `+ 30` **days ahead**, which is a 31-day period. Only prose said "30 days", in nine
places. The Phase 0 review audited this exact line and still missed it, because it was correcting
the *anchor* (`from` → `request.time`) and both forms yield 31; the count was never in question, so
nobody counted. Owner's ruling: the number is just where the limit was put, nothing derives from it,
so the prose moved. `AwayRules.maxLengthInDays` now states it, and the test asserts the **length**
rather than only the boundary.

Two things that are wrong regardless of the number, now recorded in
`security/firestore-rules-guidelines.md` for Phase 6:

- **`request.time + 30d` is not calendar arithmetic.** Adding 720 hours to an instant lands on
  day + 29, + 30 or + 31 depending on the time of day and whether a DST transition falls inside the
  window — verified, not reasoned.
- **The rules cannot enforce the cap at all.** `through` is a date in the watched person's zone;
  `request.time` is UTC and the rules engine has no timezone conversion. For a watched person in
  Auckland a UTC-derived bound rejects writes that are legitimately inside the cap.

Both point the same way, and the resolution is now settled: **the rules clause is `+32d`,
deliberately slack**, biased so it can never reject a legitimate write (a rejected away write queues
offline and resurfaces hours later with no visible cause). The exact check is `AwayRules`, handed a
`today` already resolved in the watched person's zone. **Travel is not the cause and needs no
special handling** — the mismatch bites a watched person who never leaves their house.

**And the absurd case is now defended twice, because the rules alone could not do it.** They bound
what can be *written*; they do not bound what a device may *read*, and ADR-0001 says a read that
succeeds is trusted. A ten-year away document arriving any other way — written before the rules were
deployed, admitted by a rules-deploy mistake, or produced by a buggy client — would have silenced
that family for a decade, and **the staleness bound could not have saved them**: nothing is stale,
the read works perfectly every day and returns the same absurd answer. Verified as a real gap before
fixing it — `tryCreate` accepted a 3 654-day period and `covers()` returned true for 2035.

`AwayPeriod.clampedToSanityBound()` now bounds what may be *honoured*. It clamps rather than
discards, so the days a family really did mark away stay covered and no false *"she didn't check
in"* is produced for them; past the bound the ordinary decision resumes and the app speaks.

**Two things about it were wrong in the first version, and review caught both.**

*It was sized to the cap*, at 31 days. But the Firestore rules are deliberately slack at `+32d` —
they have to be — so they legitimately admit periods of up to ~34 local days. A read-time bound at
the exact cap therefore un-honours periods the server accepted and tells a family *"No check-in from
Mum yesterday"* for days they really did mark away: a rare absurd-document failure traded for a
routine false claim. The bound is now **60 days** and answers a different question — *can this
possibly be real?* — with `AwayRules` keeping the exact number.

*It was applied at one of three places* that honour an away period. `ReminderPolicy` and
`WatchStatus` were left raw, which produces the worst state of all: a ten-year document suppresses
the watched person's own reminders for a decade, so she is never nudged to tap, while the clamped
watcher side warns her family every day. Worse, `WatchedReconciler` derives its window end from
`through` directly and `DayKey.through()` materialises the span — **2 912 222 `DayKey` allocations
on the alarm path**, measured, from a value the test suite already constructs one file away. Fixed by
inverting the default: `covers()` is now the *clamped* predicate and `coversAsStored()` the explicit
raw one, so a caller is safe without having to remember. A predicate whose misuse silences a family
should not depend on every future author thinking about it.

Three bounds now exist deliberately, tabulated in the rules guidelines: the **cap** (31 days, exact,
client-side), the **rules clause** (`+32d`, slack, server-side), and the **sanity bound** (60 days,
on read).

**The access-lost reminder cadence is decided: day 0, 1, 3, then every seventh day, indefinitely.**
The UI review flagged the original daily behaviour as fatigue on the one channel that must not be
trained away. My first fix — notify once, on the transition — was the *more* dangerous extreme:
one swipe on a bus converts a fixable fault into permanent silence, and the surfaces holding the
condition afterwards (health panel, list row) only reach a watcher who opens the app, which §13
argues this watcher does not. Day 1 catches the swipe while the fault is freshest and most fixable;
the weekly heartbeat never stops, on the same reasoning as §12's away cap.

Two consequences fell out and are implemented: `accessLostNotifiedOn` dedupes within the day,
because `reconcile()` runs on app open, FCM, alarm and boot and would otherwise fire four times on a
reminder day; and a **changed cause** re-notifies regardless of cadence, since "sign in again" and
"update the app" are different instructions. There is deliberately **no "access restored"**
notification — quiet confirm, loud miss, the same shape as §12's absent "away finished" message.

**And the first implementation of the cadence was wrong in a way only the test review caught.** It
asked *"is today a milestone day"* rather than *"has a milestone passed unserved"*. Miss the day-7
wake-up and the next reminder is day 14; miss 7, 14 and 21 — routine on the HyperOS handset the
device matrix is built around **precisely because it kills background work** — and the app is
permanently silent after day 3. The 22-day simulation could not see it, because it reconciled every
single day: the one traffic pattern under which the two questions are indistinguishable, and the one
this project exists because it cannot assume. Now `isAccessLostReminderDue` takes the gap since the
last reminder as well, so a device waking late is served late rather than skipped, and the
simulation takes an `awakeOn` set.

Three more from the same round: a refusal now anchors the state on **any** `ReadRefused` rather than
only when the decision is `warnAccessLost` — §13's health item is defined as "the last reconcile was
refused", a fact about the *read*, so a refusal on a day already settled by a check-in left the panel
green while every read was failing. A **flapping cause** — `permissionDenied` and `unauthenticated`
can alternate around a token refresh — is now bounded to one notification a day rather than one per
reconcile. And `cancelAccessLostNotice` exists at all: there is no "access restored" *message*, but
*not notifying* and *not cancelling* are different decisions, and only the first had been made — the
tray kept telling a watcher to fix something already fixed.

Left open for Phase 3, and recorded in `screens.md`: a reminder that lands while the watcher already
has the app open should be suppressed. Reconcile runs on app open, so a cadence day can post a
notification to someone looking at the screen.

The **anchor** remains `request.time`, not `from`, as the Phase 0 review established: identical
while `from` is always today, divergent the moment future-dated away is exposed. A test asserts that
a *short* future-dated period is still rejected, which a `from + 30` rule would allow.

---

## Review, and what it changed

Four reviewers ran to completion over three rounds: `architecture-reviewer` three times,
`testing-reviewer` twice, `uiux-reviewer` and `security-reviewer` once each.
`infrastructure-reviewer` was not run — this phase touches no Firebase configuration and no part of
the Android build.

**Between them they found twenty-six defects. All are fixed.** Three of them were introduced by
earlier rounds *while fixing something else*, which is the honest summary of this phase: the raw
first draft shipped three separate ways of telling a family something untrue, and two of the repairs
for those shipped a fourth and a fifth. The reviewers are the reason none of it survives.

### Round one — architecture

**1. A revoked link kept warning — and would have claimed the phone was offline.** `reconcile()`
took the whole `Link` and never read `status`. Worse than it first sounds: §8 gates the `checkins`
read on an accepted link, so after revocation every read returns permission-denied — a **failed**
read — so the alarm fell through to `warnOffline` and would have said *"No check-in received from
Mum yesterday — your phone has been offline since HH:MM"*, daily, about someone the watcher
deliberately stopped watching. Two false claims in one notification, in the category §10 rates as
the worst possible bug.

**Pulling that thread found the real defect, and it was a category rather than a case — ADR-0004.**
`WarningPolicy.decide` took `required bool readSucceeded`, collapsing a five-value failure enum to
one bit, and the code documented the collapse as intentional. ADR-0001's rule that "a failed read is
not an answer" is correct **for cache retention**, where the cause is irrelevant; I over-applied it
to **message selection**, where the cause decides which sentence is true. With one bit available,
every failure produced the offline wording — and that wording is a false claim about the device
whenever the server was actually *reached* and said no. The same false sentence is produced by App
Check rejection, an expired token, account deletion, and **a bad `firestore.rules` deploy, which
would tell every watcher in every family simultaneously that their phone was offline and their
relative might be in trouble.**

Chasing it surfaced a second instance in a layer not yet written: **Firestore's offline persistence
is on by default and `get()` does not throw when offline — it serves the local cache.** A naive
Phase 4 implementation would build a *successful* read from a cache hit, stamp `lastReconcileAt`,
and reset ADR-0001's two-day staleness bound on every reconcile. A device offline for a month would
"verify" thirty times and a cached away would silence the watcher indefinitely — the exact wrongful
silence ADR-0001 exists to prevent, re-entering through a different door. Both faults are the same
mistake: **treating "I got bytes" as "I verified."**

Fixed as ADR-0004, in four parts:

- `FirestoreRead` is now a sealed `ReadSucceeded` / `ReadUnreachable` / `ReadRefused`, and the policy
  takes a narrowed `Verification` rather than a bool — a sealed type is the remedy for a mistake
  made *while holding the correct rule in mind*, because it makes flattening a compile error.
- A fourth outcome, `warnAccessLost`. It claims nothing about the watched person, nothing false
  about the device, and is the only one of the four the reader can **act on**. (The copy went
  through the UI review below and changed; the approved strings are in `screens.md`.)
- Refusal dominates the away branch but **not** positive evidence, so the order is
  `revoked → activeFrom → check-in recorded → refused → cached away → warn`.
- The reminder repeats on a **decaying cadence** — day 0, 1, 3, then weekly, indefinitely. See below.
- Phase 4's error mapping is constrained now: `permission-denied`/`unauthenticated` → refused,
  `unavailable`/`deadline-exceeded` → unreachable, and **`isFromCache == true` is never success**.

§10, §13 and §17 amended accordingly. Revocation itself is handled locally and earlier, so the
commonest cause of a refusal never reaches the refused branch at all.

**2. Alarm identity excluded the instant, so `reconcile()` could not repair a timezone or
warning-time change.** `ScheduledReminder` compared `(day, slot)` and `ScheduledWarning` compared
`(day)`, ignoring `at`. Since every diff is a set difference, a moved instant was invisible: a
watched person flying Madrid → New York produced an empty diff, `isNoOp` reported **true**, and the
reminders went on firing at 06:00 local. A watcher changing `warningLocalTime` from 10:00 to 08:00
produced no change for a week. §3 names "timezone change" as one of the seven cases the single
`reconcile()` is supposed to collapse, and ADR-0002 accepts a stale cached zone precisely on the
grounds that the worst case is one boundary day — a promise only kept if the diff notices. My
original justification (avoiding churn) was wrong: `at` is a pure function of `(day, slot, zone)`,
so it differs *only* when the zone or time genuinely changed, which is exactly when churn is wanted.
Fixed on both types, with regression tests at the policy and reconciler level.

**3. `WatcherReconciler.reconcile()` only ever created.** It returned `warningsToCancel: const {}`,
while its own sibling class carries the comment "a window that only ever creates leaves reminders
armed through a holiday". Mitigated by a second entry point, `reconcileWithScheduled` — but the
shorter, default-looking method was the unsafe one, and it is what a Phase 3 caller would reach for.
Collapsed into a single `reconcile()` with `currentlyScheduled` **required, not defaulted**, so the
create-only path can only be chosen deliberately. I had independently spotted this before the review
returned.

Also fixed: `AwayRules`' doc comment claimed to implement §8's away rules when it implements one of
two groups; `WarningPolicy` re-derived §10 step 1 inline instead of calling `lastCompletedDay`; and
the purity guard had **four holes** — it matched only single-quoted `import`, so double quotes,
conditional imports (`if (dart.library.io)`, the classic route for `dart:io`) and deferred imports
all slipped past, and `export` was not checked at all, which matters because `domain.dart` is a
barrel. All closed. The guard's substring matching is a lint rather than a proof and now says so;
the import allowlist is the half that fails closed.

Not acted on, deliberately: a future-dated away period would build one contiguous
`today..through+7` span and arm ~80 reminders. It matches §10's literal wording and is unreachable
while §12 pins `from` to today. Recorded here rather than fixed speculatively.

### Round two — the fix for finding 1 had introduced a new false claim

**4. `warnAccessLost` was written into `warningsShownFor`, so the watcher's list row reported a
missed check-in.** `WatchStatus.derive` reads that set and nothing else to decide
`WatchState.warned` / `needsAttention`. So an App Check rejection, an expired token or a bad rules
deploy produced the honest *notification* — and a list row saying Mum had missed a day. **The exact
claim ADR-0004 exists to prevent, arriving by the surface ADR-0004 did not look at.** Worse, on
restoration a check-in for `D` would emit a *correction*, retracting a message that had never
claimed anything about her. Fixed: access loss lives in `accessLostSince` / `accessLostCause`,
`warningsShownFor` is reserved for claims about the watched person, and `WatchState` gains
`accessLost` and `revoked`.

**5. A changed outcome could never replace a standing notification.** `shouldNotify` keyed on the
day alone. Before ADR-0004 that was harmless — one day, one outcome. With four reachable for the
same `D`, a 10:00 alarm that could not reach the server, followed by an 11:00 app-open that verified
the day and found no check-in, left the family reading *"your phone has been offline"* while the
device had since established the real thing. `warningsShownFor` is now a map of day → **which**
message is standing.

Implementing that naively introduced the mirror bug, which the tests caught: replacing on *any*
change also walks a verified *"No check-in from Mum yesterday"* **back** to a weaker hedge on the
next failed read. Only an upgrade supersedes.

**6. Revocation cancelled the alarm but left the standing warning in the tray forever.** Nothing
clears it — every read after revocation is refused, so no correction can ever run — and
`WatchStatus` reported `needsAttention` about someone no longer watched. The existing test looked
like it covered this and was vacuous: the input cache was empty. Added `withdrawnWarnings`, a
channel distinct from `corrections` because nothing here *disproves* the warning; *"Mum did check in
yesterday"* would be a claim the device cannot support.

**7. A backwards clock jump silenced the watcher indefinitely.** `today.differenceInDays(verifiedOn)
<= 2` passes on a *negative* number, so a device whose clock moved back treated a reconcile "verified
in the future" as fresh. §11's rule is that skew is surfaced, never silently trusted. One clause.

**8. The purity guard had a route for the entire Data layer.** Relative imports were skipped
(`import '../../data/local_store.dart'` has no colon), and the banned-substring pass only reads
files under `lib/domain` — so a Data-layer import would have gone unexamined, past a guard whose
whole purpose is to stop it. Now every relative import is resolved and asserted to land back inside
`lib/domain/`. Also added: `Future`/`Stream`/`async`/`await` (exported by `dart:core`, so no import
exists to catch), `DateTime.parse(`, and a check that `DateTime` is only ever constructed as
`.utc(`. The keyword bans needed word boundaries — a substring ban on `await` fires on
`awaitingCheckIn`, which is how the new check first failed.

**9. `previousAway` was being destroyed.** `applyRead` overwrites `away` wholesale, so nothing above
it could tell a *cancelled* away from an *expired* one — a distinction §12 gives different messages.
"Deferred to Phase 6" was wrong, because by Phase 6 the evidence is gone: the edge would have had to
re-read the cache before `applyRead`, i.e. keep a second source of truth for away state exactly
where ADR-0001 says there must not be one. The result now carries it; classifying it stays Phase 6.

**10. `Link.watchedZone` could throw inside an alarm isolate** with no non-throwing counterpart,
unlike `AwayPeriod.tryCreate` which exists for precisely that reason. One unrecognised zone string —
a device alias, or a zone newer than the pinned tzdata — means a permanently silent watcher. Added
`tryWatchedZone`.

**11. The `toCancel`-before-`toSchedule` contract was on the wrong type.** Documented on
`ScheduledReminder`/`ScheduledWarning`; the type a caller actually holds is the *result*. Moved
there, and added `warningsToReschedule` so the trap is visible in autocomplete and assertable rather
than living in prose.

### Round two — tests

**12. The 18-case model port asserted no `SilenceReason` at all** — the one file where it matters
most. Eight of the eighteen expect silence, and every one would have passed against a policy silent
about everything. S4 (before `activeFrom`) and S15 (the ADR-0001 "a failed read is not an answer"
trap) were both in that set. All eight now name the rule.

**13. Three adjacent orderings were unpinned** — `revoked ↔ activeFrom`, `revoked ↔ checkInRecorded`,
`activeFrom ↔ checkInRecorded`. All silent-vs-silent, so nothing observable changed at the policy
boundary — but ADR-0004 keys a health-panel item on the reason. Three one-line cases. The two
orderings ADR-0004 actually argues about were already pinned twice each, in two independent files.

**14. Four tautological tests**, all replaced: a loop whose variable was never used; an assertion
that a pure function of two constants is deterministic; an `isNot` that followed from the line above
it; and a property test that could not fail because the constructor throws before reaching it.

**15. DST coverage stopped at `DayKey`** — no reconciler window ever spanned a transition, and the
EU/US out-of-step week (when Madrid↔New York is 5 hours, not 6) was never exercised despite
`newYork` existing in the fixtures for exactly that. Both added.

**16. Nothing ran the model inside `flutter test`.** Its `superseded: 4 / decided: 0` invariant — the
ADR-0001 regression guard — only ran when a human typed the command. `test/domain/model_regression_test.dart`
now runs it. This is the same shape as the Phase 0 finding about the secrets script: *a rule with no
assertion is a rule nobody notices losing.*

### Round two — copy

**17. The proposed `warnAccessLost` string implied a claim about Mum.** *"Last confirmed Saturday 15
August"* reads as *she has not checked in for five days*; `lastConfirmedDay` is the newest check-in
**this phone managed to read**, and during a refusal she may be tapping daily. The words claimed
nothing, the reading did. Now *"Your phone last saw a check-in on…"*.

Also from that review: *"Open I Am Ok"* parses for a beat as *"Open — I am OK"*, the opposite of the
message; it is now *"Open the app to see what to do."* The message dropped the `away` period it
already carries, so a watcher whose relative is provably marked away would phone Portugal at 08:00 —
there is now a variant for it. And **two of the three already-approved strings interpolate a
nullable the domain proves reachable**: a device that has never reconciled would render *"offline
since null"*. All variants are in `screens.md`, and both skills that describe the copy were still
saying there were two outcomes.

### Round three — the repairs had their own defects

Detailed above rather than repeated here: the **sanity bound was sized to the cap** (security
review), the **clamp was applied at one of three call sites** and left an unbounded allocation on the
alarm path (architecture *and* testing review, independently), and the **cadence asked the wrong
question**, going permanently silent on exactly the hardware this project targets (testing review).

Five smaller ones from the same round, all fixed: `isNoOp` ignored `withdrawnWarnings` and the new
cancellation, so a Phase 3 caller doing `if (isNoOp) return;` would leave a notification standing; a
backwards clock could silence the cadence permanently, the mirror of a hazard `WarningPolicy`
already defended; `applyRead` cleared the three access-lost fields *implicitly* with no test, so the
obvious refactor to `copyWith` would have silently stopped clearing them; the retention loop that
was supposed to prove a failed read changes nothing built its fixture with those fields null, so it
proved nothing about them; and two code comments still argued for the transition-only cadence that
ADR-0004 had replaced twenty lines above.

Also corrected: three documents Phase 4 will read to write the rules tests listed **"31 days"
among the DENIED cases** — fallout from the 30→31 count change. Written as specified, that test
asserts a legitimate maximum-length away period is rejected, and the natural "fix" is to tighten the
rules until it is.

**Security review's verdict on the widened clause**, since it was the thing most worth challenging:
`+32d` is *not* a weakened control, because the clause was never the control — T6 already accepts
that any group member can silence the family, and the cap is re-settable in one extra write, so the
marginal cost to an adversary of 30 versus 32 is zero. What it defends is the absurd case, which 30
and 32 defend identically. Two days is the right amount: one is the boundary with no margin, three
buys nothing. Secrets were verified clean independently of the guard script, and surfacing
`RefusedCause` to the user leaks nothing — the distinction is read off gRPC status codes any caller
already sees.

---

## Deferred, deliberately

Everything below is on `docs/testing/strategy.md`'s mandatory list and is **not** testable as pure
domain logic yet — each needs a layer Phase 1 deliberately does not build.

| Deferred | Needs | Phase |
|---|---|---|
| Permissions → health derivation | a permission model | 2 / 7 |
| `LocalStore` round-trips | sqflite | 2 |
| Away transition notifications, "ends tomorrow" | notification service + away mode | 6 |
| Cancelled vs expired away messaging | the cache diff, at the edge | 6 |
| Away attribution (`setBy` / `setByName`) | the away document | 6 (rules 4) |
| `redeemInvite` cases | the callable | 5 |
| `UNREGISTERED` token pruning | the Function | 4 |

Not deferred but worth naming: the **notification id** `hash(link, D)` is Phase 3. The domain emits
`Correction(linkId, day)` so the id can be built from both parts — which is what keeps a correction
for one watched person from cancelling a standing warning for another on the same day.

---

## What to watch out for next

**Apply `toCancel` before `toSchedule`.** Now that alarm identity includes the instant, a moved
reminder appears in *both* sets. The platform id stays derived from `(day, slot)`, so cancelling
after scheduling would cancel the alarm you just armed. Documented on both `ScheduledReminder` and
`ScheduledWarning`; it is a Phase 2/3 sequencing trap.

**The purity guard only guards `lib/domain/`.** Phase 2 introduces layers where `DateTime.now()` is
legitimate at the edge and forbidden in a policy. The guard will not catch a policy that drifts into
`lib/data/`.

**Phase 4 must not treat a cache hit as a successful read.** This is the trap above, and it is the
single most expensive thing in this summary to get wrong, because it disables ADR-0001's staleness
bound silently and the symptom is *nothing happening*. Use `Source.server`, or check
`metadata.isFromCache`. The mapping table is in ADR-0004 and in the `FirestoreRead` doc comment.

**The 18 model cases are a port, not a link — and the model is now partially superseded.**
`tools/models/away_warning_model.dart` has one `readOk` flag where ADR-0004 has two states. Its 18
cases stay correct read as the *unreachable* interpretation and are ported that way; `S15r` and
`S16r` in the test suite cover the refused reading, which the model cannot express. The model is
annotated to say so and left runnable, because its `superseded: 4 / decided: 0` result is still the
regression guard for the ADR-0001 ordering question. **Decide that invariant's fate before
extending it.**

**`warnAccessLost` needs its copy reviewed by `uiux-reviewer` and added to `screens.md`,** which is
where approved strings live. The `lastConfirmedDay` it carries is nullable — access can be lost
before any check-in was recorded — and the copy needs a variant for that rather than rendering an
empty date.

**Phase 2 has a device exit criterion**, and `docs/testing/device-matrix.md` wants stock power
settings tested first on the POCO F3 (Android 13 / API 33, HyperOS 1.0).

---

## Verification

```
flutter analyze                                   No issues found!
flutter test                                      All tests passed!  (328 tests)
dart run tools/models/away_warning_model.dart     superseded: 4 failure(s)   decided: 0 failure(s)
flutter build apk --debug                         Built app-debug.apk
  └─ GeneratedPluginRegistrant.java               0 registrations  (ADR-0002 confirmed)
tools/check-secrets-ignored.ps1                   OK - 19 paths ignored, 1 deliberately tracked
```

**Exit criteria from PLAN.md** — `flutter test` green ✓, covering day boundaries across timezones ✓,
DST in both directions ✓, away edges (`from`, `through`, the day after) ✓, the correction path ✓,
and warning suppression ✓.

**Review focus from PLAN.md — purity.** Zero Flutter imports under `lib/domain/`. The only
`package:` imports in the entire layer are `package:timezone/timezone.dart` and
`package:timezone/data/latest.dart`. Every occurrence of `DateTime.now`, `.toLocal(`, `tz.local`,
`Timer`, `Stopwatch`, `dart:io` and `package:flutter` in the layer is inside a doc comment
explaining why it is forbidden — asserted, not reviewed, by
`test/domain/domain_purity_test.dart`.
