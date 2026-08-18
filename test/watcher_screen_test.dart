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

  Link linkTo(String watchedUid, String name,
          {LinkStatus status = LinkStatus.accepted}) =>
      Link(
        watchedUid: watchedUid,
        watcherUid: 'ana',
        status: status,
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
    LinkStatus status = LinkStatus.accepted,
  }) =>
      WatchedPersonState(
        link: linkTo(uid, name, status: status),
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
                state: WatcherState(
                  people: people,
                  today: today,
                  watcherZone: TimeZones.location('Europe/Madrid'),
                ),
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

    testWidgets('an OLDER unresolved warning is history, not status',
        (tester) async {
      // The regression both reviewers found independently, and the one this
      // getter's own docstring already forbade. `warningsShownFor` loses a day
      // only to a correction for THAT day or to revocation, so a genuinely
      // missed day stays in it forever. The first version fell back to the
      // newest day in the map, so Mum missing 1 August and tapping every day
      // since produced "No check-in from Mum yesterday." on the 18th — a false
      // claim about a specific day, to a family, permanently.
      //
      // Every string in the set says "yesterday", and only `decision.day` is
      // yesterday, so only `decision.day` can be rendered honestly.
      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {DayKey(2026, 8, 1): WarningOutcome.warnOnline},
            lastConfirmedDay: d,
          ),
        ),
      ]);
      expect(find.textContaining('No check-in'), findsNothing);
      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
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

  group('the surface half of "accept, prevent and surface"', () {
    // A force-stopped watcher goes deaf with the row still reading "Everything
    // OK" — true of the last thing this phone read, and silent about whether it
    // has read anything since. This line is the only thing that distinguishes
    // WORKING from STOPPED before §13's panel arrives in Phase 7, so it is on
    // every row rather than only the unhealthy ones.
    testWidgets('every row says when this phone last checked', (tester) async {
      final checkedAt = DateTime.utc(2026, 8, 16, 8);
      await pump(tester, [
        person(
          cache: WatcherCache(
            lastConfirmedDay: d,
            lastReconcileAt: checkedAt,
          ),
        ),
      ]);
      expect(find.textContaining('This phone last checked'), findsOneWidget);
    });

    testWidgets('a row that has never checked says so, not a null',
        (tester) async {
      await pump(tester, [person()]);
      expect(find.text(WatcherCopy.neverChecked), findsOneWidget);
    });

    testWidgets('it is present on an unhealthy row too', (tester) async {
      // The row that matters most: lost access AND a stalled phone are
      // different faults, and a reader needs to tell them apart.
      await pump(tester, [
        person(
          cache: WatcherCache(
            accessLostSince: d,
            accessLostCause: RefusedCause.unauthenticated,
            lastReconcileAt: DateTime.utc(2026, 8, 16, 8),
          ),
          outcome: WarningOutcome.warnAccessLost,
        ),
      ]);
      expect(find.textContaining('This phone last checked'), findsOneWidget);
      expect(find.text('Sign in again.'), findsOneWidget);
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

  group('a phone that cannot post still shows the warning on screen', () {
    testWidgets('the row does NOT say Everything OK when the day is warned',
        (tester) async {
      // **`warningsShownFor` is a delivery ledger, not a status field.** It is
      // written only when something was actually delivered, so on a phone with
      // *Missed check-ins* switched off — or `POST_NOTIFICATIONS` auto-revoked
      // from an app nobody opens, which §13 rates High because that describes a
      // watcher — the day is correctly not recorded and the row found nothing
      // standing.
      //
      // It then rendered "Everything OK" about a relative who missed yesterday,
      // on the one surface that watcher still had. A muted phone is exactly the
      // phone whose screen has to carry the whole message.
      await pump(tester, [
        person(
          cache: WatcherCache(lastConfirmedDay: DayKey(2026, 8, 14)),
          outcome: WarningOutcome.warnOnline,
        ),
      ]);

      expect(find.text(WatcherCopy.everythingOk), findsNothing);
      expect(find.text('No check-in from Mum yesterday.'), findsOneWidget);
    });

    testWidgets('and it says which of the four messages it is', (tester) async {
      // Not a generic "something is wrong". §10's four outcomes are a
      // correctness requirement rather than copy polish, and the row reuses the
      // notification's own sentence so the two cannot disagree.
      await pump(tester, [
        person(
          cache: const WatcherCache.empty(),
          outcome: WarningOutcome.warnOffline,
        ),
      ]);

      expect(find.textContaining('No check-in received from Mum yesterday'),
          findsOneWidget);
    });

    testWidgets('a silent decision still reads Everything OK', (tester) async {
      // The other half. The fallback must not turn every empty ledger into a
      // warning — she checked in, and the row says so.
      await pump(tester, [person(cache: WatcherCache(lastConfirmedDay: d))]);

      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
    });
  });

  group('the revoked row', () {
    WatchedPersonState revoked({WatcherCache? cache}) => person(
          status: LinkStatus.revoked,
          cache: cache ?? WatcherCache(lastConfirmedDay: d),
        );

    testWidgets('does NOT say Everything OK', (tester) async {
      // What it said before. A revoked link arms no alarms, will never warn,
      // and every read it makes is refused — and the row answered "Everything
      // OK" in two words. The flattest false all-clear this screen can produce,
      // reached by falling through every branch rather than by any decision.
      await pump(tester, [revoked()]);
      expect(find.text(WatcherCopy.everythingOk), findsNothing);
    });

    testWidgets('says the link ended, and what that costs', (tester) async {
      await pump(tester, [revoked()]);
      expect(find.text(WatcherCopy.linkEnded('Mum')), findsOneWidget);
      expect(
          find.text(WatcherCopy.accessLostConsequence('Mum')), findsOneWidget);
    });

    testWidgets('outranks the lost-access row', (tester) async {
      // A revoked link makes every later read refused BY DEFINITION, so the
      // access branch fires too. Leading with it would send the reader off to
      // sign in again and repair a permission fault that does not exist. §10
      // step 1 puts a non-accepted link first for the same reason.
      await pump(tester, [
        revoked(
          cache: WatcherCache(
            accessLostSince: d,
            accessLostCause: RefusedCause.permissionDenied,
          ),
        ),
      ]);
      expect(find.text(WatcherCopy.linkEnded('Mum')), findsOneWidget);
      expect(find.text(WatcherCopy.accessLostLabel('Mum')), findsNothing);
      expect(find.textContaining('ask whoever set up the app'), findsNothing);
    });

    testWidgets('outranks a warning left standing at revocation',
        (tester) async {
      await pump(tester, [
        revoked(cache: WatcherCache(
          warningsShownFor: {d: WarningOutcome.warnOnline},
        )),
      ]);
      expect(find.text('No check-in from Mum yesterday.'), findsNothing);
    });

    testWidgets('is not styled as an error', (tester) async {
      // A settled state, not bad news about her. "Quiet confirm, loud miss"
      // keeps alarm styling for a miss, and the words carry it regardless —
      // colour is never the only signal.
      await pump(tester, [revoked()]);
      final finder = find.text(WatcherCopy.linkEnded('Mum'));
      final context = tester.element(finder);
      expect(tester.widget<Text>(finder).style?.color,
          isNot(Theme.of(context).colorScheme.error));
    });

    testWidgets('still says when this phone last checked', (tester) async {
      await pump(tester, [
        revoked(
          cache: WatcherCache(
            lastConfirmedDay: d,
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
        ),
      ]);
      expect(find.textContaining('This phone last checked'), findsOneWidget);
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

    testWidgets('the largest system font scale really does enlarge the row',
        (tester) async {
      // Set by exactly the people this app is for, and the longest row in the
      // app — four lines, one of them a full remediation sentence.
      //
      // **`takeException()` was the whole of this assertion, and it cannot
      // fail here.** These rows live in a `ListView`, which hands its children
      // unbounded height, and `Text` wraps rather than overflowing. So there is
      // no `RenderFlex` to overflow in either axis: the check passed at every
      // scale, including scales the row does not actually honour. Phase 2 hit
      // the same trap on the Tap screen.
      //
      // What can actually go wrong is the opposite failure — a hard-coded
      // `fontSize`, a `TextScaler.noScaling`, or a fixed-height box — where the
      // row silently ignores the setting and stays unreadable. That is invisible
      // to an overflow check and is what these assertions measure instead.
      final row = [
        person(
          cache: WatcherCache(
            accessLostSince: d,
            accessLostCause: RefusedCause.permissionDenied,
          ),
          outcome: WarningOutcome.warnAccessLost,
        ),
      ];
      final line = find.text(WatcherCopy.accessLostRemedy(
          RefusedCause.permissionDenied));
      const surface = Size(320, 640);

      await pump(tester, row, surface: surface);
      final atOne = tester.getSize(line);

      await pump(tester, row, textScale: 2, surface: surface);
      final atTwo = tester.getSize(line);

      expect(atTwo.height, greaterThan(atOne.height),
          reason: 'the text must grow with the system setting, not ignore it');
      expect(atTwo.width, lessThanOrEqualTo(surface.width),
          reason: 'and wrap inside the screen rather than run off it');

      // Every line still rendered — growing the text must not push one out.
      expect(find.text(WatcherCopy.accessLostLabel('Mum')), findsOneWidget);
      expect(
          find.text(WatcherCopy.accessLostConsequence('Mum')), findsOneWidget);
      expect(line, findsOneWidget);
      expect(find.text(WatcherCopy.neverChecked), findsOneWidget);
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
