@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// **A reconcile she did not ask for must not delete the one instruction she
/// has.**
///
/// Phase 4 gave the Tap screen a second thing that can rebuild it: an FCM nudge
/// arriving in the foreground. `tapFailed` is transient screen state rather than
/// something stored, so a plain refresh clears it — her tap fails, *"That did
/// not save. Please tap again."* appears, and a push landing three seconds later
/// removes it with no user action at all.
///
/// Nothing becomes **false**: the target stays enabled and the state is
/// accurate. She simply loses the sentence telling her what to do, on the screen
/// this app exists for, and she has no way to know it was ever there.
///
/// Near-unreachable in Phase 4, because a watched person receives no push unless
/// they also watch somebody. Reachable in Phase 6, when `onAwayChanged` fans out
/// to the watched person's own device — which is why it is closed now rather
/// than noted.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late ProviderContainer container;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    await store.setDeviceTimezone('Europe/Madrid');
    final notifications = _FakeNotifications();
    container = ProviderContainer(
      overrides: [
        appServicesProvider.overrideWithValue(
          AppServices(
            store: store,
            clock: FixedClock(at(madrid, 2026, 8, 21, 9, 14)),
            notifications: notifications,
            // The plugin is unavailable in a VM test, and scheduling is not what
            // this file is about.
            alarms: _NoAlarms(),
            permissions: PermissionService(notifications),
            clockService: const ClockService(),
            selfUid: LocalStore.signedOutUid,
            auth: AuthRepository(store),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() => store.close());

  Future<void> failATap() async {
    final notifier = container.read(watchedStateProvider.notifier);
    await container.read(watchedStateProvider.future);
    // The screen state the person is looking at. Set directly rather than by
    // forcing a real write failure: this file is about what a LATER refresh does
    // to it, and `tap_writes_through_test.dart` owns how it gets set.
    notifier.state = AsyncData(
      notifier.state.value!.copyWith(tapFailed: true),
    );
    expect(container.read(watchedStateProvider).value!.tapFailed, isTrue);
  }

  test('a push-driven refresh does NOT clear the tap-failed message', () async {
    await failATap();

    await container
        .read(watchedStateProvider.notifier)
        .refresh(userInitiated: false);

    expect(
      container.read(watchedStateProvider).value!.tapFailed,
      isTrue,
      reason: 'nobody asked for this reconcile, so it must not take away the '
          'only line telling her the tap did not save',
    );
  });

  test('a refresh she DID ask for clears it', () async {
    // The other half, and the reason this is a parameter rather than a blanket
    // carry-forward: on a resume she has come back to the screen and the
    // reconcile is the fresh answer. A stale red line there would be its own
    // small lie.
    await failATap();

    await container.read(watchedStateProvider.notifier).refresh();

    expect(container.read(watchedStateProvider).value!.tapFailed, isFalse);
  });

  test('an unsolicited refresh with nothing to preserve behaves normally',
      () async {
    await container.read(watchedStateProvider.future);

    await container
        .read(watchedStateProvider.notifier)
        .refresh(userInitiated: false);

    expect(container.read(watchedStateProvider).value!.tapFailed, isFalse);
  });
}

/// Implemented explicitly rather than through `noSuchMethod`, which cannot
/// produce the right Future type per member and fails at the call site with a
/// cast error that reads like a defect in the code under test.
class _NoAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> desired,
    required Set<ScheduledReminder> toCancel,
  }) async =>
      true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}

class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}
