import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../application/watcher_reconcile_service.dart';
import '../copy/notification_copy.dart';
import '../copy/watcher_copy.dart';
import '../domain/domain.dart';
import '../platform/notification_router.dart';

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

  @override
  ConsumerState<WatcherScreen> createState() => _WatcherScreenState();
}

class _WatcherScreenState extends ConsumerState<WatcherScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
      appBar: AppBar(title: const Text(WatcherCopy.title)),
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
        error: (_, _) => _Failed(
          onRetry: () => ref.invalidate(watcherStateProvider),
        ),
        data: (watcher) => WatcherBody(
          state: watcher,
          onRefresh: ref.read(watcherStateProvider.notifier).refresh,
          onTurnOnWarnings:
              ref.read(watcherStateProvider.notifier).requestNotifications,
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
                child: const Text(WatcherCopy.retry),
              ),
            ],
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            WatcherCopy.nobody,
            textAlign: TextAlign.center,
            // Ordinary secondary text, never a warning colour. Styling an empty
            // state as an alarm makes it a status message about other people's
            // behaviour, which is the thing this app deliberately does not do.
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
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

  void _onTapped() {
    final linkId = NotificationRouter.instance.tappedLink.value;
    if (linkId == null || !mounted) return;
    final index = widget.state.people.indexWhere((p) => p.link.id == linkId);
    if (index < 0) return;
    NotificationRouter.instance.consume();
    setState(() => _highlighted = linkId);
  }

  String? _highlighted;

  @override
  Widget build(BuildContext context) {
    if (widget.state.isEmpty) return const _Empty();
    return Column(
      children: [
        // Above the list, because when it is showing it is the most important
        // thing on the screen: the rows describe what is true, this says the
        // reader will not be told about it again.
        if (widget.state.warningsSilenced)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _WarningsOffBanner(onTurnOn: widget.onTurnOnWarnings),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => widget.onRefresh?.call(),
            child: ListView.separated(
              // Always scrollable, so pull-to-refresh works with one short row.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.state.people.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final person = widget.state.people[i];
                return _PersonRow(
                  person: person,
                  watcherZone: widget.state.watcherZone,
                  today: widget.state.today,
                  highlighted: person.link.id == _highlighted,
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
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
          TextButton(
            onPressed: onTurnOn == null ? null : () => onTurnOn!(),
            // The 48dp floor, which applies to everything that is not the Tap
            // screen's primary target.
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text(WatcherCopy.warningsOffAction),
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.person,
    required this.watcherZone,
    required this.today,
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

  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status(context);

    return Container(
      color: highlighted ? theme.colorScheme.surfaceContainerHighest : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Semantics(
        label: WatcherCopy.rowLabel(person.name, status.spoken),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(person.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              ...status.lines.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    line,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      // Colour is never the only signal — every status carries
                      // its own words. This only reinforces what the text says.
                      color: status.isBad ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _RowStatus _status(BuildContext context) {
    final cache = person.cache;

    // A revoked link outranks everything, including lost access — §10 step 1
    // makes a non-accepted link the first branch of the whole decision, and this
    // is that ordering on the screen.
    //
    // **It fell through every branch below and rendered "Everything OK".** For a
    // link that is armed with no alarms, will never warn, and cannot read
    // anything, that is the flattest false all-clear this screen can produce.
    //
    // Above the access row rather than below it, because a revoked link makes
    // every later read refused by definition — so the access branch would fire
    // too, and send the reader off to sign in again and repair a permission
    // fault that does not exist. The link ended; there is nothing to fix.
    if (person.link.status == LinkStatus.revoked) {
      return _RowStatus(
        // **No "this phone last checked" line here**, alone among the row
        // states. That line exists to distinguish *working* from *stopped* for a
        // force-stopped watcher whose rows all still read "Everything OK". On a
        // revoked link nothing is working by design and the first sentence has
        // already said so — what the line would add is the suggestion that this
        // phone checks on her periodically and last managed it on Tuesday.
        // Worse, a revoked link refuses every read forever, so
        // `lastReconcileAt` never advances and it would say the same Tuesday in
        // week twelve.
        lines: [
          WatcherCopy.linkEnded(person.name),
          WatcherCopy.accessLostConsequence(person.name),
        ],
        // Not an error. A settled state, not bad news about her — "quiet
        // confirm, loud miss" keeps alarm styling for a miss. The words carry
        // it, which they have to in any case: colour is never the only signal.
        isBad: false,
      );
    }

    // Lost access next. It is a fault in THIS app rather than a claim about
    // her, and it is the state the notification routes here to explain — so it
    // outranks the rest of the row for the same reason ADR-0004 puts refusal
    // above the away branch.
    if (person.hasLostAccess) {
      return _RowStatus(
        lines: [
          WatcherCopy.accessLostLabel(person.name),
          WatcherCopy.accessLostConsequence(person.name),
          WatcherCopy.accessLostRemedy(cache.accessLostCause),
          _lastChecked(cache),
        ],
        isBad: true,
      );
    }

    final standing = person.standingWarning;
    if (standing != null && standing != WarningOutcome.silent) {
      return _RowStatus(
        lines: [
          NotificationCopy.warningBody(
            outcome: standing,
            watchedName: person.name,
            day: person.decision.day,
            away: person.decision.away,
            unverifiedSince: person.decision.unverifiedSince,
            lastConfirmedDay: cache.lastConfirmedDay,
            watcherZone: watcherZone,
            today: today,
          ),
          _lastChecked(cache),
        ],
        isBad: true,
      );
    }

    return _RowStatus(
      lines: [
        WatcherCopy.everythingOk,
        cache.lastConfirmedDay == null
            ? WatcherCopy.neverSeen
            : WatcherCopy.lastSeen(
                NotificationCopy.dayLabel(cache.lastConfirmedDay!)),
        _lastChecked(cache),
      ],
      isBad: false,
    );
  }

  /// When this phone last managed a successful read.
  ///
  /// On **every** row, healthy or not, and that is the point. A watcher whose
  /// app was force-stopped goes deaf with the row still reading *"Everything
  /// OK"* — which is true of the last thing this phone read and says nothing
  /// about whether it has read anything since. This is the only surface that
  /// distinguishes *working* from *stopped* before §13's panel lands in Phase 7.
  String _lastChecked(WatcherCache cache) => cache.lastReconcileAt == null
      ? WatcherCopy.neverChecked
      : WatcherCopy.lastChecked(
          NotificationCopy.momentLabel(cache.lastReconcileAt!, watcherZone, today));
}

class _RowStatus {
  const _RowStatus({required this.lines, required this.isBad});

  final List<String> lines;
  final bool isBad;

  String get spoken => lines.join(' ');
}
