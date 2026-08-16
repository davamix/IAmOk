import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  AwayPeriod period(String from, String through) =>
      AwayPeriod(from: day(from), through: day(through));

  group('the through >= from invariant', () {
    test('an inverted period cannot be constructed', () {
      expect(() => period('2026-08-10', '2026-08-09'), throwsArgumentError);
      expect(
        AwayPeriod.tryCreate(
            from: day('2026-08-10'), through: day('2026-08-09')),
        isNull,
      );
    });

    test('a single-day period is one day, not zero', () {
      expect(period('2026-08-10', '2026-08-10').lengthInDays, 1);
      expect(period('2026-08-01', '2026-08-04').lengthInDays, 4);
    });
  });

  group('covers — the edges are the whole point', () {
    final holiday = period('2026-08-01', '2026-08-04');

    test('the day from starts is covered', () {
      expect(holiday.covers(day('2026-08-01')), isTrue);
    });

    test('the day through ends is covered — it is inclusive', () {
      expect(holiday.covers(day('2026-08-04')), isTrue);
    });

    test('the day before from and the day after through are not', () {
      expect(holiday.covers(day('2026-07-31')), isFalse);
      expect(holiday.covers(day('2026-08-05')), isFalse);
    });

    test('firstDayBack is the day after through', () {
      expect(holiday.firstDayBack, day('2026-08-05'));
    });
  });

  group('expiry is arithmetic, never a transmitted event', () {
    final holiday = period('2026-08-01', '2026-08-04');

    test('has not expired on the last away day', () {
      expect(holiday.hasExpiredOn(day('2026-08-04')), isFalse);
    });

    test('has expired the day after through', () {
      expect(holiday.hasExpiredOn(day('2026-08-05')), isTrue);
    });

    test('expires on a device that has not been online since it started', () {
      // Nothing is delivered and nothing needs to be: the same comparison runs
      // on every phone, so the period ends at the same moment on all of them.
      expect(holiday.hasExpiredOn(day('2026-08-20')), isTrue);
    });

    test('endsTomorrowOn fires exactly once, the day before the last', () {
      expect(holiday.endsTomorrowOn(day('2026-08-03')), isTrue);
      expect(holiday.endsTomorrowOn(day('2026-08-02')), isFalse);
      expect(holiday.endsTomorrowOn(day('2026-08-04')), isFalse);
    });
  });

  group('cancellation truncates — ADR-0001 decision 5', () {
    final holiday = period('2026-08-01', '2026-08-20');

    test('mid-period, through is pulled back to the last genuinely away day',
        () {
      final cancelled = holiday.cancelOn(day('2026-08-05'));
      expect(cancelled, period('2026-08-01', '2026-08-04'));
    });

    test('the elapsed away days stay covered', () {
      // Deleting instead would retroactively un-cover them, and the next device
      // to refresh would warn about a day the person was legitimately away.
      final cancelled = holiday.cancelOn(day('2026-08-05'))!;
      for (final d in ['2026-08-01', '2026-08-02', '2026-08-03', '2026-08-04']) {
        expect(cancelled.covers(day(d)), isTrue, reason: d);
      }
      expect(cancelled.covers(day('2026-08-05')), isFalse);
    });

    test('cancelling on the day the period starts deletes outright', () {
      // Truncating here would write through = from - 1 and break the invariant.
      expect(holiday.cancelOn(day('2026-08-01')), isNull);
    });

    test('cancelling before the period starts deletes outright', () {
      expect(holiday.cancelOn(day('2026-07-30')), isNull);
    });

    test('never produces a period that violates through >= from', () {
      // The property the delete branch exists to protect, over every cancel day
      // in and around the period.
      //
      // Asserted as `returnsNormally` plus the exact expected value, NOT as
      // `result.through >= result.from`: the constructor throws on violation, so
      // that assertion could never fail — a broken cancelOn would blow up before
      // reaching it. This says what it means.
      for (var i = -3; i <= 25; i++) {
        final cancelDay = day('2026-08-01').plusDays(i);
        expect(() => holiday.cancelOn(cancelDay), returnsNormally,
            reason: 'cancelling on $cancelDay');

        final result = holiday.cancelOn(cancelDay);
        if (cancelDay <= holiday.from) {
          expect(result, isNull, reason: 'nothing elapsed on $cancelDay');
        } else {
          expect(result, AwayPeriod(from: holiday.from, through: cancelDay.previous),
              reason: 'cancelling on $cancelDay');
        }
      }
    });

    test('cancelling on the last away day leaves the rest covered', () {
      final cancelled = holiday.cancelOn(day('2026-08-20'));
      expect(cancelled, period('2026-08-01', '2026-08-19'));
    });
  });

  group('write rules — ARCHITECTURE.md §8', () {
    final today = day('2026-08-16');

    test('a create starting today is allowed', () {
      expect(
        AwayRules.validateCreate(period('2026-08-16', '2026-08-20'), today),
        isNull,
      );
    });

    test('a retroactive from is rejected, and named', () {
      expect(
        AwayRules.validateCreate(period('2026-08-15', '2026-08-20'), today),
        AwayRejection.retroactiveFrom,
      );
    });

    test('the longest permitted period is 31 days, counting `from`', () {
      // Asserted as a COUNT, deliberately. The cap is an offset — 30 days
      // *ahead* of today — so the period it permits is 31 days long. Every
      // calculation in the project has always said 30-ahead; only the prose
      // said "30 days", and the prose was corrected to match. Pinning the
      // length here stops the two drifting apart again, which is the failure
      // an anchor-only assertion let through once already.
      final longest = period('2026-08-16', '2026-09-15');
      expect(longest.lengthInDays, AwayRules.maxLengthInDays);
      expect(longest.lengthInDays, 31);
      expect(AwayRules.validateCreate(longest, today), isNull);
      expect(
        AwayRules.validateCreate(period('2026-08-16', '2026-09-16'), today),
        AwayRejection.exceedsCap,
        reason: '32 days is one too many',
      );
    });

    test('the cap is measured from today, not from `from`', () {
      // §8 says `through <= request.time + 30d`. Identical while `from` is
      // always today; divergent the moment future-dated away is exposed, which
      // §12 deliberately leaves the door open for.
      expect(
        AwayRules.validateCreate(period('2026-08-16', '2026-09-15'), today),
        isNull,
        reason: 'through == today + 30 is the boundary and is allowed',
      );
      expect(
        AwayRules.validateCreate(period('2026-08-16', '2026-09-16'), today),
        AwayRejection.exceedsCap,
      );
    });

    test('a future-dated period is capped against today, not its own start', () {
      // from = today + 25, through = today + 35. Only 11 days long, and still
      // rejected — which is what §8's wording means and a `from + 30` rule
      // would allow.
      expect(
        AwayRules.validateCreate(period('2026-09-10', '2026-09-20'), today),
        AwayRejection.exceedsCap,
      );
    });

    test('an update may not move from — ADR-0001 decision 6', () {
      final existing = period('2026-08-10', '2026-08-20');
      expect(
        AwayRules.validateUpdate(
            period('2026-08-11', '2026-08-20'), existing, today),
        AwayRejection.fromChanged,
      );
    });

    test('truncating an in-progress period is allowed on update', () {
      // The write ADR-0001 requires: `from` is already in the past, so a
      // blanket `from >= today` rule would reject the cancellation itself.
      final existing = period('2026-08-10', '2026-08-20');
      final truncated = existing.cancelOn(today)!;
      expect(truncated.from < today, isTrue,
          reason: 'the premise: from is in the past');
      expect(AwayRules.validateUpdate(truncated, existing, today), isNull);
    });

    test('an update still respects the cap', () {
      final existing = period('2026-08-16', '2026-08-20');
      expect(
        AwayRules.validateUpdate(
            period('2026-08-16', '2026-09-20'), existing, today),
        AwayRejection.exceedsCap,
      );
    });
  });

  group('absurd periods — bounding the silence, not just the write', () {
    final tenYears = period('2026-08-01', '2036-08-16');
    final today = day('2026-08-16');

    test('the write path rejects them', () {
      expect(AwayRules.validateCreate(period('2026-08-16', '2036-08-16'), today),
          AwayRejection.exceedsCap);
      expect(
        AwayRules.validateUpdate(
          period('2026-08-16', '2036-08-16'),
          period('2026-08-16', '2026-08-20'),
          today,
        ),
        AwayRejection.exceedsCap,
        reason: 'extending an existing period to ten years is the same attack',
      );
    });

    test('but a stored one can still be read, and covers everything', () {
      // The premise. A device does not only write periods, it reads them — and
      // ADR-0001 says a read that SUCCEEDS is trusted. So a document written
      // before the rules were deployed, through a rules-deploy mistake, or by a
      // buggy client, arrives looking perfectly valid.
      expect(AwayPeriod.tryCreate(from: tenYears.from, through: tenYears.through),
          isNotNull);
      expect(tenYears.coversAsStored(day('2035-01-01')), isTrue);
      expect(tenYears.hasExpiredOn(day('2030-01-01')), isFalse);
    });

    test('exceedsCap names them', () {
      expect(tenYears.exceedsCap, isTrue);
      expect(period('2026-08-01', '2026-08-31').exceedsCap, isFalse,
          reason: '31 days is the longest permitted, and is not absurd');
      expect(period('2026-08-01', '2026-09-01').exceedsCap, isTrue,
          reason: '32 days is one too many');
    });

    test('clampedToSanityBound bounds the silence', () {
      final clamped = tenYears.clampedToSanityBound();
      expect(clamped.from, tenYears.from, reason: 'the start is not in dispute');
      expect(clamped.through, day('2026-09-29'));
      expect(clamped.lengthInDays, AwayRules.absurdLengthInDays);
    });

    test('the days legitimately marked away are still covered', () {
      // Clamping rather than discarding is what stops this over-correcting into
      // a false "she didn't check in" for days the family really did mark away.
      final clamped = tenYears.clampedToSanityBound();
      for (final d in ['2026-08-01', '2026-08-15', '2026-09-29']) {
        expect(clamped.covers(day(d)), isTrue, reason: d);
      }
      expect(clamped.covers(day('2026-09-30')), isFalse,
          reason: 'past the sanity bound the app speaks again');
    });

    test('a period within the cap is returned untouched', () {
      final ordinary = period('2026-08-01', '2026-08-20');
      expect(ordinary.clampedToSanityBound(), ordinary);
      expect(identical(ordinary.clampedToSanityBound(), ordinary), isTrue);
    });

    test('clamping is idempotent', () {
      final once = tenYears.clampedToSanityBound();
      expect(once.clampedToSanityBound(), once);
      expect(once.isAbsurd, isFalse);
    });

    test('a far-future through is bounded the same way', () {
      final absurd = period('2026-08-01', '9999-12-31');
      expect(absurd.exceedsCap, isTrue);
      expect(absurd.clampedToSanityBound().through, day('2026-09-29'));
    });
  });

  test('value equality', () {
    expect(period('2026-08-01', '2026-08-04'),
        period('2026-08-01', '2026-08-04'));
    expect(period('2026-08-01', '2026-08-04').hashCode,
        period('2026-08-01', '2026-08-04').hashCode);
    expect(period('2026-08-01', '2026-08-04'),
        isNot(period('2026-08-01', '2026-08-05')));
  });
}
