import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/domain.dart';
import 'local_store.dart';

/// Reads this user's links out of Firestore and into `LocalStore` (§6).
///
/// **Links are the map of who is watching whom, and every other decision hangs
/// off them.** The watched side names its audience from them; the watcher side
/// reconciles one per link and arms a warning alarm for each. Nothing else in
/// this app decides anything without one.
///
/// They are **written only by Cloud Functions** (§9) — `redeemInvite` creates
/// them so single-use and expiry are enforced server-side — with one client
/// exception, revocation. So this class reads and revokes; it never creates.
class LinkRepository {
  LinkRepository({FirebaseFirestore? firestore}) : _injected = firestore;

  // Resolved on use, not in the constructor: `FirebaseFirestore.instance` throws
  // before Firebase is initialised, and this is built inside the composition
  // root. Same shape as the other repositories here.
  final FirebaseFirestore? _injected;

  FirebaseFirestore get _firestore => _injected ?? FirebaseFirestore.instance;

  /// Every link this user is a party to, from the **server**.
  ///
  /// ## Two queries, not one `or`
  ///
  /// §8 grants a read where `watchedUid == uid || watcherUid == uid`. Firestore
  /// evaluates rules against a *query's constraints*, not against the documents
  /// it would return, so a disjunction has to be expressible as two queries each
  /// of which the rules can see is safe. Two round trips, and they are cheap;
  /// the alternative is a query the rules reject with `permission-denied`, which
  /// ADR-0004 maps to **refused** and turns into an access-lost notice.
  ///
  /// ## `Source.server`, for ADR-0001's reason
  ///
  /// Offline persistence is on, and a cache hit is not a verification. Here the
  /// cost of getting that wrong is different from the check-in read's but no
  /// smaller: the *local store* is already the offline copy of this data, so a
  /// Firestore cache hit would be a second, staler copy overwriting the first.
  Future<List<Link>> fromServer(String uid) async {
    final collection = _firestore.collection('links');
    const options = GetOptions(source: Source.server);

    final results = await Future.wait([
      collection.where('watchedUid', isEqualTo: uid).get(options),
      collection.where('watcherUid', isEqualTo: uid).get(options),
    ]);

    // Keyed by document id so a self-link — the same uid on both sides, which
    // the device harness uses to exercise both roles at once — appears once
    // rather than twice.
    final byId = <String, Link>{};
    for (final snapshot in results) {
      for (final doc in snapshot.docs) {
        final link = _decode(doc);
        if (link != null) byId[doc.id] = link;
      }
    }
    return byId.values.toList();
  }

  /// Refreshes the local copy from the server, and **leaves it alone if the read
  /// fails**.
  ///
  /// This is ADR-0001's rule applied to a second kind of read, and the reasoning
  /// transfers exactly. A failed read is not an answer: a timeout, a permission
  /// denial and an App Check rejection all happen while online, and none of them
  /// mean *you watch nobody*. Clearing the local links on any of them would
  /// disarm every warning alarm on the device — a dead man's switch turned off
  /// by a dropped connection, with nothing on any screen to say so.
  ///
  /// So the store is replaced **only** on success. Returns whether it was.
  ///
  /// What a successful read *does* do is authoritative, including deletions: a
  /// link the server no longer returns is gone from the local store too. That is
  /// how a revocation performed on another device reaches this one without a
  /// push — §3's rule that FCM is a hint and never the thing that carries truth.
  Future<bool> syncInto(LocalStore store, String uid) async {
    if (uid == LocalStore.signedOutUid) return false;

    final List<Link> links;
    try {
      links = await fromServer(uid);
    } on Object {
      // Swallowed, and the caller carries on with what it already had. The
      // watcher's own reconcile is what reports a backend it cannot reach, in
      // ADR-0004's three carefully distinguished ways; this is not the place to
      // invent a fourth.
      return false;
    }

    await store.replaceLinksFor(uid, links);
    return true;
  }

  /// Links on which [uid] is the **watched** party, as they change.
  ///
  /// The one streaming read in this app, and it exists for one screen: the
  /// pairing flow assumes a family member sets up both phones **in one sitting**
  /// (`ui-ux/screens.md`), so the phone showing the code has to notice the
  /// moment the other phone redeems it, without anybody navigating.
  ///
  /// ## Why this does not weaken §3
  ///
  /// §3 says Firestore is the source of truth and a **listener's live state is
  /// invisible to background isolates** (§4). Both still hold: nothing decides
  /// anything from this stream. It is a *nudge*, exactly as an FCM push is — the
  /// screen reacts by calling `syncLinks()`, which is the same
  /// read-and-replace path a launch and a resume use, and the store is what
  /// everything else reads afterwards. Losing the stream costs the reader a
  /// live update, never correctness.
  ///
  /// ## One query, not the two `fromServer` makes
  ///
  /// Only the watched half is watched, because that is the half this screen is
  /// about: *has anybody redeemed my code*. §8 grants the read on
  /// `watchedUid == uid`, so the rules can see this query is safe with no
  /// disjunction to decompose.
  ///
  /// Cache hits are welcome here, unlike in [fromServer]: this is a change
  /// signal rather than a verification, and the verification is the `syncLinks`
  /// the caller does next.
  Stream<List<Link>> watchWatchedBy(String uid) {
    if (uid == LocalStore.signedOutUid) return const Stream.empty();
    return _firestore
        .collection('links')
        .where('watchedUid', isEqualTo: uid)
        .snapshots()
        .map((snapshot) => [
              // A document this build cannot interpret is dropped rather than
              // thrown on, exactly as `syncInto` drops one — on this side an
              // exception is a screen that never updates.
              for (final doc in snapshot.docs) ?_decode(doc),
            ]);
  }

  /// Either party may end a link, and may change **nothing else** (§8).
  ///
  /// Revocation is final: ADR-0004 decision 7 has the watcher *withdraw* any
  /// standing warning rather than correct it, because after this every read is
  /// refused and nothing could ever clear it.
  Future<void> revoke(String linkId) =>
      _firestore.doc('links/$linkId').update({'status': 'revoked'});

  /// Turns a document into a [Link], or null if this build cannot read it.
  ///
  /// **Null rather than a throw.** One malformed document — a field a newer
  /// build writes, a status this one has no case for — must not take down the
  /// whole sync and leave the device with no links at all. The same shape as
  /// `LocalStore`'s own "a row this build cannot interpret" handling, for the
  /// same reason: on this side, an exception is silence.
  static Link? _decode(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final watchedUid = data['watchedUid'];
    final watcherUid = data['watcherUid'];
    final watchedTimezone = data['watchedTimezone'];
    final activeFrom = data['activeFrom'];
    if (watchedUid is! String ||
        watcherUid is! String ||
        watchedTimezone is! String ||
        activeFrom is! String) {
      return null;
    }

    final warningLocalTime = data['warningLocalTime'];
    return Link(
      watchedUid: watchedUid,
      watcherUid: watcherUid,
      // Anything that is not exactly "accepted" reads as revoked, which is the
      // safe direction: a status this build does not know must not be treated
      // as permission to speak about somebody.
      status: data['status'] == 'accepted'
          ? LinkStatus.accepted
          : LinkStatus.revoked,
      watchedName: data['watchedName'] as String? ?? '',
      watcherName: data['watcherName'] as String? ?? '',
      watchedTimezone: watchedTimezone,
      activeFrom: DayKey.parse(activeFrom),
      warningLocalTime: warningLocalTime is String
          ? LocalTimeOfDay.tryParse(warningLocalTime) ??
              Link.defaultWarningLocalTime
          : Link.defaultWarningLocalTime,
      // **The epoch, not `DateTime.now()`**, and the purity guard is what caught
      // the first version doing the latter. Reading the device clock here would
      // fabricate a fact about the past out of the present — and on a field that
      // came back missing, which is precisely when the app knows least.
      //
      // Nothing decides anything from `createdAt`: `activeFrom` is what gates
      // which days may be warned about (§7), and it is required above. If that
      // ever stops being true, this fallback becomes a lie with consequences and
      // the honest move is to drop the link instead.
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      acceptedAt: (data['acceptedAt'] as Timestamp?)?.toDate(),
    );
  }
}
