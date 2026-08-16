import '../time/day_key.dart';

/// A bounded period during which no check-in is expected.
///
/// One document, one truth: `users/{watchedUid}/shared/away` (ARCHITECTURE.md
/// §12). Away is a property of the watched *person*, not of a pair, because the
/// effect is global — during away there are no taps at all.
///
/// [through] is **inclusive**: it is the last away day, not the day of return.
/// The UI is required to say so unambiguously ("Last day away: Saturday 22" /
/// "Back on Sunday 23") because "until" alone is not.
///
/// The invariant `through >= from` is enforced at construction. [ADR-0001][]
/// turns on that invariant holding — it is why cancelling on the first away day
/// deletes the document rather than truncating it — so a period that violates
/// it must not be representable.
///
/// [ADR-0001]: ../../../docs/architecture/decisions/0001-away-cache-precedence.md
class AwayPeriod {
  AwayPeriod({required this.from, required this.through}) {
    if (through < from) {
      throw ArgumentError.value(
        '$from..$through',
        'through',
        'an away period cannot end before it starts',
      );
    }
  }

  /// [AwayPeriod.new], returning null rather than throwing.
  ///
  /// For the boundary that parses a stored document: a corrupt or hostile
  /// `through < from` should surface as "no valid away period", not as an
  /// exception thrown inside an alarm isolate with seconds to live.
  static AwayPeriod? tryCreate({required DayKey from, required DayKey through}) {
    if (through < from) return null;
    return AwayPeriod(from: from, through: through);
  }

  /// First away day, in the watched person's timezone.
  final DayKey from;

  /// Last away day, **inclusive**, in the watched person's timezone.
  final DayKey through;

  /// The first day a check-in is expected again.
  DayKey get firstDayBack => through.next;

  /// Away days counted inclusively: a `from == through` period is one day.
  int get lengthInDays => through.differenceInDays(from) + 1;

  /// Whether [day] falls inside the period **as it may actually be honoured**
  /// — that is, after [clampedToSanityBound].
  ///
  /// Clamped by default, deliberately. The first version of this guard clamped
  /// at the one call site that was being thought about and left the other two
  /// raw, which is how an over-long document went on suppressing the watched
  /// person's reminders for a decade while the watchers warned daily. A
  /// predicate whose misuse silences a family should be safe when used without
  /// thinking about it; [coversAsStored] is there for the rare case that wants
  /// what the document literally claims.
  bool covers(DayKey day) {
    final honoured = clampedToSanityBound();
    return day >= honoured.from && day <= honoured.through;
  }

  /// Whether [day] falls inside the period **as literally stored**, cap or no
  /// cap. For diagnostics and for asserting what a document claims — never for
  /// deciding whether to stay silent.
  bool coversAsStored(DayKey day) => day >= from && day <= through;

  /// Whether the period is longer than the **cap** permits — the exact
  /// client-side rule in [AwayRules]. Used for validating a write, never for
  /// deciding whether to honour a read: see [isAbsurd].
  bool get exceedsCap => lengthInDays > AwayRules.maxLengthInDays;

  /// Whether the period is so long it cannot be a real away period.
  ///
  /// Measured as a **duration** from [from], not as a horizon from today: this
  /// bounds **how long a family can be silenced**, where [AwayRules] bounds how
  /// far ahead a period may reach.
  ///
  /// **Deliberately far looser than the cap**, and that gap is the whole point.
  /// The Firestore rules cannot express the cap exactly — `through` is a local
  /// date and `request.time` is a UTC instant — so they are written slack at
  /// `+32d`, which admits a period of up to ~34 local days in the most extreme
  /// zone. A read-time bound set at the *exact* cap would therefore reject
  /// periods the server legitimately accepted, and the watcher would be told
  /// *"No check-in from Mum yesterday"* for days the family really did mark
  /// away. Clamping to the cap would swap a rare absurd-document failure for a
  /// routine false claim, which is the worse trade by this design's own
  /// ordering.
  ///
  /// So the bound answers only *"can this possibly be real?"* Sixty days is
  /// comfortably above anything the rules can admit and orders of magnitude
  /// below the failure it exists for.
  bool get isAbsurd => lengthInDays > AwayRules.absurdLengthInDays;

  /// The period, or as much of it as can possibly be real.
  ///
  /// [AwayRules] rejects an over-long period on **write**, but a device does not
  /// only write periods — it *reads* them, and a read that succeeds is trusted
  /// (ADR-0001). So a ten-year away document reaching a device — written before
  /// the rules were deployed, through a rules-deploy mistake, or by a buggy or
  /// hostile client — would silence that family for ten years, and the
  /// staleness bound could not help, because nothing is stale: the read works
  /// perfectly, every day, and returns the same absurd answer.
  ///
  /// Clamping rather than discarding is what keeps this from over-correcting:
  /// the days the family legitimately marked away are still covered, so no
  /// false *"she didn't check in"* is produced for them. Beyond the bound the
  /// ordinary decision resumes and the app speaks — the design's standing
  /// preference, because silence is the one failure it cannot detect in itself.
  AwayPeriod clampedToSanityBound() => isAbsurd
      ? AwayPeriod(
          from: from,
          through: from.plusDays(AwayRules.absurdLengthInDays - 1),
        )
      : this;

  /// Whether the period has run its course as of [today].
  ///
  /// Expiry is **arithmetic**, never a transmitted event (§12): every device
  /// computes this independently, so nothing can be lost in delivery and the
  /// period ends at the same moment on every phone whether or not any of them
  /// has been online since it started.
  bool hasExpiredOn(DayKey today) => today > through;

  /// Whether [today] is the day before the last away day — the trigger for the
  /// locally scheduled "ends tomorrow" notice (§12). No server is involved.
  bool endsTomorrowOn(DayKey today) => through == today.next;

  /// The period as it must be **written** when someone cancels on [cancelDay].
  ///
  /// [ADR-0001][] decision 5. Cancelling truncates rather than deletes, so the
  /// days already spent away stay covered: deleting mid-period would
  /// retroactively un-cover them, and the next device to refresh its cache
  /// would warn about a day the person was legitimately away — a false claim,
  /// which is the worst thing this app can do.
  ///
  /// Returns null — meaning *delete the document* — only when nothing has
  /// elapsed. Truncating on the first away day would write
  /// `through = from - 1` and break `through >= from`.
  ///
  /// ```
  /// cancel(a, day) = null              if day <= a.from
  ///                = {a.from, day - 1} otherwise
  /// ```
  ///
  /// [ADR-0001]: ../../../docs/architecture/decisions/0001-away-cache-precedence.md
  AwayPeriod? cancelOn(DayKey cancelDay) {
    if (cancelDay <= from) return null;
    return AwayPeriod(from: from, through: cancelDay.previous);
  }

  AwayPeriod copyWith({DayKey? from, DayKey? through}) =>
      AwayPeriod(from: from ?? this.from, through: through ?? this.through);

  @override
  bool operator ==(Object other) =>
      other is AwayPeriod && other.from == from && other.through == through;

  @override
  int get hashCode => Object.hash(from, through);

  @override
  String toString() => 'AwayPeriod($from..$through)';
}

/// Why a proposed away write is not allowed.
///
/// Named rather than boolean so a test can assert *which* rule rejected a
/// write. "It was rejected" passes just as happily against a validator that
/// rejects everything.
enum AwayRejection {
  /// `from` is in the past. No retroactive away (§12).
  retroactiveFrom,

  /// `through` is further out than the cap allows.
  exceedsCap,

  /// `from` differs from the stored value. Immutable after creation
  /// (ADR-0001 decision 6).
  fromChanged,
}

/// The **period** rules of ARCHITECTURE.md §8, as pure functions.
///
/// These mirror the Firestore security rules that Phase 6 deploys. Duplicating
/// them here is deliberate: the client must be able to reject a bad period
/// *before* writing, and the rules must reject it again for a client that
/// does not. `through >= from` is absent from both lists because [AwayPeriod]
/// makes it unrepresentable.
///
/// **This is one of §8's two validation groups, not both.** The attribution
/// group — [ADR-0003][]'s `setBy == request.auth.uid` on create *and* update,
/// `setByName` present and 1–100 chars, `setAt`/`updatedAt == request.time` —
/// is absent here, as are the `setBy`/`setByName` fields on [AwayPeriod]
/// itself. That follows §5, which scopes this type to "from/through,
/// containment, validity": attribution is document metadata for display and for
/// the rules, not an input to any decision. It lands with away mode in Phase 6.
///
/// [ADR-0003]: ../../../docs/architecture/decisions/0003-away-attribution.md
abstract final class AwayRules {
  /// How far past **today** `through` may reach — not past `from`.
  ///
  /// §8's rules clause is `through <= request.time + 32d` — deliberately slack,
  /// because the rules cannot compare a local date to a UTC instant exactly. This
  /// is the *exact* client-side number; they are not meant to match. The anchor
  /// matters too: it is
  /// invisible while `from` is always today, and divergent the moment
  /// future-dated away periods are exposed, which §12 leaves the door open for.
  ///
  /// **This is an offset, so the longest period is 31 days**, counting `from`.
  /// §12 said "30 days" for a while and every calculation in the project said
  /// 30 days *ahead*; the prose has been corrected to the arithmetic rather
  /// than the reverse, because the number is simply where the limit was put —
  /// nothing derives from it.
  static const int maxDaysAhead = 30;

  /// The longest away period this cap permits, counting `from`. See
  /// [maxDaysAhead].
  static const int maxLengthInDays = maxDaysAhead + 1;

  /// The read-time sanity bound — see [AwayPeriod.isAbsurd].
  ///
  /// **Deliberately far above [maxLengthInDays], and not derived from it.** The
  /// Firestore rules cannot express the cap exactly and are written slack at
  /// `+32d`, which admits up to roughly 34 local days in the most extreme
  /// zone. A read-time bound set at the exact cap would un-honour periods the
  /// server legitimately accepted and warn a family about days they really did
  /// mark away. This bound answers a different question — *can this possibly be
  /// real?* — so it sits above anything the rules can admit and orders of
  /// magnitude below the ten-year document it exists to stop.
  static const int absurdLengthInDays = 60;

  /// Validates a create. Returns null when the write is allowed.
  static AwayRejection? validateCreate(AwayPeriod period, DayKey today) {
    if (period.from < today) return AwayRejection.retroactiveFrom;
    if (period.through > today.plusDays(maxDaysAhead)) {
      return AwayRejection.exceedsCap;
    }
    return null;
  }

  /// Validates an update against the [existing] stored period.
  ///
  /// `from` is checked for equality rather than for being in the future:
  /// truncating an in-progress period rewrites a document whose `from` is
  /// already in the past, and a blanket `from >= today` would reject the very
  /// write ADR-0001 requires.
  static AwayRejection? validateUpdate(
    AwayPeriod period,
    AwayPeriod existing,
    DayKey today,
  ) {
    if (period.from != existing.from) return AwayRejection.fromChanged;
    if (period.through > today.plusDays(maxDaysAhead)) {
      return AwayRejection.exceedsCap;
    }
    return null;
  }
}
