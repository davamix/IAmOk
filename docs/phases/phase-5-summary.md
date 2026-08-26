# Phase 5 — Onboarding and pairing · summary

**Date:** 2026-08-26 · **1 193 Dart tests**, **79 Functions tests**, **75 rules tests**,
`flutter analyze` clean, debug **and release** APKs build, secrets guard clean.

**Status: COMPLETE and SIGNED OFF, 2026-08-26.** Built, the exit criterion met on two devices, all
five reviewers run with their findings applied, all three owner decisions taken, and the six items
the review round left open either closed or recorded.

> **[phase-5-handover.md](phase-5-handover.md) was the close-out plan and is now historical.** It
> carries the state as of the review round and a suggested solution for each open item — every one
> of which was taken. Read it for the reasoning; read *Closing the phase* below for what was
> actually done. This file is *what was built and why*.

> **Two phones paired from a cold install using only a shared code**, 2026-08-26 11:12–11:28. The AVD
> was *Mum*, the POCO F3 was *Ana*; both were uninstalled first; the code was read off one screen and
> typed into the other. Mum landed on the Tap screen naming Ana, Ana on the watcher list showing Mum.
> **The AVD also tapped**, which closes the half Phase 4 left owed.

> **The device run was made BEFORE the close-out changes below.** The chooser behind *"Add someone"*,
> the empty-audience 21:00 body and the fourth refusal are covered by tests and by mutation testing,
> and **not** by a run on a handset. None of them is on the path the exit criterion exercised — the
> chooser sits behind a control the criterion never presses, the reminder body is a string chosen at
> schedule time, and the refusal is a branch that fires when the backend faults. Worth knowing, and
> named here rather than left to be assumed either way. The first thing Phase 6 does on a device
> should be to press *Add someone* and take the second option.

---

## The one-line story

Both callables, the three screens, a sign-in surface that did not exist, role routing as a pure
function, and a way back into pairing from both main screens.

**The device run is what made the phase.** It found **two defects nothing else could have**, one of
them a plugin trap this repo has already been bitten by twice and had never applied to the third
plugin, and one of them a deliverable screen that no user could reach. Both are the same shape as
every finding at every gate of this project: each piece was individually correct and the composition
was not.

---

## What was built

| | What |
|---|---|
| **`createInvite`** | A **fourth** Function ([ADR-0011](../architecture/decisions/0011-creating-an-invite-is-a-function-too.md)). Generates a §7 code, `create`s it so a collision is the write failing rather than a read-then-write race, 24-hour expiry, `watchedUid` from `request.auth`. Reuses a live code rather than replacing it, and sweeps the caller's own expired unconsumed invites. |
| **`redeemInvite`** | One transaction: validate → `links/{watched}_{watcher}` with `activeFrom` in the **watched person's** zone and all three names denormalised → mark consumed. |
| **`InviteService`** | Data. Two callables, no Firestore reference — §8 makes `invites/` unwritable as well as unreadable. |
| **`HomeRoute`** | Domain. Two questions kept apart: **is the flow over** (`completed` alone) and **which main screen** (the two answers unioned with the accepted links). Conflating them is what let a mid-flow answer end the flow. |
| **`InviteCode`** | Domain. §7's alphabet, parsing and normalisation. |
| **Sign-in, 3 onboarding screens, 2 pairing screens** | Presentation, with all copy in `OnboardingCopy`. |
| **The route back** | *"Add someone"* on the Tap screen and the watcher list. |

---

## The design decisions taken, and why

**`createInvite` is a Function, not a client write** — ADR-0011. §8 always said so; §9 and §6 did not,
and the client had no path to a code at all. Granting a narrowed `create` instead was rejected because
a create that fails because the document exists tells the caller that code is **live** — the
enumeration the deny exists to close, arriving through the write path.

**The callables return outcomes as a `status`, and throw only for real faults.** A mistyped code is
not an exception. A status enum crossing the wire makes the client's mapping *total*; the alternative
is what `OPEN-QUESTIONS.md` #5 records elsewhere in this app, where an **English substring** decides
which sentence a family reads.

**Which main screen is the union of the answers and the links; whether the flow is OVER is
`completed` alone.** §1 chose Google Sign-In because *the uid survives a reinstall, so links never
break* — which means a cold install can begin with an empty store and a user who already watches
three people. Routing on the stored answers alone strands a reinstalled watcher on the Tap screen,
where the list that re-arms their warning alarms is reachable only by a notification tap: the failure
`main.dart` had warned about for three phases, arriving through the fix for it.

Those are **two questions**, and answering both with one expression is what let a mid-flow answer end
the flow — twice, by two different doors. `AppServices.settleOnboardingIfPaired` now answers the
first *from* the links, once, before the router is asked.

**A skip is an answer.** `completed` is a third flag rather than something derived, so somebody who
wants neither role is not asked the same two questions every morning.

**The summary reports evidence, never intent.** Someone who tapped *"Add someone"* and closed the code
screen has set nothing up. `HomeRoute` unions intent with evidence to decide *where to go*; the
summary screen reports the links that exist and nothing else.

**A link to yourself is refused**, and the device rig's deliberate self-link is unaffected because
`tools/seed-link.ps1` writes through the Admin SDK and bypasses the callable.

**An unresolvable watched timezone is refused rather than defaulted to UTC.** `Link.tryWatchedZone`
calls a zone this build cannot resolve *"a permanently silent watcher, which is the one failure this
app cannot detect in itself"*. Better to fail at the one moment a human is watching the screen than to
write a quietly broken link.

**All three notification channels are still created on every phone** — recorded in `screens.md` as
settled rather than left open. A channel that does not exist is a notification that silently does not
post; role is not stable, because anyone can be handed a code minutes later; and Android remembers a
deleted channel's settings, so recreating one does not restore a default.

---

## What the device run found, and nothing else could

### 1. Every callable from a physical handset went to an address that does not exist there

`redeemInvite` **hung until it timed out** and the Functions emulator logged *nothing* — the call
never arrived. Auth and Firestore were fine over the same `adb reverse`: the phone signed in, wrote
`users/{uid}`, rendered the pairing screen.

`useFunctionsEmulator` does the same `127.0.0.1 → 10.0.2.2` rewrite as the other two plugins and
defaults `automaticHostMapping` to `true`. `FirebaseBootstrap` passed `false` to Auth and Firestore
and not to Functions.

**Half the app working is what made it read as a backend fault.** No test could see it and the AVD
could not either — `10.0.2.2` is *correct* there. It needed a physical handset. Now a `CLAUDE.md`
line, generalised: three plugins, three for three, assume the next one does it too.

### 2. The summary screen was unreachable

With the callable fixed, both phones went from *"Skip for now"* **straight past screen 3** to their
main screens. Screen 3 is a deliverable of this phase and no user ever saw it.

`_persist` invalidated the provider `homeRouteProvider` watches, so answering a question
affirmatively made the route recompute, find a role, and leave onboarding. Every piece was correct in
isolation. The defect existed only as *a screen a person never reaches* — which a suite of unit tests
is structurally unable to notice.

> **The same-day fix was not enough, and the review round said so.** Telling the router only from
> `finish()` made the defect **latent rather than absent**: the route was then held off by a *cache*,
> and testing found a second door into it that needs no provider at all — killing the app between
> question 1 and *Finish* leaves the same state on disk, because `_persist` writes each answer
> immediately. `HomeRoute.decide` now ends onboarding on **`completed` alone**. See *The review
> round*, finding 2.

### 3. A dependency change broke only the Android build

`flutter pub add cloud_functions` moved `firebase_core` 4.13.0 → 4.14.0, against which
`firebase_auth` 6.5.7 does not compile. **`flutter analyze` and `flutter test` both stayed green**;
only `:firebase_auth:compileDebugJavaWithJavac` failed. `firebase_core` is now pinned to an exact
version, and `cloud_functions` held at `^6.3.6` so it cannot drag 4.14.0 back in. Also a `CLAUDE.md`
line.

---

## Mutation testing — 42 mutations, two harnesses, both with a passing control

**Functions: 16, all as expected.** The first pass reported two `DID NOT COMPILE`, and the harness
**refused to score them** rather than counting them as caught — a mutation TypeScript rejects proves
nothing about the tests. Both were rewritten to compile and both then failed the suite.

**Dart: 26, all as expected.** The first pass reported three unexpected, and they were three different
things:

- Two were **bad mutations**: one added a branch that fires exactly when the original already does,
  and one mutated `ref.read(appServicesProvider)` when the loop rode on the *choices* read. Rewritten.
- One was a **real test gap**: `recordPairing`'s `asWatched == true ? true : null` could be written
  `asWatched` with the suite green, because no caller passes `false`. The guard is what makes
  recording monotone — a pairing screen able to **erase** an answer rather than record one — and it is
  now pinned by a test that calls it with `false`.

**Both harnesses abort rather than score if they cannot read their subprocess's output**, which is
CLAUDE.md's requirement after Phase 4's runner reported five green results that were an encoding
crash. They ran under Node with explicit UTF-8, which is what the previous harness got wrong.

> **The scripts above were scratch and are gone.** They were rebuilt into the repo at the gate as
> `tools/mutate-runner.mjs`, `tools/mutate-dart.mjs`, `tools/mutate-invites.mjs` and
> `tools/functions-mutate.ps1`, and re-run — see *Closing the phase*, item 6d, for the numbers that
> are actually reproducible today. **The rebuilt harness refused to score twice before it scored
> once**, both times on a mistake in the caller rather than in the suite, which is the guard doing
> exactly the job it was kept for.

---

## The review round — all five reviewers, 2026-08-26

They found **the usual thing, in quantity**: almost nothing came from a test failing, and the
sharpest findings were claims that had stopped being true. Two reviewers independently found the
same defect twice over.

### Fixed — the ones that were false claims or broken deliverables

**1. A revoked watcher re-typing their old code was told the pairing was live.** Found by security
and testing independently. `redeemInviteFor` checked that the link document **exists** and not that
it is `accepted` — and the consumed invite is deliberately kept, and the code is still in the
message thread it was shared in. So Ana, revoked, re-types her code and reads *"You are now looking
after Mum."* while every read she makes is still refused. Nothing was restored. Now falls through to
`consumed` — *"That code has already been used. Ask for a new one."* — which is true and names the
action that works. Three tests, including that a spent code cannot restore the link.

**2. The flow could be ejected mid-way, by two different doors.** The summary-screen defect the
device run found was patched by not invalidating the router's provider mid-flow — which left it
**latent rather than absent**, held off by a cache. Testing found the second door: `_persist` writes
each answer immediately, so killing the app between question 1 and *Finish* leaves
`(wantsToBeWatched: true, completed: false)` on disk, and `HomeRoute.decide` routed that to the Tap
screen with no provider involved at all. Question 2 then never gets asked and `completed` stays
false for ever.

`HomeRoute.decide` now ends onboarding on **`completed` alone**. The reinstall case it used to
handle by treating a link as an ending moved to `AppServices.settleOnboardingIfPaired`, which
answers *is the flow over* **from** the links, once, before the router is asked. Two questions that
were being answered by one expression, now kept apart — and the truth table gained the three states
that had no case.

**3. "Add someone else" could never confirm the second pairing.** Found by three reviewers.
`_addAnother` set the baseline to `null` with a comment saying the new watcher "joins the baseline";
it did not — it deferred the baseline to the *next* emission, which is the one caused by the second
redemption. The screen sat on *"Waiting for them to type it in."* for ever on a pairing that had
succeeded. The baseline now moves at the moment of confirmation.

**4. The share screen's baseline came from the first Firestore snapshot**, so a redemption that beat
it — a slow first listen, a phone briefly offline — was swallowed and never confirmed. It is now
seeded from `LocalStore` before the stream is attached, which is also the answer §3 wants: the store
is what every other surface renders from.

**5. The summary said "You're all set" over "Nobody is set up yet."** The tick and the title rendered
unconditionally, so somebody who skipped both questions finished onboarding reading a green success
tick above a line saying nothing was set up. Both are now gated on there being something to report,
and the screen gained the loading and error states it never had — without them a failed read was
indistinguishable from "nothing is set up", which is a claim about the account made by a device that
just failed to find out.

**6. A both-roles user got no warning alarm for the rest of the session.** After `finish()` routes
them to the Tap screen the watcher list never mounts, and nothing else reconciles that side. This is
the failure `main.dart`'s own three-phase-old comment warns about, arriving through the phase that
introduced the routing. `finish()` now runs the watcher repair when the settled route is `tap`, and
only then — the list reconciles itself.

**7. Links were never synced after an in-app sign-in.** `main()` syncs with the *launch-time* uid,
which on a reinstall is the signed-out sentinel — so `linkRolesProvider`'s docstring claim that *"the
store is the fresh copy"* was false at exactly the moment `HomeRoute`'s reinstall reasoning is about.

**8. Every callable from a physical handset went to `10.0.2.2`** — fixed during the device run, and
now **mechanical**: `android_manifest_test.dart` counts the emulator wiring calls against the
`automaticHostMapping: false` opt-outs, so a fourth service cannot be added without one. Verified by
removing the flag and watching it fail.

**9. The confirmation and every refusal were silent to a screen reader.** Nothing re-reads a changed
widget, so a blind watched person heard *"Waiting for them to type it in"* and then nothing, for
ever — on the screen whose whole justification is that the person the app is *for* should not be
left staring at an unchanged screen. Both are announced now, with already-approved strings. The bare
spinner is labelled too.

**10. A watcher-only user's first screen was a red banner** about a permission the app had never
requested. `ensureNotificationsAsked` lived on the Tap screen and nowhere else, which covered
everybody until Phase 5 routed on role.

**11. "Add someone" meant two opposite things.** On the Tap screen it *produces* a code; on the
watcher list it *consumes* one. A watcher with no code pressed the only button on the screen and
landed on a form demanding an artefact that did not exist yet — while the sentence that used to
point them at the person who can make one is exactly what this phase deleted. The watcher list's
button is now **"I have a code"**, which is already-approved copy from onboarding screen 2.

**12. Three refusals named an action that could not repair anything.** `users/{uid}` was written at
sign-in and never again, so *"This phone could not finish getting ready. Try again."* re-ran an
identical failing call, and *"Ask them to open I Am Ok"* changed nothing on the other phone. There is
now `AppServices.refreshProfile`, called on resume and on the retry paths.

**13. The invite sweep would not have run in production.** Fire-and-forget work is dropped when
Cloud Run freezes the container after the response — and the emulator, where nothing throttles, is
the only place the test could pass. It is the design's *only* garbage collection. Now awaited.

**14. `redeemInvite` would have deployed accepting ~800 concurrent guesses.** `OPEN-QUESTIONS.md`
#11 accepts the brute-force risk on an argument with **no rate term in it**; at the 2nd-gen defaults
the expected time to a first hit falls inside a single code's 24-hour life. Now
`concurrency: 1, maxInstances: 3`.

**Also fixed:** the two `logger.error` calls could carry a live invite code three lines under a
comment saying they never do; the collision retry retried on *any* error, so a transient timeout on a
write that landed would mint a second live code; `link_reconcile_failed` survived a sign-out;
`DateTime.tryParse` walked through the purity guard and the comment defending it was backwards; the
copy floors matched **single-quoted strings only**, so every string containing an apostrophe — this
phase's most common shape — was invisible to them; `SignedInUid.signedOut()` had no caller while its
docstring said it was wired; and a docstring named a test file that did not exist, which now does.

**Corrected documents:** `OPEN-QUESTIONS.md` #11 understated the blast radius twice over (a
successful redemption **does** return the watched person's uid, necessarily; and a guessed link
grants read **and write** on the away document, so a stranger could silence every watcher for ~32
days); `threat-model.md` T3 said the rate limit was owed *in this phase* and was never updated;
`deploy-notes.md`'s header said nothing was deployed, five days after the rules went live — the same
failure that file already catalogues, in its own header; and §15's *"UI isolate only"* was false of
the `cloud_functions` package, which `FirebaseBootstrap` puts in all three isolates.

**`firebase_auth` 6.6.0 exists and was tried.** The pubspec comment claimed 6.5.7 was the newest
there was; infrastructure checked pub.dev and found the whole FlutterFire set shipped on 2026-08-24.
Moving to `firebase_core ^4.14.0` / `firebase_auth ^6.6.0` / `cloud_functions ^6.4.0` **still fails
the Android build**, with a different error (`compileDebugKotlin`, an inaccessible checkerframework
annotation). The pin holds on evidence now rather than on a guess.

---

## Closing the phase — 2026-08-26

Everything the review round left open was closed or recorded. **The three owner decisions were put to
the owner and all three took the recommended option.**

### 1. Copy — approved, with four amendments · OWNER

**Every new user-visible string is approved**, including the **two deletions** from already-approved
copy: `TapCopy.nobodyYet` and `WatcherCopy.nobody` both lost *"Ask a family member to help you add
someone."* now that an **Add someone** button sits directly beneath each line.
`TapCopy.notificationsOff` records the rule they follow — *"ask a family member" is the dead-end
wording, only honest once there is nothing left to press*.

**Four strings were missing from `screens.md` and are now in it**: the summary's title *"You're all
set"* **and the condition it renders under**, the share message, the watcher-list control's label,
and the recorded exception for `summaryNothing` keeping the word *"yet"* — defensible because that
screen is reached once, before anything has ever been set up, which is the one state where *"yet"* is
true of every reader.

**Four amendments were taken at approval:**

| | Was | Now |
|---|---|---|
| `PairingRefusal.ownCode` | *"That is your own code. Ask the person you are looking after for theirs."* | *"That code belongs to this phone. Type it into the other one."* |
| The share message | ends at the code | the code, then `codeExpiry`'s own sentence on a second line |
| The watcher-list control's label | `WatcherCopy.title` — a **screen title** | `WatcherCopy.openLabel` — *"See who you look after"* |
| Refusals | three could-not-reach paths lied about the device | a fourth outcome, `serverFault` |

**Why `ownCode` had to change.** That branch fires when the watched person's own code is typed into
the watched person's **own phone** — and `screens.md` records that the family member realistically
sets up both handsets in one sitting, so the reader is overwhelmingly somebody holding the wrong one
of two phones on a table. The old sentence named a relationship they do not have and sent them to ask
a question of the person sitting next to them.

**Why the share message needed the expiry.** It is the only string in this app that reaches a phone
without it installed. A code shared at 9pm and read the next morning is dead, and the recipient's
first experience of I Am Ok was a code that failed with no way to tell an expired one from a mistyped
one — while the sender had the expiry on their own screen the whole time. The code stays at the
**end of its own line** and nothing is punctuated after it: a full stop there is a character
somebody can type into a six-character field, and `InviteCode.tryParse` strips only spaces and
hyphens.

### 2. The cross-role dead end — a chooser behind *Add someone* · OWNER

*"Add someone"* on the Tap screen now opens a two-option sheet — **"Someone to look after me"** →
`ShareCodeScreen`, **"Someone I look after"** → `EnterCodeScreen` — instead of going straight to the
code screen.

It closes a dead end rather than adding a feature. That button opened `ShareCodeScreen` and only
that, while the only route to `EnterCodeScreen` was the watcher list, which is reachable from the Tap
screen **only by somebody who is already a watcher**. So anybody who answered *"Skip for now"* to
onboarding's second question was shut out of that role for good: no error, no wrong screen, nothing
anywhere to press.

**Framed as two people, never as two roles**, mirroring the two onboarding questions PLAN.md fixes —
*"Are you the elderly one?"* is a question nobody wants to answer. A sheet rather than a permanent
second control, because `guidelines.md`'s first principle is one screen one action; it costs the
elderly user nothing in daily use, since they never press the button it sits behind.

`AddSomeoneButton.pairingScreenFor` is a pure mapping and `@visibleForTesting`, the same shape as
`Home.screenFor`, so the branch that decides which half of pairing a person reaches is asserted
without a composition root.

### 3. The 21:00 reminder — an empty-audience variant · OWNER

*"Please tap I'm OK before the day ends, so your family knows you're well."* is now
*"Please tap I'm OK before the day ends."* when no accepted link exists. `screens.md` no longer says
*"Owed before Phase 5"*.

That item's proposed resolution was *"an explicit acceptance once onboarding guarantees pairing before
reminders arm"* — and **onboarding does not guarantee that**, so the acceptance had nothing to rest
on. It is a **subtraction** from approved copy, the same move `nobodyYet` made, and the same rule as
the four warning messages: never claim more than the device knows. **Reminders still arm for a phone
with nobody set up**, which is deliberate — they exist for her own routine, and coupling them to an
audience would mean losing every watcher silently stops her being nudged to tap.

**It reaches the scheduler as a flag rather than riding on `ScheduledReminder`.** Audience is not part
of a reminder's identity, and putting it in that type's equality would put it in the diff
`WatchedReconciler` takes against a `LocalStore` snapshot **that has no audience column** — so every
stored reminder would differ from every desired one the moment a first watcher appeared.
`AlarmScheduler.apply` re-asserts the whole desired set on every reconcile, so the wording follows
the audience with no diff having to notice. `hasAudience` is **required**, not defaulted: the default
that preserves today's behaviour is the one that promises a family to a phone that has none.

### 4. `couldNotReach` said when the server answered — a fourth refusal

ADR-0004's *refused is not unreachable*, one layer down. Four paths claimed the phone could not reach
the internet about a phone that demonstrably had: an `internal` from a failed transaction, any wire
status this build has no case for, a malformed `created` payload, and a `not-found` from a region
mismatch. A false claim about the **device**, naming an action — *check your connection* — that
cannot work.

`serverFault` — *"That did not work just now. Try again in a moment."* — deliberately claims nothing
about **either** side. `couldNotReach` is now narrow: `unavailable` and `deadline-exceeded`, the two
gRPC codes that mean the request did not arrive.

**The exception mapping was lifted out of the `catch` into `InviteService.refusalForCode`**, which is
the half that had no test because no unit test can enter an exception handler. It is table-tested now,
including the codes that were wrong. The status mapping had been a pure function since the class was
written; this half had not, and it was wrong for the whole of Phase 5.

`onboarding_copy_test.dart` **pinned the false claim** — it asserted `couldNotReach` names the
internet — so that assertion now belongs to `serverFault`'s sibling, which asserts the opposite.

### 5. `Home.build` — a source lint, honestly labelled

`Home.screenFor` is asserted as a pure mapping and so is the argument it receives; the one line that
*reads the provider* was covered by nothing. `onboarding_routing_test.dart` now asserts that
`lib/main.dart` contains `screenFor(ref.watch(homeRouteProvider))`.

**A lint, not a proof**, and it says so. Two precedents in this repo: `domain_purity_test.dart`'s
guards and the `automaticHostMapping` counter added this phase. **Verified by mutation** — changing
the line to `screenFor(null)` makes it fail. The first attempt at that mutation was `ref.watch(
otherProvider)`, which does not compile, so the test never ran: a mutation that proves nothing, which
is exactly the trap the harnesses below are built to refuse.

Option B — diagnosing the hang that stops `Home` being pumped in a real container — remains open and
is worth more than this one line, because it would also unblock `app_lifecycle_test.dart`.

### 6. Verification hygiene — all four

**a. The release manifest, measured — the fourth measurement.** `flutter build apk --release`, then
the merged report **and the merged manifest itself**. Permissions: **no change, still fourteen**,
neither `share_plus` nor `cloud_functions` contributing one. But the check as documented would have
missed what they did add, because it greps for a *permission*: `share_plus` contributes a
**`ShareFileProvider`** and a **`SharePlusPendingIntent` receiver**, both `android:exported="false"`,
the provider's authority scoped to this application id; `cloud_functions` contributes one `meta-data`
registrar.

**Read the merged manifest, not the merger report, for anything about a component** — the report
lists attribute *names* without their *values*, so it says `android:exported` was added and never what
it was set to, which is the entire question. `deploy-notes.md`'s standing command now does both, and
the finding is recorded in `android_manifest_test.dart` with the rest. The provider is present and
**unused**: this app shares text, never a file.

**b. `@types/node` pinned to the deployed runtime.** `@types/node@26.2.0` was in the TypeScript
program transitively under `firebase-admin` while Cloud Functions runs Node 22 — and
`deploy-notes.md` said *"`@types/node` is not installed"*, which was false. Newly load-bearing,
because `invites.ts` imports `node:crypto`: a Node 23+ API would have type-checked clean, run clean in
the emulator, and failed only after deploy. Now `^22`, `tsc --noEmit` clean at 22.20.1, and the
sentence corrected.

> **`npm --prefix functions install …` typed from inside `functions/` creates
> `functions/functions/`.** No error; `npm ls` then reports a package called `functions`. It happened
> during this work and was caught by reading the output rather than the exit code. The stray
> directory was removed and the command is recorded in `deploy-notes.md` as *run it from inside
> `functions/`*.

**c. Two colour pairs measured, and one of them is a finding.** `contrast_test.dart` asserted nine
pairs and neither the **code block** (`onPrimaryContainer`/`primaryContainer`) nor the **tonal
buttons** (`onSecondaryContainer`/`secondaryContainer`). Measured: **5.18 light / 6.62 dark** and
**5.19 / 6.62**. Both clear `guidelines.md`'s floor, which is AA for all text and AAA **by name** for
the tap target and warnings — so both are asserted at AA and both pass.

**The code block does not reach AAA**, and it is the one string in this app read aloud across a table
and transcribed into another phone. Raising it is a **palette change to an approved theme**, which is
the owner's, so it is recorded as `OPEN-QUESTIONS.md` **#12** rather than enforced by a test asserting
a floor no document sets.

**d. The mutation harnesses are in the repo.** `tools/mutate-runner.mjs` (the engine),
`tools/mutate-dart.mjs`, `tools/mutate-invites.mjs` and `tools/functions-mutate.ps1` (the wrapper that
finds Java). Phase 5's "42 mutations, all as expected" was a claim nobody could re-run, which is the
wrong shape for the one artefact whose job is to distrust a green suite — especially after Phase 4's
runner produced a green report **by being broken**.

Three properties are enforced by the engine rather than remembered:

- **It proves it can read its subprocess before scoring.** Explicit UTF-8 — `spawn` with no encoding,
  `Buffer.concat`, one `toString('utf8')` — and a `classify` that returns `UNREADABLE` for output
  matching neither the pass phrase nor the fail phrase, which aborts the run. Silence is never scored.
  **That is the whole defence:** absent output must not be indistinguishable from a failing suite, or
  a harness *hoping* for failure calls every mutation caught.
- **The no-op control runs first and has to pass.**
- **A mutation that does not compile is REFUSED**, not scored, and exits non-zero so it gets rewritten.

An ambiguous `from` — matching zero times or more than once — is refused before anything runs: a
mutation that might be editing a different line than the one it names cannot be scored. The source is
restored in a `finally`, always.

**Results, 2026-08-26.** Dart: **14 mutations, 14 caught, 0 survived**, five passing no-op controls,
first run. Functions: **16 mutations, 16 caught, 0 survived** — but only on the *third* run, and what
happened on the first two is the reason the harness was worth keeping.

**The harness refused to score, twice, before it scored once. Both times the caller was wrong.**

1. The pass phrase was `# fail 0` — **TAP's** format — while `node --test`'s default reporter is
   `spec` and prints `ℹ fail 0`. Nothing matched, the no-op control came back `UNREADABLE`, and the
   run aborted having scored nothing. A harness that read *"no pass phrase"* as failure would have
   reported all sixteen as caught **from a suite it had never read** — which is Phase 4's failure
   exactly. The phrases are patterns now, anchored to the line with the count as a group, because the
   old list also stopped at `fail 5`.
2. With that fixed it still refused: `spawn` with `shell: true` **concatenates arguments and escapes
   nothing** (Node warns as DEP0190), so `'npm --prefix functions test'` reached `firebase` as five
   arguments and it answered `error: unknown option '--prefix'`. The harness captured all 33
   characters of that perfectly and declined to score them. `run` quotes arguments containing spaces
   now.

Both times *"UNREADABLE"* looked at a glance like a decoding fault and was the opposite: the guard was
right and the caller was wrong, and its refusal to guess is what made the real cause findable in one
step.

**Then the third run found four real gaps and two bad mutations of mine**, which is the ratio the
harness's own docstring warns to expect:

| | |
|---|---|
| **The TTL was asserted against itself.** `assert.equal(expiresAt - NOW, INVITE_TTL_MS)` **imports the constant from the module under test**, so widening 24 hours to a week moved both sides together and the suite stayed green — under a comment reading *"the owner chose 24 hours"*. Three things depend on that number: the owner's decision, the sentence the share message now sends to a phone without the app, and `OPEN-QUESTIONS.md` #11's arithmetic. | Pinned to a literal, alongside the code length and the alphabet size. `CLAUDE.md`'s rule for derived values, applied to a constant. |
| **Only a collision may be retried, and nothing checked it.** Both existing tests collide for real, so they pass with or without the `code !== 6` half of the guard. That guard is the Phase 5 review's own fix — a transient `DEADLINE_EXCEEDED` on a write that **had landed** would mint a second live code — and it was unpinned. | A test that fails `create` with gRPC code 4 and asserts it propagates on the **first** draw. |
| **The sweep being awaited could not be observed at all.** `await` → `void` left the suite green, which is precisely why the defect reached the review round: nothing throttles a local Node process, so the two are indistinguishable in the emulator. The existing test even sleeps 300ms, which is the slack a dropped promise hides in. | A **source lint**, labelled as one. The property is about Cloud Run freezing a container and there is no local behaviour to assert. |
| **Reuse picks the code that dies last**, and every other test has at most one live code — so inverting the comparison to pick the one that dies **first** was invisible. Two live codes is a state that really occurs: `createInviteFor` is not atomic, which ADR-0011 records as accepted. | A test with two live codes at different expiries. |

**Two of my mutations were bad, and one of them SURVIVED** — the case that matters, because a
surviving bad mutation reads exactly like a test gap. `if (!inviteSnap.exists) return unknown-code`
→ `if (false)` changes **nothing observable**: a missing invite then falls through to
`data() ?? {}`, and the guard two lines below returns `unknown-code` anyway. Scoring it as a gap
would have been the harness lying in the other direction. It now mutates the **answer** instead.

**Three more were refused as `DID NOT COMPILE`**, all the same shape: `if (false)` on a guard that is
what **narrows a nullable type**, so four later uses stop type-checking. A mutation the compiler
rejects proves nothing about the tests, because the tests never ran. All three were rewritten to
change the same behaviour in a way that compiles — and the Dart harness had its own version of this,
where the first `Home.build` mutation was `ref.watch(otherProvider)`, an undefined name.

**Functions tests went from 75 to 79.**

### Recorded rather than fixed

Two of the smaller items were *"record the cost"* items and are now recorded:

- **ADR-0011's Consequences** now names what reuse costs: an invite **cannot be withdrawn** once
  shared to the wrong person, and reuse actively prevents displacing it. Bounded — single-use, 24
  hours, and the redeemer appears by name on the Tap screen where either party can revoke — so it is a
  recorded cost, not a defect. A `cancelInvite` callable is cheap if ever wanted.
- **`threat-model.md`'s Assets table** now carries *pairing decisions in Cloud Logging*.
  `redeemInvite` logs `linkId` = `{watchedUid}_{watcherUid}` on every call, so project log access is
  access to the link graph. It is **deliberate and load-bearing** — `OPEN-QUESTIONS.md` #11 rests its
  acceptance of the guessing risk on that evidence existing — which is exactly why it needed naming,
  so nobody later removes it as noise.

**A defect found while doing the above, unrelated to any of it.** Every source-lint test that matches
a pattern spanning two lines would fail on a **fresh clone on Windows**: Git for Windows defaults to
`core.autocrlf=true`, the repo stores LF, and `push_handler_test.dart`'s two-line listener lint reads
`\n`. One `git checkout lib/main.dart` reproduced it. Both `_withoutComments` helpers now normalise
CRLF first, and the guard was verified by forcing the file to CRLF and watching the suite stay green.

### Still open, and deliberately

- **`Home.build`'s hang** — option B above. Worth a timebox in a later phase; it would unblock
  `app_lifecycle_test.dart` too.
- **The nine smaller items** listed in the handover's *Smaller open items* table, minus the two
  recorded above. None is a false claim to a family; each is a one-line fix or a small one.
- **`OPEN-QUESTIONS.md` #12** — the code block's contrast, new at this gate.
- **Everything on Phase 4's standing list**, unchanged and listed below.

---

## Deliberately NOT fixed by the review round, and why

> **Kept as written, because it is the record of what the review round decided and why.** Items 1–6
> were all closed at the gate — see *Closing the phase* above.

**1. The cross-role dead end.** A Tap-screen user who is not already a watcher has no route to
`EnterCodeScreen`, and a watcher-only user has none to `ShareCodeScreen`. So somebody who skipped one
question can never take up that role. **This is the owner's call**, because the only fixes add a
second action to the *watched person's* screen — and `guidelines.md`'s first principle is one screen,
one action, with `WatchedAudience` recording at length how firmly this project refuses extra surfaces
there. The options are a chooser behind *"Add someone"*, making the watcher list always reachable, or
accepting it until Phase 7's UI pass.

**2. The 21:00 reminder.** `screens.md` still says *"Owed before Phase 5"*: that reminder says *"so
your family knows you're well"* while the screen may simultaneously say nobody is set up, and the
proposed resolution was *"an explicit acceptance once onboarding guarantees pairing before reminders
arm"*. **Onboarding does not guarantee that** — it offers *Skip for now* on the screen that would
produce it. So the item is not closed, it is now *easier* to reach, and it needs either an
empty-audience variant of that body or a written acceptance. Owner's decision either way.

**3. `couldNotReach` is said when the server was reached and answered.** A `HttpsError('internal')`
from a failed transaction, and any status this build has no case for, both map to *"Could not reach
the internet. Check your connection and try again."* — a claim about the **device** that is false,
and a next action that cannot work. This is ADR-0004's *refused is not unreachable* reappearing in a
new place. Fixing it properly needs a fourth refusal and **new copy**, so it is owed the owner rather
than invented here.

**4. `Home.build` is still uncovered.** `Home.screenFor` is asserted as a pure mapping, but the one
line that reads the provider is not. Pumping `Home` inside a real container **hangs with no output**
— the same behaviour `app_lifecycle_test.dart` records for pumping `IAmOkApp`, and its stated reason
for not doing so. Attempted and abandoned rather than left as a hanging test or a green one that
proves nothing; recorded in the test file itself.

**5. The release manifest measurement is owed.** `deploy-notes.md` makes it a standing command
whenever a plugin is added, *"including when you expect no change"*. Two were added. The debug merge
suggests the permission set is unchanged but that **`share_plus` contributes a new content provider**
— which the documented `Select-String INTERNET` check would miss anyway, because it greps for a
permission. Needs `flutter build apk --release` and a recorded result.

**6. `@types/node` is four majors ahead of the deployed runtime.** 26.2.0 is in the TypeScript
program against Node 22 on Cloud Functions, and `deploy-notes.md` says the opposite (*"`@types/node`
is not installed"*). Phase 5 added this project's first Node builtin import (`node:crypto`), so it is
newly load-bearing: a Node 23+ API would type-check clean, run clean in the emulator, and fail after
deploy.

**Smaller, all recorded rather than fixed:** a watcher-only user's launch runs two overlapping
watcher reconciles; an error in either routing input renders as a permanent spinner with no retry;
`deviceFactsProvider` is in the right layer but the wrong file; `createInviteFor` is not atomic so
two racing calls can leave two live codes; an invite cannot be withdrawn once shared to the wrong
person; the code block's colour pair is not in the contrast test; the system back button exits from
onboarding rather than stepping back; `AddSomeoneButton` and the Away control will be adjacent
look-alikes once Phase 6 enables Away; and nothing exercises the `onCall` wrappers below a device
run.

---

## Owed to the owner — **all settled 2026-08-26**

Kept for the record of what was asked and what came back. The detail is in *Closing the phase*.

**1. Copy approval — every new string. → APPROVED as drafted**, and `screens.md` now carries the
approval date against each section, the four strings that were missing from it, and the four
amendments taken at the same time.

**2. Two changes to already-approved copy. → APPROVED.** `TapCopy.nobodyYet` and `WatcherCopy.nobody`
keep their shortened form. The alternative — keep the sentence, do not add the button — was rejected
because it leaves a skipped first question as a dead end and makes a second watcher impossible.

**3. The cross-role dead end. → a chooser behind *Add someone*.**

**4. The 21:00 reminder. → an empty-audience variant.**

**5. The five reviewers.** They ran at the review round (commit `e8af581`) and their fourteen
findings were applied. **They have not been re-run over the close-out changes** — the chooser, the
21:00 variant, the fourth refusal and the harnesses. That is the owner's to trigger, and this repo's
memory records that launching them in parallel has twice exhausted the session limit, so they want
running one at a time.

---

## Still owed, and carried

**Nothing here blocks Phase 6.**

- **The five reviewers over the close-out changes** — see *Owed to the owner* #5 above.
- **A device run over the close-out changes.** None of them is on the path the exit criterion
  exercised. The first thing to do on a handset is press *Add someone* and take the second option.
- **`Home.build`'s hang**, which also blocks `app_lifecycle_test.dart`. Worth a timebox, not an
  open-ended hunt.
- **The nine smaller items** in the handover's table, minus the two recorded at the gate.
- **`OPEN-QUESTIONS.md` #12** — the pairing code's colour pair is measured at AA and does not reach
  AAA. A palette question, and the owner's.
- **Everything on Phase 4's standing list** — the first Functions deploy (still blocked on four
  missing 2nd-gen APIs, and the owner's call), App Check's console half, the live-radio measurement,
  and what ADR-0008's option 1 costs.
- **The receiving half of Phase 4's end-to-end row.** Ana's list did show the tap, but her app was
  already running and on that screen, so a foreground push and the resume reconcile cannot be told
  apart. The row wants the app *killed*.
- **`redeemInvite` has never run deployed.** Everything here is the emulator, as the brief instructed.
- **Nothing rate-limits guessing** — `OPEN-QUESTIONS.md` #11, with the arithmetic. The designed
  control is App Check enforcement.
- **Delete protection and PITR are both OFF**, and pairing is the feature that starts producing real
  data. The deadline in `OPEN-QUESTIONS.md` #6 stops being theoretical the moment this ships.

---

## The rig as this session left it

**POCO F3 — the app is UNINSTALLED, deliberately.** It held a link to a synthetic *Mum* on a local
emulator and **81 alarm entries** including armed warning alarms. The emulator has since stopped, so
those alarms would have fired at 10:00 the next morning against a backend that no longer answers and
posted an offline notice about a person who does not exist — on the owner's personal phone.
**Phase 4's recorded POCO state is gone** and is not restorable; a future phase reinstalls.

**AVD `Medium_Phone_API_36.0`** — keeps the paired state: signed in as *Mum*, accepted link to *Ana*,
onboarding complete, today's check-in recorded. Scratch rig; *Wipe store* resets it.

**The emulator export did NOT run.** The suite was killed rather than `Ctrl-C`'d, so `emulator-data/`
is still the 2026-08-25 export and today's users, invites and link are **not** in it. The next
`emulators.ps1` starts from the older state and the AVD's store will reference uids the emulator no
longer knows — **re-pair rather than trying to reconcile it.**

---

## Prompt to start the next session

> I'm starting **Phase 6 — away mode** of the I Am Ok project. Read
> `docs/phases/phase-5-summary.md` first, then follow the reading order in `docs/README.md`.
> `docs/OPEN-QUESTIONS.md` lists what is deliberately unsettled — check its *Blocking-when* table
> rather than re-deriving any of it.
>
> **Phase 5 is COMPLETE and SIGNED OFF** (2026-08-26). Built, its exit criterion **met on two
> devices** — two phones paired from a cold install using only a shared code, each landing on the
> correct main screen — all five reviewers run with their findings applied, all three owner decisions
> taken, and the review round's six open items closed or recorded. **1 193 Dart tests, 75 Functions
> tests, 75 rules tests**, `flutter analyze` clean, debug and release APKs build, secrets guard
> clean.
>
> **Read *Closing the phase* in the summary before you write anything**, because three of the things
> settled there constrain Phase 6 directly: the **empty-audience 21:00 variant** threads
> `hasAudience` through `AlarmScheduler.apply` (Phase 6 changes what suppresses reminders, and away
> is the other input to the same call); the **chooser** put a second action behind the Tap screen's
> *Add someone*, which is now adjacent to the Away control the phase is about to enable; and
> **`PairingRefusal.serverFault`** is the pattern any new refusal copy should follow — *refused is not
> unreachable*, one layer down from ADR-0004.
>
> **Two things about the close-out are worth carrying as habits.** The **mutation harnesses are in
> the repo now** (`tools/mutate-dart.mjs`, `tools/functions-mutate.ps1`) and they refuse to score
> rather than guess — mine refused twice before it scored once, both times on a mistake in the
> harness's caller, and both times that refusal is what made the real cause findable. And **read a
> claim against the thing it describes**: this close-out found a `deploy-notes.md` sentence that was
> false (`@types/node` *was* installed, four majors ahead of the deployed runtime), a documented
> permission check that greps for the wrong kind of thing, and an enum docstring that counted to four
> against seven cases.
>
> **Build against the emulator suite**, exactly as Phase 5 did. A 2nd-gen deploy would still fail —
> four prerequisite APIs are missing — and it is the owner's call.
>
> **Three things about the rig before you touch a device.** The POCO F3 has **no app installed**; the
> AVD holds a paired *Mum*↔*Ana* state; and `emulator-data/` does **not** contain that pairing,
> because the suite was killed rather than stopped, so **re-pair rather than trying to reconcile the
> two**. The close-out changes have **not** been run on a handset — press *Add someone* and take the
> second option first.
>
> **Two traps this phase paid for, both now in `CLAUDE.md`.** Every FlutterFire API that takes an
> emulator host rewrites it on Android unless passed `automaticHostMapping: false` — three plugins,
> three for three, and the failure is *half the app working*. And adding a Dart package can move a
> transitive Firebase one and break **only** the Android build, with analyze and test both green.
>
> **What Phase 6 needs from what Phase 5 built.** Away is a direct client write under rules (§8,
> §12), so it is the first feature since Phase 4 to touch `firestore.rules` — the away validation and
> attribution rules are already written and tested there, and `AwayRules` in the domain is the exact
> 31-day cap. `onAwayChanged` is the **fifth** Function and fans out to *every* party including the
> watched device, which is the first time the watched side receives a push.
>
> **The habit that found everything this phase: run it on a device, and read a claim against the
> thing it describes.** Both defects Phase 5 found were invisible to 1 141 tests — one because the
> AVD makes the wrong address the right one, and one because the defect was *a screen nobody
> reaches*, which no unit test has a way to notice. And when a mutation comes back unexpected, check
> whether the mutation was bad before concluding the test was.
