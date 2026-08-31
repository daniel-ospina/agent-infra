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

Non-interactive `pi -p` sessions (epic-executor sub-agents, background workers) default to **`warn`** — never blocking. Post-#357 this covers ALL print sessions, env- OR argv-detected (bare-shell `pi -p` with no PI_MODE included) — see "#201 carve-out reversal" below. Explicit overrides always win: `AGENT_SEQUENCE_MODE=gate|strict`, `PI_ENFORCER_MODE`, or the mode file force full enforcement in print sessions. Interactive sessions keep the `gate` default.

⚠️ **Verifier-gate trade-off of the reversal:** the bare-shell `pi -p` class loses the verifier-step tool allow-list (task/subagent/read/loop_enforcer) — those calls become warn-only. The merge gate (review-enforcer) stays active; restore per-session with `AGENT_SEQUENCE_MODE=gate`. Monitoring: if `warn_blocked` volume on verifier gates from bare-shell sessions rises (enforcement.jsonl `mode:warn` + verifier steps), re-evaluate the default — the trigger is a spike, not a steady background.

Audit visibility (`~/.pi/agent/audit/enforcement.jsonl`) for background workers:
- `warn_blocked` — a call that WOULD have been blocked under gate mode was allowed in warn mode; includes `allowed` + `hint` context.
- `timeout_park` — a stale sequence was parked at step N in print mode (state preserved), not popped.
- `blocked` entries now include `allowed` + `hint` so orchestrators can see why a worker is stuck and what the exit is.

## Checkpoint Gates (#357 post-fix reality)

Checkpoint steps (`gate: checkpoint`, e.g. `parallel_check_*` in writing-plans / commit-workflow / executing-plans) are **token-gated** (Enforcement A #5039): a fresh phase-correct `CLEAR` token from `parallel_work_check` is required to pass. Canonical phases (C1–C5): `start` (executing-plans), `scope` (issue-scoping), `plan` (writing-plans), `implement` (commit-workflow + executing-plans), `merge`. There is NO `verify` checkpoint — the verifier gate is a separate mechanism. issue-scoping's start/scope checkpoints are prose instructions (self-enforced; no frontmatter gate). Post-fix (#357) the contract is satisfiable and escapable:

- **Warn mode (default for `pi -p`)**: the FIRST call at a checkpoint auto-advances with a `checkpoint_skipped_warn` audit entry (token_state: none/stale/missing-or-wrong-phase/corrupt/other/ok) — never blocks, never deadlocks. Advance is mode-independent: gate/strict advance on a valid token at tool_call; a producer-timing escape call advances at tool_result when the token transitions !ok→ok.
- **No-board skip (gate/strict)**: a no-board session (ALL board/card/agent/paths signal families empty — unset OR empty/whitespace; ANY non-empty signal → fail-closed NOT-no-board) gets a distinguishable `CLEAR  no-board-skip: <advisory>` verdict from the vendored checker and a token carrying `mode:"no-board-skip"`. The enforcer emits `checkpoint_no_board_skip` (distinct from `checkpoint_force_pass`) at token-driven advances; board sessions are unchanged (plain CLEAR, no skip audit).
- **The in-session escape (gate/strict)**: `read` + `loop_enforcer` are ALWAYS allowed at a pending checkpoint; `bash` ONLY for the sole-command checker invocation — the CANONICAL reference is `$AGENT_INFRA_PATH/scripts/parallel_work_check.sh <phase>` (the vendored checker; NOT any hardcoded swarm path) — resolved absolute path, optional `env` with the allowlisted keys `GH_TOKEN|CHECKOUT_GUARD_ENFORCE|AGENT_INFRA_PATH`, optional bare `sudo`, optional `python3`/`uv run`, mandatory `.sh|.py` suffix + phase arg; tab/NBSP/zero-width/metachars rejected. `PARALLEL_CHECK_BIN` is an INTERNAL bin-location override — never a gate-time `env` prefix (not in the escape allowlist, so `env PARALLEL_CHECK_BIN=…` fails closed at the gate). Everything else fails closed. A checker re-run at an ALREADY-ok checkpoint is blocked (`checkpoint_token_fresh` — re-running can REMOVE the token on UNKNOWN); non-checker tools at an already-ok checkpoint are allowed (the step advanced on the fresh token).
- **Operator force-pass (human-only)**: write `/tmp/parallel-check-force.json` — `{"verdict":"CLEAR","phase":"<step token_phase>","operator":"<you>","origin":"shell","repo":"<git remote>","ts":"<ISO>"}`. CONSUMED on ANY checkpoint advance (unlinked — including a real-token or warn-mode advance, so a leftover file can never pass a same-phase adjacent checkpoint), 60-min TTL (future timestamps rejected), phase + repo bound. New-session start unlinks lingering force files (machine-shared path — write it AFTER the checkpoint is reached; single-operator assumption); a mid-session `/reload` does NOT unlink. It is AUDITED as `checkpoint_force_pass` ONLY when it actually DROVE the pass — a real-token or warn-mode consume emits nothing (the event means "an operator CLEAR passed this step"). This is the operator path for gate-mode interactive worktree sessions where the checker CANNOT CLEAR by design (C1 DEFER on any non-main worktree branch).
  ⚠️ **Trust boundary**: `/tmp` is world-writable and the file carries no operator credential — this is workflow-enforcement, NOT a security boundary; the audit trail + 60-min TTL are the detections. The real token file has the same exposure — but IS repo-bound (gate/strict only; warn is binding-free). The token's `repo` is the URL form (`git remote get-url` of the resolved ops target, userinfo-stripped); binding compares `token.repo` against `bindingRepo() = resolveRepo(PARALLEL_CHECK_REPO) || currentRepo()`. No-remote / non-git cwd → both sides "unknown" → binding passes. Cross-repo mismatch → named-reason BLOCK → re-run the checker from this checkout. `PARALLEL_CHECK_REPO` is honored as a PATH (resolved via the same `git remote get-url`); set-but-not-a-git-dir → both "unknown". `--repo X` without the env binds X's remote — and `--repo X` from a different cwd with no env means the enforcer never learns the flag → named-reason BLOCK, remediation: "set PARALLEL_CHECK_REPO to the checkout path". SAME-REPO-DIFFERENT-URL-FORMAT also BLOCKs (https vs scp of the same origin) — re-run from the same checkout form. This is NOT "a token written in repo A fails repo B" — same repo does not guarantee a pass; phase, TTL, and URL format must all line up.
  **Same-repo concurrent sessions**: the token file is last-writer-wins and machine-global; it is NEVER unlinked on a token-driven advance (only the force file is one-shot) — the phase + TTL + repo-binding bound the concurrency class to fail-safe outcomes. A shared-token advance may be audit-attributed to EITHER concurrent session — accepted, documented. Mode-attribution sub-case: a no-board session advancing on a concurrent board session's CLEAR token emits a BOARD-mode audit with NO skip event (the event stream carries no tenant info); the post-merge lag tripwire queries for same-repo/same-phase multi-advance anomalies alongside the existing no-board-lacks-event query (per-session nonce deferred).
- **Recovery (park-only, never pop)**: ≥3 consecutive blocked calls at a checkpoint OR a >5-min wall-clock stall → immediate PARK (state preserved) with one `checkpoint_block_recovery` event per checkpoint. Blocked-call audit entries are coalesced (≤20/60s per step) to bound log volume. Conditional signature: per-call blocked + 1 recovery event + 1 park/10min — after the one-shot event the step reverts to the 10-min cadence, and a relentless retry loop re-arms the 10-min timer on every blocked call (no further recovery signal until orchestrator kill).
- **Fail-closed diagnosis**: a checkpoint step missing `token_phase` in its frontmatter is unpassable-by-design (blocks + `⚠️ F2` warning at activation listing the step) — fix the skill declaration.

**Audit event set (checkpoint)**: `checkpoint_skipped_warn`, `checkpoint_force_pass`, `checkpoint_no_board_skip`, `checkpoint_block_recovery`, `checkpoint_token_fresh`. Mutual exclusivity + mode domain: skip audits carry `token_mode`/`mode` (`no-board-skip`), force-pass carries `viaForce` — a skip-token advance emits NO force-pass audit and a force-driven advance emits NO skip audit. Audit-gap note (deploy window): tokens written PRE-deploy carry no `mode` → after the new enforcer deploys they advance as board-mode CLEAR with no skip audit — re-run the checker once. The audit is HUMAN-READ-ONLY — enforcement.jsonl has no automated consumer; a reader is a swarm-side follow-up.

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
