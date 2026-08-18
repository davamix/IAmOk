import 'package:flutter/foundation.dart';

import '../data/check_in_reader.dart';
import '../data/local_store.dart';
import '../domain/domain.dart';
import '../platform/clock.dart';
import '../platform/notification_service.dart';
import '../platform/warning_alarm_scheduler.dart';
import 'watcher_reconcile_service.dart';

/// The watcher's alarm, as the OS wakes it.
///
/// ## This is a bare isolate, and that is the whole constraint
///
/// `android_alarm_manager_plus` starts a **new Dart isolate** with a fresh
/// engine. It shares no memory with the UI (§4): no Riverpod container, no
/// in-memory cache, no open database handle, no plugin registrations beyond what
/// it makes itself. Everything it needs is read from `LocalStore`.
///
/// So this function bootstraps the minimum, calls `reconcile()`, and exits —
/// the shape §4 prescribes for both background entry points. It is listed in
/// `domain_purity_test.dart`'s `bareIsolateSafe`, which asserts that neither it
/// nor anything it reaches imports Flutter, Riverpod or `flutter_timezone`.
///
/// **`flutter_timezone` is the one that would look fine and fail here**
/// (ADR-0002 decision 2). The watcher's own zone is read from `LocalStore`, and
/// the watched person's comes off the link — both already on disk, which is
/// exactly why they were put there.
///
/// ## Why it reconciles everything rather than the alarm it was armed for
///
/// The alarm id encodes a link and a day, and this deliberately ignores both.
/// §3: nothing is transmitted as a command — a fire is a *nudge to reconcile*,
/// carrying no authority. Acting only on the alarm's own link would mean one
/// dropped alarm leaves one watched person unreconciled with nothing to notice,
/// which is the silent failure this design spends everything avoiding.
///
/// ## Failure policy
///
/// Anything thrown here is invisible: there is no screen, no user, and no log
/// anyone will read. So the isolate must not die holding the reconcile lease —
/// the service releases it in a `finally` — and a failure to reconcile must
/// leave the *next* fire able to try again. Nothing is cached in memory that a
/// crash could corrupt, because nothing is cached in memory at all.
@pragma('vm:entry-point')
Future<void> warningAlarmCallback(int id) async {
  final store = await LocalStore.open();
  try {
    // Each isolate creates its own plugin instance and its own channels.
    // `onTap` is deliberately not wired: a background isolate that posts a
    // notification does not route taps — the UI isolate does, on next launch.
    final notifications = await NotificationService.initialize();

    // The clock offset comes off disk so this isolate agrees with the UI about
    // what day it is. A forced date in the harness that the alarm did not share
    // would test nothing.
    //
    // **Gated on `kDebugMode`, exactly as `main()` gates the same read.** That
    // gate exists so "zero offset in every release build" is enforced by the
    // code rather than resting on the only writer being compiled out — anything
    // that could put a row under `debug_clock_offset_ms` would otherwise shift
    // this app's entire notion of now. Phase 3 originally left the read ungated
    // on the one path that decides whether to tell a family something is wrong,
    // which is the worst possible place to have missed it.
    final clock = SystemClock(
      offset: kDebugMode ? await store.clockOffset() : Duration.zero,
    );

    final service = WatcherReconcileService(
      store: store,
      clock: clock,
      reader: SimulatedCheckInReader(store),
      notifications: notifications,
      alarms: AndroidWarningAlarmScheduler(
        warningAlarmCallback,
        notifications.canScheduleExact,
      ),
      // The app is by definition NOT in the foreground: this isolate only runs
      // because the OS woke it. So the only question is whether the platform
      // will post at all — and `canPost` is checked per channel, because a user
      // who switched off just the warnings channel leaves the app-level flag
      // true and would have every warning consumed as delivered.
      delivery: () async => NotificationDelivery.from(
        canPost: await notifications.canPost(
          channel: NotificationService.warningsChannel,
        ),
        appInForeground: false,
      ),
      lockOwner: 'alarm',
    );

    await service.reconcile(selfUid: LocalStore.defaultSelfUid);
  } finally {
    // Closed explicitly. The isolate is about to be torn down, but leaving a
    // connection open across that is how a later isolate meets a locked
    // database it cannot explain.
    await store.close();
  }
}
