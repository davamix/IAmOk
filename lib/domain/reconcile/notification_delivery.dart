/// Whether a notification the domain decides is owed can actually be
/// **delivered** — and therefore whether the reminder it satisfies may be
/// consumed.
///
/// ## Why the domain is told this at all
///
/// Before this existed, `WatcherReconciler` recorded a message as *shown* at the
/// moment it decided one was *owed*. It had no way to know whether the platform
/// posted anything, so "we decided to speak" and "the watcher was told" were the
/// same fact. They are not.
///
/// The mild case is cosmetic — a reminder lands while the watcher already has
/// the app open, showing the same thing twice.
///
/// **The sharp case is `POST_NOTIFICATIONS` being revoked**, which §13 rates
/// High precisely because it happens to watchers who never open the app. The
/// alarm isolate still fires, still reconciles, and still marked each reminder
/// consumed. Nothing was shown. For the *daily* warning that self-heals — a new
/// day `D` gets a fresh attempt — but **the access-lost cadence does not**: days
/// 0, 1, 3, 7 and 14 are each silently consumed, and if permissions return on
/// day 20 the next reminder is day 21. A cadence built to survive a *sleeping*
/// device did not survive a *muted* one.
///
/// ## Why it is a value, not a port
///
/// This is passed in exactly as `now`, `away` and `watcherZone` already are.
/// Every parameter the reconciler takes is a plain value supplied by the layer
/// above, so this adds no import, no coupling and no I/O, and it is tested by
/// passing a value. The domain stays pure.
///
/// ## Why three states and not a bool
///
/// "Could not" and "chose not to" must behave differently — the same shape of
/// mistake [ADR-0004][] corrected when it split a failed read into *unreachable*
/// and *refused*. A bool here would force the foreground case and the revoked
/// case to share behaviour, and only one of them means the watcher was left
/// uninformed.
///
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
enum NotificationDelivery {
  /// Normal. The notification will be posted, and the reminder it satisfies is
  /// consumed.
  available,

  /// The watcher is looking at the screen that already shows this, so posting
  /// would tell them something they can see.
  ///
  /// **Consumed anyway** — they have been informed, which is what the record is
  /// actually tracking. `reconcile()` runs on app open, so this is reached
  /// routinely rather than exceptionally: a cadence day can otherwise post a
  /// notification to someone already reading the answer.
  redundant,

  /// Nothing can be posted — `POST_NOTIFICATIONS` is revoked.
  ///
  /// **Not consumed.** Nothing was delivered, so nothing is owed-off, and the
  /// same reminder is still due at the next reconcile. This is the state the
  /// whole enum exists for: without it a muted phone burns its way through the
  /// access-lost cadence in silence and then has nothing left to say when
  /// permissions come back.
  unavailable;

  /// The state implied by the two facts the platform edge can observe.
  ///
  /// **The branch order is a decision, not plumbing**, which is why it lives
  /// here rather than in `PermissionService` behind a `Future`. Testing
  /// `canPost` *first* is what makes a watcher whose `POST_NOTIFICATIONS` is
  /// revoked come out [unavailable] even while the app is open — and the app
  /// being open is exactly when `reconcile()` definitely runs. Testing
  /// [appInForeground] first would return [redundant] for that watcher, consume
  /// the reminder, and reopen the very defect this enum was added to close.
  ///
  /// A 2×2 truth table with one interesting cell, and it is cheaper to assert
  /// than to argue about.
  factory NotificationDelivery.from({
    required bool canPost,
    required bool appInForeground,
  }) {
    if (!canPost) return NotificationDelivery.unavailable;
    return appInForeground
        ? NotificationDelivery.redundant
        : NotificationDelivery.available;
  }

  /// Whether a notification decided now would actually be posted.
  bool get postsNotification => this == NotificationDelivery.available;

  /// Whether the reader has been informed, and the reminder may therefore be
  /// recorded as served.
  ///
  /// True for [redundant] as well as [available]: seeing it on screen is being
  /// told. False only for [unavailable], where nothing reached anyone.
  bool get consumesReminder => this != NotificationDelivery.unavailable;
}

/// The delivery state of **each** notice the watcher side can post.
///
/// ## Why one value was not enough
///
/// The watcher side posts on two Android channels, and [ADR-0004][] made that
/// split load-bearing: the missed-day warning is a claim about *her*, the
/// access-lost notice is a claim about *us*, and a watcher who mutes app faults
/// must still hear about a missed day. Channels are the unit Android gives the
/// user for switching us off, so they are switched off independently.
///
/// The first version measured `canPost` once — on the warnings channel — and
/// handed the single answer to both branches. Both directions were wrong:
///
/// * Mute **App problems** only. The warnings channel is on, so the value is
///   `available`, so the access-lost cadence is consumed for a notice Android
///   dropped. Days 0, 1, 3, 7 and 14 burn in silence, and the state ADR-0004
///   rates as the one a watcher cannot detect in themselves persists with
///   nothing left to say about it.
/// * Mute **Missed check-ins** only. The value is `unavailable`, so the
///   access-lost notice is suppressed and its cadence held — on a channel that
///   is switched on and would have shown it.
///
/// So the measurement is per channel, and the two travel together only because
/// they are decided in one pass.
///
/// [appInForeground] is genuinely shared: it is one app, one screen, and the
/// watcher list renders both states — the access-lost row outranks the warning
/// row on the same row (`watcher_screen.dart`). Seeing it is being told,
/// whichever notice it would have been.
///
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
class WatcherDelivery {
  const WatcherDelivery({required this.warning, required this.accessLost});

  /// Both channels in the same state.
  ///
  /// Named rather than defaulted, because "one value for both" is precisely the
  /// bug above and it must be a thing someone chose to say. Legitimate when the
  /// app-level `POST_NOTIFICATIONS` is revoked — that really does stop both —
  /// and in tests that are not about the channel split.
  const WatcherDelivery.uniform(NotificationDelivery delivery)
      : warning = delivery,
        accessLost = delivery;

  /// From what the platform edge can observe about each channel.
  factory WatcherDelivery.from({
    required bool canPostWarning,
    required bool canPostAccessLost,
    required bool appInForeground,
  }) =>
      WatcherDelivery(
        warning: NotificationDelivery.from(
          canPost: canPostWarning,
          appInForeground: appInForeground,
        ),
        accessLost: NotificationDelivery.from(
          canPost: canPostAccessLost,
          appInForeground: appInForeground,
        ),
      );

  /// The missed-day warning, and the correction that retracts one — both are
  /// the same claim about the same person on the same channel, at the same id.
  final NotificationDelivery warning;

  /// ADR-0004's *lost access* notice, on the **App problems** channel.
  final NotificationDelivery accessLost;

  @override
  bool operator ==(Object other) =>
      other is WatcherDelivery &&
      other.warning == warning &&
      other.accessLost == accessLost;

  @override
  int get hashCode => Object.hash(warning, accessLost);

  @override
  String toString() =>
      'WatcherDelivery(warning: ${warning.name}, access: ${accessLost.name})';
}
