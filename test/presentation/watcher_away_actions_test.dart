import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/application/watcher_reconcile_service.dart';
import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/copy/watcher_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/presentation/app_theme.dart';
import 'package:i_am_ok/presentation/away_picker.dart';
import 'package:i_am_ok/presentation/watcher_screen.dart';

/// The watcher row's two away **actions**, as opposed to how it reads.
///
/// `watcher_screen_test.dart` covers the row's rendering and never presses
/// anything, because pressing needs a `ProviderScope` and a notifier. Two owner
/// decisions of 2026-09-01 live entirely in what a press does, so they need the
/// scope:
///
/// * **Ending asks first, and only here.** The Tap screen's *"I'm not away"* has
///   no confirmation, on the argument that the failure is loud and setting it
///   again is two taps. Neither half transfers: ending **truncates**, so a
///   mis-tap on day 3 of a 14-day hospital stay destroys the remaining 11 days,
///   and what is loud is a warning waking the rest of the family about somebody
///   who is genuinely away. The asymmetry is the decision.
/// * **This row says when a write lands.** `AwayCopy.saved` is null because the
///   Tap screen's own away line is the confirmation and is still there tomorrow.
///   This row has no such line — the only feedback was a status line changing
///   under a reader who may not be looking, and a blind watcher heard nothing.
///
/// The hardest assertion here is the **negative** one: *Go back* must write
/// nothing. `strategy.md`'s rule is to assert the silent case as hard as the
/// firing one, and a confirmation that fires the action anyway is worse than no
/// confirmation at all — it teaches the reader the dialog is decorative.
class _RecordingWatcher extends WatcherStateNotifier {
  _RecordingWatcher(this._state);

  final WatcherState _state;

  int endCalls = 0;
  int setCalls = 0;

  /// What the fake write returns. `set` is the confirmed case; the refusals and
  /// `queued` go through the shared switch and are covered by `AwayCopy`'s own
  /// suite.
  AwayOutcome outcome = const AwayOutcome.set();

  @override
  Future<WatcherState> build() async => _state;

  @override
  Future<AwayOutcome> endAway({
    required String watchedUid,
    required AwayPeriod existing,
    required DayKey watchedToday,
  }) async {
    endCalls += 1;
    return outcome;
  }

  @override
  Future<AwayOutcome> setAway({
    required String watchedUid,
    required DayKey lastDay,
    required DayKey watchedToday,
    AwayPeriod? existing,
  }) async {
    setCalls += 1;
    return outcome;
  }
}

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

  AwayRecord awayRecord() => AwayRecord(
        period: AwayPeriod(from: DayKey(2026, 8, 15), through: DayKey(2026, 8, 22)),
        setBy: 'ana-uid',
        setByName: 'Ana',
      );

  WatchedPersonState person({WatcherCache cache = const WatcherCache.empty()}) =>
      WatchedPersonState(
        link: linkTo('mum', 'Mum'),
        cache: cache,
        decision: WarningDecision(
          outcome: WarningOutcome.silent,
          day: d,
          silenceReason: SilenceReason.checkInRecorded,
        ),
      );

  WatcherState stateFor(WatchedPersonState who) => WatcherState(
        people: [who],
        today: today,
        watcherZone: TimeZones.location('Europe/Madrid'),
        warningDelivery: NotificationDelivery.redundant,
        uses24Hour: true,
      );

  /// The row inside a scope, with the notifier replaced by a recorder.
  ///
  /// [recorder] is optional so a test can pump the **same** tree again with a
  /// different person — which updates the existing elements rather than
  /// building new ones, and is the only way to reach `didUpdateWidget`. Passing
  /// a fresh recorder would rebuild the row's `State` from scratch and any
  /// assertion about state surviving a rebuild would pass for the wrong reason.
  Future<_RecordingWatcher> pumpRow(
    WidgetTester tester, {
    required WatchedPersonState who,
    Size surface = const Size(400, 800),
    double textScale = 1,
    _RecordingWatcher? recorder,
  }) async {
    tester.view.physicalSize = surface * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    final state = stateFor(who);
    final notifier = recorder ?? _RecordingWatcher(state);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [watcherStateProvider.overrideWith(() => notifier)],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(body: WatcherBody(state: state)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return notifier;
  }

  group('ending an away period asks first', () {
    testWidgets('the dialog names the person and says what is lost',
        (tester) async {
      await pumpRow(tester, who: person(cache: WatcherCache(away: awayRecord())));

      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.endAwayConfirmTitle('Mum')), findsOneWidget);
      // The destructive part first, then the consequence, then the way back.
      expect(find.text(WatcherCopy.endAwayConfirmBody('Mum')), findsOneWidget);
      expect(find.text(WatcherCopy.endAwayConfirmAction), findsOneWidget);
      // The picker's approved dismissal, verbatim, rather than a second word
      // for the same act.
      expect(find.text(AwayCopy.cancel), findsOneWidget);
    });

    testWidgets('GOING BACK writes nothing at all', (tester) async {
      // The assertion the whole decision rests on. A confirmation that runs the
      // action anyway is worse than none: it teaches the reader to press
      // through it, and the next mis-tap costs eleven days of cover.
      final recorder =
          await pumpRow(tester, who: person(cache: WatcherCache(away: awayRecord())));

      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcher-away-end-cancel')));
      await tester.pumpAndSettle();

      expect(recorder.endCalls, 0);
      // And it says nothing afterwards: a dismissal is a choice, not a fault.
      expect(find.byKey(const Key('watcher-away-message-mum_ana')), findsNothing);
    });

    testWidgets('confirming ends it, and the row says so', (tester) async {
      final recorder =
          await pumpRow(tester, who: person(cache: WatcherCache(away: awayRecord())));

      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcher-away-end-confirm')));
      await tester.pumpAndSettle();

      expect(recorder.endCalls, 1);
      expect(find.text(WatcherCopy.awayEndedSaved('Mum')), findsOneWidget);
    });

    testWidgets('the dialog\'s actions clear the 48dp floor', (tester) async {
      // `guidelines.md`: 48dp for every secondary control, no exceptions — and
      // a dialog is where Material's own default (36dp) would otherwise win.
      await pumpRow(tester, who: person(cache: WatcherCache(away: awayRecord())));

      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();

      for (final key in const [
        Key('watcher-away-end-cancel'),
        Key('watcher-away-end-confirm'),
      ]) {
        expect(tester.getSize(find.byKey(key)).height,
            greaterThanOrEqualTo(48), reason: '$key');
      }
    });

    testWidgets('and it survives the largest font scale on a small phone',
        (tester) async {
      // The shape `screens.md` records the Phase 5 gate measuring: a dialog
      // whose content overflows at scale 2.0 is CLIPPED IN RELEASE, silently.
      // `scrollable: true` is what stops that being this dialog.
      await pumpRow(
        tester,
        who: person(cache: WatcherCache(away: awayRecord())),
        surface: const Size(320, 480),
        textScale: 2,
      );

      // The control is below the fold at this scale — that is the list
      // scrolling, not the dialog, and `watcher_screen_test.dart` covers
      // reachability. Scroll to it so the assertion below is about the DIALOG.
      await tester.ensureVisible(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'a dialog that overflows here is CLIPPED IN RELEASE');
      expect(find.text(WatcherCopy.endAwayConfirmAction), findsOneWidget);
      // **And the way BACK is still there.** This assertion did not exist, so
      // the case measured only that the destructive action survived the scale
      // — the half that costs nothing if it is missing.
      expect(find.text(AwayCopy.cancel), findsOneWidget);

      // **The destructive action must not sit flush against the safe one.**
      // `AlertDialog` stacks its actions in an `OverflowBar` once they no
      // longer fit side by side, and defaults the gap to 0 — so at this size
      // *End it* was directly under *Go back*, touching, with nothing between
      // them. Overshooting *Go back* by a few pixels then ends eleven days of
      // cover, which is the mis-tap the dialog was added to prevent.
      final back = tester.getRect(find.byKey(const Key('watcher-away-end-cancel')));
      final endIt = tester.getRect(find.byKey(const Key('watcher-away-end-confirm')));
      expect(back.overlaps(endIt), isFalse, reason: 'the two actions overlap');
      final stacked = endIt.top >= back.bottom - 1;
      expect(
        stacked ? endIt.top - back.bottom : endIt.left - back.right,
        greaterThanOrEqualTo(8),
        reason: stacked
            ? 'stacked with no gap: a mis-tap on Go back ends the period'
            : 'side by side with no gap',
      );
    });
  });

  group('what the row says is what came BACK — not always "Saved"', () {
    /// The platform messages TalkBack would speak, rather than the copy
    /// constants: a string-equality check against a constant still passes with
    /// the whole `sendAnnouncement` call deleted, which is the mistake
    /// `watcher_screen_test.dart` records being fixed for.
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

    /// Ends the period with the recorder returning [outcome], and reports what
    /// the row said and spoke.
    Future<(List<String>, _RecordingWatcher)> endWith(
      WidgetTester tester,
      AwayOutcome outcome,
    ) async {
      final recorder =
          await pumpRow(tester, who: person(cache: WatcherCache(away: awayRecord())));
      recorder.outcome = outcome;
      final spoken = announcementsOn(tester);
      final handle = tester.ensureSemantics();

      await tester.tap(find.text(WatcherCopy.endAwayAction('Mum')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcher-away-end-confirm')));
      await tester.pumpAndSettle();
      // Disposed here rather than in a tear-down: the framework verifies no
      // handle is outstanding BEFORE tear-downs run, so `addTearDown` fails the
      // test it was meant to clean up after.
      handle.dispose();
      return (spoken, recorder);
    }

    // Until 2026-09-01 this file's recorder had an `outcome` field that **no
    // test ever assigned**: all six ran the confirmed case. Rewriting the row's
    // one branch as `final message = saved;` left every test green while a
    // watcher who pressed in a lift read *"Saved. Mum is marked away."* for a
    // write the server had refused. That is the Phase 5 gate's finding
    // restated — the double replaced the method that ACTS, and left the method
    // that CHOOSES A SENTENCE undriven — and §12 calls a watcher silently wrong
    // about somebody else's cover the one failure this app cannot detect in
    // itself.

    testWidgets('a QUEUED write is not reported as saved', (tester) async {
      final (spoken, recorder) = await endWith(tester, const AwayOutcome.queued());

      expect(recorder.endCalls, 1);
      expect(find.text(AwayCopy.queued), findsOneWidget);
      expect(find.text(WatcherCopy.awayEndedSaved('Mum')), findsNothing,
          reason: 'the write has not landed; saying it has is the false half');
      expect(spoken, [AwayCopy.queued]);
    });

    testWidgets('a REFUSED write is not reported as saved', (tester) async {
      final (spoken, recorder) = await endWith(
        tester,
        const AwayOutcome.refused(AwayRefusal.notPermitted),
      );

      expect(recorder.endCalls, 1);
      expect(find.text(AwayCopy.refusal(AwayRefusal.notPermitted)),
          findsOneWidget);
      expect(find.text(WatcherCopy.awayEndedSaved('Mum')), findsNothing);
      expect(spoken, [AwayCopy.refusal(AwayRefusal.notPermitted)],
          reason: 'a blind watcher hears the refusal or hears nothing at all');
    });

    testWidgets('and the CONFIRMED case still speaks its own sentence',
        (tester) async {
      // The control for the two above: without it, a row that said the shared
      // switch's sentence for everything would pass both of them.
      final (spoken, _) = await endWith(tester, const AwayOutcome.set());

      expect(find.text(WatcherCopy.awayEndedSaved('Mum')), findsOneWidget);
      expect(spoken, [WatcherCopy.awayEndedSaved('Mum')]);
    });

    testWidgets('the sentence is dropped once the period it described moves',
        (tester) async {
      // *"Mum is marked away"* is PRESENT TENSE. It was cleared only by the
      // next press, so a resume, a refresh or a foreground push could leave it
      // sitting under a row that now reads "Everything OK" — a status claim
      // contradicting the row above it, which is `guidelines.md`'s *state, not
      // history* rule broken by the newest sentence on the screen.
      final recorder = await pumpRow(tester, who: person());
      recorder.outcome = const AwayOutcome.set();

      await tester.tap(find.text(WatcherCopy.markAwayAction('Mum')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AwayPickerScreen.saveKey));
      await tester.pumpAndSettle();
      expect(find.text(WatcherCopy.awaySetSaved('Mum')), findsOneWidget);

      // A period appears from elsewhere — Mum's own phone, or another watcher —
      // and this row is rebuilt from the reconcile that followed. The SAME
      // recorder, so the tree updates in place and the row's `State` survives:
      // rebuilding it from scratch would clear `_message` for a reason that has
      // nothing to do with the fix.
      await pumpRow(
        tester,
        who: person(cache: WatcherCache(away: awayRecord())),
        recorder: recorder,
      );
      await tester.pumpAndSettle();

      expect(find.text(WatcherCopy.awaySetSaved('Mum')), findsNothing,
          reason: 'a present-tense claim must not outlive what it described');
    });
  });

  group('a write that lands says so — on this surface only', () {
    testWidgets('setting away is confirmed by name', (tester) async {
      final recorder = await pumpRow(tester, who: person());

      await tester.tap(find.text(WatcherCopy.markAwayAction('Mum')));
      await tester.pumpAndSettle();
      // The picker, opened from the row: it names the person, which is the
      // other half of the same day's decision.
      expect(find.text(AwayCopy.pickerTitleFor('Mum')), findsOneWidget);

      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AwayPickerScreen.saveKey));
      await tester.pumpAndSettle();

      expect(recorder.setCalls, 1);
      expect(find.text(WatcherCopy.awaySetSaved('Mum')), findsOneWidget);
    });

    testWidgets('and AwayCopy.saved stays null, because the Tap screen is not '
        'this screen', (tester) async {
      // The split, asserted as a fact about the constant rather than left to a
      // reader to infer from two surfaces behaving differently.
      expect(AwayCopy.saved, isNull);
    });
  });
}
