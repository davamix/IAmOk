// ADR-0009 — **a gap no longer drops the days inside it**.
//
// This file began as characterisation tests for the defect ADR-0008 consequence
// 4 derived: `WarningPolicy.decide` took `D` from when the isolate *ran*, so a
// fire deferred past local midnight decided about `D+1` and `D` was never asked
// about again. Every one of them passed, which is how the defect was confirmed.
//
// Measuring it here rather than on the device was deliberate:
// `docs/testing/strategy.md`'s rule is that if a test needs a device to answer a
// question about *logic*, the logic is in the wrong layer. Nothing about this is
// device-shaped, and the device had already supplied the only part it could —
// that deferrals happen, and reached 3h31m overnight on the POCO F3.
//
// It also showed the finding was **wider than the ADR that raised it**:
// `reconcile()` asked about exactly one day however long it had been since the
// last run, so a drawer, a force-stop and a flat battery drop days with no Doze
// anywhere near them. That is what made "carry the armed day on the alarm" the
// wrong fix — after a force-stop there is no alarm left to carry anything.
//
// The tests below are now the **specification**. Each names the day that used to
// be dropped, so a regression reads as "D went missing again" rather than as an
// assertion count.

import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  // One family, one zone. The watcher and the watched person are in the same
  // place, which is the ordinary case and the one that makes the arithmetic easy
  // to check by eye: a 10:00 alarm asks about yesterday.
  final mum = Link(
    watchedUid: 'mum',
    watcherUid: 'ana',
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watcherName: 'Ana',
    watchedTimezone: 'Europe/Madrid',
    activeFrom: day('2026-08-01'),
    createdAt: at(madrid, 2026, 8, 1),
  );

  // D is the day that used to get dropped: Monday 2026-08-10.
  final d = day('2026-08-10');
  final dPlus1 = day('2026-08-11');
  final dPlus2 = day('2026-08-12');

  // A device that has been working normally: yesterday's fire settled D-1. This
  // is what makes the catch-up window meaningful — a cache with no
  // `lastDecidedDay` at all is a fresh install, which deliberately never looks
  // back.
  WatcherCache working({
    DayKey? decidedThrough,
    Map<DayKey, WarningOutcome> warnings = const {},
  }) =>
      WatcherCache(
        lastDecidedDay: decidedThrough ?? d.previous,
        warningsShownFor: warnings,
      );

  WatcherReconcileResult reconcileAt(
    DateTime when, {
    WatcherCache? cache,
    FirestoreRead read = const FirestoreRead.succeeded(),
    NotificationDelivery delivery = NotificationDelivery.available,
  }) =>
      WatcherReconciler.reconcile(
        now: when,
        link: mum,
        watcherZone: madrid,
        cache: cache ?? working(),
        // Succeeded with no check-in days: nobody tapped. Every day in this file
        // is genuinely missed, so every drop would be a real warning lost rather
        // than a warning correctly suppressed.
        read: read,
        currentlyScheduled: const {},
        delivery: WatcherDelivery.uniform(delivery),
      );

  group('the ordinary day is untouched, which is what makes this safe', () {
    test('on time at 10:00 on D+1, it decides about D and nothing else', () {
      final result = reconcileAt(at(madrid, 2026, 8, 11, 10));

      expect(result.decision.day, d);
      expect(result.decision.outcome, WarningOutcome.warnOnline);
      expect(result.shouldNotify, isTrue);
      expect(result.catchUpWarnings, isEmpty,
          reason: 'the window is {D} alone when yesterday settled D-1');
      expect(result.cache.lastDecidedDay, d);
    });

    test('a second reconcile the same day adds nothing', () {
      final first = reconcileAt(at(madrid, 2026, 8, 11, 10));
      final second =
          reconcileAt(at(madrid, 2026, 8, 11, 18), cache: first.cache);

      expect(second.decision.day, d);
      expect(second.shouldNotify, isFalse, reason: 'already standing');
      expect(second.catchUpWarnings, isEmpty);
    });

    test('a fresh install does not retro-warn about days nobody was watching',
        () {
      // `lastDecidedDay` is null. The window is {D}, not "everything since
      // activeFrom" — the link may have existed for weeks before this device
      // was ever able to decide anything.
      final result = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        cache: const WatcherCache.empty(),
      );

      expect(result.decision.day, d);
      expect(result.catchUpWarnings, isEmpty);
    });
  });

  group('THE FIX — a deferral past midnight no longer drops D', () {
    test('deferred to 02:00 on D+2, it decides about D as well as D+1', () {
      // The 3h31m deferral of the overnight run, stretched to the 16 hours a
      // low-usage watcher's phone can easily sit untouched. `D` has been
      // overtaken — `decision.day` is still D+1, because that IS the last
      // completed day — but D is no longer lost with it.
      final result = reconcileAt(at(madrid, 2026, 8, 12, 2));

      expect(result.decision.day, dPlus1);
      expect(result.catchUpWarnings.map((w) => w.day), [d]);
      expect(result.catchUpWarnings.single.outcome, WarningOutcome.warnOnline);
      expect(result.shouldNotify, isTrue, reason: 'D+1 is owed too');
    });

    test('both days land in the ledger, so neither fires twice', () {
      final result = reconcileAt(at(madrid, 2026, 8, 12, 2));

      expect(result.cache.warningsShownFor, {
        d: WarningOutcome.warnOnline,
        dPlus1: WarningOutcome.warnOnline,
      });
      expect(result.cache.lastDecidedDay, dPlus1);
    });

    test('the next punctual fire has nothing left to say', () {
      final deferred = reconcileAt(at(madrid, 2026, 8, 12, 2));
      final nextMorning =
          reconcileAt(at(madrid, 2026, 8, 12, 10), cache: deferred.cache);

      expect(nextMorning.decision.day, dPlus1);
      expect(nextMorning.shouldNotify, isFalse);
      expect(nextMorning.catchUpWarnings, isEmpty);
    });
  });

  group('and the wider case the finding turned out to be', () {
    test('a three-day gap warns about all three days, oldest first', () {
      // A phone in a drawer, a force-stop nobody undid until Thursday, a flat
      // battery over a weekend. No Doze anywhere near any of them.
      final result = reconcileAt(at(madrid, 2026, 8, 14, 10));

      expect(result.decision.day, day('2026-08-13'));
      expect(result.catchUpWarnings.map((w) => w.day),
          [d, dPlus1, dPlus2], reason: 'oldest first');
      expect(result.cache.warningsShownFor.keys, hasLength(4));
      expect(result.cache.lastDecidedDay, day('2026-08-13'));
    });

    test('the look-back is capped, and the cap is stated rather than implied',
        () {
      // A month of silence does not produce thirty notifications on the one
      // channel §1 is built to keep un-swipeable. Seven days back, no further —
      // and the days beyond that are dropped, knowingly, which is a strictly
      // smaller loss than dropping every day but the newest.
      final result = reconcileAt(
        at(madrid, 2026, 9, 10, 10),
        cache: working(decidedThrough: day('2026-08-01')),
      );

      expect(result.decision.day, day('2026-09-09'));
      expect(result.catchUpWarnings, hasLength(6));
      expect(result.catchUpWarnings.first.day, day('2026-09-03'),
          reason: 'seven days inclusive of D');
    });

    test('never before the link existed', () {
      final late = Link(
        watchedUid: 'mum',
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: 'Mum',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: dPlus1,
        createdAt: at(madrid, 2026, 8, 11),
      );

      final result = WatcherReconciler.reconcile(
        now: at(madrid, 2026, 8, 14, 10),
        link: late,
        watcherZone: madrid,
        cache: working(),
        read: const FirestoreRead.succeeded(),
        currentlyScheduled: const {},
        delivery: WatcherDelivery.uniform(NotificationDelivery.available),
      );

      expect(result.catchUpWarnings.map((w) => w.day), [dPlus1, dPlus2],
          reason: 'D itself predates activeFrom and is never spoken about');
      expect(result.cache.warningsShownFor.keys, isNot(contains(d)));
    });

    test('a day she actually tapped is settled by the evidence, not warned', () {
      final result = reconcileAt(
        at(madrid, 2026, 8, 14, 10),
        read: FirestoreRead.succeeded(checkInDays: {dPlus1}),
      );

      // lastConfirmedDay is monotone, so confirming D+1 settles D as well —
      // §10 step 4's "evidence outranks doubt", applied across the whole window.
      expect(result.catchUpWarnings.map((w) => w.day), [dPlus2]);
      expect(result.cache.warningsShownFor.keys, [dPlus2, day('2026-08-13')]);
    });
  });

  group('a day nobody could be told about is not marked settled', () {
    test('a muted phone leaves the pointer below the day it could not post', () {
      // NotificationDelivery.unavailable — POST_NOTIFICATIONS revoked. Nothing
      // reached anyone, so nothing is owed off. Advancing the pointer here would
      // reintroduce the exact defect ADR-0009 exists to fix, through the field
      // written to fix it.
      final result = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        delivery: NotificationDelivery.unavailable,
      );

      expect(result.shouldNotify, isFalse);
      expect(result.cache.warningsShownFor, isEmpty);
      expect(result.cache.lastDecidedDay, d.previous,
          reason: 'unchanged — D is still owed');
    });

    test('and it is warned about once notifications come back', () {
      final muted = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        delivery: NotificationDelivery.unavailable,
      );
      final restored =
          reconcileAt(at(madrid, 2026, 8, 12, 10), cache: muted.cache);

      expect(restored.catchUpWarnings.map((w) => w.day), [d],
          reason: 'the day the muted phone could not report');
      expect(restored.decision.day, dPlus1);
    });

    test('the pointer never steps over a hole', () {
      // D unsettled, D+1 settled. Advancing to D+1 would jump D.
      final muted = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        delivery: NotificationDelivery.unavailable,
      );
      final next =
          reconcileAt(at(madrid, 2026, 8, 12, 10), cache: muted.cache);

      expect(next.cache.lastDecidedDay, dPlus1);
      expect(next.cache.warningsShownFor.keys, containsAll([d, dPlus1]),
          reason: 'the hole was filled on the way past, not stepped over');
    });
  });

  group('a refused read decides nothing about her, and says so by waiting', () {
    test('the pointer does not advance while access is refused', () {
      final refused = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      );

      expect(refused.decision.outcome, WarningOutcome.warnAccessLost);
      expect(refused.catchUpWarnings, isEmpty,
          reason: 'access loss has its own decaying cadence, not a per-day one');
      expect(refused.cache.lastDecidedDay, d.previous, reason: 'unchanged');
    });

    test('and the refused days are caught up once access returns', () {
      var cache = working();
      for (final hour in [
        at(madrid, 2026, 8, 11, 10),
        at(madrid, 2026, 8, 12, 10),
        at(madrid, 2026, 8, 13, 10),
      ]) {
        cache = reconcileAt(
          hour,
          cache: cache,
          read: const FirestoreRead.refused(RefusedCause.permissionDenied),
        ).cache;
      }

      final restored = reconcileAt(at(madrid, 2026, 8, 13, 12), cache: cache);

      expect(restored.catchUpWarnings.map((w) => w.day), [d, dPlus1],
          reason: 'the days the outage covered, now decidable on evidence');
      expect(restored.decision.day, dPlus2);
    });

    test('a day she tapped during the outage is not warned about after it', () {
      var cache = working();
      cache = reconcileAt(
        at(madrid, 2026, 8, 11, 10),
        cache: cache,
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
      ).cache;

      final restored = reconcileAt(
        at(madrid, 2026, 8, 12, 10),
        cache: cache,
        read: FirestoreRead.succeeded(checkInDays: {d}),
      );

      expect(restored.catchUpWarnings, isEmpty);
      expect(restored.cache.warningsShownFor.keys, [dPlus1]);
    });
  });

  group('an unverifiable away is not a per-day claim and is not repeated', () {
    // The burst this design would otherwise produce, and the one a test caught
    // before it shipped: six days inside a stale away period would each decide
    // `warnUnverifiableAway` and post six notifications differing only in a date
    // that is not what any of them is about.
    final holiday = AwayPeriod(from: d, through: day('2026-08-20'));

    test('only the current day speaks', () {
      final cache = WatcherCache(
        away: AwayRecord.unattributed(holiday),
        lastDecidedDay: d.previous,
        // Read three days ago, so the away is past ADR-0001's two-day bound.
        lastReconcileAt: at(madrid, 2026, 8, 11, 10),
      );

      final result = reconcileAt(
        at(madrid, 2026, 8, 14, 10),
        cache: cache,
        read: const FirestoreRead.unreachable(),
      );

      expect(result.decision.outcome, WarningOutcome.warnUnverifiableAway);
      expect(result.catchUpWarnings, isEmpty,
          reason: 'one claim about this phone, not one per day');
    });

    test('and those days are left unsettled, to be decided on evidence later',
        () {
      final cache = WatcherCache(
        away: AwayRecord.unattributed(holiday),
        lastDecidedDay: d.previous,
        lastReconcileAt: at(madrid, 2026, 8, 11, 10),
      );

      final stale = reconcileAt(
        at(madrid, 2026, 8, 14, 10),
        cache: cache,
        read: const FirestoreRead.unreachable(),
      );

      expect(stale.cache.lastDecidedDay, d.previous,
          reason: 'nothing was said about D..D+2, so nothing is settled');

      // The away turns out to have been cancelled. Those days were expected
      // after all, and they are still there to be warned about.
      final verified = reconcileAt(
        at(madrid, 2026, 8, 14, 12),
        cache: stale.cache,
      );

      expect(verified.catchUpWarnings.map((w) => w.day), [d, dPlus1, dPlus2]);
    });
  });
}
