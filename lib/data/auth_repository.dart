import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase_bootstrap.dart';
import 'local_store.dart';

/// Google Sign-In → a Firebase uid, and the uid written where a bare isolate can
/// read it (§6).
///
/// Identity is Google Sign-In (§1): free, one tap on Android because the account
/// is already on the device, and **the uid survives a reinstall and a phone
/// replacement, so links never break**. It costs a small PII surface — an email
/// and a display name — which `docs/security/threat-model.md` accounts for.
///
/// UI isolate only. The background isolates never sign anybody in; they read the
/// uid from `LocalStore` and let the security rules judge the credential Firebase
/// restored for them. See [signIn] for why the store is the source there.
class AuthRepository {
  AuthRepository(this._store, {FirebaseAuth? auth, GoogleSignIn? google})
      : _injectedAuth = auth,
        _injectedGoogle = google;

  /// The **Web** OAuth client id, which is what `google_sign_in` needs as
  /// `serverClientId` on Android to return an ID token Firebase will accept.
  ///
  /// **Using the Android client id here produces a silent failure with no useful
  /// error** — recorded in `docs/infrastructure/firebase-setup-prompt.md`, which
  /// lists both ids. Neither is a secret: both ship inside the APK, and the real
  /// controls are the security rules plus App Check.
  static const String serverClientId =
      '744276314021-uour1dugadnlu0kf4atdmgs9bv00sd6n.apps.googleusercontent.com';

  final LocalStore _store;

  // **Resolved on use, not in the constructor.** `FirebaseAuth.instance` throws
  // if Firebase has not been initialised, so reaching for it while building the
  // composition root would make `AppServices` unconstructible in any test that
  // does not stand up the whole platform — for an object most of them never
  // call. Injected values win; the singletons are the fallback.
  final FirebaseAuth? _injectedAuth;
  final GoogleSignIn? _injectedGoogle;

  FirebaseAuth get _auth => _injectedAuth ?? FirebaseAuth.instance;
  GoogleSignIn get _google => _injectedGoogle ?? GoogleSignIn.instance;

  bool _initialised = false;

  /// The signed-in uid, or null.
  ///
  /// Read from Firebase rather than from the store, because in the UI isolate
  /// this is the identity the security rules will actually judge. The store's
  /// copy exists for the isolates that cannot ask — see [signIn].
  String? get currentUid => _auth.currentUser?.uid;

  String? get displayName => _auth.currentUser?.displayName;

  Stream<User?> get changes => _auth.authStateChanges();

  /// Signs in with Google and records the uid for the other isolates.
  ///
  /// Returns the uid, or null if the user dismissed the account chooser — which
  /// is a choice, not a fault, and is not reported as one.
  ///
  /// ## The uid is written to `LocalStore`, and that is not a cache
  ///
  /// The alarm isolate needs to know **whose** links these are. It has two
  /// possible sources — `FirebaseAuth.instance.currentUser` in its own isolate,
  /// or this row — and they are not equally safe.
  ///
  /// `currentUser` is restored from disk during `initializeApp`, and if it is
  /// null when a bare isolate asks, the reconcile finds **zero links, does
  /// nothing, and reports success**. That is silence, and silence is the one
  /// failure this app cannot detect in itself (§12, ADR-0007).
  ///
  /// A uid read from the store cannot be missing. If it were ever *wrong* — a
  /// sign-out this method failed to record, an account switch — every read for
  /// those links is `permission-denied`, which ADR-0004 maps to **refused**,
  /// which posts the access-lost notice and turns §13's panel red. Visible, and
  /// actionable.
  ///
  /// So the store wins, because its failure mode is loud and the alternative's is
  /// silent. `LocalStore.selfUid`'s own docstring carries the same argument from
  /// the other side.
  Future<String?> signIn() async {
    await _ensureGoogleInitialised();

    final UserCredential credential;
    if (FirebaseBootstrap.usesEmulator) {
      credential = await _auth.signInWithCredential(_emulatorCredential());
    } else {
      final GoogleSignInAccount account;
      try {
        account = await _google.authenticate();
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled) return null;
        rethrow;
      }
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        // Not a dismissal and not something the caller can retry into success:
        // it means the OAuth configuration is wrong, and the usual cause is
        // `serverClientId` being the Android client rather than the Web one.
        throw StateError(
          'Google returned no ID token. Check serverClientId is the WEB OAuth '
          'client — see AuthRepository.serverClientId.',
        );
      }
      credential = await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
    }

    final uid = credential.user?.uid;
    if (uid != null) await _store.setSelfUid(uid);
    return uid;
  }

  /// Signs out, and takes the local decision cache with it.
  ///
  /// **The cache has to go.** It is keyed by link, and every link belongs to the
  /// uid that is leaving: `warningsShownFor`, the cached away period, the armed
  /// warning alarms. Leaving it behind would let a *different* account's session
  /// inherit the previous one's standing warnings about someone it has never
  /// heard of — and the alarms would keep firing about them.
  ///
  /// The caller reconciles afterwards, which is what actually tears the alarms
  /// down: §3's rule is that nothing patches state incrementally, so "there are
  /// no links now" is expressed by reconciling against an empty desired set.
  Future<void> signOut() async {
    await _ensureGoogleInitialised();
    if (!FirebaseBootstrap.usesEmulator) {
      await _google.signOut();
    }
    await _auth.signOut();
    await _store.clearSelfUid();
  }

  Future<void> _ensureGoogleInitialised() async {
    if (_initialised) return;
    _initialised = true;
    // Not against the emulator: there is no Google to talk to, and
    // `initialize()` would go looking for play services that have nothing to
    // authenticate against.
    if (!FirebaseBootstrap.usesEmulator) {
      await _google.initialize(serverClientId: serverClientId);
    }
  }

  /// A synthetic Google credential the **Auth emulator** accepts.
  ///
  /// Real Google Sign-In cannot work against the emulator suite — there is no
  /// Google in the loop to issue an ID token, and the emulator could not verify
  /// one if there were. The documented substitute is an *unsigned* ID token: the
  /// emulator reads `GoogleAuthProvider.credential`'s `idToken` as a plain JSON
  /// claim set and creates or reuses the matching user.
  ///
  /// **Gated on `FirebaseBootstrap.usesEmulator`, which is a compile-time
  /// const**, so a release build cannot reach this line at all — the branch is
  /// dead code the tree shaker removes. That matters more than it looks: this is
  /// a function that mints an identity without a password, and the guard on it
  /// must not be something a runtime setting, a restore, or a rooted device
  /// could flip. It is the same argument `main.dart` makes for gating the debug
  /// clock offset on `kDebugMode`, one step stronger.
  ///
  /// The fixed subject means the emulator hands back the **same uid every run**,
  /// which is what lets `tools/emulators.ps1` export and re-import a link graph
  /// that still belongs to somebody after a restart.
  AuthCredential _emulatorCredential() => GoogleAuthProvider.credential(
        idToken: jsonEncode({
          'sub': 'emulator-watcher',
          'email': 'watcher@example.test',
          'email_verified': true,
          'name': 'Ana',
        }),
      );
}
