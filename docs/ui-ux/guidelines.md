# UI/UX guidelines

**Date:** 2026-08-15 · **Status:** Current · The Tap screen, the watcher list, the debug harness,
the failure screens, **sign-in, the three onboarding screens and both pairing screens** are built;
the away picker and the health panel are not. *"No UI has been built"* stood here until 2026-08-25,
four screens after it stopped being true.

Two audiences with opposite needs share one app.

| | Watched person | Watcher |
|---|---|---|
| Who | Elderly, lives alone, may not be comfortable with phones | Family member, busy, may not open the app for weeks |
| Does | One tap a day | Nothing, until something is wrong |
| Fails by | Not noticing a reminder; not being sure the tap worked | Ignoring a notification; never opening the app |
| Needs | Certainty and one obvious action | To be left alone until it matters, then told clearly |

Everything below follows from that split.

---

## Principles

**1. One screen, one action.** The watched person's main screen has exactly one thing to do. No
tabs, no nav bar, no settings gear competing for attention. If a second action must exist — Away —
it is visibly secondary, and it is not adjacent to the tap target.

**2. The tap target is enormous.** Large enough to hit without aiming, with high contrast against
its background, and it must not move between sessions. Muscle memory is the feature; a layout that
reflows is a bug.

**3. Confirm the tap in the UI, permanently for the day.** After tapping, the target is disabled
for the rest of the local day and reads *"You already tapped today, at 09:14"*. It re-enables at
local midnight. The write is idempotent so a second tap would be harmless — this exists for the
person, not the data. Someone who cannot remember whether they tapped will tap again, worry, and
ask a family member. The screen answering that question is the point.

**4. Quiet confirm, loud miss.** A successful check-in updates the watcher's status silently. Only
a *missed* day makes noise. Daily "everything is fine" notifications train a family to swipe away
the one notification that matters, and once trained they cannot be untrained.

> **And the noise waits for the link's warning time.** A warning is not posted before
> `warningLocalTime` in the watcher's own zone
> ([ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md)). That hour
> used to bound only when the *alarm asked*, so a push triggered by somebody else's tap woke a
> family at 00:24 with a warning about a past day — measured, not hypothesised. The day stays
> **owed**, so it is said at 10:00 rather than lost, and a push later in the day still posts at once.

**5. Never claim more than the device knows.** When the watcher's phone cannot reach Firestore it
says so, in different words: *"No check-in received from Mum yesterday — your phone has been
offline since 22:10."* Silence would be a silent failure; a flat "she didn't check in" is a claim
the device cannot support. This distinction is a correctness requirement, not copy polish.

**6. State, not history.** The watcher's cold open shows what is true **now**: an unresolved
warning if one stands, otherwise "Everything OK" with the last check-in time. A warning from three
weeks ago followed by three weeks of check-ins is history, not status, and must not be presented
as the current state.

**7. Say what "OK" means.** A tap at 00:05 Monday and another at 23:55 Tuesday is nearly 48 hours
of real silence with both days reading green. That is inherent to calendar-day check-ins. The UI
says *sometime that day* rather than implying a rolling 24 hours.

**8. Name the person who acted.** Away is set by a human and affects everyone: *"Ana marked Mum
away until Sat 22 Aug."* Never *"This person is away."* A state change nobody can attribute is a
state change nobody trusts.

**9. Health is always reachable.** Android can revoke permissions from an app nobody opens, which
is exactly the watcher's situation. Permission state is continuously observed and surfaced, never a
one-time onboarding gate.

**10. Plain language, always.** No "sync", no "token", no "reconcile", no error codes. The person
reading this may be 80 years old or may be reading it at 3am after a warning. Write the sentence a
person would say out loud.

---

## Concrete rules

| Rule | Value |
|---|---|
| Minimum touch target | Well beyond the 48dp Material minimum for the primary tap. Secondary controls: 48dp floor, no exceptions. |
| Text | Respect the system font scale up to the largest setting without clipping or overlap. Never hard-code a size that ignores it. |
| Contrast | WCAG AA at minimum for all text; AAA for the tap target and any warning. |
| Colour | Never the only signal. Every status carries text as well. |
| Motion | Minimal. No animation gates the primary action. |
| Copy | Short sentences. Real names, not roles: "Mum", not "watched person". |
| Dates in copy | Written out — "Saturday 22", "Sat 22 Aug". Never `22/08` — ambiguous, and hard to read at a glance. |
| Times in copy | Device-local, formatted by the device's own 12h/24h setting. The approved strings are written 24h ("09:14", "23:40") because that is this owner's locale; render, do not hard-code. |
| Dark mode | Supported, and contrast re-verified in it. Not assumed to fall out of theming. |
| Errors | Say what happened and what to do. Never a code, never "something went wrong". |

## Copy rules for notifications

Every notification this app sends is either quiet status or bad news. There is no marketing tone.

- **Never a false claim.** If the device cannot verify, the message says what it actually knows.
- **A correction replaces the warning it corrects** — same notification id, so the false one is
  gone rather than sitting above the truth in the shade.
- **Name the person**: *"No check-in from Mum yesterday."*
- **No emoji, no exclamation marks.**
- The watched person is never notified that they are being watched more closely, and never nagged
  about anything except the daily reminder.

## Accessibility

Not a polish pass — the primary user is elderly.

- Every interactive element has a semantic label. The tap target's label states the action and the
  current state.
- The app is usable end to end with TalkBack.
- Nothing requires a precise gesture: no long-press, no swipe, no drag as the only route to an
  action.
- The app works at the system's largest font scale and at 200% display size.

## Open

Recorded here so they are not silently decided by whoever writes the widget first.

- **Multiple watched people per watcher.** The data model supports it; the list UI has not been
  designed.
- ~~**What the watcher sees on cold open after weeks away.** A history strip, or just today?~~
  **Settled at the Phase 3 review: today only.** Not chosen on aesthetics — a fallback to "the
  newest day we ever warned about" shipped, and produced *"No check-in from Mum yesterday."*
  permanently on the 18th about a day she had checked in on, because a missed day leaves
  `warningsShownFor` only by correction or revocation. Every string in the warning set says
  *yesterday*, and only today's `D` is yesterday, so only today's `D` can be rendered honestly.
  Recorded in `screens.md` under "The watcher list shows today only".
- **The first day back after away.** Routine is most likely to break the day someone returns from a
  trip. No grace day is planned — the reminders do their job — but the copy could acknowledge it.
- **Whether the watched person's screen should show anything about the watchers at all**, beyond
  the fact that someone is watching. *Phase 5 added one thing and no more:* an **"Add someone"**
  control beneath the audience line. It is an action, not a status message, and it is what makes the
  empty line honest — that line used to end *"Ask a family member to help you add someone"*, the
  dead-end wording, which stops being true the moment there is something to press.
- **Whether the watcher ever chooses, or even sees, `warningLocalTime`.** Nothing sets it but link
  creation and the debug harness, and no screen shows it.
  [ADR-0008](../architecture/decisions/0008-the-warning-is-late-in-doze-and-the-app-says-so.md)
  forbids copy that states or implies a delivery time, and
  [ADR-0010](../architecture/decisions/0010-a-push-may-not-post-a-warning-early.md) has since made
  the hour a **hard floor** — so it is now load-bearing with no surface, and the watcher's only
  mental model of *when will I be told* remains unstated. `screens.md` owes the row either way.
  Phase 7.
