import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// ADR-0002's open assumption, asserted at the behavioural level.
///
/// The static verification — no `flutter:` section, no platform directories, no
/// `MethodChannel`, no plugin registrant generated — is recorded in the
/// [TimeZones] doc comment and in the Phase 1 summary. What can be checked *at
/// runtime* is the consequence: the zones this app needs resolve from a
/// standing start, with nothing initialised by a Flutter binding.
void main() {
  test('resolves a zone with no bootstrap of any kind', () {
    // If this needed a plugin registrant it would fail here, in a plain
    // package:test isolate with no Flutter binding.
    expect(TimeZones.location('Europe/Madrid').name, 'Europe/Madrid');
  });

  test('the database carries the zones this design depends on', () {
    for (final name in const [
      'Europe/Madrid',
      'Pacific/Auckland',
      'Pacific/Honolulu',
      'America/New_York',
      'Asia/Tokyo',
      'Etc/UTC',
    ]) {
      expect(TimeZones.isKnown(name), isTrue, reason: name);
    }
  });

  test('initialisation is idempotent', () {
    TimeZones.ensureInitialized();
    TimeZones.ensureInitialized();
    expect(TimeZones.location('Europe/Madrid').name, 'Europe/Madrid');
  });

  test('an unknown zone throws with the offending name attached', () {
    expect(
      () => TimeZones.location('Mars/Olympus'),
      throwsA(isA<UnknownTimeZone>()
          .having((e) => e.name, 'name', 'Mars/Olympus')),
    );
    expect(TimeZones.isKnown('Mars/Olympus'), isFalse);
  });

  test('the database has real DST rules, not fixed offsets', () {
    // A fixed-offset stub would pass every other test in this suite and then
    // fire every reminder an hour out for half the year.
    final madrid = TimeZones.location('Europe/Madrid');
    expect(DayKey.parse('2026-01-15').startOfDay(madrid).timeZoneOffset,
        const Duration(hours: 1), reason: 'CET, UTC+1');
    expect(DayKey.parse('2026-07-15').startOfDay(madrid).timeZoneOffset,
        const Duration(hours: 2), reason: 'CEST, UTC+2');
  });

  test('UTC is available', () {
    expect(TimeZones.utc.name, anyOf('UTC', 'Etc/UTC'));
  });
}
