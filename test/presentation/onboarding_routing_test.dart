import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:i_am_ok/presentation/pairing_screens.dart';
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
///
/// **A source lint stands in for it** — see *the one line no behaviour test
/// reaches*, below. It is not a proof and does not pretend to be one: it cannot
/// tell you the app works, only that the specific regression which would be
/// invisible has not happened. This repo has two precedents for exactly that
/// trade (`domain_purity_test.dart`'s guards, and the `automaticHostMapping`
/// counter added this phase).
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
      // `openLabel`, not `title`. The title is approved as a heading; read out
      // as a control's name it announces a place rather than an action.
      expect(button.tooltip, WatcherCopy.openLabel);
      expect(button.tooltip, isNotEmpty);

      // **And it reaches the semantics tree**, which asserting the widget
      // property alone does not show. Measured: a `tooltip` populates
      // `SemanticsProperties.tooltip` — Android's `setTooltipText` — and leaves
      // `label` empty, so `find.bySemanticsLabel` finds nothing for it. That is
      // a weaker guarantee than a `contentDescription` and the docstring on
      // `WatcherCopy.openLabel` now says so rather than claiming otherwise.
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(
        find.byKey(WatcherListButton.buttonKey),
      );
      expect(node.tooltip, WatcherCopy.openLabel);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
          reason: 'a labelled node with no tap action is not a control');
      handle.dispose();
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

  /// **The cross-role dead end, closed.**
  ///
  /// Until Phase 5 closed, this button opened `ShareCodeScreen` and nothing
  /// else, while the only route to `EnterCodeScreen` was the watcher list —
  /// which is reachable from the Tap screen only by somebody who is *already* a
  /// watcher. So anybody who answered "Skip for now" to onboarding's second
  /// question was shut out of that role permanently: no error, no wrong screen,
  /// nothing anywhere to press.
  ///
  /// It was invisible to 1 161 tests for the same reason the unreachable
  /// summary screen was — the defect is *a screen nobody reaches*, and no
  /// assertion about a screen's contents can notice one that never opens.
  group('Add someone reaches both halves of pairing', () {
    test('the answer chooses the screen', () {
      expect(
        AddSomeoneButton.pairingScreenFor(true),
        isA<ShareCodeScreen>(),
        reason: 'someone to look after me: this phone produces a code',
      );
      expect(
        AddSomeoneButton.pairingScreenFor(false),
        isA<EnterCodeScreen>(),
        reason: 'someone I look after: this phone consumes one — the route '
            'that did not exist',
      );
    });

    testWidgets('the chooser offers exactly the two, and says so in words',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AddSomeoneButton.chooseRole(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(OnboardingCopy.addSomeoneToWatchMe), findsOneWidget);
      expect(find.text(OnboardingCopy.addSomeoneIWatch), findsOneWidget);
      expect(find.byKey(AddSomeoneButton.watchedChoiceKey), findsOneWidget);
      expect(find.byKey(AddSomeoneButton.watcherChoiceKey), findsOneWidget);
    });

    testWidgets('each option answers with its own half', (tester) async {
      Future<bool?> open(Key key) async {
        bool? answer;
        var opened = false;
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  opened = true;
                  answer = await AddSomeoneButton.chooseRole(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
        expect(opened, isTrue);
        return answer;
      }

      expect(await open(AddSomeoneButton.watchedChoiceKey), isTrue);
      expect(await open(AddSomeoneButton.watcherChoiceKey), isFalse);
    });

    // **The largest system font scale, on a small screen.** `guidelines.md`'s
    // floor, and the reason it bites here specifically: a default
    // `showModalBottomSheet` caps its child at 9/16 of the screen height, and a
    // `Column` that overflows is **clipped in release** — no stripe, no error,
    // nothing to see.
    //
    // What that costs is specific. The row at the bottom is *"Someone I look
    // after"*, so the option that gets cut is the one this sheet exists to
    // provide, for exactly the users most likely to be running a large font.
    // The cross-role dead end would come back for the population this app is
    // for.
    //
    // Measured before and after the fix, at scale 2.0 on 320x480:
    // without `SingleChildScrollView` the sheet raises a `FlutterError`
    // (RenderFlex overflowed) and the second row's bottom lands at 802 against
    // a 480 viewport; with it, no exception and the row scrolls into reach.
    //
    // **The scale is set on the platform dispatcher, not in a `MediaQuery`
    // inside `home`.** The first version of this test wrapped the button's
    // subtree — and a modal sheet is built by a *route*, above that widget, so
    // the scale never reached it. Every measurement was identical at every
    // scale and the test passed against the unfixed code: a test manufacturing
    // its own green.
    testWidgets('both options survive the largest font on a small screen',
        (tester) async {
      tester.view.physicalSize =
          const Size(320, 480) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AddSomeoneButton.chooseRole(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'an overflow here is an option clipped away in release');

      // Present, reachable, and still above the touch floor. `findsOneWidget`
      // alone would pass for a row rendered outside the viewport.
      for (final key in [
        AddSomeoneButton.watchedChoiceKey,
        AddSomeoneButton.watcherChoiceKey,
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
        await tester.ensureVisible(find.byKey(key));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(key)).height,
            greaterThanOrEqualTo(48),
            reason: '$key is below the touch floor at this scale');
      }

      // And the one that would have been cut still answers.
      await tester.tap(find.byKey(AddSomeoneButton.watcherChoiceKey));
      await tester.pumpAndSettle();
      expect(find.byKey(AddSomeoneButton.watcherChoiceKey), findsNothing,
          reason: 'the sheet should have closed on the choice');
    });

    testWidgets('dismissing it chooses nothing, and nothing is said',
        (tester) async {
      bool? answer;
      var returned = false;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                answer = await AddSomeoneButton.chooseRole(context);
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A tap outside the sheet — a change of mind, not a failure.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(answer, isNull,
          reason: 'null must be distinguishable from either choice, or a '
              'dismissal opens a screen the reader did not ask for');
    });

    // The label of the icon button that opens the watcher list. It is an icon,
    // so this string is a screen-reader user's whole identification of the only
    // route to the other half of the app — and a title read out as a control's
    // name announces a place rather than an action.
    test('the watcher-list control is labelled with an action', () {
      expect(WatcherCopy.openLabel, isNot(WatcherCopy.title));
      expect(WatcherCopy.openLabel.toLowerCase(), startsWith('see'));
    });
  });

  /// **The one line no behaviour test in this suite reaches.**
  ///
  /// `Home.build` is `screenFor(ref.watch(homeRouteProvider))`. Everything above
  /// asserts `screenFor` and the argument it is handed; nothing asserts that the
  /// widget reads *that* provider. It could watch a different one, or pass
  /// `null` unconditionally, and every test in this file would still pass.
  ///
  /// A lint, not a proof. It cannot tell you the app works — a device run does
  /// that, and did. What it stops is the specific regression that would be
  /// invisible to the whole suite.
  group('the routing wire, as source', () {
    /// Comments stripped, and CRLF normalised, before matching.
    ///
    /// **Both were missing and both are holes.** Without stripping, commenting
    /// the line out and returning a constant leaves the lint green — and
    /// commenting a line out is the most natural way to make exactly that
    /// mutation. Without normalising, the lint fails on a fresh clone on
    /// Windows, where `core.autocrlf=true` disagrees with what the repo stores.
    ///
    /// This is what the two precedents the group cites already do
    /// (`push_handler_test.dart`, `domain_purity_test.dart`); this lint cited
    /// them and did neither.
    String sourceOf(String path) => File(path)
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          final comment = RegExp(r'(?<!:)//').firstMatch(line);
          return comment == null ? line : line.substring(0, comment.start);
        })
        .join('\n');

    test('Home.build renders the route provider and nothing else', () {
      expect(
        sourceOf('lib/main.dart'),
        contains('screenFor(ref.watch(homeRouteProvider))'),
        reason: 'if this moved, update the lint — do not delete it: the line '
            'it guards is the only one in the routing wire that no assertion '
            'in this file can reach',
      );
    });

    /// **The two lines that spend `refusalForCode`, which no test can reach.**
    ///
    /// `InviteService.refusalForCode` and `inviteRefusalForCode` are pure and
    /// table-tested — but their only callers sit inside
    /// `catch (FirebaseFunctionsException)`, which no unit test can enter
    /// without faking `FirebaseFunctions`, and none does. Revert either call to
    /// `couldNotReach` and the whole suite stays green while every server-side
    /// fault tells a reader whose phone demonstrably reached the backend to go
    /// and check their internet connection — the defect the Phase 5 gate
    /// closed, restored invisibly.
    ///
    /// A lint, because no cheap behaviour test exists here. The mutation
    /// harness aims one line deeper, at the function body, which the table
    /// tests already cover.
    test('both callables map their exception through the tested function', () {
      final code = sourceOf('lib/data/invite_service.dart');
      expect(code, contains('PairingRefused(refusalForCode(e.code))'));
      expect(code, contains('InviteRefused(inviteRefusalForCode(e.code))'));
      expect(
        code,
        isNot(contains("e.code == 'unauthenticated'")),
        reason: 'the inline mapping is what was wrong; it belongs in the pure '
            'function that has a table test',
      );
    });
  });
}
