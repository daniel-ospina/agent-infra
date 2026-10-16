---
title: "Rate-card corpus remeasurement — per-id cards, the session-latch window, and the qwen-tp hop-leg literal (#631)"
type: engineering
domain: operations
doc_status: live
created: 2026-09-11
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-631, issue-476, pi-config, models-store, cost-config-policy
---

> **Findings date:** 2026-09-11 — corpus snapshot cut at **2026-09-11T21:57:58Z**.
> Remeasurement of `docs/research/2026-09-09-rate-card-governance.md` against the live session corpus.
> Issue: [#631](https://github.com/daniel-ospina/agent-infra/issues/631) · Level: project (standalone) · Depth: **medium**.
> Supersedes the affected corpus claims in the 2026-09-09 governance research and in
> `docs/plans/2026-09-10-issue-631-rate-card-governance.md` (revised as **v7** at the same time).
> Memory system: **not queried** for this measurement. Every claim below is a direct corpus or git
> measurement, or an inference explicitly labelled as such — no prior epistemic claims were retrieved and
> none were filed.

**Evidence classes used throughout.** The tag is a discipline, not decoration.

- **[MEASURED]** — read directly out of the session corpus or by walking git history. Reproducible from the
  cutoffs in §7.
- **[INFERENCE]** — a causal or mechanism claim that the measurement supports but does not prove. Each one
  names what would settle it.

## TL;DR

The measured price cards are consistent with the 2026-09-09 governance research **except on one headline
claim**, which was wrong in a way that shrinks the problem:

- The `0.2608/0.7825/0.0083` stamps on `deepseek-v4-flash` are **not a per-call mixture** of two live config
  sources. **0 of 288 sessions contain both target cards** — of the 288 carrying a `deepseek-v4-flash` record,
  **276** touch `0.14/0.28/0.0028` (275 exclusively), **6** only `0.2608`, and **6** neither target card (5
  with a newer card, 1 partial/zero-usage only). Six sessions were **latched**
  to `0.2608` at session start inside a bounded **~10-hour window** (2026-09-05T18:29:39Z → 2026-09-06T04:37:52Z).
  Because those six sessions were long-running they kept stamping until 2026-09-11T04:19Z — which is what made
  it *look* like a multi-day mixture. The observable — six sessions, the window boundaries, 0 of 288 mixing —
  is **[MEASURED]**; the card-resolved-once-at-session-start **latch mechanism** is **[INFERENCE]** (see §3, §6.1).
- `deepseek-v4-flash` carries **four** observed cards, not three: `0.14/0.28/0.0028` (93,966 records),
  `0.2608/0.7825/0.0083` (7,197), a **new** `0.15/0.6/0.003` (436, first seen 2026-09-11T01:29:50Z), and the
  ×1 `0.22/0.66/0.007`. **[MEASURED]**
- `deepseek-v4.1-flash-expires-on-0910` carries **exactly one** card — `0.22/0.66/0.007`, first seen
  2026-09-09T20:52:16Z and still live. There is **no** pre/post split at any point, so the plan's
  "pre-correction + HEAD" two-row premise is not evidence-backed. **[MEASURED]**
- The `0.2608` literal exists **only** under `providers["qwen-tp"].models["deepseek-v4-flash-0731"]` in
  `pi-bootstrap/pi-config/models.json` at **every commit since its introduction (`3211574`)**, and it was added by
  failover work (`3211574`, issue #476, 2026-09-06; side-branch `1f38e93`, 2026-09-05). The hop-leg diagnosis is
  **confirmed by inference**; the plumbing that makes the record keep the `deepseek` identity is **not**
  proven from code. **[MEASURED evidence / INFERENCE diagnosis]**
- The shipped and live `defaultModel` is now **`deepseek-flash`**, not
  `deepseek-v4.1-flash-expires-on-0910`. It resolves to its own row at `0.15/0.6/0.003` (corpus-confirmed).
  Without that own row the store's **peak** `0.30/1.20/0.006` would apply. **[MEASURED]**
- The corpus is **live** — this session appends to it — so **every count in this document is a snapshot**,
  not a total. **[MEASURED]**

---

## 1. Corpus, method, and what "the card" means

**Framing: direct measurement (no external sources used).**

- **Corpus:** `~/.pi/agent/sessions/**/*.jsonl` — **345 files**, **116,284** assistant records carrying both a
  `usage` block and a `cost` block. Record timestamps span **2026-08-13T01:03:39Z → 2026-09-11T21:57:58Z**.
  **[MEASURED]**
- **The price card is DERIVED, not stored.** No record carries the rate; each carries dollars and tokens.
  For every token field `<f>` ∈ `{input, output, cacheRead}`, the implied card entry is
  `cost.<f> / usage.<f> × 1e6` USD per 1M tokens. A "card" below is the tuple
  `(input, output, cacheRead)` rounded to the corpus's own precision. **[MEASURED]**
- **Grouping:** by `(provider, model)` for the id-level traffic table, then by the derived card inside each
  id. Records with a zero denominator (`usage.<f> == 0`) yield **no** card and are counted separately, never
  divided by zero. **[MEASURED]**
- **Live-corpus caveat (load-bearing for reproduction).** This measurement was taken *during* a live session,
  so the session appends to the corpus while it runs. All counts are therefore **snapshot** values at the cut
  instant, and re-running later will give higher numbers. §7 gives the cutoffs that reproduce the
  **2026-09-09** research's numbers so the two documents can be compared without confusing growth with drift.
  **[MEASURED]**
- **Id-level traffic (all-time at the cut):**

  | provider | model id | records |
  |---|---|---|
  | deepseek | `deepseek-v4-flash` | 103,930 |
  | deepseek | `deepseek-v4.1-flash-expires-on-0910` | 6,676 |
  | openrouter | `deepseek/deepseek-v4-flash` | 4,280 |
  | deepseek | `deepseek-flash` | 1,396 |
  | anthropic | `claude-opus-4-8` | 1 |
  | deepseek | `deepseek-v4-pro` | 1 (partial — see §2) |

  Provider totals on call records: **deepseek 112,003 · openrouter 4,280 · anthropic 1**. **Zero `qwen-tp`
  call records.** The bare string `qwen-tp` occurs **1,421×** across **446** records. **89** of those are the
  provider field `"provider":"qwen-tp"` — and the provider-field form appears **only** inside `toolResult` /
  `exhaustionMarker` payloads, never as a call-record `provider`. Of the remaining occurrences, **563** sit in
  assistant messages, of which **301** are in `toolCall` `arguments`; **835** of all 1,421 sit inside
  `toolResult`-role records. **[MEASURED]**

---

## 2. Per-id card inventory (measured)

**Framing: direct measurement.**

### 2.1 `deepseek-v4-flash` (provider `deepseek`) — 103,930 records, **FOUR** cards

| card `(in / out / cacheRead)` | records | first seen | last seen |
|---|---|---|---|
| `0.14 / 0.28 / 0.0028` | 93,966 | 2026-08-13T01:03:58Z *(= corpus start)* | 2026-09-11T20:39:43Z |
| `0.2608 / 0.7825 / 0.0083` | 7,197 | 2026-09-05T18:30:26Z | 2026-09-11T04:19:04Z |
| `0.15 / 0.6 / 0.003` | 436 | 2026-09-11T01:29:50Z | **live** |
| `0.22 / 0.66 / 0.007` | 1 | 2026-09-09T21:34:50Z | 2026-09-09T21:34:50Z |

Plus non-card records for the same id: `0.14 / 0.28 / None` × **3** (partial — `cacheRead` had no cost),
and **2,327** records where every cost and usage field was `None`/zero (§6.4). **[MEASURED]**

The `0.15 / 0.6 / 0.003` card is **new** relative to the 2026-09-09 research snapshot and to plan v6.1, which
described three cards. It appears the day the deepseek own row for this id was corrected (2026-09-10
`55d3463`, §4). **[MEASURED]**

### 2.2 `deepseek-v4.1-flash-expires-on-0910` (provider `deepseek`) — 6,676 records, **EXACTLY ONE** card

| card `(in / out / cacheRead)` | records | first seen | last seen |
|---|---|---|---|
| `0.22 / 0.66 / 0.007` | 6,562 | 2026-09-09T20:52:16Z | **live** |

**No pre/post split exists at any point.** The id is not in any base layer (bundled catalog, repo
`models.json`, shipped store), and its single observed card is not produced by any config layer either (§6.2).
**[MEASURED]**

### 2.3 `deepseek/deepseek-v4-flash` (provider **`openrouter`**) — 4,280 records, one card

| card `(in / out / cacheRead)` | records | first seen | last seen |
|---|---|---|---|
| `0.0882 / 0.1764 / 0.01764` | 3,890 | 2026-09-07T11:58:26Z | 2026-09-09T20:49:14Z |

This is the OpenRouter extension's frozen literal (the 2026-09-09 research and plan v6.1 both name it as
`0.0882/0.1764`). The remaining 390 records are non-card / partial. **[MEASURED]**

### 2.4 `deepseek-flash` (provider `deepseek`) — 1,396 records, one card

| card `(in / out / cacheRead)` | records | first seen | last seen |
|---|---|---|---|
| `0.15 / 0.6 / 0.003` | 1,394 | 2026-09-10T22:58:19Z | **live** |

The id only starts producing records after the fleet default moved to it (§5). Its card matches the
current off-peak Flash card and the corrected deepseek own row. **[MEASURED]**

### 2.5 `deepseek-v4-pro` — 1 partial record

A single record at **2026-09-11T16:36:38Z** whose derived card is `(0.66, 1.98, None)` — `input` and `output`
present, `cacheRead` absent. This is a **partial** card, not a full triple, and one record is not a traffic
signal. **[MEASURED]**

---

## 3. Headline correction: the `0.2608` card is a **session latch**, not a per-call mixture

**Framing: adversarial — this section corrects the prior research and plan v6.1.**

The 2026-09-09 research and plan v6.1 asserted that the `0.14/0.28/0.0028` and `0.2608/0.7825/0.0083` cards
were **concurrent** — both live every day Sep-5 → Sep-10 — and therefore that history was a **per-call
mixture** no single-valued card can reconcile. The session-level measurement falsifies the *mixture* half and
replaces it with a much smaller, bounded phenomenon. **[MEASURED]**

- **288 session files** carry a `deepseek-v4-flash` record: **276** touch the `0.14 / 0.28 / 0.0028` card and
  not the `0.2608` one (**275** exclusively — 1 session spans the config change and carries both the `0.14`
  and the newer `0.15` card), **6** touch only `0.2608 / 0.7825 / 0.0083`, **0** touch both target cards, and
  **6** touch neither — of those 5 carry a full newer card (4× `0.15/0.6/0.003`, 1× `0.22/0.66/0.007`) and 1
  is partial/zero-usage only. **[MEASURED]**

The six `0.2608` sessions are confined to a **bounded session-start window**:

| Boundary | Value |
|---|---|
| Last `0.14` session start before the window | 2026-09-05T16:41:37Z |
| Window opens (first `0.2608` session start) | 2026-09-05T18:29:39Z |
| Last `0.2608` session start inside the window | 2026-09-06T04:37:52Z |
| First `0.14` session start after the window | 2026-09-06T14:06:39Z |
| Last `0.2608` **stamp** (from a long-running latched session) | 2026-09-11T04:19:04Z |

No session started **inside** the window used `0.14`; no session started **outside** it used `0.2608`.
**[MEASURED]**

**Interpretation [INFERENCE].** A price card was resolved **once at session start** and then latched for the
life of the session. A ~10-hour window of session starts picked up the `0.2608` card (from the newly added
`qwen-tp` failover literal, §4); those six sessions were long-running, so they kept stamping `0.2608` for
days after the window closed. The apparent Sep-5 → Sep-11 "mixture" is the **shadow of six latched sessions**,
not two cards flipping per call. What would settle it: the session-start metadata that records which card
resolution each session saw (not present in the corpus records measured here).

**Why this matters for the plan.** It is a **simplification**:

1. **Card attribution becomes per-session exact.** Because no session mixes the two cards, a per-session reader
   can attribute a session's card with no ambiguity — the plan's "single-rate approximation" for a session
   summary is *exact for card selection*, though a session that also mixes **ids** still needs one rate.
2. **The divergent-card window collapses.** It narrows from an open-ended Sep-5→Sep-10 mixture to a **bounded
   ~10-hour session-start window affecting six sessions** — small enough to enumerate rather than model.
3. **`render(ts)` still cannot be *match*-total.** Two cards genuinely stamped at the same instant once the
   latched sessions overlap sessions started after 2026-09-06T14:06Z, so a single-valued card still cannot
   reconcile every record — the plan's "defined-total, not match-total" framing survives. **[INFERENCE]**

---

## 4. Git-walk: the `qwen-tp` literal and the deepseek own row

**Framing: internal evidence (git history, direct).**

- **The `0.2608/0.7825/0.0083` literal appears in the shipped config only** under
  `providers["qwen-tp"].models["deepseek-v4-flash-0731"]` in `pi-bootstrap/pi-config/models.json`
  (**lines 146–148**) — test fixtures mirror the same block — and it is present in the `qwen-tp` block at
  **every commit since its introduction (`3211574`)** (it was absent at `7177320`/`6ed4271`, where the
  `qwen-tp` entry had no `cost` block). It is **never** a deepseek own-row value. **[MEASURED]**
- **The deepseek own row for `deepseek-v4-flash` was `0.14/0.28/0.0028` at every commit from 2026-08-06**
  until commit **`55d3463` (2026-09-10)** changed it to `0.15/0.6/0.003`. So no config layer ever published
  `0.2608` as a deepseek card. **[MEASURED]**
- **The literal was introduced by failover work:**
  - commit **`3211574`** (2026-09-06, **issue #476** provider failover), and
  - side-branch **`1f38e93`** (2026-09-05), whose message carries these clauses (spliced from **two separate
    bullets** of that message, not one sentence):

    > "qwen-tp mirror entries (deepseek-v4-flash-0731, deepseek-v4-pro) gain qwen mirror rate cost blocks for
    > hop cost metadata… so hop-leg dispatches resolve at runtime and ledger cost is honest"

    **[MEASURED]**

**Interpretation [INFERENCE].** The `0.2608` stamps on `deepseek-v4-flash` are **failover-hop calls stamped
under the primary `deepseek` identity**, matching the prior research's diagnosis. What is **not** proven from
code is *how* the record retains the `deepseek` identity through a hop leg — see §6.1. What would settle it:
reading the failover dispatch path in `extensions/shared/provider-failover.ts` and pi's extension model
resolution to trace which provider/model identity is written onto the call record.

---

## 5. The shipped `defaultModel` change

**Framing: direct measurement (config + corpus).**

- `defaultModel` is now **`deepseek-flash`** — in **both** `pi-bootstrap/pi-config/settings.json` (shipped) and
  the live `~/.pi/agent/settings.json`. It is **no longer** `deepseek-v4.1-flash-expires-on-0910` (the value
  the 2026-09-09 research and plan v6.1 describe). **[MEASURED]**
- `deepseek-flash` **resolves to its own row** and prices at `0.15 / 0.6 / 0.003` — confirmed independently by
  the corpus (§2.4), whose `deepseek-flash` card is exactly that. **[MEASURED]**
- **Counterfactual.** Without an explicit own row for `deepseek-flash`, the 4h store's `deepseek-flash` entry
  = `0.30 / 1.20 / 0.006` (**peak**, 2× off-peak) would apply. That is plan v6.1's **E5/D4** risk, and the
  defaultModel move makes it live rather than hypothetical: the fleet's default id is now exactly the id whose
  own row is load-bearing. **[MEASURED for the store value and the corpus card; INFERENCE for the
  counterfactual mechanism, which follows E5.]**
- The id `deepseek-flash` first appears in the corpus on **2026-09-10T22:58:19Z** (§2.4) — i.e. after the
  default moved. It has no traffic before the move. **[MEASURED]**

---

## 6. Not determined

**Framing: adversarial — explicit gaps. None of these are resolved by this measurement.**

1. **Hop-leg identity plumbing.** The corpus shows failover-hop prices stamped under the primary
   `deepseek` provider/model identity, but the code path that writes that identity is **not** proven. §4
   establishes *what* happened in git and *which* values were stamped; it does not establish the mechanism.
   *Settles it:* tracing `provider-failover.ts` through pi's extension model resolution to the record writer.
2. **Source of the expires id's `0.22 / 0.66 / 0.007` card.** This value exists in **no** config layer
   (bundled, repo `models.json`, shipped store). It numerically matches one **unrelated** entry —
   `openrouter/deepseek/deepseek-v4-flash-vision-exp` in the store — but the match is only numeric, and the
   provider differs. The real source is unexplained. *Settles it:* finding a config layer or upstream overlay
   that published `0.22/0.66/0.007` between 2026-09-09 and the present.
3. **Pre-2026-08-13 history.** The corpus begins **2026-08-13T01:03:39Z**, so the `0.14 / 0.28 / 0.0028`
   card's first-seen is bounded by **corpus start**, not by the card's real deployment. Its `renderedAt`
   therefore **cannot** be derived from the corpus; git shows the card present from **2026-08-06**. Any
   `renderedAt` seeded for this row is a git-derived decision, not a corpus fact. *Settles it:* the commit
   date (which is the best available proxy) plus, if ever needed, a git walk of the live/previous config
   layers.
4. **The 2,327 zero-denominator records.** Records whose cost/usage fields are all `None`/zero yield no
   derivable card. They are error/stop records, not evidence of any price. Whether they carry a *different*
   hidden signal (e.g. an error class correlated with a provider leg) is unmeasured. *Settles it:* grouping
   those records by `stopReason` and session.
5. **The ×1 `0.22 / 0.66 / 0.007` card on `deepseek-v4-flash`.** It shares its tuple with the expires id's
   only card (§2.2) and appears once, at 2026-09-09T21:34:50Z. Whether it is a hand-edit artefact, a one-off
   cross-id dispatch, or a config transient is undetermined. *Settles it:* the single record's session and
   surrounding metadata.

---

## 7. Reproducibility

**Framing: method — so the next measurement is comparable, not merely repeatable.**

- **Cut instant for this document:** records with timestamp **≤ 2026-09-11T21:57:58Z**. Counts are snapshot
  values (§1).
- **To reproduce the 2026-09-09 research's numbers, cut at `≤ 2026-09-10T23:59:59Z`.** At that cutoff this
  measurement yields, per id:
  - `deepseek-v4-flash` `0.14 / 0.28 / 0.0028` → **92,910** (the 2026-09-09 doc records **92,871**; delta 39).
  - `deepseek-v4-flash` `0.2608 / 0.7825 / 0.0083` → **7,126** (the 2026-09-09 doc records **7,124**; delta 2).
  - the ×1 `0.22 / 0.66 / 0.007` card → **exact** (count and timestamp).
  The small `0.14`/`0.2608` deltas are consistent with corpus growth or a slightly different derivation cutoff
  in the earlier run; they are recorded rather than smoothed over. **[MEASURED]**
- **Method, stated so it can be re-run byte-for-byte:**
  1. Glob `~/.pi/agent/sessions/**/*.jsonl`; keep records with both `cost` and `usage`.
  2. For each `<f>` ∈ `{input, output, cacheRead}`, compute `cost.<f> / usage.<f> × 1e6` when
     `usage.<f> != 0`; otherwise mark `<f>` as absent.
  3. Group by `(provider, model)` and then by the rounded derived tuple; record count, `min(timestamp)`,
     `max(timestamp)`.
  4. Count sessions per `(model, tuple)` and the number of sessions containing **both** of two target tuples
     (the "0/288" check in §3).
  5. Walk `pi-bootstrap/pi-config/models.json` with `git log -p` to find every commit that ever contained the
     `0.2608/0.7825/0.0083` literal and the deepseek `deepseek-v4-flash` row.
- **Live-corpus warning repeated deliberately:** this session's own records are in the corpus, so re-running
  after this session will not match these counts. Compare against the **cutoff-scoped** numbers above, never
  against a raw re-run.

---

## Source Confidence Summary

| Claim | Class | Confidence |
|---|---|---|
| Corpus: 345 files, 116,284 assistant records with usage+cost, 2026-08-13 → 2026-09-11 | [MEASURED] | **[HIGH]** |
| Card is derived (`cost/usage × 1e6`), not stored | [MEASURED] | **[HIGH]** |
| `deepseek-v4-flash` has four cards incl. the new `0.15/0.6/0.003` | [MEASURED] | **[HIGH]** |
| `0.2608` stamps are confined to a bounded ~10h session-start window; 0/288 sessions mix cards | [MEASURED] | **[HIGH]** |
| `…expires-on-0910` has exactly one card (`0.22/0.66/0.007`) — no pre/post split | [MEASURED] | **[HIGH]** |
| `0.2608` literal exists only under the `qwen-tp` id, added by #476 failover commits | [MEASURED] | **[HIGH]** |
| `defaultModel` is now `deepseek-flash`, resolving to `0.15/0.6/0.003` | [MEASURED] | **[HIGH]** |
| Without the own row the store's peak `0.30/1.20/0.006` applies | [INFERENCE] | **[MEDIUM]** (follows E5) |
| The `0.2608` stamps are hop-leg calls under the primary deepseek identity | [INFERENCE] | **[MEDIUM]** — diagnosis consistent with git, mechanism unproven |
| Session-start card resolution is the latch mechanism | [INFERENCE] | **[MEDIUM]** — consistent with 0/288 mixing, not directly observed |
| Source of the expires id's `0.22/0.66/0.007` card | undetermined | **[LOW]** ⚠️ — matches no config layer; only a numeric coincidence |
| Hop-leg identity plumbing | undetermined | **[LOW]** ⚠️ — not proven from code |
| Pre-2026-08-13 card history | undetermined | **[LOW]** ⚠️ — corpus starts 2026-08-13; git is the only witness |

---

## Raw Notes

> Append-only. All numbers are **measurements already performed** for this remeasurement; no new analysis was
> run to write them down. No external/Perplexity calls were made — every source here is the local corpus or
> the repository's git history, so no gated models were used and no cost gate applied.

- **2026-09-11 — corpus scan [MEASURED]:** `~/.pi/agent/sessions/**/*.jsonl`; 345 files; 116,284 assistant
  records with `usage`+`cost`; timestamp range 2026-08-13T01:03:39Z → 2026-09-11T21:57:58Z. Derived card =
  `cost.<f>/usage.<f> × 1e6`.
- **2026-09-11 — id-level traffic [MEASURED]:** `deepseek-v4-flash` 103,930 · `…expires-on-0910` 6,676 ·
  `openrouter/deepseek/deepseek-v4-flash` 4,280 · `deepseek-flash` 1,396 · `claude-opus-4-8` 1 ·
  `deepseek-v4-pro` 1 partial. Provider totals: deepseek 112,003 · openrouter 4,280 · anthropic 1.
- **2026-09-11 — `qwen-tp` string audit [MEASURED]:** bare string `qwen-tp` **1,421** occurrences across
  **446** records; **89** are the provider field `"provider":"qwen-tp"`, and the provider-field form appears
  **only** inside `toolResult`/`exhaustionMarker` payloads (563 occurrences are in assistant messages, 301 of
  those in `toolCall` arguments; 835 of all 1,421 sit in `toolResult`-role records); **0**
  call records with `provider = "qwen-tp"`.
- **2026-09-11 — per-card tables [MEASURED]:** see §2. `deepseek-v4-flash` partials:
  `0.14/0.28/None` ×3, all-None ×2,327. `deepseek-v4.1-flash-expires-on-0910`: one card, 6,562 of 6,676
  records.
- **2026-09-11 — session-latch analysis [MEASURED]:** 288 session files carry a `deepseek-v4-flash`
  record; 276 touch `0.14` (**275** exclusively — 1 also carries the newer `0.15` card), 6 only `0.2608`,
  **0 mixed**, 6 touch neither target card (4× `0.15/0.6/0.003`, 1× `0.22/0.66/0.007`, 1 partial/zero-usage
  only). Session-start window: last pre-window `0.14` start
  2026-09-05T16:41:37Z; window opens 2026-09-05T18:29:39Z; last `0.2608` start 2026-09-06T04:37:52Z; first
  post-window `0.14` start 2026-09-06T14:06:39Z. Longest latch stamp: 2026-09-11T04:19:04Z.
- **2026-09-11 — git walk [MEASURED]:** `0.2608/0.7825/0.0083` only under
  `providers["qwen-tp"].models["deepseek-v4-flash-0731"]`, `pi-bootstrap/pi-config/models.json` lines 146–148,
  at every commit since `3211574` (absent at `7177320`/`6ed4271`), with the same triple mirrored in 8 tracked
  `tests/fixtures/cost-config/*/models.json`. deepseek `deepseek-v4-flash` row = `0.14/0.28/0.0028` from
  2026-08-06 until `55d3463` (2026-09-10) → `0.15/0.6/0.003`. Literal introduced by `3211574` (2026-09-06,
  #476) and side-branch `1f38e93` (2026-09-05), whose message is quoted in §4.
- **2026-09-11 — defaultModel read [MEASURED]:** `pi-bootstrap/pi-config/settings.json` and live
  `~/.pi/agent/settings.json` both now `deepseek-flash`; corpus confirms its own row at `0.15/0.6/0.003`.
- **2026-09-11 — reproducibility check [MEASURED]:** cutting at `≤ 2026-09-10T23:59:59Z` reproduces the
  2026-09-09 doc: `0.14` → 92,910 (doc 92,871), `0.2608` → 7,126 (doc 7,124), the ×1 card exact.
- **2026-09-11 — supersession [MEASURED/inference]:** the 2026-09-09 research and plan v6.1's
  **concurrent/mixture** claim is corrected here (§3). The affected plan claims were revised as **v7** in
  `docs/plans/2026-09-10-issue-631-rate-card-governance.md`.
