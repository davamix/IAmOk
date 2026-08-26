import { randomBytes as nodeRandomBytes } from 'node:crypto';

import type { Firestore, Timestamp } from 'firebase-admin/firestore';
import { Timestamp as AdminTimestamp } from 'firebase-admin/firestore';

/**
 * Pairing — `createInvite` and `redeemInvite` (ARCHITECTURE.md §9), with the
 * database handed in.
 *
 * ## Why creation is a Function at all
 *
 * §9 listed only `redeemInvite`, and §6 gave `InviteService` a "create invite"
 * the client cannot perform: §8 says `invites/{code}` is **Function-written**,
 * and `firestore.rules` enforces it with `allow read, write: if false` in both
 * directions. So the two documents disagreed, and this file resolves it the way
 * §8 already decided — see ADR-0011.
 *
 * The alternative, granting the client a `create`, reopens the enumeration the
 * deny exists to close: a `create` that fails because the document already
 * exists tells the caller that code is live, which turns the write path into the
 * read path §8 refused.
 *
 * ## Everything here re-validates its own inputs
 *
 * Functions run with admin credentials and **bypass the rules entirely**, so
 * nothing below may lean on them. `redeemInvite` exists precisely because the
 * client cannot be trusted to enforce single-use or expiry, and must never learn
 * another user's uid out of an invite — which is why the redeem result carries a
 * display name and a link id and no uid the caller did not already have.
 *
 * ## Separable from the callables, for the reason `check_in_fan_out.ts` is
 *
 * The two exported operations take a `Firestore` and a `now`, so
 * `functions/test/invites.test.js` runs them against the **real emulated
 * Firestore** — the transaction, the collision retry and the deterministic link
 * id are exercised as they will run in production. `docs/testing/strategy.md`:
 * if a test needs a deploy to answer a question about logic, the logic is in the
 * wrong layer.
 */

/**
 * The 32 characters a code may contain — §7's unambiguous alphabet.
 *
 * A–Z without `I` or `O`; 2–9 without `0` or `1`. **This string is duplicated in
 * `lib/domain/entities/invite_code.dart`** and the duplication is deliberate:
 * two languages, and the client copy is only ever a typo check. They are pinned
 * against each other character for character by `functions/test/invites.test.js`,
 * which reads the Dart file, so the two cannot drift silently.
 *
 * 32 divides 256, which is why [generateCode] can take a byte modulo 32 with no
 * bias and no rejection loop.
 */
export const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export const INVITE_CODE_LENGTH = 6;

/**
 * How long a code stays redeemable — **24 hours**, the owner's decision.
 *
 * The pairing flow assumes a family member sets up both phones in one sitting
 * (`ui-ux/screens.md`), and this is the window that assumption implies. It is
 * not what bounds guessing — single-use redemption behind a callable that never
 * reveals a uid is — but it is what bounds how long a code read aloud over the
 * phone, or left in a message, stays worth anything.
 */
export const INVITE_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * How many distinct codes to try before giving up on a collision.
 *
 * At 32^6 ≈ 1.07 billion codes and a family-scale collection, a single collision
 * is already improbable; three in a row is not a state worth designing for, and
 * looping for ever inside a callable is.
 */
const MAX_CODE_ATTEMPTS = 5;

/** What `createInvite` gives back to the phone that asked. */
export interface CreatedInvite {
  readonly code: string;
  /** ISO-8601. The screen renders it as a local time the reader recognises. */
  readonly expiresAt: string;
  /** True when a live code already existed and this call reused it. */
  readonly reused: boolean;
}

/**
 * Every way a redemption can end.
 *
 * **The failures are distinguished rather than collapsed**, and that is a
 * deliberate trade. Collapsing them leaks marginally less — a guesser would not
 * learn that a code once existed — but the three tell a *family* three different
 * next actions: check what you typed, ask for a fresh code, and "that one has
 * already been used". At 32^6 with a 24-hour life, the information a guesser
 * gains is worth less than the family that cannot tell a typo from an expiry.
 */
export type RedeemOutcome =
  | {
      readonly status: 'linked';
      readonly linkId: string;
      /** Denormalised from `users/{watchedUid}` — never a uid (§8). */
      readonly watchedName: string;
      readonly activeFrom: string;
      /** True when this exact pairing already existed — see below. */
      readonly alreadyLinked: boolean;
    }
  | { readonly status: 'unknown-code' }
  | { readonly status: 'expired' }
  | { readonly status: 'consumed' }
  | { readonly status: 'self' }
  | { readonly status: 'watched-profile-missing' }
  | { readonly status: 'watcher-profile-missing' }
  | { readonly status: 'unusable-timezone' };

/** A `users/{uid}` document, as much of it as pairing needs. */
interface Profile {
  readonly displayName: string;
  readonly timezone: string;
}

/**
 * Six characters from [INVITE_ALPHABET], from a cryptographic source.
 *
 * `randomBytes` rather than `Math.random`: a predictable code is a code somebody
 * else can redeem, and the whole consent record in this design is *the watched
 * person's device generated this and they shared it* (§2).
 *
 * No modulo bias, because 256 is an exact multiple of 32 — asserted in the
 * tests rather than left as a comment, since the property breaks silently the
 * moment the alphabet changes length.
 */
export function generateCode(
  randomBytes: (size: number) => Buffer = nodeRandomBytes,
): string {
  const bytes = randomBytes(INVITE_CODE_LENGTH);
  let code = '';
  for (let i = 0; i < INVITE_CODE_LENGTH; i++) {
    // `noUncheckedIndexedAccess` is on, so both indexes are narrowed rather
    // than asserted.
    const byte = bytes[i] ?? 0;
    code += INVITE_ALPHABET[byte % INVITE_ALPHABET.length] ?? INVITE_ALPHABET[0];
  }
  return code;
}

/**
 * `YYYY-MM-DD` for [instant] **in [timeZone]**, or null if the zone is not one
 * this runtime knows.
 *
 * This is where `activeFrom` comes from, and §7 is exact about whose zone it is:
 * *today in the **watched person's** timezone, not the redeemer's*. A watcher
 * redeeming from another continent must not shift which days are eligible for a
 * warning — get this wrong westward and the link is active for a day that has
 * not happened where the watched person lives, which is a warning about a day
 * before the link existed, which §17 lists as its own risk.
 *
 * Assembled from `formatToParts` rather than by trusting a locale's date order:
 * `en-CA` happens to render ISO order today, and a locale-data change would
 * silently produce `26-08-2026` — a string that still matches nothing and would
 * be written to a field the whole warning path reads.
 */
export function dayKeyInZone(instant: Date, timeZone: string): string | null {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).formatToParts(instant);
  } catch {
    // RangeError for a zone ICU does not recognise. Not a throw, because the
    // caller turns it into a refusal a human can act on rather than a 500.
    return null;
  }
  const find = (type: string) => parts.find((p) => p.type === type)?.value;
  const year = find('year');
  const month = find('month');
  const day = find('day');
  if (year === undefined || month === undefined || day === undefined) {
    return null;
  }
  return `${year}-${month}-${day}`;
}

function readProfile(data: FirebaseFirestore.DocumentData | undefined): Profile | null {
  if (data === undefined) return null;
  const displayName = data['displayName'];
  const timezone = data['timezone'];
  if (typeof displayName !== 'string' || displayName.length === 0) return null;
  if (typeof timezone !== 'string' || timezone.length === 0) return null;
  return { displayName, timezone };
}

/**
 * Mints a code for [watchedUid], or hands back the live one it already has.
 *
 * ## Reuse is not an optimisation
 *
 * A second call must not invalidate the code somebody has already written down
 * or read aloud. The pairing screen can be re-entered — backed out of, resumed
 * after a phone call, reached again from the Tap screen — and a fresh code each
 * time would kill the one the family is in the middle of using, with nothing on
 * either phone able to explain why it stopped working.
 *
 * ## And it is what bounds the collection
 *
 * There is no scheduled cleanup in this design and §9 is deliberate about not
 * adding one. So this call sweeps **this caller's own expired, unconsumed**
 * invites while it is here. Consumed ones are kept: they are what lets a retried
 * redemption recognise itself instead of reporting a failure for a pairing that
 * succeeded, and there is exactly one per link.
 *
 * The query is `watchedUid ==` alone — an automatic single-field index, no
 * composite — and the expiry filter is applied in memory. The set is one
 * person's own invites, so it is small by construction.
 */
export async function createInviteFor(
  db: Firestore,
  watchedUid: string,
  now: Date,
  randomBytes?: (size: number) => Buffer,
): Promise<CreatedInvite | { readonly status: 'watched-profile-missing' }> {
  // **Checked at creation, where a human is watching**, not left to surface
  // inside `redeemInvite` on somebody else's phone a minute later. The redeem
  // path re-reads it anyway — a profile can be deleted in between — but a
  // failure here is one the person who caused it can actually act on.
  const profile = readProfile((await db.doc(`users/${watchedUid}`).get()).data());
  if (profile === null) return { status: 'watched-profile-missing' };

  const invites = db.collection('invites');
  const mine = await invites.where('watchedUid', '==', watchedUid).get();

  const nowMs = now.getTime();
  let live: { code: string; expiresAt: Timestamp } | null = null;
  const stale: string[] = [];

  for (const doc of mine.docs) {
    const data = doc.data();
    const expiresAt = data['expiresAt'];
    const consumed = data['consumedBy'] !== undefined && data['consumedBy'] !== null;
    if (!isTimestamp(expiresAt)) continue;
    const expired = expiresAt.toMillis() <= nowMs;
    if (consumed) continue;
    if (expired) {
      stale.push(doc.id);
      continue;
    }
    // The one that dies last, so re-entering the screen never shortens the
    // window a family is already working inside.
    if (live === null || expiresAt.toMillis() > live.expiresAt.toMillis()) {
      live = { code: doc.id, expiresAt };
    }
  }

  // **Awaited, because on Cloud Run an unawaited promise may simply never
  // run.** This was `void … .catch()`, on the reasoning that a sweep which fails
  // must not fail the pairing it was incidental to. That property is preserved
  // by the per-document `.catch` below; what the `void` actually bought was a
  // sweep that works **only in the emulator**. 2nd-gen functions are throttled
  // the moment the response is written, so work started and not awaited is
  // dropped — and the local Node process, where nothing throttles, is exactly
  // where `invites.test.js` proves it works. A test that can only pass.
  //
  // It matters because this is the design's **only** garbage collection: §9 has
  // no scheduled function deliberately, so if this silently no-ops, expired
  // invites accumulate for ever and the `watchedUid ==` read above — which is
  // on the pairing path — grows without bound.
  //
  // `allSettled`, so one failed delete cannot reject the batch, and the set is
  // one person's own invites so the added latency is bounded by construction.
  await Promise.allSettled(
    stale.map((id) => invites.doc(id).delete().catch(() => undefined)),
  );

  if (live !== null) {
    return {
      code: live.code,
      expiresAt: live.expiresAt.toDate().toISOString(),
      reused: true,
    };
  }

  const expiresAt = AdminTimestamp.fromMillis(nowMs + INVITE_TTL_MS);
  for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt++) {
    const code = generateCode(randomBytes);
    try {
      // `create`, never `set`: it fails if the document exists, which is the
      // collision check itself rather than a read-then-write with a race in it.
      await invites.doc(code).create({
        watchedUid,
        createdAt: AdminTimestamp.fromMillis(nowMs),
        expiresAt,
      });
      return { code, expiresAt: expiresAt.toDate().toISOString(), reused: false };
    } catch (error) {
      // **Only a collision is retried.** This caught everything, so a transient
      // `DEADLINE_EXCEEDED` on a write that had in fact landed would mint a
      // *second* live code for the same person — doubling their guessing surface
      // and leaving an orphan nothing sweeps until it expires. Firestore's
      // `ALREADY_EXISTS` is gRPC code 6, which is the one case this loop exists
      // for; anything else is rethrown immediately.
      const code = (error as { code?: unknown }).code;
      if (code !== 6 || attempt === MAX_CODE_ATTEMPTS - 1) throw error;
    }
  }
  // Unreachable: the loop either returns or rethrows on its last attempt.
  throw new Error('createInvite: exhausted code attempts');
}

/**
 * Turns a code into `links/{watchedUid}_{watcherUid}`, atomically.
 *
 * ## The order of the checks is the design
 *
 * **A repeat redemption by the same watcher is a success, not a "consumed"
 * error**, and it is checked before expiry. §7 makes pairing idempotent by
 * construction — the link id is deterministic, so redeeming twice writes the
 * same document — and the case that reaches this branch is a client that
 * retried after a dropped response. Reporting a failure there would tell a
 * family the pairing did not work about a pairing that did, on the one screen
 * whose whole job is to say whether it worked.
 *
 * ## What is denormalised, and why the watcher never learns a uid
 *
 * §7: `watchedName`, `watchedTimezone` **and `watcherName`** go onto the link,
 * in both directions, so neither party ever reads the other's `users/{uid}` —
 * §8 grants that document to self only. `watcherName` is what ADR-0005's Tap
 * screen names. Both are **display labels and not identities** (ADR-0003):
 * either user can rename themselves afterwards and nothing decides anything from
 * them.
 *
 * ## Re-pairing after a revocation resets `activeFrom`, deliberately
 *
 * The link id is the same document, so a watcher who was revoked and is invited
 * back writes over the old row. `activeFrom` becomes **today**, which is what
 * stops the restored link warning about the days nobody was watching. The
 * watcher's own `warningLocalTime` and the original `createdAt` are preserved,
 * because neither is a claim about those days and resetting the hour would
 * silently move when a family is told.
 */
export async function redeemInviteFor(
  db: Firestore,
  code: string,
  watcherUid: string,
  now: Date,
): Promise<RedeemOutcome> {
  return db.runTransaction(async (txn) => {
    const inviteRef = db.doc(`invites/${code}`);
    const inviteSnap = await txn.get(inviteRef);
    if (!inviteSnap.exists) return { status: 'unknown-code' as const };

    const invite = inviteSnap.data() ?? {};
    const watchedUid = invite['watchedUid'];
    if (typeof watchedUid !== 'string' || watchedUid.length === 0) {
      // A malformed invite is not a code anybody can be told to re-check, and
      // it cannot be redeemed into a link with no watched party. Reported as
      // unknown rather than invented into something worse.
      return { status: 'unknown-code' as const };
    }

    const linkId = `${watchedUid}_${watcherUid}`;
    const linkRef = db.doc(`links/${linkId}`);
    const linkSnap = await txn.get(linkRef);

    const consumedBy = invite['consumedBy'];
    const alreadyMine =
      typeof consumedBy === 'string' && consumedBy === watcherUid;

    // Ahead of expiry on purpose — see the docstring. A completed pairing
    // reporting "that code has expired" would be false about the pairing.
    //
    // **`accepted`, not merely `exists`** — and the difference is a false claim
    // to a family. The invite is deliberately kept after it is consumed, and the
    // code stays in the message thread it was shared in. So a watcher who has
    // been **revoked** can re-type their old code: `alreadyMine` is true, the
    // link document still exists, and without this clause the callable answers
    // `linked`, the screen renders a green tick and *"You are now looking after
    // Mum."*, and nothing has been restored. Every read that watcher makes is
    // still refused by the rules, so the app would be claiming a relationship
    // the backend denies — silence dressed as success, which is the direction
    // this app must never fail in.
    //
    // Falling through is correct rather than convenient: two lines below,
    // `consumedBy` is set, so the answer becomes `consumed` — *"That code has
    // already been used. Ask for a new one."* — which is true, and names the
    // action that actually works. It must **not** fall further into the re-link
    // path, or a revoked watcher could restore themselves with a spent code.
    const linkAccepted = (linkSnap.data() ?? {})['status'] === 'accepted';
    if (alreadyMine && linkSnap.exists && linkAccepted) {
      const existing = linkSnap.data() ?? {};
      const activeFrom = existing['activeFrom'];
      const watchedName = existing['watchedName'];
      return {
        status: 'linked' as const,
        linkId,
        watchedName: typeof watchedName === 'string' ? watchedName : '',
        activeFrom: typeof activeFrom === 'string' ? activeFrom : '',
        alreadyLinked: true,
      };
    }

    if (typeof consumedBy === 'string' && consumedBy.length > 0) {
      return { status: 'consumed' as const };
    }

    const expiresAt = invite['expiresAt'];
    if (!isTimestamp(expiresAt) || expiresAt.toMillis() <= now.getTime()) {
      return { status: 'expired' as const };
    }

    // **A link to yourself is refused.** It would warn you about your own
    // missed day and make the Tap screen name you as your own watcher. The
    // device rig's deliberate self-link is seeded through the Admin SDK by
    // `tools/seed-link.ps1`, which bypasses this callable, so refusing here
    // costs it nothing.
    if (watcherUid === watchedUid) return { status: 'self' as const };

    const watchedProfile = readProfile(
      (await txn.get(db.doc(`users/${watchedUid}`))).data(),
    );
    if (watchedProfile === null) {
      return { status: 'watched-profile-missing' as const };
    }

    const watcherProfile = readProfile(
      (await txn.get(db.doc(`users/${watcherUid}`))).data(),
    );
    if (watcherProfile === null) {
      return { status: 'watcher-profile-missing' as const };
    }

    // **Refused rather than defaulted.** `watchedTimezone` is what lets the
    // watcher's alarm isolate compute `D` with no plugin access at all
    // (ADR-0002), and `Link.tryWatchedZone` calls a zone this build cannot
    // resolve "a permanently silent watcher, which is the one failure this app
    // cannot detect in itself". Writing `Etc/UTC` over it instead would create
    // exactly that link quietly, at the one moment a human is watching the
    // screen and could do something about it.
    const activeFrom = dayKeyInZone(now, watchedProfile.timezone);
    if (activeFrom === null) return { status: 'unusable-timezone' as const };

    const previous = linkSnap.data() ?? {};
    const previousWarningTime = previous['warningLocalTime'];
    const previousCreatedAt = previous['createdAt'];

    txn.set(linkRef, {
      watchedUid,
      watcherUid,
      status: 'accepted',
      watchedName: watchedProfile.displayName,
      watcherName: watcherProfile.displayName,
      watchedTimezone: watchedProfile.timezone,
      activeFrom,
      warningLocalTime:
        typeof previousWarningTime === 'string' ? previousWarningTime : '10:00',
      createdAt: isTimestamp(previousCreatedAt)
        ? previousCreatedAt
        : AdminTimestamp.fromMillis(now.getTime()),
      acceptedAt: AdminTimestamp.fromMillis(now.getTime()),
    });

    txn.update(inviteRef, {
      consumedBy: watcherUid,
      consumedAt: AdminTimestamp.fromMillis(now.getTime()),
    });

    return {
      status: 'linked' as const,
      linkId,
      watchedName: watchedProfile.displayName,
      activeFrom,
      alreadyLinked: false,
    };
  });
}

/**
 * Duck-typed rather than `instanceof Timestamp`.
 *
 * The same reason `check_in_fan_out.ts` gives: the value crosses a module
 * boundary, and an `instanceof` that silently fails against a second copy of the
 * SDK would drop the field with no error anywhere — here that would read as an
 * invite with no expiry, which the caller treats as expired.
 */
function isTimestamp(value: unknown): value is Timestamp {
  return (
    typeof value === 'object' &&
    value !== null &&
    'toMillis' in value &&
    typeof (value as { toMillis: unknown }).toMillis === 'function' &&
    'toDate' in value &&
    typeof (value as { toDate: unknown }).toDate === 'function'
  );
}
