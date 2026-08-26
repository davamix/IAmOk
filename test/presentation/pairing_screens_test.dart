import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/presentation/pairing_screens.dart';

/// The two pairing screens' one piece of input transformation.
///
/// **This file existed only as a claim until the Phase 5 review.**
/// `UpperCaseFormatter`'s docstring said it was public *"because
/// `pairing_screens_test.dart` asserts it directly"*, and there was no such
/// file — so the class was public for a reason that was not true, and the
/// sentence read as coverage the suite did not have. That is the failure mode
/// `CLAUDE.md`'s newest constraint is about, in a docstring.
void main() {
  group('UpperCaseFormatter', () {
    TextEditingValue format(TextEditingValue oldValue, TextEditingValue next) =>
        UpperCaseFormatter().formatEditUpdate(oldValue, next);

    test('upper-cases as the person types', () {
      final result = format(
        TextEditingValue.empty,
        const TextEditingValue(text: 'k7r'),
      );
      expect(result.text, 'K7R');
    });

    test('leaves digits alone', () {
      expect(
        format(TextEditingValue.empty, const TextEditingValue(text: '5v2'))
            .text,
        '5V2',
      );
    });

    // Upper-casing is length-preserving for this alphabet, so carrying the
    // selection through unchanged is correct — and a formatter that moved the
    // caret would be a code nobody could finish entering.
    test('does not move the caret', () {
      final result = format(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'k7rtqx',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      expect(result.text, 'K7RTQX');
      expect(result.selection.baseOffset, 6);
      expect(result.selection.extentOffset, 6);
    });

    test('a caret in the middle stays in the middle', () {
      final result = format(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'k7rtqx',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      expect(result.selection.baseOffset, 3);
    });

    test('the length never changes, across the whole alphabet', () {
      for (final raw in ['abcdef', 'ABCDEF', 'a1b2c3', 'k7r tqx', 'k7r-tqx']) {
        final result = format(
          TextEditingValue.empty,
          TextEditingValue(text: raw),
        );
        expect(result.text.length, raw.length, reason: raw);
      }
    });

    test('an empty edit stays empty', () {
      expect(format(TextEditingValue.empty, TextEditingValue.empty).text, '');
    });
  });
}
