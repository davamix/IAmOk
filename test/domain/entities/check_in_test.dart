import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  group('the day id comes from the device clock', () {
    test('a tap is filed on the device-local day', () {
      final checkIn =
          CheckIn.forTap(now: at(madrid, 2026, 8, 17, 9, 14), zone: madrid);
      expect(checkIn.day, day('2026-08-17'));
      expect(checkIn.timezone, 'Europe/Madrid');
    });

    test('a tap at 23:50 that syncs at 08:00 stays on the EARLIER day', () {
      // The §17 "High — silently wrong data" risk, and the test that stops
      // someone simplifying this back to serverTimestamp() in Phase 4.
      // serverTimestamp() resolves when the write reaches the server, so this
      // check-in would land on the 18th and the family would be told Mum
      // missed the 17th.
      final tappedAt = at(madrid, 2026, 8, 17, 23, 50);
      final queued = CheckIn.forTap(now: tappedAt, zone: madrid);
      expect(queued.day, day('2026-08-17'));
      expect(queued.isSynced, isFalse);

      final synced =
          queued.copyWith(receivedAt: at(madrid, 2026, 8, 18, 8, 0));
      expect(synced.day, day('2026-08-17'),
          reason: 'the day was decided at tap time and does not move');
      expect(synced.isSynced, isTrue);
    });

    test('deviceTappedAt is the client clock — what the family is shown', () {
      final tappedAt = at(madrid, 2026, 8, 17, 23, 50);
      final synced = CheckIn.forTap(now: tappedAt, zone: madrid)
          .copyWith(receivedAt: at(madrid, 2026, 8, 18, 8));
      expect(synced.deviceTappedAt, tappedAt);
      expect(synced.syncDelay, const Duration(hours: 8, minutes: 10));
    });

    test('a tap at 00:05 is filed on the day that just started', () {
      expect(
        CheckIn.forTap(now: at(madrid, 2026, 8, 17, 0, 5), zone: madrid).day,
        day('2026-08-17'),
      );
    });

    test('the device zone decides, not UTC', () {
      // 23:30 Madrid on the 17th is 21:30 UTC on the 17th, but 09:30 on the
      // 18th in Auckland. Whichever device taps files its own day.
      final instant = at(madrid, 2026, 8, 17, 23, 30);
      expect(CheckIn.forTap(now: instant, zone: madrid).day,
          day('2026-08-17'));
      expect(CheckIn.forTap(now: instant, zone: auckland).day,
          day('2026-08-18'));
    });
  });

  group('the document id is the day', () {
    test('a second tap the same day produces the same id', () {
      // Once-per-day semantics for free: the second write is an update, so it
      // does not fire onDocumentCreated and no duplicate push goes out. There
      // is no dedupe logic anywhere, so the premise is worth asserting.
      final first =
          CheckIn.forTap(now: at(madrid, 2026, 8, 17, 9, 14), zone: madrid);
      final second =
          CheckIn.forTap(now: at(madrid, 2026, 8, 17, 20, 2), zone: madrid);
      expect(first.day, second.day);
      expect(first.day.toString(), '2026-08-17');
      expect(first, isNot(second), reason: 'the tap times still differ');
    });

    test('taps on consecutive days produce different ids', () {
      final monday =
          CheckIn.forTap(now: at(madrid, 2026, 8, 17, 23, 55), zone: madrid);
      final tuesday =
          CheckIn.forTap(now: at(madrid, 2026, 8, 18, 0, 5), zone: madrid);
      expect(monday.day, isNot(tuesday.day));
      expect(tuesday.day, monday.day.next);
    });
  });

  test('syncDelay is null while the write is queued', () {
    final queued =
        CheckIn.forTap(now: at(madrid, 2026, 8, 17, 9), zone: madrid);
    expect(queued.receivedAt, isNull);
    expect(queued.syncDelay, isNull);
  });

  test('value equality', () {
    final a = CheckIn.forTap(now: at(madrid, 2026, 8, 17, 9), zone: madrid);
    final b = CheckIn.forTap(now: at(madrid, 2026, 8, 17, 9), zone: madrid);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
