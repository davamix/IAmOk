@TestOn('vm')
library;

import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

/// The 2×2 that produces every [NotificationDelivery] in production.
///
/// The enum's *semantics* were proven thoroughly; the mapping that produces it
/// was proven not at all, and it sat at the platform edge behind a `Future`
/// where nothing looked at it. Swapping the two branches — checking
/// `appInForeground` first — gives a watcher whose `POST_NOTIFICATIONS` is
/// revoked but who has the app open a `redundant`, consumes the reminder, and
/// reopens the whole defect for precisely the case where `reconcile()`
/// definitely runs.
void main() {
  group('NotificationDelivery.from', () {
    test('can post, backgrounded → available', () {
      expect(
        NotificationDelivery.from(canPost: true, appInForeground: false),
        NotificationDelivery.available,
      );
    });

    test('can post, foregrounded → redundant', () {
      expect(
        NotificationDelivery.from(canPost: true, appInForeground: true),
        NotificationDelivery.redundant,
      );
    });

    test('cannot post, backgrounded → unavailable', () {
      expect(
        NotificationDelivery.from(canPost: false, appInForeground: false),
        NotificationDelivery.unavailable,
      );
    });

    test('cannot post, FOREGROUNDED → still unavailable', () {
      // The one interesting cell, and the whole reason the branch order is a
      // decision rather than plumbing. `redundant` consumes the reminder;
      // `unavailable` does not. A muted phone with the app open must not be
      // told it has informed anyone.
      expect(
        NotificationDelivery.from(canPost: true, appInForeground: true),
        isNot(NotificationDelivery.unavailable),
        reason: 'sanity: foreground alone is not unavailable',
      );
      expect(
        NotificationDelivery.from(canPost: false, appInForeground: true),
        NotificationDelivery.unavailable,
        reason: 'cannot post dominates foreground — order matters',
      );
    });

    test('cannot post never consumes a reminder, either way round', () {
      for (final foreground in [true, false]) {
        final delivery = NotificationDelivery.from(
          canPost: false,
          appInForeground: foreground,
        );
        expect(delivery.consumesReminder, isFalse, reason: '$foreground');
        expect(delivery.postsNotification, isFalse, reason: '$foreground');
      }
    });
  });
}
