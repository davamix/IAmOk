// invites/{code} — unreadable by every client, including the invite's creator.
//
// Not "readable only by the creator": a readable invite collection is an
// enumerable list of live codes, and the alphabet is six unambiguous characters.
// Redemption happens exclusively inside the `redeemInvite` callable, which also
// means the client never learns another user's uid from an invite document.

import { after, before, beforeEach, describe, it } from 'node:test';

import { assertFails } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, setDoc, Timestamp } from 'firebase/firestore';

import { ANA, MUM, STRANGER, newTestEnv, seedDoc, seedLinks } from './helpers.mjs';

let testEnv;

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();
const CODE = 'K7RTQX';

before(async () => {
  testEnv = await newTestEnv();
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedLinks(testEnv);
  await seedDoc(testEnv, ['invites', CODE], {
    watchedUid: MUM,
    createdAt: Timestamp.now(),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 86400000)),
  });
});

describe('invites', () => {
  it('denies a read to the creator', async () => {
    await assertFails(getDoc(doc(dbAs(MUM), 'invites', CODE)));
  });

  it('denies a read to anyone else, signed in or not', async () => {
    await assertFails(getDoc(doc(dbAs(ANA), 'invites', CODE)));
    await assertFails(getDoc(doc(dbAs(STRANGER), 'invites', CODE)));
    await assertFails(getDoc(doc(testEnv.unauthenticatedContext().firestore(), 'invites', CODE)));
  });

  it('denies listing the collection — the enumeration this rule exists for', async () => {
    await assertFails(getDocs(collection(dbAs(MUM), 'invites')));
    await assertFails(getDocs(collection(dbAs(STRANGER), 'invites')));
  });

  it('denies every client write', async () => {
    await assertFails(
      setDoc(doc(dbAs(MUM), 'invites', 'NEWONE'), {
        watchedUid: MUM,
        createdAt: Timestamp.now(),
        expiresAt: Timestamp.now(),
      }),
    );
    await assertFails(setDoc(doc(dbAs(STRANGER), 'invites', CODE), { consumedBy: STRANGER }));
    await assertFails(deleteDoc(doc(dbAs(MUM), 'invites', CODE)));
  });
});

describe('the catch-all', () => {
  it('denies a collection nothing in the matrix mentions', async () => {
    await assertFails(getDoc(doc(dbAs(MUM), 'admin', 'settings')));
    await assertFails(setDoc(doc(dbAs(MUM), 'admin', 'settings'), { enabled: true }));
    await assertFails(getDocs(collection(dbAs(MUM), 'users')));
    await assertFails(getDocs(collection(dbAs(MUM), 'links')));
  });
});
