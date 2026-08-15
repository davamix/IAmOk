# I Am Ok — Architecture

**Date:** 2026-08-15 · **Status:** Design. No code written. · **Supersedes:** the *Architecture
decisions* and *Open questions* sections of [HANDOVER.md](../HANDOVER.md).

The scope boundary in HANDOVER.md ("Explicit non-goals") still holds and is **not** re-opened
here. This is a relay for one notification between two people. It is not a health monitor.

---

## 1. Decisions taken this session

| Question | Decision | Consequence |
|---|---|---|
| Identity | **Google Sign-In** | Free; one tap on Android (account already on device); the uid survives reinstall and phone replacement, so links never break. Costs a small PII surface (email, display name). |
| Contact notification | **Quiet confirm, loud miss** | The daily check-in updates status silently. Only a *missed* day makes noise. Avoids training the family to swipe away the notification that matters. |
| Role representation | **Roles live on links** | A user is just a user. Each link names who is watched and who is watching. Someone can be both. |
| Away mode | **One global state, anyone can set it, no approval** | See §12. Away is a property of the watched *person*, not of a pair. |

Derived from those, decided here:

| Decision | Rationale |
|---|---|
| FCM is **data-only**, never notification-payload | The app must run code on arrival (update cache, cancel alarm, correct a false warning). A notification-payload message displays without waking app code, which would leave the dead man's switch armed. "Quiet confirm" makes this free — there is nothing to display anyway. |
| Firestore is the **source of truth**; FCM is a hint | See §3. Removes FCM from the correctness path entirely. |
| Warning fires from a **logic-bearing alarm**, not a display-only one | See §10. A false "she didn't check in" is the worst bug this app can have; the alarm must verify before it speaks. |
| Firestore + Functions in **`europe-west1` / `eur3`** | Owner in Spain. Latency, and GDPR data residency. **Irreversible** — see §16. |
| Pairing is **invite-code, watched-side originated**, redeemed through a callable Function | The watched person's device generating and sharing the code *is* the consent record. One step, no approval round-trip. |

---

## 2. Actors

The domain language is "elderly person" and "contact". Because roles now live on links, the
data model uses neutral terms — a link has a **watched** side and a **watcher** side.

| Actor | Is | Cares about | Can fail by |
|---|---|---|---|
| **Watched person** | Elderly user, one tap a day | Not being nagged; the tap obviously working | Forgetting; not noticing a reminder |
| **Watcher** | Family member, 1..n watched people | Knowing without being spammed | Ignoring a notification; never opening the app |
| **Watched runtime** | Flutter app + AlarmManager + notification channels | Firing 12:00/18:00/21:00; writing the check-in | OEM battery killer; revoked permissions |
| **Watcher runtime** | Flutter app + alarm isolate + FCM isolate + local DB | Deciding *correctly* whether to warn | Same, plus stale cache while offline |
| **Firebase** | Auth, Firestore, Functions, FCM | Durable truth, fan-out | Nothing at this scale |
| **FCM transport** | Google Play Services | Best-effort delivery | Doze deferral, throttling, force-stopped app |
| **Android / OEM** | The platform | — | Auto-revoking permissions, killing alarms |

The last two are **not controlled**. The design below assumes both misbehave.

---

## 3. The truth model

This is the spine of the whole design. Three tiers, with strict precedence:

```
1. Firestore          the source of truth.        Durable, server-timestamped, offline-queued.
2. FCM (data-only)    a wake-up hint.             Keeps tier 3 warm while the app is closed.
3. Local SQLite       an offline decision cache.  What a background isolate reads when it
                      cannot reach the network.
```

**FCM is not load-bearing.** If every push were dropped, the system stays correct — it just
gets slower, because the watcher reconciles from Firestore on app open and again at alarm
time. FCM earns its place for exactly one reason: it is the only way to refresh tier 3 while
the app is not running, which is what protects an *offline* watcher from a false warning.

The corollary is the operating rule for the whole codebase:

> **Reconcile, don't mutate.**
> There is one idempotent `reconcile()` per side. It reads current state, computes what
> alarms and status *should* exist, and makes reality match. It is called on app open, on FCM
> arrival, on alarm fire, and on boot. No code path incrementally patches state.

This collapses seven edge cases (reboot, late FCM, missed FCM, clock change, timezone change,
reinstall, away-mode transitions) into one code path that is unit-testable with no device and
no network.

**No state is ever transmitted as a command.** Every push is a "something changed, reconcile
now" nudge that carries no authority. Losing one costs latency, never correctness — which is
what stops a lost "away finished" message from silencing a watcher permanently (§12).

---

## 4. The isolate boundary

The single most consequential platform constraint, and the one most Flutter background designs
get wrong. **Three isolates run this app, and they share no memory.**

| Isolate | Entered by | Lives for | Can see |
|---|---|---|---|
| **UI** | User opening the app | Foreground session | Everything |
| **FCM background** | `onBackgroundMessage`, app closed | ~seconds | Nothing from UI. Must init Firebase itself. |
| **Alarm** | `android_alarm_manager_plus` callback | ~seconds | Nothing from UI. Must init its own plugins. |

Everything the background isolates need must therefore be **on disk**, not in memory. Riverpod
providers, in-memory caches, and the Firestore listener's live state are all invisible to them.

Consequences that shape the design:

- The local store is **SQLite** (`sqflite`), not `SharedPreferences` — cross-isolate writes with
  real locking. `SharedPreferences` caches in memory per isolate and needs `reload()` gymnastics.
- Both background entry points are `@pragma('vm:entry-point')` **top-level functions** that
  bootstrap the minimum they need, call `reconcile()`, and exit.
- The domain layer must have **zero Flutter dependencies** so it runs identically in all three.
- **Timezones are read from disk, never from a plugin, in a background isolate**
  ([ADR-0002](decisions/0002-clock-split.md)). The UI writes the device's IANA zone to `LocalStore`
  on resume; the watched person's zone is already there, denormalized onto the link by §7. This is
  the canonical instance of the rule above — the alternative is a plugin registrant on the alarm
  path, to answer a question the UI already knows the answer to.

---

## 5. Client architecture

```
┌─ Presentation ──────────────────────────────────────────────┐
│  CheckInShell (watched mode)   WatchShell (watcher mode)     │
│  OnboardingFlow   HealthPanel   PairingScreens   AwayScreen  │
│  DebugHarness                                                │
├─ Application (Riverpod) ────────────────────────────────────┤
│  CheckInController  WatchListController  OnboardingController│
│  AwayController     SystemHealthController                   │
├─ Domain — pure Dart, no Flutter, no Firebase ───────────────┤
│  DayKey          day boundary arithmetic in a given tz       │
│  AwayPeriod      from/through, containment, validity         │
│  ReminderPolicy  which of 12/18/21 should exist, given state │
│  WarningPolicy   should the watcher warn for day D?          │
│  Reconciler      desired-state calculator (both sides)       │
│  Link, CheckIn, WatchStatus  entities                        │
├─ Data ──────────────────────────────────────────────────────┤
│  AuthRepository  UserRepository  LinkRepository              │
│  CheckInRepository  AwayRepository  LocalStore(SQLite)       │
│  InviteService                                               │
├─ Platform edge ─────────────────────────────────────────────┤
│  AlarmScheduler  NotificationService  FcmService             │
│  PermissionService  Clock  ClockService  ConnectivityService │
└─────────────────────────────────────────────────────────────┘
```

**The rule that makes this testable:** every hard decision — what day is it, should a reminder
exist, should we warn, is this day inside an away period, is this a correction — lives in
**Domain** as a pure function over explicit inputs. No `DateTime.now()`, no plugin calls, no
I/O. The layers above only supply inputs and execute the result.

---

## 6. Components & services

| Component | Layer | Responsibility | Isolates |
|---|---|---|---|
| `AuthRepository` | Data | Google Sign-In → Firebase uid; sign-out; current uid | UI |
| `UserRepository` | Data | `users/{uid}` doc; timezone; FCM token subcollection | UI |
| `LinkRepository` | Data | Read links for either role; revoke; per-link warning time | UI |
| `CheckInRepository` | Data | Write today's check-in; read a watched person's days | UI, Alarm |
| `AwayRepository` | Data | Read / set / cancel the away period for a watched user | UI, FCM, Alarm |
| `InviteService` | Data | Create invite; call `redeemInvite` | UI |
| `LocalStore` | Data | SQLite. Per-link `lastConfirmedDate`, `warningsShownFor`, `activeFrom`, `watchedTimezone`, cached `awayPeriod`; plus `deviceTimezone`, `pendingAlarms`, `lastReconcileAt` (a **timestamp** — §10 renders "offline since 10:14") | **All three** |
| `AlarmScheduler` | Platform | Schedule / cancel / enumerate alarms; `rescheduleOnReboot` | UI, Alarm |
| `NotificationService` | Platform | Channels, display, cancel, replace-by-id, tap routing | All three |
| `FcmService` | Platform | Token lifecycle → Firestore; route foreground + background messages | UI, FCM |
| `PermissionService` | Platform | POST_NOTIFICATIONS, exact alarms, battery exemption, auto-revoke exemption | UI |
| `Clock` | Platform edge | The current instant. Trivial and **plugin-free**. | **All three** |
| `ClockService` | Platform | Discover device IANA tz → `LocalStore` on resume; device-vs-server skew detection | UI |
| `ConnectivityService` | Platform | Online state for the staleness banner | UI |
| `Reconciler` | Domain | Pure desired-state calculation for both sides | All three |

`Reconciler` appearing in all three isolates while depending on nothing is the payoff of the
layering. It is the same code deciding, whether a human opened the app or an alarm woke a
bare isolate at 10:00.

`Clock` and `ClockService` are two components rather than one because their isolate requirements
differ ([ADR-0002](decisions/0002-clock-split.md)). Reading the current instant is core Dart and is
needed everywhere; discovering the device's zone is a **plugin** call, and skew detection needs a
server round-trip that §11 scopes to app-open. Only the first belongs in a bare isolate.

The consequence is worth stating plainly, because the intuitive reading is the opposite: **the
alarm isolate computes `D` with no plugin access at all.** It needs the current instant
(`DateTime.now()`, core Dart), the *watched person's* zone (denormalized onto the link by §7, so
already on disk), and `package:timezone` (pure Dart, compiled-in database). `flutter_timezone` is
only ever needed to discover the device's *own* zone, which is a UI-side question whose answer is
cached to `LocalStore`.

---

## 7. Data model

```
users/{uid}
  displayName        string      from Google profile
  timezone           string      IANA, e.g. "Europe/Madrid"
  createdAt / lastSeenAt

users/{uid}/tokens/{token}                    subcollection, not an array
  platform           string
  updatedAt          timestamp                → lets the Function prune by age and by UNREGISTERED

users/{uid}/shared/away                       single doc. absent ⇒ not away
  from               string      YYYY-MM-DD   first away day, watched person's tz
  through            string      YYYY-MM-DD   last away day, INCLUSIVE
  setBy              string      uid
  setByName          string      denormalized → "Ana marked Mum away"
  setAt / updatedAt  timestamp

links/{watchedUid}_{watcherUid}               deterministic id ⇒ pairing is naturally idempotent
  watchedUid         string
  watcherUid         string
  status             "accepted" | "revoked"
  watchedName        string      denormalized  → watcher never needs to read users/{watchedUid}
  watchedTimezone    string      denormalized  → watcher computes the same day boundary
  activeFrom         string      YYYY-MM-DD    → never warn about days before the link existed
  warningLocalTime   string      "10:00"       → watcher-local, per link
  createdAt / acceptedAt

checkins/{watchedUid}/days/{YYYY-MM-DD}       doc id IS the day, in the watched person's tz
  deviceTappedAt     timestamp   client clock at tap    → what the contact is shown
  receivedAt         timestamp   serverTimestamp()      → audit + skew detection
  timezone           string      tz at moment of tap

invites/{CODE}                                6 chars, unambiguous alphabet (no O/0/I/1)
  watchedUid, createdAt, expiresAt, consumedBy?, consumedAt?
```

Four things here are load-bearing:

**The document id is the date.** Writing `days/2026-08-15` gives once-per-day semantics for
free: a second tap the same day is an *update*, which does not fire `onDocumentCreated`, so no
duplicate push. No dedupe logic anywhere.

**Denormalizing `watchedName` and `watchedTimezone` onto the link** means a watcher never reads
another user's document. Security rules stay tight and the watcher can render fully offline.

**Away lives under the watched user, not on links.** Away is global by definition — there are
no taps at all — so a per-link copy would be a fan-out write that can partially fail and leave
one watcher warning through a holiday. One document, one truth. See §12.

**Two timestamps, not one.** See §11 — this is a correction to HANDOVER.md.

---

## 8. Security rules

| Path | Read | Write |
|---|---|---|
| `users/{uid}` | self | self |
| `users/{uid}/tokens/{t}` | self | self |
| `users/{uid}/shared/away` | self, **or** an accepted link exists | self, **or** an accepted link exists — plus validation (§12) |
| `links/{id}` | `watchedUid == uid \|\| watcherUid == uid` | Function only, except: either party may set `status: "revoked"` |
| `checkins/{uid}/days/{d}` | self, **or** an accepted link exists for `(uid, request.auth.uid)` | self only |
| `invites/{code}` | nobody | Function only |

The watcher read on `checkins` costs one `get()` per rule evaluation, and it is what makes the
pull-based reconciliation path possible. Without it the watcher would depend on FCM for
correctness, which §3 explicitly refuses.

Away is a **direct client write** rather than a callable Function, on purpose: it means a
watcher can set away on a plane and have it queue offline like any other write. Validation
lives in the rules — `through >= from` and `through <= request.time + 30d` on every write;
`from >= today` **on create only**, with `from` immutable on update, so that cancelling an
in-progress period by truncation is not rejected ([ADR-0001](decisions/0001-away-cache-precedence.md)).
That is enough — the cap is a guardrail, not a security boundary.

Invites are unreadable by clients on purpose — a readable invite collection is an enumerable
list of codes.

---

## 9. Cloud Functions

Three required, one optional. All in `europe-west1`.

| Function | Trigger | Does |
|---|---|---|
| `onCheckInCreated` | `checkins/{uid}/days/{date}` created | Read accepted links where `watchedUid == uid` → collect watcher tokens → send **data-only, high-priority** FCM `{watchedUid, date, deviceTappedAt, tz, watchedName}` → delete tokens that return `UNREGISTERED` |
| `onAwayChanged` | `users/{uid}/shared/away` written or deleted | Fan out a data-only nudge to **every party** — all watchers *and* the watched device, since either may have made the change. Each device reconciles and renders its own notification. |
| `redeemInvite` | Callable | Validate code + expiry + not-consumed → create `links/{watched}_{watcher}` with `activeFrom = today in watched tz` → mark invite consumed. Atomic in a transaction. |
| `revokeLink` | Callable *(optional)* | Could be a client write under rules; a Function gives an audit point. Decide at implementation. |

Redemption **must** be a Function: the client cannot enforce single-use or expiry, and cannot
be allowed to read another user's uid out of an invite.

`onAwayChanged` sends a nudge, not a command. There is deliberately **no "away finished"
message** — expiry is arithmetic against `through`, computed independently on every device
(§12). Nothing needs to run on the last day.

**Deliberately absent:** a scheduled nightly "who didn't check in" function. HANDOVER.md ruled
Cloud Scheduler out and this design does not re-open it. The data model supports adding it
later without migration — it is the documented escape hatch if §10's client alarms prove
unreliable on real OEM hardware (§14).

---

## 10. Alarm architecture

### The asymmetry

Two kinds of alarm, chosen by what a *spurious* fire costs:

| | Watched side — reminders | Watcher side — the warning |
|---|---|---|
| Fires | 12:00, 18:00, 21:00 watched-local | `warningLocalTime` watcher-local, day after |
| A false fire costs | Nothing. A redundant "remember to tap". | **Everything.** Telling a family something false is the worst possible bug. |
| Mechanism | `flutter_local_notifications.zonedSchedule` — display only, no code runs | `android_alarm_manager_plus` — wakes a Dart isolate |
| Boot recovery | Free (`ScheduledNotificationBootReceiver`) | `rescheduleOnReboot: true` + a BOOT_COMPLETED `reconcile()` |
| Verifies before speaking | No — cancellation is enough | **Yes** — see below |

### The dead man's switch, self-verifying

Cancellation alone is not trusted. The alarm isolate **reconciles first, then decides** —
amended by [ADR-0001](decisions/0001-away-cache-precedence.md), which found that the original
ordering let a stale cached away silence a watcher for as long as the away period had left to
run. A runnable model of what follows is at
[`tools/models/away_warning_model.dart`](../../tools/models/away_warning_model.dart).

**First, reconcile.** Attempt to read `checkins/{watchedUid}/days/{D}` **and**
`users/{watchedUid}/shared/away`. If and only if the read **succeeds**, overwrite the cached
away period with what Firestore returned — *including overwriting it with nothing* — refresh
`lastConfirmedDate`, and stamp `lastReconcileAt`.

> A read that **fails is not an answer.** A timeout, a permission denial, and an App Check
> rejection all happen while the device is online, and none of them prove the away document is
> gone. Only a read that succeeded and returned nothing may clear the cache. Keying this on
> connectivity instead would wipe a legitimate away on a transient error and warn falsely.

**Then decide**, against a cache that is now either fresh or knowably stale:

1. Compute `D` = the most recently **completed** calendar day in the watched person's timezone.
2. If `D < link.activeFrom` → silent. (Nothing to say about days before pairing.)
3. If `LocalStore.lastConfirmedDate >= D` → silent. **Evidence outranks doubt:** a recorded
   check-in settles the day before any away reasoning runs, because tapping during an away day
   is allowed (§12).
4. If `D` falls inside the cached away period:
   - verified within the last **2 days** → silent;
   - otherwise → warn, **distinctly**: *"Can't check on Mum — your phone has been offline since
     Tuesday 10:14. She was marked away until Saturday 22 August."*
5. Otherwise **warn**: *"No check-in from Mum yesterday."* if the read succeeded, or *"No
   check-in received from Mum yesterday — your phone has been offline since HH:MM."* if it did
   not. Different message, different meaning.
6. Record `warningsShownFor += D`.

Steps 4 and 5 matter for the same reason. Silence would be a silent failure; a flat "she didn't
check in" would be a claim the device cannot support. The notification says what is actually
known, and nothing more.

Step 4's staleness bound is what makes the warning alarm **keep firing daily through an away
period** worth anything. The alarm is not cancelled during away, and each fire re-verifies
against Firestore — so an away cancelled remotely is picked up at the next fire even if every
push was lost. Cancelling and re-arming would be cheaper and less correct.

Offline, the device **cannot** distinguish "the away was cancelled and I did not hear" from "the
away is still on and I have not checked" — the inputs are identical. Step 4 therefore chooses
which error to prefer, and prefers speaking. Silence is the one failure this app cannot detect in
itself.

Belt and braces: incoming taps still cancel the pending alarm (fast path), *and* the alarm
re-derives the answer at fire time (correct path). Either alone would be a bug.

### The rolling window

Nothing runs at midnight to arm tomorrow's alarms, so alarms are not armed one day at a time.
Instead, `reconcile()` maintains a **7-day rolling window** of desired alarms and makes reality
match — creating what's missing, cancelling what shouldn't exist. Called on open, on check-in,
on FCM, on alarm fire, and on boot. Idempotent by construction, and boot recovery is not a
special case: it is the same function.

During an away period the window extends to **`through` + 7 days**, and the days inside the
away period are simply absent from the desired set. This is what lets the watched side stay
display-only: the reminders for the first days back are already scheduled before the person
leaves, so the app re-arms itself without anyone opening it, and no logic-bearing alarm is
needed on the watched side.

### Correcting a false warning

A warning already shown for `D`, then a check-in for `D` arrives — because the watched person
was offline and Firestore only just synced, or because FCM was deferred until morning:

```
FCM/reconcile sees checkin for D
  → D ∈ LocalStore.warningsShownFor?
      → cancel/replace notification id hash(link,D)
      → "Correction: Mum did check in yesterday, at 23:40."
      → lastConfirmedDate = D; remove D from warningsShownFor
```

One handler covers both causes. This is the highest-value thing to test.

---

## 11. Time, and a correction to HANDOVER.md

HANDOVER.md says *"Write `serverTimestamp()` for `tappedAt`. Never trust device clocks."*
**That is wrong when combined with offline-first**, and the combination is the normal case.

`serverTimestamp()` is resolved **when the write reaches the server**, not when it was queued.
A tap at 23:50 with no signal, syncing at 08:00 the next morning, would be stamped 08:00 — and
land on the wrong day. Since HANDOVER.md also (correctly) says not to build a retry queue
because Firestore's offline persistence handles it, these two instructions collide.

Resolution:

- **The day is decided on the device, at tap time.** The document id `YYYY-MM-DD` comes from the
  device clock in the device's timezone. There is no alternative that works offline.
- `deviceTappedAt` = client clock. This is what the contact is shown ("checked in at 23:40"),
  because it is what actually happened.
- `receivedAt` = `serverTimestamp()`. Audit trail, and the only skew signal available.
- **Clock skew is detected, not silently corrected.** On app open while online, compare device
  clock to server time; if the drift exceeds a few minutes, surface it in the health panel and
  deep-link to date/time settings. A device that is a day off will file check-ins on the wrong
  day and no server-side fix-up can distinguish that from a legitimate offline sync.

Everything else about time stands:

- The **day is defined in the watched person's timezone**, carried on the link and in the payload.
  Away dates use the same definition.
- Scheduling uses `timezone` + `flutter_timezone` and `zonedSchedule` — never raw UTC offsets,
  so DST is handled. `flutter_timezone` is a **plugin and is called only from the UI isolate**,
  which caches the device's IANA zone to `LocalStore`; background isolates read it from there
  ([ADR-0002](decisions/0002-clock-split.md)). `package:timezone` itself is pure Dart and runs
  anywhere.
- **A cached device zone can go stale** if someone travels without opening the app. Accepted: a
  watcher's own zone cannot affect `D` — that uses the watched person's zone from the link — and
  the watched person opens the app daily to tap, so the worst case is one boundary day after a
  flight, which the soft-midnight rule below already tolerates.
- The watcher's alarm fires at **watcher-local** time (default 10:00) but asks about the last
  completed **watched-local** day. This is why a watcher in another country is never woken at 03:00.
- Midnight remains a soft boundary — a tap at 00:05 Monday and 23:55 Tuesday is ~48h of real
  silence with both days green. Inherent to calendar-day check-ins. "OK" means *sometime that
  day*, and the UI should say so.

---

## 12. Away mode

A bounded period during which no check-in is expected: a holiday, a hospital stay, a week at a
daughter's house.

### The model

**One document, one truth.** `users/{watchedUid}/shared/away` holds a single period. Absent, or
`through` earlier than today, means not away. Away is a property of the **watched person**, not
of a pair — because the effect is global: during away there are no taps at all, so suppressing
warnings for only one watcher would leave every other watcher warned every morning of the trip.

**Anyone in the group can set, extend, or cancel it. No approval.** The watched person or any
watcher writes the same document. A watcher setting away is asserting *"I know she's fine, and
I'm accountable for that"* — which is exactly what happens when someone is in hospital or
staying with family, and precisely when the watched person is least able to answer a prompt.
Requiring approval would block the feature in its main use case.

`setByName` is denormalized onto the document so this is never mysterious: every device can
show *"Ana marked Mum away until Sat 22 Aug."*

### Effects

| Side | During an away day |
|---|---|
| **Watched** | No reminders at 12/18/21. Home screen reads *"You're away until Saturday 22. Your family isn't expecting a check-in."* Tapping is still **allowed** — it is harmless, reassuring, and writes a normal check-in that watchers see as usual. |
| **Watcher** | No warning. Status reads *"Away until Sat 22 Aug — set by Ana"*, in the app, not as a notification. |

Both fall out of two pure functions gaining one argument:

```
ReminderPolicy(D, away)          → no reminders if away.from <= D <= away.through
WarningPolicy (D, away, ...)     → silent      if away.from <= D <= away.through
```

`D` is always a date in the **watched person's** timezone, matching §11.

### Why there is no "away finished" message

The original sketch had the watched app send "away started" and later "away finished" to the
watchers. Both directions fail, asymmetrically:

- **"Away started" lost** → watchers warn through the holiday. Annoying, visible, self-correcting.
- **"Away finished" lost** → the watcher's app stays silent **forever**. Nobody notices, because
  silence is what away mode looks like. The app is dead and reports nothing.

There is also nothing to send it *with*: during away the watched phone has no reason to run
code, so no alarm exists to fire on the last day, and the message would only go out whenever the
person next happened to open the app.

Instead, **`through` is a date and expiry is arithmetic.** Every `reconcile()` on every device
compares today against it. Nothing is transmitted, nothing can be lost, and the period ends at
the same instant on every phone whether or not any of them has been online since it started.

`onAwayChanged` (§9) still fires a data-only nudge so devices react within seconds rather than
at their next reconcile — but it carries no authority. Losing it costs latency, not correctness.

### Notifications around the transition

Away transitions are rare — a handful of times a year — so alarm fatigue is not a risk here and
these can be ordinary notifications rather than silent ones:

| Event | Who is told | Message |
|---|---|---|
| Away set by a watcher | All other watchers, and the watched person | *"Ana marked Mum away until Sat 22 Aug."* |
| Away set by the watched person | All watchers | *"Mum is away until Sat 22 Aug."* |
| Away cancelled | Everyone except whoever cancelled | *"Mum's away period was cancelled — daily check-ins resume today."* |
| Away ending | All watchers | *"Mum's away period ends tomorrow."* |

The last one needs no server: every device already knows `through`, so it is a locally scheduled
notification. It exists so the resumption of warnings is never a surprise.

### Rules

- **Cap: 30 days.** To go longer, set it again. An away that outlives its purpose is how this app
  silently dies, and a short cap forces a deliberate renewal.
- **No retroactive away.** `from` is today at the earliest. Owner's call, and it costs nothing —
  if a warning already fired before anyone remembered, the family has already made the phone call
  that the warning was for. Setting away from today forward is all that remains useful.
- **Cancellation is symmetric with activation.** Anyone can cancel; the same document is written;
  the same fan-out and the same `reconcile()` run. There is no separate cancel path.
- **Cancellation truncates; it does not delete** — [ADR-0001](decisions/0001-away-cache-precedence.md).
  `through` is pulled back to the last genuinely-away day, so the days already spent away stay
  covered. Deleting the document would retroactively un-cover them, and a device that then
  refreshed its cache would warn about a day the person was legitimately away — a false claim,
  which is the worst thing this app can do. The exception is cancelling on the day the period
  *starts*: nothing has elapsed, and truncating would write `through = from - 1` and violate
  `through >= from`, so that case deletes.
  ```
  cancel(a, day) = null                       if day <= a.from
                 = {a.from, day - 1}          otherwise
  ```
- **`from` is immutable once written.** It follows from the rule above: truncating an in-progress
  period rewrites a document whose `from` is already in the past, so §8's `from >= today` can only
  be a *create* rule. On update, `from` must equal what is already stored.
- **Last write wins.** Two people setting away simultaneously is a single-document conflict at
  family scale. `setByName` makes the outcome legible.
- **UI: a calendar picker, with the selected day labelled unambiguously** — *"Last day away:
  Saturday 22"* and *"Back on Sunday 23"*. "Until" alone is ambiguous about whether the chosen
  day still needs a tap.

### Designed-in, not yet exposed

`from` exists as a real field rather than always being today, so **scheduling a future away**
("I'm going away on the 20th") is a UI change with no migration. Not in v1.

Deliberately **not** built: a per-link "mute just me". Owner's decision — if she is away, she is
away for everyone.

---

## 13. Permissions and the health panel

Permissions are not a one-time onboarding gate — Android can take them back. Android 11+
**auto-resets permissions for unused apps**, which is a live threat for a watcher who never
opens the app: they would silently stop receiving anything.

So permissions are modelled as **continuously observed state**, re-checked on every app resume
and surfaced in a **health panel** that is always reachable, showing green/red per item:

| Check | API | If missing |
|---|---|---|
| Notifications | `POST_NOTIFICATIONS`, API 33+ | App is inert. Hard gate with a plain-language explanation. |
| Exact alarms | `USE_EXACT_ALARM` declared; `canScheduleExactAlarms()` | Deep-link to settings. Reminders degrade to inexact. |
| Battery optimization | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Prompt once, then explain; link dontkillmyapp.com |
| Auto-revoke exemption | `isAutoRevokeWhitelisted` | Prompt. Critical for low-usage watchers. |
| Last sync | app state | "Last update: 3 days ago" banner |
| Clock skew | §11 | Warn, deep-link to settings |

`USE_EXACT_ALARM` is available to apps whose core purpose is alarms and reminders. This app
plausibly qualifies but **expect to justify it in Play review** — write the justification before
submitting, not after rejection.

---

## 14. Testing

| Level | What | Tool |
|---|---|---|
| Unit | `DayKey`, `AwayPeriod`, `ReminderPolicy`, `WarningPolicy`, `Reconciler`, correction logic | Plain `test` — no Flutter, no device |
| Repository | Firestore reads/writes, offline queue behaviour | `fake_cloud_firestore` |
| Rules + Functions | The security rules table in §8, away write validation, `redeemInvite` transaction | Firebase Emulator Suite, `@firebase/rules-unit-testing` |
| Device | Notification delivery, alarm survival, OEM battery killers | **Real hardware. Irreducible.** |

Away is almost entirely pure-function territory, so it is cheap to test hard. Worth covering
explicitly: the day `from` starts and the day after `through`; away set mid-period; away
cancelled while a device was offline; away expiring on a device that has not been online since
it started; and a watcher whose timezone differs from the watched person's around both edges.

### Build the debug harness early

A screen, debug builds only, that can: force the current date, fire any alarm now, inject a
synthetic FCM payload, dump `LocalStore`, and run `reconcile()` on demand.

Without it, verifying a 24-hour behaviour takes 24 hours. With it, it takes seconds. Given that
the riskiest logic in this app is all time-dependent, this is not a nice-to-have — build it
alongside the first alarm, not after.

### The one thing an emulator cannot tell you

Whether alarms and data-only FCM actually survive on Xiaomi / Samsung / Huawei with stock power
settings. HANDOVER.md already names this the riskiest unknown; nothing in this design changes
that. It is the trigger condition for un-deferring the scheduled Function in §9.

---

## 15. Package shape

| Concern | Package |
|---|---|
| Firebase | `firebase_core`, `firebase_auth`, `cloud_firestore`, `firebase_messaging` |
| Sign-in | `google_sign_in` |
| Display alarms + boot restore | `flutter_local_notifications` |
| Logic-bearing alarms | `android_alarm_manager_plus` |
| Time | `timezone`, `flutter_timezone` |
| Cross-isolate local store | `sqflite` |
| Permissions | `permission_handler` |
| Connectivity | `connectivity_plus` |
| State | `flutter_riverpod` |

Deep links for invites: **Android App Links**, not Firebase Dynamic Links — that service shut
down in August 2025. `assetlinks.json` can be hosted on GitHub Pages under the domain the
`io.github.davamix` namespace already implies. Typed codes work with no hosting at all, so app
links are polish, not a dependency.

---

## 16. One-way doors

Decisions that cannot be undone later without breaking existing installs. All three are now
settled — recorded here because they constrain everything downstream, not because anything
remains to decide.

| Decision | Value | Why it is permanent |
|---|---|---|
| `applicationId` | `io.github.davamix.i_am_ok` | Fixed once published to Play |
| **Firestore location** | **`europe-west1`** · settled 2026-08-15 | Chosen at database creation, never changeable. Picked over `eur3` for co-location with Functions, EU residency, and cost. |
| **Firestore mode** | **`FIRESTORE_NATIVE`** · settled 2026-08-15 | Datastore mode would invalidate the entire client SDK approach in this document |
| Firebase project id | **`i-am-ok-c74ca`** · settled | Not changeable |

Cheaply reversible, by contrast: adding the scheduled Function (§9), adding phone auth
alongside Google, changing warning times, changing the notification copy, exposing future-dated
away periods (§12).

---

## 17. Risks this design pass surfaced

New relative to HANDOVER.md's inventory.

| Risk | Severity | Handling |
|---|---|---|
| `serverTimestamp()` + offline sync files a check-in on the **wrong day** | **High** — silently wrong data | Device-side day id + dual timestamps (§11) |
| Android auto-revokes permissions for **unused** apps — kills inactive watchers silently | **High** — silent failure, exactly the mode this app can't afford | Request auto-revoke exemption; health panel (§13) |
| Background isolates can't see UI state; a naive design puts the alarm's decision data in memory | High — false warnings | SQLite as the cross-isolate contract (§4) |
| An away period outliving its purpose — the app goes quiet and stays quiet | Medium — indistinguishable from working | 30-day cap; "ends tomorrow" notice; away state always visible in-app (§12) |
| Warnings for days before the link existed | Medium | `link.activeFrom` (§7) |
| Watcher offline at alarm time — cannot distinguish "no check-in" from "no network" | Medium | Distinct, honest message (§10, step 7) |
| One watcher silences the whole family by setting away | Low — accepted by design | `setByName` on every surface; anyone can cancel (§12) |
| High-priority data-only FCM is quota-limited for backgrounded apps | Low | A few messages per person per day. Far under quota. |
| Firestore rules `get()` on every checkin read costs a read | Low | Negligible at this scale; noted so it isn't a surprise |

---

## 18. Still open

Not decided, and not blocking a first build.

- **Watcher-side onboarding when the watched person has no phone skills.** Realistically the
  family member sets up both devices. The pairing flow should assume that, and probably support
  doing it in one sitting on two phones.
- **What the watcher sees on cold open after weeks away.** A history strip? Just today?
- **Multiple watched people per watcher.** The model supports it; the UI has not been designed.
- **Future-dated away periods.** The data model supports it (§12); whether the UI exposes it is
  a v2 question.
- **The first day back after away.** Routine is most likely to break the day someone returns from
  a trip. No grace day is planned — the reminders do their job — but the copy could acknowledge it.
- **GDPR posture.** Google Sign-In stores email + display name. Data stored is a timestamp, an
  away period, and a link. Needs a privacy policy before Play submission; owner is in Spain, data
  in EU.
- **Release signing.** Still debug keys.
- **Elderly-facing UI/UX.** Large tap target, high contrast, minimal chrome. Not started.

---

## 19. Suggested build order

HANDOVER.md offered two candidates and preferred "prove the risky part first". This design
sharpens that into a sequence, because the risky part now has a precise definition.

1. **Domain layer + tests, no Flutter.** `DayKey`, `AwayPeriod`, `ReminderPolicy`,
   `WarningPolicy`, `Reconciler`. A day's work, zero dependencies, and it is the spec.
   **Give the policies their `away` argument from the first line**, even while it is always
   null — retrofitting it later means touching every call site and every test.
2. **The debug harness + watched-side reminders.** Fake data, no backend. Prove 12/18/21 fire,
   cancel on tap, survive reboot — on **real hardware**.
3. **The watcher-side self-verifying alarm**, still with fake local data. Prove the false-warning
   suppression and the correction path.
4. **Then** wire Firebase: project (EU location), auth, check-in write, the relay Function.
5. Pairing.
6. **Away mode.** One document, one Firestore trigger, two policy branches already unit-tested
   in step 1. Deliberately late: it is low-risk once the policies exist, and it is meaningless
   before pairing works.
7. Health panel, UI polish.

Steps 1–3 need no Firebase project, no Blaze plan, and no credit card, and they retire the
risk that would invalidate everything else.
