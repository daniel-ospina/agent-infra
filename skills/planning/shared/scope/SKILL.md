---
name: shared-scope
description: Scope + E2E proportional to issue size. Routes to issue-scoping.
domain: capability
type: Routing
status: stub
tags: [pipeline, shared, scope]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skill and adds workflow-specific guidance.

# Scope Stage

## Instructions

1. Project workflow → `issue-scoping` with standard depth.
2. Epic workflow → `epic-scope` with full depth (E2E before journeys).
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
