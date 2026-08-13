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
