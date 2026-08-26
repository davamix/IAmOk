@TestOn('vm')
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/data/check_in_repository.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// **A tap must never fail because the network did.**
///
/// The Tap screen is the one action this app asks of an elderly person, and it
/// is asked every morning. Phase 4 gives the tap somewhere to go — a Firestore
/// write — and the whole risk of that is the tap becoming contingent on it: a
/// phone with no signal, a spinner that never resolves, and a person who tapped
/// being told she has not.
///
/// So the local record comes first and the sync is fired, not awaited. These
/// tests pin that, including the parts a happy-path test would never notice.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    await store.setDeviceTimezone('Europe/Madrid');
  });

  tearDown(() => store.close());

  WatchedReconcileService service({
    CheckInRepository? checkIns,
    String selfUid = 'uid-mum',
  }) =>
      WatchedReconcileService(
        store: store,
        clock: FixedClock(at(madrid, 2026, 8, 21, 9, 14)),
        alarms: _NoAlarms(),
        notificationsEnabled: () async => true,
        checkIns: checkIns,
        selfUid: selfUid,
      );

  test('the tap is recorded locally before anything is sent', () async {
    final state = await service().tap(selfUid: 'uid-mum');

    expect(state.hasTappedToday, isTrue);
    // Compared as an INSTANT, not as a value: the store round-trips epoch
    // milliseconds, so what comes back is a UTC `DateTime` rather than the
    // `TZDateTime` that went in. Same moment, different subclass — and asserting
    // equality here would be asserting which class the fixture happened to
    // build, which is the note `local_store_test.dart` opens with.
    expect(
      (await store.checkInOn(day('2026-08-21')))?.deviceTappedAt,
      isNotNull,
    );
    expect(
      (await store.checkInOn(day('2026-08-21')))!
          .deviceTappedAt
          .isAtSameMomentAs(at(madrid, 2026, 8, 21, 9, 14)),
      isTrue,
    );
  });

  test('a write that THROWS does not fail the tap', () async {
    // The case that matters. Firestore's own persistence queues an offline
    // write, but the call can still throw — a permission problem, a malformed
    // path, an SDK in a state nobody predicted. None of that is a reason to tell
    // somebody her tap did not happen.
    final state = await service(checkIns: _ThrowingRepository())
        .tap(selfUid: 'uid-mum');

    expect(state.hasTappedToday, isTrue);
    expect(state.tapFailed, isFalse,
        reason: 'tapFailed is about the LOCAL record, which succeeded');
  });

  test('a write that never completes does not hang the tap', () async {
    // The realistic offline shape: the future completes only when the SERVER
    // has the write, so on a phone with no signal it simply does not complete.
    // Awaiting it would leave the screen mid-tap indefinitely.
    final repository = _HangingRepository();

    final state = await service(checkIns: repository)
        .tap(selfUid: 'uid-mum')
        .timeout(const Duration(seconds: 2));

    expect(state.hasTappedToday, isTrue);
    expect(repository.started, isTrue,
        reason: 'fired, not skipped — the write is still owed and the SDK is '
            'the retry queue');
  });

  test('signed out, the tap is local only and nothing is attempted', () async {
    // Not an error state. There is no `users/{uid}` to file under and no link
    // that could carry it to anyone, and the person still tapped.
    final repository = _RecordingRepository();

    final state = await service(
      checkIns: repository,
      selfUid: LocalStore.signedOutUid,
    ).tap(selfUid: LocalStore.signedOutUid);

    expect(state.hasTappedToday, isTrue);
    expect(repository.writes, isEmpty);
  });

  test('the day written is the DEVICE\'s, at tap time — never the server\'s',
      () async {
    // §11's correction to HANDOVER.md, asserted at the boundary where it would
    // be undone. A tap at 23:50 Madrid is still the 21st there; a server
    // timestamp resolving after midnight UTC would file it on the 22nd, and a
    // day she tapped would be recorded as a day she did not.
    final repository = _RecordingRepository();
    final late = WatchedReconcileService(
      store: store,
      clock: FixedClock(at(madrid, 2026, 8, 21, 23, 50)),
      alarms: _NoAlarms(),
      notificationsEnabled: () async => true,
      checkIns: repository,
      selfUid: 'uid-mum',
    );

    await late.tap(selfUid: 'uid-mum');
    // The write is fired rather than awaited, so give the microtask a turn.
    await Future<void>.delayed(Duration.zero);

    expect(repository.writes.single.day, day('2026-08-21'));
    expect(repository.writes.single.timezone, 'Europe/Madrid');
  });
}

class _RecordingRepository implements CheckInRepository {
  final List<CheckIn> writes = [];

  @override
  Future<void> write(String watchedUid, CheckIn checkIn) async {
    writes.add(checkIn);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _ThrowingRepository implements CheckInRepository {
  @override
  Future<void> write(String watchedUid, CheckIn checkIn) async =>
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _HangingRepository implements CheckInRepository {
  bool started = false;

  @override
  Future<void> write(String watchedUid, CheckIn checkIn) {
    started = true;
    // Never completes — a queued offline write.
    return Completer<void>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// The alarm scheduler is not what this file is about.
///
/// Implemented explicitly rather than through `noSuchMethod`, which cannot
/// produce the right Future type per member and fails at the call site with a
/// cast error that reads like a defect in the code under test.
class _NoAlarms implements AlarmScheduler {
  @override
  Future<bool> apply({
    required Set<ScheduledReminder> desired,
    required Set<ScheduledReminder> toCancel,
    required bool hasAudience,
  }) async =>
      true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<int> armedAccordingToPlugin() async => 0;
}
