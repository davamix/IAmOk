// Mutation testing for Phase 5's Dart logic.
//
//   node tools/mutate-dart.mjs
//
// Needs no emulator and no device — everything here is pure domain and
// application code, which is exactly what `docs/testing/strategy.md` requires of
// anything a test has to reason about.
//
// Each entry below is **one line made wrong on purpose**, and the suite is
// expected to go RED. A mutation the suite does not notice is a line nothing
// asserts. See `mutate-runner.mjs` for the three properties this harness
// guarantees — it can read its subprocess, its no-op control has to pass, and a
// mutation that does not compile is refused rather than scored.
//
//
// ## What these lists deliberately do NOT cover, so the score is read correctly
//
// Every mutation here is a **Phase 5 or Phase 6 surface**. The score is a
// statement about those, not about the suite, and the difference matters
// because the risk in this design sits somewhere else as well.
//
// **`AwayPeriod` came off this list at the Phase 6 gate**, which is the point:
// it sat here for five phases as a type nothing read, and it is now what every
// away decision on both sides runs through. `AwayRecord` and the watched
// reconcile's away half joined it.
//
// Still not mutated, and named so nobody mistakes the number for coverage:
// `DayKey`, `ReminderPolicy`, `WarningPolicy`, either reconciler, the
// false-warning correction path, `AlarmIds` (whose per-process stability is a
// `CLAUDE.md` constraint and the premise the correction path rests on), the
// `onCheckInCreated` fan-out, and `firestore.rules` — which has 75 tests and no
// mutation coverage at all.
//
// Those are most of the pure functions `docs/testing/strategy.md` says the risk
// lives in. Extending the lists there is worth more than adding another Phase 5
// mutation; a harness grown past what it is run against stops being run.
//
// **When a mutation SURVIVES, suspect the mutation first.** Three of Phase 5's
// Dart mutations came back unexpected and two of them were bad: one added a
// branch that fires exactly when the original already does, one mutated a line
// the loop under test did not ride on. Only the third — `recordPairing`'s
// monotonicity guard — was a real gap, and it is pinned below.

import { mutate, report, run } from './mutate-runner.mjs';

const suite = async () => run('flutter', ['test']);

// `flutter test` prints one of these two, always. Requiring both phrases is
// what makes an EMPTY capture `UNREADABLE` instead of silently reading as a
// failing suite — the Phase 4 encoding failure, which reported five mutations
// as caught because it could not read anything at all.
suite.phrases = {
  green: ['All tests passed!'],
  red: ['Some tests failed.', 'Test failed. See exception logs above.'],
};

/**
 * **The compile gate, and it was missing.**
 *
 * `mutate-runner.mjs` only enforces *"a mutation that does not compile is
 * REFUSED"* when a `compile` callback is supplied, and this driver supplied
 * none. What happens without it is worse than nothing: a Dart compile error
 * makes `flutter test` end with `Some tests failed.` — verbatim the red phrase
 * below — so a mutation that never compiled is classified RED and printed as
 * **CAUGHT**. "14 of 14 caught" could not tell you whether the suite noticed or
 * the analyzer did.
 *
 * That is not hypothetical. The first `Home.build` mutation written at this gate
 * was `ref.watch(otherProvider)`, an undefined name; a human spotted it. Under
 * the harness as first committed it would have been scored as caught, on the one
 * tool whose entire job is to distrust a green result.
 *
 * `flutter analyze` rather than a build: it is the cheapest thing that rejects an
 * undefined name, and this repo already treats a clean analyze as the bar.
 */
const compile = () => run('flutter', ['analyze', '--no-pub']);

/**
 * Every mutation names the file it edits, so one harness covers the phase.
 *
 * `from` must match **exactly once** across the file — the runner refuses an
 * ambiguous match rather than editing a line it did not mean to.
 */
const groups = [
  {
    file: 'lib/domain/onboarding/home_route.dart',
    mutations: [
      {
        name: 'decide: completed no longer ends the flow alone',
        from: 'if (!choices.completed) {',
        to: 'if (!choices.completed && !choices.wantsToBeWatched) {',
        why:
          'This is the Phase 5 review defect restored — answering question 1 ' +
          'ejects the reader from onboarding, so question 2 is never asked and ' +
          '`completed` stays false for ever. It was found on two phones, and ' +
          'again by testing through a second door after the same-day fix made ' +
          'it latent rather than absent.',
      },
      {
        name: 'decide: a revoked link counts as a role',
        from: 'final isWatched = choices.wantsToBeWatched || hasAcceptedWatchedLinks;',
        to: 'final isWatched = choices.wantsToBeWatched;',
        why:
          'Drops the reinstall case. §1 chose Google Sign-In because the uid ' +
          'survives a reinstall, so a cold install can begin with an empty ' +
          'store and a user who already watches three people — and routing on ' +
          'the stored answers alone strands them.',
      },
      {
        name: 'decide: the watcher list stops being reachable',
        from: 'watcherListReachable: isWatcher,',
        to: 'watcherListReachable: false,',
        why:
          'A both-roles user loses their only route to the list that re-arms ' +
          'their warning alarms. `main.dart` has warned about exactly this for ' +
          'three phases.',
      },
      {
        name: 'decide: the sign-in guard is inverted',
        from: 'if (!signedIn) {',
        to: 'if (signedIn) {',
        why:
          'Every link is keyed by a uid; nothing below that guard is ' +
          'answerable without one. Inverted, a signed-in user is sent back to ' +
          'onboarding for ever and a signed-out one is routed on their links.',
        // **Rewritten after the compile gate REFUSED it.** It was `if (false)`,
        // which `flutter analyze` rejects as dead code — and before the gate
        // existed that scored as CAUGHT, because a Dart compile error ends
        // `flutter test` with `Some tests failed.`, the red phrase verbatim.
        // Inversion is the mutation operator that always compiles.
      },
    ],
  },
  {
    file: 'lib/domain/entities/invite_code.dart',
    mutations: [
      {
        name: 'tryParse: an off-alphabet character is skipped, not refused',
        from: 'if (!alphabet.contains(char)) return null;',
        to: 'if (!alphabet.contains(char)) continue;',
        why:
          'A typed `O` or `0` would be silently DROPPED rather than refused — ' +
          'which is the realistic wrong implementation, not an absent check. ' +
          'The reader then gets "That code is not right" for a five-character ' +
          'code they cannot see is five characters, and §7 excludes those ' +
          'glyphs precisely because the code is read aloud.',
        // Rewritten after the compile gate refused `if (false)` as dead code.
        // This is a better mutation anyway: skipping is what somebody would
        // actually write by mistake; deleting the guard is not.
      },
      {
        name: 'tryParse: the length stops being checked',
        from: 'return code.length == length ? code : null;',
        to: 'return code;',
        why: 'A five-character code becomes a round trip that cannot succeed.',
      },
      {
        name: 'tryParse: hyphens are no longer stripped',
        from: "if (char == ' ' || char == '-') continue;",
        to: "if (char == ' ') continue;",
        why:
          'Somebody who types the grouping they were read aloud is refused. ' +
          'The comment above that line says exactly this.',
      },
    ],
  },
  {
    file: 'lib/data/invite_service.dart',
    mutations: [
      {
        name: 'refusalForCode: internal is called unreachable again',
        from: "_ => PairingRefusal.serverFault,",
        to: "_ => PairingRefusal.couldNotReach,",
        why:
          'The defect this phase closed: a phone that carried a request and ' +
          'read an answer is told to check its internet connection.',
      },
      {
        name: 'refusalForCode: a timeout becomes a server fault',
        from: "'unavailable' || 'deadline-exceeded' => PairingRefusal.couldNotReach,",
        to: "'unavailable' || 'deadline-exceeded' => PairingRefusal.serverFault,",
        why:
          'The other direction — a phone with no radio is told to try again ' +
          'in a moment, and never told to check its connection.',
      },
      {
        name: 'pairingFrom: a consumed code reports as unknown',
        from: "      case 'consumed':\n        return const PairingRefused(PairingRefusal.alreadyUsed);",
        to: "      case 'consumed':\n        return const PairingRefused(PairingRefusal.unknownCode);",
        why:
          '*Check it and type it again* against *ask for a new one* is the ' +
          'difference between a loop that can succeed and one that cannot.',
      },
      {
        name: 'pairingFrom: an empty link id still pairs',
        from: 'if (linkId is! String || linkId.isEmpty) {',
        to: 'if (linkId is! String) {',
        why:
          'An empty id would be recorded as a link, and every read made ' +
          'against it afterwards is refused.',
      },
    ],
  },
  {
    file: 'lib/application/onboarding_controller.dart',
    mutations: [
      {
        name: 'recordPairing: the monotonicity guard is dropped',
        from: 'wantsToBeWatched: asWatched == true ? true : null,',
        to: 'wantsToBeWatched: asWatched,',
        why:
          '**This one was a real gap in Phase 5**, and it is here because it ' +
          'is the mutation that found it. The guard is what makes recording ' +
          'monotone — without it a pairing screen can ERASE an answer rather ' +
          'than record one. No production caller passes false, so the suite ' +
          'was green until a test called it with false.',
      },
    ],
  },
  {
    file: 'lib/domain/entities/watched_audience.dart',
    mutations: [
      {
        name: 'WatchedAudience: the accepted-link filter is inverted',
        from: 'if (!link.isAccepted) continue;',
        to: 'if (link.isAccepted) continue;',
        why:
          'The Tap screen would name only the people who will NOT be notified ' +
          '— a false claim to the person the app is for, on her daily screen, ' +
          'and it flips the 21:00 reminder to promising a family that is not ' +
          'there.',
        // Rewritten after the compile gate refused `if (false)` as dead code.
      },
      {
        name: 'WatchedAudience: two watchers with one name collapse',
        from: 'if (seen.add(link.watcherUid)) accepted.add(link);',
        to: 'if (seen.add(link.watcherName)) accepted.add(link);',
        why:
          'Two different people genuinely called "Ana" would become one, ' +
          'silently dropping a real watcher from a list whose only job is to ' +
          'be complete.',
      },
    ],
  },
  // ---------------------------------------------------------------- Phase 6
  //
  // `AwayPeriod` becoming live code is what made this worth doing: it sat on
  // the "not mutated" list above for five phases while nothing read it, and it
  // is now the type every away decision on both sides runs through.
  //
  // Away is the first feature here whose failure mode is **silence**, so these
  // are chosen for the direction that produces no notification and no error —
  // a period honoured when it should not be, or one that never ends.
  {
    file: 'lib/domain/away/away_period.dart',
    mutations: [
      {
        name: 'AwayPeriod.covers: `through` stops being inclusive',
        from: 'return day >= honoured.from && day <= honoured.through;',
        to: 'return day >= honoured.from && day < honoured.through;',
        why:
          'The last away day would stop being an away day: she is reminded ' +
          'three times on a day she is away, and every watcher is warned about ' +
          'it the next morning. `through` being INCLUSIVE is the whole reason ' +
          'the picker copy says "Last day away" rather than "until".',
      },
      {
        name: 'AwayPeriod.covers: reads the document instead of the clamp',
        from: 'final honoured = clampedToSanityBound();',
        to: 'final honoured = this;',
        why:
          'A ten-year away document would be honoured for ten years, and ' +
          'nothing could catch it: the read SUCCEEDS every day, so nothing is ' +
          'stale and the staleness bound never fires. That is the failure ' +
          'clampedToSanityBound exists for, and it is silent on both sides.',
      },
      {
        name: 'AwayPeriod.hasExpiredOn: off by one, in the silent direction',
        from: 'bool hasExpiredOn(DayKey today) => today > through;',
        to: 'bool hasExpiredOn(DayKey today) => today > through.next;',
        why:
          'The period would outlive itself by a day. Section 12 makes expiry ' +
          'ARITHMETIC precisely so nothing can be lost in delivery — this is ' +
          'the arithmetic, and getting it wrong is exactly the "away that ' +
          'never ends" the exit criterion is written against.',
      },
      {
        name: 'AwayPeriod.cancelOn: cancels by deleting rather than truncating',
        from: 'if (cancelDay <= from) return null;',
        to: 'if (cancelDay <= from.next) return null;',
        why:
          'ADR-0001 decision 5. Deleting mid-period retroactively UN-COVERS ' +
          'the days already spent away, so the next device to refresh its ' +
          'cache warns about a day the person really was away — a false claim ' +
          'to a family, which is the worst thing this app can do.',
      },
      {
        name: 'AwayRules.validateCreate: retroactive away is allowed',
        from: 'if (period.from < today) return AwayRejection.retroactiveFrom;',
        to:
          'if (period.from < today.minusDays(400)) ' +
          'return AwayRejection.retroactiveFrom;',
        why:
          'No retroactive away (section 12) is an owner decision, and the ' +
          'client check is the one that is exact — the rules clause is ' +
          'deliberately slack because it cannot compare a local date to a UTC ' +
          'instant.',
      },
      {
        name: 'AwayRules.validateUpdate: `from` stops being immutable',
        from:
          'if (period.from != existing.from) return AwayRejection.fromChanged;',
        to:
          'if (period.from == existing.from) return AwayRejection.fromChanged;',
        why:
          'Inverted rather than removed, so it compiles and so the mutation ' +
          'is observable in both directions. ADR-0001 decision 6 froze `from` ' +
          'because truncation rewrites a document whose `from` is already in ' +
          'the past.',
      },
    ],
  },
  {
    file: 'lib/domain/away/away_record.dart',
    mutations: [
      {
        name: 'AwayRecord.tryCreate: a missing name costs the PERIOD',
        from: 'if (period == null) return null;',
        to: 'if (period == null || setByName == null) return null;',
        why:
          'ADR-0003 Absence case, got wrong. An older build or an admin write ' +
          'omitting the name would become NO away period at all — so a family ' +
          'is warned about days somebody really did mark away. The name may ' +
          'degrade; the period may not.',
      },
      {
        name: 'AwayRecord.nameToShowFor: the reader is told they did it',
        from: 'if (forUid != null && wasSetBy(forUid)) return null;',
        to: 'if (forUid == null) return null;',
        why:
          'The owner decision of 2026-08-27, inverted. She would read ' +
          '"Mum marked you away" about her own action — addressed in the ' +
          'wrong grammatical person — and a watcher would read their own name ' +
          'back on the row they just set.',
      },
      {
        name: 'AwayRecord: an unbounded name reaches the notification tray',
        from: 'if (trimmed.length > AwayRules.nameMaxLength) return null;',
        to: 'if (trimmed.length > AwayRules.nameMaxLength * 1000) return null;',
        why:
          'ADR-0003 names a long clinical string as the injection this bound ' +
          'exists for. The rules bound only what THIS app clients write; a ' +
          'document arriving by any other door reaches every family member ' +
          'phone through this field.',
      },
    ],
  },
  {
    file: 'lib/application/watched_reconcile_service.dart',
    mutations: [
      {
        name: 'the watched reconcile: a FAILED read clears the away cache',
        from: 'if (read.succeeded) await store.setSelfAway(read.awayOrNull);',
        to: 'await store.setSelfAway(read.awayOrNull);',
        why:
          'ADR-0001 decision 1 — a read that FAILED is not an answer. A ' +
          'timeout, a permission denial and an App Check rejection all happen ' +
          'while online, and clearing on any of them nags an elderly person ' +
          'through a holiday and tells her family she has stopped checking in.',
      },
      {
        name: 'the watched reconcile: away stops suppressing reminders',
        from: '      away: away?.period,',
        to: '      away: null,',
        why:
          'The `away` parameter has been threaded through every policy since ' +
          'Phase 1 for this line. Passing null re-arms all three reminders on ' +
          'every away day, which is the visible half of the feature.',
      },
    ],
  },
];

const all = [];
for (const group of groups) {
  console.log('');
  console.log(`== ${group.file}`);
  all.push(
    ...(await mutate({
      file: group.file,
      mutations: group.mutations,
      suite,
      compile,
    })),
  );
}

process.exit(report(all));
