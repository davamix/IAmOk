@TestOn('vm')
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/auth_repository.dart';
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

/// Answers Madrid without touching `flutter_timezone`, which has no platform
/// side in a test process.
///
/// Also reports a **12-hour** device, overridden for the same reason: the real
/// getter reads `platformDispatcher`, and the point here is the round trip to
/// `LocalStore` rather than the platform read.
class _MadridClockService extends ClockService {
  const _MadridClockService();

  @override
  Future<String?> deviceTimezone() async => 'Europe/Madrid';

  @override
  bool uses24HourClock() => false;
}

/// A plugin hiccup on the zone lookup, with the clock format still readable.
///
/// `ClockService.deviceTimezone` swallows its own `Exception`s and returns null,
/// so this throws an `Error` to model what actually reaches the caller: a
/// platform channel failure that is not an `Exception`.
class _ThrowingZoneClockService extends ClockService {
  const _ThrowingZoneClockService();

  @override
  Future<String?> deviceTimezone() async => throw StateError('no platform');

  @override
  bool uses24HourClock() => false;
}

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
        auth: AuthRepository(store),
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

  /// The same derivation as the alarm isolate reaches — literally the same
  /// method, which is the point of it living on `NotificationService`.
  ///
  /// **The isolate's root is the one that matters most and the one nothing can
  /// watch.** It serves the watcher who never opens the app, which is the entire
  /// population `NotificationDelivery` exists for, and while it built its own
  /// copy of this expression it drifted from the UI's copy exactly once. Now
  /// there is one derivation and one `appInForeground` argument between them, so
  /// the isolate's wiring is covered by every case below plus the one here.
  Future<WatcherDelivery> deliveryInAlarmIsolate({
    bool warnings = true,
    bool access = true,
  }) {
    notifications.allowed[NotificationService.warningsChannel.id] = warnings;
    notifications.allowed[NotificationService.accessChannel.id] = access;
    return notifications.watcherDelivery(appInForeground: false);
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

  group('the device zone is cached BEFORE the first reconcile', () {
    /// A fresh install: `LocalStore.deviceTimezone()` is null, and the platform
    /// is about to say Madrid.
    ///
    /// This ordering is the fix for a defect measured on the POCO F3 on
    /// 2026-08-17 — 19 alarms, every one an hour or two late, with
    /// `device_timezone` already correctly stored beside them — and it had no
    /// test. Reverse the two lines in `WatchedStateNotifier.build()` and the
    /// first reconcile takes ADR-0002's documented UTC fallback, arming the
    /// whole window at UTC wall times: 14:00 / 20:00 / 23:00 in Madrid rather
    /// than 12:00 / 18:00 / 21:00.
    ///
    /// It used to be self-correcting — a second reconcile fixed the times — and
    /// ADR-0006 correctly stopped that second run as concurrent. So nothing
    /// repairs it now until the next resume: a 23:00 nudge to someone who may
    /// well be asleep, for up to the depth of the window.
    late _RecordingAlarms alarms;
    late ProviderContainer container;

    setUp(() {
      alarms = _RecordingAlarms();
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
        auth: AuthRepository(store),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    test('so the window is armed at the device\'s wall times, not UTC\'s',
        () async {
      expect(await store.deviceTimezone(), isNull, reason: 'fresh install');

      await container.read(watchedStateProvider.future);

      expect(alarms.armed, isNotEmpty);
      for (final reminder in alarms.armed) {
        expect(reminder.at.location.name, 'Europe/Madrid');
        expect(reminder.at.hour, reminder.slot.time.hour,
            reason: '${reminder.slot.name} fired at ${reminder.at.hour}:00 — '
                'the UTC fallback would put it two hours late in August');
      }
    });

    test('and the zone is on disk afterwards, for the bare isolates', () async {
      await container.read(watchedStateProvider.future);
      expect(await store.deviceTimezone(), 'Europe/Madrid');
    });

    test('and so is the 12h/24h setting, which is the other bare-isolate fact',
        () async {
      // **Both device facts, one writer.** The clock format was written in
      // `main()` only, so a reader who changed it in Android settings kept the
      // old format for the life of the process — while the zone beside it was
      // re-read on every resume. It is now cached here too, which is what makes
      // `LocalStore.uses24HourClock`'s docstring true.
      expect(await store.uses24HourClock(), isTrue, reason: 'the default');

      await container.read(watchedStateProvider.future);

      expect(await store.uses24HourClock(), isFalse,
          reason: 'the platform says 12-hour, and the alarm isolate has no way '
              'to ask — so a wrong value here renders every notification in a '
              'format the device does not use');
    });

    test('one shared implementation, reachable by all three callers', () async {
      // `main()`, the shell's resume handler and `WatchedStateNotifier.build()`
      // all cache the same two facts. It was written out twice — in `main()` and
      // in the notifier — by the very round that was fixing this fact having two
      // sources, and the copies agreed only by luck. Asserted directly now that
      // it is one method on `AppServices`.
      expect(await store.deviceTimezone(), isNull, reason: 'fresh install');

      await container.read(appServicesProvider).cacheDeviceFacts();

      expect(await store.deviceTimezone(), 'Europe/Madrid');
      expect(await store.uses24HourClock(), isFalse);
    });

    test('a zone lookup that throws does not take the clock format with it',
        () async {
      // The two writes shared one `try`, and only the zone's half calls a
      // plugin. So a `flutter_timezone` hiccup — the exact failure that `try`
      // exists to swallow — silently skipped the format as well, and a 12-hour
      // device spent the whole session on the 24-hour default.
      final throwing = ProviderContainer(
        overrides: [
          appServicesProvider.overrideWithValue(
            AppServices(
              store: store,
              clock: FixedClock(at(madrid, 2026, 8, 17, 9)),
              notifications: notifications,
              alarms: alarms,
              permissions: PermissionService(notifications),
              clockService: const _ThrowingZoneClockService(),
              selfUid: LocalStore.defaultSelfUid,
        auth: AuthRepository(store),
            ),
          ),
        ],
      );
      addTearDown(throwing.dispose);

      await throwing.read(watchedStateProvider.future);

      expect(await store.deviceTimezone(), isNull,
          reason: 'the zone genuinely could not be read');
      expect(await store.uses24HourClock(), isFalse,
          reason: 'and the format was still written — separate guards');
    });
  });

  group('the alarm isolate\'s root', () {
    test('is never in the foreground, whatever else is true', () async {
      // Not a preference — a fact about how this isolate came to exist. A
      // `redundant` here would consume the day claiming a reader was looking at
      // a screen that is not running.
      expect(
        await deliveryInAlarmIsolate(),
        const WatcherDelivery.uniform(NotificationDelivery.available),
      );
    });

    test('and measures both channels, exactly as the UI root does', () async {
      expect(await deliveryInAlarmIsolate(access: false),
          await deliveryWhen(listShowing: false, access: false),
          reason: 'one derivation, so the two roots cannot answer differently '
              'about the same phone — which they did');
      expect(await deliveryInAlarmIsolate(warnings: false),
          await deliveryWhen(listShowing: false, warnings: false));
    });

    test('a muted App problems channel still leaves it able to warn', () async {
      // The case the whole split exists for, on the path that serves the
      // watcher who never opens the app.
      final delivery = await deliveryInAlarmIsolate(access: false);
      expect(delivery.warning, NotificationDelivery.available);
      expect(delivery.accessLost, NotificationDelivery.unavailable);
    });
  });
}
