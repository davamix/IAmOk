import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:timezone/timezone.dart' as tz;

import '../application/providers.dart';
import '../copy/notification_copy.dart';
import '../data/check_in_reader.dart';
import '../data/firebase_bootstrap.dart';
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
/// Nothing here is reachable outside a debug build, and the reason is worth
/// stating precisely, because the obvious phrasing is wrong. [DebugHarnessButton]
/// **is** constructed and built in a release build — `tap_screen.dart` creates
/// it unconditionally — and it returns `SizedBox.shrink()`. What makes the
/// harness unreachable is that `DebugHarnessScreen` is referenced from exactly
/// one place in the repo, the `onPressed` closure of a widget that is never
/// returned: no route table, no deep link, no other construction site. So
/// reachability is nil by construction rather than by compilation.
///
/// This docstring used to add "so the tree is never built at all and
/// `DebugHarnessScreen` — with it `LocalStore.dump()` and `LocalStore.wipe()` —
/// is tree-shaken". That is the *expected* AOT outcome of dead code behind a
/// const-`false` branch, but nothing here measures it, and `flutter test` cannot:
/// the test VM is a debug VM, so the false branch is unreachable from a unit
/// test. It does not matter for security — reachability is already nil — only
/// for APK size and for what strings a release binary contains. Corrected at the
/// Phase 3 security gate rather than left as an unmeasured claim.
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

/// A token, abbreviated, or the honest reason there is not one.
///
/// **Abbreviated deliberately.** An FCM token is enough to send a push to
/// somebody's phone, so the panel that is read out loud during a device session
/// — and photographed into a phase summary — shows a prefix. *Show the FCM
/// token* prints it in full, because sending a test push needs the whole string
/// and there is nowhere else to get it.
String _tokenLine(String? token) => token == null
    ? 'NOT REGISTERED - no Play Services, or no network'
    : '${token.substring(0, 12)}... saved';

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

          // **Phase 4's identity, and where this build is pointed.**
          //
          // Sign-in has no screen of its own yet — the screen inventory puts
          // onboarding in Phase 5 and does not specify one, and inventing an
          // un-designed elderly-facing sign-in now would be a surface the UI/UX
          // guidelines have never approved, replaced within a phase. So it is
          // driven from here, where nothing is user-visible and no copy is owed.
          _section('Identity — Phase 4', [
            _Action('Show identity and backend', () async {
              final stored = await services.store.selfUid();
              // **The override, first, because it outranks everything below
              // it.** A `debug_simulated_backend` row answers the tier-1
              // read instead of Firestore, and until this line existed that
              // was invisible: the panel said EMULATOR, the reconcile said
              // the read succeeded, and neither was talking to a backend at
              // all. Measured on the POCO F3 on 2026-08-21, where a row left
              // over from the Phase 3 sessions silently answered a reconcile
              // that was meant to be proving Firestore worked.
              final simulated = await services.store.simulatedBackendRaw();
              return 'reads answered by ${simulated == null ? "the backend below" : "THE SIMULATED BACKEND - Firestore is not being asked"}\n'
                  'backend          ${FirebaseBootstrap.describe}\n'
                  // Both, on purpose. `stored` is what every isolate decides
                  // with; `live` is what the security rules will judge. They
                  // agree in every healthy state, and when they do NOT the
                  // symptom is every read coming back permission-denied — which
                  // ADR-0004 turns into an access-lost notice about somebody's
                  // relative. Two lines here is the cheapest way to tell that
                  // apart from a genuine backend fault.
                  'stored uid       ${stored ?? '-'}\n'
                  'live uid         ${services.auth.currentUid ?? '-'}\n'
                  'display name     ${services.auth.displayName ?? '-'}';
            }),
            _Action('Sign in', () async {
              final uid = await services.auth.signIn();
              if (uid == null) return 'cancelled — no account chosen';

              // `users/{uid}`, immediately. Phase 5's `redeemInvite` reads
              // this document to denormalise `displayName` and `timezone`
              // onto the link (§7), so a signed-in user without one cannot
              // be paired with — and the failure would surface there, a
              // phase away from its cause.
              final zone = await services.store.deviceTimezone();
              await services.users.upsert(
                uid: uid,
                displayName: services.auth.displayName ?? 'Someone',
                timezone: zone ?? 'Etc/UTC',
              );

              // The token, immediately, and under the uid just established.
              // `AppServices.registerForPush` keys on `selfUid`, which is a
              // SNAPSHOT taken at launch — so it is still the signed-out
              // sentinel here and would register nothing. This is the one place
              // that holds the new uid before a restart.
              final token = await services.push.register(uid: uid);

              return 'signed in as     $uid\n'
                  'users/$uid written\n'
                  'fcm token        ${_tokenLine(token)}\n'
                  'RESTART the app: selfUid is read once, at launch.';
            }),
            _Action('Show the FCM token', () async {
              // **Tier 2, and the panel has to say so.** No token means pushes
              // do not arrive; it does not mean the app is wrong — every
              // watcher still reconciles on app open and at alarm time (§3).
              //
              // The full value is printed because there is no other way to get
              // it: FCM has no emulator, so this always talks to the REAL
              // project, and sending a test push means handing this string to
              // something outside the app.
              final token = await services.push.token();
              if (token == null) {
                return 'NO TOKEN - this device cannot be reached by push.\n'
                    'Needs Play Services and a network. FCM has no emulator, '
                    'so this path always talks to the REAL project even when '
                    'everything else is pointed at the suite.';
              }
              return 'token, in full\n$token';
            }),
            _Action('Show App Check — monitoring only', () async {
              // **This control cannot be a green tick, and should not read like
              // one.** App Check is in MONITORING mode: it blocks nothing, and
              // until enforcement is enabled the rules are the whole defence
              // (`docs/security/threat-model.md`). A failure here costs a metric.
              //
              // In a debug build the provider is `AndroidDebugProvider`, which
              // attests nothing — it prints a UUID to logcat that a human pastes
              // into the Firebase console, after which that one install is
              // trusted. So a failure is the EXPECTED state until somebody has
              // done that, and saying so here is the difference between a
              // finding and an afternoon.
              try {
                final token = await FirebaseAppCheck.instance.getToken();
                return token == null
                    ? 'no token — nothing is being attested\n'
                        'monitoring mode, so nothing is blocked either'
                    : 'token acquired (${token.length} chars)\n'
                        'this install is attesting; the console shows it under '
                        'App Check > Requests';
              } on Object catch (error) {
                return 'no token: $error\n\n'
                    'EXPECTED until the debug token is registered. Find it with\n'
                    '  adb logcat | Select-String DebugAppCheckProvider\n'
                    'and add it in the Firebase console under App Check.\n'
                    'Nothing is blocked either way — monitoring mode.';
              }
            }),
            _Action('Register the FCM token again', () async {
              // Idempotence, the same check the `users/{uid}` write gets. The
              // rules validate this document's exact field set and require
              // `updatedAt == request.time`, so a second write proves the
              // repository and the deployed rules still agree.
              final uid = services.selfUid;
              if (uid == LocalStore.signedOutUid) return 'not signed in';
              final token = await services.push.register(uid: uid);
              return 'users/$uid/tokens/...  ${_tokenLine(token)}';
            }),
            _Action('Write users/{uid} again — idempotence', () async {
              // The rules freeze `createdAt` on update and require it on
              // create, so this is the write that proves the repository can
              // tell the two apart. Getting it wrong makes every ordinary
              // app open a permission-denied — which ADR-0004 maps to
              // REFUSED, which tells a family the app has lost sight of
              // their relative.
              final uid = services.selfUid;
              if (uid == LocalStore.signedOutUid) return 'not signed in';
              final zone = await services.store.deviceTimezone();
              await services.users.upsert(
                uid: uid,
                displayName: services.auth.displayName ?? 'Someone',
                timezone: zone ?? 'Etc/UTC',
              );
              return 'second write accepted — createdAt preserved';
            }),
            _Action('Sync links from Firestore', () async {
              // The step that makes a seeded link visible to the app.
              // Links are Function-written (§9), so nothing in this app
              // creates one — `tools/seed-link.ps1` stands in for
              // `redeemInvite` until Phase 5.
              final ok = await services.syncLinks();
              final watching = await services.store.linksWatching(services.selfUid);
              final watchedBy = await services.store.linksWatchedBy(services.selfUid);
              return 'read succeeded   $ok\n'
                  // Both directions, because a self-link appears in both and
                  // a one-sided seed shows up here as an asymmetry rather
                  // than as nothing at all.
                  'I am watched by ${watching.length}\n'
                  'I watch          ${watchedBy.length}\n'
                  '${ok ? "" : "read FAILED - the local set was left alone, "
                      "which is ADR-0001s rule applied to links"}';
            }),
            _Action('Sign out — CLEARS the local cache', () async {
              // Through `AppServices`, not `auth` directly, because this
              // install's token document has to go FIRST — after
              // `clearSelfUid` the rules refuse the delete and the row is
              // unremovable from this device for good, while the fan-out keeps
              // sending to a phone that has signed into another account. See
              // [AppServices.signOut].
              await services.signOut();
              // **The in-memory half of the same fact.** `signOut` clears
              // `LocalStore`'s uid; without this `signedInUidProvider` keeps the
              // old one, so `appServicesProvider.selfUid` stays stale and
              // `signedIn` reads true while the store says otherwise — the
              // store/RAM disagreement §4 exists to prevent, living in the
              // composition root. While stale, a tap would write to
              // `checkins/{oldUid}` and the router would keep showing a main
              // screen to a signed-out user.
              ref.read(signedInUidProvider.notifier).signedOut();
              // Deliberately not tearing the alarms down here. §3: nothing
              // patches state incrementally, so "there are no links now" is
              // expressed by reconciling against an empty desired set — which
              // is what the restart below does.
              return 'signed out, links and cache cleared\n'
                  'RESTART the app to reconcile the alarms away.';
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
                // **The audience is read, not assumed.** The 21:00 body drops
                // its *"so your family knows you're well"* clause when nobody is
                // set up, and a harness that hard-coded either answer would show
                // a sentence this phone would never post — on the one control
                // whose whole justification is that what is verified is what
                // ships.
                final audience = WatchedAudience.from(
                  await services.store.linksWatching(services.selfUid),
                );
                await services.notifications.showNow(
                  id: AlarmIds.reminder(_testNotificationDay, slot),
                  title: NotificationCopy.reminderTitle,
                  body: NotificationCopy.reminderBody(
                    slot,
                    hasAudience: audience.isNotEmpty,
                  ),
                  channel: NotificationService.remindersChannel,
                );
                return 'posted ${slot.name} on the reminders channel'
                    '${audience.isEmpty ? " (no audience)" : ""}';
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
            _Action('Clear the simulated backend — back to Firestore', () async {
              await services.store.setSimulatedBackendRaw(null);
              // **This said "back to: read succeeds, holding nothing, which
              // produces a warning" until Phase 4, and that is no longer
              // what happens.** Clearing the row now hands the tier-1 read
              // to Firestore — the real one — so what follows depends on
              // what the backend actually holds rather than on a default
              // this file chose. Leaving the old words would have told the
              // next person the app was making a claim it was not.
              return 'the tier-1 read goes to Firestore again\n'
                  '${FirebaseBootstrap.describe}';
            }),
            _Action('Show the simulated backend', () async {
              final raw = await services.store.simulatedBackendRaw();
              return '${SimulatedBackend.decode(raw)}\n\nraw: ${raw ?? '(unset)'}';
            }),
          ]),

          _section('Watcher — reconcile', [
            _Action('Run the watcher reconcile', () async {
              final state = await services.watcherReconcile(watcherListShowing: false)
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
                  // ADR-0009's catch-up pointer. On the device this is the one
                  // value that says whether a gap is about to be caught up on,
                  // and it is not derivable from anything else on this panel:
                  // `standing` only holds days something was actually SAID
                  // about, so a day left unsettled looks identical to a day that
                  // never existed.
                  ..writeln('  decided    ${person.cache.lastDecidedDay ?? '-'}')
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
              await services.watcherReconcile(watcherListShowing: false)
                  .reconcile(selfUid: services.selfUid);
              final before = await _standing(services.store, services.selfUid);
              await services.watcherReconcile(watcherListShowing: false)
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
              await services.watcherReconcile(watcherListShowing: false)
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

              // Arms the window — and, being a real reconcile, also DECIDES and
              // posts. That is correct behaviour and it ruins this particular
              // test: the alarm would fire into a day whose warning is already
              // standing and say nothing, which looks exactly like the alarm
              // not working.
              //
              // So the decision state is reset immediately afterwards, leaving
              // the armed alarms alone. The alarm then becomes the FIRST thing
              // to decide this day, which is the whole point of the exercise.
              await services
                  .watcherReconcile(watcherListShowing: false)
                  .reconcile(selfUid: services.selfUid);

              for (final link
                  in await services.store.linksWatchedBy(services.selfUid)) {
                final cache = await services.store.watcherCache(link.id);
                for (final warnedDay in cache.warnedDays.toList()) {
                  await services.notifications
                      .cancelWarning(link.id, warnedDay);
                }
                await services.store
                    .saveWatcherCache(link.id, const WatcherCache.empty());
              }

              final hh = fireAt.hour.toString().padLeft(2, '0');
              final mm = fireAt.minute.toString().padLeft(2, '0');
              return '''
warning time set to $hh:$mm
armed, then the decision state reset so the ALARM decides first

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
              // Both sides, named by channel. Printing one number labelled
              // "delivery handed to the domain" was wrong from the moment the
              // watcher side went per-channel — and this screen is what someone
              // reads while diagnosing a muted channel on a device, so a
              // plausible-looking wrong number here costs more than none.
              final reminders = await services.permissions.reminderDelivery();
              final watcher = await services.notifications
                  .watcherDelivery(appInForeground: false);
              return '$snapshot\n\nreminders (watched): ${reminders.name}\n'
                  'watcher: $watcher';
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
