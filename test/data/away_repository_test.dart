import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/data/away_repository.dart';
import 'package:i_am_ok/domain/domain.dart';

import '../support/zones.dart';

/// Everything [AwayRepository] **decides**, without a Firestore.
///
/// The two SDK calls themselves are not covered here and decide nothing. What
/// is covered is the part that was wrong for a whole phase last time it lived
/// inside a `catch`: which of several sentences a person reads.
void main() {
  final repository = AwayRepository(confirmWithin: const Duration(seconds: 1));

  group('send — a timeout is QUEUED, and is never called a failure', () {
    test('a write the server confirms is set', () async {
      expect(await repository.send(Future<void>.value()), isA<AwaySet>());
    });

    test('a write that does not confirm in the window is queued', () async {
      // §8 chose a direct client write over a callable precisely so this case
      // works: "a watcher can set away on a plane and have it queue offline like
      // any other write". Firestore is holding the mutation and will replay it.
      final never = Completer<void>();
      final outcome = await repository.send(never.future);

      expect(outcome, isA<AwayQueued>());
      expect(outcome.isRefused, isFalse,
          reason: 'the reader must not be told nothing was saved — it was, and '
              'it will land');
    });

    test('a slow write that lands inside the window is still set', () async {
      final outcome = await repository.send(
        Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(outcome, isA<AwaySet>());
    });

    test('a Firestore refusal is a refusal, not a queue', () async {
      final outcome = await repository.send(
        Future<void>.error(FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        )),
      );
      expect(outcome, isA<AwayRefused>());
      expect((outcome as AwayRefused).refusal, AwayRefusal.notPermitted);
    });

    test('anything else is a server fault and claims nothing', () async {
      final outcome = await repository.send(Future<void>.error(StateError('x')));
      expect((outcome as AwayRefused).refusal, AwayRefusal.serverFault);
    });
  });

  group('refusalForCode — the table that used to be unreachable', () {
    test('permission-denied is about access, not about the device', () {
      expect(AwayRepository.refusalForCode('permission-denied'),
          AwayRefusal.notPermitted);
    });

    test('unauthenticated is nobody signed in', () {
      expect(AwayRepository.refusalForCode('unauthenticated'),
          AwayRefusal.notSignedIn);
    });

    test('an unrecognised code falls through to serverFault, never to a claim '
        'about the connection', () {
      // ADR-0004's rule, one layer down. `couldNotReach` is deliberately absent
      // from `AwayRefusal`: for a write it cannot be told from "not confirmed
      // yet", and the SDK delivers it either way.
      for (final code in const [
        'aborted',
        'resource-exhausted',
        'unavailable',
        'deadline-exceeded',
        'something-a-later-sdk-invents',
      ]) {
        expect(AwayRepository.refusalForCode(code), AwayRefusal.serverFault,
            reason: '$code must not become a claim about this phone');
      }
    });
  });

  group('classifyRead — ADR-0004\'s three states, kept apart', () {
    AwayRead classify(String code, {String? message}) =>
        AwayRepository.classifyRead(FirebaseException(
          plugin: 'cloud_firestore',
          code: code,
          message: message,
        ));

    test('a permission denial is REFUSED — the server answered', () {
      final read = classify('permission-denied');
      expect(read.verification, Verification.refused);
      expect((read as AwayReadRefused).cause, RefusedCause.permissionDenied);
    });

    test('an App Check rejection is refused, by its message', () {
      final read = classify('failed-precondition',
          message: 'Firebase App Check token is invalid');
      expect((read as AwayReadRefused).cause, RefusedCause.appCheckRejected);
    });

    test('a failed-precondition that is NOT App Check is unreachable', () {
      expect(classify('failed-precondition').verification,
          Verification.unreachable);
    });

    test('unavailable and deadline-exceeded are unreachable', () {
      expect((classify('unavailable') as AwayReadUnreachable).cause,
          UnreachableCause.offline);
      expect((classify('deadline-exceeded') as AwayReadUnreachable).cause,
          UnreachableCause.timeout);
    });

    test('an unrecognised code is unreachable, never refused', () {
      // Guessing "refused" would post the access-lost notice — "I Am Ok has
      // lost access" — for what might be a transient fault. Being wrong towards
      // unreachable claims less and heals by itself.
      expect(classify('internal').verification, Verification.unreachable);
    });

    test('only a succeeded read may replace the cache', () {
      expect(const AwayRead.succeeded(null).succeeded, isTrue);
      expect(const AwayRead.unreachable().succeeded, isFalse);
      expect(const AwayRead.refused().succeeded, isFalse);
    });

    test('awayOrNull is null for a FAILED read as well as an absent document',
        () {
      // Which is exactly why a caller must ask `succeeded` first. Pinned so the
      // convenience cannot quietly become the thing somebody branches on.
      expect(const AwayRead.unreachable().awayOrNull, isNull);
      expect(const AwayRead.succeeded(null).awayOrNull, isNull);
    });
  });

  group('decode — a stored document', () {
    test('a well-formed document round-trips with its attribution', () {
      final record = AwayRepository.decode(<String, dynamic>{
        'from': '2026-08-15',
        'through': '2026-08-22',
        'setBy': 'ana-uid',
        'setByName': 'Ana',
      });
      expect(record!.period.from, day('2026-08-15'));
      expect(record.period.through, day('2026-08-22'));
      expect(record.setByName, 'Ana');
    });

    test('an absent document is no away period', () {
      expect(AwayRepository.decode(null), isNull);
    });

    test('non-string days are no away period', () {
      expect(
        AwayRepository.decode(<String, dynamic>{'from': 1, 'through': 2}),
        isNull,
      );
    });

    test('through before from is no away period', () {
      expect(
        AwayRepository.decode(<String, dynamic>{
          'from': '2026-08-22',
          'through': '2026-08-15',
        }),
        isNull,
      );
    });

    test('a missing name degrades the LABEL and keeps the period', () {
      final record = AwayRepository.decode(<String, dynamic>{
        'from': '2026-08-15',
        'through': '2026-08-22',
      });
      expect(record, isNotNull, reason: "ADR-0003's Absence case");
      expect(record!.setByName, isNull);
      expect(record.period.through, day('2026-08-22'));
    });

    test('a non-string name is dropped, not stringified', () {
      final record = AwayRepository.decode(<String, dynamic>{
        'from': '2026-08-15',
        'through': '2026-08-22',
        'setBy': 'ana-uid',
        'setByName': 42,
      });
      expect(record!.setByName, isNull);
      expect(record.setBy, 'ana-uid');
    });
  });

  group('write refuses before it sends', () {
    // These are the two refusals reachable with no network at all, so they are
    // asserted against the real method rather than against `send`.
    final today = day('2026-08-15');
    final period =
        AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22'));

    test('nobody signed in is refused without a document path being built', () {
      expect(
        repository.write(
          watchedUid: 'mum-uid',
          setBy: '',
          setByName: 'Ana',
          period: period,
          today: today,
        ),
        completion(isA<AwayRefused>().having(
            (r) => r.refusal, 'refusal', AwayRefusal.notSignedIn)),
      );
    });

    test('a retroactive from is refused before anything is sent', () {
      // Reachable by the CLOCK rather than by the picker: a device whose date
      // moves between opening the picker and confirming it turns a legal `from`
      // into a retroactive one. §11 surfaces skew rather than correcting it.
      expect(
        repository.write(
          watchedUid: 'mum-uid',
          setBy: 'mum-uid',
          setByName: 'Mum',
          period:
              AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
          today: today,
        ),
        completion(isA<AwayRefused>().having(
            (r) => r.refusal, 'refusal', AwayRefusal.rejectedPeriod)),
      );
    });

    test('a period over the cap is refused before anything is sent', () {
      expect(
        repository.write(
          watchedUid: 'mum-uid',
          setBy: 'mum-uid',
          setByName: 'Mum',
          period: AwayPeriod(
            from: today,
            through: today.plusDays(AwayRules.maxDaysAhead + 1),
          ),
          today: today,
        ),
        completion(isA<AwayRefused>().having(
            (r) => r.refusal, 'refusal', AwayRefusal.rejectedPeriod)),
      );
    });

    test('an update that moves `from` is refused before anything is sent', () {
      // ADR-0001 decision 6. `from` is immutable once written, and the update
      // path exists so that TRUNCATING an in-progress period — whose `from` is
      // already in the past — is not rejected as retroactive.
      expect(
        repository.write(
          watchedUid: 'mum-uid',
          setBy: 'mum-uid',
          setByName: 'Mum',
          period:
              AwayPeriod(from: day('2026-08-16'), through: day('2026-08-22')),
          today: today,
          existing:
              AwayPeriod(from: day('2026-08-10'), through: day('2026-08-22')),
        ),
        completion(isA<AwayRefused>().having(
            (r) => r.refusal, 'refusal', AwayRefusal.rejectedPeriod)),
      );
    });
  });
}
