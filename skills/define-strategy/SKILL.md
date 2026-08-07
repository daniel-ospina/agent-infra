---
name: define-strategy
description: "Defines organizational strategy — gap analysis, initiatives, role alignment, and roadmap — for any function, team, or role."
domain: capability
type: Workflow
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---

# Define Strategy

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

Produces the Strategy artifact and Roadmap. Takes the S4 vision as input. Executed by the Team Strategist role.

## Philosophy

**Good strategy eliminates options.** It forces hard trade-offs that drive specialization. If the output doesn't make you uncomfortable about what you're NOT doing, it's not a strategy — it's a wishlist.

- Default to less. Doing fewer things well beats doing more things poorly.
- Every "yes" to an initiative is a "no" to something else. Make those nos explicit.
- Delegation is the first choice. Adding roles is the last.
- The best infrastructure is the infrastructure you don't build.

## VSM S3 Alignment

| S3 Function | Step | Ponytail Check |
|-------------|------|----------------|
| Bridge current to future | 1: Gap analysis | Which gaps should we accept? |
| Balance autonomy with goals | 2: Horizon mapping | What can be deferred? Best infra is unbuilt. |
| Resource allocation | 3: Initiative generation | What's the one-line version? |
| System re-organization | 4-5: Role gap + workflows | Delegate → skills → expand agreement → add role (last) |
| Performance management | 6: Coherence review | What did we say no to? |
| Handoff to execution | 7: Roadmap → Coordinator | — |

## What you are missing

- [ ] `workflow/01-gap-analysis.md` — current vs desired, competitor research, internal analytics, AI review
- [ ] `workflow/02-horizon-mapping.md` — Three Horizons, ponytail check, human gate
- [ ] `workflow/03-initiative-generation.md` — one-off + ongoing Actions, human gate
- [ ] `workflow/04-role-gap-analysis.md` — map initiatives to existing roles, AI review
- [ ] `workflow/05-workflows-plan.md` — delegate → skills → expand → add, human gate
- [ ] `workflow/06-coherence-review.md` — internal consistency, trade-off check
- [ ] `workflow/07-roadmap.md` — handoff to Coordinator, human gate

## Memory System Integration (S9)

### Before Strategy — Load Existing Strategy Points

**Before starting gap analysis, query the epistemic graph for prior strategy claims.** This surfaces assumptions, constraints, and decisions from previous strategy cycles — preventing drift and enabling cumulative reasoning.

```bash
node scripts/tortoise-memory.mjs query-strategies
```

Also query for relevant decisions and assumptions:
```bash
node scripts/tortoise-memory.mjs query-prior-research --domain "<strategy-domain>"
```

**Interpretation:**
- **Existing strategy Points found:** Summarize prior decisions, constraints, and assumptions. Use them as inputs to the gap analysis — what changed since the last strategy? What assumptions held true? Which didn't?
- **\"tortoise unavailable\":** Skip — memory system offline. Proceed without prior context.
- **Zero results:** First strategy cycle for this domain. Note \"no prior strategy Points found.\"

### After Strategy — Write Strategy Points to Memory

**After the Roadmap step completes, log the strategy's key claims to the epistemic graph.** This ensures subsequent strategy cycles and related skills (vision, identity) can reference the decisions made.

```bash
node scripts/tortoise-memory.mjs write-points \
  --kind strategy \
  --points-json '[
    {"content": "<key decision 1>", "authoredBy": "define-strategy-skill", "confidence": 0.8},
    {"content": "<key constraint 2>", "authoredBy": "define-strategy-skill", "confidence": 0.9},
    {"content": "<open question>", "authoredBy": "define-strategy-skill", "confidence": 0.3}
  ]'
```

**What to write (minimum):**
- Each initiative as a strategy Point (confidence based on analysis depth)
- Key constraints and assumptions (high confidence)
- Explicit trade-offs (\"we chose X over Y because Z\")
- Resources allocated and why

**Graceful degradation:** If `tortoise unavailable` → skip with note.

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| Gap analysis | Strategy built on assumptions, not data. Competitor threats invisible. |
| Horizon mapping | Everything is urgent. No sequencing. Burnout and thrash. |
| Initiative generation | Vision never becomes action. Strategy is a document, not a plan. |
| Role gap analysis | Initiatives have no owners. Work falls through cracks. |
| Workflows plan | Roles overloaded or under-specified. Coordination overhead explodes. |
| Coherence review | Contradictions between steps. Strategy doesn't hang together. |
| Roadmap | Coordinator has nothing to execute. Strategy stays on the shelf. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
