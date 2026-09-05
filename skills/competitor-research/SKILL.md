---
name: competitor-research
description: Use when asked to "research a competitor", "analyze competitor X", "profile competitor", "competitive analysis", "competitor deep dive", or when evaluating a competitor's product, strategy, positioning, traction, or business model. Produces structured profiles following the skill's 11-dimension competitor template (bootstrapped to the output directory as _template.md on first run) and updates the competitive analysis synthesis.
domain: capability
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Competitor Research

> **Source:** Canonical copy at `skills/competitor-research/SKILL.md`. Consumers link this dir into their `operations/skills/` farm — edit here only.

Produces structured competitor profiles and updates the competitive analysis synthesis. Wraps the `research` skill as its research engine, adding competitive-intelligence-specific quality gates: source-URL verification, delta analysis, gap surfacing, analysis anchoring, and recency validation.

**Use this skill when:** asked to research a competitor, analyze a competitor's product/strategy, profile a company, or update the competitive landscape.

**Output:** A competitor profile at `docs/teams/<team>/product/competitors/<slug>.md` following the 11-dimension template, plus updates to `_analysis.md` (synthesis) and `_index.md` (registry) in the same directory.

**Team routing:** Output goes to the session's active team (detected from `AGENT_SESSION_TEAM` env var — `ELDATO_SESSION_TEAM` legacy alias — current working directory, or issue labels). The team is **declared to the user** at the start of each invocation so they can override if wrong (moving a folder is trivial). If team detection confidence <70%, the skill **asks** before proceeding. Directory is auto-bootstrapped if missing.

---

## Research Discipline

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md): the `research` engine runs at Tier 3 (full protocol per research-protocol §8) and this skill applies competitive-intelligence gates as an overlay. The research skill handles problem reframing (Step 0), internal knowledge (Step 2), external knowledge via Perplexity (Step 3), context7 library docs (Step 4), and synthesis (Step 5); this skill structures the output for competitive analysis and enforces domain-specific quality gates.



---

## Phase 0 — Team Detection & Output Routing

### 0a — Detect team

Resolve the team for output routing. Priority order:

1. `AGENT_SESSION_TEAM` environment variable (highest priority)
2. `ELDATO_SESSION_TEAM` (legacy alias — eldato sessions that set only the old var still resolve)
3. Current working directory — if under `docs/teams/<team-slug>/`, use that team
4. Issue labels on the current issue (e.g., `team:org-design`)
5. Inference from session context (what the user has been working on)

If confidence < 70%, **ask the user**: "Which team does this competitor research belong to?" with a list of known team slugs.

If confidence ≥ 70%, **declare to the user**: "Outputting to `docs/teams/<team>/product/competitors/`. Reply with a different team if that's wrong — trivial to move."

### 0b — Bootstrap directory

```bash
COMPETITORS_DIR="docs/teams/$TEAM/product/competitors"
mkdir -p "$COMPETITORS_DIR"

# Bootstrap template if missing — create full 11-dimension skeleton
if [ ! -f "$COMPETITORS_DIR/_template.md" ]; then
  cat > "$COMPETITORS_DIR/_template.md" << 'TEMPLATE_EOF'
# [Competitor Name]

> One-line description of what they are.

---

## 1. Overview

| Field | Value |
|-------|-------|
| Founded | |
| HQ | |
| Funding raised | |
| Team size | |
| Markets | |

*Last checked: YYYY-MM-DD*

---

## 2. Product Type

<!-- What they actually are. Adapt to domain: marketplace, SaaS, platform, infrastructure, etc. -->

*Last checked: YYYY-MM-DD*

---

## 3. Positioning & Messaging

**Tagline:**

**Value proposition (their words):**

**Brand voice:**

*Last checked: YYYY-MM-DD*

---

## 4. Target Audience

**Primary customers:**

**Use cases:**

*Last checked: YYYY-MM-DD*

---

## 5. Business Model & Pricing

**Revenue model:**

**Pricing tiers:**

**Who pays and for what:**

*Last checked: YYYY-MM-DD*

---

## 6. Product & Features

**Platform:** (web / mobile / API / CLI / all)

**Core capabilities:**
-
-
-

**Standout features:**

**Notable gaps:**

*Last checked: YYYY-MM-DD*

---

## 7. Go-to-Market & Acquisition

**Primary growth channels:**

**Sales motion:** (self-serve / sales-led / product-led / open-source)

**Key partnerships:**

*Last checked: YYYY-MM-DD*

---

## 8. Traction & Scale

| Signal | Value |
|-------|-------|
| Users / customers | |
| Revenue signals | |
| Press / notable mentions | |

*Last checked: YYYY-MM-DD*

---

## 9. Online Presence & Content

<!-- Adapt to domain: SEO metrics for B2C, GitHub stars for dev tools, docs quality for infra, etc. -->

**Primary online channels:**

**Content strategy:**

*Last checked: YYYY-MM-DD*

---

## 10. Community & Ecosystem

<!-- Adapt to domain: social media for B2C, GitHub/Discord for dev tools, partner networks for enterprise -->

| Channel | Followers / Members | Engagement notes |
|---------|---------------------|------------------|
| | | |

**Community mechanics:**

*Last checked: YYYY-MM-DD*

---

## 11. Customer Sentiment

**Sources checked:**

**What users/customers praise:**

**What users/customers complain about:**

**Overall sentiment:** Positive / Mixed / Negative

*Last checked: YYYY-MM-DD*

---

## Notes & Sources

<!-- Raw links, research dates, gaps documented -->

*Last updated: YYYY-MM-DD*
TEMPLATE_EOF
fi

# Bootstrap registry if missing
if [ ! -f "$COMPETITORS_DIR/_index.md" ]; then
  cat > "$COMPETITORS_DIR/_index.md" << 'INDEX_EOF'
# Competitor Registry

| Competitor | File | Product Type | Research Status |
|---|---|---|---|
INDEX_EOF
fi

# Bootstrap analysis if missing
if [ ! -f "$COMPETITORS_DIR/_analysis.md" ]; then
  cat > "$COMPETITORS_DIR/_analysis.md" << 'ANALYSIS_EOF'
# Competitive Analysis

## 1. Threat Map

### Tier 1 — Watch Closely

| Competitor | Why Tier 1 | Specific relevance | What to watch for |
|---|---|---|---|

### Tier 2 — Monitor

| Competitor | Overlap | Limiting factor | Watch if… |
|---|---|---|---|

### Tier 3 — Low / No Threat

| Competitor | Why Tier 3 |
|---|---|

---

## 2. Strategic Implications

<!-- Analysis of what competitor patterns mean for this team. -->

---

## 3. Feature Comparison

| Capability | Competitor A | Our Approach | Notes |
|---|---|---|---|

---

*Last updated: YYYY-MM-DD*
ANALYSIS_EOF
fi
```

---

## Phase 1 — Parse & URL Discovery

### 1a — Parse competitor

Extract from user input:
- **Competitor name** — primary identifier
- **Optional URL** — user may provide the competitor's website
- **Output directory** — resolved in Phase 0: `docs/teams/<team>/product/competitors/`

If the user provides partial or ambiguous naming, resolve via `web_search`:
```
web_search("<name> company product")
```

**Multi-product competitors:** When a competitor has multiple distinct products (e.g., Zep Cloud + Graphiti), create ONE profile per company covering all products. Use sub-sections within each dimension to distinguish products where they differ (pricing, features, target audience). If the products target fundamentally different markets with no shared strategy, ask the user whether to split into separate profiles.

### 1b — URL discovery

If user provided a URL → use it directly. If not:

```bash
web_search "<competitor name> official website"
```

Extract the primary domain from the top result. For competitors with multiple distinct products or acquired properties, capture all relevant domains.

### 1c — Check registry

Read `docs/teams/<team>/product/competitors/_index.md` to determine:
- Is the competitor already registered? (check the registry table)
- What is the current research status? (✅ Complete, ⚠️ Partial, not listed)
- What slug/filename is expected?

If the competitor is not in the registry, create a new entry. Derive the slug from the competitor name (lowercase, kebab-case).

---

## Phase 2 — Research (via research skill)

Dispatch a `task` sub-agent with the research skill to gather competitor intelligence. The sub-agent prompt MUST include:
- Competitor name and primary URL (and any secondary URLs)
- The 11-dimension `_template.md` as the output structure
- **Quality gate requirements** (inject these into the prompt verbatim):
  - Every factual claim (pricing, features, traction) must include source URL + retrieval date
  - When a page returns 404/paywall, document the gap explicitly — never fabricate from gaps
  - Quote competitor positioning verbatim — do not paraphrase
  - Mark confidence: `⚠️ single-source (Perplexity)` when no specific URL anchor exists
  - Adapt domain-specific metrics to the competitor's actual domain (don't force B2C metrics onto a B2B tool)

### Research query structure

Run queries organized by the 11 template dimensions. Dispatch in parallel where possible. **Adapt the specific metrics within each dimension to the competitor's domain** — what's relevant for a B2C marketplace (App Store ratings, Instagram followers) differs from a B2B infrastructure tool (GitHub stars, enterprise customers).

| Dimension | Query focus | Domain-adaptive notes |
|-----------|-------------|----------------------|
| **1. Overview** | Founded date, HQ, funding raised, team size, markets served | Source discovery is domain-adaptive: Tracxn/Crunchbase for VC-backed startups, LinkedIn for enterprise, GitHub for open-source. |
| **2. Product Type** | What they actually are — use domain-appropriate categories | Marketplace, SaaS, platform, infrastructure, dev tool, API, etc. |
| **3. Positioning & Messaging** | Tagline, value proposition (verbatim from their site), brand voice | Always quote verbatim. Paraphrasing loses nuance. |
| **4. Target Audience** | Customer profile, use cases, personas | Adapt: "businesses + end users" for B2C marketplaces, "developers + enterprises" for dev tools, "teams + departments" for B2B SaaS. |
| **5. Business Model & Pricing** | Revenue model, pricing tiers, who pays — with source URLs | Credit-based, subscription, marketplace commission, open-core, etc. |
| **6. Product & Features** | Platform surface, core capabilities, standout features, gaps | Adapt: web/iOS/Android for B2C; API/SDK/CLI for dev tools; dashboard + integrations for enterprise. |
| **7. Go-to-Market & Acquisition** | Growth channels, sales motion, partnerships | Self-serve, sales-led, PLG, open-source funnel, partner ecosystem. |
| **8. Traction & Scale** | Users, customers, revenue signals, press mentions | Adapt: downloads/MAU for consumer; GitHub stars/PyPI downloads for dev tools; ARR/logos for enterprise; App Store rating for mobile. |
| **9. Online Presence & Content** | Primary online channels, content strategy, SEO signals | Adapt: SEO/traffic for content-driven; GitHub/docs for dev tools; partner marketplace for platforms. Drop irrelevant metrics rather than forcing B2C SEO onto B2B tools. |
| **10. Community & Ecosystem** | Followers/members per relevant channel, community mechanics | Adapt: Instagram/TikTok for B2C; GitHub/Discord/Twitter for dev tools; LinkedIn for enterprise; partner ecosystem for platforms. |
| **11. Customer Sentiment** | Reviews, praise, complaints, overall sentiment | Adapt: App Store/G2/Capterra for SaaS; GitHub issues/Discord for dev tools; case studies/testimonials for enterprise. |

### Mandatory live web fetch

For dimensions 3, 5, 6, and 8: fetch the competitor's actual website pages via `web_fetch`. Pricing pages, feature pages, and "About" pages change frequently — do not rely solely on Perplexity summaries.

```bash
web_fetch "https://<competitor-domain>/pricing"
web_fetch "https://<competitor-domain>/features"
web_fetch "https://<competitor-domain>/about"
```

### Gap handling

When a competitor's pages return 404, require login, or are behind a paywall:
- Document the gap explicitly: `⚠️ pricing page behind login — data from Perplexity only, not verified against live site`
- Do NOT guess or fabricate prices/features from the gap
- The Gap Surfacing gate (Phase 4) enforces this

---

## Phase 3 — Draft Profile

Write the profile to `docs/teams/<team>/product/competitors/<slug>.md` following `_template.md`.

### Create vs. Update branching

**Profile does not exist** (first run — the common case):
- Create full profile with all 11 dimensions
- Every dimension gets a `*Last checked: YYYY-MM-DD*` date at the dimension level
- **Per-field granularity:** Within dimensions, sub-fields that change at different rates get individual date stamps:
  - **High-churn** (pricing, features): `*Last checked*` per sub-section — these change weekly
  - **Medium-churn** (traction, social followers): `*Last checked*` per dimension — these change monthly
  - **Low-churn** (overview, company facts): dimension-level stamp sufficient — these rarely change
- Factual claims (pricing, features, traction numbers) include source URLs in `## Notes & Sources`
- Skip delta analysis — nothing to diff against

**Profile exists** (re-research of a previously profiled competitor):
- Read the existing profile as baseline
- Research to confirm unchanged dimensions + expand changed ones
- **Delta analysis:** flag every dimension that changed since the prior profile. Format: `🔄 **Changed:** pricing increased from $29/mo to $49/mo (2026-07-06)` 
- Update `*Last checked*` dates
- Preserve historical data if it informs trajectory analysis

### Source-URL requirement

Every factual claim that is verifiable against a URL must include:
```
[Source](https://example.com/pricing) — retrieved 2026-07-06
```

Claims from Perplexity without a specific URL anchor:
```
⚠️ single-source (Perplexity) — verify against live site when accessible
```

### Profile format

Follow the structure bootstrapped in Phase 0b (`docs/teams/<team>/product/competitors/_template.md`) exactly — do not restate it here. If you edit the template, update the Phase 0b heredoc too; the two must not diverge.

The 11 dimensions, in order: **1. Overview · 2. Product Type · 3. Positioning & Messaging · 4. Target Audience · 5. Business Model & Pricing · 6. Product & Features · 7. Go-to-Market & Acquisition · 8. Traction & Scale · 9. Online Presence & Content · 10. Community & Ecosystem · 11. Customer Sentiment**, closing with **Notes & Sources**.

---

## Phase 4 — Draft Analysis

After the profile is written, produce the analysis layer. This is the "what does this mean" interpretation — not just facts, but strategic signal.

### 4a — Threat tier classification

Classify the competitor into Tier 1/2/3 following the team's `_analysis.md` §1 conventions. If no existing tier framework exists in the team's analysis, create one:

| Tier | Criteria | Review cadence |
|------|----------|---------------|
| **Tier 1** | Direct overlap in geography + customer + value prop | Quarterly |
| **Tier 2** | Real overlap but indirect/constrained | Every 6 months |
| **Tier 3** | No meaningful product or geographic overlap | No active monitoring |

### 4b — Analysis layer (per-section)

Per-dimension interpretation lives in the competitor's section of `_analysis.md`, **not** in the profile file — the profile stays factual (see Phase 6). Mirror each profile dimension there with an analysis sub-section. Every analysis claim must be anchored to profile data:

```
### Analysis: [Dimension]
- **What they optimize for:** <inferred from design choices> — [cites ≥2 data points from profile]
- **Strategic signal:** <what this reveals about their strategy> — [cites ≥2 data points]
- **Implication:** <how this affects our team's positioning or decisions>
```

**Anchoring rule (hard gate):** Every "what this means" claim must cite ≥2 specific data points from the profile above. Format citations as `[Profile §N]` referencing the dimension number. If <2 data points exist for a claim → mark as `⚠️ insufficient data — analysis skipped for [dimension]` and do not fabricate.

**Team-adaptive implications:** The "Implication" line should reference the team's actual domain, not a fixed company name. For the `eldato-app-team` analyzing a deals marketplace, the implication is about El Dato's positioning. For the `organisation-design-team` analyzing a memory platform, the implication is about architecture decisions. Derive the right framing from the team context.

### 4c — Update _analysis.md

Append or update the relevant sections in `docs/teams/<team>/product/competitors/_analysis.md`. If the team's `_analysis.md` lacks a `## <Competitor> — Analysis` subsection, bootstrap one — this is the home for the 4b per-dimension analysis. The analysis file structure adapts to the team's domain — use whatever sections the team's bootstrapped `_analysis.md` provides. Minimum update:

1. **Threat Map (§1):** Add/update the competitor's row in the appropriate tier table. Include: competitor name, why that tier, what specific relevance they have to this team, and what to watch for.
2. **Strategic Implications (§2):** Add 2-5 implications derived from the analysis layer. What does this competitor's approach mean for the team's decisions?
3. **Feature Comparison (§3):** If a feature comparison table exists, add the competitor. If not and this is the first competitor, bootstrap one.

**Team-adaptive sections:** Different teams care about different things. An app team analyzing a marketplace competitor needs positioning cheat sheets and feature matrices. An ops team analyzing a tool needs threat vectors and architecture implications. An outreach team analyzing a content competitor needs SEO overlap and keyword gaps. Use the sections that serve the team's domain — don't force all five El Dato-specific sections onto every team.

### 4d — Update _index.md

Update `docs/teams/<team>/product/competitors/_index.md`:
1. Add/update the registry row: `| Competitor | File | Product Type | Research Status |`
2. Update status: `✅ Complete` (all 11 dimensions filled with source URLs) or `⚠️ Partial` (dimensions missing or unverifiable)

**Registry columns are domain-adaptive.** The bootstrapped template uses 4 columns (Competitor, File, Product Type, Research Status). Add columns that matter for the team's domain (e.g., Geography for local-market competitors, Tier for threat-classified competitors, GitHub Stars for dev tools). Remove columns that don't apply.

---

## Phase 5 — Quality Gates (MANDATORY)

Before considering the profile complete, verify all 5 gates pass:

### Gate 1 — Source-URL
- [ ] Every pricing claim has a source URL + retrieval date
- [ ] Every feature claim has a source URL or `⚠️ single-source` annotation
- [ ] Every traction metric has a source URL or explicit date (e.g., "App Store shows 4.2★ as of 2026-07-06")

### Gate 2 — Delta Analysis (update only)
- [ ] If prior profile existed: every changed dimension flagged with `🔄 Changed:`
- [ ] Skip on first-run creates

### Gate 3 — Gap Surfacing
- [ ] Every 404/paywall/login-wall encountered is documented
- [ ] No fabricated data fills the gap

### Gate 4 — Analysis Anchoring
- [ ] Every "what this means" claim cites ≥2 data points from the profile
- [ ] Claims without citations → `⚠️ insufficient data — analysis skipped`

### Gate 5 — Recency Validation
- [ ] **Skip on first-run creates** — all dates are current by definition. Gate 5 is only meaningful for re-research of existing profiles.
- [ ] Pricing dimensions: `*Last checked*` date ≤ 30 days ago (re-research only)
- [ ] All other dimensions: `*Last checked*` date ≤ 90 days ago (re-research only)
- [ ] Stale dimensions flagged with: `⚠️ stale — last verified YYYY-MM-DD`

---

## Phase 6 — Architecture Deep-Dive (conditional)

**When to run:** The competitor's tech/architecture decisions inform the team's own architecture, strategy, or build-vs-buy decisions. Run Phase 6 only when all of (a)-(c) hold:
- (a) Competitor is **not Tier 3** (Tier 3 = no strategic relevance — light profile is sufficient)
- (b) **Architecture is relevant** to the team's domain (e.g., an app team analyzing a deals marketplace doesn't need deep architecture analysis of a loyalty SaaS)
- (c) User did **not** explicitly request a **"light"** or **"quick"** profile

Skip Phase 6 entirely when any of (a)-(c) fails.

**Output:** Appends to `docs/teams/<team>/product/competitors/_analysis.md` as a new section. Does NOT modify the profile — the profile stays factual; the deep-dive lives in analysis.

### 6a — Process/Component Map

Create a structured breakdown of how the competitor's product works. If the product is simple (single surface), skip to 6b.

```
┌──────────────────────────────────────────────────┐
│                  COMPONENT 1                      │
│  What it does, inputs, outputs                    │
└────────────────────────┬─────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────┐
│                  COMPONENT 2                      │
│  What it does, inputs, outputs                    │
└──────────────────────────────────────────────────┘
```

For each component: name, what it does, data in, data out, sync/async, what triggers it.

### 6b — Design Choice Tables

For each significant component (or for the product as a whole if it's simple), create a table:

| Decision | Choice | Rationale | What they optimize for |
|----------|--------|-----------|----------------------|
| Primary DB | PostgreSQL + pgvector | Composite-FK multi-tenancy, no new infra | Zero new infrastructure (developer adoption) |
| Queue backend | PostgreSQL-backed polling | No external broker. Sufficient throughput. | Simplicity over scalability |
| ... | ... | ... | ... |

**Column meanings:**
- **Decision:** The architectural question they faced
- **Choice:** What they picked
- **Rationale:** Their stated or inferred reason
- **What they optimize for:** The product strategy this serves (e.g., developer adoption, cost predictability, onboarding speed, enterprise compliance)

### 6c — Hidden Architecture

Identify what's really happening under the hood that surface analysis or docs don't reveal. Classic pattern: a competitor publicly disclaims using a graph DB while keeping graph-shaped data in JSONB columns and LLM tool calls.

**Investigation prompts:**
- What does their architecture SAY it does vs. what does it ACTUALLY do?
- Are there implementations hidden behind abstraction layers?
- Do they use X but call it Y for marketing reasons?
- What would break if you tried to replicate their architecture exactly?
- Is there an open-source component that reveals more than the marketing docs?

**Output format:**
```
### The uncomfortable truth

[What the architecture claims] — but **false at the implementation level.**

[Competitor] has [X] operations. They're just hidden:

**1. [Hidden pattern name]**
[Code/docs evidence of what's really happening]

**2. [Hidden pattern name]**
...

### The actual architecture: [pattern name]

[Diagram or description of the real architecture]

### Why this works for [competitor] (and only [competitor])

| Condition | [Competitor]'s reality |
|-----------|------------------------|
| [Constraint 1] | [How they satisfy it] |
| [Constraint 2] | [How they satisfy it] |
```

### 6d — Gap Consolidation

Collect every `⚠️` flag from the profile into a single "What's Missing / Weak" table:

| Gap | Detail |
|-----|--------|
| [Dimension or capability] | [What's missing or weak, from profile ⚠️ flags] |

Also add architectural gaps discovered during deep-dive (not just profile gaps).

### 6e — Optimization Function

Frame what this competitor is ACTUALLY trading off. Every architectural choice serves a product strategy, not a technical ideal.

**Format:**
```
maximize: [primary goal — e.g., developer_adoption × revenue_per_developer]
subject to:
  - [constraint 1 — e.g., zero_new_infrastructure]
  - [constraint 2 — e.g., per-tenant_isolation_guarantee]
  - [constraint 3 — e.g., onboarding_time < 5 minutes]
```

Then map design choices to constraints:

| Design choice | Serves which constraint |
|---------------|------------------------|
| PostgreSQL + pgvector | zero_new_infrastructure |
| Composite-FK multi-tenancy | per-tenant_isolation_guarantee |
| ... | ... |

### 6f — Copy vs Differentiate

Two explicit lists:

**What to copy:**
| Pattern | Why |
|---------|-----|
| [Specific pattern from their architecture] | [Why it applies to our context] |

**What to differentiate:**
| Pattern | Why |
|---------|-----|
| [Pattern we should do differently] | [Why their approach doesn't fit our context] |

---

## Post-Completion

After all phases complete and quality gates pass:

1. **Output the summary** (see below)
2. **Signal readiness:** "Files ready at `docs/teams/<team>/product/competitors/`. Review the profile and analysis, then `git add` + commit if satisfied."
3. **Do NOT auto-commit** — the user reviews the output before it lands in the repo. The skill produces files; committing is a separate decision.

## Output Summary

After completion, output a summary:

```
## Competitor Research — [Name]

**Team:** <team-slug>
**Profile:** docs/teams/<team>/product/competitors/<slug>.md
**Tier:** Tier 1/2/3 — <rationale>
**Status:** ✅ Complete / ⚠️ Partial — <what's missing>
**Analysis updated:** _analysis.md §<sections touched>
**Registry updated:** _index.md row <N>

### Key Findings
- <3-5 most important findings>

### Strategic Implications
- <2-3 implications for this team's domain>

### Gaps / Next Research
- <any dimensions needing follow-up, URLs behind paywalls, etc.>
```

---

## Anti-Patterns

| Anti-Pattern | Why It Matters |
|--------------|----------------|
| **Fabricating analysis from thin data** | Pre-launch/stealth competitors have sparse data. The anchoring rule prevents hallucination. "⚠️ insufficient data" is better than confident-wrong. |
| **Skipping live web fetch** | Perplexity summaries are days to weeks stale. Pricing changes weekly. Always fetch the actual pricing page. |
| **Paraphrasing competitor positioning** | Their exact words matter. Quote the tagline and value proposition verbatim. Paraphrasing loses nuance. |
| **Omitting source URLs** | A profile without source URLs is unverifiable. Every claim traceable to a URL must link to it. |
| **Creating profiles without updating analysis** | Profiles without analysis = half the value. Always update `_analysis.md` tier classification at minimum. |
| **Skipping registry update** | A profile not in `_index.md` is unfindable. Always update the registry row. |
| **Deep-diving Tier 3 competitors** | For competitors with no overlap, fill the profile quickly (light research). Don't burn queries on something with no strategic relevance. |
| **Re-researching without delta** | If re-profiling, the delta (what changed) is the whole point. Don't just regenerate the same profile. |
| **Forcing B2C metrics onto B2B competitors** | App Store ratings and Instagram followers mean nothing for an API platform. Adapt every dimension to the competitor's actual domain. Drop irrelevant metrics rather than filling them with "N/A." |
| **Using company-specific names in templates** | "Implication for El Dato" doesn't make sense for other teams. Use team-adaptive language throughout. The skill should work for any team, not just one. |

---

## Integration

- **Called by:** Direct user invocation (primary), team-specific strategy skills, research pipelines
- **Pairs with:** `research` skill (engine), `content-staleness-scanner` (future — detect stale profiles needing refresh)
- **Output consumed by:** `_analysis.md` (synthesis), team strategy documents, architecture decisions, competitive positioning briefs
- **Team-adaptive:** This skill works for any team by routing output to `docs/teams/<team>/product/competitors/` and adapting dimensions to the competitor's domain
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
