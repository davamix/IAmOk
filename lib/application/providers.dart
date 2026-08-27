import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../data/away_repository.dart';
import '../data/check_in_repository.dart';
import '../data/check_in_reader.dart';
import '../data/debug_backend_override.dart';
import '../data/firestore_check_in_reader.dart';
import '../data/invite_service.dart';
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
  ///
  /// **Phase 5 gave that sentence a mechanism.** Until onboarding existed the
  /// only way to sign in was the debug harness, whose own button says *"RESTART
  /// the app: selfUid is read once, at launch"* — which is not something a real
  /// sign-in screen may ask an 80-year-old to do. [signedInUidProvider] now holds
  /// the live value and [appServicesProvider] derives from it, so signing in
  /// rebuilds this object and everything watching it.
  final String selfUid;

  /// The same services, for a different account.
  ///
  /// Every field except [selfUid] is a property of the *phone* — the store, the
  /// clock, the notification channels, the alarm scheduler — so identity is the
  /// only thing that changes. Rebuilding rather than mutating is the point: §3's
  /// rule is that nothing patches state incrementally, and a mutable uid under a
  /// tree that has already read it is exactly the incremental patch that rule
  /// forbids.
  AppServices withSelfUid(String uid) => AppServices(
    store: store,
    clock: clock,
    notifications: notifications,
    alarms: alarms,
    permissions: permissions,
    clockService: clockService,
    selfUid: uid,
    auth: auth,
    push: _push,
  );

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
    // Null when nobody is signed in, for the same reason and with the same
    // consequence: there is no `users/{uid}/shared/away` to read. The CACHED
    // period is still honoured — expiry is arithmetic and needs no server
    // (§12) — so a phone that signs out mid-holiday does not start nagging.
    away: signedIn ? AwayRepository() : null,
    selfUid: selfUid,
  );

  /// The away document, read and written directly under the rules (§8, §12).
  ///
  /// A **direct client write** rather than a callable, on purpose: it queues
  /// offline like any other Firestore write, which is what lets a watcher set
  /// away on a plane. Exposed separately from [watchedReconcile] because the
  /// *watcher* writes it too, for somebody else's uid.
  AwayRepository get awayDocument => AwayRepository();

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

  /// Marks onboarding complete when this account **already has links**.
  ///
  /// ## Why this exists rather than living in `HomeRoute.decide`
  ///
  /// Two different questions were being answered by one expression: *is
  /// onboarding over* and *does this user have a role*. Unioning them meant
  /// answering a question mid-flow ended the flow — the summary screen was
  /// unreachable, measured on two phones — and a flow killed between question 1
  /// and *Finish* never resumed.
  ///
  /// `HomeRoute.decide` now ends onboarding on `completed` alone. This is what
  /// keeps the reinstall case working: §1 chose Google Sign-In because **the uid
  /// survives a reinstall, so links never break**, so a wiped store can belong to
  /// somebody already watching three people. For them the two questions were
  /// answered by **action**, and asking again would be the app failing to
  /// recognise somebody it is already relaying for.
  ///
  /// Called from `main()` after `syncLinks()`, and again after an in-app
  /// sign-in — the two moments a link set can appear under a store that has
  /// never seen it.
  ///
  /// **Idempotent, and it never un-completes.** It only ever sets the flag, only
  /// when there is an accepted link, and it returns immediately once the flow is
  /// complete — so it cannot interrupt somebody who is mid-flow *and* paired,
  /// which is the ordinary state of anyone who just used the code screen.
  ///
  /// Never allowed to fail its caller, the same rule as [cacheDeviceFacts] and
  /// [syncLinks]: this runs before the first frame, and the worst it can cost is
  /// one extra pass through two questions.
  Future<void> settleOnboardingIfPaired() async {
    try {
      final choices = await store.onboardingChoices();
      if (choices.completed || !signedIn) return;

      // `LocalStore`'s two names read the opposite way round to these — see
      // `linkRolesProvider`, which spells the same trap out at its own call
      // site.
      final somebodyWatchesMe = await store.linksWatching(selfUid);
      final iWatchSomebody = await store.linksWatchedBy(selfUid);
      final paired = somebodyWatchesMe.any((link) => link.isAccepted) ||
          iWatchSomebody.any((link) => link.isAccepted);
      if (!paired) return;

      await store.setOnboardingChoices(choices.copyWith(completed: true));
    } on Object {
      // Swallowed deliberately; see above.
    }
  }

  /// `users/{uid}` and its token subcollection (§7). UI isolate only.
  UserRepository get users => UserRepository();

  /// Re-writes `users/{uid}` from what this device currently knows.
  ///
  /// ## Without this, three approved sentences name an action that cannot work
  ///
  /// `upsert` had exactly **one** caller — the sign-in screen — so nothing
  /// re-wrote the profile afterwards, ever. That made three refusals dishonest,
  /// and worse than a dead end, because a dead end at least stops:
  ///
  /// - `InviteRefusal.profileMissing` and `PairingRefusal.watcherProfileMissing`
  ///   both say *"This phone could not finish getting ready. Try again."* and
  ///   offer a **Try again** button that re-ran the identical failing call.
  /// - `watchedProfileMissing` and `unusableTimezone` say *"Ask them to open
  ///   I Am Ok on their phone, then try again."* — and opening the app did not
  ///   re-write their profile or their timezone, so the family could carry out
  ///   the instruction any number of times and nothing would change.
  ///
  /// Called on **resume**, which is also where `guidelines.md`'s *health is
  /// state, not a gate* principle puts it: the timezone is a device fact that
  /// changes while the app is backgrounded, and `redeemInvite` denormalises it
  /// onto every link it creates.
  ///
  /// Never allowed to fail its caller, the same rule as [cacheDeviceFacts]: a
  /// write that throws leaves the previous document, which is the correct
  /// outcome, and an exception escaping into a resume would replace whatever
  /// screen the reader opened.
  Future<void> refreshProfile() async {
    if (!signedIn) return;
    try {
      await users.upsert(
        uid: selfUid,
        displayName: auth.displayName ?? 'Someone',
        timezone: await store.deviceTimezone() ?? 'Etc/UTC',
      );
    } on Object {
      // Swallowed deliberately; see above.
    }
  }

  /// Pairing — the two callables (§6, §9). **UI isolate only.**
  ///
  /// No background entry point may reach this. A nudge carries no authority
  /// (§3), and an isolate with seconds to live has nothing to ask a function;
  /// `test/domain/domain_purity_test.dart` is what holds that line, because
  /// `cloud_functions` is a plugin and a bare isolate has no registrant for it.
  InviteService get invites => InviteService();

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
  }) => WatcherReconcileService(
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

/// The composition root as `main()` built it, at launch, for whoever was signed
/// in **then**.
///
/// Overridden in `main()`. Reading it without that override is a wiring bug, and
/// failing loudly here beats a half-built app.
///
/// Nothing outside this file should read it: [appServicesProvider] is the one
/// that knows who is signed in *now*.
final launchServicesProvider = Provider<AppServices>(
  (ref) =>
      throw StateError('launchServicesProvider must be overridden in main()'),
);

/// Whose app this is, right now.
///
/// Seeded from the launch-time snapshot and moved by onboarding's sign-in and by
/// sign-out. It exists because Phase 5 put a **sign-in screen inside the app**:
/// before that the only route was the debug harness, which could honestly tell a
/// developer to restart, and onboarding cannot tell a family to.
///
/// The uid is written to `LocalStore` by `AuthRepository.signIn` on the same
/// path — that row is what §4's background isolates read, and this notifier is
/// what the *UI* reads. Two readers of one fact, deliberately, because the
/// isolates share no memory and only one of them can hold state in RAM.
class SignedInUid extends Notifier<String> {
  @override
  String build() => ref.watch(launchServicesProvider).selfUid;

  /// After a successful sign-in. Rebuilds [appServicesProvider] and everything
  /// derived from it, which is how the reconcilers start answering for the new
  /// account without a restart.
  void signedInAs(String uid) => state = uid;

  /// After [AppServices.signOut]. `LocalStore.clearSelfUid` has already taken
  /// the cache and the links; this is the in-memory half of the same fact.
  void signedOut() => state = LocalStore.signedOutUid;
}

final signedInUidProvider =
    NotifierProvider<SignedInUid, String>(SignedInUid.new);

/// The services **for the account that is signed in now**.
///
/// A derived provider rather than the overridden one, so that a sign-in during
/// onboarding rebuilds it and every dependent — `watchedStateProvider` and
/// `watcherStateProvider` both `ref.watch` this, so both re-reconcile under the
/// new identity rather than going on answering for the previous one.
///
/// Still overridable with a plain value: every widget test in this suite does
/// exactly that, and a test that supplies a whole `AppServices` is stating the
/// identity along with everything else.
final appServicesProvider = Provider<AppServices>((ref) {
  final launched = ref.watch(launchServicesProvider);
  final uid = ref.watch(signedInUidProvider);
  // Identity-equal in the overwhelmingly common case — the app launched signed
  // in and nobody has signed in or out since — so this does not rebuild the
  // world on every read.
  return launched.selfUid == uid ? launched : launched.withSelfUid(uid);
});

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
    if (userInitiated) {
      state = next;
      return;
    }
    // **A pass nobody asked for may not replace the list with an error.**
    //
    // `AsyncValue.guard` turns a throw into `AsyncError`, and `WatcherScreen`
    // renders that as the whole-screen *"This phone could not check on
    // anyone."* — so a reader looking at a standing warning about Mum, who
    // asked for nothing, loses it to an error page because somebody else
    // tapped. `_onForegroundPush`'s own `try` cannot help: the state was
    // already set in here.
    //
    // The exact shape of `WatchedStateNotifier.refresh`'s `tapFailed` rule one
    // file along — *a reconcile she did not ask for must not take away the one
    // thing she has* — and the same answer: keep the last good value. Stale
    // beats absent, and the row's own *"This phone last checked …"* line is
    // what makes the staleness visible rather than silent.
    //
    // A refresh the reader **asked** for still surfaces the error, because they
    // are waiting for an answer and an unexplained non-update would be worse.
    if (value == null && state.hasValue) return;
    state = value == null
        ? next
        : AsyncData(value.copyWith(userInitiated: false));
  }

  /// Asks for `POST_NOTIFICATIONS` once, on first run — **on this side too.**
  ///
  /// Marks [watchedUid] away, or extends an existing period, then reconciles.
  ///
  /// **A watcher writing somebody else's away document is the design, not a
  /// loophole** (§12). *"Anyone in the group can set, extend or cancel it. No
  /// approval."* — a watcher setting away is asserting *"I know she's fine, and
  /// I'm accountable for that"*, which is exactly what happens when somebody is
  /// in hospital and least able to answer a prompt. The rules permit it on an
  /// accepted link, and `setBy` is what makes it accountable afterwards.
  ///
  /// **Nothing is written to the cache here.** The reconcile that follows reads
  /// the document back, and only a read that *succeeded* replaces `away`
  /// (ADR-0001 decision 1). Optimistically caching the period would be the one
  /// shortcut this side cannot take: a write that was refused would leave this
  /// watcher silenced about somebody for up to a month, with no notification and
  /// no error — which is the direction §12 calls the one failure this app cannot
  /// detect in itself.
  Future<AwayOutcome> setAway({
    required String watchedUid,
    required DayKey lastDay,
    required DayKey watchedToday,
    AwayPeriod? existing,
  }) async {
    final services = ref.read(appServicesProvider);
    final period = AwayPeriod.tryCreate(from: watchedToday, through: lastDay);
    if (period == null) {
      return const AwayOutcome.refused(AwayRefusal.rejectedPeriod);
    }

    final outcome = await services.awayDocument.write(
      watchedUid: watchedUid,
      // **The caller's uid, never the watched person's.** ADR-0003 rule 1, and
      // the rules enforce `setBy == request.auth.uid` — so writing anything else
      // here is not a misattribution, it is a rejected write.
      setBy: services.selfUid,
      setByName: services.auth.displayName ?? 'Someone',
      period: period,
      today: watchedToday,
      existing: existing,
    );

    await refresh();
    return outcome;
  }

  /// Ends an away period this watcher can see — **truncating, not deleting**.
  ///
  /// ADR-0001 decision 5, and the same arithmetic as the watched side's twin:
  /// `AwayPeriod.cancelOn` decides between truncate and delete, and only the
  /// one case where truncating would violate `through >= from` deletes.
  ///
  /// Re-attributed to whoever wrote last, per §12's last-write-wins: a
  /// truncation keeping the original `setByName` would tell the family that the
  /// person who set the holiday also cut it short.
  Future<AwayOutcome> endAway({
    required String watchedUid,
    required AwayPeriod existing,
    required DayKey watchedToday,
  }) async {
    final services = ref.read(appServicesProvider);
    final truncated = existing.cancelOn(watchedToday);
    final outcome = truncated == null
        ? await services.awayDocument.cancel(watchedUid: watchedUid)
        : await services.awayDocument.write(
            watchedUid: watchedUid,
            setBy: services.selfUid,
            setByName: services.auth.displayName ?? 'Someone',
            period: truncated,
            today: watchedToday,
            existing: existing,
          );

    await refresh();
    return outcome;
  }

  /// The twin of `WatchedStateNotifier.ensureNotificationsAsked`, and it did not
  /// exist until Phase 5 routed on role. Before that the Tap screen was home and
  /// asked for everybody; now a **watcher-only** user never sees it, and on API
  /// 33+ the permission is denied by default — so their very first screen was
  /// the red *"This phone will not warn you about anyone."* banner, about a
  /// permission the app had never requested.
  ///
  /// This is the person whose entire role is receiving warnings. §13 rates their
  /// losing the permission High precisely because Android takes it back from
  /// apps nobody opens, and starting them out without it is that state on day
  /// one.
  ///
  /// Only asks when the OS says notifications are currently off, so a granted
  /// install never sees a prompt.
  Future<void> ensureNotificationsAsked() async {
    final services = ref.read(appServicesProvider);
    if (await services.permissions.notificationsEnabled()) return;
    await services.permissions.requestNotifications();
    await refresh();
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

  /// Sets or extends this person's own away period, then reconciles.
  ///
  /// **Reconciles rather than patching the state in place** (§3). The reconcile
  /// re-reads the document from Firestore, so what the screen ends up showing is
  /// what the server actually holds — including the case where the write was
  /// refused, where the screen correctly goes back to *not away* rather than
  /// showing a period nobody else can see.
  ///
  /// The outcome is handed back for the screen to render, and is **not** put on
  /// the state: it is a fact about one action, not about the person, and the
  /// next reconcile would have to remember to clear it. Same shape as `tap()`'s
  /// deliberate exception: only the initial load may take the screen away.
  Future<AwayOutcome> setAway(DayKey lastDay) async {
    final services = ref.read(appServicesProvider);
    final current = state.value;
    if (current == null) {
      return const AwayOutcome.refused(AwayRefusal.serverFault);
    }

    final period = AwayPeriod.tryCreate(from: current.today, through: lastDay);
    if (period == null) {
      // `through` before `from` — the picker cannot produce it, and a period
      // that ends before it starts must surface as a refusal rather than as an
      // exception. `AwayPeriod` makes it unrepresentable; this is the boundary
      // where that guarantee is taken up.
      return const AwayOutcome.refused(AwayRefusal.rejectedPeriod);
    }

    final outcome = await services.awayDocument.write(
      watchedUid: services.selfUid,
      setBy: services.selfUid,
      // The Google profile name, the same value `users/{uid}` carries and the
      // same fallback `upsertProfile` uses. It is a display LABEL and not an
      // identity (ADR-0003) — `setBy` beside it is what is enforced.
      setByName: services.auth.displayName ?? 'Someone',
      period: period,
      today: current.today,
      existing: current.away?.period,
    );

    await refresh();
    return outcome;
  }

  /// Ends the away period — **truncating, not deleting** (ADR-0001 decision 5).
  ///
  /// `through` is pulled back to the last genuinely-away day, so the days
  /// already spent away stay covered. Deleting mid-period would retroactively
  /// un-cover them, and the next device to refresh its cache would warn about a
  /// day the person really was away — a false claim to a family, which is the
  /// worst thing this app can do.
  ///
  /// `AwayPeriod.cancelOn` returns null for the one case where truncating is
  /// impossible — cancelling on the day the period **starts**, where
  /// `through = from - 1` would violate `through >= from` — and only then is
  /// the document deleted. The arithmetic is the domain's; this only carries out
  /// the answer.
  Future<AwayOutcome> endAway() async {
    final services = ref.read(appServicesProvider);
    final current = state.value;
    final away = current?.away;
    if (current == null || away == null) {
      return const AwayOutcome.refused(AwayRefusal.serverFault);
    }

    final truncated = away.period.cancelOn(current.today);
    final outcome = truncated == null
        ? await services.awayDocument.cancel(watchedUid: services.selfUid)
        : await services.awayDocument.write(
            watchedUid: services.selfUid,
            // Re-attributed to whoever wrote last — §12 is last-write-wins, and
            // a truncation that kept the original `setByName` would tell the
            // family the person who set the holiday also cut it short.
            setBy: services.selfUid,
            setByName: services.auth.displayName ?? 'Someone',
            period: truncated,
            today: current.today,
            existing: away.period,
          );

    await refresh();
    return outcome;
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
