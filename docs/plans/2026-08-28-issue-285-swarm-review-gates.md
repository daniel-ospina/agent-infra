---
title: "Issue #285 — sub-agent envs run with REVIEW GATES DISABLED (ELDATO_SKIP_VGATE=1)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-285, review-enforcer, verification-gate
---

# Implementation Plan — Issue #285: sub-agent envs run with REVIEW GATES DISABLED

**Scope phase:** issue-scoping v5.1 double diamond (standard tier), completed 2026-08-28. Prior scope posted on the issue 2026-08-28T10:06Z + amendment 10:15Z; verification cycles 2–4 run by this session (see Review Cycle Log). This doc materializes the verified scope (v5) as the implementation contract.

## 1. Problem Statement

Task-dispatched sub-agents boot with `⚠️ REVIEW GATES DISABLED — all quality checks bypassed` + `[verification-gate] ⏸️ Disabled — ELDATO_SKIP_VGATE=1`, so swarm PRs bypass the VGATE, review-registry, and manifest gates.

The issue conflates **three distinct mechanisms** (verified by code tracing):

| # | Mechanism | Layer | Fix surface |
|---|-----------|-------|-------------|
| M1 | `swarm_daemon.py:115-116` (daniel-ospina/swarm) launches pi sessions with `ELDATO_SKIP_VGATE=1` + `AGENT_SKIP_REVIEW_GATE=1` + `AGENT_ALLOW_MAIN_EDITS=1` | launch env (parent) | **follow-up issue (swarm repo)** — out of agent-infra PR scope |
| M2 | agent-infra `task` tool (`extensions/builtin-tools/index.ts` `subAgentEnv = { ...process.env, ... }` at L2283-86) and `subagent` tool (`extensions/subagent/index.ts:534` `env: { ...process.env, PATH }`) **spread the parent env**, inheriting `ELDATO_SKIP_VGATE=1` into task children — silently defeating the #825 contract ("VGATE stays ACTIVE for sub-agents") | dispatch boundary | ✅ **fix here** |
| M3 | `AGENT_SKIP_REVIEW_GATE: "1"` is **deliberately** forced in `subAgentEnv` (#825: review DISPATCH stays parent-enforced — a sub-agent must never self-satisfy the review-enforcer); its "all quality checks bypassed" message is misleading for sub-agents | dispatch boundary (by design) | ⚠️ keep the flag; make the message truthful; keep the merge-registry gate ACTIVE |

**Confirmed problem statement:** Task-dispatched sub-agents inherit `ELDATO_SKIP_VGATE=1` from the parent launch env through the `...process.env` spread in both sub-agent dispatchers, so the verification-gate disables itself at process start (passive warning) — defeating the #825 design where sub-agents run VGATE ACTIVE with the parent's verified-file registry via the bridge. The review-enforcer child disable is by design (#825, parent-enforced ceremony); its message must be truthful, and the merge-registry gate (#138) must stay ACTIVE in sub-agents so PR merges require a `reviews/<PR>.json` record. The missing review-registry entries and manifest drift originate at the **parent** layer (swarm daemon env + no record-review wiring in the swarm flow) — tracked as follow-up issues, not fixable from an agent-infra PR.

**Falsification check:** if a builtin-tools child of a clean parent still shows `⏸️ Disabled` at session_start, the leak is elsewhere (shell rc / other dispatcher) — the polluted-parent e2e guards this. If stripping `ELDATO_` vars causes sub-agent commits to deadlock (bridge-empty → every commit blocks with no self-verify path), the #825 in-band self-satisfy design regressed.

**Confidence:** high for M2/M3 (verified in agent-infra code), medium for M1 (swarm repo state varies across copies — re-verify at execution).

## 2. Proposed Solution (Fix A–D + P1/P2 amendments)

### Fix A — Strip inherited bypass vars at BOTH dispatch boundaries

- `extensions/builtin-tools/index.ts` `subAgentEnv` (L2283-2325): after the `...process.env` spread, explicitly `delete subAgentEnv.ELDATO_SKIP_VGATE; delete subAgentEnv.ELDATO_SKIP_REVIEW_GATE;` (the inherited/accidental variants).
- `extensions/subagent/index.ts:534`: same key-specific strip in the spawn env.
- **Keep `AGENT_SKIP_REVIEW_GATE: "1"`** — deliberate #825 (review dispatch parent-enforced).
- **Key-specific only, never a prefix sweep:** `ELDATO_ALLOW_MAIN_EDITS` + `AGENT_ALLOW_MAIN_EDITS` (dual-support #7549) must survive — they are the branch-ownership axis (main-worktree-guard M2/M3 escape hatch, #7470: must NOT disable commit verification).
- Fix D must assert the `delete` calls exist AFTER the spread and that no subsequent line re-assigns them; the polluted-parent e2e is the authoritative check (the static "must NOT inject" assertion at builtin-tools.test.ts L223-232 matches only the literal `"1"` form and cannot catch the runtime spread re-injection).

### Fix B — Fail-closed in verification-gate for task sub-agents

`isTaskSubAgent()` = `TASK_HEARTBEAT === "1" && PI_MODE === "print"` (L160).

- `session_start` (~L915/L916): if `isTaskSubAgent() && ELDATO_SKIP_VGATE === "1"` → do NOT disable. Plain-text WARN ("bypass refused for task sub-agent — VGATE stays ACTIVE (#285)") + actionable instruction (see Fix P1-A task-tool-aware branch) + `appendJsonl("gate_bypass_refused")`; `extensionEnabled = true`.
- `tool_call` per-command bypass (~L945, #37): same refusal for task sub-agents.
- **Explicit non-coverage:** swarm daemon workers (PI_MODE=print, no TASK_HEARTBEAT) are NOT `isTaskSubAgent()` by design (L153-158 comment) — their VGATE disable persists until the M1 follow-up lands (out of repo). Do NOT extend the refuse to them in this PR.

### Fix P1-1 — No auto-bypass disable for task sub-agents (ALL THREE vgateFailures sites)

Extract a shared helper `refuseAutoBypassForSubAgent()` (module-level, following the inlined `isTaskSubAgent` pattern — do NOT create a sibling file; extension-loader constraint at index.ts:44-46 forbids it). Route **all four** `extensionEnabled = false` sites through it:

- L1173 (empty verifier content)
- L1185 (no text content)
- L1347 (unparseable output, no mergeable prompt files)
- L916 (session_start escape hatch — same helper for consistency)

At each: `isTaskSubAgent()` → WARN (plain text) + `appendJsonl("gate_bypass_refused")` + keep blocking (`extensionEnabled` stays true); else → existing behavior.

**Do NOT add an `extensionEnabled` check to the tool_result handler itself** (Aug-12 plan L144: "would gut D2" — the handler must keep writing the bridge; the stored-hash match-or-drop makes stale entries inert).

### Fix P2-B — Refuse the #5724 fail-open prompt-merge for task sub-agents

`tool_result` handler, "Verifier unparseable — fail-open" branch (~L1318-1347): when `isTaskSubAgent()` and the response is unparseable (no FAIL, no PASS, no valid JSON) → do NOT merge prompt files. Mirror the hasFail path (A.3b):

- do NOT increment `vgateFailures`
- do NOT consume `lastBlockedCwd`/`lastBlockedFiles` (keep block state for the re-dispatch)
- WARN + `appendJsonl("gate_bypass_refused")` + return undefined (still blocked)

Interactive sessions keep the #5724 fail-open unchanged (model JSON-compliance noise must not block a legit user). The plain-text-PASS branch (~L1266-1314, line-anchored genuine PASS signal) is unchanged for both — it is a real verdict.

### Fix P1-2 — Uniform sub-agent classification for the subagent tool

`extensions/subagent/index.ts` spawn env (L534): set `TASK_HEARTBEAT: "1"` + `PI_MODE: "print"` **+ `TASK_HEARTBEAT_DISABLE: "1"`**:

- classification preserved — `isTaskSubAgent()` reads the pair only
- emitter inert — `taskHeartbeatActive()` (task-heartbeat.ts L77-83) gates on the pair **and** `TASK_HEARTBEAT_DISABLE !== "1"` (without DISABLE, every subagent-tool child would emit `[task-heartbeat]` markers with an empty nonce into `currentResult.stderr` — polluting every dispatch result)

Also strip `ELDATO_SKIP_VGATE` / `ELDATO_SKIP_REVIEW_GATE` / inherited `AGENT_SKIP_REVIEW_GATE` there (Fix A extended). Result: Fix A + B + C + E cover BOTH dispatchers uniformly.

**Posture (documented):** restricted agents (planner/verifier/reviewer/scout/code-reviewer/bug-scanner — `--tools` allowlists without `task`) are read-only by design; if ever handed a write+commit task they hard-block (no #7591 auto-bypass, no in-band self-satisfy) → escalate to the parent.

### Fix P1-2b — Review-enforcer merge-registry gate ACTIVE in task sub-agents

`extensions/review-enforcer/index.ts`: add a local `isTaskSubAgent()` (TASK_HEARTBEAT=1 && PI_MODE=print, mirroring verification-gate).

- `_skipReviewGate()` && task sub-agent → `extensionEnabled = true` but the **DISPATCH-count gate** (git commit/push/gh pr create — dispatchCount check) is skipped; the **`gh pr merge` merge-registry gate** (#138, `evaluateMergeGate` — blocks unless `~/.pi/agent/reviews/<PR>.json` exists with verdict `clean`/`clean-micro` + head match) **stays ACTIVE**.
- `_skipReviewGate()` && interactive → full bypass (emergency escape hatch preserved, unchanged).
- Task sub-agents previously got `extensionEnabled=false` → both create AND merge were ungated; after: create stays ungated (status-quo-equivalent, **no new** zero-review-create vector — `gh pr create` cannot trip the merge gate), merge flips from ungated → **fail-closed**. Strictly safer.

### Fix P2-a — Audit truthfulness

- review-enforcer `session_start` currently logs `logGateEvent("gate_bypass", { reason: "escape_hatch" })` (L433 — OUTSIDE the #133 isPrintMode guard, which wraps only the console JSON) for ALL modes incl. task sub-agents → a false "escape_hatch bypass" record for every sub-agent (AGENT_SKIP_REVIEW_GATE=1 is always forced). After P1-2b the sub-agent gate is NOT bypassed (merge gate active) — the record is semantically false.
- Fix: task sub-agents emit `appendJsonl("review_gate_parent_enforced")` (new event string — `appendJsonl` is untyped, raw-string precedent exists: `gate_skip`, `gate_recovery_empty`; **no GateEventName union change needed**); `gate_bypass/escape_hatch` stays for interactive only.
- New event name chosen over "review_dispatch_parent_enforced" (review_dispatch is already the tool_result counting event — would overload the taxonomy).

### Fix P1-A — Task-tool-aware block messages (both surfaces)

**Detection:** comma-split set-membership on the `--tools` value in `process.argv` (the subagent tool passes `agent.tools.join(",")` at subagent/index.ts L479). Task-capable iff `"task" ∈ allowlist` or no `--tools` flag. Reuse/export a value-taking-flag-aware argv parser (print-mode.ts precedent) handling `--tools`/`-t`/`--tools=`; treat `--exclude-tools task`/`--no-tools` as restricted. Add an argv param seam for deterministic e2e (the test harness's process.argv has no `--tools`).

**Surface 1 — verification-gate block message** (`subAgentReason`, L1134-1152): the current text unconditionally says "This session HAS the task tool, so verify them in-band" — false for all 7 task-restricted user agents (verified: bug-scanner, code-reviewer, planner, reviewer, scout, verifier, product-verifier exclude `task`; only worker.md is unrestricted). Branch:

- task-capable → existing in-band self-satisfy text (dispatch `[VGATE] verify files: ...` via task, retry)
- task-restricted → "STOP — this block is final; do not bypass; return to the parent session (it runs the verification ceremony and will re-dispatch you)."

**Surface 2 — session_start bridge-absent warning (L894-899):** same unconditional "in-band via the task tool" claim → same task-tool-aware branch (task-capable → in-band instruction; restricted → return-to-parent instruction).

### Fix C — Truthful review-enforcer message for sub-agents

- Print-mode sub-agent: `[review-enforcer] review DISPATCH is parent-enforced (#825) — the parent session runs the review ceremony; VGATE + merge-registry gate protect this PR` instead of `⚠️ REVIEW GATES DISABLED — all quality checks bypassed`.
- Interactive keeps the full warning + JSON audit (#133 guard stays).
- **Merge-gate block message (evaluateMergeGate no-record reason, L280-295):** the emergency line "set AGENT_SKIP_REVIEW_GATE=1 ... to bypass all gates" is FALSE for task sub-agents (flag already set, merge gate stays ACTIVE by #285). Make shape-aware: task sub-agent → "the parent session must record the review (record-review.sh <PR> <head_sha> clean); the bypass flag does NOT unlock sub-agent merges (#285)".

### Fix D — Tests

1. `extensions/builtin-tools/builtin-tools.test.ts` (≈160 tests): update the #825 section — assert `subAgentEnv` strips `ELDATO_SKIP_VGATE`/`ELDATO_SKIP_REVIEW_GATE` (delete calls present after the spread, no re-assignment), still sets `AGENT_SKIP_REVIEW_GATE: "1"` (#825), and BOTH `ELDATO_ALLOW_MAIN_EDITS` + `AGENT_ALLOW_MAIN_EDITS` remain (regression for Fix A key-specific strip).
2. `extensions/builtin-tools/subagent-integration.test.ts`: simulate a polluted parent env (set `ELDATO_SKIP_VGATE=1` + `ELDATO_SKIP_REVIEW_GATE=1` in the test env) → assert the subAgentEnv block deletes them; assert markers + `TASK_HEARTBEAT_DISABLE=1` present in the subagent-tool child env (P1-2).
3. `extensions/verification-gate` e2e (harness at index.e2e.test.ts L657-747):
   - task sub-agent session (TASK_HEARTBEAT=1 + PI_MODE=print) + `ELDATO_SKIP_VGATE=1` → gate does NOT disable, still blocks unverified commits (Fix B)
   - 3× empty-content VGATE results → still blocks (P1-1, L1173)
   - 3× unparseable-no-prompt-files → still blocks (P1-1, L1347)
   - task sub-agent + garbage-with-files dispatch → still blocked, files NOT recorded, vgateFailures NOT incremented (P2-B)
   - refused-bypass WARN present + `gate_bypass_refused` audit event written
4. `extensions/review-enforcer/index.test.ts`:
   - task sub-agent `gh pr merge` with no record → blocked (merge gate active, P1-2b); with clean record → allowed
   - task sub-agent's in-band [VGATE] dispatch produces NO `review_dispatch` record (P2 tool_result noise — see below) and no "📊 Reviewer dispatch counted" line
   - interactive bypass unchanged (escape hatch preserved)
   - task sub-agent audit event is `review_gate_parent_enforced`, not `gate_bypass` (P2-a)
5. **Review-enforcer tool_result noise (P2, incorporated):** the tool_result handler (~L517-527) counts every task dispatch as `review_dispatch` — under P1-2b, task sub-agents keep `extensionEnabled=true`, so their own in-band [VGATE] dispatches would be counted/audited as review dispatches (today silent via early return). Add `if (isTaskSubAgent()) return undefined;` after the toolName check (dispatch counting is skipped for them anyway).
6. **Instruction branching (P2, incorporated):** Fix P2-c's "report to parent for re-dispatch" is wrong for task-CAPABLE sub-agents (contradicts #264's "do not ask the parent to re-run this task"). Branch on task-tool presence: task-capable → "re-dispatch your own [VGATE] verification with the required JSON format"; restricted → "STOP — return to parent session for re-dispatch". The re-dispatch loop terminates: unparseable → WARN → re-dispatch → valid JSON PASS → merge → retry.

Verify the full suites: `npx tsx extensions/builtin-tools/builtin-tools.test.ts`, `extensions/builtin-tools/subagent-integration.test.ts`, `extensions/verification-gate/index.test.ts` + `index.e2e.test.ts` (run with `env -u ELDATO_SKIP_VGATE`), `extensions/review-enforcer/index.test.ts`.

## 3. Behavior-Change Register (all intentional, documented for reviewers)

| Change | Detail |
|---|---|
| sequence-enforcer gate→warn flip for subagent-tool children | Adding PI_MODE=print flips resolveMode default from gate → warn (#201 design: "pi -p workers default to warn"; AGENT_SEQUENCE_MODE/PI_ENFORCER_MODE overrides still force gate/strict). ACCEPTED, not pinned. Impact lands on epic-executor/parallel-orchestrator subagent-tool children (code-review dispatches via task(), not the subagent tool). |
| #7591 auto-bypass removed for subagent-tool children | P1-2 markers make them isTaskSubAgent() → the 3-attempt auto-bypass (L1059, already `!isTaskSubAgent()`-guarded) becomes unreachable for them (interactive before). Restricted one-shot agents: block final → parent re-dispatch (P1-A). Intended fail-closed. |
| Emergency-parent edge | ELDATO_SKIP_VGATE=1 applies to the interactive session only; its task children run fail-closed (strip + refuse) and must self-satisfy VGATE in-band or return to parent. |
| Merge gate flips from inert → active for task sub-agents | gh pr merge in sub-agents now blocks without a reviews/<PR>.json record (P1-2b). Fail-open only on `currentHead === null` (pre-existing same-user trust, #212). |

## 4. Follow-up Issues (filed during this PR, NOT in scope)

**Follow-up 1 — swarm repo (M1):** remove `ELDATO_SKIP_VGATE` + `AGENT_SKIP_REVIEW_GATE` from `swarm_daemon.py` `run_pi` env. Pinned precisely:

- Target: LIVE copy `~/swarm/swarm` (HEAD **ab693683** — verified dirty at `operations/coordination/swarm_daemon.py:115-116`). Outer copy `~/Documents/GitHub/swarm` (HEAD **29dd67e8**) is already clean and has `test_swarm_daemon_run_pi_env_has_no_gate_disabling_vars` (def ~L312) — use as model.
- **Test port semantics:** the clean copy's test iterates over `("AGENT_ALLOW_MAIN_EDITS", "ELDATO_SKIP_VGATE", "AGENT_SKIP_REVIEW_GATE")` asserting all absent — a verbatim port FAILS if we keep `AGENT_ALLOW_MAIN_EDITS=1` in the daemon env. Make an explicit keep/remove decision on ALLOW_MAIN_EDITS aligned with the clean copy (which dropped all three) and adapt the ported test tuple to the two gate vars only.
- **Execution-path check:** verify which copy `headless_agent.py` (imports `agent_daemon`) imports swarm_daemon from. The launchd watchdog plist (`com.eldato.swarm-watchdog.plist`) is **report-only** — irrelevant to execution; `run_headless.sh` is a placeholder stub in the live copy — do not pin on it.
- Wire `record-review.sh` into the swarm reviewer phase so the merge-registry gate has evidence (without it, enabling the gate in swarm sessions blocks merges — intended fail-closed).

**Follow-up 2 — tortoise repo (CI backstop):** the issue's fix direction 3 (manifest drift at PR time) is owned by the existing tortoise #1262 gate (verified: CLOSED "drift gate blind spot...") + agent-infra `check-pipeline-compliance.sh`/`drift-check.yml` — both already fail-closed on all PRs. Ensure the stale-branch caveat is tracked tortoise-side (out of agent-infra scope).

## 5. Rejected Alternatives

| Approach | Why rejected |
|---|---|
| Strip `AGENT_SKIP_REVIEW_GATE` from subAgentEnv (issue fix direction 1, literal) | Violates #825 (parent-enforced review dispatch); deadlocks swarm merges (merge-registry gate fail-closed on missing `reviews/<PR>.json`, nothing in the swarm flow writes records); flips 2 test suites; reintroduces the #33 leaf-commit deadlock. |
| Fail-closed in review-enforcer (refuse the #825 child bypass) | The child DISPATCH disable is BY DESIGN; refusing it blocks every sub-agent commit (dispatch-count gate) and merge — the exact deadlock #825 avoided. Only the message + merge-gate split needed. |
| Fix only the swarm daemon (M1) in this PR | Cross-repo (swarm repo); requires record-review wiring or merges break; out of scope for an agent-infra PR — filed as follow-up issue. |
| CI-side backstop only (direction 3) | Tortoise #1262 + agent-infra drift-check already exist and fail closed. Review-registry records are local files (`~/.pi/agent/reviews/`) — no CI backstop is possible. Complementary, not a substitute. |
| Do nothing (accept passive warnings) | The leak defeats the #825 contract silently; manifest drift + unreviewed merges continue (the observed P1). |
| Prefix-sweep env strip (delete all ELDATO_*) | Would remove `ELDATO_ALLOW_MAIN_EDITS` — the branch-ownership escape hatch required for worktree write flows (#7470/#7549). Key-specific strip only. |

## 6. Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| builtin-tools subAgentEnv | dispatch env | Fix A + tests | ✅ |
| subagent tool spawn env | dispatch env | Fix A + P1-2 + tests | ✅ |
| verification-gate session_start + per-command bypass + 3× vgateFailures sites + fail-open merge | gate read-at-start + auto-bypass | Fix B + P1-1 + P2-B + e2e | ✅ |
| verification-gate block messages (L1134 + L894) | gate message | Fix P1-A (task-tool-aware branch) | ✅ |
| review-enforcer merge-registry gate | gate | Fix P1-2b + unit tests | ✅ |
| review-enforcer messages + audit | gate message + audit | Fix C + P2-a + tool_result noise fix | ✅ |
| swarm_daemon.py env (M1) | launch env (parent) | follow-up #1 (swarm repo) | ⚠️ tracked |
| tortoise manifest gate #1262 + agent-infra drift-check | CI backstop | exists — no change; stale-branch caveat tortoise-side | ⚠️ tracked |
| record-review.sh wiring in swarm flow | review registry | follow-up #1 | ⚠️ tracked |
| No DB / API / auth / external services | — | — | ✅ n/a |

## 7. Runtime Prerequisites

- None beyond the existing extension runtime. Zero new dependencies (repo is dep-free by design): all changes use existing `process.env`, existing `isTaskSubAgent()`/`isPrintMode()` helpers, existing `appendJsonl` audit path.
- `isTaskSubAgent()` semantics (TASK_HEARTBEAT=1 && PI_MODE=print) must be kept drift-guarded with the existing E14-style drift tests between verification-gate, review-enforcer, and task-heartbeat.

## 8. Acceptance Criteria

1. A `task`-dispatched sub-agent's stderr shows gates ENABLED — no "REVIEW GATES DISABLED — all quality checks bypassed" line; the truthful "[review-enforcer] review DISPATCH is parent-enforced (#825); merge-registry gate ACTIVE (#285)" variant; `[verification-gate]` never prints `⏸️ Disabled` for a task sub-agent even under a polluted parent env (e2e-verified).
2. A task sub-agent's unverified commit still blocks; the block message instructs truthfully (in-band self-satisfy if task-capable; return-to-parent if restricted); NO path exists for a task sub-agent to auto-bypass VGATE (3× any failure class, or fail-open merge — all e2e-covered).
3. Sub-agent `gh pr merge` is blocked without a clean `reviews/<PR>.json` record (merge-registry gate active, #138) — the enforcement point that makes "Sub-agent PRs carry reviews registry records" achievable; record production wired swarm-side (follow-up #1).
4. `ELDATO_SKIP_VGATE`/`ELDATO_SKIP_REVIEW_GATE` never reach a child from either dispatcher (Fix A + polluted-parent e2e); `AGENT_SKIP_REVIEW_GATE: "1"` and both ALLOW_MAIN_EDITS variants still set (no #825/#7470 regression).
5. Interactive sessions keep both emergency escape hatches unchanged (full warning + JSON audit; ELDATO_SKIP_VGATE bypass).
6. Existing suites green: builtin-tools, subagent-integration, verification-gate unit + e2e, review-enforcer unit.

## 9. Review Cycle Log (scope-verify gates)

- **Cycle 1 (prior session, on-issue):** 2 verifiers → 2 P1 fixed (vgateFailures auto-bypass unguarded; acceptance #3 unenforced) + 4 P2 incorporated. Amendment posted 2026-08-28T10:15Z.
- **Cycle 2 (this session):** Verifier A 1 P1 (third disable site L1347 — verified) + 2 P2 + 2 P3; Verifier B 2 P1 (L1347; P1-2 marker side-effects — verified) + P2s. Controller verified both in code → accepted into v3.
- **Cycle 3:** Verifier A 1 P1 (restricted-agent block message untruthful — verified) + P3s; Verifier B 1 P2 (fail-open merge for task sub-agents — verified) + P3s. Accepted into v4.
- **Cycle 4 (cap):** Verifier A P0 (adjudicated FALSE POSITIVE — reviewed the worktree for *implemented* fixes; this is the scoping phase, the plan is the artifact; fixes are specified, not yet applied — implementation is the next phase) + 2 P2 + 2 P3; Verifier B 0 P0/P1 + 4 P2 + 2 P3. Gate exit condition met (no P0/P1 in substance). All 8 P2/P3 incorporated into this plan (vgateFailures counter handling, comma-split --tools detection, bridge-absent surface, review_dispatch noise, instruction branching, test-port semantics, behavior register, argv seam).
- **Exit:** `⚠️ capped at 4 cycles — 0 P0/P1 remain; 8 P2/P3 incorporated` → scope verified, proceed to planning/implementation.

## 10. Complexity

| Domain | Rating |
|--------|--------|
| TIER | standard |
| UX | low |
| Ontology | low |
| Architecture | low-medium |
| Library-deps | none (dep-free) |
