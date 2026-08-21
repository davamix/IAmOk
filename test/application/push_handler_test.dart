@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// **The push carries no authority, checked where it could stop being true.**
///
/// `test/domain/reconcile/watcher_reconciler_test.dart` asserts the consequence:
/// a nudge arriving with Firestore unreachable and an empty cache moves nothing.
/// That test is only meaningful because the reconciler is never *given* the
/// payload — and nothing enforced that. `pushBackgroundHandler` receives a
/// `RemoteMessage` carrying `{watchedUid, date, deviceTappedAt, tz,
/// watchedName}`, which looks exactly like the answer the reconcile is about to
/// go and fetch. Reading one field out of it "to save a read" would make FCM
/// load-bearing (§3): a dropped message would change an answer rather than delay
/// one, and a **forged** message would move `lastConfirmedDay` for a day nobody
/// tapped — a family told their relative is fine by anyone who can send this app
/// a push.
///
/// So the strongest available guarantee is that the handler does not look at the
/// message at all, and that is what is asserted here.
///
/// ## A lint, not a proof
///
/// Same standing as the shared-store guards in `domain_purity_test.dart`: this
/// is substring-and-token matching over source, and a determined refactor could
/// evade it. It exists to stop the specific, tempting shortcut, and to make the
/// next person read the reason before taking it.
///
/// The handler itself cannot be *run* here — it is a bare-isolate entry point
/// that brings up Firebase, opens the platform store and initialises the
/// notification plugin. What it reaches is checked by
/// `domain_purity_test.dart`'s computed closure; what it does with its argument
/// is checked here.
void main() {
  final source =
      _withoutComments(File('lib/application/push_handler.dart').readAsStringSync());

  test('the handler exists and is a vm entry point', () {
    // Without `@pragma('vm:entry-point')` the function is tree-shaken out of a
    // release build and the plugin's raw handle points at nothing — the app
    // never wakes, and nothing anywhere says so.
    expect(source, contains("@pragma('vm:entry-point')"));
    expect(source, contains('Future<void> pushBackgroundHandler('));
  });

  test('it never reads the message', () {
    // Exactly one occurrence of the identifier: the parameter declaration.
    // Any second one is a use.
    final uses = RegExp(r'\bmessage\b').allMatches(source).length;
    expect(uses, 1,
        reason: 'pushBackgroundHandler must not read its RemoteMessage. §3: a '
            'push is a nudge carrying no authority, and the reconcile is what '
            'establishes the facts. Deciding anything from the payload lets a '
            'forged message move lastConfirmedDay for a day nobody tapped.');
  });

  test('it reconciles both sides', () {
    // Phase 4's only push goes to WATCHERS, so the watched side looks like dead
    // weight and is the half a tidy-up would remove. It is not: Phase 6's
    // `onAwayChanged` fans out to the watched person's own device, and their
    // REMINDERS are what must change. More generally §3 — a nudge carries no
    // authority about what it concerns, so reconciling the half we guessed at is
    // the same mistake as acting on the payload.
    expect(source, contains('WatcherReconcileService('));
    expect(source, contains('WatchedReconcileService('));
  });

  test('it names itself in the reconcile lease', () {
    // ADR-0006 serialises reconciles on disk. The owner string is what makes a
    // held lease legible in a `dump()` instead of an opaque token — and with
    // three isolates now able to take it, "who is holding this" stops being
    // guessable.
    expect("lockOwner: 'fcm'".allMatches(source).length, 2,
        reason: 'both sides must name this isolate, or a dump attributes half '
            'its reconciles to the UI');
  });

  test('it never closes the store', () {
    // Measured on the POCO F3, 2026-08-20, on the ALARM isolate: Android runs
    // every isolate in the app's own process and sqflite hands each one the same
    // native connection, so a background `close()` kills the UI's store for the
    // life of the process. `domain_purity_test.dart` holds every background
    // entry point to this; it is repeated here because this file is the newest
    // one to inherit the rule.
    expect(source.contains('.close()'), isFalse);
  });
}

String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final comment = RegExp(r'(?<!:)//').firstMatch(line);
      return comment == null ? line : line.substring(0, comment.start);
    })
    .join('\n');
