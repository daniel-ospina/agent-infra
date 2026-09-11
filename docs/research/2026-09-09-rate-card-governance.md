---
title: "Rate-card governance — override vs consume upstream catalog, model-id lifecycle, and dated snapshots without a vendor API (#631)"
type: engineering
domain: operations
doc_status: live
created: 2026-09-09
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-631, pi-config, models-store, cost-config-policy
---

> **Findings date:** 2026-09-09
> Controller-verified primary source 2026-09-09; independently re-fetched by this agent
> **2026-09-10 11:50 EST** — page unchanged (see Raw Notes for the full table + footnotes).
> Issue: [#631](https://github.com/daniel-ospina/agent-infra/issues/631) · Level: project (standalone) · Depth: **medium**.
> Memory system: Tortoise returned `tortoise_unavailable` (GET /v1/search → HTTP 404) — no prior epistemic
> claims were retrievable; findings below are not cross-linked to graph Points.

> **⚠️ Revision (2026-09-10) — TL;DR SUPERSEDED on the headline recommendation.** Later verification at the installed-pi
> source level falsified this document's central recommendation ("consume upstream for first-party ids, override only
> where upstream is provably wrong"). Three verified findings overturn it:
>
> - **E1 — a `models.json` `models[]` row without `cost` prices at $0, it does NOT inherit upstream.**
>   `provider-composer.js:71`: `cost: definition.cost ?? {input:0,output:0,cacheRead:0,cacheWrite:0}`. Dropping our
>   cost to "let upstream own it" therefore stamps **$0 on every DeepSeek call** — a silent, total accounting loss.
> - **E4 — the shipped `pi-config/models-store.json` snapshot is INERT** under the installed pi:
>   `remoteModels()` drops an overlay whose `lastModified` (2026-07-31) predates pi-ai's catalog `generatedAt`
>   (2026-09-05). So "upstream" is **not one authority**: the 4h *store* carries the current card, while pi-ai's
>   **bundled** catalog still carries the July card — and the bundled layer is what a fresh box actually uses.
> - **E5/D4 — the store carries PEAK values** (`deepseek-flash` 0.3/1.2/0.006 = 2× off-peak), and it covers only the
>   vendor's *new* ids. An id we dispatch but do not define is therefore priced at **2×**, and our 102k-call
>   `deepseek-v4-flash` plus the fleet default are covered by it **not at all**.
>
> **Corrected direction (adopted by the plan):** maintain ONE dated in-repo rate ledger that both renders the runtime
> card and prices the report retroactively; keep an explicit own row for every **dispatched** id; use the store as a
> *sensor*, never an authority.
>
> **Also corrected here:** the §2 alias table omitted **`deepseek-v4.1-flash-expires-on-0910`** — the fleet's live
> `defaultModel` (2,830 calls as of 2026-09-10; an earlier draft of this artifact said 2,256 — the corpus grew
> during the session — see the plan §0 for the measurement date and method), which exists in **no** base layer. And §5's open question Q5 (the `setup.sh` merge
> semantics) is answered: see **#682**.
>
> Plan of record: `docs/plans/2026-09-10-issue-631-rate-card-governance.md`.

## TL;DR

The drift in #631 is not a stale-numbers bug — it is a **shadowing** bug. The upstream catalog we already
consume (`~/.pi/agent/models-store.json`, refreshed every 4h from pi.dev) **already publishes the current
DeepSeek card and the current model id**, and our hand-maintained `cost` block in `pi-config/models.json`
silently overrides it. The established pattern in every adjacent ecosystem (LiteLLM, OpenRouter, LangSmith,
gateways) is the same shape: **upstream catalog owns price, local config owns structure (context window,
clamps, routing), and any local price override must be narrow, dated, and loud** — never a whole-model
shadow. Two facts make string-equality drift guards the wrong gate: (a) the vendor publishes **no
machine-readable pricing endpoint** and **no "last updated" date**, and (b) from **2026-09-14** `deepseek-v4-pro`
is **date-gated** into Flash pricing, so the "correct" price for an id is a function of time, not a constant.
Recommended direction: **consume upstream for first-party ids, override only where upstream is provably wrong
(reseller ids that upstream prices at $0), keep one dated snapshot file with `asOf` + `sourceUrl` for
auditability, and use the 4h store refresh as the drift oracle instead of scraping the page.**

---

## 1. Rate-metadata authority: override vs consume upstream catalog

**Framing: canonical + competitor-precedent + internal evidence.**

**Internal evidence (decisive and verified):**
- `~/.pi/agent/models-store.json` (4h refresh) already carries `deepseek-flash` @ **peak** `0.30 / 1.20 / 0.006`
  and `deepseek-v4-pro` @ peak `1.32 / 3.96 / 0.044` — i.e. **exactly the current official card** (off-peak =
  peak ÷ 2 → `0.15 / 0.60 / 0.003`). Upstream is not stale; our config is. **[HIGH]** — direct read of the live file.
- The same store lists reseller entries `qwen-token-plan → deepseek-v4-flash` and
  `qwen-token-plan[-individual] → deepseek-v4-pro` with **`cost` all `0`**. So "just consume upstream and
  delete local cost metadata" is **not safe wholesale** — it would silently price reseller traffic at $0.
  **[HIGH]** — same direct read.
- `pi-config/models.json` pins the **July** cards (`0.435/0.87/0.003625`, `0.14/0.28/0.0028`) and the
  **July ids** (`deepseek-v4-pro`, `deepseek-v4-flash`) — it is one id and ~2 model generations behind the
  catalog it shadows. **[HIGH]** — direct read.

**Canonical / precedent — how the ecosystems actually handle this:**
- **LiteLLM** is the closest analogue: a maintained upstream map (`model_prices_and_context_window.json`)
  with an explicit **per-deployment override** mechanism. Its docs state the override "changes only the
  deployments you name" and "survives every upstream map update." It also warns that when the remote map
  fetch fails or validation rejects a shrunk map, the proxy **falls back to the bundled backup map — which
  can silently revert pricing corrections.** (docs.litellm.ai — `custom_model_cost_map`, `custom_pricing`,
  `config_settings`; deepwiki cost-tracking summary.) **[MEDIUM]** — one ecosystem, but two independent
  doc surfaces agree on the failure shape.
- **OpenRouter** exposes `pricing` per model in `GET /api/v1/models` and a per-generation cost endpoint,
  i.e. the gateway *is* the pricing authority while clients are expected to read it rather than recompute.
  But two caveats that map directly onto us: the field is documented as "pricing from the **top provider**
  for this model" (a routing-dependent value, not a scalar truth), and platform fees live outside it.
  (openrouter.ai/docs/guides/overview/models, /docs/faq, /api/v1/models.) **[MEDIUM]** — one ecosystem's own docs;
  no independent corroboration.
- **The shadowing failure mode is not "the override goes stale once" — it is that once you override, you own
  it forever and the upstream update becomes unreachable.** That is precisely our state: the store updated to
  `deepseek-flash` + V4.1 card; `models.json` kept serving the July card to `pi`'s cost stamping because
  config wins the merge (verified in scoping: `setup.sh` merges shipped → live, source wins; and
  `provider-composer` resolves config over store). **[MEDIUM]** — mechanism verified internally, pattern
  corroborated externally.
- Aider's issue #3055 (consuming OpenRouter's models API for pricing) captures the main objection to
  *full dependency* on an upstream catalog: schema/semantics are a frontend detail and can change. That is
  the argument for keeping a **pinned snapshot copy** for reproducibility even while consuming upstream at
  runtime. **[MEDIUM]** — single upstream GitHub issue thread, no corroborating source.

**Synthesis for #631:** three distinct fields are being conflated. Structure (`contextWindow`, `maxTokens`,
thinking map, clamp) is legitimately **config-authority** — the existing `check-cost-config.sh` design is
correct there. **Price** is upstream-authority wherever upstream has a non-zero value. Local override is
legitimate **only** for (a) ids upstream mis-prices (the $0 reseller entries), and (b) a **dated, loud**
pinned snapshot retained for audit. The anti-pattern to kill is the *silent* whole-model shadow.
**[MEDIUM]** — synthesis of the LiteLLM + OpenRouter precedents above against the verified internal merge
semantics; no single source states this three-way split in these terms.

---

## 2. Model-id lifecycle and alias retirement

**Framing: canonical + competitor-precedent.**

- **Universal practice: record the requested id *and* the served id; bill on the served model; keep an
  alias→canonical map; pin snapshots where possible.** Independent sources converge:
  - "Treat aliases as **pointers**, record the concrete model that actually served the call, and diff
    provider listings on a schedule so recycled or retired IDs do not break historical analytics."
    (inferbase.ai — *Silent Model Swaps: The `-latest` Trap*.) **[MEDIUM]** — practitioner blog, single source.
  - "Resolve model aliases via the API, record the alias-to-snapshot mapping, and pin the resolved snapshot
    so future evaluations and cost comparisons remain attributable even after the alias moves."
    (allanninal.dev — *A floating model alias silently changes model under you*.) **[MEDIUM]** — practitioner
    blog, single source.
  - "Providers rename models and add aliases — store both the provider's raw model ID and your own canonical
    mapping so history stays comparable; **not versioning pricing will cause historical spend to be
    recomputed incorrectly with today's rates**." (warpmetrics.com/learn/tracking-llm-costs.) **[MEDIUM]** —
    the three bullets above are independent practitioner sources agreeing with each other (no vendor doc).
- **Provider-side precedent for publishing the mapping:** AI/ML API ships a **deprecations endpoint** listing
  "models folded into another model, including the date and the **id to move to**"; Microsoft Foundry exposes
  `lifecycleStatus` + `deprecationDate` via a Models API. DeepSeek publishes the equivalent **only as prose
  footnotes on the pricing page** — no structured endpoint (re-verified 2026-09-10: no JSON/status API).
  **[MEDIUM]** for the general pattern — two provider doc surfaces (AI/ML API, Microsoft Foundry), both
  vendor documentation rather than independent analysis. **[HIGH]** for "DeepSeek has none" — direct fetch,
  twice, plus the PRIOR_RESEARCH constraint.
- **Our concrete alias table, derived from the vendor footnotes (verified 2026-09-10):**

  | Requested id | Served by | Billed at | Effective |
  |---|---|---|---|
  | `deepseek-flash` | DeepSeek-V4.1-Flash | Flash | current |
  | `deepseek-v4-flash` (retired, still accepted) | DeepSeek-V4.1-Flash | Flash | current |
  | `deepseek-v4-flash-vision-exp` (retired, still accepted) | DeepSeek-V4.1-Flash (vision ✓) | Flash | current |
  | `deepseek-v4-pro` | DeepSeek-V4-Pro-0813 → **re-routed to V4.1-Flash** | Pro → **Flash price** | **from 2026-09-14 12:00 Beijing** |

  **[HIGH]** — primary source, re-fetched.
- **The date-gated row is the killer argument.** After 2026-09-14 the *correct* price for `deepseek-v4-pro`
  changes without any change to the id, the config, or the website's pro row disappearing. Any guard that
  asserts "config value == value in row X of the pricing page" is therefore **structurally wrong** — it can
  only encode a point-in-time belief. This is the strongest single reason #631 should adopt a dated snapshot
  + reconciliation, and should **not** ship a page-scraping equality gate.
- **[LOW] ⚠️ single-source/uncovered:** I found no authoritative guidance on how to *deprecate an alias in a
  cost database* (i.e. whether historical rows should be re-priced or frozen). Warpmetrics' warning implies
  **freeze** (never recompute history with today's rates), but this is one practitioner source. Flagged in §5.

---

## 3. Auditable dated snapshots without a vendor API

**Framing: competitor-precedent + pitfalls.**

- **The "stale beats wrong" principle.** A practitioner write-up on automating LLM pricing is explicit:
  provider pricing pages are JS-rendered, scrapers **fail silently**, a maintained community dataset "can lag
  by a day", and the chosen philosophy is **"stale beats wrong"** because silent bad data is riskier than
  slightly old data. (dev.to/jjen0206 — *Your LLM pricing page is probably wrong*.) **[MEDIUM]** — single
  practitioner source, but it independently reproduces the pitfall already established in PRIOR_RESEARCH and
  matches our own verified constraint (`/pricing.json` → SPA HTML; `api.deepseek.com/pricing` → 401).
- **Dated/versioned snapshot shape.** The recurring pattern in versioned-config guidance: a pricing entry
  carries **effective date, expiry, currency, region, and status**, not just a number
  (agent-context.org — *How to Stop AI Agents From Quoting Stale Prices*); and thresholds/staleness behaviour
  should be **versioned configuration rather than inline constants so routing and stale-price behaviour can
  be audited later** (price-monitoring.org). **[MEDIUM]** — two independent practitioner/generated doc sites,
  neither authoritative; direction is consistent with the versioned-config precedent.
- **Staleness detection without a vendor API** — the literature uses a **timestamp-age check** (quote age /
  `lastUpdateTime` vs a max-age threshold; eodhd, ifalabs). Applied to us: an `asOf` date on the snapshot
  plus an `asOf_age > N days → WARN` rule is the minimum viable audit without any vendor endpoint. **[MEDIUM]** —
  the staleness pattern is well-established in adjacent domains (market data, oracle feeds), but all four
  sources are non-LLM domains — the transfer to rate cards is a synthesis, not a cited practice.
- **We have a better oracle than scrapers.** Because `models-store.json` is machine-readable, refreshed every
  4h, and already carries the current card, the drift signal can be computed as a **catalog diff**
  (pinned snapshot vs store, per id) rather than a page scrape. Two normalizations are mandatory or it
  produces false positives: **(a) the store carries PEAK values, so compare against peak (or halve them)**,
  and **(b) map ids through the alias table in §2** before comparing, because upstream renamed
  `deepseek-v4-flash` → `deepseek-flash`. **[HIGH]** for the mechanics (both verified directly); the store's
  own `cost` semantics are documented nowhere I could find — flagged in §5.
- **What the snapshot should be, concretely:** one file (data, not inline literals in three scripts), each
  entry `{id, aliasOf?, servedBy?, input, output, cacheRead, peak:{...}, asOf, sourceUrl, fetchedAt}`,
  consumed by `fleet-cost-report.sh`, `session-postmortem.sh`'s fallback, and the guard — replacing the
  three hand-copied cards (shipped `models.json`, live `models.json`, `session-postmortem.sh:252`).
  **[MEDIUM]** — synthesis, no single source; consistent with the versioned-config precedent.

---

## 4. Counter-evidence and failure modes

**Framing: pitfalls + adversarial.**

- **Against build-time page scraping (strong):** "a retailer can change markup so the selector still matches
  the wrong value"; monitor **page structure, extracted node counts, and historical HTML fragments**, never
  just "did the selector return something" (scrapes.us; assrt.ai ×2). Null-ratio spikes and DOM-fingerprint
  changes are the real signals — i.e. a scraper can return a **plausible but wrong price** and look healthy.
  **[MEDIUM]** — three independent scraping-vendor sources agree, and it matches the PRIOR_RESEARCH
  "monitoring an input proxy rather than the billed outcome" finding.
- **Against trusting local estimates at all:** "you can estimate request cost from token counts and per-token
  rates, but this is an **estimate**; for actual charges, provider-side billing remains the authoritative
  source" (apxml.com). Corroborated by invoice-reconciliation guidance: "verify tracked cost against **one
  provider invoice for a sample day**, then add custom model definitions for anything unmatched"
  (langfuse.com); "common gaps come from **stale registry prices** or missing cached-token fields"
  (braintrust.dev); "review cost management monthly against official provider pricing pages" (oneuptime).
  **[MEDIUM–HIGH]** — four independent practitioners/docs surfaces, same conclusion.
- **This reframes #631's ceiling.** Our own scoping recorded dashboard **$1,151.52/30d** vs **~$320–420**
  local. A perfect rate card cannot close a 3x gap — that gap is a **coverage** problem (unattributed
  traffic, missing sessions, or non-DeepSeek spend), and the reconciliation step is where it surfaces.
  **[HIGH]** for the internal numbers; **[MEDIUM]** for the interpretation. *Do not let a card fix be
  mistaken for a spend-accuracy fix.*
- **Against vendoring a third-party dataset (medium):** the best-maintained public dataset found
  (`slavin.ai/data/llm-vendor-pricing.json`, CC-BY-4.0) is **quarterly**, stamped **as of 2026-06-14**, and
  self-describes its figures as "**planning estimates, not commitments**" with a methodology based on
  vendor pricing pages "**not negotiated enterprise contracts**" — i.e. it is
  already older than our in-tree correction and would have missed the Aug-17 hike, the V4.1-Flash release,
  **and** the 2026-09-14 pro re-route. LiteLLM's map is more actively maintained but encodes another
  ecosystem's provider abstraction and would still need local augmentation for pi-specific ids/resellers.
  **[MEDIUM]** — the dataset metadata is primary (direct source), but the "LiteLLM would need local
  augmentation" half is inference from its documented scope, not observed.
- **Honest gap (no counter-evidence found):** I did **not** find any source arguing that a dated-snapshot +
  periodic-reconciliation approach is inferior to a hard config-vs-website equality gate. Every source found
  converges on *estimate + reconcile*. Treat this as a **weakly-falsified** positive — the absence of
  counter-evidence across the 9 recorded queries (2 adversarial: Q5, Q9) is itself the finding, but it is not
  proof. **[MEDIUM]**
- **[LOW] ⚠️:** No source addressed a fleet **without** a vendor billing API key/dashboard in scope (our
  `fleet-cost-report.sh` never reconciles against the DeepSeek dashboard). The reconciliation half of the
  recommended pattern is **currently unimplemented here**, and no researched source substitutes for it.

---

## 5. Open questions

**Framing: internal evidence + adversarial.** These are decision blockers surfaced by the research, not
researched claims — each is anchored to a verified internal artifact or a cited external source above, and
the external literature does **not** answer them for our context. No section-level source applies.

1. **Ownership of reconciliation.** Who is the named human owner of the weekly/manual card re-check, and does
   the ~$730/mo unattributed gap get its own issue? (Scoping already flagged invoice reconciliation as
   unfiled; §4 argues it is the higher-value half.) — *human gate.*
2. **Peak/off-peak representation** — deliberately deferred to **#634**; must not be modeled in #631's
   snapshot schema beyond carrying both numbers as separate fields.
3. **Is `models-store.json`'s `cost` semantics documented anywhere?** It carries **peak** values while the
   live config was corrected to **off-peak**. If the store's contract is "peak", every consumer must halve.
   Unverified — [#LOW], needs a pi upstream/doc check before the snapshot diff becomes a guard.
4. **Alias resolution in pi.** Does pi resolve `deepseek-v4-flash` → store entry `deepseek-flash`, or does the
   missing store id mean no cost stamp at all for legacy-id calls? This determines whether legacy traffic is
   silently $0 in local reports (the same class as the reseller $0 entries).
5. **Does the shipped snapshot merge destroy the local card (#682)?** Scoping established `setup.sh`'s
   per-provider merge replaces the whole provider block — if the new design keeps any local override, the
   merge must become per-id or the override will be wiped (or will wipe live-only ids).
6. **What is the actual store drift-check tolerance?** A guard that warns on any delta will fire on the
   legitimate 4h refresh cycle boundaries and on resellers. Needs the same BLOCK/WARN/vendor-scoped
   discipline the existing `check-cost-config.sh` uses.

---

## Source Confidence Summary

| Claim | Confidence | Sources (independent categories) |
|---|---|---|
| Store already carries current card; config shadows it | **[HIGH]** | direct file read (internal) + issue-scoping verification |
| Reseller (qwen-tp) store entries are `cost: 0` | **[HIGH]** | direct file read |
| DeepSeek has no machine-readable pricing/deprecation endpoint | **[HIGH]** | direct fetch (2×), PRIOR_RESEARCH |
| `deepseek-v4-pro` date-gated into Flash pricing 2026-09-14 | **[HIGH]** | primary vendor page (footnote 2), re-fetched |
| Upstream-catalog-authority + narrow dated override is the ecosystem pattern | **[MEDIUM]** | LiteLLM docs, OpenRouter docs, Aider issue |
| Alias→canonical mapping + bill-on-served is universal practice | **[MEDIUM]** | inferbase, allanninal, warpmetrics, AI/ML API, Foundry |
| "Stale beats wrong" > build-time scraping | **[MEDIUM]** | dev.to practitioner, scraping-vendor docs ×3, PRIOR_RESEARCH |
| Dated snapshot fields (asOf/expiry/currency/status) | **[MEDIUM]** | agent-context.org, price-monitoring.org |
| Reconcile against provider invoice; local = estimate | **[MEDIUM–HIGH]** | langfuse, braintrust, apxml, oneuptime |
| Third-party datasets are quarterly/lagging | **[MEDIUM]** | slavin.ai dataset metadata |
| No counter-evidence to snapshot+reconcile | **[MEDIUM]** (weakly falsified) | absence across 9 recorded queries |
| Whether history should be re-priced on alias change | **[LOW]** ⚠️ single-source — verify when new source available | warpmetrics only |
| Reconciliation half currently unimplemented locally | **[LOW]** | internal observation, no external source |

---

## Raw Notes

> Append-only. All external queries run via `web_search model=sonar` (Perplexity MCP tools were **not
> registered** in this session — `mcp_catalog` lists only exa / brave-search / playwright / gemini /
> tortoise / aws-mcp). No gated models used. Two queries returned HTTP 429 on first attempt and were
> re-run serially after backoff.

- **2026-09-09 (PRIOR_RESEARCH, not re-run — deduped):** canonical = provider invoices are the source of
  truth, local cards are approximations; pitfalls = external HTML drift detection is net-negative without
  careful thresholding; constraint = DeepSeek publishes no machine-readable pricing endpoint
  (`/pricing.json` → SPA HTML; `api.deepseek.com/pricing` → 401); competitor-precedent = dated snapshot
  treated as an estimate + periodic invoice reconciliation beats config-vs-website equality in CI;
  adversarial = a mirror site still publishes the old July card.
- **2026-09-10 11:48 EST — internal read (source: worktree files):** `pi-bootstrap/pi-config/models.json`
  deepseek block = July card (`pro 0.435/0.87/0.003625`, `flash 0.14/0.28/0.0028`) with July ids;
  `scripts/check-cost-config.sh` is a **context-clamp** guard only (no cost-field assertion);
  `docs/ops/cost-config-policy.md` documents config-as-authority for the clamp; `scripts/session-postmortem.sh`
  line ~252 hardcodes the July flash card as its no-cost-dict fallback.
- **2026-09-10 11:50 EST — web_fetch `https://api-docs.deepseek.com/quick_start/pricing/`** (source:
  primary vendor): table re-verified verbatim. `deepseek-flash` = DeepSeek-V4.1-Flash (vision ✓);
  `deepseek-v4-pro` = DeepSeek-V4-Pro-0813; both 1M context / 384K max output; off-peak cache-hit
  `$0.003 / $0.022`, cache-miss `$0.15 / $0.66`, output `$0.6 / $1.98`; **peak = 2×**; peak hours
  **01:00–04:00 and 06:00–10:00 UTC Mon–Fri**, all other hours off-peak; concurrency 2500 / 500.
  Footnotes: (1) legacy ids accepted → served by V4.1-Flash, billed at Flash price; (2) **from 12:00
  Beijing 2026-09-14** pro requests route to V4.1-Flash at Flash price "until V4.1 Pro is released";
  (3) off-peak = half of peak; (4) see Rate Limit & Isolation. **No "last updated" / effective date is
  published on the page** — noted for §3.
- **2026-09-10 11:51 EST — internal read `~/.pi/agent/models-store.json`** (source: live config, outside repo):
  `deepseek-flash` → `{"input":0.3,"output":1.2,"cacheRead":0.006}` ctx 1_000_000 provider `deepseek`;
  `deepseek-v4-pro` → `{"input":1.32,"output":3.96,"cacheRead":0.044}` ctx 1_000_000 provider `deepseek`;
  `deepseek-v4-flash` → all-zero cost under `qwen-token-plan`; `deepseek-v4-pro` → all-zero under
  `qwen-token-plan` and `qwen-token-plan-individual`. Top-level provider keys include openrouter, zai,
  moonshotai, nvidia. Store values are **peak** (exactly 2× the off-peak official card).
- **2026-09-10 11:52 EST — tortoise-memory query** (source: internal tooling): `tortoise_unavailable`,
  `GET /v1/search → HTTP 404`, status `degraded`. No prior epistemic claims retrieved. Claims below were
  **not** persisted to the graph.
- **2026-09-10 ~11:56 EST [canonical] — Q1 — LiteLLM override vs upstream precedence:** docs.litellm.ai `custom_model_cost_map`
  (per-deployment override "changes only the deployments you name", "survives every upstream map update";
  remote-fetch failure → bundled backup map "can silently revert pricing corrections"), `custom_pricing`
  (`model_info` block), `config_settings` (`LITELLM_LOCAL_MODEL_COST_MAP=True` forces bundled map);
  deepwiki cost-tracking summary (prices passed to the call override the DB lookup); GH PR #9855;
  GH discussion #20823 (custom names mapped to real pricing → local override shadows upstream).
- **2026-09-10 ~11:57 EST [competitor-precedent] — Q2 — model alias / retirement mapping:** warpmetrics.com/learn/tracking-llm-costs (store raw
  provider id + own canonical mapping; not versioning pricing recomputes history wrongly);
  docs.litellm.ai/proxy/model_management (public name → underlying model + token costs);
  allanninal.dev (floating alias → resolve via API, record mapping, pin snapshot);
  agentgateway.dev cost docs (internal cost catalog mapping deprecated/aliased ids);
  docs.langchain.com/langsmith/cost-tracking (map model names → per-token prices, store provider+model
  metadata); inferbase.ai *Silent Model Swaps: The -latest Trap* (aliases are pointers; record served model;
  diff provider listings on a schedule).
- **2026-09-10 ~11:58 EST [counter-evidence] — Q3 — vendoring a dataset vs build-time fetch:** slavin.ai/Open-Data + `llm-vendor-pricing.json`
  (CC-BY-4.0, "updated quarterly", "planning estimates, not enterprise-contract commitments", prices as of
  **2026-06-14**); dev.to/jjen0206 (JS-rendered pages, silent scraper failure, "**stale beats wrong**");
  benchlm.ai/llm-pricing-trends (pricing is a moving target, needs an update strategy not a one-time scrape);
  letsdatascience.com (enterprise pricing pressure/complexity); amnic.com (cost = input/output mix + caching,
  not just posted rates).
- **2026-09-10 ~11:58 EST [canonical] — Q4 — invoice reconciliation:** langfuse.com LLM cost management (verify against **one provider
  invoice for a sample day**, then add custom model definitions for unmatched items; use the price in effect
  when the call ran); braintrust.dev 2026 playbook (gaps from **stale registry prices** / missing cached-token
  fields); stackspend.app (keep provider-native detail for reconciliation, lighter layer for daily tracking);
  traceloop.com (per-request attribution); oneuptime.com (review monthly against official provider pricing
  pages); truefoundry.com (gateway-centralized observability + alerts).
- **2026-09-10 ~11:59 EST [pitfalls/adversarial] — Q5 — scraping drift detection failure modes:** proxiesapi.com price-monitoring
  guide (hash a **normalized** price representation; separate transient from persistent failures);
  assrt.ai selector-drift guides ×2 (validate cardinality/type/freshness; monitoring "did the selector
  return something" is insufficient; monitor page structure + null rates + simultaneous failures);
  scrapem.com (silent failure modes; null-ratio spikes, DOM fingerprint changes);
  scrapes.us (markup changes can leave a selector **matching the wrong value**);
  dev.to/extractdata (empty-field monitoring misses plausible-but-wrong prices; use structural fingerprints
  + semantic canaries).
- **2026-09-10 ~11:59 EST [competitor-precedent] — Q6 — upstream catalog as source of truth:** openrouter.ai/docs/guides/overview/models
  (`pricing` = "from the **top provider**", USD per token/request/unit);
  openrouter.ai/docs/api_reference/overview (`/api/v1/generation` for tokens + cost — read cost from the
  gateway rather than recompute); openrouter.ai/docs/faq (pass-through pricing, separate fee on credits);
  openrouter.ai/api/v1/models (live `pricing.prompt`/`.completion`); Aider GH issue #3055 (models API has
  pricing, but stability as a client API is questioned).
- **2026-09-10 ~12:00 EST [pitfalls] — Q7 — stale-data detection without a vendor API:** eodhd.com (track quote age with received
  timestamps; monitor freshness per symbol not per connection); nextgatetech.com (detect instruments with
  unchanged prices and how long); fundrecs.com (day-over-day comparison + thresholds);
  ifalabs docs (`lastUpdateTime` vs `MAX_PRICE_AGE`; widen thresholds when natural cadence is slower);
  agent-context.org *How to Stop AI Agents From Quoting Stale Prices* (pricing config carries **effective
  date, expiry, currency, region, status**); price-monitoring.org (store thresholds as **versioned
  configuration** rather than inline constants so behaviour is auditable).
- **2026-09-10 ~12:00 EST [competitor-precedent] — Q8 — model deprecation tables / bill-on-served:** docs.aimlapi.com model-deprecations
  (deprecations endpoint listing models **folded into another model** with date + id to move to; canonical
  ids and aliases); MS Learn Foundry model retirements (`lifecycleStatus`, `deprecationDate`, Models API);
  truefoundry.com *Model Deprecations: Virtual Models & Staged Cutovers* (alias routing; shutdown date
  becomes a routing change); inferbase.ai (floating alias repointed to newer weights); benchlm.ai/deprecations
  (provider-by-provider deprecation table); ai-tldr.dev model-deprecation-migration (aliases move you to
  newer snapshots; pin to snapshot ids).
- **2026-09-10 ~12:01 EST [counter-evidence — drifted] — Q9 — "provider billing API as only source of truth":**
  returned mostly self-hosted-TCO material (capitalandcompute.net, mpt.solutions ×2, wavect.io,
  promptcost.org) — **off-target for our cloud-API case**, not used as evidence. One relevant hit:
  apxml.com ("estimate from token counts and per-token rates… for actual charges, provider-side billing
  remains the authoritative source"). **Noted honestly: the counter-evidence bucket is thinner than the
  others; one query was wasted on a drifted result set.**
