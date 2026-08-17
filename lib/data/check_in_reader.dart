import 'dart:convert';

import '../domain/domain.dart';
import 'local_store.dart';

/// The **tier-1 read** the watcher attempts before consulting any cache
/// (ADR-0001 decision 1).
///
/// This is the seam Phase 4 replaces with Firestore. It is an interface now, and
/// not a `TODO` on a concrete class, because ADR-0004 already fixed the contract
/// it has to satisfy and that contract is easy to get wrong in a way no test
/// notices:
///
/// | Firestore condition | Must become |
/// |---|---|
/// | `permission-denied`, `unauthenticated`, App Check rejection | [ReadRefused] |
/// | `unavailable`, `deadline-exceeded`, no connectivity | [ReadUnreachable] |
/// | a snapshot with `metadata.isFromCache == true` | [ReadUnreachable] — **never** [ReadSucceeded] |
///
/// The last row is the trap. Firestore's offline persistence is on by default
/// and `get()` does **not** throw when offline — it serves the local cache. An
/// implementation that reports that as success stamps `lastReconcileAt` and
/// resets ADR-0001's staleness bound on every reconcile, so a device offline for
/// a month "verifies" every day and a cached away silences the watcher
/// indefinitely. **A read served from the cache has verified nothing, however
/// successful it looks.**
abstract interface class CheckInReader {
  /// Attempts to read the watched person's check-ins and away period.
  ///
  /// Never throws: a failure is a [FirestoreRead] value, because the difference
  /// between *could not reach* and *was refused* is the whole of ADR-0004 and an
  /// exception collapses it back to one bit.
  Future<FirestoreRead> read(Link link);
}

/// What the simulated backend is currently answering. Phase 3 only.
enum SimulatedReadOutcome { succeeded, unreachable, refused }

/// Phase 3's stand-in for Firestore, driven from `LocalStore`.
///
/// **It reads its answer from the store rather than from memory, and that is the
/// point.** The alarm isolate shares no memory with the UI (§4), so a simulated
/// backend held in a Riverpod provider would be invisible to the one isolate
/// this phase exists to test. The clock offset lives in the store for exactly
/// the same reason: forcing a state in the UI and having the alarm disagree
/// would test nothing.
///
/// PLAN.md's Phase 3 is explicit that this phase runs on **fake local data, no
/// Firebase**, so the whole of §10's decision tree — including the two failure
/// branches that are hardest to produce on demand against a real backend — can
/// be exercised from the debug harness on a device.
class SimulatedCheckInReader implements CheckInReader {
  const SimulatedCheckInReader(this._store);

  final LocalStore _store;

  @override
  Future<FirestoreRead> read(Link link) async =>
      SimulatedBackend.decode(await _store.simulatedBackendRaw()).toRead();
}

/// The simulated backend's state, as stored and as the harness edits it.
class SimulatedBackend {
  const SimulatedBackend({
    this.outcome = SimulatedReadOutcome.succeeded,
    this.checkInDays = const {},
    this.away,
    this.refusedCause = RefusedCause.permissionDenied,
    this.unreachableCause = UnreachableCause.offline,
  });

  final SimulatedReadOutcome outcome;

  /// Days the fake backend holds a check-in for.
  final Set<DayKey> checkInDays;

  /// The away period the fake backend holds, or null for "no document".
  ///
  /// Null is meaningful and not merely absent: a successful read returning null
  /// is the signal that clears a **cancelled** away, which is the failure
  /// ADR-0001 exists to fix. A simulator that could not express it would make
  /// the most important away case untestable.
  final AwayPeriod? away;

  final RefusedCause refusedCause;
  final UnreachableCause unreachableCause;

  FirestoreRead toRead() => switch (outcome) {
        SimulatedReadOutcome.succeeded =>
          FirestoreRead.succeeded(checkInDays: checkInDays, away: away),
        SimulatedReadOutcome.unreachable =>
          FirestoreRead.unreachable(unreachableCause),
        SimulatedReadOutcome.refused => FirestoreRead.refused(refusedCause),
      };

  String encode() => jsonEncode({
        'outcome': outcome.name,
        'checkInDays': checkInDays.map((d) => d.toString()).toList(),
        'awayFrom': away?.from.toString(),
        'awayThrough': away?.through.toString(),
        'refusedCause': refusedCause.name,
        'unreachableCause': unreachableCause.name,
      });

  /// Anything unparseable becomes the default rather than throwing.
  ///
  /// This is decoded inside a bare alarm isolate, where a throw looks exactly
  /// like the app working correctly and saying nothing — the one failure mode
  /// this project cannot detect in itself. The default is a *successful* read
  /// holding nothing, which produces a warning rather than silence, and noisy is
  /// the recoverable direction.
  static SimulatedBackend decode(String? raw) {
    if (raw == null) return const SimulatedBackend();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final from = map['awayFrom'] as String?;
      final through = map['awayThrough'] as String?;
      return SimulatedBackend(
        outcome: _byName(SimulatedReadOutcome.values, map['outcome']) ??
            SimulatedReadOutcome.succeeded,
        checkInDays: {
          for (final day in (map['checkInDays'] as List? ?? const []))
            DayKey.parse(day as String),
        },
        away: (from == null || through == null)
            ? null
            : AwayPeriod.tryCreate(
                from: DayKey.parse(from),
                through: DayKey.parse(through),
              ),
        refusedCause: _byName(RefusedCause.values, map['refusedCause']) ??
            RefusedCause.permissionDenied,
        unreachableCause:
            _byName(UnreachableCause.values, map['unreachableCause']) ??
                UnreachableCause.offline,
      );
    } on Object {
      return const SimulatedBackend();
    }
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  SimulatedBackend copyWith({
    SimulatedReadOutcome? outcome,
    Set<DayKey>? checkInDays,
    AwayPeriod? away,
    bool clearAway = false,
    RefusedCause? refusedCause,
    UnreachableCause? unreachableCause,
  }) =>
      SimulatedBackend(
        outcome: outcome ?? this.outcome,
        checkInDays: checkInDays ?? this.checkInDays,
        away: clearAway ? null : (away ?? this.away),
        refusedCause: refusedCause ?? this.refusedCause,
        unreachableCause: unreachableCause ?? this.unreachableCause,
      );

  @override
  String toString() => 'SimulatedBackend(${outcome.name}, '
      '${checkInDays.length} check-in(s), away: $away)';
}
