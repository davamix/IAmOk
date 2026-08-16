import 'package:flutter_timezone/flutter_timezone.dart';

import '../domain/domain.dart';

/// Discovers the device's own IANA timezone. **UI isolate only**
/// ([ADR-0002][]).
///
/// This is the half of the old single `ClockService` row that genuinely needs a
/// plugin, and the reason §6 splits it from [Clock][]. `flutter_timezone` is a
/// **plugin**, so calling it from a bare alarm or FCM isolate would put a plugin
/// registrant on the very path that must not have one — to answer a question the
/// UI already knows the answer to.
///
/// > **Never call this from a background isolate.** The UI writes the discovered
/// > zone to `LocalStore` on every resume; background isolates read it from
/// > there, exactly as they read the per-link `watchedTimezone`. §4's whole
/// > thesis is that what a background isolate needs is on disk.
///
/// A cached zone can go stale if someone travels without opening the app, and
/// ADR-0002 accepts that: for the **watcher** it cannot affect `D` at all, since
/// `D` uses the watched person's zone from the link; for the **watched person**
/// it sets the day id and the reminder times, but they open the app daily to
/// tap, so it refreshes daily. The worst case is one boundary day after a
/// flight, and §11 already treats midnight as a soft boundary.
///
/// This class deliberately does **not** hold a `LocalStore`. §5 makes Data and
/// Platform peers; the Application layer reads from here and writes there. §6
/// describes the round trip as one responsibility, which is true of the
/// behaviour and not of the dependency.
///
/// Skew detection — the other half of §6's row — needs a server round-trip and
/// is Phase 4, where a server timestamp first exists to compare against.
///
/// [ADR-0002]: ../../docs/architecture/decisions/0002-clock-split.md
/// [Clock]: clock.dart
class ClockService {
  const ClockService();

  /// The device's current IANA zone, e.g. `Europe/Madrid`.
  ///
  /// Returns null if the platform reports a name the bundled tzdata does not
  /// know — a device alias, or a zone newer than the pinned `timezone` package.
  /// Null rather than a throw because the caller's correct response is to keep
  /// the previously cached value, and a throw during app start would take the
  /// whole screen with it.
  Future<String?> deviceTimezone() async {
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      // Validated here, at the boundary, so an unusable name never reaches
      // `LocalStore` and from there a background isolate that cannot report a
      // problem. Same reasoning as `Link.tryWatchedZone`.
      return TimeZones.isKnown(name.identifier) ? name.identifier : null;
    } on Exception {
      return null;
    }
  }
}
