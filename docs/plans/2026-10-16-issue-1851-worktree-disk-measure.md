---
title: "Plan: agent-infra#1851 — measure worktree disk per machine with a df used delta, not an asserted APFS ratio"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra-1851, issue-1095, worktree-disk-probe.sh, pi-reap-worktrees.sh, uv-cache, false-pass, apparent-vs-real
---

# Plan — agent-infra#1851 → per-machine worktree disk measurement

> Status: **shipped on `fix/1851-worktree-disk-measure` (PR #1858)**. This doc is the
> plan/evidence record the pipeline-compliance gate requires for a `complexity:standard`
> issue; the code and its evidence suites landed in the same PR.
> Refs: agent-infra#1851 (fix), agent-infra#1095 (the reaper doc this corrects),
> agent-infra#1678 (arming / inert enforcer), agent-infra#1765 (disk observability floor).

## Confirmed problem

Everywhere the fleet reasoned about worktree weight it used `du` (apparent bytes) and
translated that into real disk with one hard-coded ratio justified by a mechanism that
does not hold everywhere:

> Per-worktree `.venv`s are hardlinked to the uv cache, so `du` over-reports them
> (measured: 84 GB `du` delta vs 22 GB actually freed).

The **number** is a real observation; the **mechanism** is falsified. The apparent→real gap
is a **sharing** property of the filesystem, so it is **per-machine** — and the machines
that filled are the ones where the sharing does **not** happen.

This is a **category A false PASS**: the size of an estate is measured in apparent bytes,
so a machine that is about to fill reads the same as one that is not, on a figure that had
not been revalidated per machine since 2026-09-15.

## Root cause

`du` reports allocated *apparent* bytes per file; `df` reports *real* block allocation of a
volume. They diverge exactly when two paths share blocks: APFS copy-on-write `clonefile`,
or a hardlink into the uv cache. Sharing is a property of the **volume pair** (the estate's
volume vs the cache's volume) and of the **link mode** (`uv --link-mode`), so no single
ratio is portable. A ratio asserted from one machine is wrong on another; a `du` figure is
honest only as an upper bound.

## Plan

1. **Publish a per-machine probe** — `scripts/worktree-disk-probe.sh`. Non-destructive by
   default: it prints the volume row, the `du` upper bound, the estate/uv-cache
   same-volume identity, and the sampled `nlink` regime. `--measure-removal PATH --repo R
   --yes` runs ONE `git worktree remove` (**no** `--force`, so git's own refusal is the
   second gate and branch refs survive) and reports **both** `du -sk` and the real figure
   as a `df -Pk` **`used`** delta, plus their ratio.
2. **Read `used`, not `avail`** — `avail` drifts with concurrent writes (measured ~1 MB/s);
   `used` moved monotonically by exactly the freed bytes.
3. **Fail closed** — an unreadable `df`/`du` yields exit 3, never a number that was not
   read; a removal refusal yields exit 4.
4. **Correct the reaper's stated reason** — `scripts/pi-reap-worktrees.sh` keeps NEVER
   calling `du` and NEVER claiming a byte saving (its contract is unchanged); its header and
   runtime honesty line now carry the measured three-regime model and point at the probe.
5. **Correct the scoping doc** — `docs/scoping/2026-09-15-issue-1095-worktree-reaper.md`
   §3.5 keeps the old claim for provenance, marks it `⛔ FALSIFIED 2026-10-16 (#1851)` and
   replaces it with the measured three-regime model, the published command, and the three
   scope decisions the issue left open.
6. **Farm the probe** — `pi-bootstrap/setup.sh` `fleet_srcs` gains `worktree-disk-probe.sh`
   so a cell has it at `~/.pi/agent/scripts/` where the estate lives.
7. **Correct the two operator-facing docs that restated the falsified claim** —
   `docs/ops/disk-reaper.md` ("Byte accounting") and `docs/ops/lane-venv-reaper-policy.md`
   ("Byte accounting" + "The `uv` cache is never touched") are the policy docs for the two
   scripts this lane rewrites, and both still carried the universal hardlink claim
   unmarked — so the repo contradicted itself on the one mechanism the issue falsifies,
   in the docs operators use for capacity reasoning. Both now mark it
   `⛔ FALSIFIED 2026-10-16 (#1851)`, carry the measured three-regime model, and point at
   `scripts/worktree-disk-probe.sh`. Each box's own measurement (cell-2 77,438 MB vs
   1,330 MB; cell-3's cache prune) is kept and labelled as THAT box's regime, not a law.

**Scope decisions (the issue's three open questions), recorded in §3.5:** (1) the reaper
keeps renouncing byte claims and the probe measures — a per-pass `df` delta on a shared box
has no attribution; (2) the per-machine disk budget stays the #1765 observability floor,
not a dispatch gate; (3) no new multi-repo/multi-machine owner — the probe is repo-agnostic;
ownership stays #1678 / #1759 and is not restated.

## Wiring Check

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `scripts/worktree-disk-probe.sh` (new probe) | script | #1858 | ✅ |
| `scripts/worktree-disk-probe.test.sh` (new suite) | test | #1858, registered in `scripts/run-bash-shards.sh` | ✅ |
| `scripts/pi-reap-worktrees.sh` header + honesty line | script (comment/UX only) | #1858, pinned by `pi-reap-worktrees.test.sh` A9 | ✅ |
| `docs/scoping/2026-09-15-issue-1095-worktree-reaper.md` §3.5 | doc | #1858 | ✅ |
| `docs/ops/disk-reaper.md` "Byte accounting" (+ the uv-cache class note) | doc | #1858 (same correction, operator-facing) | ✅ |
| `docs/ops/lane-venv-reaper-policy.md` "Byte accounting" + "The `uv` cache is never touched" | doc | #1858 (policy doc for `reap-lane-venvs.sh`) | ✅ |
| `pi-bootstrap/setup.sh` `fleet_srcs` farm | bootstrap | #1858; `pi-bootstrap/tests/test-setup-no-nesting.sh` | ✅ |
| Reaper removal-path behaviour | runtime contract | unchanged — no rewiring needed | ✅ |
| Arming the probe/reaper on a schedule | owner decision | out of scope — #1678 | ⚠️ |

## Evidence

Re-measured at the THIRD review-fix head, after merging `origin/main` — a count that carries no
revision drifts (three review cycles found this table quoting a smaller number than the tree
prints: 251 for a suite then at 258, then 90/94/144, then 151 for `reap-lane-venvs` which
`origin/main`'s own #1949 commit took to 180). Every number below is the printed total from this
head, not a re-derivation.

| Command | Result |
|---|---|
| `bash scripts/worktree-disk-probe.test.sh` | all **110** assertions passed (64 at first push; +A2b/A3b/A5b/A11b/A13b/A13c, then +A2c/A5c for the second review) |
| `bash scripts/pi-reap-worktrees.test.sh` | **258** passed, 0 failed |
| `bash scripts/reap-lane-venvs.test.sh` | **185** assertions, ALL PASS (was 151 before this lane merged `origin/main`, whose #1949 commit grew that suite) |
| `bash scripts/disk-reaper.test.sh` | **391** assertions, ALL PASS |
| `bash scripts/install-launchd.test.sh` | **PASS=146 FAIL=0** (the drive-by is reverted: the file is byte-identical to `origin/main` — see below) |
| `bash tests/ci-lane-parity/run.sh` | 90 assertions passed |
| `bash pi-bootstrap/tests/test-setup-no-nesting.sh` | fleet_srcs farmed byte-identical **47/47** (the rebase correctly dropped the retired `queue-dispatch.py` from the farm, so the old 48/48 row described the PRE-rebase list) |
| `node extensions/main-worktree-guard/test-discard-gate.mjs` | 479 passed, 0 failed |
| `bash scripts/run-bash-shards.sh --list` | probe suite registered |

The launchd drive-by is **gone, not justified**: `scripts/install-launchd.test.sh` is now
byte-identical to `origin/main` (`git diff origin/main -- scripts/install-launchd.test.sh` is
empty). `main`'s own note (`:49-53`) records that the suite-wide `unset` at `:43` is the ONE
place that decides hermeticity, and that a second per-variable `unset TORTOISE_REPO` there was
deliberately dropped; #1851 re-added it on the strength of a PASS/FAIL delta that no line here
could have produced (`resolve_env` treats set-but-empty exactly like unset,
`install-launchd.sh:84-85`). Adopting over that recorded decision is a reopen, not a drive-by —
and it was not even a behaviour change. §1's count stays DERIVED (`9 + GATED_INSTALLED1`), the
gated inventory is pinned at 3, and `main` keys the ambient-leak case on `GATED_VISIBLE1`
(derived from the filesystem) so a host that resolves a tortoise checkout stays green while a leak
that no disk candidate explains reds — i.e. the residual that block named is controlled on
`main`, and nothing here needs to control it again.

## Review provenance

Review evidence for this plan/PR is recorded in commit messages on
`fix/1851-worktree-disk-measure` (see the `code-review` commit on PR #1858). The probe's
hermetic suite asserts the fail-closed paths (`df` unreadable before/after, no `du`-only
"real" claim, removal refusals) so a broken live path cannot pass behind the `DF_BIN`/`DU_BIN`
seams.
