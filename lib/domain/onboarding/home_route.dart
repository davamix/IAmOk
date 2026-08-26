/// Which main screen a user lands on, and whether the other one is reachable.
///
/// PLAN.md decides the routing and `ui-ux/screens.md` records it: onboarding
/// asks two questions about **other people**, and the role falls out of the
/// answers. Screen 1 — *"Who should know you're OK?"* — makes this user
/// **watched**, whose main screen is Tap + Away. Screen 2 — *"Who are you
/// looking after?"* — makes them a **watcher**, whose main screen is the list.
/// Both selected means Tap + Away with a top action button to the list, because
/// the person who taps daily should never have to navigate to reach their one
/// action.
///
/// **Role is never asked directly**, and that is the decision this file
/// implements rather than one it may re-open: *"are you the elderly one?"* is a
/// question nobody wants to answer.
enum HomeScreen {
  /// Nobody is signed in, or the two questions have not been asked yet.
  onboarding,

  /// Tap + Away — the watched person's one screen.
  tap,

  /// The watcher list.
  watcherList,
}

/// The two onboarding answers, as this device recorded them.
///
/// Held in `LocalStore`'s settings table and **not in Firestore**, deliberately.
/// §1 is explicit that *roles live on links* and a user is just a user, so a
/// `role` field on `users/{uid}` would be a second, weaker answer to a question
/// the link graph already answers — and one the security rules would then have
/// to validate. These two booleans are a record of what this person said on
/// this phone, which is a different and smaller claim.
///
/// They are cleared with the account on sign-out, for the same reason the
/// per-link cache is: they are answers *this user* gave.
class OnboardingChoices {
  const OnboardingChoices({
    required this.wantsToBeWatched,
    required this.wantsToWatch,
    required this.completed,
  });

  /// Nothing asked yet — the state of a cold install.
  const OnboardingChoices.none()
      : wantsToBeWatched = false,
        wantsToWatch = false,
        completed = false;

  /// Screen 1 was answered rather than skipped: somebody should know they
  /// are OK.
  final bool wantsToBeWatched;

  /// Screen 2 was answered rather than skipped: they are looking after
  /// somebody.
  final bool wantsToWatch;

  /// The flow ran to the summary screen. **Both questions skipped still
  /// completes it** — a skip is an answer, and re-asking on every launch would
  /// make the app nag the one user it must not nag.
  final bool completed;

  OnboardingChoices copyWith({
    bool? wantsToBeWatched,
    bool? wantsToWatch,
    bool? completed,
  }) =>
      OnboardingChoices(
        wantsToBeWatched: wantsToBeWatched ?? this.wantsToBeWatched,
        wantsToWatch: wantsToWatch ?? this.wantsToWatch,
        completed: completed ?? this.completed,
      );

  @override
  bool operator ==(Object other) =>
      other is OnboardingChoices &&
      other.wantsToBeWatched == wantsToBeWatched &&
      other.wantsToWatch == wantsToWatch &&
      other.completed == completed;

  @override
  int get hashCode => Object.hash(wantsToBeWatched, wantsToWatch, completed);

  @override
  String toString() => 'OnboardingChoices(watched: $wantsToBeWatched, '
      'watcher: $wantsToWatch, completed: $completed)';
}

/// Where the app opens, decided as a pure function over explicit inputs.
///
/// ## Why this is a decision and not three lines in `main.dart`
///
/// `main.dart` hard-coded `home: const TapScreen()` for three phases and reached
/// the watcher list **only** through a notification tap. Its own comment already
/// named the cost of getting the successor wrong: *"someone who is both watched
/// and watcher lands on the Tap screen by design, so their watcher alarms would
/// never be re-armed by opening the app at all"*. That is a predicate over a
/// handful of booleans deciding whether a dead man's switch is repaired, and
/// `docs/testing/strategy.md`'s rule is that a predicate over booleans is logic
/// and belongs where it can be asserted without a device.
///
/// ## Links outrank the stored answers, and that is the load-bearing part
///
/// §1 chose Google Sign-In precisely because **the uid survives a reinstall and
/// a phone replacement, so links never break**. A cold install therefore starts
/// with an empty `LocalStore` — no recorded answers — and a user who may already
/// be watching three people. Routing on the stored answers alone would put a
/// reinstalled watcher on the Tap screen, where the list is unreachable except
/// by a notification tap, which is the exact failure `main.dart` warns about
/// arriving through the fix for it.
///
/// So the two sources are **unioned, never overridden**: an accepted link is
/// evidence of a role, and a recorded answer is an intention that has not
/// produced a link yet. Someone who creates an invite nobody has redeemed is
/// watched by nobody and still belongs on the Tap screen — that is what
/// `TapCopy.nobodyYet` exists to say.
///
/// **Only accepted links count.** A revoked one is not a role: it is a role that
/// ended, and `WatchedAudience` records at length why this app does not render
/// *"someone stopped watching you"* in any form.
class HomeRoute {
  const HomeRoute({required this.screen, required this.watcherListReachable});

  /// The screen the app opens on.
  final HomeScreen screen;

  /// Whether the watcher list is reachable from the Tap screen — the top action
  /// button PLAN.md specifies for somebody who is both watched and a watcher.
  ///
  /// False whenever [screen] is not [HomeScreen.tap]: the list cannot be
  /// *reachable from* a screen the app is not showing, and a true here would be
  /// a second, contradictory answer for the same user.
  final bool watcherListReachable;

  /// Decides where this user's app opens.
  ///
  /// [hasAcceptedWatchedLinks] — an accepted link on which this user is the
  /// **watched** party, i.e. somebody is watching them.
  /// [hasAcceptedWatcherLinks] — an accepted link on which this user is the
  /// **watcher**, i.e. they are watching somebody.
  static HomeRoute decide({
    required bool signedIn,
    required OnboardingChoices choices,
    required bool hasAcceptedWatchedLinks,
    required bool hasAcceptedWatcherLinks,
  }) {
    // Nothing below this line is answerable without an identity. Every link is
    // keyed by uid, `createInvite` needs one to name `watchedUid`, and
    // `redeemInvite` needs one to be the watcher — so sign-in is the first
    // thing onboarding does rather than something it asks for later.
    if (!signedIn) {
      return const HomeRoute(
        screen: HomeScreen.onboarding,
        watcherListReachable: false,
      );
    }

    final isWatched = choices.wantsToBeWatched || hasAcceptedWatchedLinks;
    final isWatcher = choices.wantsToWatch || hasAcceptedWatcherLinks;

    // **Links are what let a reinstall skip the questions**, and the condition
    // is deliberately about links rather than about `completed` alone. A user
    // whose store was wiped but whose link graph survived has already answered
    // both questions by acting on them; asking again would be the app failing to
    // recognise somebody it is already relaying for.
    if (!choices.completed && !isWatched && !isWatcher) {
      return const HomeRoute(
        screen: HomeScreen.onboarding,
        watcherListReachable: false,
      );
    }

    // **Tap + Away takes priority, and the button is the compensation.** PLAN.md
    // settles this: the person who taps daily should never have to navigate to
    // reach their one action, so the watcher pays the one extra tap.
    if (isWatched) {
      return HomeRoute(
        screen: HomeScreen.tap,
        watcherListReachable: isWatcher,
      );
    }

    if (isWatcher) {
      return const HomeRoute(
        screen: HomeScreen.watcherList,
        watcherListReachable: false,
      );
    }

    // **Both questions skipped, and no links: the Tap screen, not onboarding
    // again.** The app knows nothing about this person, and the Tap screen is
    // the one that says so out loud — `TapCopy.nobodyYet` names the empty
    // audience and offers the way to fill it. Sending them round the questions
    // a second time would ask an 80-year-old the same thing every morning, and
    // the watcher list would be worse: a list of nobody, on a screen built for
    // somebody who is watching people.
    return const HomeRoute(
      screen: HomeScreen.tap,
      watcherListReachable: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeRoute &&
      other.screen == screen &&
      other.watcherListReachable == watcherListReachable;

  @override
  int get hashCode => Object.hash(screen, watcherListReachable);

  @override
  String toString() =>
      'HomeRoute(${screen.name}, watcherListReachable: $watcherListReachable)';
}
