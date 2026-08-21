import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
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
    required this.auth,
  });

  final LocalStore store;
  final Clock clock;
  final NotificationService notifications;
  final AlarmScheduler alarms;
  final PermissionService permissions;
  final ClockService clockService;

  /// **Whose links these are** — the Firebase uid, read from `LocalStore` at
  /// launch, or [LocalStore.signedOutUid] when nobody is signed in.
  ///
  /// Read from the store rather than from `FirebaseAuth` even here, where both
  /// are available, so that the UI and the alarm isolate are answering from the
  /// *same* row. Two sources agreeing today is not the same as two sources that
  /// cannot disagree — and the whole reason this value is on disk is that §4's
  /// isolates share no memory. [LocalStore.selfUid] carries the argument for
  /// which failure shape that buys.
  ///
  /// It is a snapshot: signing in or out rebuilds `AppServices`, because
  /// changing identity changes every answer below it.
  final String selfUid;

  /// Google Sign-In → the Firebase uid (§6). UI isolate only.
  final AuthRepository auth;

  /// Whether anybody is signed in. Nothing is watched, armed or owed otherwise.
  bool get signedIn => selfUid != LocalStore.signedOutUid;

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

  /// The link [linkId] names, if this user watches it — otherwise null.
  ///
  /// **On `AppServices` rather than reached for directly from a widget.** §5's
  /// arrows are Presentation → Application → Domain, with Data driven by
  /// Application; `main.dart` was calling `store.linksWatchedBy` from a widget,
  /// which inverts that for one lookup.
  ///
  /// It exists because a notification payload is an **untrusted hint** — see
  /// `NotificationRouter.tappedLink`. The concrete attack is not hypothetical:
  /// `MainActivity` is exported, as every LAUNCHER activity must be, so a
  /// co-installed app can start it with an intent carrying a payload extra, and
  /// `getNotificationAppLaunchDetails()` hands that string straight back. Before
  /// this existed, any non-null value pushed a screen.
  ///
  /// ## It returns the `Link`, not a bool, and that is the whole point
  ///
  /// A bool answers *"is this string one of mine"* and then leaves the caller
  /// holding the string — which invites exactly the Phase 4 shape this is meant
  /// to prevent: `if (await watches(id)) read('links/$id')`, membership proven
  /// against a local cache and the raw payload dereferenced anyway. Handing back
  /// the resolved object means the string can be dropped at the boundary.
  ///
  /// ## What it is not
  ///
  /// **It is a UX affordance, not an authorisation control, and it can never
  /// become one.** `LocalStore` is a decision cache — the threat model's trust
  /// boundary 4 says it is never an authorisation record — so this proves only
  /// that *this device once wrote a row saying so*. From Phase 4 the thing
  /// standing between a crafted payload and a stranger's data is the security
  /// rule on `links/{id}` and `checkins/{uid}/days/{date}`. Resolve here, and
  /// let the rules deny; never let this stand in for them.
  ///
  /// ## Revoked links resolve, deliberately
  ///
  /// The security review proposed filtering on `Link.isAccepted`. That is right
  /// for any future *read* path and wrong for this one, which decides whether to
  /// open a screen. A notification posted before revocation can still be sitting
  /// in the tray, and the watcher list has a revoked row — *"Your link with Mum
  /// has ended."* — that exists precisely to explain it. Filtering here would
  /// make that tap do nothing at all: no screen, no explanation, on the one
  /// surface that could give one. A caller that needs an *accepted* link must
  /// check `isAccepted` on the value returned, where the distinction is visible.
  Future<Link?> resolveWatchedLink(String linkId) async {
    for (final link in await store.linksWatchedBy(selfUid)) {
      if (link.id == linkId) return link;
    }
    return null;
  }

  /// Caches the two device facts a bare isolate cannot ask for.
  ///
  /// **One implementation, on `AppServices`, because there are three callers and
  /// the last round left two copies of it.** `main()` had it written out and so
  /// did `WatchedStateNotifier` — same two facts, same two guards, same order,
  /// created by the very round that was fixing *this fact* having two sources.
  /// They agreed, but the next person to change one had no signal to change the
  /// other. `NotificationService.watcherDelivery` carries the rule this follows:
  /// *"two copies of a decision are two chances to make it"*, written after both
  /// wiring defects of this phase turned out to be in a copy of one expression.
  ///
  /// ## Two facts, two guards
  ///
  /// Only the zone calls a plugin. Sharing one `try` meant a `flutter_timezone`
  /// hiccup — the exact thing the guard exists to swallow — silently skipped the
  /// clock format too, leaving a 12-hour device on the 24-hour default for the
  /// whole session.
  ///
  /// ## And the two facts refresh differently — measured on the POCO F3
  ///
  /// The **zone** is a live plugin call, so calling this on resume genuinely
  /// re-reads it. The **clock format** is `platformDispatcher
  /// .alwaysUse24HourFormat`, which Flutter refreshes only when Android delivers
  /// a configuration change: two successive background→resume cycles wrote the
  /// stale value in both directions, while a cold start and a config-change
  /// resume wrote the correct one. So this method is not the single source of
  /// freshness it reads as — see `LocalStore.uses24HourClock` for the
  /// measurement and what it does and does not cost.
  ///
  /// ## Never allowed to fail its caller
  ///
  /// A lookup that throws leaves whatever is already cached and lets
  /// `reconcile()` fall back as designed (ADR-0002's documented UTC fallback).
  /// An exception escaping into `WatchedStateNotifier.build()` would put the
  /// provider into `AsyncError` and show *"this phone could not get ready"* for a
  /// plugin hiccup, on the screen whose whole job is to be there every morning.
  Future<void> cacheDeviceFacts() async {
    try {
      final zone = await clockService.deviceTimezone();
      if (zone != null) await store.setDeviceTimezone(zone);
    } on Object {
      // Swallowed deliberately; see above.
    }
    try {
      await store.setUses24HourClock(clockService.uses24HourClock());
    } on Object {
      // Swallowed deliberately; see above.
    }
  }

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
        // **Not gated on `kDebugMode`, unlike the clock offset — and the
        // difference is worth stating, because the security review reasonably
        // asked why.**
        //
        // `main.dart` gates `debug_clock_offset_ms` so that "zero in every
        // release build" is enforced by the reading code rather than resting on
        // the writer being compiled out — a restore or a rooted device could
        // otherwise put a row there. That argument applies just as well to
        // `debug_simulated_backend`, which decides whether a family is warned.
        //
        // It cannot be applied, because the two are not symmetric: the clock
        // offset has a real fallback (`Duration.zero`) and this has none. In
        // Phase 3 the simulated reader **is** the implementation — there is no
        // Firebase dependency to fall back to — so gating it would leave a
        // release build with no reader at all rather than with a safe default.
        //
        // Phase 4 replaces this line with the real Firestore reader and the
        // question disappears. If for any reason it does not, gate it then,
        // when there is something to fall back to.
        reader: SimulatedCheckInReader(store),
        notifications: notifications,
        alarms: warningAlarms,
        // One shared derivation, in `NotificationService`, rather than a copy
        // here and another in the alarm isolate. Both wiring defects this phase
        // produced lived in a copy of this expression — see
        // [NotificationService.watcherDelivery].
        delivery: () =>
            notifications.watcherDelivery(appInForeground: watcherListShowing),
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

  /// The warnings-off banner's action, then a full reconcile so the banner
  /// disappears the moment it stops being true.
  ///
  /// Android stops showing the prompt after two refusals, at which point this
  /// is a no-op and the banner is the honest dead end — the same trade the Tap
  /// screen's twin already makes.
  Future<void> requestNotifications() async {
    final services = ref.read(appServicesProvider);
    await services.permissions.requestNotifications();
    await refresh();
  }
}

class WatchedStateNotifier extends AsyncNotifier<WatchedState> {
  @override
  Future<WatchedState> build() async {
    final services = ref.watch(appServicesProvider);
    // BEFORE the first reconcile, and the order is load-bearing — see
    // [AppServices.cacheDeviceFacts] and the paragraph below.
    await services.cacheDeviceFacts();
    return services.watchedReconcile.reconcile(selfUid: services.selfUid);
  }

  /// Caches the two device facts a background isolate cannot ask for, and is
  /// called **before the first reconcile**.
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


}
