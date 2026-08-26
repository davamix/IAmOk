@TestOn('vm')
library;

import 'package:i_am_ok/copy/onboarding_copy.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// Onboarding and pairing copy.
///
/// The refusal tables are the point. **Every branch is a claim**, and a family
/// typing a code is being told why it did not work — so each sentence has to be
/// true about what actually happened and has to name a next action. A branch
/// that fell through to another branch's sentence would be this app telling
/// somebody the wrong thing on the one screen that pairs them.
void main() {
  TimeZones.ensureInitialized();
  final madrid = TimeZones.location('Europe/Madrid');

  group('pairing refusals', () {
    test('every reason has a sentence', () {
      for (final reason in PairingRefusal.values) {
        expect(OnboardingCopy.pairingRefusal(reason), isNotEmpty,
            reason: '${reason.name} has no sentence');
      }
    });

    test('every sentence ends a sentence and says something', () {
      for (final reason in PairingRefusal.values) {
        final line = OnboardingCopy.pairingRefusal(reason);
        expect(line, endsWith('.'), reason: reason.name);
        expect(line.split(' ').length, greaterThan(3), reason: reason.name);
      }
    });

    // The three the reader can act on themselves must not read alike — "check
    // it and type it again" and "ask for a new one" are different actions, and
    // giving the wrong one sends a family round a loop that cannot succeed.
    test('the three code problems are told apart', () {
      final unknown = OnboardingCopy.pairingRefusal(PairingRefusal.unknownCode);
      final expired = OnboardingCopy.pairingRefusal(PairingRefusal.expired);
      final used = OnboardingCopy.pairingRefusal(PairingRefusal.alreadyUsed);

      expect({unknown, expired, used}, hasLength(3));
      expect(unknown.toLowerCase(), contains('check'));
      expect(expired.toLowerCase(), contains('expired'));
      expect(used.toLowerCase(), contains('already been used'));
    });

    test('the own-code refusal names the mistake, so it is not repeated', () {
      final line = OnboardingCopy.pairingRefusal(PairingRefusal.ownCode);
      expect(line.toLowerCase(), contains('your own code'));
    });

    // Not the reader's mistake and not fixable by re-typing, so the sentence
    // points at the other phone.
    test('the two other-phone problems say so', () {
      for (final reason in [
        PairingRefusal.watchedProfileMissing,
        PairingRefusal.unusableTimezone,
      ]) {
        expect(
          OnboardingCopy.pairingRefusal(reason).toLowerCase(),
          contains('their phone'),
          reason: reason.name,
        );
      }
    });

    test('the unreachable case is about the connection, not about the code',
        () {
      final line =
          OnboardingCopy.pairingRefusal(PairingRefusal.couldNotReach)
              .toLowerCase();
      expect(line, contains('internet'));
      expect(line, isNot(contains('expired')));
      expect(line, isNot(contains('already been used')),
          reason: 'nothing was decided — claiming otherwise is a false claim');
    });

    test('no sentence blames the reader for a fault that is not theirs', () {
      for (final reason in [
        PairingRefusal.watcherProfileMissing,
        PairingRefusal.couldNotReach,
        PairingRefusal.notSignedIn,
      ]) {
        expect(
          OnboardingCopy.pairingRefusal(reason).toLowerCase(),
          isNot(contains('not right')),
          reason: reason.name,
        );
      }
    });
  });

  group('invite refusals', () {
    test('every reason has a sentence, and they are distinct', () {
      final lines = {
        for (final reason in InviteRefusal.values)
          OnboardingCopy.inviteRefusal(reason),
      };
      expect(lines, hasLength(InviteRefusal.values.length));
      for (final line in lines) {
        expect(line, isNotEmpty);
        expect(line, endsWith('.'));
      }
    });
  });

  group('the code expiry line', () {
    test('names the day in full and the time by the device setting', () {
      // 09:00 UTC on 27 August is 11:00 in Madrid.
      final line = OnboardingCopy.codeExpiry(
        expiresAt: DateTime.utc(2026, 8, 27, 9),
        zone: madrid,
        uses24Hour: true,
      );
      expect(line, 'It stops working at 11:00 on Thursday 27 August.');
    });

    test('follows a 12-hour device', () {
      final line = OnboardingCopy.codeExpiry(
        expiresAt: DateTime.utc(2026, 8, 27, 9),
        zone: madrid,
        uses24Hour: false,
      );
      expect(line, contains('11:00 am'));
      expect(line, isNot(contains('11:00 on')));
    });

    // `guidelines.md`: dates written out, never `27/08` — ambiguous and hard to
    // scan.
    test('never renders a numeric date', () {
      final line = OnboardingCopy.codeExpiry(
        expiresAt: DateTime.utc(2026, 8, 27, 9),
        zone: madrid,
        uses24Hour: true,
      );
      expect(line, isNot(matches(RegExp(r'\d{2}/\d{2}'))));
      expect(line, contains('August'));
      expect(line, contains('Thursday'));
    });

    test('renders in the given zone, not UTC', () {
      // 23:30 UTC on the 26th is already the 27th in Madrid.
      final line = OnboardingCopy.codeExpiry(
        expiresAt: DateTime.utc(2026, 8, 26, 23, 30),
        zone: madrid,
        uses24Hour: true,
      );
      expect(line, contains('Thursday 27 August'));
    });
  });

  group('the share message carries a readable code', () {
    test('grouped the way it is read aloud', () {
      expect(OnboardingCopy.shareMessage('K7RTQX'), contains('K7R TQX'));
    });

    test('and names the app, so a stranger knows what it is for', () {
      expect(OnboardingCopy.shareMessage('K7RTQX'), contains('I Am Ok'));
    });
  });

  group('the summary reports evidence, not intentions', () {
    test('names the watchers who actually exist', () {
      expect(
        OnboardingCopy.summaryWatched(['Ana', 'Beto']),
        'Ana and Beto will know you are OK when you tap each day.',
      );
    });

    test('one watched person takes the singular verb', () {
      expect(
        OnboardingCopy.summaryWatching(['Mum']),
        'You will be told if Mum misses a day.',
      );
    });

    test('several take the plural', () {
      expect(
        OnboardingCopy.summaryWatchingMany(['Granddad', 'Mum']),
        'You will be told if Granddad and Mum miss a day.',
      );
    });

    test('the empty case offers the way to change it', () {
      expect(OnboardingCopy.summaryNothing.toLowerCase(),
          contains('add someone'));
      expect(
        OnboardingCopy.summaryNothing.toLowerCase(),
        isNot(contains('ask a family')),
        reason: 'the dead-end wording is only honest with nothing to press',
      );
    });
  });

  group('the two questions are the ones PLAN.md fixed', () {
    test('verbatim', () {
      expect(OnboardingCopy.watchedQuestion, "Who should know you're OK?");
      expect(OnboardingCopy.watcherQuestion, 'Who are you looking after?');
    });

    test('and neither asks about a role directly', () {
      for (final question in [
        OnboardingCopy.watchedQuestion,
        OnboardingCopy.watcherQuestion,
      ]) {
        expect(question.toLowerCase(), isNot(contains('elderly')));
        expect(question.toLowerCase(), isNot(contains('watcher')));
        expect(question.toLowerCase(), isNot(contains('role')));
      }
    });
  });

  group('the sign-in blurb promises nothing that is not set up yet', () {
    test('it describes the app rather than claiming an audience', () {
      // The same rule `TapCopy.tapTargetLabel` follows: with an empty audience,
      // a promise that "your family will be told" is contradicted by the very
      // next screen.
      expect(
        OnboardingCopy.signInBlurb.toLowerCase(),
        isNot(contains('your family')),
      );
    });
  });
}
