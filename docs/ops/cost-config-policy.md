---
title: "Cost-Config Policy — deepseek context clamp @400K & drift guard (#341)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-341, pi-config, cost-config-policy
---

# Cost-Config Policy — deepseek context clamp @400K & drift guard (#341)

One place that pins the agent-infra fleet's **token-cost guardrail contract**:
what the 400K deepseek context clamp means, why the guard's classes are
BLOCK-vs-WARN, and how a deliberate revert (rollback) is done. Delivered by
issue #341 PR-A (config-as-authority); scope/plan:
`docs/scoping/2026-08-28-issue-341-token-cost-driver-solution-diverge.md` +
`docs/plans/2026-08-28-issue-341-session-lifecycle.md`.

**The problem class:** sessions on a 1M context window compact at
`contextTokens > contextWindow − reserveTokens` (pi `compaction.js:163`). At
1M that is ~983K — but pi caches the conversation prefix, so a **ceiling
compaction re-ingests 629–821K fresh tokens at full price** (cacheRead ≈ 0):
measured 9 low-threshold compactions ≈ $0.16 vs 7 ceiling ≈ $0.70. The clamp
cuts that amplifier: at 400K the trigger is ~383K and marathon-session cache
share stays in the cache-read area instead of collapsing.

---

## 1. The conditioned savings claim (honest framing)

- The clamp only changes behavior for sessions whose context crosses **~383K**
  — **marathon sessions**. The 85–87% cache-share figure is marathon-derived;
  the fleet median cache-share is 30%.
- The pre-registered win is over **COMPACTING sessions**, not fleet-wide: the
  cache-read area (cacheRead $0.0028/M on flash) is retained where a 1M
  ceiling would destroy it.
- **Fresh line:** an uncached fresh line runs at **~1.4x** the clamped
  compacting-session cost per token (full input price vs cache-read price) —
  this is the upper bound a session pays when it does start cold; the clamp
  keeps compactions inside the cache-read area so marathon sessions stay at
  the cheap end.

## 2. Why `retry.maxRetries` stays at 10000 (offline-resume contract)

`retry.maxRetries = 10000` is **load-bearing**, not a dial. With a 5-min
capped backoff (patch-pi-retry.sh, #318), 10000 retries ≈ **34 days** of
retrying through an outage — sessions survive any plausible network/provider
outage and resume without user action. This plan **does not touch retry**; the
guard asserts it stays at 10000. (Retry-storm *measurement* is a #365
data-source-discovery task — no persisted retry records exist to analyze yet.)

## 3. Existence-proof assumptions (the Aug 25 transient-200K proof)

- On **2026-08-25 11:51–12:33** the live config transiently ran a **200K**
  context window (trigger ≈ 196K implies `reserveTokens` ≈ **4096** during
  the proof — NOT the shipped 16384) and was silently reverted. That window is
  the existence proof that the compaction trigger fires early and cheaply when
  the clamp is in place, and that live-config writes can silently drift back.
- The clamp target of **400K** (user-selected over 200K) is deliberately
  conservative: it keeps headroom for the p95 45–64KB multi-tool reads near
  the trigger while still avoiding the 1M ceiling.

## 4. The qwen-ha decision (excluded from the clamp)

- `qwen-ha`/`qwen3.8-max` (1M) is the **token-plan HA fallback** — it stays at
  1M by documented decision (it is not deepseek-served; it is the resilience
  path when the deepseek provider is down).
- `qwen-tp`/`qwen3.8-max` (262K) is already under the clamp.
- `kimi-k3` (1M) is a separate provider, **excluded** by the same
  deepseek-served-only scope. The guard's canonical matcher normalizes ids
  (strips `provider/` / `~provider/`) and matches only the
  `deepseek-v4-flash` / `deepseek-v4-pro` family (incl. `-0731`, `-vision-exp`,
  `-0813`, `-latest`) — kimi-k3 and qwen3.8-max are never flagged (negative
  controls in the fixture suite).

## 5. Store-refresh reality + detector semantics

- **Config-as-authority:** pi's `provider-composer` resolves
  `override.contextWindow ?? model.contextWindow` — a models.json definition
  **wins over the store/catalog entry at runtime**. The 4h remote refresh
  (pi.dev) only rewrites the **store**, so the models.json clamp is durable
  and immune to it. All deepseek-served ids are defined in models.json
  (including the catalog-only aliases: openrouter variants, the
  `~deepseek/deepseek-v4-flash-latest` alias, qwen-token-plan variants,
  `deepseek-v4-flash-vision-exp`) so config wins for them too.
- The **store snapshot** also ships clamped (checkedAt bumped so the shipped
  snapshot wins the setup.sh merge) — **best-effort defense-in-depth**: the
  4h refresh may re-write the live store back to 1M, and that is **DETECTED,
  not blocked**.
- **Guard classes** (`scripts/check-cost-config.sh`):
  - `models.json` drift (any deepseek-served id > 400K) → **BLOCK (exit 1)**.
  - `settings.json` drift (compaction block / `retry.maxRetries != 10000`) →
    **BLOCK (exit 1)**.
  - **Missing shipped `models.json` / `settings.json` → BLOCK (exit 1)**:
    deletion of the clamp authority is itself terminal drift (clamp gone while
    CI stays green). Store-class and live-dir-missing (first-install) stay
    WARN.
  - `models-store.json` drift → **WARN** (a hard red would break auto-sync the
    moment pi's refresh legitimately reverts the store — the verifier P0).
    The alert path is the **weekly report** (`fleet-cost-report.sh`, PR-B) and
    the **tripwire**: any compaction record with `tokensBefore ≥ 900K`
    (0.9 × 1M — NOT 0.9 × 400K, which would misclassify every post-clamp
    compaction as a ceiling).
  - **PR-A ships a detect-only store-drift signal**: the store WARN goes to
    stdout and the sync log only — there is **no escalation recipient yet**
    (no email/Slack/ticket) until PR-B lands `fleet-cost-report.sh` (weekly)
    and the tripwire. A drifted live store between PR-A and PR-B is visible in
    the next sync/CI run's log but alerts nobody on its own.
  - Wired: `--shipped-only` in pre-commit + ci.yml/ci-main.yml; the **live
    pass** in `sync.sh` (after setup.sh) blocks on models.json/settings.json
    drift and warns on store drift.

## 6. `COST_CLAMP_OVERRIDE=1` — the documented escape

- The guard honors `COST_CLAMP_OVERRIDE=1`: it **silences the BLOCK, prints a
  loud warning, still detects** (exit 0).
- **Sanctioned use: the rollback window only.** It never enables a live 1M
  session silently — it is the in-window escape while the revert commit is
  prepared. A per-session override was explicitly dropped: startup auto-sync
  clobbers live edits (verified), so the committed revert is the only durable
  escape.

## 7. Rollback semantics (deliberate + committed)

- The only true escape from the clamp is a **deliberate revert commit**:
  context windows back to 1M **and the guard's `CLAMP` constant updated in
  the SAME commit** — a reverted clamp with a stale 400K guard would block
  every sync/commit (or force override usage indefinitely, which is exactly
  the drift the guard exists to surface).
- Trigger (pre-committed, owner = weekly report reader): re-read volume or
  LLM call count per compacting session > 2× the regenerated Aug baseline over
  any 3 consecutive days, **or** ≥ 1 `stopReason:"length"` truncation record
  → revert to 1M. The 200K dial is the pre-registered upside if week-2+ shows
  < 1.5x cost reduction over compacting sessions.
- Re-clamping after a revert requires **re-approval** (the same
  human-gated decision as the original clamp).
