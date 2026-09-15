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
  ├─ Declare the domain: `### Adversarial Threat Surface`, or an explicit `(not adversarial)`
  │
  ▼
SCOPE-VERIFY (gate: verifier — blocks write/edit/bash)
  │
  ├─ Dispatch the tier's scope verifier(s) — count per issue-scoping §Tier Scaling
  ├─ Each reviews: problem definition, alternatives, complexity
  ├─ If issues found → fix → re-dispatch
  ├─ Loop until ALL verifiers return NO ISSUES FOUND
  │     (adversarial domain: `THREAT SURFACE COVERED`, bounded at 2 cycles — see below)
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
  ├─ Dispatch the plan reviewer(s) — count per `proportional-gates` §Review Cycles
  ├─ Each reviews: approach soundness, step clarity, integration surfaces
  ├─ If issues found → fix → re-dispatch
  ├─ Loop until ALL plan reviewers return NO ISSUES FOUND
  │     (adversarial domain: `THREAT SURFACE COVERED`, bounded at 2 cycles — see below)
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

1. **Dispatch the gate's own count** via the `task` tool — scope: `issue-scoping` §Tier Scaling; plan: `proportional-gates` §Review Cycles; verify: `verification-before-completion` (one verifier sub-agent)
2. Each dispatched agent returns structured output with `NO ISSUES FOUND` or an issue list — **every issue must declare `consequence: <what breaks, who observes it>`** (canonical: `proportional-gates` §Findings Must Declare Consequence). An issue without an adequate consequence is **advisory**: it does not block this gate, is not counted, and is not filed as an issue.
3. The gate stays locked (blocks write/edit/bash/MCP) until ALL dispatched agents return clean — where "clean" means each gate's own clean token, never a count, and never a substring of a qualified token
4. If any agent finds a **blocking** issue → fix it → re-dispatch ALL
5. Only `NO ISSUES FOUND` from every dispatched agent advances the gate (adversarial domain: `THREAT SURFACE COVERED` substitutes — see below)

**Conformance floor.** A round that returns ≥1 issue and **none** carrying an adequate `consequence:` is malformed reviewer output, not clean: record `⚠️ reviewer returned N consequence-less findings`, re-dispatch once, and exit the gate **non-clean**. Where this gate's bound is already spent, record the marker and exit non-clean without the extra dispatch — the floor never widens a bound (`AGENTS.md` §Hard Cap counts every dispatch as a round).

**The gate does NOT advance on dispatch count alone.** Verifier content is checked. A verifier that finds issues keeps the gate locked so the agent must fix and re-verify.

### Adversarial domain — bounded verifier gates

When the scope output declares an `### Adversarial Threat Surface` (gate/enforcement code whose correctness is "an attacker cannot make it fail open"), the verifier gates are bounded by that declared surface, not by reviewer exhaustion: **cap 2 cycles**, acceptance = every declared threat class covered by a test + green CI, residuals **filed from cycle 1, not chased**. A verifier that reproduces no in-scope bypass and confirms each declared class is covered returns **`THREAT SURFACE COVERED`** — a clean exit for this domain, substituting for `NO ISSUES FOUND`. When the merge rests on threat-list coverage rather than a literal `NO ISSUES FOUND`, the PR body must disclose it (`[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=<#N,…|none>`). Statement of record: `AGENTS.md` §Hard Cap. <!-- adversarial-bound: cap=2 -->

## Nudge Protocol

When the agent first reads this skill, the sequence-enforcer shows:

```
🔒 Scope-verify gate ahead — you will need to dispatch the tier's scope verifier(s).
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
| Scope/plan gates | Verifiers per the gate's own skill | Human approval + shared sub-skills, MECE decompose, wiring |

**Escalation rule:** if Scope (via `issue-scoping`) reveals the task actually needs **MECE decomposition into child issues, wiring, or E2E** → escalate to `project-workflow` instead. A task-level standard/complex issue stays here while it remains one deliverable.

> Note: issues created without fractal fields fall back by complexity — `complexity:standard|complex` → Level `project` → `project-workflow`. An explicit `Level: task` field is what routes to this skill.

## Key Principles

- **Scope before plan before code.** Mechanical enforcement. No shortcuts.
- **Verifier quality over dispatch count.** A verifier that actually reviews beats one that signs off, and independent conclusions beat a single pass wherever the tier's count allows it.
- **Loop until clean.** Fix-and-reverify is the expected pattern. The gate stays locked until it's right.
- **Proportional depth.** Complex issues get deeper research in issue-scoping. Standard gets lighter passes. The pipeline is the same; the sub-skills scale depth.
- **Research path (issue #231 D11).** A standard/complex task's research = issue-scoping Phase 1.5's `### Axis Research`/`### Integration Docs` artifact (scoping stage) + writing-plans Step B's `### Pattern Research` re-derivation at the concrete plan level (planning stage). Both are fresh-query surfaces at their own granularity — the scoping artifact is PRIOR_RESEARCH for planning, never a substitute.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
