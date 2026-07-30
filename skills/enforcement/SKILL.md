---
name: enforcement
description: Manage the sequence-enforcer that gates skill execution. Check mode, change enforcement level, or kill-switch.
domain: capability
allowed-tools: bash
---
> ⛔ **HUMAN APPROVAL REQUIRED for ALL operations except checking current mode.** Do not change enforcement level, kill enforcement, or re-enable enforcement without explicit human authorization. The kill switch exists as a safety valve for humans — agents must NEVER engage it autonomously. If enforcement is blocking legitimate work, escalate to the human.

# Enforcement

Manages the sequence-enforcer that validates agent tool calls against YAML skill step declarations.

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
