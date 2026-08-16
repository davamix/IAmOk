@TestOn('vm')
library;

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

    test('are NOT per day — the cadence replaces one standing notice', () {
      // ADR-0004's "a changed cause re-notifies" is a replacement at this id,
      // so the watcher is never left with two contradictory remediations.
      expect(AlarmIds.accessLost(mum), AlarmIds.accessLost(mum));
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
