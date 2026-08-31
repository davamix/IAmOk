import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  final period = AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22'));

  group('a missing name may never cost the period', () {
    // ADR-0003's *Absence* case. The whole point of this type parsing rather
    // than validating: a document written before the attribution rules were
    // deployed, or by an admin path that bypasses them, must degrade to an
    // UNATTRIBUTED away period and never to NO away period. Dropping the period
    // would warn a family about days somebody really did mark away, which is
    // the worst thing this app can do.
    test('no setBy and no setByName still yields a period', () {
      final record = AwayRecord.tryCreate(
        from: day('2026-08-15'),
        through: day('2026-08-22'),
      );
      expect(record, isNotNull);
      expect(record!.period, period);
      expect(record.setBy, isNull);
      expect(record.setByName, isNull);
    });

    test('an empty setBy is null rather than an attribution to ""', () {
      final record = AwayRecord.tryCreate(
        from: day('2026-08-15'),
        through: day('2026-08-22'),
        setBy: '',
        setByName: 'Ana',
      );
      expect(record!.setBy, isNull);
      expect(record.wasSetBy(''), isFalse,
          reason: 'nobody is not somebody, however the empty string compares');
    });

    test('an unusable name leaves the period and drops only the label', () {
      final record = AwayRecord.tryCreate(
        from: day('2026-08-15'),
        through: day('2026-08-22'),
        setBy: 'ana-uid',
        setByName: '   ',
      );
      expect(record!.period, period, reason: 'the period survives');
      expect(record.setByName, isNull);
      expect(record.setBy, 'ana-uid', reason: 'the identity is untouched');
    });
  });

  group('only the period can refuse to parse', () {
    test('through before from is no valid away period', () {
      expect(
        AwayRecord.tryCreate(
          from: day('2026-08-22'),
          through: day('2026-08-15'),
          setBy: 'ana-uid',
          setByName: 'Ana',
        ),
        isNull,
        reason: 'the same boundary AwayPeriod.tryCreate draws, and the same '
            'reason: a corrupt document must not throw inside an alarm isolate',
      );
    });

    test('a single-day period is fine', () {
      final record = AwayRecord.tryCreate(
        from: day('2026-08-15'),
        through: day('2026-08-15'),
      );
      expect(record!.period.lengthInDays, 1);
    });
  });

  group('the name is bounded on READ, which the rules cannot do', () {
    // The rules bound `setByName` to 1-100 characters, but they only bound what
    // this app's own clients may put there. ADR-0003 lists
    // `setByName: "Dr. Smith, Hospital Admissions"` as the injection this exists
    // for, and it reaches a family's notification tray through this field.
    test('a name at the maximum length is kept', () {
      final name = 'A' * AwayRules.nameMaxLength;
      expect(
        AwayRecord(period: period, setBy: 'x', setByName: name).setByName,
        name,
      );
    });

    test('a name one character over the maximum is dropped', () {
      final name = 'A' * (AwayRules.nameMaxLength + 1);
      expect(
        AwayRecord(period: period, setBy: 'x', setByName: name).setByName,
        isNull,
        reason: 'the bound the rules state, applied where the rules cannot',
      );
    });

    test('surrounding whitespace is trimmed rather than counted', () {
      expect(
        AwayRecord(period: period, setBy: 'x', setByName: '  Ana  ').setByName,
        'Ana',
      );
    });

    test('a name that is only whitespace is not a name', () {
      expect(
        AwayRecord(period: period, setBy: 'x', setByName: '\t\n ').setByName,
        isNull,
      );
    });
  });

  group('nameToShowFor — whose action the reader is looking at', () {
    final byAna = AwayRecord(
      period: period,
      setBy: 'ana-uid',
      setByName: 'Ana',
    );

    test('somebody else set it, so the reader is told who', () {
      expect(byAna.nameToShowFor('mum-uid'), 'Ana');
    });

    test('the reader set it themselves, so no name is offered', () {
      // The caller renders the already-approved unattributed string instead.
      // Every string this feeds reads "X marked you away" / "set by X", and a
      // reader told they were marked away by themselves is being addressed in
      // the wrong grammatical person.
      expect(byAna.nameToShowFor('ana-uid'), isNull);
    });

    test('an unattributed period names nobody, whoever is reading', () {
      final anonymous = AwayRecord.unattributed(period);
      expect(anonymous.nameToShowFor('mum-uid'), isNull);
      expect(anonymous.nameToShowFor(null), isNull);
    });

    test('a name with NO uid behind it names nobody', () {
      // Corrected at the Phase 6 gate. A label with no `setBy` has nothing to
      // resolve a dispute through, and the app has no evidence that anybody
      // acted — so it may not say somebody did. It is also the case that can
      // put her OWN name in front of "marked you away", because the
      // self-suppression guard keys on the uid the document lacks.
      final unsigned = AwayRecord(period: period, setBy: null, setByName: 'Ana');
      expect(unsigned.nameToShowFor('mum-uid'), isNull);
      expect(unsigned.nameToShowFor('ana-uid'), isNull);
      expect(unsigned.wasSetBy('ana-uid'), isFalse);
    });

    test('the placeholder for a writer with no name is suppressed', () {
      // The rules REQUIRE `setByName`, so a writer whose account has no display
      // name must still put something there — but "Someone marked you away
      // until Saturday 22" names a role, which `guidelines.md` forbids, and is
      // ADR-0003's "?? marked you away" wearing a word.
      final unnamed = AwayRecord(
        period: period,
        setBy: 'ana-uid',
        setByName: AwayRecord.unnameable,
      );
      expect(unnamed.isUnnameable, isTrue);
      expect(unnamed.nameToShowFor('mum-uid'), isNull,
          reason: 'the approved unattributed line renders instead, which is '
              'honest: nobody can be named');
    });

    test('the placeholder matches the one the write path uses', () {
      // Duplicated deliberately — the domain may not import the copy layer —
      // so the two are pinned against each other rather than trusted to agree.
      expect(AwayRecord.unnameable, AwayCopy.unnamedWriter);
    });
  });

  group('value semantics', () {
    test('attribution is part of equality', () {
      // It has to be: `WatcherCache` equality is what every idempotence
      // assertion in the watcher suite rests on, and a re-attributed period is
      // a real change that must reach the row.
      expect(
        AwayRecord(period: period, setBy: 'ana-uid', setByName: 'Ana'),
        AwayRecord(period: period, setBy: 'ana-uid', setByName: 'Ana'),
      );
      expect(
        AwayRecord(period: period, setBy: 'ana-uid', setByName: 'Ana'),
        isNot(AwayRecord(period: period, setBy: 'beto-uid', setByName: 'Beto')),
      );
      expect(
        AwayRecord(period: period, setBy: 'ana-uid', setByName: 'Ana').hashCode,
        AwayRecord(period: period, setBy: 'ana-uid', setByName: 'Ana').hashCode,
      );
    });

    test('copyWith replaces the period and keeps the attribution', () {
      // The shape cancellation needs: truncating re-writes `through` while §12
      // is last-write-wins about WHO — so the caller re-stamps attribution
      // explicitly rather than inheriting it silently from here.
      final truncated = AwayRecord(
        period: period,
        setBy: 'ana-uid',
        setByName: 'Ana',
      ).copyWith(period: period.cancelOn(day('2026-08-18'))!);

      expect(truncated.period.through, day('2026-08-17'));
      expect(truncated.period.from, day('2026-08-15'));
      expect(truncated.setBy, 'ana-uid');
      expect(truncated.setByName, 'Ana');
    });
  });
}
