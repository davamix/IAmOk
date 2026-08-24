import 'package:firebase_messaging/firebase_messaging.dart';

import 'user_repository.dart';

/// This install's FCM registration — the token, and the `users/{uid}/tokens/…`
/// document that makes it reachable (§7).
///
/// ## What this is for, and what it is not
///
/// FCM is **tier 2** (§3): a wake-up hint, never the truth. Nothing this class
/// does affects whether the app is *correct*; it affects whether the app finds
/// out *early*. If every token here were wrong, every watcher would still
/// reconcile on app open and again at alarm time, and every warning decision
/// would come out the same. What would be lost is the one thing tier 2 exists
/// for — refreshing the local decision cache while the app is not running, which
/// is what protects an **offline** watcher from a false warning.
///
/// That is the reason nothing below is allowed to throw at its caller.
///
/// ## No permission is requested here, deliberately
///
/// `FirebaseMessaging.requestPermission()` asks for `POST_NOTIFICATIONS` on
/// Android, which `PermissionService` already owns through
/// `flutter_local_notifications` — and owns *better*, because asking the
/// notification manager "will this appear" also catches a switched-off channel,
/// which no runtime-permission API does. Two sources for one permission is two
/// answers about whether this phone can speak, and §13's whole argument is that
/// the answer has to be observed rather than remembered.
///
/// It is not needed here in any case: **data-only messages are delivered
/// regardless of notification permission.** A phone with notifications denied
/// still wakes, still reconciles, and still refreshes its cache — it just cannot
/// say anything, which `NotificationDelivery.unavailable` already models.
class PushRegistration {
  // Positional, like `AuthRepository(this._store)`: a named parameter cannot
  // bind to a private field, and the alternative is an initialiser list that the
  // analyzer flags.
  PushRegistration(
    this._users, {
    FirebaseMessaging? messaging,
    // Injectable only so the timeout test does not burn five seconds of real
    // wall clock — half this suite's runtime for one case.
    this.deleteTimeout = const Duration(seconds: 5),
  }) : _injected = messaging;

  final UserRepository _users;

  // Resolved on use, not in the constructor — the same shape as the
  // repositories. `FirebaseMessaging.instance` needs Firebase up, and this is
  // built inside the composition root, which many tests construct without
  // standing up the platform at all.
  final FirebaseMessaging? _injected;

  /// How long the token-document delete may take before a sign-out gives up on
  /// it. Public only so the timeout test does not burn five seconds of real wall
  /// clock — half this suite's runtime for one case.
  final Duration deleteTimeout;

  FirebaseMessaging get _messaging => _injected ?? FirebaseMessaging.instance;

  /// This install's current token, or null if the device cannot produce one.
  ///
  /// Null is ordinary rather than exceptional: `getToken()` needs Play Services
  /// and a network round trip, and a phone in a lift has neither. The caller
  /// treats that as *not registered yet* and tries again next launch.
  Future<String?> token() async {
    try {
      return await _messaging.getToken();
    } on Object {
      return null;
    }
  }

  /// Records this install's token under [uid], and returns it.
  ///
  /// **Never throws.** A failure here means this device is not reachable by
  /// push, which costs latency and nothing else (§3) — so it must not be able to
  /// take down a sign-in, a launch, or the screen the caller was building.
  Future<String?> register({required String uid}) async {
    final value = await token();
    if (value == null) return null;
    try {
      await _users.saveToken(uid: uid, token: value);
      return value;
    } on Object {
      return null;
    }
  }

  /// Drops this install's token document for [uid].
  ///
  /// **Called before signing out, and the order is not arbitrary.** The rules
  /// grant this delete to `isSelf(uid)` only, so a sign-out that ran first would
  /// leave a document nothing on this device may ever remove — and the fan-out
  /// would go on sending this person's check-ins to a phone that has signed into
  /// somebody else's account.
  ///
  /// ## It must not be able to hang, and `delete()` can
  ///
  /// `DocumentReference.delete()` completes on **server acknowledgement**, not
  /// on local application — the same property that makes the check-in write
  /// fired rather than awaited. Awaited here with no bound, a sign-out on a
  /// phone with no signal simply never returns: the button does nothing,
  /// forever. Firing it instead is worse, not better, because the queued write
  /// would replay *after* `auth.signOut()` and be refused.
  ///
  /// So it is bounded, and the timeout is treated as a failure like any other.
  ///
  /// ## On failure the DEVICE TOKEN is invalidated, and that inverts the
  /// argument this docstring used to make
  ///
  /// It used to say the device token is "deliberately left alive", because
  /// "what makes a push reach an account is the document, and that is what this
  /// removes" — and then claimed `onCheckInCreated`'s `UNREGISTERED` pruning as
  /// the backstop when it could not.
  ///
  /// **That backstop does not exist for this case.** A row left behind here
  /// belongs to a token that is still perfectly *valid* — the app is installed
  /// and registered — so FCM returns success and **delivers**. Nothing ever
  /// returns `UNREGISTERED`, nothing prunes, and every later check-in of every
  /// person the previous account watched pushes `watchedName` and a day someone
  /// was verified alive to a phone now signed into somebody else's account.
  ///
  /// The original argument is right for the **success** path and exactly
  /// inverted for the failure path, which is the only path where the document
  /// survives. Invalidating the token there costs the next account one
  /// registration round trip and is what makes the claimed backstop true: the
  /// orphaned row now answers `UNREGISTERED` on the next fan-out and is deleted.
  Future<void> unregister({required String uid}) async {
    final value = await token();
    if (value == null) return;
    try {
      await _users.deleteToken(uid: uid, token: value).timeout(deleteTimeout);
    } on Object {
      try {
        // The row survived. Make it self-cleaning rather than permanent.
        await _messaging.deleteToken();
      } on Object {
        // Nothing left to try, and a sign-out must still complete.
      }
    }
  }

  /// Tokens rotate — on a restore, an app-data clear, or at FCM's discretion.
  ///
  /// A rotation the app does not record is a watcher who stops being woken and
  /// nothing anywhere saying so, which is §12's silent failure in the one tier
  /// that is supposed to be noisy. The old document is left behind on purpose:
  /// this device no longer knows that token, so it cannot prove it is dead, and
  /// FCM will say `UNREGISTERED` on the next fan-out — which is the authority on
  /// the question and the one path that prunes.
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;
}
