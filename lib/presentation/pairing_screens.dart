import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../application/onboarding_controller.dart';
import '../application/providers.dart';
import '../copy/onboarding_copy.dart';
import '../copy/tap_copy.dart';
import '../domain/domain.dart';
import 'onboarding_screen.dart';

/// The two pairing screens: **make a code**, and **use a code**.
///
/// ## Both are built for one sitting
///
/// `ui-ux/screens.md` calls it out and leaves it undesigned: *"realistically the
/// family member sets up both phones in one sitting; the pairing flow should
/// assume that rather than assuming two people configuring independently."*
///
/// Three things follow, and they are the design:
///
/// 1. **The code is sized to be read across a table**, grouped three and three,
///    because it is spoken aloud as often as it is typed.
/// 2. **The phone that made the code notices when it is used**, without anybody
///    navigating — the family member is holding the *other* phone at that
///    moment, and a confirmation only they can see would leave the person the
///    app is for looking at an unchanged screen.
/// 3. **Every refusal names a next action**, because in a sitting there is
///    somebody there to carry it out.
///
/// Both are reachable from onboarding **and** from either main screen, which is
/// why they are ordinary pushed routes rather than steps of a flow.

/// Shows a code, and waits for somebody to use it.
///
/// Pops `true` if at least one person paired while it was open, so the caller
/// can record that this user is now watched.
class ShareCodeScreen extends ConsumerStatefulWidget {
  const ShareCodeScreen({super.key});

  @override
  ConsumerState<ShareCodeScreen> createState() => _ShareCodeScreenState();
}

class _ShareCodeScreenState extends ConsumerState<ShareCodeScreen> {
  InviteOutcome? _outcome;

  /// Watchers already accepted when this screen opened.
  ///
  /// The **baseline is the point**. Somebody who already has two watchers and
  /// adds a third must see *the third one's* name, not a confirmation about a
  /// pairing from last month — and `WatchedAudience` is explicit that this app
  /// never renders a status *change* about watchers on the watched side. This is
  /// a confirmation of an action taken seconds ago on this screen, which is a
  /// different thing and the only reason it is allowed.
  Set<String>? _knownWatchers;

  /// The name to confirm, once somebody redeems.
  String? _newWatcherName;

  StreamSubscription<List<Link>>? _links;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // **The baseline comes from the STORE, before the stream is attached.**
      //
      // It used to be seeded from the first snapshot, which is wrong in two
      // ways. A redemption that beat the first snapshot — a slow first listen, a
      // phone briefly offline, the other person typing fast — was swallowed into
      // the baseline, and the screen then waited for ever on a pairing that had
      // already happened. And the first snapshot is Firestore's answer, whereas
      // the question this screen asks is *who was watching me when I opened
      // it*, which the local store already knows and §3 makes the thing every
      // other surface renders from.
      await _seedBaseline();
      if (!mounted) return;
      unawaited(_createCode());
      _listenForRedemption();
    });
  }

  Future<void> _seedBaseline() async {
    final services = ref.read(appServicesProvider);
    if (!services.signedIn) return;
    try {
      // `linksWatching` is `watched_uid = me` — the people watching *me*. The
      // store's two names read the opposite way round to their meaning.
      final links = await services.store.linksWatching(services.selfUid);
      _knownWatchers = {
        for (final link in links)
          if (link.isAccepted) link.watcherUid,
      };
    } on Object {
      // An empty baseline is the safe direction: it means the first watcher the
      // stream reports is treated as new, so the reader is told about a pairing
      // that may already have existed. Telling somebody about a real link is
      // survivable; missing the one they are waiting for is what this screen is
      // for.
      _knownWatchers = <String>{};
    }
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    super.dispose();
  }

  Future<void> _createCode() async {
    final outcome = await ref.read(appServicesProvider).invites.create();
    if (!mounted) return;
    setState(() => _outcome = outcome);
  }

  /// Notices the moment the other phone redeems.
  ///
  /// A **nudge, not a decision** (§3): the stream says *something changed*, and
  /// the response is `syncLinks()` — the same read-and-replace path a launch and
  /// a resume use — after which the local store is what everything else reads.
  /// Losing the stream costs a live update and never correctness; the pairing is
  /// already durable in Firestore before this fires.
  void _listenForRedemption() {
    final services = ref.read(appServicesProvider);
    if (!services.signedIn) return;
    _links = services.links.watchWatchedBy(services.selfUid).listen(
      (links) async {
        final accepted = {
          for (final link in links)
            if (link.isAccepted) link.watcherUid: link.watcherName,
        };
        final baseline = _knownWatchers ??= <String>{};
        final arrived = accepted.keys.where((uid) => !baseline.contains(uid));
        if (arrived.isEmpty) return;

        // The store first, so that popping back to a main screen finds the link
        // already there rather than racing the next reconcile for it.
        await services.syncLinks();
        if (!mounted) return;

        // **The baseline moves HERE, at the moment of confirmation.**
        //
        // `_addAnother` used to clear it to null instead, with a comment saying
        // the new watcher "joins the baseline". It did not: clearing it deferred
        // the baseline to the *next* emission, and the next emission is the one
        // caused by the second redemption — which then computed a baseline that
        // already contained the second watcher, found nobody new, and returned.
        // The screen sat on *"Waiting for them to type it in."* for ever on a
        // pairing that had succeeded, which is the one thing "Add someone else"
        // exists to do.
        _knownWatchers = accepted.keys.toSet();

        final name = accepted[arrived.first];
        setState(() => _newWatcherName = name);
        // **Spoken, not only shown.** Nothing in Flutter re-reads a changed
        // widget, so without this a blind watched person hears *"Waiting for
        // them to type it in"* and then hears nothing, for ever — on the screen
        // whose whole justification is that the person the app is *for* should
        // not be left staring at an unchanged screen. Already-approved copy;
        // `WatcherBody` is the pattern, proven on hardware 2026-08-25.
        if (name != null && name.isNotEmpty) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            OnboardingCopy.nowWatching(name),
            Directionality.of(context),
          );
        }

        // The answer to screen 1 now has evidence behind it. Recorded here
        // because this screen is also reachable from the Tap screen, where
        // somebody who once skipped the question has just changed their mind.
        unawaited(
          ref
              .read(onboardingControllerProvider.notifier)
              .recordPairing(asWatched: true),
        );
      },
      // A stream error is not a failed pairing and must not be rendered as one.
      // The code on screen is still valid and still redeemable; all that is lost
      // is the live confirmation, and the next reconcile finds the link anyway.
      onError: (Object _, StackTrace _) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final paired = _newWatcherName;
    return Scaffold(
      appBar: AppBar(title: const Text(OnboardingCopy.yourCodeTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: switch ((paired, _outcome)) {
            // A pairing with an empty name is NOT rendered as a confirmation:
            // `nowWatching('')` reads *" will now know you're OK."*, which is
            // the "offline since null" failure `guidelines.md` names by hand.
            // The link is real and the store has it; the screen keeps waiting
            // rather than saying something malformed, and the next reconcile
            // shows the person on the Tap screen's audience line.
            (final String name, _) when name.isNotEmpty => _Paired(
                watcherName: name,
                onAddAnother: _addAnother,
                onDone: () => Navigator.of(context).pop(true),
              ),
            (_, final InviteReady ready) => _CodeOnOffer(ready: ready),
            (_, final InviteRefused refused) => _Refused(
                message: OnboardingCopy.inviteRefusal(refused.reason),
                onRetry: () {
                  setState(() => _outcome = null);
                  unawaited(_retryCreate(refused.reason));
                },
              ),
            _ => const _Working(),
          },
        ),
      ),
    );
  }

  /// **Try again**, and for `profileMissing` it retries the thing that actually
  /// failed.
  ///
  /// The sentence is *"This phone could not finish getting ready. Try again."*
  /// with a button under it — and re-running `createInvite` alone would fail
  /// identically for ever, because nothing else re-writes `users/{uid}`. That is
  /// an infinite loop dressed as an action, on a screen whose copy promises to
  /// say what to do.
  Future<void> _retryCreate(InviteRefusal reason) async {
    if (reason == InviteRefusal.profileMissing) {
      await ref.read(appServicesProvider).refreshProfile();
      if (!mounted) return;
    }
    await _createCode();
  }

  /// A second watcher needs a **second code** — an invite is single-use (§8).
  ///
  /// **The baseline is deliberately left alone.** It was updated at the moment
  /// the last pairing was confirmed, so it already contains that watcher and the
  /// next confirmation is about the next person. Clearing it here is what broke
  /// the second pairing — see the listener.
  void _addAnother() {
    setState(() {
      _newWatcherName = null;
      _outcome = null;
    });
    unawaited(_createCode());
  }
}

class _CodeOnOffer extends ConsumerWidget {
  const _CodeOnOffer({required this.ready});

  final InviteReady ready;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(OnboardingCopy.yourCodeBlurb, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 32),
        _BigCode(code: ready.code),
        const SizedBox(height: 16),
        _ExpiryLine(expiresAt: ready.expiresAt),
        const SizedBox(height: 32),
        FilledButton.tonalIcon(
          onPressed: () => SharePlus.instance.share(
            ShareParams(text: OnboardingCopy.shareMessage(ready.code)),
          ),
          icon: const Icon(Icons.share),
          label: const Text(OnboardingCopy.shareCode),
          style: tallButton,
        ),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                OnboardingCopy.waitingForCode,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The code itself — the one thing on this screen somebody has to read out.
class _BigCode extends StatelessWidget {
  const _BigCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      // **Spelled out for a screen reader**, because "K7RTQX" is read as a word
      // and a listener cannot spell a word back. The visual grouping is for the
      // eye; this is the same information for the ear.
      label: code.split('').join(' '),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            InviteCode.forReading(code),
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              // Monospaced digits and letters, so `K7R TQX` does not shift width
              // as it is read, and the two groups stay the same size.
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
              letterSpacing: 6,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// *"It stops working at 09:00 on Thursday 27 August."*
///
/// Rendered in the **device's** zone and its own 12/24-hour setting, both read
/// from `LocalStore` where `ClockService` cached them (ADR-0002). A watched
/// person reading this is in their own zone by definition, so the device's is
/// the right one — unlike a warning, which is about somebody else's day.
class _ExpiryLine extends ConsumerWidget {
  const _ExpiryLine({required this.expiresAt});

  final DateTime expiresAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = ref.watch(deviceFactsProvider).value;
    if (facts == null) return const SizedBox.shrink();
    return Text(
      OnboardingCopy.codeExpiry(
        expiresAt: expiresAt,
        zone: facts.zone,
        uses24Hour: facts.uses24Hour,
      ),
      style: Theme.of(context).textTheme.bodyMedium,
      textAlign: TextAlign.center,
    );
  }
}

class _Paired extends StatelessWidget {
  const _Paired({
    required this.watcherName,
    required this.onAddAnother,
    required this.onDone,
  });

  final String watcherName;
  final VoidCallback onAddAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Icon(Icons.check_circle, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          OnboardingCopy.nowWatching(watcherName),
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        FilledButton(
          onPressed: onDone,
          style: tallButton,
          child: const Text(OnboardingCopy.done),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: onAddAnother,
          style: tallButton,
          child: const Text(OnboardingCopy.addAnother),
        ),
      ],
    );
  }
}

/// Types a code somebody was given.
///
/// Pops `true` if a link was made, so the caller can record that this user is
/// now a watcher.
class EnterCodeScreen extends ConsumerStatefulWidget {
  const EnterCodeScreen({super.key});

  @override
  ConsumerState<EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends ConsumerState<EnterCodeScreen> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _pairedWith;

  /// Why the previous attempt was refused, so a retry can repair what it can.
  PairingRefusal? _lastRefusal;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final services = ref.read(appServicesProvider);
    // **If the last attempt failed because THIS phone had no profile, repair it
    // before re-sending.** `users/{uid}` is written at sign-in and nowhere else,
    // so without this the approved *"This phone could not finish getting ready.
    // Try again."* sends somebody into a loop that cannot succeed.
    if (_lastRefusal == PairingRefusal.watcherProfileMissing) {
      await services.refreshProfile();
      if (!mounted) return;
    }
    final outcome = await services.invites.redeem(_field.text);
    if (!mounted) return;

    switch (outcome) {
      case Paired(:final watchedName):
        // The link exists on the server; pull it down before leaving, so the
        // watcher list this pops back to has the row and its warning alarm gets
        // armed by the next reconcile rather than the one after.
        await ref.read(appServicesProvider).syncLinks();
        if (!mounted) return;
        await ref
            .read(onboardingControllerProvider.notifier)
            .recordPairing(asWatcher: true);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _pairedWith = watchedName;
        });
        // The same reason the refusals are announced, and the same approved
        // string the screen renders.
        if (watchedName.isNotEmpty) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            OnboardingCopy.nowLookingAfter(watchedName),
            Directionality.of(context),
          );
        }
      case PairingRefused(:final reason):
        final message = OnboardingCopy.pairingRefusal(reason);
        setState(() {
          _busy = false;
          _error = message;
          _lastRefusal = reason;
        });
        // **Spoken, not only shown.** The refusal appears as text above a button
        // that still has focus, and nothing re-reads it — so a screen-reader
        // user presses *"Use this code"* and hears nothing at all, with no way
        // to tell whether it did anything. The whole justification for having
        // nine distinguished refusals is that each names a different next
        // action, and that is exactly what is lost.
        if (!mounted) return;
        SemanticsService.sendAnnouncement(
          View.of(context),
          message,
          Directionality.of(context),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paired = _pairedWith;

    return Scaffold(
      appBar: AppBar(title: const Text(OnboardingCopy.enterCodeTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: paired != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Icon(
                      Icons.check_circle,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      OnboardingCopy.nowLookingAfter(paired),
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: tallButton,
                      child: const Text(OnboardingCopy.done),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      OnboardingCopy.enterCodeBlurb,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _field,
                      autofocus: true,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _busy ? null : unawaited(_submit()),
                      // Not `TextInputType.text`: the alphabet is letters AND
                      // digits, so a numeric keyboard would hide half of it and
                      // an email keyboard would autocorrect it.
                      keyboardType: TextInputType.visiblePassword,
                      // Upper-cased as they type, so the field shows the same
                      // characters the other phone is displaying.
                      inputFormatters: [UpperCaseFormatter()],
                      style: theme.textTheme.headlineMedium?.copyWith(
                        letterSpacing: 6,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        labelText: OnboardingCopy.codeFieldLabel,
                        border: const OutlineInputBorder(),
                        errorText: _error,
                        // Never truncated to a line: these sentences all name a
                        // next action, and the action is the half that would be
                        // cut off.
                        errorMaxLines: 4,
                      ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: _busy ? null : () => unawaited(_submit()),
                      style: tallButton,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(OnboardingCopy.useCode),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Upper-cases as the person types.
///
/// Public so it can be asserted directly in
/// `test/presentation/pairing_screens_test.dart`: it is the only piece of this
/// screen that transforms what somebody typed, and a formatter that mangled a
/// cursor position would be a code nobody could finish entering.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      // The selection is carried through unchanged: upper-casing is
      // length-preserving for this alphabet, so the caret does not move.
      newValue.copyWith(text: newValue.text.toUpperCase());
}

class _Working extends StatelessWidget {
  const _Working();

  /// A bare spinner says nothing at all to TalkBack, which is the whole
  /// experience for the reader who depends on it — and this one is on the screen
  /// a blind watched person opens to *get* a code. Every other spinner in this
  /// app is labelled; this was the one that was not.
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 64),
        child: Center(
          child: Semantics(
            label: TapCopy.loadingLabel,
            child: const CircularProgressIndicator(),
          ),
        ),
      );
}

class _Refused extends StatelessWidget {
  const _Refused({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text(message, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: onRetry,
            style: tallButton,
            child: const Text(OnboardingCopy.tryAgain),
          ),
        ],
      );
}

