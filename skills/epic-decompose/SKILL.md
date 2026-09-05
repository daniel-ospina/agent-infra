---
disable-model-invocation: true
name: epic-decompose
description: "Bounded skill for work decomposition into GitHub issues. Takes the approved epic plan and generates child issues with per-issue review gates and MECE verification (Mutually Exclusive, Collectively Exhaustive). Uses the issue-creation skill for each issue. Invoked by epic-plan after coherence review passes."
domain: planning
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: extract_work_units
    type: skill
    gate: auto
    produces: [work_units]
  - name: dependency_order
    type: skill
    gate: auto
    requires: [extract_work_units]
    produces: [ordered_units]
  - name: generate_issues
    type: skill
    gate: auto
    requires: [dependency_order]
    produces: [child_issues]
  - name: per_issue_review
    type: parallel
    gate: verifier
    requires: [generate_issues]
    produces: [reviewed_issues]
  - name: mece_verification
    type: skill
    gate: verifier
    requires: [per_issue_review]
    produces: [verified_decomposition]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

# Work Decomposition into Issues

**Announce at start:** "I'm using the epic-decompose skill for issue generation."

## Purpose

Bounded skill that decomposes an approved epic plan into implementable GitHub issues. Each issue passes through a coherence review gate. After all issues are generated, a MECE gate verifies the decomposition is complete and non-overlapping.

## Workflow

### Step 1 — Extract Work Units

From the approved epic plan, extract discrete work units:

- Each sub-step that produces a deliverable → potential issue
- Each cross-cutting concern (auth, testing, deployment) → potential issue
- Each integration point between sub-steps → potential issue

### Step 2 — Dependency Order

Map dependencies between work units:

```
Issue A ──→ Issue B (B depends on A)
Issue A ──→ Issue C (C depends on A)
Issue D (independent — can run in parallel)
```

### Step 3 — Generate Issues

For each work unit, invoke the `issue-creation` skill:

```
Create a GitHub issue for: <work unit description>

Parent epic: <epic doc path>
Depends on: <dependency list>
Complexity: <from epic scope ratings>
```

Each issue must include:
- **Epic contract reference** — link to the epic plan section it implements
- **Test alignment** — reference the E2E test cases it should satisfy
- **Test-design reference** — link the epic's integration-surface map (from the test-design issue created before Plan) and name the surfaces this work unit touches
- **Verification checklist** — derived from the surface map: one row per surface this issue touches, with the assigned test layer and expected verification (e.g., SQL logic → pgTAP cases, external API → contract tests, auth boundary → integration tests, UI flow → e2e). Format: `Verification: see test-design #N — tests [T1, T4, T7]` plus the surface→test-layer checklist. No child issue ships without its checklist.

### Step 4 — Per-Issue Review Gate

After each issue is created, dispatch a fresh-context reviewer:

```
Review this issue for:

1. EPIC COHERENCE: Does it match the epic contract? Any silent divergence?
2. TEST ALIGNMENT: Does it reference the correct E2E test cases?
3. RESEARCH ALIGNMENT: Does it incorporate relevant research findings?
4. DEPENDENCY CORRECTNESS: Are dependencies accurate and complete?
5. VERIFICATION CHECKLIST: Does the issue body reference the epic's test-design surface map and include a verification checklist derived from it (surface → test layer → expected verification)? Are any surfaces this issue touches missing from the checklist?

Return: NO ISSUES FOUND | ISSUES: <list>
```

**Resilience:** Per-issue review sub-agents may time out. Inherits retry/timeout from builtin-tools (epic #6038 Phase 4). On zero-output timeout: retry with backoff (max 3). On exhaustion: flag gap and continue ("⚠️ review for issue #N timed out — manual review needed"). Use partial-failure pattern from `parallel-orchestrator`. Never block decomposition on a single reviewer failure.

Fix-loop until clean per issue (convergence-gated, safety cap: 10 cycles (tight scope, quick convergence)).

### Step 5 — MECE Verification Gate

After ALL issues are generated and reviewed, run the MECE gate:

Dispatch a fresh-context reviewer via `task` sub-agent:

```
Verify the issue decomposition is MECE (Mutually Exclusive, Collectively Exhaustive):

Given the full epic plan and this list of issues:

<full epic plan>
<all issue titles + summaries>

CHECK:
1. MUTUALLY EXCLUSIVE: Do any two issues overlap in scope? Would implementing both create merge conflicts or duplicated work?
2. COLLECTIVELY EXHAUSTIVE: Is any part of the epic plan NOT covered by an issue? Walk through each epic section and verify coverage.
3. DEPENDENCY SOUNDNESS: Is the dependency graph acyclic? Are there circular dependencies?
4. PARALLELISM: Are independent issues correctly flagged for parallel execution?

For each gap found:
ISSUE:
  type: overlap | gap | cycle | serialization
  description: <what's wrong>
  affected_issues: <issue numbers>
  fix: <create new issue | merge issues | reorder dependencies>

Return: MECE CLEAN | ISSUES: <list>
```

**Fix-loop:** If issues found, fix (create/merge/reorder issues) and re-run MECE verification. Safety cap: 10 cycles (convergence-gated). On safety cap: log remaining gaps, proceed.

### Output

A dependency-ordered list of issues, each:
- Created via `issue-creation` skill
- Reviewed for coherence
- MECE-verified as a set

## Review Gate

The per-issue and MECE gates described above are the review mechanism. No additional terminal review needed — the MECE gate is the final quality check.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Per-issue review | Issues drift from epic contract — implementation produces features the epic didn't specify |
| Verification checklist derivation | Child issues implement surfaces with no assigned tests — integration bugs surface only at capstone time, when they're most expensive to fix |
| MECE verification | Overlapping issues → merge conflicts, duplicated work. Missing issues → feature gaps discovered during implementation |
| Dependency ordering | Issues blocked waiting for unstarted dependencies — pipeline stalls |

## Integration

**Called by:** `epic-plan` (after coherence review passes)
**Hands off to:** `epic-verify` (final pipeline gate)
**Calls:** `issue-creation` (for each child issue)
**References:** `test-design` (epic integration-surface map), `parallel-orchestrator` (review gate dispatch)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
