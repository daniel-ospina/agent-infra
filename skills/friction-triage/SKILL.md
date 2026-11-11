---
name: friction-triage
description: Use when session captures in ~/.tortoise/session-events/ show friction patterns — BEFORE filing any fix issues. Triage derives the friction signals from the recorded turns, classifies each one (agent-error, gate-bug, design-gap, workaround-signal), clusters related events, researches root causes, and only then files scoped issues with research mandates.
domain: capability
subjects.team: organisation-design-team
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

**What the source actually is.** The writer is `extensions/reflect-hook.ts` (agent-infra). On every session *quit* it appends exactly ONE JSON object per session to `~/.tortoise/session-events/<YYYY-MM-DD>.jsonl`, and — only when hosted capture is explicitly opted in (`"cloud": true` in `~/.pi/agent/tortoise-config.json`) **and** a key is present (a key alone never enables egress — #803) — POSTs the same payload to hosted tortoise `POST /v1/sessions`. A repo narrows it with `<repo>/.pi/tortoise-capture.json` `{"cloud": false}`; `TORTOISE_CAPTURE_CLOUD=0` denies for a session. The effective state is stated at session start and again at quit, so a silent capture outage cannot be mistaken for a quiet system.

⛔ **The record is a raw transcript, not a friction list.** Schema of one line (measured 2026-11-11 against `~/.tortoise/session-events/2026-11-11.jsonl`):

```
{ "session_id": "…",
  "conversation": [ { "role": "user"|"assistant", "content": "…" } ],  # every turn, ≤5000 chars each, ≤1000 turns
  "metadata": { "capturedAt", "charCount", "projectRoot", "prs": ["123", …], "source": "pi-session-quit", "team" },
  "harness": "pi", "machine_id": "…", "model": "…" }
```

There is **no** `friction_events.jsonl` and no `docs/teams/*/operations/` postmortem feed in this fleet (`rg friction_events` matches this skill only) — that was the eldato-era `reflect.py`, retired with #94. **Do not wait for a pre-classified feed and never report "no friction found" because it is absent** — derive the signals from the turns. An agent that stops at "the feed does not exist" re-creates the silently-dead pipeline #94 removed.

```bash
DIR="${TORTOISE_FALLBACK_DIR:-$HOME/.tortoise/session-events}"
FILES=$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -3)
[ -n "$FILES" ] || { echo "no session records in $DIR — nothing to triage; say so, do not invent"; exit 0; }

# (1) One line per session: when, which repo, which PRs, how big.
for f in $FILES; do
  jq -r '[.session_id, .metadata.capturedAt, .metadata.projectRoot,
          ((.metadata.prs // []) | join(",")), .metadata.charCount] | @tsv' "$f"
done

# (2) Signal VOLUME per session — one instrument hammering a lane shows up here.
for f in $FILES; do
  jq -r '.conversation[].content' "$f" \
    | grep -oiE '\[VGATE\]|BLOCKED|FAIL(ED|URE)?|refus(ED|AL)|fatal:|error:' \
    | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn \
    | awk -v f="$(basename "$f" .jsonl)" '{printf "%s\t%5d\t%s\n", f, $1, $2}'
done

# (3) The matching TURNS, for the instruments that fired most (bounded sample).
for f in $FILES; do
  jq -r '.session_id as $s | .conversation[]
         | select(.content | test("\\[VGATE\\]|BLOCKED|FAIL(ED|URE)?|refus|fatal:|error:"; "i"))
         | [$s, .role, (.content | gsub("\\s+"; " ") | .[0:240])] | @tsv' "$f"
done | head -100
```

**Extract these four per signal — they ARE the friction events; Step 2 classifies them:**

1. **instrument** — the gate/tool that fired (`VGATE`, `review-enforcer`, `sequence-enforcer`, a red check name, a shell error).
2. **timestamp** — the containing session's `metadata.capturedAt`. The record is per-session, so there is no per-turn timestamp; do not invent one.
3. **frequency** — how many sessions/turns carry the same signal. One typo is not friction; 40 identical blocks is.
4. **the cause the session itself named** — the assistant's own adjacent explanation, which is what makes a cluster traceable instead of guessed.

⛔ **`double-loop` is not a field — infer it** in Step 4 from whether the session's remedy addressed the *cause* (double-loop) or worked around the *symptom* (single-loop). Nothing in the record labels it for you.

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
