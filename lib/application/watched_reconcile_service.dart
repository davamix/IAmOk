import 'package:timezone/timezone.dart' as tz;

import '../data/local_store.dart';
import '../domain/domain.dart';
import '../platform/alarm_scheduler.dart';
import '../platform/clock.dart';

/// Everything the Tap screen needs to render, as of one reconcile.
class WatchedState {
  const WatchedState({
    required this.today,
    required this.zone,
    required this.audience,
    required this.todayCheckIn,
    required this.away,
    required this.notificationsEnabled,
    required this.armed,
    this.tapFailed = false,
  });

  /// Today in the **device's** zone. The watched person's own zone is the
  /// device's, because they are the one tapping (§11).
  final DayKey today;

  /// The zone [today] was computed in.
  ///
  /// Carried so the screen can schedule its own midnight refresh against the
  /// same zone the reconcile used, rather than reaching for the device's
  /// current one and disagreeing with itself.
  final tz.Location zone;

  /// Who will be notified when she taps — and the only thing this screen says
  /// about watchers. See [WatchedAudience].
  final WatchedAudience audience;

  /// Today's tap, or null if it has not happened.
  ///
  /// The tap target is disabled while this is non-null and re-enables when
  /// [today] rolls over, which is why the whole state is recomputed on resume
  /// rather than a boolean being flipped and remembered.
  final CheckIn? todayCheckIn;

  final AwayPeriod? away;

  /// False when `POST_NOTIFICATIONS` is revoked — §13's hard gate, and the app
  /// is inert without it.
  final bool notificationsEnabled;

  /// How many reminders the platform actually holds.
  ///
  /// Surfaced for the debug harness, where the interesting number is the one
  /// that disagrees with the store.
  final int armed;

  /// The last tap did not save.
  ///
  /// Carried **on the state** rather than thrown, so a failed tap shows one
  /// line beneath a target that stays on screen and stays enabled. Routing it
  /// through the provider's error channel replaced the whole screen at the
  /// exact moment she taps — her one action vanished, and the message said the
  /// phone could not get ready, which was not even true: the phone was ready
  /// and the check-in did not save.
  final bool tapFailed;

  bool get hasTappedToday => todayCheckIn != null;

  WatchedState copyWith({bool? tapFailed}) => WatchedState(
        today: today,
        zone: zone,
        audience: audience,
        todayCheckIn: todayCheckIn,
        away: away,
        notificationsEnabled: notificationsEnabled,
        armed: armed,
        tapFailed: tapFailed ?? this.tapFailed,
      );

  bool get isAway => away != null && away!.covers(today);
}

/// The watched side's one idempotent entry point (§3 — *reconcile, don't
/// mutate*).
///
/// Called on app open, on check-in, on boot, and from the debug harness. It
/// reads current state, asks the domain what **should** exist, and makes the
/// platform match. No path in this app incrementally patches an alarm; that is
/// what collapses reboot, clock change, timezone change and away transitions
/// into one code path instead of seven.
///
/// The clock is read **once**, here, and passed down as a value. The domain
/// never reads it — and this file's name contains `reconcile` deliberately, so
/// the widened purity guard in `test/domain/domain_purity_test.dart` covers it:
/// the rule is *no clock read in a policy or a reconciler anywhere*, not merely
/// inside `lib/domain/`.
class WatchedReconcileService {
  const WatchedReconcileService({
    required this.store,
    required this.clock,
    required this.alarms,
    required this.notificationsEnabled,
  });

  final LocalStore store;
  final Clock clock;
  final AlarmScheduler alarms;

  /// Asked afresh on every reconcile rather than cached. Android can revoke
  /// `POST_NOTIFICATIONS` at any moment, including while the app is open —
  /// §13's whole argument is that permissions are continuously observed state.
  final Future<bool> Function() notificationsEnabled;

  /// Reconciles, and returns what the screen should show.
  Future<WatchedState> reconcile({required String selfUid}) async {
    final now = clock.now();
    final zone = await _deviceZone();

    final links = await store.linksWatching(selfUid);
    final checkedIn = await store.checkedInDays();
    final pending = await store.pendingReminders();

    final result = WatchedReconciler.reconcile(
      now: now,
      watchedZone: zone,
      // Phase 6 reads this from `self_away`; every Phase 2 call site passes
      // null, which is exactly the arrangement PLAN.md mandates for the `away`
      // argument — the parameter exists from the first line so that retrofitting
      // it later does not touch every call site and every test.
      away: null,
      checkedInDays: checkedIn,
      currentlyScheduled: pending,
      links: links,
    );

    // **toCancel before toSchedule**, and the ordering is enforced inside
    // `AlarmScheduler.apply` rather than here, so no caller can get it wrong.
    await alarms.apply(
      toCancel: result.toCancel,
      toSchedule: result.toSchedule,
    );

    // Recorded only after the platform calls returned. A crash in between
    // leaves the store believing less is armed than really is, which the next
    // reconcile repairs by scheduling over the same ids. The opposite order
    // would leave a reminder that never fires and nothing to notice it.
    await store.replacePendingReminders(result.desired);

    final today = DayKey.fromInstant(now, zone);
    return WatchedState(
      today: today,
      zone: zone,
      audience: result.audience,
      todayCheckIn: await store.checkInOn(today),
      away: null,
      notificationsEnabled: await notificationsEnabled(),
      armed: await alarms.armedOnPlatform(),
    );
  }

  /// Records a tap and reconciles, which cancels the rest of today's reminders.
  ///
  /// **Belt and braces** (§10): the tap cancels the pending reminders through
  /// the reconcile below (the fast path), and each reminder is display-only so
  /// there is nothing to verify at fire time. On the watcher side the same
  /// principle needs both halves; here the second half is unnecessary precisely
  /// because a spurious reminder costs nothing.
  Future<WatchedState> tap({required String selfUid}) async {
    final now = clock.now();
    final zone = await _deviceZone();

    // The day is decided **here, on the device, at tap time** — §11. Deriving
    // it from a server timestamp would file a 23:50 tap that synced at 08:00 on
    // the following day, which §17 rates "High — silently wrong data".
    await store.recordCheckIn(CheckIn.forTap(now: now, zone: zone));

    return reconcile(selfUid: selfUid);
  }

  /// The device's cached IANA zone, falling back to UTC.
  ///
  /// Read from `LocalStore`, never from `flutter_timezone` — this same service
  /// runs from the boot entry point, and ADR-0002 decision 2 forbids a plugin
  /// call there. The UI refreshes the cached value on every resume.
  ///
  /// The UTC fallback is reachable only before the first resume has ever
  /// completed, i.e. on a store with nothing in it. It is deliberately not a
  /// throw: a bare isolate that cannot name the zone should still arm
  /// *something* rather than nothing, and the next UI resume corrects it.
  Future<tz.Location> _deviceZone() async {
    final name = await store.deviceTimezone();
    if (name == null) return TimeZones.utc;
    return TimeZones.tryLocation(name) ?? TimeZones.utc;
  }
}
