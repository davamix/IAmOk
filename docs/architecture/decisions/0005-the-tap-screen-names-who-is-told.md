# ADR-0005 — The Tap screen names who will be notified, and says nothing else

**Date:** 2026-08-16 · **Status:** Accepted
**Phase:** 1 (decided at the Phase 1 gate; implemented in Phase 2)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §7 · `docs/ui-ux/screens.md`

## Context

§8 lets **either party** revoke a link. [ADR-0004](0004-refused-is-not-unreachable.md) modelled the
watcher side of that thoroughly — a revoked link goes silent, its alarm is torn down, and any
standing warning is withdrawn rather than corrected.

**Nothing modelled the watched side.** `WatchedReconciler.reconcile` took no links at all, so if the
last watcher revoked, the watched person went on tapping every day believing the promise, and no
surface anywhere said otherwise. The Phase 1 security review raised this as finding M4.

No Cloud Function is needed to close it: §8 already lets the watched person read their own links, so
their device can see it by reconciling.

The question is therefore not *can we tell her* but **what, if anything, should the app say** — and
that is a product decision about who this app is for, not a technical one.

## Decision

**The Tap screen shows who will be notified when the person taps. That is all.**

| State | Line |
|---|---|
| One or more watchers | *"Ana and Beto will know you're OK."* |
| **Nobody** — never paired, **or** the last watcher revoked | *"No one is set up to know you're OK. Ask a family member to help you add someone."* |

**Explicitly rejected — do not implement, and do not re-propose:**

- a notification when someone starts watching;
- a notification when someone stops watching;
- a "nobody is watching you" **warning**, banner, or health-panel item;
- any other status-change message on the watched side.

The owner's reasoning, recorded so it is not re-litigated:

> If everyone stops watching Mum, that is a family problem or a lack of communication. It is not the
> app's responsibility.
>
> It is important to avoid extra notifications or messages in the watched app. Elderly people can be
> overwhelmed if we start showing different messages like "this started watching you", "that stopped
> watching you", "no one is watching you". Elderly users are not ready to read a lot, and may not
> understand what the different messages mean.

**One line covers both empty states, and that is the decision rather than a limitation.**
Distinguishing "never paired" from "everyone revoked" requires tracking that someone *left*, and
rendering that is the "someone stopped watching you" message above, under another name. So the line
never announces a change: it describes what is true now, in the same words, whichever way the screen
arrived there. It is styled as ordinary secondary text — never as a warning, because styling it red
would reintroduce the rejected message by appearance rather than by wording.

The empty line is shown rather than hidden. Showing nothing was the alternative and the owner
rejected it: a large button with no explanation is its own silent failure for someone who has never
been paired, and naming a next human is the same shape the health panel's dead-end row already uses.

**Consequently §7 gains `watcherName`.** The screen is not buildable without it: §8 grants
`users/{uid}` read **to self only**, so the watched person's device has no path from a `watcherUid`
to a name, and the link is the only document it may read that could carry one. The field is the exact
mirror of `watchedName` and carries the same status — a **display label, not an identity**, written
by `redeemInvite` from the redeemer's verified token, with nothing deciding anything from it. The
`setByName` framing in [ADR-0003](0003-away-attribution.md) applies unchanged, including its
rejection of a `displayName` cross-check.

## Consequences

**Bought.** The watched person can see, on the screen she already opens daily, whether the promise
is being kept. The commonest real case — she is paired and it works — is answered in one line she
can read at a glance, in the same words the onboarding question used.

**Paid — and this is a deliberate acceptance, not an oversight.** The residual of M4 stands: the
line appears only when she opens the app and looks below the target, it is ordinary secondary text,
and it never announces the transition. A watcher revoking at 09:00 is not surfaced until she next
looks. **A future reviewer will flag this again**, and should: the finding is real. The acceptance is
a judgement about the user population, made by the risk owner, and `docs/HANDOVER.md`'s non-goals
mean the app never promised to be the failsafe here.

Also paid: a schema field that Phase 5's `redeemInvite` must populate, and Phase 4's rules must
protect. The revoke exception in §8 has to be written as a key-set diff —
`affectedKeys().hasOnly(['status'])` — not as a test that the new status is `revoked`, or a single
write could carry `{status: "revoked", watcherName: "Dr Martinez"}`. Recorded in
`docs/security/firestore-rules-guidelines.md`.

**Reversing** costs a screen change and the copy. `watcherName` would stay, because it is cheap and
Phase 7's watcher list may want the symmetric case.

## Alternatives considered

**Show nothing when the list is empty.** The Phase 2 brief's own "quiet reading", and rejected by the
owner: before pairing has ever happened it leaves a person tapping a button with no idea whether
anything is behind it, which is the same silent inertness at the other end.

**Distinguish "never paired" from "everyone revoked".** More informative, and rejected because it is
the rejected message: any wording for the second state is a statement that someone stopped watching.

**Notify on revocation.** Rejected above, in the owner's own words. It is also the surface most
likely to arrive at the worst moment — a family member tidying up their own app produces an alarming
message on an elderly person's phone.

**Relax §8 so the watched person can read watchers' profiles.** The alternative to adding
`watcherName`. Rejected: strictly more data, on the collection that also holds email, and it would
break offline rendering — the watched device would need a live read to draw its own main screen.
