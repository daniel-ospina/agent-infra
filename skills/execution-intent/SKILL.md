---
name: execution-intent
description: "Canonical reference for the session-level execution intent flag. Defines the Fast/Autonomous/Budget profiles, propagation rules, and sub-agent preamble template. Cross-referenced by 9 pipeline skills."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Source:** Canonical copy at `skills/execution-intent/SKILL.md`.

# Execution Intent

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Overview

The execution intent flag is set once at brainstorming entry and read by every downstream skill in the pipeline. It enables three profiles for how skills handle gates, review cycles, fix policy, and sub-agent dispatch.

This skill is a reference — it does not run a procedure. Other skills cross-reference it to avoid duplicating intent semantics in each skill's prose.

## Profiles

| Profile | Philosophy | User pauses | Review cycles | Fix scope | Sub-agent dispatch |
|---------|-----------|-------------|---------------|-----------|--------------------|
| **Fast** (default) | Speed + quality | Normal interactive gates | Up to 4 cycles, per-skill default | Per-skill default | Ask user |
| **Autonomous** | Measure twice, cut once | **Zero** | Full 4 cycles, no early-exit cap | All P0/P1/P2 + verify each fix | Auto-dispatch by heuristic |
| **Budget** | Watch credits | Normal gates | Same as Fast | Same as Fast | Force in-chat (migrations excepted) |

**Default behavior:** When no intent is set, fall back to **Fast**.

## Reading the Intent

Skills read intent in this order:

1. **Session context** — if a prior skill in the chain (typically brainstorming) set `EXECUTION_INTENT`, use that value.
2. **Worktree file** — `cat .pi/execution-intent 2>/dev/null` returns one line of the form `EXECUTION_INTENT=<value>`. If file mtime is >24h, treat the file as absent.
3. **Default to Fast** — if neither source returns a recognized value (`fast`, `autonomous`, `budget`).

Recognized values are case-insensitive. Unknown values fall back to Fast.

## Setting the Intent

Brainstorming asks the entry-point question and writes both:

- **Session context** — already-loaded for downstream skills in the chain (no I/O).
- **`.pi/execution-intent` file** — at the worktree root, for skills invoked outside the chain.

Pseudocode for setting:

```bash
mkdir -p .pi
echo "EXECUTION_INTENT=$intent" > .pi/execution-intent
```

The file is overwritten on each new brainstorming session. Intent is immutable per session, but a new session re-asks the question.

## Lifecycle

- **Set** at brainstorming entry-point question.
- **Cleared** by `commit-workflow` on completion (success or abort): `rm -f .pi/execution-intent`.
- **Auto-expires** when file mtime is >24h old; stale files are treated as absent.

## Tier × Intent Interaction

**Intent modifies behavior within the tier the skill selects. Intent never forces a Micro-tier skill to run Complex-tier phases.**

Worked examples:

- **Micro + Autonomous:** Codebase Explorer still skipped (Micro rule). Plan reviews run 2 cycles instead of 4 (Micro constrains). Fix P0+P1 (Micro skips P2 by default; intent does not override tier).
- **Micro + Budget:** codebase-read only — the micro proportional external-research trigger is skipped under Budget (issue #231 D3).
- **Complex + Budget:** code-review skips NVIDIA pattern scan (6 → 5 agents). writing-plans skips perplexity gate. All other Complex phases run normally.
- **Standard + Budget:** issue-scoping Phase 1.5 runs ≤ 2 external queries, codebase-first, fired only on P0-level gaps (new third-party dep / novel pattern with zero in-repo precedent) — the writing-plans Perplexity gate is the total session research budget (no double-charge). (issue #231 D3)
- **Epic-tier + Budget:** epic-plan research hooks and epic-scope granular queries defer to the epic research brief (codebase + brief only, zero external queries). (issue #231 D3)
- **Complex + Autonomous:** All Complex phases run; review cycles take 4 cycles each, fix all severities; sub-agents auto-dispatch.

## Sub-agent Preamble

Every sub-agent dispatched in **Autonomous** or **Budget** mode receives this canonical block at the **start** of its prompt. Copy-paste the relevant variant; do not paraphrase.

```
## Execution Mode: Autonomous

- Fix ALL issues found (P0, P1, P2). Do not skip minor issues.
- After every fix: verify the fix worked. Run relevant tests.
- Confirm nothing regressed. If regression found, revert and try alternative.
- Log every autonomous decision with rationale, risk, and recovery path.
- Do not wait for user approval. Proceed autonomously.
```

```
## Execution Mode: Budget

- Favor cheapest tool options. Skip optional research calls.
- Use in-chat execution. Avoid sub-agent dispatch unless migration isolation required.
- Normal gates apply. Wait for user approval when required.
```

In **Fast** mode, no preamble is added — sub-agents operate as they always have.

## Autonomous Decision Log Format

Decisions made under Autonomous are logged inline in the active design doc, plan comment, or PR description as:

```
**Autonomous decision:** Chose <X> over <Y> because <reason>.
**Risk:** <what could go wrong if this turns out to be wrong>
**Fix if wrong:** <recovery path>
```

The user reviews these on return and can override any decision by replying.

## Disambiguation: brainstorming's "Path B"

Brainstorming's existing scope-routing "Path B: No taxonomy → AUTO-PROCEED" is a brainstorming-internal conditional (auto-proceed within that skill only). This is distinct from the session-wide **Autonomous** profile. The two coexist because the profile is set after the taxonomy gate.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
