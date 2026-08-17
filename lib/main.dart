import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/providers.dart';
import 'data/local_store.dart';
import 'domain/domain.dart';
import 'platform/alarm_scheduler.dart';
import 'platform/clock.dart';
import 'platform/clock_service.dart';
import 'platform/notification_router.dart';
import 'platform/notification_service.dart';
import 'platform/permission_service.dart';
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

class _IAmOkAppState extends ConsumerState<IAmOkApp> {
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
    NotificationRouter.instance.tappedLink.addListener(_openWatcherList);
    // After the first frame, so a payload captured before runApp is honoured.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openWatcherList();
      _reconcileBothSides();
    });
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
  /// Reading the provider is enough: that triggers its build, which is the
  /// reconcile. The result is not needed here — whoever shows the list will read
  /// it — and ADR-0006's lease makes the overlap with a screen doing the same
  /// thing safe.
  void _reconcileBothSides() => ref.read(watcherStateProvider);

  @override
  void dispose() {
    NotificationRouter.instance.tappedLink.removeListener(_openWatcherList);
    super.dispose();
  }

  /// Opens the watcher list, which is where every notification this app posts to
  /// a *watcher* is explained.
  ///
  /// The routing is deliberately not per-notification-kind. All three — warning,
  /// correction, lost access — are about one watched person, and the list row is
  /// what carries the current truth about them. Sending a correction somewhere
  /// different from the warning it replaced would be its own small confusion.
  void _openWatcherList() {
    if (NotificationRouter.instance.tappedLink.value == null) return;
    final navigator = _navigator.currentState;
    if (navigator == null) return;
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
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00658F)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00658F),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        // PLAN.md routes on the two onboarding selections in Phase 5. Until
        // then the watched side is the whole app, which is what Phase 2 is for.
        home: const TapScreen(),
      );
}
