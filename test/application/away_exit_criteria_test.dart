@TestOn('vm')
library;

import 'package:i_am_ok/application/watched_reconcile_service.dart';
import 'package:i_am_ok/application/watcher_reconcile_service.dart';
import 'package:i_am_ok/data/away_repository.dart';
import 'package:i_am_ok/data/check_in_reader.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_scheduler.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/warning_alarm_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// **Phase 6's exit criteria, driven end to end through both reconcilers.**
///
/// > Away set from **either side** silences **both** sides everywhere;
/// > cancelling restores both; and a device that was offline for the whole
/// > period still ends away on the right day.
///
/// ## Why the third clause gets the most room here
///
/// Away is the first feature in this app whose failure mode is **silence**.
/// Every phase before it could fail loudly — a warning that did not arrive, a
/// screen that would not load, a code that would not redeem. An away period
/// that is honoured when it should not be, or that never ends, produces no
/// notification and no error, on both sides, for up to 31 days. §12 calls a
/// permanently silent watcher *the one failure this app cannot detect in
/// itself*.
///
/// So these are built around **ending**, not around starting — and the third
/// clause is the hard one, because it is not a fan-out test at all. It is what
/// happens when the push never arrives, and it is where a cached away period
/// outliving its own `through` day would be invisible.
class _RecordingScheduler implements AlarmScheduler {
  final Set<ScheduledReminder> armed = {};

  @override
  Future<bool> apply({
    required Set<ScheduledReminder> toCancel,
    required Set<ScheduledReminder> desired,
    required bool hasAudience,
  }) async {
    armed
      ..removeAll(toCancel)
      ..addAll(desired);
    return true;
  }

  @override
  Future<void> cancelAll() async => armed.clear();

  @override
  Future<int> armedAccordingToPlugin() async => armed.length;
}

/// An [AwayRepository] that answers as told, and counts what it was asked.
///
/// It **extends** the real class rather than implementing an interface, so the
/// production constructor, the field set and the validation path are the ones
/// under test — only the two SDK calls are replaced. A hand-written double with
/// its own `write` would prove the test's own arithmetic and nothing else.
class _FakeAway extends AwayRepository {
  _FakeAway();

  AwayRecord? stored;

  /// What the next [read] does. Failures leave [stored] untouched *and* must
  /// leave the caller's cache untouched — that is ADR-0001 decision 1.
  AwayRead? nextRead;

  int reads = 0;

  @override
  Future<AwayRead> read(String watchedUid) async {
    reads += 1;
    return nextRead ?? AwayRead.succeeded(stored);
  }

  @override
  Future<AwayOutcome> write({
    required String watchedUid,
    required String setBy,
    required String setByName,
    required AwayPeriod period,
    required DayKey today,
    AwayPeriod? existing,
  }) async {
    // The real validation, so a test cannot write a period the app would not.
    final rejection = existing == null
        ? AwayRules.validateCreate(period, today)
        : AwayRules.validateUpdate(period, existing, today);
    if (rejection != null) {
      return const AwayOutcome.refused(AwayRefusal.rejectedPeriod);
    }
    stored = AwayRecord(period: period, setBy: setBy, setByName: setByName);
    return const AwayOutcome.set();
  }

  @override
  Future<AwayOutcome> cancel({required String watchedUid}) async {
    stored = null;
    return const AwayOutcome.set();
  }
}

/// The watcher's tier-1 read, answering from the same away document.
class _FakeReader implements CheckInReader {
  _FakeReader(this.away);

  _FakeAway away;
  Set<DayKey> checkInDays = {};

  /// Set to a failure to model a watcher whose phone cannot reach the server.
  FirestoreRead? forced;

  @override
  Future<FirestoreRead> read(Link link) async =>
      forced ??
      FirestoreRead.succeeded(checkInDays: checkInDays, away: away.stored);
}

/// Records everything, so a silent case can assert that **nothing** happened.
///
/// The strict form, for the reason the Phase 3 suite gives: a spurious
/// correction and a spurious cancel both satisfied an assertion that only
/// looked for warnings, and both are claims about a person.
class _RecordingNotifications implements WatcherNotifications {
  final List<String> calls = [];

  @override
  Future<void> showWarning({
    required String linkId,
    required DayKey day,
    required String body,
  }) async =>
      calls.add('warn:$linkId:$day');

  @override
  Future<void> showCorrection({
    required String linkId,
    required DayKey day,
    required String body,
  }) async =>
      calls.add('correct:$linkId:$day');

  @override
  Future<void> cancelWarning(String linkId, DayKey day) async =>
      calls.add('cancelWarn:$linkId:$day');

  @override
  Future<void> showAccessLost({
    required String linkId,
    required String body,
  }) async =>
      calls.add('access:$linkId');

  @override
  Future<void> cancelAccessLost(String linkId) async =>
      calls.add('cancelAccess:$linkId');

  bool get silent => calls.isEmpty;
}

/// The warning alarms, which these tests do not assert on.
class _NoWarningAlarms implements WarningAlarmScheduler {
  @override
  Future<bool> apply({
    required String linkId,
    required Set<ScheduledWarning> toCancel,
    required Set<ScheduledWarning> desired,
  }) async =>
      true;

  @override
  Future<void> cancelAll({
    required String linkId,
    required Set<ScheduledWarning> armed,
  }) async {}
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late _RecordingScheduler scheduler;
  late _FakeAway away;
  late FixedClock clock;

  const mum = 'mum';
  const ana = 'ana';

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    scheduler = _RecordingScheduler();
    away = _FakeAway();
    // 06:00 Madrid on the 17th, so every slot of every day ahead is still
    // schedulable and nothing is decided by the hour.
    clock = FixedClock(at(madrid, 2026, 8, 17, 6));
    await store.setDeviceTimezone('Europe/Madrid');
  });

  tearDown(() => store.close());

  WatchedReconcileService watched() => WatchedReconcileService(
        store: store,
        clock: clock,
        alarms: scheduler,
        away: away,
        notificationsEnabled: () async => true,
        selfUid: mum,
      );

  Future<void> seedLink() => store.upsertLink(Link(
        watchedUid: mum,
        watcherUid: ana,
        status: LinkStatus.accepted,
        watchedName: 'Mum',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        createdAt: DateTime.utc(2026, 7, 1),
      ));

  /// Days the watched side has reminders armed for.
  Set<DayKey> armedDays() => scheduler.armed.map((r) => r.day).toSet();

  // ---------------------------------------------------------------- clause 1

  group('away set from EITHER side silences BOTH sides', () {
    test('set by the watched person: her reminders stop on the away days',
        () async {
      await watched().reconcile(selfUid: mum);
      expect(armedDays(), contains(day('2026-08-18')),
          reason: 'the 18th is armed before anything is set');

      await away.write(
        watchedUid: mum,
        setBy: mum,
        setByName: 'Mum',
        period:
            AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22')),
        today: day('2026-08-17'),
      );
      await watched().reconcile(selfUid: mum);

      for (final d in [
        '2026-08-17',
        '2026-08-18',
        '2026-08-19',
        '2026-08-20',
        '2026-08-21',
        '2026-08-22',
      ]) {
        expect(armedDays(), isNot(contains(day(d))),
            reason: 'no reminder on an away day');
      }
    });

    test('set by a WATCHER: her reminders stop too, from her own read',
        () async {
      // The case §12 exists for — somebody in hospital, least able to answer a
      // prompt. Her phone has done nothing; it learns about it by reading.
      away.stored = AwayRecord(
        period:
            AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22')),
        setBy: ana,
        setByName: 'Ana',
      );

      final state = await watched().reconcile(selfUid: mum);

      expect(state.isAway, isTrue);
      expect(state.awaySetByName, 'Ana',
          reason: 'she is told WHO — §17s mitigation lives on this line');
      expect(armedDays(), isNot(contains(day('2026-08-18'))));
    });

    test('the window still extends past `through`, so she is re-armed for the '
        'days back', () async {
      // The property that lets the watched side stay display-only: the
      // reminders for the first days back are already scheduled before she
      // leaves, so the app re-arms itself without anyone opening it.
      away.stored = AwayRecord.unattributed(
        AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22')),
      );

      await watched().reconcile(selfUid: mum);

      expect(armedDays(), contains(day('2026-08-23')),
          reason: 'the first day back is armed');
      expect(armedDays(), contains(day('2026-08-29')),
          reason: 'the window extends to through + 7');
    });

    test('the watcher goes silent about the same days', () async {
      await seedLink();
      away.stored = AwayRecord(
        period:
            AwayPeriod(from: day('2026-08-14'), through: day('2026-08-22')),
        setBy: mum,
        setByName: 'Mum',
      );
      final reader = _FakeReader(away);
      final notifications = _RecordingNotifications();

      final result = await WatcherReconcileService(
        store: store,
        clock: clock,
        reader: reader,
        notifications: notifications,
        alarms: _NoWarningAlarms(),
        delivery: () async =>
            const WatcherDelivery.uniform(NotificationDelivery.available),
      ).reconcile(selfUid: ana);

      final person = result.people.single;
      expect(person.decision.outcome, WarningOutcome.silent);
      expect(person.decision.silenceReason, SilenceReason.awayVerified);
      expect(notifications.silent, isTrue,
          reason: 'nothing at all — not merely no warning: a spurious '
              'correction is a claim about a person too');
      expect(person.rowKind, WatchedRowKind.away);
    });

    test('TAPPING during an away day is still allowed and still recorded',
        () async {
      // §12 allows it: harmless, reassuring, and it writes a normal check-in
      // that watchers see as usual. `ReminderPolicy`'s docstring names the
      // plausible bug — suppressing the WRITE along with the reminders.
      away.stored = AwayRecord.unattributed(
        AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22')),
      );

      final state = await watched().tap(selfUid: mum);

      expect(state.hasTappedToday, isTrue);
      expect(await store.checkInOn(day('2026-08-17')), isNotNull);
      expect(state.isAway, isTrue, reason: 'still away, and still tapped');
    });
  });

  // ---------------------------------------------------------------- clause 2

  group('cancelling restores BOTH sides', () {
    test('truncating puts the reminders back from the cancel day on', () async {
      away.stored = AwayRecord(
        period:
            AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22')),
        setBy: mum,
        setByName: 'Mum',
      );
      await watched().reconcile(selfUid: mum);
      expect(armedDays(), isNot(contains(day('2026-08-18'))));

      // Cancelled on the 17th: `through` is pulled back to the 16th, so the
      // days already spent away stay covered and today onwards does not.
      final truncated = away.stored!.period.cancelOn(day('2026-08-17'))!;
      await away.write(
        watchedUid: mum,
        setBy: mum,
        setByName: 'Mum',
        period: truncated,
        today: day('2026-08-17'),
        existing: away.stored!.period,
      );
      await watched().reconcile(selfUid: mum);

      expect(truncated.through, day('2026-08-16'));
      expect(armedDays(), contains(day('2026-08-17')));
      expect(armedDays(), contains(day('2026-08-18')));
    });

    test('the days already spent away STAY covered — the false claim ADR-0001 '
        'exists to stop', () async {
      final holiday =
          AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22'));
      final truncated = holiday.cancelOn(day('2026-08-17'))!;

      expect(truncated.covers(day('2026-08-15')), isTrue);
      expect(truncated.covers(day('2026-08-16')), isTrue,
          reason: 'deleting instead would retroactively un-cover these, and '
              'the next device to refresh would warn about a day she really '
              'was away');
      expect(truncated.covers(day('2026-08-17')), isFalse);
    });

    test('cancelling on the FIRST away day deletes, because truncating cannot',
        () async {
      // `through = from - 1` would violate `through >= from`, which ADR-0001
      // turns on being unrepresentable.
      final startsToday =
          AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22'));
      expect(startsToday.cancelOn(day('2026-08-17')), isNull);

      away.stored = AwayRecord.unattributed(startsToday);
      await watched().reconcile(selfUid: mum);
      expect(armedDays(), isNot(contains(day('2026-08-18'))));

      await away.cancel(watchedUid: mum);
      await watched().reconcile(selfUid: mum);

      expect(await store.selfAway(), isNull,
          reason: 'the successful read overwrote the cache with nothing');
      expect(armedDays(), contains(day('2026-08-18')));
    });

    test('a cancellation the NUDGE never delivered still lands, by reading',
        () async {
      // The failure ADR-0001 was written for. Every push was lost; the device
      // finds out because a reconcile reads the document and replaces the cache
      // WHOLESALE, including with nothing.
      away.stored = AwayRecord.unattributed(
        AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22')),
      );
      await watched().reconcile(selfUid: mum);
      expect((await store.selfAway()), isNotNull);

      away.stored = null; // cancelled from another phone; no nudge arrives
      final state = await watched().reconcile(selfUid: mum);

      expect(state.isAway, isFalse);
      expect(await store.selfAway(), isNull);
      expect(armedDays(), contains(day('2026-08-18')));
    });

    test('a FAILED read may not clear a legitimate away', () async {
      // ADR-0001 decision 1, from the other direction. A timeout, a permission
      // denial and an App Check rejection all happen while online; clearing on
      // any of them would nag an elderly person through a holiday and tell her
      // family she had stopped checking in.
      away.stored = AwayRecord.unattributed(
        AwayPeriod(from: day('2026-08-15'), through: day('2026-08-22')),
      );
      await watched().reconcile(selfUid: mum);

      for (final failure in <AwayRead>[
        const AwayRead.unreachable(UnreachableCause.offline),
        const AwayRead.unreachable(UnreachableCause.timeout),
        const AwayRead.refused(RefusedCause.permissionDenied),
        const AwayRead.refused(RefusedCause.appCheckRejected),
      ]) {
        away.nextRead = failure;
        final state = await watched().reconcile(selfUid: mum);
        expect(state.isAway, isTrue, reason: '$failure must not clear it');
        expect(await store.selfAway(), isNotNull);
      }
    });
  });

  // ---------------------------------------------------------------- clause 3

  group('a device offline for the WHOLE period still ends away on the right '
      'day', () {
    /// The period, and the device that never once reaches the server inside it.
    setUp(() async {
      away.stored = AwayRecord(
        period:
            AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22')),
        setBy: ana,
        setByName: 'Ana',
      );
      // One successful read to seed the cache — she was online when it was set,
      // or a nudge got through once. After this, nothing.
      await watched().reconcile(selfUid: mum);
      away.nextRead = const AwayRead.unreachable(UnreachableCause.offline);
    });

    test('it is honoured on every away day with no read succeeding', () async {
      for (final d in [17, 18, 19, 20, 21, 22]) {
        clock = FixedClock(at(madrid, 2026, 8, d, 6));
        final state = await watched().reconcile(selfUid: mum);
        expect(state.isAway, isTrue, reason: 'the $d th is inside the period');
      }
    });

    test('IT ENDS on the day after `through`, with nothing having been read',
        () async {
      // The clause the phase turns on. Nothing is transmitted and nothing needs
      // to be: expiry is ARITHMETIC against `through`, computed on the device
      // (§12). The original sketch sent an "away finished" message, and losing
      // it left the app silent for ever — because silence is what away mode
      // looks like.
      clock = FixedClock(at(madrid, 2026, 8, 23, 6));

      final state = await watched().reconcile(selfUid: mum);

      expect(away.nextRead, isA<AwayReadUnreachable>(),
          reason: 'the guard on this test: no read has succeeded');
      expect(state.isAway, isFalse, reason: 'the 23rd is the first day back');
      expect(await store.selfAway(), isNotNull,
          reason: 'the ROW is not deleted — the days spent away stay covered, '
              'which is ADR-0001s argument applied to the cache');
      expect(armedDays(), contains(day('2026-08-23')),
          reason: 'and she is reminded again, on the right day');
    });

    test('and it does not end a day early or a day late', () async {
      clock = FixedClock(at(madrid, 2026, 8, 22, 6));
      expect((await watched().reconcile(selfUid: mum)).isAway, isTrue,
          reason: '`through` is INCLUSIVE — the 22nd is still an away day');

      clock = FixedClock(at(madrid, 2026, 8, 23, 6));
      expect((await watched().reconcile(selfUid: mum)).isAway, isFalse);
    });

    test('the WATCHER ends it on the same day, with nothing having been read',
        () async {
      await seedLink();
      final reader = _FakeReader(away);
      final notifications = _RecordingNotifications();

      WatcherReconcileService watcher() => WatcherReconcileService(
            store: store,
            clock: clock,
            reader: reader,
            notifications: notifications,
            alarms: _NoWarningAlarms(),
            delivery: () async =>
                const WatcherDelivery.uniform(NotificationDelivery.available),
          );

      // One successful read on the 22nd — the last away day — so the cache is
      // fresh and ADR-0001's two-day staleness bound is not what decides
      // anything below. Then the phone goes dark for good.
      clock = FixedClock(at(madrid, 2026, 8, 22, 11));
      await watcher().reconcile(selfUid: ana);
      reader.forced = const FirestoreRead.unreachable(UnreachableCause.offline);

      // The 23rd: deciding about the 22nd, which the away period covers. Silent,
      // and silent for the RIGHT reason — an unverifiable away would also be
      // quiet-ish, and it is a different claim.
      clock = FixedClock(at(madrid, 2026, 8, 23, 11));
      final lastAwayDay = (await watcher().reconcile(selfUid: ana)).people.single;
      expect(lastAwayDay.decision.day, day('2026-08-22'));
      expect(lastAwayDay.decision.outcome, WarningOutcome.silent);
      expect(lastAwayDay.decision.silenceReason, SilenceReason.awayVerified);

      // The 24th: deciding about the 23rd — the first day back, and a day
      // nobody tapped. The away no longer covers it, by arithmetic alone, on a
      // device that has read nothing since. So the watcher speaks.
      clock = FixedClock(at(madrid, 2026, 8, 24, 11));
      final firstDayBack = (await watcher().reconcile(selfUid: ana)).people.single;

      expect(firstDayBack.decision.day, day('2026-08-23'));
      expect(firstDayBack.decision.isWarning, isTrue,
          reason: 'the away period ended by arithmetic, with nothing '
              'transmitted and nothing read — the whole of clause 3');
      expect(firstDayBack.rowKind, isNot(WatchedRowKind.away),
          reason: 'and the row stops saying she is away');
    });

    test('past ADR-0001s bound an away day is NOT silently honoured for ever',
        () async {
      // The other half of the same clause, and the one that stops "offline is
      // fine" becoming "offline is silent". §10 step 5: silent if verified
      // within two days, otherwise the DISTINCT unverifiable-away message —
      // which still names the away period rather than claiming she missed a day.
      await seedLink();
      final reader = _FakeReader(away);
      final notifications = _RecordingNotifications();

      clock = FixedClock(at(madrid, 2026, 8, 17, 11));
      await WatcherReconcileService(
        store: store,
        clock: clock,
        reader: reader,
        notifications: notifications,
        alarms: _NoWarningAlarms(),
        delivery: () async =>
            const WatcherDelivery.uniform(NotificationDelivery.available),
      ).reconcile(selfUid: ana);
      reader.forced = const FirestoreRead.unreachable(UnreachableCause.offline);

      clock = FixedClock(at(madrid, 2026, 8, 22, 11));
      final stale = (await WatcherReconcileService(
        store: store,
        clock: clock,
        reader: reader,
        notifications: notifications,
        alarms: _NoWarningAlarms(),
        delivery: () async =>
            const WatcherDelivery.uniform(NotificationDelivery.available),
      ).reconcile(selfUid: ana))
          .people
          .single;

      expect(stale.decision.outcome, WarningOutcome.warnUnverifiableAway,
          reason: 'five days without a successful read is past the two-day '
              'bound, and a cached away that cannot be re-verified must not '
              'buy unlimited silence');
      expect(stale.decision.away, isNotNull,
          reason: 'the message still names the away period — it is a claim '
              'about THIS PHONE, not about her missing a day');
    });

    test('an away period that never ended would be INVISIBLE, so pin the '
        'arithmetic directly', () async {
      // The failure this clause is really about, asserted where it lives rather
      // than only through the service: nothing anywhere consults a flag.
      final period =
          AwayPeriod(from: day('2026-08-17'), through: day('2026-08-22'));
      expect(period.covers(day('2026-08-22')), isTrue);
      expect(period.covers(day('2026-08-23')), isFalse);
      expect(period.hasExpiredOn(day('2026-08-23')), isTrue);
      expect(period.firstDayBack, day('2026-08-23'));
    });
  });
}

