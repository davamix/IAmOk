import 'package:timezone/timezone.dart' as tz;

import 'local_time_of_day.dart';

/// A calendar day — a *label*, not an instant.
///
/// `2026-08-15` is the id of a check-in document (ARCHITECTURE.md §7), the unit
/// away periods are expressed in (§12), and the `D` the watcher warning
/// reasons about (§10). It is deliberately not a `DateTime`: the same label
/// denotes a different span of real time in every zone, and conflating the two
/// is how a check-in lands on the wrong day.
///
/// The day this label refers to is decided **on the device, at tap time**, from
/// the device clock in the device's zone — never from `serverTimestamp()`,
/// which resolves when the write reaches the server and would file a 23:50 tap
/// that synced at 08:00 on the following day (§11).
///
/// ### Why arithmetic goes through UTC
///
/// Every UTC day is exactly 86 400 seconds, so `plusDays` is exact. A local day
/// is 23 or 25 hours twice a year, so doing the same arithmetic by adding
/// `Duration(days: 1)` to a zoned instant drifts across a DST boundary. The
/// label moves in UTC; only [startOfDay] and [at] ever touch a real zone.
class DayKey implements Comparable<DayKey> {
  DayKey._(this._midnightUtc);

  /// The day `year-month-day`. Out-of-range components normalise the way
  /// `DateTime.utc` normalises them — `DayKey(2026, 13, 1)` is 2027-01-01.
  factory DayKey(int year, int month, int day) =>
      DayKey._(DateTime.utc(year, month, day));

  /// The calendar day that contains [instant] in [zone].
  ///
  /// This is the only place an instant becomes a day, and it is why the zone is
  /// always explicit. Passing the *watcher's* zone where the *watched person's*
  /// belongs is the mistake this signature exists to make visible.
  factory DayKey.fromInstant(DateTime instant, tz.Location zone) {
    final local = tz.TZDateTime.from(instant, zone);
    return DayKey(local.year, local.month, local.day);
  }

  /// Parses the `YYYY-MM-DD` document-id form.
  ///
  /// Strict, and round-trip checked: `2026-02-30` and `2026-8-15` are both
  /// rejected rather than normalised into a day nobody wrote.
  factory DayKey.parse(String iso) {
    final parsed = tryParse(iso);
    if (parsed == null) {
      throw FormatException('not a YYYY-MM-DD calendar day', iso);
    }
    return parsed;
  }

  /// [DayKey.parse], returning null instead of throwing.
  static DayKey? tryParse(String iso) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
    if (match == null) return null;
    final key = DayKey(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    // Rejects 2026-02-30, which DateTime.utc would silently roll to March 2nd.
    return key.toString() == iso ? key : null;
  }

  /// Midnight UTC on this day. Private: exposing it invites `.toLocal()`, which
  /// is an implicit read of a zone this design always states explicitly.
  final DateTime _midnightUtc;

  int get year => _midnightUtc.year;
  int get month => _midnightUtc.month;
  int get day => _midnightUtc.day;

  DayKey plusDays(int days) =>
      DayKey._(_midnightUtc.add(Duration(days: days)));

  DayKey minusDays(int days) =>
      DayKey._(_midnightUtc.subtract(Duration(days: days)));

  DayKey get next => plusDays(1);
  DayKey get previous => minusDays(1);

  /// Whole days from [other] to this day. Positive when this day is later.
  int differenceInDays(DayKey other) =>
      _midnightUtc.difference(other._midnightUtc).inDays;

  /// The instant this day begins in [zone].
  tz.TZDateTime startOfDay(tz.Location zone) =>
      tz.TZDateTime(zone, year, month, day);

  /// The instant [time] falls at on this day in [zone].
  ///
  /// On a spring-forward day the named wall-clock time may not exist; the
  /// `timezone` package resolves it to the adjacent valid instant rather than
  /// throwing. None of this app's fixed times — 12:00, 18:00, 21:00, and a
  /// default warning at 10:00 — sit anywhere near a transition, so this is a
  /// documented edge rather than a live one.
  tz.TZDateTime at(LocalTimeOfDay time, tz.Location zone) =>
      tz.TZDateTime(zone, year, month, day, time.hour, time.minute);

  /// Every day from this one through [last], inclusive. Empty if [last] is
  /// earlier.
  List<DayKey> through(DayKey last) {
    final span = last.differenceInDays(this);
    if (span < 0) return const [];
    return [for (var i = 0; i <= span; i++) plusDays(i)];
  }

  @override
  int compareTo(DayKey other) => _midnightUtc.compareTo(other._midnightUtc);

  bool operator <(DayKey other) => compareTo(other) < 0;
  bool operator <=(DayKey other) => compareTo(other) <= 0;
  bool operator >(DayKey other) => compareTo(other) > 0;
  bool operator >=(DayKey other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is DayKey && other._midnightUtc == _midnightUtc;

  @override
  int get hashCode => _midnightUtc.hashCode;

  /// The `YYYY-MM-DD` form. This *is* the Firestore document id (§7), so it is
  /// a contract, not a display convenience.
  @override
  String toString() => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// The most recently **completed** calendar day in [zone] as of [now].
///
/// ARCHITECTURE.md §10 step 1. The watcher's alarm fires at *watcher-local*
/// time but asks about the last completed *watched-local* day, so [zone] is
/// always the watched person's — which is why §7 denormalises it onto the link.
DayKey lastCompletedDay(DateTime now, tz.Location zone) =>
    DayKey.fromInstant(now, zone).previous;
