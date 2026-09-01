@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/auth_repository.dart';
import 'package:i_am_ok/data/away_repository.dart';
import 'package:i_am_ok/data/check_in_reader.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:i_am_ok/platform/warning_alarm_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// **The watcher side must NOT cache a write the server has not taken.**
///
/// `away_queued_is_cached_test.dart` pins the positive half of the owner's
/// decision of 2026-09-01: a *queued* away write goes into `self_away` on the
/// phone that wrote it. `WatchedNotifier._cacheQueued`'s docstring says the
/// asymmetry is the decision —
///
/// > **The watcher's side does NOT do this and must not.** There, an optimistic
/// > cache of a write the server refused would silence a watcher about somebody
/// > else for up to a month with nothing said.
///
/// — and until this file existed that half was enforced by **the absence of a
/// call**. Nothing failed if somebody added four symmetrical lines to
/// `WatcherStateNotifier.setAway`, and the failure it produces is the one §12
/// calls the one this app cannot detect in itself: no notification, no error,
/// and a watcher quietly told nothing about a person for up to 31 days.
///
/// It also puts `WatcherStateNotifier.setAway` and `endAway` **under execution
/// for the first time**. Every other test that reaches them replaces both with
/// a double, so the real bodies — including `setBy: services.selfUid`, which the
/// rules enforce as `setBy == request.auth.uid` — had never run.
class _FakeAway extends AwayRepository {
  AwayOutcome next = const AwayOutcome.queued();

  /// What each write was asked to record, so the caller's uid can be asserted
  /// rather than assumed.
  final List<({String watchedUid, String setBy, AwayPeriod period})> writes = [];
  int cancels = 0;

  /// The read that follows the write is refused for the same reason the write
  /// queued: this phone cannot reach the server. That is not decoration — a
  /// read that SUCCEEDED would legitimately overwrite the cache, and the
  /// assertions below would then be about the read rather than about the write.
  @override
  Future<AwayRead> read(String watchedUid) async =>
      const AwayRead.unreachable(UnreachableCause.offline);

  @override
  Future<AwayOutcome> write({
    required String watchedUid,
    required String setBy,
    required String setByName,
    required AwayPeriod period,
    required DayKey today,
    AwayPeriod? existing,
  }) async {
    writes.add((watchedUid: watchedUid, setBy: setBy, period: period));
    return next;
  }

  @override
  Future<AwayOutcome> cancel({required String watchedUid}) async {
    cancels += 1;
    return next;
  }
}

/// Firestore, unreachable by default — the state a queued write happens in.
///
/// [next] is settable so the last test in this file can make a read **succeed**
/// and show the cache filling. Without that control, every `isNull` assertion
/// here could be passing because nothing in this harness is able to put an away
/// period in the watcher cache at all, which is an assertion that cannot fail.
class _FakeReader implements CheckInReader {
  FirestoreRead next = const ReadUnreachable(UnreachableCause.offline);

  @override
  Future<FirestoreRead> read(Link link) async => next;
}

class _NoWarningAlarms implements WarningAlarmScheduler {
  @override
  Future<bool> apply({
    required String linkId,
    required Set<ScheduledWarning> toCancel,
    required Set<ScheduledWarning> desired,
  }) async => true;

  @override
  Future<void> cancelAll({
    required String linkId,
    required Set<ScheduledWarning> armed,
  }) async {}
}

class _SilentNotifications extends NotificationService {
  _SilentNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

class _FakeAuth extends AuthRepository {
  _FakeAuth(super.store);

  @override
  String? get displayName => 'Ana';
}

class _MadridClockService extends ClockService {
  const _MadridClockService();

  @override
  Future<String?> deviceTimezone() async => 'Europe/Madrid';

  @override
  bool uses24HourClock() => true;
}

class _NoAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
    required bool hasAudience,
  }) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}

/// The real composition root with the two plugin-backed seams replaced.
///
/// `checkInReader` reaches `FirebaseFirestore.instance` and `warningAlarms`
/// reaches `AlarmManager`; neither has a platform side in a VM test. Everything
/// else — the notifier, the reconcile, the store, the away repository seam — is
/// the shipped object, which is the point of the file.
class _TestServices extends AppServices {
  _TestServices({
    required super.store,
    required super.clock,
    required super.notifications,
    required super.alarms,
    required super.permissions,
    required super.clockService,
    required super.selfUid,
    required super.auth,
    required super.awayDocument,
    required this.reader,
  });

  final CheckInReader reader;

  @override
  CheckInReader get checkInReader => reader;

  @override
  WarningAlarmScheduler get warningAlarms => _NoWarningAlarms();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');
  const selfUid = 'ana-uid';
  const watchedUid = 'mum-uid';
  final watchedToday = DayKey(2026, 8, 17);

  final link = Link(
    watchedUid: watchedUid,
    watcherUid: selfUid,
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watcherName: 'Ana',
    watchedTimezone: 'Europe/Madrid',
    activeFrom: DayKey(2026, 8, 1),
    warningLocalTime: const LocalTimeOfDay(10, 0),
    createdAt: DateTime.utc(2026, 8, 1),
  );

  late LocalStore store;
  late _FakeAway away;
  late _FakeReader reader;
  late ProviderContainer container;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    await store.setDeviceTimezone('Europe/Madrid');
    await store.upsertLink(link);
    away = _FakeAway();
    reader = _FakeReader();
    final notifications = _SilentNotifications();
    container = ProviderContainer(
      overrides: [
        appServicesProvider.overrideWithValue(
          _TestServices(
            store: store,
            clock: FixedClock(at(madrid, 2026, 8, 17, 9)),
            notifications: notifications,
            alarms: _NoAlarms(),
            permissions: PermissionService(notifications),
            clockService: const _MadridClockService(),
            selfUid: selfUid,
            auth: _FakeAuth(store),
            awayDocument: away,
            reader: reader,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(store.close);
  });

  test('a QUEUED away write caches NOTHING on the watcher side', () async {
    await container.read(watcherStateProvider.future);

    final outcome = await container.read(watcherStateProvider.notifier).setAway(
          watchedUid: watchedUid,
          lastDay: DayKey(2026, 8, 22),
          watchedToday: watchedToday,
        );

    expect(outcome, isA<AwayQueued>());
    expect(away.writes, hasLength(1), reason: 'the write itself still happens');
    expect((await store.watcherCache(link.id)).away, isNull,
        reason: 'the watched side may cache a queued write about ITSELF; here '
            'the same shortcut would silence this watcher about somebody else '
            'for up to a month, with no notification and no error');
  });

  test('and a QUEUED cancellation caches nothing either', () async {
    // The direction that matters more. Optimistically believing a *cancellation*
    // landed is what stops this phone warning about a person who is no longer
    // covered — and the whole point of ending a period is that she is expected
    // to check in again.
    await container.read(watcherStateProvider.future);

    final outcome = await container.read(watcherStateProvider.notifier).endAway(
          watchedUid: watchedUid,
          existing: AwayPeriod(
            from: DayKey(2026, 8, 15),
            through: DayKey(2026, 8, 22),
          ),
          watchedToday: watchedToday,
        );

    expect(outcome, isA<AwayQueued>());
    expect((await store.watcherCache(link.id)).away, isNull);
  });

  test('a REFUSED write caches nothing, and is not reported as queued',
      () async {
    away.next = const AwayOutcome.refused(AwayRefusal.notPermitted);
    await container.read(watcherStateProvider.future);

    final outcome = await container.read(watcherStateProvider.notifier).setAway(
          watchedUid: watchedUid,
          lastDay: DayKey(2026, 8, 22),
          watchedToday: watchedToday,
        );

    expect(outcome, isA<AwayRefused>());
    expect((await store.watcherCache(link.id)).away, isNull);
  });

  test('the write is attributed to the CALLER, never to the watched person',
      () async {
    // ADR-0003 rule 1, and `firestore.rules` enforces `setBy == request.auth.uid`
    // — so writing the watched person's uid here is not a misattribution, it is
    // a rejected write, on every away period any watcher ever sets. Nothing
    // executed this line before this file: every other test replaces the method
    // it lives in.
    await container.read(watcherStateProvider.future);

    await container.read(watcherStateProvider.notifier).setAway(
          watchedUid: watchedUid,
          lastDay: DayKey(2026, 8, 22),
          watchedToday: watchedToday,
        );

    expect(away.writes.single.setBy, selfUid);
    expect(away.writes.single.setBy, isNot(watchedUid));
    expect(away.writes.single.watchedUid, watchedUid);
  });

  test('the period is bounded by HER today, not by the reader\'s', () async {
    // §11: an away period's days are labels in the watched person's zone. A
    // watcher in London marking somebody in Sydney away must bound the period
    // by the day *she* is living, or the first and last days are off by one.
    await container.read(watcherStateProvider.future);

    await container.read(watcherStateProvider.notifier).setAway(
          watchedUid: watchedUid,
          lastDay: DayKey(2026, 8, 22),
          watchedToday: watchedToday,
        );

    expect(away.writes.single.period.from, watchedToday);
    expect(away.writes.single.period.through, DayKey(2026, 8, 22));
  });

  test('CONTROL: a read that SUCCEEDS is what fills this cache', () async {
    // The green control for every `isNull` above. Those assertions are only
    // evidence that the write path caches nothing if this harness is *able* to
    // put an away period in the watcher cache — otherwise they pass for the
    // same reason an empty file would, which is the failure this project's
    // mutation harness carries thirteen controls to avoid.
    //
    // It is also ADR-0001 decision 1 on this side, stated positively: a read
    // that succeeded is the only thing that may write here.
    final record = AwayRecord(
      period: AwayPeriod(from: DayKey(2026, 8, 15), through: DayKey(2026, 8, 22)),
      setBy: selfUid,
      setByName: 'Ana',
    );
    reader.next = ReadSucceeded(away: record);

    await container.read(watcherStateProvider.future);

    expect((await store.watcherCache(link.id)).away?.period, record.period,
        reason: 'the cache is reachable, so `isNull` above means something');
  });
}
