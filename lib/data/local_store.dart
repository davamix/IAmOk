import 'package:sqflite/sqflite.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/domain.dart';

/// Tier 3 of the truth model (§3) — the offline decision cache, and **the only
/// thing a bare background isolate can see**.
///
/// SQLite rather than `SharedPreferences`, and that is not a preference (§4).
/// The three isolates share no memory, so everything a background entry point
/// needs must be on disk with real cross-isolate locking. `SharedPreferences`
/// caches in memory per isolate and needs `reload()` gymnastics that fail
/// quietly — and quietly is the one way this app must not fail.
///
/// Every accessor here converts at the boundary, so nothing above ever handles
/// a raw row. The encodings are deliberate:
///
/// | Domain value | Stored as | Why |
/// |---|---|---|
/// | [DayKey] | `YYYY-MM-DD` text | This **is** the Firestore document id (§7), so it is a contract rather than a formatting choice. |
/// | [DateTime] | epoch milliseconds, UTC | An instant, stored as an instant. §11's "store instants in UTC, never days". |
/// | [LocalTimeOfDay] | `HH:mm` text | Wall-clock with no date and no zone, which is exactly what the type means. |
/// | enums | `.name` | Readable in a `dump`, and stable as long as nobody renames a case. |
class LocalStore {
  LocalStore._(this._db);

  /// The current schema version. Bump **and** add an `onUpgrade` branch — an
  /// installed app that loses its store loses its `warningsShownFor`, and the
  /// visible symptom is every standing warning firing again.
  static const int schemaVersion = 1;

  static const String defaultDatabaseName = 'i_am_ok.db';

  final Database _db;

  Database get database => _db;

  /// Opens (and creates or migrates) the store.
  ///
  /// Called by **each** isolate that needs it — UI, alarm, and later FCM. They
  /// each hold their own connection to the same file; SQLite does the locking.
  static Future<LocalStore> open({String? path}) async {
    final resolved = path ?? '${await getDatabasesPath()}/$defaultDatabaseName';
    final db = await openDatabase(
      resolved,
      version: schemaVersion,
      onConfigure: (db) async {
        // Off by default in SQLite, and `warnings_shown` is meaningless without
        // the link row it hangs off.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        for (final statement in _schema) {
          await db.execute(statement);
        }
      },
      onUpgrade: (db, from, to) async {
        // Nothing to migrate yet. The branch exists so the next schema change
        // is an edit rather than a decision.
        throw StateError('no migration from v$from to v$to');
      },
    );
    return LocalStore._(db);
  }

  Future<void> close() => _db.close();

  static const List<String> _schema = [
    '''
    CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    ''',
    // Both directions live here: rows where this user is watched, and rows
    // where they watch. §1 — roles live on links, a user is just a user.
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
    )
    ''',
    // The watched person's own taps. The day is the primary key for the same
    // reason it is the Firestore document id (§7): a second tap the same day is
    // an update, so once-per-day semantics come free and no dedupe logic exists
    // anywhere to be got wrong.
    '''
    CREATE TABLE check_ins (
      day              TEXT PRIMARY KEY,
      device_tapped_at INTEGER NOT NULL,
      timezone         TEXT NOT NULL
    )
    ''',
    // The per-link watcher cache — §6's field list, one row per link.
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
    )
    ''',
    // `warningsShownFor` — a map of day → WHICH warning is standing, not a set
    // of days (ADR-0004 decision 6). §6 called it a set; more than one message
    // became reachable for the same D, and keyed on the day alone a stronger,
    // now-verified message can never replace a stale hedge.
    '''
    CREATE TABLE warnings_shown (
      link_id TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
      day     TEXT NOT NULL,
      outcome TEXT NOT NULL,
      PRIMARY KEY (link_id, day)
    )
    ''',
    // What we believe is armed on the platform. §6's `pendingAlarms`.
    //
    // The reconciler diffs its desired set against this, so it is the answer to
    // "what did we schedule" — `flutter_local_notifications` can enumerate
    // pending requests but not the structured (day, slot, instant) they were
    // built from, and rebuilding that from an id is guesswork.
    //
    // Keyed on the natural key rather than on the platform notification id:
    // deriving that id is the Platform layer's job, and §5 makes Data and
    // Platform **peers** — neither depends on the other. Storing the id here
    // would have inverted that for the sake of one integer.
    //
    // `slot` and `link_id` are NOT NULL with an empty default, and that is
    // load-bearing rather than tidy. SQLite does not enforce NOT NULL on a
    // rowid table's primary key, and NULLs compare **distinct** — so a
    // nullable key column constrains nothing and the same alarm can be
    // inserted repeatedly. A reminder carries no `link_id` and a Phase 3
    // warning will carry no `slot`, so without this both kinds can duplicate,
    // and `currentlyScheduled` would report alarms twice to the very diff that
    // decides what to cancel.
    '''
    CREATE TABLE pending_alarms (
      kind     TEXT NOT NULL,
      day      TEXT NOT NULL,
      slot     TEXT NOT NULL DEFAULT '',
      link_id  TEXT NOT NULL DEFAULT '',
      fires_at INTEGER NOT NULL,
      zone     TEXT NOT NULL,
      PRIMARY KEY (kind, day, slot, link_id)
    )
    ''',
    // The watched person's own away period — one row, because away is one
    // document and one truth (§12). Written in Phase 6; the table exists now so
    // that phase is a feature rather than a migration.
    '''
    CREATE TABLE self_away (
      id          INTEGER PRIMARY KEY CHECK (id = 0),
      from_day    TEXT NOT NULL,
      through_day TEXT NOT NULL,
      set_by      TEXT,
      set_by_name TEXT
    )
    ''',
  ];

  // ---------------------------------------------------------------- settings

  static const String _keyDeviceTimezone = 'device_timezone';
  static const String _keyClockOffsetMs = 'debug_clock_offset_ms';

  Future<String?> _setting(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> _putSetting(String key, String? value) async {
    if (value == null) {
      await _db.delete('settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The device's own IANA zone, written by `ClockService` on every resume.
  ///
  /// Background isolates read it from here and **never** call
  /// `flutter_timezone` (ADR-0002 decision 2). This is the canonical instance
  /// of §4's rule that what a background isolate needs is on disk.
  Future<String?> deviceTimezone() => _setting(_keyDeviceTimezone);

  Future<void> setDeviceTimezone(String zone) =>
      _putSetting(_keyDeviceTimezone, zone);

  /// The debug harness's forced-date offset, in milliseconds.
  ///
  /// Stored rather than held in memory because the alarm isolate has to agree
  /// with the UI about what day it is — forcing the date in the UI and having
  /// the alarm disagree would test nothing.
  Future<Duration> clockOffset() async {
    final raw = await _setting(_keyClockOffsetMs);
    final ms = raw == null ? null : int.tryParse(raw);
    return Duration(milliseconds: ms ?? 0);
  }

  Future<void> setClockOffset(Duration offset) => _putSetting(
        _keyClockOffsetMs,
        offset == Duration.zero ? null : '${offset.inMilliseconds}',
      );

  // ------------------------------------------------------------------- links

  /// Inserts or updates a link **without disturbing anything that hangs off
  /// it.**
  ///
  /// Deliberately a real `ON CONFLICT … DO UPDATE` and **not**
  /// `ConflictAlgorithm.replace`. SQLite resolves a REPLACE primary-key
  /// conflict by *deleting* the existing row first — and `watcher_cache` and
  /// `warnings_shown` both declare `ON DELETE CASCADE`, with foreign keys
  /// enabled in [open]. So a REPLACE here silently takes with it, for that
  /// link: every standing warning, `lastConfirmedDay`, `lastReconcileAt`,
  /// `accessLostSince`, `accessLostCause` and `accessLostNotifiedOn`.
  ///
  /// Re-writing a link is not rare — it is what Phase 4 does on every reconcile
  /// that refreshes links from Firestore, and what a revocation does today. The
  /// damage is exactly the failure this file's own header warns about ("an
  /// installed app that loses its store loses its `warningsShownFor`, and the
  /// visible symptom is every standing warning firing again"), reached by a
  /// route that warning did not anticipate. It would also reset ADR-0001's
  /// two-day staleness bound on every link refresh — so a cached away could
  /// silence a watcher indefinitely — and reset ADR-0004's cadence anchor, so
  /// the access-lost reminder would never advance past day 0.
  ///
  /// **UPDATE, then INSERT if it changed nothing** — deliberately not SQLite's
  /// `ON CONFLICT … DO UPDATE`.
  ///
  /// UPSERT syntax needs **SQLite 3.24** (June 2018), which Android ships from
  /// **API 29**. This app's minSdk is 24, and `docs/testing/device-matrix.md`
  /// says why in terms: *"the watched user's phone is likely to be old"*. On
  /// API 24–28 the UPSERT form is a **parse error**, not a subtle
  /// misbehaviour — the app simply cannot write a link.
  ///
  /// It passed every test because `sqflite_common_ffi` binds a modern desktop
  /// `sqlite3` library, and the only physical device is API 33. That is the
  /// shape of hazard the device matrix's API-level axis exists for, and the one
  /// axis a single handset cannot cover.
  ///
  /// The two statements run in one transaction so a concurrent writer cannot
  /// land between them. The uids are not in the UPDATE set: they are what the
  /// id is derived from, so a row whose uids changed is a different link.
  Future<void> upsertLink(Link link) {
    final values = <String, Object?>{
      'status': link.status.name,
      'watched_name': link.watchedName,
      'watcher_name': link.watcherName,
      'watched_timezone': link.watchedTimezone,
      'active_from': link.activeFrom.toString(),
      'warning_local_time': link.warningLocalTime.toString(),
      'created_at': link.createdAt.toUtc().millisecondsSinceEpoch,
      'accepted_at': link.acceptedAt?.toUtc().millisecondsSinceEpoch,
    };

    return _db.transaction((txn) async {
      // An UPDATE leaves the row in place, so nothing cascades — which is the
      // whole point. `INSERT OR REPLACE` deletes first, and `watcher_cache`
      // and `warnings_shown` cascade on delete, so a link rewrite would take
      // every standing warning and the access-lost cadence anchor with it.
      final changed = await txn.update(
        'links',
        values,
        where: 'id = ?',
        whereArgs: [link.id],
      );
      if (changed > 0) return;

      await txn.insert('links', {
        'id': link.id,
        'watched_uid': link.watchedUid,
        'watcher_uid': link.watcherUid,
        ...values,
      });
    });
  }

  Future<List<Link>> allLinks() async =>
      (await _db.query('links', orderBy: 'id')).map(_linkFrom).toList();

  /// Links where [uid] is the **watched** party — the ones §8 lets that user
  /// read about themselves, and the input to [WatchedAudience].
  Future<List<Link>> linksWatching(String uid) async => (await _db.query(
        'links',
        where: 'watched_uid = ?',
        whereArgs: [uid],
        orderBy: 'id',
      ))
          .map(_linkFrom)
          .toList();

  /// Links where [uid] is the **watcher** — the watcher-side list.
  Future<List<Link>> linksWatchedBy(String uid) async => (await _db.query(
        'links',
        where: 'watcher_uid = ?',
        whereArgs: [uid],
        orderBy: 'id',
      ))
          .map(_linkFrom)
          .toList();

  static Link _linkFrom(Map<String, Object?> row) => Link(
        watchedUid: row['watched_uid']! as String,
        watcherUid: row['watcher_uid']! as String,
        // An unrecognised status reads as `revoked`, and does **not** throw.
        //
        // `byName` threw, which was the one decoder in this file that did —
        // every other one degrades, precisely so a bad row cannot take down a
        // bare isolate that has no way to report anything. This is on
        // `linksWatching`, which every single reconcile calls, so a value
        // written by a newer build and then downgraded, or a partial sync,
        // would have stopped the app reconciling at all.
        //
        // `revoked` rather than `accepted` because §10 makes revoked the silent
        // branch: an unreadable link says nothing and cancels its alarm. The
        // alternative errs toward speaking about a link we cannot interpret,
        // and a false claim to a family is the worst bug this app can have.
        status: _byName(LinkStatus.values, row['status']) ?? LinkStatus.revoked,
        watchedName: row['watched_name']! as String,
        watcherName: row['watcher_name']! as String,
        watchedTimezone: row['watched_timezone']! as String,
        activeFrom: DayKey.parse(row['active_from']! as String),
        warningLocalTime:
            LocalTimeOfDay.parse(row['warning_local_time']! as String),
        createdAt: _instant(row['created_at'])!,
        acceptedAt: _instant(row['accepted_at']),
      );

  // ---------------------------------------------------------------- check-ins

  /// Records today's tap.
  ///
  /// The day id comes from the **device clock in the device's zone** and is
  /// supplied by the caller, never derived here — §11, and the reason a
  /// `serverTimestamp()` cannot decide it. Idempotent by primary key, which is
  /// the same once-per-day property the Firestore document id gives (§7).
  Future<void> recordCheckIn(CheckIn checkIn) => _db.insert(
        'check_ins',
        {
          'day': checkIn.day.toString(),
          'device_tapped_at':
              checkIn.deviceTappedAt.toUtc().millisecondsSinceEpoch,
          'timezone': checkIn.timezone,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<CheckIn?> checkInOn(DayKey day) async {
    final rows = await _db.query(
      'check_ins',
      where: 'day = ?',
      whereArgs: [day.toString()],
    );
    return rows.isEmpty ? null : _checkInFrom(rows.first);
  }

  Future<Set<DayKey>> checkedInDays() async =>
      (await _db.query('check_ins', columns: ['day']))
          .map((r) => DayKey.parse(r['day']! as String))
          .toSet();

  Future<List<CheckIn>> allCheckIns() async =>
      (await _db.query('check_ins', orderBy: 'day DESC'))
          .map(_checkInFrom)
          .toList();

  static CheckIn _checkInFrom(Map<String, Object?> row) => CheckIn(
        day: DayKey.parse(row['day']! as String),
        deviceTappedAt: _instant(row['device_tapped_at'])!,
        timezone: row['timezone']! as String,
      );

  // ----------------------------------------------------------- watcher cache

  /// The cache slice the warning decision runs on, for one link.
  ///
  /// Returns [WatcherCache.empty] for a link never reconciled, which is the
  /// correct starting state rather than an error: it means nothing is known,
  /// nothing is standing, and nothing has been verified.
  Future<WatcherCache> watcherCache(String linkId) async {
    final rows = await _db.query(
      'watcher_cache',
      where: 'link_id = ?',
      whereArgs: [linkId],
    );
    final warnings = await _warningsShown(linkId);
    if (rows.isEmpty) {
      return WatcherCache(warningsShownFor: warnings);
    }
    final row = rows.first;

    final from = row['away_from'] as String?;
    final through = row['away_through'] as String?;
    // tryCreate, not the constructor: a stored pair that cannot form a valid
    // period must not throw inside an alarm isolate. The same shape, and the
    // same reason, as `Link.tryWatchedZone`.
    final away = (from == null || through == null)
        ? null
        : AwayPeriod.tryCreate(
            from: DayKey.parse(from),
            through: DayKey.parse(through),
          );

    return WatcherCache(
      away: away,
      lastConfirmedDay: _day(row['last_confirmed_day']),
      warningsShownFor: warnings,
      lastReconcileAt: _instant(row['last_reconcile_at']),
      accessLostSince: _day(row['access_lost_since']),
      accessLostCause: _refusedCause(row['access_lost_cause']),
      accessLostNotifiedOn: _day(row['access_lost_notified_on']),
    );
  }

  /// Persists a reconciled cache — **one write**, covering the refresh, any
  /// corrections and any warning this fire recorded.
  ///
  /// One transaction rather than several statements because a background
  /// isolate can be killed mid-write, and a store holding the refreshed away
  /// period but not the warning that was shown against it would notify twice.
  Future<void> saveWatcherCache(String linkId, WatcherCache cache) =>
      _db.transaction((txn) async {
        await txn.insert(
          'watcher_cache',
          {
            'link_id': linkId,
            'away_from': cache.away?.from.toString(),
            'away_through': cache.away?.through.toString(),
            'last_confirmed_day': cache.lastConfirmedDay?.toString(),
            'last_reconcile_at':
                cache.lastReconcileAt?.toUtc().millisecondsSinceEpoch,
            'access_lost_since': cache.accessLostSince?.toString(),
            'access_lost_cause': cache.accessLostCause?.name,
            'access_lost_notified_on': cache.accessLostNotifiedOn?.toString(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        // Replaced wholesale rather than merged: the cache is an immutable
        // value and the reconciler already computed the whole of it, so a
        // merge here would be a second opinion about what is standing.
        await txn
            .delete('warnings_shown', where: 'link_id = ?', whereArgs: [linkId]);
        for (final entry in cache.warningsShownFor.entries) {
          await txn.insert('warnings_shown', {
            'link_id': linkId,
            'day': entry.key.toString(),
            'outcome': entry.value.name,
          });
        }
      });

  Future<Map<DayKey, WarningOutcome>> _warningsShown(String linkId) async {
    final rows = await _db.query(
      'warnings_shown',
      where: 'link_id = ?',
      whereArgs: [linkId],
    );
    final result = <DayKey, WarningOutcome>{};
    for (final row in rows) {
      final outcome = _outcome(row['outcome']);
      // An unrecognised outcome drops the row rather than throwing. The effect
      // is that the warning is treated as not standing and may be shown again
      // — noisy, and the right direction: silence is the one failure this app
      // cannot detect in itself, and a throw here happens inside an alarm
      // isolate where it looks exactly like the app working.
      if (outcome == null) continue;
      result[DayKey.parse(row['day']! as String)] = outcome;
    }
    return result;
  }

  // ---------------------------------------------------------- pending alarms

  /// What we believe is armed. The reconciler's `currentlyScheduled`.
  Future<Set<ScheduledReminder>> pendingReminders() async {
    final rows = await _db
        .query('pending_alarms', where: 'kind = ?', whereArgs: ['reminder']);
    final result = <ScheduledReminder>{};
    for (final row in rows) {
      final slot = _slot(row['slot']);
      final zone = TimeZones.tryLocation(row['zone']! as String);
      // A row we can no longer interpret is dropped rather than thrown on. The
      // reconciler then believes it is not armed and schedules over the same
      // platform id, which is a replacement — the recoverable direction.
      if (slot == null || zone == null) continue;
      result.add(ScheduledReminder(
        day: DayKey.parse(row['day']! as String),
        slot: slot,
        at: tz.TZDateTime.from(_instant(row['fires_at'])!, zone),
      ));
    }
    return result;
  }

  /// Replaces the pending set for one kind of alarm.
  ///
  /// Written after the platform calls succeed, so a crash between scheduling
  /// and recording leaves the store believing *less* is armed than really is.
  /// That direction is recoverable — the next reconcile re-schedules over the
  /// same ids — whereas believing more is armed than really is would leave a
  /// reminder that never fires and nothing to notice it.
  Future<void> replacePendingReminders(Set<ScheduledReminder> reminders) =>
      _db.transaction((txn) async {
        await txn
            .delete('pending_alarms', where: 'kind = ?', whereArgs: ['reminder']);
        for (final reminder in reminders) {
          await txn.insert('pending_alarms', {
            'kind': 'reminder',
            'day': reminder.day.toString(),
            'slot': reminder.slot.name,
            // Empty rather than NULL — see the table definition. A reminder
            // belongs to the person, not to a link.
            'link_id': '',
            'fires_at': reminder.at.toUtc().millisecondsSinceEpoch,
            'zone': reminder.at.location.name,
          });
        }
      });

  // ------------------------------------------------------------- debug: dump

  /// Every table, as rows. The debug harness's *dump `LocalStore`*.
  Future<Map<String, List<Map<String, Object?>>>> dump() async {
    final tables = [
      'settings',
      'links',
      'check_ins',
      'watcher_cache',
      'warnings_shown',
      'pending_alarms',
      'self_away',
    ];
    return {
      for (final table in tables) table: await _db.query(table),
    };
  }

  /// Drops every row, keeping the schema. Debug builds only.
  Future<void> wipe() => _db.transaction((txn) async {
        for (final table in [
          'warnings_shown',
          'watcher_cache',
          'pending_alarms',
          'check_ins',
          'links',
          'self_away',
          'settings',
        ]) {
          await txn.delete(table);
        }
      });

  // -------------------------------------------------------------- conversion

  static DateTime? _instant(Object? value) => value == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);

  static DayKey? _day(Object? value) =>
      value == null ? null : DayKey.tryParse(value as String);

  static WarningOutcome? _outcome(Object? value) =>
      _byName(WarningOutcome.values, value);

  static ReminderSlot? _slot(Object? value) =>
      _byName(ReminderSlot.values, value);

  /// An unrecognised cause becomes [RefusedCause.unknown] rather than null.
  ///
  /// Null would mean "access is fine" alongside a non-null `accessLostSince`,
  /// which is an impossible state. `unknown` has a defined §13 remediation —
  /// *"ask whoever set up the app"* — so the panel stays honest.
  static RefusedCause? _refusedCause(Object? value) => value == null
      ? null
      : _byName(RefusedCause.values, value) ?? RefusedCause.unknown;

  static T? _byName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}
