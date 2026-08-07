---
name: define-vision
description: "Defines S4 (Vision) artifacts — environmental scan, competitor research, brainstorming, options — for any function, team, or role."
domain: capability
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---

# Define Vision (S4) [DEPRECATED]

> ⚠️ **DEPRECATED.** Split into `define-team-vision` (offering, sustainability, phases) and `define-product-vision` (V1 scope, positioning vs competitors). This skill is preserved for reference. Use the new skills.

Produces the S4 Vision artifact for any function/team/role. The vision is a directional hypothesis structured by Three Horizons, with distinct options proposed to S5. Human intuition leads the process; research validates and challenges.

## Process

### 1. Read S5 Identity
Load the function's identity doc from `management/identity (S5)/`. Required: guiding question, stakeholders + needs.

### 2. Intuition Primer (Cover Story)
Human surfaces initial patterns and directions before research constrains thinking. Imagine a magazine cover 3 years from now about this function. What is the headline? What are people saying? This frames — not constrains — the exploration.

### 3. Customer Discovery
Who is the customer? What do they need? Often unknown at the start — default to "we will find out via research" if uncertain.

### 4. Environment Scan
Business model landscape. Market trends. Build vs buy dynamics. What is the market behavior? Even for internal markets, understand the landscape.

#### 4.0 — Epistemic Memory Checkpoint (S9)

**Before scanning the environment, query the epistemic graph for existing vision Points.** This surfaces prior vision claims, assumptions about the environment, and competitor claims already logged — preventing redundant research and anchoring the scan in accumulated knowledge.

```bash
node scripts/tortoise-memory.mjs query-visions --point-kind vision
```

Also query for related claims:
```bash
node scripts/tortoise-memory.mjs query-prior-research --domain "<domain>"
```

**Interpretation:**
- **Existing vision Points found:** Summarize prior worldview claims. What did we believe about the market? What competitors did we track? Use these to validate or challenge the current environmental scan.
- **"tortoise unavailable":** Skip — memory system offline.
- **Zero results:** First vision cycle for this domain. Note and proceed.

### 5. Competitor Research

#### 5a. Broad Scan — Multi-Angle Search
**Cast a wide net before deep-diving.** Search for partial overlaps, not just direct competitors. Searching only for our own category framing misses players building toward the same problem from different angles.

Dispatch parallel research sub-agents, each searching a different framing:

| Search Framing | Rationale |
|----------------|-----------|
| Our category (direct) | Direct competitors in the same space |
| Adjacent categories | Players in neighboring spaces converging toward us |
| Orthogonal approaches | Different paths to the same problem |
| Partial overlaps | Players who overlap on one dimension only |

**Adjacent categories to scan:**
- **Agent teams** — team-of-agents coordination, multi-agent task allocation
- **Agent swarms** — swarm intelligence, emergent agent collaboration
- **Agent harnesses** — meta-orchestration, agent supervision frameworks
- **Co-harness patterns** — human-agent shared control, collaborative steering
- **Shared workspace platforms** — artifact-mediated agent collaboration
- **Agent marketplaces** — agent discovery, composition, and deployment platforms

For each framing, search 2-3 queries with different terminology. Aggregate results into a candidate list before selecting which to deep-dive.

#### 5b. Deep-Dive Profiles
From the aggregated candidates, select the most relevant for detailed competitor profiles. What are they building? What justifies building vs buying? What can we learn?

### 6. Brainstorming
Explore the possibility space. Multiple directions. No premature convergence. Dispatch brainstorming sub-agents to generate vision options.

### 7. Synthesize
Pull all research + intuition into a coherent model. Surface patterns, tensions, and possibilities. The synthesis feeds the vision options.

### 8. Derive Value Proposition
From customer understanding + environment scan: what do we offer? Why us? The value proposition is the CONCLUSION of research, not an input.

### 9. Positioning + Theory of Change
How does this function become viable while satisfying its guiding question? What will it output into the world? How does doing so create the change the guiding question aims for?

### 10. Vision + Options
Structured by Three Horizons:
- H1 (near-term): current state, unknowns to resolve
- H2 (transition): building capabilities, proving viability
- H3 (far-term): the bigger idea, intuition, self-expression

Options are distinct possible futures. The skill proposes — it does not select.

### 11. Failure Checklist
Run these diagnostics before filing:

| Failure | Check |
|---------|-------|
| Ivory Tower | Co-created with reality or dictated from above? |
| Purpose-Washing | Do incentives align with vision? |
| Horizons Linearity | Does output treat H1→H3 as sequential lockstep? |
| False Precision | Numbers supported by evidence? |
| No Accountability | Who owns progress toward vision? |
| Wordsmithing | Bold or diluted by committee? |
| No Re-Entry | Plan to revisit or become a poster? |

### 12. AI Review Gate

> ⚠️ **GATE WARNING — DEPRECATED SKILL:** This skill is deprecated (S10 licensing cleanup, 2026-07-17). Quality gates below are retained for reference only. Active vision work should route through the current orchestrator skill.

Before the human gate, run an automated review to catch issues early.

**Dispatch a fresh `task` sub-agent reviewer:**

```
You are reviewing an S4 Vision artifact for quality and completeness.

VISION DRAFT:
- Guiding Question (from S5): <question>
- Vision Options (A, B, ...): <option summaries with H1/H2/H3>
- Competitor Research: <findings summary>
- Failure Checklist: <table>

CHECK:
1. Does the vision align with the S5 guiding question? Do the options meaningfully explore the question's tension, or do they sidestep it?
2. Are Three Horizons correctly applied? Does H1 represent current state/unknowns, H2 represent transition/building, H3 represent the bigger idea? Are they interdependent or treated as sequential lockstep?
3. Did competitor research actually inform the options? Can you trace specific competitive insights to specific vision elements?
4. Is the failure checklist complete? Are there missing failure modes given the function's context?

For each issue:
ISSUE:
  severity: P0|P1|P2
  description: <what's wrong>
  suggestion: <how to fix>

P0=fundamental flaw in vision, P1=important gap, P2=improvement
If no issues: NO ISSUES FOUND
```

**Review loop:**
1. Dispatch reviewer via `task` tool (fresh `pi -p` session)
2. "NO ISSUES FOUND" → exit clean. Issues found → step 3.
3. Apply fixes to vision options, failure checklist, or alignment
4. Re-dispatch reviewer → repeat until clean

### 12.5 — Write Vision Points to Epistemic Graph (S9)

**After the AI review passes clean, log the vision's key claims to the memory system.** This ensures subsequent vision cycles, strategy work, and identity checks can reference the worldview established.

```bash
node scripts/tortoise-memory.mjs write-points \
  --kind vision \
  --points-json '[
    {"content": "<H1 claim>", "authoredBy": "define-vision-skill", "confidence": 0.7},
    {"content": "<H2 transition>", "authoredBy": "define-vision-skill", "confidence": 0.5},
    {"content": "<H3 aspiration>", "authoredBy": "define-vision-skill", "confidence": 0.3},
    {"content": "<competitor insight>", "authoredBy": "define-vision-skill", "confidence": 0.8}
  ]'
```

**What to write (minimum):**
- Each horizon claim (H1, H2, H3) — confidence decreases with horizon distance
- Key competitor insights (high confidence — externally validated)
- Environmental assumptions (medium confidence — market shifts can invalidate these)
- The guiding question as context for all vision Points

**Graceful degradation:** If `tortoise unavailable` → skip with note.

### 13. Human Approval Gate
The vision options MUST be reviewed by S5 (human). S5 selects the option. The skill documents the selection. This is an algedonic boundary — vision defines WHERE the system goes. An agent cannot decide that alone.

### 14. File
Write the vision document to `management/future (S4)/<name>-vision.md`.

## Output Format

```markdown
---
title: "<Name> — Vision (S4)"
type: capability
domain: capability
subjects.team: <team>
doc_status: draft
created: <date>
---

## S5 Selection
<selected option + rationale, recorded after human review>

## Guiding Question (from S5)
<question>

## Intuition Primer (Cover Story)
<magazine cover exercise output>

## Customer Discovery
| Stakeholder | Need | Known? |
...

## Environment Scan
...

## Competitor Landscape
...

## Vision Options (proposed to S5)
### Option A — <name>
- H1: ...
- H2: ...
- H3: ...

## Positioning
...

## Theory of Change
...

## Failure Mode Checklist
| Failure | Check | Status |
...
```

---

Continue following the workflow as mandated by the orchestrator skill. Do not skip steps.
