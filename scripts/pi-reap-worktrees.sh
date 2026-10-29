#!/usr/bin/env bash
# pi-reap-worktrees.sh — reap provably-reclaimable git worktree checkouts (#1095).
#
# Why this exists: on 2026-09-15 the `tortoise` repo had 407 worktrees and
# `.worktrees/` was 179 GB against ~2 GB of repo content; the working tree held
# 2,363,772 files and `find . -type f | wc -l` took 188 s. A manual sweep
# removed 163 worktrees with zero data loss — but nothing prevented
# regeneration. This is the reclamation mechanism.
#
# POLICY CONTRACT (per issue #1095). A worktree is removed ONLY when ALL hold:
#   * clean        — `git status --porcelain --ignored=traditional -unormal` is
#                    empty except declared-EPHEMERAL root entries
#   * unreferenced — no live process holds the path (ps argv + a bounded lsof
#                    cwd probe) and the branch is not an open PR head ref
#   * reachable    — the commits survive the checkout's deletion: merged to
#                    main, OR on a NAMED BRANCH (`git worktree remove` deletes
#                    the checkout, NEVER the branch), OR a detached HEAD whose
#                    SHA is held by a `refs/heads/*` ref. A detached SHA on no
#                    such ref would be ORPHANED => preserve — including when the
#                    checkout's directory is already gone, because the admin
#                    record's HEAD is the last thing holding that commit.
#                    A holder OUTSIDE refs/heads/* is PRESERVE: the claim would
#                    be revocable (F3 / #1104) — `fetch --prune` drops
#                    refs/remotes/*, `fetch --prune --prune-tags` drops a
#                    local-only tag, `stash drop` refs/stash, `bisect reset`
#                    refs/bisect/*. Reason is `remote-only-ref` for
#                    refs/remotes/* and `revocable-ref` otherwise, and the ref
#                    is NAMED in both.
#   * aged         — HEAD commit strictly older than REAP_WT_AGED_DAYS (7),
#                    EXCEPT when HEAD is MERGED (refs=merged) or
#                    PATCH-EQUIVALENT: those are the proofs the work landed,
#                    so the age floor has nothing left to protect and such a
#                    checkout can be reclaimed the same day.
#                    REAP_WT_MERGED_AGE_DAYS (0) is the floor for both. A lane
#                    SCRATCH checkout (`wt-*` / `cell-wt-*`, #2354) has its floor
#                    CAPPED at REAP_WT_SCRATCH_AGE_DAYS (1) when that is lower: a
#                    dead lane's scratch dir is not a week's worth of review
#                    surface. The cap only ever LOWERS — a value above the floor in
#                    force has no effect (so 14 does not mean "keep longer"), and a
#                    merged/patch-equivalent scratch row keeps the merged floor.
# Anything failing clean / reachable / unreferenced is SURFACED with its
# deciding reason and NEVER auto-removed.
#
# ── SEVEN-RULE DECISION TABLE (#2721) — every row PRINTS the rule and its proof.
# A KEEP whose reason does not name the evidence it used is indistinguishable from
# a bug, and three of the classes below were unprovable for days because the tool
# could only say "no upstream — cannot prove it is pushed":
#
#   1 live holder — a process whose argv names the path, or whose cwd is the path
#                  or ANY path INSIDE IT (PREFIX, never equality: an exact-match
#                  test deleted a live lane's checkout while the lane stood in a
#                  subdirectory of it — #2721, measured)                        => KEEP
#   2 dirty       — the clean gate: tracked changes, operator data, or a probe
#                  that cannot be evaluated                                 => KEEP
#   3 ancestor    — clean + HEAD is an ancestor of `origin/main`: a commit already
#                  in main cannot be lost (measured: 31 trees, +4.4 GB on cell-1) => REMOVE
#   4 pr-merged   — clean + a PR for THIS HEAD is `MERGED`, any merge strategy
#                  (merge / squash / rebase): after a squash the branch head is
#                  NOT an ancestor of main, and PR state is the only durable
#                  record that the work landed                                 => REMOVE
#   5 pr-closed   — clean + PR `CLOSED` without a merge + head not an ancestor.
#                  Nobody can tell whether that work should land; it is NAMED so a
#                  human can decide                                              => KEEP
#   6 no-pr       — clean + no PR matches this head at all: nothing proves the work
#                  landed ("no PR — cannot prove it is landed"). Past
#                  REAP_WT_AGED_DAYS the pre-existing #1095 aged rule still
#                  governs a checkout whose commits survive on a branch            => KEEP
#   7 too-young   — nothing younger than REAP_WT_MIN_AGE_MINUTES (45) is removable
#                  by rules 3-4. A lane dispatched minutes ago is detached at
#                  main and clean FOR EXACTLY THE SAME REASON an abandoned
#                  checkout is; only time separates them, and the age is the
#                  YOUNGER of HEAD's commit date and the checkout's own ctime
#                  (a checkout made minutes ago from an hours-old main has an
#                  hours-old HEAD — the commit date alone would not have saved
#                  the 4-minute-old lane this floor exists for)                  => KEEP
#
# `rule=P` marks the PRE-EXISTING structural gates that are not one of the seven
# and keep their own semantics: main checkout, self checkout, `worktree lock`,
# unreadable path, bare repo, an OPEN PR head, a commit held only by a revocable
# ref (`refs/remotes/*`, a tag, stash, bisect), and a detached HEAD on no ref.
#
# ⛔ THE TWO PROOFS ARE DIFFERENT CLAIMS. "This tree holds no work" (rules 3-4)
# is git/PR state. "Nothing is using this tree" (rules 1 and 7) is the process
# table and time. The rule that deleted a live lane satisfied the first and
# assumed the second; both are now required, and a read that cannot be
# established is a KEEP.
#
# ⛔ WHAT "FINISHED" MEANS (the durable rule — #1095, #2354). A worktree is
# finished ONLY when LOCAL evidence proves it: its tree is CLEAN (no work that
# exists only here), its head is IN THE BASE (an ancestor of MAIN_REF, OR held by
# a refs/heads/* ref that survives the removal), NO live process holds the path,
# and NO open PR names the branch. ⛔ PATCH-ID EQUIVALENCE TO MAIN_REF IS *NOT*
# A REACHABILITY PROOF and must never be used as one: `git cherry` reports that an
# equal patch appeared SOMEWHERE in main's history, so a change main has since
# reverted still shows `-`, patch-id ignores whitespace, and a DETACHED head whose
# commits all have twins is still on no ref — treating it as "in the base" removes
# a checkout and orphans that commit. Patch equivalence only lifts the AGE FLOOR
# (patch_equivalent()); the survival decision stays with ancestry and ref-holding,
# which is why a squashed lane is reclaimed as `branch-retained:<name>`. The
# branch is never deleted, so "reachable" is a property of the REF, not of the
# checkout: `git worktree remove` removes the directory and nothing else.
# ⛔ TWO THINGS THIS TOOL MUST NEVER DO:
#   1. touch a PRIMARY checkout — the main worktree, or the reaper's own cwd;
#      the gate is `main-checkout` / `self-checkout`, decided by git's own
#      FIRST `worktree list` entry and by canonicalised path containment (a
#      nested lane worktree must never be mistaken for the hub it sits under);
#   2. judge "finished" from a BRANCH NAME — a name is not evidence. `merged`
#      is an ancestor test, never a "looks landed" test, and a branch whose
#      name says fix/ or chore/ is treated exactly like any other.
#
# ⛔ THE OPEN-PR SURFACE IS A VETO — AND AN UNREADABLE VETO IS NOT A PASS (#2354)
# The veto is a PRECONDITION: a worktree whose branch an open PR names must never
# be touched, so a pass that CANNOT read the open-PR list must not remove
# anything it cannot clear. That is why an unreadable `gh` still aborts the class
# (exit 3, nothing removed) — a wrong reap costs a night, an orphan costs disk.
# What #2354 changed is the SURFACE, not the rule: the scheduled wrapper hands
# this script the REAL gh for its read-only query, because routing a bounded
# hourly sweep through the interactive pacing shim meant a wedged shim (a
# self-recursive `AGENT_GH_REAL`, fixed in agent-infra #2266/#2295) made every
# pass reclaim zero while `systemctl` showed it green. A veto that cannot answer
# is a deployment defect to fix, never a licence to skip the veto.
#
# WHY THE MERGED EXEMPTION IS SAFE. The floors protect two different things:
# `clean` protects uncommitted work, `reachable` protects commits, and the
# live-process/live-cwd gates protect a lane that is using the checkout. Age is
# the only blunt one — a proxy for "someone may still be reviewing this" — and
# for a MERGED head that review is over. MEASURED 2026-10-18 on cell-3: the
# single biggest reclaimable checkout (/tmp/cell-t3/.worktrees/dispatch-scout,
# 5.7 GB) was merged, clean and holder-free, and the 7-day floor kept it while
# the box sat at 87% used. An unmerged head is NOT exempt: there the age floor
# still separates "a stale scratch checkout" from "work in progress".
#
# `merged` is REPORTED (refs=merged|branch-retained:<b>|reachable-from:<ref>),
# not binding: the issue's own measured sweep removed 48 "stale-unmerged, no
# open PR" worktrees with the branch retained, and its never-auto-remove list
# names only clean/reachable/unreferenced. See docs/scoping/
# 2026-09-15-issue-1095-worktree-reaper.md §2 for the derivation.
#
# EPHEMERAL ALLOWLIST — the measured sweep treated a per-worktree `.venv` as
# disposable (14 worktrees removed on that basis). The allowlist is the ONLY
# dirt the clean gate tolerates, and it is deliberately narrow: a
# reproducible-from-manifest artifact at the worktree ROOT. Ignored
# (`!! path`) entries are tolerated ONE STEP FURTHER and only for the named
# regenerable-cache classes (IGNORED_REGENERABLE): everything else ignored is
# `ignored-artifact` => PRESERVE. This matters because
# `git worktree remove` does NOT refuse ignored files (verified): without the
# ignored half of the gate, a worktree holding only a gitignored `.env` or
# experiment output would look "clean" and be silently destroyed. The
# regenerable half exists because that protection, applied to `__pycache__`,
# held 212 worktrees on the live estate forever (measured 2026-10-11).
#   Allowlisted UNTRACKED (`??`) entries are deleted explicitly before removal
# because git WILL refuse on them; a refusal is reported, never swallowed.
#   `--force` is never passed and `git branch -D` is never called.
#
# DISK-SAVINGS HONESTY: there is NO single apparent-to-real ratio, because the gap
# is a SHARING property of the filesystem, not of worktrees. Measured 2026-10-16
# (#1851), three regimes: (a) APFS with the uv cache on the SAME volume shares
# blocks by copy-on-write (`clonefile`) — one venv `du` 22.0 MB vs a `df` used
# delta of +0.6 MB, nlink=1 throughout, and a `--link-mode=hardlink` control at
# nlink=2 proving the flag is honoured; (b) hardlinks into the cache (nlink>1)
# make a venv`s marginal cost the CACHE`s — `du` 5,704 MB vs 186 MB actually
# released on a Linux cell; (c) neither (Linux/overlayfs, a cache on another
# mount, `--link-mode=copy`) leaves the venv REAL — 75 worktrees at `du`
# 5,647 MiB vs `df` 5.90 GB released, ratio 1.004. So this script NEVER calls
# `du` and NEVER claims a byte saving: a `du` figure is an upper bound whose
# error is machine-specific and unmeasured. The real, portable win is FILE
# COUNT — the amplification that produced the 10-18 minute repo-wide searches.
# Real bytes are measured per machine, on the machine that removes, by
# scripts/worktree-disk-probe.sh (a `df` used delta), never inferred from `du`.
#
# BOUNDEDNESS (a reaper that hangs the fleet is worse than no reaper):
#   * enumeration is `git worktree list --porcelain [-z]` (admin files only) —
#     never `find .worktrees`, never a directory walk
#   * the clean gate uses --untracked-files=normal, so an untracked dir
#     (`.venv/`, `node_modules/`) collapses to ONE entry — git never recurses
#     into it (verified: 60 files under an ignored node_modules = one line)
#   * EVERY subprocess that can block runs under a watchdog (list / status /
#     ps / lsof / gh / rm / git worktree remove / git worktree prune /
#     merge-base / for-each-ref / log / symbolic-ref / rev-parse / remote
#     get-url) — ONE watchdog, resolved by the shared helper
#     `scripts/lib/bounded.sh` as `timeout` -> `gtimeout` -> an internal
#     background watchdog. macOS has no GNU `timeout` (#2046), so the fallback
#     is what runs there; the status contract is identical (124 == timeout).
#     The three PROPERTY PROBES per record (merge-base, for-each-ref, log) are
#     in that list deliberately: the global budget is only checked BETWEEN
#     records, so an unwatched probe that hangs inside one record hung the whole
#     pass — the exact failure this tool exists to prevent. Each takes the
#     preserving arm on a timeout, so failure is fail-closed, never a pass.
#     `prune` is in the list because it is the ACTUAL removal for every
#     `prunable` row and runs after the loop, i.e. outside the budget's reach.
#     `rm` is in that list because the allowlisted-ephemeral pre-delete
#     (remove_one) is a recursive filesystem delete over a checkout the operator
#     does not control: a huge or NFS-locked `.venv` can block it exactly as it
#     can block `git worktree remove`, and it is the LAST fork on that path.
#   * a GLOBAL wall-clock budget (REAP_WT_BUDGET_SECONDS, 300) bounds the
#     per-worktree work (classification AND removal); unprocessed worktrees are
#     reported `deferred` and preserved. The budget deliberately does NOT start
#     until the per-worktree loop begins: enumeration/ps/lsof already have their
#     own watchdogs, and charging their latency to the budget made a slow host
#     defer EVERY worktree on every pass — a reaper that silently never reaps.
#   * no `find`, `rg -r`, `du`, `lsof +D`, or recursive glob is executed
#   * the removal path re-runs the clean gate TWICE (remove_one): both runs are
#     `status` probes bounded by REAP_WT_STATUS_TIMEOUT, so the TOCTOU re-check
#     cannot itself become the unbounded fork it exists to prevent — and a
#     re-check that cannot be evaluated takes the PRESERVE arm, never a pass.
#
# FAIL-CLOSED: a probe that cannot be evaluated never counts as a pass. Lock
# held / git enumeration failed / ps failed or empty / gh unavailable with
# candidates / log unwritable on an armed pass => exit 3 with nothing removed.
#
# Usage:
#   pi-reap-worktrees.sh [--dry-run] [--apply] [--repo PATH] [--aged-days N]
#                        [--main REF] [--list] [--help]
#
#   (no mode flag)  dry-run: classify + report, remove NOTHING (default)
#   --dry-run       explicit dry-run
#   --apply         armed one-shot pass (or env REAP_WT_DRY_RUN=0)
#   --repo PATH     repo whose worktrees are reaped (default $PWD)
#   --aged-days N   age threshold (default 7; strict >)
#   --main REF      main ref for the merged check (default: auto-detect)
#   --list          print worktrees and exit (no gh / ps / lock / log)
#   --help          this text
#
# Gate order (first failure decides) — keep in sync with classify_one():
#   unparseable-path (poisoned record) > bare > main-checkout > self-checkout >
#   worktree-locked > unreadable-path | prunable > live-process > live-cwd >
#   dirty | ignored-artifact | status-timeout | status-error >
#   detached-unreachable > open-pr > too-recent > reclaimable
#
# PRESERVE reasons and why each one is not a bug:
#   main-checkout          the shared checkout
#   self-checkout          contains the reaper's own cwd
#   unreadable-path        cannot be resolved (perm/unmount) — NOT prunable;
#                          deregistering it would drop a LIVE record. A failed
#                          LEAF stat is not proof of absence: an unresolvable
#                          PARENT preserves too, because with an untraversable
#                          ancestor `[ -e ]`/`[ -L ]` are false for a checkout
#                          that is still on disk
#   prunable               checkout directory already gone, commits survive
#   worktree-locked        `git worktree lock` is set
#   detached-unreachable   deleting the checkout (or pruning the record) would
#                          leave the HEAD commit on no ref at all
#   remote-only-ref        the only ref holding the HEAD is refs/remotes/*,
#                          which `git fetch --prune` can revoke — i.e. the
#                          survival claim would not be permanent. The revocable
#                          ref is NAMED so the operator can decide
#   revocable-ref          the only ref holding the HEAD is outside
#                          refs/heads/* and is revocable (`fetch --prune
#                          --prune-tags` for a local-only tag, `stash drop`,
#                          `bisect reset`). Same argument as remote-only-ref,
#                          and the ref is NAMED. Neither reason blocks the
#                          end-of-pass prune by REASON: the commit is held by a
#                          REF, so for a present-directory record deregistering
#                          the admin record cannot orphan it. A GONE-directory
#                          record is different and still blocks — the admin
#                          HEAD is a gc reachability root, i.e. its last DURABLE
#                          handle — and that is caught by the `prunable` flag
#                          test in the classify loop, not by the reason
#   unparseable-path       the record could not be framed safely (tab/newline)
#   live-process/live-cwd  a process holds the path
#   dirty                  tracked/unparseable changes
#   ignored-artifact       gitignored data that `git worktree remove` will NOT
#                          refuse to delete
#   status-*               the clean gate could not be evaluated => fail-closed
#   open-pr                an open PR head branch
#   too-recent             HEAD commit not strictly older than --aged-days
#   unreadable-head        HEAD could not be dated
#   deferred               the pass budget ran out; the record is UNCLASSIFIED,
#                          so it also blocks the end-of-pass prune (an
#                          unclassified record may be prunable)
#
# OPERATOR NOTE — this script's git target is resolved at runtime, so the
# main-worktree-guard extension's static script-content walker (#1484) blocks
# executing it from a session whose working directory is the shared main
# checkout (its own test suite included). Run it from a session ROOTED IN A
# WORKTREE, from a terminal, or from launchd.
#
# Env seams: GIT_BIN GH_BIN PS_BIN LSOF_BIN RM_BIN REAP_WT_LOG REAP_WT_DRY_RUN
#   REAP_WT_AGED_DAYS REAP_WT_MERGED_AGE_DAYS REAP_WT_MIN_AGE_MINUTES REAP_WT_MAX_DAYS
#   REAP_WT_MAIN_REF REAP_WT_NOW_EPOCH
#   REAP_WT_LIST_TIMEOUT REAP_WT_STATUS_TIMEOUT REAP_WT_PS_TIMEOUT
#   REAP_WT_CWD_TIMEOUT REAP_WT_GH_TIMEOUT REAP_WT_REMOVE_TIMEOUT
#   REAP_WT_GIT_TIMEOUT
#   REAP_WT_BUDGET_SECONDS REAP_WT_STATE_DIR REAP_WT_LOCK_STALE_SECONDS
#   REAP_WT_REPO_SLUG REAP_WT_PR_LIMIT
#   REAP_WT_MAIN_PROOF (auto|local) REAP_WT_MAIN_PUSH_URL
#   REAP_WT_PROC_ROOT
#   REAP_WT_SCAN_CAP (test seam: pins the runaway-guard exhaustion branch, which is unreachable with
#   the derived cap)
# Exit codes: 0 pass completed with nothing failed, 2 usage, 3 fail-closed
# abort (nothing trusted), 4 pass completed but >=1 removal FAILED.
# (`remove_one`'s internal 2 — "the checkout changed since classification, it
# is PRESERVED" — is never a process exit code; it maps to exit 0.)

set -uo pipefail

SCRIPT_NAME="pi-reap-worktrees.sh"
ISSUE_REF="#1095"

GIT_BIN="${GIT_BIN:-git}"
GH_BIN="${GH_BIN:-gh}"
PS_BIN="${PS_BIN:-/bin/ps}"
# REAP_WT_PROC_ROOT — where the process table lives (`/proc`). A seam for the suites, and for an
# exotic host that mounts proc elsewhere; it is read by `proc_start_epoch` ONLY.
REAP_WT_PROC_ROOT="${REAP_WT_PROC_ROOT:-/proc}"
LSOF_BIN="${LSOF_BIN:-lsof}"
# Only the ephemeral pre-delete in remove_one uses this; the script's own
# scratch/log cleanup keeps the real `rm` (it must not be defeated by a seam).
RM_BIN="${RM_BIN:-rm}"
STATE_DIR="${REAP_WT_STATE_DIR:-${HOME:-}/.pi/agent/state}"
REAP_WT_LOG="${REAP_WT_LOG:-$STATE_DIR/pi-reap-worktrees.log}"
LOCK_DIR="$STATE_DIR/pi-reap-worktrees.lock"
REAP_WT_AGED_DAYS="${REAP_WT_AGED_DAYS:-7}"
# The age floor applied to a MERGED head. 0 = reclaim a merged checkout the same day (see POLICY
# CONTRACT); set it equal to REAP_WT_AGED_DAYS for the pre-exemption behaviour.
REAP_WT_MERGED_AGE_DAYS="${REAP_WT_MERGED_AGE_DAYS:-0}"
# RULE 7 — the minimum age (minutes) of a checkout before ANY removal rule may
# act on it. A lane dispatched four minutes ago is detached at main and clean for
# exactly the same reason an abandoned checkout is; only time separates them
# (#2721: an armed pass deleted a live 4-minute-old lane's checkout). 45 minutes
# is comfortably longer than a lane's startup (worktree add + uv sync) and short
# enough not to protect residue past the next hour's pass.
REAP_WT_MIN_AGE_MINUTES="${REAP_WT_MIN_AGE_MINUTES:-45}"
# The age floor for a LANE SCRATCH checkout (`wt-*` / `cell-wt-*` at any depth). A dead lane's
# scratch dir is not the 7-day review surface a named issue branch is: it exists to be thrown away.
# It still keeps every safety gate (clean / no live holder / no open PR); only the AGE differs.
REAP_WT_SCRATCH_AGE_DAYS="${REAP_WT_SCRATCH_AGE_DAYS:-1}"
# Path patterns that mark a lane scratch checkout. Basename match, deliberately narrow: `wt-4212`,
# `cell-wt-diskhyg2` — NOT `wt` or a repo whose name merely starts with `wt`.
REAP_WT_SCRATCH_GLOB="${REAP_WT_SCRATCH_GLOB:-wt-*|cell-wt-*}"
REAP_WT_MAX_DAYS="${REAP_WT_MAX_DAYS:-1000000}"
REAP_WT_DRY_RUN="${REAP_WT_DRY_RUN:-1}"
REAP_WT_LIST_TIMEOUT="${REAP_WT_LIST_TIMEOUT:-30}"
REAP_WT_STATUS_TIMEOUT="${REAP_WT_STATUS_TIMEOUT:-20}"
REAP_WT_PS_TIMEOUT="${REAP_WT_PS_TIMEOUT:-20}"
REAP_WT_CWD_TIMEOUT="${REAP_WT_CWD_TIMEOUT:-5}"
REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-20}"
REAP_WT_REMOVE_TIMEOUT="${REAP_WT_REMOVE_TIMEOUT:-120}"
# Every PROPERTY probe (merge-base / for-each-ref / log / symbolic-ref /
# rev-parse) runs under this: they read the ref store and the commit graph,
# which on a healthy repo are milliseconds and on a hung mount are forever.
REAP_WT_GIT_TIMEOUT="${REAP_WT_GIT_TIMEOUT:-20}"
REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}"
REAP_WT_LOCK_STALE_SECONDS="${REAP_WT_LOCK_STALE_SECONDS:-1800}"
# The bound on ONE batched `gh pr list --state all` read (the whole pass). It must
# exceed the LARGEST repo's total PR count, or the truncation refusal below fires on
# every pass and the worktree class becomes a no-op — which is the failure this whole
# change exists to remove. MEASURED 2026-10-24: daniel-ospina/tortoise has **3,987**
# PRs across all states, so the old default of 1000 would have refused there forever.
# `gh` pages past 1000 (`--limit 1200` returned 1200), so the remedy for a bigger repo
# is this number and not a code change.
REAP_WT_PR_LIMIT="${REAP_WT_PR_LIMIT:-5000}"
REAP_WT_MAIN_REF="${REAP_WT_MAIN_REF:-}"
REAP_WT_REPO_SLUG="${REAP_WT_REPO_SLUG:-}"
# auto = prove "merged into main" against the main the REMOTE reports (ls-remote on the push url);
# local = the local ref chain only. The suite pins this to `local` for every fixture so no test ever
# opens a network connection or changes verdict with the host's state.
REAP_WT_MAIN_PROOF="${REAP_WT_MAIN_PROOF:-auto}"
# Override the push url the resolved main is read from (tests use a local bare repo).
REAP_WT_MAIN_PUSH_URL="${REAP_WT_MAIN_PUSH_URL:-}"

# Declared-disposable, reproducible-from-manifest artifacts tolerated at the
# worktree ROOT. Deliberately narrow — `dist/`, `build/`, `target/`, `.next/`
# are NOT allowlisted (over-preserving is the safe direction, and the operator
# sees the offending path in the reason).
# NO trailing slashes: the match is against a path's basename (`${p%/}` then
# `##*/`), and a slash here silently disables the whole allowlist.
EPHEMERAL=" .venv node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .cache .DS_Store "

# IGNORED-REGENERABLE ALLOWLIST — the ignored (`!!`) half of the tolerance.
# An ignored entry is NON-BLOCKING only when it is pure build/test cache any
# checkout reproduces from its own manifests. Everything else ignored is DATA
# the operator put there deliberately and MUST stay protected: `git worktree
# remove` does NOT refuse ignored files (verified), so this allowlist is the
# only thing between a gitignored `.env` and silent destruction (test G2b pins
# exactly that case).
# MEASURED 2026-10-11 over the live 294-worktree estate: 261 worktrees held
# ignored entries — 212 of them ONLY a class listed below, 49 carrying at least
# one non-regenerable entry (`/private/tmp/fix7773`'s
# `longmemeval_*.report.json`, `tortoise.db`, `data/kind_index/*.npz`,
# `operations/logs/code-review-errors.jsonl`, `supabase-session.js`,
# `website/apps/dashboard/dist/`). That 49 is why "ignored is clean" is wrong
# and why this is a narrow allowlist rather than a blanket rule.
# `*.egg-info` is a suffix rule and is handled in is_regenerable_ignored().
# `.cache` is DELIBERATELY ABSENT: it is the one generic name in the old
# EPHEMERAL list, and the ROOT-only rule it replaced existed precisely to keep a
# NESTED `src/.cache/` out of the tolerant set (operator data, not build junk).
# Every name here is instead tool-scoped, so a nested match is still provably
# regenerable.
IGNORED_REGENERABLE=" __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .DS_Store node_modules .venv .ci-selection .longmemeval_cache .wrangler .playwright-mcp .ipynb_checkpoints htmlcov :memory: "

MODE=unknown
LIST_ONLY=0
REPO=""
MAIN_REF_OVERRIDE="$REAP_WT_MAIN_REF"

# run() state
WT_LIST=""              # path<TAB>sha<TAB>branch<TAB>flags
COMMON_DIR=""
MAIN_CANON=""
MAIN_REF=""
SELF_CWD_CANON=""
SELF_PIDS=""
PS_OUT=""
CWD_OUT=""
GIT_OUT=""
CWD_DEGRADED=0
REMOVED=0
FAILED=0
LATE_PRESERVE=0
# Verdict of the removal-time re-check that caused a late PRESERVE (set by
# remove_one; read by run() so the operator sees WHY, not just "changed").
REMOVE_SKIP_VERDICT=""
DEFERRED=0
# ⛔ A DEFERRED REMOVAL IS NOT A DEFERRED CLASSIFICATION. An armed overrun defers a record whose
# verdict was ALREADY `remove`, so it was classified and selected; folding it into DEFERRED deflates
# `preserved = PRESERVE_C - DEFERRED` and makes the SUMMARY line contradict itself. Own counter.
DEFERRED_REMOVE=0
WT_TOTAL=0
REMOVE_C=0
PRESERVE_C=0
# Records the pass actually DECIDED (a deferred record never reached classify_one).
CLASSIFIED_C=0
# Every preserved reason, space-separated, folded into the SUMMARY line by summary_reasons().
PRESERVE_REASONS=""
GH_STATE=unknown
# RESOLVED_MAIN = the oid the REMOTE reports for its default branch ("" when unprovable), and
# MAIN_PROOF names which source answered so the report can never claim a proof it did not use.
RESOLVED_MAIN=""
MAIN_PROOF="local"
MAIN_REF_NAME=""
# Whether the pass's PR-state read (the merged evidence for rules 4-6) could be evaluated at all.
# `ok` = read and answerable, `na` = no GitHub origin, `unavailable` = the read failed.
PR_MERGED_STATE="unknown"
# Rebound after pr_state_load decides whether the read was answerable.
pr_merged_state_from_gh() {
    case "$GH_STATE" in
        ok)  PR_MERGED_STATE="ok" ;;
        na)  PR_MERGED_STATE="na" ;;
        *)   PR_MERGED_STATE="unavailable" ;;
    esac
}
START_EPOCH=0
# A preserve-classified record that git might ALSO consider prunable makes a
# global `git worktree prune` unsafe (it would deregister a worktree the
# operator asked us to leave alone). Any such record blocks the prune.
PRUNE_BLOCKED=0
PRUNE_WANTED=0

usage() {
    cat <<EOF
$SCRIPT_NAME — reap provably-reclaimable git worktree checkouts ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--repo PATH] [--aged-days N]
               [--main REF] [--list] [--help]

  (no mode flag)  dry-run: classify + report, remove NOTHING (default)
  --dry-run       explicit dry-run
  --apply         armed one-shot pass (or env REAP_WT_DRY_RUN=0)
  --repo PATH     repo whose worktrees are reaped (default \$PWD)
  --aged-days N   age threshold in days (default 7; HEAD must be strictly older)
  --main REF      main ref for the merged check (default: auto-detect)
  --list          print worktrees and exit
  --help          this text

Decision table (env REAP_WT_MIN_AGE_MINUTES, default 45):
  1 live holder (argv/cwd PREFIX inside the tree)      KEEP
  2 dirty / unreadable clean gate                      KEEP
  3 clean + head is an ancestor of origin/main         REMOVE
  4 clean + a PR for this head is MERGED                REMOVE
  5 clean + PR CLOSED unmerged, head not an ancestor   KEEP (named)
  6 clean + no PR at all                               KEEP (named)
  7 younger than REAP_WT_MIN_AGE_MINUTES               KEEP
  P pre-existing structural gates (main/self/locked/open-PR/revocable-ref)
Every row prints the rule it was decided by and the proof it used.

"main" is read from the remote that PUSHES (REAP_WT_MAIN_PROOF=auto): the
remote's advertised default branch and its oid, with the local ref chain as
the fallback. REAP_WT_MAIN_PROOF=local forces the local chain (no network).

The pass ends with ONE machine-readable SUMMARY line (examined/classified/
remove/preserved/deferred/removed/reasons/main_proof/pr_merged).

`git worktree remove` deletes the CHECKOUT, never the branch — named-branch
worktrees lose no commits, and this script never runs \`git branch -D\`.
No disk-savings figure is ever reported (see the header comment).

Run this from a terminal, from launchd, or from a session whose working
directory is a worktree — a session rooted in the shared main checkout is
blocked by the agent harness's script-content walker (#1484).
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
log_line() { printf '%s\n' "$*"; log "REAP $*"; }
log() { printf '%s\n' "$*" >>"$REAP_WT_LOG" 2>/dev/null || true; }

now_epoch() {
    if [ -n "${REAP_WT_NOW_EPOCH:-}" ]; then printf '%s\n' "$REAP_WT_NOW_EPOCH"; return 0; fi
    /bin/date +%s 2>/dev/null || date +%s
}

is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ── bounded execution — the shared helper (#2046) ─────────────────────────────────────────────
# `run_bounded`'s watchdog is NOT defined here any more: it MOVED to scripts/lib/bounded.sh, which
# resolves the bound ONCE as `timeout` -> `gtimeout` -> that same internal watchdog, and which
# `scripts/disk-reaper.sh` shares. Keeping the second copy is how two reapers drift into bounding
# different probes; the only thing left here is the name this file's 30 call sites already use.
#
# Contract, unchanged: 0 = ok, 124 = timed out, other = the command's own status; `<seconds>` 0 means
# "no watchdog"; a non-integer bound is REFUSED (125) rather than silently run unbounded.
# A missing library is a fail-closed abort at startup — without it NO probe is bounded, and an
# unbounded probe is what this tool exists to prevent.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for cand in "$SELF_DIR/lib/bounded.sh" \
                "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { BOUNDED_LIB="$cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    echo "FAIL-CLOSED abort: bounded-execution library missing (${BOUNDED_LIB:-$SELF_DIR/lib/bounded.sh or ${HOME:-}/.pi/agent/scripts/lib/bounded.sh, exit 3)}" >&2
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    echo "FAIL-CLOSED abort: TB_TIMEOUT_BIN=${TB_TIMEOUT_BIN:-} cannot be executed (exit 3)" >&2
    exit 3
fi
run_bounded() { tb_run "$@"; }

# canonicalize <path> — physical path, or "" when it cannot be resolved. Every
# path comparison uses the canonical form: `git worktree list` reports the
# RESOLVED path (/tmp/x is stored as /private/tmp/x — verified), while a
# process's argv keeps whatever was typed — an uncanonicalized compare would
# silently miss the /private/tmp scratch class of the incident.
canonicalize() {
    local p="$1"
    [ -n "$p" ] || { printf ''; return 0; }
    ( cd "$p" 2>/dev/null && pwd -P ) || printf ''
}

# is_self_or_ancestor <canon-path> — never remove the checkout the reaper runs
# from, nor any directory containing its cwd.
is_self_or_ancestor() {
    local p="$1" cwd="$SELF_CWD_CANON"
    [ -n "$p" ] && [ -n "$cwd" ] || return 1
    case "$cwd" in
        "$p"|"$p"/*) return 0 ;;
    esac
    return 1
}

is_ephemeral_name() {
    case "$EPHEMERAL" in *" $1 "*) return 0 ;; esac
    return 1
}

# is_regenerable_ignored <entry> — true when an ignored (`!!`) entry is pure
# regenerable build/test cache. Matched on the BASENAME so a nested
# `tortoise/__pycache__/` counts, which is the measured dominant class (2044 of
# the 3045 ignored entries on the live estate are `__pycache__`).
is_regenerable_ignored() {
    local base
    base="${1%/}"; base="${base##*/}"
    case "$base" in
        *.egg-info) return 0 ;;
    esac
    case "$IGNORED_REGENERABLE" in *" $base "*) return 0 ;; esac
    return 1
}

# is_scratch_path <path> — true for a LANE SCRATCH checkout (#2354).
#
# A lane's throwaway dir is named `wt-<issue>` (the `wt-` prefix the harness has used for years) or
# `cell-wt-<slug>` (a cell lane). The match is on the BASENAME and on a HYPHENATED prefix, so `wt`
# alone, `web-tools/` and a repo directory that merely starts with those letters are NOT scratch: a
# prefix rule that accepted `wt*` would silently shorten the age floor for a legitimate checkout.
# This only CHOOSES the age floor — every other gate (clean, live holder, open PR) still decides.
is_scratch_path() {
    local base
    base="${1%/}"; base="${base##*/}"
    # NOTE: no `local IFS` — a value-less `local` UNSETS it, and `set -u` turns that into a hard
    # error inside the predicate (if it did not, a mis-set IFS would silently change the split).
    local pat old_ifs="$IFS"
    # ⛔ `set -f` AROUND THE SPLIT (review of #2354). `for pat in $REAP_WT_SCRATCH_GLOB` performs
    # PATHNAME EXPANSION: with `wt-999` in the reaper's cwd the list became the FILE `wt-999` and
    # the scratch floor silently stopped applying — ambient, cwd-dependent, and silent.
    set -f
    IFS='|'
    for pat in $REAP_WT_SCRATCH_GLOB; do
        # shellcheck disable=SC2254 — the glob is DELIBERATE (the seam is a pattern list)
        case "$base" in $pat) IFS="$old_ifs"; set +f; return 0 ;; esac
    done
    IFS="$old_ifs"
    set +f
    return 1
}

# ── lock (macOS has no flock) ──────────────────────────────────────────
LOCK_HELD=0
lock_release() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR"; LOCK_HELD=0; }; return 0; }
lock_acquire() {
    local now owner started age mtime
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ -d "$LOCK_DIR" ]; then
        owner="$(cat "$LOCK_DIR/owner" 2>/dev/null || printf '')"
        started="$(cat "$LOCK_DIR/started" 2>/dev/null || printf '')"
        now="$(now_epoch)"
        # Age has two sources. `started` when usable; otherwise the lock dir's
        # own mtime. A missing/corrupt owner or start stamp must NOT read as
        # "stale": the window between `mkdir` and the owner write is real, and
        # treating it as stale let two passes run concurrently.
        age=""
        if is_pos_int "$started" && is_pos_int "$now" && [ "$now" -ge "$started" ]; then
            age=$((now - started))
        else
            mtime="$(/bin/date -r "$LOCK_DIR" +%s 2>/dev/null || printf '')"
            if is_pos_int "$mtime" && is_pos_int "$now" && [ "$now" -ge "$mtime" ]; then
                age=$((now - mtime))
            fi
        fi
        [ -n "$age" ] || age=0   # unknown age => not stale => honour the lock
        if is_pos_int "$owner" && kill -0 "$owner" 2>/dev/null && [ "$age" -lt "$REAP_WT_LOCK_STALE_SECONDS" ]; then
            log "LOCK held by live pid $owner (age ${age}s) — abort"
            return 1
        fi
        if [ "$age" -lt "$REAP_WT_LOCK_STALE_SECONDS" ]; then
            # live owner unknown/corrupt but the lock is young: still held.
            log "LOCK held (owner=${owner:-?} age ${age}s, unverifiable owner) — abort"
            return 1
        fi
        log "LOCK stale (owner=${owner:-?} age=${age}s) — breaking"
        rm -rf "$LOCK_DIR"
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then log "LOCK raced — abort"; return 1; fi
    printf '%s\n' "$$" >"$LOCK_DIR/owner"
    printf '%s\n' "$(now_epoch)" >"$LOCK_DIR/started"
    LOCK_HELD=1
    return 0
}

# ── worktree enumeration (admin files only — no directory walk) ────────
# Framing safety: `--porcelain` prints path bytes raw (a tab or newline in a
# path is NOT escaped). The record is re-joined with TAB for the internal
# pipeline, so any framing byte in a path would corrupt the record — and a
# truncated path would then look like a vanished directory. Such records are
# POISONED (path sanitized, flags=poison) and classified
# `preserve/unparseable-path`; nothing is ever removed on a corrupted record.
# `-z` is used when the git version supports it.
WT_Z_SUPPORTED=""
wt_z_probe() {
    local out rc
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-wt-z.XXXXXX")" || { WT_Z_SUPPORTED=0; return 0; }
    # $REPO_CANON, not `$COMMON_DIR/..`: for a submodule or --separate-git-dir
    # worktree the parent of the git dir is NOT the repo root.
    run_bounded "$REAP_WT_LIST_TIMEOUT" "$out" "$GIT_BIN" -C "$REPO_CANON" worktree list --porcelain -z
    rc=$?
    if [ "$rc" = 0 ] && [ -s "$out" ]; then WT_Z_SUPPORTED=1; else WT_Z_SUPPORTED=0; fi
    rm -f "$out"
}

wt_list_load() {
    local out rc raw line
    local cur_path="" cur_head="" cur_branch="-" cur_flags="" cur_poison=0
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-wt-list.XXXXXX")" || return 3
    if [ "$WT_Z_SUPPORTED" = 1 ]; then
        run_bounded "$REAP_WT_LIST_TIMEOUT" "$out" "$GIT_BIN" -C "$REPO_CANON" worktree list --porcelain -z
        rc=$?
    else
        run_bounded "$REAP_WT_LIST_TIMEOUT" "$out" "$GIT_BIN" -C "$REPO_CANON" worktree list --porcelain
        rc=$?
    fi
    if [ "$rc" != 0 ]; then rm -f "$out"; return 3; fi
    # flush <path> <head> <branch> <flags> <poison>
    flush() {
        [ -n "$1" ] || return 0
        local p="$1"
        if [ "$5" = 1 ]; then p="$(printf '%s' "$p" | tr '\t\n' '??')"; WT_FLAGS_OUT="poison"; else WT_FLAGS_OUT="$4"; fi
        WT_LIST="$(printf '%s\n%s' "$WT_LIST" "$p"$'\t'"$2"$'\t'"$3"$'\t'"$WT_FLAGS_OUT" | sed '/^$/d')"
    }
    if [ "$WT_Z_SUPPORTED" = 1 ]; then raw="$(tr '\0' '\n' <"$out")"; else raw="$(cat "$out")"; fi
    rm -f "$out"
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                flush "$cur_path" "$cur_head" "$cur_branch" "$cur_flags" "$cur_poison"
                cur_path="${line#worktree }"; cur_head=""; cur_branch="-"; cur_flags=""; cur_poison=0
                case "$cur_path" in *"$(printf '\t')"*) cur_poison=1 ;; esac
                ;;
            HEAD\ *)   cur_head="${line#HEAD }" ;;
            branch\ *) cur_branch="${line#branch }" ;;
            detached)  cur_branch="-" ;;
            bare)      cur_branch="BARE" ;;
            locked*)   cur_flags="$cur_flags,locked" ;;
            prunable*) cur_flags="$cur_flags,prunable" ;;
            '')        flush "$cur_path" "$cur_head" "$cur_branch" "$cur_flags" "$cur_poison"
                       cur_path=""; cur_head=""; cur_branch="-"; cur_flags=""; cur_poison=0 ;;
            *)         # an unrecognised line can only come from a path containing
                       # a newline — the record it belongs to cannot be trusted
                       cur_poison=1 ;;
        esac
    done <<<"$raw"
    flush "$cur_path" "$cur_head" "$cur_branch" "$cur_flags" "$cur_poison"
    return 0
}

# resolve_main_ref — first existing of origin/HEAD's target, origin/main,
# main, origin/master, master. Empty => merged check unavailable (reported).
resolve_main_ref() {
    local r
    if [ -n "$MAIN_REF_OVERRIDE" ]; then printf '%s\n' "$MAIN_REF_OVERRIDE"; return 0; fi
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
        "$GIT_BIN" -C "$REPO_CANON" symbolic-ref -q refs/remotes/origin/HEAD
    r="$(head -1 "$GIT_OUT" 2>/dev/null)"
    if [ -n "$r" ]; then
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" rev-parse --verify -q "$r"
        [ $? = 0 ] && { printf '%s\n' "$r"; return 0; }
    fi
    for r in refs/remotes/origin/main refs/heads/main refs/remotes/origin/master refs/heads/master; do
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" rev-parse --verify -q "$r"
        [ $? = 0 ] && { printf '%s\n' "$r"; return 0; }
    done
    printf ''
}

# ── THE REMOTE'S OWN DEFAULT BRANCH ──────────────────────────────────────────
# `resolve_main_ref` reads the LOCAL ref chain, which is a cache: `origin/main` can lag the remote by
# hours, and every rule that proves "merged into main" then proves it against a stale answer. This
# asks the remote which branch it calls HEAD and what oid that branch carries, and records WHICH
# source answered in MAIN_PROOF so a row can never claim a proof it did not use.
#
# THE PUSH URL, NOT THE FETCH URL: `git ls-remote origin` reads remote.origin.url, while `ls-remote
# <url>` on the PUSH url is what the operator actually merges into. A repo with two push urls is
# AMBIGUOUS and claims nothing rather than picking one.
# `ls-remote --symref <url> HEAD` is asked FIRST so a `master`- or `dev`-default repo is not silently
# proved against a `main` that does not exist there.
#
# Every failure mode sets MAIN_PROOF and leaves RESOLVED_MAIN empty — i.e. no evidence is claimed —
# and the caller falls back to the local chain. Nothing here can turn an unprovable merge into a
# removal: `auto-unfetched` means the remote's oid is not in this repository, so no ancestry test can
# be run against it.
resolve_remote_main() {
    local url="" n=0 cand="" oid="" ref="" out rc _u
    RESOLVED_MAIN=""; MAIN_PROOF="local"; MAIN_REF_NAME=""
    if [ "$REAP_WT_MAIN_PROOF" = "local" ]; then return 0; fi
    if [ -n "$REAP_WT_MAIN_PUSH_URL" ]; then
        url="$REAP_WT_MAIN_PUSH_URL"
    else
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" remote get-url --push --all origin
        rc=$?
        if [ "$rc" != 0 ]; then MAIN_PROOF="unavailable"; return 0; fi
        while IFS= read -r _u; do
            [ -n "$_u" ] || continue
            n=$((n + 1)); url="$_u"
        done <"$GIT_OUT"
        [ "$n" = 0 ] && { MAIN_PROOF="unavailable"; return 0; }
        [ "$n" = 1 ] || { MAIN_PROOF="ambiguous"; return 0; }
    fi
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-main.XXXXXX")" || { MAIN_PROOF="unavailable"; return 0; }
    cand="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}" \
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$out" "$GIT_BIN" ls-remote --symref "$url" HEAD 2>/dev/null \
        && sed -n 's/^ref: \(refs\/heads\/[^[:space:]]*\).*/\1/p' "$out" | head -1)"
    [ -n "$cand" ] || cand="$(printf '%s\n' refs/heads/main refs/heads/master)"
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}" \
            run_bounded "$REAP_WT_GIT_TIMEOUT" "$out" "$GIT_BIN" ls-remote "$url" "$ref"
        rc=$?
        if [ "$rc" != 0 ]; then MAIN_PROOF="unavailable"; break; fi
        oid="$(awk -v r="$ref" '$2 == r { print $1; exit }' "$out" 2>/dev/null)"
        [ -n "$oid" ] && break
    done <<EOF
$cand
EOF
    rm -f "$out"
    if [ -z "$oid" ]; then MAIN_PROOF="unavailable"; return 0; fi
    MAIN_REF_NAME="$ref"
    # The remote answered, but its oid must be IN this repository before any ancestry test can use
    # it. `auto-unfetched` claims no evidence, and does NOT silently fall back to a stale local tip.
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
        "$GIT_BIN" -C "$REPO_CANON" cat-file -e "${oid}^{commit}"
    if [ "$?" != 0 ]; then
        MAIN_PROOF="auto-unfetched"
        return 0
    fi
    RESOLVED_MAIN="$oid"; MAIN_PROOF="auto"
    return 0
}

# is_ancestor_of_main <sha> — true when <sha> is reachable from the main this pass resolved.
#
# The resolved remote oid is tried FIRST and the local ref chain SECOND. Both are tried because the
# two can legitimately disagree (an unfetched remote tip, a repo with no remote at all), and a
# disagreement must never read as "not merged": that is the direction that PRESERVES, which is safe,
# but it also means a squash-landed checkout stays for a week. Trying both is what keeps the answer
# about the commit rather than about which source happened to be consulted.
is_ancestor_of_main() {
    local sha="$1" t rc
    [ -n "$sha" ] || return 1
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" merge-base --is-ancestor "$sha" "$t"
        rc=$?
        [ "$rc" = 0 ] && return 0
    done <<EOF
${RESOLVED_MAIN}
${MAIN_REF}
EOF
    return 1
}

# ancestry_proof_text <sha> — the command that ACTUALLY proved the merge, for the row.
#
# ⛔ A ROW MUST CITE THE PROOF IT TOOK, and `is_ancestor_of_main` takes whichever of the two
# candidates answers first: the RESOLVED REMOTE oid, then the local ref chain. Printing
# `merge-base --is-ancestor <sha> ${MAIN_REF:-<no-main-ref>}=0` unconditionally is therefore a
# citation that can be FALSE — on exactly the cell this resolution was written for (a stale local
# tracking ref, where the remote oid is the one that answered, and the local ref returns 1), and with
# no local ref at all the row even read `<no-main-ref>=0`. A removal row whose stated proof cannot be
# reproduced is the "cite a proof it did not take" class, in the destructive path.
#
# So the proof is RE-TAKEN here, in the same order, and the ref that answered is the one printed.
# Prints NOTHING when no candidate answers: the caller must then PRESERVE — a proof that cannot be
# retaken removes nothing. (Rule 3 only fires after `commits_survive` saw it succeed, so that arm is
# a guard against the repository changing under the pass, not a normal path.)
ancestry_proof_text() {
    local sha="$1" t
    [ -n "$sha" ] || return 0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" merge-base --is-ancestor "$sha" "$t"
        [ "$?" = 0 ] && { printf 'merge-base --is-ancestor %s %s=0' "$sha" "$t"; return 0; }
    done <<EOF
${RESOLVED_MAIN}
${MAIN_REF}
EOF
    return 0
}

# ancestry_candidates_text — the refs the ancestry test actually TRIED, for a row that says "not in main".
# A row that names only the LOCAL ref is wrong on the cell the remote resolution exists for: with
# `main_proof=auto` and no usable local tracking ref it read `<no-main-ref>` for a non-ancestry that was
# established against the resolved remote oid. Same list, same order, as the test itself.
ancestry_candidates_text() {
    local out="" t
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        out="${out}${out:+,}${t}"
    done <<EOF
${RESOLVED_MAIN}
${MAIN_REF}
EOF
    printf '%s' "${out:-?}"
}

# ── probes ─────────────────────────────────────────────────────────────
# canonical_token_match <line> <canon> — true when a token of <line> resolves
# into <canon>. Needed because git records the RESOLVED path while argv keeps
# what was typed. Only tokens sharing the candidate's basename are
# canonicalized, so this stays bounded by the process table.
canonical_token_match() {
    local line="$1" canon="$2" base="${2##*/}" tok d
    [ -n "$base" ] || return 1
    for tok in $line; do
        case "$tok" in *"/$base"*) ;; *) continue ;; esac
        case "$tok" in "$canon"|"$canon"/*) return 0 ;; esac
        if [ -d "$tok" ]; then d="$tok"; else d="$(dirname "$tok" 2>/dev/null)"; fi
        [ -n "$d" ] && [ -d "$d" ] || continue
        d="$(canonicalize "$d")"
        case "$d" in "$canon"|"$canon"/*) return 0 ;; esac
    done
    return 1
}

# ps_load — ONE ps pass for the whole run. An EMPTY table is a probe failure,
# not "no live processes": reading it as clean silently disables the live-
# reference gate (fail-open).
ps_load() {
    local rc
    PS_OUT="$(mktemp "${TMPDIR:-/tmp}/pi-reap-ps.XXXXXX")" || { PS_OUT=""; return 1; }
    run_bounded "$REAP_WT_PS_TIMEOUT" "$PS_OUT" "$PS_BIN" -axo pid=,ppid=,command=
    rc=$?
    [ "$rc" = 0 ] || return 1
    [ -s "$PS_OUT" ] || return 1
    return 0
}

# Exported so a caller (and the harness) can tell WHICH pid this run IS. SELF_PIDS is assembled
# from `ps` output, so a test can only pin the cwd-vs-argv asymmetry by emitting the ancestor link
# FOR THIS PID — without it, `SELF_PIDS` holds the reaper alone and an "ancestor holds it" leg is
# vacuous (the mutant that restores the exemption passes it; review of #2354).
export REAP_WT_SELF_PID="$$"

self_pid_tree_load() {
    local pid="$$" ppid depth=0
    SELF_PIDS=" $$ "
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
        ppid="$(awk -v p="$pid" '$1==p {print $2; exit}' "$PS_OUT" 2>/dev/null)"
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        SELF_PIDS="$SELF_PIDS$ppid "
        pid="$ppid"; depth=$((depth + 1))
    done
}

live_process_for() { # <canon> <recorded> [<exclude-pids>] -> matching pid ("" when none)
    local canon="$1" recorded="$2" exclude="${3:-}" pid line
    [ -s "$PS_OUT" ] || return 1
    # The match MUST end at a path boundary. A bare substring test lets a
    # SIBLING share the basename prefix (`.../wt-elsewhere` contains
    # `.../wt`) veto the removal of an unrelated worktree.
    for pid in $(awk -v a="$canon" -v b="$recorded" '
        function hits(line, needle,   i, c) {
            i = index(line, needle)
            if (i == 0) return 0
            c = substr(line, i + length(needle), 1)
            return (c == "" || c == "/" || c == " " || c == "\t")
        }
        { pid=$1; line=$0
          if (a != "" && hits(line, a)) { print pid; next }
          if (b != "" && hits(line, b)) { print pid }
        }' "$PS_OUT" 2>/dev/null); do
        case "$SELF_PIDS" in *" $pid "*) continue ;; esac
        case " $exclude " in *" $pid "*) continue ;; esac
        printf '%s\n' "$pid"
        return 0
    done
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid="${line%% *}"
        case "$SELF_PIDS" in *" $pid "*) continue ;; esac
        case " $exclude " in *" $pid "*) continue ;; esac
        case "$line" in *"/${canon##*/}"*) ;; *) continue ;; esac
        if canonical_token_match "$line" "$canon"; then printf '%s\n' "$pid"; return 0; fi
    done <<<"$(grep -F -- "/${canon##*/}" "$PS_OUT" 2>/dev/null)"
    return 1
}

# cwd_probe_load — ONE bounded `lsof -a -d cwd` pass (never the `+D` directory
# walk, which would be unbounded). Best-effort by design: a missing or slow
# lsof sets CWD_DEGRADED and the pass falls back to the argv probe — reported in
# the footer and the log, never a silent pass.
#
# ⛔ CWD_DEGRADED DESCRIBES THE TABLE THAT IS IN `CWD_OUT` NOW, NOT THE PASS'S HISTORY (review
# round 10, P2). It was a LATCH: set to 1 by any failure and cleared NOWHERE, so `holder_recheck`'s
# "the pass HAD a good cwd table and the re-read lost it" guard read the flag's lifetime instead of
# the current table. Reachable ordering with no execution: (a) the pass-start `lsof` times out ⇒
# flag=1; (b) worktree A's re-read SUCCEEDS ⇒ the table in hand is good but the flag stays 1, so the
# guard is skipped — correct by luck; (c) worktree B's re-read FAILS ⇒ the guard is skipped because
# the flag is still 1, `holders_live` runs argv-only, and a checkout whose only witness is its cwd is
# deleted under a live lane — verbatim the round-2 P1 this file claims is closed, in a second
# ordering. Clearing on a successful NON-EMPTY read fixes it and leaves the no-lsof host unchanged:
# that host degrades on EVERY call, so it keeps the documented argv-only behaviour. The footer then
# finally reports the state of the table it names.
cwd_probe_load() {
    CWD_OUT="$(mktemp "${TMPDIR:-/tmp}/pi-reap-cwd.XXXXXX")" || { CWD_OUT=""; CWD_DEGRADED=1; return 0; }
    if ! command -v "$LSOF_BIN" >/dev/null 2>&1; then
        CWD_DEGRADED=1; log "CWD probe degraded: $LSOF_BIN not found — argv-only live-reference check"; return 0
    fi
    run_bounded "$REAP_WT_CWD_TIMEOUT" "$CWD_OUT" "$LSOF_BIN" -a -d cwd -Fpn
    if [ $? != 0 ] || [ ! -s "$CWD_OUT" ]; then
        CWD_DEGRADED=1; log "CWD probe degraded: lsof failed/empty — argv-only live-reference check"
    else
        CWD_DEGRADED=0
    fi
    return 0
}

live_cwd_for() { # <canon> <recorded> [<exclude-pids>] -> pid whose cwd is inside ("" when none)
    # ⛔ THE REAPER'S OWN PROCESS TREE IS **NOT** EXEMPT HERE (#2354). The argv probe skips
    # SELF_PIDS because its own command line carries the path it is judging — a string it wrote
    # itself. A CWD is not that: no process can be *made* to sit in a checkout by the reaper's
    # arguments. Exempting the tree here reproduced a live-lane reap in the field: a lane ran the
    # reaper from worktree A while its OWN session (the reaper's ancestor) sat in worktree B, so B
    # was reported `unref=no-proc` and offered for removal while the lane was still using it.
    # The self-checkout gate above still protects the reaper's OWN directory (decided by path, not
    # by pid), and it runs FIRST, so dropping the pid filter cannot make a self-reap possible.
    # `<exclude-pids>` is the #2721 addition and is NOT that filter: it carries only the holders THIS
    # classification has already DEMOTED as idle shells, so the scan can reach the next holder. It is
    # per-record and caller-supplied — never the reaper's ancestry — so #2354's rule still holds.
    local canon="$1" recorded="$2" exclude="${3:-}" pid="" last=""
    [ -s "$CWD_OUT" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            p*) pid="${line#p}" ;;
            n*)
                last="${line#n}"
                case " $exclude " in *" $pid "*) continue ;; esac
                case "$last" in
                    "$canon"|"$canon"/*|"$recorded"|"$recorded"/*)
                        printf '%s\n' "$pid"; return 0 ;;
                    *"/${canon##*/}"*)
                        if canonical_token_match "$last" "$canon"; then
                            printf '%s\n' "$pid"; return 0
                        fi ;;
                esac ;;
        esac
    done <"$CWD_OUT"
    return 1
}

# ── THE IDLE-SHELL RULE (agent-infra#2721) ─────────────────────────────
# WHY. `live-process` and `live-cwd` answer "is a process holding this checkout?" — and a shell that
# `cd`'d in and never exited answers YES for ever. #2721 measured the cost: the reclaim log recorded
# `KEEP … (a live process has it as cwd)` for nearly every worktree on a wedged cell while 59
# checkouts at 5-6 GB each accumulated and the box lost its disk. A shell at a prompt is not a lane:
# the lane's agent is the shell's CHILD, so a shell with no children is a process nobody is using.
#
# THE RULE, and it is deliberately narrow:
#   a cwd / argv holder is LIVE EVIDENCE unless it is a SHELL whose START TIME is before the
#   worktree's HEAD commit AND which has no child process.
# "Started before the last commit" is #2721's own phrasing of "never did anything here": a lane
# between turns still holds its `pi`/test child, so it does not match; a lane that finished and left
# its `cd` behind does. Every OTHER gate is untouched — dirty / ignored-artifact / open-pr /
# too-recent / detached-unreachable / remote-only-ref all still PRESERVE — so the blast radius of a
# wrong reading here is a re-created checkout, never uncommitted or unpushed work (and `clean` +
# `reachable` are checked before any removal regardless).
# ⛔ FAIL CLOSED ON EVERY UNKNOWABLE: a pid missing from the ps table, a start time that cannot be
# read, a HEAD that cannot be dated, or any probe that cannot answer all leave the holder LIVE.
# ⛔ AND IT IS SWITCHABLE (`REAP_WT_IDLE_SHELL=0`) so an operator can restore the strict reading
# without editing a shipped script. A demotion is NAMED in the pass log.
IDLE_SHELL="${REAP_WT_IDLE_SHELL:-1}"

# proc_start_epoch <pid> -> epoch seconds the process started ("" when unreadable).
# Linux needs no fork: the `/proc/<pid>` DIRECTORY's mtime is set at process creation (measured).
# Elsewhere `ps -o etimes=` then `ps -o etime=`'s `[[dd-]hh:]mm:ss` form (BSD ps has etime).
# An unreadable value is "" — never 0, which would compare as "started at the epoch" and make every
# holder read stale.
proc_start_epoch() {
    local pid="${1:-}" v e f1 f2 f3 rest
    is_pos_int "$pid" || return 1
    # ⛐ THE ROOT IS `$REAP_WT_PROC_ROOT`, NOT A LITERAL `/proc` (review round 5, P2): the same seam
    # `REAP_VENV_PROC_ROOT` gives the venv reaper, for the same reason — pinning this read to `/proc`
    # makes the fallback untestable on a Linux host (a live fixture pid takes THIS branch, so an arm for
    # the `10#` parse decides on whatever process owns that pid). Default `/proc`: production unchanged.
    if [ -r "$REAP_WT_PROC_ROOT/$pid" ]; then
        v="$(stat -c '%Y' "$REAP_WT_PROC_ROOT/$pid" 2>/dev/null)"
        case "$v" in ''|*[!0-9]*) v="" ;; esac
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    fi
    v="$("$PS_BIN" -o etimes= -p "$pid" 2>/dev/null | tr -d ' \t')"
    case "$v" in ''|*[!0-9]*) v="" ;; esac
    [ -n "$v" ] && { printf '%s\n' "$(( $(now_epoch) - v ))"; return 0; }
    e="$("$PS_BIN" -o etime= -p "$pid" 2>/dev/null | tr -d ' \t')"
    [ -n "$e" ] || return 1
    case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
    # ⛔ EVERY FIELD IS FORCED TO BASE 10 (review round 1, P2): `ps -o etime` prints zero-padded
    # components, so an ordinary `1:08:30` reaches the arithmetic as `08` and bash rejects it as a bad
    # OCTAL constant and the expansion ABORTED: `proc_start_epoch` returned NOTHING, the rule could not
    # prove the holder predated HEAD, and the holder stayed LIVE — an INERT enforcer, never a false
    # reap, on every host that reaches this fallback (on macOS it is the PRIMARY path). `10#` makes the
    # parse literal decimal.
    v=0
    case "$e" in *-*) v=$(( 10#${e%%-*} * 86400 )); e="${e#*-}" ;; esac
    case "$e" in
        *:*:*) f1="${e%%:*}"; rest="${e#*:}"; f2="${rest%%:*}"; f3="${rest#*:}" ;;
        *:*)   f1=0; f2="${e%%:*}"; f3="${e#*:}" ;;
        *)     f1=0; f2=0; f3="$e" ;;
    esac
    is_pos_int "$f1" && is_pos_int "$f2" && is_pos_int "$f3" || return 1
    printf '%s\n' "$(( $(now_epoch) - (v + 10#$f1 * 3600 + 10#$f2 * 60 + 10#$f3) ))"
}

# is_shell_pid <pid> — the process's COMMAND WORD is a shell (its argv[0], from the ps table).
is_shell_pid() {
    local pid="${1:-}" cmd base
    is_pos_int "$pid" || return 1
    [ -s "${PS_OUT:-}" ] || return 1
    cmd="$(awk -v p="$pid" '$1==p { $1=""; $2=""; sub(/^[ \t]+/, ""); print; exit }' "$PS_OUT" 2>/dev/null)"
    [ -n "$cmd" ] || return 1
    cmd="${cmd%% *}"
    base="${cmd##*/}"
    base="${base#-}"
    case "$base" in bash|sh|dash|zsh|ksh|ksh93|mksh|ash|fish) return 0 ;; esac
    return 1
}

# has_child <pid> — a pid with a live child is DOING something (a prompt has none). The reaper's own
# process tree is excluded, exactly as every other witness excludes it.
has_child() {
    local pid="${1:-}"
    is_pos_int "$pid" || return 1
    [ -s "${PS_OUT:-}" ] || return 1
    awk -v p="$pid" -v self=" ${SELF_PIDS:-} " '
        $2==p { if (index(self, " " $1 " ") == 0) { found=1; exit } }
        END { exit !found }' "$PS_OUT" 2>/dev/null
}

# head_epoch_for <sha> -> epoch of that commit ("" when git cannot date it). Bounded like every other
# git probe here, and the failure arm is the PRESERVING one.
head_epoch_for() {
    local sha="${1:-}" v
    [ -n "$sha" ] || return 1
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT.ct" "$GIT_BIN" -C "$REPO_CANON" log -1 --format=%ct "$sha" || return 1
    v="$(head -1 "$GIT_OUT.ct" 2>/dev/null | tr -d ' \t')"
    is_pos_int "$v" || return 1
    printf '%s\n' "$v"
}

# stale_shell_for <pid> <sha> — 0 when this holder is an IDLE SHELL predating the worktree's HEAD.
stale_shell_for() {
    local pid="${1:-}" sha="${2:-}" head start
    [ "$IDLE_SHELL" = 1 ] || return 1
    is_shell_pid "$pid" || return 1
    has_child "$pid" && return 1
    head="$(head_epoch_for "$sha")" || return 1
    start="$(proc_start_epoch "$pid")" || return 1
    [ "$start" -lt "$head" ] || return 1
    return 0
}

# clean_gate <path> -> "<verdict>\t<payload>"
# For `clean` the payload is the allowlisted-EPHEMERAL entries present (they
# must be deleted before `git worktree remove`, which refuses on untracked
# files); otherwise up to 3 offending entries.
clean_gate() {
    local path="$1" out rc buf bad="" ignored="" eph="" n=0 line xy p base
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-st.XXXXXX")" || { printf 'status-error\tmktemp-failed\n'; return 0; }
    run_bounded "$REAP_WT_STATUS_TIMEOUT" "$out" \
        "$GIT_BIN" -C "$path" -c core.quotepath=false status --porcelain -z \
        --ignored=traditional --untracked-files=normal
    rc=$?
    case "$rc" in
        0) : ;;
        124) rm -f "$out"; printf 'status-timeout\tstatus exceeded %ss\n' "$REAP_WT_STATUS_TIMEOUT"; return 0 ;;
        *)  rm -f "$out"; printf 'status-error\tgit status rc=%s\n' "$rc"; return 0 ;;
    esac
    # -z: records are NUL-separated "XY<space>PATH". A path containing a newline
    # splits into a line failing the XY check — dirty (fail-closed).
    buf="$(tr '\0' '\n' <"$out")"
    rm -f "$out"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${line:2:1}" != " " ]; then bad="unparseable-status-record"; continue; fi
        xy="${line:0:2}"
        p="${line:3}"
        base="${p%/}"; base="${base##*/}"
        case "$xy" in
            '??'|'!!')
                # ROOT-level ephemeral allowlist ONLY. A NESTED `src/.cache/`
                # is tolerated by NOTHING: `.cache` is deliberately absent from
                # IGNORED_REGENERABLE (a nested cache is operator data). This
                # branch is also what keeps the `clean` payload safe — it admits
                # nothing but space-free ROOT names, and remove_one expands that
                # payload UNQUOTED.
                if [ "${p%/}" = "$base" ] && is_ephemeral_name "$base"; then
                    eph="$eph$p "
                elif [ "$xy" = '!!' ]; then
                    # Ignored: non-blocking ONLY for pure regenerable cache.
                    # Anything else is operator data and PRESERVES (G2b).
                    if is_regenerable_ignored "$p"; then
                        # TOLERATED AND DELIBERATELY NOT COLLECTED. Anything
                        # appended to the `clean` payload is later expanded
                        # UNQUOTED by remove_one (`for entry in $eph`) and
                        # `rm -rf`'d, so the payload MUST stay limited to the
                        # space-free ROOT names the branch above admits: a
                        # nested path with a space would split into fragments
                        # and delete an unrelated, possibly TRACKED directory
                        # (`website (copy)/…` -> `rm -rf $wt/website`).
                        # Ignored entries need no pre-delete anyway — verified:
                        # `git worktree remove` (no --force) returns rc=0 with
                        # an ignored `__pycache__/` present, which is exactly why
                        # the ignored half of this gate exists at all.
                        :
                    else
                        n=$((n + 1)); [ "$n" -le 3 ] && ignored="$ignored$p "
                    fi
                else
                    n=$((n + 1)); [ "$n" -le 3 ] && bad="$bad$p "
                fi ;;
            *) n=$((n + 1)); [ "$n" -le 3 ] && bad="$bad$p " ;;
        esac
    done <<<"$buf"
    if [ -n "$bad" ]; then
        printf 'dirty\t%s\n' "$(printf '%s' "$bad" | sed 's/ $//')"
    elif [ -n "$ignored" ]; then
        printf 'ignored-artifact\t%s\n' "$(printf '%s' "$ignored" | sed 's/ $//')"
    else
        printf 'clean\t%s\n' "$(printf '%s' "$eph" | sed 's/ $//')"
    fi
}

# pr_state_load — ONE batched call for the whole pass, with an explicit
# limit: `gh pr list` defaults to --limit 30, so a branch whose PR sits beyond
# the first 30 would be a FALSE PASS on the exact class the issue preserved.
# Only a github.com origin can have PRs; anything else is N/A.
#
# ── WHY THIS READS `--state all` AND `headRefOid` (#2721) ────────────────────
# The gate used to read ONLY open PR heads, as a veto. "Merged into main" was
# provable only through ancestry, and a SQUASH merge makes the branch head a
# non-ancestor of main, so a fully landed checkout was indistinguishable from an
# abandoned one. Measured on this fleet: `/tmp/cell-wt-p9555b` — clean, its PR
# #9862 MERGED — was logged `no upstream — cannot prove it is pushed` for days
# while the box sat at 2.3 GB free; removing it freed 6004 MB.
# The same read decides rules 4 (MERGED => REMOVE), 5 (CLOSED => KEEP + name)
# and 6 (no PR => KEEP + name), so it must carry `state`. `headRefOid` is what
# lets a DETACHED head — which has no branch name to match — be matched to the
# PR that carried its commit.
# TRUNCATION IS A REFUSAL (#2756 review). `--state all` spends one limit on
# every state, so a repo with a long merged history can exhaust it; gh then
# returns the newest N rows and silently drops the rest, and an absent row is NOT
# "no PR": inside the floor that is rule 6 (KEEP), past it the aged rule
# (REMOVE). A live branch's checkout would be reaped on a list that never
# contained it, so a row count AT the limit fails the gate closed (exit 3).
GH_OK=0
PR_APPLICABLE=0
# PR_ROWS — "headRefName\theadRefOid\tSTATE\tnumber", one row per PR, from ONE
# `gh pr list --state all` call. Looked up by `pr_row_best`, never grepped: a
# branch can own more than one PR (closed, then reopened; closed then merged as
# a new PR), and resolving that by row ORDER would be a coin toss.
PR_ROWS=""
# ⛔ WHY THE OPEN-PR GATE COULD NOT BE EVALUATED, AS A TOKEN RATHER THAN A GUESS, and the sentence
# that says what to DO about it. The abort used to say "gh unavailable or the origin-remote probe
# failed" — naming two causes it could not distinguish, while the one that actually happens on a cell
# (an INSTALLED and WORKING `gh` that is NOT AUTHENTICATED for this pass's HOME, so `gh` exits 4) was
# not named at all. Measured 2026-10-23 on a cell at 95% used: `/usr/bin/gh` v2.102.0 present,
# `gh pr list` exit 4, HOME with no `~/.config/gh` -> the worktree class aborted for BOTH repos and
# freed 0 MB, reported as "gh unavailable" (#2443). A caller now reads the token: disk-reaper.sh turns
# it into `skipped=<repo> reason=<why>` and keeps reclaiming the repos it CAN verify.
PR_SKIP_REASON=""
PR_SKIP_REMEDY=""
github_slug() {
    local url="$1"
    case "$url" in
        *github.com[:/]*)
            printf '%s\n' "$url" | sed -E 's#^[^/]*//##; s#^git@##; s#github\.com[:/]##; s#\.git$##' ;;
        *) printf '' ;;
    esac
}
pr_state_load() {
    local slug="" out rc url_rc
    if [ -n "$REAP_WT_REPO_SLUG" ]; then
        slug="$REAP_WT_REPO_SLUG"
    else
        # The probe's EXIT STATUS decides — reading an empty URL as "no GitHub
        # remote" is fail-OPEN: it silently disables the open-PR veto for the
        # whole pass, which is the same class as reading an empty `ps` table as
        # "no live processes". `git remote get-url origin` exits 2 when origin
        # does not exist, and 0 with a URL otherwise; ONLY those two are
        # decidable. Anything else (probe failure, timeout 124) means the gate
        # cannot be evaluated => fail closed, exactly like `gh` being
        # unavailable. A rc=0 URL that is not github.com still, correctly,
        # yields no slug => the PR gate is genuinely N/A.
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" remote get-url origin
        url_rc=$?
        if [ "$url_rc" != 0 ] && [ "$url_rc" != 2 ]; then
            PR_APPLICABLE=1; GH_OK=0; GH_STATE="unavailable"
            # A git-level failure (127 = no git, 124 = timeout, 128 = the repo itself is unreadable).
            # NOT an authentication problem: the remedy names git, never `gh auth login`.
            case "$url_rc" in
                124) PR_SKIP_REASON="origin-probe-timeout(rc=124)"
                     PR_SKIP_REMEDY="bounded \`git remote get-url origin\` did not answer within ${REAP_WT_GIT_TIMEOUT}s — the checkout or its mount is unresponsive" ;;
                127) PR_SKIP_REASON="git-missing(rc=127)"
                     PR_SKIP_REMEDY="git is not executable for this pass (GIT_BIN=${GIT_BIN})" ;;
                *)   PR_SKIP_REASON="origin-probe-failed(rc=$url_rc)"
                     PR_SKIP_REMEDY="the origin remote of $REPO_CANON could not be read (bounded \`git remote get-url origin\` exit $url_rc) — check the checkout's .git/config" ;;
            esac
            log "GH slug probe failed (rc=$url_rc) for $REPO_CANON — fail-closed (reason=$PR_SKIP_REASON)"
            return 1
        fi
        slug="$(github_slug "$(head -1 "$GIT_OUT" 2>/dev/null)")"
    fi
    case "$slug" in
        */*) ;;
        *) PR_APPLICABLE=0; GH_OK=1; GH_STATE="na"; return 0 ;;
    esac
    PR_APPLICABLE=1
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-pr.XXXXXX")" || {
        GH_OK=0; GH_STATE="unavailable"
        # ⛔ THE TOKEN IS SPACE-FREE BY CONTRACT (a caller parses this line). The scratch PATH goes in
        # the remedy, never in the token: a TMPDIR containing a space (`/Users/me/My Temp`) would
        # otherwise split the token and make the repo's skip invisible to the reader again (#2443).
        PR_SKIP_REASON="scratch-unwritable"
        PR_SKIP_REMEDY="the PR probe needs ONE scratch file and could not create it under ${TMPDIR:-/tmp} — a full or read-only scratch dir"
        return 1
    }
    run_bounded "$REAP_WT_GH_TIMEOUT" "$out" \
        "$GH_BIN" pr list --repo "$slug" --state all --limit "$REAP_WT_PR_LIMIT" \
        --json headRefName,state,number,headRefOid \
        --jq '.[] | [(.headRefName // ""), (.headRefOid // ""), (.state // ""), (.number|tostring)] | @tsv'
    rc=$?
    if [ "$rc" != 0 ]; then
        rm -f "$out"; GH_OK=0
        # ⛔ THE EXIT CODE IS THE DIAGNOSIS, and the arms are disjoint remedies: `gh` documents 4 as
        # "requires authentication" (gh help exit-codes), which is a DIFFERENT fix from a missing
        # binary, a timeout, or an API error. Collapsing them into "gh unavailable" is how a cell
        # spent hours on a full disk with a working gh (#2443).
        case "$rc" in
            4)   GH_STATE="auth"
                 PR_SKIP_REASON="gh-not-authenticated(rc=4)"
                 PR_SKIP_REMEDY="gh is INSTALLED but NOT AUTHENTICATED for this pass's HOME (${HOME:-unset}): gh reads credentials from \$HOME/.config/gh or GH_TOKEN. Install the timer as the user that owns the lanes (the unit renders Environment=HOME=), or export GH_TOKEN/GITHUB_TOKEN. gh's own words: run 'gh auth login' for that HOME" ;;
            124) GH_STATE="unavailable"
                 PR_SKIP_REASON="gh-timeout(rc=124)"
                 PR_SKIP_REMEDY="gh did not answer within REAP_WT_GH_TIMEOUT=${REAP_WT_GH_TIMEOUT}s — a busy shared account; raise the timeout or let the next pass retry" ;;
            127) GH_STATE="missing"
                 PR_SKIP_REASON="gh-missing(rc=127)"
                 PR_SKIP_REMEDY="gh is not executable for this pass (GH_BIN=${GH_BIN}) — install it or point GH_BIN at an absolute path" ;;
            *)   GH_STATE="unavailable"
                 PR_SKIP_REASON="gh-error(rc=$rc)"
                 PR_SKIP_REMEDY="gh pr list failed for ${slug} (exit $rc) — see the pass log for gh's own message" ;;
        esac
        log "GH pr-list failed (rc=$rc) for $slug — fail-closed (reason=$PR_SKIP_REASON)"
        return 1
    fi
    # Normalise before storing: a producer that emits a BARE head ref (one field)
    # is the pre-#2721 `--state open --json headRefName` shape, and that shape
    # MEANT an open PR. Reading such a row as "state unknown" would silently
    # disable the open-PR veto for anyone still driving this seam, which is
    # fail-OPEN. Anything else that is not four fields is dropped (it cannot be
    # resolved to a state, and rule 6 keeps the checkout) — never guessed.
    # ── TRUNCATION IS A REFUSAL, NOT A KEEP (#2756 review, P1) ────────────
    # `--state all` spends ONE limit on every state, so the cheapest way to
    # exhaust it is a repo with a long history of merged PRs. When that happens
    # gh returns the NEWEST N rows and silently drops the rest — and the row it
    # drops can be an OPEN PR, which is the veto this read exists for. A row that
    # is merely ABSENT is not evidence of "no PR": rule 6 would keep it inside the
    # floor and the aged tail would REMOVE it past the floor, i.e. a live branch's
    # checkout reaped on a truncated list. So a row count at the bound means the
    # gate could not be evaluated — the same fail-closed verdict as an unreadable
    # `gh` (exit 3, nothing removed), never a pass.
    local nrows
    nrows="$(grep -c . "$out" 2>/dev/null || true)"
    case "$nrows" in ''|*[!0-9]*) nrows=0 ;; esac
    if [ "$nrows" -ge "$REAP_WT_PR_LIMIT" ]; then
        rm -f "$out"; GH_OK=0; GH_STATE="truncated"; PR_ROWS=""
        PR_SKIP_REASON="gh-pr-list-truncated(limit=$REAP_WT_PR_LIMIT)"
        PR_SKIP_REMEDY="this repo has at least ${REAP_WT_PR_LIMIT} PRs across ALL states, so gh returned only the newest and an absence is no longer evidence. Raise REAP_WT_PR_LIMIT above the repo's total PR count (daniel-ospina/tortoise measured 3,987 on 2026-10-24; the default is 5,000), or reap the repo by hand"
        log "GH pr-list TRUNCATED at limit=$REAP_WT_PR_LIMIT for $slug (rows=$nrows) — fail-closed: an absent PR is not evidence"
        return 1
    fi
    PR_ROWS="$(awk -F'\t' '
        NF >= 4 && $1 != "" { print; next }
        NF == 1 && $1 != ""  { printf "%s\t\tOPEN\t\n", $1 }
    ' "$out")"
    rm -f "$out"
    GH_OK=1; GH_STATE="ok"
    return 0
}

# pr_row_best <column> <value> -> "STATE\tNUMBER\tOID" of the most DECISIVE PR
# that matches, or "" when none does. Decision order is OPEN > MERGED > CLOSED:
# an OPEN PR must veto a removal, and a branch that was closed unmerged and
# later merged must read as landed. Two PRs on one head ref are normal (a
# reopened or re-landed change), so the row order decides nothing.
#
# ⛔ THE OID IS RETURNED, AND IT IS NOT DECORATION (#2756 review, P0). A branch
# NAME is reused: after `feat/x` lands, the next lane may check `feat/x` out
# again and commit new work, with no PR yet. Matching on the name alone then
# finds the OLD MERGED PR and "proves" UNLANDED work disposable. The caller must
# require `headRefOid == this HEAD` before a MERGED row may remove anything —
# GitHub durably holds the PR's head sha, so that equality is what makes both
# the removal and the revocable-ref waiver sound.
pr_row_best() {
    [ -n "$PR_ROWS" ] || return 0
    awk -F'\t' -v c="$1" -v v="$2" '
        $c == v {
            rank = ($3 == "OPEN") ? 3 : ($3 == "MERGED" ? 2 : ($3 == "CLOSED" ? 1 : 0))
            if (rank > best) { best = rank; st = $3; num = $4; oid = $2 }
        }
        END { if (best > 0) printf "%s\t%s\t%s\n", st, num, oid }' <<<"$PR_ROWS"
}
pr_state_for_ref() { pr_row_best 1 "$1"; }
pr_state_for_sha() { pr_row_best 2 "$1"; }

# path_ctime <path> -> the path's inode-change time in epoch seconds, or "" when
# it cannot be read. RULE 7's second witness (#2721): HEAD's COMMIT date is not
# the checkout's age — a checkout created minutes ago from an hours-old main has
# an hours-old HEAD, which is exactly how a 4-minute-old lane was classified as
# aged. Portable without a capability probe: GNU `stat -c %Z` first, BSD
# `stat -f %c` second; anything non-numeric (a `--help` on a stat that does not
# know the flag) is an unusable witness, never a zero.
#
# REAP_WT_TREE_TS supplies an ALREADY-MEASURED witness (a caller that probed the
# tree, or a test that needs the floor deterministic). It is validated at startup
# (run()), because a typo here would silently remove the witness and leave rule 7
# measuring HEAD's commit date only — the exact hole this witness closes.
path_ctime() {
    local p="$1" ts=""
    if [ -n "${REAP_WT_TREE_TS:-}" ]; then printf '%s\n' "$REAP_WT_TREE_TS"; return 0; fi
    ts="$(stat -c %Z "$p" 2>/dev/null)" || ts=""
    case "$ts" in ''|*[!0-9]*) ts="$(stat -f %c "$p" 2>/dev/null)" || ts="" ;; esac
    case "$ts" in ''|*[!0-9]*) printf '' ;; *) printf '%s\n' "$ts" ;; esac
}

# commits_survive <sha> <branch> -> prints the survival mechanism, or "" when
# deleting the checkout could orphan the commit. This is the REACHABLE gate and
# it is applied to EVERY removal path, including the vanished-directory one:
# the admin record's HEAD is itself the last ref holding a detached commit, so
# pruning it can orphan that commit (verified).
commits_survive() {
    local sha="$1" branch="$2" merged=0 containing="" revocable="" rc=0
    if [ -n "$sha" ]; then
        # The RESOLVED main first, the local ref chain second (see is_ancestor_of_main). ANY outcome
        # other than 0 (1 = not an ancestor, 124 = timeout, 128 = unknown object) leaves merged=0 and
        # the arms below decide. Nothing here can turn an unverifiable merge into a removal on its own.
        if is_ancestor_of_main "$sha"; then merged=1; fi
    fi
    if [ "$merged" = 1 ]; then printf 'merged\n'; return 0; fi


    if [ "$branch" != "-" ]; then
        # A named branch is a survival mechanism ONLY when the ref RESOLVES.
        # `git worktree list --porcelain` keeps emitting `branch refs/heads/X`
        # after X is force-deleted (with HEAD 0000…0), so the label is not proof
        # — trusting it reports a survival mechanism that does not exist.
        run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
            "$GIT_BIN" -C "$REPO_CANON" rev-parse --verify -q "$branch"
        rc=$?
        if [ "$rc" = 0 ]; then
            printf 'branch-retained:%s\n' "${branch#refs/heads/}"
            return 0
        fi
        # 124 = could not verify => preserve. Otherwise the ref is GONE, so the
        # label lied and the commit must be held by some OTHER ref (below) or it
        # is orphaned.
        [ "$rc" = 124 ] && { printf ''; return 0; }
    fi

    # Detached HEAD — or a named branch whose ref no longer resolves.
    #
    # SURVIVAL MUST NOT BE REVOCABLE (F3 / #1104, re-opened for tags by review).
    # The first fix blacklisted refs/remotes/*, because `git fetch --prune`
    # drops a remote-tracking ref once the remote branch is gone — routinely,
    # e.g. after a squash-merge with branch auto-delete. A blacklist cannot be
    # completed: `git fetch --prune --prune-tags` (or fetch.pruneTags=true)
    # deletes a LOCAL-ONLY tag too, `git stash drop`/`clear` revokes
    # refs/stash, and `git bisect reset` revokes refs/bisect/*. Any of those
    # leaves the commit on no ref, i.e. gc-eligible, with no record left.
    # So the test is an ALLOWLIST, not a blacklist: only refs/heads/* — which
    # `fetch` never writes and only an explicit `git branch -D` removes, a
    # command this script never calls — counts as a survival mechanism.
    #
    # The merged arm ABOVE is deliberately untouched, and that is why this is
    # not a rejection of remote refs: it is ancestor-based and MAIN_REF is
    # normally refs/remotes/origin/main, so `main` still fast-paths to
    # `refs=merged` (pinned by A20c). The allowlist applies only to the
    # containment fallback for a detached HEAD that is NOT on main.
    #
    # A holder outside refs/heads/* prints a `<reason>:<refname>` marker, which
    # classify_one turns into PRESERVE with the revocable ref NAMED so the
    # operator can judge it (`remote-only-ref` for refs/remotes/*, the common
    # case; `revocable-ref` otherwise).
    #
    # One bounded probe, then partition by prefix; the 64-ref output bound
    # cannot cause a removal a larger bound would not: if the sample is all
    # revocable refs and a refs/heads/* holder sat beyond it, the outcome is
    # PRESERVE. The bound errs toward preservation. (Walk cost is unchanged —
    # git does not short-circuit the containment walk for --count=1 either.)
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" "$GIT_BIN" -C "$REPO_CANON" \
        for-each-ref --contains="$sha" --count=64 --format='%(refname)'
    # A failure here (incl. 129 for a zero/unknown sha) is "cannot establish",
    # which is a PRESERVE, never a pass.
    [ $? = 0 ] || { printf ''; return 0; }
    while IFS= read -r containing; do
        [ -n "$containing" ] || continue
        case "$containing" in
            refs/heads/*) printf 'reachable-from:%s\n' "$containing"; return 0 ;;
            *) [ -n "$revocable" ] || revocable="$containing" ;;
        esac
    done <"$GIT_OUT"
    if [ -n "$revocable" ]; then
        case "$revocable" in
            refs/remotes/*) printf 'remote-only-ref:%s\n' "$revocable" ;;
            *)              printf 'revocable-ref:%s\n' "$revocable" ;;
        esac
        return 0
    fi
    printf ''
    return 0
}

# patch_equivalent <sha> — the SQUASH-MERGE evidence (#2354), and ONLY an age-floor signal.
#
# ⛔ THIS IS NOT A SURVIVAL PROOF, and must never be returned by commits_survive (review of
# #2354). `git cherry <main> <sha>` answers "does an equal patch-id appear in main's HISTORY",
# which is neither reachability nor present state: measured on a fixture where the squash was
# later REVERTED, `git cherry` still prints `-` while `main` no longer contains the change; and
# patch-id is whitespace-insensitive, so a branch adding `x = 1` matches main's `x  =  1`. A
# detached head on no ref would then be "survives" and be removed, orphaning the commit — the
# exact P0 `detached-unreachable` exists to prevent. Reachability stays with commits_survive
# (ancestor, or a refs/heads/* holder); this predicate only shortens the AGE floor, where the
# branch ref already proves the commit cannot be orphaned.
patch_equivalent() { # <sha> -> 0 when every commit it adds has a patch-id twin on MAIN_REF
    local sha="$1"
    [ -n "$MAIN_REF" ] && [ -n "$sha" ] || return 1
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
        "$GIT_BIN" -C "$REPO_CANON" cherry "$MAIN_REF" "$sha" || return 1
    # An EMPTY range is not this class (the head is an ancestor of MAIN_REF).
    [ -s "$GIT_OUT" ] || return 1
    ! grep -q '^+' "$GIT_OUT"
}

# ── classification ─────────────────────────────────────────────────────
# classify_one <path> <sha> <branch> <flags> <now>
# Emits one row: "<verdict>\t<reason>\t<ephemeral>\t<detail>" (ephemeral is
# third so the free-text detail, which may embed a path containing a tab, is
# absorbed by cut -f4-).
# holders_live <canon> <recorded-path> <sha> -> 0 when a holder that is NOT a demoted idle shell
# exists (HL_VERDICT/HL_DETAIL name it), 1 when every holder was demoted (HL_STALE lists them) or
# there was none.
#
# ⛔ EVERY HOLDER IS EXAMINED, NOT JUST THE FIRST (agent-infra#2721): a worktree routinely holds an
# idle shell left over from an earlier lane AND a live lane's own process, so taking the first hit
# decides the whole checkout from whichever pid the probe happened to list first (reproduced while
# writing this: one stale shell masked a busy lane's shell). The scan carries a per-record EXCLUDE
# LIST rather than rewriting the probe output, so one verdict cannot change the evidence the next
# one sees, and the cap makes a probe that keeps returning the same pid terminate instead of spin.
holders_live() {
    local canon="$1" recorded="$2" sha="$3" pid seen="" n=0 cap
    HL_VERDICT=""; HL_DETAIL=""; HL_STALE=""; HL_PROOF=""
    cap=$(( $(wc -l <"${PS_OUT:-/dev/null}" 2>/dev/null || echo 0) + $(wc -l <"${CWD_OUT:-/dev/null}" 2>/dev/null || echo 0) + 4 ))
    [ "$cap" -ge 4 ] || cap=4
    # ⛐ THE CAP HAS A TEST SEAM (`REAP_WT_SCAN_CAP`) for the same reason as its venv twin: the default
    # exceeds any reachable holder count, so the exhaustion branch is unreachable in a healthy pass and
    # its POLARITY (`truncated => LIVE`, never "no holder") was unpinned — reverting it kept the suite
    # green while a truncated scan would read as unheld and the checkout deleted (review round 8, P2).
    if is_pos_int "${REAP_WT_SCAN_CAP:-}" && [ "${REAP_WT_SCAN_CAP}" -ge 1 ]; then cap="$REAP_WT_SCAN_CAP"; fi
    while pid="$(live_process_for "$canon" "$recorded" "$seen")"; do
        n=$((n + 1))
        if [ "$n" -gt "$cap" ]; then
            # ⛔ FAIL CLOSED ON EXHAUSTION (review round 3, P2): `break` fell through to `return 1`,
            # which BOTH callers read as "every holder was demoted, or there was none" — so a holder
            # the scan could not reach was reported as no holder and its checkout deleted. The
            # sibling venv reaper has always treated this as LIVE; same rule, same polarity here.
            log "STALE-SHELL-SCAN TRUNCATED at $cap holders — treating pid $pid as LIVE (fail-closed); report it"
            HL_VERDICT="live-process"; HL_DETAIL="$pid"
            HL_PROOF="proof=ps-argv:pid=$pid holds the path"; return 0
        fi
        seen="$seen $pid"
        if stale_shell_for "$pid" "$sha"; then
            HL_STALE="$HL_STALE pid=$pid(argv)"
            log "STALE-SHELL pid=$pid (argv) — an idle shell predating HEAD is not a live lane (#2721)"
            continue
        fi
        HL_VERDICT="live-process"; HL_DETAIL="$pid"
        HL_PROOF="proof=ps-argv:pid=$pid holds the path"; return 0
    done
    seen=""; n=0
    while pid="$(live_cwd_for "$canon" "$recorded" "$seen")"; do
        n=$((n + 1))
        if [ "$n" -gt "$cap" ]; then
            log "STALE-SHELL-SCAN TRUNCATED at $cap holders — treating pid $pid as LIVE (fail-closed); report it"
            HL_VERDICT="live-cwd"; HL_DETAIL="$pid"
            HL_PROOF="proof=lsof-cwd-prefix:pid=$pid has cwd inside the path"; return 0
        fi
        seen="$seen $pid"
        if stale_shell_for "$pid" "$sha"; then
            HL_STALE="$HL_STALE pid=$pid(cwd)"
            log "STALE-SHELL pid=$pid (cwd) — an idle shell predating HEAD is not a live lane (#2721)"
            continue
        fi
        HL_VERDICT="live-cwd"; HL_DETAIL="$pid"
        HL_PROOF="proof=lsof-cwd-prefix:pid=$pid has cwd inside the path"; return 0
    done
    return 1
}

classify_one() {
    local path="$1" sha="$2" branch="$3" flags="$4" now="$5"
    local canon detail crumb cverdict cpay eph="" exists=0 refs="" parent leaf proof_txt=""
    local head_ts tree_ts witness wname age_s young age_floor aged_note
    local pr pr_state pr_num pr_oid pr_key pr_other subj prnum_note pr_floor no_pr_proof
    case ",$flags," in *,poison,*)  printf 'preserve\tunparseable-path\t\trule=P proof=worktree-list --porcelain record had a tab/newline in the path — abstaining (fail-closed)\n'; return 0 ;; esac
    if [ "$branch" = "BARE" ]; then printf 'preserve\tbare\t\trule=P proof=worktree-list bare repository\n'; return 0; fi
    { [ -e "$path" ] || [ -L "$path" ]; } && exists=1
    canon="$(canonicalize "$path")"

    if [ -n "$canon" ] && [ "$canon" = "$MAIN_CANON" ]; then
        printf 'preserve\tmain-checkout\t\trule=P proof=worktree-list:first-entry %s\n' "$canon"; return 0
    fi
    if [ -n "$canon" ] && is_self_or_ancestor "$canon"; then
        printf 'preserve\tself-checkout\t\trule=P proof=cwd-prefix:%s contains the reaper cwd\n' "$SELF_CWD_CANON"; return 0
    fi
    # `locked` is checked BEFORE the gone-directory branch, deliberately: git
    # itself refuses to prune a locked record, so a locked worktree whose
    # checkout has vanished is still a PRESERVE — classifying it `prunable`
    # would claim (and count) a removal git will not perform.
    case ",$flags," in *,locked,*) printf 'preserve\tworktree-locked\t\trule=P proof=worktree-list:locked git worktree lock is set\n'; return 0 ;; esac
    if [ -z "$canon" ]; then
        # `canonicalize` failing means "cannot resolve", NOT "directory gone":
        # an existing-but-inaccessible checkout must never be treated as prunable
        # (that would deregister a live worktree and could orphan a detached
        # commit). A leaf stat is NOT sufficient to tell the two apart: with an
        # untraversable ANCESTOR (permissions) or an absent mount, `[ -e ]` and
        # `[ -L ]` are both false for a checkout that is still on disk, so the
        # leaf test alone reproduced `remove / reason=prunable` +
        # `REMOVED=1` on a LIVE worktree (cycle-8 review; A9b). Absence is only
        # proven by a REACHABLE parent that genuinely lacks the leaf — anything
        # else (unresolvable parent, or a leaf that is still there) is
        # `unreadable-path`: preserve, and prune-blocked.
        if [ "$exists" = 1 ]; then
            printf 'preserve\tunreadable-path\t\trule=P proof=stat:present,realpath:failed exists but cannot be resolved (permissions?)\n'; return 0
        fi
        parent="$(canonicalize "$(dirname "$path")")"
        leaf="${path##*/}"
        if [ -z "$parent" ] || [ -e "$parent/$leaf" ] || [ -L "$parent/$leaf" ]; then
            printf 'preserve\tunreadable-path\t\trule=P proof=parent:%s lacks the leaf; cannot prove the checkout is absent (unresolvable parent: %s)\n' "${parent:-<none>}" "${parent:-<none>}"
            return 0
        fi
        refs="$(commits_survive "$sha" "$branch")"
        case "$refs" in
            remote-only-ref:*|revocable-ref:*)
                printf 'preserve\t%s\t\trule=P proof=for-each-ref --contains %s sha %s is held only by %s (checkout already gone); that ref is revocable (`fetch --prune[--prune-tags]`, `stash drop`, `bisect reset`), so pruning the record would ORPHAN it\n' "${refs%%:*}" "${sha:-?}" "${sha:-?}" "${refs#*:}"
                return 0 ;;
            '')
                printf 'preserve\tdetached-unreachable\t\trule=P proof=for-each-ref --contains %s:no-ref sha %s is on no ref (checkout already gone) — pruning the record would ORPHAN it\n' "${sha:-?}" "${sha:-?}"
                return 0 ;;
        esac
        printf 'remove\tprunable\t\trule=P proof=git-worktree-prunable(directory already absent) commits-survive-via=%s\n' "$refs"
        return 0
    fi

    # ── THE HOLDERS, EXAMINED ONE BY ONE (agent-infra#2721) ────────────────────────────────────
    # ⛔ EVERY holder is examined, not just the first, and that is load-bearing: a worktree routinely
    # holds an idle shell left over from an earlier lane AND a live lane's own process, so taking the
    # first hit decides the whole checkout from whichever pid the probe happened to list first
    # (reproduced while writing this: one stale shell masked a busy lane's shell, and the rule then
    # demoted the wrong way). A holder that IS an idle shell predating HEAD is NAMED in the log and
    # the scan moves to the next one; the other gates (clean/reachable/open-pr/age) still decide.
    # ⛔ THE SAME EVIDENCE IS CONSULTED AT REMOVAL TIME (review round 1, P3). `classify_one` decides
    # from holders that existed minutes ago on a big box, so a demoted shell that got a child in the
    # meantime — i.e. started working again — must be able to STOP the removal, not just have been
    # right once. `holders_live` is shared by both call sites for exactly that reason.
    # The row keeps main's `rule=1 proof=…` convention: `holders_live` names the evidence it returned
    # (ps-argv or lsof-cwd-prefix), so a reader can tell which probe convicted the holder.
    # A demoted holder is carried into the row, so a reader can see WHY a checkout that looked live
    # was reclaimed — and can tell a genuine idle-shell demotion from a lane that was still working.
    local stale_txt=""
    if holders_live "$canon" "$path" "$sha"; then
        printf 'preserve\t%s\t\trule=1 %s\n' "$HL_VERDICT" "$HL_PROOF"; return 0
    fi
    [ -n "$HL_STALE" ] && stale_txt="stale-shell:$HL_STALE"

    crumb="$(clean_gate "$path")"
    cverdict="${crumb%%$'\t'*}"
    cpay="${crumb#*$'\t'}"
    case "$cverdict" in
        clean) eph="$cpay" ;;
        dirty)            printf 'preserve\tdirty\t\trule=2 proof=git-status --porcelain %s\n' "$cpay"; return 0 ;;
        ignored-artifact) printf 'preserve\tignored-artifact\t\trule=2 proof=git-status --ignored %s\n' "$cpay"; return 0 ;;
        status-timeout)   printf 'preserve\tstatus-timeout\t\trule=2 proof=git-status:timeout %s\n' "$cpay"; return 0 ;;
        *)                printf 'preserve\tstatus-error\t\trule=2 proof=git-status:error %s\n' "$cpay"; return 0 ;;
    esac

    # ── RULE 7's witnesses, computed BEFORE any removal rule can act ─────
    # A hung commit-graph read must not wedge the pass: the budget is only
    # checked between records, so this probe is watchdosed and a failure is
    # `unreadable-head` (PRESERVE).
    if ! run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
        "$GIT_BIN" -C "$REPO_CANON" log -1 --format=%ct "$sha"; then
        printf 'preserve\tunreadable-head\t\trule=P proof=git log -1 --format=%%ct %s:probe-failed cannot date HEAD %s\n' "${sha:-?}" "${sha:-?}"
        return 0
    fi
    head_ts="$(head -1 "$GIT_OUT" 2>/dev/null)"
    case "$head_ts" in
        ''|*[!0-9]*) printf 'preserve\tunreadable-head\t\trule=P proof=git log -1 --format=%%ct %s:unparseable cannot date HEAD %s\n' "${sha:-?}" "${sha:-?}"; return 0 ;;
    esac
    # The checkout's OWN ctime is the second witness (path_ctime): a checkout
    # created minutes ago from an hours-old main has an hours-old HEAD, so the
    # commit date alone does not measure the tree's age. The YOUNGER of the two
    # decides, because "young" is the safe direction. A timestamp in the FUTURE
    # of the pass clock cannot witness age (it would make every checkout
    # infinitely young, and the reaper would then reclaim nothing at all), so it
    # is ignored rather than trusted.
    witness="$head_ts"; wname="head-commit"
    tree_ts="$(path_ctime "$path")"
    case "$tree_ts" in
        ''|*[!0-9]*) : ;;
        *) if [ "$tree_ts" -le "$now" ] && [ "$tree_ts" -gt "$witness" ]; then
               witness="$tree_ts"; wname="worktree-ctime"
           fi ;;
    esac
    age_s="$((now - witness))"
    young=0
    [ "$age_s" -lt "$((REAP_WT_MIN_AGE_MINUTES * 60))" ] && young=1

    # ── RULES 4/5/6: PR state, from the pass's ONE batched read ──────────
    # The branch name is the natural key; a DETACHED head has none, so its
    # commit sha is matched against the PR's headRefOid instead. That is what
    # makes a squash-merged checkout provable at all: after a squash the branch
    # head is NOT an ancestor of main, and the PR is the only durable record
    # that the work landed. `PR_APPLICABLE=0` (no GitHub origin) means these
    # rules cannot be evaluated and the pre-existing aged policy decides —
    # never rule 6, which would be a claim about a state nobody read.
    local pr_rest=""
    pr=""; pr_state=""; pr_num=""; pr_oid=""; pr_key=""; pr_other=""
    if [ "$PR_APPLICABLE" = 1 ]; then
        if [ "$branch" != "-" ]; then
            pr="$(pr_state_for_ref "${branch#refs/heads/}")"
            pr_key="head-ref ${branch#refs/heads/}"
            if [ -n "$pr" ]; then
                pr_state="${pr%%$'\t'*}"; pr_rest="${pr#*$'\t'}"
                pr_num="${pr_rest%%$'\t'*}"; pr_oid="${pr_rest#*$'\t'}"
                # A MERGED row whose head is NOT this commit names OTHER work on a
                # reused branch name. It is not evidence about this head: forget it
                # (keeping the name for the row's note) and let the sha lookup answer.
                if [ "$pr_state" = "MERGED" ] && [ "$pr_oid" != "$sha" ]; then
                    pr_other="$pr_key"; pr=""; pr_state=""; pr_num=""; pr_oid=""
                fi
            fi
        fi
        if [ -z "$pr" ] && [ -n "$sha" ]; then
            pr="$(pr_state_for_sha "$sha")"
            pr_key="head-sha ${sha:0:12}"
        fi
        if [ -n "$pr" ]; then
            pr_state="${pr%%$'\t'*}"; pr_rest="${pr#*$'\t'}"
            pr_num="${pr_rest%%$'\t'*}"; pr_oid="${pr_rest#*$'\t'}"
        fi
    fi
    subj="head ${sha:0:12}"
    [ "$branch" != "-" ] && subj="branch ${branch#refs/heads/}"
    prnum_note=""
    case "$pr_num" in ''|*[!0-9]*) : ;; *) prnum_note=" (#$pr_num)" ;; esac

    refs="$(commits_survive "$sha" "$branch")"

    # ── THE AGE FLOOR, computed ONCE before any removal rule can act.
    # Three inputs, in this order (#1095, #2354, #2721):
    #   1. a MERGED head (an ancestor of MAIN_REF) needs no review floor at all;
    #   2. PATCH-EQUIVALENCE to MAIN_REF (`git cherry`, #2354) is the squash signal
    #      and lifts the floor exactly like `merged`. It is NOT a survival proof —
    #      see the ⛔ block in the header — so it never appears in `refs=`;
    #   3. a LANE SCRATCH checkout (`wt-*` / `cell-wt-*`) is a throwaway dir, so its
    #      floor is CAPPED at REAP_WT_SCRATCH_AGE_DAYS. The cap only ever LOWERS.
    # `too-young` (rule 7) is a separate, harder minimum applied on top.
    age_floor="$REAP_WT_AGED_DAYS"
    case "$refs" in
        merged) age_floor="$REAP_WT_MERGED_AGE_DAYS" ;;
        *)
            if patch_equivalent "$sha"; then
                age_floor="$REAP_WT_MERGED_AGE_DAYS"
                log "CLASSIFY patch-equivalent $path head=$sha"
            fi ;;
    esac
    if [ "$REAP_WT_SCRATCH_AGE_DAYS" -lt "$age_floor" ] && is_scratch_path "$path"; then
        age_floor="$REAP_WT_SCRATCH_AGE_DAYS"
    fi

    # ── rule=P: an OPEN PR outranks every removal rule. Unchanged, and it is
    # still a VETO rather than a vote: an open PR means the branch is live work
    # by definition, whenever the last commit was made.
    if [ "$pr_state" = "OPEN" ]; then
        printf 'preserve\topen-pr\t\trule=P proof=gh-state %s is an open PR head%s\n' "$subj" "$prnum_note"; return 0
    fi
    case "$refs" in
        remote-only-ref:*|revocable-ref:*)
            # A revocable ref is not a survival mechanism (F3/#1104). A MERGED PR
            # IS one — GitHub durably holds the commit's head sha — but ONLY when
            # that PR's head IS this commit: a reused branch name can match a PR
            # for older work whose sha GitHub holds and THIS checkout's does not
            # (#2756 review, P0). The oid equality is the whole warrant.
            if [ "$pr_state" != "MERGED" ] || [ "$pr_oid" != "$sha" ]; then
                printf 'preserve\t%s\t\trule=P proof=for-each-ref --contains %s sha %s is held only by %s — that ref is revocable (`fetch --prune[--prune-tags]`, `stash drop`, `bisect reset`); removing the checkout would then ORPHAN it\n' "${refs%%:*}" "${sha:-?}" "${sha:-?}" "${refs#*:}"
                return 0
            fi ;;
    esac

    # ── RULE 3: the commit is already in origin/main ──────────────────────
    # The strongest proof there is: a commit contained in main cannot be lost,
    # whatever else the checkout holds. Fired 31 times on cell-1 (511 MB ->
    # 8.6 GB) against trees logged `no upstream` for most of a day.
    if [ "$refs" = "merged" ]; then
        # ⛔ THE PROOF IS RETAKEN, not re-derived from the inputs: with a resolved remote main the
        # ancestry was proved against THAT oid, and `${MAIN_REF}` (the local cache) can be stale — so a
        # row printing `... ${MAIN_REF}=0` would cite a command that returns 1. See ancestry_proof_text.
        proof_txt="$(ancestry_proof_text "$sha")"
        if [ -z "$proof_txt" ]; then
            # ⛔ `rule=P`, NOT `rule=3`: rule 3 is a REMOVE in the table, and printing a KEEP row as
            # `rule=3` makes `grep 'rule=3'` report preserves as removals — the mirror of the defect the
            # rule-6 preserve row already carries a ⛔ for (#2756 review, P2). The suppressed rule is
            # named in words so the row still says which decision it aborted.
            printf 'preserve\tmain-proof-vanished\t\trule=P would-remove=3 the ancestry proof that put this row in the removal path does NOT reproduce now (tried %s then %s) — a proof that cannot be retaken removes nothing\n' \
                "${RESOLVED_MAIN:-<no-resolved-main>}" "${MAIN_REF:-<no-main-ref>}"
            return 0
        fi
        # `age_floor` already carries the merged floor (computed above).
        # A floor of 0 means "no floor", not "younger than one second": with the
        # ctime witness a checkout can be 0 seconds old, and `age <= 0` would
        # then report the degenerate floor instead of rule 7.
        if [ "$age_floor" -gt 0 ] && [ "$age_s" -le "$((age_floor * 86400))" ]; then
            printf 'preserve\ttoo-recent\t\trule=P age %sd ≤ %sd (merged floor) proof=%s\n' "$((age_s / 86400))" "$age_floor" "$proof_txt"
            return 0
        fi
        if [ "$young" = 1 ]; then
            printf 'preserve\ttoo-young\t\trule=7 age=%sm < %sm (witness=%s) proof=%s\n' "$((age_s / 60))" "$REAP_WT_MIN_AGE_MINUTES" "$wname" "$proof_txt"
            return 0
        fi
        log "CLASSIFY merged-age-floor $path head_age=$((age_s / 86400))d merged_floor=${age_floor}d"
        printf 'remove\treclaimable\t%s\trule=3 refs=merged proof=%s age=%sm clean=disposable-only unref=%s,no-open-pr\n' \
            "$eph" "$proof_txt" "$((age_s / 60))" "${stale_txt:-no-proc}"
        return 0
    fi

    # ── RULE 4: a MERGED PR for this head, whatever the merge strategy ────
    # Squash merges are the reason this rule exists: the branch head is a
    # non-ancestor of main even though the work is fully landed, so rule 3 can
    # never fire for that class and PR state is the only proof available.
    if [ "$pr_state" = "MERGED" ] && [ "$pr_oid" = "$sha" ]; then
        # The operator's merged cooldown governs here too (#2756 review, P1):
        # REAP_WT_MERGED_AGE_DAYS is the floor for BOTH landed classes, and the
        # scratch cap may only lower it. A PR-merged head is a STRONGER proof than
        # patch-equivalence, so it takes this floor even when `git cherry` could
        # not see the squash (multi-commit branches).
        pr_floor="$REAP_WT_MERGED_AGE_DAYS"
        if [ "$REAP_WT_SCRATCH_AGE_DAYS" -lt "$pr_floor" ] && is_scratch_path "$path"; then
            pr_floor="$REAP_WT_SCRATCH_AGE_DAYS"
        fi
        if [ "$pr_floor" -gt 0 ] && [ "$age_s" -le "$((pr_floor * 86400))" ]; then
            printf 'preserve\ttoo-recent\t\trule=P proof=age:%sd≤%sd(merged floor) pr-merged %s state=MERGED%s head=%s\n' \
                "$((age_s / 86400))" "$pr_floor" "$pr_key" "$prnum_note" "${pr_oid:0:12}"
            return 0
        fi
        if [ "$young" = 1 ]; then
            printf 'preserve\ttoo-young\t\trule=7 proof=age:%sm<%sm(witness=%s) pr-merged %s state=MERGED%s head=%s\n' "$((age_s / 60))" "$REAP_WT_MIN_AGE_MINUTES" "$wname" "$pr_key" "$prnum_note" "${pr_oid:0:12}"
            return 0
        fi
        printf 'remove\treclaimable\t%s\trule=4 refs=%s proof=pr-merged %s state=MERGED%s head=%s age=%sm clean=disposable-only unref=%s,no-open-pr\n' \
            "$eph" "$refs" "$pr_key" "$prnum_note" "${pr_oid:0:12}" "$((age_s / 60))" "${stale_txt:-no-proc}"
        return 0
    fi

    # ── RULE 5: closed without a merge, head not an ancestor — a human's call
    if [ "$pr_state" = "CLOSED" ]; then
        printf 'preserve\tpr-closed-unmerged\t\trule=5 proof=pr-closed %s state=CLOSED%s head-not-in=%s — the work was never merged; branch/refs survive and NOTHING was removed\n' \
            "$pr_key" "$prnum_note" "$(ancestry_candidates_text)"
        return 0
    fi

    # ── RULE 6: no PR at all ───────────────────────────────────────────────
    # "Not merged" is not "abandoned", so this row NAMES itself: it used to
    # read `too-recent` and told the operator nothing about why the checkout
    # could not be proven disposable. Past the aged floor the PRE-EXISTING #1095
    # policy still governs an aged, clean, holder-free checkout whose commits
    # survive on a branch (`git worktree remove` takes the checkout, never the
    # branch). That is a recorded decision and this rule does not reverse it; it
    # makes the window in between legible, which is what was missing.
    # `rule=6` is a KEEP in the table, so it is printed on the PRESERVE row only.
    # A removal past the floor is the PRE-EXISTING aged rule (rule=P) with the
    # no-PR evidence carried as a marker — attributing a removal to a keep-rule
    # made `grep 'rule=6'` report removals (#2756 review, P2).
    aged_note=""
    if [ "$PR_APPLICABLE" = 1 ] && [ -z "$pr_state" ]; then
        # The window is the FLOOR IN FORCE, not always 7d: a lane scratch dir past
        # its 1-day cap, or a patch-equivalent head past the merged floor, is out of
        # the window and falls through to the aged removal below.
        # ⛔ A MERGED PR FOR OTHER WORK IS NOT "NO PR" (#2756 review cycle 2). This
        # arm used to be an `elif` on the same condition, so once `pr_state` was
        # cleared the marker below was unreachable and a REMOVE row told the operator
        # "gh found no PR for this branch" while gh had returned a MERGED PR for it.
        # The proof now states which of the two it is, on BOTH rows.
        if [ -n "$pr_other" ]; then
            no_pr_proof="gh-state:$pr_other-state=MERGED-head=other"
        else
            no_pr_proof="gh-state:no-PR-matches-this-head($subj)"
        fi
        if [ "$age_floor" -gt 0 ] && [ "$age_s" -le "$((age_floor * 86400))" ]; then
            printf 'preserve\tno-pr\t\trule=6 proof=%s (no PR matches this head — cannot prove it is landed)%s refs=%s age=%sm\n' \
                "$no_pr_proof" "${pr_other:+ pr-merged-other-head=$pr_other}" "$refs" "$((age_s / 60))"
            return 0
        fi
        if [ -n "$pr_other" ]; then
            aged_note=" pr-merged-other-head=$pr_other"
        else
            aged_note=" no-pr=gh-state(no PR matches this head: $subj)"
        fi
    fi

    # ── rule=P: the commit is on no ref at all ─────────────────────────────
    # Checked AFTER rules 4-6 so a merged/closed PR is reported as itself, and
    # BEFORE the aged tail so an aged orphan is never removed: its admin record
    # is the commit's last durable handle.
    if [ "$refs" = "" ]; then
        printf 'preserve\tdetached-unreachable\t\trule=P proof=for-each-ref --contains %s:no-ref sha %s is on no ref — removing would orphan it\n' "${sha:-?}" "${sha:-?}"
        return 0
    fi

    # ── the age floor in force (already merged / patch-equivalent / scratch aware)
    if [ "$age_floor" -gt 0 ] && [ "$age_s" -le "$((age_floor * 86400))" ]; then
        printf 'preserve\ttoo-recent\t\trule=P proof=age:%sd≤%sd(witness=%s) refs=%s\n' "$((age_s / 86400))" "$age_floor" "$wname" "$refs"
        return 0
    fi
    if [ "$young" = 1 ]; then
        printf 'preserve\ttoo-young\t\trule=7 proof=age:%sm<%sm(witness=%s)\n' "$((age_s / 60))" "$REAP_WT_MIN_AGE_MINUTES" "$wname"
        return 0
    fi

    printf 'remove\treclaimable\t%s\trule=P proof=aged-floor(clean,holder-free,no-open-pr)%s refs=%s age=%sm clean=disposable-only unref=%s,no-open-pr\n' \
        "$eph" "$aged_note" "$refs" "$((age_s / 60))" "${stale_txt:-no-proc}"
    return 0
}

# ── removal ────────────────────────────────────────────────────────────
# holder_recheck <path> -> 0 when the deletion may proceed, 2 when it must be preserved.
# Re-reads the ps and cwd tables (the pass's are ONE snapshot — re-running the rule over them could
# never observe a change, so it would be an inert gate claiming a check it never ran) and re-applies
# `holders_live`. Sets REMOVE_SKIP_VERDICT and logs on every preserve path.
holder_recheck() {
    local path="$1" rcanon ps_prev cwd_prev cwd_prev_degraded
    rcanon="$(canonicalize "$path")"
    # ⛔ AND THE PREDECESSOR TABLE IS RELEASED (review round 3, P2): `ps_load` mints a NEW table and
    # never removes the old one, and the EXIT trap only removes whatever PS_OUT holds at exit — so
    # every re-check leaked one `pi-reap-ps.*` file (measured 19 in a single suite run) into the very
    # volume this reaper exists to reclaim. The cwd predecessor was already released; this is the pair.
    ps_prev="$PS_OUT"
    if ! ps_load; then
        # ⛔ A FAILED RE-PROBE MUST NOT WEAKEN THE PASS'S WITNESS SET (review round 10, P1).
        # `ps_load` assigns PS_OUT BEFORE it can fail (it mints the new table first, then returns 1 on
        # a timeout or an empty read), so returning here with PS_OUT pointing at the NEW EMPTY table
        # left `ps_prev` — the pass's good table — orphaned, and every LATER row of the pass was then
        # classified against an empty one. `live_process_for` begins `[ -s "$PS_OUT" ] || return 1`, so
        # "empty" reads as "no argv holder": a checkout whose only holder is argv-visible is deleted
        # under a live lane. The file's own loader states the rule this broke (`ps_load` header: an
        # empty table is a probe FAILURE, not "no live processes"). The cwd arm below already restores
        # its predecessor; this is the missing pair, and it also stops the leak of the new table into
        # the volume this reaper exists to reclaim. Reachable, not theoretical: `REAP_WT_PS_TIMEOUT` is
        # operator-settable and `ps -axo` on a cell carrying ~59 checkouts and 20 lanes is exactly the
        # probe that times out — and the pass continues afterwards, by design.
        if [ -n "${PS_OUT:-}" ] && [ "${PS_OUT:-}" != "$ps_prev" ]; then rm -f "$PS_OUT"; fi
        PS_OUT="$ps_prev"
        REMOVE_SKIP_VERDICT="live-probe-unavailable"
        log "REMOVE-SKIP $path the live-holder re-probe could not read the process table — nothing removed, preserved (fail-closed)"
        return 2
    fi
    self_pid_tree_load
    [ -n "$ps_prev" ] && [ "$ps_prev" != "$PS_OUT" ] && rm -f "$ps_prev"
    # ⛔ A DEGRADED CWD RE-READ MUST NOT SILENTLY WEAKEN THE WITNESS SET (review round 2, P1).
    # `cwd_probe_load` ALWAYS returns 0 and ALWAYS reassigns CWD_OUT, setting CWD_DEGRADED when lsof
    # fails — so a failed re-read here would (a) leave `live_cwd_for` reading an empty table, i.e. the
    # removal would proceed on ARGV-ONLY evidence, and (b) clobber the pass's good table for every
    # subsequent classification. A lane's own `pi` has cwd = the worktree and argv = the INSTALLED
    # path, so cwd is that holder's ONLY witness: proceeding would delete a live lane's checkout.
    # The distinction that matters is WHEN it degraded. `CWD_DEGRADED` describes the table in hand
    # NOW (review round 10, P2 — it used to be a latch that was never cleared, so after one transient
    # failure this guard could never fire again), so `cwd_prev_degraded = 0` really does mean "the
    # table we are about to replace is good". A host with NO lsof degrades on every call, so its
    # removal path stays argv-only BY DOCUMENTED DESIGN and the footer says so; a pass that started
    # degraded but has since read a good table is NOT such a host, and this guard stays armed for it.
    cwd_prev="$CWD_OUT"; cwd_prev_degraded="$CWD_DEGRADED"
    cwd_probe_load
    if [ "$cwd_prev_degraded" = 0 ] && { [ "$CWD_DEGRADED" != 0 ] || [ ! -s "${CWD_OUT:-}" ]; }; then
        [ -n "${CWD_OUT:-}" ] && rm -f "$CWD_OUT"
        CWD_OUT="$cwd_prev"; CWD_DEGRADED="$cwd_prev_degraded"
        REMOVE_SKIP_VERDICT="live-probe-unavailable"
        log "REMOVE-SKIP $path the cwd re-probe degraded (lsof failed or returned nothing) AFTER a good pass-start read — nothing removed, preserved (fail-closed)"
        return 2
    fi
    [ -n "$cwd_prev" ] && [ "$cwd_prev" != "$CWD_OUT" ] && rm -f "$cwd_prev"
    if holders_live "$rcanon" "$path" "${2:-}"; then
        REMOVE_SKIP_VERDICT="live-refound"
        log "REMOVE-SKIP $path a holder is live AGAIN (${HL_VERDICT} pid=${HL_DETAIL}) — nothing removed, preserved"
        return 2
    fi
    return 0
}

# remove_one <path> <sha>
# Never --force. Deletes the declared-ephemeral ROOT names first, whether
# UNTRACKED (`??`, which git DOES refuse on) or IGNORED (`!!`) — clean_gate's
# root branch collects both, so both are pre-deleted here. NESTED ignored
# regenerable caches are NOT collected and are left to git, which removes them
# with the checkout: `git worktree remove` does not refuse ignored files
# (verified — that fact is the whole reason the ignored gate exists).
# A refusal/timeout is REPORTED as REMOVE-FAILED, never swallowed.
#
# The pre-delete is a recursive filesystem delete over a checkout this script
# does not control, so it runs under the SAME watchdog as the removal — it was
# the last unbounded fork on the removal path. A failure (including a timeout)
# returns 1 => REMOVE-FAILED rather than continuing: an ephemeral that survived
# its deletion is a directory `git worktree remove` will refuse on anyway
# (untracked), so the honest report is available without a second unbounded
# attempt against the same block. The admin record is left intact either way.
#
# TOCTOU (F4 / #1105). The clean gate ran at CLASSIFICATION, and
# `git worktree remove` does NOT refuse IGNORED files, so a gitignored
# non-ephemeral file created in the window would be deleted with the checkout —
# silently, and the row already read `remove`. The window is re-checked HERE,
# twice: before the pre-delete (so a checkout that changed since classification
# is preserved with nothing deleted, not even its own ephemerals) and
# immediately before the destructive `git worktree remove`. A late appearance
# is a PRESERVE (return 2), not a removal and not a failure: nothing was
# removed, nothing failed, and the next pass re-classifies the record. The
# window is narrowed to the fork itself, not closed — closing it would need a
# lock on the checkout — which is exactly why the classification is re-checked
# rather than trusted.
#
# Returns 0 removed · 1 REMOVE-FAILED (a real failure ⇒ exit 4) ·
#         2 the removal-time clean re-check was not clean ⇒ PRESERVE
#           (the verdict is left in REMOVE_SKIP_VERDICT for the caller to print).
remove_one() {
    local path="$1" sha="$2" eph entry target out rc crumb cverdict cpay rcanon cwd_prev cwd_prev_degraded ps_prev
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-rm.XXXXXX")" || return 1

    # Re-check #0 — THE HOLDER RULE, again (review round 1), and AGAIN as the LAST step before the
    # fork (review round 3, P2): this early call avoids the deletions when a holder is already back,
    # but the window that matters is the TAIL — two `git status` calls and the ephemeral deletions
    # (up to REAP_WT_REMOVE_TIMEOUT each) sit between here and `git worktree remove`, and a shell
    # demoted as idle can pick up a child inside it. That is exactly "started working again".
    holder_recheck "$path" "$sha" || { rm -f "$out"; return 2; }

    # Re-check #1 — before ANY deletion. Without this, a checkout that grew an
    # ignored artifact since classification would lose its ephemerals to the
    # pre-delete and then be preserved anyway.
    crumb="$(clean_gate "$path")"
    cverdict="${crumb%%$'\t'*}"
    cpay="${crumb#*$'\t'}"
    if [ "$cverdict" != clean ]; then
        REMOVE_SKIP_VERDICT="$cverdict"
        log "REMOVE-SKIP $path checkout changed since classification ($cverdict: $cpay) — nothing removed, preserved"
        rm -f "$out"; return 2
    fi
    # The FRESH allowlist, not the classification-time one: an ephemeral that
    # appeared is still declared disposable, so it is deleted here rather than
    # left to make `git worktree remove` refuse.
    eph="$cpay"

    for entry in $eph; do
        target="$path/${entry%/}"
        [ -e "$target" ] || [ -L "$target" ] || continue
        if [ -L "$target" ]; then
            run_bounded "$REAP_WT_REMOVE_TIMEOUT" "$out" "$RM_BIN" -f "$target"
        else
            run_bounded "$REAP_WT_REMOVE_TIMEOUT" "$out" "$RM_BIN" -rf "$target"
        fi
        rc=$?
        if [ "$rc" != 0 ]; then
            if [ "$rc" = 124 ]; then
                log "REMOVE-FAIL $path ephemeral ${entry%/} timeout after ${REAP_WT_REMOVE_TIMEOUT}s (admin record left intact)"
            else
                log "REMOVE-FAIL $path ephemeral ${entry%/} rc=$rc"
            fi
            rm -f "$out"
            return 1
        fi
        log "EPHEMERAL removed ${entry%/} under $path"
    done

    # Re-check #2 — immediately before the fork that destroys. This is the one
    # that matters: the pre-delete above can run for up to
    # REAP_WT_REMOVE_TIMEOUT, which is the LARGEST part of the old window.
    crumb="$(clean_gate "$path")"
    cverdict="${crumb%%$'\t'*}"
    cpay="${crumb#*$'\t'}"
    if [ "$cverdict" != clean ]; then
        REMOVE_SKIP_VERDICT="$cverdict"
        log "REMOVE-SKIP $path removal-time re-check not clean ($cverdict: $cpay) — nothing removed, preserved"
        rm -f "$out"; return 2
    fi

    # Re-check #3 — THE HOLDER RULE, as the LAST thing before the fork (review round 3, P2). The
    # comment on re-check #0 called it "right before the delete" while it actually ran first, leaving
    # the two `git status` calls and the ephemeral deletions (up to REAP_WT_REMOVE_TIMEOUT each)
    # uncovered — the largest part of the window, by this file's own reasoning for re-check #2.
    holder_recheck "$path" "$sha" || { rm -f "$out"; return 2; }

    run_bounded "$REAP_WT_REMOVE_TIMEOUT" "$out" "$GIT_BIN" -C "$REPO_CANON" worktree remove "$path"
    rc=$?
    if [ "$rc" = 0 ]; then rm -f "$out"; return 0; fi
    if [ "$rc" = 124 ]; then
        log "REMOVE-FAIL $path timeout after ${REAP_WT_REMOVE_TIMEOUT}s (admin record left intact)"
    else
        log "REMOVE-FAIL $path rc=$rc $(head -1 "$out" 2>/dev/null)"
    fi
    rm -f "$out"
    return 1
}

# ── report ─────────────────────────────────────────────────────────────
report_row() { # <verdict> <path> <reason> <detail>
    if [ -n "${4:-}" ]; then
        printf '%-8s %s\n         reason=%s  %s\n' "$1" "$2" "$3" "$4"
    else
        printf '%-8s %s\n         reason=%s\n' "$1" "$2" "$3"
    fi
}

print_footer() {
    log "MODE=$MODE NOW=$1 AGED_DAYS=$REAP_WT_AGED_DAYS MIN_AGE_MINUTES=$REAP_WT_MIN_AGE_MINUTES WORKTREES=$WT_TOTAL REMOVE=$REMOVE_C PRESERVE=$PRESERVE_C REMOVED=$REMOVED FAILED=$FAILED LATE_PRESERVE=$LATE_PRESERVE DEFERRED=$DEFERRED DEFERRED_REMOVE=$DEFERRED_REMOVE CLASSIFIED=$CLASSIFIED_C GH=$GH_STATE CWD_PROBE=$([ "$CWD_DEGRADED" = 1 ] && printf degraded || printf ok) PRUNE_BLOCKED=$PRUNE_BLOCKED MAIN_PROOF=$MAIN_PROOF PR_MERGED=$PR_MERGED_STATE"
}

# summary_reasons — the preserved reasons as `reason:count,…`, most frequent first.
summary_reasons() {
    [ -n "$PRESERVE_REASONS" ] || { printf 'none'; return 0; }
    printf '%s\n' "$PRESERVE_REASONS" | tr ' ' '\n' | sed '/^$/d' | sort | uniq -c | sort -rn \
        | awk '{printf "%s%s:%s", (n++ ? "," : ""), $2, $1}'
}

# summary_line — the pass's ONE machine-readable tally.
#
# ⛔ TWO identities, and the reason there are two: a DEFERRED record is one the budget stopped the
# pass BEFORE classifying, so adding it to `classified` would claim a decision that was never made
# (measured: a 16-record list with a 1s budget printed `classified=2 … deferred=15`, and
# `2 = 1 + 1 + 15` is arithmetic that does not reconcile). So:
#     classified = remove + preserved      (every record the pass actually DECIDED)
#     examined   = classified + deferred   (`examined` is the length of git's own listing, so this
#                                           one is checkable against WORKTREES= in the footer)
# `preserved` EXCLUDES deferrals, and a deferred REMOVAL is its own counter (`deferred_remove`) — it
# was classified and selected, so folding it into `deferred` deflates `preserved`. A deferred record
# also blocks the end-of-pass prune. `removed`/`failed`/`late_preserved` are APPLY-mode outcomes and
# stay 0 in a dry run; `remove=` is therefore "would remove" in dry-run and "selected" in apply. A
# pass that removes nothing is visible HERE (`examined=51 classified=51 remove=0 preserved=51
# reasons=too-recent:51`), which `REMOVED=0` alone never was.
summary_line() {
    printf 'SUMMARY examined=%s classified=%s remove=%s preserved=%s deferred=%s deferred_remove=%s removed=%s failed=%s late_preserved=%s prune_blocked=%s reasons=%s main_proof=%s main_ref=%s pr_merged=%s\n' \
        "$WT_TOTAL" "$CLASSIFIED_C" "$REMOVE_C" "$((PRESERVE_C - DEFERRED))" "$DEFERRED" "$DEFERRED_REMOVE" \
        "$REMOVED" "$FAILED" "$LATE_PRESERVE" "$PRUNE_BLOCKED" "$(summary_reasons)" "$MAIN_PROOF" "${MAIN_REF_NAME:-${MAIN_REF:-?}}" "$PR_MERGED_STATE"
}

# ── main ───────────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) MODE=dry-run; shift ;;
            --apply) MODE=apply; shift ;;
            --list) LIST_ONLY=1; shift ;;
            --repo)
                [ $# -ge 2 ] || { echo "bad --repo: missing value" >&2; exit 2; }
                REPO="$2"; shift 2 ;;
            --aged-days)
                [ $# -ge 2 ] || { echo "bad --aged-days: missing value" >&2; exit 2; }
                REAP_WT_AGED_DAYS="$2"; shift 2 ;;
            --main)
                [ $# -ge 2 ] || { echo "bad --main: missing value" >&2; exit 2; }
                MAIN_REF_OVERRIDE="$2"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
}

run() {
    local now
    # One EXIT trap for the whole pass, installed BEFORE the first bounded probe:
    # it owns the probe scratch dir, the watchdog timers, the probe output files
    # and the lock. Installing it later (as it was) leaked the scratch dir on
    # every early fail-closed exit.
    trap 'tb_watchdogs_reap; tb_bound_cleanup; rm -f "$PS_OUT" "$CWD_OUT" "$GIT_OUT"; lock_release' EXIT
    if [ "$MODE" = unknown ]; then
        if [ "$REAP_WT_DRY_RUN" = "0" ]; then MODE=apply; else MODE=dry-run; fi
    fi
    case "$MODE" in dry-run|apply) ;; *) usage >&2; exit 2 ;; esac

    # Validate every operator-settable number BEFORE it guards anything. A
    # non-numeric timeout would otherwise disable its watchdog and let a probe
    # block forever — the failure mode this tool exists to prevent.
    local v
    for v in REAP_WT_AGED_DAYS:"$REAP_WT_AGED_DAYS" REAP_WT_LIST_TIMEOUT:"$REAP_WT_LIST_TIMEOUT" \
             REAP_WT_STATUS_TIMEOUT:"$REAP_WT_STATUS_TIMEOUT" REAP_WT_PS_TIMEOUT:"$REAP_WT_PS_TIMEOUT" \
             REAP_WT_CWD_TIMEOUT:"$REAP_WT_CWD_TIMEOUT" REAP_WT_GH_TIMEOUT:"$REAP_WT_GH_TIMEOUT" \
             REAP_WT_REMOVE_TIMEOUT:"$REAP_WT_REMOVE_TIMEOUT" REAP_WT_GIT_TIMEOUT:"$REAP_WT_GIT_TIMEOUT" \
             REAP_WT_REMOVE_TIMEOUT:"$REAP_WT_REMOVE_TIMEOUT" REAP_WT_BUDGET_SECONDS:"$REAP_WT_BUDGET_SECONDS" \
             REAP_WT_LOCK_STALE_SECONDS:"$REAP_WT_LOCK_STALE_SECONDS" REAP_WT_PR_LIMIT:"$REAP_WT_PR_LIMIT" \
             REAP_WT_MIN_AGE_MINUTES:"$REAP_WT_MIN_AGE_MINUTES" \
             REAP_WT_MAX_DAYS:"$REAP_WT_MAX_DAYS" \
             REAP_WT_MERGED_AGE_DAYS:"$REAP_WT_MERGED_AGE_DAYS" \
             REAP_WT_SCRATCH_AGE_DAYS:"$REAP_WT_SCRATCH_AGE_DAYS"; do
        is_pos_int "${v#*:}" || { echo "bad ${v%%:*}: ${v#*:} (want a non-negative integer)" >&2; exit 2; }
    done
    awk -v a="$REAP_WT_AGED_DAYS" -v m="$REAP_WT_MAX_DAYS" 'BEGIN{exit !(a >= 0 && a <= m)}' \
        || { echo "bad --aged-days: out of range (0..$REAP_WT_MAX_DAYS)" >&2; exit 2; }
    # `--aged-days` range is bounded above as well as below. The loop above already REFUSES a
    # non-numeric floor (`is_pos_int`), so what this adds is the upper bound: a value that is numeric
    # but beyond REAP_WT_MAX_DAYS. Same bound, same remedy line, for the merged floor — it governs the
    # common arm now (every squash-landed head), so an out-of-range value must fail here, loudly,
    # rather than silently changing every verdict in the pass.
    awk -v m="$REAP_WT_MERGED_AGE_DAYS" -v x="$REAP_WT_MAX_DAYS" 'BEGIN{exit !(m >= 0 && m <= x)}' \
        || { echo "bad REAP_WT_MERGED_AGE_DAYS: $REAP_WT_MERGED_AGE_DAYS (want 0..$REAP_WT_MAX_DAYS)" >&2; exit 2; }
    # An unrecognised proof mode must not silently become "local" OR "auto": one skips the remote
    # read, the other opens a network call, and neither is what the operator asked for.
    case "$REAP_WT_MAIN_PROOF" in
        auto|local) ;;
        *) echo "bad REAP_WT_MAIN_PROOF: $REAP_WT_MAIN_PROOF (want auto|local)" >&2; exit 2 ;;
    esac
    # An explicit age witness is a NUMBER or it is a refusal: a typo must not
    # silently drop the witness and leave rule 7 measuring HEAD's commit date.
    if [ -n "${REAP_WT_TREE_TS:-}" ]; then
        is_pos_int "$REAP_WT_TREE_TS" || { echo "bad REAP_WT_TREE_TS: $REAP_WT_TREE_TS (want epoch seconds)" >&2; exit 2; }
    fi

    # ONE reusable scratch file for every bounded git probe in the pass. The
    # property probes run PER WORKTREE, so a per-call mktemp would add forks to
    # the tool that exists to unload the host; a single file is truncated by
    # each run_bounded call and is owned by the EXIT trap.
    GIT_OUT="$(mktemp "${TMPDIR:-/tmp}/pi-reap-git.XXXXXX")" || GIT_OUT=""
    if [ -z "$GIT_OUT" ]; then
        echo "FAIL-CLOSED abort: cannot create the probe scratch file (exit 3)" >&2
        exit 3
    fi

    REPO="${REPO:-$PWD}"
    REPO_CANON="$(canonicalize "$REPO")"
    [ -n "$REPO_CANON" ] || { echo "not a directory: $REPO" >&2; exit 2; }
    local common
    run_bounded "$REAP_WT_GIT_TIMEOUT" "$GIT_OUT" \
        "$GIT_BIN" -C "$REPO_CANON" rev-parse --git-common-dir
    [ $? = 0 ] || { echo "not a git repository: $REPO_CANON" >&2; exit 2; }
    common="$(head -1 "$GIT_OUT" 2>/dev/null)"
    [ -n "$common" ] || { echo "not a git repository: $REPO_CANON" >&2; exit 2; }
    case "$common" in
        /*) : ;;
        *) common="$REPO_CANON/$common" ;;
    esac
    COMMON_DIR="$(canonicalize "$common")"
    [ -n "$COMMON_DIR" ] || COMMON_DIR="$common"
    # The main worktree is the FIRST entry of `git worktree list` (git
    # documents that order). Deriving it from `--git-common-dir` by stripping
    # `/.git` breaks for submodules and --separate-git-dir, which would leave
    # the main checkout unrecognised and offered for removal.
    wt_z_probe
    WT_LIST=""
    if ! wt_list_load; then
        echo "FAIL-CLOSED abort: git worktree list failed (exit 3)" >&2
        log "FAIL-CLOSED abort: git worktree list failed (exit 3)"
        exit 3
    fi
    # ⛔ AN EMPTY LIST IS NOT A HEALTHY PASS (#4529 review). `git worktree list` ALWAYS records at
    # least the main (or bare) worktree, so ZERO records means the enumeration answered nothing —
    # and a pass that goes on to publish `examined=0 classified=0 remove=0 preserved=0 reasons=none`
    # is the "a no-op pass is indistinguishable from a healthy one" shape this PR exists to remove,
    # now wearing a machine-readable tally that makes it look measured. The sibling delegate refuses
    # exactly this state (`reap-lane-venvs.sh`: "reports no worktrees at all — that cannot be true of
    # a checkout (exit 3)"); this arm must not be the weaker one. It is checked BEFORE MAIN_CANON's
    # fallback (which would silently invent a main) and before `--list` can print an empty success.
    if [ -z "$WT_LIST" ]; then
        echo "FAIL-CLOSED abort: git worktree list reported no worktrees — that cannot be true of a checkout (exit 3)" >&2
        log "FAIL-CLOSED abort: git worktree list reported no worktrees (exit 3)"
        exit 3
    fi
    MAIN_CANON="$(printf '%s\n' "$WT_LIST" | head -1 | cut -f1 | while IFS= read -r p; do canonicalize "$p"; done)"
    [ -n "$MAIN_CANON" ] || MAIN_CANON="$REPO_CANON"
    SELF_CWD_CANON="$(canonicalize "$PWD")"
    now="$(now_epoch)"
    MAIN_REF="$(resolve_main_ref)"
    # The remote's own advertised default branch OUTRANKS the local ref chain: `origin/main` is a
    # cache, and a pass that proves "merged into main" against a stale cache is a false PASS one
    # layer down. Failure is not fatal — every arm falls back to MAIN_REF and says so.
    resolve_remote_main

    if [ "$LIST_ONLY" = 1 ]; then
        while IFS=$'\t' read -r p h b f; do
            [ -n "$p" ] || continue
            case ",$f," in *,poison,*) b="(unparseable)" ;; esac
            printf '%s\t%s\t%s\n' "$p" "$h" "${b#refs/heads/}"
        done <<<"$WT_LIST"
        exit 0
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ "$MODE" = apply ] && ! : >>"$REAP_WT_LOG" 2>/dev/null; then
        echo "FAIL-CLOSED abort: REAP_WT_LOG unwritable ($REAP_WT_LOG) (exit 3)" >&2
        exit 3
    fi
    if ! lock_acquire; then
        echo "FAIL-CLOSED abort: lock held ($LOCK_DIR) (exit 3)" >&2
        exit 3
    fi

    log "==== pi-reap-worktrees pass: MODE=$MODE repo=$REPO_CANON aged=${REAP_WT_AGED_DAYS}d main=${MAIN_CANON} now=$now ===="
    WT_TOTAL="$(printf '%s\n' "$WT_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"

    # PR state is now needed for EVERY real record, not only for the ones with a
    # branch: rule 4 matches a DETACHED head by its commit sha (a detached head
    # has no branch name, and that is exactly the class that sat unprovable on
    # cell-4 for days — #2721). A BARE record is the main repo's own and never a
    # candidate, so its PR state is never consulted.
    local need_pr=0 p h b f
    while IFS=$'\t' read -r p h b f; do
        [ -n "$p" ] || continue
        [ "$b" = "BARE" ] || { need_pr=1; break; }
    done <<<"$WT_LIST"
    if [ "$need_pr" = 1 ]; then
        if ! pr_state_load; then
            # ⛔ THE REASON, NOT A GUESS — and it is MACHINE-READABLE. The first line names the gate,
            # the second carries `skipped=<repo> reason=<token>` for the caller (disk-reaper.sh reads
            # it to report a per-repo skip and keep reclaiming the repos it CAN verify), and the third
            # is the remedy for THIS cause. `skipped=` is on stderr like every other abort line and
            # `run_class` merges both streams, so the entry point sees it either way.
            echo "FAIL-CLOSED abort: the PR-state gate cannot be verified for this repo (exit 3)" >&2
            echo "SKIPPED-REPO: skipped=${REPO_CANON:-$REPO} reason=${PR_SKIP_REASON:-unknown}" >&2
            echo "   ${PR_SKIP_REMEDY:-set REAP_WT_REPO_SLUG, or replace the origin remote with a GitHub URL}" >&2
            echo "   NOTHING in this repo was touched: a checkout whose PR state is unknown is never removed (the other repos in the pass are unaffected)" >&2
            echo "   (#2354: the scheduled pass must use the REAL gh — a wedged interactive shim is a" >&2
            echo "   deployment defect, not a reason to skip the veto; nothing is removed)" >&2
            log "FAIL-CLOSED abort: PR-state gate unverifiable for ${REPO_CANON:-$REPO} (reason=${PR_SKIP_REASON:-unknown}) with candidates (exit 3)"
            print_footer "$now"
            exit 3
        fi
    else
        GH_STATE="na"; GH_OK=1; PR_APPLICABLE=0
    fi
    # The pass's PR-state read IS the merged evidence (rules 4-6: a squash-merged head is never an
    # ancestor of main, so PR state is the only proof available). Record whether it was answerable, so
    # a consumer can tell `pr_merged=ok` (read, answered) from `pr_merged=unavailable` (never read).
    pr_merged_state_from_gh

    if ! ps_load; then
        echo "FAIL-CLOSED abort: ps enumeration failed or empty — cannot verify the live-reference gate (exit 3)" >&2
        log "FAIL-CLOSED abort: ps enumeration failed/empty (exit 3)"
        print_footer "$now"
        exit 3
    fi
    self_pid_tree_load
    cwd_probe_load

    log_line "rules: 1 live-holder KEEP · 2 dirty KEEP · 3 ancestor-of-main REMOVE · 4 PR-MERGED REMOVE ·"
    log_line "       5 PR-CLOSED KEEP(named) · 6 no-PR KEEP(named) · 7 younger-than-${REAP_WT_MIN_AGE_MINUTES}m KEEP ·"
    log_line "       P pre-existing gates (main/self/locked/open-PR/revocable-ref). Every row prints rule= and proof=."
    log_line ""
    log_line "note: \`git worktree remove\` deletes the CHECKOUT only — branch refs are never deleted by this tool."
    log_line "note: no byte-savings figure is reported — a per-worktree .venv shares blocks with the uv"
    log_line "      cache on SOME machines (APFS clonefile, or a hardlink) and is REAL on others"
    log_line "      (Linux/overlayfs, a cache on another volume — measured 2026-10-16: du 22.0 MB vs df"
    log_line "      +0.6 MB when cloned; du 5,647 MiB vs df 5.90 GB real, ratio 1.004). The deliverable"
    log_line "      win is FILE COUNT. Real bytes are measured per machine, never inferred from du:"
    # The probe is FARMED (pi-bootstrap/setup.sh fleet_srcs) because cells run this reaper from
    # $DEST/scripts, not from a checkout — so a repo-relative `scripts/...` hint would not resolve
    # where this line is actually read. Name the SIBLING this script was invoked as (#1858 review P2).
    log_line "      bash ${SELF_DIR:+$SELF_DIR/}worktree-disk-probe.sh --help   (#1851)"
    log_line ""

    local elapsed=0 crumb verdict reason detail rc
    # The budget clock starts HERE, not at `now`: see the BOUNDEDNESS note in
    # the header. `now` stays the single ageing reference for the whole pass.
    START_EPOCH="$(now_epoch)"
    while IFS=$'\t' read -r p h b f; do
        [ -n "$p" ] || continue
        elapsed="$(( $(now_epoch) - START_EPOCH ))"
        if [ "$REAP_WT_BUDGET_SECONDS" -gt 0 ] && [ "$elapsed" -ge "$REAP_WT_BUDGET_SECONDS" ]; then
            log_line "preserve $p"
            log_line "         reason=deferred  pass budget ${REAP_WT_BUDGET_SECONDS}s exhausted — not classified"
            log "DEFERRED $p (budget)"
            # CRITICAL: a deferred record is UNCLASSIFIED, so we cannot know
            # whether it is also prunable. A global `git worktree prune` would
            # therefore sweep it up — and for a gone checkout whose detached
            # HEAD is on no ref, that deregisters the last holder of that
            # commit (the very P0 the commits-survive gate exists to prevent).
            PRUNE_BLOCKED=1
            PRESERVE_C=$((PRESERVE_C + 1)); DEFERRED=$((DEFERRED + 1))
            continue
        fi
        crumb="$(classify_one "$p" "$h" "$b" "$f" "$now")"
        verdict="$(printf '%s' "$crumb" | cut -f1)"
        reason="$(printf '%s' "$crumb" | cut -f2)"
        detail="$(printf '%s' "$crumb" | cut -f4- | tr '\n' ' ')"
        # A CLASSIFIED record is one the pass actually DECIDED. A deferred record below increments
        # PRESERVE_C but never reaches here, which is why `classified = remove + preserved` is the
        # identity the SUMMARY line advertises and `examined = classified + deferred` is the second.
        CLASSIFIED_C=$((CLASSIFIED_C + 1))
        report_row "$verdict" "$p" "$reason" "$detail"
        if [ "$verdict" = "remove" ]; then
            REMOVE_C=$((REMOVE_C + 1))
            log "CLASSIFY remove $p reason=$reason $detail"
            if [ "$reason" = "prunable" ] && [ "$MODE" = apply ]; then PRUNE_WANTED=$((PRUNE_WANTED + 1)); fi
            if [ "$MODE" = apply ]; then
                elapsed="$(( $(now_epoch) - START_EPOCH ))"
                if [ "$REAP_WT_BUDGET_SECONDS" -gt 0 ] && [ "$elapsed" -ge "$REAP_WT_BUDGET_SECONDS" ]; then
                    log_line "         NOT REMOVED (pass budget exhausted) — will be re-classified next pass"
                    log "DEFERRED-REMOVE $p (budget)"
                    # Its removal did not happen, so the end-of-pass prune must
                    # not run either: for a `prunable` row the prune IS the
                    # removal, and it has no path filter.
                    PRUNE_BLOCKED=1
                    DEFERRED_REMOVE=$((DEFERRED_REMOVE + 1))
                    continue
                fi
                if [ "$reason" = "prunable" ]; then
                    # Deferred to the single end-of-pass `git worktree prune`
                    # below: prune has no path filter, so it must not run while
                    # any unclassified (deferred) or preserved record could
                    # also be prunable. REMOVED is incremented ONLY if the
                    # prune actually ran — otherwise the report would claim a
                    # removal that never happened.
                    log_line "         REMOVES — pending the end-of-pass \`git worktree prune\` (a global prune has no path filter)"
                    log "PRUNE-PENDING $p"
                else
                    remove_one "$p" "$h"; rc=$?
                    case "$rc" in
                        0)
                            log_line "         REMOVED — branch/refs survive: $(printf '%s' "$detail" | sed -n 's/.*refs=\([^ ]*\).*/\1/p')"
                            REMOVED=$((REMOVED + 1))
                            log "REMOVED $p" ;;
                        2)
                            # The removal-time re-check was not clean (F4): the
                            # checkout is PRESERVED. Nothing failed and nothing
                            # was removed, so this must NOT be exit 4 — that
                            # code is the machine-readable "a removal failed".
                            # The verdict is printed, not assumed: `dirty` and
                            # `ignored-artifact` mean the checkout changed,
                            # while `status-*` means the probe could not be
                            # evaluated — different operator actions.
                            log_line "         PRESERVED — removal-time re-check kept it (${REMOVE_SKIP_VERDICT:-unknown}); nothing removed"
                            LATE_PRESERVE=$((LATE_PRESERVE + 1))
                            log "PRESERVED-LATE $p" ;;
                        *)
                            log_line "         REMOVE-FAILED — see the log ($REAP_WT_LOG)"
                            FAILED=$((FAILED + 1)) ;;
                    esac
                fi
            fi
        else
            PRESERVE_C=$((PRESERVE_C + 1))
            PRESERVE_REASONS="$PRESERVE_REASONS$reason "
            log "CLASSIFY preserve $p reason=$reason $detail"
            # A preserved record that git may ALSO deem prunable must not be
            # swept up by the global, path-filterless prune. The AUTHORITATIVE
            # predicate is git's OWN `prunable` flag: as of the pass-start
            # snapshot it is exactly the set the prune would then remove, so it
            # is what makes a gone-directory row's
            # admin HEAD load-bearing. A detached worktree's admin HEAD is a
            # reachability root for `git gc` (and its reflog a second handle),
            # so deregistering a preserved GONE record discards the last DURABLE
            # handle of a commit whose only other holder is a REVOCABLE ref —
            # the F3 exposure reached through the prune. Reproduced in cycle 8
            # (A24). Present-directory records are never flagged prunable, so a
            # live `remote-only-ref` row no longer disables reclaiming the
            # prunable class (F7/A23) — which is why this is a flag test, not a
            # reason test. The snapshot cannot see a record that becomes
            # prunable DURING the pass, and `git worktree prune` re-evaluates
            # prunability at prune time; F17 closes that window with a bounded
            # pre-prune re-read, because for a preserved gone-dir row the admin
            # HEAD is the commit's last durable handle.
            case ",$f," in *,prunable,*) PRUNE_BLOCKED=1 ;; esac
            # Belt and braces for a record preserved because a PROBE could not
            # be evaluated: git may not have flagged it prunable, and
            # `detached-unreachable` (commit on NO ref) is the one reason where
            # losing the record's HEAD is unrecoverable, so it blocks on the
            # reason regardless.
            case "$reason" in
                unreadable-path|status-error|status-timeout|unparseable-path|worktree-locked) PRUNE_BLOCKED=1 ;;
                detached-unreachable) PRUNE_BLOCKED=1 ;;
                # `remote-only-ref` / `revocable-ref` block ONLY via the flag
                # test above — a present-dir row of either must not block.
            esac
        fi
    done <<<"$WT_LIST"

    if [ "$MODE" = apply ] && [ "$PRUNE_WANTED" -gt 0 ]; then
        # F17 (cycle-10, P1) — the per-record `prunable` test above read the flag
        # from the list snapshot taken at PASS START, but `git worktree prune`
        # RE-EVALUATES prunability at prune time. A record that was PRESENT then
        # and is GONE now carries no flag in that snapshot, so nothing set
        # PRUNE_BLOCKED — yet the path-filterless prune sweeps it. Where such a
        # record was PRESERVED as `remote-only-ref`/`revocable-ref`, its admin
        # HEAD is the commit's last DURABLE handle, so the prune ORPHANS the
        # commit: the F9 class, reached through a window the snapshot cannot
        # see (threat classes 2 and 4). Re-list immediately before the prune —
        # bounded, one probe — and block unless every now-prunable path ALREADY
        # carried the flag when it was classified (those are the intended
        # reclaim targets). An unreadable re-read, or an unusable scratch file,
        # is fail-closed: block.
        PRUNE_START_LIST="$WT_LIST"
        PRUNE_RECHECK_FAILED=0
        # `wt_list_load` APPENDS to WT_LIST (it does not reset it), so the
        # re-read needs the accumulator cleared first — otherwise the re-read
        # list contains every path TWICE and the set comparison below reports a
        # spurious difference, blocking the prune on every pass.
        WT_LIST=""
        wt_list_load || PRUNE_RECHECK_FAILED=1
        PRUNE_START_TMP=""
        PRUNE_NOW_TMP=""
        if [ "$PRUNE_RECHECK_FAILED" = 0 ]; then
            PRUNE_START_TMP="$(mktemp "${TMPDIR:-/tmp}/pi-reap-prune-start.XXXXXX")" || PRUNE_RECHECK_FAILED=1
            PRUNE_NOW_TMP="$(mktemp "${TMPDIR:-/tmp}/pi-reap-prune-now.XXXXXX")" || PRUNE_RECHECK_FAILED=1
        fi
        PRUNE_NEWLY=""
        if [ "$PRUNE_RECHECK_FAILED" = 0 ]; then
            : >"$PRUNE_START_TMP"; : >"$PRUNE_NOW_TMP"
            # only the path is needed, and only from records git ALREADY flags
            while IFS=$'\t' read -r _p _h _b _f; do
                [ -n "$_p" ] || continue
                case ",$_f," in *,prunable,*) printf '%s\n' "$_p" >>"$PRUNE_START_TMP" ;; esac
            done <<<"$PRUNE_START_LIST"
            while IFS=$'\t' read -r _p _h _b _f; do
                [ -n "$_p" ] || continue
                case ",$_f," in *,prunable,*) printf '%s\n' "$_p" >>"$PRUNE_NOW_TMP" ;; esac
            done <<<"$WT_LIST"
            # F18 (cycle-11, P1) — the comparison toolchain's OWN exit status is
            # part of the probe, not an implementation detail. With `sort` or
            # `comm` unavailable the process writes to stderr and leaves stdout
            # EMPTY, which is byte-for-byte what "no new prunable record" looks
            # like. Reading that empty result without the rc let the
            # path-filterless prune run on an UNVERIFIABLE comparison — the same
            # unverifiable-probe bypass (threat class 3) the re-read rc already
            # closes. Three rc checks, no extra fork; the removal `rm` below is
            # still unconditional so a failed run leaves no scratch behind.
            sort -o "$PRUNE_START_TMP" "$PRUNE_START_TMP" || PRUNE_RECHECK_FAILED=1
            sort -o "$PRUNE_NOW_TMP" "$PRUNE_NOW_TMP" || PRUNE_RECHECK_FAILED=1
            PRUNE_NEWLY="$(comm -23 "$PRUNE_NOW_TMP" "$PRUNE_START_TMP")" || PRUNE_RECHECK_FAILED=1
        fi
        [ -n "$PRUNE_START_TMP" ] && rm -f "$PRUNE_START_TMP"
        [ -n "$PRUNE_NOW_TMP" ] && rm -f "$PRUNE_NOW_TMP"
        if [ "$PRUNE_RECHECK_FAILED" = 1 ]; then
            # Never "could not check, so reclaim anyway": an unevaluable re-read,
            # scratch file, or comparison is exactly the unverifiable-probe case
            # (threat class 3).
            PRUNE_BLOCKED=1
            log "PRUNE-RECHECK-FAILED (re-read, scratch file, or comparison unavailable — fail-closed, global prune skipped)"
        elif [ -n "$PRUNE_NEWLY" ]; then
            PRUNE_BLOCKED=1
            log_line ""
            log_line "⚠️  $(printf '%s\n' "$PRUNE_NEWLY" | wc -l | tr -d ' ') record(s) became prunable DURING this pass, after they were classified — the global prune is skipped."
            while IFS= read -r _nl; do
                [ -n "$_nl" ] || continue
                log "PRUNE-RECHECK-BLOCK $_nl (became prunable after classification — not an intended reclaim target)"
            done <<<"$PRUNE_NEWLY"
        fi
        # the pass's snapshot is authoritative again for anything that follows
        WT_LIST="$PRUNE_START_LIST"
        if [ "$PRUNE_BLOCKED" = 1 ]; then
            log_line ""
            log_line "⚠️  skipped \`git worktree prune\`: ${PRUNE_WANTED} reclaimable gone-checkout record(s) were"
            log_line "    left registered, because a record this pass did not classify (deferred), did"
            log_line "    preserve, or became prunable only after classification — and a global prune"
            log_line "    has no path filter."
            log_line "    Nothing was lost: those records are re-classified on the next pass."
            log "PRUNE-SKIPPED wanted=$PRUNE_WANTED (a deferred, preserved, or mid-pass-prunable record may be prunable)"
        elif run_bounded "$REAP_WT_REMOVE_TIMEOUT" "$GIT_OUT" "$GIT_BIN" -C "$REPO_CANON" worktree prune; then
            REMOVED=$((REMOVED + PRUNE_WANTED))
            log "PRUNED $PRUNE_WANTED gone-checkout record(s)"
        else
            # The prune is the ACTUAL removal for a `prunable` row, so it is
            # watchdosed like every other removal: a hang here must not wedge a
            # pass that has already finished classifying.
            FAILED=$((FAILED + PRUNE_WANTED))
            log "PRUNE-FAIL (gone-checkout records left registered)"
        fi
    fi

    log_line ""
    if [ "$MODE" = dry-run ]; then
        log_line "DRY-RUN — nothing removed. Re-run with --apply to remove the 'remove' rows."
    else
        log_line "armed pass complete: REMOVED=$REMOVED FAILED=$FAILED"
    fi
    summary_line
    print_footer "$(now_epoch)"
    # 4 is not a failure of the PASS — it is the machine-readable form of the
    # `FAILED=` footer, so a cron/launchd wrapper cannot read a refused removal
    # as a clean run (the "false PASS" failure mode). Deferrals stay 0: they are
    # the budget working, and the next pass re-classifies them.
    [ "$FAILED" -gt 0 ] && exit 4
    exit 0
}

parse_args "$@"
run
