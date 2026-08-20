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
  ///
  /// ## "Yesterday" is only true of one day, and this can be called about others
  ///
  /// ADR-0009 has `reconcile()` decide about **every** completed day it has not
  /// settled, so a fire deferred past local midnight, a phone out of a drawer,
  /// or a recovered multi-day refusal can post about a day that is not
  /// yesterday. Three of these four bodies said *yesterday* unconditionally, and
  /// posting one of them about an older day would be a false claim to a family
  /// — in the message whose entire purpose is not to make one.
  ///
  /// The remedy is [correctionBody]'s, which met this first: the correction path
  /// has always been able to fire for several days at once. `_when` is that
  /// idiom, shared rather than copied, so the warning and the correction that
  /// later retracts it cannot describe the same day differently.
  ///
  /// It also removes a falsehood that pre-dates ADR-0009. A watcher several
  /// zones from the watched person could already be told *"yesterday"* about a
  /// watched-local day that was not their yesterday; that message now dates
  /// itself. The words got **more** true on a path where truth is the product.
  static String warningBody({
    required WarningOutcome outcome,
    required String watchedName,
    required DayKey day,
    AwayPeriod? away,
    DateTime? unverifiedSince,
    DayKey? lastConfirmedDay,
    required tz.Location watcherZone,
    /// Today in the **watcher's** zone. Needed so an `unverifiedSince` older
    /// than a week is dated rather than left as a bare weekday the reader will
    /// take for this week — see [_moment].
    required DayKey today,

    /// Whether this device shows 24-hour times. Cached to `LocalStore` by the
    /// UI, because reading `MediaQuery.alwaysUse24HourFormat` needs a
    /// `BuildContext` and the isolate that posts most of these has no widget
    /// tree — the same shape as the device timezone (ADR-0002).
    required bool uses24Hour,
  }) =>
      switch (outcome) {
        WarningOutcome.silent => throw ArgumentError(
            'silent has no message; a silent decision must not reach the '
            'notification layer',
          ),
        WarningOutcome.warnOnline =>
          'No check-in from $watchedName ${_when(day, today)}.',
        WarningOutcome.warnOffline => 'No check-in received from $watchedName '
            '${_when(day, today)} — '
            '${_offlineClause(unverifiedSince, watcherZone, today, uses24Hour)}',
        // The one outcome that names no day when it is about yesterday, because
        // it is a claim about THIS PHONE rather than about a missed day: "can't
        // check" is present tense. It gains the day only when the day is not
        // yesterday — otherwise two of these, posted for two days in the same
        // catch-up, would arrive at two notification ids with identical text and
        // no way for the reader to tell them apart.
        WarningOutcome.warnUnverifiableAway =>
          'Can\'t check on $watchedName${_forDayClause(day, today)} — '
              '${_offlineClause(unverifiedSince, watcherZone, today, uses24Hour)} '
              '${_awayClause(watchedName, away)}',
        WarningOutcome.warnAccessLost => _accessLostBody(
            watchedName: watchedName,
            away: away,
            lastConfirmedDay: lastConfirmedDay,
          ),
      };

  /// *"yesterday"*, or *"on Monday 10 August"* when it is not.
  ///
  /// [day] is a day in the **watched person's** zone and [today] is the
  /// **watcher's** today, which is the reader's frame and therefore the right
  /// one to judge "yesterday" against: the reader is the one the word has to be
  /// true for. Shared by [warningBody] and [correctionBody] so a warning and the
  /// correction that retracts it can never describe the same day differently.
  static String _when(DayKey day, DayKey today) =>
      day == today.previous ? 'yesterday' : 'on ${_date(day)}';

  /// *""*, or *" for Monday 10 August"* when the day is not yesterday.
  ///
  /// The same judgement as [_when], for the one message that reads better with
  /// no day at all in the ordinary case. Kept beside it so the two cannot drift
  /// about which day counts as yesterday.
  static String _forDayClause(DayKey day, DayKey today) =>
      day == today.previous ? '' : ' for ${_date(day)}';

  /// *"your phone has been offline since 22:10."* — or the never-reconciled
  /// variant.
  ///
  /// **Every interpolated value here can be null**, and this is the one that
  /// bites: a watcher whose device has never had a successful read has no
  /// "offline since". Rendering *"offline since null"* to a worried family is
  /// the failure the variants exist to prevent, which is why the null case is a
  /// different sentence rather than a formatting fallback.
  static String _offlineClause(
    DateTime? since,
    tz.Location zone,
    DayKey today,
    bool uses24Hour,
  ) =>
      since == null
          ? 'your phone has not been able to check even once.'
          : 'your phone has been offline since ${_moment(since, zone, today, uses24Hour)}.';

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
  /// The retraction that **replaces** a warning at the same notification id, so
  /// the false one is gone rather than sitting above the truth in the shade.
  ///
  /// [tappedAt] is the moment **she** tapped — `deviceTappedAt`, the client
  /// clock, which §11 keeps precisely because it is what happened rather than
  /// when we heard about it. Null when the read carries no per-check-in
  /// timestamp, and then the time clause is omitted entirely.
  ///
  /// **Null is not a degraded case to paper over.** The alternative on offer was
  /// the instant this device did the reading, which is a different fact wearing
  /// the same words: a watcher's phone that was asleep until morning would
  /// render *"Mum did check in yesterday, at 09:02"* about a tap at 23:40 — a
  /// fabricated claim about a person, on the one message whose purpose is to
  /// correct a false claim about her. Every interpolated value in this file can
  /// be null and every one has a variant; this is that rule applied to the value
  /// that is easiest to fake and worst to fake.
  ///
  /// Both variants are in `docs/ui-ux/screens.md`.
  /// [day] is the day being retracted, and [today] is the reconcile's `D`.
  ///
  /// **"Yesterday" is only true for one of the days this can be called about.**
  /// The reconciler emits a correction for *every* standing warning a read
  /// confirms, and a day leaves `warningsShownFor` only by correction or
  /// revocation — so a genuinely missed day sits there indefinitely. Mum's phone
  /// offline over a weekend, both taps syncing on Monday: the watcher was warned
  /// about Saturday and about Sunday, and Monday's read confirms both. Two
  /// notifications, two ids, and — before this — identical text, one of them
  /// factually wrong about which day it covered.
  ///
  /// A reader at 3am got the same sentence twice and could not tell which days
  /// were now covered. That is the same fault the time clause was removed for:
  /// a message whose whole purpose is to withdraw a false claim about a person,
  /// making a new one to do it. The day is the one fact the device certainly
  /// holds here — it already derives the notification id from it.
  static String correctionBody({
    required String watchedName,
    required DayKey day,
    required DayKey today,

    /// Whether this device shows 24-hour times. Cached to `LocalStore` by the
    /// UI, because reading `MediaQuery.alwaysUse24HourFormat` needs a
    /// `BuildContext` and the isolate that posts most of these has no widget
    /// tree — the same shape as the device timezone (ADR-0002).
    required bool uses24Hour,
    required DateTime? tappedAt,
    required tz.Location watcherZone,
  }) {
    // "Yesterday" reads better and is what the approved string says, so it is
    // kept for the one day it is true of. Through [_when], which ADR-0009 made
    // shared: the warning this retracts renders its day with the same call, and
    // a correction that dated a day differently from the warning above it would
    // be its own small confusion at the worst moment to have one.
    final when = _when(day, today);
    return tappedAt == null
        ? 'Correction: $watchedName did check in $when.'
        : 'Correction: $watchedName did check in $when, '
            'at ${_time(tappedAt, watcherZone, uses24Hour)}.';
  }

  /// *"Tuesday 10:14"*, for a surface outside this file.
  ///
  /// Shared with the watcher list for the same reason [dayLabel] is: two
  /// formatters is two things to keep true, and the reader compares the row and
  /// the notification about the same moment directly.
  static String momentLabel(
    DateTime instant,
    tz.Location zone,
    DayKey today,
    bool uses24Hour,
  ) =>
      _moment(instant, zone, today, uses24Hour);

  /// *"09:14"* or *"9:14 am"*, for a surface outside this file.
  ///
  /// Exposed for the same reason [momentLabel] and [dayLabel] are: this app had
  /// three separate ways of turning an instant into a time, and the Tap screen's
  /// produced *"9:14 AM"* against everywhere else's *"9:14 am"*. One formatter
  /// is one thing to keep true.
  static String timeLabel(DateTime instant, tz.Location zone, bool uses24Hour) =>
      _time(instant, zone, uses24Hour);

  /// *"Saturday 22 August"*, for a surface outside this file.
  ///
  /// Exposed rather than duplicated so the watcher list and the notification
  /// about the same day cannot render it differently — two date formatters is
  /// two things to keep true, and the reader compares them directly.
  static String dayLabel(DayKey day) => _date(day);

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
  static String _moment(
    DateTime instant,
    tz.Location zone,
    DayKey today,
    bool uses24Hour,
  ) {
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
    final weekday = weekdays[local.weekday - 1];

    // **Beyond a week the weekday is ambiguous in the direction that
    // understates.** "Tuesday 10:14" for an instant nine days ago reads as the
    // most recent Tuesday — two days ago. Adding the weekday moved the
    // ambiguity from one day to seven; it did not remove it, and this comment
    // used to claim it had.
    //
    // It is not hypothetical on the built screen. A revoked link and a
    // lost-access link both refuse every read forever, so `lastReconcileAt`
    // never advances and the row would show the same "Tuesday 10:14" in week
    // three and week twelve — about a phone that has checked nothing since.
    final days = today.differenceInDays(DayKey.fromInstant(instant, zone));
    if (days > 6) {
      // `_date` already carries the weekday — "Saturday 15 August, 10:14".
      return '${_date(DayKey.fromInstant(instant, zone))}, '
          '${_time(instant, zone, uses24Hour)}';
    }
    // **Today is just the time**, which is what this function's own docstring
    // and `screens.md` have always said and what the code did not do. Naming
    // the weekday for something four hours ago — *"Tuesday 10:14"* at 14:00 on
    // Tuesday — reads as a different day, and pushes the reader to work out
    // that it is in fact this morning. The weekday earns its place only once
    // there is another day it could be.
    if (days == 0) return _time(instant, zone, uses24Hour);
    return '$weekday ${_time(instant, zone, uses24Hour)}';
  }

  /// *"23:40"*, or *"9:14 am"*, in the reader's own zone.
  ///
  /// **Follows the device's own 12h/24h setting**, which is what
  /// `docs/ui-ux/guidelines.md` asks for. This docstring argued the opposite
  /// until the Phase 3 gate — that 24-hour was hard-coded because reading the
  /// setting needs a `BuildContext` a bare isolate does not have — and it went
  /// on saying so after [uses24Hour] was added three lines below it, pointing at
  /// a "deviation" in the Phase 3 summary that is now recorded as closed.
  ///
  /// The rationale was wrong as well as stale: `platformDispatcher
  /// .alwaysUse24HourFormat` needs no context at all, so `ClockService` reads it
  /// and caches it to `LocalStore` beside the device zone, and every surface —
  /// notification, watcher row, Tap screen — renders from that one value.
  static String _time(DateTime instant, tz.Location zone, bool uses24Hour) {
    final local = tz.TZDateTime.from(instant, zone);
    final m = local.minute.toString().padLeft(2, '0');
    if (uses24Hour) {
      return '${local.hour.toString().padLeft(2, '0')}:$m';
    }
    // 12-hour, in the shape a reader of this locale expects: no leading zero on
    // the hour, lowercase suffix, midnight and noon as 12 rather than 0.
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    return '$hour12:$m ${local.hour < 12 ? 'am' : 'pm'}';
  }
}
