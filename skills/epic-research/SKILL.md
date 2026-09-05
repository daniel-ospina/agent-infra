---
disable-model-invocation: true
name: epic-research
description: "Bounded skill wrapping the existing research skill for epic-scope investigation. Adds epic-specific research brief sections (Strategy, UX Patterns, Workflow Patterns, Tech Stack, Assumptions Register). Thin wrapper — delegates deep research to the research skill. Invoked by epic-plan after strategy alignment."
domain: planning
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

# Epic Research

**Announce at start:** "I'm using the epic-research skill for epic-scope investigation."

## Purpose

Thin wrapper around the `research` skill that adds epic-specific research brief sections. Does NOT replace or duplicate the `research` skill — it invokes it with epic-scope parameters and structures the output for downstream epic planning phases.

## Workflow

### Step 1 — Scope Research Axes

From the epic strategy decision (produced by `epic-align`), identify research axes:

- **Strategy:** Market context, competitive landscape, business model implications
- **UX Patterns:** How similar features work in comparable products, UX precedents
- **Workflow Patterns:** Operational/business process patterns, automation opportunities
- **Tech Stack:** Library choices, architecture patterns, integration approaches
- **Assumptions Register:** Every assumption from the strategy phase, tagged with confidence

### Step 2 — Invoke Research Skill

Dispatch the `research` skill with epic-scope parameters:

```
Research the following epic-scope topic: <epic title + problem statement>

Axes: <list from Step 1>
Depth: deep (epic scope)
Domain classification: <from epic context>

Include adversarial queries for each axis.
```

Collect the research output.

### Step 3 — Structure Research Brief

Produce an epic research brief document:

```markdown
## Epic Research Brief — <epic title>

### Strategy Context
<market, competitive, business model findings>

### UX Pattern Research
<precedent, best practices, anti-patterns>

### Workflow Pattern Research
<operational patterns, automation opportunities>

### Tech Stack Research
<library choices, architecture patterns, integration notes>

### Assumptions Register
| Assumption | Confidence | Source | Validation Plan |
|------------|-----------|--------|-----------------|
| <assumption> | high/medium/low | <where it came from> | <how to validate> |

## Raw Notes
<append-only evidence ledger — see the research-protocol reference skill (§13).
Entries are timestamped + source-tagged; synthesized sections above may be updated
per level with documented `[updated YYYY-MM-DD — <what changed>]` traces.
Append via scripts/_research_append.sh.>
```

> **Canonical brief structure (contract):** the five headings above — `### Strategy
> Context`, `### UX Pattern Research`, `### Workflow Pattern Research`, `### Tech
> Stack Research`, `### Assumptions Register` — plus `## Raw Notes` are the **canonical
> brief contract**. Downstream consumers (writing-plans Step A.1) read these exact
> headings. Do NOT rename them without updating every consumer; future briefs must
> preserve this set (issue #231 D9).

### Step 4 — Hand Off

Pass the research brief to `epic-scope` for boundary definition.

## Review Gate

Dispatch a fresh-context reviewer via `task` sub-agent:

```
Review this epic research brief for:

1. COMPLETENESS: Are all 5 sections populated with substantive findings?
2. ASSUMPTION COVERAGE: Are assumptions from strategy phase reflected in the register?
3. ADVERSARIAL BALANCE: Does research include disconfirming evidence, not just confirmation?
4. SOURCE QUALITY: Are claims sourced (internal codebase, external docs, web research)?

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until "NO ISSUES FOUND" or convergence; safety cap: 10 cycles.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Research axes | Unfocused research — deep dives on irrelevant topics, gaps on critical ones |
| Assumptions register | Untracked assumptions become silent design constraints |
| Structured brief | Downstream phases (scope, plan) operate on unstructured notes — drift accumulates |

## Integration

**Called by:** `epic-plan` (pipeline step 2, after `epic-align`)
**Hands off to:** `epic-scope`
**Calls:** `research` skill (delegates deep investigation)
**References:** `research-protocol` (query patterns, adversarial framing)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
