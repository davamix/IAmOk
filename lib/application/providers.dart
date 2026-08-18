import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/check_in_reader.dart';
import '../data/local_store.dart';
import '../domain/domain.dart';
import '../platform/alarm_scheduler.dart';
import '../platform/clock.dart';
import '../platform/clock_service.dart';
import '../platform/notification_service.dart';
import '../platform/permission_service.dart';
import '../platform/warning_alarm_scheduler.dart';
import 'warning_alarm_handler.dart';
import 'watched_reconcile_service.dart';
import 'watcher_reconcile_service.dart';

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

  /// The watcher's logic-bearing alarms. Exposed so the debug harness can arm
  /// one directly — the only control that asks the OS whether it will actually
  /// wake a bare isolate on this handset.
  WarningAlarmScheduler get warningAlarms => AndroidWarningAlarmScheduler(
        warningAlarmCallback,
        notifications.canScheduleExact,
      );

  /// The watcher's reconcile.
  ///
  /// [watcherListShowing] is **not** "the UI isolate is running" — it is "the
  /// watcher list is on screen, rendering this person's state right now". It
  /// decides `NotificationDelivery.redundant`, whose whole meaning is *the
  /// reader is looking at the screen that already shows this*, and `redundant`
  /// **consumes the day without posting anything**.
  ///
  /// Getting that wrong is a silent lost warning, and it happened. Reconciling
  /// on app open — added so a force-stopped watcher repairs itself — ran with a
  /// hard-coded `true` while the user sat on the **Tap screen**. The warning was
  /// decided, recorded as standing, and never shown to anyone. Measured on the
  /// POCO F3: `warningsShownFor` held `warnOnline` for the day with zero
  /// notifications posted.
  ///
  /// So the flag is a parameter, and the only caller that may pass true is the
  /// list itself.
  WatcherReconcileService watcherReconcile({
    required bool watcherListShowing,
  }) =>
      WatcherReconcileService(
        store: store,
        clock: clock,
        reader: SimulatedCheckInReader(store),
        notifications: notifications,
        alarms: warningAlarms,
        // `canPost` is checked FIRST inside `NotificationDelivery.from`, so a
        // watcher with notifications revoked still comes out `unavailable`
        // rather than `redundant` — which is what stops a muted phone consuming
        // the access-lost cadence in silence.
        delivery: () async => NotificationDelivery.from(
          canPost: await notifications.canPost(
            channel: NotificationService.warningsChannel,
          ),
          appInForeground: watcherListShowing,
        ),
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

/// The watcher list's state, recomputed by a full reconcile.
///
/// Same shape as [watchedStateProvider] and for the same reason: §3's rule is
/// *reconcile, don't mutate*, so opening the app re-reads everything and
/// re-derives the whole answer rather than rendering a remembered one. On this
/// side that also means **opening the app is a real dead-man's-switch check** —
/// it attempts tier 1, corrects a false warning if a late check-in has arrived,
/// and clears a stale access-lost notice.
final watcherStateProvider =
    AsyncNotifierProvider<WatcherStateNotifier, WatcherState>(
  WatcherStateNotifier.new,
);

class WatcherStateNotifier extends AsyncNotifier<WatcherState> {
  @override
  Future<WatcherState> build() {
    final services = ref.watch(appServicesProvider);
    // True: this provider exists because the list is being rendered, and the
    // row will show whatever is decided here.
    return services
        .watcherReconcile(watcherListShowing: true)
        .reconcile(selfUid: services.selfUid);
  }

  /// Re-reads everything. Called on resume, and after the harness changes the
  /// simulated backend underneath.
  Future<void> refresh() async {
    final services = ref.read(appServicesProvider);
    state = await AsyncValue.guard(
      () => services
          .watcherReconcile(watcherListShowing: true)
          .reconcile(selfUid: services.selfUid),
    );
  }
}

class WatchedStateNotifier extends AsyncNotifier<WatchedState> {
  @override
  Future<WatchedState> build() async {
    final services = ref.watch(appServicesProvider);
    // BEFORE the first reconcile, and the order is load-bearing — see
    // [_cacheDeviceZone].
    await _cacheDeviceZone(services);
    return services.watchedReconcile.reconcile(selfUid: services.selfUid);
  }

  /// Caches the device's IANA zone, and is called **before the first
  /// reconcile**.
  ///
  /// On a fresh install `LocalStore.deviceTimezone()` is null, so a reconcile
  /// that runs first takes ADR-0002's documented UTC fallback and arms the whole
  /// window at **UTC wall times** — 14:00 / 20:00 / 23:00 in Madrid rather than
  /// 12:00 / 18:00 / 21:00. Measured on the POCO F3 on 2026-08-17: 19 alarms,
  /// every one an hour or two late, with `device_timezone` already correctly
  /// stored beside them.
  ///
  /// Before [ADR-0006][] a second reconcile ran behind the first and quietly
  /// corrected the times — while stranding one alarm doing it, which is the
  /// defect that produced the ADR. Now that run is correctly refused as
  /// concurrent, so **nothing corrects them** until the next resume: a 23:00
  /// nudge to someone who may well be asleep, for up to the depth of the window.
  ///
  /// Ordering the two removes the failure instead of repairing it, which is the
  /// better fix in any case — the UTC pass never made sense, it was only ever
  /// cheap to undo.
  ///
  /// **Never allowed to fail the load.** A zone lookup that throws leaves
  /// whatever is already cached and lets `reconcile()` fall back as designed; an
  /// exception escaping here would put the provider into `AsyncError` and show
  /// *"this phone could not get ready"* for a plugin hiccup, on the screen whose
  /// whole job is to be there every morning.
  ///
  /// [ADR-0006]: ../../docs/architecture/decisions/0006-reconcile-is-serialised-on-disk.md
  Future<void> _cacheDeviceZone(AppServices services) async {
    try {
      final zone = await services.clockService.deviceTimezone();
      if (zone != null) await services.store.setDeviceTimezone(zone);
    } on Object {
      // Swallowed deliberately; see above.
    }
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
    await _cacheDeviceZone(services);
    await refresh();
  }
}
