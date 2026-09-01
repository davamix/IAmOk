# I Am Ok — documentation index

A daily "I'm OK" signal from an elderly person living alone to the family who watch over them.
One tap a day. A quiet update when it happens, a loud warning when it doesn't.

**Android only. Flutter + Firebase.** Not a health monitor, not an emergency-help app — see the
non-goals in [HANDOVER.md](HANDOVER.md), which the whole design is built on top of.

| | |
|---|---|
| Next phase | **Phase 7 — UI/UX and the health panel.** Briefed: **[phases/phase-7-brief.md](phases/phase-7-brief.md)**, written 2026-09-01 at the end of Phase 6. Two of its three deliverables — the watcher list and cold-open state — are **already built**; the health panel does not exist at all, and §13's *clock skew* row has no implementation despite three documents describing one. Owner decisions open with the phase: where the panel lives and how an 80-year-old reaches it, what it says when everything is fine, and whether §12's away transition notifications land here. |
| Current phase | **Phase 6 — away mode · BUILT, REVIEWED, RUN ON DEVICES and all owner decisions applied — not signed off, 2026-09-01.** Start from **[phases/phase-6-handover.md](phases/phase-6-handover.md)** — what is left and in what order — then *The gate review* in [phases/phase-6-summary.md](phases/phase-6-summary.md); [phases/phase-6-brief.md](phases/phase-6-brief.md) is what the phase was asked to do. **The gate found that the feature did not work.** Three of the five reviewers independently found that away could be set **once per person and then never again** — nothing deletes the document when a period *ends*, `from` was immutable on update, and both call sites passed the stale cached period as `existing`, so every later attempt was refused on both sides with copy blaming the reader's choice of day. Three documents said otherwise, including §12's *"to go longer, set it again"*. Fixed by scoping `from`'s immutability to a **period** rather than a person, in the client and the rules, which is what ADR-0001 decision 6 actually argues; both new rules tests were verified by reverting the clause. **Two more defects that produce silence:** `onAwayChanged` could not change a **closed** watched device (the FCM handler never passed `away:`), and the away read had no timeout while being awaited inside `tap()`. **Eleven claims had stopped being true**, most written in the commits that made them false. Built: `AwayRecord` (attribution as a **separate type**, so no policy can decide from a name ADR-0003 says cannot be authenticated), `AwayRepository`, the `self_away` accessors the table waited five versions for, schema **v6**, `onAwayChanged` — the **fourth** Function, `onDocumentWritten` because every meaningful away change is an update or a delete — the picker, the Tap screen's away state, and the watcher list's away row and action. All three exit criteria are met **in tests**, and **every Phase 6 device-checklist row was run on 2026-09-01** — first on two API 36 AVDs while **the POCO refused every install** (`INSTALL_FAILED_USER_RESTRICTED`; HyperOS's *Install via USB* toggle, which a retry does not fix and adb cannot set), then **on the POCO itself** once the owner turned it back on. The run proved the closed-app nudge and the gate's `push_handler` fix on a device, both cancel shapes, §17's *"Ana marked you away until …"* surface, the v5 → v6 migration on a real store, and the 48dp day-cell floor at 360dp; **the handset then confirmed the OEM half** — 21/21 reminders armed around an away period with no vendor trimming, and the closed-app nudge waking a killed app in **both** directions on HyperOS. It also found that **an away period set offline reports *"Saved."* and changes nothing on the setter's own phone** until an unrelated reconcile runs. **Doze remains unmeasured.** **1 370 Dart tests** (1 202 at the start of the phase; 1 354 before the owner's decisions were applied), **80 rules tests** (75), **102 Functions tests** (83), analyze clean, debug APK builds, and **34 mutations / 34 caught / 0 survived** with thirteen passing controls — re-run after the owner's decisions were applied, with three added for the new code. **All seven owner decisions were taken and applied on 2026-09-01**: the copy is approved (the picker title now names the person on a watcher's phone), ending a period from the **watcher's row** asks first, that row says when a write lands, and a **queued** away write is cached on the phone that wrote it — bounded by the rule that the first read to succeed overrules it. **Owed:** Doze on the handset (the one OEM question the run did not close), and §12's four away transition notifications. `onAwayChanged`'s trigger wiring is **no longer owed**: `functions/test/away_trigger_fires.mjs` runs as 3/3 of `tools/functions-test.ps1`, asserts the create, the update and the **delete adapter** separately, was mutation-checked, and the device run then drove a real cancellation through it. |
| Previous phase | **Phase 5 — onboarding and pairing · COMPLETE and SIGNED OFF, 2026-08-26.** Two phones paired from a cold install using only a shared code (AVD ↔ POCO F3); each landed on the correct main screen; **the AVD finally tapped**, closing the half Phase 4 left owed. [ADR-0011](architecture/decisions/0011-creating-an-invite-is-a-function-too.md) added a **fourth** Function, `createInvite`. **The device run found two defects nothing else could** — a third FlutterFire plugin rewriting the emulator host, so every callable from a physical handset hung; and the summary screen being unreachable because the router left onboarding as soon as a question was answered. **All five reviewers then found fourteen more**, almost none from a test failing. **The gate closed the rest**, and running the reviewers over the close-out itself found four more defects in it. [phases/phase-5-summary.md](phases/phase-5-summary.md). |
| Phase 4 | **Firebase backbone · steps 1-7 built, all five reviewers run at the gate, two review rounds applied. Not signed off.** [phases/phase-4-summary.md](phases/phase-4-summary.md) carries the standing list: the first Functions deploy, App Check's console half, the live-radio measurement, and what ADR-0008's option 1 costs — the only open *design* decision, and the owner asked for the number rather than the ADR. Its three device rows: **the AVD tapping is now done** (Phase 5, 2026-08-26), the receiving half is still owed isolated, forced deep Doze remains unreachable on HyperOS, and the overnight-Doze run was never done. [phases/phase-4-handover.md](phases/phase-4-handover.md) is the mid-phase snapshot and is deliberately frozen — read it for the four things that went wrong, two of them false greens, not for current state. Phase 3 is complete: [phases/phase-3-summary.md](phases/phase-3-summary.md). |
| Open questions | **[OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)** — known, deliberately unsettled, not blocking. Each says what would make it a blocker. Read the *Blocking-when* table at every gate |
| Phase history | [phases/](phases/) — one summary per completed phase |
| Firebase project | `i-am-ok-c74ca` · Firestore `europe-west1` · Native mode · all permanent |
| Repo | https://github.com/davamix/IAmOk (public) |

---

## Reading order

Read these four, in this order, before touching anything.

1. **[PLAN.md](PLAN.md)** — the nine phases, what each delivers, and the review gate between them.
   Start here to know *what* is being built next.
2. **[architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md)** — the full design and the
   reasoning behind it. The single source of truth for *how*. Nothing may contradict it without a
   decision record.
3. **[infrastructure/firebase-setup-prompt.md](infrastructure/firebase-setup-prompt.md)** — what is
   actually provisioned, independently verified from the CLI, plus two Windows CLI traps.
4. **[HANDOVER.md](HANDOVER.md)** — historical. Read it for the environment and toolchain table,
   which is still current, and for the non-goals. Its design sections are superseded.

Then, whichever topic you are working in:

| Topic | Documents | Reviewer agent |
|---|---|---|
| Architecture | [architecture/](architecture/) · [decisions/](architecture/decisions/) | `architecture-reviewer` |
| Security | [security/](security/) — [threat model](security/threat-model.md), [rules guidelines](security/firestore-rules-guidelines.md), [secrets policy](security/secrets-policy.md) | `security-reviewer` |
| UI/UX | [ui-ux/](ui-ux/) — [guidelines](ui-ux/guidelines.md), [screens](ui-ux/screens.md) | `uiux-reviewer` |
| Testing | [testing/](testing/) — [strategy](testing/strategy.md), [device matrix](testing/device-matrix.md) | `testing-reviewer` |
| Infrastructure | [infrastructure/](infrastructure/) — [setup record](infrastructure/firebase-setup-prompt.md), [deploy notes](infrastructure/deploy-notes.md) | `infrastructure-reviewer` |
| Legal | [legal/](legal/) — privacy policy and terms, drafted in Phase 8 | — |

---

## How the repo documents itself

Four kinds of writing, deliberately kept apart, because mixing them is how documentation rots.

| Where | Holds | Changes when |
|---|---|---|
| `docs/` | Design, reasoning, and verified state. Prose for humans. | A decision is made or state is verified |
| `CLAUDE.md` | Constraints, each paid for by a failure that already happened. | Something actually goes wrong |
| `.claude/skills/` | Working rules per topic, loaded during normal work | The rules change |
| `.claude/agents/` | Five reviewers that apply those rules at a phase gate | The review focus changes |

Skills carry the rules; agents apply them. `CLAUDE.md` is not a style guide and not a wish list —
if a line in it was never paid for by a real failure, delete it.

---

## Per-phase protocol

1. Implement.
2. Run the relevant reviewer agents.
3. Write `docs/phases/phase-N-summary.md` — what was built, what was decided and **why**, what was
   deferred, what to watch out for next. It doubles as the handover to the next session.
4. Stop for the owner's review before the next phase begins.

---

## What is and is not secret

The full reasoning is in [security/secrets-policy.md](security/secrets-policy.md). The short form,
because getting this wrong in either direction is expensive:

- **Secret, never in the repo:** the release keystore and its passwords, any service-account JSON.
  They live in `.local/`, which is git-ignored, and in a password manager.
- **Not secret, despite intuition:** the Firebase project id, the API key inside
  `android/app/google-services.json` (it ships in the APK; anyone can unzip one), and the Firestore
  security rules. `google-services.json` is committed on purpose. The real control is security
  rules plus App Check, not hiding an extractable key.
