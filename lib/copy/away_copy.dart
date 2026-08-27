import '../domain/domain.dart';

/// The away picker's words, and what the app says when a period cannot be set.
///
/// Approved copy lives in [`docs/ui-ux/screens.md`][]; this is its code-side
/// twin, and the same rules apply as in [TapCopy]: plain language, no jargon,
/// no emoji, no exclamation marks, dates written out rather than as `22/08`.
///
/// **Two strings here are frozen and were approved long before this phase** —
/// [lastDayAway] and [backOn]. PLAN.md fixed them in the *Calendar copy* line
/// and `screens.md` has carried them since Phase 3, because *"until Saturday"*
/// alone is ambiguous about whether Saturday still needs a tap. Do not reword
/// them; the ambiguity they remove is the whole reason they are exact.
///
/// [`docs/ui-ux/screens.md`]: ../../docs/ui-ux/screens.md
abstract final class AwayCopy {
  // ------------------------------------------------------------- the picker

  /// The picker's title.
  ///
  /// It names **the last away day**, not a range and not a return date, because
  /// that is the single thing this screen collects: `from` is always today and
  /// there is no future-dating in v1 (§12, ADR-0001 decision 6). A title
  /// offering a choice the screen cannot make is a promise it then breaks.
  static const String pickerTitle = 'Choose the last day you are away';

  /// *"Last day away: Saturday 22"* — **frozen**, and half of the pair that
  /// removes the ambiguity in "until".
  static String lastDayAway(String date) => 'Last day away: $date';

  /// *"Back on Sunday 23"* — **frozen**. The other half: it answers *"so do I
  /// need to tap on Saturday?"* without the reader having to work it out.
  static String backOn(String date) => 'Back on $date';

  /// The picker's confirm action.
  ///
  /// A control's label says what pressing it **does** — the rule `screens.md`
  /// recorded when the watcher-list control stopped reusing a screen title. The
  /// day is already stated twice above the button, so the button does not
  /// restate it.
  static const String save = 'Save';

  /// The picker's dismiss action. A dismissal is a choice, not a fault, and it
  /// says nothing to anybody — the same decision `screens.md` records by hand
  /// for the *Add someone* chooser and the Google account chooser.
  static const String cancel = 'Not now';

  /// The picker's TalkBack label for the chosen day.
  ///
  /// Carries **both** sentences, because a screen-reader user gets what a
  /// sighted user gets rather than a vaguer version of it — and the second
  /// sentence is the one that disambiguates the first.
  static String pickerLabel(String lastDay, String firstDayBack) =>
      '${lastDayAway(lastDay)}. ${backOn(firstDayBack)}.';

  // ------------------------------------------------------------- the outcome

  /// The away period reached the server.
  ///
  /// Nothing is said on this path — the Tap screen's own away line is the
  /// confirmation, and it is a better one than a toast because it is still
  /// there tomorrow. Present as a named constant so the absence is a decision
  /// somebody made rather than a case somebody missed.
  static const String? saved = null;

  /// The write did not confirm in time, so Firestore is holding it.
  ///
  /// **Not a failure, and it must not read like one.** §8 chose a direct client
  /// write precisely so this works — *"a watcher can set away on a plane and
  /// have it queue offline like any other write"* — and the SDK replays it when
  /// the connection returns. See [AwayOutcome] for why *"could not reach the
  /// server"* is a sentence this path can never truthfully say.
  ///
  /// It says **saved** first, because that is the part the reader needs, and it
  /// claims nothing about when — *"when this phone is back online"* is the only
  /// honest bound, and it is true whether the delay is two seconds or two days.
  static const String queued =
      'Saved. Your family will see this when this phone is back online.';

  /// What a refused away write says. One sentence per cause — the rule
  /// ADR-0004 sets out for the warnings, applied here: a refusal that names the
  /// wrong cause names the wrong remedy, and a remedy that cannot work is worse
  /// than none.
  ///
  /// **Exhaustive on purpose**, like `PairingRefusalSurface.isAboutTheCode`: a
  /// refusal added later cannot default into somebody else's sentence, because
  /// the switch stops compiling until somebody decides.
  static String refusal(AwayRefusal refusal) => switch (refusal) {
        // Reachable by the CLOCK rather than by the picker, which is bounded to
        // the same rule — a device whose date moves between opening the picker
        // and confirming it. So it names the bound rather than blaming the
        // reader for a day the screen offered them.
        AwayRefusal.rejectedPeriod =>
          'That day does not work. Choose a day in the next month.',
        // The server answered, and said no. A claim about **access**, never
        // about the device: the phone demonstrably reached the backend, because
        // it got an answer. ADR-0004, one layer down.
        AwayRefusal.notPermitted =>
          'That could not be saved. I Am Ok is no longer allowed to change '
              'this.',
        // `PairingRefusal.serverFault`'s sentence, **verbatim**, because it is
        // the same claim about the same situation and the Phase 5 gate approved
        // exactly these words for it. A sibling sentence tuned in isolation
        // would be a second way of saying one thing.
        AwayRefusal.serverFault =>
          'That did not work just now. Try again in a moment.',
        AwayRefusal.notSignedIn =>
          'You are not signed in. Sign in and try again.',
      };

  // ------------------------------------------------------------------- dates

  /// *"Saturday 22"* — weekday and day of the month, no month name.
  ///
  /// The form the two frozen picker strings are written in. The month is left
  /// off deliberately: the picker never offers a day more than 30 ahead, so the
  /// weekday and the number are unambiguous to the reader who is looking at a
  /// calendar showing them.
  static String dayAndDate(DayKey day) {
    final at = day.at(const LocalTimeOfDay(12, 0), TimeZones.utc);
    return '${_weekdays[at.weekday - 1]} ${day.day}';
  }

  /// *"Sat 22 Aug"* — the abbreviated form the **watcher's** row uses.
  ///
  /// Shorter than [NotificationCopy.dayLabel]'s *"Saturday 22 August"* because
  /// it sits inside a row alongside a name and a status, where the long form
  /// pushes the line to wrap at the font scales this app is built for. It keeps
  /// the month, unlike [dayAndDate], because a watcher reading it has no
  /// calendar in front of them.
  static String shortDate(DayKey day) {
    final at = day.at(const LocalTimeOfDay(12, 0), TimeZones.utc);
    return '${_weekdays[at.weekday - 1].substring(0, 3)} ${day.day} '
        '${_months[day.month - 1].substring(0, 3)}';
  }

  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}
