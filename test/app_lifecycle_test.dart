@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:i_am_ok/presentation/watcher_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/zones.dart';

/// **The two facts the app shell decides with, tested where they are decided.**
///
/// ## What this deliberately does not do
///
/// It does not pump `IAmOkApp`. That was tried, and it hangs: `WidgetTester`
/// runs in a fake-async zone, `LocalStore` is real `sqflite` doing real I/O off
/// that zone, and the reconcile the shell kicks off never completes — the tests
/// time out rather than failing, which is worse than not having them.
/// `tester.runAsync` would let the I/O through but takes the frame scheduler
/// with it, and the Tap screen's indefinite progress indicator means
/// `pumpAndSettle` can never be used either.
///
/// So the glue in `didChangeAppLifecycleState` — three lines, no branching
/// beyond the guard below — stays covered by the device matrix, and the two
/// things it *decides with* are asserted here directly:
///
/// * **`WatcherScreen.isShowing`**, which chooses between the shell's reconcile
///   and the list's own. The two disagree about `NotificationDelivery`, and one
///   of those answers consumes a day while showing nobody anything.
/// * **`AppServices.watches`**, which is what stops an untrusted notification
///   payload opening a screen.
class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

class _NoopAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
  }) async =>
      true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();

  late LocalStore store;
  late AppServices services;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    await store.setDeviceTimezone('Europe/Madrid');
    final notifications = _FakeNotifications();
    services = AppServices(
      store: store,
      clock: FixedClock(at(madrid, 2026, 8, 17, 10)),
      notifications: notifications,
      alarms: _NoopAlarms(),
      permissions: PermissionService(notifications),
      clockService: const ClockService(),
      selfUid: 'ana',
    );
  });

  tearDown(() => store.close());

  Future<void> seedLink(String watchedUid, String name) => store.upsertLink(Link(
        watchedUid: watchedUid,
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: name,
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-08-01'),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      ));

  group('a notification payload is resolved, never trusted', () {
    test('a link this user watches resolves', () async {
      await seedLink('mum', 'Mum');
      expect(await services.watches('mum_ana'), isTrue);
    });

    test('a link belonging to someone else does not', () async {
      // The whole point. `tappedLink` is whatever string arrived on a
      // notification, and the app pushed a screen for any non-null value.
      await seedLink('mum', 'Mum');
      expect(await services.watches('mum_bob'), isFalse);
    });

    test('a link that does not exist does not', () async {
      await seedLink('mum', 'Mum');
      expect(await services.watches('stranger_ana'), isFalse);
    });

    test('nothing resolves when this user watches nobody', () async {
      expect(await services.watches('mum_ana'), isFalse);
    });
  });

  group('the watcher list owns whether it is showing', () {
    /// The list alone, in a scope that can build it. Its own reconcile never
    /// completes here — real I/O, fake-async zone — so it sits on the loading
    /// state, which is all this needs: the counter moves in `initState`.
    Future<void> pumpList(WidgetTester tester) => tester.pumpWidget(
          ProviderScope(
            overrides: [appServicesProvider.overrideWithValue(services)],
            child: const MaterialApp(home: WatcherScreen()),
          ),
        );

    testWidgets('false when it is not on screen', (tester) async {
      expect(WatcherScreen.isShowing, isFalse);
    });

    testWidgets('true while it is', (tester) async {
      await pumpList(tester);
      expect(WatcherScreen.isShowing, isTrue);

      // Disposed before the test ends, or the next one starts dirty.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('and false again once it is gone', (tester) async {
      await pumpList(tester);
      await tester.pumpWidget(const SizedBox());

      expect(WatcherScreen.isShowing, isFalse,
          reason: 'a counter that never returns to zero would silence the '
              'shell\'s resume repair for the rest of the process — and that '
              'repair is what ADR-0007 names as the only recovery from a '
              'force-stop');
    });

    testWidgets('two instances do not clear it when one pops', (tester) async {
      // The defect the counter replaced. `main.dart` tracked this around its
      // own `push`, so a second notification tap stacked a second screen and
      // the first `.then` to fire cleared the flag while one was still up.
      await pumpList(tester);
      expect(WatcherScreen.isShowing, isTrue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appServicesProvider.overrideWithValue(services)],
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const WatcherScreen(),
              ),
            ),
          ),
        ),
      );
      expect(WatcherScreen.isShowing, isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(WatcherScreen.isShowing, isFalse);
    });
  });
}
