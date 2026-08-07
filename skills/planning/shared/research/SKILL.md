---
name: shared-research
description: Research wrapper for workflows. Routes to research skill with proportional depth.
domain: capability
type: Routing
status: stub
tags: [pipeline, shared, research]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skill and adds workflow-specific guidance.

# Research Stage

## Instructions

1. If parent has existing brief → append findings.
2. Otherwise run `research` skill: Medium depth for projects, Deep for epics.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
