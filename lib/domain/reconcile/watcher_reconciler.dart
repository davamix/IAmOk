import 'package:timezone/timezone.dart' as tz;

import '../away/away_period.dart';
import '../entities/link.dart';
import '../policy/warning_policy.dart';
import '../time/day_key.dart';
import '../time/local_time_of_day.dart';
import 'firestore_read.dart';
import 'watcher_cache.dart';

/// One warning alarm that should exist.
///
/// Unlike a reminder, this alarm is **not** cancelled during an away period
/// (§10): each fire re-verifies against Firestore, which is how an away
/// cancelled remotely is picked up even when every push was lost. Cancelling
/// and re-arming would be cheaper and less correct.
///
/// Equality covers the **instant as well as** the day, for the reason given on
/// [ScheduledReminder]. Here the moving part is `link.warningLocalTime`, which
/// §6 gives `LinkRepository` as a per-link setting: with [at] excluded, a
/// watcher changing 10:00 to 08:00 produces an empty diff and nothing happens
/// for a week. Same ordering rule — **apply `toCancel` before `toSchedule`**.
class ScheduledWarning {
  const ScheduledWarning({required this.day, required this.at});

  /// The watcher-local day the alarm fires on. The day it asks *about* is
  /// derived at fire time in the watched person's zone, not here.
  final DayKey day;

  /// The instant it fires, in the watcher's zone.
  final tz.TZDateTime at;

  @override
  bool operator ==(Object other) =>
      other is ScheduledWarning && other.day == day && other.at == at;

  @override
  int get hashCode => Object.hash(day, at);

  @override
  String toString() => 'ScheduledWarning($day @ $at)';
}

/// A standing warning that a late check-in has proved wrong (§10).
///
/// The notification is **replaced**, not supplemented — same id, so the family
/// sees one corrected message rather than two contradictory ones. The id is
/// `hash(link, day)`, which is built at the platform edge in Phase 3; carrying
/// both parts here is what keeps a correction for one watched person from
/// touching a standing warning for another on the same day.
class Correction {
  const Correction({required this.linkId, required this.day});

  final String linkId;
  final DayKey day;

  @override
  bool operator ==(Object other) =>
      other is Correction && other.linkId == linkId && other.day == day;

  @override
  int get hashCode => Object.hash(linkId, day);

  @override
  String toString() => 'Correction($linkId, $day)';
}

/// Everything one watcher-side reconcile concluded, for one link.
class WatcherReconcileResult {
  const WatcherReconcileResult({
    required this.cache,
    required this.decision,
    required this.shouldNotify,
    required this.corrections,
    required this.withdrawnWarnings,
    required this.cancelAccessLostNotice,
    required this.previousAway,
    required this.desiredWarnings,
    required this.warningsToSchedule,
    required this.warningsToCancel,
  });

  /// The cache to persist — one write, covering the refresh, any corrections,
  /// and any warning recorded by this fire.
  final WatcherCache cache;

  /// What the alarm concluded about `D`.
  final WarningDecision decision;

  /// Whether a *new* notification is owed.
  ///
  /// Distinct from `decision.isWarning`: the decision answers §10's question
  /// ("should this day be warned about"), which stays true on every subsequent
  /// reconcile of the same day. This answers the idempotence question — every
  /// entry point calls reconcile, so a warning already standing must not fire
  /// again on app open or on boot.
  final bool shouldNotify;

  /// Standing warnings a late check-in has disproved. The notification is
  /// **replaced** by the correction message.
  final List<Correction> corrections;

  /// Standing warnings to **cancel outright, with no replacement message**,
  /// because the link was revoked (§10 step 2).
  ///
  /// Distinct from [corrections] on purpose: nothing here disproves the
  /// warning, so *"Mum did check in yesterday"* would be a claim the device
  /// cannot support. Without this channel a warning standing at the moment of
  /// revocation would sit in the tray forever — every later read is refused, so
  /// no correction could ever clear it.
  final List<DayKey> withdrawnWarnings;

  /// The away period the cache held **before** this reconcile overwrote it.
  ///
  /// Carried because `applyRead` replaces `away` wholesale, and the diff is the
  /// only thing that can tell a *cancelled* away from one that simply *expired*
  /// — a cached `through` later than the fetched one means shortened or
  /// cancelled. §12 gives those different messages, and destroying the evidence
  /// here would force Phase 6 to re-read the cache before `applyRead`, i.e. to
  /// keep a second source of truth for away state exactly where ADR-0001 says
  /// there must not be one. Classifying it is Phase 6; preserving it is here.
  final AwayPeriod? previousAway;

  /// Every warning alarm that should exist across the window.
  ///
  /// **Apply [warningsToCancel] before [warningsToSchedule].** Alarm identity
  /// includes the instant, so a moved alarm appears in both sets, while the
  /// platform id stays derived from the day — cancelling last would disarm the
  /// alarm just rescheduled, and the symptom is nothing happening.
  final Set<ScheduledWarning> desiredWarnings;

  /// Missing, so create them. Apply **after** [warningsToCancel].
  final Set<ScheduledWarning> warningsToSchedule;

  /// Present and unwanted, so cancel them. Apply **before**
  /// [warningsToSchedule] — see [desiredWarnings].
  final Set<ScheduledWarning> warningsToCancel;

  /// Alarms whose instant moved: same platform id, different fire time.
  ///
  /// Derived, and present so the ordering trap above is visible in
  /// autocomplete and assertable in a test rather than living only in prose.
  Set<DayKey> get warningsToReschedule {
    final cancelling = warningsToCancel.map((w) => w.day).toSet();
    return warningsToSchedule
        .map((w) => w.day)
        .where(cancelling.contains)
        .toSet();
  }

  /// Whether a standing access-lost notification must be **cancelled**, with no
  /// replacement message.
  ///
  /// There is deliberately no "access restored" notification — quiet confirm,
  /// loud miss. But *not notifying* and *not cancelling* are different
  /// decisions, and only the first was made: without this the tray keeps
  /// telling a watcher to open the app and fix something already fixed, next to
  /// the next real warning. The same gap as `withdrawnWarnings`, on the other
  /// channel.
  final bool cancelAccessLostNotice;

  /// Nothing to do — no notification, no correction, no withdrawal, no alarm
  /// churn.
  bool get isNoOp =>
      !shouldNotify &&
      corrections.isEmpty &&
      withdrawnWarnings.isEmpty &&
      !cancelAccessLostNotice &&
      warningsToSchedule.isEmpty &&
      warningsToCancel.isEmpty;

  @override
  String toString() => 'WatcherReconcileResult(${decision.outcome.name}, '
      'notify: $shouldNotify, ${corrections.length} correction(s))';
}

/// The watcher side's desired-state calculator: **reconcile first, then
/// decide.**
///
/// The ordering is the entire content of [ADR-0001][]. Consulting the cache
/// before attempting tier 1 inverts the truth model (§3) and lets a stale
/// cached away silence a watcher for as long as the away period has left to run
/// — sixteen days in the modelled scenario, in a state §17 rates as
/// indistinguishable from working.
///
/// [ADR-0001]: ../../../docs/architecture/decisions/0001-away-cache-precedence.md
abstract final class WatcherReconciler {
  /// Days of warning alarms kept armed ahead, counting today.
  static const int windowDays = 7;

  /// The reminder milestone at or before [daysSinceLost].
  ///
  /// Milestones are day 0, 1, 3, then every seventh day. Expressing the
  /// schedule as *which milestone have we reached* rather than *is today a
  /// milestone* is what makes it survive a device that does not wake every day
  /// — see [isAccessLostReminderDue].
  static int accessLostMilestone(int daysSinceLost) {
    if (daysSinceLost < 1) return 0;
    if (daysSinceLost < 3) return 1;
    if (daysSinceLost < 7) return 3;
    return daysSinceLost - (daysSinceLost % 7);
  }

  /// Whether an access-lost reminder is **due**.
  ///
  /// **Day 0, day 1, day 3, then every seventh day, indefinitely.**
  ///
  /// Both obvious choices are wrong, in opposite directions. *Notify once* means
  /// a single swipe — on a bus, at 10:00, before the watcher has understood it —
  /// converts a fixable fault into permanent silence, and the surfaces that hold
  /// the condition afterwards (the health panel, the list row) only reach
  /// someone who opens the app, which §13 argues this watcher does not. *Notify
  /// daily* lands in the same channel as the real "No check-in from Mum
  /// yesterday", and training a family to swipe that channel cannot be undone —
  /// worse for a cause they cannot fix, where it would never end.
  ///
  /// So: day 1 catches the swipe while the fault is freshest and most fixable
  /// (a re-sign-in takes seconds), day 3 is a last nudge, and the weekly
  /// heartbeat thereafter is slow enough not to train swiping but frequent
  /// enough that the app never goes quietly inert.
  ///
  /// It does **not** stop. Stopping is exactly the silent inertness this
  /// exists to prevent — the same reasoning as §12's away cap, which forces a
  /// deliberate renewal rather than letting something outlive its purpose
  /// unnoticed. For a cause the watcher genuinely cannot resolve, the escape
  /// belongs in the copy (`screens.md` already says *"ask whoever set up the
  /// app"*), not in going silent.
  ///
  /// The numbers are a judgement call, not a derivation.
  ///
  /// **Due, not "is today a milestone".** The first version asked the latter,
  /// and it fails on exactly the hardware this project is built for: miss the
  /// day-7 wake-up and the next reminder is day 14; miss 7, 14 and 21 — routine
  /// on the HyperOS handset in the device matrix, which is chosen precisely
  /// because it kills background work — and the app is **permanently silent
  /// after day 3**. That is the failure this cadence exists to prevent, so the
  /// question has to be "has a milestone passed that we have not served", which
  /// a device waking late still answers correctly.
  ///
  /// A negative [daysSinceLost] means the clock moved backwards past the day
  /// the loss was recorded. It is treated as due rather than as "not yet",
  /// matching `WarningPolicy`'s choice on the same hazard: prefer speaking.
  static bool isAccessLostReminderDue({
    required int daysSinceLost,
    required int daysSinceLastNotified,
  }) {
    if (daysSinceLost <= 0) return true;
    final servedAt = daysSinceLost - daysSinceLastNotified;
    return accessLostMilestone(daysSinceLost) > accessLostMilestone(servedAt);
  }

  /// Reconciles one link.
  ///
  /// [read] is the tier-1 attempt, made **before** this is called. [now] is the
  /// current instant, [watcherZone] the watcher's own zone from `LocalStore`;
  /// the watched person's zone comes off the link, so no plugin is touched on
  /// this path (ADR-0002).
  ///
  /// [currentlyScheduled] is **required, not defaulted**. §10 says `reconcile()`
  /// "makes reality match — creating what's missing, cancelling what shouldn't
  /// exist", and a convenient default of `{}` would make the short call the
  /// create-only one — the shape [WatchedReconcileResult] warns about, reached
  /// by whoever reads the shortest signature. Pass an empty set deliberately if
  /// the alarms have genuinely not been enumerated.
  static WatcherReconcileResult reconcile({
    required DateTime now,
    required Link link,
    required tz.Location watcherZone,
    required WatcherCache cache,
    required FirestoreRead read,
    required Set<ScheduledWarning> currentlyScheduled,
    int staleAwayAfterDays = WarningPolicy.defaultStaleAwayAfterDays,
  }) {
    final watchedZone = link.watchedZone;

    // 1. Reconcile. A failed read leaves the cache exactly as it was.
    var next = cache.applyRead(read, at: now);

    // 2. Corrections, against days Firestore has *actually* confirmed.
    //
    // Deliberately not "every standing warning at or below lastConfirmedDay":
    // a missed Monday followed by a tapped Tuesday would satisfy that test and
    // retract a warning that was true. Only a check-in for the warned day
    // itself disproves it.
    final confirmed =
        read is ReadSucceeded ? read.checkInDays : const <DayKey>{};
    final corrections = <Correction>[];
    for (final day in cache.warnedDays.toList()) {
      if (confirmed.contains(day)) {
        corrections.add(Correction(linkId: link.id, day: day));
        next = next.withCorrectionFor(day);
      }
    }

    // 3. Decide, against a cache that is now either fresh or knowably stale.
    final decision = WarningPolicy.decide(
      now: now,
      watchedZone: watchedZone,
      away: next.away,
      linkAccepted: link.isAccepted,
      activeFrom: link.activeFrom,
      lastConfirmedDay: next.lastConfirmedDay,
      lastReconcileAt: next.lastReconcileAt,
      verification: read.verification,
      staleAwayAfterDays: staleAwayAfterDays,
    );

    // Access loss is tracked apart from warningsShownFor, which is reserved for
    // claims about the watched person (ADR-0004). Two consequences, both
    // deliberate: the watcher's list row does not read as a missed check-in,
    // and the reminder follows a decaying cadence (day 0, 1, 3, then weekly)
    // rather than firing daily. Notifying daily would be fatigue on the one
    // channel that must not be trained away; notifying only on the transition —
    // the first implementation here — let one swipe buy permanent silence.
    //
    // Everything else notifies when the standing message for D is not the
    // message now owed. Keyed on the day alone this would compare only
    // "has anything been shown", so a 10:00 "your phone has been offline"
    // would still be standing after an 11:00 app-open verified the day and
    // found no check-in — the family left reading a hedge the device has since
    // resolved.
    final withdrawn = <DayKey>[];
    final bool shouldNotify;

    // A standing access-lost notice must be cancelled the moment it stops being
    // true, on either route out of the state. Read from the PRE-refresh cache:
    // applyRead already cleared these fields on a successful read, which is the
    // very case that owes a cancellation.
    final hadStandingAccessNotice = cache.accessLostNotifiedOn != null;
    var cancelAccessLostNotice = false;

    if (!link.isAccepted) {
      // Revocation: the standing warnings are not wrong, they are simply no
      // longer this watcher's business. Withdraw rather than correct — a
      // correction would claim she checked in, which nothing here supports.
      shouldNotify = false;
      withdrawn.addAll(next.warnedDays);
      cancelAccessLostNotice = hadStandingAccessNotice;
      next = next.withWarningsWithdrawn().withAccessRestored();
    } else if (read is ReadRefused) {
      // Keyed on the READ, not on the decision. §13's health item is defined as
      // "the last reconcile was refused" — a fact about the read — so a refusal
      // on a day already settled by a check-in, or before activeFrom, must still
      // turn the panel red and must still anchor the cadence. Gating this on the
      // decision left the panel green while every read was being refused.
      final cause = read.cause;
      final since = next.accessLostSince;
      final notifiedOn = next.accessLostNotifiedOn;
      final owed = decision.outcome == WarningOutcome.warnAccessLost;

      // Dedupe within the day: reconcile() runs on app open, FCM, alarm and
      // boot, so a day-granular cadence would otherwise fire several times.
      // It also bounds a *flapping* cause — permission-denied and
      // unauthenticated can genuinely alternate around a token refresh — to one
      // notification a day rather than one per reconcile.
      final alreadyToday = notifiedOn == decision.day;

      if (!owed || alreadyToday) {
        shouldNotify = false;
      } else if (since == null || next.accessLostCause != cause) {
        // The transition, or a change of remediation: "sign in again" and
        // "update the app" are different instructions, so the standing
        // notification is the wrong one the moment the cause moves.
        shouldNotify = true;
      } else {
        shouldNotify = isAccessLostReminderDue(
          daysSinceLost: decision.day.differenceInDays(since),
          daysSinceLastNotified: notifiedOn == null
              ? decision.day.differenceInDays(since)
              : decision.day.differenceInDays(notifiedOn),
        );
      }

      next = next.withAccessLostOn(decision.day, cause);
      if (shouldNotify) {
        next = next.withAccessLostNotifiedOn(decision.day);
      }
    } else {
      final standing = next.warningsShownFor[decision.day];
      shouldNotify = decision.isWarning &&
          (standing == null || _supersedes(decision.outcome, standing));
      // Only record what is actually on screen. When the new message does not
      // supersede, the old one is still the one showing.
      if (shouldNotify) {
        next = next.withWarningShownFor(decision.day, decision.outcome);
      }
      if (read is ReadSucceeded) {
        cancelAccessLostNotice = hadStandingAccessNotice;
        next = next.withAccessRestored();
      }
    }

    // 4. The rolling window of warning alarms, in the WATCHER's zone and at the
    //    watcher's chosen time — so a watcher abroad is never woken at 03:00.
    //    A revoked link wants none at all, so the diff is pure cancellation.
    final desired = link.isAccepted
        ? _desiredWarnings(
            now: now,
            watcherZone: watcherZone,
            at: link.warningLocalTime,
          )
        : <ScheduledWarning>{};

    return WatcherReconcileResult(
      cache: next,
      decision: decision,
      shouldNotify: shouldNotify,
      corrections: corrections,
      withdrawnWarnings: withdrawn,
      cancelAccessLostNotice: cancelAccessLostNotice,
      previousAway: cache.away,
      desiredWarnings: desired,
      warningsToSchedule: desired.difference(currentlyScheduled),
      warningsToCancel: currentlyScheduled.difference(desired),
    );
  }

  /// Whether [next] is a claim worth replacing [standing] with.
  ///
  /// Only an **upgrade** replaces a standing message. The case this exists for
  /// is a 10:00 alarm that could not reach the server and said *"your phone has
  /// been offline"*, followed by an 11:00 app-open that verified the day and
  /// found no check-in: the family should get the message the device can now
  /// actually support.
  ///
  /// The reverse must not happen. Once a day has been verified, a later failed
  /// read is no reason to walk the claim back to a hedge — that would replace
  /// *"No check-in from Mum yesterday"* with *"your phone has been offline"*,
  /// which is both weaker and, by then, false about the earlier verification.
  /// [WarningOutcome.warnOnline] is the only verified warning, so it is the
  /// only one that supersedes.
  static bool _supersedes(WarningOutcome next, WarningOutcome standing) =>
      next != standing && next == WarningOutcome.warnOnline;

  static Set<ScheduledWarning> _desiredWarnings({
    required DateTime now,
    required tz.Location watcherZone,
    required LocalTimeOfDay at,
  }) {
    final today = DayKey.fromInstant(now, watcherZone);
    return {
      for (final day in today.through(today.plusDays(windowDays - 1)))
        if (day.at(at, watcherZone).isAfter(now))
          ScheduledWarning(day: day, at: day.at(at, watcherZone)),
    };
  }
}
