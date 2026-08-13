---
name: parallel-orchestrator
description: Reference pattern for parallel sub-agent dispatch, fan-out/fan-in, concurrency control, retry with backoff, and convergence gates. Consumed by other skills — not invoked directly.
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Parallel Orchestrator (Reference Pattern)

Standardized fan-out/fan-in pattern for parallel sub-agent dispatch in pi. All orchestrator skills (codebase-audit, content-strategy-agent, prototype-review, epic-executor) should reference this pattern instead of reimplementing concurrency control.

## When to Use This Pattern

- Dispatching 2+ independent sub-agents that can run simultaneously
- Review cycles with parallel reviewers
- Batch processing where items don't depend on each other
- Any workflow where sequential dispatch would add unnecessary wall-clock time

**Not for:** Tasks with data dependencies (output of A feeds into B), tasks touching the same files, or single-agent operations.

## The Pattern

### 1. Fan-Out Dispatch

Use `subagent({ tasks: [...] })` for true parallel execution:

```
subagent({
  tasks: [
    { agent: "worker", task: "Review diff for correctness..." },
    { agent: "worker", task: "Review diff for security..." },
    { agent: "worker", task: "Review diff for accessibility..." },
  ]
})
```

The subagent tool blocks until ALL tasks complete. All tasks run concurrently — wall-clock time ≈ slowest task, not sum of all tasks.

### 2. Concurrency Control

```
MAX_CONCURRENCY = 8            # hard cap — never exceed
STAGGER_MS = 200               # delay between task launches
RETRY_BACKOFF = [1000, 2000, 4000]  # exponential backoff + jitter ±200ms
```

**Rules:**
- Never launch more than `MAX_CONCURRENCY` tasks in a single `subagent` call
- If you have N > 8 tasks, batch them: first 8 → wait → next 8
- Stagger launches within each batch: add a brief pause between constructing task prompts
- On rate-limit errors: retry with exponential backoff. After 3 retries, surface the failure

### 3. Structured Output Format

ALL parallel sub-agents MUST return results in a parseable, deduplicatable format:

```
FINDING: [P0|P1|P2|P3] Brief title
- File: path/to/file.ts:line
- Category: [Security|Bug|Config|SupplyChain|Database|UX|Accessibility|SEO|Content|...]
- Description: 1-2 sentences
- Fix: Specific suggested approach
```

Or for binary results:
```
RESULT: PASS|FAIL
- Detail: <explanation>
```

### 4. Fan-In Synthesis

After all sub-agents return:

1. **Collect** all results into a single list
2. **Deduplicate** — if two agents flag the same issue (same file+line or ≥70% similar description), merge into one (keep higher severity)
3. **Sort** by severity (P0 first)
4. **Count** by category

### 5. Convergence Gate

For review cycles (review → fix → re-review), stop when:
- `is_clean: true` — all reviewers return zero issues
- **Convergence** — issue count is shrinking but not reaching zero (surface remaining to human)
- **Safety cap** — at 10 cycles, exit with remaining issues documented

Never loop infinitely. Always have a cap.

## Pre-Warming Pattern

For tasks where a slow prerequisite can run in parallel with planning:

```
# In Step 0, before planning begins, start typecheck in the background:
npm install --silent 2>&1 | tail -1 && npx tsc --noEmit > /tmp/typecheck-preflight.txt 2>&1 &

# Before starting implementation, check the result:
if [ -f /tmp/typecheck-preflight.txt ] && [ -s /tmp/typecheck-preflight.txt ]; then
  echo "⚠️ Pre-flight typecheck errors:" && cat /tmp/typecheck-preflight.txt
elif [ -f /tmp/typecheck-preflight.txt ]; then
  echo "✅ Pre-flight typecheck clean"
fi
```

The orchestrator checks the background result before starting implementation. If FAIL, surface errors. If still running, warn and proceed.

## Integration

**Consumed by:**
- **codebase-audit** — Phase 2 fan-out/fan-in
- **content-strategy-agent** — Reviewer cycle dispatch
- **prototype-review** — Review cycle dispatch
- **epic-executor** — Issue batch dispatch
- **executing-plans** — Step 0 pre-warming, Phase 3 verification dispatch

**Uses:**
- **subagent** tool (built-in) — provides `subagent` with `tasks` array for parallel dispatch. No `background` flag exists; use bash `&` for non-blocking work (see Background Execution Note below).



## Background Execution Note

The `subagent` tool blocks until completion — there is no `background: true` parameter. For truly non-blocking background work (pre-warming, long-running side tasks), use `bash` background processes (`&`) with output redirected to temp files. Check temp files before the result is needed.

For parallel dispatch of independent blocking tasks, use `subagent({ tasks: [...] })` — the tool blocks but all tasks run concurrently.

## Partial-Failure Handling

When dispatching parallel sub-agents, not all may succeed. Handle gracefully:

### Pattern
1. **Collect** all results — successes and failures
2. **Classify:** ✅ Success, ⚠️ Timed out, ❌ Failed
3. **If some succeeded:** Proceed. Flag gaps: "⚠️ reviewer-3 timed out — skipped"
4. **If ALL failed:** Return structured error: "❌ All reviewers failed (3/3)"
5. **Aggregate** multiple gaps into single summary

All fan-out orchestrator skills (code-review, plan-review, prototype-review, test-review, content-strategy-agent, codebase-audit) implement this pattern.

## Teardown Contract (worktrees/branches) — MANDATORY for parallel dispatch

**Issue #195:** an aborted 6-task parallel dispatch left orphaned worktrees and `fix/*` branches with NO teardown (observed 2026-08-12; `.worktrees/` accumulated 60+ dead entries). Nothing owned the lifecycle. Since pi exposes no abort hook the dispatcher can rely on, teardown is **record-first**: every artifact a dispatch creates is written to a manifest before dispatch, so an abort leaves an explicit teardown trail instead of silence.

**The contract — every orchestrator that spawns sub-agents which create branches/worktrees MUST:**

1. **RECORD before dispatch** (each worktree/branch the sub-agent will create):
   ```bash
   bash scripts/record-worktree.sh add --branch fix/801-signup-rate --worktree .worktrees/fix-801-signup-rate --dispatch d-<id>
   ```
   (Records append to `~/.pi/agent/worktrees.jsonl` — one JSONL line per artifact: ts, branch, worktree, dispatch, repo. Writes are atomic tmp+mv; a failed write warns but NEVER blocks the dispatch.)

2. **DONE on clean completion** — after the fan-in succeeds and worktrees are removed, the orchestrator removes its own records:
   ```bash
   bash scripts/record-worktree.sh done --dispatch d-<id>
   ```

3. **ABORT leaves the record** — on user abort, sub-agent hang, or crash, do NOT clean records. The surviving record IS the teardown manifest: the next sweep flags it.

4. **SWEEP after every dispatch** (and periodically) — `scripts/scan-orphans.sh` reads the manifest + git state and classifies each record:
   - **ORPHAN** — branch local-only, no open PR, record stale (>1d by default) → safe to remove
   - **DIRTY-ORPHAN** — worktree holds uncommitted changes → manual review; `--apply` refuses without `--force-dirty`
   - **RECENT** — recorded, not yet stale → listed, never removed
   - **LIVE** — branch pushed or has an open PR → ignored
   - **GHOST** — branch/dir already gone → record pruned
   - **UNRECORDED** — informational only (pre-contract worktrees/branches); NEVER auto-removed
   
   ```bash
   bash scripts/scan-orphans.sh            # dry-run: teardown list, deletes nothing
   bash scripts/scan-orphans.sh --apply    # explicit removal of ORPHANs + ghost records
   ```
   `--apply` removes the worktree dir, deletes the local branch (never `main`/`master`, never a pushed branch, never a dirty worktree without `--force-dirty`), and prunes the record.

5. **Document the wiring** — see `scripts/scan-orphans.sh --help` for the full contract and the issue-workflow skill's Worktree Gate for the dispatcher-side rules.

> **Why not an abort hook?** Research for #195 found no reliable cross-session abort/cancel hook in the pi SDK. A deterministic, no-LLM record + sweep is robust to kills, crashes, and lost sessions — the record survives the process that wrote it.

## Anti-Patterns

| Anti-Pattern | Why It Matters |
|---|---|
| Dispatching 20+ agents at once | API rate limits, context pressure on fan-in. Cap at 8, batch the rest |
| No staggered launches | Burst dispatch can trigger rate limits. 200ms stagger smooths load |
| Sub-agents touching same files | Merge conflicts, inconsistent state. Partition file ownership before dispatch |
| No structured output format | Can't deduplicate or sort results. Enforce format in agent prompts |
| Infinite review cycles | Always cap at 10 cycles. Surface remaining issues to human |
| Waiting for background tasks synchronously | Defeats the purpose. Check background results before they're needed |
| No fallback for subagent tool failures | If the subagent tool is unreachable (network, API down), the skill hangs. Always have a fallback: retry 3× with backoff, then surface to human with options to (a) retry, (b) proceed sequentially, (c) abort. |
| Spawning worktrees/branches with no teardown record | Aborted dispatch silently orphans them (#195). Record every artifact before dispatch (`record-worktree.sh add`), remove on clean completion (`done`), sweep with `scan-orphans.sh` — abort leaves the record as the teardown manifest. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
