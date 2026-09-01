import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/onboarding_controller.dart';
import '../application/providers.dart';
import '../copy/onboarding_copy.dart';
import '../copy/tap_copy.dart';
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

  /// Signed in, but the account had no name and one has not been typed yet.
  ///
  /// Held here rather than as an `OnboardingStep` because it is not a step:
  /// almost nobody sees it, it cannot be returned to, and it is answerable only
  /// with the uid this screen has just obtained. `OnboardingController`'s own
  /// docstring draws the line — it owns *"the step and the two answers"*,
  /// because those decide where the app opens for ever afterwards. This decides
  /// nothing beyond one field on one document.
  String? _signedInUid;

  /// Stores the typed name, then finishes exactly as an account with a name
  /// would have.
  ///
  /// [name] arrives **trimmed and non-empty** — [AskNameForm] owns that rule, so
  /// it can be asserted without a composition root.
  ///
  /// Written to disk **before** `users/{uid}`, so a failed profile write leaves
  /// the name to retry with rather than making them type it again — and so the
  /// next launch's `refreshProfile` cannot overwrite it with the placeholder.
  Future<void> _submitName(String name) async {
    final uid = _signedInUid;
    if (uid == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    await ref.read(appServicesProvider).store.setChosenDisplayName(name);
    if (!mounted) return;
    await _finish(uid);
  }

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

    // **Ask for a name rather than inventing one.** Google Sign-In almost always
    // supplies a display name; when it does not, this used to write the literal
    // `'Someone'` into `users/{uid}`, which `redeemInvite` then denormalises onto
    // every link (§7). From that point the person reads as *"Someone"* on their
    // family's phones — *"Choose the last day Someone is away"* — which names a
    // role, forbidden by `guidelines.md`, and silently suppresses their away
    // attribution, because `AwayRecord.unnameable` is the same string.
    //
    // Asked HERE, before `users/{uid}` is written, so the document is right the
    // first time. Writing the placeholder and correcting it later would leave
    // every link redeemed in between carrying the wrong name, on somebody else's
    // phone, with no path back.
    if (services.needsDisplayName) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _signedInUid = uid;
      });
      return;
    }

    await _finish(uid);
  }

  /// Writes `users/{uid}`, registers for push, and advances the flow.
  ///
  /// Split out of [_signIn] so the name screen can reach it with exactly the
  /// same ordering. The display name is resolved by
  /// [AppServices.profileDisplayName], which is also what every later launch
  /// uses — one precedence rule, in one place, rather than a second copy here
  /// that could disagree with `refreshProfile`.
  Future<void> _finish(String uid) async {
    final services = ref.read(appServicesProvider);
    try {
      await services.users.upsert(
        uid: uid,
        displayName: await services.profileDisplayName(),
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
    await ref.read(onboardingControllerProvider.notifier).signedIn(uid);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_signedInUid != null) {
      return AskNameForm(
        busy: _busy,
        error: _error,
        onSubmit: (name) => unawaited(_submitName(name)),
      );
    }
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
        final failed = snapshot.hasError;
        final lines = <String>[
          if (names != null && names.watchers.isNotEmpty)
            OnboardingCopy.summaryWatched(names.watchers),
          if (names != null && names.watched.isNotEmpty)
            names.watched.length == 1
                ? OnboardingCopy.summaryWatching(names.watched)
                : OnboardingCopy.summaryWatchingMany(names.watched),
        ];
        final nothing = names != null && lines.isEmpty;

        // **The tick and "You're all set" are gated on there being something to
        // report**, and that is not presentation polish.
        //
        // Rendered unconditionally, a user who skipped both questions — or who
        // opened a code screen nobody redeemed — finished onboarding reading a
        // green tick and *"You're all set"* directly above *"Nobody is set up
        // yet."* That is the first false all-clear this app makes, on the screen
        // the whole phase exists to reach, and it undoes the care that went into
        // reporting evidence rather than intent two lines below it.
        final settled = lines.isNotEmpty;

        return _Page(
          children: [
            const Spacer(),
            if (settled) ...[
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
            ],
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
            // **A screen that cannot tell says so.** Without this the pending
            // and failed states are indistinguishable from "nothing is set up"
            // — the `FutureBuilder` rendered a tick, a title and Finish and
            // nothing else, permanently, if `_names` threw. Silence would be a
            // silent failure, which is the one thing this app may not do.
            if (failed)
              Text(
                OnboardingCopy.summaryUnknown,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            if (names == null && !failed)
              Semantics(
                label: TapCopy.loadingLabel,
                child: const Center(child: CircularProgressIndicator()),
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
/// The name field, for the test that has to type into it.
///
/// A named key rather than `find.byType(TextField)`: the pairing flow has a text
/// field too, and a finder that would match either is a finder that stops
/// meaning anything the moment these screens are composed differently.
const Key nameFieldKey = Key('onboarding-name-field');

/// [AskNameForm]'s button. Keyed for the same reason as the field.
const Key nameSubmitKey = Key('onboarding-name-submit');

/// *"What is your name?"* — one question, one field, one button.
///
/// **Public, and it reaches no provider, no repository and no store.** That is
/// deliberate and it is the only way this screen is testable at all: this repo
/// has already established that pumping a widget which touches a real
/// `LocalStore` **hangs** — `WidgetTester` runs in a fake-async zone, `sqflite`
/// does real I/O off it, and the test times out rather than failing.
/// `app_lifecycle_test.dart` records that finding in full and is the reason
/// `IAmOkApp` is never pumped. Everything this widget decides — the field's
/// rule, the floors, what the button does with whitespace — is asserted by
/// pumping it directly with a callback.
///
/// It owns exactly one rule: **a name is trimmed, and an empty one is refused.**
/// [onSubmit] is therefore called only with a trimmed, non-empty string, so the
/// caller has nothing left to validate. The rules require `displayName` to be
/// 1–100 characters after trimming, and a write outside that is a
/// `permission-denied` on the one document that makes pairing possible.
///
/// Built to the same floors as every other elderly-facing surface: the whole
/// page scrolls, so the largest system font scale pushes nothing off the bottom
/// and the keyboard cannot cover the field; the button is [tallButton],
/// comfortably past the 48dp floor; and the field carries a visible label which
/// is also its screen-reader label, because `guidelines.md` requires every
/// interactive element to be labelled and a hint alone is not read as one.
///
/// **`maxLength` is not used**, deliberately: it renders a live character
/// counter, which is clutter on a screen whose whole job is one plain question.
/// The 100-character ceiling is enforced by an input formatter instead, so it
/// cannot be exceeded rather than being refused after the fact.
class AskNameForm extends StatefulWidget {
  const AskNameForm({
    super.key,
    required this.busy,
    required this.onSubmit,
    this.error,
  });

  /// A write is in flight: the field and the button are disabled.
  final bool busy;

  /// Called with a **trimmed, non-empty** name.
  final ValueChanged<String> onSubmit;

  /// A failure from the write, rendered below the field.
  ///
  /// Separate from the field's own refusal, and rendered separately, because
  /// `errorText` also turns the field red and relabels it as invalid — the same
  /// distinction `pairing_screens.dart` draws between refusals that are about
  /// the code and refusals that are not.
  final String? error;

  @override
  State<AskNameForm> createState() => _AskNameFormState();
}

class _AskNameFormState extends State<AskNameForm> {
  final _field = TextEditingController();
  String? _fieldError;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.busy) return;
    final typed = _field.text.trim();
    if (typed.isEmpty) {
      setState(() => _fieldError = OnboardingCopy.nameEmpty);
      return;
    }
    setState(() => _fieldError = null);
    widget.onSubmit(typed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Page(
      children: [
        const Spacer(),
        Text(
          OnboardingCopy.nameTitle,
          style: theme.textTheme.displaySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Text(
          OnboardingCopy.nameBlurb,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        TextField(
          key: nameFieldKey,
          controller: _field,
          autofocus: true,
          enabled: !widget.busy,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            labelText: OnboardingCopy.nameFieldLabel,
            border: const OutlineInputBorder(),
            errorText: _fieldError,
            errorMaxLines: 3,
          ),
        ),
        const Spacer(),
        if (widget.error case final message?) ...[
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
        ],
        FilledButton(
          key: nameSubmitKey,
          onPressed: widget.busy ? null : _submit,
          style: tallButton,
          child: widget.busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(OnboardingCopy.nameAction),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

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
