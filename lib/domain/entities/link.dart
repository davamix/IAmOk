import 'package:timezone/timezone.dart' as tz;

import '../time/day_key.dart';
import '../time/local_time_of_day.dart';
import '../time/time_zones.dart';

enum LinkStatus { accepted, revoked }

/// One watched person, watched by one watcher.
///
/// Roles live on links (ARCHITECTURE.md §1): a user is just a user, and the
/// same person can be watched on one link and a watcher on another.
///
/// [watchedName] and [watchedTimezone] are denormalised onto the link on
/// purpose (§7) — it means a watcher never reads another user's document, which
/// keeps the security rules tight and lets the watcher render and decide fully
/// offline. [watchedTimezone] in particular is what makes ADR-0002 work: the
/// alarm isolate computes `D` from this string and the current instant, with no
/// plugin access at all.
///
/// [watcherName] is the mirror of [watchedName], denormalised for the identical
/// reason in the identical direction — see its own doc comment. §7 originally
/// carried only the watched half, because until the Phase 1 gate no surface on
/// the watched side ever named anybody.
class Link {
  Link({
    required this.watchedUid,
    required this.watcherUid,
    required this.status,
    required this.watchedName,
    required this.watcherName,
    required this.watchedTimezone,
    required this.activeFrom,
    required this.createdAt,
    this.warningLocalTime = defaultWarningLocalTime,
    this.acceptedAt,
  });

  /// The warning alarm time when a link does not override it (§10).
  static const LocalTimeOfDay defaultWarningLocalTime = LocalTimeOfDay(10, 0);

  /// The deterministic document id, which is what makes pairing idempotent:
  /// redeeming the same invite twice writes the same document (§7).
  static String idFor({
    required String watchedUid,
    required String watcherUid,
  }) =>
      '${watchedUid}_$watcherUid';

  final String watchedUid;
  final String watcherUid;
  final LinkStatus status;

  /// Denormalised display name of the watched person.
  final String watchedName;

  /// Denormalised display name of the **watcher**.
  ///
  /// The exact mirror of [watchedName], required by the Phase 1 gate's decision
  /// that *the Tap screen names who will be notified*. Without it that screen
  /// cannot be built at all: §8 grants `users/{uid}` read **to self only**, so
  /// the watched person's device has no path from a `watcherUid` to a name, and
  /// the link was the only document it may read that could have carried one.
  /// §7's own rationale for denormalising `watchedName` — "the watcher never
  /// needs to read `users/{watchedUid}`" — applies unchanged in this direction;
  /// only the surface that needed it is new.
  ///
  /// Like [watchedName] this is a **display label and not an identity**. It is
  /// written by `redeemInvite` from the redeemer's Google profile and can be
  /// changed by that user afterwards, exactly as ADR-0003 records for
  /// `setByName`. Nothing decides anything from it; it is rendered, and that is
  /// all. Do not add a rules check comparing it to `displayName` — ADR-0003
  /// explains why that costs a read and proves nothing.
  final String watcherName;

  /// Denormalised IANA zone of the watched person, e.g. `Europe/Madrid`.
  final String watchedTimezone;

  /// The day the link began. Never warn about days before this (§7).
  ///
  /// Set by `redeemInvite` to today **in the watched person's timezone**, not
  /// the redeemer's — a watcher redeeming from another continent must not shift
  /// which days are eligible for a warning.
  final DayKey activeFrom;

  /// Watcher-local time the warning **alarm** fires. Watcher-local so a watcher
  /// in another country is never woken at 03:00 by the alarm (§11).
  ///
  /// **It does not bound when a warning can be POSTED, and since Phase 4 that
  /// distinction is visible.** `WarningPolicy` owes a warning the moment `D` is
  /// complete; this value decides only when the alarm asks. A reconcile
  /// triggered by anything else posts whenever it lands — and Phase 4 added a
  /// trigger that fires on **somebody else's action**: an FCM nudge, three to
  /// ten seconds after any watched person taps.
  ///
  /// So a watcher in Los Angeles can be woken at 00:00 PDT because Mum in Madrid
  /// tapped at 09:00 CEST, by a warning about the day she missed *before* that
  /// tap. Same-zone version: Mum taps at 06:30 and the family hears about
  /// yesterday at 06:30 rather than at 10:00. With ADR-0009's catch-up, a phone
  /// out of contact for a week can post up to seven at that hour.
  ///
  /// Two things make this a trade rather than simply a defect, and both cut
  /// against changing it in a hurry:
  ///
  /// - It accelerates delivery **only** for warnings where somebody has just
  ///   demonstrably proved they are fine. The case that actually matters — she
  ///   has stopped tapping, so there is no check-in and no push — still waits
  ///   for the alarm ADR-0008 measured as hours late in Doze.
  /// - For a watcher of several people it is a real dead-man's-switch
  ///   improvement: Mum's 07:00 tap wakes the isolate that discovers Granddad
  ///   has gone silent.
  ///
  /// Raised by the Phase 4 UI/UX review, recorded rather than decided, and owed
  /// to the owner. The alternative is to have the push path defer *posting* —
  /// never deciding, and never recording the day as settled — until
  /// `warningLocalTime` has passed, which costs only the second bullet and is a
  /// change to the one path where silence is the failure this app cannot detect
  /// in itself.
  final LocalTimeOfDay warningLocalTime;

  final DateTime createdAt;
  final DateTime? acceptedAt;

  String get id => idFor(watchedUid: watchedUid, watcherUid: watcherUid);

  bool get isAccepted => status == LinkStatus.accepted;

  /// The watched person's zone, resolved from [watchedTimezone].
  ///
  /// A lookup in a compiled-in table — no plugin, no I/O — so this is safe on
  /// the alarm path. Throws [UnknownTimeZone] if the stored name is not an IANA
  /// zone this build knows.
  tz.Location get watchedZone => TimeZones.location(watchedTimezone);

  /// [watchedZone], or null if the stored name is unknown to this build.
  ///
  /// The same shape as `AwayPeriod.tryCreate`, and for the same reason: an
  /// unrecognised zone must be able to surface as a handled condition rather
  /// than as an exception thrown inside an alarm isolate with seconds to live.
  /// One `watchedTimezone` string the bundled tzdata snapshot does not know —
  /// a device-reported alias, or a zone newer than the pinned `timezone`
  /// package — would otherwise mean a permanently silent watcher, which is the
  /// one failure this app cannot detect in itself. Phase 4 should also validate
  /// at the Data boundary; this is the backstop for when it does not.
  tz.Location? get tryWatchedZone {
    try {
      return watchedZone;
    } on UnknownTimeZone {
      return null;
    }
  }

  Link copyWith({
    LinkStatus? status,
    String? watchedName,
    String? watcherName,
    String? watchedTimezone,
    DayKey? activeFrom,
    LocalTimeOfDay? warningLocalTime,
    DateTime? acceptedAt,
  }) =>
      Link(
        watchedUid: watchedUid,
        watcherUid: watcherUid,
        status: status ?? this.status,
        watchedName: watchedName ?? this.watchedName,
        watcherName: watcherName ?? this.watcherName,
        watchedTimezone: watchedTimezone ?? this.watchedTimezone,
        activeFrom: activeFrom ?? this.activeFrom,
        warningLocalTime: warningLocalTime ?? this.warningLocalTime,
        createdAt: createdAt,
        acceptedAt: acceptedAt ?? this.acceptedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is Link &&
      other.watchedUid == watchedUid &&
      other.watcherUid == watcherUid &&
      other.status == status &&
      other.watchedName == watchedName &&
      other.watcherName == watcherName &&
      other.watchedTimezone == watchedTimezone &&
      other.activeFrom == activeFrom &&
      other.warningLocalTime == warningLocalTime &&
      other.createdAt == createdAt &&
      other.acceptedAt == acceptedAt;

  @override
  int get hashCode => Object.hash(
        watchedUid,
        watcherUid,
        status,
        watchedName,
        watcherName,
        watchedTimezone,
        activeFrom,
        warningLocalTime,
        createdAt,
        acceptedAt,
      );

  @override
  String toString() => 'Link($id, ${status.name}, activeFrom $activeFrom)';
}
