import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import '../domain/domain.dart';
import 'alarm_ids.dart';

/// Arms and disarms the **watcher's** warning alarms (§10).
///
/// ## Why this is a different mechanism from the watched side
///
/// `AlarmScheduler` schedules display-only notifications: no Dart runs when one
/// fires, because a spurious *"remember to tap"* costs nothing, so that side
/// never needs to verify before speaking. This side is the opposite half of
/// §10's asymmetry table — **a false warning costs "everything"** — so the alarm
/// has to wake real code that can re-read Firestore and decide.
///
/// `android_alarm_manager_plus` is what wakes it. The callback runs in a **bare
/// isolate**: no widget tree, no Riverpod, no plugin registrant beyond what it
/// registers itself. See `warning_alarm_handler.dart`.
///
/// ## The ordering rule, again
///
/// **[toCancel] is applied before [desired]**, enforced here rather than left to
/// call sites, for the same reason as on the watched side: `ScheduledWarning`
/// equality includes the instant while the platform id is derived from the day
/// alone, so a warning whose time moved — a watcher changing 10:00 to 08:00 —
/// appears in *both* sets under one id. Cancelling second would disarm the alarm
/// just armed, and the symptom is nothing happening.
abstract interface class WarningAlarmScheduler {
  /// Makes the platform match a reconcile result, for one link.
  ///
  /// The second argument is the whole desired set rather than the diff, for the
  /// reason measured on hardware in Phase 2: a force-stop cancels every
  /// `AlarmManager` alarm and tells the app nothing, so a diff computed against
  /// the store re-arms nothing and the watcher goes permanently deaf. Arming is
  /// idempotent by id, so re-asserting costs a handful of binder calls and makes
  /// the operation self-healing whatever the platform's true state.
  /// Returns false when the warnings had to be armed **inexactly** — §13's
  /// documented degradation, which the health panel reports in Phase 7.
  Future<bool> apply({
    required String linkId,
    required Set<ScheduledWarning> toCancel,
    required Set<ScheduledWarning> desired,
  });

  /// Tears down every warning alarm for one link.
  ///
  /// **Currently unused, and named as such rather than left to look load-bearing.**
  /// The docstring said "used on revocation", which is where §10 step 2 does tear
  /// the alarm down — but revocation reaches that through [apply] with an empty
  /// `desired` set, which is the right mechanism because it goes through the same
  /// desired-state path as everything else (*reconcile, don't mutate*).
  ///
  /// Kept because Phase 5's unpairing removes a link outright, at which point
  /// there is no reconcile to compute an empty set *for* — that is the caller
  /// this is waiting for.
  Future<void> cancelAll({
    required String linkId,
    required Set<ScheduledWarning> armed,
  });
}

/// The real one, over `android_alarm_manager_plus`.
class AndroidWarningAlarmScheduler implements WarningAlarmScheduler {
  const AndroidWarningAlarmScheduler(this._callback, this._canScheduleExact);

  /// Whether the platform will still accept an exact alarm (API 31+).
  ///
  /// **Asked, because the plugin will not tell us.** `AlarmService.scheduleAlarm`
  /// checks `canScheduleExactAlarms()` and, when it is false, logs and
  /// **arms nothing** — no throw, no fallback. `oneShotAt` returns `true`
  /// regardless, and the alarm is persisted for reboot-rescheduling first, so
  /// every signal the app can see says it worked.
  ///
  /// Without this, a refusal silently armed nothing while
  /// `replacePendingWarnings` recorded the whole set as armed — the direction
  /// `LocalStore` names as the one that must never occur, on the side where
  /// silence is the failure this app cannot detect in itself. Reachable today on
  /// API 31–32, where `SCHEDULE_EXACT_ALARM` is user-revocable, and everywhere
  /// if Play refuses `USE_EXACT_ALARM` at Phase 8.
  ///
  /// The watched side already degrades this way (`NotificationService
  /// .scheduleReminder`); this is the same promise kept on the other half.
  final Future<bool> Function() _canScheduleExact;

  /// The top-level, `@pragma('vm:entry-point')` function the alarm wakes.
  ///
  /// Injected rather than referenced directly so this class stays testable and
  /// so the entry point lives in one file that the purity guard names.
  final Function _callback;

  @override
  Future<bool> apply({
    required String linkId,
    required Set<ScheduledWarning> toCancel,
    required Set<ScheduledWarning> desired,
  }) async {
    for (final warning in toCancel) {
      await AndroidAlarmManager.cancel(AlarmIds.warning(linkId, warning.day));
    }
    // Asked once per apply rather than per alarm: it is a device-wide setting,
    // and a value that changed mid-loop would arm half the window each way.
    final exact = await _canScheduleExact();
    for (final warning in desired) {
      await AndroidAlarmManager.oneShotAt(
        // A `tz.TZDateTime` IS a DateTime, and the plugin takes the instant.
        // The zone arithmetic already happened in the domain, against the
        // watcher's zone — never a raw UTC offset, which the next DST
        // transition would invalidate (§11).
        warning.at,
        AlarmIds.warning(linkId, warning.day),
        _callback,
        // The whole point: wake the device. A warning deferred by Doze until the
        // phone is next picked up arrives after the family already needed it.
        wakeup: true,
        // Doze defers even wakeup alarms without this.
        allowWhileIdle: true,
        // §10 promises the warning fires at `warningLocalTime`, so exact is
        // asked for first. An hour's drift on a dead man's switch is an hour
        // nobody is told — but an alarm armed inexactly still fires, and one
        // refused outright never does. Degrade, never drop.
        exact: exact,
        // Enables the plugin's RebootBroadcastReceiver for this alarm. NOT a
        // repair path for a force-stopped app — a stopped app receives no
        // broadcasts at all, including BOOT_COMPLETED, and that state survives a
        // reboot. It covers the ordinary reboot, which is the common case.
        rescheduleOnReboot: true,
      );
    }
    return exact;
  }

  @override
  Future<void> cancelAll({
    required String linkId,
    required Set<ScheduledWarning> armed,
  }) async {
    for (final warning in armed) {
      await AndroidAlarmManager.cancel(AlarmIds.warning(linkId, warning.day));
    }
  }
}
