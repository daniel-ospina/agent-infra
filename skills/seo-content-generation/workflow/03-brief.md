# Step 3 — The brief

**Produces:** `growth/seo/articles/<slug>/brief.md`.
**Owner:** agent. **Gate:** auto, then **human gate 1** — presented in-line with the research doc.

## Why this step exists

The brief is what the owner generates from. If a required decision is missing from it, that decision
gets made by the generation model instead — and the result is an article nobody scoped. The brief is
also the last cheap moment to catch a wrong framing: after step 5 the draft exists.

## Required sections

Every brief has **all eight**. A missing section is not a stylistic gap — it is a decision that will be
made by default.

### 1. Business objective

What this article is *for*, in one sentence, in business terms. Not "cover agent memory" but "own the
comparison query for teams choosing a memory layer, and route them to the docs' quickstart".

### 2. Strategy overview — where this fits

Its place in `growth/seo/README.md` §2's map: which pillar, hub or spoke, what it links to and what
links to it. Name the **primary keyword** and the **intent stage** (BOFU / MOFU / TOFU) from
`growth/seo/bofu-plan.md`. An article with no place in the map is a duplicate waiting to compete with
itself.

### 3. SEO keyword targets

- **Primary** — one term. The title and H1 serve it.
- **Secondary** — 3–10 harvested terms, from `keyword-universe.csv` / `opportunity-queue.csv`. These
  go into H2s, tables and body — never stuffed.
- For each, carry the **measured volume** and the **intent stage**.

Source data:

- `growth/seo/keyword-universe.csv` — the full harvested universe.
- `growth/seo/opportunity-queue.csv` — funnel-classified. The BOFU 405 / MOFU 273 / TOFU 950 counts
  are the **volume>0** subset; the file's full stage totals are BOFU 1,396 / MOFU 606 / TOFU 1,831.
- `growth/seo/bofu-journey.csv` — intercept-scored (`volume × winnability × stage weight`).
- `growth/seo/objection-space-findings.md` — the objection terms, which are **headings, FAQs and
  title framing — never pages of their own**.

> ⚠️ The universe is machine-filtered and carries off-topic tail (≈18% of the top 50, decaying to
> ~3% at 400). Treat it as a **candidate pool, not a mandate**: if a term would not appear in a
> sentence a developer would write, drop it.

### 4. Target reader

Who they are, what they already know, and **what they are trying to decide**. Be specific enough that
it changes the outline: "a backend engineer who has already tried a vector store and found that
retrieval alone did not stop the agent from acting on a stale fact" is a reader; "developers" is not.

### 5. Outline

The H2 sequence, plus which H3s carry per-option profiles where the type is comparison. **Build the
outline against the measured norms from step 1**, not against intuition — if the 3 exemplars converge
on an answer box in the first ~150 words and a FAQ, the outline carries both.

Mark which section is the **answer box**, which carries the **comparison table(s)**, and which is the
**runnable/test-it-yourself step** (required furniture items 3 and 7).

### 6. CTA

The single action the reader should take. One primary CTA — a second competing CTA halves both.

### 7. Example articles — the 3 from step 1

Link, not inline (inlining is step 4). For each: the URL and the **one thing it teaches** — the
specific norm this article will copy.

```markdown
| example | what we copy from it |
|---|---|
| <url> | Answer box in the first 100 words; "Best for" column in every table. |
```

### 8. Open questions carried from step 2

The `## Open questions` list from the research doc, restated as **how the article will handle them** —
write around, state the limit explicitly, or drop the claim. Never leave them for the generator to
resolve.

---

## 🛑 Human gate 1

**Present the research doc and the brief in-line in the conversation — not as file paths.** Then stop.

- The owner is checking **facts** (research) and **framing** (brief).
- A correction here costs a paragraph. The same correction after step 5 costs the whole draft.
- Do not proceed to step 4 on an assumed approval. "Looks fine" is an approval; silence is not.

## Done when

- All eight sections are present.
- The primary keyword is a single term and the title serves it.
- The outline names its answer box, its table(s), and its runnable step.
- The 3 examples are linked with what is copied from each.
- Gate 1 has been **explicitly** passed.
