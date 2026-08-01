# Protocols Reference

## Research Protocol

### Abundance Principle
Research is cheap and compounds. 8–12 queries per track is normal. Do not conserve.

### Research Dump Protocol
Every Perplexity query result is appended to the research dump file (`docs/09_strategy/research/YYYY-MM-DD-pitch-components.md`):

```markdown
## Phase 1: Sales Research — Track [A/B/C/D]

### Query: "[exact query]"
**Source:** Perplexity | **Date:** YYYY-MM-DD

[Full response]

---
```

Create the dump file at start via `mkdir -p docs/09_strategy/research`.

### Geography & Market References
**Never hardcode geographies, categories, or channels in research queries.** Always reference the strategy document dynamically:
- "B2B selling norms in [target geography from §2]" not "B2B selling norms in Mexico"
- "outreach via [outreach channel]" not "outreach via WhatsApp"
- "[target market segment from §2]" not "restaurants and hotels"
- "[persona types from §7.3]" not "owner and general manager"

## Progressive Commit Protocol

After each phase boundary: `git add docs/09_strategy/ && git commit -m "docs(strategy): pitch components Phase N — [brief description]"`

This is documentation, exempt from `commit-workflow`. Direct commits are appropriate.

**Core rule:** If context crashes, the last committed phase is always recoverable.

## Human Gate Protocol

At human gates, present using `question-format` skill for all structured questions:
1. **Summary** of what was produced (2–3 sentences)
2. **Key findings** that shape the components
3. **Decisions needed** — structured questions for user input
4. **What comes next** (next phase overview)

Wait for explicit approval before proceeding.

## Confidence Lifecycle Rules

- All new components start at `confidence: 'hypothesis'`
- **Only the user promotes** — the skill never auto-promotes. Transitions are manual based on field experience.
- The skill surfaces the question; the user makes the call.
- Promotions/demotions update `promoted_at`/`demoted_at` timestamps in the manifest.

### Confidence Check at Skill Start
In **Full Build** and **Incremental Update** modes, before generating new components:
1. If existing components exist, present current confidence levels
2. Ask: "Any promotions or demotions based on recent conversations before we generate new components?"
3. Apply any changes, then proceed to the generation pipeline

### Retirement Confirmation
When user wants to demote to `retiring`:
- Show the component content one more time
- Confirm: "This will set `is_active: false`. The component stays in the file for reference. Confirm?"
- Never hard-delete.

## File Writing Protocol

All output is written to disk at phase boundaries. Conversation history is secondary to files.

| Artifact | Path | Purpose |
|---|---|---|
| Sales Research Brief | `docs/09_strategy/sales-research-brief.md` | Deep sales culture + methodology + channel research |
| Strategy Gaps | `docs/09_strategy/strategy-gaps.md` | Strategy sections insufficient for component derivation |
| Pitch Components | `eldato-outreach: src/lib/pitch-components/pitch-components.ts` | TypeScript constants — source of truth for WhatsApp agent |
| Manifest | `eldato-outreach: src/lib/pitch-components/pitch-components-manifest.json` | Section hashes + component-to-strategy traceability |
| Research Dump | `docs/09_strategy/research/YYYY-MM-DD-pitch-components.md` | Raw research preservation |

## Dynamic References (Read at Runtime)

Always read from `strategy.md` at runtime — never hardcode:
- Geography → `strategy.md` §2
- Market segment → `strategy.md` §2
- Persona types → `strategy.md` §7.3
- JTBD forces → `strategy.md` §3
- Competition → `strategy.md` §4
- Outreach channel → `strategy.md` §2
