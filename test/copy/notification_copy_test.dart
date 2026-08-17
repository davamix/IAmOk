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
  }) =>
      NotificationCopy.warningBody(
        outcome: outcome,
        watchedName: 'Mum',
        day: d,
        away: away,
        unverifiedSince: unverifiedSince,
        lastConfirmedDay: lastConfirmedDay,
        watcherZone: madrid,
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
          tappedAt: since,
          watcherZone: madrid,
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

    test('the correction renders the time in the watcher\'s zone', () {
      expect(
        NotificationCopy.correctionBody(
          watchedName: 'Mum',
          tappedAt: at(madrid, 2026, 8, 16, 23, 40),
          watcherZone: madrid,
        ),
        'Correction: Mum did check in yesterday, at 23:40.',
      );
    });
  });
}
