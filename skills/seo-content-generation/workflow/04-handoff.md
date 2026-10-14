# Step 4 — The handoff bundle

**Produces:** `growth/seo/articles/<slug>/handoff.md`, revealed in Finder.
**Owner:** agent. **Gate:** auto (gate 1 must already be passed).

## Why this step exists

The owner takes this file to ChatGPT and generates the article from it. It must therefore be **one
self-contained file with no external references** — every fact, every example, and every instruction
inline. A handoff that says "see `research.md`" fails at the moment of use, because the file is dragged
into a browser, not read from the repo.

## Procedure

### 1. Assemble in this order

| Position | Section | Why here |
|---|---|---|
| 1 | **The brief** (step 3, complete) | The instruction — what to produce. |
| 2 | **The research doc** (step 2, complete) | The facts the instruction may assert. |
| 3 | **The 3 example articles, inlined in full** | The models — the measured format to match. |

Lead with the instruction, then the facts, then the models. The generation pass reads top-down; when
the examples come first the model imitates them before it knows the target.

### 2. Inline the examples, do not link them

Pull the `## Source text` body from each `growth/seo/examples/<slug>.md`. Keep each example's
**measured format** table next to its text — the numbers are what the outline was built from, and they
are what tells the generator how long each section should be.

### 3. Write the file

```markdown
# <Article title> — content brief and research

> Prepared for generation. Everything needed is in this file.

## Part 1 — The brief
<step 3, verbatim>

## Part 2 — Research: the facts
<step 2, verbatim — claim · source · date>

## Part 3 — Example articles

### Example 1 — <product>: "<title>"
<measured format table>
<source text>

### Example 2 — …
### Example 3 — …
```

**Verbatim, not summarised.** The brief and the research were both approved at gate 1; rewriting them
here silently ships an unapproved version. If something needs to change, change it in the source file
and re-run this step.

### 4. Open it in the file finder

```bash
open -R growth/seo/articles/<slug>/handoff.md
```

`open -R` **reveals** the file in Finder with it selected, which is what makes drag-and-drop possible
(`open` alone launches a default app and defeats the purpose).

Then tell the owner it is ready and what to do with it. Do not paste the file into the conversation —
it is long, and the owner needs it as a file.

## 🛑 Step 5 is the owner's — not yours

The owner takes the handoff to ChatGPT, generates, and **edits**. **Do not generate the article text
yourself, and do not offer to.** The editing pass is where the voice comes from; an agent draft
substitutes for it and the result reads like an agent draft. The next agent action is step 6, on the
text the owner hands back.

## Done when

- `handoff.md` exists, self-contained, with all three parts in order.
- The 3 examples are **inlined with their measured-format tables**.
- `open -R` has revealed it in Finder.
- The owner has been told the file is ready and that step 5 is theirs.
