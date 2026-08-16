import '../domain/domain.dart';

/// **Everything the app says out loud.**
///
/// The approved set lives in [`docs/ui-ux/screens.md`][] and this file is its
/// code-side twin. The strings were written to avoid making claims the device
/// cannot support, so they are used **verbatim**: do not paraphrase, and do not
/// add a string here without adding it there and having `uiux-reviewer` see it.
///
/// This is a leaf library. It depends on the domain layer for the enums it
/// switches on and on nothing else, so both the Presentation layer and the
/// Platform edge can reach it without either depending on the other (§5).
///
/// Two conventions the warning set depends on, and which every future string
/// must respect:
///
/// - ***"No check-in…"* is a claim about her. *"Can't check on Mum —…"* is a
///   claim about us** — our phone, our access. The opening tells the reader
///   which kind of message this is before they read the detail, and the
///   collapsed notification shade shows one line, so the differentiator has to
///   be in the first words.
/// - **Every interpolated value can be null.** A device that has never had a
///   successful read has no "offline since" and no "last saw". Rendering
///   *"offline since null"* to a worried family is the failure the
///   never-reconciled variants exist to prevent.
///
/// [`docs/ui-ux/screens.md`]: ../../docs/ui-ux/screens.md
abstract final class NotificationCopy {
  // ------------------------------------------------------ watched: reminders

  /// The app's own name, used as the title of every reminder.
  ///
  /// The title is the app rather than the instruction because the collapsed
  /// shade shows the body, and repeating "I Am Ok" there would spend the one
  /// line the reader gets on something they already know.
  static const String reminderTitle = 'I Am Ok';

  /// The escalating 12:00 / 18:00 / 21:00 nudges (§10).
  ///
  /// **Escalating, not repeating.** Three identical notifications read as one
  /// message the phone failed to deliver twice; these read as the day going on.
  /// No exclamation marks and no emoji — the tone stays level, because the
  /// person reading it has done nothing wrong at midday.
  ///
  /// The last one names the consequence for the first time. It is the final
  /// nudge before the day closes and the watcher's alarm asks about it
  /// tomorrow, and a person who is told *why* at 21:00 has a reason to act that
  /// *"remember to tap"* does not give them.
  static String reminderBody(ReminderSlot slot) => switch (slot) {
        ReminderSlot.midday => 'Remember to tap I\'m OK today.',
        ReminderSlot.evening => 'You haven\'t tapped I\'m OK today.',
        ReminderSlot.night =>
          'Please tap I\'m OK before the day ends, so your family knows '
              'you\'re well.',
      };
}
