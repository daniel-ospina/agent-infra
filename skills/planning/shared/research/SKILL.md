---
disable-model-invocation: true
name: shared-research
description: "Research wrapper for workflows. Routes to research skill with proportional depth. Expands the routing stub with the granularity-ladder mechanics: PRIOR_RESEARCH dedup, gate mechanics (fresh-context brief review), and the output contract (fixed sections + ## Raw Notes + findings-date). Issue #231."
domain: capability
type: Routing
status: live
tags: [pipeline, shared, research]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
updated: 2026-08-13
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skill and adds workflow-specific guidance.

# Research Stage

Routes the workflow's research stage at the correct granularity rung of the ladder (research-protocol §0):

| Workflow | Depth | Behavior |
|---|---|---|
| **epic-workflow** (stage 2) | Deep (research skill, full brief) | Produce the epic research brief (5 canonical sections + `## Raw Notes`) via `epic-research` |
| **project-workflow** (stage 2) | Medium (research skill, targeted) | If parent epic has a brief → targeted research appends findings (granularity: issue-level questions the brief doesn't cover); otherwise run the research skill at Medium depth |
| **task-workflow-standard** (scope/plan stages) | Via issue-scoping Phase 1.5 + writing-plans Step B | No standalone research stage — the ladder rungs handle it (task-workflow-standard research-path note) |

## Instructions

1. **PRIOR_RESEARCH dedup first:** if the parent has an existing brief, read it and append findings — do NOT re-run broad queries the brief already covers. Deduplicated questions are skipped with a `> Deduplicated: covered by <brief section>` note and never count toward the query budget (research-protocol §0).
2. **Otherwise run the `research` skill:** Medium depth for projects, Deep for epics — per research-protocol §1 (five dimensions) with the per-bucket protocol (canonical / competitor-precedent / pitfalls) and adversarial framings.
3. **Fresh-query granularity:** inherited brief content is context, never a substitute — the current level's targeted queries are what the brief cannot answer (issue #231 P2/P3 reconciliation: fire on demonstrated gap; fresh queries at this level's granularity).

## Gate Mechanics

After the research stage completes (epics + standalone projects — any stage the workflow frontmatter declares `gate: verifier`), dispatch a fresh-context reviewer via `task`. **Precedence:** epic-research's own 4-item Review Gate remains the epic-tier gate; this 5-item checklist SUPPLEMENTS it (single dispatch, merged prompt) — it does not replace it:

```
Review this research output for:
1. BRIEF COMPLETENESS: Do the fixed sections exist (canonical headings per epic-research contract, or the output contract for the level)?
2. ADVERSARIAL BALANCE: Were disconfirming queries run, not just confirming ones?
3. DEDUP HONESTY: Are skipped/deduplicated questions justified with a section citation?
4. FINDINGS-DATE: Does the output carry a `> **Findings date:**` stamp or documented skip?
5. RAW NOTES: Are findings persisted to `## Raw Notes` (append-only, timestamped, source-tagged) per research-protocol §13?

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until clean or convergence (10-cycle cap).

## Output Contract

- **Epics:** the 5-section brief + `## Raw Notes` (canonical headings per epic-research).
- **Projects (appending to a parent brief):** timestamped entries appended via `scripts/_research_append.sh` + a synthesized block with per-framing provenance where the brief lacks coverage. **Do NOT use the `### Axis Research` heading here** — that name is issue-scoping Phase 1.5's sole artifact (D5 authorship boundary, PR #241); use a level-neutral heading (e.g., `### Targeted Research Findings`) or no heading (bare `## Raw Notes` entries).
- **Standalone projects:** `docs/research/<slug>.md` with fixed sections + `## Raw Notes` + `> **Findings date:**`.
- **Budget mode (`EXECUTION_INTENT=Budget`):** codebase + brief only, ≤ 2 external queries on P0-level gaps; epic tier defers to the brief entirely.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
