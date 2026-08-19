import 'package:flutter/material.dart';

/// The app's two themes, in one place both `main()` and the tests can reach.
///
/// **They were inline in `MaterialApp`**, which meant every widget test pumped
/// Flutter's default theme instead — so the contrast floor, which is a floor
/// about *these* colours, was asserted against colours the app does not use.
/// `docs/ui-ux/guidelines.md` requires WCAG AA for all text and AAA for the tap
/// target and any warning, **re-verified in dark mode**, and none of that was
/// verifiable while the palette lived in a widget constructor.
abstract final class AppTheme {
  /// The seed. One colour generates both schemes, which is what keeps the two
  /// modes from drifting into separately-tuned palettes.
  static const Color seed = Color(0xFF00658F);

  /// **Raised, because the default palette missed this app's own floor.**
  ///
  /// Measured on the shipped light scheme at the Material default of `0.0`:
  ///
  /// | Pair | Ratio | Required |
  /// |---|---|---|
  /// | warning text on the list | 6.16 | 7.0 (AAA) |
  /// | warning on a highlighted row | 5.01 | 7.0 (AAA) |
  /// | the tap target | 6.46 | 7.0 (AAA) |
  ///
  /// All three are the surfaces `guidelines.md` singles out for AAA rather than
  /// AA — the one thing an 80-year-old presses every day, and the line a family
  /// member reads at 3am after being told something is wrong. Dark mode already
  /// passed; light mode had never been checked, because the themes lived inline
  /// in `MaterialApp` and no test could reach them.
  ///
  /// At `0.5` every pair clears AAA with margin (warning 11.47, highlighted row
  /// 7.92, tap target 12.09). `1.0` goes further and looks harsh for a screen
  /// someone sees every morning; this is the middle Material setting, chosen
  /// because it clears the floor rather than because it maximises a number.
  ///
  /// `contrast_test.dart` holds these to it in both modes.
  ///
  /// Public so that test can assert both schemes are generated from [seed] at
  /// **this** level with nothing hand-tuned, without pinning the number itself —
  /// the ratio assertions are what hold the level, and a test that pinned `0.5`
  /// would fail on a legitimate *raise*.
  static const double contrastLevel = 0.5;

  static final ThemeData light = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      contrastLevel: contrastLevel,
    ),
    useMaterial3: true,
  );

  static final ThemeData dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      contrastLevel: contrastLevel,
    ),
    useMaterial3: true,
  );
}
