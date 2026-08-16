import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

void main() {
  final activeFrom = day('2026-07-01');
  final holiday =
      AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));

  /// The alarm fires on 2026-08-06, so D is 2026-08-05 throughout.
  WarningDecision decide({
    AwayPeriod? away,
    DayKey? lastConfirmedDay,
    DateTime? lastReconcileAt,
    Verification verification = Verification.verified,
    DateTime? now,
    DayKey? from,
    bool linkAccepted = true,
  }) =>
      WarningPolicy.decide(
        now: now ?? at(utc, 2026, 8, 6, 10),
        watchedZone: utc,
        away: away,
        linkAccepted: linkAccepted,
        activeFrom: from ?? activeFrom,
        lastConfirmedDay: lastConfirmedDay,
        lastReconcileAt: lastReconcileAt,
        verification: verification,
      );

  group('D is the last completed day in the WATCHED zone', () {
    test('the decision is about yesterday, not today', () {
      expect(decide().day, day('2026-08-05'));
    });

    test('a watcher abroad still asks about the watched-local day', () {
      // The alarm fires at 10:00 Madrid on the 17th. In Honolulu it is 22:00 on
      // the 16th, so the last completed day there is the 15th — not the 16th
      // the watcher's own calendar would suggest.
      final decision = WarningPolicy.decide(
        now: at(madrid, 2026, 8, 17, 10),
        watchedZone: honolulu,
        away: null,
        linkAccepted: true,
        activeFrom: activeFrom,
        lastConfirmedDay: null,
        lastReconcileAt: null,
        verification: Verification.verified,
      );
      expect(decision.day, day('2026-08-15'));
    });

    test('and the mirror case, a watched person over the date line', () {
      final decision = WarningPolicy.decide(
        now: at(madrid, 2026, 8, 17, 22),
        watchedZone: auckland,
        away: null,
        linkAccepted: true,
        activeFrom: activeFrom,
        lastConfirmedDay: null,
        lastReconcileAt: null,
        verification: Verification.verified,
      );
      expect(decision.day, day('2026-08-17'));
    });
  });

  group('suppression — assert the silent cases as hard as the firing ones', () {
    test('before activeFrom, and the reason says so', () {
      final decision = decide(from: day('2026-08-20'));
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.beforeActiveFrom);
    });

    test('a check-in recorded for D settles it', () {
      final decision = decide(lastConfirmedDay: day('2026-08-05'));
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.checkInRecorded);
    });

    test('a check-in for an earlier day does not settle D', () {
      expect(decide(lastConfirmedDay: day('2026-08-04')).outcome,
          WarningOutcome.warnOnline);
    });

    test('a fresh cached away silences', () {
      final decision = decide(
        away: holiday,
        lastReconcileAt: at(utc, 2026, 8, 5, 9),
      );
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.awayVerified);
    });

    test('evidence outranks doubt — confirmed beats a stale away', () {
      // Tapping during an away day is allowed (§12), so a confirmed day must
      // stay silent even when the cached away has gone stale. Ordering matters:
      // the away branch would otherwise produce warnUnverifiableAway.
      final decision = decide(
        away: holiday,
        lastConfirmedDay: day('2026-08-05'),
        lastReconcileAt: at(utc, 2026, 8, 1),
        verification: Verification.unreachable,
      );
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.checkInRecorded);
    });

    test('activeFrom is checked before anything else', () {
      // A link created after a missed day must not warn about it, whatever the
      // rest of the state says. This is the guard the Phase 0 review found
      // dropped from the skill, and its own §17 risk.
      final decision = decide(
        from: day('2026-08-06'),
        lastReconcileAt: at(utc, 2026, 8, 1),
        verification: Verification.unreachable,
      );
      expect(decision.silenceReason, SilenceReason.beforeActiveFrom);
    });
  });

  group('four distinct warning outcomes, never fewer', () {
    test('plain — the read succeeded and there was nothing there', () {
      final decision = decide();
      expect(decision.outcome, WarningOutcome.warnOnline);
      expect(decision.unverifiedSince, isNull,
          reason: 'nothing to be honest about — the device did verify');
    });

    test('offline — the device could not REACH the server, and says so', () {
      final reconciled = at(utc, 2026, 8, 4, 22, 10);
      final decision = decide(
          verification: Verification.unreachable, lastReconcileAt: reconciled);
      expect(decision.outcome, WarningOutcome.warnOffline);
      expect(decision.unverifiedSince, reconciled,
          reason: 'the copy renders "offline since 22:10" from this');
    });

    test('unverifiable away — states both facts, claims neither', () {
      final reconciled = at(utc, 2026, 8, 1, 10, 14);
      final decision = decide(
        away: holiday,
        lastReconcileAt: reconciled,
        verification: Verification.unreachable,
      );
      expect(decision.outcome, WarningOutcome.warnUnverifiableAway);
      expect(decision.away, holiday,
          reason: 'the copy names "marked away until Saturday 22 August"');
      expect(decision.unverifiedSince, reconciled);
    });

    test('access lost — REFUSED is not unreachable (ADR-0004)', () {
      final decision = decide(
        verification: Verification.refused,
        lastConfirmedDay: day('2026-08-02'),
        lastReconcileAt: at(utc, 2026, 8, 4, 22, 10),
      );
      expect(decision.outcome, WarningOutcome.warnAccessLost);
      expect(decision.lastConfirmedDay, day('2026-08-02'),
          reason: 'the copy ends "Last confirmed Sunday 2 August"');
    });

    test('a refused read never produces the OFFLINE wording', () {
      // The phone is online and talking to the server. Claiming it is offline
      // is a false statement about the device, which §10 forbids as firmly as
      // a false statement about the watched person.
      for (final lastConfirmed in [null, day('2026-08-02')]) {
        for (final away in [null, holiday]) {
          final outcome = decide(
            verification: Verification.refused,
            away: away,
            lastConfirmedDay: lastConfirmed,
            lastReconcileAt: at(utc, 2026, 8, 1),
          ).outcome;
          expect(outcome, isNot(WarningOutcome.warnOffline));
          expect(outcome, isNot(WarningOutcome.warnUnverifiableAway));
        }
      }
    });

    test('the four are genuinely distinguishable from one another', () {
      final outcomes = {
        decide().outcome,
        decide(verification: Verification.unreachable).outcome,
        decide(
          away: holiday,
          lastReconcileAt: at(utc, 2026, 8, 1),
          verification: Verification.unreachable,
        ).outcome,
        decide(verification: Verification.refused).outcome,
      };
      expect(outcomes.length, 4);
    });
  });

  group('refusal dominates the away branch, but not evidence — ADR-0004', () {
    test('a refused read outranks even a FRESH cached away', () {
      // ADR-0001's two-day bound is calibrated for a phone in a pocket. A
      // refusal is neither transient nor self-healing, so silence here would
      // mean days of a dead man's switch that is definitively dead.
      final decision = decide(
        away: holiday,
        lastReconcileAt: at(utc, 2026, 8, 6, 9),
        verification: Verification.refused,
      );
      expect(decision.outcome, WarningOutcome.warnAccessLost);
      expect(decision.away, holiday,
          reason: 'the away is still carried, it is just not the headline');
    });

    test('but a recorded check-in for D still settles the day', () {
      // Evidence already held is not unsettled by losing access.
      final decision = decide(
        lastConfirmedDay: day('2026-08-05'),
        verification: Verification.refused,
      );
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.checkInRecorded);
    });

    test('and a revoked link is still silent, not access-lost', () {
      // Revocation is known locally, before any read is attempted, so the
      // common cause of refusal never reaches the refused branch at all.
      final decision = decide(
        linkAccepted: false,
        verification: Verification.refused,
      );
      expect(decision.outcome, WarningOutcome.silent);
      expect(decision.silenceReason, SilenceReason.linkRevoked);
    });

    test('and a day before activeFrom is still silent', () {
      final decision = decide(
        from: day('2026-08-20'),
        verification: Verification.refused,
      );
      expect(decision.silenceReason, SilenceReason.beforeActiveFrom);
    });

    test('lastConfirmedDay may legitimately be null', () {
      // Access lost before any check-in was ever recorded. The copy needs a
      // variant for this rather than rendering an empty date.
      final decision = decide(verification: Verification.refused);
      expect(decision.outcome, WarningOutcome.warnAccessLost);
      expect(decision.lastConfirmedDay, isNull);
    });
  });

  group('the staleness bound — ADR-0001 decision 2', () {
    test('a cached away never re-verified cannot silence', () {
      // lastReconcileAt null means the device has never had a successful read.
      final decision = decide(away: holiday, lastReconcileAt: null);
      expect(decision.outcome, WarningOutcome.warnUnverifiableAway);
      expect(decision.unverifiedSince, isNull);
    });

    test('silences at the bound and speaks past it', () {
      // today is 2026-08-06 in the watched zone.
      DateTime reconciledOn(String iso) => at(
            utc,
            day(iso).year,
            day(iso).month,
            day(iso).day,
            12,
          );

      expect(decide(away: holiday, lastReconcileAt: reconciledOn('2026-08-06'))
          .outcome, WarningOutcome.silent);
      expect(decide(away: holiday, lastReconcileAt: reconciledOn('2026-08-05'))
          .outcome, WarningOutcome.silent);
      expect(decide(away: holiday, lastReconcileAt: reconciledOn('2026-08-04'))
          .outcome, WarningOutcome.silent,
          reason: 'exactly 2 days — the bound is inclusive');
      expect(decide(away: holiday, lastReconcileAt: reconciledOn('2026-08-03'))
          .outcome, WarningOutcome.warnUnverifiableAway,
          reason: '3 days — three consecutive failed reconciles');
    });

    test('the comparison is calendar-day granular, not 48 hours', () {
      // ADR-0002 decision 4. Reconciled at 23:59 two days back is 58 hours ago
      // and still fresh; a duration-based rule would speak here, and would then
      // depend on what time of day the away happened to be verified.
      final decision = decide(
        away: holiday,
        lastReconcileAt: at(utc, 2026, 8, 4, 23, 59),
      );
      expect(decision.outcome, WarningOutcome.silent);
    });

    test('the bound is configurable and actually consulted', () {
      // Three days stale warns at the default and is silent at 5, so the
      // parameter is genuinely read rather than shadowed by the constant.
      WarningOutcome atBound(int days) => WarningPolicy.decide(
            now: at(utc, 2026, 8, 6, 10),
            watchedZone: utc,
            away: holiday,
            linkAccepted: true,
            activeFrom: activeFrom,
            lastConfirmedDay: null,
            lastReconcileAt: at(utc, 2026, 8, 3, 12),
            verification: Verification.unreachable,
            staleAwayAfterDays: days,
          ).outcome;

      expect(atBound(2), WarningOutcome.warnUnverifiableAway);
      expect(atBound(5), WarningOutcome.silent);
    });
  });

  group('the silent branches are ordered, not merely all silent', () {
    // Every pair here is silent-vs-silent, so nothing observable changes at the
    // policy boundary — only which reason is reported. That still matters:
    // ADR-0004 makes lost access a health-panel item keyed on the reason, and a
    // re-paired link whose cache still holds an old lastConfirmedDay would
    // otherwise report checkInRecorded where beforeActiveFrom is true.
    test('revoked outranks beforeActiveFrom', () {
      expect(
        decide(linkAccepted: false, from: day('2026-08-20')).silenceReason,
        SilenceReason.linkRevoked,
      );
    });

    test('revoked outranks a recorded check-in', () {
      expect(
        decide(linkAccepted: false, lastConfirmedDay: day('2026-08-05'))
            .silenceReason,
        SilenceReason.linkRevoked,
      );
    });

    test('beforeActiveFrom outranks a recorded check-in', () {
      expect(
        decide(from: day('2026-08-20'), lastConfirmedDay: day('2026-08-05'))
            .silenceReason,
        SilenceReason.beforeActiveFrom,
      );
    });
  });

  group('a clock that moves backwards cannot fake a verification', () {
    test('a reconcile stamped in the FUTURE is not fresh', () {
      // The device clock jumped back. lastReconcileAt is now later than today,
      // so a bare `gap <= 2` passes on a negative number and the watcher is
      // silenced for as long as the skew lasts, on a verification that never
      // happened. §11's rule is that skew is surfaced, never silently trusted.
      final decision = decide(
        away: holiday,
        lastReconcileAt: at(utc, 2026, 8, 20, 12),
        verification: Verification.unreachable,
      );
      expect(decision.outcome, WarningOutcome.warnUnverifiableAway);
    });

    test('today itself still counts as fresh', () {
      expect(
        decide(away: holiday, lastReconcileAt: at(utc, 2026, 8, 6, 9)).outcome,
        WarningOutcome.silent,
      );
    });
  });

  group('an absurd away period cannot silence a family indefinitely', () {
    // The threat the cap exists for: a ten-year away document reaching a
    // watcher. It cannot arrive by a normal write — AwayRules rejects it — but
    // it can arrive by being READ, and ADR-0001 says a read that succeeds is
    // trusted. Nothing is stale here: the read works perfectly, every day, and
    // returns the same absurd answer, so no other guard in the design fires.
    final tenYears =
        AwayPeriod(from: day('2026-08-01'), through: day('2036-08-16'));

    test('it silences only to the cap, then the app speaks again', () {
      // D is 2026-08-05 — inside both the real and the clamped period.
      expect(
        decide(away: tenYears, lastReconcileAt: at(utc, 2026, 8, 6, 9))
            .silenceReason,
        SilenceReason.awayVerified,
        reason: 'the days legitimately marked away are still covered',
      );

      // D is 2026-11-05 — past the sanity bound at 2026-09-29, though the
      // stored document still claims to cover it for another decade.
      final past = decide(
        away: tenYears,
        now: at(utc, 2026, 11, 6, 10),
        lastReconcileAt: at(utc, 2026, 11, 6, 9),
      );
      expect(tenYears.coversAsStored(day('2026-11-05')), isTrue,
          reason: 'the premise: the stored period does claim this day');
      expect(past.outcome, WarningOutcome.warnOnline);
    });

    test('and it is bounded even ten years out', () {
      final farFuture = decide(
        away: tenYears,
        now: at(utc, 2035, 1, 2, 10),
        lastReconcileAt: at(utc, 2035, 1, 2, 9),
      );
      expect(farFuture.outcome, WarningOutcome.warnOnline);
    });

    test('the decision reports the period it actually honoured', () {
      final decision =
          decide(away: tenYears, lastReconcileAt: at(utc, 2026, 8, 6, 9));
      expect(decision.away, tenYears.clampedToSanityBound());
      expect(decision.away!.through, day('2026-09-29'));
      expect(decision.away, isNot(tenYears),
          reason: 'the copy must not promise a date the app will not honour');
    });

    test('an ordinary period is unaffected', () {
      final decision =
          decide(away: holiday, lastReconcileAt: at(utc, 2026, 8, 6, 9));
      expect(decision.away, holiday);
      expect(decision.silenceReason, SilenceReason.awayVerified);
    });
  });

  group('away edges', () {
    test('the day from starts is covered', () {
      final decision = decide(
        away: AwayPeriod(from: day('2026-08-05'), through: day('2026-08-10')),
        lastReconcileAt: at(utc, 2026, 8, 6, 9),
      );
      expect(decision.silenceReason, SilenceReason.awayVerified);
    });

    test('the day through ends is covered', () {
      final decision = decide(
        away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-05')),
        lastReconcileAt: at(utc, 2026, 8, 6, 9),
      );
      expect(decision.silenceReason, SilenceReason.awayVerified);
    });

    test('the day after through warns, even with the cache fresh', () {
      final decision = decide(
        away: AwayPeriod(from: day('2026-08-01'), through: day('2026-08-04')),
        lastReconcileAt: at(utc, 2026, 8, 6, 9),
      );
      expect(decision.outcome, WarningOutcome.warnOnline);
    });

    test('a period that expired long ago does not silence', () {
      final decision = decide(
        away: AwayPeriod(from: day('2026-07-01'), through: day('2026-07-10')),
        lastReconcileAt: at(utc, 2026, 8, 6, 9),
      );
      expect(decision.outcome, WarningOutcome.warnOnline);
    });
  });
}
