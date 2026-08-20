// `WarningPolicy.daysToDecide` — ADR-0009's window, on its own.
//
// The reconciler's tests exercise it through the whole pipeline, which is where
// the behaviour that matters lives. This file asserts the arithmetic directly,
// because three of its properties are load-bearing in a way an end-to-end test
// states only indirectly:
//
//   it always ends at D          — everything downstream keys on that decision
//   it is {D} in the normal case — the reason this was safe to land at all
//   it is {D} on a first run     — a fresh install does not retro-warn
//
// A regression in any of those is a silent behaviour change, not a failure.

import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  // 10:00 on 2026-08-14 Madrid, so D = 2026-08-13.
  final now = at(madrid, 2026, 8, 14, 10);
  final d = day('2026-08-13');

  List<DayKey> window({
    DayKey? lastDecidedDay,
    DayKey? activeFrom,
    int catchUpDays = WarningPolicy.defaultCatchUpDays,
  }) =>
      WarningPolicy.daysToDecide(
        now: now,
        watchedZone: madrid,
        activeFrom: activeFrom ?? day('2026-01-01'),
        lastDecidedDay: lastDecidedDay,
        catchUpDays: catchUpDays,
      );

  group('the three properties everything else rests on', () {
    test('it always ends at D', () {
      for (final last in [
        null,
        day('2026-08-12'),
        day('2026-08-01'),
        day('2026-08-13'),
        day('2026-08-20'), // a clock that moved backwards
      ]) {
        expect(window(lastDecidedDay: last).last, d,
            reason: 'lastDecidedDay: $last');
      }
    });

    test('it is {D} alone in ordinary daily operation', () {
      expect(window(lastDecidedDay: day('2026-08-12')), [d]);
    });

    test('it is {D} alone on a first reconcile', () {
      expect(window(lastDecidedDay: null), [d]);
    });

    test('it is never empty', () {
      // The second reconcile of the day is the normal case, not an edge one:
      // reconcile() runs on app open, FCM arrival, alarm fire and boot.
      expect(window(lastDecidedDay: d), [d]);
      expect(window(lastDecidedDay: day('2026-08-20')), [d]);
    });
  });

  group('catching up', () {
    test('a three-day gap yields three days, oldest first', () {
      expect(window(lastDecidedDay: day('2026-08-10')), [
        day('2026-08-11'),
        day('2026-08-12'),
        day('2026-08-13'),
      ]);
    });

    test('the cap bounds the burst, inclusive of D', () {
      final days = window(lastDecidedDay: day('2026-01-01'));
      expect(days, hasLength(WarningPolicy.defaultCatchUpDays));
      expect(days.first, day('2026-08-07'));
      expect(days.last, d);
    });

    test('the cap is a parameter, so a caller can prove it is the cap', () {
      expect(window(lastDecidedDay: day('2026-01-01'), catchUpDays: 3), [
        day('2026-08-11'),
        day('2026-08-12'),
        day('2026-08-13'),
      ]);
      expect(window(lastDecidedDay: day('2026-01-01'), catchUpDays: 1), [d]);
    });

    test('never before the link existed', () {
      expect(
        window(lastDecidedDay: day('2026-08-01'), activeFrom: day('2026-08-12')),
        [day('2026-08-12'), d],
      );
    });

    test('an activeFrom in the future still yields D', () {
      // Reachable: `redeemInvite` sets activeFrom to today in the WATCHED
      // person's zone, which can be ahead of the day this watcher computes. The
      // per-day guard in `decideFor` returns silent for it, which is the right
      // answer; this function must not return an empty list and leave the
      // caller with no decision at all.
      expect(window(lastDecidedDay: null, activeFrom: day('2026-09-01')), [d]);
    });
  });

  group('the day is the WATCHED person\'s, not the watcher\'s', () {
    test('a watched person over the date line', () {
      // 22:00 in Madrid on the 14th is already the 15th in Auckland, so their
      // last completed day is the 14th — not the 13th a Madrid-framed
      // computation would give.
      expect(
        WarningPolicy.daysToDecide(
          now: at(madrid, 2026, 8, 14, 22),
          watchedZone: auckland,
          activeFrom: day('2026-01-01'),
          lastDecidedDay: null,
        ),
        [day('2026-08-14')],
      );
    });

    test('and a watched person well behind it', () {
      expect(
        WarningPolicy.daysToDecide(
          now: at(madrid, 2026, 8, 14, 10),
          watchedZone: honolulu,
          activeFrom: day('2026-01-01'),
          lastDecidedDay: null,
        ),
        [day('2026-08-12')],
      );
    });
  });
}
