@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// The domain layer's purity, asserted rather than reviewed.
///
/// PLAN.md calls this non-negotiable and the Phase 0 summary predicts it is the
/// rule "most likely to be broken by a well-meaning shortcut". A reviewer
/// catches that at a phase gate; this catches it in the second it happens.
///
/// The cost of a miss is not stylistic. A `package:flutter` or `dart:io` import
/// under `domain/` compiles, passes every other test, and then throws inside a
/// bare alarm isolate on someone's phone months later — where the failure looks
/// exactly like the app working correctly and saying nothing.
void main() {
  final domainFiles = Directory('lib/domain')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('the domain layer has files to check', () {
    expect(domainFiles, isNotEmpty,
        reason: 'a passing purity check over zero files proves nothing');
  });

  const banned = <String, String>{
    'package:flutter': 'Flutter does not exist in a bare background isolate',
    'dart:io': 'the domain layer performs no I/O',
    'dart:ui': 'Flutter engine binding',
    'dart:isolate': 'the domain layer does not manage isolates',
    'cloud_firestore': 'Firestore lives in the Data layer',
    'firebase_': 'Firebase lives in the Data layer',
    'sqflite': 'LocalStore lives in the Data layer',
    'shared_preferences': 'ARCHITECTURE.md §4 forbids it outright',
    'timezone/standalone.dart': 'reads tzdata via dart:io — see TimeZones',
    'timezone/browser.dart': 'pulls package:http — see TimeZones',
    'DateTime.now(': 'the clock is a parameter',
    'DateTime.timestamp(': 'the clock is a parameter',
    '.toLocal(': 'an implicit read of a zone this design always states',
    'tz.local': "the device's own zone is never the day authority",
    'Stopwatch': 'wall-clock reads belong at the platform edge',
    'Timer(': 'nothing in the domain layer schedules itself',
    'Timer.': 'nothing in the domain layer schedules itself',
    // Returns a LOCAL DateTime — the same implicit-zone hazard as .toLocal(),
    // in a layer whose whole thesis is that the zone is stated explicitly.
    'DateTime.parse(': 'parses to the device zone unless the string has an offset',
  };

  // Bare identifiers, matched on word boundaries rather than as substrings.
  // `dart:core` exports these, so they arrive with no import for the allowlist
  // below to catch, and a domain layer that becomes asynchronous is a real
  // regression for a bare isolate with seconds to live. Word boundaries matter:
  // a substring ban on `await` also fires on `awaitingCheckIn`, which is how
  // this check first failed.
  final bannedWords = <String, String>{
    'Future': 'the domain layer is synchronous',
    'Stream': 'the domain layer is synchronous',
    'async': 'the domain layer is synchronous',
    'await': 'the domain layer is synchronous',
  };

  for (final file in domainFiles) {
    final relative = file.path.replaceAll(r'\', '/');

    group(relative, () {
      final code = _withoutComments(file.readAsStringSync());

      test('uses nothing a bare isolate cannot provide', () {
        final violations = [
          for (final entry in banned.entries)
            if (code.contains(entry.key)) '${entry.key} — ${entry.value}',
          for (final entry in bannedWords.entries)
            if (RegExp('\\b${entry.key}\\b').hasMatch(code))
              '${entry.key} — ${entry.value}',
        ];
        expect(violations, isEmpty,
            reason: 'banned in lib/domain:\n  ${violations.join("\n  ")}');
      });

      test('constructs DateTime only in UTC', () {
        // A bare `DateTime(y, m, d)` reads the DEVICE's local zone to compute
        // its epoch value. DayKey's arithmetic is correct only because it moves
        // in UTC; dropping `.utc` would silently reintroduce the DST drift the
        // type exists to prevent, and no other check here would notice.
        // The negative lookbehind is what keeps `tz.TZDateTime(zone, …)` out of
        // this — that constructor takes its zone explicitly and is exactly what
        // the layer is supposed to use.
        final bare = RegExp(r'(?<![A-Za-z0-9_])DateTime\(')
            .allMatches(code.replaceAll('DateTime.utc(', ''))
            .length;
        expect(bare, 0,
            reason: 'use DateTime.utc(...) — a bare DateTime() is device-local');
      });

      test('imports only dart:core-safe and pure-Dart packages', () {
        // Matches import AND export — domain.dart is a barrel, and an
        // `export 'package:...'` from it would re-export a plugin unchecked.
        //
        // Both quote styles, because `prefer_single_quotes` is not enabled in
        // analysis_options.yaml, so double quotes are legal here.
        //
        // No trailing `';` anchor, so conditional imports
        // (`import 'a.dart' if (dart.library.io) 'b.dart';`) and deferred
        // imports are caught too — the conditional form is the classic way
        // dart:io arrives.
        //
        final all = RegExp(
          '''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''',
          multiLine: true,
        ).allMatches(code).map((m) => m.group(1)!).toList();

        // A relative import does NOT have to stay inside the layer.
        // `import '../../data/local_store.dart'` contains no colon, so the
        // allowlist below would skip it, and the banned-substring pass only
        // ever reads files under lib/domain — so the whole Data layer, Flutter
        // and sqflite included, could walk in past a guard whose entire purpose
        // is to stop it. Resolve each one and assert it lands back inside.
        final dir = file.parent.path.replaceAll(r'\', '/');
        for (final uri in all.where((u) => !u.contains(':'))) {
          final resolved = Uri.parse('$dir/').resolve(uri).path;
          expect(
            resolved.contains('lib/domain/'),
            isTrue,
            reason:
                'relative import escapes the domain layer: $uri → $resolved',
          );
        }

        final imports = all.where((uri) => uri.contains(':'));

        for (final uri in imports) {
          expect(
            uri,
            anyOf(
              equals('package:timezone/timezone.dart'),
              equals('package:timezone/data/latest.dart'),
            ),
            reason: 'lib/domain may depend on package:timezone and nothing '
                'else. Adding a dependency here needs an ADR, not an import.',
          );
        }
      });
    });
  }
}

/// Strips comments so the ban list matches real code.
///
/// Without this the checks would fire on their own documentation — these files
/// discuss `DateTime.now()` and `standalone.dart` precisely because they must
/// not use them.
///
/// `://` is deliberately not treated as the start of a comment, so a line
/// carrying a URL inside a string literal is not truncated and hidden from the
/// ban list.
///
/// This is a lint, not a proof: it is substring-based, so `DateTime . now()`
/// would slip through. The import allowlist above is the part that fails
/// closed, and it is the one that matters.
String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final comment = RegExp(r'(?<!:)//').firstMatch(line);
      return comment == null ? line : line.substring(0, comment.start);
    })
    .join('\n');
