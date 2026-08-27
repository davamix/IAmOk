@TestOn('vm')
library;

import 'dart:io';

import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// The v5 → v6 upgrade, run against a **real v5 file**.
///
/// The suite had no migration test before this one, and every earlier migration
/// was additive in a way an in-memory round-trip could not distinguish from a
/// fresh install. This one is the first to `ALTER` a table that an installed app
/// already has rows in, and `LocalStore.open()` is unguarded in both background
/// entry points: a migration that throws does not degrade, it stops the app
/// being able to open its own store at all, and the only repair a user has is a
/// reinstall — which destroys `warnings_shown` and re-fires every standing
/// warning at a family.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('i_am_ok_migration');
    path = '${dir.path}/store.db';
  });

  tearDown(() async => dir.delete(recursive: true));

  /// The v5 schema, **written out by hand**.
  ///
  /// Derived from nothing: a fixture that asked the code under test what the old
  /// shape was could never fail. This is the shape a phone in somebody's pocket
  /// actually holds — `watcher_cache` without `away_set_by` or
  /// `away_set_by_name`, and every other table exactly as v5 left it, because
  /// `watcherCache()` reads three tables and a partial fixture would fail for
  /// the wrong reason.
  const v5Schema = <String>[
    'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    'CREATE TABLE links ('
        'id TEXT PRIMARY KEY, watched_uid TEXT NOT NULL, '
        'watcher_uid TEXT NOT NULL, status TEXT NOT NULL, '
        'watched_name TEXT NOT NULL, watcher_name TEXT NOT NULL, '
        'watched_timezone TEXT NOT NULL, active_from TEXT NOT NULL, '
        'warning_local_time TEXT NOT NULL, created_at INTEGER NOT NULL, '
        'accepted_at INTEGER)',
    'CREATE TABLE check_ins ('
        'day TEXT PRIMARY KEY, device_tapped_at INTEGER NOT NULL, '
        'timezone TEXT NOT NULL)',
    // The one table v6 changes.
    'CREATE TABLE watcher_cache ('
        'link_id TEXT PRIMARY KEY REFERENCES links(id) ON DELETE CASCADE, '
        'away_from TEXT, away_through TEXT, last_confirmed_day TEXT, '
        'last_reconcile_at INTEGER, access_lost_since TEXT, '
        'access_lost_cause TEXT, access_lost_notified_on TEXT, '
        'last_decided_day TEXT)',
    'CREATE TABLE warnings_shown ('
        'link_id TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE, '
        'day TEXT NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY (link_id, day))',
    'CREATE TABLE corrections_owed ('
        'link_id TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE, '
        'day TEXT NOT NULL, PRIMARY KEY (link_id, day))',
    'CREATE TABLE pending_alarms ('
        'kind TEXT NOT NULL, day TEXT NOT NULL, '
        "slot TEXT NOT NULL DEFAULT '', link_id TEXT NOT NULL DEFAULT '', "
        'fires_at INTEGER NOT NULL, zone TEXT NOT NULL, '
        'PRIMARY KEY (kind, day, slot, link_id))',
    // Present since v5 with nothing reading or writing it — the arrangement
    // that made away mode a feature rather than a migration.
    'CREATE TABLE self_away ('
        'id INTEGER PRIMARY KEY CHECK (id = 0), from_day TEXT NOT NULL, '
        'through_day TEXT NOT NULL, set_by TEXT, set_by_name TEXT)',
    'CREATE TABLE reconcile_lock ('
        'scope TEXT PRIMARY KEY, owner TEXT NOT NULL, '
        'expires_at INTEGER NOT NULL)',
  ];

  Future<void> writeV5Store() async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5),
    );
    for (final statement in v5Schema) {
      await db.execute(statement);
    }
    await db.insert('links', {
      'id': 'mum_ana',
      'watched_uid': 'mum',
      'watcher_uid': 'ana',
      'status': 'accepted',
      'watched_name': 'Mum',
      'watcher_name': 'Ana',
      'watched_timezone': 'Europe/Madrid',
      'active_from': '2026-08-01',
      'warning_local_time': '10:00',
      'created_at': 0,
      'accepted_at': 0,
    });
    await db.insert('watcher_cache', {
      'link_id': 'mum_ana',
      'away_from': '2026-08-15',
      'away_through': '2026-08-22',
      'last_confirmed_day': '2026-08-14',
      'last_decided_day': '2026-08-14',
    });
    await db.insert('warnings_shown', {
      'link_id': 'mum_ana',
      'day': '2026-08-13',
      'outcome': 'warnOnline',
    });
    await db.close();
  }

  test('a v5 store opens, and its away period survives the upgrade', () async {
    await writeV5Store();

    final store = await LocalStore.open(path: path);
    addTearDown(store.close);

    final cache = await store.watcherCache('mum_ana');
    expect(cache.away, isNotNull, reason: 'the period must not be lost');
    expect(cache.away!.period.from, day('2026-08-15'));
    expect(cache.away!.period.through, day('2026-08-22'));
    expect(cache.lastConfirmedDay, day('2026-08-14'));
    expect(cache.lastDecidedDay, day('2026-08-14'),
        reason: "ADR-0009's catch-up pointer is not reset by an upgrade");
  });

  test('the upgraded row is UNATTRIBUTED, which is the honest answer', () async {
    // Nothing is back-filled and nothing can be: a store written by v5 never
    // read the fields. Naming somebody the store cannot show wrote the document
    // would be the forgery ADR-0003 exists to make impossible, invented by the
    // migration itself.
    await writeV5Store();

    final store = await LocalStore.open(path: path);
    addTearDown(store.close);

    final cache = await store.watcherCache('mum_ana');
    expect(cache.away!.setBy, isNull);
    expect(cache.away!.setByName, isNull);
    expect(cache.away!.nameToShowFor('mum-uid'), isNull,
        reason: 'the row renders the already-approved unattributed string '
            'until the next successful read supplies a name');
  });

  test('the new columns are really there, and take a write', () async {
    await writeV5Store();

    final store = await LocalStore.open(path: path);
    addTearDown(store.close);

    await store.saveWatcherCache(
      'mum_ana',
      WatcherCache(
        away: AwayRecord(
          period:
              AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22')),
          setBy: 'ana-uid',
          setByName: 'Ana',
        ),
      ),
    );

    final cache = await store.watcherCache('mum_ana');
    expect(cache.away!.setBy, 'ana-uid');
    expect(cache.away!.setByName, 'Ana');
  });

  test('the step is IDEMPOTENT — replaying it does not throw', () async {
    // The case the v4 and v5 blocks each spell out and this one inherits.
    // `onDowngrade` accepts a newer file and rewrites its version DOWN, leaving
    // the newer schema in place — so v5 → v6 → roll back → re-install v6
    // replays this step against a table that already has the columns. A bare
    // ALTER TABLE would throw `duplicate column name` out of `openDatabase`
    // itself, and the app could not open its store.
    await writeV5Store();

    final upgraded = await LocalStore.open(path: path);
    await upgraded.close();

    // What a rollback leaves behind: v6's schema, stamped v5.
    final rolledBack = await databaseFactory.openDatabase(path);
    await rolledBack.setVersion(5);
    await rolledBack.close();

    final store = await LocalStore.open(path: path);
    addTearDown(store.close);

    expect(await store.watcherCache('mum_ana'), isA<WatcherCache>(),
        reason: 'replaying v6 against a table that already has the columns '
            'must be a no-op, not a crash');
  });

  test('a fresh install and an upgraded one hold the SAME shape', () async {
    // Two schemas that agree until somebody edits one. The migration is the
    // copy that drifts, because it is the path no fresh install ever runs.
    await writeV5Store();
    final upgraded = await LocalStore.open(path: path);
    addTearDown(upgraded.close);

    final freshPath = '${dir.path}/fresh.db';
    final fresh = await LocalStore.open(path: freshPath);
    addTearDown(fresh.close);

    Future<List<String>> columnsOf(LocalStore store) async {
      final rows = await store.database.rawQuery(
        'PRAGMA table_info(watcher_cache)',
      );
      return [for (final row in rows) row['name']! as String]..sort();
    }

    expect(await columnsOf(upgraded), await columnsOf(fresh));
  });
}
