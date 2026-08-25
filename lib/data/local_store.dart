import 'package:sqflite/sqflite.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/domain.dart';

/// Tier 3 of the truth model (§3) — the offline decision cache, and **the only
/// thing a bare background isolate can see**.
///
/// SQLite rather than `SharedPreferences`, and that is not a preference (§4).
/// The three isolates share no memory, so everything a background entry point
/// needs must be on disk, with concurrent access that is actually serialised.
/// `SharedPreferences` caches in memory per isolate and needs `reload()`
/// gymnastics that fail quietly — and quietly is the one way this app must not
/// fail.
///
/// **"Cross-isolate locking" is the right outcome but was the wrong mechanism,**
/// and [open] now carries the measurement: on Android these isolates share **one
/// native connection**, so writes are serialised by `sqflite`'s single worker
/// thread rather than by SQLite locking between separate connections. Read [open]
/// before assuming anything else about what two isolates do to this file.
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
  ///
  /// **v2** adds `reconcile_lock`; **v3** re-keys it by scope. See
  /// [acquireReconcileLock]. **v4** adds `last_decided_day` (ADR-0009). **v5**
  /// adds `corrections_owed` — a retraction that was established but could not
  /// be spoken, which is lost state of exactly the kind the paragraph above is
  /// about.
  static const int schemaVersion = 5;

  static const String defaultDatabaseName = 'i_am_ok.db';

  /// Phase 3's fixed local uid, kept **only** to read a store written before
  /// Phase 4 signed anybody in.
  ///
  /// Identity is now the Firebase uid — see [selfUid]. Rows keyed to this string
  /// belong to a device that has not signed in since, and no reconcile will ever
  /// find them again, because the signed-in uid is what every query asks for.
  /// That is the intended outcome and not a migration: they are fake links to a
  /// fake person, created by the harness.
  static const String defaultSelfUid = 'local-watched-user';

  /// The uid **nothing is keyed to** — signed out, expressed as a value.
  ///
  /// Deliberately not `null`. Every query that takes a uid — `linksWatchedBy`,
  /// `linksWatching`, both `reconcile`s — answers *nothing* for this one, which
  /// is exactly right when nobody is signed in: no links, so no alarms, so
  /// nothing to say. A nullable uid would push the same answer out to two dozen
  /// call sites as a guard each of them has to remember, and the one that forgot
  /// would throw inside an alarm isolate rather than quietly do nothing.
  ///
  /// It is safe as a sentinel because it **cannot collide**: Firebase uids are
  /// never empty, and links are written only by `redeemInvite`.
  ///
  /// Note the asymmetry with a *missing* uid on a signed-in device, which is the
  /// dangerous case and is a different thing entirely — see [selfUid].
  static const String signedOutUid = '';

  final Database _db;

  Database get database => _db;

  /// Opens (and creates or migrates) the store.
  ///
  /// Called by **each** isolate that needs it — UI, alarm, and later FCM.
  ///
  /// ## They share ONE connection, and it must never be closed by a background
  /// isolate — measured on the POCO F3, 2026-08-20
  ///
  /// This used to say *"they each hold their own connection to the same file;
  /// SQLite does the locking"*. That is **false on Android**, and it cost a
  /// defect. The background isolates run in the app's **own process**
  /// (`android_alarm_manager_plus`'s `AlarmService` has no
  /// `android:process=":remote"`), and `sqflite`'s Android plugin keeps a
  /// **static** `_singleInstancesByPath`. So the second and third callers here
  /// are handed back **the same `databaseId` the first one opened** — one native
  /// connection, not three.
  ///
  /// Two consequences, and both are load-bearing:
  ///
  /// 1. **Nothing may `close()` this from a background isolate.** Closing it
  ///    closes it for everyone; the alarm isolate did, and every UI call then
  ///    threw `DatabaseException(database_closed 1)` for the life of the
  ///    process. `sqflite`'s own docs say so:
  ///
  ///    > If `singleInstance` is true when using multiple isolates, make sure no
  ///    > background isolate closes the database, since that might close the
  ///    > database for all isolates.
  ///
  ///    Guarded by `domain_purity_test.dart`, because the test suite runs one
  ///    isolate on `sqflite_common_ffi` and structurally cannot catch it.
  ///
  /// 2. **Concurrent writes are serialised by `sqflite`'s single native
  ///    connection and worker thread**, not by SQLite file locking between
  ///    connections. The outcome the design wanted still holds — see
  ///    [acquireReconcileLock] and ADR-0006 — but by a different mechanism than
  ///    those documents originally described.
  static Future<LocalStore> open({String? path}) async {
    final resolved = path ?? '${await getDatabasesPath()}/$defaultDatabaseName';
    // Built as [OpenDatabaseOptions] rather than passed as loose arguments
    // because the convenience form of `openDatabase` does not expose
    // `rollbackActiveTransactionOnOpen` at all — and its own doc warns that
    // "if options is provided, all other parameters are ignored", so the two
    // styles must not be mixed.
    final options = OpenDatabaseOptions(
      version: schemaVersion,
      // **Pinned, because its default differs between debug and release** —
      // `true` in debug, `false` in release — and this app's evidence is
      // gathered from debug builds on a device.
      //
      // When true, opening the store from another isolate **rolls back any
      // transaction active in a different one**. This isolate boundary has two
      // writers using `_db.transaction` (`saveWatcherCache` and
      // [acquireReconcileLock]), and the alarm isolate opens the store on every
      // fire — so in a debug build an alarm could silently roll back an
      // in-flight UI write, and no release build would ever do the same. A
      // measurement that cannot mean the same thing in both builds is worse
      // than no measurement.
      //
      // `false` is what `sqflite` recommends "typically if you explicitly
      // create multiple isolates", which is exactly this app. The cost is
      // giving up rollback-on-open as a hot-restart safety net in debug: if a
      // hot restart strands an open transaction, reopening no longer clears it
      // and the app must be restarted properly. That is the right trade here.
      rollbackActiveTransactionOnOpen: false,
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
      // Additive only, and deliberately not a drop-and-recreate: an installed
      // app that loses this store loses `warningsShownFor`, and every standing
      // warning fires again the next morning.
      //
      // **A ladder, one step per version, and every step must be idempotent.**
      //
      // The ladder replaces a set of `if (from < n)` branches plus a
      // `if (to > 3) throw` tripwire. The tripwire's `3` was a literal derived
      // from nothing: bumping `schemaVersion` to 4 *and* writing the v4 step
      // would still have thrown on every device holding an older store, blaming
      // a missing migration that had just been written. It could not tell "you
      // forgot" from "you didn't". The `default` arm below cannot drift, because
      // it is reached only by a version with no case.
      //
      // **Idempotence is a rule, not a coincidence**, and this is the case the
      // old comment missed. [onDowngrade] accepts a newer file and rewrites its
      // version down — leaving the newer schema in place. So:
      //
      //   v3 → install v4 (adds a column) → roll back to v3 → the column stays,
      //   the version says 3 → re-install v4 → the v4 step runs again.
      //
      // A bare `ALTER TABLE … ADD COLUMN` there throws `duplicate column name`,
      // `openDatabase` throws with it, and `LocalStore.open()` is unguarded in
      // both `main.dart` and the alarm entry point. The app then cannot open its
      // store at all and the only repair is a reinstall — which destroys
      // `warnings_shown` and `pending_warnings`, the exact loss this whole block
      // is written to prevent, arriving by a route the block did not consider.
      //
      // v3's step is idempotent already (`DROP TABLE IF EXISTS` then create),
      // which is why the hazard is latent rather than live. That was luck. Any
      // future step must check before it alters:
      //
      //   final cols = await db.rawQuery('PRAGMA table_info(links)');
      //   if (!cols.any((c) => c['name'] == 'server_uid')) { … }
      onUpgrade: (db, from, to) async {
        for (var v = from + 1; v <= to; v++) {
          switch (v) {
            // v2 and v3 both land on the current `reconcile_lock`. From v1 the
            // drop is a no-op; from v2 it discards a real table — and it is the
            // one table that may be dropped rather than migrated, because it
            // holds nothing but ephemeral leases and the worst a lost row can do
            // is let one reconcile run that would otherwise have waited. Every
            // other table here is the opposite.
            case 2:
            case 3:
              await db.execute('DROP TABLE IF EXISTS reconcile_lock');
              await db.execute(_reconcileLockTable);
            // ADR-0009. Additive, and **idempotent by inspection rather than by
            // luck** — the rule the block above states and the reason it states
            // it: `onDowngrade` accepts a newer file and rewrites its version
            // down, leaving the newer schema in place, so v3 → v4 → roll back →
            // re-install v4 replays this step against a table that already has
            // the column. A bare ALTER TABLE would throw `duplicate column
            // name`, `openDatabase` would throw with it, and `LocalStore.open()`
            // is unguarded in both entry points — the app could not open its
            // store at all and the only repair would be a reinstall, which
            // destroys `warnings_shown`.
            case 4:
              final columns =
                  await db.rawQuery('PRAGMA table_info(watcher_cache)');
              final has = columns.any((c) => c['name'] == 'last_decided_day');
              if (!has) {
                await db.execute(
                  'ALTER TABLE watcher_cache ADD COLUMN last_decided_day TEXT',
                );
              }
            // A held retraction. Additive, and idempotent for the reason the v4
            // block spells out — `onDowngrade` accepts a newer file and rewrites
            // its version down, so this step can be replayed against a schema
            // that already has the table. `IF NOT EXISTS` rather than an
            // inspection because a whole table can say so itself.
            //
            // Nothing is back-filled, and nothing can be: a store written by v4
            // has already dropped every day whose retraction it could not speak,
            // because dropping them unconditionally is the defect this table
            // exists to fix. An upgrading install starts owing nothing, which is
            // the honest answer rather than a guessed one.
            case 5:
              await db.execute(_correctionsOwedTable);
            default:
              throw StateError('no migration to v$v');
          }
        }
      },
      // A store written by a NEWER build than the one now running — a Play
      // staged-rollout halt, or a debug build installed over a release one.
      //
      // **Stated rather than left to the default, because the two stock answers
      // differ by everything and neither name says which you get.** sqflite runs
      // nothing when this is null (`database_mixin.dart`: `if (options
      // .onDowngrade != null)`) and silently rewrites the version downward,
      // which is in fact what we want — but it is the kind of default that gets
      // "tidied" into `onDatabaseDowngradeDelete` by whoever next reads this
      // block and assumes a downgrade needs handling.
      //
      // `onDatabaseDowngradeDelete` **deletes the file**. That loses
      // `warnings_shown`, and this class's own schema note says the visible
      // symptom is every standing warning firing again — a fresh round of false
      // claims to a family, produced by a rollback. It is the one option that
      // must never appear here, and a test pins that.
      //
      // Accepting the file is safe today because every migration so far is
      // additive plus one re-key of `reconcile_lock`, and an older build's
      // queries name their columns, so extra tables and columns are invisible to
      // it. **A future migration that drops or renames a column breaks that and
      // must revisit this** — at which point the honest move is a version floor
      // here rather than a blanket accept.
      //
      // **The second consequence, which this comment used to miss.** Accepting
      // the file leaves the *newer* schema on disk under an older version
      // number, so the next upgrade replays a step against a table that already
      // has its change. That is why [onUpgrade]'s steps must each be idempotent
      // — the reasoning is there, with the crash it produces.
      onDowngrade: (db, from, to) async {},
    );

    final db = await openDatabase(resolved, options: options);
    return LocalStore._(db);
  }

  /// Closes the connection — **and on Android that means closing it for every
  /// isolate in the process.** Read [open] before calling this.
  ///
  /// It has **no caller in `lib/` on purpose.** The one that existed —
  /// `warningAlarmCallback`'s `finally` — is the defect measured on 2026-08-20:
  /// the alarm isolate is handed the connection the UI already holds, so closing
  /// it left every later UI call throwing `DatabaseException(database_closed 1)`
  /// for the life of the process. `domain_purity_test.dart` now fails if a
  /// background entry point calls it.
  ///
  /// Kept because the **tests** need it: they run on `sqflite_common_ffi`, where
  /// each `open()` really is a separate connection and a `tearDown` must release
  /// it. That difference between test and device is exactly what hid the defect,
  /// so it is named here rather than left to be rediscovered.
  ///
  /// If a future caller in `lib/` ever needs this, it may only be one that owns
  /// the whole process's store lifetime — never a background entry point.
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
      access_lost_notified_on TEXT,
      -- ADR-0009's catch-up pointer: the newest day this device has SETTLED,
      -- which is not the same as the newest day it ran. See
      -- `WatcherCache.lastDecidedDay`. Null on a fresh install, and null means
      -- the window is `{D}` alone — no retro-warning about days nobody was
      -- watching.
      last_decided_day        TEXT
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
    // `correctionsOwedFor` — days whose warning has been DISPROVED and taken
    // down, but whose retraction has not yet been spoken out loud.
    //
    // Deliberately not a column on `warnings_shown`: a day is in exactly one of
    // the two states, never both, and `warnings_shown` means *standing*. See
    // `WatcherCache.correctionsOwedFor` for the row that renders a false warning
    // if the two are merged.
    //
    // No `outcome`: the retracted message does not matter, only the day. What
    // gets posted is `NotificationCopy.correctionBody`, which is built from the
    // day and the watched name.
    _correctionsOwedTable,
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
    _reconcileLockTable,
  ];

  /// Named rather than inlined in [_schema] **because the v5
  /// migration executes the same string**. Two copies of a CREATE TABLE are two
  /// schemas that agree until somebody edits one, and the one that would drift
  /// is the migration — the path no fresh install ever runs.
  static const String _correctionsOwedTable = '''
    CREATE TABLE IF NOT EXISTS corrections_owed (
      link_id TEXT NOT NULL REFERENCES links(id) ON DELETE CASCADE,
      day     TEXT NOT NULL,
      PRIMARY KEY (link_id, day)
    )
    ''';

  /// One row **per scope**. See [acquireReconcileLock] for why it exists, and
  /// why one global row was wrong.
  ///
  /// Deliberately carries **no** foreign key and nothing hangs off it, so the
  /// `INSERT OR REPLACE` used to take the lock cannot cascade — the failure
  /// `upsertLink` was fixed for.
  static const String _reconcileLockTable = '''
    CREATE TABLE reconcile_lock (
      scope      TEXT PRIMARY KEY,
      owner      TEXT NOT NULL,
      expires_at INTEGER NOT NULL
    )
    ''';

  // ---------------------------------------------------------------- settings

  static const String _keyDeviceTimezone = 'device_timezone';
  static const String _keyClockOffsetMs = 'debug_clock_offset_ms';
  static const String _keySimulatedBackend = 'debug_simulated_backend';
  static const String _keyWarningAlarmsExact = 'warning_alarms_exact';
  static const String _keyLinkReconcileFailed = 'link_reconcile_failed';
  static const String _keyUses24HourClock = 'uses_24_hour_clock';
  static const String _keySelfUid = 'self_uid';

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

  /// The device's own IANA zone. `ClockService` discovers it and the **UI**
  /// writes it here, on launch and on every resume — that class deliberately
  /// holds no `LocalStore` (§5 makes Data and Platform peers), so it supplies the
  /// value and does not store it.
  ///
  /// Background isolates read it from here and **never** call
  /// `flutter_timezone` (ADR-0002 decision 2). This is the canonical instance
  /// of §4's rule that what a background isolate needs is on disk.
  Future<String?> deviceTimezone() => _setting(_keyDeviceTimezone);

  Future<void> setDeviceTimezone(String zone) =>
      _putSetting(_keyDeviceTimezone, zone);

  /// **Whose links these are** — the Firebase uid, written by the UI on sign-in
  /// and read by every isolate.
  ///
  /// This replaces [defaultSelfUid], and it lives here for the reason that
  /// constant did: the alarm isolate and the UI must agree, and they share no
  /// memory (§4). What is new in Phase 4 is that the answer is no longer a
  /// literal — it is an account.
  ///
  /// ## Why not read `FirebaseAuth.instance.currentUser` in the isolate
  ///
  /// It is available there: the alarm isolate initialises Firebase anyway,
  /// because §10 has it read Firestore before deciding whether to speak. It is
  /// not used, and the reason is the **shape of each failure**.
  ///
  /// `currentUser` is restored from disk during `initializeApp`. If it comes
  /// back null when a bare isolate asks — a restore still in flight, a token the
  /// SDK decided to re-fetch — the reconcile finds **zero links, does nothing,
  /// and reports success**. Nothing is logged, nothing is shown, and the dead
  /// man's switch is simply not armed. That is the silence §12 calls the one
  /// failure this app cannot detect in itself.
  ///
  /// This row cannot be missing while a user is signed in. If it were ever
  /// *stale* — an account switch the UI failed to record — the reads for those
  /// links come back `permission-denied`, which ADR-0004 maps to **refused**,
  /// which posts the access-lost notice and turns §13's panel red. Wrong and
  /// loud beats absent and quiet, on this side.
  ///
  /// Null means signed out, which is a real state and not an error: nothing is
  /// watched, nothing is armed, and reconcile has nothing to do.
  Future<String?> selfUid() => _setting(_keySelfUid);

  Future<void> setSelfUid(String uid) => _putSetting(_keySelfUid, uid);

  /// Clears the uid **and everything decided on its behalf**.
  ///
  /// The per-link cache has to go with the account, because every row in it
  /// belongs to the uid that is leaving: `warningsShownFor`, the cached away
  /// period, the pending warnings. Leaving them would let the next account
  /// inherit standing warnings about a person it has never heard of — and, worse,
  /// inherit the *alarms*, since `pending_alarms` is what the next reconcile
  /// diffs against.
  ///
  /// **The device facts are deliberately kept**: the zone and the 12/24-hour
  /// setting are properties of the phone, not of the account, and dropping them
  /// would put the next session back on ADR-0002's documented UTC fallback until
  /// the first resume. That is the fresh-install window `main()` closes on
  /// purpose.
  ///
  /// Tearing the platform alarms down is **not** done here and must not be: §3's
  /// rule is that nothing patches state incrementally, so the caller reconciles
  /// afterwards and the empty desired set cancels them.
  Future<void> clearSelfUid() => _db.transaction((txn) async {
        await txn.delete('settings', where: 'key = ?', whereArgs: [_keySelfUid]);
        for (final table in [
          'warnings_shown',
          'corrections_owed',
          'watcher_cache',
          'pending_alarms',
          'check_ins',
          'links',
          'self_away',
        ]) {
          await txn.delete(table);
        }
      });

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

  /// Phase 3's simulated backend, as JSON. See `CheckInReader`.
  ///
  /// On disk rather than in memory for the same reason as the clock offset: the
  /// alarm isolate shares no memory with the UI (§4), and a simulated backend
  /// the alarm could not see would leave this phase's whole point untested.
  ///
  /// Deleted entirely in Phase 4, along with `SimulatedCheckInReader`.
  Future<String?> simulatedBackendRaw() => _setting(_keySimulatedBackend);

  Future<void> setSimulatedBackendRaw(String? encoded) =>
      _putSetting(_keySimulatedBackend, encoded);

  /// Whether the last `apply` armed the warning alarms **exactly**.
  ///
  /// False means §13's documented degradation happened: the platform refused
  /// `SCHEDULE_EXACT_ALARM`, so the window is armed inexactly and every warning
  /// may arrive late by however long Android decides. That is a real reduction
  /// in what this app promises — §10 says the warning fires at
  /// `warningLocalTime`, and a dead man's switch an hour late is an hour nobody
  /// is told — and it happens with no prompt, no error and nothing on screen.
  ///
  /// Recorded rather than discarded because the scheduler is the only code that
  /// can observe it and it runs in an isolate with no UI. §13's health panel
  /// reads this in Phase 7; until then it is at least in `dump`, which is the
  /// difference between a known degradation and an invisible one.
  ///
  /// Null before the first apply — never armed, so nothing to claim either way.
  Future<bool?> warningAlarmsExact() async {
    final raw = await _setting(_keyWarningAlarmsExact);
    return raw == null ? null : raw == 'true';
  }

  Future<void> setWarningAlarmsExact(bool exact) =>
      _putSetting(_keyWarningAlarmsExact, '$exact');

  /// Whether the last reconcile failed on at least one watched link.
  ///
  /// The pass carries on with the rest — one bad link must not cost every other
  /// watched person their check — but a link the app silently stopped checking
  /// is precisely the failure this side cannot detect in itself, so it is not
  /// allowed to be invisible as well.
  ///
  /// Cleared by the next reconcile in which every link succeeds.
  Future<bool> linkReconcileFailed() async =>
      await _setting(_keyLinkReconcileFailed) == 'true';

  Future<void> setLinkReconcileFailed(bool failed) => _putSetting(
        _keyLinkReconcileFailed,
        failed ? 'true' : null,
      );

  /// Whether this device shows times as 24-hour.
  ///
  /// `docs/ui-ux/guidelines.md` asks for the device's own 12h/24h setting rather
  /// than a hard-coded one. Reading it needs `MediaQuery.alwaysUse24HourFormat`
  /// — a `BuildContext` — and the isolate that posts most of these notifications
  /// has no widget tree at all.
  ///
  /// **So it is cached here, exactly as the device's timezone is** (ADR-0002
  /// decision 2), and for the same reason: what a background isolate needs is on
  /// disk. `ClockService` supplies it, and the UI writes it in `main()` and on
  /// every resume — the same round trip the zone beside it makes.
  ///
  /// ## What "on every resume" does and does not buy — measured 2026-08-19
  ///
  /// The **write** happens on every resume. The **value** it writes does not
  /// necessarily change, and this is the part that was claimed wrongly here
  /// until it was tested on the POCO F3:
  ///
  /// > ~~because a reader can change it in Android settings while the app is
  /// > backgrounded~~
  ///
  /// `platformDispatcher.alwaysUse24HourFormat` is refreshed only when Android
  /// delivers a **configuration change** to the activity. Measured: with the
  /// device switched between 12- and 24-hour while the app was backgrounded, two
  /// successive background→resume cycles wrote the **stale** value, in both
  /// directions; a cold start wrote the correct one, and so did a resume that
  /// followed a forced configuration change (dark mode). So the cache tracks the
  /// device as of the last **cold start or configuration change**, not the last
  /// resume.
  ///
  /// The consequence is cosmetic — times render in the format the device used at
  /// process start until the next config change — and it is *not* a false claim
  /// about a person, which is why it is recorded rather than urgently fixed. The
  /// real fix is a platform channel to `DateFormat.is24HourFormat(context)`,
  /// which is live; that belongs with Phase 7's UI work, not with a phase that is
  /// closing. The resume write stays: it costs nothing and is correct whenever
  /// the platform value has in fact moved.
  ///
  /// **The zone half is not affected.** `ClockService.deviceTimezone()` calls
  /// `flutter_timezone`, a live plugin call into Android, so its resume refresh
  /// is real. Not measured — setting the device zone needs a system permission
  /// `adb` does not have — but it is a different mechanism from the one that
  /// failed here.
  ///
  /// It was also written in `main()` only at one point, which cost two further
  /// things worth keeping a note of: the write shared a `try` with the zone's
  /// plugin call, so a `flutter_timezone` hiccup at launch left a 12-hour device
  /// on the 24-hour default for the whole session.
  ///
  /// Defaults to true before the UI has ever run — the approved strings are
  /// 24-hour, so an uncached device renders what `screens.md` shows rather than
  /// something neither setting asked for.
  Future<bool> uses24HourClock() async =>
      await _setting(_keyUses24HourClock) != 'false';

  Future<void> setUses24HourClock(bool uses24Hour) =>
      _putSetting(_keyUses24HourClock, uses24Hour ? null : 'false');

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
    return _db.transaction((txn) => _upsertLinkIn(txn, link));
  }

  /// [upsertLink]'s statement, callable from inside an existing transaction.
  ///
  /// Factored out for [replaceLinksFor], which has to upsert several links and
  /// prune the rest atomically. Two copies of this would be two chances to write
  /// the delete-first version, which is the one that destroys the standing
  /// warnings.
  static Future<void> _upsertLinkIn(DatabaseExecutor txn, Link link) async {
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
  }

  /// Makes the stored links for [uid] match [links] exactly — Phase 4's sync.
  ///
  /// **Upsert then prune, in one transaction**, and never a delete-then-insert.
  /// The rows that hang off a link cascade on delete: `watcher_cache` carries the
  /// standing warnings and the access-lost cadence anchor, and `warnings_shown`
  /// is what stops a warning being posted twice. Rewriting a link the blunt way
  /// would take all of that with it, and the visible symptom would be every
  /// standing warning firing again the next morning — a fresh round of false
  /// claims to a family, produced by a sync. [upsertLink] avoids that by
  /// updating in place, and this reuses its statement rather than a second copy.
  ///
  /// **The prune is what makes a revocation on another device arrive here**, and
  /// it is the reason this takes the whole desired set rather than one link at a
  /// time: a link the server no longer returns must go, or the alarm isolate
  /// keeps warning about somebody this user no longer watches.
  ///
  /// It is **only ever called with a set the server actually returned** — see
  /// `LinkRepository.syncInto`, which does nothing at all on a failed read. A
  /// failed read here would mean an empty set, which would delete every link on
  /// the device and disarm the whole dead man's switch.
  Future<void> replaceLinksFor(String uid, List<Link> links) =>
      _db.transaction((txn) async {
        for (final link in links) {
          await _upsertLinkIn(txn, link);
        }

        final keep = links.map((l) => l.id).toList();
        final placeholders = List.filled(keep.length, '?').join(', ');
        await txn.delete(
          'links',
          where: '(watched_uid = ? OR watcher_uid = ?)'
              '${keep.isEmpty ? '' : ' AND id NOT IN ($placeholders)'}',
          whereArgs: [uid, uid, ...keep],
        );
      });

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
    final owed = await _correctionsOwed(linkId);
    if (rows.isEmpty) {
      // A link with no `watcher_cache` row has still been able to accumulate
      // both of these — they live in their own tables — so neither may be
      // dropped on this branch.
      return WatcherCache(
        warningsShownFor: warnings,
        correctionsOwedFor: owed,
      );
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
      correctionsOwedFor: owed,
      lastReconcileAt: _instant(row['last_reconcile_at']),
      accessLostSince: _day(row['access_lost_since']),
      accessLostCause: _refusedCause(row['access_lost_cause']),
      accessLostNotifiedOn: _day(row['access_lost_notified_on']),
      lastDecidedDay: _day(row['last_decided_day']),
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
            'last_decided_day': cache.lastDecidedDay?.toString(),
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

        // Same wholesale replacement, same reason. A merge would let a day the
        // reconciler has just retracted out loud survive as still owed, and the
        // watcher would be told about it again every reconcile thereafter.
        await txn.delete(
          'corrections_owed',
          where: 'link_id = ?',
          whereArgs: [linkId],
        );
        for (final day in cache.correctionsOwedFor) {
          await txn.insert('corrections_owed', {
            'link_id': linkId,
            'day': day.toString(),
          });
        }
      });

  Future<Set<DayKey>> _correctionsOwed(String linkId) async {
    final rows = await _db.query(
      'corrections_owed',
      columns: ['day'],
      where: 'link_id = ?',
      whereArgs: [linkId],
    );
    return {for (final row in rows) DayKey.parse(row['day']! as String)};
  }

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

  /// What we believe is armed for one link's warning alarm.
  ///
  /// Scoped by `link_id`, because a watcher with two watched people has two
  /// independent windows and reconciles them one link at a time. A query that
  /// ignored the link would hand one link's reconcile the other's alarms, and
  /// the diff would cancel them.
  Future<Set<ScheduledWarning>> pendingWarnings(String linkId) async {
    final rows = await _db.query(
      'pending_alarms',
      where: 'kind = ? AND link_id = ?',
      whereArgs: ['warning', linkId],
    );
    final result = <ScheduledWarning>{};
    for (final row in rows) {
      final zone = TimeZones.tryLocation(row['zone']! as String);
      // Dropped rather than thrown on, as in [pendingReminders]: the reconciler
      // then believes it is not armed and schedules over the same platform id,
      // which is a replacement. The recoverable direction, and this runs inside
      // an alarm isolate that cannot report a throw to anyone.
      if (zone == null) continue;
      result.add(ScheduledWarning(
        day: DayKey.parse(row['day']! as String),
        at: tz.TZDateTime.from(_instant(row['fires_at'])!, zone),
      ));
    }
    return result;
  }

  /// Replaces the pending warning set **for one link**.
  ///
  /// The delete is scoped to the link for the same reason the read is: a
  /// wholesale delete would silently disarm every other watched person the
  /// moment two links existed, and the symptom is a warning that never fires.
  Future<void> replacePendingWarnings(
    String linkId,
    Set<ScheduledWarning> warnings,
  ) =>
      _db.transaction((txn) async {
        await txn.delete(
          'pending_alarms',
          where: 'kind = ? AND link_id = ?',
          whereArgs: ['warning', linkId],
        );
        for (final warning in warnings) {
          await txn.insert('pending_alarms', {
            'kind': 'warning',
            'day': warning.day.toString(),
            // Empty rather than NULL — see the table definition. A warning
            // belongs to a link and has no slot, and NULLs compare distinct in
            // a primary key, so the same alarm could otherwise be inserted
            // repeatedly and counted twice by the diff that cancels.
            'slot': '',
            'link_id': linkId,
            'fires_at': warning.at.toUtc().millisecondsSinceEpoch,
            'zone': warning.at.location.name,
          });
        }
      });

  // ----------------------------------------------------------- reconcile lock

  /// Tries to take the reconcile lock, returning whether it was taken.
  ///
  /// ## The failure this exists for
  ///
  /// `reconcile()` computes `toCancel` as `currentlyScheduled − desired`, where
  /// `currentlyScheduled` is a **snapshot** of [pendingReminders]. Two runs that
  /// overlap each diff against their own snapshot, and whichever writes second
  /// replaces the row set without cancelling what it removed. The loser's alarms
  /// stay registered with the platform carrying no store row — and are then
  /// **unreachable forever**, because re-asserting the desired set cannot cancel
  /// something that is no longer in it.
  ///
  /// Measured on the POCO F3 on 2026-08-17 and reproduced: a fresh install left
  /// one reminder armed at 21:00 UTC that the store had no record of, because
  /// the first reconcile ran before the device zone was cached and raced the
  /// zone-corrected one behind it.
  ///
  /// ## Why it is a row and not a mutex
  ///
  /// §4: three isolates, sharing no memory. A Dart lock in the UI isolate is
  /// invisible to the alarm isolate and to the FCM isolate, both of which call
  /// the same `reconcile()`. The store is the only thing all three can see, so
  /// the lock lives where the contract already is.
  ///
  /// ## Why it expires
  ///
  /// A bare isolate can be killed at any moment — that is its normal ending, not
  /// an error — so a lock held until explicit release would eventually be held
  /// forever by a process that no longer exists, and the app would go quietly
  /// inert. That is the failure mode this project cannot detect in itself, so
  /// the lock is a **lease**: [now] plus [lease], after which anyone may take it.
  ///
  /// [now] is a parameter rather than a clock read, like every other decision in
  /// this codebase — the guard in `domain_purity_test.dart` covers this file.
  ///
  /// A [DatabaseException] — SQLite reporting the database busy under a
  /// concurrent writer — is reported as **not acquired** rather than thrown. The
  /// two are the same fact from the caller's side: somebody else is working, so
  /// do not touch the alarm set. Failing closed is the safe direction, because a
  /// skipped reconcile is repaired by the next one and a double reconcile is
  /// what strands an alarm.
  /// ## Why the lease is per [scope] and not one global row
  ///
  /// The first version had a single row, and the device showed what that costs.
  /// The watched and watcher sides are **independent reconciles over disjoint
  /// alarm sets** — `kind='reminder'` against `kind='warning'`, different
  /// platform ids, nothing shared. Both run when the app opens. With one lock,
  /// whichever lost the race skipped its alarm work entirely, so **every launch
  /// re-armed one side and left the other unarmed**:
  ///
  /// ```
  /// force-stop, then open the app
  ///   before the fix   reminders 18   warnings  0     ← watched won
  ///   after adding the watcher reconcile on open
  ///                    reminders  0   warnings 12     ← watcher won
  /// ```
  ///
  /// Neither is a race the lock exists to prevent. Serialising work that cannot
  /// conflict is not caution, it is a second way to leave alarms unarmed — the
  /// exact outcome the mechanism was added to stop. The lease is therefore per
  /// scope: `'watched'` and `'watcher'` today, and a finer key later if a scope
  /// ever needs splitting.
  Future<bool> acquireReconcileLock({
    required String scope,
    required String owner,
    required DateTime now,
    required Duration lease,
  }) async {
    try {
      return await _db.transaction(
        (txn) async {
          final rows = await txn
              .query('reconcile_lock', where: 'scope = ?', whereArgs: [scope]);
          if (rows.isNotEmpty) {
            final until = rows.first['expires_at'] as int;
            // A live lease ALWAYS refuses, including to a caller presenting the
            // same owner string. The first draft exempted the current holder so
            // it could refresh rather than deadlock against itself, and a test
            // caught what that actually buys: two runs whose owner tokens
            // happen to match — same label, same instant — would each be handed
            // the lock, and the exclusion would silently not exist. Nothing in
            // this design acquires twice, so the exemption protected against
            // nothing and disabled the mechanism under precisely the timing
            // that makes it necessary.
            if (until > now.millisecondsSinceEpoch) return false;
          }
          await txn.insert(
            'reconcile_lock',
            {
              'scope': scope,
              'owner': owner,
              'expires_at': now.add(lease).millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          return true;
        },
        // BEGIN EXCLUSIVE, so the write lock is taken before the read rather
        // than upgraded after it. Two connections that both read first and then
        // try to upgrade produce the classic deadlock, and the compare-and-set
        // above would not be one.
        exclusive: true,
      );
    } on DatabaseException {
      return false;
    }
  }

  /// Releases the lock, but **only if [owner] still holds it**.
  ///
  /// This is the only thing [owner] is for, and it is why callers must make it
  /// **unique per acquisition** rather than merely descriptive. The case: a slow
  /// run's lease expires, another isolate takes the lock, and then the slow run
  /// finishes and releases. With a reused token it would free a lock that now
  /// belongs to somebody else, and the exclusion would stop existing under
  /// exactly the load that made it necessary.
  Future<void> releaseReconcileLock(String scope, String owner) => _db.delete(
        'reconcile_lock',
        where: 'scope = ? AND owner = ?',
        whereArgs: [scope, owner],
      );

  /// Who holds one scope's lease and until when, or null. For the harness.
  Future<({String owner, DateTime expiresAt})?> reconcileLockHolder(
    String scope,
  ) async {
    final rows = await _db
        .query('reconcile_lock', where: 'scope = ?', whereArgs: [scope]);
    if (rows.isEmpty) return null;
    return (
      owner: rows.first['owner'] as String,
      expiresAt: _instant(rows.first['expires_at'])!,
    );
  }

  // ------------------------------------------------------------- debug: dump

  /// Every table, as rows. The debug harness's *dump `LocalStore`*.
  Future<Map<String, List<Map<String, Object?>>>> dump() async {
    final tables = [
      'settings',
      'links',
      'check_ins',
      'watcher_cache',
      'warnings_shown',
      'corrections_owed',
      'pending_alarms',
      'self_away',
      'reconcile_lock',
    ];
    return {
      for (final table in tables) table: await _db.query(table),
    };
  }

  /// Drops every row, keeping the schema. Debug builds only.
  Future<void> wipe() => _db.transaction((txn) async {
        for (final table in [
          'warnings_shown',
          'corrections_owed',
          'watcher_cache',
          'pending_alarms',
          'check_ins',
          'links',
          'self_away',
          'settings',
          // Cleared last and deliberately: a wipe is the harness resetting the
          // world, and leaving a lease behind would block the next reconcile
          // for as long as it had left to run, which reads exactly like the app
          // being broken.
          'reconcile_lock',
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
