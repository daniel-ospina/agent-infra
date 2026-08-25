<!-- research-path: none beyond source reading — root cause verified against installed pi SDK (dist/modes/print-mode.js, dist/core/agent-session-runtime.js, dist/core/extensions/runner.js, utils/abort.js) + agent-infra sources (extensions/builtin-tools/index.ts, extensions/task-heartbeat.ts, extensions/mcp-client/index.ts, extensions/shared/tree-kill.ts). Full findings in the issue scoping comment (#191, 2026-08-13). -->

# bug(task): sub-agent exit hang after MCP disconnect timeouts — completed work surfaces as "Subagent was aborted" — implementation plan (#191)

**Goal:** Task sub-agent sessions must exit promptly after completion instead of hanging on MCP disconnect timeouts, so parents never see "Subagent was aborted" after the work is done. Targets: 0 hung sub-agent processes; completion watchdog fires < 1% of sessions (safety net, not primary path).

**Team:** organisation-design-team
**Status:** SCOPED + PLANNED (plan artifact for the pipeline gate — no implementation yet)
**Level:** project | **Complexity:** complex (confirmed)

---

## Problem Statement

Every `task` sub-agent dispatch ends with `[mcp-client] Disconnect from 'X' timed out after 5000ms — forcing` (child stderr), the child process then **never exits**, and the parent tool call hangs for minutes until the user aborts — surfacing completed work as "Subagent was aborted" (observed all day 2026-08-12 on tortoise work; `docs/upstream-pi-bugs.md` Issue A).

Three-layer root cause (verified by source reading):

1. **Child hang (upstream).** Print mode has no `process.exit()` — `dist/modes/print-mode.js` relies on natural event-loop drain. After the final text write, `runtimeHost.dispose()` → `agent-session-runtime.dispose()` emits `session_shutdown` → mcp-client `disconnectAll()` runs a sequential 5s race per server; afterwards any leftover handle (MCP transport timer/child, cmux, undici keep-alive) keeps the loop alive in state `S` forever. (Upstream filing blocked — no issue-create permission; child-side cleanup owned by #199.)
2. **Parent watchdog blind spot (agent-infra defect).** `armExitWatchdog` arms only on BOTH-stdio-EOF (`extensions/builtin-tools/index.ts` L298-337). A hung-but-alive child never closes fds 1/2 → no EOF → the T3 watchdog never fires for the hang class. Sole rescue: the 30-min heartbeat silence kill, which returns "Partial results", not success.
3. **No completion signal.** The parent can't distinguish "work done, stuck in cleanup" from "stuck mid-work", so no short exit grace is applicable; the tool call hangs → user aborts → "Subagent was aborted".

Precedent: the `subagent` tool's #137 fix ("an abort only counts when the process did NOT exit cleanly; completed work is preserved") — this plan applies the same principle to the `task` tool.

---

## Design

### 1. Child side — `session_end` completion marker (`extensions/task-heartbeat.ts`)

Emit `[task-heartbeat] session_end nonce=<n>` **synchronously as the first action of the `session_shutdown` hook** (currently the hook only clears the tick timer). Ordering is verified in `print-mode.js`: the final assistant text is written to stdout BEFORE `disposeRuntime()` → `session_shutdown`, so by the time the parent sees `session_end`, its stdout accumulator holds the complete result payload.

- New `formatSessionEnd(nonce)` formatter (drift-guarded by the E14 round-trip test, same as the other 6 marker kinds).
- The marker is nonce-authenticated (existing `TASK_HEARTBEAT_NONCE` mechanism) — MCP servers inheriting fd 2 cannot forge it.
- Correct the outdated comment "pi does NOT emit session_shutdown in print mode": `agent-session-runtime.dispose()` (reason `"quit"`) does emit it in the current pi version — this is what makes the marker possible.
- Fallback: if a future pi version stops emitting `session_shutdown`, the marker is simply absent → parent falls back to legacy behavior (no regression).

### 2. Parent side — marker parse + completion watchdog (`extensions/builtin-tools/index.ts`)

a. **Parse + latch:** add `"session_end"` to `KNOWN_MARKER_KINDS`; add `sessionEnded: boolean` to `HeartbeatState` (latched); handle in `parseHeartbeatLine`; add `onSessionEnd` callback to `HeartbeatIngestContext` so `spawnSubAgent` gets a synchronous edge without polling.

b. **Grace getter:** `getExitCompleteGraceMs()` reads `TASK_EXIT_COMPLETE_GRACE_MS`, default `15_000`, clamped ≥ 1000ms (same philosophy as `getExitGraceMs`). 15s balances: healthy children exit ~1s (fast disconnects) — watchdog never fires; hung children get rescued before user-abort patience runs out.

c. **Completion watchdog** (new, alongside the existing EOF watchdog — which stays for the narrow stdio-closed-but-alive class): armed once on `session_end` while the process is still alive; after `graceMs` without `close`, treeKill SIGTERM → SIGKILL after 5s (exact `armExitWatchdog` escalation pattern, `extensions/shared/tree-kill.ts`). Disarmed in `doResolve`, `proc.on("close")`, `proc.on("error")` — same lifecycle as the EOF watchdog.

d. **Result composition on `close`:** when `state.sessionEnded`:
   - stdout non-empty → resolve `content = stdout` exactly like the `code === 0` success path, with `details: { model, provider, exitCode, killedAfterCompletion: true, exitWatchdog: "completion" }` when the watchdog killed it (exitCode null/signal) or `{ model, provider }` on a natural clean exit.
   - stdout empty (error stopReason sessions write to stderr) → fall back to today's stderr/exitCode composition so failure info is never lost and is never misclassified as success.
   - Never classified as aborted by the parent; the tool call returns promptly so the SDK never aborts it.

e. **Unchanged paths:** heartbeat silence/stall kills (Tier 1/2) still handle "never completed"; EOF watchdog handles "stdio closed but alive". `retry()` only re-spawns on zero-output (undefined) — a completion-watchdog result is defined, so no double work.

### 3. Abort hardening (P2, optional in first pass)

Accept the `AbortSignal` argument in `task`'s `execute`; on abort while `sessionEnded`, resolve the already-captured output immediately instead of waiting for `close`. Belt-and-suspenders for sub-grace user aborts; primary fix (≤15s return) makes this window vanishingly rare.

### 4. Overlap with #199 (mcp-client — NOT touched here)

Child-side `disconnectAll` cleanup is #199's surface (detached/bounded disconnect so healthy children exit ~1s). This plan makes the parent-side watchdog guarantee prompt, correctly-classified return regardless of #199's outcome; if #199 lands, the completion watchdog becomes a true safety net firing < 1% — matching the issue target. Indicator 2 ("no `Disconnect ... timed out` messages precede a hang") fully clears only with #199; this plan clears Indicators 1 (prompt exit enforced by parent) and 3 (no user aborts of completed sub-agents).

## Wiring

| Component | File | Test Layer | Change |
|---|---|---|---|
| Child marker emitter | `extensions/task-heartbeat.ts` | unit (fake-pi harness in builtin-tools.test.ts) | `formatSessionEnd()`; emit synchronously first in `session_shutdown` hook; fix outdated comment |
| Marker parse + latch | `extensions/builtin-tools/index.ts` | unit (`parseHeartbeatLine` tests) | `KNOWN_MARKER_KINDS` + `"session_end"`; `HeartbeatState.sessionEnded`; parse case; `HeartbeatIngestContext.onSessionEnd` |
| Grace getter | `extensions/builtin-tools/index.ts` | unit (env getters) | `getExitCompleteGraceMs()` — `TASK_EXIT_COMPLETE_GRACE_MS` default 15_000, clamp ≥1s |
| Completion watchdog | `extensions/builtin-tools/index.ts` | unit (EventEmitter fakes — armExitWatchdog pattern) + integration (fake-child spawn) | Arm on `session_end`; treeKill SIGTERM→SIGKILL; disarm on close/error/settle |
| Result composition | `extensions/builtin-tools/index.ts` | unit (pure `composeTaskResult` fn, exported for tests) | `sessionEnded` → success-with-stdout + `killedAfterCompletion`/`exitCode`; empty stdout → failure path preserved |
| Abort hardening (P2) | `extensions/builtin-tools/index.ts` | unit | Accept `AbortSignal`; abort while `sessionEnded` → resolve captured output |
| Drift guard | `extensions/builtin-tools/builtin-tools.test.ts` (E14) | unit | `session_end` round-trip through parent parser with nonce; constants parity |
| E2E | `extensions/builtin-tools/subagent-e2e-smoke.test.ts` | e2e | Deterministic fake-child hang (E1/E3) + optional LLM-gated real dispatch (E2/E4) |
| Docs | `docs/upstream-pi-bugs.md` | — | Note the agent-infra mitigation now covers the hang class (watchdog trigger no longer EOF-only) |

## Verification

- **Unit:** `npx tsx extensions/builtin-tools/builtin-tools.test.ts` — new tests: `session_end` parse+latch, nonce rejection, grace getter clamps, `composeTaskResult` success/empty-stdout/killed branches, watchdog arms-on-session-end + disarm, child emitter emits on fake `session_shutdown` with nonce, E14 drift round-trip. Existing 106 tests stay green.
- **Integration (deterministic, no LLM):** fake-child script (`node -e`) that writes a payload to stdout, emits `[task-heartbeat] session_end nonce=<n>` to stderr, then leaks `setInterval` → assert the task dispatch returns the payload as success within the grace, the child + grandchildren are reaped, and no "aborted" classification. Also a child that exits normally within grace (watchdog disarmed, no kill log) and a child that errors with empty stdout (failure composed from stderr).
- **E2E smoke (LLM-gated, `DEEPSEEK_API_KEY`):** existing dispatch harness; assert `details.stderr` may contain disconnect lines but the result is success and no user abort occurred.
- **Field target:** 24h window with zero user aborts of completed sub-agents; watchdog rescue < 1% of sessions (primary exit path = natural, ≤ ~1s once #199 lands).
- **Review:** per commit-workflow — code-review gate with fresh-context reviewers; test-review gate.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Older pi version stops emitting `session_shutdown` → no marker | Marker absent → legacy EOF/silence path; zero regression (fallback is the status quo) |
| Kill mid-cleanup orphans MCP server children | Child's `process.on("exit")` orphan sweep (mcp-client L293) + parent `treeKill` reaps the tree (proven by #137) |
| 15s grace kills a healthy-but-slow child | Harmless: output already captured; result still classified success with `killedAfterCompletion` detail; grace env-overridable |
| Empty-stdout (error) sessions misclassified as success | `composeTaskResult` falls back to stderr/exitCode path when stdout is empty |
| Marker spoofing via fd-2 inheritance | Nonce authentication (existing); foreign prefix lines already excluded by `KNOWN_MARKER_KINDS` |
| Abort during the ≤15s window | P2 signal handling resolves captured output on abort; window is 120× smaller than the 30-min status quo |
| Marker contract drift child↔parent | E14 round-trip extended to `session_end` |
