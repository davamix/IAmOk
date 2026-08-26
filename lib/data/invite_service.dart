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
/// **UI isolate only.** No background entry point calls a function — a nudge
/// carries no authority (§3), and an isolate with seconds to live has nothing to
/// ask.
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
      return InviteRefused(
        e.code == 'unauthenticated'
            ? InviteRefusal.notSignedIn
            : InviteRefusal.couldNotReach,
      );
    } on Object {
      // A platform fault, a dead socket, a response that is not a map. Nothing
      // was created, and "try again" is the honest next action — which is what
      // `couldNotReach` means and why it is distinct from every refusal.
      return const InviteRefused(InviteRefusal.couldNotReach);
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
          return const InviteRefused(InviteRefusal.couldNotReach);
        }
        final parsed = DateTime.tryParse(expiresAt);
        if (parsed == null) {
          return const InviteRefused(InviteRefusal.couldNotReach);
        }
        // **UTC, always.** The Function sends ISO-8601 with a `Z`, so this
        // parses to an absolute instant rather than to the device's zone; the
        // `toUtc()` is belt and braces against a future sender that omits it,
        // because a local-zone instant here would render an expiry hours out on
        // a screen whose whole job is to say when the code stops working.
        return InviteReady(code: code, expiresAt: parsed.toUtc());
      case 'watched-profile-missing':
        return const InviteRefused(InviteRefusal.profileMissing);
      default:
        // A status this build has no case for. Reported as unreachable rather
        // than guessed at: every other sentence would be a claim about what
        // happened, and this build does not know.
        return const InviteRefused(InviteRefusal.couldNotReach);
    }
  }

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
      return PairingRefused(
        e.code == 'unauthenticated'
            ? PairingRefusal.notSignedIn
            : PairingRefusal.couldNotReach,
      );
    } on Object {
      return const PairingRefused(PairingRefusal.couldNotReach);
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
          return const PairingRefused(PairingRefusal.couldNotReach);
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
        return const PairingRefused(PairingRefusal.couldNotReach);
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
