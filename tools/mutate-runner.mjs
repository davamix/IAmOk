// The engine behind `mutate-dart.mjs` and `mutate-invites.mjs`.
//
//   node tools/mutate-dart.mjs
//   node tools/mutate-invites.mjs
//
// A mutation harness answers one question: **would the suite notice if this
// line were wrong?** It edits a source file, runs the tests, and expects them to
// FAIL. A mutation the suite does not notice is a gap — a line nothing asserts.
//
// ## Why this is in the repo at all
//
// It was a scratch script through Phase 5, and "42 mutations, all as expected,
// with a passing no-op control" was therefore a claim nobody could re-run. The
// previous phase's headline lesson was a harness producing a **green report by
// being broken**, which makes the harness the one artefact worth keeping.
//
// ## The three properties this file exists to guarantee
//
// **1. It can read its subprocess's output, and proves it before scoring.**
// `CLAUDE.md`: *"A harness that decides pass/fail by searching a subprocess's
// output must prove it can read that output, and carry a no-op control that has
// to pass."* On 2026-08-25 a Python runner collected `flutter test`'s stdout
// through Windows' default cp1252, the reader thread died on a UTF-8 byte, and
// the captured text was empty. Absent "All tests passed!" reads as *the mutation
// was caught*, so all five mutations were reported `FAILS (good)` — a green
// report from a broken harness, on the one tool whose entire job is to distrust
// a green suite.
//
// Two defences, and they are separate. The decoding is explicit UTF-8 (`spawn`
// with no encoding, `Buffer.concat`, `toString('utf8')`) rather than whatever
// the console code page is. And [classify] refuses to return a verdict from
// output it cannot recognise: a run whose text matches neither the pass phrase
// nor the fail phrase is `UNREADABLE`, which aborts the whole harness. Silence
// is never scored.
//
// **2. The no-op control has to pass, and it runs first.** A mutation that is
// the identity — the file written back byte for byte — must produce a GREEN
// suite. If it does not, either the tree was already red or the harness is not
// running what it thinks it is, and every result after it would be noise. It
// runs first so the harness costs one suite run to disprove itself.
//
// **3. A mutation that does not compile is REFUSED, not scored.** A mutation the
// compiler rejects proves nothing about the tests — the tests never ran. Phase
// 5's Functions pass hit this twice and refusing to score them is what made the
// numbers mean anything. `DID_NOT_COMPILE` is its own verdict and the harness
// exits non-zero on it, because the mutation needs rewriting.
//
// ## And when a mutation comes back unexpected, suspect the mutation first
//
// Three Dart mutations came back unexpected in Phase 5 and **two of them were
// bad mutations**: one added a branch that fires exactly when the original
// already does, one mutated a line the loop under test did not ride on. Only the
// third was a real gap. Scoring the two as "caught" would have been the harness
// lying in the other direction.
//
// ## The source file is restored in a `finally`, always
//
// A harness that leaves a mutated line in the tree after a Ctrl-C is worse than
// no harness. Every write is wrapped, and the original text is held in memory
// from before the first mutation.

import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

/**
 * A run of the suite: its exit code and its output, decoded as UTF-8.
 *
 * **Any argument containing a space is quoted**, and that is not tidiness.
 * `shell: true` hands the command line to `cmd.exe` by **concatenating** the
 * args with spaces and escaping nothing — Node warns about it as DEP0190. So
 * `['emulators:exec', ..., 'npm --prefix functions test']` reaches `firebase` as
 * five separate arguments, and it answers `error: unknown option '--prefix'`.
 *
 * That happened on this harness's first Functions run. It is worth writing down
 * because of how it *presented*: the harness captured all 33 characters of that
 * error perfectly, matched neither the pass pattern nor the fail pattern, and
 * refused to score anything — reporting `UNREADABLE`, which reads at a glance
 * like a decoding fault. It was the opposite. **The guard was right and the
 * caller was wrong**, twice in a row, and both times the harness declining to
 * guess is what made the real cause findable.
 */
export function run(command, args, options = {}) {
  const shell = process.platform === 'win32';
  const quoted = shell
    ? args.map((arg) => (/\s/.test(arg) ? `"${arg}"` : arg))
    : args;

  return new Promise((resolve, reject) => {
    const child = spawn(command, quoted, {
      // `shell: true` on Windows, because `flutter`, `npm` and `firebase` are
      // all `.bat`/`.cmd` shims that `spawn` cannot execute directly.
      shell,
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
    });

    // **Buffers, not strings.** Setting an encoding here hands decoding to
    // Node's stream layer per chunk, which can split a multi-byte sequence
    // across two chunks. Concatenating the bytes and decoding once cannot.
    const out = [];
    const err = [];
    child.stdout.on('data', (chunk) => out.push(chunk));
    child.stderr.on('data', (chunk) => err.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      resolve({
        code,
        text:
          Buffer.concat(out).toString('utf8') +
          Buffer.concat(err).toString('utf8'),
      });
    });
  });
}

/**
 * A suite run, as a verdict — and never as a guess.
 *
 * [green] and [red] are what the suite prints when it passes and when it fails:
 * plain strings, or `RegExp`s where a count has to be matched. **Both are
 * required**, and a run matching neither is `UNREADABLE` rather than being read
 * as red. That is the whole defence against the cp1252 failure: absent output
 * must not be indistinguishable from a failing suite, because the mutation
 * harness is *looking* for a failing suite and would call it success.
 *
 * **This fired on its first real run, on a mistake in the caller.** The
 * Functions driver's first version looked for `# fail 0` — TAP's format —
 * while `node --test`'s default reporter prints `\u2139 fail 0`. Nothing
 * matched, the control came back `UNREADABLE`, and the harness refused to score
 * a single mutation. A version that read "no pass phrase" as failure would have
 * reported all sixteen as caught from a suite it had never read, which is
 * precisely the Phase 4 failure this file exists to prevent.
 *
 * The lesson taken: **match a pattern, not a guessed literal**, wherever the
 * phrase carries a count. The old caller also listed `fail 1` … `fail 5` by
 * hand, so six or more failures would have matched neither list.
 */
export function classify({ text }, { green, red }) {
  const matches = (pattern) =>
    typeof pattern === 'string' ? text.includes(pattern) : pattern.test(text);

  const sawGreen = green.some(matches);
  const sawRed = red.some(matches);

  if (sawGreen && !sawRed) return 'GREEN';
  if (sawRed && !sawGreen) return 'RED';
  // Both, or neither. "Both" happens when a suite prints a per-file summary and
  // one file failed; the callers below pass patterns specific enough that it
  // means something is being read wrong, so it is treated the same way.
  return 'UNREADABLE';
}

/**
 * Runs a mutation list against one source file.
 *
 * Each mutation is `{ name, from, to, why }`. `from` must appear **exactly
 * once** in the file — an ambiguous match is a mutation that might be editing
 * something other than the line it names, so it is refused before anything runs.
 */
export async function mutate({ file, mutations, suite, compile }) {
  const original = readFileSync(file, 'utf8');
  const results = [];

  const write = (text) => writeFileSync(file, text, { encoding: 'utf8' });

  try {
    // ---------------------------------------------------------------- control
    //
    // First, and it must pass. Everything after it is meaningless otherwise.
    process.stdout.write('control (no mutation) ... ');
    write(original);
    if (compile) {
      const built = await compile();
      if (built.code !== 0) {
        console.log('DID NOT COMPILE');
        console.log(built.text);
        throw new Error(
          'the UNMUTATED tree does not compile. Nothing below would mean ' +
            'anything.',
        );
      }
    }
    const control = classify(await suite(), suite.phrases);
    console.log(control);
    if (control !== 'GREEN') {
      throw new Error(
        control === 'UNREADABLE'
          ? 'the harness could not READ the suite output. It is not scoring ' +
            'anything until it can — an unread run is not a failing run, and ' +
            'reading it as one is how a broken harness reports every mutation ' +
            'as caught.'
          : 'the unmutated suite is RED. Fix the tree before mutating it.',
      );
    }

    // -------------------------------------------------------------- mutations
    for (const mutation of mutations) {
      const occurrences = original.split(mutation.from).length - 1;
      if (occurrences !== 1) {
        throw new Error(
          `mutation "${mutation.name}": its \`from\` matches ${occurrences} ` +
            'times, and it must match exactly once. A mutation that might be ' +
            'editing a different line than the one it names cannot be scored.',
        );
      }

      process.stdout.write(`${mutation.name} ... `);
      write(original.replace(mutation.from, mutation.to));

      if (compile) {
        const built = await compile();
        if (built.code !== 0) {
          console.log('DID NOT COMPILE — refusing to score');
          results.push({ ...mutation, verdict: 'DID_NOT_COMPILE' });
          continue;
        }
      }

      const verdict = classify(await suite(), suite.phrases);
      console.log(
        verdict === 'RED'
          ? 'CAUGHT'
          : verdict === 'GREEN'
            ? 'SURVIVED  <-- gap, or a bad mutation'
            : 'UNREADABLE',
      );
      results.push({ ...mutation, verdict });

      if (verdict === 'UNREADABLE') {
        throw new Error(
          'the harness could not read the suite output mid-run. Every result ' +
            'after this point would be a guess.',
        );
      }
    }
  } finally {
    // **Always.** A mutated line left in the tree is worse than no harness.
    write(original);
  }

  return results;
}

/** Prints the table and returns the process exit code. */
export function report(results) {
  const survived = results.filter((r) => r.verdict === 'GREEN');
  const uncompiled = results.filter((r) => r.verdict === 'DID_NOT_COMPILE');

  console.log('');
  console.log(`${results.length} mutations`);
  console.log(`  caught          ${results.filter((r) => r.verdict === 'RED').length}`);
  console.log(`  survived        ${survived.length}`);
  console.log(`  did not compile ${uncompiled.length}`);

  for (const r of survived) {
    console.log('');
    console.log(`SURVIVED  ${r.name}`);
    console.log(`  ${r.why}`);
    console.log(
      '  Check whether the MUTATION is bad before concluding the test is: ' +
        'two of three unexpected results in Phase 5 were bad mutations.',
    );
  }
  for (const r of uncompiled) {
    console.log('');
    console.log(`DID NOT COMPILE  ${r.name} — rewrite it; it proves nothing.`);
  }

  return survived.length > 0 || uncompiled.length > 0 ? 1 : 0;
}
