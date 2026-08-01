> **Step 1/6** | ← requires: nothing (entry point) | → next: Step 2 (full build) or Step 6 (incremental/review)

# Mode Detection & Setup

## Announcement

Announce at start: "I'm using the strategy-builder skill. Pi uses DeepSeek v4 Pro by default. For complex reasoning, dispatch sub-agents via the task tool."

Design doc: `docs/teams/eldato-outreach-team/growth/2026-03-14-strategy-framework-design.md`

---

## Mode Selection

At start, read existing artifacts and determine mode:

1. **Full Build** — `strategy.md` has empty/template sections (or doesn't exist) → full build
2. **Incremental Update** — strategy.md is populated + user has new data to integrate → incremental
3. **Review Secrets** — user wants to review `earned_secrets.md` patterns without new data → review
4. **Partial Rebuild** — strategy.md is populated but user wants to redo specific phases → ask which phases, run only those + coherence review at end

If mixed (some sections populated, others empty), ask:

> "Which mode? (a) Full build from Phase 1, (b) Skip to Phase N — these sections look populated: [list], (c) Incremental update with new data, (d) Review earned secrets"

---

## When to Use

- **Full Build:** First-time strategy creation or major strategy overhaul
- **Incremental Update:** After a batch of customer discovery calls, experiment results, or significant market learning
- **Review Secrets:** Standalone pattern recognition on accumulated earned secrets
- **Partial Rebuild:** Redo specific phases while keeping the rest intact

## When NOT to Use

- Product feature planning → use `epic-workflow`
- Individual issue scoping → use `issue-scoping`
- Content creation → use `content-strategy-agent`
- Translating strategy into executable pitch components → use `strategy-to-pitch-components` (see #1064)

---

## Artifacts

All output is written to disk at phase boundaries. Conversation history is secondary to files.

| Artifact | Path | Purpose |
|---|---|---|
| Philosophy | `docs/teams/eldato-app-team/product/philosophy.md` | Identity/ethos (VSM System 5) |
| Strategy | `docs/teams/eldato-app-team/product/strategy.md` | Comprehensive GTM strategy (VSM System 4) |
| Experiments | `docs/teams/eldato-app-team/product/experiments.md` | Experiment tracker |
| Earned Secrets | `docs/teams/eldato-app-team/product/earned_secrets.md` | Field insights + field notes |
| Research Dump | `docs/09_strategy/research/YYYY-MM-DD-<mode>.md` | Raw research preservation |

Ensure `docs/09_strategy/research/` exists at start: `mkdir -p docs/09_strategy/research`

---

## Strategy Document Structure

The `strategy.md` document uses this section order. §2 is the first section readers encounter; the Frameworks Reference is an appendix at the end.

```
§2. Customer Definition
§3. Jobs to Be Done
§4. Competition Analysis
§5. Value Proposition
§6. Differentiators
§7. Pitch Components Derivation
Appendix A. Frameworks Reference (produced by Phase 1)
```

Phase 1 still produces the Frameworks Reference — it is written into the appendix rather than as §1.

---

## Routing

| Mode | Go to Step |
|---|---|
| Full Build | `workflow/02-full-build-frameworks.md` |
| Incremental Update | `workflow/06-incremental-review.md` |
| Review Secrets | `workflow/06-incremental-review.md` |
| Partial Rebuild | Ask which phases, run those + coherence review |

---

## Required Reading

Before any research or drafting, the agent must read:
- `references/protocols.md` — confidence tiers, research protocol, adversarial review, clean room comparison, human gate protocol, key principles, common mistakes
- `references/context-management.md` — progressive commit, session boundaries, handoff, subagent usage
