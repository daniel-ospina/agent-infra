---
disable-model-invocation: true
name: question-format
description: "Reference protocol for presenting decisions to users. All skills that ask the user to choose between options MUST use this format. Consumed by other skills — not invoked directly."
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.2.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

<!-- ported from the primary repo -->
# Question Format Protocol

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Purpose

Standardizes how Claude presents decisions to users. Every question with discrete options **must** use asking the user directly with the structure below. No exceptions — no raw markdown bullet lists, no inline "Questions for validation" dumps.

This is a reference protocol (like `human-input-framework`). Other skills reference it; users don't invoke it directly.

## When This Applies

Any time you are about to present the user with a decision that has discrete options. This includes:

- Clarifying questions during planning (epic-workflow, issue-scoping, brainstorming)
- Design validation questions (journey reviews, data model trade-offs, migration strategy)
- UX decisions, ontology choices, phasing decisions
- Any "which approach should we take?" moment

## Required Structure

Every question presented to the user must include these elements:

### 1. Context (why this question exists)
1-2 sentences explaining what research finding, design tension, or gap prompted this question. Reference specific findings when available.

### 2. Scope & Impact (what changes depending on the answer)
1 sentence on what concretely changes — not abstractly ("this is important") but specifically ("this determines whether we add a new table or extend the existing one").

### 3. Options (2-3 substantive + always-present utility options)
Aim for **3 substantive options** in most cases — this gives the user a genuine spread (recommended, a credible alternative, and a different trade-off direction) without overwhelming. 2 is fine when the decision is truly binary. Don't pad to 3 if there aren't 3 real options, and don't force-merge to 2 when 3 exist naturally.

**Tool constraint:** asking the user directly allows 2-4 options max. The always-present options are:
- **"Research this"** — manually added as the last option in the array (see §5)
- **"Other"** — auto-added by the tool; lets the user type a custom answer

This means the options array holds **2-3 substantive options + "Research this" = 3-4 total**.

**When 4+ substantive approaches genuinely exist:** Present the top 3 in the options array (+ Research this = 4 total). Mention the remaining approaches briefly in the `question` text so the user knows they can select "Other" and pick one of those, or describe their own idea.

Each option must have:
- **Label**: concise name (1-5 words)
- **Description**: 2-3 sentences covering:
  - What this option means in practice (plain language)
  - The trade-off — what you gain and what you give up
  - When/why you'd pick this (if not obvious)

### 4. Recommendation (which option and why)
- The recommended option MUST be listed **first** in the options array
- Append `" (Recommended)"` to its label
- End the description with a `Recommended because:` line explaining the specific reasoning — what about this project's context, constraints, or research findings makes this the best fit

### 5. Research option
- Always include a `"Research this"` option as the **last** choice before "Type something" and "Chat about this" (which ask the user directly adds automatically)
- Description: `"Launches a research agent to gather more information before deciding."`
- **When the user selects this option**, launch an Agent (subagent_type: `general-purpose`) with a prompt that:
  1. States the question and options being researched
  2. Instructs the agent to decide its research scope:
     - **Internal only**: grep/glob/read the codebase for relevant patterns, existing implementations, conventions, and prior decisions
     - **Internal + external**: codebase research AND Perplexity/context7 queries for industry patterns, best practices, or comparable product approaches
  3. The agent should **bias toward internal + external** — only skip external research when the question is purely about internal implementation details with no external analogue (e.g., "which existing helper to reuse")
  4. The agent returns: a summary of findings, whether they change the recommendation, and a revised recommendation if warranted
- After the research agent returns, **re-present the same question** with findings incorporated into the option descriptions and an updated recommendation if the research warrants it

## Tool Mandate

**Discrete options:** MUST use the asking the user directly tool. Format:

- `header`: short title, max 12 chars (e.g., "QR default", "Lock style")
- `question`: context + scope/impact + question text, composed into a readable paragraph. If more substantive approaches exist than fit in the options array, list them briefly here so the user can select "Other" and reference one
- `options`: 2-3 substantive options (recommended first) + "Research this" last = 3-4 total. The tool auto-adds "Other" for custom text input
- `multiSelect`: false (unless choices are genuinely non-exclusive)

**Free-form questions (no discrete options):** Fall back to text output with this structure:

```
**Q: [short title]**

[Context: 1-2 sentences on why this came up]

[Full question text]

[Impact: what concretely changes depending on the answer]
```

## Batching Rules

- You may batch up to 4 questions in a single asking the user directly call (tool limit)
- If you have more than 4 questions, present them in batches of 4, waiting for answers before the next batch
- Group related questions in the same batch when possible
- Never dump all questions as a markdown list — always use the tool

## Anti-Patterns (what NOT to do)

| Anti-pattern | Correct behavior |
|---|---|
| "Questions for validation:" followed by numbered bullets | Use asking the user directly for each decision |
| Options without trade-off analysis | Every option needs what-you-gain / what-you-lose |
| No recommendation | Always lead with your recommended option |
| Recommendation without reasoning | Always include `Recommended because:` with project-specific rationale |
| "Is this correct?" yes/no questions | Reframe as options: the current approach vs alternatives |
| Dumping 7 questions at once as text | Batch in groups of 4 via asking the user directly, wait between batches |

## Examples

### Standard question (3 substantive options)

```
ask the user directly({
  questions: [{
    header: "QR default",
    question: "The journey assumes both QR and custom toggles default to OFF for non-subscribers, requiring them to explicitly choose. However, defaulting 'Instrucciones personalizadas' to ON could guide them toward filling it in immediately. This determines the onboarding friction for non-subscriber deal creation.",
    multiSelect: false,
    options: [
      {
        label: "Both OFF (Recommended)",
        description: "Non-subscribers see both toggles OFF and must explicitly enable custom instructions. This matches the existing Tipo de Oferta pattern where users opt-in to features. Lower risk of confusion since they only see what they activate. Recommended because: consistency with existing UX patterns reduces cognitive load, and non-subscribers don't have QR access anyway so a blank slate is cleaner."
      },
      {
        label: "Custom ON by default",
        description: "Non-subscribers land with 'Instrucciones personalizadas' pre-enabled and the text field visible. Guides them to fill in redemption instructions immediately. Trade-off: breaks the opt-in pattern used elsewhere, and the pre-opened field may feel like a required step rather than an option."
      },
      {
        label: "Research this",
        description: "Launches a research agent to gather more information before deciding."
      }
    ]
  }]
})
```

The user sees these 3 options + auto-added **"Other"** (custom text input).

### Overflow question (5+ substantive approaches)

When more approaches exist than fit in the 4-option limit, mention extras in the question text:

```
ask the user directly({
  questions: [{
    header: "Cache layer",
    question: "We need a caching strategy for the deal listings API. This determines latency and infrastructure cost. Top 3 options below; other viable approaches: Cloudflare KV with TTL, stale-while-revalidate at the CDN edge, or a Redis sidecar — select Other to pick one of these or propose your own.",
    multiSelect: false,
    options: [
      {
        label: "In-memory LRU (Recommended)",
        description: "Simple in-process LRU cache with 5-minute TTL. Zero infrastructure cost, ~2ms reads. Trade-off: per-isolate (no sharing across workers), cold starts after deploys. Recommended because: our traffic fits in a single isolate's memory and we already use this pattern for category lookups."
      },
      {
        label: "Supabase materialized view",
        description: "Pre-compute listings into a materialized view refreshed every 5 minutes via pg_cron. Trade-off: adds DB load during refresh, but reads are instant and shared across all workers."
      },
      {
        label: "No cache",
        description: "Query Supabase directly on every request. Simplest code, always fresh data. Trade-off: ~120ms per request at current query complexity, scales poorly if traffic grows."
      },
      {
        label: "Research this",
        description: "Launches a research agent to gather more information before deciding."
      }
    ]
  }]
})
```

The user can select **"Other"** to pick a mentioned alternative or type their own idea.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
