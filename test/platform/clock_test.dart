@TestOn('vm')
library;

import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// The one sanctioned read of the real clock (ADR-0002 decision 1).
///
/// Small enough to look obviously correct, which is exactly why it is worth a
/// test: everything time-dependent in this app is downstream of it, and the
/// debug harness's *force the current date* — the control that makes a 24-hour
/// behaviour verifiable in seconds — is entirely this class's arithmetic.
void main() {
  group('SystemClock', () {
    test('reports UTC, never a device-local DateTime', () {
      // Downstream everything converts through an explicit zone. A local
      // DateTime arriving there carries an implicit zone that is never the
      // right one to reason from — the same hazard the domain's purity guard
      // bans `.toLocal(` for, one layer earlier.
      expect(const SystemClock().now().isUtc, isTrue);
    });

    test('with no offset it is the real clock', () {
      final before = DateTime.now().toUtc();
      final now = const SystemClock().now();
      final after = DateTime.now().toUtc();

      expect(now.isBefore(before), isFalse);
      expect(now.isAfter(after), isFalse);
    });

    test('an offset shifts it', () {
      final real = const SystemClock().now();
      final shifted =
          const SystemClock(offset: Duration(days: 3)).now();
      final gap = shifted.difference(real);

      expect(gap.inHours, closeTo(72, 1));
    });

    test('time still MOVES under an offset', () async {
      // Deliberately an offset rather than a frozen instant. A frozen clock
      // makes every scheduled instant permanently past or permanently future,
      // so an alarm armed two minutes into a forced future would never arrive
      // — which tests nothing the real app does.
      const clock = SystemClock(offset: Duration(days: 3));
      final first = clock.now();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(clock.now().isAfter(first), isTrue);
    });

    test('offsetTo lands the clock on the requested day', () {
      // What the harness's date picker computes. Getting this wrong means
      // forcing the date silently moves to the wrong day, and every subsequent
      // observation on the device is against a premise nobody checked.
      final target = DateTime.utc(2027, 3, 14, 9, 30);
      final clock = SystemClock(offset: SystemClock.offsetTo(target));

      expect(clock.now().difference(target).abs(),
          lessThan(const Duration(seconds: 5)));
    });

    test('offsetTo works backwards as well as forwards', () {
      final past = DateTime.utc(2020, 1, 1, 12);
      final clock = SystemClock(offset: SystemClock.offsetTo(past));
      expect(clock.now().year, 2020);
    });

    test('a forced date reaches the domain as the right DayKey', () {
      // The whole point of the control: DayKey.fromInstant is what decides
      // which reminders should exist, so the offset has to survive the trip
      // through the zone conversion intact.
      final target = DateTime.utc(2026, 12, 31, 23, 30);
      final clock = SystemClock(offset: SystemClock.offsetTo(target));

      expect(DayKey.fromInstant(clock.now(), utc), DayKey(2026, 12, 31));
      // 23:30 UTC on the 31st is already 00:30 on 1 January in Madrid.
      expect(DayKey.fromInstant(clock.now(), madrid), DayKey(2027, 1, 1));
    });
  });

  group('FixedClock', () {
    test('does not move', () {
      final clock = FixedClock(DateTime.utc(2026, 8, 17, 6));
      expect(clock.now(), clock.now());
      expect(clock.now(), DateTime.utc(2026, 8, 17, 6));
    });

    test('normalises a zoned instant to UTC', () {
      // Fixtures build instants with `at(madrid, ...)`; the domain only ever
      // needs the moment, and handing it a TZDateTime where a UTC DateTime is
      // expected is how a test starts passing for the wrong reason.
      final clock = FixedClock(at(madrid, 2026, 8, 17, 6));
      expect(clock.now().isUtc, isTrue);
      expect(DayKey.fromInstant(clock.now(), madrid), DayKey(2026, 8, 17));
    });

    test('can be moved deliberately', () {
      final clock = FixedClock(DateTime.utc(2026, 8, 17, 6));
      clock.instant = DateTime.utc(2026, 8, 18, 6);
      expect(DayKey.fromInstant(clock.now(), utc), DayKey(2026, 8, 18));
    });
  });
}
