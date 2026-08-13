# Issue #209 — Research

**Status:** DRAFT
**Branch:** feat/209-load-aware-fleet
**Date:** 2026-08-12
**Level:** project | **Complexity:** standard | **Team:** organisation-design-team

**Scope:** Load-aware fleet bounds — scale task watchdog / shell-out timeout limits with
system load; suspend background batches during load storms. Supersedes the static
first-message bound from #198 and extends the env-overridable timeout pattern from #196.

**Context (from the issue):** 2026-08-12 redislite bgsave storms (tortoise #1005: load
77–98 on 10 cores) ran with the agent-infra wave: suites 10× slower, 2s git-lookup
timeout flaked (#196), 300s first-message watchdog cut live sub-agents (#198).

---

## 1. CURRENT BOUNDS — task watchdog constants (extensions/builtin-tools/index.ts)

All kill clauses route through **one pure decision function**, `heartbeatKillDecision`
(extensions/builtin-tools/index.ts:711–814), driven by a `HeartbeatDecisionInput`
(created at spawn in `spawnSubAgent`, decision loop every 10s at line 1222–1272).
Precedence is pinned: **tool-stall → stream-stall → silence → first-message → max-dispatch**
(line 759–808; test-pinned at builtin-tools.test.ts:1068).

| Constant | Default | Env override | Clamp | Defined at | Used for |
|---|---|---|---|---|---|
| `FIRST_OUTPUT_TIMEOUT_MS` | 60,000 (60s) | **none — hardcoded** | — | index.ts:1164 | tier-1 "zero-output" kill (startup hang, retryable) |
| `HEARTBEAT_TIMEOUT_MS` (T) | 1,800,000 (30 min) | `TASK_HEARTBEAT_TIMEOUT_MS` | ≥60s | index.ts:1163 | silence clause; preflight `min(L,T)` bound |
| `DEFAULT_STREAM_STALL_MS` (S) | 1,200,000 (20 min) | `TASK_STREAM_STALL_MS` | ≥60s | index.ts:435 | stream-stall clause (no tools, stream idle) |
| `DEFAULT_TOOL_STALL_MS` (L) | 21,600,000 (6h) | `TASK_TOOL_STALL_MS` | ≥60s | index.ts:436 | tool-stall clause (in-flight tool bound) |
| `DEFAULT_FIRST_MESSAGE_MS` (M) | 300,000 (300s) | `TASK_FIRST_MESSAGE_MS` | ≥60s | index.ts:437 | first-message clause (hung provider request, #5926 class) |
| `DEFAULT_MAX_DISPATCH_MS` | 0 (**off**) | `TASK_MAX_DISPATCH_MS` | ≥60s | index.ts:469 | opt-in wall-clock cap markers cannot reset |
| `DEFAULT_EXIT_GRACE_MS` | 120,000 (120s) | `TASK_EXIT_GRACE_MS` | ≥1,000ms | index.ts:269 | tier-3 exit watchdog (stdio EOF but process alive, #153) |
| `DEFAULT_HEARTBEAT_INTERVAL_MS` | 30,000 (30s) | `TASK_HEARTBEAT_INTERVAL_MS` | [5s, 300s] | index.ts:434 | parent `stateFresh` window (child owns its own timer) |
| `DEFAULT_FALLBACK_MODEL` | deepseek-v4-pro | `TASK_FALLBACK_MODEL` | — | index.ts:342 | #152 provider fallback on qwen connection errors |

Env getters follow a uniform pattern — clamped, invalid/absent → default, e.g.:

```ts
// index.ts:464–468
export function getFirstMessageMs(): number {
  return Math.max(60_000, Number(process.env.TASK_FIRST_MESSAGE_MS) || DEFAULT_FIRST_MESSAGE_MS);
}
```

### The toolsInFlight logic — and the first-message gap (the #198 recurrence)

The **silence clause exempts in-flight tools explicitly** (index.ts:774–780):

```ts
  // 3. silence — the legacy byte-silence detector, exempted while a turn is
  //    active with an in-flight tool or fresh stream activity.
  const silenceMs = i.now - i.lastLifeSignAt;
  const exempt =
    stateFresh &&
    st.turnActive &&
    (st.toolsInFlight > 0 || effStreamAge <= i.streamStallMs);
  if (silenceMs > i.heartbeatTimeoutMs && !exempt) {
    return kill("silence-threshold");
  }
```

The **first-message clause does NOT check `toolsInFlight`** (index.ts:785–798) — this is the gap:

```ts
  // 4. first-message — turn running but no message/tool activity ever within
  //    M (hung provider request, #5926 class). Retryable when no real output.
  if (
    stateFresh &&
    st.turnActive &&
    !st.turnSawMessage &&
    !st.turnSawTool &&
    effStreamAge > i.firstMessageMs
  ) {
    return kill("first-message-stall");
  }
```

Why `toolsInFlight > 0` can coexist with `turnSawTool === false` (the mechanism):
`parseHeartbeatLine` latches `turnSawTool` **only** from the tick's `saw_tool` field
(index.ts:581); `tool_start` increments `toolsInFlight` but does **not** latch
`turnSawTool` (index.ts:548–550), and `turn_start` **resets** both flags
(index.ts:555–559):

```ts
    case "tool_start":
      state.toolsInFlight += 1;
      state.everSawWork = true;
      break;
    case "turn_start":
      state.turnActive = true;
      state.everSawWork = true;
      state.turnSawMessage = false;
      state.turnSawTool = false;
      break;
```

So a tool that started (parent counts `toolsInFlight = 1`) but whose
`saw_tool=1` tick was lost/not yet received/not emitted (child blocked, marker
line-buffer drop, preflight tool) leaves `turnSawTool = false`; once `effStreamAge >
M` (300s), **first-message-stall fires while the tool is still in flight** — cutting
a live sub-agent at 300s instead of at the tool-stall bound L=6h. This is the #198
recurrence (align doc documented a live 2026-08-12 cut: 738s stream age vs 300s
bound during a tool-heavy turn). The `resolveUndefined: !i.hasOutput` semantics make
the cut retryable, but retry-under-load compounds the storm.

The child side (`extensions/task-heartbeat.ts`) latches `turnSawTool = true` on
`tool_execution_start` (task-heartbeat.ts:217) and ticks carry `saw_tool` every
`getHeartbeatIntervalMs()` (formatTick at task-heartbeat.ts:116–121; tick() at 159;
setInterval at 182) — the parent's
`turnSawTool` therefore depends on tick delivery, which is exactly what a wedged /
blocked child breaks.

## 2. TASK EXTENSION BOUNDS (extensions/subagent/index.ts)

The separate `task` **extension** (subagent extension, orchestrator-style dispatch)
carries its own bounds — a different code path from builtin-tools' `task` **tool**:

- `DEFAULT_TASK_TIMEOUT_MS = 1_800_000` (30 min) — extensions/subagent/index.ts:239.
- `getTaskTimeoutMs()` env override `SUBAGENT_TASK_TIMEOUT_MS`; **0/negative/NaN → disabled**
  (index.ts:241–249):

```ts
export function getTaskTimeoutMs(raw: string | undefined = process.env.SUBAGENT_TASK_TIMEOUT_MS): number {
	if (raw === undefined || raw.trim() === "") return DEFAULT_TASK_TIMEOUT_MS;
	const n = Number(raw);
	if (!Number.isFinite(n) || n <= 0) return 0;   // backward compat — garbage env must never kill instantly
	return n;
}
```

- Heartbeat: `HEARTBEAT_MS = 30_000` — **hardcoded, no env override** (index.ts:445):
  writes a newline + `emitUpdate()` every 30s to defeat an external silence timeout
  during long tool calls.
- Kill on timeout: `killTree("SIGTERM")` → 5s → SIGKILL (detached process group,
  `SUBAGENT_DETACHED=0` opt-out) — index.ts:455–463 + `shouldThrowOnAbort` semantics.
- **No load-awareness anywhere in this file.** No `os.loadavg`, no load gating, no
  toolsInFlight concept (it has no heartbeat-marker pipeline at all — just stdout
  empty-line heartbeats).

## 3. #196 PATTERN — env-overridable shell-out timeouts

**The #196 fix pattern exists but is NOT merged into agent-infra main.** Commits
`5feefea` ("raise git-lookup timeout 2s → 10s, env-overridable (#196)") and `f50b52b`
("git-lookup stall resilience — 5s cap + one bounded retry in BOTH duplicated copies
(#196)") live on `origin/fix/slack-bridge-git-timeout-196`; `git merge-base --is-ancestor
f50b52b origin/main` → **NO**. The current `main` slack-bridge still has the hardcoded
2s cap:

```ts
// extensions/slack-bridge/index.ts:963
const GIT_REMOTE_TIMEOUT_MS = 2000; // spec: git config lookup, 2s cap
```

used at index.ts:594 (`deriveRepoName`) and index.ts:1006 (`deriveCurrentRepo`).

The #196 pattern (from the unmerged branch) is the canonical "env-overridable,
per-call getter, clamped default" shape:

```ts
/** #196: git-lookup cap for approval-store repo discovery. Default 10s (was 2s) …
 * Env-overridable via GIT_REMOTE_TIMEOUT_MS; read per call … Invalid/absent → 10000. */
export function gitRemoteTimeoutMs(): number {
  const n = parseInt(process.env.GIT_REMOTE_TIMEOUT_MS ?? "10000", 10);
  return Number.isInteger(n) && n > 0 ? n : 10000;
}
```
(extensions/slack-bridge/index.ts on branch fix/slack-bridge-git-timeout-196; test
coverage in slack-bridge.test.ts: default / env / invalid / non-positive fallback
assertions.)

### Full inventory of shell-out (git/exec) timeouts in agent-infra

| Location | Constant / literal | Default | Env override | Notes |
|---|---|---|---|---|
| extensions/slack-bridge/index.ts:963,594,1006 | `GIT_REMOTE_TIMEOUT_MS` | 2,000ms | **none on main** (getter on #196 branch) | `git remote get-url origin` / `git config --get remote.origin.url` |
| extensions/slack-bridge/index.ts:964,1101 | `GH_API_TIMEOUT_MS` | 15,000ms | none | `gh api` call cap |
| extensions/shared/tree-kill.ts:18,38,44 | `EXEC_TIMEOUT_MS` | 2,000ms | none | `pgrep -P` / `ps -axo` during treeKill |
| extensions/repo-freshness.ts:35,36,220,262,271 | `FETCH_TIMEOUT_MS` / `PULL_TIMEOUT_MS` | 30,000 / 120,000ms | none | git fetch / ff-only pull |
| extensions/repo-freshness.ts:65 | `git()` default | 10,000ms | none | rev-parse etc. |
| extensions/main-worktree-guard/classify-git.mjs:64,101,127,144,152,181 | `timeout: 5000` | 5,000ms | none | 6 git lookups (rev-parse, worktree list, branch) |
| extensions/main-worktree-guard/index.ts:64,208,246 | `timeout: 5000` | 5,000ms | none | 3 git lookups |
| extensions/sequence-enforcer/index.ts:262,501,502 | `timeout: 5000` | 5,000ms | none | cold Python import + git rev-parse lookups |
| extensions/skill-registry.ts:44 | `timeout: 5000` | 5,000ms | none | git lookup |
| extensions/loop-enforcer/goal.ts:31,38 | `timeout: 5000` | 5,000ms | none | git lookups |
| extensions/verification-gate/index.ts:174,186,199 | `timeout: 3000/5000` | 3–5,000ms | none | checks |
| extensions/auto-sync.ts:78,113 | `timeout: 30_000 / 180_000` | 30s / 180s | none | fetch + sync.sh |
| extensions/subagent/index.ts:445 | `HEARTBEAT_MS` | 30,000ms | none | stdout heartbeat interval |

The only shell-out timeouts with env overrides anywhere in the tree are the
`TASK_*` watchdog bounds (§1) and `SUBAGENT_TASK_TIMEOUT_MS` (§2). **Every git
lookup is hardcoded** — the #196 class of flake (2s/5s caps under load) is pervasive,
not isolated. `scripts/` shell scripts use `docker exec`/plain commands with no
timeout guards at all (daily-backup.sh polls LASTSAVE with a 60s loop but the
docker calls themselves are unguarded).

## 4. BATCH SCHEDULING SURFACE

**No load gating exists anywhere.** Zero references to `loadavg` / `os.loadavg()` /
`/proc/loadavg` / `getloadavg` in agent-infra extensions/, scripts/, bin/, or in the
swarm repo's scripts (grep across both repos + all tortoise worktrees).

### scripts/cron-quality-gates.sh (195 lines)

Two subcommands, **dispatched by pipeline skills, not by a crontab**:

```bash
# Dispatched by skills/test-routing (Skill Registry) as:
#   scripts/cron-quality-gates.sh arch      # (#6463)
#   scripts/cron-quality-gates.sh mutation  # (#6460)
```

- `arch` — verify every `scripts/<name>` referenced in `skills/**/SKILL.md` resolves
  (missing scripts = gate silently no-ops, issue #100).
- `mutation` — run every `extensions/*/test.mjs`; reject assertion-free tests.
- `set -euo pipefail`, exit codes 0/1/2. **No load check, no retry, no deferral.**
- scheduling surface: skills/test-routing/SKILL.md:81–82 and
  skills/test-debt-gate/SKILL.md:178 ("Nightly cron / on-demand" — but no crontab
  entry and no GH Actions `schedule:` cron exist in this repo; `.github/workflows/`
  has ci, node-ci, python-ci, docs-ci, pipeline-compliance — none with `schedule:`).

### scripts/daily-backup.sh (168 lines)

The **daily BGSAVE trigger** — directly relevant to the storm class:

```bash
# ── Step 1: Trigger BGSAVE ──────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Triggering BGSAVE on $CONTAINER..."
docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" BGSAVE > /dev/null
```

- Polls `INFO persistence` `rdb_bgsave_in_progress` for up to 30×2s, fatal-exits if
  not done (P1(a) guard).
- **No load gating** — it triggers BGSAVE unconditionally. Under the #1005 leak class,
  this is the *igniter* of a storm, and its own polling loop competes for CPU.

### Other surfaces

- **bin/agent-infra.js** — bootstrap CLI only (init/update/check symlinks); no cron
  wrappers, no scheduling (verified: no cron/daily-backup/quality-gates references).
- **wt-291 gated-rerun script — NOT in agent-infra and NOT found in any current
  checkout.** The issue's "wt-291 gated-rerun script already waits for load<25" cannot
  be located: grep for `load < 25`, `gated-rerun`, `gated_rerun`, `getloadavg` across
  /Users/danielospina/Documents/GitHub/tortoise (main + all .worktrees), wt-291, and
  swarm returns only docs/plans/2026-08-07-p1-bugs-batch1.md (a *mention* of
  "loadavg ~26" in a test-run note, not a script). **Provenance must be pinned at
  Scope** — the script is either uncommitted/ephemeral, on a different host, or in a
  worktree not currently checked out; "promote to shared helper" is therefore a
  cross-repo *extraction*, not a move.
- **swarm** repo: `operations/coordination/state_machine.py:185` uses a "batch"
  ready-set in its scheduler but has **no load awareness**; no wave/cron wrapper with
  load gating found.

## 5. LOAD SIGNAL — os.loadavg()

- `grep -rn "loadavg"` across extensions/, scripts/, bin/, skills/ → **zero hits**.
- Node ≥ 18 ships `os.loadavg()` (returns [1-min, 5-min, 15-min]) on macOS and Linux
  — both fleet platforms; no new deps, no native modules. Same-host sub-agents share
  the parent's host, so loadavg reflects the contention they experience (true for the
  2026-08-12 host-level storm; blind to cgroup quotas / VM steal — document at Scope).
- **Feasibility of a shared helper is high**: a pure `load-gate` module (e.g.
  `scripts/load-gate.mjs` or `extensions/shared/load-gate.ts`) exposing
  `readLoad1(): number` (default `os.loadavg()[0]`) + `shouldSuspend(load1, cfg)` with
  an **injectable load getter** makes the "load 60+" target a unit test, not a CI load
  generator. Precedent for injectable pure helpers: extensions/shared/retry.ts
  (circuit breaker with injectable timers), tree-kill.ts (injectable kill fn), and the
  `dinput()` test factory (§6). Note `os.loadavg()` is real host signal — tests MUST
  inject, never read real load.
- Threshold semantics: wt-291's "< 25" was load 25 on 10 cores (2.5×). loadavg is raw,
  not per-core — a fixed constant means different things on different hosts; default +
  env override + hysteresis (suspend at `LOAD_SUSPEND_THRESHOLD`, resume at a lower
  `LOAD_RESUME_THRESHOLD`) are required to avoid single-sample thrash.

## 6. TEST PRECEDENT — how builtin-tools tests inject state

The heartbeat tests use a **`dinput()` factory** that merges partial overrides over a
canonical `HeartbeatDecisionInput`, with `HeartbeatState` built via
`createHeartbeatState()` then mutated field-by-field (builtin-tools.test.ts:936–950):

```ts
function dinput(over: Partial<HeartbeatDecisionInput> & { state?: HeartbeatState } = {}): HeartbeatDecisionInput {
  return {
    now: 0, startedAt: 0, lastLifeSignAt: 0, hasOutput: true,
    state: createHeartbeatState(),
    heartbeatTimeoutMs: T, firstOutputTimeoutMs: 60_000,
    streamStallMs: S, toolStallMs: L, firstMessageMs: M,
    intervalMs: INT, maxDispatchMs: 0,
    ...over,
  };
}
```

- E1 (builtin-tools.test.ts:1002): "turn + tool in flight with fresh markers →
  exempt from silence kill" — `st.toolsInFlight = 1` proves the silence-exemption test.
- E13 (builtin-tools.test.ts:1098): first-message-stall with `turnSawMessage=false,
  turnSawTool=false`, then "saw_tool latched → exempt". **E13 never sets
  `toolsInFlight`** — the gap case (`toolsInFlight=1 && turnSawTool=false`) is
  currently untested and would fire first-message-stall today.
- Env overrides are exercised by set/restore `process.env.*` with `try/finally`
  (e.g. TASK_EXIT_GRACE_MS at test lines 465–496).

**Load can be injected the same way**: add a `loadavg` (or `load1`) field to
`HeartbeatDecisionInput` (default 0 = no load, preserving all existing tests) and a
corresponding `loadThresholds` to the spawn-side getters; the T1 target test becomes
`heartbeatKillDecision(dinput({ loadavg: 60, ... }))` → first-message bound extended /
not cut, and `dinput({ loadavg: 0 })` → unchanged legacy behavior. The batch-helper
test injects the load getter (`loadgate({ getLoad1: () => 60 })`). No real-load CI
generator required.

---

## Implications for Scope

1. **Load signal + threshold + hysteresis (align condition 1).** Pin `os.loadavg()[0]`
   (1-min) via an injectable getter in a shared helper (candidate `extensions/shared/`
   — pattern precedent: retry.ts/tree-kill.ts; `scripts/load-gate.mjs` if only bash
   cron wrappers consume it). Defaults: `LOAD_SUSPEND_THRESHOLD` + distinct
   `LOAD_RESUME_THRESHOLD` (hysteresis) with env overrides; document per-core
   semantics (wt-291's <25 was 2.5× on 10 cores) and the cgroup/VM-steal blindness.
2. **Supersede semantics vs #196/#198 (align condition 1):** state explicitly that the
   first-message clause gains a `toolsInFlight > 0` exemption AND a load-scaled bound
   (e.g. `M × scale(load1)`), layered on top of #198's static bound (never below it),
   and that the #196 env-overridable getter pattern is applied to the *other*
   hardcoded shell-out caps (§3 inventory — slack-bridge on main still hardcodes 2s).
   Decide whether to land the unmerged `fix/slack-bridge-git-timeout-196` branch first
   or fold its pattern into this issue.
3. **Helper home + resume mechanism (align condition 2):** the wt-291 gated-rerun
   script is **not found in any checkout** — Scope must confirm provenance (tortoise
   issue #291 artifact?) or treat "promote to shared helper" as a fresh extract
   specification (exit-with-load vs. poll-and-defer; **defer must persist + resume**,
   or batches silently never run — worse than running under load).
4. **Scheduling surface is skills + scripts, not cron:** agent-infra has no crontab
   and no GH Actions `schedule:`; background waves are skill-dispatched
   (test-routing/test-debt-gate → cron-quality-gates.sh) and `daily-backup.sh` (the
   BGSAVE igniter). A load-gated wrapper would wrap these entry points; the swarm
   scheduler (`operations/coordination/state_machine.py`) is the other consumer
   surface, owned by the swarm repo.
5. **Testability without real load:** unit tests via injected load into
   `heartbeatKillDecision`/`dinput` (T1) and an injected getter into the helper (T2) —
   no CI load generator. New regression tests needed: (a) `toolsInFlight=1 &&
   turnSawTool=false && streamAge>M` → NOT cut (currently cut — E13 gap), (b) load-scaled
   first-message bound, (c) helper suspend/resume with hysteresis.
6. **Observability:** log bound extensions (e.g. `[task] first-message bound 300s → 900s
   (loadavg 60)`) and suspension events so T2 is verifiable in production without
   waiting for a real storm; reuse the existing `console.error("[task] …")` / log-line
   conventions (§1 kill headlines at index.ts:1260–1270).
