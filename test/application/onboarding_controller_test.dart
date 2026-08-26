@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/onboarding_controller.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/auth_repository.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// The flow's answers, and what they mean afterwards.
///
/// **The property that matters is that a skip is an answer.** If it were merely
/// an absence, somebody who wants neither role is asked the same two questions
/// on every single launch — the app nagging the one user `guidelines.md` says it
/// must never nag — and `HomeRoute.decide` would keep routing them back here for
/// ever.
class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());

  @override
  Future<bool> canPost({AndroidNotificationChannel? channel}) async => true;
}

/// Nothing here arms anything — these tests are about the two answers, not
/// about the platform.
class _NoAlarms implements AlarmScheduler {
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

class _MadridClockService extends ClockService {
  const _MadridClockService();

  @override
  Future<String?> deviceTimezone() async => 'Europe/Madrid';

  @override
  bool uses24HourClock() => true;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');

  late LocalStore store;
  late ProviderContainer container;

  ProviderContainer containerFor(String uid) => ProviderContainer(
        overrides: [
          launchServicesProvider.overrideWithValue(
            AppServices(
              store: store,
              clock: FixedClock(at(madrid, 2026, 8, 26, 9)),
              notifications: _FakeNotifications(),
              alarms: _NoAlarms(),
              permissions: PermissionService(_FakeNotifications()),
              clockService: const _MadridClockService(),
              selfUid: uid,
              auth: AuthRepository(store),
            ),
          ),
        ],
      );

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    container = containerFor('mum');
    addTearDown(container.dispose);
    addTearDown(store.close);
  });

  OnboardingController controller() =>
      container.read(onboardingControllerProvider.notifier);

  group('where the flow starts', () {
    test('signed out, it starts at sign-in', () async {
      final signedOut = containerFor(LocalStore.signedOutUid);
      addTearDown(signedOut.dispose);
      await signedOut.read(onboardingChoicesProvider.future);
      expect(
        signedOut.read(onboardingControllerProvider).step,
        OnboardingStep.signIn,
      );
    });

    test('signed in, it starts at the first question', () async {
      await container.read(onboardingChoicesProvider.future);
      expect(
        container.read(onboardingControllerProvider).step,
        OnboardingStep.watchedQuestion,
      );
    });
  });

  group('a skip is an answer', () {
    test('skipping the first question records false and moves on', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: false);

      final state = container.read(onboardingControllerProvider);
      expect(state.step, OnboardingStep.watcherQuestion);
      expect(state.choices.wantsToBeWatched, isFalse);
      expect(await store.onboardingChoices(),
          const OnboardingChoices(
            wantsToBeWatched: false,
            wantsToWatch: false,
            completed: false,
          ));
    });

    test('skipping both, then finishing, marks the flow COMPLETE', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: false);
      await controller().answeredWatcher(wants: false);
      await controller().finish();

      final stored = await store.onboardingChoices();
      expect(stored.completed, isTrue,
          reason: 'without this the two questions are asked every launch');
      expect(stored.wantsToBeWatched, isFalse);
      expect(stored.wantsToWatch, isFalse);
    });

    // The whole point of `completed` being a third flag rather than derived.
    test('and that user is then routed AWAY from onboarding', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: false);
      await controller().answeredWatcher(wants: false);
      await controller().finish();

      final route = HomeRoute.decide(
        signedIn: true,
        choices: await store.onboardingChoices(),
        hasAcceptedWatchedLinks: false,
        hasAcceptedWatcherLinks: false,
      );
      expect(route.screen, isNot(HomeScreen.onboarding));
    });
  });

  /// **The summary screen has to be reachable.**
  ///
  /// Found on two phones rather than in this suite: answering a question
  /// affirmatively used to re-invalidate the provider `homeRouteProvider`
  /// watches, so the route recomputed with a role, found one, and left
  /// onboarding — and screen 3, a deliverable of this phase, was skipped on both
  /// endpoints of the pairing run.
  ///
  /// These assert the route *while the flow is running*, which is the thing the
  /// per-step tests above cannot see: each of them checks a step, and the defect
  /// was that the whole flow was cut short from outside.
  group('the router leaves onboarding only when the flow says so', () {
    HomeScreen? routeNow() => container.read(homeRouteProvider)?.screen;

    test('a cold install starts on onboarding', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      expect(routeNow(), HomeScreen.onboarding);
    });

    test('answering the FIRST question keeps the reader in the flow', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      await controller().answeredWatched(wants: true);
      expect(
        routeNow(),
        HomeScreen.onboarding,
        reason: 'this is what skipped the summary on both phones',
      );
    });

    test('answering the SECOND question keeps them in the flow too', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      await controller().answeredWatched(wants: true);
      await controller().answeredWatcher(wants: true);
      expect(container.read(onboardingControllerProvider).step,
          OnboardingStep.summary);
      expect(routeNow(), HomeScreen.onboarding,
          reason: 'the summary IS the onboarding route — leaving it here is '
              'the screen never being shown');
    });

    test('a pairing recorded mid-flow does not eject them either', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      await controller().recordPairing(asWatched: true);
      expect(routeNow(), HomeScreen.onboarding);
    });

    test('finishing is what releases them, and to the right screen', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      await controller().answeredWatched(wants: true);
      await controller().answeredWatcher(wants: false);
      await controller().finish();
      // `finish` invalidates the two providers the router reads; a
      // `FutureProvider` keeps its previous value while it reloads, so the
      // route flips on the rebuild rather than on the call. Awaiting them is
      // what the widget tree does by rebuilding.
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      expect(routeNow(), HomeScreen.tap);
    });

    test('and a watcher-only flow is released to the list', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      await controller().answeredWatched(wants: false);
      await controller().answeredWatcher(wants: true);
      await controller().finish();
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      expect(routeNow(), HomeScreen.watcherList);
    });

    test('finishing picks up a link made during the flow', () async {
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      // A pairing that happened on the code screen, after the router last read
      // the links.
      await store.upsertLink(Link(
        watchedUid: 'granddad',
        watcherUid: 'mum',
        status: LinkStatus.accepted,
        watchedName: 'Granddad',
        watcherName: 'Mum',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: DayKey(2026, 8, 26),
        createdAt: DateTime.utc(2026, 8, 26),
      ));
      await controller().answeredWatched(wants: false);
      await controller().answeredWatcher(wants: false);
      await controller().finish();
      await container.read(onboardingChoicesProvider.future);
      await container.read(linkRolesProvider.future);
      expect(routeNow(), HomeScreen.watcherList,
          reason: 'the link is the evidence; the skipped answers are not');
    });
  });

  group('answering', () {
    test('the first question makes this user watched', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      expect((await store.onboardingChoices()).wantsToBeWatched, isTrue);
    });

    test('the second makes them a watcher', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatcher(wants: true);
      expect((await store.onboardingChoices()).wantsToWatch, isTrue);
      expect(container.read(onboardingControllerProvider).step,
          OnboardingStep.summary);
    });

    test('both, and the router sends them to Tap with the list reachable',
        () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      await controller().answeredWatcher(wants: true);
      await controller().finish();

      expect(
        HomeRoute.decide(
          signedIn: true,
          choices: await store.onboardingChoices(),
          hasAcceptedWatchedLinks: false,
          hasAcceptedWatcherLinks: false,
        ),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: true),
      );
    });
  });

  group('going back does not lose an answer', () {
    test('from the second question to the first', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      controller().back();

      final state = container.read(onboardingControllerProvider);
      expect(state.step, OnboardingStep.watchedQuestion);
      expect(state.choices.wantsToBeWatched, isTrue);
    });

    test('back from the first question stays put — there is nothing behind it',
        () async {
      await container.read(onboardingChoicesProvider.future);
      controller().back();
      expect(container.read(onboardingControllerProvider).step,
          OnboardingStep.watchedQuestion);
    });
  });

  group('recordPairing', () {
    test('a pairing made from a main screen updates the stored answer',
        () async {
      await container.read(onboardingChoicesProvider.future);
      // Somebody who skipped the question and later changed their mind.
      await controller().answeredWatched(wants: false);
      await controller().recordPairing(asWatched: true);

      expect((await store.onboardingChoices()).wantsToBeWatched, isTrue);
    });

    test('recording one role does not clear the other', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      await controller().recordPairing(asWatcher: true);

      final stored = await store.onboardingChoices();
      expect(stored.wantsToBeWatched, isTrue);
      expect(stored.wantsToWatch, isTrue);
    });

    /// **The guard, pinned in the direction that would break it.**
    ///
    /// A mutation pass found this unpinned: `asWatched == true ? true : null`
    /// could be written `asWatched` and the whole suite stayed green, because no
    /// caller passes `false` today and `copyWith` treats null as *keep*. The two
    /// differ only here — and the difference is a pairing screen able to
    /// **erase** an answer rather than record one.
    ///
    /// This method is called `recordPairing`, and it is monotone by design:
    /// evidence arriving never un-answers a question the user answered.
    test('and false never un-answers a question', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      await controller().answeredWatcher(wants: true);

      await controller().recordPairing(asWatched: false, asWatcher: false);

      final stored = await store.onboardingChoices();
      expect(stored.wantsToBeWatched, isTrue,
          reason: 'recordPairing records; it does not retract');
      expect(stored.wantsToWatch, isTrue);
    });

    test('a no-op call writes nothing new', () async {
      await container.read(onboardingChoicesProvider.future);
      await controller().answeredWatched(wants: true);
      final before = await store.onboardingChoices();
      await controller().recordPairing(asWatched: true);
      expect(await store.onboardingChoices(), before);
    });
  });

  group('linkRolesProvider reads the store the right way round', () {
    // `LocalStore.linksWatching` and `linksWatchedBy` read the OPPOSITE way to
    // their names, and swapping them would route every watcher to the Tap screen
    // and every watched person to a list of nobody.
    Link link({required String watched, required String watcher}) => Link(
          watchedUid: watched,
          watcherUid: watcher,
          status: LinkStatus.accepted,
          watchedName: 'Mum',
          watcherName: 'Ana',
          watchedTimezone: 'Europe/Madrid',
          activeFrom: DayKey(2026, 8, 1),
          createdAt: DateTime.utc(2026, 8, 1),
        );

    test('somebody watching me makes me watched, not a watcher', () async {
      await store.upsertLink(link(watched: 'mum', watcher: 'ana'));
      final roles = await container.read(linkRolesProvider.future);
      expect(roles.watched, isTrue);
      expect(roles.watcher, isFalse);
    });

    test('me watching somebody makes me a watcher, not watched', () async {
      await store.upsertLink(link(watched: 'granddad', watcher: 'mum'));
      final roles = await container.read(linkRolesProvider.future);
      expect(roles.watcher, isTrue);
      expect(roles.watched, isFalse);
    });

    test('both directions at once', () async {
      await store.upsertLink(link(watched: 'mum', watcher: 'ana'));
      await store.upsertLink(link(watched: 'granddad', watcher: 'mum'));
      final roles = await container.read(linkRolesProvider.future);
      expect(roles.watched, isTrue);
      expect(roles.watcher, isTrue);
    });

    test('a REVOKED link is not a role', () async {
      await store.upsertLink(
        link(watched: 'mum', watcher: 'ana')
            .copyWith(status: LinkStatus.revoked),
      );
      final roles = await container.read(linkRolesProvider.future);
      expect(roles.watched, isFalse,
          reason: 'a revoked link is a role that ended, not a role');
    });

    test('signed out has no roles at all', () async {
      final signedOut = containerFor(LocalStore.signedOutUid);
      addTearDown(signedOut.dispose);
      await store.upsertLink(link(watched: 'mum', watcher: 'ana'));
      final roles = await signedOut.read(linkRolesProvider.future);
      expect(roles.watched, isFalse);
      expect(roles.watcher, isFalse);
    });
  });
}
