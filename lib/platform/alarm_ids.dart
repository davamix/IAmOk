import '../domain/domain.dart';

/// The platform ids for alarms and notifications.
///
/// Android notification and alarm ids are **32-bit signed ints**, so every id
/// here is derived by hashing and masking into the positive range. Collisions
/// are therefore possible in principle; at family scale — a handful of links and
/// a rolling window of days — they are not a practical concern, and the failure
/// mode of one would be a replaced notification rather than a false claim.
///
/// Two rules make these ids load-bearing rather than incidental:
///
/// **A warning id is `hash(link, D)`** (§10). Both halves, always. The domain
/// emits `Correction(linkId, day)` carrying both for exactly this reason: keyed
/// on the day alone, a correction for one watched person would cancel a standing
/// warning about a *different* watched person on the same day — retracting a
/// true warning about someone whose day was never in question.
///
/// **A reminder id is `hash(day, slot)`, and deliberately excludes the
/// instant.** `ScheduledReminder`'s equality *includes* the instant, so a
/// reminder whose zone changed appears in both `toCancel` and `toSchedule` while
/// keeping one id. That is what makes it a replacement rather than a duplicate —
/// and it is also why **`toCancel` must be applied before `toSchedule`**:
/// cancelling afterwards disarms the alarm just scheduled, and the symptom is
/// nothing happening.
abstract final class AlarmIds {
  /// A display-only reminder at one of 12:00 / 18:00 / 21:00.
  static int reminder(DayKey day, ReminderSlot slot) =>
      _positive(Object.hash('reminder', day.toString(), slot.name));

  /// A warning about one link on one day — `hash(link, D)`, §10.
  static int warning(String linkId, DayKey day) =>
      _positive(Object.hash('warning', linkId, day.toString()));

  /// The access-lost notice for one link.
  ///
  /// Keyed on the link alone and **not** on the day, because the cadence
  /// replaces one standing notice rather than stacking a new one every
  /// milestone. ADR-0004's "a changed cause re-notifies" is a replacement at
  /// this same id, so the watcher is never left with two contradictory
  /// remediations in the tray.
  static int accessLost(String linkId) =>
      _positive(Object.hash('access-lost', linkId));

  /// Masks into the positive 32-bit range Android accepts.
  static int _positive(int hash) => hash & 0x7fffffff;
}
