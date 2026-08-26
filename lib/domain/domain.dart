/// The I Am Ok domain layer: every hard decision this app makes, as pure
/// functions over explicit inputs.
///
/// What day is it, should a reminder exist, should we warn, is this day inside
/// an away period, is this a correction — all of it lives here. No
/// `DateTime.now()`, no plugin call, no I/O, and **no Flutter import**.
///
/// That is not a style preference. Two of the three isolates that run this app
/// are bare — no widget tree, no Riverpod, no UI state — and this layer is the
/// only code that behaves identically in all three (ARCHITECTURE.md §4, §5).
/// It is also what makes logic that is entirely time-dependent testable in
/// milliseconds instead of in days.
///
/// The one external dependency is `package:timezone`, which is pure Dart with a
/// compiled-in database and needs no plugin registrant — verified, see
/// [TimeZones].
library;

export 'away/away_period.dart';
export 'entities/check_in.dart';
export 'entities/invite_code.dart';
export 'entities/link.dart';
export 'entities/pairing_outcome.dart';
export 'entities/watch_status.dart';
export 'entities/watched_audience.dart';
export 'onboarding/home_route.dart';
export 'policy/reminder_policy.dart';
export 'policy/warning_policy.dart';
export 'reconcile/firestore_read.dart';
export 'reconcile/notification_delivery.dart';
export 'reconcile/watched_reconciler.dart';
export 'reconcile/watcher_cache.dart';
export 'reconcile/watcher_reconciler.dart';
export 'time/day_key.dart';
export 'time/local_time_of_day.dart';
export 'time/time_zones.dart';
