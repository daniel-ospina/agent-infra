---
name: epic-executor
description: Use when instructed to complete all issues of an epic, or to process a batch of open issues. Dispatches each issue as a task sub-agent in dependency order using parallel subagent dispatch. Auto-continues until exhausted. Never pauses for /auto. Supports cross-session resume via Tortoise/FalkorDB.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.0.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Epic Executor

## Overview

Execute all issues of an epic in dependency order by dispatching each issue as a `subagent({ tasks: [...] })` call. The orchestrator (you) drives the whole process — no push-task, no /auto, no pausing to ask the user to do anything. Track completion across issues. Auto-continue until exhausted. Checkpoint via Tortoise for cross-session resumption.

**Announce at start:** "I'm using the epic-executor skill to process all issues of this epic."

**CRITICAL: This skill NEVER pauses.** Once you start, you keep going until all issues are done or a blocker requires human input. "X/N done" is a heartbeat, not a stop gate.

## Pre-flight: Worktree Check

This skill reads files (epic docs, plans) but does NOT write code directly — it dispatches to task sub-agents. No worktree needed for the dispatcher itself. Skip isolation for the dispatcher.

**#265 — implementer sub-agents need isolation:** sub-agents no longer inherit `AGENT_ALLOW_MAIN_EDITS` (env pivot). A WRITE-capable implementer sub-agent dispatched with `cwd` = a non-infra main checkout is blocked on write/edit + destructive git. Therefore: write-capable implementer sub-agents in non-infra repos MUST be dispatched with a per-issue worktree `cwd` (issue-workflow Worktree Gate, record-first per #195). Read-only sub-agents (reviewers, researchers) need no worktree — the guard only blocks writes. Agent-infra (the infra repo) is exempt via the repo fingerprint — implementers work in main by design (#99).

## The Process

### Step 1: Read Epic and Extract Issues

1. Read the epic doc (`docs/epics/YYYY-MM-DD-<slug>.md`)
2. Extract the issue list from §11:
   ```
   | # | Title | Complexity | Depends on | Migration phase |
   ```
3. Sort by dependency order: issues with no dependencies first, then dependent issues
4. If no epic doc (ad-hoc batch), gather open issues from the milestone or user's list

### Step 2: Check for Prior Session State

Before dispatching, check if a prior session already processed some issues:

Invoke FalkorDB/Tortoise to check prior state:

```
tortoise query "epic batch <epic-slug> completed"
```

If results found: report prior progress. Skip already-completed issues. Only dispatch remaining issues.

### Step 3: Build Dependency Map and Parallel Dispatch

**Pre-dispatch check:** Before constructing prompts, verify each issue is still open. Closed issues may have been completed by a parallel agent:

```bash
for ISSUE in $ISSUE_LIST; do
  STATE=$(gh issue view "$ISSUE" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
  if [ "$STATE" = "CLOSED" ]; then
    echo "Issue #$ISSUE is already CLOSED — removing from dispatch list."
    ISSUE_LIST=$(echo "$ISSUE_LIST" | grep -v "$ISSUE")
  fi
done
```

If `gh` CLI is unavailable, warn and proceed (graceful degradation).

**Concurrency control:** Max 8 parallel sub-agents per dependency level. Stagger launches by 200ms between agents to avoid API rate limits. On rate-limit errors, retry with exponential backoff (1s, 2s, 4s) + jitter ±200ms. See `parallel-orchestrator` reference skill for full pattern.

For each dependency level (issues that can run in parallel):

1. **Read each issue body** — construct a self-contained prompt that includes:
   - The issue number, title, and description
   - The plan text (if one exists at `docs/plans/`)
   - Reference to the epic doc for context
   - Instructions to use `executing-plans` or `subagent-driven-development` as appropriate
   - Instructions to run `commit-workflow` on completion

2. **Fan-out: Dispatch all parallel-ready issues at once** using the subagent tool's parallel mode:
   ```
   subagent({
     tasks: [
       { agent: "worker", task: "<constructed prompt for #XXXX>" },
       { agent: "worker", task: "<constructed prompt for #YYYY>" },
       // ... all independent issues
     ]
   })
   ```
   This dispatches all issues in a single call — true parallel execution. The subagent tool blocks until all tasks resolve.

3. **Wait for all to complete** — the subagent tool returns when all tasks finish.
   The response contains a result per task. Parse it to determine success/failure:
   - Each task result includes the agent name, task, and output
   - A task "completed successfully" or "merged" → mark as done
   - A task with error output or "FAIL" → mark as failed
   - If the subagent tool itself errors (network, timeout), all remaining tasks fail

4. **Record progress** — log which issues completed, which failed.

5. **Move to next dependency level** — issues whose dependencies are now satisfied.

6. **REPEAT** Steps 1-5 until all issues are dispatched and completed.

**Dependency-gated issues:** Issues that depend on others are only dispatched after their dependencies complete successfully. If a dependency fails, dependent issues are skipped with a note.

### Step 4: Post-Completion

After all issues are processed:
- Report: "N/N done. Epic complete." (or "X/N done, Y failed")
- Tortoise/FalkorDB auto-save handles state tracking for cross-session resume.

## Session Resume

If the user starts a new session and wants to resume:

1. `tortoise query "epic batch <epic-slug> completed"`
2. Parse the results to find which issues were merged
3. Filter the epic's issue list to remaining unmerged issues
4. Return to Step 3 with the remaining issues

## When to Use

- User says "complete all issues of epic #X"
- User says "finish the remaining issues in this milestone"
- User says "process the open issues"
- Any multi-issue batch execution request

## When NOT to Use

- Single issue → use `executing-plans` or `subagent-driven-development` directly
- The epic doc doesn't exist and issues aren't clearly defined → use `epic-workflow` first

## Integration

**Dispatches to (within each task sub-agent):**
- **executing-plans** — for single issues with verified plans
- **subagent-driven-development** — for multi-task issues
- **commit-workflow** — each task runs commit-workflow to land its PR

**Uses:**
- **Tortoise** — cross-session state tracking

## Key Principles

- **Never pause:** No push-task, no /auto, no "ready to continue?" prompts. The orchestrator drives until done or blocked.
- **Dependency order:** Independent issues run in parallel (via `subagent({ tasks: [...] })`). Dependent issues wait for their dependencies.
- **Fresh context per issue:** Each sub-agent runs in a fresh pi session — no context pollution.
- **Progress reports are heartbeats:** Never stop after "X/N done." Keep going until exhausted or blocked.
- **Tortoise/FalkorDB is the cross-session ledger:** After each merge, commit-workflow records completion. On new session, epic-executor reads the ledger to resume.
- **Concurrency capped:** Max 8 parallel sub-agents per dependency level. Stagger 200ms between launches.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
