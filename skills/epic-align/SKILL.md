---
name: epic-align
description: "Bounded skill for epic strategy alignment. Runs BEFORE research — adversarial check, Eisenhower matrix, profit growth alignment. Produces a decision rationale that either validates the feature or suggests alternatives. Invoked by epic-plan at pipeline start."
domain: planning
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

# Epic Strategy Alignment

**Announce at start:** "I'm using the epic-align skill for strategy alignment."

## Purpose

Bounded skill that runs as the FIRST step of the epic planning pipeline. Before any research or design work begins, this skill validates that the proposed epic is the right thing to build — not just that it's well-specified.

## Workflow

### Step 1 — Adversarial Strategy Test

Challenge the feature idea directly:

- **Consider alternatives:** What other ideas/actions could achieve the same goal? List 2-3 concrete alternatives.
- **Anti-post-rationalization:** Actively argue AGAINST the proposed approach. What are the strongest reasons NOT to build this? What assumptions is it betting on?
- **Opportunity cost:** If we didn't build this, what would we build instead? Is there a higher-leverage option available?

### Step 2 — Eisenhower Matrix Analysis

Classify the feature on the Eisenhower matrix:

| | Urgent | Not Urgent |
|---|---|---|
| **Important** | Do now | Schedule |
| **Not Important** | Delegate | Eliminate |

- Is this the **best action for profit growth right now**?
- Where does it fall on the matrix? Justify the placement.

### Step 3 — Profit Growth Alignment

- How does this feature contribute to profit? Map the causal chain from feature → user behavior → revenue.
- Is there a faster or better path to the same profit outcome?
- Quantify the expected impact (rough order-of-magnitude: $10s, $100s, $1000s/month).

### Step 4 — Decision Rationale

Output a structured decision:

```markdown
## Strategy Alignment Decision

**Feature:** <epic title>
**Decision:** PROCEED | DEFER | ELIMINATE | REDIRECT

**Alternatives considered:**
1. <alternative 1> — <why rejected/chosen>
2. <alternative 2> — <why rejected/chosen>

**Profit impact:** <causal chain + rough estimate>

**Eisenhower placement:** <quadrant + justification>

**Key assumptions:**
- <assumption 1> — confidence: <high/medium/low>
- <assumption 2> — confidence: <high/medium/low>

**Recommendation:** <1-2 sentence summary>
```

### Step 5 — Routing

- **PROCEED:** Hand off to `epic-research` for next pipeline stage.
- **DEFER/ELIMINATE/REDIRECT:** Surface the decision rationale. The pipeline stops here — do not proceed to research.

## Review Gate

Dispatch a fresh-context reviewer via `task` sub-agent:

```
Review this strategy alignment decision for:

1. ADVERSARIAL QUALITY: Were alternatives genuinely challenged, or post-rationalized?
2. PROFIT CAUSALITY: Is the profit chain testable, or hand-wavy?
3. ASSUMPTION RISK: Are key assumptions surfaced with confidence levels?
4. MATRIX HONESTY: Is the Eisenhower placement honest, or convenience-classified?

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until "NO ISSUES FOUND" or convergence; safety cap: 10 cycles.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Adversarial test | Features built on unchallenged assumptions — post-rationalization becomes the norm |
| Eisenhower matrix | Urgent-but-unimportant work consumes pipeline capacity |
| Profit alignment | Features ship that don't move the revenue needle |
| Decision rationale | No traceability from strategy to implementation |

## Integration

**Called by:** `epic-plan` (pipeline step 1)
**Hands off to:** `epic-research` (if PROCEED)
**References:** `research-protocol` (adversarial query patterns)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
