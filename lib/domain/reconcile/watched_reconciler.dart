import 'package:timezone/timezone.dart' as tz;

import '../away/away_period.dart';
import '../entities/link.dart';
import '../entities/watched_audience.dart';
import '../policy/reminder_policy.dart';
import '../time/day_key.dart';

/// What the watched side's alarms should be, and how to get there from what
/// they are.
class WatchedReconcileResult {
  const WatchedReconcileResult({
    required this.desired,
    required this.toSchedule,
    required this.toCancel,
    required this.audience,
  });

  /// Every reminder that should exist across the window.
  final Set<ScheduledReminder> desired;

  /// Missing, so create them.
  final Set<ScheduledReminder> toSchedule;

  /// Present and unwanted, so cancel them. A window that only ever creates
  /// leaves reminders armed through a holiday.
  final Set<ScheduledReminder> toCancel;

  /// Who will be notified when she taps — the one thing the Tap screen says
  /// about watchers. See [WatchedAudience] for what is deliberately absent.
  ///
  /// It comes out of `reconcile()` rather than off a separate query on purpose:
  /// "reconcile, don't mutate" (§3) means one function reads current state and
  /// computes everything that should be true of it, and a second path to the
  /// same links is a second source of truth about who is watching.
  final WatchedAudience audience;

  /// Reality already matches. The second of two consecutive reconciles must
  /// report this, or boot recovery is a duplicate-notification bug.
  ///
  /// Deliberately **not** widened to cover [audience]: this asks whether any
  /// alarm work is owed, and the audience is state to render rather than an
  /// action to take. A caller doing `if (isNoOp) return;` skips scheduling, not
  /// drawing.
  bool get isNoOp => toSchedule.isEmpty && toCancel.isEmpty;

  @override
  String toString() => 'WatchedReconcileResult(${desired.length} desired, '
      '+${toSchedule.length} / -${toCancel.length})';
}

/// The watched side's desired-state calculator.
///
/// **Nothing runs at midnight to arm tomorrow.** So alarms are not armed a day
/// at a time — `reconcile()` maintains a rolling window and makes reality match,
/// on app open, on check-in, on FCM, on alarm fire, and on boot. Idempotent by
/// construction, which is what makes boot recovery ordinary rather than a
/// special case (§10).
abstract final class WatchedReconciler {
  /// Days of reminders kept armed ahead, counting today.
  static const int windowDays = 7;

  /// Diffs the desired window against [currentlyScheduled].
  ///
  /// **During an away period the window extends to `through` + [windowDays]**,
  /// with the away days themselves simply absent from the desired set. That
  /// extension is load-bearing: it means the reminders for the first days back
  /// are already scheduled before the person leaves, so the app re-arms itself
  /// without anyone opening it — which is the entire reason the watched side
  /// can stay display-only and needs no logic-bearing alarm. A window that
  /// stops at `through` leaves nothing armed after a holiday.
  ///
  /// [away] has been a parameter since the first line of this file, written in
  /// Phase 1 when every production call site passed null (PLAN.md, Phase 1,
  /// non-negotiable). **Phase 6 filled it in**, which is why away mode was a
  /// feature here rather than a retrofit through every call site and test.
  ///
  /// [links] is the watched person's **own** links — the ones where they are
  /// the watched party, which §8 already lets them read. It is required rather
  /// than optional on the same reasoning PLAN.md gives for [away]: retrofitting
  /// a parameter later means touching every call site and every test written in
  /// between. It feeds [WatchedReconcileResult.audience] and nothing else — no
  /// alarm decision on this side depends on who is watching, and none should,
  /// because reminders exist for the person's own routine rather than for an
  /// audience.
  static WatchedReconcileResult reconcile({
    required DateTime now,
    required tz.Location watchedZone,
    required AwayPeriod? away,
    required Set<DayKey> checkedInDays,
    required Set<ScheduledReminder> currentlyScheduled,
    required List<Link> links,
  }) {
    final today = DayKey.fromInstant(now, watchedZone);

    // Clamped before `through` is read. The window end is derived from a
    // REMOTE document, and `DayKey.through()` materialises the span eagerly:
    // an away period ending in 9999 would allocate ~2.9 million DayKeys inside
    // a bare alarm isolate with seconds to live. Measured, not theorised. The
    // clamp also stops such a document suppressing this person's own reminders
    // for a decade — the watcher side was defended first, and defending only
    // one side produces the worst state of all: she is never nudged to tap, and
    // her family is warned every day.
    final honoured = away?.clampedToSanityBound();

    var lastDay = today.plusDays(windowDays - 1);
    if (honoured != null) {
      final firstWeekBack = honoured.through.plusDays(windowDays);
      if (firstWeekBack > lastDay) lastDay = firstWeekBack;
    }

    final desired = <ScheduledReminder>{
      for (final day in today.through(lastDay))
        ...ReminderPolicy.remindersFor(
          day: day,
          away: honoured,
          checkedIn: checkedInDays.contains(day),
          now: now,
          watchedZone: watchedZone,
        ),
    };

    return WatchedReconcileResult(
      desired: desired,
      toSchedule: desired.difference(currentlyScheduled),
      toCancel: currentlyScheduled.difference(desired),
      audience: WatchedAudience.from(links),
    );
  }
}
