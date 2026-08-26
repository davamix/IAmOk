# Phase 5 — Onboarding and pairing · summary

**Date:** 2026-08-26 · **1 161 Dart tests**, **75 Functions tests**, **75 rules tests**,
`flutter analyze` clean, debug APK builds, secrets guard clean.

**Status: built, the exit criterion is MET on two devices, and all five reviewers have run with
their findings applied.** **Not signed off** — **every new user-visible string is owed the owner's
approval**, including **two changes to already-approved copy**, and six findings were deliberately
left for the owner or a later phase rather than decided here.

> **[phase-5-handover.md](phase-5-handover.md) is where to start if you are closing this phase out.**
> It carries the current state, every open item, and a suggested solution for each — this file is
> *what was built and why*.

> **Two phones paired from a cold install using only a shared code**, 2026-08-26 11:12–11:28. The AVD
> was *Mum*, the POCO F3 was *Ana*; both were uninstalled first; the code was read off one screen and
> typed into the other. Mum landed on the Tap screen naming Ana, Ana on the watcher list showing Mum.
> **The AVD also tapped**, which closes the half Phase 4 left owed.

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

## Deliberately NOT fixed, and why

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

## Owed to the owner

**1. Copy approval — every new string.** They are all in `ui-ux/screens.md` under *Sign-in*, *The
three screens, as built*, *Making a code*, *Using a code*, *Why a code did not work* and *The
summary*.

**2. Two changes to already-approved copy**, and these are the ones to look at first:

- `TapCopy.nobodyYet` lost *"Ask a family member to help you add someone."*
- `WatcherCopy.nobody` lost the same sentence.

Both are the **dead-end** wording, which `TapCopy.notificationsOff` records the rule for: *"ask a
family member" is only honest once there is nothing left to press.* There is now an **Add someone**
button directly beneath both lines. The alternative was to keep the sentence and not add the button,
which leaves a skipped first question as a dead end and makes a second watcher impossible.

**3. The five reviewers have not run.** Deliberately left for the owner to trigger — a note in this
repo's memory records that launching them in parallel has twice exhausted the session limit, so they
want running one at a time.

---

## Still owed, and carried

- **Six things the review round left open on purpose** — see *Deliberately NOT fixed* above. The two
  that need an owner decision are the **cross-role dead end** and the **21:00 reminder's promise to a
  family that may not exist**; a third, `couldNotReach` being said when the server answered, needs
  new copy.
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
> **Where Phase 5 left things.** Built, its exit criterion **met on two devices** — two phones paired
> from a cold install using only a shared code, each landing on the correct main screen — and **all
> five reviewers run with their findings applied**. 1 161 Dart tests, 75 Functions tests, 75 rules
> tests, `flutter analyze` clean, debug APK builds, secrets guard clean.
>
> **Phase 5 has not been signed off.** Every new user-visible string is owed approval, including two
> changes to already-approved copy, and six review findings were left open on purpose — two of them
> owner decisions. All are in the summary under *Deliberately NOT fixed*. None blocks starting here.
>
> **The review round is worth reading before you write anything**, because it is the clearest
> catalogue this project has of how its own defects look: fourteen fixes, and almost none of them
> came from a test failing. Two reviewers found the same defect independently; one finding was a
> patch from earlier the same day that had made a defect *latent* rather than absent.
>
> **Build against the emulator suite**, exactly as Phase 5 did. A 2nd-gen deploy would still fail —
> four prerequisite APIs are missing — and it is the owner's call.
>
> **Three things about the rig before you touch a device.** The POCO F3 has **no app installed**; the
> AVD holds a paired *Mum*↔*Ana* state; and `emulator-data/` does **not** contain that pairing,
> because the suite was killed rather than stopped, so **re-pair rather than trying to reconcile
> the two**.
>
> **Two traps this phase paid for, both now in `CLAUDE.md`.** Every FlutterFire API that takes an
> emulator host rewrites it on Android unless passed `automaticHostMapping: false` — three plugins,
> three for three, and the failure is *half the app working*. And adding a Dart package can move a
> transitive Firebase one and break **only** the Android build, with analyze and test both green.
>
> **What Phase 6 needs from what Phase 5 built.** Away is a direct client write under rules (§8, §12),
> so it is the first feature since Phase 4 to touch `firestore.rules` — the away validation and
> attribution rules are already written and tested there, and `AwayRules` in the domain is the exact
> 31-day cap. `onAwayChanged` is the **fifth** Function and fans out to *every* party including the
> watched device, which is the first time the watched side receives a push.
>
> **The habit that found everything this phase: run it on a device, and read a claim against the
> thing it describes.** Both defects Phase 5 found were invisible to 1 141 tests — one because the
> AVD makes the wrong address the right one, and one because the defect was *a screen nobody
> reaches*, which no unit test has a way to notice. And when a mutation comes back unexpected, check
> whether the mutation was bad before concluding the test was: two of three were mine, and scoring
> them as caught would have been the harness lying.
