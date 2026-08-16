# Screen inventory

**Date:** 2026-08-15 · **Status:** Specification-in-progress. No screen has been built.

What is recorded here is **only what has actually been decided** — mostly behaviour and copy,
carried over from [PLAN.md](../PLAN.md) and [ARCHITECTURE.md](../architecture/ARCHITECTURE.md).
Layout, visual design, and anything marked *undesigned* below are open. Do not treat an absence
here as a free choice: add the decision to this file when it is made.

| Screen | Phase | State |
|---|---|---|
| Tap (watched main) | 2 | Behaviour and copy decided; layout undesigned |
| Debug harness | 2 | Capabilities decided |
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
| Not yet tapped today | The tap target, enabled. Large, high contrast, minimal chrome. |
| Tapped today | Target **disabled for the rest of the local day**: *"You already tapped today, at 09:14"*. Re-enables at local midnight. |
| Away | *"You're away until Saturday 22. Your family isn't expecting a check-in."* Tapping is still **allowed** — harmless, reassuring, and it writes a normal check-in watchers see as usual. |

The Away control is present but visibly secondary, and not adjacent to the tap target. While an
away period is active it reads *"I'm not away"*.

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
| Reminder, no tap yet | Watched | Escalating reminders at 12:00 / 18:00 / 21:00 |
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

**Still undecided, and owed before Phase 3 ships any of this:** the `contentTitle` / `contentText`
split for all four warnings; where the refused notification routes on tap; **suppressing a reminder
that lands while the watcher already has the app open** (reconcile runs on app open, so a cadence
day can post a notification to someone looking at the screen); and whether the copy set assumes
"she" — nothing in the domain captures a pronoun, so a watched father currently gets the wrong one.
