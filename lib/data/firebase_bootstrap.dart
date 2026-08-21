import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

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
  }

  static bool _wired = false;

  /// Points Auth and Firestore at the emulator suite.
  ///
  /// Guarded by a flag rather than by `Firebase.apps`, because these are
  /// per-isolate SDK settings and re-applying them after use throws. The flag is
  /// isolate-local, which is correct: each isolate has its own SDK instance and
  /// each has to be told separately.
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
