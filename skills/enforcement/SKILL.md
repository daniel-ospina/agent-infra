---
name: enforcement
description: Manage the sequence-enforcer that gates skill execution. Check mode, change enforcement level, or kill-switch.
domain: capability
allowed-tools: bash
---
> ⛔ **HUMAN APPROVAL REQUIRED for ALL operations except checking current mode.** Do not change enforcement level, kill enforcement, or re-enable enforcement without explicit human authorization. The kill switch exists as a safety valve for humans — agents must NEVER engage it autonomously. If enforcement is blocking legitimate work, escalate to the human.

# Enforcement

Manages the sequence-enforcer that validates agent tool calls against YAML skill step declarations.

## Print / Background Sessions (`pi -p`)

Non-interactive `pi -p` sessions (epic-executor sub-agents, background workers) default to **`warn`** — never blocking. This prevents verifier gates from deadlocking a worker that cannot dispatch a reviewer sub-agent (the gate's only escape in gate mode). Explicit overrides always win: `AGENT_SEQUENCE_MODE=gate|strict`, `PI_ENFORCER_MODE`, or the mode file force full enforcement in print sessions. Interactive sessions keep the `gate` default.

Audit visibility (`~/.pi/agent/audit/enforcement.jsonl`) for background workers:
- `warn_blocked` — a call that WOULD have been blocked under gate mode was allowed in warn mode; includes `allowed` + `hint` context.
- `timeout_park` — a stale sequence was parked at step N in print mode (state preserved), not popped.
- `blocked` entries now include `allowed` + `hint` so orchestrators can see why a worker is stuck and what the exit is.

## Checkpoint Gates (#357 post-fix reality)

Checkpoint steps (`gate: checkpoint`, e.g. `parallel_check_*` in writing-plans / commit-workflow / executing-plans) are **token-gated** (Enforcement A #5039): a fresh phase-correct `CLEAR` token from `parallel_work_check` is required to pass. Post-fix (#357) the contract is satisfiable and escapable:

- **Warn mode (default for `pi -p`)**: the FIRST call at a checkpoint auto-advances with a `checkpoint_skipped_warn` audit entry (token_state: none/stale/wrong-phase/ok) — never blocks, never deadlocks. Advance is mode-independent: gate/strict advance on a valid token at tool_call; a producer-timing escape call advances at tool_result when the token transitions !ok→ok.
- **The in-session escape (gate/strict)**: `read` + `loop_enforcer` are ALWAYS allowed at a pending checkpoint; `bash` ONLY for the sole-command checker invocation (`parallel_work_check.<sh|py> <phase>` — resolved absolute path, optional `env GH_TOKEN=…`, optional `python3`/`uv run`, mandatory `.sh|.py` suffix + phase arg; tab/NBSP/zero-width/metachars rejected). Everything else fails closed. A checker re-run at an ALREADY-ok checkpoint is blocked (`checkpoint_token_fresh` — re-running can REMOVE the token on UNKNOWN).
- **Operator force-pass (human-only)**: write `/tmp/parallel-check-force.json` — `{"verdict":"CLEAR","phase":"<step token_phase>","operator":"<you>","origin":"shell","repo":"<git remote>","ts":"<ISO>"}`. ONE-SHOT per checkpoint (deleted on the advance it triggers), 60-min TTL, phase + repo bound. Session start unlinks lingering force files (machine-shared path — write it AFTER the checkpoint is reached; single-operator assumption). Emits the human-read-only `checkpoint_force_pass` event. This is the operator path for gate-mode interactive worktree sessions where the checker CANNOT CLEAR by design (C1 DEFER on any non-main worktree branch).
- **Recovery (park-only, never pop)**: ≥3 consecutive blocked calls at a checkpoint OR a >5-min wall-clock stall → immediate PARK (state preserved) with one `checkpoint_block_recovery` event per checkpoint. Blocked-call audit entries are coalesced (≤20/60s per step) to bound log volume.
- **Fail-closed diagnosis**: a checkpoint step missing `token_phase` in its frontmatter is unpassable-by-design (blocks + `⚠️ F2` warning at activation listing the step) — fix the skill declaration.

**Audit event set (checkpoint)**: `checkpoint_skipped_warn`, `checkpoint_force_pass`, `checkpoint_block_recovery`, `checkpoint_token_fresh`. The audit is HUMAN-READ-ONLY — enforcement.jsonl has no automated consumer; a reader is a swarm-side follow-up.

## #201 carve-out reversal (#357)

The `pi -p` → warn default is now **argv-aware**: `resolveMode` uses `isPrintMode(env, argv)` (bare-shell `pi -p` with no PI_MODE env included). The old carve-out (bare `pi -p` keeps gate because it can dispatch `task`) is REVERSED — the checkpoint gate is unsatisfiable/inescapable in exactly that class, so warn is the safe default for ALL print sessions. Explicit overrides (`AGENT_SEQUENCE_MODE`, `ELDATO_SEQUENCE_MODE`, `PI_ENFORCER_MODE`, mode file) still force gate/strict. `--mode json/rpc` spawns remain a documented gate-resolving residual.

## Check Current Mode (agent may use)
```bash
cat /tmp/agent-sequence-mode
```
Modes: `warn` (log only), `gate` (block destructive without skill read), `strict` (block all unexpected).

## Change Mode (⛔ HUMAN APPROVAL REQUIRED)
```bash
echo <mode> > /tmp/agent-sequence-mode
```

## Emergency Kill Switch (⛔ HUMAN APPROVAL REQUIRED — agents must NEVER use autonomously)
```bash
touch /tmp/agent-state-machine.kill   # disables ALL enforcement
rm /tmp/agent-state-machine.kill      # re-enables
```
This is a safety valve for humans. If an agent is blocked by a false positive, escalate to the human — do NOT touch the kill switch.

## View Audit Log (agent may use)
```bash
cat ~/.pi/agent/audit/enforcement.jsonl
```
