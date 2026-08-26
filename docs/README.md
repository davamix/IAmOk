# I Am Ok — documentation index

A daily "I'm OK" signal from an elderly person living alone to the family who watch over them.
One tap a day. A quiet update when it happens, a loud warning when it doesn't.

**Android only. Flutter + Firebase.** Not a health monitor, not an emergency-help app — see the
non-goals in [HANDOVER.md](HANDOVER.md), which the whole design is built on top of.

| | |
|---|---|
| Next phase | **Phase 6 — away mode.** Start from **[phases/phase-5-summary.md](phases/phase-5-summary.md)** and its *Prompt to start the next session*. Phase 5 is built and its exit criterion is met on two devices; it is **not signed off** — every new user-visible string is owed the owner's approval, two of them changes to already-approved copy, and the five reviewers have not run. |
| Previous phase | **Phase 5 — onboarding and pairing · built, exit criterion MET on two devices.** Two phones paired from a cold install using only a shared code (AVD ↔ POCO F3, 2026-08-26); each landed on the correct main screen; **the AVD finally tapped**, closing the half Phase 4 left owed. [ADR-0011](architecture/decisions/0011-creating-an-invite-is-a-function-too.md) added a **fourth** Function, `createInvite` — §8 always said `invites/{code}` was Function-written and the rules enforce it, while §9 listed only `redeemInvite` and §6 asked the client for a write no client may perform. **The device run found two defects nothing else could**: a third FlutterFire plugin rewriting the emulator host, so every callable from a physical handset went to `10.0.2.2` and hung; and the summary screen being unreachable because the router left onboarding as soon as a question was answered. Both fixed, both with regression tests. 1 141 Dart tests, 67 Functions tests, 26 Dart mutations and 16 Functions mutations all behaving as expected with a passing no-op control. |
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
