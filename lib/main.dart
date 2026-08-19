import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/providers.dart';
import 'application/watcher_reconcile_service.dart';
import 'data/local_store.dart';
import 'domain/domain.dart';
import 'platform/alarm_scheduler.dart';
import 'platform/clock.dart';
import 'platform/clock_service.dart';
import 'platform/notification_router.dart';
import 'platform/notification_service.dart';
import 'platform/permission_service.dart';
import 'presentation/app_theme.dart';
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

  final store = await LocalStore.open();

  // **The device's IANA zone, cached before anything reconciles.**
  //
  // `WatchedStateNotifier.build()` already awaited this before its own first
  // reconcile — the fix for a defect measured on the POCO F3, where a fresh
  // install armed 19 alarms at UTC wall times, an hour or two late each. But
  // `_reconcileWatcherSide` runs from a post-frame callback and awaits nothing, so
  // on the watcher side the same race was still open: `deviceTimezone()` is null
  // on a fresh install, `_watcherZone()` takes ADR-0002's documented UTC
  // fallback, and seven warning alarms are armed at 10:00 **UTC**.
  //
  // It self-heals on the first fire, which is precisely the fire that is two
  // hours late — on a dead man's switch, on day one. Doing it here removes the
  // ordering dependency from both call sites instead of repeating the fix.
  //
  // Swallowed, never fatal: a plugin hiccup must not stop the app starting, and
  // every reader below has a documented fallback.
  const clockService = ClockService();
  try {
    final zone = await clockService.deviceTimezone();
    if (zone != null) await store.setDeviceTimezone(zone);
    // The device's 12h/24h preference, cached beside the zone and for the same
    // reason: the alarm isolate has no way to ask. Awaited here rather than
    // written fire-and-forget from a widget, so the first reconcile cannot read
    // a default the device disagrees with.
    await store.setUses24HourClock(clockService.uses24HourClock());
  } on Object {
    // Deliberate; see above.
  }

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
    selfUid: LocalStore.defaultSelfUid,
  );

  runApp(
    ProviderScope(
      overrides: [appServicesProvider.overrideWithValue(services)],
      child: const IAmOkApp(),
    ),
  );
}

class IAmOkApp extends ConsumerStatefulWidget {
  const IAmOkApp({super.key});

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationRouter.instance.tappedLink.addListener(_openWatcherList);
    // After the first frame, so a payload captured before runApp is honoured.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openWatcherList();
      _reconcileWatcherSide();
    });
  }

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
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The list has its own observer and passes `watcherListShowing: true`, which
    // this must not race — see `WatcherScreen.isShowing` for why the screen owns
    // that fact rather than this file tracking it.
    if (WatcherScreen.isShowing) return;
    _reconcileWatcherSide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationRouter.instance.tappedLink.removeListener(_openWatcherList);
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
  /// Errors are swallowed for the same reason `_cacheDeviceZone` swallows its
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
    if (!await ref.read(appServicesProvider).watches(linkId)) {
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
    // Phase 5 routes on role; until then the watched screen is home and this is
    // pushed on top, so Back returns where the reader came from.
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
    // PLAN.md routes on the two onboarding selections in Phase 5. Until
    // then the watched side is the whole app, which is what Phase 2 is for.
    home: const TapScreen(),
  );
}
