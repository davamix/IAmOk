import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  // Early morning, so every slot of every day in the window is still pending.
  final now = at(madrid, 2026, 8, 17, 6);

  WatchedReconcileResult reconcile({
    AwayPeriod? away,
    Set<DayKey> checkedInDays = const {},
    Set<ScheduledReminder> currentlyScheduled = const {},
    DateTime? at,
    List<Link> links = const [],
  }) =>
      WatchedReconciler.reconcile(
        now: at ?? now,
        watchedZone: madrid,
        away: away,
        checkedInDays: checkedInDays,
        currentlyScheduled: currentlyScheduled,
        links: links,
      );

  Set<DayKey> daysIn(Set<ScheduledReminder> reminders) =>
      reminders.map((r) => r.day).toSet();

  group('the rolling window', () {
    test('covers 7 days counting today', () {
      final result = reconcile();
      expect(daysIn(result.desired), hasLength(7));
      expect(daysIn(result.desired).reduce((a, b) => a < b ? a : b),
          day('2026-08-17'));
      expect(daysIn(result.desired).reduce((a, b) => a > b ? a : b),
          day('2026-08-23'));
    });

    test('three reminders per day', () {
      expect(reconcile().desired, hasLength(21));
    });

    test('nothing runs at midnight — the window moves with now', () {
      final tomorrow = reconcile(at: at(madrid, 2026, 8, 18, 6));
      expect(daysIn(tomorrow.desired).contains(day('2026-08-24')), isTrue);
      expect(daysIn(tomorrow.desired).contains(day('2026-08-17')), isFalse);
    });
  });

  group('the window cancels as well as creates', () {
    test('a reminder outside the window is cancelled', () {
      final stale = ScheduledReminder(
        day: day('2026-08-10'),
        slot: ReminderSlot.midday,
        at: day('2026-08-10').at(ReminderSlot.midday.time, madrid),
      );
      final result = reconcile(currentlyScheduled: {stale});
      expect(result.toCancel, contains(stale));
      expect(result.toSchedule, isNot(contains(stale)));
    });

    test('a reminder for a day now checked in is cancelled', () {
      final result = reconcile(checkedInDays: days(['2026-08-17']));
      expect(daysIn(result.desired).contains(day('2026-08-17')), isFalse);
      expect(result.desired, hasLength(18));
    });
  });

  group('idempotence — every entry point calls the same function', () {
    test('reconciling against its own output is a no-op', () {
      final first = reconcile();
      expect(first.isNoOp, isFalse, reason: 'nothing was armed yet');

      final second = reconcile(currentlyScheduled: first.desired);
      expect(second.isNoOp, isTrue);
      expect(second.toSchedule, isEmpty);
      expect(second.toCancel, isEmpty);
      expect(second.desired, first.desired);
    });

    test('a third run changes nothing either', () {
      final desired = reconcile().desired;
      expect(reconcile(currentlyScheduled: desired).isNoOp, isTrue);
      expect(reconcile(currentlyScheduled: desired).isNoOp, isTrue);
    });
  });

  group('away — the window extends past through', () {
    final holiday =
        AwayPeriod(from: day('2026-08-18'), through: day('2026-08-25'));

    test('the away days are absent from the desired set', () {
      final desired = daysIn(reconcile(away: holiday).desired);
      for (var d = day('2026-08-18');
          d <= day('2026-08-25');
          d = d.next) {
        expect(desired.contains(d), isFalse, reason: '$d');
      }
    });

    test('the window extends to through + 7', () {
      // This is what lets the watched side stay display-only: the reminders for
      // the first days back are armed before the person leaves, so the app
      // re-arms itself without anyone opening it. A window stopping at
      // `through` leaves nothing scheduled after a holiday.
      final desired = daysIn(reconcile(away: holiday).desired);
      expect(desired.reduce((a, b) => a > b ? a : b), day('2026-09-01'),
          reason: 'through (25 Aug) + 7');
      for (var i = 1; i <= 7; i++) {
        expect(desired.contains(holiday.through.plusDays(i)), isTrue,
            reason: 'day $i back');
      }
    });

    test('days before the away period still get reminders', () {
      final desired = daysIn(reconcile(away: holiday).desired);
      expect(desired.contains(day('2026-08-17')), isTrue);
    });

    test('setting away mid-window cancels the reminders inside it', () {
      final before = reconcile();
      final after = reconcile(away: holiday, currentlyScheduled: before.desired);

      expect(after.toCancel, isNotEmpty);
      expect(daysIn(after.toCancel).every(holiday.covers), isTrue);
      expect(after.toSchedule, isNotEmpty,
          reason: 'the days after through are newly wanted');
      expect(daysIn(after.toSchedule).every((d) => d > holiday.through), isTrue);
    });

    test('cancelling away restores the reminders it suppressed', () {
      final duringAway = reconcile(away: holiday);
      final cancelled = holiday.cancelOn(day('2026-08-20'));
      final after =
          reconcile(away: cancelled, currentlyScheduled: duringAway.desired);

      // 20 Aug onward is no longer away, so those days are wanted again.
      expect(daysIn(after.toSchedule), contains(day('2026-08-20')));
      expect(daysIn(after.desired).contains(day('2026-08-18')), isFalse,
          reason: 'truncation keeps the elapsed away days covered');
    });

    test('a whole-window away leaves only the days after it', () {
      final long =
          AwayPeriod(from: day('2026-08-17'), through: day('2026-09-05'));
      final desired = daysIn(reconcile(away: long).desired);
      expect(desired.every((d) => d > long.through), isTrue);
      expect(desired, hasLength(7));
    });

    test('an away period entirely in the past does not extend the window', () {
      final past =
          AwayPeriod(from: day('2026-07-01'), through: day('2026-07-10'));
      expect(daysIn(reconcile(away: past).desired), hasLength(7));
      expect(daysIn(reconcile(away: past).desired).contains(day('2026-08-23')),
          isTrue);
    });
  });

  group('an absurd away document cannot reach the alarm path', () {
    final tenYears =
        AwayPeriod(from: day('2026-08-01'), through: day('9999-12-31'));

    test('the window is bounded, not derived from the stored `through`', () {
      // The window end comes from a REMOTE document and DayKey.through()
      // materialises the span eagerly, so an unclamped `through` in 9999
      // allocates ~2.9 million DayKeys inside a bare alarm isolate. Measured
      // before this clamp existed.
      final result = reconcile(away: tenYears);
      expect(daysIn(result.desired).length, lessThan(20));
      expect(daysIn(result.desired).reduce((a, b) => a > b ? a : b),
          lessThan(day('2027-01-01')));
    });

    test('reminders resume past the sanity bound', () {
      // Defending only the watcher side produces the worst state of all: she is
      // never nudged to tap, and her family is warned every day.
      final resumed = ReminderPolicy.remindersFor(
        day: day('2026-10-05'),
        away: tenYears,
        checkedIn: false,
        now: at(madrid, 2026, 10, 5, 6),
        watchedZone: madrid,
      );
      expect(resumed, isNotEmpty,
          reason: 'past from + 59 the stored period is not honoured');
      expect(tenYears.coversAsStored(day('2026-10-05')), isTrue,
          reason: 'the premise: the document does claim that day');
    });

    test('days inside the bound are still suppressed', () {
      expect(
        ReminderPolicy.remindersFor(
          day: day('2026-08-15'),
          away: tenYears,
          checkedIn: false,
          now: at(madrid, 2026, 8, 15, 6),
          watchedZone: madrid,
        ),
        isEmpty,
      );
    });
  });

  test('a window spanning a DST transition keeps its wall-clock times', () {
    // The window starting 22 Oct crosses Madrid's 25 Oct fall-back. If the span
    // were ever "simplified" to Duration(days: 1) arithmetic on the first
    // instant — the exact bug DayKey's doc comment warns about — every reminder
    // after the transition would drift by an hour and nothing else would notice.
    final result = WatchedReconciler.reconcile(
      now: at(madrid, 2026, 10, 22, 6),
      watchedZone: madrid,
      away: null,
      checkedInDays: const {},
      currentlyScheduled: const {},
      links: const [],
    );
    expect(daysIn(result.desired), contains(day('2026-10-26')),
        reason: 'the window really does cross the transition');
    expect(
      result.desired.every((r) => r.at.hour == r.slot.time.hour),
      isTrue,
      reason: '12/18/21 local on both sides of the change',
    );
  });

  test('a changed watched timezone rebuilds the window', () {
    // ADR-0002 accepts a stale cached device zone on the grounds that the worst
    // case is one boundary day after a flight. That promise only holds if the
    // diff notices the instants moved when the zone is refreshed — otherwise
    // the reminders keep firing at the old local time indefinitely and isNoOp
    // reports true while there is real work to do.
    final inMadrid = WatchedReconciler.reconcile(
      now: now,
      watchedZone: madrid,
      away: null,
      checkedInDays: const {},
      currentlyScheduled: const {},
      links: const [],
    );
    final movedToNewYork = WatchedReconciler.reconcile(
      now: now,
      watchedZone: newYork,
      away: null,
      checkedInDays: const {},
      currentlyScheduled: inMadrid.desired,
      links: const [],
    );

    expect(movedToNewYork.isNoOp, isFalse);
    expect(movedToNewYork.toCancel, hasLength(21));
    expect(movedToNewYork.toSchedule, isNotEmpty);
    expect(
      movedToNewYork.desired.every((r) => r.at.hour == r.slot.time.hour),
      isTrue,
      reason: 'the new instants are the named wall-clock times in New York',
    );
  });

  test('the window is computed in the watched zone', () {
    // 23:30 Madrid on the 17th is already the 18th in Auckland, so the first
    // day of the window differs. Using the device's own zone for a watched
    // person abroad would arm the wrong days.
    final result = WatchedReconciler.reconcile(
      now: at(madrid, 2026, 8, 17, 23, 30),
      watchedZone: auckland,
      away: null,
      checkedInDays: const {},
      currentlyScheduled: const {},
      links: const [],
    );
    expect(daysIn(result.desired).reduce((a, b) => a < b ? a : b),
        day('2026-08-18'));
  });
}
