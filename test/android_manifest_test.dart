@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// **The permissions a release build declares, asserted against the manifest.**
///
/// Through Phase 3 this file guarded one claim: a **release** build has no
/// `INTERNET` permission, so nothing it holds can leave the device. **Phase 4
/// ended that**, exactly as `deploy-notes.md` predicted it would — `firebase_auth`,
/// `cloud_firestore` and `google_sign_in` all declare `INTERNET`, and measuring
/// the merged release manifest on 2026-08-21 confirmed it is now there.
///
/// The claim was **re-derived rather than deleted**, and the new one is narrower
/// and true: see `docs/security/threat-model.md`. What this file guards now is
/// the *closed set* — the permissions a release build asks for are exactly the
/// ones somebody decided to ask for.
///
/// The precedent for that set changing silently is in this project's own
/// manifest twice over: `flutter_local_notifications` merged `VIBRATE` in
/// uninvited during Phase 2, and Phase 4's measurement found
/// **`USE_BIOMETRIC` and `USE_FINGERPRINT`** arriving from
/// `androidx.biometric`, pulled in transitively behind `firebase_auth`, for a
/// feature this app does not have.
///
/// ## What this can and cannot see
///
/// It reads the **source** manifests, so it catches the case someone adds a line
/// here. It **cannot** see a permission arriving from a transitive AAR, which is
/// exactly how `VIBRATE` arrived — that needs the merged manifest, which needs a
/// release build, which no unit test can run.
///
/// So this is half the guard, and the half a test can hold. The other half is a
/// command in `docs/infrastructure/deploy-notes.md`, owed whenever a plugin is
/// added:
///
/// ```powershell
/// flutter build apk --release
/// Select-String -Path build\app\outputs\logs\manifest-merger-release-report.txt -Pattern INTERNET
/// ```
///
/// Stated plainly rather than left implied, because a guard that looks complete
/// and is not is worse than one whose limit is written down.
void main() {
  String manifest(String sourceSet) =>
      File('android/app/src/$sourceSet/AndroidManifest.xml').readAsStringSync();

  test('the SOURCE manifest still declares no INTERNET of its own', () {
    // Deliberately kept, and deliberately weaker than it used to be. A release
    // build now HOLDS `INTERNET`, merged in from Firebase — that is measured and
    // recorded. What this still says is that nobody added it here by hand, which
    // matters because the source manifest is the one place a change is a
    // decision rather than a consequence of a dependency.
    //
    // The instruction the old version of this test carried — "when Firebase
    // arrives, delete this and re-derive the claim in the threat model rather
    // than letting it rot" — was followed on 2026-08-21.
    expect(
      manifest('main'),
      isNot(contains('android.permission.INTERNET')),
      reason: 'the app declares no INTERNET itself; it inherits one. If this '
          'ever becomes a deliberate declaration, say why here and in '
          'threat-model.md',
    );
  });

  test('and debug and profile still declare it explicitly', () {
    // Not tidiness. These exist for the Flutter tooling — the VM service, hot
    // reload — and are the reason a debug build could always reach a local
    // emulator. Losing them would break `tools/emulators.ps1` in a way that
    // looks like a networking problem.
    for (final sourceSet in ['debug', 'profile']) {
      expect(manifest(sourceSet), contains('android.permission.INTERNET'),
          reason: '$sourceSet needs it for the Flutter tooling');
    }
  });

  test('the permissions main declares are exactly the ones we reason about', () {
    // A closed set, so a permission added by hand has to be added here too —
    // with whatever justification the review of that change produced. §13 owns
    // what each is for.
    final declared = RegExp(r'android:name="android\.permission\.(\w+)"')
        .allMatches(manifest('main'))
        .map((m) => m.group(1)!)
        .toSet();

    expect(
      declared,
      {
        'POST_NOTIFICATIONS', // §13: without it the app is inert
        'RECEIVE_BOOT_COMPLETED', // §10: re-arm after a reboot
        'USE_EXACT_ALARM', // §10: the warning fires at warningLocalTime
        'SCHEDULE_EXACT_ALARM', // the pre-33 twin of the above
        'VIBRATE', // arrived from flutter_local_notifications, declared after
        'WAKE_LOCK', // the alarm isolate has to finish its reconcile
      },
      reason: 'a permission appearing here without a decision behind it is the '
          'thing this asserts against — including one merged in by a plugin and '
          'then copied up into the source manifest',
    );
  });

  group('cleartext to the emulator is a DEBUG-only grant', () {
    // Measured on the POCO F3, 2026-08-21: the first sign-in against the
    // emulator suite failed with
    //
    //   [firebase_auth/unknown] Cleartext HTTP traffic to 127.0.0.1 not permitted
    //
    // because Android has denied cleartext by default since API 28 and the
    // suite speaks plain HTTP. The grant that fixes it is narrow in two
    // directions at once, and this group asserts both — a "move it to main so
    // profile builds work too" would undo the second silently, and the symptom
    // would be a shipped app permitted to send plaintext.

    test('the config exists and names only the two loopback routes', () {
      final config = File(
        'android/app/src/debug/res/xml/network_security_config.xml',
      );
      expect(config.existsSync(), isTrue);

      final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>')
          .allMatches(config.readAsStringSync())
          .map((m) => m.group(1)!.trim())
          .toSet();

      expect(
        domains,
        {
          '127.0.0.1', // a physical handset, through `adb reverse` over USB
          '10.0.2.2', // the AVD's alias for the host loopback
        },
        reason: 'both are loopback-scoped by construction. A hostname or an IP '
            'that is not one of these would let a debug build send plaintext to '
            'a machine on the network, which is a different decision from the '
            'one this file records',
      );
    });

    test('it is referenced from the debug manifest and NOWHERE else', () {
      expect(
        manifest('debug'),
        contains('android:networkSecurityConfig="@xml/network_security_config"'),
      );
      // The one that matters. `main` is what a release build merges, so a
      // reference there would ship the grant.
      for (final sourceSet in ['main', 'profile']) {
        expect(
          manifest(sourceSet),
          isNot(contains('networkSecurityConfig')),
          reason: '$sourceSet must not carry it — a release build has to keep '
              'the platform default of TLS or nothing',
        );
      }
    });

    test('and nothing anywhere opens cleartext wholesale', () {
      // `android:usesCleartextTraffic="true"` would allow plaintext to ANY
      // host, which is the shortcut this config exists instead of.
      for (final sourceSet in ['main', 'debug', 'profile']) {
        expect(
          manifest(sourceSet),
          isNot(contains('usesCleartextTraffic')),
          reason: 'the domain-scoped config is the whole point; a blanket flag '
              'would be a much larger grant for the same convenience',
        );
      }
    });
  });

  /// **What a release build actually ships, measured rather than declared.**
  ///
  /// The set above is what this repo asks for. This is what a user grants, and
  /// the two differ by seven permissions that arrived from dependencies — which
  /// is the whole reason the merged report matters and the source manifest is
  /// only half the guard.
  ///
  /// **A test cannot produce this.** It needs `flutter build apk --release`,
  /// which writes files, so the measurement is a command in
  /// `docs/infrastructure/deploy-notes.md` and the result is recorded here as
  /// evidence with a date on it. Recorded rather than asserted, honestly: what
  /// follows is a **finding from 2026-08-21**, not something re-checked on every
  /// run.
  ///
  /// ```
  /// INTERNET                 firebase-auth, firestore, google_sign_in
  /// ACCESS_NETWORK_STATE     firebase-auth, firestore
  /// USE_BIOMETRIC            androidx.biometric 1.1.0  <- unused by this app
  /// USE_FINGERPRINT          androidx.biometric 1.1.0  <- unused by this app
  /// READ_GSERVICES           com.google.android.recaptcha 18.6.1
  /// DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION   androidx (self-scoped)
  /// ```
  ///
  /// **The two biometric permissions are a live question for Phase 8**, not a
  /// curiosity. This app has no biometric feature and never asks for one; they
  /// come from a library behind `firebase_auth`. An app for elderly people
  /// requesting fingerprint access with no fingerprint feature is a Play review
  /// question at best, and at worst it is what a careful family member reads on
  /// the install screen and declines.
  ///
  /// They are removable with `tools:node="remove"` in the source manifest. That
  /// is **deliberately not done yet**: it is a change on the sign-in path, and
  /// stripping permissions from the auth libraries before the happy path has
  /// ever been proven on hardware would confound the first real measurement.
  /// Decide it at Phase 8, where the Play permission story is written anyway,
  /// with a device run behind it.
  test('the merged-release finding above has a home and a date', () {
    // A comment nothing points at is a comment nobody re-reads. This asserts
    // only that the document carrying the standing claim still exists, so the
    // finding cannot be orphaned by a rename.
    expect(File('docs/security/threat-model.md').existsSync(), isTrue);
    expect(File('docs/infrastructure/deploy-notes.md').existsSync(), isTrue);
  });
}
