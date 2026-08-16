import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/providers.dart';
import 'data/local_store.dart';
import 'domain/domain.dart';
import 'platform/alarm_scheduler.dart';
import 'platform/clock.dart';
import 'platform/clock_service.dart';
import 'platform/notification_service.dart';
import 'platform/permission_service.dart';
import 'presentation/tap_screen.dart';

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

  final store = await LocalStore.open();
  final notifications = await NotificationService.initialize();
  final permissions = PermissionService(notifications);

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
    // Phase 2 has no backend and no sign-in. Phase 4 replaces this with the
    // Firebase uid, which survives reinstall and phone replacement so links
    // never break (§1).
    selfUid: 'local-watched-user',
  );

  runApp(
    ProviderScope(
      overrides: [appServicesProvider.overrideWithValue(services)],
      child: const IAmOkApp(),
    ),
  );
}

class IAmOkApp extends StatelessWidget {
  const IAmOkApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
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
