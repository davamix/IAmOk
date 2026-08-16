# Screen inventory

**Date:** 2026-08-16 · **Status:** Specification-in-progress. **The Tap screen and the debug harness
are built** (Phase 2); everything else is still specification.

What is recorded here is **only what has actually been decided** — mostly behaviour and copy,
carried over from [PLAN.md](../PLAN.md) and [ARCHITECTURE.md](../architecture/ARCHITECTURE.md).
Layout, visual design, and anything marked *undesigned* below are open. Do not treat an absence
here as a free choice: add the decision to this file when it is made.

| Screen | Phase | State |
|---|---|---|
| Tap (watched main) | 2 | **Built.** Behaviour, copy and layout decided |
| Debug harness | 2 | **Built.** Debug builds only |
| Onboarding 1 — "Who should know you're OK?" | 5 | Purpose and routing decided; copy partial |
| Onboarding 2 — "Who are you looking after?" | 5 | Purpose and routing decided; copy partial |
| Onboarding 3 — summary | 5 | Exists; content undesigned |
| Pairing — create invite / redeem code | 5 | Mechanism decided; screens undesigned |
| Away picker | 6 | Copy decided; layout undesigned |
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
assume that rather than assuming two people configuring independently. Not yet designed.

---

## Tap screen — watched main

The only screen the watched person needs.

| State | Shows |
|---|---|
| Not yet tapped today | The tap target, enabled, reading **"I'm OK"**. Large, high contrast, minimal chrome. |
| Tapped today | Target **disabled for the rest of the local day**. The target itself changes to a tick and **"Tapped"**, and the line beneath reads *"You already tapped today, at 09:14."* Re-enables at local midnight. |
| Away | *"You're away until Saturday 22. Your family isn't expecting a check-in."* Tapping is still **allowed** — harmless, reassuring, and it writes a normal check-in watchers see as usual. |

The Away control is present but visibly secondary, and not adjacent to the tap target. While an
away period is active it reads *"I'm not away"*. It is inert until Phase 6, and present now so the
layout it has to live in is settled while the screen is still simple.

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

These are user-visible text and are approved here like any other string. **Open before Phase 5:**
all three are created on every phone, so a watched person browsing Android's settings sees two
channels describing things she does not do. Role is not known until onboarding runs.

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

A calendar picker where the selected day is labelled unambiguously:

> **Last day away: Saturday 22** · Back on Sunday 23

"Until Saturday" alone is ambiguous about whether Saturday still needs a tap. The start date is
**always today** — the calendar selects the last away day only, and there is no future-dating in
v1. Maximum 31 days — the last selectable day is 30 days after today.

Every surface that displays an away period names who set it: *"Ana marked Mum away until Sat 22 Aug."*

## Watcher list — watcher main

One row per watched person. Per row: the person's name, current status, and the away action.

| Status | Row reads |
|---|---|
| Checked in today | Last check-in time |
| Unresolved warning | The warning, unresolved |
| Away | *"Away until Sat 22 Aug — set by Ana"* — in the app, never as a notification |
| Stale / offline | Last successful update, honestly dated |

**Cold open shows current state, not the most recent event ever.** An unresolved warning if one
stands; otherwise "Everything OK" with the last check-in time. A warning from three weeks ago
followed by three weeks of check-ins is history.

Multiple watched people is supported by the data model and **not yet designed** as a layout.

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
| Away cached, but unverified for over 2 days | Watcher | *"Can't check on Mum — your phone has been offline since Tuesday 10:14. She was marked away until Saturday 22 August."* |
| …and the device has **never** reconciled | Watcher | *"Can't check on Mum — your phone has not been able to check even once. She was marked away until Saturday 22 August."* |
| Read **refused** — the app has lost access ([ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md)) | Watcher | *"Can't check on Mum — I Am Ok has lost access to her check-ins. Open the app to see what to do. Your phone last saw a check-in on Saturday 15 August."* |
| …and no check-in has ever been seen | Watcher | *"Can't check on Mum — I Am Ok has lost access to her check-ins. Open the app to see what to do. Your phone has not seen a check-in yet."* |
| …and an away period is cached for the day | Watcher | *"Can't check on Mum — I Am Ok has lost access to her check-ins. Open the app to see what to do. She was marked away until Saturday 22 August."* |
| Late check-in after a warning was shown | Watcher | *"Correction: Mum did check in yesterday, at 23:40."* Replaces the warning by id. |
| Away set by a watcher | All other watchers, and the watched person | *"Ana marked Mum away until Sat 22 Aug."* |
| Away set by the watched person | All watchers | *"Mum is away until Sat 22 Aug."* |
| Away cancelled | Everyone except whoever cancelled | *"Mum's away period was cancelled — daily check-ins resume today."* |
| Away ending | All watchers | *"Mum's away period ends tomorrow."* Scheduled locally; needs no server. |

Away transitions happen a handful of times a year, so these can be ordinary notifications rather
than silent ones — alarm fatigue is not a risk at that frequency.

### The three reminders — approved Phase 2

All three carry the title **"I Am Ok"**; the body is the line below. The title is the app name
rather than the instruction because the collapsed shade shows the *body*, and repeating the name
there would spend the one line the reader gets on something they already know.

| Slot | Body |
|---|---|
| 12:00 | *"Remember to tap I'm OK today."* |
| 18:00 | *"You haven't tapped I'm OK today."* |
| 21:00 | *"Please tap I'm OK before the day ends, so your family knows you're well."* |

**Escalating, not repeating.** Three identical notifications read as one message the phone failed
to deliver twice; these read as the day going on. The tone stays level — no exclamation marks, no
emoji — because at midday she has done nothing wrong.

Only the last one names the consequence, and only once. It is the final nudge before the day closes
and the watcher's alarm asks about it tomorrow, and a person told *why* at 21:00 has a reason to act
that *"remember to tap"* does not give them. Saying it at 12:00 as well would make every reminder a
small warning, which is the fatigue this design spends its whole notification budget avoiding.

*"tap I'm OK"* is the same phrase as the tap target's own label, so the words mean one thing on the
screen and in the shade.

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

**Still undecided, and owed before Phase 3 ships any of this:** the `contentTitle` / `contentText`
split for all four warnings — the reminders' split is settled above and is the pattern to follow;
where the refused notification routes on tap; and whether the copy set assumes "she" — nothing in
the domain captures a pronoun, so a watched father currently gets the wrong one.

**Owed before Phase 6 ships the away picker:** `TapCopy.away` names nobody, while this file also
says *"every surface that displays an away period names who set it"*. Those two contradict, and the
string is frozen now. If a watcher marks her away, she should probably read who did.

**Owed before Phase 5:** the 21:00 reminder says *"so your family knows you're well"* while the
screen may simultaneously say nobody is set up — reminders are armed regardless of the audience by
deliberate design, because they exist for her own routine. Either an empty-audience variant, or an
explicit acceptance once onboarding guarantees pairing before reminders arm.
