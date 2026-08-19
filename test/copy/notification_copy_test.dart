@TestOn('vm')
library;

import 'package:i_am_ok/copy/notification_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// The words, asserted against `docs/ui-ux/screens.md`.
///
/// **Every interpolated value here can be null**, and that is the reason this
/// file exists rather than trusting a switch to be exhaustive. A watcher whose
/// device has never had a successful read has no "offline since" and no "last
/// saw" — and rendering *"offline since null"* to a worried family at 3am is
/// the specific failure the never-reconciled variants were written to prevent.
///
/// The other half is the **openings**, which `screens.md` calls a convention
/// rather than a coincidence: *"No check-in…"* is a claim about her, *"Can't
/// check on Mum —…"* is a claim about **us**. The collapsed shade shows one
/// line, so the differentiator has to survive in the first words. That is
/// asserted here rather than left to review, because it is the thing a
/// well-meaning rewording would quietly break.
void main() {
  final d = day('2026-08-16');
  final since = at(madrid, 2026, 8, 11, 10, 14);

  String body(
    WarningOutcome outcome, {
    AwayPeriod? away,
    DateTime? unverifiedSince,
    DayKey? lastConfirmedDay,
    // Null means five days after `since` — inside the week, so the existing
    // assertions keep exercising the weekday form.
    DayKey? today,
    bool uses24Hour = true,
  }) =>
      NotificationCopy.warningBody(
        outcome: outcome,
        watchedName: 'Mum',
        day: d,
        away: away,
        unverifiedSince: unverifiedSince,
        lastConfirmedDay: lastConfirmedDay,
        watcherZone: madrid,
        uses24Hour: uses24Hour,
        today: today ?? day('2026-08-16'),
      );

  group('the two openings are a convention, not a coincidence', () {
    test('claims about HER open with "No check-in"', () {
      expect(body(WarningOutcome.warnOnline), startsWith('No check-in'));
      expect(
        body(WarningOutcome.warnOffline, unverifiedSince: since),
        startsWith('No check-in'),
      );
    });

    test('claims about US open with "Can\'t check on"', () {
      expect(
        body(
          WarningOutcome.warnUnverifiableAway,
          away: AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
          unverifiedSince: since,
        ),
        startsWith("Can't check on Mum —"),
      );
      expect(
        body(WarningOutcome.warnAccessLost, lastConfirmedDay: day('2026-08-15')),
        startsWith("Can't check on Mum —"),
      );
    });

    test('the differentiator survives a one-line truncation', () {
      // Android's collapsed shade shows one line and ellipsizes. Whatever
      // survives has to already tell the reader which KIND of claim this is.
      for (final outcome in [
        WarningOutcome.warnOnline,
        WarningOutcome.warnOffline,
        WarningOutcome.warnUnverifiableAway,
        WarningOutcome.warnAccessLost,
      ]) {
        final text = body(outcome, unverifiedSince: since);
        final head = text.substring(0, 20);
        expect(
          head.startsWith('No check-in') || head.startsWith("Can't check on"),
          isTrue,
          reason: '$outcome opens with "$head"',
        );
      }
    });
  });

  group('every interpolated value can be null', () {
    test('never reconciled says so, rather than rendering a null', () {
      final text = body(WarningOutcome.warnOffline);
      expect(text, contains('has not been able to check even once'));
      expect(text.toLowerCase(), isNot(contains('null')));
    });

    test('no check-in ever seen says so', () {
      final text = body(WarningOutcome.warnAccessLost);
      expect(text, contains('Your phone has not seen a check-in yet.'));
      expect(text.toLowerCase(), isNot(contains('null')));
    });

    test('no combination of nulls renders the word null', () {
      for (final outcome in [
        WarningOutcome.warnOnline,
        WarningOutcome.warnOffline,
        WarningOutcome.warnUnverifiableAway,
        WarningOutcome.warnAccessLost,
      ]) {
        for (final away in [
          null,
          AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
        ]) {
          for (final unverified in [null, since]) {
            for (final confirmed in [null, day('2026-08-15')]) {
              final text = body(
                outcome,
                away: away,
                unverifiedSince: unverified,
                lastConfirmedDay: confirmed,
              );
              expect(text.toLowerCase(), isNot(contains('null')),
                  reason: '$outcome away=$away since=$unverified '
                      'confirmed=$confirmed');
              expect(text, isNot(contains('  ')),
                  reason: 'an empty clause left a double space: $text');
            }
          }
        }
      }
    });
  });

  group('the Phase 3 gate decisions', () {
    test('the copy names the person, never "she"', () {
      // Nothing in the domain captures a pronoun, so a watched father was
      // getting the wrong one throughout. Cheap now, expensive after
      // translation — which is why it was settled before any of this shipped.
      final all = [
        for (final outcome in [
          WarningOutcome.warnOnline,
          WarningOutcome.warnOffline,
          WarningOutcome.warnUnverifiableAway,
          WarningOutcome.warnAccessLost,
        ])
          body(
            outcome,
            away: AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
            unverifiedSince: since,
            lastConfirmedDay: day('2026-08-15'),
          ),
        NotificationCopy.correctionBody(
          watchedName: 'Mum',
          day: day('2026-08-16'),
          today: day('2026-08-17'),
          tappedAt: since,
          watcherZone: madrid,
          uses24Hour: true,
        ),
      ];

      for (final text in all) {
        for (final pronoun in ['She ', 'she ', ' her ', 'Her ']) {
          expect(text, isNot(contains(pronoun)), reason: text);
        }
      }
    });

    test('the away clause uses the name', () {
      expect(
        body(
          WarningOutcome.warnUnverifiableAway,
          away: AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
          unverifiedSince: since,
        ),
        contains('Mum was marked away until Saturday 22 August.'),
      );
    });

    test('the title is the app name, for every warning', () {
      expect(NotificationCopy.warningTitle, 'I Am Ok');
      expect(NotificationCopy.warningTitle, NotificationCopy.reminderTitle,
          reason: 'settled at the gate: the reminders\' split is the pattern');
    });
  });

  group('ADR-0004\'s three wording rules', () {
    final text = body(
      WarningOutcome.warnAccessLost,
      lastConfirmedDay: day('2026-08-15'),
    );

    test('"your phone last saw", never "last confirmed"', () {
      // The date is the newest check-in THIS DEVICE managed to read, and during
      // a refusal she may be tapping daily. "Last confirmed Saturday 15 August"
      // reads as a five-day silence on the 20th — the words claim nothing, the
      // reading does.
      expect(text, contains('Your phone last saw a check-in on'));
      expect(text.toLowerCase(), isNot(contains('last confirmed')));
    });

    test('"Open the app", never "Open I Am Ok"', () {
      // After an imperative the app's name parses for a beat as its own clause
      // — "Open — I am OK" — which is the opposite of the message, read by the
      // person most likely to misread it.
      expect(text, contains('Open the app to see what to do.'));
      expect(text, isNot(contains('Open I Am Ok')));
    });

    test('it never claims the phone is offline', () {
      // The server was REACHED and said no. The device is online and working.
      expect(text.toLowerCase(), isNot(contains('offline')));
    });
  });

  test('a silent decision has no message and must not be asked for', () {
    // A silent outcome reaching the notification layer is a bug, and returning
    // something harmless would turn it into a spurious warning — the worst
    // direction. It throws instead.
    expect(
      () => body(WarningOutcome.silent),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('dates and times', () {
    test('dates are written out, never 22/08', () {
      expect(NotificationCopy.dayLabel(day('2026-08-22')), 'Saturday 22 August');
    });

    test('an older "offline since" names the day, not just the clock time', () {
      // "offline since 10:14" is actively misleading when the 10:14 was nine
      // days ago — it reads as this morning, understating the problem in
      // exactly the direction this app must not.
      expect(
        body(WarningOutcome.warnOffline, unverifiedSince: since),
        contains('offline since Tuesday 10:14.'),
      );
    });

    test('the correction omits the time when the read carries none', () {
      // **This is what ships.** Phase 3's read has no per-check-in timestamp,
      // so `WatcherReconcileService` passes null and the time clause is absent
      // — see `screens.md`. The retraction is complete without it.
      expect(
        NotificationCopy.correctionBody(
          watchedName: 'Mum',
          day: day('2026-08-16'),
          today: day('2026-08-17'),
          tappedAt: null,
          watcherZone: madrid,
          uses24Hour: true,
        ),
        'Correction: Mum did check in yesterday.',
      );
    });

    test('an OLDER corrected day is named, never called "yesterday"', () {
      // **The reconciler emits a correction for every standing warning a read
      // confirms**, not just yesterday's, and a day leaves `warningsShownFor`
      // only by correction or revocation — so a genuinely missed day sits there
      // indefinitely.
      //
      // Mum's phone is offline over a weekend and both taps sync on Monday. The
      // watcher was warned about Saturday on Sunday and about Sunday on Monday.
      // Monday's read confirms both, and two notifications go out at two ids.
      // With "yesterday" hard-coded they carried identical text — the same
      // sentence twice, one of them wrong about which day it covered, to a
      // reader who cannot ask.
      expect(
        NotificationCopy.correctionBody(
          watchedName: 'Mum',
          day: day('2026-08-15'),
          today: day('2026-08-17'),
          tappedAt: null,
          watcherZone: madrid,
          uses24Hour: true,
        ),
        'Correction: Mum did check in on Saturday 15 August.',
      );
    });

    test('two corrections in one pass do not read identically', () {
      final saturday = NotificationCopy.correctionBody(
        watchedName: 'Mum',
        day: day('2026-08-15'),
        today: day('2026-08-17'),
        tappedAt: null,
        watcherZone: madrid,
        uses24Hour: true,
      );
      final yesterday = NotificationCopy.correctionBody(
        watchedName: 'Mum',
        day: day('2026-08-16'),
        today: day('2026-08-17'),
        tappedAt: null,
        watcherZone: madrid,
        uses24Hour: true,
      );
      expect(saturday, isNot(yesterday));
    });

    test('a 12-hour device gets 12-hour times', () {
      // `guidelines.md` asks for the device's own setting rather than a
      // hard-coded one. The approved strings are 24-hour because the owner's
      // locale is, and that was rendered unconditionally — wrong for the first
      // user whose phone is set the other way, and recorded as a deviation
      // twice before this closed it.
      expect(
        body(WarningOutcome.warnOffline,
            unverifiedSince: at(madrid, 2026, 8, 16, 22, 10), uses24Hour: false),
        contains('offline since 10:10 pm.'),
      );
      expect(
        body(WarningOutcome.warnOffline,
            unverifiedSince: at(madrid, 2026, 8, 16, 22, 10)),
        contains('offline since 22:10.'),
      );
    });

    test('midnight and noon are 12, not 0', () {
      // The arithmetic every 12-hour clock gets wrong once.
      expect(
        body(WarningOutcome.warnOffline,
            unverifiedSince: at(madrid, 2026, 8, 16, 0, 5), uses24Hour: false),
        contains('12:05 am'),
      );
      expect(
        body(WarningOutcome.warnOffline,
            unverifiedSince: at(madrid, 2026, 8, 16, 12, 5), uses24Hour: false),
        contains('12:05 pm'),
      );
    });

    test('STAGED FOR PHASE 4 — with a real tap time, it says so', () {
      // **Not reachable from the app today**, and named so nobody reads it as
      // evidence of current behaviour. It is the only test of a dead branch in
      // the suite, and it is here because the branch is not speculative: Phase 4
      // carries `deviceTappedAt` through the read, at which point this becomes
      // the shipping variant and the one above becomes the fallback.
      //
      // The value must be HER tap, from her phone. The reason the clause was
      // removed rather than approximated is that the only instant available on
      // this side is when this device managed the read — a different fact
      // wearing the same words, and a fabricated claim about a person on the one
      // message whose purpose is to withdraw one.
      expect(
        NotificationCopy.correctionBody(
          watchedName: 'Mum',
          day: day('2026-08-16'),
          today: day('2026-08-17'),
          tappedAt: at(madrid, 2026, 8, 16, 23, 40),
          watcherZone: madrid,
          uses24Hour: true,
        ),
        'Correction: Mum did check in yesterday, at 23:40.',
      );
    });
  });
}
