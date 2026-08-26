import 'package:timezone/timezone.dart' as tz;

import '../domain/domain.dart';
import 'notification_copy.dart';
import 'tap_copy.dart';

/// Onboarding, sign-in and pairing — every word of them.
///
/// Approved copy lives in [`docs/ui-ux/screens.md`][]; this is its code-side
/// twin, and the same rule applies as on the Tap screen: **a user-visible
/// literal inline in a widget is a review failure**, screen-reader labels
/// included, because they are as user-visible as a headline and are the only
/// thing some readers get.
///
/// ## Two audiences read these screens, and only one of them is the elderly user
///
/// `guidelines.md` splits the app between someone who may not be comfortable
/// with phones and a busy family member. Onboarding is the one flow **both** of
/// them see, in the same words — PLAN.md fixes that: three screens, identical
/// for every user, because role is never asked directly. *"Are you the elderly
/// one?"* is a question nobody wants to answer.
///
/// So the floor is the stricter of the two audiences throughout: short
/// sentences, no jargon, nothing that assumes the reader knows what a code or an
/// account is for.
///
/// ## The pairing flow assumes one sitting
///
/// `screens.md`: *"realistically the family member sets up both phones in one
/// sitting; the pairing flow should assume that rather than assuming two people
/// configuring independently."* Everything below follows from it — the code is
/// sized to be read across a table, the waiting line says what to do on the
/// *other* phone, and the confirmation appears on the phone that produced the
/// code rather than only on the one that typed it.
///
/// [`docs/ui-ux/screens.md`]: ../../docs/ui-ux/screens.md
abstract final class OnboardingCopy {
  // ------------------------------------------------------------------ sign-in

  /// The first thing anybody sees.
  ///
  /// **A sign-in screen is new in Phase 5 and the screen inventory never
  /// specified one.** Phase 4 signed in from the debug harness precisely so that
  /// no un-approved elderly-facing surface shipped early. It cannot be avoided
  /// here: every link is keyed by a uid, `createInvite` needs one to name the
  /// watched party and `redeemInvite` needs one to be the watcher.
  static const String signInTitle = 'I Am Ok';

  /// What the app is, in the two sentences somebody needs before signing in.
  ///
  /// Deliberately does **not** say "your family will be notified" — at this
  /// point nobody is set up, and a promise the next screen has to walk back is
  /// worse than a plain description. Same rule as `TapCopy.tapTargetLabel`,
  /// which stopped saying "tell your family" for exactly this reason.
  static const String signInBlurb =
      'Tap once a day to say you are OK. The people you choose are told if a '
      'day goes by without a tap.';

  static const String signInAction = 'Sign in with Google';

  /// Sign-in failed for a reason that is not a dismissal.
  ///
  /// A dismissal is a **choice, not a fault** — `AuthRepository.signIn` returns
  /// null for it and nothing is shown. This is for the rest.
  static const String signInFailed =
      'Could not sign in. Check your internet connection and try again.';

  /// Signed in, but `users/{uid}` could not be written.
  ///
  /// Its own message because it is its own state: the account exists and the app
  /// still cannot pair anybody, since `redeemInvite` copies the name and the
  /// timezone off that document onto the link (§7). Saying "could not sign in"
  /// here would send somebody to re-try the one part that worked.
  static const String profileFailed =
      'Signed in, but this phone could not finish getting ready. Try again.';

  static const String tryAgain = 'Try again';

  // ---------------------------------------------------------------- screen one

  /// PLAN.md fixes this heading. Role falls out of the answer.
  static const String watchedQuestion = "Who should know you're OK?";

  static const String watchedBlurb =
      'Add the people who look after you. They will see that you are OK each '
      'day, and they are told if a day goes by without a tap.';

  static const String watchedAction = 'Add someone';

  // ---------------------------------------------------------------- screen two

  /// PLAN.md fixes this heading too.
  static const String watcherQuestion = 'Who are you looking after?';

  static const String watcherBlurb =
      'If someone has given you a code, type it in here. You will be told if '
      'they miss a day.';

  static const String watcherAction = 'I have a code';

  /// Both screens' skip, in the same words on both.
  ///
  /// *"for now"* is deliberate and is the opposite of the choice
  /// `TapCopy.nobodyYet` made when it dropped *"yet"*. There the word asserted a
  /// history the app does not track; here it describes the button honestly — the
  /// question really can be answered later, from either main screen.
  static const String skip = 'Skip for now';

  // -------------------------------------------------------- making a code

  static const String yourCodeTitle = 'Your code';

  /// Said on the phone that produced the code, to the person holding it.
  static const String yourCodeBlurb =
      'Give this code to the person who will look after you. They type it into '
      'their own phone.';

  /// When the code stops working — the owner chose 24 hours.
  ///
  /// Rendered through `NotificationCopy`'s formatters rather than a third one of
  /// its own. That file records why: this app had **three** separate ways of
  /// turning an instant into a time, and the Tap screen's produced *"9:14 AM"*
  /// against everywhere else's *"9:14 am"*. One formatter is one thing to keep
  /// true.
  ///
  /// The date is written out and the time follows the device's own 12h/24h
  /// setting, which is what `guidelines.md` requires of both.
  static String codeExpiry({
    required DateTime expiresAt,
    required tz.Location zone,
    required bool uses24Hour,
  }) {
    final day = DayKey.fromInstant(expiresAt, zone);
    final time = NotificationCopy.timeLabel(expiresAt, zone, uses24Hour);
    return 'It stops working at $time on ${NotificationCopy.dayLabel(day)}.';
  }

  static const String shareCode = 'Share this code';

  /// The subject line when the code goes out through the Android share sheet.
  static String shareMessage(String code) =>
      'Use this code in the I Am Ok app to look after me: '
      '${InviteCode.forReading(code)}';

  /// While nobody has redeemed it yet.
  ///
  /// **Present tense and about the other phone**, because in the sitting this
  /// flow assumes, the other phone is on the table. It claims nothing about
  /// whether the code has been *read* — only what this phone is waiting for.
  static const String waitingForCode = 'Waiting for them to type it in.';

  /// Somebody redeemed it.
  ///
  /// Reuses `TapCopy.willKnow`'s sentence shape on purpose: the words that
  /// confirm the pairing are the words the Tap screen will show every day
  /// afterwards, so the confirmation and the daily screen agree.
  static String nowWatching(String watcherName) =>
      "$watcherName will now know you're OK.";

  static const String addAnother = 'Add someone else';

  static const String done = 'Done';

  /// The code could not be made. One sentence per reason, and every one says
  /// what to do next.
  static String inviteRefusal(InviteRefusal reason) => switch (reason) {
        InviteRefusal.profileMissing =>
          'This phone could not finish getting ready. Try again.',
        // Distinct from every refusal: nothing was decided, so "try again" is
        // the whole of the advice and no other sentence would be true.
        InviteRefusal.couldNotReach =>
          'Could not reach the internet. Check your connection and try again.',
        InviteRefusal.notSignedIn => 'You are not signed in. Sign in and try again.',
      };

  // -------------------------------------------------------- using a code

  static const String enterCodeTitle = 'Type the code';

  static const String enterCodeBlurb =
      'Type the six characters you were given.';

  /// The field's label, and its TalkBack label.
  static const String codeFieldLabel = 'Code';

  static const String useCode = 'Use this code';

  /// Paired, said on the phone that typed the code.
  static String nowLookingAfter(String watchedName) =>
      'You are now looking after $watchedName.';

  /// Why a code did not work. **Every branch is a claim**, so each says only
  /// what this phone actually knows, and each names a next action.
  static String pairingRefusal(PairingRefusal reason) => switch (reason) {
        // The two a person can fix by looking at the code again.
        PairingRefusal.unknownCode =>
          'That code is not right. Check it and type it again.',
        PairingRefusal.expired => 'That code has expired. Ask for a new one.',
        PairingRefusal.alreadyUsed =>
          'That code has already been used. Ask for a new one.',
        // Their own code. Naming the mistake is what stops them typing it again.
        PairingRefusal.ownCode =>
          'That is your own code. Ask the person you are looking after for '
              'theirs.',
        // Not the reader's mistake, and not fixable by re-typing. Both of these
        // are fixed on the OTHER phone, so that is where the sentence points.
        PairingRefusal.watchedProfileMissing ||
        PairingRefusal.unusableTimezone =>
          'That code did not work. Ask them to open I Am Ok on their phone, '
              'then try again.',
        PairingRefusal.watcherProfileMissing =>
          'This phone could not finish getting ready. Try again.',
        PairingRefusal.couldNotReach =>
          'Could not reach the internet. Check your connection and try again.',
        PairingRefusal.notSignedIn => 'You are not signed in. Sign in and try again.',
      };

  // -------------------------------------------------------------- screen three

  static const String summaryTitle = "You're all set";

  /// What was actually set up, in the reader's own terms.
  ///
  /// Built from the **links that exist**, never from what they tapped: someone
  /// who chose "Add someone" and then closed the code screen has set nothing up,
  /// and a summary claiming otherwise would be the first false claim this app
  /// ever made to a family. [HomeRoute] unions intent with evidence to decide
  /// *where to go*; this line reports evidence only.
  static String summaryWatched(List<String> watcherNames) =>
      '${TapCopy.nameList(watcherNames)} will know you are OK when you tap '
      'each day.';

  static String summaryWatching(List<String> watchedNames) =>
      'You will be told if ${TapCopy.nameList(watchedNames)} misses a day.';

  /// Several watched people, so the verb changes.
  static String summaryWatchingMany(List<String> watchedNames) =>
      'You will be told if ${TapCopy.nameList(watchedNames)} miss a day.';

  /// Nothing was set up — both skipped, or a pairing that never completed.
  ///
  /// **Says nothing is set up and offers the way to change it.** The Tap screen's
  /// own empty line names a next human instead, because until Phase 5 there was
  /// nothing left to press; here there is, and `TapCopy.notificationsOff` records
  /// the rule this follows — *"ask a family member" is the dead-end wording and
  /// is only honest once there is nothing left to press*.
  static const String summaryNothing =
      'Nobody is set up yet. You can add someone at any time.';

  /// This phone could not read back what was set up.
  ///
  /// **Its own sentence, because the alternative is silence.** Without it a
  /// failed read renders as the empty state — *"Nobody is set up yet"* — which is
  /// a claim about the account made by a device that just failed to find out.
  /// Somebody who has in fact paired would be told they had not.
  ///
  /// It claims nothing either way and names the screen that can answer, which is
  /// the same shape as the four warning messages: say what is actually known.
  static const String summaryUnknown =
      'This phone could not check what is set up. Your main screen will show it.';

  /// The one instruction the watched person needs, and the last thing they read.
  static const String summaryTapDaily = 'Tap once a day. That is all.';

  static const String finish = 'Finish';

  // --------------------------------------------------------- getting back here

  /// Reaches pairing again from either main screen.
  ///
  /// The route back exists because without it someone who skipped both questions
  /// lands on a Tap screen naming nobody with nothing to press, and a second
  /// watcher could never be added at all.
  static const String addSomeone = 'Add someone';

}
