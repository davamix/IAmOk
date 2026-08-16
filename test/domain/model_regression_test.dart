@TestOn('vm')
library;

import 'package:test/test.dart';

// The model is plain Dart with no package imports, so importing it here costs
// the domain suite nothing.
import '../../tools/models/away_warning_model.dart' as model;

/// Runs `tools/models/away_warning_model.dart` inside `flutter test`.
///
/// The model is the executable specification the ADR-0001 ordering was settled
/// against, and its `superseded: 4 / decided: 0` result is the regression guard
/// for it. Until now that guard only ran when a human remembered to type
/// `dart run tools/models/away_warning_model.dart` — which is the shape of the
/// failure the Phase 0 summary already names about the secrets script: *a rule
/// with no assertion is a rule nobody notices losing.*
///
/// This does not duplicate `policy/away_warning_model_cases_test.dart`. That
/// file ports the cases to the real implementation; this one checks the
/// specification still says what the ADR claims it says.
void main() {
  test('the superseded ordering still fails the cases it failed', () {
    // If this ever reaches 0 the regression guard has stopped guarding —
    // most likely because someone "fixed" currentDesign, which PLAN.md
    // explicitly forbids: it is kept as the defect, not as a candidate.
    expect(model.runSuite('regression check', model.currentDesign), 4);
  });

  test('the decided ordering passes its own suite', () {
    expect(model.runSuite('regression check', model.decidedDesign), 0);
  });

  test('cancellation truncates, and deletes only when nothing has elapsed', () {
    // ADR-0001 decision 5, asserted against the model's own implementation so
    // the model and AwayPeriod.cancelOn cannot drift apart silently.
    final period =
        model.AwayPeriod(model.Day.iso('2026-08-01'), model.Day.iso('2026-08-20'));

    expect(model.applyCancel(period, model.Day.iso('2026-08-01')), isNull);
    final truncated = model.applyCancel(period, model.Day.iso('2026-08-05'))!;
    expect(truncated.through.ordinal, model.Day.iso('2026-08-04').ordinal);
  });
}
