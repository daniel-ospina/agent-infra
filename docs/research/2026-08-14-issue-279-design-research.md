---
title: "Design Research: #279 — best design for the task sub-agent first-message watchdog (Good > Easy)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-279, builtin-tools, task-heartbeat
---

# Design Research: #279 — best design for the task sub-agent first-message watchdog (Good > Easy)

> **Findings date:** 2026-08-14 (afternoon)
> **Trigger:** user asked to re-research the best design (Good > Easy) after the scoping pipeline converged on Approach A. This doc validates/challenges that choice against external practice.
> **Domain:** engineering — watchdog/liveness design for AI agent sub-processes.

## Step 0 — Problem Reframing

**5 Whys:** why does the watchdog need the first-message clause? → to avoid hanging the parent forever on a hung provider call → why would the parent hang? → the child's LLM request may never produce a first response → why does the current bound false-cut? → it applies a wall-clock age to EVERY turn, not just the first request → why does that kill live workers? → because per-turn quiet is indistinguishable from hung at the watchdog layer, and per-turn resets erase prior work evidence → root framing: **the watchdog conflates process-liveness (heartbeat) with operation-progress (stream activity), and applies a first-request bound as a per-turn bound.**

**Reframed problem:** "[The task tool] trying to [bound a hung provider request without killing a live sub-agent] but [the current bound keys on wall-clock stream age per turn, conflating liveness with progress] which results in [live work destroyed: 5 recovered cuts, verdicts lost]."

**How Might We (alternatives):**
- HMW make the bound **session-scoped** instead of per-turn? (the chosen direction)
- HMW make the child report its own **work-loop state** so the parent never has to infer? (Approach B's spirit)
- HMW distinguish "thinking/working" from "hung" using signals the child already emits?
- HMW make the watchdog **generous and layered** (like CI timeouts) instead of precise?

**Reverse the problem:** what if the watchdog's job is NOT to detect hangs at all, but only to (a) reap dead processes and (b) enforce a generous hard cap — with the provider's own timeout doing precise hang detection? That surfaces: the parent-side watchdog is a SAFETY NET, not the primary hang detector. The provider (deepseek etc.) has its own request timeouts; the watchdog's precise 5-min first-message detection duplicates that with high false-positive cost.

## Step 1.7 — Epistemic Memory

`tortoise-memory.mjs query-prior-research` → **unavailable** (TORTOISE_API_KEY not set). Skipped per protocol. No prior epistemic claims found.

## Step 2 — Internal Knowledge (code-verified 2026-08-14 against builtin-tools/index.ts + task-heartbeat.ts)

- 5 recovered cuts (445s/472s/415s/453s quiet-verdict class + 482s pre-#220): all `toolsInFlight=0, turnActive=true, lastMarkerAgeMs ≤9.2s (FRESH), streamAgeMs>300s`.
- Mechanism (precise): pi emits `turn_start` per LLM call — the extension event originates in pi-agent-core's agent-loop (`node_modules/@earendil-works/pi-agent-core/dist/agent-loop.js`, `if (!firstTurn) emit turn_start` per LLM call) and is forwarded by pi's `dist/core/agent-session.js` (_emitExtensionEvent, turnIndex per turn). Child + parent reset per-turn flags on turn_start. **The PARENT's `streamAgeMs`/`toolAgeMaxMs` state is never reset by turn/tool markers (only the tick case updates them)** — a tick can arrive up to intervalMs late, so a fresh turn inherits the previous turn's frozen stream age + growing markerAge → frozen-age kill at the turn transition. (The CHILD self-heals: its turn/tool/message handlers call `touchActivity()`; only the parent's parsed copy is stale.)
- Existing watchdog layers: tier-1 zero-output (60s), tool-stall (L=6h), stream-stall (S=20min), silence (T=30min), cut clause (#271, marker-gap 37.5s), first-message (M=300s), hard cap (2h), maxDispatch (opt-in), backstop (6h30m).
- Child emits work-loop signals already: `saw_msg` (assistant message_start/update), `saw_tool` (tool_execution_start), `tools` (outstandingTools.size), `stream_age_ms` — carried on a 30s background-timer tick.
- Prior fix lineage: #176 (heartbeat), #198/#220 (in-flight-tool exemption), #208/#221 (partials + hard cap), #209/#272 (load scaling), #271 (cut clause).

## Step 3 — External Findings

### Theme 1 — Liveness vs readiness vs progress are THREE different questions (High confidence, 4+ sources: K8s official docs, practitioner health-check article, Zylos, HeyOnCall)

Kubernetes' three-probe model encodes this: **startup** ("still booting"), **liveness** ("is my process wedged?" → restart), **readiness** ("can I serve traffic?" → drain, no kill) [K8s official docs; Amirul Islam health-checks article]. The famous failure class: "the liveness probe restarts a perfectly healthy but slow pod every 30 seconds, forever" — and the explicit rule: *"Liveness should answer only 'is my process wedged?' Things like: an internal deadlock, a thread that has spun for 60 seconds, a watchdog that has not been kicked. Downstream health belongs in readiness."* The Zylos dual-layer paper (AI-agent-specific) generalizes: **activity state and health state are orthogonal dimensions**; conflating them produces "ambiguous alerts and incorrect recovery actions." A liveness probe that checks downstream dependencies causes restart storms (documented HeyOnCall CPU-throttle incident: default 1s timeout + CPU limit → CrashLoopBackOff loop).

**Mapping to #279:** the first-message clause is a *readiness/downstream* check (the provider is the downstream dependency) being used as a *liveness* kill with wall-clock age. The child's heartbeat (fresh markers) is process-liveness and is healthy; the stream age is *activity*; the hung provider is *downstream* health. All three must live in separate clauses — which is what the proposed design does (heartbeat→stateFresh/cut clause; activity→latch; downstream→never-worked M cut + generous safety nets).

### Theme 2 — "Busy-but-silent" is the classic false-positive; the fix is progress evidence, not silence age (High confidence, 4+ sources across 3 independent families: dora-rs, systemd, K8s practitioner ×4)

**dora-rs #2284 (the closest analog — an AI/robotics dataflow):** a default-on "finish-straggler watchdog" killed a trainer node doing legitimate >120s silent compute because "the watchdog never observes whether a node is busy — it only observes silence." The node's final output was lost. Their fix direction: "**Liveness, not just silence: before escalating, sample the process and skip nodes that are demonstrably making progress; only kill nodes that are genuinely idle/blocked.**"

**systemd WatchdogSec:** "If your task performs blocking I/O for longer than the watchdog interval, you are going to get slaughtered every time" — heartbeat-based kill misapplied to legitimate long operations.

**K8s practitioner consensus** (octopus, resolve.ai, vcluster, oneuptime): aggressive probe timeouts kill busy-but-healthy containers; "slow-but-working processes can be misclassified as unhealthy"; "timeouts set too short can cause false positives, killing healthy-but-slow containers."

**Mapping to #279:** the fix must be *progress-based*, not *silence-based* — exactly the `everSawRealActivity` latch (once the child demonstrably progressed, silence-age no longer kills it) + the frozen-age reset (silence age from a COMPLETED round must not kill the next turn).

### Theme 3 — Work-loop heartbeat vs background-timer heartbeat (Medium confidence, 2 sources: Zylos + dora-rs)

Zylos: "A heartbeat running on a background timer proves the event loop is alive, not that work is progressing. The correct instrumentation is a **work-loop heartbeat**: a signal emitted from within the main processing loop... If the main loop stalls — on a hung tool call, an unresolvable LLM response, a blocked subagent — the work-loop heartbeat stops." Also: "A health HTTP endpoint that runs on its own thread will continue returning 200 OK after the main work loop stalls. This is the most common source of false health signals in production."

**Mapping to #279:** our child's tick is a background-timer heartbeat (proves the pi event loop is alive). The work-loop signals are `saw_msg`/`saw_tool`/`tools`/`stream_age_ms` — fired from message/tool event handlers INSIDE the agent loop. The proposed design's latch is built from **work-loop signals** (tool_start/tool_end markers + tick saw fields), NOT the background timer — this is the correct hierarchy. The tick merely relays work-loop state. A hung provider call (async await) keeps the background tick alive but produces no work-loop signals — which is exactly why the **never-worked** session must keep the M cut (the child's work loop produced nothing). The design gets this right.

### Theme 4 — Generous layered caps beat precise kills (Medium confidence, 2 sources: GitHub Actions, arc42)

GitHub Actions uses **fixed generous job-level timeouts** (default 360 min, step-level overrides) — the cap exists to bound runaway jobs, not to detect slowness; cancellation semantics are explicit. arc42's watchdog pattern: heartbeat/liveness probes with failureThreshold × period, "startup grace period before resuming normal heartbeat checks, avoiding restart loops during slow initialization," and "heartbeat interval too short relative to normal processing variance causes false-positive restarts."

**Mapping to #279:** after the first response, per-turn quiet should be bounded by GENEROUS fixed caps (stream-stall S=20min, hard cap 2h, maxDispatch opt-in) — matching CI practice — rather than the aggressive precise 5-min bound. The 5-min M stays only for the genuinely-never-worked first request (where no progress evidence exists at all).

### Theme 5 — Adversarial: what the research says AGAINST the chosen design (High — synthesized from Themes 1–4, each individually tagged)

- **A heartbeat can mask a stalled work loop** (Zylos, single-source — verify when available): fresh markers + hung provider = alive-but-not-progressing. The chosen design's never-worked M cut preserves hung-first-request detection, and tool-stall (L=6h) catches hung tools (Zylos' "Waiting + Unhealthy → cancel in-flight call"). But a hung LATER request on a latched session is detected at S=20min (4× slower than M) — a real trade, consistent with "generous caps" but must be accepted consciously.
- **Detection latency vs false-positive asymmetry** (HeyOnCall, single-source — verify when available): "Both types of errors are bad, but they usually aren't equally bad" — the false-positive (killing live work, losing verdicts) is the more expensive error here (5 incidents, re-run cost, circuit-breaker risk). The design trades detection latency (5min→20min for later hangs) for false-positive elimination — the correct asymmetry given the evidence.
- **K8s probe tuning** (octopus/oneuptime): conservative thresholds, higher failure counts, longer timeouts — "only using lower values if the situation absolutely requires it." Our design is conservative in exactly this spirit for the worked class.
- **The one retained silence-age kill (never-worked M)** — the design's weak point, flagged: the M=5min cut for never-worked sessions is the one place the design keeps the silence-age-kill pattern the research condemns, applied to the class with the LEAST progress evidence (a slow-but-working first request — multi-minute first-token latency — is indistinguishable from hung). Mitigating evidence: **0 of 5 recovered cuts were never-worked** — the retained M cut has produced ZERO observed false positives; its risk is theoretical, and #5926 treats the first-request cut as cheap-ish (retryable-undefined → the retry wrapper re-spawns). Open alternatives for this class (see Required Evidence): keep M with monitoring, widen to S=20min trusting the provider's own request timeout, or make it provider-timeout-aware.

## Step 4/5 — Design comparison vs external principles

| Candidate | Liveness/activity/downstream separated? | Progress-based (not silence-based)? | Work-loop signals used? | Generous layered caps? | Verdict |
|---|---|---|---|---|---|
| **A. Session-activity latch (+ tool_end + streamAgeMs reset)** | ✅ heartbeat→stateFresh/cut; activity→latch; downstream→never-worked M + S/hard-cap | ✅ kills only never-progressed sessions at M; worked sessions bounded by S | ✅ latch from tool_start/tool_end/tick saw fields (work-loop) | ✅ S=20min, hard cap 2h, maxDispatch opt-in | **BEST — matches every external principle** |
| B. Child-side session bit (wire change) | ✅ same semantics, child-owned | ✅ | ✅ stronger (child authority) | ✅ | ≈A + wire churn + stale-child fail-open |
| C1. First-turn-only bound (turnIndex) | Partial — drops downstream detection for later turns | ✅ | ⚠️ turnIndex only | ✅ | Narrower; requires ratified semantic change |
| C2. Session-latch existing flags | Same as A, drift risk | ✅ | ✅ | ✅ | Redefines per-turn names |
| D. Bound-raise | ❌ still silence-based | ❌ | ❌ | ⚠️ | **Violates progress-based principle; the 905s cut proves it fails** |

> **905s cut** (real incident, defined in `2026-08-14-issue-279-first-message-stall.md`): a quiet verdict turn killed under a latched 3× bound (900s effective, load≥16, #272 review session) — direct evidence that no static wall-clock bound can cover legitimate work (the frozen stream age includes the whole tool round).

## Recommendation

**Approach A (the converged plan) is the best design — validated, not just convenient.** It is the only candidate that satisfies ALL five external principles simultaneously:
1. **Separates the three questions** (liveness/activity/downstream) into separate clauses — the K8s three-probe lesson.
2. **Progress-based, not silence-based** — the dora-rs fix verbatim ("only kill nodes genuinely idle/blocked").
3. **Built on work-loop signals**, with the background tick only as a relay — the Zylos work-loop-heartbeat principle.
4. **Generous layered caps** for the worked class (S=20min + hard cap 2h) — the CI-timeout pattern.
5. **Preserves the one precise kill that matters**: never-worked first request at M (the only state with zero progress evidence — the hung-provider class the clause was built for).

The hardening fixes raised during review (tool_end latch for short-round marker loss; streamAgeMs reset killing the frozen-age transition cut) make it strictly better on the same principles (more progress sources, no silence-age leakage across turns).

**Open question for the human:** the accepted trade — a genuine hung request on a session that already worked is detected at 20min (stream-stall) instead of 5min. External practice (generous CI caps; false-positive asymmetry) supports this. Alternative if the user wants faster later-turn hang detection: bound it at M only when the provider's own timeout is known-unset, or make M's later-turn application opt-in via env. Default recommendation: accept S=20min for the worked class.

## Contradictions

- **(a) dora-rs: "silence never proves idle — never kill on silence alone"** vs **(b) the design retains a silence-age kill (M=5min) for never-worked sessions** (the only class with zero progress evidence; a slow first request is indistinguishable from hung). Resolution: (b) is retained because (i) 0 of 5 recovered cuts were never-worked — no observed false positive; (ii) #5926 makes the first-request cut retryable-undefined (cheap-ish: the retry wrapper re-spawns); (iii) without it, a hung first request with a live tick timer is unbounded until stream-stall (S=20min). The residual false-positive risk (slow-but-working first request) is theoretical, flagged in Theme 5 + Required Evidence, and the plan's verification step quantifies never-worked cuts from logs.
- **(a) Zylos: background-timer heartbeat can mask a stalled work loop** vs **(b) the design relies on the background tick as a relay** for the latch. Resolution: the tick only RELAYS work-loop signals (saw_msg/saw_tool/tools set by message/tool event handlers inside the agent loop); the latch sources are the work-loop signals themselves, and the never-worked M cut covers the hung-request case where the work loop produced nothing.

## Required Evidence (open items)
- Quantify later-turn (turn≥2) zero-token hang frequency from session logs (plan verification step 5) — confirms or refutes the accepted 5min→20min trade for latched sessions. If later-turn hangs are frequent, revisit (consider an opt-in per-turn M or provider-timeout-aware bound).
- Quantify **never-worked slow-first-request false positives** + the #5926 hung-first-request distribution (0 of 5 recovered cuts were never-worked; verify the cut class stays rare post-fix) — decides whether the retained M=5min never-worked bound is kept as-is, widened to S=20min (provider-timeout-aware), or made opt-in per env.

## Source Confidence Summary

| Claim | Sources (independent categories) | Tier |
|---|---|---|
| Liveness/readiness/startup are separate concerns; readiness-style checks must not kill | K8s official docs, health-check practitioner article, Zylos, HeyOnCall | **High** (4+) |
| Busy-but-silent false positives are the canonical watchdog failure; fix = progress evidence | dora-rs issue/PR, systemd docs (via practitioner), K8s practitioner ×4 | **High** (4+) |
| Background-timer heartbeat ≠ work progress; work-loop heartbeat required | Zylos, dora-rs | **Medium** (2) |
| Generous fixed caps beat aggressive precise bounds | GitHub Actions docs, arc42 | **Medium** (2) |
| False-positive errors are more expensive than detection latency in overload cases | HeyOnCall, arc42 | **Medium** (2) |
| First-token latency on LLM calls is legitimately long (multi-minute) — no dedicated external source retrieved (rate-limited) | — (internal evidence: 5 cuts, load scaling lineage) | **Low** ⚠️ single-source-absent — the M→S trade rests on internal evidence |
| dora-rs #2284 specifics (120s silent compute, trainer output lost, progress-evidence fix) | 1 (GitHub issue/PR) | **Low** ⚠️ single-source — verify when available (theme-level "High" aggregates this with K8s/systemd practitioner sources) |
| Zylos work-loop-heartbeat claim + "health endpoint returns 200 after loop stalls" | 1 (research article) | **Low** ⚠️ single-source — verify when available |
| HeyOnCall CPU-throttle CrashLoopBackOff incident | 1 (practitioner blog) | **Low** ⚠️ single-source — verify when available |
| systemd WatchdogSec blocking-I/O slaughter quote | 1 (practitioner blog) | **Low** ⚠️ single-source — verify when available |

## Raw Notes
- 2026-08-14 — exa semantic search returned the Zylos dual-layer paper (2026-04-03, AI-agent-specific) + arc42 watchdog + dora-rs #2284 (the exact analog) + K8s liveness incident (HeyOnCall) + systemd WatchdogSec trap.
- 2026-08-14 — web_search (sonar): GitHub Actions timeout-minutes (default 360min, generous caps), K8s liveness best-practice ×4. Perplexity API 429'd on 3 of 5 queries (rate limit) — coverage still sufficient via exa + sonar.
- 2026-08-14 — memory system offline (tortoise_unavailable) — no epistemic graph consult.
- 2026-08-14 — **wiki filing skipped:** agent-infra has no `docs/<domain>/wiki/` tree (this repo's research convention is `docs/research/` only); no INGEST entry appended. Explicit skip per research-skill Step 7 flexibility.
- 2026-08-14 — research-verifier cycle 1: 7×P2 (confidence tags on Theme 5/Step 2, Contradictions section, single-source notes for dora-rs/Zylos/HeyOnCall/systemd, wiki-skip note, parent-parser mechanism precision + citation fix, 905s inline definition, never-worked-M residual flagged + Required Evidence added). All fixed in doc.
