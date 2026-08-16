import '../away/away_period.dart';
import '../time/day_key.dart';

/// What a reconcile attempt actually established.
///
/// Three states, not two, and not a bool — [ADR-0004][]. "Could not reach the
/// server" and "reached the server and was refused" are different facts about
/// the *device*, and §10 requires the notification to say what is actually
/// known. Collapsing them makes the app claim a working phone is offline.
///
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
enum Verification {
  /// The server answered. Whatever it said is the truth.
  verified,

  /// The server could not be reached. *"Your phone has been offline since
  /// HH:MM"* is true.
  unreachable,

  /// The server was reached and refused. The device is online and working, so
  /// the offline wording would be a false claim about it — and the fault is in
  /// the app's access, not in the watched person's day.
  refused,
}

/// Why the server could not be reached.
///
/// Informational: [Verification.unreachable] is what the decision branches on.
enum UnreachableCause { offline, timeout, unknown }

/// Why the server refused.
///
/// Drives the health panel's remediation (§13) — "sign in again" and "update
/// the app" are different instructions — but not the warning decision, which
/// treats every refusal alike.
enum RefusedCause {
  /// Rules said no. After a revocation this is the expected answer, because §8
  /// gates the `checkins` read on an accepted link existing.
  permissionDenied,

  /// No valid auth token. Signed out, or the token expired.
  unauthenticated,

  /// App Check (Play Integrity) rejected the install. §9 provisions it in
  /// monitoring mode in Phase 4; enforcement is a separate, later step.
  appCheckRejected,

  unknown,
}

/// The result of the Firestore read the watcher attempts **before** consulting
/// any cache (ADR-0001 decision 1).
///
/// > A read that **fails is not an answer.** Only a read that succeeded and
/// > returned nothing may clear the cache.
///
/// That rule is why this is a sealed type rather than a nullable [AwayPeriod]:
/// a nullable result cannot distinguish "Firestore says there is no away
/// period" from "I could not ask", and collapsing those wipes a legitimate away
/// on a transient error and warns falsely.
///
/// ADR-0004 splits the failure side for the same reason, one level down. The
/// rule above is about **cache retention**, where the cause of failure is
/// genuinely irrelevant; it is not about **message selection**, where the cause
/// decides which of two sentences is true.
///
/// **Phase 4 mapping** — named here so it is not guessed later:
///
/// | Firestore condition | Becomes |
/// |---|---|
/// | `permission-denied`, `unauthenticated`, App Check rejection | [ReadRefused] |
/// | `unavailable`, `deadline-exceeded`, no connectivity | [ReadUnreachable] |
/// | a snapshot with `metadata.isFromCache == true` | [ReadUnreachable] — **never** [ReadSucceeded] |
///
/// The last row is not optional. Firestore's offline persistence is on by
/// default and `get()` does **not** throw when offline — it serves the local
/// cache. Treating that as success would stamp `lastReconcileAt` and reset
/// ADR-0001's staleness bound on every reconcile, so a device offline for a
/// month would "verify" every day and a cached away would silence the watcher
/// indefinitely. Use `Source.server`, or check `isFromCache`. A read served
/// from the cache has verified nothing, however successful it looks.
sealed class FirestoreRead {
  const FirestoreRead();

  /// The read succeeded. [away] may still be null — meaning Firestore holds no
  /// away document, which is the signal that clears a cancelled away.
  const factory FirestoreRead.succeeded({
    Set<DayKey> checkInDays,
    AwayPeriod? away,
  }) = ReadSucceeded;

  const factory FirestoreRead.unreachable([UnreachableCause cause]) =
      ReadUnreachable;

  const factory FirestoreRead.refused([RefusedCause cause]) = ReadRefused;

  Verification get verification => switch (this) {
        ReadSucceeded() => Verification.verified,
        ReadUnreachable() => Verification.unreachable,
        ReadRefused() => Verification.refused,
      };

  /// True only for [ReadSucceeded]. The one gate on folding a read into the
  /// cache — see `WatcherCache.applyRead`.
  bool get succeeded => this is ReadSucceeded;
}

final class ReadSucceeded extends FirestoreRead {
  const ReadSucceeded({this.checkInDays = const {}, this.away});

  /// Days `checkins/{watchedUid}/days/{d}` exists for, within the window read.
  final Set<DayKey> checkInDays;

  /// The away period Firestore holds, or null if the document is absent.
  final AwayPeriod? away;

  @override
  String toString() =>
      'ReadSucceeded(${checkInDays.length} check-in(s), away: $away)';
}

/// The server could not be reached.
final class ReadUnreachable extends FirestoreRead {
  const ReadUnreachable([this.cause = UnreachableCause.unknown]);

  final UnreachableCause cause;

  @override
  String toString() => 'ReadUnreachable(${cause.name})';
}

/// The server was reached and refused.
///
/// The device is fine. Whatever is wrong is wrong with this app's access, and
/// it will not heal on its own the way a network blip does.
final class ReadRefused extends FirestoreRead {
  const ReadRefused([this.cause = RefusedCause.unknown]);

  final RefusedCause cause;

  @override
  String toString() => 'ReadRefused(${cause.name})';
}
