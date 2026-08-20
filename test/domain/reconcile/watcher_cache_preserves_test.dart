// **Every mutator on `WatcherCache` must carry every field it does not mean to
// change**, and four of them rebuild the whole value rather than using
// `copyWith`.
//
// They rebuild deliberately: `copyWith` treats null as "unchanged", so a method
// whose job is to CLEAR a field — `clearAway`, `withAccessRestored` — cannot
// express itself through it. The cost is that adding a field means editing four
// constructor calls, and missing one is silent: the value simply comes back
// null, and nothing about that reads as a defect at the call site.
//
// It is not hypothetical. `lastDecidedDay` was added for ADR-0009 and two of the
// four dropped it — `withAccessLostOn` and `withAccessRestored` — so a refused
// read reset the catch-up window to "first run" and silently un-owed every day
// the outage covered. That is the defect ADR-0009 exists to fix, arriving
// through the field written to fix it. A test found it; review had not.
//
// This file is the guard. It is deliberately about **preservation**, not about
// behaviour: each behaviour has its own test elsewhere, and what those cannot
// see is a field quietly going missing on the way through.

import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  // Every nullable field set to something distinguishable, so a dropped one
  // shows up as null rather than as a coincidentally equal default.
  final full = WatcherCache(
    away: AwayPeriod(from: day('2026-08-10'), through: day('2026-08-20')),
    lastConfirmedDay: day('2026-08-09'),
    warningsShownFor: {day('2026-08-08'): WarningOutcome.warnOnline},
    lastReconcileAt: at(madrid, 2026, 8, 11, 10, 14),
    accessLostSince: day('2026-08-07'),
    accessLostCause: RefusedCause.permissionDenied,
    accessLostNotifiedOn: day('2026-08-07'),
    lastDecidedDay: day('2026-08-09'),
  );

  group('the four rebuild sites carry lastDecidedDay', () {
    test('clearAway', () {
      expect(full.clearAway().lastDecidedDay, day('2026-08-09'));
    });

    test('withAccessLostOn — a DIFFERENT cause, so it really rebuilds', () {
      // The same cause short-circuits and returns `this`, which would pass this
      // test while proving nothing. ADR-0004 decision 5: a changed cause is the
      // case that re-notifies, so it is also the case that rebuilds.
      final next = full.withAccessLostOn(
        day('2026-08-12'),
        RefusedCause.appCheckRejected,
      );
      expect(next.accessLostCause, RefusedCause.appCheckRejected);
      expect(next.lastDecidedDay, day('2026-08-09'));
    });

    test('withAccessRestored', () {
      final next = full.withAccessRestored();
      expect(next.accessLostSince, isNull, reason: 'it did clear what it must');
      expect(next.lastDecidedDay, day('2026-08-09'));
    });

    test('applyRead — the one that runs on every single reconcile', () {
      final next = full.applyRead(
        const FirestoreRead.succeeded(),
        at: at(madrid, 2026, 8, 12, 10),
      );
      expect(next.away, isNull, reason: 'a successful read overwrites wholesale');
      expect(next.accessLostSince, isNull, reason: 'access is provably back');
      expect(next.lastDecidedDay, day('2026-08-09'),
          reason: 'and the catch-up window is not part of that state');
    });
  });

  group('the pointer is monotonic', () {
    test('it does not walk backwards on a device whose clock moved back', () {
      // §3 lists a clock change among the seven cases reconcile() collapses, and
      // §11 says skew is surfaced rather than silently trusted. Walking the
      // pointer back would re-warn about days a family has already read and
      // acted on — a small version of the worst thing this app can do.
      expect(
        full.withLastDecidedDay(day('2026-08-01')).lastDecidedDay,
        day('2026-08-09'),
      );
    });

    test('it advances forwards', () {
      expect(
        full.withLastDecidedDay(day('2026-08-11')).lastDecidedDay,
        day('2026-08-11'),
      );
    });

    test('it is set at all from null', () {
      expect(
        const WatcherCache.empty().withLastDecidedDay(day('2026-08-11')).lastDecidedDay,
        day('2026-08-11'),
      );
    });
  });

  test('equality notices the field, or nothing above could be trusted', () {
    // A `==` that ignored the new field would make every assertion in this file
    // and in the reconciler's suite compare equal by accident.
    expect(full, isNot(equals(full.copyWith(lastDecidedDay: day('2026-08-11')))));
  });
}
