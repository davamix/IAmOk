import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../data/check_in_repository.dart';
import '../data/check_in_reader.dart';
import '../data/debug_backend_override.dart';
import '../data/firestore_check_in_reader.dart';
import '../data/link_repository.dart';
import '../data/local_store.dart';
import '../data/push_registration.dart';
import '../data/user_repository.dart';
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
    // Private, so it cannot be an initialising formal — a named parameter may
    // not bind to a private field. Same shape as the repositories' `_injected`.
    PushRegistration? push,
    // ignore: prefer_initializing_formals
  }) : _push = push;

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
        // Null when nobody is signed in, and the service treats that as "record
        // it locally and sync nothing" rather than as an error. A tap on a
        // signed-out phone is still a tap: the screen must still say
        // "You already tapped today", because the person did.
        checkIns: signedIn ? CheckInRepository() : null,
        selfUid: selfUid,
      );

  /// Links, from Firestore into `LocalStore` (§6). UI isolate only.
  ///
  /// The background isolates never sync: they read whatever the last successful
  /// sync left on disk, which is §4's rule that what a bare isolate needs is
  /// already there. An alarm firing on a link the server revoked an hour ago
  /// still decides correctly, because §10 step 2 reads `link.status` and the
  /// read it makes will be refused anyway.
  LinkRepository get links => LinkRepository();

  /// Refreshes the local link set, and says whether it managed to.
  ///
  /// Called on launch and on resume, before either side reconciles — links are
  /// the input every other decision is derived from, so reconciling first would
  /// decide against the previous session's picture.
  ///
  /// **Never allowed to fail its caller**, the same rule as
  /// [cacheDeviceFacts]: a sync that throws leaves the last good link set in
  /// place, which is exactly what should happen, and an exception escaping into
  /// a provider would replace the screen a person opened with an error about a
  /// network call they did not make.
  Future<bool> syncLinks() async {
    try {
      return await links.syncInto(store, selfUid);
    } on Object {
      return false;
    }
  }

  /// `users/{uid}` and its token subcollection (§7). UI isolate only.
  UserRepository get users => UserRepository();

  final PushRegistration? _push;

  /// This install's FCM registration (§7, tier 2). UI isolate only.
  ///
  /// The background isolates never register anything: a token is a fact about
  /// *this install*, established while somebody is signed in, and the isolates
  /// that could run without one have nothing to do with acquiring it.
  ///
  /// Injectable for the same reason [auth] is: [signOut]'s **ordering** is a
  /// security property — the token document has to go before the session does —
  /// and it was guaranteed by nothing but two adjacent lines until a test could
  /// watch them run.
  PushRegistration get push => _push ?? PushRegistration(users);

  /// Makes this install reachable by push, and never fails its caller.
  ///
  /// **Fired, not awaited, by every caller** — the same rule as the check-in
  /// write, for a weaker version of the same reason. `getToken()` is a network
  /// round trip through Play Services, so awaiting it on a phone with no signal
  /// would delay a launch for tier 2, which §3 prices at *latency, never
  /// correctness*. Nothing on any screen depends on the answer.
  ///
  /// Signed out is not an error and not a no-op worth reporting: there is no
  /// `users/{uid}` to file a token under, and the next sign-in registers.
  Future<String?> registerForPush() async {
    if (!signedIn) return null;
    return push.register(uid: selfUid);
  }

  /// Signs out, **taking this install's push registration with it first**.
  ///
  /// The order is the whole reason this exists rather than the two calls being
  /// made wherever a sign-out happens. `firestore.rules` grants the token delete
  /// to `isSelf(uid)` only, so signing out first leaves a document *nothing on
  /// this device may ever remove* — and `onCheckInCreated` would go on sending
  /// this person's check-ins to a phone that has since signed into somebody
  /// else's account. Neither party would see anything wrong.
  ///
  /// The delete is bounded and best-effort ([PushRegistration.unregister] both
  /// times out and swallows), because a sign-out must complete regardless.
  ///
  /// ## The uid is the LIVE one, and using the snapshot was a real hole
  ///
  /// This read `selfUid`, and guarded on `signedIn`, which is derived from it —
  /// and [selfUid] is **the launch-time snapshot**. Sign in and sign out again
  /// without restarting and the snapshot is still `signedOutUid`, so the guard
  /// is false and the unregister is **skipped entirely** — while the sign-in
  /// path has demonstrably registered a token under the new uid, because the
  /// harness passes the fresh uid explicitly for exactly this reason.
  ///
  /// So the one case `signOut` exists to prevent was the one case it did not
  /// cover. Debug-only today, since production sign-in needs a restart; it stops
  /// being debug-only the moment Phase 5 builds a real sign-in screen, which is
  /// why it is fixed now rather than noted.
  ///
  /// `auth.currentUid` is the right source here specifically: it is the identity
  /// the security rules will judge the delete against, and the token was
  /// registered under it. The store snapshot remains the right source
  /// everywhere a *background isolate* has to agree with the UI — see
  /// [LocalStore.selfUid] — and those are different questions.
  Future<void> signOut() async {
    final uid = auth.currentUid ?? (signedIn ? selfUid : null);
    if (uid != null) {
      try {
        await push.unregister(uid: uid);
      } on Object {
        // **Belt as well as braces.** `unregister` already swallows and times
        // out, so this catches nothing today. It is here because the property
        // that matters is *the session ends*: if that call ever threw for a
        // reason nobody anticipated, the user would be left signed in, looking
        // at a button that does nothing — the same failure the timeout inside
        // `unregister` exists to prevent, arriving by the other route.
      }
    }
    await auth.signOut();
  }

  /// **The tier-1 read, as every isolate composes it** — Firestore, with the
  /// harness able to stand in front of it in a debug build and nowhere else.
  ///
  /// A getter rather than a field so the clock it closes over is the one this
  /// `AppServices` holds, including the harness's forced offset. A reader built
  /// at construction with `DateTime.now` would ask about a different set of days
  /// from the one the policy then decides about — the two disagreeing about what
  /// day it is, which is the class of defect §11 exists to prevent.
  CheckInReader get checkInReader => DebugBackendOverride(
        store: store,
        real: FirestoreCheckInReader(now: clock.now),
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
        // Firestore, with the harness able to override it in a debug build
        // — see [checkInReader] and `DebugBackendOverride`.
        //
        // **The `kDebugMode` gate the Phase 3 security review asked for is now
        // applied.** It could not be then, and the reason was recorded here: the
        // clock offset has a real fallback (`Duration.zero`) and the simulated
        // reader had none, because in Phase 3 it *was* the implementation, so
        // gating it would have left a release build with no reader at all
        // rather than with a safe default. This paragraph promised the question
        // would disappear when the real reader arrived. It has.
        reader: checkInReader,
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

  /// Re-reads everything. Called on resume, on pull-to-refresh, and after the
  /// harness changes the simulated backend underneath.
  ///
  /// [userInitiated] is false when something the person did not do triggered
  /// this — today only a foreground FCM nudge (`_onForegroundPush`). It decides
  /// one thing on this side: whether a row that **changed** is announced to a
  /// screen reader.
  ///
  /// The twin of `WatchedStateNotifier.refresh`'s parameter, and the mirror
  /// image of what it protects. There an unasked-for reconcile *removed* the one
  /// instruction she had. Here it *replaces* a claim about a relative with a
  /// different one, silently: `NotificationDelivery.redundant` posts nothing and
  /// records the day as seen on the argument that the list renders the change
  /// itself — true while `redundant` was reached by navigating here, and false
  /// the moment a push can change the list under someone already on it. Nothing
  /// re-reads a changed widget, so a TalkBack reader is told nothing at all and
  /// no notification is ever coming.
  ///
  /// A resume is deliberately **user-initiated**: the reader is arriving at the
  /// screen and will read the row themselves, and announcing every refresh is
  /// noise. See `docs/ui-ux/screens.md`.
  Future<void> refresh({bool userInitiated = true}) async {
    final services = ref.read(appServicesProvider);
    final next = await AsyncValue.guard(
      () => services
          .watcherReconcile(watcherListShowing: true)
          .reconcile(selfUid: services.selfUid),
    );
    final value = next.value;
    state = userInitiated || value == null
        ? next
        : AsyncData(value.copyWith(userInitiated: false));
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
  ///
  /// [userInitiated] is false when something the person did not do triggered
  /// this — today only an FCM nudge (`_onForegroundPush`). It decides one thing:
  /// whether *"That did not save. Please tap again."* survives.
  ///
  /// **A reconcile she did not ask for must not delete the one instruction she
  /// has.** `tapFailed` is transient screen state rather than something stored,
  /// so a plain refresh clears it: her tap fails, the red line appears, and a
  /// push arriving three seconds later removes it with no user action. Nothing
  /// becomes *false* — the target stays enabled and correct — she simply loses
  /// the sentence telling her what to do, on the screen this app exists for.
  ///
  /// On a **resume** clearing it is right: she has come back to the screen and
  /// the reconcile is the fresh answer. That is why this is a parameter rather
  /// than a blanket carry-forward.
  ///
  /// Near-unreachable in Phase 4 — a watched person receives no push unless they
  /// also watch someone — and reachable in Phase 6, when `onAwayChanged` fans
  /// out to the watched person's own device.
  Future<void> refresh({bool userInitiated = true}) async {
    final services = ref.read(appServicesProvider);
    final hadFailedTap = !userInitiated && (state.value?.tapFailed ?? false);
    final next = await AsyncValue.guard(
      () => services.watchedReconcile.reconcile(selfUid: services.selfUid),
    );
    final value = next.value;
    state = hadFailedTap && value != null
        ? AsyncData(value.copyWith(tapFailed: true))
        : next;
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
