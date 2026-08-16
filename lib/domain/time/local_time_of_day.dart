/// A wall-clock time of day, with no date and no zone attached.
///
/// This is `link.warningLocalTime` ("10:00") and the three reminder slots
/// (12:00 / 18:00 / 21:00). It becomes an instant only when a [DayKey] and a
/// zone are supplied — which is what keeps DST out of the stored value.
class LocalTimeOfDay implements Comparable<LocalTimeOfDay> {
  const LocalTimeOfDay(this.hour, this.minute)
      : assert(hour >= 0 && hour <= 23, 'hour must be 0..23'),
        assert(minute >= 0 && minute <= 59, 'minute must be 0..59');

  /// Parses the `HH:mm` form stored on a link (ARCHITECTURE.md §7).
  ///
  /// Strict: `9:00`, `10:0` and `24:00` are all rejected, because a lenient
  /// parser here would silently reschedule someone's warning alarm.
  factory LocalTimeOfDay.parse(String hhmm) {
    final parsed = tryParse(hhmm);
    if (parsed == null) {
      throw FormatException('not a HH:mm time of day', hhmm);
    }
    return parsed;
  }

  /// [LocalTimeOfDay.parse], returning null instead of throwing.
  static LocalTimeOfDay? tryParse(String hhmm) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(hhmm);
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return LocalTimeOfDay(hour, minute);
  }

  final int hour;
  final int minute;

  /// Minutes since local midnight. Ordering only — not a duration on a DST day.
  int get minutesFromMidnight => hour * 60 + minute;

  @override
  int compareTo(LocalTimeOfDay other) =>
      minutesFromMidnight.compareTo(other.minutesFromMidnight);

  bool operator <(LocalTimeOfDay other) => compareTo(other) < 0;
  bool operator <=(LocalTimeOfDay other) => compareTo(other) <= 0;
  bool operator >(LocalTimeOfDay other) => compareTo(other) > 0;
  bool operator >=(LocalTimeOfDay other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is LocalTimeOfDay &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  /// The `HH:mm` form. Always 24-hour and zero-padded — this is the stored
  /// representation, not a display string.
  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
