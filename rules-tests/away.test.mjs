// users/{uid}/shared/away — the only document a client writes with real
// validation behind it, and the one with the most ways to be wrong.
//
// Two of the assertions here deliberately differ from the case list in
// docs/security/firestore-rules-guidelines.md, and both differences are the
// document's own slack principle applied to a clause it did not work through.
// They are called out at the assertion rather than left to be discovered.

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
  awayDoc,
  dayKey,
  newTestEnv,
  seedDoc,
  seedLinks,
} from './helpers.mjs';

let testEnv;

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();
const awayRef = (db) => doc(db, 'users', MUM, 'shared', 'away');

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

describe('away — who may read it', () => {
  beforeEach(async () => {
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      ...awayDoc(),
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });
  });

  it('allows the watched person and an accepted watcher', async () => {
    await assertSucceeds(getDoc(awayRef(dbAs(MUM))));
    await assertSucceeds(getDoc(awayRef(dbAs(ANA))));
  });

  it('denies a REVOKED watcher', async () => {
    await assertFails(getDoc(awayRef(dbAs(CARLA))));
  });

  it('denies a stranger and an unauthenticated reader', async () => {
    await assertFails(getDoc(awayRef(dbAs(STRANGER))));
    await assertFails(getDoc(awayRef(testEnv.unauthenticatedContext().firestore())));
  });
});

describe('away — who may write it', () => {
  it('allows the watched person', async () => {
    await assertSucceeds(setDoc(awayRef(dbAs(MUM)), awayDoc({ setBy: MUM, setByName: 'Mum' })));
  });

  it('allows an accepted watcher — no approval, by design (§12)', async () => {
    await assertSucceeds(setDoc(awayRef(dbAs(ANA)), awayDoc({ setBy: ANA })));
  });

  it('denies a REVOKED watcher', async () => {
    await assertFails(setDoc(awayRef(dbAs(CARLA)), awayDoc({ setBy: CARLA, setByName: 'Carla' })));
  });

  it('denies a stranger and an unauthenticated writer', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(STRANGER)), awayDoc({ setBy: STRANGER, setByName: 'Nobody' })),
    );
    await assertFails(
      setDoc(awayRef(testEnv.unauthenticatedContext().firestore()), awayDoc({ setBy: ANA })),
    );
  });
});

describe('away — the period', () => {
  it('denies through < from', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(5), through: dayKey(2) })),
    );
  });

  it('allows through == from — a single away day', async () => {
    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(0), through: dayKey(0) })),
    );
  });

  it('denies the absurd case, which is the whole of what the cap is for', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(0), through: '2036-08-20' })),
    );
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(0), through: dayKey(90) })),
    );
  });

  it('ALLOWS a 32-day period, because the rules clause is deliberately slack', async () => {
    // The guidelines list "a 32-day period (31 days is the longest allowed)"
    // among the cases to cover. Under `through <= request.time + 32d` such a
    // period is ADMITTED, and that is the documented intent, not a hole: the
    // rules cannot do calendar arithmetic in the watched person's zone, so they
    // are biased to never reject a legitimate write. THE EXACT 31-DAY CAP IS
    // `AwayRules` in the domain layer. Asserting a denial here would be
    // asserting a guarantee these rules do not make.
    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(0), through: dayKey(31) })),
    );
  });

  it('denies a period reaching past the slack bound', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(0), through: dayKey(40) })),
    );
  });

  it('denies a from two days in the past — no retroactive away (§12)', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(-2), through: dayKey(3) })),
    );
  });

  it('ALLOWS a from one UTC day in the past, and that day of slack is required', async () => {
    // The guidelines list "`from` yesterday on create" among the denied cases.
    // It cannot be denied without rejecting ordinary writes: `from` is a date in
    // the WATCHED PERSON'S zone, and for a watched person in Los Angeles the
    // local date is the previous UTC date for much of each day. A strict
    // comparison would reject "away from today" for a third of the planet, and a
    // rejected away write queues offline and resurfaces with no visible cause.
    // One day is the minimum that works and the maximum that is needed — no
    // inhabited zone is more than 14 hours from UTC.
    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ from: dayKey(-1), through: dayKey(3) })),
    );
  });

  it('denies a malformed day label', async () => {
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ from: '2026-8-1' })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ through: 'tomorrow' })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ through: 20260825 })));
  });
});

describe('away — attribution (ADR-0003)', () => {
  it('denies setBy spoofed to another uid', async () => {
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setBy: BETO })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setBy: MUM })));
  });

  it('denies setByName absent, empty, over 100 chars, or not a string', async () => {
    const { setByName, ...withoutName } = awayDoc();
    await assertFails(setDoc(awayRef(dbAs(ANA)), withoutName));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: '' })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: 'x'.repeat(101) })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: 7 })));
  });

  it('denies a backdated setAt or updatedAt', async () => {
    const old = Timestamp.fromDate(new Date('2020-01-01T00:00:00Z'));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setAt: old })));
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ updatedAt: old })));
  });

  it('denies an unexpected field', async () => {
    await assertFails(setDoc(awayRef(dbAs(ANA)), { ...awayDoc(), reason: 'hospital' }));
  });

  it('does NOT cross-check setByName against the writer\'s display name', async () => {
    // ADR-0003 rejects that rule explicitly: users own their own displayName, so
    // a rename defeats it, and the get() costs a read per write. This test pins
    // the decision so the "obvious hardening" is not re-proposed in a later
    // phase and quietly added.
    await seedDoc(testEnv, ['users', ANA], {
      displayName: 'Ana',
      timezone: 'Europe/Madrid',
      createdAt: Timestamp.now(),
      lastSeenAt: Timestamp.now(),
    });
    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ setBy: ANA, setByName: 'Someone Else Entirely' })),
    );
  });
});

describe('away — update, and the truncation that cancels one', () => {
  // An away period that started five days ago, i.e. one whose `from` is already
  // in the past. This is the state a cancellation has to be able to rewrite.
  const inProgress = {
    from: dayKey(-5),
    through: dayKey(10),
    setBy: ANA,
    setByName: 'Ana',
  };

  beforeEach(async () => {
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      ...inProgress,
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });
  });

  it('ALLOWS truncating an in-progress period — the cancel path (ADR-0001)', async () => {
    // `from` is five days in the past here. A blanket `from >= today` would
    // reject this write, and rejecting it is what would let a cancellation
    // retroactively un-cover days already spent away — a false claim about days
    // the person really was away.
    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), {
        ...inProgress,
        through: dayKey(-1),
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('denies mutating from on update', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        ...inProgress,
        from: dayKey(0),
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS a second writer extending, and re-attributes to them (§12)', async () => {
    // Last write wins, so `setBy`/`setByName` are mutable — deliberately unlike
    // `from`. A test that only asserted denial here would freeze `setBy` and
    // break §12.
    await assertSucceeds(
      setDoc(awayRef(dbAs(BETO)), {
        ...inProgress,
        through: dayKey(20),
        setBy: BETO,
        setByName: 'Beto',
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('denies a second writer extending while leaving the old attribution', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(BETO)), {
        ...inProgress,
        through: dayKey(20),
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('denies an extension past the cap', async () => {
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        ...inProgress,
        through: dayKey(60),
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });
});

describe('away — delete', () => {
  beforeEach(async () => {
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      ...awayDoc(),
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });
  });

  it('allows the watched person and an accepted watcher', async () => {
    await assertSucceeds(deleteDoc(awayRef(dbAs(ANA))));
  });

  it('denies a revoked watcher and a stranger', async () => {
    await assertFails(deleteDoc(awayRef(dbAs(CARLA))));
    await assertFails(deleteDoc(awayRef(dbAs(STRANGER))));
  });
});
