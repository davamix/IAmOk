@TestOn('vm')
library;

import 'dart:convert';

import 'package:i_am_ok/domain/domain.dart';
import 'package:i_am_ok/platform/alarm_ids.dart';
import 'package:test/test.dart';

import '../support/zones.dart';

/// **Notification identity across links** — `docs/testing/strategy.md`'s
/// mandatory case, asserted where it is actually decided.
///
/// The domain emits `Correction(linkId, day)` carrying both halves precisely so
/// the id can be built from both. Nothing asserted that the id derived *from*
/// them used both, and dropping `linkId` from the expression left the whole
/// suite green.
///
/// The scenario that costs: a watcher watches Mum and Granddad, both missed
/// 2026-08-05, both warnings standing. Mum's late check-in arrives, the
/// correction posts at `warning(mumLink, D)` — now equal to
/// `warning(granddadLink, D)` — and Granddad's **true** warning is silently
/// replaced by *"Mum did check in yesterday"*. The app retracts a true warning
/// about someone whose day was never in question, which is the worst class of
/// bug this project names.
void main() {
  final d = day('2026-08-05');
  const mum = 'mum_ana';
  const granddad = 'granddad_ana';

  group('warning ids — hash(link, D), both halves', () {
    test('two watched people on the same day do NOT collide', () {
      expect(AlarmIds.warning(mum, d), isNot(AlarmIds.warning(granddad, d)));
    });

    test('two days for the same link do NOT collide', () {
      expect(AlarmIds.warning(mum, d), isNot(AlarmIds.warning(mum, d.next)));
    });

    test('the same link and day give the same id', () {
      // What makes a correction a REPLACEMENT rather than a second
      // notification: the family sees one corrected message, not two
      // contradictory ones.
      expect(AlarmIds.warning(mum, d), AlarmIds.warning(mum, day('2026-08-05')));
    });
  });

  group('reminder ids — hash(day, slot), and NOT the instant', () {
    test('the three slots of one day are distinct', () {
      final ids = {
        for (final slot in ReminderSlot.values) AlarmIds.reminder(d, slot),
      };
      expect(ids, hasLength(3));
    });

    test('the same slot on different days is distinct', () {
      expect(AlarmIds.reminder(d, ReminderSlot.midday),
          isNot(AlarmIds.reminder(d.next, ReminderSlot.midday)));
    });

    test('a MOVED reminder keeps its id', () {
      // Load-bearing, and the reason `toCancel` must be applied before
      // `toSchedule`. `ScheduledReminder` equality includes the instant, so a
      // reminder whose zone changed appears in both diff sets — and it must be
      // the *same* platform id, or the move is a duplicate rather than a
      // replacement.
      final madridInstant = ScheduledReminder(
        day: d,
        slot: ReminderSlot.midday,
        at: d.at(ReminderSlot.midday.time, madrid),
      );
      final newYorkInstant = ScheduledReminder(
        day: d,
        slot: ReminderSlot.midday,
        at: d.at(ReminderSlot.midday.time, newYork),
      );

      expect(madridInstant, isNot(newYorkInstant),
          reason: 'the premise: the two are different desired alarms');
      expect(
        AlarmIds.reminder(madridInstant.day, madridInstant.slot),
        AlarmIds.reminder(newYorkInstant.day, newYorkInstant.slot),
        reason: 'but one id, so the move replaces rather than duplicates',
      );
    });
  });

  group('access-lost ids', () {
    test('are per link', () {
      expect(AlarmIds.accessLost(mum), isNot(AlarmIds.accessLost(granddad)));
    });

    test('never collide with a warning about the same link, on ANY day', () {
      // ADR-0004's "a changed cause re-notifies" is a replacement at this one
      // id, so the watcher is never left with two contradictory remediations —
      // and the id carries no day, which is what makes the replacement work
      // across a cadence that spans weeks.
      //
      // **The previous version of this test asserted
      // `accessLost(mum) == accessLost(mum)`** — a pure function compared to
      // itself, which cannot fail and said nothing about days at all. The
      // property that is actually at risk is the other one: a day-free id
      // sitting in the same integer space as a per-day one. A collision would
      // have an access-lost notice silently replace a standing warning about
      // her, or the reverse — the two messages ADR-0004 exists to keep apart,
      // rejoined by an integer.
      //
      // Swept across a year rather than one day, because a single sample is a
      // one-in-two-billion check dressed up as a test.
      for (var i = 0; i < 366; i++) {
        final anyDay = day('2026-01-01').plusDays(i);
        expect(AlarmIds.warning(mum, anyDay), isNot(AlarmIds.accessLost(mum)),
            reason: 'collides on $anyDay');
        expect(AlarmIds.warning(granddad, anyDay),
            isNot(AlarmIds.accessLost(mum)),
            reason: 'collides on $anyDay');
      }
    });
  });

  group('the three kinds do not collide with each other', () {
    test('a warning and an access-lost notice for the same link differ', () {
      expect(AlarmIds.warning(mum, d), isNot(AlarmIds.accessLost(mum)));
    });

    test('a reminder and a warning on the same day differ', () {
      expect(AlarmIds.reminder(d, ReminderSlot.midday),
          isNot(AlarmIds.warning(mum, d)));
    });
  });

  /// **The group that would have caught the defect, and the reason it is
  /// written as constants rather than as comparisons.**
  ///
  /// `AlarmIds` used `Object.hash`, which combines its arguments with a
  /// **per-process random seed**. Every id therefore changed on every app
  /// launch. Nothing above could see it: each test compares two calls made
  /// inside *one* process, and a seeded hash is perfectly self-consistent there.
  /// All 524 tests passed while the shipped app re-armed its whole window under
  /// fresh ids on every launch, could never cancel the previous launch's alarms,
  /// and posted two identical *"Remember to tap I'm OK today."* notifications at
  /// 12:00 on the POCO F3.
  ///
  /// A single-process suite can only assert cross-process stability by pinning
  /// **known values**. If the derivation ever becomes process-dependent again,
  /// these fail on the very next run — which is the point: they fail closed.
  ///
  /// **Changing one of these numbers is a breaking change**, not a test fix. It
  /// orphans every alarm already armed on every installed phone: they stay
  /// registered with `AlarmManager` under the old id, no longer match anything
  /// the app computes, and can never be cancelled. If a key genuinely has to
  /// change, the release that does it owes a one-time `cancelAll()` before its
  /// first reconcile.
  group('ids are stable across processes — known values', () {
    test('reminder ids', () {
      expect(AlarmIds.reminder(d, ReminderSlot.midday), 1546359976);
      expect(AlarmIds.reminder(d, ReminderSlot.evening), 431848108);
      expect(AlarmIds.reminder(d, ReminderSlot.night), 1872874278);
    });

    test('warning ids', () {
      expect(AlarmIds.warning(mum, d), 1002178930);
      expect(AlarmIds.warning(granddad, d), 742081992);
    });

    test('access-lost ids', () {
      expect(AlarmIds.accessLost(mum), 1514605395);
    });
  });

  /// An **independent oracle**. The constants above pin the values; this pins
  /// the *algorithm* that produces them, so a change to either the hash or the
  /// key construction is caught with a diagnosis rather than as six unexplained
  /// numbers.
  ///
  /// The chain is deliberate: the published FNV-1a vectors prove the oracle is
  /// real FNV-1a, and the oracle then proves production is. Neither half alone
  /// would do — an oracle copied from the implementation asserts only that the
  /// code equals itself.
  group('the derivation is FNV-1a over a separated key', () {
    // ASCII unit separator, matching AlarmIds._sep.
    final sep = String.fromCharCode(0x1f);

    int fnv1a32(String key) {
      var hash = 0x811c9dc5;
      for (final byte in utf8.encode(key)) {
        hash ^= byte;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
      return hash;
    }

    int expected(String key) => fnv1a32(key) & 0x7fffffff;

    test('the oracle matches the published FNV-1a 32-bit vectors', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
    });

    test('production matches the oracle for all three kinds', () {
      expect(AlarmIds.reminder(d, ReminderSlot.midday),
          expected('reminder${sep}2026-08-05${sep}midday'));
      expect(AlarmIds.warning(mum, d),
          expected('warning$sep$mum${sep}2026-08-05'));
      expect(AlarmIds.accessLost(mum), expected('access-lost$sep$mum'));
    });

    test('the separator cannot be forged out of the components', () {
      // Without a separator absent from every component, `warning('a', 'b-c')`
      // and `warning('a-b', 'c')` would meet — and a correction for one link
      // would retract a true warning about another. The concatenations differ
      // only in where the boundary falls.
      expect(expected('warning${sep}a${sep}b-c'),
          isNot(expected('warning${sep}a-b${sep}c')));
    });
  });

  test('every id fits Android\'s positive 32-bit range', () {
    // Android notification and alarm ids are 32-bit signed ints. A negative or
    // oversized value is rejected at the platform boundary, which would look
    // like a reminder that simply never arrived.
    final ids = <int>[
      for (var i = 0; i < 200; i++) ...[
        AlarmIds.warning('link-$i', d.plusDays(i)),
        AlarmIds.accessLost('link-$i'),
        for (final slot in ReminderSlot.values)
          AlarmIds.reminder(d.plusDays(i), slot),
      ],
    ];

    for (final id in ids) {
      expect(id, inInclusiveRange(0, 0x7fffffff));
    }
  });
}
