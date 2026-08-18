import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

/// The domain is told whether a notification can actually be **delivered**.
///
/// Before this, the reconciler recorded a message as *shown* at the moment it
/// decided one was *owed*. The mild consequence was cosmetic. The sharp one was
/// `POST_NOTIFICATIONS` being revoked — §13 rates it High precisely because it
/// happens to watchers who never open the app — where the alarm isolate went on
/// firing, reconciling, and marking each reminder consumed while nothing was
/// ever shown.
///
/// The daily warning self-heals from that, because a new day `D` gets a fresh
/// attempt. **The access-lost cadence does not**, and that asymmetry is what
/// most of this file is about.
void main() {
  final link = Link(
    watchedUid: 'mum',
    watcherUid: 'ana',
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watcherName: 'Ana',
    watchedTimezone: 'Etc/UTC',
    activeFrom: day('2026-07-01'),
    createdAt: at(utc, 2026, 7, 1),
  );

  final now = at(utc, 2026, 8, 6, 10); // D = 2026-08-05
  final theDay = day('2026-08-05');

  WatcherReconcileResult reconcile({
    NotificationDelivery? delivery,
    WatcherDelivery? channels,
    WatcherCache cache = const WatcherCache.empty(),
    FirestoreRead? read,
    DateTime? when,
  }) =>
      WatcherReconciler.reconcile(
        now: when ?? now,
        link: link,
        watcherZone: utc,
        cache: cache,
        read: read ?? const FirestoreRead.succeeded(),
        currentlyScheduled: const {},
        delivery: channels ?? WatcherDelivery.uniform(delivery!),
      );

  group('the warning channel — a claim about the watched person', () {
    test('available posts it and records it', () {
      final result = reconcile(delivery: NotificationDelivery.available);
      expect(result.decision.outcome, WarningOutcome.warnOnline);
      expect(result.shouldNotify, isTrue);
      expect(result.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline});
    });

    test('unavailable records NOTHING', () {
      final result = reconcile(delivery: NotificationDelivery.unavailable);
      expect(result.decision.outcome, WarningOutcome.warnOnline,
          reason: 'the decision is unchanged — a warning is still owed');
      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, isEmpty,
          reason: 'nothing was posted, so nothing is standing');
    });

    test('unavailable leaves the warning still owed on the next reconcile', () {
      // The whole point. reconcile() runs again on app open, and the day must
      // not have been quietly consumed by a fire nobody received.
      final muted = reconcile(delivery: NotificationDelivery.unavailable);
      final restored = reconcile(
        delivery: NotificationDelivery.available,
        cache: muted.cache,
      );
      expect(restored.shouldNotify, isTrue);
      expect(restored.cache.warningsShownFor,
          {theDay: WarningOutcome.warnOnline});
    });

    test('redundant does not post, but the day IS consumed', () {
      // The watcher is looking at the screen that already shows this. They have
      // been informed; posting would tell them something they can see.
      final result = reconcile(delivery: NotificationDelivery.redundant);
      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline},
          reason: 'seen on screen is still seen');
    });

    test('redundant does not owe the notification again later', () {
      final seen = reconcile(delivery: NotificationDelivery.redundant);
      final again = reconcile(
        delivery: NotificationDelivery.available,
        cache: seen.cache,
      );
      expect(again.shouldNotify, isFalse,
          reason: 'the standing message is already the right one');
    });

    test('an undelivered hedge does not block the stronger claim later', () {
      // 10:00, notifications revoked, server unreachable: warnOffline owed,
      // nothing shown, nothing recorded. 11:00, permission restored and the
      // read succeeds: the family must get the message the device can support,
      // and it must not be suppressed by a hedge that never appeared.
      final muted = reconcile(
        delivery: NotificationDelivery.unavailable,
        read: const FirestoreRead.unreachable(UnreachableCause.offline),
      );
      expect(muted.decision.outcome, WarningOutcome.warnOffline);
      expect(muted.cache.warningsShownFor, isEmpty);

      final verified = reconcile(
        delivery: NotificationDelivery.available,
        cache: muted.cache,
      );
      expect(verified.decision.outcome, WarningOutcome.warnOnline);
      expect(verified.shouldNotify, isTrue);
    });
  });

  group('the access-lost channel — a claim about our own access', () {
    const refused = FirestoreRead.refused(RefusedCause.permissionDenied);

    test('available posts it and stamps the cadence', () {
      final result = reconcile(
        delivery: NotificationDelivery.available,
        read: refused,
      );
      expect(result.decision.outcome, WarningOutcome.warnAccessLost);
      expect(result.shouldNotify, isTrue);
      expect(result.cache.accessLostNotifiedOn, theDay);
    });

    test('unavailable stamps NOTHING on the cadence', () {
      final result = reconcile(
        delivery: NotificationDelivery.unavailable,
        read: refused,
      );
      expect(result.shouldNotify, isFalse);
      expect(result.cache.accessLostNotifiedOn, isNull,
          reason: 'a reminder nobody received has not been given');
    });

    test('but the refusal itself IS still recorded', () {
      // accessLostSince and accessLostCause are facts about the READ, not about
      // what any human saw. §13's health panel keys on them, and a phone with
      // notifications revoked is exactly the phone whose panel must be able to
      // explain itself when it is finally opened.
      final result = reconcile(
        delivery: NotificationDelivery.unavailable,
        read: refused,
      );
      expect(result.cache.accessLostSince, theDay);
      expect(result.cache.accessLostCause, RefusedCause.permissionDenied);
      expect(result.cache.hasLostAccess, isTrue);
    });

    test('redundant does not post, but the cadence IS stamped', () {
      final result = reconcile(
        delivery: NotificationDelivery.redundant,
        read: refused,
      );
      expect(result.shouldNotify, isFalse);
      expect(result.cache.accessLostNotifiedOn, theDay);
    });
  });

  group('the cadence survives a muted phone — the defect this closes', () {
    const refused = FirestoreRead.refused(RefusedCause.permissionDenied);

    /// Reconciles once a day from 6 Aug, `days` times, at the given delivery.
    ///
    /// Day 0 of the loss is 2026-08-05 (the D of the first fire).
    WatcherCache run(int days, NotificationDelivery delivery) {
      var cache = const WatcherCache.empty();
      for (var i = 0; i < days; i++) {
        cache = WatcherReconciler.reconcile(
          now: at(utc, 2026, 8, 6 + i, 10),
          link: link,
          watcherZone: utc,
          cache: cache,
          read: refused,
          currentlyScheduled: const {},
          delivery: WatcherDelivery.uniform(delivery),
        ).cache;
      }
      return cache;
    }

    test('days 0–5 muted: the day-0 reminder is STILL owed on day 6', () {
      // Six days of `POST_NOTIFICATIONS` revoked. Nothing was delivered, so
      // nothing may have been consumed — the watcher has been told nothing at
      // all, and the first thing they are owed is still the first reminder.
      final muted = run(6, NotificationDelivery.unavailable);
      expect(muted.accessLostSince, day('2026-08-05'), reason: 'day 0');
      expect(muted.accessLostNotifiedOn, isNull,
          reason: 'six fires, nothing delivered, nothing served');

      final restored = WatcherReconciler.reconcile(
        now: at(utc, 2026, 8, 12, 10), // day 6
        link: link,
        watcherZone: utc,
        cache: muted,
        read: refused,
        currentlyScheduled: const {},
        delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
      );
      expect(restored.shouldNotify, isTrue,
          reason: 'the reminder was never given, so it is still due');
    });

    test('the contrast: delivered days 0–5 leave day 6 NOT due', () {
      // The same six days with notifications working. Day 0, 1 and 3 were all
      // served, the day-3 milestone is the standing one, and day 6 is not a new
      // milestone — so nothing is owed. This is the behaviour the test above
      // must NOT produce, and asserting it here is what makes that test mean
      // something rather than merely pass.
      final served = run(6, NotificationDelivery.available);
      expect(served.accessLostNotifiedOn, isNotNull);

      final day6 = WatcherReconciler.reconcile(
        now: at(utc, 2026, 8, 12, 10),
        link: link,
        watcherZone: utc,
        cache: served,
        read: refused,
        currentlyScheduled: const {},
        delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
      );
      expect(day6.shouldNotify, isFalse);
    });

    test('a muted phone does not burn the weekly heartbeat either', () {
      // Fourteen days muted. Under the old behaviour days 0, 1, 3, 7 and 14
      // were each consumed in silence; permissions returning on day 20 would
      // then owe nothing until day 21.
      final muted = run(15, NotificationDelivery.unavailable);
      expect(muted.accessLostNotifiedOn, isNull);

      final day20 = WatcherReconciler.reconcile(
        now: at(utc, 2026, 8, 26, 10),
        link: link,
        watcherZone: utc,
        cache: muted,
        read: refused,
        currentlyScheduled: const {},
        delivery: const WatcherDelivery.uniform(NotificationDelivery.available),
      );
      expect(day20.shouldNotify, isTrue);
    });
  });

  group('a correction is a cancellation, not a post', () {
    final warned = WatcherCache(
      warningsShownFor: {theDay: WarningOutcome.warnOnline},
      lastReconcileAt: at(utc, 2026, 8, 6, 9),
    );

    test('it is still emitted when nothing can be posted', () {
      // The warning was posted while notifications worked; the watcher then
      // revoked the permission; the late check-in arrives. Cancelling an
      // already-posted notification needs no permission, so the correction must
      // still be emitted — a "consistency fix" gating it on
      // delivery.postsNotification would leave a false claim about Mum standing
      // in the tray permanently, on the phone least likely ever to be opened.
      //
      // The same argument the revoked-link test makes for withdrawals, on the
      // other channel.
      for (final delivery in NotificationDelivery.values) {
        final result = reconcile(
          delivery: delivery,
          cache: warned,
          read: FirestoreRead.succeeded(checkInDays: {theDay}),
        );
        expect(result.corrections, [Correction(linkId: link.id, day: theDay)],
            reason: delivery.name);
        expect(result.cache.warningsShownFor, isEmpty, reason: delivery.name);
        expect(result.cache.lastConfirmedDay, theDay, reason: delivery.name);
      }
    });
  });

  group('one channel muted, the other not — measured per channel', () {
    const refused = FirestoreRead.refused(RefusedCause.permissionDenied);

    /// *App problems* off, *Missed check-ins* on. The reader is saying: do not
    /// tell me about the app's own faults, do tell me if she misses a day.
    const accessMuted = WatcherDelivery(
      warning: NotificationDelivery.available,
      accessLost: NotificationDelivery.unavailable,
    );

    /// The other way round.
    const warningMuted = WatcherDelivery(
      warning: NotificationDelivery.unavailable,
      accessLost: NotificationDelivery.available,
    );

    test('muting App problems does not consume the access-lost cadence', () {
      // **The defect, in one assertion.** `canPost` was measured on the
      // warnings channel and the single answer handed to both branches. With
      // *Missed check-ins* still on, that answer is `available`, so the day-0
      // reminder was stamped as served for a notice Android had dropped —
      // and the cadence then walks days 1, 3, 7 and 14 the same way. ADR-0004
      // rates lost access as the state a watcher cannot detect in themselves;
      // this consumed the only thing that would have told them.
      final result = reconcile(channels: accessMuted, read: refused);

      expect(result.decision.outcome, WarningOutcome.warnAccessLost);
      expect(result.shouldNotify, isFalse,
          reason: 'the App problems channel is off — nothing can be posted');
      expect(result.cache.accessLostNotifiedOn, isNull,
          reason: 'nothing was delivered, so nothing may be marked served');
      expect(result.cache.accessLostSince, theDay,
          reason: 'the READ still failed — that fact is recorded either way');
    });

    test('the cadence resumes when App problems is switched back on', () {
      final muted = reconcile(channels: accessMuted, read: refused).cache;
      final later = reconcile(
        channels: const WatcherDelivery.uniform(NotificationDelivery.available),
        cache: muted,
        read: refused,
        when: at(utc, 2026, 8, 7, 10),
      );
      expect(later.shouldNotify, isTrue,
          reason: 'the day-0 reminder was never given, so it is still due');
    });

    test('muting Missed check-ins does not silence the access notice', () {
      // The other direction, and it fails the reader in the opposite way: the
      // notice is suppressed on a channel that is switched ON and would have
      // shown it. ADR-0004 separated the two channels precisely so that muting
      // one leaves the other working.
      final result = reconcile(channels: warningMuted, read: refused);

      expect(result.decision.outcome, WarningOutcome.warnAccessLost);
      expect(result.shouldNotify, isTrue);
      expect(result.cache.accessLostNotifiedOn, theDay);
    });

    test('muting App problems does not silence a missed day', () {
      // The case the channel split exists for, stated plainly: a watcher who
      // switched off the app's complaints about itself must still be told when
      // someone they watch misses a day.
      final result = reconcile(channels: accessMuted);

      expect(result.decision.outcome, WarningOutcome.warnOnline);
      expect(result.shouldNotify, isTrue);
      expect(result.cache.warningsShownFor, {theDay: WarningOutcome.warnOnline});
    });

    test('muting Missed check-ins does not consume a missed day', () {
      final result = reconcile(channels: warningMuted);

      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, isEmpty);
    });
  });

  group('a correction is spoken only when its warning could be', () {
    final warned = WatcherCache(
      warningsShownFor: {theDay: WarningOutcome.warnOnline},
      lastReconcileAt: at(utc, 2026, 8, 6, 9),
    );

    FirestoreRead lateCheckIn() =>
        FirestoreRead.succeeded(checkInDays: {theDay});

    test('available: it is posted', () {
      final result = reconcile(
        delivery: NotificationDelivery.available,
        cache: warned,
        read: lateCheckIn(),
      );
      expect(result.corrections, isNotEmpty);
      expect(result.shouldPostCorrections, isTrue);
    });

    test('redundant: emitted, but NOT spoken', () {
      // `redundant` means the warning was consumed without ever being posted —
      // the watcher was looking at the list, which is the whole meaning of the
      // state. Nothing is in the tray. A replacement therefore arrives alone,
      // and *"Correction: Mum did check in yesterday"* with nothing above it
      // reads, at 3am, as a warning the reader somehow slept through.
      final result = reconcile(
        delivery: NotificationDelivery.redundant,
        cache: warned,
        read: lateCheckIn(),
      );
      expect(result.corrections, isNotEmpty,
          reason: 'still emitted — the service cancels rather than posts');
      expect(result.shouldPostCorrections, isFalse);
    });

    test('unavailable: emitted, but NOT spoken', () {
      final result = reconcile(
        delivery: NotificationDelivery.unavailable,
        cache: warned,
        read: lateCheckIn(),
      );
      expect(result.corrections, isNotEmpty);
      expect(result.shouldPostCorrections, isFalse);
    });

    test('the ACCESS channel has no say in it', () {
      // The correction replaces a warning, at the warning's id, on the warning
      // channel. Whether the reader muted *App problems* is a different
      // question about a different message.
      final result = reconcile(
        channels: const WatcherDelivery(
          warning: NotificationDelivery.available,
          accessLost: NotificationDelivery.unavailable,
        ),
        cache: warned,
        read: lateCheckIn(),
      );
      expect(result.shouldPostCorrections, isTrue);
    });

    test('the day is cleared whether or not it could be spoken', () {
      // She checked in. The day is no longer warned, and leaving it standing
      // would have the list render a warning about a day she is on record as
      // having tapped — the exact defect the review found in `standingWarning`.
      for (final delivery in NotificationDelivery.values) {
        final result = reconcile(
          delivery: delivery,
          cache: warned,
          read: lateCheckIn(),
        );
        expect(result.cache.warningsShownFor, isEmpty, reason: delivery.name);
      }
    });
  });

  group('the two channels are independent', () {
    test('a muted warning channel does not stamp the access cadence', () {
      final result = reconcile(delivery: NotificationDelivery.unavailable);
      expect(result.cache.warningsShownFor, isEmpty);
      expect(result.cache.accessLostNotifiedOn, isNull);
      expect(result.cache.accessLostSince, isNull,
          reason: 'a successful read is not an access failure');
    });

    test('a muted access channel does not stamp a warning', () {
      final result = reconcile(
        delivery: NotificationDelivery.unavailable,
        read: const FirestoreRead.refused(RefusedCause.unauthenticated),
      );
      expect(result.cache.accessLostNotifiedOn, isNull);
      expect(result.cache.warningsShownFor, isEmpty,
          reason: 'warnAccessLost never enters warningsShownFor — ADR-0004');
    });

    test('delivery cannot make a silent day speak', () {
      // The gate only ever subtracts. A day settled by a check-in is silent at
      // every delivery state, and `available` must not resurrect it.
      for (final delivery in NotificationDelivery.values) {
        final result = reconcile(
          delivery: delivery,
          read: FirestoreRead.succeeded(checkInDays: {theDay}),
        );
        expect(result.shouldNotify, isFalse, reason: delivery.name);
        expect(result.decision.silenceReason, SilenceReason.checkInRecorded);
      }
    });

    test('a revoked link is silent at every delivery state', () {
      final revoked = link.copyWith(status: LinkStatus.revoked);
      for (final delivery in NotificationDelivery.values) {
        final result = WatcherReconciler.reconcile(
          now: now,
          link: revoked,
          watcherZone: utc,
          cache: WatcherCache(
            warningsShownFor: {theDay: WarningOutcome.warnOnline},
          ),
          read: const FirestoreRead.refused(RefusedCause.permissionDenied),
          currentlyScheduled: const {},
          delivery: WatcherDelivery.uniform(delivery),
        );
        expect(result.shouldNotify, isFalse, reason: delivery.name);
        expect(result.withdrawnWarnings, [theDay],
            reason: 'withdrawal is a cancellation, not a post — ${delivery.name}');
      }
    });
  });

  group('the enum says what it means', () {
    test('only available posts', () {
      expect(NotificationDelivery.available.postsNotification, isTrue);
      expect(NotificationDelivery.redundant.postsNotification, isFalse);
      expect(NotificationDelivery.unavailable.postsNotification, isFalse);
    });

    test('only unavailable fails to consume', () {
      expect(NotificationDelivery.available.consumesReminder, isTrue);
      expect(NotificationDelivery.redundant.consumesReminder, isTrue);
      expect(NotificationDelivery.unavailable.consumesReminder, isFalse);
    });

    test('the two differ on exactly one state', () {
      // If these ever agree everywhere, the enum has collapsed back to a bool
      // and the redundant case has silently become one of the other two.
      final differ = NotificationDelivery.values
          .where((d) => d.postsNotification != d.consumesReminder)
          .toList();
      expect(differ, [NotificationDelivery.redundant]);
    });
  });
}
