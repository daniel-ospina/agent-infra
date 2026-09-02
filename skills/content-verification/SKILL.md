---
disable-model-invocation: true
name: content-verification
version: 1.0.0
description: "Content-domain verification gate. Dispatches the content pipeline v2 reviewers — breadth + depth in parallel (post-writing), then fact-checker (writing) after the reviewer cycle is clean — for editorial, guide, deal, and refresh content. Invoked by test-routing when domain=content; referenced by research-verification and issue-creation as the Content verification trigger. Returns structured P0/P1/P2 issues + verdict."
domain: engineering
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Verification — Content-Domain Gate

## Overview

Ensures every Content-domain issue reaches an actual verification skill. Thin orchestrator — dispatches to the existing content pipeline v2 reviewers and aggregates their output into a single gate verdict.

**Announce at start:** "I'm using the content-verification skill to run content verification."

Invoked by `test-routing` when domain=content is detected. Also the Content-domain verification trigger referenced by `research-verification` (content-pipeline research deferral) and `issue-creation` (Content domain row in the complexity table).

### When to Use

- Editorial, guide, deal, or refresh content changes (issue has content/editorial/deal labels)
- Content written by any content writer skill that needs the post-writing review cycle
- Any routing that lands on the Content domain

### When NOT to Use

- Pure code changes with no content → routed to code verification
- Research investigations → `research-verification` (unless content-pipeline keyword/SERP research → this skill)
- Trivial copy/label changes with no editorial substance → skip

## Inputs Required

| Input | Source | Notes |
|-------|--------|-------|
| Draft content | Writer skill output | intro, body, FAQs, meta fields (page_type-specific) |
| Research brief | Content research (fact-checked) | Verified claims, ✓/~/✗ tags (breadth/depth source; deal mode uses the Deal Research Brief with confidence tags) |
| Deal Research Brief | deal-content-writer Step 0.5 (deal mode only) | specialty_facts, practical_tips, confidence tags — source for breadth B-D1–B-D4 / depth D-D1–D-D3 |
| deal_id | Orchestrator (deal mode only) | resolves the deal DB record — used ONLY by fact-checker D1–D5 |
| page_type | Orchestrator | `editorial` \| `guide` \| `deal` \| `refresh` |
| Language | Orchestrator | es/en — determines audience consistency checks |

## Process

### Step 1 — Read Domain & Inputs

Confirm the routing is Content-domain from the test-routing verification plan:

```
Domain: content
page_type: editorial | guide | deal | refresh
```

Gather the draft content, research brief, page_type, and language. If page_type = `deal`, run deal-mode checks: breadth B-D1–B-D4 and depth D-D1–D-D3 read the **Deal Research Brief** (specialty_facts, practical_tips, confidence tags) — they do NOT need a DB audit; only fact-checker D1–D5 reads the **deal DB record** (value_mechanism, access_conditions, business.name, category).

### Step 2 — Fan-Out Breadth + Depth Reviewers (Parallel)

Dispatch the two post-writing reviewers **in parallel** (per content pipeline v2 — they run concurrently):

1. **`content-reviewer-breadth`** — coverage: neighborhoods, cuisine/experience types, price tiers, partner completeness (BR1–BR7 / B-D1–B-D4)
2. **`content-reviewer-depth`** — local depth, unique findings, audience consistency (DPT1–DPT5 / D-D1–D-D3)

Pass to each: draft content, research brief, page_type, language. Collect their structured ISSUE blocks (P0/P1/P2 with location/problem/fix) and summary counts.

### Step 3 — Review Cycle Until Clean

The reviewers are gates, not one-shot checks:

1. Merge issues from both reviewers, dedupe by location+problem
2. If issues exist → feed the merged list back to the writer for targeted fixes (fix ONLY flagged claims, no full rewrites)
3. Re-dispatch reviewers on revised content
4. Repeat until both return 0 issues **or** max iterations reached (cap 10 refinement rounds)

**After max iterations:** P0 remaining → gate stays closed, surface for human review. P1 → address before delivery. P2 → advisory, proceed with note. Never silently drop content.

### Step 4 — Dispatch Fact-Checker (Writing)

Once the reviewer cycle is clean (`is_clean: true`), dispatch **`content-fact-checker-writing`**:

- Editorial/guide/refresh: extract claims → map to verified research brief (FC1+ / FCE1+ for guide deal-embed UUIDs) → P0/P1/P2 issue list
- Deal: run D1–D5 against the deal DB record (discount vs value_mechanism, business name, access framing, invented details, meta accuracy)

Fact-check is itself a gate — run its refinement loop until 0 issues or the 10-round cap. P0 after cap blocks delivery.

### Step 5 — Return Verification Report

```markdown
## Content Verification Report

**Issue:** #N
**page_type:** editorial
**Language:** es
**Reviewers dispatched:** breadth, depth (parallel), fact-checker-writing

### Issues
| # | Reviewer | Severity | Location | Problem | Fix |
|---|----------|----------|----------|---------|-----|
| 1 | breadth | P1 | body §3 | Missing neighborhood: Playa Norte | Add one-sentence mention... |

**Summary:**
- P0 issues: X (block delivery)
- P1 issues: Y (should fix before delivery)
- P2 issues: Z (optional)
- Unique research findings used: X/Y

**Verdict:**
- ✓ PASS — all gates clean, content verified
- ✗ NEEDS FIXES — [count] issues require correction
```

## Pipeline Handoff

**Invoked by:** `test-routing` (domain=content), `research-verification` (content-pipeline research deferral), `issue-creation` (Content verification trigger)
**Dispatches to:** `content-reviewer-breadth`, `content-reviewer-depth` (parallel), `content-fact-checker-writing`
**Consumed by:** verification-gate checks in `test-routing` (Content domain dispatch) and `research-verification` / `issue-creation` references.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Breadth review | Drafts publish with dropped neighborhoods, cuisines, or partners — incomplete pages |
| Depth review | Generic travel-blog content — no local insight, no audience consistency |
| Fact-check gate | Invented facts, prices, or superlatives reach production content |
| Deal-mode checks | Wrong discount %, wrong access framing, or invented deal details go live |
| Parallel fan-out | Serial dispatch doubles review wall-clock time for no quality gain |

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
