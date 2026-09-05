---
disable-model-invocation: true
name: shared-verify
description: Pre + post-deploy verification gate. Epic → epic-verify, Project → verification-before-completion.
domain: capability
subjects.team: organisation-design-team
type: Routing
status: stub
tags: [pipeline, shared, verify]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skills and adds workflow-specific guidance.

# Verify Stage

## Instructions

1. **Epic workflow:** Run `epic-verify` — cross-phase coherence, E2E alignment, artifacts.
2. **Project workflow:** Run `verification-before-completion` — typecheck, tests, deploy check.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
