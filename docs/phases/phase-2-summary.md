# Phase 2 — Watched side · summary

**Date:** 2026-08-17 · **Status:** Complete. Reviewed, and **verified on real hardware with stock
power settings — every exit criterion passes.** · **Next:** the owner's review, then Phase 3

Phase 1 was a domain layer and a stock Flutter counter scaffold. Phase 2 built the four layers above
it and made the app real: `LocalStore`, `AlarmScheduler`, `NotificationService` and its channels, the
`Clock`, the Tap screen, and the debug harness. It also landed the **two decisions carried in from
the Phase 1 gate**, which are the parts most worth reading.

**530 tests**, up from 328. `flutter analyze` clean. `flutter build apk --debug` succeeds.

> **Amended 2026-08-17, at the start of Phase 3.** Watching the reminders arrive unattended — the one
> check this document originally listed as *not observed* — found a defect that invalidates part of
> what is written below: **`AlarmIds` derived every id from `Object.hash`, which is seeded randomly
> per process**, so no id survived an app launch. Fixed, guarded, and written up in
> *[The second defect the unattended run found](#the-second-defect-the-unattended-run-found--and-it-is-worse-than-the-first)*.
> Read that before trusting the alarm counts in the device table.

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

All five reviewers ran to completion. `infrastructure-reviewer` stopped without reporting on its
first launch and was re-run after the device pass, which turned out to be the right order — it had
the hardware results to review as well as the build.

**Between the five they found thirty-two defects. All are fixed.** Two were introduced by fixes
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

### Infrastructure — the build, reviewed last and worth the wait

It found the two most serious latent defects in the phase, both invisible to every test and to the
device pass.

**SQLite UPSERT does not exist on the devices this app targets.** The `ON CONFLICT … DO UPDATE`
written to fix the cascade defect above needs **SQLite 3.24**, which Android ships from **API 29**.
minSdk here is 24 — deliberately, because the device matrix says the watched person's phone is
likely to be old — so on API 24–28 it is a **parse error** and the app cannot write a link at all.

Every test passed because `sqflite_common_ffi` binds a modern desktop SQLite, and the only physical
device is API 33. This is the clearest example yet of the matrix's API-level axis being a real gap
rather than a formality, and it is a defect introduced *while fixing another defect* — the third
time that has happened across two phases. Replaced with an UPDATE-then-INSERT in one transaction,
which is portable to 24 and cascades nothing. A source-level guard now bans both `ON CONFLICT` and
`RETURNING`, since no runnable test on this machine can catch either.

**Exact alarms are refusable, and the refusal took the whole screen down.** §13 promises *"reminders
degrade to inexact"*; nothing implemented that. The plugin throws `exact_alarms_not_permitted`, the
exception propagated through `apply` and `reconcile()` into the provider's error channel, replacing
the screen with *"this phone could not get ready"* and skipping the store write. Unreachable on the
API 33 test device — `USE_EXACT_ALARM` makes the check unconditionally true there — but live on
API 31–32, and **the default everywhere if Play refuses `USE_EXACT_ALARM` at Phase 8**, since the
fallback permission is denied by default when targeting Android 14+. Now falls back per reminder to
`inexactAllowWhileIdle` and reports the degradation on `WatchedState` for §13's Phase 7 row.

**`allowBackup="false"` did not close the restore vector.** On Android 12+ it stops cloud backup but
not device-to-device transfer; that needs a `<device-transfer>` block. Added as
`res/xml/data_extraction_rules.xml`. The old `fullBackupContent="false"` was valid but inert and is
removed. Worth noting the limit: OEM tools (Mi Mover, MIUI Backup) copy app data outside this
mechanism entirely, so the whole-set re-assertion remains the only durable defence — an argument for
the app-layer fix rather than against it.

Also fixed: `/android/.kotlin/` was unignored and one `git add -A` from being committed; `VIBRATE`
was arriving merged-in from the notification plugin and undeclared, which is exactly the rule this
phase used to *remove* `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, so it is now declared with its reason.

**The three build workarounds were challenged and all three stand**, with one correction worth
recording: **`platforms;android-37` does not exist and never did.** From API 37 Google publishes
minor-versioned platforms only (`android-37.0`, `37.1`, `37.2-beta`), so "install the missing SDK
platform instead" was never an available option — dropping `permission_handler` was the only route.
`kotlin.incremental=false` is a stock Flutter 3.47 toolchain defect rather than a local artefact, so
it reproduces anywhere; the root cause is still unidentified and the flag hides it. Desugaring is
correct and does not raise minSdk.

And the reviewer's answer to the question this phase turned on: **there is no manifest-side fix for
the force-stop case.** The boot receiver cannot help — a stopped app receives no broadcasts at all.
WorkManager is cancelled by the same force-stop. A foreground service would work and costs a
permanent notification, which contradicts "the family are updated quietly". So the app-layer
re-assertion is correct *and complete for Phase 2* — **precisely because the watched person opens the
app daily to tap, which is the repair trigger.** Phase 3 does not have that: its alarm is
logic-bearing and belongs to a watcher who §13 argues never opens the app. That is now the first
thing in *What to watch out for next*.

### Not acted on, deliberately

- **`AppServices` is reachable as a service locator** from any widget. §14 sanctions the debug
  harness reaching Data and Platform directly, and nothing else does today. Narrowing it to a
  separate `debugServicesProvider` is worth doing when a second screen exists to be tempted.
- **`LocalStore` is never tested across two connections to one file**, which is the actual §4
  cross-isolate contract; every test uses `inMemoryDatabasePath`. Not load-bearing until Phase 3
  lands the alarm isolate — reminders are display-only and run no Dart — but it becomes so then.
- **`WatchedState.away` is hard-wired null**, so `TapCopy.away` is unreachable. The `away` parameter
  is correctly threaded through the domain per the from-the-first-line rule; only the UI is deferred.
- **`kotlin.incremental=false`'s root cause.** A stock-toolchain defect, unidentified. Narrower knobs
  (`kotlin.incremental.useClasspathSnapshot=false`, `kotlin.compiler.execution.strategy=in-process`)
  were suggested and not tried; the removal check belongs on the Phase 8 list, since KGP only moves
  when someone edits `settings.gradle.kts`.
- **An API 28 AVD run**, which is now the only way to exercise the SQLite floor. Owed before Phase 4,
  when `upsertLink` starts running on every reconcile rather than only from the harness.

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

## Device testing — DONE, on stock power settings

**POCO F3 · `M2012K11AG` · Android 13 (API 33) · Xiaomi HyperOS `OS1.0` (MIUI `V816.0.6.0.TKHEUXM`,
security patch 2024-03-01) · Europe/Madrid · 2026-08-17.**

**Power settings were stock, and that is evidence rather than an assumption.** Captured before the
app was launched for the first time: not on the battery-optimisation whitelist, standby bucket 50,
`POST_NOTIFICATIONS` `granted=false` (the API 33 default), fresh install with no prior data.

| # | Criterion | Result |
|---|---|---|
| 1 | Reminders exist at 12:00 / 18:00 / 21:00 local | **PASS** — 21 alarms registered with `AlarmManager` as `RTC_WAKEUP`, at exactly 12:00/18:00/21:00 Europe/Madrid across 7 consecutive days. Read from `dumpsys alarm`, not from the app's own belief. **But see the amendment**: they *fired* two/two/three, not one each, because the ids were not stable across launches. |
| 2 | A tap cancels the rest of the day | **PASS, narrowly** — 21 → 18, that day's three gone, the following six untouched. Measured inside **one process**, which is the only place it worked before the id fix; a reminder armed by an earlier launch was uncancellable. |
| 3 | Alarms survive a reboot | **PASS, with a caveat** — restored without the app being opened, but **~76 s after `sys.boot_completed`**. See below. |
| 4 | The window re-arms without opening the app | **PASS** — the boot receiver restored the full set with the app never launched, and correctly kept that day's already-tapped reminders cancelled. |
| 5 | Target disabled for the rest of the day, re-enables at local midnight | **PASS** — disabled immediately after the tap; enabled again after rolling the date forward with the harness. |
| 6 | Notification permission denial is detected and explained | **PASS** — with the permission denied and user-fixed, the banner appears with a working *"Turn reminders on"* action, in the reserved band, and the target does not move. |
| 7 | The debug harness works on-device | **PASS** — force date, show clock, run reconcile, fire each reminder, compare store against platform, seed/revoke watchers, dump store. |

Two things verified that are not on the checklist but are worth recording. **First run requests
`POST_NOTIFICATIONS`** — confirmed denied by default on this device, so without the request the app
would have been permanently inert and the banner would have blamed the user for a permission never
asked for. And the **notification copy is verbatim**: `channel=reminders`, importance 4,
`android.title="I Am Ok"`, `android.text="Remember to tap I'm OK today."`

### The defect the device pass found, which no test could

**A force-stop cancels every alarm, and `reconcile()` did not repair it.**

```
fresh launch + reconcile  →  21 armed
force-stop                →   0 armed
reopen + reconcile        →   0 armed        ← permanently inert
```

Android cancels all of an app's `AlarmManager` alarms when it is force-stopped, and nothing tells
the app. `LocalStore` still held all 21 as pending, so `desired.difference(currentlyScheduled)` was
**empty** and re-armed nothing. The app went silently and permanently inert — the one failure mode
this project cannot detect in itself, and precisely the direction
`LocalStore.replacePendingReminders` names as the one that must never occur.

**This is not an exotic state on this handset.** The device matrix already says *"Lock in recents |
Off | Swiping the app from recents kills it and its alarms."* Swiping from recents, "clear all", any
task killer, or Settings → Force stop all reach it, and an elderly user tidying her phone does
exactly that.

The fix is one line of intent: **`reconcile()` now asserts the whole desired set rather than the
difference.** Scheduling is idempotent by id — `zonedSchedule` on an existing id replaces it — so
re-asserting 21 alarms costs a handful of local binder calls and makes the operation self-healing
whatever the platform's true state. Cancellation still uses the diff, because a reminder that should
no longer exist cannot be removed by re-asserting the ones that should.

The underlying rule, now written into `AlarmScheduler`: **the store records what we asked for. It is
never evidence of what the platform holds, and only one of those may be trusted.**

Re-verified on the same device after the fix:

```
fresh launch + reconcile  →  21 armed
force-stop                →   0 armed
reopen + reconcile        →  21 armed        ← repaired
```

It is also the answer to the security review's `allowBackup` finding, which is the same shape
arriving by restore rather than by force-stop.

**A correction to how that was first written up.** The harness's compare control reported
`store says 21 / platform has 24 / DIVERGED`, and this summary originally credited it with surfacing
the defect. The infrastructure review showed the label was wrong: `pendingNotificationRequests()`
reads the notification plugin's own `SharedPreferences`, **not `AlarmManager`**, and no public
Android API can enumerate an app's pending alarms. So that control compares `LocalStore` against a
*second app-local record of the same intent* — genuinely useful, and a different question from "what
does the OS hold". SharedPreferences survive a force-stop, so it would have reported 21 while nothing
was armed.

What actually surfaced the defect was `dumpsys alarm`, which is the only ground truth. The control is
renamed *"Compare store against plugin record"*, `armedOnPlatform()` is now
`armedAccordingToPlugin()`, and the comment that claimed otherwise is corrected — it was the kind of
false confidence Phase 3 would have inherited.

### Boot recovery is delayed, not free

`ScheduledNotificationBootReceiver` restored the alarms with the app never opened — but **76 seconds
after `sys.boot_completed`**, not immediately. A first measurement at 60 s read zero and looked like
a hard failure. It was not.

Nothing in this design depends on sub-minute boot recovery — the earliest reminder is at 12:00 — so
this costs nothing today. It is recorded because it is the kind of number that quietly becomes
load-bearing later, and because **a check made too early reads as a failure**. Anyone re-running
this should poll for several minutes before concluding anything.

**Criteria 3 and 4 do not compose with the force-stop finding, and this table can be misread as
saying they do.** A force-stopped app is in the stopped state and receives **no broadcasts at all,
including `BOOT_COMPLETED`**, until a human launches it — and that state survives a reboot. Both
reboot results were measured on an app that had *not* been force-stopped; force-stop then reboot
still leaves zero alarms until the app is opened. The boot receiver is not a repair path for the
force-stop case, and only the daily tap is.

### Found and not fixed

**The harness's date picker opens on the UTC day, not the local day.** At 00:17 CEST it offered
16 August while the device said the 17th, because `initialDate` is built from `clock.now()`, which
is UTC by design. Debug-only and cosmetic, but it is the same "two zones on one screen" mistake the
UI review found in the tap-time rendering, so it is named rather than quietly left.

### The second defect the unattended run found — and it is worse than the first

**Observed 2026-08-17, watching the reminders arrive at their natural times.** This is the check the
first write-up listed as *not observed* and called "the obvious next check". It was, and it found the
most serious defect in the project so far.

| Slot | Notifications posted |
|---|---|
| 12:00 | **two** |
| 18:00 | **two** |
| 21:00 | **three** |

Not one each. And the extras were **identical copies of the same line** — two *"Remember to tap I'm
OK today."* at 12:00 — which is not accumulation in the shade, because the design's own accumulation
would have produced one of each *different* line.

**`Object.hash` is seeded randomly per process, and `AlarmIds` used it.** The same expression
evaluated in three separate VMs:

```
run 1   reminder(2026-08-17, midday) =  69007203
run 2   reminder(2026-08-17, midday) = 231827400
run 3   reminder(2026-08-17, midday) = 198951794
```

`String.hashCode` is stable across runs; `Object.hash` combines its arguments with a per-process seed
and is documented as *not* stable between runs. **An id that changes is not an id**, and every id in
this app was derived that way.

What that actually cost:

- **Every launch armed the whole rolling window under fresh ids**, leaving the previous launch's
  alarms armed and unreachable. `cancelReminder` computes the id in the current process, so nothing
  could ever cancel them. They accumulated once per launch, and survived reboot because the plugin
  re-arms from its own `SharedPreferences`.
- **A tap could not fully cancel the day.** It cancelled this process's ids; every earlier process's
  reminder still fired at her. Criterion 2 passed only because the tap and the count happened inside
  one process.
- **The harness's `store says 21 / platform has 24 / DIVERGED` reading is consistent with this** —
  three orphans from an earlier launch — rather than with the benign explanation the first write-up
  reached for. Both records are app-local, but the *divergence* had a cause and it was this.
- **Worst, and the reason Phase 3 stopped to fix it before writing anything:** a correction
  *replaces a warning by id*. With an unstable id it posts a **second** notification instead, leaving
  *"No check-in from Mum yesterday"* standing directly above *"Correction: Mum did check in
  yesterday"*. §10's correction path is the highest-value behaviour in this app and **it could not
  have worked**. ADR-0004's access-lost cadence relies on the same replacement and would have stacked
  a fresh notice at every milestone rather than replacing the standing one.

**Fixed** by writing the hash out by hand: FNV-1a, 32-bit, over the UTF-8 bytes of a key whose parts
are joined with an ASCII unit separator that cannot occur in any component. Not `String.hashCode`
either — it is stable today, but nothing guarantees it across SDK versions, and an id that moves when
Dart is upgraded orphans every alarm on every installed phone at once.

**Why 524 tests could not see it.** Every assertion in `alarm_ids_test.dart` compared two calls made
inside *one* process, and a seeded hash is perfectly self-consistent there — including the test named
*"the same link and day give the same id"*, which is the exact property that was broken. A
single-process suite can only assert cross-process stability by pinning **known values**, so the
guard is now six golden constants plus an independent FNV-1a oracle anchored to the published test
vectors. Both were **verified to fail against the old implementation** before being kept: reverting
`_hash` to `Object.hash` turns all three golden tests and the oracle red while every pre-existing
test in the file stays green.

This is the same shape as the SQLite floor: a real property that the test harness is structurally
incapable of observing. It is the **fourth** time in three phases that the thing no test could reach
was the thing that mattered.

**One consequence for the device.** The orphaned alarms from every previous launch are still
registered with `AlarmManager` on the POCO and the app can never cancel them. **Uninstall and
reinstall before the Phase 3 device run**, or every measurement inherits them. No migration code was
added: the app has never been released, so there is no installed base to repair. A released app would
have owed a one-time `cancelAll()` on first launch after the fix.

### A third defect, found while verifying the second — a fresh install strands an alarm

**Measured on the POCO F3, 2026-08-17 ~21:56 CEST, on a clean uninstall/reinstall of the fixed
build. Reproduced on a second fresh install.**

| | |
|---|---|
| `settings.device_timezone` | `Europe/Madrid` |
| `pending_alarms` rows | **18**, every one `Europe/Madrid` |
| Alarms actually registered | **19** |
| The extra | `2026-08-17 23:00 CEST` = **21:00 UTC**, tagged `ScheduledNotificationReceiver` |

The store has no row for it, so **no future reconcile can ever cancel it**: `toCancel` is
`currentlyScheduled − desired`, and that day has already left the desired window.

**Why it happens.** On a fresh install `LocalStore.deviceTimezone()` is null, so the first
`reconcile()` takes `_deviceZone()`'s documented UTC fallback and arms the window at **UTC** wall
times. The UI then resolves the zone, stores `Europe/Madrid`, and reconciles again. For days 18–23
that is harmless and in fact by design — the id is `hash(day, slot)` and deliberately excludes the
zone, so the Madrid schedule *replaces* the UTC one, which is exactly `alarm_ids_test.dart`'s *"a
MOVED reminder keeps its id"*. But `(2026-08-17, night)` is wanted **only** in UTC: 21:00 UTC was
still an hour away while 21:00 CEST had already passed. So the Madrid reconcile does not want it, and
it is left stranded.

It escaped `toCancel` because the two reconciles **overlapped** — the second computed its diff
against a store snapshot that did not yet hold the first's `replacePendingReminders` write.
`build()` and the resume-triggered `refresh()` both call `reconcile()`, and on a cold start they land
within milliseconds of each other. *The orphan is measured and reproducible; that interleaving is the
reading most consistent with the evidence rather than something directly observed.*

**It is not a narrow window.** The orphan appears whenever a slot is already past in the device zone
but still ahead in UTC — for Europe/Madrid at UTC+2, that is the two hours after each of 12:00,
18:00 and 21:00 local. Roughly six hours a day, on the first launch after any install.

**Severity is low on this side and is the point on the next one.** §10 rates a spurious reminder as
costing nothing, and that holds: the watched person gets one extra nudge, with the correct wording,
on install day. What matters is the shape. This is an alarm **the app can never cancel** — the exact
direction `LocalStore.replacePendingReminders` names as the one that must never occur — and the
force-stop fix does not repair it, because re-asserting the whole desired set cannot remove something
that is no longer in the desired set. **Phase 3 puts a logic-bearing warning alarm through the same
code path, and there §10 rates a false fire as costing "everything".**

**Deliberately not fixed here.** Serialising `reconcile()` is a real decision rather than a patch:
Phase 3 adds an alarm isolate and Phase 4 an FCM isolate, both calling the same entry point, so the
question is cross-**isolate** exclusion and not merely an in-process mutex — and §4 is explicit that
the three isolates share no memory. Settling that belongs with the Phase 3 alarm design. Recorded
here so it is not rediscovered from the symptom.

### Not observed

- **The window draining past day 7 with the app never opened.** By design it would: the depth is
  seven days and the watched person opens the app daily to tap. §10's away extension to `through + 7`
  is what covers the one case where she genuinely does not.
- **The relaxed-settings pass.** `docs/testing/device-matrix.md` asks for stock first, then a repeat
  with Autostart and battery optimisation relaxed, with the *difference* being the finding. Stock
  passed every criterion, so there is nothing yet for a second pass to explain — it becomes
  worthwhile if Phase 3's logic-bearing alarm behaves differently.

**The headline result: with stock HyperOS power settings, on the handset the device matrix calls the
harshest mainstream case, every Phase 2 exit criterion passes.** That is the OEM risk this phase was
scheduled second to retire, and it is substantially retired for display-only alarms. Phase 3's
`android_alarm_manager_plus` isolate is a different mechanism and does not inherit this result.

**And the headline correction: OEM power management was never the thing that was broken here.** The
unattended run found a defect in this app's own code that the OEM pass had no way to surface, because
every measurement in the table above was taken inside a single app process. The platform did exactly
what it was asked; it was asked for the wrong alarms. Worth keeping in view for Phase 3, where the
temptation to attribute a bad result to HyperOS will be strongest.

---

## What to watch out for next

**PHASE 3 DOES NOT INHERIT THE FORCE-STOP REPAIR, and this is the most important line in this
document.** Phase 2's whole-desired-set re-assertion works because the watched person opens the app
daily to tap — that *is* the repair trigger. Phase 3's alarm is logic-bearing, uses
`android_alarm_manager_plus`, and belongs to a watcher who §13 argues never opens the app. A
force-stop there is silent, self-perpetuating, and has no user action to recover it: the alarms are
gone, the boot receiver cannot help because a stopped app receives no broadcasts at all, and nobody
opens the app to notice. The watcher goes permanently deaf and the family are told nothing.

**Decide that before writing the watcher alarm, not after.** It is the reason this phase's result
"substantially retires the OEM risk" for display-only alarms and does *not* retire it for Phase 3.

**Nothing in the app can tell you what the OS actually holds.** `pendingNotificationRequests()` is
the plugin's own SharedPreferences; there is no public API to enumerate pending alarms. Ground truth
is `adb shell dumpsys alarm`, written to a file and pulled — piping it truncates, and that produced a
false OEM finding once already. The recipe is in `docs/testing/device-matrix.md`.

**The API-level axis is a real gap, not a formality.** Phase 2 shipped SQL that cannot parse below
API 29 and it passed 500+ tests, because the test binding uses desktop SQLite and the only handset is
API 33. Anything touching SQL, `java.time`, or a permission model needs the API 28 AVD before it is
believed. An API 28 run is owed before Phase 4.

**`reconcile()` is not safe to run concurrently, and Phase 3 doubles the number of callers.** Two
overlapping runs each compute `toCancel` against their own stale snapshot, and the loser's alarms are
stranded on the platform with no store row — unreachable, because re-asserting the desired set cannot
cancel something outside it. Measured on a fresh install, where the UTC-fallback reconcile and the
zone-corrected one raced. **Decide the exclusion mechanism before the alarm isolate is written**: it
has to hold across isolates, which rules out an in-process lock and points at the store itself.

**A platform id must be a pure function of its inputs, and nothing else.** `Object.hash` is seeded
per process; `String.hashCode` is stable today but unguaranteed across SDK versions. Anything that
crosses a process boundary — a notification id, an alarm request code, a document id, a cache key —
is hashed by code this repo owns and pins with known values. `AlarmIds` is the worked example, and
the six golden constants are the guard. The same question is worth asking of anything Phase 4 keys
on.

**Watch a behaviour actually happen before believing a checklist about it.** Everything in the device
table was measured by asking the OS what was *registered*, which was correct and insufficient: the
alarms were registered perfectly and fired wrong. The unattended run cost a day of waiting and found
the worst defect in the project. Phase 3's device criteria need at least one genuinely unattended
observation for the same reason.

**A defect fixed is a defect to re-review.** Three times across two phases, a fix introduced the next
defect: the away clamp, the Stack that stopped the target moving and let text overlap it, and the
UPSERT that fixed a cascade and broke Android 8. The reviewers caught all three; none was caught by
the person writing the fix.

**`upsertLink` is only reachable from the debug harness today.** From Phase 4 it runs on every
reconcile that refreshes links from Firestore, which is when both its cascade behaviour and its SQL
floor start to matter in production.

**Phase 3's `redundant` delivery state now has a real producer.** `PermissionService.delivery(
appInForeground:)` exists and `NotificationDelivery.from` decides; the watcher reconcile has to pass
the app's actual foreground state rather than defaulting it.

---

## Verification

```
flutter analyze                                   No issues found!
flutter test                                      All tests passed!  (530 tests)
dart run tools/models/away_warning_model.dart     superseded: 4 failure(s)   decided: 0 failure(s)
flutter build apk --debug                         Built app-debug.apk
  └─ GeneratedPluginRegistrant.java               3 registrations, timezone absent (ADR-0002 holds)
tools/check-secrets-ignored.ps1                   OK - 19 paths ignored, 1 deliberately tracked
```

`.gitignore` gained `/android/build/` and `/android/.gradle/` — Gradle writes reports there even
though `android/build.gradle.kts` redirects the main build directory to `/build`. Found because
Phase 2 is the first phase to run a real Android build. The secrets guard was re-run after the
change, per the CLAUDE.md constraint.
