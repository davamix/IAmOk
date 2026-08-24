import 'package:cloud_firestore/cloud_firestore.dart';

/// The `users/{uid}` document and its token subcollection (§6, §7).
///
/// **Read and written by self only** — §8, and that grant is load-bearing rather
/// than merely tight. It is *why* §7 denormalises `watchedName`, `watcherName`
/// and `watchedTimezone` onto the link: no user ever reads another user's
/// document, in either direction, so a watcher can render a whole row offline
/// and a watched person can name who will be told without being able to read
/// their profile.
class UserRepository {
  UserRepository({FirebaseFirestore? firestore}) : _injected = firestore;

  // **Resolved on use, not in the constructor.** `FirebaseFirestore.instance`
  // throws if Firebase has not been initialised, and this class is built inside
  // the composition root — so an eager resolve makes `AppServices` itself
  // unconstructible in any test that does not stand up the whole platform, for
  // an object most of them never call. Injected value wins; the singleton is the
  // fallback.
  final FirebaseFirestore? _injected;

  FirebaseFirestore get _firestore => _injected ?? FirebaseFirestore.instance;

  /// Creates or refreshes this user's document.
  ///
  /// The field set is exactly the four `firestore.rules` allows, and the rules
  /// check that it is *exactly* those four — a fifth would be rejected, which is
  /// the shape validation the security guidelines ask for. So this method and
  /// the rules have to move together; there is a rules test for each field.
  ///
  /// [displayName] comes from the Google profile and is a **display label, not
  /// an identity** (ADR-0003). Users can rename themselves at will; nothing
  /// decides anything from it. It is written here because §7 needs it available
  /// to `redeemInvite`, which copies it onto the link so the other party can
  /// render a name without reading this document.
  ///
  /// [timezone] is the device's own IANA zone. On the **watched** side this is
  /// what `redeemInvite` denormalises onto the link as `watchedTimezone`, which
  /// is what lets a watcher's alarm isolate compute `D` with no plugin access at
  /// all (ADR-0002). It is refreshed here rather than only at creation because a
  /// person who moves country changes which day their taps land on.
  ///
  /// `lastSeenAt` is `serverTimestamp()` on every write, which the rules
  /// require: it is a fact about when the server heard from this install, and a
  /// client-supplied value would be worth nothing. `createdAt` is immutable
  /// after creation, also enforced by the rules — so this uses `set` with
  /// `merge` semantics expressed as an explicit read-free upsert: the create
  /// path writes both stamps, the update path rewrites everything except
  /// `createdAt`.
  Future<void> upsert({
    required String uid,
    required String displayName,
    required String timezone,
  }) async {
    final doc = _firestore.doc('users/$uid');

    // A read before the write, deliberately, and it is the cheaper of the two
    // honest options. The rules freeze `createdAt` on update and require it
    // present on create, so the client has to know which it is doing. The
    // alternative — always writing `createdAt: serverTimestamp()` and letting
    // the rules reject the update — would turn every ordinary app open into a
    // `permission-denied`, which ADR-0004 maps to **refused**, which posts the
    // access-lost notice. A failed write on this path would tell a family the
    // app had lost sight of their relative because somebody saved a read.
    final existing = await doc.get();

    // Hoisted rather than written inline: `a ? b?['k'] : c` puts a null-aware
    // index straight after a conditional's `?`, which the parser reads as the
    // start of a second conditional.
    final Object? createdAt = existing.data()?['createdAt'];

    await doc.set(<String, Object?>{
      'displayName': displayName,
      'timezone': timezone,
      'createdAt': createdAt ?? FieldValue.serverTimestamp(),
      'lastSeenAt': FieldValue.serverTimestamp(),
    });
  }

  /// Records this install's FCM token under `users/{uid}/tokens/{token}`.
  ///
  /// **A subcollection, not an array field** (§7), so the fan-out Function can
  /// prune by age and by `UNREGISTERED` without rewriting the user document —
  /// and so two installs of the same account do not race each other's array.
  ///
  /// The document id *is* the token.
  ///
  /// **`updatedAt` is NOT used to decide a token is too old**, and this said it
  /// was. `onCheckInCreated` deliberately never filters by age: §13's watcher —
  /// the one who never opens the app — has by definition the stalest token in
  /// the collection, so an age filter would silence exactly the person FCM is in
  /// this design for. FCM's own `UNREGISTERED` is the authority on whether a
  /// token is dead; a date is a guess about it. See `collectTokens` in
  /// `functions/src/check_in_fan_out.ts`, which is the only consumer and argues
  /// the same thing from the other side.
  ///
  /// It is still written, because it is the honest record of when this install
  /// last confirmed its registration and a future decision may want it. What it
  /// must not become is a send filter.
  ///
  /// Called in Phase 4 step 5, when `firebase_messaging` arrives. It is written
  /// here rather than there because the rules that validate it are already
  /// deployed and already tested, and a repository whose shape is decided by the
  /// rules should not be invented separately later.
  Future<void> saveToken({required String uid, required String token}) =>
      _firestore.doc('users/$uid/tokens/$token').set(<String, Object?>{
        'platform': 'android',
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Drops a token this install no longer owns — a sign-out, or a rotation.
  ///
  /// Best-effort by nature: the common way a token dies is that the app is
  /// uninstalled, and nothing runs to delete it. That is what the Function's
  /// `UNREGISTERED` pruning is for; this only cleans up the cases the app is
  /// still alive to notice.
  Future<void> deleteToken({required String uid, required String token}) =>
      _firestore.doc('users/$uid/tokens/$token').delete();
}
