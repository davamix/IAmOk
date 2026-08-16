import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/notification_service.dart';

import '../support/zones.dart';

/// **`toCancel` before `toSchedule`, asserted on the real implementation.**
///
/// The service-level test in `test/application/` asserts the same ordering, but
/// it does so through a fake scheduler that produces the ordering itself — so it
/// would pass unchanged if [NotificationAlarmScheduler.apply] scheduled first
/// and cancelled second. This file closes that hole by recording the calls the
/// production class actually makes.
///
/// Why the invariant matters enough to test twice: `ScheduledReminder` equality
/// includes the instant while the platform id is derived from `(day, slot)`
/// alone, so a reminder whose zone or time moved appears in **both** sets under
/// one id. Cancelling last disarms the alarm just armed — and the symptom is
/// *nothing happening*. No error, no log, no notification.
class _RecordingNotifications extends NotificationService {
  _RecordingNotifications() : super(FlutterLocalNotificationsPlugin());

  final List<String> calls = [];

  /// Set to false to simulate `exact_alarms_not_permitted`.
  bool exact = true;

  @override
  Future<bool> scheduleReminder(ScheduledReminder reminder) async {
    calls.add('schedule ${reminder.day} ${reminder.slot.name}');
    return exact;
  }

  @override
  Future<void> cancelReminder(DayKey day, ReminderSlot slot) async {
    calls.add('cancel $day ${slot.name}');
  }

  @override
  Future<void> cancelAll() async => calls.add('cancelAll');

  @override
  Future<List<PendingNotificationRequest>> pending() async => const [];
}

void main() {
  TimeZones.ensureInitialized();

  late _RecordingNotifications notifications;
  late AlarmScheduler scheduler;

  setUp(() {
    notifications = _RecordingNotifications();
    scheduler = NotificationAlarmScheduler(notifications);
  });

  ScheduledReminder reminderOn(String iso, ReminderSlot slot, [dynamic zone]) {
    final d = day(iso);
    return ScheduledReminder(
      day: d,
      slot: slot,
      at: d.at(slot.time, zone ?? madrid),
    );
  }

  test('every cancel precedes every schedule', () {
    // The moved-alarm case, in the shape it actually arrives: the same day and
    // slot in both sets, at two different instants, because the zone changed.
    final inMadrid = {
      for (final slot in ReminderSlot.values)
        reminderOn('2026-08-17', slot, madrid),
    };
    final inNewYork = {
      for (final slot in ReminderSlot.values)
        reminderOn('2026-08-17', slot, newYork),
    };

    return scheduler
        .apply(toCancel: inMadrid, desired: inNewYork)
        .then((_) {
      final firstSchedule =
          notifications.calls.indexWhere((c) => c.startsWith('schedule'));
      final lastCancel =
          notifications.calls.lastIndexWhere((c) => c.startsWith('cancel'));

      expect(lastCancel, isNonNegative);
      expect(firstSchedule, isNonNegative);
      expect(lastCancel, lessThan(firstSchedule),
          reason: 'cancelling after scheduling disarms what was just armed, '
              'and the symptom is nothing happening');
    });
  });

  test('a cancel-only diff issues no schedules', () async {
    await scheduler.apply(
      toCancel: {reminderOn('2026-08-17', ReminderSlot.midday)},
      desired: const {},
    );
    expect(notifications.calls, ['cancel 2026-08-17 midday']);
  });

  test('a schedule-only diff issues no cancels', () async {
    await scheduler.apply(
      toCancel: const {},
      desired: {reminderOn('2026-08-17', ReminderSlot.night)},
    );
    expect(notifications.calls, ['schedule 2026-08-17 night']);
  });

  test('an empty diff touches the platform not at all', () async {
    await scheduler.apply(toCancel: const {}, desired: const {});
    expect(notifications.calls, isEmpty,
        reason: 'a no-op reconcile must be a no-op at the platform too');
  });

  group('exact alarms refused', () {
    // ARCHITECTURE.md §13 promises "reminders degrade to inexact". Before this,
    // the plugin's `exact_alarms_not_permitted` propagated out of `apply`,
    // through `reconcile()`, into the provider's error channel — replacing the
    // whole screen with "this phone could not get ready" and skipping the store
    // write entirely. A degraded reminder beats a screen that will not load.
    //
    // Unreachable on the API 33 test device (USE_EXACT_ALARM makes
    // canScheduleExactAlarms() always true) but live on API 31-32, and the
    // default everywhere if Play refuses USE_EXACT_ALARM at Phase 8.

    test('the whole window is still armed', () async {
      notifications.exact = false;
      final desired = {
        for (final slot in ReminderSlot.values)
          reminderOn('2026-08-17', slot),
      };

      final exact = await scheduler.apply(toCancel: const {}, desired: desired);

      expect(exact, isFalse, reason: 'the degradation is reported, not hidden');
      expect(notifications.calls.where((c) => c.startsWith('schedule')),
          hasLength(3),
          reason: 'one refusal must not abort the loop and leave the rest of '
              'the window unarmed');
    });

    test('reports exact when nothing was refused', () async {
      final exact = await scheduler.apply(
        toCancel: const {},
        desired: {reminderOn('2026-08-17', ReminderSlot.midday)},
      );
      expect(exact, isTrue);
    });
  });

  test('cancelAll goes straight through', () async {
    await scheduler.cancelAll();
    expect(notifications.calls, ['cancelAll']);
  });

  test('armedAccordingToPlugin reports the PLUGIN record, not AlarmManager',
      () async {
    // Named for what it can actually answer. `pendingNotificationRequests()`
    // reads the plugin's SharedPreferences; no public API enumerates an app's
    // pending alarms, so nothing in-process is ground truth. Correctness does
    // not depend on it — `apply` re-asserts the whole desired set regardless.
    expect(await scheduler.armedAccordingToPlugin(), 0);
  });
}
