import 'package:timezone/timezone.dart' as tz;

import '../away/away_period.dart';
import '../reconcile/firestore_read.dart';
import '../time/day_key.dart';

/// What the watcher's alarm does when it fires.
///
/// **Four warning outcomes, not one.** Silence would be a silent failure; a
/// flat "she didn't check in" is a claim an unverified device cannot support;
/// an unverifiable away period is neither of those; and an app that has been
/// *refused* by the backend is not offline and must not say it is. Which one
/// fires is a correctness requirement, not copy polish — assert on the outcome,
/// never merely that something fired.
enum WarningOutcome {
  /// Say nothing. See [WarningDecision.silenceReason] for why.
  silent,

  /// *"No check-in from Mum yesterday."* The read succeeded and there was
  /// nothing there.
  warnOnline,

  /// *"No check-in received from Mum yesterday — your phone has been offline
  /// since HH:MM."* The device could not reach the server, and says so.
  warnOffline,

  /// *"Can't check on Mum — your phone has been offline since Tuesday 10:14.
  /// She was marked away until Saturday 22 August."* An away period is cached
  /// but has not been re-verified inside the staleness bound (ADR-0001).
  warnUnverifiableAway,

  /// *"Can't check on Mum — the app has lost access. Open I Am Ok. Last
  /// confirmed Saturday 15 August."*
  ///
  /// [ADR-0004][]. The server was reached and **refused** — a revoked link, an
  /// expired token, App Check, or a bad rules deploy. The phone is online and
  /// working, so the offline wording would be a false claim about it; and
  /// nothing here is evidence about the watched person, so the plain wording
  /// would be a false claim about her.
  ///
  /// Alone among the four, this names a fault the reader can **act on**, which
  /// is why it says so. It is also a §13 health-panel item: this condition
  /// persists until someone fixes it, and persistent conditions belong in the
  /// panel. The notification exists because §13's own argument is that a
  /// low-usage watcher never opens the app.
  ///
  /// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
  warnAccessLost,
}

/// Why the alarm stayed silent.
///
/// Named so a test can assert *which* rule produced the silence. "It was
/// silent" passes just as happily against a policy that is silent about
/// everything — and this app's worst bug is silence it cannot detect in itself.
enum SilenceReason {
  /// The link has been revoked. Nothing to say about someone no longer watched.
  ///
  /// ARCHITECTURE.md §10 step 2, added by [ADR-0004][]. §7 defined `status` and
  /// §8 gated the `checkins` read on an accepted link, but §10's sequence never
  /// consulted it — and the gap was not cosmetic: after revocation the read is
  /// permission-denied, which is a *failed* read, so the alarm fell through to
  /// [WarningOutcome.warnOffline] and would have claimed daily that the phone
  /// had been offline since HH:MM. A false statement about the device, made
  /// about someone the watcher deliberately stopped watching.
  ///
  /// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
  linkRevoked,

  /// `D` predates the link. Nothing to say about days before pairing (§7).
  beforeActiveFrom,

  /// A check-in is recorded for `D`. Evidence outranks doubt.
  checkInRecorded,

  /// `D` is inside a cached away period verified within the staleness bound.
  awayVerified,
}

/// The outcome of one warning-alarm fire, with everything the copy needs.
class WarningDecision {
  const WarningDecision({
    required this.outcome,
    required this.day,
    this.silenceReason,
    this.away,
    this.unverifiedSince,
    this.lastConfirmedDay,
  });

  final WarningOutcome outcome;

  /// `D` — the day the decision is about.
  final DayKey day;

  /// Set exactly when [outcome] is [WarningOutcome.silent].
  final SilenceReason? silenceReason;

  /// The cached away period, on [WarningOutcome.warnUnverifiableAway]. The copy
  /// names its `through` date: "*She was marked away until Saturday 22 August*".
  final AwayPeriod? away;

  /// Last successful reconcile, on the outcomes whose copy renders it as
  /// "*offline since 10:14*" — which is why ADR-0002 made `lastReconcileAt` a
  /// full timestamp rather than a date. Null when the device has never
  /// reconciled successfully.
  final DateTime? unverifiedSince;

  /// The last day known to have a check-in, on [WarningOutcome.warnAccessLost].
  ///
  /// Its copy ends "*Last confirmed Saturday 15 August*" — the one thing the
  /// device still honestly knows once access is gone. **Null is a real case**
  /// (access lost before any check-in was ever recorded) and the copy needs a
  /// variant for it rather than rendering an empty date.
  final DayKey? lastConfirmedDay;

  bool get isWarning => outcome != WarningOutcome.silent;

  @override
  bool operator ==(Object other) =>
      other is WarningDecision &&
      other.outcome == outcome &&
      other.day == day &&
      other.silenceReason == silenceReason &&
      other.away == away &&
      other.unverifiedSince == unverifiedSince &&
      other.lastConfirmedDay == lastConfirmedDay;

  @override
  int get hashCode => Object.hash(
        outcome,
        day,
        silenceReason,
        away,
        unverifiedSince,
        lastConfirmedDay,
      );

  @override
  String toString() => outcome == WarningOutcome.silent
      ? 'WarningDecision(silent: ${silenceReason?.name}, $day)'
      : 'WarningDecision(${outcome.name}, $day)';
}

/// Should the watcher warn about the last completed day?
///
/// ARCHITECTURE.md §10 as amended by [ADR-0001][] and [ADR-0004][]. The
/// executable specification is `tools/models/away_warning_model.dart` — 18
/// cases, and its `decidedDesign` is what this ports. Run it before changing
/// anything here; note it predates ADR-0004 and reads as the *unreachable*
/// interpretation only, which its own header records.
///
/// **This function decides; it does not refresh.** The reconcile that must
/// happen *first* is [WatcherCache.applyRead][], and the ordering is composed
/// by `WatcherReconciler`. Splitting them is what keeps this a pure function
/// over explicit inputs — but the ordering is the entire point of ADR-0001, so
/// the composition is tested as hard as the branches.
///
/// [ADR-0001]: ../../../docs/architecture/decisions/0001-away-cache-precedence.md
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
/// [WatcherCache.applyRead]: ../reconcile/watcher_cache.dart
abstract final class WarningPolicy {
  /// A cached away period may silence for at most this many days without a
  /// successful re-verification (ADR-0001 decision 2).
  ///
  /// The alarm attempts a reconcile daily, so exceeding this means three
  /// consecutive failures. Zero or one would speak too soon — a single failed
  /// reconcile is ordinary for a phone in a pocket.
  static const int defaultStaleAwayAfterDays = 2;

  /// How far back a reconcile may catch up on days it never decided about
  /// ([ADR-0009][]).
  ///
  /// Seven, matching §10's seven-day rolling alarm window — the same number for
  /// the same reason, which is that a week is as far back as this design ever
  /// looks. It is a **cap on the burst**, not a target: a device that has been
  /// unable to decide for a month must not wake up and post thirty
  /// notifications on the one channel §1 is built to keep un-swipeable.
  ///
  /// Days older than this are dropped, knowingly. That is the residual ADR-0009
  /// accepts, and it is a strictly smaller one than dropping every day but the
  /// newest.
  static const int defaultCatchUpDays = 7;

  /// Every completed day this reconcile must decide about, **oldest first**.
  ///
  /// ADR-0009. Before it, the answer was always the single day
  /// `lastCompletedDay(now)` — and a fire that ran late, a phone in a drawer,
  /// or a force-stop nobody undid until Thursday therefore skipped every day in
  /// between and skipped them **silently**, which is the one failure this app
  /// cannot detect in itself.
  ///
  /// [lastDecidedDay] is the newest day this device has actually *settled* —
  /// see [WatcherCache.lastDecidedDay] for what settled means and why it is not
  /// simply "the last day we ran".
  ///
  /// Three properties this list always has, each load-bearing:
  ///
  /// - **It always ends at `D`.** Everything downstream that keys on "the
  ///   decision about the current day" — the access-lost cadence, the watcher
  ///   row, the alarm window — is unchanged by this function existing.
  /// - **It is `{D}` alone in ordinary operation**, because yesterday's run
  ///   settled `D - 1`. The common case is provably identical to the behaviour
  ///   this replaced, which is what makes it safe to land on the warning path.
  /// - **It is `{D}` alone on a first reconcile**, when [lastDecidedDay] is
  ///   null. A fresh install does not retro-warn about days it was not watching.
  ///
  /// [ADR-0009]: ../../../docs/architecture/decisions/0009-decide-about-every-completed-day.md
  /// [WatcherCache.lastDecidedDay]: ../reconcile/watcher_cache.dart
  static List<DayKey> daysToDecide({
    required DateTime now,
    required tz.Location watchedZone,
    required DayKey activeFrom,
    required DayKey? lastDecidedDay,
    int catchUpDays = defaultCatchUpDays,
  }) {
    final d = lastCompletedDay(now, watchedZone);

    var start = lastDecidedDay == null ? d : lastDecidedDay.next;

    // Never before the link existed (§7). Easy to omit, and its own §17 risk —
    // `decideFor` guards it per day as well, and both guards are deliberate:
    // this one keeps the list short, that one keeps the answer right.
    if (start < activeFrom) start = activeFrom;

    // The burst cap.
    final floor = d.minusDays(catchUpDays - 1);
    if (start < floor) start = floor;

    // `lastDecidedDay >= d` on every reconcile after the first of the day, and
    // on a device whose clock moved backwards. Both must still produce a
    // decision about `D`: reconcile() is idempotent by design and the second run
    // of the day is the normal case, not an edge one.
    if (start > d) start = d;

    final days = <DayKey>[];
    for (var day = start; day <= d; day = day.next) {
      days.add(day);
    }
    return days;
  }

  /// Decides for the most recently completed day in [watchedZone] as of [now].
  ///
  /// A thin delegation to [decideFor], which is where the reasoning lives. The
  /// split exists because ADR-0009 needs to ask the same six ordered steps about
  /// a day that is **not** the current one, and two copies of this body would be
  /// two chances to get the ordering wrong — the ordering being the whole of
  /// ADR-0001 and ADR-0004.
  ///
  /// [away] and the three cache values must already have been refreshed by a
  /// successful read; passing raw cache values here re-introduces exactly the
  /// defect ADR-0001 fixed.
  ///
  /// [verification] is a *read* outcome, not a connectivity one, and it has
  /// three states rather than two ([ADR-0004][]). A timeout and a permission
  /// denial both mean "could not verify", so neither may clear the cache — but
  /// only one of them means the phone is offline, and saying so when the phone
  /// is fine is a false claim about the device.
  ///
  /// [away] has been a parameter since the first line of this file, written in
  /// Phase 1 when every production call site passed null (PLAN.md, Phase 1,
  /// non-negotiable). **Phase 6 filled it in** — `WatcherReconciler` passes
  /// `cache.away?.period`, the **period only**: attribution is a display label
  /// ADR-0003 says cannot be authenticated, and no warning decision may see it.
  static WarningDecision decide({
    required DateTime now,
    required tz.Location watchedZone,
    required AwayPeriod? away,
    required bool linkAccepted,
    required DayKey activeFrom,
    required DayKey? lastConfirmedDay,
    required DateTime? lastReconcileAt,
    required Verification verification,
    int staleAwayAfterDays = defaultStaleAwayAfterDays,
  }) =>
      decideFor(
        // Step 1. D = the most recently completed day in the WATCHED person's
        // zone. The alarm fires at watcher-local time; the question is about
        // watched-local days, which is why a watcher abroad is never woken at
        // 03:00 (§11).
        day: lastCompletedDay(now, watchedZone),
        now: now,
        watchedZone: watchedZone,
        away: away,
        linkAccepted: linkAccepted,
        activeFrom: activeFrom,
        lastConfirmedDay: lastConfirmedDay,
        lastReconcileAt: lastReconcileAt,
        verification: verification,
        staleAwayAfterDays: staleAwayAfterDays,
      );

  /// Decides about **[day] specifically**, which may be older than `D`.
  ///
  /// ADR-0009's entry point. [now] is still required and is still a real input:
  /// it is what the away staleness bound is measured against — *how stale is my
  /// cache right now* — which is a question about the present whatever day is
  /// being decided about.
  ///
  /// Everything else here is [decide], unchanged. The six ordered steps, their
  /// precedence, and every argument for that precedence are untouched by
  /// ADR-0009: it changes *which days the policy is asked about* and nothing
  /// about what it answers.
  static WarningDecision decideFor({
    required DayKey day,
    required DateTime now,
    required tz.Location watchedZone,
    required AwayPeriod? away,
    required bool linkAccepted,
    required DayKey activeFrom,
    required DayKey? lastConfirmedDay,
    required DateTime? lastReconcileAt,
    required Verification verification,
    int staleAwayAfterDays = defaultStaleAwayAfterDays,
  }) {
    final today = DayKey.fromInstant(now, watchedZone);

    // Step 2. A revoked link says nothing at all, before any other reasoning
    // (§10 step 2, ADR-0004). See SilenceReason.linkRevoked for why the
    // omission was not cosmetic.
    if (!linkAccepted) {
      return WarningDecision(
        outcome: WarningOutcome.silent,
        day: day,
        silenceReason: SilenceReason.linkRevoked,
      );
    }

    // Step 3. Never warn about days before the link existed (§7). Easy to omit,
    // and its own §17 risk.
    if (day < activeFrom) {
      return WarningDecision(
        outcome: WarningOutcome.silent,
        day: day,
        silenceReason: SilenceReason.beforeActiveFrom,
      );
    }

    // Step 4. Evidence outranks doubt. A recorded check-in settles the day
    // BEFORE any away reasoning runs, because tapping during an away day is
    // allowed (§12) — so a confirmed day stays silent even when the cached away
    // has gone stale. This ordering is ADR-0001 decision 4.
    if (lastConfirmedDay != null && lastConfirmedDay >= day) {
      return WarningDecision(
        outcome: WarningOutcome.silent,
        day: day,
        silenceReason: SilenceReason.checkInRecorded,
      );
    }

    // Step 5. Reached and REFUSED (ADR-0004). Placed after evidence and before
    // away, deliberately. A recorded check-in settles D on facts already held,
    // and losing access does not unsettle it. A cached away is not evidence
    // about the present: ADR-0001's two-day bound is calibrated for transient
    // network failure — "a phone in a pocket" — and a refusal is neither
    // transient nor self-healing, so silence here would mean days of a dead
    // man's switch that is definitively dead.
    if (verification == Verification.refused) {
      // Clamped, and only if it actually covers D. The cache is cleared only by
      // a successful read, so an away period that ended in August followed by a
      // refusal in September stays cached indefinitely — and this message
      // renders `through`. Passing it raw would tell a family "she was marked
      // away until Saturday 22 August" for weeks after that period ended, which
      // is the false claim ADR-0004 was written to remove from this very
      // message.
      final honoured = away?.clampedToSanityBound();
      return WarningDecision(
        outcome: WarningOutcome.warnAccessLost,
        day: day,
        away: honoured != null && honoured.covers(day) ? honoured : null,
        unverifiedSince: lastReconcileAt,
        lastConfirmedDay: lastConfirmedDay,
      );
    }

    // Step 6. Inside a cached away period — silent only while the cache is
    // fresh enough to be worth trusting, and only for as long as the cap
    // permits. Clamping here rather than trusting the caller is deliberate:
    // an over-long period reaching this point silences a family for as long as
    // it claims, and a successful read of it is not stale, so no other guard
    // in the design would catch it.
    final honoured = away?.clampedToSanityBound();
    if (honoured != null && honoured.covers(day)) {
      // Calendar-day granular, not a 48-hour duration (ADR-0002 decision 4):
      // the alarm attempts one reconcile a day, so days are the cadence the
      // rule is actually about. The timestamp exists for the message.
      final verifiedOn = lastReconcileAt == null
          ? null
          : DayKey.fromInstant(lastReconcileAt, watchedZone);
      // The gap must be non-negative as well as small. A device clock that
      // moved BACKWARDS puts the last reconcile in the future, and a bare
      // `gap <= 2` then passes on a negative number — silencing the watcher for
      // as long as the skew lasts, on a "verification" that has not happened.
      // §3 lists "clock change" among the seven cases reconcile() collapses,
      // and §11's rule is that skew is surfaced, never silently trusted.
      final gap =
          verifiedOn == null ? null : today.differenceInDays(verifiedOn);
      final fresh = gap != null && gap >= 0 && gap <= staleAwayAfterDays;

      if (fresh) {
        return WarningDecision(
          outcome: WarningOutcome.silent,
          day: day,
          silenceReason: SilenceReason.awayVerified,
          away: honoured,
        );
      }

      // Offline, the device cannot tell "the away was cancelled and I did not
      // hear" from "the away is still on and I have not checked" — the inputs
      // are identical. This chooses which error to prefer, and prefers
      // speaking: silence is the one failure this app cannot detect in itself.
      return WarningDecision(
        outcome: WarningOutcome.warnUnverifiableAway,
        day: day,
        away: honoured,
        unverifiedSince: lastReconcileAt,
      );
    }

    // Step 7. Warn — with the message the device can actually support. Only
    // two verification states can reach here: refused returned at step 5.
    final verified = verification == Verification.verified;
    return WarningDecision(
      outcome: verified ? WarningOutcome.warnOnline : WarningOutcome.warnOffline,
      day: day,
      unverifiedSince: verified ? null : lastReconcileAt,
    );
  }
}
