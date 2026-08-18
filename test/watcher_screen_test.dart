import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/watcher_reconcile_service.dart';
import 'package:i_am_ok/copy/notification_copy.dart';
import 'package:i_am_ok/copy/watcher_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/notification_router.dart';
import 'package:i_am_ok/presentation/watcher_screen.dart';

/// The watcher list's states.
///
/// Widget tests rather than a device check, because every question here is about
/// **rendering**: does a standing warning show instead of "Everything OK", does
/// the lost-access row outrank it, does a screen reader get the person and their
/// state in one utterance. `docs/testing/strategy.md`'s rule is that if a test
/// needs a device to answer a question about logic, the logic is in the wrong
/// layer.
///
/// This screen matters more than a list usually would: it is the destination the
/// *lost access* notification promises when it says **"Open the app to see what
/// to do."** ADR-0004 makes that actionability the reason the message exists at
/// all, so a row that failed to carry the remediation would quietly turn that
/// notification into a lie.
void main() {
  TimeZones.ensureInitialized();
  final today = DayKey(2026, 8, 17);
  final d = DayKey(2026, 8, 16);

  Link linkTo(String watchedUid, String name) => Link(
        watchedUid: watchedUid,
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: name,
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: DayKey(2026, 8, 1),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      );

  WatchedPersonState person({
    String uid = 'mum',
    String name = 'Mum',
    WatcherCache cache = const WatcherCache.empty(),
    WarningOutcome outcome = WarningOutcome.silent,
  }) =>
      WatchedPersonState(
        link: linkTo(uid, name),
        cache: cache,
        decision: WarningDecision(
          outcome: outcome,
          day: d,
          silenceReason: outcome == WarningOutcome.silent
              ? SilenceReason.checkInRecorded
              : null,
        ),
      );

  Future<void> pump(
    WidgetTester tester,
    List<WatchedPersonState> people, {
    double textScale = 1,
    Size surface = const Size(400, 800),
  }) async {
    tester.view.physicalSize = surface * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    addTearDown(NotificationRouter.instance.consume);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: WatcherBody(
                state: WatcherState(people: people, today: today),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('nobody is watched', () {
    testWidgets('says so, and names a next human', (tester) async {
      await pump(tester, const []);
      expect(find.text(WatcherCopy.nobody), findsOneWidget);
    });

    testWidgets('is not styled as a warning', (tester) async {
      // An empty list is not an alarm. Colouring it red would turn it into a
      // status message about other people's behaviour, which this app
      // deliberately does not do.
      await pump(tester, const []);
      final context = tester.element(find.text(WatcherCopy.nobody));
      final style = tester.widget<Text>(find.text(WatcherCopy.nobody)).style;
      expect(style?.color, isNot(Theme.of(context).colorScheme.error),
          reason: 'ordinary secondary text. The assertion is against the ERROR '
              'colour rather than against null, because the theme legitimately '
              'gives body text a colour — asserting null would pass for the '
              'wrong reason and fail the moment a theme is applied.');
    });
  });

  group('state, not history', () {
    testWidgets('no standing warning shows Everything OK and the last day',
        (tester) async {
      await pump(tester, [person(cache: WatcherCache(lastConfirmedDay: d))]);
      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
      expect(find.text(WatcherCopy.lastSeen(NotificationCopy.dayLabel(d))),
          findsOneWidget);
    });

    testWidgets('never seen says so rather than blaming her', (tester) async {
      await pump(tester, [person()]);
      expect(find.text(WatcherCopy.neverSeen), findsOneWidget);
    });

    testWidgets('a standing warning replaces Everything OK', (tester) async {
      await pump(tester, [
        person(
          cache: WatcherCache(warningsShownFor: {d: WarningOutcome.warnOnline}),
          outcome: WarningOutcome.warnOnline,
        ),
      ]);
      expect(find.text('No check-in from Mum yesterday.'), findsOneWidget);
      expect(find.text(WatcherCopy.everythingOk), findsNothing);
    });
  });

  group('the lost-access row', () {
    WatchedPersonState refused(RefusedCause cause) => person(
          cache: WatcherCache(
            accessLostSince: d,
            accessLostCause: cause,
            warningsShownFor: {d: WarningOutcome.warnOnline},
          ),
          outcome: WarningOutcome.warnAccessLost,
        );

    testWidgets('carries the label, the consequence and the remediation',
        (tester) async {
      await pump(tester, [refused(RefusedCause.unauthenticated)]);
      expect(find.text(WatcherCopy.accessLostLabel('Mum')), findsOneWidget);
      expect(
          find.text(WatcherCopy.accessLostConsequence('Mum')), findsOneWidget);
      expect(find.text('Sign in again.'), findsOneWidget);
    });

    testWidgets('each cause implies a different instruction', (tester) async {
      await pump(tester, [refused(RefusedCause.appCheckRejected)]);
      expect(find.text('Update I Am Ok in the Play Store.'), findsOneWidget);
    });

    testWidgets('an unfixable cause names a next human', (tester) async {
      await pump(tester, [refused(RefusedCause.permissionDenied)]);
      expect(find.textContaining('ask whoever set up the app'), findsOneWidget);
    });

    testWidgets('outranks a standing warning about her', (tester) async {
      // ADR-0004's ordering, reaching the list. A refusal is a fault in THIS
      // app rather than a claim about her, and it is what the reader tapped
      // through to understand.
      await pump(tester, [refused(RefusedCause.unauthenticated)]);
      expect(find.text('No check-in from Mum yesterday.'), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('a row is one utterance: the person and their state',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, [person(cache: WatcherCache(lastConfirmedDay: d))]);

      expect(
        find.bySemanticsLabel(RegExp('^Mum. Everything OK')),
        findsOneWidget,
        reason: 'a screen reader gets the row as one utterance, not a heading '
            'with the detail somewhere beneath it',
      );
      handle.dispose();
    });

    testWidgets('survives the largest system font scale without overflow',
        (tester) async {
      // Set by exactly the people this app is for. An overflow here is an
      // unreadable row about someone who may have missed a day.
      await pump(
        tester,
        [
          person(
            cache: WatcherCache(
              accessLostSince: d,
              accessLostCause: RefusedCause.permissionDenied,
            ),
            outcome: WarningOutcome.warnAccessLost,
          ),
        ],
        textScale: 2,
        surface: const Size(320, 640),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('colour is never the only signal', (tester) async {
      // Every bad state carries its own words. Asserted because "make it red"
      // is the reflex that quietly removes the text.
      await pump(tester, [
        person(
          cache: WatcherCache(warningsShownFor: {d: WarningOutcome.warnOnline}),
          outcome: WarningOutcome.warnOnline,
        ),
      ]);
      expect(find.text('No check-in from Mum yesterday.'), findsOneWidget);
    });
  });

  group('a tapped notification', () {
    testWidgets('is consumed once the person has been shown', (tester) async {
      // The cold-start path: the payload is captured in main() before runApp,
      // so it is already set before this widget exists. §13's argument is that
      // a low-usage watcher never opens the app, which makes this the NORMAL
      // arrival rather than an edge case.
      NotificationRouter.instance.captureLaunch('granddad_ana');

      await pump(tester, [
        person(),
        person(uid: 'granddad', name: 'Granddad'),
      ]);
      await tester.pump();

      expect(NotificationRouter.instance.tappedLink.value, isNull,
          reason: 'consumed once shown, so a rebuild does not act on the same '
              'tap twice');
    });

    testWidgets('a payload for someone not in the list is ignored',
        (tester) async {
      // A revoked link, or a stale notification from a previous install. It
      // must not throw, and must not be consumed — nothing was shown.
      NotificationRouter.instance.captureLaunch('nobody_ana');

      await pump(tester, [person()]);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(NotificationRouter.instance.tappedLink.value, 'nobody_ana');
    });
  });
}
