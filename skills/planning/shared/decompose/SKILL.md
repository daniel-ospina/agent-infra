---
disable-model-invocation: true
name: shared-decompose
description: MECE-first decomposition + child issue generation. Routes to epic-decompose.
domain: capability
subjects.team: organisation-design-team
type: Routing
status: stub
tags: [pipeline, shared, decompose]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skill and adds workflow-specific guidance.

# Decompose Stage

## Instructions

1. If no child issues needed → skip.
2. Run `epic-decompose` at proportional depth.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
