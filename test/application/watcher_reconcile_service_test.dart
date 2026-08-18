@TestOn('vm')
library;

import 'package:i_am_ok/application/watcher_reconcile_service.dart';
import 'package:i_am_ok/data/check_in_reader.dart';
import 'package:i_am_ok/data/local_store.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/clock.dart';
import 'package:i_am_ok/platform/notification_service.dart';
import 'package:i_am_ok/platform/warning_alarm_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// **Phase 3's exit criteria, as tests.**
///
/// PLAN.md: *a warning fires when it should; is suppressed when a check-in is
/// cached; is suppressed when away covers the day; is replaced by a correction
/// when a late check-in arrives; and says something different and honest when
/// the device cannot reach the network.*
///
/// The decision itself is already tested exhaustively in the domain suite. What
/// is left — and what nothing else covers — is the **composition**: that the
/// read is attempted before the cache is consulted, that the right message goes
/// to the right channel, that a correction lands on the id it is meant to
/// replace, and that the cache written afterwards is the one the reconciler
/// returned.
///
/// Every assertion here is on **which** message, never merely that something
/// fired. §10 rates a false claim to a family as the worst bug this app can
/// have, so "a notification appeared" is not evidence of anything.
class _RecordingNotifications implements WatcherNotifications {
  final List<String> calls = [];
  final Map<String, String> bodies = {};

  String _key(String kind, String linkId, [DayKey? day]) =>
      day == null ? '$kind:$linkId' : '$kind:$linkId:$day';

  @override
  Future<void> showWarning({
    required String linkId,
    required DayKey day,
    required String body,
  }) async {
    calls.add(_key('warn', linkId, day));
    bodies[_key('warn', linkId, day)] = body;
  }

  @override
  Future<void> showCorrection({
    required String linkId,
    required DayKey day,
    required String body,
  }) async {
    calls.add(_key('correct', linkId, day));
    bodies[_key('correct', linkId, day)] = body;
  }

  @override
  Future<void> cancelWarning(String linkId, DayKey day) async =>
      calls.add(_key('cancelWarn', linkId, day));

  @override
  Future<void> showAccessLost({
    required String linkId,
    required String body,
  }) async {
    calls.add(_key('access', linkId));
    bodies[_key('access', linkId)] = body;
  }

  @override
  Future<void> cancelAccessLost(String linkId) async =>
      calls.add(_key('cancelAccess', linkId));

  /// **This reconcile touched the shade not at all.**
  ///
  /// The predecessor was `postedNothing`, which tested only for calls beginning
  /// `warn` or `access`. Two whole kinds slipped past it: a spurious
  /// **correction** — *"Correction: Mum did check in yesterday"*, a claim about
  /// a person — satisfied all seven of the silent-case assertions below, and so
  /// did a spurious **cancel**, which takes a true warning down and tells the
  /// family nothing about why it vanished.
  ///
  /// Every case that asserts silence here starts from an empty tray, so the
  /// honest assertion is that nothing happened at all rather than that one
  /// category of thing did not. Silence is this side's most dangerous state —
  /// it is the failure the app cannot detect in itself — so the test for it is
  /// the strict one.
  bool get silent => calls.isEmpty;
}

class _RecordingAlarms implements WarningAlarmScheduler {
  final Map<String, Set<ScheduledWarning>> armed = {};
  final List<String> calls = [];

  /// What the platform says about exact alarms. False models API 31-32 with
  /// *Alarms & reminders* revoked, where the plugin arms NOTHING and still
  /// reports success.
  bool exact = true;

  @override
  Future<bool> apply({
    required String linkId,
    required Set<ScheduledWarning> toCancel,
    required Set<ScheduledWarning> desired,
  }) async {
    for (final w in toCancel) {
      calls.add('cancel ${w.day}');
      armed[linkId]?.remove(w);
    }
    for (final w in desired) {
      calls.add('arm ${w.day}');
      (armed[linkId] ??= {}).add(w);
    }
    return exact;
  }

  @override
  Future<void> cancelAll({
    required String linkId,
    required Set<ScheduledWarning> armed,
  }) async =>
      this.armed.remove(linkId);
}

class _StubReader implements CheckInReader {
  _StubReader(this.result);

  /// What the backend answers for every link without an override.
  FirestoreRead result;

  /// Per-link answers. Needed because the interesting multi-link case is
  /// precisely the one where the backend says **different things** about two
  /// watched people — one checked in late, the other genuinely did not — and a
  /// stub that answered identically for both could not express it.
  final Map<String, FirestoreRead> perLink = {};

  /// Throws instead of answering.
  ///
  /// Not a `FirestoreRead` value — those are the *expected* failures, and the
  /// whole of ADR-0004 is that they are answers rather than exceptions. This is
  /// the unexpected kind: a plugin fault, a corrupt row, a bug. It exists to
  /// prove the reconcile lease is released on the way out.
  bool throwOnRead = false;

  /// Throws for **one** link, leaving the rest answerable — which is the only
  /// arrangement that can tell per-link isolation from an abort.
  String? throwOnLink;

  @override
  Future<FirestoreRead> read(Link link) async {
    if (throwOnRead || link.id == throwOnLink) {
      throw StateError('the backend blew up');
    }
    return perLink[link.id] ?? result;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late _RecordingNotifications notifications;
  late _RecordingAlarms alarms;
  late _StubReader reader;
  late FixedClock clock;
  var canDeliver =
      const WatcherDelivery.uniform(NotificationDelivery.available);

  const selfUid = 'ana';
  const mumLink = 'mum_ana';

  // 10:00 Madrid on the 17th. D — the last COMPLETED day in the watched
  // person's zone — is therefore the 16th, which is what every assertion below
  // is about.
  final today = day('2026-08-17');
  final d = day('2026-08-16');

  WatcherReconcileService service() => WatcherReconcileService(
        store: store,
        clock: clock,
        reader: reader,
        notifications: notifications,
        alarms: alarms,
        delivery: () async => canDeliver,
      );

  Future<void> seedLink({
    LinkStatus status = LinkStatus.accepted,
    String activeFrom = '2026-08-01',
  }) =>
      store.upsertLink(Link(
        watchedUid: 'mum',
        watcherUid: selfUid,
        status: status,
        watchedName: 'Mum',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day(activeFrom),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      ));

  setUp(() async {
    store = await LocalStore.open(path: inMemoryDatabasePath);
    notifications = _RecordingNotifications();
    alarms = _RecordingAlarms();
    reader = _StubReader(const FirestoreRead.succeeded());
    clock = FixedClock(at(madrid, 2026, 8, 17, 10));
    canDeliver = const WatcherDelivery.uniform(NotificationDelivery.available);
    await store.setDeviceTimezone('Europe/Madrid');
    await seedLink();
  });

  tearDown(() => store.close());

  group('a warning fires when it should', () {
    test('verified, and no check-in — the plain message', () async {
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('warn:$mumLink:$d'));
      expect(notifications.bodies['warn:$mumLink:$d'],
          'No check-in from Mum yesterday.');
    });

    test('it is recorded as standing, so it does not fire twice', () async {
      await service().reconcile(selfUid: selfUid);
      notifications.calls.clear();

      // Every entry point calls reconcile — app open, boot, FCM, alarm. A
      // warning that re-fires on each is this project's own "boot recovery is a
      // duplicate-notification bug".
      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue,
          reason: 'idempotent means nothing at all — not merely no second '
              'warning. A cancel here would take the FIRST one down, and the '
              'family would be told and then quietly untold.');
      expect((await store.watcherCache(mumLink)).warningsShownFor[d],
          WarningOutcome.warnOnline);
    });

    test('redundant consumes the day WITHOUT posting — the sharp edge',
        () async {
      // This is correct behaviour and it is also the most dangerous value in
      // the enum, because it is the only one that marks a day served while
      // saying nothing. Its whole justification is *the reader is looking at
      // the screen that already shows this* — so a caller that passes it while
      // the reader is looking at something else silently loses the warning.
      //
      // That happened. The app-open reconcile, added so a force-stopped watcher
      // repairs itself, ran as `redundant` while the user sat on the Tap
      // screen: `warningsShownFor` recorded `warnOnline` for the day and zero
      // notifications were posted. Measured on the POCO F3.
      //
      // The flag is a required named parameter on `AppServices.watcherReconcile`
      // so the question cannot be skipped, and only the list itself may answer
      // yes. This pins what the answer costs when it is wrong.
      canDeliver = const WatcherDelivery.uniform(NotificationDelivery.redundant);
      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
      expect((await store.watcherCache(mumLink)).warningsShownFor[d],
          WarningOutcome.warnOnline,
          reason: 'consumed. A second reconcile will now say nothing, which is '
              'right only if something really did show it to the reader');
    });

    test('nothing is recorded when the platform cannot post', () async {
      // The whole point of NotificationDelivery: a muted phone must not consume
      // a warning it never delivered, or the day is settled in silence.
      canDeliver = const WatcherDelivery.uniform(NotificationDelivery.unavailable);
      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
      expect((await store.watcherCache(mumLink)).warningsShownFor, isEmpty,
          reason: 'nothing reached anyone, so the warning is still owed');
    });
  });

  group('suppressed when a check-in is cached', () {
    test('a check-in for D settles the day', () async {
      reader.result = FirestoreRead.succeeded(checkInDays: {d});

      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
      expect((await store.watcherCache(mumLink)).lastConfirmedDay, d);
    });

    test('a check-in AFTER D also settles it — state, not history', () async {
      // §10 step 4 is `lastConfirmedDay >= D`, not `== D`, and the asymmetry
      // with corrections below is deliberate rather than an oversight.
      //
      // Suppression asks "has she been seen since?" — if the newest check-in we
      // know of is later than D, the question about D is moot and warning about
      // it would raise a resolved past. That is the UI guidelines' *state, not
      // history* rule reaching the notification.
      //
      // A **correction** is the opposite and needs the exact day, because it
      // makes a positive claim: retracting Monday's warning because she tapped
      // on Tuesday would say "Mum did check in yesterday" about a day she did
      // not. One rule decides whether to stay quiet, the other decides whether
      // to assert something.
      reader.result = FirestoreRead.succeeded(checkInDays: {today});

      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
      expect((await store.watcherCache(mumLink)).lastConfirmedDay, today);
    });
  });

  group('suppressed when away covers the day', () {
    test('a freshly-read away period silences it', () async {
      reader.result = FirestoreRead.succeeded(
        away: AwayPeriod(from: day('2026-08-14'), through: day('2026-08-20')),
      );

      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
    });

    test('a cached away that cannot be re-verified speaks, honestly', () async {
      // ADR-0001: offline, the device cannot tell "the away was cancelled and I
      // did not hear" from "the away is still on and I have not checked". It
      // prefers speaking, and says both of the things it actually knows.
      reader.result = FirestoreRead.succeeded(
        away: AwayPeriod(from: day('2026-08-14'), through: day('2026-08-20')),
      );
      await service().reconcile(selfUid: selfUid);

      clock = FixedClock(at(madrid, 2026, 8, 21, 10));
      reader.result = const FirestoreRead.unreachable();
      notifications.calls.clear();
      await service().reconcile(selfUid: selfUid);

      final body = notifications.bodies.values.single;
      expect(body, startsWith('Can\'t check on Mum —'),
          reason: 'a claim about US, not about her');
      expect(body, contains('Mum was marked away until'));
      expect(body, isNot(contains('She was marked')),
          reason: 'settled at the Phase 3 gate: the name, never a pronoun');
    });
  });

  group('replaced by a correction when a late check-in arrives', () {
    test('the correction posts at the WARNING id, so it replaces', () async {
      await service().reconcile(selfUid: selfUid);
      expect(notifications.calls, contains('warn:$mumLink:$d'));

      // The late check-in arrives — offline sync, or a deferred push.
      reader.result = FirestoreRead.succeeded(checkInDays: {d});
      notifications.calls.clear();
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, ['correct:$mumLink:$d'],
          reason: 'same link, same day — so the same notification id, so the '
              'false warning is replaced rather than left above the truth');
      expect(notifications.bodies['correct:$mumLink:$d'],
          'Correction: Mum did check in yesterday.');
      // **No time, and that is the assertion.** The approved string ends
      // *"at 23:40"* and that clause is a claim about the moment SHE tapped.
      // Phase 3's read carries no per-check-in timestamp, so the only instant
      // available was `now` — when this device happened to read it, which on a
      // phone that slept until morning is hours out and sometimes the wrong
      // day. Stamping that as her tap time invents a fact about a person, on
      // the one message whose purpose is to withdraw an untrue one. Phase 4
      // carries `deviceTappedAt` through and the clause returns with a real
      // value behind it.
      expect(notifications.bodies['correct:$mumLink:$d'],
          isNot(matches(RegExp(r'\d{1,2}:\d{2}'))),
          reason: 'no clock time may appear until it is HER time');
    });

    test('when the warning could not be posted, it is CANCELLED not corrected',
        () async {
      // `redundant` consumed the day without posting anything — the watcher was
      // reading the list, which is the whole meaning of the state. So there is
      // nothing in the tray, and a replacement message arrives alone: at 3am,
      // *"Correction: Mum did check in yesterday"* with no warning above it
      // reads as a warning the reader somehow slept through.
      canDeliver = const WatcherDelivery.uniform(NotificationDelivery.redundant);
      await service().reconcile(selfUid: selfUid);
      expect((await store.watcherCache(mumLink)).warningsShownFor[d],
          WarningOutcome.warnOnline,
          reason: 'consumed without posting — the sharp edge of `redundant`');
      expect(notifications.calls, isEmpty);

      reader.result = FirestoreRead.succeeded(checkInDays: {d});
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, ['cancelWarn:$mumLink:$d'],
          reason: 'the retraction still happens — it just says nothing');
      expect(notifications.calls, isNot(contains('correct:$mumLink:$d')));
    });

    test('a muted warning channel still takes the stale warning down',
        () async {
      // The other order: the warning WAS posted, and the channel was muted
      // afterwards. Cancelling needs no permission, so the false claim about
      // Mum comes out of the tray — on the phone least likely ever to be
      // opened, which is exactly the one that would otherwise keep it forever.
      await service().reconcile(selfUid: selfUid);
      expect(notifications.calls, contains('warn:$mumLink:$d'));

      canDeliver =
          const WatcherDelivery.uniform(NotificationDelivery.unavailable);
      reader.result = FirestoreRead.succeeded(checkInDays: {d});
      notifications.calls.clear();
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, ['cancelWarn:$mumLink:$d']);
      expect((await store.watcherCache(mumLink)).warningsShownFor, isEmpty,
          reason: 'she checked in — the day is no longer warned either way');
    });

    test('the day leaves warningsShownFor and is confirmed', () async {
      await service().reconcile(selfUid: selfUid);
      reader.result = FirestoreRead.succeeded(checkInDays: {d});
      await service().reconcile(selfUid: selfUid);

      final cache = await store.watcherCache(mumLink);
      expect(cache.warningsShownFor, isEmpty);
      expect(cache.lastConfirmedDay, d);
    });

    test('correcting one link leaves another link\'s warning standing',
        () async {
      // `docs/testing/strategy.md`'s mandatory case. Both watched people missed
      // the same day; only one of them checks in late. Retracting a TRUE warning
      // about the other is the worst class of bug this project names.
      await store.upsertLink(Link(
        watchedUid: 'granddad',
        watcherUid: selfUid,
        status: LinkStatus.accepted,
        watchedName: 'Granddad',
        watcherName: 'Ana',
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-08-01'),
        warningLocalTime: const LocalTimeOfDay(10, 0),
        createdAt: DateTime.utc(2026, 8, 1),
      ));
      await service().reconcile(selfUid: selfUid);
      expect(notifications.calls, contains('warn:granddad_ana:$d'));

      // Only Mum's check-in arrives. Granddad's backend still says nothing —
      // his warning is TRUE, and must survive.
      reader.perLink[mumLink] = FirestoreRead.succeeded(checkInDays: {d});
      notifications.calls.clear();
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('correct:$mumLink:$d'));
      expect((await store.watcherCache('granddad_ana')).warningsShownFor[d],
          WarningOutcome.warnOnline,
          reason: 'Granddad\'s warning was true and is still standing');
    });
  });

  group('a different and honest message when the network is unreachable', () {
    test('offline says so, and never claims she did not check in', () async {
      reader.result = const FirestoreRead.unreachable();

      await service().reconcile(selfUid: selfUid);

      final body = notifications.bodies['warn:$mumLink:$d'];
      expect(body, startsWith('No check-in received from Mum yesterday —'));
      expect(body, contains('your phone has not been able to check even once.'),
          reason: 'never reconciled: there is no "offline since" to render, and '
              '"offline since null" is the failure the variant exists for');
    });

    test('offline after a successful read names when', () async {
      await service().reconcile(selfUid: selfUid);

      clock = FixedClock(at(madrid, 2026, 8, 18, 10));
      reader.result = const FirestoreRead.unreachable();
      notifications.calls.clear();
      await service().reconcile(selfUid: selfUid);

      expect(notifications.bodies['warn:$mumLink:${day('2026-08-17')}'],
          contains('your phone has been offline since Monday 10:00.'));
    });

    test('REFUSED is not offline — different words, different channel',
        () async {
      // ADR-0004. The server was reached and said no, so the phone is online and
      // working: the offline wording would be false about the device, and the
      // plain wording false about her.
      reader.result = const FirestoreRead.refused(RefusedCause.unauthenticated);

      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, ['access:$mumLink'],
          reason: 'the App problems channel, so a watcher who mutes app faults '
              'still hears about a real missed day');
      final body = notifications.bodies['access:$mumLink']!;
      expect(body, startsWith('Can\'t check on Mum —'));
      expect(body, contains('Open the app to see what to do.'));
      expect(body, isNot(contains('offline')));
      expect(body, isNot(contains('her check-ins')),
          reason: 'settled at the Phase 3 gate');
    });

    test('a refusal is recorded apart from warnings about her', () async {
      reader.result = const FirestoreRead.refused();
      await service().reconcile(selfUid: selfUid);

      final cache = await store.watcherCache(mumLink);
      expect(cache.hasLostAccess, isTrue);
      expect(cache.warningsShownFor, isEmpty,
          reason: 'ADR-0004: recording it as a warning would make the list row '
              'report a missed check-in nothing supports');
    });

    test('a CHANGED cause re-notifies the same day', () async {
      // ADR-0004 decision 5: a changed cause re-notifies "whatever the cadence
      // says", because "Sign in again." and "Update I Am Ok in the Play Store."
      // are different instructions and the standing notice becomes the WRONG
      // ONE the moment the fault moves. This message exists at all because it
      // is supposed to be actionable.
      //
      // The within-day dedupe used to be checked first and swallowed exactly
      // this case — a watcher told at 09:00 to sign in kept that instruction
      // until the next day even after the fault became an App Check rejection.
      // Found on the POCO F3 while testing the cold-start tap: the cause moved
      // in the store and nothing was posted.
      reader.result = const FirestoreRead.refused(RefusedCause.unauthenticated);
      await service().reconcile(selfUid: selfUid);
      expect(notifications.bodies['access:$mumLink'], isNotNull);
      notifications.calls.clear();

      reader.result = const FirestoreRead.refused(RefusedCause.appCheckRejected);
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('access:$mumLink'),
          reason: 'the remediation changed, so the standing notice is now the '
              'wrong instruction and must be replaced today, not tomorrow');
    });

    test('an UNCHANGED cause does not re-notify the same day', () async {
      // The dedupe still does its job: reconcile runs on app open, FCM, alarm
      // and boot, so a day-granular cadence without this fires several times.
      reader.result = const FirestoreRead.refused(RefusedCause.unauthenticated);
      await service().reconcile(selfUid: selfUid);
      notifications.calls.clear();

      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
    });

    test('access returning cancels the standing notice', () async {
      reader.result = const FirestoreRead.refused();
      await service().reconcile(selfUid: selfUid);
      notifications.calls.clear();

      reader.result = FirestoreRead.succeeded(checkInDays: {d});
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('cancelAccess:$mumLink'),
          reason: 'there is no "access restored" message, but not notifying and '
              'not cancelling are different decisions — otherwise the tray goes '
              'on telling a watcher to fix something already fixed');
    });
  });

  group('revocation withdraws rather than corrects', () {
    test('a standing warning is cancelled with no replacement message',
        () async {
      await service().reconcile(selfUid: selfUid);
      notifications.calls.clear();

      await seedLink(status: LinkStatus.revoked);
      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('cancelWarn:$mumLink:$d'));
      expect(notifications.calls.any((c) => c.startsWith('correct')), isFalse,
          reason: 'nothing disproves the warning — "Mum did check in yesterday" '
              'is a claim the device cannot support');
    });

    test('the alarm window is torn down', () async {
      await service().reconcile(selfUid: selfUid);
      expect(alarms.armed[mumLink], isNotEmpty);

      await seedLink(status: LinkStatus.revoked);
      await service().reconcile(selfUid: selfUid);

      expect(alarms.armed[mumLink] ?? const {}, isEmpty,
          reason: '§10 step 2: revocation is final, so the alarm is torn down '
              'rather than left armed and mute');
    });
  });

  group('the alarm window', () {
    test('is armed at the watcher\'s chosen local time', () async {
      // 09:00, so today's own 10:00 alarm is still ahead and the full window
      // depth is visible. At exactly 10:00 it is six, because an instant that
      // has arrived is not scheduled into the past — asserted below.
      clock = FixedClock(at(madrid, 2026, 8, 17, 9));
      await service().reconcile(selfUid: selfUid);

      final armed = alarms.armed[mumLink]!;
      expect(armed, hasLength(WatcherReconciler.windowDays));
      for (final warning in armed) {
        expect(warning.at.hour, 10);
        expect(warning.at.location.name, 'Europe/Madrid',
            reason: 'the WATCHER\'s zone — a watcher abroad is never woken at '
                '03:00 by a question about a watched-local day');
      }
    });

    test('today\'s alarm is not armed once its instant has passed', () async {
      // The setUp clock is exactly 10:00, the warning time. Scheduling into the
      // past is at best a no-op and at worst an immediate spurious fire — and
      // on this side a spurious fire is a false claim to a family.
      await service().reconcile(selfUid: selfUid);

      final days = alarms.armed[mumLink]!.map((w) => w.day).toSet();
      expect(days, isNot(contains(today)));
      expect(days, hasLength(WatcherReconciler.windowDays - 1));
    });

    test('and the store agrees with what was armed', () async {
      await service().reconcile(selfUid: selfUid);

      expect(await store.pendingWarnings(mumLink), alarms.armed[mumLink],
          reason: 'the divergence between these two is what stranded an alarm '
              'on the POCO — see ADR-0006');
    });

    test('a second reconcile cancels nothing, and changes nothing', () async {
      // **The old name was "arms nothing new", which is false by design.** The
      // service passes the whole desired set on every run — that IS the
      // force-stop repair, asserted below — so the second reconcile re-arms all
      // six, deliberately. Only the cancel half is idempotent in the
      // no-platform-calls sense, and a name promising otherwise contradicts the
      // repair test forty lines down.
      await service().reconcile(selfUid: selfUid);
      final before = Set.of(alarms.armed[mumLink]!);
      alarms.calls.clear();

      await service().reconcile(selfUid: selfUid);

      expect(alarms.calls.where((c) => c.startsWith('cancel')), isEmpty,
          reason: 'nothing is cancelled on an unchanged window — a cancel here '
              'would disarm a warning the app still wants');
      expect(alarms.armed[mumLink], before,
          reason: 'and the window that ends up armed is the same one, which is '
              'the idempotence that actually matters');
    });

    test('an INEXACT arming is recorded, not discarded', () async {
      // §13 calls the exact-alarm fallback acceptable *and surfaced*. Only the
      // first half was built: `apply` reported it and the return value went
      // nowhere, so nothing anywhere distinguished a window that fires at 10:00
      // from one Android may defer by an hour or more — on a dead man's switch,
      // where an hour is an hour nobody is told.
      alarms.exact = false;
      await service().reconcile(selfUid: selfUid);

      expect(await store.warningAlarmsExact(), isFalse);
    });

    test('an exact arming records that too', () async {
      await service().reconcile(selfUid: selfUid);
      expect(await store.warningAlarmsExact(), isTrue);
    });

    test('nothing armed makes no claim either way', () async {
      // A revoked link arms nothing, so it has no opinion about exactness and
      // must not overwrite the answer a real window gave. Otherwise revoking
      // one person would report the whole app healthy.
      alarms.exact = false;
      await service().reconcile(selfUid: selfUid);
      expect(await store.warningAlarmsExact(), isFalse);

      await seedLink(status: LinkStatus.revoked);
      alarms.exact = true;
      await service().reconcile(selfUid: selfUid);

      expect(await store.warningAlarmsExact(), isFalse,
          reason: 'an empty desired set arms nothing and claims nothing');
    });
  });

  group('one link failing does not cost the others their check', () {
    /// A second watched person, so "the rest of the loop" is a real thing.
    Future<void> seedGranddad() => store.upsertLink(Link(
          watchedUid: 'granddad',
          watcherUid: selfUid,
          status: LinkStatus.accepted,
          watchedName: 'Granddad',
          watcherName: 'Ana',
          watchedTimezone: 'Europe/Madrid',
          activeFrom: day('2026-08-01'),
          warningLocalTime: const LocalTimeOfDay(10, 0),
          createdAt: DateTime.utc(2026, 8, 1),
        ));

    test('the surviving link is still reconciled and still warned about',
        () async {
      // **Links come back ordered by id**, so `granddad_ana` precedes
      // `mum_ana`. Before the per-link guard, a throw on Granddad aborted the
      // pass and Mum was never checked at all — no warning, no alarm, no
      // symptom. One bad row starves every link after it alphabetically,
      // forever.
      await seedGranddad();
      reader.perLink['granddad_ana'] = const FirestoreRead.succeeded();
      reader.throwOnLink = 'granddad_ana';

      final state = await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('warn:$mumLink:$d'),
          reason: 'Mum is fine and must still be warned about');
      expect(state.people.map((p) => p.link.id), [mumLink],
          reason: 'the failed link is omitted rather than rendered from a '
              'half-built reconcile — a row assembled out of a failure is the '
              'false claim this side exists to avoid');
    });

    test('and the failure is recorded rather than swallowed', () async {
      await seedGranddad();
      reader.throwOnLink = 'granddad_ana';

      await service().reconcile(selfUid: selfUid);

      expect(await store.linkReconcileFailed(), isTrue,
          reason: 'a link the app silently stopped checking is exactly the '
              'failure it cannot detect in itself');
    });

    test('and it clears once every link succeeds again', () async {
      await seedGranddad();
      reader.throwOnLink = 'granddad_ana';
      await service().reconcile(selfUid: selfUid);
      expect(await store.linkReconcileFailed(), isTrue);

      reader.throwOnLink = null;
      await service().reconcile(selfUid: selfUid);

      expect(await store.linkReconcileFailed(), isFalse,
          reason: 'a flag that never clears is a flag nobody trusts');
    });
  });

  group('a link with an unrenderable timezone', () {
    /// A zone name this build's compiled-in tzdata does not carry. Reachable
    /// from a store written by a newer build, a restore, or a zone renamed
    /// upstream between tzdata releases.
    Future<void> seedBadZone() => store.upsertLink(Link(
          watchedUid: 'granddad',
          watcherUid: selfUid,
          status: LinkStatus.accepted,
          watchedName: 'Granddad',
          watcherName: 'Ana',
          watchedTimezone: 'Mars/Olympus_Mons',
          activeFrom: day('2026-08-01'),
          warningLocalTime: const LocalTimeOfDay(10, 0),
          createdAt: DateTime.utc(2026, 8, 1),
        ));

    test('does not take down the reconcile of every OTHER link', () async {
      // **The whole point.** `link.watchedZone` throws `UnknownTimeZone`, and
      // `reconcile()` walks every link in one pass — inside an isolate with no
      // screen, no user and nothing that reports a throw. One bad string would
      // stop every other watched person being checked, and the only symptom is
      // silence: the one failure this side cannot detect in itself.
      await seedBadZone();

      final state = await service().reconcile(selfUid: selfUid);

      expect(state.people, hasLength(2));
      expect(notifications.calls, contains('warn:$mumLink:$d'),
          reason: 'Mum\'s link is fine and must still be reconciled');
    });

    test('falls back to the watcher\'s zone, not UTC', () async {
      // Both are guesses. This one is right in the overwhelmingly common case —
      // a family in one country — while UTC is wrong by up to a day at the far
      // end of the world, which moves D and can warn about a day she has not
      // finished yet.
      //
      // 01:00 Madrid on the 17th is 23:00 UTC on the **16th**, so the two
      // fallbacks disagree about what the last completed day is: Madrid says
      // the 16th, UTC says the 15th. Asserting the alarm's zone instead would
      // prove nothing — the window is always armed in the watcher's zone
      // whatever the link says.
      await seedBadZone();
      clock = FixedClock(at(madrid, 2026, 8, 17, 1));

      await service().reconcile(selfUid: selfUid);

      expect(notifications.calls, contains('warn:granddad_ana:$d'),
          reason: 'D is the 16th — the last completed day in Madrid');
      expect(notifications.calls,
          isNot(contains('warn:granddad_ana:${day('2026-08-15')}')),
          reason: 'the 15th is what a UTC fallback would have warned about');
    });
  });

  group('repairing itself after a force-stop', () {
    test('re-arms the whole window, not the diff', () async {
      // **Measured on the POCO F3, and the reason `apply` takes the desired set
      // rather than the diff.** A force-stop cancels every `AlarmManager` alarm
      // and tells the app nothing. `LocalStore` still says all seven are armed,
      // so a diff computed against it is empty — the app re-arms nothing, and
      // the watcher is permanently deaf with every record insisting it is fine.
      // 21 armed, force-stop, 0 armed, reopen and reconcile, still 0.
      //
      // The watched side has had this test since Phase 2. This side — where
      // silence is the failure that cannot be detected — did not.
      await service().reconcile(selfUid: selfUid);
      final wanted = Set.of(alarms.armed[mumLink]!);
      expect(wanted, isNotEmpty);

      // The force-stop: the platform forgets, the store does not.
      alarms.armed.clear();
      expect(await store.pendingWarnings(mumLink), wanted,
          reason: 'the premise — the app still believes they are armed');

      await service().reconcile(selfUid: selfUid);

      expect(alarms.armed[mumLink], wanted,
          reason: 'every one re-asserted. Arming is idempotent by id, so this '
              'costs a handful of binder calls and is self-healing whatever '
              'the platform actually holds.');
    });

    test('and the repair does not post a second warning', () async {
      // The other half, and they pull against each other: re-arming everything
      // must not also re-say everything. Boot recovery that duplicates the
      // notification is this project's own named failure.
      await service().reconcile(selfUid: selfUid);
      alarms.armed.clear();
      notifications.calls.clear();

      await service().reconcile(selfUid: selfUid);

      expect(notifications.silent, isTrue);
    });
  });

  group('the reconcile lease is released', () {
    test('so the next run can take it', () async {
      await service().reconcile(selfUid: selfUid);

      expect(await store.reconcileLockHolder(WatcherReconcileService.lockScope),
          isNull,
          reason: 'a lease still held after the run would block every '
              'reconcile until it expired — and in the alarm isolate, which is '
              'killed as its normal ending, nothing would ever release it');
    });

    test('even when a link throws', () async {
      // The isolate must not die holding the lease. It is released in a
      // `finally` precisely because there is no screen to report the throw and
      // no second chance until the next alarm fires.
      reader.throwOnRead = true;

      await service().reconcile(selfUid: selfUid);

      expect(await store.reconcileLockHolder(WatcherReconcileService.lockScope),
          isNull);
    });

    test('and a run that could not take it releases nothing', () async {
      // The loser of a race must not free the winner's lease on its way out —
      // that would hand the lock to whoever asked next while the winner was
      // still mid-diff, which is the two-concurrent-reconciles case ADR-0006
      // exists to prevent.
      await store.acquireReconcileLock(
        scope: WatcherReconcileService.lockScope,
        owner: 'someone-else',
        now: clock.now(),
        lease: const Duration(seconds: 30),
      );

      await service().reconcile(selfUid: selfUid);

      expect(
          (await store.reconcileLockHolder(WatcherReconcileService.lockScope))
              ?.owner,
          'someone-else');
    });
  });

  test('the window survives a DST transition at the watcher\'s local time',
      () async {
    // §11: never raw UTC offsets, because the next transition invalidates them.
    // Madrid moves from CEST to CET on 2026-10-25, so a seven-day window opened
    // on the 22nd straddles it — and a window built by adding 24h repeatedly,
    // or by storing an offset, drifts to 09:00 for the days after the change.
    //
    // An hour early on a dead man's switch is an hour of asking about a day
    // that is not finished; an hour late is an hour nobody is told.
    clock = FixedClock(at(madrid, 2026, 10, 22, 9));
    await service().reconcile(selfUid: selfUid);

    final armed = alarms.armed[mumLink]!;
    expect(armed, hasLength(WatcherReconciler.windowDays));
    for (final warning in armed) {
      expect(warning.at.hour, 10, reason: '${warning.day} fires at the wrong '
          'wall-clock hour');
      expect(warning.at.location.name, 'Europe/Madrid');
    }

    // And the premise: the transition really is inside this window, so the run
    // above is not passing on a week that never changed offset.
    final offsets =
        armed.map((w) => w.at.timeZoneOffset.inHours).toSet();
    expect(offsets, {2, 1},
        reason: 'CEST then CET — same wall time, different instants, which is '
            'exactly what a raw offset cannot express');
  });

  test('reading state is never gated by the reconcile lease', () async {
    // ADR-0006's split. The alarm isolate must always reach its warn/don\'t-warn
    // decision — silence is the failure this app cannot detect — so a run that
    // cannot take the lock still reads, still decides and still speaks.
    await store.acquireReconcileLock(
      scope: WatcherReconcileService.lockScope,
      owner: 'someone-else',
      now: clock.now(),
      lease: const Duration(seconds: 30),
    );

    final state = await service().reconcile(selfUid: selfUid);

    expect(notifications.calls, contains('warn:$mumLink:$d'),
        reason: 'it may skip the scheduling, never the speaking');
    expect(alarms.calls, isEmpty, reason: 'but it touched no alarms');
    expect(state.people, hasLength(1));
  });
}
