import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  Link linkTo(String watchedUid, {String zone = 'Etc/UTC', String? from}) => Link(
        watchedUid: watchedUid,
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: watchedUid,
        watcherName: 'Ana',
        watchedTimezone: zone,
        activeFrom: day(from ?? '2026-07-01'),
        createdAt: at(utc, 2026, 7, 1),
      );

  final mum = linkTo('mum');
  final now = at(utc, 2026, 8, 6, 10); // D = 2026-08-05
  final theDay = day('2026-08-05');

  WatcherReconcileResult reconcile({
    Link? link,
    WatcherCache cache = const WatcherCache.empty(),
    FirestoreRead? read,
    DateTime? when,
    Set<ScheduledWarning> currentlyScheduled = const {},
    NotificationDelivery delivery = NotificationDelivery.available,
  }) =>
      WatcherReconciler.reconcile(
        now: when ?? now,
        link: link ?? mum,
        watcherZone: utc,
        cache: cache,
        read: read ?? const FirestoreRead.succeeded(),
        currentlyScheduled: currentlyScheduled,
        delivery: WatcherDelivery.uniform(delivery),
      );

  group('reconcile first, then decide — ADR-0001 decision 1', () {
    test('a successful read refreshes the cache before the decision runs', () {
      final result = reconcile(
        cache: WatcherCache(
          away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20')),
          lastReconcileAt: at(utc, 2026, 8, 1),
        ),
      );
      expect(result.cache.away, isNull, reason: 'Firestore returned nothing');
      expect(result.cache.lastReconcileAt, now);
      expect(result.decision.outcome, WarningOutcome.warnOnline);
    });

    // ADR-0004 splits failure for MESSAGE selection but not for CACHE
    // retention, so these two differ in outcome and agree on the cache.
    final holiday =
        AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));
    final freshAway = WatcherCache(
      away: holiday,
      lastReconcileAt: at(utc, 2026, 8, 5, 9),
    );

    test('an unreachable read leaves the cache exactly as it was', () {
      final result = reconcile(
        cache: freshAway,
        read: const FirestoreRead.unreachable(UnreachableCause.timeout),
      );
      expect(result.cache.away, holiday);
      expect(result.cache.lastReconcileAt, at(utc, 2026, 8, 5, 9),
          reason: 'a failed read must not stamp a successful reconcile');
      expect(result.decision.outcome, WarningOutcome.silent,
          reason: 'the cached away is still inside the staleness bound');
    });

    test('a refused read leaves the cache exactly as it was too', () {
      final result = reconcile(
        cache: freshAway,
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(result.cache.away, holiday,
          reason: 'ADR-0001 is unchanged — no failed read may clear the cache');
      expect(result.cache.lastReconcileAt, at(utc, 2026, 8, 5, 9));
      expect(result.decision.outcome, WarningOutcome.warnAccessLost,
          reason: 'but the MESSAGE differs — ADR-0004');
    });
  });

  group('the push carries no authority', () {
    test('an FCM nudge with Firestore unreachable moves nothing', () {
      // The payload carries {watchedUid, date, deviceTappedAt, tz, watchedName}
      // and looks authoritative, which is exactly why trusting it is the
      // tempting shortcut (§3). A nudge means "reconcile now", nothing more.
      final result = reconcile(
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(result.cache.lastConfirmedDay, isNull);
      expect(result.cache.lastReconcileAt, isNull);
      expect(result.decision.outcome, WarningOutcome.warnOffline);
    });
  });

  group('the correction path', () {
    final warned = WatcherCache(
      warningsShownFor: {theDay: WarningOutcome.warnOnline},
      lastReconcileAt: at(utc, 2026, 8, 6, 9),
    );

    test('a late check-in for a warned day produces a correction', () {
      final result = reconcile(
        cache: warned,
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );
      expect(result.corrections, [Correction(linkId: mum.id, day: theDay)]);
      expect(result.cache.warningsShownFor, isEmpty);
      expect(result.cache.lastConfirmedDay, theDay);
      expect(result.decision.outcome, WarningOutcome.silent);
      expect(result.decision.silenceReason, SilenceReason.checkInRecorded);
    });

    test('the warned day is picked out of a read carrying several', () {
      // **This was two tests, named "offline sync" and "FCM deferred until
      // morning".** Neither expressed a cause: the reconciler takes a
      // `FirestoreRead`, and there is no offline-sync input and no FCM input to
      // vary. They were the same test written twice with two names, and they
      // read as satisfying `strategy.md`'s "two causes, one handler; test both"
      // while asserting one thing once.
      //
      // The half worth keeping is the one difference between them: the read
      // carried an unrelated extra day, so this pins that the correction is for
      // the **warned** day rather than for whatever the read happened to
      // contain. `the push carries no authority` (above) is the real second
      // case, and the genuine two-causes test belongs in Phase 4, where an FCM
      // payload exists to be one.
      final result = reconcile(
        cache: warned,
        read: FirestoreRead.succeeded(checkInDays: {theDay, day('2026-08-04')}),
      );
      expect(result.corrections, [Correction(linkId: mum.id, day: theDay)]);
    });

    test('a REVOKED link withdraws rather than corrects, even on a good read',
        () {
      // §10 step 2: nothing disproves the warning — the link simply ended — so
      // *"Mum did check in yesterday"* is a claim the device cannot support
      // about someone this watcher is no longer entitled to read about.
      //
      // The corrections loop runs before the revocation branch, so an
      // unguarded correction removed the day from `warnedDays` first and the
      // withdrawal then had nothing to withdraw. The retraction §10 forbids
      // was posted instead of the cancellation it requires.
      final result = reconcile(
        link: mum.copyWith(status: LinkStatus.revoked),
        cache: warned,
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );

      expect(result.corrections, isEmpty,
          reason: 'no claim about her may be made on a revoked link');
      expect(result.withdrawnWarnings, [theDay],
          reason: 'cancelled outright, with no replacement message');
      expect(result.cache.warningsShownFor, isEmpty);
    });

    test('a later check-in does NOT retract an earlier true warning', () {
      // Mum missed Monday and tapped Tuesday. The Monday warning was true and
      // must stand. A "lastConfirmedDay >= warned day" test would wrongly
      // retract it — only a check-in for the warned day itself disproves it.
      final monday = day('2026-08-03');
      final result = reconcile(
        cache: WatcherCache(
          warningsShownFor: {monday: WarningOutcome.warnOnline},
          lastReconcileAt: at(utc, 2026, 8, 6, 9),
        ),
        read: FirestoreRead.succeeded(checkInDays: {day('2026-08-04'), theDay}),
      );
      expect(result.corrections, isEmpty);
      expect(result.cache.warningsShownFor, {monday: WarningOutcome.warnOnline});
    });

    test('no correction when the read failed', () {
      final result = reconcile(
        cache: warned,
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(result.corrections, isEmpty);
      expect(result.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline});
    });
  });

  group('a standing message is replaced only by a stronger one', () {
    test('an unverified hedge is replaced once the day is verified', () {
      // 10:00: the alarm could not reach the server. 11:00: the watcher opens
      // the app, the read succeeds, and there is genuinely no check-in. The
      // family must get the message the device can now support, not be left
      // reading a hedge it has since resolved.
      final hedged = reconcile(
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(hedged.decision.outcome, WarningOutcome.warnOffline);
      expect(hedged.shouldNotify, isTrue);

      final verified = reconcile(cache: hedged.cache);
      expect(verified.decision.outcome, WarningOutcome.warnOnline);
      expect(verified.shouldNotify, isTrue, reason: 'a stronger claim');
      expect(verified.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline});
    });

    test('a verified claim is NOT walked back to a hedge', () {
      // The reverse must not happen: once the day is verified, a later failed
      // read is no reason to replace "No check-in from Mum yesterday" with
      // "your phone has been offline".
      final verified = reconcile();
      expect(verified.decision.outcome, WarningOutcome.warnOnline);

      final later = reconcile(
        cache: verified.cache,
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(later.decision.outcome, WarningOutcome.warnOffline);
      expect(later.shouldNotify, isFalse);
      expect(later.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline},
          reason: 'the cache records what is on screen, not what was computed');
    });

    test('the same message twice never re-notifies', () {
      final first = reconcile(
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      final second = reconcile(
        cache: first.cache,
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(second.shouldNotify, isFalse);
      expect(second.cache, first.cache);
    });
  });

  group('tapping during an away day is still allowed', () {
    test('the check-in is recorded and silences on its own merits', () {
      // §12 allows it: harmless, reassuring, and it writes a normal check-in
      // that watchers see as usual. The plausible bug is suppressing the write
      // along with the reminders — so the silence here must come from the
      // check-in, not from the away period.
      final holiday =
          AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));
      final result = reconcile(
        read: FirestoreRead.succeeded(checkInDays: {theDay}, away: holiday),
      );
      expect(result.cache.lastConfirmedDay, theDay);
      expect(result.decision.silenceReason, SilenceReason.checkInRecorded,
          reason: 'evidence outranks doubt — not awayVerified');
      expect(result.cache.away, holiday, reason: 'still away, still recorded');
    });
  });

  group('notification identity across links', () {
    test('a correction for one watched person leaves the other standing', () {
      // A watcher has 1..n watched people and warnings can stand for two of
      // them on the same D. Corrections carry the link id so the platform edge
      // can address hash(link, D) and not the other person's notification.
      final dad = linkTo('dad');
      final mumResult = reconcile(
        link: mum,
        cache: WatcherCache(
          warningsShownFor: {theDay: WarningOutcome.warnOnline},
          lastReconcileAt: at(utc, 2026, 8, 6, 9),
        ),
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );
      final dadResult = reconcile(
        link: dad,
        cache: WatcherCache(
          warningsShownFor: {theDay: WarningOutcome.warnOnline},
          lastReconcileAt: at(utc, 2026, 8, 6, 9),
        ),
        read: const FirestoreRead.succeeded(),
      );

      expect(mumResult.corrections.single.linkId, 'mum_ana');
      expect(mumResult.cache.warningsShownFor, isEmpty);

      expect(dadResult.corrections, isEmpty);
      expect(dadResult.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline},
          reason: "dad's standing warning is untouched");
    });

    test("a watcher's own zone never changes which day is asked about", () {
      // D comes from the WATCHED person's zone on the link, so a travelling
      // watcher cannot shift the question. Asserted here rather than on DayKey,
      // because this is the only layer where a watcher zone exists at all.
      final asked = <DayKey>{};
      for (final watcherZone in [madrid, auckland, honolulu, newYork, utc]) {
        asked.add(
          WatcherReconciler.reconcile(
            now: at(utc, 2026, 8, 6, 10),
            link: mum,
            watcherZone: watcherZone,
            cache: const WatcherCache.empty(),
            read: const FirestoreRead.succeeded(),
            currentlyScheduled: const {},
            delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
          ).decision.day,
        );
      }
      expect(asked, {theDay});
    });
  });

  group('idempotence — shouldNotify, not just the decision', () {
    test('the first reconcile notifies, the second does not', () {
      final first = reconcile();
      expect(first.decision.outcome, WarningOutcome.warnOnline);
      expect(first.shouldNotify, isTrue);
      expect(first.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline});

      final second = reconcile(cache: first.cache);
      expect(second.decision.outcome, WarningOutcome.warnOnline,
          reason: 'the day is still un-checked-in — §10 still says warn');
      expect(second.shouldNotify, isFalse,
          reason: 'a warning already stands; app open must not re-notify');
      expect(second.cache, first.cache, reason: 'no state changed');
    });

    test('a third run still changes nothing', () {
      final settled = reconcile(cache: reconcile().cache).cache;
      final again = reconcile(cache: settled);
      expect(again.shouldNotify, isFalse);
      expect(again.cache, settled);
    });

    test('a silent reconcile run twice is a no-op both times', () {
      final first = reconcile(
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );
      expect(first.shouldNotify, isFalse);
      final second = reconcile(
        cache: first.cache,
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );
      expect(second.cache, first.cache);
    });
  });

  group('the warning alarm window', () {
    test('covers 7 watcher-local days at the link warning time', () {
      final result = reconcile(when: at(utc, 2026, 8, 6, 9));
      expect(result.desiredWarnings, hasLength(7));
      expect(result.desiredWarnings.every((w) => w.at.hour == 10), isTrue);
    });

    test('fires at watcher-local time, not watched-local', () {
      // Watched person in Auckland, watcher in Madrid. The alarm must be at
      // 10:00 Madrid — a watcher abroad is never woken at 03:00 (§11).
      final result = WatcherReconciler.reconcile(
        now: at(madrid, 2026, 8, 17, 6),
        link: linkTo('mum', zone: 'Pacific/Auckland'),
        watcherZone: madrid,
        cache: const WatcherCache.empty(),
        read: const FirestoreRead.succeeded(),
        currentlyScheduled: const {},
        delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
      );
      for (final warning in result.desiredWarnings) {
        expect(DayKey.fromInstant(warning.at, madrid), warning.day);
        expect(warning.at.hour, 10);
      }
    });

    test('today is dropped once its warning time has passed', () {
      final result = reconcile(when: at(utc, 2026, 8, 6, 11));
      expect(result.desiredWarnings, hasLength(6));
      expect(result.desiredWarnings.map((w) => w.day),
          isNot(contains(day('2026-08-06'))));
    });

    test('is not cancelled during an away period', () {
      // Each fire re-verifies against Firestore, which is how an away cancelled
      // remotely is picked up even when every push was lost. Cancelling and
      // re-arming would be cheaper and less correct.
      final holiday =
          AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));
      final result = reconcile(
        when: at(utc, 2026, 8, 6, 9),
        read: FirestoreRead.succeeded(away: holiday),
      );
      expect(result.decision.outcome, WarningOutcome.silent);
      expect(result.desiredWarnings, hasLength(7));
    });

    test('cancels what should no longer exist', () {
      final stale = ScheduledWarning(
        day: day('2026-07-30'),
        at: day('2026-07-30').at(const LocalTimeOfDay(10, 0), utc),
      );
      final result = reconcile(
        when: at(utc, 2026, 8, 6, 9),
        currentlyScheduled: {stale},
      );
      expect(result.warningsToCancel, {stale});
      expect(result.warningsToSchedule, hasLength(7));
    });

    test('a changed warningLocalTime rebuilds the window', () {
      // §6 gives LinkRepository a per-link warning time. If alarm identity were
      // the day alone, moving 10:00 to 08:00 would produce an empty diff and
      // nothing would happen for a week.
      final armed = reconcile(when: at(utc, 2026, 8, 6, 6)).desiredWarnings;
      final moved = reconcile(
        link: mum.copyWith(warningLocalTime: const LocalTimeOfDay(8, 0)),
        when: at(utc, 2026, 8, 6, 6),
        currentlyScheduled: armed,
      );

      expect(moved.warningsToCancel, hasLength(7));
      expect(moved.warningsToSchedule, hasLength(7));
      expect(moved.isNoOp, isFalse);
      expect(moved.desiredWarnings.every((w) => w.at.hour == 8), isTrue);
      expect(moved.warningsToCancel.every((w) => w.at.hour == 10), isTrue);
    });

    test('a revoked link wants no warning alarms at all', () {
      final armed = reconcile(when: at(utc, 2026, 8, 6, 9)).desiredWarnings;
      final result = reconcile(
        link: mum.copyWith(status: LinkStatus.revoked),
        when: at(utc, 2026, 8, 6, 9),
        currentlyScheduled: armed,
      );
      expect(result.desiredWarnings, isEmpty);
      expect(result.warningsToCancel, armed);
      expect(result.warningsToSchedule, isEmpty);
    });

    test('reconciling against its own schedule is a no-op', () {
      final first = reconcile(
        when: at(utc, 2026, 8, 6, 9),
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      );
      final second = reconcile(
        when: at(utc, 2026, 8, 6, 9),
        cache: first.cache,
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
        currentlyScheduled: first.desiredWarnings,
      );
      expect(second.isNoOp, isTrue);
    });
  });

  group('access lost — ADR-0004, at the reconciler', () {
    test('a refused read warns, notifies once, and records the day', () {
      final first = reconcile(
        read: const FirestoreRead.refused(RefusedCause.appCheckRejected),
      );
      expect(first.decision.outcome, WarningOutcome.warnAccessLost);
      expect(first.shouldNotify, isTrue);
      expect(first.cache.accessLostSince, theDay);
      expect(first.cache.accessLostCause, RefusedCause.appCheckRejected);
      expect(first.cache.warningsShownFor, isEmpty,
          reason: 'an access failure is not a claim about the watched person — '
              'recording it here would make the list row demand attention');

      // Idempotent like any other warning: app open must not re-notify.
      final second = reconcile(
        cache: first.cache,
        read: const FirestoreRead.refused(RefusedCause.appCheckRejected),
      );
      expect(second.shouldNotify, isFalse);
      expect(second.cache, first.cache);
    });

    group('the reminder cadence — day 0, 1, 3, then weekly', () {
      /// Due, assuming the device woke and notified every previous milestone.
      bool dueOn(int day, {int? lastNotified}) =>
          WatcherReconciler.isAccessLostReminderDue(
            daysSinceLost: day,
            daysSinceLastNotified:
                day - (lastNotified ?? WatcherReconciler.accessLostMilestone(day - 1)),
          );

      test('the schedule itself, on a device that wakes every day', () {
        // Both extremes are wrong: notify-once means one swipe buys permanent
        // silence; notify-daily trains the family to swipe the channel that
        // carries the real warning.
        for (final d in [0, 1, 3, 7, 14, 21, 70]) {
          expect(dueOn(d), isTrue, reason: 'day $d is a reminder day');
        }
        for (final d in [2, 4, 5, 6, 8, 13, 15, 69]) {
          expect(dueOn(d), isFalse, reason: 'day $d is not');
        }
      });

      test('it never stops — silence is what this exists to prevent', () {
        expect(dueOn(364), isTrue);
      });

      test('a MISSED reminder day is served late, not skipped', () {
        // The failure this predicate exists to avoid. Asking "is today a
        // milestone" instead of "has a milestone passed unserved" means a device
        // asleep on day 7 waits until day 14 — and one asleep on 7, 14 and 21
        // goes permanently silent after day 3. On the HyperOS handset in the
        // device matrix, chosen precisely because it kills background work,
        // that is the expected case rather than an edge one.
        expect(
          WatcherReconciler.isAccessLostReminderDue(
              daysSinceLost: 8, daysSinceLastNotified: 5),
          isTrue,
          reason: 'last served day 3, milestone 7 has passed',
        );
        expect(
          WatcherReconciler.isAccessLostReminderDue(
              daysSinceLost: 22, daysSinceLastNotified: 19),
          isTrue,
          reason: 'asleep through 7, 14 and 21 — still owed',
        );
      });

      test('a backwards clock speaks rather than going quiet', () {
        // Mirrors WarningPolicy's choice on the same hazard. A negative gap
        // means the clock moved back past the day the loss was recorded;
        // treating it as "not yet" would silence the cadence for the duration
        // of the skew.
        expect(
          WatcherReconciler.isAccessLostReminderDue(
              daysSinceLost: -7, daysSinceLastNotified: -7),
          isTrue,
        );
      });

      test('the milestone helper buckets correctly', () {
        expect(WatcherReconciler.accessLostMilestone(0), 0);
        expect(WatcherReconciler.accessLostMilestone(1), 1);
        expect(WatcherReconciler.accessLostMilestone(2), 1);
        expect(WatcherReconciler.accessLostMilestone(3), 3);
        expect(WatcherReconciler.accessLostMilestone(6), 3);
        expect(WatcherReconciler.accessLostMilestone(7), 7);
        expect(WatcherReconciler.accessLostMilestone(13), 7);
        expect(WatcherReconciler.accessLostMilestone(14), 14);
      });

      /// Reconciles from the day access was lost through [throughDay], but only
      /// on the days in [awakeOn] — the device is asleep on the rest. Reports
      /// which days actually notified.
      List<int> notifyingDays(int throughDay, {Set<int>? awakeOn}) {
        var cache = const WatcherCache.empty();
        final firing = <int>[];
        for (var i = 0; i <= throughDay; i++) {
          if (awakeOn != null && !awakeOn.contains(i)) continue;
          final result = reconcile(
            when: at(utc, 2026, 8, 6, 10).add(Duration(days: i)),
            cache: cache,
            read: const FirestoreRead.refused(RefusedCause.unauthenticated),
          );
          cache = result.cache;
          if (result.shouldNotify) firing.add(i);
        }
        return firing;
      }

      test('over three weeks it fires on 0, 1, 3, 7, 14 and 21', () {
        expect(notifyingDays(21), [0, 1, 3, 7, 14, 21]);
      });

      test('an intermittent device is still reminded, just late', () {
        // The traffic pattern this project cannot assume away: the device
        // matrix is built around an OEM that kills background work, so on many
        // days the only reconcile is a warning alarm that may not fire. A
        // schedule of exact days would return [0, 1, 3] here and then nothing,
        // ever.
        expect(notifyingDays(21, awakeOn: {0, 1, 3, 8, 9, 10, 22}),
            contains(8));
        expect(notifyingDays(30, awakeOn: {0, 1, 3, 25}), contains(25),
            reason: 'asleep through 7, 14 and 21 — still served on waking');
      });

      test('four reconciles on one day produce one notification', () {
        // app open, FCM arrival, alarm fire, boot — all call reconcile().
        var cache = const WatcherCache.empty();
        var notified = 0;
        for (var i = 0; i < 4; i++) {
          final result = reconcile(
            cache: cache,
            read: const FirestoreRead.refused(RefusedCause.unauthenticated),
          );
          cache = result.cache;
          if (result.shouldNotify) notified++;
        }
        expect(notified, 1);
      });

      test('a changed cause re-notifies whatever the cadence says', () {
        // Day 2 is not a reminder day, but "sign in again" and "update the app"
        // are different instructions — the standing notification is now wrong.
        // Days 0 and 1 both served, so day 2 owes nothing on the cadence alone.
        final day0 = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        final day1 = reconcile(
          when: at(utc, 2026, 8, 7, 10),
          cache: day0.cache,
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        expect(day1.shouldNotify, isTrue, reason: 'day 1 is a milestone');

        final quietDay = reconcile(
          when: at(utc, 2026, 8, 8, 10),
          cache: day1.cache,
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        expect(quietDay.shouldNotify, isFalse, reason: 'day 2, same cause');

        final causeChanged = reconcile(
          when: at(utc, 2026, 8, 8, 10),
          cache: day1.cache,
          read: const FirestoreRead.refused(RefusedCause.appCheckRejected),
        );
        expect(causeChanged.shouldNotify, isTrue);
        expect(causeChanged.cache.accessLostCause, RefusedCause.appCheckRejected);
        expect(causeChanged.cache.accessLostSince, theDay,
            reason: 'access has been lost continuously — only the cause moved');
      });

      test('restoration resets the cadence for a later loss', () {
        final lost = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        final restored = reconcile(cache: lost.cache);
        expect(restored.cache.hasLostAccess, isFalse);
        expect(restored.cache.accessLostNotifiedOn, isNull,
            reason: 'or a later loss would think it had already reminded');

        final lostAgain = reconcile(
          cache: restored.cache,
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        expect(lostAgain.shouldNotify, isTrue);
      });

      test('an unreachable day between two refusals does not reset it', () {
        // Only a SUCCESSFUL read proves access is back. If an offline day
        // cleared the state, the next refusal would look like a fresh
        // transition and re-fire "the app has lost access" on every offline
        // day — on the one channel that must not be trained away.
        final lost = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        final offlineDay = reconcile(
          when: at(utc, 2026, 8, 7, 10),
          cache: lost.cache,
          read: const FirestoreRead.unreachable(UnreachableCause.offline),
        );
        expect(offlineDay.cache.accessLostSince, theDay,
            reason: 'a failed read is not proof that access returned');
        expect(offlineDay.cache.accessLostNotifiedOn, theDay);

        final refusedAgain = reconcile(
          when: at(utc, 2026, 8, 8, 10),
          cache: offlineDay.cache,
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        expect(refusedAgain.cache.accessLostSince, theDay,
            reason: 'still the original loss, not a new one');
      });

      test('a standing notice is CANCELLED when access returns', () {
        // No "access restored" message — quiet confirm — but not notifying and
        // not cancelling are different decisions. Without this the tray keeps
        // telling the watcher to fix something already fixed.
        final lost = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        expect(lost.cancelAccessLostNotice, isFalse);

        // Access returns and the day turns out to have no check-in: the notice
        // is cancelled AND a real warning is now owed. Two different messages
        // on two different channels, both correct.
        final restored = reconcile(cache: lost.cache);
        expect(restored.cancelAccessLostNotice, isTrue);
        expect(restored.decision.outcome, WarningOutcome.warnOnline);
        expect(restored.shouldNotify, isTrue);

        // And when the day is fine, the cancellation is the only thing owed.
        final restoredAndFine = reconcile(
          cache: lost.cache,
          read: FirestoreRead.succeeded(checkInDays: {theDay}),
        );
        expect(restoredAndFine.cancelAccessLostNotice, isTrue);
        expect(restoredAndFine.shouldNotify, isFalse);
        expect(restoredAndFine.isNoOp, isFalse,
            reason: 'there is still something to do — cancel the notice');
      });

      test('and cancelled on revocation too', () {
        final lost = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        final revoked = reconcile(
          link: mum.copyWith(status: LinkStatus.revoked),
          cache: lost.cache,
          read: const FirestoreRead.refused(RefusedCause.permissionDenied),
        );
        expect(revoked.cancelAccessLostNotice, isTrue);
        expect(revoked.cache.hasLostAccess, isFalse);
      });

      test('nothing to cancel when no notice was ever shown', () {
        expect(reconcile().cancelAccessLostNotice, isFalse);
      });

      test('a refusal on a settled day still turns the panel red', () {
        // §13's health item is "the last reconcile was refused" — a fact about
        // the READ. Gating the state on the decision left the panel green while
        // every read was being refused, because a day settled by a check-in
        // makes the decision silent.
        final result = reconcile(
          cache: WatcherCache(lastConfirmedDay: theDay),
          read: const FirestoreRead.refused(RefusedCause.appCheckRejected),
        );
        expect(result.decision.outcome, WarningOutcome.silent);
        expect(result.cache.hasLostAccess, isTrue);
        expect(result.cache.accessLostCause, RefusedCause.appCheckRejected);
        expect(result.shouldNotify, isFalse,
            reason: 'nothing is owed about the day — but the panel is red');
      });

      test('no notification is owed when access comes back', () {
        // Quiet confirm, loud miss — the row and the panel go green. Same
        // reasoning as §12's absent "away finished" message.
        final lost = reconcile(
          read: const FirestoreRead.refused(RefusedCause.unauthenticated),
        );
        final restored = reconcile(
          cache: lost.cache,
          read: FirestoreRead.succeeded(checkInDays: {theDay}),
        );
        expect(restored.shouldNotify, isFalse);
        expect(restored.decision.outcome, WarningOutcome.silent);
      });
    });

    test('the copy gets the last day actually confirmed', () {
      final result = reconcile(
        cache: WatcherCache(lastConfirmedDay: day('2026-08-02')),
        read: const FirestoreRead.refused(RefusedCause.unauthenticated),
      );
      expect(result.decision.lastConfirmedDay, day('2026-08-02'),
          reason: 'the one thing still honestly known once access is gone');
    });

    test('the warning alarm stays armed so access can be re-verified', () {
      // Same reasoning as the away period: tearing the alarm down would mean
      // nothing ever re-checks, and the app would go quiet exactly when it is
      // broken. Only revocation cancels it, because only revocation is final.
      final result = reconcile(
        when: at(utc, 2026, 8, 6, 9),
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(result.desiredWarnings, hasLength(7));
      expect(result.warningsToCancel, isEmpty);
    });

    test('a corrected day is not re-warned when access is later refused', () {
      // The check-in was confirmed while access still worked; losing access
      // afterwards must not un-settle a day already settled by evidence.
      final settled = reconcile(
        read: FirestoreRead.succeeded(checkInDays: {theDay}),
      ).cache;
      final afterLoss = reconcile(
        cache: settled,
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(afterLoss.decision.outcome, WarningOutcome.silent);
      expect(afterLoss.decision.silenceReason, SilenceReason.checkInRecorded);
      expect(afterLoss.shouldNotify, isFalse);
    });
  });

  group('a revoked link says nothing at all', () {
    final revoked = mum.copyWith(status: LinkStatus.revoked);

    test('silent, with the reason named', () {
      final result = reconcile(link: revoked);
      expect(result.decision.outcome, WarningOutcome.silent);
      expect(result.decision.silenceReason, SilenceReason.linkRevoked);
      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, isEmpty);
    });

    test('and above all not the OFFLINE warning', () {
      // §8 gates the checkins read on an accepted link, so after revocation
      // every read is permission-denied — a FAILED read. Without the revoked
      // branch the alarm would fall through to warnOffline and claim daily that
      // the phone had been offline, about someone no longer watched.
      final result = reconcile(
        link: revoked,
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(result.decision.outcome, isNot(WarningOutcome.warnOffline));
      expect(result.decision.outcome, WarningOutcome.silent);
      expect(result.decision.silenceReason, SilenceReason.linkRevoked);
    });

    test('a warning standing at revocation is WITHDRAWN, not left in the tray',
        () {
      // Nothing later can clear it: every read after revocation is refused, so
      // no correction can ever run. Without this the tray keeps "No check-in
      // from Mum yesterday" indefinitely, about someone no longer watched.
      final result = reconcile(
        link: revoked,
        cache: WatcherCache(
          warningsShownFor: {theDay: WarningOutcome.warnOnline},
          lastReconcileAt: at(utc, 2026, 8, 6, 9),
        ),
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(result.withdrawnWarnings, [theDay]);
      expect(result.cache.warningsShownFor, isEmpty);
      expect(result.corrections, isEmpty,
          reason: 'a correction would claim she checked in — nothing shows that');
    });

    test('withdrawal is not a correction', () {
      // The two channels are distinct on purpose: a correction REPLACES the
      // notification with "Mum did check in yesterday"; a withdrawal cancels it
      // outright, because nothing here disproves the original warning.
      final result = reconcile(
        link: revoked,
        cache: WatcherCache(
          warningsShownFor: {
            theDay: WarningOutcome.warnOnline,
            day('2026-08-03'): WarningOutcome.warnOffline,
          },
        ),
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );
      expect(result.withdrawnWarnings, hasLength(2));
      expect(result.corrections, isEmpty);
    });

    test('revocation outranks even a stale cached away', () {
      final result = reconcile(
        link: revoked,
        cache: WatcherCache(
          away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20')),
          lastReconcileAt: at(utc, 2026, 8, 1),
        ),
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(result.decision.silenceReason, SilenceReason.linkRevoked);
    });
  });

  group('previousAway — the evidence applyRead would otherwise destroy', () {
    final holiday =
        AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));

    test('the period the cache held is handed back', () {
      // applyRead overwrites `away` wholesale, so the diff is the only thing
      // that can tell a CANCELLED away from one that merely EXPIRED — §12 gives
      // those different messages. Destroying it here would force Phase 6 to
      // re-read the cache before applyRead, i.e. to keep a second source of
      // truth for away state exactly where ADR-0001 says there must not be one.
      final result = reconcile(
        cache: WatcherCache(away: holiday, lastReconcileAt: at(utc, 2026, 8, 5)),
      );
      expect(result.previousAway, holiday);
      expect(result.cache.away, isNull, reason: 'Firestore says it is gone');
      expect(result.previousAway!.through > day('2026-08-05'), isTrue,
          reason: 'cached through later than fetched ⇒ shortened or cancelled');
    });

    test('is null when nothing was cached', () {
      expect(reconcile().previousAway, isNull);
    });

    test('survives a failed read, where the cache is unchanged', () {
      final result = reconcile(
        cache: WatcherCache(away: holiday),
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(result.previousAway, holiday);
      expect(result.cache.away, holiday);
    });
  });

  group('warningsToReschedule names the ordering trap', () {
    test('a moved alarm appears in both sets and is named', () {
      final armed = reconcile(when: at(utc, 2026, 8, 6, 6)).desiredWarnings;
      final moved = reconcile(
        link: mum.copyWith(warningLocalTime: const LocalTimeOfDay(8, 0)),
        when: at(utc, 2026, 8, 6, 6),
        currentlyScheduled: armed,
      );
      // Same platform id, different instant. Cancelling AFTER scheduling would
      // disarm the alarm just rescheduled, and the symptom is nothing happening.
      expect(moved.warningsToReschedule, hasLength(7));
      expect(
        moved.warningsToReschedule,
        moved.warningsToSchedule.map((w) => w.day).toSet(),
      );
    });

    test('is empty when nothing moved', () {
      final armed = reconcile(when: at(utc, 2026, 8, 6, 6)).desiredWarnings;
      expect(
        reconcile(when: at(utc, 2026, 8, 6, 6), currentlyScheduled: armed)
            .warningsToReschedule,
        isEmpty,
      );
    });

    test('a purely stale alarm is a cancel, not a reschedule', () {
      final stale = ScheduledWarning(
        day: day('2026-07-30'),
        at: day('2026-07-30').at(const LocalTimeOfDay(10, 0), utc),
      );
      final result = reconcile(
        when: at(utc, 2026, 8, 6, 6),
        currentlyScheduled: {stale},
      );
      expect(result.warningsToCancel, {stale});
      expect(result.warningsToReschedule, isEmpty);
    });
  });

  group('the warning window across a DST transition', () {
    test('every alarm still fires at the named wall-clock time', () {
      // The window starting 22 Oct spans Madrid's 25 Oct fall-back. If the span
      // were ever "simplified" to Duration(days: 1) arithmetic on the first
      // instant, the later alarms would drift by an hour and nothing else here
      // would notice.
      final result = WatcherReconciler.reconcile(
        now: at(madrid, 2026, 10, 22, 6),
        link: mum,
        watcherZone: madrid,
        cache: const WatcherCache.empty(),
        read: const FirestoreRead.succeeded(),
        currentlyScheduled: const {},
        delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
      );
      expect(result.desiredWarnings, hasLength(7));
      expect(result.desiredWarnings.every((w) => w.at.hour == 10), isTrue);
      expect(
        result.desiredWarnings.map((w) => w.day),
        contains(day('2026-10-26')),
        reason: 'the window really does cross the transition',
      );
    });
  });

  group('suppression before activeFrom', () {
    test('nothing is said about days before the link existed', () {
      final result = reconcile(link: linkTo('mum', from: '2026-08-06'));
      expect(result.decision.silenceReason, SilenceReason.beforeActiveFrom);
      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, isEmpty);
    });
  });
}
