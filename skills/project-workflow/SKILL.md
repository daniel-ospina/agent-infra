---
name: project-workflow
description: Fractal planning pipeline for projects (standard/complex issues). Routes through 6 stages with proportional depth — inherits Align from parent Epic, runs proportional review gates.
type: Workflow
domain: capability
status: live
tags: [pipeline, project, planning, fractal, orchestrator]
summary: "Workflow skill that routes a project through the 6-stage pipeline at proportional depth."
created: 2026-07-07
updated: 2026-08-08
steps:
  - name: inherit_align
    type: skill
    gate: auto
  - name: research
    type: skill
    gate: verifier
    requires: [inherit_align]
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

# Project Workflow

Routes a project (standard/complex issue) through the 6-stage pipeline at proportional depth. Sub-skills are the same as epic-workflow — the Workflow determines the depth.

## Branch Isolation (runs BEFORE Phase 1)

> ⛔ **Every issue gets its own branch.** This prevents the 2026-08-06 incident where #74's work committed onto #73's branch.

Before any work begins, verify branch isolation:

```bash
ISSUE_NUMBER="<N>"              # from the issue being worked
SLUG="<kebab-slug>"             # brief slug from issue title
EXPECTED_BRANCH="feat/${ISSUE_NUMBER}-${SLUG}"
CURRENT=$(git branch --show-current)

[ "$CURRENT" = "$EXPECTED_BRANCH" ] && exit 0   # already on correct branch

if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  git checkout -b "$EXPECTED_BRANCH"
  exit 0
fi

# Detached HEAD? ABORT — no branch to verify
if [ -z "$CURRENT" ]; then
  echo "⛔ ABORT: Detached HEAD. Checkout main first: git checkout main && git checkout -b $EXPECTED_BRANCH"
  exit 1
fi

# ABORT: on a DIFFERENT issue's branch (boundary match prevents #76 matching #760)
if ! echo "$CURRENT" | grep -qE "(^|/)$ISSUE_NUMBER(-|\$)"; then
  echo "⛔ ABORT: On branch $CURRENT (different issue). Switch to main first, then create $EXPECTED_BRANCH."
  exit 1
fi
```

> When dispatching parallel subagents, each must get its own worktree — see `skills/issue-workflow/SKILL.md` Branch+Worktree Isolation section for the full pattern.

## Pipeline

> Sub-skills live under `../planning/shared/`. Directory scaffolding exists; individual skills are built by epic #5872.

1. **Align** — Inherited from parent Epic. Only runs if standalone.
2. **Research** — `shared/research/SKILL.md` — Targeted research (appends to epic brief if exists)
3. **Scope** — `shared/scope/SKILL.md` — Scope + E2E proportional to project size
4. **Plan** — `shared/plan/SKILL.md` — Proportional substeps (skip prototype if no GUI; 2-3 reviewers vs 1-3)
5. **Decompose** — `shared/decompose/SKILL.md` — MECE-first + wiring + verification (if project has child issues). Uses `issue-creation` skill.
6. **Verify** — `shared/verify/SKILL.md` — Proportional verification

## Human Gates (if standalone)

Same 3-gate pattern as epic, but proportional — faster review cycles:
1. After Scope
2. After Planning coherence
3. After Decomposition

### UX Design Gate (between Scope and Plan)

After Scope approval and before Plan (Stage 4): invoke `ux-design-review` skill when `UX_RATING ≥ medium`. Proportional — lighter review than epic-level.

> **ponytail:** wired inline until `shared/plan/SKILL.md` is built (#5872). Extract to sub-skill when scaffolding is complete.

## Align Inheritance

When the project is linked to an Epic (issue body has `**Epic:** docs/epics/...`):
- The Align gate is **skipped** — the parent Epic's Align Decision covers this project
- If the parent Epic has no Align Decision, the Align gate runs for the project

When the project is standalone (no parent Epic):
- Full Align gate runs via `shared/align/SKILL.md` — adversarial test + Eisenhower matrix

## Proportional Rules

| Epic Depth | Project Depth |
|------------|--------------|
| Full adversarial + Eisenhower | Adversarial lite (2 challenges) |
| Full research brief (6+ queries) | Targeted research (2-3 queries) |
| 8 planning substeps | Proportional substeps (skip irrelevant) |
| 4 parallel reviewers | 2-3 reviewers |
| Full E2E test suite | Key-journey E2E only |

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
