---
name: research
description: "Use for ANY non-trivial research — whether the user says 'research this' or the agent needs to investigate a technical question, compare approaches, evaluate trade-offs, understand a new domain, or make architecture decisions. Provides problem reframing, domain detection (Clear/Complicated/Complex), internal+external search, adversarial queries, and depth scaling. NOT for trivial single-fact lookups or content-pipeline keyword/SERP research (use content-research for that)."
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task mcp_load mcp__seo-intelligence__perplexity_search mcp__seo-intelligence__perplexity_research
version: 1.4.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

## Research Discipline

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md). Tier 3 integration (full protocol). All five dimensions apply: best practices, challenge definition, internal+external, adversarial, don't reinvent.

**Protocol compliance self-audit:**
```
☐ Tortoise graph checked BEFORE deriving (Step 0.0b) — and the finding WRITTEN BACK to it
☐ Search-tool rung resolved at PREFLIGHT (Step 0.0) and stated in the output
☐ Domain classified before research (with rationale)
☐ Domain classification challenged (Standard+)
☐ Query budget respected per Tier-Domain table
☐ Query counts stated (`attempted / returned`) — a partial batch is reported, never hidden
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

General-purpose research skill that combines **four knowledge sources** to answer any question:

0. **The Tortoise graph** (Step 0.0b) — the fleet's memory: what we already concluded, and what we already **ruled out**
1. **Codebase & internal docs** — what we already know and have built
2. **External search** — outside knowledge, best practices, competitor patterns, how others solve this (Perplexity when it loads, otherwise `web_search` with the cheapest model — see the **Step 0.0 search ladder**)
3. **context7** — library/framework documentation (when the topic involves a specific library)

The bias is toward **using all four sources** — the graph first, and external search next. Outside knowledge adds context, validates assumptions, and surfaces patterns we wouldn't find internally.

## When to Use

- User says "research this", "look into", "investigate", "what do we know about", "explore options for"
- User asks a question that benefits from both internal and external knowledge
- Before making a technical decision where outside patterns would help
- When exploring a new domain, tool, service, or approach
- When comparing approaches or evaluating trade-offs
- Any ambiguous "research" request that isn't specifically about SEO keywords or content-pipeline SERP analysis

**Not for:** SEO keyword research, SERP analysis, or content-pipeline research briefs → use `content-research` instead.

## Process


### Step 0.0 — Search Tool Preflight (MANDATORY — before anything else)

**Resolve which search tool you will use, and say so in the output.** Never silently substitute: if the primary is unavailable, report it and name the rung you used. A silent fallback is indistinguishable from compliance — it also erases the config gap that caused it, so nobody fixes it (premise-labs#400).

**The tool ladder — take the lowest-numbered rung that loads. The cost gate applies at every rung.**

| Rung | Tool | Cost | Precondition |
|------|------|------|--------------|
| **1** | `mcp__seo-intelligence__perplexity_search` / `perplexity_research` | ~$0.005/query (cheapest) | `mcp_load seo-intelligence` succeeds |
| **2** | `web_search` with the model passed **explicitly** — `model="sonar"` (the cheapest, and the harness default); `model="sonar-pro"` only when justified | $1/$1 per M tokens (sonar); $3/$15 (sonar-pro) | always loadable |
| **3** | `web_fetch` for primary sources (vendor docs, specs, RFCs) | free | always available — no precondition |

> ⛔ **`exa` is NOT a search route and must not be used.** The owner's ruling (2026-10-31): *"exa should be uninstalled because I never wanted it. external research should be perplexity."* The `exa` MCP server has been removed from `templates/.mcp.base.json` and `.mcp.json` — the two source files every repo/global `.mcp.json` is materialised from. **If a tool offers `exa`, refuse it and say so** — do not load it, do not fall back to it. There is no rung for it on this ladder, and no case where it is the right route. This supersedes the earlier "lazy fallback" arrangement (#419): external search is **Perplexity, full stop**.

**Credentials:** both Perplexity routes authenticate with **`PERPLEXITY_API_KEY`** — rung 1's MCP server inherits it from the environment, rung 2's `web_search` tool uses it directly. It lives in `/home/cmux/keys.env` on the cells (mode 0600). If a route fails on auth, fix the key — never substitute a different search engine to "make progress" (that is the fail-open this rule exists to prevent).

**Rung 2's explicit-model rule:** `model="sonar"` is the default and the cheapest; `model="sonar-pro"` ($3/$15 per M tokens) is permitted **only when the extra quality is justified** — it is not approval-gated, but it must still be named explicitly, and it is never the default. **Rung 3 is a single tool:** `web_fetch` needs no precondition and is always available; it is not a search engine — it reads a URL you already have.

**⛔ The expensive-model prohibition is unchanged and absolute at every rung.** `model="sonar-deep-research"` and `model="sonar-reasoning-pro"` cost $5–40+ per call and require EXPLICIT user approval. Rung 2 is **not** a licence to reach for those — and never rely on the ambient default model either: **name the model on every `web_search` call**, so the call is priced rather than unpriced.

**Availability observed on this machine (agent-infra checkout, measured 2026-09-24 — re-test before quoting):**
- `mcp_load seo-intelligence` → **`Unknown MCP server 'seo-intelligence'`** — the server is absent from this machine's `.mcp.json`. **Rung 1 is currently UNAVAILABLE here.** Restoring it is a server-config/credential decision for a human — do not invent a config.
- `web_search` with `model="sonar"` → **works** (verified with a live call). **This is the tested fallback when rung 1 is unavailable.**
- `mcp_load exa` → **the server no longer exists** — it was removed from the templates by owner ruling (2026-10-31). Do not re-add it, do not attempt to load it.
- `mcp_load brave-search` → **`MCP error -32000: Connection closed`**. The `${BRAVE_API_KEY}` placeholder is **not** the cause: mcp-client expands an unset `${VAR}` to the **empty string** (`extensions/mcp-client/index.ts` — *"Plain ${VAR} → process.env[VAR] (empty string when unset)"*), so the server **does spawn** and then **exits 1** with `Error: A Brave API key is required via --brave-api-key, BRAVE_API_KEY, …` (re-verified 2026-09-24: exit code 1, *"Invalid configuration"*). The client surfaces that exit as the closed connection. **brave-search is not a rung of this ladder** — take the lowest rung that loads; record it and move on, do not retry-loop (lazy-load failure class #199/#358).

**PREFLIGHT output line (required in the research output):** `Search tool: <tool + model actually used> — <rung N | rung 1 unavailable: <observed error>> — queries: <attempted> attempted / <returned> returned`. If you moved past rung 1, the reason is stated there. **The two counts are mandatory and must reconcile with the queries the output reports as searched.** A `returned` count below `attempted` is a **partial run** — name every query that did not return, and never let the shortfall pass as a complete evidence set. On rung 2 the counts also expose the rate-limit failure below: a fan-out wider than the bound loses calls to HTTP 429 (Step 3, "Concurrency and 429").

### Step 0.0b — GRAPH FIRST (MANDATORY — before the problem reframing)

**The fleet's memory is the Tortoise hosted graph, not `MEMORY.md`** (owner ruling, 2026-11-02: *every dispatch uses the research skill, and the research skill checks the graph*). A conclusion the graph already holds — **especially one it has already refuted** — costs two `curl`s to read and a whole lane to re-derive. Measured twice in one night: a root cause re-investigated that was already mapped, and a false "the SDK cannot delete an operator" that one call would have disproved.

**Reads (tested 2026-11-02).** Two reads, and they are **not** interchangeable: **`/v1/search?q=` is the only one that answers "what does the graph hold about this question"**, while **`/v1/context` is a recency digest** — it returns the ~20 most recently written points fleet-wide, takes **no query filter** (`?q=` is accepted and **ignored**: a nonsense token and an unrelated query returned the same 19 points, 19/19 overlap, measured 2026-11-02) and carries no `truncated` marker. A digest row is not a hit and a short digest is not a miss.

The credential is the **standard** variable `TORTOISE_MCP_API_KEY`; `TORTOISE_API_KEY` is the legacy compat alias, still exported with the same token (measured: identical value, Bearer → `200`) — a name to prefer away from, **not poison**. **The trap is the shell, not the name: bash sees neither variable** (`bash -c` reads length 0, `env | grep TORTOISE` → only `TORTOISE_HOME`) while every zsh route reads 35 (`zsh -c`, `zsh -lc`, `zsh -ic` alike, the exports now living in `~/.zshenv`). So read the key **through zsh** and **print the status code**: an error body is not "0 hits".

```bash
# Both reads print status + byte count and write the body to a per-run FILE: /v1/context is
# ~350 KB and a pasted body arrives truncated — a silently partial read of the evidence this
# step makes mandatory. Read fields with jq, never by dumping the file. The name carries `$$`
# because a fixed /tmp path lets two concurrent lanes read EACH OTHER's body and report its
# count and ids as their own (the #729 collision class).
# /v1/search is the HIT SOURCE (it pages at `limit`, default 10, and reports `truncated`).
# `-G --data-urlencode` is not optional: a raw `?q=` breaks on a space (curl exit 3, `HTTP 000`)
# and silently drops a `#` as a URL fragment — a bare `#3253` becomes an EMPTY query that answers
# `200 count=0`, i.e. a zero for a graph that was never asked.
zsh -ic 'curl -s -G --connect-timeout 10 --max-time 60 -o "$1" -w "HTTP %{http_code} bytes=%{size_download}\n" \
  -H "Authorization: Bearer $TORTOISE_MCP_API_KEY" \
  --data-urlencode "q=KEYWORDS" "https://api.premiselabs.co/v1/search"' _ "/tmp/tortoise-search.$$.json"
jq -r '.truncated, .count, (.results[] | "\(.id)  \(.similarity*1000|round/1000)  \(.content[:120])")' "/tmp/tortoise-search.$$.json" | head -21

# /v1/context is the RECENCY DIGEST — no query filter, ~20 latest points, not hits.
zsh -ic 'curl -s --connect-timeout 10 --max-time 60 -o "$1" -w "HTTP %{http_code} bytes=%{size_download}\n" \
  -H "Authorization: Bearer $TORTOISE_MCP_API_KEY" \
  "https://api.premiselabs.co/v1/context"' _ "/tmp/tortoise-ctx.$$.json"
jq -r '.recent_points[] | "\(.id)  \(.content[:120])"' "/tmp/tortoise-ctx.$$.json" | head -20
```

**`HTTP 200` is the only pass.** Only `401` is a credential fix (the key was empty or rejected); `402` is quota; `504` is a wait budget — retry once, and if it 504s again the query **did not run** (record it as not returned) rather than holding nothing. **`HTTP 000` means no response came back at all** — read curl's exit code instead of guessing: **3** = the URL was malformed (fix the encoding), **28** = it timed out (the query did not run), 6/7 = DNS/connect (did not run). The `--max-time 60` bound is what turns a slow server into a `failed:` entry instead of a stalled lane. None of them is a hit count of zero.

The BRIEF at `~/.pi/agent/state/TORTOISE-GRAPH-BRIEF.md` carries the write path and the error-code table (`401` = key empty or rejected, `402` = quota, **`504` = server wait-budget, not auth — retry once**); **two of its lines are superseded by this step and must not be followed**: its read recipe #1 (`/v1/context?q=…`, presented as question-scoped — it takes no query filter) and its "`TORTOISE_API_KEY` is EMPTY / a token swap 401s" credential note (the alias is populated and identical). *(The wrapper has LANDED: `~/.pi/agent/scripts/tortoise-graph.sh` on every box that runs `pi-bootstrap/setup.sh` / `cell-install.sh` (it is declared in `graph_srcs`, agent-infra#3253/#3374), and `scripts/tortoise-graph.sh` in a repo whose `scripts/` pointer resolves to the agent-infra scripts tree. Prefer it: it reads the key at call time, so it works in a long-lived process whose MCP entry pinned an empty bearer. The curl recipe remains the tested fallback when the client is absent.)*

**Why it is a hard step, not a courtesy call:** the graph is cheap to query and expensive to contradict — and neither of the two failures above skipped research. Both followed every other step perfectly; that is the class this step closes.

**Three rules:**

**(a) A hit is a PRIMARY SOURCE.** Cite the point — its `id` and its text — and build on it; do not re-derive a held conclusion as if it were new. If the point **contradicts** what you are finding, **that conflict IS the research question**: resolve it in the output (which one holds, on what evidence), never by silently preferring whichever sounds fresher.

**(b) A miss is NOT a finding.** Zero hits is a statement about your **query**, not about the graph — re-query in the domain's own vocabulary (a synonym, a subsystem name, an issue number) before concluding the graph holds nothing; and a row of the `/v1/context` digest is never a hit, so its absence is never a miss. ⛔ The **local** `tortoise` **MCP server is bound to a dead database** — `TORTOISE_DB_URI` → `127.0.0.1:16379`, port closed (measured 2026-11-02; agent-infra#3253) — so **an empty MCP result is MEANINGLESS**, never evidence that the graph holds nothing. Do not "fix" that by loading the server and reporting its silence as a finding. Two opposite errors to avoid when it answers badly: its *auth* failure inside a long-lived pi process is an **empty `${TORTOISE_MCP_API_KEY}` expansion, not a dead service** — the **hosted** endpoint `https://api.premiselabs.co/mcp/` is healthy (`initialize` → 200 over SSE; tool count varies — 69 with the fleet's graph-scoped key on 2026-11-02 — so read `tools/list` rather than trusting a number; graph point `1a19a9401a6-d74d62e9cd04`, re-measured), so never conclude "hosted is not configured" from it — and the *silence* of the local dead-DB entry is not a miss either. From a shell, the REST reads above are the tested route. (Step 1.7's `tortoise-memory.mjs` is that step's own script path and **not a substitute for this step**; it reads `TORTOISE_API_KEY` from the **process**, and a non-interactive shell has neither variable — so prefix the call as Step 1.7 shows, or its `not_configured` is a shell-visibility artifact, not a finding. A real credential gap is proven by a **`401`** on that read — a `402`, a `5xx`, or a `504` (the search read is wait-budget-flaky under load; retry once) leaves the credential question **open**, not answered.)

**(c) WRITE BACK at the end.** Every research output lands as a **point with edges** — the edges are what make it findable, and an orphan point is invisible: **IMPL** for what it addresses, **NAND + the reason** for what it rules out, **mitigations with strengths**, and its relation to the issue/epic. *(Step 5.4's `write-claim` script persists the claim text; it cannot do the edge work, and the edge work is the difference between filed and findable.)* ⛔ **Read `how-to-use-tortoise` IN FULL before any graph write** — this is a gate, not a reference: a **batch-connected mitigation nukes EP weights graph-wide**, mitigations are **0.10–0.50**, **annotate rather than create** when unsure, and a superseded operator must not leave live edges behind. Keep it current in the same session: a merge, a fix, or a **reversal** updates the point that describes it, because a lagging graph is not neutral — it is confidently wrong, and the next lane acts on it.

**PREFLIGHT output line (required, next to the Step 0.0 line):** `Graph: <n> hit(s) over <k> queries (<q1>, <q2>…) — <built on it | nothing held, re-derived | contradicted, conflict resolved | unread — no query ran | partial — <j> of <m> angles unanswered> | wrote: <session <id> → points <id,…> + edges | point <id> + edges | not written — <write attempted> → <result observed>> | failed: <qN> <code> (did not run)`. Both counts are mandatory: `0` after one query and `0` after five in-vocabulary queries are different claims, and only the second one is a miss you may report. **`<k>` counts queries that RAN** — a query listed in `failed:` is not one of them, so a partial run can never pad the count past the lazy-zero rule. `<n>` comes from `/v1/search` only — never from the `/v1/context` digest, whose rows are not hits. `/v1/search` pages at `limit` (default 10), so when its `.truncated` is `true` the `<n>` is a **page**, not the holdings — write `≥<n>` and narrow the query. The `wrote:` field is what the checklist's "WRITTEN BACK" half is audited against, so it names the point **with its edges** (`IMPL → <id>`, `NAND <id> — <reason>`, `mitigation <id> @ <strength>`, or `edges: none — <why>`), or the session **plus the point ids it produced and their edge record** — a bare point id is an orphan and a bare session id hides one, and rule (c) exists because an orphan is invisible. A `not written` must name the write it **attempted** and the result it observed (`not written — POST /v1/sessions → 504 twice`); a bare "nothing to write" is not a value. **A query that did not run is listed in `failed:` and is never counted as a miss** — and never inside `<k>`: `504` twice on one of two queries is `0 hit(s) over 1 query (q1) — partial — q2's angle unanswered | wrote: session <id> → points <id,…> + IMPL → <id> | failed: q2 504×2 (did not run)`: **`partial` is not a clean disposition** — it records that a re-query is owed, which is what Step 5.5 asks you for. When **every** query landed under `failed:`, the disposition is **`unread — no query ran`**, because no other value is true — and `nothing held` is refused at `k = 1`, so an unrun angle can never be laundered into a miss. The slot itself is never omitted: when every query ran, write **`failed: none`**.

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
# (tt_... from the dashboard at tortoise.premiselabs.co — that is the sign-up site,
# NOT the API host). TORTOISE_BASE_URL overrides the API base; default
# https://api.premiselabs.co.
# The read path distinguishes three states in its `status` field (tortoise#3805):
# "ok" (the store answered — an EMPTY store is still "ok", read `count`),
# "not_configured" (EITHER the probe's GET /v1/team answered 401/403 — a
# graph-scoped key gets 403 GRAPH_SCOPED_TEAM_SURFACE BY DESIGN — OR
# TORTOISE_API_KEY was unset IN THIS PROCESS and no request was made, which with
# no interactive-zsh prefix is the shell-visibility artifact Step 0.0b measured), and
# "tortoise_unavailable" (key set, but the store could not be reached).
# Data subcommands always exit 0 so a missing optional dependency never fails the
# skill (Step 0.0b is the mandatory read; this one is additive); the `status`
# probe exits 0 / 4 / 3 so a harness can tell the three states apart.
# The script reads process.env.TORTOISE_API_KEY, and a non-interactive shell has
# NEITHER variable (Step 0.0b's measurement) — so a bare call reports not_configured
# having made no request at all. Hand it the key explicitly:
TORTOISE_API_KEY="$(zsh -ic 'printf %s "$TORTOISE_MCP_API_KEY"')" \
  node scripts/tortoise-memory.mjs query-prior-research --domain "<topic-or-domain>"
```

**Interpretation:**
- **Results found:** Summarize prior claims. Use them to refine the research scope — what was already established? What gaps remain? What assumptions were made previously?
- **`"status": "not_configured"`:** two different causes, and they are not interchangeable. (i) The key is set and the *probe* reached `GET /v1/team`, which answers 401/403 — a **graph-scoped** key is refused there **by design** (`403 GRAPH_SCOPED_TEAM_SURFACE`), so on this box it is the **expected** answer, not a credential gap (measured 2026-11-02: probe → `not_configured`, exit 4, while `query-prior-research` on the same key returned `{"status":"ok","count":10}`). (ii) `TORTOISE_API_KEY` was unset **in the process** and no request was made — with the prefix above that cannot happen, so a bare call reporting this is the **shell-visibility** artifact, not a credential gap; the gap is real only when the Step 0.0b read answers **`401`**; a `402`/`5xx`/`504` leaves the credential question open, not answered — and that read, not this probe, is the credential test. **Run the data subcommand anyway** — it does not use the probe — and this script is **not** a substitute for the Step 0.0b reads.
- **`"status": "tortoise_unavailable"`:** **this request** failed — a timeout or a 5xx, which fires on a healthy store too (measured 2026-11-02: a per-request timeout while the REST reads answered `HTTP 200`). The Step 0.0b reads, not this word, decide whether the store is up; never report "the graph is down" from it.
- **Zero results:** a statement about the **query** — re-query in the domain's vocabulary (Step 0.0b rule (b)) before recording a miss. `0` after one query is not "no prior claims".

**Preserve provenance:** When citing prior claims in the research output, reference the Point ID and authoredBy field so the reader can trace the claim's origin.

### Step 2 — Internal Knowledge (Codebase + Docs)

**Always start here.** Check what we already know:

1. **Search the codebase** — Grep/Glob for relevant code, patterns, existing implementations
2. **Read internal docs** — Check `docs/` directory, `CLAUDE.md`, `MEMORY.md` for relevant prior knowledge
3. **Check git history** — `git log --oneline --grep="[topic]"` for past decisions and context. Escape user input: replace `"` with `\"` and `;` with `\;` before interpolation.

**Output:** Brief summary of what we already have internally. If nothing relevant exists, say so — that's useful information too.

### Step 3 — External Knowledge (via the Step 0.0 search ladder)

**Default: always run this step.** The bias is toward external search — outside knowledge almost always adds value. Skip ONLY if the question is purely about our own codebase internals (e.g., "where is the auth middleware defined?").

**Tool selection — take the lowest rung from Step 0.0 that loads, and state it. That ladder is authoritative; this list mirrors it:**
- **Rung 1** — `perplexity_research` for multi-angle investigation, comparing approaches, "how do others do X" (preferred — richer results, cheapest at $0.005/query); `perplexity_search` for quick single-question lookups, fact checks, "what is X" ($0.005/query). Usable **only if `mcp_load seo-intelligence` succeeds**.
- **Rung 2 (the tested fallback)** — `web_search` with the model passed **explicitly and cheaply**: `model="sonar"` for AI-summarized answers when you need synthesis ($1/$1 per M tokens); `model="sonar-pro"` for better quality when justified ($3/$15 per M tokens). Never omit the model.
- **Rung 3** — `web_fetch` for primary sources (vendor docs, specs, RFCs). Use when the question needs authoritative primary documents rather than a synthesized answer. It reads a URL; it does not search.

⛔ **`exa` is not a rung, not a fallback, and not a tool to load.** See the ruling in Step 0.0 above.

**If rung 1 is unavailable, say so in the output and name the rung you used** — never silently substitute.

**⛔ NEVER use `web_search` with `model="sonar-deep-research"` or `model="sonar-reasoning-pro"` without EXPLICIT user approval.** These cost $5–40+ per call (one call burned $43 in reasoning tokens in our billing). The tool itself blocks these models and will tell you to ask the user.

**Query design — design 3-5 queries, then dispatch them within the rung's concurrency bound below. Use the rung-1 tool (`perplexity_research`), or on rung 2 separate `web_search` calls with the model named explicitly (`model="sonar"`):**

**Concurrency and 429 — the rungs have different shapes.** On **rung 1**, `perplexity_research` can carry a set in **one call** with an array (`query: ["…", "…"]`, up to 5) — one request, so a 3-5 query sweep needs no per-call fan-out (a longer run is split into further batched calls of ≤5 each). Where a consumer workflow requires **separate** invocations for framing independence — `writing-plans` mandates one framing per call, and that rule stands — those separate rung-1 calls are still subject to the same Perplexity concurrency bound as rung 2: **at most 2 in flight, 2-wide or sequential.** On **rung 2**, every query is a **separate `web_search` call**, and Perplexity rate-limits concurrent calls: **HTTP 429 `request_rate_limit_exceeded`** (measured 2026-10-15 — 5 concurrent → 2 returned / 3×429; 4 concurrent → 1 returned / 3×429; the same calls run one at a time all succeed). **So on rung 2 run at most 2 concurrently — 2-wide or sequential, never the whole set fanned out.**

**429 handling (rung 2):** a query answered with 429 is **retried serially** — alone, after a short backoff (a few seconds; never re-fan-out). If it still fails it is **not-run**: it does not count as covered, it is named in the output (Step 0.0 PREFLIGHT counts + the Step 5 source list), and if it carried an adversarial or stack-specific angle the synthesis says that angle is **unprobed** rather than implying it was searched. **Never silently drop a 429'd query** — a truncated batch that reads as complete is the failure this rule exists to prevent (agent-infra#1779).

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

YouTube is often the first place leading-edge practice appears — before papers, blog posts, or documentation. When a YouTube URL is provided in the research topic OR external-search results include YouTube links, extract the transcript.

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



#### Academic / semantic discovery — no dedicated server (Perplexity + primary fetch)

> ⛔ **There is no `exa`. It was uninstalled by owner ruling (2026-10-31) and must not be re-added.**
> This section used to describe `exa` as a lazily-loaded semantic/scholarly fallback (#419). That
> arrangement is superseded: external research routes through **Perplexity** — rung 1
> (`perplexity_research` / `perplexity_search`) or rung 2 (`web_search`, `model="sonar"`) — and
> primary documents come from `web_fetch`.

**How to reach academic and semantic sources without it:**

- **Papers, preprints, people/company research** → rung 1 `perplexity_research` with a
  discovery-shaped query ("find the 2024–2026 papers on …", "which companies …"). Perplexity
  returns citations; follow them to the primary source.
- **A specific paper or spec you already have an identifier for** → rung 3 `web_fetch` on the
  DOI/arXiv URL. This is strictly better than a semantic search: it is the primary document.
- **Semantic Scholar / OpenAlex** (below) remain available as **deprecated**, direct-API routes.
  They need no MCP server and no key beyond their own — but they are noisy for general queries
  and are not a substitute for a search engine.

**Brave** — backup only, and **NOT currently loadable on this machine**: it is configured in `.mcp.json`, but `mcp_load brave-search` fails with `MCP error -32000: Connection closed`. The placeholder is **not** the cause — mcp-client expands an unset `${VAR}` to the empty string, so the server **spawns** and then **exits 1** for the missing key (`Error: A Brave API key is required via --brave-api-key, BRAVE_API_KEY, …`), which the client reports as the closed connection (measured 2026-09-24, premise-labs#400). Setting `BRAVE_API_KEY` is the only thing that restores it; until then **it is not a rung** — resolve the route via the Step 0.0 ladder. Not a primary source — Perplexity returns better results for all tested query types.

#### Exa — REMOVED (do not re-add)

`exa` was a semantic-search MCP server (`npx -y exa-mcp-server`, `EXA_API_KEY`). It is **gone**:
removed from `templates/.mcp.base.json` and `.mcp.json` — the source files every repo-local and
global `.mcp.json` is materialised from. It must not be re-added (owner ruling, below).

**The owner's ruling, verbatim (2026-10-31):** *“exa should be uninstalled because I never wanted
it. external research should be perplexity.”*

So: do not `mcp_load exa`, do not add it back to a template "just for semantic searches", do not
name it in a sub-agent's `mcp_servers` param. If a tool or a doc offers it, refuse it and say so.
If a query genuinely needs semantic/scholarly discovery, the route is rung 1 Perplexity — see the
preceding section.

**Brave MCP** — independent index verification, configured but not loadable until `BRAVE_API_KEY`
is set (see above):
```json
// Add to .mcp.json:
{"brave-search": {"command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"], "env": {"BRAVE_API_KEY": "<key>"}}}
```
$1/mo for 200 queries. Independent index — cross-source fact-checking.

#### Semantic Scholar API (deprecated — unreliable)

**Deprecated.** Intermittent HTTP 500 errors. Keyword search returns noise for precise queries. For academic paper discovery, use rung 1 `perplexity_research` (a discovery-shaped query returns citations to follow) and `web_fetch` on the DOI/arXiv URL you land on. `exa` is **not** an alternative — it is uninstalled (Step 0.0). (optional — free API key required)

**Semantic Scholar** — academic paper search (200M+ papers):
```
API: https://api.semanticscholar.org/graph/v1/paper/search?query=<topic>&limit=10
curl -s "https://api.semanticscholar.org/graph/v1/paper/search?query=<topic>&limit=10"
```
Default: keyless operation (100 req/5min unauthenticated). With `SEMANTIC_SCHOLAR_API_KEY` (see #5070): premium tier with higher rate limits. The legacy wrapper lives in the **eldato** repo at `operations/tools/research/semantic_scholar_client.py` (run from an eldato checkout: `python3 operations/tools/research/semantic_scholar_client.py --query "..." --limit 10`). Activate when research needs peer-reviewed sources (architecture decisions, methodology questions, claims requiring academic backing). English-only — humanities and non-English papers underrepresented. Independent source category for confidence-tier classification (§5a). Graceful degradation: if API unavailable or rate-limited → skip with note "Semantic Scholar unavailable — academic sources not included."

Skip if the topic is conceptual, strategic, or not tied to a specific library.


#### OpenAlex API (deprecated — search noise)

**Deprecated.** Citation-sorted keyword search returns completely off-topic results (e.g., "Gradient-based learning, 1998" for review methodology queries). Citation bias buries recent relevant papers. For citation-ranked discovery, use rung 1 `perplexity_research` — `exa` is **not** an alternative (it is uninstalled, Step 0.0).

**OpenAlex** — academic works search (318M+ works, free and open):
```
API: https://api.openalex.org/works?search=<topic>&per-page=10
curl -s "https://api.openalex.org/works?search=<topic>&per-page=10"
```
Requires `OPENALEX_API_KEY` (set in `.env.local`) for polite pool access. Max 10 req/s, respects `Retry-After` headers. The legacy wrapper lives in the **eldato** repo at `operations/tools/research/openalex_client.py` (run from an eldato checkout: `python3 operations/tools/research/openalex_client.py --query "..." --limit 10`). Provides citation counts, publication year, venue, and open access status. Ideal for filtering and scoring candidate papers by academic impact. Graceful degradation: if API unavailable → skip with note "OpenAlex unavailable — academic metadata not included."

### Paper Discovery Flow (Multi-Source)

When research requires academic paper discovery, use this 4-stage pipeline:

#### Stage 1: Broad Scan
Use **Perplexity** (rung 1 `perplexity_research` preferred; rung 2 `web_search` with `model="sonar"` where rung 1 is unavailable) to surface candidate papers and topics, and Brave (independent index) only when it loads and index diversity is genuinely needed. Dispatch the external-search step **always, via the Step 0.0 ladder**. **`exa` is not part of this flow** — it is uninstalled (Step 0.0) and must not be re-added for paper discovery. Perplexity is the primary source: rung 1 is ~$0.005/query flat, rung 2 is $1/$1 per M tokens (sonar). Brave: $1/mo for 200 queries.

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

Combine all four sources into a **research summary**. Structure:

```markdown
## Research Summary: [Topic]

**Date:** YYYY-MM-DD

**Search + queries (Step 0.0 PREFLIGHT line):** `<tool + model> — <rung N | rung 1 unavailable: …> — queries: <attempted> attempted / <returned> returned`. When `<returned> < <attempted>`, name the queries that did not return and the angle each covered — the evidence set is partial and the synthesis must say so.

**Graph (Step 0.0b PREFLIGHT line):** `<n> hit(s) over <k> queries (<q1>, <q2>…) — <built on it | nothing held, re-derived | contradicted, conflict resolved | unread — no query ran | partial — <j> of <m> angles unanswered> | wrote: <session <id> → points <id,…> + edges | point <id> + edges | not written — <write attempted> → <result observed>> | failed: <qN> <code> (did not run)`. Use `≥<n>` when `/v1/search` returned `truncated: true` — a page is not the holdings. Every hit named here is cited in the body by `id` — a hit that only appears in this line is a claim the synthesis dropped.

### What We Have Internally
- [Summary of codebase findings, existing patterns, prior decisions]
- [Relevant docs or past implementations]

### External Findings
- [Key insights from external search (the tool named in the Step 0.0 PREFLIGHT line) — organized by theme, not by query]
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

**"Independent categories" defined:** Sources from different search engines (Perplexity rungs 1 and 2 are the same engine and count as ONE category; Brave, if it loads, is a second) OR different source types (academic, practitioner, documentation, competitor) count as independent. Two Perplexity results citing the same underlying article = 1 source. **`exa` is not a category** — it is uninstalled (Step 0.0); a claim that previously rested on exa alone is downgraded to `⚠️ single-source`.

**In the synthesis output:**
- Each claim section carries a confidence tag in its header: `**[LOW]** ⚠️ single-source — verify when new source available`
- Speculative claims get a `## Required Evidence` subsection
- The overall synthesis includes a `## Source Confidence Summary` table listing each claim with its tier and source count

### Step 5.4 — Write Findings to Epistemic Graph (S9)

**After synthesis, log key claims to the memory system so future research builds on accumulated knowledge.** At minimum, write one claim per Medium+ confidence tier. Low-confidence and speculative claims are optional — they carry a hypothesis tag and should only be written if they represent a useful direction.

```bash
# From the agent-infra checkout (hosted Tortoise API — see Step 1.7 for env). Same
# shell-visibility trap as Step 1.7: the script reads process.env.TORTOISE_API_KEY,
# which a non-interactive shell does not have — pass it in, or the write silently
# never leaves the box.
TORTOISE_API_KEY="$(zsh -ic 'printf %s "$TORTOISE_MCP_API_KEY"')" \
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

**Graceful degradation:** act on the **write's** result, never on a probe. `not_configured` from the script's `status` probe is usually `GET /v1/team` refusing a graph-scoped key (`403 GRAPH_SCOPED_TEAM_SURFACE`, measured 2026-11-02) — the data subcommands do not use it, and on the same key `query-prior-research` returned `{"status":"ok","count":10}`; `tortoise_unavailable` also fires on a timeout while the REST reads answer `200`. So run `write-claim` and read its **stdout `status`**: `"ok"` is the pass, and the **exit code is `0` for every data-subcommand outcome** (agent-infra#1182) — so the exit is not evidence that a write happened. Fall back only when `status` is not `ok`, and then to the BRIEF's tested `POST /v1/sessions` capture — but read what that capture **is**: it persists the **point** and has no edge API, so on its own it is an orphan, and `session → points` with no edge record is `missing-write-back` (Step 5.5). The fallback is **capture, then edges** — add the edge record through an edge-capable route, or write `edges: none — <why>` — never a fabricated `+ edges` on a route that cannot make one. It is never a licence to write nothing. `not_configured` is a statement about one endpoint, and a mandatory write-back that a health probe can silently disable is no gate. Rule (c)'s edge work needs an edge-capable route — `tools/list` on the hosted MCP at `https://api.premiselabs.co/mcp/` carries `tortoise_create_edge`, `tortoise_create_point`, `tortoise_create_operator` and `tortoise_mitigate_operator`; look for those names rather than trusting a tool count. Log note: name the route the claim actually took.

### Step 5.5 — Research Verifier (CPI-5: fresh-session review)

**Runs after synthesis, before wiki filing.** Dispatches a FRESH `task` sub-agent — NOT self-check. Per Self-Refine (NeurIPS 2023): 94% of LLM self-critique is wrong when feedback is internal. A fresh session has no memory of the research process and evaluates the output objectively.

**Dispatch:**
```
task(prompt='[VGATE] Review this research output for completeness and accuracy. Check:
1. Every claim section has a confidence tag
2. Contradictions between sources are flagged in a Contradictions section
3. Single-source claims have verify-when-available note
4. Write-back recorded: the Step 0.0b `Graph:` line carries its hit AND query counts, a disposition, a `wrote:` value, and a `failed:` slot. A missing write is `missing-write-back`; so is a `not written` that names no attempted write; so is **any `wrote:` value that names point ids without an edge record** — bare, or via `session → points` (`IMPL`/`NAND`/`mitigation`, or `edges: none — <why>`) — an orphan point is the failure rule (c) exists to prevent, and the `POST /v1/sessions` capture produces exactly that shape, which is why the edge route must be named. When the search answered `truncated: true`, the count must be written `≥<n>`: a plain `<n>` taken from a page is `unreconciled-graph-count`. A query listed under `failed:` did not run and **cannot** be counted as a miss. The script's `not_configured` probe is **not** an excuse — it is `GET /v1/team` refusing a graph-scoped key, or `TORTOISE_API_KEY` being absent from the process (Step 5.4) — and never a reason to skip.
5. Log entry appended to wiki/log.md per WIKI_SCHEMA.md INGEST format
6. The Step 0.0 PREFLIGHT line is present, names the search tool + model actually used, states the rung taken (or that rung 1 was unavailable and the reason), and its `attempted / returned` query counts reconcile with the queries the output reports as searched — a silently substituted rung is a gap, and so is an unreconciled shortfall (a rung-2 batch that lost queries to 429 and still reads as complete)

Return ISSUE blocks for any gaps found (zero issues = CLEAN).
RESEARCH OUTPUT: <full text>
')
```

**ISSUE block format:**
```
ISSUE:
  check_type: missing-confidence|unflagged-contradiction|untagged-single-source|missing-kg-fact|missing-log-entry|missing-search-preflight|unreconciled-query-count|missing-graph-check|missing-write-back|unreconciled-graph-count
  severity: P1|P2
  location: [claim section name]
  description: <what is missing>
  suggestion: <what to add>
```

**Gate:** If issues found → fix deterministically. Re-dispatch. Max 2 fix cycles. On 3rd cycle with issues → surface to user. Zero issues → CLEAN, proceed to wiki filing.

**The graph is checked too:** the reviewer asks for the Step 0.0b `Graph:` line (query text, hit + query counts, disposition, `wrote:` value) and re-dispatches `missing-graph-check` / `missing-write-back` for its absence. Two shapes are **refusals, not misses**: a `nothing held` disposition over a single query (`k = 1`) — Step 0.0b requires a re-query in the domain's vocabulary first, so `0` after one query is a lazy zero, not a miss — and a `not written` that names no attempted write. A run that lost a query to a transport or wait-budget failure is **`partial`**, not `nothing held`.

### Step 5.6 — The Adoption Gate (step-0 of the adoption path: contradiction test + `OVERRIDES`)

**MANDATORY before a convergent finding is applied anywhere — before cost, quality, convergence strength, or fit.** This is not a review of the research itself: a finding can be perfectly accurate and still **unadoptable**, because an owner decision outranks a convergent standard. *Adoption* means applying the standard — writing it into code, a plan, a promise, or a surface — and this gate runs before that.

1. **Name what the standard would touch.** If applied, which decisions, promises, architectures, or plan sections does it change?
2. **Check the record for each.** Search the decision surfaces: the ISSUE itself (`gh issue view <n> --comments`), `~/.pi/agent/state/DECISION-LEDGER.md`, plan docs, and Tortoise points. A **recorded decision** is an owner ruling, a decision section in a plan doc, a decision comment on an issue, or a Tortoise point carrying one — **not** an existing practice and **not** what the code happens to do today.
3. **Is the contradiction marked `OVERRIDES`?** A decision that deliberately goes against the common default carries an **`OVERRIDES:`** line naming the default concretely (see `AGENTS.md` → USER QUESTIONS PROTOCOL); the line is what makes the contradiction **findable**. **Either way, a contradicted decision is a HARD STOP** — the marker is discoverability, not the trigger.
4. **Hard stop → reopen, never adoption.** A standard that contradicts a decision is **not a candidate for adoption at all**: not "adopt with a caveat", not "escalate and adopt", not a footnote, and not a question to the owner with adoption presupposed. The route is to **reopen the decision in its own home** (its issue, plan doc, or Tortoise point), **put the evidence in front of the owner, and argue it.** Post the refusal on the issue — quote the `OVERRIDES` line if the decision carries one, otherwise name the decision and quote its own text — the finding is **not** discarded; it is the evidence for the reopen.
5. **If no recorded decision is reached, split the cases.** The field converges, nothing recorded contradicts it, **and it is aligned with the rest of our work** → **adopt it** and record the adoption, with sources, on the issue (no owner question — this is the `AGENTS.md` → USER QUESTIONS PROTOCOL rule, which is conjunctive). Otherwise — it does **not** clearly converge, **or** it converges but is misaligned with the rest of our work — the finding is a live question to be **argued with the owner**, not a candidate to be killed by analogy.

**Output line for the synthesis:** `Adoption gate: <adopt | reopen <decision ref> | owner question> — <why>`.

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
6. Does the output carry the Step 0.0 PREFLIGHT line — the search tool + model actually used, the rung taken (or that rung 1 was unavailable and why), and the `attempted / returned` query counts — and do those counts reconcile with the queries the output reports as searched (an unreconciled shortfall = a partial batch presented as complete)?
7. Does it carry the Step 0.0b `Graph:` line — query text, hit and query counts, disposition, the `wrote:` value **with its edge record**, and the `failed:` slot — and is every hit that line names actually cited in the body by `id`? A `nothing held` over a single query is not a miss (Step 0.0b requires a re-query before that claim), and a lost query makes the run `partial`, not `nothing held`; a `not written` that names no attempted write is not a write-back; a count taken from a `truncated: true` page without `≥` is a page reported as the holdings; and a query listed under `failed:` did not run, so it cannot be counted as a miss.

Return: PASS or ISSUES with specific gaps and suggested fixes.
```

If issues found → fix → re-dispatch with a fresh-session sub-agent. Continue until clean or convergence (NO ISSUES FOUND or same issues re-flagged 3 consecutive cycles). On stall → document remaining issues with "⚠️ stalled after N cycles — M issues remain" and proceed. Per the research protocol: "Research review is a distinct phase before planning begins."

### Distributed Sensing (Complex × Standard+ only, NEW)

For Complex-domain Standard+ tasks, apply distributed sensing before converging on findings:

1. **Dispatch 2-3 independent research sub-agents** to assess the same problem from different lenses (user-centric, systems-centric, outlier-seeking). Each gets the same problem statement, different perspective. **Each obeys Step 3's concurrency bound** — on rung 2 keep the aggregate concurrent `web_search` count at 2 across the group (stagger them), or the fan-out re-creates the 429 partial batch at the group level.
2. **Each researches independently.** No cross-talk.
3. **Map agreements and disagreements.** Where all agents agree → high-confidence. Where they diverge → that's where the interesting information lives.
4. **Treat outliers as signal.** Per Snowden: *"We don't see things we don't expect to see."*
5. **Synthesize across perspectives** capturing dominant views, minority views, and flagged outliers.

## Depth Scaling

| Signal | Depth | External Queries (via the Step 0.0 ladder) | Internal Search |
|--------|-------|-------------------------------------------|-----------------|
| Quick question, "what is X" | Light | 1-2 (rung 1 `perplexity_search`, else rung 2 `web_search` `model="sonar"`) | Grep only |
| "Research this", "look into" | Medium | 3-5 (rung 1 `perplexity_research`, else rung 2) | Grep + docs + git log |
| "Deep dive", "comprehensive", planning input | Deep | 5-8 (rung 1 `perplexity_research`, else rung 2) | Full codebase exploration + docs + git log |

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
| Skipping external search to "save time" | Outside knowledge almost always adds value. The user wants research, not just a codebase grep. Default to the Step 0.0 ladder — cheapest available rung first. |
| Silently substituting a search rung | Rung 1 unavailable and the agent quietly switches to `web_fetch`/raw HTML discovery without saying so: the output *reads* as compliance, the cost gate and adversarial-query machinery are gone, and the missing server config stays invisible. State the rung in the PREFLIGHT line (premise-labs#400). |
| Presenting a partial search batch as complete | A rung-2 fan-out wider than 2 loses calls to HTTP 429 and the agent synthesizes from the survivors while the output still reads as compliant — as few as 1-2 of 4-5 planned queries can carry a confident synthesis. Cap rung-2 concurrency at 2, retry a 429'd query serially, and carry `attempted / returned` counts in the PREFLIGHT line: a truncated batch must never read as a complete evidence set (agent-infra#1779). |
| Only searching internally | Internal knowledge has blind spots. External search surfaces patterns, gotchas, and alternatives we wouldn't find in our own code. |
| Running 10+ external queries | Diminishing returns. 3-5 well-crafted queries cover most topics. Go to 8 only for deep dives. |
| Dumping raw search output | Synthesize. The user wants a summary that combines internal + external context, not a paste of search results. |
| Skipping internal search | External knowledge without internal context = generic advice. Always check what we already have first. |
| Asking the user instead of researching | If the question is "how does X work" or "what's the best pattern for Y" — research it. Reserve human questions for UX, strategy, and ontology decisions. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
