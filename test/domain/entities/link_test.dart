import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  Link build({
    String zone = 'Europe/Madrid',
    LinkStatus status = LinkStatus.accepted,
  }) =>
      Link(
        watchedUid: 'mum',
        watcherUid: 'ana',
        status: status,
        watchedName: 'Mum',
        watchedTimezone: zone,
        activeFrom: day('2026-07-01'),
        createdAt: at(utc, 2026, 7, 1),
      );

  group('the deterministic id', () {
    test('is watchedUid_watcherUid', () {
      expect(Link.idFor(watchedUid: 'mum', watcherUid: 'ana'), 'mum_ana');
      expect(build().id, 'mum_ana');
    });

    test('is derived from the uids, not from the instance', () {
      // What makes redeeming twice idempotent is that the id is a function of
      // the pair alone — two independently built Links for the same pair share
      // a document. (That a pure function of two constants is deterministic
      // cannot fail; the transaction itself is an emulator test in Phase 5.)
      final rebuilt = build().copyWith(
        status: LinkStatus.revoked,
        watchedName: 'Someone else',
        activeFrom: day('2026-09-01'),
      );
      expect(rebuilt.id, build().id);
      expect(rebuilt.id, Link.idFor(watchedUid: 'mum', watcherUid: 'ana'));
    });

    test('is directional — the roles are not interchangeable', () {
      expect(
        Link.idFor(watchedUid: 'mum', watcherUid: 'ana'),
        isNot(Link.idFor(watchedUid: 'ana', watcherUid: 'mum')),
      );
    });
  });

  group('the denormalised timezone', () {
    test('resolves without a plugin, on the alarm path', () {
      // ADR-0002: the alarm isolate computes D from this string plus the
      // current instant, with no plugin access at all.
      expect(build().watchedZone.name, 'Europe/Madrid');
    });

    test('an unknown zone fails loudly with the offending value', () {
      expect(
        () => build(zone: 'Europe/Madridd').watchedZone,
        throwsA(isA<UnknownTimeZone>()
            .having((e) => e.name, 'name', 'Europe/Madridd')),
      );
    });

    test('tryWatchedZone returns null instead of throwing', () {
      // The same shape as AwayPeriod.tryCreate, for the same reason: one stored
      // zone name this build does not know — a device-reported alias, or a zone
      // newer than the pinned tzdata — must be able to surface as a handled
      // condition, not as an exception inside an alarm isolate with seconds to
      // live. Thrown there, it means a permanently silent watcher.
      expect(build(zone: 'Europe/Madridd').tryWatchedZone, isNull);
      expect(build().tryWatchedZone?.name, 'Europe/Madrid');
    });
  });

  test('the default warning time is 10:00 watcher-local', () {
    expect(build().warningLocalTime, const LocalTimeOfDay(10, 0));
    expect(Link.defaultWarningLocalTime.toString(), '10:00');
  });

  group('status', () {
    test('accepted and revoked are distinguished', () {
      expect(build().isAccepted, isTrue);
      expect(build(status: LinkStatus.revoked).isAccepted, isFalse);
    });

    test('copyWith preserves identity and createdAt', () {
      final original = build();
      final revoked = original.copyWith(status: LinkStatus.revoked);
      expect(revoked.id, original.id);
      expect(revoked.createdAt, original.createdAt);
      expect(revoked.activeFrom, original.activeFrom);
      expect(revoked.isAccepted, isFalse);
    });
  });

  test('value equality', () {
    expect(build(), build());
    expect(build().hashCode, build().hashCode);
    expect(build(), isNot(build(status: LinkStatus.revoked)));
  });
}
