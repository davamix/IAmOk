# ADR-0011 — Creating an invite is a Function too

**Date:** 2026-08-26 · **Status:** Accepted
**Phase:** 5 · **Affects:** ARCHITECTURE.md §6, §9, §15

## Context

Two sections of ARCHITECTURE.md disagreed about who writes `invites/{code}`, and the disagreement
was invisible until somebody tried to build it.

**§8 says the write is Function-only**, and `firestore.rules` has enforced it since Phase 4:

```
match /invites/{code} {
  allow read, write: if false;
}
```

**§9 lists only `redeemInvite`.** And **§6 gives `InviteService` the job**: *"Create invite; call
`redeemInvite`."* Read together, §6 asks the Data layer to perform a write §8 forbids and the
deployed rules refuse. There is no client path to a code at all.

Nothing had caught it because nothing had needed a code yet. Phase 4 built the rules and 73 rules
tests — including four asserting that every client write to `invites/` is denied — and the
`invites.test.mjs` suite is *correct*; it proves the deny works. The gap is that no code had ever
been created, by anything, in any phase.

## Decision

**`createInvite` is a fourth Cloud Function, and `invites/{code}` stays unwritable by every
client.**

The server generates the code from §7's alphabet, checks for a collision with `create` rather than
a read-then-write, sets `expiresAt` to **24 hours** (the owner's decision), and takes `watchedUid`
from `request.auth` — never from the request body.

Two behaviours fall out of it and are part of the decision rather than implementation detail:

- **A live code is reused rather than replaced.** A second call while an unconsumed, unexpired
  invite exists returns that same code. The pairing screen can be left and re-entered, and a fresh
  code each time would kill the one somebody has already written down or read aloud.
- **The call sweeps the caller's own expired, unconsumed invites.** §9 deliberately has no scheduled
  function and this ADR does not add one; consumed invites are kept, because they are what lets a
  retried redemption recognise itself, and there is exactly one per link.

This is **not a change to §8**. It is §9 and §6 being brought into line with what §8 already said.

## Consequences

**What it makes easy.** The client holds no Firestore reference for pairing at all — `InviteService`
holds two function names. `invites/` remains unreadable *and* unwritable, so the collection cannot be
enumerated by any client path.

**What it makes hard.** A code cannot be minted offline. That is a real cost and it is the right way
round: an invite is a bearer credential for becoming a watcher of a vulnerable person, and one the
server never validated is not one this design should honour. The pairing flow assumes both phones are
present in one sitting anyway (`ui-ux/screens.md`), which is a moment with connectivity by
construction — the other phone has to reach the backend to redeem.

**What it costs to reverse.** Little. The rules already deny the client write, so relaxing them later
is a rules change plus a client path; nothing stored changes shape.

**What it does not fix.** Guessing. A determined caller can hammer `redeemInvite` with candidate
codes. At 32^6 ≈ 1.07 billion codes, single-use redemption, and a 24-hour life on a handful of live
codes at family scale, the expected number of hits is negligible — but it is **not zero, and the
prize is real**: a successful guess makes somebody a watcher of a stranger, which is the check-in
history and name of an identifiable elderly person living alone. The designed control is App Check
enforcement, which `OPEN-QUESTIONS.md` #5 records as structurally gated on an internal test track.
Recorded here so the absence is a known position rather than an oversight.

## Alternatives considered

**Let the client create the invite under a narrowed rule** — `allow create: if request.auth.uid ==
request.resource.data.watchedUid` plus shape checks, keeping `read` denied. Rejected: it reopens the
enumeration the deny exists to close, through the write path instead of the read path. A `create`
that fails because the document already exists tells the caller that code is live, so an attacker
probes with `create` and reads the answer off the error. It also contradicts §8 and the security
guidelines' explicit "load-bearing, do not soften" list.

**Let the client choose the code and have `redeemInvite` validate it** — no creation Function, the
code exists only once redeemed. Rejected: a client-chosen code is a client-*known* code, so the
watched person's device could be made to offer a code an attacker picked in advance, and the consent
record §2 rests on ("the watched person's device generating and sharing the code **is** the consent
record") would no longer be true of the generating half.

**Amend §6 to drop "create invite" and have the owner mint codes some other way** — a console, a
script. Rejected as not a design: there is no other way, and pairing is a user-facing flow.
