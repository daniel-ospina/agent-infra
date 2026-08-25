<!-- research-path: none (no external research — root cause pinned in extensions/verification-gate/index.ts + live repros cited in #204 and the scoping comments) -->

# fix(verification-gate): scope `gh pr merge` verification to the PR's own diff — skip cross-repo and same-repo stale-checkout misfires (#204)

**Goal:** Stop the verification-gate from blocking `gh pr merge` on files that have nothing to do with the PR being merged. On a stale/drifted checkout (orchestrator session on an old branch, or a cwd that is a different repo than the PR), the gate's "unverified files" scan currently computes `git diff origin/main...HEAD --name-only` in the session's cwd and misattributes that branch residue to the merge. Observed 2026-08-12: 14 unrelated files blocked an admin merge of swarm PR #983; the scoping investigation reproduced it live (agent-infra PR #211 merged from the swarm cwd blocked on ~50 swarm drift files). Workaround today: run the merge from the PR's own clean worktree.

**Team:** organisation-design-team
**Status:** PLANNED — scoping complete (2026-08-13 follow-up on #204); awaiting implementation

---

## Problem Statement

For any git op the gate detects (`git commit|push` → staged diff; `gh pr create|merge` → branch diff):

```ts
if (GH_PR_PATTERN.test(command)) {
  changedFiles = computeBranchDiff(cwd);   // git diff origin/main...HEAD --name-only
} else {
  changedFiles = computeStagedDiff(cwd);   // git diff --cached --name-only
}
```

`cwd` is the resolved git root of the session's shell (`cdPath ?? inputCwd`), not the PR. `gh pr merge` merges **remotely** — the local checkout's `origin/main...HEAD` diff is only meaningful when (a) the cwd repo IS the PR's repo AND (b) the checkout is on the PR head branch. In orchestrator flows both premises break:

1. **Cross-repo merge** (observed): a session in repo A runs `gh pr merge <n>` (possibly with `--repo owner/B` or `GH_REPO=`) for a PR in repo B → the gate verifies repo A's branch drift, not the PR.
2. **Same-repo stale/old-branch checkout**: cwd is the PR's repo but the checkout sits on an old branch with unmerged residue → `computeBranchDiff(cwd)` returns that branch's files, which the remote merge never touches.

The result is a false block, a wasteful verifier sub-agent dispatch, and (per #190 bridge recovery) the drift files get blessed into the persistent bridge once verified — contaminating later sessions in the same worktree root. The 3-attempt auto-bypass eventually lets the merge through, but only after noise and delay; the issue's AC requires no workaround.

## Design (planned for `extensions/verification-gate/index.ts`)

### 1. Repo resolution (network-free)

Resolve the PR's repo in priority order, mirroring `extensions/review-enforcer/index.ts` (which already solved this for its own merge gate):

- `--repo owner/name` / `-R` flag → `extractRepoFlag(command)` (exists in review-enforcer)
- `GH_REPO=owner/name` env assignment → `extractGhRepoEnv(command)` (exists in review-enforcer)
- Neither → gh targets the cwd repo **by construction** → same-repo path

Cwd repo identity: parse owner/name from `git remote get-url origin` (SSH `git@github.com:o/n.git` and HTTPS `https://github.com/o/n.git` patterns); on parse failure treat as same-repo (fail-closed). Reuse the review-enforcer helpers via one-way import (`../review-enforcer/index.js` — no cycle; review-enforcer does not import verification-gate). If pi's extension loader forbids cross-extension imports (the #5611 ponytail note), copy the two regex helpers locally (rule of two).

### 2. Pure decision — `evaluateMergeScope(cwdRepo, explicitRepo, localHead, prHead)`

Testable pure function (review-enforcer `evaluateMergeGate` style), returning `{ verify: boolean, reason }`:

| explicitRepo | localHead vs prHead | action |
|---|---|---|
| ≠ cwdRepo | — | **skip** (`cross_repo`) — nothing local represents the PR |
| = cwdRepo (or none) | == (worktree merge) | **verify** — `computeBranchDiff(cwd)` unchanged (no regression) |
| = cwdRepo (or none) | ≠ | **skip** (`head_mismatch`) — local branch residue is unrelated |
| = cwdRepo (or none) | prHead unknown (gh/network failed) | **verify** — status quo, fail-closed |

The PR head is fetched only on the same-repo path: `gh pr view <n> --json headRefOid --jq .headRefOid` run **with cwd** (gh resolves the repo from the local remote; no `--repo` needed) — same call shape as review-enforcer's `getPrHeadSha`. The skip path returns `undefined` from the hook **before** `computeBranchDiff`, so no changedFiles, no block, no verifiedSet/bridge writes — stale-checkout residue can never contaminate the registry or the bridge.

### 3. Audit parity

`appendJsonl({ event: "gate_skip", extension: "verification-gate", reason: "cross_repo" | "head_mismatch", ... })` on each skip, mirroring `gate_bypass` / `gate_recovery` (#190) / `merge_gate_pass` — a skipped verification leaves a durable record.

### 4. Untouched

- `git commit|push` staged-diff path — unchanged (AC: genuine new uncommitted files still block as today).
- `gh pr create` — branch diff is correct there (the PR is created from this branch); unchanged.
- #190/#214 verifier-PASS merge side (`resolveMergeRoot`/`scopeFiles`/bridge recovery) — unchanged; recovery still runs before each git op (root-filtered + match-or-drop). The fix removes the misfire at its source (file-set computation), so those paths never see drift files.

## Wiring

| Component | File | Change |
|---|---|---|
| Repo resolution | `extensions/verification-gate/index.ts` | `extractRepoFlag`/`extractGhRepoEnv` (import or copy from review-enforcer) + `repoNameFromRemote(url)` helper |
| Decision | `extensions/verification-gate/index.ts` | pure `evaluateMergeScope(cwdRepo, explicitRepo, localHead, prHead)` (exported) |
| Hook | `extensions/verification-gate/index.ts` tool_call `GH_PR_PATTERN` branch | same-repo: fetch PR head (cwd) → decide; skip → `undefined` + `gate_skip` audit; cross-repo: skip before `computeBranchDiff` |
| Tests | `extensions/verification-gate/index.test.ts` | unit: repo-priority resolution, `repoNameFromRemote` URL forms (SSH/HTTPS), `evaluateMergeScope` 4-combo table |
| Tests | `extensions/verification-gate/index.e2e.test.ts` | e2e: cross-repo skip (network-free), same-repo head-check-fail → status-quo block |
| Docs | `extensions/verification-gate/index.ts` header comment | cross-repo / same-repo-stale merge behavior documented |

## Verification

- `npx tsx extensions/verification-gate/index.test.ts` — existing 70+ asserts + new units, all pass.
- `npx tsx extensions/verification-gate/index.e2e.test.ts` — existing scenarios 1–18 + new merge scenarios:
  - **cross-repo skip:** temp repo with `origin` remote pointing at a different owner/name + drift on HEAD; `gh pr merge 123 --repo other/owner` → `undefined` (no block, no dispatch). Network-free.
  - **same-repo status quo (fail-closed):** temp repo with matching origin, drift ref (`git update-ref refs/remotes/origin/main <base>`), `gh pr merge 123` (no flag) → head check fails (no network) → `computeBranchDiff` → block on drift file, as today.
  - Head-match/head-mismatch combos covered at unit level (decision is pure); a gh-stubbed e2e (execSync override) is optional hardening.
- Manual: merge a PR from an unrelated cwd → one `gate_skip` audit line, no block; merge from the PR's own worktree → unchanged behavior.
- Review: fresh-context reviewer per the scoping skill's mandatory review loop before implementation ships.

## Risks

- **gh head-check latency/availability** on the same-repo path: one extra gh call per merge; failure fails closed to status quo, so no new block and no new allow beyond today.
- **Cross-extension import** (verification-gate → review-enforcer): if pi's extension loader rejects it, fall back to local copies of the two regex helpers — behavior identical.
- **Behavior change scope**: same-repo merges from a non-PR-head branch move from "blocked on residue" to "skipped" — intended; the review-enforcer registry gate (review record + head-sha match) still gates every merge, so no merge becomes un-gated.
- **Origin remote parse edge cases** (forks, non-GitHub hosts, missing remote): parse failure → same-repo path (fail-closed), never an accidental skip.
