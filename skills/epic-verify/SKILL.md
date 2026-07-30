---
name: epic-verify
description: "Bounded skill for epic pipeline verification. Final gate before implementation begins — verifies cross-phase coherence, E2E test alignment from high-level to detailed, and pipeline artifact completeness. Invoked by epic-plan after epic-decompose completes."
domain: planning
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

# Epic Verification

**Announce at start:** "I'm using the epic-verify skill for pipeline verification."

## Purpose

Final verification gate for the epic planning pipeline. Runs after `epic-decompose` produces all child issues. Verifies that the full pipeline output is coherent, complete, and ready for implementation.

## Workflow

### Step 1 — Artifact Completeness Check

Verify all pipeline artifacts exist:

- [ ] Strategy alignment decision (`epic-align` output)
- [ ] Research brief (`epic-research` output)
- [ ] Scope boundaries + high-level E2E tests (`epic-scope` output)
- [ ] Epic plan with all 8 sub-step sections (`epic-plan` output)
- [ ] Dependency-ordered issue list (`epic-decompose` output)
- [ ] Every issue has a review-gate pass record

### Step 2 — Cross-Phase Coherence

Check for drift between pipeline phases:

| Check | Source | Target | What to verify |
|-------|--------|--------|---------------|
| Strategy → Scope | `epic-align` decision | `epic-scope` boundaries | In-scope items align with PROCEED decision |
| Scope → Plan | `epic-scope` boundaries | `epic-plan` sections | Every in-scope item has a plan section |
| High-level → Detailed E2E | `epic-scope` E2E tests | `epic-plan` detailed E2E | Every high-level test has a detailed counterpart |
| Plan → Issues | `epic-plan` sections | `epic-decompose` issues | Every plan section maps to ≥1 issue |

### Step 3 — E2E Test Alignment

Verify the test chain is unbroken:

```
High-level E2E (epic-scope) → Detailed E2E (epic-plan §7) → Issue test references (epic-decompose)
```

Check each link:
1. Every high-level E2E test case → has a corresponding detailed E2E test case
2. Every detailed E2E test case → is referenced by ≥1 issue
3. Every issue that touches a tested workflow → references the relevant test case

### Step 4 — Review Gate Audit

Verify all review gates passed:

| Phase | Review Gate | Status |
|-------|------------|--------|
| `epic-align` | Strategy review | ✅/❌ |
| `epic-research` | Research brief review | ✅/❌ |
| `epic-scope` | Scope review | ✅/❌ |
| `epic-plan` §1-8 | Per-sub-step reviews | ✅/❌ (×8) |
| `epic-decompose` | Per-issue + MECE | ✅/❌ |

Flag any failed or skipped review gates.

### Step 5 — Final Decision

```
## Epic Verification Result

**Epic:** <title>
**Status:** READY | NEEDS FIXES

**Artifacts:** <N>/<total> present
**Coherence:** <N> issues found
**E2E Alignment:** <N> gaps
**Review Gates:** <N> passed / <total> total

<if NEEDS FIXES: list specific gaps and recommended fixes>

**Decision:** PROCEED to implementation | RETURN to <phase> for fixes
```

## Review Gate

Dispatch a fresh-context reviewer via `task` sub-agent:

```
Review this epic verification for:

1. FALSE PASS: Are any "passed" checks actually failing on closer inspection?
2. MISSING CHECKS: Are there pipeline integrity checks not covered by the 5 steps?
3. CROSS-PHASE DRIFT: Read the actual artifacts and verify they're coherent — don't trust the checkboxes.

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until "NO ISSUES FOUND" or convergence; safety cap: 10 cycles (verification is auditing, not creating).

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Cross-phase coherence | Implementation starts with drift between strategy, scope, and plan — teams build different things |
| E2E test alignment | High-level tests written in scoping have no detailed counterparts — untestable acceptance criteria |
| Review gate audit | Skipped review gates discovered during implementation — "why wasn't this caught in planning?" |

## Integration

**Called by:** `epic-plan` (after `epic-decompose` completes)
**Hands off to:** Implementation phase (issues go to `issue-workflow` pipeline)
**Input:** Full pipeline output (all 5 phases)
**References:** `parallel-orchestrator` (review gate dispatch)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
