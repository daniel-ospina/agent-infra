---
name: epic-executor
description: Use when instructed to complete all issues of an epic, or to process a batch of open issues. Dispatches each issue as a task sub-agent in dependency order using parallel subagent dispatch. Auto-continues until exhausted. Never pauses for /auto. Supports cross-session resume via Tortoise/FalkorDB.
subjects.team: organisation-design-team
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

**#265/#615 — implementer sub-agents need isolation:** sub-agents carry no `AGENT_ALLOW_MAIN_EDITS` (#617/#623 — the hatch is default-stripped from `task`/`subagent` children, so even a hatched controller dispatches an unhatched fleet unless the dispatch opts in with `allow_main_edits: true`; never rely on the child env — always pass a worktree `cwd`). A WRITE-capable implementer sub-agent dispatched with `cwd` = a main checkout is blocked on write/edit + destructive git. Therefore: write-capable implementer sub-agents MUST be dispatched with a per-issue worktree `cwd` (issue-workflow Worktree Gate, record-first per #195) — **in every repo, agent-infra included** (the #99 in-main-work exemption was removed by #615: the agent-infra hub now carries the same M4 discipline as any other hub). Read-only sub-agents (reviewers, researchers) need no worktree — the guard only blocks writes.

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

**Pre-dispatch gate — collision pre-flight (#3061), FAIL-CLOSED:** the FIRST check before any dispatch is the collision pre-flight. It checks every in-flight surface (open + closed PRs, local + remote branches, worktrees, assignee/claim comments) and fails loudly in both directions — a hit, and a surface that could not be queried. It gates **every issue in the batch**, not just the first: a single `<N>` invocation would leave the rest unchecked.

The gate is provided by **tortoise** (the only repo carrying `tools/collision_preflight.py`) and applies to *any* issue's repo through `--repo`.

```bash
# 1. The tool lives ONLY in tortoise. Resolve that checkout EXPLICITLY — unset, `"$TORTOISE"/tools/…`
#    collapses to `/tools/…` and PYTHON exits 2, which the loop would report as INCOMPLETE
#    ("a surface could not be queried"): a caller misconfiguration wearing a real verdict's face.
#    $TORTOISE if set; else the cwd itself (when it IS tortoise), the tortoise sibling of the cwd's
#    MAIN checkout (so it still resolves from a linked worktree), then the standard GITHUB root.
if [ -z "${TORTOISE:-}" ]; then
  TOPLEVEL="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
  COMMON="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  for CAND in "$TOPLEVEL" "$(dirname "${COMMON%/.git}")/tortoise" "${HOME:-/nonexistent}/Documents/GitHub/tortoise"; do
    if [ -n "$CAND" ] && [ -f "$CAND/tools/collision_preflight.py" ]; then
      TORTOISE="$(cd "$CAND" && pwd -P)"; break
    fi
  done
fi
if [ ! -f "${TORTOISE:-}/tools/collision_preflight.py" ]; then
  echo "❌ no tortoise checkout resolved (TORTOISE='${TORTOISE:-}') — #3061 pre-flight NOT run for this batch."
  echo "   Record this in the dispatch log; do NOT silently skip. Set TORTOISE=<a tortoise worktree> and re-run."
  exit 1   # do not dispatch the batch
fi

# 2. --repo is MANDATORY. Omitted it means "cwd", and the tool then silently resolved the WRONG
#    repository's issue — a tortoise worktree asked for an agent-infra #NNNN and returned CLEAN (#4027).
REPO="${REPO:-<owner/name>}"                   # the issues' repo, e.g. daniel-ospina/agent-infra
case "$REPO" in ''|*'<'*|*'>'*) echo "❌ REPO is unset or still the literal placeholder ('$REPO') — set it to the issues' repo owner/name; #3061 pre-flight NOT run."; exit 1 ;; esac
#    The `owner/name` form needs tortoise #3978. Until it lands, tortoise main rejects a slug with
#    exit 3 (`--repo not a directory`), so probe the tool's own usage and pass the form it accepts.
if python3 "$TORTOISE"/tools/collision_preflight.py --help 2>&1 | grep -q 'owner/name'; then
  REPO_ARG="$REPO"                                # slug form
else
  #    Pre-#3978 only a PATH is accepted, and it must be a checkout of $REPO. Falling back to `.`
  #    would check the CWD's repo and return CLEAN — the ONE code that authorizes dispatch, i.e.
  #    the #4027 wrong-repo false CLEAN. Resolve a path whose origin slug really is $REPO, or stop.
  SLOT="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed -e 's#/\.git$##')"
  REPO_ARG=""
  for CAND in "${ISSUE_REPO_PATH:-}" "$PWD" "$TORTOISE" "$(dirname "$SLOT")/$(basename "$REPO")"; do
    [ -n "$CAND" ] || continue   # `git -C ""` silently uses the CWD — an empty candidate would "match" anything
    SLUG="$(git -C "$CAND" config --get remote.origin.url 2>/dev/null | sed -e 's#.*github\.com[:/]##' -e 's#\.git$##')"
    [ -n "$SLUG" ] && [ "$SLUG" = "$REPO" ] && { REPO_ARG="$CAND"; break; }
  done
  [ -n "$REPO_ARG" ] || { echo "❌ pre-#3978 tool: no local checkout of $REPO — '.' would check the WRONG repo (#4027). Set ISSUE_REPO_PATH=<a checkout of $REPO>; pre-flight NOT run."; exit 1; }
fi

# 3. Gate EVERY issue in the batch — one <N> invocation would leave the rest unchecked.
#    $ISSUE_LIST — the batch, from Step 1's extracted issue list. It is COUNTED, not merely tested
#    for non-emptiness: a whitespace-only list word-splits to zero issues, and a zero-iteration loop
#    exits 0 — a "checked nothing" pass that would authorize the whole batch ungated.
#    ANY non-zero exit stops the WHOLE batch: 1 COLLISION, 2 INCOMPLETE (NOT clean), 3 usage error.
GATED=0
for ISSUE in ${ISSUE_LIST:-}; do
  case $ISSUE in ''|*[!0-9]*) echo "❌ '$ISSUE' is not an integer issue number — a usage error, not a verdict. STOP the batch."
                             exit 3 ;;
  esac
  GATED=$((GATED + 1))
  python3 "$TORTOISE"/tools/collision_preflight.py "$ISSUE" --repo "$REPO_ARG"
  RC=$?
  case $RC in
    0) echo "✅ #$ISSUE: CLEAN — dispatch eligible." ;;
    1) echo "⛔ #$ISSUE: COLLISION — a worktree/branch/PR/claim already covers it. DO NOT dispatch; report it."
       exit 1 ;;
    2) echo "❌ #$ISSUE: INCOMPLETE — a surface could not be queried. THIS IS NOT CLEAN. STOP the batch, fix gh auth/network, re-run."
       exit 2 ;;
    *) echo "❌ #$ISSUE: pre-flight usage/internal error (exit $RC). STOP the batch."
       exit "$RC" ;;
  esac
done
[ "$GATED" -gt 0 ] || { echo "❌ ISSUE_LIST contained no issue numbers — the #3061 pre-flight checked NOTHING. Populate it and re-run."; exit 1; }
```

⛔ **There is no graceful degradation.** If `gh` is unavailable the tool returns exit 2 (INCOMPLETE) **by construction** — that is a **stop**, not a warn-and-proceed. A pre-flight that cannot tell "no collision" from "could not check" is exactly the bug #3061 fixed; hand-waving past a non-zero exit reintroduces it. Only exit 0 authorizes dispatch.

**Distinguish the two exit-`2` causes.** A `VERDICT: INCOMPLETE` line on stdout is the tool's INCOMPLETE. An argparse `usage:` line with no `VERDICT:` line is a **wrong invocation** (unsubstituted or non-integer `<N>`) — fix the argument, not `gh`.

**Pre-run precondition — do NOT run this from an issue's own worktree.** The tool has no self-exclusion: a branch/worktree this checkout already owns is reported as a `strong` hit under `[local branches]` / `[local worktrees]`, so a run from inside `feat/<N>-…` / `.worktrees/<N>-…` collides with the artifact of the very work being gated. That is a property of the tool, **not** a licence to excuse a non-zero exit: "ANY non-zero exit stops the dispatch" is unaffected, and a surface reported INCOMPLETE is never excused either. Run the gate from a checkout that does not carry any batch issue's number (the dispatcher's checkout, or a separate clone of `$REPO`). If none exists — this batch is resumable (`Step 2`), so a resume can re-enter from such a worktree — record in the dispatch log that the pre-flight could not be run untainted and defer to the per-issue pre-dispatch gate (`issue-workflow`), which runs before any worktree exists.

**Secondary check — prune closed issues:** after the pre-flight, verify each issue is still open (closed issues may have been completed by a parallel agent):

```bash
for ISSUE in $ISSUE_LIST; do
  STATE=$(gh issue view "$ISSUE" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
  if [ "$STATE" = "CLOSED" ]; then
    echo "Issue #$ISSUE is already CLOSED — removing from dispatch list."
    ISSUE_LIST=$(echo "$ISSUE_LIST" | grep -v "$ISSUE")
  fi
done
```

If this `gh` call cannot run, the pre-flight above has already returned INCOMPLETE (exit 2) and the batch is stopped — do not proceed.

**Concurrency control:** Max 16 parallel sub-agents per dependency level (bounded by fan-in context + worktree contention, NOT API limits — direct DeepSeek API is concurrency-only: 500 v4-pro / 2,500 v4-flash, #317). Stagger launches by 200ms between agents to smooth provider load. On rate-limit errors, retry with exponential backoff (1s, 2s, 4s) + jitter ±200ms. See `parallel-orchestrator` reference skill for full pattern.

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
- **Concurrency capped:** Max 16 parallel sub-agents per dependency level. Stagger 200ms between launches.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
