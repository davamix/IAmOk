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
2. **App Check** with Play Integrity — *once enforcement is enabled*, it will prove requests come
   from the real app on a real device, so a stranger with the extracted API key gets nothing.

   **Today it protects nothing, and the tense above used to hide that.** Phase 4 step 6 ships the
   client, so the app now *sends* attestation tokens — but in **monitoring mode**, which blocks no
   request at all. Enforcing before clients were attesting would refuse every read, which ADR-0004
   maps to *refused*, which is the access-lost notice arriving at every family at once. So: rules
   are the whole defence until enforcement is turned on, and this list has exactly one live entry.

### The scanner will flag the API key. That is expected.

GitHub secret scanning raised `google_api_key` against `android/app/google-services.json` line 31
on **2026-09-02** — alert #1, resolved **won't fix**. The reasoning is the table row above, and it
will be the same reasoning the next time. Two things not to do in response to one of these:

- **Do not rotate the key.** The replacement ships in the next APK and is public the moment anyone
  installs it. §5's *rotate first, clean second* applies to the items in §1; this is the documented
  exception to it.
- **Do not rewrite history** to strip the file. It is committed on purpose, the key is extractable
  from any build anyway, and a fresh clone stops building without it.

**What is worth checking when an alert fires is not the key but what the key may do.** Verified
2026-09-02 with `gcloud services api-keys list` and the Identity Toolkit admin config:

| | State on 2026-09-02 |
|---|---|
| Application restriction | `androidKeyRestrictions` present, `allowedApplications` **empty** — no package + SHA-1 pair registered |
| API targets | **27 services**, including `identitytoolkit.googleapis.com` |
| Enabled Auth providers | **Google federated only** — password, email link, anonymous and phone all off |
| Live Firestore ruleset | `87c8784d…`, deployed 2026-08-20; catch-alls are `allow read, write: if false` |

The first two rows are what an abusable key looks like, and on their own they would be a finding.
**The third row is what closes it.** An unrestricted key that reaches Identity Toolkit is the
ordinary way a project acquires thousands of junk accounts — but with Google as the only provider
there is nothing to mint: a caller needs a Google ID token and can only obtain one for their own
identity. They then arrive as an ordinary authenticated stranger, which is the *curious stranger
with the APK* row of [threat-model.md](threat-model.md) and exactly what the rules already assume.

**So the exposure is bounded by the provider list, not by the key.** If a password or anonymous
provider is ever enabled, that stops being true on the day it is enabled, and the two items below
stop being optional.

### Owed at Phase 8, when the release keystore exists

Neither is a control, and neither replaces App Check enforcement
([OPEN-QUESTIONS.md](../OPEN-QUESTIONS.md) #5). Both are worth doing because they are nearly free.

1. **Register the application restriction** — the package name plus the *release* SHA-1 — on the
   Android key. Worth being honest about what it buys: the signing certificate's SHA-1 is
   extractable from any APK and the `X-Android-Package` / `X-Android-Cert` headers are supplied by
   the caller, so this stops copy-paste reuse of the key and nothing more determined than that.
   **This is a different task from registering release fingerprints in Firebase**, which
   [PLAN.md](../PLAN.md) already owes at Phase 8 so that Google Sign-In works on a release build.
   Same fingerprint, two separate registrations, and doing one does not do the other.
2. **Narrow the 27 API targets** to the services this app actually calls. The list is Firebase's
   default blanket and includes `sqladmin.googleapis.com`, which this project will never reach for.
   The value is not today: it is that enabling any billable Google API on the project later would
   otherwise be reachable with a key that has been public since the repo went up.

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
