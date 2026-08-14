---
title: "Research: #279 — Alternative Solution Approaches (converge input)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-279, builtin-tools, task-heartbeat
---

# #279 — Alternative Solution Approaches (converge input)

> **Date:** 2026-08-14 (evening, agent-infra repo)
> **Companion to:** `docs/research/2026-08-14-issue-279-first-message-stall.md` (mechanism analysis + leading candidate)
> **Status:** ALTERNATIVES ONLY — no winner selected. The converge phase selects.
> **Method:** in-repo design review only (no external research). All approaches read against the actual code: `extensions/builtin-tools/index.ts` (clause L1119-1125, HeartbeatState L727-757, parseHeartbeatLine L800-855, kill composition L1490-1560, defaults L572-595) and `extensions/task-heartbeat.ts` (child emitter).

## Confirmed problem (recap)

The first-message-stall watchdog applies its first-request bound (M=300s base) to EVERY turn. `turn_start` fires per LLM call (pi-agent-core `agent-loop.js`); the child resets `turnSawMessage`/`turnSawTool` on `turn_start`; and the parent's parse never resets `streamAgeMs`/`toolAgeMaxMs` at `tool_end`/`turn_end`/`turn_start`. So after a completed tool round, a quiet verdict turn trips the clause via either of two mechanisms: **(i) frozen-state turn-transition kill** — the last tick during the tool round carried `streamAgeMs > M` (frozen), the kill fires within ~10–30s of `turn_start` before the next tick can deliver a reset `streamAgeMs`; **(ii) long-quiet-verdict kill** — a verdict generation that is itself silent past M trips the clause mid-turn with fresh heartbeats. 5 distinct real cuts recovered (445s/472s/415s/453s quiet-verdict class + 482s pre-#220 class).

**Requirements (from the issue):**
- (a) never cut a demonstrably-working sub-agent (fresh heartbeats + prior tool/message activity)
- (b) preserve hung-first-request detection at M (#5926, retryable-undefined)
- (c) keep every state bounded (no unbounded-drip regression, #208)
- (d) minimal blast radius
- (e) keep E13/E15/E15b/E16 green

**Shared cross-cutting scope (any winner must carry it):** include the new activity signal in all FOUR alive-summary sites (hard-cap L1363, cut-composition L1440, heartbeat-kill L1514, backstop L1561) and fix the kill headline (L1519) to print the EFFECTIVE bound (`decision.firstMessageMs`) instead of the base `hbThresholds.firstMessageMs` (the 905s cut displayed "bound 300s" under a latched 900s bound — display bug).

---

## Approach A — Parent-side monotonic activity latch (`everSawRealActivity`)

*The research doc's leading candidate; treated here as one candidate, not the answer.*

**Description.** The parent maintains a new monotonic latch `everSawRealActivity: boolean` (default false, NEVER reset). The first-message clause additionally requires `!st.everSawRealActivity`. Once the session demonstrably worked (any tool or assistant message activity), the clause is dead for the rest of the dispatch — the quiet verdict turn is owned by stream-stall (S=20min) / silence (T=30min) / tool-stall (L=6h) / hard cap (2h default) / maxDispatch (opt-in), exactly the #198/#220 "never kill a working agent" intent.

**Files touched.** `extensions/builtin-tools/index.ts` (HeartbeatState + createHeartbeatState, parseHeartbeatLine latch sites, clause condition, 4 alive summaries + headline fix), `extensions/builtin-tools/builtin-tools.test.ts` (E279 series). **No child change. No marker-format change.**

**Architecture.** Parent-side inference from signals it already receives:
- Latch on `tool_start` marker parse (case `tool_start`).
- Latch on `tick` parse when `saw_msg=1 || saw_tool=1 || tools>0` (tick backstop — the child sets `turnSawTool` in the same `tool_execution_start` event that emits `tool_start`, so a lost `tool_start` line is recovered by the next tick).
- Deliberately NOT latched by `ready` or bare `turn_start` (the emitter fires `turn_start` BEFORE the first provider call — latching there would mark every session as worked and silently disable hung-first-request detection). The distinct name prevents a future implementer from "simplifying" to `everSawWork`, which IS turn_start-latched and therefore unusable.
- Gate: clause 4 condition becomes `stateFresh && st.turnActive && !st.everSawRealActivity && !st.turnSawMessage && !(st.turnSawTool || st.toolsInFlight > 0) && effStreamAge > effFirstMessageMs`. The clause's existing `stateFresh &&` precondition already covers staleness — a `!stateFresh ||` disjunct would be dead code.

**(a)** ✓ — any tool round latches via tool_start marker or tick `tools>0`/`saw_tool=1`; any assistant message latches via tick `saw_msg=1`; monotonic (no turn_start reset in the parse) → mechanism (i) and (ii) both neutralized: once latched, `effStreamAge`'s frozen value is irrelevant.
**(b)** ✓ — a never-worked session (ready + turn_start only, all-zero ticks) keeps `everSawRealActivity=false` → cut at M unchanged. E279b pins this: a future implementer latching on turn_start would fail it.
**(c)** ✓ — latched sessions fall to the deliberate reviewed bounds (S/L/T/hard-cap/maxDispatch); identical exposure to #198/#220 intent. No unbounded-wait.
**(d)** ✓ — one file + tests; the smallest-blast-radius real fix. E14 format unchanged (the round-trip test gains latch assertions — formatReady/formatTurnStart must-not-latch, formatToolStart must-latch — pinning the child-formatter → latch contract).
**(e)** ✓ — E13's fixture (everSawWork=true, saw flags false, fresh markers) has `everSawRealActivity=false` by default → same decision; E15/E15b/E16 are load-scaling-only; E14 untouched.

**Risks.**
- Marker-loss residual: `tool_start` lost AND every tick during the round lost (line-buffer overflow drops marker-prefixed residue) → latch missed → verdict turn cuttable. The 30s periodic tick backstop makes full loss unlikely; documented residual, not fixed by this approach (triage path = diagnostics).
- Latch is parent-side inference from three signal kinds (tool_start + three tick fields) — three latch sites to maintain, redundancy is deliberate but must not be "simplified" away. E279e pins the tick backstop.
- The gate is a new precondition; any future clause-4 refactor must remember it (comment + E279b guard).

**Tradeoffs.** Parent remains the semantic owner of kill decisions (which it must be — only the parent knows the bounds). The cost of that is inference: the parent reconstructs "did the session work" from a combination of marker kinds and tick fields instead of reading one authoritative bit.

**Best-fit-if.** The converge phase wants the smallest blast radius, zero format change, no child-side change, and accepts parent-side inference as the right home for a kill gate.

---

## Approach B — Child-side session-level state in the tick (`saw_any_ever=1`)

**Description.** The child is the semantic owner of "has this session ever done real work" — it sees `message_start`/`tool_execution_start`/`message_update` directly with no line-transport dependency. The tick format gains a session-level bit `saw_any_ever=<0|1>`, set from a child-side session-scoped flag (latched on first assistant message or first tool execution, NEVER reset on turn_start — the per-turn `saw_msg`/`saw_tool` fields stay per-turn for the parent's existing turn-scoped reads). The parent latches `everSawRealActivity` from the bit and gates the clause identically to Approach A. Variant: a one-time `worked` marker kind instead of the per-tick bit (worse — a lost one-time marker is unrecoverable; the periodic tick bit is self-healing).

**Files touched.** `extensions/task-heartbeat.ts` (session flag + tick formatter + turn_start handler stops touching the session flag), `extensions/builtin-tools/index.ts` (tick parse latch + clause gate + diagnostics), `extensions/builtin-tools/builtin-tools.test.ts` (E14 drift update REQUIRED — it round-trips the full tick format — plus E279 series).

**Architecture.** Evidence path is child → parent, one bit, no inference:
- Child: `sawAnyEver` session flag; `tool_execution_start` and `message_start`(assistant role)/`message_update` set it; `turn_start` resets ONLY the per-turn flags, never `sawAnyEver`; `formatTick` emits `saw_any_ever=`.
- Parent: tick parse latches `st.everSawRealActivity ||= (saw_any_ever === 1)`; clause gate `!st.everSawRealActivity` identical to A.
- Field absent (old child / foreign tick / E14 fixtures): the tick regex `([a-z_]+)=(\d+)` skips unknown fields, so parsing is safe — but absence means NO latch → old-format children regress to today's behavior.

**(a)** ✓ — stronger than A: the bit is session-level truth, immune to which per-turn fields were zeroed at turn boundaries and to individual marker-line loss (every tick after the first activity carries the bit; only total tick-stream loss defeats it).
**(b)** ✓ — bit is 0 for never-worked → cut at M; same E279b guard.
**(c)** ✓ — identical bounded fallback structure.
**(d)** ✗ — the only approach that changes the wire format: child formatter + parent parser + E14 round-trip parity all move. Two source files + a contract test churn, plus coordinated rollout coupling (see risks).
**(e)** — E13/E15/E15b/E16 stay green (default `false`), but E14 MUST be deliberately updated for the new field — so (e) holds only with a planned test change, not "no change".

**Risks.**
- Format-contract churn: E14 drift guard exists precisely to catch format drift; adding a field is a deliberate contract version bump that must land atomically with the child.
- Rollout coupling: parent and child ship in the same extension dir, so drift is bounded — but a stale child in any real deployment (checked-out repo at mixed revisions, cached builds) silently disables the fix (fail-open, no latch). If strict backward-compat with old children is required, the parent must ALSO keep the A-style marker/tick inference as fallback — at which point B degenerates into A + a decorative child bit (redundant complexity).
- Semantic split: `saw_msg`/`saw_tool` stay per-turn while `saw_any_ever` is session-level — a future implementer may "simplify" by removing the per-turn fields or the session flag; the E279 series must pin the split.

**Tradeoffs.** The most robust evidence signal (no transport-loss exposure, no inference) bought with the only wire-format change in the set. Child-side truth is arguably the "right" home for session state, but the gate must remain parent-side regardless (only the parent knows the bounds) — so B relocates the evidence, not the decision.

**Best-fit-if.** The converge phase has evidence that marker/line loss in the first tool round is real (research doc residual risk (c)) and wants the latch to survive arbitrary individual-marker loss; and is willing to carry the E14 contract update + coordinated child/parent rollout.

---

## Approach C — Change the clause's semantics at the source

*Family: the clause should not apply to later turns at all. Two sub-variants, both parent-side-semantics changes. C1 is the cleaner of the two.*

### C1 — First-turn-only armament (parent parses the already-emitted `turnIndex`)

**Description.** The clause's stated job is hung-**first**-request detection (#5926). A session that has completed one LLM call is by definition not in its first request → the clause disarms permanently; later quiet turns are owned by stream-stall (S=20min) / silence (T=30min) / hard cap. The child already emits `turn_start nonce=<n> <turnIndex>` (`formatTurnStart` passes `event.turnIndex`) — the parent parse currently ignores the index. No format change; the parent starts capturing it.

**Files touched.** `extensions/builtin-tools/index.ts` (parse `turnIndex` from turn_start, new `firstTurnOnly`/`clauseArmed` latch, clause condition, diagnostics), `extensions/builtin-tools/builtin-tools.test.ts` (E279 series).

**Architecture.** Arm/disarm latch: armed while `maxTurnIndexSeen === 0` AND no completed-turn evidence; disarmed on `turn_start` with `turnIndex > 0`, or `turn_end` marker, or `tool_end` marker (composite disarm mitigates marker loss: a lost first `turn_start` followed by a parsed `turnIndex=1` still disarms; a lost second `turn_start` is recovered by `turn_end`/`tool_end`). Clause 4 gains `&& armed`.

**(a)** ✓ — the quiet verdict turn is turn 2 by construction (turn 1 = the tool round that populated `everSawWork`); once any completed-turn evidence arrives, the clause is dead → mechanisms (i) and (ii) both impossible. The 482s pre-#220 class is doubly safe (#220's `toolsInFlight>0` exemption while in flight; disarm once the round ends).
**(b)** ✓ — a genuinely hung first request never completes turn 1 → armed → cut at M. E279b-style guard pins the armed-turnIndex=0 fixture.
**(c)** ✓ — the armed window is identical to today's behavior; disarmed sessions fall to the same bounded fallbacks.
**(d)** ✓ — no format change (the index is already on the wire); parent-only parse addition + latch + condition + diagnostics.
**(e)** ✓ — E13's fixture has no turnIndex (absent → treated as 0 → armed) → still killed; E15 series untouched.

**Risks.**
- Relies on line integrity for the disarm: first-`turn_start`-lost + second-`turn_start`-lost + `turn_end`-lost simultaneously leaves the parent armed for a working verdict turn. The composite disarm (turnIndex>0 || turn_end || tool_end) makes that a triple-loss corner; document + accept or pin with a fixture.
- **Semantic scope decision for converge to ratify:** "first turn only" means a hung SECOND provider request is never cut at M — it waits for S=20min. That is the correct #198/#208-aligned trade (a hung later request is indistinguishable from a slow generation), but it IS a deliberate narrowing of the clause's coverage, not just a bug fix. Must be stated explicitly in the issue body.

### C2 — Session-latched saw-flags (drop the per-turn reset on BOTH sides)

**Description.** The flags `turnSawMessage`/`turnSawTool` exist to prove "this turn did work" — the bug is the reset. Change the semantics: the child stops resetting them on `turn_start` (rename to session-scoped names, e.g. `sawMessageEver`/`sawToolEver`, to prevent semantic drift), and the parent mirrors the change (its `turn_start` parse case stops resetting; tick `saw_msg`/`saw_tool` also latch session-wide). Clause 4's condition then reads session-latched truth — a session that ever saw a tool or message never trips. Effectively Approach A implemented by redefining existing fields instead of adding a new latch.

**Files touched.** `extensions/task-heartbeat.ts` (two deleted reset lines + renames), `extensions/builtin-tools/index.ts` (parse reset removal + tick latch + renames + clause condition + diagnostics), `builtin-tools.test.ts` (rename ripple + E279 pinning test).

**(a)** ✓ — once latched, never reset. **(b)** ✓ — never-worked → flags false → cut at M. **(c)** ✓. **(d)** — smallest parent-side diff of the set (no new field; two reset lines removed), no format change; but the child must change in lockstep (both sides reset today — one side dropping alone is inconsistent), so it is NOT parent-only.
**(e)** — E13 fixture sets `turnSawTool=true` for the exemption case (still exempt under latched semantics ✓) and `false` for the kill case (still killed ✓); E15 series untouched; E14 untouched (format unchanged). Requires renames in fixtures.

**Risks.**
- **Semantic redefinition of existing fields is the highest confusion risk of any approach.** A future implementer "restoring the reset for correctness" (the flags LOOK per-turn by name and history) silently reintroduces the bug; only the E279 pinning test catches it. Renames mitigate but ripple through fixtures.
- Both sides must drop the reset atomically; mid-rollout, a parent resetting on `turn_start` while the child latches (or vice versa) misbehaves silently — the E279 tests are the only guard.
- Reads of the flags are confined to clause 4 today (verified: clause 3 silence-exempt uses `toolsInFlight`/`effStreamAge`, not the saw flags; alive summaries don't print them) — so the redefinition is safe TODAY, but nothing structurally prevents a future consumer from assuming per-turn semantics.

**Tradeoffs.** Reuse over new state (no new field, no format change) at the price of repurposing well-known per-turn names; C1 achieves the same "later turns exempt" outcome with less semantic ambiguity and is parent-only.

**Best-fit-if (family).** The converge phase ratifies the semantic narrowing (the clause is a first-request detector and should not apply to later turns) and prefers fixing the clause's meaning over adding gate state. Choose C1 if parent-only + explicit `turnIndex` parsing is acceptable; choose C2 only if the team is confident the renames + pinning tests hold against future "simplification".

---

## Approach D — Bound-raise only (widen M / context-aware M)

**Description.** Leave the clause semantics alone; make the bound bigger or work-aware: (i) widen the static M (300s → 600/900s default); (ii) context-aware M (effective bound = M + accumulated prior work, e.g. max tool age seen, so the frozen tool-round age can't exceed it).

**Files touched.** `extensions/builtin-tools/index.ts` (default constant or `getFirstMessageMs` / `effFirstMessageMs` computation), `builtin-tools.test.ts` (E15/E15b/E16 bound values).

**Architecture.** Pure bound math; no new state, no format change, no child change.

**(a)** ✗ — FAILS the requirement for both mechanisms. Mechanism (i): `effStreamAge` includes the ENTIRE tool round (frozen `streamAgeMs`), so a static M cannot bound it — the 905s cut under a latched 900s bound (load≥16, #272 review session) is direct evidence that ANY static M fails. Context-aware M (M + max tool age) fixes (i) but not (ii): a short tool round (30s) followed by a genuinely long silent verdict (>M+30s) still cuts a demonstrably-working sub-agent — the issue's requirement (a) is literal ("fresh heartbeats + prior tool/message activity" → never cut). No bounded M variant can guarantee (a).
**(b)** — widening the base M weakens hung-first-request detection: retryable-undefined resolution latency 300s → 600/900s, circuit-breaker ×3 amplification slower. The context-aware variant keeps the base at 300s for never-worked sessions → (b) preserved in variant (ii) only.
**(c)** ✓ — trivially, all bounds remain finite.
**(d)** ✓ — cheapest implementation (a default constant or one computation).
**(e)** ✗ — E15 (load bands), E15b (monotonic latch), E16 (loop wiring) pin bound values/formulas; changing the default or the effective-bound formula requires deliberate test edits, so the E-series do not stay green untouched.

**Risks.** Masks the mechanism instead of fixing it — every subsequent startup-heavy dispatch is a coin flip under a longer clock (the issue's own evidence: 5 real cuts, 905s under 900s bound). Violates #198/#208 documented intent ("never kill a working agent") and was already rejected in the strategy alignment for this issue ("treats the symptom; a quiet verdict turn after real tool work can exceed ANY static bound"). Accepts recurring destroyed dispatches as the cost of a one-line diff.

**Best-fit-if.** Only as a stopgap PR while a real fix ships (reduce incident frequency, not eliminate), or if the converge phase ratifies that some working-agent cuts are acceptable under load — which contradicts the confirmed problem statement.

---

## Comparison matrix (no winner)

| Requirement | A (latch, parent) | B (child bit in tick) | C1 (first-turn arm) | C2 (latched saw-flags) | D (bound raise) |
|---|---|---|---|---|---|
| (a) never cut working | ✓ | ✓ (strongest) | ✓ | ✓ | ✗ (both mechanisms) |
| (b) hung-first at M | ✓ (E279b-pinned) | ✓ | ✓ (only turn armed) | ✓ | ✗/partial (base widen weakens; contextual keeps) |
| (c) bounded | ✓ | ✓ | ✓ | ✓ | ✓ |
| (d) blast radius | small (1 file) | large (2 files + E14 contract) | small (1 file) | small–medium (2 files, no format) | smallest |
| (e) E-series green | ✓ untouched | E14 must be updated | ✓ untouched | ✓ (rename ripple only) | ✗ E15/15b/16 re-pinned |
| Format change | none | **yes** (tick field) | none (turnIndex already on wire) | none | none |
| Child-side change | none | yes (flag + formatter) | none | yes (drop resets) | none |
| State added | 1 latch | 1 child flag + 1 latch | 1 arm latch + turnIndex capture | 0 (redefined) | 0 |
| Mechanism (i) frozen-turn kill | killed by gate | killed by gate | killed by disarm | killed by gate | masked (not killed) |
| Mechanism (ii) long quiet verdict | killed by gate | killed by gate | killed by disarm | killed by gate | still cuts working agents |
| Key risk | marker-loss residual (tick backstop) | E14 churn + rollout coupling | triple-marker-loss corner + semantic narrowing | field-redefinition drift | accepts destroyed dispatches |

**Cross-cutting (all):** diagnostics must expose the new activity signal at all four alive-summary sites + fix the effective-bound headline bug; E279 series must pin: worked-session-never-cut (regression boundary via the frozen-state construction), never-worked-still-cut (#5926 preservation guard), and each latch/disarm source.

**Open questions for converge (not answered here):**
1. Is the clause's coverage legitimately "first request only" (C-family) or "any turn, gated by evidence" (A/B-family)? The confirmed problem statement ("hung-first-request detection") leans first-request, but A/B keep the clause armed on later turns for never-worked evidence states.
2. Is wire-format change acceptable (B) given the E14 drift contract exists precisely to make it costly?
3. Should the marker-loss residual of A/C1 (first-round line-buffer overflow) be fixed in-scope (marker robustness) or triaged via diagnostics?
