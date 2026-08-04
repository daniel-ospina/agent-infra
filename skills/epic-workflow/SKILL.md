---
name: epic-workflow
description: Fractal planning pipeline for epics. Routes through 6 stages (Align → Research → Scope → Plan → Decompose → Verify) at full depth with all review gates, E2E tests, MECE-first decomposition, and 3 human gates.
type: Workflow
domain: capability
status: live
tags: [pipeline, epic, planning, fractal, orchestrator]
summary: "Top-level Workflow skill that routes an epic through all 6 pipeline stages at full depth."
created: 2026-07-07
updated: 2026-07-07
steps:
  - name: align
    type: skill
    gate: verifier
  - name: research
    type: skill
    gate: verifier
    requires: [align]
  - name: scope
    type: skill
    gate: human_approval
    requires: [research]
  - name: plan
    type: skill
    gate: human_approval
    requires: [scope]
  - name: decompose
    type: skill
    gate: verifier
    requires: [plan]
  - name: verify
    type: skill
    gate: verifier
    requires: [decompose]
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.



# Epic Workflow

Routes an epic through the full 6-stage fractal planning pipeline. Each stage invokes a Bounded sub-skill under `planning/shared/`. All review gates run at full depth.

## Pipeline

> Sub-skills live under `../planning/shared/`. Directory scaffolding exists; individual skills are built by epic #5872.

1. **Align** — `shared/align/SKILL.md` — Strategic go/no-go gate (full adversarial + Eisenhower)
2. **Research** — `shared/research/SKILL.md` — Research wrapper (full research brief)
3. **Scope** — `shared/scope/SKILL.md` — Scope + high-level E2E (all key functionality)
4. **Plan** — `shared/plan/SKILL.md` — 8 planning substeps with full review gates
5. **Decompose** — `shared/decompose/SKILL.md` — MECE-first + wiring + verification issues. Uses `issue-creation` skill for child issue generation.
6. **Verify** — `shared/verify/SKILL.md` — Pre + post-deploy verification

**Reflect** — `operations/memory/reflect.py` runs automatically at session end via `reflect-hook.ts`. Cross-cutting: fires at epic completion, project close, and session quit. Produces AAR postmortem + classified friction events. See ONTOLOGY.md §2.6 (Reflect action).

## Human Gates

### Approval Routing

When a human gate fires, the agent MUST invoke the approval router to surface the request:

```bash
# For human bypass (default for epic gates):
APPROVAL_NO_NOTIFY=0 python3 -c "
from operations.coordination.approval import request_approval
request_approval('product-strategist', artifact='<doc-name>.md', context='<stage> approval for epic <name>', requires_human=True)
print('Approval request created — osascript dialog fired')
"
```

This triggers an osascript dialog on the human's machine. The pipeline advances after the human approves via `review_approval()`. If osascript is unavailable (non-macOS, CI, SSH), the approval is logged to `operations/coordination/approvals.json` and must be checked manually.

**Response mechanism:** The human clicks "Open" or "Dismiss" on the dialog. The agent monitors `pending_approvals('human')` to detect the response. See `operations/coordination/approval.py` for the full API.

**Role-based escalation** (for non-epic gates): use without `requires_human=True` to route through the VSM hierarchy (product-implementer → product-strategist → team-strategist → human).

1. After Scope — docs committed, GitHub URL presented
2. After Planning coherence — docs committed, GitHub URL presented

> **Decomposition gate** is now an AI review gate (not human) — same review+fix loop pattern as other stages.

### Gate Verification (between stages)

**After completing each stage, before advancing to the next, the agent MUST verify the previous review gate was cleared.**

```
Before Stage N:
  ☐ Previous stage output exists (doc committed, issue updated)
  ☐ Review gate result recorded (NO ISSUES FOUND or issues fixed + documented)
  ☐ If skipped: reason documented in plan doc
  ☐ If missing: GO BACK and complete the previous stage's review gate

⛔ HARD STOP: Do not proceed if the previous gate is incomplete.
```

This checkpoint runs at the start of every stage (2-6). The agent must explicitly confirm before stage execution begins.

### UX Design Gate (between Scope and Plan)

After Scope approval (Human Gate #1) and before Plan (Stage 4): invoke `ux-design-review` skill when `UX_RATING ≥ medium`. This gate classifies UX decisions, presents structured options, and records user choices. It does NOT block — it surfaces and records.

> **ponytail:** wired inline until `shared/plan/SKILL.md` is built (#5872). Extract to sub-skill when scaffolding is complete.

## Entity Mapping

| Stage | Produces | Entity Class |
|-------|----------|-------------|
| Align | Align Decision | Decision (#17) |
| Research | Research Brief | ResearchBrief (#21) |
| Scope | Scope Brief + E2E Tests | Brief (#22) |
| Plan | Implementation Plan | Plan (#23) |
| Decompose | Child Issues + Wiring | Features (#15) + Tasks (#30) |
| Verify | Verification Proof | Proof (#24) |
| Reflect | ReflectDoc + FrictionEvents | Reflect (#50) |

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
