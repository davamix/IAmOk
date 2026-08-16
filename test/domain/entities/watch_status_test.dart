import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  final link = Link(
    watchedUid: 'mum',
    watcherUid: 'ana',
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watchedTimezone: 'Europe/Madrid',
    activeFrom: day('2026-07-01'),
    createdAt: at(utc, 2026, 7, 1),
  );

  final today = day('2026-08-17'); // D is 2026-08-16

  WatchStatus derive({
    AwayPeriod? away,
    Set<DayKey> warningsShownFor = const {},
    DayKey? lastCheckInDay,
    Link? on,
    bool hasLostAccess = false,
  }) =>
      WatchStatus.derive(
        link: on ?? link,
        today: today,
        away: away,
        warningsShownFor: warningsShownFor,
        hasLostAccess: hasLostAccess,
        lastCheckInDay: lastCheckInDay,
      );

  test('the status is about the last completed day', () {
    expect(derive().day, day('2026-08-16'));
  });

  group('cold open shows current state, not history', () {
    test('a confirmed day reads as checked in', () {
      expect(derive(lastCheckInDay: day('2026-08-16')).state,
          WatchState.checkedIn);
    });

    test('a warning from three weeks ago is history, not status', () {
      // Followed by three weeks of check-ins. PLAN.md Phase 7 is explicit that
      // this must not present as a standing warning.
      final status = derive(
        warningsShownFor: {day('2026-07-25')},
        lastCheckInDay: day('2026-08-16'),
      );
      expect(status.state, WatchState.checkedIn);
      expect(status.needsAttention, isFalse);
    });

    test('an unresolved warning for D stands', () {
      final status = derive(warningsShownFor: {day('2026-08-16')});
      expect(status.state, WatchState.warned);
      expect(status.needsAttention, isTrue);
    });
  });

  test('away reads as away, and the period stays visible', () {
    final holiday =
        AwayPeriod(from: day('2026-08-15'), through: day('2026-08-20'));
    final status = derive(away: holiday);
    expect(status.state, WatchState.away);
    expect(status.away, holiday);
  });

  test('an expired away period no longer reads as away', () {
    final past =
        AwayPeriod(from: day('2026-08-01'), through: day('2026-08-10'));
    expect(derive(away: past).state, WatchState.awaitingCheckIn);
  });

  test('an away period covering only D still reads as away', () {
    // The period ended yesterday: D was covered, so there is nothing to warn
    // about and nothing to report as missing.
    final ending =
        AwayPeriod(from: day('2026-08-10'), through: day('2026-08-16'));
    expect(derive(away: ending).state, WatchState.away);
  });

  test('before activeFrom there is nothing to say', () {
    final fresh = link.copyWith(activeFrom: day('2026-08-17'));
    expect(derive(on: fresh).state, WatchState.notYetLinked);
  });

  test('an unknown day is awaiting, never "Everything OK"', () {
    // Not confirmed, not away, no warning fired yet — the alarm has not run.
    // Reporting green here would be the health-panel failure in miniature.
    expect(derive().state, WatchState.awaitingCheckIn);
  });

  test('a standing warning outranks a check-in — an owed correction shows', () {
    // Both true means a correction was owed and not applied. Surfacing that is
    // better than hiding it behind a green row.
    final status = derive(
      warningsShownFor: {day('2026-08-16')},
      lastCheckInDay: day('2026-08-16'),
    );
    expect(status.state, WatchState.warned);
  });

  group('a revoked link shows nothing and demands nothing — ADR-0004', () {
    final revoked = link.copyWith(status: LinkStatus.revoked);

    test('the row reads revoked, not warned', () {
      // The reconciler withdraws standing warnings on revocation, but if it
      // never runs again this row would otherwise demand attention forever
      // about someone no longer watched — and nothing could retract it, because
      // only a successful read can produce a correction and every read after
      // revocation is refused.
      final status =
          derive(on: revoked, warningsShownFor: {day('2026-08-16')});
      expect(status.state, WatchState.revoked);
      expect(status.needsAttention, isFalse);
    });

    test('revocation outranks every other state', () {
      for (final args in [
        {'warnings': {day('2026-08-16')}},
        {'lastCheckIn': day('2026-08-16')},
        {'lost': true},
      ]) {
        final status = derive(
          on: revoked,
          warningsShownFor: (args['warnings'] as Set<DayKey>?) ?? const {},
          lastCheckInDay: args['lastCheckIn'] as DayKey?,
          hasLostAccess: args['lost'] as bool? ?? false,
        );
        expect(status.state, WatchState.revoked, reason: '$args');
      }
    });
  });

  group('lost access is not a missed check-in — ADR-0004', () {
    test('the row says access is lost, and does NOT claim a missed day', () {
      final status = derive(hasLostAccess: true);
      expect(status.state, WatchState.accessLost);
      expect(status.state, isNot(WatchState.warned));
    });

    test('it still demands attention — only the watcher can fix it', () {
      expect(derive(hasLostAccess: true).needsAttention, isTrue);
    });

    test('a genuine standing warning outranks it', () {
      // If a real missed day was recorded before access went, that is the more
      // important thing to show.
      final status =
          derive(hasLostAccess: true, warningsShownFor: {day('2026-08-16')});
      expect(status.state, WatchState.warned);
    });

    test('but a day before activeFrom still says nothing', () {
      final fresh = link.copyWith(activeFrom: day('2026-08-17'));
      expect(derive(on: fresh, hasLostAccess: true).state,
          WatchState.notYetLinked);
    });
  });

  test('value equality', () {
    expect(derive(), derive());
    expect(derive().hashCode, derive().hashCode);
    expect(derive(), isNot(derive(lastCheckInDay: day('2026-08-16'))));
  });
}
