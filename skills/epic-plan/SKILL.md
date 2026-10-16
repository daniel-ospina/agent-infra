---
name: epic-plan
description: "Modular epic planning skill with 8 sub-steps, each with its own review gate. Replaces the monolithic epic-planning skill (now archived). Sequence: User Journeys → Workflows → Prototype → Data Model → Architecture → Interfaces → Detailed E2E → Coherence Review. Invoked after epic-scope approval."
domain: planning
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: user_journeys
    type: skill
    gate: auto
    produces: [journey_doc]
  - name: workflows
    type: skill
    gate: auto
    requires: [user_journeys]
    produces: [workflow_doc]
  - name: prototype
    type: skill
    gate: auto
    requires: [workflows]
    produces: [prototype_html]
  - name: data_model
    type: skill
    gate: auto
    requires: [prototype]
    produces: [data_model_doc]
  - name: architecture
    type: skill
    gate: auto
    requires: [data_model]
    produces: [architecture_doc]
  - name: interfaces
    type: skill
    gate: auto
    requires: [architecture]
    produces: [interface_doc]
  - name: detailed_e2e
    type: skill
    gate: auto
    requires: [interfaces]
    produces: [e2e_tests]
  - name: coherence_review
    type: parallel
    gate: verifier
    requires: [detailed_e2e]
    produces: [reviewed_plan]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

> ⚠️ **This file is authoritative.** All 8 sub-steps and their review gates are defined inline below — there are no separate `workflow/` files.

# Epic Planning (Modular)

**Announce at start:** "I'm using the epic-plan skill for detailed planning."

## Purpose

Modular skill that runs the 8 sub-steps of epic planning. Each sub-step has its own review gate with fresh-context reviewer dispatch. Quality is caught at each step, not at a single terminal coherence review.

## Pipeline

```
epic-align → epic-research → epic-scope → [THIS SKILL]
                                              ├─ 1. User Journeys
                                              ├─ 2. Workflows
                                              ├─ 3. Prototype
                                              ├─ 4. Data Model
                                              ├─ 5. Architecture
                                              ├─ 6. Interfaces
                                              ├─ 7. Detailed E2E Tests
                                              └─ 8. Coherence Review + Risk Analysis
                                                    ↓
                                              epic-decompose → epic-verify
```

## Sub-Steps

Each sub-step produces a section of the epic plan document and passes through a review gate before the next sub-step begins.

### 1. User Journeys
Detailed journey tables with persona mapping. Each journey describes a complete user flow with entry/exit states.

**Light research hook (issue #231 D11):** for UX precedent, fire 1–2 queries ONLY on a demonstrated gap (novel interaction type absent from the brief's `### UX Pattern Research`); otherwise rely on the brief. Budget mode: defer to the brief. If a light hook fires, record findings inline in the substep's plan section with a `> **Findings date:**` stamp + source AND append to the epic brief's `## Raw Notes` via `_research_append.sh` (same `--epic-path --append --source-tag` invocation contract as the heavy hooks; no gate check, but the ledger stays complete).

**Review gate:** Do journeys cover all in-scope items? Are persona-appropriate? Are edge cases (empty, error, loading) handled?

### 2. Workflows
Operational/business process flows. System-level workflows, not just user journeys. Automation points, manual intervention triggers.

**Review gate:** Do workflows align with journeys? Are handoff points clear? Are failure modes documented?

### 3. Prototype
UI prototype via `prototype-review` skill (GUI features) or markdown diagram (non-GUI features). Must have a dedicated modular skill for GUI prototype rendering.

**Review gate:** Does prototype match journeys? Are all states represented? Is design system compliant?

### 4. Data Model
Entity definitions, relationships, RLS policies, integrity constraints. Database schema design.

**Research hook (issue #231 D11):** before drafting, if the brief is too broad for this decision (novel schema pattern, new integration, RLS complexity beyond the brief's coverage), fire 1–3 targeted external queries (canonical schema pattern / competitor-precedent / pitfalls) and persist the output as a `### Data Model Research Notes` block in the epic plan doc with a `> **Findings date:**` stamp + per-framing provenance, deduped against the epic brief, **and append each finding to the epic brief's `## Raw Notes` via `bash scripts/_research_append.sh --epic-path <brief-path> --append "<text>" --source-tag <framing>`** (the ledger is the source of truth; the plan-doc block is the derived view — research-protocol §13). Under `EXECUTION_INTENT=Budget`: defer to the brief (zero external queries).

**Review gate:** Does data model support all workflows? Are RLS policies complete? Are integrity constraints enforced at DB level? **Research check:** if the hook fired, is `### Data Model Research Notes` present (or a justified skip — brief already covers at sufficient granularity, with a section citation) AND is there a corresponding `## Raw Notes` entry in the epic brief?

### 5. Architecture
Target state, component boundaries, system interfaces. Deployment topology, service communication patterns.

**Research hook (issue #231 D11):** before drafting, if the brief is too broad for this decision (novel architecture pattern, new service/integration, failure-mode design beyond the brief's coverage), fire 1–3 targeted external queries (canonical architecture pattern / competitor-precedent / pitfalls) and persist the output as a `### Architecture Research Notes` block in the epic plan doc with a `> **Findings date:**` stamp + per-framing provenance, deduped against the epic brief, **and append each finding to the epic brief's `## Raw Notes` via `bash scripts/_research_append.sh --epic-path <brief-path> --append "<text>" --source-tag <framing>`** (the ledger is the source of truth; the plan-doc block is the derived view — research-protocol §13). Under `EXECUTION_INTENT=Budget`: defer to the brief (zero external queries).

**Review gate:** Are boundaries clean? Are interfaces well-defined? Are failure modes addressed (circuit breakers, retries)? **Research check:** if the hook fired, is `### Architecture Research Notes` present (or a justified skip — brief already covers at sufficient granularity, with a section citation) AND is there a corresponding `## Raw Notes` entry in the epic brief? **Duplication & whole-architecture check (#688):** dispatch the `duplication-architecture` reviewer (read `skills/reviewers/duplication-architecture/SKILL.md` in full) against the drafted architecture. It asks whether this architecture duplicates a capability, write path, vocabulary, or pattern that already exists — and whether the whole is still coherent with this component added, not merely whether this component is internally sound. Every duplication finding carries a three-valued verdict: `unify` | `keep separate` | `unify-contract-keep-drivers`. **Return the skill's own output block verbatim** (Evidence / Writers / Shared contract / Verdict). Advisory, never blocking — **and it does NOT enter the Review Gate Pattern below**; see the disposition table under that pattern. Tortoise is one source among several and never the only one.

### 6. Interfaces
API contracts, event schemas, type definitions. Contract-first design — define interfaces before implementation.

**Light research hook (issue #231 D11):** for interface-contract patterns, fire 1–2 queries ONLY on a demonstrated gap (new API style / contract format absent from the brief); otherwise rely on the brief. Budget mode: defer to the brief. If a light hook fires, record findings inline in the substep's plan section with a `> **Findings date:**` stamp + source AND append to the epic brief's `## Raw Notes` via `_research_append.sh` (same `--epic-path --append --source-tag` invocation contract as the heavy hooks; no gate check, but the ledger stays complete).

**Review gate:** Are contracts complete? Are error responses defined? Is versioning strategy clear?

### 7. Detailed E2E Test Cases
Fully fleshed-out test cases aligned with high-level E2E tests from `epic-scope`. Each test case is detailed enough to be implemented as an automated test.

**Review gate:** 3 parallel reviewers dispatched:
- `reviewers/e2e-coverage` — do detailed tests cover all high-level scenarios?
- `reviewers/e2e-reproducibility` — can each test be executed (concrete setup, verifiable assertions)?
- `reviewers/test-quality` — do tests verify user-visible outcomes (not just implementation details)? Are negative cases covered? Are known brittleness anti-patterns present?

The reviewer list above is authoritative for the 3-reviewer dispatch.

### 8. Coherence Review + Risk Analysis
Cross-substep drift detection. Risk identification with mitigation strategies. Improvement opportunities.

**Review gate (FINAL):** Is the plan internally consistent? Are risks identified and mitigated? Is the plan ready for decomposition? **Final duplication re-check (#688):** re-run the `duplication-architecture` reviewer across the *finished* plan. Substep 5 saw the architecture in isolation; by step 8 the data model, interfaces, and E2E steps have each added surfaces that can duplicate — and a second writer of state already written elsewhere is the failure this catches. Any duplication found here carries a three-valued verdict: `unify` | `keep separate` | `unify-contract-keep-drivers`. Same contract as substep 5: skill's output block verbatim, advisory, outside the Review Gate Pattern below.

## Review Gate Pattern

Every sub-step review follows the same pattern:

1. Dispatch fresh-context reviewer via `task` sub-agent
2. Reviewer returns: "NO ISSUES FOUND" or ISSUES: <list>
3. If issues: fix, re-dispatch (convergence-gated; safety cap: 10 cycles per sub-step)
4. If clean: proceed to next sub-step
5. If convergence at safety cap (10 cycles): log remaining issues, proceed with warning

### ⚠️ The duplication reviewer is NOT part of this pattern

The `duplication-architecture` reviewer is **advisory** and must never be fed into the loop above. Two concrete reasons:

1. **The pattern's `NO ISSUES FOUND` test is a bare substring match** and the duplication reviewer returns that token *plus* a qualifier when a source was unavailable (`NO ISSUES FOUND — DEGRADED (<source>)`). Feeding it into step 2 would read a degraded run as clean — the exact false-negative this reviewer exists to prevent.
2. **Step 3's "fix, re-dispatch" would make an advisory check blocking**, contradicting the reviewer's own contract ("a gate that feeds this output into a blocking fix-loop has inverted the contract"), and would spend the 10-cycle budget on non-blocking findings.

**Disposition — controller-level, outside the loop:**

| Result | Action |
|---|---|
| `NO ISSUES FOUND — CLEAN` | Record verdicts in the plan doc. Proceed. |
| `NO ISSUES FOUND — DEGRADED (<source>)` | Record + name the unavailable source in the plan doc. **Not clean, not blocking.** Proceed with the caveat. |
| `ISSUES:` with a verdict | Record each verdict. `unify` → fold into the plan. `keep separate` / `unify-contract-keep-drivers` → record the **reason**. |
| `ISSUES:` with **no** verdict | Invalid result. Re-dispatch once; if it repeats, record `⚠️ reviewer returned unverdict findings` and proceed. |
| bare `NO ISSUES FOUND` (no qualifier) | **Not accepted as clean.** The skill's clean token is `NO ISSUES FOUND — CLEAN`. Re-dispatch once requiring the qualified token; if the bare form repeats, read the summary block's `Result:` line — treat as `DEGRADED (unqualified)` unless it names a full-clean result, and proceed. |

**Never re-dispatch a step reviewer because the duplication reviewer found something**, and never hold a subs-step gate open on its findings. Its `P0` is advisory severity, not blocking severity. Record it and proceed; the finding survives into the plan doc as a decision the owner can act on.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Per-step review gates | Quality issues caught at coherence review (Phase 8) after 7 steps of accumulated drift — expensive rework |
| Fresh-context reviewers | Same-model self-review — confirmation bias, missed issues |
| Sub-step sequencing | Data model designed before workflows → schemas that don't match real flows |

## Integration

**Called by:** Issue pipeline (after `epic-scope` approval)
**Hands off to:** `epic-decompose` (issue generation)
**Calls:** `epic-align`, `epic-research`, `epic-scope` (earlier pipeline stages)
**Calls:** `prototype-review` (sub-step 3, GUI features)
**References:** `parallel-orchestrator` (review gate dispatch pattern)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
