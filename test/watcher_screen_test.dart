import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/watcher_reconcile_service.dart';
import 'package:i_am_ok/copy/notification_copy.dart';
import 'package:i_am_ok/copy/watcher_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/notification_router.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
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
    // The instant the offline-shaped messages interpolate. Null models a
    // decision made against a successful read, which is what makes a stored
    // offline outcome unrenderable.
    DateTime? unverifiedSince,
    // The day this decision is about. Defaults to `D`; passed explicitly only
    // by the midnight-rollover case, which is the one that needs two states to
    // disagree about what "yesterday" means.
    DayKey? day,
  }) =>
      WatchedPersonState(
        link: linkTo(uid, name, status: status),
        cache: cache,
        decision: WarningDecision(
          outcome: outcome,
          day: day ?? d,
          unverifiedSince: unverifiedSince,
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
    NotificationDelivery warningDelivery = NotificationDelivery.redundant,
    // Names of links this pass could not reconcile at all.
    List<String> unreconciled = const [],
    bool uses24Hour = true,
    // Pull-to-refresh, and the failed row's *Try again*.
    Future<void> Function()? onRefresh,
    // True by default, matching `WatcherState`'s own default: a pass that says
    // nothing about how it was triggered announces nothing, which is the silent
    // and safe answer. Only a foreground push passes false.
    bool userInitiated = true,
  }) async {
    tester.view.physicalSize = surface * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    addTearDown(NotificationRouter.instance.consume);
    await tester.pumpWidget(
      MaterialApp(
        // The palette the app actually ships, not Flutter's default. Every
        // colour assertion below is a claim about THESE colours.
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: WatcherBody(
                onRefresh: onRefresh,
                state: WatcherState(
                  people: people,
                  today: today,
                  watcherZone: TimeZones.location('Europe/Madrid'),
                  // `redundant` by default: the list being on screen is what
                  // produces it, and it is what every case here is except the
                  // ones about the banner.
                  warningDelivery: warningDelivery,
                  uses24Hour: uses24Hour,
                  unreconciled: [
                    for (final name in unreconciled)
                      linkTo(name.toLowerCase(), name),
                  ],
                  userInitiated: userInitiated,
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
      // The **whole** line, not `textContaining('This phone last checked')`.
      // That prefix passes for `10:00`, `10:00 am` and `Sunday 10:00` alike, so
      // it could not tell the row's format from the notification's — which is
      // exactly the drift the single `uses24Hour` source exists to prevent, and
      // it went unasserted while the source was being fixed.
      expect(
        find.text('This phone last checked Sunday 10:00.'),
        findsOneWidget,
        reason: '10:00 Europe/Madrid, dated by weekday because it is inside '
            'the week, and 24-hour because that is what was passed',
      );
    });

    testWidgets('a 12-hour device gets 12-hour times on the row too',
        (tester) async {
      // **The regression `WatcherState.uses24Hour` was introduced to prevent.**
      // The row read `MediaQuery` live while the reconcile read the cache, so the
      // row and the notification posted by the SAME reconcile could disagree
      // about the same instant — and the reader compares them directly.
      //
      // It has to be asserted here, because `flutter_test` defaults
      // `alwaysUse24HourFormat` to FALSE while every test passes
      // `uses24Hour: true`: restore the `MediaQuery` read and the row silently
      // renders `10:00 am` under a notification reading `10:00`, with the whole
      // suite green.
      await pump(
        tester,
        [
          person(
            cache: WatcherCache(
              lastConfirmedDay: d,
              lastReconcileAt: DateTime.utc(2026, 8, 16, 8),
            ),
          ),
        ],
        uses24Hour: false,
      );
      expect(
        find.text('This phone last checked Sunday 10:00 am.'),
        findsOneWidget,
      );
      expect(
        find.text('This phone last checked Sunday 10:00.'),
        findsNothing,
        reason: 'one source means the row cannot render the other format',
      );
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

    testWidgets('a stored OFFLINE warning is not rendered against a verified '
        'decision', (tester) async {
      // The 10:00 alarm could not reach the server, posted `warnOffline`, and
      // recorded it. The reader muted *Missed check-ins*. A later reconcile
      // succeeded online, decided `warnOnline`, and correctly did not update the
      // ledger because nothing could be delivered.
      //
      // Rendering the stored outcome against the new decision's values produced
      // "your phone has not been able to check even once" directly above "This
      // phone last checked Tuesday 10:14" — two adjacent lines contradicting
      // each other, one of them false about the device.
      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {d: WarningOutcome.warnOffline},
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
          // Verified now: no `unverifiedSince` for the offline clause to use.
          outcome: WarningOutcome.warnOnline,
        ),
      ], warningDelivery: NotificationDelivery.unavailable);

      expect(find.textContaining('has not been able to check even once'),
          findsNothing);
      expect(find.text('No check-in from Mum yesterday.'), findsOneWidget);
    });

    testWidgets('but a stored offline warning still stands while still offline',
        (tester) async {
      // The other half: when the decision DOES carry an instant, the stored
      // outcome is renderable and is what is showing in the tray.
      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {d: WarningOutcome.warnOffline},
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
          outcome: WarningOutcome.warnOffline,
          unverifiedSince: DateTime.utc(2026, 8, 17, 8, 14),
        ),
      ]);

      expect(find.textContaining('your phone has been offline since'),
          findsOneWidget);
    });

    testWidgets('a silent decision still reads Everything OK', (tester) async {
      // The other half. The fallback must not turn every empty ledger into a
      // warning — she checked in, and the row says so.
      await pump(tester, [person(cache: WatcherCache(lastConfirmedDay: d))]);

      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
    });
  });

  group('when this phone cannot warn at all', () {
    testWidgets('it says so, and offers the action', (tester) async {
      // **The screen is the only delivery there will ever be** in this state,
      // and nothing said so. The reader saw the warning on the row, dealt with
      // it, closed the app, and went on believing they would be told next time.
      //
      // §13 rates `POST_NOTIFICATIONS` revocation High because Android takes it
      // from apps nobody opens — which is the watcher by design. The watched
      // side has had this banner since Phase 2, where the cost is a missed
      // nudge; here the cost is a family not being warned.
      await pump(
        tester,
        [person(cache: WatcherCache(lastConfirmedDay: d))],
        warningDelivery: NotificationDelivery.unavailable,
      );

      expect(find.text(WatcherCopy.warningsOff), findsOneWidget);
      expect(find.text(WatcherCopy.warningsOffAction), findsOneWidget);
    });

    testWidgets('it does not tell the family member to ask a family member',
        (tester) async {
      // The dead-end wording belongs to the Tap screen, whose reader is 80.
      // Here the reader IS the person everyone else would be sent to.
      await pump(
        tester,
        [person()],
        warningDelivery: NotificationDelivery.unavailable,
      );
      expect(find.textContaining('Ask a family member'), findsNothing);
    });

    testWidgets('the action meets the 48dp floor', (tester) async {
      await pump(
        tester,
        [person()],
        warningDelivery: NotificationDelivery.unavailable,
      );
      final size = tester.getSize(find.widgetWithText(
          TextButton, WatcherCopy.warningsOffAction));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('and its label is legible against the banner it sits on',
        (tester) async {
      // A bare `TextButton` takes its foreground from `colorScheme.primary`,
      // which is measured against `surface` — not against the `errorContainer`
      // painted behind it. That pair measures **2.33:1 in light, 2.31:1 in
      // dark**, where the floor is 4.5, and raising `contrastLevel` for the
      // light palette's AAA misses pushed it further down rather than up.
      //
      // `contrast_test.dart` holds the ratio; this holds the wiring, because
      // the ratio is only reached if the widget actually asks for this colour.
      await pump(
        tester,
        [person()],
        warningDelivery: NotificationDelivery.unavailable,
      );

      final scheme = AppTheme.light.colorScheme;
      final button = tester.widget<TextButton>(find.widgetWithText(
          TextButton, WatcherCopy.warningsOffAction));
      expect(
        button.style?.foregroundColor?.resolve({}),
        scheme.onErrorContainer,
        reason: 'the pair the body text beside it already uses',
      );
      expect(
        button.style?.foregroundColor?.resolve({}),
        isNot(scheme.primary),
      );
    });

    testWidgets('nothing is shown when warnings work', (tester) async {
      await pump(tester, [person()]);
      expect(find.text(WatcherCopy.warningsOff), findsNothing);
    });

    testWidgets('redundant is not a fault — the reader is looking at it',
        (tester) async {
      // `redundant` means the list is on screen, which is the good case. A
      // banner there would call the app broken for working as designed.
      await pump(
        tester,
        [person()],
        warningDelivery: NotificationDelivery.redundant,
      );
      expect(find.text(WatcherCopy.warningsOff), findsNothing);
    });

    testWidgets('the rows are still readable beneath it', (tester) async {
      // The banner must not push the list out. It is the reason the reader
      // needs the rows more than usual, not less.
      await pump(
        tester,
        [person(cache: WatcherCache(lastConfirmedDay: d))],
        warningDelivery: NotificationDelivery.unavailable,
      );
      expect(find.text('Mum'), findsOneWidget);
      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
    });
  });

  group('a link this pass could not reconcile', () {
    testWidgets('is NOT rendered as "you are not looking after anyone"',
        (tester) async {
      // The per-link guard keeps one bad link from costing every other watched
      // person their check — but omitting it from the list made it invisible,
      // and with one link the list is then empty and says so. That is a
      // positive false claim on the screen the lost-access notification routes
      // to, and it is the revoked-row defect arriving by a new route.
      await pump(tester, const [], unreconciled: ['Mum']);

      expect(find.text(WatcherCopy.nobody), findsNothing);
      expect(find.text('Mum'), findsOneWidget);
    });

    testWidgets('says it is a fault in this phone, not a claim about her',
        (tester) async {
      // The app does not know whether she checked in — only that it could not
      // find out. ADR-0004's opening convention carries that distinction.
      await pump(tester, const [], unreconciled: ['Mum']);

      expect(find.text(WatcherCopy.couldNotCheckOn('Mum')), findsOneWidget);
      expect(find.textContaining('No check-in'), findsNothing);
    });

    testWidgets('names a next step rather than dead-ending', (tester) async {
      await pump(tester, const [], unreconciled: ['Mum']);
      expect(find.text(WatcherCopy.couldNotCheckRemedy), findsOneWidget);
    });

    testWidgets('does not claim the reader will not be warned', (tester) async {
      // The alarm may still be armed and the next fire may succeed. Saying
      // otherwise would overstate what this phone knows.
      await pump(tester, const [], unreconciled: ['Mum']);
      expect(find.text(WatcherCopy.accessLostConsequence('Mum')), findsNothing);
    });

    testWidgets('appears alongside the links that DID reconcile',
        (tester) async {
      await pump(
        tester,
        [person(cache: WatcherCache(lastConfirmedDay: d))],
        unreconciled: ['Granddad'],
      );

      expect(find.text(WatcherCopy.everythingOk), findsOneWidget);
      expect(find.text(WatcherCopy.couldNotCheckOn('Granddad')), findsOneWidget);
    });

    testWidgets('and the warnings-off banner still shows above it',
        (tester) async {
      // The `isEmpty` early return skipped the banner too, so a muted watcher
      // whose only link failed got neither the row nor the warning that they
      // will not be told next time.
      await pump(
        tester,
        const [],
        unreconciled: ['Mum'],
        warningDelivery: NotificationDelivery.unavailable,
      );

      expect(find.text(WatcherCopy.warningsOff), findsOneWidget);
      expect(find.text(WatcherCopy.couldNotCheckOn('Mum')), findsOneWidget);
    });

    testWidgets('never says "something went wrong"', (tester) async {
      // `guidelines.md`'s Floors table bans the phrase by name, and this row
      // shipped it verbatim — on the screen the *lost access* notification
      // promises will say what to do. Asserted as a property of the rendered
      // row rather than of the constant, so it also catches the phrase arriving
      // from any other string this row shows.
      await pump(tester, const [], unreconciled: ['Mum']);
      expect(find.textContaining('something went wrong'), findsNothing);
    });

    testWidgets('offers a control, not only a pull-to-refresh drag',
        (tester) async {
      // `guidelines.md`: no drag as the ONLY route to an action — and a drag is
      // what TalkBack is least able to perform, on a row whose entire content is
      // a fault. The whole-screen failure has had a button since it was written;
      // this row had nothing.
      var retried = 0;
      await pump(
        tester,
        const [],
        unreconciled: ['Mum'],
        onRefresh: () async => retried++,
      );

      await tester.tap(find.text(WatcherCopy.retry));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('and that control is reachable by a screen reader',
        (tester) async {
      // The row's text is collapsed into ONE utterance by a
      // `Semantics`/`ExcludeSemantics` pair — correct for text, fatal for a
      // control, which is why the button sits outside that pair. Inside it, the
      // button would be invisible to exactly the reader it was added for.
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const [],
        unreconciled: ['Mum'],
        onRefresh: () async {},
      );

      expect(
        tester.getSemantics(find.text(WatcherCopy.retry)),
        matchesSemantics(
          label: WatcherCopy.retry,
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('the row still speaks as one utterance', (tester) async {
      // The button moving outside the wrapper must not have split the text.
      final handle = tester.ensureSemantics();
      await pump(tester, const [], unreconciled: ['Mum']);

      expect(
        find.bySemanticsLabel(RegExp(
            r'Mum\..*could not finish checking.*ask whoever set up the app')),
        findsOneWidget,
      );
      handle.dispose();
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

    testWidgets('does NOT say when this phone last checked', (tester) async {
      // Alone among the row states. That line distinguishes *working* from
      // *stopped* for a force-stopped watcher whose rows all read "Everything
      // OK" — but nothing is working here by design, and the row has already
      // said so. What it would add is the suggestion that this phone still
      // checks on her periodically, frozen on the same Tuesday forever, because
      // a revoked link refuses every read and `lastReconcileAt` never advances.
      await pump(tester, [
        revoked(
          cache: WatcherCache(
            lastConfirmedDay: d,
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
        ),
      ]);
      expect(find.textContaining('This phone last checked'), findsNothing);
    });
  });

  group('the tapped row is found, not merely tinted', () {
    testWidgets('a row just past the fold is scrolled into view',
        (tester) async {
      // Colour alone fails the floor outright, and it also fails plainly: the
      // row a notification is about can be off screen, which is exactly when a
      // highlight is worth having. The data model supports many watched people
      // today even though Phase 7 owns the layout.
      //
      // **Scoped to a row the list has built.** `ensureVisible` needs a context,
      // and a lazy `ListView` never builds a row far down a long list — the
      // limitation is stated in `_onTapped` and belongs to Phase 7 with the
      // layout it serves. This asserts what the code actually delivers.
      final people = [
        for (var i = 0; i < 6; i++)
          person(
            uid: 'p$i',
            name: 'Person $i',
            cache: WatcherCache(
              accessLostSince: d,
              accessLostCause: RefusedCause.permissionDenied,
            ),
            outcome: WarningOutcome.warnAccessLost,
          ),
      ];
      NotificationRouter.instance.captureLaunch('p5_ana');

      await pump(tester, people, surface: const Size(400, 500));
      await tester.pumpAndSettle();

      expect(find.text('Person 5'), findsOneWidget,
          reason: 'the row the notification named must be on screen');
      expect(
        tester.getTopLeft(find.text('Person 5')).dy,
        lessThan(500),
        reason: 'and within the viewport, not merely built off-screen',
      );
    });

    testWidgets('the reader is told whose row it is', (tester) async {
      // Flutter cannot place the screen reader's cursor on an arbitrary widget,
      // so the announcement answers the question the tap actually asks: did
      // this land on the person the notification was about.
      //
      // **Asserted on the platform message, not on the copy constant.** This
      // test used to end at `expect(WatcherCopy.showingPerson('Mum'), 'Showing
      // Mum.')` — a string-equality check on a constant, which passes with the
      // entire `sendAnnouncement` call deleted. It was the only coverage of the
      // screen-reader half of the notification-tap path: the path that exists
      // for the reader who cannot see the highlight at all.
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility,
        (message) async {
          final event = message as Map<Object?, Object?>;
          if (event['type'] == 'announce') {
            final data = event['data'] as Map<Object?, Object?>;
            announcements.add(data['message'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
                SystemChannels.accessibility, null),
      );

      final handle = tester.ensureSemantics();
      NotificationRouter.instance.captureLaunch('mum_ana');

      await pump(tester, [person(), person(uid: 'gd', name: 'Granddad')]);
      await tester.pumpAndSettle();

      expect(announcements, ['Showing Mum.'],
          reason: 'the tapped person is named, once, and it is Mum rather than '
              'the first row in the list');
      handle.dispose();
    });
  });

  /// **A row that changes under a screen reader is announced** — `screens.md`,
  /// approved 2026-08-25.
  ///
  /// `NotificationDelivery.redundant` posts nothing and records the day as seen,
  /// on the argument that the list renders the change itself. That held while
  /// `redundant` was reached by **navigating** here. Phase 4 gave the list a
  /// second way to change — a foreground push, arriving while the reader is
  /// already on the screen — and nothing re-reads a changed widget. A sighted
  /// reader sees the row change; a TalkBack reader who heard *"Mum. No check-in
  /// from Mum yesterday."* thirty seconds ago is looking at *"Everything OK"*
  /// with no announcement, no reason to swipe back, and no notification ever
  /// coming, because the day is already recorded as seen.
  ///
  /// Every case here asserts on the **platform message**, never on the copy
  /// constant: a string-equality check against `WatcherCopy.checkedIn` passes
  /// with the whole `sendAnnouncement` call deleted, which is the mistake the
  /// notification-tap test above was fixed for.
  group('a row that changes while the reader is on it', () {
    List<String> announcementsOn(WidgetTester tester) {
      final spoken = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility,
        (message) async {
          final event = message as Map<Object?, Object?>;
          if (event['type'] == 'announce') {
            final data = event['data'] as Map<Object?, Object?>;
            spoken.add(data['message'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
                SystemChannels.accessibility, null),
      );
      return spoken;
    }

    /// The row a reader has just heard a warning about.
    WatchedPersonState warned({String uid = 'mum', String name = 'Mum'}) =>
        person(
          uid: uid,
          name: name,
          cache: WatcherCache(warningsShownFor: {d: WarningOutcome.warnOnline}),
          outcome: WarningOutcome.warnOnline,
        );

    /// The same row after a check-in for that day arrives.
    WatchedPersonState settled({String uid = 'mum', String name = 'Mum'}) =>
        person(uid: uid, name: name, cache: WatcherCache(lastConfirmedDay: d));

    testWidgets('the reader is told, in the approved words', (tester) async {
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [settled()], userInitiated: false);
      await tester.pumpAndSettle();

      expect(spoken, ['Mum checked in. Everything OK.']);
      handle.dispose();
    });

    testWidgets('a refresh the reader ASKED for says nothing', (tester) async {
      // The other half of the rule, and the reason it is a condition rather
      // than a blanket announcement. On a resume or a pull-to-refresh the
      // reader is arriving at the screen and will read the row themselves;
      // announcing every refresh talks over them.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [settled()]);
      await tester.pumpAndSettle();

      expect(spoken, isEmpty);
      handle.dispose();
    });

    testWidgets('an unsolicited pass that changed NOTHING says nothing',
        (tester) async {
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [warned()], userInitiated: false);
      await tester.pumpAndSettle();

      expect(spoken, isEmpty,
          reason: 'a push arrives for every check-in in the family, and most '
              'of them change nothing on this row');
      handle.dispose();
    });

    testWidgets('a warning that merely lapsed is NOT announced as a check-in',
        (tester) async {
      // The honesty case, and the reason the condition asks the cache rather
      // than the row. A `warnUnverifiableAway` stops being renderable the
      // moment a read succeeds — the away covers the day, so the decision is
      // silent and the row goes quiet — with `lastConfirmedDay` exactly where
      // it was. *"Mum checked in"* there is a claim about a person on a day she
      // was away and did not tap.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {d: WarningOutcome.warnUnverifiableAway},
            lastReconcileAt: DateTime.utc(2026, 8, 14, 10, 14),
          ),
          outcome: WarningOutcome.warnUnverifiableAway,
          unverifiedSince: DateTime.utc(2026, 8, 14, 10, 14),
        ),
      ]);
      expect(find.textContaining('Can\'t check on Mum'), findsOneWidget,
          reason: 'the premise — a warning really was standing');

      await pump(tester, [
        // The read succeeded and the away covers the day: nothing warns, and
        // nobody checked in **on the warned day**.
        //
        // **`WatcherCache.empty()` was too weak here**, and the test's own name
        // said why without noticing: an empty cache has no `lastConfirmedDay` at
        // all, so the null check alone was sufficient and the day comparison the
        // guard is actually about was never evaluated. Mutating it to
        // `return confirmed != null;` passed the entire suite.
        //
        // A stale-but-real check-in is the production shape: she tapped on the
        // 14th, went away on the 15th, the phone could not verify, and the read
        // now succeeds with the away covering the 16th. That is the case where
        // *"Mum checked in. Everything OK."* would be a fabricated claim about a
        // person, spoken to the reader least able to check it.
        person(cache: WatcherCache(lastConfirmedDay: DayKey(2026, 8, 14))),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.everythingOk), findsOneWidget,
          reason: 'the row really did go quiet');
      expect(spoken, isEmpty);
      handle.dispose();
    });

    testWidgets('only the person whose row changed is named', (tester) async {
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [
        warned(),
        warned(uid: 'gd', name: 'Granddad'),
      ]);
      await pump(tester, [
        settled(),
        warned(uid: 'gd', name: 'Granddad'),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(spoken, ['Mum checked in. Everything OK.'],
          reason: 'Granddad\'s warning is still true and still standing');
      handle.dispose();
    });

    // **The other direction — approved 2026-08-25.** Item 3 of the post-gate
    // review. A push reconciles with the list open, so the delivery is
    // `redundant`: nothing is posted and the day is recorded as SEEN. The row
    // worsens silently, the alarm later finds the day settled and says nothing,
    // and a screen-reader user is never told at all. `checkedInSince` loses a
    // retraction; this loses a **warning**, which is worse in kind.
    group('and the row that goes the other way', () {
      testWidgets('the warning body is spoken, verbatim', (tester) async {
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled()]);
        await pump(tester, [warned()], userInitiated: false);
        await tester.pumpAndSettle();

        // The row's own sentence, word for word — no *"Update."* prefix, and
        // the name not said twice. Asserted against the string the row renders,
        // so the two can never drift.
        expect(spoken, ['No check-in from Mum yesterday.']);
        expect(find.text('No check-in from Mum yesterday.'), findsOneWidget,
            reason: 'and it really is what the row says');
        handle.dispose();
      });

      testWidgets('the footer is NOT spoken with it', (tester) async {
        // *"This phone last checked Tuesday 10:14."* is a fact about this
        // device's own effort rather than a claim about her, and it is not what
        // changed. Speaking it would bury the claim behind a timestamp for the
        // one reader who cannot skim past it.
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled()]);
        await pump(tester, [
          person(
            cache: WatcherCache(
              warningsShownFor: {d: WarningOutcome.warnOnline},
              lastReconcileAt: DateTime.utc(2026, 8, 17, 10, 14),
            ),
            outcome: WarningOutcome.warnOnline,
          ),
        ], userInitiated: false);
        await tester.pumpAndSettle();

        expect(spoken, ['No check-in from Mum yesterday.']);
        expect(spoken.single, isNot(contains('last checked')));
        handle.dispose();
      });

      testWidgets('a refresh the reader ASKED for says nothing', (tester) async {
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled()]);
        await pump(tester, [warned()]);
        await tester.pumpAndSettle();

        expect(spoken, isEmpty);
        handle.dispose();
      });

      testWidgets('LOST ACCESS is still not announced by this route',
          (tester) async {
        // `screens.md` marks *any → lost access* as deliberately not shipping,
        // and it must not arrive by falling through the new branch. `rowKind`
        // is what keeps them apart: an access failure is `accessLost`, never
        // `warning`, so the guard cannot see it.
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled()]);
        await pump(tester, [
          person(
            cache: WatcherCache(
              accessLostSince: d,
              accessLostCause: RefusedCause.unauthenticated,
              lastConfirmedDay: d,
            ),
            outcome: WarningOutcome.warnAccessLost,
          ),
        ], userInitiated: false);
        await tester.pumpAndSettle();

        expect(find.text(WatcherCopy.accessLostLabel('Mum')), findsOneWidget,
            reason: 'the premise — the row really is the lost-access one now');
        expect(spoken, isEmpty);
        handle.dispose();
      });

      testWidgets('a row that was ALREADY warning is not re-announced',
          (tester) async {
        // A push arrives for every check-in in the family. Re-reading a standing
        // warning on each one is the fatigue that trains a reader to ignore the
        // channel this app cannot afford to have ignored.
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [warned()]);
        await pump(tester, [warned()], userInitiated: false);
        await tester.pumpAndSettle();

        expect(spoken, isEmpty);
        handle.dispose();
      });

      testWidgets('only the person whose row worsened is named', (tester) async {
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled(), settled(uid: 'gd', name: 'Granddad')]);
        await pump(tester, [
          settled(),
          warned(uid: 'gd', name: 'Granddad'),
        ], userInitiated: false);
        await tester.pumpAndSettle();

        expect(spoken, ['No check-in from Granddad yesterday.']);
        handle.dispose();
      });

      testWidgets('a mixed pass leads with the WARNING, not with the good news',
          (tester) async {
        // **Within one utterance the tail is what an interrupt takes.** This is
        // the same rule `screens.md` used to reject *"Update."* — the part most
        // likely to survive is not where the claim belongs — applied to the
        // order of two sentences rather than to the words inside one.
        //
        // Appended in `people` order, an improving row that sorts first pushed
        // the warning to the end. A blind watcher would hear that Mum is fine
        // and lose the sentence saying Granddad is not — with no notification
        // coming, because `redundant` already recorded the day as seen.
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        // Mum first in list order, and Mum is the one who IMPROVES.
        await pump(tester, [warned(), settled(uid: 'gd', name: 'Granddad')]);
        await pump(tester, [
          settled(),
          warned(uid: 'gd', name: 'Granddad'),
        ], userInitiated: false);
        await tester.pumpAndSettle();

        expect(spoken, [
          'No check-in from Granddad yesterday. Mum checked in. Everything OK.',
        ], reason: 'one utterance, and the loud half is at the front of it');
        handle.dispose();
      });

      testWidgets('the OFFLINE-shaped warning is spoken too, and in full',
          (tester) async {
        // `screens.md` promises *"whatever the row is rendering"*, which is
        // three outcomes rather than one. Only `warnOnline` was asserted, so the
        // approved-copy document claimed more than the suite checked.
        //
        // This one also proves the announcement carries the interpolated
        // instant: a body truncated at the em dash would still contain the
        // person's name and still pass a `contains` check on the first clause.
        final spoken = announcementsOn(tester);
        final handle = tester.ensureSemantics();

        await pump(tester, [settled()]);
        await pump(tester, [
          person(
            cache: WatcherCache(
              warningsShownFor: {d: WarningOutcome.warnOffline},
              lastReconcileAt: DateTime.utc(2026, 8, 16, 20, 10),
            ),
            outcome: WarningOutcome.warnOffline,
            unverifiedSince: DateTime.utc(2026, 8, 16, 20, 10),
          ),
        ], userInitiated: false);
        await tester.pumpAndSettle();

        expect(spoken, hasLength(1));
        expect(spoken.single, startsWith('No check-in received from Mum'),
            reason: 'the person is named in the first five words');
        expect(spoken.single, contains('offline'),
            reason: 'and the clause explaining WHY is not clipped off');
        expect(find.text(spoken.single), findsOneWidget,
            reason: 'and it is exactly what the row renders');
        handle.dispose();
      });
    });

    testWidgets('a warning becoming REVOKED is not announced', (tester) async {
      // `screens.md` names two more candidate strings and marks both as
      // deliberately not shipping. Neither may arrive by falling through this:
      // a revoked row says *"You are no longer looking after Mum."*, which is
      // not "checked in" and not "Everything OK", and announcing the approved
      // string over it would be a claim about a person the app can no longer
      // read anything about.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [
        person(
          status: LinkStatus.revoked,
          cache: WatcherCache(lastConfirmedDay: d),
        ),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.linkEnded('Mum')), findsOneWidget,
          reason: 'the premise — the row really did change to the revoked one');
      expect(spoken, isEmpty);
      handle.dispose();
    });

    testWidgets('a warning becoming LOST ACCESS is not announced',
        (tester) async {
      // The other unapproved candidate. ADR-0004's whole point is that this is
      // a claim about **us**, not about her — so *"Mum checked in"* would be
      // exactly the false claim the four-outcome split exists to prevent, said
      // to the reader least able to notice it is wrong.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [
        person(
          cache: WatcherCache(
            accessLostSince: d,
            accessLostCause: RefusedCause.unauthenticated,
            lastConfirmedDay: d,
          ),
          outcome: WarningOutcome.warnAccessLost,
        ),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.accessLostLabel('Mum')), findsOneWidget,
          reason: 'the premise — the row really is the lost-access one now');
      expect(spoken, isEmpty);
      handle.dispose();
    });

    testWidgets('a day rollover is not announced as a check-in', (tester) async {
      // Two unsolicited passes straddling a watched-local midnight. The warning
      // stood for `D`; the new pass is about `D + 1` and carries a check-in for
      // it, so a guard that only compared `lastConfirmedDay` against the OLD
      // day would fire — on a rollover rather than on a retraction, with `D`'s
      // warning still unretracted and merely hidden by the state-not-history
      // rule.
      //
      // Nothing false would be said, which is exactly why it is worth a test:
      // the failure is a true sentence spoken for the wrong reason, and the
      // reader it is spoken to cannot glance at the row to discount it.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(tester, [
        person(day: today, cache: WatcherCache(lastConfirmedDay: today)),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.everythingOk), findsOneWidget,
          reason: 'the row did go quiet — this is not a case of nothing '
              'happening');
      expect(spoken, isEmpty);
      handle.dispose();
    });

    testWidgets('two rows settling at once are ONE utterance', (tester) async {
      // **The first version sent one announcement per person**, which is the
      // shape most likely to lose one: the platform does not reliably queue
      // announcements, and the one dropped is the first — the oldest row, which
      // is the person the reader has been waiting longest to hear about.
      //
      // Joined rather than summarised, so every word stays approved copy. A
      // shorter *"Mum and Granddad checked in. Everything OK."* would be a new
      // string and needs the approval `screens.md` requires.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned(), warned(uid: 'gd', name: 'Granddad')]);
      await pump(tester, [
        settled(),
        settled(uid: 'gd', name: 'Granddad'),
      ], userInitiated: false);
      await tester.pumpAndSettle();

      expect(spoken, hasLength(1),
          reason: 'two announcements in one frame is how one of them is lost');
      expect(spoken.single,
          'Mum checked in. Everything OK. Granddad checked in. Everything OK.',
          reason: 'list order, which is the order the rows are read in');
      handle.dispose();
    });

    testWidgets('a link with no previous row is not announced', (tester) async {
      // Newly paired, or previously in `unreconciled`. There is no "before" for
      // it to have changed from, and reading its arrival as a change would
      // announce a row the reader has never heard.
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await pump(tester, [warned()]);
      await pump(
        tester,
        [warned(), settled(uid: 'gd', name: 'Granddad')],
        userInitiated: false,
      );
      await tester.pumpAndSettle();

      expect(spoken, isEmpty);
      handle.dispose();
    });
  });

  group('the last-checked line is never part of the alarm', () {
    testWidgets('it is not error-coloured beneath a warning', (tester) async {
      // Painting the whole row `error` swept this line up with the warning and
      // collapsed the distinction it exists to make: the warning is a claim
      // about HER, the last-checked line is a fact about THIS DEVICE. In red
      // beneath a warning it reads as part of the bad news.
      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {d: WarningOutcome.warnOnline},
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
          outcome: WarningOutcome.warnOnline,
        ),
      ]);

      final warning = find.text('No check-in from Mum yesterday.');
      final footer = find.textContaining('This phone last checked');
      final scheme = Theme.of(tester.element(warning)).colorScheme;

      expect(tester.widget<Text>(warning).style?.color, scheme.error,
          reason: 'the claim about her is emphasised');
      expect(tester.widget<Text>(footer).style?.color, isNot(scheme.error),
          reason: 'the fact about this device is not');
    });

    testWidgets('and TalkBack still gets it, since colour is invisible there',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, [
        person(
          cache: WatcherCache(
            warningsShownFor: {d: WarningOutcome.warnOnline},
            lastReconcileAt: DateTime.utc(2026, 8, 17, 8, 14),
          ),
          outcome: WarningOutcome.warnOnline,
        ),
      ]);

      expect(
        find.bySemanticsLabel(RegExp(r'Mum\..*This phone last checked')),
        findsOneWidget,
      );
      handle.dispose();
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
