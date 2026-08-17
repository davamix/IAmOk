import 'dart:convert';

import '../domain/domain.dart';

/// The platform ids for alarms and notifications.
///
/// Android notification and alarm ids are **32-bit signed ints**, so every id
/// here is derived by hashing and masking into the positive range. Collisions
/// are therefore possible in principle; at family scale — a handful of links and
/// a rolling window of days — they are not a practical concern, and the failure
/// mode of one would be a replaced notification rather than a false claim.
///
/// ## Why the hash is written out by hand
///
/// **`Object.hash` is seeded randomly per process, and this file used it.**
/// Measured on 2026-08-17 by evaluating the same expression in three separate
/// VMs:
///
/// ```
/// run 1   reminder(2026-08-17, midday) =  69007203
/// run 2   reminder(2026-08-17, midday) = 231827400
/// run 3   reminder(2026-08-17, midday) = 198951794
/// ```
///
/// `String.hashCode` is stable across runs; `Object.hash` combines its arguments
/// with a per-process seed and is documented as *not* stable between runs. Every
/// id in this file therefore changed on every app launch, and **an id that
/// changes is not an id.** The consequences were the whole point of the file:
///
/// - Each launch armed the rolling window under **fresh ids**, leaving the
///   previous launch's alarms armed and unreachable. `cancelReminder` computes
///   the id in the *current* process, so nothing could ever cancel them. They
///   accumulated per launch and survived reboot, because the plugin re-arms from
///   its own `SharedPreferences`.
/// - The observed symptom on the POCO F3: **two identical *"Remember to tap I'm
///   OK today."* notifications at 12:00**, and three at 21:00. Identical because
///   the body depends only on the slot — so stale ids from earlier launches read
///   as the phone having failed to deliver one message twice, which is exactly
///   what `NotificationCopy`'s escalating wording exists to avoid.
/// - A tap could not fully cancel the day: it cancels this process's ids, and
///   every earlier process's reminder still fired at her.
/// - **Worst, and the reason this had to be fixed before the watcher side is
///   written:** a correction *replaces a warning by id*. With an unstable id it
///   posts a second notification instead, leaving *"No check-in from Mum
///   yesterday"* standing directly above *"Correction: Mum did check in
///   yesterday"*. §10's correction path is the highest-value behaviour in this
///   app and it could not have worked. ADR-0004's access-lost cadence, which
///   also relies on replacement at one id, would have stacked a fresh notice at
///   every milestone instead of replacing the standing one.
///
/// So the hash is **FNV-1a, 32-bit, written out below and pinned by golden
/// constants** in `test/platform/alarm_ids_test.dart`. Not `String.hashCode`
/// either: it happens to be stable today, but nothing guarantees it across SDK
/// versions, and an id that moves when Dart is upgraded orphans every alarm on
/// every installed phone at once.
///
/// **No test in a single-process suite can see this**, which is why all 524
/// stayed green. Every assertion here compared two calls made in one process,
/// where a seeded hash is perfectly self-consistent. The property that matters is
/// stability *across* processes, and the only way to assert it from inside one is
/// a **known-value test**. That is the guard now.
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
      _hash('reminder$_sep$day$_sep${slot.name}');

  /// A warning about one link on one day — `hash(link, D)`, §10.
  static int warning(String linkId, DayKey day) =>
      _hash('warning$_sep$linkId$_sep$day');

  /// The access-lost notice for one link.
  ///
  /// Keyed on the link alone and **not** on the day, because the cadence
  /// replaces one standing notice rather than stacking a new one every
  /// milestone. ADR-0004's "a changed cause re-notifies" is a replacement at
  /// this same id, so the watcher is never left with two contradictory
  /// remediations in the tray.
  static int accessLost(String linkId) => _hash('access-lost$_sep$linkId');

  /// Separates the parts of a key — ASCII **unit separator**, `0x1f`.
  ///
  /// It cannot occur in any component: a link id is `{watchedUid}_{watcherUid}`
  /// over Firebase's alphanumeric uids, a [DayKey] renders as `YYYY-MM-DD`, and
  /// a slot is an enum name. A separator that *could* appear in a component
  /// would let `warning('a', 'b-c')` and `warning('a-b', 'c')` collide — one
  /// link's correction retracting another link's true warning, which is the
  /// exact failure `warning` takes both halves to prevent.
  ///
  /// Built with [String.fromCharCode] rather than written as a literal, so the
  /// source carries no invisible byte that an editor could eat and no reader
  /// could see. That is not hypothetical: the first draft of this fix put the
  /// raw control character in the source, where it was indistinguishable from a
  /// space.
  static final String _sep = String.fromCharCode(0x1f);

  /// **FNV-1a, 32-bit**, over the UTF-8 bytes of [key], masked into the positive
  /// 32-bit range Android accepts.
  ///
  /// Written out rather than delegated because the id must be identical in every
  /// process that ever runs this app, on every SDK it is ever compiled with —
  /// see the note on this class for the launch-to-launch failure that paid for
  /// it. The constants are the published FNV-1a ones: `0x811c9dc5` offset basis,
  /// `0x01000193` prime. `& 0xffffffff` keeps the product 32-bit, because Dart
  /// ints are 64-bit and would otherwise accumulate high bits the reference
  /// algorithm discards.
  ///
  /// Masking to 31 bits rather than 32 is what keeps the result positive.
  static int _hash(String key) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(key)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }
}
