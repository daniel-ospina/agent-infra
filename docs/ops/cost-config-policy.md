---
title: "Cost-Config Policy — deepseek context clamp @800K (was @300K), drift guard (#341) & bounded retry/hang contract (#1088)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-341, issue-1088, issue-1078, issue-1110, issue-1227, issue-1316, pi-config, cost-config-policy
---

# Cost-Config Policy — deepseek context clamp @800K & drift guard (#341)

One place that pins the agent-infra fleet's **token-cost guardrail contract**:
what the shipped 800K deepseek context clamp means, why the guard's classes
are BLOCK-vs-WARN, and how a deliberate revert (rollback) is done. Delivered by
issue #341 PR-A (config-as-authority); scope/plan:
`docs/scoping/2026-08-28-issue-341-token-cost-driver-solution-diverge.md` +
`docs/plans/2026-08-28-issue-341-session-lifecycle.md`.

> ⛔ **LIVE GEOMETRY — clamp 800,000, compaction trigger 783,616**
> (`800,000 − 16,384`), owner decision 2026-10-31, recorded in §7.1 with its
> `OVERRIDES:` line. **Every `300K` / `283,616` / `300000` figure still quoted
> below is HISTORY**, kept because it dates the era it describes: §1's framing,
> §5's class narrative, §7's withdrawal record and the store/alias history all
> predate the move. A maintainer enforcing a "300K contract" from this page
> would be *reversing* §7.1's decision — read live numbers from the code
> (`CLAMP` in `scripts/check-cost-config.sh`, `--print-regime-floor` on both
> instruments), never from historical prose. Re-clamping to 300K requires
> re-approval (§7.1).

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
clamp **800K**, compaction trigger **783,616** (= 800,000 − 16,384
`reserveTokens`), `keepRecentTokens` **12000**. The 800K window is the owner
decision of 2026-10-31 (§7.1), which SUPERSEDED the 300K clamp dialed
400K→300K by #476's Compaction fix / PR #511 (commit `3211574`, 2026-09-05:
pi-config/models.json 23 deepseek entries 400000→300000, settings.json
`keepRecentTokens` 20000→12000, and the guard `CLAMP` 400000→300000). The
400K-selected-at-#341 context in §3 is history; the pin below is the shipped
**800K** regime, and §7.1 owns any further move.

---

## 1. The conditioned savings claim (honest framing)

- The clamp only changes behavior for sessions whose context crosses
  **~783.6K** (the shipped 800K-clamp trigger, 783,616) — **marathon
  sessions**. The 85–87% cache-share figure is marathon-derived;
  the fleet median cache-share is 30%. (Under the retired 300K clamp this
  figure was ~283.6K; the *shape* of the argument is unchanged, its window
  is not.)
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
  - `models.json` drift (any deepseek-served id > 800K), **or** a
    deepseek-served entry whose `contextWindow` is absent, non-numeric, or not
    equal to `800000` (the geometry anchor below) → **BLOCK (exit 1)**.
  - `settings.json` drift (compaction block: enabled + `reserveTokens` **16384**
    (the reviewed value — asserted independently, see the `#1227` note below) +
    a geometry check that `800000 − reserveTokens` equals the fleet regime floor
    the instruments band on (READ from `scripts/fleet-cost-report.sh` and
    `scripts/watch-truncation.sh` via each instrument's `--print-regime-floor`,
    never restated in the guard), **anchored** on
    every deepseek-served `contextWindow` EQUALLING `800000`: the models check
    above is only an upper bound (`≤ CLAMP`), so without that anchor a window
    *below* the ceiling left the real trigger at `window − reserve` while the
    geometry leg certified `800000 − reserve` — a false PASS, closed 2026-09-22
    (`scripts/check-cost-config.sh`'s `check_models_window_anchor`). The anchor
    is carried on the **shipped** `models.json` only (the live file stays
    WARN-class, and its geometry is not certified); it treats an **absent or
    non-numeric** `contextWindow` as a violation rather than a skip — pi resolves
    an absent one to `128000` (a `providers.*.models[]` row) or to the
    4h-refreshed catalog (a `modelOverrides` value), and rejects the *whole*
    file on a non-numeric one, leaving an empty provider map. The walk is
    **per-entry and does not model same-file inheritance**, so a `models[]` row
    that omits the window while the same provider's `modelOverrides[<id>]`
    supplies `contextWindow: 800000` is refused too, and the message says so
    rather than inventing a cause: reproducing pi's per-provider override
    lookup inside the guard risks a wrong answer, and a wrong answer here is a
    false PASS, which is worse than the false block. It also refuses
    with exit 2 when **no** deepseek-served entry is recognised at all, because
    "every deepseek-served window equals the anchor" over an empty set asserts
    nothing (its green line names the entry count it checked); and
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
  - **The reserve is pinned AND derived — both legs are required** (#1316,
    `#1227`). The independent leg (reserve == 16384) is the only constraint that
    survives a coordinated move of the window and the reserve; the derived leg
    (`CLAMP − reserve ==` the floor read from the two instruments) catches a
    `CLAMP` drift or an instrument drift. Removing the independent leg made the
    guard read green on `contextWindow 1000000 / reserveTokens 216384`, which
    preserves the 783616 trigger while inflating the summarization cap to
    `0.8 × 216384` — the reserve-inflation workaround the recorded owner
    directive on #1227 forbids.
  - **Fleet regime floor unreadable by execution, or inconsistent → BLOCK
    (exit 2)** (#1342): the guard asks EACH instrument for its floor by
    executing `<instrument> --print-regime-floor` (with `FLEET_REGIME_TB`
    unset), mirroring `patch-pi-retry.sh --cap`; a non-zero exit, an empty
    answer, a non-integer answer, or a digit literal too long for bash's int64
    arithmetic (`-ge` on such a value errors, which an `if` reads as a coherent
    band) is fail-closed, and the two floors must agree. The unset is what makes
    this leg certify the **committed default**, deliberately blind to the
    operator's ambient `FLEET_REGIME_TB`: the guard must not be moved off the
    committed floor by the environment it runs in. It does **not** constrain a
    report the weekly driver runs **with** the override — that run still bands at
    the override while the guard certifies the committed default; because the
    override is a documented "tests + tuning" seam, that divergence is by design
    rather than a false PASS this leg prevents. (Without the unset the guard
    would instead read the ambient value, disagree with the watcher, and
    false-BLOCK.) The watcher's owner-facing bucket LABEL is not an anchor — a
    correct relabel no longer blocks the pre-committed rollback. The watcher OWNS
    its band and refuses to print a floor when the band is empty or inverted
    (`floor >= ceiling`), when a band constant is not a plain integer or is
    outside the representable range, or when the 1M-drift floor lies strictly
    inside the current bucket (`floor < drift < ceiling`, which would attribute
    records at/above the drift floor to the current clamp regime) — any of which
    would certify a floor no record can reach or mis-triage the records it can.
    The **same exit-2 class** covers a
    `models.json` in which no deepseek-served entry is recognised — a geometry
    anchor with nothing to assert must not read green. This class is **not**
    covered by `COST_CLAMP_OVERRIDE=1`.
  - **Missing shipped `models.json` / `settings.json` → BLOCK (exit 1)**:
    deletion of the clamp authority is itself terminal drift (clamp gone while
    CI stays green). Store-class and live-dir-missing (first-install) stay
    WARN.
  - `models-store.json` drift → **WARN** (a hard red would break auto-sync the
    moment pi's refresh legitimately reverts the store — the verifier P0).
    The alert path is the **weekly report** (`fleet-cost-report.sh`, PR-B) and
    the **tripwire**: any compaction record with `tokensBefore ≥ 900K`
    (0.9 × 1M — NOT 0.9 × 800K, which sits at 720K — below the 783,616
    trigger — and would misclassify every post-clamp compaction as a ceiling).
    ⛔ At the 800K geometry this tripwire reads as **ambiguous**, not as
    "1M-era": 900K is only 116,384 tokens past the trigger and compaction runs
    on `agent_end`, so a clamped session's own mid-turn overrun can reach it
    (§7.1's stated band). Attribute such a record by its session's RESOLVED
    window before concluding the clamp is not live.
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
- **The revert must move the whole geometry, or the escape does not work
  (#1316).** Since the guard asserts both `CLAMP − reserveTokens ==` the floor
  the two instruments band on **and** `reserveTokens ==` the reviewed 16384,
  a 1M revert updates, in one commit: `contextWindow` in `models.json`, the
  guard's `CLAMP`, and the floor in **both** instruments —
  `scripts/fleet-cost-report.sh` (`FLEET_REGIME_TB:-<n>`) and
  `scripts/watch-truncation.sh`'s `REGIME_TB_FLOOR` band constant (with its
  `REGIME_TB_ERA_CEIL` bound). `settings.json`'s
  `reserveTokens` **stays at the reviewed 16384**: the 1M geometry only needs
  the window, the guard clamp, and the two floors to move, and moving the
  reserve is exactly the inflation the `#1227` directive forbids. If the
  reserve ever legitimately moves, the guard's `REVIEWED_RESERVE` must be
  updated in the same commit. The guard reads both floors by execution
  (#1342), so the watcher's bucket LABEL is display text and needs no
  coordination with the guard. Flipping only `CLAMP` trips a **settings-class** block that
  `COST_CLAMP_OVERRIDE=1` does **not** silence — it covers the `models.json`
  clamp block only — so the guard must be green *before* the revert commit.
  `watch-truncation.sh`'s printed procedure states the same list.
- Trigger (pre-committed, owner = weekly report reader): re-read volume or
  LLM call count per compacting session > 2× the regenerated Aug baseline over
  any 3 consecutive days, **or** ≥ 1 `stopReason:"length"` truncation record
  → revert to 1M. The 200K dial is the pre-registered upside if week-2+ shows
  < 1.5x cost reduction over compacting sessions.
- Re-clamping after a revert requires **re-approval** (the same
  human-gated decision as the original clamp).
- **Withdrawal record (2026-09-21).** The 2026-09-18 dial **300K→700K** (#1213,
  PR #1226) is **withdrawn**; at that date the shipped numbers went back to
  clamp **300K**, trigger **~283,616**, `reserveTokens` **16384**, guard
  `CLAMP` **300000** (the geometry was moved again on 2026-10-31 — see §7.1).
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
  `watch-truncation.sh`'s retired-era bucket (formerly
  `700K-clamp-era(650-900K)`) is **empty at this geometry**: it exists so a
  record from that era cannot be mislabelled, not because one is waiting
  there — and with `REGIME_TB_ERA_CEIL == REGIME_TB_DRIFT_FLOOR == 900000` the
  arm is empty BY CONSTRUCTION, so a 660K record now buckets `small-window`.
  What the era did leave is **compaction** records — 3
  at/above the 650,000 trigger (650,134–650,426) — which put their 2 sessions
  into `fleet-cost-report.sh`'s clamp population for one window. §7's trigger
  above is unchanged.

  **OVERRIDES:** the vendor's full deepseek window (1,000,000) — clamped at
  300,000, because cold re-ingestion at the 1M ceiling is the cost amplifier
  the clamp exists to stop, and the mechanism that once justified widening it
  (the single-token clamp death) is now closed in code.
  ⛔ **SUPERSEDED 2026-10-31 — see the decision below. Do not "restore" 300K.**

### 7.1 2026-10-31 decision — the clamp moves 300K → 800K (owner)

**Decision (owner, 2026-10-31, verbatim):** the 300K window *"was done to
reduce costs but I feel that context loss in the orchestrator is costing us
way more"* → **800,000 tokens**, with the whole geometry following it.

**What moved (one commit, per #1316):** every deepseek-served `contextWindow`
in `models.json` 300000 → 800000 (`maxTokens` 384000 unchanged — it is an
output cap, not the window); **the same 10 deepseek-served rows in the shipped
`pi-bootstrap/pi-config/models-store.json`** — `deepseek:{v4-flash,
v4-flash-vision-exp, v4-pro}`, `openrouter:deepseek/deepseek-{v4-flash,
v4-flash-0731, v4-pro, ~deepseek-v4-flash-latest}`,
`qwen-token-plan:deepseek-{v4-flash,v4-flash-0731,v4-pro}` — plus that file's
`checkedAt` bump, which is what makes the migration load-bearing rather than
cosmetic (`pi-bootstrap/setup.sh`'s `merge_models_store` does
`merged = {**dst, **src}` and lets the NEWER `checkedAt` win per provider, so a
bumped snapshot carrying the OLD window would REVERT those 10 entries on the
next install); the guard's `CLAMP` 300000 → 800000; the regime
floor in BOTH instruments 283616 → **783616**; `watch-truncation.sh`'s band
constants (`REGIME_TB_FLOOR` → 783616, `REGIME_TB_ERA_CEIL` → 900000, moved
together as this section requires); the two literal `/300k` footer parsers
(`orchestrator-heartbeat.sh`, `safe-send.sh`) now also accept `/800k`, keeping
`/300k` for historical transcripts. `settings.json`'s `reserveTokens` **stays**
at the reviewed 16384 — the #1227 directive is untouched.

⛔ **Why the shipped STORE rows are on this list (and why a guard cannot see
them).** The store is
the `WARN`-class defense-in-depth surface (§5) and pi's 4h refresh overwrites it,
which is why an earlier draft of this section described its change as
"`checkedAt` only". That description was wrong and is worth recording: the 10
window rows moved WITH it, and they have to. `pi-bootstrap/setup.sh`'s
`merge_models_store` does `merged = {**dst, **src}` and then keeps the provider
block whose `checkedAt` is NEWER (`setup.sh:155-166`), so bumping the shipped
snapshot's `checkedAt` while leaving `300000` in it makes the OLD window WIN over
a live 800K one — every install from that snapshot reverts the geometry. Nothing
would say so: the guard asserts only an UPPER bound (`deepseek-served $v >
${CLAMP}` → block/warn, `check-cost-config.sh:591`), and `300000 ≤ 800000`
prints `✅`. A future geometry move migrates these same rows, or it does not
bump `checkedAt`.

**Trigger arithmetic:** `contextTokens > contextWindow − reserveTokens`
(pi `core/compaction/compaction.js`: `shouldCompact`), so
**800,000 − 16,384 = 783,616**. No new knob was introduced.

**Consequence the reader must also know (summarization budget).** pi caps a
compaction summary at `floor(0.8 × reserveTokens)` output tokens
(`core/compaction/compaction.js`), which is **13,107 tokens — unchanged**,
because `reserveTokens` stays 16,384; `keepRecentTokens` also stays 12,000. The
volume compressed into each summary therefore goes from ≤ ~288K tokens (300K
window) to ≤ ~788K — a **~2.7× larger context loss per summary**. This is the
one mechanism by which the change can lose context, and it is an **accepted
trade**, not an oversight: it is bought for the wider window. Making the
summarizer budget scale with the window is a SEPARATE decision — the `#1227`
directive forbids moving `reserveTokens` as a workaround, so it needs its own
ruling (this `OVERRIDES:` covers the window, not the reserve).

**Why this does not reverse §7's withdrawal on its own terms.** The 2026-09-21
withdrawal rested on a *cost* argument (≈+20% recurring fleet spend) against a
*hazard* that code now covers (`MIN_USABLE_MAX_TOKENS = 1024`, pi-patch
#1214(b)). It did not establish 300K as the right window; it declined to pay
for a hazard fix with tokens. This decision re-prices the same trade from the
other side — context loss in the orchestrator outweighs the spend — which is
the owner's call to make, made explicitly, with the number stated.

**Consequence the reader must know (mid-turn band).** Compaction is checked on
`agent_end`, so a long multi-tool turn can pass the trigger before it is seen.
Under the 300K clamp that band was ~283.6K–300K; it is now **~783.6K–800K**,
and a session can overrun past 800K toward the provider's real 1,000,000
before the provider rejects it. `watch-truncation.sh` fires on the FIRST
`stopReason:"length"` record — the band constants above describe the NEW
regime, so a firing record in 783.6K–900K is this geometry's own overrun,
while records below the floor now also contain the retired eras (400K-era
383–406K, 700K-era 650–700K) and are not evidence about this clamp. Records
**at/above the 900K drift floor are AMBIGUOUS**, not "1M-era": 900K is only
116,384 tokens past this trigger, so a clamped session's own overrun can land
there — attribute such a record by its session's RESOLVED window.

**Sessions mid-flight:** a running `pi` session keeps the context window it
resolved at start; the new window applies when the session restarts. Nothing
live is retroactively resized, and nothing must be killed for this to hold.

**OVERRIDES:** the 300K §7 clamp and its own `OVERRIDES` line (window clamped
at 300,000 against the vendor's 1,000,000, on the cold-re-ingestion cost
argument) — replaced by the owner's 2026-10-31 ruling that orchestrator
context loss costs more than the re-ingestion spend; 800,000 remains inside
the provider's real 1,000,000 window. Re-clamping to 300K again requires
re-approval, exactly as this section already required.
