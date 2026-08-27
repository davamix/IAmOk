// **The toolchain this code is type-checked against matches the one it runs on.**
//
// Needs no emulator: it reads `package.json` files and nothing else, so it runs
// in the same `npm --prefix functions test` glob as everything else and costs
// nothing.
//
// ## Why this file exists
//
// Cloud Functions runs **Node 22** — `functions/package.json` pins
// `"engines": {"node": "22"}` — while `@types/node` arrived transitively under
// `firebase-admin` at **26.2.0**, four majors ahead. `tsc` therefore accepted
// Node 23, 24, 25 and 26 APIs that do not exist in production, and
// `deploy-notes.md` said `@types/node` was *"not installed"*, which was false
// for as long as the claim stood.
//
// Phase 5 made it load-bearing rather than theoretical: `invites.ts` imports
// `node:crypto`, this project's first Node builtin. A Node 23+ API would
// type-check clean, run clean in the emulator (which is Node 24 on this
// machine — newer still), and fail only **after deploy**.
//
// It was pinned to `^22` at the Phase 5 gate. What was missing is anything that
// would notice it drifting back: `npm i -D @types/node`, `@latest`, or
// `npm audit fix --force` all move it to 26, and `tsc --noEmit` stays clean
// because 26 is a superset. The infrastructure reviewer found the gap.
//
// `tsconfig.json`'s `target` is `es2023`, not a Node version, so **the types
// are what constrain the API surface**. That is why this assertion is the
// control and not a nicety.

'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { describe, it } = require('node:test');

const read = (...parts) =>
  JSON.parse(readFileSync(join(__dirname, '..', ...parts), 'utf8'));

describe('the Node toolchain', () => {
  it('pins the engine to the runtime Cloud Functions deploys', () => {
    assert.equal(read('package.json').engines.node, '22');
  });

  it('type-checks against that runtime, not a newer one', () => {
    // The resolved copy, not the range — a range of `^22` with something else
    // hoisted into `node_modules` would still type-check against the wrong one.
    const resolved = read('node_modules', '@types', 'node', 'package.json');
    assert.ok(
      resolved.version.startsWith('22.'),
      `@types/node resolves to ${resolved.version}; Cloud Functions runs Node ` +
        '22, and a 23+ API would type-check clean, run clean in the emulator, ' +
        'and fail only after deploy',
    );

    // And the declared range agrees, so a fresh `npm install` cannot quietly
    // resolve something else.
    assert.match(
      read('package.json').devDependencies['@types/node'],
      /^\^22\./,
      'the declared range must keep it on 22.x',
    );
  });

  it('serves the compiled output, which is what the emulator and deploy run',
    () => {
      // `main` is `lib/`, never `src/`. Recorded here because it is the reason
      // `tools/mutate-runner.mjs` recompiles after restoring a mutated source —
      // a mutation left in `lib/` outlives the run with `git status` clean.
      assert.equal(read('package.json').main, 'lib/index.js');
    });
});
