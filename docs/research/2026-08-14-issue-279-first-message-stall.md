---
title: "Research: #279 — first-message-stall cuts LIVE sub-agents in startup-heavy repos (mechanism + evidence)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-279, builtin-tools, task-heartbeat
---

# Research: #279 — first-message-stall cuts LIVE sub-agents in startup-heavy repos

> **Findings date:** 2026-08-14 (afternoon, agent-infra repo, branch feat/279-first-message-stall)

## Strategy Alignment Decision

**Feature:** #279 — task sub-agent first-message-stall watchdog must not cut demonstrably-working sub-agents.
**Decision:** PROCEED

**Alternatives considered:**
1. Env workaround docs (`TASK_FIRST_MESSAGE_MS` / `TASK_MAX_DISPATCH_MS` per repo) — rejected: unmanaged per-repo config; the default path already burned 3 dispatches on #265.
2. Widen the static M (300s → 600/900s) — rejected: treats the symptom; a quiet verdict turn after real tool work can exceed ANY static bound; weakens the hung-first-request detection the clause exists for (#5926 class).

**Adversarial challenges:**
- *"Does #271 (cut clause) + #272 (load scaling) already fix it?"* — Partially. Load scaling covers the load≥8 case (bound 300→600/900s) and #272's monotonic latch prevents post-storm re-cuts. But a quiet verdict turn under load <8 with a slow provider still exceeds M; and the per-LLM-call `turn_start` flag reset (verified against pi-agent-core) means NO static bound can distinguish "working" from "hung" for later turns. The #220 decision-function exemptions exist but are defeated end-to-end by the state-population gap.
- *"Does a marker-staleness gate weaken hung-provider detection?"* — No. A never-worked branch preserves genuine first-request hang detection at M; later-turn hangs fall to stream-stall (S=20min, deliberate reviewed bound) and the hard cap (2h default). The #208 drip hazard remains bounded by maxDispatch (opt-in) + hard cap. No unbounded-wait regression.

**Eisenhower placement:** Q1 (Important + Urgent). Reliability bug that destroys live work (3 lost dispatches on #265); recurs on every startup-heavy dispatch; small fix + tests.

**Profit impact:** indirect — internal dispatch reliability; each incident costs ~3 lost dispatches (hours of re-run + LLM cost); the fix unblocks #265-class startup-heavy work.

**Key assumptions:**
- A working sub-agent's quiet windows between tool rounds / before verdicts exceed M only under startup-heavy or slow-provider conditions — confidence: high (3 real incidents, consistent 415–472s cuts).
- Later-turn provider hangs are rare enough that S=20min + hard cap is an acceptable detection latency vs. false-cutting live work — confidence: high (#198/#208 design intent: "never kill a working agent").
- The child emitter (`task-heartbeat.ts`) keeps firing ticks independently of the LLM call (setInterval in the extension) — confidence: high (code-verified; ticks are emitted on a timer, not on stream events).

## Research questions → findings

### RQ1: Why doesn't the sub-agent's first tool round populate `turnSawTool`/`toolsInFlight`?

**Answer: it does — but the per-turn reset erases it before the verdict turn.**

Traced end-to-end:

1. **pi's agent loop emits `turn_start`/`turn_end` PER LLM CALL, not per session** (pi-agent-core `dist/agent-loop.js`):
   - `runAgentLoop()` / `runAgentLoopContinue()` emit `agent_start` + `turn_start` before the loop.
   - `runLoop()` inner loop: `if (!firstTurn) await emit({ type: "turn_start" })` — fires again for every subsequent LLM call (after each tool round completes).
2. **The child emitter resets the activity flags on every `turn_start`** (`extensions/task-heartbeat.ts` L221-227): `turnSawMessage = false; turnSawTool = false`.
3. **Tool-first flow:** turn 1 = LLM call with tool calls → `tool_execution_start` → `turnSawTool=true`, `toolsInFlight=1`, tool_start marker → tools execute → turn_end (child clears its outstanding-tools map). Turn 2 = verdict LLM call → `turn_start` **resets both flags** → model generates with zero tokens for >M → first-message clause fires despite fresh heartbeats and demonstrable prior work.
4. **The parent's decision function is fine** (`extensions/builtin-tools/index.ts` L1119-1125): the clause exempts `turnSawTool` and `toolsInFlight>0` (#220). The gap is upstream: the per-turn reset means neither flag survives from the tool round into the verdict turn.

The #265 evidence fits this exactly: "read project-workflow + commit-workflow → cut at 453s" = tool round (turn 1) completed, verdict generation (turn 2) silent > M. `lastMarkerAgeMs` FRESH because the tick timer runs in the extension, independent of the LLM call.

### RQ2: `loadScaledBound` direction — does load scale the bound UP?

**Verified: YES — scales UP, and 300s is the base/floor, not the ceiling.**

`loadScaledBound(baseMs, load)`: load < 8 → 1×; 8–15 → 2×; ≥16 → 3×. Effective M = 300s base, 600s mid-band, 900s ≥16 load. `getFirstMessageMs()` = max(60s, `TASK_FIRST_MESSAGE_MS` || 300s). #272 additionally made it per-tick and monotonic (latched high-water mark — a storm that starts mid-dispatch extends the bound; a post-storm drop never re-cuts). Tested by the E15/E15b/E16 series. **No change needed** — this part of the issue is already implemented.

### RQ3: Can a marker-staleness gate be added without reintroducing the #208 unbounded-drip hazard?

**Yes — a single gate suffices: fire first-message-stall only when the session NEVER saw real activity (`!everSawRealActivity`).**

The clause already carries `stateFresh &&` as a hard precondition (index.ts L1120) — a stale-marker child is already exempt from this clause today (effStreamAge's markerAge growth only applies within the fresh window). Adding `!stateFresh ||` as an extra disjunct would be dead code. The staleness semantics the issue asks for ("cut requires marker staleness") are already baked into the existing precondition; the NEW gate adds the missing half: "never cut a session that has demonstrably worked".

Safety analysis:
- **Fresh markers + activity latched → never cut.** The quiet verdict turn is bounded by stream-stall (S=20min) and the hard cap (2h default) — both deliberate, reviewed bounds. No unbounded wait.
- **Fresh markers + never worked → cut at M (unchanged).** Preserves the clause's original purpose: a hung FIRST provider request with no message/tool activity (#5926 retryable-undefined class).
- **Stale markers → clause inert (existing behavior, precondition L1120).** Wedged-quiet falls to stream-stall (S, while markers fresh) / silence (T) / backstop (6h30m). The cut clause (#271) catches the tools-in-flight wedge at 37.5s.
- **#208 drip hazard:** a pathological tool-looping/drip child is never cut by first-message once activity latches — but it is bounded by tool-stall (L=6h per tool), stream-stall (S=20min between tools), silence (T=30min without life signs), the hard cap (2h default), and maxDispatch (opt-in tighter cap, the issue's named backstop). Identical exposure to the #198/#220 intent ("never kill a working agent"); the maxDispatch opt-in remains the tighter backstop.

**Parent-side latch suffices — no child/format change needed:** the parent can latch `everSawRealActivity` from signals it already receives — `tool_start` markers, and ticks carrying `saw_msg=1` / `saw_tool=1` / `tools>0`. The latch is monotonic (never reset), so turn resets in the child can't erase it. No marker-format change → the E14 drift test is unaffected.

**Why NOT reuse `everSawWork`:** `everSawWork` latches on `turn_start` markers too (index.ts L823), and the emitter fires `turn_start` BEFORE the first provider call (index.ts L1108-1110: "ready/turn_start latch before any provider call"). Reusing it would mark every session as worked at session start → hung-first-request detection (#5926) would be silently disabled. `everSawRealActivity` is deliberately NOT latched by a bare `turn_start` — only by tool_start markers and tick `saw_msg`/`saw_tool`/`tools>0`. The distinct name prevents a future implementer from "simplifying" to the wrong field.

## Proposed fix (scoped)

1. **`HeartbeatState.everSawRealActivity: boolean`** (new, default false, monotonic latch, never reset). NOT latched by bare `turn_start` (that would defeat hung-first-request detection — see RQ3).
2. **`parseHeartbeatLine`**: latch on `tool_start`; latch on `tick` when `saw_msg=1 || saw_tool=1 || tools>0`.
3. **First-message clause** (index.ts L1119-1125): add `!st.everSawRealActivity` to the conditions (the clause's existing `stateFresh &&` precondition already covers staleness; a `!stateFresh ||` disjunct would be dead code) with a comment citing #279/#198/#208. This prevents the frozen-state turn-transition kill: a tool round latches activity; the quiet verdict turn (or frozen streamAge at turn transition) is never cut; stream-stall (S) + hard cap (2h) own the genuine hang.
4. **Diagnostics**: include `everSawRealActivity` in ALL FOUR alive-summary sites — hard-cap (L1363), cut-composition (L1440), heartbeat-kill (L1514), backstop (L1561) — plus fix the kill headline (L1519) to print the EFFECTIVE bound (`decision.firstMessageMs`) instead of the base `hbThresholds.firstMessageMs` (the 905s cut displayed "bound 300s" under a latched 900s bound — display bug folded into this scope).
5. **Tests** (builtin-tools.test.ts, E279 series):
   - E279a: worked session (everSawRealActivity=true via tool_start) + fresh markers + turnActive + turnSawMessage=false + turnSawTool=false + toolsInFlight=0 + streamAgeMs>M → NOT killed (the regression boundary; pinned via the frozen-state construction: tool round tick leaves streamAgeMs>M, then tool_end → turn_start → quiet → no cut).
   - E279b: never-worked (everSawRealActivity=false) + fresh markers + same quiet state → killed first-message-stall (preserved; doubles as the #5926-preservation guard — a future implementer latching on turn_start would fail this test).
   - E279c: latch-on-tool_start (parse-level: tool_start marker sets everSawRealActivity).
   - E279d: latch-on-tick (saw_msg=1, saw_tool=1, tools>0 each latch).
   - E279e: lost-tool_start-recovered-by-tick — tool_start marker lost (never parsed), but a subsequent tick with tools=1 latches → quiet verdict not cut (pins the tick backstop for the marker-loss residual).
   - Regression: E13/E15/E15b/E16 stay green.

## Raw Notes

- 2026-08-14 ~13:30 — read issue #279 body; evidence: 3 task dispatches on #265 cut at 415–472s with "no first message/tool activity (bound 300s)", markers fresh, one with toolAgeMaxMs 863s (issue's timestamps internally inconsistent — 863s tool age at a 453s cut is impossible; treated evidence as approximate).
- 2026-08-14 — verified #271 (cut clause, 1a3a7b4) + #272 (load scaling, a819f91) landed 2026-08-14 05:16/04:34 UTC — BEFORE #279 filed 11:56 UTC; the issue's quoted clause (`i.firstMessageMs`) and line numbers (1005-1013) are pre-#272. Evidence predates current code.
- 2026-08-14 — pi-agent-core dist/agent-loop.js: `turn_start` emitted per LLM call (`if (!firstTurn) emit turn_start`); first turn_start from runAgentLoop/runAgentLoopContinue.
- 2026-08-14 — task-heartbeat.ts L221-227: turn_start resets turnSawMessage/turnSawTool; turn_end clears outstandingTools.
- 2026-08-14 — index.ts L1119-1125 first-message clause: exemptions `!(st.turnSawTool || st.toolsInFlight > 0)` present (#220); missing staleness/activity gate = the #279 gap.
- 2026-08-14 — defaults: M=300s (DEFAULT_FIRST_MESSAGE_MS), S=1200s (stream-stall), L=21600s (tool-stall), T=30min heartbeat, hard cap 2h, maxDispatch off, cutGap 37.5s. loadScaledBound: 1x/2x/3x at load <8/8-15/≥16.
- 2026-08-14 — E13 (builtin-tools.test.ts L1392): covers saw_tool + toolsInFlight exemptions + hung-tool-still-cut; new gate `!st.everSawRealActivity` keeps E13 green (default state has everSawRealActivity=false).
- 2026-08-14 — research-gate cycle 1 (fresh reviewer): P1-1 `!stateFresh` disjunct is dead code (clause already has `stateFresh &&` precondition L1120) → gate simplified to `!st.everSawRealActivity`; P2-1 renamed latch to `everSawRealActivity` + documented why `everSawWork` (turn_start-latched, pre-provider-call) can't be reused; P3-1 alive summaries enumerated at all FOUR sites (hard-cap L1363, cut-composition L1440, heartbeat-kill L1514, backstop L1561). Fixed in doc.
- 2026-08-14 ~16:00 — **EVIDENCE GAP CLOSED (problem-verify):** raw cut partials recovered from session logs (~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-agent-infra--/, 2026-08-12→14). DISTINCT real first-message-stall cuts: **5** (482s pre-#220 class with toolsInFlight=1 — the #198/#220-fixed class; 445s, 472s, 415s, 453s — the quiet-verdict class). The issue's "3 failures" undercounts ~2×. The "45+ at bound 300s" figure is a GREP ARTIFACT (source-code echoes of the alive-summary template + issue-body quotes); verified real count = 5.
- 2026-08-14 ~16:00 — **MECHANISM SHARPENED (frozen-state turn-transition kill):** the kill fires at the TURN TRANSITION, not during a long quiet turn. Last tick DURING the tool round carried `streamAgeMs>M` (frozen — tool_start was the last activity); `tool_end`/`turn_end`/`turn_start` markers never reset `streamAgeMs`/`toolAgeMaxMs` (verified parse: those cases don't touch them); turn_start sets turnActive=true + resets saw-flags; the next 10s heartbeat decision kills on `effStreamAge = frozen streamAgeMs + fresh markerAge > M` — often SECONDS after turn_start (lastMarkerAgeMs ≤9.2s at cut). This explains the raw signatures exactly: `toolAgeMaxMs==streamAgeMs` (tool round where tool_start was last activity) and cut D's `toolAgeMaxMs=863142 > streamAgeMs=452897` (a longer tool round with intervening message activity — NOT an in-flight tool at cut; `toolsInFlight=0` is authoritative). The issue's "tool call in flight 14+ min" reading is a MISREAD. The tick code is unchanged Aug 11→14 (git-verified); no "old-code artifact" — it is a parent-side cross-marker frozen-state merge.
- 2026-08-14 — a REAL cut at 905s exists under a latched 3× bound (load≥16, #272 review session): the headline printed "(bound 300s)" because it reads `hbThresholds.firstMessageMs` (base), not the effective bound — a display bug folded into the #279 diagnostics scope. The 905s cut also demonstrates that load-scaling M alone (without the activity latch) is insufficient.
- 2026-08-14 — confirmed the #279 class resolves DEFINED partials (hasOutput=true via non-marker startup stderr → `resolveUndefined=false`) → does NOT feed the session-level circuit breaker (3× undefined strikes); no ×3 retry amplification for this class (circuit-breaker interplay resolved).
- 2026-08-14 — residual risks recorded: (a) stream `"start"`-event semantics (connection-open vs first-chunk) unverified — fix invariant to either, PM-1 acceptance judged on first-chunk semantics; (b) never-worked slow first call under load<8 remains cuttable at M (accepted: indistinguishable from hung, #5926 preservation); (c) marker loss during the first tool round (line-buffer overflow) would miss the latch — fix does NOT improve marker robustness; the tick backstop (`saw_msg/saw_tool/tools>0`) + diagnostics are the designed triage path.
- 2026-08-14 — research-gate cycle 1 (fresh reviewer): P1-1 `!stateFresh` disjunct is dead code (clause already has `stateFresh &&` precondition L1120) → gate simplified to `!st.everSawRealActivity`; P2-1 renamed latch to `everSawRealActivity` + documented why `everSawWork` (turn_start-latched, pre-provider-call) can't be reused; P3-1 alive summaries enumerated at all FOUR sites (hard-cap L1363, cut-composition L1440, heartbeat-kill L1514, backstop L1561). Fixed in doc.
