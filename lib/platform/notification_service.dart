import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../copy/notification_copy.dart';
import '../domain/domain.dart';
import 'alarm_ids.dart';

/// Channels, display, cancellation, and replace-by-id (§6).
///
/// ## Why three channels and not one
///
/// A channel is the unit Android gives the user for switching us off, so the
/// split is a correctness decision rather than a tidiness one.
///
/// [ADR-0004][] argues that notifying about lost access *daily* "lands in the
/// same channel as the real *No check-in from Mum yesterday*", and that
/// **training a family to swipe that channel cannot be undone**. The cadence was
/// the fix for the frequency; separating the channels is the fix for the
/// collision. A watcher who mutes "app problems" still gets told when their
/// relative misses a day, which is the one message this app exists to deliver.
///
/// Reminders are separated from warnings for the opposite reason: they are the
/// *only* frequent notification here, they go to a different person on a
/// different phone, and a false one costs nothing (§10's asymmetry table).
///
/// [ADR-0004]: ../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
class NotificationService {
  NotificationService(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  /// The watched person's 12:00 / 18:00 / 21:00 nudges.
  ///
  /// **Display-only.** No code runs when one fires (§10): a spurious reminder
  /// costs nothing, so this side never verifies before speaking, and boot
  /// recovery comes free from `ScheduledNotificationBootReceiver`.
  static const AndroidNotificationChannel remindersChannel =
      AndroidNotificationChannel(
    'reminders',
    'Daily reminders',
    description: 'Nudges to tap I\'m OK, at midday, evening and night.',
    importance: Importance.high,
  );

  /// The watcher's missed-day warning. The channel that must not be trained
  /// away.
  static const AndroidNotificationChannel warningsChannel =
      AndroidNotificationChannel(
    'warnings',
    'Missed check-ins',
    description: 'Tells you when someone you watch has not checked in.',
    importance: Importance.max,
  );

  /// Something is wrong with the app's own access (ADR-0004).
  ///
  /// Deliberately *not* [warningsChannel]: this reports a fault in the app, and
  /// a watcher who silences app faults must still hear about a missed day.
  static const AndroidNotificationChannel accessChannel =
      AndroidNotificationChannel(
    'access',
    'App problems',
    description: 'Tells you when I Am Ok cannot check on someone.',
    importance: Importance.high,
  );

  static const List<AndroidNotificationChannel> channels = [
    remindersChannel,
    warningsChannel,
    accessChannel,
  ];

  /// Creates the plugin and the channels. Called once per isolate that
  /// displays or schedules anything.
  ///
  /// [onTap] is only wired by the UI isolate; a background isolate that
  /// schedules a notification does not route taps.
  static Future<NotificationService> initialize({
    void Function(NotificationResponse)? onTap,
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();

    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: onTap,
    );

    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in channels) {
      await android?.createNotificationChannel(channel);
    }


    return NotificationService(plugin);
  }

  /// Whether the OS will actually show anything we post.
  ///
  /// This is what becomes [NotificationDelivery.unavailable]. On API 33+ a user
  /// can revoke `POST_NOTIFICATIONS` at any time, and Android auto-revokes it
  /// from apps nobody opens — §13 rates that High precisely because it happens
  /// to the watcher who never opens the app.
  /// Whether [channel] would actually show something.
  ///
  /// **App-level `areNotificationsEnabled()` is not enough**, and the gap is
  /// the one Decision 1 exists to close, left open on a different axis. That
  /// call maps to `NotificationManagerCompat.areNotificationsEnabled()`, which
  /// is app-wide: a user who switches off *just* the reminders channel — the
  /// single most likely thing an irritated reader does — leaves it returning
  /// true. The domain would then be told `available`, consume each reminder as
  /// delivered, and nothing would ever appear.
  ///
  /// A channel whose importance is `none` is switched off. A channel that does
  /// not exist yet is not: it is created on the next `initialize`.
  Future<bool> canPost({AndroidNotificationChannel? channel}) async {
    final android = _android;
    if (android == null) return false;
    if (!(await android.areNotificationsEnabled() ?? false)) return false;
    if (channel == null) return true;

    final channels = await android.getNotificationChannels() ?? const [];
    for (final existing in channels) {
      if (existing.id == channel.id) {
        return existing.importance != Importance.none;
      }
    }
    return true;
  }

  /// Asks for `POST_NOTIFICATIONS` (API 33+).
  ///
  /// Below 33 the permission does not exist; the platform reports enabled,
  /// which is the correct answer there rather than a special case here.
  Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? false;

  /// Whether exact alarms can still be scheduled (API 31+).
  ///
  /// Revocable, so it is re-read rather than remembered — the same reason §13
  /// models every permission as continuously observed state.
  Future<bool> canScheduleExact() async =>
      await _android?.canScheduleExactNotifications() ?? false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Arms one display-only reminder at its zoned instant.
  ///
  /// `zonedSchedule` with a [tz.TZDateTime], never a raw UTC offset — an offset
  /// captured today is wrong after the next DST transition (§11).
  /// Returns false when the reminder had to be armed **inexactly**.
  ///
  /// Exact first, because a reminder deferred by Doze into the middle of the
  /// night is worse than useless. §13 declares `USE_EXACT_ALARM` and notes it
  /// needs justifying in Play review.
  ///
  /// **But exact scheduling can be refused, and §13 promises it degrades rather
  /// than fails**: *"Deep-link to settings. Reminders degrade to inexact."*
  /// The plugin throws `exact_alarms_not_permitted` when the permission is
  /// absent, and nothing caught it — the exception propagated through
  /// `AlarmScheduler.apply` and `reconcile()` into the provider's error
  /// channel, replacing the whole screen with *"this phone could not get
  /// ready"* and skipping `replacePendingReminders` entirely.
  ///
  /// Unreachable on the API 33 test device, because `USE_EXACT_ALARM` makes
  /// `canScheduleExactAlarms()` unconditionally true there. Reachable **today**
  /// on API 31–32, where `SCHEDULE_EXACT_ALARM` is user-revocable via *Alarms &
  /// reminders* — and it becomes the default everywhere if Play refuses
  /// `USE_EXACT_ALARM` at Phase 8, since the fallback permission is denied by
  /// default when targeting Android 14+. A degraded reminder is worth far more
  /// than a screen that will not load.
  Future<bool> scheduleReminder(ScheduledReminder reminder) async {
    Future<void> schedule(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: AlarmIds.reminder(reminder.day, reminder.slot),
          title: NotificationCopy.reminderTitle,
          body: NotificationCopy.reminderBody(reminder.slot),
          scheduledDate: reminder.at,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              remindersChannel.id,
              remindersChannel.name,
              channelDescription: remindersChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.reminder,
            ),
          ),
          androidScheduleMode: mode,
        );

    try {
      await schedule(AndroidScheduleMode.exactAllowWhileIdle);
      return true;
    } on PlatformException catch (error) {
      if (error.code != 'exact_alarms_not_permitted') rethrow;
      // Still `allowWhileIdle`, so Doze defers it rather than dropping it.
      await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
      return false;
    }
  }

  Future<void> cancelReminder(DayKey day, ReminderSlot slot) =>
      _plugin.cancel(id: AlarmIds.reminder(day, slot));

  /// Everything currently armed, as the platform sees it.
  ///
  /// Used by the debug harness to check the store against reality. The store
  /// is what the reconciler diffs against; this is what actually exists, and a
  /// divergence between them is a real finding.
  Future<List<PendingNotificationRequest>> pending() =>
      _plugin.pendingNotificationRequests();

  Future<void> cancelAll() => _plugin.cancelAll();

  /// Shows a notification immediately. The debug harness's *fire alarm now*.
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
    required AndroidNotificationChannel channel,
  }) =>
      _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
}
