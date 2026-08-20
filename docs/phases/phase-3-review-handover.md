# Phase 3 review — handover

**Written:** 2026-08-20 · **Head:** `2290e71` · **781 tests**, `flutter analyze` clean, both
`flutter build apk --debug` and `--release` succeed.

This document exists because the Phase 3 gate review ran long enough to span sessions. It records
what the reviewers found, what was fixed, what is still owed, and how to pick it up.

**Phase 3 is NOT signed off.** **All five reviewers have run at the gate and every finding is fixed.**
The device work is done too, and it found something: **the warning does not arrive after a real
night in Doze.**

**Updated 2026-08-20 11:30 — the Doze question is SETTLED, and the session that settled it found a
second, unrelated defect.** Deep Doze blocks the warning **with a warm process**, so the cold-service-
start hypothesis is falsified; the block is a **JobScheduler** gate with a name, `readyNotDozing`.
Separately, **the alarm isolate closes the UI's database** — `DatabaseException(database_closed 1)`,
unfixed. Both are written up in `docs/testing/device-matrix.md`. What is now open is a *decision*, not
a measurement — see *The Doze problem* and *Next steps*.

---

## The one-line story

Five reviewers were launched at the Phase 3 gate. They found two criticals — one of them
independently by three of them — and roughly thirty further findings, on code whose self-review had
come out clean. Acting on those findings produced five more rounds, and **four of those rounds found a
defect introduced by the previous round's fix**. The testing round continued the pattern: the commit
that fixed `uses24Hour`'s two sources left the setting written once at launch inside another call's
`try`, its only test-level coverage absent, and two docstrings broken — one still arguing for the read
it had just deleted.

The UI/UX round then found that the *previous* fix to the same screen had shipped the one error phrase
`guidelines.md` bans by name, and that raising the contrast level to fix the light palette had pushed
a different pair — the button inside the warnings-off banner — from about 5:1 down to **2.33:1**.

That pattern is the reason the remaining reviewers should run before the Doze night rather than after,
and the reason each round now re-reads the previous round's diff first.

---

## Commits, oldest first

| Commit | What |
|---|---|
| `13ab177` | Tier 1 — four false claims the watcher side made to a family |
| `00df78a` | Tier 2 — tests that could not fail, including the highest-value one |
| `da069b1` | Every finding from the **testing** review, including two that were lost to a compaction |
| `63f84b4` | Two more false claims from the **architecture** review, plus per-link isolation |
| `c347315` | The **UI/UX** review — the muted watcher's missing words, and a correction about the wrong day |
| `3355b3f` | Tier 3 — resume repaired only half the app; an unchecked notification payload |
| `c690b1b` | Tier 4 — the light palette missed this app's own contrast floor |
| `ee0beed` | Tier 5 — ADR-0007, and an ADR naming the wrong mechanism as its own guard |
| `bbe68d5` | The **architecture** re-review of Tiers 3-5 |
| `7311a33` | The **testing** re-review at the gate |
| `769448c` | The **UI/UX** re-review at the gate |
| `e2e084d` | The **security** review — its first run this round |
| `ecd4e38` | The **infrastructure** review — its first run this round |
| `dd4dd03` | The **architecture** re-pass — the last review owed |
| `d497859` | Post-gate device pass, and the clock format that does not follow a resume |
| `cde67ae` | The overnight Doze run armed; forced Doze already ate a warning |
| `2290e71` | The Doze night — broadcast on time, isolate 3h31m late |

---

## Reviewer status

| Reviewer | Last run | Outcome |
|---|---|---|
| **architecture** | **at the gate, over `ecd4e38`** | Nothing to fix before the gate. Six items, all acted on — see the round below. |
| **infrastructure** | at the gate, over `e2e084d` | Nothing irreversible wrong; nine findings acted on. |
| **security** | at the gate, over `769448c` | No exploitable finding; three items acted on. |
| **uiux** | at the gate, over `7311a33` | All findings fixed. |
| **testing** | at the gate, over `bbe68d5` | All findings fixed. |

**Every reviewer has now run at the gate and every finding is fixed.** No review work remains. What
remains is one open device question — *The Doze problem*, below.

### Standing rule

**Never run reviewers in parallel, and ask before running any.** Two parallel launches exhausted the
session limit. The working pattern is: run one, report, fix, ask before the next.

**And verify a finding before acting on it.** Both gate rounds so far produced at least one finding
whose severity moved once it was checked against the code: the UI/UX round estimated a contrast
failure at "roughly 3:1, treat as an estimate" and it measured **2.33:1, in both modes**; it also
filed the missing away row as a shipping defect when no user can reach that state until Phase 6.
Measuring took two minutes in each case.

---

## The architecture round on Tiers 3-5 (`bbe68d5`)

Its must-fix was a defect introduced two commits earlier while fixing a different one.

**A single failed link made the screen say *"You're not looking after anyone."*** The per-link
isolation added in `63f84b4` omits a link the reconcile threw on — and with one link, which is all of
Phase 3, "short list" *is* "empty list". The empty list makes a positive false claim, on the screen
the *lost access* notification routes to. Two aggravations: the `isEmpty` branch returned before the
warnings-off banner, so a muted watcher whose only link failed got neither; and the failure was
written to a settings key nothing reads.

*Fixed:* `WatcherState.unreconciled` carries them in-band and `_FailedRow` renders each one — a claim
about **us** in ADR-0004's shape, naming the person, with an honest next step. Deliberately not *"you
will not be warned"*, because the alarm may still be armed.

**The wrong guard was documented twice, in the same paragraph.** `ee0beed` replaced ADR-0006's false
claim that the lease serialises the access-lost cadence — with another false claim, that the
within-day dedupe does. It does not: `alreadyToday` sits *below* the transition and cause-change
branches, deliberately and per a recorded POCO F3 finding. What actually holds is a link-keyed
notification id plus both runs stamping the same day.

**`_reconcileBothSides` reconciles one side.** ADR-0007 cited it for both. Correct behaviour (the
watched side is repaired by `TapScreen`'s own observer), wrong name. Renamed to
`_reconcileWatcherSide`; ADR-0007 decision 3 now names both mechanisms.

**`uses24Hour` had two sources and the wrong one was authoritative** — the row and the notification
from the *same reconcile* could disagree about the same instant. Now one source:
`platformDispatcher.alwaysUse24HourFormat` on `ClockService`, awaited in `main()`, read off
`WatcherState` by the screen. The Tap screen's third formatter (*"9:14 AM"* against everywhere else's
*"9:14 am"*) folded into the same one.

**A second notification tap stacked a second `WatcherScreen`** — two lifecycle observers, two
reconciles per resume, and the first pop clearing the flag while one was still showing.
`WatcherScreen.isShowing` is now a counter owned by the screen, which also survives Phase 5's routing
on role.

Also fixed: the two health-flag writes sat outside the per-link isolation they were added beside;
`watched_zone_unknown` aggregated per-link data into a device-wide bool and moved onto
`WatchedPersonState` (the setting is gone); `main.dart` reached into `LocalStore` from a widget and
now goes through `AppServices.watches`; §5 and §6 amended for the new settings and `WatcherCopy`.

### One thing that could not be done as asked

The reviewer wanted three widget tests on `IAmOkApp`. **Pumping the app shell hangs**:
`WidgetTester` runs in a fake-async zone, `LocalStore` is real `sqflite` doing real I/O off that
zone, and the reconcile never completes — tests time out rather than fail. `runAsync` would let the
I/O through but takes the frame scheduler with it, and the Tap screen's indefinite progress
indicator rules out `pumpAndSettle` in any case.

`test/app_lifecycle_test.dart` asserts the two facts the shell *decides with* — `WatcherScreen
.isShowing` and `AppServices.watches` — and states this limit in its own docstring rather than
implying coverage it does not have.

> **Corrected by the testing review.** This paragraph ended *"The three-line lifecycle glue stays on
> the device matrix"*, and it was on no row of that matrix — the nearest row covers a **launch**,
> which is a different code path from a resume. The decision inside the glue has since been hoisted to
> `IAmOkApp.repairOnResume` and unit-tested; the wiring that remains now has its own unchecked matrix
> row.

---

## The gate round — testing over `bbe68d5`

Verdict: **coverage is adequate for Phase 3.** The mandatory list is complete, the purity guard is
stronger than `strategy.md` asks for, and the device evidence records failures rather than ticks.
Nine findings, all fixed, and the two that mattered were both new material from this review round.

**The 12-hour clock was asserted on the notification and on nothing else.** `watcher_screen_test`
declared `uses24Hour = true` and never passed `false` from any of its sixty tests, and the only
time-bearing assertion was `textContaining('This phone last checked')` — which passes for `10:00`,
`10:00 am` and `Sunday 10:00` alike. So the drift `bbe68d5` was written to prevent was caught by
nothing: `flutter_test` defaults `alwaysUse24HourFormat` to **false**, so restoring the `MediaQuery`
read would render `10:00 am` on the row under a notification reading `10:00`, with the suite green.

Underneath it, two real defects rather than only a gap. `LocalStore.uses24HourClock` had **no coverage
at any level**, and its docstring claimed *"The UI writes it on every resume"* when the single call
site was in `main()` — so a reader who changed the setting kept the old format for the life of the
process, and because that write shared a `try` with `flutter_timezone`, a plugin hiccup at launch left
a 12-hour device on the 24-hour default for the whole session. `_cacheDeviceFacts` now writes both
device facts, under **separate** guards, on launch and on every resume.

**The resume repair's decision lived where only a device could reach it.** Invert
`didChangeAppLifecycleState`'s guard and a force-stopped watcher never re-arms an alarm again — with
every test green and, as it turned out, no device row either. It is now
`IAmOkApp.repairOnResume`, a two-input predicate with its truth table asserted, and the wiring that
genuinely needs hardware is a matrix row instead of a claim in a docstring.

Also fixed: an announcement test that asserted a copy constant and passed with
`sendAnnouncement` deleted; a counter test that swapped the widget tree instead of pushing and popping,
so the two instances never coexisted; `phase-3-summary.md` claiming *"The five reviewers have now run
and reported"* with a stale test count beside it; `strategy.md` and the testing skill both calling a
**31-day** away period a *rejected* case when 31 is the longest allowed and 32 is rejected — a spec
that would walk the next reviewer into a false finding against correct code; two unasserted
`onSurfaceVariant` contrast pairs including the disabled tap target, which is the state that screen is
in most of the day; a "one seed" test that only checked that the brightnesses differed; a
process-global counter unwound by a line a failing test would skip; and the two docstrings `bbe68d5`
landed broken — one with its identifiers missing, one still arguing for the `MediaQuery` read it had
just removed.

Both blocker fixes were mutation-checked rather than assumed: the announcement test and the
guard-separation test were each confirmed to **fail** against the defect they describe, then the code
restored.

---

## The gate round — UI/UX over `7311a33`

Two findings worth holding the gate for, both in material the reviewer had not seen, and both on
surfaces it had itself approved a round earlier.

**The watcher list shipped *"something went wrong"*.** `guidelines.md`'s Floors table bans that exact
phrase — *"Say what happened and what to do"* — and `WatcherCopy.couldNotCheckOn` contained it
verbatim, on the row a family member reaches by tapping the *lost access* notification, whose entire
justification (ADR-0004) is that it is actionable. Two other files quote the ban back in their own
comments, so the rule was known and applied everywhere except the one place a family would read it.

That is what a source-level test is for, and there now is one: `test/copy/copy_floors_test.dart`
reads `lib/copy/` as text and asserts the four bans that can be checked mechanically — the phrase,
exclamation marks, emoji, and numeric dates. Mutation-checked: reintroducing the string fails it.

**The button inside both warnings-off banners was illegible, and the previous round made it worse.**
A bare `TextButton` takes its label colour from `colorScheme.primary`, which is measured against
`surface` — not against the `errorContainer` painted behind it. The reviewer estimated ~3:1 and
flagged the number as an estimate; measured, it is **2.33:1 in light and 2.31:1 in dark**, against a
4.5 floor. `errorContainer` darkens as `contrastLevel` rises while `primary` does not move, so
`c690b1b` — the commit that raised the level to fix the light palette's AAA misses — pushed this pair
down. It is the one control that turns notifications back on, inside the banner that exists because
they are off. Both banners now set `foregroundColor` explicitly, asserted as a ratio in
`contrast_test.dart` and as wiring in both screens' widget tests.

Also fixed: *"It will try again."* was a promise the device cannot keep — `alarms.apply` is among the
throws the per-link guard catches, so a link whose window was never armed has nothing scheduled to
retry with, and the row told the reader to wait. The row carries a **"Try again"** control instead,
which also closes an accessibility floor breach (pull-to-refresh was the only route to retrying, and
a drag is the gesture a screen-reader user is least able to perform). The button sits *outside* the
row's `Semantics`/`ExcludeSemantics` pair, or it would be invisible to exactly the reader it was
added for — asserted with `matchesSemantics`. `screens.md` had **two contradictory approved strings**
for "Nobody is watched" and the shipped one matched neither; it also claimed the watcher list reads
`MediaQuery` live, which `bbe68d5` had made false. The single-digit 12-hour form (*"9:14 am"*, no
leading zero) was produced by the code and pinned in neither the tests nor `screens.md`. The
`isEmpty` early return still hid the warnings-off banner on an empty list. `NotificationCopy._time`'s
docstring still argued for the hard-coded 24-hour clock it no longer had.

### One finding whose severity moved on inspection

The reviewer filed the **missing away row** as a Medium shipping defect: a verified away period falls
through to *"Everything OK"*, while `screens.md` approves *"Away until Sat 22 Aug — set by Ana"*.

The behaviour is real, but no user can reach it. The Tap screen's *"I'm away"* action is
`onPressed: null` until Phase 6 and there is no backend to carry a period, so the state exists only
behind a debug-harness control. Building the row now would also produce an **unattributed** away
state — `AwayPeriod` has no `setBy`/`setByName` until Phase 6 — which the same guidelines forbid.
So it is recorded as a decision in `screens.md` and the phase summary rather than built, and it lands
in Phase 6 with the attribution that makes it honest.

---

## The gate round — security over `769448c`

**Verdict: no exploitable finding, and the secrets guard is intact in both directions.** The script
exits 0, `git ls-files` carries exactly one `.json` — `android/app/google-services.json`, tracked on
purpose — no credential shape appears anywhere, and `git log -p --follow -- .gitignore` shows **zero
removed lines across the file's entire history**, so the 2026-08-15 lesson is holding. Sections 2-4
of the security checklist have no artefact at Phase 3 and were scoped out rather than reported as
gaps: there is no `firestore.rules` and no `functions/` yet.

**Three `.gitignore` rules had no assertion behind them.** `tools/check-secrets-ignored.ps1` printed
`OK` for sample paths matched by *earlier, broader* rules — `.credentials/serviceAccount.json` is
caught by `.credentials/`, not by `**/serviceAccount*.json` — so three lines could have been deleted
with the guard still green, including `.firebase/`, which starts holding content the moment Phase 4
runs the CLI. Three sample paths added, each verified with `git check-ignore -v --no-index` to hit
the intended rule and nothing earlier, and the guard itself mutation-checked by deleting a rule and
confirming it reports `EXPOSED` and exits 1.

**`AppServices.watches` returned a bool, and that shape is a Phase 4 trap.** The check closes a real
attack — `MainActivity` is exported, as every LAUNCHER activity must be, so a co-installed app can
hand the app a crafted payload through an intent, and before this round any non-null value pushed a
screen. But a bool answers *"is this one of mine"* and leaves the caller holding the untrusted
string, which invites membership proven against a local cache and then the raw payload dereferenced
into a document path anyway. It is now `resolveWatchedLink(String) -> Future<Link?>`, and `main.dart`
uses the returned object, so the string stops at the boundary. Both docstrings now also say what the
check is **not**: `LocalStore` is the threat model's trust boundary 4, a decision cache and never an
authorisation record, so from Phase 4 the security rules are what deny — resolution keeps the
untrusted string out of the path and buys nothing else.

**`warnings_shown` keeps every missed day for ever**, which is a per-day machine-readable record of
when an identifiable elderly person was *not* verified fine. Not exploitable — `allowBackup="false"`,
no `INTERNET` in the release manifest, nothing in `lib/` can transmit — but unowned. No prune was
written: the ledger is unbounded *because* corrections are unbounded, and a prune with the wrong
bound either re-posts an old warning or strands an uncorrectable one, which is this project's worst
failure class. Recorded as owed beside T9 in the threat model, with the two acceptable answers named,
before Phase 8's privacy policy has to describe it.

Also recorded there: **nothing leaves the device in Phase 3**, verified rather than assumed — no
logging, no analytics, no `dart:io` or `http` in `lib/`, and **no `INTERNET` permission in the
release manifest** — together with the fact that this expires in Phase 4, when Firebase adds it.

### Two proposed fixes that were deliberately not applied

**Filtering `resolveWatchedLink` on `Link.isAccepted`** would have broken an honest path. It is right
for any future *read*, and wrong for this caller, which decides whether to open a screen: a
notification posted before revocation can still be in the tray, and the watcher list has a revoked
row — *"Your link with Mum has ended."* — that exists precisely to explain it. Filtering would make
that tap do nothing at all. Revoked links resolve; the status rides on the returned object where a
caller that needs an accepted link can see it, which is itself an argument for returning the `Link`.

**Gating `SimulatedCheckInReader` on `kDebugMode`**, by analogy with the clock offset, cannot be
done. The two are not symmetric: the clock offset has a real fallback (`Duration.zero`) and the
reader has none — in Phase 3 the simulated reader *is* the implementation, so gating it leaves a
release build with no reader at all rather than with a safe default. The asymmetry is documented at
the call site instead, with the note that Phase 4 deletes the question.

One claim was corrected rather than defended: the harness docstring said the release tree "is
tree-shaken". `DebugHarnessButton` is in fact constructed in a release build and returns an empty
box; what makes the harness unreachable is that `DebugHarnessScreen` has exactly one reference in the
repo, inside a closure on a widget that is never returned. Nothing measures the tree-shaking, and
`flutter test` cannot — the test VM is a debug VM.

---

## The gate round — infrastructure over `e2e084d`

**Nothing irreversible is wrong.** Firestore region and mode, the applicationId, and the App Check
state (not registered, so not enforced) are all correct, and the reviewer verified them from the CLI
rather than from the record: `europe-west1`, `FIRESTORE_NATIVE`, creation timestamp matching to the
microsecond, the app id, both debug SHAs byte for byte, and — more than the record claimed — RTDB
confirmed off. Nine findings, all acted on.

**The three Android SDK levels were not pinned.** `compileSdk`, `minSdk` and `targetSdk` all read
`flutter.*Version`, so `flutter upgrade` could move them with a **zero-line diff in this repo**. The
values were right; the guarantee did not exist. Two of the three are load-bearing: `minSdk = 24` is
cited by the desugaring block, by `LocalStore.upsertLink`'s avoidance of UPSERT syntax, and by the
device matrix's "the watched person's phone is likely to be old" — and a comment three lines away
stated it as a fact the code did not hold. `targetSdk = 36` is what the POCO F3 measured exact alarms
and `POST_NOTIFICATIONS` against, both platform-gated on it. All three pinned, with the reason on
each.

**The migration tripwire could not tell "you forgot" from "you didn't."** `if (to > 3) throw` used a
literal derived from nothing: bumping `schemaVersion` to 4 *and* writing the v4 step would still have
thrown on every device holding an older store. Replaced with a per-version ladder whose `default` arm
cannot drift.

**And `onDowngrade`'s reasoning missed the case it creates.** It blanket-accepts a newer file and
rewrites the version down — leaving the newer schema in place. So v3 → v4 → roll back → re-install v4
replays the v4 step against a table that already has its change, and a bare `ALTER TABLE … ADD
COLUMN` throws `duplicate column name`. `openDatabase` throws with it, and `LocalStore.open()` is
unguarded in both `main.dart` and the alarm entry point — the app cannot open its store at all, and
the only repair is a reinstall, which destroys `warnings_shown`: the exact loss the block is written
to prevent, by a route it did not consider. v3's step is idempotent already, which is luck rather
than design. Idempotence is now a stated rule with the crash spelled out.

**v2 → v3 is the path the owner's own phone actually took, and it was the untested one.** The POCO F3
ran `00b9b99` (v2) before `ff0e785` bumped to v3. From v1 the `DROP TABLE IF EXISTS reconcile_lock`
is a no-op; from v2 it discards a real table, because v2 keyed the lock `id INTEGER PRIMARY KEY CHECK
(id = 0)` and v3 re-keys it by scope. One branch, two genuinely different paths, one pinned. A v2
fixture now covers it — and the fixture was probed to confirm it really produces a v2 database with
the old lock shape, since a migration fixture whose "before" is not the old version asserts nothing.

**`PLAN.md` ordered the client before the rules.** Step 2 wired client writes; step 3 deployed
`firestore.rules`. Firestore was created in production (locked) mode, so a client built at step 2 gets
`permission-denied` — which ADR-0004 maps to **refused**, driving the access-lost notification and its
0/1/3/7/14-day cadence. Following the plan as written produces this app's own worst failure class from
a developer's laptop. Rules now deploy first, with the reason recorded inline.

### The `apps:*` exit-9 constraint was wrong in both halves

`CLAUDE.md`, `deploy-notes.md`, `firebase-setup-prompt.md` and the infrastructure skill all said
*every* `firebase apps:*` command prints `√ success` then exits 9. Re-measured at this gate:

- **It is intermittent.** `firebase apps:list --project i-am-ok-c74ca`, three runs in one shell
  session: crashed, **exited 0**, crashed. One clean run is not evidence the trap is gone.
- **It is not confined to `apps:*`.** `projects:list` crashes. `database:instances:list` crashed for
  the reviewer and exited 0 twice for me.

The operational advice — read the output, never the exit code — was always right and is unchanged.
All four places now say *every* Firebase command and name the intermittence, which matters most in
Phase 4 where `deploy` and `functions:list` are the commands that count.

### Two documentation claims that could not have been evidence

`firebase-setup-prompt.md` cited *"Resource Location `[Not specified]`"* from `projects:list` as proof
Firestore did not yet exist. Running it today, with Firestore live in `europe-west1`, that column
**still reads `[Not specified]`** — it is the GCP default resource location, not Firestore's, and
could not have distinguished either state. Dropped, with the reason kept.

The same file cited `keytool -list -v` for the debug SHAs. `keytool`, `java` and `adb` are **not on
`PATH`** on this machine. It matters at Phase 8, when the same command must read the *release*
fingerprints — the working form (Android Studio's JBR) is now recorded, and was run to confirm it
produces the fingerprints already registered.

### The one thing the reviewer could not check, now settled

It could not verify the **merged release manifest** — that needs `flutter build apk --release`, which
writes files, and the review is read-only. It reasoned carefully from the debug merger report instead,
and explicitly flagged that report as stale-dated before relying on it.

Built at the gate. **`INTERNET` is absent from the merged release manifest**, and the merged
permission set is exactly the six the app reasons about. That matters because `threat-model.md` now
leans on it. It also had **no guard at all**, which is how `VIBRATE` once arrived uninvited from
`flutter_local_notifications`: `test/android_manifest_test.dart` now holds the half a test can reach —
source manifests plus that closed set — and says in its own docstring that it cannot see a transitive
AAR. The merge check is a command in `deploy-notes.md`, owed whenever a plugin is added.

---

## The gate round — architecture over `ecd4e38`, the last review owed

**Nothing had to be fixed before the gate.** No layering violation, no decision in the wrong isolate,
no defect that could produce a false claim or a silently lost warning. The reviewer explicitly cleared
the two changes with the most room to go wrong — `repairOnResume` and the migration ladder — and said
so with the reasoning: `repairOnResume` cannot go to Domain because it takes a Flutter enum, and
mapping it would add an untested branch to remove one; the ladder's `default: throw` cannot ship,
because the v1 and v2 fixtures open at `LocalStore.schemaVersion` and fail the suite if a step is
missing. That is what the old literal tripwire could not do.

What it did find was **a duplication rather than a defect — the same class of thing, one step
earlier**, and created by this round.

**`cacheDeviceFacts` existed twice**, in `main()` and in `WatchedStateNotifier`: same two facts, same
two guards, same order. Written by the round that was fixing *this very fact* having two sources.
They agreed, but the next person to change one had no signal to change the other, and
`NotificationService.watcherDelivery` already carries the rule — *"two copies of a decision are two
chances to make it"* — written after both of this phase's wiring defects turned out to be in a copy
of one expression. Now one method on `AppServices`, called by all three callers.

**Resume-time caching was owned by the watched provider, and Phase 5 breaks that.** It worked only
because `TapScreen` is home and stays mounted; a watcher-only user under Phase 5's routing would
never mount it, and both device facts would revert to launch-only — the exact defect the testing
round had just removed for `uses24HourClock`. ADR-0002 says *the UI* caches on resume, which is a
statement about the isolate, not about one side's provider. It moved to the app shell, ahead of the
`repairOnResume` guard and unconditional, because the guard answers *which reconcile runs* and not
*whether the device facts are stale*. That also fixes an ordering slip the reviewer spotted: the
shell's observer registers before `TapScreen`'s, so the watcher reconcile had been reading facts
cached at the *previous* resume.

**The watcher's own unresolvable zone was swallowed; the watched person's was not.** If the platform
names a zone this build's tzdata does not carry, `ClockService` returns null, nothing is stored, and
every warning alarm on the device is armed at `warningLocalTime` **UTC** — up to twelve hours out,
permanently, on a dead man's switch. ADR-0002 accepts a *stale* watcher zone because it cannot affect
`D`; it never considered an *unresolvable* one, where the cost is a fixed offset that never heals.
The symmetric flag has existed on the watched side since the last round
(`WatchedPersonState.zoneUnknown`), with the argument that a fault the app cannot see is a fault
nobody will fix. `WatcherState.watcherZoneUnknown` is that flag for the reader's own zone.

**The Tap screen's live `MediaQuery` read is gone.** The UI/UX round recorded it as a decision and
the reasoning was sound — nothing on the watched side is paired with a notification rendering the
same instant. The architecture round pointed out the residual it names is removable at zero cost, and
that this app has now paid twice for this one fact having two sources. `uses24Hour` is on
`WatchedState`, from the same `LocalStore` read the watched reconcile already makes. The test pins it
by setting the ambient `MediaQuery` and the state *against each other*.

**§4 and §6 had drifted.** §6's `ClockService` row still described one discovery responsibility, and
§4's bullet was still singular about timezones. Both now say device **facts**, with the note that the
second is ADR-0002's pattern applied again rather than a new decision — which is why it gets no ADR
of its own, per the decisions README.

Three docstrings were describing code that no longer exists or behaviour that does not happen: a
reference to `_cacheDeviceZone`; `WarningAlarmScheduler.cancelAll` documented as "used on revocation"
when revocation goes through `apply` with an empty desired set and this method has no caller at all;
and a claim that an unconsumed notification payload is picked up by the next successful reconcile,
which it is not — that path runs from `initState` and from the listener, and a pull-to-refresh
produces a new widget against the same `State`, so neither fires.

---

## The post-gate device pass (`d497859`) — six passes and one finding

Seven checks on the POCO F3 against the six gate commits. Detail in `docs/testing/device-matrix.md`.

**Passed:** a fresh install arms at the device's wall times (12:00 / 18:00 / 21:00 Madrid, not UTC);
the alarm isolate wakes from an `am kill`ed process and picks the right message, twice; a 12-hour
device gets *"This phone last checked 10:34 pm."* on the watcher row; a notification tap opens the
watcher list with each row one TalkBack utterance; force-stop → reopen restores 0/0 → 12 warnings /
18 reminders with the store agreeing exactly; and the release build runs with the harness absent,
`aapt2` confirming compileSdk 36 / minSdk 24 / targetSdk 36 and **no `INTERNET`** — stronger evidence
for the threat model's claim than the merger report, since it is the shipped artifact.

**FINDING, still live: the cached 12/24-hour setting does not follow a plain resume.** Switching the
device between formats while the app was backgrounded, two successive background→resume cycles wrote
the **stale** value in **both** directions. A cold start wrote the correct one; so did a resume after
a forced configuration change. Flutter refreshes `platformDispatcher.alwaysUse24HourFormat` only on a
configuration change, so `cacheDeviceFacts` faithfully re-writes the same stale value.

The write happens on resume; the value does not move. The zone half is unaffected —
`flutter_timezone` is a live plugin call — though that was not measured, because setting the device
zone needs `SUGGEST_MANUAL_TIME_AND_ZONE`, which adb does not hold. **Consequence is cosmetic and
never a false claim about a person**, so it is recorded rather than urgently fixed; the live fix is a
platform channel to `DateFormat.is24HourFormat` and belongs with Phase 7. Documented at
`LocalStore.uses24HourClock`, and the docs that claimed otherwise are corrected.

Caveat kept with it: the setting was changed with `adb shell settings put`, and a real Settings
toggle might deliver a configuration change as a side effect. What was measured is that a plain
resume does not refresh the value.

**Not reached, and left unchecked rather than claimed:** a 12-hour time inside an isolate-posted
notification (both harness controls that arm a real warning either force `succeeded` or null out
`lastReconcileAt`, so neither message carries a time), and a device timezone change (needs a
permission adb does not have — it needs a human in Settings).

---

## THE DOZE PROBLEM — SETTLED 2026-08-20, and the answer was not the hypothesis

> **Read `docs/testing/device-matrix.md` § *SETTLED — deep Doze blocks it with a WARM process, and the
> block is JobScheduler* for the evidence.** The short form:
>
> A fourth run supplied the missing cell — **deep Doze with a warm process** (pid alive,
> `AlarmService started!` logged 3½ minutes before the alarm). The broadcast arrived on time and
> **nothing ran**, exactly as in runs 1 and 2. **Process warmth is irrelevant; the hypothesis below
> is falsified.**
>
> The mechanism was read out of `dumpsys jobscheduler` rather than inferred from timing. The plugin's
> `AlarmBroadcastReceiver` hands the work to `JobIntentService.enqueueWork`, i.e. **a JobScheduler
> job**, and in Doze that job sits with every explicit constraint satisfied and one implicit one not:
> `readyNotDozing: false`. The 10-second `temporaryAppAllowlistDuration` on our alarm covers the
> **broadcast** — which did run — and does not extend across the hop to the job. The app was in
> `Standby bucket: ACTIVE` with `Uid: active` and still did not run, which closes the objection that
> driving it by hand made it easier than a real night.
>
> Releasing Doze at 11:28:43 produced `R(service create …AlarmService)` at 11:28:46.787 and both
> warnings at `when=11:28:47`, against an armed second of **11:25:00**. That is run 2's 3h31m
> reproduced in miniature and under control.
>
> **And the follow-up was run — 12:00 the same day, same device, same forced deep Doze.** The
> `flutter_local_notifications` reminder, whose alarm is **indistinguishable** from the warning's in
> `dumpsys alarm` (`RTC_WAKEUP`, `flags=0x5`, `exactAllowReason=policy_permission`, the same 10-second
> allowlist) and which differs **only** in that its receiver calls `notify()` instead of
> `enqueueWork()`, arrived at **`when=12:00:00`** — on the second, with `get deep` still `IDLE` at
> 12:00:58 and no live JobScheduler entry for the package at all.
>
> **So Doze does not block local delivery on this handset. The `JobIntentService` hop does.** §14's
> trigger condition — *"whether alarms … actually survive"* — is **not met as worded**: the alarms
> survive, and so does a notification posted from a receiver. The ADR has three options, not one, and
> the cheapest of them is now live rather than ruled out. Details and the option list are in
> `docs/testing/device-matrix.md`.

### The three runs that could not settle it, kept for the record

**Everything from here to *If it reproduces* is superseded.** It is kept because the reasoning is
worth reading and because the hypothesis it argues for turned out to be **wrong** — run 4 falsified
it. Do not act on the "experiment that separates them" below; it has been run, and the answer is in
the box above.

**The warning does not arrive after a real night in Doze.** Three runs on the POCO F3 (Android 13,
HyperOS `OS1.0`, stock power settings, app never on the Doze whitelist). Full evidence in
`docs/testing/device-matrix.md`; this is the shape of it.

| # | When | Doze state | App process | Result |
|---|---|---|---|---|
| 1 | 2026-08-19 22:56 | deep, **forced** (`deviceidle force-idle`) | backgrounded ~14 min | broadcast delivered **on time**, **no Dart ran at all** |
| 2 | 2026-08-20 05:00 | deep, **real**, hours | hibernated by HyperOS | broadcast delivered **on time**; `AlarmService` not created until **08:31** — **3h31m late** |
| 3 | 2026-08-20 10:30 | **light** only | **warm**, `AlarmService` already running since 09:30 | delivered 3m47s late (ordinary light-Doze batching), Dart ran in ~1s, **warning posted correctly** |

### What is established

- **AlarmManager is not the problem.** In runs 1 and 2 the `PendingIntent`s were delivered at exactly
  the armed second. Our alarms carry `flags=0x5` (FLAG_ALLOW_WHILE_IDLE) and
  `exactAllowReason=policy_permission`, and their `device_idle` policy is not deferring them.
- **What fails is running Dart afterwards.** Run 2's smoking gun: `AlarmService` — the plugin's own
  service that starts the Flutter engine and calls `warningAlarmCallback` — was created **once all
  night, at 08:31:16**, three and a half hours after the 05:00 broadcast, and only once the phone was
  back in use. `last_reconcile_at` stamped 08:31:17.
- Our alarms' `idle-options` grant `temporaryAppAllowlistDuration=10000` — **ten seconds** to start a
  service. That window is where this is being lost.

### What is NOT established, and this is the point

**Run 3 differs from runs 1 and 2 in _two_ variables at once** — light instead of deep Doze, *and* a
warm process with the service already running. So it does not tell us which one matters.

The hypothesis, stated so the next session can try to falsify it rather than confirm it:

> **The cold service start is the cause, not Doze depth.** Run 2 argues for it — the broadcast was
> punctual at 05:00 and it was specifically `AlarmService` *creation* that waited until the device
> woke.

Run 3 is **not** evidence that the mechanism works overnight. It was never in deep Doze: the idling
history shows `deep-idle` beginning at ~10:38, five minutes *after* the alarm fired at 10:33.

### The experiment that separates them

**Deep Doze with a warm process.** If the warning arrives, the cause is the cold service start and
the fix is about keeping the service reachable. If it does not, deep Doze itself blocks it and the
answer is §9's scheduled server-side function.

The obstacle, and it is real: **the two variables keep moving together.** The process would not die
on demand this morning — `am kill` refuses while `oom_score_adj` is 0, and swiping from recents did
not take either — while overnight HyperOS hibernated it on its own. Ideas worth trying, cheapest
first:

1. **`dumpsys deviceidle force-idle` with the app freshly launched** (service warm, deep Doze
   immediate). This is run 1 with one variable changed — run 1's process had been backgrounded 14
   minutes and may already have lost the service. Check `AlarmService started!` is in logcat for the
   *current* pid before forcing idle.
2. **The inverse:** light Doze with a genuinely cold process. Kill the process (see the note on
   killing below), wait for light-idle, fire.
3. If neither separates it, a second real night with the app **launched immediately before** the
   phone is put down, to keep the service warm as long as HyperOS allows.

### If it reproduces

This is the trigger condition ARCHITECTURE.md §14 names for **un-deferring §9's scheduled
server-side function**, and ADR-0007 is the record of what that costs. Do not decide that silently —
it is a design change and belongs in an ADR.

**Keep it in proportion when writing it up.** The default `warningLocalTime` is **10:00**
watcher-local, by which time most watchers have used their phone and it is not in deep Doze. 05:00
was chosen because it is harsher. What the finding costs is the *guarantee*, and it lands exactly on
the reader §13 is written for: the low-usage watcher whose phone sits untouched.

---

## Measurement traps learned on the device, 2026-08-19/20

Each of these produced a wrong answer before it produced a right one. They are in
`docs/testing/device-matrix.md` too; repeated here because the next session will hit them within
minutes.

- **Counting pending alarms from `dumpsys alarm` by grepping the receiver name is wrong.** That
  matches the **App Alarm history** section (`reason=data_cleared`, `reason=alarm_cancelled`) and
  reported "18 reminders armed" on an app that had none. Pending alarms are the
  `RTC_WAKEUP #n: Alarm{… <pkg>}` lines whose **following** line carries `tag=*walarm*:<pkg>/<receiver>`.
  A correct parser is inline in `tools/doze-collect.ps1`.
- **A notification's `when=` is the only honest answer to "when did this fire".** The tray showing two
  warnings means nothing on its own — on 2026-08-20 they were from **00:26**, posted by a person
  opening the app, not by the 05:00 alarm.
- **Writing the app's store:** `run-as` can read it but cannot write through a redirect, cannot use a
  heredoc (no writable temp), and cannot read `/sdcard` under scoped storage. What works is streaming
  into the app's own shell:
  `"cd /data/user/0/<pkg>/databases
exec base64 -d > i_am_ok.db
<base64>" | adb shell run-as <pkg> sh`
  Verify with `PRAGMA integrity_check` afterwards, every time.
- **Killing the app without cancelling its alarms is hard — but it is SOLVED.** `am force-stop`
  cancels every alarm, so never use it mid-setup. `am kill` refuses while `oom_score_adj` is 0.
  **What works: `input keyevent KEYCODE_HOME`, wait ~5 s, read `/proc/<pid>/oom_score_adj` until it
  is non-zero (it reached 700), then `am kill`.** Measured 2026-08-20: the process died and all 12
  warning alarms and 21 reminders were still armed afterwards. The earlier "unsolved" note came from
  killing too soon after `HOME` and reading nothing back — always read `oom_score_adj` first rather
  than guessing at a delay.
- **Driving the debug harness with `adb input tap`: verify by the store, but do not conclude
  "mis-tap" from the store alone.** Always verify a control ran by reading the store, never by the
  tap returning — that part stands. But on 2026-08-20 two taps that left the store unchanged were
  taken for mis-taps and were nothing of the kind: the taps had landed, the control had run, and it
  had **thrown**. The harness prints `<label> FAILED` and the stack into a result panel **below the
  fold**, so the screen looks untouched until you scroll to the bottom. That misreading nearly buried
  the `database_closed` finding. **Scroll to the result panel and read it before blaming the tap** —
  `exec-out screencap -p` into a file and actually look at the image. Coordinates: take a screenshot,
  measure the button in it, and re-measure after every scroll; do not reuse coordinates across
  visits.
- **`dumpsys battery unplug` lets Doze engage while USB stays connected**, so adb keeps working. Pair
  with `dumpsys deviceidle force-idle` for immediate deep Doze, and always `dumpsys battery reset` +
  `dumpsys deviceidle unforce` afterwards.
- **Verify the device actually idled.** `dumpsys deviceidle` → *Idling history*, newest last, entries
  like `deep-idle: -10m35s`. An alarm firing on a phone that never idled proves nothing, and run 3
  was exactly that.

---

## Known-open, carried deliberately

Nothing here is a false claim; all are honest gaps.

- **`link_reconcile_failed` and `warning_alarms_exact`** are written and read by nothing outside
  `dump`. §13's health panel consumes them in Phase 7. (Both now have store round-trips as well as
  behavioural coverage through the service.)
- **`WatchedPersonState.zoneUnknown`** is computed and carried but no surface renders it. Same
  Phase 7 destination.
- **A warning erased by a force-stop is not re-posted** — `warningsShownFor` says it was shown.
  Accepted and recorded in ADR-0007 decision 4.
- **`ensureVisible` cannot reach a row far down a long list** — a lazy `ListView` never builds it.
  Mitigated with a cache extent; the real answer is fixed extents or a positioned list, and belongs
  with Phase 7's multi-person layout.
- **Screen-reader focus cannot be moved** to an arbitrary widget in Flutter. The tapped row is
  announced instead, and the code says so rather than implying focus.
- **§9's scheduled server-side function stays deferred.** ADR-0007 is the record of what that costs.
  The 2026-08-20 Doze result is the strongest argument in the project for un-deferring it — but read
  the caution in *The Doze problem* first: what is proven blocked is one plugin's JobScheduler hop,
  and a client-side path that skips that hop has not been ruled out because it has not been tested.
- **`DatabaseException(database_closed 1)`** — the alarm isolate closes the UI's shared sqflite
  connection, killing the UI's store for the life of the process. Found 2026-08-20, unfixed,
  mechanism verified in the plugin sources. Full write-up in `docs/testing/device-matrix.md`. This is
  the one genuinely new *defect* on this list; everything else here is an honest gap.

---

## Next steps, in order

1. ~~**Run the five reviewers.**~~ **Done.** All five ran at the gate; every finding is fixed, one
   commit per reviewer.
2. ~~**The device pass.**~~ **Done** — seven checks in `d497859`, plus three Doze runs.
3. ~~**Settle the Doze question.**~~ **Done 2026-08-20** — deep Doze blocks it with a warm process;
   the gate is JobScheduler's `readyNotDozing`. Evidence in `docs/testing/device-matrix.md`.
4. ~~**Run the experiment the ADR's premise depends on.**~~ **Done 2026-08-20 12:00** — the
   reminder path, whose alarm is identical and whose receiver skips the job hop, delivered at
   `when=12:00:00` inside the same deep Doze. Doze is not the blocker; the hop is.
5. **Decide about §9's scheduled function, in an ADR — owner's call.** The evidence is now
   sufficient and the options are three, not one: deliver from the receiver as the reminders already
   do (cheapest, and **the one remaining unmeasured step** is whether a Flutter background engine can
   start inside the 10-second allowlist, or whether it needs a foreground service under the
   exact-alarm exemption); or §9's server-side Function at ADR-0007's cost; or accept the deferral and
   surface it in §13's health panel. **§14's trigger condition should be reworded either way** — it
   says "whether alarms survive", and they do.
6. **Decide what to do about `database_closed`** — the alarm isolate closing the UI's connection. It
   is unfixed, it is not a Doze problem, and it lands on the isolate boundary in §4. This one is a
   code defect rather than a decision, but the repair has several shapes and should be chosen
   deliberately.
7. **Then rewrite `docs/phases/phase-3-summary.md`** to record the settled state, and sign off the
   gate. It does not yet carry either of this session's two findings.

### Device state as left on 2026-08-20 14:44

- **Debug build installed** (`app-debug.apk`, `lastUpdateTime` 2026-08-19 22:39:55). Predates
  `d497859` by five minutes, but that commit's `lib/` change is **doc-comment only** — verified by
  diffing with comment lines stripped — so the binary is behaviourally identical to `HEAD`.
- **The running process's UI database is CLOSED again** (pid 15097; the 14:44 alarm ran in it). Every
  harness control will throw `database_closed` until the process is restarted. **Restart before using
  the harness**: `input keyevent KEYCODE_HOME`, wait until `/proc/<pid>/oom_score_adj` is non-zero
  (~5 s, reached 902), then `am kill` — never `force-stop`, which cancels the alarms.
- Store: two accepted links, both `warning_local_time = 14:42`, `activeFrom = 2026-08-19`;
  `warnings_shown` holds **2026-08-19 / `warnOnline`** for both. Any new run must clear it — the
  harness's "Arm the natural warning 3 minutes out" does, via `saveWatcherCache(…, empty)`.
- Simulated backend: `succeeded`, no check-in days → outcome `warnOnline`.
- Device restored: `deviceidle unforce`, `battery reset`, deep and light both `ACTIVE`, 24-hour clock,
  Europe/Madrid, app **not** on the Doze whitelist.
- Tray holds the two warnings from 14:44 plus the 12:00 reminder — left as evidence.
- `firebase_messaging` 16.5.0 was added to the **global pub cache** (`dart pub cache add`) to read its
  Android sources. It is **not** a dependency of this project and `pubspec.yaml` is untouched.
- `tools/doze-collect.ps1`'s `$baselineReconcileAt` and `$armedFor` are still from the first run and
  **must be updated** before reuse. Its store pull uses a PowerShell `>` redirect on binary output;
  prefer `cmd /c "… > file"` or the Bash tool, which are byte-faithful.

## Prompt to start the next session

> I'm continuing Phase 3 of the I Am Ok project. Read `docs/phases/phase-3-review-handover.md`
> first — especially **The Doze problem** (now settled) and **Measurement traps learned on the
> device** — then follow the reading order in `docs/README.md`.
>
> All five reviewers have run at the gate and every finding is fixed. **The Doze question is
> settled:** deep Doze blocks the warning even with a warm process, and the block is a JobScheduler
> gate — `readyNotDozing: false` on `android_alarm_manager_plus`'s `JobIntentService` job, with the
> alarm's own 10-second allowlist covering only the broadcast that enqueues it. Evidence in
> `docs/testing/device-matrix.md`.
>
> **Two things are open, and the first one gates the second.**
>
> 1. **The ADR on §9's scheduled server-side function — the owner's decision, not a quiet edit.**
>    The premise has been measured rather than assumed: the reminder path, whose alarm is identical
>    and whose receiver skips the job hop, delivered at `when=12:00:00` inside the same deep Doze. So
>    **Doze is not the blocker; the hop is**, and there are three options — deliver from the receiver,
>    §9's Function, or accept and surface the deferral. §14's trigger condition ("whether alarms …
>    survive") needs rewording either way, because they do.
> 2. **One step remains unmeasured** and it is the one that would make option 1 cheap: whether a
>    Flutter background engine can be started from the receiver inside the 10-second temporary
>    allowlist, or whether that needs a foreground service under the exact-alarm exemption. Nobody has
>    tested it. Do not assume either way.
>
> **Separately, there is an unfixed defect that is not about Doze at all.** After a warning alarm
> fires while the app process is alive, the alarm isolate closes the UI's sqflite connection —
> `DatabaseException(database_closed 1)` — and the UI's store stays dead for the life of the process.
> Mechanism verified in `sqflite_android` 2.4.3's sources: the plugin keeps a **static**
> single-instance map per process, so the second isolate is handed the *same* connection and
> `warning_alarm_handler.dart`'s `finally { close(); }` closes it under the UI. `local_store.dart:56`
> claims the opposite and is wrong. No test can see it — the suite runs one isolate. Decide the repair
> deliberately; it lands on §4's isolate boundary.
>
> Three things to carry with you. **Verify the measurement before you trust the result** — this
> session's `database_closed` finding was nearly written off as a mis-tap because the harness prints
> its failures below the fold. **Read recent commits at least as harshly as old code.** And this is
> the watcher side, where a false claim to a family is the worst bug the app can have — prefer
> stopping to ask over guessing.
>
> Device state, alarms armed, and the traps that produced wrong answers before right ones are all in
> the handover.
