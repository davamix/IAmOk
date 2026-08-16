/// The current instant — the **one sanctioned place the real clock is read**,
/// in whichever isolate ([ADR-0002][] decision 1).
///
/// Deliberately trivial, and deliberately **plugin-free**. §6 splits this from
/// `ClockService` because their isolate requirements differ: reading the current
/// instant is core Dart and is needed in all three isolates, while discovering
/// the device's IANA zone is a `flutter_timezone` call and skew detection needs
/// a server round-trip, both of which §11 scopes to the UI. Only the first
/// belongs in a bare isolate with seconds to live.
///
/// The domain layer does **not** consume this. It takes `now` as an explicit
/// parameter and never reads a clock — that rule is unchanged, and this is what
/// makes it satisfiable inside an alarm callback: the entry point reads the
/// clock once and passes the value down.
///
/// [ADR-0002]: ../../docs/architecture/decisions/0002-clock-split.md
abstract interface class Clock {
  /// The current instant, **in UTC**.
  ///
  /// UTC rather than a device-local `DateTime` on purpose. Everything
  /// downstream converts through an explicit zone — `DayKey.fromInstant(now,
  /// watchedZone)` — and a local `DateTime` arriving there carries an implicit
  /// zone that is never the right one to reason from. It is the same hazard the
  /// domain's purity guard bans `.toLocal(` for, caught one layer earlier.
  DateTime now();
}

/// The real clock.
///
/// [offset] exists for the debug harness's *force the current date*, which
/// ARCHITECTURE.md §14 requires and which the phase brief says to build
/// **alongside the first alarm rather than after it** — without it, verifying a
/// 24-hour behaviour takes 24 hours.
///
/// It is an offset rather than a fixed instant because time must keep moving
/// while a date is forced: an alarm scheduled two minutes into a forced future
/// still has to arrive. A frozen clock would make every scheduled instant
/// permanently in the past or permanently in the future, which tests nothing
/// the real app does.
///
/// **The offset is persisted in `LocalStore`, not held here.** All three
/// isolates must agree on what day it is, and §4's rule is that anything a
/// background isolate needs is on disk. The entry point reads the stored offset
/// and constructs this; `Clock` itself touches no storage, which is what keeps
/// the Platform edge from depending on the Data layer (§5 — they are peers).
class SystemClock implements Clock {
  const SystemClock({this.offset = Duration.zero});

  /// Added to the real instant. Zero in every release build.
  final Duration offset;

  @override
  DateTime now() => DateTime.now().toUtc().add(offset);

  /// The offset that would make [now] read [target].
  ///
  /// What the debug harness's date picker computes. Kept here so the harness
  /// does not do clock arithmetic of its own.
  static Duration offsetTo(DateTime target) =>
      target.toUtc().difference(DateTime.now().toUtc());

  @override
  String toString() =>
      offset == Duration.zero ? 'SystemClock()' : 'SystemClock(+$offset)';
}

/// A clock frozen at one instant. Tests only.
///
/// Not used for the debug harness — see [SystemClock.offset] for why a forced
/// date still has to tick.
class FixedClock implements Clock {
  FixedClock(this.instant);

  DateTime instant;

  @override
  DateTime now() => instant.toUtc();

  @override
  String toString() => 'FixedClock($instant)';
}
