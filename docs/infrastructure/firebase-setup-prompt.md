# Firebase setup prompt for Gemini in Firebase

## Status as of 2026-08-15

| Task | State | By |
|---|---|---|
| 1 — Android app registered | **Done** · App ID `1:744276314021:android:304a9d901675e9ee748a4c` | Firebase CLI |
| 1 — Debug SHA-1 + SHA-256 | **Done** · both verified via `apps:android:sha:list` | Firebase CLI |
| 1 — `google-services.json` | **Done** · 1327 bytes, both OAuth clients present | Firebase CLI |
| 2 — Firestore | **Done** · `europe-west1`, `FIRESTORE_NATIVE` · created 2026-08-15T15:32:35Z · **CLI-verified via `databases:get`** | Console |
| 3 — Google auth provider | **Done** · verified via OAuth clients appearing in config | Console |
| 4 — Blaze + Functions APIs | Not done | — |
| 5 — FCM v1 confirm | Not done | — |
| 6 — App Check monitoring | Not done | — |
| 7 — Confirm Analytics / RTDB / Storage off | Not done | — |

### OAuth clients

| Type | Client ID |
|---|---|
| Android (`client_type: 1`) | `744276314021-kaiueh7ekk6l556kmoverlsk6d8u8d4e.apps.googleusercontent.com` |
| **Web** (`client_type: 3`) | `744276314021-uour1dugadnlu0kf4atdmgs9bv00sd6n.apps.googleusercontent.com` |

The **Web** client ID is the one `google_sign_in` needs as `serverClientId` on Android to return an
ID token Firebase will accept. Using the Android client ID there produces a silent failure with no
useful error. Neither is a secret — both ship inside the APK.

## Two CLI traps, both hit during setup

**`--out` is unreliable on Windows.** `firebase apps:sdkconfig ... --out <path>` crashed before
writing and silently left the *previous* file in place — which looked like "the OAuth clients never
appeared" when they had. Capture stdout, validate, then write:

```powershell
$out  = firebase apps:sdkconfig ANDROID <appId> --project i-am-ok-c74ca 2>$null
$json = ($out -join "`n").Substring((($out -join "`n")).IndexOf('{'))
# assert oauth_client count >= 1 BEFORE overwriting, then write
```

**Exit code 9 is not failure.** Firebase CLI commands on Windows print `√ success` and then crash
with `Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), src\win\async.c`. The work has already
completed. Verify with a `:list` or by reading the file — never by the exit code.

This said "every `apps:*` command" until 2026-08-19, when the Phase 3 gate measured it and found both
halves wrong: the crash is **intermittent** — `apps:list` crashed, exited 0, then crashed again in
one shell session — and **not confined to `apps:*`**, since `projects:list` crashes as well. The
practical rule is unchanged and now applies to every Firebase command: read the output, never the
exit code.

**OAuth clients take a minute or two to propagate** after enabling the Google provider. An empty
`oauth_client: []` immediately after saving is expected, not a misconfiguration.

---

Paste the block below into Gemini in the Firebase console for project `i-am-ok-c74ca`.

Values in it were verified on 2026-08-15 from this machine:

| Value | Source |
|---|---|
| Project ID `i-am-ok-c74ca`, number `744276314021` | `firebase projects:list` |
| No apps registered yet | `firebase apps:list` — "No apps found" |
| Firestore not created | `firestore:databases:list` returned API-disabled |
| Debug SHA-1 / SHA-256 | `keytool` on `~/.android/debug.keystore` — **not on `PATH`**, see below |

> **The Resource Location clause was dropped from the first row on 2026-08-19.** It read
> *"Resource Location `[Not specified]`"* as evidence Firestore did not exist yet. Re-running
> `firebase projects:list` at the Phase 3 gate — with Firestore live in `europe-west1` — shows that
> column **still reads `[Not specified]`**. It is the GCP default resource location (App Engine and
> the default bucket), not Firestore's, so it never changed and could not have distinguished either
> state. This document's standing rests on "verified from the CLI", and that row was not.

> **`keytool` is not on `PATH` on this machine**, and neither are `java` or `adb` — confirmed again
> at the Phase 3 gate. It lives in the Android Studio JBR. This matters at **Phase 8**, when the same
> command has to read the *release* fingerprints for Firebase registration:
>
> ```powershell
> & "D:\Android\Android Studio\jbr\bin\keytool.exe" -list -v -alias androiddebugkey `
>   -keystore ~/.android/debug.keystore -storepass android -keypass android
> ```
>
> The `~` is fine — PowerShell 7 expands it.

**Two things to verify yourself rather than trust the assistant with:** Firestore must be
**Native mode**, and its location must be **europe-west1**. Both are permanent — a wrong choice
means a new project and a full migration.

---

## The prompt

```text
I am setting up the Firebase backend for an Android-only Flutter app called "I Am Ok".

WHAT THE APP DOES
An elderly person taps a button once a day. That check-in is relayed as a quiet notification to
family contacts who have the app. If a day passes with no tap, each contact's phone raises a
warning locally. There is also an "away" mode (holiday, hospital stay) that suspends both sides
for a bounded period. Data stored is minimal: a display name, a daily timestamp, an away period,
and the links between people.

PROJECT
- Project ID: i-am-ok-c74ca
- Project number: 744276314021
- Currently: no apps registered, Firestore not created, no APIs enabled beyond defaults

Please walk me through each task below in order. For anything you cannot perform directly, give
me the exact console navigation path and the exact values to enter. At the end, report what was
done, what was skipped, and anything that failed.

TASK 1 — Register the Android app
- Android package name: io.github.davamix.i_am_ok
- App nickname: I Am Ok (Android)
- Debug SHA-1:   91:62:BA:92:47:16:22:F8:35:3C:49:E1:03:BD:2A:18:84:49:0F:F4
- Debug SHA-256: 02:E2:50:2A:9C:7E:09:FB:37:28:74:21:EF:81:C9:85:E2:2F:C4:DA:24:64:F3:41:FC:12:E8:8D:3F:1D:68:46
Both fingerprints are required for Google Sign-In to work on debug builds. I will add release
fingerprints separately later. Then give me the google-services.json download link.

TASK 2 — Create Firestore  [IRREVERSIBLE — please confirm the settings back to me before I click]
- Mode: NATIVE mode. Not Datastore mode.
- Database ID: (default)
- Location: europe-west1
- Rules: start in PRODUCTION mode (locked down). Do not use test mode.
I am in Spain and need EU data residency for GDPR, and my Cloud Functions will be in
europe-west1, so Firestore must be co-located there. Please confirm that the location and the
mode cannot be changed after creation, and restate both back to me before I proceed.

TASK 3 — Authentication
- Enable the Google sign-in provider ONLY.
- Set the project support email to davamix@gmail.com.
- Do not enable Email/Password, Phone, Anonymous, or any other provider.

TASK 4 — Cloud Functions (2nd gen)
- Confirm the Blaze plan is active, and tell me the current spend and free-tier allowances.
- Default region: europe-west1
- Runtime: Node.js 22
- Enable every API a 2nd-gen Firestore-triggered function needs to deploy: Cloud Functions,
  Cloud Build, Artifact Registry, Eventarc, Cloud Run, Pub/Sub, and Cloud Storage for build
  artifacts. List each one and its status.
I will deploy two triggers from my repo: one on document creation under
checkins/{uid}/days/{date}, and one on writes to users/{uid}/shared/away. Both fan out
data-only FCM messages to linked devices.

TASK 5 — Cloud Messaging
- Confirm the FCM v1 API is enabled.
- Confirm the legacy FCM server key is NOT in use and not needed.
My functions will send data-only, high-priority messages via the Admin SDK.

TASK 6 — App Check
- Register the Android app with the Play Integrity provider.
- Set enforcement to MONITORING ONLY for Firestore, Functions, and Authentication.
  Do NOT enforce yet — enforcing before the app is instrumented would lock out my own client.
- Tell me where to see the monitoring metrics so I can confirm real traffic is attested before
  I turn enforcement on later.

TASK 7 — Things to deliberately NOT enable
Please confirm each of these is off, and do not turn any of them on:
- Google Analytics for Firebase  (data minimization — this app handles data about vulnerable
  people and I want to store the minimum)
- Realtime Database  (not used — Firestore only)
- Cloud Storage for Firebase  (not used — no files)
- Any additional auth providers
If Analytics is already enabled at project level, tell me and explain how to disable or ignore
it without breaking anything else.

TASK 8 — Do not touch security rules
I deploy firestore.rules from my git repository with the Firebase CLI. Please leave the rules
locked and do not generate, edit, or publish any rules in the console — that would be
overwritten and would cause confusing drift.

TASK 9 — Optional, tell me the trade-off
Would you recommend Firebase Hosting for this project purely to serve two static files: a
privacy policy page required for Play submission, and an assetlinks.json for Android App Links?
The alternative is GitHub Pages. Tell me the cost, and whether enabling Hosting has any effect
on the rest of the project.

FINAL — Summarise back to me:
1. The exact Firestore location and mode that were created
2. Every API now enabled
3. App Check enforcement state for each service
4. Anything you could not do that I must do manually
```

---

## After Gemini finishes

1. Put the downloaded `google-services.json` at `android/app/google-services.json`.
2. Verify the location independently — do not rely on the summary:
   ```powershell
   firebase firestore:databases:get "(default)" --project i-am-ok-c74ca
   ```
   The output must show `Location │ europe-west1` and `Type │ FIRESTORE_NATIVE`.

   > **Use `:get`, not `:list`.** `firestore:databases:list` prints only Database Name, Edition and
   > Type — **no location column at all**, so it cannot verify the one setting that is permanent
   > and most worth checking. This runbook said `:list` until 2026-08-15, when running it against
   > the real project showed the location was simply absent from the output. Asserting on content
   > rather than trusting the command is what caught it.
3. Confirm the Android app registered:
   ```powershell
   firebase apps:list --project i-am-ok-c74ca
   ```
