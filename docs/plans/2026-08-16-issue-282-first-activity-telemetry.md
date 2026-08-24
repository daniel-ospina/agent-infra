---
title: "Plan: #282 — first-message-stall kills need time-to-first-activity triage"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-282, builtin-tools, task-heartbeat
---

<!-- research-path: in-repo source + session-log evidence only (no external research —
diagnostics + log sweep, no novel pattern, no third-party deps; mechanical trigger
absent). Code: extensions/builtin-tools/index.ts (HeartbeatState L737-779,
parseHeartbeatLine L805-925, kill composition L1590-1625, alive summaries
L1451/1531/1605/1652), extensions/task-heartbeat.ts (marker format), session logs
~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-agent-infra*--/*.jsonl.
Prior evidence: docs/plans/2026-08-14-issue-279-first-message-stall-plan.md
(verification step 5 = the log-sweep precedent this issue extends). -->

# fix: first-message-stall kills need time-to-first-activity triage (#282)

**Goal:** After #279, every first-message-stall kill is by construction a never-worked
(parent-unobservable-activity) session — but "never-worked" conflates "genuinely hung
provider" with "slow pre-activity thinking on startup-heavy dispatches", observationally
identical at cut time. Deliverables: (1) a `[task]` diagnostic line on first-message-stall
kills recording the run's tick/marker history so a cut can be triaged; (2) a log-sweep of
session logs measuring time-to-first-activity on successful dispatches to size the
slow-thinking tail (the M-cut trade rests on "0 of 5 recovered cuts were never-worked" —
small sample).

**Team:** organisation-design-team
**Status:** PLANNED
**Level:** task | **Complexity:** micro (confirmed)

---

## Scope (acceptance criteria)

1. First-message-stall kills emit a `[task]` diagnostic stderr line recording the run's
   tick/marker history — tick count, first-tick lag, saw_msg/saw_tool/tools evolution —
   so a cut can be triaged into "genuinely hung provider" vs "slow pre-activity thinking".
2. The partial's alive summary (all kill-composition sites) exposes the same tick/marker
   history fields. Additive only — no field removal, no format break (E279f loose regex
   must stay green).
3. A reproducible log-sweep (scripts/, runnable with npx tsx) measures time-to-first-activity
   (first message + first tool call) on successful dispatches from the session JSONL logs
   in ~/.pi/agent/sessions/ (agent-infra cwd slugs: main + worktree dirs).
4. New E282 tests pin parse-level instrumentation + source-level diagnostic presence.
5. Zero behavior change to kill semantics; no wire-format change, no child-side change,
   no env surface.

## Implementation approach

### (a) Diagnostics — extensions/builtin-tools/index.ts (additive)

**New `HeartbeatState` fields (session-level, monotonic — never reset by turn resets):**

| Field | Set where | Meaning |
|---|---|---|
| `markerCount: number` | top of `parseHeartbeatLine` (every valid marker) | marker history density |
| `tickCount: number` | `tick` case | tick count (30s LLM-independent backstop) |
| `firstMarkerAt: number` (0=none) | first valid marker | first-marker lag anchor |
| `firstTickAt: number` (0=none) | first `tick` | first-tick lag anchor |
| `everSawMsg: boolean` | tick post-switch latch block (`turnSawMessage` → session latch) | message activity ever seen |
| `everSawTool: boolean` | `tool_start` + tick `saw_tool=1` | tool activity ever seen |
| `firstActivityAt: number` (0=none) | same sites as `everSawRealActivity` | time-to-first-activity anchor |
| `toolsMaxInFlight: number` | `tool_start` + tick `tools` field | tools high-water mark |
| `activityTrace: string[]` | every marker, capped at 8 (first-N) | the evolution: e.g. `[ready, turn_start, tick, tick]` |

Bounded memory: trace capped at first 8 entries; counters are O(1). `everSawMsg`/`everSawTool`
are session latches distinct from the per-turn `turnSawMessage`/`turnSawTool` (which reset on
turn_start) — they answer "did this run EVER produce activity".

**Composition changes (kill path, L1590-1625):**
- Extend the shared aliveSummary template (all 4 sites — hard cap L1451, backstop L1531,
  kill composition L1605, backstopFire L1652) with the new fields, computed from state +
  `startedAt` (in scope in the interval callback):
  `tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstTickLagMs=${firstTickLagMs} everSawMsg=${...} everSawTool=${...} toolsMaxInFlight=${...} trace=[${hbCtx.state.activityTrace.join(",")}]`
  where `firstTickLagMs = firstTickAt > 0 ? firstTickAt - startedAt : -1` (same for first-marker lag).
- On `first-message-stall` kills only, emit the issue's named `[task]` diagnostic line:
  `[task] first-message-stall diagnostic: elapsedMs=<streamAge>s tickCount=<n> markerCount=<n> firstTickLagMs=<ms> everSawMsg=<bool> everSawTool=<bool> toolsMaxInFlight=<n> trace=[<kinds>] (bound=Ms)`.

### (b) Log-sweep — scripts/time-to-first-activity-sweep.ts

Session-log structure (verified): each session JSONL has a `session` event (spawn ts), then
`message` events (`role: user|assistant|toolResult`; assistant content has `thinking` +
`toolCall` blocks; `toolCall name="task"` = a dispatch; toolResult carries `isError`).
The task tool spawns the child as `pi -p ... --no-session <prompt>` → **the child's first
user message is EXACTLY the parent's `arguments.prompt`** (verified in the task tool spawn
args, L2104) → exact pairing by prompt hash.

Procedure:
1. Scan all `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-agent-infra*--/*.jsonl`.
2. Pass 1: collect every `task` toolCall {promptSha, ts, callId} and its toolResult
   {callId, isError, ts} → dispatch outcome.
3. Pass 2: per session log, hash the first user message; match to a dispatch → child.
   Measure T0 = session spawn ts → firstMsgAt (first assistant message w/ content) and
   firstToolAt (first assistant message w/ toolCall).
4. Stats over SUCCESSFUL dispatches (toolResult.isError === false): n, p50/p90/p95/p99/max
   of time-to-first-message and time-to-first-tool; tail counts ≥300s (M), ≥600s, ≥1200s.

### (c) Tests — extensions/builtin-tools/builtin-tools.test.ts (E282 series)

- **E282a (parse-level, never-worked)**: `ready → turn_start → tick(0,0,0) → tick(0,0,0)`
  → assert tickCount=2, markerCount=4, firstMarkerAt/firstTickAt set, everSawMsg=false,
  everSawTool=false, firstActivityAt=0, toolsMaxInFlight=0, trace=[ready,turn_start,tick,tick].
- **E282b (parse-level, activity evolution)**: tick `saw_msg=1` → everSawMsg=true +
  firstActivityAt set; `tool_start` → everSawTool=true + toolsMaxInFlight=1; tools=2 tick →
  high-water 2; turn_start does NOT reset the latches/counters (monotonicity).
- **E282c (source-scan, E279f precedent)**: index.ts contains the `[task] first-message-stall
  diagnostic:` line with tickCount/firstTickLagMs/trace fields; every `Alive state:` template
  exposes `tickCount=` + `trace=`.

## Verification plan

1. `npx tsx extensions/builtin-tools/builtin-tools.test.ts` from the WORKTREE ROOT — all
   pass incl. E282 series + E279f regression.
2. Run `npx tsx scripts/time-to-first-activity-sweep.ts` on the real session logs — record
   the time-to-first-activity distribution (n, percentiles, tail counts) in the plan doc +
   PR description.
3. Typecheck via the suite run (tsx transpiles; interface changes verified by the test
   compile + `npx tsc --noEmit` if available in this repo).

## Risks & mitigations

- **Field proliferation in aliveSummary**: 4 template sites get 8 new fields — mechanical,
  additive; E279f's loose regex (`.*?` between prefix and lastMarkerAgeMs) unaffected;
  tests pin the presence.
- **Prompt-hash pairing misses**: if a child's first user message is wrapped by a layer the
  task tool doesn't control, matching falls back to timestamp-window pairing (reported as
  "unpaired" — never silently wrong numbers). Sweep reports the pairing hit-rate.
- **Slow-tail mis-sizing**: sweep covers only agent-infra dispatch populations (the
  startup-heavy class that motivated #279) — the right population for the M-cut trade.
- **Cut sessions in the sweep**: toolResult.isError=false filters to successful dispatches;
  retryable-undefined cuts (isError with no content) are excluded from the success stats and
  counted separately.

## Acceptance mapping

| # | Criterion | Evidence |
|---|---|---|
| AC1 | `[task]` diagnostic line on first-message-stall kills with tick/marker history | E282c (source pin); partial text |
| AC2 | alive summaries expose tickCount/firstTickLagMs/trace | E282c |
| AC3 | log-sweep script measures time-to-first-activity on successful dispatches | script + findings in this doc |
| AC4 | E282 series green + full suite green (E279f untouched) | verification step 1 |
| AC5 | no behavior change / no wire-format change / no child-side change | additive-only diff |
