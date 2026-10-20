---
title: "#4529 — the worktree pruner removes nothing; the scan root is not the reason"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-10-20
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-4529, worktree-reaper, squash-merge, disk-reaper
---

# #4529 — the worktree pruner removes nothing, and the reason is not the scan root

Issue: **daniel-ospina/tortoise#4529** (labels: `harness`, `not-launch-relevant`) — "worktree pruner:
`.worktrees` is 233 GB across 451 worktrees and nothing ever removes one".
Implementing repo: **daniel-ospina/agent-infra** (the code the issue names lives here; the `harness`
label and the farmed `$HOME/.pi/agent/scripts/` copies both point at this repo).

Tier: **standard** (touches gate/enforcement code in a deletion tool → adversarially bounded, below).

---

## 1. Problem diamond

### 1.1 What the issue claims, and what it measures

| # | Issue's claim | Verified? | Evidence |
|---|---|---|---|
| A | 233 GB across 451 worktrees, nothing removes them | **partly** | this cell: 50 records in `git worktree list`, 8 under `/tmp/cell-home/wt-*`, 27 under `/tmp/cell-t3/.worktrees/`, 14 under `/tmp/wt-*` |
| B | **Defect 1** — the installed unit executes a path from a dead bring-up staging dir → `status=127` hourly | **yes** (operationally; and the *input* half is now fixed upstream) | on `origin/main` (51bab017 / #2173) `refuse_transient_target()` already refuses a render whose `REAPER`/`HOME`/`STATE_DIR` is `mktemp` scratch, with test T50. What is **not** covered is the artifact: nothing reads `ExecStart` back out of the INSTALLED unit, so a drop-in or a partial write still produces a 127 unit that passes every "is it installed?" check. |
| C | **Defect 2** — "the scan root is `.worktrees`, but lanes allocate at `/tmp/cell-home/wt-<PR>` … structurally invisible" | **NO — falsified** | Both owners enumerate `git worktree list --porcelain`, never a directory: `pi-reap-worktrees.sh` (`wt_list_load`) and `reap-lane-venvs.sh` (`run_gc`). Measured dry run on this cell classifies `/tmp/cell-home/wt-9307`, `/tmp/cell-home/wt-9134`, `/tmp/wt-pk1`, … normally. A second scan root would be a **cache** of the registry — the issue's own proposed fix #1 is already the implementation. |
| D | the measured consequence: `REMOVED=4 freed_df=1MB` while a 5.7 GB **MERGED** worktree survived | **yes, but the cause is different** | see 1.2 |

### 1.2 The root cause the measurement actually exposes: the merged proof cannot see a squash

```
$ gh pr view 9307 --repo daniel-ospina/tortoise --json state,headRefName,mergeCommit
{"state":"MERGED","headRefName":"fix/9078-layer1-position-row",
 "mergeCommit":{"oid":"f3b0f26a05322ae5dcdfb329a2e11f50a7a70900"}}   # == origin/main tip

$ git merge-base --is-ancestor b7d15225a origin/main   # b7d15225a = that worktree's HEAD
rc=1  (NOT an ancestor)     $ git ls-remote origin refs/heads/fix/9078-…  → (empty; deleted)
```

This repo **squash-merges**. A squash merge rewrites the branch's commits into one new commit, so the
branch tip is *never* an ancestor of main — even though the PR is merged and its content is on main.

`commits_survive()` proves "merged" only by `merge-base --is-ancestor <tip> <main>`. Therefore
`refs=merged` is unreachable for every squash-merged PR, and the branch falls through to
`refs=branch-retained:<b>` — which is a survival mechanism, so the checkout is *reclaimable*, but only
after `REAP_WT_AGED_DAYS` (7). On a cell where every worktree is hours old, that is never.

The `REAP_WT_MERGED_AGE_DAYS=0` exemption exists **precisely** so "a merged 5.7 GB checkout can be
reclaimed the same day" (its own header cites the measured 5.7 GB case). It is dead code on any
squash-merge repo. That is the whole gap between "the pruner runs and reports ok" and "the disk is
still full": the class that fills the disk is preserved by the floor the exemption was written to lift.

Second, independent defect in the same proof: `resolve_main_ref()` reads the **local**
`refs/remotes/origin/main`, which a narrowed refspec or a cell that never fetches leaves stale —
`cleanup-stale-branches.sh` documents this at length (F26/F29) and resolves the **push url** with
`git ls-remote` instead. A stale local main can only ever *under*-report merges, which is why it
compounds the squash blindness rather than causing removals by itself.

### 1.3 The third defect: a pass that removes nothing is indistinguishable from a healthy one

Measured on this cell (real dry run, full output captured):

```
preserve 47   remove 4
reasons:  too-recent ×39, live-cwd ×4, dirty ×2, live-process ×2, main-checkout ×1
```

Nothing in the delegate's *output* says that. It prints 51 rows and then a single dry-run banner, and
the entry point reduces it to `candidates=4 freed_df=…`. So the operator above it — the supervisor,
the fleet check, the human — sees `rc=0 verdict=ok` on a pass that classified 50 checkouts and
declined 46 of them. That is the reporting half of the incident, and it is why `REMOVED=4 freed_df=1MB`
read as success.

### 1.4 Confirmed problem

> The pruner's **classification** is what is broken, not its enumeration. A merged (squash) worktree
> is not provably merged, so it is preserved as unlanded work until it ages out — and on a live cell it
> never does. Compounding it, the pass emits no aggregate, so "classified 50, removed 0, 39 too-recent"
> is reported everywhere above it as `ok`. And the scheduled unit's *installed* artifact is never
> verified, so an inert 127 unit satisfies every "is the reaper installed?" check.
>
> Fix the merged proof (commit-level, squash-aware, against the resolved remote main), make the pass
> report its own classification tally, and read the installed unit back — not the input that was
> supposed to produce it.

### 1.5 Rejected framings

- *"The scan root is wrong; add `/tmp/cell-home`"* — falsified (1.1 C). Adding it would **hide** the
  registry and double-classify.
- *"The floor is too long; install with `--aged-days 0`"* — removes unlanded work. Cells hold clean,
  unmerged, actively-reviewed checkouts (measured: 2 today). The floor is the only protection for
  work in progress; the right fix is to make the exemption fire, not to delete the floor.
- *"It's just reporting"* — no: 46/50 preserved is a classification outcome, not a formatting one.

---

## 2. Solution diamond

### 2.1 Alternatives

| # | Approach | Verdict |
|---|---|---|
| **S1** | **Commit-level merged proof with a second arm**: keep `is-ancestor(tip, main)`; when it fails and the branch's PR is `MERGED`, require `is-ancestor(pr.mergeCommit.oid, resolved_main)`. Resolve `main` from the push url via `ls-remote` (`REAP_WT_MAIN_PROOF=auto`), falling back to the local tracking ref. Waive the age floor on *either* proof. | **CHOSEN** |
| S2 | Trust the PR state alone (`gh pr view` → `MERGED` ⇒ merged) | **rejected** — that is "verify by name": it holds when the PR merged into a *different base*, or when a force-push after the merge rewrote the content. The ancestor test on the PR's own merge commit is the commit-level fact that closes both. |
| S3 | `git cherry` / patch-id equivalence to detect squash merges | **rejected** — O(commits) per record (the tool is explicitly bounded: no `find`, no `du`, one batched `gh` call), needs the same main resolution anyway, and reports "equivalent" for content that was later reverted, which is a *worse* answer to "may this still be under review?" than the PR state. |
| S4 | Delete the age floor / lower it by default | **rejected** — destroys unlanded work. |
| S5 | Add a second scan root for `/tmp/cell-home/wt-*` | **rejected** — the registry already covers it (measured); a directory is a stale cache of `git worktree list`. |
| S6 | Have the delegate report bytes reclaimed | **rejected** — the tool's measured honesty rule (per-worktree `.venv`s are hardlinked to the uv cache: 84 GB `du` delta vs 22 GB actual). The **entry point** measures with `df`; the delegate reports *counts and reasons*. |
| S7 | Make an unverifiable merged-PR list exit 3 | **rejected** — that recreates the measured outage ("the worktree class exits 3 and reaps NOTHING"). Unverifiable merged evidence may only **withhold the waiver**; it must never block the open-PR gate, which keeps its exit-3 fail-closed. |
| S8 | Post-install: re-render and `cmp` the expected bytes | **rejected as insufficient** — `cmp` of the rendered temp copy proves what we wrote, not what systemd will load: a `*.service.d/*.conf` drop-in overrides `ExecStart` and the bytes still match. |
| S9 | Verify the installed artifact by parsing `ExecStart`/`HOME` back out of it (what systemd loads; `systemctl cat` merges drop-ins) and refusing on a mismatch/dead target | **CHOSEN** |

### 2.2 The chosen classification contract (per worktree; gate order unchanged)

```
poison > bare > main-checkout > self-checkout > locked > unreadable|prunable >
live-process > live-cwd > dirty|ignored-artifact|status-* >
detached-unreachable > open-pr > too-recent > reclaimable
```

`refs=` (the reachability / merge evidence) gains one value:

- `merged`                     tip is an ancestor of the resolved main (unchanged)
- `merged-pr:<oid7>`           **new** — the branch's PR is MERGED and its `mergeCommit.oid` is an
                               ancestor of the resolved main (covers squash AND rebase-with-commit)
- `branch-retained:<b>`        unchanged (removal never deletes the branch)

Age floor: `REAP_WT_MERGED_AGE_DAYS` (0) when `refs` is **any merge proof**; `REAP_WT_AGED_DAYS` (7)
otherwise. Everything else — clean/dirty, live holder, open PR — is untouched and keeps its order.

**Declared threat surface** (adversarial bound, 2 cycles; out-of-scope classes named below):

| # | Threat | Covered by |
|---|---|---|
| T1 | merged PR whose `mergeCommit.oid` is *not* on main (wrong base, rewritten main) | `is-ancestor` on the oid ⇒ no waiver. **Test: G6h** |
| T2 | merged-PR list truncated (`--limit`) | can only MISS evidence ⇒ preserve. Recorded as `pr_merged=ok` with `rows=<n>` in the log (a truncated list loses rows, so the evidence simply never matches) |
| T3 | merged-PR list unavailable / gh down | no waiver ⇒ preserve; recorded `pr_merged=unavailable`; the open-PR gate still exit-3s. **Test: G6i** |
| T4 | `mergeCommit.oid` unknown locally (unfetched) | `is-ancestor` rc 128 ⇒ no waiver |
| T5 | stale / narrowed local `origin/main` | remote main resolved via push-url `ls-remote`; local only as fallback, and recorded (`main_proof=`). **Test: G6f** |
| T6 | origin has no push url / >1 push url / ls-remote fails | fall back to local ref, recorded. No removal decision depends on it alone |
| T7 | merged proof shadowing the open-PR veto | order: `commits_survive` runs first but does not return; the open-PR veto is checked after and still wins. **Test: existing G5a** |
| T8 | installed unit masked by a drop-in (the 127 unit) | read-back parses the *artifact systemd loads*. **Test: T55** |
| T9 | partial write / truncation of the installed unit | read-back requires a non-empty effective `ExecStart` list containing our target. **T55 covers the drop-in MASK; the no-`ExecStart`-at-all branch is refused by the same function but has no dedicated test** (see §6.2) |

Declared **out of scope**, recorded so the next lane does not re-derive them: content-equality proof
(a merge reverted later still reads merged — removal never deletes the branch, so nothing is orphaned);
the *input-side* transient render (fixed by #2173/T50); a non-git-remote forge (PR gate is N/A today).

### 2.3 The reporting contract

The delegate ends with one machine-readable line (and the entry point lifts it into the class line and
the status file):

```
SUMMARY examined=<n> classified=<n> remove=<m> preserved=<k> deferred=<d> deferred_remove=<dr>
        removed=<r> failed=<f> late_preserved=<l> prune_blocked=<p>
        reasons=<reason>:<n>,… main_proof=<auto|auto-unfetched|ambiguous|unavailable|local>
        pr_merged=<ok|unavailable|na>
        (classified = remove + preserved; examined = classified + deferred)
```

`remove=` is "would remove" in dry-run and "SELECTED" in apply — a selected record can still end as
`removed`, `failed`, `late_preserved` (the removal-time re-check was not clean) or `deferred_remove`
(the budget stopped the removal), which are the apply-only outcomes on the same line. The existing
`REMOVED=` line keeps its meaning for callers that already parse it.

### 2.4 The install contract

`install-disk-reaper-timer.sh --install` gains a **read-back**: after the copy and `daemon-reload`, it
reads the unit **systemd will load** (`$SC cat`; the installed file as fallback) and refuses (exit 1,
named reason, no green) unless:

1. the EFFECTIVE `ExecStart` list is non-empty;                (partial write, or a drop-in that reset the list)
2. **our** reaper is among the effective commands;             (drop-in mask, stale farm)
3. the rendered mode flag is present;                          (arming decision visible in the artifact)
4. `HOME` — in the EFFECTIVE `Environment=` map, parsed the way systemd parses it (several assignments per line, single/double quotes, last assignment per name wins, a bare `Environment=` resets) — is present, absolute, and equal to the rendered HOME;  (gh auth — the measured exit-3 class)
5. the three pinned delegates — read from that SAME map — exist on disk;   (a pin to a missing file is not a pin; a WARNING, not a refusal, so the classes that can still run do)
6. when the scratch heuristic was not bypassed by the documented test seam, the target is not `mktemp` scratch.

⛔ Rule 2 is "ours is AMONG the effective commands", **not** "there is exactly one": `Type=oneshot`
may legally carry several, and a drop-in that ADDS a pre-flight line is a healthy unit — refusing it
would be a false block on a working cell (T55 asserts it is accepted AND still verified). On macOS
the same facts are `ProgramArguments` (the executable **and** the mode flag) plus
`EnvironmentVariables.HOME`.

The installer does **not** inject an `EnvironmentFile=` or a shims `PATH` entry: the first is
arbitrary shell that can override the very `HOME` this read-back verifies, and the second would
reopen a recorded TCC decision. `gh`'s resolvability in the rendered environment is **reported** at
install (a path, or a WARNING naming the consequence), never silently assumed and never a refusal —
a box with no GitHub remote does not need it.

---

## 3. Test plan (each fails before the change)

| Test | Fixture | Fails before because |
|---|---|---|
| **G6e** squash-merged worktree, **outside** the repo root, merged-PR evidence present | bare `origin` + worktree at `$T/G6e-ext/wt-9307` (the 5.7 GB shape: outside the repo dir), PR says MERGED with `mergeCommit == main` | tip is not an ancestor ⇒ `branch-retained` ⇒ `too-recent` ⇒ preserved |
| **G6f** stale local `refs/remotes/origin/main` | squash pushed to the bare origin, never fetched into the fixture repo | mergeCommit is only an ancestor of the *remote* main ⇒ no waiver |
| **G6h** (mutation guard) merged PR whose `mergeCommit.oid` is **not** on main | gh reports MERGED + an unrelated oid | must still preserve — fails if the ancestor arm is dropped |
| **G6i** merged evidence unavailable | `gh --state merged` fails | must preserve, and say `pr_merged=unavailable` |
| **G6j** SUMMARY tally | any fixture with mixed verdicts | no SUMMARY line exists |
| **T55** installed-artifact read-back | override unit dir + a `*.service.d/` drop-in masking `ExecStart` to a `mktemp` path | install exits 0 and reports "installed" over a unit that would 127 |
| ~~T53~~ (not written — folded into T55: the drop-in mask and the moved `HOME` are the two shapes an operator actually hits. **T56 is now used** for the tally contract: per-repo sums, the merged `reasons=` histogram, and the `?`/`not-run` sentinels) | — | — |
| A8 | updated: **two** batched gh calls, both with an explicit limit | — (contract change, asserted) |

---

## 4. Wiring check

- entry: `disk-reaper.sh` (delegate call, class line, status fields) → `pi-reap-worktrees.sh`
  (`resolve_remote_main` → `pr_merged_refs_load` → `commits_survive` → `classify_one` → SUMMARY)
- schedule: `install-disk-reaper-timer.sh` → `templates/systemd/eldato-disk-reaper.service` (read-back)
- tests: `scripts/pi-reap-worktrees.test.sh`, `scripts/disk-reaper.test.sh` — both in
  `scripts/run-bash-shards.sh` (CI `ci-main.yml`).
- docs: `docs/ops/disk-reaper.md` (the operator contract for the SUMMARY line and the read-back).
- surface: **no** MCP/SDK change (this is harness tooling; the surface rule is untouched).

---

## 5. Verification cycles

### 5.1 problem-verify — cycle 1 (1 fresh-context verifier)

Verifier: P0=0, **P1=4**, P2=4, P3=1.

| Finding | Action |
|---|---|
| P1 the doc's own predicate is not falsified: 8 of 9 *clean* merged-PR worktrees on this cell have HEAD ≠ the PR's `headRefOid`, so S1 waives the floor for moved tips | **Fixed** — S1 now requires `pr.headRefOid == worktree HEAD`. That is also what makes the evidence monotone under a truncated list. See §6.1 |
| P1 the 5.7 GB flagship is `dispatch-scout` (its `.venv`), not `wt-9307`; `wt-9307` is 136 MB and `dirty` today (and the dirty gate precedes the merge evidence) | **Fixed** — §1.1/§1.2 corrected; the fix's *measured yield* on this cell is stated, and the `.venv` class (already in the entry point) is named as the other half |
| P1 `REAP_WT_BUDGET_SECONDS` could explain "removed ~0, ok" on a 451-record estate independently of squash | **Confirmed non-dominant, and now reported** — measured 51 records in 9 s (≈0.18 s/record ⇒ ≈83 s for 451, budget 300 s) and `deferred=0`. The SUMMARY now carries `deferred=` so the hypothesis is *testable from the record* instead of inferred |
| P1 the §1.3 tally was arithmetically impossible (51 rows vs a 48-summing histogram from a different invocation) | **Fixed** — §1.3 replaced with one verbatim invocation + its log footer; reason counts now sum to `WORKTREES` |
| P2 the sibling class already prints `venvs_found=/reapable=/reaped=/kept=`; the real defect is narrower (worktree class has no tally, and `candidates_worktree` is structurally 0 in apply mode) | **Fixed** — §1.3 and §2.3 restated; the entry point now populates `classified/preserved/reasons` in **both** modes |
| P2 "a stale local main can only under-report" — false: `resolve_main_ref` falls back to `refs/heads/main`, which can be AHEAD | **Fixed** — §2.2 T5 corrected |
| P2 a 127 unit is caught by the *next* `--status` (`ExecMainStatus`); the gap is an unattended box that never runs it again | **Fixed** — §1.1 row B reworded to the real window |
| P2 the in-repo precedent already solved squash-awareness and was cited only for F26/F29 | **Fixed** — §6 cites it as the predecessor; tip identity is adopted *from* it |
| P3 test IDs T52/T53 collide with the suite's existing T52/T53 | **Fixed** — new tests are **T55** (install read-back) and **T56** (tally contract: per-repo sums, merged histogram, `?`/`not-run` sentinels) |
| **Code-review cycle 1 (reviewer B, adversarial)** P0: the `Environment=` read-back was a line match, so `Environment=PATH=… HOME=/dead` and `Environment="HOME=/dead"` both passed as "verified" | **Fixed** — `effective_env()` parses every `Environment=` line the way systemd does (list, quotes, last-wins, bare-reset); HOME and the delegate pins are read from that map. 8 new T55 assertions |
| Reviewer B P1: the launchd arm verified only the executable, so a stale plist carrying `--dry-run` reported "installed" | **Fixed** — the plist arm asserts the mode flag and `EnvironmentVariables.HOME`, and names the fact it could not verify; T20 pins the positive control |
| Reviewer B P2: the venv tally was read from the FIRST repo only (`grep -m1` outside the loop) | **Fixed** — lifted inside the repo loop and summed, like the worktree arm; 3 new T56 assertions |
| Reviewer B P2: an unanswerable tally was recorded as a measured `0`/`none` (the `${x:-?}` default could never fire) | **Fixed** — `_tally_num`/`_tally_rec` carry `?` (ran, no tally) and `not-run` (class not selected) into the class line and the record; T7/T56 pin both |
| Reviewer B P2: per-repo `reasons=` histograms were concatenated, not merged | **Fixed** — accumulated as `reason count` rows and folded into one descending histogram; T56 pins the sum |
| Reviewer B P2 (informational): `candidates_*` are now populated on armed passes — no verdict depends on them | **Recorded** — verified inert: `CAND_WT` feeds only the dry-run over-bound verdict |
| Reviewer B P3: two `say` calls had been joined on one line in the installer | **Fixed** |
| Reviewer B P3: `REAP_WT_MERGED_AGE_DAYS` was missing from the numeric-seam validation (a non-numeric value aborted `classify_one`'s subshell, printing a reason-less preserve row) | **Fixed** — validated with a range check up front; A14h pins it |
| — | External research: **justified skip** (local git safety predicate; the precedents are in-repo and were then read). |

### 5.2 solution-verify — cycle 1 (1 fresh-context adversarial verifier)

Verifier: **P0=2**, P1=6, P2=5, P3=4.

| Finding | Action |
|---|---|
| **P0** `refs=merged-pr` put the merge proof in the **survival** channel (`commits_survive` returns early) ⇒ on the gone-directory/`prunable` path it would waive the reachability gate and the global prune would deregister the admin HEAD — the last durable handle of a detached commit | **Fixed** — merge-PR evidence never enters `commits_survive`. It is a separate `merged_pr_ev` computed in `classify_one`, and it keys **only** the age floor. The reachability gate is untouched. New test **G6k** (gone-dir fixture + a merged PR by that head name ⇒ still `detached-unreachable`, still not pruned) |
| **P0** the waiver keyed on the branch NAME: name reuse, HEAD ahead of the PR head, and force-push-after-merge all waive a live checkout | **Fixed** — the evidence is `pr.headRefOid == this checkout's HEAD` (plus `mergeCommit` ancestry). Name reuse ⇒ different tip ⇒ no evidence; post-merge commits ⇒ no evidence (§6.1) |
| **P1** a shared read-back would false-block macOS (launchd has no `ExecStart`) | **Fixed** — target-dispatched: `verify_installed_unit()` (systemd) / launchd arm checks `ProgramArguments` identity |
| **P1** "installed file as fallback" *is* the fail-open: `/run/systemd/system/*.d` drop-ins are invisible to a file read | **Fixed** — for `system`/`user`, `$SC cat` must answer or the install REFUSES; the file path (plus merged `<unit>.d/*.conf`) is used only for `TARGET=override`, and it merges drop-ins itself. The t8 shim gains `cat` |
| **P1** `EnvironmentFile=keys.env` is arbitrary shell; systemd applies it *after* `Environment=`, so a `HOME=` line silently overrides the HOME the read-back certifies | **Dropped** — no `EnvironmentFile`. The installer instead **resolves `gh` in the rendered environment and reports it** (`gh=<path|MISSING>`); the class already fails closed (exit 3, red) when gh is unavailable |
| **P1** appending `$HOME/.pi/agent/shims` to PATH contradicts a recorded decision (install-launchd.sh **excludes** `/shims` — macOS TCC EPERM) and is inert (appending cannot outrank the real gh) | **Dropped** — not reopening a recorded decision; gh resolvability is reported instead |
| **P1** the new network probe needs an explicit seam or three existing fixtures become host-dependent | **Fixed** — `REAP_WT_MAIN_PROOF=auto|local`, `REAP_WT_MAIN_PUSH_URL`, `GIT_TERMINAL_PROMPT=0`, and `run_reaper` pins every fixture to `local` |
| **P1** G6f would be vacuous (a missing `refs/remotes/origin/main` falls through to `refs/heads/main`) | **Fixed** — G6f requires a stale-but-EXISTING tracking ref with local `main` reset *behind* it, plus a `REAP_WT_MAIN_PROOF=local` control on the same fixture |
| **P1** the gh shim is argument-blind; a second call feeds open-list payloads into the merged loader, and `FAKE_GH_FAIL` fails both calls so G6i cannot observe anything | **Fixed** — the shim dispatches on `--state open` vs `--state merged`, with separate payload and failure seams; A8 asserts two distinct calls |
| P2 the SUMMARY must reconcile (`PRESERVE_C` already includes `DEFERRED`; `REMOVE_C` counts rows later preserved/failed) | **Fixed, then corrected again by the VGATE reviewer** — a single `classified = remove + preserved + deferred` claimed a decision for records the budget never classified and did not reconcile on a deferral (measured `classified=2 … deferred=15` on 16 records). The line now carries `examined=` and TWO identities: `classified = remove + preserved` and `examined = classified + deferred`; `preserved` EXCLUDES deferrals; apply-only `removed/failed/late_preserved/prune_blocked`. Asserted by **G6j** (clean), **A7** (dry budget-deferred) and **A7 armed** (remove-time deferral, which has its own `deferred_remove=` counter) |
| P2 `main_proof`/`pr_merged` are per-repo but the class line is one line | **Fixed** — counts summed; a differing proof across repos reports `mixed` |
| P2 `auto` can report a main SHA that is not in the local object DB (the stale cell case) | **Fixed** — `git cat-file -e <sha>^{commit}` first; `auto-unfetched` + no waiver |
| P2 `get-url` (singular) cannot detect multiple push urls | **Fixed** — `git remote get-url --push --all`; ≠1 ⇒ `ambiguous` |
| P2 hardcoding `refs/heads/main` regresses master-default repos | **Fixed** — `ls-remote --symref <push_url> HEAD` first |
| P2 rule 5 (missing delegate ⇒ refuse) over-blocks: a cell missing one delegate would lose the class it CAN run | **Fixed** — stays a WARNING (the recorded decision); the read-back reports it, the unit goes red |
| P3 multiple `ExecStart=` is legal for `Type=oneshot` | **Fixed** — the check is "the rendered ExecStart is present among the effective ones" |
| P3 S3's rejection reason mis-states the decisive fact (patch-id cannot detect a squash at all) | **Fixed** — §2.1 S3 |
| P3 "falsified" is repo-relative; a worktree of a repo absent from `DISK_REAPER_REPOS` is still invisible | **Recorded as a residual** in §6.2 |
| P3 "covers rebase-with-commit" unverified | **Scoped** — the claim is the measured class (squash); a rebase merge with a null `mergeCommit` yields no evidence |
| P3 G5a is not a test of "merged proof does not shadow the open-PR veto" | **Fixed** — the name-reuse fixture (old merged PR + new OPEN PR, same head ref, different tip) is its own test, asserting `reason=open-pr` |

Both P0s were safety findings in destructive code; nothing was dismissed. No re-dispatch was needed
for ignored findings (none were ignored); cycle 2 is the code-review gate (§7).

---

## 6. Final contract

### 6.1 Merge evidence (the only thing the waiver rests on)

```
merged_pr_ev = "merged-pr:<mergeCommit-short>"  iff ALL of:
  branch != "-"                                    # a named branch (a PR has a head ref)
  PR(branch) is MERGED
  pr.headRefOid == <this checkout's HEAD sha>      # the evidence is about THIS commit
  is-ancestor(pr.mergeCommit.oid, RESOLVED_MAIN)   # …and its merge commit is on main
```

`RESOLVED_MAIN` = `ls-remote --symref <push_url> HEAD` → `refs/heads/<n>` → its oid, when
`REAP_WT_MAIN_PROOF=auto` (default) and the oid is present locally; otherwise the existing local
`MAIN_REF` chain. The age floor is `REAP_WT_MERGED_AGE_DAYS` when `refs = merged` **or**
`merged_pr_ev` is non-empty; otherwise `REAP_WT_AGED_DAYS`.

⛔ `merged_pr_ev` may never satisfy, replace or short-circuit `commits_survive` (the reachability
gate). It keys the age floor and nothing else.

### 6.2 Residuals (named, not fixed here)

- A checkout whose HEAD is *ahead of* its merged PR head keeps the 7-day floor — by design: those
  commits are unlanded. On a live cell the per-worktree `.venv` (the venv class, already installed)
  is the reclaimable part; the checkout itself ages out.
- A merged-then-reverted PR still reads merged. Removal never deletes the branch ref, so nothing is
  orphaned; the checkout can be regenerated from it.
- A worktree belonging to a repo that is not in `DISK_REAPER_REPOS` is not enumerated. Coverage is
  the union of the configured repos, not the filesystem. (A second scan root is exactly the stale
  cache the issue's fix #1 rejects.)
- **A truncated install** (no `ExecStart=`) is refused by the read-back, but T55 only drives the
  drop-in *mask* — the mask resets the list, so the "no ExecStart at all" branch is exercised as a
  side effect rather than by a test that writes the shape deliberately.
- **A stale launchd plist** is refused on the same facts as the systemd unit (executable, mode flag,
  `EnvironmentVariables.HOME`), but launchd has no drop-in equivalent, so no seam produces
  "written but stale": T20 is a positive control for the checks, not a negative one.
- **Two `gh` calls per repo per pass** (open veto + merged evidence) instead of one. The merged call
  is soft-fail by design, so a pacing/rate-limit refusal there costs only the waiver; the open call
  failing closed is pre-existing behaviour.
- Windows/no-`timeout` hosts: unchanged (`lib/bounded.sh` fallback). The new probe is bounded by
  `REAP_WT_GIT_TIMEOUT`.
- The dirty gate precedes the merge evidence, so a merged checkout that is dirty is never a
  candidate — the measured 9-of-51 `dirty` rows on this cell are that gate working.

### 6.3 Recorded measurement (this cell, one verbatim dry pass, 2026-10-20)

```
$ pi-reap-worktrees.sh --dry-run --repo /tmp/cell-t3 --aged-days 7     # 9 s
log footer: MODE=dry-run WORKTREES=51 REMOVE=4 PRESERVE=47 REMOVED=0 FAILED=0
            LATE_PRESERVE=0 DEFERRED=0 GH=ok CWD_PROBE=ok PRUNE_BLOCKED=0
reasons (sum 51): too-recent 20 · live-cwd 10 · dirty 9 · live-process 5 ·
                  reclaimable 4 · open-pr 2 · main-checkout 1
```

⇒ **4 reclaimable of 51**, and the 20 `too-recent` rows are where the merged class hides. This is
the "pass that removes ~nothing and reports ok" the issue measured.
