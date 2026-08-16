import 'package:timezone/timezone.dart' as tz;

import '../away/away_period.dart';
import '../time/day_key.dart';
import '../time/local_time_of_day.dart';

/// The three daily nudges on the watched side (ARCHITECTURE.md §10).
enum ReminderSlot {
  midday(LocalTimeOfDay(12, 0)),
  evening(LocalTimeOfDay(18, 0)),
  night(LocalTimeOfDay(21, 0));

  const ReminderSlot(this.time);

  /// Watched-person-local wall-clock time.
  final LocalTimeOfDay time;
}

/// One reminder that should exist.
///
/// Equality covers the **instant as well as** `(day, slot)`. Excluding [at]
/// looks like it avoids churn, but [at] is a pure function of `(day, slot,
/// zone)` — so it differs only when the zone genuinely changed, which is
/// exactly when the alarm must be rebuilt. With [at] excluded, a watched person
/// who flies Madrid → New York produces an empty diff: the reminders keep
/// firing at 06:00 local and `isNoOp` reports true. §3 names "timezone change"
/// as one of the seven cases the single `reconcile()` is supposed to collapse.
///
/// The platform alarm/notification **id** stays derived from `(day, slot)` in
/// Phase 3, so a moved reminder is a replacement rather than a duplicate. That
/// makes the diff order-sensitive: **apply `toCancel` before `toSchedule`**, or
/// a same-id cancel will undo the reschedule that preceded it.
class ScheduledReminder {
  const ScheduledReminder({
    required this.day,
    required this.slot,
    required this.at,
  });

  final DayKey day;
  final ReminderSlot slot;

  /// The instant the reminder fires, in the watched person's zone.
  ///
  /// A zoned instant, never a raw UTC offset: `zonedSchedule` needs this to
  /// handle DST, and an offset captured today is wrong after the next
  /// transition (§11).
  final tz.TZDateTime at;

  @override
  bool operator ==(Object other) =>
      other is ScheduledReminder &&
      other.day == day &&
      other.slot == slot &&
      other.at == at;

  @override
  int get hashCode => Object.hash(day, slot, at);

  @override
  String toString() => 'ScheduledReminder($day ${slot.name} @ $at)';
}

/// Which of 12:00 / 18:00 / 21:00 should exist for a given day.
///
/// Display-only alarms: a false fire costs nothing — a redundant "remember to
/// tap" — so this side never verifies before speaking. That asymmetry with
/// [WarningPolicy][] is deliberate and is what lets the watched side stay
/// display-only (§10).
///
/// [WarningPolicy]: ../policy/warning_policy.dart
abstract final class ReminderPolicy {
  /// The reminders that should exist for [day].
  ///
  /// - Away suppresses all three (§12). Tapping during an away day is still
  ///   **allowed** — that is the repository's business, not this policy's; the
  ///   plausible bug is suppressing the write along with the reminders.
  /// - A check-in already recorded for [day] cancels the rest of that day.
  ///   This is the memory-safety half of the design: the write is idempotent,
  ///   but being nudged after you have already tapped is exactly the training
  ///   this app must avoid.
  /// - Slots whose instant has already passed are not desired. Scheduling into
  ///   the past is at best a no-op and at worst an immediate spurious fire.
  ///
  /// [away] is a parameter from the first line even though away mode is not
  /// built until Phase 6 and every production call site passes null until then.
  /// Retrofitting it later would mean touching every call site and every test
  /// written in between (PLAN.md, Phase 1, non-negotiable).
  static List<ScheduledReminder> remindersFor({
    required DayKey day,
    required AwayPeriod? away,
    required bool checkedIn,
    required DateTime now,
    required tz.Location watchedZone,
  }) {
    if (away != null && away.covers(day)) return const [];
    if (checkedIn) return const [];

    return [
      for (final slot in ReminderSlot.values)
        if (day.at(slot.time, watchedZone).isAfter(now))
          ScheduledReminder(
            day: day,
            slot: slot,
            at: day.at(slot.time, watchedZone),
          ),
    ];
  }
}
