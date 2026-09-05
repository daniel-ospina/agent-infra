---
name: task-workflow-standard
description: Gated fractal pipeline for standard+complex tasks. Routes through all 6 stages with verifier gates at scope and plan — no implementation without verified design.
type: Workflow
domain: capability
subjects.team: organisation-design-team
status: live
tags: [pipeline, task, planning, fractal, orchestrator, standard, complex]
summary: "Workflow skill for standard+complex tasks — scope → plan → implement → verify with verifier gates at each design stage."
created: 2026-07-30
updated: 2026-08-07
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Verifier gates are MANDATORY. Skipping them allows unverified design through to implementation.

# Task Workflow (Standard+Complex)

Routes a standard or complex task through the full 6-stage pipeline with verifier gates at scope and plan. Implementation is mechanically blocked until design is verified.

> Dispatched by `issue-workflow` for `Level: task` issues with `complexity:standard` or `complexity:complex` (or missing/unknown complexity — fail-closed). See `issue-workflow/SKILL.md` dispatch table.

## Pipeline

```
SCOPE (gate: auto)
  │
  ├─ Read issue-scoping/SKILL.md
  ├─ Run double diamond: problem → solution
  ├─ Write scope output (issue comment or plan doc)
  │
  ▼
SCOPE-VERIFY (gate: verifier — blocks write/edit/bash)
  │
  ├─ Dispatch 2 parallel scope verifier sub-agents
  ├─ Each reviews: problem definition, alternatives, complexity
  ├─ If issues found → fix → re-dispatch
  ├─ Loop until ALL verifiers return NO ISSUES FOUND
  │
  ▼
PLAN (gate: auto)
  │
  ├─ Read writing-plans/SKILL.md
  ├─ Draft implementation plan (design decisions, task breakdown)
  ├─ Run plan-review gate internally
  │
  ▼
PLAN-VERIFY (gate: verifier — blocks write/edit/bash)
  │
  ├─ Dispatch 2 parallel plan verifier sub-agents
  ├─ Each reviews: approach soundness, step clarity, integration surfaces
  ├─ If issues found → fix → re-dispatch
  ├─ Loop until ALL verifiers return NO ISSUES FOUND
  │
  ▼
IMPLEMENT (gate: auto)
  │
  ├─ write/edit/bash unlocked
  ├─ Follow executing-plans or implement directly
  │
  ▼
VERIFY (gate: verifier — blocks write/edit/bash)
  │
  ├─ Read verification-before-completion/SKILL.md
  ├─ Typecheck + tests + targeted verification
  └─ All checks pass → done
```

## Verifier Gate Protocol

At each verifier gate (scope-verify, plan-verify, verify):

1. **Dispatch 2 parallel verifier sub-agents** via the `task` tool
2. Each verifier returns structured output with `NO ISSUES FOUND` or an issue list
3. The gate stays locked (blocks write/edit/bash/MCP) until ALL dispatched verifiers return clean
4. If any verifier finds issues → fix them → re-dispatch ALL verifiers
5. Only `NO ISSUES FOUND` from every verifier advances the gate

**The gate does NOT advance on dispatch count alone.** Verifier content is checked. A verifier that finds issues keeps the gate locked so the agent must fix and re-verify.

## Nudge Protocol

When the agent first reads this skill, the sequence-enforcer shows:

```
🔒 Scope-verify gate ahead — you will need to dispatch 2 parallel scope verifiers.
   The gate blocks write/edit/bash until all verifiers return clean.
   Fix-and-reverify loops are expected. Do not bypass.
```

This ensures the agent knows what's coming before hitting the gate.

## Relationship to project-workflow

Both this skill and `project-workflow` gate standard/complex work — the difference is **Level**:

| | `task-workflow-standard` | `project-workflow` |
|---|---|---|
| Level | `task` | `project` |
| Deliverable | Single atomic deliverable | Multi-deliverable, decomposes into child issues |
| Scope/plan gates | 2 parallel verifiers (scope + plan) | Human approval + shared sub-skills, MECE decompose, wiring |

**Escalation rule:** if Scope (via `issue-scoping`) reveals the task actually needs **MECE decomposition into child issues, wiring, or E2E** → escalate to `project-workflow` instead. A task-level standard/complex issue stays here while it remains one deliverable.

> Note: issues created without fractal fields fall back by complexity — `complexity:standard|complex` → Level `project` → `project-workflow`. An explicit `Level: task` field is what routes to this skill.

## Key Principles

- **Scope before plan before code.** Mechanical enforcement. No shortcuts.
- **Verifier quality over dispatch count.** 2 verifiers that actually review > 1 that says "looks good."
- **Loop until clean.** Fix-and-reverify is the expected pattern. The gate stays locked until it's right.
- **Proportional depth.** Complex issues get deeper research in issue-scoping. Standard gets lighter passes. The pipeline is the same; the sub-skills scale depth.
- **Research path (issue #231 D11).** A standard/complex task's research = issue-scoping Phase 1.5's `### Axis Research`/`### Integration Docs` artifact (scoping stage) + writing-plans Step B's `### Pattern Research` re-derivation at the concrete plan level (planning stage). Both are fresh-query surfaces at their own granularity — the scoping artifact is PRIOR_RESEARCH for planning, never a substitute.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
