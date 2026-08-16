# Threat model

**Date:** 2026-08-15 · **Status:** Current · Derived from
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §2, §8, §12, §17.

## Scope, and the thing that makes this model unusual

This app stores very little: a display name, an email behind Google Sign-In, one timestamp per
person per day, an away period, and the links between people. There is no message content, no
location, no health data, no payment data.

But the *inference* from that little is sensitive. `checkins/{uid}/days/` is a machine-readable
record of which days an identifiable elderly person living alone was and was not verified as
fine — and an away period is a statement that a specific home is empty between two dates. The data
is small; the consequences of it leaking to the wrong person are not.

Two consequences shape everything below:

- **Confidentiality of *who watches whom* matters as much as the check-ins themselves.** The link
  graph is the map of who is vulnerable and who is watching.
- **Integrity beats availability.** A missing warning is a nuisance the family notices. A *false*
  warning — telling a family their mother did not check in when she did — is the worst thing this
  app can do, and repeated false alarms train people to ignore the one that is real. That is a
  safety property enforced by [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §10, not by the
  security rules, but it belongs in the same threat inventory.

Out of scope by the owner's decision, and not re-opened here: the phone being off, the battery
being dead, the app being force-stopped, and detecting that the person is incapacitated. See
*Explicit non-goals* in [HANDOVER.md](../HANDOVER.md).

---

## Assets

| Asset | Sensitivity | Where it lives |
|---|---|---|
| The link graph — who watches whom | **High.** Identifies vulnerable people and their family. | `links/{watchedUid}_{watcherUid}` |
| Check-in history per person per day | **High** by inference. A pattern of presence and absence. | `checkins/{uid}/days/{date}` |
| Away periods | **High** by inference. "This home is empty from X to Y." | `users/{uid}/shared/away` |
| Display name + email | Medium. PII from Google Sign-In, minimal by design. | `users/{uid}`, Firebase Auth |
| FCM tokens | Medium. A token is a channel to push to a specific device. | `users/{uid}/tokens/{token}` |
| Invite codes | Medium, short-lived. A live code grants a link to a watched person. | `invites/{CODE}` |
| Release signing key | **Critical.** Signs updates to every install. | `.local/` — never the repo |
| Admin service-account credentials | **Critical.** Bypasses all rules. | `.local/` — never the repo |

---

## Adversaries

| Adversary | Capability | Wants | Primary control |
|---|---|---|---|
| **Curious stranger with the APK** | Can extract the API key, project id, and OAuth client ids from any release build. Can authenticate as *themselves*. | Read anyone's check-ins; enumerate users | Security rules — every read is scoped to the caller's uid or an accepted link. The API key authorises nothing on its own. |
| **Scripted attacker** | Automated requests against the project's endpoints with the extracted key | Bulk-read, enumerate invite codes, exhaust quota | Rules, and `invites/` unreadable by any client. **App Check is not yet a control** — it is provisioned in Phase 4 in monitoring mode only, and blocks nothing until enforcement is enabled later. Until then the rules are the whole defence. |
| **A legitimate but hostile watcher** | A real account with an accepted link | Surveil beyond what the watched person consented to; silence the family | Accepted here, largely. See "the insider problem" below. |
| **Someone who guesses an invite code** | Can call `redeemInvite` | Attach themselves to a stranger as a watcher | 6 chars from an unambiguous alphabet, single-use, expiring, and server-validated. See "invite codes" below. |
| **Someone with physical access to an unlocked phone** | Everything the owner has | Read the app; set away | Out of scope. Device lock is the control; the app adds nothing on top. |
| **A malicious app on the same device** | Local IPC surface | Read the local SQLite cache; spoof a broadcast | Android app sandbox. Do not export receivers or activities beyond what is required. |
| **Google / Firebase as an operator** | Full access to stored data | — | Accepted. EU data residency (`europe-west1`) and data minimisation are the mitigations available. |

---

## Trust boundaries

1. **Client ↔ Firestore.** The client is fully untrusted — it runs on a device the user controls
   and its code can be read. Every authorisation decision is a security rule, never a client-side
   check. A client-side check is a UX affordance, not a control.
2. **Client ↔ Cloud Functions.** `redeemInvite` exists precisely *because* the client cannot be
   trusted to enforce single-use, expiry, or to be prevented from reading another user's uid out of
   an invite document.
3. **Functions ↔ Firestore.** Functions run with admin credentials and bypass rules entirely. Every
   Function must therefore re-validate its own inputs — the rules are not a safety net there.
4. **The device's own storage boundary.** The local SQLite cache is a decision cache, never an
   authorisation record. A watcher's phone deciding "no warning needed" from its cache is a
   correctness decision, not a security one.

---

## Threats and controls

### T1 — Reading someone else's check-ins

An authenticated stranger reads `checkins/{someoneElse}/days/*`.

**Control.** Rules allow the read only for the owner, or where an `accepted` link exists for
`(watchedUid, request.auth.uid)`. This costs one `get()` per rule evaluation and is accepted
deliberately: without it the watcher would have to depend on FCM for correctness, which
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §3 refuses.

### T2 — Enumerating users or links

**Control.** No collection is queryable without a uid constraint. `links/{id}` uses the
deterministic id `{watchedUid}_{watcherUid}`, and reads are allowed only when the caller is one of
the two parties. There is no path that lists users.

### T3 — Invite code brute force

**Control, and its honest limit.** Codes are 6 characters from an alphabet with `O/0/I/1` removed
(~32 usable characters → on the order of 10⁹ codes), single-use, time-limited, and `invites/` is
**unreadable by every client** — a readable invite collection is an enumerable list of live codes.
Redemption goes through the `redeemInvite` callable, which is the only place a code is checked.

The residual risk is online guessing against that callable. At family scale with short expiry the
odds are negligible, but the callable should rate-limit per caller and per code, and App Check
raises the cost of automating it. **Worth revisiting in Phase 5 when the callable is actually
written** — the number of *live* codes at any moment is what matters, not the size of the keyspace.

### T4 — Pushing a forged notification to a watcher

**Control.** Only the Functions' service account can send FCM. It never ships in the APK — this is
the entire reason Cloud Functions is not optional in this design. Separately, every push is
data-only and carries **no authority**: it is a "something changed, reconcile now" nudge. A device
that somehow received a forged nudge would re-derive the truth from Firestore and display nothing
false.

### T5 — A false warning ("she didn't check in" when she did)

Not a confidentiality threat, and the highest-severity failure in the system.

**Control.** The watcher's warning comes from a logic-bearing alarm that verifies before it speaks:
cache, then away period, then a live Firestore read, and an explicitly *different* message when the
device is offline and cannot support the claim. Plus the late-arrival correction path.
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §10.

### T6 — Silencing the family with away mode

Anyone in the group can set away for a watched person, with no approval. This is a deliberate
design decision, not an oversight — requiring approval would break the feature in its main use
case, when someone is in hospital and least able to answer a prompt.

**Controls, all visibility rather than prevention:** `setByName` is denormalized onto the away
document so every surface can say *who* set it; anyone can cancel; a 31-day cap forces deliberate
renewal; and an "ends tomorrow" notice goes to all watchers, scheduled locally from `through` so it
needs no server. The residual risk is accepted and recorded in
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §17.

### T7 — Stale FCM tokens leaking pushes to a reassigned device

**Control.** Tokens live in a subcollection with `updatedAt`, so the Function prunes by age and
deletes any token that returns `UNREGISTERED`.

### T8 — Credential exposure through the repo

**Control.** [secrets-policy.md](secrets-policy.md), the `.gitignore` secrets block, and
`tools/check-secrets-ignored.ps1`.

### T9 — Data subject rights (GDPR)

Owner is in Spain; data is in `europe-west1`; the subjects include vulnerable people. Deletion is
the sharp edge — deleting a user must also deal with their check-in history, their away document,
and the links naming them, which are documents the *other* party can also read.

**Not yet designed.** Phase 8 owns the privacy policy; the deletion path needs a decision before
Play submission. Flagged, not solved.

---

## Deliberately accepted

| Accepted | Why |
|---|---|
| A watcher sees every check-in day for the person they watch | That is the product. Consent is the invite the watched person's device generated and shared. |
| Any group member can set away for anyone else | See T6. Legibility over prevention. |
| Google holds the auth identity and the data | Accepted trade for an identity that survives reinstall so links never break. |
| The API key is public | It authorises nothing. Rules plus App Check are the control. |
| The rules are public | They are reviewable because they are public. |

## Open, and owed a decision

- **T3 residual** — rate limiting on `redeemInvite`. Phase 5.
- **T9** — the account-deletion path and what happens to links and history. Before Phase 8.
- **App Check enforcement** — turning it from monitoring to enforcing, and how to verify real
  traffic is attested first. Phase 4 provisions it; enabling enforcement is a later, separate step.
