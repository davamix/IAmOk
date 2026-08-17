@TestOn('vm')
library;

import 'dart:io';

import 'package:i_am_ok/data/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

/// The reconcile lock, and the cross-connection behaviour it rests on.
///
/// ## Why this file exists at all
///
/// Every other `LocalStore` test opens `inMemoryDatabasePath`, which is a
/// *single connection to a private database*. The Phase 2 summary named that as
/// a known gap — *"`LocalStore` is never tested across two connections to one
/// file, which is the actual §4 cross-isolate contract"* — and said it became
/// load-bearing the moment Phase 3 landed the alarm isolate.
///
/// It is now more than load-bearing: the reconcile lock is a **correctness**
/// mechanism whose entire job is to behave correctly between two connections. A
/// lock tested on one connection asserts nothing at all — it would pass against
/// an implementation that ignored SQLite completely and kept a bool in memory.
///
/// So every test here opens **two real `LocalStore`s on one real file**, which
/// is the closest a desktop test can get to the shape of two isolates.
///
/// ## What it still cannot tell us
///
/// These run against `sqflite_common_ffi`, which binds desktop SQLite, while the
/// app runs `sqflite` over Android's. That is the same API-level axis that let
/// Phase 2 ship SQL which could not parse below API 29 with 500+ tests green.
/// **The device matrix owes a real two-isolate check.** What these tests do
/// establish is that the logic is right wherever SQLite behaves like SQLite.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String path;
  late LocalStore a;
  late LocalStore b;

  /// A fixed instant. The lock takes `now` as a parameter for the same reason
  /// everything else here does — the guard in `domain_purity_test.dart` covers
  /// `local_store.dart`, and a lease that read the clock itself could not be
  /// tested for expiry without sleeping.
  final t0 = DateTime.utc(2026, 8, 17, 10);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('i_am_ok_lock');
    path = '${dir.path}/store.db';
    // Two connections to ONE file — the point of the whole file.
    a = await LocalStore.open(path: path);
    b = await LocalStore.open(path: path);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    dir.deleteSync(recursive: true);
  });

  group('two connections to one file', () {
    test('see each other\'s writes — the §4 contract, asserted', () {
      // The premise every background isolate depends on. If this fails, nothing
      // else in this app works and the failure is invisible on one connection.
      return expectLater(
        a
            .setDeviceTimezone('Europe/Madrid')
            .then((_) => b.deviceTimezone()),
        completion('Europe/Madrid'),
      );
    });

    test('a lock taken on one is visible on the other', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      final holder = await b.reconcileLockHolder('watched');
      expect(holder?.owner, 'alarm');
    });
  });

  group('the lock excludes', () {
    test('a second holder is refused while the lease is live', () async {
      final first = await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30));
      final second = await b.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      expect(first, isTrue);
      expect(second, isFalse,
          reason: 'this is the whole mechanism: two overlapping reconciles '
              'each diff against their own snapshot, and the loser strands an '
              'alarm the app can never cancel');
    });

    test('the refused caller does not steal the lease', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30));
      await b.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      expect((await b.reconcileLockHolder('watched'))?.owner, 'ui',
          reason: 'a failed acquire that overwrote the row would hand the lock '
              'to the caller that was just told it could not have it');
    });
  });

  group('the lease expires', () {
    test('an expired lock may be taken by anyone', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      final later = t0.add(const Duration(seconds: 31));
      final taken = await b.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: later, lease: const Duration(seconds: 30));

      expect(taken, isTrue,
          reason: 'a bare isolate is killed as its normal ending, not as an '
              'error. A lock held until explicit release would eventually be '
              'held forever by a process that no longer exists, and the app '
              'would go quietly inert — the one failure it cannot detect.');
    });

    // Both sides of the boundary are pinned, because "expires at T" is exactly
    // the kind of edge that gets rewritten by whichever comparison the next
    // person types. The lease covers [acquired, expiresAt) — held up to the
    // instant, over at it.
    test('one millisecond before expiry it is still held', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      final justBefore = t0.add(const Duration(seconds: 30, milliseconds: -1));
      expect(
        await b.acquireReconcileLock(
            scope: 'watched',
            owner: 'ui', now: justBefore, lease: const Duration(seconds: 30)),
        isFalse,
      );
    });

    test('exactly at expiry it is available', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'alarm', now: t0, lease: const Duration(seconds: 30));

      final exactly = t0.add(const Duration(seconds: 30));
      expect(
        await b.acquireReconcileLock(
            scope: 'watched',
            owner: 'ui', now: exactly, lease: const Duration(seconds: 30)),
        isTrue,
      );
    });

    test('a live lease refuses even the same owner string', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30));

      expect(
        await a.acquireReconcileLock(
            scope: 'watched',
            owner: 'ui', now: t0, lease: const Duration(seconds: 30)),
        isFalse,
        reason: 'the first draft exempted the current holder so it could '
            'refresh its lease. A service test caught what that buys: two runs '
            'whose tokens happen to match — same label, same instant — would '
            'each be handed the lock and the exclusion would silently not '
            'exist. Nothing here acquires twice, so the exemption protected '
            'against nothing and disabled the mechanism under exactly the '
            'timing that makes it necessary. Callers make the owner unique per '
            'acquisition instead.',
      );
    });
  });

  /// **The regression the device found, and the reason the lease has a scope.**
  ///
  /// The watched and watcher sides are independent reconciles over disjoint
  /// alarm sets — `kind='reminder'` against `kind='warning'`, different platform
  /// ids, nothing shared — and both run when the app opens. With one global lock
  /// the loser skipped its alarm work entirely, so **every launch re-armed one
  /// side and left the other unarmed.** Measured on the POCO F3 after a
  /// force-stop: 18 reminders and 0 warnings, then 0 reminders and 12 warnings
  /// once the watcher reconcile was added to app open.
  ///
  /// Serialising work that cannot conflict is not caution — it is a second way
  /// to leave alarms unarmed, which is the exact outcome the lease exists to
  /// prevent.
  group('scopes do not block each other', () {
    test('the watcher may work while the watched side holds its lease',
        () async {
      final watched = await a.acquireReconcileLock(
        scope: 'watched',
        owner: 'ui',
        now: t0,
        lease: const Duration(seconds: 30),
      );
      final watcher = await b.acquireReconcileLock(
        scope: 'watcher',
        owner: 'ui',
        now: t0,
        lease: const Duration(seconds: 30),
      );

      expect(watched, isTrue);
      expect(watcher, isTrue,
          reason: 'one lock for both sides meant every app open re-armed one '
              'and left the other unarmed');
    });

    test('releasing one scope leaves the other held', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui',
          now: t0,
          lease: const Duration(seconds: 30));
      await a.acquireReconcileLock(
          scope: 'watcher',
          owner: 'ui',
          now: t0,
          lease: const Duration(seconds: 30));

      await a.releaseReconcileLock('watched', 'ui');

      expect(await b.reconcileLockHolder('watched'), isNull);
      expect((await b.reconcileLockHolder('watcher'))?.owner, 'ui');
    });
  });

  group('release', () {
    test('frees the lock for another connection', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30));
      await a.releaseReconcileLock('watched', 'ui');

      expect(await b.reconcileLockHolder('watched'), isNull);
      expect(
        await b.acquireReconcileLock(
            scope: 'watched',
            owner: 'alarm', now: t0, lease: const Duration(seconds: 30)),
        isTrue,
      );
    });

    test('by a NON-holder does nothing', () async {
      await a.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30));

      // The case that matters: a slow run whose lease expired, finishing late
      // and releasing a lock that now belongs to a different isolate. Without
      // the owner guard the exclusion silently stops existing under exactly the
      // load that made it necessary.
      await b.releaseReconcileLock('watched', 'alarm');

      expect((await b.reconcileLockHolder('watched'))?.owner, 'ui');
    });
  });

  test('a v1 store upgrades without losing anything', () async {
    // The migration is additive on purpose. An installed app that loses this
    // store loses `warningsShownFor`, and every standing warning fires again the
    // next morning — so a drop-and-recreate would be a data-loss bug wearing a
    // migration's clothes.
    final old = Directory.systemTemp.createTempSync('i_am_ok_v1');
    addTearDown(() => old.deleteSync(recursive: true));
    final oldPath = '${old.path}/store.db';

    final v1 = await databaseFactory.openDatabase(
      oldPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
              'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        },
      ),
    );
    await v1.insert('settings', {'key': 'device_timezone', 'value': 'Europe/Madrid'});
    await v1.close();

    final upgraded = await LocalStore.open(path: oldPath);
    addTearDown(upgraded.close);

    expect(await upgraded.deviceTimezone(), 'Europe/Madrid',
        reason: 'the v1 row survived the upgrade');
    expect(
      await upgraded.acquireReconcileLock(
          scope: 'watched',
          owner: 'ui', now: t0, lease: const Duration(seconds: 30)),
      isTrue,
      reason: 'and the v2 table exists',
    );
  });
}
