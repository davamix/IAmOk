import 'dart:math';

import 'package:timezone/timezone.dart' as tz;

import '../copy/notification_copy.dart';
import '../data/check_in_reader.dart';
import '../data/local_store.dart';
import '../domain/domain.dart';
import '../platform/clock.dart';
import '../platform/notification_service.dart';
import '../platform/warning_alarm_scheduler.dart';

/// What a watcher's row is currently saying about one person — four mutually
/// exclusive states, in §10's own precedence.
///
/// Ordered as the decision is: a revoked link says nothing can be checked, a
/// refused read is a claim about **us**, a standing warning is a claim about
/// **her**, and *"Everything OK"* is what is left. See
/// [WatchedPersonState.rowKind] for why this is a named value rather than a
/// chain of `if`s in the widget.
enum WatchedRowKind { revoked, accessLost, warning, ok }

/// One watched person, as the watcher's screen renders them.
class WatchedPersonState {
  const WatchedPersonState({
    required this.link,
    required this.cache,
    required this.decision,
    this.zoneUnknown = false,
  });

  final Link link;
  final WatcherCache cache;

  /// This build's tzdata does not carry `link.watchedTimezone`, so her day was
  /// computed against the watcher's zone as a guess.
  ///
  /// **Per person, and not a device-wide setting.** It was one: a bool in
  /// `settings`, OR-ed across every link. §13's panel is the stated consumer and
  /// it has to name *which* person the app is guessing about — a bool cannot,
  /// and aggregating a per-link fact into one flag loses exactly the part that
  /// makes it actionable.
  ///
  /// Carried here rather than persisted in a new column because nothing needs it
  /// across a process boundary: every surface that would show it gets it from a
  /// live reconcile, and the underlying evidence — the zone string this build
  /// cannot resolve — is already in `links` and already in `dump`.
  final bool zoneUnknown;

  /// What the last reconcile concluded about `D`.
  final WarningDecision decision;

  String get name => link.watchedName;

  /// Whether the app currently cannot read this person's check-ins
  /// (ADR-0004). Drives the row that the *lost access* notification opens onto.
  bool get hasLostAccess => cache.hasLostAccess;

  /// A standing warning for the day this reconcile is **about**, or null.
  ///
  /// **State, not history** — `docs/ui-ux/guidelines.md`. A warning from three
  /// weeks ago followed by three weeks of check-ins is history, and rendering it
  /// as status would have the app reporting a crisis that resolved itself.
  ///
  /// **The first version wrote that rule in this comment and then broke it one
  /// line below**, falling back to the newest day in `warningsShownFor` when
  /// today's `D` had none. A day only leaves that map by a correction — a
  /// check-in *for that exact day* — or by revocation, so a genuinely missed day
  /// stays in it forever. Mum missing 1 August and tapping every day since
  /// produced a row reading **"No check-in from Mum yesterday."** on the 18th,
  /// permanently, suppressing "Everything OK", about a day she had checked in
  /// on. Every string in the set says *yesterday*, and only `decision.day` is
  /// yesterday — so only `decision.day` can be rendered honestly.
  ///
  /// It compounded: the outcome came from the old day while the interpolated
  /// values came from the current decision, so a stored `warnOffline` rendered
  /// *"your phone has not been able to check even once"* on a phone that had
  /// reconciled seconds earlier.
  ///
  /// The consequence is that the list shows **today only**, which settles
  /// `guidelines.md`'s open question about what a watcher sees on cold open
  /// after weeks away. Recorded in `screens.md`.
  ///
  /// ## Why the decision is a fallback, and not merely a tidier source
  ///
  /// `warningsShownFor` is a **delivery ledger** — §10 step 8's record of which
  /// message is standing in the tray. It answers *what did we say*, not *what is
  /// true about her*, and it is written only under
  /// `owed && delivery.warning.consumesReminder`.
  ///
  /// So on a phone that cannot post — the *Missed check-ins* channel switched
  /// off, or `POST_NOTIFICATIONS` auto-revoked from an app nobody opens, which
  /// §13 rates **High** precisely because that describes a watcher — the day is
  /// correctly *not* recorded, because nothing was delivered and the warning is
  /// still owed. The row then found nothing standing and rendered **"Everything
  /// OK"** about a relative who missed yesterday, on the one surface that
  /// watcher still had. A muted phone is exactly the phone whose screen has to
  /// carry the whole message.
  ///
  /// The same asymmetry was already resolved the other way one field along:
  /// `accessLostSince` is written **ungated**, with the reconciler's own comment
  /// saying a phone with notifications revoked "is precisely the phone whose
  /// panel must still be able to explain itself when it is next opened". The
  /// warning half had the opposite treatment and nothing caught it.
  ///
  /// So the ledger is consulted first — it can hold a *superseding* outcome a
  /// later silent reconcile would otherwise drop — and the current decision
  /// answers when the ledger is empty. A silent decision still yields null, so
  /// *"Everything OK"* survives for the days it is true of, and `warnAccessLost`
  /// never reaches here because the lost-access row outranks it.
  /// ## The ledger may only supply an outcome the current values can carry
  ///
  /// The **outcome** comes from the ledger while the row interpolates the
  /// **current decision's** values — `unverifiedSince`, `away`,
  /// `lastConfirmedDay`. That is the same compounding described above, surviving
  /// for the wrong-*values* case after the wrong-*day* case was closed.
  ///
  /// The path: the 10:00 alarm cannot reach the server, posts `warnOffline` and
  /// records it. The reader mutes *Missed check-ins*. A later reconcile succeeds
  /// online, decides `warnOnline`, and correctly does not update the ledger
  /// because nothing could be delivered. The row then renders `warnOffline` with
  /// a verified decision's null `unverifiedSince`:
  ///
  /// > No check-in received from Mum yesterday — your phone has not been able to
  /// > check even once.
  /// > This phone last checked Tuesday 10:14.
  ///
  /// Two adjacent lines contradicting each other, one of them false about the
  /// device.
  ///
  /// So an offline-shaped stored outcome gives way to the decision when the
  /// decision has no instant to render. The ledger's job is to preserve a
  /// *superseding* outcome, not to supply one the row cannot state honestly.
  WarningOutcome? get standingWarning {
    final stored = cache.warningsShownFor[decision.day];
    if (stored == null) return decision.isWarning ? decision.outcome : null;
    final needsInstant = stored == WarningOutcome.warnOffline ||
        stored == WarningOutcome.warnUnverifiableAway;
    if (needsInstant && decision.unverifiedSince == null) {
      return decision.isWarning ? decision.outcome : null;
    }
    return stored;
  }

  /// Whether this row has just gone from a standing warning to *"Everything
  /// OK"* **because a check-in arrived** — the one row change `screens.md`
  /// approves announcing to a screen reader (2026-08-25).
  ///
  /// ## Why the transition is not simply "the row got better"
  ///
  /// The approved string is *"Mum checked in. Everything OK."*, and the first
  /// half is a **claim about her**. A row can reach *"Everything OK"* from a
  /// standing warning without anybody tapping: a `warnUnverifiableAway` stops
  /// being renderable the moment a read succeeds — [standingWarning] falls back
  /// to the current decision, which is silent because the away covers `D` — and
  /// the row goes quiet with `lastConfirmedDay` exactly where it was. Announcing
  /// there would tell a family she checked in on a day she was away and did not.
  ///
  /// So the last clause asks the cache, not the row: the day the warning was
  /// **about** must now be confirmed. That is true for the case this exists for
  /// — the correction, where a late-syncing check-in for `D` arrives — and false
  /// for every way a warning can lapse without one.
  ///
  /// ## And the two states that outrank a warning are excluded on both sides
  ///
  /// A revoked link and ADR-0004's lost access render something else entirely
  /// (`watcher_screen.dart`), so a change into or out of either is a different
  /// sentence. `screens.md` lists *any → access lost* as a candidate that is
  /// deliberately **not** shipping, and its reverse was never proposed; neither
  /// may arrive by falling through this.
  bool checkedInSince(WatchedPersonState previous) {
    if (previous.rowKind != WatchedRowKind.warning) return false;
    if (rowKind != WatchedRowKind.ok) return false;

    // **The same day, on both sides.** [standingWarning] keys on each state's
    // own `decision.day`, so two unsolicited passes straddling a watched-local
    // midnight compare a warning about `D` against a check-in for `D + 1` — and
    // the guard below would pass on a day rollover rather than on a retraction.
    // Nothing false would be said, but it would be said for the wrong reason,
    // and to a reader who cannot glance at the row to discount it.
    if (decision.day != previous.decision.day) return false;

    // **The cache, not the row.** This is where *"Mum checked in"* is checked
    // against evidence instead of inferred from the row going quiet — see the
    // away case above.
    final confirmed = cache.lastConfirmedDay;
    return confirmed != null && confirmed >= previous.decision.day;
  }

  /// Which of the four mutually exclusive things this person's row says.
  ///
  /// **§10's step order, on the screen.** A revoked link outranks lost access,
  /// which outranks a standing warning, which outranks *"Everything OK"* — the
  /// same precedence the decision itself uses, for the same reasons.
  ///
  /// **It exists because that order was written out twice**: once in
  /// `_PersonRow._status()` and once inside [checkedInSince], with nothing
  /// keeping them in step. `screens.md` already commits Phase 6 to adding a
  /// branch above *"Everything OK"*, and if that branch lands above the warning
  /// case the two copies disagree silently — producing an announcement that does
  /// not match the row, for the one reader who cannot see the row to check.
  /// `AppServices.cacheDeviceFacts` carries this repo's own version of the rule:
  /// two copies of a decision are two chances to make it.
  ///
  /// It also lifts the precedence out of the widget, which is where it least
  /// belongs: it is §10's ordering, not a layout choice.
  WatchedRowKind get rowKind {
    if (link.status == LinkStatus.revoked) return WatchedRowKind.revoked;
    if (hasLostAccess) return WatchedRowKind.accessLost;
    final standing = standingWarning;
    return standing != null && standing != WarningOutcome.silent
        ? WatchedRowKind.warning
        : WatchedRowKind.ok;
  }
}

/// Everything the watcher's screen needs, as of one reconcile.
class WatcherState {
  const WatcherState({
    required this.people,
    required this.today,
    required this.watcherZone,
    required this.warningDelivery,
    required this.uses24Hour,
    this.unreconciled = const [],
    this.watcherZoneUnknown = false,
    this.userInitiated = true,
  });

  final List<WatchedPersonState> people;

  /// Links this pass could not reconcile at all.
  ///
  /// **In-band, because omitting them was a false claim.** The per-link guard
  /// keeps one bad link from costing every other watched person their check —
  /// but a link left out of [people] is invisible, and with a single link
  /// "short list" *is* "empty list": the screen rendered *"You're not looking
  /// after anyone."* about someone this watcher is very much still looking
  /// after, on the surface the *lost access* notification routes to. That is
  /// the same false all-clear the revoked row was fixed for, arriving by a
  /// route the isolation opened.
  ///
  /// Carried as the [Link] rather than a half-built [WatchedPersonState],
  /// because nothing about this person's state was successfully computed and a
  /// row assembled from a failed reconcile is exactly what must not be shown.
  /// The name is all the row needs, and it comes off the link.
  final List<Link> unreconciled;

  final DayKey today;

  /// Whether this device shows 24-hour times, as the reconcile read it.
  ///
  /// **Off the state, not off `MediaQuery`.** The screen has a `BuildContext`
  /// and could read the live value — and did, which gave one fact two sources:
  /// the row and the notification produced by the SAME reconcile could disagree
  /// about the same instant. That is the drift `momentLabel` and `dayLabel`
  /// were exposed to prevent, since the reader compares the two directly.
  ///
  /// The reconcile reads it from `LocalStore`, where `ClockService` caches it on
  /// every launch and every resume — the same round trip the device zone makes,
  /// and for the same reason: the alarm isolate has no widget tree to ask.
  final bool uses24Hour;

  /// Whether a warning decided now would actually reach this reader.
  ///
  /// **On screen because when it is [NotificationDelivery.unavailable], the
  /// screen is the only delivery there will ever be.** The row still shows the
  /// warning — that is what it is true of, whether or not a notification
  /// happened — but nothing told the reader that this is the last time they
  /// will find out by looking. They deal with it, close the app, and go on
  /// believing they will be warned next time.
  ///
  /// §13 rates `POST_NOTIFICATIONS` revocation High precisely because Android
  /// takes it from apps nobody opens, which describes a watcher exactly. The
  /// watched side has had a banner for this since Phase 2, where the cost is a
  /// missed nudge; this side had nothing, where the cost is a family not being
  /// warned at all.
  final NotificationDelivery warningDelivery;

  /// Whether to show the banner. `redundant` is not a fault — it means the
  /// reader is looking at this screen, which is the good case.
  bool get warningsSilenced =>
      warningDelivery == NotificationDelivery.unavailable;

  /// **The watcher's own zone, not the watched person's.**
  ///
  /// Every time this screen renders is a claim about *this device* — *"This
  /// phone last checked Tuesday 10:14"*, *"your phone has been offline since
  /// …"* — so it must be shown in the zone of the person reading it. The screen
  /// had no other way to reach it and used `link.watchedZone`, which is a
  /// different question entirely: a watcher in London watching Mum in Madrid saw
  /// the row and the notification give different times for the same instant,
  /// and different weekdays across midnight.
  final tz.Location watcherZone;

  /// [watcherZone] is the **UTC fallback**, not the device's real zone.
  ///
  /// Either nothing has been cached yet, or the platform named a zone this
  /// build's tzdata does not carry. Every warning alarm on this device is then
  /// armed at `warningLocalTime` UTC — up to twelve hours out, and permanently,
  /// since nothing about it self-heals.
  ///
  /// The twin of [WatchedPersonState.zoneUnknown] on this side, and carried for
  /// the same stated reason: a fault the app cannot see is a fault nobody will
  /// ever fix. §13's panel reads both in Phase 7; until then it is in the state
  /// the screen already receives.
  final bool watcherZoneUnknown;

  /// Whether the person reading the screen **asked** for this pass.
  ///
  /// The twin of `WatchedStateNotifier.refresh`'s parameter, on the side where
  /// the cost of an unasked-for rebuild is the opposite one: there a reconcile
  /// she did not trigger *removed* a line she needed, here one nobody triggered
  /// *replaces* a line without saying so.
  ///
  /// False today only for a foreground FCM nudge. It decides one thing — whether
  /// a row that changed under a screen reader is announced — because nothing
  /// re-reads a changed widget, so a TalkBack reader who heard *"Mum. No
  /// check-in from Mum yesterday."* is left looking at *"Everything OK"* with no
  /// announcement, no reason to swipe back, and no notification ever coming.
  ///
  /// **Defaults to true, and the direction is deliberate.** A pass that says
  /// nothing about how it was triggered is treated as one the reader asked for,
  /// which announces nothing — the silent, safe answer. Announcing every refresh
  /// is noise, and on a resume the reader is arriving at the screen and will
  /// read the row themselves.
  ///
  /// Set by `WatcherStateNotifier`, never by the reconcile, which has no way to
  /// know why it was called. See `docs/ui-ux/screens.md`.
  final bool userInitiated;

  /// Nobody is being watched — **not** "nothing could be rendered".
  ///
  /// [unreconciled] counts, or a watcher whose only link failed is told they
  /// are looking after nobody.
  bool get isEmpty => people.isEmpty && unreconciled.isEmpty;

  /// Narrow on purpose, exactly as `WatchedState.copyWith` is: the only thing a
  /// caller may restate about a finished reconcile is how it was triggered,
  /// which is the one fact the reconcile itself cannot know.
  WatcherState copyWith({bool? userInitiated}) => WatcherState(
        people: people,
        today: today,
        watcherZone: watcherZone,
        warningDelivery: warningDelivery,
        uses24Hour: uses24Hour,
        unreconciled: unreconciled,
        watcherZoneUnknown: watcherZoneUnknown,
        userInitiated: userInitiated ?? this.userInitiated,
      );
}

/// The watcher side's one idempotent entry point — **reconcile first, then
/// decide** (§10, ADR-0001).
///
/// Called on app open, on alarm fire, on boot, and from Phase 4's FCM handler.
/// The alarm isolate and the UI both land here, which is why nothing in it may
/// touch Flutter, Riverpod or `flutter_timezone`; `domain_purity_test.dart`
/// names this file.
///
/// ## The order is the design
///
/// 1. Attempt the tier-1 read. **Before** any cache is consulted — consulting
///    the cache first inverts §3's tiering and lets a stale cached away silence
///    a watcher for as long as the period has left to run. Sixteen days in
///    ADR-0001's modelled scenario, in a state §17 rates as indistinguishable
///    from working.
/// 2. Hand the read, the cache and the link to the pure reconciler.
/// 3. Execute what it decided: post, correct, withdraw, arm, disarm.
/// 4. Persist the cache it returned — **one write**.
///
/// The decision itself is `WatcherReconciler` + `WarningPolicy`, both pure and
/// both fully tested without a device. That separation is what lets the riskiest
/// logic in the app be exercised in milliseconds.
///
/// **This class decides nothing about *what* to say.** It carries out what the
/// reconciler decided, and it makes exactly **one** substitution to an input on
/// the way in: [WatcherDelivery.notBefore], which holds the warning channel
/// until the watcher's chosen hour (ADR-0010). That changes when a decision may
/// be *spoken*, never what was decided — the gate is not an input to
/// `WarningPolicy` at all, so a held run reaches the same conclusion as an
/// unheld one and simply does not post it.
///
/// This docstring used to say the class *"contains no branch that decides
/// whether to speak"*, which stopped being true the moment that substitution
/// landed — and it was the sentence that would otherwise have stopped someone
/// adding a second one. So, plainly: **one is the budget.** Anything further
/// that decides whether to speak belongs in Domain, as a pure function over
/// explicit inputs, where it can be tested in milliseconds and mutation-checked.
class WatcherReconcileService {
  const WatcherReconcileService({
    required this.store,
    required this.clock,
    required this.reader,
    required this.notifications,
    required this.alarms,
    required this.delivery,
    this.lockOwner = 'ui',
  });

  final LocalStore store;
  final Clock clock;
  final CheckInReader reader;
  final WatcherNotifications notifications;
  final WarningAlarmScheduler alarms;

  /// Whether a notification decided now would actually reach anyone.
  ///
  /// Asked afresh on every reconcile, never cached: Android can revoke
  /// `POST_NOTIFICATIONS` at any moment and auto-revokes it from apps nobody
  /// opens — which §13 rates High precisely because that describes the watcher.
  ///
  /// **The Phase 2 brief's "until they exist, pass `available`" no longer
  /// applies.** Passing a constant here re-opens the defect
  /// `NotificationDelivery` was added to close: the access-lost cadence burns
  /// days 0, 1, 3, 7 and 14 in silence on a muted phone, and access returning on
  /// day 20 owes nothing until day 21.
  ///
  /// **One state per channel** — see [WatcherDelivery]. The two notices this
  /// side posts live on channels the reader switches off independently, which is
  /// the whole reason ADR-0004 separated them.
  final Future<WatcherDelivery> Function() delivery;

  final String lockOwner;

  static const Duration lockLease = Duration(seconds: 30);

  /// This side's lease scope. Disjoint from the watched side's: the two
  /// reconcile different links into different alarm ids and cannot conflict, and
  /// making them share one lock left one side unarmed on every launch.
  static const String lockScope = 'watcher';

  static final int _isolateSalt = Random().nextInt(0x7fffffff);
  static int _sequence = 0;

  /// Reconciles every link this user watches, and returns what to render.
  ///
  /// Every link, on every fire, rather than the one link an alarm was armed
  /// for. §3: nothing is transmitted as a command — an alarm fire is a *nudge to
  /// reconcile*, carrying no authority about which person it concerns. Keying
  /// the work to the alarm's own id would mean a single dropped alarm leaves one
  /// watched person unreconciled with nothing to notice it.
  Future<WatcherState> reconcile({required String selfUid}) async {
    final now = clock.now();
    final watcher = await _watcherZone();
    final watcherZone = watcher.zone;
    // The device's 12h/24h preference, off disk for the same reason the zone is
    // (ADR-0002): this runs in an isolate with no `MediaQuery` to ask.
    final uses24Hour = await store.uses24HourClock();
    final links = await store.linksWatchedBy(selfUid);
    final canDeliver = await delivery();

    final owner = '$lockOwner:$_isolateSalt:${_sequence++}';
    final holdsLock = await store.acquireReconcileLock(
      scope: lockScope,
      owner: owner,
      now: now,
      lease: lockLease,
    );

    final people = <WatchedPersonState>[];
    var anyLinkFailed = false;
    final unreconciled = <Link>[];
    try {
      for (final link in links) {
        // **One link's failure must not cost every other watched person their
        // check.**
        //
        // The argument was already written out for the timezone case — a throw
        // from `link.watchedZone` would abort the pass inside an isolate with no
        // screen, no user and nothing that reports a throw, and the only symptom
        // is silence. That fix removed one *instance*; the class is wider. A
        // malformed `watcher_cache` row (`DayKey.parse`, `LocalTimeOfDay.parse`
        // both throw), a plugin fault in `showWarning`, a binder failure in
        // `alarms.apply` — each aborts the loop identically. Links come back
        // ordered by id, so one persistently failing link starves every link
        // after it alphabetically, forever, and nothing anywhere says so.
        //
        // Cheap today, with one link. It stops being cheap the moment pairing
        // lands in Phase 5, and by then the failure is invisible and permanent.
        //
        // The person is **not rendered from a half-built value** — a row
        // assembled out of a failed reconcile is exactly the false claim this
        // side spends everything avoiding. They go into `unreconciled` instead,
        // which the screen renders as its own row, because a link merely left
        // out of the list is invisible and with one link makes the screen say
        // the reader is looking after nobody.
        try {
          people.add(await _reconcileLink(
            link: link,
            now: now,
            watcherZone: watcherZone,
            delivery: canDeliver,
            uses24Hour: uses24Hour,
            mayChangeAlarms: holdsLock,
          ));

        } on Object {
          anyLinkFailed = true;
          // In the returned state, not merely counted — see
          // [WatcherState.unreconciled].
          unreconciled.add(link);
        }
      }
    } finally {
      if (holdsLock) await store.releaseReconcileLock(lockScope, owner);
    }

    // **Guarded, because these sit outside the per-link isolation above.** A
    // throw here — a full disk, a busy database — would abort `reconcile()`
    // after every notification had been posted and every cache written, and in
    // the alarm isolate that throw reaches nobody. The paragraph above argues
    // that a failure must not cost the pass; these two writes were the one place
    // that could still do it.
    //
    // Device-wide and written on every pass, so both clear themselves once the
    // condition is gone. A fault the app cannot see is a fault nobody will ever
    // be told about — §13's panel reads them in Phase 7; until then they are in
    // `dump`.
    //
    // `link_reconcile_failed` is deliberately **not** per-link, unlike the zone
    // guess: the thing that failed may be `watcher_cache` itself, so writing the
    // flag into that table could throw for the same reason it is being set.
    try {
      await store.setLinkReconcileFailed(anyLinkFailed);
    } on Object {
      // Nothing here is worth the pass.
    }

    return WatcherState(
      people: people,
      today: DayKey.fromInstant(now, watcherZone),
      watcherZone: watcherZone,
      watcherZoneUnknown: watcher.unknown,
      warningDelivery: canDeliver.warning,
      uses24Hour: uses24Hour,
      unreconciled: unreconciled,
    );
  }

  /// One person, reconciled.
  Future<WatchedPersonState> _reconcileLink({
    required Link link,
    required DateTime now,
    required tz.Location watcherZone,
    required WatcherDelivery delivery,
    required bool mayChangeAlarms,
    required bool uses24Hour,
  }) async {
    // 1. Tier 1 first. A failed read is a value, never a throw — the difference
    //    between "could not reach" and "was refused" is the whole of ADR-0004,
    //    and an exception collapses it to one bit.
    final read = await reader.read(link);

    final cache = await store.watcherCache(link.id);
    final armed = await store.pendingWarnings(link.id);

    final result = WatcherReconciler.reconcile(
      now: now,
      link: link,
      watcherZone: watcherZone,
      cache: cache,
      read: read,
      currentlyScheduled: armed,
      // **The one substitution this class makes to a decided input**, and it is
      // per link because `warningLocalTime` is. See [WatcherDelivery.notBefore]
      // for why it lives in the domain and why the call stays here.
      delivery: delivery.notBefore(link.warningLocalTime,
          now: now, watcherZone: watcherZone),
    );

    // 2. Corrections FIRST, before any new warning is posted.
    //
    //    They replace a standing warning at the same id, so a correction applied
    //    after a fresh warning for the same day would silently overwrite the
    //    warning that was just, correctly, raised. The domain never produces
    //    both for one day — a corrected day leaves `warningsShownFor` — but the
    //    ordering is free and the failure it prevents is a false all-clear.
    //
    //    **Spoken only when the warning channel can carry it**, and taken down
    //    silently otherwise. A correction is meaningful only against the warning
    //    it retracts, and `redundant` means that warning was never posted at all
    //    — the watcher was reading the list — so the replacement would arrive
    //    alone, telling someone at 3am that a warning they never saw has been
    //    withdrawn. `unavailable` cannot post it in any case. Cancelling needs
    //    no permission and is a no-op when nothing is showing, so both paths end
    //    with an empty tray, which is the honest state. See
    //    [WatcherReconcileResult.shouldPostCorrections].
    //
    //    **[WatcherDelivery.notBefore] is a third route in, and it is not the
    //    same case.**
    //    There the warning really was posted and really was read, so the
    //    retraction is genuinely given up rather than merely redundant: the
    //    false claim comes down silently and no sentence says it was withdrawn.
    //    That is the quieter of the two errors at 00:24 — a correction is good
    //    news, and good news may not wake a family — and the row still renders
    //    the truth for whoever opens the app. Named here rather than left to be
    //    inferred from a shared field.
    for (final correction in result.corrections) {
      if (!result.shouldPostCorrections) {
        await notifications.cancelWarning(correction.linkId, correction.day);
        continue;
      }
      await notifications.showCorrection(
        linkId: correction.linkId,
        day: correction.day,
        body: NotificationCopy.correctionBody(
          watchedName: link.watchedName,
          // The day being retracted, and the day this reconcile is about. A
          // correction is emitted for EVERY standing warning the read confirms,
          // not only yesterday's, so the message has to name which one — see
          // [NotificationCopy.correctionBody].
          day: correction.day,
          today: DayKey.fromInstant(now, watcherZone),
          uses24Hour: uses24Hour,
          // **Null, deliberately.** The approved string ends *"at 23:40"*, and
          // that is a claim about the moment SHE tapped. Phase 3's fake backend
          // carries no per-check-in timestamp, so the only instant available
          // here is `now` — the moment this device happened to read it, which on
          // a phone that was asleep, offline, or simply not opened until morning
          // is hours out and occasionally the wrong day. Telling a family "Mum
          // checked in at 09:02" when she tapped at 23:40 the night before is a
          // fabricated fact about a person, on the message whose entire purpose
          // is to correct one.
          //
          // So the time is omitted and `correctionBody` renders the no-time
          // variant recorded in `screens.md`. The retraction is complete
          // without it; the time was never what made it true.
          //
          // **This said "until Phase 4 carries `deviceTappedAt` through the
          // read", and Phase 4 did not.** `FirestoreCheckInReader` returns a
          // `Set<DayKey>` and nothing more, so the instant is still unavailable
          // here — the check-in document holds it and the reader discards it.
          // Carrying it through is a change to the reader's shape, the cache and
          // the copy, so it is recorded as owed rather than smuggled in beside a
          // measurement. The no-time variant stays correct meanwhile.
          tappedAt: null,
          watcherZone: watcherZone,
        ),
      );
    }

    // 3. Withdrawals: cancelled outright, with no replacement message.
    //    Nothing here disproves the warning — the link was revoked — so a
    //    correction would claim she checked in, which the device cannot support.
    for (final day in result.withdrawnWarnings) {
      await notifications.cancelWarning(link.id, day);
    }

    if (result.cancelAccessLostNotice) {
      await notifications.cancelAccessLost(link.id);
    }

    // 4. The warnings — the one for today if it is owed, and the days ADR-0009
    //    caught up on, **oldest first**.
    //
    //    `shouldNotify` and `catchUpWarnings` already fold in the delivery
    //    state; re-deciding here would be a second opinion about a question the
    //    domain answered. They are disjoint by construction — `shouldNotify` is
    //    about `D`, every catch-up entry is strictly older — so this posts each
    //    day exactly once, at its own notification id.
    //
    //    Oldest first so the newest sits at the top of the shade, which is where
    //    a reader looks first and is the day most likely to still be actionable.
    for (final decision in [
      ...result.catchUpWarnings,
      if (result.shouldNotify) result.decision,
    ]) {
      final body = NotificationCopy.warningBody(
        outcome: decision.outcome,
        watchedName: link.watchedName,
        day: decision.day,
        away: decision.away,
        unverifiedSince: decision.unverifiedSince,
        lastConfirmedDay: decision.lastConfirmedDay,
        // The reader's today, which is what decides whether the body may say
        // "yesterday" — see [NotificationCopy.warningBody]. A catch-up day never
        // may, and that is the whole reason the copy changed.
        today: DayKey.fromInstant(now, watcherZone),
        uses24Hour: uses24Hour,
        watcherZone: watcherZone,
      );
      if (decision.outcome == WarningOutcome.warnAccessLost) {
        // A different channel, deliberately: a watcher who mutes app faults must
        // still hear about a missed day (ADR-0004).
        //
        // Only ever reached for `D`. Access loss is a fact about the READ, and
        // the refused branch of the reconciler never fills `catchUpWarnings` —
        // it does not even advance ADR-0009's pointer, so the days spent refused
        // are caught up on later, once a successful read can say something about
        // her rather than about us.
        await notifications.showAccessLost(linkId: link.id, body: body);
      } else {
        await notifications.showWarning(
          linkId: link.id,
          day: decision.day,
          body: body,
        );
      }
    }

    // 5. The alarm window — only under the reconcile lease (ADR-0006).
    //
    //    **The decision above is never skipped; only this is.** A run that
    //    cannot take the lock has still read, still decided and still spoken,
    //    which is what makes the lease safe on the side where silence is the
    //    failure that cannot be detected. Two concurrent runs changing the alarm
    //    set is what strands an alarm nothing can cancel.
    if (mayChangeAlarms) {
      final exact = await alarms.apply(
        linkId: link.id,
        toCancel: result.warningsToCancel,
        desired: result.desiredWarnings,
      );
      await store.replacePendingWarnings(link.id, result.desiredWarnings);
      // The return value was previously dropped on the floor, which made the
      // scheduler's fallback unobservable: the alarms are armed either way, so
      // nothing anywhere distinguished a window that fires at 10:00 from one
      // Android may defer for an hour or more. §13 calls that degradation
      // acceptable *and surfaced*; only the first half had been built.
      //
      // Recorded whenever any alarm was actually armed. An empty desired set —
      // a revoked link — arms nothing, so it has no opinion about exactness and
      // must not overwrite the answer a real window gave.
      if (result.desiredWarnings.isNotEmpty) {
        await store.setWarningAlarmsExact(exact);
      }
    }

    // 6. One write, after the platform calls returned.
    await store.saveWatcherCache(link.id, result.cache);

    return WatchedPersonState(
      link: link,
      cache: result.cache,
      decision: result.decision,
      zoneUnknown: result.watchedZoneUnknown,
    );
  }

  /// The watcher's own cached zone, falling back to UTC — and **whether that
  /// fallback was taken**.
  ///
  /// Read from `LocalStore`, never from `flutter_timezone` — this runs in the
  /// alarm isolate and ADR-0002 decision 2 forbids a plugin call there. The
  /// **watched** person's zone is a different question and comes off the link,
  /// which is why no plugin is touched on this path at all.
  ///
  /// ## Why the fallback is now reported rather than only taken
  ///
  /// ADR-0002 accepts a **stale** watcher zone, correctly: it cannot affect `D`,
  /// which uses the watched person's zone from the link. It does not consider an
  /// **unresolvable** one, and the cost is different in kind. `ClockService`
  /// returns null when the platform names a zone this build's pinned tzdata does
  /// not carry, `main()` then stores nothing, and every warning alarm on the
  /// device is armed at `warningLocalTime` **UTC** — up to twelve hours off, on a
  /// dead man's switch, permanently, because nothing about it heals.
  ///
  /// The symmetric case on the *watched* side is already carried:
  /// `WatchedPersonState.zoneUnknown` exists for exactly this, with the argument
  /// that a fault the app cannot see is a fault nobody will ever fix. The
  /// watcher's own zone got the fallback and not the flag. §13's panel is the
  /// Phase 7 consumer of both.
  Future<({tz.Location zone, bool unknown})> _watcherZone() async {
    final name = await store.deviceTimezone();
    if (name == null) return (zone: TimeZones.utc, unknown: true);
    final resolved = TimeZones.tryLocation(name);
    return resolved == null
        ? (zone: TimeZones.utc, unknown: true)
        : (zone: resolved, unknown: false);
  }
}
