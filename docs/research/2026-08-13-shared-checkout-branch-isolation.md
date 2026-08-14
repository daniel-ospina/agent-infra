---
title: "Research: Shared-Checkout Branch Isolation for Parallel Pi Sessions (#265)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-13
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-265, main-worktree-guard, auto-sync
---

# Shared-Checkout Branch Isolation for Parallel Pi Sessions (#265)

> **Findings date:** 2026-08-13

## Purpose

External best-practice import for issue #265 (shared-checkout branch-switching hazard):
parallel pi agent sessions share ONE working tree (the agent-infra main checkout), and branch
state mutates under live sessions via auto-sync's session_start force-switch, unguarded
`git checkout -b` (guard exempts agent-infra, #99), and branch identity asserted only at
work-start, never at commit time.

## Axis Research (Architecture — medium)

### Codebase-first precedent scan (strong, in-repo)

- `extensions/main-worktree-guard/` — existing destructive-git classifier (classify-git.mjs)
  already classes `checkout/switch` as `block:checkout-branch`; guard exempts agent-infra
  (`index.ts:134`, #99 b6d66fa — deliberate: "small infra repo — no worktree needed").
- `extensions/auto-sync.ts` `tryLosslessRecover()` (lines 118–175) — force-switches the
  shared tree to main (`git checkout -f main` + `merge --ff-only origin/main`) at every
  non-print session_start when the tree matches origin/main "losslessly"; single-actor
  tests only (`auto-sync.test.ts:257–296`), no concurrency coverage.
- `skills/issue-workflow/SKILL.md:139–193` — Branch Gate asserts CURRENT_BRANCH ==
  EXPECTED_BRANCH at work-start, but executes `git checkout -b <branch> origin/main` in the
  current checkout (shared tree for agent-infra sessions) — start-time gate, TOCTOU gap.
- `extensions/builtin-tools/index.ts:1660–1661` — every task sub-agent env sets
  `AGENT_ALLOW_MAIN_EDITS=1` + `ELDATO_ALLOW_MAIN_EDITS=1` (escape hatch is the sub-agent default).
- `docs/research/2026-08-07-multi-agent-git-coordination.md` — PRIOR_RESEARCH: layered
  defense; Layer 2 hub discipline (main stays on main, session-start hard warning) ratified
  as Decision 1; lock files/branch registries REJECTED ("git has no ownership; registries go
  stale; enforcement required"); Layer 5 daemon-awareness ⛳ never built.
- `./sync.sh:8` (repo ROOT — not `scripts/`) — `git pull --ff-only origin main` in the main
  checkout; FF-moves a feature branch's ref if the tree sits on one.

### Canonical framing (worktree-per-agent is the consensus for parallel agents)

| Source | Claim |
|---|---|
| mindstudio.ai (2026) | Worktrees isolate each AI agent in its own working dir + branch, preventing collisions; create worktrees from `main`, split tasks by domain |
| augmentcode.com (2026) | One git worktree per agent, explicit task boundaries, tests/verification gates before merge |
| nrmitchi.com (2025) | All AI-agent development in worktrees; name worktrees/branches by task; be explicit about context |
| zylos.ai research (2026-02) | Parallel-agent lessons: one worktree at a time into `main`, pre-flight merge checks, `git worktree prune` after merge |
| towardsdatascience | Worktrees help parallel work ACROSS different branches — not same-branch collaboration |

Consensus: for parallel agents, one worktree per agent/task with the main checkout kept
stable on `main`. Physical isolation solves cross-session branch ownership without any
ownership registry (matches prior research's rejection of registries).

### Pitfalls framing (what fails in practice)

| Source | Claim |
|---|---|
| StackOverflow "Is a local git repository thread-safe" / "Locking strategy of git" | Git's internal locks (index.lock, ref locks) protect repo **metadata**, NOT the working tree; `git checkout -f` is **not atomic** w.r.t. another process manipulating files in the tree — concurrent checkouts can cause data loss |
| StackOverflow (same) | `flock` is the standard **external** coordination mechanism to serialize whole git workflows across processes; git has no built-in whole-repo mutex |
| git docs via augmentcode | `git worktree lock` is **advisory** (prevents administrative removal) — NOT a concurrency primitive |
| trigger.dev / zylos / penligent (Agent-B diverge queries) | Teams report abandoning worktree-per-agent for **interactive** sessions: checkout isolation ≠ runtime isolation (ports, deps, disk, IDE gaps); one team switched to virtual branches (GitButler-style) |
| pre-commit docs (Agent-B diverge query) | Commit-time guards are standard practice on the **commit side** (pre-commit `no-commit-to-branch`); but `--no-verify` bypasses hooks — extension-level interception is more reliable |

Implications for the fix:
1. auto-sync's `git checkout -f main` under concurrency is a real data-loss vector (SO
   thread-safety), not just an annoyance — its recovery must be session-aware (flock-style
   serialization or a provable-idleness gate).
2. Worktree-per-agent is the right isolation model for the parallel case (canonical
   consensus), but must be **enforced for branch state, tolerant for runtime writes**:
   agent-infra's symlinked runtime (skills/extensions load from the main checkout) means a
   pure worktree-for-all model breaks the live loader — the #99 write exemption stays, the
   branch-state rules (checkout/switch blocked in main, hub warning active, commit-time
   assertion) apply everywhere.
3. Commit-time assertion is the standard pattern to close the TOCTOU gap, but must live at
   the extension layer (pi tool_call interception), not a git hook (`--no-verify` bypasses
   hooks; hooks are per-machine and untracked `.husky/` today).

## Raw Notes

- 2026-08-13 — [canonical] Worktree-per-agent consensus for parallel agents (mindstudio,
  augmentcode, nrmitchi, zylos, towardsdatascience). Main checkout stays stable on main.
- 2026-08-13 — [pitfalls] Git working tree is NOT protected by git's internal locks;
  `git checkout -f` is non-atomic under concurrency (SO). flock is the external serialization
  mechanism. `git worktree lock` is advisory only.
- 2026-08-13 — [pitfalls] Worktree-per-agent abandonment reported for interactive sessions
  (trigger.dev virtual branches; zylos; penligent) — checkout isolation ≠ runtime isolation.
- 2026-08-13 — [pitfalls] Commit-time guards standard (pre-commit no-commit-to-branch) but
  `--no-verify` bypasses hooks → prefer extension-layer interception.
- 2026-08-13 — [adversarial] Challenge to "detection is the fix": 6 classifier bypasses
  verified (`git switch -c`, `git -C <path> checkout`, `--orphan`, `symbolic-ref`,
  `update-ref`, `branch -f`) — switch-time detection alone is unfalsifiable; commit-time
  ownership + actor fixes are required.
- 2026-08-13 — [adversarial] Challenge to "blocking enforcement": escape-hatch decay risk —
  if writes to agent-infra main are blocked, every agent-infra session hits the block and the
  TTL marker (#207) becomes the default → worse than today's honest #99 exemption. Hence:
  keep the write exemption, enforce branch-state rules.
