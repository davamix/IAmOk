@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// **The composition root, which is where the defect actually was.**
///
/// Everything below this line was already tested. `NotificationDelivery` has its
/// own suite, `WatcherReconciler` consumes it correctly, and the service carries
/// out what it is told. The bug was none of those: it was the **wiring** — the
/// single expression that turns two platform facts into the value the domain
/// reasons about.
///
/// Twice now:
///
/// * `watcherListShowing` was hard-coded `true` on the app-open reconcile while
///   the user sat on the Tap screen. The warning was decided, recorded as
///   standing, and shown to nobody. Measured on the POCO F3:
///   `warningsShownFor` held `warnOnline` with zero notifications posted.
/// * `canPost` was measured on the warnings channel and the one answer handed to
///   both branches, so muting *App problems* consumed the access-lost cadence
///   for a notice Android had dropped.
///
/// Neither was reachable from any test, because nothing exercised this file.
/// Both are one line long.
class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());

  /// Which channels Android would accept a post on, by channel id.
  final Map<String, bool> allowed = {};

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async =>
      allowed[channel?.id] ?? true;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();

  late LocalStore store;
  late _FakeNotifications notifications;
  late AppServices services;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    notifications = _FakeNotifications();
    services = AppServices(
      store: store,
      clock: FixedClock(at(madrid, 2026, 8, 17, 10)),
      notifications: notifications,
      alarms: NotificationAlarmScheduler(notifications),
      permissions: PermissionService(notifications),
      clockService: const ClockService(),
      selfUid: LocalStore.defaultSelfUid,
    );
  });

  tearDown(() => store.close());

  Future<WatcherDelivery> deliveryWhen({
    required bool listShowing,
    bool warnings = true,
    bool access = true,
  }) {
    notifications.allowed[NotificationService.warningsChannel.id] = warnings;
    notifications.allowed[NotificationService.accessChannel.id] = access;
    return services
        .watcherReconcile(watcherListShowing: listShowing)
        .delivery();
  }

  group('watcherListShowing decides `redundant`, and only the list may say yes',
      () {
    test('the list is showing: both channels are redundant', () async {
      // Correct, and the most dangerous value in the enum — the only one that
      // marks a day served while saying nothing. Its whole justification is
      // *the reader is looking at the screen that already shows this*.
      expect(
        await deliveryWhen(listShowing: true),
        const WatcherDelivery.uniform(NotificationDelivery.redundant),
      );
    });

    test('the list is NOT showing: both are available', () async {
      // The app-open repair runs behind the Tap screen. Nothing is rendering
      // this person's state, so a warning decided here must actually be posted
      // or it is recorded as standing and reaches no one.
      expect(
        await deliveryWhen(listShowing: false),
        const WatcherDelivery.uniform(NotificationDelivery.available),
      );
    });

    test('a revoked permission outranks the list being on screen', () async {
      // `canPost` is tested first inside `NotificationDelivery.from`, and this
      // asserts the composition root did not reorder it. Reversed, a watcher
      // with notifications revoked comes out `redundant` while the app is open
      // — which is exactly when reconcile definitely runs — and the reminder is
      // consumed in silence.
      final delivery =
          await deliveryWhen(listShowing: true, warnings: false, access: false);
      expect(delivery,
          const WatcherDelivery.uniform(NotificationDelivery.unavailable));
    });
  });

  group('each channel is measured on its own', () {
    test('App problems muted leaves Missed check-ins working', () async {
      final delivery = await deliveryWhen(listShowing: false, access: false);

      expect(delivery.warning, NotificationDelivery.available);
      expect(delivery.accessLost, NotificationDelivery.unavailable,
          reason: 'ADR-0004 separated the channels so muting one leaves the '
              'other alone; one measurement for both rejoins them');
    });

    test('Missed check-ins muted leaves App problems working', () async {
      final delivery = await deliveryWhen(listShowing: false, warnings: false);

      expect(delivery.warning, NotificationDelivery.unavailable);
      expect(delivery.accessLost, NotificationDelivery.available);
    });

    test('the access branch does NOT read the warnings channel', () async {
      // Pins the direction of the earlier bug. With only *App problems* muted,
      // a root that asked about `warnings` and reused the answer reports
      // `available` for the access notice — the value that consumes the
      // cadence for a notice nobody received.
      final delivery = await deliveryWhen(listShowing: false, access: false);
      expect(delivery.accessLost, isNot(NotificationDelivery.available));
    });
  });
}
