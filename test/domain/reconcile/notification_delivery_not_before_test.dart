@TestOn('vm')
library;

import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

/// **[WatcherDelivery.notBefore] — ADR-0010, at the level it lives at.**
///
/// The composed behaviour is covered thoroughly through
/// `WatcherReconcileService`: nothing posted, nothing recorded, the day still
/// owed, the alarm still armed, and the 10:00 alarm speaking afterwards. That
/// suite proves the *consequences*. What it could not reach is the function's
/// own inputs, because every link in it is `Europe/Madrid` watched by a device
/// cached as `Europe/Madrid` — so the two zone arguments were the same object in
/// all eleven cases, and `warningLocalTime` was `10:00` in every one.
///
/// Three things follow, and each has cases below:
///
/// * **The zone is the WATCHER's.** Resolving the gate in the watched person's
///   zone instead is the plausible wrong implementation, it does not throw, and
///   it was indistinguishable from the correct one under all 924 tests. It also
///   restores ADR-0010's own headline defect in a new costume: `Link
///   .warningLocalTime`'s docstring describes a watcher in Los Angeles woken at
///   00:00 PDT because Mum in Madrid tapped at 09:00 CEST, and a gate keyed on
///   Madrid opens at exactly that instant while the alarm — armed correctly in
///   the watcher's zone — still sits nine hours away.
/// * **The minutes count.** Every decision test used a whole hour, so dropping
///   the minute component passed everything.
/// * **DST resolves rather than throws.** `DayKey.at` says so, and `notBefore`'s
///   docstring makes a load-bearing claim that the gate and the alarm resolve a
///   non-existent wall time *identically*. That is a property, not a guarantee,
///   and it becomes live the moment Phase 7 ships a time picker and somebody
///   chooses 02:30.
void main() {
  TimeZones.ensureInitialized();

  const available = WatcherDelivery.uniform(NotificationDelivery.available);
  const ten = LocalTimeOfDay(10, 0);

  WatcherDelivery gate(
    DateTime now, {
    WatcherDelivery from = available,
    LocalTimeOfDay at = ten,
    dynamic zone,
  }) =>
      from.notBefore(at, now: now, watcherZone: zone ?? madrid);

  group('the hour itself', () {
    test('before it, the warning channel is held', () {
      expect(gate(at(madrid, 2026, 8, 17, 0, 24)).warning,
          NotificationDelivery.unavailable);
    });

    test('at exactly it, nothing is held', () {
      // The boundary is shared with `_desiredWarnings`, which does NOT arm an
      // instant that has arrived. Both sides of that instant have to be right or
      // a warning falls between the alarm that was not armed and the post that
      // was not made.
      expect(gate(at(madrid, 2026, 8, 17, 10)).warning,
          NotificationDelivery.available);
    });

    test('after it, nothing is held — the acceleration is kept', () {
      // ADR-0010 gives up only the hours before the reader's chosen time. A push
      // at 14:00 is what rescues a 10:00 alarm Doze held.
      expect(gate(at(madrid, 2026, 8, 17, 14)).warning,
          NotificationDelivery.available);
    });

    test('the minutes are part of the answer', () {
      // 10:00 was the only value any decision test used, so an implementation
      // that compared hours alone passed everything. The product ships one
      // warning time today; Phase 7's picker is what makes this live.
      const halfPast = LocalTimeOfDay(10, 30);
      expect(gate(at(madrid, 2026, 8, 17, 10, 15), at: halfPast).warning,
          NotificationDelivery.unavailable,
          reason: '10:15 is before 10:30');
      expect(gate(at(madrid, 2026, 8, 17, 10, 30), at: halfPast).warning,
          NotificationDelivery.available);
    });
  });

  group('the zone is the WATCHER\'s', () {
    test('a watcher in Honolulu is held while it is still midnight there', () {
      // 12:00 Madrid is 00:00 the same day in Honolulu. The two zones give
      // opposite answers, which is the whole point: Madrid says the hour has
      // passed, Honolulu says it is ten hours away.
      //
      // This is the case an all-Madrid fixture set can never see, and it is the
      // one ADR-0010 turns on — the gate must agree with the alarm, and the
      // alarm is armed in the watcher's zone.
      final noonInMadrid = at(madrid, 2026, 8, 17, 12);
      expect(gate(noonInMadrid, zone: honolulu).warning,
          NotificationDelivery.unavailable,
          reason: 'midnight in Honolulu — the alarm there is ten hours away');
      expect(gate(noonInMadrid, zone: madrid).warning,
          NotificationDelivery.available,
          reason: 'the counterfactual: in Madrid the hour has passed. If this '
              'and the line above ever agree, the gate is reading the wrong '
              'zone');
    });

    test('and in Auckland, where the hour has already gone', () {
      // The other direction, so the test cannot pass by always holding. 02:00
      // Madrid on the 18th is 12:00 Auckland — past 10:00 there.
      expect(gate(at(madrid, 2026, 8, 18, 2), zone: auckland).warning,
          NotificationDelivery.available);
    });

    test('the UTC fallback is honoured, not special-cased', () {
      // `_watcherZone()` falls back to UTC when nothing is cached or the
      // platform names a zone this build cannot resolve, and `_desiredWarnings`
      // then arms every alarm at `warningLocalTime` UTC. ADR-0010 says agreeing
      // with the alarm matters more here than being right in the abstract, so
      // the gate must take the same fallback rather than reaching for a
      // "better" zone.
      final elevenMadrid = at(madrid, 2026, 8, 17, 11); // 09:00 UTC
      expect(gate(elevenMadrid, zone: utc).warning,
          NotificationDelivery.unavailable,
          reason: '09:00 UTC is before 10:00 UTC, which is when the alarm was '
              'armed');
      expect(gate(elevenMadrid, zone: madrid).warning,
          NotificationDelivery.available,
          reason: 'the counterfactual');
    });
  });

  group('DST, where the wall clock is not a duration', () {
    test('a spring-forward hour that does not exist still decides', () {
      // Madrid jumps 02:00 → 03:00 on 2026-03-29, so 02:30 never happens.
      // `DayKey.at` resolves it to the adjacent valid instant rather than
      // throwing, and the alarm scheduler resolves it the same way — so the two
      // agree by construction. What must NOT happen is a throw: this runs in the
      // alarm isolate, where nothing reports one and the only symptom is
      // silence.
      const halfTwo = LocalTimeOfDay(2, 30);
      expect(
        () => gate(at(madrid, 2026, 3, 29, 1), at: halfTwo),
        returnsNormally,
      );
      expect(gate(at(madrid, 2026, 3, 29, 1), at: halfTwo).warning,
          NotificationDelivery.unavailable,
          reason: '01:00 is before the resolved instant either way');
      expect(gate(at(madrid, 2026, 3, 29, 12), at: halfTwo).warning,
          NotificationDelivery.available,
          reason: 'and midday is after it, whichever way it resolved');
    });

    test('an autumn hour that happens twice still decides', () {
      // Madrid repeats 02:00–03:00 on 2026-10-25. The gate opens at one of the
      // two 02:30s; both are behind 12:00, so the answer is stable whichever the
      // package picked.
      const halfTwo = LocalTimeOfDay(2, 30);
      expect(gate(at(madrid, 2026, 10, 25, 1), at: halfTwo).warning,
          NotificationDelivery.unavailable);
      expect(gate(at(madrid, 2026, 10, 25, 12), at: halfTwo).warning,
          NotificationDelivery.available);
    });
  });

  group('what it must never touch', () {
    test('the access-lost channel, at any hour', () {
      // ADR-0004: a claim about US, not about her. A refusal is not tied to an
      // hour and is neither transient nor self-healing, and its decaying cadence
      // is the thing `NotificationDelivery` exists to stop being burned in
      // silence.
      final held = gate(at(madrid, 2026, 8, 17, 0, 24));
      expect(held.warning, NotificationDelivery.unavailable);
      expect(held.accessLost, NotificationDelivery.available);
    });

    test('a channel-split delivery keeps its other half exactly', () {
      const split = WatcherDelivery(
        warning: NotificationDelivery.available,
        accessLost: NotificationDelivery.unavailable,
      );
      final held = gate(at(madrid, 2026, 8, 17, 0, 24), from: split);
      expect(held.warning, NotificationDelivery.unavailable);
      expect(held.accessLost, NotificationDelivery.unavailable);
    });

    test('`redundant` is returned untouched — the reader is looking at it', () {
      // Deliberately not downgraded. It posts nothing in any case, so there is
      // nothing to suppress; downgrading it would only leave the day owed and
      // then post at 10:00 about something the reader was shown at 00:24.
      const redundant = WatcherDelivery.uniform(NotificationDelivery.redundant);
      expect(gate(at(madrid, 2026, 8, 17, 0, 24), from: redundant),
          redundant);
    });

    test('`unavailable` is returned untouched', () {
      const muted = WatcherDelivery.uniform(NotificationDelivery.unavailable);
      expect(gate(at(madrid, 2026, 8, 17, 0, 24), from: muted), muted);
    });

    test('and an unheld call returns the identical value', () {
      // Not merely an equal one: nothing is rebuilt when the hour has passed, so
      // a future change that always allocates would show up here.
      final after = at(madrid, 2026, 8, 17, 14);
      expect(identical(available.notBefore(ten, now: after, watcherZone: madrid),
          available), isTrue);
    });
  });
}
