import 'dart:async';
import 'dart:math';

import 'package:timezone/timezone.dart' as tz;

import '../data/check_in_repository.dart';
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
    this.remindersAreExact = true,
    this.uses24Hour = true,
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

  /// Whether this device shows 24-hour times, as the reconcile read it.
  ///
  /// **Off the state, not off `MediaQuery`** — the twin of
  /// `WatcherState.uses24Hour`, and now for the same reason. The Tap screen has
  /// a `BuildContext` and read the live value, which was defensible while it was
  /// the only surface here rendering a time: nothing on the watched side is
  /// paired with a notification about the same instant, so there was nothing to
  /// drift against.
  ///
  /// It is off the state anyway, because the residual was not zero and the fix
  /// is. If the `LocalStore` write fails at launch, the live read and the cached
  /// one disagree, and this app has now paid twice for this one fact having two
  /// sources. One reader, one writer, on both sides.
  ///
  /// Defaults to true, matching `LocalStore.uses24HourClock` — the approved
  /// strings are 24-hour, so an uncached device renders what `screens.md` shows.
  final bool uses24Hour;

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

  /// How many reminders the **notification plugin** has a record of.
  ///
  /// Not the platform's answer — no public API can give that. Surfaced for the
  /// debug harness, where a disagreement with `LocalStore` means the two
  /// app-local records have drifted. See `AlarmScheduler`.
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

  /// False when exact alarms were refused and the reminders were armed
  /// **inexactly** — §13's documented degradation ("reminders degrade to
  /// inexact"), which Doze can then defer. A §13 health-panel row in Phase 7.
  final bool remindersAreExact;

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
        remindersAreExact: remindersAreExact,
        uses24Hour: uses24Hour,
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
    this.checkIns,
    this.selfUid = LocalStore.signedOutUid,
    this.lockOwner = 'ui',
  });

  final LocalStore store;
  final Clock clock;
  final AlarmScheduler alarms;

  /// Where a tap goes after it has been recorded locally (§7).
  ///
  /// **Nullable, and null is a real state rather than a missing dependency.**
  /// Nobody is signed in — so there is no `users/{uid}` to file a check-in
  /// under, and no link that could carry it to anyone. The tap is still recorded
  /// in `LocalStore` and the screen still says *"You already tapped today"*,
  /// because she did, and telling her otherwise would be the app lying about the
  /// one thing she did.
  ///
  /// It is also null in every test that does not care, which keeps the
  /// hundreds of existing ones honest: they assert the local half, which is the
  /// half that decides what the screen shows.
  final CheckInRepository? checkIns;

  /// Whose check-ins these are. [LocalStore.signedOutUid] when nobody is.
  ///
  /// Carried on the service rather than taken per call, unlike `reconcile`'s
  /// parameter, because the *write* needs it and the write happens inside
  /// [tap]. Passing it twice would be two chances for them to differ.
  final String selfUid;

  /// Names the caller in the reconcile lease, so a held lock is legible in a
  /// `dump()` instead of being an opaque token.
  ///
  /// Phase 3's alarm isolate passes `'alarm'` and Phase 4's FCM handler `'fcm'`.
  /// Exclusion itself does not key on this — the owner string appends the
  /// instant, so two runs from the same isolate are still distinct holders.
  final String lockOwner;

  /// Asked afresh on every reconcile rather than cached. Android can revoke
  /// `POST_NOTIFICATIONS` at any moment, including while the app is open —
  /// §13's whole argument is that permissions are continuously observed state.
  final Future<bool> Function() notificationsEnabled;

  /// How long a reconcile may hold the lock before anyone may take it.
  ///
  /// Long enough for the slowest legitimate run — Phase 4 adds a Firestore read
  /// with its own timeout inside this window — and short enough that a bare
  /// isolate killed mid-reconcile does not block the next one for a noticeable
  /// time. It is a lease, so the only cost of overshooting is a reconcile that
  /// declines to touch alarms once.
  static const Duration lockLease = Duration(seconds: 30);

  /// This side's lease scope. Disjoint from the watcher's — see
  /// [LocalStore.acquireReconcileLock] for what one shared lock cost.
  static const String lockScope = 'watched';

  /// Distinguishes this isolate's runs from another isolate's.
  ///
  /// **Randomness is correct here and would be a defect one file over.**
  /// `AlarmIds` must be a pure function of its inputs, because its output is
  /// handed to the platform and has to still mean the same thing in the next
  /// process — deriving it from a seeded hash is what stranded 54 alarms on the
  /// POCO. This value is the opposite kind of thing: an **ephemeral identity**,
  /// never persisted beyond a lease, never recomputed, and only ever compared
  /// for equality against itself. Two isolates must disagree about it, which is
  /// exactly what a random number guarantees and a derived one does not.
  static final int _isolateSalt = Random().nextInt(0x7fffffff);

  /// Distinguishes this isolate's runs from each other, since two can start
  /// inside the same microsecond and a clock-derived token would collide.
  static int _sequence = 0;

  /// Reconciles, and returns what the screen should show.
  ///
  /// ## Two halves, and only one of them takes the lock
  ///
  /// Reading state and returning it is **always** safe and always happens: the
  /// screen must render whether or not another isolate is mid-reconcile, and a
  /// caller that got no state would show the *"this phone could not get ready"*
  /// error for a condition that is not an error.
  ///
  /// Changing the alarm set is the half that races, so it is the half that is
  /// serialised. When the lock is already held, this returns the state it read
  /// and touches no alarms — correct, because whoever holds the lock is
  /// computing the same desired set from the same store and is about to assert
  /// it. `reconcile()` is idempotent, so skipping a redundant run costs nothing;
  /// running it concurrently strands an alarm that can never be cancelled.
  ///
  /// **This split is what makes the same lock safe on the watcher side**, where
  /// skipping outright would be dangerous: the alarm isolate must always reach
  /// its warn/don't-warn decision, because silence is the one failure this app
  /// cannot detect in itself. It is the *scheduling* it may skip, never the
  /// speaking.
  Future<WatchedState> reconcile({required String selfUid}) async {
    final now = clock.now();
    final zone = await _deviceZone();

    final links = await store.linksWatching(selfUid);
    final checkedIn = await store.checkedInDays();

    final owner = '$lockOwner:$_isolateSalt:${_sequence++}';
    final holdsLock = await store.acquireReconcileLock(
      scope: lockScope,
      owner: owner,
      now: now,
      lease: lockLease,
    );

    // Read AFTER the lock is settled. Reading before it means diffing against a
    // snapshot another isolate may already be replacing, which is the whole
    // defect. When the lock was not taken the value is still read and still fed
    // through the reconciler, because the result carries the audience the screen
    // needs — it is simply not applied.
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

    var exact = true;
    if (holdsLock) {
      try {
        // **toCancel before the desired set**, and the ordering is enforced
        // inside `AlarmScheduler.apply` rather than here, so no caller can get
        // it wrong.
        //
        // The whole `desired` set is handed over rather than `toSchedule`: a
        // force-stop clears every platform alarm without touching this store, so
        // a diff computed against the store would re-arm nothing and leave the
        // app permanently inert. Measured on hardware — see
        // `AlarmScheduler.apply`.
        exact = await alarms.apply(
          toCancel: result.toCancel,
          desired: result.desired,
        );

        // Recorded only after the platform calls returned. A crash in between
        // leaves the store believing less is armed than really is, which the
        // next reconcile repairs by scheduling over the same ids. The opposite
        // order would leave a reminder that never fires and nothing to notice
        // it.
        await store.replacePendingReminders(result.desired);
      } finally {
        // Released even if the platform threw, so one failure does not lock the
        // app out of its own alarms until the lease expires.
        await store.releaseReconcileLock(lockScope, owner);
      }
    }

    final today = DayKey.fromInstant(now, zone);
    return WatchedState(
      today: today,
      zone: zone,
      audience: result.audience,
      todayCheckIn: await store.checkInOn(today),
      away: null,
      notificationsEnabled: await notificationsEnabled(),
      armed: await alarms.armedAccordingToPlugin(),
      remindersAreExact: exact,
      // The same cached device fact the watcher side reads, and the same reason:
      // one source, so no two surfaces can disagree about the same instant.
      uses24Hour: await store.uses24HourClock(),
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
    final checkIn = CheckIn.forTap(now: now, zone: zone);
    await store.recordCheckIn(checkIn);

    // **Fired, not awaited, and the local record above is why that is safe.**
    //
    // Firestore's own persistence queues this and replays it when the connection
    // returns; the future it hands back completes only once the *server* has it.
    // Awaiting that on a phone with no signal would hang the tap — the one
    // action this app asks of an elderly person, on the screen whose entire job
    // is to work every morning. HANDOVER.md's instruction not to build a retry
    // queue is the same decision from the other side: the SDK is the queue.
    //
    // Errors are swallowed for the same reason. A write that cannot leave the
    // device is not a failed tap, and there is no honest message to show about
    // it here: the watcher's own reconcile is what notices a day that never
    // arrived, and it has four carefully distinguished ways of saying so.
    final repository = checkIns;
    if (repository != null && selfUid != LocalStore.signedOutUid) {
      unawaited(
        repository.write(selfUid, checkIn).catchError((Object _, StackTrace _) {}),
      );
    }

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
