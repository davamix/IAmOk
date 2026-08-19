@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/main.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:i_am_ok/presentation/watcher_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/zones.dart';

/// **The two facts the app shell decides with, tested where they are decided.**
///
/// ## What this deliberately does not do
///
/// It does not pump `IAmOkApp`. That was tried, and it hangs: `WidgetTester`
/// runs in a fake-async zone, `LocalStore` is real `sqflite` doing real I/O off
/// that zone, and the reconcile the shell kicks off never completes — the tests
/// time out rather than failing, which is worse than not having them.
/// `tester.runAsync` would let the I/O through but takes the frame scheduler
/// with it, and the Tap screen's indefinite progress indicator means
/// `pumpAndSettle` can never be used either.
///
/// So what is asserted here is everything the shell *decides with*, plus the
/// decision itself now that it has been lifted out of the widget:
///
/// * **`IAmOkApp.repairOnResume`**, the resume guard's truth table. It was three
///   lines inside `didChangeAppLifecycleState`, which put a two-input boolean
///   decision somewhere only hardware could reach — invert it and a force-stopped
///   watcher never re-arms an alarm again, with every test green.
/// * **`WatcherScreen.isShowing`**, which chooses between the shell's reconcile
///   and the list's own. The two disagree about `NotificationDelivery`, and one
///   of those answers consumes a day while showing nobody anything.
/// * **`AppServices.resolveWatchedLink`**, which is what stops an untrusted
///   notification payload opening a screen — and which returns the resolved
///   `Link` rather than a bool, so the payload string stops at that boundary
///   instead of being carried onward into a Phase 4 document path.
///
/// ## What remains genuinely device-only, and where it is recorded
///
/// After the hoist, the untested remainder is the wiring: that
/// `didChangeAppLifecycleState` is registered at all, and that it calls
/// `_reconcileWatcherSide` with the answer. There is no branch left in it.
///
/// One other consumer of `WatcherScreen.isShowing` is also device-only:
/// `_pushWatcherList`'s *"never twice"* guard, which is what actually prevents a
/// stacked screen in production. Reaching it means pumping `IAmOkApp`, which
/// hangs for the reason above. What the counter tests below establish is that its
/// **input** is right through a real push and pop; the guard reading that input
/// is one line with no other state.
///
/// This docstring previously said that remainder "stays covered by the device
/// matrix" — and it was on no row of it. The Phase 3 checklist's nearest entry is
/// *"Opening the app repairs both sides after a force-stop"*, which is a **launch**
/// via the post-frame callback; the resume path postdates the 2026-08-17 run
/// entirely. The row now exists, unchecked, under Phase 3's *still owed* list, so
/// the gap is a gap rather than a claim.
class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

class _NoopAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
  }) async =>
      true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();

  late LocalStore store;
  late AppServices services;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    await store.setDeviceTimezone('Europe/Madrid');
    final notifications = _FakeNotifications();
    services = AppServices(
      store: store,
      clock: FixedClock(at(madrid, 2026, 8, 17, 10)),
      notifications: notifications,
      alarms: _NoopAlarms(),
      permissions: PermissionService(notifications),
      clockService: const ClockService(),
      selfUid: 'ana',
    );
  });

  tearDown(() => store.close());

  Future<void> seedLink(String watchedUid, String name) => store.upsertLink(Link(
        watchedUid: watchedUid,
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: name,
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-08-01'),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      ));

  group('a notification payload is resolved, never trusted', () {
    test('a link this user watches resolves to the link itself', () async {
      // **The `Link`, not a bool.** A bool leaves the caller holding the
      // untrusted string, which invites the Phase 4 shape this exists to
      // prevent: membership proven against a local cache, then the raw payload
      // dereferenced into a document path anyway.
      await seedLink('mum', 'Mum');

      final link = await services.resolveWatchedLink('mum_ana');
      expect(link, isNotNull);
      expect(link!.id, 'mum_ana');
      expect(link.watchedName, 'Mum');
    });

    test('a link belonging to someone else does not', () async {
      // The whole point. `tappedLink` is whatever string arrived on a
      // notification, and the app pushed a screen for any non-null value.
      // `MainActivity` is exported, as every LAUNCHER activity must be, so a
      // co-installed app can hand this string in through a crafted intent.
      await seedLink('mum', 'Mum');
      expect(await services.resolveWatchedLink('mum_bob'), isNull);
    });

    test('a link that does not exist does not', () async {
      await seedLink('mum', 'Mum');
      expect(await services.resolveWatchedLink('stranger_ana'), isNull);
    });

    test('nothing resolves when this user watches nobody', () async {
      expect(await services.resolveWatchedLink('mum_ana'), isNull);
    });

    test('a REVOKED link still resolves — the row is the explanation',
        () async {
      // The security review proposed filtering on `isAccepted` here. That is
      // right for a future read path and wrong for this one, which decides
      // whether to open a screen: a notification posted before revocation can
      // still be in the tray, and the watcher list has a revoked row that
      // exists precisely to explain it. Filtering would make that tap do
      // nothing — no screen, no explanation, on the one surface that has one.
      //
      // The status is on the returned value, so a caller that needs an accepted
      // link can see it. That is the argument for returning the Link.
      await store.upsertLink(Link(
        watchedUid: 'mum',
        watcherUid: 'ana',
        status: LinkStatus.revoked,
        watchedName: 'Mum',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-08-01'),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      ));

      final link = await services.resolveWatchedLink('mum_ana');
      expect(link, isNotNull);
      expect(link!.isAccepted, isFalse,
          reason: 'resolved, and the caller can see it is not accepted');
    });
  });

  group('the watcher list owns whether it is showing', () {
    /// Pumps a tree, and **guarantees the counter is unwound even if the test
    /// fails.**
    ///
    /// `WatcherScreen._showing` is process-global. It was unwound by a line at
    /// the end of each test body instead, which a failure above simply skips —
    /// leaking a mounted count into every later test in the process, including
    /// the ones asserting `isFalse`. One real assertion failure would have
    /// cascaded into several unrelated ones and hidden its own cause.
    Future<void> pumpTree(WidgetTester tester, Widget child) {
      addTearDown(() async {
        if (WatcherScreen.isShowing) await tester.pumpWidget(const SizedBox());
      });
      return tester.pumpWidget(
        ProviderScope(
          overrides: [appServicesProvider.overrideWithValue(services)],
          child: child,
        ),
      );
    }

    /// The list alone, in a scope that can build it. Its own reconcile never
    /// completes here — real I/O, fake-async zone — so it sits on the loading
    /// state, which is all this needs: the counter moves in `initState`.
    Future<void> pumpList(WidgetTester tester) =>
        pumpTree(tester, const MaterialApp(home: WatcherScreen()));

    testWidgets('false when it is not on screen', (tester) async {
      expect(WatcherScreen.isShowing, isFalse);
    });

    testWidgets('true while it is', (tester) async {
      await pumpList(tester);
      expect(WatcherScreen.isShowing, isTrue);
      // Unwound by `pumpTree`'s tear-down, which a failure above cannot skip.
    });

    testWidgets('and false again once it is gone', (tester) async {
      await pumpList(tester);
      // Explicit here, because *this* test is about the dispose itself.
      await tester.pumpWidget(const SizedBox());

      expect(WatcherScreen.isShowing, isFalse,
          reason: 'a counter that never returns to zero would silence the '
              'shell\'s resume repair for the rest of the process — and that '
              'repair is what ADR-0007 names as the only recovery from a '
              'force-stop');
    });

    testWidgets('two instances do not clear it when one pops', (tester) async {
      // The defect the counter replaced. `main.dart` tracked this around its
      // own `push`, so a second notification tap stacked a second screen and
      // the first `.then` to fire cleared the flag while one was still up.
      //
      // **A real push and a real pop.** This test used to swap the whole widget
      // tree instead, so the two instances never coexisted in a settled frame —
      // it discriminated a naive bool only by accident of Flutter's
      // deactivate-then-unmount ordering, while its comment claimed to model a
      // stacked screen. The production shape is two mounted at once under
      // `MaterialPageRoute`s, the top one popped, the bottom still showing.
      final navigator = GlobalKey<NavigatorState>();
      await pumpTree(
        tester,
        MaterialApp(navigatorKey: navigator, home: const WatcherScreen()),
      );
      expect(WatcherScreen.isShowing, isTrue);

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const WatcherScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(WatcherScreen.isShowing, isTrue,
          reason: 'two are mounted now');

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(WatcherScreen.isShowing, isTrue,
          reason: 'the FIRST one is still up — this is the assertion the old '
              'bool failed, and the one that decides whether the shell runs a '
              'second reconcile alongside a list that is still on screen');

      await tester.pumpWidget(const SizedBox());
      expect(WatcherScreen.isShowing, isFalse);
    });
  });

  group('a resume repairs the watcher side unless the list is up', () {
    // **The truth table, out of the widget.** These four lines lived inside
    // `didChangeAppLifecycleState`, where the only way to exercise them was a
    // device — so inverting the guard left a force-stopped watcher permanently
    // deaf with the whole suite green and no device row that would catch it.
    // `strategy.md`: if a test needs a device to answer a question about logic,
    // the logic is in the wrong layer.

    test('a resume with the list closed repairs — the case that matters',
        () {
      // ADR-0007 names the app-open reconcile as the ONLY recovery from a
      // force-stop, and a background-and-return is a resume rather than a
      // launch. This is the true cell; every defect here is it turning false.
      expect(
        IAmOkApp.repairOnResume(
          state: AppLifecycleState.resumed,
          watcherListShowing: false,
        ),
        isTrue,
      );
    });

    test('a resume with the list showing defers to the list', () {
      // The list has its own observer and passes `watcherListShowing: true`.
      // Running alongside it would contradict that in the one parameter that can
      // lose a warning silently.
      expect(
        IAmOkApp.repairOnResume(
          state: AppLifecycleState.resumed,
          watcherListShowing: true,
        ),
        isFalse,
      );
    });

    test('no other lifecycle state repairs', () {
      for (final state in AppLifecycleState.values) {
        if (state == AppLifecycleState.resumed) continue;
        expect(
          IAmOkApp.repairOnResume(state: state, watcherListShowing: false),
          isFalse,
          reason: '$state is not a resume',
        );
        expect(
          IAmOkApp.repairOnResume(state: state, watcherListShowing: true),
          isFalse,
          reason: '$state is not a resume',
        );
      }
    });
  });
}
