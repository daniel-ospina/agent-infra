---
title: "#631 — rate-card governance, model-id lifecycle, and dated price resolution — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-631, issue-634, issue-701, issue-702, issue-703, issue-704, pi-config, cost-config-policy
---

<!-- research-path: docs/research/2026-09-09-rate-card-governance.md -->

# Plan — #631: Rate-card governance, model-id lifecycle, and dated price resolution

**Issue:** daniel-ospina/agent-infra#631 (Level: project, escalated from task 2026-09-09)
**Branch:** `feat/631-rate-ledger-plan` (worktree `.worktrees/feat/631-rate-ledger-plan`)
**Research:** `docs/research/2026-09-09-rate-card-governance.md` (see its supersede block)
**Child issues:** #701 (WS1) · #702 (WS2) · #703 (WS3) · #704 (WS5)
**Status:** draft for plan-review · **v6.1** — after solution-verify cycles 1–4 (capped), the second-model coherence check, and the wiring check

> **Revision history.** *v2* removed the recurring re-check cadence, the named owner, and the upstream
> freshness oracle (operator is a solo founder; cost is retroactively recomputable, so a schedule bought
> nothing). *v3* applied solution-verify cycle 1's ten findings. *v4* (this document) rewrites the whole plan
> so those corrections are **consistent everywhere** — cycle 2 found them applied only partially, so the
> document is regenerated rather than patched. *v5* applies cycle 3, which **measured the session corpus and
> falsified two claims in v4**: (a) the `frozen ≠ render(ts)` mismatch is **not** proof of a hand-edit — the
> corpus froze **three** distinct cards, so the cause is usually incomplete ledger history, and the BLOCK rule
> is narrowed to **repo-file** render-equality; (b) the provider-**failover hop legs** (`qwen-tp`) are a
> sixth price surface the plan did not own, and their card (`0.2608/0.7825/0.0083`) is byte-identical to the
> 7,124 mystery stamps. Terminology: **D1** duplicate/unowned price data · **D2** id divergence with no alias
> layer · **D3** no time/date dimension · **D4** an id we dispatch but do not define is priced by the store,
> which carries **peak** values. *v6* applies the **second-model coherence check** (verdict: *coherent with
> reservations*), which found the plan **over-engineered for a solo operator who has refused ongoing chores**: the
> per-request re-pricer is cut to a **window-level Δ**, committed structural templates are replaced by a
> diff-only guard, the fixture is an id-set until WS3 lands, the ledger schema is trimmed, and two live holes are
> closed (the farm copy was an **unguarded** price copy; the pre-registered 09-14 row had **nothing that applied
> it**).

### Convergence log (solution-verify)

| Cycle | Reviewers | Findings | Disposition |
|---|---|---|---|
| 1 | 2 parallel | 10, all propagation-class (a false "load-bearing for routing" claim; a surviving expiry gate; an unsourced coverage check; an unreadable ledger path; an inexact `--usage-rows`; missing row structure; an undefined pre-history render; an unwired test suite; a falsified research headline) | fixed as v3 |
| 2 | 2 parallel | corrections were applied only *partially* — expiry survived in §2/§3.2/§8, WS4 survived in the decomposition map, "5 surfaces" was fixed in one place only; plus a NEW gap: the farm copy meant an ad-hoc ledger fix would never reach the runtime report | **document rewritten clean as v4** |
| 3 | 1 independent, corpus-measuring | 2 P1s that **falsified v4's measurement model**: (a) `frozen ≠ render(ts)` → BLOCK was wrong (several cards in history; the live-only id was in no base layer, so `render(ts)` was undefined for its records); (b) **failover hop legs** (`qwen-tp`, `openrouter/deepseek/deepseek-v4-pro`) were a sixth price surface, byte-identical to the 7,124 mystery stamps | fixed as v5 |
| 4 | 1 independent, corpus-measuring | v5's replacement premise was **still wrong**: the `0.14` and `0.2608` cards were **concurrent**, not sequential — both live every day Sep-5→Sep-10 — so **no single-valued `render(ts)` can reconcile them**; plus AC1 unsatisfiable against `tests/fixtures/**`+`docs/**`, a missing `v4-pro` hop leg, a "both retired ids" tombstone contradiction that would delete the 102k-call id, an under-specified seed set, count/card-label drift, and `surface` enum drift | all applied |
| **coherence** | 1 (second model) | **COHERENT WITH RESERVATIONS**: the re-pricer was the single most expensive workstream for a number with **no decision consumer** (the same admission §2 makes about the runtime scalar, never extended to WS3); structural templates were a **second hand-authored source**; and two live holes — the **farm copy was unguarded** (guard inverted: the surfaces pi stamps from are protected, the measurement's own input is not) and the **pre-registered 09-14 row had no trigger** ("ad-hoc, no owner" vs dated correctness) | v6 |
| **wiring** | 1 (Phase 6) | **3 P1s**: the 09-14 pre-registered row was still unapplyable (excluded from *both* render keys) → fixed by a period-keyed **`renderNow()`**; **nothing invoked `render.py` in write mode** → the `sync.sh` write step; the extension test matched **no** CI workflow → explicit wiring. Plus 2 surfaces (`qwen-tp`, `venice` full `models[]` rows) had **no render target** → a 4th surface; and v6's template removal was **not propagated** (5 stale references) — the same class as cycle 2 | v6.1 |

**⚠️ Capped at 4 cycles — 3 representative items remain (unverified).** On cap the AGENTS.md procedure applies:
"document remaining issues … proceed". The coherence check and the wiring check were therefore run **post-cap**,
i.e. the Phase 5.6 precondition ("after solution-verify converges clean") was **knowingly not met** — recorded
here rather than glossed. No further **solution-verify** cycle ran after cycle 4; the v6 cuts were reviewed
only by the Phase-6 wiring check (which found a v6 defect — five unpropagated template references), and the
v6.1 fixes have not been re-reviewed at all. On the cap citation: AGENTS.md states a **per-reviewer** 4-cycle
cap, and cycles 3–4 were single fresh reviewers, so this is a **global** cycle-stop rather than a per-reviewer
cap being hit — the disclosure is deliberately conservative in the direction of "less verified", not more.
Cycle 4's own fixes were likewise applied without a re-review. The convergence log above carries the full list;
the three highest-consequence items are:

1. **The `render(ts)` / `renderNow()` split** (§2, §3.1) — introduces a second render key (wiring-check fix).
2. **The 4th rendered surface** (`providers.<p>.models[]` for `qwen-tp`/`venice`) (wiring-check fix).
3. **The v6 scope cuts** (window-level Δ; diff-only structural guard; fixture as id-set) (coherence-check fix).

Not re-reviewed and not enumerated above: the wiring-check changes to `sync.sh` write-mode, the CI wiring, and
the cycle-4 fixes (concurrent-card premise, AC1 narrowing, the `v4-pro` hop leg, the tombstone contradiction,
the seed set, `surface` enum drift).

Residual, deliberately accepted: the *exact* per-day attribution of the mixed record
stream, and whether a hop-leg-stamped record is a render-divergence or a hop-leg effect, are **WS3.1
implementation questions** — they depend on session metadata this plan deliberately does not pre-commit. The
plan's position is that this is **measured, not solved** (§2, §8).

---

## 0. Corrections to the inputs (verified at source)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| E1 | A `models.json` `models[]` row **without** `cost` prices at **$0** — it does not inherit upstream | `dist/core/provider-composer.js:71` — `cost: definition.cost ?? {input:0,output:0,cacheRead:0,cacheWrite:0}` | **"Let upstream own the price" is falsified** — it stamps $0 on every call. We must own the card for any id we dispatch |
| E2 | `modelOverrides[id].cost` **merges per-field** onto the resolved model, and runs **topmost** | `provider-composer.js:25–45`, `:304` | A third, better-owned surface: cost + clamp **without duplicating a whole model row** |
| E3 | `models.json` `models[]` = **per-id replace**; extension `models[]` = **wholesale replace** | `applyModelsJson` `:107–116` vs `applyExtension` `:118–125` | Confirms the layering; the OpenRouter extension's 3-entry array is the **only** price for its hop-legs |
| E4 | Store freshness gate: an overlay is dropped when `lastModified <= builtinGeneratedAt` | `dist/core/remote-catalog-provider.js:32–41`, fed by pi-ai `providers/data/.manifest.json` `generatedAt: 2026-09-05T11:58:56Z` | Shipped `pi-config/models-store.json` (`lastModified` 2026-07-31) is **provably inert** |
| E5 | **D4:** the canonical current id is priced at **PEAK** — `deepseek-flash` has no `models.json` row, so the store's peak values apply | live store `deepseek-flash` = `0.3/1.2/0.006` (= 2× off-peak) | Migrating the fleet default to it **without an explicit own row** silently moves the fleet onto peak basis |
| E6 | `ModelCost.tiers[]` is keyed on `inputTokensAbove`; **no time or date dimension**. `calculateCost` bills `input`, `output`, `cacheRead`, `cacheWrite` (plus an Anthropic-only `cacheWrite1h` 2× term) and does **not** bill `reasoning` separately | `pi-ai/dist/types.d.ts:705–714`, `pi-ai/dist/models.js:530–548`; arithmetic reproduced on a live record | The runtime schema cannot express peak/off-peak or a dated re-route. It also **pins the re-pricer's formula** |
| E7 | `modelFromJson` builds a **fresh** object from the definition, defaulting `contextWindow ?? 128000`, `maxTokens ?? 16384`, `reasoning ?? false`, `input ?? ["text"]`, and taking `compat` only from the definition/provider (it does not inherit the replaced row) | `provider-composer.js:60–77` | An own row rendered from `cost` alone silently downgrades the model — **and passes `check-cost-config.sh`** (which blocks only `>300000`) |

**Measured in-use traffic (session-JSONL corpus, all-time, measured 2026-09-10; counts grouped by `provider` + `model`):**

| provider | model | calls | note |
|---|---|---|---|
| deepseek | `deepseek-v4-flash` | 102,283 | retired id, still accepted & billed as Flash; store no longer lists it → deleting the row reverts to pi-ai's **July** card |
| openrouter | `deepseek/deepseek-v4-flash` | 4,279 | extension literal `0.0882/0.1764` |
| deepseek | `deepseek-v4.1-flash-expires-on-0910` | 2,830 | **live `defaultModel`**, in **no** base layer |
| deepseek | `deepseek-v4-pro` | 0 | config row, no traffic; the 2026-09-14 date-gate has no historical exposure |
| anthropic | `claude-opus-4-8` | 1 | not repo-owned → `surface: upstream` |

**The corpus contradicts a "one card at a time" model.** For `deepseek-v4-flash` the cards
`0.14/0.28/0.0028` (92,871 records) and `0.2608/0.7825/0.0083` (7,124 records) **coexist on every single day**
Sep-5 → Sep-10 (09-05: 6,995 vs 223 · 09-06: 3,606 vs 1,599 · 09-07: 3,486 vs 1,741 · 09-08: 4,873 vs 1,451 ·
09-09: 2,301 vs 2,026 · 09-10: 361 vs 84). The second triple is **byte-identical to the shipped `qwen-tp`
literal**, and the corpus holds **zero** records with `provider = "qwen-tp"` — so those 7,124 records are
overwhelmingly **failover-hop calls stamped under the primary `deepseek` identity**. This is the single most
important input to the measurement model (§2): history is not a sequence of cards, it is a **mixture**.

## 1. Problem statement

DeepSeek's **effective** price for a model id composes from **five** layers; the repo owns **three**:
**(a)** pi-ai's **bundled** catalog (July card) → **(b)** the 4h **upstream store** (current card, in **peak**
form, only for the vendor's *new* ids; the *shipped* snapshot is inert per E4) → **(c)** repo `models.json`
`models[]` (wholesale replace, **exact id only**) → **(d)** repo `modelOverrides` (exact id, per-field,
topmost config layer) → **(e)** repo **extension-registered `models`** (wholesale-replaces the provider's
list; **beats `models.json`**). pi has **no alias mechanism** anywhere.

Three defects:

1. **Duplicated, unowned price data** across **seven literal surfaces** that disagree: shipped `models.json`
   (July); `scripts/session-postmortem.sh:252`; live `models.json`, whose two cards appear
   **concurrently** in the corpus (the July `0.14/0.28/0.0028` and `0.2608/0.7825/0.0083`, the latter
   **byte-identical to the shipped `qwen-tp` hop-leg literal**); the shipped `qwen-tp` and `venice`
   rows; shipped `models-store.json` (inert);
   `extensions/custom-provider-openrouter/index.ts` (frozen July hop-leg literals pricing **4,279 live
   calls**); pi-ai bundled (July). **Cost is stamped into each session record at
   call time**, so the errors are frozen into history and cannot be repaired by any later card edit.
2. **Id divergence with no alias layer.** `deepseek-v4-flash` (102k calls — deleting its row reverts to the
   bundled **July** card); `deepseek-v4.1-flash-expires-on-0910` (the live default, in **no** base layer —
   deleting its row removes the model); `deepseek-v4-pro` (an exact-id shadow of a first-party store row).
   Two different mechanisms → precedence must be decided **per id**.
3. **No time or date dimension** (E6): neither the peak/off-peak 2× (01:00–04:00 & 06:00–10:00 UTC Mon–Fri)
   nor the dated 2026-09-14 `deepseek-v4-pro` → V4.1-Flash re-route is expressible.

Plus **D4** (E5): an id we dispatch but do not define is priced by the store, which carries **peak** values.

**Out of scope:** the ~$730/mo coverage gap between the provider invoice ($1,151.52/30d) and local estimates
(~$320–420) — tracked in **#690**. This plan fixes **precision**, not coverage.

## 2. Decision — one dated ledger, rendered into the card **and** consumed by the report

A single append-only ledger (`scripts/rates/deepseek.jsonl`) is the only hand-edited price source. It produces
two **views**:

- **`render(ts)`** — the rate that was actually shipped into the runtime card **at time `ts`**, i.e. the row with
  the latest `renderedAt ≤ ts`. Used for **historical attribution** (comparing against a frozen stamp). pi can
  hold one scalar per id; that is its schema, not a choice. **`render(ts)` is *defined*-total (a row always
  exists), not *match*-total** — see below.
- **`renderNow()`** — the rate that **should** be in the card **today**, i.e. the row whose period covers today
  (`effectiveFrom ≤ today < expiresOn`), regardless of `renderedAt`. This is the key the **generator** uses and
  the key render-equality BLOCKs against, and it is what makes pre-registration actually work: a row appended
  with `effectiveFrom: 2026-09-14` needs **no write, no owner and no trigger** — the next time `render.py` runs
  in write mode on or after that date, it selects that row and the file changes. (v6 wiring fix: without a
  period-keyed HEAD render, a `renderedAt: null` row was **excluded by both** keys and the 09-14 re-route could
  never land.) A row with `renderedAt: null` is therefore excluded from `render(ts)` but **included** in
  `renderNow()` once its `effectiveFrom` arrives.
- **`vendor(ts)`** — the tier- and date-correct rate for `ts` (peak/off-peak via `peakWindows[]`, periods via
  `effectiveFrom`/`expiresOn`).

**The two views are the measurement**, and every disagreement has one cause and one owner:

| Observation | Cause | Response |
|---|---|---|
| a **repo file** ≠ what `render.py` produces from the ledger | the file was hand-edited, or is mid-sync | **BLOCK** — the only BLOCK **over history**. It is a statement about a file on disk, never about the past |
| `frozen ≠ render(ts)` (historical) | **concurrent config sources** — two cards live at one instant, which no single-valued ledger can reconcile — or the ledger's rows are incomplete, or a historical hand-edit | **report** as a *divergent-card window* (id, observed triples with first/last seen, dominant card, share) — **possibly open-ended**, **never** a CI failure |
| `render(ts) ≠ vendor(ts)` | the card was stale at that moment — **D1's cost** | escalate as a **bounded stale window** (id, dates, $) |
| `frozen ≠ vendor(ts)` on peak records, tier-consistent | peak is unstampable at runtime | measured → raw material for **#634** |

**Why history can never BLOCK** (cycle-3/4 finding): `deepseek-v4-flash` carries **five** observed triples in the
corpus — three real cards (`0.14/0.28/0.0028` ×92,871; `0.2608/0.7825/0.0083` ×7,124; `0.22/0.66/0.007` ×1) plus
two zero-usage/error variants — and two of them are **live simultaneously** across the whole Sep-5→Sep-10 window.
So a mismatch at a past timestamp has (at least) three distinct causes, only one of which is a config fault:
concurrent sources, an incomplete ledger, or a historical hand-edit. Gating CI on it would also red every
historical re-analysis. **The honest framing: `render(ts)` is *defined*-total, not *match*-total. The ledger is
expected to be *complete at HEAD* and *approximate over history*; only HEAD is gated, and history divergence is
reported as an open-ended finding rather than a bounded window.**

### Why A+B rather than B alone

B alone (report-side re-pricing only) would leave pi stamping stale cost into **every non-report consumer** —
the audit ledger, loop-enforcer logs, retro summaries, pi's cache-waste notice — and would leave the
**seven duplicated literal surfaces enumerated in §1** unowned. More decisively, **E1** means a `models[]` row *must* carry `cost` or it
stamps **$0**: the runtime card has to be owned regardless. So the render is retained for
**correctness-of-record + deduplication**, and it is the only surface the hand-edit guards can test.

**Explicitly recorded:** the runtime dollar value has **no decision consumer** (verified — nothing branches on
`usage.cost`; compaction triggers on tokens; pi's `cache-stats.js` uses cost *ratios*; extensions only
log/display; `evaluateTermination` takes no cost input). Its job is the record, not decisions.

### Why not A alone, and why not C

**A alone:** `ModelCost` has no time dimension, so no render-only scheme can be correct; render-equality proves
only *consistency*. **C ("disclaim first-party price; consume upstream")** is falsified four times over: E1
(stamps $0), E5 (store is peak → 2× over-report off-peak), E4 (shipped snapshot inert), and coverage (the
store lists neither the 102k-call id nor the fleet default). C's two good ideas survive: an explicit
`expiresOn` **in the data** marking a superseded period, and owning only the corrections we must — applied
**per id** rather than wholesale.

**Why the hybrid is not two mechanisms doing one job:** if both views derive from the same wrong ledger, the
Δ is 0. It becomes a real guard only because `render` and `vendor` are **separate axes on one row** — a
retroactive correction (correct `effectiveFrom`, today's `renderedAt`) leaves `render(ts)` matching the frozen
stamp wherever the id used **one** card at that instant (no false alarm) while `vendor(ts)` shows the exact size
and window of the undercount. Where two cards were live at once the mismatch is reported as an open divergent-card
window, not blocked — see §2. Render-equality
cannot do this (no memory of yesterday); a store comparison cannot (history-less).

## 3. Architecture

### 3.1 Ledger

`scripts/rates/deepseek.jsonl` — append-only, one JSON object per line, key `(provider, model, effectiveFrom)`.

> **Path constraint:** the ledger lives under `scripts/` because that path is symlinked into consumer repos by
> `manifest.json`. **`docs/` and `pi-bootstrap/` are NOT shipped.** Runtime readability is handled separately
> (§3.4).

```jsonc
{ "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "effectiveFrom": "2026-08-17T00:00:00Z",   // vendor axis
  "expiresOn": null,                          // optional; marks a superseded period (data only)
  "offPeak": {"input":0.15, "output":0.60, "cacheRead":0.003, "cacheWrite":0},
  "peakMultiplier": 2,
  "peakWindows":[{"days":["Mon","Tue","Wed","Thu","Fri"],"startUtc":"01:00","endUtc":"04:00"},
                 {"days":["Mon","Tue","Wed","Thu","Fri"],"startUtc":"06:00","endUtc":"10:00"}],
  "tiers": null,                              // mirrors pi's cost.tiers[] when a model has them
  "asOf": "2026-09-10",                       // last human/agent confirmation against the vendor page
  "sourceUrl": "https://api-docs.deepseek.com/quick_start/pricing/",
  "renderedAt": "2026-09-10T15:45:00Z",       // when this rate actually shipped; null = pre-registered
  "surface": "own-row",                       // own-row | override | upstream | subscription | vendor-vendor
  "aliasOf": "deepseek-flash",                // optional
  "note": "" }                                  // free text; where the id resolves WITHOUT our rows, if notable
```

**v6 — schema trimmed** (coherence check): the separate `base` field overlapped `surface` and cost the
hand-editor a decision per row; it folds into `note`. The row is the single hand-edited object, so every field
must earn its place.

**Rate triples are always written `input / output / cacheRead` in prose, and carry named keys in the ledger.**
AC4 uses the named form; there is no prose ordering convention to memorise.

Rules that make the guard work:
- `offPeak` is the base; `peak` is **derived** (`× peakMultiplier`) so the 2× can never drift.
- `renderedAt` is a **full ISO-8601 timestamp** (not a date) so same-day corrections do not create false
  render-fidelity Δs. It is the **historical** key (`render(ts)`); `renderNow()` keys on `effectiveFrom` instead,
  which is what lets a pre-registered row apply on its date without any write. `--check` prints *"pre-registered,
  pending since N days"* when `effectiveFrom ≤ today` and `renderedAt` is still null **and** the file has not yet
  been regenerated.
- A retroactive correction **appends** a row; existing rows are never rewritten. That is what makes past
  staleness *measurable* rather than masked.
- **Every observed card gets a seeded row**, so `render(ts)` is **defined-total** over history. For
  `deepseek-v4-flash` that is the bundled July card (`0.14/0.28/0.0028`, original `renderedAt`) and the current
  card; the concurrent `0.2608/0.7825/0.0083` stamps are **not** given a competing row — they are recorded as an
  **open divergence** (a hop-leg-stamped card cannot be reconciled by any single row). A seeded row's
  `renderedAt` is derived as the **first-seen corpus timestamp** for that triple, recorded in the row's `note`;
  the derivation is a decision, so it is written down rather than inferred at read time.
- **Ids that exist in no base layer need their own pre-correction row.** The bundled catalog contains no
  `deepseek-v4.1-flash-expires-on-0910`, so a "seed the bundled card" rule leaves `render(ts)` undefined for its
  2,830 records. It carries **two** rows: the pre-correction `0.22/0.66/0.007` (renderedAt = Sep-9 edit) and the
  current one at HEAD. **Only the HEAD row is the rendered card**; the pre-correction row exists so history is
  priced and the Δ is computable.
- **A past `expiresOn` never removes a row from the render.** It marks a superseded period; the renderer keeps
  emitting the own row (otherwise a still-dispatched id silently reverts to a base layer — D2).
- **`expiresOn` has two distinct roles, and the renderer must not conflate them.** For a **period** row it bounds
  the period (`effectiveFrom`…`expiresOn`); for the **tombstone** row (`…expires-on-0910`) it marks id retirement.
  Both are data; neither removes a row.
- **`renderNow()` selection rule (explicit):** among rows whose period covers today, the one with the **latest
  `effectiveFrom`** wins; `renderedAt` is irrelevant to this key. This resolves the `v4-pro` case, where the
  first period is never explicitly terminated and a tie-break would otherwise be unspecified — and the first
  period's `expiresOn` is **set** to `2026-09-14T04:00:00Z` rather than left null, so the two periods are
  disjoint by construction.
- **`tierKey` is not in the row key** (v6). `tiers` are mirrored in the ledger for fidelity, but the re-pricer
  is **window-level** (§3.2): a dispatched id with `tiers` is flagged `tiered: unmodelled` and reported, never
  silently mis-priced. This removes the per-request bucketing machinery entirely.
- `expiresOn`/`renderedAt: null` are **data and report facts only — never CI failures** (see §3.3).

### 3.2 Consumers

**Generator/checker — `scripts/rates/render.py`** (python3 stdlib only). Renders **four** surfaces (v6 wiring
fix — the fourth closes a real gap the wiring check found):

1. `pi-bootstrap/pi-config/models.json` → `providers.deepseek.models[]` — **own rows for dispatched ids only**,
   emitted by **read-modify-writing the previous row** so structure is preserved (E7), never built from `cost`
   alone. The guard is a **diff** (WS1.5), not a template.
1b. `pi-bootstrap/pi-config/models.json` → `providers.<p>.models[]` for the **named non-deepseek providers that
already carry a full `models[]` row** — i.e. `qwen-tp` (`deepseek-v4-flash-0731` `0.2608/0.7825/0.0083`,
   `deepseek-v4-pro` `0.7825/2.3475/0.0261`) and `venice` (`deepseek-v4-flash` `0.14/0.28/0.03`). These live at a
   path surfaces 1–3 did **not** cover, so without 1b they stayed **unowned, unguarded price copies** —
   precisely the D1 shape this issue exists to remove — and AC1's grep would still find them.
   **`surface: subscription` is exempt.** The `qwen-token-plan*` providers carry only `modelOverrides` and **no**
   `models[]` entries; rendering new rows for them would have no previous row to read-modify-write, which hits
   **E7** (`modelFromJson` defaults `contextWindow` 128000 / `maxTokens` 16384 / `reasoning false`) and would
   silently downgrade a provider this plan has no reason to touch. Subscription `$0` rows are declared in the
   ledger and covered by assertion 4 + AC11, not rendered.
2. `pi-bootstrap/pi-config/models.json` → `providers.<p>.modelOverrides{id}` — cost + `contextWindow` for
   clamp-only ids (the E2 surface: per-field merge, **no structural duplication**, so upstream's
   `thinkingLevelMap`/`compat` changes propagate).
3. `extensions/custom-provider-openrouter/index.ts` → its `models[]` array, via a **marker-bounded block**
   (the file is TypeScript, not JSON), preserving `name`/`input`/`contextWindow`/`maxTokens`; the list must stay
   **complete** because the layer wholesale-replaces, and it must contain **one entry per `ALIAS_FAMILIES` leg**
   (read from `extensions/shared/provider-failover.ts`, not hand-listed). It also renders the extension's
   **non-DeepSeek literal**
   (`anthropic/claude-opus-4.8`, currently `5/25`) from the ledger, so AC1's grep has no orphan. Creating
   `extensions/custom-provider-openrouter/index.test.ts` is part of this deliverable (the sibling
   `custom-provider-qwen/` uses `.test.ts`, not `.test.mjs`).

Plus **two assertions** (not rendered surfaces):

4. **Structural:** `scripts/session-postmortem.sh` contains **no USD cost literal** and contains the ledger-read
   call (WS3.4). The retro summary aggregates per **session**, not per record (`parse_sessions` keeps only sums),
   so a session mixing two deepseek ids and a hop leg has no single rate: the fallback is an
   **explicitly-documented single-rate approximation** naming the ledger row it reads, and it **fails loud**
   (printed warning + `unknown` rates) when the ledger is unreachable — it never silently reverts to a literal.
5. **Resolution:** `settings.json` `defaultModel` resolves to a ledger-covered id (also a `--check` row, §3.2).

**`--check`** re-renders in memory and asserts byte-equality, then runs these — **each tagged with the mode it
runs in**:

| Assertion | Mode | Class |
|---|---|---|
| render-equality across the **4** surfaces | shipped-only | **BLOCK** |
| `$0` landmine (no deepseek-served `models[]` row omits `cost`) | shipped-only | **BLOCK** |
| **AC1 grep** — no USD cost literal for an owned id anywhere in `pi-bootstrap/pi-config/`, `extensions/`, `scripts/` outside the ledger and its rendered outputs | shipped-only | **BLOCK** (durable, not a one-time check — a future literal in any other script is otherwise unguarded) |
| every **dispatched** id has an `own-row` (closes D4) | shipped-only | **BLOCK** |
| a rendered own row differs from the **previously committed** row **only in `cost`** (E7; diff-based, no template) | shipped-only | **BLOCK** |
| coverage fixture present, and ledger ⊇ the fixture's ids | shipped-only | **BLOCK** (errors when the fixture is absent — never a silent pass) |
| `asOf` age; pre-registered rows (`renderedAt: null`) | shipped-only | WARN / report line |
| `settings.json defaultModel` resolves to a ledger-covered id | shipped-only | **BLOCK** (the shipped settings file is in-repo, so this is evaluable without a live install) |
| `modelOverrides` key resolvability | **live only** | WARN — in shipped mode prints an explicit `not evaluable in this mode` line, **never a silent ✅** |
| corpus coverage diff (live traffic vs fixture) | **live only** (`sync.sh`) | WARN, **loud on drift** |
| store sensor comparison (peak-to-peak) | **live only** | WARN; manual consult only |

Invocation is explicit: `render.py --check --shipped-only` (pre-commit, both CI workflows) and `render.py --check
--live` (`sync.sh`, the report). **Every** assertion not evaluated in the active mode prints an explicit
`SKIP — not evaluable in <mode>` line; there is no silent green. The same rule applies in both directions (a
live-only row is not silently omitted from the shipped pass, and a shipped-only row is not silently omitted from
the live pass).

**Coverage fixture.** `tests/fixtures/rates/in-use-ids.json` is **generated** by
`render.py --write-in-use-fixture` (reads the session corpus; documented in WS5.1) and committed. CI has no
`~/.pi/agent`, so shipped-only mode asserts against the fixture — **presence and coverage only**. Staleness
cannot be detected there (there is no corpus to compare against), so shipped mode makes **no** staleness claim;
the **live** mode diffs the real corpus against the fixture and reports drift loudly. The live
diff is **one-directional**: *corpus id ⊄ fixture* is **drift (loud)**; a *fixture-only* entry is
**informational** (it is a declared-but-unused leg). A symmetric diff would report the same standing
difference on every run, which is how "loud" becomes ignored. **Canonical scope (single source of truth):** the
fixture lists **dispatched ids the repo owns** — deepseek-served ids plus the `ALIAS_FAMILIES` legs. Rendered
**literals** for non-dispatched ids (`anthropic/claude-opus-4.8`, `venice/deepseek-v4-flash`) are **not** in the
fixture; they are covered by render-equality across the four surfaces plus assertion 4. §3.2, AC1 and AC3 all
refer to this definition. `surface: upstream` ids are excluded by
design; **compaction rows are excluded** (they carry no `provider`/`model`). In Slice 0 the fixture is a plain
**id set** — nothing else needs it until WS3 lands. The **card-aware** detail (one entry per `(id, observed
price triple)` with `firstSeen`/`lastSeen` and a count) is a **WS3.3** artifact feeding the divergent-card
report; building it in Slice 0 would be idle machinery. Zero-usage rows (2,382 exist for the two flash ids;
`stopReason: error` with `output = input = 0`) yield **no triple** and are skipped rather than dividing by zero.

**Report re-pricer — the shared parser** (the #373 one-parser contract) gains `--usage-rows`, emitting rows
keyed `(provider, model, ratePeriod)` — where **`ratePeriod = (periodKey, peak|offpeak)`** — with
`{kind, input, output, cacheRead, cacheWrite, cacheWrite1h, ratePeriod, costFrozen}`.

> **Why the peak axis is not optional (code-review round 3, P1).** `vendor(ts)` is **peak-aware** by design
> (§2: 2× inside `peakWindows[]`, 01:00–04:00 and 06:00–10:00 UTC Mon–Fri). The ledger `periodKey` spans
> multiple days, so a group-by on `(provider, model, periodKey)` alone cannot resolve a **single**
> `vendor_rate` — roughly a fifth of records sit in a peak window and would be priced at the wrong rate. The
> emitted rows therefore carry the peak discriminator, and the Δ group-by splits on it. Without this, AC9's
> "exact" claim is false.

**Scope honesty (v6 simplification, from the second-model coherence check):** the re-pricer computes a
**window-level Δ**, not per-request re-billing. Within one `(period, peak|offpeak)` bucket the card is constant
*by definition*, so `Δ = Σ tokens × (vendor_rate − render_rate)` over a `(provider, model, ratePeriod)` group is
**exact** for every model we actually dispatch (none of which has `tiers`). Two stated carve-outs: (i) a
**divergent-card window** (two live cards, §2) is *not* exact — it is reported as an open finding, and the Δ
for records inside it is computed against the **dominant** card and labelled as such; (ii) a **tiered** model is
flagged `tiered: unmodelled` rather than guessed. The earlier design — per-request tier bucketing, a `tierKey`
in the row key, a full `calculateCost` clone — was machinery for a case that does not occur, carrying risk 6
(silent divergence if pi's formula changes) for a number with **no decision consumer**. The synthetic `tiers`
case remains a **unit test of the guarded branch**, not a production path.

- **`kind`** separates `message` from `compaction` rows (compaction records carry no `provider`/`model`);
  parity is asserted against `msg_cost_total` **and** `comp_cost_total` separately.
- **`ratePeriod`** is `(periodKey, peak|offpeak)`: `periodKey` is the ledger period covering the record
  (`effectiveFrom`…`expiresOn`) and the second element is resolved from the ledger's `peakWindows[]` against
  the record timestamp. A Δ window is therefore a group-by, not a per-record join, and still resolves one rate.
- **`cacheWrite1h`** is carried so the Anthropic long-cache-write 2× term is reproducible in the same group-by.

The re-pricer computes the Δ and **never** overwrites `usage.cost`.

### 3.3 What the guards do NOT do

There is **no `expiresOn` CI gate** and no `renderedAt: null` CI failure. A date-triggered red would freeze
every PR on 2026-09-14 until the ledger was edited — the exact ritual the operator rejected. Expiry and age are
**report facts**. Accepted trade-off: reports may read slightly low until the next ad-hoc ledger update;
bounded, and always fixable retroactively (for **message** calls — compaction calls are re-priced only in
total, see §3.2).

### 3.4 Runtime readability (the ledger must be reachable where the report runs)

The weekly report runs under launchd as `~/.pi/agent/scripts/fleet-cost-weekly.sh`, and `setup.sh` populates
that directory from **explicit basename allowlists**. So:

- **A `rates` farm is added to `setup.sh`** (same pattern as the existing `fleet_srcs` allowlist): copy
  `scripts/rates/render.py` and `scripts/rates/deepseek.jsonl` into `~/.pi/agent/scripts/rates/`.
- Reader precedence, defined concretely (not "when resolvable"): **`$RATE_LEDGER`** if set →
  **`$AGENT_INFRA_PATH/scripts/rates/deepseek.jsonl`** if that env var is set and the path exists →
  **script-relative farm copy** (`~/.pi/agent/scripts/rates/`). Under launchd neither env var is set, so the
  farm is the operational path — which is exactly why the farm exists. **Implementation must quote the
  expansion, require an absolute path to a regular file before use, and echo a rejected value into the
  loud-failure output** — an unquoted `$RATE_LEDGER` would word-split or glob, silently falling through to a
  different ledger and degrading the very guard this plan adds (security review, PR #706). An invalid value
  falls through to the next precedence step. Missing ledger at every step = **loud
  failure** (the report prints the attempted paths and prices as `unknown`); it never falls back to a literal.
- **The report prints the resolved ledger path, a `sha256` prefix, and the `asOf` age** as a single line, owned
  by **WS2.1** (not WS3.3) so it ships in Slice 0. The hash matters: render-equality BLOCKs **repo files**, so
  the farm copy would otherwise be a **new unguarded price copy** — exactly the D1 shape this plan exists to
  remove, and the guard would be *inverted* (the surfaces pi stamps from are guarded; the measurement's own
  input is not). With the hash printed, `--check --live` compares farm hash vs repo hash and a stale farm is a
  **detected mismatch**, not a line a human must happen to read.
- Because the runtime may read the **farm copy**, the ad-hoc update procedure (WS5.1) **includes the refresh
  step** (`setup.sh`/`sync.sh`), and the report prints which ledger path it used plus its `asOf` age — so a
  stale farm cannot be silently trusted.
- Integration test: run the report from a farm-shaped temp dir with **no** `AGENT_INFRA_PATH`.
- **Pre-registering is not the same as applying.** `render.py` renders **at HEAD for today's date**, so a row
  pre-registered with `effectiveFrom: 2026-09-14` **self-applies on the next sync** on or after that date — no
  cadence, no owner, no gate (the locked decisions hold). `--check` prints *"pre-registered, pending since N
  days"* whenever `effectiveFrom <= today` and `renderedAt` is still null, so a machine that has not synced
  since the date is **visible** rather than silently stale. This is what actually applies the 2026-09-14
  `v4-pro` → Flash re-route — otherwise that knowledge is captured but never used.
- The **postmortem** (WS3.4) resolves the ledger through the **same precedence chain** and, when it cannot
  reach any copy, prints a one-line warning and emits `unknown` rates — it never aborts a session summary and
  never silently reverts to a literal.

### 3.5 Precedence, per id

| Case | Id | Mechanism | Why |
|---|---|---|---|
| retired but accepted, dispatched | `deepseek-v4-flash` | **own row** (`aliasOf: deepseek-flash`, **no** `expiresOn`) | deleting it reverts to pi-ai July; it is still dispatched and billed, so it must **never** expire |
| in no base layer, dispatched (live default) | `deepseek-v4.1-flash-expires-on-0910` | **own row + the only `expiresOn` tombstone** (`aliasOf: deepseek-flash`), and migrate the **shipped** `defaultModel` off it | only `models[]` can create an id; **this is the single id that carries `expiresOn`** |
| vendor's current id, dispatched | `deepseek-flash` | **own row** | closes D4 (else the store's peak applies) |
| exact-id shadow of a store row | `deepseek-v4-pro` | **own row** + pre-registered second period from `2026-09-14T04:00:00Z` | the date-gate changes the rate, not the id |
| **failover hop legs** (`extensions/shared/provider-failover.ts` `ALIAS_FAMILIES`) | `qwen-tp/deepseek-v4-flash-0731`, `qwen-tp/deepseek-v4-pro`, `openrouter/deepseek/deepseek-v4-flash`, **`openrouter/deepseek/deepseek-v4-pro`** | **rendered per leg**, keyed by *leg provider*; the renderer emits **one entry per `ALIAS_FAMILIES` leg**, not from a hand-written list | these are **byte-identical to the 7,124 primary-identity stamps** (`0.2608/0.7825/0.0083`) and to the extension's `deepseek-v4-pro` literal (`0.435/0.87/0.003625`); `qwen-tp` is `DEFAULT_BLOCKED_PROVIDERS`-gated but config-re-enableable, so a hand-listed set would silently drift out of sync |
| non-DeepSeek literal in a rendered surface | `anthropic/claude-opus-4.8` (OpenRouter extension `5/25`), `venice/deepseek-v4-flash` (`0.14/0.28/0.03`) | render from the ledger with `surface: vendor-vendor` | AC1 greps these files, so they must be either rendered or explicitly declared out of scope |
| clamp-only, never dispatched | `-vision-exp`, `-0813`, `~…latest` | **`modelOverrides`** | no duplication |
| subscription-class | `qwen-token-plan/public` ids (all 18 entries `$0`) | `surface: subscription`, `$0` **explicit** | per locked decision: $0 is *intended* (subscription), not missing data — recorded in the policy doc so it never reads as an oversight |
| upstream-only | anything else | `surface: upstream` | upstream owns its own ids |

## 4. Workstreams (child issues)

`WS1 → {WS2, WS3, WS5}`. Independently startable in parallel: **WS1.1**, **WS5.1**. (WS3.1 is *schema-frozen* —
startable against WS1.1's row contract, which is the point of freezing it. There is no WS4:
that workstream was removed in Revision 2 along with the upstream freshness oracle. The number is left unused
rather than renumbered, so earlier review cycles' references stay traceable.)

- **WS1 — Ledger + render pipeline + id coverage (blocks all).**
  - 1.1 ledger v1: dated periods; `peakWindows`; the pre-registered 09-14 pro row; the current card per id;
    the **seed set spelled out** — one row per observed card per id (for `deepseek-v4-flash`: the bundled July
    card; for `…expires-on-0910`: the pre-correction `0.22/0.66/0.007` row **and** its HEAD row), each with its
    `renderedAt` derived as that triple's **first-seen corpus timestamp** and recorded in `note`. The
    concurrent `0.2608/0.7825/0.0083` stamps get **no** competing row — they are an open divergence (§2).
  - 1.2 `render.py`: the **4** rendered surfaces + the 2 assertions + `--check` with the **mode-tagged** assertion
    table (§3.2) + `--write-in-use-fixture`.
  - 1.3 id migration: explicit `deepseek-flash` own row; **shipped** `defaultModel` → `deepseek-flash`
    (propagates via `merge_settings`, which is `{**dst, **src}` — there is no separate live edit); **one**
    tombstone — `expiresOn` on `…expires-on-0910` **only** (`deepseek-v4-flash` keeps its own row with
    `aliasOf` and no expiry, because it is still dispatched); **extend `check-cost-config.sh`'s matcher** to the new canonical ids
    (`deepseek-flash`, `deepseek-v4.1-*`) so the migrated fleet does not fall outside the clamp guard.
  - 1.4 delete `pi-bootstrap/pi-config/models-store.json` (inert per E4; `setup.sh` no-ops when absent).
  - 1.5 **own-row structure guard** (the v6 replacement for the cut templates). Committed per-id structure for
    the rows that have no predecessor, and a **diff assertion with a defined baseline**: the reference is the
    row as committed at **`git show HEAD:<file>`**, not the working-tree file (otherwise render-equality is a
    tautology and a structural hand-edit is undetectable). The rendered row must differ from that baseline
    **only in `cost`**; `cost` is compared against the **rendered ledger value**. Rows with no predecessor get a
    hand-written full row (see (b) below), since read-modify-write cannot preserve structure that does not exist.

    **(b) full-row specs required for the two new ids:** `deepseek-flash` and
    `deepseek-v4.1-flash-expires-on-0910` are **both absent** from every base layer (bundled catalog, repo
    `models.json`, shipped store), so neither has a previous row: each needs an explicit full row
    (`contextWindow`, `maxTokens`, `reasoning`, `input`, `thinkingLevelMap`, `compat`) or an explicit statement
    that it mirrors the other's row. AC6's diff assertion is scoped to rows **with** a predecessor.
- **WS2 — Guards + wiring.** 2.1 pre-commit (**the repo's own `.husky/pre-commit`** — not
  `templates/.husky/pre-commit`: a consumer's `scripts/` is a symlink with no local `pi-bootstrap/pi-config/`,
  so a template-level render check would redden every consumer commit) + a **`rates` job in `ci.yml`** + a
  **`rates` job in `ci-main.yml`** + the live mode in `sync.sh` + the **`setup.sh` `rates` farm** + the
  **report's ledger-path/hash/`asOf`-age line** (§3.4 — owned **solely** by WS2.1; WS3.3 only *consumes* it, and
  WS5.2 was folded into WS5.1, so the line is never re-edited by a second workstream — which would risk the
  AC8 byte-identity regression). 2.1 also carries: **the write-mode generator invocation** — `sync.sh` gains
  `python3 scripts/rates/render.py` (write) **immediately before** `./pi-bootstrap/setup.sh`, with a
  `git diff --quiet -- pi-bootstrap/pi-config/models.json` guard so an out-of-band ledger edit cannot silently
  ship — because nothing else in the pipeline ever writes the card; **the fixture must be farmed too**
  (`tests/fixtures/rates/in-use-ids.json` into `~/.pi/agent/scripts/rates/`), otherwise the launchd report cannot
  evaluate the coverage row at all; **`ci-main.yml`'s `auto-file-on-failure.needs` must gain `rates`** (it
  enumerates inputs explicitly, so a new job is red-but-unreported without the edit); and a **farm-parity check**
  in `pi-bootstrap/tests/test-setup-no-nesting.sh` mirroring the `record-review` precedent (`check_rates_farmed`),
  so a later refactor that drops the rates loop fails CI instead of silently starving the report. 2.2 the class split of §3.2 (BLOCK vs WARN vs
  live-only, with explicit non-silent skips). 2.3 `tests/rates/run.sh` mirroring `tests/cost-config/run.sh`
  **and wired into both CI workflows** (the #447/#449 lesson: a suite that runs nowhere is not a gate), with the
  fixture-clobber guard `git diff --quiet -- tests/fixtures/rates`. **The extension test is wired here too:**
  `ci-main.yml`'s extension loops glob `extensions/*/test*.mjs` and `extensions/shared/*.test.ts`, so a new
  `extensions/custom-provider-openrouter/index.test.ts` matches **neither** and would run nowhere — it needs an
  explicit invocation (e.g. `npx tsx extensions/custom-provider-openrouter/index.test.ts` in the
  `extension-tests` job's `test-command`) or to be invoked from `tests/rates/run.sh`. The same gap exists for
  the sibling `custom-provider-qwen/provider.test.ts`.
- **WS3 — Dated history + report re-pricing.** 3.1 `--usage-rows` with parity pinned against `parse_sessions`
  (`msg_cost_total` + `comp_cost_total`). 3.2 the **window-level** re-pricer (§3.2) + unit tests incl. a
  synthetic `tiers` case for the `tiered: unmodelled` branch and a `cacheWrite1h` case. 3.3 `fleet-cost-report.sh`
  — **additive** section: frozen vs render- vs vendor-priced, the Δ **per (id × period) window**, the
  open-ended divergent-card report; it **consumes** WS2.1's ledger header line rather than re-emitting it;
  **existing threshold lines stay
  byte-identical**. 3.4 `session-postmortem.sh`'s fallback literal → a ledger read (satisfies assertion 4).
  **NB: WS3.4 is delivered in Slice 0 by #701, not by #703** — see §12 and §14 (code-review round 3: the §4 list
  was the last place still assigning it to WS3).
- **WS5 — Policy + contract.** 5.1 `docs/ops/rate-card-policy.md`: the five layers, the per-id precedence
  table, the "never strip `cost`" rule, the **ad-hoc update procedure** (*"when you learn the price changed:
  append a dated row with the correct `effectiveFrom`, then refresh the farm — history re-prices itself"*), and
  the fixture-regeneration command. 5.3 record the
  frozen schema + `--usage-rows` fields **in #634** (see §5).

## 5. Contract with #634

- **#631 owns the data and the arithmetic:** both tiers, `peakWindows[]`, `peakMultiplier`, dated periods,
  per-record `tier` resolution in the pricing function, and the emitted `--usage-rows`.
- **#634 owns everything behavioral:** the defer queue, pausing, `[PEAK-PAUSE]`, peak-share and
  avoided-premium aggregation.
- **Enforceable, not aspirational:** WS5.3 **records the frozen schema in #634 itself** at implementation time,
  and #634's `shared/peak-window` must **read `peakWindows[]`/`peakMultiplier` from the ledger** — no second
  window truth (a competing window table is exactly the duplication defect this issue exists to remove).
- Frozen at v1: the ledger row schema and the `--usage-rows` fields (#634 may **add**, never rename).
- Note: #634's PR-B mid-flight pause needs a runtime clock engine; **#631 supplies data only** and does not
  cover PR-B.

## 6. The uncontrolled 4h store

Never render into it; never BLOCK on its contents (the existing catalog-class WARN discipline). It is a
**manual sensor**: the operator may consult it while updating the ledger by hand. Every dispatched id carries
`surface: own-row`, so the store can only decide prices for ids we deliberately declare `upstream`. We assume
it will rename/drop ids (it already did). Residual, stated honestly: a vendor change is noticed whenever the
operator next looks — that is the accepted design (see §3.3), not a solved problem.

## 7. The fleet's default model

The **live** `~/.pi/agent/settings.json` `defaultModel` is `deepseek-v4.1-flash-expires-on-0910` (2,830 calls,
in **no** base layer, name self-dated); the **shipped** value is `deepseek-v4-flash`.

1. **Canonical target `deepseek-flash`**, materialized as an **own row** (the store is volatile and peak-form —
   E5/D4).
2. **Migrate the shipped `defaultModel`**; `merge_settings` is source-wins, so it propagates and there is **no
   separate live edit**.
3. **Tombstone alias row** for `deepseek-v4.1-flash-expires-on-0910` (`aliasOf`, `expiresOn`) so in-flight
   dispatch still resolves. Its expiry is **reported, never a CI failure**, and it **never removes the row from
   the render**. This is the **only** id carrying `expiresOn`.
4. Keep `deepseek-v4-flash`'s own row (102k calls, still accepted, billed as Flash) with `aliasOf` and **no
   expiry** — it is still dispatched, so expiring it would re-introduce D2.
5. `deepseek-v4-pro` keeps an own row plus a **pre-registered second period** from `2026-09-14T04:00:00Z` at
   Flash rates (`renderedAt: null`, reported by `--check`). Zero historical calls — this is a *forward*
   correctness fix, and the case that proves the mechanism.

## 8. Testing & verification

Fixture (`tests/rates/run.sh`, wired into both CI workflows) · unit (byte-equality; one hand-edit per rendered
surface reddens) · negative (`$0` landmine; missing own row; a rendered row changing a field **other than
`cost`**; **absent** coverage
fixture errors rather than passing; **a past `expiresOn` stays CI-green** — report-only) · property
(round-trip: `frozen = render(ts)` ⇒ render-fidelity Δ = 0 within float epsilon; perturbed stamp ⇒ the expected
Δ; a synthetic `tiers` case; a `cacheWrite1h` case) · parity (`--usage-rows` vs `parse_sessions`, split by
`kind`) · regression (`fleet-cost-report.sh` threshold lines byte-identical) · integration (`setup.sh` into a
temp live dir; the report run from a farm-shaped dir with no `AGENT_INFRA_PATH`) · extension
(`custom-provider-openrouter/index.test.ts`, created by WS1.2 — the sibling uses `.test.ts`, not `.test.mjs`).

**End-to-end:** `render.py --check` clean→0 / hand-edit→1; `tests/rates/run.sh` green **and invoked by CI**;
`check-cost-config.sh` still green (with the extended matcher); on the real corpus the **staleness Δ**
(`render(ts)` vs `vendor(ts)`) is large and non-zero on pre-correction records; the **divergent-card report**
names `deepseek-v4-flash`'s second triple with its `firstSeen`/`lastSeen`, its dominant card (`0.14/0.28/0.0028`,
≈21.6k records in the Sep-5→Sep-10 window vs 7,124) and its share — i.e. the instrument **detects the known
defect and attributes it to the right cause**, which is the honest version of the earlier "Δ ≈ 0" criterion
(that criterion was unachievable: two cards were live at once, so some mismatch is structural and expected); the
**peak Δ** is consistent on peak hours (hour 03 UTC alone carries 5,347 calls, so the peak/off-peak split is not
decoration); hand-editing the postmortem fallback reddens assertion 4; a past `expiresOn` is reported only.

## 9. Acceptance criteria

1. `scripts/rates/deepseek.jsonl` is the **only** hand-edited price source for **shipped surfaces**. A grep over
   `pi-bootstrap/pi-config/`, `extensions/`, and `scripts/` finds no USD cost literal for any id in the
   **declared owned set** (deepseek-served + failover legs + the two vendored literals named in §3.5) outside
   the ledger and its rendered outputs. **`tests/fixtures/cost-config/**` is exempt by design** (those fixtures
   *test* the guards and must contain literals), and `docs/**` is declared out of scope in the policy doc —
   but `docs/ops/cost-config-policy.md` and `docs/providers.md` do carry owned-id literals today, so they are
   listed explicitly as declared-out-of-scope rather than left to be "fixed" by a future reader.
2. `--check` is wired into pre-commit + both CI workflows and exits non-zero on a hand-edit to **any of the 4
   rendered surfaces**, and on failure of **every BLOCK-class assertion** in §3.2's table (the `$0` landmine,
   dispatched-id own-row, structural equality, coverage fixture present, and the `defaultModel` resolution
   assertion).
3. **In shipped mode**: the coverage fixture is present and the ledger covers every id it lists (**BLOCK**;
   absent fixture ⇒ error, never a silent pass). **In live mode**: the corpus id set is **diffed
   one-directionally** (corpus ⊄ fixture ⇒ loud drift; fixture-only entries ⇒ informational). Scope = repo-owned
   ids (deepseek-served + **every** `ALIAS_FAMILIES` leg — `qwen-tp/*`, `openrouter/deepseek/*`);
   `surface: upstream` excluded; compaction excluded. Regenerated by
   `render.py --write-in-use-fixture`.
4. Every **dispatched** deepseek id has an explicit **own row with explicit `cost`** at the verified current
   card: `deepseek-flash` / `deepseek-v4-flash` / `…expires-on-0910` off-peak `input 0.15 / output 0.60 /
   cacheRead 0.003`; `deepseek-v4-pro` `input 0.66 / output 1.98 / cacheRead 0.022` **plus a second period from
   `2026-09-14T04:00:00Z` at Flash rates**. *(This overrides the issue body's stale `0.22/0.66/0.007`
   targets — treated as a hypothesis.)*
5. Shipped `settings.json defaultModel` = `deepseek-flash`; a check fails if it does not resolve to a
   ledger-covered id.
6. No deepseek-served `models[]` row omits `cost` (the `$0` landmine), and each rendered own row differs from
   the previously committed row **only in `cost`** (v6 diff-based guard — no template artifact).
7. **No CI expiry gate.** A past `expiresOn` / a `renderedAt: null` row is **reported**, and pre-commit and both
   CI workflows stay green.
8. The weekly report prints frozen, render-priced, vendor-priced, both Δs, the bounded stale window, the ledger
   path used, and its `asOf` age; the existing threshold lines are byte-identical to the pre-change output.
9. The **window-level** re-pricer's Δ is exact per `(provider, model, ratePeriod)` group — a group-by over token
   totals × the rate delta, where `ratePeriod` **includes the peak/off-peak discriminator** (without it the Δ
   cannot resolve a single `vendor_rate`, since `vendor(ts)` is peak-aware) — verified against `parse_sessions`
   totals within float epsilon. **Carve-outs:** records inside a **divergent-card window** are priced against the
   dominant card and labelled as an open finding (not exact); a dispatched id carrying `tiers` is **reported as
   `tiered: unmodelled`**, never silently mis-priced, and the synthetic `tiers` case is a unit test of that
   guarded branch.
10. `pi-config/models-store.json` is deleted; no check BLOCKs on store contents.
11. `docs/ops/rate-card-policy.md` documents the five layers, the per-id precedence table, the **ad-hoc update
    procedure including the farm refresh**, the "never strip `cost`" rule, the fixture-regeneration
    command, and the **subscription-class declaration** (`qwen-token-plan` ids are subscription-class: `$0` is
    intended semantics, not missing data — so a future reader never "fixes" it), plus **a registration line so the
    doc is actually reachable** (this repo has no docs index; cross-link it from
    `docs/ops/cost-config-policy.md` and add one `AGENTS.md` REPO-SPECIFIC routing line, mirroring the `VENDOR.md`
    precedent) — otherwise the ad-hoc procedure is undiscoverable at the moment it is needed. **No named owner,
    no cadence.**
12. `check-cost-config.sh`'s matcher covers the post-migration canonical ids (`deepseek-flash`,
    `deepseek-v4.1-*`).
13. #634 can be implemented without adding or renaming a ledger field, and its `shared/peak-window` reads the
    ledger's `peakWindows[]` (WS5.3 records the contract in #634).

## 10. Out of scope

**#690** (coverage gap — this plan makes the Δ legible, it does not close it; **subscription-class spend is
also a #690 line item** — risk 10) · **#634** (defer queue, pausing,
avoided premium) · **#682** (the `setup.sh` per-provider merge deletes live-only ids — a *dependency* of
WS1.3's live effect, not fixed here) · changes to pi upstream (`ModelCost`, `applyModelsJson`, `remoteModels`,
extension semantics) · retired vendor generations (no traffic) · any change to the #341/#373 pre-registered
thresholds.

## 11. Risks this plan does NOT remove

1. **Frozen message history is unrepairable** — the Δ *measures* the damage; nothing repairs it. Compaction
   spend is re-priced only in total (§3.2).
2. **The runtime cannot be time-aware** (E6) — peak calls are mis-stamped by design. Report-side re-pricing is
   the only correction, and it is an estimate.
3. **We do not control the store** — it may rename/drop ids at any 4h tick; consequences are seen after the
   fact.
4. **No machine-readable vendor source** — the ledger is operator-maintained and updated **ad hoc**. The live
   number may read slightly low until the operator next learns of a change; bounded and retroactively fixable
   (message calls).
5. **`render` guarantees consistency, not truth** — a wrong ledger renders wrong everywhere. Only the Δ and
   `asOf` bound the exposure.
6. **Formula replication** — if pi changes `calculateCost`, the re-pricer diverges and produces a *false* Δ.
7. **Farm staleness** — mitigated on the `sync.sh` path by reader precedence, the printed ledger path/hash, and
   the farm-parity test; on the **launchd path it is not mitigated at all** (no `AGENT_INFRA_PATH`, repo
   unreadable), so the printed hash/`asOf` line is the *only* signal there. Stated rather than papered over.
8. **#682's merge semantics persist** — the coverage check narrows the blast radius; it does not close it.
9. **The extension stays wholesale-replace** — the rendered list must stay complete or hop-leg failover breaks.
10. **Subscription usage is invisible in dollar terms** — `qwen-token-plan`-family ids (all 18 entries `$0`) are
    **subscription-class**, recorded in the policy doc so `$0` reads as intent, not oversight. This is a
    **coverage** gap (spend that never appears in local estimates), i.e. **#690's domain**, not a precision
    defect of this plan — noted here only so it is not mistaken for one.
11. **The mis-stamping window is open-ended, not a bounded interval** — the corpus mixture runs from the July
    card (first record 2026-08-13) to the present, so the escalation must be a **bounded statement about a
    specific card** (id, observed triple, first/last seen, $), never a percentage tripwire and never a single
    date range. (2026-08-17 is the vendor's `effectiveFrom`, not the start of the corruption.)

## 12. Wiring check (issue-scoping Phase 6)

Every touch point the plan creates or consumes, with its owner. **⚠️** marks a touch point with no mitigation.

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| `pi-bootstrap/pi-config/models.json` — `providers.deepseek.models[]` | render target | #701 (WS1.2, surface 1) | ✅ |
| `pi-bootstrap/pi-config/models.json` — `providers.<p>.modelOverrides{id}` | render target | #701 (WS1.2, surface 2) | ✅ |
| `pi-bootstrap/pi-config/models.json` — `providers.<p>.models[]` (non-deepseek) | render target | #701 (WS1.2, surface 4) | ✅ |
| `extensions/custom-provider-openrouter/index.ts` | render target | #701 (WS1.2, surface 3) | ✅ |
| `pi-bootstrap/pi-config/settings.json` — `defaultModel` | consumer | #701 (WS1.3, via `merge_settings` source-wins) | ✅ |
| `pi-bootstrap/pi-config/models-store.json` | delete | #701 (WS1.4) | ✅ |
| `.husky/pre-commit` | guard | #702 (WS2.1) | ✅ |
| `.github/workflows/ci.yml` + `ci-main.yml` — `rates` job | guard | #702 (WS2.1) | ✅ |
| `ci-main.yml` — `auto-file-on-failure.needs` | guard input | #702 (WS2.1) | ✅ |
| `sync.sh` — write-mode render + committed-before-sync guard | producer | #702 (WS2.1) | ✅ |
| `pi-bootstrap/setup.sh` — `rates` farm + fixture farm | runtime path | #702 (WS2.1) | ✅ |
| `pi-bootstrap/tests/test-setup-no-nesting.sh` — farm parity | guard | #702 (WS2.1) | ✅ |
| `tests/fixtures/rates/in-use-ids.json` | artifact | #701 (generator) | ✅ |
| `tests/rates/run.sh` | guard | #702 (WS2.3) | ✅ |
| `scripts/fleet-cost-report.sh` — ledger path/hash/`asOf` header line | consumer | #702 (WS2.1) | ✅ |
| `scripts/fleet-cost-report.sh` — Δ sections, threshold byte-identity | consumer | #703 (WS3.3) | ✅ |
| `scripts/session-postmortem.sh` — fallback literal → ledger read | consumer | #701 (WS3.4, moved there) | ✅ |
| `docs/ops/rate-card-policy.md` + its registration (`docs/ops/cost-config-policy.md` cross-link + `AGENTS.md` routing line) | docs | #704 (WS5.1) | ✅ |
| `extensions/custom-provider-openrouter/index.test.ts` (new) + its CI invocation | guard | #702 (WS2.3) | ✅ |
| `scripts/check-cost-config.sh` — matcher extended to the post-migration ids | guard | #701 (WS1.3, load-bearing for AC12) | ✅ |
| shared session parser (#373 one-parser contract) — `--usage-rows` | contract | #703 (WS3.1/WS3.2) | ✅ |
| issue #634 — `peakWindows[]`/`peakMultiplier` contract | cross-issue contract | #704 (WS5.3) | ✅ |
| launchd weekly report path — farm staleness | runtime | — | ⚠️ **unmitigated** (tracked in #707) |

## 13. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **Approach B alone** — re-price only in the report, drop the runtime render | Leaves the hand-edited price copies unowned and lets pi keep stamping stale cost into every non-report consumer. Decisive: **E1** — a `models[]` row without `cost` prices at **$0**, so the card must be owned regardless. |
| **Approach A alone** — render only, no vendor view | `ModelCost` has no time dimension, so no render-only scheme can be correct; render-equality proves only *consistency*, never truth. |
| **Approach C** — disclaim first-party price, consume the upstream store | Falsified four times: E1 (`$0`), E5 (store is **peak** → 2× over-report off-peak), E4 (shipped snapshot inert), and coverage (the store lists neither the 102k-call id nor the fleet default). |
| **Per-request re-pricing** (full `calculateCost` clone, `tierKey` row key) | Cut at v6: machinery for a case that does not occur (no dispatched model has `tiers`), carrying a silent-divergence risk, for a number with **no decision consumer**. Replaced by a window-level Δ. |
| **Committed structural templates** per model row | Cut at v6: a second hand-authored source to keep in sync with `modelFromJson`, for a risk that read-modify-write largely removes. Replaced by a diff-only assertion. |
| **A CI gate on `expiresOn`** | Locked decision — a date-triggered red would freeze every PR on 2026-09-14. Expiry is a **report fact**. |
| **A recurring ledger re-check + named owner** | Locked decision — solo operator; cost is retroactively recomputable, so a schedule buys nothing. Updates are ad hoc. |
| **Consuming the upstream store as the price oracle** | Removed with WS4 (Revision 2). The store is a **manual** sensor only; it can rename/drop ids at any 4h tick. |

## 14. First shippable slice (if the project is cut short)

**Slice 0 — Corrected Card + Ledger v1 + Id Migration.** WS1.1–1.5 + WS2.1/2.2 + WS2.3 smoke + **WS3.4** +
WS5.1 + WS5.3.

Deliverables: ledger v1 (dated, both tiers, the 09-14 pre-registration, the **full per-id seed set** — one row
per observed card, with the live-only id carrying both its pre-correction and HEAD rows); `render.py`
rendering **4** surfaces + 2 assertions with the mode-tagged `--check`; the shipped deepseek block regenerated at
the verified current card **including an explicit `deepseek-flash` own row** (closes D4) with structure
preserved; shipped `defaultModel` migrated, with **one** `expiresOn` tombstone (`…expires-on-0910`) and
`deepseek-v4-flash` kept un-expired; the extended clamp matcher;
the `rates` farm in `setup.sh`; the postmortem fallback replaced by a ledger read (so **no USD literal
survives**); BLOCK-class gates in pre-commit + both CI workflows; the committed coverage fixture; `tests/rates`
smoke; **the `setup.sh` rates farm and the report's ledger-path/`asOf`-age line** (§3.4 — owned by WS2.1
exactly so they land here); the policy doc; the #634 contract recorded in #634. **No expiry gate.**

**Why:** it stops the bleeding on the two compounding defects — **D1** (one source now renders every surface,
so **no new** call is stamped from a stale July literal) and **D2** (all three id cases resolved per-id, so
deleting a row can never silently revert to the July card or remove the live default). WS3 (re-pricing/Δ) is
deferred; the ledger's dated fields are designed so it lands **without a schema change**.

**Residual risk carried by Slice 0 alone:** no staleness Δ and no per-record divergent-card window yet (that is
WS3.3), so the ledger can go stale without the report quantifying it — but the `asOf`-age line and the ledger
path **are** in the slice, so staleness is at least *visible*. Acceptable because Slice 0's own value is
preventing *new* mis-stamping, not measuring *old* mis-stamping.
