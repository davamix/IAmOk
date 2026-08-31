@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/data/away_repository.dart';
import 'package:i_am_ok/domain/domain.dart';

import '../support/zones.dart';

/// **The decision that selects create from update, and the one that bounds the
/// name.** Both were uncovered, and the first is where the set-once defect
/// lived: away worked once per person and then went permanently dead on every
/// device, with copy blaming the reader's choice of day.
///
/// All three run with no Firestore, because everything under test happens
/// **before** anything is sent — which is the point: the create-versus-update
/// decision is a policy question and now lives in the domain as a pure
/// function, where inline in the repository it was reachable from no test.
void main() {
  final today = day('2026-08-15');

  group('periodInForce — the create-versus-update decision', () {
    // The defect this exists for: nothing deletes the away document when a
    // period runs its course, so the cached record outlives the holiday. Passed
    // as `existing` it froze `from` at a date now weeks in the past, and
    // `validateUpdate` refused every later write for ever — away worked once
    // per person and then went permanently dead on every device, with copy
    // blaming the reader's choice of day.
    //
    // A pure function in the domain, not inline in the repository, because it
    // is a policy question — and because inline it was reachable from no test.

    test('an ENDED period is not in force, so the write is a create', () {
      final ended =
          AwayPeriod(from: day('2026-07-01'), through: day('2026-07-10'));

      expect(AwayRules.periodInForce(ended, today), isNull);
      expect(
        AwayRules.validateCreate(
          AwayPeriod(from: today, through: day('2026-08-22')),
          today,
        ),
        isNull,
        reason: 'ADR-0001 decision 6 froze `from` for the life of a PERIOD, '
            'not of a person',
      );
    });

    test('a period still running IS in force, so `from` stays frozen', () {
      // The other half, which must not be lost while fixing the first: an
      // in-progress period is exactly what ADR-0001 decision 6 is about, since
      // truncating one rewrites a document whose `from` is already past.
      final inForce =
          AwayPeriod(from: day('2026-08-10'), through: day('2026-08-20'));

      expect(AwayRules.periodInForce(inForce, today), inForce);
      expect(
        AwayRules.validateUpdate(
          AwayPeriod(from: today, through: day('2026-08-22')),
          inForce,
          today,
        ),
        AwayRejection.fromChanged,
      );
    });

    test('a period ending TODAY is still in force — `through` is inclusive', () {
      // The boundary, and the direction that matters: `through` is the LAST
      // away day, not the day of return, so today is still covered.
      final endsToday = AwayPeriod(from: day('2026-08-10'), through: today);

      expect(AwayRules.periodInForce(endsToday, today), endsToday);
    });

    test('a period that ended YESTERDAY is not in force', () {
      final endedYesterday =
          AwayPeriod(from: day('2026-08-10'), through: day('2026-08-14'));

      expect(AwayRules.periodInForce(endedYesterday, today), isNull);
    });

    test('a period starting in the future is in force', () {
      // Not reachable in v1 — `from` is always today — but the predicate must
      // not answer "expired" for a period that has not begun, or exposing
      // future-dating later would silently re-open the defect.
      final future =
          AwayPeriod(from: day('2026-08-20'), through: day('2026-08-25'));

      expect(AwayRules.periodInForce(future, today), future);
    });

    test('nothing stored is nothing in force', () {
      expect(AwayRules.periodInForce(null, today), isNull);
    });

    test('truncating an in-force period is still a legal update', () {
      // The write ADR-0001 requires. A fix to the create/update selection that
      // broke this would re-open the cancellation defect the ADR exists for.
      final inForce =
          AwayPeriod(from: day('2026-08-10'), through: day('2026-08-20'));

      expect(
        AwayRules.validateUpdate(inForce.cancelOn(today)!, inForce, today),
        isNull,
      );
    });
  });

  group('boundedName — the rules clause, applied before the write', () {
    test('an ordinary name is passed through, trimmed', () {
      expect(AwayRepository.boundedName('  Ana  '), 'Ana');
    });

    test('an empty or whitespace name becomes the placeholder', () {
      // The rules require 1-100 characters after trimming, so the field cannot
      // be omitted — and `displayName` is user-controlled, so `''` is reachable.
      // Without this the write is `permission-denied`, which this app's copy
      // layer renders as a claim about lost access.
      expect(AwayRepository.boundedName(''), AwayCopy.unnamedWriter);
      expect(AwayRepository.boundedName('   '), AwayCopy.unnamedWriter);
      expect(AwayRepository.boundedName('\t\n'), AwayCopy.unnamedWriter);
    });

    test('a name at the maximum length is kept whole', () {
      final name = 'A' * AwayRules.nameMaxLength;
      expect(AwayRepository.boundedName(name), name);
    });

    test('an over-long name is CLAMPED, not rejected', () {
      // Rejecting would lose the attribution entirely; clamping keeps a usable
      // label and keeps the write legal. A rename to 200 characters is a thing
      // a person can do, and it is not a fault they can act on.
      final clamped = AwayRepository.boundedName('A' * 300);
      expect(clamped.length, AwayRules.nameMaxLength);
      expect(clamped, 'A' * AwayRules.nameMaxLength);
    });

    test('everything it returns satisfies the rules clause', () {
      // The property, rather than four examples: whatever goes in, what comes
      // out is between the bounds the rules enforce.
      for (final raw in <String>[
        '',
        '   ',
        'Ana',
        '  Ana  ',
        'A' * 99,
        'A' * 100,
        'A' * 101,
        'A' * 5000,
      ]) {
        final result = AwayRepository.boundedName(raw);
        expect(result.trim().length, greaterThanOrEqualTo(AwayRules.nameMinLength),
            reason: 'for ${raw.length} chars');
        expect(result.length, lessThanOrEqualTo(AwayRules.nameMaxLength),
            reason: 'for ${raw.length} chars');
      }
    });
  });

  group('readFrom — a cache hit is never a success', () {
    test('a cache hit is UNREACHABLE, whatever it contains', () {
      // ADR-0001's founding defect, in the silent direction, and it was
      // reachable from no test: Firestore serves the local cache when offline
      // without throwing, so a cache hit reported as success would let a period
      // Firestore no longer holds go on suppressing her reminders indefinitely.
      final read = AwayRepository.readFrom(
        isFromCache: true,
        data: <String, dynamic>{
          'from': '2026-08-15',
          'through': '2026-08-22',
          'setBy': 'ana-uid',
          'setByName': 'Ana',
        },
      );

      expect(read.succeeded, isFalse);
      expect(read.verification, Verification.unreachable);
      expect(read.awayOrNull, isNull,
          reason: 'a read served from the cache has verified nothing, however '
              'successful it looks');
    });

    test('a server hit succeeds and carries the document', () {
      final read = AwayRepository.readFrom(
        isFromCache: false,
        data: <String, dynamic>{
          'from': '2026-08-15',
          'through': '2026-08-22',
          'setBy': 'ana-uid',
          'setByName': 'Ana',
        },
      );

      expect(read.succeeded, isTrue);
      expect(read.awayOrNull!.setByName, 'Ana');
    });

    test('a server hit on an ABSENT document succeeds with nothing', () {
      // The signal that clears a cancelled away. It must be distinguishable
      // from a cache hit, which is the whole point of this function.
      final read = AwayRepository.readFrom(isFromCache: false);

      expect(read.succeeded, isTrue);
      expect(read.awayOrNull, isNull);
    });
  });
}
