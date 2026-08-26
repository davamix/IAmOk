/// What happened when this phone tried to make or use a pairing code.
///
/// These types live in **Domain** rather than beside `InviteService` in Data for
/// one reason: §5 says copy is a leaf that *"depends on the domain (for the enums
/// it switches on) and on nothing else"*. `OnboardingCopy` switches on
/// [PairingRefusal] to choose a sentence, so the enum has to be reachable from
/// there without dragging `cloud_functions` along behind it.
///
/// ## Sealed, so the copy switch is total
///
/// A refusal with no sentence is a screen that says nothing, or says the wrong
/// thing. `OPEN-QUESTIONS.md` #5 records what the loose version of this costs
/// elsewhere in the app: `_mentionsAppCheck` decides which message a family sees
/// by matching an **English substring**, and anything unrecognised falls through
/// to a claim about the device that is false. A sealed type plus an exhaustive
/// switch makes the same mistake a compile error.
library;

/// Why a code could not be turned into a link.
///
/// The first four are the server's answers; the last three are conditions this
/// phone reaches on its own. They are one enum because the **screen** does not
/// care where the refusal came from — it has to say one honest sentence either
/// way — and splitting them would let a caller handle one set and forget the
/// other.
enum PairingRefusal {
  /// No invite with that code. A typo, or a code that was never real.
  unknownCode,

  /// The code existed and its 24 hours are up.
  expired,

  /// Somebody else redeemed it. Codes are single-use by design (§8).
  alreadyUsed,

  /// The redeemer is the person the code is for. A link to yourself would warn
  /// you about your own missed day and name you as your own watcher.
  ownCode,

  /// `users/{watchedUid}` is gone, so there is no name or zone to denormalise
  /// onto the link (§7).
  watchedProfileMissing,

  /// This phone has no `users/{uid}` document, so the link would carry no
  /// `watcherName` — and ADR-0005's Tap screen cannot be rendered without one.
  watcherProfileMissing,

  /// The watched person's stored zone is not one this backend can resolve.
  /// Refused rather than defaulted: `Link.tryWatchedZone` calls an unresolvable
  /// zone *"a permanently silent watcher, which is the one failure this app
  /// cannot detect in itself"*.
  unusableTimezone,

  /// The call did not complete. Distinct from every refusal above, because
  /// nothing was decided — trying again is the right next action, and none of
  /// the other sentences would be true.
  couldNotReach,

  /// Nobody is signed in, so there is no watcher for the link to name.
  notSignedIn,
}

/// Why this phone could not produce a code to share.
enum InviteRefusal {
  /// No `users/{uid}` for the caller, so a redeemer would have no name or zone
  /// to copy onto the link.
  profileMissing,

  /// The call did not complete. Nothing was created; trying again is right.
  couldNotReach,

  /// Nobody is signed in, so there is no watched person for a code to name.
  notSignedIn,
}

/// The result of redeeming a code.
sealed class PairingOutcome {
  const PairingOutcome();
}

/// A link now exists, with this phone as the **watcher**.
final class Paired extends PairingOutcome {
  const Paired({
    required this.watchedName,
    required this.linkId,
    required this.alreadyLinked,
  });

  /// The watched person's display name, denormalised off the link (§7).
  ///
  /// **A display label and not an identity** (ADR-0003) — the other user can
  /// rename themselves afterwards and nothing decides anything from it. It is
  /// deliberately the only thing about that person this result carries: §8 keeps
  /// clients out of each other's `users/{uid}`, and the redeemer never learns a
  /// uid they did not already have.
  final String watchedName;

  final String linkId;

  /// True when this exact pairing already existed — a retry after a dropped
  /// response, which §7's deterministic link id makes harmless. The screen says
  /// the same thing either way; nothing about the outcome differs, and telling
  /// somebody their second tap was redundant is noise.
  final bool alreadyLinked;

  @override
  bool operator ==(Object other) =>
      other is Paired &&
      other.watchedName == watchedName &&
      other.linkId == linkId &&
      other.alreadyLinked == alreadyLinked;

  @override
  int get hashCode => Object.hash(watchedName, linkId, alreadyLinked);

  @override
  String toString() =>
      'Paired($linkId, $watchedName, alreadyLinked: $alreadyLinked)';
}

/// No link was made, and [reason] says what to tell the person holding the code.
final class PairingRefused extends PairingOutcome {
  const PairingRefused(this.reason);

  final PairingRefusal reason;

  @override
  bool operator ==(Object other) =>
      other is PairingRefused && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'PairingRefused(${reason.name})';
}

/// The result of asking for a code to share.
sealed class InviteOutcome {
  const InviteOutcome();
}

/// A code somebody can now be given.
final class InviteReady extends InviteOutcome {
  const InviteReady({required this.code, required this.expiresAt});

  /// Six characters from `InviteCode.alphabet`, upper case, ungrouped.
  /// `InviteCode.forReading` is what puts the space in for the screen.
  final String code;

  /// When it stops working — **UTC**, rendered in the reader's own zone and
  /// their own 12/24-hour setting by the screen, never here.
  final DateTime expiresAt;

  @override
  bool operator ==(Object other) =>
      other is InviteReady &&
      other.code == code &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(code, expiresAt);

  @override
  String toString() => 'InviteReady($code, expires $expiresAt)';
}

/// No code was produced.
final class InviteRefused extends InviteOutcome {
  const InviteRefused(this.reason);

  final InviteRefusal reason;

  @override
  bool operator ==(Object other) =>
      other is InviteRefused && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'InviteRefused(${reason.name})';
}
