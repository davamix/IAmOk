---
name: testing-guidelines
description: What to test and at which level in the I Am Ok app, including the mandatory time, away-edge, and false-warning-correction cases. Load before writing or changing any test, before adding logic that depends on the clock, and before signing off a phase that has a device exit criterion.
---

# Testing guidelines

Sources: `docs/testing/strategy.md` and `docs/testing/device-matrix.md`.

```powershell
flutter analyze
flutter test
```

## The premise

Every hard decision is a **pure function over explicit inputs** in the domain layer. That is what
makes the riskiest logic in this app — all of it time-dependent, all of it running in bare
background isolates — testable in milliseconds with no device and no network.

> **If a test needs a device to answer a question about *logic*, the logic is in the wrong layer.**

That is the most useful review question to ask about any change here.

## Levels

| Level | Covers | Tool |
|---|---|---|
| Unit | `DayKey`, `AwayPeriod`, `ReminderPolicy`, `WarningPolicy`, `Reconciler`, correction logic, permission→health derivation | plain `test` — no Flutter, no device |
| Repository | Firestore reads/writes, offline queue behaviour | `fake_cloud_firestore` |
| Local store | `LocalStore` round-trips across isolate-shaped access | `sqflite_common_ffi`, in-memory |
| Rules + Functions | The access matrix, away validation, the `redeemInvite` transaction | Firebase Emulator Suite + `@firebase/rules-unit-testing` |
| Widget | Screen states, especially disabled-after-tap | `flutter_test` |
| Device | Notification delivery, alarm survival, OEM battery behaviour | **Real hardware. Irreducible.** |

## Three rules

**1. Time is injected, never read.** `DateTime.now()` does not appear in the domain layer, and does
not appear in any policy or in the reconciler at any layer. The clock is a parameter; the real
clock is read only at the platform edge, through `Clock` — which is plugin-free and available in
all three isolates, unlike `ClockService`, which is UI-only (ADR-0002). Also flag
`DateTime.timestamp()`, `.toLocal()` — an implicit local-timezone read, a real hazard in a design
where the timezone is always explicit — `Timer`, and `Stopwatch`. This is the rule most likely to
be broken by a well-meaning shortcut, and it is worth failing a review over.

**2. The policies take their `away` argument from the first line**, while it is still always null.
Away mode is not built until Phase 6, but retrofitting the parameter later means touching every
call site and every test written in between.

**3. Test the denied and the silent case.** For rules, every access-matrix row needs both halves —
allowed succeeds, denied is *denied*. For policies, assert the silent cases as hard as the firing
ones. This app's worst bug is something firing when it should not.

## Must be covered

These are not a wish list — they are where this design is known to be able to go wrong.

- **Day boundaries** — taps at 00:05 and 23:55; watcher in a different timezone from the watched
  person, around both edges; DST in both directions; a device whose timezone changes mid-period.
  Assert the soft-midnight outcome (both days green) as well as the inputs.
- **The day id comes from the device clock, not `serverTimestamp()`** — a tap queued offline at
  23:50 and synced at 08:00 still lands on the earlier day. This is the §17 "silently wrong data"
  risk; the test is what stops it being "simplified" back in Phase 4.
- **Away edges** — the day `from` starts; the day `through` ends; the day *after* `through`; away
  set mid-period; away cancelled while a device was offline; away expiring on a device that has not
  been online since it started; `through < from` and a retroactive `from` both rejected; and a
  **31-day period allowed, a 32-day period rejected** — 31 is the longest ALLOWED
  (`AwayRules.maxLengthInDays`), and this line called it a denied case until the Phase 3 gate.
  Tapping during away is still allowed and writes a normal check-in.
- **The rolling window** — 7 days, **extending to `through` + 7 during away with the away days
  absent**. Assert it cancels as well as creates. A window that does not extend past `through`
  means the watched side never re-arms after a holiday.
- **The correction path — the highest-value test in the suite.** A warning shown for day `D`, then
  a check-in for `D` arrives late. The warning must be **replaced** (same notification id),
  `lastConfirmedDate` updated, and `D` removed from `warningsShownFor`. Two causes — offline sync
  and deferred FCM — one handler; test both.
- **Notification identity across links** — ids are `hash(link, D)`. A correction for one watched
  person must not cancel a standing warning for another on the same day.
- **Warning suppression** — before `link.activeFrom`; inside an away period; when the local cache
  already has the day; when Firestore has the day but the cache does not. And the inverse: cache
  says away, Firestore says cancelled → must warn.
- **The offline warning** — assert on *which message*, not merely that something fired. The offline
  wording is a correctness requirement.
- **The push carries no authority** — a synthetic payload for `D` with Firestore unreachable and an
  empty cache must not move `lastConfirmedDate`.
- **`reconcile()` idempotence** — running it twice produces no second alarm, no second
  notification, no changed state. Every entry point calls it; if it is not idempotent, boot
  recovery is a duplicate-notification bug.
- **The date is the document id** — a second tap the same day is an update, fires no
  `onDocumentCreated`, and produces no duplicate push. No dedupe logic exists, so test the premise.
- **Permissions → health derivation** — pure logic. Guards against a panel reporting green while
  `POST_NOTIFICATIONS` is revoked, i.e. the app silently inert.
- **Away transition notifications** — per-recipient filtering, including "everyone except whoever
  cancelled"; and the locally scheduled "ends tomorrow" notice.
- **`redeemInvite`** — expired rejected; consumed rejected; double redemption idempotent via the
  deterministic link id; `activeFrom` in the **watched person's** timezone, not the redeemer's.
- **`UNREGISTERED` token pruning** — pruning the wrong token silences a watcher permanently.

## Real hardware

Phases 2 and 3 have device exit criteria **early in the plan on purpose**. Nothing but a real phone
answers whether alarms and data-only FCM survive on Xiaomi / Samsung / Huawei with **stock power
settings** — an emulator has no OEM power manager and will cheerfully report perfection.

Test stock settings first; only then repeat with battery optimisation disabled, to establish
whether a failure is fixable by onboarding guidance or not at all.

Per-phase checklists are in `docs/testing/device-matrix.md`. **The physical device rows there are
a **POCO F3, Android 13 / API 33, Xiaomi HyperOS 1.0** — the owner's own phone, and the harshest
mainstream OEM for background work.**

**Test stock settings first.** On MIUI/HyperOS, Autostart is off and per-app battery saving is
restricted by default for a sideloaded app, and that default state is what real users are in.
Record what breaks stock, *then* relax the settings and re-run; the difference between the two
passes is the finding, and it decides whether onboarding must walk a family through Autostart or
whether ARCHITECTURE.md §9's scheduled-function escape hatch has to be un-deferred.

Record one row per device per phase in that phase's summary: Android version, OEM skin and version,
whether power settings were stock, and what actually happened. A checklist that only records passes
is not evidence — the failures are the findings.

If OEM alarm reliability proves worse than the design assumes, that is the trigger for
un-deferring the scheduled server-side function (ARCHITECTURE.md §9). The data model already
supports it with no migration.

## Deliberately not doing

No CI yet · no coverage target — percentage coverage of a codebase whose risk sits in six pure
functions measures the wrong thing; cover the list above completely instead · no integration test
against the live Firebase project — the emulator answers the same questions without touching
production data.
