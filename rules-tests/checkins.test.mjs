// checkins/{uid}/days/{date} — the read grant that makes the whole pull-based
// design possible, and the write grant that has to stay narrow.
//
// The read costs a get() per evaluation and that is ACCEPTED COST: without it
// the watcher could not pull the truth from Firestore at alarm time and would
// have to trust FCM for correctness, which §3 refuses.

import { after, before, beforeEach, describe, it } from 'node:test';

import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  Timestamp,
} from 'firebase/firestore';

import {
  ANA,
  BETO,
  CARLA,
  MUM,
  STRANGER,
  dayKey,
  newTestEnv,
  seedDoc,
  seedLinks,
} from './helpers.mjs';

let testEnv;

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();
const dayRef = (db, day = dayKey(0)) => doc(db, 'checkins', MUM, 'days', day);

const checkIn = (overrides = {}) => ({
  deviceTappedAt: Timestamp.fromDate(new Date()),
  receivedAt: serverTimestamp(),
  timezone: 'Europe/Madrid',
  ...overrides,
});

before(async () => {
  testEnv = await newTestEnv();
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedLinks(testEnv);
});

describe('check-ins — read', () => {
  beforeEach(async () => {
    await seedDoc(testEnv, ['checkins', MUM, 'days', dayKey(0)], {
      deviceTappedAt: Timestamp.now(),
      receivedAt: Timestamp.now(),
      timezone: 'Europe/Madrid',
    });
  });

  it('allows the watched person and every accepted watcher', async () => {
    await assertSucceeds(getDoc(dayRef(dbAs(MUM))));
    await assertSucceeds(getDoc(dayRef(dbAs(ANA))));
    await assertSucceeds(getDoc(dayRef(dbAs(BETO))));
  });

  it('denies a REVOKED watcher — the read that becomes ADR-0004 refused', async () => {
    // This denial is what the watcher's alarm isolate sees the moment a link is
    // revoked, and ADR-0004 exists because the app used to report it as "your
    // phone has been offline". It is a rules denial by design; the client maps
    // permission-denied to refused and withdraws standing warnings rather than
    // accusing the phone of being offline.
    await assertFails(getDoc(dayRef(dbAs(CARLA))));
  });

  it('denies a stranger and an unauthenticated reader', async () => {
    await assertFails(getDoc(dayRef(dbAs(STRANGER))));
    await assertFails(getDoc(dayRef(testEnv.unauthenticatedContext().firestore())));
  });

  it('denies reading a day that does not exist, to a watcher with no link', async () => {
    await assertFails(getDoc(dayRef(dbAs(STRANGER), dayKey(-3))));
  });
});

describe('check-ins — write', () => {
  it('lets the watched person write today', async () => {
    await assertSucceeds(setDoc(dayRef(dbAs(MUM)), checkIn()));
  });

  it('lets the watched person write a PAST day — an offline tap syncing late', async () => {
    // §11: a tap at 23:50 with no signal syncs the next morning and must still
    // be filed under the day it happened. Bounding the past would break the one
    // case the device-side day id exists for.
    await assertSucceeds(setDoc(dayRef(dbAs(MUM), dayKey(-4)), checkIn()));
  });

  it('lets a second tap the same day update the document', async () => {
    // The document id IS the day, so a second tap is an update — which does not
    // fire onDocumentCreated, so there is no duplicate push and no dedupe logic
    // anywhere (§7).
    await assertSucceeds(setDoc(dayRef(dbAs(MUM)), checkIn()));
    await assertSucceeds(setDoc(dayRef(dbAs(MUM)), checkIn()));
  });

  it('denies a watcher writing, accepted or not', async () => {
    await assertFails(setDoc(dayRef(dbAs(ANA)), checkIn()));
    await assertFails(setDoc(dayRef(dbAs(CARLA)), checkIn()));
    await assertFails(setDoc(dayRef(dbAs(STRANGER)), checkIn()));
  });

  it('denies a document id that is not a day label', async () => {
    await assertFails(setDoc(dayRef(dbAs(MUM), 'today'), checkIn()));
    await assertFails(setDoc(dayRef(dbAs(MUM), '2026-8-1'), checkIn()));
    await assertFails(setDoc(dayRef(dbAs(MUM), '20260820'), checkIn()));
  });

  it('denies an unexpected or missing field', async () => {
    await assertFails(setDoc(dayRef(dbAs(MUM)), checkIn({ mood: 'fine' })));
    await assertFails(
      setDoc(dayRef(dbAs(MUM)), {
        deviceTappedAt: Timestamp.fromDate(new Date()),
        receivedAt: serverTimestamp(),
      }),
    );
  });

  it('denies a client-supplied receivedAt', async () => {
    // receivedAt is the server's stamp and the only trusted one (§11).
    // deviceTappedAt is the client's and is DISPLAYED, never authorised on —
    // which is why the next test allows a wildly wrong one.
    await assertFails(
      setDoc(dayRef(dbAs(MUM)), checkIn({ receivedAt: Timestamp.fromDate(new Date()) })),
    );
  });

  it('allows a deviceTappedAt that disagrees with the server clock', async () => {
    // A tap at 23:50 that syncs at 08:00 must still be shown as 23:50 — that is
    // the whole of §11's correction to HANDOVER.md. Skew is detected and
    // surfaced, never used to reject a check-in.
    await assertSucceeds(
      setDoc(
        dayRef(dbAs(MUM)),
        checkIn({ deviceTappedAt: Timestamp.fromDate(new Date('2026-08-19T23:50:00Z')) }),
      ),
    );
  });

  it('denies a wrong type on any field', async () => {
    await assertFails(setDoc(dayRef(dbAs(MUM)), checkIn({ deviceTappedAt: 'now' })));
    await assertFails(setDoc(dayRef(dbAs(MUM)), checkIn({ timezone: 42 })));
    await assertFails(setDoc(dayRef(dbAs(MUM)), checkIn({ timezone: '' })));
  });
});

describe('check-ins — delete', () => {
  beforeEach(async () => {
    await seedDoc(testEnv, ['checkins', MUM, 'days', dayKey(0)], {
      deviceTappedAt: Timestamp.now(),
      receivedAt: Timestamp.now(),
      timezone: 'Europe/Madrid',
    });
  });

  it('follows the matrix: write is self only, delete included', async () => {
    await assertFails(deleteDoc(dayRef(dbAs(ANA))));
    await assertSucceeds(deleteDoc(dayRef(dbAs(MUM))));
  });
});
