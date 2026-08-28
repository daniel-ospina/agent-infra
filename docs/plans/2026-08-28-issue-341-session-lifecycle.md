---
title: "Plan: #341 token-cost guardrails — config clamp @400K + visible fleet (A+B)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-341, pi-config, session-postmortem
---

<!-- research-path: docs/scoping/2026-08-28-issue-341-token-cost-driver-solution-diverge.md (solution-diverge evidence: 17 real compaction records, pi source trigger formula, cache pricing). Note: the diverge doc's Approach A still says retry 10000→5 — SUPERSEDED by the amendment below (retry unchanged). -->

# Issue #341 — Token-cost guardrails: Config Clamp @400K + Visible Fleet (user-selected A+B)

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Cut session token spend (~$44/15d) by clamping the deepseek context window to 400K (the measured driver: ceiling compactions destroy the cache prefix → ~50x cold re-ingestion) and closing the feedback loop (metrics + weekly report + escalation). User-selected: Approach A (Config Clamp) + Approach B (Visible Fleet), ceiling **400K** (not 200K).

**Team:** organisation-design-team

## Confirmed problem (verified by 4 verifiers across 2 cycles against pi source + 17 real compaction records + 203 session JSONLs)

- Compaction trigger = `contextTokens > contextWindow − reserveTokens` (pi `compaction.js:163`): at 1M → 983,616; at 400K → 383,616.
- Ceiling compactions re-ingest 629–821K fresh tokens at full price (cacheRead≈0) — measured 9 low-threshold compactions ≈ $0.16 vs 7 ceiling ≈ $0.70.
- **Conditioning (honest):** the clamp only benefits sessions whose context crosses ~383K (marathon sessions — the 85–87% cache-share figure is marathon-derived; the fleet median cache-share is 30%). The pre-registered win is over COMPACTING sessions, not fleet-wide.
- `retry.maxRetries=10000` is **load-bearing** (documented offline-resume contract, patch-pi-retry.sh: sessions survive any outage via ~34 days of 5-min-interval retries) — UNCHANGED by this plan.
- `defaultThinkingLevel=high`; `scripts/session-postmortem.sh` exists (PR #335) but is wired nowhere and skips `type:compaction` records; no feedback loop; live-config writes can silently revert shipped defaults (Aug 25 11:51–12:33 transient 200K proof — trigger ~196K implies reserveTokens 4096 during the proof, NOT the shipped 16384 — then silent revert).

## Plan (amended cycle-2 — all P0/P1/P2 verifier findings folded in)

### Task A — Config Clamp (DECIDED mechanism: config-as-authority — resolved from pi source, 2026-08-28)

**Mechanism decision (option b, extended):** `provider-composer.js:40` resolves `contextWindow: override.contextWindow ?? model.contextWindow` — the models.json config definition WINS over the store/catalog entry at runtime, BY DESIGN. The 4h remote refresh (pi.dev) only rewrites the STORE, so a models.json clamp is durable and immune to it. **No pi-internal patching** (option a rejected: upstream-owned dist internals, breaks on every pi update, version fragility; the catalog aliases aren't session models — marginal gain). Residual class: any deepseek-served id NOT defined in models.json is DETECTED (weekly report + tripwire), never silently reverted.
1. **models.json = the clamp surface**: `contextWindow` 1,000,000 → **400,000** for every deepseek-served id, INCLUDING defining the catalog-only aliases (openrouter/deepseek-v4-flash, -pro, -0731, -vision-exp, -pro-0813, `~deepseek/deepseek-v4-flash-latest`, qwen-token-plan variants) in models.json so config wins for them too (config-defined = override wins; verify the override shape needs only id+contextWindow at implementation — if a custom-model def requires api/baseUrl, extend the existing deepseek provider block's model list). models-store.json also gets the same 400K edit + checkedAt bump as defense-in-depth (best-effort: the refresh may revert it — DETECTED, not blocked). Excluded by documented decision: kimi-k3, qwen-tp/qwen3.8-max (262K), qwen-ha/qwen3.8-max (1M, token-plan HA fallback).
2. **settings.json**: add the `compaction` block (reserveTokens 16384, keepRecentTokens 20000). **retry.maxRetries UNCHANGED (10000)** — offline-resume contract; retry measurement is a #365 data-source-discovery task (no persisted retry records exist).
3. **Drift guard `scripts/check-cost-config.sh`** (dep-free bash, ~60 lines): canonical matcher (id-normalized: strip `provider/`/`~provider/`) asserting every deepseek-served id ≤400K in shipped + live (`--live-dir` seam, default `$HOME/.pi/agent`) models.json; models-store.json asserted as BEST-EFFORT (warn — the refresh may legitimately revert it); settings.json compaction block + retry=10000 asserted. **Catalog-class drift = DETECT, not block** (a permanent-red blocker would break auto-sync — the verifier P0): sync.sh live pass warns; the weekly report + the tripwire (`compaction tokensBefore ≥ 900K` — NOT 0.9×400K, which would classify every post-clamp compaction as ceiling) are the alert path. Wiring: ci-main.yml step + ci.yml per-PR step + .husky/pre-commit (`--shipped-only` mode for pre-commit). Tests: `tests/cost-config/run.sh` with fixtures regenerated from the LIVE store at implementation time (the plan's 9-entry list is illustrative) + clean 400K fixture. **Override:** the rollback commit (revert to 1M + guard threshold updated in the SAME commit) is the only true escape — per-session override dropped (startup auto-sync clobbers live edits, verified).
4. `docs/ops/cost-config-policy.md`: the conditioned savings claim (cache-read-area over compacting sessions; fresh line +1.4x), retry rationale, existence-proof assumptions (Aug 25 11:51–12:33, reserveTokens 4096 then), qwen-ha decision, store-refresh reality + detector semantics, rollback semantics (revert is deliberate+committed, re-clamp needs re-approval), the `COST_CLAMP_OVERRIDE=1` guard escape (documented: it silences the guard for the rollback window, never enables a live 1M session).
5. Propagation via existing sync.sh → setup.sh (source-wins per provider — verified); the live guard pass warns on the catalog class, blocks on models.json/settings.json drift.

### Task B — Visible Fleet (feedback loop)
6. Wire `scripts/session-postmortem.sh` into the **weekly cadence** via `cron-quality-gates.sh` (the named cadence entry — NOT per-session hooks, which would be the rejected C machinery). Parser fix: include `type:compaction` records (compaction count, `tokensBefore`, `cacheRead≈0` — all present on real records); derive the ceiling classification as `tokensBefore ≥ 0.9 × shipped window` (the 1M-drift detector — compaction records carry no window field; hardcode the treatment-period window). Spike-test the `usage.reasoning` field shape on real JSONL (confirmed present on message records).
7. Weekly report: **`scripts/fleet-cost-report.sh`** (named — the implementer must not improvise the aggregator). Thresholds (all with defined denominators/data sources):
   - (a) **ceiling-compaction count** = records with `tokensBefore ≥ 0.9 × shipped window` → count > 0 escalates (the 1M-drift detector; expected value after clamp: **0**).
   - (b) **cache-share of spend over COMPACTING sessions only** (NOT fleet-wide — fleet median is 30% and at 400K the marathon cache share falls to ~69%, so an 80% floor would be a permanent false alarm). Pre-registered 400K expected: **~65–70%**; escalate only on drift BELOW the expected 400K regime.
   - (c) **output+reasoning share over non-cache tokens** — a TREND instrument for #365 (real median 58%, range 0–91%), NOT an alarm; pre-register the trend baseline; #365's behavioral scoping fires only on sustained rise.
   - Pre-registered expected values: ceiling-compaction count → 0; **fleet-total cost over compacting sessions ~2x lower** than the regenerated Aug baseline (baseline regenerated from retros with the fixed parser in the SAME change — the metric change must not confound the treatment).

### Task C — Watch, rollback, and the 200K dial
8. **Watch instrument `scripts/watch-truncation.sh`** (or a named section of the weekly report): greps session JSONLs for `stopReason:"length"` (the real truncation marker — 20 hits across real sessions; compaction is checked on `agent_end`, so multi-tool turns can exceed 383K mid-turn where a p95 45–64KB read at ~370K context leaves ~26K budget). **Pre-committed rollback trigger:** re-read volume or LLM call count per compacting session > 2× the regenerated Aug baseline over any 3 consecutive days, OR ≥1 `stopReason:"length"` record → **revert to 1M** (the rollback commit updates the guard's threshold in the same commit; `COST_CLAMP_OVERRIDE=1` is the in-window escape). Owner: the weekly report reader.
9. **200K dial (pre-registered, not an afterthought):** if the week-2+ report shows fleet cost reduction over compacting sessions < 1.5x (vs the ~2x target), dial the clamp to 200K — config-only (two numbers + the guard constant, updated in the same commit). This is the honest execution of the user's 400K-first choice: 400K first, 200K as the pre-registered upside.

### Task D — Lifecycle follow-up (issue-title deliverable owner)
10. **#365 filed** (4-week data-gated): lifecycle contract (one-issue-per-session rule, handoff-size budget ~10-line dep-free check per mandate #3, compaction-trigger expectation), escalation wiring (output+reasoning trend from B7c → behavioral scoping), retry-storm data-source discovery. #341's clamp addresses the amplifier; #365 owns the issue's named driver (marathon sessions + oversized handoffs). Note: #363 (sub-agent hard cap 2h→6h) amplifies the marathon-session shape — the contract accounts for it.

## Out of scope (explicit)
Fleet-wide attribution, per-skill call reduction, `defaultThinkingLevel` change (deferred until B measures it), per-session postmortem hooks (rejected C machinery), AGENTS.md throughput-rule changes.

## Verification (O/I — all instrumented)
- O/I (1): `bash scripts/check-cost-config.sh` passes on shipped + live (`--live-dir`) — deepseek-served ids ≤400K everywhere, settings compaction block + retry=10000 intact; fixture tests green (9 backdoor entries fail, clean fixture passes).
- O/I (2): `scripts/fleet-cost-report.sh` runs weekly with all 3 thresholds + compaction records; ceiling-compaction count → 0 post-clamp.
- O/I (3): `scripts/watch-truncation.sh` clean at week 1 (no `stopReason:"length"`, per-compacting-session re-read volume ≤ 2× baseline); rollback trigger pre-committed with the override path documented.
- Suite: guard fixture tests green; session-postmortem parser tests green (compaction records included).

## Complexity
| Domain | Rating |
|--------|--------|
| Config | standard |
| Architecture | standard |
