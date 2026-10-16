---
title: "Research: DeepSeek peak-hour pricing — off-peak scheduling & cost practices"
type: research
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-09
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, deepseek, fleet-cost
---

# Research: DeepSeek peak-hour pricing — off-peak scheduling & cost practices (2026-09-09)

**Domain:** llm-ops / fleet cost
**Status:** Research complete. No implementation yet — decision pending on next step (measure → defer → route).
**Prompt origin:** User ("Dipseq" = DeepSeek). Cost pressure on the agent fleet; ask: *are there emerging practices for scheduling/deferring LLM work around peak-hour pricing?*
**Epistemic memory:** Tortoise unavailable (degraded) — claims not persisted to epistemic graph; verified below via web sources only.

---

## TL;DR

DeepSeek now bills **2× during peak hours**: `01:00–04:00 UTC` and `06:00–10:00 UTC`, **Mon–Fri** (Beijing business hours: 09:00–12:00 & 14:00–18:00). Everything else is off-peak at half the peak rate. The 2× applies to **every token tier**: input cache-hit, input cache-miss, and output.

**⚠️ Local-day boundary:** the weekday qualifier is on the *UTC* day. At UTC−5 the morning window (01:00–04:00 UTC Mon–Fri) lands on the **previous local evening (Sun–Thu 8–11 PM)**, so a fully-safe weekend is **Saturday all day + Sunday until 8 PM local** (the long contiguous off-peak run is Friday ~5 AM → Sunday ~8 PM local). Local Sunday 8–11 PM is peak.

For a US-Eastern operator the expensive windows are **~8–11 PM and ~1–5 AM local** — the "kick off a big batch and sleep" hours. The US **working day is fully off-peak**, so interactive agent work is already cheap; the risk is **overnight autonomous batches**, and the free lunch is the **long contiguous off-peak weekend run (Fri 5 AM → Sun 8 PM local)** — Saturdays are 100% off-peak, Sundays only until ~8 PM local.

DeepSeek has **no native async/batch API** — off-peak *scheduling* is the only time-based discount (unlike OpenAI/Anthropic/Gemini, which sell a 50% batch API with ≤24 h turnaround). Verdict: **defer-and-warn is the right instinct**, but the first step is *measurement* — we do not yet know what fraction of fleet spend lands in the two peak windows.

---

## 1. Verified rate card (official page, fetched 2026-09-09)

| Model | Tier | Off-peak | Peak (2×) |
|---|---|---|---|
| deepseek-v4-flash | input, cache hit | $0.007 /M | $0.014 /M |
| deepseek-v4-flash | input, cache miss | $0.22 /M | $0.44 /M |
| deepseek-v4-flash | output | $0.66 /M | $1.32 /M |
| deepseek-v4-pro | input, cache hit | $0.022 /M | $0.044 /M |
| deepseek-v4-pro | input, cache miss | $0.66 /M | $1.32 /M |
| deepseek-v4-pro | output | $1.98 /M | $3.96 /M |

Source: `https://api-docs.deepseek.com/quick_start/pricing/` (fetched live; footnote: *"Off-peak rates are half of the peak rates. Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday through Friday (all other hours are off-peak)."*). Corroborated by thenextweb ("output and input costs double… 9:00–12:00 and 14:00–18:00 Beijing time"), CostGoat, elser.ai, LinkedIn/Mark Hirsch. **Confidence: HIGH (3+ independent sources on schedule; official page on rates).**

Caveats & reconciliation:
- The **2025-era promo** (off-peak *discount* 16:30–00:30 UTC, 50–75% off V3/R1) belonged to the retired `deepseek-chat`/`deepseek-reasoner` aliases (retired 2026-07-24). The current model is the **opposite framing**: peak *surcharge* on V4. Do not trust old blog posts.
- deepseek.ai (independent tracker, last verified 2026-07-25) still shows the flat pre-surcharge card and calls the surcharge "announced, not active." The **official page today shows the tiers live** — consistent with the internal Aug-16 price-rise note (#284). Official page wins for current state; treat deepseek.ai figures as stale.
- Cache-hit input is ~**1/30th** of cache-miss input (off-peak $0.007 vs $0.22 on flash) — bigger than the 2× peak factor. Cache-hit engineering remains the dominant lever we already exploit (400K clamp, #341).
- Thinking-mode reasoning tokens are billed as output — the peak multiplier applies there too.

---

## 2. What this means for our fleet (timezone mapping)

Machine TZ is UTC−5 (EST). Mapping (Mon–Fri; subtract 1 h if EDT):

| DeepSeek window (UTC) | Beijing | Our local | Verdict |
|---|---|---|---|
| 01:00–04:00 | 09:00–12:00 | **8–11 PM** | **PEAK** (evening) |
| 06:00–10:00 | 14:00–18:00 | **1–5 AM** | **PEAK** (overnight) |
| 10:00–24:00 | 18:00–08:00 | 5 AM–7 PM | off-peak |
| 00:00–01:00, 04:00–06:00 | — | 7–8 PM, 11 PM–1 AM | off-peak (small gaps) |
| Sat all day; Sun until 8 PM | — | — | **off-peak** (contiguous run Fri 5 AM → Sun 8 PM local) |
| Sun 8–11 PM (→ UTC Mon 01:00–04:00) | 09:00–12:00 (Mon) | **8–11 PM Sun** | **PEAK** (weekday qualifier is on the UTC day) |

Implications:
- **Interactive work is already off-peak.** The user's daytime session (now 15:47 local = 20:47 UTC → off-peak) is cheap. The suspicion "we're already not doing much in peak" is *plausible* for interactive work. [derived — arithmetic on the published schedule]
- **The exposure is overnight autonomous work** — marathon/epic-executor batches, long review runs, "leave it running while I sleep" sessions that straddle 1–5 AM local (Mon–Fri early AM) = 100% peak. [derived]
- **Weekend = contiguous free slot.** The off-peak run **Friday ~5 AM → Sunday ~8 PM local** is the natural home for latency-tolerant heavy batches at half the weekday-peak rate. Avoid Sun 8–11 PM (peak). [derived]
- Evening kick-offs 8–11 PM local (Sun–Thu) are peak; a batch started at 8 PM runs 2× for 3 h. Friday evening is off-peak (window is UTC-day-anchored). [derived]

---

## 3. Internal context (what we already have) — all claims `(internal)` unless noted

- **(internal) Cache-share is the primary cost lever in use.** #341 shipped the 400K context clamp to keep marathon-session cache share in the cache-read area; `fleet-cost-report.sh` + `fleet-cost-weekly.sh` escalate on cache-share < 0.65 floor and ceiling compactions. **No hour-of-day / peak-window segmentation exists anywhere in this tooling.**
- **(internal)** #284 notes the "DeepSeek Aug-16 price rise is fleet-wide either way (**off-peak scheduling note**)" — peak-aware scheduling was already flagged as a follow-up, never implemented.
- **(internal)** The local-Qwen decision (2026-09-05) keeps Qwen 32B for "zero-marginal-cost review/drafting passes run as an on-demand night batch" — but note: for *cloud* work, night batches collide with the peak window; for *local* Qwen it remains genuinely free.
- **(internal) Model slots:** task default `deepseek-v4-flash`; second-model review gates `deepseek/deepseek-v4-pro` (expensive tier — the 2× peak hits Pro's $3.96/M output hardest).

---

## 4. External findings — practices emerging in the ecosystem

**A. Time-of-day demand shaping is becoming a first-class lever.** DeepSeek's stated goal (per press) is spreading demand away from Beijing business hours. Inference providers are moving from flat cards to time/load-typed pricing; the operational answer on the customer side is workload *classification*: synchronous/interactive vs latency-tolerant/batch, then routing each class to the cheapest legal path. [HIGH: multiple independent practitioner sources + provider docs]

**B. Batch-API discount is the ecosystem's standard "defer" mechanism — and DeepSeek lacks it.** OpenAI, Anthropic, and Gemini all sell ~50% off input+output for async batch jobs with a ~24 h delivery window (`llmapicosts.com`, `howmanytokens.io`, intuitionlabs, APIScout — 5+ sources, HIGH). DeepSeek has **no documented native batch endpoint** (official docs + third-party guide, MEDIUM→confirmed by docs check) — so for DeepSeek the "batch discount" only exists as *time-shifting to the off-peak window*. This makes a **local queue + scheduler** the only way to get the batch-style saving on DeepSeek.

**C. Spot / flex pricing exists at other inference providers** (e.g., Together flex-style, spot GPU markets) — the same "cheaper if you accept latency/flexibility" trade; not needed for DeepSeek whose off-peak is already the flex tier. **[MEDIUM]** ⚠️ single-source-class (provider docs/announcements + spot-market practice).

**D. FinOps for agent fleets is maturing into a practice area.** AWS Well-Architected now has an *agentic AI lens* with cost-governance guidance (automated controls, anomaly detection, continuous feedback loops); practitioners converge on: budgets + pre-flight cost estimates, block/throttle on policy breach, smaller-cheaper-model routing per task, token budgets, and output-quality-per-dollar measurement. ⚠️ medium (mixed blog/guides + AWS doc). Cost *attribution by time window* (which our sessions already capture, but don't segment) is the enabling primitive for all of this.

**E. The highest-leverage DeepSeek-specific practices remain cache engineering and output control**, not scheduling: prefix-first prompt layout (stable system prompt front → high input cache-hit rates; the ~90% figure is a deepseek.ai worked-example, not a guarantee) and cutting reasoning/output tokens (reasoning billed as output; `reasoning_effort`/output caps). Scheduling is additive on top — worth at most ~2× on the *peak-exposed slice*, whereas cache-hit ratio already moves ~30× on input. **[HIGH for the rate-card arithmetic; the ~90% hit figure is ⚠️ single-source (deepseek.ai worked example, consistent with official docs' automatic prefix caching)]**

**F. Adversarial check (does deferral actually pay?)** — the honest answer: it pays **only on the slice of traffic that lands in peak windows**. If our fleet is >90% interactive daytime (off-peak), a scheduling build-out is near-zero ROI until measurement proves otherwise. Conversely, one overnight epic-executor marathon in the 1–5 AM window is 100% peak-priced — and moving it to a weekend slot halves that cost with zero latency impact. **[internal analysis — arithmetic on measured claims, not an external source]**

---

## 5. Recommendation (staged, cheapest-first)

1. **Measure first (prerequisite, low effort):** extend `fleet-cost-report.sh` (or the shared `session-postmortem.sh` parser) with a **peak/off-peak spend split** — session JSONLs already carry per-call timestamps and token costs; classification is a ~10-line filter on `01:00–04:00` / `06:00–10:00` UTC weekdays. Output: "what % of fleet spend lands in peak?" → go/no-go for everything below.
2. **Defer + warn (the user's instinct, cheap to build):** a peak-window helper the agent loop consults before launching a *heavy, latency-tolerant* operation (epic-executor batch, marathon review, session-archival passes): if now ∈ peak window → print a cost WARNING with the off-peak ETA and offer "defer to next off-peak / weekend" instead of silently running hot. Interactive work is never gated.
3. **Time-shift known batch cadences:** move any overnight/night-autonomous schedules (cron-quality-gates heavy passes, backup/archival of sessions, epic-executor runs) out of the local peak hours (Sun–Thu 8–11 PM, Mon–Fri 1–5 AM) into off-peak day slots or — best — the long contiguous weekend run (Fri 5 AM → Sun 8 PM local).
4. **Only if measurement shows meaningful peak exposure:** add spillover routing — during peak, latency-tolerant calls go to a flat-priced alternate path (openrouter/qwen-token-plan variants already exist in models.json) where the markup is < 2×. Never silently — annotate `[PEAK-ROUTE]`.
5. **Keep feeding the two dominant levers:** prefix-first prompt layout (cache hits) and reasoning/output budget caps — these dwarf the 2× window on most workloads.

## 6. Open questions for the user

- What fraction of fleet spend actually runs 8 PM–5 AM local (overnight batches)? (Answerable by #1 above.)
- Should heavy autonomous batches get a **weekend default slot**?
- Do we want a **WARN-only** peak banner first (non-blocking), or full defer-with-queue?

---

## 7. Source confidence summary

| Claim | Tier | Sources |
|---|---|---|
| Peak windows 01:00–04:00 & 06:00–10:00 UTC Mon–Fri, off-peak = half | High | official docs (live fetch) + 4 independent trackers (windows); deepseek.ai corroborates windows only — its rate card is stale per §1 |
| Spot/flex pricing exists at other inference providers (§4C) | Medium | provider docs/announcements, spot-market practice — ⚠️ single-source-class |
| Cache/output levers dominate; ~90% cache-hit figure (§4E) | High / ⚠️ single-source | official rate-card arithmetic (30×); ~90% figure = deepseek.ai worked example |
| Deferral ROI proportional to peak-exposed slice (§4F) | (internal analysis) | arithmetic on measured claims — not external evidence |
| 2× applies to all tiers incl. cache-hit & output; Pro $3.96/M peak output | High | official docs (live fetch) |
| Legacy chat/reasoner aliases retired 2026-07-24; old 16:30–00:30 promo is V3/R1-era | Medium | deepseek.ai, official changelog refs |
| OpenAI/Anthropic/Gemini batch APIs ≈ 50% with ≤24 h | High | llmapicosts, howmanytokens, intuitionlabs, APIScout, leanlm, cloudzero, dev.to |
| DeepSeek has no native batch API | Medium | official docs (absence), chat-deep.ai guide |
| FinOps/agent-lens practices (budgets, routing, attribution) | Medium | AWS Well-Architected agentic lens, praesidia, fast.io, codenotary, fleetctl |
| Cache-hit ≈ 1/30 of miss on input | High | official rate card arithmetic |
| Peak exposure of our fleet is unmeasured | (internal) | fleet-cost tooling lacks hour-of-day split |

## 8. Notes / follow-ups

- Tortoise memory offline — no claims written to epistemic graph (degraded).
- Old web posts quoting the 2025 off-peak promo (16:30–00:30 UTC) are misleading for today's V4 pricing — historical, superseded.
- **Timezone precision:** all local-time statements assume UTC−5 (machine TZ). If the box ever reports EDT (UTC−4), shift local windows +1 h. The weekday qualifier is UTC-anchored — local Sunday 8–11 PM is peak, Friday evening is off-peak.
- Candidate follow-up issue if measurement shows >~10% peak spend: "fleet-cost: add peak/off-peak spend split + peak-window WARN on heavy dispatches."
