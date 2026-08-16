import '../away/away_period.dart';
import '../time/day_key.dart';
import 'link.dart';

/// What one row of the watcher list currently says about one watched person.
enum WatchState {
  /// The link has been revoked. Nothing to show about someone no longer
  /// watched ([ADR-0004][]).
  ///
  /// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
  revoked,

  /// The last completed day predates the link. Nothing to say yet (§7).
  notYetLinked,

  /// The backend is refusing this watcher, so nothing about the watched person
  /// can be shown — and, crucially, **no missed check-in is being claimed**.
  ///
  /// Distinct from [warned] because a refusal is evidence about this app's
  /// access, never about her. Collapsing the two would put the false claim
  /// ADR-0004 removed from the notification back on the list.
  accessLost,

  /// An unresolved warning stands for the last completed day.
  warned,

  /// An away period covers today. No check-in is expected.
  away,

  /// The last completed day is confirmed.
  checkedIn,

  /// Not confirmed, not away, and no warning has fired — the warning alarm has
  /// not run yet today. Honest "we don't know", never "Everything OK".
  awaitingCheckIn,
}

/// The watcher-side view of one link, derived from cache state.
///
/// Pure, and derived rather than stored, because this is **current state, not
/// history**: a warning from three weeks ago followed by three weeks of
/// check-ins is history, and PLAN.md Phase 7 is explicit that cold open must
/// show an *unresolved* warning if one stands and otherwise "Everything OK"
/// with the last check-in time.
///
/// Rendering is Phase 7's; the derivation is here because it is a decision, and
/// every decision in this app is a pure function over explicit inputs.
class WatchStatus {
  const WatchStatus({
    required this.linkId,
    required this.watchedName,
    required this.state,
    required this.day,
    this.away,
    this.lastCheckInDay,
    this.lastCheckInAt,
  });

  /// Derives the row for [link] as of [today] in the watched person's zone.
  ///
  /// [warningsShownFor] is expected to be post-correction — the reconciler
  /// removes a day when a late check-in arrives for it. [WatchState.warned]
  /// therefore takes precedence over [WatchState.checkedIn]: if both were
  /// somehow true, a correction was owed and not applied, and surfacing that is
  /// better than hiding it behind a green row.
  factory WatchStatus.derive({
    required Link link,
    required DayKey today,
    required AwayPeriod? away,
    required Set<DayKey> warningsShownFor,
    bool hasLostAccess = false,
    DayKey? lastCheckInDay,
    DateTime? lastCheckInAt,
  }) {
    final day = today.previous;

    final WatchState state;
    // Revocation first, and it must be checked here as well as in
    // WarningPolicy. The reconciler goes silent on a revoked link but a warning
    // standing at the moment of revocation is only *withdrawn* on the next
    // reconcile — and if that never runs, this row would otherwise demand
    // attention forever about someone no longer watched, with no path to
    // retract it, because every later read is refused and only a successful
    // read can produce a correction.
    if (!link.isAccepted) {
      state = WatchState.revoked;
    } else if (day < link.activeFrom) {
      state = WatchState.notYetLinked;
    } else if (warningsShownFor.contains(day)) {
      // A recorded claim about the watched person is the headline, above the
      // app's own health: "Mum may have missed a day" is what the family needs
      // to act on, and "the app has lost access" — while real, and surfaced by
      // needsAttention either way — is secondary to it.
      state = WatchState.warned;
    } else if (hasLostAccess) {
      // Above `away` for the same reason WarningPolicy puts refusal above the
      // away branch: a cached away is a claim about the present resting on a
      // read that can no longer be repeated.
      state = WatchState.accessLost;
    } else if (away != null && (away.covers(today) || away.covers(day))) {
      state = WatchState.away;
    } else if (lastCheckInDay != null && lastCheckInDay >= day) {
      state = WatchState.checkedIn;
    } else {
      state = WatchState.awaitingCheckIn;
    }

    return WatchStatus(
      linkId: link.id,
      watchedName: link.watchedName,
      state: state,
      day: day,
      away: away,
      lastCheckInDay: lastCheckInDay,
      lastCheckInAt: lastCheckInAt,
    );
  }

  final String linkId;
  final String watchedName;
  final WatchState state;

  /// The day this status is about — the last completed watched-local day.
  final DayKey day;

  /// The away period as currently known, whatever [state] says. The UI shows
  /// away state on every surface (§17), not only when it is the headline.
  final AwayPeriod? away;

  final DayKey? lastCheckInDay;

  /// Client clock at the last tap — what the family is shown (§11).
  final DateTime? lastCheckInAt;

  /// Whether the row should demand the watcher's attention.
  ///
  /// [WatchState.accessLost] counts: the app is not doing its job and only the
  /// watcher can fix it. [WatchState.revoked] does not — there is nothing to
  /// act on and nobody left to act for.
  bool get needsAttention =>
      state == WatchState.warned || state == WatchState.accessLost;

  @override
  bool operator ==(Object other) =>
      other is WatchStatus &&
      other.linkId == linkId &&
      other.watchedName == watchedName &&
      other.state == state &&
      other.day == day &&
      other.away == away &&
      other.lastCheckInDay == lastCheckInDay &&
      other.lastCheckInAt == lastCheckInAt;

  @override
  int get hashCode => Object.hash(
        linkId,
        watchedName,
        state,
        day,
        away,
        lastCheckInDay,
        lastCheckInAt,
      );

  @override
  String toString() => 'WatchStatus($watchedName, ${state.name}, $day)';
}
