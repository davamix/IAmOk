import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// §7's code format, asserted against the reason it has that format: the code is
/// read aloud over the phone by an elderly person.
void main() {
  group('the alphabet', () {
    test('is 32 characters', () {
      expect(InviteCode.alphabet.length, 32);
    });

    test('excludes exactly the four §7 names', () {
      for (final banned in ['O', '0', 'I', '1']) {
        expect(
          InviteCode.alphabet.contains(banned),
          isFalse,
          reason: '$banned is what §7 removed, and removing it is the whole '
              'point of the alphabet',
        );
      }
    });

    test('has no duplicate characters', () {
      expect(InviteCode.alphabet.split('').toSet().length, 32);
    });

    test('is upper case and alphanumeric throughout', () {
      expect(InviteCode.alphabet, matches(RegExp(r'^[A-Z2-9]+$')));
    });
  });

  group('tryParse accepts what a person actually types', () {
    test('a clean code', () {
      expect(InviteCode.tryParse('K7RTQX'), 'K7RTQX');
    });

    test('lower case, because a phone keyboard defaults to it', () {
      expect(InviteCode.tryParse('k7rtqx'), 'K7RTQX');
    });

    test('the grouping they were read aloud', () {
      expect(InviteCode.tryParse('K7R TQX'), 'K7RTQX');
    });

    test('a hyphen somebody added themselves', () {
      expect(InviteCode.tryParse('K7R-TQX'), 'K7RTQX');
    });

    test('surrounding whitespace from a paste', () {
      expect(InviteCode.tryParse('  K7RTQX \n'), 'K7RTQX');
    });

    test('mixed case with grouping', () {
      expect(InviteCode.tryParse(' k7r tQx '), 'K7RTQX');
    });
  });

  group('tryParse rejects rather than repairs', () {
    test('a letter outside the alphabet', () {
      expect(InviteCode.tryParse('K7RTQO'), isNull);
      expect(InviteCode.tryParse('K7RTQI'), isNull);
    });

    test('a digit outside the alphabet', () {
      expect(InviteCode.tryParse('K7RTQ0'), isNull);
      expect(InviteCode.tryParse('K7RTQ1'), isNull);
    });

    // The tempting "helpful" behaviour, and the reason it is not implemented:
    // neither substitution has a target inside the alphabet, so it would be a
    // guess about what somebody meant on the path that pairs two families.
    test('O is not read as 0, and I is not read as 1', () {
      expect(InviteCode.tryParse('OK7RTQ'), isNull);
      expect(InviteCode.tryParse('IK7RTQ'), isNull);
    });

    test('too short', () {
      expect(InviteCode.tryParse('K7RTQ'), isNull);
    });

    test('too long', () {
      expect(InviteCode.tryParse('K7RTQXA'), isNull);
    });

    // **A stray character is refused, never DROPPED.** Every case above has an
    // off-alphabet character inside six, where skipping it and refusing it both
    // end at null — so a `tryParse` that silently *skipped* what it does not
    // recognise passed the whole group. Found by mutation.
    //
    // The difference only shows past six characters, and there it matters most:
    // skipping turns `K7RTQXO` into the perfectly valid, perfectly different
    // code `K7RTQX`, and pairs a family to whoever holds that one. Refusing is
    // what §7's "guessing at what somebody meant" rule is about.
    test('a stray character is not silently dropped into a valid code', () {
      expect(InviteCode.tryParse('K7RTQXO'), isNull,
          reason: 'dropping the O leaves K7RTQX — a real code, and not theirs');
      expect(InviteCode.tryParse('OK7RTQX'), isNull);
      expect(InviteCode.tryParse('K7R0TQX'), isNull);
      expect(InviteCode.tryParse('K7RTQX.'), isNull,
          reason: 'a full stop pasted from the end of the share message');
    });

    test('empty, and separators only', () {
      expect(InviteCode.tryParse(''), isNull);
      expect(InviteCode.tryParse('   '), isNull);
      expect(InviteCode.tryParse('- -'), isNull);
    });

    test('punctuation and symbols', () {
      expect(InviteCode.tryParse('K7RTQ!'), isNull);
      expect(InviteCode.tryParse('K7RT.X'), isNull);
    });

    test('every character of the alphabet is accepted in a whole code', () {
      // Six at a time across the whole alphabet, so a character accidentally
      // omitted from the accept path fails here rather than on a family's phone.
      for (var i = 0; i + 6 <= InviteCode.alphabet.length; i++) {
        final code = InviteCode.alphabet.substring(i, i + 6);
        expect(InviteCode.tryParse(code), code);
      }
    });
  });

  group('isValid agrees with tryParse', () {
    test('both directions', () {
      expect(InviteCode.isValid('k7r tqx'), isTrue);
      expect(InviteCode.isValid('K7RTQ0'), isFalse);
    });
  });

  group('forReading', () {
    test('splits six characters into two groups of three', () {
      expect(InviteCode.forReading('K7RTQX'), 'K7R TQX');
    });

    test('round-trips through tryParse, so the grouping is presentation only',
        () {
      expect(InviteCode.tryParse(InviteCode.forReading('K7RTQX')), 'K7RTQX');
    });

    test('leaves anything that is not six characters alone', () {
      expect(InviteCode.forReading('K7RT'), 'K7RT');
      expect(InviteCode.forReading(''), '');
    });
  });
}
