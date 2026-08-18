import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:timezone/timezone.dart' as tz;

import '../application/providers.dart';
import '../copy/notification_copy.dart';
import '../data/check_in_reader.dart';
import '../data/local_store.dart';
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
/// Reads, transforms and re-stores the simulated backend.
///
/// Read-modify-write rather than a setter per field, so setting the refusal
/// cause does not silently drop the check-in days somebody seeded a minute
/// earlier — which on a device reads as the app losing state rather than as the
/// harness overwriting it.
Future<void> _updateBackend(
  LocalStore store,
  SimulatedBackend Function(SimulatedBackend) change,
) async {
  final current = SimulatedBackend.decode(await store.simulatedBackendRaw());
  await store.setSimulatedBackendRaw(change(current).encode());
}

/// The device's cached zone, or UTC. Same fallback as every isolate uses.
Future<tz.Location> _zone(LocalStore store) async {
  final name = await store.deviceTimezone();
  if (name == null) return TimeZones.utc;
  return TimeZones.tryLocation(name) ?? TimeZones.utc;
}

/// Every standing warning across every watched link, as one comparable string.
Future<String> _standing(LocalStore store, String selfUid) async {
  final links = await store.linksWatchedBy(selfUid);
  final parts = <String>[];
  for (final link in links) {
    final cache = await store.watcherCache(link.id);
    parts.add('${link.watchedName}=${cache.warningsShownFor}'
        '/${cache.accessLostNotifiedOn ?? '-'}');
  }
  return parts.join(' ');
}

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

          // ------------------------------------------------------- Phase 3
          //
          // The watcher side runs on a simulated backend, and these controls
          // are what make its FOUR outcomes reachable on a device. Two of them
          // — unreachable and refused — are close to impossible to produce on
          // demand against a real backend, and they are exactly the two whose
          // wording is a correctness requirement rather than copy polish.
          //
          // The simulated state lives in LocalStore, so the alarm isolate sees
          // whatever is set here. Setting it in memory would leave the one
          // isolate this phase exists to test reading something else.
          _section('Watcher — simulated backend', [
            for (final outcome in SimulatedReadOutcome.values)
              _Action('Backend answers: ${outcome.name}', () async {
                await _updateBackend(
                  services.store,
                  (b) => b.copyWith(outcome: outcome),
                );
                return 'the next read will be ${outcome.name}';
              }),
            for (final cause in RefusedCause.values)
              _Action('Refusal cause: ${cause.name}', () async {
                await _updateBackend(
                  services.store,
                  (b) => b.copyWith(
                    outcome: SimulatedReadOutcome.refused,
                    refusedCause: cause,
                  ),
                );
                return 'refused with ${cause.name}\n'
                    'each cause implies a DIFFERENT remediation, so a change '
                    'must replace the standing notice rather than stack';
              }),
            _Action('Backend holds a check-in for yesterday', () async {
              final zone = await _zone(services.store);
              final yesterday =
                  DayKey.fromInstant(services.clock.now(), zone).plusDays(-1);
              await _updateBackend(
                services.store,
                (b) => b.copyWith(
                  outcome: SimulatedReadOutcome.succeeded,
                  checkInDays: {...b.checkInDays, yesterday},
                ),
              );
              return 'added $yesterday\n'
                  'run reconcile() — a standing warning for that day should be '
                  'REPLACED by a correction, not joined by one';
            }),
            _Action('Backend holds an away period covering yesterday',
                () async {
              final zone = await _zone(services.store);
              final today = DayKey.fromInstant(services.clock.now(), zone);
              await _updateBackend(
                services.store,
                (b) => b.copyWith(
                  outcome: SimulatedReadOutcome.succeeded,
                  away: AwayPeriod(
                    from: today.plusDays(-3),
                    through: today.plusDays(3),
                  ),
                ),
              );
              return 'away ${today.plusDays(-3)} … ${today.plusDays(3)}';
            }),
            _Action('Clear the simulated backend', () async {
              await services.store.setSimulatedBackendRaw(null);
              return 'back to: read succeeds, holding nothing\n'
                  'which produces a warning — the noisy direction, on purpose';
            }),
            _Action('Show the simulated backend', () async {
              final raw = await services.store.simulatedBackendRaw();
              return '${SimulatedBackend.decode(raw)}\n\nraw: ${raw ?? '(unset)'}';
            }),
          ]),

          _section('Watcher — reconcile', [
            _Action('Run the watcher reconcile', () async {
              final state = await services.watcherReconcile
                  .reconcile(selfUid: services.selfUid);
              if (state.isEmpty) {
                return 'no links where you are the WATCHER\n'
                    'seed one first — a watched-side link is the other '
                    'direction and will not appear here';
              }
              final buffer = StringBuffer('today ${state.today}\n');
              for (final person in state.people) {
                buffer
                  ..writeln('')
                  ..writeln('${person.name}  (${person.link.id})')
                  ..writeln('  outcome    ${person.decision.outcome.name}')
                  ..writeln('  about day  ${person.decision.day}')
                  ..writeln('  silence    ${person.decision.silenceReason?.name ?? '-'}')
                  ..writeln('  confirmed  ${person.cache.lastConfirmedDay ?? '-'}')
                  ..writeln('  standing   ${person.cache.warningsShownFor}')
                  ..writeln('  lostAccess ${person.cache.accessLostSince ?? '-'}'
                      ' ${person.cache.accessLostCause?.name ?? ''}');
              }
              return buffer.toString();
            }),
            // The idempotence check that matters most on this side: a warning
            // already standing must NOT fire again on app open, on boot, or on
            // the next alarm. Every entry point calls reconcile.
            _Action('Run it twice — no second notification', () async {
              await services.watcherReconcile
                  .reconcile(selfUid: services.selfUid);
              final before = await _standing(services.store, services.selfUid);
              await services.watcherReconcile
                  .reconcile(selfUid: services.selfUid);
              final after = await _standing(services.store, services.selfUid);
              return 'standing after 1st  $before\n'
                  'standing after 2nd  $after\n'
                  '${before == after ? 'IDEMPOTENT' : 'NOT IDEMPOTENT'}\n\n'
                  'watch the shade: a second notification here is the bug';
            }),
            // Two different questions, and only the second one answers the
            // thing this phase exists to find out.
            //
            // This one runs the callback's LOGIC in the UI isolate. It proves
            // the decision, the copy and the store writes, in one second rather
            // than a day — and it proves nothing at all about whether Android
            // wakes a background isolate on this handset.
            _Action('Run the alarm logic now (this isolate)', () async {
              await services.watcherReconcile
                  .reconcile(selfUid: services.selfUid);
              return 'reconciled in the UI isolate\n\n'
                  'This does NOT test the isolate. Use the control below for '
                  'that — it is the only one that asks the OS anything.';
            }),
            // THE control for Phase 3. Arms a real AlarmManager alarm through
            // android_alarm_manager_plus, pointing at the real top-level entry
            // point. When it fires, Android starts a fresh FlutterEngine and a
            // bare Dart isolate that shares nothing with this one.
            //
            // Two minutes, not seconds: long enough to background the app,
            // swipe it from recents, or lock the phone first — which is the
            // state the answer actually depends on.
            _Action('Arm a REAL warning alarm, 2 minutes out', () async {
              final links =
                  await services.store.linksWatchedBy(services.selfUid);
              if (links.isEmpty) {
                return 'seed a watched person first';
              }
              final link = links.first;
              final zone = await _zone(services.store);
              final fireAt = tz.TZDateTime.from(
                services.clock.now().add(const Duration(minutes: 2)),
                zone,
              );
              await services.warningAlarms.apply(
                linkId: link.id,
                toCancel: const {},
                desired: {
                  ScheduledWarning(
                    day: DayKey.fromInstant(services.clock.now(), zone),
                    at: fireAt,
                  ),
                },
              );
              return 'armed for $fireAt\n\n'
                  'Now background the app — or swipe it from recents — and '
                  'wait. A notification arriving means the OS woke a bare '
                  'isolate that shares no memory with this screen.\n\n'
                  'Ground truth for what is armed: adb shell dumpsys alarm, '
                  'written to a file and pulled.';
            }),
            // **The control that makes the unattended warning testable at all.**
            //
            // Phase 2's worst defect was found by watching reminders arrive
            // rather than by counting registered alarms, and that check cost a
            // day of waiting. The equivalent here is a warning arriving at its
            // natural `warningLocalTime` with nobody looking — and the seeded
            // links use 10:00, so observing it naturally means waiting until
            // tomorrow morning.
            //
            // This seeds the same links with a warning time a few minutes out
            // and clears everything that would suppress the notification, so
            // the whole path — OS wakes the isolate, it reads, decides, picks
            // one of four messages, posts it on the right channel at the right
            // id — is observable in the time it takes to make coffee. That is
            // what the harness is for: without it, verifying a 24-hour
            // behaviour takes 24 hours.
            _Action('Arm the natural warning 3 minutes out', () async {
              final zone = await _zone(services.store);
              final now = services.clock.now();
              final fireAt = tz.TZDateTime.from(
                now.add(const Duration(minutes: 3)),
                zone,
              );
              final today = DayKey.fromInstant(now, zone);

              // A standing warning for D correctly suppresses a second one, so
              // a stale cache from an earlier run makes this test silently
              // prove nothing. Cleared rather than merged.
              for (final link
                  in await services.store.linksWatchedBy(services.selfUid)) {
                await services.store
                    .saveWatcherCache(link.id, const WatcherCache.empty());
              }

              for (final name in ['Mum', 'Granddad']) {
                await services.store.upsertLink(Link(
                  watchedUid: name.toLowerCase(),
                  watcherUid: services.selfUid,
                  status: LinkStatus.accepted,
                  watchedName: name,
                  watcherName: 'Me',
                  watchedTimezone: zone.name,
                  activeFrom: today.plusDays(-1),
                  warningLocalTime:
                      LocalTimeOfDay(fireAt.hour, fireAt.minute),
                  createdAt: now,
                ));
              }

              // The backend answers successfully and holds nothing, so D is
              // genuinely unconfirmed and the outcome is warnOnline — the one
              // message that claims something about her, and therefore the one
              // worth watching arrive.
              await _updateBackend(
                services.store,
                (b) => b.copyWith(
                  outcome: SimulatedReadOutcome.succeeded,
                  checkInDays: const {},
                  clearAway: true,
                ),
              );

              await services.watcherReconcile
                  .reconcile(selfUid: services.selfUid);

              final hh = fireAt.hour.toString().padLeft(2, '0');
              final mm = fireAt.minute.toString().padLeft(2, '0');
              return '''
warning time set to $hh:$mm
cache cleared, backend holds nothing

Now CLOSE the app and wait. Two notifications should arrive:
  "No check-in from Mum yesterday."
  "No check-in from Granddad yesterday."

Anything else - one, three, the wrong wording, the wrong
channel - is the finding.''';
            }),
            _Action('Compare warning alarms: store vs armed', () async {
              final links =
                  await services.store.linksWatchedBy(services.selfUid);
              if (links.isEmpty) return 'no watcher links';
              final buffer = StringBuffer();
              for (final link in links) {
                final stored = await services.store.pendingWarnings(link.id);
                buffer.writeln('${link.watchedName}  store says '
                    '${stored.length}');
                for (final w in stored.toList()
                  ..sort((a, b) => a.at.compareTo(b.at))) {
                  buffer.writeln('  ${w.at}');
                }
              }
              buffer.writeln('');
              buffer.writeln('Ground truth is `adb shell dumpsys alarm`, '
                  'written to a file and pulled. No public API can enumerate '
                  'an app\'s pending alarms.');
              return buffer.toString();
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
            // The OTHER direction, and it is a different thing entirely.
            // "Seed fake watchers" makes links where this user is WATCHED —
            // people who get told about her. These are links where this user is
            // the WATCHER, which is what the whole of Phase 3 operates on. The
            // two are easy to confuse from the harness, and seeding the wrong
            // one produces a watcher reconcile that finds nothing and reports
            // success.
            _Action('Seed fake watched people', () async {
              final now = services.clock.now();
              final zoneName =
                  await services.store.deviceTimezone() ?? 'Etc/UTC';
              for (final name in ['Mum', 'Granddad']) {
                await services.store.upsertLink(Link(
                  watchedUid: name.toLowerCase(),
                  watcherUid: services.selfUid,
                  status: LinkStatus.accepted,
                  watchedName: name,
                  watcherName: 'Me',
                  watchedTimezone: zoneName,
                  // Yesterday, so `D` is never before activeFrom and the
                  // beforeActiveFrom branch does not silently swallow every
                  // test — a silence that looks exactly like the app working.
                  activeFrom: DayKey.fromInstant(
                    now,
                    await _zone(services.store),
                  ).plusDays(-1),
                  warningLocalTime: const LocalTimeOfDay(10, 0),
                  createdAt: now,
                ));
              }
              return 'seeded Mum and Granddad as WATCHED by you\n'
                  'the watcher reconcile operates on these';
            }),
            _Action('Revoke every watched person', () async {
              final links =
                  await services.store.linksWatchedBy(services.selfUid);
              for (final link in links) {
                await services.store
                    .upsertLink(link.copyWith(status: LinkStatus.revoked));
              }
              return 'revoked ${links.length} link(s)\n'
                  'run the watcher reconcile — standing warnings should be '
                  'WITHDRAWN, never corrected';
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
