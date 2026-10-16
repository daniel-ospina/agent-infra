# Step 1 — Find the 3 example articles

**Produces:** `growth/seo/examples/<slug>.md` × 3 + index rows in `growth/seo/examples/README.md`.
**Owner:** agent. **Gate:** auto.

## Why this step exists

The article is not written to taste — it is written to the **measured format of what already ranks for
that query type**. Three exemplars turn "make it good" into a specification: how long the sections
are, how many tables, where the answer box sits, whether there are citations.

## Procedure

### 1. Determine the article type

From the brief's intent (step 3 sets it, but step 1 runs first — use the backlog entry in
`growth/seo/article-briefs.md` and the keyword cluster). One of:

| Type | Shape | Example query |
|---|---|---|
| **Comparison** | N options profiled identically + summary table with a "Best for" column | `mem0 alternative` |
| **Pillar / explainer** | Category definition, layered model, hub that links to spokes | `agent memory` |
| **How-to** | Runnable steps, one worked example, pass/fail criteria | `how to evaluate agent memory` |

### 2. Check the database before searching

`growth/seo/examples/` and its `README.md` **do not exist yet** — create both on the first run (an
empty index with just the header row). On later runs, read the index: **reuse an existing example**
if it matches the type and is still live (re-check the URL returns 200 and the format numbers still
hold). Do not re-fetch what is already good — the database exists to accumulate.

### 3. Select 3 new examples only where the database is short

Selection criteria, in order:

1. **Same article type** — a comparison article's exemplars must be comparison articles.
2. **Similar go-to-market** — developer tools, infrastructure, and API products. A B2C listicle is
   the wrong teacher no matter how well it ranks.
3. **Actually ranks** — it should be a top result for the target query or query cluster.
4. **Different from each other** where possible, so the measured norms generalise rather than
   describing one publisher's house style.

### 4. Measure — never estimate

Fetch the **rendered HTML** and count from it. Estimated counts are the failure mode this step exists
to prevent — the comparison-article format research behind this engine was built by counting rendered
HTML, not by reading for a feel.

> **Prior work, unmerged.** The measured comparison-article corpus lives at
> `growth/format-research-comparison-articles.md` in the `docs/agentic-memory-article` worktree
> (unpublished as of 2026-10-10 — not on `main`). Read it if that worktree is present; do not cite it
> as a repo document until it has landed. *(Do not quote a corpus size from it: its prose and its
> measurement table disagree — 11 vs 12 — so any numeral taken from it is a citation that does not
> check out.)*

Record per example: word count · H2 count · H3 count · table count · **in-sentence citations** ·
**bibliography present?** · "Best for" column present? · answer box present and within how many words ·
FAQ question count · whether per-option profiles use an identical template.

### 5. Write the example file

One file per example at `growth/seo/examples/<slug>.md`:

```markdown
---
title: "<the article's title>"
url: <canonical URL>
product: <who publishes it>
type: comparison | pillar | how-to
verified: <YYYY-MM-DD>          # the date you fetched it
why_chosen: <one sentence — what it teaches>
---

## Measured format

| metric | value |
|---|---|
| words | |
| H2 / H3 | |
| tables | |
| in-sentence citations | |
| bibliography | yes/no |
| "Best for" column | yes/no |
| answer box | yes/no — within N words |
| FAQ questions | |
| per-option template identical | yes/no |

## Source text

<the article's substantive text, inlined — this is what step 4 embeds>
```

Then add a row to `growth/seo/examples/README.md`:

```markdown
| <slug> | <product> | <type> | <words> | <tables> | <citations> | <verified date> |
```

## Done when

- 3 examples of the **same type** are in the database (newly fetched or reused), each with measured
  format numbers and inlined source text.
- The database index carries a row for each.
- Their **convergent norms** are written down — this is what step 3's outline is built against. If the
  3 disagree (e.g. 2 use a bibliography, 1 does not), record the split rather than averaging it away.
