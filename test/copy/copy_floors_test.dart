@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// **The copy floors, asserted against the source rather than a reviewer's eye.**
///
/// `docs/ui-ux/guidelines.md` bans a handful of things outright — a phrase, a
/// punctuation mark, a date format. Every one of them is the kind of rule that
/// is obviously right, universally agreed to, and quietly broken anyway: the
/// Phase 3 gate found *"something went wrong"* shipping on the watcher's main
/// screen, in a codebase where two other files quote the ban back in their own
/// comments. The rule was known and applied everywhere except the one place a
/// family member would read it.
///
/// So it is a test. It reads `lib/copy/` as text, because the strings there are
/// `const` and a reviewer is the only other thing that ever looks at them.
///
/// **Scoped to `lib/copy/` deliberately.** ARCHITECTURE.md §5 makes Copy a leaf
/// that every user-visible string lives in — a literal inline in a widget is
/// already a review failure on its own terms, and this file would give a false
/// sense of coverage if it implied it could see them.
void main() {
  final files = Directory('lib/copy')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  setUpAll(() {
    expect(files, isNotEmpty,
        reason: 'run from the package root, or this asserts nothing at all');
  });

  /// Every single-quoted string literal in [source], with the doc comments and
  /// line comments stripped first.
  ///
  /// The comments have to go: this file's own explanations quote the banned
  /// phrase, and so do two production files that document why they avoid it.
  /// Matching those would make the test unfixable except by deleting the
  /// reasoning, which is the opposite of what it is for.
  Iterable<String> literals(String source) {
    final withoutComments = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    return RegExp(r"'((?:[^'\\]|\\.)*)'")
        .allMatches(withoutComments)
        .map((m) => m.group(1)!);
  }

  test('never "something went wrong"', () {
    // guidelines.md, Floors: *"Errors | Say what happened and what to do. Never
    // a code, never 'something went wrong'."* This shipped in
    // `WatcherCopy.couldNotCheckOn` — an error string on the screen the *lost
    // access* notification routes to, promising to say what to do.
    for (final file in files) {
      for (final literal in literals(file.readAsStringSync())) {
        expect(
          literal.toLowerCase(),
          isNot(contains('something went wrong')),
          reason: '${file.path}: say what happened and what to do',
        );
      }
    }
  });

  test('no exclamation marks', () {
    // guidelines.md, copy rules for notifications: *"No emoji, no exclamation
    // marks."* Every message this app sends is quiet status or bad news, and
    // there is no marketing tone in either.
    for (final file in files) {
      for (final literal in literals(file.readAsStringSync())) {
        expect(literal, isNot(contains('!')),
            reason: '${file.path}: quiet status or bad news, never enthusiasm');
      }
    }
  });

  test('no emoji', () {
    // Same rule. Matched by code point rather than by a list, so a decorative
    // character nobody thought of is caught too.
    final emoji = RegExp(
      r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{1F000}-\u{1F2FF}]',
      unicode: true,
    );
    for (final file in files) {
      for (final literal in literals(file.readAsStringSync())) {
        expect(emoji.hasMatch(literal), isFalse,
            reason: '${file.path}: "$literal"');
      }
    }
  });

  test('no numeric dates', () {
    // guidelines.md: *"Written out — 'Saturday 22', 'Sat 22 Aug'. Never 22/08 —
    // ambiguous, and hard to read at a glance."* Ambiguous is the operative
    // word: this app has a watcher abroad by design, and 08/09 is two different
    // days depending on where the reader learned to read dates.
    //
    // Interpolations are excluded — `$date` carries an already-formatted string
    // from `NotificationCopy._date`, which has its own tests.
    final numericDate = RegExp(r'\b\d{1,2}/\d{1,2}\b');
    for (final file in files) {
      for (final literal in literals(file.readAsStringSync())) {
        expect(numericDate.hasMatch(literal), isFalse,
            reason: '${file.path}: "$literal" — write the date out');
      }
    }
  });
}
