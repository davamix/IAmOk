import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  final today = day('2026-08-17');

  List<ReminderSlot> slotsFor({
    AwayPeriod? away,
    bool checkedIn = false,
    DateTime? now,
    DayKey? on,
  }) =>
      ReminderPolicy.remindersFor(
        day: on ?? today,
        away: away,
        checkedIn: checkedIn,
        now: now ?? at(madrid, 2026, 8, 17, 8),
        watchedZone: madrid,
      ).map((r) => r.slot).toList();

  group('the three slots', () {
    test('are 12:00, 18:00 and 21:00 watched-local', () {
      expect(ReminderSlot.midday.time, const LocalTimeOfDay(12, 0));
      expect(ReminderSlot.evening.time, const LocalTimeOfDay(18, 0));
      expect(ReminderSlot.night.time, const LocalTimeOfDay(21, 0));
    });

    test('all three are wanted early in the day', () {
      expect(slotsFor(), ReminderSlot.values);
    });

    test('fire at the right wall-clock time in the watched zone', () {
      final reminders = ReminderPolicy.remindersFor(
        day: today,
        away: null,
        checkedIn: false,
        now: at(madrid, 2026, 8, 17, 8),
        watchedZone: madrid,
      );
      expect(reminders.map((r) => r.at.hour), [12, 18, 21]);
      expect(reminders.every((r) => r.at.day == 17), isTrue);
    });
  });

  group('elapsed slots are not desired', () {
    test('a slot already past is dropped', () {
      expect(slotsFor(now: at(madrid, 2026, 8, 17, 13)),
          [ReminderSlot.evening, ReminderSlot.night]);
      expect(slotsFor(now: at(madrid, 2026, 8, 17, 19)), [ReminderSlot.night]);
      expect(slotsFor(now: at(madrid, 2026, 8, 17, 22)), isEmpty);
    });

    test('a slot exactly at now is past, not pending', () {
      expect(slotsFor(now: at(madrid, 2026, 8, 17, 12)),
          [ReminderSlot.evening, ReminderSlot.night],
          reason: 'scheduling for this instant is at best a no-op');
    });

    test('a future day keeps all three whatever the time now is', () {
      expect(
        slotsFor(on: day('2026-08-18'), now: at(madrid, 2026, 8, 17, 22)),
        ReminderSlot.values,
      );
    });
  });

  group('a tap cancels the rest of the day', () {
    test('no reminders once the day is checked in', () {
      expect(slotsFor(checkedIn: true), isEmpty);
    });

    test('even first thing in the morning', () {
      expect(slotsFor(checkedIn: true, now: at(madrid, 2026, 8, 17, 0, 5)),
          isEmpty);
    });
  });

  group('away suppresses reminders — the away argument from the first line', () {
    // Starts tomorrow, so both edges of the period are in the future and an
    // empty result can only mean away — never merely that the slots elapsed.
    final holiday =
        AwayPeriod(from: day('2026-08-18'), through: day('2026-08-20'));

    test('null away — every production call site until Phase 6', () {
      expect(slotsFor(away: null), ReminderSlot.values);
    });

    test('a covered day has no reminders', () {
      expect(slotsFor(away: holiday, on: day('2026-08-19')), isEmpty);
    });

    test('the day from starts and the day through ends are both covered', () {
      expect(slotsFor(away: holiday, on: day('2026-08-18')), isEmpty);
      expect(slotsFor(away: holiday, on: day('2026-08-20')), isEmpty);
    });

    test('the day before from and the day after through are not', () {
      expect(slotsFor(away: holiday, on: day('2026-08-17')),
          ReminderSlot.values);
      expect(slotsFor(away: holiday, on: day('2026-08-21')),
          ReminderSlot.values);
    });

    test('an unrelated away period does not suppress', () {
      final past =
          AwayPeriod(from: day('2026-07-01'), through: day('2026-07-10'));
      expect(slotsFor(away: past), ReminderSlot.values);
    });
  });

  group('identity includes the instant', () {
    ScheduledReminder first({required tzZone, DateTime? now}) =>
        ReminderPolicy.remindersFor(
          day: today,
          away: null,
          checkedIn: false,
          now: now ?? at(madrid, 2026, 8, 17, 8),
          watchedZone: tzZone,
        ).first;

    test('the same day, slot and zone is the same alarm', () {
      final a = first(tzZone: madrid, now: at(madrid, 2026, 8, 17, 8));
      final b = first(tzZone: madrid, now: at(madrid, 2026, 8, 17, 9));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });

    test('the same day and slot in a DIFFERENT zone is a different alarm', () {
      // The watched person flies Madrid -> New York. `at` is a pure function of
      // (day, slot, zone), so it differs only when the zone genuinely changed —
      // which is exactly when the alarm must be rebuilt. If identity excluded
      // the instant, the diff would be empty and the reminders would go on
      // firing at 06:00 local. §3 names "timezone change" as one of the seven
      // cases reconcile() is supposed to collapse.
      final madridNoon = first(tzZone: madrid);
      final newYorkNoon = first(tzZone: newYork);

      expect(madridNoon.day, newYorkNoon.day);
      expect(madridNoon.slot, newYorkNoon.slot);
      expect(madridNoon, isNot(newYorkNoon));
      expect({madridNoon, newYorkNoon}, hasLength(2));
    });
  });

  test('across a DST transition the wall-clock times hold', () {
    // 2026-10-25, the day Madrid gains an hour. All three still fire at their
    // named local times; a stored UTC offset would drift by an hour.
    final reminders = ReminderPolicy.remindersFor(
      day: day('2026-10-25'),
      away: null,
      checkedIn: false,
      now: at(madrid, 2026, 10, 25, 6),
      watchedZone: madrid,
    );
    expect(reminders.map((r) => r.at.hour), [12, 18, 21]);
  });
}
