---
disable-model-invocation: true
name: cross-substep-drift
description: Detects inconsistencies across epic substeps through forward, reverse, and cross-reference passes. Use during Coherence Review for all complexity axes. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Cross-Substep Drift

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

The fractal planning pipeline generates substeps independently, and each substep may introduce assumptions that diverge from earlier decisions. This reviewer runs forward, reverse, and cross-reference passes across the entire epic to detect drift before the plan reaches implementation.

## When Used

Dispatched by the fractal planning pipeline during the **Coherence Review** phase, after all substeps are complete. Applies regardless of complexity axis ratings — coherence review runs for all epics.

## Inputs Required

- **Full epic doc** — all substep outputs: Problem Statement, User Journeys, Workflows, Data Model, Architecture, Interfaces, Detailed E2E, Risks
- **Parent epic doc** (if child epic) — for cross-epic drift detection

## Checks to Run

### P0 — Must Fix

**CSD1 — Forward drift (earlier → later):**
- A decision or constraint stated in an early substep is contradicted or silently changed in a later substep
- E.g., Workflows say "user must be verified" but Interfaces allow unverified users
- Trace forward: for each early decision, verify later substeps respect it

**CSD2 — Reverse drift (later → earlier):**
- A later substep introduces a concept, entity, or constraint that should have been present in earlier substeps but isn't
- E.g., Architecture introduces a "Notification Service" that User Journeys never mention
- Trace reverse: for each new concept in later substeps, verify earlier substeps acknowledge it

### P1 — Should Fix

**CSD3 — Cross-reference mismatch:**
- Two substeps reference the same entity/flow/state but describe it differently
- E.g., Data Model says "Order.status: enum(pending, confirmed, shipped)" but Workflows describe "Order.state: draft → review → complete"
- Flag with both references and the divergence

**CSD4 — Assumption cascade:**
- A substep builds on an assumption from an earlier substep that was marked as tentative or unresolved
- Flag the assumption chain with confidence levels

### P2 — Should Fix (blocks merge)

**CSD5 — Redundant specification:**
- Same detail specified in multiple substeps — creates maintenance burden if one copy drifts
- Flag with suggestion to consolidate to canonical location

**CSD6 — Implicit dependency across substeps:**
- Substeps ordered in a way that implies a dependency, but the dependency isn't stated
- Flag with suggestion to make explicit

## Output Format

```
ISSUE #N
Dimension: Cross-Substep Drift
Severity: P0 | P1 | P2
Location: [substep A, section X] → [substep B, section Y]
Problem: [what drifted between substeps]
Fix: [which version is correct, or what to reconcile]
```

End with:
```
CROSS-SUBSTEP DRIFT REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Forward drifts: [count]
Reverse drifts: [count]
Cross-reference mismatches: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
