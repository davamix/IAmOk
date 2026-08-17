import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../copy/notification_copy.dart';
import '../domain/domain.dart';
import '../platform/alarm_ids.dart';
import '../platform/clock.dart';
import '../platform/notification_service.dart';

/// **Debug builds only.** ARCHITECTURE.md §14, and the phase brief is emphatic
/// about the timing:
///
/// > Build the debug harness alongside the first alarm, not after it. Without
/// > it, verifying a 24-hour behaviour takes 24 hours.
///
/// That is the whole argument. The riskiest logic in this app is time-dependent
/// and runs on hardware chosen for being hostile to background work, so the
/// difference between "force the date and look" and "wait until tomorrow" is
/// the difference between finding a defect and shipping it.
///
/// Five capabilities, from §14 and `screens.md`: force the current date, fire
/// any alarm now, dump `LocalStore`, run `reconcile()` on demand, and inject a
/// synthetic FCM payload — the last of which arrives in Phase 4 with FCM
/// itself, and is listed here rather than silently dropped.
///
/// Nothing here is reachable outside a debug build: [DebugHarnessButton]
/// renders nothing unless [kDebugMode], so the tree is never built at all and
/// `DebugHarnessScreen` — with it `LocalStore.dump()` and `LocalStore.wipe()` —
/// is tree-shaken.
///
/// Gated on `kDebugMode` rather than `!kReleaseMode`: the latter leaves the
/// harness in **profile** builds, which additionally carry the `INTERNET`
/// permission that release does not.
/// The sentinel day every *fire now* test notification is posted under.
///
/// The epoch, because it can never fall inside a rolling window: a test
/// notification must not share an id with a real scheduled reminder, or posting
/// one would silently replace an armed alarm on the device being measured.
///
/// Named rather than repeated, so the *"Dismiss test notifications"* control
/// cancels the same ids the *"Fire … now"* controls post — two literals that
/// drifted apart would leave notifications nothing could clear.
final DayKey _testNotificationDay = DayKey(1970, 1, 1);

class DebugHarnessButton extends StatelessWidget {
  const DebugHarnessButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return IconButton(
      icon: const Icon(Icons.bug_report_outlined),
      tooltip: 'Debug harness',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const DebugHarnessScreen()),
      ),
    );
  }
}

class DebugHarnessScreen extends ConsumerStatefulWidget {
  const DebugHarnessScreen({super.key});

  @override
  ConsumerState<DebugHarnessScreen> createState() => _DebugHarnessScreenState();
}

class _DebugHarnessScreenState extends ConsumerState<DebugHarnessScreen> {
  String _output = '';

  Future<void> _run(String label, Future<String> Function() action) async {
    try {
      final result = await action();
      if (mounted) setState(() => _output = '$label\n\n$result');
    } on Object catch (error, stack) {
      if (mounted) setState(() => _output = '$label FAILED\n\n$error\n\n$stack');
    }
    await ref.read(watchedStateProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(appServicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Debug harness')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Clock', [
            // Forcing the date is the single most valuable control here: the
            // rolling window, the day rollover that re-enables the tap target,
            // and the away-window extension are all 24-hour behaviours.
            //
            // The offset is written to LocalStore rather than held in memory
            // because the alarm isolate must agree about what day it is — §4's
            // rule that what a background isolate needs is on disk. It survives
            // a restart for the same reason.
            _Action('Force date…', () async {
              final now = services.clock.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime(now.year, now.month, now.day),
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (picked == null) return 'cancelled';
              // Time of day carried over from the injected clock, never from
              // DateTime.now() — this is the one control whose whole job is to
              // decide what "now" means, so reaching around Clock here would
              // make a forced date disagree with itself.
              final target = DateTime.utc(
                picked.year,
                picked.month,
                picked.day,
                now.hour,
                now.minute,
              );
              final offset = SystemClock.offsetTo(target);
              await services.store.setClockOffset(offset);
              return 'offset now $offset\n'
                  'RESTART the app for background isolates to pick it up.';
            }),
            _Action('Clear forced date', () async {
              await services.store.setClockOffset(Duration.zero);
              return 'offset cleared — RESTART the app';
            }),
            _Action('Show clock', () async {
              final offset = await services.store.clockOffset();
              final zone = await services.store.deviceTimezone();
              return 'clock.now()      ${services.clock.now()}\n'
                  // Through Clock, not DateTime.now() directly: an unshifted
                  // SystemClock IS the real instant, and going the long way
                  // round keeps this file honest against the purity guard.
                  'real now         ${const SystemClock().now()}\n'
                  'stored offset    $offset\n'
                  'device timezone  $zone';
            }),
          ]),

          _section('Reconcile', [
            // The same function every entry point calls. Running it twice and
            // comparing is the idempotence check: the second run must be a
            // no-op, or boot recovery is a duplicate-notification bug.
            _Action('Run reconcile()', () async {
              final state = await services.watchedReconcile
                  .reconcile(selfUid: services.selfUid);
              return 'today            ${state.today}\n'
                  'tapped today     ${state.hasTappedToday}\n'
                  'audience         ${state.audience.names}\n'
                  'notifications    ${state.notificationsEnabled}\n'
                  'armed (plugin)   ${state.armed}';
            }),
            _Action('Run reconcile() twice — idempotence', () async {
              await services.watchedReconcile
                  .reconcile(selfUid: services.selfUid);
              final before = await services.alarms.armedAccordingToPlugin();
              await services.watchedReconcile
                  .reconcile(selfUid: services.selfUid);
              final after = await services.alarms.armedAccordingToPlugin();
              return 'armed after 1st  $before\n'
                  'armed after 2nd  $after\n'
                  '${before == after ? "IDEMPOTENT" : "NOT IDEMPOTENT"}';
            }),
          ]),

          _section('Alarms', [
            // "Fire alarm now" is what makes a notification testable without
            // waiting for 12:00. It shows the real copy through the real
            // channel, so what is verified is what ships.
            //
            // The epoch day is a SENTINEL, deliberately outside any rolling
            // window, so posting a test notification cannot collide with a real
            // scheduled reminder's id and replace it. The cost is that nothing
            // cancels it either — `toCancel` only ever holds days the window
            // knows about — so it sits in the shade until somebody swipes it.
            // Hence the control below.
            for (final slot in ReminderSlot.values)
              _Action('Fire ${slot.name} reminder now', () async {
                await services.notifications.showNow(
                  id: AlarmIds.reminder(_testNotificationDay, slot),
                  title: NotificationCopy.reminderTitle,
                  body: NotificationCopy.reminderBody(slot),
                  channel: NotificationService.remindersChannel,
                );
                return 'posted ${slot.name} on the reminders channel';
              }),
            // Cancels exactly the three sentinel ids and nothing else.
            //
            // NOT `cancelAll()`, which would also disarm the whole rolling
            // window — a destructive act wearing a tidying-up label, on the one
            // device every alarm measurement is taken from. A test notification
            // left in the shade looks exactly like a real reminder, and on
            // 2026-08-17 that cost real time: it was a live candidate
            // explanation for duplicate reminders until it was ruled out.
            _Action('Dismiss test notifications', () async {
              for (final slot in ReminderSlot.values) {
                await services.notifications
                    .cancelReminder(_testNotificationDay, slot);
              }
              return 'dismissed the three test notifications\n'
                  'the armed window is untouched';
            }),
            // Compares LocalStore against the notification plugin's own
            // record. Both are app-local: `pendingNotificationRequests()` reads
            // SharedPreferences, not AlarmManager, and no public API can list
            // an app's pending alarms. A divergence means the two bookkeeping
            // copies drifted — real, and NOT the same as the OS having dropped
            // an alarm. Ground truth is `adb shell dumpsys alarm`.
            _Action('Compare store against plugin record', () async {
              final stored = await services.store.pendingReminders();
              final armed = await services.notifications.pending();
              final buffer = StringBuffer()
                ..writeln('store says   ${stored.length}')
                ..writeln('plugin says  ${armed.length}')
                ..writeln(
                    stored.length == armed.length ? 'AGREE' : 'DIVERGED')
                ..writeln();
              for (final reminder in stored.toList()
                ..sort((a, b) => a.at.compareTo(b.at))) {
                buffer.writeln('${reminder.at}  ${reminder.slot.name}');
              }
              return buffer.toString();
            }),
            _Action('Cancel every alarm', () async {
              await services.alarms.cancelAll();
              await services.store.replacePendingReminders(const {});
              return 'cancelled — run reconcile() to re-arm';
            }),
          ]),

          _section('Store', [
            _Action('Dump LocalStore', () async {
              const encoder = JsonEncoder.withIndent('  ');
              return encoder.convert(await services.store.dump());
            }),
            _Action('Seed fake watchers', () async {
              // Phase 2 has no backend and no pairing, so the audience needs
              // fake links to render. Phase 5 replaces this with redeemInvite.
              final now = services.clock.now();
              final zoneName =
                  await services.store.deviceTimezone() ?? 'Etc/UTC';
              for (final name in ['Ana', 'Beto']) {
                await services.store.upsertLink(Link(
                  watchedUid: services.selfUid,
                  watcherUid: name.toLowerCase(),
                  status: LinkStatus.accepted,
                  watchedName: 'Mum',
                  watcherName: name,
                  watchedTimezone: zoneName,
                  // In the LINK's zone, not UTC. `activeFrom` is §10 step 3's
                  // guard — "never warn about days before the link existed" —
                  // and seeding it a day off from the zone the link claims
                  // plants a wrong answer for Phase 3's watcher tests to find.
                  activeFrom: DayKey.fromInstant(
                    now,
                    TimeZones.tryLocation(zoneName) ?? TimeZones.utc,
                  ),
                  createdAt: now,
                ));
              }
              return 'seeded Ana and Beto';
            }),
            _Action('Revoke every watcher', () async {
              // Reaches the empty-audience state without uninstalling, which is
              // the state the Phase 1 gate's decision is actually about.
              final links =
                  await services.store.linksWatching(services.selfUid);
              for (final link in links) {
                await services.store
                    .upsertLink(link.copyWith(status: LinkStatus.revoked));
              }
              return 'revoked ${links.length} link(s)';
            }),
            _Action('Wipe store', () async {
              await services.alarms.cancelAll();
              await services.store.wipe();
              return 'wiped — RESTART the app';
            }),
          ]),

          _section('Permissions', [
            _Action('Read permissions', () async {
              final snapshot = await services.permissions.snapshot();
              final delivery = await services.permissions.delivery();
              return '$snapshot\n\ndelivery handed to the domain: '
                  '${delivery.name}';
            }),
            _Action('Request notifications', () async {
              final granted =
                  await services.permissions.requestNotifications();
              return granted ? 'granted' : 'denied';
            }),
          ]),

          if (_output.isNotEmpty) ...[
            const Divider(height: 32),
            SelectableText(
              _output,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, List<_Action> actions) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in actions)
                OutlinedButton(
                  onPressed: () => _run(action.label, action.run),
                  child: Text(action.label),
                ),
            ],
          ),
        ],
      );
}

class _Action {
  const _Action(this.label, this.run);

  final String label;
  final Future<String> Function() run;
}
