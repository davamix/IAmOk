// users/{uid} and users/{uid}/tokens/{token} — the "self only" rows of the
// access matrix.
//
// Self-only on `users/{uid}` is load-bearing rather than merely tidy: it is the
// reason §7 denormalises `watchedName`, `watcherName` and `watchedTimezone` onto
// the link. The test that matters most here is therefore a DENIAL — an accepted
// watcher still cannot read the watched person's user document.

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

import { ANA, MUM, STRANGER, newTestEnv, seedDoc, seedLinks } from './helpers.mjs';

let testEnv;

const user = (overrides = {}) => ({
  displayName: 'Mum',
  timezone: 'Europe/Madrid',
  createdAt: serverTimestamp(),
  lastSeenAt: serverTimestamp(),
  ...overrides,
});

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();

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

describe('users/{uid}', () => {
  it('lets a user create their own document', async () => {
    await assertSucceeds(setDoc(doc(dbAs(MUM), 'users', MUM), user()));
  });

  it('lets a user read their own document', async () => {
    await seedDoc(testEnv, ['users', MUM], user({ createdAt: Timestamp.now(), lastSeenAt: Timestamp.now() }));
    await assertSucceeds(getDoc(doc(dbAs(MUM), 'users', MUM)));
  });

  it('denies reading another user, even with an ACCEPTED link', async () => {
    await seedDoc(testEnv, ['users', MUM], user({ createdAt: Timestamp.now(), lastSeenAt: Timestamp.now() }));
    await assertFails(getDoc(doc(dbAs(ANA), 'users', MUM)));
  });

  it('denies writing another user', async () => {
    await assertFails(setDoc(doc(dbAs(ANA), 'users', MUM), user()));
    await assertFails(setDoc(doc(dbAs(STRANGER), 'users', MUM), user()));
  });

  it('denies an unauthenticated read or write', async () => {
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, 'users', MUM)));
    await assertFails(setDoc(doc(db, 'users', MUM), user()));
  });

  it('denies an unexpected field', async () => {
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM), user({ role: 'admin' })),
    );
  });

  it('denies a missing field', async () => {
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM), {
        displayName: 'Mum',
        timezone: 'Europe/Madrid',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('denies a displayName that is empty, over 100 chars, or not a string', async () => {
    await assertFails(setDoc(doc(dbAs(MUM), 'users', MUM), user({ displayName: '' })));
    await assertFails(setDoc(doc(dbAs(MUM), 'users', MUM), user({ displayName: 'x'.repeat(101) })));
    await assertFails(setDoc(doc(dbAs(MUM), 'users', MUM), user({ displayName: 42 })));
  });

  it('denies a backdated lastSeenAt', async () => {
    await assertFails(
      setDoc(
        doc(dbAs(MUM), 'users', MUM),
        user({ lastSeenAt: Timestamp.fromDate(new Date('2020-01-01T00:00:00Z')) }),
      ),
    );
  });

  it('denies rewriting createdAt on update', async () => {
    await assertSucceeds(setDoc(doc(dbAs(MUM), 'users', MUM), user()));
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM), user({ createdAt: serverTimestamp() })),
    );
  });

  it('allows an update that keeps createdAt and refreshes lastSeenAt', async () => {
    const createdAt = Timestamp.fromDate(new Date('2026-08-01T09:00:00Z'));
    await seedDoc(testEnv, ['users', MUM], user({ createdAt, lastSeenAt: createdAt }));
    await assertSucceeds(
      setDoc(doc(dbAs(MUM), 'users', MUM), user({ createdAt, displayName: 'Mum R.' })),
    );
  });

  it('lets a user delete their own document, and nobody else', async () => {
    await seedDoc(testEnv, ['users', MUM], user({ createdAt: Timestamp.now(), lastSeenAt: Timestamp.now() }));
    await assertFails(deleteDoc(doc(dbAs(ANA), 'users', MUM)));
    await assertSucceeds(deleteDoc(doc(dbAs(MUM), 'users', MUM)));
  });
});

describe('users/{uid}/tokens/{token}', () => {
  const TOKEN = 'fcm:token-abc123';
  const token = (overrides = {}) => ({
    platform: 'android',
    updatedAt: serverTimestamp(),
    ...overrides,
  });

  it('lets a user write and read their own token', async () => {
    await assertSucceeds(setDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN), token()));
    await assertSucceeds(getDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN)));
  });

  it("denies a watcher writing or reading the watched person's tokens", async () => {
    await assertFails(setDoc(doc(dbAs(ANA), 'users', MUM, 'tokens', TOKEN), token()));
    await assertFails(getDoc(doc(dbAs(ANA), 'users', MUM, 'tokens', TOKEN)));
  });

  it('denies an unexpected field, a wrong platform, or a backdated updatedAt', async () => {
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN), token({ uid: MUM })),
    );
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN), token({ platform: 'ios' })),
    );
    await assertFails(
      setDoc(
        doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN),
        token({ updatedAt: Timestamp.fromDate(new Date('2020-01-01T00:00:00Z')) }),
      ),
    );
  });

  it('lets a user delete their own token', async () => {
    await assertSucceeds(setDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN), token()));
    await assertFails(deleteDoc(doc(dbAs(ANA), 'users', MUM, 'tokens', TOKEN)));
    await assertSucceeds(deleteDoc(doc(dbAs(MUM), 'users', MUM, 'tokens', TOKEN)));
  });
});

describe('users/{uid}/<anything else>', () => {
  it('is denied — the catch-all, not an accident of no match block', async () => {
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM, 'notes', 'n1'), { text: 'hello' }),
    );
    await assertFails(getDoc(doc(dbAs(MUM), 'users', MUM, 'notes', 'n1')));
    // `shared` holds exactly one document, `away`. Anything else under it is denied.
    await assertFails(
      setDoc(doc(dbAs(MUM), 'users', MUM, 'shared', 'other'), { text: 'hello' }),
    );
  });
});
