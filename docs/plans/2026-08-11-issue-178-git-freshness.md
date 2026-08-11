# Issue #178 — Agent git freshness: never work from stale checkouts

Status: PLAN — scope approved (research round 3 adversarial confirmation: all
practices verified good; 2×P1 + 1×P2 gaps folded)
Branch: feat/178-git-freshness (cut from origin/main — dogfooding L1)
Date: 2026-08-11
Level: project | Complexity: standard | Team: agent-infra

## Stage 1 — Align (standalone, adversarial-lite)

**Eisenhower:** Important + Urgent. Regressions from stale checkouts are
recurring NOW (live audit 2026-08-11: autocast-project + AutoCast 12 commits
behind on clean main; swarm 1 ahead + 21 dirty; tortoise mid-work). Every
stale branch risks re-introducing already-fixed code and conflict churn across
the agent fleet.

**Adversarial challenge 1 — "GitHub's merge flow already catches staleness;
is this needed?"** Partially true: branch protection / merge conflicts catch
it at merge time. But the damage is paid earlier — branches cut from stale
bases re-introduce reverted/fixed code in ways that merge CLEANLY (worst
case: silent regressions, no conflict), and agents resolve merge-time
conflicts with the same stale mental model. Prevention at branch-creation and
ambient freshness is strictly better. PROCEED.

**Adversarial challenge 2 — "Over-engineered: isn't L1 alone enough?"** L1
closes gate-fronted branch creation, but the fleet audit shows real work
happens outside gates too (dirty swarm checkout, long-lived cmux sessions
running for days). L3 closes the pre-PR gap. L2 is honestly demoted to
hygiene/visibility (research tier: ⚠️ emerging necessity) — but it is the only
layer covering gate-bypassers and long-lived sessions, and agents cannot
respond to warnings, so ambient auto-heal is the mechanism. PROCEED with all
three, ordered by correctness value L1 → L3 → L2.

**Align decision:** BUILD. Three layers, ordered L1 → L3 → L2, plus the
zero-cost `pull.ff only` machine guard. Two human decisions deferred to the
Scope gate (L2 default mode; branch-protection backstop).

## Stage 2 — Research (complete, 2 rounds)

`docs/research/2026-08-11-git-freshness-agent-checkouts.md` — fresh-session
verified (NO ISSUES FOUND after one fix cycle). Verdicts: L1 textbook (HIGH),
L2 standard-with-guards (HIGH safety / ⚠️ emerging necessity), L3 standard
(HIGH). Refinements folded: gpg-sign hazard, filesystem-watcher guard, pi
timer constraint, plain-git fleet verified, `pull.ff only` guard.

**Round 2** resolved the two open questions against external practice:
- IDE consensus = auto-fetch yes, auto-pull never-under-active-work; fleet
  management = auto-apply when safe + verify + observable (CrowdStrike:
  kill-switch, fail-open); agent tools = fresh base at task boundaries
  (Claude Code worktrees branch from `origin/HEAD` with fetch-refresh if
  >24h stale). L2's envelope excludes active work by construction →
  **auto is the evidence-backed default**.
- OpenSSF explicitly recommends "require branches up to date before merging"
  to stop "previously fixed issues slipping back in" (= this fleet's
  regression class); ladder-friction criticism targets busy repos — fleet
  throughput is low → **enable strict up-to-date as backstop**.

## Stage 3 — Scope (proportional double diamond)

### Problem (converged)

Agents work from whatever the local checkout happens to contain. Three gaps,
verified in-repo:
1. **issue-workflow Branch Gate never fetches** — branches cut from local
   main; commit-workflow and using-git-worktrees both branch from origin/main
   already (issue-workflow is the outlier — confirmed: zero fetch in its gate
   script).
2. **Long-lived sessions get no freshness** — cmux pi panes live for days;
   nothing fetches or surfaces drift after session start.
3. **No pre-PR reconciliation** — nothing checks/rebases against the origin
   default branch before shipping.

### Alternatives evaluated

| # | Alternative | Verdict |
|---|-------------|---------|
| A | **All three layers (L1 gate fix, L2 repo-freshness extension, L3 pre-PR rebase) + `pull.ff only` machine guard** | ✅ Selected — each layer covers a distinct gap; MECE |
| B | L1 only | ❌ leaves sessions + pre-PR gaps; fleet audit shows off-gate work is real |
| C | L1 + L3 only (no ambient extension) | ❌ no coverage for gate-bypassers / long-lived sessions; research says L2 is hygiene-tier but it is the ONLY layer covering that class |
| D | Server-side only ("require up to date" branch protection) | ❌ as sole measure — detection at merge time, resolution burden still on agents; ✅ as complementary backstop (open question 2) |

### Solution (converged)

**L1 — Branch Gate freshness (skills/issue-workflow/SKILL.md):**
- Detect default branch: `DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')` (fallback main).
- Before branch creation: `git fetch origin "$DEFAULT_BRANCH" --quiet` and create with `git checkout -b "$EXPECTED_BRANCH" "origin/$DEFAULT_BRANCH"` — local main untouched.
- Same treatment for the "checkout main first" abort guidance lines.
- Source-assertion test (drift-guard pattern) pinning the fetch + origin/ branching in the skill text.

**L2 — repo-freshness extension (extensions/repo-freshness.ts, new):**
- Gating: active in interactive sessions only (skip PI_MODE=print), only in git repos with an origin remote; opt-out AGENT_REPO_FRESHNESS_DISABLED=1.
- session_start + periodic (~20 min; timer started in session_start, cleared in session_shutdown per pi extension rules; unref'd): `git fetch --quiet` with 30s timeout, silent failure.
- State machine reuses auto-sync semantics: current/behind/ahead/diverged vs origin/<default>.
- On default branch + clean tree + no MERGE_HEAD/REBASE_HEAD + no index.lock + no dev-server guard hit → `git pull --ff-only` (AGENT_REPO_FRESHNESS_MODE=auto, default) or warn (warn mode). Git re-checks dirtiness at pull time — final arbiter.
- On feature branch → report-only: "base is N commits behind origin/<default>".
- Exclusions: agent-infra repo (auto-sync.ts owns it — no double-pull), submodules present (report-only), worktrees whose checked-out branch is the default branch of ANOTHER worktree (skip pull, report).
- **main-worktree-guard interaction (adversarial-review fold, P1):** the fleet's
  guard blocks pull/merge/rebase issued via the **bash tool** in main checkouts
  (incident 2026-08-06). L2 runs as extension-level code, which the guard does
  not intercept — a deliberate, documented carve-out, ratified by precedent:
  auto-sync.ts has always done extension-level main-checkout ff-pulls
  (agent-infra). The carve-out is safe BECAUSE the envelope is strictly
  narrower than any bash command (deterministic ff-only pull, all guards
  pre-checked), observable (logs `[repo-freshness] auto-pull <repo> <old>→<new>`
  on every pull), and reversible (`AGENT_REPO_FRESHNESS_DISABLED=1`). Recorded
  at the Scope gate; E6 covers it.
- **Unsaved editor buffers (adversarial-review fold, P2):** undetectable from
  git (same class as the watcher hazard) — accept-and-document per repo; repos
  with a live editor session on main can be set to warn mode individually.
- Wired: manifest entry + pi-config symlink + targeted live-farm symlink (drift gate green); tests against real throwaway git repos (auto-sync.test.ts pattern).

**L3 — pre-PR freshness + merge-time recovery (skills/commit-workflow/
workflow/01-preflight.md + 04-merge-deploy.md):**
- After branch detection / before PR creation: `git fetch origin "$DEFAULT_BRANCH" --quiet`; compute behind-count of branch vs origin/<default>.
- Behind > 0 + clean tree → `git -c commit.gpgsign=false pull --rebase origin "$DEFAULT_BRANCH"`; re-run typecheck/tests after rebase (existing preflight machinery).
- Behind > 0 + dirty tree → WARN with explicit instructions (no autostash — conflict-unsafe per research).
- Behind = 0 → silent.
- **Stale-merge recovery (adversarial-review fold, P1):** with strict
  up-to-date protection, a merge can land between L3's rebase and
  `gh pr merge` — today the workflow has NO recovery path (only
  `git push -u origin <branch>` exists). Add to 04-merge-deploy.md: if merge
  is blocked as stale → fetch, `git -c commit.gpgsign=false rebase
  origin/<default>`, re-run typecheck/tests, `git push --force-with-lease`,
  retry merge (bounded retries, then escalate).
- Source-assertion test pinning both steps.

**L0 — machine guard:** `git config --global pull.ff only` (documented in the plan; one-time fleet config, verified idempotent).

### High-level E2E (key journeys, proportional)

- E1 (L1): real repo fixture — local main stale vs origin → run gate script logic → branch tip == origin/default tip; local main unchanged.
- E2 (L2): real repo fixtures per state — behind+clean → ff-pulled; behind+dirty → no-op+warn; feature branch → report-only; MERGE_HEAD present → no-op; index.lock present → no-op; divergence → guidance, no pull.
- E3 (L3): behind+clean → rebased onto origin tip; behind+dirty → warned, untouched; gpgsign flag present in the command.
- E4 (fleet): drift audit script run post-rollout — 0 repos silently behind origin.
- E5 (L3 recovery): merge blocked as stale → fetch + rebase + checks + `push
  --force-with-lease` + retry merge path exists in 04-merge-deploy.md
  (source-asserted).
- E6 (L2 guard carve-out): repo-freshness respects its own envelope in a
  guarded-checkout fixture (guard semantics = bash-tool interception; L2's
  extension-level carve-out verified against the envelope list, agent-infra
  excluded).

### In scope / out of scope

In: the three layers + machine guard + tests + wiring + drift-gate parity.
Out: GitHub branch-protection changes (needs per-repo admin decision — open
question 2), submodule recursion, LFS handling, Windows/CI environments,
cmux-side surface refresh behavior.

### Decisions resolved at Scope gate (research round 2)

1. **L2 default mode: `auto`** — within the strictest safe envelope (default
   branch only, clean tree, ff-only, not-ahead, no merge/rebase/lock,
   feature branches report-only) + observability: log every auto-pull,
   `AGENT_REPO_FRESHNESS_DISABLED` kill-switch, fail-open to warn on any
   anomaly. Evidence: IDE practice forbids pull-under-active-work (excluded
   by construction here); fleet practice endorses auto-apply-when-safe with
   verification; agents cannot act on warnings.
2. **Server-side backstop: YES** — enable "Require branches to be up to date
   before merging" on fleet repos (OpenSSF recommendation; low-throughput
   fleet pays negligible ladder friction). Adversarial-review condition
   folded: strict mode converts rare silent regressions into rare hard merge
   blocks, so the L3 stale-merge recovery step (above) is MANDATORY with this
   decision. Applied during rollout as an operational step (admin action,
   not code); monitor-and-downgrade if friction observed.

### Complexity (domain-aware)

| Domain | Rating | Rationale |
|--------|--------|-----------|
| Org Infra | standard | two mandatory-gate skill edits; drift-guarded |
| Config | standard | new extension: periodic timer, git lock contention, watcher guard, wiring parity |
