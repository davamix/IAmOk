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
class Link {
  Link({
    required this.watchedUid,
    required this.watcherUid,
    required this.status,
    required this.watchedName,
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

  /// Denormalised IANA zone of the watched person, e.g. `Europe/Madrid`.
  final String watchedTimezone;

  /// The day the link began. Never warn about days before this (§7).
  ///
  /// Set by `redeemInvite` to today **in the watched person's timezone**, not
  /// the redeemer's — a watcher redeeming from another continent must not shift
  /// which days are eligible for a warning.
  final DayKey activeFrom;

  /// Watcher-local time the warning alarm fires. Watcher-local so a watcher in
  /// another country is never woken at 03:00 (§11).
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
        watchedTimezone,
        activeFrom,
        warningLocalTime,
        createdAt,
        acceptedAt,
      );

  @override
  String toString() => 'Link($id, ${status.name}, activeFrom $activeFrom)';
}
