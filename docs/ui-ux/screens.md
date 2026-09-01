# Screen inventory

**Date:** 2026-08-16 · **Status:** Specification-in-progress. **The Tap screen and the debug harness
were built in Phase 2, the watcher list in Phase 3, sign-in, the three onboarding screens and
both pairing screens in Phase 5, and the away picker in Phase 6.** What remains specification is the
health panel. (This line said *"everything else is still specification"* until 2026-08-25; `guidelines.md`
had the identical claim corrected the same day and this file was missed.)

**Every Phase 5 string below was approved by the owner on 2026-08-26**, at the Phase 5 gate. **Two**
are *deletions* from already-approved copy and **four** are *amendments* to it; each is called out
where it appears. (This paragraph still said the copy was *owed* approval until the gate review — in
the commit whose whole purpose was to record that it is not, which is this file's own recurring
failure mode.)

What is recorded here is **only what has actually been decided** — mostly behaviour and copy,
carried over from [PLAN.md](../PLAN.md) and [ARCHITECTURE.md](../architecture/ARCHITECTURE.md).
Layout, visual design, and anything marked *undesigned* below are open. Do not treat an absence
here as a free choice: add the decision to this file when it is made.

| Screen | Phase | State |
|---|---|---|
| Tap (watched main) | 2 | **Built.** Behaviour, copy and layout decided |
| Debug harness | 2 | **Built.** Debug builds only |
| Sign-in | 5 | **Built.** Not in this inventory before Phase 5 — see below |
| Onboarding 1 — "Who should know you're OK?" | 5 | **Built.** Copy below, approved 2026-08-26 |
| Onboarding 2 — "Who are you looking after?" | 5 | **Built.** Copy below, approved 2026-08-26 |
| Onboarding 3 — summary | 5 | **Built.** Copy approved 2026-08-26. Reports the links that exist, never what was tapped |
| Pairing — create invite / redeem code | 5 | **Built**, proven on two devices, copy approved 2026-08-26 |
| Away picker | 6 | **Built.** Layout decided 2026-08-27; two labels frozen, the rest owed approval |
| Watcher list (watcher main) | 7 | Row content decided; multi-person layout undesigned |
| Health panel | 7 | Checks decided incl. backend access (ADR-0004); layout undesigned |

---

## Onboarding

Three screens, **identical for every user**, each with a Skip option. Role is not asked about
directly — it falls out of two questions about other people, which is a deliberate choice: "are you
the elderly one?" is a question nobody wants to answer.

**Screen 1 — "Who should know you're OK?"**
People who watch **me** ⇒ I am **watched** ⇒ main screen is Tap + Away.

**Screen 2 — "Who are you looking after?"**
People **I** watch ⇒ I am a **watcher** ⇒ main screen is the watcher list.

**Screen 3 — summary.** What was set up, and what happens next.

**Both selected** — Tap + Away takes priority as the main screen, and a top action button opens the
watcher list. The person who taps daily should never have to navigate to reach their one action.

Realistically the family member sets up *both* phones in one sitting; the pairing flow should
assume that rather than assuming two people configuring independently.

> **Designed and built in Phase 5, and proven on two devices.** Three things follow from the
> one-sitting assumption, and they *are* the design:
>
> 1. **The code is sized and grouped to be read aloud across a table** — `K7R TQX`, two groups of
>    three, because six unbroken characters is what people misread and the group boundary is what a
>    reader uses to keep their place when the listener asks them to repeat it.
> 2. **The phone that made the code notices the moment it is used**, with nobody touching it. In the
>    sitting this assumes, the family member is holding the *other* phone — so a confirmation only
>    they could see would leave the person the app is actually for staring at an unchanged screen.
> 3. **Every refusal names a next action**, because in a sitting there is somebody there to carry it
>    out.

---

### Sign-in — **new in Phase 5, and this inventory never specified it**

> **Every string in this section and the five that follow it — *Sign-in*, *The three screens*,
> *Making a code*, *Using a code*, *Why a code did not work*, *The summary* and *Getting back to
> pairing* — was approved by the owner on 2026-08-26, at the Phase 5 gate.** That approval covers
> the two **deletions** from already-approved copy (`TapCopy.nobodyYet` and `WatcherCopy.nobody`),
> and the four amendments taken at the same time: `PairingRefusal.ownCode` rewritten, the expiry
> added to the share message, the watcher-list control given an action label, and a fourth refusal
> `serverFault` added. Each is marked below where it appears.

Phase 4 signed in from the debug harness *precisely so that no un-approved elderly-facing surface
shipped early*. It cannot be avoided here: every link is keyed by a uid, `createInvite` needs one to
name the watched party, and `redeemInvite` needs one to be the watcher. So it is the first thing
onboarding does.

| | Text |
|---|---|
| Title | **"I Am Ok"** |
| Body | *"Tap once a day to say you are OK. The people you choose are told if a day goes by without a tap."* |
| Action | **"Sign in with Google"** |
| Sign-in failed | *"Could not sign in. Check your internet connection and try again."* |
| Signed in, profile write failed | *"Signed in, but this phone could not finish getting ready. Try again."* |

**The body deliberately does not say "your family will be told."** At this point nobody is set up,
and a promise the very next screen has to walk back is worse than a plain description — the same rule
that made `TapCopy.tapTargetLabel` stop saying *"tell your family"*.

**A dismissed account chooser shows nothing at all.** It is a choice, not a fault.

**The profile failure has its own sentence** because it is its own state: the account exists and the
app still cannot be paired with, since `redeemInvite` copies the name and timezone off
`users/{uid}` onto the link (§7). *"Could not sign in"* would send somebody to retry the half that
worked.

### The three screens, as built

| | Screen 1 | Screen 2 |
|---|---|---|
| Question | *"Who should know you're OK?"* | *"Who are you looking after?"* |
| Body | *"Add the people who look after you. They will see that you are OK each day, and they are told if a day goes by without a tap."* | *"If someone has given you a code, type it in here. You will be told if they miss a day."* |
| Action | **"Add someone"** | **"I have a code"** |
| Skip | **"Skip for now"** | **"Skip for now"** |

**"Skip for now" keeps its *"for now"***, and that is the opposite of the choice `TapCopy.nobodyYet`
made when it dropped *"yet"*. There the word asserted a history the app does not track; here it
describes the button honestly — the question really can be answered later, from either main screen.

**A skip is an answer, not an absence.** Somebody who skips both still *completes* onboarding, which
is what stops the app asking an 80-year-old the same two questions every single morning.

### Making a code

| | Text |
|---|---|
| Title | **"Your code"** |
| Body | *"Give this code to the person who will look after you. They type it into their own phone."* |
| The code | `K7R TQX` — large, high contrast, two groups of three |
| Expiry | *"It stops working at 11:14 am on Thursday 27 August."* |
| Share | **"Share this code"** — the Android share sheet |
| The shared message | *"Use this code in the I Am Ok app to look after me: K7R TQX"* — then the expiry line, on its own second line |
| Waiting | *"Waiting for them to type it in."* |
| Someone redeemed it | *"Ana will now know you're OK."* |
| Then | **"Done"** · **"Add someone else"** |

**Why a code could not be made**, which this section did not carry until the gate review. The
screen renders one sentence and a **"Try again"** button.

| The device knows | Says |
|---|---|
| this phone has no `users/{uid}` | *"This phone could not finish getting ready. Try again."* |
| it could not reach the backend | *"Could not reach the internet. Check your connection and try again."* |
| the backend answered, and this build cannot act on the answer | *"That did not work just now. Try again in a moment."* |
| nobody is signed in | *"You are not signed in. Sign in and try again."* |
| Action | **"Try again"** |

Every sentence is the one its twin uses in *Why a code did not work* below — deliberately, because a
family who hits the same fault while making a code and while using one must not be told two different
things about it. The record was the gap, not the copy: `serverFault` was added to **both** enums at
approval and only one of them had a home in this file.

**The confirmation and the refusal are both spoken.** `SemanticsService.sendAnnouncement` carries
*"Ana will now know you're OK."* and the refusal sentence, for the reason the watcher list's
announcements section gives at length: nothing re-reads a changed widget, so a blind reader presses
the button and hears nothing at all. Both are already-approved text.

**The expiry is 24 hours**, the owner's decision, and it is rendered in the device's own zone and its
own 12/24-hour setting through `NotificationCopy`'s formatters — not a third set. The date is written
out; never `27/08`.

> **The shared expiry is a wall-clock time in the *sender's* zone, and that cost is accepted.** The
> share sheet is the path for somebody who is **not** at the same table, so it is the path most
> likely to cross a zone — and *"It stops working at 11:14 am on Thursday 27 August"* is then a time
> that is not the reader's. Bounded, because a code read too late fails with *"That code has expired.
> Ask for a new one."*, which is honest and names the action that works. Recorded rather than fixed:
> the alternative is naming a zone in a sentence an elderly person reads, and the failure it would
> prevent already lands somewhere safe.

**The code is spelled out for a screen reader** — `K 7 R T Q X` — because "K7RTQX" is read as a word
and a listener cannot spell a word back. The visual grouping is for the eye; the spelling is the same
information for the ear.

***"Ana will now know you're OK."* reuses `TapCopy.willKnow`'s sentence shape on purpose**, so the
words that confirm the pairing are the words the Tap screen shows every day afterwards.

**The shared message is the only string in this app that reaches a phone without it installed**,
which is why it names the app rather than assuming the reader knows what a code is for. It was
missing from this file until Phase 5 closed.

> **Amended at approval, 2026-08-26: the expiry goes with it.** The message used to end at the code.
> A code shared at 9pm and read the next morning is dead, and the recipient's first experience of I
> Am Ok was a code that failed with no way to tell an expired one from a mistyped one — while the
> sender was reading the expiry on their own screen the whole time. It is `codeExpiry`'s own
> sentence, the same one rendered above the button, in the **sender's** zone, because that is the
> phone the code was made on.
>
> **The code stays at the end of its own line and nothing is punctuated after it.** A full stop
> there is a character somebody can type into a six-character field, and `InviteCode.tryParse`
> strips only spaces and hyphens. That is why it is a second line and not a second clause.

**This is not a status-change message about watchers.** `WatchedAudience` rejects *"X started
watching you"* outright, and this does not reopen it: it confirms an action taken seconds ago on this
screen, against a baseline captured when the screen opened, and it is never shown for a pairing that
happened at any other time.

### Using a code

| | Text |
|---|---|
| Title | **"Type the code"** |
| Body | *"Type the six characters you were given."* |
| Field label | **"Code"** |
| Action | **"Use this code"** |
| Paired | *"You are now looking after Mum."* |

**Lower case is accepted and upper-cased as they type**, and spaces and hyphens are stripped — a
phone keyboard defaults to lower case, and somebody who types the grouping they were read must not be
punished for it.

**`O` is not silently read as `0`, and `I` is not read as `1`.** Neither digit is in the alphabet
either, so there is no character a substitution could arrive at, and guessing at what somebody meant
is how a family ends up paired to the wrong person.

**The code is spoken character by character** — `K 7 R T Q X` — for the same reason it is grouped
visually: "K7RTQX" is read as a word by a screen reader and a listener cannot spell a word back.

**The confirmation and every refusal are announced**, as on the other pairing screen and for the same
reason.

### Why a code did not work — **every branch is a claim**

| The device knows | Says |
|---|---|
| no invite with that code | *"That code is not right. Check it and type it again."* |
| the code's 24 hours are up | *"That code has expired. Ask for a new one."* |
| somebody else redeemed it | *"That code has already been used. Ask for a new one."* |
| it is the redeemer's own code | *"That code belongs to this phone. Type it into the other one."* |
| the other party's profile or timezone is unusable | *"That code did not work. Ask them to open I Am Ok on their phone, then try again."* |
| **this** phone has no profile | *"This phone could not finish getting ready. Try again."* |
| this phone could not reach the backend | *"Could not reach the internet. Check your connection and try again."* |
| the backend answered, and this build cannot act on the answer | *"That did not work just now. Try again in a moment."* |
| nobody is signed in | *"You are not signed in. Sign in and try again."* |

> **Only the first four are rendered on the code field — settled at the gate review, 2026-08-26.**
> `errorText` does not merely print a sentence: it puts the field into its **error state**, red
> outline and red *"Code"* label. Every refusal went there, so a server fault, a dead radio or a
> missing profile on *this* phone all marked the code invalid — a second, wordless claim, and the one
> a reader takes first, on paths where nothing whatever is known about the code.
>
> The copy already said this must not happen (*"The last four are not the reader's mistake and none
> of them says 'not right'"*); the screen contradicted it in colour. What a family member saw was:
> type a perfectly good code, the field turns red, retype the same six characters, loop.
>
> The other five now render **above the action button**, in the same words, without the claim. The
> split lives in the domain as `PairingRefusalSurface.isAboutTheCode` and is exhaustive, so a refusal
> added later cannot default into either bucket.

**The failures are distinguished rather than collapsed**, and that is a deliberate trade recorded in
ADR-0011: collapsing them leaks marginally less, but these tell a family three different next
actions, and *check what you typed* against *ask for a fresh one* is the difference between a loop
that can succeed and one that cannot.

**The last four are not the reader's mistake and none of them says "not right".** *"Could not reach
the internet"* in particular claims nothing about the code — nothing was decided.

> **Amended at approval, 2026-08-26: the own-code sentence names a phone, not a relationship.** It
> read *"That is your own code. Ask the person you are looking after for theirs."* This branch fires
> when the watched person's own code is typed into the watched person's own phone — and this file
> already records that the family member realistically sets up **both handsets in one sitting**, so
> the reader is overwhelmingly somebody holding the wrong one of two phones on a table. The old
> sentence sent them to ask a question of the person sitting next to them, about a code they were
> already holding. The new one names the fix: move phones.

> **Added at approval, 2026-08-26: a fourth outcome, because *refused is not unreachable*.** Four
> paths said *"Could not reach the internet"* about a phone that had demonstrably reached it — an
> `internal` from a failed transaction, any wire status this build has no case for, a malformed
> `created` payload, and a `not-found` from a region mismatch. It is
> [ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)'s rule reappearing one
> layer down: a claim about the **device** that is false, naming an action — *check your connection*
> — that cannot work.
>
> *"That did not work just now. Try again in a moment."* is deliberately the one sentence here that
> claims nothing about **either** side. The reader cannot repair a failed transaction on the far
> side and cannot repair a build a version behind the backend, so naming a cause would name one they
> cannot act on.
>
> *"Could not reach the internet"* is now **narrow**: `unavailable` and `deadline-exceeded`, the two
> gRPC codes that mean the request did not arrive. Everything else is the new sentence.

### The summary

| Who | Says |
|---|---|
| Title | **"You're all set"** — **rendered only when there is something to report** |
| watched | *"Ana will know you are OK when you tap each day."* + *"Tap once a day. That is all."* |
| watcher, one person | *"You will be told if Mum misses a day."* |
| watcher, several | *"You will be told if Granddad and Mum miss a day."* |
| nothing set up | *"Nobody is set up yet. You can add someone at any time."* |
| this phone could not read it back | *"This phone could not check what is set up. Your main screen will show it."* |
| Action | **"Finish"** |

**Built from the links that exist, never from what was tapped.** Somebody who chose *"Add someone"*
and closed the code screen without anybody redeeming has set nothing up, and a summary claiming
otherwise would be the first false claim this app ever made to a family. `HomeRoute` unions intent
with evidence to decide *where to go*; this screen reports evidence only.

**The title and its green tick are gated on there being something to report**, and were not until the
Phase 5 review. Somebody who skipped both questions finished onboarding reading *"You're all set"*
above a success tick above *"Nobody is set up yet."* — a contradiction on the last screen of setup.
Neither the title nor its render condition was in this file before Phase 5 closed.

***"Nobody is set up yet"* keeps its *"yet"*, and it is the second exception on this page.** The word
was struck from `TapCopy.nobodyYet` and `WatcherCopy.nobody` at the Phase 2 gate because it asserts
**not started**, which is false in the other state those lines cover — the last link was revoked, so
something *was* set up. That objection does not reach here: this screen is the end of onboarding,
seen once, before anything has ever been set up, so *"yet"* is true of every reader who sees it.
Recorded rather than left to be re-derived, which is what *"Skip for now"* two sections up already
gets.

**The failed-read sentence claims nothing either way.** Without it a failed read renders as the empty
state — somebody who has in fact paired would be told they had not, by a device that just failed to
find out. Same rule as the four warning messages: say what is actually known.

### Getting back to pairing — **"Add someone"**

Reachable from **both** main screens: a secondary text button on the Tap screen beneath the audience
line, and an app-bar action plus an empty-state button on the watcher list. Without it, somebody who
skipped the first question lands on a Tap screen naming nobody with nothing to press, and a second
watcher could never be added at all — an invite is single-use, so every watcher needs their own code.

**On the Tap screen it opens a chooser; the watcher list's own control is "I have a code".** That
screen has exactly one thing to add, and until the Phase 5 review *"Add someone"* meant two opposite
things across the two screens — produce a code here, consume one there.

| The chooser | Text |
|---|---|
| Title | **"Add someone"** |
| Produces a code | **"Someone to look after me"** → *Your code* |
| Consumes one | **"Someone I look after"** → *Type the code* |

> **Added at approval, 2026-08-26, and it closes a dead end rather than adding a feature.** *"Add
> someone"* opened the code screen and only the code screen, while the only route to *Type the code*
> was the watcher list — which is reachable from the Tap screen **only by somebody who is already a
> watcher**. So anybody who answered *"Skip for now"* to onboarding's second question could never
> take up that role: no error, no wrong screen, nothing anywhere to press.
>
> **It was invisible to the whole test suite**, for the same reason the unreachable summary screen
> was: the defect is *a screen nobody reaches*, and no assertion about a screen's contents can
> notice one that never opens.
>
> **Two options, framed as two people and never as two roles** — the same rule PLAN.md fixes for the
> two onboarding questions these mirror. *"Are you the elderly one?"* is a question nobody wants to
> answer.
>
> **A sheet rather than a second button on the screen**, because `guidelines.md`'s first principle is
> one screen, one action, and `WatchedAudience` records at length how firmly this project refuses
> extra surfaces there. It costs the elderly user nothing in daily use: they never press the control
> it sits behind. Rejected: making the watcher list permanently reachable from the Tap screen (no new
> copy, but a permanent second icon there, and it contradicts PLAN.md, which specifies that button
> for a both-roles user); and accepting the dead end until Phase 7 (cheapest, and it leaves a real
> family able to get stuck).

**Dismissing the chooser says nothing**, and that is the same decision this file records by hand for
the Google account chooser two sections up: a dismissal is a choice, not a fault. A back gesture, a
drag down or a tap outside all return without opening anything.

**The chooser scrolls.** A default bottom sheet caps its child at 9/16 of the screen height, and at
the largest system font scale the second option falls past that — measured at 338 pixels of overflow
on a 320×480 screen at scale 2.0, which in a release build is a **silent clip**. The option that
would be cut is *"Someone I look after"*, so the dead end this chooser closes would come back for
exactly the readers most likely to be running a large font.

**The two secondary controls on the Tap screen sit in this order: *Add someone*, then *I'm away*, 20dp
apart.** Recorded because Phase 6 makes it matter — they are two text buttons of the same weight, and
Away is inert until then. `guidelines.md`'s mis-tap reasoning is about the distance from the *tap
target*, which is still satisfied; what it does not consider is a nearer neighbour of equal weight.
**Give Away visible separation in the same change that enables it**, not after.

> **Done, Phase 6: a divider between them**, indented, with 20dp either side. A rule is a signal a
> reader takes at a glance; a gap is one they have to measure. Both controls stay text buttons — the
> equal weight is fine once there is a structural break between them — and the 48dp floor is
> asserted at every font scale.
>
> **The divider is the weakest of three signals, and the strongest was never written down.** Pressing
> *I'm away* opens a **full screen with its own Save button**, so a mis-tap in the dangerous direction
> already has an inherent confirmation and costs one back gesture. *Add someone* is also a
> `TextButton.icon` while *I'm away* is a bare `TextButton`, so the pair are not in fact look-alikes.
> Recorded because the separation should not rest on the hairline alone.
>
> **The band scrolls, and its thumb is now always visible.** The away state adds the tallest element
> on a band that is 36% of the screen — two sentences at `headlineSmall` — which at the largest font
> scale pushes the Away control below the fold. That is the one control a person needs in order to
> act on reading that somebody else marked them away, so a hidden scroll is a discovery problem for
> exactly the reader this app is for.

**The control that opens the watcher list is labelled *"See who you look after"***, which is not the
list's title. A title says what a screen **is**; a control's label says what pressing it **does**, and
this one is an icon button — so that string is a screen-reader user's whole identification of their
only route to the other half of the app. *"People you're looking after"* read out as a control's name
announces a place somebody has landed on rather than a door. Approved as a title, it had been reused
as a label for want of a second string; the second string was added at approval, 2026-08-26.

> **It forced a change to two already-approved strings, and the change was required rather than
> tidying.** `TapCopy.nobodyYet` ended *"Ask a family member to help you add someone."* and
> `WatcherCopy.nobody` ended the same way. That is the **dead-end** wording, and
> `TapCopy.notificationsOff` records the rule it follows: *"ask a family member" is only honest once
> there is nothing left to press*. There is now something to press, directly beneath both lines, so
> both second sentences are gone. What remains is the same true statement about the same two states,
> with the next step supplied by the button instead of by a sentence.
>
> **Both shortened lines were approved on 2026-08-26**, with the rest of this phase's copy. The
> alternative — keep the sentence and *not* add the button — was rejected because it leaves a
> skipped first question as a dead end and makes a second watcher impossible.

---

## Tap screen — watched main

The only screen the watched person needs.

| State | Shows |
|---|---|
| Not yet tapped today | The tap target, enabled, reading **"I'm OK"**. Large, high contrast, minimal chrome. |
| Tapped today | Target **disabled for the rest of the local day**. The target itself changes to a tick and **"Tapped"**, and the line beneath reads *"You already tapped today, at 09:14."* Re-enables at local midnight. |
| Away — **built, Phase 6** | *"Ana marked you away until Saturday 22. Your family isn't expecting a check-in."* when somebody else set it; *"You're away until Saturday 22. …"* when she did, or when the document names nobody. Rendered **above** the tap confirmation — it is the frame for the rest of the screen. Tapping is still **allowed** and the target stays enabled: harmless, reassuring, and it writes a normal check-in watchers see as usual. See *The away line names who set it* under **Away picker**. |

The Away control is present but visibly secondary, and not adjacent to the tap target. It reads
**"I'm away"**, and while an away period is active **"I'm not away"**. **Live since Phase 6.**

**No confirmation step on the cancel, decided 2026-08-27.** A mis-tap on *"I'm not away"* fails
**loud** — reminders and warnings come back, which is this app's default-safe state — and setting
away again is two taps. A confirmation dialog would be a third surface on the screen `WatchedAudience`
records this project refusing extra surfaces on. The mis-tap worth defending against is the *other*
direction, pressing **away** by accident, which is silent; that is what the separation below is for,
and the screen states the outcome in words the moment it happens.

### The tapped state changes the target, not only its colour

The target previously kept saying "I'm OK" and went grey, leaving the answer to *"did I tap?"* as
small text at the far bottom of the screen. She looks at the circle, sees the same two words, taps,
gets nothing — and worries, which is the exact scenario the confirmation exists to prevent. Colour
was the only signal, on the one control that matters.

### Everything else this screen says

| When | Text |
|---|---|
| Notifications are off | *"This phone will not remind you to tap."* with a **"Turn reminders on"** button |
| The tap did not save | *"That did not save. Please tap again."* — beneath a target that stays on screen and stays **enabled** |
| The app could not start at all | *"This phone could not get ready. Ask a family member for help."* with **"Try again"** |
| Spoken (TalkBack), untapped | *"Tap to say you are OK today"* |
| Spoken (TalkBack), tapped | *"You already tapped today, at 09:14."* |
| Spoken, while loading | *"Getting ready"* |

**The spoken labels are approved copy like any other**, and are the only thing some readers get. The
untapped one deliberately does **not** say "tell your family": with an empty audience the next line
on the same screen says nobody is set up, and a label that contradicts the screen it is on is worse
than a terse one — the reader who depends on it cannot see the contradiction to discount it.

**The notifications-off banner is about her own reminders**, never about watchers, so it does not
collide with the decision above. It carries an action because *"ask a family member"* is the
**dead-end** wording and is only honest once there is nothing left to press. The app requests
`POST_NOTIFICATIONS` once on first run; on API 33+ it is denied by default, so without that the
first launch would show a red banner about a permission the app had never asked for, and no reminder
would ever fire.

**A failed tap never takes the screen away.** Replacing the whole screen at the moment she taps
removes her one action, and the full-screen message would claim the phone could not get ready — which
is not what happened. That message is reserved for a failed initial load.

### The three notification channels, as she sees them in Android Settings

| Channel | Description |
|---|---|
| Daily reminders | *"Nudges to tap I'm OK, at midday, evening and night."* |
| Missed check-ins | *"Tells you when someone you watch has not checked in."* |
| App problems | *"Tells you when I Am Ok cannot check on someone."* |

These are user-visible text and are approved here like any other string.

> **Settled in Phase 5: all three channels are still created on every phone, deliberately.**
>
> This was marked *"open before Phase 5"* on the grounds that role is not known until onboarding
> runs, so a watched person browsing Android's settings sees two channels describing things she does
> not do. Onboarding now *does* know the role — and creating the channels conditionally was still
> rejected, for three reasons:
>
> - **A channel that does not exist is a notification that silently does not post.** That trades a
>   cosmetic oddity in a settings screen nobody opens for a lost warning, which is the worst thing
>   this app can do. The trade is not close.
> - **Role is not stable.** Any user can be handed a code and become a watcher minutes later, from
>   either main screen. A channel set fixed at onboarding would be wrong for exactly the people who
>   changed their mind — and the alarm and FCM isolates create channels too, from a bare isolate that
>   would have to read the role off disk to decide.
> - **Android remembers a deleted channel's settings**, so "delete it and recreate it if the role
>   changes" does not restore a default — it restores whatever that user had last set, including
>   *off*.
>
> The descriptions are **honest for everyone as written**: each says what the channel does, and a
> channel that never fires is not a false claim about anybody. Recorded here as a decision so it is
> not re-opened as an oversight.

### The layout is a Stack, and that is load-bearing

**The tap target is centred against the whole screen, not against the space left over.** The
obvious construction — a column with the target in the middle and the text below it — makes the
target's position depend on how tall the text is, so it shifts upward the moment *"You already
tapped today"* appears, and again when a third watcher is added.

The guideline is that the target "does not move — muscle memory is the feature; a layout that
reflows is a bug", and a column breaks that **every day, at the moment of the tap**. It was written
as a column first and caught by the widget test *"does not move between the two states"*, which is
now the regression guard.

**The first fix introduced a worse defect, and the review caught it.** A bare `Stack` removed the
movement and allowed *overlap*: the text below was free to grow upward over the target, and at the
largest system font scale — set by exactly the person this app is for — it painted on top of the
circle, unreadable, absorbing her taps because a paragraph hit-tests true. Landscape did the same at
default scale. The font-scale test could not see it, because a `Stack` with `Positioned` children
never reports overflow.

The layout now **reserves a band** for everything below the target and sizes the target against the
region above it, so the two cannot meet. The test asserts no text rectangle intersects the target's,
at 2× scale, on a small screen, in every state that grows the band.

**The screen names who will be notified when she taps.** Decided at the Phase 1 gate; **copy
approved and the empty case settled with the owner in Phase 2.**

| State | Line |
|---|---|
| One watcher | *"Ana will know you're OK."* |
| Two | *"Ana and Beto will know you're OK."* |
| Three or more | *"Ana, Beto and Carmen will know you're OK."* |
| **Nobody** — never paired, **or** the last watcher revoked | *"No one is set up to know you're OK. Ask a family member to help you add someone."* |

The wording deliberately echoes onboarding screen 1, *"Who should know you're OK?"*, so the same
words that asked the question at setup answer it every day. Names are sorted and the list is joined
without a serial comma, matching the British English used throughout.

> **Nothing else about watchers is ever shown on this screen — no "X started watching you", no
> "Y stopped watching you", no "nobody is watching you" *warning*.** Owner's decision, recorded so it
> is not re-proposed. If everyone stops watching, that is a family problem or a lack of
> communication, not the app's responsibility. And a watched person overwhelmed by several
> similar-sounding status messages is worse off than one reading a single unchanging line — elderly
> users are not ready to read a lot, and may not distinguish what the different messages mean.
>
> This knowingly accepts the exposure the Phase 1 security review raised: if the last watcher
> revokes, she goes on tapping and no surface says otherwise. That is the trade, made deliberately
> in favour of a screen she can read at a glance.

**On the empty line, which is the part most likely to be challenged.** The owner's Phase 2 ruling
was that showing *nothing* is unhelpful — a big button and no explanation is its own silent failure
for someone who has never been paired — so the empty state says what is true and names a next step.

**"yet" was removed at the Phase 2 review**, by two reviewers independently. It asserts *not
started*, which is false in precisely the post-revocation state — something *was* set up and is not
any more. Deleting the word keeps one line for both states and stops it claiming a history the app
does not track. It is not a re-proposal of anything on the rejected list; it is the same line, made
true in both states.

It is **one line covering both** "nobody yet" and "everyone revoked", and that is the decision
rather than a limitation. Distinguishing them requires tracking that someone *left*, and rendering
that is the "someone stopped watching you" message on the rejected list, under another name. So the
line never announces a change: it describes what is true now, in the same words, whichever way the
screen arrived there. It is styled as ordinary secondary text, never as a warning — asserted in
`test/widget_test.dart`, because making it red would reintroduce the rejected message through
styling rather than wording.

Reminders — display-only notifications at **12:00, 18:00, 21:00** watched-local — are cancelled by
the tap and are absent entirely on away days.

## Debug harness

Debug builds only. Built in Phase 2, **alongside the first alarm rather than after it** — without
it, verifying a 24-hour behaviour takes 24 hours.

Force the current date · fire any alarm now · inject a synthetic FCM payload · dump `LocalStore` ·
run `reconcile()` on demand.

## Away picker

**Built in Phase 6.** A calendar picker where the selected day is labelled unambiguously:

> **Last day away: Saturday 22** · Back on Sunday 23

"Until Saturday" alone is ambiguous about whether Saturday still needs a tap. The start date is
**always today** — the calendar selects the last away day only, and there is no future-dating in
v1. Maximum 31 days — the last selectable day is 30 days after today.

Every surface that displays an away period names who set it: *"Ana marked Mum away until Sat 22 Aug."*

### The layout, decided 2026-08-27

Marked *undesigned* here since Phase 3; these are the decisions taken when it was built.

**A full screen, not a dialog.** A calendar plus two sentences plus a 48dp action does not fit a
dialog at the largest system font scale on a small phone, and a `Column` that overflows its
constraint is **clipped in release** — silently, with no overflow stripe. That is the defect the
Phase 5 gate measured in the *Add someone* sheet (338 pixels of overflow at scale 2.0 on 320×480),
and the floor `guidelines.md` sets is the largest scale with no clipping. The screen scrolls.

**Both labels render live, beneath the calendar**, and update as the selection moves. A label that
only appeared after confirming would be describing a choice already made rather than disambiguating
the one being made — which is the entire job of the second sentence.

**The two are one utterance to a screen reader**, in a live region. The second sentence is what
resolves the first, so a reader who got only one of them is back where *"until Saturday"* left them.

**The last selectable day comes from `AwayRules.maxDaysAhead`**, not from a number typed into the
widget. So the picker cannot offer a day the client's own validation would refuse — which is why
`AwayRefusal.rejectedPeriod` is reachable only by the device's date moving underneath the reader
between opening the picker and confirming it, and not by anything they can press.

**An out-of-range stored period is clamped, not trusted.** The Firestore rules are deliberately
slacker than `AwayRules`, so a period the server legitimately accepted can sit a day or two past
what this screen may offer — and `CalendarDatePicker` asserts on an `initialDate` outside its own
bounds. Unclamped, the screen would crash for exactly the family whose period sits on the boundary.

**Dismissing says nothing**, and there is a control as well as a back gesture: `guidelines.md`
forbids a gesture being the only route to an action. The same decision this file records by hand for
the *Add someone* chooser and the Google account chooser — a dismissal is a choice, not a fault.

### Copy — **owed the owner's approval**

The two labels above are frozen and were approved long ago. Everything else the picker and the away
write path say is **drafted, not approved**, and is listed here so approval has something to read.
`AwayCopy` is the code-side twin.

| | |
|---|---|
| Picker title | *"Choose the last day you are away"* — names the one thing this screen collects. `from` is always today, so a title offering a range would promise a choice the screen cannot make |
| Confirm | *"Save"* |
| Dismiss | *"Go back"* — **amended at the gate**; on a screen about away *dates*, *"Not now"* reads as *"I'm not away now"* or *"start later"* rather than *"leave this screen"* |
| Write queued offline | *"Saved. Your family will see this as soon as this phone can send it."* — **amended at the gate**, see below |
| Refused — the period | *"That day does not work. Choose a day within the next month."* — *within*, so it cannot be read as *"during next month"* |
| Refused — the server said no | *"That could not be saved. Try again, and ask a family member if it keeps happening."* — **amended at the gate**, see below |
| Refused — a server fault | *"That did not work just now. Try again in a moment."* — **`PairingRefusal.serverFault`'s approved sentence, verbatim** |
| Refused — not signed in | *"You are not signed in. Sign in and try again."* — the pairing screens' sentence, verbatim |
| Watched screen, somebody else set it | *"Ana marked you away until Saturday 22. Your family isn't expecting a check-in."* — **approved 2026-08-27**, see *The away line names who set it* below |
| Watcher row | *"Away until Sat 22 Aug — set by Ana"* — already approved; *"Away until Sat 22 Aug"* is the unattributed variant |
| Watcher row control | *"Mark Mum away"* / *"End Mum's away period"* |

> **There is deliberately no *"could not reach the server"* refusal**, and its absence is
> [ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)'s rule one layer below
> `PairingRefusal.serverFault`. Away is a direct client write so it **queues offline** (§8), and
> Firestore replays it when the connection returns — so a write that has not confirmed is either
> still in flight or queued behind a dead radio, and the client cannot tell those apart. Both end
> with the write landing. Saying *"could not reach the server"* would tell somebody their family had
> not been told about a write that arrives ninety seconds later, and the obvious response is to set
> the period again. **`queued` is the honest name for the state that actually exists.**

> **And then the queued sentence said it anyway, in the affirmative.** It read *"Saved. Your family
> will see this when this phone is back online."* — which asserts the phone is **offline**, on a path
> reached purely from a six-second timeout: a slow server, a congested cell, or a cold Firestore
> connection on a phone with five bars all land there. That is `guidelines.md`'s *"'your phone has
> been offline' is a claim about the **device** that is false whenever the server was reached"*, said
> the other way round, one paragraph after refusing to say it. Amended at the gate to *"as soon as
> this phone can send it"*, which is true in both states.

> **The refused-by-the-server sentence claimed a permanence it cannot know.** It read *"I Am Ok is no
> longer allowed to change this"* — but Firestore returns `permission-denied` for a **shape**
> violation as readily as an authorisation one, and these rules validate shape aggressively, so it is
> reachable whenever the cached period is stale: a reinstall, *Wipe store*, a second device, or two
> parties writing seconds apart. It also named no next step, which `guidelines.md`'s Floors require of
> every error. Amended at the gate.

### Owed decisions this phase opened and did not close

Recorded rather than left implicit, because in each case the **code has already decided** and an
absence here would read as a free choice.

| | |
|---|---|
| **Extending a period in force** | §12 says away may be *set, extend or cancel*, and `AwayRules.validateUpdate` exists for it — but both surfaces flip their control to *end* while a period is in force, so the picker is unreachable and extending is **not possible in v1**. The documented workaround is destructive: end the period (which truncates to yesterday, re-attributed to whoever pressed it) and set it again from a date nobody has written down. Either offer both actions while away, or record the limitation in §12. |
| **The watcher row's cancel has no confirmation, and its argument is different** | The Tap screen's *"I'm not away"* decision (below) rests on *the failure is loud and setting it again is two taps*. Neither holds on the watcher row: cancelling **truncates**, so a mis-tap on day 3 of a 14-day hospital stay destroys the remaining 11 days; what is loud is a warning waking the rest of the family about somebody who is genuinely away, and none of them mis-tapped. |
| **Nothing is said when a write lands** | `AwayCopy.saved` is null. Defensible on the Tap screen, whose own away line is a better confirmation than a toast because it is still there tomorrow. On the **watcher row** the only feedback is a status line changing under a reader who may not be looking at it. |
| **The writer nobody can name** | An account with no display name writes `AwayCopy.unnamedWriter` (`"Someone"`), because the rules require the field. It is suppressed at render so the approved unattributed line shows instead. A real person actually called this loses their attribution — the right way to be wrong, but a decision. |
| **The spoken outcome strings** | The write outcome is now announced on both surfaces (`SemanticsService.sendAnnouncement`), reusing the rendered sentence. This file's own rule is that spoken labels are approved copy like any other. |
| **The picker title addresses the wrong person on the watcher's phone** — *added from the device run, 2026-09-01* | `AwayCopy.pickerTitle` is *"Choose the last day **you** are away"* and both surfaces use it. Seen on a device, the watcher opens it from *"Mark Mum away"* and is then asked about herself. The title is drafted, not approved, so this is an observation for that approval rather than a defect: either a second string naming the person, or accept that the screen's own heading is about the reader's action. |
| **An away period set offline says *"Saved."* and changes nothing on that phone** — *measured on a device, 2026-09-01* | With the radio off, the write queues, the sentence appears, and then `self_away` stays empty, the away line does not appear, the control still reads *"I'm away"*, and the reminders for the away days stay armed — until some unrelated reconcile runs. The watched side takes its away row from a **read-back**, and `onAwayChanged` deliberately **skips the setter**, so the one phone certain not to be told is the one that wrote it. On the plane §8 names, it goes on reminding her through the period she was told was saved. This is the same decision as *Nothing is said when a write lands*, seen from the other side: either the write updates local state optimistically, or the confirmation has to stop claiming more than the phone knows. Full measurement in [device-matrix.md](../testing/device-matrix.md). |

### The away line names who set it — **decided 2026-08-27 · OWNER**

The item this file carried as *"Owed before Phase 6 ships the away picker"* since Phase 3, now
settled. `TapCopy.away` named nobody while this file requires every away surface to name who set it,
and the two contradicted.

**The rule adopted: name who set it *when it wasn't you*.**

| Who set it | The watched person reads |
|---|---|
| A watcher | *"Ana marked you away until Saturday 22. Your family isn't expecting a check-in."* |
| Herself | *"You're away until Saturday 22. Your family isn't expecting a check-in."* — the already-approved string, **unchanged** |
| Nobody nameable | The same unattributed string — see below |

It reads the way a person speaks, and it keeps the approved string exactly as it was for the case
she did it herself. **It is the surface §17's mitigation depends on**: that risk — *one watcher
silences the whole family by setting away* — is accepted by design, and the recorded control is
`setByName` on every surface plus anyone being able to cancel. This screen is read by the one person
best placed to notice *"I am not away"*, so a line here naming nobody would have left the mitigation
resting on surfaces she never sees.

**The unattributed line is also the fallback**, and that is the right fallback rather than a
convenient one. [ADR-0003](../architecture/decisions/0003-away-attribution.md)'s *Absence* case — an
older build or an admin write omitting the name — must degrade to an away period nobody is named
for, never to *"?? marked you away"* and never to no away period at all. Dropping the period would
warn a family about days somebody really did mark away.

*"marked … away"* rather than a new phrasing, because it is already this file's approved vocabulary
for the act (*"Ana marked Mum away until Sat 22 Aug."*), and one verb for one action is worth more
than a sentence tuned in isolation.

## Watcher list — watcher main

One row per watched person. Per row: the person's name, current status, and the away action.

| Status | Row reads |
|---|---|
| Checked in today | Last check-in time |
| Unresolved warning | The warning, unresolved |
| Away | *"Away until Sat 22 Aug — set by Ana"* — in the app, never as a notification. **Built in Phase 6** — see below |
| Stale / offline | Last successful update, honestly dated |
| The link ended | *"Your link with Mum has ended."* + what that costs |
| This phase could not check the link at all | A fault about **us**, naming the person, with a control — see the Phase 3 copy below |

**The away row was deliberately absent in Phase 3, and that was a decision rather than an
omission.** No user could set an away period, and building the row would have broken a rule this
document sets: **every surface showing an away period names who set it**, while `AwayPeriod` carried
no attribution. An unattributed *"Away until Sat 22 Aug"* is exactly the away state the guidelines
forbid.

**Phase 6 built it, with the attribution that makes it honest.** `AwayRecord` carries `setBy` and
`setByName` alongside the period; `WatcherScreen._status()` gained the branch **above "Everything
OK"** exactly where this file said it would, and `WatchedRowKind` gained an `away` case so the
precedence lives in one place rather than in the widget.

Three things settled while building it:

- **It is keyed on *her* today, not on the day the warning decision is about.** The decision is
  about `D` — the last completed day in her zone — so a period starting today does not touch it, and
  a row keyed on `D` would read *"Everything OK"* on the first day of a holiday, with a last-seen
  date about to stop moving for a fortnight and nothing saying why. `decision.day.next` is her today
  by definition, so there is no second source to disagree at a watched-local midnight.
- **A standing warning still outranks it.** The two look mutually exclusive and are not:
  `warnUnverifiableAway` is a warning *about* an away period this device could not re-verify, and it
  must render as the warning it is rather than as a calm *"Away until Saturday"* claiming a certainty
  the read never established.
- **It is not error-coloured.** Nobody is expected to tap, so nothing is wrong — *quiet confirm, loud
  miss* keeps alarm styling for a miss. The same decision the revoked row makes, for the same reason.

**The unattributed variant is *"Away until Sat 22 Aug"***, a subtraction from the attributed line
rather than a rewording, so the two states cannot describe the same thing differently. It renders
for ADR-0003's *Absence* case, and the period is still shown, because dropping it would warn a
family about days somebody really did mark away.

**The away action sits outside the row's single utterance.** The row is one stop for a screen reader
(`ExcludeSemantics` under one `Semantics` label); a control folded into it would be unreachable.
Both labels name the person — *"Mark Mum away"*, *"End Mum's away period"* — because the list holds
several rows and a bare *"Mark away"* is ambiguous about whom to somebody swiping through it. **A
revoked link offers no control at all**: §8 gates the away write on `isSelf(uid) ||
hasAcceptedLink(uid)`, so offering it would be offering an action refused by design.

**Cold open shows current state, not the most recent event ever.** An unresolved warning if one
stands; otherwise "Everything OK" with the last check-in time. A warning from three weeks ago
followed by three weeks of check-ins is history.

Multiple watched people is supported by the data model and **not yet designed** as a layout.

### Built in Phase 3 — approved copy

The screen exists from Phase 3 because it is **where the *lost access* notification lands**, and
that message promises *"Open the app to see what to do."* Layout stays as above: undesigned, and
Phase 7's problem. What follows is the wording.

| When | Text |
|---|---|
| Screen title | *"People you're looking after"* |
| Nobody is watched | *"You're not looking after anyone. Ask a family member to help you add someone."* — **no "yet"**, see below |
| Warnings switched off | *"This phone will not warn you about anyone."* + **"Turn warnings on"** |
| A link this pass could not check | *"Can't check on Mum — this phone could not finish checking just now."* |
| …and what to do about it | *"If this is still here tomorrow, ask whoever set up the app."* + **"Try again"** |
| Spoken when a tapped notification opens a row | *"Showing Mum."* |
| Spoken when a row stops carrying a warning **because a check-in arrived**, while the list is open, unasked | *"Mum checked in. Everything OK."* — approved 2026-08-25, see below |
| Spoken when a row **starts** carrying one, same conditions | **The notification's own sentence, verbatim** — *"No check-in from Mum yesterday."* — approved 2026-08-25, see below |
| The load failed | *"This phone could not check on anyone. Try again, or open the app later."* + **"Try again"** |
| No warning standing | *"Everything OK"* |
| …with a check-in read | *"Your phone last saw a check-in on Saturday 15 August."* |
| …with none ever read | *"Your phone has not seen a check-in yet."* |
| A warning standing | **The notification's own sentence, verbatim** |
| Every row, always | *"This phone last checked Tuesday 10:14."* |
| …and none has ever succeeded | *"This phone has not been able to check even once."* |
| Spoken (TalkBack), per row | *"Mum. "* followed by the row's lines |
| Spoken, while loading | *"Checking"* |

### A row that changes under a screen reader is announced — approved 2026-08-25

`NotificationDelivery.redundant` means *the watcher is looking at the screen that already shows
this*, so nothing is posted and the day is recorded as seen. The argument has always been that the
list renders the change itself — and until Phase 4 that was true, because `redundant` was reached by
**navigating here**, so the row was read fresh on arrival.

Phase 4 gave the list a second way to change: a foreground FCM nudge, arriving while the reader is
already on the screen. A sighted user sees the row change. **A TalkBack user is told nothing** —
nothing re-reads a changed widget — so someone who heard *"Mum. No check-in from Mum yesterday."*
thirty seconds ago is now looking at *"Everything OK"*, with no announcement, no reason to swipe
back, and no notification ever coming because the day is already recorded as seen.

It bites hardest on the **correction**, which is the one message whose entire purpose is withdrawing
a false claim about a person.

**The approved string for the row that gets better** — the first of the two that ship; the other is
*OK → warning* below:

> *"Mum checked in. Everything OK."*

It reuses `everythingOk` verbatim rather than inventing a second way to say the same thing.

**It is the one message in this set that names no day, and that is a decision rather than an
omission.** ADR-0009's rule is that a warning names its day unless the day is yesterday, because
*"yesterday"* is false for a watcher several zones from the watched person. *"Mum checked in."* is
past simple with no day at all, and will be heard as *just now* — what the device actually knows is
that a check-in exists for the last completed **watched-local** day.

It ships without the date because an utterance that interrupts should be short, and because the row
directly beneath it carries the exact date (*"Your phone last saw a check-in on Saturday 15
August."*) for the next swipe to read. The error is small and in the reassuring direction. **If it
is ever revisited**, the dated forms are *"Mum checked in yesterday. Everything OK."* and *"Mum
checked in on Saturday 15 August. Everything OK."*, and they must use the same day helper as the
warning they retract so the two cannot describe one day differently.

**Several rows settling in one pass is ONE utterance**, the approved sentences joined in list order:
*"Mum checked in. Everything OK. Granddad checked in. Everything OK."* It sent one announcement per
person first, which is the shape most likely to lose one — the platform does not reliably queue
them, and the one dropped is the first, which is the oldest row and the person the reader has been
waiting longest to hear about. Repetitive, and every word of it is already approved; a shorter
summary would be a new string needing its own approval.

**A mixed pass leads with the warning**, not with the good news:

> *"No check-in from Granddad yesterday. Mum checked in. Everything OK."*

Within one utterance the part at risk is the **tail** — an interrupt takes the end, not the
beginning — so the same rule that keeps the differentiator in the first words of a body keeps the
loud sentence at the front of an announcement. Appending both kinds in `people` order put the warning
last whenever an improving row happened to sort above a worsening one, and a blind watcher would hear
that one relative is fine and lose the sentence saying a different relative is not, with no
notification coming because `redundant` had already recorded the day as seen. List order still
decides the order **within** each kind.

**Two conditions, both required.** The person's rendered status must have **changed**, and the
refresh must **not** have been user-initiated. Announcing every refresh is noise; on a resume the
reader is arriving at the screen anyway and will read the row themselves.

**Built 2026-08-25**, and **verified on hardware the same day with TalkBack running**:
a foreground push flipped a row from a standing warning to *"Everything OK"* and TalkBack took
speech audio focus 1.7 s later, while a control push that changed no row produced no speech at all.
`WatcherState.userInitiated` carries the second condition — false only for a foreground push — and
`WatchedPersonState.checkedInSince` decides the first.

**The change is not "the row got better", and the difference is a claim about a person.** *"Mum
checked in"* has to be true. A row can reach *"Everything OK"* from a standing warning with nobody
having tapped: a *"your phone has been offline… Mum was marked away until Saturday"* stops being
renderable the moment a read succeeds, because the away covers the day and the decision is now
silent — and the last check-in this device saw has not moved. So the condition asks the **cache**,
not the row: the day the warning was about must now be confirmed. That is true for the correction,
which is the case this exists for, and false for every way a warning can simply lapse.

A row moving into or out of a **revoked** or a **lost access** state is excluded on both sides, and
from the *OK → warning* announcement below as well. Each renders something else entirely, so each is
a different sentence — and *any → access lost* is exactly that sentence, still unapproved. `rowKind`
is what keeps them apart rather than a guard in the widget: an access failure is `accessLost` and
never `warning`, so neither announcement can see it.

**Two more things are pinned by tests and belong in the approved set**, because both are cases where
saying nothing is the correct answer: a link with **no previous row** — newly paired, or previously
unreconcilable — is never announced, because there is no "before" for it to have changed from; and a
**day rollover** is never announced as a check-in, because a warning about `D` followed by a
check-in for `D + 1` is a true sentence spoken for the wrong reason.

#### OK → warning — approved 2026-08-25, and it is the warning body verbatim

The mirror image, and it loses more. A push reconciles with the list open, so the delivery is
`redundant`: nothing is posted and the day is **recorded as seen**. The row worsens silently, the
alarm later finds the day settled and says nothing, and a screen-reader user is never told at all.
`checkedIn` loses a *retraction*; this loses a **warning**, which §10 rates worse in kind.

**The mechanism question that blocked it is settled.** Announcements still reach TalkBack on Android
16 at `targetSdk 36` — measured 2026-08-25 on the API 36 AVD with an exactly-matched silent control,
written up in `testing/device-matrix.md`. Two things stay true and are recorded there: `targetSdk`
was never the trigger (the deprecation applies by OS version), and Flutter reports
`MediaQuery.supportsAnnounceOf` as **false on Android generally**, so `Semantics(liveRegion: true)`
remains the sanctioned replacement if dispatch ever stops. It is not a drop-in: this row's footer is
*"This phone last checked Tuesday 10:14."*, which moves on every reconcile, so a whole-row live
region would re-read the row on app open, FCM, alarm and boot. Scoping it to the status line is the
work that would need doing.

**The approved string is the warning body, word for word:**

> *"No check-in from Mum yesterday."*

Whatever the row is rendering — so *"No check-in received from Mum yesterday — your phone has been
offline since…"* and *"Can't check on Mum — …"* too. It is `NotificationCopy.warningBody`, the same
string the row shows and the same one the notification would have carried, which is why the row and
the announcement cannot drift: `_statusFor` computes it once and both read it.

**That last opener belongs to two different outcomes and only one of them is announced.** It is
`warnUnverifiableAway` — *this phone cannot check, and she was marked away until Saturday*. The
identical opener on `warnAccessLost` is **not** announced and is not this: an access failure renders
the `accessLost` row, never the `warning` one, so it cannot reach here. Working from the table alone,
that is the easy one to get backwards.

**The drafted wording was rejected.** *"Update. Mum. No check-in from Mum yesterday."* — *"Update."*
is a category label: it differentiates nothing, it is identical for both candidates, and it is the
part most likely to survive an interrupt while the claim gets clipped, against this file's own rule
that the differentiator belongs in the first words. It also says the name twice. Reuse names the
person in the first four words already, which is the same move `checkedIn` makes with `everythingOk`.

**The footer is not spoken with it.** *"This phone last checked Tuesday 10:14."* is a fact about this
device's own effort rather than a claim about her, and it is not what changed. `spoken` — which
includes it — stays right for the row **label**, where the reader is swiping through everything on
purpose.

**The same two conditions**, and the same-day guard `checkedIn` uses: both passes must be deciding
about the same day. **The narrower gap that remains, recorded rather than glossed:** a row that turns
bad at watched-local **midnight**, when the day being decided advances onto one nobody has tapped yet,
is *not* announced. Dropping the guard would announce a warning at 00:24 unasked, which is what
ADR-0010 exists to prevent; the reader having the list open makes that arguable rather than settled,
and it is a policy question rather than the copy one that was approved.

**Still deliberately not shipping**, and named here so nobody adds it casually — it needs the same
approval the two above got:

| Change | Candidate |
|---|---|
| any → access lost | *"Update. Can't check on Mum."* |

If it ever ships, the *"Update."* objection above applies to it too, and it should reuse the row's
second line as well: a message whose whole justification is actionability must not be truncated to
the half that says nothing.

**This changes nothing about what is posted or consumed.** `redundant` still posts no notification
and still records the day. An announcement is the screen speaking to a reader who is already on it,
which is the premise the `redundant` argument always rested on — now true for someone who cannot see
the row change.

**The title echoes onboarding screen 2**, *"Who are you looking after?"* — the same trick the Tap
screen's audience line uses, so the words that asked the question at setup answer it here.

**The empty line mirrors `TapCopy.nobodyYet` deliberately**, including naming a next human: the
pairing flow assumes a family member sets up both phones, so *"ask a family member"* is the real
next step rather than a polite dead end. It is styled as ordinary text, never as a warning — an
empty list is not an alarm.

**No *"yet"*, on either screen.** Two reviewers struck it from the Tap screen's twin at the Phase 2
gate and it reappeared here. *"Yet"* asserts **not started**, which is false in the other state this
same line covers — the last link was revoked, so something was set up and is not any more. One line
has to be true in both, which is the whole reason it is deliberately one line.

**Pull-to-refresh works on the empty list too.** It is the one screen where a reader most wants to
try again — *"I was just added, is it working yet?"* — and it was the one screen that could not,
because the empty state returned before the refresh wrapper existed.

**The warnings-off banner shows above the empty state as well as above the list.** The same early
return hid it there. It is vacuous with no links — there is nobody to warn about — but the empty
state is exactly when someone is being added, and finding out then that this phone cannot warn is
worth more than finding out after the first miss.

#### The row for a link this pass could not check at all

A link the reconcile threw on is **shown**, not omitted. Omitting it is invisible, and with one link
— which is all of Phase 3 — a short list *is* an empty list, so the screen said *"You're not looking
after anyone."* about someone the reader is very much still looking after.

It is shaped like the lost-access row, because it is the same kind of thing: **a fault about us**,
naming the person, with an honest next step. Three rules govern its wording.

- **Never a claim about her.** The app does not know whether she checked in, only that it could not
  find out. *"No check-in from Mum"* is unsupportable here.
- **Never *"you will not be warned"***, which the lost-access row does say. The alarm may still be
  armed and the next fire may succeed, so that would overstate what is known.
- **Never *"something went wrong"***, which the Floors table bans by name and this row shipped
  verbatim until the Phase 3 gate. *"Could not finish checking"* says what happened; *"just now"*
  stops it reading as permanent.

It carries **no *"this phone last checked"* line** and no status, for the reason it exists: the cache
read is among the things that may have thrown, so there is no value here the row can vouch for.

It also carries **no promise about the future.** The remedy line said *"It will try again."* — and on
a link whose alarm window was never armed, nothing does until somebody opens the app. It offers the
**"Try again"** control instead, which is a thing the reader can do rather than a claim about what
the phone will do. That control also satisfies the floor forbidding a drag as the only route to an
action: pull-to-refresh was the only way to retry, and it is the gesture a screen-reader user is
least able to perform, on a row whose entire content is a fault.

### Times, dates and the device's clock

| Instant | Renders as |
|---|---|
| Today | *"22:10"* — the time alone |
| Within the last week | *"Tuesday 10:14"* |
| Older than a week | *"Saturday 15 August, 10:14"* |
| On a 12-hour device | *"9:14 am"*, *"10:10 pm"*, *"12:05 am"*, *"12:05 pm"* |

**The weekday earns its place only once there is another day it could be.** Naming it for something
four hours ago pushes the reader to work out that *"Tuesday 10:14"* is in fact this morning.

**No leading zero on a 12-hour hour** — *"9:14 am"*, never *"09:14 am"* — while the 24-hour form
does pad: *"09:14"*. The two differ deliberately, and every example here had a two-digit hour until
the Phase 3 gate, so the difference was recorded nowhere and asserted nowhere.

**12h/24h follows the device**, per the accessibility floor, rather than being hard-coded to the
owner's locale. It applies app-wide — every notification, this list, and the Tap screen's *"You
already tapped today, at 9:14 am."* — and not only to this screen.

`ClockService` reads it from `platformDispatcher.alwaysUse24HourFormat`, which needs no
`BuildContext`, and caches it to `LocalStore` on launch and on every resume — the same arrangement
[ADR-0002](../architecture/decisions/0002-clock-split.md) uses for the timezone, and for the same
reason: the alarm isolate that posts most of these notifications has no widget tree to ask.

**It follows the device as of the last cold start or configuration change, not the last resume.**
Measured on the POCO F3 on 2026-08-19: Flutter refreshes `alwaysUse24HourFormat` only when Android
delivers a configuration change, so switching the device between 12- and 24-hour while the app is
backgrounded does *not* take effect on the next resume — two cycles wrote the stale value in both
directions — while a cold start, or a resume after any config change (dark mode, rotation, locale),
picks it up. The consequence is cosmetic and a live fix needs a platform channel to
`DateFormat.is24HourFormat`, which belongs with Phase 7.

**This list renders from that one cached value, not from `MediaQuery`.** It has a `BuildContext` and
could read the setting live — and did, which gave one fact two sources: the row and the notification
produced by the *same reconcile* could disagree about the same instant, which is precisely the
comparison a reader makes. The Tap screen still reads `MediaQuery` live, because nothing there is
paired with a notification rendering the same instant; that asymmetry is recorded in its own code.

### Colour, and what is never coloured

**The "this phone last checked" line is never error-coloured, on any row.** Painting the whole
unhealthy row `error` swept it up with the warning and collapsed the very distinction it exists to
make: the warning is a claim about **her**, this is a fact about **this device's own effort**. In red
beneath a warning it reads as part of the alarm.

**The contrast floor is asserted against the shipped palette**, in both modes, by
`test/presentation/contrast_test.dart`. The default Material scheme from this app's seed missed AAA
in light mode on all three surfaces `guidelines.md` names — the warning (6.16), a warning on a
highlighted row (5.01), and the tap target (6.46). The themes now raise contrast until every pair
clears it.

### The row a tapped notification opens

Tinted, **scrolled into view**, and **announced**. Colour may never be the only signal, and the row
the notification is about can be below the fold — which is exactly when the highlight is worth
having.

The announcement is *"Showing Mum."* rather than a move of the screen reader's cursor, because
Flutter cannot place the cursor on an arbitrary widget. It answers the question the tap actually
asks — did this land on the person the notification was about — and the row is then on screen for
the next swipe to read in full.

**A standing warning reuses the notification's sentence rather than a shorter list variant.** Two
string sets would be two things to keep true, reviewed separately, and the failure is the row and
the notification disagreeing about the same day — a contradiction the reader cannot resolve. The
cost is naming the person in a row that already names them, which is accepted.

**The accepted cost includes some visible redundancy, recorded here so it is a decision rather than
an artefact.** On an offline warning the row reads *"…your phone has been offline since Tuesday
10:14."* directly above *"This phone last checked Tuesday 10:14."* — one instant, twice, with the
device called *your phone* on one line and *this phone* on the next. On a never-reconciled row the
two lines are verbatim identical. Both are the price of reusing bodies as row lines, and the trade
is still right: two string sets drifting apart costs more than a repeated clause. Revisit when
Phase 7 designs the multi-person layout, where the last-checked line probably belongs once per
screen rather than once per row.

**The last-checked line is on every row, healthy or not, and that is the point.** A watcher whose app
was force-stopped goes deaf with every row still reading *"Everything OK"* — which is true of the
last thing this phone managed to read, and says nothing about whether it has read anything since.
This is the **surface** half of "accept, prevent and surface": §13's full health panel is Phase 7,
and this one line is what makes the accepted force-stop risk visible in the meantime rather than a
year from now. It says *"This phone last checked"*, never *"last updated"* — a fact about this
device's own effort, not about her and not about the data.

**"Your phone last saw"**, never *"last checked in"* — the same rule ADR-0004 applies to the
notification. The date is the newest check-in **this device managed to read**; during an access
failure she may be tapping daily, and the shorter phrasing reads as a claim about her behaviour.

**The error line is this screen's own, not the Tap screen's.** It borrowed `TapCopy.couldNotStart`,
which ends *"Ask a family member for help."* — written for an 80-year-old, and approved above for
the Tap screen only. Here the reader **is** the family member, the person who set the app up for
everyone else, so it was a dead end pointing at themselves. Worst in the state this screen exists
for: the *lost access* notification promises *"Open the app to see what to do."*, the cold-start tap
lands here, and a throw from a malformed cache row turned that promise into an instruction to ask
oneself.

### The watcher list shows today only

Settles `guidelines.md`'s open question. A row renders the warning for **today's `D`** or nothing —
never the most recent day the app ever warned about.

The first version fell back to the newest entry in `warningsShownFor`, and a day leaves that map
only by a correction *for that exact day* or by revocation. So a genuinely missed 1 August produced
*"No check-in from Mum yesterday."* on the 18th, permanently, over a green last-confirmed day — a
false claim about a specific day, to a family, with no way out. It compounded: the outcome came from
the old day while the interpolated values came from the current reconcile, so a stored *offline*
message rendered *"your phone has not been able to check even once"* on a phone that had reconciled
seconds earlier.

Every string in the warning set says *yesterday*. Only today's `D` is yesterday.

### When this phone cannot warn at all

`POST_NOTIFICATIONS` revoked, or *Missed check-ins* switched off. §13 rates this **High** because
Android takes the permission from apps nobody opens — which describes a watcher by design.

| | |
|---|---|
| Banner | *"This phone will not warn you about anyone."* |
| Action | **"Turn warnings on"** |

**The rows still show the warning.** What is true about her does not change because a notification
could not be posted, so the row renders the same four-way-distinguished sentence it always would.
The row derives that from the reconcile's **decision**, not from the record of what was delivered —
reading the delivery ledger made a muted phone show *"Everything OK"* about a day the reconcile had
decided to warn on.

**The banner exists because the row alone cannot say the rest.** A muted watcher reads the warning,
deals with it, closes the app, and goes on believing they will be told next time. They will not be.
This is the watcher-side twin of the Tap screen's `_NotificationsOffBanner`, and it appears while
they are looking — the one moment the app can still reach them, since every other route is the one
that is switched off.

*"anyone"*, not a name: the channel is off for every watched person, and naming one would imply the
others still work. It is **not** shown for `redundant`, which means the reader is looking at this
screen and is the good case.

### The lost-access row

§13's backend-access item, brought forward because the notification routes here. The full panel is
still Phase 7.

| | |
|---|---|
| Label | *"Access to Mum's check-ins"* |
| Consequence, all causes | *"You will not be warned if Mum misses a day."* |
| `unauthenticated` | *"Sign in again."* |
| `appCheckRejected` | *"Update I Am Ok in the Play Store."* |
| `permissionDenied` / `unknown` | *"Nothing can be fixed on this phone. If it is still red tomorrow, ask whoever set up the app."* |

It **outranks a standing warning in the row**, for the same reason ADR-0004 puts a refusal above the
away branch: it is a fault in this app rather than a claim about her, and it is the thing the reader
tapped through to understand.

### The revoked row — added at the Phase 3 review

A link whose status is not `accepted` fell through every branch above and rendered **"Everything
OK"**. That is the worst sentence this screen can produce for the state: nothing is being checked,
no warning will ever fire, and the row said the opposite in two words.

| | |
|---|---|
| Label | *"You are no longer looking after Mum."* |
| Consequence | *"You will not be warned if Mum misses a day."* — the same sentence as the lost-access row |

**No "this phone last checked" line here, alone among the row states.** That line exists to
distinguish *working* from *stopped* for a force-stopped watcher whose rows all still read
"Everything OK". Nothing is working on a revoked link by design, and the first sentence has already
said so — what the line adds is the suggestion that this phone still checks on her periodically and
last managed it on Tuesday. A revoked link refuses every read forever, so `lastReconcileAt` never
advances and it would say the same Tuesday in week twelve.

**It outranks everything, including the lost-access row.** §10 step 1 makes a non-accepted link the
first branch of the whole decision, and the ordering is the same argument: once the link has ended
there is nothing left to say about access to check-ins the app is no longer entitled to read. A
revoked link produces refused reads forever, so a row led by *"Access to Mum's check-ins"* would
send the reader off to sign in again and fix a permission problem that does not exist.

**The consequence sentence is reused verbatim, on purpose.** It is the same fact — this phone will
not warn you about this person — and two wordings for one fact is two things to keep true.

**Not styled as an error.** It is a settled state rather than bad news about her, and *"quiet
confirm, loud miss"* reserves alarm styling for a miss. The words carry it, as they must anyway:
colour is never the only signal.

**It does not say who revoked it, or when.** The link carries neither, and this screen does not
invent facts about people — the same rule that took the time clause out of the correction. Naming
the actor is right and is owed a decision when pairing lands in Phase 5, where the information will
actually exist.

## Health panel

Always reachable, green/red per item, re-checked on every app resume — not an onboarding gate,
because Android takes permissions back from apps nobody opens, which is precisely the watcher's
situation.

Notifications · exact alarms · battery optimisation exemption · auto-revoke exemption · last sync ·
clock skew · **backend access**. Each red item explains the consequence in plain language and, where
one exists, deep-links to the right settings screen. See
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §13.

**Backend access** ([ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)) is the
first item with **no Android settings screen to link to**, so the remediation is the copy itself:

| | |
|---|---|
| Label | *Access to Mum's check-ins* |
| Consequence (all causes) | *"You will not be warned if Mum misses a day."* |
| `unauthenticated` | *"Sign in again."* |
| `appCheckRejected` | *"Update I Am Ok in the Play Store."* |
| `permissionDenied` / `unknown` | *"Nothing can be fixed on this phone. If it is still red tomorrow, ask whoever set up the app."* |

The last row is a dead end otherwise; naming a next human is the minimum honest exit. The cause
comes from `LocalStore.accessLostCause`, written by whichever isolate hit the refusal — usually the
alarm one, which is why it is on disk and not merely in memory.

---

## Notification copy

The full set. Everything the app says out loud is here.

| When | Who sees it | Text |
|---|---|---|
| Reminder, no tap yet | Watched | Escalating — the three strings below |
| Check-in arrives | Watcher | **Nothing.** Status updates silently — quiet confirm, loud miss. |
| No check-in yesterday, device online | Watcher | *"No check-in from Mum yesterday."* |
| No check-in yesterday, server unreachable | Watcher | *"No check-in received from Mum yesterday — your phone has been offline since 22:10."* |
| …and the device has **never** reconciled | Watcher | *"No check-in received from Mum yesterday — your phone has not been able to check even once."* |
| Away cached, but unverified for over 2 days | Watcher | *"Can't check on Mum — your phone has been offline since Tuesday 10:14. Mum was marked away until Saturday 22 August."* |
| …and the device has **never** reconciled | Watcher | *"Can't check on Mum — your phone has not been able to check even once. Mum was marked away until Saturday 22 August."* |
| Read **refused** — the app has lost access ([ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)) | Watcher | *"Can't check on Mum — I Am Ok has lost access to the check-ins. Open the app to see what to do. Your phone last saw a check-in on Saturday 15 August."* |
| …and no check-in has ever been seen | Watcher | *"Can't check on Mum — I Am Ok has lost access to the check-ins. Open the app to see what to do. Your phone has not seen a check-in yet."* |
| …and an away period is cached for the day | Watcher | *"Can't check on Mum — I Am Ok has lost access to the check-ins. Open the app to see what to do. Mum was marked away until Saturday 22 August."* |
| …and the day warned about is **not** yesterday ([ADR-0009](../architecture/decisions/0009-decide-about-every-completed-day.md)) | Watcher | *"No check-in from Mum on Friday 14 August."* |
| …the offline variant of the same | Watcher | *"No check-in received from Mum on Friday 14 August — your phone has been offline since 22:10."* |
| …the unverifiable-away variant of the same | Watcher | *"Can't check on Mum for Friday 14 August — your phone has been offline since Tuesday 10:14. Mum was marked away until Saturday 22 August."* |
| Late check-in after a warning was shown | Watcher | *"Correction: Mum did check in yesterday, at 23:40."* Replaces the warning by id. |
| …and the read carries no tap time | Watcher | *"Correction: Mum did check in yesterday."* Same id, same replacement. |
| …and the day corrected is **not** yesterday | Watcher | *"Correction: Mum did check in on Saturday 15 August."* No time clause — see below. |
| Away set by a watcher | All other watchers, and the watched person | *"Ana marked Mum away until Sat 22 Aug."* |
| Away set by the watched person | All watchers | *"Mum is away until Sat 22 Aug."* |
| Away cancelled | Everyone except whoever cancelled | *"Mum's away period was cancelled — daily check-ins resume today."* |
| Away ending | All watchers | *"Mum's away period ends tomorrow."* Scheduled locally; needs no server. |

Away transitions happen a handful of times a year, so these can be ordinary notifications rather
than silent ones — alarm fatigue is not a risk at that frequency.

> **A warning names its day unless the day is yesterday**
> ([ADR-0009](../architecture/decisions/0009-decide-about-every-completed-day.md)). `reconcile()`
> now decides about **every** completed day it has not settled, not only the most recent — because
> asking about one day only meant a fire deferred past midnight, a phone in a drawer for three days,
> a force-stop nobody undid, or a flat battery over a weekend dropped every day in between, silently.
> So a warning can be about a day that is not yesterday, and the word *yesterday* would then be a
> false claim to a family in the message whose whole purpose is not to make one.
>
> The rule is the correction's, below, applied to the warning: *yesterday* for the day before the
> **reader's** today, the written-out date for any other. One shared helper renders both, so a
> warning and the correction that later replaces it at the same id cannot describe the same day
> differently.
>
> Two consequences worth stating rather than discovering. **The unverifiable-away line takes its day
> differently** — *"Can't check on Mum for Friday 14 August"* — because that message opens with a
> claim about **this phone** and the opening has to survive a one-line truncation; the date goes
> after the name rather than displacing it. And this **removes a falsehood that predates ADR-0009**:
> a watcher several zones from the watched person could already be told *"yesterday"* about a
> watched-local day that was not their yesterday. That message now dates itself.

> **A correction names the day unless the day is yesterday.** The reconcile emits one for *every*
> standing warning a read confirms, not only yesterday's, and a missed day stays in
> `warningsShownFor` indefinitely. A phone offline over a weekend syncs both taps on Monday: the
> watcher was warned about Saturday and about Sunday, and Monday's read confirms both. Two
> notifications, two ids — and with *"yesterday"* hard-coded, identical text, one of them wrong
> about which day it covered. A reader at 3am got the same sentence twice and could not tell what
> was now covered.

> **Instants older than a week are dated, not left as a weekday.** *"Tuesday 10:14"* for something
> nine days ago reads as the most recent Tuesday. Adding the weekday moved the ambiguity from one
> day to seven; beyond that the full date is used — *"Saturday 15 August, 10:14"*. This is not
> cosmetic on a revoked or lost-access row, where every read is refused forever, `lastReconcileAt`
> never advances, and the same weekday would otherwise stand into week twelve while reading as this
> week. It understates staleness, which is the one direction this app must not.

> **The correction's time clause is hers, or it is absent.** *"at 23:40"* is `deviceTappedAt` — the
> moment she tapped, on her phone — and nothing else may be rendered there. Phase 3's read carries
> no per-check-in timestamp, so the only instant available to the watcher's device is when it
> managed the read: on a phone that was asleep until morning that is hours out and occasionally the
> wrong day. A message that exists to withdraw a false claim about a person may not make a new one
> to do it, so the second variant is what ships. The retraction is complete without the time; the
> time was never what made it true.
>
> **This said "until Phase 4 carries `deviceTappedAt` through", and Phase 4 did not.**
> `FirestoreCheckInReader` returns a bare `Set<DayKey>` and discards the instant, so the no-time
> variant is what ships today and for the foreseeable future. Corrected at the Phase 4 gate, because
> an approved-copy table describing a build that does not exist is worse than one that is merely
> incomplete — on the single message whose purpose is to withdraw a false claim about a person.
>
> **And there is now a trap sitting next to it.** `onCheckInCreated` *does* put `deviceTappedAt` on
> the wire, and `pushBackgroundHandler` deliberately never reads the message. Someone will notice
> the field is right there and reach for it precisely because this table says the time is owed. It
> is **not an acceptable source**: §3 makes a push a nudge carrying no authority, so taking the
> instant from the payload would let a forged message put a fabricated time into a sentence about
> whether a person is alive. If the time is ever wanted, it comes through the READ.

> **A correction is spoken only when the warning channel can carry it.** Three things stop it: the
> reader is on the list (`redundant`), the *Missed check-ins* channel is muted, or the reader's
> `warningLocalTime` has not arrived yet (ADR-0010). In all three the standing warning is
> **cancelled silently** instead.
>
> **Stopped is not dropped, for the last two.** `redundant` consumes the retraction — the reader is
> watching the row correct itself. The two `unavailable` cases leave the day **owed**, and the first
> pass that can post says the already-approved sentence then. Nothing new is written for it:
> `correctionBody` already names a day that is not yesterday.
>
> **And it expires. DECIDED 2026-08-25: a retraction may not outlive the window in which a warning
> would still be spoken about that day at all.** Same seven-day floor and same constant as ADR-0009's
> catch-up burst cap, for the same reason its docstring already gives — a device that has been unable
> to speak for a month must not come back and post about a month. An unbounded owed set reaches that
> fatigue from the other end: one notification, but months stale, retracting a warning the reader saw
> a season ago, on the channel §1 keeps un-swipeable.
>
> **Dropping it is safe because the load-bearing half already happened.** The day leaves
> `warningsShownFor` and `lastConfirmedDay` advances **ungated**, so the false claim came out of the
> tray and the row went honest the moment the correction was computed. Only the sentence expires, and
> nothing false is ever left standing by letting it. **A day still standing in the tray is never
> filtered** — its `Correction` is still emitted, because that is what cancels it.
>
> **Also open, and smaller:** a day drained out of `correctionsOwedFor` under `redundant` is consumed
> with nothing said on any channel, because the row was *already* correct before that reconcile and so
> nothing changed under the reader — `checkedInSince` cannot fire either. The row does show the truth,
> so nothing false is said; but the `redundant` argument here rests on *the row shows the settled
> truth* rather than on *the reader watched it change*, which is a real difference for someone who
> cannot see the row. Recorded on `shouldPostCorrections` too.
>
> **Only the first of the three means the tray was empty.** This blockquote used to say a correction
> is spoken *"only when the warning it retracts was actually posted"*, and that the `redundant` case
> means *"nothing went to the tray"* — both wrong in the common case, and the reconciler had already
> retracted them in its own docstring. The standing warning was typically posted by **yesterday's**
> 10:00 alarm; `redundant` describes only the reconcile that retracts it. So cancelling is the
> load-bearing half, not a tidy-up.
>
> The 3am argument still holds for `redundant`: a bare *"Correction: Mum did check in yesterday"*
> arriving alone reads as a warning the reader somehow slept through. It does **not** hold for the
> ADR-0010 case, where the reader did see the warning — see *A warning is not posted before the
> link's warning time* below for what that costs them.

### The three reminders — approved Phase 2

All three carry the title **"I Am Ok"**; the body is the line below. The title is the app name
rather than the instruction because the collapsed shade shows the *body*, and repeating the name
there would spend the one line the reader gets on something they already know.

| Slot | Body |
|---|---|
| 12:00 | *"Remember to tap I'm OK today."* |
| 18:00 | *"You haven't tapped I'm OK today."* |
| 21:00, somebody is set up | *"Please tap I'm OK before the day ends, so your family knows you're well."* |
| 21:00, nobody is set up | *"Please tap I'm OK before the day ends."* |

**Escalating, not repeating.** Three identical notifications read as one message the phone failed
to deliver twice; these read as the day going on. The tone stays level — no exclamation marks, no
emoji — because at midday she has done nothing wrong.

Only the last one names the consequence, and only once. It is the final nudge before the day closes
and the watcher's alarm asks about it tomorrow, and a person told *why* at 21:00 has a reason to act
that *"remember to tap"* does not give them. Saying it at 12:00 as well would make every reminder a
small warning, which is the fatigue this design spends its whole notification budget avoiding.

*"tap I'm OK"* is the same phrase as the tap target's own label, so the words mean one thing on the
screen and in the shade.

**The 21:00 body drops its consequence clause when nobody is set up — settled 2026-08-26**, closing
the *"Owed before Phase 5"* item this section used to carry further down the page.

That item's proposed resolution was *"an explicit acceptance once onboarding guarantees pairing
before reminders arm"*, and **onboarding does not guarantee that**: it offers *"Skip for now"* on the
screen that would produce a link, and `HomeRoute.decide` routes a both-skipped user to the Tap screen
by design. So Phase 5 made the combination easy to reach rather than theoretical — at 21:00 the
notification could promise a family while the screen behind it read *"No one is set up to know you're
OK."*

**Reminders still arm for a phone with nobody set up, and that is unchanged.** They exist for her own
routine, not for the family's benefit; coupling them to an audience would mean losing every watcher
silently stops her being nudged to tap. What changes is only the **claim**, which is the same rule the
four warning messages follow: never say more than the device knows.

It is a **subtraction** from an approved string rather than a new sentence — the same move
`TapCopy.nobodyYet` made in this phase — so the instruction a person acts on is identical in both. The
12:00 and 18:00 bodies name no consequence and do not vary.

The value is `WatchedAudience`, the same one the Tap screen's own line renders from, read off the
reconcile that produced the reminders, so the notification and the screen cannot disagree. It reaches
the scheduler as a flag rather than riding on `ScheduledReminder`: audience is not part of a
reminder's identity, and putting it in that type's equality would put it in a diff taken against a
`LocalStore` snapshot that has no audience column.

### Reminders and warnings are separate Android channels

A channel is the unit Android gives the user for switching us off, so this is a correctness
decision rather than a tidiness one. Three exist: **Daily reminders**, **Missed check-ins**, and
**App problems**.

Splitting *App problems* from *Missed check-ins* is the structural half of
[ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)'s argument. That ADR
already establishes that notifying about lost access daily would land "in the same channel as the
real *No check-in from Mum yesterday*", and that **training a family to swipe that channel cannot be
undone**; the decaying cadence fixed the frequency, and separate channels fix the collision. A
watcher who mutes app faults still gets told when their relative misses a day.

The away-cached row is [ADR-0001](../architecture/decisions/0001-away-cache-precedence.md). Offline,
the device cannot tell "the away was cancelled and I did not hear" from "the away is still on and I
have not checked" — so it says both of the things it actually knows and asserts neither. It is a
distinct string on purpose: reusing the plain offline warning would claim a missed check-in the
device has no basis for.

The refused rows are [ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md). The
server was **reached** and said no, so the phone is online and working: *"your phone has been
offline"* would be a false statement about the device, and *"no check-in from Mum"* a false one
about her. Note *"your phone last saw a check-in on…"* rather than *"last confirmed…"* — the date
is the newest check-in **this device managed to read**, and she may have tapped every day since;
the shorter phrasing reads as a claim about her behaviour.

> **The two openings are a convention, not a coincidence.** *"No check-in…"* is a claim about the
> watched person. *"Can't check on Mum —…"* is a claim about **us** — our phone, our access. The
> opening tells the reader which kind of message this is before they read the detail. Do not mix
> them, and keep the differentiator in the first words of the body, because the collapsed
> notification shade shows one line.

> **Every interpolated value here is nullable.** A device that has never had a successful read has
> no "offline since" and no "last saw", which is why each of those rows has a never-reconciled
> variant. Rendering "offline since null" to a worried family is the failure this note exists to
> prevent.

**The access-lost reminder repeats on a decaying cadence** — day 0, day 1, day 3, then every seventh
day for as long as it lasts ([ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)).
Notifying once would let a single swipe buy permanent silence; notifying daily would train the
family to swipe the channel that carries the real warning. There is **no "access restored"**
message — quiet confirm, loud miss.

**Settled in Phase 2:** ~~suppressing a reminder that lands while the watcher already has the app
open~~ — the domain is now told whether a notification can actually be **delivered**, as
`NotificationDelivery.available` / `redundant` / `unavailable`. The foreground case is `redundant`:
no notification is posted, but the day *is* consumed, because the watcher is looking at the screen
that already shows it. See the Phase 1 gate's decision 1 in
[phase-2-brief.md](../phases/phase-2-brief.md), and note the same input closes a sharper hole — a
phone with `POST_NOTIFICATIONS` revoked no longer burns silently through the access-lost cadence.

### Settled at the Phase 3 gate — 2026-08-17

**The `contentTitle` / `contentText` split for all four warnings: title is `"I Am Ok"`, and the whole
approved line is the body.** Identical to the reminders, and it is what the convention two paragraphs
below already requires — *"keep the differentiator in the first words of the body, because the
collapsed shade shows one line"*. The first words survive truncation, so *"No check-in received from
Mum yesterday — your…"* still tells the reader which kind of claim this is. No warning string is
split, so all four ship verbatim as written above.

Rejected: putting the claim in the title (*"No check-in from Mum"* / *"Can't check on Mum"*) with the
detail in the body. It scans better for a watcher watching several people and it can never truncate
the claim — but it turns four approved strings into eight, and it removes the app's name from the one
place a worried reader at 3am can see which app is speaking. Revisit if Phase 7's multi-person layout
makes the per-person title worth the cost.

**The copy does not assume "she".** Only two clauses across the set carried a pronoun, both now
replaced using `watchedName`, which is already denormalised onto the link:

| Was | Is |
|---|---|
| *"**She** was marked away until Saturday 22 August."* | *"**Mum** was marked away until Saturday 22 August."* |
| *"…has lost access to **her** check-ins."* | *"…has lost access to **the** check-ins."* |

The second is not a substitution: *"Can't check on Mum — I Am Ok has lost access to Mum's check-ins"*
says the name twice in one sentence. The opener already establishes whose check-ins are meant, so the
possessive was carrying no information and dropping it costs nothing.

No pronoun field was added to the data model. It would need a question at pairing that one family
member answers about another, a §8 rules change, and it would make the copy depend on data that can
be absent or wrong — for two clauses that read correctly without it. Recorded so it is not
re-proposed; the cost of getting this wrong rises sharply after translation, which is why it was
settled before Phase 3 wrote a single warning.

**The refused notification opens the watcher surface Phase 3 builds**, which carries a per-link
access-lost row rendering the remediation for the cause in `LocalStore.accessLostCause` — the three
lines already approved in *Health panel* above. §13's full panel stays in Phase 7.

That keeps *"Open the app to see what to do"* true. [ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)
makes actionability the whole reason this fourth message exists rather than being folded into the
offline one, so a tap that lands somewhere with no remediation would hollow it out — and a promise
the device does not keep is the failure class this app is least able to afford.

Rejected: opening the app with no routing (cheapest, and it makes the sentence false); pulling the
health panel forward from Phase 7 (most faithful, and it is a screen nobody has designed); and
cutting the sentence until Phase 7 (honest, but it removes the action and leaves a message the reader
can do nothing about, which is precisely what ADR-0004 rejected).

**Two consequences for the implementation.** The notification carries a payload identifying the link,
and the tap must route on a **cold start** — `getNotificationAppLaunchDetails()`, not only the live
callback. A watcher tapping this is by definition someone whose app has been closed, so the cold path
is the normal one here rather than the edge case. It is on the Phase 3 device list.

**Settled 2026-08-27, in *The away line names who set it* above.** `TapCopy.away` named nobody
while this file requires every away surface to name who set it. The owner's decision: name who set
it **when it wasn't you** — `TapCopy.awayBy` for a watcher's action, the already-approved
`TapCopy.away` unchanged for her own and for a document that names nobody.

**Settled 2026-08-26, in *The three reminders* above:** the 21:00 reminder said *"so your family
knows you're well"* while the screen might simultaneously say nobody is set up. It now has an
empty-audience variant that drops the clause. The acceptance this item offered as the alternative
would have rested on onboarding guaranteeing a pairing before reminders arm — and it does not.

### A warning is not posted before the link's warning time — settled 2026-08-25

Every string above says *what* is said. This says **when**, and it was missing.

`Link.warningLocalTime` — 10:00, and **nobody chooses it**: it is set at link creation and in the
debug harness, and no screen lets a watcher set or even see it. [ADR-0008][adr8] makes that absence
deliberate — *"nothing in `lib/copy/` may state or imply a delivery time"* — so this section
describes a value the reader has, not one they picked. It bounded only when the *alarm asks*.

[adr8]: ../architecture/decisions/0008-the-warning-is-late-in-doze-and-the-app-says-so.md Nothing in the decision path read it, so any caller posted whatever was owed, and a
warning is owed from the moment the day completes. Measured on the POCO F3:

> *"No check-in from Ana yesterday."* — posted **00:24:53 CEST**, against a `warningLocalTime` of
> 10:00, because somebody else tapped and the resulting push woke the isolate.

**The rule: a warning is posted only once `now >= today's warningLocalTime` in the watcher's own
zone.** A push at 14:00 against a 10:00 warning still posts immediately — the acceleration is kept
for the rest of the day, including rescuing an alarm Doze made late. Only the hours before the
reader's chosen time are given up, which is the window nobody asked to be woken in.
[ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md) carries the
reasoning and the trap.

**The day is still owed.** A held run decides, arms its alarms, and records nothing — so the 10:00
alarm finds the warning still owed and says it. Late, never lost.

**The *lost access* notice is not held.** A refusal is a claim about **us**, is not tied to an hour,
and its decaying cadence is exactly what must not burn in silence.

**A correction due before the hour cancels rather than replaces**, and this is a consequence of the
rule rather than part of what was asked for. A correction rides the *Missed check-ins* channel at
the warning's own id, so holding the channel holds the retraction too: the false claim comes out of
the tray silently. Chosen deliberately — a correction is good news, and good news may not wake a
family at 00:24 — and the row still tells whoever opens the app the truth. The alternative, posting
*"Correction: Mum did check in yesterday."* at 00:24, is the same wake-up the rule exists to prevent.

**Amended 2026-08-25: the sentence is held, not given up.** This paragraph used to end *"and the
sentence withdrawing it is what is given up"*. The post-gate review found that it was not given up
so much as **destroyed** — the day left the standing-warnings ledger, and the next pass looks for
corrections among days that are still warned. So a family whose relative turned out to be fine got
an empty tray at 07:00 and no way to tell *resolved* from *I swiped it in the night*. The day is now
kept in `WatcherCache.correctionsOwedFor` and spoken at the reader's own hour — the same *late, never
lost* shape as the warning it retracts, and with no new copy.

**Nothing about the screen is gated by the hour.** The row still renders the standing warning, and
*"This phone will not warn you about anyone."* still means the **channel** is off, not that this
link's hour has yet to arrive.
