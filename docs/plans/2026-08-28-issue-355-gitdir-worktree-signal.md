---
title: "Plan: #355 --git-dir+--work-tree both-inside-wt as positive worktree-containment signal"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-355, main-worktree-guard
---

<!-- research-path: none (no external research — issue #355 carries the empirical reproduction; scoping probes re-confirmed both behaviors on git 2.50.1; full-diamond-verify re-checked the 508-baseline and the m4m fixture independently) -->

# Issue #355 — `git --git-dir=<wt>/.git --work-tree=<wt> …` Should Be a Positive Worktree-Containment Signal

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Treat a hub-rooted invocation that supplies BOTH `--git-dir=<wt>/.git` and `--work-tree=<wt>` (both resolving to a mapped worktree) as a positive worktree-containment signal, so the M4 hub-disorder exemption recognizes it — while keeping `--git-dir` ALONE blocked (cross-contamination) and all existing guards intact.

**Team:** organisation-design-team

**Complexity:** micro (issue label). **Tier note (scope-verify):** the issue-scoping skill's shared-code override upgrades `extensions/` touches to Standard; this session was dispatched as micro per orchestrator instruction and ran the micro pipeline (all 4 diamond phases + 1 full-diamond-verify gate). The plan's rigor is unaffected — the full-diamond verifier independently re-verified the empirical probes and the fixture facts.

**Architecture:** `resolveInvocationTarget` (extensions/main-worktree-guard/classify-git.mjs ~446–515) computes `inside` (cwd containment) and — only when `inside` — derives `worktreeBranch` via `git branch --show-current` with `cwd` = the effective cwd. The fix:
1. **Positive both-hints signal:** when `gitDirHint`'s resolved gitdir hits the worktree map (the existing precondition — the resolved admin dir lives under `<common>/worktrees/`, never literally inside the wt path) AND `workTreeHint` realpath-resolves inside that mapped worktreePath, the invocation is worktree-contained (`isWorktree: true`), mirroring git's effective-target semantics (`--git-dir` + `--work-tree` ≡ `-C <wt>`). The signal REQUIRES `workTreeHint` — `--git-dir` ALONE (work-tree defaults to cwd = hub) stays blocked structurally.
2. **Cwd-independent branch probe:** replace the cwd-scoped `git branch --show-current` probe with `git --git-dir=<gitDir> branch --show-current` (gitDir = the resolved admin dir, already computed). `inside=true ⇒ worktreePath !== null ⇒ gitDir is a mapped worktree's admin dir` — hub probing is STRUCTURALLY impossible. Value-identical to the old probe for every cwd-contained case (gitfile resolution ≡ direct admin-dir read; the map's two-way validation guarantees `wt/.git` back-references this admin dir); zero extra spawn (1:1 replacement); also fixes the old probe's latent mis-derivation under ambient `GIT_DIR=<hub>` env (CLI > env precedence, probe-verified).

**Empirical evidence (scoping probes, git 2.50.1 — reproduced by the controller AND re-verified by the full-diamond verifier):**
- Form A (`--git-dir=<wt>/.git --work-tree=<wt> add -A` from hub) stages only wt files into the wt index, hub untouched — byte-equivalent to the exempted `git -C <wt> add -A`.
- Form B (`--git-dir=<wt>/.git add -A` ALONE) stages HUB files (hubfile.txt) into the wt index — cross-contamination; must stay blocked. The new signal's workTreeHint-required condition makes Form B structurally unable to fire it.
- Branch derivation: `git branch --show-current` from the hub cwd returns the HUB's branch (`main`); from the wt (or via `--git-dir=<admin>`) returns `wt/feat`. A hub-derived probe would both false-block the canonical hub-on-main geometry AND — critically — false-exempt a wt-on-main hint-form commit (probe → hub's `hub/off` ≠ main → main-protection silent) → advances `refs/heads/main` while the hub is off-main+dirty. The cwd-independent probe closes this by construction.
- Probe 5b: the OLD cwd-scoped probe mis-derives under ambient `GIT_DIR=<hub>/.git` env even from inside the wt (returns the hub's branch); the explicit `--git-dir` form beats env — the replacement fixes this latent class.

### Pattern Research

> **Findings date:** 2026-08-28

> **Trigger assessment (justified skip):** axes all low (UX=low, Ontology=low, Architecture=low — internal guard function, no UI, no schema, no new architecture); ZERO third-party deps (Node stdlib + in-repo `classify-git.mjs` only); no novel pattern — the entire #347/#349 worktree-exemption machinery (`resolveInvocationTarget` + two-way-validated worktree map + M4 gate) is the in-repo precedent. External research not demonstrated — skipped per the activation rule. No library docs, version, or pitfall research applies.

### Integration Surface Map

Skipped — Micro tier, no integration boundaries: no DB, API, auth, external services, UI, or cross-cutting concerns. The change is internal to one in-repo guard function + its existing test file (`extensions/main-worktree-guard/test.mjs`). Verified consumers of `resolveInvocationTarget`: `evaluateHubGateWithTargets` (M4 gate) and `scriptGitVerdict` (script surface) read ONLY `isWorktree` / `worktreeBranch`; index.ts's M3/M2 gates use the SEPARATE `branchOwnership.resolveEffectiveRepo` resolver — `classify-git`'s `effectiveCwd` is dead outside its export contract (grep-verified). No test.mjs line references `worktreeBranch` directly (grep-verified).

### Journey Test Map

Skipped — no user-facing journeys (infrastructure guard, no UI).

### Scope Decision (solution-converge, quality over convenience)

**Picked: additive both-hints signal + cwd-independent branch probe** (smallest correct instance of the "effective-target containment" class). Rejected alternatives with rationale:

| Approach | Rejected because |
|---|---|
| **B. cwd-normalization** (swap `cwd=worktreePath` after guards) | Changes the exported `effectiveCwd` contract (test.mjs pins `effectiveCwd === hubR` for other classes); ordering cliff — any future pre-swap guard resolving a relative hint rebases against the wt → T125 breaks and `GIT_INDEX_FILE=./idx` resolves to `wt/idx` (passes the index guard) while git itself resolves it against the real cwd (the hub) → redirect hole. |
| **C. document-only** (accepted conservative limit) | The guard's purpose is "isolated-wt mutations are exempt from hub disorder"; Form A is byte-equivalent to the already-exempted `-C <wt>` form (probed). Leaving it frozen is a known false-block that freezes legit worktree sessions — the exact incident class #347/#349 exist to cure. |
| **D. git-native oracle** (`rev-parse --show-toplevel` with hints) | +1 spawn on the resolving path; oracle-fidelity risk for `--git-dir` ALONE (work-tree defaults to cwd — a quirk to pin, not a principled rule); still needs the same branch probe (the oracle returns a path, not a branch); `core.worktree` fidelity is moot (`branch --show-current` doesn't consult it; explicit `--work-tree` overrides it). |
| **E. walker-level fold** (push workTreeHint into `cHints` at shape-time) | Re-bases EVERY guard's relative resolution against the wt (T125 false-block; `GIT_INDEX_FILE=./idx` hole unconditional); `cHints` is a pinned contract field consumed by `commandExecutionCwd` and pinned by walker tests (T1d/T1e). |

**Within A: cwd-independent probe over probeCwd conditional.** The earlier draft's `probeCwd` conditional (probe from `worktreePath` when signal-fired-without-cwd-containment) is correct but leaves a divergence surface; the `--git-dir=<gitDir>` probe makes hub-probing structurally impossible, adds no conditional, replaces the existing probe 1:1 (zero extra spawn), and fixes the ambient-`GIT_DIR` mis-derivation. This is the plan's Task 2 Step 2.

### Failure Modes

- `--git-dir=<wt>/.git` ALONE regresses to allowed → **Expected:** T123 fails (must stay block — hub files leak into wt index). Structurally impossible: `wtHintInside` requires `inv.workTreeHint`.
- Hub on `main` + dirty, both-flags form blocked (worktreeBranch mis-derived from hub) → **Expected:** the cwd-independent probe reads the WT's HEAD; case T122 (hub on main + dirty) pins it.
- Hub OFF-main + wt-on-main, both-flags form allowed (main-protection silent) → **Expected:** cwd-independent probe returns `main` from the wt's HEAD → main-protection blocks; case T131 (m4m fixture, hub on `hub/off` + dirty, `mwtmain` on main) pins it. This is the security regression guard — the probe must never read the hub's branch (`hub/off` ≠ main → silent false-exempt).
- Mismatch `--git-dir=<hub>/.git --work-tree=<wt>` allowed → **Expected:** gitDir map miss → `worktreePath === null` early-return → block; case T124 pins it.
- Cross-wt / hub-worktree mismatches allowed → **Expected:** mismatch guard (shared `wtHintReal`), cases T130/T130b pin them.
- Relative/symlink spelling of both hints not recognized → **Expected:** hints resolve against the session cwd frame (T1d/T1e precedent) and are realpath-normalized both sides (T28); case T125 pins relative spelling.
- Env-form `GIT_DIR=` + `GIT_WORK_TREE=` both set → **Expected:** walker normalizes into the same hint pair; case T126 pins it.
- Admin-dir both-flags (`--git-dir=<hub>/.git/worktrees/wt`) → **Expected:** gitfile-free admin dir resolves to the same map key; case T127 pins it.
- Space-separated flag spelling (`--git-dir <wt>/.git --work-tree <wt>`) → **Expected:** walker's second extraction path; case T133 pins it.
- Probe value drift for existing cwd-contained cases → **Expected:** T132 (probe-identity expectBool) + all existing main-protection verdicts (M1–M4 m4m cases) catch it. Value-identical structurally (same HEAD file, same ref).
- git read failure in the probe (pruned admin dir race) → null → conservative; identical semantics to today's probe race — no new hole.

**Tech Stack:** Node.js (ESM), git CLI (probed on git 2.50.1; `execFileSync` already imported at classify-git.mjs:10; `--git-dir` is a global option valid on `branch`), no third-party deps.

---

### Task 1: Add failing m4t regression cases (+ m4m security guard + probe-identity pin)

**Intent:** Pin the issue's Indicator 1 (both-flags → allowed), Indicator 2 (git-dir ALONE → block — must not regress), the mismatch matrix, spelling variants, and — critically — the wt-on-main security invariant (T131) BEFORE the code change, so the fix is driven by failing tests.

**Acceptance:** `node extensions/main-worktree-guard/test.mjs` shows the both-flags cases FAILING (currently `block`), the pre-existing behaviors still passing, and the 508 baseline green (modulo the new cases).

**Files:**
- Modify: `extensions/main-worktree-guard/test.mjs` (m4t section, after the #351 X-block / before the final summary; m4m section for T131)

**Step 1: Add the cases.**

Insert after the `X6b` block (end of the #351 porcelain cross-check section), before the round-2 `T35` block:

```js
  // ── Issue #355: --git-dir + --work-tree both-inside-wt = POSITIVE containment ──
  // A hub-rooted invocation supplying BOTH --git-dir=<wt>/.git AND --work-tree=<wt>
  // fully determines git's effective repo + work-tree (cwd becomes irrelevant):
  // empirically byte-equivalent to the exempted `git -C <wt> add -A` (probe:
  // stages wt-only.txt into the wt index, hub untouched). --git-dir ALONE must
  // stay BLOCKED (work-tree defaults to cwd = hub → stages HUB files into the
  // wt index — cross-contamination, probed). The signal requires BOTH hints.
  m4t("T122: --git-dir + --work-tree both-in-wt add — THE FIX", `git --git-dir="${wtR}/.git" --work-tree="${wtR}" add -A`, "allowed");
  m4t("T123: --git-dir ALONE from hub → block (cross-contamination)", `git --git-dir="${wtR}/.git" add -A`, "block");
  m4t("T124: hub git-dir + wt work-tree mismatch → block", `git --git-dir="${hubR}/.git" --work-tree="${wtR}" add -A`, "block");
  m4t("T125: RELATIVE both-flags from hub cwd → allowed", `git --git-dir="../wt/.git" --work-tree="../wt" add -A`, "allowed");
  m4t("T126: env-form GIT_DIR+GIT_WORK_TREE both-in-wt → allowed", `GIT_DIR="${wtR}/.git" GIT_WORK_TREE="${wtR}" git add -A`, "allowed");
  m4t("T127: admin-dir both-flags → allowed (gitfile-free gitdir)", `git --git-dir="${hubR}/.git/worktrees/wt" --work-tree="${wtR}" add -A`, "allowed");
  m4t("T128: NESTED-wt both-flags (tortoise .worktrees geometry) → allowed", `git --git-dir="${hubR}/.worktrees/n/.git" --work-tree="${hubR}/.worktrees/n" add -A`, "allowed");
  m4t("T129: SUBDIR work-tree both-flags → allowed (prefix containment)", `git --git-dir="${wtR}/.git" --work-tree="${wtR}/subdir" add -A`, "allowed");
  m4t("T130: CROSS-wt mismatch (wt gitdir + nested-wt work-tree) → block", `git --git-dir="${wtR}/.git" --work-tree="${hubR}/.worktrees/n" add -A`, "block");
  m4t("T130b: wt gitdir + HUB work-tree mismatch → block", `git --git-dir="${wtR}/.git" --work-tree="${hubR}" add -A`, "block");
  m4t("T133: SPACE-SEPARATED both-flags → allowed (walker 2nd extraction path)", `git --git-dir "${wtR}/.git" --work-tree "${wtR}" add -A`, "allowed");
  // #355 probe-identity pin: the cwd-independent branch probe (explicit
  // --git-dir=<admin>) must equal the cwd-scoped probe value for a cwd-contained
  // invocation — divergence would mean the fix changed an existing
  // worktreeBranch value (verdict-affecting via main-protection).
  const probeAdmin = execSync(`git --git-dir="${hubR}/.git/worktrees/wt" branch --show-current`, { encoding: "utf-8" }).trim();
  const probeCwd = execSync(`cd "${wtR}" && git branch --show-current`, { encoding: "utf-8" }).trim();
  const eqTgt = resolveInvocationTarget(allGitInvocations(`cd "${wtR}" && git commit -m x`)[0], hubR, hubR);
  expectBool("T132: cwd-independent probe ≡ cwd-scoped probe (no existing value change)",
    eqTgt?.worktreeBranch === probeCwd && probeAdmin === probeCwd, true);
```

In the round-3 main-protection mini-fixture (m4m section — append as the block's final case after `M3`, keeping the fixture's existing order M1, M2, M2b, M4, M3, M5):

```js
  // #355: wt-ON-MAIN both-flags from the hub — the SECURITY regression guard.
  // Post-fix the exemption fires (isWorktree true) but the cwd-independent probe
  // reads the WT's HEAD → "main" → main-protection blocks. Pre-fix: containment
  // miss → block. A future change that mis-derives worktreeBranch from the hub
  // (hub/off) would silently return allowed and advance refs/heads/main — this
  // pin flips red and fails.
  m4m("M5: wt-ON-MAIN both-flags commit from hub → block (main-protection, #355)",
      `git --git-dir="${mwtmain}/.git" --work-tree="${mwtmain}" commit -m x`, "block");
```

**Step 2: Run the suite.**

Run: `node extensions/main-worktree-guard/test.mjs`
Expected: `T122`/`T125`/`T126`/`T127`/`T128`/`T129`/`T133` FAIL with `block` (the bug); `T123`/`T124`/`T130`/`T130b` PASS (guards hold pre-fix); `T131` (M5) PASS (block pre-fix — regression guard, not red-green); `T132` PASS; everything else unchanged.

### Task 2: Implement the fix in resolveInvocationTarget

**Intent:** Make `isWorktree` true when git's effective target is a mapped worktree via BOTH hints, derive `worktreeBranch` from that target's own HEAD (cwd-independent), and keep every existing guard semantics-identical.

**Acceptance:** All new cases pass; the full suite is green; no existing behavior changed.

**Files:**
- Modify: `extensions/main-worktree-guard/classify-git.mjs` (`resolveInvocationTarget`, ~lines 479–515)

**Step 1: Shared `wtHintReal` + OR the hint-based positive signal into `inside`.**

Replace the block from `const cwdReal = _realpathSafe(cwd);` through the workTree mismatch guard with (index/objdir redirect guards BELOW stay byte-identical — they resolve relative hints against `cwd`, the hub for the both-hints-from-hub form; the cwd never swaps, so no rebasing cliff):

```js
    const cwdReal = _realpathSafe(cwd);
    if (cwdReal === null) return null;
    // #355: workTreeHint realpath — computed ONCE, shared by the positive
    // containment signal AND the mismatch guard (one realpath, both guards —
    // they can never disagree at the realpath-normalization boundary).
    const wtHintReal = inv.workTreeHint ? _realpathSafe(resolve(cwd, inv.workTreeHint)) : null;
    // #355 positive containment signal: gitDirHint resolving to a mapped
    // worktree's gitdir (map hit above ⇒ worktreePath !== null) AND workTreeHint
    // resolving inside that worktree ⇒ git's effective target IS the worktree
    // regardless of cwd. `git --git-dir=<wt>/.git --work-tree=<wt> <verb>` from
    // the hub cwd is byte-equivalent to the exempted `git -C <wt> <verb>` (both
    // operate on the wt index, zero hub interaction; probed on git 2.50.1).
    // workTreeHint-REQUIRED: `--git-dir` ALONE (work-tree defaults to cwd = hub)
    // stages HUB files into the wt index — cross-contamination — and must NOT
    // fire (structural by BOTH-hints).
    const wtHintInside = !!(inv.gitDirHint && inv.workTreeHint) &&
      wtHintReal !== null &&
      (wtHintReal === worktreePath || wtHintReal.startsWith(worktreePath + "/"));
    const inside = wtHintInside || cwdReal === worktreePath || cwdReal.startsWith(worktreePath + "/");
    // workTree mismatch guard (unchanged semantics — shared wtHintReal): a
    // work-tree hint pointing OUTSIDE the worktree means the invocation operates
    // on a foreign working tree → not isolated. Mutually exclusive with
    // wtHintInside by construction.
    if (inv.workTreeHint) {
      if (wtHintReal !== null &&
          !(wtHintReal === worktreePath || wtHintReal.startsWith(worktreePath + "/"))) {
        return { effectiveCwd: cwd, gitDir, worktreePath, worktreeBranch: null, isWorktree: false };
      }
    }
```

**Step 2: Cwd-independent worktreeBranch probe (replaces the cwd-scoped probe).**

Replace the `worktreeBranch` derivation (`execSync("git branch --show-current", { cwd })` — the OLD probe mis-derives under ambient `GIT_DIR` env and, for the new hint signal, would read the hub's HEAD):

```js
    let worktreeBranch = null;
    if (inside) {
      try {
        // Cwd-INDEPENDENT probe (#355): --git-dir is a global option valid on
        // `branch`. With the resolved admin dir (gitDir), the probe reads the
        // WT's OWN HEAD from ANY cwd — inside=true ⇒ worktreePath !== null ⇒
        // gitDir is a mapped worktree's admin dir, so a hub probe is
        // structurally impossible. Value-identical to the old cwd-scoped probe
        // for every cwd-contained case (gitfile resolution ≡ direct admin-dir
        // read; the map's two-way validation guarantees wt/.git back-references
        // this admin dir). Replaces the old probe 1:1 — zero extra spawn.
        // Explicit --git-dir also beats ambient GIT_DIR env (CLI > env),
        // fixing the old probe's latent mis-derivation (probe-verified).
        worktreeBranch = execFileSync("git", ["--git-dir=" + gitDir, "branch", "--show-current"], {
          encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
        }).trim() || null;
      } catch {
        worktreeBranch = null; // git read failure → conservative (unchanged)
      }
    }
```

**Step 3: Docstring update.**

Extend the `resolveInvocationTarget` JSDoc (~lines 428–445): document the new both-hints positive containment signal and the new state combination (`isWorktree: true` with `effectiveCwd` outside the worktreePath — consumers `evaluateHubGateWithTargets` M4 and `scriptGitVerdict` read only `isWorktree`/`worktreeBranch`; `effectiveCwd` remains the walker-resolved cwd for all other cases), and note the probe is now effective-target-aware (cwd-independent).

**Step 4: Run the suite.**

Run: `node extensions/main-worktree-guard/test.mjs`
Expected: all green — new cases pass, 508 baseline stays green (no regressions).

### Task 3: Final verification

**Intent:** Confirm the issue's three Targets and leave the tree clean.

**Acceptance:** Suite green (all m4t + m4m + existing tests), no stray files.

**Files:**
- (none — verification only)

**Step 1: Full suite.**

Run: `node extensions/main-worktree-guard/test.mjs`
Expected: all pass; total ≈ 521 (508 baseline + 11 m4t verdict cases T122–T130/T130b/T133 + 1 m4m case T131/M5 + 1 expectBool T132); note the baseline may have drifted ±1 since the 508 anchor — confirm no failures, not the exact count.

**Step 2: Probe-identity spot-check (no existing value change).**

For each existing cwd-contained form (`cd "${wtR}" && git commit`, `git -C "${wtR}" …`, admin-dir `-C` form T18b, gitfile form T20a): confirm `git --git-dir=<admin> branch --show-current` (run from the hub cwd) equals the cwd-scoped value. T132 pins the canonical case permanently; this spot-check covers the family.

**Step 3: Sanity-check the no-regression surface.**

Run: `git status --porcelain` in the worktree — expect only the two modified files (`classify-git.mjs`, `test.mjs`) plus this plan doc; no probe/temp files left behind (m4Tmp/m4MainTmp clean in their finallys).

---

<!-- plan-review: pending -->
