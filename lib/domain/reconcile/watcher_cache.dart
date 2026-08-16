import '../away/away_period.dart';
import '../policy/warning_policy.dart';
import '../time/day_key.dart';
import 'firestore_read.dart';

/// The per-link slice of `LocalStore` the warning decision runs on.
///
/// This is tier 3 of the truth model (§3) — the offline decision cache, and the
/// only thing a bare background isolate can see, because the three isolates
/// share no memory. It is modelled here as an immutable value so the decision
/// stays a pure function: the reconciler returns the next cache and the Data
/// layer performs one write, rather than a handler incrementally patching
/// state. That is "reconcile, don't mutate" at the level of a single row.
class WatcherCache {
  const WatcherCache({
    this.away,
    this.lastConfirmedDay,
    this.warningsShownFor = const {},
    this.lastReconcileAt,
    this.accessLostSince,
    this.accessLostCause,
    this.accessLostNotifiedOn,
  });

  const WatcherCache.empty()
      : away = null,
        lastConfirmedDay = null,
        warningsShownFor = const {},
        lastReconcileAt = null,
        accessLostSince = null,
        accessLostCause = null,
        accessLostNotifiedOn = null;

  /// The away period as last successfully read. Cached per link even though
  /// away is global to the watched person, because §6 stores it that way.
  final AwayPeriod? away;

  /// The latest day known to have a check-in. Monotonic — see [applyRead].
  final DayKey? lastConfirmedDay;

  /// The warning **about the watched person** currently standing for each day,
  /// keyed by day and carrying *which* message is showing.
  ///
  /// §6 calls this a set of days. It is a map because ADR-0004 made more than
  /// one message reachable for the same `D`: a 10:00 alarm can show *"your
  /// phone has been offline"* and an 11:00 app-open can then verify and find
  /// no check-in. Keyed on the day alone, that second, stronger, now-verified
  /// message never replaces the first — the family is left reading a stale
  /// hedge. The value is what makes "the standing message is no longer the
  /// right one" expressible at all.
  ///
  /// [WarningOutcome.warnAccessLost] deliberately never appears here. This map
  /// is the sole input to `WatchStatus`'s `warned` state, so recording an
  /// access failure in it would make the watcher's list row claim a missed
  /// check-in — the exact false claim ADR-0004 removed from the notification,
  /// arriving through the list surface instead. It would also make the
  /// correction handler later retract a message that never claimed anything
  /// about her. Access failures live in [accessLostSince] instead.
  final Map<DayKey, WarningOutcome> warningsShownFor;

  /// When tier 1 was last read **successfully**.
  ///
  /// A full timestamp, not a date (ADR-0002 decision 3): the copy renders
  /// "offline since 10:14" from it. The staleness *comparison* is nonetheless
  /// calendar-day granular — see [WarningPolicy.decide].
  final DateTime? lastReconcileAt;

  /// The day the backend first **refused** this watcher, or null while access
  /// is fine (ADR-0004 decision 5).
  ///
  /// Kept apart from [warningsShownFor] because it is a fact about *this app's
  /// access*, not about the watched person. It is also the anchor the reminder
  /// cadence counts from — day 0, 1, 3, then weekly (ADR-0004 decision 5) —
  /// which is why the FIRST day is kept rather than the latest.
  final DayKey? accessLostSince;

  /// Why the backend refused, driving §13's remediation — "sign in again" for
  /// an expired token, "update the app" for App Check. The refusal usually
  /// happens in the **alarm isolate**, and §4's rule is that anything a
  /// background isolate produces for the UI is on disk, so this is a
  /// `LocalStore` field and not merely a transient.
  final RefusedCause? accessLostCause;

  /// The last day an access-lost notification was actually shown.
  ///
  /// `reconcile()` runs several times a day — app open, FCM arrival, alarm
  /// fire, boot — so a cadence expressed in days needs to know whether today's
  /// reminder has already been given, or the watcher gets four of them.
  final DayKey? accessLostNotifiedOn;

  /// Whether the backend is currently refusing this watcher.
  bool get hasLostAccess => accessLostSince != null;

  /// The days with a standing warning about the watched person.
  Iterable<DayKey> get warnedDays => warningsShownFor.keys;

  /// Records a refusal on [day].
  ///
  /// The **first** day is kept, so the health panel can say how long this has
  /// been going on and the reminder cadence has something to count from. The
  /// cause is always updated to the current one: a change from
  /// `unauthenticated` to `appCheckRejected` means the remediation the watcher
  /// was given is now the wrong instruction.
  WatcherCache withAccessLostOn(DayKey day, RefusedCause cause) {
    if (accessLostSince != null && accessLostCause == cause) return this;
    return WatcherCache(
      away: away,
      lastConfirmedDay: lastConfirmedDay,
      warningsShownFor: warningsShownFor,
      lastReconcileAt: lastReconcileAt,
      accessLostSince: accessLostSince ?? day,
      accessLostCause: cause,
      accessLostNotifiedOn: accessLostNotifiedOn,
    );
  }

  /// Records that today's access-lost reminder has been shown.
  WatcherCache withAccessLostNotifiedOn(DayKey day) =>
      accessLostNotifiedOn == day
          ? this
          : copyWith(accessLostNotifiedOn: day);

  /// Clears the access-lost state — access is provably back.
  ///
  /// Clears the notification day with it, so a *later* loss starts its cadence
  /// from the beginning rather than believing it has already reminded someone.
  WatcherCache withAccessRestored() {
    if (accessLostSince == null &&
        accessLostCause == null &&
        accessLostNotifiedOn == null) {
      return this;
    }
    return WatcherCache(
      away: away,
      lastConfirmedDay: lastConfirmedDay,
      warningsShownFor: warningsShownFor,
      lastReconcileAt: lastReconcileAt,
    );
  }

  /// Folds a tier-1 read into the cache. **ADR-0001 decision 1 — the reconcile
  /// that must happen before anything is decided.**
  ///
  /// A failed read returns the cache untouched. Gating this on *the read
  /// succeeded* rather than on connectivity is the whole point: a timeout, a
  /// permission denial and an App Check rejection all occur while online, and
  /// clearing the cache on any of them wipes a legitimate away and warns
  /// falsely.
  ///
  /// On success [away] is overwritten **wholesale, including with null**. That
  /// single assignment is what makes a remotely cancelled away period visible
  /// to a watcher whose `onAwayChanged` nudge was lost — the failure that cost
  /// sixteen days of wrongful silence in the modelled scenario. The period it
  /// replaced is handed back on the reconcile result as `previousAway`, because
  /// destroying it here would leave nothing able to tell a *cancelled* away
  /// from an *expired* one, which §12 gives different messages.
  WatcherCache applyRead(FirestoreRead read, {required DateTime at}) {
    if (read is! ReadSucceeded) return this;

    // Monotonic: a read of a narrow window must never walk lastConfirmedDay
    // backwards and re-open a day that was already settled.
    var confirmed = lastConfirmedDay;
    for (final day in read.checkInDays) {
      if (confirmed == null || day > confirmed) confirmed = day;
    }

    // A read that succeeded is proof that access is back, so the access-lost
    // state is cleared here and nowhere else — by the same evidence rule that
    // governs everything else on this path.
    return WatcherCache(
      away: read.away,
      lastConfirmedDay: confirmed,
      warningsShownFor: warningsShownFor,
      lastReconcileAt: at,
    );
  }

  /// Records that [outcome] is now the standing warning for [day] (§10 step 8).
  WatcherCache withWarningShownFor(DayKey day, WarningOutcome outcome) {
    if (warningsShownFor[day] == outcome) return this;
    return copyWith(
      warningsShownFor: {...warningsShownFor, day: outcome},
    );
  }

  /// Applies the late-arrival correction for [day] (§10).
  ///
  /// The standing warning is no longer true, so the day leaves
  /// [warningsShownFor] and [lastConfirmedDay] advances to cover it. The
  /// caller replaces the notification — same id, so it is a replacement rather
  /// than a second notification.
  WatcherCache withCorrectionFor(DayKey day) {
    final remaining = {...warningsShownFor}..remove(day);
    final confirmed =
        lastConfirmedDay == null || day > lastConfirmedDay! ? day : lastConfirmedDay;
    return copyWith(
      warningsShownFor: remaining,
      lastConfirmedDay: confirmed,
    );
  }

  /// Drops every standing warning without correcting any of them.
  ///
  /// For revocation (§10 step 2): the warnings are not *wrong*, they are simply
  /// no longer this watcher's business. A correction would be worse than
  /// silence, because *"Mum did check in yesterday"* is a claim nothing here
  /// supports. The caller cancels the notifications outright.
  WatcherCache withWarningsWithdrawn() {
    if (warningsShownFor.isEmpty) return this;
    return copyWith(warningsShownFor: const {});
  }

  /// `away` is not covered by the null-means-unchanged convention, because
  /// null is a meaningful value for it. Use [clearAway] to remove it.
  WatcherCache copyWith({
    AwayPeriod? away,
    DayKey? lastConfirmedDay,
    Map<DayKey, WarningOutcome>? warningsShownFor,
    DateTime? lastReconcileAt,
    DayKey? accessLostSince,
    RefusedCause? accessLostCause,
    DayKey? accessLostNotifiedOn,
  }) =>
      WatcherCache(
        away: away ?? this.away,
        lastConfirmedDay: lastConfirmedDay ?? this.lastConfirmedDay,
        warningsShownFor: warningsShownFor ?? this.warningsShownFor,
        lastReconcileAt: lastReconcileAt ?? this.lastReconcileAt,
        accessLostSince: accessLostSince ?? this.accessLostSince,
        accessLostCause: accessLostCause ?? this.accessLostCause,
        accessLostNotifiedOn: accessLostNotifiedOn ?? this.accessLostNotifiedOn,
      );

  WatcherCache clearAway() => WatcherCache(
        lastConfirmedDay: lastConfirmedDay,
        warningsShownFor: warningsShownFor,
        lastReconcileAt: lastReconcileAt,
        accessLostSince: accessLostSince,
        accessLostCause: accessLostCause,
        accessLostNotifiedOn: accessLostNotifiedOn,
      );

  @override
  bool operator ==(Object other) =>
      other is WatcherCache &&
      other.away == away &&
      other.lastConfirmedDay == lastConfirmedDay &&
      other.lastReconcileAt == lastReconcileAt &&
      other.accessLostSince == accessLostSince &&
      other.accessLostCause == accessLostCause &&
      other.accessLostNotifiedOn == accessLostNotifiedOn &&
      _sameWarnings(other.warningsShownFor, warningsShownFor);

  @override
  int get hashCode => Object.hash(
        away,
        lastConfirmedDay,
        lastReconcileAt,
        accessLostSince,
        accessLostCause,
        accessLostNotifiedOn,
        Object.hashAllUnordered(
          warningsShownFor.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  static bool _sameWarnings(
    Map<DayKey, WarningOutcome> a,
    Map<DayKey, WarningOutcome> b,
  ) =>
      a.length == b.length &&
      a.entries.every((e) => b[e.key] == e.value);

  @override
  String toString() => 'WatcherCache(away: $away, confirmed: $lastConfirmedDay, '
      'warnings: $warningsShownFor, reconciled: $lastReconcileAt'
      '${hasLostAccess ? ', accessLost: $accessLostSince/${accessLostCause?.name}' : ''})';
}
