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
| `through <= request.time + 30d` — the cap | ✓ | ✓ |
| `from >= today` — no retroactive away | ✓ | — |
| `from` unchanged from the stored value | — | ✓ |
| delete allowed | — | ✓ (cancelling before any day has elapsed) |

> **`from >= today` is a create-only rule, and this is load-bearing.** Cancellation truncates
> rather than deletes (§12), which rewrites an in-progress period whose `from` is already in the
> past. A blanket `from >= today` would reject exactly the write that keeps a cancelled away from
> retroactively un-covering the days already spent away. Enforcing immutability on update is what
> replaces it.

> **The cap is against `request.time`, not against `from`.** Identical only while `from` is always
> today, which is true in v1. §12 keeps `from` as a real field so future-dated away becomes a UI
> change with no migration — at which point the two diverge: `from + 30d` would cap the *duration*,
> while `request.time + 30d` caps how far ahead the period may *extend*.

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

The 30-day cap is a **guardrail, not a security boundary**. Someone determined to stay away for 60
days can set it twice, and that is the intended behaviour — the cap exists to force a deliberate
renewal so an away period cannot silently outlive its purpose.

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
- Away period validation: `through < from`; 31 days; `from` yesterday on create; **`from` mutated
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
