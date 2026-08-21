import 'package:flutter/foundation.dart';

import '../data/debug_backend_override.dart';
import '../data/firebase_bootstrap.dart';
import '../data/firestore_check_in_reader.dart';
import '../data/local_store.dart';
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
///
/// ## This isolate MUST NOT close the store — measured 2026-08-20
///
/// It used to, in a `finally`, and the reasoning was plausible and wrong:
/// *"leaving a connection open across that is how a later isolate meets a locked
/// database it cannot explain."* On Android there is **no second connection to
/// leave open**. `android_alarm_manager_plus` runs this isolate in the app's own
/// process, and `sqflite`'s Android plugin keeps a **static**
/// `_singleInstancesByPath`, so `LocalStore.open()` here is handed back the
/// **same `databaseId` the UI is holding**. Closing it closed the UI's store,
/// and every UI call then threw `DatabaseException(database_closed 1)` for the
/// life of the process.
///
/// `sqflite`'s own documentation says exactly this
/// (`sqflite_common/lib/sqlite_api.dart`):
///
/// > If `singleInstance` is true when using multiple isolates, make sure no
/// > background isolate closes the database, since that might close the database
/// > for all isolates.
///
/// So there is nothing to release. The instance is process-scoped and `sqflite`
/// owns its lifetime; `journal_mode=delete` means even an unclean process kill
/// leaves a rollback journal SQLite recovers on the next open. **Phase 4's FCM
/// isolate is a third engine in this same process and inherits this rule** — see
/// [LocalStore.open]. Guarded by `domain_purity_test.dart`.
///
/// **There is no `try`/`finally` here any more, and its absence is deliberate.**
/// The whole reason one existed was to close the store. With nothing to release,
/// a bare `try` would only catch and rethrow. A throw from `open()` — a corrupt
/// file, a schema downgrade, a disk with nothing left on it — propagates as it
/// always did, so Phase 8's crash reporting will see it, and the *next* fire
/// still gets a clean attempt because nothing is cached in memory at all.
@pragma('vm:entry-point')
Future<void> warningAlarmCallback(int id) async {
  // **This isolate reads Firestore**, so it brings Firebase up itself — §4: the
  // three isolates share no memory, and nothing the UI initialised is visible
  // here. One shared function rather than a second copy of the same three lines,
  // because the failure a divergent copy produces is not a crash: it is this
  // isolate quietly talking to production while the UI talks to the emulator.
  await FirebaseBootstrap.ensureInitialized();

  final store = await LocalStore.open();
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
    // **Composed here, not shared with the UI's copy.** §4: this isolate sees
    // nothing the UI built. The two roots agreeing is a property of both being
    // written the same way, which is why the pieces are small enough to read
    // side by side — and why the clock passed in is this isolate's, including
    // the harness offset it read off disk two lines up.
    reader: DebugBackendOverride(
      store: store,
      real: FirestoreCheckInReader(now: clock.now),
    ),
    notifications: notifications,
    alarms: AndroidWarningAlarmScheduler(
      warningAlarmCallback,
      notifications.canScheduleExact,
    ),
    // False by definition: this isolate exists only because the OS woke it,
    // so there is no screen showing anything to anyone.
    //
    // The rest of the derivation is shared with the UI root rather than
    // copied — see [NotificationService.watcherDelivery]. This copy is the one
    // nobody can watch running, and it drifted from its twin once already.
    delivery: () => notifications.watcherDelivery(appInForeground: false),
    lockOwner: 'alarm',
  );

  // **From disk, not from `FirebaseAuth.instance.currentUser`.** Both are
  // available in this isolate now that Firebase is up, and they fail
  // differently: a `currentUser` that has not finished being restored comes back
  // null, this reconcile finds zero links, does nothing, and reports success —
  // the silence §12 calls the one failure this app cannot detect in itself. A
  // stale row, by contrast, gets `permission-denied` on every read, which
  // ADR-0004 maps to refused and which posts a notice. Loud beats quiet here.
  // `LocalStore.selfUid` carries the full argument.
  //
  // Signed out is a real state and reconciles to nothing, which is correct:
  // no links, no alarms, nothing owed.
  final selfUid = await store.selfUid() ?? LocalStore.signedOutUid;

  await service.reconcile(selfUid: selfUid);
}
