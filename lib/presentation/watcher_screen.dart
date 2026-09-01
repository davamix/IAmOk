import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../application/watcher_reconcile_service.dart';
import '../copy/away_copy.dart';
import '../copy/notification_copy.dart';
import '../copy/onboarding_copy.dart';
import '../copy/watcher_copy.dart';
import '../domain/domain.dart';
import '../platform/notification_router.dart';
import 'away_picker.dart';
import 'pairing_screens.dart';

/// The watcher's list — one row per watched person.
///
/// ## What this screen is for in Phase 3
///
/// Two jobs, and the second is the one that made it necessary now rather than
/// in Phase 7. It shows current state per person; and it is **where the *lost
/// access* notification lands**, which is what keeps that notification's *"Open
/// the app to see what to do."* true. ADR-0004 makes actionability the whole
/// reason that message exists as a fourth outcome, so a tap into a screen with
/// no remediation would hollow it out.
///
/// Layout is deliberately plain. `screens.md` marks the multi-person layout as
/// Phase 7 and undesigned; what is settled is the **row content**, and that is
/// what this renders.
///
/// ## State, not history
///
/// A row shows what is true **now**: an unresolved warning if one stands,
/// otherwise *"Everything OK"* with the last check-in this device managed to
/// read. A warning from three weeks ago followed by three weeks of check-ins is
/// history, and rendering it as status would have the app reporting a crisis
/// that resolved itself.
class WatcherScreen extends ConsumerStatefulWidget {
  const WatcherScreen({super.key});

  /// Whether this screen is on screen right now.
  ///
  /// **Owned by the screen, because it is a fact about the screen.** `main.dart`
  /// tracked it around its own `push` instead, which made it duplicated state
  /// and it went wrong the way duplicated state does: a second notification tap
  /// while the list was already up pushed a *second* `WatcherScreen`, and when
  /// the top one popped its `.then` cleared the flag while the bottom one was
  /// still showing.
  ///
  /// It decides which reconcile runs on resume — this screen's own, or
  /// `main.dart`'s — and the two differ in `watcherListShowing`, which is the
  /// one parameter that can lose a warning silently. So the answer has to be
  /// true rather than merely usually true.
  ///
  /// A counter rather than a bool so a stacked instance cannot clear it early.
  /// It also survives Phase 5's routing on role, which a call-site flag would
  /// not.
  static bool get isShowing => _showing > 0;
  static int _showing = 0;

  @override
  ConsumerState<WatcherScreen> createState() => _WatcherScreenState();
}

class _WatcherScreenState extends ConsumerState<WatcherScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WatcherScreen._showing++;
    WidgetsBinding.instance.addObserver(this);
    // **Ask once, here too.** `ensureNotificationsAsked` was called from
    // `TapScreen` and nowhere else, which covered everybody while the Tap screen
    // was home. Phase 5's routing sends a watcher-only user straight here — and
    // on API 33+ `POST_NOTIFICATIONS` is denied by default, so their very first
    // screen was a red banner about a permission the app had never requested.
    //
    // That is the watcher: the person whose entire role is *receiving warnings*,
    // and whom §13 rates High precisely because Android takes the permission
    // back from apps nobody opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(watcherStateProvider.notifier).ensureNotificationsAsked(),
      );
    });
  }

  @override
  void dispose() {
    WatcherScreen._showing--;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A resume is a real reconcile, not a redraw. Android takes permissions back
    // from apps nobody opens (§13) — which describes this user — and opening the
    // app is itself a dead-man's-switch check: it attempts tier 1, corrects a
    // false warning if a late check-in has arrived, and clears a stale
    // access-lost notice.
    if (state == AppLifecycleState.resumed) {
      ref.read(watcherStateProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(watcherStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(WatcherCopy.title),
        // **In the app bar, not the body.** This is a watcher's screen: a busy
        // family member who may not open the app for weeks, for whom an action
        // in the bar is the ordinary place to look. The floor `guidelines.md`
        // sets on the *watched* screen — one screen, one action — is about the
        // person who taps daily and does not apply here.
        //
        // It is in the bar rather than only in the empty state because a watcher
        // with one person still needs a route to add a second.
        actions: const [EnterCodeButton(inAppBar: true)],
      ),
      body: state.when(
        // A bare spinner says nothing at all to TalkBack, which is the whole
        // experience for the reader who depends on it.
        loading: () => Center(
          child: Semantics(
            label: WatcherCopy.loadingLabel,
            child: const CircularProgressIndicator(),
          ),
        ),
        // The initial load failed — the store could not be opened, or the first
        // reconcile threw. Says what happened and names a next human, and offers
        // the action, exactly as the Tap screen does.
        error: (_, _) =>
            _Failed(onRetry: () => ref.invalidate(watcherStateProvider)),
        data: (watcher) => WatcherBody(
          state: watcher,
          onRefresh: ref.read(watcherStateProvider.notifier).refresh,
          onTurnOnWarnings: ref
              .read(watcherStateProvider.notifier)
              .requestNotifications,
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(WatcherCopy.couldNotCheck, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onRetry,
            // Explicit, like every other button in the app. The theme's
            // `MaterialTapTargetSize.padded` already gives it a 48dp touch
            // area, so this was never a floor breach — but it was the only
            // control relying on that default, and a floor that holds by
            // accident is one nobody notices losing.
            style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text(WatcherCopy.retry),
          ),
        ],
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({this.onRefresh});

  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    // **Pull-to-refresh works here too.** The empty state returned early,
    // before the `RefreshIndicator` existed, so the one screen where a
    // reader most wants to try again — "I was just added, is it working
    // yet?" — was the one screen that could not. Backgrounding and
    // resuming reconciles, but nobody guesses that.
    onRefresh: () async => onRefresh?.call(),
    child: ListView(
      // Always scrollable, so the gesture is available with no content.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    WatcherCopy.nobody,
                    textAlign: TextAlign.center,
                    // Ordinary secondary text, never a warning colour.
                    // Styling an empty state as an alarm makes it a status
                    // message about other people's behaviour, which is the
                    // thing this app deliberately does not do.
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  // What makes the line above honest — see `WatcherCopy
                  // .nobody`, which dropped "ask a family member" the moment
                  // there was something to press.
                  const EnterCodeButton(),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Opens the code screen so this watcher can start looking after somebody else.
///
/// **Redeeming a code is the watcher's half of pairing**, which is why this side
/// reaches [EnterCodeScreen] and the Tap screen reaches [ShareCodeScreen]. A
/// watcher does not produce codes; the watched person does, because §2 makes
/// *the watched person's device generating and sharing the code* the consent
/// record.
///
/// Rendered as an icon in the app bar and as a labelled button in the empty
/// state — the same action, sized for where it is. The empty state is where a
/// reader is stuck and needs a wide target; the bar is where a reader with a
/// list already knows to look.
@visibleForTesting
class EnterCodeButton extends ConsumerWidget {
  const EnterCodeButton({this.inAppBar = false, super.key});

  final bool inAppBar;

  static const Key buttonKey = Key('watcher-add-someone');
  static const Key appBarKey = Key('watcher-add-someone-appbar');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> open() async {
      await Navigator.of(
        context,
      ).push<bool>(MaterialPageRoute(builder: (_) => const EnterCodeScreen()));
      // **Reconcile on the way back, whatever came out of that screen.** A new
      // link needs its warning alarm armed, and §3's rule is that nothing
      // patches state incrementally — so this re-reads rather than inserting a
      // row. `userInitiated` stays true: they pressed the button that led here.
      await ref.read(watcherStateProvider.notifier).refresh();
    }

    if (inAppBar) {
      return IconButton(
        key: appBarKey,
        onPressed: () => unawaited(open()),
        icon: const Icon(Icons.person_add_alt),
        // An unlabelled icon button is a control a screen-reader user cannot
        // identify at all.
        // **"I have a code", not "Add someone".** Both main screens carried a
        // button labelled *Add someone*, and they do opposite things: the Tap
        // screen's *produces* a code, this one *consumes* one. A watcher who
        // installed the app first, has no code, and reads "You're not looking
        // after anyone." pressed the only button on the screen and landed on a
        // form demanding an artefact that does not exist yet — while the
        // sentence that used to point them at the person who can make one is
        // exactly what this phase deleted.
        //
        // `watcherAction` is already approved: it is onboarding screen 2's
        // action for this identical action.
        tooltip: OnboardingCopy.watcherAction,
      );
    }
    return FilledButton.tonalIcon(
      key: buttonKey,
      onPressed: () => unawaited(open()),
      icon: const Icon(Icons.person_add_alt),
      label: const Text(OnboardingCopy.watcherAction),
      style: ButtonStyle(
        // `guidelines.md`: 48dp floor for secondary controls, no exceptions.
        minimumSize: WidgetStateProperty.all(const Size(0, 48)),
      ),
    );
  }
}

/// The list itself, split out from [WatcherScreen] so it can be pumped in a
/// widget test with a plain [WatcherState] and no provider container.
///
/// The same seam `TapBody` has, and for the same reason: every question about
/// this widget is a question about **rendering** — does an unresolved warning
/// show instead of "Everything OK", does the lost-access row outrank it, does a
/// screen reader get the person's name and their state in one utterance — and
/// `docs/testing/strategy.md`'s rule is that if a test needs a device to answer
/// a question about logic, the logic is in the wrong layer.
class WatcherBody extends StatefulWidget {
  const WatcherBody({
    super.key,
    required this.state,
    this.onRefresh,
    this.onTurnOnWarnings,
  });

  final WatcherState state;

  /// Pull-to-refresh. Optional so a test can pump the body without a container;
  /// the screen supplies the real reconcile.
  final Future<void> Function()? onRefresh;

  /// The warnings-off banner's action.
  final Future<void> Function()? onTurnOnWarnings;

  @override
  State<WatcherBody> createState() => _WatcherBodyState();
}

class _WatcherBodyState extends State<WatcherBody> {
  @override
  void initState() {
    super.initState();
    // A tap captured before this widget existed — the cold-start case, which is
    // the NORMAL one for this notification: §13's argument is that a low-usage
    // watcher never opens the app, so their app is closed almost by definition
    // at the moment they tap.
    NotificationRouter.instance.tappedLink.addListener(_onTapped);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTapped());
  }

  @override
  void dispose() {
    NotificationRouter.instance.tappedLink.removeListener(_onTapped);
    super.dispose();
  }

  /// Speaks a row that changed while the reader was already on this screen.
  ///
  /// **Here rather than in a listener, because this is the only place that has
  /// both states.** `didUpdateWidget` is handed the previous [WatcherState] and
  /// the new one, which is exactly the comparison the rule is written in terms
  /// of; a provider listener would have to keep its own copy of the last value
  /// and would then be a second source for it.
  ///
  /// `refresh()` never sets a loading state — it assigns the guarded result in
  /// one go — so the body stays mounted with the old data and this fires with a
  /// real `oldWidget.state` rather than after a rebuild from nothing.
  @override
  void didUpdateWidget(covariant WatcherBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _announceChanged(oldWidget.state);
  }

  /// *"Mum checked in. Everything OK."* — `screens.md`, approved 2026-08-25.
  ///
  /// **Two conditions, both required**, and each one removes a different kind of
  /// noise. The pass must not have been asked for: on a resume or a
  /// pull-to-refresh the reader is arriving at the screen and will read the row
  /// themselves, and announcing every refresh would talk over them. And the
  /// person's rendered status must actually have **changed** in the one direction
  /// that has an approved sentence — see [WatchedPersonState.checkedInSince],
  /// which is where the *"checked in"* half is checked against the cache rather
  /// than inferred from the row going quiet.
  ///
  /// **This changes nothing about what is posted or consumed.** `redundant`
  /// still posts no notification and still records the day. This is the screen
  /// speaking to a reader who is already on it, which is the premise the
  /// `redundant` argument always rested on — now true for someone who cannot see
  /// the row change.
  ///
  /// An announcement rather than a focus move, for the same reason [_onTapped]
  /// gives: Flutter has no supported way to place the screen reader's cursor on
  /// an arbitrary widget. It is a no-op with no assistive technology running.
  void _announceChanged(WatcherState previous) {
    if (widget.state.userInitiated) return;
    // **Two lists, and the order between them is the decision.**
    //
    // These are joined into ONE utterance below, and within one utterance the
    // part at risk is the **tail** — an interrupt takes the end, not the
    // beginning. `screens.md` rejected *"Update."* on exactly that reasoning,
    // and the same rule decides this: the loud sentence goes first.
    //
    // Appending both kinds to one list in `people` order put the warning last
    // whenever an improving row happened to sort above a worsening one. A blind
    // watcher would hear that one relative is fine and lose the sentence saying
    // a different relative is not — and no notification is coming, because
    // `redundant` already recorded the day as seen. That is the *"a lost warning
    // is worse in kind"* case this feature exists to close, reopened one row
    // along by list order alone.
    final owed = <String>[];
    final settled = <String>[];
    for (final person in widget.state.people) {
      final index = previous.people.indexWhere(
        (p) => p.link.id == person.link.id,
      );
      // A link that was not in the previous pass — newly paired, or previously
      // in `unreconciled` — has no "before" to have changed from. Reading its
      // arrival as a change would announce a row the reader has never heard.
      if (index < 0) continue;
      final before = previous.people[index];
      if (person.checkedInSince(before)) {
        settled.add(WatcherCopy.checkedIn(person.name));
      } else if (person.warnedSince(before)) {
        // **The row's own sentence, not a second way of saying it.** Approved
        // 2026-08-25 as the warning body *verbatim* — already-approved copy that
        // names the person in its first few words, which is `screens.md`'s rule
        // about the differentiator coming first, satisfied by reuse exactly as
        // `checkedIn` satisfies it by reusing `everythingOk`.
        //
        // The drafted candidate *"Update. Mum. No check-in from Mum
        // yesterday."* was rejected: *"Update."* is a category label that
        // differentiates nothing, is identical for both candidates, is the part
        // most likely to survive an interrupt while the claim gets clipped, and
        // it names her twice.
        //
        // `lines` rather than `spoken`: the footer is *"This phone last checked
        // Tuesday 10:14."*, a fact about this device's own effort rather than a
        // claim about her, and it is not what changed. `spoken` is right for the
        // row label, where the reader is swiping through everything on purpose.
        owed.add(
          _statusFor(
            person,
            watcherZone: widget.state.watcherZone,
            today: widget.state.today,
            uses24Hour: widget.state.uses24Hour,
          ).lines.join(' '),
        );
      }
    }
    final spoken = [...owed, ...settled];
    if (spoken.isEmpty) return;
    // **One utterance, however many rows settled.** This sent one announcement
    // per person, which is the shape most likely to lose one: the platform does
    // not reliably queue them, and the one dropped is the first — the oldest row
    // in the list, which is the person the reader has been waiting longest to
    // hear about.
    //
    // Joined rather than summarised, so every word stays approved copy. A
    // shorter *"Mum and Granddad checked in. Everything OK."* would be a new
    // string and needs the approval `screens.md` requires.
    SemanticsService.sendAnnouncement(
      View.of(context),
      spoken.join(' '),
      Directionality.of(context),
    );
  }

  /// Reached by a tap on a notification, so the row it names has to be
  /// **found**, not merely tinted.
  ///
  /// The first version set a background colour and stopped. Three things were
  /// wrong with that, and all three fail the reader who most needs this to work:
  ///
  /// * **Colour was the only signal**, which the accessibility floor forbids
  ///   outright. A watcher with any colour-vision difference tapped a
  ///   notification about Mum and arrived at an undifferentiated list.
  /// * **No scrolling.** Phase 7's multi-person layout is undesigned, but the
  ///   data model already supports it — and the row a notification is about can
  ///   be below the fold, which is exactly when a highlight is worth having.
  ///
  ///   `ensureVisible` reaches a row the `ListView` has **built**, which covers
  ///   the fold and a little past it. A row far down a long list is never built,
  ///   so its key has no context and nothing scrolls — stated here rather than
  ///   left to be discovered, because the code reads as though it handles any
  ///   distance. Reaching an arbitrary index needs fixed extents or a positioned
  ///   list, and that is a decision for Phase 7 along with the layout it serves.
  /// * **No semantic focus.** TalkBack read from the top of the list. The
  ///   notification's promise is *"open the app to see what to do"*, and a
  ///   screen-reader user got a list and no indication which row was meant.
  void _onTapped() {
    final linkId = NotificationRouter.instance.tappedLink.value;
    if (linkId == null || !mounted) return;
    // `people` only, so a payload naming a link that landed in `unreconciled`
    // matches nothing: it is neither highlighted nor **consumed**.
    //
    // The reader still lands on the list and still sees that person's failed
    // row, which is the honest answer — the row is what the tap was for.
    //
    // Leaving it unconsumed is the conservative half rather than a recovery
    // mechanism, and this comment used to claim otherwise: *"the next pass that
    // reconciles them successfully picks it up and highlights the row then"*.
    // It does not. This runs from `initState`'s post-frame callback and from the
    // `tappedLink` listener, and a successful pull-to-refresh produces a new
    // `WatcherBody` widget against the same `State`, so neither fires. The
    // highlight returns only if the screen is re-created. Not consuming still
    // costs nothing and keeps the option open; it just is not the thing the
    // sentence promised.
    final index = widget.state.people.indexWhere((p) => p.link.id == linkId);
    if (index < 0) return;
    NotificationRouter.instance.consume();
    setState(() => _highlighted = linkId);

    final name = widget.state.people[index].name;

    // After the frame that builds the highlighted row, so its context exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _highlightedRow.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(context, alignment: 0.1);
      // **An announcement, not a focus move.** Flutter has no supported way to
      // place the screen reader's cursor on an arbitrary widget, so rather than
      // pretend otherwise this says whose row was opened. The reader hears the
      // answer to "did this land on Mum" immediately, and the row is now on
      // screen for the next swipe to read in full.
      SemanticsService.sendAnnouncement(
        View.of(context),
        WatcherCopy.showingPerson(name),
        Directionality.of(context),
      );
    });
  }

  String? _highlighted;

  /// Points at the highlighted row so it can be scrolled to and focused.
  final _highlightedRow = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Above the list, because when it is showing it is the most important
        // thing on the screen: the rows describe what is true, this says the
        // reader will not be told about it again.
        //
        // **Above the empty state too.** The `isEmpty` early return used to sit
        // over this, so the banner could not appear on a screen with no rows.
        // The architecture round fixed the half of that which made a failed link
        // read as "nobody"; the early return itself survived. It is vacuous
        // today — with no links there is nobody to warn about — but the empty
        // state is exactly the moment someone is being added ("I was just added,
        // is it working yet?"), and the reader finding out then that this phone
        // cannot warn is worth more than finding out after the first miss.
        if (widget.state.warningsSilenced)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _WarningsOffBanner(onTurnOn: widget.onTurnOnWarnings),
          ),
        if (widget.state.isEmpty)
          Expanded(child: _Empty(onRefresh: widget.onRefresh))
        else
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => widget.onRefresh?.call(),
              child: ListView.separated(
                // Always scrollable, so pull-to-refresh works with one short row.
                physics: const AlwaysScrollableScrollPhysics(),
                // **Builds well past the fold, so a tapped notification can
                // actually reach its row.** `Scrollable.ensureVisible` needs the
                // target to exist, and the default cache extent leaves a row a
                // couple of positions down unbuilt — so the highlight silently
                // did nothing in precisely the case it was added for.
                //
                // The cost is laying out a few extra short rows; this list is one
                // family, not a feed. Phase 7 owns the multi-person layout and
                // should replace this with fixed extents or a positioned list if
                // the number ever justifies it.
                scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                padding: const EdgeInsets.symmetric(vertical: 8),
                // Reconciled rows first, then the links this pass could not
                // reconcile at all. They are **in** the list rather than omitted:
                // an omitted link is invisible, and with one link that made the
                // screen claim the reader was looking after nobody.
                itemCount:
                    widget.state.people.length +
                    widget.state.unreconciled.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (i >= widget.state.people.length) {
                    return _FailedRow(
                      link: widget
                          .state
                          .unreconciled[i - widget.state.people.length],
                      onRetry: widget.onRefresh,
                    );
                  }
                  final person = widget.state.people[i];
                  final highlighted = person.link.id == _highlighted;
                  return _PersonRow(
                    // Only the highlighted row carries the key — a GlobalKey must
                    // be unique in the tree, and it is what `ensureVisible` and
                    // the announcement both resolve through.
                    key: highlighted ? _highlightedRow : null,
                    person: person,
                    watcherZone: widget.state.watcherZone,
                    today: widget.state.today,
                    uses24Hour: widget.state.uses24Hour,
                    highlighted: highlighted,
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// *"This phone will not warn you about anyone."*
///
/// The watcher-side twin of the Tap screen's `_NotificationsOffBanner`, and the
/// same shape deliberately: says what stops working, and offers the action.
/// *"Ask a family member"* is the dead-end wording and is only honest once there
/// is nothing left to press — on this screen the reader **is** the family
/// member, so it would never be honest here.
///
/// It appears while they are looking at the app, which is the one moment this
/// state can still be communicated: every other channel for saying it is the
/// channel that is switched off.
class _WarningsOffBanner extends StatelessWidget {
  const _WarningsOffBanner({required this.onTurnOn});

  final Future<void> Function()? onTurnOn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            WatcherCopy.warningsOff,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          TextButton(
            onPressed: onTurnOn == null ? null : () => onTurnOn!(),
            style: TextButton.styleFrom(
              // The 48dp floor, which applies to everything that is not the Tap
              // screen's primary target.
              minimumSize: const Size(88, 48),
              // `onErrorContainer` rather than the default `primary`, which is
              // measured against `surface` and not against the `errorContainer`
              // painted behind it — 2.33:1 in light, 2.31:1 in dark, against a
              // 4.5 floor. See the Tap screen's twin for the full reasoning;
              // both banners had it and both are asserted now.
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
            child: const Text(WatcherCopy.warningsOffAction),
          ),
        ],
      ),
    );
  }
}

/// A link the reconcile threw on.
///
/// Deliberately shaped like the lost-access row — a fault about **us**, naming
/// the person, offering the honest next step — because that is the same kind of
/// thing it is. What it must never do is imply anything about her: the app does
/// not know whether she checked in, only that it could not find out.
///
/// It carries no *"this phone last checked"* line for the same reason it
/// carries no status: the cache read is one of the things that may have thrown,
/// so there is no value here the row can vouch for.
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.link, this.onRetry});

  final Link link;

  /// Retries the reconcile. **A button, because pull-to-refresh was the only
  /// route** and `guidelines.md`'s accessibility floor forbids a drag as the
  /// only way to reach an action — it is also the gesture TalkBack is least
  /// able to perform, on the row whose whole content is a fault.
  ///
  /// The whole-screen `_Failed` has had this control since it was written; the
  /// per-row failure, which is the far more common one, had nothing.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = [
      WatcherCopy.couldNotCheckOn(link.watchedName),
      WatcherCopy.couldNotCheckRemedy,
    ];

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Semantics(
        label: WatcherCopy.rowLabel(link.watchedName, lines.join(' ')),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(link.watchedName, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              ...lines.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    line,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // **Outside the `Semantics`/`ExcludeSemantics` pair above, deliberately.**
    // That pair collapses the row's text into one utterance, which is right for
    // text and fatal for a control: a button inside `ExcludeSemantics` is
    // invisible to the screen reader it was added for. It gets its own node.
    if (onRetry == null) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 4),
          child: TextButton(
            onPressed: () => onRetry!(),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text(WatcherCopy.retry),
          ),
        ),
      ],
    );
  }
}

/// The row's away action — the **other side** of "away set from either side".
///
/// §12: *"anyone in the group can set, extend or cancel it. No approval."* This
/// is the surface that makes the watcher's half reachable by a person rather
/// than only by an API call, which `OPEN-QUESTIONS.md` #11 names in as many
/// words.
///
/// **One control, two labels**, matching the Tap screen's: mark away, or end an
/// away period that is in force. Cancellation is symmetric with activation
/// (§12) — the same document, the same fan-out, no separate path.
///
/// Both labels **name the person**, because this row is one of several and a
/// bare *"Mark away"* is ambiguous about whom to a screen-reader user swiping
/// down the list. The row itself is `ExcludeSemantics`-wrapped into one
/// utterance, so this button is deliberately outside that: it is a separate
/// stop with its own label, which is what makes it reachable at all.
class _AwayRowAction extends ConsumerStatefulWidget {
  const _AwayRowAction({required this.person});

  final WatchedPersonState person;

  @override
  ConsumerState<_AwayRowAction> createState() => _AwayRowActionState();
}

class _AwayRowActionState extends ConsumerState<_AwayRowAction> {
  bool _busy = false;
  String? _message;

  /// Runs one away write and reports what came back.
  ///
  /// [saved] is what this row says when the write **succeeded**, and it is a
  /// parameter because only the caller knows which of the two actions ran.
  /// `AwayCopy.saved` is deliberately null — that is the Tap screen's decision,
  /// where the away line is the confirmation and is still there tomorrow. This
  /// row has no such line, so the owner split the two surfaces on 2026-09-01.
  Future<void> _run(
    Future<AwayOutcome> Function() action, {
    required String saved,
  }) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // Guarded for the same reason as the Tap screen's twin: an unguarded
    // throw leaves `_busy` true and the control dead for the session, with
    // nothing said.
    AwayOutcome outcome;
    try {
      outcome = await action();
    } on Object {
      outcome = const AwayOutcome.refused(AwayRefusal.serverFault);
    }
    if (!mounted) return;
    // The success case is this surface's own; everything else — queued, and the
    // four refusals — is the shared exhaustive switch, so a refusal added later
    // still cannot default into somebody else's sentence.
    final message = outcome is AwaySet ? saved : AwayCopy.awayMessageFor(outcome);
    setState(() {
      _busy = false;
      _message = message;
    });
    // **Spoken, because nothing re-reads a changed widget.** On this row the
    // outcome is the ONLY feedback — a blind watcher presses *"End Mum's away
    // period"*, the write is refused, and otherwise they hear nothing at all.
    if (message != null) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    }
  }

  /// Confirms before **ending** a period, and only here.
  ///
  /// Owner decision, 2026-09-01. The Tap screen's *"I'm not away"* has no
  /// confirmation on the argument that the failure is loud and setting it again
  /// is two taps. Neither half holds on this row: ending **truncates**, so a
  /// mis-tap on day 3 of a 14-day stay destroys the remaining 11 days, and what
  /// is loud is a warning waking the rest of the family about somebody who is
  /// genuinely away. The asymmetry is the decision, not an oversight.
  ///
  /// **`scrollable: true`**, because this is the shape `screens.md` records the
  /// Phase 5 gate measuring: a dialog whose content overflows at the largest
  /// font scale is **clipped in release**, silently and with no overflow
  /// stripe. A title, three lines of body and two 48dp actions do not fit a
  /// 320×480 phone at scale 2.0.
  Future<bool> _confirmEnd(String watchedName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(WatcherCopy.endAwayConfirmTitle(watchedName)),
        content: Text(WatcherCopy.endAwayConfirmBody(watchedName)),
        actions: [
          TextButton(
            key: const Key('watcher-away-end-cancel'),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            onPressed: () => Navigator.of(context).pop(false),
            // The picker's approved dismissal, verbatim. A dismissal is a
            // choice rather than a fault, and it says nothing afterwards.
            child: const Text(AwayCopy.cancel),
          ),
          TextButton(
            key: const Key('watcher-away-end-confirm'),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(WatcherCopy.endAwayConfirmAction),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _endAway(AwayPeriod away) async {
    final person = widget.person;
    if (!await _confirmEnd(person.name)) return;
    if (!mounted) return;
    await _run(
      () => ref
          .read(watcherStateProvider.notifier)
          .endAway(
            watchedUid: person.link.watchedUid,
            existing: away,
            watchedToday: person.watchedToday,
          ),
      saved: WatcherCopy.awayEndedSaved(person.name),
    );
  }

  Future<void> _setAway() async {
    final person = widget.person;
    final lastDay = await Navigator.of(context).push<DayKey>(
      MaterialPageRoute(
        builder: (_) => AwayPickerScreen(
          // **Her today, not the reader's.** §11: an away period's days are
          // labels in the watched person's zone, and a watcher in London
          // marking somebody in Sydney away must bound the picker by the day
          // *she* is living, or the first and last days are off by one.
          today: person.watchedToday,
          initialLastDay: person.cache.away?.period.through,
          // **Whose period this is.** Shared with the Tap screen, this title
          // said *"the last day you are away"* to a watcher choosing dates for
          // somebody else — found on a device 2026-09-01, and invisible to a
          // widget test because both surfaces rendered the string correctly.
          personName: person.name,
        ),
      ),
    );
    if (lastDay == null) return;
    if (!mounted) return;
    await _run(
      () => ref
          .read(watcherStateProvider.notifier)
          .setAway(
            watchedUid: person.link.watchedUid,
            lastDay: lastDay,
            watchedToday: person.watchedToday,
            existing: person.cache.away?.period,
          ),
      saved: WatcherCopy.awaySetSaved(person.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final person = widget.person;
    final away = person.cache.away?.period;
    final isAway = person.isAwayToday;
    final message = _message;

    // A revoked link can neither read nor write this document — §8 gates the
    // away write on `isSelf(uid) || hasAcceptedLink(uid)` — so offering the
    // control would be offering an action that is refused by design. The row
    // above already says the link has ended.
    if (person.rowKind == WatchedRowKind.revoked) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(
          key: Key('watcher-away-${person.link.id}'),
          onPressed: _busy || (isAway && away == null)
              ? null
              : () => isAway ? _endAway(away!) : _setAway(),
          style: TextButton.styleFrom(
            minimumSize: const Size(88, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: Text(
            isAway
                ? WatcherCopy.endAwayAction(person.name)
                : WatcherCopy.markAwayAction(person.name),
          ),
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Text(
              message,
              key: Key('watcher-away-message-${person.link.id}'),
              // Not error-coloured: only one of the four things this says is a
              // refusal, and `AwayCopy.queued` is not a failure at all.
              style: theme.textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.person,
    required this.watcherZone,
    required this.today,
    required this.uses24Hour,
    required this.highlighted,
  });

  final WatchedPersonState person;

  /// **The reader's own zone.** Every time on this row is a claim about *this
  /// device*, so it is rendered where the person reading it lives — not in the
  /// watched person's zone, which is a different question and was what the row
  /// used before.
  final tz.Location watcherZone;

  /// Today in the reader's own zone, so an instant older than a week is dated
  /// rather than rendered as a bare weekday. On a revoked or refused link
  /// `lastReconcileAt` never advances again, so *"Tuesday 10:14"* would
  /// otherwise stand unchanged into week twelve while reading as this week.
  final DayKey today;

  /// From [WatcherState], never from `MediaQuery` — one fact, one source. See
  /// [WatcherState.uses24Hour].
  final bool uses24Hour;

  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Off the state, so the row cannot disagree with the notification the same
    // reconcile posted — see [WatcherState.uses24Hour].
    final status = _status();

    return Container(
      color: highlighted ? theme.colorScheme.surfaceContainerHighest : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: WatcherCopy.rowLabel(person.name, status.spoken),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(person.name, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  // The claim itself. Colour is never the only signal — every
                  // status carries its own words — so this only reinforces them.
                  ...status.lines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        line,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: status.isBad ? theme.colorScheme.error : null,
                        ),
                      ),
                    ),
                  ),
                  // **Never coloured, on any row.**
                  //
                  // Painting the whole row `error` swept this line up with the
                  // warning and collapsed the very distinction it was added to
                  // make: *"No check-in from Mum yesterday"* is a claim about
                  // **her**, and *"This phone last checked Tuesday 10:14"* is a
                  // fact about **this device's own effort**. In red beneath a
                  // warning it reads as part of the alarm — as though the last
                  // check were itself the bad news — and a reader at 3am has no way
                  // to separate them.
                  if (status.footer != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        status.footer!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // **Outside the row's single utterance, deliberately.** The row is
          // one stop for a screen reader; a control folded into it would be
          // unreachable, and `guidelines.md` requires every interactive
          // element to be labelled and reachable.
          _AwayRowAction(person: person),
        ],
      ),
    );
  }

  /// Renders the row's claim from [person], and reads no device fact of its own.
  ///
  /// [uses24Hour] arrives from [WatcherState] — **not** from `MediaQuery`, which
  /// is what this comment argued for until the drift it caused was measured. This
  /// side does have a `BuildContext` and could read the live setting, and that is
  /// precisely the defect: the row and the notification posted by the *same*
  /// reconcile then had two sources for one fact and could disagree about the
  /// same instant. One source, cached by `ClockService` on launch and on resume,
  /// is what both surfaces now read.
  _RowStatus _status() => _statusFor(
    person,
    watcherZone: watcherZone,
    today: today,
    uses24Hour: uses24Hour,
  );
}

/// The row's rendered claim, as a value, so **the row and the announcement are
/// the same sentence**.
///
/// Free-standing rather than a method on [_PersonRow] because
/// `_WatcherBodyState._announceChanged` needs the identical string: the approved
/// OK → warning announcement is the warning body **verbatim**, and a second
/// place computing "what the row says" is a second chance to say something the
/// row does not. That is the argument [WatchedPersonState.rowKind] was extracted
/// for, one layer out — and the widget's own comment below already records what
/// it cost when the precedence lived in two places.
_RowStatus _statusFor(
  WatchedPersonState person, {
  required tz.Location watcherZone,
  required DayKey today,
  required bool uses24Hour,
}) {
  final cache = person.cache;

  // **The precedence is [WatchedPersonState.rowKind]'s, not this widget's.**
  // It is §10's step order — revoked, then lost access, then a standing
  // warning, then "Everything OK" — and it was written out here AND inside
  // `checkedInSince`, with nothing keeping the two in step. `screens.md`
  // already commits Phase 6 to adding a branch above "Everything OK"; if that
  // branch landed above the warning case, the announcement and the row would
  // have disagreed silently, for the one reader who cannot see the row to
  // check. Switching on the shared value makes that impossible and makes a
  // new state a compile error here rather than a fall-through.
  switch (person.rowKind) {
    // A revoked link outranks everything, including lost access.
    //
    // **It fell through every branch below and rendered "Everything OK".** For
    // a link that is armed with no alarms, will never warn, and cannot read
    // anything, that is the flattest false all-clear this screen can produce.
    //
    // Above the access row rather than below it, because a revoked link makes
    // every later read refused by definition — so the access branch would fire
    // too, and send the reader off to sign in again and repair a permission
    // fault that does not exist. The link ended; there is nothing to fix.
    case WatchedRowKind.revoked:
      return _RowStatus(
        // **No "this phone last checked" line here**, alone among the row
        // states. That line exists to distinguish *working* from *stopped* for
        // a force-stopped watcher whose rows all still read "Everything OK".
        // On a revoked link nothing is working by design and the first
        // sentence has already said so — what the line would add is the
        // suggestion that this phone checks on her periodically and last
        // managed it on Tuesday. Worse, a revoked link refuses every read
        // forever, so `lastReconcileAt` never advances and it would say the
        // same Tuesday in week twelve.
        lines: [
          WatcherCopy.linkEnded(person.name),
          WatcherCopy.accessLostConsequence(person.name),
        ],
        // Not an error. A settled state, not bad news about her — "quiet
        // confirm, loud miss" keeps alarm styling for a miss. The words carry
        // it, which they have to in any case: colour is never the only signal.
        isBad: false,
      );

    // Lost access next. It is a fault in THIS app rather than a claim about
    // her, and it is the state the notification routes here to explain — so
    // it outranks the rest of the row for the same reason ADR-0004 puts
    // refusal above the away branch.
    case WatchedRowKind.accessLost:
      return _RowStatus(
        lines: [
          WatcherCopy.accessLostLabel(person.name),
          WatcherCopy.accessLostConsequence(person.name),
          WatcherCopy.accessLostRemedy(cache.accessLostCause),
        ],
        footer: _lastChecked(cache, watcherZone, today, uses24Hour),
        isBad: true,
      );

    case WatchedRowKind.warning:
      return _RowStatus(
        lines: [
          NotificationCopy.warningBody(
            // Non-null by construction: `rowKind` answers `warning` only when
            // `standingWarning` is a real outcome.
            outcome: person.standingWarning!,
            watchedName: person.name,
            day: person.decision.day,
            away: person.decision.away,
            unverifiedSince: person.decision.unverifiedSince,
            lastConfirmedDay: cache.lastConfirmedDay,
            watcherZone: watcherZone,
            today: today,
            uses24Hour: uses24Hour,
          ),
        ],
        footer: _lastChecked(cache, watcherZone, today, uses24Hour),
        isBad: true,
      );

    // Phase 6, and `screens.md` named this position back in Phase 3: **above
    // "Everything OK"**, which is where a verified away period used to fall.
    //
    // It lands together with the attribution that makes it honest. An
    // unattributed *"Away until Sat 22 Aug"* is exactly the away state
    // `screens.md` forbids — every surface showing an away period names who
    // set it, because that is §17's recorded mitigation for *one watcher
    // silences the whole family*, and a state change nobody can attribute is
    // a state change nobody trusts.
    case WatchedRowKind.away:
      final away = cache.away;
      final setByName = away?.setByName;
      return _RowStatus(
        lines: [
          // Non-null by construction: `rowKind` answers `away` only when the
          // cache holds a period that covers her today.
          setByName == null
              // **The HONOURED `through`.** `isAwayToday` decides through
              // `covers`, which clamps to the sanity bound — so the raw value
              // would name a date the app stops honouring, on a row that goes
              // quiet the same day. `WarningPolicy.warningBody` sets the
              // precedent and gives the reason.
              ? WatcherCopy.awayUntil(AwayCopy.shortDate(
                  away!.period.clampedToSanityBound().through))
              : WatcherCopy.awayUntilBy(
                  AwayCopy.shortDate(
                      away!.period.clampedToSanityBound().through),
                  setByName,
                ),
        ],
        footer: _lastChecked(cache, watcherZone, today, uses24Hour),
        // **Not bad news.** Nobody is expected to tap, so nothing is wrong —
        // "quiet confirm, loud miss" keeps alarm styling for a miss, and
        // colour is never the only signal in either direction. The same
        // decision the revoked row makes for the same reason.
        isBad: false,
      );

    case WatchedRowKind.ok:
      return _RowStatus(
        lines: [
          WatcherCopy.everythingOk,
          cache.lastConfirmedDay == null
              ? WatcherCopy.neverSeen
              : WatcherCopy.lastSeen(
                  NotificationCopy.dayLabel(cache.lastConfirmedDay!),
                ),
        ],
        // **In `footer`, like every other branch.** It rendered identically
        // while it sat in `lines`, because this row is `isBad: false` and
        // nothing tints an unemphasised row — so the "never error-coloured, on
        // any row" rule held here **by coincidence rather than by structure**.
        //
        // `screens.md` already commits Phase 6 to adding an away branch "above
        // Everything OK", and whoever writes it will copy its nearest
        // neighbour. Copied from a branch that puts this line in `lines`, with
        // `isBad: true`, it paints *"This phone last checked Tuesday 10:14."*
        // red — collapsing the exact distinction the footer was extracted to
        // protect: the warning is a claim about **her**, this is a fact about
        // **this device's own effort**.
        //
        // `spoken` is `[...lines, ?footer].join(' ')`, so the utterance is
        // byte-identical either way.
        footer: _lastChecked(cache, watcherZone, today, uses24Hour),
        isBad: false,
      );
  }
}

/// When this phone last managed a successful read.
///
/// On **every** row, healthy or not, and that is the point. A watcher whose
/// app was force-stopped goes deaf with the row still reading *"Everything
/// OK"* — which is true of the last thing this phone read and says nothing
/// about whether it has read anything since. This is the only surface that
/// distinguishes *working* from *stopped* before §13's panel lands in Phase 7.
String _lastChecked(
  WatcherCache cache,
  tz.Location watcherZone,
  DayKey today,
  bool uses24Hour,
) => cache.lastReconcileAt == null
    ? WatcherCopy.neverChecked
    : WatcherCopy.lastChecked(
        NotificationCopy.momentLabel(
          cache.lastReconcileAt!,
          watcherZone,
          today,
          uses24Hour,
        ),
      );

class _RowStatus {
  const _RowStatus({required this.lines, required this.isBad, this.footer});

  /// The claim — what is true about this person, or about the app's access to
  /// them. Emphasised when [isBad].
  final List<String> lines;

  /// A fact about **this device**, rendered as ordinary text whatever the rows
  /// above it say. Null **only** on the revoked row, which has nothing to report
  /// about an effort it is no longer making — every other row carries it,
  /// including *"Everything OK"*, because the failure it exposes is a
  /// force-stopped watcher whose rows all still read exactly that.
  final String? footer;

  final bool isBad;

  /// TalkBack gets one utterance, so the footer is part of it — the visual
  /// distinction is carried by colour, which a screen reader does not see.
  String get spoken => [...lines, ?footer].join(' ');
}
