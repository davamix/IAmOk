@TestOn('vm')
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:i_am_ok/data/push_registration.dart';
import 'package:i_am_ok/data/user_repository.dart';
import 'package:test/test.dart';

/// **Nothing here may fail its caller**, and that is the whole file.
///
/// FCM is tier 2 (§3): a wake-up hint. Every failure below costs *latency* — the
/// watcher finds out at alarm time instead of within seconds — and none of them
/// costs correctness. So a phone with no Play Services, no signal, or a
/// Firestore write that is refused must all end up in the same place: nothing
/// registered, nothing thrown, and the app carrying on.
///
/// The one asymmetry worth stating: a token that is *wrong* is worse than a
/// token that is *missing*, because a missing one is retried on the next launch
/// while a wrong one looks registered forever. That is what the unregister
/// tests are about.
void main() {
  test('registers this install under the signed-in uid', () async {
    final users = _RecordingUsers();
    final registration =
        PushRegistration(users, messaging: _FakeMessaging(token: 'tok-abc'));

    expect(await registration.register(uid: 'uid-ana'), 'tok-abc');
    expect(users.saved, [('uid-ana', 'tok-abc')]);
  });

  test('a device that cannot produce a token registers nothing', () async {
    // Ordinary rather than exceptional: `getToken()` is a network round trip
    // through Play Services, and a phone in a lift has neither. The next launch
    // tries again.
    final users = _RecordingUsers();
    final registration =
        PushRegistration(users, messaging: _FakeMessaging(token: null));

    expect(await registration.register(uid: 'uid-ana'), isNull);
    expect(users.saved, isEmpty);
  });

  test('a getToken that THROWS is not an error the caller sees', () async {
    // No Play Services at all — a de-Googled handset, or a device where the
    // Firebase installation could not be created. The app is fully correct
    // without a push; it is only slower.
    final users = _RecordingUsers();
    final registration =
        PushRegistration(users, messaging: _FakeMessaging(throwing: true));

    expect(await registration.token(), isNull);
    expect(await registration.register(uid: 'uid-ana'), isNull);
    expect(users.saved, isEmpty);
  });

  test('a REFUSED token write is not an error the caller sees', () async {
    // The shape that would otherwise reach a screen: the rules reject the write
    // — a uid mismatch, a stale session — and `permission-denied` propagates out
    // of a launch. ADR-0004 maps that code to *refused* on the read path, where
    // it means something; here it must mean nothing at all.
    final registration = PushRegistration(
      _ThrowingUsers(),
      messaging: _FakeMessaging(token: 'tok-abc'),
    );

    expect(await registration.register(uid: 'uid-ana'), isNull);
  });

  test('unregistering deletes the document for this install only', () async {
    final users = _RecordingUsers();
    final registration =
        PushRegistration(users, messaging: _FakeMessaging(token: 'tok-abc'));

    await registration.unregister(uid: 'uid-ana');

    expect(users.deleted, [('uid-ana', 'tok-abc')]);
    expect(users.saved, isEmpty);
  });

  test('unregistering with no token available does nothing', () async {
    final users = _RecordingUsers();
    final registration =
        PushRegistration(users, messaging: _FakeMessaging(token: null));

    await registration.unregister(uid: 'uid-ana');

    expect(users.deleted, isEmpty);
  });

  test('a delete that throws does not stop a sign-out', () async {
    // Sign-out is the caller, and it must complete.
    final messaging = _FakeMessaging(token: 'tok-abc');
    final registration = PushRegistration(_ThrowingUsers(), messaging: messaging);

    await expectLater(registration.unregister(uid: 'uid-ana'), completes);
  });

  test('a delete that FAILS invalidates the device token instead', () async {
    // The row survived, and it belongs to a token that is still perfectly
    // valid — the app is installed and registered — so FCM would return success
    // and DELIVER. Nothing would ever answer UNREGISTERED and nothing would ever
    // prune it, and every later check-in of everyone the previous account
    // watched would push a name and a verified day to a phone now signed into
    // somebody else's account.
    //
    // Invalidating the device token is what makes the pruning backstop true.
    final messaging = _FakeMessaging(token: 'tok-abc');
    final registration = PushRegistration(_ThrowingUsers(), messaging: messaging);

    await registration.unregister(uid: 'uid-ana');

    expect(messaging.deleted, isTrue,
        reason: 'a surviving row must be made self-cleaning, or it is permanent');
  });

  test('a delete that SUCCEEDS leaves the device token alone', () async {
    // The other half, and the reason this is not simply "always delete the
    // token": on the success path the document is gone, so invalidating the
    // token would cost the next account on this phone a registration round trip
    // for nothing.
    final users = _RecordingUsers();
    final messaging = _FakeMessaging(token: 'tok-abc');

    await PushRegistration(users, messaging: messaging)
        .unregister(uid: 'uid-ana');

    expect(users.deleted, [('uid-ana', 'tok-abc')]);
    expect(messaging.deleted, isFalse);
  });

  test('a delete that never completes does not hang the sign-out', () async {
    // `DocumentReference.delete()` completes on SERVER acknowledgement, so on a
    // phone with no signal it simply does not complete. Unbounded, that is a
    // sign-out button that does nothing, forever — and it is worst on exactly
    // the device state where the orphaned row is created.
    final messaging = _FakeMessaging(token: 'tok-abc');
    final registration = PushRegistration(_HangingUsers(), messaging: messaging);

    await expectLater(
      registration.unregister(uid: 'uid-ana'),
      completes,
    );
    expect(messaging.deleted, isTrue,
        reason: 'a timeout is a failure like any other, and takes the same path');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a rotated token is re-registered, and the old one is left alone',
      () async {
    // The old document is deliberately NOT deleted here: this device no longer
    // knows that token, so it cannot prove it is dead. FCM answers that question
    // with UNREGISTERED on the next fan-out, and that is the only path that
    // prunes.
    final users = _RecordingUsers();
    final messaging = _FakeMessaging(token: 'tok-old');
    final registration = PushRegistration(users, messaging: messaging);

    await registration.register(uid: 'uid-ana');
    messaging.rotate('tok-new');
    await registration.register(uid: 'uid-ana');

    expect(users.saved, [('uid-ana', 'tok-old'), ('uid-ana', 'tok-new')]);
    expect(users.deleted, isEmpty);
  });

  test('the refresh stream is the plugin\'s own', () async {
    final messaging = _FakeMessaging(token: 'tok-abc');
    final registration = PushRegistration(_RecordingUsers(), messaging: messaging);

    final seen = <String>[];
    final subscription = registration.tokenRefreshes.listen(seen.add);
    messaging.rotate('tok-new');
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(seen, ['tok-new']);
  });
}

class _RecordingUsers implements UserRepository {
  final List<(String, String)> saved = [];
  final List<(String, String)> deleted = [];

  @override
  Future<void> saveToken({required String uid, required String token}) async {
    saved.add((uid, token));
  }

  @override
  Future<void> deleteToken({required String uid, required String token}) async {
    deleted.add((uid, token));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _HangingUsers implements UserRepository {
  @override
  Future<void> deleteToken({required String uid, required String token}) =>
      Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _ThrowingUsers implements UserRepository {
  @override
  Future<void> saveToken({required String uid, required String token}) async =>
      throw FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied');

  @override
  Future<void> deleteToken({required String uid, required String token}) async =>
      throw FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// Stands in for the plugin, which is a concrete class with no interface.
class _FakeMessaging implements FirebaseMessaging {
  _FakeMessaging({this.token, this.throwing = false});

  String? token;
  final bool throwing;

  /// Whether `deleteToken()` was called — the SDK-level invalidation, not the
  /// Firestore document delete. These are different things and the tests care
  /// about which one happened.
  bool deleted = false;

  final StreamController<String> _refreshes = StreamController<String>.broadcast();

  @override
  Future<void> deleteToken({String? senderId}) async {
    deleted = true;
    token = null;
  }

  void rotate(String next) {
    token = next;
    _refreshes.add(next);
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    if (throwing) {
      throw FirebaseException(plugin: 'firebase_messaging', code: 'unknown');
    }
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => _refreshes.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
