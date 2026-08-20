// Shared setup for the Firestore security-rules tests.
//
// EMULATOR ONLY, and belt and braces about it. `initializeTestEnvironment` is
// given an explicit host and port, so these tests talk to the emulator by
// construction; and the project id is `demo-i-am-ok`, which the Firebase tooling
// treats as a guaranteed-offline demo project — no credentials are used and the
// SDKs refuse to reach production for it. Neither half is sufficient on its own
// to be worth relying on, so both are here.
//
// Run them with `pwsh -File tools/rules-test.ps1`, which starts the emulator
// (and puts the Android Studio JBR on PATH, because `java` is not on PATH on
// this machine).

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, serverTimestamp, setDoc, Timestamp } from 'firebase/firestore';

const here = dirname(fileURLToPath(import.meta.url));

/** The rules under test — the same file that gets deployed. */
export const RULES_PATH = join(here, '..', 'firestore.rules');

// The cast. Roles live on links (§1), so these are just uids; who is watched
// and who is watching is a property of the link between them.
export const MUM = 'uid-mum'; // the watched person
export const ANA = 'uid-ana'; // a watcher, link accepted
export const BETO = 'uid-beto'; // a second watcher, link accepted
export const CARLA = 'uid-carla'; // a watcher whose link is REVOKED
export const STRANGER = 'uid-stranger'; // no link at all

export const linkId = (watchedUid, watcherUid) => `${watchedUid}_${watcherUid}`;

export async function newTestEnv() {
  return initializeTestEnvironment({
    projectId: 'demo-i-am-ok',
    firestore: {
      rules: readFileSync(RULES_PATH, 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
}

/**
 * Seeds the link graph with security rules DISABLED.
 *
 * Links are Function-written (§9), so there is no client path that could create
 * them and no way to seed them through the rules under test. The revoked link
 * is seeded alongside the accepted ones deliberately: every grant that keys on
 * `hasAcceptedLink` needs its denied half proven, and a revoked link is the
 * cheapest way for that grant to be wrong in production.
 */
export async function seedLinks(testEnv) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const base = {
      watchedUid: MUM,
      watchedName: 'Mum',
      watchedTimezone: 'Europe/Madrid',
      activeFrom: '2026-08-01',
      warningLocalTime: '10:00',
      createdAt: Timestamp.fromDate(new Date('2026-08-01T09:00:00Z')),
      acceptedAt: Timestamp.fromDate(new Date('2026-08-01T09:00:00Z')),
    };
    await setDoc(doc(db, 'links', linkId(MUM, ANA)), {
      ...base,
      watcherUid: ANA,
      watcherName: 'Ana',
      status: 'accepted',
    });
    await setDoc(doc(db, 'links', linkId(MUM, BETO)), {
      ...base,
      watcherUid: BETO,
      watcherName: 'Beto',
      status: 'accepted',
    });
    await setDoc(doc(db, 'links', linkId(MUM, CARLA)), {
      ...base,
      watcherUid: CARLA,
      watcherName: 'Carla',
      status: 'revoked',
    });
  });
}

/** Writes a document with the rules disabled, to set up an "already stored" state. */
export async function seedDoc(testEnv, path, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), ...path), data);
  });
}

// ── day labels ──────────────────────────────────────────────────────────────
//
// UTC, because that is the frame the RULES reason in. The app's day labels are
// in the watched person's zone (§11) and the two can differ by a day, which is
// exactly why the away clauses are slack. Tests that care about that boundary
// say so at the assertion.

export function dayKey(offsetDays = 0) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

/**
 * A valid away document, with the six fields the rules require.
 *
 * `setAt`/`updatedAt` default to `serverTimestamp()` because the rules require
 * them to equal `request.time` (ADR-0003 rule 3, blocking backdating) — which
 * means a client with a badly skewed clock cannot write an away period at all.
 * That is accepted, and §11 already detects and surfaces skew.
 */
export function awayDoc({
  from = dayKey(0),
  through = dayKey(7),
  setBy = ANA,
  setByName = 'Ana',
  setAt = serverTimestamp(),
  updatedAt = serverTimestamp(),
} = {}) {
  return { from, through, setBy, setByName, setAt, updatedAt };
}
