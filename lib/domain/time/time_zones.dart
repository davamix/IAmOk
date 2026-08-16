import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Resolves IANA zone names against the compiled-in tz database.
///
/// This exists in the domain layer on purpose. [ADR-0002][] argues that a bare
/// background isolate can compute the current day *with no plugin access at
/// all* — using only the current instant, two strings from `LocalStore`, and
/// `package:timezone`. That argument only holds if the database is reachable
/// from the same code the isolate already runs, so the initialisation lives
/// here rather than at an app-startup edge that an alarm isolate never touches.
/// The failure it removes is the expensive one: an isolate that forgot to
/// initialise would throw at `getLocation`, the warning would never fire, and
/// silence is the one failure this app cannot detect in itself.
///
/// **Verified 2026-08-16, closing ADR-0002's open assumption.** `timezone`
/// 0.11.1 declares no `flutter:` section, ships no `android/` or `ios/`
/// directory, references neither `package:flutter` nor `MethodChannel`
/// anywhere in `lib/`, and adding it produced no
/// `.flutter-plugins-dependencies` entry — so no plugin registrant exists to
/// be missing. The assumption holds, with one condition ADR-0002 does not
/// state: it is true of *these* entry points only.
///
/// | Entry point | Verdict |
/// |---|---|
/// | `timezone/timezone.dart` + `timezone/data/latest.dart` | pure — `dart:typed_data` blob |
/// | `timezone/standalone.dart` | **forbidden** — `dart:io` + `dart:isolate`, reads tzdata from a file |
/// | `timezone/browser.dart` | **forbidden** — `package:http` |
///
/// Importing `standalone.dart` would put `dart:io` on the alarm path and
/// silently re-open the failure mode ADR-0002 closed.
///
/// [ADR-0002]: ../../../docs/architecture/decisions/0002-clock-split.md
abstract final class TimeZones {
  static bool _initialized = false;

  /// Loads the tz database into memory once per isolate.
  ///
  /// Idempotent, and cheap after the first call. Not I/O: the database is a
  /// `Uint8List` compiled into the binary, so this is a parse, not a read.
  static void ensureInitialized() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// The zone named [ianaName], e.g. `Europe/Madrid`.
  ///
  /// Throws [UnknownTimeZone] rather than the package's own exception, so a
  /// bad `watchedTimezone` on a link surfaces as this project's error with the
  /// offending value attached.
  static tz.Location location(String ianaName) {
    ensureInitialized();
    try {
      return tz.getLocation(ianaName);
    } on tz.LocationNotFoundException {
      throw UnknownTimeZone(ianaName);
    }
  }

  /// [location], returning null instead of throwing.
  ///
  /// The same shape, and the same reason, as `Link.tryWatchedZone` and
  /// `AwayPeriod.tryCreate`: a zone name read back off disk — written by an
  /// older build, or a device alias newer than the pinned tzdata — must be able
  /// to surface as a handled condition rather than as an exception thrown
  /// inside an alarm isolate with seconds to live.
  static tz.Location? tryLocation(String ianaName) {
    try {
      return location(ianaName);
    } on UnknownTimeZone {
      return null;
    }
  }

  /// UTC, available without initialisation.
  ///
  /// Present for tests and for the degenerate case. Real days are computed in
  /// the *watched person's* zone (ARCHITECTURE.md §11); UTC is never a
  /// substitute for it.
  static tz.Location get utc => tz.UTC;

  /// Whether [ianaName] names a zone this database knows.
  static bool isKnown(String ianaName) {
    ensureInitialized();
    return tz.timeZoneDatabase.locations.containsKey(ianaName);
  }
}

/// Thrown when a stored IANA zone name is not in the database.
class UnknownTimeZone implements Exception {
  const UnknownTimeZone(this.name);

  final String name;

  @override
  String toString() => 'UnknownTimeZone: "$name" is not an IANA zone name';
}
