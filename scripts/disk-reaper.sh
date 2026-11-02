#!/usr/bin/env bash
# disk-reaper.sh — ONE entry point for the three disk sinks that stop a cell (agent-infra#2032).
#
# WHY THIS EXISTS (the measured defect)
# Disk exhaustion is the SECOND reason the cloud cells stopped working, and it fails in the most
# misleading way available: the controller keeps beating, the queue reads fine, and every dispatch is
# refused, because at ~97% used a `git worktree add` or a `uv sync` cannot write.
#   cell-3 1.7 GB free (95%) · cell-2 2.2 GB (97%) · lane-1 1.1 GB (97%) on 63 GB volumes
#   biggest single offender: a stale PR worktree, /tmp/wt-pr-8915 = 1.1 GB (its PR is MERGED)
#   /tmp/wt-pr-8839 = 291 MB (merged) · /tmp/cell-home = 524 MB
#   earlier on cell-3, ~/.cache/uv alone was 7.1 GB; clearing it freed 6-7 GB
#
# THE FLEET ALREADY HAD A POLICY OWNER FOR EACH CLASS — and no one thing that ran them. Four
# ad-hoc reaps existed: `cloud-cell-supervisor.sh prune`, the hourly cache pass inside
# `orch-loop.sh`, `pi-reap-worktrees-launchd.py`, and `cleanup-worktree.sh` at merge time. This
# script is the CONSOLIDATION, not a fourth policy: it OWNS NO DELETION RULE of its own. It
# resolves, schedules and accounts for the three owners:
#
#   class      owner (the single source of the delete rule)      what it reclaims
#   ---------  -------------------------------------------------  --------------------------------
#   uv         scripts/pi-cache-reap.sh       (#1987)             machine-global uv/npm/pip caches,
#                                                                 bounded BY SIZE (default 2048 MB
#                                                                 per cache), prune-then-escalate
#   venv       scripts/reap-lane-venvs.sh     (#1932 / PR #1949)  per-worktree `.venv`s whose lane
#                                                                 is gone, proven by three liveness
#                                                                 witnesses; fail-closed
#   worktree   scripts/pi-reap-worktrees.sh   (#1095)             clean, reachable, holder-free,
#              + scripts/reap-abandoned-worktrees.sh (#2542)       un-open-PR checkouts; merged heads
#                                                                 are exempt from the 7-day floor.
#                                                                 The SECOND arm covers what that
#                                                                 policy cannot reach: abandoned
#                                                                 LINKED worktree dirs under a scratch
#                                                                 root (age > 180 min AND no live
#                                                                 process's cwd/exe inside)
#   duplicate-install  scripts/reap-duplicate-installs.sh (#2542)  surplus copies of the same tool
#                                                                 install (a runner family), removing
#                                                                 only copies PROVEN idle, always
#                                                                 keeping the newest, never the last
#   runner-work scripts/reap-runner-work.sh   (this change)        the CI runners' `_work` checkout
#                                                                 dirs (19 G measured on one cell at
#                                                                 98%): an entry is removed ONLY when
#                                                                 its newest CONTENT is older than the
#                                                                 mtime floor, and `_work/_tool` /
#                                                                 `_work/_actions` are retained
#
# ⛔ IT NEVER DELETES A SINK ITSELF. The only recursive delete in this file is its OWN lock dir — by the
# pass that acquired it, or a lock whose recorded owner is provably GONE and which is older than the
# staleness bound (the stale reclaim; it is never a sink) — there is no `rm` of a worktree, venv or
# cache path, and that is
# the point: a fourth copy of the policy is exactly how a live lane loses its env to a sweep whose
# author only read one of the other three. If a delegate is missing, the class is FAIL-CLOSED (exit
# 3, named loudly) — never silently skipped, because a reaper that quietly does nothing reads exactly
# like a healthy box.
#
# BYTES — TWO NUMBERS, BECAUSE ONE ALONE IS A LIE (the accounting half of #1932/#1987)
#   * dry-run: per-candidate `du` (BLOCKS OCCUPIED) for what WOULD go. `du` counts blocks shared
#     with the uv cache once per link, so it OVER-STATES what removal frees ONLY on a box that
#     shares them (hardlink OR clonefile — a PER-MACHINE property; #1851 falsified the universal
#     hardlink claim, and `scripts/worktree-disk-probe.sh` measures the box in front of you).
#     Every such line states that condition.
#   * apply: the `df` delta across the class — what the filesystem ACTUALLY got back. This is the
#     number the status line and the supervisor report; it is never derived from `du`.
# A `du` figure is never reported as freed bytes, and a `df` delta that is negative or zero is
# reported as 0 for the status line while the UNCLAMPED figure is printed beside it (`df_raw=…MB`).
#
# SCHEDULING (installed by the cell bring-up, see cloud-cell-bringup.sh check_disk_reaper)
#   templates/systemd/eldato-disk-reaper.{service,timer} — hourly, `--apply`, installed and enabled
#   by `cloud-cell-bringup.sh --check` on a systemd cell. Arming is an OWNER decision (#1678 is the
#   general rule: deletion tools ship dry-run and arming is a dated, reversible owner step). This
#   feature was explicitly instructed to run unattended, so the unit is armed and the arming is
#   recorded in the unit file itself, not implied by a default.
#
# STATUS — the supervisor's `status` verb reads this pass record (`--print-status` prints it):
#   $STATE_DIR/disk-reaper.status   key=value, written ATOMICALLY at the end of every pass
# It carries the mode, the exit code, per-class `df` bytes reclaimed, and the dry-run candidates, so
# "did the last run succeed and how much did it free" is answerable without reading a log.
#
# Usage:
#   disk-reaper.sh [--dry-run] [--apply] [--repo PATH]... [--only LIST]
#                  [--aged-days N] [--min-age S] [--print-status] [--help]
#
#   (no mode flag)   dry-run: report what WOULD be removed, with byte counts; remove NOTHING
#   --dry-run        explicit dry-run (wins over DISK_REAPER_DRY_RUN=0)
#   --apply          armed pass
#   --repo PATH      a repo whose worktrees the venv/worktree classes scan (repeatable)
#   --only LIST      comma list of uv,venv,worktree,duplicate-install,runner-work (default: all five)
#   --aged-days N    worktree age floor passed to the owner (default 7; merged heads exempt)
#   --min-age S      venv GC age floor passed to the owner (default 1800)
#   --print-status   print the last pass record and exit (0 ok, 3 failed/stale/never, 2 usage)
#   --help           this text (exit 0)
#
# Env seams:
#   DISK_REAPER_STATE_DIR      status/log dir            (default $HOME/.pi/agent/state)
#   DISK_REAPER_STATE_DIR_FALLBACKS  colon-separated dirs used IN ORDER when the state dir above
#                              cannot be written (a full disk). Default: $XDG_RUNTIME_DIR/pi-disk-reaper
#                              (when set) then <DISK_REAPER_TMPFS_ROOT>/pi-disk-reaper-<uid>. An EMPTY
#                              value disables the fallback and restores the hard refusal (#2443)
#   DISK_REAPER_TMPFS_ROOT     where the default fallback lives, AND the root of the ONE canonical
#                              pass lock (<root>/pi-disk-reaper/disk-reaper.lock) every pass derives
#                              (default /dev/shm). Pin it identically on every pass on a box — a pass
#                              with a different value cannot see the others' canonical lock (#2443)
#   DISK_REAPER_LOG            pass log                  (default $STATE_DIR/disk-reaper.log)
#   DISK_REAPER_REPOS          colon-separated repos when no --repo is given
#   DISK_REAPER_ONLY           classes (same as --only)
#   DISK_REAPER_DRY_RUN        0 supplies the default mode only (an explicit flag always wins)
#   DISK_REAPER_WT_AGED_DAYS   worktree floor            (default 7)
#   DISK_REAPER_VENV_MIN_AGE   venv floor in seconds     (default 1800)
#   DISK_REAPER_RUNNER_GLOBS   space-separated globs naming the CI runners' `_work` roots, handed to
#                              the runner-work owner (default: /opt/gh-runner*/_work,
#                              $HOME/actions-runner*/_work, /tmp/actions-runner*/_work). A SET-but-EMPTY
#                              value is a REFUSAL at startup, never "scan nothing": an emptied seam
#                              would otherwise report a measured zero for a sink nothing looked at
#   DISK_REAPER_RUNNER_MIN_AGE the runner-work mtime floor in seconds (default 3600): a `_work` entry
#                              whose NEWEST content is older than this is reapable
#   DISK_REAPER_CLASS_TIMEOUT  watchdog per class, secs  (default 1800)
#   DISK_REAPER_DU_TIMEOUT     watchdog per dry-run `du`, secs (default 120)
#   DISK_REAPER_STALE_SECONDS  a status older than this is STALE (default 7200)
#   CACHE_REAPER / VENV_REAPER / WORKTREE_REAPER  explicit delegate paths
#   BOUNDED_LIB                the bounded-execution helper (default: lib/bounded.sh beside this
#                              script, then $HOME/.pi/agent/scripts/lib/); a SET-but-missing value is
#                              a refusal at startup, never a silent different file (#2046)
#   TB_TIMEOUT_BIN             pin the watchdog binary (`timeout`/`gtimeout`); unusable => refusal
#   TB_TIMEOUT_FORCE_INTERNAL  1 = use the internal watchdog even where `timeout` exists
#
# BOUNDED EXECUTION (#2046). Every subprocess here runs under a wall-clock bound resolved ONCE by
# scripts/lib/bounded.sh: `timeout` -> `gtimeout` -> an internal background watchdog (same contract,
# 124 == timeout). macOS ships neither binary, so before #2046 every class failed closed with rc=3 and
# the pass completed anyway. The resolved mechanism is recorded in the pass record (`watchdog=`);
# when it is NOT GNU `timeout` the pass prints one line naming it, so the fallback is visible without
# changing the report on a host that has the real binary.
#
# Exit codes — TWO DIFFERENT OUTCOMES SHARE ONE NUMBER IN THE DELEGATES' OWN VOCABULARIES (#2036), so
# every delegate code enters this pass through `delegate_rc`, which maps it PER CLASS. The scheduled
# unit's SuccessExitStatus is written against this table:
#
#   0  pass completed, every class ok                                       unit GREEN
#   2  usage                                                                unit RED
#   3  fail-closed — the condition was NOT claimed clean: a delegate returned its own fail-closed 3
#      (a probe unavailable, a cache that could not be measured or verified, a log unwritable), a
#      delegate could not run as asked (rc 2 bad arguments, 124 its own timeout, 126/127 missing
#      binary), a class had NO repo to scan or its delegate is ABSENT (recorded as `misconfigured` +
#      `not-run`, never as a measured zero), the pass record could not be written, or a startup
#      refusal (the bounded-execution library is missing / a numeric seam is not a number).
#      ⛔ A DELEGATE'S 3 IS NOT GREEN. All three owners use 3 for "I could not do the work";
#      flattening it into the green arm made a permanently INERT reaper read as a succeeding hourly
#      job (measured: PS_BIN=/nonexistent → venv class exit 3 on a box that cannot prove any lane
#      dead) — the inert-enforcer shape this whole feature is for.
#   4  a class completed but at least one removal FAILED; also a lock directory that cannot be
#      created at all (a filesystem problem), and a pass whose record could not be written while its
#      verdict was a green one (with no record there is no alarm channel left).          unit RED
#   5  a class reported an OVER-BOUND condition: a cache over its bound in a dry run, or (in an APPLY
#      pass) the venv owner finishing BELOW its own free-disk floor — `reap-lane-venvs.sh` 5, #1949.
#      ⛔ IT IS KEPT, not discarded: `worst_rc` used to drop it and the venv class recorded
#      `rc=0 verdict=ok` for exactly that state — the #2156 false PASS. In APPLY mode it RANKS WITH A
#      FAIL-CLOSED CLASS (3), because the condition the floor exists to surface is still present and
#      nothing was reclaimed; in a dry run it is informative (and `ok=1`).                unit RED (apply)
#                                                                                        unit GREEN (dry)
#   6  a delegate DEFERRED the pass — it ran, declined to act, and claimed nothing: another pass holds
#      its lock (pi-cache-reap.sh 4), or a live `uv` holds the cache so evicting it would be
#      unprovable (pi-cache-reap.sh 7, #2036) — OR this pass itself did not run because another
#      disk-reaper holds THIS lock (benign and routine: a manual pass may outrun the hourly tick).
#      That is the routine state of a busy cell, so it must not paint the unit red — an alarm that
#      fires hourly on a healthy box is one nobody reads — while the RECORD still says
#      `ok=0 verdict_<class>=deferred`. The verdict channel is the record; the unit's colour is not.
#      ⛔ DEFERRED IS NOT FAIL-CLOSED. Only codes that mean "ran, declined, claimed nothing" may
#      become 6; anything that means "I could not do the work" stays 3 and stays red.
#
# Severity, worst wins: 3 > 4 > 6 > 5 > 0 — in `_rc_rank`, one place.
#
set -uo pipefail

SCRIPT_NAME="disk-reaper.sh"

STATE_DIR="${DISK_REAPER_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${DISK_REAPER_LOG:-$STATE_DIR/disk-reaper.log}"
STATUS="$STATE_DIR/disk-reaper.status"
LOCK_DIR="$STATE_DIR/disk-reaper.lock"
LOCK_STALE_SECONDS="${DISK_REAPER_LOCK_STALE_SECONDS:-1800}"

DRY_RUN="${DISK_REAPER_DRY_RUN:-1}"
ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree,duplicate-install,runner-work}"
ONLY_GIVEN=0      # 1 when --only was passed, so an EMPTY list is a refusal and not the default
WT_AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
VENV_MIN_AGE="${DISK_REAPER_VENV_MIN_AGE:-1800}"
# ── class=runner-work (the CI runners' `_work` sink) ─────────────────────────────────────────────
# ⛔ `-` NOT `:-`, AND SET-BUT-EMPTY IS A REFUSAL (see the startup check below). `${X:-default}` would
# substitute the DEFAULTS for an emptied seam, so an operator (or a rendered unit) that emptied the
# glob list to "turn the class off" would instead get the WIDEST possible sweep — the delete direction.
# This is the same rule BOUNDED_LIB gets: a set value is authoritative, and a wrong one is loud.
RUNNER_GLOBS="${DISK_REAPER_RUNNER_GLOBS-/opt/gh-runner*/_work $HOME/actions-runner*/_work /tmp/actions-runner*/_work}"
RUNNER_GLOBS_EXPLICIT=0
if [ -n "${DISK_REAPER_RUNNER_GLOBS+set}" ]; then RUNNER_GLOBS_EXPLICIT=1; fi
# The floor: a `_work` entry whose NEWEST CONTENT is older than this is reapable. 3600 s is ~2x the
# longest gap a writing job has been measured to leave, and the hand reap that validated the class on
# the 98%-full cell used 120 min. It is a SEAM because a box running long quiet steps needs a higher
# floor, and that is the intended response — never a process-check (see the owner's header).
RUNNER_MIN_AGE="${DISK_REAPER_RUNNER_MIN_AGE:-3600}"
CLASS_TIMEOUT="${DISK_REAPER_CLASS_TIMEOUT:-1800}"
DU_TIMEOUT="${DISK_REAPER_DU_TIMEOUT:-120}"
# One bound for the small non-delegate probes (git / ps). They are cheap; a hung mount is not.
GIT_TIMEOUT="${DISK_REAPER_GIT_TIMEOUT:-60}"
# One budget for the whole per-candidate sizing sweep (not per candidate): a pass over N checkouts
# must not be able to hold the lock for N x DU_TIMEOUT and age itself out of it.
DU_BUDGET="${DISK_REAPER_DU_BUDGET:-300}"
STALE_SECONDS="${DISK_REAPER_STALE_SECONDS:-7200}"
# ⛔ THE STALE THRESHOLD IS VALIDATED BEFORE ITS FIRST READER, not here — see the `--print-status` block
# below (a reader must never be the one place a seam is unvalidated), and the numeric-seam sweep after
# argv for every other value. Deliberately ONE check, one message.

DU_BIN="${DU_BIN:-du}"
DF_BIN="${DF_BIN:-df}"
PS_BIN="${PS_BIN:-/bin/ps}"

REPOS_ARG=""
REPOS=""
FREED_UV=0; FREED_VENV=0; FREED_WT=0
RAW_UV=0; RAW_VENV=0; RAW_WT=0
# 1 = `df` answered for that class. 0 = it could not, and NOTHING may then be reported as a measured 0.
DF_UV_OK=1; DF_VENV_OK=1; DF_WT_OK=1
WOULD_UV=0; WOULD_VENV=0; WOULD_WT=0
CAND_UV=0; CAND_VENV=0; CAND_WT=0
CLASSIFIED_VENV=0; PRESERVED_VENV=0
HAVE_WT_TALLY=0
HAVE_WT_CAND=0
DEFERRED_REMOVE_WT=0
HAVE_VENV_TALLY=0
HAVE_VENV_CAND=0
# 1 = every repo the venv class SCANNED answered its tally, so the summed counts are an answer for the
# CLASS. 0 = at least one repo did not, and the sum is only a lower bound (`?`, or the row count in a
# dry pass). Initialised here because the venv arm's fail-closed arms `return 3` BEFORE the loop — with
# `set -u`, an unset read there would abort the pass instead of recording the failure.
VENV_FULL_COVER=0
# ⛔ THE OTHER TWO CLASSES GET REAL SENTINELS TOO. `uv` and `duplicate-install` publish no tally of
# their own, and overloading the VERDICT for the purpose was wrong twice: `fail-closed` (the delegate
# RAN and could not measure) is not a measurement either, and an ARMED pass has no `DRY-RUN` rows to
# count for uv at all. So `HAVE_*_CAND` says "this pass MEASURED the count", set only where a
# measurement actually happened: uv's dry-run row scan, and dup's dry sweep or its owner's own
# `SUMMARY candidates=` (which the dup delegate prints in BOTH modes).
HAVE_UV_CAND=0
HAVE_DUP_CAND=0
VENV_TALLY_COVER=0/0
WT_TALLY_COVER=0/0
RC_UV=0; RC_VENV=0; RC_WT=0; RC_DUP=0
VERDICT_UV="not-run"; VERDICT_VENV="not-run"; VERDICT_WT="not-run"; VERDICT_DUP="not-run"
NOTE_UV=""; NOTE_VENV=""; NOTE_WT=""; NOTE_DUP=""
# ── class=duplicate-install (#2542): the second missing sink, measured at 11.3 GB on cell-1 ──────
# A whole class per sink is this file's existing idiom (see the three above): the record carries one
# key per class so an operator can answer "how much did THIS class free" without parsing a log. The
# record keys use `duplicate_install` (the class name is `duplicate-install`) because a `sed` key
# with a hyphen is a footgun for every reader that already does `s/^freed_mb_//p`.
FREED_DUP=0; RAW_DUP=0
DF_DUP_OK=1
WOULD_DUP=0; CAND_DUP=0
WANT_DUP=0
# ── class=runner-work (the CI runners' `_work` sink; record key `runner_work`) ───────────────────
# MEASURED (2026-10-28, cell c1 `vm-efa6cc8fdb974e61b5c054acf41d8846`, 8 cores, 12 runners): `/` at
# **98% used, 3.5 G free**, with **19 G** in `/opt/gh-runner-x64-{2,4,5,6,7,8}/_work` — checkout left
# by jobs that finished or were killed. A runner cleans its own `_work` only on a NORMAL job end, so a
# cancelled or OOM-killed job's tree stays for ever, and NO class matched it: not a cache (`uv`), not a
# lane env (`venv`), not a tracked checkout (`worktree`), not a duplicate install. The hand reap of that
# sink took the box 98% → 90% without disturbing a running job — that hand reap is the class's gate.
# The record keys use `runner_work` (the class name is `runner-work`) for the same reason
# `duplicate_install` does: a `sed` key with a hyphen is a footgun for every `s/^freed_mb_//p` reader.
FREED_RW=0; RAW_RW=0
DF_RW_OK=1
WOULD_RW=0; CAND_RW=0
WANT_RW=0
# 1 = this pass MEASURED the candidate count (a lifted, fully-answered SUMMARY). 0 = it did not, and the
# record must say `?` rather than the initialised 0 — the sentinel every other class already carries.
HAVE_RW_CAND=0
# The owner's `unmeasurable=` tally: entries it KEPT because the bounded walk could not ANSWER (a
# permission error, a vanished mount, a watchdog 124, or a TOCTOU re-probe that could not answer).
# ⛔ THIS IS THE CLASS'S ONLY "COULD NOT DECIDE" OUTCOME AND IT NEEDED ITS OWN CHANNEL. The entry point
# lifted seven SUMMARY fields and dropped this one, so in the record a pass that read "nothing wrote here
# for an hour" (proof of death, reaped) and one that read "I could not read it at all" (kept, fail-closed)
# were the same number — `kept=`/`failed=` alone cannot tell a decision from an abstention, which is the
# distinction the whole class rests on. `?` until a fully-answered SUMMARY lifts a numeric value, the
# same sentinel `HAVE_RW_CAND` carries (an initialised 0 is never published as a measurement).
RW_UNMEAS='?'
RC_RW=0
VERDICT_RW="not-run"
NOTE_RW=""
# The worktree class's SECOND arm (abandoned scratch worktrees). It reports into the worktree class's
# own keys — it is the same sink — and these are its accumulators.
AW_FREED=0; AW_RAW=0; AW_MEASURED=1; AW_OUT=""; AW_NOTE=""
# Repos whose PR-state gate could not be verified, and the reason, as `<repo>[<reason>]` — one entry
# each. A SKIPPED repo is not a failed CLASS: its own checkouts are untouched (fail closed) while the
# other repos in the same class are still reclaimed. Reported per repo so a single unverifiable repo
# cannot hide what the pass did do, and cannot disable the repos it could not reach (#2443).
SKIPPED_WT=""; SKIPPED_WT_N=0
# Set when a class could not be set up AT ALL (delegate absent, no repo to scan). That is one of the
# things exit 3 means; a delegate that RAN and DEFERRED is 6, and one that ran and failed closed is
# also 3 but with a per-class verdict, not `misconfigured`. Keeping the two apart is the whole point
# of #2036 — see the exit-code table above.
MISCONFIG=""

log_line() { printf '%s\n' "$*"; }
log() { printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }

# seam_too_large <value> — true when a (already all-digits) seam is too large for `[ ... ]` to compare.
# ⛔ "ALL DIGITS" IS NOT A VALIDATED SEAM (#2173 review; the same residual #2158 closed in
# reap-lane-venvs.sh). `[ -lt ]`/`[ -gt ]` parse with strtoimax, so a value above intmax_t makes the
# COMPARISON ITSELF error; with `set -u` and no `-e` the `if` then takes the ELSE arm. Measured:
#   age=999999; S=99999999999999999999
#   bash: [: 99999999999999999999: integer expression expected  ->  NOT-STALE
# So a digit-only out-of-range DISK_REAPER_STALE_SECONDS reported an arbitrarily old record as
# `status=ok` and --print-status exited 0 — and every reader that gates on that rc went green:
# cloud-cell-supervisor.sh `status` prints its healthy line, install-disk-reaper-timer.sh --status
# allow-lists 0/5/6 and certifies CELL READY, fleet-health reports no alarm. The digited-only check is
# therefore bounded by MAGNITUDE too.
# Leading zeros are harmless to `[` (base 10), so they are stripped before the length test rather than
# refused. Nine significant digits is ~31 years of seconds (and 999,999,999 days or MB): no real seam
# can exceed it, and anything above it cannot be compared at all.
seam_too_large() {
    local _n="${1#"${1%%[!0]*}"}"
    [ -n "$_n" ] || _n=0
    [ "${#_n}" -gt 9 ]
}


usage() {
    # ⛔ `$0` IS NOT THIS SCRIPT under a piped start. The macOS agent runs the pass as
    # `/bin/bash -s -- …` (pi-reap-worktrees-launchd.py execs exactly that argv), so `$0` is the bash
    # BINARY's path and `${BASH_SOURCE[0]}` is empty: awk on `$0` would print a shell's header, not this
    # one. Fall back to a synopsis that names the real doc.
    if [ -r "${BASH_SOURCE[0]:-}" ]; then
        awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    else
        printf '%s\n' "usage: $SCRIPT_NAME [--dry-run|--apply] [--repo PATH]... [--only uv,venv,worktree]"
        printf '%s\n' "                        [--aged-days N] [--min-age S] [--print-status] [--help]"
        printf '%s\n' "       full documentation: docs/ops/disk-reaper.md (this start has no script path to read the header from)"
    fi
    exit 0
}

# ── argv ─────────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --apply)    DRY_RUN=0; shift ;;
        --repo)     [ $# -ge 2 ] || die "--repo needs a path"; REPOS_ARG="${REPOS_ARG}${REPOS_ARG:+
}$2"; shift 2 ;;
        --only)     [ $# -ge 2 ] || die "--only needs a list"; ONLY="$2"; ONLY_GIVEN=1; shift 2 ;;
        --aged-days)
            [ $# -ge 2 ] || die "--aged-days needs a number"
            case "$2" in ''|*[!0-9]*) die "--aged-days must be a number (got '$2')" ;; esac
            WT_AGED_DAYS="$2"; shift 2 ;;
        --min-age)
            [ $# -ge 2 ] || die "--min-age needs a number"
            case "$2" in ''|*[!0-9]*) die "--min-age must be a number (got '$2')" ;; esac
            VENV_MIN_AGE="$2"; shift 2 ;;
        --print-status) PRINT_STATUS=1; shift ;;
        --help|-h)  usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# A class list that names nothing would run nothing and report a healthy box (a false PASS): a typo
# silently drops a sink, and an empty list means "reap nothing, forever" while the timer says ok.
# ⛔ VALIDATE UNCONDITIONALLY. The guard used to be `if [ -n "$ONLY" ]`, so `--only ""` skipped it
# entirely: ZERO classes ran and the pass exited 0 with `ok=1 classes=`. (Only the ARGV form can be
# empty: `ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree,duplicate-install,runner-work}"` substitutes the default for an empty env value.)
if [ -z "$ONLY" ]; then die "--only was given an empty list (valid: uv, venv, worktree, duplicate-install, runner-work)"; fi
ONLY_CLASSES=""
for c in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case "$c" in
        uv|venv|worktree|duplicate-install|runner-work) ;;
        *) die "unknown --only class '$c' (valid: uv, venv, worktree, duplicate-install, runner-work)" ;;
    esac
    ONLY_CLASSES="${ONLY_CLASSES}${ONLY_CLASSES:+,}$c"
done
[ -n "$ONLY_CLASSES" ] || die "--only was given an empty list (valid: uv, venv, worktree, duplicate-install, runner-work)"
ONLY="$ONLY_CLASSES"
# A class the operator did not select did not run: its reclaim is NOT a measured zero, and the record
# must not present it as one (the supervisor renders these per-class values verbatim).
WANT_UV=0; WANT_VENV=0; WANT_WT=0

# ── status record ────────────────────────────────────────────────────────────────────────────────
# One key per line, so the supervisor can read it with `sed -n 's/^k=//p'` and no jq. Written to a
# temp file and renamed: a reader never sees a half-written record (the supervisor prints this while
# a timer may be running).
status_field() { [ -f "$STATUS" ] || return 0; sed -n "s/^$1=//p" "$STATUS" | head -1; }

# _tally_num <have_tally> <value> — a count, or `?` when the class ran but produced NO tally.
# ⛔ `${sum_classified:-?}` CANNOT SAY THIS: the counters are initialised to 0, so the `:-` never fires
# and an unanswerable pass is recorded as a measured zero — the exact false PASS the tally exists to
# remove, one layer up. `?` is the class line's vocabulary for it; the record says `not-run` when the
# class was not selected at all (see `_tally_rec`).
_tally_num() { [ "${1:-0}" = 1 ] && printf '%s' "$2" || printf '?'; }

# _tally_rec <want> <have_tally> <value> — the pass-record form: `not-run` (class not selected),
# `?` (selected, no tally) or the value. One vocabulary per surface, and never an invented 0.
_tally_rec() {
    [ "${1:-0}" = 1 ] || { printf 'not-run'; return 0; }
    [ "${2:-0}" = 1 ] || { printf '?'; return 0; }
    [ -n "$3" ] && printf '%s' "$3" || printf '?'
}

# _class_rec <verdict> <want> <have> <value> — the pass-record form for a class that publishes no
# TALLY of its own (`uv`, `duplicate-install`). Four states, and the ORDER is the whole point:
#
#     misconfigured -> `?`         (selected, could not be SET UP: NOTHING was measured)
#     not-run      -> `not-run`    (the class was not selected: nothing to measure)
#     want != 1    -> `not-run`    (deselected by a setup-failure arm that also resets WANT_*)
#     have != 1    -> `?`          (selected, but THIS PASS measured no count: a refusal, or an armed
#                                   pass with no tally to lift — a `0` here is an INVENTED zero)
#     otherwise    -> the value, or `?` if it is empty
#
# ⛔ `misconfigured` is tested FIRST because those arms also reset `WANT_*` to 0, and asking `want`
# first would report `not-run` for a class that WAS selected and failed to run — erasing the
# distinction #2036 exists to keep.
# ⛔ `have` is NOT redundant with the verdict: `fail-closed` means the delegate RAN and could not do the
# work, which is also not a measurement, and an armed uv pass has no rows to count at all. Overloading
# the verdict for this (the first cut of this fix) left `candidates_uv=0` beside `verdict_uv=fail-closed`,
# and recorded `0` on every armed pass — the same invented zero, one state over.
# ⛔ A class that DOES publish a tally keeps `_tally_rec`: that is the stronger evidence, and a second
# definition of "measured" is how the two surfaces drift apart again.
_class_rec() {
    case "${1:-not-run}" in
        misconfigured) printf '?'; return 0 ;;
        not-run)       printf 'not-run'; return 0 ;;
    esac
    [ "${2:-0}" = 1 ] || { printf 'not-run'; return 0; }
    [ "${3:-0}" = 1 ] || { printf '?'; return 0; }
    [ -n "$4" ] && printf '%s' "$4" || printf '?'
}

# kv_field <line> <key> — one `k=v` token out of a delegate's machine-readable line.
# The delegate's `SUMMARY` is the ONLY tally a pass produces; the entry point lifts it instead of
# re-deriving it, because a second implementation of "how many were preserved" is a second answer.
kv_field() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# _dclass <verdict> -> `B` (an ordinary reading of a pass, or an abstention) | `A` (the ALARM class).
# ⛔ The BENIGN side is an ALLOW-LIST, so a verdict the reaper gains later and this reader was never
# taught classifies as an ALARM and is PRINTED. An unrecognised spelling must never become silence —
# that is the whole fail-loud property the `⛔ worktree-delegate=` line depends on (#3058 review, P1).
_dclass() {
    case "${1:-}" in
        ''|ok|'?'|not-run|dry-run|reclaimed|idle|mixed-benign) printf 'B' ;;
        *) printf 'A' ;;
    esac
}

print_status() {
    local epoch mode ok rc freed iso age status
    if [ ! -f "$STATUS" ]; then
        log_line "status=never"
        log_line "detail=no pass has been recorded at $STATUS"
        return 3
    fi
    epoch="$(status_field epoch)"; mode="$(status_field mode)"; ok="$(status_field ok)"
    rc="$(status_field rc)"; freed="$(status_field freed_mb)"
    iso="$(status_field iso)"
    # ⛔ AN UNUSABLE EPOCH IS STALE, NOT OK. `age=-1` failed `[ "$age" -ge 0 ]` and fell through to
    # `status=ok`, so a record with no readable timestamp read healthy — while fleet-health called the
    # same record an alarm. One record, one verdict: cannot-age is cannot-prove-liveness.
    # ⛔ AND AGE IS DECIDED FIRST, BEFORE `ok`. Computed only inside the ok=1 branch, an ok=0 record three
    # weeks old was reported `failed` with its old rc — and the readiness gate that allow-lists rc 5/6
    # then passed it, so a box certified CELL READY with no completed pass for weeks. fleet-health
    # already computes staleness first and calls the same bytes STALE; the two readers must agree.
    case "$epoch" in ''|*[!0-9]*) age=-1 ;; *) age=$(( $(date +%s) - epoch )) ;; esac
    if [ "$age" -lt 0 ] || [ "$age" -gt "$STALE_SECONDS" ]; then
        status=stale
    elif [ "$ok" = "1" ]; then
        status=ok
    else
        status=failed
    fi
    log_line "status=$status"
    log_line "epoch=$epoch"
    log_line "iso=$iso"
    log_line "age_seconds=$age"
    log_line "mode=$mode"
    log_line "watchdog=$(status_field watchdog)"
    log_line "rc=$rc"
    log_line "freed_mb=$freed"
    log_line "freed_mb_uv=$(status_field freed_mb_uv)"
    log_line "freed_mb_venv=$(status_field freed_mb_venv)"
    log_line "freed_mb_worktree=$(status_field freed_mb_worktree)"
    log_line "freed_mb_duplicate_install=$(status_field freed_mb_duplicate_install)"
    log_line "freed_mb_runner_work=$(status_field freed_mb_runner_work)"
    log_line "freed_mb_unmeasured=$(status_field freed_mb_unmeasured)"
    log_line "would_free_mb_uv=$(status_field would_free_mb_uv)"
    log_line "would_free_mb_venv=$(status_field would_free_mb_venv)"
    log_line "would_free_mb_worktree=$(status_field would_free_mb_worktree)"
    log_line "would_free_mb_duplicate_install=$(status_field would_free_mb_duplicate_install)"
    log_line "would_free_mb_runner_work=$(status_field would_free_mb_runner_work)"
    log_line "candidates_uv=$(status_field candidates_uv)"
    log_line "candidates_venv=$(status_field candidates_venv)"
    log_line "candidates_worktree=$(status_field candidates_worktree)"
    log_line "classified_venv=$(status_field classified_venv)"
    log_line "preserved_venv=$(status_field preserved_venv)"
    log_line "classified_worktree=$(status_field classified_worktree)"
    log_line "preserved_worktree=$(status_field preserved_worktree)"
    log_line "preserved_reasons_worktree=$(status_field preserved_reasons_worktree)"
    log_line "main_proof=$(status_field main_proof)"
    log_line "pr_merged=$(status_field pr_merged)"
    log_line "candidates_duplicate_install=$(status_field candidates_duplicate_install)"
    log_line "candidates_runner_work=$(status_field candidates_runner_work)"
    log_line "cand_runner_work=$(status_field cand_runner_work)"
    log_line "note_runner_work=$(status_field note_runner_work)"
    # ⛔ A FIELD THE READER DOES NOT PRINT DOES NOT EXIST (the rule this block already carries for
    # `skipped_worktree=`): `unmeasurable_runner_work=` is written every pass, so it must be readable
    # without opening the record file — it is the only surface that distinguishes "nothing was written
    # for an hour" (reaped) from "the walk could not answer" (kept).
    log_line "unmeasurable_runner_work=$(status_field unmeasurable_runner_work)"
    log_line "verdict_uv=$(status_field verdict_uv)"
    log_line "verdict_venv=$(status_field verdict_venv)"
    log_line "verdict_worktree=$(status_field verdict_worktree)"
    log_line "verdict_runner_work=$(status_field verdict_runner_work)"
    # ⛔ AND THE DELEGATE'S OWN VERDICT (#3041), on the same rule: `verdict_worktree=` above is the
    # EXIT-CODE reading, and an ineffective reap exits 0 by design — so a reader that saw only that
    # field reported `worktree=ok` for a pass that reclaimed nothing on a full box. Written every pass,
    # so it must be printable, or it does not exist (the rule two paragraphs down).
    log_line "delegate_verdict_worktree=$(status_field delegate_verdict_worktree)"
    # ⛔ A FIELD THE READER DOES NOT PRINT DOES NOT EXIST. `skipped_worktree=` is the whole point of
    # #2443 (WHICH repo was skipped and WHY); leaving it out of `--print-status` would repeat the
    # `classes=`/`repos=` defect this block already documents — written every pass, read by nobody.
    log_line "skipped_worktree=$(status_field skipped_worktree)"
    # `classes=` and `repos=` were WRITTEN every pass and read by nobody, so "which sinks and which
    # checkouts did the last pass actually cover" — the first question after a bring-up changes
    # DISK_REAPER_REPOS — had no answer on any surface. The record is this feature's verdict channel,
    # so everything in it must be reachable from the reader.
    log_line "classes=$(status_field classes)"
    log_line "repos=$(status_field repos)"
    log_line "detail=$(status_field detail)"
    # Exit vocabulary matches the pass: 0 ok, 3 failed/stale/never. A `[ ... ]` here would return 1,
    # which no caller's case arm handles and which reads as "usage error" to a human.
    case "$status" in ok) return 0 ;; *) return 3 ;; esac
}

# ⛔ STALE_SECONDS IS VALIDATED *BEFORE* --print-status, because that is a READER of it. Validated with
# the other seams further down (after the early exit), a non-numeric value made `[ "$age" -gt "$30m" ]`
# error and — no `set -e` — the ELSE arm set status=ok, so --print-status answered 0 for a 56-year-old
# record while cloud-cell-supervisor gates its ⛔ line on that rc. A reader must never be the one place
# a seam is unvalidated.
case "$STALE_SECONDS" in
    ''|*[!0-9]*)
        printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_STALE_SECONDS must be a whole number (got %s).\n' \
            "$SCRIPT_NAME" "'$STALE_SECONDS'" >&2
        exit 3 ;;
esac
# … and BOUNDED, not merely digit-only: a value above intmax_t makes `[ "$age" -gt "$STALE_SECONDS" ]`
# error and the ELSE arm answer `status=ok` (see seam_too_large). The reader must not be the one place
# this is unchecked, so the bound is applied HERE, beside the digits check above.
if seam_too_large "$STALE_SECONDS"; then
    printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_STALE_SECONDS=%s is out of range: at most 9 digits (~31 years) can be compared, and a bound the shell cannot compare is not a bound.\n' \
        "$SCRIPT_NAME" "'$STALE_SECONDS'" >&2
    exit 3
fi

if [ "${PRINT_STATUS:-0}" = "1" ]; then
    print_status
    exit $?
fi

# ── config validation — AFTER argv, so a valid flag can override a stale env ────────────────────
# ⛔ THIS RUNS AFTER ARGV AND AFTER --print-status, on purpose. Validated where the value was first
# read, it also blocked invocations that never use it: `DISK_REAPER_VENV_MIN_AGE=30m … --print-status`
# refused to print the record, and `… --min-age 1800` refused a VALID argv. A unit file is the most
# likely place the typo lands, so the check is still a refusal (exit 3, misconfigured — a startup
# condition, not a usage error) when a bad env is actually going to be USED.
case "$VENV_MIN_AGE" in
    ''|*[!0-9]*)
        printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_VENV_MIN_AGE must be a whole number of seconds (got %s).\n' "$SCRIPT_NAME" "'$VENV_MIN_AGE'" >&2
        printf '%s: refusing rather than running on a different age floor than the one written in the unit; pass --min-age to override\n' "$SCRIPT_NAME" >&2
        exit 3 ;;
esac
if seam_too_large "$VENV_MIN_AGE"; then
    printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_VENV_MIN_AGE=%s is out of range: at most 9 digits (~31 years) can be compared, and a floor the shell cannot compare is not a floor.\n' \
        "$SCRIPT_NAME" "'$VENV_MIN_AGE'" >&2
    exit 3
fi
# ⛔ A SET-BUT-EMPTY GLOB LIST IS A REFUSAL, NOT "SCAN NOTHING" — and it is checked here, beside the
# other seam checks, for the reason `BOUNDED_LIB` gives: an emptied value must never silently become a
# DIFFERENT value (here, the widest default sweep, which deletes). The owner applies the same rule to
# REAP_RW_GLOBS it is handed, so neither side can be emptied into a silent behaviour change.
case "$RUNNER_GLOBS" in *[![:space:]]*) : ;; *)
    printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_RUNNER_GLOBS is EMPTY.\n' "$SCRIPT_NAME" >&2
    printf '%s: an empty glob list would scan no runner `_work` root and report a measured zero for ever; unset it to take the defaults, or name the roots.\n' "$SCRIPT_NAME" >&2
    exit 3 ;;
esac
# ⛔ THE ARMING SEAM IS NOT A BOOLEAN BY FAITH. `is_dry` tests for exactly "1", so DISK_REAPER_DRY_RUN=true
# (or yes/01/a typo) used to run the pass ARMED — a deleted-file direction, one export away. Refuse a
# value that is neither 0 nor 1; the explicit flags still win and always set a valid one here.
case "$DRY_RUN" in
    0|1) ;;
    *) die "DISK_REAPER_DRY_RUN must be 0 or 1 (got '$DRY_RUN')" ;;
esac
# ⛔ EVERY NUMERIC SEAM THIS SCRIPT COMPARES IS VALIDATED HERE. `[ "$age" -gt "$STALE_SECONDS" ]`
# errors on a non-numeric value and, under `set -u` without `-e`, the error status makes the `else`
# arm run — so `DISK_REAPER_STALE_SECONDS=30m` made a 56-year-old record print `status=ok`, exit 0,
# and the supervisor (which gates its ⛔ line on that rc) read a dead reaper as healthy. Same shape the
# venv floor had (#2158), same answer: refuse at startup (3) rather than compare against a number that
# is not one.
# ⛔ AND EACH IS BOUNDED, not merely digit-checked — see `seam_too_large`: a digit string above intmax_t
# passes the case below and then makes the comparison itself error, which is the SAME fail-open one
# size class up (measured on `DISK_REAPER_STALE_SECONDS=99999999999999999999`).
for _seam in "DISK_REAPER_WT_AGED_DAYS=$WT_AGED_DAYS" \
             "DISK_REAPER_LOCK_STALE_SECONDS=$LOCK_STALE_SECONDS" \
             "DISK_REAPER_CLASS_TIMEOUT=$CLASS_TIMEOUT" \
             "DISK_REAPER_DU_TIMEOUT=$DU_TIMEOUT" \
             "DISK_REAPER_DU_BUDGET=$DU_BUDGET" \
             "DISK_REAPER_RUNNER_MIN_AGE=$RUNNER_MIN_AGE" \
             "DISK_REAPER_GIT_TIMEOUT=$GIT_TIMEOUT"; do
    case "${_seam#*=}" in
        ''|*[!0-9]*)
            printf '%s: ⛔ FAIL-CLOSED at startup — %s must be a whole number (got %s).\n' \
                "$SCRIPT_NAME" "${_seam%%=*}" "'${_seam#*=}'" >&2
            exit 3 ;;
    esac
    if seam_too_large "${_seam#*=}"; then
        printf '%s: ⛔ FAIL-CLOSED at startup — %s='%s' is out of range: at most 9 digits can be compared, and a bound the shell cannot compare is not a bound.\n' \
            "$SCRIPT_NAME" "${_seam%%=*}" "${_seam#*=}" >&2
        exit 3
    fi
done

# ── bounded execution — the macOS half of this script (#2046) ───────────────────────────────────
# `timeout` is GNU coreutils and macOS ships it NOWHERE (`gtimeout` only with Homebrew coreutils), so
# every call site below used to fail with `timeout: command not found` (rc=127 -> fail-closed, rc=3)
# while the pass completed and printed `verdict=fail-closed` per class — a false PASS that removed
# nothing. The resolver lives in ONE place (scripts/lib/bounded.sh: `timeout` -> `gtimeout` -> an
# internal background watchdog with the same status contract, 124 == timeout) and is shared with
# `pi-reap-worktrees.sh`, which already carried that watchdog as `run_bounded`. A missing library is a
# REFUSAL AT STARTUP, never a pass whose classes all quietly fail closed.
# ⛔ `${BASH_SOURCE[0]:-}` IS LOAD-BEARING, NOT DEFENSIVE TIDINESS. The macOS LaunchAgent starts this
# script through pi-reap-worktrees-launchd.py, which pipes it into `bash -s` (TCC: a launchd-spawned
# bash cannot read the file itself). Under `bash -s` there is NO BASH_SOURCE[0], and with `set -u` a
# bare reference aborts the substitution, leaving SELF_DIR empty — so the beside-script arm searched
# `/lib/bounded.sh`, the pass refused at startup, and the installed hourly job would have been inert
# on the very platform the installer was just extended to schedule. Measured: rc=3 every pass, with
# `BASH_SOURCE[0]: unbound variable` on stderr.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
fi
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for cand in "$SELF_DIR/lib/bounded.sh" \
                "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { BOUNDED_LIB="$cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED at startup — the bounded-execution library is missing (%s).\n' \
        "$SCRIPT_NAME" "${BOUNDED_LIB:-not beside this script ($SELF_DIR/lib/) and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    printf '%s: refusing to start, because without it every class reports verdict=fail-closed and the pass completes looking like a run (#2046)\n' "$SCRIPT_NAME" >&2
    printf '%s: an installer/unit must pin it: BOUNDED_LIB=<reaper dir>/lib/bounded.sh — a start that cannot derive its own path (a piped `bash -s` launch) has no other way to find it\n' "$SCRIPT_NAME" >&2
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
# ⛔ THE EXIT TRAP IS INSTALLED BEFORE ANY SCRATCH EXISTS. It used to be installed ~190 lines later, so
# the two STARTUP REFUSALS below (an unusable TB_TIMEOUT_BIN, an uncreatable state dir) exited without
# removing the probe scratch — one leaked `bounded.*` directory per refused start, hourly on a
# misconfigured unit. `release_lock` is a no-op until the lock is held (LOCK_HELD defaults to 0).
LOCK_HELD=0
bound_cleanup_early() {
    command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
}
trap bound_cleanup_early EXIT
# ⛔ CREATE THE PROBE SCRATCH IN THE PARENT, BEFORE ANY PROBE RUNS. `tb_timeout` is called inside
# command substitutions — i.e. SUBSHELLS — so a lazily-created `TB_BOUND_TMP` was created in the CHILD
# and the parent's EXIT trap then had nothing to remove: one `bounded.*` directory per pass leaked on
# every host with no GNU `timeout` (macOS). A subshell inherits the parent's variable, so creating it
# here means every probe reuses THIS directory and `tb_bound_cleanup` can actually reap it.
tb_bound_tmp || printf '%s: warn: no writable TMPDIR — bounded probes will run without a scratch dir\n' "$SCRIPT_NAME" >&2
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    printf '%s: ⛔ FAIL-CLOSED at startup — TB_TIMEOUT_BIN=%s cannot be executed.\n' "$SCRIPT_NAME" "${TB_TIMEOUT_BIN:-}" >&2
    printf '%s: refusing instead of falling back, because a pinned watchdog that is silently ignored is the defect this refusal exists to prevent\n' "$SCRIPT_NAME" >&2
    exit 3
fi

# ── delegate resolution ──────────────────────────────────────────────────────────────────────────
# The SAME chain every other caller uses (${X:-} -> the FARMED copy -> the copy beside this script),
# so a reaper that is farmed and one that is run from a checkout are the same file, and one override
# cannot be honoured by the timer and ignored by the operator.
find_delegate() { # find_delegate <env-value> <basename>
    local cand
    # ⛔ AN EXPLICIT OVERRIDE IS AUTHORITATIVE, INCLUDING WHEN IT IS WRONG. A `${X}` that names a
    # missing file falls through to the farm/beside-script copy in the other callers, which means an
    # operator who pinned a path is silently running a DIFFERENT file — and the class then reports
    # healthy. Here a set-but-missing override is a fail-closed answer, named with the path tried.
    if [ -n "$1" ]; then
        [ -f "$1" ] && { printf '%s' "$1"; return 0; }
        return 1
    fi
    for cand in "${HOME:-}/.pi/agent/scripts/$2" \
                "${SELF_DIR:+$SELF_DIR/}$2"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

CACHE_REAPER_PATH=""; VENV_REAPER_PATH=""; WORKTREE_REAPER_PATH=""; ABANDONED_WT_REAPER_PATH=""; DUP_INSTALL_REAPER_PATH=""; RUNNER_WORK_REAPER_PATH=""
CACHE_REAPER_PATH="$(find_delegate "${CACHE_REAPER:-}" pi-cache-reap.sh)" || CACHE_REAPER_PATH=""
VENV_REAPER_PATH="$(find_delegate "${VENV_REAPER:-}" reap-lane-venvs.sh)" || VENV_REAPER_PATH=""
WORKTREE_REAPER_PATH="$(find_delegate "${WORKTREE_REAPER:-}" pi-reap-worktrees.sh)" || WORKTREE_REAPER_PATH=""
ABANDONED_WT_REAPER_PATH="$(find_delegate "${ABANDONED_WT_REAPER:-}" reap-abandoned-worktrees.sh)" || ABANDONED_WT_REAPER_PATH=""
DUP_INSTALL_REAPER_PATH="$(find_delegate "${DUP_INSTALL_REAPER:-}" reap-duplicate-installs.sh)" || DUP_INSTALL_REAPER_PATH=""
RUNNER_WORK_REAPER_PATH="$(find_delegate "${RUNNER_WORK_REAPER:-}" reap-runner-work.sh)" || RUNNER_WORK_REAPER_PATH=""
# ── bounded probes ──────────────────────────────────────────────────────────────────────────────
# Every subprocess that reads the filesystem runs under a watchdog: a reaper that HANGS the cell is
# worse than the disk it was reclaiming. `du` is charged to the class watchdog, and a timeout is a
# FAILURE of the class (never a silent 0). `tb_timeout` is the ONE bounded-execution helper (#2046):
# `timeout` -> `gtimeout` -> the internal watchdog, so the bound exists on macOS too.
now() { date +%s; }

# free_kb <path> — filesystem free KiB, or empty when df cannot answer (never read as "enough").
# ⛔ BOUNDED. The doc (and this file's own claim) says every filesystem probe runs under a watchdog; `df`
# against a dead or degraded mount could hang the whole pass WHILE IT HOLDS THE LOCK — the "reaper that
# hangs the cell" the bound exists to prevent.
free_kb() { tb_timeout "$DU_TIMEOUT" "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

# free_kb_for_path <path> — walk up to the nearest existing ancestor, so measuring a sink that is
# about to be created/reaped still names the filesystem it lives on.
free_kb_for_path() {
    local p="$1" i
    for i in 1 2 3 4 5 6 7 8; do
        [ -e "$p" ] && { free_kb "$p"; return; }
        [ "$p" = "/" ] && break
        p="$(dirname "$p")"
    done
    free_kb "/"
}

# file_mtime <path> — epoch mtime, portable across GNU and BSD stat. Empty when unstatable.
# ⛔ THE TARGET DECIDES THE FLAVOUR, NOT `$0`. The old probe was `stat -f '%m' "$0"`: it used `$0` only
# to pick the FLAVOUR and took the VALUE from the target, so on this host it happened to work — but the
# flavour then depends on the interpreter's path existing. Under the macOS agent's `/bin/bash -s -- …`
# start `$0` IS /bin/bash (the launcher execs that argv), so it resolved; a start where `$0` does not
# exist (a piped `sh -s`, a deleted interpreter path) takes BSD's `stat -c`, which BSD rejects, and the
# mtime comes back EMPTY — `age` then pins at 0 and the stale-lock reclaim never fires. (Under review
# cycle 6 this was relabelled: the defect is a latent fail-open, not the over-firing earlier prose
# claimed.) Probing the file we care about removes the dependency entirely.
file_mtime() {
    local m
    m="$(tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" stat -f '%m' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" stat -c '%Y' "$1" 2>/dev/null
}

# ⛔ BOUNDED EXECUTION HAS EXACTLY ONE IMPLEMENTATION (#2046) and it is NOT here. `scripts/lib/
# bounded.sh` resolves `timeout` -> `gtimeout` -> an internal watchdog, honours the operator's
# `TB_TIMEOUT_BIN` pin (refusing when it is unusable), and records the resolved mechanism as
# `TB_TIMEOUT_KIND` so the pass can DISCLOSE it (`watchdog=` in the pass record).
# A second resolver used to sit in this exact spot — the macOS-`timeout` fix written before the
# shared library existed. It is deleted rather than kept: it had no call sites (every probe here goes
# through `tb_timeout`), it ignored the `TB_TIMEOUT_BIN` pin, and it would have made `watchdog=` name
# a mechanism that did not bound the pass. Two copies of a resolver is how they drift; the library's
# own header says so. If a call shape is missing, add it to the LIBRARY, never to the caller.

du_mb() {
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" "$DU_BIN" -sk "$1" 2>/dev/null)" || return 1
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb / 1024 ))"
}

# run_class <cmd...> — run a delegate under the class watchdog, capture combined output.
# Sets CLASS_OUT / CLASS_RC. A timeout is rc=124, which every caller treats as fail-closed.
CLASS_OUT=""; CLASS_RC=0
run_class() {
    CLASS_OUT="$(tb_timeout "$CLASS_TIMEOUT" "$@" 2>&1)"; CLASS_RC=$?
    return 0
}

# ── one pass ────────────────────────────────────────────────────────────────────────────────────
# ── the state dir: a FULL DISK MUST NOT STOP THE PASS (#2443) ───────────────────────────────────
# MEASURED (2026-10-23 06:53Z, cell-1): `df /` = 100%, 0 bytes available, and the hourly pass printed
#   disk-reaper.sh: cannot create state dir /home/cmux/.pi/agent/state
# having run NO class — on the box, at the moment, whose disk it exists to free. The state dir is not
# "just a log location": the lock and the pass record live there, so without a writable one the reaper
# cannot run at all, which is the exact inert-enforcer shape this feature exists to remove. Its state
# therefore has to live somewhere the exhausted filesystem cannot reach.
#
# ⛔ THE CONFIGURED DIR IS STILL THE PRIMARY. It is used whenever it can be written; the fallback
# exists ONLY for the case where it cannot, and it is tmpfs — a DIFFERENT filesystem, so "full" is a
# property of the primary and never of the fallback. Every fallback is DISCLOSED: loudly on the pass's
# stdout (journald keeps it) and in the record (`state_dir_primary=`), never silently.
# ⛔ MUTUAL EXCLUSION IS NOT WEAKENED. A fallback pass takes a lock — that is why a pass with no
# writable candidate REFUSES below rather than running unlocked — and it is the CANONICAL lock, the one
# path every pass on the box derives from the tmpfs root alone (see CANONICAL_LOCK_DIR). So a pass that
# took the configured dir's lock before the disk filled is still excluded, in both orderings, and the
# concurrent-deletion hazard those two locks used to create is closed by construction rather than by
# enumerating environments the checker does not control.
state_dir_writable() { # <dir> — create it and PROVE a byte can be written
    local d="$1" p
    [ -n "$d" ] || return 1
    mkdir -p "$d" 2>/dev/null || return 1
    p="$d/.disk-reaper-probe.$$"
    # ⛔ NEVER WRITE THROUGH A PRE-PLANTED NAME. `-e` follows a symlink, so a DANGLING one would create
    # its target; `-L` catches that, and it is what makes a planted FIFO a refusal rather than a hang
    # (opening a FIFO for write blocks until a reader appears — measured: the pass sat in
    # wait_for_partner with no output, and the oneshot unit has no timeout).
    [ -e "$p" ] || [ -L "$p" ] && return 1
    # ⛔ A ZERO-BYTE CREATE IS NOT A FREE-SPACE PROBE. On a full filesystem an entry can be creatable
    # while a data block is not, so "the pass can write its record here" is measured with a real byte.
    # `set -C` (noclobber) makes the write itself refuse to follow an existing name, belt to the braces.
    # ⛔ THE `set -C` MUST LIVE IN A SUBSHELL. A brace group is not a subshell, so `set -C` there leaked
    # noclobber into the whole pass and every later `>` write — including the per-pass `: >"$LOG"`
    # truncation — started failing (measured: the log grew 5 -> 10 -> 15 lines across passes with one
    # error per pass). Parentheses scope it to the probe.
    ( set -C; printf 'x' >"$p" ) 2>/dev/null || { rm -f "$p" 2>/dev/null; return 1; }
    rm -f "$p" 2>/dev/null
    return 0
}
# tmpfs candidates: XDG_RUNTIME_DIR when the box has one, then /dev/shm. macOS has neither (its temp
# roots are on the data volume), so there the refusal below is the honest answer — unchanged behaviour.
# `-` (not `:-`): an EMPTY value disables the fallback, which is both a test seam and the operator's
# way to restore the old hard refusal on a box where a record off the primary path would be worse.
STATE_DIR_PRIMARY="$STATE_DIR"
STATE_DIR_PRIMARY_NOTE=""
# ⛔ ONE CANONICAL LOCK PATH, DERIVED FROM THE TMPFS ROOT ALONE (#2443). It is deliberately NOT
# keyed on the uid, on $XDG_RUNTIME_DIR, or on which fallback candidate this pass resolved: those are
# exactly the inputs that differ between a system unit, an interactive shell and a root repair pass,
# and a lock whose NAME depends on them is a lock those three do not share. tmpfs is writable when the
# disk is full, which is the only property the fallback needs from it.
CANONICAL_LOCK_DIR="${DISK_REAPER_TMPFS_ROOT:-/dev/shm}/pi-disk-reaper"
# The CONFIGURED dir's lock, set below ONLY when this pass fell back (a healthy pass's own lock IS
# that path, and `same_file` skips it). ⛔ DECLARED HERE, NOT NEAR ITS READER — initialising it after
# `resolve_state_dir` runs wipes the value that function sets (measured: the fallback then ran beside
# the live primary pass, the exact hazard the check exists for).
PRIMARY_LOCK_DIR=""
# An operator's own `DISK_REAPER_LOG` pin wins over the fallback's log path (resolve_state_dir below).
LOG_PINNED="${DISK_REAPER_LOG:-}"
STATE_DIR_FALLBACKS="${DISK_REAPER_STATE_DIR_FALLBACKS-${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/pi-disk-reaper}:${DISK_REAPER_TMPFS_ROOT:-/dev/shm}/pi-disk-reaper-$(id -u 2>/dev/null || printf 0)}"

resolve_state_dir() { # sets STATE_DIR/LOCK_DIR/STATUS/LOG, or refuses (exit 3)
    local cand seen=" "
    state_dir_writable "$STATE_DIR" && return 0
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$seen" in *" $cand "*) continue ;; esac
        seen="$seen$cand "
        [ "$cand" = "$STATE_DIR" ] && continue
        # ⛔ OWNERSHIP IS CHECKED BEFORE THE PROBE, NOT AFTER IT. A fallback candidate is only adopted
        # when this user owns it: /dev/shm is 1777 and the name is guessable, so a pre-existing foreign
        # dir carrying a planted lock would become this pass's lock/log/record dir and then defer for
        # ever (exit 6, unit GREEN, no record). Checking it AFTER `state_dir_writable` was the bug: that
        # function WRITES into the directory (at a predictable `.disk-reaper-probe.$$` name) before the
        # guard ran, so in a foreign dir it truncated whatever that name resolved to — a planted symlink
        # to a victim file was truncated to one byte, and a planted FIFO HUNG the pass (openat in
        # wait_for_partner) with the unit being Type=oneshot and unbounded, i.e. the reaper silently
        # disarmed. The canonical branch below already had this order; the two must not disagree.
        # The CONFIGURED dir is exempt from ownership (a shared or root-run state dir is legitimate).
        # An ABSENT candidate is fine — this pass will create it, and then owns what it created. Only a
        # PRE-EXISTING directory can be foreign, so only that case is refused.
        if [ -e "$cand" ] || [ -L "$cand" ]; then
            [ -O "$cand" ] || continue
        fi
        state_dir_writable "$cand" || continue
        STATE_DIR_PRIMARY_NOTE="unwritable"
        STATE_DIR="$cand"
        # ⛔ THE LOCK DOES NOT MOVE WITH THE STATE DIR. It moves to ONE canonical path every pass on
        # this box derives identically — `${DISK_REAPER_TMPFS_ROOT}/pi-disk-reaper/disk-reaper.lock`,
        # no uid, no candidate choice — so a fallback pass and a healthy pass contend on the SAME lock
        # whichever ordering they start in. Enumerating "candidate" or "per-uid" locks was tried and
        # abandoned: it needed every checker to reconcile environments it does not control (a system
        # unit has no $XDG_RUNTIME_DIR, a root repair pass has a different uid), and each enumeration
        # gap was another way for two passes to delete concurrently. One name cannot drift.
        # The log, record and scratch DO follow the state dir (they are data, not identity).
        if mkdir -p "$CANONICAL_LOCK_DIR" 2>/dev/null && [ -O "$CANONICAL_LOCK_DIR" ] && state_dir_writable "$CANONICAL_LOCK_DIR"; then
            LOCK_DIR="$CANONICAL_LOCK_DIR/disk-reaper.lock"
        else
            # Degraded, and DISCLOSED: no tmpfs at all means we can only exclude within this state dir.
            LOCK_DIR="$STATE_DIR/disk-reaper.lock"
            printf '%s: ⚠ the canonical lock dir %s is unusable too — this pass can only exclude against passes that resolved the same state dir\n' \
                "$SCRIPT_NAME" "$CANONICAL_LOCK_DIR" >&2
        fi
        STATUS="$STATE_DIR/disk-reaper.status"
        [ -n "$LOG_PINNED" ] || LOG="$STATE_DIR/disk-reaper.log"
        return 0
    done <<<"$(printf '%s\n' "$STATE_DIR_FALLBACKS" | tr ':' '\n')"
    # ⛔ NO WRITABLE STATE DIR ANYWHERE IS STILL A REFUSAL, and now it is a *stated* one: every
    # candidate tried is named. A pass that cannot record is a pass no reader can see, and a pass
    # without a lock is not a pass at all (#2036/T46).
    # ⛔ NAME WHAT WAS TRIED. With the fallback seam emptied there is no candidate list, and printing
    # `(tried: )` would be a refusal whose reason is invisible — the operator cannot tell "every
    # candidate was unwritable" from "no candidate exists", which are different remediations.
    if [ -n "${STATE_DIR_FALLBACKS//:/}" ]; then
        # ⛔ RENDER ONLY THE CANDIDATES THAT EXIST. With $XDG_RUNTIME_DIR unset the default list's `:`
        # join leaves an EMPTY first entry, and the old `${VAR//:/, }` printed it verbatim — "(tried: ,
        # /dev/shm/…)" names a candidate with no name, so the message was not "every candidate it tried".
        tried8="$(printf '%s\n' "$STATE_DIR_FALLBACKS" | tr ':' '\n' | sed '/^$/d' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
        printf '%s: cannot create state dir %s — and no fallback was writable (tried: %s)\n' \
            "$SCRIPT_NAME" "$STATE_DIR_PRIMARY" "$tried8" >&2
    else
        printf '%s: cannot create state dir %s — and no fallback is configured (DISK_REAPER_STATE_DIR_FALLBACKS is empty)\n' \
            "$SCRIPT_NAME" "$STATE_DIR_PRIMARY" >&2
    fi
    printf '%s: refusing to start — this pass would run with no lock and no readable record (exit 3).\n' "$SCRIPT_NAME" >&2
    printf '%s: free space by hand, or point DISK_REAPER_STATE_DIR at a writable filesystem.\n' "$SCRIPT_NAME" >&2
    exit 3
}

resolve_state_dir
if [ -n "$STATE_DIR_PRIMARY_NOTE" ]; then
    # ⛔ THE DELEGATES GET THE SAME DIR, AND THAT IS THE POINT OF THE FALLBACK. Each of the three
    # owners keeps its own lock and log under `$HOME/.pi/agent/state`; left alone on a full disk they
    # fail closed in THAT directory (pi-cache-reap.sh: "cannot create the lock directory … exit 3";
    # pi-reap-worktrees.sh: "FAIL-CLOSED abort: lock held"), so the pass would "run", free nothing and
    # report fail-closed — the same inert outcome through a longer path. Only seams the operator has
    # not pinned are set, so an explicit CACHE_REAP_LOCK/REAP_WT_STATE_DIR/… still wins.
    export CACHE_REAP_LOCK="${CACHE_REAP_LOCK:-$STATE_DIR/pi-cache-reap.lock}"
    export CACHE_REAP_LOG="${CACHE_REAP_LOG:-$STATE_DIR/pi-cache-reap.log}"
    export REAP_WT_STATE_DIR="${REAP_WT_STATE_DIR:-$STATE_DIR}"
    export REAP_WT_LOG="${REAP_WT_LOG:-$STATE_DIR/pi-reap-worktrees.log}"
    export REAP_VENV_LOG="${REAP_VENV_LOG:-$STATE_DIR/reap-lane-venvs.log}"
    # ⛔ THE NEW OWNERS GET IT TOO. Left alone on a full disk they fail closed in $HOME with "cannot
    # create the lock dir" — the same inert outcome through a longer path (#2443). An operator's own
    # pin still wins.
    export REAP_AW_STATE_DIR="${REAP_AW_STATE_DIR:-$STATE_DIR}"
    export REAP_AW_LOG="${REAP_AW_LOG:-$STATE_DIR/reap-abandoned-worktrees.log}"
    export REAP_DI_STATE_DIR="${REAP_DI_STATE_DIR:-$STATE_DIR}"
    export REAP_DI_LOG="${REAP_DI_LOG:-$STATE_DIR/reap-duplicate-installs.log}"
    # …and the runner `_work` owner, for the same reason. Without this it keeps its lock and log in
    # `$HOME/.pi/agent/state` and reports `SKIP reason=lock-uncreatable` (rc 3, `candidates=?`) on
    # EXACTLY the pass the fallback exists for, so the class would be inert on a full disk (#3043).
    export REAP_RW_STATE_DIR="${REAP_RW_STATE_DIR:-$STATE_DIR}"
    export REAP_RW_LOG="${REAP_RW_LOG:-$STATE_DIR/reap-runner-work.log}"
    # Scratch too: the bounded probes and the venv owner's `mktemp` would otherwise still target the
    # exhausted filesystem. `tb_bound_tmp` is lazy and idempotent, so the retry below only creates the
    # scratch that the earlier attempt could not.
    mkdir -p "$STATE_DIR/tmp" 2>/dev/null && export TMPDIR="$STATE_DIR/tmp"
    tb_bound_tmp 2>/dev/null || true
    printf '%s: ⚠ state dir %s is unusable (%s) — running this pass on %s (lock, log, scratch, record; the delegates get it too)\n' \
        "$SCRIPT_NAME" "$STATE_DIR_PRIMARY" "$STATE_DIR_PRIMARY_NOTE" "$STATE_DIR" >&2
    # ⛔ THE LOCK THE OTHER PASS HOLDS IS THE PRIMARY ONE, AND IT IS STILL READABLE ON A FULL DISK.
    # `state_dir_writable` can only fail here, so this pass takes its lock on tmpfs — a DIFFERENT lock
    # from a pass that started while the configured dir was still writable and is STILL RUNNING. Left
    # unchecked the two would run the same three delegates over the same caches, and because this pass
    # hands the delegates ITS state dir (CACHE_REAP_LOCK, REAP_WT_STATE_DIR — see above) their own locks
    # would not exclude each other either: two `uv cache prune`s, or two `git worktree remove`/`prune`s,
    # over one tree. The disclosure is NOT enough — that is concurrent deletion, not an accounting
    # artefact. So a fallback pass refuses to run beside a LIVE primary holder (checked after it takes
    # its own lock, below).
    PRIMARY_LOCK_DIR="$STATE_DIR_PRIMARY/disk-reaper.lock"
fi

# proc_lstart <pid> — the process's start time as `ps` prints it, pinned to C so BOTH sides of the
# comparison are spelled the same way (en_GB prints `Sun 18 Oct …`, C prints `Sun Oct 18 …` — the same
# defect pi-cache-reap.sh's lock fixed). Empty when it cannot be read, which is NOT "a different
# process": an unreadable side suppresses the recycle verdict rather than inventing one.
proc_lstart() {
    # Bounded too: a wedged `ps` under a debugger or on a hung /proc holds the lock just as well.
    tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" env LC_ALL=C "$PS_BIN" -o lstart= -p "$1" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ⛔ MUTUAL EXCLUSION. Two concurrent passes computing `df` deltas over one filesystem credit each
# other's reclaim — the same reason each delegate locks. A lock we cannot create is a refusal, not a
# pass; a STALE lock (older than LOCK_STALE_SECONDS) is removed and named.
acquire_lock() {
    local owner owner_started owner_lstart now_lstart ABANDONED=0
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s lstart=%s\n' "$$" "$(now)" "$(proc_lstart $$)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    # ⛔ PARSE THE NUMBER, NOT THE LINE. The token is `pid=<pid> started=<epoch> lstart=<ps text>`, and
    # the old `s/^pid=//p` returned the WHOLE TAIL (`"1234 started=1700000000"`), so `kill -0 "$owner"`
    # was always "invalid pid" — the live-holder arm was dead code and only the age bound stood between
    # a live pass and a contender deleting its lock. (Pre-existing; found by review on #2173.) The age
    # bound is not enough on its own: a single class may run for CLASS_TIMEOUT=1800s with no heartbeat,
    # which is exactly LOCK_STALE_SECONDS — a contender could then break a LIVE lock and two passes
    # would credit each other's `df` reclaim.
    # ⛔ AND A LIVE PID IS NOT PROOF THAT IT IS THE SAME PROCESS. pids are recycled (macOS's space is
    # ~99k), so a dead pass's pid can be taken by an unrelated process within hours — treating that as
    # a live holder makes every future pass exit 4 for ever and the stale reclaim unreachable. The owner
    # is identified the way pi-cache-reap.sh's lock identifies one: by (pid, START TIME). A pid whose
    # start time does not match the token is the RECYCLED case, which the age bound may then reclaim.
    # ⛔ "COULD NOT CREATE THE LOCK" IS NOT "SOMEONE ELSE HOLDS IT". When `mkdir` fails for a filesystem
    # reason (a full or read-only state dir) there is no token, `file_mtime` on a missing dir is empty so
    # `age=0`, and the contention arm below reported it BENIGN (exit 6, unit GREEN) — a box that can never
    # reap, certified. The lock dir's ABSENCE after a failed mkdir is the discriminator.
    [ -e "$LOCK_DIR" ] || { log_line "disk-reaper: cannot create $LOCK_DIR (filesystem problem: full, read-only?) — refusing to run without mutual exclusion"; exit 4; }
    owner="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    owner_started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    owner_lstart="$(sed -n 's/.*lstart=//p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    local age lm; lm="$(file_mtime "$LOCK_DIR")"
    case "$lm" in ''|*[!0-9]*) age=0 ;; *) age=$(( $(now) - lm )) ;; esac
    # ⛔ LOSING THE LOCK IS NOT A FAILURE, AND IT IS NOT 4 OR 5 EITHER. 4 reads as „a human must
    # look" to every reader (a removal failed), so the hourly tick that overlapped a long manual pass
    # failed readiness on a healthy box. 5 is the over-bound code, which the armed unit correctly does
    # NOT accept as success — a benign skip rendered as 5 would therefore redden the hour. The pass ran
    # and declined to act, claimed nothing: that is exactly 6 (DEFERRED), the one non-zero code the
    # unit accepts. NO record is written, so the previous one stands.
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        now_lstart="$(proc_lstart "$owner")"
        # ⛔ A TOKEN WITHOUT AN `lstart=` FENCE (one written by an older release) IS TREATED AS LIVE.
        # The alternative — reclaim it once it is older than the bound — was tried and is FAIL-OPEN: an
        # old-release pass still running past LOCK_STALE_SECONDS (3 classes x CLASS_TIMEOUT=1800s is
        # 5400s) would have its lock broken, and two passes would then credit each other's `df` reclaim.
        # A permanent false block is recoverable (remove the stale lock, name it on the unit); a broken
        # live lock is not. Recorded here because the trade is deliberate, not an oversight.
        if [ -z "$owner_lstart" ] || [ -z "$now_lstart" ] || [ "$owner_lstart" = "$now_lstart" ]; then
            log_line "disk-reaper: another pass holds the lock ($LOCK_DIR, pid $owner${owner_started:+, started $owner_started}) — not running (benign: the other pass is doing this hour's work)"
            exit 6
        fi
        log_line "disk-reaper: lock owner pid $owner is a RECYCLED pid (start time '$now_lstart' != '$owner_lstart') — the recorded pass is gone"
        ABANDONED=1
    fi
    if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
        log_line "disk-reaper: removing STALE lock ($LOCK_DIR, ${age}s old, pid ${owner:-?} gone)"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { log_line "disk-reaper: cannot take the lock — refusing to run without mutual exclusion"; exit 4; }
        printf 'pid=%s started=%s lstart=%s\n' "$$" "$(now)" "$(proc_lstart $$)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    # ⛔ NAME WHAT WAS ACTUALLY PROVEN. In the recycled-pid case the arm above has just said the recorded
    # owner is GONE, so falling through to "held by pid X" contradicted it in the next line: there is no
    # holder, only a lock too young to break.
    if [ "${ABANDONED:-0}" = 1 ]; then
        log_line "disk-reaper: the lock at $LOCK_DIR is ABANDONED (its recorded owner is gone) and is only ${age}s old (< ${LOCK_STALE_SECONDS}s) — this pass skips; it self-heals on the next one past the bound"
    else
        log_line "disk-reaper: lock $LOCK_DIR is held by pid ${owner:-?} (${age}s) — not running (benign)"
    fi
    exit 6
}

# Only the pass that WON the lock may release it. The EXIT trap is installed before acquire_lock
# runs, so a contender that loses the race exits 4 THROUGH the trap — without this flag it would
# delete the live owner's lock and let a third pass in; two passes would then compute df deltas over
# one filesystem and credit each other's reclaim.
LOCK_HELD=0
release_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    LOCK_HELD=0
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}
# A long but PROGRESSING pass must not age out of its own lock (a stale lock is taken by a contender).
heartbeat_lock() { [ "${LOCK_HELD:-0}" = 1 ] && touch "$LOCK_DIR" 2>/dev/null; return 0; }

# ps_can_see_self — can this `ps` report a process at all? A control probe, because `ps -p PID` exits 1
# BOTH for "no such process" and for "could not see it", and the two mean opposite things here. Cheap,
# and only consulted on the rc-1 arm.
ps_can_see_self() {
    local out
    out="$(tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" env LC_ALL=C "$PS_BIN" -o lstart= -p "$$" 2>/dev/null)" || return 1
    [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]
}

# peer_lock_live <lock-dir> — is another live pass holding THAT lock? The SAME identity rule this
# script's own lock uses (pid AND its start time): a live pid alone is not a holder, because pids are
# recycled and a recycled one would block every future pass for ever; a token without `lstart=` is
# treated as LIVE, matching acquire_lock's deliberate fail-closed choice for old-release tokens.
peer_lock_live() {
    local d="$1" owner owner_lstart now_lstart age lm ps_out ps_rc
    [ -n "$d" ] && [ -d "$d" ] || return 1
    owner="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$d/token" 2>/dev/null | head -1)"
    owner_lstart="$(sed -n 's/.*lstart=//p' "$d/token" 2>/dev/null | head -1)"
    if [ -z "$owner" ]; then
        # ⛔ A LOCK DIR WITH NO READABLE TOKEN IS STILL A LOCK, MIRRORING `acquire_lock`. The token write
        # there is `|| true`, and this function exists for the state `state_dir_writable` documents — an
        # entry can be creatable while a data block is not — so on a full disk `mkdir` can succeed and
        # the token's write fail. Reading that as "free" let a fallback pass run beside that live
        # holder: the exact concurrent-reap hazard this gate closes. A tokenless lock younger than the
        # stale bound is therefore LIVE; past it, it is debris and the pass proceeds (self-healing).
        lm="$(file_mtime "$d")"
        case "$lm" in ''|*[!0-9]*) age=0 ;; *) age=$(( $(now) - lm )) ;; esac
        [ "$age" -le "$LOCK_STALE_SECONDS" ]
        return $?
    fi
    # ⛔ NOT `kill -0`. It returns EPERM — indistinguishable from "no such process" through `|| return
    # 1` — for a LIVE process owned by another uid, so a root repair pass's lock read as dead and the
    # two passes reaped concurrently (measured: rc=0 beside a live root holder). `ps -o lstart=` IS
    # world-readable, so readability is the existence test: if the start time can be read the process
    # exists, and the token's own `lstart` then decides identity (recycled pid => not a holder).
    # ⛔ THE EXIT STATUS IS WHAT SEPARATES "GONE" FROM "COULD NOT LOOK", and `proc_lstart` throws it away.
    # `ps -p PID` exits 1 when there is no such process, and 0 when there is — including a process owned
    # by ANOTHER uid, which is why `kill -0` cannot be used (it returns EPERM for exactly that case and
    # read a live root holder as dead: measured, a fallback pass ran beside it). A non-1 failure (a
    # broken PS_BIN, a `ps` that timed out on a hung /proc, hidepid) means we cannot tell, and THAT must
    # fail closed — reading it as "no holder" ran a pass beside a live one (measured with
    # PS_BIN=/nonexistent: rc=0, class ran). The stale window bounds both arms, so a genuinely dead
    # holder cannot hold the pass for ever (a permanent exit 6 is the inert reaper this feature removes).
    ps_out="$(tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" env LC_ALL=C "$PS_BIN" -o lstart= -p "$owner" 2>/dev/null)"; ps_rc=$?
    now_lstart="$(printf '%s' "$ps_out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # ⛔ rc 1 IS NOT ONLY "ABSENT". It is also "could not look" — a hardened /proc (hidepid), a sandboxed
    # cell, or a PS_BIN shim that exits 1 on error — and folding the third outcome into "absent" is
    # fail-OPEN: the live holder becomes invisible and the pass runs beside it (measured with a
    # PS_BIN that exits 1: rc=0, class ran, while a working ps gives rc=6 on the same fixture). The
    # control probe decides which reading applies, exactly as scripts/orchestrator-harness/claims.sh
    # does: if ps cannot report OUR OWN pid's start time, rc 1 carries no information.
    if [ "$ps_rc" -eq 1 ] && ps_can_see_self; then
        return 1                            # ps works and does not know this pid: definitely not a holder
    fi
    if [ -z "$now_lstart" ]; then
        lm="$(file_mtime "$d")"
        case "$lm" in ''|*[!0-9]*) age=0 ;; *) age=$(( $(now) - lm )) ;; esac
        [ "$age" -le "$LOCK_STALE_SECONDS" ]
        return $?
    fi
    [ -z "$owner_lstart" ] || [ "$owner_lstart" = "$now_lstart" ]
}

# same_file <a> <b> — are these two spellings the SAME lock? A trailing slash, or a symlink/–ef alias,
# otherwise makes a pass compare its own lock with itself, fail to recognise it, and REFUSE (exit 6) —
# which the unit treats as GREEN, so the reaper would silently never reap: this feature's own named
# failure, produced by a comparison. Measured with `...FALLBACKS=/tmp/x/fb-slash/`: rc=6, and the pid
# it named as the holder was the pass itself.
same_file() {
    local a b
    a="$(printf '%s' "$1" | sed 's#/*$##')"
    b="$(printf '%s' "$2" | sed 's#/*$##')"
    [ -n "$a" ] && [ "$a" = "$b" ] && return 0
    [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

# peer_lock_dirs — the locks that mean "a pass is already working this box". Exactly TWO, and neither
# depends on the checker's uid, $XDG_RUNTIME_DIR, or which fallback candidate it resolved: the
# configured dir's lock and the ONE canonical tmpfs lock. ⛔ EVERY ENUMERATION VARIANT WAS TRIED AND
# ABANDONED (#2443 review cycles 3-5): "my configured candidates", "my uid's tmpfs dir", "every
# pi-disk-reaper-* uid dir" each left a reachable ordering where two passes reaped concurrently,
# because each made the SET a function of the checker's environment — the one thing a system unit, an
# interactive shell and a root repair pass do NOT share. A single fixed name cannot drift, and it is
# why a healthy pass can check it too (below) without any hermeticity problem: one path, one stat.
peer_lock_dirs() {
    printf '%s\n' "$PRIMARY_LOCK_DIR"
    # ⛔ OBEY ONLY A LOCK WE COULD HAVE TAKEN OURSELVES. /dev/shm is 1777, so on a shared host any local
    # user can create this directory first and plant a token naming a long-lived pid: obeying it holds
    # every pass — root's included — at exit 6, the one non-zero code the unit accepts, with no record
    # written (measured). Obeying only an owned dir turns that permanent disarm into a disclosed
    # degradation to state-dir locking, which the pass already reports.
    [ -O "$CANONICAL_LOCK_DIR" ] || return 0
    printf '%s\n' "$CANONICAL_LOCK_DIR/disk-reaper.lock"
}

# check_peer_locks — no pass may run beside a live pass holding either of the TWO locks that exist: the
# canonical one and this pass's configured one. It runs for EVERY pass, not only a fallback one: a
# healthy pass takes the configured lock while a fallback pass takes the canonical one, so leaving the
# healthy side unchecked was the mirror ordering (healthier pass starts after the fallback freed the
# space). With ONE fixed canonical path that check is a single stat, so it is closed rather than traded.
# Only refusal is safe here: deferring (6) is the routine "another pass is doing this hour's work" code
# the unit treats as green, and unlike crediting each other's `df` deltas, it cannot delete twice.
# ⛔ THE CANONICAL LOCK IS OBEYED ONLY WHEN THIS USER OWNS ITS DIR (peer_lock_dirs): /dev/shm is 1777,
# so on a shared host a foreign token could otherwise hold every pass at 6 for ever.
check_peer_locks() {
    # ⛔ EVERY PASS, NOT ONLY A FALLBACK ONE. A healthy pass takes the configured lock and a fallback
    # pass takes the canonical one, so a healthy pass starting while a fallback pass still runs (the
    # fallback may have just freed the space that made the configured dir writable) is the mirror
    # ordering — and with ONE fixed canonical path, checking it costs a single stat, so there is no
    # reason to leave it open. The old residual (i) was priced on enumerating tmpfs dirs; one name is
    # free, which is what makes it closable rather than a trade.
    local cand owner
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        # ⛔ NOT A STRING COMPARE: this pass's own lock can be spelled with a trailing slash or reached
        # through a symlink, and failing to recognise it makes the pass refuse against itself (exit 6,
        # unit GREEN) — the inert reaper this feature exists to remove.
        same_file "$cand" "$LOCK_DIR" && continue
        peer_lock_live "$cand" || continue
        owner="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$cand/token" 2>/dev/null | head -1)"
        log_line "disk-reaper: another pass holds a lock this pass must not run beside ($cand, pid ${owner:-?}) — refusing to run on $LOCK_DIR: a fallback pass hands the delegates this state dir, so their locks would not exclude two concurrent reaps of the same caches"
        release_lock
        exit 6
    done <<<"$(peer_lock_dirs)"
}
# ⛔ THE BOUNDED-EXECUTION LIBRARY OWNS SCRATCH AND TIMER PROCESSES. scripts/lib/bounded.sh documents
# `tb_bound_cleanup` and `tb_watchdogs_reap` as the CALLERS' EXIT-trap obligations; without them every
# pass on a host with no GNU `timeout` (macOS — the platform this PR adds) leaks its probe scratch dirs.
bound_cleanup() {
    release_lock
    command -v tb_watchdogs_reap >/dev/null 2>&1 && tb_watchdogs_reap
    command -v tb_bound_cleanup  >/dev/null 2>&1 && tb_bound_cleanup
    return 0
}
trap bound_cleanup EXIT

# Class selection: a tiny membership test that cannot be fooled by substring (e.g. `venv` vs
# `reap-lane-venvs`), because the list is split on commas.
want_class() {
    local c
    local IFS=,
    for c in $ONLY; do [ "$c" = "$1" ] && return 0; done
    return 1
}

# applies_mode / dry_flags — the delegate's own flag, so each owner keeps its own defaulting rules.
mode_flag() { [ "$DRY_RUN" = "1" ] && printf '%s' "--dry-run" || printf '%s' "--apply"; }
is_dry() { [ "$DRY_RUN" = "1" ]; }

# A delegate's exit code is mapped to the pass verdict ONCE, here, so every class agrees on what
# "failed" means. The labels are what the supervisor and fleet-health print, so each one names a
# DIFFERENT remedy:
#   removal-failed  the delegate ran and could not remove something          -> look at what holds it
#   over-bound      DRY-RUN: work present / the cache is over its bound       -> the box is short
#   deferred        the delegate ran, declined, claimed nothing (busy box)    -> retry later, not a bug
#   fail-closed     the delegate ran and could not do the work              -> look at the delegate
#   misconfigured   the class never RAN (delegate absent, no repo to scan)  -> fix the install
# ⛔ THE LABEL IS MODE-AWARE: 5 in a dry run means "this is over the bound / would be reaped", while 5
# on an armed pass means "the box is now UNDER its owner's stated floor" — and THAT case is ranked with
# a fail-closed class at the pass level (see the verdict loop), so both the rc and the label say the
# condition is still present. Reporting the dry-run label for it told the supervisor the opposite.
# ⛔ THE LABEL DESCRIBES WHAT HAPPENED, NOT WHICH DELEGATE SAID IT. Today only the uv family emits 5,
# and only in dry-run; the venv owner's below-floor 5 arrives with #1949.
# ⛔ A WORKTREE exit 3 IS NOT ALWAYS "LOCK HELD". That owner's 3 is its generic fail-closed code (gh
# unavailable, git enumeration failed, ps failed, log unwritable, library missing); only ONE of its
# arms is the lock. Special-casing it to "lock held" told the operator "retry later" for a broken box,
# so the family is deliberately NOT special-cased here.
class_verdict() { # class_verdict <rc>
    case "$1" in
        0) printf 'ok' ;;
        4) printf 'removal-failed' ;;
        5) if is_dry; then printf 'over-bound'; else printf 'fail-closed'; fi ;;
        6) printf 'deferred' ;;
        # `misconfigured` is set explicitly by the setup-failure arms (see MISCONFIG), because
        # `fail-closed` means the delegate RAN and could not do the work — a different remedy from
        # "there was nothing to run".
        *) printf 'fail-closed' ;;
    esac
}

# delegate_rc <class> <delegate-exit> — translate a DELEGATE's own exit vocabulary into the pass's
# class code. EVERY delegate rc enters the pass through here, never raw, because the three owners do
# NOT share a vocabulary and a single number->meaning table would be wrong for all three:
#
#   rc   pi-cache-reap.sh                reap-lane-venvs.sh        pi-reap-worktrees.sh
#   2    usage error                     usage error               usage error
#   3    fail-closed (could not          fail-closed (a probe      fail-closed (lib/git/gh/log,
#        measure/verify, log)             unavailable)              or the lock is held)
#   4    DID NOT RUN (lock held)         a removal FAILED          a removal FAILED
#   5    OVER BOUND (dry-run only)       BELOW THE FREE FLOOR      —
#   7    DEFERRED (a live tool holds     —                         —
#        the cache; nothing acted on)
#
# So 4 means the OPPOSITE in the cache owner to what it means in the other two, and only the cache
# owner has genuinely benign non-zero outcomes. Mapping is therefore per class:
#   * uv 4 (did not run) and uv 7 (deferred) -> 6 DEFERRED. Both mean "ran, declined, claimed
#     nothing", which is the routine state of a busy cell (#2036).
#   * 4 for venv/worktree -> 4, "a removal FAILED".
#   * 3 for ALL THREE -> 3, RED. A fail-closed delegate has not done the work; making it green is the
#     inert-enforcer false PASS (measured: a box whose `ps` probe is missing would report a green
#     hourly venv reaper while reaping nothing, forever).
#   * 5 survives for every class (#2156); it is ranked with 3 at the pass level when APPLYING.
#   * anything else (2/124/126/127/…) -> 3: it could not run as asked.
delegate_rc() { # delegate_rc <class> <delegate-exit>
    case "$2" in
        0) printf '0' ;;
        5) printf '5' ;;
        4) case "$1" in uv) printf '6' ;; *) printf '4' ;; esac ;;
        7) case "$1" in uv) printf '6' ;; *) printf '3' ;; esac ;;
        *) printf '3' ;;
    esac
}

# note_for <delegate> <rc> [family] — the record's `detail`, which is what a supervisor prints when
# ok=0. It must NAME the condition: "exited 5" leaves the reader to look up a table, "below its stated
# floor" does not. ⛔ THE FAMILY MATTERS BECAUSE THE DELEGATES' VOCABULARIES DISAGREE: in the uv family
# exit 4 is "another pass holds the lock" (benign, and routine — orch-loop.sh takes the same lock
# hourly), while in venv/worktree it is "a removal FAILED"; and in the worktree family exit 3 is
# "lock held" (benign) while in the others it is fail-closed. Each owner's header states its own
# mapping and forbids applying a sibling's.
note_for() { # note_for <delegate> <rc> [family]
    # ⛔ THE DELEGATE'S OWN CODE COMES FIRST, ALWAYS. `detail=` is what a supervisor prints when ok=0,
    # and the first thing a reader needs is WHICH code the owner returned — the pass's mapped code is in
    # `rc=`, one field up, and the two must never be confused. The words after the em dash are the
    # remedy, and they are per-FAMILY because the owners' vocabularies genuinely disagree.
    case "$2" in
        0) return 0 ;;
        5) if is_dry; then printf '%s exited 5 — it reports work it would do' "$1"
           else printf "%s exited 5 — it ended BELOW its owner's stated floor (apply mode: the box is still short)" "$1"; fi ;;
        4) case "${3:-}" in
               uv) printf '%s exited 4 — it did not run: another pass holds the lock' "$1" ;;
               *)  printf '%s exited 4 — a removal FAILED' "$1" ;;
           esac ;;
        3) printf '%s exited 3 — it FAILED CLOSED (could not do the work; see its log)' "$1" ;;
        7) case "${3:-}" in
               uv) printf '%s exited 7 — DEFERRED: a live tool holds the cache' "$1" ;;
               *)  printf '%s exited %s' "$1" "$2" ;;
           esac ;;
        *) printf '%s exited %s' "$1" "$2" ;;
    esac
}

# _rc_rank <code> — the severity order in ONE place: 3 (fail-closed) > 4 (a removal FAILED) >
# 6 (a delegate deferred) > 5 (over bound) > 0 (ok). Written as ranks rather than a case lattice so
# adding a code cannot silently fall through an arm nobody re-read (#2156) — and the catch-all ranks
# an UNRECOGNISED code as the MOST severe, never as ok: an unnamed value must never be read as
# success (the fleet's allow-list polarity rule).
_rc_rank() {
    case "$1" in
        0) printf '0' ;;
        5) printf '1' ;;
        6) printf '2' ;;
        4) printf '3' ;;
        3) printf '4' ;;
        *) printf '4' ;;
    esac
}

# worst_rc <current> <incoming> — the pass keeps the most severe class code, so one repo's failure
# cannot be masked by another repo's success, and a DEFERRAL in one repo cannot mask a REMOVAL FAILURE
# in another.
worst_rc() {
    local cur="${1:-0}" new="${2:-0}"
    if [ "$(_rc_rank "$new")" -gt "$(_rc_rank "$cur")" ]; then printf '%s' "$new"
    else printf '%s' "$cur"; fi
}

# to_mb <token> — "6156KB" / "2048MB" / "1.5GB" -> MiB as an integer. Empty when unparseable, so a
# future format change is a MISSING number rather than a wrong one.
to_mb() {
    local t="$1" n
    case "$t" in
        *KB) n="${t%KB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$(( n / 1024 ))" ;;
        *MB) n="${t%MB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$n" ;;
        *GB) n="${t%GB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$(( n * 1024 ))" ;;
        *) return 1 ;;
    esac
}

# ── class: uv (machine-global package caches, bounded by SIZE) ──────────────────────────────────
reap_uv() {
    local before after delta path would count=0 cands="" line size bound
    if [ -z "$CACHE_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=uv FAIL-CLOSED — pi-cache-reap.sh not found (looked at \$CACHE_REAPER, \$HOME/.pi/agent/scripts, and beside this script)"
        NOTE_UV="pi-cache-reap.sh not found"; RC_UV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }uv-delegate-missing"
        # It did not RUN: `WANT_*=0` makes the record say `not-run` (not a measured zero), the verdict
        # says `misconfigured` (not `refused` — that word is for a delegate that RAN and said no), and
        # `DF_*_OK` stays 1 so the detail does not blame `df` for a class that never ran.
        WANT_UV=0; VERDICT_UV="misconfigured"; DF_UV_OK=1; return 3
    fi
    # WHERE the cache is, and WHAT the bound is, come from the owner (`--print-config`), never from a
    # second copy of the paths here — the uv cache honours XDG_CACHE_HOME and a tuned bound must not
    # be described by a different policy than the one enforced.
    path="$(tb_timeout 60 bash "$CACHE_REAPER_PATH" --print-config 2>/dev/null | sed -n 's/^cache=uv://p' | head -1)"
    # ⛔ THE FALLBACK MUST NAME THE SAME DIRECTORY THE OWNER USES. It used to fall back to
    # `$HOME/.cache/uv` only, while `pi-cache-reap.sh` honours `UV_CACHE_DIR` AND `XDG_CACHE_HOME` — so on
    # a box with either set, the `df` reading was taken on a DIFFERENT filesystem than the one reclaimed
    # and `freed_mb_uv` was attributed to the wrong mount (accounting only: no delete path).
    [ -n "$path" ] || path="${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}"
    before="$(free_kb_for_path "$path")"
    run_class bash "$CACHE_REAPER_PATH" "$(mode_flag)"
    RC_UV="$CLASS_RC"
    # ⛔ 4 IN THE uv FAMILY IS NOT "a removal FAILED" (#2156 review). pi-cache-reap.sh's own contract
    # (its header, and its `*) exit 4` arm) says 4 = "did not run: another pass holds the lock" — a
    # BENIGN skip that happens routinely, because the controller's own hourly cache pass takes the
    # same lock. Mapping it to removal-failed put the unit RED on a healthy box: the exact #2036 shape,
    # reintroduced for the one class that shares its lock with the controller. Normalise it to 6 (the
    # delegate did not do its job — visible in the record, not a human-needed failure) and keep the
    # RAW code for the detail line, which is where "lock held" must be said in words.
    UV_RAW_RC="$CLASS_RC"
    # Every delegate code enters through delegate_rc, so uv's 4 (did not run) and 7 (deferred) become
    # 6 DEFERRED — "ran, declined, claimed nothing" — while its 3 stays 3 (RED).
    RC_UV="$(delegate_rc uv "$UV_RAW_RC")"
    after="$(free_kb_for_path "$path")"
    delta=""
    if [ -n "$before" ] && [ -n "$after" ]; then
        # RAW kept for the report: a negative or zero delta is CLAMPED to 0 for the status line, and the
        # unclamped figure is printed beside it — a clamp that cannot be audited is indistinguishable
        # from a measurement that never happened (the doc claimed this before the code did it).
        DF_UV_OK=1
        RAW_UV=$(( (after - before) / 1024 ))
        delta="$RAW_UV"; [ "$delta" -lt 0 ] && delta=0
        # A dry-run removed nothing: whatever df moved belongs to a concurrent writer, not to us.
        if is_dry; then FREED_UV=0; else FREED_UV="$delta"; fi
    else
        DF_UV_OK=0
    fi
    # Per-candidate would-free, from the owner's own dry-run line. Pulled out rather than recomputed:
    # "size minus bound" is the OWNER's rule, and a second implementation could disagree with it.
    while IFS= read -r line; do
        case "$line" in
            *"DRY-RUN uv "*">"*"bound"*)
                # The owner prints `<class> <path> <size> > <bound> bound ...` and the UNIT VARIES
                # (KB under 10 MB, measured: "6156KB > 1MB"). Read the tokens around `>` and convert,
                # so a small cache cannot silently drop out of the byte report.
                size="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i==">") {print $(i-1); exit}}')"
                bound="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i==">") {print $(i+1); exit}}')"
                size="$(to_mb "$size")" || continue
                bound="$(to_mb "$bound")" || continue
                count=$((count + 1)); WOULD_UV=$((WOULD_UV + size - bound))
                cands="${cands}${cands:+
}disk-reaper: WOULD-PRUNE class=uv ${size}MB -> ${bound}MB bound  ${path}"
                ;;
        esac
    done <<<"$CLASS_OUT"
    # rc 5 in dry-run means "over bound" — that is still WORK PRESENT, even when the owner printed no
    # row this pass. Counting it keeps a parse miss from becoming verdict 0.
    if is_dry && [ "$count" -eq 0 ] && [ "$RC_UV" = 5 ]; then
        count=1; cands="${cands}${cands:+
}disk-reaper: WOULD-PRUNE class=uv (? bytes — owner reported over-bound but printed no sized row) ${path}"
    fi
    CAND_UV="$count"
    VERDICT_UV="$(class_verdict "$RC_UV")"
    # ⛔ A COUNT IS OUR MEASUREMENT ONLY WHERE WE MADE ONE. In a DRY pass it is the number of
    # `DRY-RUN uv <path> <size> > <bound>` rows the owner printed, and any of its own per-cache lines
    # (over-bound, under-bound or absent) proves it ENUMERATED. A refusal prints none, and an APPLY
    # pass has no rows to count and no tally to lift — both are `?`, never the initialised 0.
    if is_dry && grep -qE '^pi-cache-reap: (DRY-RUN )?uv ' <<<"$CLASS_OUT"; then HAVE_UV_CAND=1; fi
    # A class that did not finish ok must say so in the record's `detail`, or the supervisor prints
    # `ok=0 detail=ok` — a self-contradicting line is worse than no line.
    [ "$RC_UV" = 0 ] || NOTE_UV="${NOTE_UV:-$(note_for pi-cache-reap.sh "$UV_RAW_RC" uv)}"
    log_line "$CLASS_OUT"
    [ -n "$cands" ] && log_line "$cands"
    if is_dry; then
        log_line "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=dry-run candidates=$(_tally_num "$HAVE_UV_CAND" "$CAND_UV") would_free_du=${WOULD_UV}MB (du estimate — over-counts blocks shared with the cache ONLY where this box shares them; measure with ${SELF_DIR:+$SELF_DIR/}worktree-disk-probe.sh) freed_df=0MB"
    else
        if [ "${DF_UV_OK:-0}" = 1 ]; then
            log_line "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=apply freed_df=${FREED_UV}MB df_raw=${RAW_UV}MB (df delta on $path)"
        else
            log_line "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero)"
        fi
    fi
    return 0
}

# ── repos for the two per-worktree classes ──────────────────────────────────────────────────────
# An EMPTY repo list is a fail-closed condition for these classes, not a no-op: a venv/worktree pass
# that scans nothing looks identical to a clean box.
resolve_repos() {
    local r list="" seen=" " _g="" _rc=0
    REPOS=""
    list="$REPOS_ARG"
    [ -n "$list" ] || list="$(printf '%s\n' "${DISK_REAPER_REPOS:-}" | tr ':' '\n')"
    if [ -z "$list" ]; then
        # The documented candidates: the fleet exports some of these (the cell supervisor exports
        # REPO; a laptop shell exports TORTOISE_REPO/AGENT_INFRA_PATH).
        list="$(printf '%s\n' "${REPO:-}" "${TORTOISE_REPO:-}" "${AGENT_INFRA_PATH:-}")"
    fi
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$seen" in *" $r "*) continue ;; esac
        seen="$seen$r "
        # ⛔ BOUNDED, LIKE EVERY OTHER PROBE THIS FILE MAKES. A bare `git` on a repo whose `.git` sits on a
        # dead or hung mount blocks the pass WHILE IT HOLDS THE LOCK: the hour's reap never happens, the
        # lock ages out, a contender breaks it, and two passes credit each other's `df` deltas.
        # ⛔ AND QUOTE GIT'S OWN LINE, NEVER ASSERT A CAUSE — the SAME rule the installer applies in its
        # resolve_repos (scripts/install-disk-reaper-timer.sh), because the two are one concept and used
        # to differ (#2159 review: the installer was fixed, this hourly copy kept the old diagnostic).
        # `rev-parse --git-dir` fails for MANY reasons: a vanished checkout, `chmod 000`, and the fleet's
        # dominant shape, `fatal: detected dubious ownership in repository at …` (a checkout owned by a
        # different uid). Stamping all of them "not a git checkout" sends the operator after the one
        # cause that cannot explain the fault — and suppresses the datum that would. This is the line the
        # 2026-10-30 incident's hourly log carried, so the fix belongs here too, not only in the installer.
        # `2>&1 >/dev/null`: stderr duplicates onto the capture pipe BEFORE stdout is discarded, so git's
        # ERROR is captured and its stdout (the `--git-dir` answer, which this function never reads) is not.
        _rc=0
        _g="$(tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" git -C "$r" rev-parse --git-dir 2>&1 >/dev/null)" || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            # An explicit --repo is the operator's assertion, so a rejected one must be named (the
            # same rule find_delegate applies to a set-but-missing delegate override).
            if [ "$_rc" = "124" ]; then
                # 124 is the BOUND firing, not git's answer: a dead or hung mount times out with an
                # EMPTY stderr, and rendering that as "git gave no message" would hide the one fact
                # this pass does know about it. Named as itself, like every other bounded probe here.
                log_line "disk-reaper: WARNING: ignoring '$r' — the git probe did not finish within ${GIT_TIMEOUT:-$DU_TIMEOUT}s (a dead or hung mount), so a class cannot scan it"
            else
                # `${_g:-…}` guards the empty-stderr shape (a silent git exits non-zero and says
                # nothing): an empty "(...)" would name no datum at all, so say so explicitly.
                log_line "disk-reaper: WARNING: ignoring '$r' — git cannot use it here ($(printf '%s' "${_g:-<git gave no message>}" | head -1)), so a class cannot scan it"
            fi
            continue
        fi
        REPOS="${REPOS}${REPOS:+
}$r"
    done <<<"$list"
    [ -n "$REPOS" ]
}

# ── class: venv (per-worktree .venv of a lane that is GONE) ──────────────────────────────────────
# Byte counts: the owner prints a size on every row it classifies; the entry point lifts those and
# labels them as the owner does, and states WHEN it over-counts: only where blocks are shared with
# the cache — a PER-MACHINE property (#1851 falsified the universal hardlink claim; measure it with
# scripts/worktree-disk-probe.sh rather than inferring it).
reap_venv() {
    local before after delta repo out rc count all_c=0 cands="" rows="" freed=0 raw=0 b a d MEASURED=1
    # ⛔ SUMMED PER REPO, like the worktree arm. The owner prints ONE `venvs_found= …` line per repo it
    # is handed, so reading the first match after the loop reported the FIRST repo's numbers as the
    # class's — on a two-repo cell with `found=1` and `found=5` the record said `classified_venv=1`
    # beside five more venvs, and `candidates_venv=0` stayed reachable whenever the first repo was
    # clean (the structural zero this lift exists to remove, one configuration away).
    local sum_v_classified=0 sum_v_cand=0 sum_v_pres=0 have_venv_tally=0 _vsum="" _vn2="" _vf="" _vr=""
    local venv_repos=0 venv_tally_repos=0
    if [ -z "$VENV_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=venv FAIL-CLOSED — reap-lane-venvs.sh not found (agent-infra PR #1949 owns this policy)"
        NOTE_VENV="reap-lane-venvs.sh not found"; RC_VENV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }venv-delegate-missing"
        WANT_VENV=0; VERDICT_VENV="misconfigured"; DF_VENV_OK=1; return 3
    fi
    if ! resolve_repos; then
        log_line "disk-reaper: ⛔ class=venv FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS); a class that scans nothing is NOT a pass"
        NOTE_VENV="no repo to scan"; RC_VENV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }venv-no-repo"
        WANT_VENV=0; VERDICT_VENV="misconfigured"; DF_VENV_OK=1; return 3
    fi
    # df is measured PER REPO: --repo may name paths on different filesystems, and the first repo's
    # delta would then report 0MB for gigabytes removed from another mount.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        venv_repos=$((venv_repos + 1))
        run_class bash "$VENV_REAPER_PATH" --gc --repo "$repo" --min-age "$VENV_MIN_AGE" "$(mode_flag)"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); raw=$((raw + d)); [ "$d" -lt 0 ] && d=0; freed=$((freed + d))
        else
            MEASURED=0
        fi
        log_line "$out"
        rows="${rows}${rows:+$'\n'}$out"
        # This repo's own tally. A non-numeric or absent field is "no answer", never 0: the caller
        # keeps the fallback and `detail=` still says the class did not finish.
        _vsum="$(printf '%s\n' "$out" | grep -m1 'venvs_found=' || true)"
        if [ -n "$_vsum" ]; then
            # ⛔ THE TALLY IS ANSWERED ONLY IF ITS CORE COUNT PARSES. `venvs_found=` was set as
            # "answered" before any field was read, so a TRUNCATED delegate stdout (a process dying
            # mid-line) left every sum at 0 while coverage claimed the repo had answered — an invented
            # `classified=0` presented as full coverage, which is the class this PR exists to remove.
            _vf="$(kv_field "$_vsum" venvs_found)"
            _vr="$(kv_field "$_vsum" reapable)"
            # ⛔ ANSWERED ONLY IF **BOTH** CORE COUNTERS PARSE — `venvs_found` AND `reapable`. The flag
            # was set on `venvs_found=` alone and `reapable` (the field the CANDIDATE count comes from)
            # was parsed opportunistically, so a line truncated after `venvs_found=`, or one with
            # `reapable=` absent/malformed, claimed an answer while `sum_v_cand` stayed 0. That ALSO
            # suppressed the row-count fallback below (`[ "$have_venv_tally" = 1 ] || CAND_VENV="$all_c"`),
            # so the REAP rows the pass had just scanned were discarded and the record read
            # `classified=3 candidates=0 tally=1/1` — "three classified, nothing to do, fully covered".
            # Same predicate, same reason, as the worktree arm's `case "${f_classified:-x}…"`.
            # ⛔ `${_vf:-x}` per field, not a bare concatenation: an EMPTY field concatenates away, so
            # `venvs_found=3` with `reapable` ABSENT would read as "all digits".
            case "${_vf:-x}${_vr:-x}" in
                ''|*[!0-9]*) : ;;
                *) have_venv_tally=1
                   venv_tally_repos=$((venv_tally_repos + 1))
                   sum_v_classified=$((sum_v_classified + _vf))
                   sum_v_cand=$((sum_v_cand + _vr)) ;;
            esac
            _vn2="$(kv_field "$_vsum" kept)";          case "$_vn2" in ''|*[!0-9]*) : ;; *) sum_v_pres=$((sum_v_pres + _vn2)) ;; esac
            _vn2="$(kv_field "$_vsum" recheck_kept)";  case "$_vn2" in ''|*[!0-9]*) : ;; *) sum_v_pres=$((sum_v_pres + _vn2)) ;; esac
        fi
        RC_VENV="$(worst_rc "$RC_VENV" "$(delegate_rc venv "$rc")")"
        # ⛔ APPEND, DO NOT FIRST-WIN. With two repos, a deferral in one and a removal failure in the
        # other must BOTH be named or `detail=` contradicts `rc=` (it named one code on a pass that
        # exited for another). One entry per DISTINCT code — the match is DELIMITED, so `exited 12`
        # cannot swallow `exited 1` — and the entry leads with the DELEGATE's own code (note_for).
        if [ "$rc" -gt 0 ]; then
            _vn="$(note_for reap-lane-venvs.sh "$rc" venv)"
            case "; $NOTE_VENV;" in *"; $_vn;"*) : ;; *) NOTE_VENV="${NOTE_VENV}${NOTE_VENV:+; }$_vn" ;; esac
        fi
    done <<<"$REPOS"
    VERDICT_VENV="$(class_verdict "$RC_VENV")"
    DF_VENV_OK="$MEASURED"; RAW_VENV="$raw"
    if is_dry; then FREED_VENV=0; else FREED_VENV="$freed"; fi
    # ── The owner's OWN tally answers "how many, and why kept" in BOTH modes ────────────────────────
    # `reap-lane-venvs.sh` already prints `venvs_found= reapable= reaped= kept= recheck_kept= failed=`
    # on one line PER REPO. Reading it is what makes an ARMED pass report a real candidate count: the
    # `REAP`-row scan below can only run in a dry pass (an armed pass's rows already happened), so
    # `candidates_venv` used to be a structural 0 on every armed pass — the same defect the worktree
    # arm's SUMMARY lift fixes, in the sibling class (#4529).
    if [ "$have_venv_tally" = 1 ] && { [ "$venv_repos" -gt 0 ] && [ "$venv_tally_repos" = "$venv_repos" ]; }; then
        CLASSIFIED_VENV="$sum_v_classified"
        CAND_VENV="$sum_v_cand"
        PRESERVED_VENV="$sum_v_pres"
        VENV_FULL_COVER=1
    fi
    # Published for the pass record, which cannot see this function is locals — the record used to
    # print these three raw, so `--only uv` wrote `verdict_venv=not-run` beside `classified_venv=0`
    # (a self-contradicting record) and a delegate that answered nothing wrote three measured zeros.
    HAVE_VENV_TALLY="$VENV_FULL_COVER"
    # ⛔ A HALF-ANSWERED CLASS IS NOT AN ANSWERED ONE: with N repos, `have_*_tally` is set by ANY repo,
    # so one delegate dying after printing made the class total an undercount that looked complete.
    # The coverage is published so the record can say `tally_venv=<answered>/<scanned>`.
    # ⛔ AND A PARTIAL SUM IS A LOWER BOUND, NOT A MEASUREMENT OF THE CLASS — `have_venv_tally` is a
    # CLASS-level "SOME repo answered" flag while the three counts above are class TOTALS. Measured on a
    # two-repo dry pass where repo A answered `reapable=0` and repo B's line was truncated after one
    # `REAP` row: the class line printed `candidates=0` beside `would_free_du=12MB` and the named
    # candidate, and the record said `candidates_venv=0 tally_venv=1/2` — a candidate the pass SCANNED,
    # reported as a measured zero. (The previous round fixed this per REPO and left it broken per
    # CLASS.) FULL coverage — every scanned repo answered — is what makes the sum an answer.
    VENV_TALLY_COVER="${venv_tally_repos}/${venv_repos}"
    # Same rule as the worktree arm: in a DRY pass the candidate count is OUR scan of the delegate
    # REAP rows, so classification output makes it answerable even without a tally; a refusal does not.
    HAVE_VENV_CAND="$VENV_FULL_COVER"
    if is_dry && grep -qE '^(REAP|KEEP|SUMMARY) ' <<<"$rows"; then HAVE_VENV_CAND=1; fi
    # Candidate rows are the owner's `REAP <reason> <N>MB <path>` lines; they carry the SIZE, which the
    # tally does not, so the row scan still runs in a dry pass for the byte estimate and the detail list.
    if is_dry; then
        while IFS= read -r line; do
            case "$line" in
                "REAP "*)
                    count="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+MB$/) {print $i; exit}}')"
                    # The owner's row is `REAP <reason> <size>  <path>` with PADDING, so `$NF` truncated a
                    # path containing a space and the report then named a directory that does not exist
                    # (the worktree arm had the same defect). The path is the REMAINDER of the line after
                    # the verb, the reason and the size.
                    path="$(printf '%s' "$line" | sed -E 's/^ *REAP +[^ ]+ +[^ ]+ +//')"
                    count="${count%MB}"
                    # ⛔ A CANDIDATE IS A CANDIDATE EVEN WHEN ITS BYTES COULD NOT BE MEASURED. The owner
                    # prints `REAP dead-lane  ?  <path>` whenever its own `du` fails; `continue`-ing on a
                    # non-numeric size dropped the row entirely, so a class with a reapable env reported
                    # `candidates=0 ok=1 detail=ok` — the unmeasured-reads-as-nothing false PASS the
                    # worktree arm below already avoids. Count it and say the bytes are unknown.
                    all_c=$((all_c + 1))
                    case "$count" in
                        ''|*[!0-9]*)
                            cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=venv (? bytes unmeasured — the owner could not size it) ${path}/.venv" ;;
                        *)
                            WOULD_VENV=$((WOULD_VENV + count))
                            cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=venv ${count}MB ${path}/.venv (du estimate — over-counts blocks shared with the cache ONLY where this box shares them; measure with ${SELF_DIR:+$SELF_DIR/}worktree-disk-probe.sh)" ;;
                    esac
                    ;;
            esac
        done <<<"$rows"
        # The owner's `reapable=` wins when it ANSWERED EVERY REPO; the row count is the fallback for an
        # owner too old to print a tally, for a PARTIAL answer, and for a row the owner sized as `?`
        # (which the scan handles). Never the partial sum: it is a lower bound, and printing it here
        # suppressed this fallback and reported a scanned candidate as `0`.
        [ "$VENV_FULL_COVER" = 1 ] || CAND_VENV="$all_c"
        [ -n "$cands" ] && log_line "$cands"
        log_line "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=dry-run candidates=$(_tally_num "$HAVE_VENV_CAND" "$CAND_VENV") would_free_du=${WOULD_VENV}MB (du estimate) freed_df=0MB"
    else
        # ⛔ `candidates=` IS NOT OURS TO ASSUME IN AN ARMED PASS. It is the delegate's own `reapable=`
        # (the armed pass already performed its `REAP` rows, so no row scan exists to fall back on),
        # and a delegate that printed nothing left the initialised 0 to print as a MEASURED zero —
        # beside a record that correctly said `?` (a review cycle caught the two surfaces disagreeing).
        if [ "${DF_VENV_OK:-0}" = 1 ]; then
            log_line "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=apply candidates=$(_tally_num "$HAVE_VENV_CAND" "$CAND_VENV") freed_df=${FREED_VENV}MB df_raw=${RAW_VENV}MB (df delta)"
        else
            log_line "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=apply candidates=$(_tally_num "$HAVE_VENV_CAND" "$CAND_VENV") freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero)"
        fi
    fi
    return 0
}

# ── class: worktree, SECOND arm — abandoned scratch worktrees (#2542) ───────────────────────────
# WHY THE CLASS HAS TWO OWNERS. `pi-reap-worktrees.sh` answers "is this REGISTERED checkout finished?"
# — clean, reachable, no open PR, aged by its HEAD commit. On 2026-10-24 that policy reclaimed nothing
# while ~120 directories under `/tmp` held 12.3 GB across three cells: they are linked worktrees of
# lanes that DIED, so their HEAD is young, their tree is dirty, and the 7-day floor never lets go.
# The owner's measured predicate for that population is different, and it is not a weakening of #1095:
#   age > 180 min AND no live process's cwd/exe resolves inside it (plus the pin / argv / live arms).
# `scripts/reap-abandoned-worktrees.sh` owns that rule. This arm only runs it, per scratch root, and
# folds its `df` delta into the worktree class — the entry point still owns no delete rule of its own.
#
# ⛔ IT IS A SEPARATE OWNER, NOT A RULE IN HERE. Adding the predicate to this file would make the
# entry point a fourth copy of a deletion policy, which is precisely what the #2032 consolidation
# exists to prevent (see the header). It also means the arm's fail-closed behaviour (an unreadable
# process list -> exit 3, nothing reaped, `SKIP reason=census-unreadable`) is owned and tested where
# the deletion is, not re-derived here.
#
# ⛔ THE PIN AND THE LIVE-CONTROLLER ARMS ARE THE OWNER'S (its `--print-config` says where it will
# sweep; `pinned()` / `lp_path_named()` inside it say what it will not touch). This function only
# accounts: per root, a `df` reading before and after, never a `du` sum.
reap_abandoned_arm() {
    local roots root b a d out rc _r _root_rem
    AW_FREED=0; AW_RAW=0; AW_MEASURED=1; AW_OUT=""; AW_NOTE=""; AW_REAPED=0; AW_SETUP_FAIL=0
    if [ -z "$ABANDONED_WT_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=worktree arm=abandoned FAIL-CLOSED — reap-abandoned-worktrees.sh not found (looked at \$ABANDONED_WT_REAPER, \$HOME/.pi/agent/scripts, and beside this script)"
        AW_NOTE="abandoned-worktree owner missing"
        # ⛔ SET, or the `misconfigured` verdict this arm exists for never happens (the guard read a
        # variable nothing assigned and the record still said `fail-closed` — "the delegate RAN").
        AW_SETUP_FAIL=1
        RC_WT="$(worst_rc "$RC_WT" 3)"
        MISCONFIG="${MISCONFIG}${MISCONFIG:+, }abandoned-worktree-delegate-missing"
        return 0
    fi
    # WHERE it will sweep comes from the owner, never from a second copy of the default here.
    roots="$(tb_timeout 60 bash "$ABANDONED_WT_REAPER_PATH" --print-config 2>/dev/null | sed -n 's/^roots=//p' | head -1)"
    [ -n "$roots" ] || roots="${REAP_AW_ROOTS:-/tmp}"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        b="$(free_kb_for_path "$root")"
        # `--aged-minutes` is the owner's dial; DISK_REAPER_ABANDONED_MINUTES is the operator's seam.
        run_class bash "$ABANDONED_WT_REAPER_PATH" "$(mode_flag)" --root "$root" \
                  --aged-minutes "${DISK_REAPER_ABANDONED_MINUTES:-180}"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$root")"
        # ⛔ PER ROOT. The "removed nothing ⇒ not our delta" rule used to be applied to the SUM across
        # roots, so a root whose delegate reaped nothing had its foreign delta credited as long as any
        # OTHER root reaped something (measured: a stub reporting reaped=1 for r1 and 0 for r2 gave
        # `freed_df=63MB detail=ok` for a pass that removed nothing in r2). A delta belongs to the root
        # that produced it, and only when THAT root's own ledger says it removed something.
        _root_rem="$(sed -n 's/.* reaped=\([0-9][0-9]*\) .*/\1/p' <<<"$out" | head -1)"
        case "${_root_rem:-}" in ''|*[!0-9]*) _root_rem=0 ;; esac
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); AW_RAW=$((AW_RAW + d))
            if [ "$_root_rem" -gt 0 ]; then
                [ "$d" -lt 0 ] && d=0; AW_FREED=$((AW_FREED + d))
            fi
        else
            AW_MEASURED=0
        fi
        _r="$(sed -n 's/.* reaped=\([0-9][0-9]*\) .*/\1/p' <<<"$out" | head -1)"
        case "${_r:-}" in ''|*[!0-9]*) _r=0 ;; esac
        AW_REAPED=$((AW_REAPED + _r))
        log_line "$out"
        AW_OUT="${AW_OUT}${AW_OUT:+$'\n'}$out"
        RC_WT="$(worst_rc "$RC_WT" "$(delegate_rc worktree "$rc")")"
        if [ "$rc" -gt 0 ]; then
            # APPENDED, like the venv and registered arms: with two scratch roots an assignment left
            # only the LAST root's failure in `detail=`, so the first failure vanished from the record.
            _an="$(note_for reap-abandoned-worktrees.sh "$rc" worktree)"
            case "; ${AW_NOTE:-};" in *"; $_an;"*) : ;; *) AW_NOTE="${AW_NOTE}${AW_NOTE:+; }$_an" ;; esac
        fi
    done <<<"$(printf '%s\n' "$roots" | tr ':' '\n')"
    # ⛔ NOTHING REMOVED MEANS THE DELTA IS NOT OURS. Measured on cell-3: a pass that removed no
    # candidate still printed `freed_df=44MB`, because another lane happened to free 44 MB inside the
    # window — credit taken for someone else's work. That is the same false credit `df`-instead-of-`du`
    # was adopted to stop, arriving through the other door. The observation is still reported, AS an
    # observation (df_raw), and named in the note.
    if [ "$AW_REAPED" = 0 ] && ! is_dry; then
        if [ "$AW_RAW" != 0 ]; then
            AW_NOTE="${AW_NOTE}${AW_NOTE:+; }nothing removed: the ${AW_RAW}MB df change belongs to another process (not attributed)"
        fi
        AW_FREED=0
    fi
    if [ -n "$AW_NOTE" ]; then
        case "; $NOTE_WT;" in *"; $AW_NOTE;"*) : ;; *) NOTE_WT="${NOTE_WT}${NOTE_WT:+; }$AW_NOTE" ;; esac
    fi
    return 0
}

# ── class: worktree (clean + reachable + holder-free checkouts) ─────────────────────────────────
reap_worktree() {
    local before after delta repo out rc count all_c=0 cands="" rows="" path size freed=0 raw=0 b a d sweep_end swept why="" MEASURED=1 _skip="" SKIP_NOTE="" REPO_ARM_OK=1 _rem WT_REMOVED=0 delegate_rows=""
    # ⛔ NEITHER OF THESE IS A `return` ANY MORE (#2542). The class has TWO arms, and the abandoned
    # arm needs no repo and no registered-checkout policy: returning here made the class's ONLY working
    # arm skip itself on exactly the cell #2443 measured — the one with no `--repo`, where the disk
    # keeps filling and every repo-scoped class fails closed. The failure is still recorded (rc 3,
    # `cannot run: …`, verdict misconfigured); it just no longer takes the arm that CAN run with it.
    # The delegate's own tally, summed across repos. `reasons` is joined; a proof value that DIFFERS
    # between repos is reported as `mixed` rather than letting the last repo answer for all of them.
    local sum_classified=0 sum_preserved=0 sum_remove=0 sum_reasons="" sum_removed=0 sum_failed=0
    local sum_deferred=0 sum_late=0 proof="" prm="" dverdict="" f_classified f_preserved f_remove f_reasons _sum _n _v
    # have_tally separates the two UNANSWERABLE cases from a measured zero: the class never ran
    # (`not-run`), or it ran and its delegate printed no SUMMARY (`?`). Both are recorded, neither is
    # reported as 0 — a `classified=0` beside `verdict=not-run` is a self-contradicting record, and it
    # is exactly the shape that reads as "healthy, nothing to do" on a pass that produced no answer.
    local have_tally=0 REASON_ROWS="" wt_repos=0 wt_tally_repos=0 wt_reasons_repos=0 reasons_none_repos=0 sum_deferred_remove=0
    if [ -z "$WORKTREE_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=worktree arm=registered FAIL-CLOSED — pi-reap-worktrees.sh not found (the abandoned arm still runs: it needs no repo)"
        NOTE_WT="pi-reap-worktrees.sh not found"; RC_WT=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }worktree-delegate-missing"
        REPO_ARM_OK=0; REPOS=""
    elif ! resolve_repos; then
        log_line "disk-reaper: ⛔ class=worktree arm=registered FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS); the abandoned arm still runs: it needs no repo"
        NOTE_WT="no repo to scan"; RC_WT=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }worktree-no-repo"
        REPO_ARM_OK=0; REPOS=""
    fi
    # df is measured PER REPO: --repo may span filesystems.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        wt_repos=$((wt_repos + 1))
        run_class bash "$WORKTREE_REAPER_PATH" "$(mode_flag)" --repo "$repo" --aged-days "$WT_AGED_DAYS"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        # ⛔ THE OWNER'S OWN LEDGER DECIDES ATTRIBUTION — `armed pass complete: REMOVED=<n>` is the datum
        # it already publishes. Crediting the window's `df` change unconditionally let a pass with ZERO
        # removals in BOTH arms report `freed_df=32MB verdict=ok` because another lane freed 32 MB
        # (measured) — a false PASS, and the reason the identical rule the two new arms carry belongs
        # here as well.
        _rem="$(sed -n 's/.* REMOVED=\([0-9][0-9]*\) .*/\1/p' <<<"$out" | tail -1)"
        case "${_rem:-}" in ''|*[!0-9]*) _rem=0 ;; esac
        WT_REMOVED=$((WT_REMOVED + _rem))
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); raw=$((raw + d))
            if [ "$_rem" -gt 0 ]; then [ "$d" -lt 0 ] && d=0; freed=$((freed + d)); fi
        else
            MEASURED=0
        fi
        # Lift the delegate's tally (one SUMMARY line per repo). Absent => the delegate is an older
        # copy; the class line then says `?` for the counts instead of inventing a number.
        _sum="$(printf '%s\n' "$out" | sed -n 's/^SUMMARY //p' | tail -1)"
        if [ -n "$_sum" ]; then
            f_classified="$(kv_field "$_sum" classified)"
            f_preserved="$(kv_field "$_sum" preserved)"
            f_remove="$(kv_field "$_sum" remove)"
            f_reasons="$(kv_field "$_sum" reasons)"
            # ⛔ DID THIS SUMMARY ACTUALLY CARRY `reasons=`? Counted separately from the histogram
            # below, because an ABSENT field and a real `reasons=none` both leave the histogram empty —
            # and only the latter is an answer. See the `none` normalisation at the end of this arm.
            [ -n "$f_reasons" ] && wt_reasons_repos=$((wt_reasons_repos + 1))
            # ⛔ AND DID IT SAY `none`, OR DID WE MERELY SEE A FIELD? `wt_reasons_repos` above counts a
            # PRESENT field; only `reasons=none` is an ANSWER. The two differ on a malformed histogram
            # (`reasons=too-recent:x`, or a future reason spelling whose count is not a number): the
            # merge loop drops every row, so the histogram is EMPTY, and normalising that empty to
            # `none` published `preserved=4 reasons=none` — "four kept, and none of them for any
            # reason" — the exact self-contradiction the `none` rule below exists to forbid. Counted
            # here, required below, so an unparseable histogram ends as `?`, never as `none`.
            [ "$f_reasons" = "none" ] && reasons_none_repos=$((reasons_none_repos + 1))
            # ⛔ ANSWERED ONLY IF THE CORE COUNTERS ALL PARSE. `have_tally=1` was set on the mere
            # PRESENCE of a SUMMARY, so a truncated line (a delegate dying mid-write) left the sums at 0
            # and the coverage at `1/1` — `classified=0` reported as a measured zero under full coverage.
            # The tally is the delegate's ANSWER; an unparseable one is no answer (same fix in
            # `reap_venv`). ⛔ `${f:-x}` per field, not a concatenation of the three: an EMPTY field
            # concatenates away, so `classified=3` with `preserved`/`remove` ABSENT read as "all digits".
            case "${f_classified:-x}${f_preserved:-x}${f_remove:-x}" in
                ''|*[!0-9]*) : ;;
                *) have_tally=1
                   wt_tally_repos=$((wt_tally_repos + 1))
                   sum_classified=$((sum_classified + f_classified))
                   sum_preserved=$((sum_preserved + f_preserved))
                   sum_remove=$((sum_remove + f_remove)) ;;
            esac
            # ⛔ MERGE the per-repo histograms, do not concatenate them: `too-recent:1` from repo A and
            # `too-recent:5` from repo B joined as text reads `too-recent:1,too-recent:5` — not a
            # histogram, and it does not sum to `preserved=`. ACCUMULATE `reason count` rows, then emit
            # one entry per reason, descending (the delegate's own shape).
            if [ -n "$f_reasons" ] && [ "$f_reasons" != "none" ]; then
                local _pair _rk _rv
                # ⛔ QUOTED, UNEXPANDED WORD SPLIT ONLY. The unquoted `$(…)` form also pathname-expands
                # against the pass CWD, so a reason token containing `*` would become the names of
                # files in the working directory (`reasons=*:4` -> `c:4,b:4,a:4`) and the histogram
                # stopped reconciling with `preserved=`. `set -f` around the loop is the cheap half.
                local _noglob_was_set=0
                case "$-" in *f*) _noglob_was_set=1 ;; *) set -f ;; esac
                for _pair in $(printf '%s' "$f_reasons" | tr ',' ' '); do
                    _rk="${_pair%%:*}"; _rv="${_pair##*:}"
                    # ⛔ ONLY the COUNT is a number. A reason NAME is a word (`too-recent`,
                    # `live-process`), so a digit test on it drops every real row — measured as
                    # `reasons=?` on a pass whose delegate reported `too-recent:1`.
                    [ -n "$_rk" ] || continue
                    case "$_rv" in ''|*[!0-9]*) continue ;; esac
                    REASON_ROWS="${REASON_ROWS}${REASON_ROWS:+
}${_rk} ${_rv}"
                done
                [ "$_noglob_was_set" = 1 ] || set +f
            fi
            _n="$(kv_field "$_sum" removed)";  case "$_n" in ''|*[!0-9]*) : ;; *) sum_removed=$((sum_removed + _n)) ;; esac
            _n="$(kv_field "$_sum" failed)";   case "$_n" in ''|*[!0-9]*) : ;; *) sum_failed=$((sum_failed + _n)) ;; esac
            _n="$(kv_field "$_sum" deferred)"; case "$_n" in ''|*[!0-9]*) : ;; *) sum_deferred=$((sum_deferred + _n)) ;; esac
            # ⛔ A DEFERRED REMOVAL IS NOT A DEFERRED CLASSIFICATION. The record let one vanish: an
            # armed pass whose budget ran out mid-removal printed `removed=0 failed=0 late_preserved=0`
            # — indistinguishable from "the removals silently did nothing" — with only the echoed
            # delegate text explaining it. Lift it so the alarm channel names it.
            _n="$(kv_field "$_sum" deferred_remove)"; case "$_n" in ''|*[!0-9]*) : ;; *) sum_deferred_remove=$((sum_deferred_remove + _n)) ;; esac
            _n="$(kv_field "$_sum" late_preserved)"; case "$_n" in ''|*[!0-9]*) : ;; *) sum_late=$((sum_late + _n)) ;; esac
            _v="$(kv_field "$_sum" main_proof)"
            if [ -n "$_v" ]; then if [ -z "$proof" ]; then proof="$_v"; elif [ "$proof" != "$_v" ]; then proof="mixed"; fi; fi
            _v="$(kv_field "$_sum" pr_merged)"
            if [ -n "$_v" ]; then if [ -z "$prm" ]; then prm="$_v"; elif [ "$prm" != "$_v" ]; then prm="mixed"; fi; fi
            # ⛔ THE DELEGATE'S OWN VERDICT (#3041). `verdict_worktree=` above is derived from the
            # delegate's EXIT CODE, and an ineffective reap exits 0 BY DESIGN (it is a diagnosis, not a
            # failure), so the fleet's status file said `verdict_worktree=ok` for a pass that reclaimed
            # nothing on a box at 0 bytes free. This field carries the delegate's ANSWER alongside it;
            # it does not change the class verdict or any exit code, so nothing that reads those moves.
            # ⛔ BUT NOT `main_proof=`'s POLARITY (#3058 review, P1). That one is read by nothing; THIS
            # one feeds an ⛔ alarm line, and a plain "any disagreement => mixed" rule makes `mixed`
            # mean BOTH "repo A was ineffective, repo B was idle" (the alarm) and "repo A reclaimed,
            # repo B was idle" (two ordinary readings). On the multi-repo shape a HEALTHY cell would
            # then print `⛔ worktree-delegate=mixed`, and `⛔ worktree-delegate=reap-ineffective` would
            # never be reachable at all — one repo `reap-ineffective` + one `idle` is exactly the pair
            # that collapses. The alarm class therefore WINS, and the two kinds of disagreement get
            # DIFFERENT spellings:
            #   · an alarm-class answer (reap-ineffective/unmeasured, or a spelling this reader has
            #     never seen — fail-loud) is carried as ITSELF; `mixed` is reserved for the one case
            #     where the cell genuinely cannot say, i.e. TWO DIFFERENT alarm answers;
            #   · benign answers that disagree (`reclaimed` + `idle`) read `mixed-benign`, which the
            #     reader keeps SILENT: two ordinary readings of two healthy passes are not an
            #     abstention, and a ⛔ there is the alarm-fatigue defect this field exists to avoid.
            _v="$(kv_field "$_sum" verdict)"
            if [ -n "$_v" ]; then
                if [ -z "$dverdict" ]; then dverdict="$_v"
                elif [ "$dverdict" != "$_v" ]; then
                    if [ "$(_dclass "$dverdict")" = "B" ]; then
                        if [ "$(_dclass "$_v")" = "B" ]; then dverdict="mixed-benign"; else dverdict="$_v"; fi
                    else
                        if [ "$(_dclass "$_v")" = "B" ]; then :; else dverdict="mixed"; fi
                    fi
                fi
            fi
        fi
        log_line "$out"
        rows="${rows}${rows:+$'\n'}$out"
        # ⛔ A REPO THE OPEN-PR GATE CANNOT VERIFY IS SKIPPED BY NAME — never the whole class, and never
        # a silent absence. The delegate fails closed for ONE repo (its checkouts untouched, which is
        # the safety property and it is NOT weakened here); this ledger says WHICH repo and WHY, so the
        # operator can fix the cause instead of reading `verdict=fail-closed` with no subject. Measured
        # 2026-10-23 on a cell at 95% used: gh present and working but not authenticated under the
        # pass's HOME -> both repos aborted -> `freed_df=0MB`, reported as "gh unavailable" (#2443).
        # ⛔ THE REASON IS EVERYTHING AFTER `reason=`, not the token after `skipped=`: a repo path may
        # contain a space (a checkout under `~/My Projects/…`), and anchoring on the path would then
        # match nothing — silently turning a named skip back into an anonymous fail-closed class.
        # `tr -d '[:space:]'` keeps a malformed/split token from becoming half a reason; the delegate
        # emits space-free tokens, so this only ever removes trailing whitespace in practice (#2443 P1).
        _skip="$(printf '%s\n' "$out" | sed -n 's/^SKIPPED-REPO: .*reason=//p' | head -1 | tr -d '[:space:]')"
        if [ -n "$_skip" ]; then
            SKIPPED_WT_N=$((SKIPPED_WT_N + 1))
            SKIPPED_WT="${SKIPPED_WT}${SKIPPED_WT:+, }${repo}[${_skip}]"
            log_line "disk-reaper: class=worktree skipped=$repo reason=$_skip — this repo's checkouts are UNTOUCHED (fail closed); the class kept going for the other repos"
        fi
        RC_WT="$(worst_rc "$RC_WT" "$(delegate_rc worktree "$rc")")"
        # Same rule as the venv class: one entry per DISTINCT code, appended, delegate code first.
        if [ "$rc" -gt 0 ]; then
            _wn="$(note_for pi-reap-worktrees.sh "$rc" worktree)"
            case "; $NOTE_WT;" in *"; $_wn;"*) : ;; *) NOTE_WT="${NOTE_WT}${NOTE_WT:+; }$_wn" ;; esac
        fi
    done <<<"$REPOS"
    # ⛔ THE REGISTERED DELEGATE'S OWN ROWS, KEPT APART FROM THE SECOND ARM'S (#2542 merge). The
    # abandoned arm prints an UNCONDITIONAL `SUMMARY` even when it found nothing, so the
    # refusal-vs-measurement gate below — which greps for a classification row — read a refusing
    # registered delegate as ANSWERED and recorded a measured `candidates_worktree=0` beside
    # `classified_worktree=?` (T59 b5). `$delegate_rows` is the registered arm's output alone; the
    # `remove` rows of BOTH arms are still real work this pass scanned.
    delegate_rows="$rows"
    # ── the class's SECOND arm: abandoned scratch worktrees (#2542) ───────────────────────────────
    # Folded into THIS class's accounting on purpose: it is the same sink (worktree debris), it needs
    # no `--repo` (so it still runs on a cell whose repo list is empty — the #2443 failure), and a
    # separate class name would have made an operator read two verdicts for one sink.
    reap_abandoned_arm
    rows="${rows}${rows:+$'\n'}${AW_OUT}"
    freed=$((freed + AW_FREED)); raw=$((raw + AW_RAW))
    [ "$AW_MEASURED" = 1 ] || MEASURED=0
    # A class whose REGISTERED arm could not be set up stays `misconfigured` even though its abandoned
    # arm ran: `cannot run: worktree-no-repo` in `detail=` is the truth about the half that did not
    # run, and the rc (3) already carries the red. The alternative — `fail-closed`, which means "the
    # delegate RAN and could not do the work" — would misdescribe it.
    # `misconfigured` is "a class that could not be SET UP at all" — so a missing ABANDONED delegate
    # belongs here too, not under `fail-closed` ("the delegate ran and could not do the work"), which
    # is what the record said beside `detail=cannot run: abandoned-worktree-delegate-missing`.
    if [ "$REPO_ARM_OK" = 1 ] && [ "${AW_SETUP_FAIL:-0}" = 0 ]; then
        VERDICT_WT="$(class_verdict "$RC_WT")"
    else
        VERDICT_WT="misconfigured"
    fi
    # ⛔ THE CLASS LINES AND THE RECORD PRINT *THIS* VARIABLE, never `class_verdict "$RC_WT"`
    # (a merge resolution briefly re-derived it at the `say`, which put `verdict=fail-closed` on the
    # class line beside `verdict_worktree=misconfigured` in the record of the SAME pass — the
    # two-surfaces-disagree defect, and #2036's "could not be SET UP at all" distinction erased from
    # the operator-facing line). `misconfigured` is not derivable from the rc alone; it is state.
    # ⛔ CLASS LEVEL, OVER BOTH ARMS: a class that removed NOTHING in either arm does not get to claim
    # the window's `df` change (measured: `freed_df=110MB` on a pass whose registered arm failed closed
    # and whose abandoned arm found nothing, because two other lanes were writing).
    if [ "$REPO_ARM_OK" = 1 ] && [ "$WT_REMOVED" = 0 ] && [ "$AW_REAPED" = 0 ] && ! is_dry; then
        if [ "$raw" != 0 ]; then
            _wn="nothing removed: the ${raw}MB df change belongs to another process (not attributed)"
            case "; $NOTE_WT;" in *"; $_wn;"*) : ;; *) NOTE_WT="${NOTE_WT}${NOTE_WT:+; }$_wn" ;; esac
        fi
        freed=0
    fi
    DF_WT_OK="$MEASURED"; RAW_WT="$raw"
    WT_TALLY_COVER="${wt_tally_repos}/${wt_repos}"
    # ⛔ A HALF-ANSWERED CLASS IS NOT AN ANSWERED ONE — AND THAT RULE IS ABOUT THE CLASS TOTALS, NOT
    # ONLY THE PER-REPO ROWS (#4529; the mirror of the venv arm's full-coverage gate). `have_tally` is
    # set by ANY repo that answered, while `sum_classified`/`sum_preserved`/`sum_remove`/`sum_deferred*
    # and the histogram below are class TOTALS accumulated over ONLY the repos that answered. Measured
    # on a two-repo pass where repo A answered `classified=5` and repo B's SUMMARY was truncated: the
    # record published `classified_worktree=5 preserved_worktree=4 preserved_reasons_worktree=too-recent:4`
    # as the class's measured counts, with the sole disclosure a `tally_worktree=1/2` field the design
    # doc never mentions — so a repo that produced NO ANSWER AT ALL was silently absent from the four
    # fields this arm exists to publish. FULL COVERAGE — every scanned repo answered — is what makes a
    # sum an answer; a partial class publishes `?` for every count instead, exactly as the venv arm
    # does. Demoting `have_tally` here also makes the `reasons=none` normalisation below coverage-aware,
    # and reaches `HAVE_WT_CAND` and `HAVE_WT_TALLY` because both are assigned FROM this variable.
    if [ "$have_tally" = 1 ] && ! { [ "$wt_repos" -gt 0 ] && [ "$wt_tally_repos" = "$wt_repos" ]; }; then
        have_tally=0
    fi
    # ⛔ THE PROOF MODES ARE CLASS TOTALS TOO, and they are accumulated exactly like the counters above
    # (`proof`/`prm` are `mixed` when the answering repos disagree). Printed from the RAW variables, the
    # class line published `main_proof=local pr_merged=na` for the partial pass above while the RECORD
    # — which routes them through `_tally_rec`/`HAVE_WT_TALLY` — printed `main_proof=?`: two surfaces of
    # ONE pass contradicting each other, which is the defect this arm exists to remove, on the fields
    # that answer "how was the merge proved". Decided ONCE here so both surfaces read the same value.
    [ "$have_tally" = 1 ] || { proof="?"; prm="?"; dverdict="?"; }
    # Fold `reason count` rows into one histogram, descending by count — the delegate's own shape.
    sum_reasons="$(printf '%s\n' "$REASON_ROWS" | awk 'NF==2 { c[$1] += $2 }
        END { for (k in c) printf "%d\t%s\n", c[k], k }' | sort -rn -k1,1 \
        | awk -F'\t' 'BEGIN{ORS=""} {printf "%s%s:%s", (n++ ? "," : ""), $2, $1}')"
    # An ANSWERED `reasons=none` (a clean, fully-measured pass) must not degrade to `?`: no reasons is
    # a result, not a missing one. ⛔ NORMALISED HERE, BEFORE the class line prints `${sum_reasons:-?}`:
    # done after the `say`, it repaired the RECORD only, so every clean armed pass still printed
    # `reasons=?` on its class line — the sentinel losing its meaning on the one pass it must not
    # (a review cycle found the two surfaces disagreeing).
    # ⛔ AND ONLY WHEN `reasons=` WAS REALLY READ FROM EVERY SUMMARY WE ACCEPTED: an empty histogram is
    # `none` when the delegate SAID `none`, and `?` when the field was never reached — the likeliest truncation, since `reasons=`/`main_proof=`/`pr_merged=`
    # are the TAIL fields. Without this a line cut after `failed=0` printed `preserved_worktree=2`
    # beside `preserved_reasons_worktree=none`: "two checkouts kept, and none of them for any reason".
    [ "$have_tally" = 1 ] && [ "$wt_reasons_repos" = "$wt_tally_repos" ] && [ "$reasons_none_repos" = "$wt_tally_repos" ] && [ -z "$sum_reasons" ] && sum_reasons="none"
    # ⛔ The histogram is a class TOTAL like the counters above, so a PARTIAL class must not publish it
    # either: `reasons=too-recent:4` beside `classified=?` reads as a reason breakdown for a count that
    # was never measured. Placed AFTER the `none` normalisation (which already requires `have_tally=1`)
    # so the two rules cannot disagree about what a partial class says.
    [ "$have_tally" = 1 ] || sum_reasons="?"

    # The skip ledger rides on the class line AND the pass record: a class that skipped a repo did LESS
    # than a clean class, so its verdict stays fail-closed (3) — skipping is not a pass — but the line
    # names how much of the class DID run, which is what makes the difference actionable.
    SKIP_NOTE=""
    [ "$SKIPPED_WT_N" -gt 0 ] && SKIP_NOTE=" skipped=$SKIPPED_WT_N ($SKIPPED_WT)"
    # ⛔ NOT MISCONFIG. That field is "a class that could not be SET UP at all" and is rendered as
    # `cannot run: …` — the opposite of what happened here: the class RAN and reclaimed the repos it
    # could verify. Adding it made `detail=` carry two contradictory causes, one of them false, on a
    # record an operator reads to decide what to fix. `NOTE_WT` names the cause; the exit code and
    # `verdict_worktree=fail-closed` already carry the red (#2443 review P2).
    if [ "$SKIPPED_WT_N" -gt 0 ]; then
        case "; $NOTE_WT;" in
            *"; PR-state gate unverifiable;"*) : ;;
            *) NOTE_WT="${NOTE_WT}${NOTE_WT:+; }PR-state gate unverifiable" ;;
        esac
    fi
    if is_dry; then FREED_WT=0; else FREED_WT="$freed"; fi
    # (the delegate's tally is lifted out of $out inside the repo loop above)
    # The owner deliberately reports NO byte figure: whether its `.venv`s share cache blocks is a
    # PER-MACHINE property (#1851 — the old universal "84 GB du delta vs 22 GB freed" mechanism was
    # falsified; measured regimes are APFS clonefile, hardlink, and neither, ratio 1.004). A `du`
    # figure here would therefore be an upper bound dressed as a saving. The consolidation
    # requirement is "byte counts in dry-run", so the ENTRY POINT measures each selected checkout
    # with a bounded `du` and labels it for what it is. The owner's contract is untouched: it still
    # never claims a saving.
    # ⛔ WHETHER THIS CLASS ANSWERED IS DECIDED HERE, BEFORE THE CLASS LINE IS PRINTED. The record's
    # `candidates_worktree` already distinguishes a measured count from a REFUSAL (`?`), but the class
    # line printed the raw counter — so a delegate that exited 3 and printed only
    # `FAIL-CLOSED gh unavailable` reported `candidates=0` on the line while the record written in the
    # same pass said `candidates_worktree=?`. Two surfaces of one pass disagreeing about the very field
    # this tool exists to report is the false PASS one layer up — T59's shape, worktree arm.
    #
    # ⛔ `candidates` is OUR measurement only where we measured it. In a DRY run it is the count of
    # `remove` rows this class scanned with `du`, so any delegate output makes it real (0 rows = 0
    # candidates). In an APPLY pass it is the delegate's own `remove=` from the SUMMARY, so it is
    # answerable ONLY with a tally — hardcoding `have_tally=1` recorded a measured `0` beside
    # `classified_worktree=?` on a selected class whose delegate printed nothing.
    HAVE_WT_CAND="$have_tally"
    # ⛔ A REFUSAL IS NOT A MEASUREMENT EITHER. `[ -n "$rows" ]` was true for a delegate that printed
    # only `class=worktree FAIL-CLOSED gh unavailable` and exited 3, so the record claimed
    # `candidates_worktree=0` (a measured zero) beside `classified_worktree=?`. Count it only when the
    # output actually contains CLASSIFICATION rows — that is what the `du` sweep measured.
    # ⛔ AND ONLY THE REGISTERED DELEGATE'S `SUMMARY` PROVES IT ANSWERED: the abandoned arm emits one
    # unconditionally, so grepping `$rows` let a refusal inherit the other arm's tally. A `remove` row
    # from either arm is a candidate this pass really scanned, so that alone also answers the count.
    if is_dry && { grep -qE '^(remove|preserve|SUMMARY) ' <<<"$delegate_rows" || grep -qE '^remove[[:space:]]' <<<"$rows"; }; then
        HAVE_WT_CAND=1
    fi
    if is_dry; then
        # CLASS_TIMEOUT bounds the DELEGATE, not this sweep: N candidates x DU_TIMEOUT each would let a
        # single pass hold the lock for hours. The sweep gets ONE budget for the whole class.
        sweep_end=$(( $(now) + DU_BUDGET )); swept=0
        # ⛔ ONE DIRECTORY, ONE CANDIDATE. `rows` concatenates BOTH arms' output, and a checkout can be
        # selected by both (the registered arm removes its record, the abandoned arm matches the path),
        # so the same `remove` row arrived twice: `candidates` was reported as 2 for one directory and
        # its `du` was added twice. Dedupe on the PATH before counting or sizing anything.
        seen_paths=" "
        while IFS= read -r line; do
            if [[ "$line" == remove* ]]; then
                # The owner's row is `remove   <path>` (ragged columns): drop the verb, then LEADING
                # whitespace, then take the first remaining token. Trimming in the other order made
                # the path empty and silently produced candidates=0 for every real row.
                path="${line#remove}"
                path="${path#"${path%%[![:space:]]*}"}"
                # Keep the REMAINDER of the line: a checkout under a directory with a space in its
                # name was truncated at the space, then `du` measured a path that does not exist and the
                # row asserted the wrong cause. The path is the rest of the line, verbatim.
                path="${path%"${path##*[![:space:]]}"}"
                [[ "$path" == /* ]] || continue
                case "$seen_paths" in *" $path "*) continue ;; esac
                seen_paths="$seen_paths$path "
                why="du could not read it (already gone, or unreadable)"
                if [ "$(now)" -ge "$sweep_end" ]; then size="?"; why="du budget exhausted"
                else size="$(du_mb "$path")" || size="?"; fi
                swept=$((swept + 1)); [ $((swept % 25)) -eq 0 ] && heartbeat_lock
                all_c=$((all_c + 1))
                case "$size" in
                    ''|*[!0-9]*) cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=worktree (? bytes unmeasured — ${why}) ${path}" ;;
                    *) WOULD_WT=$((WOULD_WT + size))
                       cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=worktree ${size}MB ${path} (du estimate — over-counts blocks shared with the cache ONLY where this box shares them; measure with ${SELF_DIR:+$SELF_DIR/}worktree-disk-probe.sh)" ;;
                esac
            fi
        done <<<"$rows"
        CAND_WT="$all_c"
        [ -n "$cands" ] && log_line "$cands"
        log_line "disk-reaper: class=worktree rc=$RC_WT verdict=$VERDICT_WT mode=dry-run candidates=$(_tally_num "$HAVE_WT_CAND" "$CAND_WT") would_free_du=${WOULD_WT}MB (du estimate) freed_df=0MB classified=$(_tally_num "$have_tally" "$sum_classified") preserved=$(_tally_num "$have_tally" "$sum_preserved") deferred=$(_tally_num "$have_tally" "$sum_deferred") failed=$(_tally_num "$have_tally" "$sum_failed") reasons=${sum_reasons:-?} main_proof=${proof:-?} pr_merged=${prm:-?} tally=${WT_TALLY_COVER:-0/0}${SKIP_NOTE}"
    else
        # `candidates_worktree` used to be structurally 0 on an ARMED pass (it was only accumulated in
        # the dry-run branch), so the record answered "no candidates" for a pass that classified fifty.
        # Lift the delegate's `remove=` instead of re-deriving it.
        CAND_WT="$sum_remove"
        if [ "${DF_WT_OK:-0}" = 1 ]; then
            log_line "disk-reaper: class=worktree rc=$RC_WT verdict=$VERDICT_WT mode=apply freed_df=${FREED_WT}MB df_raw=${RAW_WT}MB (df delta) classified=$(_tally_num "$have_tally" "$sum_classified") removed=$(_tally_num "$have_tally" "$sum_removed") preserved=$(_tally_num "$have_tally" "$sum_preserved") deferred=$(_tally_num "$have_tally" "$sum_deferred") deferred_remove=$(_tally_num "$have_tally" "$sum_deferred_remove") failed=$(_tally_num "$have_tally" "$sum_failed") late_preserved=$(_tally_num "$have_tally" "$sum_late") reasons=${sum_reasons:-?} main_proof=${proof:-?} pr_merged=${prm:-?} tally=${WT_TALLY_COVER:-0/0}${SKIP_NOTE}"
        else
            log_line "disk-reaper: class=worktree rc=$RC_WT verdict=$VERDICT_WT mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero) classified=$(_tally_num "$have_tally" "$sum_classified") removed=$(_tally_num "$have_tally" "$sum_removed") preserved=$(_tally_num "$have_tally" "$sum_preserved") deferred=$(_tally_num "$have_tally" "$sum_deferred") deferred_remove=$(_tally_num "$have_tally" "$sum_deferred_remove") failed=$(_tally_num "$have_tally" "$sum_failed") late_preserved=$(_tally_num "$have_tally" "$sum_late") reasons=${sum_reasons:-?} main_proof=${proof:-?} pr_merged=${prm:-?} tally=${WT_TALLY_COVER:-0/0}${SKIP_NOTE}"
        fi
    fi
    # An ANSWERED `reasons=none` is normalised ABOVE, before the class line prints it (a fix applied
    # only here repaired the record while the class line still said `?`).
    CLASSIFIED_WT="$sum_classified"; PRESERVED_WT="$sum_preserved"; REASONS_WT="$sum_reasons"
    PROOF_WT="$proof"; PRM_WT="$prm"; HAVE_WT_TALLY="$have_tally"
    DELEGATE_VERDICT_WT="$dverdict"
    DEFERRED_REMOVE_WT="$sum_deferred_remove"
    return 0
}

# ── class: duplicate-install (surplus copies of the same tool install, #2542) ───────────────────
# MEASURED (2026-10-24, cell-1): 3.1 GB free, and **11.3 GB of `/tmp/actions-runner` was EIGHT
# identical runner installs** (`ps … | grep -c '[R]unner.Listener'` -> 8) on an 8-core box. Duplicate
# installs are not caches, not lane venvs and not checkouts, so every existing class matched nothing
# and the box filled with copies of a tool that had one job to do.
#
# ⛔ THE ASYMMETRY IS THE POLICY, and it points the opposite way from the other classes: a duplicate
# left on disk costs disk, while a duplicate reaped while live costs WORK (a runner killed mid-job is
# a lost job, and the run goes unserved). So the owner removes only copies it can PROVE idle, always
# keeps the newest, never empties a family, and keeps-and-names every copy it cannot prove. This
# entry point adds nothing to that: it accounts, per root, with a `df` delta.
reap_dup() {
    local roots root b a d out rc freed=0 raw=0 MEASURED=1 rows="" cands="" all_c=0 line path size why _dn reaped=0 _r _root_rem
    local _dup_cand=0 _dup_ans=0 _dup_roots=0 _dup_sum_line="" _dup_c="" _dup_census=""
    local sweep_end swept
    if [ -z "$DUP_INSTALL_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=duplicate-install FAIL-CLOSED — reap-duplicate-installs.sh not found (looked at \$DUP_INSTALL_REAPER, \$HOME/.pi/agent/scripts, and beside this script)"
        NOTE_DUP="reap-duplicate-installs.sh not found"; RC_DUP=3
        MISCONFIG="${MISCONFIG}${MISCONFIG:+, }duplicate-install-delegate-missing"
        WANT_DUP=0; VERDICT_DUP="misconfigured"; DF_DUP_OK=1; return 3
    fi
    roots="$(tb_timeout 60 bash "$DUP_INSTALL_REAPER_PATH" --print-config 2>/dev/null | sed -n 's/^roots=//p' | head -1)"
    [ -n "$roots" ] || roots="${REAP_DI_ROOTS:-/tmp}"
    # ⛔ HOW MANY ROOTS THIS PASS WILL ACTUALLY VISIT, so a partial answer is detectable. `_dup_ans`
    # counts the roots that answered; the published count is the SUM over them, so `_dup_ans > 0` is
    # "ANY root answered" — the same half-answered-class defect this PR removes from the worktree and
    # venv arms, left in the third class. With `roots=A:B`, A `census=ok candidates=3` and B unreadable,
    # the record published `candidates_duplicate_install=3` as the class's count with NO field anywhere
    # disclosing that B answered nothing. Counted with the loop's OWN filter (`[ -n "$root" ]` skips an
    # empty entry), so this is the number of visits, not the number of colon-separated tokens.
    _dup_roots="$(printf '%s\n' "$roots" | tr ':' '\n' | awk 'NF { n++ } END { print n + 0 }')"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        b="$(free_kb_for_path "$root")"
        run_class bash "$DUP_INSTALL_REAPER_PATH" "$(mode_flag)" --root "$root"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$root")"
        _root_rem="$(sed -n 's/.* reaped=\([0-9][0-9]*\) .*/\1/p' <<<"$out" | head -1)"
        case "${_root_rem:-}" in ''|*[!0-9]*) _root_rem=0 ;; esac
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); raw=$((raw + d))
            if [ "$_root_rem" -gt 0 ]; then
                [ "$d" -lt 0 ] && d=0; freed=$((freed + d))
            fi
        else
            MEASURED=0
        fi
        _r="$(sed -n 's/.* reaped=\([0-9][0-9]*\) .*/\1/p' <<<"$out" | head -1)"
        case "${_r:-}" in ''|*[!0-9]*) _r=0 ;; esac
        reaped=$((reaped + _r))
        log_line "$out"
        rows="${rows}${rows:+$'\n'}$out"
        # ⛔ THE OWNER'S OWN COUNT, lifted per root and SUMMED (never the first root's, never
        # re-derived from row counts). `reap-duplicate-installs.sh` prints `SUMMARY … candidates=<n>` in
        # BOTH modes, so unlike uv this class CAN answer on an ARMED pass — which is what
        # `candidates_duplicate_install` silently reported as a structural 0 before (the counter was
        # only ever assigned in the dry branch).
        # ⛔ IT BELONGS HERE, IN `reap_dup`'s ROOT LOOP — the block was first pasted at the FIRST
        # `rows="${rows}…"` line in the file, which is `reap_venv`'s: there it incremented a pair of
        # GLOBALS nothing promoted, while `reap_dup` read its OWN `local …=0`, so the armed pass still
        # recorded `candidates_duplicate_install=0` and the test below caught it.
        _dup_sum_line="$(grep -F 'SUMMARY ' <<<"$out" | tail -1)"
        _dup_c="$(kv_field "$_dup_sum_line" candidates)"
        _dup_census="$(kv_field "$_dup_sum_line" census)"
        # ⛔ ONLY A `census=ok` SUMMARY IS A MEASUREMENT. A refused census still PRINTS the line —
        # `reap-duplicate-installs.sh` emits `SUMMARY … families=0 candidates=0 … census=unreadable` —
        # so lifting its `candidates=0` recorded an invented zero for a class that never scanned, which
        # is the same defect as uv one arm over (the previous reviewer's P1 shape, in the sibling).
        case "${_dup_census:-}" in
            ok)
                case "${_dup_c:-}" in
                    ''|*[!0-9]*) : ;;
                    *) _dup_cand=$((_dup_cand + _dup_c)); _dup_ans=$((_dup_ans + 1)) ;;
                esac ;;
            *) : ;;
        esac
        RC_DUP="$(worst_rc "$RC_DUP" "$(delegate_rc worktree "$rc")")"
        if [ "$rc" -gt 0 ]; then
            _dn="$(note_for reap-duplicate-installs.sh "$rc" worktree)"
            case "; $NOTE_DUP;" in *"; $_dn;"*) : ;; *) NOTE_DUP="${NOTE_DUP}${NOTE_DUP:+; }$_dn" ;; esac
        fi
    done <<<"$(printf '%s\n' "$roots" | tr ':' '\n')"
    # Same rule as the abandoned arm: a class that removed nothing does not get to claim the window's
    # `df` change (another lane's file writes move it by GB — measured -5432MB on one pass here).
    if [ "$reaped" = 0 ] && ! is_dry; then
        if [ "$raw" != 0 ]; then
            _dn="nothing removed: the ${raw}MB df change belongs to another process (not attributed)"
            case "; $NOTE_DUP;" in *"; $_dn;"*) : ;; *) NOTE_DUP="${NOTE_DUP}${NOTE_DUP:+; }$_dn" ;; esac
        fi
        freed=0
    fi
    VERDICT_DUP="$(class_verdict "$RC_DUP")"
    DF_DUP_OK="$MEASURED"; RAW_DUP="$raw"
    if is_dry; then FREED_DUP=0; else FREED_DUP="$freed"; fi
    # The DRY count comes from our own sweep below (every `remove` row is a candidate we scanned); an
    # ARMED pass has no rows, so it answers from the owner's SUMMARY tally lifted above.
    # A FULLY-ANSWERED CLASS IS WHAT MAKES THE SUM AN ANSWER: `_dup_ans = _dup_roots` is the same rule
    # the worktree arm applies with `wt_tally_repos = wt_repos`. Short of it the count is `?`, and the
    # class line carries `tally=` so the operator can see WHY (a bare `?` names no cause).
    DUP_TALLY_COVER="${_dup_ans}/${_dup_roots}"
    if ! is_dry && [ "$_dup_ans" -gt 0 ] && [ "$_dup_ans" = "$_dup_roots" ]; then CAND_DUP="$_dup_cand"; HAVE_DUP_CAND=1; fi
    if is_dry; then
        sweep_end=$(( $(now) + DU_BUDGET )); swept=0
        while IFS= read -r line; do
            [[ "$line" == remove* ]] || continue
            path="${line#remove}"
            path="${path#"${path%%[![:space:]]*}"}"
            path="${path%"${path##*[![:space:]]}"}"
            # ⛔ THE ROW IS `remove <path>` AND THE PATH IS THE REST OF THE LINE. Truncating at the first
            # space measured a DIFFERENT directory: a copy under `"/tmp/sp test/root/fam/b"` was sized as
            # `/tmp/sp`, and the class reported a byte figure that was not its work (measured: 200MB per
            # row for candidates holding 12MB).
            path="${path%"${path##*[![:space:]]}"}"
            [[ "$path" == /* ]] || continue
            why="du could not read it (already gone, or unreadable)"
            if [ "$(now)" -ge "$sweep_end" ]; then size="?"; why="du budget exhausted"
            else size="$(du_mb "$path")" || size="?"; fi
            swept=$((swept + 1)); [ $((swept % 25)) -eq 0 ] && heartbeat_lock
            all_c=$((all_c + 1))
            case "$size" in
                ''|*[!0-9]*) cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=duplicate-install (? bytes unmeasured — ${why}) ${path}" ;;
                *) WOULD_DUP=$((WOULD_DUP + size))
                   cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=duplicate-install ${size}MB ${path} (du estimate — never a saving)" ;;
            esac
        done <<<"$rows"
        # ⛔ `0` IS A MEASUREMENT ONLY IF THE DELEGATE ACTUALLY CLASSIFIED. Setting the sentinel
        # unconditionally made a REFUSED dry pass record `candidates_duplicate_install=0` beside
        # `verdict_duplicate_install=fail-closed` — while its two siblings recorded `?` for the same
        # shape. Evidence is a `remove` row we scanned, or the owner's own `census=ok` tally.
        CAND_DUP="$all_c"
        { [ "$all_c" -gt 0 ] || { [ "$_dup_ans" -gt 0 ] && [ "$_dup_ans" = "$_dup_roots" ]; }; } && HAVE_DUP_CAND=1
        [ -n "$cands" ] && log_line "$cands"
        log_line "disk-reaper: class=duplicate-install rc=$RC_DUP verdict=$(class_verdict "$RC_DUP") mode=dry-run candidates=$(_tally_num "$HAVE_DUP_CAND" "$CAND_DUP") would_free_du=${WOULD_DUP}MB (du estimate) freed_df=0MB tally=${DUP_TALLY_COVER}"
    else
        if [ "${DF_DUP_OK:-0}" = 1 ]; then
            log_line "disk-reaper: class=duplicate-install rc=$RC_DUP verdict=$(class_verdict "$RC_DUP") mode=apply freed_df=${FREED_DUP}MB df_raw=${RAW_DUP}MB (df delta) tally=${DUP_TALLY_COVER}"
        else
            log_line "disk-reaper: class=duplicate-install rc=$RC_DUP verdict=$(class_verdict "$RC_DUP") mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero) tally=${DUP_TALLY_COVER}"
        fi
    fi
    return 0
}

# ── class: runner-work (the CI runners' `_work` checkout dirs) ────────────────────────────────
# MEASURED (2026-10-28, cell c1 `vm-efa6cc8fdb974e61b5c054acf41d8846`, 8 cores, 12 GitHub Actions
# runners): `/` at **98% used, 3.5 G free**, and **19 G** in `/opt/gh-runner-x64-{2,4,5,6,7,8}/_work`
# (2.6–4.7 G per runner) left by jobs that had finished or been killed. A runner cleans its own
# `_work/<entry>` only on a NORMAL job end. Sizes were measured; the hand reap of exactly this sink took
# the box 98% → 90% without disturbing a single running job, and `scripts/reap-runner-work.sh` owns that
# rule. This class discovers nothing and deletes nothing: it resolves the globs, runs the owner per
# pass, lifts the owner's own ledger and accounts per FILESYSTEM with a `df` delta — the same split
# every other class uses, and why this file still contains no `rm` on a filesystem path (its suite pins
# that with T6).
#
# ⛔ THE SAFETY GATE IS ONE SENTENCE: an entry is a candidate ONLY when its NEWEST CONTENT is older than
# the floor (`DISK_REAPER_RUNNER_MIN_AGE`, default 3600 s). The IN-ENTRY witness is the checkout's own
# writes; `_work/_temp` (step scripts, command logs) is a SIBLING of `_work/<repo>` and protects nothing
# here, so the mtime is the proof for the entry being deleted and there is no local busy-check on a
# runner to consult, and the owner's header forbids inventing a `pgrep`-shaped one (it would keep every
# dead entry while ANY runner is idle — always, on a 12-runner box — i.e. an inert class that reports
# healthy). The owner re-probes the same question immediately before each removal, so a job that starts
# mid-pass survives.
#
# ⛔ `_work/_tool` AND `_work/_actions` ARE DELIBERATELY RETAINED: they are the runner's cross-job caches,
# so removing them buys a re-download on the NEXT job rather than disk. The owner excludes them BEFORE
# measuring and counts them (`retained=` on the class line), and its suite proves they survive even when
# they are the oldest thing in the tree.

# fs_dev <path> — the filesystem a path lives on (`df` field 1), for the per-filesystem dedupe.
fs_dev() { tb_timeout "$DU_TIMEOUT" "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 {print $1}'; }

# rw_df_targets — ONE existing directory per distinct filesystem the configured globs can land on.
# ⛔ PER FILESYSTEM. A runner farm can straddle two: `/tmp` is a tmpfs on some boxes and part of `/` on
# others, and a single delta taken on the first target would report 0MB for gigabytes reclaimed from the
# second — the defect the venv/worktree classes fixed when `--repo` spanned mounts.
# ⛔ NO GLOB EXPANSION HERE, ON PURPOSE: expanding could match twelve roots on one filesystem and
# re-measure it twelve times. The STATIC prefix (everything before the first metacharacter), walked up to
# something that exists, is the path whose filesystem the roots will live on.
rw_df_targets() {
    local g p dev seen=" "
    for g in $RUNNER_GLOBS; do
        p="${g%%[*?]*}"
        [ -n "$p" ] || p="/"
        # A prefix that is not absolute (a literal `$HOME/...` in the seam, unexpanded) cannot be walked
        # up meaningfully: fall back to HOME, which is where such a glob would land.
        case "$p" in /*) ;; *) p="${HOME:-/}" ;; esac
        while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do p="$(dirname "$p")"; done
        [ -d "$p" ] || p="${HOME:-}"
        [ -d "$p" ] || p="/"
        dev="$(fs_dev "$p")"
        case "$seen" in *" ${dev:-?} "*) continue ;; esac
        seen="$seen${dev:-?} "
        printf '%s\n' "$p"
    done
}

reap_runner_work() {
    local out rc line path size why cands="" rows="" all_c=0 freed=0 raw=0 MEASURED=1 rec=""
    local tgt before after d _rw_line="" _rw_cand="" _rw_roots="" _rw_census="" _rw_reaped=""
    local _rw_retained="" _rw_failed="" _rw_kept="" _rw_why="" _rw_unmeasurable=""
    if [ -z "$RUNNER_WORK_REAPER_PATH" ]; then
        log_line "disk-reaper: ⛔ class=runner-work FAIL-CLOSED — reap-runner-work.sh not found (looked at \$RUNNER_WORK_REAPER, \$HOME/.pi/agent/scripts, and beside this script)"
        NOTE_RW="reap-runner-work.sh not found"; RC_RW=3
        MISCONFIG="${MISCONFIG}${MISCONFIG:+, }runner-work-delegate-missing"
        WANT_RW=0; VERDICT_RW="misconfigured"; DF_RW_OK=1; return 3
    fi
    # df BEFORE, per distinct filesystem. Recorded as `<path>\t<kb>` because bash 3.2 has no associative
    # array and the AFTER pass must be paired with the SAME path it measured.
    while IFS= read -r tgt; do
        [ -n "$tgt" ] || continue
        before="$(free_kb_for_path "$tgt")"
        if [ -n "$before" ]; then rec="${rec}${rec:+
}${tgt}	${before}"; else MEASURED=0; fi
    done <<<"$(rw_df_targets)"
    # The globs travel as the OWNER's seam (REAP_RW_GLOBS) and the explicit-vs-default fact as
    # REAP_RW_EXPLICIT, because that flag is what turns "this box has no runners" (a measured empty
    # population) into "the operator asserted a layout that is not there" (a refusal). `env` keeps both
    # per-invocation: the pass's own environment is never mutated by a class.
    run_class env REAP_RW_GLOBS="$RUNNER_GLOBS" REAP_RW_EXPLICIT="$RUNNER_GLOBS_EXPLICIT" \
              bash "$RUNNER_WORK_REAPER_PATH" "$(mode_flag)" --min-age "$RUNNER_MIN_AGE"
    out="$CLASS_OUT"; rc="$CLASS_RC"
    # df AFTER, paired with each BEFORE by path.
    while IFS="	" read -r tgt before; do
        [ -n "$tgt" ] || continue
        after="$(free_kb_for_path "$tgt")"
        if [ -n "$before" ] && [ -n "$after" ]; then
            d=$(( (after - before) / 1024 )); raw=$((raw + d))
            [ "$d" -lt 0 ] && d=0; freed=$((freed + d))
        else
            MEASURED=0
        fi
    done <<<"$rec"
    log_line "$out"
    rows="$out"
    # ── the owner's own ledger, lifted (never re-derived) ───────────────────────────────────────
    _rw_line="$(grep -F 'SUMMARY class=runner-work' <<<"$out" | tail -1)"
    _rw_census="$(kv_field "$_rw_line" census)"
    _rw_roots="$(kv_field "$_rw_line" roots)"
    _rw_cand="$(kv_field "$_rw_line" candidates)"
    _rw_reaped="$(kv_field "$_rw_line" reaped)"
    _rw_retained="$(kv_field "$_rw_line" retained)"
    _rw_kept="$(kv_field "$_rw_line" kept)"
    _rw_failed="$(kv_field "$_rw_line" failed)"
    # The eighth field — the one the lift used to drop. Carried, never re-derived: the owner is the only
    # component that can say which entries its walk could not read.
    _rw_unmeasurable="$(kv_field "$_rw_line" unmeasurable)"
    case "${_rw_reaped:-}" in ''|*[!0-9]*) _rw_reaped=0 ;; esac
    case "${_rw_unmeasurable:-}" in
        ''|*[!0-9]*) : ;;                       # unanswered: `RW_UNMEAS` stays `?`, never an invented 0
        *) RW_UNMEAS="$_rw_unmeasurable"
           # A nonzero tally is NAMED in the note, because it is a decision an operator must be able to
           # find without knowing the field exists: these entries were KEPT for want of an answer.
           [ "$RW_UNMEAS" -gt 0 ] && NOTE_RW="${NOTE_RW}${NOTE_RW:+; }${RW_UNMEAS} entr$( [ "$RW_UNMEAS" = 1 ] && printf 'y' || printf 'ies') KEPT as unreadable (the bounded walk could not answer, which is never proof of death); see unmeasurable_runner_work" ;;
    esac
    # ⛔ AN EXPLICIT GLOB LIST THAT MATCHED NOTHING IS `misconfigured`, NEVER A MEASURED ZERO — the same
    # rule (and the same shape) as `venv-no-repo`: a class that scanned NOTHING is not a pass, and the
    # remedy is different from "the delegate ran and could not work". The owner only reports this for a
    # glob list an operator SET; the DEFAULT globs matching nothing is a box with no runners, which IS a
    # measurement (`roots=0`) and must not paint an hourly alarm on a healthy box.
    if [ "$_rw_census" = "no-roots" ]; then
        log_line "disk-reaper: ⛔ class=runner-work FAIL-CLOSED — no directory matched DISK_REAPER_RUNNER_GLOBS ('$RUNNER_GLOBS'), and it was set EXPLICITLY; a class that scans nothing is NOT a pass"
        NOTE_RW="no runner _work root matched DISK_REAPER_RUNNER_GLOBS"; RC_RW=3
        MISCONFIG="${MISCONFIG}${MISCONFIG:+, }runner-work-no-root"
        WANT_RW=0; VERDICT_RW="misconfigured"; DF_RW_OK=1; return 3
    fi
    # ⛔ THE COUNT IS A MEASUREMENT ONLY WHEN THE OWNER ANSWERED IT: `census=ok` AND a numeric
    # `candidates=`. Anything else is `?` (a refusal, a killed sweep, a truncated SUMMARY) — never the
    # initialised 0. The owner prints the SUMMARY in BOTH modes, so an ARMED pass answers a real count
    # instead of the structural 0 the worktree arm had to fix (#4529).
    if [ "$_rw_census" = "ok" ]; then
        case "${_rw_cand:-}" in
            ''|*[!0-9]*) : ;;
            *) CAND_RW="$_rw_cand"; HAVE_RW_CAND=1 ;;
        esac
    fi
    # ⛔ NOTHING REMOVED MEANS THE DELTA IS NOT OURS. Another lane (or a runner finishing a job, or the
    # runner's own cleanup) moves `df` inside the window; crediting it would report a reclaim this class
    # did not cause — the false credit `df`-instead-of-`du` was adopted to stop, arriving through the
    # other door. The observation is still reported, AS an observation (`df_raw`), and named in the note.
    if [ "$_rw_reaped" = 0 ] && ! is_dry; then
        if [ "$raw" != 0 ]; then
            _rw_why="nothing removed: the ${raw}MB df change belongs to another process (not attributed)"
            NOTE_RW="${NOTE_RW}${NOTE_RW:+; }$_rw_why"
        fi
        freed=0
    fi
    RC_RW="$(worst_rc "$RC_RW" "$(delegate_rc runner-work "$rc")")"
    if [ "$rc" -gt 0 ]; then
        _rw_why="$(note_for reap-runner-work.sh "$rc")"
        case "; ${NOTE_RW:-};" in *"; $_rw_why;"*) : ;; *) NOTE_RW="${NOTE_RW}${NOTE_RW:+; }$_rw_why" ;; esac
    fi
    VERDICT_RW="$(class_verdict "$RC_RW")"
    DF_RW_OK="$MEASURED"; RAW_RW="$raw"
    if is_dry; then FREED_RW=0; else FREED_RW="$freed"; fi
    # The owner's `candidates=` is the count; the `REAP` rows carry the BYTES, so they are scanned for the
    # would-free figure and the named list. ⛔ A row whose size the owner could not measure (`?`) is still
    # a CANDIDATE — `continue`-ing on a non-numeric size is how a class with real work reports
    # `candidates=0 ok=1`, the unmeasured-reads-as-nothing false PASS the venv arm already removed.
    if is_dry; then
        while IFS= read -r line; do
            case "$line" in
                "REAP "*)
                    size="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+MB$/) {print $i; exit}}')"
                    # The path is the REMAINDER of the line after the verb, the reason and the size —
                    # not `$NF`, which truncated a path containing a space (the worktree arm's defect).
                    path="$(printf '%s' "$line" | sed -E 's/^ *REAP +[^ ]+ +[^ ]+ +//')"
                    size="${size%MB}"
                    all_c=$((all_c + 1))
                    case "$size" in
                        ''|*[!0-9]*) cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=runner-work (? bytes unmeasured — the owner could not size it) ${path}" ;;
                        *) WOULD_RW=$((WOULD_RW + size))
                           cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=runner-work ${size}MB ${path} (du estimate; no content written for >= ${RUNNER_MIN_AGE}s — _tool/_actions are retained whatever their age)" ;;
                    esac ;;
            esac
        done <<<"$rows"
        # The tally is authoritative when the owner answered; the row count is the fallback for a SUMMARY
        # that did not (a truncated line). Never an invented 0.
        [ "$HAVE_RW_CAND" = 1 ] || { CAND_RW="$all_c"; [ "$all_c" -gt 0 ] && HAVE_RW_CAND=1; }
        [ -n "$cands" ] && log_line "$cands"
        # ⛔ `kept=` IS NOT A DECISION AND `unmeasurable=` IS AN ABSTENTION — both are on the line, so an
        # operator reading the class line alone can tell "ten entries were written within the floor" from
        # "ten entries could not be read at all" (the second is a broken probe, not a healthy box).
        log_line "disk-reaper: class=runner-work rc=$RC_RW verdict=$VERDICT_RW mode=dry-run candidates=$(_tally_num "$HAVE_RW_CAND" "$CAND_RW") would_free_du=${WOULD_RW}MB (du estimate) freed_df=0MB min_age=${RUNNER_MIN_AGE}s retained=${_rw_retained:-?} kept=$(_tally_num "$HAVE_RW_CAND" "${_rw_kept:-?}") unmeasurable=$RW_UNMEAS roots=${_rw_roots:-?}"
    else
        if [ "${DF_RW_OK:-0}" = 1 ]; then
            log_line "disk-reaper: class=runner-work rc=$RC_RW verdict=$VERDICT_RW mode=apply freed_df=${FREED_RW}MB df_raw=${RAW_RW}MB (df delta) candidates=$(_tally_num "$HAVE_RW_CAND" "$CAND_RW") reaped=$(_tally_num "$HAVE_RW_CAND" "${_rw_reaped:-?}") retained=${_rw_retained:-?} unmeasurable=$RW_UNMEAS min_age=${RUNNER_MIN_AGE}s roots=${_rw_roots:-?}"
        else
            log_line "disk-reaper: class=runner-work rc=$RC_RW verdict=$VERDICT_RW mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero) candidates=$(_tally_num "$HAVE_RW_CAND" "$CAND_RW") reaped=$(_tally_num "$HAVE_RW_CAND" "${_rw_reaped:-?}") retained=${_rw_retained:-?} unmeasurable=$RW_UNMEAS min_age=${RUNNER_MIN_AGE}s roots=${_rw_roots:-?}"
        fi
    fi
    return 0
}

# ── the pass ────────────────────────────────────────────────────────────────────────────────────
MODE_TEXT=dry-run; is_dry || MODE_TEXT=apply
acquire_lock
: >"$LOG" 2>/dev/null || true
# ⛔ THE FALLBACK'S OWN LOCK IS NOT THE ONLY ONE THAT MATTERS (#2443 review): a pass that started
# while the configured dir was writable may still be running and holding THAT lock. Runs for EVERY pass
# (see check_peer_locks' own docblock — a healthy pass takes the configured lock and a fallback pass the
# canonical one, so the healthy side must check too); with one fixed canonical path that is a single
# stat, not an enumeration, so no hermeticity cost.
check_peer_locks
{
    log_line "disk-reaper: pass start mode=$MODE_TEXT only=$ONLY aged=${WT_AGED_DAYS}d venv_min_age=${VENV_MIN_AGE}s pid=$$"
    # The bounding MECHANISM is disclosed only when it is not GNU `timeout`: on a host that has it,
    # this pass's report is byte-for-byte what it was before #2046 (and the mechanism is in the pass
    # record either way). On macOS this is the line that says the bound is real rather than a
    # fail-closed no-op — the absence is visible WHERE IT MATTERS, without being fatal.
    if [ "${TB_TIMEOUT_KIND:-}" != "timeout" ]; then
        log_line "disk-reaper: watchdog=$TB_TIMEOUT_KIND — $(tb_watchdog_description); a timeout is still reported as rc=124 (fail-closed)"
    fi
    log "==== pass start mode=$MODE_TEXT only=$ONLY repos=${REPOS:-<resolved per class>} ===="
    log "watchdog: ${TB_TIMEOUT_KIND:-unknown} ($(tb_watchdog_description))"
    # The fallback is said in the PASS LOG too, not only on stderr before it: the log is the artifact an
    # operator reads after the fact, and "which filesystem held this pass's lock" decides whether its
    # `df` deltas can be credited to it (agent-infra#2443).
    [ -n "$STATE_DIR_PRIMARY_NOTE" ] && log_line "disk-reaper: ⚠ state dir fallback — configured $STATE_DIR_PRIMARY is unusable ($STATE_DIR_PRIMARY_NOTE); lock/log/scratch/record on $STATE_DIR, and the delegates were given it too"
    log "delegates: cache=${CACHE_REAPER_PATH:-MISSING} venv=${VENV_REAPER_PATH:-MISSING} worktree=${WORKTREE_REAPER_PATH:-MISSING} abandoned=${ABANDONED_WT_REAPER_PATH:-MISSING} dup-install=${DUP_INSTALL_REAPER_PATH:-MISSING} runner-work=${RUNNER_WORK_REAPER_PATH:-MISSING}"
} | tee -a "$LOG"

# Heartbeat after each class: a pass that is making progress must never be aged out of its own lock.
want_class uv       && { WANT_UV=1;   reap_uv;       heartbeat_lock; }
want_class venv     && { WANT_VENV=1; reap_venv;     heartbeat_lock; }
want_class worktree && { WANT_WT=1;   reap_worktree; heartbeat_lock; }
# ⛔ LAST, ON PURPOSE. It is the newest class and the least load-bearing on a full disk: uv and the two
# worktree arms free the most, and the duplicate-install owner is the one most likely to fail closed
# (it refuses to act without an idle proof), so it must not be the reason the bigger arms never ran.
want_class duplicate-install && { WANT_DUP=1; reap_dup; heartbeat_lock; }
# runner-work is last of all for the same reason: it is the only class whose candidates live OUTSIDE the
# fleet's own trees, and its mtime gate is the most conservative in the pass. It is in the DEFAULT list
# because the measured box GAINED five runners in a week and nothing measured the sink — a class an
# operator has to remember to enable is the hole this class closes.
want_class runner-work && { WANT_RW=1; reap_runner_work; heartbeat_lock; }

# Verdict. ⛔ ONE ordering, expressed ONCE: 3 fail-closed (a delegate's own 3, "could not run", or a
# class that could not be SET UP at all — MISCONFIG) > 4 removal-failed > 6 deferred > 5 over-bound > 0.
# A class that could not be set up is 3 regardless of what the others did: an absent delegate is not a
# busy box. Everything else folds through worst_rc, whose `_rc_rank` ranks an UNRECOGNISED code as the
# most severe rather than as ok (allow-list polarity).
verdict=0
if [ -n "$MISCONFIG" ]; then
    verdict=3
else
    for rc in "$RC_UV" "$RC_VENV" "$RC_WT" "$RC_DUP" "$RC_RW"; do
        # ⛔ 5 IN AN APPLY PASS RANKS WITH A FAIL-CLOSED CLASS (3). In a dry run, "over bound" is the
        # dry run doing its job; in an ARMED pass the same 5 means a class ended BELOW its owner's
        # stated floor and nothing was reclaimed — the condition the floor exists to surface, so it must
        # not be ranked as merely informational (#2156's false PASS: `rc=0 verdict=ok` on a short box).
        [ "$rc" = 5 ] && ! is_dry && rc=3
        verdict="$(worst_rc "$verdict" "$rc")"
    done
    if [ "$verdict" = 0 ] && is_dry \
       && { [ "$CAND_UV" -gt 0 ] || [ "$CAND_VENV" -gt 0 ] || [ "$CAND_WT" -gt 0 ] || [ "$CAND_DUP" -gt 0 ] || [ "$CAND_RW" -gt 0 ]; }; then
        verdict=5
    fi
fi

TOTAL=$(( FREED_UV + FREED_VENV + FREED_WT + FREED_DUP + FREED_RW ))
UNMEASURED=""
[ "${DF_UV_OK:-0}"  = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }uv"
[ "${DF_VENV_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }venv"
[ "${DF_WT_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }worktree"
[ "${DF_DUP_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }duplicate-install"
[ "${DF_RW_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }runner-work"
# ⛔ AN UNANSWERABLE TOTAL IS `?`, NOT THE INITIALISED ZERO. `CAND_*` are initialised to 0 and are
# only lifted to a sentinel on the CLASS line, so a fail-closed class printed `candidates=?` on its own
# line and the pass-end line then summed the zeroes into a confident `candidates=0` — the last line of
# the pass, and the one an operator reads to decide whether the sweep had anything to do. That is
# verbatim the "reads as a passing pass" failure this report exists to remove, the same shape T59 pins
# for the class line. One vocabulary: a class that was NOT SELECTED contributes nothing; a class that
# ran with no tally makes the TOTAL unknown. Computed once, before either the line or the log uses it,
# so the two surfaces cannot disagree again.
CAND_TOTAL="$(( CAND_UV + CAND_VENV + CAND_WT + CAND_DUP + CAND_RW ))"
{ [ "${WANT_VENV:-0}" != 1 ] || [ "${HAVE_VENV_CAND:-0}" = 1 ]; } || CAND_TOTAL="?"
{ [ "${WANT_WT:-0}" != 1 ] || [ "${HAVE_WT_CAND:-0}" = 1 ]; } || CAND_TOTAL="?"
{ [ "${WANT_RW:-0}" != 1 ] || [ "${HAVE_RW_CAND:-0}" = 1 ]; } || CAND_TOTAL="?"
# ⛔ A CLASS THAT MEASURED NOTHING CANNOT CONTRIBUTE A CONFIDENT `0` TO THE TOTAL — for ANY reason:
# could not be SET UP (`misconfigured`), the delegate RAN and failed closed, or an armed pass with no
# tally to lift. One rule over all five classes, so a sixth cannot be added and then forgotten here.
# ⛔ TWO OPPOSITE WAYS FOR A CLASS TO LOOK "NOT SELECTED", and only ONE of them is harmless:
#   · `--only venv` leaves the others `WANT_*=0` because they never RAN — the `not-run` state, which is
#     not a hole in the total. Requiring `want && have` on every class made the total `?` on EVERY
#     single-class pass (`--only venv` printing `candidates=?` on a pass whose venv arm answered), so
#     the sentinel cried wolf on the one surface that must stay trustworthy.
#   · a SETUP-FAILURE arm ALSO resets `WANT_*=0` (`VERDICT_*=misconfigured`), and that class measured
#     nothing. Reading `WANT` alone therefore reports it as "never selected" and lets an invented `0`
#     back into the total — the very defect this loop exists to stop, one state over.
# So "was selected" is `WANT=1` **or** `VERDICT=misconfigured`, and a selected class with no measurement
# taints the sum. Polarity: deselected is silent, selected-but-unmeasured is `?`.
for _cv in VENV WT UV DUP RW; do
    eval "_cw=\${WANT_$_cv:-0}; _ch=\${HAVE_${_cv}_CAND:-0}; _cv_verdict=\${VERDICT_$_cv:-not-run}"
    { [ "$_cw" = 1 ] || [ "$_cv_verdict" = misconfigured ]; } || continue
    [ "$_ch" = 1 ] || CAND_TOTAL="?"
done
if is_dry; then
    log_line "disk-reaper: pass end mode=dry-run verdict=$verdict freed_df=0MB would_free_du=$(( WOULD_UV + WOULD_VENV + WOULD_WT + WOULD_DUP + WOULD_RW ))MB candidates=$CAND_TOTAL — NOTHING was removed"
else
    # third arg: was the class SELECTED at all? not-run is a third state, distinct from both
    # "measured zero" and "unmeasured".
    _pc() { [ "${3:-1}" = 1 ] || { printf 'not-run'; return 0; }
            [ "${1:-0}" = 1 ] && printf '%sMB' "$2" || printf 'unmeasured'; }
    log_line "disk-reaper: pass end mode=apply verdict=$verdict $([ -n "$UNMEASURED" ] && printf 'freed_df=unmeasured (measured classes: %sMB)' "$TOTAL" || printf 'freed_df=%sMB' "$TOTAL") (uv=$(_pc "${DF_UV_OK:-0}" "$FREED_UV" "$WANT_UV") venv=$(_pc "${DF_VENV_OK:-0}" "$FREED_VENV" "$WANT_VENV") worktree=$(_pc "${DF_WT_OK:-0}" "$FREED_WT" "$WANT_WT") duplicate-install=$(_pc "${DF_DUP_OK:-0}" "$FREED_DUP" "$WANT_DUP") runner-work=$(_pc "${DF_RW_OK:-0}" "$FREED_RW" "$WANT_RW"))${UNMEASURED:+ — df could not measure: $UNMEASURED (not a measured zero)}"
fi

# ── record it ───────────────────────────────────────────────────────────────────────────────────
# `ok` is the RECORD's verdict, and it is deliberately NOT "the unit is green". A dry run that found
# work did its job (ok=1). An APPLY pass that ended below a class's stated floor did NOT: it exits 3
# (see the verdict loop) and the record says `ok=0 rc=3 verdict_<class>=fail-closed` — the #2156 false
# PASS was `ok=1 rc=0 verdict_venv=ok detail="... exited 5"` on a cell that was short of disk. A
# DEFERRAL (6) is also ok=0: the unit stays green because the alarm channel is the record, not the
# unit's colour (#2036).
OK=0
{ [ "$verdict" = 0 ] || { [ "$verdict" = 5 ] && is_dry; }; } && OK=1
DETAIL=""
[ -n "$NOTE_UV" ] && DETAIL="$NOTE_UV"
[ -n "$NOTE_VENV" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_VENV"
[ -n "$NOTE_WT" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_WT"
[ -n "$NOTE_DUP" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_DUP"
[ -n "$NOTE_RW" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_RW"
[ -n "$MISCONFIG" ] && DETAIL="${DETAIL}${DETAIL:+; }cannot run: ${MISCONFIG}"
[ -n "$UNMEASURED" ] && DETAIL="${DETAIL}${DETAIL:+; }df could not measure the reclaim for: ${UNMEASURED} (not a measured zero)"
# The fallback is part of the VERDICT, not a footnote beside it: a reader who sees a record must be
# able to tell that it came from a pass whose configured state dir was unusable (agent-infra#2443).
[ -n "$STATE_DIR_PRIMARY_NOTE" ] && DETAIL="${DETAIL}${DETAIL:+; }state dir $STATE_DIR_PRIMARY was unusable (${STATE_DIR_PRIMARY_NOTE}) — this pass ran on $STATE_DIR, and so did its delegates"
[ -n "$DETAIL" ] || DETAIL="ok"

# ⛔ THE RECORD GOES TO THE CONFIGURED PATH WHENEVER IT CAN (#2443). A fallback pass may have just FREED
# the space that made the configured dir unwritable, and the supervisor reads
# $DISK_REAPER_STATE_DIR/disk-reaper.status — a record only the fallback can see is a record the alarm
# channel cannot read. One record, one verdict (T45): the canonical dir is preferred, the dir this pass
# ran on is the fallback, and BOTH ARE NEVER WRITTEN.
record_body() {
    printf 'epoch=%s\n' "$(now)"
    printf 'iso=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'mode=%s\n' "$MODE_TEXT"
    printf 'ok=%s\n' "$OK"
    printf 'rc=%s\n' "$verdict"
    printf 'classes=%s\n' "$ONLY"
    printf 'watchdog=%s\n' "${TB_TIMEOUT_KIND:-unknown}"
    printf 'freed_mb=%s\n' "$TOTAL"
    printf 'freed_mb_unmeasured=%s\n' "$UNMEASURED"
    # In a dry run nothing was removed, so 0 is measured, not unmeasured.
    _rc() { [ "${3:-1}" = 1 ] || { printf 'not-run'; return 0; }
             { [ "${1:-0}" = 1 ] || is_dry; } && printf '%s' "$2" || printf 'unmeasured'; }
    printf 'freed_mb_uv=%s\n' "$(_rc "${DF_UV_OK:-0}" "$FREED_UV" "$WANT_UV")"
    printf 'freed_mb_venv=%s\n' "$(_rc "${DF_VENV_OK:-0}" "$FREED_VENV" "$WANT_VENV")"
    printf 'freed_mb_worktree=%s\n' "$(_rc "${DF_WT_OK:-0}" "$FREED_WT" "$WANT_WT")"
    printf 'freed_mb_duplicate_install=%s\n' "$(_rc "${DF_DUP_OK:-0}" "$FREED_DUP" "$WANT_DUP")"
    printf 'freed_mb_runner_work=%s\n' "$(_rc "${DF_RW_OK:-0}" "$FREED_RW" "$WANT_RW")"
    printf 'would_free_mb_uv=%s\n' "$WOULD_UV"
    printf 'would_free_mb_venv=%s\n' "$WOULD_VENV"
    printf 'would_free_mb_worktree=%s\n' "$WOULD_WT"
    printf 'would_free_mb_duplicate_install=%s\n' "$WOULD_DUP"
    printf 'would_free_mb_runner_work=%s\n' "$WOULD_RW"
    printf 'candidates_uv=%s\n' "$(_class_rec "${VERDICT_UV:-not-run}" "${WANT_UV:-0}" "${HAVE_UV_CAND:-0}" "$CAND_UV")"
    printf 'classified_venv=%s\n' "$(_tally_rec "${WANT_VENV:-0}" "${HAVE_VENV_TALLY:-0}" "${CLASSIFIED_VENV:-}")"
    printf 'preserved_venv=%s\n' "$(_tally_rec "${WANT_VENV:-0}" "${HAVE_VENV_TALLY:-0}" "${PRESERVED_VENV:-}")"
    printf 'candidates_venv=%s\n' "$(_tally_rec "${WANT_VENV:-0}" "${HAVE_VENV_CAND:-0}" "${CAND_VENV:-}")"
    printf 'tally_venv=%s\n' "$([ "${WANT_VENV:-0}" = 1 ] && printf '%s' "${VENV_TALLY_COVER:-0/0}" || printf 'not-run')"
    printf 'tally_worktree=%s\n' "$([ "${WANT_WT:-0}" = 1 ] && printf '%s' "${WT_TALLY_COVER:-0/0}" || printf 'not-run')"
    # ⛔ An UNANSWERABLE class is recorded as such, never as a measured 0: a record reading
    # `verdict_worktree=not-run` beside `classified_worktree=0 preserved_worktree=0
    # preserved_reasons_worktree=none` is self-contradicting, and on a fail-closed abort (gh down,
    # `ps` empty, lock held) it is the shape that reads "healthy, nothing to do" for a pass that
    # produced no answer at all.
    printf 'candidates_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_CAND:-0}" "$CAND_WT")"
    printf 'classified_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${CLASSIFIED_WT:-}")"
    printf 'preserved_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${PRESERVED_WT:-}")"
    printf 'preserved_reasons_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${REASONS_WT:-}")"
    # The delegate's deferred REMOVALS, on their own field: an armed pass whose budget ran out mid
    # removal records `removed=0 failed=0 late_preserved=0`, which reads as "nothing to do" unless
    # this is visible. `?`/`not-run` polarity is the same as every other class field.
    printf 'deferred_remove_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${DEFERRED_REMOVE_WT:-}")"
    printf 'main_proof=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${PROOF_WT:-}")"
    printf 'pr_merged=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${PRM_WT:-}")"
    # The delegate's OWN answer (#3041): `verdict_worktree=` is the exit-code reading and stays what it
    # was; this is what the reaper said about ITSELF, so "reclaimed nothing on a full box" is visible in
    # the status file instead of only inside the echoed delegate text.
    printf 'delegate_verdict_worktree=%s\n' "$(_tally_rec "${WANT_WT:-0}" "${HAVE_WT_TALLY:-0}" "${DELEGATE_VERDICT_WT:-}")"
    printf 'candidates_duplicate_install=%s\n' "$(_class_rec "${VERDICT_DUP:-not-run}" "${WANT_DUP:-0}" "${HAVE_DUP_CAND:-0}" "$CAND_DUP")"
    # ⛔ THIS CLASS'S COUNTER HAS TWO SPELLINGS, AND THEY ARE THE SAME NUMBER. Every sibling publishes
    # `candidates_<key>`, and the brief that added this class names it `cand_runner_work`; both are written
    # here from the SAME expression on adjacent lines, so they cannot disagree (the defect two surfaces of
    # one pass can produce is a STALE or re-derived value, not an alias of one expression). Either name
    # answers "how many candidates did runner-work see", which is the only reason the field exists.
    printf 'candidates_runner_work=%s\n' "$(_class_rec "${VERDICT_RW:-not-run}" "${WANT_RW:-0}" "${HAVE_RW_CAND:-0}" "$CAND_RW")"
    # ⛔ THE EIGHTH SUMMARY FIELD (#3057 review): the owner answers `unmeasurable=<n>` — entries KEPT
    # because its bounded walk could not answer — and the entry point lifted the other seven and dropped
    # it, so the one "could not decide" outcome had no channel in the record at all. Same polarity as
    # `_class_rec`: a class that could not be SET UP answers `?` (it measured nothing), a class this pass
    # did not SELECT answers `not-run`, and otherwise the owner's own number (or `?` if it did not answer).
    _unmeas_rec() {
        case "${VERDICT_RW:-not-run}" in
            misconfigured) printf '?' ;;
            not-run)       printf 'not-run' ;;
            *) [ "${WANT_RW:-0}" = 1 ] && printf '%s' "$RW_UNMEAS" || printf 'not-run' ;;
        esac
    }
    printf 'unmeasurable_runner_work=%s\n' "$(_unmeas_rec)"
    printf 'cand_runner_work=%s\n' "$(_class_rec "${VERDICT_RW:-not-run}" "${WANT_RW:-0}" "${HAVE_RW_CAND:-0}" "$CAND_RW")"
    # The class's own cause channel. `detail=` still carries it joined with its siblings (the supervisor
    # prints one line); this field exists so a reader can ask "why is runner-work not ok" without
    # parsing a shared sentence — and `--print-status` prints it, because a field no reader prints does
    # not exist.
    printf 'note_runner_work=%s\n' "$NOTE_RW"
    printf 'verdict_uv=%s\n' "$VERDICT_UV"
    printf 'verdict_venv=%s\n' "$VERDICT_VENV"
    printf 'verdict_worktree=%s\n' "$VERDICT_WT"
    printf 'verdict_duplicate_install=%s\n' "$VERDICT_DUP"
    printf 'verdict_runner_work=%s\n' "$VERDICT_RW"
    # empty=no repo was skipped; otherwise `<repo>[<reason>], ...` — the subject the class verdict
    # never had (#2443).
    printf 'skipped_worktree=%s\n' "$SKIPPED_WT"
    printf 'repos=%s\n' "$(printf '%s' "$REPOS" | tr '\n' ',')"
    # ⛔ THE NORMAL RECORD IS UNCHANGED (#2443): BOTH fields appear only when this pass actually fell
    # back, so a healthy box's artifact stays byte-for-byte what every existing reader already parses.
    # An UNCONDITIONAL `state_dir=` was the first draft and it is wrong: it adds a line to the record of
    # every healthy pass on every box, to say where a pass ran when the answer is the configured path
    # the reader already holds. `state_dir` is where THIS pass's lock/log/scratch/record lived;
    # `state_dir_primary` is the configured dir it could not use.
    if [ -n "$STATE_DIR_PRIMARY_NOTE" ]; then
        printf 'state_dir=%s\n' "$STATE_DIR"
        printf 'state_dir_primary=%s\n' "$STATE_DIR_PRIMARY"
    fi
    printf 'detail=%s\n' "$DETAIL"
    return 0
}

write_record() { # <dir> — 0 when the record was written and renamed into place
    local d="$1" tmp
    tmp="$d/disk-reaper.status.tmp.$$"
    record_body >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$d/disk-reaper.status" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

RECORD_DIR=""
if [ "$STATE_DIR_PRIMARY" != "$STATE_DIR" ] && state_dir_writable "$STATE_DIR_PRIMARY"; then
    RECORD_DIR="$STATE_DIR_PRIMARY"
else
    RECORD_DIR="$STATE_DIR"
fi
write_record "$RECORD_DIR" 2>/dev/null \
    || { if [ "$RECORD_DIR" != "$STATE_DIR" ] && write_record "$STATE_DIR"; then
             log_line "disk-reaper: ⚠ cannot write the pass record to $RECORD_DIR — it is at $STATE_DIR/disk-reaper.status instead"
         else
             RECORD_DIR=""
         fi; }
[ -z "$RECORD_DIR" ] && { log_line "disk-reaper: ⛔ cannot write the pass record $STATUS — the PREVIOUS record still stands (readers will keep seeing it until it goes stale); this pass's exit code is the only witness to this run"
             # ⛔ 5 AND 6 ARE GREEN BECAUSE THE RECORD CARRIES THE ALARM. With no record there is no alarm
             # channel left, so any non-3 verdict becomes 4 (a filesystem problem) instead of exiting green
             # over an un-writable state dir.
             [ "$verdict" = 3 ] || verdict=4; }
log "==== pass end mode=$MODE_TEXT verdict=$verdict freed_mb=$TOTAL uv=$FREED_UV venv=$FREED_VENV worktree=$FREED_WT duplicate_install=$FREED_DUP runner_work=$FREED_RW candidates=$CAND_TOTAL ===="

exit "$verdict"
