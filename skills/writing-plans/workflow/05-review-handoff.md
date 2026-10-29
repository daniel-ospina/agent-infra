> **Step 5/5** | ← requires: `04-draft-plan.md`

## Plan Review Gate (Standard and Complex Tiers) — Gate Loop — MANDATORY

> **Exception — `task-workflow-standard` (agent-infra#2861).** For that pipeline this gate is **already satisfied when you arrive**: `task-workflow-standard`'s PLAN-VERIFY *is* the plan review, writes the `<!-- plan-review: cycles=…, status=…, version=… -->` signature, and dispatches `plan-review` again would be the second blocking pre-code round the redesign removed. Two skills saying MANDATORY about the same gate is how a lane pays twice — read this exception as part of the mandate, not as advice.

After saving the plan doc, invoke the `plan-review` skill to validate plan quality:

```
plan-review docs/plans/YYYY-MM-DD-<feature-name>.md [--issue <ISSUE_NUMBER>] [--epic <epic-doc-path>] --tier <TIER>
```

Pass the issue number and epic path if available. Wait for the skill to complete.

**The `plan-review` skill runs each review cycle in FRESH `task` sub-agents** —
reviewers have no memory of prior cycles, preventing confirmation bias.
See `.pi/APPEND_SYSTEM.md` → Review Loop Protocol for the full protocol.

- **If `status=clean`:** proceed to Execution Handoff
- **If `status=threat-surface-covered`:** proceed, and record the `[ADVERSARIAL-BOUND] …` disclosure in the PR body (the declared-surface clean exit).
- **If `status=capped` or `status=stalled`:** surface the remaining issues to the user. Do NOT proceed to Execution Handoff until the user either fixes the issues or explicitly approves the plan as-is.

**FORBIDDEN — these bypass the quality gate entirely:**

- ❌ Skip `plan-review` because the plan "looks good"
  Every Standard+Complex plan MUST pass plan-review before execution.

- ❌ Accept a capped/stalled plan-review result as clean
  `capped` and `stalled` are NOT clean — they require human approval.

- ❌ Run plan-review and ignore its output
  The review cycle IS the quality gate. Skipping it = no quality gate.

## Execution Handoff

**Pre-check (Standard/Complex only):** Before proceeding, verify the plan doc contains a clean review signature:

Search for `<!-- plan-review:` in the plan doc. If:
- Signature is absent → stop. Run `plan-review` first — **except in the `task-workflow-standard` pipeline, where PLAN-VERIFY writes this signature itself** (`task-workflow-standard` §3); dispatching `plan-review` there as well would be the second pre-code round the #2861 redesign removes.
- `status=clean` → proceed.
- `status=threat-surface-covered` → proceed, and record the `[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=…` disclosure from the plan doc in the PR body (that is the declared-surface clean exit, `AGENTS.md` §Hard Cap).
- `status=capped` or `status=stalled` → stop. Surface issues to user.

**Research-evidence pre-check (Standard/Complex only, issue #231 D7):** before Execution Handoff, verify the plan carries research evidence — **for the task pipeline that is the issue comment marked `<!-- research: v1 -->`** (its `> **Findings date:**` stamp is the datum; `### Pattern Research` is superseded there — see `task-workflow-standard` §1), and for the epic/project pipelines it is the plan's `### Pattern Research` block with the same stamp. Either way the stamp must be present, or a documented skip justification (`> Gate skipped` / `> Bucket [name] skipped` / `> Research skipped: no demonstrated gap`). Absence of both = the fresh-query evidence gate did not run — stop and run Step B before handoff. (Executing-plans Step 1.5 keys dependency staleness to this stamp; an unstamped block is treated as unfamiliar at execution.)

> **No workflow-state label changes (agent-infra#2861 §8.2).** `planning`, `scoping`, `implementing` **and `planned`** are deleted: all four have no reader anywhere in the fleet (16 write commands across 4 skills, zero reads), and their self-cleanup could strip a live peer lane's marker. The durable signals are `doc_status` on the plan doc and the issue's open/closed state.

**Status transition:** Plan `doc_status`: draft → live (plan-review passed clean). The issue needs no label change — its own state and the plan doc's `doc_status` are the durable signals.

Then select execution mode automatically:

**≤ 8 tasks → Subagent-Driven (this session)**
- Stay in this session
- Fresh subagent per task + code review

**> 8 tasks → Parallel Session (separate)**
Output this message (substituting actual values) and stop:

```
Plan ready: `docs/plans/YYYY-MM-DD-<feature-name>.md` (N tasks)

Open a new session in the `<branch>` worktree and paste:

> Use the `executing-plans` skill to implement this plan:
> `docs/plans/YYYY-MM-DD-<feature-name>.md`
> Issue: #<ISSUE_NUMBER>
> Branch: <branch>
```

> **Rationale:** 8 tasks is the threshold where context window pressure in a single session makes a separate session worthwhile. Below that, the overhead of context-switching between sessions exceeds the cost of staying in one.

Announce the selected mode with a one-line note: "Using [subagent-driven/parallel session] for [N] tasks — [brief reason]."

If the user prefers the other mode, switch without argument.

## Label Cleanup — removed (agent-infra#2861 §8.2)

There is nothing to clean up: this skill no longer applies a `planning` label (it never had a reader), so an early exit leaves no orphaned marker.
