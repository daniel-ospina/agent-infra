# Issue #176 — task sub-agent heartbeat: alive signals, not output bytes

Status: IMPLEMENTED — T1–T6 complete, 99/99 unit tests, E4 e2e passed (70s
silent tool call survived the 60s threshold through the real task tool), drift
gate green (25 entries)
Branch: feat/176-heartbeat-alive-signals
Date: 2026-08-11
Branch: feat/176-heartbeat-alive-signals
Date: 2026-08-11

## Problem Diamond

### Confirmed problem

The task-tool (extensions/builtin-tools/index.ts `spawnSubAgent`) tier-2 silence
detector kills sub-agents that are **actively working**. `lastHeartbeat` resets only
on stdout/stderr bytes. In print mode pi buffers stdout until the final turn message,
so a sub-agent that is mid-tool-call (long pytest/build/clone) or mid-model-turn
(deep reasoning, slow stream) emits zero bytes for the whole operation. At 1800s of
byte-silence the parent SIGTERMs a live, productive agent. Recurrence of #129, which
only raised the threshold (660s → 1800s) — same failure class at the new cliff.

### Divergence — root-cause candidates

1. **Alive-definition bug (root):** detector equates "alive" with "recent output
   bytes". Life signs exist in the child (tool in flight, model turn active) but are
   not observable on the parent's channels.
2. Print-mode stdout buffering (#489 class) hides assistant turns until completion.
3. Long-running child processes of `bash` emit nothing until they finish.
4. Threshold (1800s) < real-world operation length (>30 min suites/builds/clones).

### Convergence — problem definition

The threshold semantics are wrong: they must mean **"no signs of life"**, not **"no
output bytes"**. Raising the threshold again only moves the cliff. The fix must make
child life signs (in-flight tool calls, active model turns) observable to the parent
and suppress the kill while any is true — falling back to byte-silence detection when
no life signs are available (legacy behavior, no regression).

## Solution Diamond

### Divergence — alternatives considered

| # | Alternative | Verdict |
|---|-------------|---------|
| A | **Child life-sign emitter extension + parent state-aware heartbeat.** New extension (gated by `TASK_HEARTBEAT=1` env the task tool injects) emits `[task-heartbeat]` markers on stderr; parent parses them and makes the tier-2 kill state-aware. | ✅ **Selected** — additive, backward compatible, matches the issue's suggested fix, mirrors the proven 30s-keepalive pattern in extensions/subagent/index.ts (#6539 heartbeat). |
| B | Switch task tool to `--mode json` and parse structured events (like extensions/subagent). | ❌ for this issue — changes the result contract (stdout text) for every caller, rework of retry/fallback/connection-error detection. Viable follow-up. |
| C | Raise/disable the timeout again. | ❌ — #129 proved this insufficient; a disabled timeout can never detect genuinely hung agents. |
| D | Parent probes the child process (signal-0 liveness, CPU sampling). | ❌ — proves existence, not work; cannot distinguish a running tool from a wedged loop. |
| E | Wait for upstream pi to stream in print mode. | ❌ — out of our control; tracked in docs/upstream-pi-bugs.md. |

### Convergence — chosen solution (A)

**Child side — new extension `extensions/task-heartbeat.ts`** (root-level flat file,
fully self-contained — flat extensions cannot resolve sibling imports, #5611; imports
only the `ExtensionAPI` type):

- Active only when `TASK_HEARTBEAT=1` (set by the task tool for sub-agents) AND
  `PI_MODE=print` (belt-and-braces against a stray shell env), and not
  `TASK_HEARTBEAT_DISABLE=1`. Silent in interactive sessions and other print-mode
  contexts (e.g. swarm_daemon) — no new noise.
- Emits to **stderr** (stdout is the result payload; pi wraps stdout only in print
  mode — console.error goes straight to fd 2 unmediated):
  - `[task-heartbeat] ready` — once at `session_start` (diagnostic: distinguishes
    "emitter absent / legacy fallback" from "broken wiring")
  - `[task-heartbeat] tool_start <toolCallId> <name>` / `tool_end <toolCallId>`
    (from `tool_execution_start` / `tool_execution_end`)
  - `[task-heartbeat] turn_start <n>` / `turn_end <n>` (turn spans LLM request +
    tool calls, so turnActive covers deep-reasoning waits AND tool execution;
    agent_start/agent_end is wrong — agent_end can be followed by auto-retry /
    compaction gaps)
  - `[task-heartbeat] tick tools=<n> turn=<0|1> stream_age_ms=<n> tool_age_max_ms=<n> saw_msg=<0|1> saw_tool=<0|1>`
    every `TASK_HEARTBEAT_INTERVAL_MS` (default 30s, clamped 5s–300s).
- **Activity tracking (child):** `lastActivityAt` resets on any of {turn_start,
  turn_end, tool_execution_start, tool_execution_update, tool_execution_end,
  message_start (assistant), message_update} → `stream_age_ms` = ms since then.
  Covering message_start + tool_execution_update protects non-streaming /
  slow-TTFT / reasoning-only-delta turns from false stall-kills.
  Caveat documented: a provider that emits zero events for > TASK_STREAM_STALL_MS
  inside a legitimate turn (no streaming, no message_start observable) is
  indistinguishable from a stall — the bound is overridable.
- **Per-turn flags (child):** `turnSawMessage` (assistant message_start or
  message_update seen) and `turnSawTool` (any tool_execution_start seen), both
  reset on turn_start → ticked as `saw_msg` / `saw_tool` (feeds the parent's
  first-message backstop).
- **Tool tracking (child):** outstanding tools tracked as a **Set keyed by
  toolCallId** (not a bare counter — pi emits tool_execution_start during
  preflight and tool_execution_end in completion order; a preflight-started tool
  that is rejected/skipped could otherwise desync a counter forever). Set is
  **cleared on turn_end** (pi guarantees all tools finalize before turn_end —
  bounds any residual desync to one turn). `tool_age_max_ms` = age of the oldest
  outstanding tool (0 when none).
- Tick timer is `.unref()`ed + cleared on `session_shutdown` — must never hold the
  event loop open (#153 hang-on-exit class).
- **Wiring deliverables (load path):** symlink
  `pi-bootstrap/pi-config/extensions/task-heartbeat.ts` (drift gate
  `scripts/check-pi-config-extensions.sh` check 3 enforces set parity) AND add
  `"task-heartbeat.ts"` to `manifest.json` `files.extensions.entries` (CLI
  bootstrap path, parity with setup.sh per #96). ALSO repair pre-existing drift
  making the gate red today: add the missing
  `pi-bootstrap/pi-config/extensions/custom-provider-qwen` symlink, so the gate
  runs green and actually enforces the new entry.

**Parent side — `spawnSubAgent` in extensions/builtin-tools/index.ts:**

- Sets `TASK_HEARTBEAT=1` in the sub-agent env (checks `TASK_HEARTBEAT_DISABLE=1`
  BEFORE setting — the disable flag also flows to the child via the env spread).
- **Marker ingestion at data-arrival:** stderr chunks are line-buffered; complete
  lines matching `[task-heartbeat] ...` are parsed into state and then DISCARDED —
  they never enter the capped `stderr` accumulator. Filtering at ingestion (not at
  result time) means the 1MB cap boundary can never truncate a marker into a
  leakable fragment, and no result path (clean exit / non-zero exit / kill /
  spawn-error) can contain markers. Non-marker stderr keeps all legacy effects
  (`hasOutput=true`, `lastHeartbeat` reset).
  **Line-buffer edges:** the residual line buffer is bounded (a few KB); on
  overflow, any buffered residue BEGINNING WITH `[task-heartbeat]` is discarded
  (same rule as close/error) before the rest flushes into the accumulator as
  ordinary stderr — a split marker can never leak into returned stderr nor flip
  `hasOutput` on the overflow path. On close/error, residual text starting with
  `[task-heartbeat]` (a marker truncated by SIGKILL/crash mid-write) is likewise
  discarded; only non-marker residue flushes into the accumulator — guarantee 6
  holds on the kill and overflow paths too.
- **State:** `toolsInFlight` (count), `turnActive`, `streamAgeMs`, `toolAgeMaxMs`,
  `turnSawMessage`, `turnSawTool` (from ticks — overwrite semantics =
  self-healing), `everSawWork` (latched on first tool_start/turn_start),
  `sawReady` (latched on `ready`), `lastMarkerAt`.
- **Markers are NOT output bytes:** marker lines update the life-sign clock
  (`lastHeartbeat`) but never set `hasOutput` — otherwise the emitter would defeat
  the tier-1 first-output retry (#5926).
- **Tier-1 (first-output, 60s):**
  `!hasOutput && elapsed > FIRST_OUTPUT_TIMEOUT_MS && !everSawWork && !sawReady`
  → retryable undefined (unchanged for process-level startup hangs). `sawReady`
  protects slow-start children (cold MCP connects, slow extension load) that
  already proved initialization — with a healthy ticking emitter they are bounded
  by the stream-stall clause at S (retryable undefined when no real output); the
  silence clause at T applies once markers stop. Note: pi emits turn_start before
  the provider request, so a hung first request latches everSawWork and is handled
  by the first-message backstop below (detection moves from 60s to
  TASK_FIRST_MESSAGE_MS, retryability preserved). Caveat (same limitation tier-1
  has today): stray non-marker stderr bytes (MCP startup logs on `mcp_servers`
  children) set hasOutput and make a later kill defined/non-retryable.
- **Kill clauses (tier-2 replacement).** With T = HEARTBEAT_TIMEOUT_MS,
  S = TASK_STREAM_STALL_MS (default 1200s, clamp ≥ 60s),
  L = TASK_TOOL_STALL_MS (default 6h, clamp ≥ 60s),
  M = TASK_FIRST_MESSAGE_MS (default 300s, clamp ≥ 60s — well above sane TTFT for
  the dispatch models while keeping #5926 detection within ~5 min/attempt;
  trade-off vs legacy 60s documented in guarantee 5),
  stateFresh = `lastMarkerAt > 0 && now - lastMarkerAt <= max(2T, 2 × interval)`
  (the `2 × interval` term prevents a 300s tick interval colliding with a 120s
  2T window). **Clamp parity (explicit):** the parent clamps interval identically
  to the child (5s–300s) and T identically to today (≥ 60s); S, L, M are
  parent-only. A drift test asserts the interval-clamp constants match between
  extensions/task-heartbeat.ts and extensions/builtin-tools/index.ts (precedent:
  the getPiInvocation drift guard in builtin-tools.test.ts):
  1. **silence:** `silence > T && !(stateFresh && turnActive && (toolsInFlight > 0 || streamAgeMs <= S))`
     → reason `silence-threshold`. The tools exemption REQUIRES turnActive — tools
     cannot legitimately be in flight outside a turn, so a desynced counter alone
     can't grant immortality.
  2. **stream-stall:** `toolsInFlight === 0 && streamAgeMs > S && stateFresh`
     → reason `stream-stall`. No turnActive requirement — this also bounds
     between-turn wedges (event loop alive, ticks flowing, nothing progressing),
     which byte-silence detection can never catch. Legit gaps are exempt: every
     turn_start/turn_end/message/tool event resets streamAgeMs.
  3. **tool-stall:** `toolsInFlight > 0 && toolAgeMaxMs > (turnActive ? L : min(L, T)) && stateFresh`
     → reason `tool-stall`. Bounds the desynced-counter + wedged-stream
     combination; generous default (6h) never touches legit long operations.
     The reduced `min(L, T)` bound when `turnActive=false` covers PREFLIGHT-stuck
     children (pi legitimately emits tool_execution_start before any turn — a
     dead MCP server in preflight with a live event loop must be detected at ~T,
     not 6h); preflight tools have no legitimate multi-hour duration.
  4. **first-message:** `turnActive && !turnSawMessage && !turnSawTool &&
     streamAgeMs > M && stateFresh` → reason `first-message-stall`. Restores fast
     detection of the #5926 hung-first-request class (turn started, but no
     message_start / streaming / tool activity ever — only TTFT waiting). A false
     kill here self-heals: with no real output the result is retryable undefined.
- **Kill-result semantics (retry preservation):** any kill fired while `!hasOutput`
  (no REAL output ever arrived) resolves `undefined` — retryable, exactly like
  tier-1 — so the retry wrapper (3 attempts, backoff) and circuit breaker stay live
  for the #5926 model/network-hang class. Kills with partial real output resolve
  the defined partial result as today.
- Kill messages (defined results) report last known alive state (toolsInFlight,
  turnActive, streamAgeMs, toolAgeMaxMs, marker age) separately from the stderr
  tail; `details.reason` distinguishes `silence-threshold` / `stream-stall` /
  `tool-stall` / `first-message-stall`.

### Guarantees

1. Tool call in flight inside a turn → exempt from the silence threshold while
   ticks flow, bounded only by the 6h tool-stall backstop; if markers stop (event
   loop blocked mid-tool), bounded by the stale-state bound max(2T, 2×interval).
2. Model turn in progress with real stream activity → not killed; a wedge with no
   stream activity > TASK_STREAM_STALL_MS IS killed (backstop, retryable when no
   real output ever arrived). A turn that never produces a first message/tool
   event is killed at TASK_FIRST_MESSAGE_MS (retryable when no real output).
3. No emitter loaded / markers absent → exact legacy byte-silence behavior.
4. Wedged child, state set, then zero signs of life → killed at ≤ max(2T, 2×interval).
5. Tier-1 retry + circuit breaker preserved: startup hangs (no markers, no ready)
   retry at 60s; slow-start (ready seen, healthy emitter) bounded by stream-stall
   at S, or silence at T once markers stop — retryable undefined while no real
   output; hung first request (turn_start latched, no message/tool event, no real
   output) is first-message-killed as retryable undefined at M (default 300s —
   slower than legacy 60s detection but retryability/circuit-breaker fully
   preserved). Exit watchdog + provider fallback unchanged. Caveat: stray
   non-marker stderr bytes make kills defined (pre-existing tier-1 limitation).
6. No `[task-heartbeat]` text in any returned content/stderr field (filtered at
   ingestion + truncated-marker residue discarded on close AND on line-buffer
   overflow — structurally guaranteed on every result path, including
   kill/crash).

### High-level E2E cases

E1–E3, E5–E14 are fast unit tests over exported pure logic (fake streams/timers —
the heartbeat decision functions are extracted and exported for this; pattern =
existing tsx + node:assert harness in builtin-tools.test.ts). E4 is the only
real-pi integration test.

- E1: fake stream with `turn_start` + `tool_start` + ticks but zero other output
  past T → NOT killed; resolves normally on exit. (Fixture MUST include
  turn_start: the silence exemption and the L tool-stall bound both require
  turnActive — without it the fixture would be the E10 preflight class.)
- E2: fake stream with output then total silence, no markers → killed at T with
  partial results (legacy behavior preserved).
- E3: fake stream sends `tool_start`, then nothing (no ticks) → killed at ≤
  max(2T, 2×interval) (stale-state bound), not held forever.
- E4 (integration, real pi, gated on DEEPSEEK_API_KEY like
  subagent-e2e-smoke.test.ts — exit-0 skip when absent; that file is the style
  reference): run THROUGH THE ACTUAL TASK TOOL — a parent pi session whose prompt
  dispatches a task sub-agent that runs `sleep 70` as its first action, with
  `TASK_HEARTBEAT_TIMEOUT_MS=60000` in the parent env (#489 ≥60s clamp kept).
  Explicit spawn timeout ≈ 240s (full chain: parent startup/TTFT + dispatch +
  child startup/TTFT + sleep 70 + relay ≈ 2–3 min total). Assertions:
  result contains the sub-agent's answer AND contains none of
  "silence threshold", "failed after 3 attempts", "circuit breaker open"
  (all three are old-code false-pass paths). Discriminating: old code either
  silence-kills mid-sleep (startup stderr → defined partial) or zero-output
  retries ×3 (quiet stderr).
- E5: `turn_start` + an early `message_start` (latches saw_msg so the
  first-message clause cannot preempt), then ticks with rising `stream_age_ms`
  past S, no tools → killed at S, reason stream-stall. (Alternatively keep the
  fixture message-less and set S < M in the test config.)
- E6: `turn_start` + ticks, no real output, rising stream_age_ms → kill resolves
  `undefined` (retryable — #5926 class preserved).
- E7: `turn_start` + `message_update`/`message_start` resets over a duration past
  the stall bound → NOT killed (false-kill protection for streaming work).
- E8: `tool_start`/`tick` markers + clean exit AND non-zero exit AND a
  kill/crash path (fake stream ends mid-marker-line) AND an overflow path (burst
  of chunks filling the residual line buffer mid-marker-line → buffer-full flush
  with residue starting `[task-heartbeat]`) → result content and details.stderr
  contain no `[task-heartbeat]` text on any path, and the discarded fragment does
  not flip `hasOutput`.
- E9: `turn_start` + ticks with `tool_age_max_ms` past L → killed, reason
  tool-stall (desync bound; turn_start required so the L bound — not the
  min(L,T) preflight bound — is the clause under test).
- E10 (turnActive gate on the tools exemption — the cycle-2 P1 regression guard):
  preflight `tool_start` + ticks, NO `turn_start`, no output → killed at
  ~min(L,T), reason **tool-stall** (the fold-2 preflight bound), whether ticks
  stop or keep flowing — tool-stall preempts the silence clause in both cases.
  The tool-less turnActive=false silence path is covered by E11(a)/E12(a).
- E11 (between-turn wedge): `turn_start`/`turn_end` markers then (a) ticks stop →
  killed at T via silence (set T and S so S > max(2T, 2×interval), e.g. T=60s,
  S=1200s, so the stale-state window expires before the stream-stall bound and
  silence fires first), or (b) ticks keep flowing → killed at S via stream-stall
  (keep tick interval < T in the test config so the silence clause cannot fire
  between ticks).
- E12 (sawReady gate), two sub-cases: `ready` marker, no turn_start, no output →
  NOT tier-1-killed at 60s; then (a) ticks stop → killed at ~T, reason
  silence-threshold, undefined (same S > max(2T, 2×interval) config pin as
  E11(a)); (b) ticks keep flowing → killed at S via stream-stall, undefined
  (interval < T in test config).
- E13: `turn_start` + ticks with saw_msg=0 saw_tool=0 and stream_age_ms past M →
  killed, reason first-message-stall, undefined when no real output.
- E14: drift guard — interval clamp constants in extensions/task-heartbeat.ts
  match extensions/builtin-tools/index.ts.

## Complexity

| Domain | Rating | Rationale |
|--------|--------|-----------|
| code | standard | Timer/stream/process-lifecycle concurrency across two extensions; three bounded kill clauses that must neither kill working agents nor hang forever; backward compat when the emitter is absent |

Level: task — single atomic deliverable, no decomposition.

## Review history

- Scope-verify cycle 1: 2×P1 (tier-1 defeat via hasOutput; unbounded stall-hidden
  turn) + 4×P2 → folded (rev 2).
- Scope-verify cycle 2: 1×P1 (tool-counter desync → unbounded exemption) + 5×P2
  → folded (rev 3).
- Scope-verify cycle 3: 0×P0/P1; 8×P2 (unused ready marker → tier-1 sawReady
  gate; truncated-marker residue on kill path; missing turnActive-gate +
  between-turn-wedge tests; #5926 detection latency → first-message backstop
  clause M + stray-stderr caveat; guarantee-1 wording; E4 mechanism through the
  real task tool + DEEPSEEK_API_KEY gate; line-buffer bound; explicit clamp
  parity + drift test) → folded (rev 4).
- Scope-verify cycle 4: 0×P0/P1; 4×P2 (E10/E12 outcomes unreachable while ticks
  flow → ticks-stop / ticks-flow sub-cases + narrative correction; preflight-stuck
  bounded only by 6h tool-stall → min(L,T) bound when turnActive=false; M default
  600s → 300s; E4 false-pass paths + timeout) → folded (rev 5).
- Scope-verify cycle 5: 0×P0/P1; 5×P2 doc-consistency (E10(a) unreachable —
  tool-stall preempts silence at min(L,T) → merged to single tool-stall
  expectation; E1/E9 fixtures must include turn_start since the exemption and L
  bound require turnActive; stale style reference in E2E intro; stale E-test
  enumeration; E11(b) ambiguous parenthetical) → folded (rev 6).
- Scope-verify cycle 6: 0×P0/P1; 3×P2 doc-consistency (E5 unreachable —
  first-message preempts stream-stall → early message_start in fixture or S<M
  config; E11(a)/E12(a) unreachable under defaults → config pin
  S > max(2T, 2×interval); details.reason enumeration missing
  first-message-stall) → folded (rev 7).
- Scope-verify cycle 7: verifier 2 NO ISSUES FOUND; verifier 1 1×P2 (line-buffer
  overflow path could flush a truncated marker fragment → same discard rule
  extended to overflow flush) → folded (rev 8).
- Scope-verify cycle 8: 2×P2 (overflow-discard branch untested → E8 gains an
  overflow fixture incl. hasOutput-flip assertion; guarantee 6 mechanism
  parenthetical stale → now mentions close AND overflow) → folded (rev 9, this
  document).

---

# Implementation Plan (writing-plans stage)

Execution order: T1 → T2 → T3 (red-green alongside T2) → T5 → T4 → T6.
(T4 runs AFTER T5 — E4's child pi must load the emitter from the live
`~/.pi/agent/extensions/` farm, which only exists once T5's wiring is
installed/synced.)
Test runner: `cd extensions/builtin-tools && npx tsx builtin-tools.test.ts`
(66 tests green pre-change — regression baseline). CI hard gates: extension
tests (`extensions/*/test*.mjs`) + script-validate; the .test.ts harness is the
developer gate for this component.

### Task 1: Child life-sign emitter extension

**Intent:** Make child life signs (in-flight tools, active turns, stream
activity) observable to the parent so the silence detector can mean "no signs
of life" instead of "no output bytes" (issue expected behavior).
**Acceptance:**
- `extensions/task-heartbeat.ts` exists, self-contained (only imports the
  `ExtensionAPI` type), exports named helpers used by tests
  (`HEARTBEAT_MARKER_PREFIX`, `clampHeartbeatIntervalMs`, marker formatting)
  plus the default extension factory.
- Inactive unless `TASK_HEARTBEAT=1` AND `PI_MODE=print` AND NOT
  `TASK_HEARTBEAT_DISABLE=1`.
- Emits: `ready` (session_start), `tool_start <id> <name>` / `tool_end <id>`,
  `turn_start <n>` / `turn_end <n>`, and
  `tick tools=<n> turn=<0|1> stream_age_ms=<n> tool_age_max_ms=<n> saw_msg=<0|1> saw_tool=<0|1>`
  every clamped interval (5s–300s, default 30s, TASK_HEARTBEAT_INTERVAL_MS).
- Tool tracking = Set keyed by toolCallId, cleared on turn_end; activity reset
  set = {turn_start, turn_end, tool_execution_start/update/end, assistant
  message_start, message_update}; per-turn flags turnSawMessage/turnSawTool
  reset on turn_start.
- Tick timer `.unref()`ed and cleared on session_shutdown.
- All marker formatting goes through exported formatter helpers (one per marker
  kind) so T3's E14 round-trip test can feed them through the parent parser.
**Files:**
- Create: extensions/task-heartbeat.ts
- Test: extensions/builtin-tools/builtin-tools.test.ts (clamp + marker format
  cases; direct import of the flat extension file — type-only pi import is
  erased by tsx, no mock needed; precedent = extensions/auto-sync.ts +
  auto-sync.test.ts)

### Task 2: Parent state-aware heartbeat in spawnSubAgent

**Intent:** Replace the output-byte-only tier-2 timer with an idle detector
over (tool-in-flight OR turn-active-with-stream-activity OR recent output),
bounded on every wedge path (scope kill clauses 1–4 + tier-1 update).
**Acceptance:**
- New exported pure/testable helpers in extensions/builtin-tools/index.ts:
  `HEARTBEAT_MARKER_PREFIX` (literal, drift-tested vs the child),
  `getHeartbeatIntervalMs` (identical clamp to the child — drift-tested),
  `getStreamStallMs` (default 1200s, ≥60s), `getToolStallMs` (default 6h,
  ≥60s), `getFirstMessageMs` (default 300s, ≥60s), `createHeartbeatState`,
  `parseHeartbeatLine` (complete-line parse → state mutation; returns whether
  the line was a marker; ANY line starting with HEARTBEAT_MARKER_PREFIX that
  fails to parse is still treated as a marker — discarded, never enters the
  accumulator, never sets hasOutput), `flushHeartbeatResidue` (overflow/close
  discard rule; returns whether the flushed residue was marker-prefixed so the
  no-hasOutput-flip assertion is checkable),
  `heartbeatKillDecision` (tier-1 + the four clauses, returns
  `{kill, reason, resolveUndefined}` where resolveUndefined = kill && !hasOutput
  — the retry-preservation contract, expressible in tests; reasons:
  silence-threshold / stream-stall / tool-stall / first-message-stall).
  **Clause precedence (pinned):** evaluation order is tool-stall → stream-stall
  → silence → first-message; when multiple clauses fire in one poll, tool-stall
  wins (E10's settled expectation — tool-stall preempts silence).
- spawnSubAgent: sets `TASK_HEARTBEAT=1` in subAgentEnv (after checking
  `TASK_HEARTBEAT_DISABLE`); stderr data handler line-buffers → markers parsed
  and DISCARDED (never enter the capped accumulator, never set hasOutput;
  bounded residual buffer with overflow discard rule); non-marker bytes keep
  legacy hasOutput/lastHeartbeat effects.
- Tier-1: `!hasOutput && elapsed > FIRST_OUTPUT_TIMEOUT_MS && !everSawWork &&
  !sawReady`.
- Tier-2 replaced by heartbeatKillDecision with stateFresh window
  max(2T, 2×clamped interval); kill-result semantics: any kill with !hasOutput
  resolves `undefined` (retryable); defined kills carry details.reason from the
  four-value set and an alive-state summary in the message text.
- Before composing ANY kill result, `flushHeartbeatResidue` runs: non-marker
  residue appends to the accumulator (preserves today's kill-result fidelity —
  the last partial stderr line is often the most informative), marker-prefixed
  residue is discarded.
- The `HEARTBEAT_TIMEOUT_MS` computation stays the byte-identical inline
  expression `Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) ||
  1_800_000)` — existing regression test #5954 pins that exact source literal;
  it is consumed as an input by heartbeatKillDecision, not extracted into a
  getter.
- File-header tier comment updated.
**Files:**
- Modify: extensions/builtin-tools/index.ts
- Test: extensions/builtin-tools/builtin-tools.test.ts

### Task 3: Unit tests (E1–E3, E5–E14)

**Intent:** Prove every kill clause, every exemption, every guarantee boundary,
and the no-marker-leak property — the regression surface of this change.
**Acceptance:** `npx tsx builtin-tools.test.ts` green with the 66 pre-existing
tests unchanged plus new cases covering:
- E1 (turn_start + tool_start + ticks past T → not killed),
  E2 (legacy silence preserved), E3 (stale-state bound ≤ max(2T, 2×interval)),
  E5 (stream-stall at S; fixture with early message_start),
  E6 (stall kill with no real output → undefined),
  E7 (message_start/message_update resets survive past S),
  E8 (no [task-heartbeat] text on clean / non-zero / kill-crash / overflow
  paths; discarded fragment does not flip hasOutput),
  E9 (tool-stall at L, turnActive), E10 (preflight tool-stall at min(L,T);
  fixture keeps at least one tick after tool_start so the clauses cannot
  coincide at the first poll — precedence is pinned in T2 regardless),
  E11 (between-turn wedge: ticks-stop → silence at T with S > max(2T,2×interval)
  pin; ticks-flow → stream-stall at S),
  E12 (sawReady gate: no tier-1 kill at 60s; a/b sub-cases like E11),
  E13 (first-message-stall at M → undefined without real output),
  E14 (drift guard: (a) marker prefix + interval clamp constants identical
  between task-heartbeat.ts and builtin-tools/index.ts; (b) FULL-FORMAT
  round-trip — feed each child formatter's output through parent
  parseHeartbeatLine and assert the resulting state, making tick field names,
  argument order, and turn numbering drift-proof; pattern = existing
  getPiInvocation drift test).
- Child-emitter behavior tests (fake-pi harness, EventEmitter-fake pattern):
  invoke the default factory with a stub ExtensionAPI recording `on()`
  handlers; drive stub events; assert emitted marker strings, gating matrix
  (TASK_HEARTBEAT=1 ∧ PI_MODE=print ∧ ¬DISABLE — all combos), `ready` on
  session_start, Set-keyed tool semantics (tool_start ×2 + tool_end ×1 →
  tick tools=1; turn_end clears → tools=0 — the cycle-2 P1 desync fix),
  activity-reset set coverage, per-turn flag resets on turn_start, tick field
  values, and timer cleanup on session_shutdown.
**Files:**
- Test: extensions/builtin-tools/builtin-tools.test.ts

### Task 4: Integration test E4 (real pi, through the real task tool)

**Intent:** Prove end-to-end that a long-running tool call with zero output is
no longer killed — discriminating old vs new behavior through the actual
dispatch path.
**Acceptance:** new case in extensions/builtin-tools/subagent-e2e-smoke.test.ts:
DEEPSEEK_API_KEY gate (exit-0 skip); PRE-CHECK that the live farm contains the
emitter (`~/.pi/agent/extensions/task-heartbeat.ts` exists) implemented as a
PER-CASE skip — mechanism pinned: E4's precheck throws a module-local
`SkipError` sentinel; the `test()` wrapper catches it and increments
`skipped++` + prints `⏭️` (NOT `passed++`/✅); `run()` appends the skipped
count to the summary (`${passed} passed, ${failed} failed, ${skipped}
skipped`) and exits 0 when failed === 0 regardless of skipped — NOT a
file-level process.exit(0) gate, so the pre-existing smoke case still runs on
unwired machines; parent pi
session prompted to dispatch a task sub-agent whose first action is `sleep 70`;
parent env carries TASK_HEARTBEAT_TIMEOUT_MS=60000; spawn timeout ≈ 240s
(spawnPi's third param); asserts result contains the sub-agent's answer and
NONE of "silence threshold", "failed after 3 attempts", "circuit breaker
open".
**Files:**
- Test: extensions/builtin-tools/subagent-e2e-smoke.test.ts

### Task 5: Wiring + pre-existing drift repair

**Intent:** The emitter ships on every machine (both bootstrap paths) and the
drift gate runs green so it actually enforces the new entry.
**Acceptance:**
- Symlink pi-bootstrap/pi-config/extensions/task-heartbeat.ts →
  ../../../extensions/task-heartbeat.ts
- Symlink pi-bootstrap/pi-config/extensions/custom-provider-qwen →
  ../../../extensions/custom-provider-qwen (pre-existing drift repair)
- manifest.json files["extensions/"].entries gains "task-heartbeat.ts"
- `bash scripts/check-pi-config-extensions.sh` exits 0
- **Live farm refresh (E4 prerequisite) — TARGETED, not a full installer run:**
  create only the missing entry
  `ln -s "$INFRA_ROOT/extensions/task-heartbeat.ts" ~/.pi/agent/extensions/task-heartbeat.ts`
  (absolute-link style matching the farm). Do NOT run `node bin/agent-infra.js
  update` or `bash pi-bootstrap/setup.sh` — the live farm contains a divergent
  materialized `cmux-session.ts` (1519 lines, uncommitted local work) that a
  full installer run would delete/overwrite. Repo-side wiring (manifest entry +
  pi-config symlink) ensures future installer runs pick the emitter up.
**Files:**
- Create: pi-bootstrap/pi-config/extensions/task-heartbeat.ts (symlink)
- Create: pi-bootstrap/pi-config/extensions/custom-provider-qwen (symlink)
- Modify: manifest.json

### Task 6: Verification + docs

**Intent:** Proof-of-work before completion.
**Acceptance:** full builtin-tools test suite green; drift gate green;
git diff confined to planned files; scope doc Status → IMPLEMENTED; plan
commit/PR reference issue #176.
**Files:**
- Modify: docs/plans/2026-08-11-issue-176-heartbeat-alive-signals.md (status)

## Plan-review history

- Plan-verify cycle 1: 1×P1 (E4 ran before live-farm wiring — reordered T4
  after T5; T5 gains live farm refresh + E4 precheck) + 5×P2 (kill decision
  returns resolveUndefined + flushHeartbeatResidue contract; child emitter
  fake-pi harness tests; parse-failure discard rule + E14 full-format
  round-trip; kill-path residue flush preserves fidelity; #5954 inline literal
  preserved) → folded (plan rev 2).
- Plan-verify cycle 2: 1×P1 (full installer run would clobber the divergent
  materialized cmux-session.ts in the live farm → T5 refresh is now a targeted
  single symlink) + 2×P2 (clause precedence pinned: tool-stall → stream-stall →
  silence → first-message; E4 precheck is a per-case skip with a `skipped`
  counter, not a file-level gate; E10 fixture keeps ≥1 tick after tool_start)
  → folded (plan rev 3).
- Plan-verify cycle 3: verifier 1 NO ISSUES FOUND; verifier 2 1×P2 (per-case
  skip mechanism underspecified — naive early-return would count the skip as a
  pass → pinned SkipError sentinel caught by the test wrapper, skipped counter
  in summary, exit 0 when failed === 0) → folded (plan rev 4).

## Code-review history (PR #177)

- Review dispatch: bug-scan (shallow+deep) + extension-safety/integration +
  security (threat-model) — 3 parallel reviewers. Result: 0 P0/P1, 10 P2.
- Fixed in follow-up commit:
  1. Mid-line marker merge (unterminated foreign fragment + marker) → split in
     ingestHeartbeatChunk; head preserved, marker part parsed/discarded.
  2. Tick number overflow (Number → Infinity) → non-finite values skipped.
  3. Stale tool counter after turn_end → parent mirrors child's turn_end clear
     (toolsInFlight = 0).
  4. Unknown-kind prefix lines → preserved as ordinary stderr (no state, no
     freshness) instead of silently discarded.
  5. Wedged-child latency (frozen tick ages) → stall clauses use effective age
     (state age + time since last marker).
  6. Unauthenticated marker channel (MCP servers inherit the child's fd 2;
     ambient TASK_HEARTBEAT=1) → per-dispatch nonce (TASK_HEARTBEAT_NONCE,
     randomBytes(6)): child echoes it in every marker; parent rejects
     mismatches as foreign.
  7. Unbounded total dispatch time (honest drip-stream/tool-loop) → opt-in
     TASK_MAX_DISPATCH_MS cap (default 0 = off, issue semantics preserved),
     clause "max-dispatch".
- Documented/accepted:
  8. Tier-1 60s fast-fail neutralized for emitter-equipped children (hung
     first request detected at TASK_FIRST_MESSAGE_MS=300s instead) — settled
     scope trade-off; comment added at the first-message clause.
  9. >4KB unterminated stderr line re-chunking — cosmetic display delta vs
     legacy; marker discard semantics unaffected.
  10. mcp-client `stderr: "pipe"` hardening — separate extension, filed as
      follow-up (nonce closes the #176 attack surface).
- Re-verified after fixes: 106/106 unit tests, E4 e2e green, nonce confirmed
  flowing in real pi child.
- Fix-confirmation round 2 (post-8db93a3): 3 residual P2s found and fixed:
  11. E8 merged-line test never exercised the split branch (chunks formed two
      lines) → true cross-chunk merge fixture + forged-nonce merged variant +
      ANSI-decorated marker fixture.
  12. ANSI-decorated marker lines hit the split branch (decoration flushed as
      real stderr → hasOutput flip) → isDecoratedMarker check routes them to
      the pure-marker path.
  13. Nonce leaked to MCP servers via the env spread (mcp-client passes
      {...process.env} to stdio servers; SDK default stderr:"inherit") — the
      named attacker held both nonce and write path → buildMcpServerEnv()
      scrubs TASK_HEARTBEAT_NONCE (unit-tested in resolution.test.ts).
  Re-verified: 107/107 builtin-tools tests, 12/12 mcp-client tests, E4 green.
