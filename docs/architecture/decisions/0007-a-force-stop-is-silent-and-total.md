# ADR-0007 — A force-stop is silent and total, and only opening the app repairs it

**Date:** 2026-08-19 · **Status:** Accepted
**Phase:** 3 (measured on hardware during the Phase 3 device pass)
**Affects:** [ARCHITECTURE.md](../ARCHITECTURE.md) §4, §9, §10, §13

## Context

**Measured on the POCO F3, Android 13 / API 33, HyperOS OS1.0, stock power settings, 2026-08-18.**

Force-stopping the app from Android's App info screen:

| | Before | After |
|---|---|---|
| `dumpsys alarm` entries for this app | 21 | **0** |
| Standing notifications in the shade | 4 | **0** |
| `pending_alarms` rows in `LocalStore` | 21 | **21** |
| `package … stopped=true` | no | **yes** |

Three things follow, and each is worse than the last.

**Every alarm is cancelled and the app is told nothing.** There is no broadcast, no callback, no
flag the app can read at the moment it happens. `LocalStore` goes on saying all 21 are armed,
because from the app's point of view nothing occurred.

**Standing notifications go too.** An unread warning — *"No check-in from Mum yesterday"* — is
removed from the shade, while `warningsShownFor` still records it as shown and
`accessLostNotifiedOn` still records the cadence day as served. The app believes the family was
told. Nobody was.

**A stopped app receives no broadcasts at all, including `BOOT_COMPLETED`.** So the plugin's
`RebootBroadcastReceiver`, which is what makes an ordinary restart harmless, does not run either.
The state survives a reboot. The app stays inert until a human opens it.

The two ordinary "close the app" gestures were checked and are **not** this: both the recents-list
swipe (horizontal on this device) and *Clear all* leave `stopped=false` and the alarms intact. They
are process kills, and the OS restarts the process for the next alarm. Only the explicit Force stop —
and the OEM battery managers that invoke it — produces this state.

This is §17's *silently wrong data* risk in its purest form: the app is confidently, permanently
wrong about the one thing it exists to do, and reports success throughout.

## Decision

**1. The app never tries to detect a force-stop. It repairs unconditionally instead.**

There is nothing to detect. Rather than look for evidence, every `reconcile()` **re-asserts the whole
desired set** — `alarms.apply` takes `desired`, not a diff against `LocalStore`. Arming is idempotent
by id, so re-asserting costs a handful of binder calls and is correct whatever the platform actually
holds. A diff computed against the store re-arms nothing after a force-stop, which is exactly the
measured failure: 21 armed, force-stop, 0 armed, reopen, still 0.

**2. `LocalStore` is the app's belief, never evidence about the platform.**

Stated as a repo constraint and repeated here because it is the trap this ADR exists for. Any future
optimisation that skips work because the store says it is already done re-opens this defect. The
store's alarm rows exist to compute what to *cancel*, not to decide what to *arm*.

**3. Opening the app repairs both sides — by two different mechanisms, on launch and on resume.**

Home is the Tap screen, so the **watched** side is repaired by `TapScreen`'s own lifecycle observer,
which stays mounted underneath the pushed watcher list and so fires on every resume. The **watcher**
side has no such screen in the common case, and had to be reconciled explicitly or a watcher who
opened the app was still deaf: `main.dart`'s `_reconcileWatcherSide`, called from the post-frame
callback on launch and from `didChangeAppLifecycleState` on resume.

Naming one function for both was wrong and briefly written that way here. They are two mechanisms
with two lifetimes, and the watcher one defers when the list is showing precisely because the list
has an observer of its own.

**4. The residue is surfaced, not fixed.**

The alarms come back. The erased notifications and the false "already told them" records do not, and
nothing in the app can distinguish them from genuinely-delivered ones. Two consequences are accepted
deliberately:

- A warning that was posted and erased is **not** re-posted, because `warningsShownFor` says it was
  shown. Re-posting on that basis would mean re-warning a family every time the record looked
  suspicious, which is the false-claim failure this app rates worst.
- Every row carries *"This phone last checked …"*, which is the one surface that distinguishes
  *working* from *stopped* before §13's health panel lands in Phase 7. On a force-stopped watcher it
  stops advancing, and that is the visible symptom.

## Consequences

**Accepted, and named as a product limit.** A watcher whose phone force-stops the app is not warned
until they next open it. §9's scheduled server-side function is the only real answer — it does not
depend on the watcher's device running anything — and it stays deferred. **This ADR is the record of
what deferring it costs.** The data model already supports un-deferring it with no migration.

**This is the strongest argument in the project for that function**, stronger than the OEM alarm
reliability concern §9 was originally written against, because a force-stop is not a probabilistic
degradation: it is total, permanent until a human intervenes, and invisible from both ends.

**Onboarding owes a step in Phase 5.** HyperOS restricts background work for a sideloaded app by
default, and its battery manager can force-stop. Walking a family through Autostart and battery
exemption is now a functional requirement, not a nicety.

**Not testable in the suite.** No desktop or emulator test can produce `stopped=true`. The
`re-arms the whole window, not the diff` case in `watcher_reconcile_service_test.dart` models the
shape — platform empty, store full — and the device matrix carries the real check.
