---
name: research-verification
description: "Thin wrapper that standardizes invocation of the research skill's adversarial review gate. Ensures disconfirming queries are run and assumptions are challenged. Invoked by test-routing when domain=research."
domain: engineering
allowed-tools: read write edit bash grep find web_search web_fetch
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Research Verification — Adversarial Review Gate

## Overview

Ensures every research investigation includes adversarial review — disconfirming queries, assumption challenges, and source verification. Thin wrapper — delegates to the `research` skill's built-in adversarial gate.

**Announce at start:** "I'm using the research-verification skill to run adversarial review."

Invoked by `test-routing` when domain=research is detected.

### When to Use

- Research investigations (market, technical, competitive)
- Decision-support research (architecture choices, tool comparisons)
- Domain exploration (new technology, new market)

### When NOT to Use

- Trivial single-fact lookups ("what version of Node?") → skip
- Content-pipeline research (keyword/SERP) → content-verification handles this
- Research already passed adversarial review → skip

## Process

### Step 1 — Read Domain

Confirm this is a research issue from the test-routing verification plan:

```
Domain: research
```

### Step 2 — Invoke Adversarial Review

Route to the `research` skill's adversarial review gate. This runs:

1. **Disconfirming queries:** Search for evidence that contradicts the research findings
2. **Assumption challenge:** List all assumptions, challenge each with "what if this is wrong?"
3. **Source verification:** Check that claims are sourced (internal codebase, external docs, web research)
4. **Alternative framings:** How might we achieve the same outcome differently?

### Step 3 — Verify Gate Completeness

- [ ] Disconfirming queries were run (not skipped)
- [ ] At least one disconfirming finding was surfaced (if none, flag as P2 — possible confirmation bias)
- [ ] Assumptions are tagged with confidence levels
- [ ] Sources are cited for key claims

### Step 4 — Return Report

```markdown
## Research Verification Report

**Issue:** #N
**Research topic:** <summary>
**Adversarial queries run:** 3
**Disconfirming findings:** 1

### Adversarial Findings
| Query | Finding | Impact |
|-------|---------|--------|
| "What are alternatives to X?" | Y is a viable alternative not considered | Medium — should be added to research brief |

### Assumption Check
| Assumption | Confidence | Challenged? |
|------------|-----------|-------------|
| "Supabase scales to 1M users" | medium | Yes — found counterexample at 500K |
| "Playwright is faster than Cypress" | high | Yes — confirmed by benchmarks |

### Verdict
**PASS** — adversarial review complete. 1 disconfirming finding surfaced.
```

## Pipeline Handoff

**Invoked by:** `test-routing` (domain=research)
**Dispatches to:** `research` skill (adversarial review gate)
**Consumed by:** `code-review` (verification gate check)

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Disconfirming queries | Research confirms existing bias — missed alternatives, unchallenged assumptions |
| Assumption challenge | Untracked assumptions become silent design constraints |
| Source verification | Claims treated as facts without evidence — decisions built on sand |
