---
title: "Cost-Config Policy — deepseek context clamp @300K, drift guard (#341) & bounded retry/hang contract (#1088)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-341, issue-1088, issue-1078, issue-1110, pi-config, cost-config-policy
---

# Cost-Config Policy — deepseek context clamp @300K & drift guard (#341)

One place that pins the agent-infra fleet's **token-cost guardrail contract**:
what the shipped 300K deepseek context clamp means, why the guard's classes
are BLOCK-vs-WARN, and how a deliberate revert (rollback) is done. Delivered by
issue #341 PR-A (config-as-authority); scope/plan:
`docs/scoping/2026-08-28-issue-341-token-cost-driver-solution-diverge.md` +
`docs/plans/2026-08-28-issue-341-session-lifecycle.md`.

**The problem class:** sessions on a 1M context window compact at
`contextTokens > contextWindow − reserveTokens` (pi `compaction.js:163`). At
1M that is ~983K — but pi caches the conversation prefix, so a **ceiling
compaction re-ingests 629–821K fresh tokens at full price** (cacheRead ≈ 0):
measured 9 low-threshold compactions ≈ $0.16 vs 7 ceiling ≈ $0.70. The clamp
cuts that amplifier: at 300K the trigger is **~283,616** (300,000 − 16,384
`reserveTokens`) and marathon-session cache share stays in the cache-read
area instead of collapsing.

**Sibling policy (#365):** this file pins the *config* clamp + drift guard;
the *behavioral* cap on the marathon class (one-issue-per-session, handoff-size
budget, compaction-trigger expectation, max-call guidance, and the
pre-committed output+reasoning escalation with its calibration-pending
threshold) is `docs/ops/session-lifecycle-contract.md`.

**Shipped regime (the #511 dial):** this policy pins the LIVE config numbers —
clamp **300K**, compaction trigger **~283,616** (= 300,000 − 16,384
`reserveTokens`), `keepRecentTokens` **12000**. Dialed 400K→300K by #476's
Compaction fix / PR #511 (commit `3211574`, 2026-09-05): pi-config/models.json
(23 deepseek entries 400000→300000), settings.json (`keepRecentTokens`
20000→12000), and the guard `CLAMP` 400000→300000
(`scripts/check-cost-config.sh`). The 400K-selected-at-#341 context in §3 is
history; the pin below is the shipped 300K regime.

---

## 1. The conditioned savings claim (honest framing)

- The clamp only changes behavior for sessions whose context crosses
  **~283.6K** (the shipped 300K-clamp trigger, 283,616) — **marathon
  sessions**. The 85–87% cache-share figure is marathon-derived;
  the fleet median cache-share is 30%.
- The pre-registered win is over **COMPACTING sessions**, not fleet-wide: the
  cache-read area (cacheRead $0.003/M on flash) is retained where a 1M
  ceiling would destroy it.
- **Fresh line:** an uncached fresh line runs at **~1.4x** the clamped
  compacting-session cost per token (full input price vs cache-read price) —
  this is the upper bound a session pays when it does start cold; the clamp
  keeps compactions inside the cache-read area so marathon sessions stay at
  the cheap end.

## 2. The bounded retry/hang contract (#1088) — two ceilings, one finite budget

The shipped retry contract is **bounded**: a session that cannot make progress
reaches a visible terminal/needs-input state inside a declared wall-clock
window, while a transient outage still recovers without user action.

**What changed, and why it was safe to change.** The previous contract was
10,000 retry attempts plus a 5-minute backoff cap (`patch-pi-retry.sh`,
#318) and 10-minute per-attempt timeouts — declared *load-bearing, not a dial*.
It was defensible only because retries could not succeed: `createClient()`
pooled sockets the server had already killed, so every retry met a corpse
(#1110, upstream "Issue B" in `docs/upstream-pi-bugs.md`). A budget that can
never buy recovery is not load-bearing — it is pure exposure:
`10000 x (10 min attempt + 5 min backoff)` = **34–104 days** of a session
spinning with no state that distinguishes "retrying" from "working" (measured
on 2026-09-15: three sessions wedged 24–83 min, 0 B of socket traffic, the
signature in #1088). #1110 is fixed and merged (`extensions/http-pool-hygiene/`)
— a retry now lands on a fresh connection — so the unbounded budget no longer
protects anything. It is now only an unbounded hang.

**The contract.** pi has no agent-level wall-clock retry deadline
(`_prepareRetry()` in `dist/core/agent-session.js` is an attempt count only),
so a session's exposure is the **product**, not the count:

    window = (maxRetries + 1) x per-attempt ceiling + sum(backoff)

Every term is pinned below, and `scripts/check-cost-config.sh` asserts both the
exact values and the **derived window**:

| Knob | Value | Role |
|---|---|---|
| `retry.maxRetries` | `7` | 8 attempts total — the attempt budget |
| `retry.baseDelayMs` | `2000` | backoff base: 2s, 4s, 8s, 16s, 32s, 60s, 60s |
| backoff cap (`patch-pi-retry.sh`, `PI_MAX_RETRY_DELAY_MS`) | `60000` | 1-minute retry cadence — uniform, never 17m/34m/68m gaps |
| `httpIdleTimeoutMs` | `300000` | **silent-hang ceiling** (undici headers/body idle; pi's own default) |
| `retry.provider.timeoutMs` | `600000` | **per-call ceiling** (SDK total request) — unchanged |
| `retry.provider.maxRetries` | absent / `0` | provider-level retries multiply the calls inside one attempt — pinned off |

Derived, and enforced by the guard:

- **no-progress window** `(7+1) x 300000 + 182000` = `2,582,000 ms` ≈ **43.0 min**
  ≤ the declared **45-minute** ceiling (`HANG_WINDOW_CEILING_MS` = `2700000`).
- **worst-case window** (every attempt burns its full SDK ceiling)
  `(7+1) x 600000 + 182000` = `4,982,000 ms` ≈ **83 min**
  ≤ the declared **90-minute** ceiling (`WORST_WINDOW_CEILING_MS` = `5400000`).
- **transient recovery ladder** = `2+4+8+16+32+60+60` = **182 s** ≈ 3 min of
  retrying after a fast-failing (refused/reset) attempt.

**Why these numbers — against the failure modes, not against roundness.**

- *Poisoned pool / persistent outage* — the observed #1088 mode: the attempt
  either fails fast or stalls **silently**, and the session is invisible. The
  silent hang is bounded by the **idle** ceiling, because a hung attempt emits
  no bytes — exactly the measured 0 B signature. 5 minutes of zero-byte silence
  is ~1.5 orders of magnitude above a normal time-to-first-token on a
  300K-context request; 8 attempts x (<=5 min idle + <=1 min backoff) bounds the
  whole hang to ~43 min — a coffee break, not a season. (On this host the
  observed cost was 34-104 days.)
- *Transient outage* — wifi handoff, load-balancer restart, short provider
  blip. The ladder still rides ~3 minutes of retrying, and #1110 is what makes
  a tighter budget safe: the retry that lands after connectivity returns now
  *succeeds*. A longer outage terminates the turn **visibly** — pi emits
  `auto_retry_end` with the final error and the session accepts input — rather
  than absorbing an arbitrary deadline; the user re-issues one message. That is
  the deliberate trade: the old contract promised unattended survival of *any*
  outage and in practice delivered a silent multi-day hang.
- *Legitimate slow call* — the two ceilings bound **different things**, and the
  ordering between them is what keeps that true. `httpIdleTimeoutMs` =
  `300000` is pi's own `DEFAULT_HTTP_IDLE_TIMEOUT_MS`; it maps to undici
  `headersTimeout`/`bodyTimeout`, so it bounds a call that **never emits a
  byte** (a 300K-context prefill's time-to-first-byte, or a mid-stream stall).
  `retry.provider.timeoutMs` = `600000` (unchanged) bounds a call that *is*
  streaming. The enforced invariant is `httpIdleTimeoutMs < provider.timeoutMs`:
  if the total ceiling were at or below the idle ceiling, the idle ceiling could
  never fire first and the no-progress window would silently become
  `maxRetries x providerTimeout`. Going *below* pi's default idle ceiling is
  deliberately **not** done — that would need a measured time-to-first-byte
  distribution for 300K-context requests, which we do not have; 5 minutes is the
  upstream-considered value, so the fleet's previous 10 minutes was the
  unmeasured outlier.

**What can defeat it (checked, not assumed).** Four escapes were closed or
scoped explicitly:

- `COST_CLAMP_OVERRIDE=1` silences the **clamp** block only (models.json
  `contextWindow` / `modelOverrides`). Retry-contract violations are counted
  separately (`RETRY_BLOCKS`) and settings/compaction violations in a third
  counter (`SETTINGS_BLOCKS`); the guard exits 1 when **either** is non-zero,
  and the banner says so. An ambient env var must not be able to defeat the
  retry bound, nor to hide a reverted/disabled compaction contract — neither
  has a rollback window. That
  includes the two *absence* cases, which are retry-class precisely because
  they are not a clamp rollback: a **deleted** settings file (the contract
  itself is gone) and one that **cannot be analysed** — unparseable, valid JSON
  that is not an object, or any failure that leaves the derived window
  underivable (fail closed; a bound that cannot be computed must never read
  green). §6 below documents the override, and those carve-outs are pinned by
  tests 20, 22 and 26.
- **Project settings.** pi resolves the project file from the **session cwd**
  (`join(resolvedCwd, ".pi", "settings.json")`), not from the repo root — so a
  session started in a subdirectory merges *that* directory's project file over
  the global settings, and a project file could revert the contract while the
  shipped and live files read clean. The guard walks the checkout for **any**
  `.pi/settings.json` (following symlinked `.pi` directories, **at any depth** —
  an explicit traversal with a realpath visited-set, not a depth cap, because a
  session cwd can be any directory and a cap silently missed deeper files) —
  including under `.worktrees/`, which is gitignored but *is* a live session cwd —
  and fails closed on each one that carries `retry`, `httpIdleTimeoutMs` or
  `compaction`, or that is unparseable, not a file, or not a JSON object.
  (`compaction` counts because a project file can disable compaction or shrink
  it exactly as it can revert `retry` — both are override-immune settings
  classes, and leaving `compaction` out was a false PASS.) Scope boundary, stated
  plainly: the walk covers **one checkout**; a *different* repo's project
  settings are outside the reach of a guard run inside this one.
- **Extension-registered providers.** An extension that builds its own undici
  `Agent` (e.g. `extensions/custom-provider-qwen/`, the HA fallback) bypasses
  pi's global dispatcher, so `httpIdleTimeoutMs` never reaches it. The guard
  cannot see TypeScript constants and does not assert them; this PR aligned that
  Agent's `bodyTimeout` with the same 5-minute silent-hang ceiling and pins the
  reasoning in the comment there. Any future provider extension must do the same
  — that file is the worked example.
- **Provider-level retries.** `retry.provider.maxRetries > 0` multiplies the
  provider calls inside one attempt, so it is part of the window; it is pinned
  to absent/`0` (pi's own settings doc says the same).

**Coupling — the actual bug class.** The pre-#1088 guard pinned the attempt
count alone (`retry.maxRetries != 10000` → BLOCK) while this doc declared it
load-bearing, so the *window* could drift green in either direction: raising
the count was blocked, but raising the backoff cap or the idle ceiling (or
inflating `retry.provider.timeoutMs`) was not — and the count alone says
nothing without them. The guard now reads the backoff cap **out of**
`scripts/patch-pi-retry.sh`, computes the window from the **actual** settings,
and BLOCKs when any of: a pinned value drifts, the cap and the guard disagree,
the two ceilings invert, or either window exceeds its declared ceiling. A
missing/unreadable patch script is a **fail-closed BLOCK** — a window that
cannot be computed must never read green. `tests/cost-config/run.sh` tests
15–26 pin guard↔settings↔patch↔doc, including the case where the guard
constants and the settings are moved **together** to 8 retries: the
exact-value checks stay green and the **derived** window check is what fires.
There is no `COST_CLAMP_OVERRIDE` for this contract: unlike the context clamp,
nothing here needs a rollback window.

**Per-call ceiling consistency (#1078).** #1078 asks for a per-call resource
ceiling on a *tool* invocation (CPU/IO — the prevention leg of the #943
family); this section pins the per-call ceilings on the *provider-call*
surface. They share one invariant, enforced here for the surface that has it
and required of #1078's: **a per-call ceiling must sit strictly below the
enclosing retry/deadline window, and that window must be finite** — otherwise
the ceiling can never fire and the "bound" is inert. #1078's tool-call ceiling
(which depends on #1066 for an enforceable kill) must satisfy the same
property; this guard is the pattern to copy, not a substitute for it.

## 3. Existence-proof assumptions (the Aug 25 transient-200K proof)

- On **2026-08-25 11:51–12:33** the live config transiently ran a **200K**
  context window (trigger ≈ 196K implies `reserveTokens` ≈ **4096** during
  the proof — NOT the shipped 16384) and was silently reverted. That window is
  the existence proof that the compaction trigger fires early and cheaply when
  the clamp is in place, and that live-config writes can silently drift back.
- The clamp target of **300K** (dialed 400K→300K by #476's Compaction fix /
  PR #511, 2026-09-05; #341 originally selected 400K over 200K) is
  deliberately conservative: it keeps headroom for the p95 45–64KB multi-tool
  reads near the trigger while still avoiding the 1M ceiling.

## 4. The qwen-ha decision (excluded from the clamp)

- `qwen-ha`/`qwen3.8-max` (1M) is the **token-plan HA fallback** — it stays at
  1M by documented decision (it is not deepseek-served; it is the resilience
  path when the deepseek provider is down).
- `qwen-tp`/`qwen3.8-max` (262K) is already under the clamp.
- `kimi-k3` (1M) is a separate provider, **excluded** by the same
  deepseek-served-only scope. The guard's canonical matcher normalizes ids
  (strips `provider/` / `~provider/`) and matches the canonical
  `deepseek-flash` (V4.1 Flash), its `deepseek-v4-flash` legacy alias, and the
  `deepseek-v4-pro` (future bare `deepseek-pro`) family — dotted `v4.1-*` ids,
  `-0731`, `-vision-exp`, `-0813`, `-latest`, and any `:`-suffixed
  (routing-tier) shape — the `:` terminator catches those ids, and `:batch` is
  the fixture control for it — so kimi-k3 and qwen3.8-max are never flagged
  (negative controls in the fixture suite).

  Rate-card note (2026-09-10): flash is off-peak 0.15 in / 0.60 out / 0.003
  cache-hit per 1M (peak = 2x). From 12:00 Beijing 2026-09-14 `deepseek-v4-pro`
  requests route to V4.1 Flash at Flash pricing — revisit its 0.66/1.98/0.022
  card then (#716).

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
  - `models.json` drift (any deepseek-served id > 300K) → **BLOCK (exit 1)**.
  - `settings.json` drift (compaction block: enabled + `reserveTokens` 16384 +
    `keepRecentTokens` 12000; or the `retry`/`httpIdleTimeoutMs` contract —
    the keys are `retry.maxRetries`, `httpIdleTimeoutMs`, `retry.baseDelayMs`,
    `retry.provider.timeoutMs`, `retry.provider.maxRetries`; **the table in §2
    is the single source for their values, which are deliberately NOT restated
    here** — or a missed `retry.provider.timeoutMs` > `httpIdleTimeoutMs`
    ordering; or a DERIVED retry/hang window over its declared ceiling) →
    **BLOCK (exit 1)**. Drift in `scripts/patch-pi-retry.sh`'s backoff cap
    (`RETRY_MAX_BACKOFF_MS`, pinned in §2) — or an unreadable/missing patch
    script — is **BLOCK (exit 1)** too: the window cannot be computed without
    it, and a bound that cannot be computed must never read green. A project
    settings file (`<repo>/.pi/settings.json`) carrying `retry` or
    `httpIdleTimeoutMs` is **BLOCK (exit 1)** as well (pi merges it OVER the
    global settings). An ambient `PI_MAX_RETRY_DELAY_MS` differing from the
    contract cap is **BLOCK (exit 1)**: the guard reads the DEFAULT cap, so
    without this the environment could install a different cap while the guard
    stayed green.
  - **Missing shipped `models.json` / `settings.json` → BLOCK (exit 1)**:
    deletion of the clamp authority is itself terminal drift (clamp gone while
    CI stays green). Store-class and live-dir-missing (first-install) stay
    WARN.
  - `models-store.json` drift → **WARN** (a hard red would break auto-sync the
    moment pi's refresh legitimately reverts the store — the verifier P0).
    The alert path is the **weekly report** (`fleet-cost-report.sh`, PR-B) and
    the **tripwire**: any compaction record with `tokensBefore ≥ 900K`
    (0.9 × 1M — NOT 0.9 × 300K, which sits at 270K — below the 283,616
    trigger — and would misclassify every post-clamp compaction as a ceiling).
  - **PR-A ships a detect-only store-drift signal**: the store WARN goes to
    stdout and the sync log only — there is **no escalation recipient yet**
    (no email/Slack/ticket) until PR-B lands `fleet-cost-report.sh` (weekly)
    and the tripwire. A drifted live store between PR-A and PR-B is visible in
    the next sync/CI run's log but alerts nobody on its own.
  - Wired: `--shipped-only` in pre-commit + ci.yml/ci-main.yml; the **live
    pass** in `sync.sh` (after setup.sh) blocks on models.json/settings.json
    drift and warns on store drift.

## 6. `COST_CLAMP_OVERRIDE=1` — the documented escape

- The guard honors `COST_CLAMP_OVERRIDE=1`: it **silences the CLAMP BLOCK,
  prints a loud warning, still detects** (exit 0).
- **It does not cover the retry/hang contract (#1088) or the settings/
  compaction contract.** Three counters now separate the block classes: the
  clamp (`block()`), the retry contract (`block_retry()` → `RETRY_BLOCKS`) and
  the settings/compaction contract (`block_settings()` → `SETTINGS_BLOCKS`).
  Even with the override set, the guard exits 1 when either of the latter two
  is non-zero, and the banner says so. The retry class includes the *absence*
  cases, because neither is a clamp rollback: a **deleted** settings file (the
  contract is gone) and one that **cannot be analysed** (unparseable,
  non-object JSON, or any failure that leaves the derived window underivable —
  fail closed). Tests 20, 22 and 26 pin all of it.
- **Sanctioned use: the clamp rollback window only.** It never enables a live
  1M session silently — it is the in-window escape while the revert commit is
  prepared. A per-session override was explicitly dropped: startup auto-sync
  clobbers live edits (verified), so the committed revert is the only durable
  escape.

## 7. Rollback semantics (deliberate + committed)

- The only true escape from the clamp is a **deliberate revert commit**:
  context windows back to 1M **and the guard's `CLAMP` constant updated in
  the SAME commit** — a reverted clamp with a stale 300K guard would block
  every sync/commit (or force override usage indefinitely, which is exactly
  the drift the guard exists to surface).
- Trigger (pre-committed, owner = weekly report reader): re-read volume or
  LLM call count per compacting session > 2× the regenerated Aug baseline over
  any 3 consecutive days, **or** ≥ 1 `stopReason:"length"` truncation record
  → revert to 1M. The 200K dial is the pre-registered upside if week-2+ shows
  < 1.5x cost reduction over compacting sessions.
- Re-clamping after a revert requires **re-approval** (the same
  human-gated decision as the original clamp).
- **Withdrawal record (2026-09-21).** The 2026-09-18 dial **300K→700K** (#1213,
  PR #1226) is **withdrawn**; the shipped numbers are back at clamp **300K**,
  trigger **~283,616**, `reserveTokens` **16384**, guard `CLAMP` **300000**.
  Reason: the wider window published its own sequencing — *withdraw only after
  the floor fix deploys* — and that condition is now met. The installed
  `pi-ai` carries `MIN_USABLE_MAX_TOKENS = 1024` with
  `clampMaxTokensToContext()` returning `min(maxTokens, 1024)` whenever the
  available budget falls under it (`pi-patch:#1214(b)` — never clamp below a
  usable output budget), so the one mechanism the window was bought for —
  `estimate ≥ contextWindow − 4096` → a single-token `stopReason:"length"`
  turn, silently un-answerable — is closed in code. Against that, the window
  costs roughly **+20% fleet-level model spend, recurring** (trigger
  283,616→650,000; summary cap 13,107→40,000; ceiling re-ingestion ~2.3×).
  **The corpus scan that motivated the wider window, kept here because
  withdrawing the window deleted its old home:** the session corpus carried
  **188 `stopReason:"length"` records across 49 sessions**, in four window
  eras, each sitting at `configured window − ~4,082` — the clamp's own reserve
  (`contextWindow − estimate − 4096`). That is the measurement §7's
  pre-committed trigger fired on; the owner's response to it was the 700K
  re-clamp and then this withdrawal, because the floor fix, not a wider
  window, closes that class.
  **Residual, stated plainly:** it has **not** been verified that the floor fix
  subsumes *every* failure the wider window covered — only the silent-death
  one. The retired regime left **no** truncation records — 0
  `stopReason:"length"` across its session files (2026-09-18..21; measured
  2026-09-21) — so
  `watch-truncation.sh`'s `700K-clamp-era(650-900K)` bucket is **empty**: it
  exists so a record from that era cannot be mislabelled, not because one is
  waiting there. What the era did leave is **compaction** records — 3
  at/above the 650,000 trigger (650,134–650,426) — which put their 2 sessions
  into `fleet-cost-report.sh`'s clamp population for one window. §7's trigger
  above is unchanged.

  **OVERRIDES:** the vendor's full deepseek window (1,000,000) — clamped at
  300,000, because cold re-ingestion at the 1M ceiling is the cost amplifier
  the clamp exists to stop, and the mechanism that once justified widening it
  (the single-token clamp death) is now closed in code.
