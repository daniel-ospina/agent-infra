<!-- research-path: none (no external research brief — root cause verified against extensions/sequence-enforcer/index.ts source + 2026-08-11 batch observation in #201) -->

# fix(sequence-enforcer): print-mode gate deadlock + stale-pop state loss — implementation plan (#201)

**Goal:** sequence-enforcer gate mode must not deadlock or lose state in non-interactive `pi -p` (print/background) sessions. Verifier gates that require dispatching a task sub-agent routinely stall background workers for hours (observed 2026-08-11: 5/5 workers stalled 4–6h each; 3 died at MCP teardown without completing final gates). Scope of THIS doc: SCOPED + PLANNED — **not yet implemented** (scoping sub-agent deliverable).

**Team:** organisation-design-team
**Status:** PLANNED (scoping/plan artifact for #201; implementation gated on separate approval)

---

## Problem Statement

Three interacting defects in `extensions/sequence-enforcer/index.ts`:

1. **`resolveMode()` is print-mode-blind.** Env (`AGENT_SEQUENCE_MODE`/`ELDATO_SEQUENCE_MODE`/`PI_ENFORCER_MODE`) → file (`/tmp/agent-sequence-mode`) → **default `"gate"`**. Every `pi -p` worker (epic-executor sub-agent, `qwen3.8-max`) boots into gate mode.
2. **Verifier gates hard-block.** `getExpectedToolsForStep()` for `gate: verifier|ai_review` returns `allow: [task, subagent, read, loop_enforcer]`, `block: [/.*/]` → bash/edit blocked in gate mode. The only escape is dispatching a `task` reviewer — impossible when the parent is gh-rate-limited, loaded, or has already dispatched (the observed 2026-08-11 scenario). Workers stall at the gate.
3. **The 10-min stale timeout both fails to fire and destroys state when it does.** Every tool call (including blocked ones) runs `resetSequenceTimeout()` *before* validation, so blocked-spam never times out; the timer fires only on true silence. When it fires it **pops the skill**, discarding `stepIndex` + `reviewers` counters mid-stage. The worker resumes with no enforcement, or re-reads the SKILL.md → re-activates at step 0 → re-hits the same gate → infinite stage-restart loop.
4. **Audit blindness.** Blocked entries carry a generic reason (`⛔ gate — step "X" ... blocks this operation`) with **no allowed-tools hint**; warn mode (the proposed default) writes **no audit entries at all**. Orchestrators cannot distinguish "blocked at gate" from "idle" in `~/.pi/agent/audit/enforcement.jsonl`.

## Design (as planned — all changes in `extensions/sequence-enforcer/index.ts` unless noted)

### 1. Print-mode default: `warn` (explicit override always wins)

`resolveMode()` gains a final fallback branch: if `PI_MODE === "print"` → `"warn"`, else `"gate"`. Order unchanged: explicit env → MODE_FILE → print-aware default. Ops can force `gate`/`strict` in print sessions via `AGENT_SEQUENCE_MODE` or the mode file — the override is the escape hatch, never the default.

Rationale:
- Warn mode never blocks → the gate deadlock is structurally impossible in background workers.
- Gate **advancement is mode-independent**: `tool_call` reviewer counting and `tool_result` step advancement run regardless of `mode` (only `validateToolCall` branching differs). A worker that *does* dispatch a reviewer still advances the sequence under warn.
- Interactive sessions (the enforcement core) are untouched; the file-header hard-rule ("don't disable for sub-agents") is deliberately deviated from here per the owner-authored issue, with mitigations: overrides preserved, warn still tracks + advances + (new) audits.

### 2. Timeout: park instead of pop in print mode

In the `resetSequenceTimeout()` callback, branch on `PI_MODE === "print"`:
- **Print:** log `⏰ Sequence timeout — parking "<skill>" at step N (10min no tool calls) — state preserved`, `auditLog({event: "timeout_park", skill, step, mode})`, **leave stack/stepIndex/reviewers intact**, re-arm the timer. A resumed worker continues at the exact step; re-reading the same SKILL.md hits the existing `top.path === path` early-return (no re-activation/reset).
- **Interactive:** unchanged (pop stale skill, restore parent — existing cleanup valve).

This implements the issue's target: *stale-pop restores the step instead of discarding it* — and satisfies indicator (1): print sessions never emit "popping stale".

### 3. Audit the gate context

- **Blocked entries** (both `validateToolCall` block sites): append `allowed: [...]` (from `getExpectedToolsForStep`) and `hint` (from `gateGuidance()`, e.g. `→ To proceed: dispatch a task sub-agent to review this stage...`).
- **Warn mode:** audit `event: "warn_blocked"` **only when the call would have been blocked under gate mode** (computable via the same allow/block sets) — includes `allowed` + `hint`. Avoids per-call audit spam while giving orchestrators "this worker passed a gate that would have blocked it" signal.
- **`timeout_park`** events in print mode (see §2).

## Wiring

| Component | File | Change |
|---|---|---|
| Print-mode default | `extensions/sequence-enforcer/index.ts` | `resolveMode()` final branch on `PI_MODE==="print"`; add `export` to `resolveMode` (+ `getExpectedToolsForStep`, `gateGuidance`) for tests |
| Timeout park | `extensions/sequence-enforcer/index.ts` | `resetSequenceTimeout()` callback print branch (log+audit+re-arm, no pop) |
| Audit context | `extensions/sequence-enforcer/index.ts` | blocked entries + `allowed`/`hint`; warn-mode `warn_blocked` (would-block only); `timeout_park` |
| Tests | `extensions/sequence-enforcer/sequence-enforcer.test.ts` (NEW) | exported-internals pattern (per `repo-freshness.test.ts`), run `npx tsx` |
| Docs | `skills/enforcement/SKILL.md` | note: print/background sessions default to `warn` unless overridden; `warn_blocked`/`timeout_park` audit events documented |

No changes to: `extensions/mcp-client`, `extensions/builtin-tools`, `extensions/verification-gate`, `extensions/slack-bridge`.

## Verification

- `npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts` — new suite:
  - **resolveMode matrix:** print × {no override → warn; `AGENT_SEQUENCE_MODE=gate` → gate; MODE_FILE=strict → strict}; interactive × {no override → gate; env → env}.
  - **Timeout park:** print → stack unchanged, stepIndex preserved, `timeout_park` audit entry written, timer re-armed; interactive → pop preserved (existing behavior).
  - **Audit:** blocked entry contains `allowed` + `hint`; warn mode emits `warn_blocked` only for would-block calls (and never for allowed ones); reviewer counters still increment/decrement and advance steps under warn mode (task tool_call → tool_result → next step).
- Manual smoke (optional, gated): run a `pi -p` session reading a verifier-gate skill (`skills/task-workflow-standard/SKILL.md`) with `AGENT_SEQUENCE_MODE` unset → observe `Loaded — mode: warn`, bash allowed, gate guidance still printed; with `AGENT_SEQUENCE_MODE=gate` → gate behavior restored.
- Review: fresh-context reviewer pass per repo protocol (plan-review loop before implementation).

## Risks

- **File-header hard-rule tension** ("do NOT disable for sub-agents"): deliberately deviated per owner-authored issue; mitigations = explicit-override escape hatch + warn still tracks/advances + new audit visibility. Flagged in the issue-scoping comment for the human gate.
- **Warn audit spam:** bounded by would-block-only filtering.
- **Parked skill resurrection after an unrelated skill read:** pre-existing ponytail stack semantics (restore-parent); out of scope, documented.
- **Reviewers relying on gate blocking:** no reviewer skill has a YAML `steps:` block (verified: `grep "^steps:" skills/reviewers/*/SKILL.md` empty) → reviewers are never sequence-enforced today → warn default loosens nothing for them.
- **Behavior change for print workflows that explicitly set gate mode:** unaffected — explicit overrides always win.
