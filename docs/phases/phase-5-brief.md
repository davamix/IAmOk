# Phase 5 — Onboarding and pairing · brief

**Opened:** 2026-08-25, at the end of Phase 4.

**Deliverables** (PLAN.md) — the three onboarding screens with both Skip options, identical for every
user; invite creation and the `redeemInvite` callable; role routing from the two selections; the
summary screen.

**Exit criteria** — two phones pair from a **cold install** using only a shared code, and each lands
on the correct main screen.

---

## Prompt to start the session

> I'm starting **Phase 5 — onboarding and pairing** of the I Am Ok project. Read
> `docs/phases/phase-5-brief.md` first, then follow the reading order in `docs/README.md`.
> `docs/phases/phase-4-summary.md` is the previous phase and is where the backbone this builds on is
> described; `docs/OPEN-QUESTIONS.md` lists what is deliberately unsettled and **none of it blocks
> this phase** — check its *Blocking-when* table rather than re-deriving any of it.
>
> **Build and test against the local Firebase Emulator Suite.** A real Functions deploy is neither
> needed nor wanted for this phase — see *Emulator-first* below for the two reasons, one of which is
> that it would currently fail.
>
> **Where Phase 4 left things.** Steps 1–7 built and reviewed, two review rounds applied, 997 Dart
> tests, 30 Functions tests, `flutter analyze` clean, debug APK builds, secrets guard clean. Three of
> Phase 4's six device rows are still unticked and say why — they are end-to-end runs needing the AVD
> to tap, not defects. Phase 4 has **not been signed off**; that is the owner's call and does not
> block starting here.

---

## What already exists, and what emphatically does not

**Exists and is load-bearing:**

| | |
|---|---|
| `firestore.rules` | `invites/{code}` is `allow read, write: if false` — **unreadable by every client**, deployed, 73 rules tests. Redemption happens only inside the callable. |
| `LinkRepository` | Reads links for either role. Links are **written only by Cloud Functions**; the client never creates one. |
| `UserRepository` | `users/{uid}`, timezone, FCM token subcollection. |
| `AuthRepository` | Google Sign-In → Firebase uid. Driven from the debug harness today. |
| `Link` entity | Already carries `watchedName`, `watchedTimezone`, `watcherName`, `activeFrom`, `warningLocalTime`, `status` — every field `redeemInvite` has to denormalise. |
| `functions/` | `onCheckInCreated` fan-out, 30 tests, `pretest: tsc`. Not deployed. |
| Emulator tooling | `tools/emulators.ps1` (auth 9099, firestore 8080, functions 5001, UI 4000). |

**Does not exist yet — this phase writes it:**

- **`InviteService`** (Data). No file. §6 gives it: *create invite; call `redeemInvite`*.
- **`redeemInvite`** (callable Function). Not in `functions/src/`.
- **The three onboarding screens.** `screens.md` has purpose and routing decided, **copy partial**.
- **Role routing.** `main.dart` currently hardcodes `home: const TapScreen()` and reaches the
  watcher list **only** through a notification tap — `_pushWatcherList`. Both comments say *"Phase 5
  routes on role"*. That is this phase.

---

## The design decisions already made — do not re-litigate these

Every one is recorded with its reasoning; the file is named so you can go and read why.

- **Pairing is invite-code, watched-side originated** (ARCHITECTURE.md §2). The watched person's
  device generating and sharing the code **is the consent record**. One step, no approval
  round-trip.
- **Invites are unreadable by clients** (§8). A readable invite collection is an enumerable list of
  live codes. It also means the client never learns another user's uid from an invite.
- **`redeemInvite` is the only writer of `links/`** and does it in **one transaction**: validate code
  + expiry + not-consumed → create `links/{watched}_{watcher}` with `activeFrom` = today **in the
  watched person's timezone** → denormalise `watchedName`, `watchedTimezone`, `watcherName` → mark
  the invite consumed.
- **The link id is `{watchedUid}_{watcherUid}`**, so redeeming the same invite twice writes the same
  document (§7) — idempotent by construction rather than by a guard.
- **Both names are denormalised onto the link**, in both directions, so neither party ever reads the
  other's `users/{uid}`. `watcherName` exists because
  [ADR-0005](../architecture/decisions/0005-the-tap-screen-names-who-is-told.md) made the Tap screen
  name who is told, and §8 grants `users/{uid}` read to self only.
- **Code format: 6 characters, unambiguous alphabet, no `O`/`0`/`I`/`1`** (§7). It is read aloud over
  the phone by an elderly person.
- **Role is never asked directly.** It falls out of two questions about *other people* — *"are you
  the elderly one?"* is a question nobody wants to answer. Both selected ⇒ Tap + Away is the main
  screen with a top action button to the watcher list, because the person who taps daily should
  never have to navigate to reach their one action.
- **Deep links, when they come, are Android App Links** — not Firebase Dynamic Links, which shut
  down (§17).

**Undesigned and yours to design:** *"Realistically the family member sets up both phones in one
sitting; the pairing flow should assume that rather than assuming two people configuring
independently."* — `screens.md`. That sentence is the most important line in the onboarding section
and it has no screens behind it yet.

**Copy is partial and needs the owner's approval**, as every user-visible string in this project
does. `ui-ux/guidelines.md` and `screens.md` carry the rules; the elderly-first floors are not
negotiable.

---

## Emulator-first — and why a deploy is not on the path

**Do the whole phase against `tools/emulators.ps1`.** The Functions emulator hosts callables, so
`redeemInvite` can be written, tested and driven from two real devices without deploying anything.

Two reasons, and the first is not a preference:

1. **A 2nd-gen deploy would fail right now.** Verified read-only with `gcloud` on 2026-08-25: of the
   seven prerequisite APIs, **four are missing** — Cloud Build, Artifact Registry, Eventarc, Cloud
   Run. Enabling them is one command and a state change, so it is the owner's call.
2. **Blaze is ON** (`billingEnabled: true`, verified the same day). So enabling those APIs makes
   builds and stored images *billable* rather than blocked. Small at this scale, but there is no
   reason to spend it before the pairing flow works locally.

`docs/infrastructure/deploy-notes.md` carries both results, and the superseded claim that this
"cannot be checked from this machine" is kept beside them, because that claim is what made a
**state-changing dry run** look like the only way to find out.

**Emulator traps, all previously paid for:**

- **Only one emulator script may run at a time.** `emulators.ps1`, `rules-test.ps1` and
  `functions-test.ps1` all want 8080/9099/5001. The second fails with *"port taken"* and reads as a
  broken script.
- **Start it detached with output redirected to a file.** If the process owning the pipe is torn
  down, the CLI spins on `EPIPE`, the hub stops answering, and state cannot be exported.
- **`--project i-am-ok-c74ca`, never `demo-*`.** The app takes its project id from
  `google-services.json`, and the Firestore emulator loads `firestore.rules` into **only** the
  namespace it was started with. With a `demo-` id the app's writes were judged by permissive
  default rules — a false green that would have confirmed the write path and told us nothing about
  authorisation. The script's header has the measurement.
- **Both Firebase plugins rewrite `127.0.0.1` to `10.0.2.2` on Android** unless
  `automaticHostMapping: false`.
- **`adb reverse` dies with an adb *server* restart**, not just a cable unplug, and the failure reads
  as a broken script.
- **The local emulator sends REAL FCM** with nothing provisioned (recorded `81a725b`). Useful, and a
  trap if you assume otherwise.

---

## What is not a blocker

`docs/OPEN-QUESTIONS.md` is the register. Nothing in it blocks Phase 5 — check its *Blocking-when*
table rather than re-deriving any entry. Two are worth knowing about while building here:

- **Delete protection and PITR are both OFF**, and the trigger is *"before the first real user data
  lands"*. Pairing is the feature that starts producing real data, so this is the phase after which
  that deadline stops being theoretical.
- **App Check enforcement** is structurally gated on the app reaching an internal test track, and
  before it is ever enforced the refusal-to-copy mapping must be verified against a real rejection.
  Nothing to do here, but pairing is the first flow a real user would hit.

**Carried from Phase 4, unticked and honest:** three device rows — the AVD has never tapped, so the
end-to-end criterion was never met on the terms it is written in; forced deep Doze was unreachable on
HyperOS; and the overnight-Doze run was never done. Phase 5's own exit criterion needs two phones
anyway, so the AVD finally tapping is work this phase wants regardless.

---

## The device rig, as Phase 4 left it

**POCO F3** (`1720f883`) — one accepted link (self-linked, `warningLocalTime` 10:00), 7 warning
alarms armed at 10:00 matching the store exactly, empty tray, TalkBack off, accessibility services
restored, battery and `deviceidle` reset. **One thing not restored:** `secure screensaver_enabled`
was set to `0` while trying to force Doze and its original value was never captured.

**`Medium_Phone_API_36.0` AVD** — Android 16, current debug APK installed, TalkBack **off**,
accessibility services cleared, store at **schema v5**, holding two seeded fake watched people (*Mum*,
*Granddad*) with today's check-in on the watched side. It is a scratch rig; *Wipe store* in the
harness resets it. **This is the phone that has to tap** for both Phase 4's outstanding row and Phase
5's exit criterion.

**HyperOS behaviours measured on the POCO**, all in `device-matrix.md`: `deviceidle force-idle` will
not reach deep idle from a screen-off device; `am kill` does not reliably kill this app, so check
`pidof` and never substitute `am force-stop` while alarms matter; and **deleting** a link from
Firestore strands its warning alarms while **revoking** it tears them down the way §10 step 1 says.

**Driving the app from adb**, learned in Phase 4 and reusable here:

- A Flutter app exposes **no accessibility tree** to `uiautomator dump` until an accessibility
  service is running — with TalkBack off you must navigate by screenshot and raw coordinates.
- A notification tap replicates exactly as
  `am start -n io.github.davamix.i_am_ok/.MainActivity -a SELECT_NOTIFICATION --es payload <linkId>`.
- **`am force-stop` cancels every notification the app has posted**, which silently removes the thing
  a notification measurement is about.
- Pull the app's database with `adb exec-out run-as … cat`, never a shell redirect — the redirect
  writes a **zero-byte** file and `adb pull` still reports success.

---

## How this phase is expected to go wrong

Read `phase-4-summary.md`'s closing section in full; the short version is the part that has caught
something every single round:

**Read a claim against the thing it describes.** Across four review rounds, almost nothing came from
a test failing. Findings came from a docstring, a checklist, a copy table, a threat model, a handover
and finally the design document itself, each asserting something that had quietly stopped being true.
This phase adds a new surface for that — onboarding copy that `screens.md` marks *partial*, which is
the most likely place for the app to say something nobody approved.

**Verify the measurement before you trust the result.** Three times in Phase 4 the subject was fine
and the measurement was wrong. Phase 4's own mutation harness reported five green results that were
an encoding crash, caught only because a no-op control was added and had to pass.

**Mutate the code to see the test fail, and mutate in both directions.** The last defect of Phase 4
was a guard mutated to `false` and never to `true`.

**A false claim to a family is the worst bug this app can have.** Pairing is where a wrong link, a
reused code, or a name attached to the wrong person becomes exactly that. Prefer stopping to ask over
guessing, and if you think a finding is wrong, say so before acting on it rather than after.
