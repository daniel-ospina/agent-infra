---
title: "Research: Multi-Agent Git Coordination — Worktree Isolation, Hub Discipline, Branch Lifecycle"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-07
aboutObjects: git-worktrees, main-worktree-guard, agent-infra, swarm
---

# Multi-Agent Git Coordination — Best Solution Research

**Date:** 2026-08-07
**Status:** Layers 1 & 4 complete (#40, #74). Layers 2-3 & 5-6 pending.

## Problem

Multiple interactive pi sessions share one main checkout (`/Users/home/tortoise`).
Incidents (2026-08-06):
1. Agent B ran `git reset --hard origin/main` mid-PR, wiping agent A's branch position (recovered from remote).
2. Two `git pull origin main` fast-forwards and branch switches under agent A mid-session.
3. Agent A deleted `origin/chore/hosted-db-config` (post-merge cleanup) while agent B sat on that branch — B lost its upstream mid-work.

**Reframed:** agents treating the shared main checkout as their personal workspace, with no coordination on branch state, branch lifecycle, or deletion.

## What We Have Internally

- `using-git-worktrees` skill — solid worktree creation (`.worktrees/`, .mcp.json/.env symlinks, baseline test verification). NOT enforced.
- `main-worktree-guard` extension (agent-infra, hardened `1e71c5c`) — blocks write/edit tools + destructive git (`reset`, `clean`, `merge`, `rebase`, `pull`, `branch -D`, `force-push`, `push --delete`, force/branch-switch `checkout`, `restore`, `stash pop`) in the main checkout; worktrees exempt; no auto-bypass.
- 20+ worktrees already exist at `.worktrees/` — mechanism in use, isolation not mandatory.
- swarm repo (`~/swarm`) — agent daemon with heartbeats (`operations/coordination/heartbeats/agent_events.jsonl`), `agent_cron.sh` scheduling.

## External Findings

| Claim | Tier | Sources |
|-------|------|---------|
| One agent = one worktree (isolated dir + branch, never share branches, short-lived branches, serialized merges) is the consensus pattern for parallel AI agents | **High** | Claude Code official docs, augmentcode, mindstudio, jeffkliu, nx.dev, e7coding, battyterm (7+ independent) |
| Worktree drawbacks: per-worktree dependency install, cache loss on cleanup, end-of-merge coordination, submodule edge cases | **Medium** | nx.dev, augmentcode, e7coding, termdock |
| Git does NOT track branch ownership — deletion coordination must be procedural or server-enforced | **Medium** | git docs, SO/GitHub/GitLab discussions |
| Branch lifecycle automation (delete-on-merge, scheduled stale cleanup, notification-before-delete) is standard practice | **Medium** | git-automation.com, pullpanda, github discussions |
| Server-side protections (protection rules, audit) don't protect the LOCAL shared checkout | **Medium** | consensus across sources |

## Recommendation — Layered Defense

| Layer | Measure | Status |
|-------|---------|--------|
| 1 | Guard the main checkout (destructive git, branch-switch, push --delete blocked) | ✅ `1e71c5c` |
| 2 | **Hub discipline**: main checkout sits on `main`; session-start hard-warning when on a non-main branch or dirty; feature work redirected to worktrees | ⛳ Issue #40 |
| 3 | **Coordinated branch deletion**: `push --delete` blocked unless branch not checked out in any worktree (`git worktree list`); owner-notification | ⛳ Issue #41 |
| 4 | **Server-side hygiene**: `deleteBranchOnMerge` + scheduled stale-branch cleanup with notification-first | ✅ #74 (2026-08-07) |
| 5 | **Daemon awareness** (swarm): scheduler avoids launching agents that collide with active interactive sessions/checkouts (heartbeats exist) | ⛳ Issue #43 |
| 6 | Observability: branch lifecycle events logged for diagnosability | ⛳ follow-up |

## Why Not Alternatives

- Lock files / branch registries: git has no ownership; registries go stale; enforcement required (Medium).
- GitHub protection rules alone: server-side only; doesn't protect local hub (Medium).
- Guard-only (current): closes destructive vectors but not the root behavior (agents starting feature work in the hub).

## Decisions

1. **Hub branch:** `main` only. Feature branches live in worktrees. Main checkout is a shared hub. ✅ (#40)
2. **`deleteBranchOnMerge`:** **Enabled** on `daniel-ospina/agent-infra` (2026-08-07, #74). Rationale: the main-worktree-guard (Layer 1) blocks destructive git operations in the main checkout, and #73 provides coordinated deletion checks. Stale-branch cleanup script (`scripts/cleanup-stale-branches.sh`) catches any stragglers with notification-first dry-run default.
3. **Policy docs:** Live in `skills/using-git-worktrees/SKILL.md` under "Shared Checkout Policy" section, with a reference back to this research doc.
