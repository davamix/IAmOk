import '../domain/domain.dart';

/// The watcher list's words.
///
/// Approved copy lives in [`docs/ui-ux/screens.md`][]; this is its code-side
/// twin, like [TapCopy]. The reader here is a family member who may be opening
/// the app at 3am because a notification just told them something is wrong, so
/// the rules are the same: plain language, no jargon, no error codes, dates
/// written out.
///
/// **The warning rows reuse the notification bodies verbatim** rather than
/// having a parallel set of shorter list strings. Two sets would be two things
/// to keep true, reviewed separately, and the failure mode is the row and the
/// notification disagreeing about the same day — which is exactly the kind of
/// contradiction a worried reader cannot resolve. The slight redundancy of
/// naming the person in a row that already names them is the price.
///
/// [`docs/ui-ux/screens.md`]: ../../docs/ui-ux/screens.md
abstract final class WatcherCopy {
  /// The screen title. Echoes onboarding screen 2, *"Who are you looking
  /// after?"*, so the words that asked the question at setup answer it here —
  /// the same trick the Tap screen's audience line uses.
  static const String title = 'People you\'re looking after';

  /// Nobody is being watched.
  ///
  /// Same shape as `TapCopy.nobodyYet`, and for the same reason: a screen with
  /// no content and no explanation is its own silent failure. It names a next
  /// human, because the pairing flow assumes a family member sets up both
  /// phones.
  static const String nobody = 'You\'re not looking after anyone yet. '
      'Ask a family member to help you add someone.';

  /// The good state — **current state, never history**.
  ///
  /// `docs/ui-ux/guidelines.md`: a warning from three weeks ago followed by
  /// three weeks of check-ins is history, not status. So this shows whenever no
  /// warning is standing, regardless of what has happened before.
  static const String everythingOk = 'Everything OK';

  /// The last day this device managed to confirm a check-in.
  ///
  /// *"Your phone last saw"* phrasing, deliberately, for the reason ADR-0004
  /// gives about the notification: the date is the newest check-in **this
  /// device has read**, not the day she last tapped. During an access failure
  /// she may be tapping daily, and *"last checked in Saturday"* would read as a
  /// claim about her behaviour that nothing supports.
  static String lastSeen(String date) => 'Your phone last saw a check-in on '
      '$date.';

  /// No check-in has ever been read for this person.
  ///
  /// Not *"she has never checked in"*, which is unsupportable — the device may
  /// simply never have managed a successful read.
  static const String neverSeen = 'Your phone has not seen a check-in yet.';

  /// When this phone last managed a successful read — shown on **every** row,
  /// healthy or not.
  ///
  /// `screens.md` already specifies it for the stale row ("Last successful
  /// update, honestly dated"); it is shown always because the failure it exists
  /// to expose does not announce itself. A watcher whose app has been
  /// force-stopped goes deaf with every row still reading *"Everything OK"* —
  /// which is true of the last thing this phone managed to read, and says
  /// nothing about whether it has read anything since.
  ///
  /// This is the **surface** half of "accept, prevent and surface". §13's full
  /// health panel is Phase 7; this is the one row that makes the accepted risk
  /// visible in the meantime rather than a year from now.
  ///
  /// *"This phone last checked"*, never *"last updated"* — it is a fact about
  /// this device's own effort, not about her and not about the data.
  static String lastChecked(String when) => 'This phone last checked $when.';

  /// No successful read has ever happened on this device.
  ///
  /// Deliberately the same sentence the offline warning uses, so the two
  /// surfaces cannot drift into describing the same state differently.
  static const String neverChecked =
      'This phone has not been able to check even once.';

  // ------------------------------------------------------------ lost access

  /// §13's backend-access row, brought forward to Phase 3 as the destination
  /// the *lost access* notification opens onto.
  ///
  /// The notification says *"Open the app to see what to do."* ADR-0004 makes
  /// that actionability the whole reason the message exists as a fourth outcome
  /// rather than being folded into the offline one — so the tap has to land
  /// somewhere that says what to do. The full health panel is Phase 7; this row
  /// is the part of it this promise depends on.
  static String accessLostLabel(String watchedName) =>
      'Access to $watchedName\'s check-ins';

  /// Stated for every cause, because it is the part that matters to the reader
  /// and it is true whichever fault produced it.
  static String accessLostConsequence(String watchedName) =>
      'You will not be warned if $watchedName misses a day.';

  /// The remediation the refusal reason implies.
  ///
  /// The last case is a dead end otherwise, and naming a next human is the
  /// minimum honest exit — the same shape as `TapCopy.nobodyYet`. It is
  /// deliberately not *"contact support"*: there is no support desk, and
  /// whoever set the app up is a real person the reader can actually reach.
  static String accessLostRemedy(RefusedCause? cause) => switch (cause) {
        RefusedCause.unauthenticated => 'Sign in again.',
        RefusedCause.appCheckRejected => 'Update I Am Ok in the Play Store.',
        RefusedCause.permissionDenied ||
        RefusedCause.unknown ||
        null =>
          'Nothing can be fixed on this phone. If it is still red tomorrow, '
              'ask whoever set up the app.',
      };

  // ---------------------------------------------------------- spoken labels

  /// A row's TalkBack label.
  ///
  /// Names the person **and** their state, because a screen reader user gets
  /// the row as one utterance rather than as a heading with detail beneath it.
  /// The same rule as the tap target's label: state the thing and its current
  /// state, never just the thing.
  static String rowLabel(String watchedName, String status) =>
      '$watchedName. $status';

  /// Announced while the first reconcile runs.
  static const String loadingLabel = 'Checking';
}
