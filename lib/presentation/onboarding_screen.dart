import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/onboarding_controller.dart';
import '../application/providers.dart';
import '../copy/onboarding_copy.dart';
import '../domain/domain.dart';
import 'pairing_screens.dart';

/// Sign in, two questions about other people, and a summary.
///
/// ## Role is never asked directly, and that is the whole design
///
/// PLAN.md fixes it: *"Who should know you're OK?"* makes this user **watched**,
/// *"Who are you looking after?"* makes them a **watcher**, and both selected
/// means Tap + Away with a button to the list. The questions are about *other
/// people* on purpose — *"are you the elderly one?"* is a question nobody wants
/// to answer.
///
/// The three screens are **identical for every user**, which is why nothing here
/// branches on anything until the summary, and the summary branches on the links
/// that exist rather than on what was tapped.
///
/// ## Sign-in is in front of them, and it is new
///
/// The screen inventory specifies no sign-in surface — Phase 4 drove it from the
/// debug harness precisely so no un-approved elderly-facing screen shipped
/// early. It cannot be avoided here: every link is keyed by a uid.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: switch (state.step) {
          OnboardingStep.signIn => const _SignIn(),
          OnboardingStep.watchedQuestion => const _WatchedQuestion(),
          OnboardingStep.watcherQuestion => const _WatcherQuestion(),
          OnboardingStep.summary => const _Summary(),
        },
      ),
    );
  }
}

class _SignIn extends ConsumerStatefulWidget {
  const _SignIn();

  @override
  ConsumerState<_SignIn> createState() => _SignInState();
}

class _SignInState extends ConsumerState<_SignIn> {
  bool _busy = false;
  String? _error;

  /// Signs in, then writes `users/{uid}` **before going anywhere**.
  ///
  /// The order is not cosmetic. `redeemInvite` reads that document to
  /// denormalise `displayName` and `timezone` onto the link (§7), so a signed-in
  /// user without one cannot be paired with at all — and the failure would
  /// surface on somebody *else's* phone, as a code that will not work, a whole
  /// screen away from its cause. The debug harness has done it in this order
  /// since Phase 4 for the same reason.
  ///
  /// A **dismissal is a choice, not a fault**: `signIn` returns null and nothing
  /// is shown.
  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final services = ref.read(appServicesProvider);

    final String? uid;
    try {
      uid = await services.auth.signIn();
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = OnboardingCopy.signInFailed;
      });
      return;
    }
    if (uid == null) {
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    try {
      await services.users.upsert(
        uid: uid,
        displayName: services.auth.displayName ?? 'Someone',
        timezone: await services.store.deviceTimezone() ?? 'Etc/UTC',
      );
    } on Object {
      if (!mounted) return;
      // **Its own message.** The account exists; what failed is the half that
      // makes pairing possible. "Could not sign in" would send them to re-try
      // the part that worked.
      setState(() {
        _busy = false;
        _error = OnboardingCopy.profileFailed;
      });
      return;
    }

    // The token, under the uid just established. `registerForPush` keys on
    // `selfUid`, which is still the launch-time snapshot here, so this is the
    // one place that holds the new uid — the same reason the debug harness
    // passes it explicitly.
    unawaited(services.push.register(uid: uid).catchError((Object _) => null));

    if (!mounted) return;
    ref.read(onboardingControllerProvider.notifier).signedIn(uid);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Page(
      children: [
        const Spacer(),
        Text(
          OnboardingCopy.signInTitle,
          style: theme.textTheme.displaySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Text(
          OnboardingCopy.signInBlurb,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        if (_error case final message?) ...[
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
        ],
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_signIn()),
          style: tallButton,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(OnboardingCopy.signInAction),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// *"Who should know you're OK?"* — answering makes this user **watched**.
class _WatchedQuestion extends ConsumerWidget {
  const _WatchedQuestion();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Question(
        question: OnboardingCopy.watchedQuestion,
        blurb: OnboardingCopy.watchedBlurb,
        action: OnboardingCopy.watchedAction,
        onAction: () async {
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const ShareCodeScreen()),
          );
          // **Answered either way, and the screen's own result is deliberately
          // ignored.** Opening the code screen *is* the answer to this question —
          // they said somebody should know — so the flow moves on whether or not
          // anybody redeemed while they were in there. A code nobody has used yet
          // is exactly the state `TapCopy.nobodyYet` describes, and the Tap
          // screen is still where this person belongs.
          await ref
              .read(onboardingControllerProvider.notifier)
              .answeredWatched(wants: true);
        },
        onSkip: () => ref
            .read(onboardingControllerProvider.notifier)
            .answeredWatched(wants: false),
      );
}

/// *"Who are you looking after?"* — answering makes this user a **watcher**.
class _WatcherQuestion extends ConsumerWidget {
  const _WatcherQuestion();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Question(
        question: OnboardingCopy.watcherQuestion,
        blurb: OnboardingCopy.watcherBlurb,
        action: OnboardingCopy.watcherAction,
        onBack: ref.read(onboardingControllerProvider.notifier).back,
        onAction: () async {
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const EnterCodeScreen()),
          );
          await ref
              .read(onboardingControllerProvider.notifier)
              .answeredWatcher(wants: true);
        },
        onSkip: () => ref
            .read(onboardingControllerProvider.notifier)
            .answeredWatcher(wants: false),
      );
}

/// One question, one action, one skip — the same shape on both screens.
class _Question extends StatelessWidget {
  const _Question({
    required this.question,
    required this.blurb,
    required this.action,
    required this.onAction,
    required this.onSkip,
    this.onBack,
  });

  final String question;
  final String blurb;
  final String action;
  final Future<void> Function() onAction;
  final FutureOr<void> Function() onSkip;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Page(
      children: [
        if (onBack case final back?)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: back,
              icon: const Icon(Icons.arrow_back),
              // Labelled, because an unlabelled icon button is a control a
              // screen-reader user cannot identify at all.
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          )
        else
          const SizedBox(height: 48),
        const Spacer(),
        Text(
          question,
          style: theme.textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Text(
          blurb,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => unawaited(Future<void>.sync(onAction)),
          style: tallButton,
          child: Text(action),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => unawaited(Future<void>.sync(onSkip)),
          style: tallButton,
          child: const Text(OnboardingCopy.skip),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// What was set up, and what happens next.
///
/// **Built from the links that exist, never from what was tapped.** Somebody who
/// chose "Add someone" and closed the code screen without anybody redeeming has
/// set nothing up, and a summary claiming otherwise would be the first false
/// claim this app ever made to a family. [HomeRoute] unions intent with evidence
/// to decide *where to go*; this screen reports evidence only.
class _Summary extends ConsumerWidget {
  const _Summary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<({List<String> watchers, List<String> watched})>(
      future: _names(ref),
      builder: (context, snapshot) {
        final names = snapshot.data;
        final lines = <String>[
          if (names != null && names.watchers.isNotEmpty)
            OnboardingCopy.summaryWatched(names.watchers),
          if (names != null && names.watched.isNotEmpty)
            names.watched.length == 1
                ? OnboardingCopy.summaryWatching(names.watched)
                : OnboardingCopy.summaryWatchingMany(names.watched),
        ];
        final nothing = names != null && lines.isEmpty;

        return _Page(
          children: [
            const Spacer(),
            Icon(
              Icons.check_circle,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              OnboardingCopy.summaryTitle,
              style: theme.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            for (final line in lines) ...[
              Text(
                line,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
            ],
            if (nothing)
              Text(
                OnboardingCopy.summaryNothing,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            // The one instruction the watched person needs, and the last thing
            // they read before the screen they will use every morning.
            if (names != null && names.watchers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                OnboardingCopy.summaryTapDaily,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const Spacer(),
            FilledButton(
              onPressed: () => unawaited(
                ref.read(onboardingControllerProvider.notifier).finish(),
              ),
              style: tallButton,
              child: const Text(OnboardingCopy.finish),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  /// Both directions, off the local store.
  ///
  /// `LocalStore`'s two link queries read the opposite way round to their names,
  /// which is worth stating at every call site: `linksWatching(uid)` is
  /// `watched_uid = uid` — the people watching *me* — and `linksWatchedBy(uid)`
  /// is `watcher_uid = uid`.
  Future<({List<String> watchers, List<String> watched})> _names(
    WidgetRef ref,
  ) async {
    final services = ref.read(appServicesProvider);
    if (!services.signedIn) return (watchers: <String>[], watched: <String>[]);
    final watchingMe = await services.store.linksWatching(services.selfUid);
    final iWatch = await services.store.linksWatchedBy(services.selfUid);
    return (
      // `WatchedAudience` is the one place that decides how a watcher list is
      // ordered and deduped, so the summary reuses it rather than sorting again
      // — the reader sees its answer on the Tap screen the very next day.
      watchers: WatchedAudience.from(watchingMe).names,
      watched: [
        for (final link in iWatch)
          if (link.isAccepted) link.watchedName,
      ]..sort(),
    );
  }
}

/// The page frame every step shares: padding, a max width, and a scroll for the
/// largest system font scale.
///
/// `guidelines.md` requires the app to work at the system's largest font setting
/// **without clipping or overlap**, which a bare `Column` cannot promise — so
/// the frame scrolls rather than each screen remembering to.
class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      );
}

/// Comfortably past `guidelines.md`'s 48dp floor for secondary controls, and it
/// holds at the largest system font scale because the minimum is a floor rather
/// than a height.
final ButtonStyle tallButton = ButtonStyle(
  minimumSize: WidgetStateProperty.all(const Size.fromHeight(56)),
);
