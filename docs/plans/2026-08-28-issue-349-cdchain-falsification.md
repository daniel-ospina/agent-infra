---
title: "Plan: #349 worktree-exemption falsification + regression tests"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-349, main-worktree-guard
---

<!-- research-path: none (no external research — falsification evidence in #349: probes on e0bf46f + main, both `allowed`; audit-log timeline) -->

# Issue #349 — #347 Worktree Exemption Fires for `cd <worktree> && git …` — Falsification + Regression Tests

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Prove (in code and in the issue record) that the #347 M4 worktree-target exemption already fires for the standard `cd <worktree> && git …` invocation form, and add the regression tests the issue mandates — with no production code change.

**Team:** organisation-design-team

**Architecture:** The bug report #349 is falsified by direct probe of the deployed commit (e0bf46f) and of `main`: `allGitInvocations`/`_walkShell` extract the `cd` target into `cdChain`, and `resolveInvocationTarget` resolves it to `isWorktree: true`, so `evaluateHubGateWithTargets('cd <abs-wt> && git add -A', …)` returns `allowed` on a dirty hub. The issue's evidence — `resolveInvocationTarget({cmd, args}, hub)` → `isWorktree: false` — came from calling the function with the wrong input shape (it consumes the allGitInvocations invocation object `{cdChain, cHints, gitDirHint, workTreeHint, indexFileHint, objDirsHint}`; there is no `cmd` field), so the result was the trivially-expected empty-chain fallback to the hub, not evidence of a parsing bug. The remaining real gap is the issue's Target 3: test.mjs has no `git add` m4t case and no relative-`cd` m4t case. This plan adds those regression cases (pinning the incident's exact command forms and the correct invocation-object contract), and records the falsification in the issue.

### Pattern Research

Skipped — plan touches zero third-party dependencies (pure additions to an existing Node test file, `test.mjs`, exercising existing in-repo parser logic).

### Integration Surface Map

Skipped — no integration boundaries: no DB, API, auth, external services, UI, or cross-cutting concerns. The change is test-only within `extensions/main-worktree-guard/test.mjs`.

### Journey Test Map

Skipped — no user-facing journeys (infrastructure guard, no UI).

### Failure Modes

- A future triager re-probes `resolveInvocationTarget` with `{cmd, args}` and "discovers" `isWorktree: false` again → **Expected:** the new negative contract-pin test + inline comment document that this probe shape is NOT the invocation contract, so the result is expected, not evidence of a bug.
- The exact incident command form (`cd <abs-wt> && git add -A`) regresses → **Expected:** the new m4t case `T1b` fails.

**Tech Stack:** Node (test.mjs, classify-git.mjs — no new deps).

---

### Task 1: Add the #349 regression cases + probe-shape contract pin to test.mjs

**Intent:** Satisfy issue #349's Targets — test.mjs must cover the exact incident command forms (`cd <abs-worktree> && git add`, `cd <rel-worktree> && git commit`) that the issue claims are uncovered, and pin the correct `resolveInvocationTarget` input contract so the misdiagnosis cannot recur.
**Acceptance:**
- test.mjs contains m4t cases: `cd "${wtR}" && git add -A` → allowed; `git -C "${wtR}" add -A` → allowed; `cd ../wt && git add -A` → allowed; `cd ../wt && git commit -m x` → allowed; `cd "${hubR}/.worktrees/n" && git add -A` → allowed (nested wt-inside-hub — the incident's exact geometry, P3 fold-in).
- test.mjs contains an `expectBool` contract pin: `resolveInvocationTarget({cmd: '…', args: […]}, hubR, hubR)` → `isWorktree === false` (the `{cmd,args}` probe shape is NOT the invocation contract) with a comment referencing #349.
- `classify-git.mjs` resolveInvocationTarget JSDoc gains a one-line input-contract clarification (comment-only; no logic change).
- Full suite stays green (all existing + new cases pass).
- No LOGIC changes to `classify-git.mjs`, `index.ts`, or `branch-ownership.mjs`.

**Files:**
- Modify: `extensions/main-worktree-guard/test.mjs` (m4t block after the T1 case; nested-worktree fixture provisioning in the m4Tmp try block; contract pin after the existing `observable:` assertions)
- Modify: `extensions/main-worktree-guard/classify-git.mjs` (JSDoc input-contract note on `resolveInvocationTarget`, comment-only)

**Step 1: Add the m4t regression cases directly after T1**

In `extensions/main-worktree-guard/test.mjs`, in the `#347: M4 worktree-target exemption` m4t block, immediately after the `T1` case:

```js
m4t("T1: cd wt commit — THE FIX", `cd "${wtR}" && git commit -m x`, "allowed");
```

add:

```js
// #349 regression: the issue claimed the exemption doesn't fire for the
// standard `cd <worktree> && git …` form ("cdChain not extracted"). Falsified
// by probe: the walker DOES extract the cd target (see the T1b-T1f allowed
// verdicts below + the "shape: cdChain content pinned" expectBool). These
// cases pin the issue's exact incident command forms so a future regression
// fails loudly instead of freezing worktree sessions. T1d/T1e resolve the
// relative `../wt` against the sessionCwd frame (hubR) — the production
// bash-gate base-cwd path (the resolution base the #349 misdiagnosis
// hinged on).
m4t("T1b: cd abs-wt git add -A — the #349 incident form", `cd "${wtR}" && git add -A`, "allowed");
m4t("T1c: git -C abs-wt add -A — Indicator 2 cross-check", `git -C "${wtR}" add -A`, "allowed");
m4t("T1d: RELATIVE cd into wt + git add", `cd ../wt && git add -A`, "allowed");
m4t("T1e: RELATIVE cd into wt + git commit", `cd ../wt && git commit -m x`, "allowed");
m4t("T1f: NESTED wt-inside-hub (the tortoise .worktrees geometry) + git add", `cd "${hubR}/.worktrees/n" && git add -A`, "allowed");
```

**Step 2: Add the nested-worktree fixture (the incident's tortoise geometry)**

In the `#347: M4 worktree-target exemption` provisioning block (~lines 666-678), after the existing worktree adds, add:

```js
// #349: nested wt INSIDE the hub dir (the tortoise .worktrees/<n> geometry —
// the incident's exact layout, durably pinned after the repro scripts die).
execSync(`mkdir -p "${hubR}/.worktrees"`, { stdio: "ignore" });
execSync(`git worktree add -q "${hubR}/.worktrees/n" -b wt/n HEAD`, { cwd: hubR, stdio: "ignore" });
```

**Step 3: Add the probe-shape contract pin near the existing "observable:" assertions**

After the existing `observable: resolveInvocationTarget → worktree` expectBool, add:

```js
// #349 contract pin: resolveInvocationTarget consumes an INVOCATION object
// {cdChain, cHints, gitDirHint, workTreeHint, indexFileHint, objDirsHint} —
// there is NO `cmd` field. The issue's probe
// `resolveInvocationTarget({cmd: 'cd <wt> && git add -A', args: [...]}, hub)`
// trivially yields an EMPTY cdChain → effectiveCwd = hub → isWorktree:false.
// That result is EXPECTED for the wrong shape, not evidence of a parsing bug
// (the #349 misdiagnosis — the walker extracts cd targets fine, T1b/T1d/T1e).
const badShape = resolveInvocationTarget({ cmd: `cd "${wtR}" && git add -A`, args: ["add", "-A"] }, hubR, hubR);
expectBool("contract: {cmd,args} probe shape is NOT the invocation contract (empty cdChain → hub → isWorktree:false — #349 misdiagnosis)", badShape !== null && badShape.isWorktree === false && badShape.effectiveCwd === hubR, true);
```

**Step 4: Run the suite and confirm green**

Run: `node extensions/main-worktree-guard/test.mjs` — expect all existing 501 cases plus the 6 new ones to pass with 0 failures.

**Step 5: Remove scratch repro files**

Delete `extensions/main-worktree-guard/.repro-349.mjs` and `.scope-349.mjs` (ephemeral evidence; the committed m4t cases are the durable record).

### Task 2: Record the falsification in the issue + file the hardening findings

**Intent:** Close #349 with the evidence so the phantom repro cannot be re-filed, and per the auto-file rule, route the verifiers' P3 hardening findings to separate issues.
**Acceptance:**
- Issue #349 has a comment documenting: (a) the falsification evidence (probes on e0bf46f + main, both `allowed`), (b) the probe-shape misconstruction, (c) the audit-log timeline (1765 session 08-27 08:14Z predates the fix — e0bf46f 2026-08-27 13:16 +02:00 = 11:16Z; 08-28 production premise-labs `cd <wt> && git add/commit/push` sessions fired 6 `m4_worktree_exemption` audit events), (d) the test additions, (e) links to the two hardening issues.
- Two separate GitHub issues filed for the P3 hardening findings (pushd/popd not recognized; `--git-dir <wt>/.git --work-tree <wt>` positive containment signal not recognized) — NOT folded into #349.
- Labels: `scoping` removed, `invalid` added (falsified bug report — the honest close label).

**Files:**
- Create: (none — GitHub comments/issues only)

**Step 1: Post the falsification comment on #349**

`gh issue comment 349 --body "<evidence comment>"` — verbatim probe commands + outputs (from the scope runs), audit-log evidence (1765 session 08:14Z < fix — e0bf46f 2026-08-27 13:16 +02:00 = 11:16Z; 08-28 production exemption events), test additions, hardening issue links, close rationale.

**Step 2: File the two P3 hardening issues**

`gh issue create` for: (1) pushd/popd cwd-state mutations not recognized by `_walkShell` (conservative false-block, safe direction); (2) `--git-dir <wt>/.git --work-tree <wt>` from hub cwd not treated as a positive worktree-containment signal (conservative false-block of a git-equivalent form). Each with the verifier's exact repro.

**Step 3: Finalize labels + close**

`gh issue edit 349 --remove-label scoping --add-label invalid` then close with the evidence summary (labels: `invalid` is the honest close for a falsified bug report; the work WAS done — regression tests + contract pin — so note that in the close comment rather than mislabeling `implemented`).
