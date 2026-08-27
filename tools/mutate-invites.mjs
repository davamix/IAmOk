// Mutation testing for Phase 5's two Cloud Functions.
//
//   pwsh -File tools/functions-mutate.ps1          # the wrapper that finds Java
//   node tools/mutate-invites.mjs                  # if java is already on PATH
//
// **This one needs the Firestore emulator**, because `invites.test.js` exercises
// `createInviteFor` and `redeemInviteFor` against a real emulated Firestore
// rather than a fake — a transaction that reads its own writes is exactly the
// thing a fake would get wrong for you. So each mutation costs one
// `firebase emulators:exec`, which is why this harness is slower than its Dart
// twin and why it is a separate file rather than another group in one.
//
// > **Only one emulator script may run at a time.** `tools/emulators.ps1`,
// > `tools/rules-test.ps1` and `tools/functions-test.ps1` all want ports 8080 /
// > 9099 / 5001, and so does this. Stop whichever is up first; the failure is
// > loud but reads like a broken script rather than a busy port.
//
// ## `tsc` runs before every mutation, and a mutation it rejects is REFUSED
//
// Phase 5's first Functions pass reported two `DID NOT COMPILE`, and the harness
// **refused to score them** rather than counting them as caught. That is the
// whole point: a mutation TypeScript rejects proves nothing about the tests,
// because the tests never ran. Both were rewritten to compile and both then
// failed the suite, which is the result that means something.
//
// The compiled output is also what the emulator serves — `main` is `lib/`, not
// `src/` — so building is not optional here in the way it is optional for Dart.
// A mutation applied to `src/` and not compiled would be tested against the
// PREVIOUS build, and every mutation would come back SURVIVED.
//
//
// ## What these lists deliberately do NOT cover, so the score is read correctly
//
// Every mutation here is a **Phase 5 surface**. "14 of 14 caught" is a statement
// about this phase's code, not about the suite, and the difference matters
// because the risk in this design sits somewhere else.
//
// Not mutated, and named so nobody mistakes the number for coverage:
// `DayKey`, `AwayPeriod`, `ReminderPolicy`, `WarningPolicy`, either reconciler,
// the false-warning correction path, `AlarmIds` (whose per-process stability is
// a `CLAUDE.md` constraint and the premise the correction path rests on), the
// `onCheckInCreated` fan-out, and `firestore.rules` — which has 75 tests and no
// mutation coverage at all.
//
// Those are exactly the six pure functions `docs/testing/strategy.md` says the
// risk lives in. Extending the lists there is worth more than adding another
// Phase 5 mutation; it is deliberately not done here, because a harness grown
// past what it is run against stops being run.
//
// One mandatory case is *nearly* covered and misses the half that matters:
// `dayKeyInZone` is mutated for its null handling but never for **whose zone it
// is**. `strategy.md` names that explicitly — *"`activeFrom` in the watched
// person's timezone, not the redeemer's"* — and swapping the two compiles,
// changes a real family's `activeFrom` by a day, and is not in the list below.
// The deterministic link id `{watchedUid}_{watcherUid}` is likewise unmutated;
// swapping the operands breaks double-redemption idempotence.
//
// See `mutate-runner.mjs` for the properties this shares with the Dart harness.

import { mutate, report, run } from './mutate-runner.mjs';

const PROJECT = 'demo-i-am-ok';

const compile = () => run('npm', ['--prefix', 'functions', 'run', 'build']);

const suite = async () =>
  run('firebase', [
    'emulators:exec',
    '--only',
    'firestore',
    '--project',
    PROJECT,
    'npm --prefix functions test',
  ]);

// **`node --test`'s own summary line, matched as a pattern.**
//
// A run matching neither is UNREADABLE and aborts the harness rather than being
// scored as a failing suite. That is the defence against the Phase 4 encoding
// failure: an empty capture must not be indistinguishable from a red suite, or a
// mutation harness — which is *hoping* for red — calls every mutation caught.
//
// It also covers the documented Windows trap from a different angle: on this
// machine no Firebase CLI exit code is a result, since `emulators:exec` prints
// its work and then dies intermittently with a libuv assertion in
// `src\win\async.c`. The runner never looks at the exit code; it reads the text.
//
// **The first version of these two lines was wrong, and the guard caught it.**
// It looked for `# fail 0` — TAP's format — while `node --test`'s DEFAULT
// reporter is `spec`, which prints `\u2139 fail 0`. Nothing matched, the no-op
// control came back UNREADABLE, and the harness refused to score anything. It
// also listed `fail 1` … `fail 5` by hand, so six or more failures would have
// matched neither list. Hence a pattern, anchored to the line, with the count as
// a group: it cannot be defeated by a reporter's prefix or by an unusual count.
suite.phrases = {
  green: [/^\W*fail 0\s*$/m],
  red: [/^\W*fail [1-9]\d*\s*$/m],
};

const groups = [
  {
    file: 'functions/src/invites.ts',
    mutations: [
      {
        name: 'generateCode: the alphabet gains an ambiguous character',
        from: "export const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';",
        to: "export const INVITE_ALPHABET = 'ABCDEFGHIJKLMNPQRSTUVWXYZ23456789';",
        why:
          '§7 excludes `I`, `O`, `0` and `1` because the code is read aloud by ' +
          'an elderly person. The Dart client would then refuse a code this ' +
          'backend had just minted — and `invite_code.dart` asserts the two ' +
          'alphabets character for character precisely so they cannot drift.',
      },
      {
        name: 'the TTL becomes a week',
        from: 'export const INVITE_TTL_MS = 24 * 60 * 60 * 1000;',
        to: 'export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;',
        why:
          'The owner chose 24 hours, and it is the term OPEN-QUESTIONS.md #11 ' +
          "does the brute-force arithmetic against. It is also the number the " +
          'share message now quotes to somebody else.',
      },
      {
        name: 'the collision retry catches everything again',
        from: 'if (code !== 6 || attempt === MAX_CODE_ATTEMPTS - 1) throw error;',
        to: 'if (attempt === MAX_CODE_ATTEMPTS - 1) throw error;',
        why:
          'A transient DEADLINE_EXCEEDED on a write that had in fact landed ' +
          'mints a SECOND live code for the same person — doubling their ' +
          'guessing surface and orphaning one nothing sweeps until it expires.',
      },
      {
        name: 'the sweep stops being awaited',
        from: '  await Promise.allSettled(\n    stale.map((id) => invites.doc(id).delete().catch(() => undefined)),\n  );',
        to: '  void Promise.allSettled(\n    stale.map((id) => invites.doc(id).delete().catch(() => undefined)),\n  );',
        why:
          '**The exact defect the Phase 5 review found**, and the one this ' +
          'harness most needs to catch. Cloud Run throttles the container the ' +
          'moment the response is written, so unawaited work is dropped — and ' +
          'the emulator, where nothing throttles, is the only place it passes. ' +
          'If this SURVIVES, the test is asserting the local process rather ' +
          'than the deployed behaviour.',
      },
      {
        name: 'a consumed invite is reused as live',
        from: 'if (consumed) continue;',
        to: 'if (false) continue;',
        why:
          'A spent code would be handed back as the caller’s live one, so ' +
          'the code on their screen is one `redeemInvite` will refuse.',
      },
      {
        name: 'the sweep deletes live invites too',
        from: 'const expired = expiresAt.toMillis() <= nowMs;',
        to: 'const expired = expiresAt.toMillis() >= nowMs;',
        why:
          'Inverts the sweep: every code a family is currently working with is ' +
          'deleted on the next call to the screen that shows it, and every ' +
          'expired one is kept for ever.',
        // **Rewritten after the first run REFUSED it.** It was `if (expired)` ->
        // `if (true)`, which TypeScript rejects: the `continue` makes the
        // assignment below unreachable, so `live` narrows to `never`. A mutation
        // the compiler rejects proves nothing about the tests. Inverting the
        // comparison changes the same behaviour and still type-checks.
      },
      {
        name: 'reuse picks the code that dies FIRST',
        from: 'if (live === null || expiresAt.toMillis() > live.expiresAt.toMillis()) {',
        to: 'if (live === null || expiresAt.toMillis() < live.expiresAt.toMillis()) {',
        why:
          'Re-entering the screen would shorten the window a family is already ' +
          'working inside, which is the opposite of what reuse is for.',
      },
      {
        name: 'redeem: a revoked link is restored by a spent code',
        from: "const linkAccepted = (linkSnap.data() ?? {})['status'] === 'accepted';",
        to: 'const linkAccepted = linkSnap.exists;',
        why:
          '**The defect two reviewers found independently.** A revoked watcher ' +
          're-typing their old code — still sitting in the message thread — was ' +
          'told the pairing was live while every read they made was refused. ' +
          'Nothing was restored; the app said otherwise.',
      },
      {
        name: 'redeem: an expired code still pairs',
        from: 'if (!isTimestamp(expiresAt) || expiresAt.toMillis() <= now.getTime()) {',
        to: 'if (!isTimestamp(expiresAt)) {',
        why: 'The 24-hour expiry stops existing on the only path that enforces it.',
      },
      {
        name: 'redeem: expiry is off by one at the boundary',
        from: 'expiresAt.toMillis() <= now.getTime()',
        to: 'expiresAt.toMillis() < now.getTime()',
        why:
          'The exact-boundary case. A code is dead AT its expiry instant, not ' +
          'one millisecond after it.',
      },
      {
        name: 'redeem: a link to yourself is allowed',
        from: "if (watcherUid === watchedUid) return { status: 'self' as const };",
        to: "if (false) return { status: 'self' as const };",
        why:
          'A self-link warns you about your own missed day and names you as ' +
          'your own watcher on your own Tap screen.',
      },
      {
        name: 'redeem: a consumed code is redeemed again',
        from: "if (typeof consumedBy === 'string' && consumedBy.length > 0) {",
        to: "if (typeof consumedBy === 'string' && consumedBy.length > 99) {",
        why:
          'Codes are single-use by design (§8). Two watchers off one code is ' +
          'the enumeration guard failing open.',
      },
      {
        name: 'redeem: an unresolvable timezone is defaulted, not refused',
        from: `    const activeFrom = dayKeyInZone(now, watchedProfile.timezone);
    if (activeFrom === null) return { status: 'unusable-timezone' as const };`,
        to: `    const activeFrom =
      dayKeyInZone(now, watchedProfile.timezone) ?? '1970-01-01';`,
        why:
          '`Link.tryWatchedZone` calls an unresolvable zone "a permanently ' +
          'silent watcher, which is the one failure this app cannot detect in ' +
          'itself". Defaulting writes exactly that link quietly, at the one ' +
          'moment a human is watching the screen and could act on it.',
        // **Rewritten after the first run REFUSED it.** `if (false)` left
        // `activeFrom` typed `string | null`, which `RedeemOutcome` does not
        // accept — the guard is what narrows it. Supplying the default the
        // guard exists to prevent is the same mutation, and it compiles.
      },
      {
        name: 'redeem: the two missing-profile answers are confused',
        from: `    if (watchedProfile === null) {
      return { status: 'watched-profile-missing' as const };
    }`,
        to: `    if (watchedProfile === null) {
      return { status: 'watcher-profile-missing' as const };
    }`,
        why:
          'The two point at DIFFERENT phones. One says *"Ask them to open I Am ' +
          'Ok on their phone"*, the other *"This phone could not finish getting ' +
          'ready"* — so confusing them sends a family to the handset that is ' +
          'working.',
        // **Rewritten after the first run REFUSED it.** `if (false)` leaves
        // `watchedProfile` possibly null at four later uses, because that guard
        // is what narrows it. Swapping the ANSWER keeps the narrowing and still
        // changes what a family reads.
      },
      {
        name: 'redeem: an unknown code is called expired',
        from: "if (!inviteSnap.exists) return { status: 'unknown-code' as const };",
        to: "if (!inviteSnap.exists) return { status: 'expired' as const };",
        why:
          'A typo would be answered *"That code has expired. Ask for a new ' +
          'one."* — which sends a family to mint a code they do not need ' +
          'instead of re-reading the one they have.',
        // **The first version of this mutation was BAD, and it SURVIVED — which
        // is the case the harness's own docstring warns about.** It was
        // `if (false)`, and a non-existent invite then falls through to
        // `inviteSnap.data() ?? {}`, so `watchedUid` is undefined and the guard
        // two lines below returns `unknown-code` ANYWAY. Identical observable
        // behaviour, so nothing could have caught it. Scoring that as a test gap
        // would have been the harness lying in the other direction.
        //
        // Two guards returning the same status for the same input is a
        // reasonable belt-and-braces; what it means here is that this mutation
        // has to change the ANSWER to prove anything.
      },
      {
        name: 'dayKeyInZone: a bad zone yields a day instead of null',
        from: `  } catch {
    // RangeError for a zone ICU does not recognise. Not a throw, because the
    // caller turns it into a refusal a human can act on rather than a 500.
    return null;
  }`,
        to: `  } catch {
    // RangeError for a zone ICU does not recognise. Not a throw, because the
    // caller turns it into a refusal a human can act on rather than a 500.
    return '1970-01-01';
  }`,
        why:
          'The refusal above depends on this returning null. A default here ' +
          'writes a quietly broken link with an `activeFrom` in 1970, which ' +
          'backdates every warning decision the watcher will ever make.',
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
