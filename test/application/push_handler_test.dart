@TestOn('vm')
library;

import 'dart:io';

import 'package:i_am_ok/application/push_handler.dart';
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

  test('it tells the delivery derivation the app is NOT in front of anybody', () {
    // **A one-word slip here reproduces the worst defect Phase 3 found.**
    // `NotificationDelivery.from` turns `appInForeground: true` into
    // `redundant`, and `redundant` has `postsNotification == false` and
    // `consumesReminder == true` — so the FCM isolate would decide a warning is
    // owed, record the day as served, and post nothing to anyone. Measured on
    // the POCO on 2026-08-18 through the app-open path, where
    // `warningsShownFor` held `warnOnline` with zero notifications sent.
    //
    // It is false here by definition: this isolate exists only because a push
    // arrived while the app was not on screen. `providers_test.dart` asserts the
    // derivation itself but reads neither entry point.
    expect(source, contains('appInForeground: false'));
  });

  test('and so does the alarm handler, which is where it drifted once', () {
    // Same hole, same cost, and the alarm handler's own docstring admits "this
    // copy is the one nobody can watch running, and it drifted from its twin
    // once already". Guarded here rather than in a file of its own because the
    // property belongs to background entry points as a class.
    final alarm = _withoutComments(
      File('lib/application/warning_alarm_handler.dart').readAsStringSync(),
    );
    expect(alarm, contains('appInForeground: false'));
  });

  test('the platform is told where to find it', () {
    // Delete `FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler)` and
    // §4's third isolate silently stops existing: every test still passes,
    // `flutter analyze` is clean, and the only symptom is a watcher who finds
    // out at alarm time instead of in seconds — the silence §12 calls the one
    // failure this app cannot detect in itself.
    //
    // The registration has to live in `main()` because the plugin records the
    // callback's raw handle for its Android service to start an engine at, so a
    // registration the app might not reach on a cold start is one that is not
    // there when it matters.
    final main = _withoutComments(File('lib/main.dart').readAsStringSync());
    expect(main, contains('onBackgroundMessage(pushBackgroundHandler)'));
  });

  test('the foreground listener discards its message too', () {
    // The §3 guarantee is asserted hard for the background handler and was
    // asserted nowhere for the UI isolate — which is the EASIER place to take
    // the shortcut, because the container, the repositories and the notifier are
    // all already in scope. In the background handler you would have to build
    // something first.
    final main = _withoutComments(File('lib/main.dart').readAsStringSync());
    expect(main, contains('FirebaseMessaging.onMessage.listen(\n      (_) =>'),
        reason: 'the listener must discard its RemoteMessage at the listen '
            'site. Binding it is how a payload starts being trusted.');
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

  group('runBothSides — the failure isolation, actually run', () {
    // Extracted out of the entry point precisely so these four lines exist. The
    // source lint above says the two services are mentioned; only this says the
    // second one still runs when the first does not.

    test('both run, in order, when nothing fails', () async {
      final order = <String>[];
      await runBothSides(
        () async => order.add('watcher'),
        () async => order.add('watched'),
      );
      expect(order, ['watcher', 'watched'],
          reason: 'the watcher side is the reason the OS woke this isolate, and '
              'a background engine has seconds to live — if only one of the two '
              'completes it must be the one that decides whether to tell a '
              'family something');
    });

    test('the watched side still runs when the watcher side throws', () async {
      // The defect this replaced: `await A; await B;` skips B entirely, which is
      // a second failure caused by the first. Phase 6's away nudge lands on the
      // watched side, so this is the half that must change then.
      final order = <String>[];
      await expectLater(
        runBothSides(
          () async {
            order.add('watcher');
            throw StateError('the store was busy');
          },
          () async => order.add('watched'),
        ),
        throwsStateError,
      );
      expect(order, ['watcher', 'watched']);
    });

    test('and the throw still escapes, so crash reporting sees it', () async {
      // `warningAlarmCallback` has no `try` for exactly this reason: a fault in
      // a background isolate has no screen, no user and no log anyone will read,
      // so the crash report is the only account there will ever be. Swallowing
      // here would buy tidiness and cost that.
      await expectLater(
        runBothSides(() async => throw StateError('x'), () async {}),
        throwsStateError,
      );
    });

    test('a watched-side throw is not hidden either', () async {
      await expectLater(
        runBothSides(() async {}, () async => throw StateError('y')),
        throwsStateError,
      );
    });
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
    // **CRLF first, and this is not cosmetic.** Git for Windows defaults to
    // `core.autocrlf=true`, so a fresh clone checks these files out with CRLF
    // while the repo stores LF. Every lint below that spans two lines would
    // then fail on a machine where nothing is wrong — a red suite produced by
    // the checkout, on the tests whose whole job is to be trusted. Measured:
    // one `git checkout lib/main.dart` on 2026-08-26 broke
    // `push_handler_test`'s two-line listener lint and nothing else.
    .replaceAll('\r\n', '\n')
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final comment = RegExp(r'(?<!:)//').firstMatch(line);
      return comment == null ? line : line.substring(0, comment.start);
    })
    .join('\n');
