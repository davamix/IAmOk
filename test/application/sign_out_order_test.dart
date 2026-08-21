@TestOn('vm')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/application/providers.dart';
import 'package:i_am_ok/data/auth_repository.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/data/push_registration.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/clock_service.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/permission_service.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/zones.dart';

/// **The ORDER of two lines is the security property here, and nothing watched
/// them run.**
///
/// `firestore.rules` grants `users/{uid}/tokens/{token}` deletion to
/// `isSelf(uid)` only. Sign out first and the document becomes one *nothing on
/// this device may ever remove* — while `onCheckInCreated` goes on delivering
/// `watchedName` and the day someone was verified alive to a phone that has
/// since signed into a different account. Neither party sees anything wrong.
///
/// There is no `UNREGISTERED` backstop for that row, which is the part that made
/// it worth a test rather than a comment: the app is still installed and the
/// token is still valid, so FCM returns **success and delivers**. The row is
/// permanent.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
  });

  tearDown(() => store.close());

  // `signOut()` touches `auth` and `push` and nothing else, so the notification
  // service is a stand-in rather than a dependency — `initialize()` needs a real
  // plugin platform that a VM test does not have.
  AppServices services({
    required String selfUid,
    required _RecordingPush push,
    required _RecordingAuth auth,
  }) {
    final notifications = _FakeNotifications();
    return AppServices(
      store: store,
      clock: FixedClock(at(madrid, 2026, 8, 21, 10)),
      notifications: notifications,
      alarms: NotificationAlarmScheduler(notifications),
      permissions: PermissionService(notifications),
      clockService: const ClockService(),
      selfUid: selfUid,
      auth: auth,
      push: push,
    );
  }

  test('the token document goes BEFORE the session', () async {
    final events = <String>[];
    final push = _RecordingPush(events);
    final auth = _RecordingAuth(events, currentUid: 'uid-ana');

    await services(selfUid: 'uid-ana', push: push, auth: auth).signOut();

    expect(events, ['unregister uid-ana', 'signOut'],
        reason: 'reversing these leaves a token document the rules will never '
            'let this device delete');
  });

  test('it uses the LIVE uid, not the launch-time snapshot', () async {
    // The hole this test exists for. `selfUid` is captured at launch, so in a
    // sign-in -> sign-out session with no restart it is still the signed-out
    // sentinel — while the sign-in path has already registered a token under the
    // new uid, because it passes the fresh one explicitly.
    //
    // Guarding on the snapshot therefore SKIPPED the unregister in exactly the
    // case it exists for. Debug-only today; it stops being debug-only the moment
    // Phase 5 builds a real sign-in screen.
    final events = <String>[];
    final push = _RecordingPush(events);
    final auth = _RecordingAuth(events, currentUid: 'uid-freshly-signed-in');

    await services(selfUid: LocalStore.signedOutUid, push: push, auth: auth)
        .signOut();

    expect(events, ['unregister uid-freshly-signed-in', 'signOut']);
  });

  test('signed out with no live session, nothing is unregistered', () async {
    final events = <String>[];
    final push = _RecordingPush(events);
    final auth = _RecordingAuth(events, currentUid: null);

    await services(selfUid: LocalStore.signedOutUid, push: push, auth: auth)
        .signOut();

    expect(events, ['signOut'],
        reason: 'there is no token document to remove and no uid to remove it '
            'under; signing out must still work');
  });

  test('an unregister that fails does not stop the sign-out', () async {
    // A sign-out must complete. `PushRegistration.unregister` both times out and
    // swallows, so this asserts the contract from the caller's side.
    final events = <String>[];
    final push = _RecordingPush(events, throws: true);
    final auth = _RecordingAuth(events, currentUid: 'uid-ana');

    await services(selfUid: 'uid-ana', push: push, auth: auth).signOut();

    expect(events.last, 'signOut');
  });
}

class _FakeNotifications extends NotificationService {
  _FakeNotifications() : super(FlutterLocalNotificationsPlugin());
}

class _RecordingPush implements PushRegistration {
  _RecordingPush(this.events, {this.throws = false});

  final List<String> events;
  final bool throws;

  @override
  Future<void> unregister({required String uid}) async {
    events.add('unregister $uid');
    if (throws) throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _RecordingAuth implements AuthRepository {
  _RecordingAuth(this.events, {this.currentUid});

  final List<String> events;

  @override
  final String? currentUid;

  @override
  Future<void> signOut() async => events.add('signOut');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
