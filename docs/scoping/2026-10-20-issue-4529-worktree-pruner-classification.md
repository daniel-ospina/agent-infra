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

#### 1.2.1 The premise as it stands at the MERGED head (read this before §2.1/§6.1)

The measurement above is the pre-merge state and it is what made the issue real. It is **no longer
true of the code that ships here**: while this branch was in review, `main` landed #2721's
**RULE 4** in the delegate itself — `classify_one` now removes a checkout when "a PR for this head is
MERGED", decided two rules before the age floor is even computed:

```
scripts/pi-reap-worktrees.sh:1727  # ── RULE 4: a MERGED PR for this head, whatever the merge strategy
                                   #    if [ "$pr_state" = "MERGED" ] && [ "$pr_oid" = "$sha" ]
```

So on a squash-merge repo `refs=merged` (rule 3) is still unreachable, but the class is no longer
*stuck in the age floor*: rule 4 fires on the PR state with the sha identity gate (`pr_oid = $sha`),
which is the same "the evidence is about THIS commit" warrant §6.1 asked for, and rule 7's minimum
age still gates it (`G6e`). #2354's `patch_equivalent()` (`:1464`) remains as a **second, independent**
squash signal that lifts the *floor* only, never reachability.

Consequence for this document: the second ancestry arm this PR carried (`merged_pr_ev` /
`is-ancestor(pr.mergeCommit.oid, RESOLVED_MAIN)`) was **dropped in the merge**, because rule 4
decides the same class with a stronger proof. §2.1, §3, §5.2 and §6.1 below carry that correction
inline; the parts of this PR that ship unchanged are the reporting half (§1.3, §2.3), the remote-main
resolution (§6.1), and the installed-unit read-back (§2.4).

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
| **S1** | **Commit-level merged proof with a second arm**: keep `is-ancestor(tip, main)`; when it fails and the branch's PR is `MERGED`, require `is-ancestor(pr.mergeCommit.oid, resolved_main)`. Resolve `main` from the push url via `ls-remote` (`REAP_WT_MAIN_PROOF=auto`), falling back to the local tracking ref. Waive the age floor on *either* proof. | **SUPERSEDED at the merged head** — the `is-ancestor(mergeCommit, main)` arm was dropped: `main` shipped #2721's **RULE 4** (`pi-reap-worktrees.sh:1727`, PR state + `pr_oid == HEAD`) which decides the same class two rules earlier with a stronger warrant. The **main resolution half ships** (`resolve_remote_main`, `:744`). |
| S2 | Trust the PR state alone (`gh pr view` → `MERGED` ⇒ merged) | **REJECTED as stated, ADOPTED as RULE 4 above** — "merged PR ⇒ merged" alone is verify-by-name; the shipped rule adds `pr_oid == this checkout's HEAD`, which is exactly the commit-level fact S2 lacked (name reuse, post-merge commits, force-push-after-merge all fail it — `G14f`). |
| S3 | `git cherry` / patch-id equivalence to detect squash merges | **ADOPTED NARROWLY** — #2354's `patch_equivalent()` (`:1464`) ships as a **second squash signal that lifts the AGE FLOOR only**, never a survival proof (`:96-107` states the ⛔). The original rejection was right about the survival channel and wrong about the floor: there, "equivalent content, maybe reverted" is an acceptable input to *when may this be reaped*, and it is defended by the branch ref still existing. |
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

`refs=` (the reachability evidence) is **UNCHANGED at the merged head** — the second arm that would
have added a `merged-pr:<oid7>` value was dropped (§2.1 S1):

- `merged`                     tip is an ancestor of the resolved main (rule 3)
- `branch-retained:<b>`        unchanged (removal never deletes the branch)

A squash-merged head therefore leaves `refs=branch-retained:<b>` and is removed by **rule 4**, whose
row names the proof it used: `proof=pr-merged <owner/repo#n> state=MERGED head=<sha12>`.

Age floor: `REAP_WT_MERGED_AGE_DAYS` (0) when `refs=merged`, when `patch_equivalent` holds (#2354),
or on rule 4's own merged floor; `REAP_WT_AGED_DAYS` (7) otherwise, and rule 7's
`REAP_WT_MIN_AGE_MINUTES` minimum applies on top of every one of them. Everything else — clean/dirty,
live holder, open PR — is untouched and keeps its order.

**Declared threat surface** (adversarial bound, 2 cycles; out-of-scope classes named below).
⚠️ Rows T1/T2/T4 were written for the DROPPED ancestry arm and are restated against the **shipped**
rule 4 + `patch_equivalent` (§2.1, §6.1):

| # | Threat | Covered by |
|---|---|---|
| T1 | a MERGED PR found by BRANCH NAME that is not about this commit (name reuse, post-merge commits, force-push-after-merge) | the sha identity gate `pr_oid == $sha` ⇒ no evidence, and the row says so (`pr-merged-other-head=`). **Test: G14f** (mutation: dropping the equality turns it red) |
| T2 | merged-PR list truncated (`--limit`) | **A row count AT the bound is a REFUSAL** (`pr_state_load`, exit 3, nothing removed) — an absent row is not "no PR". Test: **G5c**-adjacent shard (`A8` pins the call shape); truncation is exercised by the `GH_STATE=truncated` seam |
| T3 | merged-PR list unavailable / gh down / gh unauthenticated | no evidence ⇒ preserve; recorded `pr_merged=unavailable`; the PR gate exits 3 (skipped repo, `pr_merged=` + `detail=` naming it). **Test: G5c** |
| T4 | a rebase-with-commit (or any strategy) merge | rule 4 reads PR STATE, so strategy cannot matter — it is strictly stronger than the dropped `mergeCommit`-ancestry arm. **Test: G14** (squash, head not an ancestor), **G14b** (detached head matched by sha) |
| T5 | stale / narrowed local `origin/main` | remote main resolved via push-url `ls-remote --symref`; local only as fallback, and recorded (`main_proof=`). **Test: G6f** |
| T6 | origin has no push url / >1 push url / ls-remote fails | fall back to local ref, recorded. No removal decision depends on it alone |
| T7 | merged proof shadowing the open-PR veto | the open-PR veto is checked **before** rule 3/4 and returns. **Test: G5a** |
| T8 | installed unit masked by a drop-in (the 127 unit) | read-back parses the *artifact systemd loads*. **Test: T58** |
| T9 | partial write / truncation of the installed unit | read-back requires a non-empty effective `ExecStart` list containing our target. **T58 covers the drop-in MASK; the no-`ExecStart`-at-all branch is refused by the same function but has no dedicated test** (see §6.2) |

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
        main_ref=<refs/heads/…|refs/remotes/…|?> pr_merged=<ok|unavailable|na>
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
would be a false block on a working cell (T58 asserts it is accepted AND still verified). On macOS
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
| **G14** squash-merged worktree, **outside** the repo root, merged-PR evidence present | bare `origin` + a worktree whose HEAD is NOT an ancestor of main, PR says MERGED for that sha | rule 3 cannot see a squash ⇒ `branch-retained` ⇒ `too-recent` ⇒ preserved |
| **G14b** detached head matched by head sha | `worktree add --detach` at the squash sha, PR row keyed by `headRefOid` | a detached head has no branch name ⇒ rule 4 could not name it |
| **G14f** (mutation guard) MERGED PR for a REUSED branch name, HEAD ahead of it | gh reports MERGED for the OLD sha, the checkout holds new work | must still preserve, and NAME the other-head PR — fails if the `pr_oid == HEAD` gate is dropped |
| **G14c/G14d** CLOSED-unmerged / no PR | — | must preserve (rules 5/6), named |
| **G6e** rule 7 gates rule 4 | 60s-old checkout with a MERGED PR (`REAP_WT_TREE_TS`) | the merged floor must not short-circuit the 45-minute minimum |
| **G6f** stale local `refs/remotes/origin/main` + the real clock | stale-but-existing tracking ref; and a seconds-old checkout whose HEAD is 76d old | a missing/stale tracking ref falls through to local `main`; the floor must still hold |
| **G6d** merged exemption | MERGED head 2d old, floor pinned to 7d as a control | the exemption is unrecorded / the floor is bypassed silently |
| **T59** (SUMMARY tally) in `disk-reaper.test.sh`, **A14i** in `pi-reap-worktrees.test.sh` | a stub delegate printing the real SUMMARY shape; and a REAL pass for the identities | no SUMMARY line exists — the tally contract lives in the entry-point suite (§1.3/§2.3), and nothing checks the delegate's own arithmetic |
| **T58** installed-artifact read-back | override unit dir + a `*.service.d/` drop-in masking `ExecStart` to a `mktemp` path | install exits 0 and reports "installed" over a unit that would 127 |
| ~~T53~~ (not written — folded into **T58**: the drop-in mask and the moved `HOME` are the two shapes an operator actually hits. **T59** carries the tally contract: per-repo sums, the merged `reasons=` histogram, and the `?`/`not-run` sentinels; **T60** carries a class that could not be SET UP) | — | — |
| A8 | one batched gh call (`--state all`, explicit limit) carrying `state` + `headRefOid` | — (contract change, asserted) |

⛔ **The tests DROPPED with the arm:** `G6h` (a merged PR whose `mergeCommit.oid` is not on main),
`G6i` (merged-evidence read fails), `G6k` (gone-dir + a merged PR ⇒ still `detached-unreachable`).
They tested the ancestry arm that rule 4 replaced. What they protected is now structural: rule 4
fires only in the REMOVAL path and still runs after `commits_survive`, so merge evidence can never
reach the reachability decision the way the lost P0 did — pinned by **G3a** (`detached-unreachable`
preserved), **A24** (gone-dir record held only by a revocable ref blocks the prune) and **G10**
(gone dir + unreachable sha).

---

## 4. Wiring check

- entry: `disk-reaper.sh` (delegate call, class line, status fields) → `pi-reap-worktrees.sh`
  (`resolve_remote_main` → `pr_state_load` → `commits_survive` → `classify_one` → SUMMARY)
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
| P3 test IDs T52/T53 collide with the suite's existing T52/T53 | **Fixed** — new tests are **T58** (install read-back) and **T59** (tally contract: per-repo sums, merged histogram, `?`/`not-run` sentinels), later joined by **T60** (a class that could not be SET UP reports neither a verdict nor a count it never computed) |
| **Code-review cycle 1 (reviewer B, adversarial)** P0: the `Environment=` read-back was a line match, so `Environment=PATH=… HOME=/dead` and `Environment="HOME=/dead"` both passed as "verified" | **Fixed** — `effective_env()` parses every `Environment=` line the way systemd does (list, quotes, last-wins, bare-reset); HOME and the delegate pins are read from that map. 8 new T58 assertions |
| Reviewer B P1: the launchd arm verified only the executable, so a stale plist carrying `--dry-run` reported "installed" | **Fixed** — the plist arm asserts the mode flag and `EnvironmentVariables.HOME`, and names the fact it could not verify; T20 pins the positive control |
| Reviewer B P2: the venv tally was read from the FIRST repo only (`grep -m1` outside the loop) | **Fixed** — lifted inside the repo loop and summed, like the worktree arm; 3 new T59 assertions |
| Reviewer B P2: an unanswerable tally was recorded as a measured `0`/`none` (the `${x:-?}` default could never fire) | **Fixed** — `_tally_num`/`_tally_rec` carry `?` (ran, no tally) and `not-run` (class not selected) into the class line and the record; T7/T59 pin both |
| Reviewer B P2: per-repo `reasons=` histograms were concatenated, not merged | **Fixed** — accumulated as `reason count` rows and folded into one descending histogram; T59 pins the sum |
| Reviewer B P2 (informational): `candidates_*` are now populated on armed passes — no verdict depends on them | **Recorded, and CORRECTED by a later review** — true for `worktree` and `venv` (both lift a tally in both modes) and now for `duplicate-install` (its owner prints `SUMMARY … candidates=` in both modes), but NOT for `uv`: its owner publishes no tally, so an ARMED uv pass records `candidates_uv=?` rather than the initialised 0. Verified inert for every verdict: `CAND_WT` feeds only the dry-run over-bound verdict |
| Reviewer B P3: two `say` calls had been joined on one line in the installer | **Fixed** |
| Reviewer B P3: `REAP_WT_MERGED_AGE_DAYS` was missing from the numeric-seam validation (a non-numeric value aborted `classify_one`'s subshell, printing a reason-less preserve row) | **Fixed** — validated with a range check up front; A14h pins it |
| **Code-review cycle 2** P2: `effective_env` accepted an `Environment=` word with an UNTERMINATED QUOTE, which systemd rejects and abandons — so the install certified a HOME the unit would never get (a fail-open the pre-fix line match did not have) | **Fixed** — an unbalanced quote discards that line AND is reported; the install refuses naming it. **T58 pins the refusal** |
| **Drainer review at `13d6c29c`** P1: `candidates_venv` was reported as a MEASURED `0` while the class had candidates — `have_venv_tally` was set on `venvs_found=` alone while `reapable=` (the field the count comes from) was parsed opportunistically, and the same flag then suppressed the row-count fallback | **Fixed** — the answered predicate requires **both** core counters to parse (the worktree arm's `${f:-x}` per-field form), so a half-answer keeps `?` and the REAP rows the pass scanned are no longer discarded; **4 new T60 assertions** |
| **Drainer review** P2: a truncated `SUMMARY` fabricated the affirmative `reasons=none` (`reasons` is a TAIL field, so a line cut after `failed=0` is the likeliest truncation) | **Fixed** — the `none` normalisation now requires `reasons=` to have been READ from every SUMMARY the pass accepted, so an unread field stays `?` |
| **Drainer review** P2: the entry-point suite was not hermetic — `run_reaper` pinned no `REAP_WT_MAIN_PROOF`, so T55's fixtures (real `github.com` origins) issued real `git ls-remote` calls | **Fixed** — pinned to `local` in the runner, with T3 opting into `auto` explicitly (its origin is a LOCAL BARE repo, so it stays offline) |
| **Drainer review** P2: `main-proof-vanished` had no entry in the operator reason table, and the row wore `rule=3` — a REMOVE number — on a KEEP row | **Fixed** — the reason is documented, and the row carries `rule=P would-remove=3`, so `grep ' rule=3'` cannot read a preserve as a removal (the first cut said `would-be-rule=3`, which still matched) |
| **Code-review cycle 3** P1: the venv candidate count was fixed per REPO and left broken per CLASS — `have_venv_tally` is set by ANY repo, so on a two-repo pass where one repo answered `reapable=0` and the other was truncated after a `REAP` row, the partial sum suppressed the row-count fallback and the class published `candidates=0` beside the candidate it had just named | **Fixed** — FULL coverage (`venv_tally_repos = venv_repos`) is what makes the sum an answer; otherwise the dry count is the row the pass scanned and the three class counts stay `?`. **T60 pins a two-repo partial pass, both surfaces** |
| **Code-review cycle 3** P1: the `uv` class LINE printed the raw counter while the record printed `?`, so a refusal said `candidates=0` on the operator surface beside `candidates_uv=?` in the record | **Fixed** — the line uses `_tally_num "$HAVE_UV_CAND" "$CAND_UV"`, and T60 asserts on the LINE (the earlier cut read only the record, so it could not fail) |
| **Code-review cycle 3** P1: `duplicate-install` claimed a measured count on BOTH arms that measured nothing — the dry sentinel was set unconditionally, and the armed lift accepted the delegate's REFUSAL SUMMARY, which prints `candidates=0` by construction (`census=unreadable`) | **Fixed** — the lift requires `census=ok`, the dry sentinel requires a `remove` row or a `census=ok` answer, and the class line uses the sentinel. **T60 pins a refused census** |
| **Code-review cycle 3** P2: the entry-point suite was still not hermetic — the pin was added only to `run_reaper`, but T55c invokes the delegate directly, and `resolve_remote_main` runs BEFORE the gh gate it exercises | **Fixed** — that call pins `REAP_WT_MAIN_PROOF=local` |
| **Code-review cycle 3** P2: four findings could ship green because no assertion read the field they broke (uv class line, dup refusal, two-repo venv partial, `rule=3` token), and one comment claimed the opposite of the code | **Fixed** — one discriminating assertion per arm, and the stale comment corrected |
| **Own audit of the uncommitted fix round** P1: the duplicate-install SUMMARY lift was pasted at the FIRST `rows="…"` line in the file — `reap_venv`'s — where it incremented GLOBALS nothing promoted while `reap_dup` read its own `local …=0`, so an armed dup pass still recorded `candidates_duplicate_install=0` | **Fixed** — the lift moved into `reap_dup`'s root loop; **T60 fails without the move** |
| **Own audit** P1: the one-rule `CAND_TOTAL` loop demanded `want && have` for EVERY class, so every single-class pass printed `candidates=?` — and its first correction then let a `misconfigured` class back in as an invented `0` (the setup-failure arms reset `WANT_*=0`) | **Fixed** — "selected" is `WANT=1` **or** `VERDICT=misconfigured`; deselected is silent, selected-but-unmeasured is `?`. **Both directions pinned in T60** |
| Cycle 2 P2: the plist TEXTUAL fallback (no usable parser) required only that the reaper path appear somewhere, so a stale `--dry-run` artifact read as installed — and the message claimed the parser was absent even when present-but-failing | **Fixed** — the fallback requires the mode flag too and names `EnvironmentVariables.HOME` as NOT verified; parser stderr is kept and shown to the operator when the parser FAILED (on the acceptance AND the refusal branch). **T58b pins all five halves, and asserts the parenthetical EXACTLY (a substring match was green over a doubled message — `${perr:-…}` is not an else)** (function driven from the live script, so no drift) |
| Cycle 2 P2: the venv counters were still printed raw (`0` beside `verdict_venv=not-run`) | **Fixed** — the venv arm publishes `HAVE_VENV_TALLY`/`HAVE_VENV_CAND` and uses the same `_tally_rec` sentinels; **T59 pins not-run / `?` / answered** |
| Cycle 2 P2: a DRY pass whose delegate only REFUSED recorded `candidates_worktree=0` | **Fixed** — candidates are answerable only from classification rows (`remove`/`preserve`/`SUMMARY`) or a tally; **T59 pins the refusal → `?`** |
| Cycle 2 P2: a half-answered class (only some repos printed a tally) looked complete | **Fixed** — `tally_worktree=`/`tally_venv=` record `<answered>/<scanned>`; T59 pins `tally_venv=2/2` and `tally_worktree=not-run` |
| Cycle 2 P3: the histogram merge glob-expanded the delegate's reason tokens (unquoted `$(…)`), so a `*` became file names from the pass CWD | **Fixed** — the loop splits with `set -f`; the counts can no longer come from the filesystem |
| Cycle 2 P3: an ANSWERED `reasons=none` degraded to `?` | **Fixed** — no reasons is a result; **T59 pins `preserved_reasons_worktree=none`** |
| — | External research: **justified skip** (local git safety predicate; the precedents are in-repo and were then read). |

### 5.2 solution-verify — cycle 1 (1 fresh-context adversarial verifier)

Verifier: **P0=2**, P1=6, P2=5, P3=4.

| Finding | Action |
|---|---|
| **P0** `refs=merged-pr` put the merge proof in the **survival** channel (`commits_survive` returns early) ⇒ on the gone-directory/`prunable` path it would waive the reachability gate and the global prune would deregister the admin HEAD — the last durable handle of a detached commit | **Fixed** — merge evidence never enters `commits_survive`; the arm was confined to the age floor. ⚠️ **At the merged head the arm itself is gone** (§2.1 S1, §6.1): `main` shipped RULE 4, which decides the same class in the REMOVAL path, after `commits_survive` has already decided reachability — so the channel separation the P0 asked for holds structurally. The dedicated test **G6k** was dropped with the arm; the reachability gate it guarded is pinned by **G3a**, **A24** and **G10** |
| **P0** the waiver keyed on the branch NAME: name reuse, HEAD ahead of the PR head, and force-push-after-merge all waive a live checkout | **Fixed, and now by RULE 4** — the shipped evidence is `pr_state = MERGED && pr_oid == this checkout's HEAD` (`pi-reap-worktrees.sh:1727-1753`). Name reuse ⇒ different tip ⇒ no evidence; post-merge commits ⇒ no evidence. **Test: G14f** (plus its control: the same fixture IS rule-4 reclaimable when the oid matches) (§6.1) |
| **P1** a shared read-back would false-block macOS (launchd has no `ExecStart`) | **Fixed** — target-dispatched: `verify_installed_unit()` (systemd) / launchd arm checks `ProgramArguments` identity |
| **P1** "installed file as fallback" *is* the fail-open: `/run/systemd/system/*.d` drop-ins are invisible to a file read | **Fixed** — for `system`/`user`, `$SC cat` must answer or the install REFUSES; the file path (plus merged `<unit>.d/*.conf`) is used only for `TARGET=override`, and it merges drop-ins itself. The t8 shim gains `cat` |
| **P1** `EnvironmentFile=keys.env` is arbitrary shell; systemd applies it *after* `Environment=`, so a `HOME=` line silently overrides the HOME the read-back certifies | **Dropped** — no `EnvironmentFile`. The installer instead **resolves `gh` in the rendered environment and reports it** (`gh=<path|MISSING>`); the class already fails closed (exit 3, red) when gh is unavailable |
| **P1** appending `$HOME/.pi/agent/shims` to PATH contradicts a recorded decision (install-launchd.sh **excludes** `/shims` — macOS TCC EPERM) and is inert (appending cannot outrank the real gh) | **Dropped** — not reopening a recorded decision; gh resolvability is reported instead |
| **P1** the new network probe needs an explicit seam or three existing fixtures become host-dependent | **Fixed** — `REAP_WT_MAIN_PROOF=auto|local`, `REAP_WT_MAIN_PUSH_URL`, `GIT_TERMINAL_PROMPT=0`, and `run_reaper` pins every fixture to `local` |
| **P1** G6f would be vacuous (a missing `refs/remotes/origin/main` falls through to `refs/heads/main`) | **Fixed** — G6f requires a stale-but-EXISTING tracking ref with local `main` reset *behind* it, plus a `REAP_WT_MAIN_PROOF=local` control on the same fixture |
| **P1** the gh shim is argument-blind; a SEPARATE call per state feeds open-list payloads into the merged loader, and `FAKE_GH_FAIL` fails both calls so the merged-evidence arm cannot observe anything | **Fixed at the time, then MOOT at the merged head** — the read is now ONE `gh pr list --state all` call carrying `state` + `headRefOid` (`pr_state_load`, `:1210`), so there is no second loader to confuse; A8 pins that the single call carries both fields |
| P2 the SUMMARY must reconcile (`PRESERVE_C` already includes `DEFERRED`; `REMOVE_C` counts rows later preserved/failed) | **Fixed, then corrected again by the VGATE reviewer** — a single `classified = remove + preserved + deferred` claimed a decision for records the budget never classified and did not reconcile on a deferral (measured `classified=2 … deferred=15` on 16 records). The line now carries `examined=` and TWO identities: `classified = remove + preserved` and `examined = classified + deferred`; `preserved` EXCLUDES deferrals; apply-only `removed/failed/late_preserved/prune_blocked`. Asserted by **A14i** (both identities on a REAL pass), **A7** (dry budget-deferred) and **A7 armed** (remove-time deferral, which has its own `deferred_remove=` counter) |
| P2 `main_proof`/`pr_merged` are per-repo but the class line is one line | **Fixed** — counts summed; a differing proof across repos reports `mixed` |
| P2 `auto` can report a main SHA that is not in the local object DB (the stale cell case) | **Fixed** — `git cat-file -e <sha>^{commit}` first; `auto-unfetched` + no waiver |
| P2 `get-url` (singular) cannot detect multiple push urls | **Fixed** — `git remote get-url --push --all`; ≠1 ⇒ `ambiguous` |
| P2 hardcoding `refs/heads/main` regresses master-default repos | **Fixed** — `ls-remote --symref <push_url> HEAD` first |
| P2 rule 5 (missing delegate ⇒ refuse) over-blocks: a cell missing one delegate would lose the class it CAN run | **Fixed** — stays a WARNING (the recorded decision); the read-back reports it, the unit goes red |
| P3 multiple `ExecStart=` is legal for `Type=oneshot` | **Fixed** — the check is "the rendered ExecStart is present among the effective ones" |
| P3 S3's rejection reason mis-states the decisive fact (patch-id cannot detect a squash at all) | **Fixed** — §2.1 S3 |
| P3 "falsified" is repo-relative; a worktree of a repo absent from `DISK_REAPER_REPOS` is still invisible | **Recorded as a residual** in §6.2 |
| P3 "covers rebase-with-commit" unverified | **RESOLVED by the merged head** — rule 4 keys on PR state, not on a `mergeCommit` oid, so a rebase merge (and a null `mergeCommit`) is decided identically; the question no longer has a code path to be wrong about |
| P3 G5a is not a test of "merged proof does not shadow the open-PR veto" | **Fixed** — the name-reuse fixture (old merged PR + new OPEN PR, same head ref, different tip) is its own test, asserting `reason=open-pr` |

Both P0s were safety findings in destructive code; nothing was dismissed. No re-dispatch was needed
for ignored findings (none were ignored); cycle 2 is the code-review gate (§7).

---

## 6. Final contract

### 6.1 Merge evidence (the only thing the waiver rests on) — **AS SHIPPED**

⚠️ This section was rewritten at the merge: the second arm it originally specified
(`merged_pr_ev` = `is-ancestor(pr.mergeCommit.oid, RESOLVED_MAIN)`) **is not in the code**, because
`main` landed #2721's RULE 4 while this branch was in review and rule 4 decides the same class with a
stronger, strategy-independent proof. Shipped predicate:

```
scripts/pi-reap-worktrees.sh:1727-1753   RULE 4 — a MERGED PR for this head, whatever the strategy
  pr_state == MERGED                          # from ONE `gh pr list --state all` read
  pr_oid    == <this checkout's HEAD sha>     # the evidence is about THIS commit (G14f)
  ⇒ remove, at REAP_WT_MERGED_AGE_DAYS (0), still gated by rule 7's minimum age (G6e)
     row: remove\treclaimable\t…\trule=4 refs=<refs> proof=pr-merged <slug>#<n> state=MERGED head=<sha12>
```

`refs=` is untouched by it: a squash-merged head is still `refs=branch-retained:<b>`, and rule 4
never touches `commits_survive` (the reachability gate) nor the `refs=merged` ancestor test of rule 3.

`REAP_WT_MERGED_AGE_DAYS` is lifted by three inputs, in this order (`:1605-1622`):

1. `refs=merged` (rule 3, ancestry) — the strongest proof;
2. `patch_equivalent()` (`:1464`, `git cherry`) — the #2354 squash signal, **age floor only**
   (`:96-107` carries the ⛔: it is neither reachability nor present state, and a squash later
   reverted still reads equivalent, which is why it can never appear in `refs=`);
3. rule 4's own merged floor, which applies even when `git cherry` cannot see a multi-commit squash.

`RESOLVED_MAIN` = `ls-remote --symref <push_url> HEAD` → `refs/heads/<n>` → its oid, when
`REAP_WT_MAIN_PROOF=auto` (default) and the oid is present locally; otherwise the existing local
`MAIN_REF` chain. This half **ships unchanged** (`resolve_remote_main`, `:744`) and is reported per
pass as `main_proof=<auto|auto-unfetched|ambiguous|unavailable|local>` in the SUMMARY line, alongside
`pr_merged=<ok|na|unavailable>` (whether the PR read was answerable at all — not a waiver).

### 6.2 Residuals (named, not fixed here)

- A checkout whose HEAD is *ahead of* its merged PR head keeps the 7-day floor — by design: those
  commits are unlanded. On a live cell the per-worktree `.venv` (the venv class, already installed)
  is the reclaimable part; the checkout itself ages out.
- A merged-then-reverted PR still reads merged. Removal never deletes the branch ref, so nothing is
  orphaned; the checkout can be regenerated from it.
- A worktree belonging to a repo that is not in `DISK_REAPER_REPOS` is not enumerated. Coverage is
  the union of the configured repos, not the filesystem. (A second scan root is exactly the stale
  cache the issue's fix #1 rejects.)
- **A truncated install** (no `ExecStart=`) is refused by the read-back, but T58 only drives the
  drop-in *mask* — the mask resets the list, so the "no ExecStart at all" branch is exercised as a
  side effect rather than by a test that writes the shape deliberately.
- **A stale launchd plist** is refused on the same facts as the systemd unit (executable, mode flag,
  `EnvironmentVariables.HOME`), but launchd has no drop-in equivalent, so no seam produces
  "written but stale": T20 is a positive control for the checks, not a negative one.
- **One `gh` call per repo per pass** (`pr list --state all`), plus the origin-remote probe for the
  slug. Its soft-fail behaviour is a KEEP (rules 5/6 + `pr_merged=unavailable`), never a removal.
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
