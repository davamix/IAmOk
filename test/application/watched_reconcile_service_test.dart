@TestOn('vm')
library;

import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// The watched side's composition: reconcile → schedule → record.
///
/// The domain is already tested in isolation and the store against real SQLite;
/// what is left is the wiring, and two things about it can be wrong in ways
/// nothing else would catch — **the order the platform is driven in**, and
/// whether the clock is read once and passed down or reached for repeatedly.
class _RecordingScheduler implements AlarmScheduler {
  final List<String> calls = [];
  final Set<ScheduledReminder> armed = {};

  @override
  Future<void> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
  }) async {
    for (final reminder in toCancel) {
      calls.add('cancel ${reminder.day} ${reminder.slot.name}');
      armed.remove(reminder);
    }
    for (final reminder in desired) {
      calls.add('schedule ${reminder.day} ${reminder.slot.name}');
      armed.add(reminder);
    }
  }

  /// What a force-stop does: every platform alarm is cancelled, and nothing
  /// tells the app. The store is untouched.
  void platformWipedByForceStop() => armed.clear();

  @override
  Future<void> cancelAll() async {
    calls.add('cancelAll');
    armed.clear();
  }

  @override
  Future<int> armedOnPlatform() async => armed.length;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late _RecordingScheduler scheduler;
  late FixedClock clock;
  var notificationsOn = true;

  const selfUid = 'mum';

  WatchedReconcileService service() => WatchedReconcileService(
        store: store,
        clock: clock,
        alarms: scheduler,
        notificationsEnabled: () async => notificationsOn,
      );

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    scheduler = _RecordingScheduler();
    // 06:00 Madrid, so every slot of every day in the window is still ahead.
    clock = FixedClock(at(madrid, 2026, 8, 17, 6));
    notificationsOn = true;
    await store.setDeviceTimezone('Europe/Madrid');
  });

  tearDown(() => store.close());

  Set<DayKey> daysCovered(Set<ScheduledReminder> reminders) =>
      reminders.map((r) => r.day).toSet();

  Future<void> seedWatchers(List<String> names) async {
    for (final name in names) {
      await store.upsertLink(Link(
        watchedUid: selfUid,
        watcherUid: name.toLowerCase(),
        status: LinkStatus.accepted,
        watchedName: 'Mum',
        watcherName: name,
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        createdAt: DateTime.utc(2026, 7, 1),
      ));
    }
  }

  group('the rolling window is armed', () {
    test('7 days of three reminders', () async {
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, hasLength(21));
      expect(await store.pendingReminders(), hasLength(21));
    });

    test('the store and the platform agree afterwards', () async {
      await service().reconcile(selfUid: selfUid);
      expect(await store.pendingReminders(), scheduler.armed);
    });

    test('every instant is the named wall-clock time in Madrid', () async {
      await service().reconcile(selfUid: selfUid);
      expect(
        scheduler.armed.every((r) => r.at.hour == r.slot.time.hour),
        isTrue,
      );
    });
  });

  group('idempotence — every entry point calls the same function', () {
    // Idempotence is asserted on **what ends up armed** and on the absence of
    // CANCEL churn — not on the raw call log. Since the repair fix, every
    // reconcile re-asserts the whole desired set, so the log grows by design;
    // what must never change is the resulting state, or boot recovery becomes a
    // duplicate-notification bug.
    test('a second reconcile changes nothing that is armed', () async {
      await service().reconcile(selfUid: selfUid);
      final afterFirst = Set<ScheduledReminder>.from(scheduler.armed);

      scheduler.calls.clear();
      await service().reconcile(selfUid: selfUid);

      expect(scheduler.armed, afterFirst,
          reason: 'boot recovery is the same function, not a special case');
      expect(scheduler.calls.where((c) => c.startsWith('cancel')), isEmpty,
          reason: 'nothing moved, so nothing may be torn down');
    });

    test('a third run changes nothing either', () async {
      await service().reconcile(selfUid: selfUid);
      await service().reconcile(selfUid: selfUid);
      final armed = Set<ScheduledReminder>.from(scheduler.armed);
      scheduler.calls.clear();

      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, armed);
      expect(scheduler.calls.where((c) => c.startsWith('cancel')), isEmpty);
    });
  });

  group('a tap', () {
    test('cancels the rest of the day', () async {
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed.where((r) => r.day == day('2026-08-17')),
          hasLength(3));

      await service().tap(selfUid: selfUid);
      expect(scheduler.armed.where((r) => r.day == day('2026-08-17')), isEmpty,
          reason: 'being nudged after you have tapped is the training to avoid');
      expect(scheduler.armed, hasLength(18),
          reason: 'the following six days are untouched');
    });

    test('records the day from the device clock at tap time', () async {
      // 23:50 Madrid. §11: the day is decided here, not by a server timestamp
      // that would resolve at 08:00 the next morning and file it a day late.
      clock = FixedClock(at(madrid, 2026, 8, 17, 23, 50));
      final state = await service().tap(selfUid: selfUid);
      expect(state.today, day('2026-08-17'));
      expect(await store.checkedInDays(), {day('2026-08-17')});
    });

    test('is idempotent — a second tap the same day changes nothing', () async {
      await service().tap(selfUid: selfUid);
      final armed = Set<ScheduledReminder>.from(scheduler.armed);
      await service().tap(selfUid: selfUid);
      expect(scheduler.armed, armed);
      expect(await store.allCheckIns(), hasLength(1));
    });

    test('leaves the target disabled for the rest of the day', () async {
      final state = await service().tap(selfUid: selfUid);
      expect(state.hasTappedToday, isTrue);
    });

    test('the target re-enables when the local day rolls over', () async {
      await service().tap(selfUid: selfUid);

      clock = FixedClock(at(madrid, 2026, 8, 18, 6));
      final tomorrow = await service().reconcile(selfUid: selfUid);
      expect(tomorrow.today, day('2026-08-18'));
      expect(tomorrow.hasTappedToday, isFalse);
      expect(scheduler.armed.where((r) => r.day == day('2026-08-18')),
          hasLength(3));
    });
  });

  group('reconcile repairs a platform wiped behind its back', () {
    // MEASURED ON THE POCO F3, Phase 2 device pass, stock power settings:
    //
    //   fresh launch + reconcile  → 21 alarms armed
    //   force-stop                → 0 armed   (Android cancels them all)
    //   reopen + reconcile        → STILL 0
    //
    // Nothing tells the app. `LocalStore` still held all 21 as pending, so the
    // old `desired.difference(currentlyScheduled)` was empty and re-armed
    // nothing. The app was silently and permanently inert — the one failure
    // this project cannot detect in itself — and on HyperOS a force-stop is an
    // ordinary user action: swiping from recents, "clear all", any task killer.
    //
    // The store records what we ASKED for. It is never evidence of what the
    // platform HOLDS, and only one of those may be trusted.

    test('re-arms everything after a force-stop clears the platform', () async {
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, hasLength(21));
      expect(await store.pendingReminders(), hasLength(21),
          reason: 'the store believes all 21 are armed');

      scheduler.platformWipedByForceStop();
      expect(scheduler.armed, isEmpty);

      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, hasLength(21),
          reason: 'reconcile must MAKE REALITY MATCH, not trust its own record '
              'of what it once asked for');
    });

    test('and it repairs a PARTIAL loss too', () async {
      // An OEM cleaner that drops some rather than all. Same principle, and the
      // count-based check a diff would do cannot see it either.
      await service().reconcile(selfUid: selfUid);
      final survivors = scheduler.armed.take(5).toSet();
      scheduler.armed
        ..clear()
        ..addAll(survivors);

      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, hasLength(21));
    });

    test('repairing is still idempotent in EFFECT', () async {
      // Asserting the whole desired set means the call log grows every
      // reconcile — that is the cost, and it is cheap. What must not change is
      // what ends up armed, or boot recovery becomes a duplicate bug.
      await service().reconcile(selfUid: selfUid);
      final armed = Set<ScheduledReminder>.from(scheduler.armed);
      await service().reconcile(selfUid: selfUid);
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, armed);
      expect(await store.pendingReminders(), armed);
      expect(armed, hasLength(21));
    });

    test('a tap still cancels the rest of the day after a wipe', () async {
      // The repair must not resurrect reminders the day no longer wants.
      await service().tap(selfUid: selfUid);
      scheduler.platformWipedByForceStop();

      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed.where((r) => r.day == day('2026-08-17')), isEmpty,
          reason: 'today is tapped, so it must stay cancelled through a repair');
      expect(scheduler.armed, hasLength(18));
    });
  });

  group('the ordering trap — cancel before schedule', () {
    test('a moved reminder is cancelled BEFORE it is rescheduled', () async {
      // The watched person flies Madrid → New York. `ScheduledReminder`
      // equality includes the instant while the platform id is derived from
      // (day, slot) alone, so every reminder appears in BOTH sets under one id.
      // Scheduling first and cancelling second would disarm what was just
      // armed, and the symptom is nothing happening — no error, no log.
      await service().reconcile(selfUid: selfUid);
      scheduler.calls.clear();

      await store.setDeviceTimezone('America/New_York');
      await service().reconcile(selfUid: selfUid);

      final firstSchedule =
          scheduler.calls.indexWhere((c) => c.startsWith('schedule'));
      final lastCancel =
          scheduler.calls.lastIndexWhere((c) => c.startsWith('cancel'));

      expect(lastCancel, isNonNegative, reason: 'the zone change moved them');
      expect(firstSchedule, isNonNegative);
      expect(lastCancel, lessThan(firstSchedule),
          reason: 'every cancel must precede every schedule');
    });

    test('the timezone change is noticed at all', () async {
      await service().reconcile(selfUid: selfUid);
      final madridInstants = scheduler.armed.map((r) => r.at).toSet();

      await store.setDeviceTimezone('America/New_York');
      await service().reconcile(selfUid: selfUid);

      expect(scheduler.armed.map((r) => r.at).toSet(),
          isNot(madridInstants),
          reason: 'ADR-0002 accepts a stale zone only because the diff notices');
      expect(
        scheduler.armed.every((r) => r.at.hour == r.slot.time.hour),
        isTrue,
        reason: '12/18/21 local in New York now',
      );
    });
  });

  group('who will be notified', () {
    test('comes back on the reconciled state', () async {
      await seedWatchers(['Beto', 'Ana']);
      final state = await service().reconcile(selfUid: selfUid);
      expect(state.audience.names, ['Ana', 'Beto']);
    });

    test('a revoked watcher drops out', () async {
      await seedWatchers(['Ana', 'Beto']);
      await store.upsertLink(
        (await store.linksWatching(selfUid))
            .firstWhere((l) => l.watcherUid == 'beto')
            .copyWith(status: LinkStatus.revoked),
      );
      final state = await service().reconcile(selfUid: selfUid);
      expect(state.audience.names, ['Ana']);
    });

    test('an empty audience does not change which reminders are armed',
        () async {
      // Reminders exist for her own routine, not for an audience. If these ever
      // couple, losing every watcher silently stops her being nudged to tap.
      await service().reconcile(selfUid: selfUid);
      final withNobody = Set<ScheduledReminder>.from(scheduler.armed);

      await seedWatchers(['Ana']);
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, withNobody);
    });

    test('links where this user is the WATCHER are not the audience', () async {
      // The audience answers "who will be notified when *I* tap", so only links
      // where this user is the watched party count.
      await store.upsertLink(Link(
        watchedUid: 'granddad',
        watcherUid: selfUid,
        status: LinkStatus.accepted,
        watchedName: 'Granddad',
        watcherName: 'Mum',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        createdAt: DateTime.utc(2026, 7, 1),
      ));
      final state = await service().reconcile(selfUid: selfUid);
      expect(state.audience.isEmpty, isTrue);
    });
  });

  group('notification permission is read afresh every time', () {
    test('it surfaces on the state', () async {
      expect((await service().reconcile(selfUid: selfUid)).notificationsEnabled,
          isTrue);
      notificationsOn = false;
      expect((await service().reconcile(selfUid: selfUid)).notificationsEnabled,
          isFalse);
    });

    test('revoked notifications do not stop the window being armed', () async {
      // The alarms are still scheduled; the OS simply will not show them. When
      // the permission returns, what was armed is what fires — nothing has to
      // be rebuilt, and nothing was silently consumed in the meantime.
      notificationsOn = false;
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, hasLength(21));
    });
  });

  group('a store with nothing in it', () {
    // The clock is deliberately 23:30 UTC — which is already the NEXT day in
    // Madrid. At the suite's usual 06:00 Madrid the two zones agree about the
    // day, so `expect(today, ...)` would hold for every zone from UTC-4 to
    // UTC+18 and the assertion would discriminate nothing.
    final acrossMidnight = at(utc, 2026, 8, 17, 23, 30);

    test('falls back to UTC rather than throwing', () async {
      // Reachable only before the first UI resume has ever completed. A bare
      // isolate that cannot name the zone should arm something rather than
      // nothing, and the next resume corrects it.
      await store.wipe();
      clock = FixedClock(acrossMidnight);

      final state = await service().reconcile(selfUid: selfUid);
      expect(state.today, day('2026-08-17'),
          reason: 'UTC, not Madrid — where it is already the 18th');
      expect(state.zone, TimeZones.utc);
      // 23:30 is past all three of today's slots, so the window is the six
      // whole days ahead. Asserted as the span rather than a bare count, so it
      // says what it means.
      expect(daysCovered(scheduler.armed), hasLength(6));
      expect(daysCovered(scheduler.armed), isNot(contains(day('2026-08-17'))));
      expect(scheduler.armed, hasLength(18));
    });

    test('an unknown stored zone also falls back rather than throwing',
        () async {
      // A zone name written by a newer build, or a device alias the pinned
      // tzdata does not carry. Throwing here happens inside an alarm isolate,
      // where it looks exactly like the app working and saying nothing.
      await store.setDeviceTimezone('Mars/Olympus_Mons');
      clock = FixedClock(acrossMidnight);

      final state = await service().reconcile(selfUid: selfUid);
      expect(state.today, day('2026-08-17'));
      expect(state.zone, TimeZones.utc);
      expect(scheduler.armed, hasLength(18),
          reason: 'a full window of whole days, not merely "something"');
    });
  });

  group('across a DST transition', () {
    // The suite otherwise runs entirely inside the DST-free week of 17-23
    // August. The round trip is `day.at(slot, zone)` → epoch ms + zone name →
    // `TZDateTime.from(...)`; if those disagree by an hour across a transition,
    // every reconcile cancels and reschedules all 21 alarms forever, and the
    // idempotence test in the August week is blind to it.
    test('a window spanning the autumn change is still idempotent', () async {
      // 22 October 2026, four days before Madrid falls back on the 25th.
      clock = FixedClock(at(madrid, 2026, 10, 22, 6));

      await service().reconcile(selfUid: selfUid);
      final afterFirst = Set<ScheduledReminder>.from(scheduler.armed);
      expect(daysCovered(scheduler.armed), contains(day('2026-10-26')),
          reason: 'the premise: the window really does cross the transition');

      scheduler.calls.clear();
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, afterFirst);
      expect(scheduler.calls.where((c) => c.startsWith('cancel')), isEmpty,
          reason: 'the stored instants must round-trip exactly, or every '
              'reconcile tears down and rebuilds all 21 alarms');
    });

    test('every alarm keeps its named wall-clock time across the change',
        () async {
      clock = FixedClock(at(madrid, 2026, 10, 22, 6));
      await service().reconcile(selfUid: selfUid);
      expect(
        scheduler.armed.every((r) => r.at.hour == r.slot.time.hour),
        isTrue,
        reason: '12/18/21 local on both sides of the transition',
      );
    });

    test('the spring change round-trips too', () async {
      clock = FixedClock(at(madrid, 2027, 3, 26, 6));
      await service().reconcile(selfUid: selfUid);
      final afterFirst = Set<ScheduledReminder>.from(scheduler.armed);
      scheduler.calls.clear();
      await service().reconcile(selfUid: selfUid);
      expect(scheduler.armed, afterFirst);
      expect(scheduler.calls.where((c) => c.startsWith('cancel')), isEmpty);
    });
  });

  group('a timezone change that moves the DAY, not just the instant', () {
    test('the whole window shifts by a day', () async {
      // Madrid → Honolulu. At 06:00 Madrid it is still the previous day in
      // Honolulu, so `today` itself moves — which the Madrid → New York case
      // does not exercise, because that only shifts instants. This is where the
      // diff is most likely to be wrong.
      await service().reconcile(selfUid: selfUid);
      final inMadrid = daysCovered(scheduler.armed);
      expect(inMadrid, contains(day('2026-08-17')));

      await store.setDeviceTimezone('Pacific/Honolulu');
      final state = await service().reconcile(selfUid: selfUid);

      expect(state.today, day('2026-08-16'),
          reason: '06:00 on the 17th in Madrid is the 16th in Honolulu');
      final days = daysCovered(scheduler.armed);
      expect(days, contains(day('2026-08-16')),
          reason: 'the window now starts a day EARLIER than it did in Madrid');
      expect(days, hasLength(7));
      expect(days.reduce((a, b) => a > b ? a : b), day('2026-08-22'));
      expect(inMadrid, isNot(days),
          reason: 'the day set really moved, not just the instants');
    });
  });

  group('a tap at the other edge of the day', () {
    test('00:05 lands on the day it was made', () async {
      // The 23:50 edge is covered above; this is the other one, and together
      // they are §11's soft-midnight boundary.
      clock = FixedClock(at(madrid, 2026, 8, 17, 0, 5));
      final state = await service().tap(selfUid: selfUid);
      expect(state.today, day('2026-08-17'));
      expect(await store.checkedInDays(), {day('2026-08-17')});
    });
  });
}
