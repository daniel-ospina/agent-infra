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
| `pi-bootstrap/setup.sh` `fleet_srcs` farm | bootstrap | #1858; `pi-bootstrap/tests/test-setup-no-nesting.sh` | ✅ |
| Reaper removal-path behaviour | runtime contract | unchanged — no rewiring needed | ✅ |
| Arming the probe/reaper on a schedule | owner decision | out of scope — #1678 | ⚠️ |

## Evidence

| Command | Result |
|---|---|
| `bash scripts/worktree-disk-probe.test.sh` | 64 assertions, 0 failed |
| `bash scripts/pi-reap-worktrees.test.sh` | 251 passed, 0 failed |
| `bash scripts/install-launchd.test.sh` | PASS=132 FAIL=0 |
| `bash tests/ci-lane-parity/run.sh` | 90 assertions passed |
| `bash pi-bootstrap/tests/test-setup-no-nesting.sh` | fleet_srcs farmed byte-identical |
| `bash scripts/run-bash-shards.sh --list` | probe suite registered |

## Review provenance

Review evidence for this plan/PR is recorded in commit messages on
`fix/1851-worktree-disk-measure` (see the `code-review` commit on PR #1858). The probe's
hermetic suite asserts the fail-closed paths (`df` unreadable before/after, no `du`-only
"real" claim, removal refusals) so a broken live path cannot pass behind the `DF_BIN`/`DU_BIN`
seams.
