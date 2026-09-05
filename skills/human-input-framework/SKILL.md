---
disable-model-invocation: true
name: human-input-framework
description: "Reference taxonomy for when coding workflow skills should pause for human input vs proceed autonomously. Not invoked directly — consumed by other skills."
subjects.team: organisation-design-team
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 2.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

<!-- ported from the primary repo -->
> **Source:** Canonical copy at `skills/human-input-framework/SKILL.md`.

# Human Input Decision Framework

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Overview

Shared reference defining when agents should pause for human input during coding workflows. Other skills inline the taxonomy from here — this file is the canonical source of truth.

**This skill is NOT invoked directly.** It exists so there is one authoritative definition that skill authors reference when creating or updating overrides.

**v2.0.0 — Research-Before-Ask Protocol:** Before pausing for ANY taxonomy-matched decision, the agent MUST first research. Many decisions that appear ambiguous have clear answers from internal codebase patterns, existing project conventions, or external best practices. Research resolves most cases; only genuinely ambiguous high-stakes decisions should reach the user.

---

## Research-Before-Ask Protocol (MANDATORY — runs BEFORE any pause)

**When a taxonomy match occurs, do NOT pause immediately. Run this protocol first:**

### Step 1 — Internal Research
Search the codebase for existing patterns, conventions, or prior decisions:
- `grep` for similar implementations, naming conventions, architectural patterns
- Check `docs/` for relevant specs, ADRs, or conventions
- Check `CLAUDE.md` and `MEMORY.md` for documented patterns
- Look at recent PRs or git history for similar decisions

### Step 2 — External Research
If internal research doesn't yield a clear answer, fire targeted Perplexity queries:
- Best practices for this specific pattern/decision
- How comparable products or projects handle it
- Known failure modes or anti-patterns
- Use `perplexity_research` (3+ queries) for medium-impact decisions; `perplexity_search` for quick lookups

### Step 3 — Decision
Based on research:

| Confidence | Action |
|-----------|--------|
| **>80% confidence** — research yields a clear, unambiguous answer | Apply the decision. Note it with a `ponytail:` comment citing the research source. **Do NOT pause.** |
| **50-80% confidence** — research favors one option but alternatives exist | Apply the best-supported option. Note: "Researched [topic]. Chose [X] because [research finding]. Alternative [Y] would [trade-off]." **Do NOT pause.** |
| **<50% confidence** — research is inconclusive or options have equally strong trade-offs | **Pause** with structured question. Present the research findings and the remaining ambiguity. |
| **P0 consequence** — data loss, security breach, irreversible schema change, large cost impact, legal/compliance | **Pause regardless of research confidence.** These gates are absolute. |

### Step 4 — If Pausing
When pausing is necessary, present:
- The research findings (what was found, what remains ambiguous)
- Structured options per `question-format` protocol
- A recommendation with rationale

**Never pause with a bare question.** Every pause must include: what was researched, what was found, and why the decision still needs human input.

---

## Taxonomy — What Requires Human Input (After Research-Before-Ask)

Research first, then pause ONLY if research doesn't yield a clear answer OR the consequence is P0:

1. **Ontology changes** — new tables, columns, relationships, semantic meaning changes
2. **UX changes** — visible user-facing behavior/layout/flow changes not explicitly requested
3. **One-way doors** — destructive operations, data migrations, schema drops, force pushes
4. **Third-party dependencies** — new API integrations, service subscriptions
5. **Cost impact** — changes increasing recurring costs by >$1-3/month
6. **Scope expansion** — implementing beyond what was requested

**Tie-breaking rule (UPDATED):** When uncertain whether a decision matches the taxonomy, RESEARCH FIRST. If research yields a clear answer (>80% confidence), apply it. Only pause if research is inconclusive OR the decision is P0 (data loss, security, irreversible, cost >$10/month, legal/compliance).

**Everything else** → Agent decides autonomously with a brief note explaining the choice, open to iteration if the user disagrees.

---

## "Work On It" Response Protocol

When human input is required (research was inconclusive on a taxonomy-matching decision) and the user says "work on it":

### First "work on it"
Surface each pending decision in structured format:

```
**Decision: [short title]**
- **Research findings:** [what was found — internal patterns, external best practices]
- **Options:** [2-4 concrete choices]
- **Analysis:** [1-2 sentences on trade-offs]
- **Recommendation:** [which option and why, citing research]
```

Wait for user to pick an option or provide custom direction before proceeding.

### Second "work on it" (without answering questions)
Agent picks its own recommendation for each unanswered question, notes the choices clearly with:
> "Proceeding with my recommendations since no specific direction was given. These choices can be revisited — just let me know."

Then continues with implementation.

---

## Examples (Updated for v2.0.0)

| Task | Taxonomy Match? | Research | Behavior |
|---|---|---|---|
| Change a CSS class name | No | — | Proceed, brief note |
| Add a new DB column matching existing pattern | Yes — ontology | Internal: found 3 similar columns in same table | Apply pattern, note: "ponytail: following existing pattern from [table].[col]." Do NOT pause. |
| Add a new DB column with novel semantics | Yes — ontology | Internal: no pattern. External: Perplexity finds clear best practice. | Apply best practice, note: "Researched [topic]. Pattern from [source]." Do NOT pause. |
| Add a new DB column with multiple valid approaches | Yes — ontology | Research inconclusive — 2 valid patterns with different trade-offs | Pause with structured question + research findings |
| Drop a production table | Yes — one-way door (P0) | — | Pause regardless. P0 gate is absolute. |
| Refactor hook to use useCallback | No | — | Proceed, brief note |
| Integrate Stripe for payments | Yes — third-party + cost (P0) | — | Pause regardless. P0 gate is absolute. |
| Change button label text | Yes — UX (tie-breaking) | Internal: check existing button patterns. External: Perplexity for UX best practices. | If research yields clear answer → apply, note. If ambiguous → pause with structured question. |
| Fix a typo in error message | No | — | Proceed, brief note |
| Add retry logic to existing API call | No | — | Proceed, brief note |
| Switch from REST to GraphQL | Yes — one-way door + scope (P0) | — | Pause regardless. P0 gate is absolute. |

---

## P0 Gate — Absolute Stops (Research Cannot Override)

These decisions ALWAYS pause for human input, regardless of research confidence:

| Category | Examples |
|----------|----------|
| **Data loss risk** | Dropping tables/columns, destructive migrations, deleting user data |
| **Security** | Auth model changes, permission grants, credential handling |
| **Irreversible changes** | Schema drops, force pushes, production data modifications |
| **Large cost impact** | New paid services >$10/month, API usage that could spike billing |
| **Legal/compliance** | Data handling changes, privacy implications, terms of service |

When a P0 gate is hit, research is still conducted and presented, but the decision ALWAYS pauses.

---

## Research Tool Selection (Cost-Ordered)

> **Note:** Tool names vary by agent. Pi: `mcp__seo-intelligence__perplexity_research`, `mcp__seo-intelligence__perplexity_search`, `mcp__context7__query_docs`. Claude Code: `perplexity` CLI or built-in web search. Check your agent's tool manifest for exact names.

| Tool | Cost | Use When |
|------|------|----------|
| Internal codebase search (grep, read) | Free | Always — first step |
| Library docs (context7 MCP or equivalent) | Free | When topic involves a specific library/framework |
| Quick Perplexity lookup | $0.005/query | Simple fact-check, "what is X" |
| Multi-angle Perplexity research | $0.005/query × N | Comparing approaches, "how do others do X" |
| AI-summarized web search | $1/$1 per M tokens | Synthesis of multiple sources |
| Higher-quality web search | $3/$15 per M tokens | Better quality when justified |

**⛔ NEVER use deep-research or reasoning-pro models without EXPLICIT user approval.** These cost $5-40+ per call. Use the cheapest tool that answers the question.

---

## Inlining Instructions

Skills that consume this taxonomy MUST inline:
1. The full taxonomy (6 categories)
2. The Research-Before-Ask Protocol (Steps 1-4)
3. The P0 Gate list
4. The tie-breaking rule

This ensures cross-session resilience — a skill invoked in a fresh session must work without loading this framework skill first.

When updating the taxonomy here, update all consuming skills:
- `agent-infra/skills/brainstorming/SKILL.md`
- `agent-infra/skills/executing-plans/SKILL.md`
- `agent-infra/skills/issue-scoping/SKILL.md`
- `~/.pi/agent/skills/brainstorming/SKILL.md` (Pi symlink)
- `~/.pi/agent/skills/executing-plans/SKILL.md` (Pi symlink)
- `~/.pi/agent/skills/issue-scoping/SKILL.md` (Pi symlink)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
