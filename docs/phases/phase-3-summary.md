# Phase 3 — Watcher side · summary

**Date:** 2026-08-17 · **Status:** Implementation complete; device pass recorded below · **Next:**
the reviewer agents, then the owner's review

Phase 3 built the edge around a decision that already existed. `WarningPolicy` and
`WatcherReconciler` were finished and exhaustively tested in Phase 1; what was missing was an
isolate to wake them, somewhere to persist what they concluded, the words to say it in, and a
surface to explain it on.

**692 tests**, up from 547. `flutter analyze` clean. `flutter build apk --debug` succeeds.

> **This phase is NOT signed off.** The five reviewers have now run and reported, and the prediction
> below held exactly: the author caught none of what they found. Two criticals — one found
> independently by three of them — plus roughly thirty further findings. Tiers 1 and 2 are fixed and
> committed; the outstanding tiers are listed at the end of this document.
>
> The record is worth keeping as written, because it is the fourth time in this project that a
> self-review has come out clean on code the reviewers then found real defects in:
>
> *"Phase 2's gate produced thirty-two defects across five reviewers, and three times in this
> project a fix has introduced the next defect, so the absence of a review here is a real gap rather
> than a formality. What follows is a self-review, which is exactly the thing this project's own
> record says does not work: 'the reviewers caught all three; the author caught none of them.'"*
>
> The worst of the two criticals was a getter that broke the rule stated in its own docstring, one
> line above the expression that broke it.

---

## The three decisions taken at the gate

### 1. `reconcile()` is serialised by a lease in the store

Taken *before* the alarm was written, and it turned out to be the right order — the mechanism was
needed by the second thing Phase 3 built. Recorded as
[ADR-0006](../architecture/decisions/0006-reconcile-is-serialised-on-disk.md); the reasoning and the
measurement that forced it are there rather than repeated here.

The part that matters for this phase: **reading state is never gated, only changing alarms is.** That
split is what makes the same lease safe on this side. The alarm isolate must always reach its
warn/don't-warn decision — silence is the one failure this app cannot detect in itself — so it may
skip the *scheduling*, never the *speaking*.

### 2. The refused notification opens the watcher list

*"Open the app to see what to do."* had nowhere to land: §13's health panel is Phase 7.
[ADR-0004](../architecture/decisions/0004-refused-is-not-unreachable.md) makes actionability the
whole reason that fourth message exists rather than being folded into the offline one, so a tap into
a screen with no remediation would have hollowed it out.

The watcher list now carries a lost-access row rendering the cause-specific remediation already
approved in `screens.md`. Rejected: opening the app with no routing (makes the sentence false);
pulling the panel forward (a screen nobody has designed); and cutting the sentence (removes the
action, which is what ADR-0004 rejected).

**Cold-start routing is the normal path here, not an edge case.** §13's argument for the panel is
that a low-usage watcher never opens the app — so at the moment they tap this notification, their app
is closed almost by definition. The payload is read with `getNotificationAppLaunchDetails()` in
`main()` before `runApp`, held in a `ValueNotifier` so a listener attaching later still sees it, and
navigated through a `GlobalKey` because nothing is mounted yet.

### 3. The harness dismisses its own test notifications

*"Fire ⟨slot⟩ reminder now"* posts under a sentinel epoch day so it cannot collide with a real armed
reminder — which also means no reconcile ever cancels it. A control now cancels exactly those three
ids and leaves the armed window alone. Small, and it earned itself immediately: on 2026-08-17 a
leftover test notification was a live candidate explanation for duplicate reminders and cost real
time to rule out.

---

## What was built

| Component | File | Notes |
|---|---|---|
| Alarm entry point | `application/warning_alarm_handler.dart` | `@pragma('vm:entry-point')`. Opens the store, builds its own plugin instances, reconciles **every** link, exits. |
| Watcher reconcile | `application/watcher_reconcile_service.dart` | The composition: read tier 1 → reconcile → execute → one write. Contains no branch that decides whether to speak. |
| Warning alarms | `platform/warning_alarm_scheduler.dart` | `android_alarm_manager_plus`. Exact, wakeup, allow-while-idle, reschedule-on-reboot. |
| The read seam | `data/check_in_reader.dart` | `CheckInReader` + Phase 3's `SimulatedCheckInReader`. Carries ADR-0004's Phase 4 mapping in its contract. |
| Warning ids | `data/local_store.dart` | `pendingWarnings` / `replacePendingWarnings`, scoped per link. |
| Copy | `copy/notification_copy.dart`, `copy/watcher_copy.dart` | Four warning bodies, every null variant, the correction, and the list. |
| Tap routing | `platform/notification_router.dart` | Live and cold-start paths. |
| Watcher list | `presentation/watcher_screen.dart` | One row per person. State, never history. |

### The alarm reconciles every link, not the one it was armed for

The alarm id encodes a link and a day, and the handler ignores both. §3: **nothing is transmitted as
a command** — a fire is a nudge to reconcile, carrying no authority. Acting only on the alarm's own
link would mean one dropped alarm leaves one watched person unreconciled, with nothing to notice it.

### The simulated backend lives in `LocalStore`

PLAN.md's Phase 3 is fake data, no Firebase, so the tier-1 read is stubbed. The stub reads its answer
**off disk** rather than from memory, for the same reason the clock offset does: the alarm isolate
shares no memory with the UI, and a simulator it could not see would leave the one isolate this phase
exists to test reading something else entirely.

It matters more than it sounds. Two of the four outcomes — *unreachable* and *refused* — are close to
impossible to produce on demand against a real backend, and they are exactly the two whose wording is
a correctness requirement rather than copy polish.

---

## The build, and what the plugin brought with it

`android_alarm_manager_plus` **compiles**, which was not a given —
`permission_handler_android` did not, and that shaped the whole of Phase 2's permission story.

**Its `AndroidManifest.xml` is a single empty `<manifest/>` tag**, so nothing is merged in for us.
The service and both receivers are declared by hand, with the class names read out of the plugin's
own sources rather than from memory. That is the opposite failure from Phase 2's, where `VIBRATE`
arrived *uninvited* from `flutter_local_notifications` and had to be declared after the fact — and
it is why the built APK was checked rather than the manifest source:

```
aapt2 dump permissions app-debug.apk
  POST_NOTIFICATIONS · RECEIVE_BOOT_COMPLETED · USE_EXACT_ALARM
  SCHEDULE_EXACT_ALARM (maxSdkVersion 32) · VIBRATE · WAKE_LOCK
  INTERNET  ← debug/profile only, added by the Flutter tool
```

Exactly what is declared, and nothing else. `WAKE_LOCK` is the one this phase adds: the isolate has
to stay awake long enough to reconcile and decide, and without it the CPU can sleep mid-decision —
which on this side means the warning silently never arrives.

**`GeneratedPluginRegistrant` now holds four plugins and `timezone` is still absent.** That is
ADR-0002's claim tested against another case that could have falsified it: Phase 1 observed zero
registrations (true but weak evidence), Phase 2 three, and Phase 3 four.

## The purity guard was wrong, and Phase 3 is what proved it

`bareIsolateSafe` banned `package:flutter/` outright, on the stated grounds that a background isolate
has *"no widget tree and no plugin registrant"*.

**The second half is false.** `android_alarm_manager_plus` starts its isolate on
`new FlutterEngine(context)`, and that constructor registers plugins automatically — it has to, since
the isolate reads `LocalStore` through `sqflite` and posts through `flutter_local_notifications`, both
method-channel plugins. Read out of the plugin's own sources, and confirmed on hardware below.

So `package:flutter/services.dart` — the method-channel layer, which `NotificationService` needs for
`PlatformException` — is legitimate there, and the blanket ban would have forced either a pointless
wrapper or a whole-file exemption that reopened the rule. The ban is now on the **widget layer by
name**, which is what it always meant. Verified to still fail closed by injecting
`package:flutter/material.dart` into the entry point.

This is the second guard in two phases that was passing while approximating its own rule.

---

## Tests

22 new tests on the composition, one per exit criterion and per trap the domain cannot see alone,
plus a copy suite.

**Everything asserts *which* message, never that something fired.** §10 rates a false claim to a
family as the worst bug this app can have, so "a notification appeared" is not evidence.

The ones worth naming:

- **The correction posts at the warning's id**, so it replaces rather than joins. Asserted as
  `['correct:mum_ana:2026-08-16']` — same link, same day, therefore same id.
- **Correcting Mum leaves Granddad's warning standing.** `docs/testing/strategy.md`'s mandatory case:
  both missed the same day, only one checks in late, and retracting a **true** warning about the
  other is the worst class of bug this project names.
- **A refusal goes to a different channel with different words**, and is recorded in
  `accessLostSince` rather than `warningsShownFor` — otherwise the list row reports a missed check-in
  that nothing supports.
- **Revocation withdraws without correcting**, and tears the alarm window down.
- **Nothing is consumed when the platform cannot post.** A muted phone must not settle a day in
  silence.
- **No combination of nulls renders the word "null"** or a double space, across every outcome × away
  × since × confirmed. This is the failure the never-reconciled variants exist for.
- **Both openings survive a one-line truncation** — the collapsed shade shows one line, and whatever
  survives has to already say which *kind* of claim this is.

### Three tests failed first, and all three were the test

Worth recording because one of them documents a real asymmetry that reads like a bug until it is
stated:

**Suppression is `lastConfirmedDay >= D`; a correction needs the exact day.** Suppression asks *has
she been seen since* — if the newest check-in is later than D, the question about D is moot and
warning about it raises a resolved past, which is the *state, not history* rule reaching the
notification. A correction makes a positive claim, so retracting Monday's warning because she tapped
Tuesday would assert something false about Monday. One rule decides whether to stay quiet; the other
decides whether to say something.

The other two: the window is six alarms rather than seven when the clock is exactly the warning time,
because an instant that has arrived is not scheduled into the past; and 22 August 2026 is a Saturday.

---

## Device testing

**POCO F3 · `M2012K11AG` · Android 13 (API 33) · Xiaomi HyperOS `OS1.0` · Europe/Madrid ·
2026-08-17, 23:27–23:40. Stock power settings, fresh install.**

The question this phase exists to answer is **not** whether the logic is right — the domain suite
answers that in milliseconds. It is whether Android, on the harshest mainstream OEM, will wake a bare
Dart isolate on a schedule. Phase 2 retired that risk for *display-only* alarms and explicitly did
not retire it here, because `android_alarm_manager_plus` is a different mechanism.

### The alarms are real

After seeding two watched people and running the watcher reconcile:

```
dumpsys alarm, by receiver
  com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver   18   ← watched reminders
  dev.fluttercommunity.plus.androidalarmmanager.AlarmBroadcastReceiver    12   ← watcher warnings

LocalStore pending_alarms, kind='warning'                                 12
```

Two links × six days, at 10:00 Europe/Madrid. Today's is absent because 10:00 had passed — an instant
that has arrived is not scheduled into the past. **The store and the platform agree**, which after
ADR-0006 is a property rather than a coincidence.

### The isolate wakes — measured, not inferred

A real alarm armed two minutes out, then the app sent to the background:

```
armed for       23:32:22
last_reconcile_at, both links, after:
                1787002342800  =  23:32:22
```

The timestamp is written by `WatcherCache.applyRead` inside the reconcile. It moving to exactly the
armed instant is direct evidence that **our Dart code ran**: the isolate started, opened `LocalStore`
through `sqflite`, attempted the read, decided, and wrote. It also settles the question the purity
guard forced earlier — plugins *are* registered in the background isolate, because the store write
could not have happened otherwise.

### The channel split, verified where it actually lives

```
NotificationChannel{mId='warnings',  mImportance=5}   ← max
NotificationChannel{mId='access',    mImportance=4}   ← high
NotificationChannel{mId='reminders', mImportance=4}
```

ADR-0004's structural half is a claim about **what the user can switch off**, so a test asserting the
constants proves nothing — the assertion has to be against the system's own record. A watcher who
mutes *App problems* still has *Missed check-ins* at max importance, which is the one message this
app exists to deliver.

### The isolate wakes with the process dead, too

The stronger case, and the watcher's actual situation at 10:00 — nothing of this app running at all:

```
armed for            23:36:58
process killed       pid gone
after the fire       pid 22348          ← the OS cold-started the app
                     last_reconcile_at  23:36:59
```

Android started a fresh process, ran the bare isolate, reconciled both links and wrote to disk with
no UI and no user. **That is the risk the Phase 3 brief said Phase 2 had not retired, and it is now
retired for the ordinary background case on this handset with stock power settings.**

### The force-stop exposure, measured for this mechanism

```
before force-stop    reminders 18   warnings 12
after force-stop     reminders  0   warnings  0
```

Confirmed: `android_alarm_manager_plus` alarms are cancelled by a force-stop exactly as
`flutter_local_notifications` ones are. The exposure the brief describes is real here, and nothing in
this phase changes that.

`am kill` — the ordinary low-memory kill — is **not** a force-stop and leaves alarms armed. That
distinction matters for anyone repeating these measurements.

### The defect only the device could find

**After a force-stop, opening the app repaired the watched side and left the watcher deaf.**

```
after force-stop, then opening the app
  before the fix    reminders 18   warnings 0
```

§3 says `reconcile()` is called on app open. On the watched side that was true, because the Tap
screen is home and its provider reconciles when it builds. On the watcher side it was **not**:
`watcherStateProvider` only builds when the watcher list is shown, so nothing reconciled until
somebody navigated there.

So the one repair path the whole Decision 1 mitigation rests on did not repair the half that matters.
The brief's argument was that a watcher never opens the app; this is the case where they **do** and it
still does not help — and nothing on any screen says so.

It is not a Phase 5 routing artefact either. Someone who is both watched and watcher lands on the Tap
screen **by design** (`screens.md`), so their watcher alarms would never be re-armed by opening the
app at all.

Fixed by reconciling both sides on app open, whatever screen is showing. That immediately exposed the
second half — the global lease meant the two sides took turns, so one was always left unarmed. Both
fixed, and re-measured:

```
after force-stop     reminders  0   warnings  0
after opening        reminders 18   warnings 12     ← both sides repaired
```

### A warning arriving unattended — the check that found Phase 2's worst defect

Run 2026-08-18 with the harness's near-future warning control, app closed via `am kill` (not a
force-stop, so the alarms survive):

```
app closed          pid ''
alarm due           09:11:00
after               pid 31768                     ← the OS started a fresh process
last_reconcile_at   09:11:02, both links
warnings_shown      warnOnline, both links
notifications       2 records, channel=warnings, importance 5
                    "No check-in from Mum yesterday."
                    "No check-in from Granddad yesterday."
```

**Two, not one and not three**, with the correct one of four messages, on the channel that must not be
trained away, posted by a bare isolate into a process that did not exist a second earlier. This is the
watcher-side equivalent of the check that caught the `Object.hash` defect, and it is the first time
this phase's whole path has been observed end-to-end rather than inferred from what was registered.

**A second result fell out of it.** The two notification ids — `678899615` and `1519566369` — are
byte-identical to those from an earlier run in a **different process**, across a `pm clear` and a
reinstall. That is `AlarmIds`' FNV-1a stability demonstrated on hardware rather than in a
single-process test, and it is what makes the correction path able to replace a warning at all.

### The cold-start tap, and two more findings from running it

Process killed, notification tapped from the shade:

```
pid before tap    ''            ← nothing of this app running
pid after tap     2817          ← cold start
screen            "People you're looking after", Mum's row highlighted
row               Access to Mum's check-ins
                  You will not be warned if Mum misses a day.
                  Nothing can be fixed on this phone. If it is still red
                  tomorrow, ask whoever set up the app.
                  This phone last checked Tuesday 09:19.
```

*"Open the app to see what to do."* now lands somewhere that says what to do, from the state this
notification is actually read in. The refusal also went to `channel=access` at importance 4 while the
two `channel=warnings` notices stayed standing at importance 5 — ADR-0004's structural split,
observed rather than asserted from constants.

**A force-stop erases the notifications too.** Not just the alarms:

```
before force-stop   4 notifications standing (2 warnings, 2 access)
after force-stop    0
```

So a family member who swipes the app away also deletes the unread warning telling them their
relative missed a day. That belongs in ADR-0007 — it makes the force-stop exposure meaningfully worse
than "future warnings stop", and it is not something the design had accounted for.

**And it does not un-record the delivery.** `accessLostNotifiedOn` still said "shown today", so the
notice could not be re-posted — the app believes a message was delivered that the OS has since
removed. Same family as the exposure above; recorded, not fixed.

### ADR-0004's changed-cause rule was not implemented

Found while producing a fresh notification for the tap test. ADR-0004 decision 5:

> a **changed cause** re-notifies *whatever the cadence says*: "sign in again" and "update the app"
> are different instructions, so the standing notification is the wrong one the moment the cause
> moves.

`WatcherReconciler` tested the within-day dedupe **first**, which swallowed exactly that case. A
watcher told at 09:00 to sign in again, whose fault becomes an App Check rejection at 09:05, kept the
sign-in instruction until the following day. Observed on the device: the cause moved to
`appCheckRejected` in the store and nothing was posted.

Not merely stale — **the wrong thing to do**, on the one message whose entire justification is that it
is actionable. Fixed by checking transition-or-changed-cause before the dedupe, with tests for both
directions.

### Reboot recovery for the warning alarm

The one §10 promises with `rescheduleOnReboot: true` and which nothing had ever exercised. Run
2026-08-18 with 35 alarms armed — 21 reminders and 14 warnings across two links:

```
sys.boot_completed        uptime  19s
alarms at uptime  39s      0
alarms at uptime  59s      0
alarms at uptime  79s      0
alarms at uptime 100s     35     ← full set restored

pre-reboot instants   35
post-reboot instants  35
identical sets        True
```

Not merely the same count — **the same instants**, exactly. The 10:00 entries come back ×2, one per
link, which is the warning alarm specifically rather than the reminders carrying the total.

**A check at 60 s would have read zero and looked like total failure.** Phase 2 recorded that trap for
the reminders (~76 s there) and it holds here; anyone repeating this must poll for several minutes
before concluding anything.

**Recovery happens without our code deciding anything, and that is worth knowing.** `last_reconcile_at`
was still 09:30:24 afterwards — pre-reboot — and the store already held 14 + 21 matching the platform.
So both boot receivers restore from **their own records** rather than from a reconcile: the alarms
that *were* armed, not the ones that *should* be. If the two had diverged before the reboot, the
reboot would faithfully restore the divergence, and only the next `reconcile()` would repair it. That
is the correct division of labour — but it means a reboot is not a repair.

### "Swiping from recents" is not a force-stop, and that changes ADR-0007's premise

The whole force-stop exposure has been argued from one line in the device matrix — that swiping the
app from recents "kills it and its alarms", making an ordinary thumb movement enough to leave a
watcher permanently deaf. Measured directly, with 35 alarms armed and 3 notifications standing:

| Action | Process | Alarms | Notifications | `stopped` flag |
|---|---|---|---|---|
| **Clear all** in recents | killed | **35** | **3** | **false** |
| `am force-stop` | killed | **0** | **0** | **true** |

**Clear-all is an ordinary process kill.** Alarms survive, notifications survive, the app is not in the
stopped state, and it goes on receiving broadcasts — and the isolate test independently proves
delivery from exactly that state, a dead process with alarms intact.

A force-stop is a materially different act: every alarm cancelled, **every standing notification
erased**, and `stopped=true`, after which the app receives nothing at all until someone launches it
by hand.

So the exposure is **narrower and more deliberate** than the brief assumed. It is not a thumb
movement; it is Settings → Force stop, or a third-party task killer that invokes it. That strengthens
"accept, prevent and surface" considerably — prevention now has to cover a deliberate act rather than
an everyday one — and it weakens the case for un-deferring §9, whose whole justification was how
routine this was believed to be.

**Both gestures are now measured.** The dismissal gesture on this handset is **horizontal**; a
vertical swipe scrolls the carousel, which is why the first attempts changed nothing — and why the
first reading of "nothing happened" proved nothing rather than proving safety. Re-run correctly, an
individual horizontal card swipe kills the process and leaves **35 alarms and 3 notifications intact
with `stopped=false`**, identical to clear-all. Neither gesture is a force-stop, and the caveat this
paragraph used to carry is closed.

### Deliberately not proven by this

**A notification did not appear on that fire, and that is correct.** A warning for `D` was already
standing, so `shouldNotify` was false — which is the idempotence this design requires, since every
entry point calls reconcile and boot recovery would otherwise be a duplicate-notification bug. The
fire is evidenced by the store, not by the shade.

## The fourth defect: a warning decided, recorded as delivered, and never shown

**Found by the unattended-arrival test on its first run**, which is the entire
argument for running it. Nothing else would have caught it: the suite was green, the alarm woke, the
store looked right, and no notification ever reached anyone.

`NotificationDelivery.redundant` means *no notification posted, but the day **is** consumed, because
the reader is looking at the screen that already shows this*. `AppServices` hard-coded
`appInForeground: true`, reasoning that the UI isolate only exists while the app is running. True,
and irrelevant — the question is not whether the app is running, it is whether the watcher **list**
is on screen rendering this person's state.

The app-open reconcile added earlier in this phase — so a force-stopped watcher repairs itself — ran
with that hard-coded `true` while the user sits on the **Tap screen**, which is home. Measured:

```
last_reconcile_at   09:01:02          ← the isolate woke and reconciled
warnings_shown      warnOnline, both links
notifications       0
```

The day was settled, the family untold, and every later reconcile correctly stayed silent because a
warning was already "standing". **This is exactly the failure `NotificationDelivery` was added to
prevent** — recording a warning as delivered when nothing delivered it — reintroduced through a
different door by the fix for the previous defect.

That is the **fourth** time in this project that a fix has introduced the next defect, and the first
one no reviewer caught, because no reviewer ran.

`appInForeground` is now a required named parameter, so the question cannot be skipped, and only the
list itself may answer yes. The app-open path calls the service directly rather than through
`watcherStateProvider`, because that provider *is* the list's state and answers yes by definition.

Re-measured after the fix — the same action that had silently consumed the day:

```
channel=warnings  importance=5   "No check-in from Mum yesterday."
channel=warnings  importance=5   "No check-in from Granddad yesterday."
```

Two, correct wording, correct channel, `bigText` set. **This is also the first end-to-end proof of
the notification path**: the right one of four messages, on the right channel, at the right ids.

### The harness had the same shape of flaw, one level up

Arming the near-future warning runs a real `reconcile()`, which also **decides and posts**. So the
alarm fired into a day already settled and correctly said nothing — indistinguishable, from the
outside, from the alarm not working. The control now resets the decision state after arming, leaving
the armed alarms alone, so the alarm is the first thing to decide that day.

Worth naming because it is the same trap in a different costume: a test whose setup performs the
behaviour it is supposed to observe proves only that the setup ran.

## The surface half, brought forward from Phase 7

"Accept, prevent and surface" was the leading answer to the force-stop exposure, and its third word
did not exist: §13's health panel is Phase 7. Choosing it today would have accepted a window where
the failure is both silent **and** unsurfaced.

So every watcher row now carries **"This phone last checked Tuesday 10:14."** — or *"has not been
able to check even once"* when no read has ever succeeded. It is on healthy rows too, and that is the
point: a force-stopped watcher goes deaf with every row still reading *"Everything OK"*, which is
true of the last thing this phone managed to read and says nothing about whether it has read anything
since. This one line is the only thing that distinguishes **working** from **stopped** before the
panel lands.

*"This phone last checked"*, never *"last updated"* — a fact about this device's own effort, not
about her and not about the data. It shares the moment formatter with the notification, so the row
and the message about the same instant cannot render it differently.

## Deviations, recorded rather than made quietly

**The correction carries no time at all** — *"Correction: Mum did check in yesterday."*

This was recorded here as a deviation: Phase 3's read has no per-check-in timestamp, so *"at 23:40"*
was stamped with the reconcile instant. The Phase 3 review rated that a false factual claim about a
person rather than an acceptable approximation, and it was right — on a phone that slept until
morning the reconcile instant is hours out and occasionally the wrong day, on the one message whose
entire purpose is to withdraw an untrue claim about her.

The clause is now omitted. `screens.md` carries both variants; Phase 4 carries `deviceTappedAt`
through the read and the time returns with something true behind it. The retraction was always
complete without it.

**Notification times are rendered 24-hour rather than following the device's setting.**
`docs/ui-ux/guidelines.md` asks for the device's own 12h/24h preference; reading it needs a
`BuildContext`, which a notification posted from a bare isolate does not have. The approved strings
are 24-hour and the owner's locale is 24-hour, so nothing is wrong today. It becomes wrong for the
first user whose phone is set to 12-hour.

**Both remaining device criteria have since been observed**, and the records are above: the
unattended warning at its natural `warningLocalTime`, and the cold-start tap on the *lost access*
notification. This paragraph listed them as outstanding after they had been driven, which is the
worse direction for a summary to be stale in — a checklist that under-reports its own evidence
invites the work being done twice, and one that contradicts its own body cannot be trusted in
either direction.

What remains genuinely unobserved is the **overnight Doze run**, which is a different criterion and
is still owed.

**The watcher list layout is deliberately plain.** `screens.md` marks the multi-person layout as
Phase 7 and undesigned; what is settled is the row *content*, which is what this renders.
