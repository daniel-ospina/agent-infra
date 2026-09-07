---
title: "#561 — VGATE ceremony cost (state-bearing diagnostics + observable bridge state) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-06
aboutSubjects: organisation-design-team, verification-gate
aboutObjects: agent-infra, issue-561, issue-482, issue-285
---

# Scope & Plan — #561: VGATE ceremony cost (state-bearing diagnostics + observable state)

> issue-scoping v5.1 double diamond. Created 2026-09-06. Issue: #561 (complexity:standard, org-design).
> Incident archaeology: heterogeneous — #513 (review-enforcer merge-verdict attestation; out of VGATE component), #489 (pre-fix stdout-buffering silence watchdog, fixed in builtin-tools/task-heartbeat), #469 (pi-session memory hygiene / Jetsam), #490 (git-parser interception hole; T1 shipped #560, follow-up #559 out of scope). The shared, still-open, VGATE-owned defect class across the incidents: feedback-free retry loop + unobservable state.

## Confirmed Problem

The [VGATE] dispatch→verify→retry ceremony loop has **no state feedback**: after an unmergeable verifier dispatch (prose output, placeholder/mistyped sha256, zero-merge PASS, FAIL verdict), the retried git op re-blocks with an *identical generic* message (`buildSubAgentBlockMessage` index.ts:1966-2011; block assembly ~2355-2385), so standard/complex task-sub-agent runs re-dispatch identical verifiers until budget exhaustion (6+ incidents, 2026-09-05/06). Compounding:
1. LLM transcription of sha256 + exact-JSON is a single point of failure (extension rejects PLACEHOLDER hashes ~1943-1962; mismatch re-blocks at the next git op).
2. Verification state is unobservable/unclearable except manual `~/.pi/agent/verification` surgery (`clearBridge` index.ts:265 — zero live callers).
3. `vgateFailures` counts only 3 format classes (empty/no-text/unparseable-without-prompt-files, ~2402/2420/2600); FAIL verdicts (~2626), zero-merge PASSes (~2657/2685), and the sub-agent fail-open refusal (~2567-2576) never increment it — the machinery is blind to most of the loop.

**Fail-closed invariants (must be preserved):** no sub-agent auto-bypass (#7591, gated `if (!isTaskSubAgent())` ~2294); no child gate-disable (#285 refusals ~178-193 at 2406/2423/2603); verifier stays a separate fresh context (the gated agent can never be its own notary); unit 241/0 + e2e 66/66 stay green at the new head.

## Verification Gates

### problem-verify: 1 cycle, clean (2 fresh verifiers — NO P0/P1; P2s incorporated)
Findings incorporated: indicator-1 must require **state-bearing** messages (prior class + attempt count + escalation at threshold), not cosmetic text; failure-class taxonomy required; interactive one-way disable latch folded into observability; record-keeping duties (rejected framings, devil's-advocate resolutions, explicit body-framing challenge) landed in this doc; incident set enumerated above.

### solution-verify: 1 cycle, clean (2 fresh verifiers — NO P0/P1; P2s incorporated)
Findings incorporated: judgment-vs-dispatch class taxonomy (#132 doctrine — FAIL verdicts are successful dispatches, never format failures); plain-text-PASS merged>0 (~2533) success reset; session_start reset of new state; e2e scenario **64** (42 is taken); restricted sessions can't fire tool_result → streak unreachable there (documented); vgate.sh status semantics (bridge+audit union only; in-session streak dies with the process); pinned-phrase hygiene list.

### [SECOND-MODEL-GATE] coherence: deepseek/deepseek-v4-pro — clean (NO P0/P1)
Findings incorporated: streak(4 classes) vs latch(3 classes) membership divergence stated explicitly; streak reset on plain-text PASS is deliberate and does NOT touch the latch; foreign-root residual diagnosability gap accepted; audience-neutral escalation copy; append at the block-assembly CALL SITE (never inside `buildSubAgentBlockMessage` — keeps pinned-function tests hermetic); `bridge_clear` union extension is type-documentation (appendJsonl is `Record<string, unknown>`).

## Decisions (a)-(d)

- **(a) Cost-reduction mechanism: state-bearing ceremony diagnostics + observable/clearable bridge state.** In-session dispatch-failure state → the retried block message names the prior failure class + remedy + attempt count, escalating at the 3-strike threshold to STOP-and-fix instead of generic re-dispatch. Plus `scripts/vgate.sh status|clear`, audited interactive disable, dual-cause hash-mismatch remedy, and 01-preflight.md ceremony-diagnostics docs. Rejected: **docs-only clarity** (zero behavioral delta on the feedback loop — the loop is blind, not uninstructed); **deterministic verifier-side hash helper via dispatch-template surgery** (template at index.test.ts:1266 is the most load-bearing pinned string in the file and concurrent agents edit it; helper compliance is probabilistic — the transcription class dies only when the verifier actually runs it; covers 1 of 7 classes; if post-ship evidence shows the schema-near-miss refusal loop persisting despite the sha256sum remedy, the helper is the deterministic fallback for that single class); **hash-less PASS contract** (relaxes verifier-authoritative stored-hash provenance — #190/#320, "verifier is the authority" ~1784-1790 — which indicator 3's "gate strength unchanged" argues against; the existing empty-verified_files fallback ~2657 already provides the bounded diff-scoped path).
- **(b) Threshold-3 behavior:** currently — `vgateFailures` latch (3 format classes only) auto-disables *interactive* sessions at ~2406/2423/2603 (one-way, no re-enable); #7591 auto-bypasses interactive after 3 block attempts on the same files (~2290-2318); task sub-agents get BOTH refused via #285 (gate stays ACTIVE, block final). **Change:** a separate `dispatchStreak` (dispatch-format classes only: empty-content, no-text, unparseable-without-files, fail-open-refused) escalates **messaging** at ≥3 — never any disable/bypass (no #7591 path, no latch path). Judgment classes (JSON FAIL, prose hasFail) and zero-merge classes record their class for remedy text but never move the streak (#132: "a FAIL is a SUCCESSFUL dispatch"; zero-merge proves nothing about dispatch health). The vgateFailures latch and #7591 semantics are byte-unchanged; the interactive disable sites gain an audit event.
- **(c) Task-restricted deadlock:** preserved orchestrator-visible fail-closed — final block + return-to-parent (pinned text unchanged), **no escape hatch** (#285 invariant). Streak diagnostics are unreachable in restricted sessions by construction (no task tool → no tool_result events in-process) — documented, not engineered around.
- **(d) Scope boundary:** #559 (rename-source shape detection, index.ts ~1100-1330 + follow-up note ~2255-2258) is NOT absorbed. Touched regions are disjoint: state ~126-141, session_start reset ~2038-2043, block assembly ~2355-2385, tool_result ~2395-2690, audit-log union, new `scripts/vgate.sh`, 01-preflight.md prose (outside the drift fence 367-374). Both #561 and #559 append e2e scenarios at the file tail (ours = 64) — merge adjacency only; reconcile via git merge, never by reverting the other.

## Implementation Plan

1. **index.ts state (~126-141):** `type DispatchFailureClass = "empty-content" | "no-text" | "unparseable" | "fail-open-refused" | "fail-verdict" | "zero-merge-pass";` + `let lastDispatchClass: DispatchFailureClass | null = null; let dispatchStreak = 0;` (never feeds any disable/bypass path). Reset both in session_start (~2038-2043 reset block).
2. **Pure exported helper `formatCeremonyDiagnostics(klass, streak): string`** (near buildSubAgentBlockMessage ~1966): per-class remedy text (below); when streak ≥ VGATE_FAILURE_THRESHOLD (3) prepend escalation. Audience-neutral escalation copy (safe for interactive AND task-capable sub-agents; contains none of the pinned negative phrases: "Dispatch the verifier sub-agent", "Report this block", "This session has the task tool", "Dispatch your own VGATE verification"):
   `⛔ Escalation: {streak} consecutive malformed VGATE dispatches (last: {class}). STOP re-dispatching the same verifier shape. {remedy} The gate stays ACTIVE and will NOT auto-bypass (#285). Fix the dispatch to satisfy the format requirements above, then retry the git operation.`
3. **Wiring (tool_result ~2395-2690):** `recordDispatchFailure(klass)` at the dispatch-format terminals (empty ~2402, no-text ~2420, unparseable-no-prompt-files → vgateFailures++ site ~2600, sub-agent fail-open refusal ~2567-2576 → class `fail-open-refused`); `recordDispatchJudgment(klass)` (no streak) at JSON-FAIL ~2626 + hasFail ~2456 (`fail-verdict`) and zero-merge sites ~2540/2657/2685 (`zero-merge-pass`); `recordDispatchSuccess()` (streak=0, class=null) at every merged>0 site INCLUDING plain-text-PASS ~2533 (deliberate divergence from the vgateFailures latch, which does not reset there — do NOT touch the latch). Foreign-root dispatch (foreign=true ~2495/2637): no record (benign routing non-event; residual diagnosability gap for wrong-root proactive dispatches accepted against indicator 1).
4. **Block assembly (~2355-2385, CALL SITE only):** build the message as today, then append `formatCeremonyDiagnostics(...)` when `lastDispatchClass !== null`. Never inside buildSubAgentBlockMessage (hermetic pinned-function tests).
5. **Hash-mismatch remedy (mismatch arm only ~2358-2364):** append per-file remedy after expected/actual: `remedy: the file changed after verification, OR the verifier returned a wrong hash — never hand-type sha256; run sha256sum <file> and re-dispatch the exact hash`. Keep the `Hash mismatch` header + expected/actual lines (pinned).
6. **Interactive disable audit (~2406/2423/2603 else-branches):** `appendJsonl({ event: "gate_bypass", extension: "verification-gate", reason: "vgate_failure_threshold_disable", ... })` before `extensionEnabled = false`. Disable semantics unchanged.
7. **shared/audit-log.ts:** extend GateEventName union with `"bridge_clear"` (type-documentation — appendJsonl itself is `Record<string, unknown>`).
8. **New `scripts/vgate.sh`:** `status` — bridge path/mtime/entry count, per-entry root/file/stored-hash + disk match-or-drop preview, audit tail; `clear` — default current-root-scoped rewrite (drops only that root's entries from latest.json); `--all` removes the file; JSONL audit append (`gateEventsFile()` path). Fail-closed: clearing only removes verified state → re-blocks; never a bypass. Documented: status = bridge+audit union only (in-session streak/registry die with the process); clear is cross-process — a *running* session's stuck block is cured by the in-band escalation, not the CLI.
9. **01-preflight.md** (after the VGATE-SHAPE-RULE fence ~410): "VGATE ceremony diagnostics & recovery" — per-failure-class symptom→remedy table; dual-cause hash-mismatch note + sha256sum rule; vgate.sh usage (via $AGENT_INFRA_PATH); threshold semantics (streak escalates messaging only; gate never auto-disables for sub-agents; interactive disable = 3 format classes, now audited). Machine-read fences byte-identical.
10. **Tests:** unit — new section in index.test.ts for the pure formatter (per-class remedy presence, escalation at 3, no-escalation below 3) + reset semantics via exported record fns (must be exported for the pure-export suite pattern); NO existing test modified. e2e — scenario 64 appended at tail: sub-agent commit blocked → unparseable dispatch (streak 1) → retried commit block names the class + remedy → 3rd malformed dispatch → escalated block (≤2 retries to escalation: indicator-1 proof) → proper JSON PASS → commit allowed.
11. **Plan doc + scoping comment + labels** (this doc; comment on #561; scoping → scoped).

### Rejected alternatives (with when-better)
| Approach | Why rejected | When it WOULD have been better |
|---|---|---|
| Docs-only clarity (decision a-1) | Zero behavioral delta on the blind loop; indicator 2 unmet | If postmortems showed agents lacked instructions (they don't — messages already carry the template) |
| Verifier-side hash helper, template surgery (decision a-3/B) | Template 1266 is the most-collision-prone string under concurrent edits; compliance probabilistic; 1/7 classes | Post-ship evidence of a persistent schema-near-miss refusal loop despite the sha256sum remedy |
| Hash-less PASS contract (decision a-3/C) | Relaxes verifier-authoritative hash provenance (#190/#320) — fails indicator 3 spirit | If dispatch-format retries dominate despite diagnostics (provenance tradeoff then negotiable) |
| Hard retry cap for sub-agents | Requires disable or new final-block — violates #285 | Never (invariant is non-negotiable) |

## Wiring Check
| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| Bridge file ~/.pi/agent/verification/latest.json | cross-cutting | vgate.sh status/clear (item 8) | ✅ |
| Audit log gate-events.jsonl | cross-cutting | appendJsonl + vgate.sh JSONL | ✅ |
| 01-preflight.md drift fences | docs | item 9 (outside 367-374) | ✅ |
| Pinned tests (unit 1250-1295, e2e 22/25/34-37) | tests | append-only/call-site/deliberate taxonomy | ✅ |
| #559 rename-source region | concurrent | disjoint regions (decision d) | ✅ |
| CI pipeline-compliance | external | PR body: Fixes #561 + scoping marker + plan doc + review evidence | ✅ |

## Acceptance Criteria
1. `NODE_ENV=test npx tsx index.test.ts` ≥ 241 pass, 0 fail; `index.e2e.test.ts` 66 + new scenario 64 pass, 0 fail — at PR head.
2. E2E scenario 64 demonstrates: (a) recovery on the FIRST guidance message after one malformed dispatch, and (b) a stubborn prose-verifier loop escalates within ≤2 further malformed re-dispatches of the first guidance message (indicator 1 proof) — with the streak still counting and the gate still blocking past escalation (no disable for sub-agents).
3. `scripts/vgate.sh status|clear` works (indicator 2 proof) — bridge observable + root-scoped clearable without manual surgery. Evidence: exercised against sandboxed bridge copies (status preview incl. per-entry disk match-or-drop; root-scoped clear preserves foreign-root entries; `--all` removes the file; JSONL `bridge_clear` audit appended) during implementation.
4. No gate-mechanics change: no new bypass, no disable-path change, #285 refusals + #7591 guard byte-unchanged.
5. Fresh-context code-review gate returns NO ISSUES FOUND at PR head; review recorded at exact merged head.
