@TestOn('vm')
library;

import 'dart:io';

import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// A stored instant, as a plain UTC [DateTime].
///
/// Deliberately not the suite's `at(utc, ...)` helper. That returns a
/// `tz.TZDateTime`, and the store round-trips instants through epoch
/// milliseconds and hands back a plain UTC `DateTime` — the same moment, a
/// different runtime type, and `TZDateTime`'s `==` is type-sensitive. Using the
/// canonical form here keeps these tests about *the encoding* rather than about
/// which `DateTime` subclass the fixture happened to build.
DateTime utcAt(int year, int month, int day,
        [int hour = 0, int minute = 0, int second = 0]) =>
    DateTime.utc(year, month, day, hour, minute, second);

/// `LocalStore` round-trips, against **real SQLite**.
///
/// Real rather than a fake, because the thing most likely to be wrong here is
/// the encoding at the boundary — a `DayKey` that comes back as a different day,
/// an enum that comes back null — and a fake store would agree with whatever the
/// code did. `docs/testing/strategy.md` names this level explicitly.
///
/// The store is the **cross-isolate contract** (§4): it is the only thing a bare
/// alarm isolate can see, so a field that fails to round-trip is not a data bug,
/// it is a silent behaviour change in an isolate that cannot report anything.
/// §6 says it plainly — *missing `accessLostNotifiedOn` means the reminder
/// dedupe silently fails and a reminder day fires four times.*
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
  });

  tearDown(() => store.close());

  Link linkTo(
    String watcherUid, {
    String watcherName = 'Ana',
    LinkStatus status = LinkStatus.accepted,
  }) =>
      Link(
        watchedUid: 'mum',
        watcherUid: watcherUid,
        status: status,
        watchedName: 'Mum',
        watcherName: watcherName,
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        warningLocalTime: const LocalTimeOfDay(8, 30),
        createdAt: utcAt(2026, 7, 1, 9, 15),
        acceptedAt: utcAt(2026, 7, 1, 9, 20),
      );

  group('links', () {
    test('round-trip every field', () async {
      final original = linkTo('ana');
      await store.upsertLink(original);
      final read = (await store.allLinks()).single;

      expect(read, original, reason: 'value equality covers every field');
      expect(read.watcherName, 'Ana',
          reason: 'the field the Tap screen cannot be built without');
      expect(read.warningLocalTime, const LocalTimeOfDay(8, 30));
      expect(read.activeFrom, day('2026-07-01'));
      expect(read.acceptedAt, utcAt(2026, 7, 1, 9, 20));
    });

    test('upsert is idempotent on the deterministic id', () async {
      await store.upsertLink(linkTo('ana'));
      await store.upsertLink(linkTo('ana'));
      expect(await store.allLinks(), hasLength(1));
    });

    test('a revocation overwrites rather than duplicating', () async {
      await store.upsertLink(linkTo('ana'));
      await store.upsertLink(linkTo('ana').copyWith(status: LinkStatus.revoked));
      final links = await store.allLinks();
      expect(links, hasLength(1));
      expect(links.single.status, LinkStatus.revoked);
    });

    test('re-upserting a link does NOT destroy its watcher cache', () async {
      // `INSERT OR REPLACE` resolves a primary-key conflict by DELETING the
      // existing row, and `watcher_cache` / `warnings_shown` both cascade on
      // delete — so the obvious implementation silently wiped the standing
      // warnings, `lastConfirmedDay`, the staleness stamp and the access-lost
      // cadence anchor every time a link was re-written.
      //
      // Re-writing a link is not rare: Phase 4 refreshes links from Firestore
      // on every reconcile, and a revocation does it today. The test above
      // passes happily while all of that is destroyed, which is why this one
      // exists separately.
      await store.upsertLink(linkTo('ana'));
      final cache = WatcherCache(
        lastConfirmedDay: day('2026-08-16'),
        warningsShownFor: {day('2026-08-15'): WarningOutcome.warnOnline},
        lastReconcileAt: utcAt(2026, 8, 17, 10, 14),
        accessLostSince: day('2026-08-10'),
        accessLostCause: RefusedCause.unauthenticated,
        accessLostNotifiedOn: day('2026-08-13'),
      );
      await store.saveWatcherCache('mum_ana', cache);

      await store.upsertLink(linkTo('ana').copyWith(status: LinkStatus.revoked));

      expect(await store.watcherCache('mum_ana'), cache,
          reason: 'every field survives a link rewrite');
    });

    test('upsert uses no SQL newer than the oldest Android it supports',
        () async {
      // `ON CONFLICT ... DO UPDATE` needs SQLite 3.24, which Android ships only
      // from API 29. minSdk here is 24 — deliberately, because the device
      // matrix says the watched person's phone is likely to be old — so on
      // API 24-28 that syntax is a PARSE ERROR and the app cannot write a link
      // at all.
      //
      // No test can catch that by running: `sqflite_common_ffi` binds a modern
      // desktop SQLite, and the only physical device is API 33. So this asserts
      // the source instead, which is the level the mistake lives at.
      //
      // Comments are stripped first — this file explains at length why the
      // banned syntax is banned, and matching its own documentation is how the
      // check first failed.
      final code = (await File('lib/data/local_store.dart').readAsString())
          .split('\n')
          .map((line) {
            final comment = line.indexOf('//');
            return comment == -1 ? line : line.substring(0, comment);
          })
          .join('\n')
          .toUpperCase();

      expect(code, isNot(contains('ON CONFLICT')),
          reason: 'UPSERT syntax requires SQLite 3.24 / API 29; use an UPDATE '
              'then INSERT in a transaction');
      expect(code, isNot(contains('RETURNING')),
          reason: 'RETURNING requires SQLite 3.35 / API 34');
      expect(code, contains('CREATE TABLE'),
          reason: 'the premise: this really is reading the schema source');
    });

    test('an updated link keeps its changed fields', () async {
      // The other half: a real upsert must still actually update.
      await store.upsertLink(linkTo('ana'));
      await store.upsertLink(
        linkTo('ana', watcherName: 'Ana María')
            .copyWith(warningLocalTime: const LocalTimeOfDay(9, 45)),
      );
      final link = (await store.allLinks()).single;
      expect(link.watcherName, 'Ana María');
      expect(link.warningLocalTime, const LocalTimeOfDay(9, 45));
    });

    test('the two directions are queried separately', () async {
      await store.upsertLink(linkTo('ana'));
      await store.upsertLink(Link(
        watchedUid: 'granddad',
        watcherUid: 'mum',
        status: LinkStatus.accepted,
        watchedName: 'Granddad',
        watcherName: 'Mum',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        createdAt: utcAt(2026, 7, 1),
      ));

      expect((await store.linksWatching('mum')).single.watcherUid, 'ana');
      expect((await store.linksWatchedBy('mum')).single.watchedUid, 'granddad');
    });
  });

  group('check-ins', () {
    test('round-trip', () async {
      final checkIn = CheckIn(
        day: day('2026-08-17'),
        deviceTappedAt: utcAt(2026, 8, 17, 7, 14),
        timezone: 'Europe/Madrid',
      );
      await store.recordCheckIn(checkIn);
      expect(await store.checkInOn(day('2026-08-17')), checkIn);
    });

    test('a second tap the same day is an UPDATE, not a duplicate', () async {
      // The same once-per-day property the Firestore document id gives (§7),
      // which is why no dedupe logic exists anywhere to be got wrong.
      await store.recordCheckIn(CheckIn(
        day: day('2026-08-17'),
        deviceTappedAt: utcAt(2026, 8, 17, 7, 14),
        timezone: 'Europe/Madrid',
      ));
      await store.recordCheckIn(CheckIn(
        day: day('2026-08-17'),
        deviceTappedAt: utcAt(2026, 8, 17, 21, 40),
        timezone: 'Europe/Madrid',
      ));

      expect(await store.allCheckIns(), hasLength(1));
      expect((await store.checkInOn(day('2026-08-17')))!.deviceTappedAt,
          utcAt(2026, 8, 17, 21, 40));
    });

    test('a 23:50 tap keeps the day it was made on', () async {
      // §11's whole correction to HANDOVER.md: the day is decided on the device
      // at tap time. If this ever came back as the following day the check-in
      // would land where nobody looks for it — §17's "High, silently wrong
      // data".
      final late = CheckIn.forTap(
        now: at(madrid, 2026, 8, 17, 23, 50),
        zone: madrid,
      );
      await store.recordCheckIn(late);
      expect(await store.checkedInDays(), {day('2026-08-17')});
    });
  });

  group('the watcher cache — §6 field by field', () {
    setUp(() => store.upsertLink(linkTo('ana')));

    test('an unreconciled link reads as empty, not as an error', () async {
      final cache = await store.watcherCache('mum_ana');
      expect(cache.lastConfirmedDay, isNull);
      expect(cache.lastReconcileAt, isNull);
      expect(cache.warningsShownFor, isEmpty);
      expect(cache.hasLostAccess, isFalse);
    });

    test('every field round-trips', () async {
      final cache = WatcherCache(
        away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20')),
        lastConfirmedDay: day('2026-08-16'),
        warningsShownFor: {
          day('2026-08-14'): WarningOutcome.warnOnline,
          day('2026-08-15'): WarningOutcome.warnOffline,
        },
        lastReconcileAt: utcAt(2026, 8, 17, 10, 14),
        accessLostSince: day('2026-08-10'),
        accessLostCause: RefusedCause.unauthenticated,
        accessLostNotifiedOn: day('2026-08-13'),
        // ADR-0009's catch-up pointer. Deliberately a DIFFERENT day from
        // `lastConfirmedDay` above: the two are both nullable DayKeys on the
        // same row, and a fixture that gave them the same value would pass with
        // the two columns swapped.
        lastDecidedDay: day('2026-08-17'),
      );

      await store.saveWatcherCache('mum_ana', cache);
      expect(await store.watcherCache('mum_ana'), cache);
    });

    test('lastDecidedDay survives the round-trip on its own', () async {
      // Named separately from the field-by-field test above because a null it
      // never wrote would compare equal to a null it failed to read. This one
      // asserts the value, not the equality.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(lastDecidedDay: day('2026-08-17')),
      );
      expect(
        (await store.watcherCache('mum_ana')).lastDecidedDay,
        day('2026-08-17'),
      );

      // Null clears it: a cache written without one must not inherit the old
      // value, or a device that reset would keep catching up on days it had
      // already spoken about.
      await store.saveWatcherCache('mum_ana', const WatcherCache.empty());
      expect((await store.watcherCache('mum_ana')).lastDecidedDay, isNull);
    });

    test('lastReconcileAt keeps the TIME, not just the day', () async {
      // ADR-0002 decision 3 made this a full timestamp because the copy renders
      // "offline since 10:14". Rounding it to a date here would leave the
      // message with nothing to say.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(lastReconcileAt: utcAt(2026, 8, 17, 10, 14)),
      );
      final read = await store.watcherCache('mum_ana');
      expect(read.lastReconcileAt, utcAt(2026, 8, 17, 10, 14));
    });

    test('accessLostNotifiedOn survives — the dedupe depends on it', () async {
      // §6 names this one specifically: without it the day-granular cadence
      // cannot tell whether today's reminder has been given, and reconcile()
      // runs on app open, FCM, alarm and boot — so a reminder day fires four
      // times.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          accessLostSince: day('2026-08-10'),
          accessLostCause: RefusedCause.permissionDenied,
          accessLostNotifiedOn: day('2026-08-13'),
        ),
      );
      expect((await store.watcherCache('mum_ana')).accessLostNotifiedOn,
          day('2026-08-13'));
    });

    test('warningsShownFor keeps WHICH message is standing', () async {
      // §6 called this a set of days. ADR-0004 made more than one message
      // reachable for the same D, and storing only the day would make a
      // stronger, now-verified message unable to replace a stale hedge.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          warningsShownFor: {day('2026-08-15'): WarningOutcome.warnOffline},
        ),
      );
      expect((await store.watcherCache('mum_ana')).warningsShownFor,
          {day('2026-08-15'): WarningOutcome.warnOffline});
    });

    test('correctionsOwedFor survives the round-trip on its own', () async {
      // A retraction this device established but could not speak. If it fails
      // to persist, the sentence is lost at the first process death — and the
      // held case is *by definition* the one where the app is not being used,
      // so the process dying before the hour arrives is the normal course of
      // events rather than an edge.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(correctionsOwedFor: {day('2026-08-15')}),
      );
      expect((await store.watcherCache('mum_ana')).correctionsOwedFor,
          {day('2026-08-15')});
    });

    test('saving replaces the owed retractions rather than merging', () async {
      // A merge would leave a day owed after it had been spoken, and the family
      // would be told again on every reconcile for the life of the link.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(correctionsOwedFor: {day('2026-08-15')}),
      );
      await store.saveWatcherCache('mum_ana', const WatcherCache.empty());
      expect((await store.watcherCache('mum_ana')).correctionsOwedFor, isEmpty);
    });

    test('an away period cleared to null really clears', () async {
      // ADR-0001 decision 1: on a successful read `away` is overwritten
      // wholesale, INCLUDING with nothing. If a null failed to persist here,
      // a remotely cancelled away would silence the watcher until its original
      // `through` — the sixteen-day defect that ADR exists for.
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20')),
        ),
      );
      await store.saveWatcherCache('mum_ana', const WatcherCache.empty());
      expect((await store.watcherCache('mum_ana')).away, isNull);
    });

    test('saving replaces the standing warnings rather than merging', () async {
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          warningsShownFor: {day('2026-08-15'): WarningOutcome.warnOnline},
        ),
      );
      await store.saveWatcherCache('mum_ana', const WatcherCache.empty());
      expect((await store.watcherCache('mum_ana')).warningsShownFor, isEmpty,
          reason: 'a correction removes the day; a merge would resurrect it');
    });

    test('two links do not share a cache', () async {
      // Notification ids are hash(link, D) precisely so one watched person's
      // correction cannot touch another's standing warning. The store owes the
      // same separation.
      await store.upsertLink(linkTo('beto', watcherName: 'Beto'));
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          warningsShownFor: {day('2026-08-15'): WarningOutcome.warnOnline},
        ),
      );
      expect((await store.watcherCache('mum_beto')).warningsShownFor, isEmpty);
    });
  });

  group('pending alarms', () {
    test('round-trip, instant included', () async {
      // ScheduledReminder equality covers the instant, so a reminder that came
      // back with a different `at` would look like a change and churn every
      // reconcile.
      final reminders = {
        for (final slot in ReminderSlot.values)
          ScheduledReminder(
            day: day('2026-08-17'),
            slot: slot,
            at: day('2026-08-17').at(slot.time, madrid),
          ),
      };
      await store.replacePendingReminders(reminders);
      expect(await store.pendingReminders(), reminders);
    });

    test('the zone survives, so a DST-era instant is not re-derived wrong',
        () async {
      final reminder = ScheduledReminder(
        day: day('2026-10-26'),
        slot: ReminderSlot.midday,
        at: day('2026-10-26').at(ReminderSlot.midday.time, madrid),
      );
      await store.replacePendingReminders({reminder});
      final read = (await store.pendingReminders()).single;
      expect(read.at, reminder.at);
      expect(read.at.location.name, 'Europe/Madrid');
    });

    test('replacing is a replacement, not an append', () async {
      await store.replacePendingReminders({
        ScheduledReminder(
          day: day('2026-08-17'),
          slot: ReminderSlot.midday,
          at: day('2026-08-17').at(ReminderSlot.midday.time, madrid),
        ),
      });
      await store.replacePendingReminders(const {});
      expect(await store.pendingReminders(), isEmpty);
    });
  });

  group('pending WARNINGS — the same round-trip, on the logic-bearing side', () {
    /// The reminder side has had these two tests since Phase 2; the warning
    /// side got its round-trip only incidentally, through a service test at a
    /// non-DST instant that asserts against the alarm fake rather than the
    /// store.
    ///
    /// It matters more here. `ScheduledWarning` equality covers the instant, and
    /// the store's answer is what `currentlyScheduled` diffs against — so a
    /// warning that came back with a different `at` looks like a change on every
    /// single reconcile, and the window is cancelled and re-armed forever. On
    /// the side where each of those is a binder call from a woken isolate, and
    /// where a mis-ordered churn is a warning that never fires.
    const mum = 'mum_ana';

    setUp(() => store.upsertLink(Link(
          watchedUid: 'mum',
          watcherUid: 'ana',
          status: LinkStatus.accepted,
          watchedName: 'Mum',
          watcherName: 'Ana',
          watchedTimezone: 'Europe/Madrid',
          activeFrom: day('2026-08-01'),
          createdAt: DateTime.utc(2026, 8, 1),
        )));

    test('round-trip, instant included', () async {
      final warnings = {
        for (var i = 0; i < 3; i++)
          ScheduledWarning(
            day: day('2026-08-17').plusDays(i),
            at: day('2026-08-17')
                .plusDays(i)
                .at(const LocalTimeOfDay(10, 0), madrid),
          ),
      };
      await store.replacePendingWarnings(mum, warnings);
      expect(await store.pendingWarnings(mum), warnings);
    });

    test('the zone survives a DST-era instant', () async {
      // 2026-10-26 is the day after Madrid falls back to CET. An instant
      // re-derived against the wrong offset lands an hour out, and the diff
      // churns the whole window every reconcile from then on.
      final warning = ScheduledWarning(
        day: day('2026-10-26'),
        at: day('2026-10-26').at(const LocalTimeOfDay(10, 0), madrid),
      );
      await store.replacePendingWarnings(mum, {warning});

      final read = (await store.pendingWarnings(mum)).single;
      expect(read.at, warning.at);
      expect(read.at.location.name, 'Europe/Madrid');
      expect(read.at.hour, 10);
      expect(read.at.timeZoneOffset.inHours, 1, reason: 'CET, not CEST');
    });

    test('replacing one link leaves another link\'s warnings alone', () async {
      // Warnings are per link, unlike reminders. A replace that cleared the
      // whole table would leave every other watched person with no record of
      // what is armed — and the next reconcile would diff against nothing.
      await store.upsertLink(Link(
        watchedUid: 'granddad',
        watcherUid: 'ana',
        status: LinkStatus.accepted,
        watchedName: 'Granddad',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-08-01'),
        createdAt: DateTime.utc(2026, 8, 1),
      ));
      final granddads = {
        ScheduledWarning(
          day: day('2026-08-18'),
          at: day('2026-08-18').at(const LocalTimeOfDay(10, 0), madrid),
        ),
      };
      await store.replacePendingWarnings('granddad_ana', granddads);
      await store.replacePendingWarnings(mum, {
        ScheduledWarning(
          day: day('2026-08-18'),
          at: day('2026-08-18').at(const LocalTimeOfDay(8, 0), madrid),
        ),
      });

      expect(await store.pendingWarnings('granddad_ana'), granddads);
    });

    test('replacing with an empty set clears that link', () async {
      await store.replacePendingWarnings(mum, {
        ScheduledWarning(
          day: day('2026-08-18'),
          at: day('2026-08-18').at(const LocalTimeOfDay(10, 0), madrid),
        ),
      });
      await store.replacePendingWarnings(mum, const {});
      expect(await store.pendingWarnings(mum), isEmpty);
    });
  });

  group('settings', () {
    test('the device timezone round-trips', () async {
      // The only way a bare alarm isolate ever learns the device's zone
      // (ADR-0002 decision 2).
      await store.setDeviceTimezone('Europe/Madrid');
      expect(await store.deviceTimezone(), 'Europe/Madrid');
    });

    test('the clock offset round-trips and clears', () async {
      // Stored rather than held in memory so the alarm isolate agrees with the
      // UI about what day it is under a forced date.
      expect(await store.clockOffset(), Duration.zero);
      await store.setClockOffset(const Duration(days: 3, hours: 2));
      expect(await store.clockOffset(), const Duration(days: 3, hours: 2));
      await store.setClockOffset(Duration.zero);
      expect(await store.clockOffset(), Duration.zero);
    });

    test('the 12h/24h setting round-trips in both directions', () async {
      // **Both directions, because the two are not symmetric.** `true` is stored
      // by *deleting* the row, so the 12h → 24h transition is the only one that
      // exercises that branch — and it is the direction a reader takes when they
      // switch their phone back. Nothing covered either until the Phase 3 gate.
      expect(await store.uses24HourClock(), isTrue,
          reason: 'the approved strings are 24-hour, so an uncached device '
              'renders what screens.md shows rather than a third thing');

      await store.setUses24HourClock(false);
      expect(await store.uses24HourClock(), isFalse);

      await store.setUses24HourClock(true);
      expect(await store.uses24HourClock(), isTrue,
          reason: 'the delete branch: a reader switching back to 24-hour must '
              'not be stuck on 12-hour');
    });

    test('the two health flags round-trip and clear', () async {
      // Same null-deletes semantics as the setting above, and the same gap: both
      // had behavioural coverage through the service and no store round-trip.
      // §13's panel reads them in Phase 7; `dump` shows them meanwhile, and a
      // flag that cannot clear itself reports a fault that is over.
      expect(await store.linkReconcileFailed(), isFalse);
      await store.setLinkReconcileFailed(true);
      expect(await store.linkReconcileFailed(), isTrue);
      await store.setLinkReconcileFailed(false);
      expect(await store.linkReconcileFailed(), isFalse);

      // Null, not false: before the first apply nothing has been armed, so there
      // is no claim to make either way. A default of `false` would report a
      // degradation that has not happened.
      expect(await store.warningAlarmsExact(), isNull);
      await store.setWarningAlarmsExact(false);
      expect(await store.warningAlarmsExact(), isFalse);
      await store.setWarningAlarmsExact(true);
      expect(await store.warningAlarmsExact(), isTrue);
    });
  });

  group('a row this build cannot interpret', () {
    // Every decoder in the store degrades rather than throwing, because a throw
    // happens inside a bare alarm isolate where it looks exactly like the app
    // working and saying nothing. These assert the documented degradations,
    // which no happy-path round-trip can reach.

    test('an unknown link status reads as revoked, and does not throw',
        () async {
      await store.upsertLink(linkTo('ana'));
      await store.database.update(
        'links',
        {'status': 'suspended'},
        where: 'id = ?',
        whereArgs: ['mum_ana'],
      );

      final links = await store.linksWatching('mum');
      expect(links.single.status, LinkStatus.revoked,
          reason: 'revoked is §10s silent branch — an uninterpretable link '
              'says nothing rather than risking a false claim');
    });

    test('an unknown warning outcome drops that day, keeping the rest',
        () async {
      await store.upsertLink(linkTo('ana'));
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          warningsShownFor: {day('2026-08-15'): WarningOutcome.warnOnline},
        ),
      );
      await store.database.insert('warnings_shown', {
        'link_id': 'mum_ana',
        'day': '2026-08-16',
        'outcome': 'warnGreen',
      });

      final cache = await store.watcherCache('mum_ana');
      expect(cache.warningsShownFor,
          {day('2026-08-15'): WarningOutcome.warnOnline},
          reason: 'the unreadable day is treated as not standing, so the '
              'warning may be shown again — noisy, and the safe direction');
    });

    test('an unknown refusal cause becomes RefusedCause.unknown, never null',
        () async {
      // Null would mean "access is fine" alongside a non-null accessLostSince,
      // which is an impossible state. `unknown` has a defined §13 remediation.
      await store.upsertLink(linkTo('ana'));
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(accessLostSince: day('2026-08-10')),
      );
      await store.database.update(
        'watcher_cache',
        {'access_lost_cause': 'quotaExceeded'},
        where: 'link_id = ?',
        whereArgs: ['mum_ana'],
      );

      final cache = await store.watcherCache('mum_ana');
      expect(cache.accessLostCause, RefusedCause.unknown);
      expect(cache.hasLostAccess, isTrue);
    });

    test('an unknown zone drops that pending alarm rather than throwing',
        () async {
      await store.replacePendingReminders({
        ScheduledReminder(
          day: day('2026-08-17'),
          slot: ReminderSlot.midday,
          at: day('2026-08-17').at(ReminderSlot.midday.time, madrid),
        ),
      });
      await store.database.update('pending_alarms', {'zone': 'Mars/Olympus'});

      // Dropped, so the reconciler believes it is not armed and schedules over
      // the same platform id — a replacement, which is the recoverable
      // direction.
      expect(await store.pendingReminders(), isEmpty);
    });
  });

  group('the harness needs it readable', () {
    test('dump covers every table', () async {
      final dump = await store.dump();
      expect(
        dump.keys,
        containsAll([
          'settings',
          'links',
          'check_ins',
          'watcher_cache',
          'warnings_shown',
          'pending_alarms',
          'self_away',
        ]),
      );
    });

    test('wipe empties everything and keeps the schema', () async {
      await store.upsertLink(linkTo('ana'));
      await store.setDeviceTimezone('Europe/Madrid');
      await store.recordCheckIn(CheckIn.forTap(
        now: at(madrid, 2026, 8, 17, 9),
        zone: madrid,
      ));

      await store.wipe();

      expect(await store.allLinks(), isEmpty);
      expect(await store.allCheckIns(), isEmpty);
      expect(await store.deviceTimezone(), isNull);
      // Still usable afterwards — a wipe that dropped the tables would leave
      // the app broken until reinstall.
      await store.upsertLink(linkTo('ana'));
      expect(await store.allLinks(), hasLength(1));
    });
  });

  /// The onboarding answers, and what a sign-out does to them.
  ///
  /// `clearSelfUid` had **no test of its own** before Phase 5, which is what
  /// made adding a second thing for it to delete worth covering rather than
  /// assuming: the method's whole job is that one class of row goes and another
  /// class stays, and the two live in the same table.
  group('onboarding choices', () {
    test('a cold install has answered nothing', () async {
      expect(await store.onboardingChoices(), const OnboardingChoices.none());
    });

    test('round-trips all three flags', () async {
      const choices = OnboardingChoices(
        wantsToBeWatched: true,
        wantsToWatch: false,
        completed: true,
      );
      await store.setOnboardingChoices(choices);
      expect(await store.onboardingChoices(), choices);
    });

    test('round-trips the both-skipped state as completed', () async {
      const skipped = OnboardingChoices(
        wantsToBeWatched: false,
        wantsToWatch: false,
        completed: true,
      );
      await store.setOnboardingChoices(skipped);
      final read = await store.onboardingChoices();
      expect(read.completed, isTrue,
          reason: 'a skip is an answer — losing it re-asks every launch');
      expect(read.wantsToBeWatched, isFalse);
      expect(read.wantsToWatch, isFalse);
    });

    test('a later write replaces the earlier one in both directions', () async {
      await store.setOnboardingChoices(const OnboardingChoices(
        wantsToBeWatched: true,
        wantsToWatch: true,
        completed: true,
      ));
      await store.setOnboardingChoices(const OnboardingChoices.none());
      expect(await store.onboardingChoices(), const OnboardingChoices.none());
    });
  });

  group('signing out', () {
    test('takes the uid, the answers and the per-link cache', () async {
      await store.setSelfUid('mum');
      // The name says "per-link cache" and the assertions only reached `links`.
      // `clearSelfUid`'s own docstring says why the rest matters: *"Leaving them
      // would let the next account inherit standing warnings about a person it
      // has never heard of — and, worse, inherit the alarms."* Dropping
      // `warnings_shown` from that list left the suite green.
      await store.setOnboardingChoices(const OnboardingChoices(
        wantsToBeWatched: true,
        wantsToWatch: true,
        completed: true,
      ));
      await store.upsertLink(linkTo('ana'));
      await store.saveWatcherCache(
        'mum_ana',
        WatcherCache(
          lastConfirmedDay: day('2026-08-25'),
          warningsShownFor: {day('2026-08-25'): WarningOutcome.warnOnline},
        ),
      );

      await store.clearSelfUid();

      expect(await store.selfUid(), isNull);
      expect(
        await store.onboardingChoices(),
        const OnboardingChoices.none(),
        reason: 'the next account would otherwise be routed by this one\'s '
            'answers, and HomeRoute unions rather than overrides',
      );
      expect(await store.allLinks(), isEmpty);
      expect(
        (await store.watcherCache('mum_ana')).warningsShownFor,
        isEmpty,
        reason: 'the next account would inherit a standing warning about '
            'somebody it has never heard of',
      );
    });

    test('KEEPS the device facts, which belong to the phone', () async {
      await store.setSelfUid('mum');
      await store.setDeviceTimezone('Europe/Madrid');
      await store.setUses24HourClock(false);

      await store.clearSelfUid();

      expect(
        await store.deviceTimezone(),
        'Europe/Madrid',
        reason: 'dropping it puts the next session on ADR-0002\'s UTC fallback',
      );
      expect(await store.uses24HourClock(), isFalse);
    });
  });
}
