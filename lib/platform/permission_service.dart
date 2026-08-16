import '../domain/domain.dart';
import 'notification_service.dart';

/// The permission facts §13 turns into health-panel rows.
///
/// **Permissions are continuously observed state, not an onboarding gate.**
/// Android 11+ auto-resets permissions for unused apps, which is a live threat
/// for a watcher who never opens the app — they would silently stop receiving
/// anything, and §17 rates that High for exactly the reason this app exists. So
/// these are re-read on every resume rather than asked once and remembered.
///
/// Phase 2 consumes one of them for real: [notificationsEnabled] is what becomes
/// [NotificationDelivery.unavailable], the input the Phase 1 gate added so a
/// muted phone stops silently consuming reminders it never delivered.
///
/// ## Why this is not `permission_handler`
///
/// §15 names `permission_handler` as the intended package and it is **not** used
/// here, which is a deliberate deviation recorded rather than made quietly.
///
/// `permission_handler_android` 14.0.0 does not compile below **API 37** — it
/// references `Manifest.permission.ACCESS_LOCAL_NETWORK` and
/// `Build.VERSION_CODES.CINNAMON_BUN`, neither of which exists in the SDK this
/// project builds against. Pinning its `compileSdk` down merely moves the
/// failure into its own source.
///
/// Weighed against that: of the four §13 items, **three are answered natively by
/// `flutter_local_notifications`**, which this app needs anyway — and the
/// notification one is answered *better*, see [notificationsEnabled]. The only
/// item it cannot answer is the battery-optimisation exemption, which is a
/// health-panel row and therefore **Phase 7**, not Phase 2.
///
/// So the dependency buys one Phase 7 row and costs the Phase 2 build. It comes
/// back when the panel needs it, against whatever version compiles then.
class PermissionService {
  const PermissionService(this._notifications);

  final NotificationService _notifications;

  /// Whether anything we post would actually be shown.
  ///
  /// Asked of the **notification manager**, not of a runtime-permission API,
  /// and that is the more truthful question. A channel the user switched off,
  /// or a whole app the user blocked, both silence us *without*
  /// `POST_NOTIFICATIONS` ever being revoked. What the domain needs to know is
  /// "will this appear", not "was the permission granted" — and only the first
  /// is safe to consume a reminder against.
  Future<bool> notificationsEnabled() =>
      _notifications.canPost(channel: NotificationService.remindersChannel);

  /// Requests `POST_NOTIFICATIONS` (API 33+).
  ///
  /// Returns the granted state. Below API 33 the permission does not exist and
  /// the platform reports enabled, which is the correct answer there.
  Future<bool> requestNotifications() => _notifications.requestPermission();

  /// Whether exact alarms can be scheduled (API 31+).
  ///
  /// Without it reminders degrade to inexact and can be deferred by Doze — a
  /// midday nudge arriving at 15:00 is a different product. §13 deep-links to
  /// settings rather than treating this as fatal.
  Future<bool> canScheduleExactAlarms() => _notifications.canScheduleExact();

  /// Everything Phase 2 can answer, for the harness and later the panel.
  Future<PermissionSnapshot> snapshot() async => PermissionSnapshot(
        notifications: await notificationsEnabled(),
        exactAlarms: await canScheduleExactAlarms(),
      );

  /// The delivery state to hand the reconciler.
  ///
  /// [appInForeground] is the caller's business, because only the caller knows
  /// whether the screen currently showing already answers the notification —
  /// that is what makes it [NotificationDelivery.redundant] rather than merely
  /// undelivered.
  /// A value read, with the decision itself in the domain where it is tested.
  Future<NotificationDelivery> delivery({bool appInForeground = false}) async =>
      NotificationDelivery.from(
        canPost: await notificationsEnabled(),
        appInForeground: appInForeground,
      );
}

/// A point-in-time reading of the §13 items Phase 2 can see.
///
/// Battery optimisation and auto-revoke exemption are absent rather than
/// stubbed false: a panel row that reports a state nobody measured is worse
/// than a row that is honestly not there yet. They arrive in Phase 7.
class PermissionSnapshot {
  const PermissionSnapshot({
    required this.notifications,
    required this.exactAlarms,
  });

  /// Without this the app is **inert**. §13 makes it a hard gate with a
  /// plain-language explanation, and it is the one the domain is told about.
  final bool notifications;

  final bool exactAlarms;

  /// Whether every item Phase 2 measures is green.
  bool get allGood => notifications && exactAlarms;

  @override
  String toString() => 'PermissionSnapshot(notifications: $notifications, '
      'exactAlarms: $exactAlarms)';
}
