# Firestore security rules — guidelines

**Date:** 2026-08-15 · **Status:** Current · Implements
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §8.
No rules file exists yet. `firestore.rules` is written in **Phase 4**.

The rules are the only real authorisation boundary in this app. The client is untrusted by
definition — it runs on hardware the user controls and its code can be read out of the APK. Any
check that lives only in Dart is a UX affordance, not a control.

---

## The access matrix

This table is the specification. If the rules and this table disagree, one of them is a bug.

| Path | Read | Write |
|---|---|---|
| `users/{uid}` | self | self |
| `users/{uid}/tokens/{token}` | self | self |
| `users/{uid}/shared/away` | self, **or** an accepted link exists | self, **or** an accepted link exists — plus validation below |
| `links/{id}` | `watchedUid == uid \|\| watcherUid == uid` | Function only, **except** either party may set `status: "revoked"` |
| `checkins/{uid}/days/{date}` | self, **or** an accepted link exists for `(uid, request.auth.uid)` | self only |
| `invites/{code}` | **nobody** | Function only |

Anything not listed is denied. End the ruleset with a catch-all deny rather than relying on the
absence of a match.

---

## Rules that are load-bearing, and why

**`invites/` is unreadable by every client.** Not "readable only by the creator" — unreadable. A
readable invite collection is an enumerable list of live codes. Redemption happens exclusively
inside the `redeemInvite` callable, which also means the client never learns another user's uid
from an invite document.

**The watcher read on `checkins` costs a `get()` per rule evaluation.** This is accepted
deliberately. Without it, the watcher's alarm could not pull the truth from Firestore at fire time
and would have to trust FCM for correctness — which
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §3 explicitly refuses. The cost is negligible at
family scale and is recorded so it is never a surprise.

**Away is a direct client write, not a callable.** On purpose: a watcher can set away on a plane
and have it queue offline like any other Firestore write. Validation therefore has to live in the
rules.

From [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §8, as amended by
[ADR-0001](../architecture/decisions/0001-away-cache-precedence.md):

| Rule | On create | On update |
|---|---|---|
| `through >= from` | ✓ | ✓ |
| `through <= request.time + 32d` — the cap, **deliberately slack**; see below | ✓ | ✓ |
| `from >= today` — no retroactive away | ✓ | — |
| `from` unchanged from the stored value — **while the stored period is still in force** | — | ✓ |
| delete allowed | — | ✓ **unconditionally** — see below. The parenthetical *"cancelling before any day has elapsed"* described the **client**, not the rule |

> **`from >= today` is a create-only rule, and this is load-bearing.** Cancellation truncates
> rather than deletes (§12), which rewrites an in-progress period whose `from` is already in the
> past. A blanket `from >= today` would reject exactly the write that keeps a cancelled away from
> retroactively un-covering the days already spent away. Enforcing immutability on update is what
> replaces it.

> **`from` is frozen for the life of a PERIOD, not of a person — corrected at the Phase 6 gate.**
> Nothing deletes this document when a period runs its course, so the record outlives the holiday.
> A flat `from == resource.data.from` therefore meant away could be set **once per person and then
> never again**: every later attempt refused, on both sides, for ever — while the paragraph below
> says a determined person "can set it twice" and §12 says "to go longer, set it again". Neither was
> reachable.
>
> The clause now admits a fresh, non-retroactive `from` once the stored `through` is behind today:
>
> ```
> request.resource.data.from == resource.data.from
>   || (dayStart(resource.data.through) < todayStartUtc()
>       && awayNotRetroactive(request.resource.data))
> ```
>
> **Inexact by up to a day, and which way it errs depends on the zone.** `through` is a day label in
> the watched person's zone and `todayStartUtc()` is a UTC date. This block said the comparison was
> *"biased strict"* — that it could only ever refuse a legitimate write. **The Phase 6 close-out gate
> corrected that: it holds for non-negative UTC offsets only.**
>
> - **Positive offset** (Europe/Madrid, where this app actually ships). UTC runs behind local, so a
>   period that ended yesterday locally still reads as in force for the first one to two hours of the
>   local day: a legitimate re-set is refused, recoverably, and says nothing false. Here
>   `utc_today > through` implies `local_today > through`, so the permissive error below **cannot
>   occur** and the clause genuinely is strict.
> - **Negative offset** (the Americas). UTC runs ahead, so a period whose last day is **today** can
>   read as ended for the last hours of the local day, and a fresh non-retroactive `from` may land
>   while the stored period still has a day to run — un-covering days already spent away, which is
>   the false claim to a family ADR-0001 exists to prevent.
>
> **Not reachable from this app**: `AwayRules.periodInForce` resolves the day in the watched person's
> own zone and refuses first, so the permissive case needs a client driving the SDK directly. It is
> left as-is rather than widened by the one-day slack used elsewhere in this file, because that would
> take the strict cost in the shipping zone from about two hours to about twenty-six and buy nothing
> there. **Revisit if this app ever serves a negative UTC offset.**

> **`allow delete` is unconditional, so the clause above is not an invariant.** No shape, no state,
> no time — *"a new `from` may not land while a period still has a day to run"* is reachable by
> **delete then create**, in every timezone, by the watched person and by every accepted watcher.
> Left open deliberately: a party who can do it can already delete the document outright, which
> un-covers everything, and guarding it on `from` would make a **malformed stored document
> unrepairable** — `dayStart()` errors on a bad day key, so the update branch and a guarded delete
> would both deny with no client path left to clear it. **The invariant is therefore
> client-enforced**, by `AwayRules.periodInForce`, and that check is not a duplicate of anything in
> this file.

> **The cap is against `request.time`, not against `from`.** Identical only while `from` is always
> today, which is true in v1. §12 keeps `from` as a real field so future-dated away becomes a UI
> change with no migration — at which point the two diverge: anchoring at `from` would cap the
> *duration*, while anchoring at `request.time` caps how far ahead the period may *extend*. The
> domain enforces **both**, at different points — see *The absurd case is defended twice*.

**Attribution**, adopted into §8 by
[ADR-0003](../architecture/decisions/0003-away-attribution.md). All three are pure
`request.resource.data` checks and cost no extra reads:

| Rule | On create | On update |
|---|---|---|
| `setBy == request.auth.uid` | ✓ | ✓ |
| `setByName` present, string, 1–100 chars | ✓ | ✓ |
| `setAt` / `updatedAt == request.time` | ✓ | ✓ |

Note `setBy` and `setByName` are **mutable** on update, deliberately unlike `from`: §12 is
last-write-wins, so extending someone else's away period must re-attribute it to whoever wrote
last.

> **Do not add a rule cross-checking `setByName` against `users/{uid}.displayName`.** It looks
> like the obvious hardening and it is worth nothing: §8 grants `users/{uid}` write-to-self, so
> anyone can rename themselves before writing, and the check costs a `get()` per write. `setBy`
> is the enforceable identity; `setByName` is a display label. ADR-0003 records the reasoning so
> this is not re-proposed.

The 31-day cap is a **guardrail, not a security boundary**. Someone determined to stay away for 60
days can set it twice, and that is the intended behaviour — the cap exists to force a deliberate
renewal so an away period cannot silently outlive its purpose. *(Unreachable until the Phase 6 gate,
for the reason in the block above: setting it a second time was refused. The renewal the cap exists
to force is now actually possible.)*

> ### The rules cannot enforce this cap exactly, and must not try
>
> `through` is a calendar date **in the watched person's timezone**. `request.time` is a UTC
> instant, and the rules engine has no timezone conversion — it cannot know that zone. So any
> `through <= request.time + Nd` clause compares two things that are not exactly comparable, and is
> loose in two independent ways:
>
> - **Adding a duration to an instant is not calendar arithmetic.** 720 hours after 23:30 on a day
>   preceding a spring-forward lands on day + 31; after 00:30 before a fall-back, on day + 29. The
>   same rule therefore admits 30, 31 or 32 days depending on the *time of day the write happened*
>   and whether a DST transition falls inside the window.
> - **UTC is not the watched person's day.** For a watched person in Auckland the local date runs
>   ahead of UTC for much of each day, so a UTC-derived bound rejects writes that are legitimately
>   inside the cap.
>
> **So write it as `+32d`**, on create and on update, with a comment saying it is approximate and
> why. Two days of slack absorbs the DST swing, the time-of-day swing, and the UTC-versus-local-date
> offset for every inhabited zone. The slack is deliberately biased to be **generous enough never to
> reject a legitimate write**: a rejected away write queues offline and surfaces minutes or hours
> later with no visible cause, which is far worse than admitting a period a day or two over a cap
> that is a guardrail in the first place.
>
> **The exact cap lives in `AwayRules` in the domain layer**, which is given `today` as a `DayKey`
> already resolved in the watched person's zone. That is the only place the question is
> well-posed. The rules stop the absurd case — a ten-year away period that silences a family
> forever — which is the whole of what they are for. Travel is *not* the cause of any of this and
> does not need special handling: the mismatch bites a watched person who never leaves their house.

### The absurd case is defended twice, deliberately

The rules bound what can be **written**. They do not bound what a device may **read** — and
[ADR-0001](../architecture/decisions/0001-away-cache-precedence.md) says a read that *succeeds* is
trusted. A ten-year away document that reaches a watcher any other way — written before these rules
were deployed, admitted through a rules-deploy mistake, or produced by a buggy client — would
silence that family for ten years, and **the staleness bound could not save them**, because nothing
is stale: the read works perfectly, every day, and returns the same absurd answer.

So the domain clamps as well. `AwayPeriod.clampedToSanityBound()` bounds the period, and `covers()`
applies it by default so no caller can forget — the first version clamped at one of three call
sites and left the watched person's own reminders suppressed for a decade.

**The sanity bound is 60 days, deliberately far above the 31-day cap, and it must stay that way.**
Sizing it *to* the cap looks tidier and is wrong: the rules are slack at `+32d`, so they legitimately
admit periods of up to ~34 local days, and a read-time bound at the exact cap would un-honour
periods the server had accepted — telling a family *"No check-in from Mum yesterday"* for days they
really did mark away. That trades a rare absurd-document failure for a routine false claim, which is
the worse deal by this project's own ordering. The bound answers only *"can this possibly be
real?"*; `AwayRules` is where the exact number lives.

| | Number | Enforced where | Answers |
|---|---|---|---|
| The cap | 31 days | `AwayRules`, client-side, exact | "is this a legal away period?" |
| The rules clause | `+32d` | Firestore, slack | "is this obviously not one?" |
| The sanity bound | 60 days | `AwayPeriod`, on read | "can this possibly be real?" |

Note the two bounds are anchored differently, and that is not an inconsistency:

| | Anchor | Bounds |
|---|---|---|
| `AwayRules` — write time | **today** | how far ahead a period may reach |
| `clampedToSanityBound` — read time | **`from`** | how long a family can be silenced (60 days) |

They coincide while `from` is always today, and separate the moment future-dated away is exposed —
at which point each is still bounding the thing it was written to bound.

**Links are Function-written, with one exception.** Creation goes through `redeemInvite` so
single-use and expiry are enforced server-side. Revocation is a client write because either party
must be able to walk away without a round trip — but it may set `status: "revoked"` and nothing
else.

---

## Writing rules

- **Validate the shape of every write**, not just the identity of the writer. Check that the fields
  present are exactly the fields expected, that types are right, and that immutable fields
  (`watchedUid`, `watcherUid`, `activeFrom`) are unchanged on update. `request.resource.data.keys()`
  compared against a literal list is the blunt tool that catches most of this.
- **Never trust a client timestamp for authorisation.** `deviceTappedAt` is client-supplied data
  that the UI displays; `receivedAt` is `request.time`. Do not authorise on the former.
- **Factor the repeated `get()` into a named function.** `hasAcceptedLink(watchedUid)` appears in
  three places. Duplicating it is how the three drift apart.
- **Deny by default; grant narrowly.** Prefer several specific `match` blocks over one broad one
  with exceptions carved out.
- **Rules are public and that is fine.** They are in the repo, they will be read, and a ruleset
  that is only safe while unread is not safe. See [secrets-policy.md](secrets-policy.md).

## Testing rules

Rules are tested against the **Firebase Emulator Suite** with `@firebase/rules-unit-testing`, never
against the live project. Every row of the access matrix needs both halves: the allowed case
succeeds, and the denied case is **denied** — a rules test that only asserts the happy path proves
nothing.

Cover at minimum:

- Each matrix row, allowed and denied.
- A watcher with a `revoked` link — must be denied everywhere an accepted link would be allowed.
- Away period validation: `through < from`; a 32-day period (31 days is the longest **allowed**); `from` yesterday on create; **`from` mutated
  on update** (must be denied); and the truncation write that cancels an in-progress period (must
  be **allowed**, even though its `from` is in the past).
- Away attribution validation: `setBy` spoofed to another uid (denied); `setByName` absent, empty,
  non-string, or over 100 chars (denied); `setAt`/`updatedAt` backdated (denied); and a second
  writer **extending** an existing period, which must be **allowed** and must re-attribute — a
  test that only asserts denial here would freeze `setBy` and break §12's last-write-wins.
- A write to `links/` from a client that changes anything other than `status: "revoked"`.
- Any read of `invites/`, by anyone, including the invite's creator.

## Deploying

```powershell
firebase deploy --only firestore:rules --project i-am-ok-c74ca
```

Rules are deployed **from this repo only**. Nothing is edited in the console — a console edit is
silently overwritten by the next deploy, and the drift is invisible until something breaks. This
was stated explicitly in the provisioning prompt
([infrastructure/firebase-setup-prompt.md](../infrastructure/firebase-setup-prompt.md), Task 8) and
still holds.
