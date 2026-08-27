---
title: "Plan: M4 worktree-target exemption (issue #347)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-27
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-347, main-worktree-guard
---

# Plan: M4 worktree-target exemption (issue #347)

Date: 2026-08-27 · Repo: agent-infra · Branch: `fix/347-m4-worktree-freeze`
Pipeline: task-workflow-standard (scope → plan → verifier gates) · issue-scoping v5.1 double diamond
Status: scoped + solution-verified + plan-verified (cycles 1-4; **cap reached at 4 cycles** — 2 residual P1s controller-verified with direct evidence and folded into v5; implementation proceeds with the test matrix + live e2e + commit-workflow code review as residual gates)

## Problem statement

M4 (hub-discipline gate, #1484) anchors its hub-disorder read to the **session cwd**
(`_hubState()` → `readHubDisorder(resolve(process.cwd()))`) and gates every git
invocation by verb/args alone (`evaluateHubGate`) with **no notion of the
invocation's effective repo**. Consequently a session rooted in the hub that runs
git ops targeting an isolated worktree — `cd <wt> && git commit`,
`git -C <wt> status`, `cd <wt> && bash x.sh` — is blocked whenever the hub is
off-main or dirty (2026-08-27 tortoise incident class: three consecutive freezes
from untracked WIP in main). The write/edit M4 block has the same misanchor: it
blocks **all** writes from a hub session when disordered, before any target
resolution. `_backdoorBlock` resolves script paths against `process.cwd()` —
same class.

**Fix:** resolve each git invocation's effective target; exempt worktree-targeted
invocations from the M4 bash gate; make the write/edit M4 block target-aware
(hub-equality); make the script backdoor execution-cwd-aware. **No total-bash-gate
bypass and no false exemption**: the exemption is per-invocation and semantic
(worktree-list membership, not path strings); non-worktree targets (hub, foreign,
unresolvable) keep today's gating.

## Confirmed constraints (from problem/solution verify — P0/P1)

- **C1 (P1, security):** per-invocation resolution. `cd <wt> && git commit &&
  git -C <hub> reset --hard` must still BLOCK. Same-verb compounds must block.
  Exemption must be semantic (worktree-list membership + effectiveCwd
  containment), never path-string-based.
- **C2 (P1, degradation):** M4 depends ONLY on classify-git.mjs. The fix must
  not make M4 depend on branch-ownership — branch-ownership load failure must
  NOT regress the freeze fix. Approach A (self-contained in classify-git).
- **C3 (P1, D3):** the M4 write/edit block stays INSIDE `if (!_isAllowMainEdits())`
  and BEFORE the marker bypass (line ~450). Only its internal logic changes from
  blanket-block to target-vs-hub equality.
- **C4:** `_backdoorBlock` becomes execution-cwd-aware (script path + content
  gating resolved against the command's cd-target), **while keeping the
  session-level worktree fast-path**.
- **C5:** foreign non-worktree repos keep today's gating on the bash side
  (worktree lookup runs at sessionCwd — a foreign repo's worktrees are not in
  the hub's map → blocked). Write side: hub-equality (writes never mutate git
  refs; /tmp + foreign writes exempt when hub disordered; compensated by the
  end-to-end backdoor closure test B11).
- **C6:** `readHubDisorder(process.cwd())` stays the session anchor.

## Solution (Approach A — self-contained in classify-git.mjs, with reviewer fixes)

### Worktree predicate — SEMANTIC (plan-verify cycles 1-2)

Empirically verified (git 2.50.1 Apple Git-155): **`git worktree list --porcelain`
emits NO `gitdir` column** (only `worktree`/`HEAD`/`branch`|`detached`/`bare`/
`locked`/`prunable`) — the membership key must come from elsewhere, and the main
checkout is listed as its first entry (must never match).

**Worktree map (per sessionCwd, derived from reverse-pointer files + filesystem
layout — one git call total, main excluded by construction, empirically verified
on git 2.50.1 macOS):**
1. `common = realpath(resolve(sessionCwd, execSync("git rev-parse --git-common-dir",
   {cwd: sessionCwd})))` — `git-common-dir` returns RELATIVE `.git` from the hub
   (probe-verified) — resolve against sessionCwd, then realpath.
2. For each subdirectory `name` under `common/worktrees/`: read
   `join(adminRoot, name, "gitdir")` (the reverse-pointer file; content =
   realpath of `<wt>/.git`, probe-verified); `wtPath = realpath(dirname(content))`;
   **map key = `realpath(join(adminRoot, name))`** — the canonical admin dir
   (`<common>/worktrees/<name>`, which `git rev-parse --git-dir` returns for a
   worktree cwd, probe-verified) — NOT the reverse-pointer content (which is the
   gitfile path `<wt>/.git` and does NOT match rev-parse output);
   `map.set(adminDirKey, wtPath)`.
3. Main checkout is excluded by construction (its common dir is `common`
   itself, never under `common/worktrees/`). No git calls per worktree.
4. **Probe evidence (git 2.50.1 Apple Git-155, macOS /tmp→/private/tmp):**
   porcelain emits ZERO gitdir lines; `git rev-parse --git-dir` from a wt returns
   the realpath'd admin dir `/private/tmp/<base>/hub/.git/worktrees/wt`; from the
   hub returns relative `.git`; a `--git-dir=<admin>` hint is echoed as-given
   (`/tmp/...`) while a `--git-dir=<gitfile>` hint resolves to realpath — all
   forms converge under `realpath(resolve(effectiveCwd, raw))`.

**Invocation target (`resolveInvocationTarget(inv, sessionCwd)`):**
1. `effectiveCwd` = cd-chain (failed-cd-aware, subshell-scoped) + cHints in
   order → **realpath-normalized** (macOS `/tmp`→`/private/tmp`; porcelain and
   gitdir files are realpath'd, effectiveCwd is not — both sides must agree).
2. canonical `gitDir` = `realpath(resolve(effectiveCwd, raw))` where:
   - `gitDirHint` present → `raw = execSync("git --git-dir=<resolve(effectiveCwd,
     hint)> rev-parse --git-dir", {cwd: effectiveCwd})` (git resolves gitfiles;
     admin-dir hints echoed as-given → realpath normalizes);
   - else → `raw = execSync("git rev-parse --git-dir", {cwd: effectiveCwd})`
     (relative `.git` from main, realpath'd admin dir from worktrees);
   - realpath/resolve makes all spellings converge on the map keys.
3. `worktreePath = map.get(canonicalGitDir) ?? null`.
4. `isWorktree` = `worktreePath !== null && (realpath(effectiveCwd) ===
   worktreePath || realpath(effectiveCwd).startsWith(worktreePath + "/"))`.
5. **workTree mismatch guard:** `workTreeHint` present and
   `realpath(resolve(effectiveCwd, workTreeHint))` NOT inside worktreePath →
   `isWorktree = false` (block).
6. Returns `{ effectiveCwd, gitDir, worktreePath, isWorktree }` or null (git
   failure / realpath failure → conservative, no exemption).

This closes: cycle-4 trap (`-C <wt> --git-dir=<hub>/.git <block-verb>` → gitDir
= main `.git` → not in map → block); **admin-dir attack**
(`--git-dir=<hub>/.git/worktrees/<x> reset --hard` from hub → gitDir IS a
worktree admin dir → in map → but effectiveCwd=hub NOT contained → block);
path-name false-positives (`/x/worktrees/foo` not in map → block); **gitfile
from hub cwd** (`GIT_DIR="<wt>/.git" git commit` from hub → effectiveCwd=hub
not contained → block — correct: git commits hub working-tree files onto the wt
branch, a cross-contamination hazard); workTree mismatch; foreign worktrees
(not in the sessionCwd map → block, C5); symlinked spellings (realpath both
sides).

### classify-git.mjs

1. **`allGitInvocations(command)`** — new exported function (renamed from
   private `_allGitInvocations`; **exported for test.mjs**). Emitted shape per
   invocation: `{ verb, args, cdChain, cHints, gitDirHint, workTreeHint, vars }`
   — `{verb, args}` unchanged for existing consumers.
   - `cdChain`: running chain of resolved `cd <target>` targets, **subshell-
     scoped AND pipe-scoped** via a shared `_SubshellChain` helper: `(` pushes a
     chain copy (subshell inherits the parent cwd), `)` pops; cds inside parens
     never leak. **Pipe rule (cycle-4 P1, probe-verified):** `C0 = the cdChain
     as of the last command boundary BEFORE the first pipe segment`; every pipe
     segment (INCLUDING the first) runs against a copy seeded from C0 and its
     cds are discarded at the segment end; restore `chain = C0` at the next
     `&&`/`||`/`;`/`)`/EOF. Probe: `cd /tmp | cd <wt> && pwd` AND `cd <wt> |
     cd /tmp && pwd` BOTH print the hub (every pipeline segment runs in a
     subshell) → T32 AND T33 both BLOCK.
   - **Per-cd var resolution**: each cd target is resolved AT WALK TIME against
     the vars in scope at that cd (segment-local `VAR=` assignments), and the
     RESOLVED target is pushed into cdChain — so same-segment `$VAR` cds
     (`WT="<wt>" cd "$WT" && git commit`, T3/B2) resolve; an unresolvable
     `$VAR` at any cd → null (conservative). The invocation's vars snapshot is
     NOT used for chain resolution.
   - `cHints`: `-C`/`--cd` for **that invocation only**, in order.
   - `gitDirHint`: `--git-dir[=]` for that invocation + `GIT_DIR=` env prefix
     scoped to the **next command only** (bash semantics; deliberate divergence
     from branch-ownership's all-invocations scoping — see consistency matrix).
   - `workTreeHint`: `--work-tree[=]` + `GIT_WORK_TREE=` (next-command scope).
   - `vars`: `VAR=value` assignments since the last command boundary
     (`&&`/`||`/`;`/`|`/`(`) — **per-segment scoping** (branch-ownership's
     leading pre-scan has no per-segment scoping; documented divergence).
2. **`_resolveCdChain(cdChain, sessionCwd)`** — private (no `vars` param —
   per-cd resolution happens at walk time in `allGitInvocations`, cycle-4 P4):
   resolve cds sequentially; **failed-cd semantics (cycle-4 P3, state (a)):** a
   cd target that does not resolve to an existing directory is a failed `cd` —
   bash keeps the cwd before the failed cd, so the failed target AND everything
   after it in the chain are discarded while the resolved prefix stands
   (`cd <wt> && cd /nonexistent && git commit` runs at `<wt>` → allow, T35); a
   bare-`cd`-at-start (chain begins with a failed cd) → caller keeps the
   session cwd. Unresolvable `$VAR` → null (conservative). `~` → null
   (conservative).
3. **`_worktreeGitdirMap(sessionCwd)`** — private: the reverse-pointer derivation
   above (Map<canonicalGitDir, worktreePath>). **Per-entry try/catch:** skip any
   entry whose gitdir file is unreadable OR whose `dirname(content)` realpath
   throws (stale admin dir left by `rm -rf <wt>` without prune — ENOENT; T34);
   only a `git-common-dir` or `readdir` failure produces the whole-map-empty
   conservative fallback. Map is ALWAYS derived at the SESSION cwd (the guard's
   hub — invariant across hub + worktrees); `executionCwd` only feeds the
   cd-chain base (step 4) — a /tmp-executed script still sees the hub's map (B14
   allow). Optional sessionCwd-keyed cache (topology stable within a session).
4. **`resolveInvocationTarget(inv, sessionCwd, baseCwd = sessionCwd)`** — new
   export (predicate above). sessionCwd is the cwd frame for the MAP (M4 only
   fires when session cwd IS the hub; foreign worktrees stay blocked); baseCwd is
   the cd-chain/cHints resolution base (evaluateHubGateWithTargets passes
   sessionCwd; scriptGitVerdict passes executionCwd). gitDirHint resolution uses
   the **args-array `execFileSync` form** (NOT `execSync` — Node's `execSync`
   has NO array overload, cycle-4 P1, probe-verified: it runs bare `git` and
   throws): `execFileSync("git", ["--git-dir=" + resolved, "rev-parse",
   "--git-dir"], {cwd: effectiveCwd})` — no shell interpolation (worktree names
   with spaces / metacharacters must not split or execute). Add `execFileSync`
   to the `node:child_process` import (classify-git.mjs line 10).
5. **`evaluateHubGateWithTargets(command, currentBranch, sessionCwd = process.cwd())`**
   — new export. **Decision procedure:**
   1. `invs = allGitInvocations(command)`; none → `{ verdict: "non-git" }`.
   2. For each: `v = isHubRecoveryInvocation(verb, args, currentBranch)`.
   3. `v === "block"` → `t = resolveInvocationTarget(inv, sessionCwd)`; if
      `t?.isWorktree` → continue (isolated — exempt); else → return the
      standard block verdict (same reason text as `evaluateHubGate`).
   4. `v === "recovery"` → sawRecovery = true; else (readonly) → continue.
   5. Return `{ verdict: sawRecovery ? "recovery" : "allowed" }`.
   - `checkout main`/`switch main` classify `recovery` and are never resolved
     (sanctioned regardless of target); the git-dir override trap is exercised
     with block verbs.
   - Branch sourcing: classify uses the HUB's branch; worktree exemption applies
     regardless of verdict, so per-target branch sourcing is unnecessary.
   - `evaluateHubGate` stays exported **contract-identical** (signature +
     verdicts; body may reference the renamed `allGitInvocations`).
6. **`commandExecutionCwd(command, sessionCwd)`** — new export: leading
   env/`cd`-chain walk using the SAME `_SubshellChain` push/pop (NOT bare
   paren-skipping — `cd /x && (cd /y) && bash s.sh` runs the script at /x; the
   inner cd must not leak: outer chain [/x], inner popped) → resolved execution
   cwd with failed-cd semantics; null on unresolvable `$VAR` (caller falls back
   to session cwd — true bash semantics). **Returns the cdChain state AT the
   script-path token (interpreter/script position), not after the full command
   (cycle-4 P2)** — B4/B12 exercise exactly this (`(cd /x && bash ./s.sh)` →
   chain at the script token = [/x]).
7. **`extractScriptPath(command)`** — extend the leading-position scan to skip
   `(`/`)` subshell wrappers (symmetric with the chain helper), closing the
   `(cd /tmp && bash x.sh)` script backdoor. Existing cases unchanged.
8. **`scriptGitVerdict(path, currentBranch, executionCwd = process.cwd())`** —
   3rd optional param. Per-invocation: block verdict → `resolveInvocationTarget(
   inv, sessionCwd = process.cwd(), baseCwd = executionCwd)` (map from the
   session's repo; executionCwd only the script-content cd-base) → worktree →
   exempt; else block.
9. **`resolveTargetTopLevel(targetPath, cwd = process.cwd())`** — new export
   (testable home for the write-gate check): walk `dirname(resolve(cwd,
   targetPath))` up to the nearest existing dir → `git rev-parse
   --show-toplevel` → string or null (git failure → null → caller falls
   through).

### index.ts

10. New imports + inert fail-safe defaults (defaults block ~55-60 + try-block
    destructure) for `evaluateHubGateWithTargets`, `commandExecutionCwd`,
    `resolveTargetTopLevel`. (index.ts never imports `resolveInvocationTarget`
    directly — test-only.)
11. **M4 bash gate** (~415-428): `evaluateHubGate(command, st.branch)` →
    `evaluateHubGateWithTargets(command, st.branch, resolve(process.cwd()))`.
    `_hubState()` session anchor unchanged (C6). D3 ordering unchanged.
12. **`_backdoorBlock`** (~210-231): keep the session-level
    `isWorktreeCwdWrite(resolve(process.cwd()))` fast-path (C4); base
    script-path resolution + content gating on
    `commandExecutionCwd(command, process.cwd()) ?? process.cwd()` (pin the
    call shape — cycle-4 P4).
13. **Write/edit M4 block** (~428-437): stays inside `if (!_isAllowMainEdits())`
    BEFORE the marker bypass (C3/D3). Internal logic →
    `st.disorder && resolveTargetTopLevel(targetPath) === _mainTopLevel()` →
    block; else fall through. NOTE: `targetPath` must be read
    (`(event.input as {path?: string}).path`) INSIDE the write/edit branch — it
    is currently computed later in the handler (~695) — hoist it.
    `resolveTargetTopLevel`'s return value is `resolve`/`realpath`-normalized
    identically to `_mainTopLevel()` before the `===` (symlink spellings of the
    hub must not diverge).
14. **Doc comments:** update the index.ts header + M4 section comment to state
    the per-invocation worktree-target exemption.

### test.mjs

15. New `m4t()` helper driving `evaluateHubGateWithTargets` over a provisioned
    tmp hub (`git init -b main`, commit, untracked file → dirty) + linked
    worktree. Existing `m4()` (evaluateHubGate) and `guardDecision` untouched.
    Provisioning under a realpath-stable dir (realpath `mktemp -d` result
    before `git init` — mirrors the existing marker test's `baseDir` pattern).
16. **Existing `scriptGitVerdict` call sites pass `MAIN` explicitly** as
    executionCwd (suite supports worktree-run mode; plan-verify P1). New
    script-verdict assertions pass executionCwd explicitly too.
17. Regression matrix (below). Cross-consistency extension, **scoped to
    agreement**: `resolveInvocationTarget` vs `resolveEffectiveRepo` agree on
    isWorktree for same-segment, non-subshell, no-GIT_DIR cases (cd-into-wt,
    `-C` wt, `-C wt --git-dir=main` (both false), same-segment `$VAR` cd,
    compound chains). **Expected divergences annotated** (kept OUT of the
    agreement matrix): GIT_DIR next-command vs all-invocations (classify-git
    bash-faithful; branch-ownership's all-invocations GIT_DIR can FALSE-EXEMPT
    M3 — pre-existing, out of scope C2); vars per-segment vs leading pre-scan;
    subshell-scoped cd (branch-ownership never pops subshells → outer
    invocations disagree); **pipe-scoped chain (branch-ownership's flat cdChain
    ignores pipeline boundaries — false-exempts M2/M3/legacy on T32-class
    commands; pre-existing, out of scope C2)**; failed-cd-in-middle outcome
    divergence (classify-git v4 allows `cd <wt> && cd /nope; git commit`, branch-
    ownership resolves blindly → false-blocks; both safe).
18. Shape-level regression: `allGitInvocations("cd <wt> && git -C <hub>
    reset")` emits per-invocation cdChain/cHints/gitDirHint/vars; the
    `_SubshellChain` pop behavior (`cd /x && (cd /y) && git commit` → outer
    chain [/x]).
19. Static assert: `classify-git.mjs` source contains no `branch-ownership`
    import (C2 guard).
20. Worktree provisioning hygiene: every new `git worktree add` gets a
    `finally`-remove; suite-final `git worktree prune`.

### README.md + deployment

21. Update README M4 §Scope (per-invocation worktree-target exemption),
    write-side hub-equality + /tmp/foreign relaxation, backdoor execution-cwd
    semantics, worktree-target push parity note (pre-existing #265 gap), §D3.
22. **Cross-repo propagation (deliverable):** repair the stale
    `eldato/operations/pi-config/extensions/main-worktree-guard` dangling
    symlink (points at old `/Users/home/agent-infra/...`) → current agent-infra
    path; verify `~/.pi/agent/extensions/main-worktree-guard` symlink farm
    resolves; confirm linked repos (tortoise, eldato, DMeer, premise-labs,
    wt-291) resolve the extension.

## Regression matrix

### Bash gate (hub session, hub dirty — `m4t`)

| # | Command | Expect | Constraint |
|---|---|---|---|
| T1 | `cd <wt> && git commit -m x` | allowed | THE FIX (freeze regression) |
| T2 | `git -C <wt> commit -m x` | allowed | -C form |
| T3 | `WT="<wt>" cd "$WT" && git commit` | allowed | same-segment $VAR (#337) |
| T4 | `cd $UNRESOLVED && git commit` | block | unresolvable → conservative |
| T5 | `git commit -m x` | block | hub-targeted + dirty = blocked (main never in map) |
| T6 | `git -C <hub> reset --hard` | block | hub-targeted destructive |
| T7 | `cd <wt> && git commit && git -C <hub> reset --hard` | block | **C1 P1 compound** |
| T8 | `git -C <wt> commit -m a && git -C <hub> commit -m b` | block | **C1 same-verb compound** |
| T9 | `git -C <wt> --git-dir="<hub>/.git" reset --hard` | block | cycle-4 trap (block verb) |
| T10 | `GIT_DIR="<hub>/.git" git -C <wt> commit` | block | env-form git-dir trap |
| T11 | `git --git-dir="<hub>/.git/worktrees/<wt>" reset --hard` | block | admin-dir attack: in map but cwd not contained |
| T12 | `(cd <wt>) && git reset --hard` | block | subshell cd does not leak |
| T13 | `cd <wt> && (git reset --hard)` | allowed | subshell inherits cd |
| T14 | `(cd <wt> && git commit) && git reset --hard` | block | subshell + outer hub reset |
| T15 | `cd <wt> && (git -C <hub> reset --hard)` | block | cd outside + -C inside parens |
| T16 | `(cd <wt> && git -C <hub> reset --hard)` | block | cd + -C inside subshell |
| T17 | `cd <wt> && git -C <hub> reset --hard` | block | cd + -C override → hub |
| T18 | `cd <wt> && git -C <wt> --work-tree="<hub>" reset --hard` | block | **workTree mismatch guard** (flag form) |
| T18a | `GIT_WORK_TREE="<hub>" git -C <wt> commit` | block | workTree mismatch (env form) |
| T18b | `git -C <wt> --git-dir="<hub>/.git/worktrees/<wt>" reset --hard` | allowed | admin dir + cwd inside = the worktree (verified operates on wt) |
| T19 | `GIT_DIR="<hub>/.git" git status && git -C <wt> commit` | recovery | GIT_DIR next-command scoping |
| T20 | `GIT_DIR="<wt>/.git" git commit` (from hub cwd) | block | **gitfile from hub: commits hub files onto wt branch — cross-contamination** |
| T20a | `cd <wt> && GIT_DIR="<wt>/.git" git commit` | allowed | gitfile form from inside the wt |
| T21 | `git -C <foreign-repo> reset --hard` (non-worktree) | block | C5 — foreign keeps gating |
| T22 | `git -C <foreign-wt> reset --hard` (foreign repo's worktree) | block | foreign worktrees not in sessionCwd map (C5) |
| T23 | `cd <wt> && git status` / `git log` | recovery/allowed | read-only unaffected |
| T24 | `cd <wt> && git checkout main` | recovery | recovery ops never resolved |
| T25 | `cd <wt> && git commit && git fetch` | recovery | worktree-exempt + hub recovery mix |
| T26 | `cd /nonexistent && git commit` | block | **failed-cd: cd not applied → hub cwd → gate** |
| T27 | `cd <wt>/subdir && git commit` | allowed | subdir containment (realpath) |
| T28 | `ln -s <wt> <link> && cd <link>/subdir && git commit` | allowed | symlink spelling (realpath both sides) |
| T29 | `cd <wt>/../hub && git commit` | block | traversal out of the wt |
| T30 | clean hub + T1 | gate not consulted | clean-hub no-op (mirror in index test) |
| T31 | worktree session + any git op | gate not consulted | worktree session unchanged (C6) |
| T32 | `cd /tmp \| cd <wt> && git commit` | block | **pipe-cd false exemption (cycle-3 P1): every pipe segment runs in a subshell — commit executes at the hub** |
| T33 | `cd <wt> \| cd /tmp && git commit` | block | pipe-cd mirror (cycle-4 P1: C0 = chain before the first pipe segment; first-segment cds discarded — probe: BOTH pipe spellings print the hub) |
| T34 | stale admin dir: `rm -rf <wt>` (no prune) + `cd <other-wt> && git commit` | allowed | per-entry try/catch — stale entry skipped, other worktrees still exempt |
| T35 | `cd <wt> && cd /nonexistent && git commit` | allowed | failed-cd prefix semantics (state (a)): resolved prefix stands — commit runs at <wt> |

### Backdoor (B)

| # | Command / content | Expect |
|---|---|---|
| B1 | `commandExecutionCwd("cd /x && bash ./s.sh")` → `/x`; `cd /x && cd /y && bash ./s.sh` → `/y` | sequential chain |
| B2 | `commandExecutionCwd('V="/wt" cd "$V" && bash ./s.sh')` → `<wt>` | $VAR cd |
| B3 | `commandExecutionCwd("bash /abs/s.sh")` → sessionCwd | no-cd default |
| B4 | `commandExecutionCwd("(cd /x && bash ./s.sh)")` → `/x` | subshell wrapper |
| B5 | `commandExecutionCwd("cd /nonexistent && bash x.sh")` → sessionCwd | failed-cd: script runs at session cwd |
| B6 | `commandExecutionCwd("cd /x && (cd /y) && bash s.sh")` → `/x` | inner cd does not leak (shared push/pop) |
| B7 | script `git reset --hard`, executionCwd = hub → block | hub-targeted script blocked (disorder-independent, unchanged) |
| B8 | script `git -C <hub> reset --hard`, executionCwd = wt → block | worktree-cwd script hitting hub still blocks |
| B9 | script `cd <wt> && git commit`, executionCwd = hub → allow | worktree-targeted content exempt |
| B10 | script `git commit` (no cd), executionCwd = wt → allow | isolated by execution cwd |
| B11 | script `(cd <wt> && git commit)`, executionCwd = hub → allow | subshell content |
| B12 | `(cd <wt> && bash ./mutation.sh)` — content hub-mutating → block; wt-targeted → allow | end-to-end subshell backdoor (extractScriptPath parens) |
| B13 | `cd <hub> && (cd <wt>) && bash x.sh` — content `git reset --hard` → block | inner wt-cd must NOT leak to exempt a hub-targeted script (cycle-3 P1 flip) |
| B13a | `cd <wt> && (cd <hub>) && bash x.sh` — content `git -C <hub> reset --hard` → block | explicit hub-targeting content |
| B13b | `cd <wt> && (cd <hub>) && bash x.sh` — content `git reset --hard` → allow | script legitimately runs at /wt (subshell cd does not leak — real bash) |
| B14 | **end-to-end closure (P1-verify):** W4 allows `write /tmp/x.sh`; then `cd /tmp && bash x.sh` — content `git -C <abs-wt> commit` → **allow** (map from session repo); content `git reset --hard` (executes at /tmp) → **block** | the exact #1484 vector stays closed (cycle-3 P1: map frame = session cwd) |
| B15 | missing script → allow; recovery/read-only scripts → allow | back-compat (existing call sites pass MAIN) |
| B16 | script at /tmp with content `git -C <abs-wt> commit` → allow | map-frame row (sessionCwd map + executionCwd base) |
| B17 | `cd /tmp \| cd <wt> && bash x.sh` — content `git -C <hub> reset --hard` → block; content `git commit` (no targeting) → block | pipe rule on the backdoor (cycle-4 P1): script executes at the hub |

### Write/edit (dirty hub, hub session — via `resolveTargetTopLevel`)

| # | Target | Expect |
|---|---|---|
| W1 | `<hub>/file.md` | BLOCK (M4) — even under marker (D4 row) |
| W2 | `<wt>/file.md` | ALLOW — THE FIX |
| W3 | `<wt>/deep/file.md` | ALLOW |
| W4 | `/tmp/foo.md` | ALLOW (hub-equality; C5 write-side deviation) |
| W5 | `<hub>/newdir/file.md` (missing dir) | BLOCK (walk-up to nearest existing dir) |
| W6 | `<foreign-repo>/file.md` | ALLOW (walk-up → foreign toplevel ≠ hub) |
| W7 | marker path | BLOCK (audit requirement, downstream) |
| W8 | clean hub + `<hub>/file.md` | BLOCK (permanent gate — M4 inactive, downstream fires) |
| W9 | worktree session + any target | ALLOW (isolated early-return, existing) |

### Degradation (D)

| # | Condition | Expected |
|---|---|---|
| D1 | classify-git load fail | M4 off (existing contract, unchanged) |
| D2 | branch-ownership load fail | M4 fully functional incl. worktree exemption (static assert: no branch-ownership import in classify-git.mjs) |
| D3 | resolveInvocationTarget git/realpath exec fails | conservative block (never false-exempt) |
| D4 | marker active + disordered hub + write to hub | BLOCK (write M4 block stays before marker bypass) |

## Acceptance criteria

- **AC1:** From a hub-rooted session with a disordered hub, every git invocation
  whose effective target is a `git worktree list` worktree (cd, `-C`, same-
  segment `$VAR`, subshell, gitfile-from-inside, subdir, symlinked spelling)
  passes M4 — T1-T3, T13, T19, T20a, T23-T25, T27-T28.
- **AC2:** No bypass and no false exemption: hub/foreign/foreign-wt/
  admin-dir-from-hub/gitfile-from-hub/workTree-mismatch/unresolvable targets
  keep today's block — T4-T12, T14-T18, T18a, T20-T22, T26, T29.
- **AC3:** write/edit M4 block target-aware: hub-targeted writes blocked when
  disordered, even under the marker (W1 + D4); worktree/foreign//tmp allowed
  (W2-W4, W6); missing-dir walk-up blocks (W5); marker-path audit block (W7).
- **AC4:** Backdoor execution-cwd-aware with failed-cd semantics (B5-B6):
  hub-targeted script content blocks even from a worktree cwd (B8); worktree-
  targeted content exempt (B9-B11); subshell-script backdoor closed (B12-B13);
  the write→bash end-to-end closure holds (B14).
- **AC5:** M4's dependency surface unchanged (C2): classify-git.mjs contains
  zero branch-ownership references (D2 static assert).
- **AC6:** `readHubDisorder(process.cwd())` remains the session anchor (C6).
- **AC7:** All existing tests green in BOTH run modes (main checkout and
  worktree): evaluateHubGate contract-identical; scriptGitVerdict call sites
  pass MAIN explicitly; branch-ownership zero-change.
- **AC8:** README + index.ts doc comments updated; eldato dangling symlink
  repaired; symlink farm verified across linked repos.

## Verification plan

1. `node extensions/main-worktree-guard/test.mjs` from the main checkout — full
   suite green (existing 248 + new ~70 assertions).
2. **Smoke:** run the same suite once from a linked worktree of agent-infra
   (`cd .worktrees/<x> && node extensions/main-worktree-guard/test.mjs`) —
   green (AC7).
3. `node extensions/shared/test-branch-ownership.mjs` — green, **zero changes**
   to branch-ownership (proves C2 isolation).
4. Static degradation assert (D2): no `branch-ownership` import in
   classify-git.mjs.
5. **Live e2e** (hot-reload `/reload` in a pi session rooted in the hub of a
   scratch NON-INFRA repo — agent-infra is skipInfra-exempt, the freeze only
   reproduces in non-infra repos; hub dirtied with an untracked file; hub +
   worktree provisioned under a realpath-stable path):
   - `cd <wt> && git commit -am x` → **succeeds** (the incident's freeze case).
   - `git commit -m x` (hub) → **blocked** with the M4 reason.
   - `cd <wt> && git commit && git -C <hub> reset --hard` → **blocked** at reset.
   - `git --git-dir=<hub>/.git/worktrees/<wt> reset --hard` → **blocked**
     (admin-dir attack).
   - `GIT_DIR="<wt>/.git" git commit` from hub → **blocked** (cross-contamination).
   - write/edit under `<wt>` → succeeds; under `<hub>` → blocked.
   - `cd <wt> && bash ./mutation.sh` (hub-mutating content) → blocked;
     worktree-targeted content → runs.
6. `/reload` sanity: extension loads clean; session-start hub warn unchanged.
7. Cross-repo propagation: repair eldato dangling symlink; verify
   `~/.pi/agent/extensions/main-worktree-guard` + linked repos resolve.

## Wiring checklist

- [ ] classify-git.mjs: `allGitInvocations` (exported, extended shape),
      `_SubshellChain` helper, `_resolveCdChain` (failed-cd),
      `_worktreeGitdirMap` (reverse-pointer derivation), `resolveInvocationTarget`
      (semantic predicate + workTree guard + realpath), `evaluateHubGateWithTargets`,
      `commandExecutionCwd`, `extractScriptPath` parens, `scriptGitVerdict` 3rd
      param, `resolveTargetTopLevel`
- [ ] index.ts: defaults block + try-destructure (3 imports); bash gate swap;
      `_backdoorBlock` execution-cwd; write/edit M4 target check; doc comments
- [ ] test.mjs: import list + helpers + matrices + static assert + scriptGitVerdict
      call sites (MAIN) + worktree hygiene + shape regression + realpath-stable
      provisioning
- [ ] README §M4 scope + §D3 wording
- [ ] docs/plans/2026-08-27-issue-347-m4-worktree-freeze.md (this file)
- [ ] Issue #347: scope comment posted; `scoped` label applied
- [ ] **Deployment: eldato dangling symlink repair + symlink farm verification**

## Known limitations / follow-ups

1. **Clean-hub legacy multi-verb resolution (pre-existing, out of scope):** on a
   CLEAN hub, `cd <wt> && git commit && git -C <hub> reset --hard` can still slip
   past the legacy destructive gate. M4's per-invocation resolution blocks it in
   the disordered case. Follow-up: per-invocation resolution in the #265 path.
2. **Worktree-targeted push of a foreign branch (pre-existing #265 gap):**
   worktree-targeted push is exempt as a worktree target, but push mutates the
   shared ref store. Matches today's worktree-session behavior; out of scope.
3. **`$VAR` resolution is same-segment-only**: env-provided vars are
   unresolvable → conservative block. Follow-up: consult `process.env`.
4. **GIT_DIR-from-hub-cwd worktree targeting (T20) is conservatively blocked**
   (cycle-4 P2 rationale corrected): git resolves the gitfile to the wt's admin
   dir and operates on the WT (branch + working tree) — the block is the
   CONTAINMENT POLICY (effectiveCwd = hub is not contained in the wt), a
   deliberate conservative choice; use the cd/-C forms (T20a/T2).
5. **Non-git writes into main** (heredoc/tee/python open) remain a separate
   hygiene issue — follow-up issue to be filed (write-gate warning for
   docs/plans/ in the hub).
5a. **GIT_INDEX_FILE / other index-redirect env vars are not modeled** —
   `GIT_INDEX_FILE=<hub>/.git/index git -C <wt> commit` passes the predicate
   while staging the hub's index onto the wt branch (T20 class via an unparsed
   env var). Deliberate bypass class (adversarial); follow-up if M4's threat
   model includes adversarial agents.
5b. **`-c core.worktree=<path>` redirection**: empirically IGNORED by git 2.50.1
   (no redirection effect) — no hole today; optional hardening note to treat it
   like the workTree hint in the mismatch guard.
6. **W4 write-side relaxation** is the deliberate hub-equality deviation from
   bash-side C5 (writes never mutate git refs); the end-to-end backdoor closure
   (B14) is the compensating control.
7. **Optional hardening (not in scope):** per-sessionCwd worktree-map cache
   (topology is stable within a session); audit `gate_exempted` events for M4
   worktree exemptions.

## Review cycle log (plan-verify)

- **Cycle 1:** Verifier A P1×2 (T9 unreachable → block-verb rows; scriptGitVerdict
  worktree-run breakage → MAIN passed explicitly) + P2×4/P3×3/P4×2. Verifier B
  P1×1 (worktree-admin-dir false-exempt → semantic predicate) + P2×3/P3×3/P4×1.
  Controller: all resolved (plan v2).
- **Cycle 2:** Verifier A P1×3 (T20 contradiction → block; main-checkout
  exclusion in the map; symlink realpath divergence) + P2×1/P3×2. Verifier B
  **P0 (porcelain has NO gitdir column — map rebuilt on reverse-pointer files)**
  + P1×3 (symlink realpath; sessionCwd frame; T20 → block) + P2×3/P3×2/P4×2.
  Controller: all resolved (plan v3 — this file): reverse-pointer map with main
  excluded by construction, realpath both sides, T20 block + T20a, shared
  `_SubshellChain` for commandExecutionCwd, extractScriptPath parens, foreign-wt
  rows, consistency-matrix scoping, eldato symlink repair as deliverable.
- **Cycle 3:** Verifier A P1×2 (B14 map-frame → map at sessionCwd, base at
  executionCwd; stale-admin-dir → per-entry try/catch) + P2×2 (B13 matrix
  contradiction; execSync args-array) + P3×3. Verifier B P1×3 (pipe-cd false
  exemption → pipe boundary in _SubshellChain + T32/T33; per-cd var resolution
  (T3/AC1) → resolve at walk time; B13 contradiction → flip + mirror) + P3×4/
  P4×2. 30/30 T-rows validated by the verifier's own prototype; T20 block and
  T18b allow probe-validated. Controller: all resolved (plan v4 — this file).
- **Cycle 4 (FINAL, cap reached):** Verifier A P1×1 (execSync has no array
  overload → execFileSync) + P3×1/P4×2. Verifier B P1×1 (pipe C0 capture timing
  ambiguous — literal reading made T33 false-exempt; correct reading: C0 =
  chain at the last command boundary BEFORE the first pipe segment, first-
  segment cds discarded) + P2×3 (commandExecutionCwd stop-at-script-token; T20
  rationale; consistency-matrix pipe divergence) + P4×1.
  ⚠️ **CAPPED at 4 cycles — 2 P1s remain, both controller-verified with direct
  evidence:** (1) execFileSync API — probe: execSync array throws, execFileSync
  works; (2) pipe C0 timing — probe: `cd /tmp | cd <wt> && pwd` AND `cd <wt> |
  cd /tmp && pwd` both print the hub. Both folded into plan v5 (this file) +
  T33/B17 rows. Implementation proceeds; the plan's own test matrix (T32/T33/
  T20a/T35/B17) + live e2e + commit-workflow code review are the residual gates.
