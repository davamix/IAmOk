# Testing strategy

**Date:** 2026-08-15 · **Status:** Current · Expands
[ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §14. No tests exist yet beyond the scaffolded
`test/widget_test.dart`.

## The idea this whole strategy rests on

Every hard decision in this app — what day is it, should a reminder exist, should we warn, is this
day inside an away period, is this a correction — lives in the **domain layer as a pure function
over explicit inputs**. No `DateTime.now()`, no plugin calls, no I/O. The layers above supply
inputs and execute the result.

That is not an aesthetic preference. It is what makes the riskiest logic in this app — all of it
time-dependent, all of it running in bare background isolates — testable in milliseconds with no
device and no network. If a test needs a device to answer a question about *logic*, the logic is in
the wrong layer. That is the single most useful review question to ask about any pull of code here.

---

## The levels

| Level | Covers | Tool | Runs |
|---|---|---|---|
| **Unit** | `DayKey`, `AwayPeriod`, `ReminderPolicy`, `WarningPolicy`, `Reconciler`, correction logic, permission→health derivation | plain `test` — no Flutter, no device | Every change |
| **Repository** | Firestore reads/writes, offline queue behaviour | `fake_cloud_firestore` | Every change |
| **Local store** | `LocalStore` round-trips — `lastConfirmedDate`, `warningsShownFor`, cached away, `pendingAlarms` | `sqflite_common_ffi`, in-memory | Every change |
| **Rules + Functions** | The access matrix, away write validation, the `redeemInvite` transaction | Firebase Emulator Suite, `@firebase/rules-unit-testing` | Every change to rules or Functions |
| **Widget** | Screen states, especially the disabled-after-tap state | `flutter_test` | Every UI change |
| **Device** | Notification delivery, alarm survival, OEM battery behaviour | **Real hardware. Irreducible.** | Every phase with a device-facing exit criterion |

```powershell
flutter analyze
flutter test
```

---

## Time is injected, never read

`DateTime.now()` does not appear in the domain layer, and does not appear in a policy or the
reconciler at any layer. **The clock is a parameter.** Reading the real clock happens only at the
platform edge, through `ClockService`, and the value is then passed in.

This is the rule that makes the away-mode and day-boundary tests possible at all, and the one most
likely to be broken by a well-meaning shortcut. It is worth failing a review over.

> **Open, and owed a decision before Phase 3.** ARCHITECTURE.md §6 lists `ClockService` as a **UI**
> isolate component, but §10 requires the alarm isolate to compute `D` — the most recently
> completed watched-local day — which needs a clock in a bare isolate. Either §6's isolate column
> widens, or the alarm entry point gets a sanctioned way to read the clock at its own edge. The
> rule above is unaffected either way; only the location of the one legitimate read is open.

## Give the policies their `away` argument from the first line

`ReminderPolicy` and `WarningPolicy` take an `away` argument in Phase 1, **while it is still always
null**. Away mode is not built until Phase 6, but retrofitting the parameter later means touching
every call site and every test written in between.

## Test the denied case

For rules, an assertion that the allowed case works proves nothing on its own. Every row of the
access matrix needs both halves — allowed succeeds, denied is **denied**. Same for the policies:
assert the silent cases as hard as the firing ones. This app's worst bug is something firing when
it should not.

---

## What must be covered, explicitly

Not a wish list — these are the cases where this design is known to be able to go wrong.

**Day boundaries** — a tap at 00:05 and at 23:55; a watcher in a different timezone from the
watched person around both edges; DST transitions in both directions; a device whose timezone
changes mid-period. Assert the **soft midnight boundary** as an outcome, not just as an input: a
tap at 00:05 Monday and 23:55 Tuesday leaves both days green, and that is intended (§11).

**The day id comes from the device clock** — not from `serverTimestamp()`. A tap queued offline at
23:50 and synced at 08:00 the next morning still lands on the **earlier** day. This is the §17
"High — silently wrong data" risk, and the test is what stops someone "simplifying" it back to a
server timestamp in Phase 4. Alongside it: `deviceTappedAt` is the client clock and `receivedAt` is
the server timestamp, and clock drift beyond threshold is **surfaced, never silently corrected**.

**Away edges** — the day `from` starts; the day `through` ends; the day *after* `through`; away set
mid-period; away cancelled while a device was offline; away expiring on a device that has not been
online since it started; `through < from` rejected; a 31-day period rejected; a retroactive `from`
rejected. Also: **tapping during an away day is still allowed** and writes a normal check-in that
watchers see as usual (§12) — the plausible bug is suppressing the write along with the reminders.

**The rolling window** — pure `Reconciler` logic, and currently the largest untested surface. The
desired set is 7 days, **extending to `through` + 7 during an away period with the away days
absent**. Assert that the window *cancels* what should not exist as well as creating what is
missing, and that it extends past `through` — if it does not, nothing is armed for the days after a
holiday and the watched side never re-arms, which is the whole reason that side can stay
display-only (§10).

**The correction path** — the highest-value thing in the suite. A warning shown for day `D`,
then a check-in for `D` arrives late (offline sync, or FCM deferred until morning). The warning
must be *replaced* by the correction, `lastConfirmedDate` updated, and `D` removed from
`warningsShownFor`. One handler covers both causes; test both causes.

**Notification identity across links** — a watcher has `1..n` watched people and the id is
`hash(link, D)`. With warnings standing for two people on the same `D`, a correction for one must
leave the other's notification and its `warningsShownFor` entry untouched.

**Warning suppression** — before `link.activeFrom`; inside an away period; when the local cache
already has the day; when Firestore has the day but the cache does not.

**The away-cache precedence rules** — [ADR-0001](../architecture/decisions/0001-away-cache-precedence.md),
and the reason it exists. The runnable model at
[`tools/models/away_warning_model.dart`](../../tools/models/away_warning_model.dart) carries all 18
cases; port them, they are the specification:

- cache says away, Firestore says **cancelled**, online → **warn** (the defect the ADR fixed)
- cache says away, Firestore says **shortened**, online → warn for the days now outside
- cache says away, offline, verified **within** 2 days → silent
- cache says away, offline, **stale** → the distinct unverifiable-away message
- cache says away, stale, **but `lastConfirmedDate >= D`** → silent. Evidence outranks doubt
- **online but the read FAILED** (timeout, permission denied, App Check) → the cache must **not**
  be cleared, and a live away must still silence. This is the trap: connectivity is not success
- cancelling truncates — the elapsed away days stay covered and must not produce a warning
- cancelling on the day the period *starts* deletes instead, and `through >= from` never breaks

**The offline warning** — when Firestore is unreachable the message is *different*, and honest.
There are now **three** distinct outcomes and the test must assert on which one fired, never
merely that something did: plain warning, offline warning, and unverifiable-away.

**The push carries no authority** — reconcile with a synthetic FCM payload for `D`, Firestore
unreachable and the cache empty, must leave `lastConfirmedDate` unchanged. The payload carries
`{watchedUid, date, deviceTappedAt, tz, watchedName}` and looks authoritative, which is exactly why
trusting it is the tempting shortcut (§3).

**Idempotence of `reconcile()`** — running it twice in a row produces no second alarm, no second
notification, and no changed state. Every entry point calls the same function; if it is not
idempotent, boot recovery is a duplicate-notification bug.

**The date is the document id** — a second tap on the same day is an *update*, so it does not fire
`onDocumentCreated` and produces no duplicate push. §7 calls this load-bearing and says there is no
dedupe logic anywhere, which makes it worth an explicit test rather than an assumption.

**Permissions and health** — the derivation from a set of permission booleans to an overall verdict
and a remediation is pure logic and belongs in the unit level. The failure it guards against is a
health panel reporting green while `POST_NOTIFICATIONS` is revoked, i.e. the app silently inert.
§17 rates auto-revoke **High**, "exactly the mode this app can't afford".

**Away transition notifications** — four messages with per-recipient filtering (§12), including
"everyone **except** whoever cancelled". Easy to notify the actor, or to miss the watched person.
The "ends tomorrow" notice is scheduled locally from `through` with no server involved.

**`redeemInvite`** — expired code rejected; already-consumed code rejected; redeeming twice is
idempotent via the deterministic link id; and `activeFrom` set to today **in the watched person's
timezone, not the redeemer's** — the `activeFrom` suppression above depends on that being right.

**`UNREGISTERED` token pruning** — pruning the wrong token silences a watcher permanently. A silent
failure, and cheap to test on the emulator.

---

## Real hardware, and what only it can tell you

Phases 2 and 3 have device exit criteria on purpose, early in the plan rather than late, because
this is the risk that could invalidate the whole design.

Nothing but a real phone answers: do alarms and data-only FCM survive on Xiaomi / Samsung / Huawei
with **stock power settings**? Do alarms survive a reboot? Does the 7-day rolling window re-arm
without anyone opening the app?

**The debug harness is what makes any of this affordable.** Force the current date, fire any alarm
now, inject a synthetic FCM payload, dump `LocalStore`, run `reconcile()` on demand. It is a Phase
2 deliverable and ARCHITECTURE.md §14 is explicit that it gets built *alongside* the first alarm,
not after — without it, verifying a 24-hour behaviour takes 24 hours. Treat it as a gate item, not
a nice-to-have.

The device matrix and the manual checklist live in [device-matrix.md](device-matrix.md).

**This is the trigger condition for un-deferring the scheduled server-side function**
([ARCHITECTURE.md](../architecture/ARCHITECTURE.md) §9). If OEM alarm reliability turns out worse
than the design assumes, that is the documented escape hatch — and the data model already supports
adding it with no migration.

## Not doing

- **No CI yet.** `flutter analyze` and `flutter test` are run locally. Worth adding when there is
  something to protect; noted so its absence is a decision rather than an oversight.
- **No coverage target.** Percentage coverage of a codebase whose risk is concentrated in six pure
  functions would measure the wrong thing. Cover the list above completely instead.
- **No integration test driving the real Firebase project.** The emulator answers the same
  questions without touching production data.
