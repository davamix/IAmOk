import '../reconcile/firestore_read.dart';
import 'away_record.dart';

/// What an attempt to read `users/{uid}/shared/away` actually established.
///
/// The watched side's twin of [FirestoreRead], and it exists for the same
/// reason that one is a sealed type rather than a nullable value: **a read that
/// fails is not an answer** (ADR-0001 decision 1). A nullable [AwayRecord]
/// cannot tell *"Firestore says there is no away period"* from *"I could not
/// ask"*, and collapsing those wipes a legitimate away on a transient error.
///
/// ## Why this is a separate type and not [FirestoreRead]
///
/// [FirestoreRead] answers a **watcher's** question about somebody else — it
/// carries `checkInDays` because the away period and the check-ins are read in
/// one pass and decided on together. The watched person's own read has no
/// check-in half: she knows her own taps from `LocalStore`, which is the record
/// the screen has always rendered from.
///
/// Reusing it would mean a `checkInDays` that is always empty on this path and
/// means nothing — and an empty set of check-in days is not inert here, it is
/// the exact shape of *"she has not tapped"*. A field that means one thing on
/// one caller and nothing on another is how the wrong half gets read.
///
/// [UnreachableCause] and [RefusedCause] are shared, because those genuinely are
/// the same facts about the same backend.
sealed class AwayRead {
  const AwayRead();

  /// The server answered. [away] may still be null — meaning Firestore holds no
  /// away document, which is the signal that clears a **cancelled** away.
  const factory AwayRead.succeeded(AwayRecord? away) = AwayReadSucceeded;

  const factory AwayRead.unreachable([UnreachableCause cause]) =
      AwayReadUnreachable;

  const factory AwayRead.refused([RefusedCause cause]) = AwayReadRefused;

  Verification get verification => switch (this) {
        AwayReadSucceeded() => Verification.verified,
        AwayReadUnreachable() => Verification.unreachable,
        AwayReadRefused() => Verification.refused,
      };

  /// True only for [AwayReadSucceeded] — the one gate on replacing the cached
  /// period, including with nothing.
  bool get succeeded => this is AwayReadSucceeded;

  /// The record this read established, or null.
  ///
  /// **Null for a failed read as well as for an absent document**, which is
  /// precisely why callers must ask [succeeded] first and never branch on this
  /// alone. It exists so the one caller that has already checked does not have
  /// to pattern-match a second time.
  AwayRecord? get awayOrNull =>
      this is AwayReadSucceeded ? (this as AwayReadSucceeded).away : null;
}

final class AwayReadSucceeded extends AwayRead {
  const AwayReadSucceeded(this.away);

  final AwayRecord? away;

  @override
  String toString() => 'AwayReadSucceeded($away)';
}

final class AwayReadUnreachable extends AwayRead {
  const AwayReadUnreachable([this.cause = UnreachableCause.unknown]);

  final UnreachableCause cause;

  @override
  String toString() => 'AwayReadUnreachable(${cause.name})';
}

final class AwayReadRefused extends AwayRead {
  const AwayReadRefused([this.cause = RefusedCause.unknown]);

  final RefusedCause cause;

  @override
  String toString() => 'AwayReadRefused(${cause.name})';
}
