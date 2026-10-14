---
title: "Task-run record retention — dry-run by default, arming is an owned step (#1662)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-01
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1662, issue-783, task-runs, retention, builtin-tools
---

# Task-run record retention (#1662)

One place that says **how the durable background-dispatch run tree is bounded**,
and who arms the sweep. Module: `extensions/shared/task-runs.ts`; invoked from
`extensions/builtin-tools/index.ts` (`startBackgroundTask`).

## What is retained

Every `background: true` `task` dispatch writes one record
(`$TASK_RUNS_ROOT/<run_id>.json`, which carries the composed final message) and
one capture log (`$TASK_RUNS_ROOT/<run_id>.log`). Default root:
`~/.pi/agent/task-runs` (mode `0700`, records/logs `0600`).

`TASK_RUNS_ROOT` only names the tree; it does **not** arm the sweep.

## Retention bounds

Age **or** total bytes, whichever binds first, evicting the OLDEST non-live run
first. A live run (`status: "running"` with an alive pid, or a dead pid whose
log is inside the 5-minute settle grace) is never evicted.

| Knob | Default | Meaning |
|---|---|---|
| `TASK_RUNS_MAX_AGE_DAYS` | `7` | age bound |
| `TASK_RUNS_MAX_BYTES` | `2147483648` (2 GiB) | size bound |
| `TASK_RUNS_PRUNE` | unset (sweep runs) | `0` disables the sweep entirely |
| `TASK_RUNS_PRUNE_DRY_RUN` | `1` | `1` = report only; `0` = **armed** (deletes) |
| `TASK_RUNS_LOG_MAX_BYTES` | `16777216` (16 MiB) | per-run capture-log cap (truncate-while-keeping-the-tail; the record is never capped) |

## ⛔ Dry-run by default — this is the recorded decision

This sweep is **DRY-RUN by default**, matching the sibling
`scripts/pi-task-session-prune.sh` contract and the retention decision recorded
in `AGENTS.md` (*"Retention is owned, bounded, and dry-run by default … arming it
is a separate manual step owned by that operator … Until it is armed the bounds
do not bind — a known, accepted state, not a silent one."*). The same precedent
is recorded for a new sweep in
`docs/scoping/2026-09-15-issue-1095-worktree-reaper.md:271`.

A default-armed sweep that deletes `<run_id>.json` would silently drop the
composed final message of a settled lane — a decision contradiction, not a
style preference, so the default is report-only.

An unarmed pass logs one line per dispatch that has something to evict:

```
[task] task-runs retention DRY-RUN: would evict N run(s) (B bytes) — not armed; set TASK_RUNS_PRUNE_DRY_RUN=0 to arm (TASK_RUNS_PRUNE=0 disables)
```

## Arming — a separate, owned step

**Owner:** the organisation-design-team operator on call for `agent-infra`.

Arming is manual and dated: set `TASK_RUNS_PRUNE_DRY_RUN=0` in the environment
that launches the dispatching session/agent. There is no default-ON job for this
tree; the sweep runs in-process on each background dispatch. Until armed, the
bounds are reported, not enforced.

## Failure reporting

`writeRunRecord` reports failure only through its return value. Every persist in
the dispatch path — including the fire-and-forget **settle** writes — checks it
and logs loudly on failure. A swallowed settle-write leaves the record at
`running` after a child has settled, which `task_collect` finalizes as a
permanent `failed`/`settle-lost` with `content: null`; the `console.error` is the
signal that a settled lane's result is not durable.
