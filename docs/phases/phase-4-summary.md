# Phase 4 — Firebase backbone · summary

**Date:** 2026-08-25 · **Head:** `43cd1b2` · **901 Dart tests**, **30 Functions tests**,
`flutter analyze` clean, `--debug` and `--release` both build, secrets guard clean.

**Status: implemented and reviewed at the gate. All five reviewers have run and every finding is
fixed or recorded.** **Not signed off.**

**Next session picks up two approved changes** — the owner settled both on 2026-08-25 and neither is
implemented yet. Everything else outstanding is not code: the first Functions deploy, App Check's
console half, and one measurement that needs the live project. Start at *Prompt to start the next
session*.

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
the *alarm* asks, not when a warning may be posted. **Decided and not yet implemented** — see
*Prompt to start the next session*.

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

**2 and 3 are DECIDED — 2026-08-25 — and are the next session's work.** Both are implementable
without another decision; neither is implemented yet. See *Prompt to start the next session*.

---

## Still owed, and none of it is code

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
> especially **The nine findings** and **What to be careful of next** — then follow the reading
> order in `docs/README.md`. `docs/phases/phase-4-handover.md` is the mid-phase snapshot and is
> **deliberately frozen**; read it for the four things that went wrong earlier in the phase, never
> for current state.
>
> **Steps 4–7 are built and reviewed at the gate.** All five reviewers have run, one commit each,
> every finding fixed or recorded. 901 Dart tests, 30 Functions tests, `flutter analyze` clean.
> ADR-0008's deciding measurement **passed both its questions** in forced deep Doze, mutation-checked
> against `priority: 'normal'`.
>
> **Your first job is two changes the owner approved on 2026-08-25 and nobody has implemented.**
> Both are one-file changes using machinery that already exists and already has tests. Neither may
> ship without a device run.
>
> ---
>
> ### 1. A push may not post a warning before `warningLocalTime`
>
> **Why.** `warningLocalTime` feeds exactly one thing — `_desiredWarnings` at
> `watcher_reconciler.dart:681`, the alarm schedule. It appears nowhere in the decision path, so
> whoever calls `reconcile()` posts. That was invisible until Phase 4 because the alarm was the only
> *unattended* caller. FCM is the second, and it fires on **somebody else's** action. Measured on
> 2026-08-25 at **00:24:53 CEST**: *"No check-in from Ana yesterday."*, `warningLocalTime` 10:00.
>
> **The rule.** Post only when `now >= today's warningLocalTime` in the **watcher's** zone. A push at
> 14:00 against a 10:00 warning time still posts immediately — the acceleration benefit is kept for
> the rest of the day, including rescuing an alarm Doze made late. Only the hours before the
> watcher's chosen time are given up, which is the window nobody asked to be woken in.
>
> **THE TRAP, and it is the whole risk.** A suppressed run must still **decide**, must still
> **re-arm**, and must **not** record the day in `warningsShownFor` — otherwise the 10:00 alarm finds
> it settled and says nothing, which is a *lost warning*, the worst class this app has. **Do not
> invent a state.** `NotificationDelivery.unavailable` already means exactly *not posted, not
> consumed, still owed at the next reconcile* (`notification_delivery.dart:61`), and it already has
> tests.
>
> **Where it goes.** `_reconcileLink` (`watcher_reconcile_service.dart:414`) already takes a
> `WatcherDelivery` **per link** and has `now`, `watcherZone` and `link` in scope, so the downgrade
> is expressible there without touching the domain layer or the enum. `WatcherDelivery` has two
> channels — downgrade **`warning` only**. The access-lost channel must not be time-gated: a refusal
> is not tied to an hour.
>
> Note `catchUpWarnings` already folds in the same delivery state, so ADR-0009's catch-up is covered
> by the same change — which is the case that would otherwise post seven at midnight.
>
> **Prove it on the device**, and re-run the measurement in `device-matrix.md` § *Does a Doze push
> show the user anything*. The expected result flips from "a warning at 00:24" to **no notification,
> the alarm still armed, and the day still owed** — and the third is the one to check by pulling the
> store, not by looking at the screen.
>
> ---
>
> ### 2. Announce a row that changes under a screen reader
>
> **Why.** `redundant` means *the watcher is looking at the screen that already shows this*, so
> nothing posts and the day is recorded as seen. That held while `redundant` was reached by
> **navigating** here. A foreground nudge makes it also mean *the list is open and something
> arrived* — and nothing re-reads a changed widget, so a TalkBack user who heard *"Mum. No check-in
> from Mum yesterday."* is now looking at *"Everything OK"* with no announcement, no reason to swipe
> back, and no notification ever coming.
>
> **The approved string is in `docs/ui-ux/screens.md`**, with the two candidates that are
> deliberately **not** shipping yet:
>
> > *"Mum checked in. Everything OK."*
>
> **Two conditions, both required**: the person's rendered status **changed**, and the refresh was
> **not** user-initiated. `WatchedStateNotifier.refresh` already carries a `userInitiated` flag for
> the `tapFailed` fix; the watcher side needs the same signal. Announcing every refresh is noise, and
> on a resume the reader is arriving at the screen anyway.
>
> **The mechanism exists** — `SemanticsService.sendAnnouncement`, used at `watcher_screen.dart:299`.
> This changes **nothing** about what is posted or consumed.
>
> ---
>
> ### Then, in order
>
> 1. **Investigate what ADR-0008's option 1 actually costs** — the owner asked for the number before
>    any ADR is drafted. It means replacing or forking `android_alarm_manager_plus` so the warning
>    uses the allowlist its own broadcast receiver is already granted, instead of handing the work to
>    JobScheduler. Report the cost; **do not draft the ADR** until the owner has it. This is the one
>    decision still open.
> 2. **The first Functions deploy.** The Cloud Functions API is enabled (three clean runs); the other
>    six 2nd-gen prerequisites are **unverified and unverifiable from this machine** — no `gcloud`,
>    and the CLI exposes no read. `firebase deploy --only functions --dry-run --project i-am-ok-c74ca`
>    settles it and **is a state change**, not a probe, so it is the owner's call.
> 3. **App Check's console half** — register with Play Integrity, register this install's debug token
>    (confirmed *not* registered). Enforcement cannot work before the app reaches an internal test
>    track, and the refusal-to-copy mapping must be verified against a real rejection first.
> 4. **The live-radio measurement**, the only thing that closes ADR-0008 question 1. It will also be
>    the first run to exercise App Check on a cold radio — register the debug token first, or it
>    measures a retry loop.
> 5. **The AVD taps.** Every run so far used an admin REST write as the other endpoint. Both Phase 4
>    device rows in the matrix are unticked and say why.
>
> ---
>
> **Four things that will cost you time otherwise.** Only one emulator script may run at a time —
> `emulators.ps1`, `rules-test.ps1` and `functions-test.ps1` all want 8080/9099/5001. `adb reverse`
> dies with an adb **server** restart, not just a cable unplug, and the failure reads as a broken
> script. Start the suite **detached with output redirected to a file**, or a torn-down pipe leaves
> the CLI spinning on `EPIPE` with the hub unreachable and no way to export state. And both Firebase
> plugins rewrite `127.0.0.1` to `10.0.2.2` on Android unless `automaticHostMapping: false`.
>
> **The habit that found everything at this gate: read a claim against the thing it describes.**
> Nine findings, and almost none came from a test failing — they came from a docstring, a checklist,
> a copy table and a threat model each asserting something that had quietly stopped being true.
> **Verify the measurement before you trust the result**: three times this phase the subject was fine
> and the *measurement* was wrong. And this is the side where a false claim to a family is the worst
> bug the app can have — prefer stopping to ask over guessing, and if you think a finding is wrong,
> say so before acting on it rather than after.
