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

  @override
  Future<void> scheduleReminder(ScheduledReminder reminder) async {
    calls.add('schedule ${reminder.day} ${reminder.slot.name}');
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
        .apply(toCancel: inMadrid, toSchedule: inNewYork)
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
      toSchedule: const {},
    );
    expect(notifications.calls, ['cancel 2026-08-17 midday']);
  });

  test('a schedule-only diff issues no cancels', () async {
    await scheduler.apply(
      toCancel: const {},
      toSchedule: {reminderOn('2026-08-17', ReminderSlot.night)},
    );
    expect(notifications.calls, ['schedule 2026-08-17 night']);
  });

  test('an empty diff touches the platform not at all', () async {
    await scheduler.apply(toCancel: const {}, toSchedule: const {});
    expect(notifications.calls, isEmpty,
        reason: 'a no-op reconcile must be a no-op at the platform too');
  });

  test('cancelAll goes straight through', () async {
    await scheduler.cancelAll();
    expect(notifications.calls, ['cancelAll']);
  });

  test('armedOnPlatform asks the PLATFORM, not the store', () async {
    // The store is what the reconciler diffs against; this is what actually
    // exists. On a handset that silently dropped scheduled alarms, only this
    // number changes — which is the finding the debug harness is built to
    // surface.
    expect(await scheduler.armedOnPlatform(), 0);
  });
}
