import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../domain/domain.dart';

/// `users/{watchedUid}/shared/away` — the away document (§7, §8, §12).
///
/// **One document, one truth.** Away is a property of the watched *person*, not
/// of a pair, and anyone in the group may set, extend or cancel it with no
/// approval. Both facts live in the rules rather than here: the client is
/// untrusted by definition and every check in this file is an affordance, not a
/// control.
///
/// ## A direct client write, and that is the reason this class exists at all
///
/// §8 chose a direct write over a callable **on purpose** — *"it means a watcher
/// can set away on a plane and have it queue offline like any other write"*.
/// Validation therefore lives in `firestore.rules`, and the exact 31-day cap
/// lives in [AwayRules], where a local date can be compared against a local
/// today. The two are **deliberately not the same check** and are not meant to
/// match: the rules are slack because they cannot convert a day label to an
/// instant, and a rejected away write queues offline and resurfaces later with
/// no visible cause, which is worse than admitting a period a day over a
/// guardrail.
///
/// ## The write is bounded, and a timeout is not a failure
///
/// [write] and [cancel] wait a short while for the server, then return
/// [AwayOutcome.queued] — see that type for why *"could not reach the server"*
/// is a sentence this path can never truthfully say. Nothing is retried by hand:
/// HANDOVER.md's instruction not to build a retry queue is the same decision
/// from the other side, because Firestore's own persistence **is** one.
class AwayRepository {
  AwayRepository({FirebaseFirestore? firestore, this.confirmWithin = _window})
      : _injected = firestore;

  /// How long to wait for the server before calling the write **queued**.
  ///
  /// Long enough that an ordinary write on a working connection confirms inside
  /// it, and short enough that somebody standing in a lift is not left holding a
  /// spinner on the one screen this app asks an elderly person to use. Getting
  /// this wrong in either direction costs nothing but a word: the write lands
  /// either way, and the next reconcile reads back what actually happened.
  static const Duration _window = Duration(seconds: 6);

  final Duration confirmWithin;

  // **Resolved on use, not in the constructor** — the same reasoning as
  // `CheckInRepository` and `UserRepository`. `FirebaseFirestore.instance`
  // throws if Firebase has not been initialised, and this is built inside the
  // composition root.
  final FirebaseFirestore? _injected;

  FirebaseFirestore get _firestore => _injected ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _doc(String watchedUid) =>
      _firestore.doc('users/$watchedUid/shared/away');

  /// Reads the away document, with ADR-0004's three states kept apart.
  ///
  /// **A read that fails is not an answer** (ADR-0001 decision 1), and this is
  /// the watched side's version of the guard `FirestoreCheckInReader` spends its
  /// docstring on. Both traps apply here unchanged and for the same reasons:
  ///
  /// - `Source.server`, **and** an explicit `isFromCache` check anyway. Firestore
  ///   serves the local cache when offline without throwing, so a cache hit
  ///   reported as success would let a period that Firestore no longer holds go
  ///   on suppressing this person's reminders indefinitely — she is not
  ///   reminded, she does not tap, and her family is warned about a holiday
  ///   that was cancelled.
  /// - It **never throws**. This runs on a path a bare isolate reaches, where a
  ///   throw is silence.
  Future<AwayRead> read(String watchedUid) async {
    try {
      final snapshot =
          await _doc(watchedUid).get(const GetOptions(source: Source.server));
      if (snapshot.metadata.isFromCache) return const AwayRead.unreachable();
      return AwayRead.succeeded(decode(snapshot.data()));
    } on FirebaseException catch (e) {
      return classifyRead(e);
    } on Object {
      // A malformed document, or a type that is not what §7 says. Unreachable
      // rather than refused, on the same reasoning as the reader: nothing about
      // it says the backend turned us away, and guessing "refused" would post
      // the access-lost notice about an app that has lost nothing.
      return const AwayRead.unreachable();
    }
  }

  /// Writes [period], attributed to [setBy] / [setByName] (ADR-0003).
  ///
  /// [today] is already resolved in the **watched person's** zone — the only
  /// place [AwayRules]' question is well-posed. It is a parameter rather than a
  /// clock read for the reason `domain_purity_test.dart` enforces one layer up:
  /// the decision is the domain's and the instant is the caller's.
  ///
  /// [existing] is what the server currently holds, or null. It selects
  /// `validateCreate` against `validateUpdate`, which differ in the one way
  /// ADR-0001 decision 6 requires: `from` must be **today or later** on create
  /// and **unchanged** on update, because truncating an in-progress period
  /// rewrites a document whose `from` is already in the past.
  Future<AwayOutcome> write({
    required String watchedUid,
    required String setBy,
    required String setByName,
    required AwayPeriod period,
    required DayKey today,
    AwayPeriod? existing,
  }) async {
    if (setBy.isEmpty) {
      return const AwayOutcome.refused(AwayRefusal.notSignedIn);
    }

    // The client's own check, run **before** anything is sent. It is not the
    // control — the rules are — but it is what stops an ordinary mistake
    // becoming a `permission-denied`, which ADR-0004 maps to *refused* and which
    // this app's own copy layer treats as a claim about lost access.
    final rejection = existing == null
        ? AwayRules.validateCreate(period, today)
        : AwayRules.validateUpdate(period, existing, today);
    if (rejection != null) {
      return const AwayOutcome.refused(AwayRefusal.rejectedPeriod);
    }

    // `setAt` and `updatedAt` are both `serverTimestamp()` because the rules
    // require both to equal `request.time` — ADR-0003 rule 3, which blocks
    // backdating. A client-supplied instant would be worth nothing and would be
    // rejected, and the rejection would arrive as lost access.
    //
    // The whole field set is written on every write, create or update, because
    // the rules check `hasOnly` **and** `hasAll`: a merge that omitted `setAt`
    // on an update would fail shape validation. `setBy` and `setByName` are
    // deliberately re-stamped — §12 is last-write-wins, so extending somebody
    // else's period must re-attribute it to whoever wrote last.
    return send(_doc(watchedUid).set(<String, Object?>{
      'from': period.from.toString(),
      'through': period.through.toString(),
      'setBy': setBy,
      'setByName': setByName,
      'setAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }));
  }

  /// Removes the document — the **only** case §12 allows a delete.
  ///
  /// Cancellation normally **truncates**: `through` is pulled back to the last
  /// genuinely-away day so the days already spent away stay covered, because
  /// deleting mid-period would retroactively un-cover them and the next device
  /// to refresh its cache would warn about a day the person really was away.
  /// `AwayPeriod.cancelOn` returns null for the one case where truncating is
  /// impossible — cancelling on the day the period starts, where `through =
  /// from - 1` would violate `through >= from` — and that is what reaches here.
  ///
  /// So this method takes no period and validates nothing: the arithmetic that
  /// decides between truncate and delete is [AwayPeriod.cancelOn]'s, and having
  /// a second opinion about it here is how the two would come to disagree.
  Future<AwayOutcome> cancel({required String watchedUid}) =>
      send(_doc(watchedUid).delete());

  /// Awaits [write] only as long as [confirmWithin], then calls it queued.
  ///
  /// **Visible for testing, and that is the Phase 5 gate's lesson applied
  /// before it costs anything.** The mapping that decides which of three
  /// sentences a person reads used to live inside a `catch`, where no unit test
  /// can enter it — and it was wrong for a whole phase. Everything this class
  /// *decides* is reachable from a test: this, [refusalForCode], [classifyRead]
  /// and [decode]. What is left un-covered is the two SDK calls themselves,
  /// which decide nothing.
  @visibleForTesting
  Future<AwayOutcome> send(Future<void> write) async {
    try {
      await write.timeout(confirmWithin);
      return const AwayOutcome.set();
    } on TimeoutException {
      // Firestore is holding the mutation and will replay it. §8 chose this
      // write shape for exactly this case, so it is reported as what it is.
      return const AwayOutcome.queued();
    } on FirebaseException catch (e) {
      return AwayOutcome.refused(refusalForCode(e.code));
    } on Object {
      return const AwayOutcome.refused(AwayRefusal.serverFault);
    }
  }

  /// Maps a Firestore error code onto a refusal.
  ///
  /// **A pure function, and `@visibleForTesting`-shaped for the reason the
  /// Phase 5 gate found the hard way**: the mapping that used to live inside a
  /// `catch` was wrong for a whole phase, because no unit test can enter an
  /// exception handler. This one is table-tested.
  ///
  /// The default is [AwayRefusal.serverFault] and never a claim about the
  /// device. `unavailable` and `deadline-exceeded` are **absent on purpose** —
  /// they cannot reach here for a write, because the SDK queues rather than
  /// failing, and the timeout above is what that case actually looks like.
  @visibleForTesting
  static AwayRefusal refusalForCode(String code) => switch (code) {
        'permission-denied' => AwayRefusal.notPermitted,
        'unauthenticated' => AwayRefusal.notSignedIn,
        _ => AwayRefusal.serverFault,
      };

  @visibleForTesting
  static AwayRead classifyRead(FirebaseException e) => switch (e.code) {
        'permission-denied' =>
          const AwayRead.refused(RefusedCause.permissionDenied),
        'unauthenticated' =>
          const AwayRead.refused(RefusedCause.unauthenticated),
        'failed-precondition' when _mentionsAppCheck(e) =>
          const AwayRead.refused(RefusedCause.appCheckRejected),
        'unavailable' => const AwayRead.unreachable(UnreachableCause.offline),
        'deadline-exceeded' =>
          const AwayRead.unreachable(UnreachableCause.timeout),
        _ => const AwayRead.unreachable(),
      };

  /// The same English-substring match `FirestoreCheckInReader` carries, and the
  /// same open question — `OPEN-QUESTIONS.md` #5. Harmless while App Check is in
  /// monitoring mode; verified against a real rejection before enforcement.
  static bool _mentionsAppCheck(FirebaseException e) =>
      (e.message ?? '').toLowerCase().contains('app check');

  /// A stored document, or null when it is absent or unusable.
  ///
  /// A malformed period yields null — *no valid away period* — because
  /// `AwayRecord.tryCreate` refuses to build one that ends before it starts.
  /// A malformed **name** does not: it degrades to unattributed, because
  /// dropping the period would warn a family about days somebody really did
  /// mark away (ADR-0003's *Absence* case).
  @visibleForTesting
  static AwayRecord? decode(Map<String, dynamic>? data) {
    if (data == null) return null;
    final from = data['from'];
    final through = data['through'];
    if (from is! String || through is! String) return null;

    final setBy = data['setBy'];
    final setByName = data['setByName'];
    return AwayRecord.tryCreate(
      from: DayKey.parse(from),
      through: DayKey.parse(through),
      setBy: setBy is String ? setBy : null,
      setByName: setByName is String ? setByName : null,
    );
  }
}
