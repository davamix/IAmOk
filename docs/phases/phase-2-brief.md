# Phase 2 — brief, and the two decisions carried in from Phase 1

**Date:** 2026-08-16 · **Status:** Ready to start · **Phase 1 committed** as `55f82bf`

Two decisions were taken at the Phase 1 gate that Phase 1 deliberately did **not** implement,
because both need layers Phase 1 does not build. They are specified here in full so the next session
can act without re-deriving them. Everything else in this file is the context needed to do that
safely.

---

## Paste this as the first prompt

> I'm starting Phase 2 of the "I Am Ok" project. Read `docs/phases/phase-2-brief.md` first — it
> carries two decisions already taken that must land in this phase, plus the reading order and the
> state to verify before writing anything. Then follow the reading order it gives.
>
> Do not re-open the two decisions in that file; they were settled with the owner. If you believe
> one is wrong, say so before implementing rather than diverging.

---

## Where things stand

Phase 1 built the domain layer and nothing else. `lib/main.dart` is still the stock Flutter counter
scaffold. There is no `LocalStore`, no `AlarmScheduler`, no `NotificationService`, no `Clock`, no UI.

| | |
|---|---|
| Commit | `55f82bf` on `main`, not pushed |
| Tests | 328, all passing |
| Decision records | ADR-0001 … **ADR-0004** — all four are binding |
| Phase 1 summary | [phase-1-summary.md](phase-1-summary.md) — read the *Review* section, it is where the design actually got decided |

### Verify before writing anything

```powershell
flutter analyze                                   # No issues found!
flutter test                                      # All tests passed!  (328)
dart run tools/models/away_warning_model.dart     # superseded: 4 failure(s)   decided: 0 failure(s)
pwsh -File tools/check-secrets-ignored.ps1        # OK - 19 paths ignored, 1 deliberately tracked
```

If the model line does not read `superseded: 4 / decided: 0`, stop — that is the ADR-0001
regression guard and something has drifted. It also runs inside `flutter test` via
`test/domain/model_regression_test.dart`.

### Reading order

1. **`docs/phases/phase-1-summary.md`** — what exists, what was decided and why, and what four
   reviewers found. The *Review* section is long on purpose: three of its defects were introduced by
   earlier fixes, and the reasoning is what stops them coming back.
2. **`docs/architecture/ARCHITECTURE.md`** — §4 (isolates), §6 (`LocalStore` fields), §10 (alarms
   and the eight-step decision), §11 (time), §13 (health panel). Nothing may contradict it.
3. **`docs/architecture/decisions/`** — ADR-0001 through **ADR-0004**. All four amend
   ARCHITECTURE.md and all four are live.
4. **`docs/PLAN.md`** — Phase 2's deliverables and exit criteria.
5. **`docs/ui-ux/screens.md`** — the Tap screen and the approved copy. Every user-visible string
   must come from here.
6. **`docs/testing/device-matrix.md`** — Phase 2 has a **device exit criterion**. Stock power
   settings first.

Then load the `architecture-guidelines`, `testing-guidelines` and `ui-ux-guidelines` skills.

---

## Decision 1 — the domain must be told whether a notification can actually be delivered

### The defect this closes

`WatcherReconciler.reconcile` currently records a message as *shown* at the moment it decides one is
*owed* (`watcher_reconciler.dart`, `withAccessLostNotifiedOn` and `withWarningShownFor`). It has no
way to know whether the platform posted anything.

The mild case is cosmetic: a reminder lands while the watcher already has the app open, showing the
same thing.

**The sharp case is `POST_NOTIFICATIONS` being revoked**, which §13 rates High precisely because it
happens to watchers who never open the app. The alarm isolate still fires, still reconciles, and
still marks each reminder consumed. Nothing is shown. For the *daily* warning this self-heals — a
new day `D` gets a fresh attempt — but the **access-lost cadence does not**: days 0, 1, 3, 7 and 14
are each silently consumed, and if permissions return on day 20 the next reminder is day 21. The
cadence built to survive a *sleeping* device does not survive a *muted* one.

### The decision

**Pass the delivery capability in as an explicit value**, exactly as `now`, `away` and `watcherZone`
already are. Verified as genuinely pure: every parameter `reconcile` takes today is a plain value
supplied by the layer above, so this adds no import, no coupling and no I/O, and is testable by
passing a value.

Three states, because "could not" and "chose not to" must behave differently:

| State | Post a notification? | Consume the reminder? | When |
|---|---|---|---|
| `available` | **yes** | yes | normal |
| `redundant` | no | **yes** | the user is looking at the screen that already shows this — they have seen it |
| `unavailable` | no | **no** | `POST_NOTIFICATIONS` revoked — nothing was delivered, so nothing is owed-off |

Suggested shape, to be refined in implementation:

```dart
enum NotificationDelivery { available, redundant, unavailable }
```

and in the reconciler, replacing the current unconditional record:

```dart
final owed = /* the existing shouldNotify computation */;
shouldNotify = owed && delivery == NotificationDelivery.available;
final seen   = owed && delivery != NotificationDelivery.unavailable;
if (seen) { /* record it */ }
```

**This applies to both channels** — `warningsShownFor` and `accessLostNotifiedOn`. Do not fix one
and leave the other; that is the exact mistake ADR-0004's clamp made, and it cost two review rounds.

### What to test

- `unavailable` → nothing recorded, and the reminder is still owed on the next reconcile.
- `redundant` → no notification, but the day *is* consumed.
- The access-lost cadence with `unavailable` for days 0–5: the day-0 reminder is still owed on day 6.
- Both channels, independently.

### Who supplies it

The platform edge — `PermissionService` for the revoked case, app lifecycle for the foreground case.
Neither exists yet; both are Phase 2. Until they do, pass `available`.

---

## Decision 2 — the Tap screen names who will be notified, and says nothing else

### The gap this addresses

§8 lets **either party** revoke a link. ADR-0004 modelled the watcher side of that thoroughly.
Nothing modelled the watched side: `WatchedReconciler.reconcile` takes no links at all, so if the
last watcher revokes, the watched person keeps tapping every day believing the promise, and no
surface anywhere says otherwise.

No Cloud Function is needed. §8 already lets the watched person read their own links, so their
device can see this by reconciling.

### The decision

**The Tap screen shows who will be notified when the person taps. That is all.**

**Explicitly rejected — do not implement, and do not re-propose:**

- a notification when someone starts watching
- a notification when someone stops watching
- a "nobody is watching you" warning, banner, or health-panel item
- any other status-change message on the watched side

**The owner's reasoning, recorded so it is not re-litigated:**

> If everyone stops watching Mum, that is a family problem or a lack of communication. It is not the
> app's responsibility.
>
> It is important to avoid extra notifications or messages in the watched app. Elderly people can be
> overwhelmed if we start showing different messages like "this started watching you", "that stopped
> watching you", "no one is watching you". Elderly users are not ready to read a lot, and may not
> understand what the different messages mean.

This is a deliberate trade-off, not an oversight. It accepts the silent-inertness exposure the
Phase 1 security review raised (its finding M4) in exchange for a screen an 80-year-old can read at
a glance. **A future reviewer will flag this again** — the finding is real and the acceptance is a
judgement about who the app is for. Record it in `docs/ui-ux/screens.md` alongside the Tap screen so
the next reviewer meets the decision rather than the gap, in the same way ADR-0003 records the
display-name check it rejects.

### What this needs

- A pure derivation on the watched side: *who will be notified?* — the accepted links, by name.
- Therefore `WatchedReconciler` (or whatever supplies the Tap screen) gains a links input. Consider
  giving it the parameter now even where it is unused, on the same reasoning PLAN.md gives for the
  `away` argument: retrofitting later touches every call site and every test written in between.
- Copy in `screens.md`, approved before it ships, and reviewed by `uiux-reviewer`.

### The one detail still open

The screen has to render *something* when the list is empty — which is also the state before pairing
has ever happened. The quiet reading of the decision above is to show the line only when there is
someone to name, and otherwise show nothing at all. Settle it with the owner and record it; do not
invent an empty-state message, since that is the thing the decision exists to avoid.

---

## Phase 2's own scope, unchanged

From PLAN.md. Fake data, no backend.

**Deliverables** — `LocalStore` (sqflite), `AlarmScheduler`, `NotificationService` + channels, the
minimal Tap screen, and the debug harness (force date, fire alarm now, dump store, run reconcile).

**Exit criteria — on a real phone:** 12:00/18:00/21:00 fire; a tap cancels the rest of the day;
alarms survive a reboot; the window re-arms without opening the app.

**Build the debug harness alongside the first alarm, not after it.** Without it, verifying a
24-hour behaviour takes 24 hours.

### `LocalStore`'s schema comes from §6, and it changed in Phase 1

Per-link: `lastConfirmedDate`, `warningsShownFor` — **a map of day → which warning is standing**, not
a set — `activeFrom`, `watchedTimezone`, cached `awayPeriod`, `accessLostSince`, `accessLostCause`,
`accessLostNotifiedOn`. Plus `deviceTimezone`, `pendingAlarms`, and `lastReconcileAt` as a **full
timestamp**.

Missing `accessLostNotifiedOn` means the reminder dedupe silently fails and a reminder day fires four
times.

---

## Carried non-negotiables

- **The domain stays pure.** `test/domain/domain_purity_test.dart` enforces it — no Flutter, no
  `dart:io`, no clock read, no `async`. It resolves relative imports to prove they land back inside
  `lib/domain/`. **Widen it in Phase 2** to cover any path containing `policy` or `reconcile` at any
  layer: the rule is "no clock read in a policy or the reconciler anywhere", and the guard currently
  only checks `lib/domain/`.
- **Apply `toCancel` before `toSchedule`.** Alarm identity includes the instant, so a moved alarm
  appears in both sets while its platform id stays derived from the day. Cancelling last disarms the
  alarm just scheduled, and the symptom is nothing happening. See `warningsToReschedule`.
- **`Clock` is written this phase**, at the platform edge, plugin-free, available in all three
  isolates. The domain keeps taking `now` as a parameter. `ClockService` (device-zone discovery, skew
  detection) is **UI-only** — ADR-0002.
- **Never call `flutter_timezone` from a background isolate.**
- **Four warning outcomes, not three.** Which one fires is a correctness requirement.
- **Notification ids are `hash(link, D)`** so a correction for one watched person cannot touch a
  standing warning for another. The domain hands you both halves.

---

## Already decided — do not re-open

- ADR-0001 … ADR-0004. If code disagrees, the code is wrong; if you believe an ADR is wrong, write
  ADR-0005 rather than diverging quietly.
- The away cap is **31 days**; the rules clause is **`+32d` and deliberately slack**; the read-time
  sanity bound is **60 days**. Three numbers, three jobs — the table is in
  `docs/security/firestore-rules-guidelines.md`. Do not "tidy" them into one.
- The access-lost reminder cadence: day 0, 1, 3, then weekly, **as milestones passed rather than
  exact days**, so a device that sleeps through day 7 is served late instead of skipped.
- The day is a local calendar label, never a UTC instant — §11 has the callout and the worked
  example.
- Quiet confirm, loud miss. Away as one global document. No "away finished" message. Expiry as
  arithmetic.
- The scope boundary in `docs/HANDOVER.md` "Explicit non-goals".

---

## Protocol

1. Implement.
2. Run the reviewer agents — `architecture-reviewer`, `testing-reviewer` and `uiux-reviewer` at
   minimum for this phase; `infrastructure-reviewer` if the Android build is touched. **Expect them
   to find things**: they found twenty-six defects in Phase 1, three of which were introduced by
   earlier rounds of fixes.
3. Write `docs/phases/phase-2-summary.md`, including a **device row per handset**: Android version,
   OEM skin, whether power settings were stock, and what actually happened. A checklist that records
   only passes is not evidence.
4. Stop for the owner's review before Phase 3.

Commit to `main` when the phase is done. Do not push unless asked.
