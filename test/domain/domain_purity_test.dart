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

  /// Reads of the real clock, banned wherever a decision is made.
  ///
  /// Split out of [banned] so it can be applied **beyond** `lib/domain/` — see
  /// the second half of this file. The rule these encode is not "the domain
  /// layer is special", it is *the clock is a parameter to anything that
  /// decides*, and the layer boundary was only ever a proxy for that.
  const clockReads = <String, String>{
    'DateTime.now(': 'the clock is a parameter',
    'DateTime.timestamp(': 'the clock is a parameter',
    '.toLocal(': 'an implicit read of a zone this design always states',
    'tz.local': "the device's own zone is never the day authority",
    'Stopwatch': 'wall-clock reads belong at the platform edge',
    'Timer(': 'nothing that decides schedules itself',
    'Timer.': 'nothing that decides schedules itself',
    // Returns a LOCAL DateTime — the same implicit-zone hazard as .toLocal(),
    // in a codebase whose whole thesis is that the zone is stated explicitly.
    'DateTime.parse(': 'parses to the device zone unless the string has an offset',
  };

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
    ...clockReads,
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

  // ==========================================================================
  // The same clock rule, at EVERY layer.
  // ==========================================================================

  /// **The rule is "no clock read in a policy or the reconciler *anywhere*".**
  ///
  /// Until Phase 2 the guard above was the whole of it, and it only ever looked
  /// inside `lib/domain/`. That was sufficient while the domain layer was the
  /// only code there was. It stopped being sufficient the moment Phase 2
  /// introduced layers where `DateTime.now()` is legitimate — it is exactly what
  /// `Clock` is for at the platform edge — because the guard would not have
  /// noticed a policy or a reconciler drifting into `lib/data/` or
  /// `lib/application/` and reading the clock directly once it got there.
  ///
  /// The Phase 1 summary named this under *what to watch out for next*, and the
  /// Phase 2 brief carried it forward as a deliverable. It is deliberately keyed
  /// on the **path** rather than on the layer: anything named for deciding is
  /// held to the rule, wherever it lives.
  ///
  /// Only [clockReads] applies here. The import allowlist and the ban on
  /// `Future`/`async` are properties of the *domain layer* specifically — a
  /// service in `lib/application/` is legitimately asynchronous and legitimately
  /// imports Flutter — whereas reading the clock inside something that decides
  /// is wrong at any altitude.
  ///
  /// **This is an allowlist, not a path filter, and that is the second attempt.**
  /// The first selected files whose path contained `policy` or `reconcile`,
  /// which covers files by *name*: a Phase 3 alarm callback called
  /// `warning_alarm_handler.dart` would read `DateTime.now()` in a bare isolate
  /// — the exact place the rule exists for — while the guard went on reporting
  /// itself healthy. Scanning everything and naming the exemptions instead is a
  /// smaller rule, and it fails closed for every file added from here on.
  ///
  /// Exemptions are **per file and per banned key**, never whole-file.
  ///
  /// `tap_screen.dart` is the case that forced this: it legitimately holds a
  /// `Timer` to re-read the screen at local midnight, and a whole-file
  /// exemption for that would also have licensed a `DateTime.now()` in the same
  /// file forever after. Naming the key keeps the rest of the rule live.
  ///
  /// Each exemption is asserted to still be *needed*, so one that stops
  /// applying shows up as a stale entry rather than sitting there widening the
  /// guard quietly.
  const clockExemptions = <String, Map<String, String>>{
    'lib/platform/clock.dart': {
      'DateTime.now(':
          'the one sanctioned real-clock read — ADR-0002 decision 1',
    },
    'lib/presentation/debug_harness.dart': {
      'DateTime(': 'builds the date the harness forces the clock to',
    },
    'lib/presentation/tap_screen.dart': {
      'Timer(': 'refreshes the screen at local midnight, so a phone left on '
          'the charger does not keep showing "you already tapped today" on a '
          'day she has not. It schedules a REDRAW, not a decision, and it '
          'computes the wait from the injected Clock.',
    },
  };

  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('the clock is a parameter to anything that decides', () {
    test('there are files to check, past lib/domain', () {
      // A rule that silently matches nothing is a rule nobody notices losing —
      // the shape of the Phase 0 finding about the secrets script, and of
      // Phase 1's finding that nothing ran the away model inside `flutter test`.
      expect(libFiles, isNotEmpty);
      expect(
        libFiles.any((f) => !_path(f).contains('lib/domain/')),
        isTrue,
        reason: 'this must reach past lib/domain — that is what Phase 2 '
            'widened it for',
      );
    });

    test('every exemption still exists and is still needed', () {
      clockExemptions.forEach((path, keys) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: 'exemption for a file that is gone silently widens the '
                'guard: $path');

        final code = _withoutComments(file.readAsStringSync());
        for (final key in keys.keys) {
          expect(code.contains(key), isTrue,
              reason: '$path no longer uses "$key" — drop the exemption '
                  'rather than leaving the hole open');
        }
      });
    });

    for (final file in libFiles) {
      final relative = _path(file);
      final exempt = clockExemptions[relative] ?? const <String, String>{};

      test('$relative reads no clock', () {
        final code = _withoutComments(file.readAsStringSync());
        final violations = [
          for (final entry in clockReads.entries)
            if (!exempt.containsKey(entry.key) && code.contains(entry.key))
              '${entry.key} — ${entry.value}',
        ];
        expect(violations, isEmpty,
            reason: 'the clock is injected, never read:\n'
                '  ${violations.join("\n  ")}');
      });
    }
  });

  /// Files that must run in a **bare background isolate**, checked for the
  /// things that are not there.
  ///
  /// Beyond the clock: outside `lib/domain/` the guard applies only
  /// [clockReads], which is right for `Future`/`async` — but nothing otherwise
  /// stops the reconcile service importing `package:flutter` tomorrow. It would
  /// pass the clock check and then throw in the isolate that cannot report
  /// anything.
  const bareIsolateSafe = <String>[
    'lib/application/watched_reconcile_service.dart',
    'lib/data/local_store.dart',
    'lib/platform/clock.dart',
    'lib/platform/alarm_ids.dart',
  ];

  group('runs in a bare isolate', () {
    for (final path in bareIsolateSafe) {
      test('$path imports nothing an isolate cannot provide', () {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'listed but missing: $path');

        final code = _withoutComments(file.readAsStringSync());
        for (final banned in const [
          'package:flutter/',
          'package:flutter_riverpod',
          'dart:ui',
          'flutter_timezone',
        ]) {
          expect(code.contains(banned), isFalse,
              reason: '$path must not reach $banned — it runs where there is '
                  'no widget tree and no plugin registrant');
        }
      });
    }
  });
}

String _path(File file) => file.path.replaceAll(r'\', '/');

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
