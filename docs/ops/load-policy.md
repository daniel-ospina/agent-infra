---
title: "Fleet Load Policy — load-aware bounds & batch suspension (#209)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, builtin-tools, fleet
---

# Fleet Load Policy — load-aware bounds & batch suspension (#209)

One place that pins the agent-infra fleet's load policy so operators, skills,
and future consumers (incl. swarm's `state_machine.py`) share the same
contract. Delivered by issue #209 (2026-08-12); scope/plan:
`docs/plans/2026-08-12-issue-209-scope.md` + `-plan.md`.

**The problem class:** under load storms (redislite BGSAVE bursts, builds, git
clones, other batches — observed 2026-08-12: load 77–98 on 10 cores), static
watchdog bounds cut live sub-agents and unconditional batch scripts compound
the load. The fix: watchdog bounds **scale** with load (never shrink), and
background batches **defer** under pre-existing load with a loud re-invoke
contract.

---

## 1. Signal — `os.loadavg()[0]` (1-min load average)

- Read via injectable getters on both consumers: `getLoad1()` in
  `extensions/builtin-tools/index.ts` (test seam `__setGetLoad1`), `readLoad1()`
  in `scripts/load-gate.mjs` (CLI tests inject through `run()`'s `deps`).
- **1-min exponential average** — trailing by design; supports hysteresis (never
  trust a single sample).
- **I/O-inclusive** — loadavg includes tasks waiting on I/O, not just CPU
  runnable. This makes it *sensitive to exactly the BGSAVE-storm class* this
  policy targets (an I/O-heavy save storm raises it).
- **Accepted blindness (same-host fleet):** loadavg is host-wide — a
  quota-capped container can be CPU-starved while loadavg reads low; a
  neighbor's storm can raise loadavg while this host is idle; VM steal
  inflates it. The fleet is same-host (sub-agents are child processes of the
  pi host; batch scripts run on the same host), so these are accepted and
  documented, not blockers.
- **macOS (Darwin) semantics:** loadavg counts *threads* — idle systems can
  show load > 1.0 and multi-threaded workloads double-count. Per-core readings
  run higher on macOS than Linux; defaults are calibrated to Linux. Spurious
  **suspension** is the safe direction (deferrals are loud and resumable) — set
  per-host env thresholds if macOS hosts defer too eagerly.

## 2. Thresholds — per-core normalized + hysteresis band

Defaults are per-core so a fixed constant means the same thing on different
hosts, anchored to the wt-291 documented operating point (load ~25 on 10
cores ≈ 2.5×/core):

| Threshold | Default | Rule |
|---|---|---|
| `LOAD_SUSPEND_THRESHOLD` | `2.5 × cores` (10-core: 25) | suspend batches at **≥** this. Does **not** drive the watchdog — its bands are fixed literals 8/16 (#1073, see §6) |
| `LOAD_RESUME_THRESHOLD` | `1.5 × cores` (10-core: 15) | resume only **below** this (40% hysteresis band) |
| `TASK_LOAD_SCALE_START` | `1.5 × cores` (10-core: 15) | **inert for the watchdog — read by nothing (#1073)**; the watchdog's scale bands are fixed at 8/16 (see §6) |
| `TASK_LOAD_SCALE_MAX` | `3` | **inert for the watchdog — read by nothing (#1073)**; the watchdog's multiplier is fixed at 3 (see §6) |

**Hysteresis:** a batch that defers waits until load drops **below** the resume
threshold — a single-sample dip between suspend and resume never thrash-resumes
(CLI: plain `check` gates on `shouldSuspend`; `check --deferred` gates on
`shouldResume`).

## 3. Env var table (the #209 contract vocabulary)

| Env | Default | Consumer | Meaning |
|---|---|---|---|
| `LOAD_SUSPEND_THRESHOLD` | `2.5 × os.cpus().length` (10-core: 25) | load-gate.mjs (the watchdog reads none of it — #1073) | suspend batches at ≥ this; not a watchdog scale input |
| `LOAD_RESUME_THRESHOLD` | `1.5 × os.cpus().length` (10-core: 15) | load-gate.mjs | resume only below this (hysteresis band) |
| `TASK_LOAD_SCALE_START` | `1.5 × os.cpus().length` (10-core: 15) | — read by nothing (#1073) | documented as the watchdog scale point; `loadScaledBound` does not read it (bands are fixed at 8/16) |
| `TASK_LOAD_SCALE_MAX` | `3` | — read by nothing (#1073) | documented as the watchdog multiplier cap; `loadScaledBound` hardcodes 3 |
| `TASK_HEARTBEAT_CUT_GAP_MS` | derived `1.25 ×` tick interval (`37.5s` at the 30s default), floor `15_000` | builtin-tools cut clause | marker-gap cut deadline. **An explicit value is honoured VERBATIM and never load-rescaled** — only the derived default is scaled (#1070; see §6) |
| `LOAD_GATE_MAX_WAIT_MIN` | `10` | wrappers (bounded poll) | minutes to poll before exit 3; `0` = no poll (deterministic defer for tests) |
| `LOAD_GATE_FORCE` | unset | load-gate.mjs / wrappers | `1` bypasses the gate (`--force` flag sets it) |
| `TASK_FIRST_OUTPUT_TIMEOUT_MS` | `60_000` | builtin-tools tier-1 | first-output bound (NOT load-scaled) |
| `GIT_REMOTE_TIMEOUT_MS` | load-scaled base `5_000` (x1/2/3 by loadavg tier; `TASK_LOAD_SCALE_OFF=1` → `5_000`) | slack-bridge `gitRemoteTimeoutMs()` | git config lookup cap (#196 fold, #232) |
| `TREE_KILL_EXEC_TIMEOUT_MS` | `5_000` | tree-kill `execTimeoutMs()` | pgrep/ps cap on the kill path (#196 fold) |
| `PROCESS_SWEEP_EXEC_TIMEOUT_MS` | `5_000` | process-sweep `sweepExecTimeoutMs()` | pgrep/ps cap on the settle-path sweep + the own-pgid probe (#1074). Aligned with `TREE_KILL_EXEC_TIMEOUT_MS` for the same binaries; the override exists so a test can force a deterministic probe timeout with a PATH shim |

**One-line ordering-clamp note:** the watchdog has no scale config to order —
its bands are fixed literals and it reads **none** of `TASK_LOAD_SCALE_START`,
`TASK_LOAD_SCALE_MAX` or `LOAD_SUSPEND_THRESHOLD` (#1073); `TASK_LOAD_SCALE_OFF=1`
is its only scale input. `load-gate` clamps `resume > suspend` down to `suspend`
(safe direction; preserves the `LOAD_SUSPEND_THRESHOLD=0` always-defer hook). Validity: absent/empty/
non-finite/negative → default; `0` is **valid** for suspend/resume/maxWaitMin
(the deterministic-defer test hook).

## 4. Defer/resume contract (batches)

A deferral is a **promise to re-run**, never a silent skip.

1. **Entry gate** — wrapper runs `node scripts/load-gate.mjs check --json`
   (rule = `shouldSuspend`); exit 0 → proceed, exit 3 → suspended.
2. **Bounded poll** — wrapper re-checks with `check --deferred` every 60s up to
   `LOAD_GATE_MAX_WAIT_MIN` (default 10; `0` = no poll). The `--deferred` mode
   gates on `shouldResume` — a deferred batch stays deferred until load drops
   **below** resume (no single-sample-dip thrash-resume).
3. **Exit-3 re-invoke contract** — after the poll cap the wrapper exits 3 with a
   loud log. The invoker MUST re-invoke (pipeline skills re-dispatch; see
   residuals for daily-backup's unknown invoker). Exit 3 is distinct from
   0/1/2 so invokers cannot mistake it for success.
4. **Mid-run re-check (gating is not entry-only)** — wrappers poll `check`
   inside their run loops (at most once per 60s) and abort with exit 3 + a loud
   defer log if load crosses suspend mid-run.
   - **cron-quality-gates.sh:** re-check inside the arch scan loop and the
     mutation test loop; re-invoke is idempotent (re-scan / re-run tests).
   - **daily-backup.sh:** the mid-run re-check guards the **pre-trigger steps
     ONLY**. BGSAVE fires before the LASTSAVE poll loop; once in flight,
     exit-3's "did NOT run; re-invoke" contract is **false** — a re-invoke
     would trigger a SECOND BGSAVE (a storm igniter under load). After the
     trigger the script completes its wait (aborting saves nothing). Pre-trigger
     abort log (round-2 F6 wording):
     `[load-gate] DEFERRED — partial: BGSAVE may have run; re-invoke to complete copy`.
     Post-trigger, only an optional warn-log fires:
     `[load-gate] WARN — load M ≥ suspend N during BGSAVE wait; completing (aborting would not save the in-flight save)`.
     Note BGSAVE is itself a storm igniter — the gate defers only under
     *pre-existing* load.
   - Any future abort-after-trigger semantics must use **exit 4** ("BGSAVE ran;
     remaining steps deferred"), never exit-3 "did NOT run; re-invoke". Exit 4
     is reserved and never used by #209.

## 5. Exit-code contract (`scripts/load-gate.mjs`)

| Code | Meaning |
|---|---|
| `0` | proceed |
| `2` | usage error |
| `3` | **deferred — re-invoke** (the wrapper's defer exit; distinct from 0/1/2 so invokers cannot mistake it for success) |
| `4` | reserved for any future abort-after-trigger semantics — never used by this issue |

CLI: `node scripts/load-gate.mjs check [--deferred] [--json] [--force]`.
`LOAD_SUSPEND_THRESHOLD=0` → always exit 3 (deterministic defer). `--force`
sets `LOAD_GATE_FORCE=1` (the env var alone also works) → exit 0
unconditionally.

## 6. Watchdog side (builtin-tools) — the first-message and cut-gap bounds

- **The scale function** is `loadScaledBound(base, load1)`: **three discrete
  bands, no linear region** — `1x` below load `8`, `2x` at `8 ≤ load1 < 16`, `3x`
  at `load1 ≥ 16`; `TASK_LOAD_SCALE_OFF=1` → `1x`. (The `TASK_LOAD_SCALE_START`
  / `TASK_LOAD_SCALE_MAX` rows in §2/§3 name a scale point and cap this function
  does **not** read — its thresholds are fixed literals. See #1073.)
- **First-message bound:** `effM = max(M, M × scale(load1))` where
  `scale ∈ {1,2,3}`. The scaling path does not round — `loadScaledBound`
  multiplies by 1/2/3 exactly. **Load only EXTENDS the bound**
  (never shrinks below the env-overridable static `TASK_FIRST_MESSAGE_MS`).
- **Per-dispatch monotonic high-water-mark latch:** an agent's effM is
  `max(previous tick's effM, recomputed effM)` — once a storm raises the bound
  it never shrinks below the run's max, so a storm ending while `streamAge` is
  peaked cannot trigger an immediate re-cut.
- **`toolsInFlight > 0` exemption (the #198 structural fix):** the first-message
  clause never fires while a tool is in flight — a live tool is bounded by the
  task-path in-flight clauses (#783): output-silence first (S = 20 min), then
  the age backstop at 2/3 of the effective hard cap (4h at the 6h default),
  never cut at M. (The exported `DEFAULT_TOOL_STALL_MS` stays 6h for
  `extensions/subagent/`.) Pinned by test E13. Note (#279): with
  the `everSawRealActivity` latch below, the per-turn exemption is subsumed
  (every parse source of `toolsInFlight`/`turnSawTool` also latches); the
  live #198 protection is the session-level latch — E279g pins hung-tool
  boundedness at L.
- **`everSawRealActivity` gate (the #279 fix):** the clause additionally never
  fires for a session that has demonstrably worked — any parsed
  `tool_start`/`tool_end` marker or tick reporting `tools>0`/`saw_msg`/`saw_tool`
  latches the session monotonically. Per-LLM-call `turn_start` resets the
  per-turn flags in both child and parent, so without this gate a tool-first
  sub-agent was cut at M during its quiet verdict turn (5 recovered cuts). A
  never-worked session (hung first provider request, #5926) keeps the M cut
  unchanged — the latch is deliberately NOT set by bare `ready`/`turn_start`
  (those fire before the first provider call). Pinned by the E279 series.
- **Frozen-age transition reset (the #279 P1-2 hardening):** the parent's parsed
  `streamAgeMs` is the last tick's value — a completed round can leave it frozen
  beyond S (nested-task class), stream-stall-cutting the live verdict at the
  turn transition. `tool_end`/`turn_end`/`turn_start` now reset the parent's
  copy to 0 (the child self-heals via its own activity clock); quiet beyond S is
  then genuine quiet only. Between-turn wedge detection is preserved (stream-stall at
  S of true quiet via flowing ticks; a marker-stopped child is caught at ~S via
  markerAge accumulation inside the 60min fresh window).
- **Observability:** when effM extends beyond M the loop emits
  `[task] first-message bound 300s → 900s (load1=60)` (rate-limited to bound
  increases); the kill headline shows the EFFECTIVE bound (the 905s cut once
  printed "bound 300s" under a latched 900s bound — fixed). **The same rule now
  holds for the ages (#1070)** on the four age-reporting clauses — tool-silence,
  stream-stall, tool-stall and first-message-stall: they fire on the EFFECTIVE
  ages (`raw + markerAge`), so their headlines and the
  `[task] first-message-stall diagnostic:` line report the effective age. The raw
  `streamAgeMs`/`toolAgeMaxMs` in the payload is the child's frozen last
  self-reported sample, not a live reading. All four `Alive state:` diagnostics
  expose the raw pair, `effStreamAgeMs=` / `effToolAgeMs=`, and
  `everSawRealActivity=` for triage.
- **Cut-gap bound (#1070):** the marker-gap cut deadline is a SECOND consumer of
  the same scale function. `effCutGap = getEffectiveCutGapMs(latched, load1)` —
  the derived base (`1.25 ×` tick interval, floor `15_000`) scaled 1x/2x/3x, with
  its own per-dispatch monotonic latch (the same no-shrink rule as effM: a storm
  that starts mid-dispatch extends the window; a post-storm load drop never
  re-cuts). An explicit `TASK_HEARTBEAT_CUT_GAP_MS` is honoured **verbatim and is
  never rescaled** — only the derived default scales, so pinning it is how a test
  or an operator gets a host-independent bound. The loop emits
  `[task] cut-gap bound 38s -> 113s (load1=60)` on a real increase (`Math.round`
  of the 112.5s 3x bound is 113).
  **Reachability invariant:** the clause is gated by `stateFresh`
  (`markerAge ≤ max(2·T, 2·interval)`), so a scaled gap at or above that window
  makes it structurally unreachable; the loop emits a one-shot
  `[task] cut-gap bound Xs >= the stateFresh window Ys …` warning when an override
  crosses it. Safe at the shipped defaults (T = 30min ⇒ window 60min, ~30× the 3x
  gap).
- Tier-1 (`TASK_FIRST_OUTPUT_TIMEOUT_MS`) is **NOT** load-scaled — scaling it
  delays hung-spawn detection, and spawn retry is cheap and stateless.

## 7. Accepted residuals

- **Cap 3× → 15-min storm-time guarantee (watchdog):** at the cap, a first
  message that normally takes >90s is still cut after 900s under a persistent
  storm (10× slowdown ⇒ 900s < 1500s needed). Guarantee: *no cut for
  first-message latency up to 15 min of storm time; beyond that, capped by
  design* (uncapped scale would let hung providers linger indefinitely; the
  in-flight tool-silence clause + age backstop remain the bounds for tools).
- **Cut-gap scaling supersedes the #208 <60s detection target at 2x/3x (#1070):**
  at 1x the cut clause still resolves inside ~54.5s (the #271 calibration); at 2x/3x
  the bound is 75s/112.5s, so the ≤60s figure holds at 1x only. That is the
  deliberate trade: a machine at load 13-18 no longer cuts a child at a flat ~38s
  marker gap. Bounded by the same 3x cap.
- **RPO ≤ 48h (not 24h) for daily-backup:** a deferral near one daily
  invocation can slip to the next under sustained load — accepted trade for
  load safety.
- **daily-backup invoker is unidentified in-repo** (no crontab/schedule
  entry): the exit-3 re-invoke contract depends on an external invoker with
  unknown exit-code handling. If it cannot re-invoke, the contract degrades to
  **loud failure requiring human re-invoke** (the defer log + exit 3 surface
  the miss). Wiring the invoker is out of scope.
- **Skill-gate "defer ≠ lose" is doc-only:** no enforcement that a
  skill-dispatched gate eventually re-ran — exit 3 surfaces as loud failure.
- **macOS thread-counting semantics:** per-core readings run higher than Linux;
  defaults calibrated to Linux; set per-host env thresholds; spurious
  suspension is the safe direction.
- **cgroup/VM-steal blindness:** accepted for a same-host fleet (see §1).

## 8. Swarm CLI contract (documented handoff — out of scope here)

swarm's `operations/coordination/state_machine.py` can consume the same
semantics later via subprocess: exit codes 0/2/3 (§5), envs `LOAD_SUSPEND_THRESHOLD`
/ `LOAD_RESUME_THRESHOLD` / `LOAD_GATE_MAX_WAIT_MIN` / `LOAD_GATE_FORCE`, and
`--json` output `{load1, suspend, resume, verdict, thresholds}` for
observability. A code change in the swarm repo is out of scope for #209 — the
contract is the deliverable.

## 9. Emergency escape

`LOAD_GATE_FORCE=1` bypasses the gate unconditionally (both wrappers accept the
env directly — no script flags, scope-pinned; the helper CLI's `--force`
shorthand merely sets it). Use for manual/urgent runs; a real full daily-backup
run fires a live BGSAVE, so bypass deliberately.

## 10. Complementary (NOT part of the #209 contract)

Optional schedulers-side helpers that can coexist with the gate: a fixed
low-load hour for daily-backup, and `nice`/`ionice` priority lowering. Reactive,
not adaptive — complementary at most (the gate is the adaptive mechanism).

## 11. Scratch checkouts — the un-metered I/O source (#1141)

The load signals in §1–§6 describe a host that is *busy*; this section describes
one that is busy for no reason. Review/probe/mutation sub-agents repeatedly
materialised "an isolated copy of the repo" by hand under `/private/tmp`. A
copy is a second full filesystem tree — on `tortoise` (2,361,772 files in the
working tree, 698 MB `.git`) that is the single largest avoidable I/O generator
on the host.

### Producer evidence (2026-09-17, measured)

Across 2,949 recorded pi transcripts (both `sessions/` and `task-sessions/`):

| Producer | Count | Note |
|---|---|---|
| `git worktree add` → /tmp | 383 | the right primitive, **not** self-cleaning |
| `git worktree remove` → /tmp | 335 | ~48 leaked admin records |
| `cp -R …` → /tmp | 171 | full tree |
| `git clone …` → /tmp | 66 | tree + a second `.git` |
| `rsync -a --exclude .git …` → /tmp | 48 | full tree |

No script in the repo emitted these (`rg '/private/tmp' skills/` → 0 hits; the
`code-review` fixer loop was the one worktree user, and it removed its worktree).
The producers were **agent improvisation** — so the durable fix is an explicit,
checkable rule in the skill text plus a self-cleaning helper, not a reaper.

Surviving artifacts on that host confirmed two copy shapes:
`/private/tmp/rev13` and `rev14` — 126 MB each, 4,559 files, **no `.git`** (the
`rsync` shape); `/private/tmp/p1` — 881 MB with nested `before/` + `mid/` trees.
A third producer was **textual**: `extensions/main-worktree-guard`'s
working-tree-discard block message *taught* `cp <file> /tmp/probe-<file>` and
`git worktree add /tmp/probe <ref>, test inside it` with no cleanup obligation.

### After-measurement — a review-shaped workload

`scripts/scratch-worktree.sh` (worktree + `trap` cleanup, `--paths` sparse mode).
Workload: 8 cycles of "obtain an isolated checkout of a ref and run a check in
it" against `agent-infra`, measured with `ls -1 /private/tmp | wc -l` and
`du -sk /private/tmp`.

| Quantity | Value |
|---|---|
| `/private/tmp` entries before → after | 168 → 168 (**delta 0**) |
| `/private/tmp` size before → after | 1,228,128 KB → 1,228,136 KB (**delta 8 KB**) |
| Per cycle, `--paths skills/code-review` | 112 KB |
| Per cycle, `--paths <one file>` | 8 KB |
| Per cycle, `--full` | 22,056 KB (tree only — objects shared) |
| Per cycle, `git clone --depth 1` (derived: `.git` 124,476 KB + tree 22,048 KB) | ~143,000 KB |
| Leftover scratch worktrees after the run | **0** |

For comparison, the debris this replaces measured 126 MB + 4,559 files **per
cycle**, and `p1` alone 881 MB.

### The rule

- Scratch checkouts MUST come from `bash scripts/scratch-worktree.sh run …`
  (`git worktree add` + `trap` on EXIT/INT/TERM/HUP). Full rule in
  `skills/code-review/SKILL.md`, `skills/test-writing/SKILL.md`,
  `skills/verification-before-completion/SKILL.md`.
- `git clone`, `cp -R`/`cp -r`, `rsync` of the repo, and `git archive | tar -x`
  into a temp dir are BANNED for scratch checkouts.
- Leaked worktrees are recoverable by `scripts/pi-reap-worktrees.sh` (#1095);
  this section exists so they are not created in the first place.
