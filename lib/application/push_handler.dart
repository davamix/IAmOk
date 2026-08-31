import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/away_repository.dart';
import '../data/debug_backend_override.dart';
import '../data/firebase_bootstrap.dart';
import '../data/firestore_check_in_reader.dart';
import '../data/local_store.dart';
import '../platform/alarm_scheduler.dart';
import '../platform/clock.dart';
import '../platform/notification_service.dart';
import '../platform/permission_service.dart';
import '../platform/warning_alarm_scheduler.dart';
import 'warning_alarm_handler.dart';
import 'watched_reconcile_service.dart';
import 'watcher_reconcile_service.dart';

/// A data-only push arriving while the app is closed — §4's **third** isolate.
///
/// ## Everything the alarm isolate's docstring says applies here
///
/// This is a bare isolate: a fresh engine, no Riverpod container, no in-memory
/// cache, no open database handle, nothing the UI built. Everything it needs is
/// read from `LocalStore`. It is listed in `domain_purity_test.dart`'s
/// `bareIsolateSafe` and in its `backgroundEntryPoints`, and the second of those
/// is the one that has already cost a day: **no background isolate may
/// `close()` the store.** On Android all three isolates run in the app's own
/// process and `sqflite` hands each of them the same native connection, so
/// closing it here would kill the UI's store for the life of the process. There
/// is nothing to release. See [LocalStore.open] and `warningAlarmCallback`.
///
/// ## It reads nothing out of the message, and that is the design
///
/// §3: **nothing is transmitted as a command.** A push is a nudge — *something
/// changed, reconcile now* — carrying no authority whatever, and the strongest
/// way to say so is for this function not to look at [message] at all. Deciding
/// anything from a payload would make FCM load-bearing, which §3 refuses: it
/// would mean a dropped message could change an answer rather than only delay
/// it, and a *forged* one could move `lastConfirmedDay` for a day nobody tapped.
///
/// `docs/testing/strategy.md` asks for exactly that case — *the push carries no
/// authority* — and it is asserted in `test/application/push_handler_test.dart`
/// against the reconcile, because there is nothing here to assert against.
///
/// ## Both sides reconcile, not the one this push is about
///
/// Phase 4's only push is `onCheckInCreated`, which goes to **watchers**. This
/// still runs the watched side too, for the same reason `warningAlarmCallback`
/// reconciles every link rather than the one its alarm was armed for: the nudge
/// carries no authority about what it concerns, so keying the work to a guess
/// about it means one dropped message leaves one side unreconciled with nothing
/// to notice. It is also what Phase 6 needs, where `onAwayChanged` fans out to
/// the watched person's own device and their reminders are what must change.
///
/// The watched side runs **second**. Both sides are independent — disjoint lease
/// scopes, disjoint alarm ids — but the watcher side is the reason the OS woke
/// this isolate, and a background engine has seconds to live. If only one of the
/// two completes, it should be the one that decides whether to tell a family
/// something.
///
/// ## Failure policy
///
/// Anything thrown here is invisible: no screen, no user, and no log anyone will
/// read. So the two sides are run separately rather than in one `try`, because a
/// watcher-side failure that skipped the watched side would be a second failure
/// caused by the first. Nothing is cached in memory that a crash could corrupt,
/// because nothing is cached in memory at all, and the *next* nudge — or the app
/// being opened, or the next alarm — gets a clean attempt.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  // **This isolate reads Firestore**, so it brings Firebase up itself — §4: the
  // three isolates share no memory and nothing the UI initialised is visible
  // here. One shared function rather than a third copy of the same three lines,
  // because the failure a divergent copy produces is not a crash: it is a
  // background isolate quietly talking to production while the UI talks to the
  // emulator.
  await FirebaseBootstrap.ensureInitialized();

  final store = await LocalStore.open();

  // Each isolate creates its own plugin instance and its own channels. `onTap`
  // is deliberately not wired: a background isolate that posts a notification
  // does not route taps — the UI isolate does, on next launch.
  final notifications = await NotificationService.initialize();

  // Off disk, so this isolate agrees with the UI and with the alarm isolate
  // about what day it is. Gated on `kDebugMode` exactly as `main()` and
  // `warningAlarmCallback` gate the same read, so "zero offset in every release
  // build" is enforced by the code rather than resting on the only writer being
  // compiled out.
  final clock = SystemClock(
    offset: kDebugMode ? await store.clockOffset() : Duration.zero,
  );

  // **From disk, not from `FirebaseAuth.instance.currentUser`.** Both are
  // available here now that Firebase is up, and they fail differently: a
  // `currentUser` still being restored comes back null, the reconcile finds zero
  // links, does nothing and reports success — the silence §12 calls the one
  // failure this app cannot detect in itself. A stale row instead gets
  // `permission-denied` on every read, which ADR-0004 maps to refused and which
  // posts a notice. Loud beats quiet here.
  final selfUid = await store.selfUid() ?? LocalStore.signedOutUid;

  await runBothSides(
    () => _reconcileWatcherSide(store, clock, notifications, selfUid),
    () => _reconcileWatchedSide(store, clock, notifications, selfUid),
  );
}

/// Runs [watcherSide], then [watchedSide] **even if the first threw**, and still
/// lets the throw out.
///
/// ## Why this is a function and not two lines in the entry point
///
/// It was two lines, and before that it was two bare `await`s with a docstring
/// claiming they were isolated from each other — which `await A; await B;` is
/// precisely not. The architecture review found that by reading, and no test
/// could have: `pushBackgroundHandler` brings up Firebase, opens the platform
/// store and initialises a notification plugin, so it cannot be run in the VM at
/// all, and a source lint that greps for two type names passes whether the order
/// is swapped, the `finally` reverted, or one call wrapped in `if (false)`.
///
/// `docs/testing/strategy.md`'s rule is that if a test needs a device to answer
/// a question about *logic*, the logic is in the wrong layer — and "does the
/// second thing still run when the first fails" is logic. Here it is a pure
/// function over two callbacks, asserted in microseconds.
///
/// ## Both halves matter, in opposite directions
///
/// **The second must run.** The throw surfaces on the first are real and sit
/// *outside* `WatcherReconcileService`'s per-link guard — `store.linksWatchedBy`,
/// `store.uses24HourClock`, `_watcherZone()`, and `delivery()`'s two plugin
/// round trips. A watcher-side failure that skipped the watched side would be a
/// second failure caused by the first, and it lands where Phase 6 needs it
/// least: `onAwayChanged` fans out to the watched person's own device, and their
/// reminders are the half that must change.
///
/// **The throw must still escape.** `warningAlarmCallback` deliberately has no
/// `try` so that a fault reaches Phase 8's crash reporting rather than being
/// swallowed into the silence this side cannot detect in itself. Catching here
/// would buy tidiness and cost the only report anyone will ever get.
Future<void> runBothSides(
  Future<void> Function() watcherSide,
  Future<void> Function() watchedSide,
) async {
  try {
    await watcherSide();
  } finally {
    await watchedSide();
  }
}

Future<void> _reconcileWatcherSide(
  LocalStore store,
  Clock clock,
  NotificationService notifications,
  String selfUid,
) async {
  final service = WatcherReconcileService(
    store: store,
    clock: clock,
    // **Composed here, not shared with the UI's copy.** §4: this isolate sees
    // nothing the UI built. The two roots agreeing is a property of both being
    // written the same way, which is why the pieces are small enough to read
    // side by side — and why the clock passed in is this isolate's.
    reader: DebugBackendOverride(
      store: store,
      real: FirestoreCheckInReader(now: clock.now),
    ),
    notifications: notifications,
    alarms: AndroidWarningAlarmScheduler(
      warningAlarmCallback,
      notifications.canScheduleExact,
    ),
    // False by definition: this isolate exists only because a push arrived while
    // the app was not in front of anybody. The derivation itself is shared with
    // the UI root rather than copied — see [NotificationService.watcherDelivery]
    // — because both wiring defects of Phase 3 lived in a copy of this
    // expression.
    delivery: () => notifications.watcherDelivery(appInForeground: false),
    lockOwner: 'fcm',
  );
  await service.reconcile(selfUid: selfUid);
}

Future<void> _reconcileWatchedSide(
  LocalStore store,
  Clock clock,
  NotificationService notifications,
  String selfUid,
) async {
  final service = WatchedReconcileService(
    store: store,
    clock: clock,
    alarms: NotificationAlarmScheduler(notifications),
    notificationsEnabled: PermissionService(notifications).notificationsEnabled,
    // **`checkIns` is deliberately not passed at all**, and its absence is not
    // a missing dependency. It is where a *tap* goes, and no tap happens on this
    // path — nobody is holding the phone. It defaults to null, `reconcile()`
    // never touches it, and passing a repository this side would never call
    // would be an invitation for a later change to call it. A check-in written
    // by a background isolate is a check-in nobody made.
    //
    // **`away` IS passed, and its absence was the defect this comment's
    // neighbour hid.** `onAwayChanged` fans out to the watched person's own
    // device precisely so her REMINDERS change, and without the repository
    // `_refreshedAway` skips the read and reconciles against the very cache the
    // nudge came to replace — so the Function nudged correctly and the handler
    // it woke could not act. A watcher marks her away from another phone, hers
    // stays in her pocket, and she is reminded at 12:00, 18:00 and 21:00
    // through the holiday. The cancellation direction is worse and is the
    // silent one: away cancelled remotely, her phone stays suppressed, and
    // nothing on it says why.
    //
    // Null when nobody is signed in, mirroring `AppServices` — there is no
    // `users/{uid}/shared/away` to read, and the cached period is still
    // honoured because expiry is arithmetic (§12).
    away: selfUid == LocalStore.signedOutUid ? null : AwayRepository(),
    selfUid: selfUid,
    lockOwner: 'fcm',
  );
  await service.reconcile(selfUid: selfUid);
}
