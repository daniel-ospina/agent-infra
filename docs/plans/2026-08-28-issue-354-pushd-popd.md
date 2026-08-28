---
title: "fix(main-worktree-guard): recognize pushd/popd cwd-state mutations in _walkShell (conservative false-block) — implementation plan"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-354, main-worktree-guard
---

# Issue #354 — pushd/popd cwd-state recognition in `_walkShell` — implementation plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.
> **SCOPE + PLAN ONLY. Do NOT implement. This is the plan artifact.**

**Goal:** A hub-rooted session that uses `pushd <wt> && git … && popd` is no longer conservatively frozen by M4 hub disorder — the walker recognizes `pushd`/`popd` as real cwd-state mutations (like `cd`), in the **safe direction only** (no bypass).

**Team:** organisation-design-team (agent-infra — shared infrastructure)
**Role:** (unavailable — omit)

**Architecture:** Pure classification change in `extensions/main-worktree-guard/classify-git.mjs` — `_walkShell`'s per-frame chain state machine gains a `pushd`/`popd` branch (mirroring the `cd` branch) plus a per-frame pushd-boundary stack; zero changes to `_resolveCdChain`, `resolveInvocationTarget`, `index.ts`, or the invocation shape contract. Test surface: new m4t + shape/observable pins in `extensions/main-worktree-guard/test.mjs`. Full suite must stay green (currently 508 passed, 0 failed — grown past the 507 in the issue body).

---

## Problem Statement

`_walkShell` (the shared shell-command walker behind `allGitInvocations`, `commandExecutionCwd`, and the M4 hub-disorder gate) recognizes exactly ONE cwd-state builtin: `cd`. `pushd`/`popd` are real bash cwd-state builtins the walker does not recognize — they fall through the generic word path (`onOther`), so no cdChain entry is produced.

**Reproduced (by the #349 plan verifier, confirmed by issue #354):** from a hub-rooted session with a dirty hub,

```
pushd <wt> && git add -A && popd
```

→ **BLOCK**. The walker's cdChain is empty, `resolveInvocationTarget` resolves `effectiveCwd` to the hub, the hub is dirty → M4 freezes a legitimately worktree-targeted op.

**Direction of today's behavior:** conservative false-block only. `pushd` being invisible means git always resolves to the hub → over-gating (never under-gating). Safe direction confirmed by code-read: the generic word path never touches the chain.

**Why fix it:** the exemption mechanism (#347/#349) exists precisely so isolated worktree-targeted ops are not frozen; `pushd`-wrapped compounds are a legitimate form of that isolation. The issue is a conservative false-block improvement for an edge-case builtin form (agents mostly type `cd`; plausibility low), already reproduced and safety-verified.

---

## Confirmed Problem (scoping Phase 2)

`_walkShell`'s cwd-state model recognizes only `cd`, so real `pushd`/`popd` cwd mutations are invisible → worktree-targeted git ops in pushd-wrapped compounds resolve to the hub → conservative false-block (M4 freeze). The fix must add `pushd`/`popd` to the cwd model **without introducing an unsafe direction** — i.e., no invocation may resolve to a worktree while bash's real cwd is the hub.

**Evidence:**
- Code-read of `_walkShell` (line ~587): only `t === "cd"` has a chain-push branch; `pushd`/`popd` reach the generic `!isGitToken` path.
- Bash probes (2026-08-28, macOS zsh/bash 3.2+ semantics verified in bash): the four decisive cases are pinned in the test spec below (mixed pushd/cd/popd restores the **pre-pushd** cwd — see Design Decision D1).
- Issue body + #349 verifier reproduction.

**Falsification check:** any new test in which the resolved chain says "worktree" while a bash probe shows the real cwd is the hub → the design is unsafe and must not ship. The test spec below pins exactly these cases.

**Confidence:** 90/100.

---

## Solution Approach (chosen — B, see Rejected Alternatives)

Two new branches in `_walkShell`'s main loop, placed immediately after the existing `cd` branch, guarded by the same command-position test (`prevWasBoundary && !spawnerPending` — a `pushd` after a spawner like `sudo pushd` runs in a subprocess and must NOT mutate the parent chain, mirroring `cd`):

### Design Decision D1 — `popd` restores the PRE-pushd chain state (not "pop the last entry")

The issue body's naive prescription — "popd pops the last entry" — **diverges from bash when a `cd` intervenes between `pushd` and `popd`**:

- Bash probe: `pushd <wt>; cd subdir; popd` → real cwd is **the hub** (popd restores the directory that was current before the pushd).
- Naive pop-last chain: `[wt, subdir] → pop → [wt]` → git resolves to the worktree → **ALLOWED while bash runs git in the hub → BYPASS** (hub mutation undetected if the hub is dirty).

Correct model: each `pushd` records the chain length at push time on a per-frame pushd-stack; `popd` truncates the chain back to that length. Probe-verified to match bash in every case tested (paired pushd/popd, intervening cd, nested pushd, cd-then-pushd):

| Command | bash cwd after popd | chain after popd (this design) |
|---|---|---|
| `pushd wt; popd` | hub | `[]` |
| `pushd wt; cd sub; popd` | hub | `[]` |
| `cd wt; pushd hub; popd` | wt | `[wt]` |
| `pushd a; pushd b; popd` | a | `[a]` |

For the common paired form (`pushd <wt> && git … && popd`) truncate-to-boundary and pop-last are identical; they differ exactly where pop-last is unsafe.

### Behavior spec

1. **`pushd <target>`** (command position): like `cd` — push `_expandCdVars(target, f.segVars)` onto the frame's `chain` (same prior-segment var expansion, same subshell/pipe scoping because the chain is per-frame), and push the current chain length onto the frame's `pushtack`. Set `prevWasBoundary = false` (mirroring the cd branch's post-condition, line ~604).
2. **Bare `pushd` / `pushd <boundary>` / `pushd -<flag…>`** (incl. `-n`, `+N`, `-N`, `--`): push a **null marker** onto the chain → conservative block. Rationale: bare `pushd` swaps the stack top (error with a 1-entry stack — probe: exit 1, cwd unchanged); `-n` never changes cwd. Modeling either as a cd would be wrong; null = conservative.
3. **`popd`** (command position, no arg consumption): if `pushtack` non-empty → `chain.splice(pushtack.pop(), …)` (truncate to the pre-pushd state, D1). If empty → push a **null marker** (bash errors without changing cwd — probe: exit 1, cwd unchanged; conservative over-gating is safe here). Set `prevWasBoundary = false` (mirroring cd).
4. **Scoping:** the `pushtack` lives on the same per-frame state as `chain`/`vars`: subshell `(` inherits a **copy** (bash subshells inherit a copy of the dir stack), `)` discards it, `&` clears the chain (boundary true) leaving at worst a stale pushtack entry whose only effect is a spurious truncation → conservative, never a bypass. Pipe segments: the existing `|` chain-reseed already drops segment pushd effects (verified: `pushd wt | cat && git commit` → chain `[]` → hub → block); stale pushtack entries after a pipe are again conservative-only. **No changes to `|`/`&`/`(` handling.**
5. **No changes to:** `_resolveCdChain` (null-marker semantics already conservative), `resolveInvocationTarget` (consumes the chain as-is), `commandExecutionCwd` (reads the same shared chain via `onScriptToken` — pushd/popd flow through automatically), the emitted invocation shape, `index.ts`.

### Files touched

| File | Change |
|---|---|
| `extensions/main-worktree-guard/classify-git.mjs` | +`pushtack` field in the frame literal (~line 565) and the subshell frame copy (~line 611); +pushd/popd branch after the cd branch (~line 608). ~35 lines. |
| `extensions/main-worktree-guard/test.mjs` | +12 m4t pins + 7 shape/observable pins (~new `#354` section after the shape-regression block). 19 assertions. |

## Testing strategy

Run: `node extensions/main-worktree-guard/test.mjs` (full suite must stay green — currently 508 passed, 0 failed).

New pins (m4t — `evaluateHubGateWithTargets(cmd, "main", hubR)`; fixtures: dirty hubR, wtR worktree):

```
T122 pushd wt && git commit -m x && popd                      → allowed   (THE FIX — issue indicator 1)
T123 pushd hub && git commit -m x                             → block     (chain [hub] → hub)
T124 pushd && git commit -m x                                  → block     (bare pushd → null marker)
T125 cd wt && pushd hub && git commit -m x                     → block     (chain [wt, hub] → hub)
T126 pushd wt && cd subdir && popd && git commit -m x          → block     (D1: popd restores hub — bypass pin)
T127 pushd wt && popd && git commit -m x                       → block     (popd returns to hub)
T128 cd wt && pushd hub && popd && git commit -m x             → allowed   (popd returns to wt)
T129 pushd -n wt && git commit -m x                            → block     (flag form never cds → conservative)
T130 pushd wt | cat && git commit -m x                         → block     (pipe segment does not leak)
T131 ( pushd wt ) && git commit -m x                           → block     (subshell does not leak)
T132 pushd wt && pushd hub && popd && git commit -m x          → allowed   (nested pushd — popd restores the 1st pushd target; exercises pushtack bookkeeping)
T133 pushd wt && pushd hub && popd && popd && git commit -m x  → block     (double popd — restores hub)
```

Shape/observable pins (`expectBool` + `allGitInvocations`/`resolveInvocationTarget`):

```
#354: pushd target lands in cdChain at the git invocation       ([wtR])
#354: resolveInvocationTarget → worktree for pushd-wrapped git   (isWorktree === true)
#354: popd after git empties the chain (restores hub)            (cdChain.length === 0)
#354: empty-stack popd → null marker (conservative)              (cdChain[0] === null)
#354: popd restores PRE-pushd chain across an intervening cd     (cdChain.length === 0 — T126 shape pin)
#354: nested pushd single popd restores the 1st pushd target      (allGitInvocations(`pushd wt && pushd hub && popd && git commit`)[0].cdChain.length === 1 && cdChain[0] === wtR — T132 shape pin)
#354: background & clears chain, stale pushtack pop is a no-op     (allGitInvocations(`pushd wt && git commit -m x & popd && git commit -m x`)[0].cdChain[0] === wtR && [1].cdChain.length === 0 — first inv allowed, second blocked)
```

All existing tests must stay green (T45a bare-cd null marker, the #347/#349 shape pins, M4/M4M suites).

## Verification plan

1. `node extensions/main-worktree-guard/test.mjs` → 0 failed (was 508 passed; expect 527 with the 19 new assertions).
2. Manual bash cross-check (documented in the PR): all four D1 probe cases (pushd;popd / pushd;cd;popd / cd;pushd;popd / nested pushd) are pinned by tests — T127, T126, T128, T132 — and match real bash.
3. No git/fs/network surface touched; no config; no migrations.

## Acceptance criteria

- [ ] Indicator 1: `pushd <abs-wt> && git add -A && popd` from a hub-rooted session with a dirty hub returns `allowed`.
- [ ] Indicator 2: `allGitInvocations('pushd <wt> && git commit')` carries a cdChain entry for `<wt>`.
- [ ] Indicator 3: `cd` semantics unchanged — all existing M4 tests stay green.
- [ ] No bypass: T126 (`pushd wt; cd sub; popd; git commit`) → block, matching the bash probe.
- [ ] Full suite green (508 + 19 new assertions).

## Runtime prerequisites

None beyond Node (the existing test harness). No new dependencies.

## Rejected Alternatives

- **A — "popd pops the last chain entry" (the issue body's naive prescription).** Simpler (no pushtack field) but introduces a **bypass**: `pushd <wt> && cd subdir && popd && git commit` would resolve chain `[wt]` → allowed while bash's real cwd is the hub → hub mutation undetected. Rejected on safety; the issue's own stated property is "no bypass — conservative false-block". Would be better only if bash's popd ignored intervening cds — empirically false.
- **B (CHOSEN) — pushd/popd with per-frame boundary stack.** Exactly matches probed bash semantics in every case; no bypass; modest extra state (one small per-frame array). This is the quality choice.
- **C — document-only (README note "pushd/popd unsupported → conservative block").** Zero code risk but fails indicator 1 of the issue contract; the exemption mechanism exists to avoid freezing legitimate worktree-targeted ops, and the fix is probe-verifiable with bounded risk. Rejected because it keeps a known false-block when a safe fix exists.
- **D — full dir-stack emulation (`dirs`/`pushd +N`/`popd +N`/`cd -`).** Overkill for a micro tier; the +N/-N index forms are exotic in agent commands, and every such form errs conservative under this design (flag args → null marker). Documented residual: `pushd -n` (stack-only) and indexed forms are conservatively blocked, never mis-allowed.

## Learnings (post-implementation)

(TBD — implementer to append any gotchas here.)
