---
name: goal-setting
description: Formalize loop goals with O/I/T structure, loop type selection, and verification criteria. Use before /loop start, or when asked to "set a goal", "define loop criteria", or "prepare a loop".
domain: capability
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Goal-Setting Skill

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Overview

Goal-setting prepares a well-structured goal before starting a loop enforcer cycle. It validates that objectives, indicators, targets, and loop type are coherent — preventing Goodhart's Law gaming and ill-formed loops before execution begins.

**When to use:** Before `/loop start`, when asked to "set a goal," or when decomposing a parent loop into sub-loops.

## Goal Structure (O/I/T)

Every loop goal has three components structured per OECD RBM (Results-Based Management, 30+ year track record):

| Component | Description | Example |
|-----------|-------------|---------|
| **Objective** | What outcome are we trying to achieve? | "Users can authenticate via Google OAuth" |
| **Indicator** | How will we know it's done? (measurable, verifiable) | "Login flow passes 3 test scenarios", "TypeScript compiles clean" |
| **Target** | What's the bar for success? | "0 type errors", "All 3 scenarios pass" |

**Multiple indicators are required** — single-indicator goals invite Goodhart's Law gaming (optimizing for the metric at the expense of the outcome).

## Loop Types

| Type | Behavior | Use When |
|------|----------|----------|
| **completion** | Work until exit criteria met, then stop | Default — tasks with a defined endpoint |
| **cron** | Recurring on schedule. No auto-continue — scheduler re-triggers | Daily reports, weekly audits |
| **trigger** | Event-driven. Sleeps until trigger fires | Webhook handlers, file watchers |
| **continuous** | Always-on. Never self-terminates | Monitoring, drift detection, always-running agents |

**Selection rule:** Default to `completion`. Only use `cron`/`trigger`/`continuous` when the task genuinely has no natural endpoint.

## Goal Verification Protocol

Before creating a loop, run this verification:

0. **Who is this for?** — select team and optionally role:
   - Use `--for <role-slug>` flag (e.g., `--for content-strategist`)
   - Team is resolved from the role via `operations/subjects/*.yaml`
   - Role inherits escalation chain: role → reports_to → team.escalation → parent team
   - If no role specified: attribute to team directly
   - If unattributed: flag `goals_unverified` — ad-hoc work with no owner
1. **Restate the objective** — agent restates what it understood
2. **Challenge the indicators** — agent asks: "What could go wrong? Is there a way to satisfy every indicator without achieving the objective?"
3. **Confirm loop type** — is `completion` appropriate? Would `cron`/`trigger`/`continuous` fit better?
4. **Set target ambition** — `baseline` (minimum viable), `1.5x` (stretch), `10x` (redesign), `100x` (moonshot)
5. **Principal confirms** — human reviews and confirms the goal structure
6. **GOALS CONFIRMED** — manifest written, execution begins

## Usage

### Via /loop start

```
/loop start "Implement Google OAuth login" --for content-strategist
```

The loop enforcer runs goal verification automatically — you'll see the O/I/T confirmation dialog.

### Via loop_enforcer tool

```
loop_enforcer action=start goal="Research competitor pricing for Riviera Maya restaurants"
```

### Explicit type and ambition

```
/loop start "Daily SEO performance report" --type cron --for growth-hacker
/loop start "Redesign onboarding flow" --ambition 10x --for product-strategist
```

### Deterministic checks

Add machine-verifiable checks that run before LLM evaluation:

```
/loop start "Fix type errors" --check "exec:npx tsc --noEmit"
/loop start "Write article" --check "file:docs/05_growth/wiki/article.md"
```

| Syntax | Meaning | Pass condition |
|--------|---------|---------------|
| `--check "exec:<command>"` | Run shell command | exit 0 |
| `--check "file:<path>"` | Check file exists | file at path exists |

### Output target

Specify what artifact the loop should produce:

```
/loop start "Write article" --output "docs/05_growth/wiki/article.md"
```

### Constraints

Set hard boundaries:

```
/loop start "Refactor auth" --constraint "don't modify /config"
```

Checks run before every cycle. Fail → immediate NEEDS_FIX without LLM dispatch. Pass → LLM evaluates quality.

### Mid-loop refinement (subgoal)

```
/loop subgoal "Also verify mobile responsiveness"
/loop subgoal-list                     # See all current indicators
```

### Decomposition

After goal confirmed, the loop enforcer prompts: "Decompose into sub-tasks?" Child loops inherit the parent's loop_type.

## Integration Surface

The manifest (`~/.pi/agent/loops/<slug>.yaml`) is the integration surface between goal-setting and the loop enforcer. Goal-setting writes:
- `objective` — the O in O/I/T
- `indicators` — list of I's with type and target
- `target_ambition` — baseline, 1.5x, 10x, or 100x
- `loop_type` — completion, cron, trigger, or continuous
- `completion_contract` — free-text complement (optional, Hermes-compatible)

The verifier reads all fields and checks output against them.

## When NOT to Use Goal-Setting

- Micro-tasks that don't need structured verification (single-line changes, trivial fixes)
- Tasks where the outcome is obvious and unambiguous
- When the loop enforcer's default O/I/T generation is sufficient

## See Also

- `docs/teams/organisation-design-team/capability/2026-06-28-loop-enforcer.md` — full system architecture
- `docs/teams/organisation-design-team/capability/2026-06-28-loop-enforcer-research.md` — research backing
- `operations/pi-config/extensions/loop-enforcer/` — extension code
- Hermes `/goal` command (goals.py:79-97) — cross-reference for harmonization
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
