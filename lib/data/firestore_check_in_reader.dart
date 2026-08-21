import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/domain.dart';
import 'check_in_reader.dart';

/// The **real tier-1 read** (§3, ADR-0001): what the watcher's device asks
/// Firestore before it decides whether to say anything about somebody's
/// relative.
///
/// This is the seam Phase 3 built `SimulatedCheckInReader` against, and the
/// contract it has to satisfy was fixed by ADR-0004 before there was any code to
/// satisfy it — because it is easy to get wrong in a way no test notices.
///
/// ## The trap, stated first because it is the whole reason this class is
/// careful
///
/// **Firestore's offline persistence is on by default and `get()` does not throw
/// when offline — it serves the local cache.** An implementation that reports
/// that as success stamps `lastReconcileAt` and resets ADR-0001's two-day
/// staleness bound on every reconcile. A device offline for a month would
/// "verify" thirty times, and a cached away period would silence the watcher
/// indefinitely: precisely the wrongful silence ADR-0001 exists to eliminate,
/// reintroduced through a different door.
///
/// So every read here is `Source.server`, **and** the result is checked for
/// `metadata.isFromCache` anyway. Two guards for one hazard, deliberately: the
/// first states the intent to the SDK, the second is what actually holds if a
/// future SDK decides `Source.server` may fall back. A read served from the
/// cache has verified nothing, however successful it looks.
///
/// ## Three states, not two
///
/// | Firestore condition | Becomes |
/// |---|---|
/// | `permission-denied`, `unauthenticated`, App Check rejection | [ReadRefused] |
/// | `unavailable`, `deadline-exceeded`, no connectivity | [ReadUnreachable] |
/// | a snapshot with `isFromCache == true` | [ReadUnreachable] — **never** [ReadSucceeded] |
///
/// A timeout and a permission denial both mean *could not verify*, so neither
/// may clear the away cache. Only one of them means the phone is offline, and
/// saying so when the phone is fine is a false claim about the device — which is
/// the whole of ADR-0004.
///
/// **It never throws.** A failure is a [FirestoreRead] value, because an
/// exception collapses that three-way distinction back into one bit at exactly
/// the boundary where it matters. This runs in an alarm isolate with seconds to
/// live and nothing to report a throw to.
class FirestoreCheckInReader implements CheckInReader {
  FirestoreCheckInReader({
    required this.now,
    FirebaseFirestore? firestore,
    this.windowDays = defaultWindowDays,
  }) : _injected = firestore;


  /// How many completed days back to ask about.
  ///
  /// **This is the bound that closes the far-future check-in hazard**, and it
  /// lives here rather than in `firestore.rules` because here is where the
  /// question is well-posed. A check-in's day id is a date in the *watched
  /// person's* zone; the rules engine has no timezone conversion and cannot know
  /// that zone, so a rules-level bound would be inexact in exactly the direction
  /// that rejects legitimate writes.
  ///
  /// What it prevents: a watched device with a badly skewed clock — §11 says
  /// skew is detected and surfaced, never silently corrected — files a check-in
  /// years ahead. `WatcherCache.applyRead` takes the maximum of the days it is
  /// given, `lastConfirmedDay` is monotone, and §10 step 4 then silences the
  /// watcher **for ever**. Asking only about a bounded window of specific days
  /// means such a document is never read at all.
  ///
  /// Eight: ADR-0009's seven-day catch-up window, plus one, so the oldest day
  /// the policy may still decide about is always covered rather than exactly at
  /// the edge.
  static const int defaultWindowDays = 8;

  final int windowDays;

  /// The current instant, injected — never `DateTime.now()`.
  ///
  /// `Clock.now` in production. This class computes which days to ask about, so
  /// it reads the clock; the purity guard's rule is that the clock is a
  /// *parameter* to anything that decides, and this is what that looks like at
  /// the Data layer.
  final DateTime Function() now;

  // **Resolved on use, not in the constructor.** `FirebaseFirestore.instance`
  // throws if Firebase has not been initialised, and this class is built inside
  // the composition root — so an eager resolve makes `AppServices` itself
  // unconstructible in any test that does not stand up the whole platform, for
  // an object most of them never call. Injected value wins; the singleton is the
  // fallback.
  final FirebaseFirestore? _injected;

  FirebaseFirestore get _firestore => _injected ?? FirebaseFirestore.instance;

  @override
  Future<FirestoreRead> read(Link link) async {
    // The days to ask about, in the WATCHED person's zone — the zone is
    // denormalised onto the link (§7) precisely so this needs no plugin and no
    // second document read. `tryWatchedZone` rather than `watchedZone`: an
    // unknown zone name must surface as a handled condition, not as an exception
    // thrown inside an alarm isolate.
    final zone = link.tryWatchedZone;
    if (zone == null) {
      // Nothing was reached and nothing was refused. The device cannot compute
      // which days to ask about, which is a fault in this app rather than in the
      // network or the backend — and `WatcherReconcileResult.watchedZoneUnknown`
      // is what carries it to §13's panel. Reported as unreachable because it is
      // the honest one of the three: it claims nothing about the backend and
      // does not clear the away cache.
      return const FirestoreRead.unreachable();
    }

    final today = DayKey.fromInstant(now(), zone);
    final oldest = today.minusDays(windowDays);

    try {
      final away = await _readAway(link.watchedUid);
      final days = await _readCheckInDays(link.watchedUid, oldest, today);
      return FirestoreRead.succeeded(checkInDays: days, away: away);
    } on FirebaseException catch (e) {
      return _classify(e);
    } on _CacheHit {
      // A snapshot that came from the local cache. Not an error to Firestore,
      // and not a verification to us.
      return const FirestoreRead.unreachable();
    } on Object {
      // Anything else — a malformed document, a type that is not what §7 says.
      // Unreachable rather than refused: nothing about it says the backend
      // turned us away, and a wrong guess in that direction would post the
      // access-lost notice and tell a family the app has lost access when it has
      // not. Deliberately NOT rethrown: this runs where a throw is silence.
      return const FirestoreRead.unreachable();
    }
  }

  /// `users/{uid}/shared/away` — absent means not away (§12).
  Future<AwayPeriod?> _readAway(String watchedUid) async {
    final snapshot = await _firestore
        .doc('users/$watchedUid/shared/away')
        .get(const GetOptions(source: Source.server));
    _rejectCacheHit(snapshot.metadata);

    if (!snapshot.exists) return null;
    final data = snapshot.data();
    if (data == null) return null;

    final from = data['from'];
    final through = data['through'];
    if (from is! String || through is! String) return null;

    // `tryCreate`, not the constructor: a stored pair that cannot form a valid
    // period must not throw here. Same shape and same reason as
    // `Link.tryWatchedZone` and `LocalStore.watcherCache`.
    return AwayPeriod.tryCreate(
      from: DayKey.parse(from),
      through: DayKey.parse(through),
    );
  }

  /// The days in `[oldest, today]` that carry a check-in.
  ///
  /// A range query on the document id rather than one `get()` per day: the ids
  /// are `YYYY-MM-DD`, which sorts lexicographically in the same order it sorts
  /// chronologically, so `FieldPath.documentId` bounds do exactly what the dates
  /// mean. Nine round trips would also be nine chances for one to fail
  /// separately, which is nine partial answers to reason about instead of one.
  Future<Set<DayKey>> _readCheckInDays(
    String watchedUid,
    DayKey oldest,
    DayKey today,
  ) async {
    final snapshot = await _firestore
        .collection('checkins/$watchedUid/days')
        .where(FieldPath.documentId, isGreaterThanOrEqualTo: '$oldest')
        .where(FieldPath.documentId, isLessThanOrEqualTo: '$today')
        .get(const GetOptions(source: Source.server));
    _rejectCacheHit(snapshot.metadata);

    return {
      for (final doc in snapshot.docs)
        if (_isDayKey(doc.id)) DayKey.parse(doc.id),
    };
  }

  /// Maps a Firestore error onto ADR-0004's three states.
  ///
  /// The list is closed on purpose and the default is **unreachable**, not
  /// refused. Guessing "refused" for an unfamiliar code would post the
  /// access-lost notice — *"I Am Ok has lost access to the check-ins"* — for
  /// something that might be a transient network fault, and that message is
  /// meant to be actionable. Being wrong towards "your phone could not reach the
  /// server" claims less and heals by itself.
  static FirestoreRead _classify(FirebaseException e) => switch (e.code) {
        'permission-denied' => const FirestoreRead.refused(
            RefusedCause.permissionDenied,
          ),
        'unauthenticated' => const FirestoreRead.refused(
            RefusedCause.unauthenticated,
          ),
        // App Check rejections surface under this code with a message naming
        // App Check; the SDK has no distinct code for them.
        'failed-precondition' when _mentionsAppCheck(e) =>
          const FirestoreRead.refused(RefusedCause.appCheckRejected),
        'unavailable' => const FirestoreRead.unreachable(
            UnreachableCause.offline,
          ),
        'deadline-exceeded' => const FirestoreRead.unreachable(
            UnreachableCause.timeout,
          ),
        _ => const FirestoreRead.unreachable(),
      };

  static bool _mentionsAppCheck(FirebaseException e) =>
      (e.message ?? '').toLowerCase().contains('app check');

  static void _rejectCacheHit(SnapshotMetadata metadata) {
    if (metadata.isFromCache) throw const _CacheHit();
  }

  static bool _isDayKey(String id) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(id);
}

/// A snapshot Firestore served from its own cache.
///
/// A private control-flow signal rather than a returned value, so that the two
/// read helpers above can each refuse a cache hit at the point they get one
/// without either of them having to remember to propagate a "not really
/// verified" flag back up.
class _CacheHit implements Exception {
  const _CacheHit();
}
