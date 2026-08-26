import 'package:i_am_ok/data/invite_service.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// The wire-status → outcome mapping, which is what decides the sentence a
/// family reads after they type a code.
///
/// **Every branch here is a claim**, and the failure this pins is the one
/// `OPEN-QUESTIONS.md` #5 records elsewhere in the app: a status this build has
/// no case for must not fall through to a sentence that says something else
/// happened. `couldNotReach` is the only honest answer to *the backend said
/// something I do not understand*, because nothing was decided that this build
/// can describe.
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

    test('an unrecognised status is unreachable, never invented', () {
      expect(
        InviteService.inviteFrom(const {'status': 'something-new'}),
        const InviteRefused(InviteRefusal.couldNotReach),
      );
    });

    test('an empty or shapeless payload is unreachable', () {
      expect(
        InviteService.inviteFrom(const {}),
        const InviteRefused(InviteRefusal.couldNotReach),
      );
    });

    test('created with a missing or unparseable field is unreachable', () {
      for (final broken in <Map<String, Object?>>[
        {'status': 'created', 'expiresAt': '2026-08-27T09:00:00.000Z'},
        {'status': 'created', 'code': 'K7RTQX'},
        {'status': 'created', 'code': 'K7RTQX', 'expiresAt': 'not-a-date'},
        {'status': 'created', 'code': 42, 'expiresAt': '2026-08-27T09:00:00Z'},
      ]) {
        expect(
          InviteService.inviteFrom(broken),
          const InviteRefused(InviteRefusal.couldNotReach),
          reason: 'payload $broken',
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

    test('an unrecognised status is unreachable, never invented', () {
      expect(
        InviteService.pairingFrom(const {'status': 'brand-new-refusal'}),
        const PairingRefused(PairingRefusal.couldNotReach),
      );
    });

    test('linked with no usable link id is unreachable, not a pairing', () {
      for (final broken in <Map<String, Object?>>[
        {'status': 'linked', 'watchedName': 'Mum'},
        {'status': 'linked', 'linkId': '', 'watchedName': 'Mum'},
        {'status': 'linked', 'linkId': 7, 'watchedName': 'Mum'},
      ]) {
        expect(
          InviteService.pairingFrom(broken),
          const PairingRefused(PairingRefusal.couldNotReach),
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
        const PairingRefused(PairingRefusal.couldNotReach),
      );
    });
  });
}
