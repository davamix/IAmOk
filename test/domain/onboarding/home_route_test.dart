import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// Where the app opens, asserted as a truth table rather than observed on a
/// device.
///
/// `docs/testing/strategy.md`: *if a test needs a device to answer a question
/// about logic, the logic is in the wrong layer.* Routing on role is a predicate
/// over four booleans, and one of the four — whether a link already exists —
/// decides whether a reinstalled watcher can reach the screen that repairs their
/// warning alarms at all.
void main() {
  const none = OnboardingChoices.none();
  const watchedOnly = OnboardingChoices(
    wantsToBeWatched: true,
    wantsToWatch: false,
    completed: true,
  );
  const watcherOnly = OnboardingChoices(
    wantsToBeWatched: false,
    wantsToWatch: true,
    completed: true,
  );
  const both = OnboardingChoices(
    wantsToBeWatched: true,
    wantsToWatch: true,
    completed: true,
  );
  const skippedBoth = OnboardingChoices(
    wantsToBeWatched: false,
    wantsToWatch: false,
    completed: true,
  );

  HomeRoute route({
    bool signedIn = true,
    OnboardingChoices choices = none,
    bool watchedLinks = false,
    bool watcherLinks = false,
  }) =>
      HomeRoute.decide(
        signedIn: signedIn,
        choices: choices,
        hasAcceptedWatchedLinks: watchedLinks,
        hasAcceptedWatcherLinks: watcherLinks,
      );

  group('signed out', () {
    test('goes to onboarding whatever else is true', () {
      expect(route(signedIn: false).screen, HomeScreen.onboarding);
      expect(
        route(signedIn: false, choices: both, watchedLinks: true).screen,
        HomeScreen.onboarding,
        reason: 'every link is keyed by a uid there is not one of',
      );
    });
  });

  group('a cold install', () {
    test('with nothing recorded and no links, asks the two questions', () {
      expect(route().screen, HomeScreen.onboarding);
    });

    test('never offers the watcher list from onboarding', () {
      expect(route().watcherListReachable, isFalse);
    });
  });

  group('the two selections decide the main screen', () {
    test('watched only lands on the Tap screen, list not reachable', () {
      expect(
        route(choices: watchedOnly),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: false),
      );
    });

    test('watcher only lands on the list', () {
      expect(
        route(choices: watcherOnly),
        const HomeRoute(
          screen: HomeScreen.watcherList,
          watcherListReachable: false,
        ),
      );
    });

    test('both lands on Tap with the list reachable — PLAN.md priority', () {
      expect(
        route(choices: both),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: true),
      );
    });

    test('both skipped lands on Tap, which is the screen that says so', () {
      expect(
        route(choices: skippedBoth),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: false),
        reason: 'asking the same questions every launch nags the one user '
            'this app must not nag',
      );
    });
  });

  /// **The flow ends on `completed`, and on nothing else.**
  ///
  /// These three states — an answer recorded with the flow not finished — had no
  /// case at all, and all three routed to a main screen. Two ways in, both live:
  /// answering question 1 used to eject the reader mid-flow (measured on two
  /// phones, the summary was never seen), and killing the app between question 1
  /// and *Finish* leaves exactly this on disk, because `_persist` writes each
  /// answer immediately.
  ///
  /// The second needs no provider and no invalidation, so it is the version that
  /// survives any future refactor of the caching.
  group('an interrupted flow is still in the flow', () {
    const answeredFirstOnly = OnboardingChoices(
      wantsToBeWatched: true,
      wantsToWatch: false,
      completed: false,
    );
    const answeredSecondOnly = OnboardingChoices(
      wantsToBeWatched: false,
      wantsToWatch: true,
      completed: false,
    );
    const answeredBothUnfinished = OnboardingChoices(
      wantsToBeWatched: true,
      wantsToWatch: true,
      completed: false,
    );

    test('question 1 answered, not finished', () {
      expect(route(choices: answeredFirstOnly).screen, HomeScreen.onboarding,
          reason: 'ejecting here is what skipped the summary on two phones');
    });

    test('question 2 answered, not finished', () {
      expect(route(choices: answeredSecondOnly).screen, HomeScreen.onboarding);
    });

    test('both answered, not finished — the summary is the next screen', () {
      expect(
        route(choices: answeredBothUnfinished).screen,
        HomeScreen.onboarding,
      );
    });

    // The device case: a pairing completed during the flow, then the app died
    // before Finish. A link now exists AND the flow is unfinished.
    test('paired during the flow, but not finished, still shows the summary',
        () {
      expect(
        route(choices: answeredFirstOnly, watchedLinks: true).screen,
        HomeScreen.onboarding,
      );
    });

    test('the ONLY thing that ends the flow is completed', () {
      for (final watched in [true, false]) {
        for (final watcher in [true, false]) {
          for (final choices in [
            answeredFirstOnly,
            answeredSecondOnly,
            answeredBothUnfinished,
            none,
          ]) {
            expect(
              route(
                choices: choices,
                watchedLinks: watched,
                watcherLinks: watcher,
              ).screen,
              HomeScreen.onboarding,
              reason: 'unfinished flow, links $watched/$watcher, $choices',
            );
          }
        }
      }
    });
  });

  /// **Links route, but they no longer END the flow.**
  ///
  /// A reinstall keeps the uid and therefore the links, and loses the store — so
  /// those users must not be asked two questions they answered by action. That
  /// is now settled by `AppServices.settleOnboardingIfPaired`, which sets
  /// `completed` before the router is asked, rather than by this function
  /// treating a link as an ending. Conflating the two is what made answering a
  /// question end the flow.
  ///
  /// So these assert the half that is still this function's job: once the flow
  /// is over, an accepted link is evidence of a role the stored answers may not
  /// know about.
  group('links are evidence of a role', () {
    // Post-settle, which is the state the router actually sees for a reinstall.
    const settled = OnboardingChoices(
      wantsToBeWatched: false,
      wantsToWatch: false,
      completed: true,
    );

    test('a reinstalled watcher reaches the list', () {
      expect(
        route(choices: settled, watcherLinks: true),
        const HomeRoute(
          screen: HomeScreen.watcherList,
          watcherListReachable: false,
        ),
      );
    });

    test('a reinstalled watched person lands on Tap', () {
      expect(
        route(choices: settled, watchedLinks: true),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: false),
      );
    });

    test('a reinstalled both-roles user gets Tap AND the list button', () {
      expect(
        route(choices: settled, watchedLinks: true, watcherLinks: true),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: true),
        reason: "main.dart's own warning: a both-roles user stranded on Tap "
            'never re-arms their watcher alarms by opening the app',
      );
    });
  });

  group('selections and links are unioned, never overridden', () {
    test('a selection with no link yet still routes — an unredeemed invite', () {
      expect(route(choices: watchedOnly).screen, HomeScreen.tap);
    });

    test('a watched person who later watches someone gains the button', () {
      expect(
        route(choices: watchedOnly, watcherLinks: true).watcherListReachable,
        isTrue,
        reason: 'the link is a role the stored answer does not know about',
      );
    });

    test('a watcher who is later watched moves to Tap, keeping the button', () {
      expect(
        route(choices: watcherOnly, watchedLinks: true),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: true),
      );
    });

    test('someone who skipped both but has links is routed by the links', () {
      expect(
        route(choices: skippedBoth, watcherLinks: true).screen,
        HomeScreen.watcherList,
      );
    });
  });

  group('the guard that keeps onboarding from re-running', () {
    test('completed with no answers and no links does not re-ask', () {
      expect(route(choices: skippedBoth).screen, isNot(HomeScreen.onboarding));
    });

    // The mutation that used to survive: replacing the answers with the links in
    // the exit condition. It cannot survive now, because the links are not in
    // the exit condition at all.
    test('a link alone does NOT end the flow — settling does', () {
      expect(
        route(choices: none, watchedLinks: true).screen,
        HomeScreen.onboarding,
        reason: 'AppServices.settleOnboardingIfPaired is what ends it, by '
            'setting completed before the router is asked',
      );
    });

    test('and once settled, the same user is routed by their links', () {
      expect(
        route(
          choices: const OnboardingChoices(
            wantsToBeWatched: false,
            wantsToWatch: false,
            completed: true,
          ),
          watchedLinks: true,
        ).screen,
        HomeScreen.tap,
      );
    });
  });

  group('watcherListReachable is never true off the Tap screen', () {
    test('holds across every input combination', () {
      for (final signedIn in [true, false]) {
        for (final choices in [none, watchedOnly, watcherOnly, both,
          skippedBoth]) {
          for (final watched in [true, false]) {
            for (final watcher in [true, false]) {
              final result = route(
                signedIn: signedIn,
                choices: choices,
                watchedLinks: watched,
                watcherLinks: watcher,
              );
              if (result.screen != HomeScreen.tap) {
                expect(
                  result.watcherListReachable,
                  isFalse,
                  reason: 'a list cannot be reachable from a screen that is '
                      'not showing — $result',
                );
              }
            }
          }
        }
      }
    });
  });

  group('OnboardingChoices', () {
    test('none is the cold-install state', () {
      expect(none.wantsToBeWatched, isFalse);
      expect(none.wantsToWatch, isFalse);
      expect(none.completed, isFalse);
    });

    test('copyWith changes one answer and keeps the others', () {
      expect(
        none.copyWith(wantsToWatch: true),
        const OnboardingChoices(
          wantsToBeWatched: false,
          wantsToWatch: true,
          completed: false,
        ),
      );
    });

    test('value equality, so a rebuild with the same answers is not a change',
        () {
      expect(watchedOnly, const OnboardingChoices(
        wantsToBeWatched: true,
        wantsToWatch: false,
        completed: true,
      ));
      expect(watchedOnly.hashCode, const OnboardingChoices(
        wantsToBeWatched: true,
        wantsToWatch: false,
        completed: true,
      ).hashCode);
      expect(watchedOnly, isNot(watcherOnly));
    });
  });
}
