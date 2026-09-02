# I Am Ok — Implementation Plan

**Date:** 2026-08-15 · **Status:** Approved and in progress. **Phases 0, 1 and 2 complete** — Phase 2
reviewed and verified on real hardware — see
[phases/phase-0-summary.md](phases/phase-0-summary.md),
[phases/phase-1-summary.md](phases/phase-1-summary.md) and
[phases/phase-2-summary.md](phases/phase-2-summary.md).

Nine phases. Each ends with a summary document in `docs/phases/`, and a review gate before the
next begins. Phases 1–3 need no backend at all.

---

## Decisions locked before planning

| Decision | Value |
|---|---|
| Pairing | **Invite codes + Android share sheet.** No `READ_CONTACTS`, no address-book upload, works on day one. |
| Onboarding screen 1 | "Who should know you're OK?" → people who watch **me** → I am **watched** → Tap + Away main screen |
| Onboarding screen 2 | "Who are you looking after?" → people **I** watch → I am a **watcher** → list main screen |
| Both selected | Tap + Away takes priority; a top action button opens the watcher list |
| Firebase project | `i-am-ok-c74ca` ("I Am Ok"), project number `744276314021` |
| Firebase CLI | Authenticated as `davamix@gmail.com` — I can drive rules, indexes, Functions, emulators |
| Away start date | Always today. Calendar selects the **last away day** only. No future-dating. |

### Firebase infrastructure — provisioned and verified 2026-08-15

Independently verified from the CLI, not taken from a console summary.

| Item | Value | Verified by |
|---|---|---|
| Firestore location | **`europe-west1`** — permanent | `firestore:databases:get` |
| Firestore mode | **`FIRESTORE_NATIVE`** — permanent | `firestore:databases:get` |
| Android app | `1:744276314021:android:304a9d901675e9ee748a4c` | `apps:list` |
| Debug SHA-1 + SHA-256 | both registered | `apps:android:sha:list` |
| Google sign-in provider | enabled | OAuth clients present in config |
| `google-services.json` | at `android/app/`, 1327 bytes, both OAuth clients | file read |

`europe-west1` was chosen over `eur3` for co-location with Functions, EU residency, and cost.
Both were permanent at creation; this one is now settled.

**Web OAuth client** — `744276314021-uour1dugadnlu0kf4atdmgs9bv00sd6n.apps.googleusercontent.com`.
This is the `serverClientId` value `google_sign_in` needs on Android. Using the *Android* client ID
instead causes a silent sign-in failure with no useful error.

Still outstanding, all Phase 4: Blaze plan, the 2nd-gen Functions APIs, FCM v1 confirmation,
App Check in monitoring mode, and confirming Analytics / RTDB / Storage remain off.

See `docs/infrastructure/firebase-setup-prompt.md` for the full state and two CLI traps that cost
time during setup (`--out` silently leaving a stale file; exit code 9 not meaning failure).

---

## Phase 0 — Foundations

No app code. Sets up the documentation, constraint, and review machinery everything else runs on.
One session with no functional progress, deliberately.

**Deliverables**
- `docs/` reorganised by topic (see below), with `docs/README.md` as the index
- `CLAUDE.md` in failure-log form — project overview + build commands, **and no invented
  constraints**. Entries get added as real failures occur.
- `.claude/skills/` — project guidelines per topic, loadable during normal work
- `.claude/agents/` — five reviewer agents
- `.gitignore` hardened for secrets; `.local/` established as the private, never-committed area

**Documentation layout**
```
docs/
  README.md              index and reading order
  PLAN.md                this file
  HANDOVER.md            kept, marked historical
  architecture/          ARCHITECTURE.md + decision records
  security/              threat model, rules guidelines, secrets policy
  ui-ux/                 guidelines, screen specs
  testing/               strategy, device matrix
  infrastructure/        Firebase setup runbook, deploy notes
  legal/                 privacy policy, terms
  phases/                one summary per completed phase
```

**Reviewers** (`.claude/agents/`) — `architecture-reviewer`, `security-reviewer`, `uiux-reviewer`,
`testing-reviewer`, `infrastructure-reviewer`. Skills carry the rules; agents apply them.

**Exit criteria** — docs navigable from `docs/README.md`; agents invocable; `git status` clean with
no secret paths trackable.

### On the public/private documentation split

The split you asked for is real but **narrower than it looks**, and being precise about it matters
more than being cautious about it.

**Genuinely secret — never in the repo, `.local/` and a password manager:**
- the release keystore and its passwords
- any service-account JSON (Functions admin, Play publishing)

**Not secret, despite intuition — these ship inside the APK and anyone can extract them:**
- the Firebase project ID and project number
- the API key in `google-services.json`
- the Firestore security rules

Treating an extractable API key as a secret buys nothing and creates false confidence. The actual
control is **security rules plus App Check** (Play Integrity attestation), which is what stops a
stranger with your API key from reading anything. App Check is proposed in Phase 4.

---

## Phase 1 — Domain layer

Pure Dart. No Flutter, no Firebase, no `DateTime.now()`. This is the specification, expressed as
testable code.

**Deliverables** — `DayKey`, `AwayPeriod`, `ReminderPolicy`, `WarningPolicy`, `Reconciler`, and the
`Link` / `CheckIn` / `WatchStatus` entities, with a full unit suite.

**Non-negotiable:** the policies take their `away` argument from the first line, even while it is
always null. Retrofitting it later means touching every call site and every test.

**Exit criteria** — `flutter test` green, covering day boundaries across timezones, DST, away edges
(`from`, `through`, the day after), the correction path, and warning suppression.

**Review focus** — purity. Anything that reaches for a clock, a plugin, or I/O belongs in a layer above.

---

## Phase 2 — Watched side, on real hardware

Fake data, no backend. Proves the mechanism that everything else assumes works.

**Start from [phases/phase-2-brief.md](phases/phase-2-brief.md)** — it carries two decisions taken
at the Phase 1 gate that must land in this phase: the domain must be told whether a notification can
actually be **delivered**, and the Tap screen names **who will be notified** and says nothing else.

**Deliverables** — `LocalStore` (sqflite), `AlarmScheduler`, `NotificationService` + channels, the
minimal Tap screen, and the debug harness (force date, fire alarm now, dump store, run reconcile).

**Tap screen behaviour** — large target, high contrast, minimal chrome. Once tapped, the target is
**disabled for the rest of the local day** and reads *"You already tapped today, at 09:14"* — the
memory-safety idea, worth having even though the write is idempotent. Re-enables at local midnight.

**Exit criteria** — on a **real phone**: 12:00/18:00/21:00 fire; a tap cancels the rest of the day;
alarms survive a reboot; the window re-arms without opening the app.

> **Status: MET, on stock power settings.** Verified 2026-08-17 on the POCO F3 (Android 13,
> HyperOS `OS1.0`), reading `AlarmManager` rather than the app's own belief. The pass also found the
> phase's most serious defect — a force-stop cancels every alarm and `reconcile()` did not repair it,
> leaving the app permanently inert — now fixed and re-verified on the same device. Evidence in
> [phases/phase-2-summary.md](phases/phase-2-summary.md).

**Risk** — this is where OEM battery management either works or doesn't. It is the reason this phase
is second rather than fifth.

---

## Phase 3 — Watcher side, on real hardware

**Start from [phases/phase-3-brief.md](phases/phase-3-brief.md)** — it carries the force-stop
exposure Phase 2 found and could not close on this side, plus the copy owed before any warning
ships.

Still fake local data. Proves the one bug that would make this app harmful.

**Deliverables** — the alarm isolate (`android_alarm_manager_plus`), the self-verifying dead man's
switch, the false-warning suppression, and the late-arrival correction.

**Exit criteria** — a warning fires when it should; is suppressed when a check-in is cached; is
suppressed when away covers the day; is replaced by a correction when a late check-in arrives; and
says something **different and honest** when the device cannot reach the network.

> **Status, 2026-08-20: implemented, reviewed, and all five exit criteria observed on hardware.
> Not yet signed off** — see [phases/phase-3-review-handover.md](phases/phase-3-review-handover.md)
> for what remains.
>
> **Done since this block was last written:** all five reviewers ran at the gate and every finding is
> fixed; **all five exit criteria were driven end-to-end on the device** (2026-08-20 15:33–15:55,
> one build, one session — not merely asserted in tests); the alarm isolate wakes from a killed
> process; and the reconcile ran with the UI live without the store and the platform diverging.
>
> **Two things were found on the device and are recorded rather than glossed.** The warning is
> **late when the watcher's phone is in deep Doze** — `android_alarm_manager_plus` hands the work to
> JobScheduler, which Doze holds; accepted for now in
> [ADR-0008](architecture/decisions/0008-the-warning-is-late-in-doze-and-the-app-says-so.md), which
> also reworded §14's trigger condition because it was false as written. And the alarm isolate was
> **closing the UI's shared database connection**, now fixed with two guards. ADR-0007 records the
> force-stop response.
> Evidence in [phases/phase-3-summary.md](phases/phase-3-summary.md).

---

## Phase 4 — Firebase backbone

> **In progress. Steps 1–7 are built, all five reviewers have run, and the owner-approved changes are
> built and proven on hardware** — a push may not post a warning before `warningLocalTime`
> ([ADR-0010](architecture/decisions/0010-a-push-may-not-post-a-warning-early.md)), and a row that
> changes under a screen reader is announced, **both directions**. The post-gate diff was re-reviewed
> by architecture, testing and UI/UX, and the **three items that round left open are all closed**:
> announcements still reach TalkBack at `targetSdk 36` (measured on the API 36 AVD against a silent
> control — the risk was real to raise and false as stated), the retraction the hour-gate used to
> destroy is now held and spoken at the reader's hour, and the copy decision it blocked was approved
> by the owner and built. A second review round over that work has also run and its findings are
> applied. **The only design decision still open is what ADR-0008's option 1 costs** — the owner asked
> for the number, not the ADR. After that: the **first Functions deploy**, **App Check's console
> half**, the **live-radio** version of step 7's measurement, and the AVD taps. Start from
> [phases/phase-4-summary.md](phases/phase-4-summary.md); the earlier
> [phases/phase-4-handover.md](phases/phase-4-handover.md) carries the four things that went wrong
> in the first half of the phase — two of them **false greens**, work that looked finished and was
> not.
>
> **[ADR-0009](architecture/decisions/0009-decide-about-every-completed-day.md) also landed here**
> and was not in this plan: ADR-0008 consequence 4 was owed as a measurement, turned out to be real,
> and turned out to be **wider than Doze** — a drawer, a force-stop and a flat battery dropped
> missed days by the same arithmetic. `reconcile()` now decides about every completed day it has
> not settled.

**The irreversible step is already done** — Firestore exists in `europe-west1`, Native mode.
What remains:

1. ~~Wire `firebase_core` + `google_sign_in` against the existing config, using the **Web** client
   ID as `serverClientId`.~~ **Done** (`8f13f46`, `a0dc307`). Release SHA fingerprints still get
   added at Phase 8, when the keystore exists. Sign-in is driven from the debug harness — the screen
   inventory specifies no sign-in surface and Phase 5 builds the real one.
2. ~~**`firestore.rules` + emulator-based rules tests, and deploy them — before any client write
   exists.**~~ **Done** (`a433c47`) — 73 tests, mutation-checked, live ruleset
   `87c8784d-42b8-45c8-8bcc-76d295656157`.

   ```powershell
   firebase deploy --only firestore:rules --project i-am-ok-c74ca
   ```

   > **Reordered at the Phase 3 gate.** This was step 3, after the client writes below, and
   > `deploy-notes.md` has always said rules deploy first. Here the generic reason — "the client
   > fails in a way that looks like a client bug" — badly understates it. Firestore was created in
   > **production (locked) mode**, so a client built against undeployed rules gets
   > `permission-denied`; [ADR-0004](architecture/decisions/0004-refused-is-not-unreachable.md) maps
   > that to **refused**, which drives the access-lost notification and its 0/1/3/7/14-day cadence.
   > Following the old order produces the exact class of false claim to a family that this app exists
   > to avoid, from a developer's own laptop.

3. ~~`users/{uid}` + token subcollection; check-in write with `deviceTappedAt` + `receivedAt`.~~
   **Done** (`9ffea33`), plus the link sync the step did not mention and cannot work without.
   The token methods are written and are called in step 5.
   **The watcher's reconcile read must use `Source.server`, or check
   `metadata.isFromCache`** — offline persistence is on by default and `get()` does *not* throw when
   offline, it serves the local cache. Treating that as a successful read stamps `lastReconcileAt`
   and silently disables ADR-0001's staleness bound on every reconcile. Map `permission-denied` /
   `unauthenticated` to **refused** and `unavailable` / `deadline-exceeded` to **unreachable**
   ([ADR-0004](architecture/decisions/0004-refused-is-not-unreachable.md)).
4. ~~`onCheckInCreated` Function, `europe-west1`, data-only FCM fan-out~~ **Done** (`e030fea`).
   High priority, data-only, one collapse key. Only `registration-token-not-registered` prunes a
   token — `invalid-argument` is returned for a malformed *message* too, and pruning on it would
   deregister the whole fleet from one bad deploy. **Not deployed**; the emulator is where it has
   run so far.
5. ~~FCM wiring in both the UI and background isolates~~ **Done** (`e1d0491`), and the FCM handler
   is §4's **third** entry point. It reads nothing out of the message, which
   `push_handler_test.dart` enforces by counting the identifier: the payload looks exactly like the
   answer the reconcile is about to fetch, and trusting one field would let a forged push move
   `lastConfirmedDay` for a day nobody tapped.
6. ~~**App Check** (Play Integrity), **monitoring mode only**~~ **Done** (`3f012f0`) — enforcing
   before the client sends tokens would lock the app out of its own backend. Client-side only:
   **registering the debug token and turning enforcement on are still owed**, and until then the
   rules are the whole defence.
7. ~~**Re-open ADR-0008's delivery-hop question**~~ **Measured** (`0063888`) — the Phase 4 trigger
   that ADR is written against, and **both its questions passed**. High-priority data-only FCM wakes
   the background isolate in forced deep Doze: the platform grants a ~20 s allowlist and names the
   reason `high-prio FCM`, and a Flutter engine started and began reconciling 2 974 ms in.
   Mutation-checked — the same run at `priority: 'normal'` produced no allowlist, no process and no
   reconcile. **Two things remain**: the read went over `adb reverse` loopback rather than a radio,
   so the live-project version is owed; and choosing ADR-0008's successor is the owner's decision,
   not a measurement.

**Blaze plan** is required from step 4 onward, along with the 2nd-gen Functions APIs (Cloud
Functions, Cloud Build, Artifact Registry, Eventarc, Cloud Run, Pub/Sub, Cloud Storage). Free
allowances mean effectively €0 at this scale, but the card must be on the account.

**Exit criteria** — a tap on one physical phone quietly updates a second physical phone.

> **Only one physical phone exists, and the substitution is recorded rather than made quietly** —
> decided 2026-08-20, full reasoning in [testing/device-matrix.md](testing/device-matrix.md).
> **POCO F3 = the watcher, the receiving endpoint; the API 36 AVD = the watched, tapping endpoint.**
> The direction is the decision: the receiver is where FCM must pierce Doze and wake a background
> isolate, so it stays on real OEM hardware and the emulator only writes a check-in. Run the other
> way round the criterion proves nothing, because an emulator has no Doze and no vendor killer.
>
> So the criterion is met in its **functional** half. Its second-real-device half is **not** met, and
> six specific checks are listed in the matrix as owed until a second handset exists — chief among
> them the watched person's actual phone, which is still unidentified and is the one device that has
> to work.

---

## Phase 5 — Onboarding and pairing

> **COMPLETE and SIGNED OFF, 2026-08-26.** Built, the exit criterion met on two devices, **all three
> owner decisions taken**, the review round's six open items closed or recorded, and **the five
> reviewers run twice — once over the phase, once over the close-out itself**. Start from
> [phases/phase-5-summary.md](phases/phase-5-summary.md) — *Closing the phase* is what happened at
> the gate. [phases/phase-5-handover.md](phases/phase-5-handover.md) was the close-out plan and is
> now historical.
>
> **The three owner decisions.** Copy approved as drafted, with four amendments — `ownCode` rewritten
> to name a phone rather than a relationship, the expiry added to the share message, an action label
> for the watcher-list control, and a fourth refusal. **The cross-role dead end** closed with a
> chooser behind the Tap screen's *Add someone*: it opened `ShareCodeScreen` and only that, while the
> only route to `EnterCodeScreen` was reachable solely by somebody already a watcher — so anybody who
> skipped onboarding's second question was shut out of that role for good. **The 21:00 reminder** now
> drops its *"so your family knows you're well"* clause when nobody is set up; `screens.md` no longer
> says *"Owed before Phase 5"*.
>
> **The gate found more than it closed**, which is the usual shape here. `couldNotReach` was said on
> four paths where the server had answered — ADR-0004's *refused is not unreachable*, one layer down
> — and the exception mapping that decided it sat inside a `catch` no test can enter. The
> `@types/node` in the TypeScript program was **four majors ahead** of the deployed runtime while
> `deploy-notes.md` said it was not installed at all. The documented release-manifest check greps for
> a *permission*, so it could not see `share_plus` contributing a content provider. And every
> two-line source lint in the suite would fail on a fresh clone on Windows, because Git's default
> `autocrlf` disagrees with what the repo stores.
>
> **The mutation harnesses are in the repo now** — `tools/mutate-dart.mjs`,
> `tools/functions-mutate.ps1` — rather than being a claim nobody could re-run. Rebuilt and re-run,
> they found five test gaps: four in `functions/test/invites.test.js`, including a TTL assertion that
> imported the constant it was checking, and one in `InviteCode.tryParse`, where skipping an
> unrecognised character instead of refusing it turns `K7RTQXO` into somebody else's valid code. They
> also **refused to score three times before scoring cleanly** — twice on a mistake in the caller,
> once on a mutated build left behind in `functions/lib/`.
>
> **And running the reviewers over the close-out is what made the phase actually done.** They found
> four more defects in it, two of them serious: the chooser added to close a dead end opened a second
> door into the unarmed-watcher failure `main.dart` has warned about for three phases, and the
> flagship 21:00 change had **no test on the line that produces the sentence** — both scheduler
> doubles replaced it, so they proved the flag was passed and never that it chose a body. The Dart
> mutation harness had also been reporting 14/14 with **no compile gate**, and three of those
> mutations never compiled.
>
> Built against the emulator suite as the brief instructed, so **nothing here says anything about a
> deployed `redeemInvite`**; the 2nd-gen deploy is still blocked on four missing APIs and remains
> the owner's call.
>
> **[ADR-0011](architecture/decisions/0011-creating-an-invite-is-a-function-too.md) landed here and
> was not in this plan.** §8 has always said `invites/{code}` is Function-written and the deployed
> rules enforce it, while §9 listed only `redeemInvite` and §6 gave `InviteService` a "create
> invite" no client may perform. There is now a **fourth** Function, `createInvite`, which is what
> makes the three sections agree.
>
> **Two defects were found by the device run and by nothing else** — every callable was being sent
> to `10.0.2.2` from a physical handset because a third FlutterFire plugin rewrites the emulator
> host, and the summary screen was unreachable because the router left onboarding the moment a
> question was answered. Both are in `testing/device-matrix.md` under *Pairing on two phones*.

**Deliverables** — ~~the three screens with both Skip options, identical for every user; invite
creation and the `redeemInvite` callable; role routing from the two selections; the summary
screen.~~ **All built**, plus three things the list did not name and the phase could not be finished
without: a **sign-in screen** (every link is keyed by a uid, and Phase 4 signed in from the debug
harness), **`createInvite`** (ADR-0011), and a **route back into pairing** from both main screens
(without it a skipped first question is a dead end and a second watcher can never be added).

**Exit criteria** — ~~two phones pair from a cold install using only a shared code, and each lands on
the correct main screen.~~ **MET, 2026-08-26**, AVD ↔ POCO F3, both uninstalled first, code read off
one screen and typed into the other. Mum landed on the Tap screen naming Ana; Ana landed on the
watcher list showing Mum. **The AVD also tapped**, which closes the half Phase 4 left owed.

---

## Phase 6 — Away mode

> **BUILT; REVIEWED TWICE — once over the phase 2026-08-27, once over the close-out 2026-09-01; RUN
> ON DEVICES 2026-09-01 (two API 36 AVDs, then the POCO F3); ALL SEVEN OWNER DECISIONS TAKEN AND
> APPLIED the same day; DOZE MEASURED ON A REAL OVERNIGHT 2026-09-02. Not signed off** — the only
> thing outstanding is §12's four away transition notifications, which are specified and deliberately
> not built, and which this deliverable list does not name. Start from
> [phases/phase-6-handover.md](phases/phase-6-handover.md), then read *The gate review*, *The device
> run* and *The second gate* in [phases/phase-6-summary.md](phases/phase-6-summary.md).
>
> **The second gate found four more defects**, which is why it exists: Phase 5 was signed off only
> after the same second pass. A stale `deploy-notes.md` header claiming the live rules were
> byte-identical to the repo when they were 2 219 bytes behind; a recorder knob **no test ever
> turned**, so the watcher row could report *"Saved."* for a refused write with all 1 370 tests green;
> the watcher-side write path reached by **no test at all**, leaving the queued-cache asymmetry
> enforced only by the absence of a call; and a confirmation dialog whose two actions stacked with
> **zero gap**, destructive directly under safe, at the font scale it was built for. Nine findings
> applied and each verified by reverting it; four decisions taken.
>
> **Doze, measured 2026-09-02 on a real overnight** — the last open device row. Unplugged 23:48 in
> aeroplane mode, `device_idle=full` at 00:50, then the textbook 1 h / 2 h / 4 h / 8 h doubling with
> 30-second maintenance windows, and `full` **unbroken from 07:52 to 12:34**. The 12:00 reminder — the
> first day back after the away period ended — posted at **12:00:00.876**, 876 ms after the armed
> second, with 0% battery drain over 12h45m. It goes beyond ADR-0008, which measured *forced* Doze in
> Phase 3; the *warning* path is untouched and stays as ADR-0008 accepted it.
>
> **The gate found that the feature did not work.** Three of the five reviewers independently found
> that away could be set **once per person and then never again**: nothing deletes the away document
> when a period *ends*, `from` was immutable on update, and both call sites passed the stale cached
> period as `existing` — so every later attempt was refused, client-side *and* by the rules, with copy
> blaming the reader's choice of day. Three documents said it worked, including §12's *"to go longer,
> set it again"*. The fix is a scope correction rather than a new rule: ADR-0001 decision 6 froze
> `from` for the life of a **period**, not of a person, and both the client and the rules now carry
> that distinction. Both new rules tests were verified by reverting the clause.
>
> **Two more defects that produce silence.** `onAwayChanged` could not change a **closed** watched
> device — `push_handler.dart` never passed `away:`, so the FCM reconcile decided reminders from the
> very cache the nudge came to replace. And `AwayRepository.read` had no timeout while being awaited
> inside `tap()`, which is the hang that file argues against five lines above it.
>
> **Eleven claims had stopped being true**, most of them written in the same commits that made them
> false — including `AwayCopy.queued` saying *"when this phone is back online"* one file after
> `AwayOutcome` spends a paragraph refusing to say *"could not reach the server"*, and a test guard
> that asserted what `setUp` had assigned rather than what the run did.
>
> **The owner decision this phase opened with is taken**: the away line names who set it **when it
> wasn't you** — `TapCopy.awayBy` for a watcher's action, and the already-approved `TapCopy.away`
> unchanged for her own and for a document that names nobody. It is the surface §17's *one watcher
> silences the whole family* mitigation depends on, and it was put before the screen was built rather
> than after.
>
> **What existed already was as much as the brief promised** — `AwayPeriod`, `AwayRules`, the away
> rules with 27 tests, the `self_away` table and the `away` parameter on every policy since Phase 1 —
> so this was a feature rather than a retrofit. What this phase added: `AwayRecord` (attribution,
> deliberately a **separate type**, because the moment a policy can see `setByName` it can decide from
> it), `AwayRead`, `AwayOutcome`, `AwayRepository`, the `self_away` accessors, schema **v6**,
> `onAwayChanged`, the picker, the Tap screen's away state and the watcher list's away row and action.
>
> **`AwayOutcome` has no "could not reach the server", and the absence is the decision.** Away is a
> direct client write so it queues offline (§8); a write that has not confirmed is either in flight or
> queued behind a dead radio, the client cannot tell them apart, and both end with the write landing.
> Saying it failed would be a false claim about a write that arrives ninety seconds later.
> `AwayOutcome.queued` is the honest name — ADR-0004's *refused is not unreachable*, one layer below
> `PairingRefusal.serverFault`.
>
> **`AwayPeriod` came off the mutation harness's "not mutated" list**, where it had sat for five
> phases as a type nothing read. **39 Dart mutations, 39 caught, 0 survived, 0 failed to compile,
> fourteen passing controls. 1 396 Dart tests**, 102 Functions tests plus a fourth no-emulator run,
> 82 rules tests, analyze clean, debug APK builds. *(This paragraph read 25 / 1 322 until 2026-09-01
> and 34 / 1 370 until 2026-09-02 — twice now the gate's own commits moved the numbers and did not
> move this line. It is the third claim in this document corrected for that reason.)*
>
> **The device run is done**, 2026-09-01: every checklist row in `testing/device-matrix.md`,
> including the Phase 5 gate's unarmed-warning check, on two AVDs and then the OEM half on the POCO.
> It proved the closed-app nudge in both directions, both cancel shapes, §17's attribution line on a
> handset, and the v5 → v6 migration on a real store — and found that an away period set **offline**
> reports *"Saved."* and changes nothing on the setter's own phone until an unrelated reconcile runs.
>
> **The owner's decisions are taken**, 2026-09-01, and applied: the copy is approved with the picker
> title amended to name the person on a watcher's phone; ending a period from the **watcher's row**
> now asks first; that row says when a write lands; and a **queued** away write is cached on the
> phone that wrote it, which is what stops the screen contradicting its own *"Saved."*. Answers and
> questions both in `ui-ux/screens.md`; the extending limitation is recorded in §12.
>
> **Owed:** §12's four away **transition notifications** only — specified and deliberately not built,
> and this deliverable list does not name them and the exit criteria do not turn on them.
> ~~**Doze on the handset.**~~ **Measured 2026-09-02**, on a real overnight: the reminder posted
> **876 ms** after the armed second from 4h42m of unbroken `device_idle=full`.

**Deliverables** — `users/{uid}/shared/away`, rules validation (31-day cap — **deliberately slack in the rules, see `security/firestore-rules-guidelines.md`; the exact check is `AwayRules`**, no retroactive,
`through >= from`), the `onAwayChanged` fan-out, the Away button on the Tap screen (which becomes
*"I'm not away"* while active), and the away action on the watcher list.

**Calendar copy** — the picker labels the chosen day unambiguously: *"Last day away: Saturday 22"*
and *"Back on Sunday 23"*.

**Exit criteria** — ~~away set from either side silences both sides everywhere; cancelling restores
both; and a device that was offline for the whole period still ends away on the right day.~~ **All
three met in tests, 2026-08-27** (`test/application/away_exit_criteria_test.dart`), driven end to end
through both reconcilers and built around **ending** rather than starting, because away is the first
feature here whose failure mode is silence. **The first two are now met on devices as well,
2026-09-01** — away set from either side silenced both, and cancelling from either side restored
both, on two AVDs and on the POCO, with the alarms read from `dumpsys` rather than from the app's own
record. **And the third was driven the same day**, on the POCO in eleven minutes: aeroplane mode on
for the whole run, the harness walking the clock from the last away day to the first day back, the
period ending **by arithmetic with every read refused** (`UNAVAILABLE` throughout), the cached row
surviving because the days spent away stay covered, and the reminders armed again on the right day.
**All three exit criteria are now met on devices as well as in tests.** What no device has is the
*watcher's* half of clause 3 — a watcher offline across the boundary warning again on the first day
back — which the test file covers.

---

## Phase 7 — UI/UX and the health panel

**Deliverables** — the watcher list (multiple watched people, status per row, away action), the
health panel, and cold-open state.

**Cold open** — an *unresolved* warning if one stands, otherwise "Everything OK" with the last
check-in time. Note this means the current state, not the most recent warning ever fired: a warning
from three weeks ago that was followed by three weeks of check-ins is history, not status.

---

## Phase 8 — Release readiness

**Deliverables** — release keystore + signing config, privacy policy and terms, the Play
sensitive-permission justification for `USE_EXACT_ALARM`.

**Signing** — `keytool` is available in the Android Studio JBR, so I can generate the keystore and
wire `key.properties` + `build.gradle.kts`, with both gitignored. Two things are yours to decide:
the password (I will not invent one and leave it in a file as the only copy), and whether to enable
**Play App Signing** — strongly recommended, because it makes a lost *upload* key recoverable,
whereas a lost app signing key means the app can never be updated again.

**Legal** — I can draft a privacy policy and terms covering the actual data flows (Google account
email and display name, a daily timestamp, away periods, links). It needs hosting at a public URL
for Play; GitHub Pages under your existing namespace works. **This is a template grounded in the
real data flows, not legal advice** — worth a lawyer's eye given vulnerable-person data and a Spanish
establishment.

---

## Per-phase protocol

1. Implement
2. Run the relevant reviewer agents
3. Write `docs/phases/phase-N-summary.md` — what was built, what was decided and **why**, what was
   deferred, what to watch out for next
4. Stop for your review before the next phase

---

## What this plan does not include

- Contact-list discovery (replaced by invite codes)
- Future-dated away periods (the field exists; the UI does not)
- A per-link "mute just me"
- A scheduled server-side missed-check-in Function — still the documented escape hatch if Phase 2
  or 3 reveals that OEM alarm reliability is worse than the design assumes
- iOS
