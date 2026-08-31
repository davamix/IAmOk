import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/copy/away_copy.dart';
import 'package:i_am_ok/copy/onboarding_copy.dart';
import 'package:i_am_ok/domain/domain.dart';

/// **Which sentence a person reads about an away write.**
///
/// Every string here was referenced by no test at all, and the switch that
/// picks between them was written out twice — once per screen — which is the
/// defect `WatchedRowKind` was extracted to stop. The stakes are the ones
/// `AwayOutcome.queued` was invented for: swapping two of these tells somebody
/// their family was told when they were not, on the write whose whole
/// justification (§8) is that it works on a plane.
void main() {
  group('awayMessageFor — one switch, and every case distinct', () {
    test('success says nothing', () {
      // The Tap screen's own away line is the confirmation, and it is a better
      // one than a toast because it is still there tomorrow.
      expect(AwayCopy.awayMessageFor(const AwayOutcome.set()), isNull);
      expect(AwayCopy.saved, isNull);
    });

    test('queued says SAVED, and is not a refusal', () {
      final message = AwayCopy.awayMessageFor(const AwayOutcome.queued());
      expect(message, AwayCopy.queued);
      expect(message, startsWith('Saved'),
          reason: 'the part the reader needs comes first — §8 chose this write '
              'shape so an offline write works, and the one thing they must '
              'not be told is that nothing was saved');
    });

    test('every refusal maps to its own sentence', () {
      for (final refusal in AwayRefusal.values) {
        expect(
          AwayCopy.awayMessageFor(AwayOutcome.refused(refusal)),
          AwayCopy.refusal(refusal),
          reason: 'the mapping must not collapse two causes into one remedy',
        );
      }
    });

    test('no two outcomes produce the same words', () {
      // The guard against the switch collapsing. Every assertion above would
      // still pass if two arms returned the same string.
      final rendered = <String>{
        for (final refusal in AwayRefusal.values) AwayCopy.refusal(refusal),
        AwayCopy.queued,
      };
      expect(rendered, hasLength(AwayRefusal.values.length + 1));
    });
  });

  group('no sentence claims more than the device knows', () {
    test('queued does NOT name the radio', () {
      // `send` reaches queued purely from a timeout: a slow server, a congested
      // cell, or a cold Firestore connection on a phone with five bars all land
      // here. `guidelines.md`: *"your phone has been offline" is a claim about
      // the DEVICE that is false whenever the server was reached.* Saying it in
      // the affirmative is the same claim.
      expect(AwayCopy.queued, isNot(contains('offline')));
      expect(AwayCopy.queued.toLowerCase(), isNot(contains('back online')));
      expect(AwayCopy.queued.toLowerCase(), isNot(contains('connection')));
    });

    test('notPermitted does NOT claim a permanent loss of access', () {
      // Firestore returns `permission-denied` for a SHAPE violation as readily
      // as an authorisation one, and these rules validate shape aggressively —
      // so this is reachable whenever the cached period is stale. Claiming lost
      // access there is ADR-0004's false claim arriving through the copy layer,
      // about an app that has lost nothing.
      final sentence = AwayCopy.refusal(AwayRefusal.notPermitted);
      expect(sentence.toLowerCase(), isNot(contains('no longer')));
      expect(sentence.toLowerCase(), isNot(contains('lost access')));
    });

    test('every refusal names something to do', () {
      // `guidelines.md` Floors: *say what happened and what to do.* A sentence
      // with no next step is a dead end, and the reader may be 80 years old.
      for (final refusal in AwayRefusal.values) {
        final sentence = AwayCopy.refusal(refusal).toLowerCase();
        expect(
          sentence.contains('try again') ||
              sentence.contains('choose') ||
              sentence.contains('sign in') ||
              sentence.contains('ask'),
          isTrue,
          reason: '${refusal.name} names no next step: '
              '"${AwayCopy.refusal(refusal)}"',
        );
      }
    });

    test('serverFault reuses the approved pairing sentence, verbatim', () {
      // The Phase 5 gate approved exactly these words for exactly this claim.
      // A sibling tuned in isolation would be a second way of saying one thing.
      expect(
        AwayCopy.refusal(AwayRefusal.serverFault),
        OnboardingCopy.pairingRefusal(PairingRefusal.serverFault),
      );
    });

    test('notSignedIn reuses its approved sentence too', () {
      expect(
        AwayCopy.refusal(AwayRefusal.notSignedIn),
        OnboardingCopy.pairingRefusal(PairingRefusal.notSignedIn),
      );
    });
  });

  group('the writer nobody can name', () {
    test('the placeholder is never shown to a reader', () {
      // It exists because the rules REQUIRE `setByName`, not because anybody
      // should read it. "Someone marked you away until Saturday 22" names a
      // role, which `guidelines.md` forbids.
      expect(
        AwayRecord(
          period: AwayPeriod(from: DayKey(2026, 8, 15), through: DayKey(2026, 8, 22)),
          setBy: 'ana-uid',
          setByName: AwayCopy.unnamedWriter,
        ).nameToShowFor('mum-uid'),
        isNull,
      );
    });

    test('it satisfies the rules clause, or the write it enables is denied', () {
      expect(AwayCopy.unnamedWriter.trim().length,
          greaterThanOrEqualTo(AwayRules.nameMinLength));
      expect(AwayCopy.unnamedWriter.length,
          lessThanOrEqualTo(AwayRules.nameMaxLength));
    });
  });
}
