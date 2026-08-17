import 'dart:math';

import 'package:timezone/timezone.dart' as tz;

import '../copy/notification_copy.dart';
import '../data/check_in_reader.dart';
import '../data/local_store.dart';
import '../domain/domain.dart';
import '../platform/clock.dart';
import '../platform/notification_service.dart';
import '../platform/warning_alarm_scheduler.dart';

/// One watched person, as the watcher's screen renders them.
class WatchedPersonState {
  const WatchedPersonState({
    required this.link,
    required this.cache,
    required this.decision,
  });

  final Link link;
  final WatcherCache cache;

  /// What the last reconcile concluded about `D`.
  final WarningDecision decision;

  String get name => link.watchedName;

  /// Whether the app currently cannot read this person's check-ins
  /// (ADR-0004). Drives the row that the *lost access* notification opens onto.
  bool get hasLostAccess => cache.hasLostAccess;

  /// A standing warning, if one is unresolved.
  ///
  /// **State, not history** — `docs/ui-ux/guidelines.md`. A warning from three
  /// weeks ago followed by three weeks of check-ins is history, and rendering it
  /// as status would have the app reporting a crisis that resolved itself.
  WarningOutcome? get standingWarning =>
      cache.warningsShownFor[decision.day] ??
      (cache.warningsShownFor.isEmpty
          ? null
          : cache.warningsShownFor[cache.warnedDays
              .reduce((a, b) => a > b ? a : b)]);
}

/// Everything the watcher's screen needs, as of one reconcile.
class WatcherState {
  const WatcherState({required this.people, required this.today});

  final List<WatchedPersonState> people;
  final DayKey today;

  bool get isEmpty => people.isEmpty;
}

/// The watcher side's one idempotent entry point — **reconcile first, then
/// decide** (§10, ADR-0001).
///
/// Called on app open, on alarm fire, on boot, and from Phase 4's FCM handler.
/// The alarm isolate and the UI both land here, which is why nothing in it may
/// touch Flutter, Riverpod or `flutter_timezone`; `domain_purity_test.dart`
/// names this file.
///
/// ## The order is the design
///
/// 1. Attempt the tier-1 read. **Before** any cache is consulted — consulting
///    the cache first inverts §3's tiering and lets a stale cached away silence
///    a watcher for as long as the period has left to run. Sixteen days in
///    ADR-0001's modelled scenario, in a state §17 rates as indistinguishable
///    from working.
/// 2. Hand the read, the cache and the link to the pure reconciler.
/// 3. Execute what it decided: post, correct, withdraw, arm, disarm.
/// 4. Persist the cache it returned — **one write**.
///
/// The decision itself is `WatcherReconciler` + `WarningPolicy`, both pure and
/// both fully tested without a device. This class contains no branch that
/// decides whether to speak; it only carries out what was decided. That
/// separation is what lets the riskiest logic in the app be exercised in
/// milliseconds.
class WatcherReconcileService {
  const WatcherReconcileService({
    required this.store,
    required this.clock,
    required this.reader,
    required this.notifications,
    required this.alarms,
    required this.delivery,
    this.lockOwner = 'ui',
  });

  final LocalStore store;
  final Clock clock;
  final CheckInReader reader;
  final WatcherNotifications notifications;
  final WarningAlarmScheduler alarms;

  /// Whether a notification decided now would actually reach anyone.
  ///
  /// Asked afresh on every reconcile, never cached: Android can revoke
  /// `POST_NOTIFICATIONS` at any moment and auto-revokes it from apps nobody
  /// opens — which §13 rates High precisely because that describes the watcher.
  ///
  /// **The Phase 2 brief's "until they exist, pass `available`" no longer
  /// applies.** Passing a constant here re-opens the defect
  /// `NotificationDelivery` was added to close: the access-lost cadence burns
  /// days 0, 1, 3, 7 and 14 in silence on a muted phone, and access returning on
  /// day 20 owes nothing until day 21.
  final Future<NotificationDelivery> Function() delivery;

  final String lockOwner;

  static const Duration lockLease = Duration(seconds: 30);

  static final int _isolateSalt = Random().nextInt(0x7fffffff);
  static int _sequence = 0;

  /// Reconciles every link this user watches, and returns what to render.
  ///
  /// Every link, on every fire, rather than the one link an alarm was armed
  /// for. §3: nothing is transmitted as a command — an alarm fire is a *nudge to
  /// reconcile*, carrying no authority about which person it concerns. Keying
  /// the work to the alarm's own id would mean a single dropped alarm leaves one
  /// watched person unreconciled with nothing to notice it.
  Future<WatcherState> reconcile({required String selfUid}) async {
    final now = clock.now();
    final watcherZone = await _watcherZone();
    final links = await store.linksWatchedBy(selfUid);
    final canDeliver = await delivery();

    final owner = '$lockOwner:$_isolateSalt:${_sequence++}';
    final holdsLock = await store.acquireReconcileLock(
      owner: owner,
      now: now,
      lease: lockLease,
    );

    final people = <WatchedPersonState>[];
    try {
      for (final link in links) {
        people.add(await _reconcileLink(
          link: link,
          now: now,
          watcherZone: watcherZone,
          delivery: canDeliver,
          mayChangeAlarms: holdsLock,
        ));
      }
    } finally {
      if (holdsLock) await store.releaseReconcileLock(owner);
    }

    return WatcherState(
      people: people,
      today: DayKey.fromInstant(now, watcherZone),
    );
  }

  Future<WatchedPersonState> _reconcileLink({
    required Link link,
    required DateTime now,
    required tz.Location watcherZone,
    required NotificationDelivery delivery,
    required bool mayChangeAlarms,
  }) async {
    // 1. Tier 1 first. A failed read is a value, never a throw — the difference
    //    between "could not reach" and "was refused" is the whole of ADR-0004,
    //    and an exception collapses it to one bit.
    final read = await reader.read(link);

    final cache = await store.watcherCache(link.id);
    final armed = await store.pendingWarnings(link.id);

    final result = WatcherReconciler.reconcile(
      now: now,
      link: link,
      watcherZone: watcherZone,
      cache: cache,
      read: read,
      currentlyScheduled: armed,
      delivery: delivery,
    );

    // 2. Corrections FIRST, before any new warning is posted.
    //
    //    They replace a standing warning at the same id, so a correction applied
    //    after a fresh warning for the same day would silently overwrite the
    //    warning that was just, correctly, raised. The domain never produces
    //    both for one day — a corrected day leaves `warningsShownFor` — but the
    //    ordering is free and the failure it prevents is a false all-clear.
    for (final correction in result.corrections) {
      await notifications.showCorrection(
        linkId: correction.linkId,
        day: correction.day,
        body: NotificationCopy.correctionBody(
          watchedName: link.watchedName,
          // Phase 3 has no per-check-in timestamp from the fake backend, so the
          // correction is stamped with the moment it was learned rather than the
          // moment she tapped. Phase 4 carries `deviceTappedAt` through the read
          // and this becomes the real value — recorded rather than left as a
          // silent approximation, because "at 23:40" is a claim about her.
          tappedAt: now,
          watcherZone: watcherZone,
        ),
      );
    }

    // 3. Withdrawals: cancelled outright, with no replacement message.
    //    Nothing here disproves the warning — the link was revoked — so a
    //    correction would claim she checked in, which the device cannot support.
    for (final day in result.withdrawnWarnings) {
      await notifications.cancelWarning(link.id, day);
    }

    if (result.cancelAccessLostNotice) {
      await notifications.cancelAccessLost(link.id);
    }

    // 4. The warning itself, if one is owed AND the platform can post it.
    //    `shouldNotify` already folds in the delivery state; re-deciding here
    //    would be a second opinion about a question the domain answered.
    if (result.shouldNotify) {
      final body = NotificationCopy.warningBody(
        outcome: result.decision.outcome,
        watchedName: link.watchedName,
        day: result.decision.day,
        away: result.decision.away,
        unverifiedSince: result.decision.unverifiedSince,
        lastConfirmedDay: result.decision.lastConfirmedDay,
        watcherZone: watcherZone,
      );
      if (result.decision.outcome == WarningOutcome.warnAccessLost) {
        // A different channel, deliberately: a watcher who mutes app faults must
        // still hear about a missed day (ADR-0004).
        await notifications.showAccessLost(linkId: link.id, body: body);
      } else {
        await notifications.showWarning(
          linkId: link.id,
          day: result.decision.day,
          body: body,
        );
      }
    }

    // 5. The alarm window — only under the reconcile lease (ADR-0006).
    //
    //    **The decision above is never skipped; only this is.** A run that
    //    cannot take the lock has still read, still decided and still spoken,
    //    which is what makes the lease safe on the side where silence is the
    //    failure that cannot be detected. Two concurrent runs changing the alarm
    //    set is what strands an alarm nothing can cancel.
    if (mayChangeAlarms) {
      await alarms.apply(
        linkId: link.id,
        toCancel: result.warningsToCancel,
        desired: result.desiredWarnings,
      );
      await store.replacePendingWarnings(link.id, result.desiredWarnings);
    }

    // 6. One write, after the platform calls returned.
    await store.saveWatcherCache(link.id, result.cache);

    return WatchedPersonState(
      link: link,
      cache: result.cache,
      decision: result.decision,
    );
  }

  /// The watcher's own cached zone, falling back to UTC.
  ///
  /// Read from `LocalStore`, never from `flutter_timezone` — this runs in the
  /// alarm isolate and ADR-0002 decision 2 forbids a plugin call there. The
  /// **watched** person's zone is a different question and comes off the link,
  /// which is why no plugin is touched on this path at all.
  Future<tz.Location> _watcherZone() async {
    final name = await store.deviceTimezone();
    if (name == null) return TimeZones.utc;
    return TimeZones.tryLocation(name) ?? TimeZones.utc;
  }
}
