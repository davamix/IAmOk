import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Brings Firebase up in **whichever isolate is asking**, and points it at the
/// emulator suite when this build was compiled for one.
///
/// ## Why this is one function and not three lines in `main()`
///
/// §4: three isolates run this app and they share no memory. The UI initialises
/// Firebase; so must the alarm isolate, because §10 has it read Firestore before
/// it decides whether to speak; so must the FCM background isolate. Three
/// copies of the same bootstrap is three chances to point one of them somewhere
/// different — and the failure that produces is not a crash. It is a background
/// isolate quietly talking to **production** while the UI talks to the emulator,
/// with both reporting success.
///
/// `NotificationService.watcherDelivery` carries the rule this follows: *two
/// copies of a decision are two chances to make it*. Both of Phase 3's wiring
/// defects turned out to be in a copy of one expression.
///
/// ## Idempotent, because the isolates do not coordinate
///
/// `Firebase.initializeApp()` throws `duplicate-app` if it runs twice in one
/// isolate, and there is no reliable way for an entry point to know whether
/// something earlier already called it — the alarm callback can fire while the
/// UI is alive, in the same process. So this checks `Firebase.apps` first and
/// every entry point may call it unconditionally, which is the only shape that
/// stays correct as entry points are added.
abstract final class FirebaseBootstrap {
  /// The host running the Firebase Emulator Suite, or empty for the real
  /// backend.
  ///
  /// Set at **compile time**, and that is deliberate rather than convenient:
  /// `String.fromEnvironment` is a const, so the same value is visible in every
  /// isolate of the binary without anything having to be passed, stored or
  /// re-read. A runtime setting would have to be written to `LocalStore` and
  /// read back by each isolate, and the window in which one of them had not read
  /// it yet is exactly the window where a background isolate writes to the live
  /// database.
  ///
  /// ```
  /// flutter run --dart-define=IAMOK_EMULATOR_HOST=10.0.2.2    # the API 36 AVD
  /// flutter run --dart-define=IAMOK_EMULATOR_HOST=127.0.0.1   # POCO, via adb reverse
  /// ```
  ///
  /// `tools/emulators.ps1 -Device <serial>` sets up the `adb reverse` the second
  /// form needs. Empty is the default, so a build nobody thought about is a
  /// build that talks to the real project — which is the right way round for a
  /// release, and the reason the harness renders the value where a device run
  /// can see it.
  static const String emulatorHost =
      String.fromEnvironment('IAMOK_EMULATOR_HOST');

  // In step with `firebase.json`. Wrong values here fail loudly and immediately
  // — nothing connects — which is the failure mode to prefer over a silent
  // fall-through to production.
  static const int _authPort = 9099;
  static const int _firestorePort = 8080;
  static const int _functionsPort = 5001;

  /// Where the callables live (§1, §9) — co-located with Firestore, and named
  /// at every call site because the library default is `us-central1`.
  ///
  /// A callable invoked in the wrong region does not fall back: it 404s, which
  /// reads like a function that was never deployed rather than one that was
  /// asked for in the wrong place.
  static const String functionsRegion = 'europe-west1';

  /// True when this build talks to the emulator suite instead of the project.
  static bool get usesEmulator => emulatorHost.isNotEmpty;

  /// Initialises Firebase for the current isolate, at most once.
  ///
  /// Safe to call from any entry point, including one that runs while another
  /// isolate is already up.
  static Future<void> ensureInitialized() async {
    if (Firebase.apps.isEmpty) {
      // No `options:` — the values come from `google-services.json` through the
      // Gradle plugin, so there is one source for them and no generated Dart
      // file to fall out of step with the JSON.
      await Firebase.initializeApp();
    }
    _useEmulators();
    await _activateAppCheck();
  }

  static bool _appCheckActivated = false;

  /// Starts sending App Check tokens — **and protects nothing yet.**
  ///
  /// ## The order is the decision (PLAN.md step 6)
  ///
  /// App Check is provisioned in **monitoring mode only**. Enforcing it before
  /// clients are attesting would lock the app out of its own backend — every
  /// read refused, which ADR-0004 maps to *refused*, which is the access-lost
  /// notice arriving at every family at once. So the client ships first, the
  /// console watches real traffic, and enforcement is a later phase's decision
  /// once the metrics say attested traffic is what is actually arriving.
  ///
  /// Until then `docs/security/threat-model.md` is right that **the rules are
  /// the whole defence**, and nothing here may be described as protecting
  /// anything.
  ///
  /// ## Two providers, and the debug one is not a weaker Play Integrity
  ///
  /// `AndroidProvider.debug` does not attest anything: it prints a UUID to
  /// logcat that a human pastes into the Firebase console, after which that one
  /// install is trusted unconditionally. That is a **backdoor with a list**, and
  /// it is acceptable only because it is compiled out — the branch is chosen by
  /// `kDebugMode`, a const, so a release build cannot reach it and the tree
  /// shaker removes it. Same argument as `AuthRepository._emulatorCredential`,
  /// which mints an identity without a password behind a compile-time const.
  ///
  /// ## Failure is swallowed, deliberately
  ///
  /// A device with no Play Services, an out-of-date Play Store, or a rooted ROM
  /// cannot produce an attestation. In monitoring mode that costs a metric and
  /// nothing else — so it must not be able to fail a launch, an alarm, or an FCM
  /// wake-up. §3's rule about tier 2 applies here for a stronger reason: this is
  /// tier *zero*, and the app is fully correct without it.
  ///
  /// Guarded by a flag rather than by `Firebase.apps`, because this is a
  /// per-isolate SDK setting and each of §4's three isolates has to activate its
  /// own.
  static Future<void> _activateAppCheck() async {
    if (_appCheckActivated) return;
    _appCheckActivated = true;
    try {
      await FirebaseAppCheck.instance.activate(
        // `providerAndroid`, not the deprecated `androidProvider` — the latter
        // is removed in a future major and this is a new call site, so there is
        // no reason to write the version that has to be migrated later.
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
      );
    } on Object {
      // Swallowed; see above. There is no surface that could honestly explain
      // this to anybody, and nothing depends on the answer.
    }
  }

  static bool _wired = false;

  /// Points Auth, Firestore **and Functions** at the emulator suite.
  ///
  /// Guarded by a flag rather than by `Firebase.apps`, because these are
  /// per-isolate SDK settings and re-applying them after use throws. The flag is
  /// isolate-local, which is correct: each isolate has its own SDK instance and
  /// each has to be told separately.
  ///
  /// **Functions joined the list in Phase 5**, and it belongs here for the same
  /// reason the other two do rather than at the call site: a build pointed at the
  /// emulator whose *callables* still went to the live project would mint real
  /// invites and write real links into `i-am-ok-c74ca` while every read around
  /// them came from the emulator, with both halves reporting success. That is
  /// this class's whole failure mode, one service later.
  static void _useEmulators() {
    if (!usesEmulator || _wired) return;
    _wired = true;
    // **`automaticHostMapping: false`, and it is not optional here.**
    //
    // Both plugins silently rewrite `127.0.0.1` and `localhost` to `10.0.2.2`
    // on Android, on the assumption that any Android device is the Android
    // emulator. On the AVD that is a kindness. On a **physical handset** it is
    // wrong and it is quiet: `10.0.2.2` means nothing there, so every read and
    // write fails to connect while the log says only
    //
    //   Mapping Firestore Emulator host "127.0.0.1" to "10.0.2.2".
    //
    // — measured on the POCO F3, 2026-08-21, and it defeats the `adb reverse`
    // route entirely. Turning it off makes `emulatorHost` mean exactly what it
    // says on both devices: `10.0.2.2` for the AVD, `127.0.0.1` for a handset
    // with `adb reverse` set up. One knob, no hidden rewrite.
    FirebaseAuth.instance
        .useAuthEmulator(emulatorHost, _authPort, automaticHostMapping: false);
    FirebaseFirestore.instance.useFirestoreEmulator(
      emulatorHost,
      _firestorePort,
      automaticHostMapping: false,
    );
    // **The region has to match here too.** `instanceFor` is what every call
    // site uses, and pointing the default instance at the emulator would leave
    // the regional one talking to the live project — the split-brain this
    // method exists to prevent, arriving through the one service that takes a
    // region.
    //
    // **`automaticHostMapping: false` here as well, and it is a THIRD plugin
    // doing it — measured on the POCO F3, 2026-08-26.** The note above says
    // "both plugins"; `cloud_functions` makes three, and it defaults the flag to
    // `true` exactly as the other two do. The failure is quieter than theirs,
    // because Auth and Firestore were already mapped correctly: the phone signed
    // in, wrote `users/{uid}`, showed the pairing screen — and then every
    // callable went to `10.0.2.2`, which means nothing on a physical handset, so
    // `redeemInvite` **hung until it timed out** and the Functions emulator
    // logged nothing at all. Half the app worked, so it read as a backend fault
    // rather than as a host that was never reached.
    //
    // The general rule, since this is now three for three: **every FlutterFire
    // API that takes an emulator host rewrites it on Android unless told not
    // to.** Assume the next one does too.
    FirebaseFunctions.instanceFor(region: functionsRegion).useFunctionsEmulator(
      emulatorHost,
      _functionsPort,
      automaticHostMapping: false,
    );
  }

  /// One line for the debug harness, so a device run can see where this build is
  /// pointed.
  ///
  /// **Worth a surface of its own.** The difference between talking to the
  /// emulator and talking to the live project is invisible from inside the app
  /// — both read, both write, both succeed — and getting it wrong in either
  /// direction is expensive: a device run that "passed" against an emulator
  /// proves nothing about the backend, and a test session that quietly wrote to
  /// production leaves real check-in rows for a person who does not exist.
  static String get describe =>
      usesEmulator ? 'EMULATOR $emulatorHost' : 'LIVE i-am-ok-c74ca';
}
