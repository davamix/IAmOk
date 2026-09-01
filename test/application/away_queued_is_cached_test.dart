@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/auth_repository.dart';
import 'package:i_am_ok/data/away_repository.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// A **queued** away write reaches this phone's own cache — owner decision,
/// 2026-09-01.
///
/// The device run measured what the alternative feels like. Aeroplane mode, set
/// away, and the screen said *"Saved."* while `self_away` stayed empty, the away
/// line never appeared, the control still read *"I'm away"*, and the reminders
/// for the away days stayed armed — for as long as the app was not resumed. On
/// the plane §8 names, the phone goes on reminding her three times a day through
/// the period she has just been told is saved.
///
/// Nothing corrected it either, and that is the part worth keeping in mind while
/// reading these tests: the watched side takes its away row from a **read-back**,
/// and `onAwayChanged` deliberately skips whoever set the period — so the one
/// device certain not to be told is the one that wrote it.
///
/// **This is composition-root wiring**, which is where both of the defects
/// `providers_test.dart` was written for actually lived. The away repository is
/// injected for the first time here, because the alternative way to reach a
/// queued write is a real Firestore.
class _FakeAway extends AwayRepository {
  /// What the next write or cancel returns.
  AwayOutcome next = const AwayOutcome.queued();

  /// What a read reports the server holds. Null models the ordinary case for
  /// these tests: the write has not landed, so there is nothing to read back.
  AwayRecord? stored;

  /// Set to a failure to model the phone that queued the write in the first
  /// place. **This is not decoration.** A write queues because the server could
  /// not be reached, so the reconcile that follows is refused too — and a read
  /// that SUCCEEDS legitimately overwrites the cache with whatever Firestore
  /// holds, including with nothing (ADR-0001 decision 1). The last test below
  /// is that case, on purpose.
  AwayRead? forcedRead;

  int writes = 0;

  @override
  Future<AwayRead> read(String watchedUid) async =>
      forcedRead ?? AwayRead.succeeded(stored);

  @override
  Future<AwayOutcome> write({
    required String watchedUid,
    required String setBy,
    required String setByName,
    required AwayPeriod period,
    required DayKey today,
    AwayPeriod? existing,
  }) async {
    writes += 1;
    return next;
  }

  @override
  Future<AwayOutcome> cancel({required String watchedUid}) async {
    writes += 1;
    return next;
  }
}

/// A display name without a Firebase app.
///
/// `setAway` reads it for `setByName` — a display LABEL, never the identity
/// (ADR-0003) — and `AuthRepository` resolves `FirebaseAuth.instance` on use,
/// which throws in a VM test.
class _FakeAuth extends AuthRepository {
  _FakeAuth(super.store);

  @override
  String? get displayName => 'Mum';
}

class _SilentNotifications extends NotificationService {
  _SilentNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

/// The reminders, recorded rather than handed to a plugin with no platform side
/// in a VM test. What is asserted below is the desired set the reconcile
/// derived, which is the thing the decision changes.
class _RecordingAlarms implements AlarmScheduler {
  final Set<ScheduledReminder> armed = {};

  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
    required bool hasAudience,
  }) async {
    armed
      ..removeAll(toCancel)
      ..addAll(desired);
    return true;
  }

  @override
  Future<void> cancelAll() async => armed.clear();

  @override
  Future<int> armedAccordingToPlugin() async => armed.length;
}

/// Answers Madrid without touching `flutter_timezone`, which has no platform
/// side in a test process.
class _MadridClockService extends ClockService {
  const _MadridClockService();

  @override
  Future<String?> deviceTimezone() async => 'Europe/Madrid';

  @override
  bool uses24HourClock() => true;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');
  final today = DayKey(2026, 8, 17);

  late LocalStore store;
  late _FakeAway away;
  late _RecordingAlarms alarms;
  late ProviderContainer container;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    away = _FakeAway();
    alarms = _RecordingAlarms();
    final notifications = _SilentNotifications();
    container = ProviderContainer(
      overrides: [
        appServicesProvider.overrideWithValue(
          AppServices(
            store: store,
            clock: FixedClock(at(madrid, 2026, 8, 17, 9)),
            notifications: notifications,
            alarms: alarms,
            permissions: PermissionService(notifications),
            clockService: const _MadridClockService(),
            selfUid: LocalStore.defaultSelfUid,
            auth: _FakeAuth(store),
            awayDocument: away,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(store.close);
  });

  /// Sets away on a phone that cannot reach the server — the only state a
  /// queued write actually happens in.
  Future<AwayOutcome> setAway(DayKey lastDay) async {
    await container.read(watchedStateProvider.future);
    away.forcedRead = const AwayRead.unreachable(UnreachableCause.offline);
    return container.read(watchedStateProvider.notifier).setAway(lastDay);
  }

  test('a QUEUED write is cached here, so the screen stops contradicting itself',
      () async {
    final outcome = await setAway(DayKey(2026, 8, 22));

    expect(outcome, isA<AwayQueued>());
    final cached = await store.selfAway();
    expect(cached, isNotNull,
        reason: 'the phone that wrote it is the one device the nudge skips');
    expect(cached!.period.from, today);
    expect(cached.period.through, DayKey(2026, 8, 22));
    expect(cached.setBy, LocalStore.defaultSelfUid,
        reason: 'attributed to whoever actually wrote it, as the document is');
  });

  test('and the reminders are re-derived around it, not patched', () async {
    await setAway(DayKey(2026, 8, 22));

    final days = {for (final reminder in alarms.armed) reminder.day};
    expect(days, isNot(contains(today)), reason: 'an away day is not reminded');
    expect(days, isNot(contains(DayKey(2026, 8, 22))));
    expect(days, contains(DayKey(2026, 8, 23)),
        reason: 'the first day back is armed before she leaves');
    expect(days, contains(DayKey(2026, 8, 29)),
        reason: 'and the window runs to `through` + 7');
  });

  test('a REFUSED write caches nothing — it is not a period that exists',
      () async {
    away.next = const AwayOutcome.refused(AwayRefusal.notPermitted);

    final outcome = await setAway(DayKey(2026, 8, 22));

    expect(outcome, isA<AwayRefused>());
    expect(await store.selfAway(), isNull);
  });

  test('a CONFIRMED write leaves the cache to the read-back', () async {
    // The queued branch is the only one that writes here. With the fake
    // reporting the server holds nothing, a `set` that also cached would show
    // up as a row — which is what makes this the control for the first test
    // rather than a restatement of it.
    away.next = const AwayOutcome.set();

    await setAway(DayKey(2026, 8, 22));

    expect(await store.selfAway(), isNull);
  });

  test('and a later read that SUCCEEDS overrules the optimistic row', () async {
    // The bound on the whole decision, and the reason it is safe. If the write
    // is ultimately refused, this phone believes it is away when it is not —
    // which stops its reminders, the LOUD direction, since her family reads the
    // server and warns exactly as before. The first read that succeeds puts it
    // right, including by saying there is no period at all.
    await setAway(DayKey(2026, 8, 22));
    expect(await store.selfAway(), isNotNull, reason: 'cached while offline');

    away.forcedRead = null; // the radio comes back, and the write never landed
    await container.read(watchedStateProvider.notifier).refresh();

    expect(await store.selfAway(), isNull,
        reason: 'a read that succeeded is the answer, however this row got here');
  });

  group('ending it queues too, and that direction matters more', () {
    setUp(() async {
      // A period already in force, cached the ordinary way: read back from a
      // read that succeeded.
      away.stored = AwayRecord(
        period: AwayPeriod(from: DayKey(2026, 8, 15), through: DayKey(2026, 8, 22)),
        setBy: 'ana-uid',
        setByName: 'Ana',
      );
      await container.read(watchedStateProvider.future);
      expect(await store.selfAway(), isNotNull, reason: 'the fixture is real');
      // From here the phone is offline: the write queues, and the read that
      // follows it is refused for the same reason.
      away.stored = null;
      away.forcedRead = const AwayRead.unreachable(UnreachableCause.offline);
      away.next = const AwayOutcome.queued();
    });

    test('a truncation lands in the cache, so she is reminded again', () async {
      final outcome =
          await container.read(watchedStateProvider.notifier).endAway();

      expect(outcome, isA<AwayQueued>());
      final cached = await store.selfAway();
      expect(cached, isNotNull, reason: 'truncated, never deleted');
      expect(cached!.period.through, DayKey(2026, 8, 16),
          reason: 'the day before today — the days already spent away stay '
              'covered, which is ADR-0001 decision 5');

      final days = {for (final reminder in alarms.armed) reminder.day};
      expect(days, contains(today),
          reason: 'she is expected to tap today, and must be reminded to');
    });

    test('and a cancellation on the FIRST day clears it, as the delete does',
        () async {
      away.stored = AwayRecord(
        period: AwayPeriod(from: today, through: DayKey(2026, 8, 22)),
        setBy: 'ana-uid',
        setByName: 'Ana',
      );
      away.forcedRead = null;
      await container.read(watchedStateProvider.notifier).refresh();
      away.stored = null;
      away.forcedRead = const AwayRead.unreachable(UnreachableCause.offline);

      await container.read(watchedStateProvider.notifier).endAway();

      expect(await store.selfAway(), isNull,
          reason: 'truncating would write `through = from - 1`, so §12 deletes '
              '— and the cache says the same thing by being empty');
    });
  });
}
