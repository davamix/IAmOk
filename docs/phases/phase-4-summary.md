# Phase 4 — Firebase backbone · summary

**Date:** 2026-08-25 · **982 Dart tests**, **30 Functions tests**, `flutter analyze` clean, secrets
guard clean.

**Status: implemented and reviewed at the gate. All five reviewers have run and every finding is
fixed or recorded.** **Not signed off.**

**Both owner-approved changes are built and proven on the POCO F3** — a push may not post a warning
before `warningLocalTime` ([ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md)),
and a row that changes under a screen reader is announced. Both device runs were the condition of
their approval and both passed on 2026-08-25, and the three reviewers whose scope the post-gate
diff touched have since run over it again.

**That round left three things open. All three are now closed** — the Android 16 announcement risk
was measured and is **false as stated**, the correction the hour-gate dropped is now **held**, and the
copy decision it blocked was **approved by the owner and built**. What each turned out to be, and the
one thing each cost that was not in the plan, is in *The post-gate review round*. Start at *Prompt to
start the next session*.

---

## The one-line story

Steps 4–7 landed: a Cloud Function that fans out a data-only push, FCM in all three isolates, App
Check in monitoring mode, and ADR-0008's deciding measurement — **which passed both its questions**.

Then five reviewers found nine things worth fixing, and the pattern is the same one this phase
started with. **Almost every finding was a claim that had stopped being true**: a docstring
promising failure isolation the code did not have, a deploy checklist asserting an API was disabled
when it was enabled, a copy table handing implementers a pronoun the app deliberately removed, a
threat model naming a control the Function refuses to implement. None was found by a test failing.
All were found by reading something against the thing it described.

The sharpest was aimed at this phase's own headline result: **the deciding measurement could have
been faked**, by exactly the false green the phase had already produced once.

---

## What was built

| Step | What |
|---|---|
| **4 — `onCheckInCreated`** (`e030fea`) | `europe-west1`, data-only, **high priority**, one collapse key, 24 h TTL. Reads accepted links, collects every watcher's tokens, sends, and prunes what FCM reports `UNREGISTERED`. Not deployed. |
| **5 — FCM in all three isolates** (`e1d0491`) | `firebase_messaging`; token registered on sign-in and on rotation; `pushBackgroundHandler` as §4's **third** entry point, reconciling both sides. |
| **6 — App Check** (`3f012f0`) | Monitoring mode, activated from `FirebaseBootstrap` so all three isolates attest. Protects nothing yet, deliberately. |
| **7 — ADR-0008's revisit** (`0063888`) | Run as a measurement, not a tick. Both questions passed. |

Five review rounds followed: `39764d9` architecture, `d322a12` security, `df586e7` testing,
`fcca7b2` infrastructure, `43cd1b2` UI/UX.

Then the two changes the reviews produced and the owner approved, both built **and proven on the
POCO F3** on 2026-08-25:

| Change | What |
|---|---|
| **ADR-0010 — a push may not post a warning early** | `WatcherDelivery.notBefore` downgrades the **warning** channel to `unavailable` until `now >= warningLocalTime` in the watcher's zone. Suppresses the post; leaves the day owed, the alarm armed and the row honest. Access-lost is not gated; corrections are, and that is recorded as a decision. |
| **A row that changes under a screen reader is announced** | `WatcherState.userInitiated` (false only for a foreground push) plus `WatchedPersonState.checkedInSince`, which asks the **cache** whether the warned day is now confirmed rather than inferring it from the row going quiet. One approved string; the two candidates in `screens.md` still do not ship. |

---

## ADR-0008's deciding measurement — both questions passed

POCO F3, stock power settings, app **killed**, device in **forced deep Doze** (`get deep` = `IDLE`
at every sample). The platform names the reason itself:

```
UID=10612: +19s744ms - broadcast:…c2dm.intent.RECEIVE,reason:high-prio FCM
```

**Mutation-checked, which is the part that makes it mean anything:**

| `priority` | allowlist | process | `last_reconcile_at` |
|---|---|---|---|
| `'high'` | granted ~20 s | yes | moved |
| `'normal'` | **never**, polled every 2 s for 40 s | **none** | **0 ms** |
| `'high'` restored | granted ~20 s | yes | moved |

Latency check-in → reconcile *starting*: **3–10 s** across runs, against a ~20 s grant. The spread is
FCM **delivery**, not the engine — the allowlist appeared at +2 s in one run and +8 s in another.
Quoting the best number alone would suggest more headroom than there is.

Also measured, because the review asked and the code had only assumed it:
`android_alarm_manager_plus` **does** work from `firebase_messaging`'s engine. Proven by moving the
device's debug clock forward a day while the app was dead, pushing, and reading `dumpsys alarm`: the
7-day window came back at **new dates**. Read from the platform's record, not the app's.

**What it does not settle.** The Firestore read went over `adb reverse` — loopback, not a radio — and
loopback is ordinarily exempt from Doze's per-uid rules. The allowlist grant was directly observed,
which weakens that but does not close it. Closing it needs the same run against the **live** project.

Full write-up, method, and both caveats: [../testing/device-matrix.md](../testing/device-matrix.md).

---

## The nine findings, and what each cost

Ranked by what they would have cost if shipped, not by when they were found.

**1. A token document could outlive the account.** `signOut()` guarded on `selfUid`, the
*launch-time snapshot*, so signing in and out without restarting **skipped the unregister entirely**
— the one case it exists for. Worse, both docstrings claimed `UNREGISTERED` pruning as the backstop,
and there is none: the orphaned row's token is still *valid*, so FCM returns success and **delivers**
another family's check-ins to a phone that has since signed into a different account. A failed
delete now invalidates the device token, which is what makes the claimed backstop true.

**2. The deciding measurement could have been faked.** `DebugBackendOverride` sits in front of the
real reader in a debug build and stamps `lastReconcileAt` with no socket involved — precisely the
leftover-harness-row false green this phase already produced. The row *was* absent, and nothing said
so. The script now refuses to run unless the pulled database shows it absent and the clock offset
zero, and prints both beside the result so the evidence carries its own disproof.

**3. The FCM handler had no failure isolation and its docstring said it did.** `await A; await B;`
is exactly a watcher-side failure skipping the watched side. Now `try`/`finally`, extracted as
`runBothSides` so the property is four assertions rather than a source lint that would pass with the
order swapped.

**4. A push can post a warning at any hour — measured, at 00:24.** `warningLocalTime` bounds when
the *alarm* asks, not when a warning may be posted. **Decided and now built** —
[ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md). The warning
channel is handed `NotificationDelivery.unavailable` before the reader's hour, which is the one
substitution that suppresses the post while leaving the day **owed**: nothing recorded, ADR-0009's
pointer not advanced, the 10:00 alarm still armed. Held at 07:49 and spoken at 08:01 on the POCO
F3 the same day.

**5. The deploy checklist asserted the opposite of the truth.** `deploy-notes.md` still said
`functions:list` returns `SERVICE_DISABLED`; it has been enabled since 2026-08-21. That is the file
someone reads immediately before the first deploy.

**6. `npm test` tested a git-ignored artifact with no build step** — module-not-found on a fresh
clone, and **stale compiled code** after editing `src/`. `"pretest": "tsc"`.

**7. The copy table handed implementers a removed pronoun.** The skill still said *"She was marked
away"* and *"her check-ins"* — the wording the Phase 3 gate removed because a watched **father** was
getting the wrong word.

**8. The pruning fake could not falsify the thing that decides whose token dies.** It resolved
outcomes by token, so it produced the right answer under any mapping. A position-keyed sender now
fails for anything not order-preserving; mutation-checked.

**9. A foreground push cleared *"That did not save. Please tap again."*** Nothing became false — she
lost the one instruction telling her what to do, with no user action, on the screen this app exists
for.

---

## Decisions taken this phase

**Only `registration-token-not-registered` prunes a token.** `messaging/invalid-argument` is the
tempting second candidate and is a trap: FCM returns it for a malformed *message* too, so pruning on
it would deregister every watcher in the fleet from one bad deploy, silently. Verified against the
SDK sources rather than assumed.

**No token is ever skipped for being stale.** §13's watcher — the one who never opens the app — owns
the stalest token by definition, so an age filter would silence exactly the person FCM is in this
design for.

**One collapse key for every check-in nudge.** FCM keeps four per device and drops the rest
unspecified. A single key can never drop anything, because a delivered nudge reconciles *all* of a
device's links rather than the one named in the payload.

**The background handler reads nothing out of the message**, enforced by counting occurrences of the
identifier. The payload looks exactly like the answer the reconcile is about to fetch; trusting one
field would let a forged push move `lastConfirmedDay` for a day nobody tapped.

**Both sides reconcile on a nudge**, not the half Phase 4's only push is about — §3 says a nudge
carries no authority about what it concerns, and Phase 6's away nudge lands on the watched side.

**App Check ships before it enforces.** Enforcing before clients attest refuses every read, which
ADR-0004 maps to *refused*, which is the access-lost notice arriving at every family at once.

---

## Owed to the owner — one decision left, and it is not a measurement

**1. ADR-0008's successor.** The ADR says that if both questions passed it "should be superseded
rather than amended". The measurement half is done. The choice is not:

- **Option 1, deliver from the receiver** — now demonstrably viable for the FCM path, but the
  warning is armed by `android_alarm_manager_plus`, and what makes it late is that the plugin hands
  its work to JobScheduler instead of using the allowlist its own receiver was granted. Taking this
  means replacing or forking that plugin, on the path where a false or missing warning matters most.
- **Option 2, un-defer §9's scheduled function** — ADR-0007's objection is unchanged and is not a
  cost question: a server deciding "no check-in" cannot see the watcher's local away cache, so §10's
  verify-before-speaking design would have two deciders and could give two answers about whether
  someone's relative is all right.

**2 and 3 were DECIDED — 2026-08-25 — and are now BUILT and PROVEN on hardware.** A push may not post
a warning before `warningLocalTime` (ADR-0010), and a row that changes under a screen reader is
announced — **both directions** now, the second approved on 2026-08-25 after the API 36 measurement
unblocked it.

**Option 1's cost — item 1 above — is the only design decision still open**, and the owner asked for
the number before any ADR is drafted.

---

## Proven on the device — 2026-08-25, 07:44–08:14

Both changes were approved on the condition that they be shown on hardware. Both were.

**ADR-0010.** Real clock, `debug_clock_offset_ms` = 0 and `debug_simulated_backend` absent — read out
of the pulled store on both sides, so the override that could have faked this was provably not in the
path. A real high-priority FCM push woke a **cold** process (`pidof` empty before, 6206 after) at
07:49; `last_reconcile_at` moved, so the isolate ran and the read succeeded; and **nothing was
posted**, with the day absent from `warnings_shown`, `last_decided_day` still below `D`, and today's
alarm still armed. The same store then posted *"No check-in from Granddad yesterday."* at **08:01**,
when the alarm reached the watcher's own hour. **Late, never lost, measured.**

The instrument was `warningLocalTime` itself, not a forced clock — a second watched person linked
with the warning time ahead of the real clock, then moved — so the only difference between the held
run and the spoken one is the hour.

**The announcement.** With TalkBack running, a foreground push flipped a row from *"No check-in from
Pop yesterday."* to *"Everything OK…"* (read out of the accessibility tree) and TalkBack took speech
audio focus 1.7 s later. **The control is what makes it evidence:** a second push that changed no row
produced no speech at all. Repeated once with the same result.

**Two limits, recorded rather than glossed.** Forced deep Doze could not be entered on HyperOS —
`deviceidle force-idle` stops at `INACTIVE` because a screen-off device sits in `Dozing` wakefulness
with `DreamManagerService` holding a `DOZE_WAKE_LOCK`; Doze is not what ADR-0010 turns on, and
ADR-0008 already established the wake-up. And TalkBack does not log utterance **text** at its default
level, so the device shows *spoke / did not speak*, while the words are pinned in
`watcher_screen_test.dart`.

Full method, tables and three HyperOS traps: [../testing/device-matrix.md](../testing/device-matrix.md).

---

## The post-gate review round — 2026-08-25, and the three things it left open

The five reviewers ran at `43cd1b2`. Everything after that — the two approved changes, the device
runs, and the docs around them — had never been reviewed, so three of the five ran again over the
post-gate diff: **architecture** (`88124cc`), **testing** (`8784edb`), **UI/UX** (`589cc71`).

**Security and infrastructure were deliberately not re-run.** The diff touches no `.gitignore`, no
`firestore.rules`, nothing under `functions/`, no Firebase config and no Android build file — which
is exactly what those two agents' trigger conditions name. Recorded so the absence reads as a
decision rather than an oversight.

They found the usual thing: claims, not test failures. The gate itself was traced branch by branch
and holds. Fixed in those three commits, and worth knowing about:

- The **gate moved into the domain** as `WatcherDelivery.notBefore`, beside `NotificationDelivery.from`,
  whose docstring already set the precedent — *"the branch order is a decision, not plumbing"*. Zero
  behaviour change, call site unchanged, mutation-checked after the move.
- **The gate's zone was never the watcher's in any test.** Every link was `Europe/Madrid` watched by
  a device cached as `Europe/Madrid`, so an implementation resolving the hour against
  `link.tryWatchedZone` — which does not throw — passed all 924 tests. That is ADR-0010's own
  headline defect restored in a new costume.
- **`checkedInSince`'s day comparison was never evaluated.** Mutating it to `return confirmed != null;`
  passed the entire suite, because the test written to prove it used a person who had *never* checked
  in. Under that mutation TalkBack says *"Mum checked in. Everything OK."* about a day she was away
  and did not tap.
- **An unsolicited pass that threw replaced the reader's list with an error page.**

Three things were **not** fixed then. **All three were done on 2026-08-25**, in the order below, and
each is recorded with what it actually turned out to be — which in two cases was not what the plan
said.

---

### 1. `SemanticsService.sendAnnouncement` on Android 16 — MEASURED, and the claim is false as stated

**Settled 2026-08-25 20:04 on the `Medium_Phone_API_36.0` AVD.** Announcements still reach TalkBack
at `targetSdk 36`. Neither shipped feature is silent, and item 3 stayed a copy decision.

Dispatch to TalkBack speech focus to TTS synthesis inside **8 ms**, twice, with the platform naming
its own API level in the middle of the chain (`sdk=36` on the audio-focus line). The **control was
exact**: the same `am start -a SELECT_NOTIFICATION` against the same activity, differing in one
string — a payload naming no link, which makes `_onTapped` return at its `index < 0` guard — produced
**zero** dispatch, zero focus, zero synthesis, twice. Replicating the notification's own intent is
what made an exactly-matched pair possible at all; a finger on the shade changes the window as well
as the payload. The premise was read from `dumpsys package` (`targetSdk=36` on the **installed** app)
rather than from `build.gradle.kts`, because the premise is what the measurement is about.

**Two things the original write-up got wrong, and both matter more than the pass.**

- **`targetSdk` was never the trigger.** The deprecation is on Android's *behavior changes: **all
  apps*** page, not the *apps targeting Android 16* page. It applies by **OS version**, whatever the
  app targets — so pinning `targetSdk` at 35 would not have avoided it, and the section below says it
  would.
- **Flutter already reports this API as unsupported on Android — on every version.** The engine sets
  `NO_ANNOUNCE` unconditionally, so `MediaQuery.supportsAnnounceOf` is **false here and always has
  been**, and Flutter's own widgets branch on it to `Semantics(liveRegion: true)`.
  `sendAnnouncement`'s docstring says to check that flag before calling; this app does not. The
  engine still dispatches, and logs a warning while doing it.

So the finding is not *"the risk was imaginary"*. It is *"the mechanism works today, and both the
platform and the framework have said in writing not to rely on it"*. `liveRegion` is **not** a
drop-in: the row's footer is *"This phone last checked Tuesday 10:14."*, which moves on every
reconcile, so a whole-row live region re-reads the row on app open, FCM, alarm and boot. Scoping it
to the status line is the work if dispatch ever stops.

Full method, tables and both caveats: [../testing/device-matrix.md](../testing/device-matrix.md),
*Announcements at API 36*.

<details>
<summary>The original write-up, kept because it is what the measurement was run against</summary>

### 1. `SemanticsService.sendAnnouncement` may be a no-op on Android 16 — CHECK THIS FIRST

**The claim.** Android 16 stops dispatching accessibility announcements (`TYPE_ANNOUNCEMENT` /
`announceForAccessibility`) for apps targeting **API 36**, with live regions as the replacement.

**What is confirmed:** `targetSdk = 36` in `android/app/build.gradle.kts:55`. **What is not:** the
behaviour itself. The 2026-08-25 device run that proved the announcement works was on the POCO F3 at
**API 33**, where it demonstrably speaks.

**Why it is first.** If it is real, **two** shipped features are silent on current Android and
nothing in the app or the suite can see it: `WatcherCopy.checkedIn` (Phase 4) and
`WatcherCopy.showingPerson` (Phase 3, the screen-reader half of the notification-tap path, which
`screens.md` promises when the notification says *"Open the app to see what to do."*). The widget
tests assert the platform message is **sent**, which is the same distinction `CLAUDE.md` already
draws: the app's record of what it dispatched is not evidence of what the platform did with it.

**How to settle it.** The `Medium_Phone_API_36.0` AVD already exists (`~/.android/avd/`). Install a
debug build, enable TalkBack, open the watcher list on a person with a standing warning, and drive a
row change — the method that worked on the POCO is in `device-matrix.md` § *A row that changes under
a screen reader*. Evidence is TalkBack taking speech audio focus (`MediaFocusControl` for
`USAGE_ASSISTANCE_ACCESSIBILITY`), plus a control push that changes no row and must produce silence.
**Confirm the current wording of Android 16's behaviour-changes page rather than trusting the
summary above.**

**If it is dead**, the structural replacement is `Semantics(liveRegion: true)` on the row (Flutter
3.47 supports it), which makes the row **re-read itself** when its label changes. That is a better
fit than an announcement in any case: per row, no separate approved string, and it covers **both**
directions of change — which is why item 3 below is blocked on this one.

</details>

---

### 2. ADR-0010 drops the retraction, not just the hour — FIXED, and the plan's own premise was wrong

**Built 2026-08-25.** `withCorrectionFor` now takes `delivered` — the same
`delivery.warning.consumesReminder` predicate the warning path uses. The tray still empties
immediately, `lastConfirmedDay` still advances ungated, and an undeliverable day is kept so the next
postable pass says the already-approved sentence. Six mutations, each of which fails. ADR-0010's
*Consequences*, `screens.md` and two docstrings amended: all four asserted the sentence *"is what is
given up"*, which was the defect rather than the design.

**The one thing the design below got wrong is the thing it told the next session to prove rather than
reason about.** *"No new cache column — the day simply stays in `warningsShownFor`"* does not work.
That map is the **sole input to the watcher row's warned state** (its own docstring says so), so a
day kept there after its warning was cancelled makes the row render *"No check-in from Mum
yesterday."* about a day the same cache has just recorded a check-in for. The paragraph below reasons
that `decision.day` has always moved past the corrected day by then; that holds for the hour-gate
case and **fails for the muted one**, where the corrected day is still the most recently completed
day for up to fourteen hours. A false claim about a person, produced by the fix for a lost sentence —
and it would also have broken the invariant `watcher_reconcile_service.dart` relies on to stop a
correction overwriting a fresh warning at the same id.

So it is a separate field, `WatcherCache.correctionsOwedFor`, with schema v5 — additive and
idempotent, on the established pattern. The ledger and the retraction are two facts and are stored as
two. Everything else in the design below shipped as written: no new copy, no new enum state, and all
four rows of the truth table hold.

<details>
<summary>The original design, kept because the reasoning is still the reasoning</summary>

### 2. ADR-0010 drops the retraction, not just the hour — APPLY THE FIX BELOW

**The defect.** Two lines, different files, opposite policies.

The **warning** path gates the ledger write on delivery — `watcher_reconciler.dart:668`:

```dart
final recorded = owed && delivery.warning.consumesReminder;
if (recorded) next = next.withWarningShownFor(each.day, each.outcome);
```

The **correction** path clears the ledger unconditionally — `watcher_reconciler.dart:476`:

```dart
for (final day in cache.warnedDays.toList()) {
  if (confirmed.contains(day)) {
    corrections.add(Correction(linkId: link.id, day: day));
    next = next.withCorrectionFor(day);      // <- no delivery check at all
  }
}
```

`shouldPostCorrections` is not computed until line 730, long after the day has left `warnedDays`.
So under the hour-gate: `cancelWarning` fires (right — the false claim leaves the tray), the day is
dropped, and **nothing anywhere records that a retraction is owed**. The next pass computes
corrections from `cache.warnedDays ∩ read.checkInDays`; the day is not in `warnedDays`; nothing is
emitted, ever.

**The reachable path.** Mum taps at 23:50 on `D` in a dead zone; the write queues. At 10:00 on
`D + 1` the alarm reads successfully, sees nothing for `D`, and posts *"No check-in from Mum
yesterday."* The family phones. The write later syncs. Before 10:00 on `D + 2` — 00:24, say — a push
arrives because somebody **else** in the family tapped early, the read now returns `D`, the
correction is held, the warning is cancelled and the day is dropped. At 07:00 the family finds an
empty tray and cannot tell *resolved* from *I swiped it in the night*. The push is what discovered
the good news, and the gate is what threw the sentence away.

Narrow — it needs a check-in that syncs 24–34 hours after its day ended, found by a pre-hour
reconcile, which in practice means a push. But it is exactly the *"she was fine all along"* case,
which is the one the correction exists for. The **row** still tells the truth; `guidelines.md`'s
whole premise is that this reader does not open the app.

**The fix: gate the ledger removal exactly as the warning path gates the write.** No new cache
column, no migration, and no fourth enum state — which matters, because *"do not invent a state"* is
ADR-0010's own load-bearing argument and it should not be spent here.

Split what `withCorrectionFor` does today:

- **`lastConfirmedDay` stays ungated.** It is evidence about *her*, not a delivery record — the same
  argument that keeps `accessLostSince` ungated. It is belt-and-braces anyway: `applyRead` already
  advances it monotonically from the read (`watcher_cache.dart:208-222`).
- **Dropping the day from `warningsShownFor` is gated on `delivery.warning.consumesReminder`** — the
  identical predicate the warning path uses.

| Delivery | Tray | Ledger | Result |
|---|---|---|---|
| `available` | correction posted | day dropped | unchanged |
| `redundant` | cancelled silently | day dropped | unchanged — the reader is on the row, and *seeing it on screen is being told* |
| `unavailable`, muted | cancelled silently | **day kept** | spoken when notifications come back |
| `unavailable`, **held by the hour** | cancelled silently | **day kept** | **spoken at the warning time** |

The false claim still leaves the tray immediately — that half is load-bearing and does not change.
What changes is that the retraction stays **owed**, so the next postable pass emits the
already-approved *"Correction: Mum did check in on Saturday 15 August."* `correctionBody` already
handles a day that is not yesterday, so **no new copy is needed**. It also fixes the muted case as a
side effect, which is the same defect on a different phone.

**The one thing to prove rather than reason about.** Keeping a day in `warnedDays` feeds
`standingWarning`, which the row renders. It *looks* safe — by the time a correction is held,
`decision.day` has moved past the corrected day, so the row renders a different key — but that is
exactly the kind of paragraph this gate keeps finding to be wrong. Assert it.

**Rejected alternative**, recorded so it is not re-argued: leave the false warning *standing* in the
tray so the next pass replaces it at the same id (which is what `guidelines.md` literally requires of
a correction). Cheaper, no ledger change — and it parks a claim the device **knows is false** on a
family's phone from 00:24 to 10:00. If they wake at 07:00 they read *"No check-in from Mum
yesterday."* about a day she checked in on. The version above is honest at every instant.

**Also owed:** an amendment to ADR-0010's *Consequences*, which currently says the retraction's
sentence *"is what is given up"* — true today, false once this lands.

</details>

---

### 3. The OK → warning announcement — APPROVED by the owner 2026-08-25, and built

Item 1 passed, so this stayed a **copy** decision. The owner approved the UI/UX review's suggestion:
the warning body **verbatim** — *"No check-in from Mum yesterday."* — already-approved copy that
names the person in its first four words, which is the same move `checkedIn` makes when it reuses
`everythingOk`. The drafted *"Update. Mum. …"* was rejected for the reasons recorded below.

`WatchedPersonState.warnedSince` is the mirror of `checkedInSince` and needs **no** evidence check,
because it speaks the row's own claim back word for word rather than making a new one about her. The
string comes from `_statusFor` — extracted so the row and the announcement compute it **once** —
which is `NotificationCopy.warningBody`, the same sentence the notification would have carried. The
footer is deliberately not spoken with it: *"This phone last checked Tuesday 10:14."* is a fact about
this device's effort, not a claim about her, and it is not what changed. Five mutations, each of
which fails.

**The narrower gap that remains, recorded rather than glossed.** The same-day guard `checkedInSince`
uses is kept, so a row that turns bad at watched-local **midnight** is not announced. Dropping it
would speak a warning at 00:24 unasked, which is what ADR-0010 exists to prevent; the reader having
the list open makes that arguable rather than settled, and it is a policy question rather than the
copy one that was approved.

*any → access lost* is **still unapproved** and still does not ship. `rowKind` is what keeps it out
rather than a guard in the widget: an access failure is `accessLost` and never `warning`, so neither
announcement can see it — asserted on both.

<details>
<summary>The original framing, including why it waited for item 1</summary>

### 3. The OK → warning announcement — DECIDE AFTER 1, NOT BEFORE

**The gap.** With the list open **and TalkBack running**, a push records the day as seen
(`redundant` — working as designed), the row silently changes from *"Everything OK"* to a warning,
the announcement correctly declines because that direction is unapproved, and the alarm then finds
the day settled and says nothing. Nothing posted, nothing spoken, day consumed.

**How it relates to item 2 — two holes in one matrix, and neither fix closes the other.** Both are
instances of one rule: *the app may only record something as communicated if it actually was*. Item
2 is `unavailable`'s claim being ignored; item 3 is `redundant`'s claim resting on a premise that is
false for a reader who cannot see the row change. `notBefore` returns early on `redundant`, so **the
hour never applies while the list is showing** — the two cannot overlap:

| | Reader **on the list** (`redundant`, any hour) | Reader **elsewhere**, before the hour (held) |
|---|---|---|
| **Correction owed** (row gets better) | announced — `checkedIn`, shipped 2026-08-25 | **item 2** — cancelled, sentence lost |
| **Warning owed** (row gets worse) | **item 3** — recorded as seen, nothing spoken | held, day stays owed, alarm speaks |

Item 2 affects **every** watcher; item 3 affects only screen-reader users, because a sighted reader
genuinely does see the row change — which is what makes `redundant` defensible at all. Item 3 loses
a **warning**, item 2 a **retraction**, and a lost warning is worse in kind.

**Why it waits for item 1.** If announcements are dead at `targetSdk 36`, this stops being a copy
decision and becomes a mechanism one — `liveRegion` on the row covers both directions with no
approved string at all. Approving copy now risks approving something that gets thrown away.

**And the drafted candidate should not ship as written.** `screens.md` drafts *"Update. Mum. No
check-in from Mum yesterday."* The UI/UX review rejected the wording: *"Update."* is a category label
that differentiates nothing, is identical for both candidates, and is the part most likely to survive
an interrupt while the claim gets clipped — against `screens.md`'s own rule that the differentiator
belongs in the first words. It also says the name twice. The suggestion is the warning body
**verbatim**: *"No check-in from Mum yesterday."* — already approved, names the person in its first
four words, and applies the same rule `checkedIn` follows when it reuses `everythingOk`. The second
candidate, *"Update. Can't check on Mum."*, truncates a message whose whole justification is
actionability; if it ever ships, reuse the row's second line too.

</details>

---

## Still owed beyond those three

- **The first Functions deploy.** The Cloud Functions API is enabled (three clean runs); the other
  six 2nd-gen prerequisites are **unverified** and cannot be checked from this machine — `gcloud` is
  not installed and the Firebase CLI exposes no read for them. `firebase deploy --only functions
  --dry-run` settles it, and is a state change rather than a probe.
- **App Check's console half** — register the app with Play Integrity, register this install's debug
  token (confirmed **not** registered). **Play Integrity requires the app to be known to Google
  Play**, so enforcement cannot work before an internal test track exists; it is a Phase 8-or-later
  decision for a structural reason, not a metrics one.
- **The live-radio measurement** — the only thing that closes ADR-0008 question 1. It will also be
  the **first** run to exercise App Check on a cold radio: register the debug token first, or it
  measures a retry loop.
- **The AVD never tapped.** Every run used an admin REST write as the other endpoint — deliberate,
  and stronger for the Doze question because it isolates the receiving side, but it is not what the
  exit criterion says. Both Phase 4 device rows in the matrix are unticked and say why.
- **Before App Check is enforced**, the refusal-to-copy mapping must be verified against a real
  rejection on hardware. `_mentionsAppCheck` matches an English substring and anything unrecognised
  falls through to *"your phone has been offline"* — a false claim about the device, and §17's
  fleet-wide false alarm arriving through the copy layer.
- Everything on [phase-3-review-handover.md](phase-3-review-handover.md)'s known-open list that
  Phase 4 did not touch.

---

## What to be careful of next

**The three-scripts-one-port trap bit twice this session.** `tools/emulators.ps1`,
`tools/rules-test.ps1` and `tools/functions-test.ps1` all want 8080/9099/5001.

**A measurement's premise is now the most likely thing to be wrong.** Three times this phase the
subject was fine and the measurement was not: a probe that reported a sign-in had failed when it had
succeeded (wrong Auth endpoint), a guard demanding `last_confirmed_day` go null when `applyRead` is
deliberately monotonic, and a silence check asserting "today is checked in" against a four-day-old
seed. Check what the measurement assumes before believing what it says.

**`adb reverse` does not survive an adb server restart**, not just a cable unplug — and the failure
looks like a broken emulator script.

**The emulator's stdout can die and take the functions log with it.** If the process that owns the
pipe is torn down, the CLI spins on `EPIPE`, the hub stops answering, and state cannot be exported.
Start it detached with output redirected to a file.

---
## Prompt to start the next session

> I'm continuing **Phase 4** of the I Am Ok project. Read `docs/phases/phase-4-summary.md` first —
> especially **The post-gate review round** and **What to be careful of next** — then follow the
> reading order in `docs/README.md`. `docs/phases/phase-4-handover.md` is the mid-phase snapshot and
> is **deliberately frozen**; read it for the four things that went wrong earlier in the phase, never
> for current state.
>
> **Where it stands.** Steps 4–7 are built and reviewed. The two changes the owner approved earlier
> on 2026-08-25 are built, mutation-checked, proven on the POCO F3, and re-reviewed by architecture,
> testing and UI/UX. **The three items that round left open are all now closed** — the Android 16
> announcement risk was measured and is false as stated, the correction the hour-gate dropped is now
> held, and the copy decision it blocked was approved by the owner and built. 982 Dart tests, 30
> Functions tests, `flutter analyze` clean, debug APK builds and installs.
>
> **Nothing is queued for you by a previous session's plan.** What follows is the standing list, and
> the first item is the only open *design* decision in the phase.
>
> ---
>
> ### The one design decision still open
>
> **What ADR-0008's option 1 actually costs** — the owner asked for the number before any ADR is
> drafted, and asked for the cost rather than the decision. Replacing or forking
> `android_alarm_manager_plus` so the warning uses the allowlist its own receiver already holds,
> instead of handing the work to JobScheduler. **Report the cost; do not draft the ADR.** The
> alternative, un-deferring §9's scheduled function, is unchanged and is not a cost question:
> ADR-0007's objection is that a server deciding "no check-in" cannot see the watcher's local away
> cache, so §10's verify-before-speaking design would have two deciders and could give two answers
> about whether someone's relative is all right.
>
> ### Then, and unchanged
>
> 1. **The first Functions deploy.** The Cloud Functions API is enabled (three clean runs); the other
>    six 2nd-gen prerequisites are **unverified and unverifiable from this machine** — no `gcloud`,
>    and the CLI exposes no read. `firebase deploy --only functions --dry-run --project i-am-ok-c74ca`
>    settles it and **is a state change**, not a probe, so it is the owner's call. Blaze status has no
>    recorded verification at all; the setup table's rows 4–7 still read *Not done* and are dated
>    2026-08-15.
> 2. **App Check's console half** — register with Play Integrity, register this install's debug token
>    (confirmed *not* registered). Enforcement cannot work before the app reaches an internal test
>    track, and the refusal-to-copy mapping must be verified against a real rejection first.
> 3. **The live-radio measurement**, the only thing that closes ADR-0008 question 1. It will also be
>    the first run to exercise App Check on a cold radio — register the debug token first, or it
>    measures a retry loop.
> 4. **The AVD taps.** Every run so far used an admin REST write as the other endpoint. Both Phase 4
>    end-to-end device rows are unticked and say why.
> 5. **Delete protection and point-in-time recovery are both OFF**, and `deploy-notes.md` says decide
>    both before the first real data lands.
> 6. **`any → access lost` is the last unapproved announcement candidate.** It needs the owner's
>    approval like the two that shipped, and the *"Update."* objection recorded in `screens.md`
>    applies to it too.
> 7. **`MediaQuery.supportsAnnounceOf` is false on Android and this app does not check it.** Both
>    announcements work today and are measured; Flutter's own docstring says to check the flag before
>    calling, and its own widgets branch to `Semantics(liveRegion: true)` when it is false. If
>    dispatch ever stops, that is the replacement — **not a drop-in**, because the row's footer
>    carries a clock time that moves on every reconcile, so a whole-row live region would re-read the
>    row on app open, FCM, alarm and boot. It would have to be scoped to the status line.
> 8. Everything on [phase-3-review-handover.md](phase-3-review-handover.md)'s known-open list that
>    Phase 4 did not touch.
>
> ---
>
> **The device rig, as this session left it.**
>
> **POCO F3** — untouched by this session. One accepted link (self-linked, `warningLocalTime` 10:00),
> 7 warning alarms armed at 10:00 matching the store exactly, an empty tray, TalkBack off and the
> accessibility services restored, battery and `deviceidle` reset. **One thing was not restored** by
> the session before: `secure screensaver_enabled` was set to `0` while trying to force Doze and its
> original value was never captured.
>
> **`Medium_Phone_API_36.0` AVD** — the current debug APK is installed, TalkBack is **off** and the
> accessibility services are cleared, and the store holds two seeded fake watched people (*Mum*,
> *Granddad*) with today's check-in recorded on the watched side. It is a scratch rig; *Wipe store*
> in the harness resets it. Its store is at **schema v5**: installing this build over the previous
> one exercised the **v4 → v5 migration on a real store with real rows**, which passed and is written
> up in `device-matrix.md`.
>
> The emulator suite from the 00:24 session may still be up on 4000/4400/4500/5001/8080/9099 with
> `adb reverse` in place — check before starting another, because the second one fails with *"port
> taken"* and reads as a broken script.
>
> **Five things that will cost you time otherwise.** Only one emulator script may run at a time —
> `emulators.ps1`, `rules-test.ps1` and `functions-test.ps1` all want 8080/9099/5001. `adb reverse`
> dies with an adb **server** restart, not just a cable unplug, and the failure reads as a broken
> script. Start the suite **detached with output redirected to a file**, or a torn-down pipe leaves
> the CLI spinning on `EPIPE` with the hub unreachable and no way to export state. Both Firebase
> plugins rewrite `127.0.0.1` to `10.0.2.2` on Android unless `automaticHostMapping: false`. And
> **`am force-stop` cancels every notification the app has posted** — which silently removes the thing
> a notification-tap measurement is about, and looks like the notification never being posted.
>
> **Three HyperOS behaviours measured on 2026-08-25**, all written up in `device-matrix.md`:
> `deviceidle force-idle` will not reach deep idle from a screen-off device (a `DOZE_WAKE_LOCK` held
> by `DreamManagerService` parks it in `Dozing`); `am kill` does not reliably kill this app, so check
> `pidof` rather than assuming, and never substitute `am force-stop` while alarms matter; and
> **deleting** a link from Firestore strands its warning alarms, while **revoking** it tears them down
> the way §10 step 1 says. Pull the app's database with `adb exec-out run-as … cat`, never a shell
> redirect — the redirect writes a **zero-byte** file and `adb pull` still reports success.
>
> **Two things this session learned about driving the app from adb**, both reusable:
> a Flutter app exposes **no** accessibility tree to `uiautomator dump` until an accessibility service
> is running, so with TalkBack off you must navigate by screenshot and raw coordinates; and a
> notification tap can be replicated exactly with
> `am start -n io.github.davamix.i_am_ok/.MainActivity -a SELECT_NOTIFICATION --es payload <linkId>`,
> which is `flutter_local_notifications`' own intent. The second is what made an exactly-matched
> control possible — same intent, one string different — where a finger on the shade would have
> changed the window too.
>
> **The habit that found everything at this gate: read a claim against the thing it describes.**
> Across three rounds now, almost nothing came from a test failing — findings came from a docstring, a
> checklist, a copy table and a threat model each asserting something that had quietly stopped being
> true. This round added two more: a **handover** that specified a fix whose central premise was
> wrong, and a **behaviour-changes page** cited for a claim it does not make. **Verify the measurement
> before you trust the result** — this session's own mutation harness reported five green results
> that were an encoding crash, caught only because a no-op control was added to it and had to pass.
> **And mutate the code to see the test fail** before believing a green suite. This is the side where
> a false claim to a family is the worst bug the app can have — prefer stopping to ask over guessing,
> and if you think a finding is wrong, say so before acting on it rather than after.
