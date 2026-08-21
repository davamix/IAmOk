# Secrets policy

**Date:** 2026-08-15 · **Status:** Current · Applies to every phase.

The repo is **public**. That is the constraint everything here follows from.

Being vague about this is worse than being wrong about it. A policy that says "keep credentials
safe" produces a `docs-private/` folder full of things that ship inside the APK anyway, and a
comfortable feeling that is not backed by anything. So the two lists below are exhaustive and
specific, and the reasoning for each entry is stated.

---

## 1. Genuinely secret — never in the repo, in any form

| Item | Where it lives | Why |
|---|---|---|
| Release upload keystore (`*.jks`, `*.keystore`) | `.local/`, plus an off-machine backup | Whoever holds it can sign an update to the app. Losing it is worse — with Play App Signing an upload key is recoverable; without it, the app can never be updated again. |
| Keystore + key passwords, `android/key.properties` | Password manager. `key.properties` is generated locally and git-ignored. | Same. |
| Firebase Admin SDK service-account JSON | `.local/`, downloaded only when a task needs it | Server-side credential. It bypasses security rules entirely — full read/write on Firestore and the ability to send FCM to any device. |
| Google Play publishing service-account JSON | `.local/` | Can publish releases as the owner. |
| Any `.env` file, any personal access token | `.local/` or the environment | — |
| **App Check debug secret** (the UUID `DebugAppCheckProvider` prints to logcat) | Nowhere. Read it from logcat when needed, paste it into the console, and let it go. | Once registered it makes one install **attest unconditionally** — it is an allow-list entry that bypasses Play Integrity, so committing one would hand anybody who reads the repo a way past App Check the moment enforcement is turned on. It is regenerated whenever app data is cleared, so there is nothing worth keeping. |

`.local/` is the private, never-committed working area for this repo. It is git-ignored as a whole
directory. Nothing inside it is ever referenced by a committed path.

## 2. Not secret, despite intuition

These are in the repo on purpose. Filing them under "private docs" buys nothing and creates false
confidence.

| Item | Why it is not a secret |
|---|---|
| Firebase project id `i-am-ok-c74ca` and project number `744276314021` | Both are embedded in `google-services.json`, which ships inside the APK. |
| The API key in `android/app/google-services.json` | Ships inside the APK. Anyone can unzip a release and read it. It identifies the project to Google's endpoints; it authorises nothing on its own. |
| The Android and Web OAuth client ids | Same — both are in the APK, and the Web client id is only meaningful together with a Google account sign-in. |
| `firestore.rules` | Publishing the rules is how the design gets reviewed. A rule set that is only safe while unread is not safe. |
| Debug SHA-1 / SHA-256 fingerprints | Derived from the debug keystore Android ships to every developer. |

**`android/app/google-services.json` is committed deliberately.** Do not add a `.gitignore` rule
for it and do not "fix" it in a later cleanup pass. Without it in the repo the project does not
build from a fresh clone, and removing it protects nothing.

### What actually protects the backend

Not the secrecy of the key. Two things:

1. **Firestore security rules** — see [firestore-rules-guidelines.md](firestore-rules-guidelines.md).
   Every read is scoped to the caller's uid or to an accepted link.
2. **App Check** with Play Integrity — proves requests come from the real app on a real device, so a
   stranger with the extracted API key gets nothing. Proposed in Phase 4, **monitoring mode only**
   at first: enforcing before the client sends tokens would lock the app out of its own backend.

---

## 3. The incident this policy was written after

**2026-08-15 — a Firebase Admin SDK service-account JSON was downloaded into `.credentials/` in
the working tree.**

What went right: the folder was git-ignored at the time, `git log --all` confirmed the file was
never committed, and the keys have since been regenerated, which invalidates the downloaded copy
regardless. **The incident is closed.**

What went wrong afterwards, and is the actual lesson: when the folder was deleted, the `.gitignore`
entry that guarded it went with it. The guard disappeared along with the thing it was guarding —
so the repo spent time with no protection at all against the *next* download landing in the same
place. Restoring that entry was a Phase 0 task.

> **A `.gitignore` line protects the next file, not the one you just deleted. Never remove one
> because the thing it guarded is gone.**

---

## 4. The guard, and how to check it

`.gitignore` carries a `# Secrets` block. It ignores `.local/`, `.credentials/`, keystores and
signing material, service-account and OAuth-client JSON name patterns, `.runtimeconfig.json`,
emulator export directories, and `.env` files — and it deliberately contains nothing that would
match `android/app/google-services.json`.

Verify both halves at once:

```powershell
pwsh -File tools/check-secrets-ignored.ps1
```

It asserts that every must-never-be-committed path is ignored, **and** that
`android/app/google-services.json` is still both trackable and tracked. Run it after any
`.gitignore` edit. Adding a pattern to `.gitignore` means adding a sample path to the script too —
a rule with no assertion is a rule nobody notices losing.

> **One git subtlety the script exists to handle.** `git check-ignore` consults the **index** by
> default and reports any *tracked* file as "not ignored", whatever the rules say. So the naive
> check on `google-services.json` passes green even with `*.json` in `.gitignore` — it is tracked,
> so it always answers "not ignored". The script uses `--no-index` for that half, which asks the
> question actually being asked: *would the rules match this path?* The first half keeps the
> index-aware form on purpose, so a secret that has already been committed reports as not-ignored
> and fails the run loudly.

Manual spot checks for a single path:

```powershell
git check-ignore -v .credentials/serviceAccount.json              # exit 0 = ignored
git check-ignore -v --no-index android/app/google-services.json   # exit 1 = no rule matches. Correct.
```

## 5. If a credential does get committed

Rotate first, clean second. History rewriting is the slow, optional part; the leaked key is live
from the moment it is pushed.

1. **Revoke and regenerate the credential** in the Firebase or Google Cloud console. This is the
   only step that actually fixes anything.
2. Confirm the blast radius: `git log --all -- <path>` and `git log -S '<a distinctive string>' --all`.
3. If it was pushed, treat it as public forever — GitHub caches, forks, and clones are outside your
   reach. Rewriting history does not un-publish it.
4. Only then consider `git filter-repo` to remove it from history, and force-push after telling
   anyone with a clone.
5. Add the path pattern to `.gitignore` **and** to `tools/check-secrets-ignored.ps1`, so the next
   run of the check would have caught it.
