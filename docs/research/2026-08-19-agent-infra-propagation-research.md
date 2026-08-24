# agent-infra → Consumer Repo Propagation Research

**Date:** 2026-08-19 (based on current checkout state)
**Question:** How does a change in agent-infra reach a consumer repo's runtime? Where are the gaps? Where must #1484 land so it propagates everywhere?
**Evidence base:** read of agent-infra (bin/agent-infra.js, manifest.json, sync, sync-all, sync.sh, pi-bootstrap/setup.sh, templates/, extensions/main-worktree-guard/, docs/ci-centralization-plan.md, docs/research/2026-08-14-checkout-discipline-homes.md), tortoise (scripts/, .husky/, .github/workflows/, AGENTS.md, .env.example, .agent-infra-version), premise-labs + eldato + swarm (workflows, bootstrap), live ~/.pi/agent install, ~/Library/LaunchAgents.

---

## 1. The mechanism — five propagation channels

| Channel | Mechanics | Live vs Copy | Refresh trigger |
|---|---|---|---|
| **A. Extension farm** | `~/.pi/agent/extensions/*` → symlinks into `agent-infra/extensions/*` (26 entries, incl. `main-worktree-guard/`) | **LIVE (symlink)** | `pi-bootstrap/setup.sh` (re-run refreshes in place); `agent-infra update` run from any consumer repo re-forces symlinks |
| **B. Skills** | `~/.pi/agent/skills` → `agent-infra/skills` | **LIVE (symlink)** | `setup.sh` keeps the farm if it points into the repo ("updates via git pull"); `agent-infra update` re-forces the symlink |
| **C. Repo scripts** | `<consumer>/scripts/` → `agent-infra/scripts` | **LIVE where symlinked** — tortoise ✓, premise-labs ✓, all ~30 worktrees ✓; **NOT for DMeer, dmer, eldato** (real dirs) | `agent-infra init/update` |
| **D. Templates** | `AGENTS.md`, `.husky/`, `.mcp.json`, `.gitignore` **copied** from `templates/` | **COPY — only if missing.** `init/update` never overwrites existing files ("preserved") → drift accumulates silently | `agent-infra init/update` (copy-if-missing only) |
| **E. Version pin** | `.agent-infra-version` written by init/update (currently `0.1.0` everywhere) | COPY (per repo) | `agent-infra update` bumps it; mismatch **blocks commits** via copied `.husky/pre-commit` gate (skips if `AGENT_INFRA_PATH` unset) |

**Orchestrators:**
- `agent-infra sync <repo>` / `sync-all` → runs `agent-infra update` inside every repo carrying `.agent-infra-version` under `$AGENT_INFRA_REPOS_ROOT` (~/Documents/GitHub). This is the PUSH direction (agent-infra → consumers).
- `sync.sh` → PULL direction: `git pull --ff-only origin main` on agent-infra itself + re-run `pi-bootstrap/setup.sh`. Branch-ownership guard: refuses to pull off-main (#265).
- `agent-infra check [repo]` → verifies symlinks match `manifest.json`; **flags any local file where a symlink is expected as "diverged"** (CI workflows, scripts, extensions).

**Version gate (E) is commit-local only** — it lives in the copied `.husky/pre-commit` template. No consumer repo runs it (or `agent-infra check`) in CI (verified: tortoise workflows reference agent-infra only in comments).

## 2. The guard extension specifically

**Canonical source = agent-infra.** `~/.pi/agent/extensions/main-worktree-guard` is a **symlink** → `agent-infra/extensions/main-worktree-guard` (created by setup.sh/init; last refreshed 13 Aug). The live install is NOT a copy — edits to `agent-infra/extensions/main-worktree-guard/index.ts` are immediately live for every pi session on this machine. Nothing "updates" it beyond the symlink refresh; a stale/foreign link (broken or pointing at a different clone path) is replaced by setup.sh, never deleted.

Extension auto-loading: pi loads from `~/.pi/agent/extensions/` (no per-repo extension install exists — the farm is global, so the guard is active in every repo's sessions).

## 3. CI/CD sharing status — **NOT centralized (the big gap)**

- agent-infra has **reusable workflows** (`on: workflow_call`): `agent-infra/.github/workflows/{python,node,docs}-ci.yml`, plus `templates/.github/workflows/*` symlinked into repos for `agent-infra check` drift detection — this is the locked design in `docs/ci-centralization-plan.md` (hybrid: reusable workflows for execution + symlinks for drift detection; thin `ci.yml` callers per repo).
- **No consumer repo actually consumes them.** tortoise: all **14 workflows are local self-contained files** — deliberately, per inline comments: "Self-contained on purpose (fix #555): no reusable-workflow call and no `scripts/`/`agent-infra` symlinks — both resolve to paths that are broken on the runner." (The prior symlink was silently ignored by GitHub.) premise-labs: single local `ci.yml`, no symlinks. eldato: all-local workflows.
- The plan's DoD ("all 3 repos CI symlinked + `agent-infra check` passes") is **not met**. `agent-infra check` would report tortoise's python-ci.yml as "local file (not symlinked)".

**Conclusion:** CI/CD is effectively per-repo today. The user's goal ("same CI/CD and agent workflows, centralized in agent-infra and propagated") requires reviving the centralization plan — tortoise's #555 self-containment was a reaction to broken symlinks, not a rejection of shared workflows; a thin `ci.yml` calling `daniel-ospina/agent-infra/.github/workflows/python-ci.yml@main` is the working shape.

## 4. #1484 pieces — placement verdict

| #1484 piece | Current home | Propagation status |
|---|---|---|
| Guard (incl. M4) | `agent-infra/extensions/main-worktree-guard/` | **Already canonical + LIVE** (symlink farm). Landing = merge to agent-infra; no further propagation needed locally. |
| checkout-hygiene scripts (`corruption_canary.py`) | `agent-infra/scripts/checkout-hygiene/` | **Already canonical + LIVE** via `~/.pi/agent/scripts/checkout-hygiene/corruption_canary.py` (symlink) and consumer `scripts/` symlinks. |
| using-git-worktrees skill | `agent-infra/skills/using-git-worktrees/` | **Already canonical + LIVE** (`~/.pi/agent/skills` symlink). |
| **launchd scheduling (the canary plist)** | `~/Library/LaunchAgents/com.eldato.corruption-canary.plist` — **per-machine, unversioned** | **GAP.** Points at the symlinked script (so script updates flow), but the plist itself lives only on this machine. swarm's `deploy/install-launchd.sh` (run by `bootstrap.sh`) installs the 6 `com.eldato.*` daemons but does NOT install the canary plist. No repo versions it; no mechanism installs it on a new machine. |

**Verdict: #1484 SHOULD live in agent-infra — and largely already does.** The guard, canary script, and skill are agent-infra artifacts today; the only genuinely un-propagated piece is the launchd scheduling of the canary (per-machine, manual).

## 5. What's missing — the gaps and the "centralize + propagate" fix

1. **CI is not shared.** Revive ci-centralization-plan: per-repo thin `ci.yml` callers → `agent-infra/.github/workflows/*-ci.yml@main` (pin to a tag, not `@main`, for stability); keep templates authoritative; delete self-contained duplicates; add `agent-infra check` (or the version gate) as a CI job so drift fails CI, not just local commits.
2. **Templates copy-if-missing only → silent drift** (AGENTS.md, .husky, .mcp.json say "managed by agent-infra update" but update never overwrites). Fix: template merge/overwrite policy (footer diff + explicit refresh) or a drift check inside `agent-infra check`.
3. **`~/.pi/agent/scripts` is a half-farm** (record-review.sh is a plain copy; checkout-hygiene is a symlink). Make the whole dir a symlink farm or fully version the copies.
4. **Unlinked consumers** (DMeer, dmer, eldato have real `scripts/` dirs despite `.agent-infra-version`) — decide: symlink them (run `agent-infra init`) or mark them exempt.
5. **launchd plists are per-machine, unversioned.** Fix: ship plist templates in `agent-infra/templates/launchd/` + an idempotent installer script (`scripts/install-launchd.sh`), consumed by swarm bootstrap and `pi-bootstrap` for non-swarm machines (the canary). This is the concrete #1484 propagation work item.
6. **Version bump is the propagation contract.** All consumers pin `0.1.0`. A #1484 merge should bump the manifest version → the copied `.husky/pre-commit` gate blocks consumer commits until `agent-infra update`/`sync --all` runs — turning "did it propagate?" into "the gate forces it".

## 6. How to validate a #1484 change lands everywhere (checklist)

1. `git -C agent-infra pull` → `./sync.sh` (refresh local pi config) → confirm `~/.pi/agent/extensions/main-worktree-guard` resolves into agent-infra.
2. `./sync --all` from agent-infra → runs `agent-infra update` in every linked repo; confirm scripts/ symlinks + version pins refresh.
3. `agent-infra check <repo>` per consumer → green (this is the drift detector; make it a CI gate).
4. New machine: `pi-bootstrap/setup.sh` (extensions+skills farm) + swarm `bootstrap.sh` (daemons + launchd); canary plist must come from the new versioned installer (gap #5).
