---
title: "Issue #265 — shared-checkout branch-ownership sentinel: baseline, M1/M2/M3 gates, auto-sync lock, env pivot"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-13
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-265, main-worktree-guard, auto-sync, builtin-tools
---

<!-- research-path: docs/research/2026-08-13-shared-checkout-branch-isolation.md (#265) -->

# fix(extensions): shared-checkout branch-ownership sentinel (#265)

**Team:** organisation-design-team
**Status:** APPROVED — 3 verifier cycles (2 scope → 14 findings folded; 2 plan → 11 findings folded; re-review clean).

## Problem statement

The agent-infra shared checkout is a multi-actor resource with **no per-session branch
ownership**: branch state mutates under live sessions via (a) auto-sync's
session_start force-switch (`tryLosslessRecover` — extension-level `execSync`, invisible
to tool-call hooks), (b) unguarded branch-switching in the shared tree (the guard exempts
agent-infra entirely, #99; task sub-agents inherit the `AGENT_ALLOW_MAIN_EDITS=1` escape
hatch by default, `extensions/builtin-tools/index.ts:1660-1661`; swarm daemon sets it
externally, `~/swarm/.../swarm_daemon.py:98`), and (c) branch identity asserted only at
work-start (issue-workflow Branch Gate, `skills/issue-workflow/SKILL.md:139-193`), never
at commit time — a TOCTOU gap. Result: cross-session branch/commit contamination
(incidents a/b/c) and stale-content reviews.

**Canonical bypass list (7, empirically verified 2026-08-13 — all classify `allow` today):**
`git -C <path> checkout`, `git -c k=v checkout`, `git checkout --orphan <b>`,
`git symbolic-ref HEAD refs/heads/x`, `git update-ref refs/heads/x HEAD`,
`git branch -f x main`, `git switch -c feat/x`. (Note: `git --git-dir=/p/.git checkout`
today FALSE-POSITIVES to `block:checkout-branch` because `\bgit\b` matches the `.git`
inside the path string; the T3 skimmer normalizes it to a genuine block either way.
`git branch -m/-M` (rename) is a further unclassed state-mutation — added in T3.
`gh pr checkout <N>` and script-wrapped git are DOCUMENTED fail-open (see Risks) — M1/M2
are the backstop; a gh matcher is a possible follow-up, not v1.)

Detection alone is unfalsifiable; commit-time ownership assertion + actor isolation are
required.

## Chosen approach — A (extension-layer branch-ownership sentinel) + co-requisites

**A-core** (extension layer, invisible-to-hooks-proof — the only layer that sees auto-sync's
execSync): per-session baseline `{repoKey, branch, head}` recorded at session_start (incl.
print mode), M1 warn on branch deviation, M2 block on commit/push off-baseline (worktree-
exempt), M3 gate on branch-state mutations with a create-new carve-out for agent-infra,
auto-sync recovery serialized by an O_EXCL pid-lock with TTL + stale-steal, task-sub-agent
env pivot.

**B-co-requisite (same PR, narrowed):** issue-workflow Branch Gate goes worktree-first for
non-infra repos (primary sessions AND write-capable sub-agent dispatches — enforced, not
advisory); agent-infra keeps its in-main `checkout -b` (liveness: extensions/skills load
from the main checkout via the `~/.pi/agent` symlink farm, `pi-bootstrap/setup.sh:144-176`)
now made legal by the M3 create-new carve-out; commit-workflow's own-branch hygiene ops get
an ownership-aware allowance so the agent-infra commit pipeline is not false-blocked.

**C-sliver (documented backstop, not implemented):** server-side branch protection would
close the non-pi-actor hole (humans in terminals, external daemons). Out of scope for v1.

**Deviations from diverge summary (with rationale):**
1. Lock + baseline + DECISION LAYER live in a NEW `extensions/shared/branch-ownership.mjs`,
   not in `classify-git.mjs` — `extensions/shared/` is the sanctioned cross-extension home
   (print-mode.ts precedent, #228); it keeps classify-git pure-classification, avoids
   auto-sync → main-worktree-guard directory coupling, and stays plain-node testable.
   **The M1/M2/M3/ownership DECISIONS are pure functions here too** (verifier fold-in: ACs
   1/2/3/6 require unit-testable decisions — handler-embedded logic is untestable).
2. commit-workflow mitigation = ownership-aware allowance for the session's OWN baseline
   branch, in addition to the worktree-first branch gate. Pure worktree-first for
   agent-infra breaks infra edit-liveness (the entire reason for #99's write exemption).
3. **M1 semantics (verifier fold-in):** M1 warns ONLY on BRANCH deviation
   (current branch != baseline branch). HEAD advancement on the same branch (own commits,
   rebase, pull, auto-sync ff) is NORMAL and never warns — a static-HEAD baseline would
   fire a spurious warning after every self-commit, drowning the real signal (stale-review
   hazard AC8 exists to prevent).
4. **M2 is worktree-exempt (verifier fold-in):** repoKey is git-common-dir identity, which
   main + its worktrees SHARE. M2 therefore resolves the EFFECTIVE repo of the command
   and allows when `isWorktreeCwd(effectiveCwd)` — otherwise the worktree-first flow (AC5)
   would false-block at the first commit inside `.worktrees/feat-N/`.
5. **Load-order race (verifier fold-in, resolved by design):** pi's extension loader
   iterates `readdir` unsorted — the guard's baseline record and auto-sync's recovery both
   run at session_start in nondeterministic order. Under the shared lock BOTH orders are
   safe by construction: guard-first → baseline=feat/X, auto-sync force-switch → M1 warns
   feat/X→main, M2 blocks the first commit, session recovers via the M3 create-new
   carve-out (checkout -b → re-baseline) — exactly the anti-contamination behavior the
   issue demands; auto-sync-first → baseline records post-recovery main, session owns main,
   silent. No code depends on order.
6. **Marker/flag contract (verifier fold-in, explicit):** under the TTL marker (#207) or
   `AGENT/ELDATO_ALLOW_MAIN_EDITS=1`: **M1 stays ACTIVE** (cheap detection — swarm-style
   spawns under the external flag still get warned), **M2/M3 are INACTIVE** (the escape
   hatch keeps its documented semantics — a stranded main checkout must remain recoverable
   by a deliberate solo session, which requires `git checkout main`; narrowing it would
   break #207's purpose). Both matrix cells tested (T4).
7. **Ownership-allowance predicate split (verifier fold-in, cycle 2):** for
   `pull --rebase` / `rebase` / `merge origin/<default>` the command names the REMOTE
   default, never the local baseline branch — the allowance gate for these is
   `current branch == baseline branch` AND the sync source resolves to the repo default.
   For `push` / `push --delete` / `branch -D` the gate is `every named target == baseline
   branch` (all-targets — a single `git push origin --delete a b` must not slip a foreign
   delete past the retained #73 check).
8. **Commit atomicity (verifier fold-in, cycle 2):** the classifier return-shape change,
   its test updates, AND the guard-index rewrite land in ONE commit (T3+T4+T5) —
   `classifyGitCommand` keeps its string verdict (back-compat) and a new
   `classifyGitCommandDetailed` returns the object; no broken intermediate state, no
   `verdict.startsWith` crash, no unintended `block:commit` hard-block window.

## Architecture

```
extensions/shared/branch-ownership.mjs   (NEW, pure JS, plain-node testable)
  repoKey(cwd)                    → git-common-dir/toplevel identity (NOT basename)
  acquireRepoLock(key,pid)        → O_EXCL pidfile holding {pid, startedAt} + stale-steal
                                    (pid dead OR age > MAX_LOCK_AGE=10min — pid-reuse
                                    hole closed), retries, timeout; SAME-PID re-acquire is
                                    re-entrant success (owner pid == self → held by self);
                                    file: ~/.pi/agent/locks/<sha1(key)>.lock
  releaseRepoLock(key,pid)        → no-op if not owner; SILENT on clean path (auto-sync
                                    test asserts zero output on "current → silent")
  readBranchState(repo)           → {branch|null-if-detached, head} — one git call
  classifyBranchOp(subcmd,args)   → create-new (with new branch name) | switch-existing
                                    | force | orphan | rename | other  (M3 pure classification)
  parseRefspecDst(refspec)        → dst branch for git push refspecs; empty refspec
                                    ("", "git push", "git push origin") → current branch
                                    (push.default=simple semantics — Stale-Merge Recovery
                                    pushes bare `git push --force-with-lease`)
  resolveEffectiveRepo(command, sessionCwd)   → {repoKey, gitDir, effectiveCwd, isWorktree, currentBranch}
                                    GIT-FAITHFUL (verifier fold-ins, cycle 3 — empirically
                                    verified against git 2.50.1):
                                      (1) cd-chain resolves to a final cwd (LAST cd wins,
                                          quote-masked); each -C <path> resolves RELATIVE
                                          to that final cwd, in order (multi -C chains
                                          relative to the previous);
                                      (2) gitDir = resolved --git-dir hint / GIT_DIR env
                                          (resolved against the FINAL cwd — git semantics:
                                          --git-dir and GIT_DIR are relative to the cwd
                                          after ALL -C chdirs, regardless of option order)
                                          else <finalCwd>/.git;
                                      (3) repoKey = git-common-dir of the RESOLVED gitDir;
                                          isWorktree = resolved gitDir path contains
                                          "/worktrees/" (git-faithful discriminator —
                                          classify-git.mjs getMainCheckoutBranch precedent;
                                          NEVER isWorktreeCwd(effectiveCwd): a -C <wt>
                                          --git-dir=<main>/.git command operates on the
                                          MAIN checkout and must NOT be exempted);
                                      (4) currentBranch read FROM THE RESOLVED REPO
                                          (git -C <wt> --git-dir=<main>/.git branch
                                          --show-current answers the main checkout), NOT
                                          from effectiveCwd;
                                      (5) fallback process.cwd() when no cd/-C/git-dir
  decideM1(currentBranch, baselineBranch)      → "warn" | null        (branch-ONLY)
  decideM2(effectiveRepo, baseline, currentBranch, pushDst, pushTargets, allowActive)
                                              → {block, reason} | null
  decideM3(opClass, isAgentInfraRepo, baseline, branchNames)
                                              → {block, reason, reBaseline?} | null
  ownershipAllowed(opKind, currentBranch, baselineBranch, targets[], syncSource)
                                              → bool  (predicate split, deviation 7)
  DEFAULT_LOCK_AGE_MS = 10*60_000

extensions/main-worktree-guard/classify-git.mjs   (EXTEND)
  skimGitGlobalFlags(command)     → {rest, repoHint, gitDirHint}: strips leading git
                                    global flags (-C <path> incl. quoted, -c k=v, --git-dir[=],
                                    --work-tree[=], --namespace, --no-pager, -p, ...) and
                                    GIT_DIR/GIT_WORK_TREE env prefixes; cd-prefix resolved
                                    quote-masked (verification-gate extractCdPath pattern)
  verb-anchored matchers on skimmed rest (so `git -c k=v checkout main` == `git checkout main`)
  new matchers: commit (verb == "commit"; EXCLUDES commit-graph/commit-tree),
                push (with parseRefspecDst; dst = baseline-compare target),
                branch-state (symbolic-ref HEAD / update-ref refs|HEAD / branch -f / branch -m|-M),
                force-push hygiene (--force-with-lease / --force-if-includes NOT force)
  checkout/switch subclassified for M3 (create-new vs switch-existing/-f/-B/--orphan)
  **classifyGitCommand keeps its STRING verdict** (back-compat, test.mjs unchanged for
    existing cases) + NEW classifyGitCommandDetailed → object
    { verdict, repoHint, gitDirHint, newBranch, pushDst, pushTargets: string[],
      isPushDelete, renameFrom, renameTo, syncSource }
  **block:push-delete verdict PRESERVED with pushTargets[] array** (all-targets routing —
    the #73 coordinated check keys off it; single pushDst is insufficient for multi-target)

extensions/main-worktree-guard/index.ts   (EXTEND — thin adapter over the decision layer)
  session_start: baseline record (main-checkout sessions only; under shared lock — RETRIES
                 bounded seconds (ceiling ~20s), never skips; fallback: record on first
                 tool_call BEFORE that tool_call's guard evaluation if the lock was
                 unavailable; print mode INCLUDED — keyed by process.pid — SessionStartEvent
                 carries no sessionId; one pi process == one session);
                 hub-discipline check rehomed here (interactive-only !isPrintMode() — a
                 DELIBERATE sub-agent-noise fix: today print-mode sub-agents DO receive the
                 box on non-main/dirty main checkouts (no isPrintMode gate at index.ts ~278,
                 the check currently runs at EXTENSION-INIT as the last block inside the
                 export default function body, i.e. before any session_start handler —
                 rehoming into session_start moves it after auto-sync's recovery, benign:
                 warn-only; stranded trees are clean) — AND !_isAllowMainEdits(); agent-infra
                 downgraded to a DIRTY-TREE-ONLY one-liner — branch deviation is the norm in
                 agent-infra main; detached-HEAD warn)
  M1: on EVERY tool_call (all tool types) — sessions with a baseline, cwd is the baseline
      repo's MAIN checkout: if current branch != baseline branch → warn ONCE per
      (pid, deviation), deduped; branch == baseline → silent (HEAD re-adopt implicit);
      ACTIVE under allow-marker AND env flag AND print mode
  M2: bash commit/push — resolveEffectiveRepo; isWorktree → ALLOW; else if repoKey ==
      baseline AND baseline exists: (commit: current branch != baseline branch; push:
      parseRefspecDst != baseline branch — bare push compares current branch) → block
  M3: branch-state verbs — main checkout (resolved, target-aware): create-new
      (checkout -b / switch -c) allowed in agent-infra main ONLY → pending re-baseline
      (verified on next tool_call: current branch must equal the created branch; else M1
      path); rename of session's own baseline branch (branch -m/-M) → re-baseline;
      ALL other branch-state (switch-to-existing, -f, -B, --orphan, checkout -,
      symbolic-ref/update-ref/branch -f) blocked in ANY main checkout; worktree targets
      allowed; agent-infra blanket exemption REMOVED (write/edit exemption #99 retained)
  ownership allowance (agent-infra main only; predicate split per deviation 7):
      pull --rebase / rebase / merge origin/<default> → current branch == baseline branch
        AND syncSource resolves to origin/<default>|/<default>
      push / push --force-with-lease / push --force → ALL refspec src+dst targets
        (pushTargets[]) == baseline branch — all-targets semantics symmetric with delete
        (a multi-refspec `git push origin feat/1 other/2` must NOT slip a foreign target
        past the gate; single pushDst is insufficient for multi-refspec)
      push --delete / branch -D → EVERY pushTargets[]/named branch == baseline branch
        (else fall through to the retained #73 coordinated check for foreign branches)
  push-delete coordinated check (#73) retained for OTHER sessions' branches; degradation
    contract (see Risks): classify-git failure → bash warn-only; branch-ownership failure →
    M1/M2/M3 OFF + one-time console.warn; write/edit NEVER depends on either module and
    stays enforced (isWorktreeCwd defaults SPLIT: bash path fail-open () => true, write/edit
    path fail-closed () => false — fixes today's latent fail-open at index.ts:34/216)

extensions/auto-sync.ts + ./sync.sh   (EXTEND)
  session_start: acquire repo lock (key = AGENT_INFRA_PATH repoKey) ONCE, before ANY
      mutation (recovery AND sync.sh run); pass held state into tryLosslessRecover (no
      internal re-acquire when held — same-pid self-contention must never skip recovery);
      release after; skip-with-warn under FOREIGN contention only
  tryLosslessRecover(repo, opts?): acquires internally when not held (direct-call tests);
      re-verify syncState + lossless checks AFTER lock acquisition before checkout -f;
      no rmSync based on pre-lock state — each untracked file re-checked (exists +
      byte-identical to origin/main) immediately before removal; hold lock across
      rm+checkout+merge; bail if anything changed
  sync.sh (verifier fold-in, cycle 3): refuse to pull when the checkout is NOT on
      main — `[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ] && echo "skip" && exit 0` —
      closing the FF-move hazard (a behind feature branch's ref silently becomes
      origin/main tip, name unchanged → M1/M2 silent by branch-only design). The stranded-
      branch case is already handled by tryLosslessRecover (#203) under the lock
  residual (documented, honest justification): the lock prevents double-recovery
      interleave + gives auto-sync a skip-under-contention signal — it does NOT close
      incident 3 for a LIVE non-holder session (writes during rm+checkout still race;
      live sessions never take the lock); the backstop for the live-session case is
      M1 warn + M2 block (matches indicator 1). No liveness probe in v1.

extensions/builtin-tools/index.ts   (ENV PIVOT)
  remove ELDATO_ALLOW_MAIN_EDITS / AGENT_ALLOW_MAIN_EDITS from subAgentEnv (:1660-1661);
  keep SKILL_ENFORCER_DISABLED=1 (skill-enforcer already bypassed for sub-agents)
```

## Implementation tasks (ordered, with dependencies)

| # | Task | Files | Depends on |
|---|---|---|---|
| T1 | Shared module: `repoKey`, `acquireRepoLock`/`releaseRepoLock` (O_EXCL + {pid,startedAt} + stale-steal pid-dead-OR-age>10min + retries + timeout + SAME-PID re-entrant + steal-warn + SILENT clean path), `readBranchState`, `classifyBranchOp` (incl. rename), `parseRefspecDst` (empty → current branch), `resolveEffectiveRepo` (git-faithful), `decideM1/decideM2/decideM3/ownershipAllowed` | `extensions/shared/branch-ownership.mjs` (NEW) | — |
| T2 | Lock + keying + classification + DECISION tests: lifecycle (acquire/release/stale-steal incl. age-based + same-pid re-entrant), contention (second process), repoKey stability (main checkout vs its worktree → same key; same basename different paths → different keys), refspec matrix (bare push, push origin, HEAD:refs/heads/other, empty, NO-COLON `push origin feat/1` → dst=feat/1 under push.default=simple, multi-refspec `push origin feat/1 other/2` → both targets), branch-op matrix (create-new/switch/-f/-B/--orphan/rename/symbolic-ref/update-ref/branch -f), resolveEffectiveRepo matrix (compound cd chains, -C-relative-to-cd, --git-dir precedence incl. `-C <wt> --git-dir=<main>/.git` → isWorktree=FALSE + currentBranch=main-checkout's, `-C <main> --git-dir=<wt>/.git` → isWorktree=TRUE, GIT_DIR env), decideM2 worktree-exemption, decideM3 carve-out + rename, ownershipAllowed predicate split (incl. all-targets force-push) | `extensions/shared/test-branch-ownership.mjs` (NEW — filename MUST start with `test`: CI glob is `extensions/*/test*.mjs`, verified ci-main.yml:31; `*.test.mjs` would silently never run) | T1 |
| T3 | Classifier hardening: `skimGitGlobalFlags`, verb-anchored matchers, commit matcher (commit-graph/commit-tree excluded), push + refspec dst + pushTargets[] + isPushDelete, branch-state matchers (incl. branch -m/-M), force-push hygiene, M3 subclassification, `classifyGitCommandDetailed` object export (STRING verdict kept for back-compat) | `extensions/main-worktree-guard/classify-git.mjs` | T1 |
| T4 | Guard test updates: skimmer matrix (quoted `-C`, `-c` chains, `--git-dir=`, GIT_DIR env, cd prefixes, compound cd chains), 7-bypass regression matrix (ALL now classed), commit/push hygiene (commit-graph/commit-tree NOT commit), refspec dst (bare push → current branch, no-colon form), force-with-lease exclusion, M3 matrix (incl. rename), marker/flag matrix cells (marker+agent-infra, marker+non-infra, flag+print), ceremony commands pass on own branch (`git -c commit.gpgsign=false pull --rebase origin main`, `git merge origin/main`, `git rebase origin/main`, bare `git push --force-with-lease`), multi-target push --delete all-targets routing (foreign target → #73 check fires), multi-refspec force-push all-targets, adversarial resolveEffectiveRepo rows (`-C <wt> --git-dir=<main>/.git checkout -f main` must BLOCK; `-C <main> --git-dir=<wt>/.git commit` must ALLOW), zero-M1-warn-after-carve-out (synchronous re-baseline), worktree-exemption test (main baseline → `cd .worktrees/x && git commit` must pass), load-failure test (branch-ownership import failure → M1/M2/M3 off, write/edit intact), existing suites adapted (note: `expect("add+commit", …, "allow")` — string verdict unchanged; detailed shape covers block:commit classification) | `extensions/main-worktree-guard/test.mjs` | T3 |
| T5 | Guard index: session_start baseline (lock-guarded RETRY, print-mode, pid-keyed, first-tool-call fallback), hub check rehome (interactive-only !isPrintMode() + !_isAllowMainEdits(), dirty-tree-only agent-infra variant, detached-HEAD warn), M1 all-tool_calls deduped (branch-only, marker/env/print-blind), M2 ownership block (worktree-exempt), M3 rules + pending re-baseline (incl. rename), ownership allowance (predicate split), target-aware repo resolution (resolveEffectiveRepo), remove agent-infra blanket exemption, degradation split (isWorktreeCwd defaults), branch-ownership try/catch import | `extensions/main-worktree-guard/index.ts` | T1, T3 |
| **C1** | **ONE atomic commit: T3 + T4 + T5 together** (classifier shape change + its tests + the guard rewrite land atomically — no broken intermediate state; deviation 8) | classify-git.mjs, test.mjs, index.ts | T1, T2 |
| T6 | auto-sync lock integration + lossless-recovery hardening (acquire-once-at-session_start + pass-held-state, internal acquire for direct calls, re-verify-under-lock, no pre-lock rmSync, skip-with-warn under FOREIGN contention, SILENT clean path) | `extensions/auto-sync.ts` | T1 |
| T7 | auto-sync concurrency tests (CAPTED to the lock's actual claims — cycle-3 fold-in): lock contention (second holder skips recovery with warn), stale-pid/age steal, same-pid re-entrant (recovery never self-skips), recovery-under-lock (re-verify path), sync.sh skip-on-non-main row, current-state silent (0 output lines asserted — lock ops log nothing on clean path); re-verify-bail covered by the existing single-actor pre-rm re-check (no spawned-holder machinery); preserve single-actor suite (already wired: ci-main.yml explicit `npx tsx extensions/auto-sync.test.ts`) | `extensions/auto-sync.test.ts`, `sync.sh` (no CI change needed) | T6 |
| T8 | Env pivot: remove the two allow-flags from subAgentEnv (the two-line subAgentEnv change folds into C1 — avoids an interim false-block window for non-infra sub-agents with no worktree-first gate yet; cycle-3 fold-in); update fixture comments (subagent-e2e-smoke.test.ts:72 SKIP_ENV + subagent-integration.test.ts:80 "All 5 skip env vars" → 4, flag now explicit-fixture-only); add absence-wiring assertion (subAgentEnv must NOT contain either flag) | `extensions/builtin-tools/index.ts`, `extensions/builtin-tools/subagent-integration.test.ts`, `extensions/builtin-tools/subagent-e2e-smoke.test.ts` | C1 |
| T9 | Skill updates: issue-workflow Branch Gate (worktree-first for non-infra primary sessions, record-first #195; agent-infra in-main `checkout -b` documented as M3-carve-out), commit-workflow (ownership allowance + worktree-first notes), epic-executor "No worktree needed. Skip isolation" → write-capable implementer sub-agents in non-infra repos MUST get a worktree cwd (read-only sub-agents exempt — guard only blocks write/edit/destructive-git), using-git-worktrees `:234/:270` (marker = solo path, M2/M3 inactive under marker but M1 stays active; sub-agents no longer inherit the hatch) | `skills/issue-workflow/SKILL.md`, `skills/commit-workflow/workflow/01-preflight.md`, `skills/commit-workflow/workflow/04-merge-deploy.md`, `skills/epic-executor/SKILL.md`, `skills/using-git-worktrees/SKILL.md` (brainstorming/carousel edits DROPPED as gold-plating — their escape-hatch advice remains correct as-is; decision recorded) | T5, T8 |
| T10 | Docs + review gate: commit plan + research docs as artifacts (research path fix ALREADY APPLIED — `./sync.sh:8`); CI wiring verified (glob + explicit tsx lines + skill-lint + typecheck — no changes needed); dispatch fresh-context plan reviewers to convergence; file any P2 fold-ins discovered | `docs/plans/2026-08-13-issue-265-shared-checkout-branch-ownership-plan.md`, `docs/research/2026-08-13-shared-checkout-branch-isolation.md` | all |

**Parallelization:** T1 + T8-fixture-comments in parallel; after T1 → T2, T3, T6 in parallel; C1 (T3+T4+T5+T8-env-line) after T1+T2; T7 after T6; T9 after C1; T10 continuous.

## Testing strategy

- **Unit (plain node):** `extensions/shared/test-branch-ownership.mjs` (T2) + extended
  `extensions/main-worktree-guard/test.mjs` (T4) — pure functions incl. the DECISION layer
  (decideM1/M2/M3/ownershipAllowed/resolveEffectiveRepo), real throwaway git repos
  (test.mjs precedent), no mocks. Both auto-globbed by CI (`extensions/*/test*.mjs`).
- **Behavioral (tsx, real repos):** extended `extensions/auto-sync.test.ts` (T7) —
  makeBareOrigin/makeClone harness (existing), concurrency via SPAWNED second lock holder.
- **Wiring:** subAgentEnv absence assertion (T8); CI glob + explicit tsx lines verified (T10).
- **Skill lint + typecheck:** node-ci.yml covers T9/.ts edits.
- **Manual scenario walkthrough (verification plan):**
  1. Two interactive sessions, agent-infra main: A on `feat/1`, B starts → B's auto-sync
     contends on the lock; with a live tree it must NOT force-switch; A's commit allowed.
  2. External `git checkout main` mid-session → next ANY tool_call emits exactly one M1
     warn; `git commit` blocked (M2); `git switch main` blocked (M3); `git checkout -b
     feat/2` allowed with re-baseline (agent-infra).
  3. Sub-agent spawn: `env` of the child lacks both allow-flags; sub-agent in a non-infra
     main checkout is blocked on write/edit + destructive git.
  4. Swarm-style spawn (`PI_MODE=print` + `AGENT_ALLOW_MAIN_EDITS=1`): baseline recorded,
     M1 fires on branch change (detection survives the external flag).

## Acceptance criteria (mapped to issue indicators + targets)

| # | Criterion (concrete, verifiable) | Maps to |
|---|---|---|
| AC1 | M1: main-checkout session on branch X; external switch to main; the next tool_call of ANY type emits exactly ONE deduped M1 warning naming X → main (decideM1 unit test + manual scenario 2). Own-branch commits/rebase/pull NEVER warn (branch-only — unit test) | Indicator 1 |
| AC2 | M2: with branch != baseline, bash `git commit -m x` and `git push origin main` both return `block:…`; on the baseline branch both pass; the SAME commands inside a worktree of the baseline repo pass (decideM2 + resolveEffectiveRepo unit tests); bare `git push` / `git push --force-with-lease` on the baseline branch pass (refspec-dst-empty + force-hygiene tests) | Indicator 1 |
| AC3 | M3: `git switch main`, `git checkout -f`, `git checkout -B`, `git checkout --orphan`, `git symbolic-ref HEAD refs/heads/x`, `git update-ref refs/heads/x HEAD`, `git branch -f x` all classed/blocked in any main checkout; `git checkout -b feat/N-new` allowed in agent-infra main and the baseline re-adopts `feat/N-new` SYNCHRONOUSLY (the next tool_call emits ZERO M1 warns — unit test); owner `git branch -m` re-adopts baseline synchronously (decideM3 unit tests) | Indicator 1 |
| AC4 | `subAgentEnv` no longer contains `AGENT_ALLOW_MAIN_EDITS` / `ELDATO_ALLOW_MAIN_EDITS` (wiring assertion); a sub-agent in a non-infra main checkout is blocked on write/edit + destructive git (integration test or manual scenario 3) | Indicator 2 |
| AC5 | issue-workflow Branch Gate creates a worktree for non-infra primary sessions AND write-capable sub-agent dispatches (record-first per #195); main checkout branch never leaves main in that flow; skill-lint green | Indicator 2 |
| AC6 | Two-session test: session A baseline X; tree switched to Y; A's commit/push blocked; A's own `checkout -b Z` + commit allowed; auto-sync under concurrent lock never force-switches a tree with live work (lock-contention test) | Indicator 3 |
| AC7 | All 7 verified classifier bypasses are classed (blocked or ownership-gated) — regression matrix in T4 | Target: no new contamination |
| AC8 | M1 fires on a `read`-type tool_call (review session whose tree moved mid-review sees the warn before proceeding) | Target: no stale-content reviews |
| AC9 | `git commit-graph write` and `git commit-tree HEAD` NOT classed as commit; `git push origin HEAD:refs/heads/other` blocked (refspec dst parse); `git push --force-with-lease` NOT force-blocked (ownership path); `git push --force` still blocked; lock filename derived from git-common-dir (same-basename repos get distinct locks); lock stale-steal via age works when pid is alive-but-recycled; same-pid re-acquire is re-entrant (auto-sync recovery never self-skips); print-mode sub-agent records pid-keyed baseline; auto-sync recovery re-verifies under lock | P2 fold-ins |
| AC10 | Full extension suite (existing guard/auto-sync/print-mode/builtin-tools) + skill-lint + typecheck green in CI; marker-TTL and push-delete behaviors unchanged; agent-infra merge ceremony (condition-5 merge, Step B push-delete/branch-D, Stale-Merge rebase+bare force-with-lease push) NOT false-blocked on the own baseline branch; multi-target `git push origin --delete a b` with a foreign `b` still hits the #73 coordinated check; multi-refspec `git push --force origin feat/1 other/2` with a foreign `other/2` is BLOCKED (all-targets); sync.sh NEVER pulls/FF-moves a non-main branch | Regression |

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Load-order race (auto-sync recovery vs guard baseline record — readdir order unsorted, verifier-confirmed) | Both orders safe by construction (design decision 5): guard-first → M1 warn + M2 block until carve-out re-baseline; auto-sync-first → baseline = post-recovery state. Shared lock serializes the mutations; baseline record under lock (RETRY, ceiling ~20s, then record-on-first-tool_call BEFORE that call's guard evaluation). NO order dependence in code |
| Transient git-read failure (readBranchState throws mid-recovery checkout) | FAIL-CLOSED for M2/M3: skip the tool_call guard evaluation → treat as block-warn (consistent with the write/edit fail-closed precedent at index.ts:34/216); M1 degrades to warn-only (never blocks reads) |
| sync.sh FF-move (pull --ff-only origin main while a feature branch is behind) | sync.sh refuses to pull when not on main (3 lines) — closes the silent FF axis; stranded-branch recovery stays with tryLosslessRecover (#203) under the lock |
| M1 on every tool_call adds git execSync latency | Single combined git call (`rev-parse --git-dir --abbrev-ref HEAD HEAD`); worktree/no-baseline sessions skip entirely; skip when deviation already warned |
| False blocks on legitimate commit-workflow ops | Ownership allowance with predicate split (deviation 7): own-branch `pull --rebase`/`rebase`/`merge origin/<default>`/`push` incl. `--force-with-lease`/`push --delete`/`branch -D`; force-push regex hygiene (`--force-with-lease` currently matches `--force\b` — verified false block today, surfaced by un-exemption) |
| Ownership-allowance predicate misreads the ceremony | Split predicate (deviation 7) tested with the EXACT ceremony commands in T4; current-branch==baseline is the gate for sync ops, all-targets==baseline for delete/push ops |
| Exotic git invocations evade the skimmer (aliases, `gh pr checkout`, script-wrapped git, `git --exec-path`, …) | Unknown verbs default to allow (fail-open classifier contract); `gh`/script-wrapped git DOCUMENTED fail-open — M1 still DETECTS the resulting branch change, M2 blocks the next off-baseline commit; server-side protection (C) is the backstop (out of scope) |
| Env pivot breaks sub-agents that legitimately touched main | Worktree-first gate (T9) covers write-capable dispatches in non-infra repos; agent-infra unaffected (fingerprint exemption retained for write/edit); read-only/reviewer sessions write nothing |
| auto-sync lock starvation (long recovery) | Timeout + skip-with-warn; never force-switch under contention (fail-safe: recovery is convenience, not correctness); SAME-PID re-acquire re-entrant so recovery never self-skips |
| Lock stale-steal pid-reuse hole (dead holder's pid recycled → lock looks live forever) | Lock file carries `{pid, startedAt}`; stale when pid dead OR age > 10 min; warn on steal; skip-with-warn under contention (closed — verifier fold-in) |
| Lock contention drops the guard's baseline → session unguarded | Guard session_start RETRIES (bounded seconds) instead of skipping; fallback: record baseline on first tool_call if the lock was unavailable; only auto-sync skip-with-warns (verifier fold-in) |
| branch-ownership module load failure silently disables the guard | try/catch-guarded import (classify-git pattern, index.ts:30-38): M1/M2/M3 OFF + one-time console.warn; write/edit guard NEVER depends on the module (isWorktreeCwd defaults split: bash fail-open, write/edit fail-closed) — fixes today's latent fail-open at index.ts:34/216 (verified) |
| Swarm daemon remains an external bypass (sets the flag itself) | M1 fires under the flag (detection); lock serializes its auto-sync contention; documented follow-up: strip the flag in swarm or adopt server-side protection |
| TTL marker is machine-global → cross-session exposure | Exposure bounded by 15-min TTL; M1 stays active under marker; M2/M3 inactive under marker (escape-hatch contract preserved, documented in T9); session-scoped markers = future work (out of scope) |
| M3 re-baseline race (pending window) | Verify created branch matches expectation before adopting baseline; mismatch routes to the M1 warn path |
| classify-git load failure | Bash guard warn-only (existing); write/edit unaffected (isWorktreeCwd default for write path is fail-closed `() => false`); classify-git try/catch import at index.ts:44-50 (not :30-38 — cycle-3 citation fix) |

## Runtime prerequisites

- `AGENT_INFRA_PATH` set (guard/auto-sync already require it; `echo $AGENT_INFRA_PATH`).
- git ≥ 2.x (rev-parse features already in use). No new npm dependencies (pure node).
- Lock dir `~/.pi/agent/locks/` created on demand; cleanup on release + stale-steal.

## Out of scope

- Full spawn-time worktree enforcement for every session incl. agent-infra (approach B —
  blocked by the symlink-loader constraint, edit-liveness break, 47-way teardown; direction,
  not v1).
- Server-side branch protection implementation (approach C beyond documentation; closes the
  non-pi-actor hole — future issue).
- `gh pr checkout` / script-wrapped git matchers (documented fail-open; M1/M2 backstop; a gh
  matcher is a follow-up).
- Daemon-mediated serialization (D), virtual branches (GitButler-style), git hooks
  (`--no-verify` bypass), ownership/branch registries (prior research: rejected — the O_EXCL
  pidfile is a mutation MUTEX, not an ownership registry).
- Same-branch collisions between two worktrees; detached-HEAD workflows beyond the M1 warn;
  swarm daemon code (external repo `~/swarm` — follow-up issue).
