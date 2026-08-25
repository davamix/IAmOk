import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  final holiday =
      AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));
  final now = at(utc, 2026, 8, 6, 10);

  group('applyRead — only a read that SUCCEEDED is an answer', () {
    test('a successful read stamps lastReconcileAt', () {
      final result =
          const WatcherCache.empty().applyRead(const FirestoreRead.succeeded(), at: now);
      expect(result.lastReconcileAt, now);
    });

    // ADR-0004 splits failure into unreachable and refused for MESSAGE
    // selection. For CACHE RETENTION they remain identical, which is
    // ADR-0001's rule and is what this asserts across every cause of both.
    final everyFailure = <FirestoreRead>[
      for (final c in UnreachableCause.values) FirestoreRead.unreachable(c),
      for (final c in RefusedCause.values) FirestoreRead.refused(c),
    ];

    for (final read in everyFailure) {
      test('$read changes nothing at all', () {
        // A timeout, a permission denial and an App Check rejection all happen
        // while the device is online, and none of them prove the away document
        // is gone. Keying this on connectivity instead would wipe a legitimate
        // away on a transient error and warn falsely.
        final before = WatcherCache(
          away: holiday,
          lastConfirmedDay: day('2026-08-04'),
          warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline},
          lastReconcileAt: at(utc, 2026, 8, 1),
          // Populated deliberately: with these left null the assertion below
          // would prove nothing about them, and they are the fields most
          // recently added.
          accessLostSince: day('2026-08-02'),
          accessLostCause: RefusedCause.appCheckRejected,
          accessLostNotifiedOn: day('2026-08-02'),
        );
        expect(before.applyRead(read, at: now), before);
      });
    }

    test('a successful read clears the access-lost state', () {
      // The clearing is implicit — applyRead builds a fresh WatcherCache and
      // omits these three. The obvious refactor (switch to copyWith when a
      // field is added) would silently stop clearing them.
      final lost = WatcherCache(
        accessLostSince: day('2026-08-02'),
        accessLostCause: RefusedCause.unauthenticated,
        accessLostNotifiedOn: day('2026-08-02'),
      );
      final after = lost.applyRead(const FirestoreRead.succeeded(), at: now);
      expect(after.hasLostAccess, isFalse);
      expect(after.accessLostCause, isNull);
      expect(after.accessLostNotifiedOn, isNull,
          reason: 'or a later loss would think it had already reminded');
    });

    test('every failure variant reports itself as not succeeded', () {
      // applyRead gates on this one bit, so a new FirestoreRead subtype that
      // got it wrong would silently start clearing the cache.
      for (final read in everyFailure) {
        expect(read.succeeded, isFalse, reason: '$read');
        expect(read.verification, isNot(Verification.verified), reason: '$read');
      }
      expect(const FirestoreRead.succeeded().succeeded, isTrue);
    });

    test('verification maps one-to-one onto the read type', () {
      expect(const FirestoreRead.succeeded().verification,
          Verification.verified);
      expect(const FirestoreRead.unreachable().verification,
          Verification.unreachable);
      expect(const FirestoreRead.refused().verification, Verification.refused);
    });

    test('an away period is overwritten wholesale — including with nothing', () {
      // The single assignment that makes a remotely cancelled away visible to a
      // watcher whose nudge was lost. Sixteen days of wrongful silence in the
      // modelled scenario turned on this line.
      final cached = WatcherCache(away: holiday);
      expect(
        cached.applyRead(const FirestoreRead.succeeded(), at: now).away,
        isNull,
      );
    });

    test('an away period is replaced by a shortened one', () {
      final shortened =
          AwayPeriod(from: day('2026-08-01'), through: day('2026-08-04'));
      final result = WatcherCache(away: holiday)
          .applyRead(FirestoreRead.succeeded(away: shortened), at: now);
      expect(result.away, shortened);
    });

    test('lastConfirmedDay takes the latest day read', () {
      final result = const WatcherCache.empty().applyRead(
        FirestoreRead.succeeded(
            checkInDays: days(['2026-08-03', '2026-08-05', '2026-08-04'])),
        at: now,
      );
      expect(result.lastConfirmedDay, day('2026-08-05'));
    });

    test('lastConfirmedDay is monotonic — a narrow read cannot walk it back', () {
      // Re-opening a settled day would produce a warning for a day already
      // known to be fine.
      final cached = WatcherCache(lastConfirmedDay: day('2026-08-05'));
      final result = cached.applyRead(
        FirestoreRead.succeeded(checkInDays: days(['2026-08-02'])),
        at: now,
      );
      expect(result.lastConfirmedDay, day('2026-08-05'));
    });

    test('a successful empty read does not clear lastConfirmedDay', () {
      final cached = WatcherCache(lastConfirmedDay: day('2026-08-05'));
      expect(
        cached.applyRead(const FirestoreRead.succeeded(), at: now).lastConfirmedDay,
        day('2026-08-05'),
      );
    });

    test('warningsShownFor is untouched — corrections are a separate step', () {
      final cached = WatcherCache(warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline});
      expect(
        cached.applyRead(const FirestoreRead.succeeded(), at: now).warningsShownFor,
        {day('2026-08-03'): WarningOutcome.warnOnline},
      );
    });
  });

  group('warningsShownFor', () {
    test('recording a warning is idempotent', () {
      final once = const WatcherCache.empty().withWarningShownFor(day('2026-08-05'), WarningOutcome.warnOnline);
      final twice = once.withWarningShownFor(day('2026-08-05'), WarningOutcome.warnOnline);
      expect(once.warningsShownFor, {day('2026-08-05'): WarningOutcome.warnOnline});
      expect(twice, once);
      expect(identical(twice, once), isTrue);
    });

    test('a correction removes the day and advances lastConfirmedDay', () {
      final cache = WatcherCache(
        warningsShownFor: {day('2026-08-05'): WarningOutcome.warnOnline, day('2026-08-02'): WarningOutcome.warnOnline},
      );
      final corrected =
          cache.withCorrectionFor(day('2026-08-05'), delivered: true);
      expect(corrected.warningsShownFor, {day('2026-08-02'): WarningOutcome.warnOnline});
      expect(corrected.lastConfirmedDay, day('2026-08-05'));
    });

    test('a correction never walks lastConfirmedDay backwards', () {
      final cache = WatcherCache(
        warningsShownFor: {day('2026-08-02'): WarningOutcome.warnOnline},
        lastConfirmedDay: day('2026-08-05'),
      );
      expect(
        cache
            .withCorrectionFor(day('2026-08-02'), delivered: true)
            .lastConfirmedDay,
        day('2026-08-05'),
      );
    });

    test('correcting a day that was never warned about is harmless', () {
      final corrected = const WatcherCache.empty()
          .withCorrectionFor(day('2026-08-05'), delivered: true);
      expect(corrected.warningsShownFor, isEmpty);
      expect(corrected.lastConfirmedDay, day('2026-08-05'));
    });
  });

  // The ledger half of ADR-0010's follow-up. The warning path gates its ledger
  // WRITE on delivery; this path gated nothing, so a retraction found before the
  // reader's hour cancelled the warning, dropped the day, and left no record
  // anywhere that a sentence was owed.
  group('a retraction that could not be spoken stays owed', () {
    final warned = WatcherCache(
      warningsShownFor: {day('2026-08-05'): WarningOutcome.warnOnline},
    );

    test('held: the day leaves the tray ledger and enters the owed set', () {
      final held = warned.withCorrectionFor(day('2026-08-05'), delivered: false);

      // The false claim comes down either way — that half is load-bearing.
      expect(held.warningsShownFor, isEmpty,
          reason: 'the warning was cancelled, so nothing is standing');
      expect(held.correctionsOwedFor, {day('2026-08-05')});
      expect(held.lastConfirmedDay, day('2026-08-05'),
          reason: 'evidence about HER is not a delivery record');
    });

    test('and is cleared once it is actually spoken', () {
      final held = warned.withCorrectionFor(day('2026-08-05'), delivered: false);
      final spoken =
          held.withCorrectionFor(day('2026-08-05'), delivered: true);
      expect(spoken.correctionsOwedFor, isEmpty);
      expect(spoken.warningsShownFor, isEmpty);
    });

    test('holding it twice owes it once', () {
      final once = warned.withCorrectionFor(day('2026-08-05'), delivered: false);
      final twice = once.withCorrectionFor(day('2026-08-05'), delivered: false);
      expect(twice.correctionsOwedFor, {day('2026-08-05')});
      expect(twice, once, reason: 'reconcile() is idempotent by design');
    });

    test('a delivered correction never owes anything', () {
      expect(
        warned.withCorrectionFor(day('2026-08-05'), delivered: true)
            .correctionsOwedFor,
        isEmpty,
      );
    });

    // Sec 10 step 2: a revoked link's warnings are WITHDRAWN, never retracted.
    // "Mum did check in" is a claim this device may not make about a person it
    // is no longer entitled to read about.
    test('revocation withdraws the owed retraction with the warnings', () {
      final held = warned.withCorrectionFor(day('2026-08-05'), delivered: false);
      final withdrawn = held.withWarningsWithdrawn();
      expect(withdrawn.correctionsOwedFor, isEmpty);
      expect(withdrawn.warningsShownFor, isEmpty);
    });

    test('withWarningsWithdrawn still fires when ONLY a retraction is owed', () {
      // The early return used to test `warningsShownFor.isEmpty` alone, which is
      // exactly the state a held correction leaves behind: no standing warning,
      // one owed sentence. Returning `this` there would carry the retraction
      // straight through the revocation that must drop it.
      final held = warned.withCorrectionFor(day('2026-08-05'), delivered: false);
      expect(held.warningsShownFor, isEmpty, reason: 'the precondition');
      expect(held.withWarningsWithdrawn().correctionsOwedFor, isEmpty);
    });
  });

  group('value semantics — the basis of every idempotence assertion', () {
    test('equal caches compare equal, including the day set', () {
      final a = WatcherCache(
        away: holiday,
        lastConfirmedDay: day('2026-08-05'),
        warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline, day('2026-08-04'): WarningOutcome.warnOnline},
        lastReconcileAt: now,
      );
      final b = WatcherCache(
        away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20')),
        lastConfirmedDay: day('2026-08-05'),
        warningsShownFor: {day('2026-08-04'): WarningOutcome.warnOnline, day('2026-08-03'): WarningOutcome.warnOnline},
        lastReconcileAt: at(utc, 2026, 8, 6, 10),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing day set compares unequal', () {
      expect(
        WatcherCache(warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline}),
        isNot(WatcherCache(warningsShownFor: {day('2026-08-04'): WarningOutcome.warnOnline})),
      );
      expect(
        WatcherCache(warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline}),
        isNot(const WatcherCache.empty()),
      );
    });

    test('clearAway removes the period and keeps everything else', () {
      final cache = WatcherCache(
        away: holiday,
        lastConfirmedDay: day('2026-08-05'),
        warningsShownFor: {day('2026-08-03'): WarningOutcome.warnOnline},
        lastReconcileAt: now,
      );
      final cleared = cache.clearAway();
      expect(cleared.away, isNull);
      expect(cleared.lastConfirmedDay, day('2026-08-05'));
      expect(cleared.warningsShownFor, {day('2026-08-03'): WarningOutcome.warnOnline});
      expect(cleared.lastReconcileAt, now);
    });
  });
}
