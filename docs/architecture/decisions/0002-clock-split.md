# ADR-0002 — Split the clock, and cache the device timezone on disk

**Date:** 2026-08-15 · **Status:** Accepted
**Phase:** 0 (found at the Phase 0 gate; implemented in Phases 1–3)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §4, §5, §6, §11 · refines
[ADR-0001](0001-away-cache-precedence.md)

## Context

§6 listed one component for everything clock-shaped:

```
| ClockService | Platform | Device tz; device-vs-server skew detection | UI |
```

But §10 step 1 requires the **alarm isolate** to compute `D`, the most recently completed
calendar day in the watched person's timezone, and [ADR-0001](0001-away-cache-precedence.md)
added a staleness comparison and a `lastReconcileAt` stamp on the same path. §12 goes further:
away expiry is arithmetic that "every `reconcile()` on every device" performs. Three of the four
entry points — alarm, FCM background, and the `BOOT_COMPLETED` reconcile — need to know what time
it is, and §6 granted that to the one isolate that is not running.

**The row was wrong because it was two things.** They have genuinely different requirements:

| Responsibility | Needs | Isolates |
|---|---|---|
| What instant is it now | `DateTime.now()` — core Dart, no plugin | all three |
| What is the device's IANA zone | `flutter_timezone` — a **plugin** | UI |
| Is the device clock skewed against the server | a server round-trip, and §11 scopes it to *"on app open while online"* | UI only |

"UI" was correct for skew detection and wrong for reading the current instant.

**What makes the fix cheap.** Computing `D` needs no plugin at all. The current instant is core
Dart; the relevant zone is the **watched person's**, which §7 already denormalises onto the link
so a watcher never reads another user's document; and `package:timezone` is pure Dart with a
compiled-in database. `flutter_timezone` is only needed to *discover* the device's own zone —
which is a UI-side question whose answer can be written to disk, exactly as §4 already mandates
for everything a background isolate needs.

Chasing this exposed three further gaps in §6's `LocalStore` field list, all on the same row:
`watchedTimezone` was absent (so `D` was not computable from disk alone, which §10's offline
branch requires), the device's own zone was absent, and `lastReconcileAt` — introduced by
ADR-0001 — was under-specified as to type.

## Decision

**1. Split the component in two.**

| Component | Layer | Responsibility | Isolates |
|---|---|---|---|
| `Clock` | Platform edge | The current instant. Trivial, plugin-free. | **All three** |
| `ClockService` | Platform | Discover the device's IANA zone → write it to `LocalStore` on resume; device-vs-server skew detection | UI |

`Clock` is the single sanctioned place the real clock is read, in whichever isolate. The domain
layer still takes `now` as an explicit parameter and never reads a clock — that rule is unchanged,
and this is what makes it satisfiable in a bare isolate.

**2. Background isolates never call `flutter_timezone`.** The UI writes the device's IANA zone
string to `LocalStore` on every resume; background isolates read it from disk, the same way they
read the per-link `watchedTimezone`.

**3. `LocalStore` gains three things:** `deviceTimezone`, per-link `watchedTimezone`, and
`lastReconcileAt` **as a full timestamp**, not a date — §10 renders *"offline since
10:14"* and a date cannot produce that. (Written as "step 5" when this ADR was accepted;
[ADR-0004](0004-refused-is-not-unreachable.md) renumbered §10, and the timestamp is now rendered by
the two offline branches. The claim is unchanged.)

**4. The staleness comparison stays calendar-day granular.** ADR-0001's "verified within 2 days"
compares the *date component* of `lastReconcileAt` against today, not a 48-hour duration. The
watcher's alarm attempts a reconcile once a day, so day granularity is the cadence the rule is
actually about; the timestamp exists for the message, not for the comparison.

## Consequences

**Bought.** The alarm and FCM isolates can compute `D`, the rolling window, away expiry, and the
ADR-0001 staleness test with **no plugin access at all** — only `DateTime.now()`, pure-Dart
`package:timezone`, and two strings from SQLite. That removes a whole class of
background-isolate failure (a missing plugin registrant) from the riskiest code in the app, and it
keeps `Reconciler` genuinely identical across all three isolates, which §6 calls "the payoff of
the layering".

**Paid.** A cached device zone can go stale if someone travels without opening the app. The
exposure is small and asymmetric:

- For the **watcher** it cannot affect `D` at all — `D` uses the *watched* person's zone from the
  link. Their own zone only sets when the alarm fires, and `zonedSchedule` handles that.
- For the **watched person** it sets the day id and the 12/18/21 reminder times, but they open the
  app daily to tap, so it refreshes daily. The worst case is one boundary day after a flight, and
  §11 already accepts midnight as a soft boundary.

**Reversing** costs a `LocalStore` migration for the two new fields. Nothing else.

**Rested on one assumption:** that `package:timezone` is pure Dart and needs no plugin registrant.
~~Confirm this when the dependency lands in Phase 1~~ — **CONFIRMED 2026-08-16, Phase 1**, on
`timezone` 0.11.1. Four independent checks, the last of which is the one that settles it:

- the package declares no `flutter:` section and does not depend on `flutter` — it is a plain Dart
  package, not a Flutter plugin;
- it ships no `android/` or `ios/` directory, and references neither `package:flutter` nor
  `MethodChannel` anywhere in `lib/`;
- adding it generated no `.flutter-plugins-dependencies` file;
- **after a full `flutter build apk --debug`, `GeneratedPluginRegistrant.java` contains zero
  registrations.** There is no registrant to be missing, so decision 2 stands as written.

One condition this ADR did not state, found while confirming it: **purity is a property of the
entry point, not of the package.** Only `timezone/timezone.dart` and `timezone/data/latest.dart`
are pure — the database is a compiled-in `dart:typed_data` blob. `timezone/standalone.dart` imports
`dart:io` and `dart:isolate` and reads tzdata from a *file*; `timezone/browser.dart` pulls
`package:http`. Importing `standalone.dart` would put `dart:io` on the alarm path and silently
re-open the failure this ADR closed. Both are named and banned in
`test/domain/domain_purity_test.dart`, which fails the build rather than relying on anyone
remembering.

## Alternatives considered

**Widen `ClockService` to all three isolates.** The one-cell edit. Rejected: it would drag skew
detection — which needs a server round-trip and is explicitly scoped to app-open in §11 — into a
bare isolate that has seconds to live, and it would leave `flutter_timezone` being called from a
background entry point for no reason.

**Call `flutter_timezone` from the background isolates.** Feasible with
`DartPluginRegistrant.ensureInitialized()`, and rejected: it adds a plugin dependency to the
alarm path purely to answer a question whose answer barely changes and is already known to the UI.
§4's whole thesis is that what a background isolate needs is on disk.

**Pass `now` in through the alarm callback's parameters.** `android_alarm_manager_plus` does hand
the callback a fire time. Rejected as a sole source: it is the *scheduled* time, not the actual
one, and a device that was asleep can deliver it late — using it as the current instant would
compute the wrong `D` precisely on the days that matter most.

**Make the staleness test duration-based (48 hours).** More precise, and rejected: it invites
off-by-a-few-hours behaviour that depends on what time of day the away was last verified, when
the underlying cadence is one alarm per day. Calendar days match the mechanism.
