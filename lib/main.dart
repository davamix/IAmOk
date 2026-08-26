import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/onboarding_controller.dart';
import 'application/providers.dart';
import 'application/push_handler.dart';
import 'application/watcher_reconcile_service.dart';
import 'copy/tap_copy.dart';
import 'data/auth_repository.dart';
import 'data/firebase_bootstrap.dart';
import 'data/local_store.dart';
import 'domain/domain.dart';
import 'platform/alarm_scheduler.dart';
import 'platform/clock.dart';
import 'platform/clock_service.dart';
import 'platform/notification_router.dart';
import 'platform/notification_service.dart';
import 'platform/permission_service.dart';
import 'presentation/app_theme.dart';
import 'presentation/onboarding_screen.dart';
import 'presentation/tap_screen.dart';
import 'presentation/watcher_screen.dart';

/// The **UI isolate's** entry point.
///
/// Two of the three isolates that run this app never come through here (§4).
/// The alarm and FCM entry points bootstrap themselves from `LocalStore` and
/// share no memory with anything built below — which is why every decision this
/// app makes lives in the domain layer, where it behaves identically in all
/// three.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Parsed from a compiled-in blob, not read from disk, so this is cheap and
  // needs no plugin. The domain layer initialises it lazily too, because the
  // alarm isolate never runs app startup (see TimeZones).
  TimeZones.ensureInitialized();

  // Registers the plugin's own AlarmService and starts the background executor
  // that the alarm isolate is launched from. It must run in the UI isolate
  // before anything is armed — without it `oneShotAt` reports success and the
  // callback is never invoked, which is a silent failure of exactly the kind
  // this side exists to avoid.
  await AndroidAlarmManager.initialize();

  // **In every isolate, not only this one.** The alarm isolate reads Firestore
  // before it decides whether to speak (§10), so it calls the same function from
  // its own entry point — see `FirebaseBootstrap`, which is one implementation
  // precisely so that one of them cannot end up pointed somewhere different.
  await FirebaseBootstrap.ensureInitialized();

  // **Registers §4's third entry point, and it has to happen here.** The plugin
  // records the callback's raw handle so its Android service can start a fresh
  // engine at that function when the app is not running — so a registration
  // made anywhere the app might not reach on a cold start is a registration
  // that is not there when it matters. `pushBackgroundHandler` never runs in
  // this isolate; this line is only how the platform learns where it lives.
  FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);

  final store = await LocalStore.open();

  final notifications = await NotificationService.initialize(
    // Only the UI isolate routes taps. The alarm isolate posts notifications and
    // wires nothing, because there is no screen to open from there.
    onTap: NotificationRouter.instance.onTap,
  );
  final permissions = PermissionService(notifications);

  // A notification that launched the app from cold is not delivered through the
  // callback above — the app was not running to receive it. This is the normal
  // case for the watcher's *lost access* notice, which exists precisely for
  // someone whose app has been closed, so reading it is not an edge case here.
  NotificationRouter.instance.captureLaunch(
    await notifications.launchPayload(),
  );

  // The debug harness's forced date, if one is set. Read from disk rather than
  // held in memory so every isolate agrees about what day it is.
  //
  // Gated on kDebugMode so the claim "zero in every release build" is enforced
  // by the code rather than resting on the fact that the only WRITER is
  // compiled out. Anything that could put a row under `debug_clock_offset_ms`
  // — a restore, a rooted device — would otherwise shift the app's entire
  // notion of now: the day boundary, every reminder instant, and from Phase 3
  // the watcher's warning decision.
  final clock = SystemClock(
    offset: kDebugMode ? await store.clockOffset() : Duration.zero,
  );

  final services = AppServices(
    store: store,
    clock: clock,
    notifications: notifications,
    alarms: NotificationAlarmScheduler(notifications),
    permissions: permissions,
    clockService: const ClockService(),
    // Shared with the alarm isolate through LocalStore, because the two share
    // no memory and an isolate looking up a different uid finds zero links,
    // reconciles nothing, and reports success.
    //
    // **A snapshot taken here, before `runApp`.** Identity decides every answer
    // below it, so signing in or out rebuilds this whole object rather than
    // mutating one field under a tree that has already read it.
    selfUid: await store.selfUid() ?? LocalStore.signedOutUid,
    auth: AuthRepository(store),
  );

  // **The device's zone and clock format, cached before anything reconciles.**
  //
  // `WatchedStateNotifier.build()` awaits this before its own first reconcile —
  // the fix for a defect measured on the POCO F3, where a fresh install armed 19
  // alarms at UTC wall times, an hour or two late each. But `_reconcileWatcherSide`
  // runs from a post-frame callback and awaits nothing, so on the watcher side
  // the same race was still open: `deviceTimezone()` is null on a fresh install,
  // `_watcherZone()` takes ADR-0002's documented UTC fallback, and seven warning
  // alarms are armed at 10:00 **UTC**.
  //
  // It self-heals on the first fire, which is precisely the fire that is two
  // hours late — on a dead man's switch, on day one. Doing it here removes the
  // ordering dependency from both call sites instead of repeating the fix.
  //
  // The procedure itself lives on `AppServices`, because this is one of three
  // callers and it was written out twice — see [AppServices.cacheDeviceFacts].
  await services.cacheDeviceFacts();

  // **Links before anything reconciles.** They are the input every other
  // decision derives from — who the watched side names, and which warning
  // alarms the watcher side arms — so reconciling first would decide against
  // the picture the previous session left behind. On a failed read it does
  // nothing and the previous picture is what gets used, which is the correct
  // outcome and the reason `syncInto` returns a bool rather than throwing.
  await services.syncLinks();

  runApp(
    ProviderScope(
      // `launchServicesProvider`, not `appServicesProvider`: the latter is
      // derived from this plus whoever is signed in *now*, so that onboarding's
      // sign-in rebuilds it without the restart the debug harness could ask a
      // developer for and a family cannot be asked for.
      overrides: [launchServicesProvider.overrideWithValue(services)],
      child: const IAmOkApp(),
    ),
  );
}

class IAmOkApp extends ConsumerStatefulWidget {
  const IAmOkApp({super.key});

  /// **A resume is a real reconcile, not only a launch.**
  ///
  /// The watcher-side repair ran from a post-frame callback and nowhere else, so
  /// it covered the cold start and nothing after it. A watcher who backgrounds
  /// the app and comes back — which is most of how a phone is used — reconciled
  /// only the watched side, because that is the side whose provider rebuilds.
  ///
  /// That matters most in the state it was added for. A force-stop cancels every
  /// alarm and tells the app nothing; opening the app repairs it. But "opening"
  /// after a background-and-return is a *resume*, not a launch, and the repair
  /// did not run there. Android also revokes permissions from apps nobody opens
  /// (§13), and a resume is exactly when that must be re-observed.
  ///
  /// **It defers to the list when the list is showing**, rather than running
  /// alongside it — the list has an observer of its own and passes
  /// `watcherListShowing: true`, which this would contradict.
  ///
  /// The guard is about **noise and duplicate work**, not about a lost warning,
  /// and the distinction matters for whoever changes it next. Running with
  /// `false` while the list shows would post a notification the reader can
  /// already see: mildly wrong. Running with `true` while it does not consumes
  /// the day and shows nobody anything: a lost warning, and the defect measured
  /// on the POCO F3. So if this guard is ever wrong, it must be wrong in the
  /// direction of running — never in the direction of defaulting to `true`.
  ///
  /// ## Why this is a static function and not three lines in the callback
  ///
  /// It was those three lines, and that put a two-input boolean decision
  /// somewhere only a device could reach: inverting the guard leaves a
  /// force-stopped watcher permanently deaf, with the whole suite green and no
  /// device row that would catch it. `docs/testing/strategy.md`'s rule is that if a
  /// test needs a device to answer a question about *logic*, the logic is in the
  /// wrong layer — and a predicate over two enums is logic. The widget now holds
  /// no decision, only a call; the truth table is asserted in
  /// `test/app_lifecycle_test.dart`.
  static bool repairOnResume({
    required AppLifecycleState state,
    required bool watcherListShowing,
  }) =>
      state == AppLifecycleState.resumed && !watcherListShowing;

  @override
  ConsumerState<IAmOkApp> createState() => _IAmOkAppState();
}

class _IAmOkAppState extends ConsumerState<IAmOkApp>
    with WidgetsBindingObserver {
  /// Lets a notification tap navigate without a `BuildContext` from a widget
  /// that may not be mounted yet.
  ///
  /// The cold-start path needs exactly that: the payload is captured in `main()`
  /// before `runApp`, and nothing is on screen to react to it. §13's argument is
  /// that a low-usage watcher never opens the app, so for this notification the
  /// cold start is the *normal* arrival rather than the edge case.
  final _navigator = GlobalKey<NavigatorState>();

  /// A push arriving while the app is **in front of somebody**.
  ///
  /// `onBackgroundMessage` does not fire in this case — the two are exclusive,
  /// and this is the half that has a screen to update.
  StreamSubscription<RemoteMessage>? _pushes;

  /// Tokens rotate — on a restore, an app-data clear, or at FCM's discretion —
  /// and a rotation nobody records is a watcher who stops being woken with
  /// nothing anywhere saying so.
  StreamSubscription<String>? _tokenRefreshes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationRouter.instance.tappedLink.addListener(_openWatcherList);
    // After the first frame, so a payload captured before runApp is honoured.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openWatcherList();
      _reconcileWatcherSide();
      _registerForPush();
    });
  }

  /// Makes this install reachable by push, and re-registers when the token
  /// rotates.
  ///
  /// **Fired, never awaited.** `getToken()` is a network round trip through Play
  /// Services; awaiting it here would put tier 2 in front of the first frame, on
  /// the screen whose whole job is to be there every morning. §3 prices a
  /// missing push at *latency, never correctness*, so a launch with no signal
  /// registers nothing and tries again next time.
  ///
  /// The refresh listener re-enters the same method rather than saving the token
  /// the stream handed it. One registration path is worth one extra local call:
  /// two would be two chances to write a token document that does not match the
  /// one FCM will deliver to.
  void _registerForPush() {
    final services = ref.read(appServicesProvider);
    unawaited(services.registerForPush());
    _tokenRefreshes ??= services.push.tokenRefreshes.listen(
      (_) => unawaited(ref.read(appServicesProvider).registerForPush()),
    );
    _pushes ??= FirebaseMessaging.onMessage.listen(
      (_) => unawaited(_onForegroundPush()),
    );
  }

  /// Reconciles both sides because something changed somewhere (§3).
  ///
  /// **Nothing is read out of the message**, exactly as in the background
  /// handler: a push is a nudge carrying no authority, and the strongest way to
  /// say so is not to look at it.
  ///
  /// ## Why this does not reuse [IAmOkApp.repairOnResume]
  ///
  /// That predicate exists to stop the shell reconciling when the watcher list
  /// is showing, because on a **resume** the list has its own lifecycle observer
  /// that will do it. A push is not a lifecycle event: nothing else fires, so
  /// standing back here would mean a nudge that changed the very row on screen
  /// updated nothing at all.
  ///
  /// So both branches reconcile, and they differ only in `watcherListShowing` —
  /// which is `WatcherScreen.isShowing` and nothing else. When the list is up
  /// the reader is looking at the answer, so the delivery is `redundant` and no
  /// notification is posted; when it is not, the shell's own path posts.
  Future<void> _onForegroundPush() async {
    try {
      final services = ref.read(appServicesProvider);
      // Same ordering as launch and resume: links are the input every other
      // decision derives from, and Phase 6's away nudge changes one.
      await services.syncLinks();
      if (!mounted) return;
      if (WatcherScreen.isShowing) {
        // `userInitiated: false` on this side too, and for the mirror-image
        // reason. The list is on screen, so the delivery is `redundant`: nothing
        // is posted and the day is recorded as seen, on the argument that the
        // reader can see the row change. Nothing re-reads a changed widget, so a
        // TalkBack reader sees nothing, hears nothing, and no notification is
        // ever coming. The flag is what lets the screen announce it.
        await ref.read(watcherStateProvider.notifier).refresh(
              userInitiated: false,
            );
      } else {
        _reconcileWatcherSide();
      }
      if (!mounted) return;
      // `userInitiated: false` — nobody asked for this. A reconcile she did not
      // trigger must not clear *"That did not save. Please tap again."* from
      // under her: nothing becomes false, but she loses the one instruction
      // telling her what to do, on the screen this app exists for.
      await ref.read(watchedStateProvider.notifier).refresh(userInitiated: false);
    } on Object {
      // Swallowed for the same reason `_reconcileWatcherSide` swallows: this
      // runs behind whatever screen the user actually opened, and must never be
      // able to replace it with an error about a message they did not send.
    }
  }

  /// Carries out [IAmOkApp.repairOnResume]'s answer, and decides nothing itself.
  ///
  /// The reasoning — including why the guard must never be wrong in the
  /// direction of defaulting to `true` — is on the predicate, where it can be
  /// tested. `WatcherScreen.isShowing` is read here rather than tracked, because
  /// the screen owns that fact; see its docstring for what duplicating it cost.
  ///
  /// ## The device facts are re-cached first, and unconditionally
  ///
  /// **Ahead of the guard**, because the guard answers *which reconcile runs*,
  /// not *whether the device's zone and clock format are stale*. Both change
  /// while the app is backgrounded, and both are read from `LocalStore` by an
  /// isolate that cannot ask the platform itself (ADR-0002).
  ///
  /// **On the shell rather than on `WatchedStateNotifier`, which is where the
  /// resume caching used to live.** That only worked because `TapScreen` is
  /// home and stays mounted; `main.dart` below says Phase 5 routes on role, and
  /// a watcher-only user would then never mount it — so both facts would
  /// silently revert to launch-only, which is precisely the defect the testing
  /// round removed for `uses24HourClock` at this gate. ADR-0002 decision 2 says
  /// *the UI* caches on every resume, which is a statement about the isolate and
  /// not about one side's provider.
  ///
  /// **What this does and does not order.** Within `_onResumed` the sequence is
  /// real — it awaits `cacheDeviceFacts()` and `syncLinks()` before reconciling
  /// anything, so the shell's own pass reads fresh values.
  ///
  /// It does **not** order the *screens*. The line below is
  /// `unawaited(_onResumed())`, which returns at the first `await`, and the
  /// binding then dispatches this same lifecycle event to `TapScreen`'s and
  /// `WatcherScreen`'s observers, both of which refresh immediately — against
  /// the previous session's device facts and links. An earlier version of this
  /// docstring claimed registration order fixed that; it does not, because
  /// registration order decides who is *called* first, not who *finishes* first.
  ///
  /// Bounded, and recorded as owed in the Phase 4 summary rather than fixed at a
  /// gate: ADR-0002 already accepts a stale zone for a boundary period, §10 step
  /// 2 covers a link revoked while backgrounded because the read is refused
  /// anyway, and the shell's pass corrects both behind the screens.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_onResumed());
  }

  Future<void> _onResumed() async {
    final services = ref.read(appServicesProvider);
    await services.cacheDeviceFacts();
    // Same ordering as launch, and for the same reason: a link revoked while
    // this app was backgrounded has to be gone before the reconcile below
    // decides what to arm.
    await services.syncLinks();
    if (!mounted) return;
    if (!IAmOkApp.repairOnResume(
      state: AppLifecycleState.resumed,
      watcherListShowing: WatcherScreen.isShowing,
    )) {
      return;
    }
    _reconcileWatcherSide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationRouter.instance.tappedLink.removeListener(_openWatcherList);
    unawaited(_pushes?.cancel());
    unawaited(_tokenRefreshes?.cancel());
    super.dispose();
  }

  /// Reconciles the **watcher** side on app open, whatever screen is showing.
  ///
  /// §3 says `reconcile()` is called on app open. On the watched side that was
  /// true because the Tap screen is home and its provider reconciles when it
  /// builds. On the watcher side it was **not**: `watcherStateProvider` only
  /// builds when the watcher list is shown, so nothing reconciled until someone
  /// navigated there.
  ///
  /// **Measured on the POCO F3.** After a force-stop — an ordinary action on
  /// HyperOS — every alarm is cancelled and nothing tells the app. Opening it
  /// restored the 18 watched reminders and **none** of the 12 watcher warnings,
  /// because home is the Tap screen. So the one repair path the design relies on
  /// did not repair the half that matters: a watcher who opens the app was still
  /// deaf, and nothing on any screen said so.
  ///
  /// That is worse than the Phase 3 brief assumed. Its argument was that a
  /// watcher never opens the app; this was the case where they *do* and it still
  /// does not help. It also matters permanently rather than only until Phase 5
  /// routes on role — someone who is both watched and watcher lands on the Tap
  /// screen by design (`screens.md`), so their watcher alarms would never be
  /// re-armed by opening the app at all.
  ///
  /// **Deliberately NOT through `watcherStateProvider`.** That provider is the
  /// watcher list's state and reconciles as though the list were on screen,
  /// which decides `NotificationDelivery.redundant` — *the reader is looking at
  /// the screen that already shows this* — and `redundant` consumes the day
  /// without posting anything.
  ///
  /// Nothing is showing it here. Home is the Tap screen, so a warning decided on
  /// this path must actually be **posted**, or it is recorded as standing and
  /// never reaches anyone. That is what happened on the POCO F3 before this
  /// call was split out: `warningsShownFor` held `warnOnline` for the day with
  /// zero notifications sent.
  ///
  /// Errors are swallowed for the same reason `AppServices.cacheDeviceFacts`
  /// swallows its
  /// own: this is a repair running behind whatever screen the user actually
  /// opened, and it must never be able to replace it with an error.
  void _reconcileWatcherSide() {
    final services = ref.read(appServicesProvider);
    unawaited(
      services
          .watcherReconcile(watcherListShowing: false)
          .reconcile(selfUid: services.selfUid)
          .catchError(
            // Discarded — nothing renders this. It exists only to satisfy
            // `catchError`'s return type on a repair running behind whatever
            // screen the user actually opened.
            (Object _, StackTrace _) => WatcherState(
              people: const [],
              today: DayKey(1970, 1, 1),
              watcherZone: TimeZones.utc,
              warningDelivery: NotificationDelivery.unavailable,
              uses24Hour: true,
            ),
          ),
    );
  }


  /// Opens the watcher list, which is where every notification this app posts to
  /// a *watcher* is explained.
  ///
  /// The routing is deliberately not per-notification-kind. All three — warning,
  /// correction, lost access — are about one watched person, and the list row is
  /// what carries the current truth about them. Sending a correction somewhere
  /// different from the warning it replaced would be its own small confusion.
  ///
  /// **The payload is checked against this user's own links before it opens
  /// anything.** `tappedLink` is an untrusted hint — whatever string arrived on
  /// a notification — and this pushed a screen for any non-null value. The
  /// screen itself validates before highlighting a row, so a stranger's link id
  /// could not surface another person's data; what it *could* do is open the
  /// watcher list on a phone that watches nobody, from a notification the app
  /// never posted. Small today, and exactly the check that must already exist
  /// before Phase 5 makes link ids meaningful and keys Firestore reads on them.
  void _openWatcherList() {
    final tapped = NotificationRouter.instance.tappedLink.value;
    if (tapped == null) return;
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    unawaited(_openIfWatched(tapped, navigator));
  }

  Future<void> _openIfWatched(String linkId, NavigatorState navigator) async {
    // Through `AppServices`, not `store` — §5's arrows are Presentation →
    // Application → Data, and this is a widget.
    //
    // The resolved `Link` rather than a bool, so the untrusted payload string
    // stops here: from this line on the app holds an object it looked up
    // itself. Nothing downstream needs the id yet — the list matches on its own
    // state — but the shape is what stops Phase 4 keying a Firestore read on
    // the string. See [AppServices.resolveWatchedLink].
    final link = await ref.read(appServicesProvider).resolveWatchedLink(linkId);
    if (link == null) {
      // Not this user's business. Consumed so a rebuild does not retry it —
      // and deliberately NOT navigated anywhere, because there is nothing to
      // show and no screen that could explain it honestly.
      NotificationRouter.instance.consume();
      return;
    }
    if (!mounted) return;
    _pushWatcherList(navigator);
  }

  void _pushWatcherList(NavigatorState navigator) {
    // **Never twice.** A second notification tap while the list is already up
    // would otherwise stack a second `WatcherScreen`: two mounted lifecycle
    // observers, two reconciles per resume, and a Back that returns to an
    // identical screen. `_openIfWatched` captures its link id before awaiting,
    // so the list consuming the tap does not prevent this.
    if (WatcherScreen.isShowing) return;
    // **Pushed on top of whatever home is, still.** With Phase 5 routing on
    // role, home may already *be* the watcher list — for a watcher who is not
    // also watched — and the guard above is what stops this stacking a second
    // copy of it. Where home is the Tap screen, Back returns there, which is
    // where the reader came from.
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const WatcherScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    title: 'I Am Ok',
    debugShowCheckedModeBanner: false,
    // In `AppTheme` rather than inline, so the widget tests pump the palette
    // the app actually ships — the contrast floor is a claim about these
    // colours, and it was being asserted against Flutter's defaults.
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    // **Phase 5's routing.** The decision itself is `HomeRoute.decide`, a pure
    // function asserted as a truth table; this only renders its answer. See
    // [Home].
    home: const Home(),
  );
}

/// Whichever main screen this user belongs on.
///
/// ## The decision is not here, deliberately
///
/// `main.dart` hard-coded `home: const TapScreen()` for three phases and its own
/// comment named what getting the successor wrong would cost: *"someone who is
/// both watched and watcher lands on the Tap screen by design, so their watcher
/// alarms would never be re-armed by opening the app at all"*. That is a
/// predicate over four booleans deciding whether a dead man's switch is
/// repaired, and `docs/testing/strategy.md` puts a predicate over booleans where
/// it can be asserted without a device — [HomeRoute.decide], with a truth table
/// in `test/domain/onboarding/home_route_test.dart`.
///
/// ## Nothing is rendered until the inputs are in
///
/// The answer depends on two disk reads. Guessing a main screen and correcting it
/// a frame later would **move the tap target**, and `guidelines.md` calls a
/// layout that reflows a bug — on the one control an 80-year-old presses from
/// muscle memory every morning. So a null route is a spinner, not a default.
class Home extends ConsumerWidget {
  const Home({super.key});

  /// The route, as a screen. **A pure function, and that is deliberate.**
  ///
  /// The same move [IAmOkApp.repairOnResume] makes, for the same reason: pumping
  /// the shell to find out which screen it picked needs a whole composition root
  /// — a real `LocalStore`, real notification channels — and every one of those
  /// is irrelevant to the question *did the router honour the route*. Worse, it
  /// puts the answer somewhere only an integration test can reach, on the wiring
  /// that decides whether a watcher can reach the screen that re-arms their
  /// warning alarms.
  ///
  /// So the widget holds no decision, only a lookup, and
  /// `test/presentation/onboarding_routing_test.dart` asserts this directly.
  static Widget screenFor(HomeRoute? route) => switch (route?.screen) {
        // **Null is a spinner, never a default screen.** The answer depends on
        // two disk reads; guessing a main screen and correcting it a frame later
        // would move the tap target, and `guidelines.md` calls a layout that
        // reflows a bug — on the one control an 80-year-old presses from muscle
        // memory every morning.
        null => Scaffold(
            body: Semantics(
              // A bare spinner says nothing at all to TalkBack — the same gap
              // `TapCopy.loadingLabel` was written for, and the same words,
              // because it is the same wait.
              label: TapCopy.loadingLabel,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
        HomeScreen.onboarding => const OnboardingScreen(),
        HomeScreen.tap => TapScreen(
            watcherListReachable: route!.watcherListReachable,
          ),
        HomeScreen.watcherList => const WatcherScreen(),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      screenFor(ref.watch(homeRouteProvider));
}
