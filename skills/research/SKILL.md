---
name: research
description: "Use for ANY non-trivial research — whether the user says 'research this' or the agent needs to investigate a technical question, compare approaches, evaluate trade-offs, understand a new domain, or make architecture decisions. Provides problem reframing, domain detection (Clear/Complicated/Complex), internal+external search, adversarial queries, and depth scaling. NOT for trivial single-fact lookups or content-pipeline keyword/SERP research (use content-research for that)."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

## Research Discipline

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md). Tier 3 integration (full protocol). All five dimensions apply: best practices, challenge definition, internal+external, adversarial, don't reinvent.

**Protocol compliance self-audit:**
```
☐ Domain classified before research (with rationale)
☐ Domain classification challenged (Standard+)
☐ Query budget respected per Tier-Domain table
☐ Adversarial queries included (per task-type modifier)
☐ Theory-first query run (Complex / ComplicatedxComplex)
☐ Distributed sensing run (Complex x Standard+)
☐ Exaptation probe considered
☐ Research review or Ritual Dissent completed
☐ Verification strategy applied per domain
```

# Research

> **Source:** Canonical copy at `skills/research/SKILL.md`.

## Purpose

General-purpose research skill that combines **three knowledge sources** to answer any question:

1. **Codebase & internal docs** — what we already know and have built
2. **Perplexity** — outside knowledge, best practices, competitor patterns, how others solve this
3. **context7** — library/framework documentation (when the topic involves a specific library)

The bias is toward **using all three sources**, especially Perplexity. Outside knowledge adds context, validates assumptions, and surfaces patterns we wouldn't find internally.

## When to Use

- User says "research this", "look into", "investigate", "what do we know about", "explore options for"
- User asks a question that benefits from both internal and external knowledge
- Before making a technical decision where outside patterns would help
- When exploring a new domain, tool, service, or approach
- When comparing approaches or evaluating trade-offs
- Any ambiguous "research" request that isn't specifically about SEO keywords or content-pipeline SERP analysis

**Not for:** SEO keyword research, SERP analysis, or content-pipeline research briefs → use `content-research` instead.

## Process


### Step 0 — Problem Reframing (NEW)

**Before researching solutions, challenge the problem definition** per the research protocol §1.2:

1. **5 Whys:** Ask "why is this needed?" up to 5 times to find the root cause
2. **How Might We:** Generate at least 2 alternative framings of the problem. "How might we achieve [outcome] without [assumed approach]?"
3. **Assumption mapping:** List every assumption being made. Tag each as `[validated]` or `[unverified]`
4. **Aporetic Turn:** If the question cannot be answered with the current framing — *"a question you can only answer if you think differently about the problem"* (Snowden) — change the framing, not the search effort
5. **Reverse the problem:** "What if we tried the opposite? What constraints would that surface?"

If reframing reveals the problem is in a different domain than assumed, adjust the research approach per the Tier-Domain Behavior Table.

**Output:** A reframed problem statement before entering solution research. Format: "[User] trying to [job] but [barrier] which results in [negative outcome]."

### Step 1 — Understand the Question

Parse the user's request into:
- **Topic:** What specifically to research
- **Context:** Why they're asking (feature work, bug, decision, curiosity)
- **Scope:** How deep to go (quick lookup vs. comprehensive investigation)

If the request is vague, ask ONE clarifying question maximum. Default to medium depth.


### Step 1.5 — Scope Parsing + Domain Routing (NEW)

**Parse scope flags from user input.** The `/research` command accepts:

**Ontology reference:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d`. Entity kinds `ResearchBrief`/`Brief` (Document kinds) define research outputs. **Routing flag:**
- `--domain=<slug>` — routes output to a documentation domain wiki. Canonical.

| --domain flag | Wiki path | Auto-bootstrap? | Notes |
|---------------|-----------|-----------------|-------|
| `product` | `docs/01_product/wiki/` | Yes | Product specs + strategy (merged). |
| `data` | `docs/02_data/wiki/` | Yes | Ontology, canonical schemas. |
| `engineering` | `docs/04_platform/wiki/` | Yes | Dev, auth, DB, deployment, platform, security, ADRs. Wiki path retains 04_platform/ for backward compat. |
| `ux` | `docs/07_ux/wiki/` | Yes | Design specs, journey maps, interaction patterns. |
| `growth` | `docs/05_growth/wiki/` | Yes | Marketing, SEO, content, CRM, sales, support. |
| `operations` | `docs/06_operations/wiki/` | Yes | CI/CD, migrations, agent ops, workflows, skills, L&D. |

| `legal` | `docs/10_legal/wiki/` | Yes | Legal & Compliance — contracts, compliance, data protection. |
| `finance-accounting` | `docs/11_finance/wiki/` | Yes | Finance & Accounting — billing, spend analysis. |
| `capability` | `docs/12_capability/wiki/` | Yes | Org Development & Capability — workflows, skills, roles, Identity. |

**Deprecated aliases (transitional, emit warning):**
- `--team=marketing` → `--domain=growth`
- `--team=dev` → `--domain=engineering`
- `--team=ops` → `--domain=operations`
- `--domain=search` → `--domain=growth` (deprecated)
- `--domain=strategy` → `--domain=product` (deprecated)
- `--domain=platform` → `--domain=engineering` (deprecated)
- `--domain=architecture` → `--domain=engineering` (deprecated)
- `--domain=finance` → `--domain=finance-accounting` (deprecated)

Other `--team` values belong to the #4930 2-axis scope system and are orthogonal.

**Inference:** If `--domain` is omitted, infer domain from topic context (current directory, surrounding conversation, issue labels). If confidence < 70%, confirm with user: "Routing to `<domain>` wiki — correct?"

**Unknown domain:** Error with message: `Unknown domain: X. Registered: product, data, engineering, ux, growth, operations, legal, finance-accounting, capability.`


### Step 1.7 — Epistemic Memory Checkpoint (S9)

**Query the epistemic graph for prior knowledge about the research topic BEFORE scanning the codebase or web.** This surfaces claims, decisions, and hypotheses we already logged — avoiding redundant research and building on accumulated knowledge.

```bash
# From the agent-infra checkout. Hosted Tortoise API — env: TORTOISE_API_KEY
# (tt_... from tortoise.premiselabs.co), TORTOISE_BASE_URL (default https://tortoise.premiselabs.co).
# No key → prints {"error":"tortoise_unavailable"} and exits 0 (skip step).
node scripts/tortoise-memory.mjs query-prior-research --domain "<topic-or-domain>"
```

**Interpretation:**
- **Results found:** Summarize prior claims. Use them to refine the research scope — what was already established? What gaps remain? What assumptions were made previously?
- **"tortoise unavailable":** `TORTOISE_API_KEY` missing or API unreachable — memory system offline. Skip this step — proceed with fresh research.
- **Zero results:** First research on this topic. Note "no prior epistemic claims found" and proceed.

**Preserve provenance:** When citing prior claims in the research output, reference the Point ID and authoredBy field so the reader can trace the claim's origin.

### Step 2 — Internal Knowledge (Codebase + Docs)

**Always start here.** Check what we already know:

1. **Search the codebase** — Grep/Glob for relevant code, patterns, existing implementations
2. **Read internal docs** — Check `docs/` directory, `CLAUDE.md`, `MEMORY.md` for relevant prior knowledge
3. **Check git history** — `git log --oneline --grep="[topic]"` for past decisions and context. Escape user input: replace `"` with `\"` and `;` with `\;` before interpolation.

**Output:** Brief summary of what we already have internally. If nothing relevant exists, say so — that's useful information too.

### Step 3 — External Knowledge (Perplexity)

**Default: always run this step.** The bias is toward using Perplexity — outside knowledge almost always adds value. Skip ONLY if the question is purely about our own codebase internals (e.g., "where is the auth middleware defined?").

**Tool selection:**
- `perplexity_research` — for multi-angle investigation, comparing approaches, "how do others do X" (preferred — richer results, cheapest at $0.005/query)
- `perplexity_search` — for quick single-question lookups, fact checks, "what is X" ($0.005/query)
- `web_search` (model="sonar") — for AI-summarized answers when you need synthesis ($1/$1 per M tokens)
- `web_search` (model="sonar-pro") — for better quality when justified ($3/$15 per M tokens)

**⛔ NEVER use `web_search` with `model="sonar-deep-research"` or `model="sonar-reasoning-pro"` without EXPLICIT user approval.** These cost $5–40+ per call (one call burned $43 in reasoning tokens in our billing). The tool itself blocks these models and will tell you to ask the user.

**Query design — run 3-5 queries in parallel via `perplexity_research`:**

1. **Direct question:** `"[topic] best practices [year]"`
2. **How others solve it:** `"[topic] implementation patterns real-world examples"`
3. **Trade-offs:** `"[topic] pros cons alternatives comparison"`
4. **Gotchas:** `"[topic] common mistakes pitfalls lessons learned"`
5. **Adversarial (NEW):** `"[topic] problems failures limitations production"` and `"why [approach] fails in practice"` — seek disconfirmation, not just confirmation
6. **Our stack specifically** (if relevant): `"[topic] with [Supabase/React/Cloudflare Workers/etc]"`

Adapt queries to the actual topic — these are templates, not rigid formulas.

**For Spanish-language or Mexico-specific topics**, add ES queries:
- `"[tema] mejores prácticas México"`
- `"[tema] experiencia empresas latam"`

### Step 4 — Library Docs (context7)

**Run when the topic involves a specific library or framework.** Use `resolve-library-id` then `query-docs` for:
- API syntax questions
- Version-specific behavior
- Configuration options
- Migration guides



#### YouTube Transcripts (NEW — optional leading-edge source)

YouTube is often the first place leading-edge practice appears — before papers, blog posts, or documentation. When a YouTube URL is provided in the research topic OR Perplexity results include YouTube links, extract the transcript.

**Extraction:**
```bash
# Validate URL before passing to yt-dlp — reject non-YouTube domains
[[ "<URL>" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]] &&   yt-dlp --write-sub --skip-download --sub-lang en,es --convert-subs srt "<URL>" --output /tmp/yt-transcript
```
**Security:** URL is validated against YouTube domain regex before shell interpolation. Non-YouTube URLs are rejected. No `;`, `|`, `` ` ``, or `$(` characters pass the regex gate.

**Integration rules:**
- Transcript content is included as a source in Step 5 synthesis
- Default confidence: ⚠️ single-source (one creator, one video) — unless corroborated by other independent sources
- Transcript saved as raw source: `docs/<domain>/raw/YYYY-MM-DD-youtube-<video-id>.md`
- **Graceful degradation:** If yt-dlp not installed → skip with note "yt-dlp not available — install via `pip install yt-dlp`". If video has no captions → skip with note "no captions available for this video". Never blocks research flow. **Flag the gap:** When a YouTube source is skipped, note in the synthesis source list: "⚠️ YouTube source `<URL>` unavailable (no captions / yt-dlp missing) — content not included in analysis." This prevents silent source loss.

**Multi-language:** Attempt English (`en`) subtitles first, fall back to Spanish (`es`). Auto-caption WER 10-30% — note reduced reliability when using auto-generated captions.



#### Exa (semantic/scholarly discovery — DEPRECATED from core, lazy on demand #419)

**Exa** — semantic search for academic papers and technical content. **Secondary, on-demand source — NOT primary** (#419). Perplexity is the primary source for all web research; Exa is a lazy fallback used only when a query needs semantic/scholarly/entity discovery that keyword retrieval misses: specific papers, arXiv preprints, technical documentation, people/company/prospect research. **It is no longer loaded at session start.** Invocation: `mcp_load exa` → next turn `mcp__exa__web_search_exa` (or stdin: `npx -y exa-mcp-server`). If `mcp_load` fails, degrade gracefully to Perplexity — do not retry-loop (lazy-load failure class #199/#358). **Sub-agents:** dispatched `task` sub-agents start with zero eager MCP connects (#286) — when a sub-agent may need semantic/scholarly discovery, name `exa` in the task tool's `mcp_servers` param, or instruct it to `mcp_load exa` mid-run.

**Brave** — backup only. Web search fallback if Perplexity is unavailable. Same invocation pattern. Not a primary source — Perplexity returns better results for all tested query types.

#### Exa + Brave (legacy — formerly P1 add-ons)

**Exa MCP** — semantic discovery (embeddings-based, 81% WebWalker). **Lazy (on demand, #419) — do NOT add to eager core:**
```json
// .mcp.json (lazy — loads only via mcp_load exa):
{"exa": {"command": "npx", "args": ["-y", "exa-mcp-server"], "env": {"EXA_API_KEY": "<key>"}, "lazy": true}}
```
Free tier: $10/mo credits (~1.4K searches/mo). Catches what keyword search misses. Weak on time-sensitive queries (24% FreshQA).

**Brave MCP** — independent index verification (47% HLE):
```json
// Add to .mcp.json:
{"brave": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-brave-search"], "env": {"BRAVE_API_KEY": "<key>"}}}
```
$1/mo for 200 queries. Independent index — cross-source fact-checking.

**Status:** Exa installed but **lazy** (#419) — never eager, never primary. Load on demand via `mcp_load exa` only when a query needs semantic/scholarly/entity discovery (academic papers, arXiv, people/company/prospect research). Perplexity is the go-to source for everything else. Brave: $1/mo for 200 queries, lazy fallback. Cost discipline: prefer Perplexity first; use Exa/Brave only when semantic discovery or index diversity is needed. When active, they join Perplexity as independent source categories for confidence-tier classification (§5a).

#### Semantic Scholar API (deprecated — unreliable)

**Deprecated.** Intermittent HTTP 500 errors. Keyword search returns noise for precise queries. Use Exa for academic paper discovery instead. (optional — free API key required)

**Semantic Scholar** — academic paper search (200M+ papers):
```
API: https://api.semanticscholar.org/graph/v1/paper/search?query=<topic>&limit=10
curl -s "https://api.semanticscholar.org/graph/v1/paper/search?query=<topic>&limit=10"
```
Default: keyless operation (100 req/5min unauthenticated). With `SEMANTIC_SCHOLAR_API_KEY` (see #5070): premium tier with higher rate limits. The legacy wrapper lives in the **eldato** repo at `operations/tools/research/semantic_scholar_client.py` (run from an eldato checkout: `python3 operations/tools/research/semantic_scholar_client.py --query "..." --limit 10`). Activate when research needs peer-reviewed sources (architecture decisions, methodology questions, claims requiring academic backing). English-only — humanities and non-English papers underrepresented. Independent source category for confidence-tier classification (§5a). Graceful degradation: if API unavailable or rate-limited → skip with note "Semantic Scholar unavailable — academic sources not included."

Skip if the topic is conceptual, strategic, or not tied to a specific library.


#### OpenAlex API (deprecated — search noise)

**Deprecated.** Citation-sorted keyword search returns completely off-topic results (e.g., "Gradient-based learning, 1998" for review methodology queries). Citation bias buries recent relevant papers. Use Exa instead.

**OpenAlex** — academic works search (318M+ works, free and open):
```
API: https://api.openalex.org/works?search=<topic>&per-page=10
curl -s "https://api.openalex.org/works?search=<topic>&per-page=10"
```
Requires `OPENALEX_API_KEY` (set in `.env.local`) for polite pool access. Max 10 req/s, respects `Retry-After` headers. The legacy wrapper lives in the **eldato** repo at `operations/tools/research/openalex_client.py` (run from an eldato checkout: `python3 operations/tools/research/openalex_client.py --query "..." --limit 10`). Provides citation counts, publication year, venue, and open access status. Ideal for filtering and scoring candidate papers by academic impact. Graceful degradation: if API unavailable → skip with note "OpenAlex unavailable — academic metadata not included."

### Paper Discovery Flow (Multi-Source)

When research requires academic paper discovery, use this 4-stage pipeline:

#### Stage 1: Broad Scan
Use Exa (`mcp_load exa` first — lazy #419), Brave (independent index), and Perplexity (synthesis) to surface candidate papers and topics. Dispatch Perplexity always; Exa/Brave only when semantic or index diversity is needed. Perplexity first — it is the primary source; Exa free tier: $10/mo credits (~1.4K searches). Brave: $1/mo for 200 queries.

#### Stage 2: Filter
Use OpenAlex + Semantic Scholar to confirm relevance via metadata. Scoring rubric: citations > 10, year >= 2023, open access preferred. Normalize/dedupe results in synthesis: dedupe by DOI (exact), then title (fuzzy, difflib ratio >= 0.85). The legacy normalize helper lives in the **eldato** repo (`operations/tools/research/normalize.py` — run from an eldato checkout).

#### Stage 3: Deep Dive

Use Unpaywall for legal open access retrieval of top-N candidates by DOI:

```bash
# Unpaywall API is public and keyless (email required):
curl -s "https://api.unpaywall.org/v2/<doi>?email=<your-email>"
# Legacy wrapper: eldato repo operations/tools/research/unpaywall_client.py
#   python3 operations/tools/research/unpaywall_client.py --doi "10.xxx"  (run from an eldato checkout)
```

**Unpaywall** (OurResearch, nonprofit) — 56M+ open access articles from 50K publishers. Free, no API key. Returns OA status, PDF links, and repository locations. Legal — harvested from university repositories and publisher open content.

**CORE** (core.ac.uk) — 300M+ records, 40M full-text papers. Free API key from core.ac.uk/services/api. Supports keyword search + PDF download. Use when Unpaywall returns OA=false and the paper is critical.

**Sci-Hub is deprecated** (all mirrors unreachable as of 2026-07-01, see #5129). Do not use. Do not cite in methodology.

#### Stage 4: Claim Verification — DebateCV
Extract claims from PaperResult metadata (title + abstract). File claims in wiki/ for evidence. Run DebateCV for adversarial verification:

```bash
# Legacy DebateCV lives in the eldato repo (run from an eldato checkout):
#   python3 operations/tools/research/debatecv.py --claim "<extracted claim>" --domain <04_platform>
# (pass directory-form domain, e.g. 04_platform, not semantic slug)
```

> **Superseded:** the fresh-session Research Verifier (Step 5.5) and the adversarial queries in Step 3 cover claim verification without the eldato dependency — prefer those. DebateCV is optional when working from an eldato checkout.

### Step 5 — Synthesize

Combine all three sources into a **research summary**. Structure:

```markdown
## Research Summary: [Topic]

**Date:** YYYY-MM-DD

### What We Have Internally
- [Summary of codebase findings, existing patterns, prior decisions]
- [Relevant docs or past implementations]

### External Findings
- [Key insights from Perplexity — organized by theme, not by query]
- [Best practices, patterns, trade-offs discovered]
- [Gotchas or warnings relevant to our context]

### Library/Framework Specifics
- [context7 findings if applicable]

### Recommendation
- [Synthesized view: what approach makes sense given both internal context and external knowledge]
- [Open questions that need human decision]
```

Keep it concise. The goal is actionable insight, not an exhaustive report.

#### Step 5a — Confidence Tiers (NEW)

**Every research claim is filed — none are rejected.** Instead, claims are tagged by evidential strength:

| Sources | Confidence | Tag | Action |
|---------|-----------|-----|--------|
| 3+ independent categories | **High** | (none) | Filed normally — sections get standard headers |
| 2 sources, different categories | **Medium** | `⚠️ emerging` | Filed with emerging tag in section header |
| 1 source only | **Low** | `⚠️ single-source` | Filed with single-source warning + "verify when new source available" note |
| 0 sources (LLM memory) | **Speculative** | `⚠️ hypothesis` | Filed as hypothesis with `## Required Evidence` section listing what would confirm/refute |

**"Independent categories" defined:** Sources from different search engines (Perplexity, Brave, Exa) OR different source types (academic, practitioner, documentation, competitor) count as independent. Two Perplexity results citing the same underlying article = 1 source.

**In the synthesis output:**
- Each claim section carries a confidence tag in its header: `**[LOW]** ⚠️ single-source — verify when new source available`
- Speculative claims get a `## Required Evidence` subsection
- The overall synthesis includes a `## Source Confidence Summary` table listing each claim with its tier and source count

### Step 5.4 — Write Findings to Epistemic Graph (S9)

**After synthesis, log key claims to the memory system so future research builds on accumulated knowledge.** At minimum, write one claim per Medium+ confidence tier. Low-confidence and speculative claims are optional — they carry a hypothesis tag and should only be written if they represent a useful direction.

```bash
# From the agent-infra checkout (hosted Tortoise API — see Step 1.7 for env):
node scripts/tortoise-memory.mjs write-claim \
  --content "<claim text>" \
  --kind "statement" \
  --authored-by "research-skill" \
  --confidence <0.0-1.0>
```

**What to write:**
- **Key findings** (Medium+ confidence) — the central claims the research established
- **Decisions made** — any go/no-go calls or approach selections
- **Open questions** — tagged as `kind: hypothesis` with low confidence, so future research can find and resolve them
- **Contradictions** — when sources disagree, write BOTH sides as claims linked via context

**Confidence mapping:**
| Tier | confidence value | kind |
|------|-----------------|------|
| High (3+ sources) | 0.8 | statement |
| Medium (2 sources) | 0.5 | statement |
| Low (1 source) | 0.3 | hypothesis |
| Speculative | 0.1 | hypothesis |

**Graceful degradation:** If `tortoise unavailable` → skip. Log note: "Memory system offline — claims not persisted to epistemic graph."

### Step 5.5 — Research Verifier (CPI-5: fresh-session review)

**Runs after synthesis, before wiki filing.** Dispatches a FRESH `task` sub-agent — NOT self-check. Per Self-Refine (NeurIPS 2023): 94% of LLM self-critique is wrong when feedback is internal. A fresh session has no memory of the research process and evaluates the output objectively.

**Dispatch:**
```
task(prompt='[VGATE] Review this research output for completeness and accuracy. Check:
1. Every claim section has a confidence tag
2. Contradictions between sources are flagged in a Contradictions section
3. Single-source claims have verify-when-available note
4. KG facts filed for key claims (skip if Tortoise unavailable)
5. Log entry appended to wiki/log.md per WIKI_SCHEMA.md INGEST format

Return ISSUE blocks for any gaps found (zero issues = CLEAN).
RESEARCH OUTPUT: <full text>
')
```

**ISSUE block format:**
```
ISSUE:
  check_type: missing-confidence|unflagged-contradiction|untagged-single-source|missing-kg-fact|missing-log-entry
  severity: P1|P2
  location: [claim section name]
  description: <what is missing>
  suggestion: <what to add>
```

**Gate:** If issues found → fix deterministically. Re-dispatch. Max 2 fix cycles. On 3rd cycle with issues → surface to user. Zero issues → CLEAN, proceed to wiki filing.

### Step 5b — Claim Verification (DebateCV)

For research that surfaces academic papers, optionally run DebateCV on key claims before the synthesis review:

```bash
# Legacy DebateCV — eldato repo (run from an eldato checkout):
#   python3 operations/tools/research/debatecv.py --claim "<claim>" --domain <04_platform>
```

DebateCV (`operations/tools/research/debatecv.py`, eldato repo) is an adversarial claim verifier using wiki evidence. Pro/con debater pattern with moderator. Claims should be extracted from PaperResult metadata (title + abstract) and filed in the domain wiki before running. See §Paper Discovery Flow Stage 4 above. **Prefer the fresh-session Research Verifier (Step 5.5) — it needs no eldato checkout.**


### Step 5c — Graph-Enhanced Synthesis (LightRAG)

For complex multi-document synthesis (5+ source documents, multi-hop questions), use LightRAG for entity-connected graph synthesis:

```bash
# Legacy wrapper — eldato repo (run from an eldato checkout, requires DEEPSEEK_API_KEY):
#   python3 operations/tools/research/lightrag_synthesize.py --docs docs/<domain>/wiki/ --query "what patterns emerge across sources" --mode hybrid
# Fresh install (any repo): pip install lightrag-hku
```

**LightRAG** (HKUDS, MIT license) builds a knowledge graph across documents and retrieves via hybrid mode (vector + graph). ~$0.002/query with DeepSeek. Requires `DEEPSEEK_API_KEY` set in env.

**Query routing guidance:**
| Question type | Tool | Why |
|---------------|------|-----|
| Simple fact, single doc | Direct read or Tortoise FalkorDB query | Lower latency, zero cost |
| Medium complexity, 2-5 docs | Manual synthesis (Step 5) | Agent context window sufficient |
| Complex, 5+ docs, multi-hop | LightRAG hybrid mode | Graph traversal finds cross-document connections |

The routing infrastructure costs more than it saves at <200 queries/month — when in doubt, use LightRAG + DeepSeek. The difference between $0.20/month and $5/month is noise.

### Step 6 — Research Review (Standard+Complex only, NEW)

For Standard and Complex tasks, dispatch a fresh-session sub-agent to review the research output for accuracy and completeness:

```
You are reviewing research output for accuracy and completeness.

RESEARCH OUTPUT: <the full research summary>

1. Are all factual claims supported by sources?
2. Is anything missing that should have been researched?
3. Are there contradictions or gaps in the evidence?
4. Does the recommendation follow from the evidence presented?
5. Were adversarial queries included and addressed?

Return: PASS or ISSUES with specific gaps and suggested fixes.
```

If issues found → fix → re-dispatch with a fresh-session sub-agent. Continue until clean or convergence (NO ISSUES FOUND or same issues re-flagged 3 consecutive cycles). On stall → document remaining issues with "⚠️ stalled after N cycles — M issues remain" and proceed. Per the research protocol: "Research review is a distinct phase before planning begins."

### Distributed Sensing (Complex × Standard+ only, NEW)

For Complex-domain Standard+ tasks, apply distributed sensing before converging on findings:

1. **Dispatch 2-3 independent research sub-agents** to assess the same problem from different lenses (user-centric, systems-centric, outlier-seeking). Each gets the same problem statement, different perspective.
2. **Each researches independently.** No cross-talk.
3. **Map agreements and disagreements.** Where all agents agree → high-confidence. Where they diverge → that's where the interesting information lives.
4. **Treat outliers as signal.** Per Snowden: *"We don't see things we don't expect to see."*
5. **Synthesize across perspectives** capturing dominant views, minority views, and flagged outliers.

## Depth Scaling

| Signal | Depth | Perplexity Queries | Internal Search |
|--------|-------|--------------------|-----------------|
| Quick question, "what is X" | Light | 1-2 via `perplexity_search` | Grep only |
| "Research this", "look into" | Medium | 3-5 via `perplexity_research` | Grep + docs + git log |
| "Deep dive", "comprehensive", planning input | Deep | 5-8 via `perplexity_research` | Full codebase exploration + docs + git log |

Default to **Medium** unless the user signals otherwise.

### Step 7 — Filing to Wiki (NEW)

> **⚠️ DATA CLASSIFICATION:** Before filing, review findings for sensitive data. Repo is private but all wiki content is committed to git history. Flag and redact: credentials, API keys, proprietary strategy not yet approved for sharing, unreleased product details, personally identifiable information (PII). When in doubt, surface to user before filing.

After research synthesis is complete, file to the domain wiki:

1. **Determine wiki path** from `--domain` flag (or inferred domain)
2. **Bootstrap wiki/ if missing** — create `wiki/{entities,concepts}` dirs + `index.md` + `log.md` + `synthesis.md` per WIKI_SCHEMA.md §8 bootstrap sequence. Frontmatter populated with domain slug and type.
3. **Write synthesis.md** — revisionist update. Merge new findings into existing synthesis. Preserve `## Core Thesis`, update `## Key Entities` and `## Key Concepts`, add to `## Active Debates` if findings raise open questions. Link to entity/concept pages (≥3).
4. **Append log.md** — INGEST entry per WIKI_SCHEMA.md §2.7: `[HH:MM] INGEST: research on <topic> → updated synthesis.md (N findings, M sources)`
5. **Deprecated domains:** `--domain=architecture` and `--domain=platform` emit deprecation warnings and route to `--domain=engineering`.

**Confidence annotations (from #4932):** Research claims carry confidence tiers. See the confidence-tier system for annotation format.

## Integration with Other Skills

- **Before `brainstorming`:** Research can inform brainstorming by providing external context
- **Before `writing-plans`:** Research findings feed into plan design decisions
- **Before `issue-scoping`:** Research can answer deferred technical questions
- **During `debug-workflow`:** Research can surface known library gotchas
- **Standalone:** Research can be the entire task — user just wants to understand something

## Anti-Patterns

| Anti-Pattern | Why It Matters |
|--------------|----------------|
| Using `sonar-deep-research` without approval | Costs $5–40+ per call. One call burned $43 in reasoning tokens in our billing. The tool blocks it — ask the user for explicit approval if truly needed. |
| Skipping Perplexity to "save time" | Outside knowledge almost always adds value. The user wants research, not just a codebase grep. Default to calling Perplexity (cheap Search API tools). |
| Only searching internally | Internal knowledge has blind spots. Perplexity surfaces patterns, gotchas, and alternatives we wouldn't find in our own code. |
| Running 10+ Perplexity queries | Diminishing returns. 3-5 well-crafted queries cover most topics. Go to 8 only for deep dives. |
| Dumping raw Perplexity output | Synthesize. The user wants a summary that combines internal + external context, not a paste of search results. |
| Skipping internal search | External knowledge without internal context = generic advice. Always check what we already have first. |
| Asking the user instead of researching | If the question is "how does X work" or "what's the best pattern for Y" — research it. Reserve human questions for UX, strategy, and ontology decisions. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
