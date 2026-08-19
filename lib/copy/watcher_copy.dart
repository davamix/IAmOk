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
  ///
  /// **No *"yet"*.** Two reviewers struck it from the Tap screen's twin at the
  /// Phase 2 gate and it came back here. *"Yet"* asserts **not started**, which
  /// is false in the other state this same line covers: the last link was
  /// revoked, so something was set up and is not any more. One line has to be
  /// true in both, which is the whole reason it is deliberately one line.
  static const String nobody = 'You\'re not looking after anyone. '
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

  // ------------------------------------------------------------ this screen

  /// The initial load failed — the store could not be opened, or the first
  /// reconcile threw.
  ///
  /// **Not `TapCopy.couldNotStart`**, which this screen borrowed. That string
  /// ends *"Ask a family member for help."* and was written for an 80-year-old;
  /// `screens.md` approves it for the Tap screen only. Here the reader **is**
  /// the family member — the person who set the app up for everyone else — so
  /// it is a dead end pointing at themselves.
  ///
  /// It was worst in the state this screen exists for: the *lost access*
  /// notification promises *"Open the app to see what to do."*, the cold-start
  /// tap lands here, and a throw from a malformed cache row turned that promise
  /// into an instruction to ask oneself for help.
  static const String couldNotCheck =
      'This phone could not check on anyone. Try again, or open the app later.';

  static const String retry = 'Try again';

  // ------------------------------------------------- warnings switched off

  /// The reader has muted *Missed check-ins*, or `POST_NOTIFICATIONS` has been
  /// revoked from an app they never open.
  ///
  /// The twin of `TapCopy.notificationsOff`, on the side where the cost is
  /// larger. There it is a missed nudge; here it is a family not being warned,
  /// and §13 rates the revocation High precisely because Android takes the
  /// permission from apps nobody opens — which is the watcher, by design.
  ///
  /// **Needed because the row alone cannot say it.** A muted watcher who opens
  /// the app still sees the warning on the row, deals with it, closes the app,
  /// and goes on believing they will be told next time. This is the sentence
  /// that says otherwise, and it appears while they are looking — the one moment
  /// the app can still reach them.
  ///
  /// *"anyone"*, not a name: the channel is off for every watched person, and
  /// naming one would imply the others still work.
  static const String warningsOff =
      'This phone will not warn you about anyone.';

  /// The banner's action, mirroring the Tap screen's. Android stops showing the
  /// prompt after two refusals, at which point this is the honest dead end —
  /// the same trade `TapCopy.notificationsOffAction` already makes.
  static const String warningsOffAction = 'Turn warnings on';

  // ------------------------------------------------- this pass could not run

  /// The reconcile threw on this link and nothing about her state was computed.
  ///
  /// **A claim about us**, in ADR-0004's shape, because that is all the device
  /// can support — it does not know whether she checked in, only that it could
  /// not find out. *"No check-in from…"* would be a claim about her that
  /// nothing here backs.
  ///
  /// The row exists because the alternative was worse: a link left out of the
  /// list is invisible, and with one link that made the screen say *"You're not
  /// looking after anyone."* about someone the reader is still looking after.
  static String couldNotCheckOn(String watchedName) =>
      'Can\'t check on $watchedName — something went wrong on this phone.';

  /// Deliberately not *"you will not be warned"*: the alarm may well still be
  /// armed and the next fire may succeed, so that would overstate what is
  /// known. It names a next human on the second attempt, the same shape as
  /// [accessLostRemedy]'s dead-end case.
  static const String couldNotCheckRemedy =
      'It will try again. If this is still here tomorrow, ask whoever set up '
      'the app.';

  // ---------------------------------------------------------------- revoked

  /// The link has ended — `status` is no longer `accepted`.
  ///
  /// Added at the Phase 3 review, where a revoked link was found rendering
  /// **"Everything OK"**. Nothing is being checked, no warning can ever fire,
  /// and the row said the opposite in two words — the flattest false all-clear
  /// this screen is capable of.
  ///
  /// Echoes the screen title, *"People you're looking after"*: the title says
  /// what the list is, and this says this person has left it.
  ///
  /// Deliberately does not name who revoked it or when. The link carries
  /// neither, and inventing either is the same fault as stamping a correction
  /// with a tap time nobody recorded. Attribution is owed a decision in Phase 5,
  /// where pairing gives it something true to say.
  static String linkEnded(String watchedName) =>
      'You are no longer looking after $watchedName.';

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

  /// Spoken when a tapped notification opens the list on someone's row.
  ///
  /// The visual highlight is a background tint, and colour may never be the only
  /// signal. Flutter cannot place the screen reader's cursor on an arbitrary
  /// widget, so this answers the reader's actual question — *did this land on
  /// the person the notification was about* — and the row is scrolled into view
  /// for the next swipe to read in full.
  static String showingPerson(String watchedName) => 'Showing $watchedName.';
}
