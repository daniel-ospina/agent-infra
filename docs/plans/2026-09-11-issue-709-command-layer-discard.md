---
title: "#709 — gate the working-tree-discard family at the command layer — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-709, issue-664, issue-678, issue-617, issue-623, issue-744, main-worktree-guard
---

# Issue #709 — Gate the working-tree-discard family at the command layer

**Issue:** [#709](https://github.com/daniel-ospina/agent-infra/issues/709) · **Complexity:** standard · **Date:** 2026-09-11

## Objective

Intercept the working-tree-discard family at the **command layer** for the actor that
actually performs it — including `task` / `pi -p` sub-agents — keyed on the command's
**effect on uncommitted tracked work**, not on whether the argv matches a blocked git
verb.

## Confirmed problem

`extensions/main-worktree-guard` gates *git argv*, not the *effect*, and it exempts
worktrees wholesale for the destructive-verb arms:

| Command | Hub (main) | Linked worktree |
|---|---|---|
| `git checkout -- <dirty path>` | **allow** (`classifyGitCommand` pinned `allow` at `test.mjs:108`) | allow |
| `git checkout <tree-ish> -- <path>` | allow | allow |
| `git restore <path>` | `block:restore` | **exempt** (`eff.isWorktree`) |
| `git checkout .` / `-f` | `block:checkout-discard-all` / `block:force-checkout` | **exempt** |
| `git reset --hard` / `git clean -fd` | `block:reset` / `block:clean` | **exempt** |

The 2026-09-10 incident (an unrestored mutation-test mutant in the shared hub,
[#664](https://github.com/daniel-ospina/agent-infra/issues/664)) is exactly the first
row: the discard that matters is the one that classifies `allow`. The M4 hub-state gate
does block `git checkout -- <path>` *while the hub is disordered* (`test.mjs:2247`) —
the clean-hub case, and every worktree case, are open.

Sub-agents: `spawnSubAgent` strips `AGENT_ALLOW_MAIN_EDITS`/`ELDATO_ALLOW_MAIN_EDITS`
(#617/#623) and `main-worktree-guard` is not disabled by `SKILL_ENFORCER_DISABLED`, so
the guard **is** the enforcement surface for `pi -p` children — it just doesn't cover
the discard family.

## Design

A new **effect-keyed** arm (M5) in the bash branch of `main-worktree-guard/index.ts`,
fed by a new pure classifier export in `classify-git.mjs`:

```
extractWorkingTreeDiscards(command)
  → [{ inv, verb, args, scope: "all" | "paths", pathspecs: string[], form: string }]
```

Family (token-level, from `allGitInvocations`):
- `checkout` — `-- <pathspec>…`, `<tree-ish> -- <pathspec>…`, bare `.`/`./…`/`:/…`,
  `-f`/`--force` (scope `all` when no pathspec)
- `restore` — worktree restore (bare, `--worktree`, `-s <tree>`); **`--staged`-only is
  index-only and stays allow**
- `switch` — `-f` / `--force` / `--discard-changes`
- `reset --hard` — scope `all` (or the paths after `--`)
- `checkout-index -f` / `-a`
- non-git revert shape: `git show <rev>:<path>` / `cat-file` whose stdout is redirected
  onto a tracked path
- **script files** — `bash /tmp/undo.sh` / `source f` are read (depth ≤ 3, ≤ 64KB) and
  the same extraction runs on their content; M4's `_backdoorBlock` returns early for
  worktrees, so this is the one surface a worktree `pi -p` child could otherwise hide in.

Deliberately NOT in the family: `git clean` (untracked-only — `git clean -fdx` build
artifact cleanup in a private worktree is ordinary, and the M4/legacy arms still block
it in a shared main checkout) and `git stash push` (stores; does not discard).

Effect decision (the whole point): resolve the invocation's effective cwd
(`resolveInvocationTarget`), run a **bounded** `git status --porcelain=v1 [-- <paths>]`
there and block **only** when the discard would destroy uncommitted state:

- scope `all` → any tracked entry (X or Y ≠ ` `, `??`/`!!` excluded)
- scope `paths` → any listed path with a **worktree-vs-index** difference
  (`Y ≠ ' '`), since `checkout --`/`restore` restore from the index; tree-source
  forms (`checkout <tree> --`, `restore -s`) also consider `X ≠ ' '`
- untracked-only dirt → **allow** (`checkout -- .` does not delete untracked files)

Consequences:
- `git checkout -- <clean file>` stays allow → ordinary work unaffected.
- `git restore --staged <file>` stays allow → index-only, per the issue's own note.
- `ls`, `cat`, `git status`, `git log`, `git diff`, `rg` stay allow → read-only proof test.
- The deliberate-discard case (dirty target) blocks **in both hub and worktree**, and the
  block reason directs to the copy-based probe recipe (#664) — never mutate in place.

### Escape hatches preserved (unchanged)

The arm is placed **after** the existing `_isAllowMainEdits() ||
readAllowMarkerState(...)` return in the bash path, so:
- the env hatch (`AGENT_ALLOW_MAIN_EDITS=1` / `ELDATO_ALLOW_MAIN_EDITS=1`) bypasses it;
- the `~/.pi/agent/.allow-main-edits` marker (stamped JSON, session-scoped, 15-min TTL)
  bypasses it;
- `SKILL_ENFORCER_DISABLED` is untouched (and is not read by the guard).

No change to `classifyGitCommand`/`classifyGitCommandDetailed` verdicts → the frozen
`allow` pins and the M2/M3/M4 arms are byte-identical. M5 only **adds** blocks on top.

## Wiring

| Surface | Wiring point | Test |
|---|---|---|
| `classify-git.mjs` | new exports `extractWorkingTreeDiscards` + `discardDestroysWip` (pure) | `test-discard-gate.mjs` Part A |
| `index.ts` loader | M5 exports read from the cached module namespace (NOT added to the destructuring assignment — each new target there is a new `test-module-load.mjs` Part A assertion, and that suite's contract is exactly 49/0) + typeof skew guards | `test-module-load.mjs` 49 passed / 0 failed, real load with 0 degradation warnings |
| `index.ts` bash arm (M5) | `_worktreeDiscardBlock(command)` after the marker/env return, before the degradation/full classifier arms | `test-discard-gate.mjs` Part B (hub + linked worktree, dirty/clean) |
| script-file surface | `extractScriptPath` + bounded content walk inside `_worktreeDiscardBlock` | `test-discard-gate.mjs` B6e/B6f |
| `pi -p` sub-agent | `spawnSubAgent` strips the env hatch (#617/#623); M5 runs in the child's process (env hatches removed in Part B; `SKILL_ENFORCER_DISABLED=1` set) | `test-discard-gate.mjs` Part B |
| escape hatches | arm sits after the hatch return; no change to marker parser/env checks | `test-discard-gate.mjs` B11a–d |
| negative controls | clean targets, untracked-only dirt, `--staged`, read-only commands | `test-discard-gate.mjs` B5/B7a/B8 |

## Verification checklist

| Surface | Layer | Expected |
|---|---|---|
| classification | unit | every family form extracts with the right scope/pathspecs; `--staged` excluded |
| effect | unit | dirty hub target blocks; dirty **linked-worktree** target blocks; clean target allows |
| `all` scope | unit | `checkout .` / `-f` / `reset --hard` / `clean -fd` block iff a tracked entry is dirty |
| read-only | unit | `ls`, `cat x`, `git status`, `git log`, `git diff`, `rg x` all allow |
| index-only | unit | `git restore --staged f` allows |
| hatches | unit | env hatch + marker bypass M5 |
| module load | unit | `test-module-load.mjs` stays **49 passed / 0 failed** |
| full suite | unit | `test.mjs` no new failures (baseline on `origin/main`: 1786 passed / 2 failed) |
| behavioral | new suite | `test-discard-gate.mjs` 79 passed / 0 failed |

## Non-goals / residuals

- Not blocking all git in worktrees — only the discard family, and only when it destroys
  uncommitted tracked work.
- Not extending the write-tool/main-worktree-guard hub write gate to worktrees: ordinary
  tracked-file edits in a worktree are the point of a worktree (the #625 in-place
  *overwrite* gate keeps its existing hub scope; the M5 non-git arm covers only the
  `git show <rev>:<path> > <path>` revert shape).
- Documented residual: `cp backup file` / arbitrary interpreter writers that rewrite a
  tracked file from a non-git source are not detected as discards (indistinguishable
  from an edit without reading content). Tracked as a follow-up if the fleet needs it.
- Probe failure (`git status` errors) is fail-safe allow, matching the codebase's
  existing write-gate convention ("never false-block"); an unresolvable invocation
  target (`$VAR` cd chain) or pathspec fails **closed**.
- Script-file discards are covered to a bounded depth (`bash /tmp/undo.sh`); a chain
  deeper than 3 is a documented residual (same class as the #627 residual).
