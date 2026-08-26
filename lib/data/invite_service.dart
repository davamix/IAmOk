import 'package:cloud_functions/cloud_functions.dart';

import '../domain/domain.dart';
import 'firebase_bootstrap.dart';

/// Create an invite; call `redeemInvite` (§6).
///
/// **Both halves are callables, and neither could be a client write.** §8 makes
/// `invites/{code}` unreadable and unwritable by every client — `firestore.rules`
/// says `allow read, write: if false` in both directions — because a readable
/// invite collection is an enumerable list of live codes, and a *writable* one
/// is the same list reachable through failed creates. So this class holds no
/// Firestore reference at all; it holds two function names.
///
/// §9 originally listed only `redeemInvite`, which left §6's "create invite" as
/// something the client was expected to do and could not. ADR-0011 records the
/// resolution: `createInvite` is a Function, exactly as §8 always said.
///
/// **No background entry point calls a callable** — a nudge carries no authority
/// (§3), and an isolate with seconds to live has nothing to ask. This class is
/// reached only from the UI isolate, which `domain_purity_test.dart` enforces by
/// computing the closure from both background entry points.
///
/// The `cloud_functions` *package* is a different question and is in all three
/// isolates, because `FirebaseBootstrap` imports it to wire the emulator. See
/// §15.
class InviteService {
  InviteService({FirebaseFunctions? functions}) : _injected = functions;

  // Resolved on use, not in the constructor, exactly as the repositories here
  // do it: `FirebaseFunctions.instanceFor` throws before Firebase is
  // initialised, and this is built inside the composition root.
  final FirebaseFunctions? _injected;

  /// **The region is named, and it is not optional.**
  ///
  /// The plugin's default is `us-central1`. A callable asked for there does not
  /// fall back to `europe-west1` — it 404s, which surfaces as a
  /// `FirebaseFunctionsException` with code `not-found` and reads like a
  /// function that was never deployed. `FirebaseBootstrap` holds the one copy of
  /// the region so this and the emulator wiring cannot disagree.
  FirebaseFunctions get _functions =>
      _injected ??
      FirebaseFunctions.instanceFor(region: FirebaseBootstrap.functionsRegion);

  /// Asks for a code this user can give to whoever should know they are OK.
  ///
  /// The caller's uid is **never sent**: the Function reads it from the verified
  /// ID token, because a `watchedUid` parameter would let anybody mint a code
  /// that pairs a stranger's phone to their own.
  ///
  /// Calling twice hands back the **same live code** rather than replacing it —
  /// see `createInviteFor`. That matters on this side because the pairing screen
  /// can be left and re-entered, and a fresh code each time would kill the one
  /// somebody has already written down.
  Future<InviteOutcome> create() async {
    final Map<String, Object?> data;
    try {
      final result = await _functions.httpsCallable('createInvite').call();
      data = asMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      return InviteRefused(inviteRefusalForCode(e.code));
    } on Object {
      // Not the network branch. A dead socket surfaces as `unavailable` or
      // `deadline-exceeded` on the exception above; what lands here is a
      // platform fault — a missing plugin, a channel error, a type this build
      // did not expect. Nothing was created, and the only claim that is true of
      // all of them is that it did not work.
      return const InviteRefused(InviteRefusal.serverFault);
    }

    return inviteFrom(data);
  }

  /// The `createInvite` payload, as an outcome.
  ///
  /// **Separated from the call for the reason `check_in_fan_out.ts` separates
  /// its fan-out**: this is the part that can be wrong, and testing it needs no
  /// plugin, no emulator and no device. `docs/testing/strategy.md`'s rule is
  /// that if a test needs a device to answer a question about *logic*, the logic
  /// is in the wrong layer — and a total mapping from a wire status to a
  /// sentence a family reads is logic.
  static InviteOutcome inviteFrom(Map<String, Object?> data) {
    switch (data['status']) {
      case 'created':
        final code = data['code'];
        final expiresAt = data['expiresAt'];
        if (code is! String || expiresAt is! String) {
          return const InviteRefused(InviteRefusal.serverFault);
        }
        final parsed = DateTime.tryParse(expiresAt);
        // **An offset-less timestamp is refused, not repaired.**
        //
        // This used to say the `toUtc()` below was *"belt and braces against a
        // future sender that omits the `Z`"*. It is the opposite:
        // `DateTime.tryParse('2026-08-27T09:00:00')` with no offset yields a
        // **local** instant, and `toUtc()` then shifts it by the device's offset
        // — so the rescue would render the expiry two hours out in Madrid rather
        // than fixing anything, and the result would depend on which phone read
        // it.
        //
        // The Function sends ISO-8601 with a `Z` (`toISOString()`), so an
        // offset-less string is a malformed payload from a backend this build
        // does not understand — which is what `serverFault` is for. It was
        // `couldNotReach` until Phase 5 closed, which told somebody who had just
        // received a payload to go and check their internet connection.
        if (parsed == null || !parsed.isUtc) {
          return const InviteRefused(InviteRefusal.serverFault);
        }
        return InviteReady(code: code, expiresAt: parsed);
      case 'watched-profile-missing':
        return const InviteRefused(InviteRefusal.profileMissing);
      default:
        // A status this build has no case for — a backend a version ahead of
        // this APK. Not guessed at, and **not** reported as unreachable: the
        // phone carried a request and read an answer, so the one sentence that
        // names the internet is the one sentence that is certainly false.
        return const InviteRefused(InviteRefusal.serverFault);
    }
  }

  /// A `FirebaseFunctionsException` code, as the sentence a reader gets.
  ///
  /// **Lifted out of the `catch` so it can be tested at all.** The status
  /// mapping below it has been a pure function since this class was written;
  /// this half sat inside an exception handler no unit test can enter, and it
  /// was wrong — every code that was not `unauthenticated` produced *"Could not
  /// reach the internet"*, including `internal` (the transaction failed on the
  /// far side), `not-found` (the region is wrong, ADR-0011's own trap) and
  /// `permission-denied` (App Check, once it is enforced).
  ///
  /// Only the two codes that actually mean *the request did not get there* keep
  /// [PairingRefusal.couldNotReach]. Everything else claims nothing about either
  /// side. gRPC's `unavailable` covers a dead radio and a refused connection;
  /// `deadline-exceeded` covers a request that went out and never came back —
  /// unreachable *from this phone's point of view*, which is all the sentence
  /// claims.
  static PairingRefusal refusalForCode(String code) => switch (code) {
        'unauthenticated' => PairingRefusal.notSignedIn,
        'unavailable' || 'deadline-exceeded' => PairingRefusal.couldNotReach,
        _ => PairingRefusal.serverFault,
      };

  /// [refusalForCode]'s twin for `createInvite`. Same three answers, same
  /// reasoning; a separate enum because the two screens refuse for different
  /// sets of reasons and one enum would let a caller handle a case that cannot
  /// happen on its screen.
  static InviteRefusal inviteRefusalForCode(String code) => switch (code) {
        'unauthenticated' => InviteRefusal.notSignedIn,
        'unavailable' || 'deadline-exceeded' => InviteRefusal.couldNotReach,
        _ => InviteRefusal.serverFault,
      };

  /// Turns a code somebody was given into a link, with this phone as the
  /// **watcher**.
  ///
  /// [rawCode] is whatever a person typed. It is normalised here — upper-cased,
  /// spaces and hyphens stripped — and a shape this build cannot parse is
  /// refused **without a round trip**, which is a UX affordance and never a
  /// control: `redeemInvite` re-checks the shape itself, because functions
  /// bypass the rules and the client is untrusted by definition.
  Future<PairingOutcome> redeem(String rawCode) async {
    final code = InviteCode.tryParse(rawCode);
    if (code == null) {
      return const PairingRefused(PairingRefusal.unknownCode);
    }

    final Map<String, Object?> data;
    try {
      final result = await _functions
          .httpsCallable('redeemInvite')
          .call<Object?>({'code': code});
      data = asMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      return PairingRefused(refusalForCode(e.code));
    } on Object {
      return const PairingRefused(PairingRefusal.serverFault);
    }

    return pairingFrom(data);
  }

  /// The `redeemInvite` payload, as an outcome.
  ///
  /// Separated from the call for the same reason [inviteFrom] is, and it matters
  /// more here: this switch is what decides which sentence a family reads after
  /// they type a code, and **every branch of it is a claim**.
  static PairingOutcome pairingFrom(Map<String, Object?> data) {
    switch (data['status']) {
      case 'linked':
        final watchedName = data['watchedName'];
        final linkId = data['linkId'];
        if (linkId is! String || linkId.isEmpty) {
          // The pairing may well have happened; this build cannot say so,
          // because the id it would record it under is not in the payload.
          return const PairingRefused(PairingRefusal.serverFault);
        }
        return Paired(
          watchedName: watchedName is String ? watchedName : '',
          linkId: linkId,
          alreadyLinked: data['alreadyLinked'] == true,
        );
      case 'unknown-code':
        return const PairingRefused(PairingRefusal.unknownCode);
      case 'expired':
        return const PairingRefused(PairingRefusal.expired);
      case 'consumed':
        return const PairingRefused(PairingRefusal.alreadyUsed);
      case 'self':
        return const PairingRefused(PairingRefusal.ownCode);
      case 'watched-profile-missing':
        return const PairingRefused(PairingRefusal.watchedProfileMissing);
      case 'watcher-profile-missing':
        return const PairingRefused(PairingRefusal.watcherProfileMissing);
      case 'unusable-timezone':
        return const PairingRefused(PairingRefusal.unusableTimezone);
      default:
        return const PairingRefused(PairingRefusal.serverFault);
    }
  }

  /// The callable's payload as a map, whatever the platform channel handed back.
  ///
  /// `HttpsCallableResult.data` is `dynamic` and arrives from Android as a
  /// `Map<Object?, Object?>`, not a `Map<String, Object?>` — a direct cast
  /// throws, and it would throw *after* the call succeeded, turning a completed
  /// pairing into a reported failure.
  static Map<String, Object?> asMap(Object? data) {
    if (data is Map) {
      return <String, Object?>{
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    }
    return const <String, Object?>{};
  }
}
