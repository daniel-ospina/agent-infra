---
name: define-team-vision
description: "Team Strategist role (S4). Produces Team Vision — environment scan, positioning options, destination — through parallel research and synthesis."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Define Team Vision

Produces the Team Vision artifact. Vision is the conclusion of environmental scanning — trends, competitors, and opportunity — synthesized into a destination. Vision stays thin: positioning and direction. Strategy handles execution.

## Process

### Phase 1 — Research (Parallel)

Dispatch three parallel research sub-agents. Each MUST use the `research` skill for complex, multi-source investigation — not quick web_search calls. Superficial research produces weak visions. Each produces a separate research doc with data-backed claims:

**Trends Research:**
```
Use the research skill for complex investigation. Research how the world is changing in the domain this team operates in.
Map the progression stages — what stages have been reached, what's next.
For each claim, include a data point (percentage, year, source).
Output to management/future (S4)/research/trends.md
```

**Market/Competitor Research:**
```
Use the research skill for complex investigation. Broad scan of the competitive landscape. Who else operates in this space?
What segments exist? Where are the gaps? Include market data:
build-vs-buy preferences, failure rates, adoption percentages.
Output list to management/future (S4)/research/competitors.md
```

**Internal/Stakeholder Research:**
```
Use the research skill for complex investigation. What do internal stakeholders need? What do existing teams lack?
What would make them adopt this? Be specific — avoid generic needs.
Output to management/future (S4)/research/stakeholders.md
```

### Phase 2 — AI Review Gates (per research doc)

For each research output, dispatch a reviewer. Check:
- Trends: are claims backed by data? Is the progression logical? Are sources cited?
- Competitors: are all segments covered? Are gaps correctly identified? Is market data referenced? Is vendor lock-in risk assessed?
- Stakeholders: are needs specific? Are there missing stakeholders? Are needs data-backed?

**Data-backed rule:** Claims without supporting data must be flagged. "Many teams struggle" → P2. "50% of agents operate in isolation (Gartner, 2025)" → acceptable.

Fix issues and re-dispatch until "NO ISSUES FOUND."

### Phase 3 — Synthesis

Pull all three research docs into a coherent team vision. Use this mapping:

| Research Finding | Maps To | Vision Element |
|-----------------|---------|---------------|
| Trend progression stages | → | Opportunity — what stage is next? Why now? |
| Competitor gaps, build-vs-buy data | → | Offering — what gap do we fill? Why buy vs build? |
| Stakeholder needs, adoption data | → | Sustainability — who pays? How is this viable? |
| Market size, failure rates | → | Positioning Options — where do we position? |

**Progression Framework:** Map the domain's progression as stages (1 through N). Show which stages are mainstream, emerging, leading edge, and missing. The missing stage IS the opportunity.

**Positioning Options:** Options are about WHERE to position in the environment, not HOW to execute. Internal-first vs open-source vs service vs venture studio. Each option is a distinct positioning choice.

**Vision (Destination):** The selected positioning expressed as a future state. Not phases. Not execution. The world as it should be.

### Phase 4 — AI Review Gate

Dispatch a reviewer on the complete vision doc:
- Does the opportunity follow logically from the research data?
- Are the progression stages accurately mapped?
- Are positioning options distinct and non-trivial? Does positioning address vendor lock-in risk?
- Is the vision a destination, not a plan?
- Are claims data-backed?

Fix issues and re-dispatch until clean.

### Phase 5 — Human Approval Gate

Human reviews the vision. May select a positioning option, request additional research, or send back for revisions. This is the S4→S5 handoff. The vision proposes; S5 selects.

### Phase 6 — File

Vision doc → `management/future (S4)/<name>-vision.md`
Research docs → `management/future (S4)/research/trends.md`, `competitors.md`, `stakeholders.md`

---

Continue following the workflow as mandated by this skill. Do not skip steps.
