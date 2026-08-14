---
title: "Plan: #279 — task sub-agent first-message-stall — everSawRealActivity gate + frozen-age transition reset"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-279, builtin-tools, task-heartbeat
---

<!-- research-path: in-repo source + incident evidence only. Research docs:
docs/research/2026-08-14-issue-279-first-message-stall.md (mechanism, 5 recovered cuts,
frozen-state turn-transition kill) + docs/research/2026-08-14-issue-279-first-message-stall-alternatives.md
(4-approach diverge). Code: extensions/builtin-tools/index.ts (clause L1119-1126,
HeartbeatState L726-747, createHeartbeatState L745-758, parseHeartbeatLine L790-857,
alive summaries L1363/1440/1514/1561, headline L1519, defaults L572-595) +
extensions/task-heartbeat.ts (child emitter). Docs: docs/ops/load-policy.md §6 (watchdog section). -->

# fix: task sub-agent first-message-stall cuts LIVE sub-agents — gate the clause on everSawRealActivity + kill the frozen-age transition cut — implementation plan (#279)

**Goal:** The first-message-stall watchdog (M=300s base) must never cut a sub-agent that has demonstrably done real work (fresh heartbeats + prior tool/message activity), while preserving hung-FIRST-request detection at M (#5926). Targets: 0 first-message-stall partials on worked sessions (the #265 class, 5 recovered cuts); 0 stream-stall partials on frozen-age turn transitions (nested-task class); hung-first-request retryable-undefined detection unchanged.

**Team:** organisation-design-team
**Status:** CONVERGED + PLANNED + REVIEWED-CYCLE-1 (devil's advocate P1s incorporated — plan hardened)
**Level:** project | **Complexity:** standard (confirmed)

---

## Decision summary

**Chosen: Approach A — parent-side monotonic `everSawRealActivity` latch gating the first-message clause, PLUS two hardening fixes surfaced by the Phase-7 devil's advocate (P1-1, P1-2).**

### Core (Approach A, as verified by solution-verify)

- Add `everSawRealActivity: boolean` to `HeartbeatState` (default `false`, NEVER reset — `turn_start` must not clear it).
- Latch in `parseHeartbeatLine` from: (1) `tool_start` markers; (2) `tool_end` markers (**P1-1 hardening** — a parsed `tool_end` provably implies a PRIOR STREAMED ASSISTANT MESSAGE (model activity), even when the tool was failed/blocked/truncated (`failToolCallsFromTruncatedMessage` emits start+end for UNEXECUTED tools; a never-worked hung-first-request session can never reach tool code — no message → no `tool_end` → #5926 safe); closes the short-round marker-loss corner); (3) any `tick` whose post-parse state shows `tools > 0 || turnSawMessage || turnSawTool` (the tick backstop — the 30s timer fires independently of the LLM call; for truncated/failed-tool paths the tick is the FIRST latch and `tool_end` only a second — do not "simplify" them away).
- Deliberately NOT latched by bare `ready`/`turn_start` (the emitter fires `turn_start` BEFORE the first provider call — latching there would mark every session as worked and silently disable #5926 detection).
- Clause 4 (first-message) gains `!st.everSawRealActivity` — a worked session is never cut at M; its genuine quiet windows are owned by stream-stall (S=20min) / silence (T) / tool-stall (L=6h) / hard cap (2h) / maxDispatch (opt-in).
- Diagnostics: expose the latch in all FOUR alive-summary sites + fix the first-message headline to print the EFFECTIVE bound (`decision.firstMessageMs`) instead of the base `hbThresholds.firstMessageMs` (the 905s cut printed "(bound 300s)" under a latched 900s bound).

### Hardening 1 — `tool_end` latch (P1-1, short-round marker-loss corner)

The latch's assumption "any demonstrable work leaves ≥1 parseable evidence line" fails for SHORT first rounds (< one 30s tick interval — e.g. the "read project-workflow + commit-workflow" pattern is two fast reads). No in-round tick exists (no `tools>0` tick), `turn_end` clears the child's map, `turn_start(1)` resets both saw flags, and a lost `tool_start` (MCP stderr flood >4KB overflow discards marker-prefixed residue) leaves ZERO latch evidence at the quiet verdict. Latching on `tool_end` closes this: every executed tool fires `tool_execution_end` → `tool_end` marker → latch. Remaining corner (BOTH `tool_start` AND `tool_end` lost) = total blindness — practically impossible + triaged via diagnostics. **Parent-side, one line in `case "tool_end"`, monotonic, no format change.**

### Hardening 2 — parent-side `streamAgeMs` reset on turn transition markers (P1-2, frozen-age stream-stall cut)

The frozen-age mechanism is NOT limited to the M band. A latched session whose completed round had `streamAgeMs > S` (20min — the NESTED-TASK class: an outer agent dispatching a nested task sits in its task-tool round for the full child duration, and `task` emits no `tool_execution_update` while awaiting) trips **stream-stall (clause 2)** seconds after `turn_start` — the parent's parsed `streamAgeMs` is the last round tick's frozen value; `tool_end`/`turn_end`/`turn_start` never reset it; the 10s decision fires before the next self-healing tick (≤30s). The verdict may be actively streaming. Fix: **reset `streamAgeMs = 0` in the parent parse on `turn_end` AND `turn_start`** (the child already self-heals — its handlers `touchActivity()` — the parent's parsed copy is what's stale). This kills BOTH frozen-transition bands (M and S) deterministically:
- Transition window: `effStreamAge = 0 + markerAge` ≈ ≤30s → neither M nor S can fire on frozen age.
- Between-turn wedge (E11b class): now takes a full S of TRUE quiet (bounded — the child's ticks report the real growing age; the reset only bridges the <30s tick gap). Acceptable, still bounded.
- Wedged child (markers stopped): streamAgeMs frozen anyway, markerAge grows → stall clauses still catch the wedge.
- Mid-turn genuine quiet: ticks report the true growing `streamAgeMs` → stream-stall at S (correct).

**Both hardening fixes are parent-side, one-file, no wire-format change, no env surface.**

### Why A over C1 (the only other parent-only candidate) — unchanged from cycle 1

Both survive the frozen-state turn-transition kill and both preserve the never-worked cut at M. A wins on: (1) **(b)-strictness** — A keeps the clause armed until REAL activity latches (a hung no-activity request at ANY turn index still cuts at M; C1 disarms at turn-1 completion, narrowing #5926-class coverage); (2) **marker-loss robustness on the actual incident class** — the freezing tick carries `tools ≥ 1` (child emits `tools = outstandingTools.size`), so the tick that creates the frozen age ITSELF latches A; the 5 recovered cut partials prove round ticks got through; C1's disarm depends on 3 event markers at the burst-prone transition; (3) **semantic fit** — A is the faithful implementation of the issue's stated target; C1 requires ratifying a behavior change.

### Rejected alternatives (with when each WOULD have been better)

- **B (child-side `saw_any_ever=1` tick bit) — rejected.** Wire-format change: child formatter + parent parser + E14 round-trip must move atomically; a stale old-format child silently fail-opens (no latch) unless A-style inference kept as fallback, at which point B ≈ A + decorative bit. **Would have been better** if first-round marker loss were evidenced frequent enough to defeat the 30s tick backstop (it isn't — 5 recovered cuts prove round ticks flow) AND the team accepted the E14 contract bump.
- **C1 (first-turn-only armament via the already-emitted `turnIndex`) — runner-up.** **Would have been better** if the team ratified "the clause is a first-request detector and must never apply to later turns" as a deliberate semantic change and turn-transition marker loss were the dominant failure mode. A's `tool_end` latch (Hardening 1) now also covers C1's best case (lost `tool_start` recovered by `tool_end`) with a marker that cannot false-positive.
- **C2 (session-latch the existing saw-flags, drop both resets) — rejected.** Redefines well-known PER-TURN names session-wide (highest future-drift risk); NOT parent-only (both sides must drop the reset atomically). **Would have been better** if the team wanted zero new state at any cost.
- **D (bound-raise) — rejected.** Fails requirement (a) outright: `effStreamAge` includes the ENTIRE tool round (frozen), so no static M can bound it — the real 905s cut under a latched 900s bound (load≥16) proves ANY static M fails; also weakens #5926 and fails (e). **Would have been better** as a one-commit stopgap PR while this ships (reduce incident frequency, not eliminate).

---

## Code changes (all in `extensions/builtin-tools/index.ts` + one doc)

### 1. `HeartbeatState` (L726-747) + `createHeartbeatState()` (L745-758)

Add `everSawRealActivity: boolean` after `everSawWork` (L734) / `everSawWork: false` (L753), default `false`. Comment: monotonic session-level latch proving REAL message/tool activity — deliberately NOT latched by bare `turn_start`/`ready` (the emitter fires them BEFORE the first provider call; latching there would disable #5926 hung-first-request detection). Distinct from `everSawWork` (which IS latched on `turn_start` — a live footgun).

### 2. `parseHeartbeatLine` (L790-857) — latch sites + streamAgeMs transition reset

- `case "tool_start"` (L814-816): `state.everSawRealActivity = true;` (alongside existing `toolsInFlight += 1; everSawWork = true`).
- `case "tool_end"` (L818-819): `state.everSawRealActivity = true;` (**Hardening 1** — a parsed tool_end implies a prior streamed assistant message (model activity), including failed/blocked/truncated tool paths; closes the short-round marker-loss corner; monotonic).
- `case "turn_start"` (L821-825): existing per-turn flag resets stay; ADD `state.streamAgeMs = 0;` (**Hardening 2** — the parent's parsed copy is stale after a completed round; the child self-heals via its own `touchActivity()`, the parent's copy is what the 10s decision reads between the transition and the next tick). Keep `everSawWork = true` unchanged. Do NOT touch `everSawRealActivity` here.
- `case "turn_end"` (L827-833): ADD `state.streamAgeMs = 0;` (same reason; covers the transition window even if the turn_start marker is lost).
- `case "tick"` (L835-853): unchanged loop; AFTER the loop, compute the latch from the complete post-parse state: `state.everSawRealActivity = state.everSawRealActivity || state.toolsInFlight > 0 || state.turnSawMessage || state.turnSawTool;` (field-order-independent; the nonce check precedes the switch, so a forged tick cannot set the latch).
- `case "ready"` / `session_end`: no change (never latch).

### 3. Clause 4 gate (L1119-1126)

Extend the clause comment and add the gate:

```ts
  // 4. first-message — turn running but no message/tool activity ever within
  //    M (hung provider request, #5926 class). Retryable when no real output.
  //    #279: gated on !everSawRealActivity — a session that demonstrably
  //    worked (any tool_start/tool_end marker or tick saw_msg/saw_tool/tools>0)
  //    is NEVER cut at M: mid-turn quiet verdicts and frozen streamAge at the
  //    turn transition are owned by stream-stall (S) / silence (T) /
  //    tool-stall (L) / hard cap / maxDispatch — the #198/#220 "never kill a
  //    working agent" intent. A never-worked session keeps the M cut unchanged
  //    (hung-first-request detection preserved, #5926). Marker STALENESS stays
  //    covered by the stateFresh precondition (a stale marker stream is already
  //    exempt here).
  if (
    stateFresh &&
    st.turnActive &&
    !st.everSawRealActivity &&
    !st.turnSawMessage &&
    !(st.turnSawTool || st.toolsInFlight > 0) &&
    effStreamAge > effFirstMessageMs
  ) {
    return { ...kill("first-message-stall"), firstMessageMs: effFirstMessageMs };
  }
```

Safety (unchanged exposure for latched sessions — identical to #198/#220 intent): a tool-looping/drip child that latches is never cut by first-message, but remains bounded by tool-stall (L=6h per tool), stream-stall (S=20min between tools), silence (T=30min), the hard cap (2h default), and maxDispatch (opt-in tighter cap — the issue's named backstop). No unbounded-wait regression (#208).

### 4. Diagnostics — four alive summaries + headline fix + header comment + load-policy doc

**All four `Alive state:` templates gain `everSawRealActivity=`** (inserted after `toolAgeMaxMs=`):
- Hard-cap composition (L1363, inline in the hardCapTimer text — `hbCtx` is in scope in the timer callback).
- Cut composition (L1440, `finalize` cut branch).
- Heartbeat-kill composition (L1514, the 10s interval kill path).
- Backstop composition (L1561, `backstopFire`).

Each becomes: `Alive state: toolsInFlight=${...} turnActive=${...} streamAgeMs=${...} toolAgeMaxMs=${...} everSawRealActivity=${hbCtx.state.everSawRealActivity} lastMarkerAgeMs=${markerAgeMs}`.

**Headline fix (L1519)** — print the EFFECTIVE (load-scaled + latched) bound, not the base:

```ts
        "first-message-stall": `⚠️ Sub-agent turn produced no first message/tool activity for ${Math.round(hbCtx.state.streamAgeMs / 1000)}s (bound ${Math.round((decision.firstMessageMs ?? hbThresholds.firstMessageMs) / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
```

`decision.firstMessageMs` is the effective bound on the kill path (clause 4 returns `{ ...kill("first-message-stall"), firstMessageMs: effFirstMessageMs }`, L1126); the `?? base` fallback keeps other reasons untouched (verified: no renderable kill path lacks `firstMessageMs` — all other kills fall back to the finite base; the only returns lacking it are non-kill). Fixes the 905s-cut display bug.

**Header kill-clause summary (L550-557):** update the clause-4 line to note the `!everSawRealActivity` gate (currently reads as if clause 4 applies to every turn).

**Docs:** `docs/ops/load-policy.md` §6 (Watchdog side — the first-message bound) — (a) add a paragraph documenting the `everSawRealActivity` gate + the streamAgeMs transition reset, placed ADJACENT TO the existing "#198 structural fix" bullet (it extends that fix); (b) the existing bullet "the kill headline shows the effective bound" is CURRENTLY CODE-FALSE (L1519 prints the base) — the L1519 fix makes it true; note this in the doc diff so the intent is explicit; (c) fix the stale "pinned by test E13b" reference (no E13b exists in the suite — it is E13).

---

## Testing strategy

All new tests in `extensions/builtin-tools/builtin-tools.test.ts`, a dedicated `#279` section (per the E271/E272 series convention — console `section()` label, no harness change). Run: `npx tsx extensions/builtin-tools/builtin-tools.test.ts` from `extensions/builtin-tools/`.

### E279 series

- **E279a — worked session, MID-TURN quiet verdict → NEVER cut (the primary regression boundary).** Construction: latch fired (parse a `tool_start` OR set `everSawRealActivity=true` directly) + `turnActive=true` + saw flags false + `toolsInFlight=0` + `streamAgeMs = M + 1000` (a mid-turn quiet verdict, no transition needed) + fresh markers. **dinput MUST set `streamStallMs: 600_000`** (harness default S=120s < M=300s would make stream-stall preempt first-message and the `kill === false` assertion would fail; E13's precedent L1401). → `kill === false`. Pre-fix (latch false) → `kill === true, reason === "first-message-stall"` (bracketing: the gate is what saves it).
- **E279a2 — worked session, FROZEN-TRANSITION state → NEVER cut (the Hardening-2 reset + latch).** CONSTRUCTION MUST BE PARSE-DRIVEN (drive the marker sequence through `parseHeartbeatLine` so the reset/latch sites are actually exercised — manual state construction would pass without running the fix): `tool_start` → round ticks (last tick carries `streamAgeMs=600_000 > S` — a NESTED-TASK-length round, `tools=1, saw_tool=1` → latch fires from the round ticks) → `tool_end` → `turn_end` (parent parse resets `streamAgeMs=0`) → `turn_start(1)` (resets `streamAgeMs=0` again, flags zeroed) → decision at +10s: `effStreamAge = 0 + 10_000 = 10_000` → `kill === false` (frozen age gone). Pre-fix (no reset): `effStreamAge = 600_000 + 10_000 > S` → `kill === true, reason === "stream-stall"` — the P1-2 nested-task class. Assert both. No `streamStallMs` override needed (both branches valid under the harness S=120s default).
- **E279b — never-worked session → cut at M PRESERVED (the #5926 guard).** Parse-driven: `ready` → `turn_start` (turnIndex=0) → all-zero ticks (tools=0, saw_msg=0, saw_tool=0) with `streamAgeMs` crossing M at t=430_000 → decision at t=440_000 → **dinput MUST set `streamStallMs: 600_000` AND `hasOutput: false`** (harness S=120s would preempt; dinput default hasOutput=true would flip `resolveUndefined`) → `kill === true, reason === "first-message-stall", resolveUndefined === true` (retryable, #5926). This test is the guard: a future implementer latching `everSawRealActivity` on bare `turn_start` (or reusing `everSawWork`) FAILS it.
- **E279c — latch sources, parse-level + monotonicity (PARSE-DRIVEN — construct markers through `parseHeartbeatLine`).** `tool_start` latches; `tool_end` latches (**Hardening 1** — the short-round marker-loss corner: `tool_start` lost, `tools=0` ticks, `tool_end` parsed → latched); subsequent `turn_start`/`turn_end`/`tool_end` do NOT clear; a bare `turn_start` alone does NOT latch (hung-first-request preservation); `ready` alone does NOT latch.
- **E279d — latch-on-tick, each field.** `saw_msg=1`, `saw_tool=1`, and `tools=1` (individually) each latch; an all-zero tick does NOT; the latch is computed POST-switch (field order irrelevant — assert a tick carrying only `saw_msg=1` latches).
- **E279d2 — forged tick cannot latch.** Existing forged-tick test extended: a tick with the WRONG nonce (or no nonce) must leave `everSawRealActivity` unchanged (false) — a forged marker cannot disarm #5926 detection (security property pin).
- **E279e — lost-tool_start recovered by the tick backstop (LONG round).** Tool_start and early round ticks LOST (never parsed); a single late round tick (`tools=1, streamAgeMs=330_000`) parsed → **assert `everSawRealActivity === true` IMMEDIATELY after the tick parse, BEFORE parsing `tool_end`** (isolates the tick-only latch source — otherwise the test could pass via the `tool_end` source) → then `tool_end` → `turn_start`(1) → quiet decision → **dinput MUST set `streamStallMs: 600_000`** → NOT cut. Pins the long-round marker-loss path.
- **E279f — diagnostics pin (source-scan, E16/E271g precedent).** Read `index.ts`: assert exactly 4 `Alive state:` template sites, each containing `everSawRealActivity=` (comment: a deliberate 5th site must be added to this test); assert the `"first-message-stall"` headline references `decision.firstMessageMs`; assert `everSawRealActivity` appears in `createHeartbeatState` with `false`; assert the `turn_start`/`turn_end` cases contain `streamAgeMs = 0`. Optional-but-recommended: a decision-level assertion with a saw_msg-latched state (latch source = a single `saw_msg=1` tick) pinning the message-only class end-to-end.
- **E279g — latched hung-tool still cut (tool-stall precedence with the latch SET).** `everSawRealActivity=true` + `toolsInFlight=1` + `toolAgeMaxMs > L` → `kill === true, reason === "tool-stall"` (clause 1 precedes clause 4 regardless of the latch; pins AC4's "latched sessions fall to tool-stall (L)").

### Regression (must stay green, untouched)

- **E13** (L1392): never-worked fixture (`everSawWork=true`, saw flags false, no latch sources) → `everSawRealActivity` defaults `false` → gate passes → still killed; exemption sub-cases (`sawTool=true`, `toolsInFlight=1`) unaffected; hung-tool-still-cut → tool-stall unaffected. ✓
- **E15/E15b/E16** (L1946-1999): `mkFirstMsg` sets no activity fields → latch `false` → identical decisions/bounds. ✓
- **E14** (L1608-1647): no format change; the round-trip's `formatToolStart`/`formatTick` now ALSO latch a field no assertion reads — parse parity unchanged. ✓
- **E11b** (between-turn wedge): constructs state manually (`turnActive=false, streamAgeMs=S+1`) — does NOT go through the turn_end/turn_start parse cases → unaffected by the Hardening-2 reset. The REAL between-turn wedge is still caught: ticks report the child's growing `streamAgeMs` → stream-stall at S of true quiet. ✓
- **E12, E271 series, tier-1, #191 sessionEnded, "no markers at all"**: manual-state fixtures → unaffected. ✓
- Existing parse tests ("ready / tool_start / tool_end / turn_start / turn_end update state", "turn_start resets per-turn saw flags", "tick overwrites state fields", overflow guard, session_end, forged-tick): additive latch/reset sites; no assertion on the new field or streamAgeMs-reset conflicts (the turn_start-reset test asserts saw flags only). ✓

---

## Verification plan

1. **Unit suite:** `npx tsx extensions/builtin-tools/builtin-tools.test.ts` → all pass, including the new E279 series. Confirms (e).
2. **Typecheck:** `npx tsc --noEmit` on the extension (or the repo's standard check) — the new interface field must typecheck across `createHeartbeatState`/`parseHeartbeatLine`/alive summaries.
3. **Reproduction-under-test (fast loop):** temporarily set `TASK_FIRST_MESSAGE_MS=60000` (the `max(60s, …)` floor) and re-run the #265-class scenario (startup-heavy dispatch: read skills → run tools → long tool round → quiet verdict) — confirm the verdict arrives, zero first-message partials, alive summary shows `everSawRealActivity=true`. Also run a nested-task dispatch (outer task dispatches an inner task) long enough to exceed the streamAgeMs M-window — confirm no stream-stall cut at the outer's turn transition (Hardening 2). Revert the env override.
4. **Grep-based regression scan (post-change):** run several real `task` dispatches (incl. one startup-heavy and one nested) and grep session logs for `"first-message-stall"` and `"stream-stall"` — assert zero partials where the alive summary shows `everSawRealActivity=true` or where the cut landed ≤10s after a `turn_start` (frozen-age signature); a never-worked hang (if reproducible) still shows the partial with `everSawRealActivity=false` and the EFFECTIVE bound in the headline.
5. **Latency-regression quantification (P2-1 evidence closure):** sweep session logs for turn-2+ zero-token provider hangs (partials where the alive state shows a latched session with `streamAgeMs ≈ M..S` and no message/tool in the current turn) to confirm later-turn hangs are rare relative to the false-cut class; record the count in the PR description. Confirm `TASK_MAX_DISPATCH_MS` semantics documented for batch contexts (epic-executor).
6. **Issue Target check:** the failing dispatch scenario delivers its verdict instead of a partial.

---

## Acceptance criteria (mapped to issue O/I/T)

| # | Criterion | O/I/T mapping | Evidence |
|---|---|---|---|
| AC1 | A worked sub-agent (fresh markers + any parsed tool/message activity, incl. `tool_end`) is NEVER killed by `first-message-stall` — mid-turn quiet verdict OR frozen-age turn transition. **Carve-out (explicit):** a session with ZERO observable activity in turn 1 (slow first call, long pre-tool thinking) remains subject to the M cut — indistinguishable from hung, #5926 preservation; evidenced-rare (0 of 5 recovered cuts). | O; Indicator (1) regression boundary (worked + no-tools + quiet > M); Indicator (2) zero worked-session partials; Target's corrected semantics ("never cut on fresh markers + real activity") | E279a, E279a2, E279e; verification steps 3–4 |
| AC2 | A never-worked session (fresh markers, no activity ever) is STILL cut at the effective M with `resolveUndefined=true` (retryable) — #5926 detection preserved. | Indicator (2) boundary ("…when the sub-agent was demonstrably working" — non-working stays cut); #5926 | E279b (+ E13 regression) |
| AC3 | The frozen-age stream-stall cut (nested-task class: a completed round with `streamAgeMs > S` must not cut the live verdict at the turn transition) is eliminated; between-turn wedge detection is preserved (stream-stall at S of true quiet). | O (no cut of live work, any clause); nested-task stakeholder class | E279a2; E11b regression |
| AC4 | `toolsInFlight`/`turnSawTool` tracking covers the first tool round; the latch fires from `tool_start` AND `tool_end` AND tick `saw_msg`/`saw_tool`/`tools>0` (tick backstop for marker loss); a forged marker cannot latch. | Indicator (3) "tracking covers the sub-agent's first tool round" | E279c, E279d, E279d2, E279e |
| AC5 | Every state remains bounded: latched sessions fall to stream-stall (S) / silence (T) / tool-stall (L) / hard cap / maxDispatch — no #208 unbounded-drip regression. | O (no regression); #208 guard | E279a companion (S ownership), E279g (L ownership), E13 hung-tool case |
| AC6 | Minimal blast radius: no wire-format change, no child-side change, no env surface; E13/E15/E15b/E16/E14/E11b + all existing tests green unchanged. | Requirement (d)/(e) | Full suite run |
| AC7 | Diagnostics: all four alive-summary sites expose `everSawRealActivity`; the first-message headline prints the EFFECTIVE (latched) bound; `docs/ops/load-policy.md` §6 documents the gate + transition reset (stale E13b ref fixed). | Indicator (2) triage fidelity; 905s display bug | E279f; docs diff |

---

## Risks & mitigations

- **Marker-loss residual (A's documented weakness), split by round duration:**
  - (i) LONG rounds (> one 30s tick): the freezing tick carries `tools≥1` (self-latch) — ~N independent LLM-independent latch chances; full-round loss practically impossible; E279e pins single-loss recovery.
  - (ii) SHORT rounds (< one tick): no in-round tick; the `tool_end` latch (Hardening 1) is the designed second chance — a parsed `tool_end` provably implies prior model activity (streamed assistant message), including failed/blocked/truncated tool paths; E279c pins it. Remaining corner (BOTH `tool_start` AND `tool_end` lost) = total blindness: two independent marker lines lost (two timed >4KB floods) + a >M quiet verdict — genuinely rare but not impossible; diagnostics (latch in all 4 alive summaries) are the triage path. NOT fixing marker robustness in-scope (research residual (c) — separate concern).
- **Wedge-after-transition residual (Hardening 2):** a child that completes its transition markers (turn_end/turn_start parsed → `streamAgeMs=0`) and THEN stops emitting is now caught at silence T=30min instead of stream-stall ~2min after the last tick (pre-fix, a frozen age > S−120s crossed S quickly; post-fix, stream-stall would need markerAge > S=20min, unreachable inside the stateFresh 120s window). Bounded (silence T, hard cap 2h, backstop 6.5h all fire) and arguably the correct semantics for a tools=0, turnActive=true, marker-stopped child (legacy E11/E12 class) — named here as the accepted trade; the AC3 "between-turn wedge preserved" claim refers to the tick-flowing variant (stream-stall at S of true quiet), not the marker-stopped-at-transition variant.
- **Frozen-age stream-stall (Hardening 2 scope change):** resetting `streamAgeMs` on `turn_end`/`turn_start` widens between-turn wedge detection from `min(S, frozen+markerAge)` to a full S of true quiet. Bounded and deliberate (E11b unaffected — manual construction); documented in the code comment + load-policy.md.
- **Hung-detection latency M→S for latched turn-2+ hangs (P2-1):** a genuine provider hang after any real activity is detected at S=20min instead of M=5min (4× latency; retry ≈ 60min/dispatch; breaker ≈ 60min). Accepted per #198/#220 intent ("never kill a working agent") + verification step 5 quantifies the class frequency from logs; `TASK_MAX_DISPATCH_MS` remains the opt-in tighter cap for batch contexts (documented for epic-executor).
- **Latch-site multiplicity:** three evidence paths (tool_start, tool_end, tick) must not be "simplified" away — the redundancy is deliberate (each covers a distinct loss mode). E279c/d/e pin each source; the code comment warns against merging into `everSawWork`/turn_start latching.
- **Future clause refactors:** clause 4 gains a new precondition; a refactor dropping it silently reintroduces the bug. E279b (never-worked still cut) + E279a (worked never cut) bracket it from both sides.
- **#5926 preservation:** the gate must not drift into "latch on turn_start". E279b fails on exactly that implementation error; the `everSawRealActivity` vs `everSawWork` distinction is documented at the field definition + E279d2 pins the forged-marker invariant.
- **Stream `"start"`-event semantics** (connection-open vs first-chunk) remain unverified (research residual (a)); PM-1 acceptance judges on first-chunk semantics — out of this plan's scope, no behavior change here.
- **Slow-but-alive never-worked first call under load<8** remains cuttable at M (accepted: indistinguishable from hung; #5926 preservation — AC1 carve-out). Under load≥8 the #272 scaling (2×/3×) already extends the bound.

---

## Runtime prerequisites

- No new dependencies, env vars, or config surfaces. `TASK_FIRST_MESSAGE_MS` / `TASK_MAX_DISPATCH_MS` / load scaling (#272) semantics unchanged.
- Test env: `node_modules/@earendil-works/pi-coding-agent` + `typebox` mocks present (existing suite prerequisite, noted in builtin-tools.test.ts header).
- Requires the marker emitter loaded in children (`TASK_HEARTBEAT=1`); with the emitter absent the clause is inert by `stateFresh=false` (legacy behavior) — unchanged.
- Single PR against `extensions/builtin-tools/` (+ `docs/ops/load-policy.md`); commit via the standard commit-workflow gate (pre-flight suite + review).
