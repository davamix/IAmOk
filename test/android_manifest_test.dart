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
  /// **Re-measured the same day, after step 5 added `firebase_messaging`.** One
  /// more, and only one:
  ///
  /// ```
  /// com.google.android.c2dm.permission.RECEIVE   firebase-messaging 25.1.1
  /// ```
  ///
  /// Signature-level and owned by Play Services: it appears on no install
  /// screen and there is nothing for a user to accept or decline, so it raises
  /// none of the question the biometric pair does. `WAKE_LOCK` is unchanged —
  /// `firebase-messaging` merges it, and the source manifest has declared it
  /// since Phase 3 for the alarm that wakes the watcher's isolate.
  ///
  /// **Re-measured a third time, after step 6 added `firebase_app_check`.** The
  /// answer is **no change at all** — still thirteen, and
  /// `firebase-appcheck-playintegrity` plus `com.google.android.play:integrity`
  /// contribute none of their own.
  ///
  /// (This said *"fourteen"* until the Phase 5 gate review. See the correction
  /// under the fourth measurement below — the number was always wrong, and the
  /// arithmetic in this very docstring already disagreed with it.)
  ///
  /// That is worth recording precisely *because* it is a null result. The rule
  /// in this file's docstring is "owed whenever a plugin is added", and a rule
  /// that is only honoured when it finds something stops being run. The Phase 4
  /// security review caught that this measurement had been skipped for step 6
  /// while the two before it were recorded.
  ///
  /// This is the routine the docstring above predicts: a plugin was added, the
  /// release build was run, and the diff is stated rather than guessed.
  ///
  /// **Re-measured a fourth time, when Phase 5 closed — 2026-08-26**, and again
  /// at the gate review. Two plugins were added that phase (`share_plus`,
  /// `cloud_functions`). The permission answer is **no change at all**: still
  /// the same **thirteen**, and neither plugin contributes one of its own.
  ///
  /// **Thirteen, not fourteen, and the number had been wrong since Phase 4.**
  /// The merger report lists AndroidX's
  /// `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` **twice** — once with
  /// `${applicationId}` unresolved and once resolved — so a grep of the report
  /// double-counts one permission. The merged manifest itself has 13 distinct
  /// `<uses-permission>` elements.
  ///
  /// The arithmetic above already disagreed: this file says the merged set
  /// differs from `main`'s by **seven**, and `main` declares **six**. 6 + 7 is
  /// 13. Nothing asserted the number, so nothing caught it for two phases —
  /// which is the argument for counting from the manifest, where a double count
  /// is impossible, rather than from a report that resolves placeholders by
  /// listing both forms.
  ///
  /// **But the permission check alone would have missed what they did add**, and
  /// that is the finding worth keeping. `deploy-notes.md`'s standing command is
  /// `Select-String … -Pattern INTERNET`, which greps for a *permission* — and
  /// `share_plus` contributes two **components**:
  ///
  /// ```
  /// provider#dev.fluttercommunity.plus.share.ShareFileProvider
  ///   android:exported="false"
  ///   android:grantUriPermissions="true"
  ///   android:authorities="io.github.davamix.i_am_ok.flutter.share_provider"
  /// receiver#dev.fluttercommunity.plus.share.SharePlusPendingIntent
  ///   android:exported="false"
  /// ```
  ///
  /// `cloud_functions` contributes **three** `meta-data` Firebase component
  /// registrars and nothing else: `FlutterFirebaseAppRegistrar`,
  /// `FunctionsRegistrar` and `FirebaseFunctionsKtxRegistrar`. (Recorded as
  /// *one* until the gate review — the command in `deploy-notes.md` had no
  /// `meta-data` in its alternation, so it could not see the very thing it was
  /// cited as having measured. Both are fixed.)
  ///
  /// `share_plus` also nests a `FILE_PROVIDER_PATHS` meta-data inside its
  /// provider. That resource is what actually bounds what the provider could
  /// expose, so it is the thing worth naming in a paragraph arguing the
  /// provider is harmless.
  ///
  /// Verified against the merged release manifest itself
  /// (`build/app/intermediates/merged_manifest/release/…`) rather than the
  /// merger report, because **the report lists attribute names without their
  /// values** — it says `android:exported` was added and not what it was set
  /// to, which is the whole question. Note the path is an AGP implementation
  /// detail that has moved before; `deploy-notes.md` globs for it and throws
  /// rather than hard-coding it.
  ///
  /// **Both components are `exported="false"`**, so neither is reachable from
  /// another app, and the provider's authority is scoped to this application id.
  /// The receiver does carry an `<intent-filter>`; the explicit
  /// `exported="false"` overrides the default that filter would otherwise imply,
  /// so it stays unreachable.
  ///
  /// `grantUriPermissions="true"` is **not a grant**. It is permission for *this
  /// app* to attach `FLAG_GRANT_READ_URI_PERMISSION` to a URI it hands out —
  /// what a FileProvider is for. **This app shares only text** —
  /// `ShareParams(text: …)`, the invite code and its expiry — so no URI is ever
  /// minted, nothing is ever granted, and the provider is present and unused. Recorded rather than removed: it is a
  /// plugin's own manifest entry, it grants nothing while nothing calls it, and
  /// stripping a dependency's component is the kind of change that should be
  /// made with a device run behind it, alongside the biometric question below.
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
  /// The permission count, asserted rather than left in prose.
  ///
  /// It was wrong for two phases *because nothing asserted it* — the docstring
  /// said fourteen while its own arithmetic said thirteen. A number in a comment
  /// is a claim nobody reads back against the thing it describes, which is the
  /// failure this whole file exists to prevent one layer up.
  ///
  /// This asserts the **source** manifest's own count, which is the half that
  /// lives in this repo; the merged total is `main`'s six plus seven merged in,
  /// and the merged half needs a release build, so it stays a recorded
  /// measurement with a date on it.
  test('main declares six permissions, and the merged total is thirteen', () {
    final declared = RegExp(r'android:name="android\.permission\.(\w+)"')
        .allMatches(manifest('main'))
        .map((m) => m.group(1))
        .toSet();
    expect(declared, hasLength(6),
        reason: 'six declared here, seven merged in from dependencies, '
            'thirteen in the release manifest — recorded above with dates');
  });

  test('the merged-release finding above has a home and a date', () {
    // A comment nothing points at is a comment nobody re-reads. This asserts
    // only that the document carrying the standing claim still exists, so the
    // finding cannot be orphaned by a rename.
    expect(File('docs/security/threat-model.md').existsSync(), isTrue);
    expect(File('docs/infrastructure/deploy-notes.md').existsSync(), isTrue);
  });

  /// **Every emulator wiring call passes `automaticHostMapping: false`.**
  ///
  /// A lint, not a proof — the same shape as the guards in
  /// `domain_purity_test.dart`, and it exists to stop the *specific* regression
  /// that already happened.
  ///
  /// Measured on the POCO F3 on 2026-08-26: `FirebaseBootstrap` passed the flag
  /// to Auth and Firestore and not to `useFunctionsEmulator`, which defaults it
  /// to `true` exactly as the other two do. Over `adb reverse` the phone signed
  /// in, wrote `users/{uid}` and rendered the pairing screen — then every
  /// callable went to `10.0.2.2`, which means nothing on a physical handset, so
  /// `redeemInvite` hung until it timed out and the Functions emulator logged
  /// nothing at all. **Half the app working is what made it read as a backend
  /// fault** rather than as a host that was never reached.
  ///
  /// Three plugins, three for three. This is the `CLAUDE.md` line made
  /// mechanical, so the fourth cannot be missed by remembering.
  test('every emulator wiring call passes automaticHostMapping: false', () {
    // Comments stripped first: the reasoning above the calls quotes the flag
    // several times, and matching those would make the count pass for the wrong
    // reason. The same move `copy_floors_test.dart` makes, for the same reason.
    final code = File('lib/data/firebase_bootstrap.dart')
        .readAsStringSync()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final calls = RegExp(r'use\w+Emulator\(').allMatches(code).length;
    final flags = 'automaticHostMapping: false'.allMatches(code).length;

    expect(calls, greaterThan(0), reason: 'the regex stopped matching anything');
    expect(
      flags,
      calls,
      reason: 'every FlutterFire API that takes an emulator host rewrites it on '
          'Android unless told not to — $calls wiring calls, $flags opt-outs',
    );
  });

}
