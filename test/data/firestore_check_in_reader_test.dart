@TestOn('vm')
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:i_am_ok/data/firestore_check_in_reader.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// **ADR-0004's mapping, asserted rather than reviewed.**
///
/// The reader turns Firestore conditions into the three-state [FirestoreRead]
/// that everything downstream reasons with, and getting one of them wrong is not
/// a crash — it is a family being told the wrong thing about a relative:
///
/// - a **refused** read misreported as unreachable says *"your phone has been
///   offline"* about a phone that is online and talking to the server;
/// - an **unreachable** read misreported as refused posts the access-lost
///   notice — *"I Am Ok has lost access"* — for a passing network blip;
/// - a **cache hit** misreported as success stamps `lastReconcileAt`, resets
///   ADR-0001's two-day staleness bound, and lets a cached away silence a
///   watcher indefinitely.
///
/// The classification is a pure static function, so it is tested directly.
/// Nothing here needs a Firestore instance, which is the point: the mapping is
/// the risky part and it is reachable without one.
void main() {
  // The private classifier is exercised through `read` in the integration
  // check below; here the concern is the reader's own arithmetic and the two
  // guards it applies before ever asking Firestore anything.

  Link linkTo({String zone = 'Europe/Madrid'}) => Link(
        watchedUid: 'mum',
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: 'Mum',
        watcherName: 'Ana',
        watchedTimezone: zone,
        activeFrom: day('2026-08-01'),
        createdAt: at(madrid, 2026, 8, 1),
      );

  group('a zone this build cannot resolve', () {
    test('reports unreachable, and does not throw', () async {
      // Reachable from a store written by a newer build, a restore, or a zone
      // renamed between tzdata releases. Throwing here would take down the whole
      // reconcile loop inside an alarm isolate — every OTHER watched person
      // would stop being checked because of one bad string, and the only symptom
      // would be silence.
      final reader = FirestoreCheckInReader(
        now: () => at(madrid, 2026, 8, 21, 10),
        // Never reached: the zone check comes first, which is the property
        // being asserted. A Firestore instance here would be a live singleton
        // this test cannot have.
        firestore: null,
      );

      final read = await reader.read(linkTo(zone: 'Mars/Olympus_Mons'));

      expect(read, isA<ReadUnreachable>());
      expect(read.verification, Verification.unreachable,
          reason: 'it claims nothing about the backend, and — this is the half '
              'that matters — it does not clear the away cache');
    });
  });

  group('the read window', () {
    test('is bounded, and that bound is what closes the far-future hazard', () {
      // The reason this is a window rather than "every check-in": a watched
      // device with a badly skewed clock can file a check-in years ahead, §11
      // says skew is detected and never silently corrected, and
      // `lastConfirmedDay` is monotone — so one such document would satisfy
      // §10 step 4 and silence the watcher for ever.
      expect(FirestoreCheckInReader.defaultWindowDays, 8);
      expect(
        FirestoreCheckInReader.defaultWindowDays,
        greaterThan(WarningPolicy.defaultCatchUpDays),
        reason: 'the window must cover every day ADR-0009 may still decide '
            'about, or a caught-up day would be judged against a read that '
            'never asked about it',
      );
    });
  });

  group('the classification is closed, and defaults to the safer answer', () {
    // Asserted through the public surface: `read` catches whatever the
    // injected instance throws. A fake that throws on the first call is enough,
    // because the away read is the first thing attempted.
    Future<FirestoreRead> readThrowing(Object error) async {
      final reader = FirestoreCheckInReader(
        now: () => at(madrid, 2026, 8, 21, 10),
        firestore: _ThrowingFirestore(error),
      );
      return reader.read(linkTo());
    }

    test('permission-denied is REFUSED, not offline', () async {
      final read = await readThrowing(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
      expect(read, isA<ReadRefused>());
      expect((read as ReadRefused).cause, RefusedCause.permissionDenied);
    });

    test('unauthenticated is REFUSED — an expired token is not a network fault',
        () async {
      final read = await readThrowing(
        FirebaseException(plugin: 'cloud_firestore', code: 'unauthenticated'),
      );
      expect((read as ReadRefused).cause, RefusedCause.unauthenticated);
    });

    test('an App Check rejection is REFUSED, and named as itself', () async {
      // It has no distinct code; the SDK reports it as failed-precondition with
      // App Check in the message. The cause matters because §13 drives a
      // different remediation from it — "update the app", not "sign in again".
      final read = await readThrowing(
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
          message: 'Request throttled or missing App Check token',
        ),
      );
      expect((read as ReadRefused).cause, RefusedCause.appCheckRejected);
    });

    test('unavailable and deadline-exceeded are UNREACHABLE', () async {
      expect(
        await readThrowing(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        ),
        isA<ReadUnreachable>(),
      );
      expect(
        await readThrowing(
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'deadline-exceeded',
          ),
        ),
        isA<ReadUnreachable>(),
      );
    });

    test('a failed-precondition that is NOT App Check stays unreachable',
        () async {
      // The usual cause is a missing index. Nothing about it says the backend
      // turned us away, and guessing "refused" would post the access-lost notice
      // — a message that exists to be actionable — for something the reader can
      // do nothing about.
      final read = await readThrowing(
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
          message: 'The query requires an index',
        ),
      );
      expect(read, isA<ReadUnreachable>());
    });

    test('an UNFAMILIAR code defaults to unreachable, never to refused',
        () async {
      // The direction of the default is the decision. Being wrong towards "your
      // phone could not reach the server" claims less about the app's health and
      // heals by itself; being wrong towards "refused" tells a family the app
      // has lost sight of their relative.
      final read = await readThrowing(
        FirebaseException(plugin: 'cloud_firestore', code: 'resource-exhausted'),
      );
      expect(read, isA<ReadUnreachable>());
    });

    test('a non-Firebase throw is unreachable and does NOT escape', () async {
      // This runs in an alarm isolate with seconds to live and nothing to report
      // a throw to. An exception escaping here is silence.
      final read = await readThrowing(StateError('malformed document'));
      expect(read, isA<ReadUnreachable>());
    });
  });
}

/// A `FirebaseFirestore` that throws on first use.
///
/// Deliberately minimal: `read` reaches for `doc(...)` before anything else, so
/// throwing there covers every path this file asserts. Implementing the rest of
/// the interface would be inventing behaviour nothing here depends on.
class _ThrowingFirestore implements FirebaseFirestore {
  _ThrowingFirestore(this.error);

  final Object error;

  @override
  DocumentReference<Map<String, dynamic>> doc(String path) => throw error;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw error;
}
