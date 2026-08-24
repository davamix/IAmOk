---
name: ui-ux-guidelines
description: Elderly-first UI rules, accessibility floors, and the exact approved notification copy for the I Am Ok app. Load before building or changing any widget, screen, or user-visible string, and before writing any notification text.
---

# UI/UX guidelines

Sources: `docs/ui-ux/guidelines.md` (principles) and `docs/ui-ux/screens.md` (the screen inventory
and the full approved copy).

Two audiences with opposite needs share one app: an **elderly person** who taps once a day and
needs certainty and one obvious action, and a **watcher** who does nothing until something is wrong
and may not open the app for weeks.

## Non-negotiable

**One screen, one action.** The watched person's main screen has exactly one thing to do. No tabs,
no nav bar, no settings gear competing for attention. Away is present but visibly secondary and
**not adjacent to the tap target**.

**The tap target is enormous, high contrast, and does not move between sessions.** Muscle memory is
the feature; a layout that reflows is a bug.

**Confirm the tap for the rest of the day.** After tapping, the target is disabled and reads
*"You already tapped today, at 09:14"*, re-enabling at local midnight. The write is idempotent, so
this is for the person, not the data — someone who cannot remember whether they tapped will tap
again and worry. The screen answering that question is the whole point.

**Quiet confirm, loud miss.** A check-in updates the watcher's status **silently**. Only a missed
day makes noise. Daily "everything is fine" notifications train a family to swipe away the one
notification that matters, and that training cannot be undone.

**Never claim more than the device knows.** There are **four** warning messages, not one, and which
one fires is a correctness requirement rather than copy polish:

| The device | Says |
|---|---|
| verified, and she did not check in | *"No check-in from Mum yesterday."* |
| could not **reach** the server | *"No check-in received from Mum yesterday — your phone has been offline since 22:10."* |
| has a cached away it cannot re-verify | *"Can't check on Mum — your phone has been offline since Tuesday 10:14. Mum was marked away until Saturday 22 August."* |
| was **refused** by the server (ADR-0004) | *"Can't check on Mum — I Am Ok has lost access to the check-ins. Open the app to see what to do. Your phone last saw a check-in on Saturday 15 August."* |

**The two rows above carry no pronoun for the watched person, and that is the point.** Both said
*"She"* / *"her"* until the Phase 3 gate: the model has no gender for anyone, `watchedName` is
denormalised onto the link, and a watched **father** was getting the wrong word in a message about
whether he was all right. The shipped strings interpolate the name or drop the possessive
entirely — see `NotificationCopy._awayClause` and `accessLostBody`. This table said otherwise until
the Phase 4 gate, which is worse than a stale doc: it is the table implementers are told to use
verbatim.

Silence would be a silent failure; a flat "she didn't check in" is a claim the device cannot
support; and **"your phone has been offline" is a claim about the *device* that is false whenever
the server was reached and said no** — which is what a revoked link, an expired token, App Check, or
a bad rules deploy all produce.

Two conventions the set depends on, worth keeping deliberately:

- ***"No check-in…"* is a claim about her. *"Can't check on Mum —…"* is a claim about us.** The
  opening tells the reader which kind of message this is before they read the detail. Do not mix
  them.
- **Every interpolated value can be null.** A watcher whose device has never had a successful read
  has no "offline since" and no "last saw"; the variants are in `screens.md` and are not optional —
  rendering "offline since null" to a worried family is the failure mode here.

**State, not history.** Cold open shows what is true **now** — an unresolved warning if one stands,
otherwise "Everything OK" with the last check-in time. A warning from three weeks ago followed by
three weeks of check-ins is history, not status.

**Name the person who acted.** *"Ana marked Mum away until Sat 22 Aug."* Never *"This person is
away."* A state change nobody can attribute is a state change nobody trusts.

**Say what "OK" means.** A tap at 00:05 Monday and 23:55 Tuesday is ~48h of real silence with both
days green. Inherent to calendar-day check-ins — the UI says *sometime that day*, never implying a
rolling 24 hours.

## Floors

| | |
|---|---|
| Touch targets | Primary tap: far beyond the 48dp Material minimum. Everything else: 48dp floor, no exceptions. |
| Font scale | Works at the system's largest setting without clipping or overlap. Never hard-code a size that ignores it. |
| Contrast | WCAG AA for all text; AAA for the tap target and any warning. Re-verify in dark mode. |
| Colour | Never the only signal. Every status carries text too. |
| Gestures | No long-press, swipe, or drag as the only route to an action. |
| Semantics | Every interactive element labelled. The tap target's label states the action **and** the current state. TalkBack usable end to end. |
| Motion | Minimal. No animation gates the primary action. |
| Errors | Say what happened and what to do. Never a code, never "something went wrong". |

## Copy

Plain language always. No "sync", no "token", no "reconcile", no error codes — the reader may be 80
years old, or reading it at 3am after a warning. Write the sentence a person would say out loud.

- Real names, not roles: "Mum", not "watched person".
- Dates written out: "Saturday 22", "Sat 22 Aug". Never `22/08` — ambiguous and hard to scan.
- Times: device-local, formatted by the device's own 12h/24h setting. The approved strings show 24h
  ("09:14", "23:40") because that is the owner's locale — render it, do not hard-code it.
- **No emoji, no exclamation marks.** Every notification here is either quiet status or bad news.
- A correction **replaces** the warning it corrects — same notification id — so the false one is
  gone rather than sitting above the truth in the shade.

**The approved notification strings are in `docs/ui-ux/screens.md`. Use them verbatim.** They were
written to avoid making claims the device cannot support. Do not paraphrase, and do not invent new
user-visible copy without adding it to that file.

Away picker copy is exact and load-bearing: **"Last day away: Saturday 22" / "Back on Sunday 23"**.
"Until Saturday" alone is ambiguous about whether Saturday still needs a tap. Start date is always
today; no future-dating in v1; 31-day maximum (the last selectable day is 30 days after today).

## Health is state, not a gate

Permissions are re-checked on every app resume and surfaced in an always-reachable health panel —
never a one-time onboarding step. Android revokes permissions from apps nobody opens, which is
exactly the watcher's situation, and a silently inert watcher app is the failure mode this product
cannot afford.

## Before designing something not in screens.md

Check `docs/ui-ux/screens.md` first: it records what has actually been decided and marks what is
open. An absence there is **not** a free choice — several items are explicitly undesigned and owed
a decision. Add your decision to that file when you make one.
