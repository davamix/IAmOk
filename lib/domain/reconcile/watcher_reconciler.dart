import 'package:timezone/timezone.dart' as tz;

import '../away/away_period.dart';
import '../entities/link.dart';
import '../policy/warning_policy.dart';
import '../time/day_key.dart';
import '../time/local_time_of_day.dart';
import 'firestore_read.dart';
import 'notification_delivery.dart';
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

/// A warning that a late check-in has proved wrong (§10).
///
/// The notification is posted at the **same id**, `hash(link, day)`, so when one
/// is standing the family sees one corrected message rather than two
/// contradictory ones. The id is built at the platform edge in Phase 3; carrying
/// both parts here is what keeps a correction for one watched person from
/// touching a standing warning for another on the same day.
///
/// **"Replaces" is only one of the two routes here**, and the sentence used to
/// claim it was both. A day drained out of [WatcherCache.correctionsOwedFor] had
/// its warning **cancelled by an earlier pass** — the reader's hour had not
/// arrived, or the channel was muted — so there is nothing standing to replace
/// and this is a fresh post. The shared id still earns its keep: it is what
/// prevents a second notification in the case where one *is* standing.
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
    this.catchUpWarnings = const [],
    required this.corrections,
    required this.shouldPostCorrections,
    required this.watchedZoneUnknown,
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

  /// Warnings owed for days **older than `D`**, oldest first — ADR-0009.
  ///
  /// Empty on every ordinary reconcile, because the ordinary window is `{D}`
  /// alone. It fills only when this device could not decide for a day or more:
  /// a fire deferred past local midnight, a phone in a drawer, a force-stop
  /// nobody undid, a flat battery, or the days after a multi-day refused read.
  ///
  /// **Disjoint from [shouldNotify] by construction**, and that is what keeps
  /// this from being a second copy of the same decision: [shouldNotify] is
  /// about `D` and every entry here is strictly older than `D`. The caller posts
  /// both — same channel, same treatment, one notification per day, each at its
  /// own id because [AlarmIds] keys them by `(link, day)`.
  ///
  /// Already delivery-filtered, exactly as [shouldNotify] is: an entry here is a
  /// warning that is owed **and** that the platform can actually post. Days that
  /// could not be delivered are not here and are not marked settled either, so
  /// the next reconcile finds them still owed.
  ///
  /// The copy for these must name the day. Three of the four warning bodies said
  /// *yesterday*, and posting one of those about an older day would be a false
  /// claim to a family in the message whose whole purpose is not to make one —
  /// see [NotificationCopy.warningBody].
  final List<WarningDecision> catchUpWarnings;

  /// Warnings a late check-in has disproved — both the ones this read disproved
  /// and the ones an earlier pass disproved but could not speak about
  /// ([WatcherCache.correctionsOwedFor]).
  ///
  /// A standing notification is **replaced** by the correction message at the
  /// same id — or, when [shouldPostCorrections] is false, simply taken down and
  /// the day left owed. For a day whose warning an earlier pass already
  /// cancelled, nothing is standing and the correction is a fresh post.
  final List<Correction> corrections;

  /// This build's tzdata does not carry `link.watchedTimezone`, so the day was
  /// computed against a **guess**.
  ///
  /// Reachable from a store written by a newer build, a restore, or a zone
  /// renamed upstream between tzdata releases. Nothing here can fix it — the
  /// link is what it is — so the reconcile continues against the watcher's own
  /// zone rather than throwing and taking every remaining link down with it.
  ///
  /// **Carried out because guessing quietly is not the same as guessing.** This
  /// repo's own constraint is that the app's record is not evidence of what the
  /// platform holds; the mirror of that is that a fault the app cannot see is a
  /// fault nobody will ever fix. §13's health panel reads it in Phase 7; until
  /// then the service persists it so it is at least in `dump`.
  final bool watchedZoneUnknown;

  /// Whether [corrections] may be **spoken**, or must be carried out as a bare
  /// cancellation of the warning they retract.
  ///
  /// The warning channel's [NotificationDelivery.postsNotification], and it is
  /// not the same question as whether the retraction is owed. **Three routes
  /// reach it, for three different reasons**, and only two of them mean the
  /// platform cannot post:
  ///
  /// * **`redundant`.** The watcher is looking at the list — that is the whole
  ///   meaning of the state — and the list renders the retraction itself: the
  ///   row goes from the warning to *"Everything OK"* in the same reconcile. A
  ///   notification would be telling someone what they are already reading.
  ///
  ///   **That premise is weaker for a day drained out of
  ///   [WatcherCache.correctionsOwedFor], and the difference is stated rather
  ///   than left to be discovered.** There the warning was cancelled by an
  ///   *earlier* pass, so the row is already *"Everything OK"* before this
  ///   reconcile and **nothing changes under the reader** —
  ///   [WatchedPersonState.checkedInSince] cannot fire either, because the
  ///   previous row was not a warning. The day is consumed and no *"Correction"*
  ///   is said on any channel.
  ///
  ///   It stays honest: the row reads *"Everything OK"* above *"Your phone last
  ///   saw a check-in on Saturday 15 August."*, which is the truth and is what
  ///   the reader is looking at. But it rests on *the row shows the settled
  ///   truth*, not on *the reader watched it change* — a real difference for
  ///   someone who cannot see the row, and the reason this is written down.
  ///
  ///   **Phase 4 widened what `redundant` covers, and one case is now weaker
  ///   than this argument.** It used to mean *the reader just navigated here*,
  ///   so the change happened under their eyes. A foreground FCM nudge makes it
  ///   also mean *the list is open and something arrived* — so a TalkBack user
  ///   who heard "No check-in from Mum yesterday." thirty seconds ago has it
  ///   silently replaced by "Everything OK", with no announcement and no reason
  ///   to swipe back. `WatcherScreen` already owns the mechanism
  ///   (`SemanticsService.sendAnnouncement`).
  ///
  ///   **DECIDED by the owner and BUILT, 2026-08-25: announce it** —
  ///   `WatcherState.userInitiated` plus `WatchedPersonState.checkedInSince`
  ///   for the row that gets better and `WatchedPersonState.warnedSince` for the
  ///   row that gets worse, verified on the POCO F3 with TalkBack running. The
  ///   trigger is narrow on purpose: a person's rendered status **changed** *and*
  ///   the refresh was not user-initiated. Announcing every refresh is noise, and
  ///   on a resume the reader is arriving at the screen anyway.
  ///
  ///   **Both directions ship** (the second approved later the same day). Only
  ///   *any → access lost* remains unapproved, and `rowKind` is what keeps it
  ///   out rather than a guard in the widget. The approved strings are in
  ///   `screens.md`.
  ///
  ///   **This does not change what is POSTED or what is CONSUMED.** `redundant`
  ///   still means no notification and still records the day as seen. An
  ///   announcement is the screen speaking to a reader who is already on it —
  ///   which is the premise this bullet rests on, finally made true for someone
  ///   who cannot see the row change.
  /// * **`unavailable` because the platform cannot post.** `POST_NOTIFICATIONS`
  ///   revoked, or this channel muted. There is no replacement to make **now**.
  ///
  /// * **`unavailable` because the hour has not arrived** —
  ///   [WatcherDelivery.notBefore], ADR-0010. **This one is not the same case**,
  ///   and it is the one a reader of the two above would get wrong: the platform
  ///   can post perfectly well, and the standing warning really was posted and
  ///   really was read — typically by yesterday's alarm under `available`. So
  ///   there is a sentence genuinely owed here, where `redundant` has none.
  ///
  ///   The false claim still comes down immediately, and silently: a correction
  ///   is *good news*, and good news may not wake a family at 00:24.
  ///
  ///   **This bullet used to end "the retraction is genuinely given up … and no
  ///   sentence says it was withdrawn", and that was the defect rather than the
  ///   design.** Both `unavailable` cases now leave the day in
  ///   [WatcherCache.correctionsOwedFor], and the next pass that *can* post
  ///   drains it — so the retraction is late, not lost, which is the rule every
  ///   other consequence of ADR-0010 already followed. See
  ///   [WatcherCache.withCorrectionFor].
  ///
  /// **Cancelling still happens in both**, and it is the load-bearing half.
  /// `cancel` needs no permission, so the muted case genuinely takes a stale
  /// warning out of the tray — on the phone least likely ever to be opened,
  /// which is the one that would otherwise keep a false claim about her
  /// forever. When nothing is showing it is a no-op costing one binder call.
  ///
  /// **An earlier version of this comment argued that `redundant` means the
  /// warning was never posted.** That is wrong in the common case: the standing
  /// warning was typically posted by yesterday's 10:00 alarm under `available`,
  /// and `redundant` describes only *this* reconcile. The tray really does hold
  /// something, and it is cancelled rather than replaced — which is right for
  /// the reason above, not for the reason first given.
  ///
  /// The cache is cleared either way: she checked in, the day is no longer
  /// warned, and leaving it would have the list render a warning about a day
  /// she is on record as having tapped.
  final bool shouldPostCorrections;

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
  ///
  /// [delivery] is **required for the same reason**, and it is the one input
  /// here that is not about the watched person at all: it says whether a
  /// notification decided now would actually reach anyone. A default of
  /// [NotificationDelivery.available] would restore precisely the assumption
  /// that made the access-lost cadence burn itself out on a phone with
  /// `POST_NOTIFICATIONS` revoked — see [NotificationDelivery]. The platform
  /// edge supplies it: `PermissionService` for the revoked case, app lifecycle
  /// for the foreground case, and — since ADR-0010 — the caller's own clock
  /// against `link.warningLocalTime` for the held case
  /// ([WatcherDelivery.notBefore], applied per link in
  /// `WatcherReconcileService._reconcileLink`).
  ///
  /// **This function never derives any part of it**, and that is why the third
  /// supplier is at the edge rather than in here. A parameter the callee
  /// partly computes is a half-truth, and the reader then has to know which
  /// half. It also keeps `WatcherState.warningDelivery` — which drives the
  /// warnings-off banner, a claim about the *channel* — free of a per-link
  /// hour.
  ///
  /// It carries **one state per channel**, because the two notices this side
  /// posts are switched off independently by the reader and ADR-0004 made that
  /// independence load-bearing. Measuring one channel and applying the answer to
  /// both consumed the access-lost cadence for a notice Android had dropped —
  /// see [WatcherDelivery].
  static WatcherReconcileResult reconcile({
    required DateTime now,
    required Link link,
    required tz.Location watcherZone,
    required WatcherCache cache,
    required FirestoreRead read,
    required Set<ScheduledWarning> currentlyScheduled,
    required WatcherDelivery delivery,
    int staleAwayAfterDays = WarningPolicy.defaultStaleAwayAfterDays,
  }) {
    // `tryWatchedZone`, never `watchedZone` — which **throws** `UnknownTimeZone`
    // on a name this build's compiled-in tzdata does not carry. One such link
    // would take down the whole loop: `reconcile()` walks every link in one
    // pass, and the pass that matters most runs in the alarm isolate, where
    // there is no screen, no user and nothing that reports a throw. Every OTHER
    // watched person would stop being checked because of one bad string, and
    // the only symptom is silence — the one failure this side cannot detect in
    // itself.
    //
    // The fallback is the **watcher's** zone rather than UTC. Both are guesses,
    // but this one is right in the overwhelmingly common case — a family in one
    // country — while UTC is wrong by up to a day at the far end of the world,
    // which moves `D` and can warn about a day she has not finished yet.
    //
    // **That argument does not hold on a fresh install**, where the watcher's
    // own zone has not been cached yet and `_watcherZone()` is itself the
    // documented UTC fallback — so the composed answer lands exactly where this
    // comment says it must not. `main()` now caches the device zone before
    // anything reconciles, which closes that window rather than arguing about
    // it; the fallback is stated honestly here so nobody re-derives a guarantee
    // from a preference.
    //
    // It is a fault either way, and [WatcherReconcileResult.watchedZoneUnknown]
    // carries it out so §13's panel has something to render in Phase 7. Guessing
    // quietly is the lesser of two bad outcomes, not a good one — and an
    // unrecorded guess would leave the app with no belief at all about a link it
    // cannot compute the day for.
    final watchedZone = link.tryWatchedZone ?? watcherZone;

    // 1. Reconcile. A failed read leaves the cache exactly as it was.
    var next = cache.applyRead(read, at: now);

    // 2. Corrections, against days Firestore has *actually* confirmed.
    //
    // Deliberately not "every standing warning at or below lastConfirmedDay":
    // a missed Monday followed by a tapped Tuesday would satisfy that test and
    // retract a warning that was true. Only a check-in for the warned day
    // itself disproves it.
    // **`link.isAccepted` is part of the guard, not a separate branch below.**
    // §10 step 2: a revoked link's standing warning is *withdrawn* — cancelled
    // outright, never corrected — because nothing disproves it and *"Mum did
    // check in yesterday"* is a claim the device cannot support about a person
    // this watcher is no longer entitled to read about.
    //
    // Without this, a successful read arriving alongside a revoked link
    // corrected the day here, which removed it from `warnedDays` **before** the
    // withdrawal branch ran — so the day was never withdrawn, and the retraction
    // §10 forbids was posted instead of the cancellation it requires. Reachable
    // today: `SimulatedCheckInReader` answers whatever the harness set,
    // regardless of status, and the harness has a *Revoke every watcher*
    // action. In Phase 4 a revoked link normally reads `permission-denied` — but
    // this function must be correct over its explicit inputs, not over what one
    // backend happens to produce.
    final confirmed = link.isAccepted && read is ReadSucceeded
        ? read.checkInDays
        : const <DayKey>{};

    // **Two sources, one list.** A day the read has just disproved, and a day an
    // earlier pass disproved but could not say so about
    // ([WatcherCache.correctionsOwedFor]).
    //
    // The second is what makes the retraction survive a pass that cannot post.
    // Before it existed the ledger removal below was unconditional while the
    // *warning* path one screen down gated its ledger write on delivery — two
    // lines, opposite policies. Under ADR-0010's hour gate that cost the whole
    // sentence: `cancelWarning` fired, the day left `warningsShownFor`, and the
    // next pass computed corrections from days that were still warned, of which
    // this was no longer one. Nothing anywhere recorded that a retraction was
    // owed, so none was ever posted — for the *"she was fine all along"* case,
    // which is the one a correction exists for.
    //
    // **An owed day does not need the read to succeed.** Its evidence was banked
    // when the correction was first computed and is already in
    // `lastConfirmedDay`; a later refusal does not un-disprove it, and making
    // the retraction wait for a fresh read would strand it behind exactly the
    // outage that is most likely to be what delayed it.
    //
    // **`link.isAccepted` guards both**, and for the owed set it is the whole
    // guard rather than half of one: this loop runs before the revocation branch
    // below clears the set, so without it a revoked link would post the
    // retraction §10 step 2 forbids on the very reconcile that withdraws its
    // warnings.
    final corrections = <Correction>[];
    if (link.isAccepted) {
      // Ungated for `available` and `redundant`, held for `unavailable`. The
      // predicate is `consumesReminder` and not `postsNotification`, because
      // `redundant` means the reader is on the list watching the row correct
      // itself — seeing it on screen is being told.
      final delivered = delivery.warning.consumesReminder;
      final owed = <DayKey>{
        ...cache.warnedDays.where(confirmed.contains),
        ...cache.correctionsOwedFor,
      }.toList()
        ..sort();
      for (final day in owed) {
        corrections.add(Correction(linkId: link.id, day: day));
        next = next.withCorrectionFor(day, delivered: delivered);
      }
    }

    // 3. Decide, against a cache that is now either fresh or knowably stale.
    //
    // **Every completed day this device has not settled, oldest first**
    // (ADR-0009), not only the most recent one. In ordinary daily operation
    // that list is `{D}` and this is exactly the single call it replaced —
    // which is the property that made it safe to change the warning path at
    // all. It grows only when a day or more went by with nothing decided.
    //
    // The whole list is computed here, before any of the branches below mutate
    // `next`, so every day is decided against the same post-read snapshot. A
    // day decided against a cache another day's recording had already moved
    // would be deciding about `D - 2` using what we just concluded about
    // `D - 1`, which is not what any of the six steps mean.
    final refreshed = next;
    final decisions = [
      for (final day in WarningPolicy.daysToDecide(
        now: now,
        watchedZone: watchedZone,
        activeFrom: link.activeFrom,
        lastDecidedDay: refreshed.lastDecidedDay,
      ))
        WarningPolicy.decideFor(
          day: day,
          now: now,
          watchedZone: watchedZone,
          away: refreshed.away,
          linkAccepted: link.isAccepted,
          activeFrom: link.activeFrom,
          lastConfirmedDay: refreshed.lastConfirmedDay,
          lastReconcileAt: refreshed.lastReconcileAt,
          verification: read.verification,
          staleAwayAfterDays: staleAwayAfterDays,
        ),
    ];

    // `daysToDecide` always ends at `D`, so this is always the decision about
    // the current day — which is what every surface below keys on: the
    // access-lost cadence, the watcher row, the withdrawal branch. Nothing that
    // read `decision` before ADR-0009 reads a different thing now.
    final decision = decisions.last;

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
    final catchUp = <WarningDecision>[];
    final bool shouldNotify;

    // A standing access-lost notice must be cancelled the moment it stops being
    // true, on either route out of the state. Read from the PRE-refresh cache:
    // applyRead already cleared these fields on a successful read, which is the
    // very case that owes a cancellation.
    final hadStandingAccessNotice = cache.accessLostNotifiedOn != null;
    var cancelAccessLostNotice = false;

    // Both channels below compute what is OWED, then split it in two:
    //
    //   shouldNotify — post it, only if the platform can actually post.
    //   seen         — record it as standing, unless nothing was delivered.
    //
    // They differ on exactly one state. `redundant` is not posted but IS
    // recorded, because the watcher is looking at the screen that already shows
    // it. `unavailable` is neither, because nothing reached anyone and a
    // reminder nobody received is still owed. Recording on "we decided to
    // speak" rather than "it was delivered" is the defect this closes; see
    // [NotificationDelivery].
    //
    // **Both channels, deliberately.** Fixing one and leaving the other is the
    // exact mistake ADR-0004's clamp made, and it cost two review rounds.

    if (!link.isAccepted) {
      // Revocation: the standing warnings are not wrong, they are simply no
      // longer this watcher's business. Withdraw rather than correct — a
      // correction would claim she checked in, which nothing here supports.
      shouldNotify = false;
      withdrawn.addAll(next.warnedDays);
      cancelAccessLostNotice = hadStandingAccessNotice;
      next = next.withWarningsWithdrawn().withAccessRestored();
      // Every day in the window is settled: a revoked link says nothing at all
      // about any of them, and revocation is final (ADR-0004 decision 7), so
      // there is nothing for a later catch-up to come back for.
      next = next.withLastDecidedDay(decision.day);
    } else if (read is ReadRefused) {
      // Keyed on the READ, not on the decision. §13's health item is defined as
      // "the last reconcile was refused" — a fact about the read — so a refusal
      // on a day already settled by a check-in, or before activeFrom, must still
      // turn the panel red and must still anchor the cadence. Gating this on the
      // decision left the panel green while every read was being refused.
      final cause = read.cause;
      final since = next.accessLostSince;
      final notifiedOn = next.accessLostNotifiedOn;
      final outcomeIsAccessLost =
          decision.outcome == WarningOutcome.warnAccessLost;

      // Dedupe within the day: reconcile() runs on app open, FCM, alarm and
      // boot, so a day-granular cadence would otherwise fire several times.
      // It also bounds a *flapping* cause — permission-denied and
      // unauthenticated can genuinely alternate around a token refresh — to one
      // notification a day rather than one per reconcile.
      final alreadyToday = notifiedOn == decision.day;

      final bool owed;
      if (!outcomeIsAccessLost) {
        owed = false;
      } else if (since == null || next.accessLostCause != cause) {
        // The transition, or a change of remediation: "sign in again" and
        // "update the app" are different instructions, so the standing
        // notification is the wrong one the moment the cause moves.
        //
        // **Checked BEFORE the within-day dedupe, and the order is the whole
        // point.** ADR-0004 decision 5 says a changed cause re-notifies
        // *"whatever the cadence says"*. The first version tested `alreadyToday`
        // first, which silently swallowed exactly that case: a watcher told at
        // 09:00 to sign in again, whose fault becomes an App Check rejection at
        // 09:05, kept the sign-in instruction until the following day. The
        // notification was not merely stale, it was **the wrong thing to do** —
        // and this message exists at all because it is supposed to be
        // actionable.
        //
        // Found on the POCO F3 while testing the cold-start tap: the cause
        // moved to `appCheckRejected` in the store and no notification was
        // posted.
        owed = true;
      } else if (alreadyToday) {
        owed = false;
      } else {
        owed = isAccessLostReminderDue(
          daysSinceLost: decision.day.differenceInDays(since),
          daysSinceLastNotified: notifiedOn == null
              ? decision.day.differenceInDays(since)
              : decision.day.differenceInDays(notifiedOn),
        );
      }

      shouldNotify = owed && delivery.accessLost.postsNotification;

      // Ungated, and deliberately so: this records a fact about the READ — the
      // backend refused us, on this day, for this reason — not a fact about
      // what any human saw. §13's health item and the cadence anchor both key
      // on it, and a phone with notifications revoked is precisely the phone
      // whose panel must still be able to explain itself when it is next
      // opened. Only the *notified-on* stamp below is a record of delivery.
      next = next.withAccessLostOn(decision.day, cause);

      // The cadence's memory. Advancing this on `unavailable` is the failure
      // [NotificationDelivery] exists to prevent: days 0, 1, 3, 7 and 14 would
      // each be consumed in silence, and access returning on day 20 would owe
      // nothing until day 21.
      if (owed && delivery.accessLost.consumesReminder) {
        next = next.withAccessLostNotifiedOn(decision.day);
      }
    } else {
      // One pass over every day this reconcile is deciding about, oldest first
      // (ADR-0009). With the ordinary `{D}` window this is the single-day code
      // it replaced, unrolled once.
      var postForToday = false;

      // ADR-0009's pointer only ever crosses a CONTIGUOUS run of settled days.
      // Stepping over an unsettled one would drop it exactly as the old
      // single-day window dropped everything below `D` — the same defect,
      // reintroduced through the field written to fix it.
      var settledThrough = next.lastDecidedDay;
      var stillContiguous = true;

      for (final each in decisions) {
        final isToday = each.day == decision.day;
        final standing = next.warningsShownFor[each.day];
        final owed = each.isWarning &&
            (isToday || _namesTheDay(each.outcome)) &&
            (standing == null || _supersedes(each.outcome, standing));

        final post = owed && delivery.warning.postsNotification;

        // Only record what is actually on screen. When the new message does not
        // supersede, the old one is still the one showing — and when nothing
        // could be posted at all, nothing is standing, so the next reconcile of
        // the same day must find the warning still owed rather than served.
        final recorded = owed && delivery.warning.consumesReminder;
        if (recorded) {
          next = next.withWarningShownFor(each.day, each.outcome);
        }

        if (post) {
          if (each.day == decision.day) {
            postForToday = true;
          } else {
            catchUp.add(each);
          }
        }

        // Settled: nothing was owed (silent, or a warning already stands), or
        // what was owed actually reached someone. Two cases must NOT settle,
        // and they are different failures:
        //
        //   `owed && !recorded` — the muted phone, NotificationDelivery
        //   .unavailable. Nothing reached anyone, so the day is still owed.
        //
        //   an old day whose warning does not name a day — a
        //   `warnUnverifiableAway` we declined to post above. Nothing was said
        //   about that day at all, so settling it would drop it exactly as the
        //   old single-day window did. Leaving it unsettled is what gets it
        //   decided again once a successful read can say something about HER:
        //   silent if the away really did cover it, warned if the away had been
        //   cancelled and she was expected to tap.
        final settled =
            each.isWarning ? recorded || (!owed && standing != null) : true;
        if (!settled) stillContiguous = false;
        if (stillContiguous && settled) settledThrough = each.day;
      }

      shouldNotify = postForToday;

      if (settledThrough != null) {
        next = next.withLastDecidedDay(settledThrough);
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
      catchUpWarnings: catchUp,
      corrections: corrections,
      shouldPostCorrections: delivery.warning.postsNotification,
      watchedZoneUnknown: link.tryWatchedZone == null,
      withdrawnWarnings: withdrawn,
      cancelAccessLostNotice: cancelAccessLostNotice,
      previousAway: cache.away,
      desiredWarnings: desired,
      warningsToSchedule: desired.difference(currentlyScheduled),
      warningsToCancel: currentlyScheduled.difference(desired),
    );
  }

  /// Whether this outcome is a claim about **one particular day**, and can
  /// therefore be posted for a day that is not today (ADR-0009).
  ///
  /// [WarningOutcome.warnOnline] and [WarningOutcome.warnOffline] name a day
  /// nobody checked in — one message per missed day is one fact per message, and
  /// the copy dates each one.
  ///
  /// [WarningOutcome.warnUnverifiableAway] is not that. It is present tense —
  /// *this phone cannot check, and she was marked away until Saturday* — a claim
  /// about the cache's staleness right now rather than about any day. Caught up
  /// across a six-day gap it would post six notifications differing only in a
  /// date that is not what any of them is actually about, on the one channel §1
  /// is built to keep un-swipeable. A test caught that before this shipped.
  ///
  /// So an older day with that outcome is not posted **and is not settled**: the
  /// day was never spoken about, and the pointer stops below it. Once a read
  /// succeeds, that day is decided again on evidence rather than on a stale
  /// cache — silent if the away really covered it, warned if the away had been
  /// cancelled and she was expected to tap.
  ///
  /// [WarningOutcome.warnAccessLost] cannot reach here — the refused branch
  /// above owns it, has its own decaying cadence, and deliberately advances no
  /// pointer.
  static bool _namesTheDay(WarningOutcome outcome) =>
      outcome == WarningOutcome.warnOnline ||
      outcome == WarningOutcome.warnOffline;

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
  ///
  /// **This holds within one reconcile, not globally, and Phase 4 added the
  /// third writer.** ADR-0006 gates only *alarm changes* on the lease — a run
  /// that cannot take it still reads, decides and speaks — and
  /// `saveWatcherCache` is last-write-wins. So two reconciles that both load the
  /// cache before either writes, with different read outcomes, can post at the
  /// same notification id in the wrong order: a verified warning replaced by a
  /// hedge from a run that failed its read, on a device that read Firestore
  /// seconds earlier. ADR-0006 enumerated the two properties holding the
  /// *access-lost* channel up against exactly this; the warning channel had no
  /// equivalent note and this docstring asserted the property unconditionally.
  ///
  /// Narrow — it needs two reconciles overlapping across a lease boundary — and
  /// recorded rather than closed. Closing it means re-reading `warningsShownFor`
  /// immediately before posting instead of trusting the snapshot taken at step 1.
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
