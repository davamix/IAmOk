---
name: security-guidelines
description: Secrets handling and Firestore security rules for the I Am Ok app. Load before editing .gitignore, adding any file that could hold a credential, writing or changing firestore.rules, writing a Cloud Function, or deciding whether something belongs in the public repo.
---

# Security guidelines

Sources: `docs/security/secrets-policy.md`, `docs/security/threat-model.md`,
`docs/security/firestore-rules-guidelines.md`. **The repo is public.** Everything follows from that.

## Secrets — the two lists, and they are exhaustive

**Genuinely secret. Never in the repo, in any form.** Release keystore (`*.jks`, `*.keystore`) and
its passwords · `android/key.properties` · any Firebase Admin SDK service-account JSON · any Play
publishing service account · `.env` files and tokens.

They live in **`.local/`** — git-ignored as a whole directory — and passwords live in a password
manager.

**Not secret, despite intuition. In the repo on purpose.** Firebase project id `i-am-ok-c74ca` and
project number · the API key in `android/app/google-services.json` · the Android and Web OAuth
client ids · `firestore.rules` · debug SHA fingerprints.

All of these ship inside the APK, where anyone can unzip and read them. Treating an extractable key
as a secret buys nothing and creates false confidence. The real controls are **security rules plus
App Check**.

### Three rules that follow

1. **Never add a `.gitignore` rule that would match `android/app/google-services.json`**, and never
   add a broad `*.json` rule. Without that file the project does not build from a fresh clone, and
   removing it protects nothing.
2. **A `.gitignore` line protects the next file, not the one you just deleted.** Never remove an
   entry because the thing it guarded is gone. That exact mistake happened on 2026-08-15.
3. After any `.gitignore` change, run `pwsh -File tools/check-secrets-ignored.ps1`. It asserts both
   directions — secrets ignored, and `google-services.json` still trackable *and* tracked. New
   secret patterns get added to the script as well as to `.gitignore`; a rule with no assertion is
   a rule nobody notices losing. Note `git check-ignore` consults the index by default and reports
   any tracked file as "not ignored", so the trackable half must use `--no-index` or it proves
   nothing.

### If a credential is ever committed

**Rotate first, clean second.** Revoke and regenerate in the console — that is the only step that
actually fixes anything. If it was pushed, treat it as public forever: caches, forks, and clones
are outside your reach, and rewriting history does not un-publish it.

## Security rules

The rules are the **only** real authorisation boundary. The client is untrusted by definition — it
runs on hardware the user controls and its code can be read out of the APK. A check that lives only
in Dart is a UX affordance, not a control.

The access matrix in `docs/security/firestore-rules-guidelines.md` is the specification. If the
rules and that table disagree, one of them is a bug.

**Load-bearing, do not soften:**

- **`invites/` is unreadable by every client.** Not "readable by the creator" — unreadable. A
  readable invite collection is an enumerable list of live codes.
- **Links are Function-written**, except that either party may set `status: "revoked"` and nothing
  else. Creation goes through `redeemInvite` so single-use and expiry are enforced server-side.
- **Away is a direct client write**, on purpose, so it queues offline like any other write.
  Validation therefore lives in the rules. From ARCHITECTURE.md §8 as amended by ADR-0001:
  `through >= from` and `through <= request.time + 30d` on every write (**against `request.time`,
  not `from`** — they differ the moment future-dated away is exposed); `from >= today`
  **on create only**, with `from` immutable on update. That split is load-bearing: cancelling an
  away truncates `through` on a document whose `from` is already in the past, so a blanket
  `from >= today` would reject the very write that stops a cancellation retroactively un-covering
  elapsed away days.
- **Away attribution** (ADR-0003, now in §8): `setBy == request.auth.uid` on create *and* update;
  `setByName` present, string, 1–100; `setAt`/`updatedAt == request.time`. All free — no extra
  reads. `setBy`/`setByName` are **mutable** on update, unlike `from`, because §12 is
  last-write-wins and extending someone else's period must re-attribute it.
  **Never cross-check `setByName` against `users/{uid}.displayName`** — users can rename
  themselves at will, so it proves nothing and costs a `get()`. `setBy` is the identity;
  `setByName` is a label. Do not let any surface imply the name is authenticated.
- The `get()` on `checkins` reads is **accepted cost**, not something to optimise away. Removing it
  would force the watcher to trust FCM for correctness, which the design refuses.

**When writing rules:**

- Validate the **shape** of every write, not just the writer's identity — field set, types, and
  immutability of `watchedUid`, `watcherUid`, `activeFrom`.
- Never authorise on a client-supplied timestamp. `deviceTappedAt` is displayed data;
  `request.time` is the trusted one.
- Factor the repeated `get()` into `hasAcceptedLink(watchedUid)`. It appears three times, and
  duplicating it is how the three drift.
- Deny by default, end with a catch-all deny, and grant narrowly.
- Test the **denied** case for every matrix row. A test that only asserts the happy path proves
  nothing. Emulator suite only, never the live project.

## Cloud Functions

Functions run with admin credentials and **bypass the rules entirely**. Every Function re-validates
its own inputs — the rules are not a safety net there. `redeemInvite` exists precisely because the
client cannot be trusted to enforce single-use, expiry, or to be prevented from reading another
user's uid out of an invite.

## When designing anything new

Two properties of this app that are easy to forget:

- **The inference is more sensitive than the data.** A check-in history is a record of which days an
  identifiable elderly person living alone was verified fine; an away period says a specific home is
  empty between two dates. The link graph is the map of who is vulnerable and who is watching.
- **Integrity beats availability.** A missing warning is a nuisance. A *false* warning is the worst
  thing this app can do, and repeated false alarms train a family to ignore the real one.

Anything touching account deletion is currently **undecided** — deleting a user leaves check-ins,
an away document, and links the other party can read. See threat-model.md T9. Do not invent an
answer in code; raise it.
