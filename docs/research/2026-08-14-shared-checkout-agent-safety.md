---
title: "Research: Shared-Checkout Agent Safety — daemon execution surface, gate bypass, corruption root-cause"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-14
aboutObjects: main-worktree-guard, agent-infra, swarm
---

# Shared-Checkout Agent Safety — research + incident root-cause

**Date:** 2026-08-14
**Trigger:** two corruption incidents in the swarm main checkout + wrong-branch
commit class, traced to daemons executing cards in the shared hub with all
safety gates disabled.

## Problem (reframed)

The git-coordination research (2026-08-07) prescribes the shared main checkout
as an **idle hub on `main`**: agents work in isolated worktrees. The swarm's
runtime violates that contract in one load-bearing place — **daemon agents
spawn `pi` directly in the shared main checkout, with the safety gates turned
off** — which produced:

1. **Corruption incident 1 (2026-08-12):** `STATUS_LABEL` tokens mass-injected
   into 300+ tracked files, the venv, and inner `.git` metadata. Recovered via
   HEAD restore + venv rebuild.
2. **Corruption incident 2 (2026-08-13→14):** `handle_error(raise)` tokens +
   `.bak` backups of every touched file — the same agent pattern (backup-then-
   botched-global-replace), re-injected into the shared tree after recovery.
3. **Wrong-branch commit class (agent-infra #265):** the shared checkout was
   switched to a daemon branch (`epic-tracking`) under other sessions; an
   operator commit landed on the daemon's branch.
4. **Direct-to-main pushes:** daemon commits (`698e1f5`, `32ae138`) landed on
   main, bypassing branch protection ("Bypassed rule violations").

## Root cause (verified in code)

`operations/coordination/swarm_daemon.py:115-116` spawns pi with:

```
AGENT_ALLOW_MAIN_EDITS=1   # guard off
ELDATO_SKIP_VGATE=1        # verification gate off
AGENT_SKIP_REVIEW_GATE=1   # review enforcer off
```

with `cwd=<swarm root>` for swarm-repo cards — a pi agent with ALL gates
disabled, editing the shared hub directly. Any botched edit (as happened
twice) corrupts the hub; any branch switch under it strands other sessions
(#265). The `main-worktree-guard` (#39 — hardened `1e71c5c`) closes the
bash-tool vectors but not (a) subprocess-level git (the recovery path used
here), nor (b) environments where the daemon itself disables the guard.

## External findings (2026-08-14)

| Claim | Tier | Sources |
|-------|------|---------|
| Block raw git for agents; replace with governed git ("block the primitive") | High | htek.dev hookflows-governed-git |
| Branch protection must be unbypassable: require PRs + status checks + block force-push, disable admin/agent bypass | High | GitHub community guidance; dev.to "Stop Letting Agents Push to Main" |
| Never let agents commit directly to main; always start on a feature branch | High | goose_oss; GitHub production guidance |
| "Wrong Branch" is an empirical agent-failure class (PR targets wrong branch) | High | arXiv 2601.15195 (empirical study of coding agents) |
| CI gates + mandatory review for AI PRs | High | GitHub community #182197 |
| Worktree-per-agent + fresh base per task is canonical for fleets | High | internal 2026-08-07/08-11 research; Claude Code, Conductor, nx.dev |

## Decision — layered enforcement

1. **Daemons never execute in the shared hub.** Swarm-repo cards execute in a
   dedicated execution worktree (or per-card worktrees), consistent with the
   multi-repo checkout resolution already shipped (epic #5260). The hub stays
   on `main`, clean, idle.
2. **Remove the gate-disabling env** from `swarm_daemon.run_pi`. If a daemon
   path needs gates off, it must be an explicit, logged, time-boxed exception —
   not the default.
3. **Hub-on-main enforcement** (agent-infra #40/#265): session/daemon-start
   hard-warning when the shared checkout is on a non-main branch or dirty;
   redirect feature work to worktrees.
4. **Server-side:** strict branch protection on `swarm` (require PRs + status
   checks + block direct/force pushes, no bypass) so daemon work lands via
   commit-workflow PRs, not direct pushes.
5. **Corruption canary:** watch for `.bak` files and known token patterns
   (`STATUS_LABEL`, `handle_error(`) in the hub; alert + auto-revert on
   detection. Root-cause the specific card/agent behind both incidents from
   the events log.
6. **Close the subprocess bypass** (agent-infra #39 follow-up): the guard
   intercepts the bash tool but not subprocess-level git; daemons and recovery
   paths operate at subprocess level.

## Open questions (human decision)

- Per-card worktrees vs one dedicated daemon execution worktree for
  swarm-repo cards (per-card matches the tortoise workflow precedent but adds
  venv/setup cost; one dedicated worktree is cheaper, still isolates the hub).
- Whether the corruption incidents warrant a dedicated canary in CI (swarm
  repo) or just the hub-side watcher.

## Related

- `docs/research/2026-08-07-multi-agent-git-coordination.md` (layered defense)
- `docs/research/2026-08-11-git-freshness-agent-checkouts.md` (freshness layers)
- agent-infra issues #39, #40, #265, #266
- swarm epic #5260 (multi-repo readiness — per-repo checkout resolution)
