import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

/// Who will be notified when the watched person taps — and nothing else.
void main() {
  Link linkTo(
    String watcherUid, {
    required String watcherName,
    LinkStatus status = LinkStatus.accepted,
  }) =>
      Link(
        watchedUid: 'mum',
        watcherUid: watcherUid,
        status: status,
        watchedName: 'Mum',
        watcherName: watcherName,
        watchedTimezone: 'Europe/Madrid',
        activeFrom: day('2026-07-01'),
        createdAt: at(utc, 2026, 7, 1),
      );

  final ana = linkTo('ana', watcherName: 'Ana');
  final beto = linkTo('beto', watcherName: 'Beto');
  final carmen = linkTo('carmen', watcherName: 'Carmen');

  group('the accepted links, by name', () {
    test('names one watcher', () {
      expect(WatchedAudience.from([ana]).names, ['Ana']);
    });

    test('names several', () {
      expect(WatchedAudience.from([ana, beto, carmen]).names,
          ['Ana', 'Beto', 'Carmen']);
    });

    test('no links at all is empty', () {
      expect(WatchedAudience.from(const []).isEmpty, isTrue);
      expect(WatchedAudience.from(const []).names, isEmpty);
    });
  });

  group('revoked links are absent, not marked', () {
    test('a revoked watcher is not named', () {
      final revoked = linkTo('beto',
          watcherName: 'Beto', status: LinkStatus.revoked);
      expect(WatchedAudience.from([ana, revoked]).names, ['Ana']);
    });

    test('the last watcher revoking empties the audience', () {
      // The state the Phase 1 security review raised as finding M4: she goes on
      // tapping and no surface says otherwise. The empty audience is what the
      // Tap screen renders its static line from — see WatchedAudience's doc
      // comment for why there is deliberately no notification, banner or
      // warning attached to reaching this state.
      final revoked =
          linkTo('ana', watcherName: 'Ana', status: LinkStatus.revoked);
      expect(WatchedAudience.from([revoked]).isEmpty, isTrue);
    });

    test('never-paired and everyone-revoked are indistinguishable', () {
      // Deliberate, and load-bearing. Telling them apart is what would make a
      // "someone stopped watching you" message possible, which is on the
      // explicitly-rejected list. One static line covers both.
      final revoked =
          linkTo('ana', watcherName: 'Ana', status: LinkStatus.revoked);
      expect(WatchedAudience.from([revoked]),
          WatchedAudience.from(const <Link>[]));
    });
  });

  group('the line does not reorder between sessions', () {
    test('names are sorted regardless of input order', () {
      expect(WatchedAudience.from([carmen, ana, beto]).names,
          WatchedAudience.from([ana, beto, carmen]).names);
    });

    test('sorting is case-insensitive', () {
      final lower = linkTo('zoe', watcherName: 'aaron');
      expect(WatchedAudience.from([beto, lower]).names, ['aaron', 'Beto']);
    });

    test('two watchers with the same name still produce a total order', () {
      // Tie-broken on watcherUid, so the line is stable rather than arbitrary.
      final anaB = linkTo('ana-2', watcherName: 'Ana');
      final one = WatchedAudience.from([ana, anaB]);
      final other = WatchedAudience.from([anaB, ana]);
      expect(one.names, other.names);
      expect(one.names, ['Ana', 'Ana']);
    });
  });

  group('completeness is the only job this list has', () {
    test('two different people called Ana are BOTH named', () {
      // Deduping by name would silently drop a real watcher from a list whose
      // entire purpose is to be complete.
      final anaB = linkTo('ana-2', watcherName: 'Ana');
      expect(WatchedAudience.from([ana, anaB]).names, hasLength(2));
    });

    test('the same link twice is counted once', () {
      // The deterministic link id (§7) means this should not occur; the
      // backstop is for a caller concatenating two queries.
      expect(WatchedAudience.from([ana, ana]).names, ['Ana']);
    });
  });

  group('through the reconciler', () {
    WatchedReconcileResult reconcile(List<Link> links) =>
        WatchedReconciler.reconcile(
          now: at(madrid, 2026, 8, 17, 6),
          watchedZone: madrid,
          away: null,
          checkedInDays: const {},
          currentlyScheduled: const {},
          links: links,
        );

    test('the audience comes out of reconcile()', () {
      expect(reconcile([ana, beto]).audience.names, ['Ana', 'Beto']);
    });

    test('who is watching does not change which reminders are armed', () {
      // Reminders exist for the person's own routine, not for an audience. If
      // this ever couples, an empty audience silently stops her being nudged to
      // tap — which is the failure mode the watched side cannot detect.
      expect(reconcile(const []).desired, reconcile([ana, beto]).desired);
    });

    test('an empty audience is still a no-op reconcile', () {
      // isNoOp is about alarm work, not about rendering. A caller doing
      // `if (isNoOp) return;` must not be skipping the audience.
      final first = reconcile([ana]);
      final second = WatchedReconciler.reconcile(
        now: at(madrid, 2026, 8, 17, 6),
        watchedZone: madrid,
        away: null,
        checkedInDays: const {},
        currentlyScheduled: first.desired,
        links: const [],
      );
      expect(second.isNoOp, isTrue);
      expect(second.audience.isEmpty, isTrue);
    });
  });
}
