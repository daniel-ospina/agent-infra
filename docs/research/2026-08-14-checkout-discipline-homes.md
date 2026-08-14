---
title: "Research: Where the checkout discipline lives — shared homes + coherence across repos"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-14
aboutObjects: main-worktree-guard, agent-infra, swarm, tortoise
---

# Where the checkout discipline lives — coherence across repos

**Date:** 2026-08-14
**Question:** the checkout discipline (guards, worktree isolation, corruption
canary, hub-on-main) is scattered across agent-infra, swarm, and tortoise. How
do we maintain ONE source of truth so maintainability is automatic?

## The answer: three shared homes, consumed by every repo

| Layer | Canonical home | Install/consume mechanism | Applies to |
|---|---|---|---|
| **Behavior (extensions + skills)** | agent-infra (`extensions/`, `skills/`) | Installed globally to `~/.pi/agent/{extensions,skills}` (pi setup) | Every repo's pi sessions automatically |
| **Runtime scripts** | agent-infra `scripts/checkout-hygiene/` | Symlinked into `~/.pi/agent/scripts/checkout-hygiene/` (the `record-review.sh` precedent) — any repo/daemon calls the shared path | Swarm daemons, interactive sessions, CI |
| **Repo-specific runtime** | the owning repo (swarm: `repos_loader`, `checkout_guard.sh`) | Stays in-repo; consumes the shared scripts | That repo's daemons only |

## What lives where now (2026-08-14 state)

- **agent-infra (canonical):**
  - `main-worktree-guard` extension (hub protection; escape hatch non-ambient)
  - `using-git-worktrees` skill — now includes **Checkout Discipline**:
    delete-on-merge, hub-check, canary usage, no-ambient-guard-disable
  - `scripts/checkout-hygiene/corruption_canary.py` — the shared canary
  - research docs (multi-agent-git-coordination, freshness, shared-checkout safety)
- **swarm (runtime):** `repos_loader.resolve_exec_checkout` (role-scoped daemon
  execution worktrees for ALL repos — hub isolation), `checkout_guard.sh`,
  the launchd daemons. The canary is invoked from the shared path.
- **tortoise (consumer):** inherits the discipline via pi skills/extensions
  (installed globally); its worktree-per-issue workflow gets the
  delete-on-merge step from the skill.

## How coherence stays automatic

1. **One edit site per artifact.** Change the canary once in agent-infra; the
   symlink propagates. Change the discipline once in the skill; every session
   picks it up.
2. **Bootstrap verification.** Each repo's bootstrap (swarm: `scripts/bootstrap.sh`)
   verifies: guard env NOT exported, shared scripts present (symlink target
   exists), hub-on-main. Fail-closed on missing discipline.
3. **The canary is scheduled** (launchd) against the hub — a recurrence is
   caught even with no session active.
4. **New repos** get the discipline for free: clone + pi setup installs the
   skills/extensions; the bootstrap links the shared scripts.

## Pitfalls

- Symlinks are machine-specific (agent-infra path) — the bootstrap creates
  them; a missing target must hard-fail, not silently degrade.
- Don't duplicate scripts into consumer repos (the swarm canary file was
  merged in #6904 before this refactor — it now delegates to the shared path).
- Skills are copied to `~/.pi/agent/skills` at install; edits must be made in
  agent-infra and re-synced (the existing skill-sync mechanism).

## Related

- docs/research/2026-08-07-multi-agent-git-coordination.md (layered defense)
- docs/research/2026-08-14-shared-checkout-agent-safety.md (incident root-cause)
- swarm #6688 (daemon exec worktrees), #6689 (canary), agent-infra #269
