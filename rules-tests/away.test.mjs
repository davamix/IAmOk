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

  it('denies a WHITESPACE-ONLY setByName', async () => {
    // `size() >= 1` alone admitted "   ", which trims to nothing on the client
    // and renders as the unattributed string on every surface. That is ADR-0003
    // rule 2's whole point defeated by three spaces: no client may silently
    // turn off §17's control by writing a name that names nobody. Omitting the
    // field was already denied; this is the same thing wearing a character.
    await assertFails(setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: '   ' })));
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: '\t\n ' })),
    );
  });

  it('ALLOWS a name with surrounding whitespace, trimmed to something real', async () => {
    // The denial above must not become a denial of ordinary names — the bound
    // is on what is left after trimming, not on the raw string.
    await assertSucceeds(setDoc(awayRef(dbAs(ANA)), awayDoc({ setByName: '  Ana  ' })));
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

  it('denies mutating from while the period is IN PROGRESS', async () => {
    // ADR-0001 decision 6, and the reason is scoped: truncating an in-progress
    // period rewrites a document whose `from` is already past, so `from` must
    // not move underneath it. `inProgress` runs to +10, so it is in force.
    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        ...inProgress,
        from: dayKey(0),
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS a new from once the stored period has ENDED — away is settable ' +
      'more than once in a lifetime', async () => {
    // The defect this pair exists for. Nothing deletes the document when a
    // period runs its course, so a flat `from == resource.data.from` meant away
    // could be set ONCE per person and then never again — every later attempt
    // refused, on both sides, for ever, while §12 says "to go longer, set it
    // again". `from` is frozen for the life of a PERIOD, not of a person.
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      from: dayKey(-20),
      through: dayKey(-10),
      setBy: ANA,
      setByName: 'Ana',
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });

    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), {
        from: dayKey(0),
        through: dayKey(5),
        setBy: ANA,
        setByName: 'Ana',
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('a period whose last day is TODAY is still in force — no new from',
      async () => {
    // **The boundary the whole clause turns on, and nothing exercised it.**
    // `awayPeriodEnded()` is `dayStart(through) < todayStartUtc()`; the cases
    // around it seed `through` at -10 and +10, which sit either side of BOTH
    // `<` and `<=`. So the classic off-by-one — relaxing this to `<=` — was
    // caught by no test in the suite, and it is the one that un-covers a day
    // the person is still away for: a new `from` lands while the stored period
    // still has today to run, and every watcher whose device has not yet
    // settled that day re-decides it and warns about somebody who is genuinely
    // away. That is the false claim to a family ADR-0001 exists to prevent.
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      from: dayKey(-5),
      through: dayKey(0),
      setBy: ANA,
      setByName: 'Ana',
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });

    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        from: dayKey(0),
        through: dayKey(5),
        setBy: ANA,
        setByName: 'Ana',
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('and one that ended YESTERDAY is not — the very next day works',
      async () => {
    // The other side of the same boundary, one day out. Without this the fix
    // for the case above could be to freeze `from` again for anything recent,
    // which would bring back the set-once defect in a narrower form: a family
    // home from a holiday could not mark her away the following morning.
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      from: dayKey(-5),
      through: dayKey(-1),
      setBy: ANA,
      setByName: 'Ana',
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });

    await assertSucceeds(
      setDoc(awayRef(dbAs(ANA)), {
        from: dayKey(0),
        through: dayKey(5),
        setBy: ANA,
        setByName: 'Ana',
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('a new period after an ended one is still not RETROACTIVE', async () => {
    // The freeze is what used to stop a `from` in the past; lifting it for an
    // ended period must not lift §12's no-retroactive rule with it, or the days
    // between the two periods could be silently un-covered.
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      from: dayKey(-20),
      through: dayKey(-10),
      setBy: ANA,
      setByName: 'Ana',
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });

    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        from: dayKey(-5),
        through: dayKey(5),
        setBy: ANA,
        setByName: 'Ana',
        setAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('a new period after an ended one is still capped', async () => {
    await seedDoc(testEnv, ['users', MUM, 'shared', 'away'], {
      from: dayKey(-20),
      through: dayKey(-10),
      setBy: ANA,
      setByName: 'Ana',
      setAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });

    await assertFails(
      setDoc(awayRef(dbAs(ANA)), {
        from: dayKey(0),
        through: dayKey(90),
        setBy: ANA,
        setByName: 'Ana',
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
