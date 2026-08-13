# Issue #208 — Research

Status: DRAFT
Branch: feat/208-task-cut-resume
Date: 2026-08-12
Level: project | Complexity: standard | Team: organisation-design-team

---

## 1. DISPATCH LIFECYCLE — `extensions/subagent/index.ts` (the `subagent` tool)

`runSingleAgent` (L405–594) owns the child's lifetime. The parent's await is
the promise at L425:

```ts
const exitCode = await new Promise<number>((resolve) => {
```

**Spawn** (L430–438) — detached by default (#137 F8), which puts the child in
its OWN process group:

```ts
// #137 F8: detached spawn gives the sub-agent its own process group,
// so treeKill can signal it (and its MCP server children) without
// ever signalling the orchestrator. Opt out via SUBAGENT_DETACHED=0.
const detached = process.env.SUBAGENT_DETACHED !== "0";
const proc = spawn(invocation.command, invocation.args, {
  cwd: cwd ?? defaultCwd,
  shell: false,
  detached,
  stdio: ["ignore", "pipe", "pipe"],
  env: { ...process.env, PATH: augmentedPath },
});
```

**Resolve points** — exactly two, both process events:

1. `proc.on("close", ...)` (L537–563) — the ONLY resolver on normal exit,
   per-task timeout, abort, and external kill:

```ts
proc.on("close", (code) => {
  clearInterval(heartbeat);
  if (taskTimeout) clearTimeout(taskTimeout);
  if (buffer.trim()) processLine(buffer);
  if (timedOut) {
    currentResult.stopReason = "timeout";
  } else if (wasAborted) {
    if (shouldThrowOnAbort(code, wasAborted)) {
      currentResult.stopReason = "aborted";
      currentResult.errorMessage = `Subagent was aborted (user-initiated). Result cache: ${cacheDir}`;
    } else {
      currentResult.stopReason = "completed_before_abort";
    }
  }
  emitUpdate();
  resolve(code ?? 0);            // ← L562: null (signal-killed) collapses to 0
});
```

2. `proc.on("error", ...)` (L565–568) — spawn failures: `resolve(1)`.

**stopReason assignments**: `timedOut` → `"timeout"` (L545); `wasAborted` +
`shouldThrowOnAbort` (non-zero / signal-killed code) → `"aborted"` (L548);
abort-after-clean-exit → `"completed_before_abort"` (L552). **There is no
branch for an external watchdog kill** — an externally SIGKILLed child fires
`close` with `code === null`, which resolves `0` and leaves `stopReason`
undefined. `isFailedResult` (L165–172) then returns **false** — an external
cut is indistinguishable from SUCCESS in this tool (only partial `messages`
survive). This is the cut-reason gap for the `subagent` tool.

**Timeout** (#137 F1, L452–464): `DEFAULT_TASK_TIMEOUT_MS = 1_800_000` (30 min);
0/negative/NaN → disabled. Fires → `timedOut = true; killTree("SIGTERM")`.
**Abort** (L570–581): `wasAborted = true; killTree("SIGTERM")`.

**Kill path** (L470–482) — process-TREE kill via `shared/tree-kill.ts`:

```ts
const killTree = (signal: NodeJS.Signals) => {
  const pid = proc.pid;
  if (pid !== undefined) {
    treeKill(pid, signal);
  } else {
    proc.kill(signal);
  }
  const sigkillTimer = setTimeout(() => {
    if (proc.exitCode === null && !proc.killed) {
      if (pid !== undefined) treeKill(pid, "SIGKILL");
      else proc.kill("SIGKILL");
    }
  }, 5000);
  sigkillTimer.unref?.();
  proc.once("close", () => clearTimeout(sigkillTimer));
};
```

**Key lifecycle facts for #208**:
- Both tools resolve on `close` only — there is **no `exit` handler** anywhere
  in `subagent/index.ts` or `builtin-tools/index.ts` (grep: only `close`/`error`).
- Node's `close` fires only after the process **and all stdio streams** have
  ended. A grandchild (MCP server / bash fork) holding the inherited pipes
  delays `close` indefinitely — the parent's await survives the child's death.
- `resolve(code ?? 0)` erases the signal-kill signal for the exitCode field —
  an external cut looks like `exitCode: 0` unless a stopReason was set first.

## 2. THE 6H BLOCK — `extensions/builtin-tools/index.ts` (the `task` tool)

The observed incident ("parent task calls returned partial results ~6h later")
was dispatched through the builtin `task` tool's `spawnSubAgent` (L1116–1302),
which runs the tiered watchdog (#152/#153/#176).

**(a) Which clause fires when a sub-agent is cut while a tool is in flight
(`toolsInFlight > 0`)?**

`heartbeatKillDecision` (L726–809), precedence pinned `tool-stall →
stream-stall → silence → first-message` (L722, test E10):

```ts
// 1. tool-stall — L759–766
if (stateFresh && st.toolsInFlight > 0) {
  const bound = st.turnActive
    ? i.toolStallMs
    : Math.min(i.toolStallMs, i.heartbeatTimeoutMs);
  if (effToolAge > bound) return kill("tool-stall");
}
```

With `toolsInFlight > 0` and `turnActive` (a tool executing inside a turn),
the **only** clause that can fire is **tool-stall at `DEFAULT_TOOL_STALL_MS =
21_600_000` = 6h** (L436). The 300s `first-message` clause (L792–798) requires
`!turnSawMessage && !turnSawTool` — a tool in flight latches `saw_tool` on
ticks, so it cannot fire for the observed class. **The 6h number in the issue
is exactly `DEFAULT_TOOL_STALL_MS`.** The silence clause is explicitly exempted
while `stateFresh && turnActive && toolsInFlight > 0` (L774–778).

**(b) Why the PARENT's await doesn't resolve when the child dies.**

The builtin tool spawns **without `detached`** (L1135–1139) — the child shares
the parent's process group — and resolves only on `close` (L1274–1296) and
`error` (L1298–1301):

```ts
proc.on("close", (code: number) => {
  clearInterval(heartbeat);
  flushHeartbeatLineBuf(hbCtx);
  ...
  doResolve({ content: [{ type: "text", text: stdout.trim() }], details });
  ...
});
```

When the watchdog kills the child, the kill path (L1240–1245) is:

```ts
clearInterval(heartbeat);
proc.kill("SIGTERM");
const sigkillTimer = setTimeout(() => { if (!proc.killed) proc.kill("SIGKILL"); }, 5000);
proc.once("close", () => clearTimeout(sigkillTimer));
```

Two compounding defects:
1. The kill is a **single-pid `proc.kill`** (not `treeKill`), so the child's
   MCP servers / forked shells survive the cut.
2. A surviving child-of-the-child **holds the inherited stdout/stderr pipes
   open** → the parent's `close` event never fires → `doResolve` never runs.
   The heartbeat interval was already cleared, and there is no `exit` handler
   and no fallback timer on the parent's await — the wait is effectively
   **unbounded**; it ends only when the orphan eventually exits (~6h in the
   incident, matching tool-stall for the wedged-alive child and/or the orphan's
   own death). The align doc already names this: "a forked child holding the
   stdout/stderr pipes both survives the cut AND blocks the parent's `close`
   event (the 6h mechanism)."

**(c) Heartbeat kill: `proc.kill` (single pid) — quoted above (L1241).** The
only `treeKill` in the builtin tool is the tier-3 **exit watchdog** default
(L306: `const killFn = opts.kill ?? ((signal) => treeKill(opts.pid, signal))`),
armed at L1150. The heartbeat kill path — the one that fires on
tool-stall/stream-stall/silence/first-message — uses plain `proc.kill`.

Kill-result composition (defined partial results, L1259–1272) already exists:
`doResolve({ content: [...headline + alive state + stderr/stdout tail], details:
{ model, provider, killed: true, reason, heartbeatTimeout } })` — with headlines
per reason ("Partial results below — parent should decide: accept, re-dispatch,
or escalate."). `resolveUndefined` (retryable, `!hasOutput`) at L1248–1257.

## 3. ORPHAN SURFACE — kill paths, process groups, sweep placement

Grep of `extensions/` for kill/process-group handling:

| Path | Kill mechanism | Process group |
|---|---|---|
| `subagent/index.ts` killTree (L470–482) | `treeKill` (recursive PPID-tree walk, per-PID signals) | child spawned **detached** → own pgid (L433/437) |
| `builtin-tools/index.ts` heartbeat kill (L1241) | **`proc.kill` single PID** | child NOT detached → **shares parent's pgid** |
| `builtin-tools/index.ts` exit watchdog (L306) | `treeKill` (default) | same process group as parent |
| `shared/tree-kill.ts` (L67–85) | per-PID tree walk, `process.kill(pid, signal)` | **no process-group signaling anywhere** (`grep 'kill(-'` → zero hits) |
| `mcp-client/index.ts` (L584–593) | per-PID SIGTERM→SIGKILL on tracked transports | n/a |

`treeKill` (L67–85) walks the **parent-PID tree** (`pgrep -P`, L28–48),
children-first, double-pass. **Limitation for a post-cut sweep:** once the
sub-agent is reaped, an orphan's PPID is reassigned (→ 1/launchd), so a
PPID-walk can never find it. A sweep must therefore anchor on the **process
group id (pgid) captured at spawn** (requires `detached: true` first — the
builtin tool currently doesn't detach, so a group-anchored sweep there would
hit the parent's own group) or on a dispatch identity (e.g. the
`TASK_HEARTBEAT_NONCE` / marker task-string, which appears in the child's argv
and is `pgrep -f`-greppable — the pattern already used by
`timeout-integration.test.ts` L110–120). Exclusion envelope: never the
orchestrator's own group; verify ppid-chain; coordinate with #195 worktree
recovery (a killed mid-write orphan can leave `index.lock`/partial worktree
state).

Natural sweep placement: in `spawnSubAgent`'s kill/close paths and/or a small
post-dispatch sweep utility next to `shared/tree-kill.ts` (which is the 
precedent file for orphan reaping — its header already documents the #137
MCP-server orphan class).

## 4. PARENT-SIDE WAIT

- **`subagent` tool:** the promise returned to the orchestrator is
  `runSingleAgent`'s `await new Promise(...)` (L425), resolved exclusively in
  `close` (L562) / `error` (L567). Its only bound is the **child-side**
  `taskTimeout` (L452–464, 30 min default) which kills the tree; after a kill
  the resolve still waits on `close`. **No timeout exists on the parent's await
  itself** — if `close` never fires (pipe holder), the await is unbounded.
- **`task` tool (builtin):** `spawnSubAgent` returns
  `new Promise((resolve) => ...)` (L1118) with `doResolve` (L1204–1208,
  settled-guarded, disarms the exit watchdog). Resolvers: heartbeat kill
  (L1248/L1268), `close` (L1288/L1293), `error` (L1301). Bounds on the await:
  the heartbeat clauses (tool-stall 6h / stream-stall 20 min / silence 30 min /
  first-message 300s / tier-1 60s) + the exit watchdog (120s). **All of these
  resolve through kill-then-`close`** — so every bound is defeated by an orphan
  holding the pipes. There is no wall-clock timeout on the await itself
  (`TASK_MAX_DISPATCH_MS` is opt-in and OFF by default — `DEFAULT_MAX_DISPATCH_MS = 0`, L469–472; clause at L800–805).
- **Both** tools: adding a resolver on `proc.on("exit")` (fires on child death
  regardless of pipes) — in addition to `close` — is the minimal fix for the
  unbounded wait; the pipeline already has partial-output accumulation
  (`currentResult.messages`/`stdout`/`stderr` are captured incrementally), so
  resolving on `exit` returns the partials immediately.

## 5. TEST PRECEDENT — harness patterns for a "simulated cut" test

- `extensions/subagent/index.test.ts` (341 lines) — pure unit tests:
  `isFailedResult`, `getResultOutput`, `shouldAbortBeNoop`/`shouldThrowOnAbort`,
  `getTaskTimeoutMs` parsing, `getCacheDir`/`cacheResult` (disk round-trip),
  PATH/`getPiInvocation` regressions. No process spawns.
- `extensions/subagent/timeout-integration.test.ts` (145 lines) — **the harness
  pattern for a simulated cut.** Real `runSingleAgent` dispatch with
  `SUBAGENT_TASK_TIMEOUT_MS = "5000"` and a task that cannot finish
  (`"sleep 120 && echo done"`), asserting:
  1. resolve within a window (`elapsed >= 4500 && elapsed < 30_000`);
  2. `stopReason === "timeout"`;
  3. **orphan reaping**: `pgrep -f "sleep 120 && echo done"` must be empty
     after the kill (L110–120).
  It relies on `process.argv[1] = undefined` so `getPiInvocation` falls back to
  bare `pi`, and needs no `DEEPSEEK_API_KEY` (no key → pi never completes →
  killed by the bound).
- `extensions/subagent/abort-resilience.test.ts` (130 lines) — real spawn +
  `AbortController` fired after completion; **requires `DEEPSEEK_API_KEY`
  (skips when absent)**; uses `SUBAGENT_TASK_TIMEOUT_MS=120000` as a hang
  safety net.
- `extensions/builtin-tools/builtin-tools.test.ts` (1367 lines) — pure
  `heartbeatKillDecision` clause tests E1–E13 (L928–1115) with injected
  `HeartbeatDecisionInput` (T=60s, S=120s, L=3.6M, M=300s): E9 (in-turn
  tool-stall at L), E10 (preflight `min(L,T)` + precedence), E13
  (first-message at M, `saw_tool` exemption), plus a source-drift assertion
  that `armExitWatchdog` is wired into `spawnSubAgent` (L559).
- `extensions/builtin-tools/subagent-integration.test.ts` (114 lines) — spawns
  real `pi -p` children, captures stderr for a window, then `proc.kill()`s them
  — an existing "kill a child mid-flight" primitive.

**Feasibility of the target test** ("simulated cut → parent returns partial
results < 60s after cut"): yes — combine the timeout-integration harness with
the E-series decision-function unit tests:
1. Unit: `heartbeatKillDecision` with a "cut" state (toolsInFlight>0 and a
   marker gap > deadline) asserts the new cut clause fires and
   `resolveUndefined=false` with partial output.
2. Integration: dispatch via `spawnSubAgent`/`runSingleAgent` with short
   bounds; the child writes partial output then either (a) forks a
   pipe-holding grandchild and exits (tests the `exit`-resolver fix), or (b)
   is externally SIGKILLed mid-tool (tests liveness/exit detection); assert
   parent resolves < 60s with a cut reason and `pgrep`-anchored zero orphans.
3. Reuse the `pgrep -f <marker>` orphan assertion (timeout-integration L110)
   as the sweep's verification anchor.

## 6. DOC TARGET — `skills/parallel-orchestrator/SKILL.md` (cat, 6680 bytes)

Sections present (in order): header + "must be read in full" gate → "When to
Use This Pattern" → "The Pattern" (1. Fan-Out Dispatch, 2. Concurrency
Control, 3. Structured Output Format, 4. Fan-In Synthesis, 5. Convergence
Gate) → "Pre-Warming Pattern" → "Integration" (consumed-by list) →
"Background Execution Note" → "Partial-Failure Handling" → "Anti-Patterns"
(table) → footer.

**Partial-Failure Handling** today covers classify/aggregate only:

> 1. **Collect** all results — successes and failures
> 2. **Classify:** ✅ Success, ⚠️ Timed out, ❌ Failed
> 3. **If some succeeded:** Proceed. Flag gaps: "⚠️ reviewer-3 timed out — skipped"
> 4. **If ALL failed:** Return structured error: "❌ All reviewers failed (3/3)"

**Anti-Patterns** has a fallback row ("No fallback for subagent tool failures —
If the subagent tool is unreachable ... retry 3× with backoff, then surface to
human with options (a) retry, (b) proceed sequentially, (c) abort") — but zero
assume-dead / commit-early / re-dispatch guidance. **Gap confirmed** (matches
align I3).

**Where the new guidance belongs:**
- A new subsection under **Partial-Failure Handling** (e.g. "Cut / Assume-Dead
  Handling"): treat a cut result (`killed: true, reason` / `stopReason: "cut"`)
  as **assume-dead** — never block on it, do not treat it as success; read the
  result cache (subagent F6) for partial output; **commit-early contract**
  (workers persist incrementally so a cut loses ≤ the last uncommitted step);
  **re-dispatch on cut** with backoff up to a bounded number of attempts; state
  the idempotency expectation (re-dispatch may re-run partial writes).
- One new **Anti-Patterns** row (e.g. "Blocking on a cut/dead sub-agent" —
  parent waits are bounded; a cut must return partials + reason within the
  watchdog bound, then the orchestrator re-dispatches instead of hanging).

## Implications for Scope

1. **Cut definition must be operational before the 60s indicator is testable.**
   Two cut classes, two detectors: (a) *process death* — add a `proc.on("exit")`
   resolver in BOTH tools (settles the parent promise even when an orphan holds
   the pipes; currently `close`-only); (b) *liveness loss* (the observed
   0%-CPU hang-alive class, PID 6632) — a marker-gap deadline (ticks flow every
   30s; ~2–3 missed = cut) since exit never fires for a wedged-alive child.
   Without (b) the headline target is unreachable for the dominant class; the
   align doc flags (b) as medium-confidence and the gate on the target.
2. **Sweep must be group/ancestry-anchored, not pid/name-based.** The builtin
   `task` tool spawns non-detached (shares the parent's group) — a pgid sweep
   there would kill the orchestrator; either switch it to `detached: true`
   (parity with the subagent ext, #137 F8) or anchor on the dispatch identity
   (`TASK_HEARTBEAT_NONCE` / marker task-string, `pgrep -f` — the existing
   timeout-integration orphan assertion). Never kill the orchestrator's own
   group; verify ppid-chain; coordinate with #195 worktree recovery. Note
   `treeKill`'s PPID walk breaks on reparented orphans (PPID→1), so the sweep
   cannot be a plain `treeKill` replay.
3. **Keep the tool-stall bound at 6h.** `DEFAULT_TOOL_STALL_MS` is a deliberate
   ceiling for legitimately long tools (deploys, batch reads); lowering it
   reintroduces the #489 kill-productive-agents class. The target is
   *parent-returns-on-cut at bound latency*, not bound shrink. The 6h observed
   is the tool-stall clause doing its job on a cut child — the fix is exit/live
   detection + pipe-holder resolution, not a lower L.
4. **Resume contract is first-class, not just doc.** Builtin `task` already
   emits `killed: true, reason` + partials for internal kills (reuse); the
   `subagent` ext has NO cut reason — external SIGKILL resolves `exitCode 0,
   stopReason undefined` and `isFailedResult` reports success (L562/L165) — a
   `"cut"` stopReason mapping is needed there. Result caching (F6) is the
   partial-output preservation mechanism; the parallel-orchestrator guidance
   must name commit-early + re-dispatch-on-cut + idempotency explicitly
   (align I3 gap).
5. **Close the single-pid kill gap.** The builtin heartbeat kill path
   (L1241, `proc.kill("SIGTERM")`) is the only non-treeKill kill left; switch
   it to `treeKill` (precedent: subagent ext L473, exit watchdog L306) so
   MCP/fork children die with the child and the pipes close. This alone fixes
   the orphan surface for internal kills; the external-cut class still needs
   the exit/liveness resolvers + sweep.
6. **Test strategy is proven and cheap.** Follow `timeout-integration.test.ts`
   (real spawn + short env bound + elapsed window + `pgrep` orphan assertion)
   for the simulated-cut E2E, and extend the E-series
   `heartbeatKillDecision` unit tests for the new cut clause; no new harness
   infrastructure needed.
