---
name: friction-triage
description: Use when a session postmortem or friction_events.jsonl shows friction patterns — BEFORE filing any fix issues. Triage classifies each friction (agent-error, gate-bug, design-gap, workaround-signal), clusters related events, researches root causes, and only then files scoped issues with research mandates.
domain: capability
type: Bounded
status: draft
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: gather
    type: skill
    gate: auto
    produces: [friction_data]
  - name: triage
    type: skill
    gate: auto
    requires: [gather]
    produces: [classified_events]
  - name: cluster
    type: skill
    gate: auto
    requires: [triage]
    produces: [friction_clusters]
  - name: root_cause
    type: skill
    gate: auto
    requires: [cluster]
    produces: [causal_chains]
  - name: research
    type: skill
    gate: verifier
    requires: [root_cause]
    produces: [research_findings]
  - name: file_issues
    type: skill
    gate: auto
    requires: [research]
    produces: [github_issues]
tags: [friction, triage, reflect, process]
summary: "Classify friction events before filing fix issues — prevents solution-jumping"
created: 2026-07-22
updated: 2026-07-22
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

# Friction Triage

Gate between friction detection and action. Prevents the agent from jumping from "I see a friction event" to "here's my fix" without understanding what actually broke.

## The Problem

```
Broken:  Reflect → Agent sees friction → Agent: "Fix it by doing X!"
Fixed:   Reflect → Agent invokes friction-triage → Triage → Root cause → Research → Scoped issues
```

The broken pipeline produces issues that prescribe solutions before understanding the problem. The fixed pipeline produces issues that mandate research.

## Step 1 — Gather

Read friction data:

```bash
ls -t docs/teams/*/operations/*postmortem* | head -1
cat docs/teams/organisation-design-team/operations/friction_events.jsonl
```

Extract: friction types, frequencies, timestamps, double-loop flags.

## Step 2 — Triage

Classify EVERY friction event into exactly one category:

| Category | Definition | Example | Action |
|----------|-----------|---------|--------|
| **agent-error** | Agent should have known better | Skipping skill read, hitting enforcer repeatedly | Fix agent behavior |
| **gate-bug** | Gate has a real bug | VGATE rejects valid JSON, enforcer deadlocks | Fix the gate |
| **design-gap** | Gate correct but workflow creates unavoidable friction | Enforcer re-blocks after every reload | Refine gate/workflow |
| **workaround-signal** | Agent reaches for bypass instead of fixing root cause | --no-verify push because VGATE is hard to satisfy | Fix gate driving workarounds |

**Rule:** When unsure, default to `design-gap` — requires research before action.

## Step 3 — Cluster

Group related events by root cause, not by friction type. Same root cause produces different friction types:

```
Root: VGATE schema mismatch
  → verification-gate (P1) × 40: schema-invalid JSON rejected
  → gate-blocked (P0) × 22: agent retries commit after block
  → counterproductive-harness (P2) × 16: agent resorts to --no-verify
```

## Step 4 — Root Cause

Trace each cluster's causal chain 3 levels:

```
Level 1 (symptom): Agent uses --no-verify push
Level 2 (mechanism): VGATE blocks commit, verifier returns wrong format
Level 3 (root): VGATE prompt format undocumented, verifiers don't know required JSON
```

Stop when you reach a cause that, if fixed, would prevent the entire chain.

## Step 5 — Research

For each root cause, research alternatives:
- Internal: check issues, AGENTS.md, MEMORY.md for prior discussion
- External: how do other agent systems handle gate friction?
- Adversarial: what if we removed this gate entirely?

Output: 2-3 alternative approaches per cluster with trade-offs.

## Step 6 — File Issues

For each cluster with confirmed root cause and researched alternatives, file ONE issue that:
1. Describes the root cause (not the symptom)
2. References friction events
3. Mandates research before implementation
4. Does NOT prescribe a solution

---

> Continue following the workflow as mandated by this skill. Do not skip steps. Do not propose solutions before completing triage and research.
