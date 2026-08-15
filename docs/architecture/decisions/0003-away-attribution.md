# ADR-0003 — Enforce away attribution; stop treating the name as authenticated

**Date:** 2026-08-15 · **Status:** Accepted
**Phase:** 0 (found at the Phase 0 gate; implemented in Phase 6, rules deployed in Phase 4)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §8, §17

## Context

§17 accepts a real risk and names one control:

> | One watcher silences the whole family by setting away | Low — accepted by design | `setByName` on every surface; anyone can cancel (§12) |

§12 builds on the same field — *"every device can show 'Ana marked Mum away until Sat 22 Aug'"* —
and uses it again to make last-write-wins legible. But §8's validation list covered only the
shape of the *period* (`through >= from`, the 30-day cap, `from >= today`) and declared itself
"enough". Nothing constrained **who** the document said had acted.

An accepted risk was therefore mitigated by client goodwill. Three ways that breaks:

- **Misattribution.** A watcher writes `setBy` pointing at another watcher and `setByName: "Ana"`.
  Every phone reports that Ana silenced the family when she did not. §12 frames setting away as
  *"I know she's fine, and I'm accountable for that"* — forging it moves accountability onto
  someone who never accepted it, and if the watched person is genuinely in trouble the family
  starts looking in the wrong place.
- **Absence.** Not malicious — a client bug or an older build omits the field, every surface
  renders "?? marked Mum away", and §17's mitigation degrades to nothing without anyone noticing.
- **Arbitrary text.** `setByName: "Dr. Smith, Hospital Admissions"` arrives as a notification on
  every family member's phone.

**The finding that shapes the decision: `setByName` cannot be meaningfully authenticated.**

The tempting rule is to require `setByName == get(users/$(request.auth.uid)).data.displayName`.
It is technically available — rules `get()` bypasses read rules, so `users/{uid}` being
self-read-only does not block it. But §8 grants `users/{uid}` **write: self**: the user owns their
own display name. An attacker renames themselves "Ana" and passes the check. The rule costs a
document read per write and buys nothing.

So the guarantees available here are asymmetric, and the design must say which is which rather
than implying the name carries the same weight as the uid.

## Decision

**Adopt into §8**, all three free — pure `request.resource.data` checks, no extra document reads:

1. **`setBy == request.auth.uid`**, on **create and update**. The uid cannot be forged.
2. **`setByName` present, a string, length 1–100.** Prevents the silent degradation of §17's
   mitigation and bounds notification-injection.
3. **`setAt` / `updatedAt == request.time`.** Blocks backdating.

**Explicitly reject** cross-checking `setByName` against the writer's `displayName`. Recorded here
so it is not re-proposed in Phase 4: it is defeated by a self-service rename and costs a read.

**`setBy` and `setByName` are mutable on update** — deliberately the opposite of `from`, which
[ADR-0001](0001-away-cache-precedence.md) froze. §12 says last write wins and `setByName` makes
the outcome legible, so if Beto extends Ana's period the document must now name Beto. Always the
current writer, never frozen.

**§17's mitigation is restated** to say what is actually true:

> `setBy` is the identity and is rules-enforced; `setByName` is a display label and is not
> authenticated. The UI shows the label; any dispute resolves through the uid.

## Consequences

**Bought.** A voluntary mitigation becomes an enforced one at zero read cost. A forged *name* is
now always recoverable, because the *uid* underneath is truthful — the family, or a support
Function, can establish who actually wrote the document. Without rule 1, nothing is recoverable.
Rule 2 means no client can silently disable §17's control by omitting a field.

**Paid.** `setByName` still cannot be trusted as a name. That is now documented rather than
implied, which is the point: a design that quietly suggests the label is authenticated is worse
than one that states it is not. Rule 3 means a client with a badly skewed clock cannot write an
away period at all — acceptable, and §11 already detects and surfaces skew.

**Scope, honestly.** Everyone who can write this document redeemed an invite the watched person's
device generated. The realistic adversary is a careless client or a disgruntled family member, not
a stranger, which is why §17 rates this Low. This is cheap hardening, not the closing of a hole —
but the cost is genuinely zero.

**Reversing** costs a rules edit and its tests. No migration; no stored data changes shape.

## Alternatives considered

**Leave §8 as "which is enough".** Rejected: it is not enough for the one thing §17 depends on.
The other rules bound a legitimate user's *choice*; these prevent a *lie*, which is a different
category.

**Cross-check `setByName` against `users/{uid}.displayName`.** Rejected — see Context. Defeated by
a rename the user is entitled to perform, and it costs a read.

**Route away writes through a callable Function**, which could stamp attribution server-side.
Rejected: §8 and §12 make away a direct client write *on purpose*, so a watcher can set it on a
plane and have it queue offline like any other write. A callable breaks that, and the offline
property is worth more than server-stamped attribution.

**Drop `setByName` and resolve the name on each device.** Rejected: links are `(watched, watcher)`
pairs, so a watcher has no path from a *peer* watcher's uid to their name — and §7 deliberately
keeps watchers from reading other users' documents. Denormalising the name is what makes the
message renderable offline, which is why the field exists.
