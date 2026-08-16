// ignore_for_file: avoid_print
// =============================================================================
// I Am Ok — the watcher warning decision as a state machine.
//
// Executable annex to ADR-0001 (docs/architecture/decisions/0001-away-cache-
// precedence.md). This is a MODEL, not application code: it exists so the
// decision can be re-checked by running it rather than by re-reading prose.
//
//     dart run tools/models/away_warning_model.dart
//
// `currentDesign` is ARCHITECTURE.md §10 as it was written BEFORE ADR-0001, and
// is kept deliberately: it is the regression the decision exists to prevent.
// `decidedDesign` is what §10 now says. Both run the same suite.
//
// SCOPE. Timezone is out of the model — the question was the ORDER in which the
// truth tiers are consulted, and tz is orthogonal to it. A `Day` here is a bare
// calendar-day ordinal, which is what DayKey reduces to once the watched
// person's tz has been applied. The late-arrival correction path (§10) is a
// separate handler and is not modelled.
//
// PARTIALLY SUPERSEDED by ADR-0004 (docs/architecture/decisions/0004-refused-
// is-not-unreachable.md). `readOk` below covers "a timeout, a permission
// denial, or an App Check rejection" alike, and ADR-0004 splits those: a
// timeout means the phone really is offline, a refusal means it is online and
// working, and only one of those sentences can be true at a time. A refusal now
// produces a FOURTH outcome, warnAccessLost, which this model cannot express.
//
// All 18 cases below remain correct READ AS THE UNREACHABLE INTERPRETATION, and
// are ported that way in test/domain/policy/away_warning_model_cases_test.dart,
// where S15 and S16 gain refused-interpretation counterparts. The model is left
// runnable and unchanged on purpose: its job is the ADR-0001 ordering question,
// and its `superseded: 4 / decided: 0` result is still the regression guard for
// that. Do not extend it without deciding that invariant's fate first.
// =============================================================================

// ─────────────────────────────────────────────────────────────── primitives ──

class Day implements Comparable<Day> {
  final int ordinal; // days since epoch. No clock, no tz, no DST.
  const Day(this.ordinal);

  static Day iso(String s) {
    final p = s.split('-').map(int.parse).toList();
    return Day(DateTime.utc(p[0], p[1], p[2]).millisecondsSinceEpoch ~/ 86400000);
  }

  Day plus(int n) => Day(ordinal + n);
  Day minus(int n) => Day(ordinal - n);
  int gap(Day other) => ordinal - other.ordinal;

  @override
  int compareTo(Day o) => ordinal.compareTo(o.ordinal);
  bool operator <(Day o) => ordinal < o.ordinal;
  bool operator >(Day o) => ordinal > o.ordinal;
  bool operator <=(Day o) => ordinal <= o.ordinal;
  bool operator >=(Day o) => ordinal >= o.ordinal;
  @override
  bool operator ==(Object o) => o is Day && o.ordinal == ordinal;
  @override
  int get hashCode => ordinal;
  @override
  String toString() {
    final d = DateTime.fromMillisecondsSinceEpoch(ordinal * 86400000, isUtc: true);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

class AwayPeriod {
  final Day from;
  final Day through; // INCLUSIVE (§7)
  const AwayPeriod(this.from, this.through);
  bool covers(Day d) => d >= from && d <= through;
  @override
  String toString() => '$from..$through';
}

class Link {
  final Day activeFrom; // never warn about days before the link existed (§7)
  const Link(this.activeFrom);
}

/// LocalStore (§6) — the only thing a bare background isolate can see.
class DeviceState {
  AwayPeriod? cachedAway;
  Day? lastConfirmedDate;
  Set<Day> warningsShownFor = {};

  /// Last SUCCESSFUL read of tier 1.
  ///
  /// In the real LocalStore this is a full **timestamp**, not a date — §10
  /// renders "offline since 10:14" from it (ADR-0002). It is modelled as a
  /// `Day` here because the staleness rule is deliberately calendar-day
  /// granular: the alarm attempts a reconcile once a day, so "verified within
  /// 2 days" compares date components, not a 48-hour duration. The timestamp
  /// exists for the message, not for the comparison.
  Day? lastReconcileAt;

  DeviceState({this.cachedAway, this.lastConfirmedDate, this.lastReconcileAt});
}

/// Firestore (tier 1) plus the network, as they are at a moment in time.
class World {
  final Set<Day> checkins;
  final AwayPeriod? away; // null == not away / cancelled
  final bool online;

  /// "The read succeeded" is NOT "the device has a network". A timeout, a
  /// permission-denied, or an App Check rejection all fail while online. Only a
  /// read that SUCCEEDED and returned nothing proves the away document is gone;
  /// a failed read proves nothing and must never clear the cache.
  final bool readOk;

  const World({
    this.checkins = const {},
    this.away,
    this.online = true,
    this.readOk = true,
  });

  bool get canTrustReads => online && readOk;
}

enum Outcome { silent, warnOnline, warnOffline, warnUnverifiableAway }

/// The approved copy. See docs/ui-ux/screens.md — these are the strings, and
/// the point of each is that it claims exactly what the device can support.
String message(Outcome o) => switch (o) {
      Outcome.silent => '',
      Outcome.warnOnline => 'No check-in from Mum yesterday.',
      Outcome.warnOffline => 'No check-in received from Mum yesterday — your '
          'phone has been offline since 22:10.',
      Outcome.warnUnverifiableAway =>
        "Can't check on Mum — your phone has been offline since Tuesday 10:14. "
            'She was marked away until Saturday 22 August.',
    };

/// ADR-0001: a cached away period may silence for at most this many days
/// without a successful re-verification. The watcher's alarm attempts a
/// reconcile daily, so exceeding this means three consecutive failures.
const int kStaleAwayAfterDays = 2;

typedef AlarmFn = Outcome Function(DeviceState, World, Day today, Link,
    [int staleAfterDays]);

/// §9 `onAwayChanged` landing on the device: a nudge with no authority that
/// triggers a reconcile. Identical for both designs.
void deliverNudge(DeviceState s, World w, Day today) {
  if (!w.canTrustReads) return;
  s.cachedAway = w.away;
  s.lastReconcileAt = today;
}

/// How a cancellation must be WRITTEN so already-elapsed away days stay covered
/// without ever violating the §8 invariant `through >= from`.
AwayPeriod? applyCancel(AwayPeriod a, Day cancelDay) {
  if (cancelDay <= a.from) return null; // nothing elapsed — delete outright
  return AwayPeriod(a.from, cancelDay.minus(1)); // preserve the elapsed days
}

// ──────────────────────────────── SUPERSEDED: §10 steps 1-8 as first written ──

Outcome currentDesign(DeviceState s, World w, Day today, Link link,
    [int staleAfterDays = kStaleAwayAfterDays]) {
  final d = today.minus(1); // 1. last COMPLETED day

  if (d < link.activeFrom) return Outcome.silent; // 2.

  // 3. THE SHORT CIRCUIT. Reads tier 3 before tier 1 has been attempted, so
  //    step 5 is unreachable in exactly the case it was credited with handling.
  if (s.cachedAway != null && s.cachedAway!.covers(d)) return Outcome.silent;

  if (s.lastConfirmedDate != null && s.lastConfirmedDate! >= d) {
    return Outcome.silent; // 4.
  }

  if (w.canTrustReads) {
    // 5. Positive path only — a stale cached away is never cleared here.
    final hasCheckin = w.checkins.contains(d);
    final hasAway = w.away != null && w.away!.covers(d);
    if (hasCheckin || hasAway) {
      if (hasCheckin) s.lastConfirmedDate = d;
      if (w.away != null) s.cachedAway = w.away;
      s.lastReconcileAt = today;
      return Outcome.silent;
    }
    s.warningsShownFor.add(d); // 8.
    return Outcome.warnOnline; // 6.
  }

  s.warningsShownFor.add(d); // 8.
  return Outcome.warnOffline; // 7.
}

// ──────────────────────────────────────────── DECIDED: ADR-0001, §10 as now ──

Outcome decidedDesign(DeviceState s, World w, Day today, Link link,
    [int staleAfterDays = kStaleAwayAfterDays]) {
  final d = today.minus(1);

  // reconcile() FIRST. Firestore is the source of truth (§3); the cache is what
  // you read when you cannot reach it. Assigning w.away wholesale is what
  // CLEARS a cancelled away — gated on canTrustReads, never on connectivity.
  if (w.canTrustReads) {
    s.cachedAway = w.away;
    if (w.checkins.contains(d) &&
        (s.lastConfirmedDate == null || s.lastConfirmedDate! < d)) {
      s.lastConfirmedDate = d;
    }
    s.lastReconcileAt = today;
  }

  if (d < link.activeFrom) return Outcome.silent;

  // A recorded check-in for D settles the question on its own, and outranks any
  // away reasoning: tapping during an away day is allowed (§12), so a confirmed
  // day must stay silent even when the cached away has gone stale.
  if (s.lastConfirmedDate != null && s.lastConfirmedDate! >= d) {
    return Outcome.silent;
  }

  if (s.cachedAway != null && s.cachedAway!.covers(d)) {
    final fresh = s.lastReconcileAt != null &&
        today.gap(s.lastReconcileAt!) <= staleAfterDays;
    if (fresh) return Outcome.silent;
    s.warningsShownFor.add(d);
    return Outcome.warnUnverifiableAway;
  }

  s.warningsShownFor.add(d);
  return w.canTrustReads ? Outcome.warnOnline : Outcome.warnOffline;
}

// ─────────────────────────────────────────────────────────────────── cases ──

class Case {
  final String id;
  final String name;
  final DeviceState Function() state;
  final World world;
  final Day today;
  final Outcome expected;
  final String note;

  Case(this.id, this.name,
      {required this.state,
      required this.world,
      required this.today,
      required this.expected,
      this.note = ''});
}

final link = Link(Day.iso('2026-07-01'));
final holiday = AwayPeriod(Day.iso('2026-08-01'), Day.iso('2026-08-20'));
final shortened = AwayPeriod(Day.iso('2026-08-01'), Day.iso('2026-08-04'));
final d06 = Day.iso('2026-08-06'); // alarm day; D = 2026-08-05
final d22 = Day.iso('2026-08-22'); // alarm day; D = 2026-08-21

final cases = <Case>[
  Case('S1', 'no away, no check-in, online',
      state: () => DeviceState(),
      world: const World(),
      today: d06,
      expected: Outcome.warnOnline),

  Case('S2', 'check-in in Firestore, cache empty, online',
      state: () => DeviceState(),
      world: World(checkins: {Day.iso('2026-08-05')}),
      today: d06,
      expected: Outcome.silent),

  Case('S3', 'check-in already cached, offline',
      state: () => DeviceState(lastConfirmedDate: Day.iso('2026-08-05')),
      world: const World(online: false),
      today: d06,
      expected: Outcome.silent),

  Case('S4', 'D is before link.activeFrom',
      state: () => DeviceState(),
      world: const World(),
      today: Day.iso('2026-06-15'),
      expected: Outcome.silent),

  Case('S5', 'away active, nudge received, online',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-05')),
      world: World(away: holiday),
      today: d06,
      expected: Outcome.silent),

  Case('S6', 'away SET, nudge LOST, online',
      state: () => DeviceState(),
      world: World(away: holiday),
      today: d06,
      expected: Outcome.silent,
      note: 'self-heals: cache empty, so tier 1 is reached'),

  Case('S7', 'away expired naturally, offline throughout',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-01')),
      world: const World(online: false),
      today: d22,
      expected: Outcome.warnOffline,
      note: 'expiry is arithmetic (§12) — needs no network'),

  Case('S8', 'away CANCELLED early, nudge LOST, online',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-01')),
      world: const World(),
      today: d06,
      expected: Outcome.warnOnline,
      note: 'ADR-0001: the defect'),

  Case('S9', 'away SHORTENED, nudge LOST, online',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-01')),
      world: World(away: shortened),
      today: d06,
      expected: Outcome.warnOnline,
      note: 'same root cause'),

  Case('S10', 'away cancelled, nudge RECEIVED, online',
      state: () => DeviceState(lastReconcileAt: Day.iso('2026-08-05')),
      world: const World(),
      today: d06,
      expected: Outcome.warnOnline),

  Case('S11', 'offline, no away, nothing cached',
      state: () => DeviceState(),
      world: const World(online: false),
      today: d06,
      expected: Outcome.warnOffline),

  Case('S12', 'away CANCELLED, nudge lost, OFFLINE + stale',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-01')),
      world: const World(online: false),
      today: d06,
      expected: Outcome.warnUnverifiableAway,
      note: 'truly home. ADR-0001: speak'),

  Case('S13', 'away GENUINELY ACTIVE, offline + stale',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-01')),
      world: World(away: holiday, online: false),
      today: d06,
      expected: Outcome.warnUnverifiableAway,
      note: 'truly away. Device input IDENTICAL to S12 — accepted cost'),

  Case('S14', 'away active, offline but recently verified',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-05')),
      world: World(away: holiday, online: false),
      today: d06,
      expected: Outcome.silent,
      note: 'within kStaleAwayAfterDays — the cache is still trusted'),

  Case('S15', 'away ACTIVE, online, but the READ FAILS',
      state: () =>
          DeviceState(cachedAway: holiday, lastReconcileAt: Day.iso('2026-08-05')),
      world: World(away: holiday, readOk: false),
      today: d06,
      expected: Outcome.silent,
      note: 'a failed read must NOT be read as "no away document"'),

  Case('S16', 'no away at all, online, but the READ FAILS',
      state: () => DeviceState(),
      world: const World(readOk: false),
      today: d06,
      expected: Outcome.warnOffline,
      note: 'cannot verify => must not claim'),

  Case('S17', 'away started today, cancelled today, nudge lost',
      state: () => DeviceState(
          cachedAway: AwayPeriod(d06, Day.iso('2026-08-20')), lastReconcileAt: d06),
      world: World(
          away: applyCancel(AwayPeriod(d06, Day.iso('2026-08-20')), d06)),
      today: d06,
      expected: Outcome.warnOnline,
      note: 'nothing elapsed => delete, not truncate'),

  Case('S18', 'away cached + stale, but D already confirmed',
      state: () => DeviceState(
          cachedAway: holiday,
          lastConfirmedDate: Day.iso('2026-08-05'),
          lastReconcileAt: Day.iso('2026-08-01')),
      world: const World(online: false),
      today: d06,
      expected: Outcome.silent,
      note: 'she tapped during away (allowed, §12) — evidence outranks doubt'),
];

// ────────────────────────────────────────────────────────────────── harness ──

String pad(String s, int n) => s.length >= n ? s : s + ' ' * (n - s.length);

int runSuite(String title, AlarmFn fn) {
  print('');
  print(title);
  print('-' * 86);
  var failures = 0;
  for (final c in cases) {
    final got = fn(c.state(), c.world, c.today, link, kStaleAwayAfterDays);
    final ok = got == c.expected;
    if (!ok) failures++;
    print('  ${pad(c.id, 6)}${pad(c.name, 46)}${pad(got.name, 24)}'
        '${ok ? "ok" : "FAIL  <<<"}');
  }
  print('-' * 86);
  print('  $failures failure(s) of ${cases.length}');
  return failures;
}

enum CancelAs { delete, truncate }

/// Ground truth, independent of any device's knowledge: Mum was genuinely away
/// 01–04 Aug, home from the 5th, and never tapped again.
final trueAway = AwayPeriod(Day.iso('2026-08-01'), Day.iso('2026-08-04'));
final julyCheckins = <Day>{
  for (var i = 0; i < 31; i++) Day.iso('2026-07-01').plus(i)
};

Outcome ideal(Day today) {
  final d = today.minus(1);
  if (d < link.activeFrom) return Outcome.silent;
  if (trueAway.covers(d)) return Outcome.silent;
  if (julyCheckins.contains(d)) return Outcome.silent;
  return Outcome.warnOnline;
}

void timeline(String design, AlarmFn fn, CancelAs how) {
  final s = DeviceState();
  final cancelOn = Day.iso('2026-08-05');
  final truncated = applyCancel(holiday, cancelOn);

  final got = <String>[], want = <String>[];
  var wrongfulSilence = 0, spurious = 0;
  Day? firstWarn;

  for (var i = 0; i <= 24; i++) {
    final today = Day.iso('2026-08-01').plus(i);
    final away = today < cancelOn
        ? holiday
        : (how == CancelAs.delete ? null : truncated);
    final w = World(checkins: julyCheckins, away: away);

    // The only nudge that lands announces the away on 1 Aug. The 5 Aug
    // cancellation nudge is LOST — Doze, throttling, force-stop.
    if (i == 0) deliverNudge(s, w, today);

    final o = fn(s, w, today, link, kStaleAwayAfterDays);
    final exp = ideal(today);
    if (o != Outcome.silent) firstWarn ??= today;
    if (o == Outcome.silent && exp != Outcome.silent) wrongfulSilence++;
    if (o != Outcome.silent && exp == Outcome.silent) spurious++;
    got.add(o == Outcome.silent ? '.' : '!');
    want.add(exp == Outcome.silent ? '.' : '!');
  }

  print('');
  print('  $design   cancel written as: ${how.name}');
  print('    ideal  ${want.join()}');
  print('    actual ${got.join()}');
  print('           ^Aug01                   ^Aug25    . silent   ! warns');
  print('    first warning ${firstWarn ?? "never"} (correct: 2026-08-06)   '
      '$wrongfulSilence wrongful silence, $spurious spurious');
}

void main() {
  print('=' * 86);
  print('I Am Ok — watcher warning decision   (ADR-0001)');
  print('=' * 86);

  final a = runSuite('SUPERSEDED — §10 as first written', currentDesign);
  final b = runSuite('DECIDED — ADR-0001', decidedDesign);

  print('');
  print('=' * 86);
  print('TIMELINE  Mum away 01-04 Aug. Ana cancels on the 5th; THE NUDGE IS LOST.');
  print('          Mum is home from the 5th and never taps again.');
  print('=' * 86);
  timeline('SUPERSEDED', currentDesign, CancelAs.truncate);
  timeline('DECIDED   ', decidedDesign, CancelAs.delete);
  timeline('DECIDED   ', decidedDesign, CancelAs.truncate);

  print('');
  print('=' * 86);
  print('APPROVED COPY');
  print('=' * 86);
  for (final o in Outcome.values.where((o) => o != Outcome.silent)) {
    print('  ${pad(o.name, 24)}${message(o)}');
  }

  print('');
  print('=' * 86);
  print('RESULT   superseded: $a failure(s)   decided: $b failure(s)');
  print('=' * 86);
  if (b != 0) throw StateError('the decided design must pass its own suite');
}
