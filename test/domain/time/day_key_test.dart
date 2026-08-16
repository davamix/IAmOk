import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  group('parsing and formatting', () {
    test('round-trips the YYYY-MM-DD document-id form', () {
      expect(DayKey.parse('2026-08-15').toString(), '2026-08-15');
      expect(DayKey(2026, 8, 5).toString(), '2026-08-05');
      expect(DayKey(2026, 12, 31).toString(), '2026-12-31');
    });

    test('rejects a day that does not exist rather than rolling it', () {
      // DateTime.utc(2026, 2, 30) is silently March 2nd. A document id nobody
      // wrote must not appear out of a parse.
      expect(DayKey.tryParse('2026-02-30'), isNull);
      expect(DayKey.tryParse('2026-13-01'), isNull);
      expect(() => DayKey.parse('2026-02-30'), throwsFormatException);
    });

    test('rejects unpadded and malformed input', () {
      for (final bad in ['2026-8-15', '26-08-15', '2026/08/15', '', 'today']) {
        expect(DayKey.tryParse(bad), isNull, reason: bad);
      }
    });

    test('accepts a real leap day and rejects a fake one', () {
      expect(DayKey.parse('2028-02-29').toString(), '2028-02-29');
      expect(DayKey.tryParse('2026-02-29'), isNull);
    });
  });

  group('arithmetic', () {
    test('crosses month, year and leap boundaries', () {
      expect(DayKey.parse('2026-01-31').next, DayKey.parse('2026-02-01'));
      expect(DayKey.parse('2026-12-31').next, DayKey.parse('2027-01-01'));
      expect(DayKey.parse('2027-01-01').previous, DayKey.parse('2026-12-31'));
      expect(DayKey.parse('2028-02-28').next, DayKey.parse('2028-02-29'));
      expect(DayKey.parse('2026-02-28').next, DayKey.parse('2026-03-01'));
    });

    test('measures whole days, signed', () {
      final from = DayKey.parse('2026-08-01');
      expect(DayKey.parse('2026-08-06').differenceInDays(from), 5);
      expect(from.differenceInDays(DayKey.parse('2026-08-06')), -5);
      expect(from.differenceInDays(from), 0);
    });

    test('orders and compares', () {
      final a = DayKey.parse('2026-08-05');
      final b = DayKey.parse('2026-08-06');
      expect(a < b, isTrue);
      expect(a <= a, isTrue);
      expect(b > a, isTrue);
      expect(b >= b, isTrue);
      expect(a == DayKey(2026, 8, 5), isTrue);
      expect(a.hashCode, DayKey(2026, 8, 5).hashCode);
    });

    test('through() is inclusive at both ends, empty when reversed', () {
      final start = DayKey.parse('2026-08-05');
      expect(start.through(DayKey.parse('2026-08-07')),
          days(['2026-08-05', '2026-08-06', '2026-08-07']).toList()
            ..sort((a, b) => a.compareTo(b)));
      expect(start.through(start), [start]);
      expect(start.through(start.previous), isEmpty);
    });
  });

  group('DST — the arithmetic must stay calendar arithmetic', () {
    // Europe/Madrid: forward 2026-03-29 (02:00 -> 03:00), back 2026-10-25.
    test('a 23-hour day is still one day', () {
      final springForward = DayKey.parse('2026-03-29');
      expect(springForward.next, DayKey.parse('2026-03-30'));
      expect(springForward.previous, DayKey.parse('2026-03-28'));

      // The real elapsed time across it is 23 hours, which is exactly why the
      // label may not be computed by adding Duration(days: 1) to an instant.
      final elapsed = springForward.next
          .startOfDay(madrid)
          .difference(springForward.startOfDay(madrid));
      expect(elapsed, const Duration(hours: 23));
    });

    test('a 25-hour day is still one day', () {
      final fallBack = DayKey.parse('2026-10-25');
      expect(fallBack.next, DayKey.parse('2026-10-26'));

      final elapsed = fallBack.next
          .startOfDay(madrid)
          .difference(fallBack.startOfDay(madrid));
      expect(elapsed, const Duration(hours: 25));
    });

    test('instants either side of a transition land on the right day', () {
      expect(DayKey.fromInstant(at(madrid, 2026, 3, 29, 1, 59), madrid),
          DayKey.parse('2026-03-29'));
      expect(DayKey.fromInstant(at(madrid, 2026, 3, 29, 3, 1), madrid),
          DayKey.parse('2026-03-29'));
      expect(DayKey.fromInstant(at(madrid, 2026, 3, 29, 23, 59), madrid),
          DayKey.parse('2026-03-29'));
      expect(DayKey.fromInstant(at(madrid, 2026, 3, 30, 0, 1), madrid),
          DayKey.parse('2026-03-30'));
    });

    test('a fixed wall-clock reminder time survives both transitions', () {
      // 12:00 local is 12:00 local on both sides of a transition. A raw UTC
      // offset captured before the change would fire an hour out afterwards.
      for (final d in ['2026-03-28', '2026-03-29', '2026-03-30']) {
        final noon =
            DayKey.parse(d).at(const LocalTimeOfDay(12, 0), madrid);
        expect(noon.hour, 12, reason: d);
        expect(DayKey.fromInstant(noon, madrid), DayKey.parse(d));
      }
    });
  });

  group('fromInstant — the zone is always explicit', () {
    test('the same instant is a different day in different zones', () {
      // 2026-08-17 08:00 UTC.
      final instant = at(utc, 2026, 8, 17, 8);
      expect(DayKey.fromInstant(instant, madrid), DayKey.parse('2026-08-17'));
      expect(DayKey.fromInstant(instant, auckland), DayKey.parse('2026-08-17'));
      // 22:00 on the 16th in Honolulu.
      expect(DayKey.fromInstant(instant, honolulu), DayKey.parse('2026-08-16'));
    });

    test('lastCompletedDay is the watched zone answer, not the watcher one', () {
      // The alarm fires at 10:00 Madrid. Asked in the watcher's own zone it
      // would name the 16th; the watched person in Honolulu has only completed
      // the 15th. §10 step 1 requires the latter.
      final alarmFires = at(madrid, 2026, 8, 17, 10);
      expect(lastCompletedDay(alarmFires, madrid), DayKey.parse('2026-08-16'));
      expect(lastCompletedDay(alarmFires, honolulu), DayKey.parse('2026-08-15'));
    });

    test('handles the far side of the date line', () {
      // 22:00 Madrid on the 17th is already 08:00 on the 18th in Auckland.
      final instant = at(madrid, 2026, 8, 17, 22);
      expect(DayKey.fromInstant(instant, madrid), DayKey.parse('2026-08-17'));
      expect(DayKey.fromInstant(instant, auckland), DayKey.parse('2026-08-18'));
    });
  });

  group('a device whose timezone changes mid-period', () {
    test('the same instant yields a different day after a flight', () {
      // Mum flies Madrid -> Auckland. At 23:30 Madrid it is already the 18th
      // where she now is, so the day her tap files under changes with her.
      final instant = at(madrid, 2026, 8, 17, 23, 30);
      expect(DayKey.fromInstant(instant, madrid), day('2026-08-17'));
      expect(DayKey.fromInstant(instant, auckland), day('2026-08-18'));
    });

    test('a stale cached device zone costs exactly one boundary day', () {
      // ADR-0002's accepted cost: someone travels without opening the app, so
      // LocalStore still holds the old zone. Asserted as a known outcome rather
      // than left as a surprise — and bounded, because the watched person opens
      // the app daily to tap, which refreshes it.
      final stale = madrid;
      final actual = auckland;

      // Near the boundary the two disagree, by one day and never more.
      final atBoundary = at(auckland, 2026, 8, 18, 8, 0);
      expect(
        DayKey.fromInstant(atBoundary, actual)
            .differenceInDays(DayKey.fromInstant(atBoundary, stale)),
        1,
      );

      // Away from the boundary they agree, which is why the exposure is one day.
      final midday = at(auckland, 2026, 8, 18, 15, 0);
      expect(DayKey.fromInstant(midday, actual),
          DayKey.fromInstant(midday, stale));
    });

    test('the zone argument is what decides — same instant, different days', () {
      // The property "a watcher's own zone never affects D" is only assertable
      // one layer up, where a watcher zone exists; it is covered in
      // watcher_reconciler_test.dart. What IS assertable here is the premise it
      // rests on: this function reads the zone it is given and nothing else.
      final instant = at(utc, 2026, 8, 17, 8);
      expect(lastCompletedDay(instant, madrid), day('2026-08-16'));
      expect(lastCompletedDay(instant, honolulu), day('2026-08-15'));
      expect(lastCompletedDay(instant, auckland), day('2026-08-16'));
    });

    test('the EU and US fall back on different dates', () {
      // For ~one week a year Madrid↔New York is 5 hours, not 6. A cached or
      // assumed offset gives the wrong D for exactly that week — which is the
      // case a single-zone fixture set never exercises.
      // Madrid falls back 2026-10-25; New York on 2026-11-01.
      expect(at(madrid, 2026, 10, 27, 0, 30).timeZoneOffset,
          const Duration(hours: 1));
      expect(at(newYork, 2026, 10, 27, 0, 30).timeZoneOffset,
          const Duration(hours: -4));

      // 00:30 on the 27th in Madrid is 19:30 on the 26th in New York.
      expect(lastCompletedDay(at(madrid, 2026, 10, 27, 0, 30), newYork),
          day('2026-10-25'));
      expect(lastCompletedDay(at(madrid, 2026, 10, 27, 0, 30), madrid),
          day('2026-10-26'));
    });
  });

  group('the soft midnight boundary is an outcome, not just an input', () {
    test('00:05 Monday and 23:55 Tuesday leave both days green', () {
      // ~47h50m of real silence with both days recorded. Inherent to
      // calendar-day check-ins, and intended (§11) — asserted here so nobody
      // "fixes" it into a rolling 24-hour window later.
      final earlyMonday = at(madrid, 2026, 8, 17, 0, 5);
      final lateTuesday = at(madrid, 2026, 8, 18, 23, 55);

      final monday = DayKey.fromInstant(earlyMonday, madrid);
      final tuesday = DayKey.fromInstant(lateTuesday, madrid);

      expect(monday, DayKey.parse('2026-08-17'));
      expect(tuesday, DayKey.parse('2026-08-18'));
      expect(tuesday, monday.next);
      expect(lateTuesday.difference(earlyMonday),
          const Duration(hours: 47, minutes: 50));
    });
  });

  group('startOfDay and at', () {
    test('startOfDay is local midnight in the given zone', () {
      final midnight = DayKey.parse('2026-08-17').startOfDay(madrid);
      expect(midnight.hour, 0);
      expect(midnight.minute, 0);
      expect(midnight.day, 17);
    });

    test('at() places a wall-clock time on the day', () {
      final noon =
          DayKey.parse('2026-08-17').at(const LocalTimeOfDay(12, 0), madrid);
      expect(noon.hour, 12);
      expect(DayKey.fromInstant(noon, madrid), DayKey.parse('2026-08-17'));
    });
  });
}
