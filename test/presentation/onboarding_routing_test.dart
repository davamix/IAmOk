import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/copy/onboarding_copy.dart';
import 'package:i_am_ok/copy/tap_copy.dart';
import 'package:i_am_ok/copy/watcher_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/main.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
import 'package:i_am_ok/presentation/onboarding_screen.dart';
import 'package:i_am_ok/presentation/tap_screen.dart';
import 'package:i_am_ok/presentation/watcher_screen.dart';

/// **That the app actually uses `HomeRoute`'s answer.**
///
/// `HomeRoute.decide` is asserted as a truth table one layer down, and that
/// covers the decision. It says nothing about whether anything *renders* it —
/// and the two app-level test files in this suite both deliberately avoid
/// pumping the shell (`widget_test.dart` pumps `TapBody`, and
/// `app_lifecycle_test.dart` says in as many words that pumping `IAmOkApp`
/// hangs). So the wire between the decision and the screen had no coverage at
/// all, which is exactly the shape of gap this project keeps finding: the claim
/// was true and nothing checked the thing it described.
///
/// ## One link in that wire is still uncovered, and this says so rather than
/// implying otherwise
///
/// What follows covers `Home.screenFor` — the mapping — and the parameter it
/// passes. It does **not** cover `Home.build`, which is
/// `screenFor(ref.watch(homeRouteProvider))`: that one line could read the wrong
/// provider, or pass `null` unconditionally, and every assertion here would
/// still pass.
///
/// Closing it was attempted at the Phase 5 review and **abandoned deliberately**:
/// pumping `Home` inside a real `ProviderContainer` hangs with no output, which
/// is the same behaviour `app_lifecycle_test.dart` records for pumping
/// `IAmOkApp` and gives as its reason for not doing so. Rather than leave a
/// hanging test or a green one that proves nothing, the gap is named here and in
/// `docs/phases/phase-5-summary.md`. It is one line, and it is the line a device
/// run exercises every time.
void main() {
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');

  /// The mapping, asserted directly.
  ///
  /// `Home.screenFor` is a pure function precisely so this needs no composition
  /// root — see its docstring. Pumping the shell would need a real `LocalStore`
  /// and real notification channels to answer a question about which of three
  /// widgets was chosen.
  group('Home renders the route it is given', () {
    test('onboarding', () {
      expect(
        Home.screenFor(const HomeRoute(
          screen: HomeScreen.onboarding,
          watcherListReachable: false,
        )),
        isA<OnboardingScreen>(),
      );
    });

    test('the Tap screen', () {
      expect(
        Home.screenFor(const HomeRoute(
          screen: HomeScreen.tap,
          watcherListReachable: false,
        )),
        isA<TapScreen>(),
      );
    });

    test('the watcher list', () {
      expect(
        Home.screenFor(const HomeRoute(
          screen: HomeScreen.watcherList,
          watcherListReachable: false,
        )),
        isA<WatcherScreen>(),
      );
    });

    // **A guess would move the tap target.** `guidelines.md` calls a layout that
    // reflows a bug, and the reflow here would be the whole screen changing
    // under an 80-year-old's thumb a frame after it appeared.
    test('an undecided route is a spinner, never a default screen', () {
      final screen = Home.screenFor(null);
      expect(screen, isNot(isA<TapScreen>()));
      expect(screen, isNot(isA<WatcherScreen>()));
      expect(screen, isNot(isA<OnboardingScreen>()));
    });

    testWidgets('and the spinner is labelled — a bare one says nothing to '
        'TalkBack', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light, home: Home.screenFor(null)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel(TapCopy.loadingLabel), findsOneWidget);
    });

    // The parameter is what PLAN.md's "top action button" rides on, and passing
    // it is the half a truth table one layer down cannot see.
    test('watcherListReachable reaches TapScreen', () {
      final screen = Home.screenFor(const HomeRoute(
        screen: HomeScreen.tap,
        watcherListReachable: true,
      )) as TapScreen;
      expect(screen.watcherListReachable, isTrue);
    });

    test('and is false when the route says so', () {
      final screen = Home.screenFor(const HomeRoute(
        screen: HomeScreen.tap,
        watcherListReachable: false,
      )) as TapScreen;
      expect(screen.watcherListReachable, isFalse);
    });
  });

  group('the Tap screen top action button', () {
    WatchedState watched({List<String> watchers = const []}) => WatchedState(
          today: DayKey(2026, 8, 26),
          zone: madrid,
          audience: WatchedAudience(watchers),
          todayCheckIn: null,
          away: null,
          notificationsEnabled: true,
          armed: 21,
          tapFailed: false,
          uses24Hour: true,
        );

    Future<void> pumpBody(
      WidgetTester tester, {
      required bool reachable,
      List<String> watchers = const [],
    }) async {
      tester.view.physicalSize =
          const Size(400, 800) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: TapBody(
                state: watched(watchers: watchers),
                watcherListReachable: reachable,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('is absent for somebody who is only watched', (tester) async {
      await pumpBody(tester, reachable: false);
      expect(find.byKey(WatcherListButton.buttonKey), findsNothing);
    });

    testWidgets('is present for somebody who is both', (tester) async {
      await pumpBody(tester, reachable: true);
      expect(find.byKey(WatcherListButton.buttonKey), findsOneWidget);
    });

    testWidgets('is labelled, so a screen reader can identify it',
        (tester) async {
      await pumpBody(tester, reachable: true);
      final button = tester.widget<IconButton>(
        find.byKey(WatcherListButton.buttonKey),
      );
      expect(button.tooltip, WatcherCopy.title);
      expect(button.tooltip, isNotEmpty);
    });

    testWidgets('does not displace the tap target', (tester) async {
      await pumpBody(tester, reachable: false);
      final without = tester.getCenter(find.byKey(TapTarget.targetKey));
      await pumpBody(tester, reachable: true);
      final with_ = tester.getCenter(find.byKey(TapTarget.targetKey));
      expect(
        with_,
        without,
        reason: 'muscle memory is the feature — the target may not move '
            'because this user also watches somebody',
      );
    });
  });

  group('the route back into pairing', () {
    testWidgets('the Tap screen offers Add someone', (tester) async {
      tester.view.physicalSize =
          const Size(400, 900) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: TapBody(
                state: WatchedState(
                  today: DayKey(2026, 8, 26),
                  zone: madrid,
                  audience: const WatchedAudience([]),
                  todayCheckIn: null,
                  away: null,
                  notificationsEnabled: true,
                  armed: 21,
                  tapFailed: false,
                  uses24Hour: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(AddSomeoneButton.buttonKey), findsOneWidget);
      expect(find.text(OnboardingCopy.addSomeone), findsOneWidget);
    });

    // The copy change this button forced. `notificationsOff` records the rule:
    // *"ask a family member" is the dead-end wording and is only honest once
    // there is nothing left to press.* There is now something to press.
    test('the empty audience line no longer sends the reader away', () {
      expect(TapCopy.nobodyYet.toLowerCase(), isNot(contains('ask a family')));
      expect(
        TapCopy.nobodyYet,
        "No one is set up to know you're OK.",
      );
    });

    test('and neither does the watcher list\'s empty line', () {
      expect(WatcherCopy.nobody.toLowerCase(), isNot(contains('ask a family')));
    });

    test('both empty lines still say what is true, in both their states', () {
      // The Phase 2 review's finding, still held: "yet" asserts *not started*,
      // which is false after the last link is revoked.
      expect(TapCopy.nobodyYet.toLowerCase(), isNot(contains('yet')));
      expect(WatcherCopy.nobody.toLowerCase(), isNot(contains('yet')));
    });
  });
}
