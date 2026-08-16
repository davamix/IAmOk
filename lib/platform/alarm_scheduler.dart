import '../domain/domain.dart';
import 'notification_service.dart';

/// Arms and disarms the watched side's reminders (§6).
///
/// Phase 2 schedules **display-only** alarms through
/// `flutter_local_notifications.zonedSchedule` — no Dart code runs when one
/// fires. That is §10's asymmetry, not an interim shortcut: a spurious reminder
/// costs nothing ("a redundant *remember to tap*"), so the watched side never
/// needs to verify before speaking, and boot recovery comes free from
/// `ScheduledNotificationBootReceiver`. The logic-bearing
/// `android_alarm_manager_plus` alarm belongs to the **watcher** side and is
/// Phase 3, where a false fire would cost "everything".
///
/// This holds no store. §5 makes Data and Platform **peers** — the Application
/// layer reconciles, hands the two sets here, and records the outcome. A
/// scheduler that wrote its own view of what is armed would be a second source
/// of truth about it.
abstract interface class AlarmScheduler {
  /// Makes the platform match a reconcile result.
  ///
  /// **[toCancel] is applied before [desired].** See
  /// [NotificationAlarmScheduler.apply] for why the order is load-bearing, and
  /// for why the second argument is the whole desired set rather than the
  /// diff; every implementation owes both guarantees.
  /// Returns false when any reminder had to be armed **inexactly** — §13's
  /// documented degradation, which the health panel reports in Phase 7.
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
  });

  /// Tears down every reminder.
  Future<void> cancelAll();

  /// How many reminders the **notification plugin's own record** holds.
  ///
  /// Read [NotificationAlarmScheduler.armedAccordingToPlugin] before trusting
  /// this number for anything: it is not the platform's answer.
  Future<int> armedAccordingToPlugin();
}

/// The real one, over `flutter_local_notifications`.
class NotificationAlarmScheduler implements AlarmScheduler {
  const NotificationAlarmScheduler(this._notifications);

  final NotificationService _notifications;

  /// Makes the platform match a reconcile result.
  ///
  /// **[toCancel] is applied before [toSchedule], and the order is load-bearing.**
  /// `ScheduledReminder` equality includes the instant while the platform id is
  /// derived from `(day, slot)` alone — so a reminder whose zone or day-time
  /// moved appears in *both* sets under one id. Scheduling first and cancelling
  /// second would disarm the alarm just armed, and the symptom is **nothing
  /// happening**: no error, no log, just a reminder that never fires.
  ///
  /// `WatchedReconcileResult` does not expose a combined "reschedule" set the
  /// way the watcher side does; `desired.intersection` of the two sets by day is
  /// what that would be, and the ordering below is what makes it unnecessary.
  ///
  /// ## Why it schedules the WHOLE desired set, not the difference
  ///
  /// **Measured on the POCO F3, Phase 2 device pass.** Android cancels every one
  /// of an app's `AlarmManager` alarms when the app is force-stopped — which on
  /// HyperOS is an ordinary user action: swiping from recents, "clear all", or
  /// any task killer. The device matrix says so in terms ("Lock in recents |
  /// Off | Swiping the app from recents kills it and its alarms").
  ///
  /// Nothing tells the app. `LocalStore` still holds all 21 as pending, so a
  /// diff-based schedule computes `desired.difference(currentlyScheduled)` = ∅
  /// and re-arms **nothing**. Observed directly: 21 armed → force-stop → 0
  /// armed → reopen and reconcile → **still 0**. The app is silently and
  /// permanently inert, which is the one failure mode this project cannot
  /// detect in itself, and `LocalStore.replacePendingReminders` names this exact
  /// direction as the one that must never occur.
  ///
  /// Scheduling is **idempotent by id** — `zonedSchedule` on an existing id
  /// replaces it — so asserting the whole set costs a handful of local binder
  /// calls per reconcile and makes the operation self-healing whatever the
  /// platform's true state. That is what "reconcile, don't mutate" actually
  /// requires: the store is a record of what we *asked for*, never evidence of
  /// what the platform *holds*, and only one of those may be trusted.
  ///
  /// The diff is still needed for [toCancel], because a reminder that should no
  /// longer exist cannot be removed by re-asserting the ones that should.
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
  }) async {
    for (final reminder in toCancel) {
      await _notifications.cancelReminder(reminder.day, reminder.slot);
    }
    var exact = true;
    for (final reminder in desired) {
      // Per reminder, so one refusal degrades that alarm rather than aborting
      // the loop and leaving the rest of the window unarmed.
      exact = await _notifications.scheduleReminder(reminder) && exact;
    }
    return exact;
  }

  /// Tears down every reminder. Used when the store is wiped in debug builds,
  /// and on sign-out later.
  @override
  Future<void> cancelAll() => _notifications.cancelAll();

  /// How many reminders `flutter_local_notifications` has a record of.
  ///
  /// **This is NOT the platform's answer, and an earlier version of this
  /// comment claimed it was.** `pendingNotificationRequests()` reads the
  /// plugin's own `SharedPreferences` file — it does not enumerate
  /// `AlarmManager`, and no public Android API can: an app cannot list its own
  /// pending alarms. So this is a *second app-local record of the same intent*,
  /// sitting beside `LocalStore`.
  ///
  /// That matters for the failure this project cares about. A force-stop
  /// cancels every `AlarmManager` alarm but leaves SharedPreferences intact, so
  /// after exactly the scenario the Phase 2 device pass measured, this still
  /// returns 21 while nothing is armed. Comparing it against `LocalStore`
  /// detects the two bookkeeping copies disagreeing — useful, and not the same
  /// question.
  ///
  /// **The only ground truth is `adb shell dumpsys alarm`**, written to a file
  /// on the device and pulled; see `docs/testing/device-matrix.md`. The
  /// compensating design is that detection is not needed for correctness:
  /// [apply] re-asserts the whole desired set every reconcile, so the platform
  /// is repaired whether or not anything noticed it had drifted.
  @override
  Future<int> armedAccordingToPlugin() async =>
      (await _notifications.pending()).length;
}
