import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Where a tapped notification takes the reader.
///
/// The *lost access* notice says **"Open the app to see what to do."**
/// [ADR-0004][] makes that actionability the whole reason the message exists as
/// a fourth outcome rather than being folded into the offline one — so a tap
/// that lands nowhere hollows it out, and a promise the device does not keep is
/// the failure class this app can least afford.
///
/// ## Two arrival paths, and the cold one is the normal one here
///
/// A tap on a **running** app arrives through
/// `onDidReceiveNotificationResponse`. A tap that **launches** the app does not:
/// there was no app running to receive the callback, so the payload has to be
/// asked for at startup with `getNotificationAppLaunchDetails()`.
///
/// For this app the cold path is not an edge case. §13's argument for the health
/// panel is that a low-usage watcher never opens the app, and this notification
/// exists for exactly that person — so their app is closed almost by definition
/// at the moment they tap it.
///
/// ## Why a plain value and not a router
///
/// This holds the payload and nothing else. Navigation belongs to the
/// Presentation layer; the Platform edge's job is to make the fact available in
/// a form a widget can watch. Keeping it this small is also what lets the UI
/// isolate own it while the alarm isolate — which posts these notifications and
/// routes nothing — never touches it.
///
/// [ADR-0004]: ../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
class NotificationRouter {
  NotificationRouter._();

  static final NotificationRouter instance = NotificationRouter._();

  /// The link id of the most recently tapped notification, or null.
  ///
  /// A `ValueNotifier` rather than a stream so a late listener still sees a tap
  /// that arrived during startup — the cold-start case, where the payload is
  /// captured before any widget exists to be listening.
  final ValueNotifier<String?> tappedLink = ValueNotifier<String?>(null);

  /// Called by `flutter_local_notifications` when the app is already running.
  void onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    tappedLink.value = payload;
  }

  /// Called once at startup with the payload that launched the app, if any.
  void captureLaunch(String? payload) {
    if (payload == null || payload.isEmpty) return;
    tappedLink.value = payload;
  }

  /// Marks the tap as handled.
  ///
  /// Explicit rather than automatic, so the screen decides when it has actually
  /// shown the reader what they came for. Clearing it on read would lose the tap
  /// if the widget rebuilt in between.
  void consume() => tappedLink.value = null;
}
