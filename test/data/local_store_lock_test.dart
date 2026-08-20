@TestOn('vm')
library;

import 'dart:io';

import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
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
/// So every test here opens **two real `LocalStore`s on one real file**.
///
/// ## That is NOT the shape the device has — measured 2026-08-20
///
/// This used to claim two connections were "the closest a desktop test can get
/// to the shape of two isolates". They are not: **on Android the isolates share
/// ONE connection.** `android_alarm_manager_plus` runs the alarm isolate in the
/// app's own process and `sqflite`'s plugin keeps a static
/// `_singleInstancesByPath`, so the second `LocalStore.open()` is handed the
/// first one's `databaseId`. See `LocalStore.open` for the defect that taught us
/// this, and ADR-0006's amendment.
///
/// So these tests exercise a *different* topology from the shipped one. That is
/// not useless — two connections is the stricter case, and a lock that works
/// across real connections is what Phase 4 would need if an isolate ever ran in
/// its own process — but it means **a green run here says nothing about how the
/// lease behaves on the phone**.
///
/// What the device showed (2026-08-20, `docs/testing/device-matrix.md`): with the
/// UI live and the alarm isolate reconciling, the store and the platform's alarm
/// set stayed identical and nothing threw. What it did **not** show is the
/// exclusion actually firing — a refused lease is caught and returned as `false`
/// silently, so it cannot be observed from outside.
///
/// The prediction still owed a test: with one shared connection each isolate has
/// its own Dart-side transaction lock, so a second `BEGIN EXCLUSIVE` should fail
/// as a **nested** transaction rather than block on SQLite's cross-connection
/// lock — the same refusal by a different route.
///
/// ## What it still cannot tell us
///
/// These run against `sqflite_common_ffi`, which binds desktop SQLite, while the
/// app runs `sqflite` over Android's. That is the same API-level axis that let
/// Phase 2 ship SQL which could not parse below API 29 with 500+ tests green.
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

  group('migrating a real v1 store', () {
    /// **v1's schema, written out, and deliberately not imported.**
    ///
    /// The first version of this test built a "v1" holding a single `settings`
    /// table — so the upgrade had six tables' worth of nothing to lose, and it
    /// could not have detected the data loss it exists to prevent. A
    /// drop-and-recreate would have passed it.
    ///
    /// Copying the DDL is the point rather than the cost. Reading it from
    /// `LocalStore` would make the fixture whatever today's schema is, and a
    /// migration test whose "before" tracks its "after" asserts nothing at all.
    /// These seven statements are what shipped as v1 and are now frozen.
    const v1Schema = [
      '''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''',
      '''
      CREATE TABLE links (
        id                 TEXT PRIMARY KEY,
        watched_uid        TEXT NOT NULL,
        watcher_uid        TEXT NOT NULL,
        status             TEXT NOT NULL,
        watched_name       TEXT NOT NULL,
        watcher_name       TEXT NOT NULL,
        watched_timezone   TEXT NOT NULL,
        active_from        TEXT NOT NULL,
        warning_local_time TEXT NOT NULL,
        created_at         INTEGER NOT NULL,
        accepted_at        INTEGER
      )''',
      '''
      CREATE TABLE check_ins (
        day              TEXT PRIMARY KEY,
        device_tapped_at INTEGER NOT NULL,
        timezone         TEXT NOT NULL
      )''',
      '''
      CREATE TABLE watcher_cache (
        link_id                 TEXT PRIMARY KEY REFERENCES links(id) ON DELETE CASCADE,
        away_from               TEXT,
        away_through            TEXT,
        last_confirmed_day      TEXT,
        last_reconcile_at       INTEGER,
        access_lost_since       TEXT,
        access_lost_cause       TEXT,
        access_lost_notified_on TEXT
      )''',
      '''
      CREATE TABLE warnings_shown (
        link_id TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
        day     TEXT NOT NULL,
        outcome TEXT NOT NULL,
        PRIMARY KEY (link_id, day)
      )''',
      '''
      CREATE TABLE pending_alarms (
        kind     TEXT NOT NULL,
        day      TEXT NOT NULL,
        slot     TEXT NOT NULL DEFAULT '',
        link_id  TEXT NOT NULL DEFAULT '',
        fires_at INTEGER NOT NULL,
        zone     TEXT NOT NULL,
        PRIMARY KEY (kind, day, slot, link_id)
      )''',
      '''
      CREATE TABLE self_away (
        id          INTEGER PRIMARY KEY CHECK (id = 0),
        from_day    TEXT NOT NULL,
        through_day TEXT NOT NULL,
        set_by      TEXT,
        set_by_name TEXT
      )''',
    ];

    /// A v1 file with **a row in every table**, because a table nobody wrote to
    /// cannot demonstrate that its contents survived.
    Future<String> seedV1() async {
      final old = Directory.systemTemp.createTempSync('i_am_ok_v1');
      addTearDown(() => old.deleteSync(recursive: true));
      final path = '${old.path}/store.db';

      final v1 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final statement in v1Schema) {
              await db.execute(statement);
            }
          },
        ),
      );
      await v1.insert('settings',
          {'key': 'device_timezone', 'value': 'Europe/Madrid'});
      await v1.insert('links', {
        'id': 'mum_ana',
        'watched_uid': 'mum',
        'watcher_uid': 'ana',
        'status': 'accepted',
        'watched_name': 'Mum',
        'watcher_name': 'Ana',
        'watched_timezone': 'Europe/Madrid',
        'active_from': '2026-08-01',
        'warning_local_time': '10:00',
        'created_at': DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
      });
      await v1.insert('check_ins', {
        'day': '2026-08-16',
        'device_tapped_at': DateTime.utc(2026, 8, 16, 9, 14).millisecondsSinceEpoch,
        'timezone': 'Europe/Madrid',
      });
      await v1.insert('watcher_cache', {
        'link_id': 'mum_ana',
        'last_confirmed_day': '2026-08-15',
        'last_reconcile_at': DateTime.utc(2026, 8, 17, 8).millisecondsSinceEpoch,
      });
      await v1.insert('warnings_shown', {
        'link_id': 'mum_ana',
        'day': '2026-08-14',
        'outcome': 'warnOnline',
      });
      await v1.insert('pending_alarms', {
        'kind': 'warning',
        'day': '2026-08-18',
        'link_id': 'mum_ana',
        'fires_at': DateTime.utc(2026, 8, 18, 8).millisecondsSinceEpoch,
        'zone': 'Europe/Madrid',
      });
      await v1.insert('self_away', {
        'id': 0,
        'from_day': '2026-08-20',
        'through_day': '2026-08-22',
        'set_by': 'ana',
        'set_by_name': 'Ana',
      });
      await v1.close();
      return path;
    }

    test('every table keeps its rows', () async {
      // The migration is additive on purpose. An installed app that loses this
      // store loses `warningsShownFor`, and every standing warning fires again
      // the next morning — so a drop-and-recreate would be a data-loss bug
      // wearing a migration's clothes.
      final upgraded = await LocalStore.open(path: await seedV1());
      addTearDown(upgraded.close);

      final dump = await upgraded.dump();
      for (final table in [
        'settings',
        'links',
        'check_ins',
        'watcher_cache',
        'warnings_shown',
        'pending_alarms',
        'self_away',
      ]) {
        expect(dump[table], hasLength(1), reason: '$table lost its row');
      }
    });

    test('the standing warning in particular', () async {
      // Named on its own because it is the row whose loss is not merely data
      // loss: `warningsShownFor` is what stops a warning being posted twice, so
      // an empty one means every standing warning fires again — a second false
      // claim to a family, produced by an upgrade.
      final upgraded = await LocalStore.open(path: await seedV1());
      addTearDown(upgraded.close);

      final cache = await upgraded.watcherCache('mum_ana');
      expect(cache.warningsShownFor,
          {DayKey(2026, 8, 14): WarningOutcome.warnOnline});
      expect(cache.lastConfirmedDay, DayKey(2026, 8, 15));
    });

    test('and the v3 lock table exists afterwards', () async {
      final upgraded = await LocalStore.open(path: await seedV1());
      addTearDown(upgraded.close);

      expect(
        await upgraded.acquireReconcileLock(
            scope: 'watched',
            owner: 'ui',
            now: t0,
            lease: const Duration(seconds: 30)),
        isTrue,
      );
    });

    /// **v2 → v3, which is the path a real device actually took.**
    ///
    /// The POCO F3 ran `00b9b99` — schema v2 — before `ff0e785` bumped to v3, so
    /// this migration has already executed on the owner's phone with nothing
    /// pinning it. From v1 the `DROP TABLE IF EXISTS reconcile_lock` is a no-op;
    /// from **v2 it discards a real table**, because v2 keyed the lock
    /// `id INTEGER PRIMARY KEY CHECK (id = 0)` — a single global row — and v3
    /// re-keys it by scope so the watched and watcher sides cannot block each
    /// other. One branch, two genuinely different paths, and only one was
    /// covered.
    ///
    /// The lock table losing its row is explicitly acceptable — it holds nothing
    /// but ephemeral leases. What must survive is everything else.
    Future<String> seedV2() async {
      final path = await seedV1();
      final v2 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (_, _) async {},
        ),
      );
      // v2's shape, written out and frozen for the same reason v1's is.
      await v2.execute('''
        CREATE TABLE reconcile_lock (
          id         INTEGER PRIMARY KEY CHECK (id = 0),
          owner      TEXT NOT NULL,
          expires_at INTEGER NOT NULL
        )''');
      await v2.insert('reconcile_lock', {
        'id': 0,
        'owner': 'ui:1:0',
        'expires_at': t0.millisecondsSinceEpoch,
      });
      await v2.close();
      return path;
    }

    test('v2 keeps every table that matters', () async {
      final upgraded = await LocalStore.open(path: await seedV2());
      addTearDown(upgraded.close);

      final dump = await upgraded.dump();
      for (final table in [
        'settings',
        'links',
        'check_ins',
        'watcher_cache',
        'warnings_shown',
        'pending_alarms',
        'self_away',
      ]) {
        expect(dump[table], hasLength(1), reason: '$table lost its row');
      }
      expect(
        (await upgraded.watcherCache('mum_ana')).warningsShownFor,
        {DayKey(2026, 8, 14): WarningOutcome.warnOnline},
        reason: 'the row whose loss re-fires a warning at a family',
      );
    });

    test('v4 adds last_decided_day, and the v1 row survives it', () async {
      // ADR-0009's column. Additive, like every step in this ladder, so the row
      // seeded at v1 must still be there with its warning intact.
      final upgraded = await LocalStore.open(path: await seedV1());
      addTearDown(upgraded.close);

      final cache = await upgraded.watcherCache('mum_ana');
      expect(cache.lastDecidedDay, isNull,
          reason: 'an upgraded store has decided nothing yet, and null means '
              'the window is {D} alone — no retro-warning about the days this '
              'device was on an older build');
      expect(cache.warningsShownFor,
          {DayKey(2026, 8, 14): WarningOutcome.warnOnline});

      // And it is writable, i.e. the column really is there rather than merely
      // absent from a query that names its columns.
      await upgraded.saveWatcherCache(
        'mum_ana',
        cache.withLastDecidedDay(DayKey(2026, 8, 16)),
      );
      expect((await upgraded.watcherCache('mum_ana')).lastDecidedDay,
          DayKey(2026, 8, 16));
    });

    test('the v4 step is IDEMPOTENT, which the ladder requires of every step',
        () async {
      // The hazard `onDowngrade`'s comment spells out, made concrete: a store
      // that already HAS the column but whose version says 3. That is what a
      // rollback leaves behind — the newer schema in place, the version rewritten
      // down — and a bare `ALTER TABLE … ADD COLUMN` throws `duplicate column
      // name` against it. `openDatabase` throws with it, and `LocalStore.open()`
      // is unguarded in both entry points, so the app could not open its store
      // at all and the only repair would be a reinstall — destroying
      // `warnings_shown`, the exact loss the whole block exists to prevent.
      final path = await seedV1();

      // Upgrade to current, so the column exists.
      final current = await LocalStore.open(path: path);
      await current.saveWatcherCache(
        'mum_ana',
        WatcherCache(lastDecidedDay: DayKey(2026, 8, 16)),
      );
      await current.close();

      // Now rewrite the version down, exactly as onDowngrade does, leaving the
      // v4 schema in place.
      final rolledBack = await openDatabase(path, version: 3, onCreate: (_, _) async {});
      await rolledBack.close();

      // Re-open at the current version: the v4 step replays.
      final replayed = await LocalStore.open(path: path);
      addTearDown(replayed.close);
      expect((await replayed.watcherCache('mum_ana')).lastDecidedDay,
          DayKey(2026, 8, 16),
          reason: 'the replay must be a no-op, not a throw and not a reset');
    });

    test('v2 gets the scope-keyed lock, and both scopes work', () async {
      // The re-key is the whole content of this migration. v2 could hold one
      // lock for the entire app; v3 must let the watched and watcher sides hold
      // one each, which is what stopped one side going unarmed on every launch.
      final upgraded = await LocalStore.open(path: await seedV2());
      addTearDown(upgraded.close);

      const lease = Duration(seconds: 30);
      expect(
        await upgraded.acquireReconcileLock(
            scope: 'watched', owner: 'ui', now: t0, lease: lease),
        isTrue,
      );
      expect(
        await upgraded.acquireReconcileLock(
            scope: 'watcher', owner: 'ui', now: t0, lease: lease),
        isTrue,
        reason: 'a v2 store carried one global lock row; if the table were not '
            'replaced, the second scope would collide with the first',
      );
    });
  });

  test('a store written by a NEWER build opens, and keeps its rows', () async {
    // A rollback — a Play staged-rollout halt, or a debug build over a release
    // one. `LocalStore.open()` is the first line of both background entry
    // points, so whatever happens here happens before anything else can.
    //
    // **This pins a behaviour, not a bug fix.** sqflite runs nothing when
    // `onDowngrade` is null and silently accepts the file, which is what this
    // app wants; the handler is written out so the intent is visible. What the
    // test defends against is the plausible "tidy-up": switching it to
    // `onDatabaseDowngradeDelete`, which deletes the store, loses
    // `warnings_shown`, and fires every standing warning again — a round of
    // false claims to a family, produced by a rollback. Verified to fail
    // against exactly that.
    final dir = Directory.systemTemp.createTempSync('i_am_ok_v4');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/store.db';

    final future = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: LocalStore.schemaVersion + 1,
        onCreate: (db, _) async {
          await db.execute(
              'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await db.execute(
              'CREATE TABLE something_new (id INTEGER PRIMARY KEY)');
        },
      ),
    );
    await future
        .insert('settings', {'key': 'device_timezone', 'value': 'Europe/Madrid'});
    await future.close();

    final store = await LocalStore.open(path: path);
    addTearDown(store.close);

    expect(await store.deviceTimezone(), 'Europe/Madrid',
        reason: 'opened, and the newer build\'s data is still there');
  });
}
