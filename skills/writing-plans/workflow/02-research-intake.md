> **Step 2/5** | ← requires: `01-prerequisite-check.md` | → next: `03-integration-surface.md`

## Prior Research Intake (all tiers)

Before drafting the plan, gather all existing research. This avoids re-researching what's already known and ensures design decisions build on prior findings.

### Step A — Locate Prior Research

**If invoked directly from `issue-scoping` in the same session (auto-invoke path):** Skip Step A's *search* — research findings, codebase context, and requirements are already live in context — but **validate the scoping artifact exists**: the scoping comment must contain `### Axis Research` (+ `### Integration Docs` for standard+) or a justified-skip trigger assessment; if absent, note the gap and proceed (the plan's `### Pattern Research` is still authored by Step B). Proceed to Step B (checking for any remaining implementation gaps).

**Otherwise:** Check for research artifacts in this order:

1. **Epic research brief:** If an epic doc was found in the Prerequisite Check, look for its companion research brief:
   ```bash
   # If epic is docs/epics/2026-03-05-notifications-v2.md
   # Research brief is docs/epics/2026-03-05-notifications-v2-research.md
   RESEARCH_BRIEF=$(echo "$EPIC_DOC_PATH" | sed 's/\.md$/-research.md/')
   [ -f "$RESEARCH_BRIEF" ] && echo "Found: $RESEARCH_BRIEF"
   ```
   If found, read the canonical headings — `### Strategy Context`, `### Tech Stack Research`, `### UX Pattern Research`, `### Assumptions Register` (epic-research's producer contract, issue #231 D9) — plus `## Raw Notes`. These are the architecture contract for design decisions.

2. **Issue-scoping research:** Read the issue comments for `### Axis Research` and `### Integration Docs` blocks (output from issue-scoping Phase 1.5). These contain Perplexity findings on integrations and implementation patterns. **`### Pattern Research` is NOT consumed here** — it is Step B's exclusive output in the plan doc (authorship boundary, issue #231 D5). If the issue comment has no blocks, fall back to the research brief's `### Axis Research` section (resolved via `_research_path.sh`).

3. **Standalone research briefs:** Check `docs/plans/` for a research doc matching the feature name:
   ```bash
   ls docs/plans/*<feature-slug>*research* 2>/dev/null
   ```

Store findings as `PRIOR_RESEARCH` for use in plan drafting and Step B below.

### Step B — Multi-Call Perplexity Verification Gate (Standard + Complex only)

**Skip for Micro tier.**

**Purpose:** Verify library versions, syntax, and current best-practices for any third-party dependencies the plan will rely on, BEFORE handoff to `plan-review`. Multi-call triangulation reduces hallucination and ensures the plan reflects current reality (not training-data drift). This is the `writing-plans` analog of the gate defined in the fractal pipeline and `issue-scoping`; the protocol is intentionally identical so reviewers downstream see consistent shape regardless of which skill produced the research.

After reading the codebase (files to modify, existing patterns) and prior research, identify the third-party dependencies the plan will touch and the design decisions that still need outside knowledge. The gate runs in two sub-steps:

#### Sub-step B.0 — Library docs lookup

> **pi note:** context7 is available via `mcp__context7__resolve_library_id` and `mcp__context7__query_docs`. Use it for structured library documentation lookup before falling back to Perplexity.

For each named library / SDK / framework the plan mentions (e.g. `supabase-js`, `@anthropic-ai/sdk`, `react-query`, `zod`):

1. **Try context7 first**: use `mcp__context7__resolve_library_id` to find the library, then `mcp__context7__query_docs` for structured documentation. Fast, versioned, accurate.
2. **Fall back to Perplexity** for proprietary SDKs (typically SaaS APIs like HubSpot, Resend, Meta CAPI).

This sub-step does NOT count toward the multi-call gate's 3+ call floor — it's a separate library-docs preflight. Findings inform the gate's queries below (e.g. confirms which version is in use, surfaces deprecations to probe further).

If the plan touches **zero** third-party libraries / SDKs / frameworks (rare — pure config / copy / internal-helper change), skip Sub-step B.0 cleanly and document the skip in the `### Pattern Research` output block.

#### Sub-step B.1 — Multi-Call Perplexity Verification Gate

**Topic buckets** — for each bucket below that **applies** to the plan's third-party deps, fire **Perplexity calls proportional to topic novelty (see Research Depth table in proportional-gates). Well-known patterns: 0-1 calls. Novel patterns: 3+ calls.** (one per framing — see protocol). Skip a bucket entirely if it does not apply (see "When NOT to fire" below). Document any skip in the `### Pattern Research` output block.

| Bucket | When it applies | What it surfaces |
|---|---|---|
| **Library version & API surface** | Plan uses a specific library / SDK at a specific version (e.g. `supabase-js v2`, `@anthropic-ai/sdk v0.x`, `react-query v5`) | Current major-version API, breaking changes since training cutoff, version-pinned syntax differences |
| **Idiomatic usage patterns** | Plan introduces a new usage pattern for a library (hooks, edge function patterns, query builders, streaming, batch APIs) | Idiomatic API usage for the exact version + known anti-patterns |
| **Library/framework pitfalls** | Plan touches any third-party dep where misuse has known footguns (auth flows, retries, timeouts, state machines, side effects in renderers) | Common pitfalls, post-mortems, "we tried this and reverted" cases |

**Per-bucket protocol (mandatory minimum, identical to epic-workflow + issue-scoping gates):**

For each bucket that applies, issue at least **3 separate** `mcp__seo-intelligence__perplexity_research` invocations, each with a distinct framing:

1. **Canonical patterns call** — "What is the established / canonical approach to [library / API / pattern] in [version / runtime]? What patterns have been recommended for >= 12 months?"
2. **Competitor variance call** — "How do reference codebases / open-source projects use [library / API / pattern] at [version]? Cite specific repos and their distinguishing choices."
3. **Failure modes / pitfalls call** — "What are the known failure modes, anti-patterns, and pitfalls when using [library / API / pattern]? Include post-mortems and 'we tried this and reverted' cases."

Optional 4th call when warranted:

4. **Recency call** — "What changed in the last 12-18 months for [library / API]? Deprecations, breaking changes, paradigm shifts?"

**Hard rules:**

- **Multi-call != multi-question single call.** A single perplexity call with three questions packed in is ONE call from the model's perspective — one synthesis biased by one framing. Use **separate invocations** of `mcp__seo-intelligence__perplexity_research`, one per framing.
- **Parallel-safe.** The 3+ calls per bucket are independent and SHOULD be issued in parallel (multiple tool calls in one message).
- **Cite the framing in the synthesized output.** When writing into `### Pattern Research`, label which framing produced which conclusion ("Canonical: X. Competitor variance: Y. Known pitfall: Z.").
- **Per-bucket call count is a floor, not a ceiling.**

**When NOT to fire the gate**

Skip a bucket — or the entire gate — when:

- **Zero third-party deps in the plan** — pure config / copy / i18n / internal-helper change.
- **In-repo wrapper exclusively** — if the plan uses an in-repo wrapper exclusively without touching the underlying third-party SDK.
- **Idiomatic usage patterns bucket only** applies when the plan introduces a new usage pattern. A plan that follows an existing in-repo pattern (2+ examples in the codebase) can skip.
- **Library/framework pitfalls bucket** is the most defensive; skip only if the dep has been used identically elsewhere in the codebase with no documented post-mortem.

**Fallback: perplexity unavailable / out of credits**

If `mcp__seo-intelligence__perplexity_research` returns 401, 402 (out-of-credits), 429 (rate limit), or any unreachable-API error, **the workflow PAUSES and asks the user.** The gate must not silently skip external research.

Pause message format (use asking the user directly, single-question form):

```
Perplexity research is unavailable for this plan.

Bucket: [library version & API surface | idiomatic usage patterns | library/framework pitfalls]
Error: [401 / 402 credits exhausted / 429 rate limit / unreachable]
Calls completed before failure: [N of 3+]

Options:
(a) Pause writing-plans until perplexity is restored
(b) Proceed with partial research (only for low-downstream-risk buckets)
(c) Substitute internal/codebase research only (rare; justify before choosing)
```

Default to (a). Never auto-select (b) or (c).

**Output**

`### Pattern Research` block — embedded in the plan doc's Architecture section, persisted to the research brief's `## Raw Notes` per the persistence rules (research-protocol §13). **This block is Step B's SOLE-authorship output — scoping emits `### Axis Research` / `### Integration Docs`, never this block (issue #231 D5).** Structure (findings-date stamp is mandatory — executing-plans Step 1.5 keys staleness to it):

```
### Pattern Research

> **Findings date:** YYYY-MM-DD

**Library docs (preflight)** — [list | "no third-party deps in plan — skipped"]

**Library version & API surface** — [3+ calls | skipped]
- Canonical: [finding]
- Competitor variance: [finding]
- Known pitfall: [finding]

**Idiomatic usage patterns** — [3+ calls | skipped]
- Canonical: [finding]
- Competitor variance: [finding]
- Known pitfall: [finding]

**Library/framework pitfalls** — [3+ calls | skipped]
- Canonical: [finding]
- Competitor variance: [finding]
- Known pitfall: [finding]
```

**Skip propagation (issue #231 H5):** when Step B skips a bucket or the entire gate, document the skip in this block using the executing-plans-recognized vocabulary — `> Gate skipped: <justification>` / `> Bucket [name] skipped: <justification>` (or, for a scoping-side skip, `> Research skipped: no demonstrated gap`). A documented skip takes precedence over findings-date absence at execution (no re-verify).
