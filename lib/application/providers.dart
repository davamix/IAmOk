import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_store.dart';
import '../platform/alarm_scheduler.dart';
import '../platform/clock.dart';
import '../platform/clock_service.dart';
import '../platform/notification_service.dart';
import '../platform/permission_service.dart';
import 'watched_reconcile_service.dart';

/// Everything built once at app start, in one place.
///
/// This is the **UI isolate's composition root**. The background entry points
/// have their own, and that is the point: they share no memory with this one
/// (§4), so a Riverpod provider is invisible to them. Anything a background
/// isolate needs is read from `LocalStore`, never from here.
class AppServices {
  const AppServices({
    required this.store,
    required this.clock,
    required this.notifications,
    required this.alarms,
    required this.permissions,
    required this.clockService,
    required this.selfUid,
  });

  final LocalStore store;
  final Clock clock;
  final NotificationService notifications;
  final AlarmScheduler alarms;
  final PermissionService permissions;
  final ClockService clockService;

  /// Phase 2 has no backend and no sign-in, so identity is a fixed local uid.
  /// Phase 4 replaces this with the Firebase uid, which survives reinstall and
  /// phone replacement so links never break (§1).
  final String selfUid;

  WatchedReconcileService get watchedReconcile => WatchedReconcileService(
        store: store,
        clock: clock,
        alarms: alarms,
        notificationsEnabled: permissions.notificationsEnabled,
      );
}

/// Overridden in `main()`. Reading it without that override is a wiring bug,
/// and failing loudly here beats a half-built app.
final appServicesProvider = Provider<AppServices>(
  (ref) => throw StateError('appServicesProvider must be overridden in main()'),
);

/// The Tap screen's state, recomputed by a full reconcile.
///
/// Deliberately **not** an incrementally patched value. §3's operating rule is
/// *reconcile, don't mutate*: every action here re-reads current state and
/// recomputes the whole of it, which is what makes a tap, a resume, a forced
/// date and a boot all the same code path.
final watchedStateProvider =
    AsyncNotifierProvider<WatchedStateNotifier, WatchedState>(
  WatchedStateNotifier.new,
);

class WatchedStateNotifier extends AsyncNotifier<WatchedState> {
  @override
  Future<WatchedState> build() {
    final services = ref.watch(appServicesProvider);
    return services.watchedReconcile.reconcile(selfUid: services.selfUid);
  }

  /// Re-reads everything. Called on resume, and after the debug harness changes
  /// something underneath.
  ///
  /// Android takes permissions back from apps nobody opens (§13), and the
  /// device's zone can change while the app is backgrounded, so a resume is a
  /// real reconcile rather than a redraw.
  Future<void> refresh() async {
    final services = ref.read(appServicesProvider);
    state = await AsyncValue.guard(
      () => services.watchedReconcile.reconcile(selfUid: services.selfUid),
    );
  }

  /// Records the tap, then reconciles — which cancels the rest of today's
  /// reminders.
  ///
  /// **A failure here stays local.** It does *not* go through
  /// `AsyncValue.guard`, because that would put the whole provider into
  /// `AsyncError` and replace the entire screen — she taps, the screen she uses
  /// every morning disappears, and the message claims the phone could not get
  /// ready when in fact the phone was ready and the check-in did not save. The
  /// only way out would re-run a reconcile rather than the tap, and her family
  /// would be warned the next morning with nothing having told her.
  ///
  /// Instead the last good state is kept, the target stays on screen and
  /// enabled, and one line appears beneath it.
  Future<void> tap() async {
    final services = ref.read(appServicesProvider);
    final previous = state.value;
    try {
      state = AsyncData(
        await services.watchedReconcile.tap(selfUid: services.selfUid),
      );
    } on Object {
      // Only the initial load may take the screen away; see [build].
      state = previous == null
          ? state
          : AsyncData(previous.copyWith(tapFailed: true));
    }
  }

  /// Asks for `POST_NOTIFICATIONS` once, on first run.
  ///
  /// On API 33+ the permission is **denied by default**, so without this the
  /// first launch on the target device shows a red banner about a permission
  /// the app has never requested — and no reminder ever fires, which is this
  /// phase's own exit criterion. Phase 5 moves the ask into onboarding, where
  /// it can be explained first.
  ///
  /// Only asks when the OS says notifications are currently off, so a granted
  /// install never sees a prompt.
  Future<void> ensureNotificationsAsked() async {
    final services = ref.read(appServicesProvider);
    if (await services.permissions.notificationsEnabled()) return;
    await services.permissions.requestNotifications();
    await refresh();
  }

  /// The banner's action. Android stops showing the prompt after two refusals,
  /// at which point this is a no-op and the banner is the honest dead end.
  Future<void> requestNotifications() async {
    final services = ref.read(appServicesProvider);
    await services.permissions.requestNotifications();
    await refresh();
  }

  /// Refreshes the cached device zone from the platform, then reconciles.
  ///
  /// `flutter_timezone` is a plugin, so this can only happen here in the UI
  /// isolate (ADR-0002 decision 2). Writing the result to `LocalStore` is what
  /// lets a bare alarm isolate compute the day with no plugin access at all.
  Future<void> refreshDeviceZone() async {
    final services = ref.read(appServicesProvider);
    final zone = await services.clockService.deviceTimezone();
    if (zone != null) await services.store.setDeviceTimezone(zone);
    await refresh();
  }
}
