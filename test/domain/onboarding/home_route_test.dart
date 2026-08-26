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

  group('links are evidence of a role, and outrank an empty store', () {
    // The reinstall case §1 designed Google Sign-In for: the uid survives, so
    // the links do, and LocalStore does not.
    test('a reinstalled watcher skips onboarding and reaches the list', () {
      expect(
        route(choices: none, watcherLinks: true),
        const HomeRoute(
          screen: HomeScreen.watcherList,
          watcherListReachable: false,
        ),
      );
    });

    test('a reinstalled watched person skips onboarding and lands on Tap', () {
      expect(
        route(choices: none, watchedLinks: true),
        const HomeRoute(screen: HomeScreen.tap, watcherListReachable: false),
      );
    });

    test('a reinstalled both-roles user gets Tap AND the list button', () {
      expect(
        route(choices: none, watchedLinks: true, watcherLinks: true),
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

    test('not completed but holding a link does not re-ask', () {
      expect(
        route(choices: none, watchedLinks: true).screen,
        isNot(HomeScreen.onboarding),
      );
    });

    // The mutation that matters in the other direction: dropping `completed`
    // from the guard would send a both-skipped user round the questions for
    // ever, and dropping the link half strands the reinstall above.
    test('not completed, no answers, no links is the ONLY re-ask', () {
      expect(route(choices: none).screen, HomeScreen.onboarding);
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
