// links/{id} — Function-written, with exactly one client exception.
//
// The exception is narrow on purpose: either party may set `status: "revoked"`
// and nothing else. Everything denormalised onto a link — `watchedName`,
// `watcherName`, `watchedTimezone`, `activeFrom`, `warningLocalTime` — is what
// the other side renders and decides with, so a client that could rewrite them
// could move the day boundary a warning is computed against.

import { after, before, beforeEach, describe, it } from 'node:test';

import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { deleteDoc, doc, getDoc, updateDoc, setDoc, Timestamp } from 'firebase/firestore';

import {
  ANA,
  CARLA,
  MUM,
  STRANGER,
  linkId,
  newTestEnv,
  seedLinks,
} from './helpers.mjs';

let testEnv;

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();
const anaLink = (db) => doc(db, 'links', linkId(MUM, ANA));

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

describe('links — read', () => {
  it('allows either party', async () => {
    await assertSucceeds(getDoc(anaLink(dbAs(MUM))));
    await assertSucceeds(getDoc(anaLink(dbAs(ANA))));
  });

  it('allows a party whose link is REVOKED to read it', async () => {
    // Deliberate: the watcher list has a revoked row — "Your link with Mum has
    // ended." — that exists precisely to explain a notification posted before
    // revocation. A read denial here would make that row unrenderable.
    await assertSucceeds(getDoc(doc(dbAs(CARLA), 'links', linkId(MUM, CARLA))));
  });

  it('denies a third party and an unauthenticated reader', async () => {
    await assertFails(getDoc(anaLink(dbAs(STRANGER))));
    await assertFails(getDoc(anaLink(dbAs(CARLA))));
    await assertFails(getDoc(anaLink(testEnv.unauthenticatedContext().firestore())));
  });
});

describe('links — the revocation exception', () => {
  it('lets either party set status: revoked', async () => {
    await assertSucceeds(updateDoc(anaLink(dbAs(ANA)), { status: 'revoked' }));
    await testEnv.clearFirestore();
    await seedLinks(testEnv);
    await assertSucceeds(updateDoc(anaLink(dbAs(MUM)), { status: 'revoked' }));
  });

  it('denies setting status to anything else', async () => {
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { status: 'accepted' }));
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { status: 'deleted' }));
  });

  it('denies revoking AND changing another field in the same write', async () => {
    await assertFails(
      updateDoc(anaLink(dbAs(ANA)), { status: 'revoked', watchedName: 'Someone' }),
    );
  });

  it('denies changing any other field on its own', async () => {
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { watchedTimezone: 'Pacific/Auckland' }));
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { activeFrom: '2020-01-01' }));
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { warningLocalTime: '03:00' }));
    await assertFails(updateDoc(anaLink(dbAs(ANA)), { watcherName: 'Not Ana' }));
  });

  it('denies a third party revoking', async () => {
    await assertFails(updateDoc(anaLink(dbAs(STRANGER)), { status: 'revoked' }));
    await assertFails(updateDoc(anaLink(dbAs(CARLA)), { status: 'revoked' }));
  });
});

describe('links — create and delete are Function-only', () => {
  it('denies a client creating a link, including one naming itself', async () => {
    const forged = {
      watchedUid: MUM,
      watcherUid: STRANGER,
      status: 'accepted',
      watchedName: 'Mum',
      watcherName: 'Nobody',
      watchedTimezone: 'Europe/Madrid',
      activeFrom: '2026-08-01',
      warningLocalTime: '10:00',
      createdAt: Timestamp.now(),
    };
    await assertFails(
      setDoc(doc(dbAs(STRANGER), 'links', linkId(MUM, STRANGER)), forged),
    );
    // And the watched person cannot mint one either — redeemInvite is the only
    // path, because it is the only place single-use and expiry are enforceable.
    await assertFails(setDoc(doc(dbAs(MUM), 'links', linkId(MUM, STRANGER)), forged));
  });

  it('denies deleting a link', async () => {
    await assertFails(deleteDoc(anaLink(dbAs(ANA))));
    await assertFails(deleteDoc(anaLink(dbAs(MUM))));
  });
});
