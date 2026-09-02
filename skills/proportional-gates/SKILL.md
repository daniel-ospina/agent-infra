---
disable-model-invocation: true
name: proportional-gates
description: "Reference: replaces rigid/programmatic skill rules with judgment-based gating. Consumed by other skills — not invoked directly. Defines proportionality principle, risk-tiered verification, and the 'reviewer validates judgment' pattern."
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Proportional Gates

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Overview

Rigid rules ("always run 4 reviewers", "always typecheck", "always use a worktree") create bureaucracy without intelligence. They force the same overhead on a 3-line config change as on a 500-line DB migration. This wastes tokens, slows down agents, and produces non-sensical results (typecheck failures attributed to markdown changes).

**Proportional gates** replace mechanical rules with a single principle: **match verification depth to change risk and novelty.** An agent uses judgment to decide what gates to run. A reviewer validates those decisions.

This skill is the canonical reference. Consuming skills inline the proportionality tables relevant to their domain.

---

## Core Principle

> **The cheapest verification that catches the most likely failure mode. Proportionate to the change. Validated by review.**

Every gate decision follows the same logic:
1. **Classify the change** — what type? what risk? what novelty?
2. **Select proportional verification** — what's the cheapest check that catches the likely failure?
3. **Note the decision** — document what was skipped and why
4. **Reviewer validates** — a fresh sub-agent confirms the gating decisions were appropriate

---

## Change Classification

Before deciding what gates to run, classify the change:

| Dimension | Low | Medium | High |
|-----------|-----|--------|------|
| **Code impact** | Docs, config, CSS, strings only | Single component/hook change | Multi-file, shared types, DB, auth |
| **Surface risk** | No runtime behavior change | UI behavior change, existing pattern | New integration, new data flow, auth change |
| **Novelty** | Following existing pattern exactly | Adapting existing pattern | New pattern, unfamiliar library, first-of-kind |
| **Reversibility** | Trivially revertible | Requires migration rollback | Destructive, data loss possible |

**Overall risk = highest dimension.** A docs-only change with high novelty = Medium (docs are low-risk even if novel).

---

## Proportionality Tables

### Workspace Isolation

| Risk | Isolation |
|------|-----------|
| Low | Plain branch acceptable. No worktree needed. |
| Medium | Worktree recommended if 3+ files or shared infrastructure. Plain branch OK for single-file. |
| High | Worktree required. Stash uncommitted changes first. |

**Never** start on main/master regardless of risk.

### Pre-flight Verification

| Risk | Typecheck | Build | Integration Tests | pgTAP |
|-------|-----------|-------|-------------------|-------|
| Low | Skip (no TS changes) | Skip | Skip | Skip (migrations = always High) |
| Medium | Run if .ts/.tsx changed | Run if src/ changed | Run if integration surfaces touched | Run if migrations |
| High | Always run | Always run | Always run | Always run |

**Skip rule:** If a check would not catch the change's failure mode, skip it. A markdown change cannot cause a type error. A CSS change cannot break an integration test.

### Review Cycles

| Risk | Reviewers | Max Cycles |
|------|-----------|------------|
| Low | 0 (skip review) | — |
| Low-Medium (small plan, existing patterns) | 2 reviewers (Structural + Integration) | 3 |
| Medium-High (large plan, some novelty) | 3 reviewers (+ Efficiency) | 5 |
| High (novel architecture, first-of-kind) | 4 reviewers (all parallel) | 8 |

**Proportional dispatch:** The agent decides how many reviewers to launch based on plan size and novelty. A 20-line plan following existing patterns = 2 reviewers. A 200-line plan with new architecture = 4 reviewers.

### Dependency Verification

| Situation | Action |
|-----------|--------|
| Dep already used elsewhere in codebase | Skip verification — pattern is known |
| Dep is well-known stdlib-adjacent (lodash, date-fns) | Skip — common knowledge |
| Dep is new to codebase AND not in plan's Pattern Research | Verify: 1-2 Perplexity calls |
| Dep is novel, unfamiliar, AND plan has no Pattern Research | Verify: 2-3 Perplexity calls. Pause if unavailable. |

**Perplexity unavailable:** If dep is well-known (used in 2+ other repos, documented extensively), proceed with note. Only pause for genuinely novel deps.

### Research Depth

| Topic novelty | Research calls |
|---------------|---------------|
| Well-known pattern (codebase has 2+ examples) | 0-1 Perplexity calls |
| Pattern exists but choice has trade-offs | 2-3 Perplexity calls (canonical + comparative) |
| Novel pattern, no codebase precedent | 3+ Perplexity calls (canonical + comparative + pitfalls + recency) |
| First-of-kind, unfamiliar domain | 5+ calls (all framings + scale + adversarial) |

---

## The Reviewer-Validates-Judgment Pattern

Instead of rigid rules, skills use this pattern:

```
Agent: "Classified as Low risk — skipping typecheck (no TS changes), 
        using plain branch (single markdown file). 
        Reviewer will validate."
        
Reviewer sub-agent: reads the change, confirms:
  - Classification is correct (are there hidden .ts changes?)
  - Skipped gates would not have caught anything
  - → "Classifications validated: Low risk confirmed. All skips appropriate."
  OR
  - → "Found .ts file in diff — reclassify as Medium. Run typecheck."
```

This is the same generate-review loop applied to gate selection itself. The agent uses judgment; the reviewer catches mistakes; the loop converges.

---

## Inlining Instructions

Consuming skills inline the proportionality tables relevant to their domain. Do NOT inline the full skill — just the tables that replace rigid rules.

Format in consuming skills:

```markdown
## Proportional Gates (inlined from proportional-gates v1.0.0)

> Replace rigid rules with judgment-based gating. See proportional-gates/SKILL.md for the canonical reference.

### [Domain] Proportionality

[Relevant table(s) from above]

### Reviewer-Validates-Judgment

After classifying and selecting gates, dispatch a brief review sub-agent to validate the decisions. On disagreement, re-classify and re-run skipped gates.
```

---

## When NOT to Apply Proportionality

Some gates should remain absolute — they catch catastrophic failures that judgment cannot reliably predict:

| Gate | Why Absolute |
|------|-------------|
| pgTAP on migrations | Data loss from bad migrations is irreversible. Always run. |
| P0 human gates | Data loss, security, legal/compliance, cost >$10/mo. Always pause. |
| Commit to main/master | Never. Always use a branch. |
| Force push to main | Never. |

Proportionality applies to **verification depth**, not to **safety invariants**.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.


## Review Gate Routing by Level

For review gates that dispatch sub-agent reviewers, route proportionally based on the issue's Level field:

| Level | Dispatch | Rationale |
|-------|----------|-----------|
| **Epic** | Sub-agent reviewer (fresh context) | Full adversarial check needed; scope justifies dispatch cost |
| **Project** | Inline review (current context) | Targeted check; dispatch overhead exceeds marginal value |
| **Task** | Inline self-check | Lightweight; no separate review needed |

**Fallback:** If Level is missing or unrecognized, default to sub-agent review (safe default = full review, never skip).

**Skills affected:** `plan-review`, `code-review`, `test-review`, and any skill that dispatches reviewer sub-agents.

**Enforcement:** The skill-enforcer extension already requires the relevant skill to be read before the operation. This routing table is an agent instruction — the agent reads this skill and applies the rule.
