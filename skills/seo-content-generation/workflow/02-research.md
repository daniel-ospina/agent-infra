# Step 2 — The research doc

**Produces:** `growth/seo/articles/<slug>/research.md`.
**Owner:** agent. **Gate:** auto, then merged into **human gate 1** (step 3).

## Why this step exists

Step 5 is the owner generating prose from a brief. Every fact in that prose arrives from here. An
unverified number in this doc is printed verbatim into published copy, and nothing downstream will
catch it: the check that matters is **against the registry it is attributed to**, not against the
sentence's plausibility.

## Procedure

### 1. Scope the facts to the article

Read the backlog entry in `growth/seo/article-briefs.md` for the article's primary keyword. The
research doc covers **only** what that article asserts — not the whole category.

### 2. Gather from internal sources first

Internal sources are free, already verified, and mostly already cross-checked:

- **`premise-labs/product/competition/`** — the competitor registry. This is the source of truth for
  competitor benchmark and maturity facts. Use it before the web.
- **The `daniel-ospina/tortoise` repo** — the *only* admissible source for a claim about what Tortoise
  ships. Verify at a **named commit** (`git rev-parse HEAD` when you read it) and cite the file and
  line. Ship-state changes; a commit hash is what makes the claim checkable later.
- **`growth/seo/`** — `keyword-universe.csv`, `opportunity-queue.csv`, `bofu-journey.csv`,
  `objection-space-findings.md`, `competitor-seo-matrix.md`. These carry the measured numbers
  (volumes, difficulty, intercept weights, competitor keyword counts).

External facts go through the **`research` skill** — never call `web_search` directly.

> ⛔ **Dispatch that research to a `task` sub-agent — do not read `research/SKILL.md` yourself.** The
> sequence-enforcer auto-advances this skill past *every* consecutive `gate: auto` step the moment you
> `read` **any other** `SKILL.md` (`extensions/sequence-enforcer/index.ts:1806-1824`, pinned by
> `sequence-enforcer.test.ts:1126`). Reading the research skill's file here would jump `find_examples`
> → `research_doc` → `brief_doc` straight onto the gate-1 approval gate, which blocks
> `write`/`edit`/`bash`/`task` — leaving you unable to write the very `research.md` you were working
> on. A sub-agent reads it in its own process, so this session's step index is untouched.
>
> **Give the sub-agent a self-contained prompt** — it starts with no session context: the article's
> **primary keyword**, the scoped questions from §1, the instruction to use the `research` skill, and
> the return format ("claim · source · date per fact"). Without the scope it will research the whole
> category instead of this article's assertions.
>
> **There is no "step finished" signal to wait for** — the index moves only when a foreign `SKILL.md`
> is opened, so no marker ever says an `auto` step is done. The rule is simply: **never open another
> `SKILL.md` in this session. Dispatch it as a `task` sub-agent instead.**

### 3. Write every fact as: claim · source · date

```markdown
## Competitor facts

- **Zep** reports LoCoMo **94.7%** and LongMemEval **90.2%**.
  — source: `product/competition/zep.md` (registry), checked 2026-10-10.

- **Tortoise** ranks source credibility on a five-tier scale, and each tier carries a Beta prior whose
  pseudo-count (`pc = α − 1`) is 9.0 (T0), 4.0 (T1), 2.0 (T2), 1.0 (T3), 0.1 (T4); the Beta means
  are 0.9091 / 0.8333 / 0.7500 / 0.6667 / 0.5238.
  — source: `daniel-ospina/tortoise` @ `acc5db1359da693ac42495a9e442981a3cb0cf16`,
  `tortoise/source_credibility.py:36-42` (`TIER_PRIORS`); checked 2026-10-10.
```

> ⚠️ **A line number is only valid at the commit you name it with.** `tortoise/sdk.py` is ~4,100 lines
> at some commits and ~27,600 at others, so pairing one commit's hash with another version's line
> number yields a citation that cannot be checked — and looks perfectly authoritative. Verify the
> line at the sha before you write it down.

**No number without a source and a date.** If you cannot source it, it does not go in the doc — and
the brief must not promise it.

### 4. Apply the claim-discipline rules before writing, not after

- **"nobody / only / never / the only / sole"** → name the checked source in the same sentence, or
  cut the claim. These are treated as guilty until verified.
- **Never convert a searched absence into a positive assertion.** Write "we found no published
  statement by X that…", never "X publishes no…". A failed search is not evidence of absence.
- **A first-person shipped/not-shipped claim about Tortoise** is P0 until verified against the repo at
  a named commit. Grant docs and research briefs are **not** evidence.
- **Beware the landed fix relocating the error.** When a reviewer flags a claim, re-derive the fact
  from the source — do not reword the sentence. A reworded P0 became the next cycle's P0.

### 5. Mark what is unknown

List the questions the article raises that you could not source, in a `## Open questions` section.
These are **not failures** — they are the honest limits, and the brief must write around them rather
than assert through them. An honest "we did not measure X" is a credibility asset; a guess is a
liability.

## Done when

- Every fact in the doc has a source and a date.
- The `## Open questions` section exists (even if short).
- No `only/nobody/never` claim lacks a named source.
- No absence has been converted into a positive assertion.
