# Decision records

**Date:** 2026-08-15 · **Status:** Established in Phase 0.

## Index

| ADR | Title | Status | Affects |
|---|---|---|---|
| [0001](0001-away-cache-precedence.md) | Refresh Firestore before the away cache decides | Accepted | ARCHITECTURE.md §8, §10, §12 |
| [0002](0002-clock-split.md) | Split the clock, and cache the device timezone on disk | Accepted | ARCHITECTURE.md §4, §5, §6, §11 |

## What belongs here

One file per decision that is **taken after Phase 0** and that either changes something in
[ARCHITECTURE.md](../ARCHITECTURE.md) or is expensive to reverse. A decision earns a record when
the next person would otherwise re-open it — that is the whole test.

Write one when:

- ARCHITECTURE.md would have to change to accommodate the choice
- the choice is a one-way door, or costs a migration to undo
- an option in ARCHITECTURE.md §18 *Still open* gets resolved
- something in ARCHITECTURE.md turns out to be **wrong** once it meets real hardware — record the
  correction here and amend the section, rather than leaving two documents disagreeing

Do **not** write one for: a naming choice, a package version, a refactor, or anything a reader can
recover from the code and the git history.

## Why there are no records for the decisions already taken

The decisions made before Phase 0 are already written down, with their reasoning, in prose that is
better than a retro-fitted template would be:

| Decision set | Where |
|---|---|
| Identity, notification model, roles-on-links, away model, FCM data-only, region | [ARCHITECTURE.md](../ARCHITECTURE.md) §1 |
| One-way doors — applicationId, Firestore location and mode, project id | [ARCHITECTURE.md](../ARCHITECTURE.md) §16 |
| Pairing by invite code, onboarding routing, away start date | [PLAN.md](../../PLAN.md) — *Decisions locked before planning* |
| What is and is not secret | [security/secrets-policy.md](../../security/secrets-policy.md) |
| Everything superseded from the setup session | [HANDOVER.md](../../HANDOVER.md) — marked historical |

Converting those into ADRs would produce a second, lower-quality copy of the same reasoning and a
new opportunity for the two to drift. They are not retro-fitted.

ADR-0001 is therefore not a pre-existing decision written up late — it is the first genuinely
*new* one, forced by a defect the Phase 0 review found in ARCHITECTURE.md §10.

## Format

Filename `NNNN-short-kebab-title.md`, numbered in order, never renumbered.

```markdown
# ADR-0007 — Short imperative title

**Date:** YYYY-MM-DD · **Status:** Proposed | Accepted | Superseded by ADR-00NN
**Phase:** N · **Affects:** ARCHITECTURE.md §X

## Context
What made this a question. What was already true. What was actually observed — if the
prompt was a real failure, name it, because that is the most useful part.

## Decision
What was chosen, stated as a decision and not as a discussion.

## Consequences
What this makes easy, what it makes hard, and what it forecloses. Include the cost of
reversing it. State this honestly — an ADR listing only benefits is a sales pitch.

## Alternatives considered
Each with the reason it lost. An alternative with no stated reason was not considered.
```

Keep it short. Two paragraphs of honest reasoning beat two pages of headings.

## Superseding

Never edit a decision to say something different, and never delete one. Write a new record, and set
the old one's status to `Superseded by ADR-00NN`. The record of a decision that turned out wrong is
worth more than the record of one that happened to be right — it is the only thing that stops the
same option being re-argued a year later.
