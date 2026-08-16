# Phase 2 — Watched side · summary

**Date:** 2026-08-16 · **Status:** Code complete and reviewed. **The device exit criteria are NOT
met** — no handset was attached. · **Next:** the device pass, then Phase 3

Phase 1 was a domain layer and a stock Flutter counter scaffold. Phase 2 built the four layers above
it and made the app real: `LocalStore`, `AlarmScheduler`, `NotificationService` and its channels, the
`Clock`, the Tap screen, and the debug harness. It also landed the **two decisions carried in from
the Phase 1 gate**, which are the parts most worth reading.

**517 tests**, up from 328. `flutter analyze` clean. `flutter build apk --debug` succeeds.

---

## The two carried decisions

### 1. The domain is told whether a notification can actually be delivered

`WatcherReconciler.reconcile` used to record a message as *shown* at the moment it decided one was
*owed*. It had no way to know whether the platform posted anything, so "we decided to speak" and
"the watcher was told" were the same fact.

Now `NotificationDelivery` is passed in as an explicit value, exactly as `now`, `away` and
`watcherZone` already are — no import, no coupling, no I/O, and testable by passing a value.

| State | Post? | Consume? | When |
|---|---|---|---|
| `available` | yes | yes | normal |
| `redundant` | no | **yes** | the reader is looking at the screen that already shows this |
| `unavailable` | no | **no** | `POST_NOTIFICATIONS` revoked — nothing was delivered, so nothing is owed off |

Applied to **both** channels, `warningsShownFor` and `accessLostNotifiedOn`, because fixing one and
leaving the other is the exact mistake ADR-0004's clamp made and it cost two review rounds.

**What it actually closes.** For the daily warning, mis-recording self-heals — a new day `D` gets a
fresh attempt. **The access-lost cadence does not.** Days 0, 1, 3, 7 and 14 were each consumed in
silence on a muted phone, and permissions returning on day 20 owed nothing until day 21: a cadence
built to survive a *sleeping* device failing on a *muted* one, which §13 rates High precisely because
it happens to watchers who never open the app.

Two details that took some care:

- **`accessLostSince` and `accessLostCause` are deliberately NOT gated.** They record a fact about
  the *read* — the backend refused us, on this day, for this reason — not about what a human saw.
  §13's health panel keys on them, and a phone with notifications revoked is exactly the phone whose
  panel must still be able to explain itself when it is finally opened. Only the *notified-on* stamp
  is a record of delivery.
- **The gate only ever subtracts.** A day settled by a check-in stays silent at every delivery
  state; `available` cannot resurrect it. Asserted, because a gate that could add is a gate that can
  make the app speak when it should not.

Tested in `test/domain/reconcile/notification_delivery_test.dart`, including the brief's four
required cases. The cadence case is asserted **with its contrast** — six delivered days leave day 6
*not* due, six undelivered days leave it *still* due — because the first assertion alone would pass
against an implementation that never advances the cadence at all.

**Who supplies it.** `PermissionService.delivery({appInForeground})`, which now exists. Phase 3 wires
it into the watcher reconcile; the brief's "until they do, pass `available`" no longer applies.

**The branch order moved into the domain** as `NotificationDelivery.from({canPost, appInForeground})`
after the testing review pointed out it was the only production producer of the enum and was untested.
Checking `canPost` *first* is what makes a watcher with notifications revoked come out `unavailable`
even while the app is open — and the app being open is exactly when `reconcile()` definitely runs.
The other order returns `redundant`, consumes the reminder, and reopens the defect. That is a
decision over two booleans, so it belongs where decisions live and where a 2×2 can assert it.

### 2. The Tap screen names who will be notified, and says nothing else

`WatchedReconciler` gained a `links` input and returns a `WatchedAudience` — the accepted links, by
name, sorted so the line does not reorder between sessions.

**This exposed a gap in the data model that had to be closed first.** §7 denormalised `watchedName`
onto the link but nothing in the other direction, and §8 grants `users/{uid}` read **to self only** —
so the watched person's device had no path from a `watcherUid` to a name, and the link was the only
document it may read that could carry one. The screen was not buildable as specified.

`Link` therefore gained **`watcherName`**, and §7 was amended. The alternative was relaxing §8's read
rule so every watched person could read the profile of everyone watching them, which is a much larger
change to a much more load-bearing rule. Like `watchedName`, and like `setByName` in ADR-0003, it is
a **display label and not an identity**: written by `redeemInvite` from the redeemer's Google profile,
changeable by that user afterwards, and nothing decides anything from it. This is recorded as a §7 amendment, **and the decision above it as
[ADR-0005](../architecture/decisions/0005-the-tap-screen-names-who-is-told.md)** — the architecture
review's call, and the right one. The *field* is a mechanical consequence of a screen §8 makes
unbuildable otherwise; the *decision* deliberately accepts a security finding on behalf of a user
population, which is precisely what the decisions index is for. It was living in three places, none
of them the index, while citing ADR-0003 as its model — and ADR-0003 is an ADR.

**The empty state was settled with the owner**, and the answer overrode the brief's own "quiet
reading" of showing nothing:

> *"No one is set up to know you're OK. Ask a family member to help you add someone."*

The reasoning for showing something at all: a big button and no explanation is its own silent failure
for someone who has never been paired.

It said *"…OK **yet**."* until the review, and two reviewers caught the same thing independently:
"yet" asserts *not started*, which is false in precisely the post-revocation state. One word removed,
and the line is now true in both states it has to cover.

**It is one line covering both "never paired" and "everyone revoked", and that is the decision rather
than a limitation.** Distinguishing them requires tracking that someone *left*, and rendering that is
the "someone stopped watching you" message on the explicitly-rejected list, under another name. So
the line never announces a change — it describes what is true now, in the same words, whichever way
the screen arrived there. It is styled as ordinary secondary text, and a test asserts the colour
**positively** — excluding only `colorScheme.error` would still admit `errorContainer` or a red
literal, and styling it as a warning reintroduces the rejected message by appearance rather than by
wording.

`WatchedAudience.from` dedupes by **watcher, never by name**: two different people called Ana must
both appear, because collapsing them would silently drop a real watcher from a list whose only job is
to be complete.

---

## What else was built

| Component | File | Notes |
|---|---|---|
| `Clock` | `platform/clock.dart` | ADR-0002's plugin-free half. Returns **UTC**, never a device-local `DateTime`. `SystemClock(offset:)` is the harness's forced date; the offset lives in `LocalStore` so all three isolates agree what day it is. |
| `ClockService` | `platform/clock_service.dart` | `flutter_timezone`, **UI only**. Returns a zone; the Application layer persists it. Validates against the bundled tzdata at the boundary so an unusable name never reaches a background isolate. |
| `LocalStore` | `data/local_store.dart` | sqflite, §6's schema in full. Seven tables. Converts at the boundary so nothing above handles a raw row. |
| `NotificationService` | `platform/notification_service.dart` | **Three** channels — see below. |
| `AlarmScheduler` | `platform/alarm_scheduler.dart` | Interface + `NotificationAlarmScheduler`. Enforces **toCancel before toSchedule** internally so no caller can get it wrong. |
| `AlarmIds` | `platform/alarm_ids.dart` | Warning ids are `hash(link, D)` — both halves, always. Reminder ids are `hash(day, slot)` and deliberately exclude the instant. |
| `PermissionService` | `platform/permission_service.dart` | Over `flutter_local_notifications`, not `permission_handler` — see *Deviations*. Checks the **channel**, not just the app-level flag. |
| `WatchedReconcileService` | `application/watched_reconcile_service.dart` | The one idempotent entry point. Reads the clock **once** and passes it down. |
| Tap screen | `presentation/tap_screen.dart` | |
| Debug harness | `presentation/debug_harness.dart` | Debug builds only. |
| Copy | `copy/{notification,tap}_copy.dart` | A leaf library both Presentation and Platform may reach without depending on each other. |

### Three notification channels, not one

A channel is the unit Android gives the user for switching us off, so this is a correctness decision.

ADR-0004 already argues that notifying about lost access *daily* would land "in the same channel as
the real *No check-in from Mum yesterday*", and that **training a family to swipe that channel cannot
be undone**. The decaying cadence fixed the frequency; **separate channels fix the collision**. A
watcher who mutes *App problems* still gets told when their relative misses a day. Recorded in
`screens.md`.

### The store and the platform are separate answers, on purpose

`LocalStore.pendingReminders()` is what the reconciler diffs against; `NotificationService.pending()`
is what the platform actually holds. The debug harness compares them, and **the divergence is the
finding** — on a handset that has silently dropped scheduled alarms, the store will insist everything
is armed and only the platform will disagree. That is the whole question Phase 2 exists to answer,
so it is a first-class control rather than a debugging afterthought.

The store is written **after** the platform calls return. A crash in between leaves the store
believing *less* is armed than really is, which the next reconcile repairs by scheduling over the
same ids. The opposite order leaves a reminder that never fires and nothing to notice it.

### The purity guard was widened, as the brief required

It now covers **any path containing `policy` or `reconcile`, at any layer**, applying the clock bans
outside `lib/domain/`. The rule was never "the domain layer is special" — it is *the clock is a
parameter to anything that decides*, and the layer boundary was only ever a proxy for it. Today that
catches `lib/application/watched_reconcile_service.dart`, which is named for the purpose.

Two guards against the guard being vacuous: it asserts it matched some files at all, **and** that at
least one lies outside `lib/domain/`. It was verified to fail closed by injecting `DateTime.now()`
into the service and watching it go red.

---

## Review, and what it changed

Four reviewers ran to completion — `architecture-reviewer`, `testing-reviewer`, `uiux-reviewer` and
`security-reviewer`. **`infrastructure-reviewer` did not report**: it was launched and stopped
before producing findings, so **the Android build changes below are unreviewed** and should be the
first thing looked at when the phase is picked up again.

**Between them the four found twenty-three defects. All are fixed.** Two were introduced by fixes
made earlier in this same phase, which is the honest summary: the Stack that fixed the tap target
*moving* introduced it being *overlapped*, and the widened purity guard covered files by name in a
way that would have left Phase 3's alarm callback unguarded.

The tests grew from 444 to **517** as a result.

### The one that would have cost the most

**`upsertLink` silently destroyed the watcher cache.** `INSERT OR REPLACE` resolves a primary-key
conflict by *deleting* the row, and `watcher_cache` and `warnings_shown` both declare
`ON DELETE CASCADE` with foreign keys enabled. So re-writing a link — which Phase 4 does on every
reconcile that refreshes links from Firestore, and which a revocation does today — took with it that
link's standing warnings, `lastConfirmedDay`, `lastReconcileAt`, and the whole access-lost triple.

That is this file's own header warning ("an installed app that loses its `warningsShownFor` … every
standing warning fires again") reached by a route it did not anticipate. It would also have reset
ADR-0001's staleness bound on every link refresh — a cached away silencing a watcher indefinitely —
and reset ADR-0004's cadence anchor so the access-lost reminder never advanced past day 0.

Invisible in Phase 2 because nothing writes a watcher cache yet, which is exactly why it was worth
closing now. Fixed with a real `ON CONFLICT … DO UPDATE`, and the regression test was **verified to
fail against the old implementation** before being kept — the existing test *"a revocation overwrites
rather than duplicating"* passed happily while all of it was destroyed.

### Three tests that could not fail

- **The cancel-before-schedule ordering** was asserted against a fake scheduler that produced the
  ordering itself. The production `NotificationAlarmScheduler.apply` had no test at all — reversing
  its two loops kept every test green, and the symptom on a device is *nothing happening*. Now
  asserted on the real class in `test/platform/alarm_scheduler_test.dart`.
- **`AlarmIds` had no tests.** Dropping `linkId` from `warning(linkId, day)` left all 444 tests
  green — and a correction for Mum would then have replaced a **true** standing warning about
  Granddad on the same day, which is the worst class of bug this project names. This is
  `docs/testing/strategy.md`'s "notification identity across links", asserted only obliquely in the
  domain and nowhere in the layer that derives the id.
- **The font-scale test asserted `takeException()` is null**, which a `Stack` with `Positioned`
  children can never produce. It was a false negative, not a guard, and it was passing while the
  text was drawn on top of the tap target.

### The accessibility defect

**TalkBack could not activate the app's one action.** `Semantics` wrapping an `ExcludeSemantics`
strips the subtree's `SemanticsAction.tap`, leaving a node that announces itself as an enabled button
and then does nothing when double-tapped. A label-based test cannot see the difference; the test now
asserts `hasTapAction`.

Alongside it: the spoken label said *"Tap to tell your family you are OK"* while the line below it
could be saying nobody is set up — a claim the device cannot support, on the surface whose reader
cannot see the contradiction. It is now *"Tap to say you are OK today"*.

### Four more that mattered

- **The app never asked for `POST_NOTIFICATIONS`.** On API 33+ it is denied by default, so first run
  on the target device would have shown a permanent red banner about a permission never requested —
  and fired no reminder, which is this phase's own exit criterion. Now asked once on first run, and
  the banner carries an action instead of a dead end.
- **A failed tap replaced the whole screen.** `AsyncValue.guard` put the provider into `AsyncError`,
  so she taps, the screen she uses every morning disappears, and the message claims the phone could
  not get ready — when in fact it was ready and the check-in did not save. Tap failures are now local
  state beneath a target that stays enabled.
- **The day never rolled over while the app was open.** A phone left on the charger across midnight
  kept showing *"You already tapped today, at 09:14"* on a day she had not tapped. She reads it,
  believes she is done, and the watcher is warned in the morning — the confirmation line causing the
  exact harm it exists to prevent. There is now a midnight timer, computed from the injected clock.
- **`areNotificationsEnabled()` is app-level only**, so a user switching off *just* the reminders
  channel left `canPost()` true and the domain consuming every reminder as delivered. That is
  Decision 1's own defect, left open on the channel axis. Now checks the channel's importance too.

### Security

Secrets clean, verified independently of the guard script. One real finding:

**`android:allowBackup` was unset, so the platform default copied the whole store to Drive and
restored it onto a new device — including `pending_alarms`.** Scheduled notifications do not survive
a restore, so the restored store insists a full 7-day window is armed while nothing is, every
reminder is skipped, and she is never nudged. `LocalStore` names that as the one direction that must
never occur; Auto Backup manufactured it for free. Now `false`.

Also fixed: the release build read the debug clock offset from disk (the *writer* was compiled out,
the *reader* was not); `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` was declared with no code behind it and
is deferred to Phase 7 with the panel that uses it; and the debug harness was gated on `kReleaseMode`
rather than `kDebugMode`, which shipped it in profile builds — the one build variant that also
carries `INTERNET`.

The security reviewer's verdict on M4 — the silent-inertness exposure — is that it is **mitigated in
part and the remainder is a properly recorded owner acceptance, not an open finding**. The empty-state
line breaks the silence and is true in the post-revocation state; what remains is timeliness and
salience, which is the part the owner rejected in terms.

One forward requirement recorded rather than fixed: `LocalStore` has no owner column, so from Phase 4
sign-out and account switch must call `wipe()`, or a second account inherits the first's check-ins and
is told it has already tapped.

### The purity guard, second attempt

Widening it by path substring (`policy` or `reconcile`) covers files **by name**. A Phase 3 alarm
callback called `warning_alarm_handler.dart` would read the clock in a bare isolate — the exact place
the rule exists for — while the guard reported itself healthy. It is now an **allowlist**: every file
under `lib/` is scanned, and exemptions are named **per file and per banned key**, each asserted to
still be needed.

That change immediately earned itself: it caught the midnight `Timer` added an hour earlier. The
exemption for it names the key rather than the file, so a `DateTime.now()` in the same file would
still fail.

A second guard came with it — a named list of files that must be **bare-isolate safe**, checked for
Flutter, Riverpod and `flutter_timezone` imports. Nothing otherwise stopped the reconcile service
importing `package:flutter` tomorrow and throwing in the isolate that cannot report anything.

### Not acted on, deliberately

- **`AppServices` is reachable as a service locator** from any widget. §14 sanctions the debug
  harness reaching Data and Platform directly, and nothing else does today. Narrowing it to a
  separate `debugServicesProvider` is worth doing when a second screen exists to be tempted.
- **`LocalStore` is never tested across two connections to one file**, which is the actual §4
  cross-isolate contract; every test uses `inMemoryDatabasePath`. Not load-bearing until Phase 3
  lands the alarm isolate — reminders are display-only and run no Dart — but it becomes so then.
- **`WatchedState.away` is hard-wired null**, so `TapCopy.away` is unreachable. The `away` parameter
  is correctly threaded through the domain per the from-the-first-line rule; only the UI is deferred.

---

## The layout defect the tests caught

The Tap screen was written as a `Column` with the target centred in the middle and the text below.
That makes the target's position depend on how tall the text is — so it shifted upward the moment
*"You already tapped today"* appeared, and again when a third watcher was added.

`docs/ui-ux/guidelines.md` is explicit that the target "does not move — muscle memory is the feature;
a layout that reflows is a bug", and a column breaks that **every day, at the moment of the tap**.
The widget test *"does not move between the two states"* caught it; the layout is now a `Stack`
positioning the target against the whole body, and that test is the regression guard.

Worth recording because it is the shape of defect this project keeps finding: the rule was known,
written down, and quietly violated by the obvious implementation.

---

## Deviations from the design, recorded rather than made quietly

**`permission_handler` is not used, and §15 names it.** `permission_handler_android` 14.0.0 does not
compile below API 37 — it references `Manifest.permission.ACCESS_LOCAL_NETWORK` and
`Build.VERSION_CODES.CINNAMON_BUN`. The local SDK has that platform installed as `android-37.0`,
while Gradle resolves the declaration to the exact hash string `android-37`, which does not exist;
pinning `compileSdk` down merely moves the failure into the plugin's own source.

Against that: of §13's four permission items, **three are answered natively by
`flutter_local_notifications`**, which this app needs anyway — and the notification one is answered
*better*. `areNotificationsEnabled()` asks the notification manager "will this appear", which is true
of a switched-off channel or a blocked app, neither of which revokes `POST_NOTIFICATIONS`. That is
the question the domain actually needs answered before consuming a reminder against it.

The only item it cannot answer is the battery-optimisation exemption, which is a health-panel row and
therefore **Phase 7**. The dependency buys one Phase 7 row and costs the Phase 2 build. It comes back
when the panel needs it, against whatever version compiles then.

**`kotlin.incremental=false`.** Kotlin's incremental compiler cannot close its own caches when
building `flutter_timezone` with this Gradle/Kotlin combination. It is **not** staleness — it
reproduced from a deleted `build/` with every daemon stopped, so neither `flutter clean` nor
`gradlew --stop` helps. Turning incremental compilation off compiles those modules whole, which on a
project with one app module and a handful of small plugins is a rounding error.

**Core library desugaring enabled.** Required by `flutter_local_notifications`, which uses
`java.time`. minSdk is 24 — deliberately low, because the device matrix notes the watched person's
phone is likely to be old — and `java.time` only arrives natively at API 26, so exactly those devices
need it to schedule a reminder at all.

---

## ADR-0002's assumption, re-verified with real plugins present

Phase 1 confirmed `package:timezone` needs no plugin registrant by observing that
`GeneratedPluginRegistrant.java` contained **zero** registrations. That was true but weak evidence:
there were no plugins at all.

Phase 2 added three. The registrant now contains exactly:

```
com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin
net.wolverinebeach.flutter_timezone.FlutterTimezonePlugin
com.tekartik.sqflite.SqflitePlugin
```

`timezone` is **not** among them, in a build that demonstrably registers plugins when they exist.
That is ADR-0002's claim tested against the case that could have falsified it.

---

## Device testing — NOT DONE

**No handset was attached during this phase.** `flutter devices` and `adb devices -l` both reported
nothing but the Windows and Edge targets, so none of PLAN.md's four exit criteria has been observed
on hardware.

| Device | Android | Skin | Power settings | Result |
|---|---|---|---|---|
| POCO F3 (`M2012K11AG`) | 13 / API 33 | HyperOS 1.0 | — | **NOT RUN — device not connected** |

`docs/testing/device-matrix.md` says a checklist that only records passes is not evidence. A
checklist that records nothing is less than that, so this is stated as the outstanding work rather
than softened.

**Outstanding, and the whole point of the phase:**

- [ ] Reminders fire at 12:00, 18:00, 21:00 local
- [ ] A tap cancels the remaining reminders for that day
- [ ] Alarms survive a reboot
- [ ] The window re-arms for following days **without the app being opened**
- [ ] The tap target is disabled for the rest of the day and re-enables at local midnight
- [ ] Notification permission denial is detected and explained
- [ ] The debug harness works on-device

**Stock power settings first**, then repeat with Autostart and battery optimisation relaxed. The
difference between the two passes is the finding: it decides whether onboarding must walk a family
through Autostart, or whether §9's scheduled-function escape hatch has to be un-deferred.

Setup reminder: File transfer (MTP) mode, USB debugging, and Xiaomi additionally needs
"Install via USB".

### One exit criterion deserves a note before it is tested

*"The window re-arms without opening the app"* has no logic-bearing alarm behind it on this side, by
design. The mechanism is the **7-day rolling window**: reconcile arms seven days ahead, so reminders
keep firing for a week without the app running, and the watched person opens the app daily to tap,
which re-arms it. §10's claim that the watched side can stay display-only rests on that, and the
extension to `through + 7` during away is what covers the one case where she genuinely does not open
it for a week.

So the device check is *do days 2–7 fire with the app never opened*, not *does something re-arm at
midnight*. Nothing runs at midnight, deliberately.

---

## Verification

```
flutter analyze                                   No issues found!
flutter test                                      All tests passed!  (517 tests)
dart run tools/models/away_warning_model.dart     superseded: 4 failure(s)   decided: 0 failure(s)
flutter build apk --debug                         Built app-debug.apk
  └─ GeneratedPluginRegistrant.java               3 registrations, timezone absent (ADR-0002 holds)
tools/check-secrets-ignored.ps1                   OK - 19 paths ignored, 1 deliberately tracked
```

`.gitignore` gained `/android/build/` and `/android/.gradle/` — Gradle writes reports there even
though `android/build.gradle.kts` redirects the main build directory to `/build`. Found because
Phase 2 is the first phase to run a real Android build. The secrets guard was re-run after the
change, per the CLAUDE.md constraint.
