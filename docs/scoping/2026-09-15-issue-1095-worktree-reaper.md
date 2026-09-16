---
title: "#1095 — worktree reaper + retention policy — Scope"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-15
aboutSubjects: git-worktrees, disk-reclamation, organisation-design-team
aboutObjects: agent-infra, issue-1095, pi-reap-worktrees.sh, pi-reap-worktrees.test.sh
---

# Scoping — #1095: worktree reaper + retention policy

**Issue:** [daniel-ospina/agent-infra#1095](https://github.com/daniel-ospina/agent-infra/issues/1095)
**Tier:** Standard (introduces a script under `scripts/`; `parallel_work_check.sh` C1 = `CLEAR no-board-skip`)
**Date:** 2026-09-15
**Branch:** `feat/1095-worktree-reaper`

---

## 1. Problem diamond

### 1.1 Framings diverged

| # | Framing | Verdict |
|---|---|---|
| F1 | **"Add a cron that deletes worktrees older than N days."** The literal ask, and what a naive reader implements. | **Rejected.** This is the exact rule the 2026-09-15 manual sweep falsified: 7 worktrees held real uncommitted work, 3 more had non-`.venv` changes, 1 had an active PR branch, and 71 `/private/tmp` worktrees (3–5 days old) mapped to live issues #2985/#2952/#3018/#3005/#3061. Age alone is a *destroyer of live work*. |
| F2 | **"Stop worktrees being created."** Prevent sprawl at the source. | **Rejected as the fix, retained as an observation.** The creator-side fix already exists (`hub-worktree.sh`, `using-git-worktrees` hub discipline) and the sprawl still happened — the manual sweep is the evidence that creation-side discipline is not sufficient. Reaper is the missing half. |
| F3 | **"Make the fleet's searches bounded instead."** Fix #1069/#928 by excluding `.worktrees/*` from search tooling. | **Rejected as the fix.** It treats the symptom (`grep -r` cost) and leaves 179 GB / 2.36 M files on disk, which also drives host load (25–35 on 10 CPUs) and the 300-worktree `collision_preflight.py` blind spot. Bounding searches is a separate, complementary mitigation, already tracked by #1069. |
| F4 | **"A reaper that classifies each worktree by whether removing it can lose anything, and only removes what provably cannot."** | **Chosen.** It is the framing the manual sweep actually used (163 removals, zero data loss), it is the only framing that satisfies the issue's own safety prose, and it is falsifiable per-worktree: every `remove` carries a survival argument. |

### 1.2 Root cause

Worktrees are cheap to create and have **no owner, no TTL, and no reclamation path**. `git worktree remove` exists but nothing calls it. The cost of a worktree is not the repo's ~2 GB of content but the per-worktree amplification (its own checkout + `.venv` + `node_modules`), and that amplification is charged to *every* repo-wide walk. This is a **missing reclamation mechanism**, not a search-performance bug and not a creation-discipline bug.

### 1.3 Hard constraint discovered in the problem diamond

The host is at load ~16 on 10 CPUs and a prior incident wedged whole sessions with **unbounded filesystem searches**. `tortoise` has 2.36 M files and `find . -type f | wc -l` alone took 188 s. **The reaper is itself a filesystem-walking program.** A reaper that walks the tree to decide is strictly worse than no reaper: it adds load to the exact machine state it was written to relieve. This constraint is a *first-class design input*, not an implementation detail — see §3.

### 1.4 Confirmed problem

> Nothing reclaims worktree checkouts, so they accumulate without bound and amplify every filesystem operation the fleet performs. A safe reclamation pass must be able to prove, per worktree and without walking repository content, that removing the checkout cannot destroy work — and must surface, never auto-remove, anything it cannot prove.

**Falsification check:** if a worktree exists whose checkout can be removed while destroying work, the classification is unsound. The five measured preserve categories (dirty, non-venv-dirty, active PR, detached-unreachable, too-recent) are the adversarial set, and each is a test fixture (§5).

---

## 2. Gate semantics — the one genuine ambiguity, resolved

The issue body states the gates as a flat conjunction ("Removal is safe iff **all** of: merged, aged, clean, unreferenced, reachable"), but the issue's own measured table contains the row:

> `Stale-unmerged, no open PR | 48 | removed (branch retained)`

A literal reading of "all of, including merged" contradicts that row: 48 unmerged worktrees were removed. Three independent signals in the issue resolve the contradiction in favour of the measured table:

1. The Notes: *"`git worktree remove` deletes the checkout, never the branch, so named-branch worktrees lose no commits."*
2. The `/private/tmp` lesson and the issue's own hard rule: *"anything failing `clean`, `reachable`, or `unreferenced` must be surfaced with its deciding reason, and NEVER auto-removed."* — **`merged` and `aged` are absent from that never-auto-remove list.**
3. The task's required test fixtures: *dirty, detached-unreachable, live reference, open PR, too-recent* — again **no "unmerged" fixture.**

**Resolution (the gate is `commits-survive`, not `merged`):**

| HEAD kind | Commits survive because | Gate |
|---|---|---|
| Named branch | the **branch ref is retained** by `git worktree remove` (only the checkout dies) | passes |
| Detached, SHA reachable from **any** ref (`git for-each-ref --contains`) | that ref still points into the history | passes |
| Detached, SHA reachable from **no** ref | nothing holds the commit → removal **orphans** it | **PRESERVE** |
| Merged to `main` (same as detached-reachable-via-main, or a merged named branch) | `main` holds the history | passes (reported as `merged`) |

`merged` is therefore **reported, not binding** — the output names which mechanism keeps the commits alive (`refs=merged` / `refs=branch-retained:<branch>` / `refs=reachable-from:<ref>`), because the issue requires *"Say so in the output so the operator can trust it."* A report that merely said "remove" without naming the survival mechanism would be untrustworthy precisely where trust matters.

**Cost of the resolution (accepted, and recorded rather than hidden).** This *does* relax the issue's literal five-gate conjunction, so `merged` is no longer an independent check on the named-branch path: the operator's only signal that an unmerged branch was never landed is the reported `refs=branch-retained:<branch>`. Two mitigations are in the output — the survival mechanism is always named, and the branch name is always printed. The alternative reading (require `merged` for every removal) contradicts the issue's own measured table and its never-auto-remove list, and would leave the 48-row class permanently unreclaimable; §7.8 states the deviation as an acceptance condition.

### 2.1 Binding gates (all must pass for `remove`)

| Gate | Check | Mechanism | Boundedness |
|---|---|---|---|
| clean | `git status --porcelain --ignored=traditional -unormal` is empty, except **root-level** entries on the declared-ephemeral allowlist (`.venv node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .cache .DS_Store`) | git index + collapsed untracked/ignored dirs | **index-bounded**; `-unormal` collapses an untracked dir to one entry, so `.venv`/`node_modules` are never enumerated. Hard per-call timeout → fail-closed preserve. |
| unreferenced-process | no live process's argv contains the worktree path, and the reaper's own cwd/ancestors are not inside it | one `ps -axo pid=,command=` pass | **process-table-bounded** |
| unreferenced-PR | the named branch is not an open PR head-ref | **one** batched `gh pr list --state open --json headRefName` | one network call; fail-closed (gh missing/offline ⇒ `pr-unknown` ⇒ **preserve**) |
| reachable | detached HEAD only: SHA reachable from some ref | `git for-each-ref --contains=<sha> --format=%(refname)` | ref-bounded commit-graph walk; short-circuits on first hit |
| aged | last commit `> AGED_DAYS` (default 7) | `git log -1 --format=%ct` | O(1) |

Exactly ONE gate decides each row — the first one that fails — evaluated in this order (mirrored in the script header and in `classify_one()`):

```
unparseable-path (poisoned record) > bare > main-checkout > self-checkout >
unreadable-path | prunable > worktree-locked > live-process > live-cwd >
dirty | ignored-artifact | status-timeout | status-error >
detached-unreachable > open-pr > too-recent > reclaimable
```

The report prints **one** deciding reason per row, not every failing gate: the operator's question is "why was this *not* removed", and the first failure is the actionable one (the rest are reachable by re-running after fixing it, or by `--list`).

**`--ignored=traditional` IS used, with a narrow allowlist (review cycle 1, P0).** The first draft dropped `--ignored` on the theory that it would flag every `node_modules` and make the reaper a no-op. That was a **false dilemma**, verified: git collapses a fully-ignored directory to a single `!! node_modules/` line, so the ignored check is index-bounded too. Dropping it was a genuine data-loss hole — `git worktree remove` does **not** refuse ignored files (verified: an ignored `.venv` was deleted silently, and with it would go a gitignored `.env` or experiment output that the clean gate never saw). The gate therefore reports `ignored-artifact` → **preserve** for anything ignored that is not on the ephemeral allowlist. The allowlist is deliberately narrow (build/venv caches reproducible from a manifest); `dist/`, `build/`, `target/`, `.next/` are **not** allowlisted — over-preserving is the correct direction, and the operator sees the offending path in the reason.

Allowlisted entries must be deleted before removal when they are *untracked*: `git worktree remove` (no `--force`) refuses on untracked files (verified). That pre-delete is a recursive filesystem delete over a checkout the reaper does not control, so it runs under the same `REAP_WT_REMOVE_TIMEOUT` watchdog as the removal itself — see §3.3.9. Ignored entries need no pre-delete — git removes them itself. `--force` is never passed; git's refusal is a real second gate, and a refusal is **reported and counted** (`REMOVE-FAILED`), never swallowed.

### 2.2 Preserve paths (never auto-removed)

`main-checkout` · `bare` · `self-checkout` · `worktree-locked` · `live-process` · `live-cwd` · `dirty` · `ignored-artifact` · `status-timeout` · `status-error` · `detached-unreachable` · `open-pr` · `too-recent` · `unreadable-head` · `unreadable-path` · `unparseable-path` · `deferred` — plus `missing-dir`, which is **`remove` / `reason=prunable`** (a vanished checkout has nothing to lose; only the admin record is pruned — §3.4).

Two of these are the **cycle-2 P0s** (both were a false PASS on the reachable gate, the one gate whose failure is unrecoverable):

- **`unreadable-path`** — `canonicalize` returning `""` was read as "the directory is gone", so a checkout that merely could not be resolved (permissions, unmounted parent) was classified `prunable` and **deregistered while it was live**. `canonicalize` failing means *cannot resolve*, never *absent*: the two are now distinguished by an explicit `-e || -L` existence test, and an existing-but-unresolvable path is preserved and its record protected from the end-of-pass `prune` (G9).
- **`prunable` + unreachable detached HEAD** — the gone-directory branch returned `remove` *before* the commits-survive gate, so a vanished worktree whose HEAD was a detached SHA on no ref would have its admin record pruned, leaving that commit on **no ref at all**. The commits-survive gate now runs on **every** removal path including this one, and the unreachable case is `preserve` + prune-blocked (G10).

The `unreferenced` gate has two independent probes plus a third layer:

- **argv** (`ps -axo`, one pass) — catches `pi --cwd <path>`, shells, editors;
- **cwd** (`lsof -a -d cwd -Fpn`, one bounded pass — never the `+D` directory walk) — catches a process that merely `cd`-ed in, which argv cannot see. Best-effort: a missing/slow `lsof` sets `CWD_PROBE=degraded` in the footer instead of silently passing;
- **path canonicalization** — `git worktree list` records the **resolved** path (`/tmp/x` is stored as `/private/tmp/x` — verified), while a process's argv keeps whatever was typed. Every comparison therefore resolves both sides, and an argv token sharing the candidate's basename is canonicalized before comparison. Without this the gate silently misses exactly the `/private/tmp` scratch class the incident notes call out. (Review cycle 1, P1.)

---

## 3. Solution diamond

### 3.1 Approaches diverged

**S1 — Extend `scripts/stale-worktrees.sh`.**
Reuse the existing dry-run-first worktree script.
*Rejected on safety and scope, not convenience.* Its gates are different ones: it requires **no remote ref and no open PR** and **skips every detached HEAD** — i.e. it refuses exactly the 48 unmerged-but-branch-retained worktrees the manual sweep removed, and cannot touch any of the `/private/tmp` detached scratch. Retrofitting the new classification would silently widen an existing, separately-relied-upon tool's blast radius, and its boolean chain cannot express a per-worktree *deciding reason* (an explicit acceptance criterion).

**S2 — A launchd/cron sweep that calls `git worktree remove` directly.**
*Rejected.* Same destruction risk as F1; no classification.

**S3 — `scripts/pi-reap-worktrees.sh`: classify-from-metadata, dry-run by default, `--apply` to arm.**
*Chosen.* Matches the repo's existing reaper precedent (`pi-reap-idle.sh`): same CLI shape (`--dry-run` default / `--apply` / env seams / `MODE=` log footer / `STATE_DIR` lock), same fail-closed posture, same hermetic test layout (`<script>.test.sh`).

### 3.2 Why S3 over S1 (quality, not convenience)

S1 is "fewer files to touch". S3 is better on every axis that matters here: it does not widen an existing tool's blast radius, it can express a per-worktree *deciding reason* (S1's boolean chain cannot), it can report the survival mechanism, and it can be armed independently. The duplication is real and acknowledged: both scripts call `git worktree remove`, but they encode different policies (S1: "surely-abandoned remote-less branches", S3: "checkout reclaimable without losing anything"). `stale-worktrees.sh` / `cleanup-worktree.sh` / `hub-worktree.sh` are left untouched.

### 3.3 Boundedness — the "cannot hang the fleet" argument

This is the load-bearing design property. Every probe is O(refs), O(processes), O(index), or O(commit-graph). **No probe recurses a working tree.**

1. **Enumeration is `git worktree list --porcelain`** — reads `.git/worktrees/*` admin files only. Never `find .worktrees -maxdepth 1`, never a directory walk.
2. **Clean gate uses `--untracked-files=normal`**, so git stops at the first level of an untracked or ignored directory. `.venv/`, `node_modules/`, and any other large dir cost one `lstat`, not an enumeration — **verified**: 60 files under an ignored `node_modules` report as one `!! node_modules/` line, and `-uall` (which would enumerate them) is never used.
3. **Hard per-probe timeout** (`REAP_WT_STATUS_TIMEOUT`, default 20 s; `REAP_WT_PS_TIMEOUT`; `REAP_WT_CWD_TIMEOUT`; `REAP_WT_GH_TIMEOUT`) implemented by a watchdog subshell (macOS has no GNU `timeout`). A timeout is not "clean": it is `status-timeout` ⇒ **preserve**. A reaper that hung the fleet was the explicit risk to avoid, so the slow probe fails closed.
4. **Global wall-clock budget** (`REAP_WT_BUDGET_SECONDS`, default 300 s) bounding the **per-worktree loop** — classification and removal. On overrun the pass stops, marks every remaining worktree `deferred` (preserve) in the output and the log, and exits 0 with a footer that says so.
   The clock deliberately starts **at the loop, not at process start** (cycle-2 fix). Enumeration, `ps`, and `lsof` already have their own watchdogs, so charging their latency to the same budget meant that on a loaded host the setup alone could exhaust it — every worktree deferred, every pass, forever: a reaper that silently never reaps. The first draft's own test caught this (its 1 s budget deferred all three worktrees because *setup* had already consumed it).
5. **Fork economy is part of boundedness.** The tool exists to *unload* a host, so its own process churn is a design constraint, not a micro-optimization. Each bounded probe previously cost two `mktemp` forks plus a `pkill -P` — an exec plus a **full process-table scan** — and leaked one `sleep` per probe. Now one scratch directory is created per pass, and the watchdog holds its own timer as a child so a `TERM` tears the timer down; no `pkill` is needed at all, and the leak is fixed rather than papered over. Measured effect on this host at load ~55: a 4-worktree pass went from **47 s to 17 s** wall clock.
6. **`ps` is one pass** and **`lsof -a -d cwd` is one pass**, not per-worktree. `gh pr list` is **one call for the whole pass**, not per-branch.
7. **No `find`, no `rg -r`, no `du`, no `lsof +D`, no recursive glob is executed anywhere in the script.** `du` is not used at all — see §3.5.
8. **Self-protection:** the reaper never removes the worktree that contains its own cwd, nor any worktree whose path is an ancestor of its cwd (compared canonically).
9. **Removal is the one genuinely unbounded filesystem operation** — `git worktree remove` recursively deletes the checkout, and the allowlisted-ephemeral pre-delete (`rm -rf` on a `.venv`/`node_modules` at the worktree root) is the same class of delete on a checkout the operator does not control. **Both** run under `REAP_WT_REMOVE_TIMEOUT` (120 s) and count against the global budget; a timeout leaves the admin record intact and reports `REMOVE-FAILED`. The pre-delete was the last unbounded fork on the removal path (closed in §9 cycle 3): a huge or NFS-locked `.venv` could block it indefinitely, and because the old code discarded its status the block left *no trace* — the pass went on to report a clean `REMOVED=1`. It now returns `REMOVE-FAILED` (⇒ `exit 4`) instead of continuing, since an ephemeral that survived its deletion is a directory `git worktree remove` refuses on anyway.

Corrections accepted from review cycle 1 (P2): the earlier draft claimed `git for-each-ref --contains` "short-circuits on first hit" — **it does not** (verified: it printed all four containing refs). It is bounded by the reachable history of the refs it walks, and `--count=1` caps the *output*, not the walk; it runs only for a detached HEAD that failed the merged check. Also noted: "reachable from any ref" includes remote-tracking refs, which a later `fetch --prune` can drop — the output therefore **names the holding ref**, so the operator can judge; and `main` ⟹ reachable, so the walk is skipped for merged detached HEADs.

### 3.4 Idempotence, and the `missing-dir` / prunable case

A worktree whose directory has already been deleted appears in `git worktree list --porcelain` as an entry with a vanished path (git marks it `prunable`). There is no checkout to lose, so it is classified `remove` / `reason=prunable` **only after the commits-survive gate passes** — the admin record's `HEAD` is itself the last ref holding a detached commit, so pruning it can orphan that commit (§2.2, G10). Removal in `--apply` mode is by `git worktree prune` (the admin record only).

`git worktree prune` has **no path filter**, so it cannot be aimed at the records we decided to reclaim: a global prune would also deregister any *preserved* record that git happens to consider prunable. The prune therefore runs **once, at the end of the pass, and only after checking that no preserved record could be prunable**; if one could (`unreadable-path`, `status-error`, `status-timeout`, `detached-unreachable`, `unparseable-path`, `worktree-locked`), the prune is skipped, the skip is stated on stdout and logged, and the reclaimable records simply wait for a later pass (`PRUNE_BLOCKED` in the footer). Idempotence is unaffected either way.

Re-running after any pass is a no-op by construction: removed worktrees leave the list, preserved ones classify identically (A3 rotates the log first, so its `REMOVED=0` cannot be satisfied by the previous pass's footer). A lock (`STATE_DIR/pi-reap-worktrees.lock`, mkdir-based, stale-break by pid+age — and an **ownerless young lock is honoured, not broken** — mirroring `pi-reap-idle`) prevents two concurrent passes.

**Exit codes** (cycle-2 change): `0` pass completed with nothing failed, `2` usage, `3` fail-closed abort (nothing trusted), `4` pass completed but ≥1 removal failed. `4` exists so a launchd/cron wrapper cannot read a refused removal as a clean run — the `FAILED=` footer alone is not a machine-readable contract. Deferrals stay `0`: they are the budget working, and the next pass re-classifies them.

### 3.5 Disk-savings honesty

The issue mandates stating this plainly, so both the script's report and this doc do:

> **Per-worktree `.venv`s are hardlinked to the uv cache, so `du` over-reports them (measured: 84 GB `du` delta vs 22 GB actually freed).** The reaper therefore **does not report and does not claim any byte saving** — it never calls `du`. The real, deliverable win is **file count**: 2,363,772 files → the count actually walked by `find`/`grep`/`rg` in the working tree is the amplification that produced the 10–18-minute searches.

### 3.6 Removal mechanics

`git worktree remove <path>` (**no `--force`**) — git's own refusal on tracked/untracked dirt is a **second, independent gate** after ours, and a refusal is reported as `REMOVE-FAILED` rather than swallowed. Branch refs are never deleted (`git branch -D` is never called) — this is the guarantee the output states, and the test suite asserts the ref survives removal. After removal, `git worktree prune` cleans the admin record. Semantics relied on here, from `git-worktree(1)` / `git-gc(1)`: `worktree remove` deletes the checkout **and its admin entry only** (a branch created by `worktree add -b` remains); it refuses a dirty or untracked-file worktree without `--force`, but does **not** refuse one holding only ignored files; and a worktree whose directory has vanished is `prunable` — `git worktree prune` removes that record immediately, whereas `git gc` would only do so after `gc.worktreePruneExpire` (default ~3 months). Our explicit `prune` is therefore what makes the `prunable` path immediate rather than a 3-month-deferred `gc` side effect.

### 3.7 Operator entry point (harness constraint found during implementation)

The reaper's git target is resolved at runtime, so the `main-worktree-guard` extension's static script-content walker (#1484) blocks executing it from a session whose **process cwd is the shared main checkout** — its own test suite included. The guard exempts a session rooted in a linked worktree (`isWorktreeCwdWrite(process.cwd())`). This is a harness property, not a reaper defect: run it from a worktree-rooted session, a terminal, or launchd, and the script's own usage text says so. Arming (launchd) is deferred (§8).

---

## 4. Integration surface map

| Surface | Kind | Test layer | Failure modes tested |
|---|---|---|---|
| `git worktree list --porcelain` | subprocess (git) | integration — **real temp git repo** | detached vs named branch; worktree vanishing mid-pass; enumeration failure (`exit 3`) |
| `git status --porcelain --ignored=traditional -unormal` | subprocess (git) | integration — real repo | tracked modification; gitignored non-ephemeral; allowlisted-ephemeral; timeout |
| `git for-each-ref --contains` | subprocess (git) | integration — real repo | detached reachable-from-other-ref / unreachable |
| `git merge-base --is-ancestor` / `git log -1` | subprocess (git) | integration — real repo | merged vs unmerged; too-recent (strict `>` boundary both sides) |
| `git worktree remove` / `prune` | subprocess (git) | integration — real repo | removal; branch ref survives; prunable record; refusal not swallowed |
| `gh pr list` | external command | **shim** (`GH_BIN` seam) | open PR ⇒ preserve; explicit `--limit` (the default 30 would be a false PASS); unavailable ⇒ `exit 3`; no GitHub remote ⇒ N/A |
| `ps -axo` | external command | **shim** (`PS_BIN` seam) | live reference; symlinked-path form; enumeration failure |
| `lsof -a -d cwd` | external command | **shim** (`LSOF_BIN` seam) | cwd inside the worktree ⇒ preserve; probe degradation |
| path canonicalization | mixed | integration | argv in resolved / unresolved / symlinked form; sibling path not a false veto |
| lock | filesystem (state dir) | unit-ish | live-held lock blocks (`exit 3`) |
| budget | wall clock | integration | overrun ⇒ `deferred`, nothing removed |
| log footer | filesystem | unit-ish | `MODE=`/counters written on every exit path |

Real git (not a shim) is used for every git probe: the gates *are* git semantics, and shimming git would let the tests pass while the production classification was wrong. `gh` and `ps` are shimmed because they are not what is under test and must be deterministic.

## 5. Journey test map

| Journey step | Required outcome | Test |
|---|---|---|
| Operator runs the reaper with no flags | Report printed; **nothing removed** | `A1 dry-run default: nothing removed` |
| Operator arms removal | Only classified-safe worktrees removed; branch refs intact | `A2 apply removes the reclaimable; branch survives` |
| A session has a worktree mid-work | Preserved with `dirty` / `live-process` / `live-cwd` | `G2a`, `G4a`, `G4b` |
| A worktree holds an active PR | Preserved with `open-pr` | `G5a` |
| A worktree's branch is UNMERGED with no open PR | Removed with `refs=branch-retained:<branch>` named, and the ref proven to survive | `G6b` (feat/g6-aged is unmerged) + `A2`; `G3c` for the detached analogue |
| A detached scratch worktree with nothing pointing at it | Preserved with `detached-unreachable` | `G3a` |
| A 3-day-old worktree (the `/private/tmp` class) | Preserved with `too-recent` | `G6a` |
| Re-running is safe | Second pass removes nothing | `A3 idempotent` |
| gh is unavailable | Loud fail-closed abort (`exit 3`), nothing removed | `G5c` |
| A repo with no GitHub remote | PR gate N/A; still reclaims | `G5d` |
| The checkout the reaper runs inside | Preserved with `self-checkout` | `G8` |
| An ignored-but-valuable file | Preserved with `ignored-artifact` | `G2b` |
| A `git worktree lock`-ed checkout | Preserved with `worktree-locked` | `G11` |
| A checkout that exists but cannot be resolved (permissions) | Preserved with `unreadable-path`; record NOT pruned | `G9` |
| A vanished checkout whose HEAD commit is on no ref | Preserved with `detached-unreachable`; record NOT pruned | `G10` |
| The pass budget is exhausted | Remaining rows `deferred`; an armed pass removes nothing further | `A7` |
| `ps` cannot run, or returns an empty table | Loud fail-closed abort (`exit 3`) | `G12a`/`G12b` |
| `lsof` is unavailable | Footer `CWD_PROBE=degraded`, argv probe still classifies (never silent) | `G13` |
| An armed pass's log cannot be written | Abort (`exit 3`) — no unlogged removal | `A13` |
| git refuses a removal | `REMOVE-FAILED` + `FAILED=1` + `exit 4`; the checkout stays | `A12` |
| The allowlisted-ephemeral pre-delete blocks (huge / locked `.venv`) | `REMOVE-FAILED` + `FAILED=1` + `exit 4`; the checkout and its admin record stay | `A16` |

## 6. Wiring check

- `scripts/pi-reap-worktrees.sh` (new) — the reaper.
- `scripts/pi-reap-worktrees.test.sh` (new) — hermetic suite (**129 assertions, all green**; see §9 for the count's history); registered in `.github/workflows/ci-main.yml` alongside `pi-reap-idle.test.sh` (post-merge main-push family — `ci.yml` has no per-PR shell-script block).
- **Repo-selection contract:** `--repo PATH` (default `$PWD`), mirroring `stale-worktrees.sh`. `git worktree list` is per-repo, so the reaper **never** walks outside the named repo, and the main-checkout exclusion resolves from that repo's `--git-common-dir`.
- No existing caller changes. `stale-worktrees.sh` / `cleanup-worktree.sh` / `hub-worktree.sh` / `checkout_guard.sh` are untouched.
- **Adjacent finding (not absorbed):** `scripts/rg` search tooling still walks `.worktrees/*/node_modules` (#1069, already open).
- **Adjacent finding (not fixed):** a hub-rooted agent session cannot execute a runtime-targeted git script at all (§3.7); the documented path is a worktree-rooted session or a terminal. Not a reaper defect — noted for the harness owner.
- No new dependency: `git`, `bash 3.2`-safe, `awk`. (`python3` is not required — the only structured input is `git worktree list --porcelain`, which is line-oriented, and `gh` is asked for plain newline-separated text.)
- Bash **3.2**-safe only (macOS `/bin/bash`): no `declare -A`, no `mapfile`, no `${var,,}`.

## 7. Acceptance criteria

1. Per worktree: `remove` or `preserve` **plus the deciding reason** (and, for `remove`, the commits-survival mechanism `refs=merged` / `refs=branch-retained:<branch>` / `refs=reachable-from:<ref>`).
2. Dry-run is the default; removal requires `--apply`.
3. Idempotent; safe while a session works in a worktree (argv + cwd live-reference gates, `dirty` gate, `self-checkout` guard, lock).
4. Test fixture per gate fail path: **dirty, detached-unreachable, live reference (argv and cwd), open PR, too-recent** — plus **unmerged-named-branch** (the `refs=branch-retained` removal path), ignored-artifact, gh-unavailable, no-GitHub-remote, status-timeout, lock, budget, prunable, idempotence.
5. No disk-savings claim; file-count framed honestly.
6. Bounded: no recursive walk; per-probe timeout; global budget covering classification **and** removal.
7. `main` checkout and the reaper's own checkout are never candidates.
8. **Stated deviation from the issue's literal gate list:** the binding gate is *commits survive*, not *merged*. An **unmerged named-branch** worktree is removable (branch ref retained — the measured 48-row class). `merged` is reported, not binding. Derivation in §2; both the `refs=merged` path and the branch-retained path are covered by tests.
9. **Fail-closed on every unverifiable gate:** enumeration, `ps`, `gh` (with candidates), `git status`, the lock, and the armed pass's log each abort with `exit 3` rather than degrading to a pass. The only intentionally degraded probe is `lsof` (reported in the footer, never silent).
10. **A removal failure is machine-visible:** `exit 4` plus `FAILED=n` plus `REMOVE-FAILED` on stdout and in the log.

## 8. Deferred / gated

- **Arming a launchd job** to run the reaper periodically is **deliberately not done here**: this ships the reaper (classification + dry-run + `--apply`) with no scheduled execution. Arming is a separate, reversible, dated step with a named owner (the operator), mirroring the `pi-task-session-prune` precedent (shipped DRY-RUN; arming is a separate manual step). *Re-check mechanism:* a follow-up issue tracks arming-or-not with the operator as owner; the reaper is not left with a "defer until X" and no owner.
- **Creation-time ownership / session-exit self-reclaim (frame F5).** Considered in problem-diverge and **not absorbed**: recording an owner at `git worktree add` time plus a `pi` session-exit hook would bound sprawl continuously rather than daily, and carries little of the risk that dominates this doc. Out of scope for #1095 because (a) it cannot reclaim any of the existing 407 worktrees — the measured problem is *already-accumulated* sprawl — and (b) it requires touching the session-exit path, a materially larger blast radius. Filed as a follow-up rather than silently dropped.
- **Byte-accurate disk accounting** — cannot be delivered honestly (§3.5). Not attempted.
- **A per-site `mktemp` for the probe output files** (enumeration / `ps` / `lsof` / `gh` / `status` / `remove`). The cycle-2 work moved the *watchdog* scratch into one per-pass directory (the hot path), which is where nearly all the fork cost was; the remaining `mktemp` calls are one per probe *site* (≈6 per pass) and each site has its own distinct failure handling. Converting them is a real further saving on a loaded host but touches five correct fail-closed paths, so it is **not** done in this change. If the reaper's CI runtime becomes a problem, that is the measured next step.
- **A timeout primitive that does not fork at all** (bash-3.2-safe `read -t` on a held-open FIFO, plus a done-sentinel written by a wrapper). Would cut per-probe forks further. Rejected for this change: rewriting the timeout engine that the A6/A7 tests pin, late in the cycle, on a host too loaded to iterate on, is exactly how a safety gate acquires a false negative.

---

## 9. Review cycle log

### Cycle 1 — scope verification (fresh context, `task` sub-agent)

- **P0 (accepted, fixed):** dropping `--ignored` from the clean gate silently deletes ignored-but-valuable files, since `git worktree remove` does not refuse ignored files. Verified independently (an ignored `.venv` was deleted by a bare `worktree remove`), and the claimed "it would flag every node_modules" justification was falsified (one `!! node_modules/` line). Fixed by reinstating `--ignored=traditional` with a narrow root-level ephemeral allowlist → `ignored-artifact` preserve (G2b).
- **P1 (accepted, fixed):** `.venv`-only worktrees were classified `remove` and then refused by git, with the refusal swallowed. Fixed: allowlisted *untracked* ephemerals are deleted explicitly before removal; refusals are logged and counted as `REMOVE-FAILED` (G2c asserts actual removal + ref survival).
- **P1 (accepted, fixed):** `gh pr list` defaults to `--limit 30`, so a PR beyond the first 30 was a **false PASS** on the exact class the issue preserved. Fixed with an explicit `--limit 1000` (A8 asserts the flag).
- **P1 (accepted, fixed):** no path canonicalization — `git worktree list` stores resolved paths, so the live-reference gate and self-checkout guard would silently miss `/tmp`-vs-`/private/tmp` forms. Fixed (G7a–c, G8).
- **P1 (accepted, fixed):** silent `pr-unknown` per candidate would make a gh-less environment a healthy-looking forever-no-op. Fixed to a loud `exit 3` (G5c), with a no-GitHub-remote N/A path (G5d).
- **P1 (accepted, documented):** the gate-semantics resolution relaxes the literal conjunction; its direction is correct but the deviation must be stated. Recorded in §2 (cost paragraph) and §7.8; the unmerged-named-branch fixture is added (G6b + A2).
- **P1 (accepted, fixed):** repo selection was unspecified. Fixed as `--repo PATH` (§6), with a test asserting a named repo's worktrees are the only ones touched (every fixture passes `--repo`).
- **P2 (accepted, fixed):** the `for-each-ref --contains` "short-circuits" claim is false, and `gh`/removal had no timeout. Fixed by dropping the claim and putting `gh` and `git worktree remove` under watchdogs counted against the budget.
- **P2 (accepted, documented):** the argv-only live-reference probe cannot see a process that merely `cd`-ed in. Fixed by adding the bounded `lsof -a -d cwd` probe (G4b) rather than narrowing the acceptance wording.
- **P2 + P3:** a creation-time TTL/owner complement and the `git-worktree(1)`/`git-gc(1)` semantics are now recorded (§8, §3.6).

**Verdict:** all P0/P1 findings accepted and fixed; the one P1 requiring an explicit decision rather than a code change (the `merged` deviation) is documented in the acceptance criteria instead of silently applied.

### Cycle 2 — code review (fresh context, `task` sub-agents)

Three fresh-context reviewers (scope/doc verifier, test reviewer, code reviewer) ran against the cycle-1 fixes. Findings and disposition:

**P0 — both were false PASSes on the *reachable* gate, the only gate whose failure is unrecoverable:**

- **`prunable` bypassed commits-survive.** The vanished-directory branch returned `remove` before the commits-survive gate ran, so a worktree whose directory was gone and whose `HEAD` was a detached SHA on **no ref** would have its admin record pruned — leaving that commit unreferenced. A later `gc` then deletes it. *Fixed:* the commits-survive gate now runs on **every** removal path, including `prunable`; the unreachable case is `preserve/detached-unreachable` **and** sets `PRUNE_BLOCKED`. *Pinned by:* `G10` (asserts the record is still registered after `--apply`).
- **`canon == ""` conflated "gone" with "unresolvable".** A checkout that exists but cannot be resolved (permissions, unmounted parent) was classified `prunable` — i.e. deregistered while live, and (via the old global prune) possibly while a process held it. *Fixed:* an explicit existence test distinguishes the two; `unreadable-path` preserves and blocks the prune. *Pinned by:* `G9` (the `chmod 000` leg asserts both the reason and that the record survives `--apply`).

**P1 (accepted, fixed):** an unconditional end-of-pass `git worktree prune` deregistered preserved records → selective/guarded prune with `PRUNE_BLOCKED`; `.venv`-only refusals were swallowed → surfaced (and now `exit 4`); the `gh pr list` default `--limit` would be a false PASS → explicit limit asserted (A8, incl. exactly one batched call); path canonicalization / symlinked argv forms → `G7a–c`; an empty `ps` table read as "no live process" → `exit 3` (G12b); non-numeric timeouts silently disabling watchdogs → validated before use (A14f); the watchdog leaked a `sleep` per probe → the watchdog now owns its timer (and the per-probe `pkill -P` is gone, §3.3.5); the lock `mkdir`→owner-write window read as stale → an ownerless *young* lock is honoured (A5b); `locked` records were removal candidates → `worktree-locked`; `MAIN_CANON` derived from `${common%/.git}` (wrong for submodules / `--separate-git-dir`) → taken from the first `worktree list` record; framing bytes in `--porcelain` output could truncate a path into looking absent → poisoned records are never removed.

**P1 (accepted, fixed) — the budget clock:** the pass budget started before the probes, so on a loaded host the setup alone could exhaust it and defer **every** worktree on **every** pass — a reaper that silently never reaps. *Fixed:* the clock starts at the per-worktree loop. *Found by:* the suite, which is the point of having it (`A7` failed 3/3 assertions on the first near-green run; the fixture was also given 4× timing headroom, since a fork on this host costs ~1 s under load).

### Cycle 2 — test review (fresh context, `task` sub-agent)

- **P0:** `A3`'s idempotence assertion was **vacuous** (the log is append-only, so the *previous* pass's `REMOVED=0` satisfied it) — fixed by rotating the log first. `refs=branch-retained:<branch>` was asserted nowhere (every aged fixture happened to be a detached-or-merged one) — fixed by making `WT_AGED` unmerged and asserting the ref still resolves after removal (`G6b`). The removal-refusal path was untested → `A12`.
- **P1:** the `ps`-failure, log-unwritable, and cwd-degraded fail-closed paths were untested (→ `G12a`, `G13`, `A13`); the armed overrun path was untested (→ `A7`); non-numeric timeout validation was untested (→ `A14f`); the `du` canary and the "no byte saving" claim family were untested (→ `A9`); `--aged-days` / `REAP_WT_DRY_RUN=0` / `--help` / bad-arg were untested (→ `A14`); the `gh` call count was unasserted (→ `A8`, exactly one).
- **Self-inflicted, worth recording:** the suite itself was **unbalanced** (one stray quote inside a command substitution), and bash executes a script incrementally — so 46 assertions ran and then it died *without a summary line*. Fixed, and the suite now runs `bash -n "$0"` as its first act, so a truncated file is a one-line error instead of a partial pass.

**Verdict:** every P0/P1 from both cycle-2 reviewers is fixed with a fixture that fails without the fix. Remaining items are recorded as deliberate omissions (§8) rather than silently dropped. The reaper is **not armed** in this change (§8), so the blast radius of any residual defect is a dry-run report.

### Cycle 3 — residual closure at commit time (worktree-rooted session)

The suite was run as committed (`bash scripts/pi-reap-worktrees.test.sh`, 120/120 green). One residual carried by the cycle-2 review was then closed: **the allowlisted-ephemeral pre-delete in `remove_one()` was a bare unbounded `rm -rf`** — the last fork on the removal path outside every watchdog, and (worse) its status was discarded, so a block was invisible rather than reported.

- **Fix:** the pre-delete runs under `REAP_WT_REMOVE_TIMEOUT` via the existing `run_bounded` watchdog, through a new `RM_BIN` seam (the script's own scratch/log cleanup deliberately keeps the real `rm`, so the seam cannot defeat it). A non-zero/timed-out pre-delete returns 1 ⇒ `REMOVE-FAILED` ⇒ `exit 4`, with the admin record intact.
- **Why it reports instead of continuing:** an ephemeral that survived its own deletion is exactly a directory `git worktree remove` (no `--force`) refuses on, so continuing would only convert one report into a slower second unbounded attempt at the same block.
- **Pinned by `A16`** (slow-`rm` shim at `RM_BIN`, `REAP_WT_REMOVE_TIMEOUT=1`): exit 4, `FAILED=1`, the timeout logged with the entry name, the worktree and its admin record still present — plus `A16b`, the same fixture reclaiming normally under a real `rm`, so the watchdog is not a veto. Falsifier run before commit: with the watchdog and its status check removed (the pre-fix shape, unbounded `rm` + default 120 s removal timeout), the same fixture exits **0** with `REMOVED=1 FAILED=0` and the worktree gone — the 3 s block left no trace. `A16` fails on exactly that shape.
- **Assertion count:** 120 → 129 (the nine new `A16`/`A16b` assertions).
