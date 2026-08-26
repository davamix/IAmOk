# Phase 5 — Onboarding and pairing · summary

**Date:** 2026-08-26 · **1 141 Dart tests**, **67 Functions tests**, `flutter analyze` clean, debug
APK builds, secrets guard clean.

**Status: built, and the exit criterion is MET on two devices.** **Not signed off** — the five
reviewers have not run, and **every new user-visible string is owed the owner's approval**, including
**two changes to already-approved copy**.

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
| **`HomeRoute`** | Domain. Which main screen, from the two answers **unioned with the links**. |
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

**Links outrank the stored answers, and the two are unioned rather than one overriding.** §1 chose
Google Sign-In because *the uid survives a reinstall, so links never break* — which means a cold
install can begin with an empty store and a user who already watches three people. Routing on the
stored answers alone strands a reinstalled watcher on the Tap screen, where the list that re-arms
their warning alarms is reachable only by a notification tap. That is the failure `main.dart` had
warned about for three phases, arriving through the fix for it.

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
is structurally unable to notice. The router is now told once, by `finish()`, and the regression group
asserts the route **while the flow is running**.

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
> **Where Phase 5 left things.** Built, and its exit criterion is **met on two devices**: two phones
> paired from a cold install using only a shared code, and each landed on the correct main screen.
> 1 141 Dart tests, 67 Functions tests, `flutter analyze` clean, debug APK builds, secrets guard
> clean, 42 mutations across two harnesses all behaving as expected with passing no-op controls.
> **Phase 5 has not been signed off** — the five reviewers have not run and every new user-visible
> string is owed approval, including two changes to already-approved copy. That is the owner's call
> and does not block starting here.
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
