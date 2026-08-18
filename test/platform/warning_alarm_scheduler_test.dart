import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_ids.dart';
import 'package:i_am_ok/platform/warning_alarm_scheduler.dart';

import '../support/zones.dart';

/// **The watcher's real scheduler, which nothing exercised.**
///
/// `test/application/` asserts the ordering and the exact-alarm degradation
/// through `_RecordingAlarms` — a fake that produces the ordering itself and
/// models the degradation as a bool field. Both would pass unchanged if
/// [AndroidWarningAlarmScheduler.apply] armed before it cancelled, or ignored
/// `_canScheduleExact` entirely. `alarm_scheduler_test.dart` closes exactly that
/// hole on the watched side and says so in its own docstring; this side had
/// nothing.
///
/// It matters more here. A mis-ordered cancel on the watched side is a missing
/// nudge. On this side it is a warning that never fires — no error, no log, no
/// notification, on the half where §10 rates silence as the failure the app
/// cannot detect in itself.
///
/// So this watches the plugin's method channel and asserts on the arguments that
/// actually reach it.
///
/// ## The two things being pinned
///
/// **Cancel before arm.** `ScheduledWarning` equality includes the instant while
/// the platform id is derived from the day alone, so a warning whose time moved
/// — a watcher changing 10:00 to 08:00 — appears in *both* sets under one id.
/// Cancelling second disarms the alarm just armed.
///
/// **`exact:` carries what the platform said.** `AlarmService.scheduleAlarm`
/// checks `canScheduleExactAlarms()` and, when it is false, logs and **arms
/// nothing** — no throw, no fallback — while `oneShotAt` returns `true` anyway
/// and the alarm is persisted for reboot first. Every signal the app can see
/// says it worked. Commit `0c6d9f3` fixed that by asking first and degrading to
/// inexact; until now the fix was asserted only against a fake's bool.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TimeZones.ensureInitialized();

  const mum = 'mum_ana';
  final d = day('2026-08-18');

  late List<MethodCall> calls;

  /// The plugin refuses to touch the channel at all unless it can resolve the
  /// callback to a handle, which `PluginUtilities` cannot do for a closure in a
  /// test process. The plugin exposes this seam for exactly this reason.
  setUpAll(() {
    AndroidAlarmManager.setTestOverrides(
      getCallbackHandle: (_) => CallbackHandle.fromRawHandle(1),
    );
  });

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidAlarmManager.channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidAlarmManager.channel, null);
  });

  /// `JSONMethodCodec` delivers the positional list as a `List<dynamic>`.
  List<dynamic> argsOf(MethodCall call) => call.arguments as List<dynamic>;

  // The positional layout of `Alarm.oneShotAt`, named here so an assertion
  // below reads as something other than an index into a mystery.
  const idIndex = 0;
  const allowWhileIdleIndex = 2;
  const exactIndex = 3;
  const wakeupIndex = 4;
  const startMillisIndex = 5;
  const rescheduleOnRebootIndex = 6;

  ScheduledWarning warningAt(DayKey day, int hour) => ScheduledWarning(
        day: day,
        at: day.at(LocalTimeOfDay(hour, 0), madrid),
      );

  void alarmCallback(int id) {}

  AndroidWarningAlarmScheduler schedulerWith({required bool exact}) =>
      AndroidWarningAlarmScheduler(alarmCallback, () async => exact);

  group('cancel before arm — the ordering, on the real implementation', () {
    test('a moved warning is cancelled first, then re-armed', () async {
      // One day, two instants: the watcher moved the warning time. Same
      // platform id, so this is the case where getting it backwards means
      // nothing happens at all.
      await schedulerWith(exact: true).apply(
        linkId: mum,
        toCancel: {warningAt(d, 10)},
        desired: {warningAt(d, 8)},
      );

      expect(calls.map((c) => c.method).toList(),
          ['Alarm.cancel', 'Alarm.oneShotAt'],
          reason: 'cancelling second would disarm the alarm just armed, and '
              'the symptom is a warning that never fires');
    });

    test('every cancel precedes every arm across a whole window', () async {
      final window = {for (var i = 0; i < 5; i++) warningAt(d.plusDays(i), 8)};
      final old = {for (var i = 0; i < 5; i++) warningAt(d.plusDays(i), 10)};

      await schedulerWith(exact: true)
          .apply(linkId: mum, toCancel: old, desired: window);

      final methods = calls.map((c) => c.method).toList();
      final lastCancel = methods.lastIndexOf('Alarm.cancel');
      final firstArm = methods.indexOf('Alarm.oneShotAt');
      expect(lastCancel, lessThan(firstArm));
      expect(methods.where((m) => m == 'Alarm.cancel'), hasLength(5));
      expect(methods.where((m) => m == 'Alarm.oneShotAt'), hasLength(5));
    });

    test('the cancel names the id the arm will use', () async {
      await schedulerWith(exact: true).apply(
        linkId: mum,
        toCancel: {warningAt(d, 10)},
        desired: {warningAt(d, 8)},
      );

      expect(argsOf(calls[0]).single, AlarmIds.warning(mum, d));
      expect(argsOf(calls[1])[idIndex], AlarmIds.warning(mum, d));
    });
  });

  group('the exact-alarm degradation reaches the platform', () {
    test('refused: it still arms, inexactly', () async {
      // The defect this replaced armed NOTHING and recorded the whole set as
      // armed. Degrade, never drop: an alarm armed inexactly still fires; one
      // refused outright never does.
      final degraded = await schedulerWith(exact: false)
          .apply(linkId: mum, toCancel: const {}, desired: {warningAt(d, 10)});

      expect(calls.single.method, 'Alarm.oneShotAt');
      expect(argsOf(calls.single)[exactIndex], isFalse);
      expect(degraded, isFalse, reason: 'and it says so, so §13 can surface it');
    });

    test('granted: exact is what is asked for', () async {
      final exact = await schedulerWith(exact: true)
          .apply(linkId: mum, toCancel: const {}, desired: {warningAt(d, 10)});

      expect(argsOf(calls.single)[exactIndex], isTrue);
      expect(exact, isTrue);
    });

    test('asked ONCE per apply, not per alarm', () async {
      // A device-wide setting. A value re-read mid-loop could change between
      // alarms and arm half the window each way — and each ask is a binder call
      // on a path that runs in a woken isolate.
      var asks = 0;
      final scheduler = AndroidWarningAlarmScheduler(alarmCallback, () async {
        asks++;
        return true;
      });

      await scheduler.apply(
        linkId: mum,
        toCancel: const {},
        desired: {for (var i = 0; i < 5; i++) warningAt(d.plusDays(i), 10)},
      );

      expect(asks, 1);
    });
  });

  group('the flags a dead man\'s switch depends on', () {
    test('wakeup, allowWhileIdle and rescheduleOnReboot are all set',
        () async {
      // Each of these is one word and each removes a whole class of warning.
      // Without `wakeup` the alarm waits for the phone to be picked up; without
      // `allowWhileIdle` Doze defers even a wakeup alarm; without
      // `rescheduleOnReboot` an ordinary restart disarms the window silently.
      await schedulerWith(exact: true)
          .apply(linkId: mum, toCancel: const {}, desired: {warningAt(d, 10)});

      final args = argsOf(calls.single);
      expect(args[wakeupIndex], isTrue);
      expect(args[allowWhileIdleIndex], isTrue);
      expect(args[rescheduleOnRebootIndex], isTrue);
    });

    test('the instant is the domain\'s, to the millisecond', () async {
      // The zone arithmetic already happened in the domain, against the
      // WATCHER's zone. Anything recomputed here would be a second opinion and
      // a DST bug waiting for October.
      final warning = warningAt(d, 10);
      await schedulerWith(exact: true)
          .apply(linkId: mum, toCancel: const {}, desired: {warning});

      expect(argsOf(calls.single)[startMillisIndex],
          warning.at.millisecondsSinceEpoch);
    });
  });

  group('cancelAll', () {
    test('cancels each armed warning by its own id', () async {
      final armed = {for (var i = 0; i < 3; i++) warningAt(d.plusDays(i), 10)};

      await schedulerWith(exact: true).cancelAll(linkId: mum, armed: armed);

      expect(calls.map((c) => c.method).toSet(), {'Alarm.cancel'});
      expect(
        calls.map((c) => argsOf(c).single).toSet(),
        {for (final w in armed) AlarmIds.warning(mum, w.day)},
      );
    });

    test('touches nothing when nothing is armed', () async {
      await schedulerWith(exact: true)
          .cancelAll(linkId: mum, armed: const {});
      expect(calls, isEmpty);
    });
  });
}
