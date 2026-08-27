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
/// The first **seven** are answers the server gave; the last three are
/// conditions this phone reaches without one. They are one enum because the
/// **screen** does not care where the refusal came from — it has to say one
/// honest sentence either way — and splitting them would let a caller handle one
/// set and forget the other.
///
/// The count in that first sentence was wrong before Phase 5 closed — it said
/// *"the first four"* against seven server statuses — which is the small version
/// of the failure this whole file exists to prevent: a claim nobody read back
/// against the thing it describes.
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

  /// **This phone could not reach the backend at all.** A dead radio, a
  /// captive portal, a request that timed out on the wire.
  ///
  /// Narrow on purpose, because its sentence names an action — *check your
  /// connection* — that only works when the claim is true. ADR-0004's *refused
  /// is not unreachable* rule is the same rule one layer down: this build used
  /// to say it whenever it had no better case, which told somebody whose phone
  /// had just carried a request and an answer to go and check their internet.
  /// [serverFault] is where "no better case" goes now.
  couldNotReach,

  /// The backend was reached, answered, and the answer was one this build
  /// cannot act on — a fault on the far side, or a payload it does not
  /// understand.
  ///
  /// Its sentence deliberately claims nothing about **either** side. The reader
  /// cannot repair a failed transaction and cannot repair a build that is a
  /// version behind the backend; the only true thing to say is that it did not
  /// work and that trying again is reasonable.
  serverFault,

  /// Nobody is signed in, so there is no watcher for the link to name.
  notSignedIn,
}

/// Whether a refusal is a claim about **the code**, or about something else.
///
/// Decides where the sentence is rendered, and that is a correctness question
/// rather than a layout one. `EnterCodeScreen` put every refusal into the
/// `TextField`'s `errorText`, which does not merely print a sentence — it puts
/// the field into its **error state**: red outline, red *"Code"* label. So a
/// server fault, a dead radio or a missing profile on *this* phone all marked
/// the code invalid, on paths where nothing whatever is known about the code.
///
/// `screens.md` says the opposite in as many words — *"The last four are not
/// the reader's mistake and none of them says 'not right'"* — and the copy
/// honours it while the colour contradicted it. Colour is what a reader takes
/// first, so what a family member saw was: type a good code, the field turns
/// red, retype the same six characters, loop.
///
/// **Exhaustive on purpose.** A refusal added later cannot default into either
/// bucket; the switch stops compiling until somebody decides.
extension PairingRefusalSurface on PairingRefusal {
  /// True when re-reading or re-typing the code is the action that helps.
  bool get isAboutTheCode => switch (this) {
        // The four a person fixes by looking at the code again — or, for
        // [PairingRefusal.ownCode], by looking at which phone they are holding.
        // In all four the code is genuinely the subject of the sentence.
        PairingRefusal.unknownCode ||
        PairingRefusal.expired ||
        PairingRefusal.alreadyUsed ||
        PairingRefusal.ownCode =>
          true,
        // Everything else is about a phone, a profile, a radio or a backend.
        // The code may well be perfectly good, and marking it invalid sends the
        // reader to check the one thing that is not wrong.
        PairingRefusal.watchedProfileMissing ||
        PairingRefusal.watcherProfileMissing ||
        PairingRefusal.unusableTimezone ||
        PairingRefusal.couldNotReach ||
        PairingRefusal.serverFault ||
        PairingRefusal.notSignedIn =>
          false,
      };
}

/// Why this phone could not produce a code to share.
enum InviteRefusal {
  /// No `users/{uid}` for the caller, so a redeemer would have no name or zone
  /// to copy onto the link.
  profileMissing,

  /// This phone could not reach the backend. Nothing was created; trying again
  /// is right. Narrow, for the reason its [PairingRefusal] twin records.
  couldNotReach,

  /// The backend answered and this build cannot act on the answer. Nothing was
  /// created either way, and the sentence claims nothing about which side.
  serverFault,

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
