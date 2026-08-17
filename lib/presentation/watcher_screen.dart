import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../application/watcher_reconcile_service.dart';
import '../copy/notification_copy.dart';
import '../copy/tap_copy.dart';
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
        data: (watcher) => watcher.isEmpty
            ? const _Empty()
            : _People(people: watcher.people),
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
              Text(TapCopy.couldNotStart, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text(TapCopy.retry),
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

class _People extends ConsumerStatefulWidget {
  const _People({required this.people});

  final List<WatchedPersonState> people;

  @override
  ConsumerState<_People> createState() => _PeopleState();
}

class _PeopleState extends ConsumerState<_People> {
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
    final index = widget.people.indexWhere((p) => p.link.id == linkId);
    if (index < 0) return;
    NotificationRouter.instance.consume();
    setState(() => _highlighted = linkId);
  }

  String? _highlighted;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () => ref.read(watcherStateProvider.notifier).refresh(),
        child: ListView.separated(
          // Always scrollable, so pull-to-refresh works with one short row.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: widget.people.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final person = widget.people[i];
            return _PersonRow(
              person: person,
              highlighted: person.link.id == _highlighted,
            );
          },
        ),
      );
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, required this.highlighted});

  final WatchedPersonState person;
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

    // Lost access first. It is a fault in THIS app rather than a claim about
    // her, and it is the state the notification routes here to explain — so it
    // outranks the rest of the row for the same reason ADR-0004 puts refusal
    // above the away branch.
    if (person.hasLostAccess) {
      return _RowStatus(
        lines: [
          WatcherCopy.accessLostLabel(person.name),
          WatcherCopy.accessLostConsequence(person.name),
          WatcherCopy.accessLostRemedy(cache.accessLostCause),
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
            watcherZone: person.link.watchedZone,
          ),
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
      ],
      isBad: false,
    );
  }
}

class _RowStatus {
  const _RowStatus({required this.lines, required this.isBad});

  final List<String> lines;
  final bool isBad;

  String get spoken => lines.join(' ');
}
