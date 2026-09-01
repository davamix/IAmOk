# Open questions

Things that are **known, deliberately not settled, and not blocking**. The register exists so they
stop being re-derived at every gate and stop being mistaken for oversights.

**What belongs here:** an honest gap, a decision deferred on purpose, or a risk that has been
measured and accepted. **What does not:** a defect. A defect gets fixed or gets a constraint in
`CLAUDE.md`; parking one here would be this document's own failure mode.

Every row says what would make it a **blocker**, because that is the only thing that decides when it
gets picked up.

**Date:** 2026-08-25 · Opened at the end of Phase 4. · Rows 11 and 12 added at the Phase 5 gate.

---

## Blocking-when — the short version

| # | Question | Becomes a blocker when |
|---|---|---|
| 1 | Announcement API is deprecated on Android | TalkBack stops speaking, or `supportsAnnounce` is enforced |
| 2 | `any → access lost` announcement unapproved | A screen-reader user needs to hear an access failure |
| 3 | `redundant` consumes a drained retraction silently | Never, unless a reader reports it |
| 4 | `warningsShownFor` has no age bound | A long-lived install shows store growth |
| 5 | App Check enforcement + refusal-copy mapping | **Before** App Check is ever enforced |
| 6 | Delete protection and PITR are OFF | **Before the first real user data lands** |
| 7 | ADR-0008 option 1's cost | Before ADR-0008 can be superseded |
| 8 | Phase 7 surfaces for fields already stored | Phase 7 |
| 9 | `ensureVisible` cannot reach a far-down row | Phase 7's multi-person layout |
| 10 | A warning erased by force-stop is not re-posted | Accepted in ADR-0007; never, unless measured harmful |
| 11 | Nothing rate-limits `redeemInvite` guessing | Before App Check is enforced, or if abuse is ever observed |
| 12 | The pairing code's colour pair meets AA, not AAA | If a reader ever mis-transcribes a code, or the palette is retuned |

---

## 1. The announcement API is deprecated on Android, and the app does not check the flag

**Status:** measured working, 2026-08-25, on Android 16 / API 36 with an exactly-matched silent
control. Written up in `testing/device-matrix.md` § *Announcements at API 36*.

**The question.** Flutter's engine sets `NO_ANNOUNCE` unconditionally on Android, so
`MediaQuery.supportsAnnounceOf` is **false on every Android version**, and Flutter's own widgets
branch on it to `Semantics(liveRegion: true)`. `SemanticsService.sendAnnouncement`'s docstring says
to check that flag before calling. This app calls it in three places without checking. It works
today — the engine still dispatches and merely logs a warning at API 36.

**Why it is not being fixed now.** `liveRegion` is **not a drop-in**. The watcher row's footer is
*"This phone last checked Tuesday 10:14."*, which moves on every reconcile, so a whole-row live
region would re-read the row on app open, FCM, alarm and boot — noise on the surface that must stay
trustworthy. Doing it properly means scoping the live region to the status line and re-approving how
each of the three announcements behaves.

**Blocker when:** a device run shows TalkBack no longer speaking, or Flutter starts honouring
`supportsAnnounce` as a hard gate rather than a hint. **Re-run the API 36 measurement at each Flutter
upgrade** — it is twenty minutes and the method is written down.

## 2. `any → access lost` is the last unapproved announcement candidate

`screens.md` drafts *"Update. Can't check on Mum."* and marks it not shipping. The two sibling
directions were approved on 2026-08-25; this one was not.

The *"Update."* objection applies to it as it did to the others — a category label that
differentiates nothing and is the part most likely to survive an interrupt. If it ever ships it
should reuse the row's second line too, because a message whose whole justification is actionability
must not be truncated to the half that says nothing.

**Blocker when:** a screen-reader user needs to be told about an access failure while the list is
open. Until then `rowKind` keeps it structurally out — an access failure is `accessLost`, never
`warning`, so neither shipped announcement can reach it.

## 3. A drained retraction under `redundant` is consumed with nothing said

Recorded on `WatcherReconcileResult.shouldPostCorrections` and in `screens.md`.

When a held retraction is drained while the reader is on the list, the row was **already** correct
before that reconcile — so nothing changes under them, `checkedInSince` cannot fire, and the day is
consumed with no *"Correction"* on any channel. Nothing false is said: the row reads *"Everything
OK"* above the dated last check-in. But the `redundant` argument here rests on *the row shows the
settled truth* rather than *the reader watched it change*, which is a real difference for someone who
cannot see the row.

**Blocker when:** never, on its own. Revisit if the alternative is ever wanted — gating the drain of
a *previously owed* day on `postsNotification` — which trades this silence for a notification to
someone already reading the answer.

## 4. `warningsShownFor` has no age bound

`correctionsOwedFor` was bounded on 2026-08-25 to ADR-0009's seven-day catch-up window. Its sibling
was not: a day enters `warningsShownFor` when a warning is delivered and leaves only by correction or
revocation. A watched person who genuinely missed days that are never later confirmed leaves rows
there for ever.

It is **not** the same defect the bound fixed — nothing stale is ever *said*, because a day below
ADR-0009's floor is never decided about again. It is unbounded storage, and a slow leak on a
long-lived install.

**Blocker when:** a real install shows the table growing without limit. The fix is the same floor
applied in the same place.

## 5. App Check enforcement, and the refusal-to-copy mapping underneath it

Two things, and the second gates the first.

**Enforcement is structurally gated**, not a metrics decision: Play Integrity requires the app to be
known to Google Play, so it cannot work before an internal test track exists. Phase 8 or later.

**Before it is ever enforced**, `_mentionsAppCheck` must be verified against a real rejection on
hardware. It matches an English substring, and anything unrecognised falls through to *"your phone
has been offline"* — a false claim about the device, and §17's fleet-wide false alarm arriving
through the copy layer. The live-radio measurement will be the first run to exercise App Check on a
cold radio; register this install's debug token first (confirmed **not** registered) or it measures a
retry loop.

> **There are TWO call sites since Phase 6, not one**, and this entry named one until the gate
> caught it. `FirestoreCheckInReader._mentionsAppCheck` is the watcher's read;
> `AwayRepository._mentionsAppCheck` is the watched person's own away read, added when this phase
> gave the client a second Firestore path — and Firestore-level enforcement affects both. Verifying
> one and enforcing on the strength of it leaves the other falling through to a claim about a device
> that is online. **Either verify both, or hoist the predicate into one shared classifier** — the
> second is cheaper and is what makes this entry's own instruction unambiguous.

**Blocker when:** before enforcement, absolutely. Not before.

## 6. Delete protection and point-in-time recovery are both OFF

`deploy-notes.md` says decide both before the first real data lands. Neither is on.

**Blocker when:** **before the first real user's data exists.** This is the one item on this list
with a hard, external deadline, and it is cheap to do — put it in Phase 8's checklist rather than
leaving it here to be found late.

## 7. What ADR-0008 option 1 actually costs

The only open **design** decision in Phase 4. Replacing or forking `android_alarm_manager_plus` so
the warning uses the allowlist its own receiver already holds instead of handing the work to
JobScheduler. The owner asked for the number before any ADR is drafted.

ADR-0008 says that if both its questions passed it "should be superseded rather than amended". The
measurement half is done and both passed. The alternative — un-deferring §9's scheduled function —
is unchanged and is not a cost question: ADR-0007's objection is that a server deciding "no check-in"
cannot see the watcher's local away cache, so §10's verify-before-speaking design would have two
deciders and could give two answers about whether someone's relative is all right.

**Blocker when:** before ADR-0008 can be superseded. Not before Phase 5, 6 or 7.

## 8. Fields stored for a surface that does not exist yet

**Two of the four grew surfaces and this entry did not notice — corrected 2026-09-01.**

| Field | State |
|---|---|
| `uses_24_hour_clock` | **Surfaced.** Every time on the watcher list renders in the device's own 12/24-hour setting; seen on hardware 2026-09-01 — *"10:43 am"* on the AVDs, *"11:37"* on the POCO |
| `link_reconcile_failed` | **Surfaced.** `WatcherState.unreconciled` renders its own rows beneath the people, with *Try again* |
| `warning_alarms_exact` | Written by the watcher reconcile, read by `dump()` alone |
| `WatchedPersonState.zoneUnknown` | Carried through the service, rendered nowhere |

The last two are what §13's device-health panel consumes in **Phase 7**. Carried deliberately from
Phase 3; all four have store round-trips and behavioural coverage.

**And one row of §13 is not "stored, awaiting a surface" at all:** *clock skew* has **no
implementation**. `ClockService` has two members, neither of them skew, while ADR-0002 (twice),
ARCHITECTURE §11 and the architecture skill all describe it as doing device-versus-server skew
detection. The only skew *signal* that exists is `receivedAt` beside `deviceTappedAt` on a check-in,
and nothing compares them. Found while writing the Phase 7 brief.

**Blocker when:** Phase 7.

## 9. `ensureVisible` cannot reach a row far down a long list

A lazy `ListView` never builds it, so its key has no context and nothing scrolls. Mitigated with a
cache extent. The real answer is fixed extents or a positioned list, and belongs with **Phase 7**'s
multi-person layout. The code says so rather than implying it handles any distance.

Related and permanent: **Flutter has no supported way to move the screen reader's cursor** to an
arbitrary widget. The tapped row is announced instead.

**Blocker when:** Phase 7.

## 10. A warning erased by a force-stop is not re-posted

`warningsShownFor` says it was shown, so the next reconcile does not raise it again. Accepted and
recorded in **ADR-0007 decision 4** — a force-stop is silent and total, and the alternative (ignoring
the ledger) re-posts warnings a family has already read and acted on.

**Blocker when:** only if measured to matter in practice. It is a recorded acceptance, not a gap.

## 11. Nothing rate-limits guessing at `redeemInvite`

Added at the end of Phase 5, when pairing became real.

**The arithmetic, and the rate it depends on.** A code is 6 characters from a 32-character
alphabet — 32^6 ≈ **1.07 billion**. Codes are single-use and live for **24 hours**, and at family
scale a handful exist at any moment.

That was the whole of this entry until the Phase 5 review, and it has **no rate term in it** — which
is the half that decides whether the conclusion holds. `setGlobalOptions` gives every function
`maxInstances: 10`, and the 2nd-gen default is `concurrency: 80`, so deployed as written
`redeemInvite` would have accepted **800 concurrent** guesses. At that throughput the expected time
to a first hit falls *inside* one code's lifetime rather than outside it, and the acceptance below
would have been resting on a number that was never true.

`redeemInvite` now carries `concurrency: 1, maxInstances: 3` — roughly fifteen attempts a second,
which costs a family nothing on a once-per-relationship call and is what makes the arithmetic above
mean what it says. **That cap is now load-bearing: do not raise it without redoing this sum.**

**What a hit costs, stated properly.** An earlier version of this entry said *"the callable never
returns a uid, so the blast radius stops there"*. Both halves were wrong.

- On success `redeemInvite` returns `linkId` = `{watchedUid}_{watcherUid}`, so the attacker **does**
  get the watched person's uid — necessarily, since it is what makes their check-ins readable. §9's
  actual rule is that no client learns a uid *out of an invite*, and that holds: every refusal
  returns a bare status.
- The blast radius does not stop at check-ins. `firestore.rules` grants an accepted link **read on
  `users/{watchedUid}/shared/away`** — *this specific home is empty between these two dates*, which
  the threat model rates High by inference — and **write** on it too. So a guessed link lets a
  stranger set a ~32-day away period, which suppresses the missed-day warning for **every** watcher,
  renewably. That produces silence rather than a false alarm, which is the direction this app cannot
  detect in itself.

**What limits it.** The new watcher appears **by name** on the watched person's Tap screen
(ADR-0005), and either party can revoke. Both are real, and neither is automatic.

> **Updated at the Phase 6 gate, 2026-08-27.** The away half now has surfaces, and they cut both
> ways. A stranger with a guessed link can reach the away write from a **screen** rather than only
> from an API call — which is what this entry warned about — and at the same time the watched
> person's own Tap screen now reads *"X marked you away until Saturday 22"* on the screen she opens
> every morning.
>
> **What that line shows is the label the writer chose, and ADR-0003 says it is not
> authenticated.** The detection it buys is *"somebody marked you away"*, not *"this person did"* —
> an attacker holding a guessed link picks the string, and can write a plausible relative's name.
> `setBy` is the identity that survives a dispute, and nothing renders it; there is no path from a
> uid to a real name on that screen, and §7 deliberately keeps one from existing.
>
> So *"nothing anywhere says this happened"* is no longer true, which was the sharper half of the
> risk, and *"and it names who did it"* was never true. Both are stated because the mitigation
> argument rests on the second one.

**A cheap counter was considered and not built.** It is a Firestore document per uid on the pairing
path, with contention and its own failure modes, for a threat the concurrency cap now bounds.

**The designed control is App Check enforcement**, which row 5 records as structurally gated on the
app reaching an internal test track. **For a 2nd-gen callable that is a code change, not the console
toggle row 5 describes**: enforcement is `enforceAppCheck: true` in the `onCall` options, deployed
from this repo. Neither callable sets it today, which is correct — enforcement must not precede a
verified client — but "fold it into that work" is not zero effort, and flipping the console switch
alone would leave both callables open while the register said the control was on.

**Blocker when:** before App Check is enforced — and note that for these two callables that means a
code change plus a Functions deploy, not only the console — or immediately, if abuse is ever
observed. `redeemInvite` logs the outcome and the
caller's uid on every call, so the evidence exists to notice.

## 12. The pairing code is measured at AA, and it is the string most read aloud

Added at the Phase 5 gate, when `contrast_test.dart` measured the two pairs it had never covered.

**The numbers**, 2026-08-26, WCAG 2.x, from the palette the app actually ships:

| Pair | Light | Dark | Where |
|---|---|---|---|
| `onPrimaryContainer` / `primaryContainer` | **5.18** | **6.62** | the six-character code itself |
| `onSecondaryContainer` / `secondaryContainer` | **5.19** | **6.62** | *Share this code*, the watcher list's empty-state button |

**Both clear the floor `guidelines.md` sets**, which is AA (4.5) for all text and AAA (7.0) for the
tap target and any warning, **by name**. So this is not a failure — it is a measured fact with a
question attached to it.

**The question.** The code block is neither the tap target nor a warning, so AAA was never required
of it. But it is the one string in this app that is **read aloud across a table and transcribed into
another phone**, by an elderly person to a family member or the reverse, once, with no way to ask the
screen to repeat itself. A mis-read character fails with *"That code is not right. Check it and type
it again."* — which sends them back to the same characters. §7's alphabet already removes the
confusable glyphs it can (`O`, `0`, `I`, `1`); contrast is the other half of the same concern.

**Not fixed here, deliberately.** Raising it is a **palette change** to an approved theme, which is
the owner's call and not an implementation detail — and the test now asserts the documented floor
rather than one invented by its own assertion, which is what a test that enforced AAA would be.

**Blocker when:** a reader mis-transcribes a code in practice, or the palette is retuned for any
other reason — at which point this pair should be raised at the same time rather than measured again
later. Phase 7's UI pass is the natural home.

---

## How to use this file

- **At a phase gate:** read the *Blocking-when* table. Anything whose trigger the phase crosses
  stops being an open question and becomes work.
- **When something here becomes a defect** — a measurement fails, a user reports it — take it out of
  this file and give it a commit, a test and, if it was paid for by a real failure, a line in
  `CLAUDE.md`.
- **Do not add speculation.** Every entry here is either measured, decided, or explicitly carried
  from a review. An open question nobody has actually run into belongs in the design docs as a note,
  not here.
