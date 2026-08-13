---
name: define-product-vision
description: "Product Strategist role (S4). Produces Product Vision — V1 scope, positioning vs competitors, what to be/build."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.



# Define Product Vision

Produces the Product Vision artifact. Answers: what's in V1, how do we position vs competitors, what to be/build? Vision stays thin — positioning and scope, not build order. Strategy handles execution.

## Process

### 1. Read Context
Load the Team Vision (produced by `define-team-vision`) and Subject Identity for domain context. The Subject Identity provides the guiding question this product vision must align with.

### 2. Market Positioning
Where do we fit vs competitors? What's our unique angle? What do we choose to be/build?

### 3. Competitor Landscape
What are others doing? What justifies building? What can we learn?

### 4. V1 Scope
What specific pieces are in V1? Shared state, Memory Orchestrator, gates, Coordinator, define-* skills, Slack UI, self-healing, observability. Keep it thin — no build order.

### 5. Options
Propose distinct V1 scopes or positioning options to S5. The skill proposes, S5 selects.

### 6. AI Review Gate → Human Approval Gate → File
Output → `management/future (S4)/<name>-product-vision.md`

---

Continue following the workflow as mandated by this skill. Do not skip steps.
