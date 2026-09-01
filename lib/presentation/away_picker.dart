import 'package:flutter/material.dart';

import '../copy/away_copy.dart';
import '../domain/domain.dart';

/// The away picker (§12, `screens.md`).
///
/// Returns the chosen **last away day**, or null when dismissed.
///
/// ## It collects one date, and that is the design rather than a limitation
///
/// `from` is **always today**: no retroactive away, and no future-dating in v1
/// (§12, ADR-0001 decision 6). So there is one day to choose and the screen asks
/// for exactly it — a range picker would offer a start date the app then
/// silently overrides, which is a control that lies about what it does.
///
/// ## The two labels are frozen, and they are the whole point of this screen
///
/// *"Last day away: Saturday 22"* and *"Back on Sunday 23"* — PLAN.md's
/// *Calendar copy* line, carried in `screens.md` since Phase 3. *"Until
/// Saturday"* alone is ambiguous about whether Saturday still needs a tap, and
/// the second sentence is what settles it. They are rendered **live, beneath the
/// calendar**, because a label that only appears after confirming is not
/// disambiguating the choice, it is describing a choice already made.
///
/// ## A screen, not a dialog
///
/// `guidelines.md`'s floor is the largest system font scale with no clipping,
/// and a calendar plus two sentences plus a 48dp action does not fit a dialog
/// at scale 2.0 on a small phone — it would clip, silently, in release, which is
/// the defect the Phase 5 gate found in the *Add someone* sheet. A full screen
/// scrolls instead.
///
/// ## The bound is the cap, taken from the domain
///
/// `lastDate` is `today + AwayRules.maxDaysAhead`, so the longest period the
/// picker can produce is exactly the 31 days §12 allows, counting today. The
/// screen therefore cannot offer a day the client's own validation would refuse
/// — which is why `AwayRefusal.rejectedPeriod` is reachable only by the clock
/// moving underneath the reader, and not by anything they can press.
class AwayPickerScreen extends StatefulWidget {
  const AwayPickerScreen({
    required this.today,
    this.initialLastDay,
    this.personName,
    super.key,
  });

  /// Today in the **watched person's** zone, resolved by the reconcile that
  /// built the screen this was opened from.
  ///
  /// A parameter rather than a clock read, for the reason the domain purity
  /// guard enforces one layer down: the day this app decides about is a label in
  /// somebody's timezone, and a widget reaching for `DateTime.now()` would be a
  /// second answer to a question already settled.
  final DayKey today;

  /// The day to open on.
  ///
  /// **Not reachable with a period in force in v1, and the docstring used to
  /// say otherwise.** Both surfaces flip their control to *end* while away, so
  /// this screen is only ever opened when no period covers today — and what
  /// reaches here is therefore an *ended* period's last day, which `_openOn`
  /// clamps forward to today.
  ///
  /// It stays a parameter because §12 says away may be **extended** and
  /// `AwayRules.validateUpdate` exists for exactly that; the surface that would
  /// reach it is owed a decision, recorded in `screens.md`. When it lands, this
  /// is where it plugs in.
  final DayKey? initialLastDay;

  /// Whose away period this is, when it is **not** the reader's own.
  ///
  /// Null on the Tap screen, where the reader is the subject and the title says
  /// *"you"*. Set on the watcher's row, where it does not: the device run on
  /// 2026-09-01 watched Ana open this from *"Mark Mum away"* and be asked about
  /// herself. A parameter rather than a lookup because this widget takes its
  /// inputs and holds no decisions — the same rule as [today], which is the
  /// watched person's day and not the reader's.
  final String? personName;

  /// The title, which is about whoever the period belongs to.
  String get title {
    final name = personName;
    return name == null
        ? AwayCopy.pickerTitle
        : AwayCopy.pickerTitleFor(name);
  }

  static const Key calendarKey = Key('away-picker-calendar');
  static const Key saveKey = Key('away-picker-save');
  static const Key cancelKey = Key('away-picker-cancel');

  /// The last day this picker may offer. See the class docstring.
  DayKey get lastSelectable => today.plusDays(AwayRules.maxDaysAhead);

  @override
  State<AwayPickerScreen> createState() => _AwayPickerScreenState();
}

class _AwayPickerScreenState extends State<AwayPickerScreen> {
  late DayKey _selected = _openOn();

  /// Clamped into range rather than trusted.
  ///
  /// A stored period can reach past the picker's bound — the Firestore rules are
  /// deliberately slacker than `AwayRules`, so a period the server accepted may
  /// be a day or two beyond what this screen can offer. `CalendarDatePicker`
  /// asserts on an `initialDate` outside its own bounds, so an unclamped value
  /// would crash the screen for exactly the family whose period sits on the
  /// boundary.
  DayKey _openOn() {
    final requested = widget.initialLastDay ?? widget.today;
    if (requested < widget.today) return widget.today;
    if (requested > widget.lastSelectable) return widget.lastSelectable;
    return requested;
  }

  DateTime _asDateTime(DayKey day) => DateTime(day.year, day.month, day.day);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastDay = AwayCopy.dayAndDate(_selected);
    final firstBack = AwayCopy.dayAndDate(_selected.next);

    return Scaffold(
      // **A bare bar, and the title is in the body.** `AppBar` wraps its title
      // in `softWrap: false, overflow: ellipsis` and clamps text scaling at
      // 1.34 — so *"Choose the last day you are away"* truncates on an ordinary
      // 360dp phone at scale 1.0, and the half that gets cut is the word
      // **last**, which is the entire reason the title is worded this way. A
      // bar that refuses to honour the system font scale also breaks
      // `guidelines.md`'s floor outright.
      appBar: AppBar(),
      body: SafeArea(
        // **No horizontal padding here.** `CalendarDatePicker` adds its own
        // 12dp each side and divides what is left by seven, so 16dp here made
        // each day cell `(width - 56) / 7` — below the 48dp floor on any phone
        // narrower than 392dp, which is most of them, on the only control this
        // screen exists for. The padding is on the children instead.
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  widget.title,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              CalendarDatePicker(
                key: AwayPickerScreen.calendarKey,
                initialDate: _asDateTime(_openOn()),
                firstDate: _asDateTime(widget.today),
                lastDate: _asDateTime(widget.lastSelectable),
                onDateChanged: (picked) => setState(() {
                  _selected = DayKey(picked.year, picked.month, picked.day);
                }),
              ),
              const SizedBox(height: 16),

              // **Both sentences, together, as one utterance to a screen
              // reader.** The second is what disambiguates the first, so a
              // reader who got only one of them would be back where "until
              // Saturday" left them. `MergeSemantics` is what makes the pair a
              // single stop rather than two swipes.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MergeSemantics(
                  child: Semantics(
                    liveRegion: true,
                    label: AwayCopy.pickerLabel(lastDay, firstBack),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            AwayCopy.lastDayAway(lastDay),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            AwayCopy.backOn(firstBack),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton(
                  key: AwayPickerScreen.saveKey,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text(AwayCopy.save),
                ),
              ),
              const SizedBox(height: 8),
              // A dismissal is a choice, not a fault, and it says nothing —
              // the same decision `screens.md` records for the Add someone
              // chooser. Present as a control as well as a back gesture,
              // because `guidelines.md` forbids a gesture being the only route.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextButton(
                  key: AwayPickerScreen.cancelKey,
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(AwayCopy.cancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
