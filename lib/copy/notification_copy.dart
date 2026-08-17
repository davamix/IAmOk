import 'package:timezone/timezone.dart' as tz;

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

  // ------------------------------------------------------- watcher: warnings

  /// The title of **every** warning, correction and access notice.
  ///
  /// Settled at the Phase 3 gate: the split is the reminders' split, so the
  /// whole approved line is the body and the differentiator stays in its first
  /// words. Android's collapsed shade truncates the body, and *"No check-in
  /// received from Mum yesterday — your…"* still tells the reader which kind of
  /// claim this is. Putting the claim in the title instead was considered and
  /// rejected: it splits four approved strings into eight and takes the app's
  /// name off the one line a worried reader at 3am can use to tell who is
  /// speaking.
  static const String warningTitle = reminderTitle;

  /// The body for one warning outcome, rendered from what the device actually
  /// knows.
  ///
  /// **Which one fires is a correctness requirement**, not copy polish — §10's
  /// asymmetry rates a false claim to a family as the worst bug this app can
  /// have. So this switch is exhaustive over [WarningOutcome] with no default:
  /// a fifth outcome added later is a compile error here rather than a silently
  /// missing message.
  ///
  /// [WarningOutcome.silent] has no body and asking for one is a programming
  /// error, so it throws rather than returning something harmless. A silent
  /// decision that reached a notification is a bug that must not be smoothed
  /// over into a spurious warning.
  static String warningBody({
    required WarningOutcome outcome,
    required String watchedName,
    required DayKey day,
    AwayPeriod? away,
    DateTime? unverifiedSince,
    DayKey? lastConfirmedDay,
    required tz.Location watcherZone,
  }) =>
      switch (outcome) {
        WarningOutcome.silent => throw ArgumentError(
            'silent has no message; a silent decision must not reach the '
            'notification layer',
          ),
        WarningOutcome.warnOnline => 'No check-in from $watchedName yesterday.',
        WarningOutcome.warnOffline => 'No check-in received from $watchedName '
            'yesterday — ${_offlineClause(unverifiedSince, watcherZone)}',
        WarningOutcome.warnUnverifiableAway =>
          'Can\'t check on $watchedName — '
              '${_offlineClause(unverifiedSince, watcherZone)} '
              '${_awayClause(watchedName, away)}',
        WarningOutcome.warnAccessLost => _accessLostBody(
            watchedName: watchedName,
            away: away,
            lastConfirmedDay: lastConfirmedDay,
          ),
      };

  /// *"your phone has been offline since 22:10."* — or the never-reconciled
  /// variant.
  ///
  /// **Every interpolated value here can be null**, and this is the one that
  /// bites: a watcher whose device has never had a successful read has no
  /// "offline since". Rendering *"offline since null"* to a worried family is
  /// the failure the variants exist to prevent, which is why the null case is a
  /// different sentence rather than a formatting fallback.
  static String _offlineClause(DateTime? since, tz.Location zone) =>
      since == null
          ? 'your phone has not been able to check even once.'
          : 'your phone has been offline since ${_moment(since, zone)}.';

  /// *"Mum was marked away until Saturday 22 August."*
  ///
  /// Settled at the Phase 3 gate: the name, never *"She"*. Nothing in the domain
  /// captures a pronoun, so a watched father was getting the wrong one
  /// throughout — and `watchedName` is already denormalised onto the link, so
  /// using it costs nothing and survives translation.
  static String _awayClause(String watchedName, AwayPeriod? away) => away == null
      ? ''
      : '$watchedName was marked away until ${_date(away.through)}.';

  /// ADR-0004's message. Three variants, and the differences are load-bearing.
  ///
  /// *"the check-ins"*, not *"her check-ins"* — the same Phase 3 gate decision.
  /// A direct substitution would read *"Can't check on Mum — I Am Ok has lost
  /// access to Mum's check-ins"*, saying the name twice in one sentence; the
  /// opener already establishes whose they are, so the possessive was carrying
  /// no information.
  ///
  /// *"Your phone last saw"*, never *"Last confirmed"*: the date is the newest
  /// check-in **this device managed to read**, and during a refusal she may be
  /// tapping every day. *"Last confirmed Saturday 15 August"* reads as a
  /// five-day silence on the 20th — the words claim nothing, the reading does.
  ///
  /// *"Open the app"*, never *"Open I Am Ok"*: after an imperative the app's
  /// name parses for a beat as its own clause — *"Open — I am OK"* — which is
  /// the opposite of the message, read by the person most likely to misread it.
  static String _accessLostBody({
    required String watchedName,
    required AwayPeriod? away,
    required DayKey? lastConfirmedDay,
  }) {
    const opener = 'I Am Ok has lost access to the check-ins. '
        'Open the app to see what to do.';
    final tail = away != null
        ? _awayClause(watchedName, away)
        : lastConfirmedDay == null
            ? 'Your phone has not seen a check-in yet.'
            : 'Your phone last saw a check-in on ${_date(lastConfirmedDay)}.';
    return 'Can\'t check on $watchedName — $opener $tail';
  }

  /// *"Correction: Mum did check in yesterday, at 23:40."*
  ///
  /// Posted at the **same notification id** as the warning it corrects, so the
  /// false one is replaced rather than left sitting above the truth.
  static String correctionBody({
    required String watchedName,
    required DateTime tappedAt,
    required tz.Location watcherZone,
  }) =>
      'Correction: $watchedName did check in yesterday, '
      'at ${_time(tappedAt, watcherZone)}.';

  /// *"Saturday 22 August"*. Written out, never `22/08` — ambiguous and hard to
  /// scan, and this is read at 3am by someone who has just been told bad news.
  static String _date(DayKey day) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
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
    final at = day.at(const LocalTimeOfDay(12, 0), TimeZones.utc);
    return '${weekdays[at.weekday - 1]} ${day.day} ${months[day.month - 1]}';
  }

  /// *"Tuesday 10:14"* for anything older than yesterday, *"22:10"* for today.
  ///
  /// The long form exists because *"offline since 10:14"* is actively
  /// misleading when the 10:14 in question was nine days ago — it reads as this
  /// morning, which understates the problem in exactly the direction this app
  /// must not.
  static String _moment(DateTime instant, tz.Location zone) {
    final local = tz.TZDateTime.from(instant, zone);
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return '${weekdays[local.weekday - 1]} ${_time(instant, zone)}';
  }

  /// *"23:40"*, in the reader's own zone.
  ///
  /// 24-hour because that is the owner's locale and the approved strings are
  /// written that way. `docs/ui-ux/guidelines.md` says to render the device's
  /// own 12h/24h setting rather than hard-coding either; doing that needs a
  /// `BuildContext`, which a notification posted from a bare isolate does not
  /// have. Recorded as a deviation in the Phase 3 summary rather than silently
  /// resolved the easy way.
  static String _time(DateTime instant, tz.Location zone) {
    final local = tz.TZDateTime.from(instant, zone);
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
