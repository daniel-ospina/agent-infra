# Research: keeping agent git checkouts fresh (auto-pull / staleness avoidance)

**Date:** 2026-08-11
**Question:** Are the three proposed layers good practice? (L1: branch from
`origin/main` at the branch gate; L2: ambient fetch + ff-only pull on clean
main via extension; L3: rebase onto `origin/main` before PR.)
**Context:** multi-agent pi fleet, long-lived cmux sessions, recurring
regressions from stale checkouts. Live audit: autocast repos 12 commits behind
on clean main; swarm/tortoise mid-work.

## Problem (reframed)

[Multi-agent fleet] trying to [never work from stale git checkouts] but
[pulling at the wrong moment destroys in-progress agent work] which results in
[regressions + conflict churn]. Adversarial framing tested: *with L1+L3 in
place, is L2 even necessary?*

## What we have internally

- `extensions/auto-sync.ts` — proven Level-1 pattern for agent-infra itself:
  session_start fetch → state machine (current/behind/ahead/diverged) →
  `pull --ff-only` (AGENT_SYNC_MODE=auto) or warn. Never pushes. Skips print
  mode. Tested against real git repos (`auto-sync.test.ts`). NOTE: the
  dirty-tree / MERGE_HEAD / REBASE_HEAD / index.lock guards in the L2 proposal
  are NEW code — proven precedent covers the fetch/state/ff-pull core only.
- commit-workflow preflight already does `git fetch origin main && git
  checkout -b ... origin/main` ✓. using-git-worktrees does `git fetch && git
  worktree add -b ... origin/main` ✓.
- **Gap:** issue-workflow Branch Gate branches from local main with NO fetch —
  the outlier, and the gate that fronts all issue work.

## External findings

### L1 — branch from `origin/main` at branch-creation time
**Verdict: textbook best practice.**
- Atlassian feature-branch workflow: `git fetch origin` + update from origin
  BEFORE creating a feature branch. asam-ev git best practices: branch from
  main, rebase on `origin/main`, merge `--ff-only`. Azure/GitHub guidance:
  `origin/main` is the shippable source of truth; PRs gate main.
- Branching from `origin/main` directly (not even moving local main) is a
  strict improvement over fetch+checkout-main — zero local-state mutation.
- Confidence: HIGH (≥3 independent sources + internal precedent in 2 skills).

### L2 — ambient fetch + ff-only pull on clean main
**Verdict: fetch part is unambiguously standard; auto-pull part is safe ONLY
with the guards proposed.**
- `git fetch` never touches the working tree — documented safe; background /
  periodic fetch is an established first-class pattern (GitKraken fetches as
  often as every minute; git ships `git maintenance prefetch` for exactly
  this).
- **`git maintenance prefetch` cannot substitute**: it writes
  `refs/prefetch/*` and deliberately does NOT update `refs/remotes/origin/*`
  — staleness detection needs a plain `git fetch` (git docs, verified).
- Auto-pull pitfalls (multiple sources): dirty tree + overlapping changes →
  aborted merge/conflict noise; `pull --rebase` + dirty index → failed
  stash/autostash conflicts; unattended scripts creating merge-commit mess.
  The proposed guards (on main/master only, clean tree, `--ff-only`, no
  MERGE_HEAD/REBASE_HEAD/index.lock, never on feature branches, sub-agents
  skipped) are exactly the documented mitigations. Git itself re-checks at
  pull time — a dirty-tree race aborts the pull, so git is the final arbiter.
- Adversarial finding: with L1+L3 in place, L2 is **visibility + ambient
  hygiene, not the correctness backbone** — its unique value is long-lived
  sessions, agents that bypass workflow gates, and surfacing "N behind" info.
  That is still worth building (agents DO bypass gates), but set expectations.
- Confidence: HIGH for the safety model; ⚠️ emerging for necessity given L1+L3.

### L3 — update branch onto `origin/main` before PR
**Verdict: standard practice, with a rebase-vs-merge nuance.**
- OSSF SCM best practices explicitly recommend the GitHub branch-protection
  rule "Require branches to be up to date before merging". GitHub's Update
  branch feature offers rebase for linear history. GitHub docs: merge the base
  into the topic branch frequently.
- Rebase-vs-merge: merge preferred for multi-author shared branches (history
  rewrite hazard); agent branches are single-author and squash-merged →
  rebase is safe and keeps history linear. Git docs warn against rebase on
  published multi-owner history — does not apply here.
- Autostash is NOT conflict-safe for automation (sources agree) → require
  clean tree, warn otherwise. The proposal already does this.
- **GPG signing hazard (research-review fold):** with `commit.gpgsign=true`,
  rebase re-signs every rewritten commit — pinentry prompts/hangs in headless
  agent sessions. L3 must run `git -c commit.gpgsign=false pull --rebase
  origin main` (fleet signing config should be verified at implementation).
- Confidence: HIGH.

### Cross-cutting practices (agent fleets)
- One worktree per parallel agent is the dominant pattern (boundaryml, nx.dev,
  understandingdata, vibereference) — matches our using-git-worktrees skill.
  Ambient pull must NEVER touch feature-branch worktrees (proposal complies).
- Delete stale worktrees aggressively.
- Detect the default branch via `git symbolic-ref refs/remotes/origin/HEAD` —
  do not hardcode `main` (some repos use `master`).
- `git config --global pull.ff only` is a widely recommended machine-level
  guard (git ≥2.34 defaults lean ff-only, but explicit config makes unsafe
  pulls impossible everywhere, including manual agent shell-outs).
- Submodules: a superproject pull leaves submodules stale unless recursed —
  report-only, don't recurse (none of the current fleet repos use them).
- Lock contention: background fetch vs concurrent git write is rare; standard
  mitigation = timeout + silent failure (auto-sync pattern). Fleet scar tissue
  corroborates: commit-workflow 02-commit-pr.md documents orphaned index.lock
  incidents from killed pre-commit hooks — the index.lock guard stays, and a
  background pull hitting a hook-held lock simply fails silently (benign).
- **Filesystem watchers (research-review fold):** an ff-pull on a clean tree
  still mutates working files when incoming commits touch them — dev-server
  watchers (vite/metro/nodemon; DMeer, eldato) can cascade rebuilds or crash.
  L2 guard: skip auto-pull when a dev-server/watcher is attached to the
  checkout (detect or configure), or accept-and-document per repo.
- **Fleet is plain-git (verified):** no `.gitmodules`, no LFS `.gitattributes`
  filters in any fleet repo — submodule/LFS staleness is report-only by
  design, not an active hazard.
- **pi extension timer constraint (research-review fold):** pi forbids
  starting timers/processes from the extension factory — L2's periodic fetch
  timer must start in `session_start` and clear in `session_shutdown`
  (extensions reload on session switch); feasible, same shape as
  task-heartbeat.ts (#176).

## Recommendation

Build all three layers, ordered by correctness value:
1. **L1** — fix issue-workflow Branch Gate to fetch + branch from
   `origin/main` (≈10-line skill edit; closes the stale-branch-creation class
   entirely; matches commit-workflow + worktree precedent).
2. **L3** — commit-workflow preflight freshness check: fetch, report N-behind,
   `git pull --rebase origin main` when clean, warn when dirty (no autostash).
   Optionally enable "require up to date" branch protection per repo.
3. **L2** — `repo-freshness` extension modeled on auto-sync.ts: session_start
   + ~20 min periodic fetch (timer started in session_start, cleared in
   session_shutdown per pi's extension rules); ff-only auto-pull on clean
   default branch (`AGENT_REPO_SYNC=auto|warn`, default auto); feature branches
   get report-only "N behind"; guards: dirty tree, MERGE_HEAD/REBASE_HEAD,
   index.lock, dev-server/watcher attached, offline/no-remote, print mode;
   default-branch detection via symbolic-ref; `git -c commit.gpgsign=false` on
   any rebase path.
4. **Zero-cost extra:** set `git config --global pull.ff only` fleet-wide.

## Open questions (human decision)

- L2 default mode: `auto` (pull on clean main without asking) vs `warn`
  (agent-infra's default). Recommend `auto` for work repos — ff-only + clean
  tree + git's own re-check make it safe, and agents can't respond to warnings
  anyway.
- Enable GitHub "require branches up to date before merging" on the fleet
  repos as a server-side backstop? (recommended yes)

## Source confidence summary

| Claim | Tier | Sources |
|---|---|---|
| Branch from fetched origin/main before feature work | High | Atlassian, asam-ev, Azure, GitHub + internal skills |
| fetch is safe / background fetch is standard | High | Atlassian, GitKraken, git-maintenance docs, SO |
| git maintenance prefetch doesn't update origin refs | High | git docs (2 corroborating summaries) |
| Auto-pull guards = documented pitfall mitigations | High | multi-source pull-pitfalls synthesis, git docs |
| Up-to-date-before-merge + rebase for single-author branches | High | OSSF, GitHub blog/docs, community discussion |
| Worktree-per-agent dominant for AI fleets | Medium | 4 practitioner sources (no formal studies) |
| L2 necessity given L1+L3 | ⚠️ emerging | adversarial analysis, single-line reasoning |

---

## Research Round 2 (2026-08-11, later) — the two open decisions

### Decision 1: L2 default mode — auto vs warn

**Interactive-tool consensus: auto-fetch YES, auto-pull NEVER-under-active-work.**
- JetBrains: explicit "Fetch remote changes automatically" option; update/pull
  is always an explicit user action (fetch vs update docs).
- VS Code: `git.autofetch` (fetch-only, periodic) — no auto-pull exists.
- Visual Studio docs: "fetch and pull before you push" — manual guidance.
- The anti-pattern is pulling under ACTIVE EDITING. L2's envelope excludes
  active work by construction: default branch only, clean tree, ff-only, no
  local-ahead commits, no merge/rebase in progress, no index.lock, feature
  branches report-only, agent work happens on feature branches/worktrees.
  The IDE analogy therefore does not transfer — the correct analogy is fleet
  management.

**Fleet-management practice (applies):**
- NCSC device guidance: automatic updates recommended WHEN SAFE, with
  verification that they actually applied.
- CrowdStrike lesson: never trust one update path blindly → observability +
  kill-switch + fail-open. Applied: L2 logs every auto-pull, keeps
  AGENT_REPO_FRESHNESS_DISABLED kill-switch, and fails open to warn on any
  anomaly (diverged/ahead/dirty/locked).

**Agent-orchestrator standard (fresh-base-at-task-start is canonical):**
- Claude Code worktrees: "branch from `origin/HEAD` so they start from a clean
  tree matching the remote"; fetch-refresh origin/HEAD if not fetched in 24h
  (≤5s), fallback to local HEAD on fetch failure — the exact L1 pattern with
  a staleness policy.
- Conductor (Melty Labs): per-task loop includes validate/commit/RESET before
  the next task. ComposioHQ agent-orchestrator, AgentWrapper: worktree-per-
  agent from the existing repo.
- Nobody ambient-pulls live agent worktrees — isolation + fresh base per task
  is the dominant pattern. L2 targets only the idle default branch of the
  primary checkout, which no agent edits by convention.

**Verdict: auto** — within the strictest safe envelope (above), with logging +
kill-switch + fail-open-to-warn. HIGH confidence (3 independent practice
families converge: IDE fetch-only policy maps to "never under active work";
fleet mgmt maps to "auto-apply when safe + verify + observable"; agent-tool
practice maps to "fresh base at task boundaries + ambient hygiene for idle
bases").

### Decision 2: "Require branches up to date before merging"

- **OpenSSF SCM best practices explicitly recommend it** — rationale: without
  it, "previously fixed issues [can] slip back in" when the base moved. This
  is precisely the fleet's regression class.
- GitHub docs: strict mode = PR must be current; costs more check runs. Merge
  queue provides the same benefits without manual update-and-wait — designed
  for BUSY branches.
- Criticism (GitHub community #7399, SO): merge-ladder friction on busy repos
  (someone merges first → you update + re-run checks), redundant when base
  changes don't touch the PR, rebase/force-push noise.
- Fleet reality: low-throughput repos (few PRs/day, mostly agent-generated,
  single owner). Ladder friction is negligible; the OpenSSF regression
  protection is exactly what's being paid for. Strict mode also raises L3's
  value: agents reconcile locally pre-PR, so they rarely hit the ladder.

**Verdict: YES — enable strict up-to-date on fleet repos.** Merge queue is the
high-throughput alternative; overkill at fleet volumes. HIGH confidence
(OpenSSF recommendation + GitHub docs + throughput analysis).

---

## Research Round 3 (2026-08-11) — adversarial confirmation verdict

Fresh-session adversarial verifier (empirical testing in throwaway repos +
fleet probe): **all four practices confirmed good**, with 3 gaps folded into
the scope:

1. **L1 VERIFIED clean** — issue-workflow Branch Gate confirmed fetch-less
   outlier; both internal precedents verified verbatim; textbook against
   Atlassian/asam/Azure/GitHub guidance.
2. **L2 envelope VERIFIED mechanically** — ff-pull on clean tree: post-merge
   hook does NOT fire on ff (tested); dirty tree → abort, edits preserved;
   untracked-file collision → abort, file preserved (fail-closed). Fleet
   probe: zero hooks, zero sparse-checkout, zero submodules, origin/HEAD=main
   everywhere. **P1 folded:** main-worktree-guard interaction — the guard
   intercepts bash-tool git in main checkouts; L2 runs extension-level
   (bypass by construction). Carve-out documented with ratified precedent
   (auto-sync.ts) + observability (per-pull log line) + kill-switch.
3. **L3 VERIFIED** — gpgsign bypass is process-scoped, harmless today (fleet
   has gpgsign unset), needed where set (headless pinentry hangs); squash-
   merge fleet means re-signed/unsigned rebased commits carry no post-merge
   integrity value. No weakening.
4. **Decision 2 upheld with mandatory recovery** — small-team friction
   critique rebutted (agents pay zero rebase cost; L3 automates it; OpenSSF
   recommendation), BUT the residual ladder case (merge lands between rebase
   and merge) had no recovery path anywhere in commit-workflow → L3 stale-
   merge recovery step added (fetch → rebase → checks → push
   --force-with-lease → retry) as a MANDATORY companion to strict mode.
   Monitor-and-downgrade escape hatch recorded.
5. **P2 folded** — unsaved editor buffers are undetectable from git
   (watcher-hazard class): accept-and-document per repo, per-repo warn mode
   available.

**Final verdict: PROCEED — practices confirmed good with the folded guards.**
