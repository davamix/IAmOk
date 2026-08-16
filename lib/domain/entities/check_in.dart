import 'package:timezone/timezone.dart' as tz;

import '../time/day_key.dart';

/// One day's "I'm OK" tap: `checkins/{watchedUid}/days/{YYYY-MM-DD}`.
///
/// [day] **is** the document id (ARCHITECTURE.md §7), which buys once-per-day
/// semantics with no dedupe logic anywhere: a second tap the same day is an
/// *update*, so it does not fire `onDocumentCreated` and produces no duplicate
/// push.
///
/// Two timestamps, not one (§11):
///
/// - [deviceTappedAt] is the client clock, and is what the family is shown,
///   because it is what actually happened.
/// - [receivedAt] is `serverTimestamp()` — audit trail, and the only clock-skew
///   signal available. It is null until the write reaches the server.
class CheckIn {
  const CheckIn({
    required this.day,
    required this.deviceTappedAt,
    required this.timezone,
    this.receivedAt,
  });

  /// The check-in a tap at [now] produces, for a device in [zone].
  ///
  /// **The day is decided here, on the device, at tap time.** Deriving it from
  /// `serverTimestamp()` instead would file a tap made at 23:50 with no signal
  /// — and synced at 08:00 the next morning — on the wrong day. ARCHITECTURE.md
  /// §17 rates that "High — silently wrong data", and §11 records that it
  /// corrects an instruction in HANDOVER.md that says the opposite.
  factory CheckIn.forTap({
    required DateTime now,
    required tz.Location zone,
  }) =>
      CheckIn(
        day: DayKey.fromInstant(now, zone),
        deviceTappedAt: now,
        timezone: zone.name,
      );

  /// The day this check-in covers, in the tapping device's timezone.
  final DayKey day;

  /// Client clock at the moment of the tap.
  final DateTime deviceTappedAt;

  /// `serverTimestamp()`. Null while the write is still queued offline.
  final DateTime? receivedAt;

  /// The device's IANA zone at the moment of the tap.
  final String timezone;

  /// Whether the write has reached the server.
  bool get isSynced => receivedAt != null;

  /// How far the device clock was from the server, or null if not yet synced.
  ///
  /// Skew is **detected and surfaced, never silently corrected** (§11): a
  /// device that is a day off files check-ins on the wrong day, and no
  /// server-side fix-up can tell that apart from a legitimate offline sync.
  /// A large value here is expected and harmless for a queued offline write,
  /// which is why the health panel compares clocks live rather than inferring
  /// skew from this field.
  Duration? get syncDelay => receivedAt?.difference(deviceTappedAt);

  CheckIn copyWith({DateTime? receivedAt}) => CheckIn(
        day: day,
        deviceTappedAt: deviceTappedAt,
        timezone: timezone,
        receivedAt: receivedAt ?? this.receivedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is CheckIn &&
      other.day == day &&
      other.deviceTappedAt == deviceTappedAt &&
      other.receivedAt == receivedAt &&
      other.timezone == timezone;

  @override
  int get hashCode => Object.hash(day, deviceTappedAt, receivedAt, timezone);

  @override
  String toString() => 'CheckIn($day, tapped $deviceTappedAt $timezone)';
}
