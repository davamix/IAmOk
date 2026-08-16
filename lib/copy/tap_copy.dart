/// The Tap screen's words — the only screen the watched person needs.
///
/// Approved copy lives in [`docs/ui-ux/screens.md`][]; this is its code-side
/// twin. Every string here is read by someone who may be 80 years old, so the
/// rules are stricter than elsewhere: plain language, no jargon, no emoji, no
/// exclamation marks, and dates written out rather than as `22/08`.
///
/// **Everything user-visible lives here, including the spoken labels and the
/// error strings.** The Phase 2 UI review found nine strings shipping as inline
/// literals in widgets, where nothing reviews them against `screens.md` — the
/// point of this library is that there is one place to look. A screen-reader
/// label is as user-visible as a headline, and for the reader who depends on it
/// there is nothing else.
///
/// [`docs/ui-ux/screens.md`]: ../../docs/ui-ux/screens.md
abstract final class TapCopy {
  /// The tap target. Short, and the same words the reminders and the audience
  /// line use, so *"tap I'm OK"* means one thing everywhere.
  static const String tapTarget = "I'm OK";

  /// The target's label once today's tap is recorded.
  ///
  /// The target changes **content**, not only colour. Previously it kept saying
  /// "I'm OK" and went grey, leaving the answer to *"did I tap?"* as small text
  /// at the far bottom of the screen — so she looks at the circle, sees the same
  /// two words, taps, gets nothing, and worries. That is the exact scenario the
  /// confirmed state exists to prevent, and colour alone was carrying it.
  static const String tapTargetDone = 'Tapped';

  /// After tapping, with the time the tap actually happened.
  ///
  /// The write is idempotent, so this is for the **person**, not the data:
  /// someone who cannot remember whether they tapped will tap again and worry.
  ///
  /// [time] is formatted by the device's own 12h/24h setting — never
  /// hard-coded — and rendered in the zone the tap was **made** in, which
  /// `CheckIn.timezone` records for exactly this reason. Using the device's
  /// current zone would show a wall-clock time she never saw after a flight.
  static String alreadyTapped(String time) =>
      'You already tapped today, at $time.';

  /// While an away period is active (§12). Tapping is still **allowed** —
  /// harmless, reassuring, and it writes a normal check-in.
  static String away(String lastDay) =>
      "You're away until $lastDay. Your family isn't expecting a check-in.";

  /// The Away control. Secondary, and not adjacent to the tap target.
  static const String awayAction = "I'm away";
  static const String notAwayAction = "I'm not away";

  // ------------------------------------------------------------- who is told

  /// **Who will be notified when she taps. That is all.**
  ///
  /// Decided at the Phase 1 gate. Nothing else about watchers is ever shown on
  /// this screen — no "X started watching you", no "Y stopped watching you".
  /// See `WatchedAudience` for the full rejection list and the reasoning.
  ///
  /// Deliberately mirrors onboarding screen 1, *"Who should know you're OK?"*,
  /// so the same words that asked the question at setup answer it every day.
  static String willKnow(List<String> names) =>
      '${nameList(names)} will know you\'re OK.';

  /// The empty case — **no watchers yet, or the last one revoked**.
  ///
  /// One line covering both states, and that is the decision rather than a
  /// limitation. The app can only distinguish them by tracking that someone
  /// *left*, and rendering that is the "someone stopped watching you" message
  /// the Phase 1 gate explicitly rejected. So this line never announces a
  /// change: it describes what is true now, in the same words, whichever way
  /// the screen arrived here.
  ///
  /// **It said "yet" until the Phase 2 review**, and both the UI and security
  /// reviewers caught the same thing independently: "yet" asserts *not started*,
  /// which is false in precisely the post-revocation state — something *was*
  /// set up and is not any more. Removing the word keeps one line for both
  /// states and stops it claiming a history the app does not track. It is not a
  /// re-proposal of anything rejected; it is the same line, made true in both
  /// states.
  ///
  /// It names a next human, which is the shape the health panel's dead-end row
  /// already uses (*"ask whoever set up the app"*) — the pairing flow assumes a
  /// family member sets up both phones, so this is the real next step.
  static const String nobodyYet = "No one is set up to know you're OK. "
      'Ask a family member to help you add someone.';

  /// Joins names the way a person would say them out loud.
  ///
  /// *"Ana"* · *"Ana and Beto"* · *"Ana, Beto and Carmen"*. No serial comma —
  /// the approved copy is British English throughout, and the list is read
  /// aloud by a screen reader as often as it is read on screen.
  static String nameList(List<String> names) => switch (names.length) {
        0 => '',
        1 => names.single,
        2 => '${names[0]} and ${names[1]}',
        _ => '${names.sublist(0, names.length - 1).join(', ')} '
            'and ${names.last}',
      };

  // ------------------------------------------------------------ spoken labels

  /// The tap target's TalkBack label, before today's tap.
  ///
  /// **Claims nothing about who will hear it.** It said *"Tap to tell your
  /// family you are OK"*, which asserts delivery — and with an empty audience
  /// the very next line on the same screen says nobody is set up. A label that
  /// contradicts the screen it is on is worse than a terse one, and the reader
  /// who depends on it cannot see the contradiction to discount it.
  static const String tapTargetLabel = 'Tap to say you are OK today';

  /// The tap target's TalkBack label once tapped.
  ///
  /// Carries the time, so a screen-reader user gets what a sighted user gets
  /// rather than a vaguer version of it.
  static String tapTargetLabelDone(String time) => alreadyTapped(time);

  /// Announced while the first reconcile runs. A bare spinner says nothing at
  /// all to TalkBack.
  static const String loadingLabel = 'Getting ready';

  // ------------------------------------------------------------------ trouble

  /// Shown when `POST_NOTIFICATIONS` is revoked and the app has already asked.
  ///
  /// §13's hard gate: without it this phone will not remind her, and the app is
  /// inert. It says what stops working and offers the action, because "ask a
  /// family member" is the **dead-end** wording and is only honest once there is
  /// nothing left to press.
  static const String notificationsOff =
      'This phone will not remind you to tap.';

  /// The banner's action. Requests the permission, or opens settings once
  /// Android will no longer show the prompt.
  static const String notificationsOffAction = 'Turn reminders on';

  /// The initial load failed — the store could not be opened, or the first
  /// reconcile threw. Says what happened and names a next human.
  static const String couldNotStart =
      'This phone could not get ready. Ask a family member for help.';

  static const String retry = 'Try again';

  /// **A failed tap, shown beneath a target that stays on screen and enabled.**
  ///
  /// Previously a throw from the tap path put the whole screen into its error
  /// state: she tapped, the screen she uses every morning vanished, and the
  /// message said the phone could not get ready — which was not true, because
  /// the phone was ready and it was the check-in that did not save. The only
  /// way out re-ran a reconcile rather than the tap, and her family would be
  /// warned the next morning with nothing having told her.
  static const String tapFailed = 'That did not save. Please tap again.';
}
