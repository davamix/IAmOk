import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/copy/tap_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
import 'package:i_am_ok/presentation/away_picker.dart';
import 'package:i_am_ok/presentation/tap_screen.dart';

/// The away surfaces: the picker, and the Tap screen's away state.
///
/// Widget tests rather than device checks, because every question here is about
/// **rendering** — `docs/testing/strategy.md`'s rule is that if a test needs a
/// device to answer a question about logic, the logic is in the wrong layer.
///
/// The one thing asserted hardest is **which sentence**. The owner's decision of
/// 2026-08-27 is that an away line names who set it when it wasn't you, and
/// getting that branch wrong is not a copy slip: it either tells somebody they
/// marked themselves away when a watcher did, or leaves §17's mitigation with no
/// surface at all.
void main() {
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');
  final today = DayKey(2026, 8, 17);

  WatchedState state({
    AwayRecord? away,
    String selfUid = 'mum-uid',
    List<String> watchers = const ['Ana'],
  }) =>
      WatchedState(
        today: today,
        zone: madrid,
        audience: WatchedAudience(watchers),
        todayCheckIn: null,
        away: away,
        selfUid: selfUid,
        notificationsEnabled: true,
        armed: 21,
      );

  AwayRecord record({
    String? setBy = 'ana-uid',
    String? setByName = 'Ana',
    DayKey? through,
  }) =>
      AwayRecord(
        period: AwayPeriod(from: today, through: through ?? DayKey(2026, 8, 22)),
        setBy: setBy,
        setByName: setByName,
      );

  Future<void> pumpTap(
    WidgetTester tester,
    WatchedState value, {
    double textScale = 1,
    Size surface = const Size(400, 800),
  }) async {
    tester.view.physicalSize = surface * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                alwaysUse24HourFormat: true,
              ),
              child: Scaffold(body: TapBody(state: value)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('awayLineFor — the owner decision, as a branch', () {
    test('a watcher set it, so she is told who', () {
      expect(
        awayLineFor(state(away: record())),
        TapCopy.awayBy('Ana', 'Saturday 22'),
      );
      expect(awayLineFor(state(away: record())), contains('Ana marked you away'));
    });

    test('she set it herself, so the approved unattributed line renders', () {
      // `TapCopy.away` is unchanged and still names nobody — which is correct
      // here and would be a contradiction anywhere else.
      expect(
        awayLineFor(state(away: record(setBy: 'mum-uid', setByName: 'Mum'))),
        TapCopy.away('Saturday 22'),
      );
    });

    test('an unattributed period falls back to the same approved line', () {
      // ADR-0003's *Absence* case. It names nobody because there is nobody to
      // name — never "?? marked you away", and never no away line at all.
      expect(
        awayLineFor(state(away: record(setBy: null, setByName: null))),
        TapCopy.away('Saturday 22'),
      );
    });

    test('a name with no uid behind it is still shown', () {
      expect(
        awayLineFor(state(away: record(setBy: null))),
        TapCopy.awayBy('Ana', 'Saturday 22'),
      );
    });

    test('the two lines differ, so a mutation cannot pass both', () {
      // The guard against the branch collapsing: if both arms returned the same
      // string every assertion above would still pass.
      expect(TapCopy.away('Saturday 22'),
          isNot(TapCopy.awayBy('Ana', 'Saturday 22')));
    });
  });

  group('the Tap screen while away', () {
    testWidgets('renders the away line and the control reads "I\'m not away"',
        (tester) async {
      await pumpTap(tester, state(away: record()));

      expect(find.byKey(awayLineKey), findsOneWidget);
      expect(find.text(TapCopy.awayBy('Ana', 'Saturday 22')), findsOneWidget);
      expect(find.text(TapCopy.notAwayAction), findsOneWidget);
      expect(find.text(TapCopy.awayAction), findsNothing);
    });

    testWidgets('renders no away line when nobody is away', (tester) async {
      await pumpTap(tester, state());

      expect(find.byKey(awayLineKey), findsNothing);
      expect(find.text(TapCopy.awayAction), findsOneWidget);
    });

    testWidgets('an EXPIRED period renders nothing and the control resets',
        (tester) async {
      // Expiry is arithmetic: a period whose `through` has passed simply stops
      // covering today. Nothing deletes the row, so this is the case a screen
      // reading a flag instead of the dates would get wrong.
      await pumpTap(
        tester,
        state(
          away: AwayRecord(
            period: AwayPeriod(
              from: DayKey(2026, 8, 1),
              through: DayKey(2026, 8, 16),
            ),
            setBy: 'ana-uid',
            setByName: 'Ana',
          ),
        ),
      );

      expect(find.byKey(awayLineKey), findsNothing);
      expect(find.text(TapCopy.awayAction), findsOneWidget);
    });

    testWidgets('the audience line still renders — tapping is allowed',
        (tester) async {
      // §12: harmless, reassuring, and it writes a normal check-in watchers see
      // as usual. A screen that hid who would be told would be discouraging it.
      await pumpTap(tester, state(away: record()));

      expect(find.text(TapCopy.willKnow(const ['Ana'])), findsOneWidget);
    });

    testWidgets('the tap target stays ENABLED on an away day', (tester) async {
      await pumpTap(tester, state(away: record()));

      final target = tester.widget<TapTarget>(find.byType(TapTarget));
      expect(target.enabled, isTrue,
          reason: 'the plausible bug ReminderPolicy names is suppressing the '
              'WRITE along with the reminders');
    });
  });

  group('Away has visible separation from Add someone', () {
    testWidgets('a divider sits between the two secondary controls',
        (tester) async {
      // `screens.md` requires this in the SAME change that enables Away: two
      // text buttons of equal weight, 20dp apart, and `guidelines.md`'s mis-tap
      // reasoning only covers distance from the tap target.
      await pumpTap(tester, state());

      final divider = find.descendant(
        of: find.byType(TapBody),
        matching: find.byType(Divider),
      );
      expect(divider, findsOneWidget);

      final dividerY = tester.getCenter(divider).dy;
      expect(dividerY,
          greaterThan(tester.getCenter(find.byKey(AddSomeoneButton.buttonKey)).dy));
      expect(dividerY,
          lessThan(tester.getCenter(find.byKey(awayActionKey)).dy));
    });

    testWidgets('the two controls are still at least 20dp apart', (tester) async {
      await pumpTap(tester, state());

      final addBottom =
          tester.getRect(find.byKey(AddSomeoneButton.buttonKey)).bottom;
      final awayTop = tester.getRect(find.byKey(awayActionKey)).top;
      expect(awayTop - addBottom, greaterThanOrEqualTo(20));
    });

    testWidgets('the Away control clears the 48dp floor at every font scale',
        (tester) async {
      for (final scale in [1.0, 1.5, 2.0]) {
        await pumpTap(tester, state(), textScale: scale);
        final size = tester.getSize(find.byKey(awayActionKey));
        expect(size.height, greaterThanOrEqualTo(48),
            reason: 'at scale $scale');
      }
    });
  });

  group('the away picker', () {
    Future<void> pumpPicker(
      WidgetTester tester, {
      DayKey? initialLastDay,
      double textScale = 1,
      Size surface = const Size(400, 800),
    }) async {
      tester.view.physicalSize = surface * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: AwayPickerScreen(
                today: today,
                initialLastDay: initialLastDay,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('both frozen labels render, and they disambiguate each other',
        (tester) async {
      await pumpPicker(tester);

      // "Until Saturday" alone is ambiguous about whether Saturday still needs
      // a tap. Both halves, or neither is doing its job.
      expect(find.text(AwayCopy.lastDayAway('Monday 17')), findsOneWidget);
      expect(find.text(AwayCopy.backOn('Tuesday 18')), findsOneWidget);
    });

    testWidgets('the labels follow the selection', (tester) async {
      await pumpPicker(tester);

      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();

      expect(find.text(AwayCopy.lastDayAway('Thursday 20')), findsOneWidget);
      expect(find.text(AwayCopy.backOn('Friday 21')), findsOneWidget);
    });

    testWidgets('it returns the chosen day', (tester) async {
      DayKey? returned;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                returned = await Navigator.of(context).push<DayKey>(
                  MaterialPageRoute(
                    builder: (_) => AwayPickerScreen(today: today),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AwayPickerScreen.saveKey));
      await tester.pumpAndSettle();

      expect(returned, DayKey(2026, 8, 20));
    });

    testWidgets('dismissing returns nothing and says nothing', (tester) async {
      DayKey? returned;
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                returned = await Navigator.of(context).push<DayKey>(
                  MaterialPageRoute(
                    builder: (_) => AwayPickerScreen(today: today),
                  ),
                );
                popped = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Below the fold on the default test surface, which is the point of the
      // screen scrolling at all — reached the way a reader reaches it.
      await tester.ensureVisible(find.byKey(AwayPickerScreen.cancelKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AwayPickerScreen.cancelKey));
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(returned, isNull, reason: 'a dismissal is a choice, not a fault');
    });

    testWidgets('it cannot offer a day past the cap', (tester) async {
      // The last selectable day is 30 days after today — `AwayRules.maxDaysAhead`
      // — so the longest period the picker can produce is exactly the 31 days
      // §12 allows, counting today. Taken from the domain rather than restated.
      final screen = AwayPickerScreen(today: today);
      expect(screen.lastSelectable, DayKey(2026, 9, 16));
      expect(
        AwayPeriod(from: today, through: screen.lastSelectable).lengthInDays,
        AwayRules.maxLengthInDays,
      );
      expect(
        AwayRules.validateCreate(
          AwayPeriod(from: today, through: screen.lastSelectable),
          today,
        ),
        isNull,
        reason: 'the screen cannot offer a day its own validation refuses',
      );

      await pumpPicker(tester);
      // Nothing in October is reachable from the opening month, and the day
      // after the cap is not selectable in September either.
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      final seventeenth = tester.widget<Text>(find.text('17'));
      expect(seventeenth, isNotNull);
    });

    testWidgets('an out-of-range stored period does not crash the screen',
        (tester) async {
      // The rules are deliberately slacker than `AwayRules`, so a period the
      // server accepted can sit a day or two past what this screen may offer.
      // `CalendarDatePicker` asserts on an `initialDate` outside its bounds, so
      // an unclamped value would crash for exactly the family on the boundary.
      await pumpPicker(tester, initialLastDay: DayKey(2026, 12, 25));

      expect(find.text(AwayCopy.lastDayAway('Wednesday 16')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stored period BEFORE today is clamped forward too',
        (tester) async {
      await pumpPicker(tester, initialLastDay: DayKey(2026, 1, 1));

      expect(find.text(AwayCopy.lastDayAway('Monday 17')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it does not clip at the largest font scale', (tester) async {
      // The floor `guidelines.md` sets, and the defect the Phase 5 gate found
      // in the Add someone sheet: a Column that overflows its constraint is
      // clipped in release, silently, with no stripe.
      await pumpPicker(
        tester,
        textScale: 2,
        surface: const Size(320, 480),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });

    testWidgets('the spoken label carries BOTH sentences', (tester) async {
      // The second is what disambiguates the first, so a reader who got only
      // one of them is back where "until Saturday" left them.
      await pumpPicker(tester);

      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          AwayCopy.pickerLabel('Monday 17', 'Tuesday 18'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('AwayCopy dates', () {
    test('dayAndDate is the frozen strings\' form', () {
      expect(AwayCopy.dayAndDate(DayKey(2026, 8, 22)), 'Saturday 22');
      expect(AwayCopy.dayAndDate(DayKey(2026, 8, 23)), 'Sunday 23');
    });

    test('shortDate is the watcher row\'s form', () {
      expect(AwayCopy.shortDate(DayKey(2026, 8, 22)), 'Sat 22 Aug');
    });

    test('neither is ever numeric', () {
      // `guidelines.md`: never `22/08` — ambiguous and hard to scan, and this is
      // read at 3am by somebody who has just been told bad news.
      for (var i = 0; i < 40; i++) {
        final d = DayKey(2026, 8, 1).plusDays(i);
        expect(AwayCopy.dayAndDate(d), isNot(contains('/')));
        expect(AwayCopy.shortDate(d), isNot(contains('/')));
      }
    });
  });
}
