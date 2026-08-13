---
name: define-team-strategy
description: "Team Strategist role (S3). Produces Team Strategy — sustainability, resource allocation, phase sequencing. Monitors Product Roadmap progress."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.



# Define Team Strategy

Produces the Team Strategy artifact. Answers: how do we get there and sustain ourselves? Output is consumed by `define-product-strategy` — product strategy operates within team-level constraints. Also extracts a Team Roadmap from the strategy — a context-efficient summary of phases for the Coordinator. Strategy = epistemic (logic, reasoning). Roadmap = coordination document (just the phases, no arguments).

## Process

### 1. Read Team Vision
Load the team vision doc: offering, sustainability model, phase vision.

### 2. Define Sustainability Approach
How is this team sustained? Self-funded? Bootstrapped by Daniel? Revenue from external teams? What's the runway?

### 3. Phase Sequencing
What order do we tackle phases? Internal first → DMer → rollout → externalize. What's the logic?

### 4. Progress Check
Read the *prior cycle's* Product Roadmap (if exists) to check execution progress. Are we on track? Behind? Ahead? Use this as feedback input — flag adjustments if needed before setting the next cycle's strategy.

### 5. Produce Artifacts
- **Team Strategy doc:** sustainability model + phase sequencing + progress assessment (epistemic)
- **Team Roadmap:** extracted from the strategy. Context-efficient — no strategic arguments, just phases and what happens when. The Roadmap is a derivative of the Strategy, not a separate creative process. It is the coordination document for the Coordinator.

### 6. AI Review Gate
Dispatch fresh task sub-agent. Check:
- Is the sustainability model realistic? Are cost and revenue numbers supported?
- Are phases correctly sequenced? Does the order follow logically from the vision?
- Does the strategy leverage competitor research from the vision process? Are competitive insights applied?
- If competitor research has gaps, flag them — they must be filled upstream (in vision), not skipped.
- Does the roadmap accurately extract the phases from the strategy?

### 7. Human Approval Gate
Human approves Team Strategy and Team Roadmap.

### 8. File
Team Strategy → `management/change (S3)/<name>-strategy.md`
Team Roadmap → extracted from strategy → `management/change (S3)/<name>-roadmap.md`

---

Continue following the workflow as mandated by this skill. Do not skip steps.
