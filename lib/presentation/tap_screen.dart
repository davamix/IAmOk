import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../application/providers.dart';
import '../application/watched_reconcile_service.dart';
import '../copy/tap_copy.dart';
import '../domain/domain.dart';
import 'debug_harness.dart';

/// The watched person's main screen, and **the only screen they need**.
///
/// The rules this screen is built to, from `docs/ui-ux/guidelines.md`:
///
/// - **One screen, one action.** No tabs, no nav bar, no settings gear
///   competing for attention. The Away control is present but visibly secondary
///   and **not adjacent** to the tap target, so a mis-tap cannot mark someone
///   away.
/// - **The tap target is enormous and does not move.** Muscle memory is the
///   feature; a layout that reflows is a bug. See [TapBody] for how that is
///   achieved and for the two ways it was got wrong first.
/// - **Confirm the tap for the rest of the day.** The write is idempotent, so
///   this is for the person, not the data.
/// - Font scale, contrast and semantics are floors rather than goals.
class TapScreen extends ConsumerStatefulWidget {
  const TapScreen({super.key});

  @override
  ConsumerState<TapScreen> createState() => _TapScreenState();
}

class _TapScreenState extends ConsumerState<TapScreen>
    with WidgetsBindingObserver {
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // The device's zone is refreshed from the plugin here and cached to
      // LocalStore, which is the only way a bare alarm isolate ever learns it
      // (ADR-0002 decision 2).
      await ref.read(watchedStateProvider.notifier).refreshDeviceZone();
      // First run on API 33+ has POST_NOTIFICATIONS denied by default. Ask
      // once, rather than showing her a red banner about a permission the app
      // never requested — and never firing a reminder, which is this phase's
      // own exit criterion.
      await ref.read(watchedStateProvider.notifier).ensureNotificationsAsked();
      _scheduleMidnightRefresh();
    });
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A resume is a full reconcile, not a redraw. Android takes permissions
    // back from apps nobody opens (§13), and the device zone can change while
    // backgrounded.
    if (state == AppLifecycleState.resumed) {
      ref.read(watchedStateProvider.notifier).refreshDeviceZone();
      _scheduleMidnightRefresh();
    }
  }

  /// Re-reads the screen when the **local day** rolls over.
  ///
  /// Without this the target re-enables only on a resume. A phone left on the
  /// charger with the app in the foreground across midnight would still show a
  /// disabled target and *"You already tapped today, at 09:14"* on a day she
  /// has not tapped — she reads it, believes she is done, and her family is
  /// warned in the morning. That is the confirmation line causing exactly the
  /// harm it exists to prevent.
  ///
  /// Computed from the injected clock in the device's zone, so a forced date in
  /// the debug harness is honoured here too.
  void _scheduleMidnightRefresh() {
    _midnight?.cancel();
    final services = ref.read(appServicesProvider);
    final now = services.clock.now();
    final zone = ref.read(watchedStateProvider).value?.zone;
    if (zone == null) return;

    final local = tz.TZDateTime.from(now, zone);
    final nextMidnight = DayKey.fromInstant(now, zone).next.startOfDay(zone);
    final wait = nextMidnight.difference(local);

    _midnight = Timer(
      // A minute past, so a clock a few seconds fast cannot land on the day it
      // just left and reschedule into a zero-length wait.
      wait + const Duration(minutes: 1),
      () {
        ref.read(watchedStateProvider.notifier).refresh();
        _scheduleMidnightRefresh();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(watchedStateProvider);

    return Scaffold(
      body: SafeArea(
        child: switch (state) {
          AsyncData(:final value) => TapBody(state: value),
          AsyncError(:final error) => _Failure(error: error),
          _ => Semantics(
              label: TapCopy.loadingLabel,
              child: const Center(child: CircularProgressIndicator()),
            ),
        },
      ),
    );
  }
}

@visibleForTesting
class TapBody extends ConsumerWidget {
  const TapBody({required this.state, super.key});

  final WatchedState state;

  /// The share of the screen reserved for everything below the target.
  ///
  /// See [build] — this is the number that makes overlap impossible rather than
  /// merely unlikely.
  static const double bottomBandFraction = 0.36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **The target is centred in the space ABOVE a reserved band, and both
    // halves of that matter.**
    //
    // A plain Column put the text in the same flex as the target, so the
    // target's position depended on how tall the text was: it shifted upward
    // the moment "You already tapped today" appeared, and again when a third
    // watcher was added. `docs/ui-ux/guidelines.md` is explicit that the target
    // "does not move — muscle memory is the feature; a layout that reflows is a
    // bug", and a Column breaks that every day at the moment of the tap.
    //
    // A bare Stack fixed the movement and introduced overlap. With the bottom
    // cluster free to grow upward over a target sized from the shortest screen
    // edge, at the largest system font scale — set by exactly the person this
    // app is for — the text painted *on top of* the circle, unreadable, and
    // absorbed her taps because a paragraph hit-tests. Landscape did the same
    // at default scale, because the shortest side is then the height.
    //
    // Reserving the band gives both properties at once: the target's centre is
    // a pure function of the screen, and the two regions cannot meet.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bandHeight = constraints.maxHeight * bottomBandFraction;
        final targetArea = constraints.maxHeight - bandHeight;

        return Column(
          children: [
            SizedBox(
              height: targetArea,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: TapTarget(
                        enabled: !state.hasTappedToday,
                        tappedAtLabel: _tappedAt(context),
                        // Sized against the region it actually occupies, not
                        // the whole screen, so it cannot grow into the band.
                        maxDiameter: targetArea,
                        onTap: () =>
                            ref.read(watchedStateProvider.notifier).tap(),
                      ),
                    ),
                  ),
                  const Positioned(top: 0, right: 0, child: DebugHarnessButton()),
                ],
              ),
            ),
            SizedBox(
              height: bandHeight,
              child: _BottomBand(state: state, tappedAt: _tappedAt(context)),
            ),
          ],
        );
      },
    );
  }

  /// The tap time, in the zone the tap was **made** in.
  ///
  /// `CheckIn.timezone` records that zone for precisely this reason. Using the
  /// device's current zone — `.toLocal()` — is the implicit-zone read the
  /// domain's purity guard bans one layer down, and after a flight it renders a
  /// wall-clock time she never saw, on the one line whose whole job is to be
  /// believed.
  String? _tappedAt(BuildContext context) {
    final checkIn = state.todayCheckIn;
    if (checkIn == null) return null;
    final zone = TimeZones.tryLocation(checkIn.timezone);
    final at = zone == null
        ? checkIn.deviceTappedAt
        : tz.TZDateTime.from(checkIn.deviceTappedAt, zone);
    return TimeOfDay.fromDateTime(at).format(context);
  }
}

class _BottomBand extends StatelessWidget {
  const _BottomBand({required this.state, required this.tappedAt});

  final WatchedState state;
  final String? tappedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Scrollable inside its own band. At the largest font scale the content can
    // exceed the reserved height; scrolling is how that stays reachable without
    // ever encroaching on the target.
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // In the reserved band, not floating over the target area.
            // Positioned at the top of the Stack it grew *downward into the
            // circle* at the largest font scale — unreadable, and absorbing her
            // taps, because a paragraph hit-tests true. Here it is directly
            // beneath the target, so it is still the first thing under her
            // eyes, and the band is scrollable so it can never encroach.
            if (!state.notificationsEnabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: _NotificationsOffBanner(),
              ),
            if (state.tapFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  TapCopy.tapFailed,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            if (tappedAt != null)
              Text(
                TapCopy.alreadyTapped(tappedAt!),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            const SizedBox(height: 12),
            _AudienceLine(state: state),

            // Away is present, secondary, and **not adjacent** to the tap
            // target — a full text block sits between them, so a mis-tap on the
            // primary action cannot mark someone away. Inert until Phase 6; here
            // so the layout it must live in is settled while the screen is
            // simple.
            const SizedBox(height: 20),
            const _AwayAction(),
          ],
        ),
      ),
    );
  }
}

/// The one thing to do.
///
/// Sized from the region it occupies rather than a fixed dp value, so it stays
/// enormous on a small phone, does not overflow a large one, and cannot grow
/// into the text band below it. Far beyond the 48dp Material minimum, which is
/// the floor for *everything else* on this screen rather than the target here.
@visibleForTesting
class TapTarget extends StatelessWidget {
  const TapTarget({
    required this.enabled,
    required this.onTap,
    required this.maxDiameter,
    this.tappedAtLabel,
    super.key,
  });

  final bool enabled;
  final VoidCallback onTap;
  final double maxDiameter;

  /// The tap time, for the spoken label. Null before today's tap.
  final String? tappedAtLabel;

  /// Found by tests, and stable across both states — the target is one widget
  /// that changes appearance, never two that swap places.
  static const Key targetKey = Key('tap-target');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final diameter = [
      shortestSide * 0.62,
      maxDiameter * 0.9,
    ].reduce((a, b) => a < b ? a : b);

    // `Semantics(onTap:)` plus `excludeSemantics`, NOT a Semantics wrapping an
    // ExcludeSemantics. The latter strips the whole subtree including the
    // InkWell's SemanticsAction.tap, leaving a node that is labelled and flagged
    // as an enabled button but carries no tap action — so TalkBack announces the
    // app's one action and then cannot activate it. A label-based test cannot
    // see the difference, which is why the test now asserts `hasTapAction`.
    return Semantics(
      key: targetKey,
      button: true,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      // States the action **and** the current state, so a screen-reader user
      // gets the same answer to "have I tapped today" that the screen gives.
      label: enabled
          ? TapCopy.tapTargetLabel
          : TapCopy.tapTargetLabelDone(tappedAtLabel ?? ''),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Material(
          shape: const CircleBorder(),
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onTap : null,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: FittedBox(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Colour is never the only signal: the tapped state
                      // changes the CONTENT of the target, so the answer to
                      // "did I tap?" is where her eyes already are rather than
                      // in small text at the bottom of the screen.
                      if (!enabled)
                        Icon(
                          Icons.check,
                          size: 64,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      Text(
                        enabled ? TapCopy.tapTarget : TapCopy.tapTargetDone,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displayMedium?.copyWith(
                          color: enabled
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **Who will be notified when she taps. That is all.**
///
/// Nothing else about watchers appears on this screen — no "X started watching
/// you", no "Y stopped watching you", no warning when the list empties. See
/// `WatchedAudience` for the full rejection list and the owner's reasoning.
///
/// The empty case is one static line covering both "nobody yet" and "everyone
/// revoked", because distinguishing them is what would make a status-change
/// message possible.
class _AudienceLine extends StatelessWidget {
  const _AudienceLine({required this.state});

  final WatchedState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = state.audience.names;

    return Text(
      names.isEmpty ? TapCopy.nobodyYet : TapCopy.willKnow(names),
      textAlign: TextAlign.center,
      style: theme.textTheme.titleLarge?.copyWith(
        // Secondary to the tap target, and never styled as a warning: this is
        // a statement of fact, including when it is the empty one.
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Shown when `POST_NOTIFICATIONS` is revoked — the state that makes the app
/// inert (§13).
///
/// It carries an **action**, because "ask a family member" is the dead-end
/// wording and is only honest once there is nothing left to press. §13's floor
/// is that a red item explains the consequence and, where one exists,
/// deep-links to the right settings screen.
///
/// It is about the *watched* person's own reminders, so it does not collide
/// with Decision 2: it says this phone will stop reminding **her**, and claims
/// nothing about who is or is not watching.
class _NotificationsOffBanner extends ConsumerWidget {
  const _NotificationsOffBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            TapCopy.notificationsOff,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
          TextButton(
            onPressed: () =>
                ref.read(watchedStateProvider.notifier).requestNotifications(),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text(TapCopy.notificationsOffAction),
          ),
        ],
      ),
    );
  }
}

/// Present, secondary, and inert until Phase 6.
class _AwayAction extends StatelessWidget {
  const _AwayAction();

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: null,
        style: TextButton.styleFrom(
          minimumSize: const Size(88, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
        child: const Text(TapCopy.awayAction),
      );
}

class _Failure extends ConsumerWidget {
  const _Failure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Says what happened and what to do — never a code, never
              // "something went wrong". Reserved for the INITIAL load: a failed
              // tap keeps the screen and shows one line, because replacing the
              // whole screen at the moment she taps is the worst possible time
              // to take her one action away.
              Text(
                TapCopy.couldNotStart,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () =>
                    ref.read(watchedStateProvider.notifier).refresh(),
                style: FilledButton.styleFrom(minimumSize: const Size(88, 56)),
                child: const Text(TapCopy.retry),
              ),
              const SizedBox(height: 24),
              if (kDebugMode)
                Text('$error', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}
