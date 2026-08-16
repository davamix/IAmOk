# ADR-0004 — "Reached and refused" is not "could not reach"

**Date:** 2026-08-16 · **Status:** Accepted
**Phase:** 1 (found at the Phase 1 gate; implemented in Phase 1, consumed in Phases 3, 4 and 7)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §10, §13, §17 · refines
[ADR-0001](0001-away-cache-precedence.md)

## Context

[ADR-0001](0001-away-cache-precedence.md) established the rule that makes the watcher's warning
trustworthy:

> A read that **fails is not an answer.** A timeout, a permission denial, and an App Check
> rejection all happen while the device is online, and none of them prove the away document is
> gone. Only a read that succeeded and returned nothing may clear the cache.

That is correct, and this ADR does not touch it. **It was over-applied.** The Phase 1 domain layer
carried the rule from *cache retention*, where the reason for failure is genuinely irrelevant, into
*message selection*, where it is decisive. `WarningPolicy.decide` took `required bool
readSucceeded`, collapsing a five-value failure enum to one bit — and the code documented the
collapse as intentional:

> Informational — the decision treats every value here identically. It exists so a failure can be
> logged and surfaced in the health panel, not so the policy can branch on it.

With one bit available, every failed read produces §10 step 5's negative branch:

> *"No check-in received from Mum yesterday — your phone has been offline since HH:MM."*

There are two genuinely different states hiding inside "failed", and that sentence is true of only
one of them:

| | Device state | "your phone has been offline" |
|---|---|---|
| **Unreachable** — offline, timeout, DNS | out of contact | **true** |
| **Refused** — permission denied, unauthenticated, App Check | online, connected, *talking to the server* | **a false claim about the device** |

**The failure.** §8 gates `checkins/{uid}/days/{d}` on "an accepted link exists". So the moment a
link is revoked — which §8 permits *either party* to do — every subsequent read is denied, the
denial is a failed read, and the watcher is told daily that their phone has been offline and that
no check-in was received from someone they no longer watch. Both halves are false. §10's asymmetry
table rates this class as costing "Everything. Telling a family something false is the worst
possible bug."

Revocation is the mildest instance. The same path is reached by:

- **App Check enforcement** (§9, Phase 4, provisioned in monitoring mode) rejecting a legitimate
  install — a fault the user can neither see nor fix, reported to them as a network problem;
- an expired or signed-out auth token;
- **account deletion** — threat model T9, explicitly undecided, where the watched person's data
  becomes unreadable by design;
- **a bad `firestore.rules` deploy**, which would tell *every watcher in every family,
  simultaneously*, that their phone is offline and their relative may be in trouble. A
  configuration error becomes a fleet-wide false alarm.

Chasing this surfaced a second instance of the same error, in a layer not yet written.
**Firestore's offline persistence is enabled by default and `get()` does not throw when offline —
it returns cached data.** A naive Phase 4 implementation would therefore construct a *successful*
read from a cache hit, stamp `lastReconcileAt`, and reset ADR-0001's two-day staleness bound. A
device offline for thirty days would "verify" thirty times, and a cached away period would silence
the watcher indefinitely — reintroducing precisely the wrongful silence ADR-0001 was written to
eliminate, through a different door.

Both are the same mistake: **treating "I got bytes" as "I verified."**

## Decision

**1. Verification is a three-state fact, and the type system enforces it.** `FirestoreRead` becomes
a sealed hierarchy of `ReadSucceeded` / `ReadUnreachable` / `ReadRefused`, and the policy receives a
narrowed `Verification` value rather than a bool. A sealed type is the specific remedy for a
mistake made *while holding the correct rule in mind*: it makes flattening a compile error rather
than a judgement call.

The policy receives `Verification`, not the read itself, so it still cannot reach the payload and
re-derive state that `applyRead` is responsible for — the property that keeps it a pure function
over explicit inputs.

**2. A fourth warning outcome, `warnAccessLost`.** Refusal is reported as what it is:

> *"Can't check on Mum — I Am Ok has lost access to her check-ins. Open the app to see what to do.
> Your phone last saw a check-in on Saturday 15 August."*

It claims nothing about the watched person, nothing false about the device, states what **is**
known, and is **actionable** — unlike "offline", about which a user can do nothing.

Three details, each of which the first draft got wrong and review caught:

- **"Your phone last saw", not "Last confirmed."** `lastConfirmedDay` is the newest check-in *this
  device has managed to read*, not the day she last tapped — during a refusal she may be tapping
  daily. "Last confirmed Saturday 15 August" reads as a five-day silence on the 20th. The words
  claimed nothing; the reading did, and §10's asymmetry rates a false claim to a family as the worst
  bug this app can have. Attributing the fact to the phone removes the implicature.
- **"Open the app", not "Open I Am Ok."** After an imperative verb the app's name parses for a beat
  as its own clause — *"Open — I am OK"* — which is the opposite of the message, read by the person
  most likely to misread it.
- **`lastConfirmedDay` is nullable**, and access can be lost before any check-in was ever seen. The
  variant is *"Your phone has not seen a check-in yet"* — deliberately not "she has never checked
  in", which is unsupportable.

There is a third variant for a cached away period, because `warnAccessLost` carries `away` and
dropping it would leave a watcher whose relative is provably marked away phoning Portugal at 08:00.
All three, and the two pre-existing never-reconciled variants review found loose in the *approved*
set, are recorded in `docs/ui-ux/screens.md`.

**3. Refusal dominates the away branch, but not positive evidence.** The order becomes:

```
revoked → before activeFrom → check-in recorded for D → REFUSED → cached away → warn
```

Placing refusal after evidence and before away is deliberate. A recorded check-in for `D` settles
the day on facts already held, and losing access does not unsettle it — `lastConfirmedDay` is
monotone and can only ever have been written by a read that succeeded, so it is a settled fact
about a *completed* day. A *cached away*, by contrast, is a claim about the **present** resting on
a read that can no longer be repeated: ADR-0001's two-day bound is calibrated for transient network
failure — "a phone in a pocket" — and a refusal is neither transient nor self-healing.

The placement is stronger than a judgement call, and this is the argument that settles it: **a
refusal fails every subsequent daily attempt identically, so the two-day bound expires anyway and
the away branch would produce `warnUnverifiableAway` on day three regardless.** Ordering refusal
above away therefore does not change *whether* the app speaks — only *when*, and *with which
sentence*. In the two days it would otherwise wait, the sentence it would eventually use says the
phone has been offline, which is false. There is no version of this where silence is preserved;
there is only a version where the app lies for two days first.

**Consequently `WatchStatus` gains the same distinction.** Access loss is recorded apart from
`warningsShownFor`, which stays reserved for claims about the watched person. Recording a refusal
there would make the watcher's list row report a standing missed check-in — the same false claim
this ADR removes from the notification, arriving through the list instead — and would later have
the correction handler retract a message that never claimed anything about her.

**4. Revocation is not a failure and is not diagnosed as one.** A revoked link is known locally,
before any read is attempted: `WarningPolicy` returns silent with `SilenceReason.linkRevoked`, and
the reconciler tears the warning alarm down rather than leaving it armed and mute. §10's sequence
never consulted `link.status` — §7 defines the field, §8 gates on it, §6 and §9 give it a write
path, and the one section that decides whether to speak never asked. **§10 gains that step.**

**5. Lost access is a health-panel item (§13),** alongside `POST_NOTIFICATIONS` and clock skew,
with the refusal reason driving the remediation. Persistent conditions belong in the panel;
notifications are for events. The notification in decision 2 is still required, because §13 already
argues that a low-usage watcher never opens the app — which is exactly the person this failure
silences.

The refusal usually happens in the **alarm isolate**, and §4's rule is that anything a background
isolate produces for the UI is on disk — so §6's `LocalStore` row gains `accessLostSince` and
`accessLostCause`, and §13's row is keyed on them. Without that the panel could only ever report a
refusal the *UI* happened to hit, which is the one isolate that does not run when this fails.

**Consequently the notification follows a decaying cadence: day 0, day 1, day 3, then every seventh
day, indefinitely.** Both obvious choices are wrong, in opposite directions.

*Daily* lands in the same channel as the real "No check-in from Mum yesterday", and §13 already
argues that training a family to swipe that channel cannot be undone — worse for a cause the reader
cannot fix, such as account deletion, where it would never stop.

*Once, on the transition* was the first implementation here and is the more dangerous of the two. A
single swipe — on a bus, at 10:00, before the watcher has taken it in — converts a fixable fault
into **permanent silence**, and the surfaces that hold the condition afterwards (the health panel,
the list row) only reach someone who opens the app, which §13's own argument says this watcher does
not. That is §17's High-severity silent failure, reached by one thumb.

So day 1 catches the swipe while the fault is freshest and most fixable — a re-sign-in takes
seconds — day 3 is a last nudge, and the weekly heartbeat is slow enough not to train swiping and
frequent enough that the app never goes quietly inert. **It does not stop**, for the same reason
§12 caps away periods: better a deliberate renewal than something outliving its purpose unnoticed.
For a cause the watcher genuinely cannot resolve, the escape belongs in the copy — `screens.md`
already says *"ask whoever set up the app"* — not in going silent. The numbers are a judgement call,
not a derivation.

Two consequences fall out. `reconcile()` runs on app open, FCM arrival, alarm fire and boot, so a
cadence in days needs `accessLostNotifiedOn` to dedupe within the day or a reminder day fires four
times. And a **changed cause** re-notifies whatever the cadence says: "sign in again" and "update
the app" are different instructions, so the standing notification is the wrong one the moment the
cause moves.

**There is no "access restored" notification.** Quiet confirm, loud miss — the row and the panel go
green and the next real warning gets through. The same shape as §12's absent "away finished"
message, for a gentler reason: losing this one costs nothing, because the app simply resumes
working.

**6. A standing message is replaced only by a stronger one.** With four outcomes reachable for the
same `D`, `warningsShownFor` records *which* message is standing, not merely that one is. A 10:00
alarm that could not reach the server, followed by an 11:00 app-open that verifies the day, must
replace the hedge with the claim the device can now support. The reverse must not happen: once a
day is verified, a later failed read is no reason to walk *"No check-in from Mum yesterday"* back
to *"your phone has been offline"*.

**7. Revocation withdraws standing warnings; it does not correct them.** A warning standing when a
link is revoked can never be cleared otherwise — every later read is refused, so no correction can
run — and would sit in the tray, and on the list as a row demanding attention, forever. Withdrawal
is a distinct channel from correction because nothing here disproves the warning: *"Mum did check
in yesterday"* would be a claim the device cannot support.

**8. Phase 4 is constrained now, while it is still cheap.** The mapping is named rather than left
to be guessed:

| Firestore condition | Verification |
|---|---|
| `permission-denied`, `unauthenticated`, App Check rejection | **refused** |
| `unavailable`, `deadline-exceeded`, no connectivity | **unreachable** |
| a snapshot with `metadata.isFromCache == true` | **unreachable — never succeeded** |

The last row is the trap above, and it is not optional: the reconcile read must use
`Source.server`, or check `isFromCache` and treat a cache hit as a failure to verify. A read served
from the local cache has verified nothing, however successful it looks.

## Consequences

**Bought.** The three false-claim paths above stop being false. A revoked link goes quiet instead of
accusing a phone of being offline. An App Check or rules misconfiguration produces an honest,
actionable message pointing at the app instead of a fleet-wide false alarm about people's relatives.
ADR-0001's staleness bound keeps working in Phase 4 rather than being silently disabled by the
offline cache. §17's "silent failure" risk gains a real control: the app can now say *the app is
broken* as distinct from *your phone is offline* and *she did not check in*.

**Paid.** A fourth outcome and a fourth message to write, test and translate. A genuine away period
coinciding with a genuine access loss now notifies where it previously stayed silent — accepted
deliberately, on the same reasoning as ADR-0001: the app is in fact broken at that moment, and
silence is the one failure this app cannot detect in itself. `WarningPolicy.decide` gains one
parameter (`linkAccepted`) and changes another (`readSucceeded` → `verification`).

**Superseding the model, partially.** `tools/models/away_warning_model.dart` has a single `readOk`
flag that conflates both failure modes. Its 18 cases remain correct **read as the unreachable
interpretation**, which is how they are ported; `S15` and `S16` gain refused-interpretation
counterparts in the real suite rather than in the model. The model is annotated to say so, and its
`superseded: 4 / decided: 0` invariant is untouched.

**Reversing** costs a `WarningPolicy` change and its tests, plus the copy. Nothing migrates; no
stored data changes shape.

## Alternatives considered

**Fix only the revoked link — one `linkAccepted` check.** The first proposal, and rejected once the
blast radius was clear: it treats the symptom. App Check, token expiry, account deletion and a bad
rules deploy all reach the same false sentence by other routes, and the last of those is a
fleet-wide event.

**Stay silent on a refused read.** The conservative reading. Rejected for the reason ADR-0001
rejected it: silence is the one failure this app cannot detect in itself, and a watcher who
believes they are being told nothing *because there is nothing to tell* is exactly the person this
app exists to inform.

**Reuse `warnOffline` with softened wording** — drop "your phone has been offline" and say only
"couldn't check". Cheaper, and rejected: it removes the falsehood by removing the information,
leaving one vague message covering a transient network blip and a permanently broken app install.
Those need different actions from the reader, so they need different messages.

**Keep the bool and branch on `ReadFailure` inside the reconciler.** Would work today, and rejected
as leaving the trap armed: the policy is where "what do we say" is decided, and a bool at that
boundary invites exactly the collapse this ADR is correcting. The sealed type makes the mistake
unrepresentable instead of merely discouraged.

**Make lost access health-panel-only, with no notification.** Rejected: §13 exists because Android
auto-revokes permissions for unused apps and "a watcher who never opens the app would silently stop
receiving anything". A panel that only speaks when opened cannot reach the person it is for.
