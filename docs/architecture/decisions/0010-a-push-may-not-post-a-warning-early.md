# ADR-0010 — A push may not post a warning before `warningLocalTime`

**Date:** 2026-08-25 · **Status:** Accepted
**Phase:** 4 · **Affects:** ARCHITECTURE.md §10 · `ui-ux/screens.md` · `testing/device-matrix.md`

## Context

`Link.warningLocalTime` — *"10:00"*, the hour the watcher chose — fed **exactly one thing**:
`_desiredWarnings`, the rolling window of warning alarms. It appears nowhere in §10's six ordered
steps, so it bounds when the *alarm asks*, never when a warning may be *posted*. Whoever calls
`reconcile()` posts whatever `WarningPolicy` says is owed, and `WarningPolicy` owes a warning from
the moment `D` is complete — which is local midnight in the watched person's zone.

That was invisible for three phases because the alarm was the only **unattended** caller. Every
other caller was somebody opening the app.

Phase 4 added a second unattended caller, and it fires on **somebody else's** action. Measured on
the POCO F3 while checking whether a Doze push shows the user anything:

```
channel=warnings  importance=5
android.text = "No check-in from Ana yesterday."
posted 2026-08-25 00:24:53 CEST
```

`warningLocalTime` was 10:00. The app decided correctly, on its own channel, in its own approved
copy — the last completed day genuinely had no check-in. What was wrong was the hour, and the cause
was ordinary: a check-in was written, `onCheckInCreated` fanned out, and the isolate woke. Nobody
had to be in an unlucky timezone pairing.

ADR-0009 makes it worse rather than better. A device that has decided nothing for a week owes one
warning per missed day, oldest first, so the same push posts up to seven notifications at 00:24.

## Decision

**A warning is posted only when `now >= today's `warningLocalTime`` in the watcher's own zone.**
Before that hour the reconcile still runs in full; only the *posting* is held.

It is implemented as a **delivery downgrade**, not as a new branch and not as a new state:
`WatcherReconcileService._notBefore` hands the domain `NotificationDelivery.unavailable` on the
warning channel, which already means exactly *not posted, not consumed, still owed at the next
reconcile*. Four consequences follow from that one substitution, and all four are required:

1. nothing is posted;
2. `warningsShownFor` is not written, so the day is not recorded as standing;
3. ADR-0009's `lastDecidedDay` does not advance across it, so the day is still owed;
4. the alarm window is armed exactly as before — `_desiredWarnings` arms every day whose instant is
   still ahead, so a run suppressed at 00:24 arms today's 10:00 alarm on its way past.

Three deliberate limits:

- **The warning channel only.** ADR-0004's *lost access* notice is a claim about **us**, not about
  her. A refusal is not tied to an hour, it is neither transient nor self-healing, and its decaying
  cadence — days 0, 1, 3, 7, 14 — is the thing `NotificationDelivery` exists to stop being burned in
  silence.
- **Only `available` is downgraded.** `redundant` means the reader is looking at the list, which is
  delivery by a route no hour applies to. Downgrading it would post at 10:00 about something the
  reader was shown at 00:24.
- **The watcher's zone, including its UTC fallback.** Agreeing with the alarm matters more here than
  being right in the abstract: a gate in one zone and an alarm armed in another would suppress a day
  the alarm has already passed.

## Consequences

**What it costs.** The acceleration a push buys is given up for the hours *before* the reader's
chosen time — the window nobody asked to be woken in. It is kept for the rest of the day, which is
where it was actually worth something: a push at 14:00 still posts immediately, and that is what
rescues a 10:00 alarm ADR-0008 measured Doze holding for 3h31m.

**Corrections are held back too, and that is the one consequence the approval did not spell out.**
A correction rides the warning channel at the warning's own id, so before the chosen hour a standing
false warning is **cancelled rather than replaced** — the path `redundant` already takes. The tray
ends empty and honest, which is the substance of the retraction; what is given up is the sentence
saying so. This was chosen over the alternative because a correction is *good news*, and good news
may not wake a family at 00:24. It is recorded in `ui-ux/screens.md` so it is a decision rather than
a side effect of a shared field.

**The screen is not gated by any of this**, and must not be. A reader who opens the app at 02:00 is
owed the truth about the day: the row still renders the warning, and the warnings-off banner still
reflects the *channel* rather than this link's hour.

**The risk it introduces**, stated plainly: every path above turns on the day remaining *unsettled*.
A future change that records, settles, or short-circuits a suppressed run turns a **late** warning
into a **lost** one, which §10 rates as the worst class of bug this app has. That is why nothing
here returns early and why no fourth enum value was added — the four properties are asserted
individually in `watcher_reconcile_service_test.dart`, and mutation-checked against a build with the
gate removed.

**Reversing it** is a one-line change and no migration: the gate is one static function with one
call site, and nothing is persisted differently.

## Alternatives considered

**Post immediately and let the reader mute the channel.** Rejected: the *Missed check-ins* channel
is the one this app cannot afford to have muted, and training a family to swipe it away is the
failure `guidelines.md`'s "quiet confirm, loud miss" exists to prevent. It also cannot be undone.

**Gate inside `WarningPolicy` as a seventh step.** Rejected: the six steps decide *what is true about
her*, and the hour is not evidence about anyone. Folding it in would make a silent decision
indistinguishable from a held one, and a silent decision **settles** the day — which is precisely
how this becomes a lost warning.

**A fourth `NotificationDelivery` state — `tooEarly`.** Rejected: it would behave identically to
`unavailable` at every one of the six places the enum is read, and a state that is a synonym is a
state two people will eventually treat differently. The prompt for the change said it in one line:
do not invent a state.

**Suppress the push instead, server-side, by scheduling the fan-out for the watcher's hour.**
Rejected: the Function would have to hold and re-send, which makes FCM load-bearing — §3's rule is
that a push carries no authority and losing one costs latency, never correctness. It would also give
a *second* decider about when a family hears something, which is the same objection ADR-0007 raises
against §9's scheduled function.

**Gate only the FCM caller, leaving app-open free to post early.** Rejected: it would mean two
callers with two answers about the same question, and the caller is not the thing that makes 00:24
the wrong hour. The cost of the wider rule is small and safe — the day stays owed and the alarm
speaks — and one rule is one thing to keep true.
