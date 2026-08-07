---
name: shared-align
description: Strategic go/no-go gate for workflows. Routes to epic-align skill.
domain: capability
type: Routing
status: stub
tags: [pipeline, shared, align]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
created: 2026-07-26
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> ⚠️ **Routing wrapper — thin by design.** Dispatches to the existing skill and adds workflow-specific guidance.

# Align Gate

Strategic alignment check before planning proceeds.

## Instructions

1. **Epic workflow:** Run `epic-align` — adversarial test + Eisenhower matrix.
2. **Project workflow:** Inherits from parent epic. If standalone, verify O/I/T alignment.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
