@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// **The permissions a release build declares, asserted against the manifest.**
///
/// `docs/security/threat-model.md` leans on one fact: a **release** build has no
/// `INTERNET` permission, so nothing it holds can leave the device. That is what
/// lets Phase 3 say "no logging, no analytics, nothing transmits" and mean it
/// rather than hope it. Until the Phase 3 gate, nothing asserted it — no test, no
/// lint, no script — and the precedent for it changing silently is in this
/// project's own manifest: `flutter_local_notifications` merged `VIBRATE` in
/// uninvited during Phase 2 and it had to be declared after the fact.
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

  test('the release manifest declares no INTERNET permission', () {
    // `main` is what a release build merges; there is no `src/release/`.
    expect(
      manifest('main'),
      isNot(contains('android.permission.INTERNET')),
      reason: 'threat-model.md states a release build cannot transmit, and this '
          'is the line that makes it true. Phase 4 adds Firebase, which brings '
          'INTERNET with it — when that happens, delete this test and re-derive '
          'the claim in the threat model rather than letting it rot.',
    );
  });

  test('and debug and profile still do', () {
    // Not tidiness — asserting the negative above is only meaningful if the
    // positive is present somewhere. If these ever lost it, the test above would
    // pass for the wrong reason: nothing anywhere declaring it, and a developer
    // wondering why their debug build cannot reach the emulator.
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
}
