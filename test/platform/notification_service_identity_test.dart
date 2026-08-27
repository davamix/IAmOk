import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_ids.dart';
import 'package:i_am_ok/platform/notification_service.dart';

import '../support/zones.dart';

/// **A correction replaces its warning — asserted against the real code.**
///
/// ## Why this file exists
///
/// `docs/testing/strategy.md` calls the correction path *the highest-value test
/// in the suite*, and it was already covered twice: once in the domain, once at
/// the service. Neither could fail.
///
/// The service test asserts the correction lands on the warning's id by watching
/// a fake `WatcherNotifications` that builds its own key —
/// `'correct:$linkId:$day'` — from the arguments it was handed. That string is
/// manufactured by the test double, so it matches the warning's key by
/// construction. Change `NotificationService.showCorrection` to post at
/// `AlarmIds.accessLost(linkId)`, or at `id + 1`, or at a constant, and every
/// one of those tests stays green while a family sees *"No check-in from Mum
/// yesterday"* with *"Correction: Mum did check in yesterday"* stacked
/// underneath it — the exact outcome `screens.md` forbids, and the reason the
/// two calls share one id derivation in the first place.
///
/// So this file watches the **method channel**. The ids asserted below are the
/// integers that reach the platform, produced by production code, and no test
/// double stands between the two calls.
///
/// ## What it deliberately does not cover
///
/// Whether Android honours a repost at the same id as a *replacement*. That is
/// platform behaviour and belongs on the device matrix; it is already recorded
/// as observed on the POCO F3. What is testable here is that the app asks it to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TimeZones.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  final d = day('2026-08-16');
  final madrid = TimeZones.location('Europe/Madrid');
  const mum = 'mum_ana';
  const granddad = 'granddad_ana';

  late List<MethodCall> calls;
  late NotificationService notifications;

  /// Every `show` the platform was asked for, as (method, id).
  List<({String method, int id})> posted() => [
        for (final call in calls)
          (
            method: call.method,
            id: call.method == 'cancel'
                // `cancel` sends a map on Android, a bare int elsewhere.
                ? (call.arguments is Map
                    ? (call.arguments as Map)['id'] as int
                    : call.arguments as int)
                : (call.arguments as Map)['id'] as int,
          ),
      ];

  setUp(() {
    // Registers the Android implementation as the platform instance, which is
    // what `resolvePlatformSpecificImplementation` inside the plugin looks for.
    // `defaultTargetPlatform` is already android under flutter_test.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    notifications = NotificationService(FlutterLocalNotificationsPlugin());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> warn(String linkId, DayKey day) => notifications.showWarning(
        linkId: linkId,
        day: day,
        body: 'No check-in from Mum yesterday.',
      );

  Future<void> correct(String linkId, DayKey day) =>
      notifications.showCorrection(
        linkId: linkId,
        day: day,
        body: 'Correction: Mum did check in yesterday.',
      );

  group('the correction replaces, and does not stack', () {
    test('it posts at the id the warning used', () async {
      await warn(mum, d);
      await correct(mum, d);

      expect(posted(), hasLength(2));
      expect(posted()[0].method, 'show');
      expect(posted()[1].method, 'show');
      expect(posted()[1].id, posted()[0].id,
          reason: 'one id, so Android replaces rather than stacks — the family '
              'sees one corrected message, not a contradiction');
    });

    test('and that id is hash(link, day), not something else', () async {
      // Pinned against the derivation rather than merely against itself, so a
      // change that keeps the two calls consistent but moves them both — onto
      // the access-lost id, say — is still caught.
      await correct(mum, d);
      expect(posted().single.id, AlarmIds.warning(mum, d));
    });

    test('a withdrawal cancels the same id', () async {
      // §10 step 2: revocation takes the warning down with no replacement
      // message. Cancelling a different id would leave the false claim standing
      // forever — every later read on a revoked link is refused, so no
      // correction could ever clear it.
      await warn(mum, d);
      await notifications.cancelWarning(mum, d);

      expect(posted()[1].method, 'cancel');
      expect(posted()[1].id, posted()[0].id);
    });
  });

  group('identity across links — the worst failure this path has', () {
    test('correcting Mum does not touch Granddad\'s standing warning',
        () async {
      // `docs/testing/strategy.md`'s mandatory case, at the level where the
      // integer is actually decided. Both missed the same day, both warnings
      // stand, only Mum checks in late. If the id dropped `linkId`, Granddad's
      // **true** warning would be silently replaced by "Mum did check in
      // yesterday" — the app retracting a true warning about someone whose day
      // was never in question.
      await warn(mum, d);
      await warn(granddad, d);
      await correct(mum, d);

      expect(posted()[2].id, posted()[0].id, reason: 'replaces Mum\'s');
      expect(posted()[2].id, isNot(posted()[1].id),
          reason: 'and leaves Granddad\'s alone');
    });

    test('correcting one day does not touch another day', () async {
      await warn(mum, d);
      await warn(mum, d.next);
      await correct(mum, d);

      expect(posted()[2].id, posted()[0].id);
      expect(posted()[2].id, isNot(posted()[1].id));
    });
  });

  group('the access-lost notice is a separate identity', () {
    test('it does not collide with a warning about the same link', () async {
      await warn(mum, d);
      await notifications.showAccessLost(linkId: mum, body: 'Can\'t check.');

      expect(posted()[1].id, isNot(posted()[0].id),
          reason: 'ADR-0004 keeps the two messages apart; one id would rejoin '
              'them and have each silently replace the other');
    });

    test('and its cancel clears it, not the warning', () async {
      await warn(mum, d);
      await notifications.showAccessLost(linkId: mum, body: 'Can\'t check.');
      await notifications.cancelAccessLost(mum);

      expect(posted()[2].method, 'cancel');
      expect(posted()[2].id, posted()[1].id);
      expect(posted()[2].id, isNot(posted()[0].id));
    });
  });

  group('the message goes to the channel it belongs on', () {
    String channelOf(MethodCall call) => ((call.arguments
        as Map)['platformSpecifics'] as Map)['channelId'] as String;

    test('a warning is on Missed check-ins', () async {
      await warn(mum, d);
      expect(channelOf(calls.single),
          NotificationService.warningsChannel.id);
    });

    test('a correction is on the same channel as the warning it replaces',
        () async {
      // It has to be: Android replaces by (channel-independent) id, but a
      // correction arriving on a channel the reader muted would leave the
      // warning standing and unanswered.
      await correct(mum, d);
      expect(channelOf(calls.single),
          NotificationService.warningsChannel.id);
    });

    test('the access-lost notice is on App problems', () async {
      // The structural half of ADR-0004. A watcher who mutes app faults must
      // still hear about a missed day, and this is the line that makes that
      // true — a regression here is invisible until someone mutes a channel.
      await notifications.showAccessLost(linkId: mum, body: 'Can\'t check.');
      expect(channelOf(calls.single), NotificationService.accessChannel.id);
    });
  });

  test('the payload carries the link, so a tap can open that row', () async {
    await warn(mum, d);
    expect((calls.single.arguments as Map)['payload'], mum);
  });

  /// **The 21:00 body, asserted where it is actually chosen.**
  ///
  /// This is the same gap as the one at the top of this file, in the phase that
  /// added it. `hasAudience` is a three-link chain — the reconcile computes it,
  /// the scheduler carries it, `NotificationCopy.reminderBody` spends it — and
  /// the first two links were tested while the third, the only one that produces
  /// a sentence a person reads, was not.
  ///
  /// `AlarmScheduler`'s two test doubles both *replace* `scheduleReminder`, so
  /// they can prove the flag was passed and never that it selects a body. Change
  /// `notification_service.dart`'s call to `hasAudience: true` and the whole
  /// suite stayed green, with the 21:00 nudge promising a family to a phone
  /// whose own screen says nobody is set up — the exact defect the variant was
  /// written to remove, restored invisibly.
  ///
  /// So this watches the method channel, like everything else in this file: the
  /// string asserted below is the one that reaches the platform, produced by
  /// production code, with no double in between.
  group('the 21:00 reminder promises a family only when there is one', () {
    // **A future day, because the plugin refuses to schedule into the past** —
    // `validateDateIsInTheFuture` throws before the method channel is reached,
    // so `d` (the 2026 fixture the rest of this file uses) never gets far enough
    // to produce a body. Far enough out that the suite does not develop a
    // shelf life.
    final future = day('2099-08-16');

    ScheduledReminder nightOf(DayKey on) => ScheduledReminder(
          day: on,
          slot: ReminderSlot.night,
          at: on.at(ReminderSlot.night.time, madrid),
        );

    String bodyOf(MethodCall call) =>
        (call.arguments as Map)['body'] as String;

    test('with an audience it names the consequence', () async {
      await notifications.scheduleReminder(nightOf(future), hasAudience: true);
      expect(
        bodyOf(calls.single),
        "Please tap I'm OK before the day ends, so your family knows "
        "you're well.",
      );
    });

    test('with nobody set up it says only the instruction', () async {
      await notifications.scheduleReminder(nightOf(future), hasAudience: false);
      expect(bodyOf(calls.single),
          "Please tap I'm OK before the day ends.");
      expect(bodyOf(calls.single).toLowerCase(), isNot(contains('family')),
          reason: 'the screen behind this may read "No one is set up to know '
              'you are OK"');
    });

    test('the other two slots do not vary, in either direction', () async {
      for (final slot in [ReminderSlot.midday, ReminderSlot.evening]) {
        final reminder = ScheduledReminder(
          day: future,
          slot: slot,
          at: future.at(slot.time, madrid),
        );
        calls = [];
        await notifications.scheduleReminder(reminder, hasAudience: true);
        final withFamily = bodyOf(calls.single);
        calls = [];
        await notifications.scheduleReminder(reminder, hasAudience: false);
        expect(bodyOf(calls.single), withFamily, reason: slot.name);
      }
    });
  });
}
