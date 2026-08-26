# I Am Ok — documentation index

A daily "I'm OK" signal from an elderly person living alone to the family who watch over them.
One tap a day. A quiet update when it happens, a loud warning when it doesn't.

**Android only. Flutter + Firebase.** Not a health monitor, not an emergency-help app — see the
non-goals in [HANDOVER.md](HANDOVER.md), which the whole design is built on top of.

| | |
|---|---|
| Current phase | **Phase 4 — Firebase backbone · steps 1-7 built, all five reviewers run at the gate, and every item the post-gate round left open now closed.** **Start from [phases/phase-4-summary.md](phases/phase-4-summary.md)** and its *Prompt to start the next session*. A push may not post a warning before `warningLocalTime` ([ADR-0010](architecture/decisions/0010-a-push-may-not-post-a-warning-early.md)) and a row that changes under a screen reader is announced — **both directions**, proven on hardware. The post-gate re-review left three items, and all three are done: announcements **still reach TalkBack at `targetSdk 36`** (measured on the API 36 AVD with an exactly-matched silent control — the risk was real to raise and false as stated); a retraction the hour-gate used to **destroy** is now held in `correctionsOwedFor` and spoken at the reader's hour; and the OK → warning announcement was approved by the owner and ships as the warning body verbatim. **A second review round over that work has run and its findings are applied** — two real defects (an unpinned guard that let a warning be spoken at midnight, and a mixed pass that spoke the warning last where an interrupt clips it) plus ARCHITECTURE.md still specifying the behaviour ADR-0010 disowned. **The only design decision still open is what ADR-0008's option 1 costs** — the owner asked for the number, not the ADR — and one question is explicitly owed to the owner: `correctionsOwedFor` has no age bound, so a muted phone can retract a warning a season after it was cancelled (`ui-ux/screens.md`). After that: the first Functions deploy, App Check's console half, the live-radio measurement, and the AVD taps. [phases/phase-4-handover.md](phases/phase-4-handover.md) is the mid-phase snapshot and is deliberately frozen there — read it for the four things that went wrong, two of them false greens, not for current state. Phase 3 is complete: [phases/phase-3-summary.md](phases/phase-3-summary.md). |
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
