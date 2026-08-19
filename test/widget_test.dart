import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/copy/tap_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
import 'package:i_am_ok/presentation/tap_screen.dart';

/// The Tap screen's states.
///
/// A widget test rather than a device check, because every one of these is a
/// question about *rendering* rather than about the platform — and
/// `docs/testing/strategy.md`'s rule is that if a test needs a device to answer
/// a question about logic, the logic is in the wrong layer.
void main() {
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');
  final today = DayKey(2026, 8, 17);

  /// 07:14 in Madrid, expressed as the UTC instant the store would hand back.
  final tappedAt = DateTime.utc(2026, 8, 17, 5, 14);

  CheckIn checkInAt({String zone = 'Europe/Madrid'}) => CheckIn(
        day: today,
        deviceTappedAt: tappedAt,
        timezone: zone,
      );

  WatchedState state({
    List<String> watchers = const [],
    CheckIn? checkIn,
    bool notificationsEnabled = true,
    bool tapFailed = false,
  }) =>
      WatchedState(
        today: today,
        zone: madrid,
        audience: WatchedAudience(watchers),
        todayCheckIn: checkIn,
        away: null,
        notificationsEnabled: notificationsEnabled,
        armed: 21,
        tapFailed: tapFailed,
      );

  Future<void> pump(
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
          // `copyWith` on the inherited data, never a fresh `MediaQueryData`:
          // constructing one wholesale zeroes `size`, which silently collapses
          // the tap target to a diameter of 0 and makes every layout assertion
          // below meaningless while still passing some of them.
          //
          // `alwaysUse24HourFormat` is pinned so the time assertions are
          // deterministic. The app itself honours the device setting — that is
          // the requirement — and this fixes the setting rather than the app.
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
  }

  group('the tap target', () {
    testWidgets('is enabled and says what to tap before a tap', (tester) async {
      await pump(tester, state());
      expect(find.text(TapCopy.tapTarget), findsOneWidget);
      expect(tester.widget<InkWell>(find.byType(InkWell).first).onTap,
          isNotNull);
    });

    testWidgets('is DISABLED for the rest of the day once tapped',
        (tester) async {
      // The write is idempotent, so this is for the person rather than the
      // data: someone who cannot remember whether they tapped will tap again
      // and worry. The screen answering that question is the whole point.
      await pump(tester, state(checkIn: checkInAt()));
      expect(tester.widget<InkWell>(find.byType(InkWell).first).onTap, isNull);
    });

    testWidgets('changes its CONTENT when tapped, not only its colour',
        (tester) async {
      // Colour is never the only signal. Previously the circle kept saying
      // "I'm OK" and went grey, so the answer to "did I tap?" lived in small
      // text at the far bottom of the screen — she looks at the circle, sees
      // the same two words, taps, gets nothing, and worries.
      await pump(tester, state());
      expect(find.text(TapCopy.tapTarget), findsOneWidget);
      expect(find.text(TapCopy.tapTargetDone), findsNothing);

      await pump(tester, state(checkIn: checkInAt()));
      expect(find.text(TapCopy.tapTargetDone), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('confirms the tap with the exact time it happened',
        (tester) async {
      await pump(tester, state(checkIn: checkInAt()));
      expect(find.text(TapCopy.alreadyTapped('07:14')), findsOneWidget);
    });

    testWidgets('renders the time in the zone the tap was MADE in',
        (tester) async {
      // `CheckIn.timezone` records that zone precisely so this is not inferred
      // from wherever the phone happens to be now. Reading the device's current
      // zone shows a wall-clock time she never saw after a flight, on the one
      // line whose whole job is to be believed.
      await pump(tester, state(checkIn: checkInAt(zone: 'Pacific/Auckland')));
      expect(find.text(TapCopy.alreadyTapped('17:14')), findsOneWidget,
          reason: '05:14 UTC is 17:14 in Auckland, not 07:14 in Madrid');
    });

    testWidgets('does not move between the two states', (tester) async {
      // Muscle memory is the feature; a layout that reflows is a bug. The
      // centre must not depend on whether today's tap has happened, nor on how
      // many watchers there are.
      await pump(tester, state(watchers: ['Ana']));
      final untapped = tester.getCenter(find.byKey(TapTarget.targetKey));

      await pump(
        tester,
        state(watchers: ['Ana', 'Beto', 'Carmen'], checkIn: checkInAt()),
      );
      expect(tester.getCenter(find.byKey(TapTarget.targetKey)), untapped);
    });

    testWidgets('does not move when the notifications banner appears',
        (tester) async {
      await pump(tester, state(watchers: ['Ana']));
      final without = tester.getCenter(find.byKey(TapTarget.targetKey));

      await pump(
        tester,
        state(watchers: ['Ana'], notificationsEnabled: false),
      );
      expect(tester.getCenter(find.byKey(TapTarget.targetKey)), without);
    });

    testWidgets('is far beyond the 48dp Material minimum', (tester) async {
      await pump(tester, state());
      final size = tester.getSize(find.byKey(TapTarget.targetKey));
      expect(size.width, greaterThan(200));
      expect(size.height, greaterThan(200));
    });
  });

  group('accessibility', () {
    testWidgets('TalkBack can ACTIVATE the target, not merely read it',
        (tester) async {
      // `Semantics` wrapping an `ExcludeSemantics` strips the InkWell's
      // SemanticsAction.tap, leaving a node that is labelled and flagged as an
      // enabled button but cannot be activated — TalkBack announces the app's
      // one action and then double-tap does nothing. A label lookup cannot see
      // the difference, which is why this asserts the action.
      final handle = tester.ensureSemantics();
      await pump(tester, state());

      expect(
        tester.getSemantics(find.byKey(TapTarget.targetKey)),
        matchesSemantics(
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          label: TapCopy.tapTargetLabel,
        ),
      );
      handle.dispose();
    });

    testWidgets('the spoken label claims nothing about who will hear it',
        (tester) async {
      // With an empty audience the next line on the same screen says nobody is
      // set up. A label asserting "tell your family" contradicts it, and the
      // reader who depends on the label cannot see the contradiction.
      final handle = tester.ensureSemantics();
      await pump(tester, state());
      expect(TapCopy.tapTargetLabel.toLowerCase(), isNot(contains('family')));
      expect(find.bySemanticsLabel(TapCopy.tapTargetLabel), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the spoken label carries the time once tapped',
        (tester) async {
      // A screen-reader user gets what a sighted user gets, not a vaguer
      // version of it.
      final handle = tester.ensureSemantics();
      await pump(tester, state(checkIn: checkInAt()));
      // Asserted on the target's own node. The visible confirmation line
      // carries the same words, so a bare label lookup finds two.
      expect(
        tester.getSemantics(find.byKey(TapTarget.targetKey)),
        matchesSemantics(
          isButton: true,
          hasEnabledState: true,
          label: TapCopy.alreadyTapped('07:14'),
        ),
      );
      handle.dispose();
    });

    testWidgets('the text NEVER overlaps the tap target', (tester) async {
      // The guard the old font-scale test could not be. A Stack with
      // `Positioned` children never reports overflow, so `takeException()` was
      // null while the text was painted on top of the circle — unreadable, and
      // absorbing her taps because a paragraph hit-tests true.
      //
      // Every combination that grows the bottom band, at the largest system
      // font scale, on a small screen.
      for (final value in [
        state(watchers: ['Ana', 'Beto', 'Carmen'], checkIn: checkInAt()),
        state(notificationsEnabled: false, checkIn: checkInAt()),
        state(watchers: ['Ana'], checkIn: checkInAt(), tapFailed: true),
        state(),
      ]) {
        await pump(tester, value, textScale: 2, surface: const Size(320, 480));
        final target = tester.getRect(find.byKey(TapTarget.targetKey));

        // Everything EXCEPT the target's own label, which is inside it by
        // design and is what the tapped-state content change relies on.
        final outside = find.descendant(
          of: find.byType(TapBody),
          matching: find.byType(Text),
          matchRoot: false,
        );
        for (final element in outside.evaluate()) {
          if (find
              .descendant(of: find.byType(TapTarget), matching: find.byWidget(element.widget))
              .evaluate()
              .isNotEmpty) {
            continue;
          }
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(target.overlaps(rect), isFalse,
              reason: '"${(element.widget as Text).data}" is drawn over the '
                  'tap target at 2x font scale');
        }
      }
    });

    testWidgets('survives the largest font scale in landscape too',
        (tester) async {
      // The shortest side is the HEIGHT in landscape, so a target sized from it
      // fills most of the window and the band has nowhere to go.
      await pump(
        tester,
        state(watchers: ['Ana', 'Beto'], checkIn: checkInAt()),
        textScale: 2,
        surface: const Size(800, 360),
      );
      final target = tester.getRect(find.byKey(TapTarget.targetKey));
      final audience = tester.getRect(find.text(TapCopy.willKnow(['Ana', 'Beto'])));
      expect(target.overlaps(audience), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('who will be notified — and nothing else', () {
    testWidgets('names one watcher', (tester) async {
      await pump(tester, state(watchers: ['Ana']));
      expect(find.text("Ana will know you're OK."), findsOneWidget);
    });

    testWidgets('names two', (tester) async {
      await pump(tester, state(watchers: ['Ana', 'Beto']));
      expect(find.text("Ana and Beto will know you're OK."), findsOneWidget);
    });

    testWidgets('names three', (tester) async {
      await pump(tester, state(watchers: ['Ana', 'Beto', 'Carmen']));
      expect(find.text("Ana, Beto and Carmen will know you're OK."),
          findsOneWidget);
    });

    testWidgets('the empty case shows the settled static line', (tester) async {
      await pump(tester, state());
      expect(find.text(TapCopy.nobodyYet), findsOneWidget);
    });

    test('the empty line claims no history', () {
      // "yet" asserts *not started*, which is false after the last watcher
      // revokes — something was set up and is not any more. The line has to be
      // true in both states, because it is deliberately the same line in both.
      //
      // A plain `test`, not `testWidgets`: this is a claim about the string, and
      // the harness was pumping a whole widget tree that no assertion looked at.
      // A rendering test that renders nothing it checks implies coverage it does
      // not have.
      expect(TapCopy.nobodyYet.toLowerCase(), isNot(contains('yet')));
    });

    testWidgets('says nothing about anyone STARTING or STOPPING watching',
        (tester) async {
      // The explicitly-rejected list from the Phase 1 gate. Asserted rather
      // than reviewed, because the natural instinct on seeing an empty audience
      // is to explain it — and explaining it is the thing the decision forbids.
      for (final value in [state(), state(watchers: ['Ana'])]) {
        await pump(tester, value);
        for (final forbidden in [
          'started watching',
          'stopped watching',
          'no longer watching',
          'nobody is watching',
          'no one is watching',
        ]) {
          expect(find.textContaining(forbidden, findRichText: true), findsNothing,
              reason: '"$forbidden" is on the rejected list');
        }
      }
    });

    testWidgets('the empty line is styled as ordinary secondary text',
        (tester) async {
      // Asserted POSITIVELY. Excluding only `colorScheme.error` would still
      // admit errorContainer or a red literal, and styling it as a warning
      // reintroduces the rejected message by appearance rather than wording.
      await pump(tester, state());
      final context = tester.element(find.text(TapCopy.nobodyYet));
      final text = tester.widget<Text>(find.text(TapCopy.nobodyYet));
      expect(text.style?.color, Theme.of(context).colorScheme.onSurfaceVariant);
    });
  });

  group('notifications revoked', () {
    testWidgets('says what stops working and offers the action',
        (tester) async {
      await pump(tester, state(notificationsEnabled: false));
      expect(find.text(TapCopy.notificationsOff), findsOneWidget);
      expect(find.text(TapCopy.notificationsOffAction), findsOneWidget);
    });

    testWidgets('and the action is legible against the banner it sits on',
        (tester) async {
      // A bare `TextButton` takes its label colour from `colorScheme.primary`,
      // measured against `surface` — not against the `errorContainer` behind it.
      // That pair is **2.33:1 in light and 2.31:1 in dark**, against a floor of
      // 4.5, and it got worse rather than better when `contrastLevel` was raised
      // to fix the light palette's AAA misses: `errorContainer` darkens with the
      // level, `primary` does not move.
      //
      // This is the one control that turns reminders back on, for a reader who
      // is 80, inside the banner that exists because they are off.
      await pump(tester, state(notificationsEnabled: false));

      final scheme = AppTheme.light.colorScheme;
      final button = tester.widget<TextButton>(find.widgetWithText(
          TextButton, TapCopy.notificationsOffAction));
      expect(
        button.style?.foregroundColor?.resolve({}),
        scheme.onErrorContainer,
      );
    });

    testWidgets('nothing is shown while notifications work', (tester) async {
      await pump(tester, state());
      expect(find.text(TapCopy.notificationsOff), findsNothing);
    });

    test('claims nothing about who is watching', () {
      // It is about her own reminders. If it strayed into the audience's
      // territory it would collide with Decision 2 on the same screen.
      //
      // A plain `test` for the same reason as the empty-line one above: every
      // assertion here is about the constant, and the pump it used to do was
      // decorative.
      for (final forbidden in ['watch', 'family will', 'nobody']) {
        expect(TapCopy.notificationsOff.toLowerCase(), isNot(contains(forbidden)));
      }
    });
  });

  group('a failed tap', () {
    testWidgets('keeps the target on screen and enabled', (tester) async {
      // Replacing the whole screen at the moment she taps takes her one action
      // away, and the full-screen message would claim the phone could not get
      // ready — which is not what happened.
      await pump(tester, state(tapFailed: true));
      expect(find.byKey(TapTarget.targetKey), findsOneWidget);
      expect(tester.widget<InkWell>(find.byType(InkWell).first).onTap,
          isNotNull);
    });

    testWidgets('says what happened and what to do', (tester) async {
      await pump(tester, state(tapFailed: true));
      expect(find.text(TapCopy.tapFailed), findsOneWidget);
    });

    testWidgets('is absent on the happy path', (tester) async {
      await pump(tester, state());
      expect(find.text(TapCopy.tapFailed), findsNothing);
    });
  });

  group('the away control', () {
    testWidgets('is present, secondary, and not adjacent to the target',
        (tester) async {
      await pump(tester, state(watchers: ['Ana']));
      final away = find.ancestor(
        of: find.text(TapCopy.awayAction),
        matching: find.byType(TextButton),
      );
      expect(away, findsOneWidget);

      // Measured against the BUTTON's rect, not the text's — the text is inset
      // inside the button, which flattered the gap by ~12dp each side.
      final targetBottom = tester.getRect(find.byKey(TapTarget.targetKey)).bottom;
      final awayTop = tester.getRect(away).top;
      expect(awayTop - targetBottom, greaterThan(48));
    });

    testWidgets('meets the 48dp floor', (tester) async {
      await pump(tester, state());
      final away = find.ancestor(
        of: find.text(TapCopy.awayAction),
        matching: find.byType(TextButton),
      );
      expect(tester.getSize(away).height, greaterThanOrEqualTo(48));
    });
  });
}
