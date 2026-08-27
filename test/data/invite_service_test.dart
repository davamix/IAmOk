import 'package:i_am_ok/data/invite_service.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// The wire-status → outcome mapping, which is what decides the sentence a
/// family reads after they type a code.
///
/// **Every branch here is a claim**, and the failure this pins is the one
/// `OPEN-QUESTIONS.md` #5 records elsewhere in the app: a status this build has
/// no case for must not fall through to a sentence that says something else
/// happened.
///
/// **The header above used to name `couldNotReach` as that answer**, and it was
/// wrong in the way this file exists to catch: a backend that *"said something I
/// do not understand"* was reached, so the one thing certainly false about it is
/// that the phone could not reach the internet. `serverFault` is the honest
/// answer, and `couldNotReach` is now narrow — the two gRPC codes that mean the
/// request did not arrive.
void main() {
  group('createInvite', () {
    test('a created code, with the expiry as an absolute instant', () {
      final outcome = InviteService.inviteFrom(const {
        'status': 'created',
        'code': 'K7RTQX',
        'expiresAt': '2026-08-27T09:00:00.000Z',
        'reused': false,
      });

      expect(outcome, isA<InviteReady>());
      final ready = outcome as InviteReady;
      expect(ready.code, 'K7RTQX');
      expect(ready.expiresAt, DateTime.utc(2026, 8, 27, 9));
      expect(ready.expiresAt.isUtc, isTrue,
          reason: 'a local-zone instant renders an expiry hours out');
    });

    test('a reused code is indistinguishable to the screen', () {
      final outcome = InviteService.inviteFrom(const {
        'status': 'created',
        'code': 'K7RTQX',
        'expiresAt': '2026-08-27T09:00:00.000Z',
        'reused': true,
      });
      expect((outcome as InviteReady).code, 'K7RTQX');
    });

    test('a missing profile is its own refusal', () {
      expect(
        InviteService.inviteFrom(const {'status': 'watched-profile-missing'}),
        const InviteRefused(InviteRefusal.profileMissing),
      );
    });

    test('an unrecognised status is a server fault, never invented', () {
      expect(
        InviteService.inviteFrom(const {'status': 'something-new'}),
        const InviteRefused(InviteRefusal.serverFault),
      );
    });

    test('an empty or shapeless payload is a server fault', () {
      expect(
        InviteService.inviteFrom(const {}),
        const InviteRefused(InviteRefusal.serverFault),
      );
    });

    test('created with a missing or unparseable field is a server fault', () {
      for (final broken in <Map<String, Object?>>[
        {'status': 'created', 'expiresAt': '2026-08-27T09:00:00.000Z'},
        {'status': 'created', 'code': 'K7RTQX'},
        {'status': 'created', 'code': 'K7RTQX', 'expiresAt': 'not-a-date'},
        // **An offset-less timestamp is refused, not repaired.** `tryParse`
        // yields a LOCAL instant for this, so a `.toUtc()` would shift it by
        // the device's offset rather than rescuing it — and the rendered
        // expiry would then differ between two phones reading the same code.
        // The Function always sends a `Z`, so this is a malformed payload.
        {'status': 'created', 'code': 'K7RTQX', 'expiresAt': '2026-08-27T09:00:00'},
        {'status': 'created', 'code': 42, 'expiresAt': '2026-08-27T09:00:00Z'},
      ]) {
        expect(
          InviteService.inviteFrom(broken),
          const InviteRefused(InviteRefusal.serverFault),
          reason: 'payload $broken — the phone read this, so it reached the '
              'backend; saying otherwise names an action that cannot work',
        );
      }
    });
  });

  group('redeemInvite', () {
    test('a new link', () {
      final outcome = InviteService.pairingFrom(const {
        'status': 'linked',
        'linkId': 'uid-mum_uid-ana',
        'watchedName': 'Mum',
        'activeFrom': '2026-08-26',
        'alreadyLinked': false,
      });

      expect(
        outcome,
        const Paired(
          watchedName: 'Mum',
          linkId: 'uid-mum_uid-ana',
          alreadyLinked: false,
        ),
      );
    });

    test('a retry that found the pairing already done', () {
      final outcome = InviteService.pairingFrom(const {
        'status': 'linked',
        'linkId': 'uid-mum_uid-ana',
        'watchedName': 'Mum',
        'activeFrom': '2026-08-26',
        'alreadyLinked': true,
      });
      expect((outcome as Paired).alreadyLinked, isTrue);
      expect(outcome.watchedName, 'Mum');
    });

    // Every status the Function can return has a case. A gap here is a family
    // reading the wrong sentence about why their code did not work.
    test('every server refusal maps to its own reason', () {
      const expected = <String, PairingRefusal>{
        'unknown-code': PairingRefusal.unknownCode,
        'expired': PairingRefusal.expired,
        'consumed': PairingRefusal.alreadyUsed,
        'self': PairingRefusal.ownCode,
        'watched-profile-missing': PairingRefusal.watchedProfileMissing,
        'watcher-profile-missing': PairingRefusal.watcherProfileMissing,
        'unusable-timezone': PairingRefusal.unusableTimezone,
      };
      expected.forEach((status, reason) {
        expect(
          InviteService.pairingFrom({'status': status}),
          PairingRefused(reason),
          reason: 'status "$status"',
        );
      });
    });

    test('the refusals are distinct — no two share a reason', () {
      final reasons = <PairingRefusal>{};
      for (final status in [
        'unknown-code',
        'expired',
        'consumed',
        'self',
        'watched-profile-missing',
        'watcher-profile-missing',
        'unusable-timezone',
      ]) {
        final outcome =
            InviteService.pairingFrom({'status': status}) as PairingRefused;
        expect(reasons.add(outcome.reason), isTrue,
            reason: '$status reuses ${outcome.reason}');
      }
    });

    test('an unrecognised status is a server fault, never invented', () {
      expect(
        InviteService.pairingFrom(const {'status': 'brand-new-refusal'}),
        const PairingRefused(PairingRefusal.serverFault),
      );
    });

    test('linked with no usable link id is a server fault, not a pairing', () {
      for (final broken in <Map<String, Object?>>[
        {'status': 'linked', 'watchedName': 'Mum'},
        {'status': 'linked', 'linkId': '', 'watchedName': 'Mum'},
        {'status': 'linked', 'linkId': 7, 'watchedName': 'Mum'},
      ]) {
        expect(
          InviteService.pairingFrom(broken),
          const PairingRefused(PairingRefusal.serverFault),
          reason: 'payload $broken',
        );
      }
    });

    test('a linked result with no name still pairs — the link is what matters',
        () {
      final outcome = InviteService.pairingFrom(const {
        'status': 'linked',
        'linkId': 'uid-mum_uid-ana',
      });
      expect(outcome, isA<Paired>());
      expect((outcome as Paired).watchedName, '');
    });
  });

  // The half of this mapping that had no test, because it lived inside a
  // `catch` no unit test can enter — and it was wrong there for the whole of
  // Phase 5: everything that was not `unauthenticated` said *"Could not reach
  // the internet. Check your connection and try again."*
  //
  // ADR-0004's rule is that **refused is not unreachable**. A phone that
  // received `internal` carried a request to Cloud Functions and read an answer
  // back; telling that reader to check their connection names the one action
  // that certainly cannot help.
  group('a FirebaseFunctionsException code, as a refusal', () {
    // Only the two codes that mean *the request did not get there*.
    // `unavailable` is a dead radio or a refused connection; `deadline-exceeded`
    // is a request that went out and never came back — unreachable from this
    // phone's point of view, which is all the sentence claims.
    test('only two codes claim the internet', () {
      for (final code in ['unavailable', 'deadline-exceeded']) {
        expect(InviteService.refusalForCode(code), PairingRefusal.couldNotReach,
            reason: code);
        expect(InviteService.inviteRefusalForCode(code),
            InviteRefusal.couldNotReach,
            reason: code);
      }
    });

    test('an unauthenticated call is the one the reader can fix', () {
      expect(InviteService.refusalForCode('unauthenticated'),
          PairingRefusal.notSignedIn);
      expect(InviteService.inviteRefusalForCode('unauthenticated'),
          InviteRefusal.notSignedIn);
    });

    // Each of these was `couldNotReach` before Phase 5 closed, and each is a
    // reply from a backend the phone reached.
    test('every other code is a server fault', () {
      const codes = <String>[
        // The transaction failed inside `redeemInvite`.
        'internal',
        // The region is wrong — `us-central1` instead of `europe-west1`, which
        // is ADR-0011's own documented trap and 404s rather than falling back.
        'not-found',
        // App Check, once it is enforced (OPEN-QUESTIONS.md #5).
        'permission-denied',
        'resource-exhausted',
        'failed-precondition',
        'invalid-argument',
        'aborted',
        'unimplemented',
        'data-loss',
        'cancelled',
        // A code this build has never heard of.
        'something-the-sdk-added-later',
        '',
      ];
      for (final code in codes) {
        expect(InviteService.refusalForCode(code), PairingRefusal.serverFault,
            reason: 'code "$code"');
        expect(InviteService.inviteRefusalForCode(code),
            InviteRefusal.serverFault,
            reason: 'code "$code"');
      }
    });

    // The two enums answer the same question the same way. They are separate
    // types because the two screens refuse for different sets of reasons, not
    // because a network failure means something different on each.
    test('the two sides agree, code for code', () {
      const pairs = <PairingRefusal, InviteRefusal>{
        PairingRefusal.couldNotReach: InviteRefusal.couldNotReach,
        PairingRefusal.serverFault: InviteRefusal.serverFault,
        PairingRefusal.notSignedIn: InviteRefusal.notSignedIn,
      };
      for (final code in [
        'unauthenticated',
        'unavailable',
        'deadline-exceeded',
        'internal',
        'not-found',
      ]) {
        expect(
          InviteService.inviteRefusalForCode(code),
          pairs[InviteService.refusalForCode(code)],
          reason: 'code "$code"',
        );
      }
    });
  });

  // **Where each refusal's sentence is rendered, decided in the domain.**
  //
  // `errorText` on the code field does not merely print a sentence — it turns
  // the field red and relabels it invalid. That is a second, wordless claim, and
  // it is the one a reader takes first, so it must not be made about a code
  // nothing is known about. `screens.md` says so in words; until the Phase 5
  // gate the screen contradicted it in colour.
  group('which refusals are a claim about the code', () {
    test('the four a person fixes by looking at the code, and only those', () {
      const aboutTheCode = {
        PairingRefusal.unknownCode,
        PairingRefusal.expired,
        PairingRefusal.alreadyUsed,
        PairingRefusal.ownCode,
      };
      for (final reason in PairingRefusal.values) {
        expect(reason.isAboutTheCode, aboutTheCode.contains(reason),
            reason: reason.name);
      }
    });

    test('nothing that names another phone, a radio or the backend', () {
      for (final reason in [
        PairingRefusal.watchedProfileMissing,
        PairingRefusal.watcherProfileMissing,
        PairingRefusal.unusableTimezone,
        PairingRefusal.couldNotReach,
        PairingRefusal.serverFault,
        PairingRefusal.notSignedIn,
      ]) {
        expect(reason.isAboutTheCode, isFalse,
            reason: '${reason.name} would mark a good code invalid');
      }
    });
  });

  group('asMap', () {
    // The Android platform channel hands back Map<Object?, Object?>, and a
    // direct cast would throw AFTER the call succeeded — turning a completed
    // pairing into a reported failure.
    test('accepts the loosely typed map a platform channel returns', () {
      // Typed as a bare Object on purpose: that is all the call site knows
      // about `HttpsCallableResult.data`.
      final Object fromChannel = <Object?, Object?>{
        'status': 'linked',
        'linkId': 'uid-mum_uid-ana',
        'watchedName': 'Mum',
        'alreadyLinked': false,
      };
      final map = InviteService.asMap(fromChannel);
      expect(map['status'], 'linked');
      expect(
        InviteService.pairingFrom(map),
        const Paired(
          watchedName: 'Mum',
          linkId: 'uid-mum_uid-ana',
          alreadyLinked: false,
        ),
      );
    });

    test('drops non-string keys rather than throwing', () {
      final map = InviteService.asMap(<Object?, Object?>{
        'status': 'expired',
        7: 'ignored',
      });
      expect(map, {'status': 'expired'});
    });

    test('a payload that is not a map at all is empty, not a crash', () {
      expect(InviteService.asMap('nonsense'), isEmpty);
      expect(InviteService.asMap(null), isEmpty);
      expect(
        InviteService.pairingFrom(InviteService.asMap(null)),
        const PairingRefused(PairingRefusal.serverFault),
      );
    });
  });
}
