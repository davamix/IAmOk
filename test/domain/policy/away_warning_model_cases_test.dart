import 'package:i_am_ok/domain/domain.dart';
import 'package:test/test.dart';

import '../../support/zones.dart';

/// The 18 cases of `tools/models/away_warning_model.dart`, ported.
///
/// The model is the executable specification for this decision — it is what
/// [ADR-0001][] was settled against, and it caught two defects that were
/// invisible to a prose reading of §10. Porting it here is what stops the
/// specification and the implementation from drifting apart once the model
/// stops being run.
///
/// Two deliberate differences from the model:
///
/// - The model's `Day` is a bare epoch ordinal with **no timezone**, which was
///   correct for settling an ordering question and is not what `DayKey` is.
///   These cases therefore run in UTC, so the model's tz-free framing carries
///   over exactly and the timezone behaviour is tested where it belongs.
/// - They run through [WatcherReconciler] rather than [WarningPolicy] alone.
///   The model's `decidedDesign` refreshes *and* decides in one function, and
///   the **ordering of those two steps is the entire content of ADR-0001** — so
///   the port must exercise the composition, not just the branches.
///
/// **[ADR-0004][] partially supersedes the model.** The model has a single
/// `readOk` flag covering "a timeout, a permission denial, or an App Check
/// rejection" alike. ADR-0004 splits those: a timeout means the phone really is
/// offline, a refusal means it is online and working, and only one of those two
/// sentences can be true at a time. All 18 cases below remain correct **read as
/// the unreachable interpretation**, and are ported that way. `S15` and `S16`
/// — the two that turn on `readOk` — gain refused-interpretation counterparts
/// as `S15r` and `S16r`, which the model cannot express.
///
/// [ADR-0001]: ../../../docs/architecture/decisions/0001-away-cache-precedence.md
/// [ADR-0004]: ../../../docs/architecture/decisions/0004-refused-is-not-unreachable.md
void main() {
  final holiday =
      AwayPeriod(from: day('2026-08-01'), through: day('2026-08-20'));
  final shortened =
      AwayPeriod(from: day('2026-08-01'), through: day('2026-08-04'));

  /// The alarm day. D is the day before.
  final d06 = at(utc, 2026, 8, 6, 10);
  final d22 = at(utc, 2026, 8, 22, 10);

  final link = Link(
    watchedUid: 'mum',
    watcherUid: 'ana',
    status: LinkStatus.accepted,
    watchedName: 'Mum',
    watchedTimezone: 'Etc/UTC',
    activeFrom: day('2026-07-01'),
    createdAt: at(utc, 2026, 7, 1),
  );

  /// A `lastReconcileAt` on the given day. Midday, so the calendar-day
  /// staleness comparison is unambiguous.
  DateTime reconciled(String iso) {
    final d = day(iso);
    return at(utc, d.year, d.month, d.day, 12);
  }

  WarningDecision decide({
    required DateTime now,
    AwayPeriod? cachedAway,
    DayKey? lastConfirmedDay,
    String? lastReconcileAt,
    Set<DayKey> checkins = const {},
    AwayPeriod? firestoreAway,
    bool online = true,
    bool readOk = true,
    bool refused = false,
  }) {
    // The model's `readOk == false` while online is ported as a TIMEOUT — the
    // unreachable reading — which is what preserves its stated expectations.
    // `refused: true` is the ADR-0004 reading the model cannot express.
    final read = refused
        ? const FirestoreRead.refused(RefusedCause.permissionDenied)
        : online && readOk
            ? FirestoreRead.succeeded(
                checkInDays: checkins, away: firestoreAway)
            : FirestoreRead.unreachable(online
                ? UnreachableCause.timeout
                : UnreachableCause.offline);

    return WatcherReconciler.reconcile(
      now: now,
      link: link,
      watcherZone: utc,
      cache: WatcherCache(
        away: cachedAway,
        lastConfirmedDay: lastConfirmedDay,
        lastReconcileAt:
            lastReconcileAt == null ? null : reconciled(lastReconcileAt),
      ),
      read: read,
      currentlyScheduled: const {},
    ).decision;
  }

  /// Asserts silence **and the rule that produced it**.
  ///
  /// Eight of the eighteen cases below expect silence. Asserting only the
  /// outcome would let every one of them pass against a policy that is silent
  /// about everything — and silence is the one failure this app cannot detect
  /// in itself, which is exactly why `SilenceReason` exists.
  void expectSilent(WarningDecision decision, SilenceReason reason) {
    expect(decision.outcome, WarningOutcome.silent);
    expect(decision.silenceReason, reason);
  }

  test('S1  no away, no check-in, online', () {
    expect(decide(now: d06).outcome, WarningOutcome.warnOnline);
  });

  test('S2  check-in in Firestore, cache empty, online', () {
    expectSilent(decide(now: d06, checkins: days(['2026-08-05'])),
        SilenceReason.checkInRecorded);
  });

  test('S3  check-in already cached, offline', () {
    expectSilent(
      decide(now: d06, lastConfirmedDay: day('2026-08-05'), online: false),
      SilenceReason.checkInRecorded,
    );
  });

  test('S4  D is before link.activeFrom', () {
    expectSilent(decide(now: at(utc, 2026, 6, 15, 10)),
        SilenceReason.beforeActiveFrom);
  });

  test('S5  away active, nudge received, online', () {
    expectSilent(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-05',
        firestoreAway: holiday,
      ),
      SilenceReason.awayVerified,
    );
  });

  test('S6  away SET, nudge LOST, online — self-heals via tier 1', () {
    expectSilent(decide(now: d06, firestoreAway: holiday),
        SilenceReason.awayVerified);
  });

  test('S7  away expired naturally, offline throughout', () {
    // Expiry is arithmetic (§12) — it needs no network.
    expect(
      decide(
        now: d22,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-01',
        online: false,
      ).outcome,
      WarningOutcome.warnOffline,
    );
  });

  test('S8  away CANCELLED early, nudge LOST, online — the ADR-0001 defect', () {
    expect(
      decide(now: d06, cachedAway: holiday, lastReconcileAt: '2026-08-01').outcome,
      WarningOutcome.warnOnline,
    );
  });

  test('S9  away SHORTENED, nudge LOST, online', () {
    expect(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-01',
        firestoreAway: shortened,
      ).outcome,
      WarningOutcome.warnOnline,
    );
  });

  test('S10 away cancelled, nudge RECEIVED, online', () {
    expect(decide(now: d06, lastReconcileAt: '2026-08-05').outcome,
        WarningOutcome.warnOnline);
  });

  test('S11 offline, no away, nothing cached', () {
    expect(decide(now: d06, online: false).outcome, WarningOutcome.warnOffline);
  });

  test('S12 away CANCELLED, nudge lost, OFFLINE + stale — truly home', () {
    expect(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-01',
        online: false,
      ).outcome,
      WarningOutcome.warnUnverifiableAway,
    );
  });

  test('S13 away GENUINELY ACTIVE, offline + stale — truly away', () {
    // The device input is IDENTICAL to S12. ADR-0001 accepts this cost
    // deliberately: offline, the two are indistinguishable, so the design
    // chooses which error to prefer and prefers speaking.
    expect(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-01',
        firestoreAway: holiday,
        online: false,
      ).outcome,
      WarningOutcome.warnUnverifiableAway,
    );
  });

  test('S14 away active, offline but recently verified', () {
    expectSilent(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-05',
        firestoreAway: holiday,
        online: false,
      ),
      SilenceReason.awayVerified,
    );
  });

  test('S15 away ACTIVE, online, but the READ FAILS', () {
    // A failed read must NOT be read as "no away document".
    expectSilent(
      decide(
        now: d06,
        cachedAway: holiday,
        lastReconcileAt: '2026-08-05',
        firestoreAway: holiday,
        readOk: false,
      ),
      SilenceReason.awayVerified,
    );
  });

  test('S16 no away at all, online, but the READ FAILS', () {
    // Cannot verify => must not claim.
    expect(decide(now: d06, readOk: false).outcome, WarningOutcome.warnOffline);
  });

  group('ADR-0004 — the readings the model conflates', () {
    test('S15r away ACTIVE, online, read REFUSED', () {
      // The model's S15 expects silent, because a fresh cached away is trusted
      // for two days. That holds for a timeout. It does not hold for a refusal:
      // ADR-0001's bound is calibrated for a phone in a pocket, and a refusal
      // is neither transient nor self-healing.
      expect(
        decide(
          now: d06,
          cachedAway: holiday,
          lastReconcileAt: '2026-08-05',
          firestoreAway: holiday,
          refused: true,
        ).outcome,
        WarningOutcome.warnAccessLost,
      );
    });

    test('S16r no away at all, online, read REFUSED', () {
      // The model's S16 expects warnOffline. The phone is not offline — it is
      // online and talking to the server, which refused. Saying "your phone has
      // been offline" would be a false claim about the device.
      final outcome = decide(now: d06, refused: true).outcome;
      expect(outcome, WarningOutcome.warnAccessLost);
      expect(outcome, isNot(WarningOutcome.warnOffline));
    });

    test('a refusal still leaves the cache untouched — ADR-0001 is unchanged', () {
      // The split is about which SENTENCE is true, never about whether a failed
      // read may clear the cache. It may not, for any cause.
      final result = WatcherReconciler.reconcile(
        now: d06,
        link: link,
        watcherZone: utc,
        cache: WatcherCache(
          away: holiday,
          lastReconcileAt: reconciled('2026-08-05'),
        ),
        read: const FirestoreRead.refused(RefusedCause.appCheckRejected),
        currentlyScheduled: const {},
      );
      expect(result.cache.away, holiday);
      expect(result.cache.lastReconcileAt, reconciled('2026-08-05'));
    });

    test('a revoked link never reaches the refused branch', () {
      // §8 denies the checkins read once a link is revoked, so revocation is
      // the commonest cause of a permission denial. It is caught locally first,
      // which is why the access-lost message is reserved for genuine faults.
      final result = WatcherReconciler.reconcile(
        now: d06,
        link: link.copyWith(status: LinkStatus.revoked),
        watcherZone: utc,
        cache: const WatcherCache.empty(),
        read: const FirestoreRead.refused(RefusedCause.permissionDenied),
        currentlyScheduled: const {},
      );
      expect(result.decision.outcome, WarningOutcome.silent);
      expect(result.decision.silenceReason, SilenceReason.linkRevoked);
    });
  });

  test('S17 away started today, cancelled today, nudge lost', () {
    // Nothing elapsed => delete, not truncate.
    final startedToday =
        AwayPeriod(from: day('2026-08-06'), through: day('2026-08-20'));
    expect(startedToday.cancelOn(day('2026-08-06')), isNull);
    expect(
      decide(
        now: d06,
        cachedAway: startedToday,
        lastReconcileAt: '2026-08-06',
        firestoreAway: startedToday.cancelOn(day('2026-08-06')),
      ).outcome,
      WarningOutcome.warnOnline,
    );
  });

  test('S18 away cached + stale, but D already confirmed', () {
    // She tapped during away (allowed, §12) — evidence outranks doubt.
    expectSilent(
      decide(
        now: d06,
        cachedAway: holiday,
        lastConfirmedDay: day('2026-08-05'),
        lastReconcileAt: '2026-08-01',
        online: false,
      ),
      SilenceReason.checkInRecorded,
    );
  });

  group('the timeline the ADR was written against', () {
    // Mum away 01-04 Aug. Ana cancels on the 5th and THE NUDGE IS LOST. Mum is
    // home from the 5th and never taps again.
    //
    // The superseded ordering warned first on 22 August instead of the 6th:
    // sixteen days of wrongful silence, in a state §17 rates as
    // indistinguishable from working.
    final trueAway =
        AwayPeriod(from: day('2026-08-01'), through: day('2026-08-04'));
    final julyCheckins =
        days([for (var i = 1; i <= 31; i++) '2026-07-${i.toString().padLeft(2, '0')}']);
    final cancelDay = day('2026-08-05');
    final truncated = holiday.cancelOn(cancelDay);

    ({DayKey? firstWarning, int wrongfulSilence, int spurious}) simulate() {
      var cache = const WatcherCache.empty();
      DayKey? firstWarning;
      var wrongfulSilence = 0;
      var spurious = 0;

      for (var i = 0; i <= 24; i++) {
        final today = day('2026-08-01').plusDays(i);
        final now = at(utc, today.year, today.month, today.day, 10);
        final storedAway = today < cancelDay ? holiday : truncated;

        // The only nudge that lands announces the away on 1 Aug. The 5 Aug
        // cancellation nudge is lost — Doze, throttling, force-stop.
        if (i == 0) {
          cache = cache.applyRead(
            FirestoreRead.succeeded(checkInDays: julyCheckins, away: holiday),
            at: now,
          );
        }

        final result = WatcherReconciler.reconcile(
          now: now,
          link: link,
          watcherZone: utc,
          cache: cache,
          read: FirestoreRead.succeeded(
              checkInDays: julyCheckins, away: storedAway),
          currentlyScheduled: const {},
        );
        cache = result.cache;

        final d = today.previous;
        final shouldBeSilent =
            d < link.activeFrom || trueAway.covers(d) || julyCheckins.contains(d);

        if (result.decision.isWarning) {
          firstWarning ??= today;
          if (shouldBeSilent) spurious++;
        } else if (!shouldBeSilent) {
          wrongfulSilence++;
        }
      }
      return (
        firstWarning: firstWarning,
        wrongfulSilence: wrongfulSilence,
        spurious: spurious
      );
    }

    test('warns on the 6th, with no wrongful silence and nothing spurious', () {
      final outcome = simulate();
      expect(outcome.firstWarning, day('2026-08-06'));
      expect(outcome.wrongfulSilence, 0,
          reason: 'the superseded ordering produced 16');
      expect(outcome.spurious, 0,
          reason: 'cancel-by-delete produced 1 — truncation is what avoids it');
    });
  });
}
