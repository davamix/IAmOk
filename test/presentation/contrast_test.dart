import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/presentation/app_theme.dart';

/// **The contrast floor, against the palette the app actually ships.**
///
/// `docs/ui-ux/guidelines.md`: WCAG **AA for all text**, **AAA for the tap
/// target and any warning**, and *"re-verify in dark mode"*. None of that was
/// verifiable before — the themes lived inline in `MaterialApp`, so every widget
/// test pumped Flutter's defaults and asserted the floor against colours this
/// app does not use.
///
/// The reader here is 80 years old, or a family member at 3am, and the warning
/// is the one thing on the screen that must not be hard to read. That is why the
/// warning gets the AAA bar rather than AA.
///
/// Ratios are computed from the WCAG 2.x formula rather than taken from a
/// package, because it is eight lines and a dependency that silently changed its
/// rounding would be worse than no check.
void main() {
  /// Relative luminance, per WCAG 2.x.
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) as double;
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  /// The WCAG contrast ratio between two opaque colours, 1.0 to 21.0.
  double ratio(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// What the reader is looking at, as (foreground, background) pairs drawn
  /// from the real schemes.
  void checkScheme(String mode, ColorScheme scheme) {
    group(mode, () {
      test('body text on the surface meets AA', () {
        expect(ratio(scheme.onSurface, scheme.surface),
            greaterThanOrEqualTo(4.5));
      });

      test('the secondary lines meet AA', () {
        // `onSurfaceVariant` on `surface` — the "who will be notified" line on
        // the Tap screen. It was unasserted while `onSurface`/`surface` was
        // asserted twice under two names, which is one fact wearing two hats and
        // a real pair left uncovered.
        expect(ratio(scheme.onSurfaceVariant, scheme.surface),
            greaterThanOrEqualTo(4.5));
      });

      test('the DISABLED tap target meets AAA — it is the target most of the day',
          () {
        // `onSurfaceVariant` on `surfaceContainerHighest`: the state the Tap
        // screen is in from the moment she taps until midnight. Still the tap
        // target, so still the AAA bar rather than AA — the guideline names the
        // target, not the target's enabled state.
        expect(
          ratio(scheme.onSurfaceVariant, scheme.surfaceContainerHighest),
          greaterThanOrEqualTo(7.0),
        );
      });

      test('a WARNING meets AAA — the one line that must not be hard to read',
          () {
        // *"No check-in from Mum yesterday."* is `colorScheme.error` on the
        // list background, read by someone who has just been told something is
        // wrong about a relative.
        expect(ratio(scheme.error, scheme.surface), greaterThanOrEqualTo(7.0),
            reason: 'guidelines.md puts warnings at AAA, not AA');
      });

      test('the warnings-off banner meets AA', () {
        // `onErrorContainer` on `errorContainer`, both from the same seed.
        expect(ratio(scheme.onErrorContainer, scheme.errorContainer),
            greaterThanOrEqualTo(4.5));
      });

      test('the highlighted row keeps its text readable', () {
        // A tapped notification tints the row `surfaceContainerHighest`, and
        // the text on it is unchanged — so the tint must not eat the contrast
        // it was drawn against.
        expect(ratio(scheme.onSurface, scheme.surfaceContainerHighest),
            greaterThanOrEqualTo(4.5));
        expect(ratio(scheme.error, scheme.surfaceContainerHighest),
            greaterThanOrEqualTo(7.0),
            reason: 'a warning on a highlighted row is still a warning');
      });

      test('the tap target meets AAA', () {
        // The one thing an 80-year-old does every day, and the guideline calls
        // it out by name alongside warnings.
        expect(ratio(scheme.onPrimary, scheme.primary),
            greaterThanOrEqualTo(7.0));
      });
    });
  }

  checkScheme('light', AppTheme.light.colorScheme);
  checkScheme('dark', AppTheme.dark.colorScheme);

  test('the two modes come from one seed', () {
    // Two separately-tuned palettes is two things to keep above the floor, and
    // dark mode is the one that gets forgotten.
    expect(AppTheme.light.colorScheme.brightness, Brightness.light);
    expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);

    // **The seed itself, which this test named and did not check.** Asserting
    // only that the brightnesses differ passes for two hand-tuned palettes with
    // nothing in common — the exact thing the single seed exists to prevent, and
    // the reason `_contrastLevel` can be reasoned about once rather than twice.
    for (final scheme in [
      AppTheme.light.colorScheme,
      AppTheme.dark.colorScheme,
    ]) {
      expect(
        scheme,
        ColorScheme.fromSeed(
          seedColor: AppTheme.seed,
          brightness: scheme.brightness,
          // The declared level, not a pinned `0.5` — the ratio assertions above
          // are what hold the level itself, and a literal here would fail on a
          // legitimate raise while catching nothing extra.
          contrastLevel: AppTheme.contrastLevel,
        ),
        reason: 'both schemes are generated from AppTheme.seed at the raised '
            'contrast level, and nothing is overridden by hand',
      );
    }
  });
}
