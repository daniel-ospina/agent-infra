#!/usr/bin/env bash
# reap-lane-venvs.sh — reclaim a lane's `.venv` when (and only when) the lane is provably gone (#1932).
#
# WHY THIS EXISTS
# A `.venv` is a PRIVATE COPY of Python plus every library the project needs. It is a build artifact:
# it can always be recreated from `uv.lock`. Lanes now run the test suite (`uv sync --extra embeddings
# --extra parity`, per AGENTS.md), `uv` writes `.venv` INSIDE the worktree, and the fleet runs one
# worktree per lane — so every lane materialises its own env and NOTHING removes it. MEASURED on
# lane-1 (2026-10-17): 5 lane venvs = 7.3 GB deduplicated on a 32 GB disk, one of them 5.8 GB because
# its lane installed a broader extra set. ⛔ THAT DEAD RESIDUE IS WHY THE BOX RAN OUT OF *DISK*; it is not
# why the box held ~4 lanes — RAM (~0.9 GB/lane) sets the lane count, and N LIVE lanes need N x ~1.1 GB
# whatever the reaper does. Removing dead residue returns disk headroom the live lanes need; it cannot
# raise the per-lane ceiling (see docs/ops/disk-reaper.md, "What this does NOT do", #2159).
#
# TWO HALVES, because a venv has two ways of outliving its lane:
#   * REAP ON EXIT (`--worktree PATH`) — the lane RUNNER calls this from its own teardown. It KNOWS
#     the lane is done, so nothing has to be inferred. This is the primary half; a runner that exits
#     normally cannot leave a venv behind.
#   * GC (`--gc`, the default) — a sweep for ORPHANS: worktrees whose lane ended without teardown
#     (killed session, reboot, an operator's `tmux kill-session`). Here the lane's death must be
#     INFERRED, so every removal rests on positive evidence.
#
# THE POLICY CONTRACT — the part that must not be got wrong
# A venv is removed ONLY when ALL of these hold:
#   1. not the repo's MAIN checkout        — the main checkout is the controller's, not a lane's.
#   2. not the worktree the reaper runs in — the same self-protection `pi-reap-worktrees.sh` uses; a
#                                            GC run FROM a lane would otherwise reap that lane's env.
#   3. `<worktree>/.venv` is a REAL DIRECTORY — a symlinked `.venv` (or any non-directory) is never
#                                            touched, so no delete can ever follow a link out of the
#                                            worktree. (It is also what keeps this script away from
#                                            the `uv` download cache: the delete target is a directory
#                                            named `.venv` at a worktree root, nothing else.)
#   4. NO LIVE HOLDER, proven by three mechanical witnesses (below) — never by "the directory looks
#                                                                       old".
#   5. GC only: the venv is older than `REAP_VENV_MIN_AGE_SECONDS` (default 1800) — the floor that
#      covers the window between `git worktree add` and the first process binding to it.
#
# LIVENESS IS MECHANICAL — three witnesses, one fresh read each, all fail-closed:
#   * LIVE-TMUX-PANE: a tmux pane whose `pane_current_path` resolves INSIDE the worktree. The fleet
#                     spawns every lane into its own tmux session, so this is the witness that fires
#                     for a lane whose agent is merely between turns (measured on cell-2: every live
#                     lane is a pane whose cwd is its worktree).
#   * LIVE-CWD:       any process whose cwd is inside the worktree (`lsof -a -d cwd`, or `/proc/*/cwd`
#                     where lsof is absent). Catches a `bash -c 'cd $wt && pytest'` whose argv never
#                     names the path.
#   * LIVE-ARGV:      any process whose command line names the worktree — catches a process that
#                     `cd`'d elsewhere after starting (`$wt/.venv/bin/python`).
#   The reaper's OWN process ancestry is excluded from all three (its cwd IS a worktree, and the pane
#   it is called from is its ancestor): without that exclusion `--worktree` mode could never reap.
#
# FAIL CLOSED ON AMBIGUITY — this is the asymmetry the issue names: a wrongly deleted env costs a lane
# a multi-minute re-sync, but deleting the env of a lane that is MID-TEST is the failure the whole
# design exists to avoid. So: an unreadable `ps`, an unlistable tmux, an unavailable cwd probe, an
# unstatable age, or an unresolvable git dir => KEEP, and (for a probe that makes the pass unsound)
# exit 3 with nothing removed at all. A degraded cwd probe is abortive by default and only tolerable
# with `REAP_VENV_ALLOW_DEGRADED_CWD=1` set EXPLICITLY, in which case the pass says so on every line.
#
# BYTE ACCOUNTING — two numbers, because they answer different questions and only one is honest alone
#   * `du` per venv: the BLOCKS THE TREE OCCUPIES — an UPPER BOUND on what removal frees, never a
#     figure. Whether it over-reports is PER MACHINE, not universal (#1851 falsified the old claim
#     here): a venv shares cache blocks only where the filesystem does — APFS clonefile (du 22.0 MB
#     vs df used +0.6 MB, nlink=1), a hardlink into the cache (du 5,704 MB vs 186 MB released,
#     nlink>1), or NEITHER (du 5,647 MiB vs df 5.90 GB, ratio 1.004 — du is accurate there). Measure
#     it on the box in front of you with the SIBLING `worktree-disk-probe.sh` (installed next to
#     this script: both are `fleet_srcs`, so a cell runs them from $DEST/scripts and a repo-relative
#     `scripts/...` pointer would not resolve where this line is actually read); never infer it.
#   * `df` delta across the pass: what the FILESYSTEM actually got back. This is the reclamation.
# Both are printed. Nothing here claims the `du` figure was freed.
#
# CAPACITY, AND A STATED FLOOR (the acceptance test on #1932, from the review of PR #1949): "a box can
# run N lanes without free disk falling below a stated floor — N measured, floor asserted, both printed
# by the reaper". So every pass that COMPLETES prints ONE capacity line — and a FAIL-CLOSED abort
# (exit 3, any probe or enumeration failure) prints NONE, deliberately: an estate the pass could not
# measure must not be summarised, because any floor verdict on it would be a claim about a walk that
# never ran (review of PR #1949, P3 — the sentence here and in the policy doc used to promise the line
# on every pass, which the abort paths contradicted):
#   * `lanes_live=K`   MEASURED: how many lane ENVS this pass KEPT because a live holder was found.
#                      ⛔ It is a count of retained envs, NOT of worktrees (review of PR #1949): a live
#                      worktree with no `.venv` yet produces no row at all (classify() returns early),
#                      so it is not counted even though it is about to `uv sync` ~1.85 GB of real,
#                      non-shared disk (measured: two lanes consumed 3.7 GB). Read K as "envs still on
#                      disk because someone is using them", never as "lanes on this box".
#   * `lane_venv_max=M` MEASURED: the LARGEST lane env this pass saw. The headroom below uses the
#                      worst case, never the mean — a byte budget built on the average env is the same
#                      error as a `du` figure built on the assumption that hardlinked blocks are free.
#                      ⛔ Its representative is only as good as the sample: a PARTIALLY-synced env (a
#                      `uv sync` in progress — the case `venv_newest_mtime` explicitly expects) is
#                      small, and dividing by it over-states headroom by orders of magnitude. The
#                      divisor is printed on the line so a reader can reject the quotient; it is an
#                      input, not a verdict.
#   * `free_after=F`   MEASURED: filesystem free space after the pass.
#   * `floor=L`        STATED: `REAP_VENV_FREE_FLOOR_MB` (default 2048 = one measured lane env, so the
#                      box can always start another lane).
#   * `floor_ok=`      ASSERTED: `yes` | `no` | `unknown`. `unknown` is NEVER READ AS SATISFIED — a `df`
#                      that cannot answer must never read as "enough", so the line says so and names
#                      why. It does NOT change the exit code: an unmeasurable `df` is not evidence of a
#                      BREACH (that is the `no` verdict, which exits 5). Do not read the pass's rc as a
#                      floor verdict — read `floor_ok`.
#   * `lanes_headroom=N` DERIVED: how many MORE lane envs fit before free space reaches the floor,
#                      i.e. `(free_after - floor) / lane_venv_max`, floored at 0. `?` when either input
#                      is unknown — never a fabricated number.
# A pass that ends BELOW the floor exits 5. ⛔ THAT CODE IS PROPAGATED (#2156): `disk-reaper.sh`'s
# `worst_rc()` used to DROP a delegate 5 (`0|5) printf '%s' "$cur"`), so this class line read
# `rc=0 verdict=ok` and only `detail=reap-lane-venvs.sh exited 5` survived — a false PASS exactly at the
# condition the floor exists to make visible. It now KEEPS the 5 and ranks it fail-closed in an apply
# pass, so a breach surfaces as a red pass (`rc=3`) with `verdict_venv=fail-closed`. Reclaiming is not the remedy
# for a breach and the reaper does not pretend otherwise: it will not delete a live lane's env to get
# back above the floor, so the line NAMES the breach rather than hiding it behind a green summary.
#
# ⛔ THE `uv` DOWNLOAD CACHE IS NEVER TOUCHED. Where a venv shares blocks with it (a hardlink, or an
# APFS clone), removing the cache does not free the space it appears to — the links keep the blocks
# alive — and on EVERY machine it forces the next `uv sync` to write a full copy instead of a shared
# one, so the rule holds whether or not the sharing regime is active on this box. That is the measured regression that created
# this situation in the first place: 6.1 GB "freed" by deleting the cache, then re-spent as duplicated
# venvs. If the cache must be bounded, that is `uv cache prune` (which preserves live links) — a
# different tool with different semantics, and deliberately NOT this one.
#
# ⛔ AND A MACHINE-WIDE SHARED ENV IS NOT THE FIX (considered, rejected): `uv` installs the project
# itself in EDITABLE mode pointing at ONE worktree, so a shared env silently imports the wrong code for
# every other lane. The safe version (`--no-install-project` plus an explicit `PYTHONPATH` per lane) is
# a design decision, not a reaper. Recorded here so it is not re-proposed as a hotfix.
#
# Usage:
#   reap-lane-venvs.sh --worktree PATH [--apply]      # lane-exit teardown (ONE worktree, known dead)
#   reap-lane-venvs.sh [--gc] [--repo PATH] [--apply] # orphan GC over every worktree of PATH
#   reap-lane-venvs.sh --help
#
#   (no mode flag)  dry-run: classify + report, remove NOTHING (default)
#   --dry-run       explicit dry-run (wins over an armed env)
#   --apply         armed pass (or env REAP_VENV_DRY_RUN=0)
#   --worktree P    lane-exit mode: P is the worktree whose lane has exited
#   --gc            orphan-GC mode (default when --worktree is absent)
#   --repo PATH     repo whose worktrees the GC scans (default $PWD)
#   --min-age S     GC age floor in seconds (default 1800)
#
# Env seams (tests use them; operators rarely should):
#   REAP_VENV_FREE_FLOOR_MB  stated free-disk floor for the capacity line (default 2048)
#   PS_BIN LSOF_BIN TMUX_BIN GIT_BIN RM_BIN DU_BIN DF_BIN
#   REAP_VENV_DRY_RUN REAP_VENV_MIN_AGE_SECONDS REAP_VENV_FREE_FLOOR_MB REAP_VENV_NOW_EPOCH
#   REAP_VENV_LOG
#   ⛔ REAP_VENV_MIN_AGE_SECONDS is VALIDATED before use (#2158): a non-numeric value is refused with
#   exit 2 and nothing removed, rather than making the age comparison error out and fall through to
#   reaping every holder-free env regardless of age. (The sibling FREE FLOOR is validated the same way,
#   at the point it is read — see `is_pos_int "$REAP_VENV_FREE_FLOOR_MB"`.)
#   REAP_VENV_PS_TIMEOUT REAP_VENV_CWD_TIMEOUT REAP_VENV_TMUX_TIMEOUT REAP_VENV_GIT_TIMEOUT
#   REAP_VENV_VENV_COST_TIMEOUT (the hard-link-aware cost walk; default 60s)
#   REAP_VENV_REMOVE_TIMEOUT REAP_VENV_ALLOW_DEGRADED_CWD REAP_VENV_PROC_ROOT
#   REAP_VENV_SCAN_CAP (test seam: pins the runaway-guard exhaustion branch, which is unreachable with
#   the derived cap)
#
# Exit codes: 0 pass completed (removals or none), 2 usage, 3 fail-closed abort (nothing removed),
#             4 pass completed but at least one removal FAILED,
#             5 pass completed but free space is BELOW REAP_VENV_FREE_FLOOR_MB (`over-bound`). Surface it:
#               `disk-reaper.sh` KEEPS a delegate 5 and ranks it fail-closed in an apply pass, so the
#               condition the floor exists to report is never written down as `ok` (#2156).

set -uo pipefail

SCRIPT_NAME="reap-lane-venvs.sh"
ISSUE_REF="#1932"
TAB="$(printf '\t')"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
# The sibling probe, resolved beside this script: both are `fleet_srcs`, so a cell runs them from
# $DEST/scripts and a repo-relative pointer would not resolve where this line is actually read.
VENV_REAL_BIN="${VENV_REAL_BIN:-$(dirname "${BASH_SOURCE[0]}")/venv-real-cost.py}"

PS_BIN="${PS_BIN:-/bin/ps}"
LSOF_BIN="${LSOF_BIN:-lsof}"
TMUX_BIN="${TMUX_BIN:-tmux}"
GIT_BIN="${GIT_BIN:-git}"
RM_BIN="${RM_BIN:-rm}"
DU_BIN="${DU_BIN:-du}"
DF_BIN="${DF_BIN:-df}"

REAP_VENV_DRY_RUN="${REAP_VENV_DRY_RUN:-1}"
REAP_VENV_MIN_AGE_SECONDS="${REAP_VENV_MIN_AGE_SECONDS:-1800}"
# The stated free-disk floor (MB) the capacity line asserts against. 2048 = one MEASURED lane env
# (~1.85 GB of real, non-shared disk per lane), so "above the floor" means "one more lane still fits".
REAP_VENV_FREE_FLOOR_MB="${REAP_VENV_FREE_FLOOR_MB:-2048}"
REAP_VENV_PS_TIMEOUT="${REAP_VENV_PS_TIMEOUT:-25}"
REAP_VENV_CWD_TIMEOUT="${REAP_VENV_CWD_TIMEOUT:-20}"
REAP_VENV_TMUX_TIMEOUT="${REAP_VENV_TMUX_TIMEOUT:-15}"
REAP_VENV_GIT_TIMEOUT="${REAP_VENV_GIT_TIMEOUT:-20}"
REAP_VENV_REMOVE_TIMEOUT="${REAP_VENV_REMOVE_TIMEOUT:-120}"
# The hard-link-aware cost walk (#2159). Bounded like every other probe; on timeout the reading is
# UNKNOWN (`?`), never a partial number.
REAP_VENV_VENV_COST_TIMEOUT="${REAP_VENV_VENV_COST_TIMEOUT:-60}"
REAP_VENV_ALLOW_DEGRADED_CWD="${REAP_VENV_ALLOW_DEGRADED_CWD:-0}"
# The `/proc` fallback's root. A TEST SEAM (nothing in production sets it): the degraded-cwd branch
# below is unreachable on Linux unless `/proc` can be made to look absent, and an unreachable
# fail-closed branch is an untested one.
REAP_VENV_PROC_ROOT="${REAP_VENV_PROC_ROOT:-/proc}"
STATE_DIR="${HOME:-}/.pi/agent/state"
REAP_VENV_LOG="${REAP_VENV_LOG:-$STATE_DIR/reap-lane-venvs.log}"

MODE=""              # exit | gc
REPO=""
WORKTREE=""
MAIN_REF_DRY=""
REAP_VENV_DRY=""

# pass state
PS_TABLE=""
SELF_PIDS=""
CWD_TABLE=""
CWD_STATE="unknown"        # ok | absent | degraded
TMUX_TABLE=""
TMUX_STATE="unknown"       # ok | absent | failed
SCRATCH=""
FOUND=0
REAPABLE=0
REAPED=0
KEPT=0
# classified `reap`, but the fresh liveness read at the moment of removal found a holder — reported
# separately because it is the ONE number that proves the TOCTOU re-check is live, and it must not be
# confused with a classification keep (those were never candidates).
RECHECK_KEPT=0
FAILED=0
DU_KB=0
DF_BEFORE=""
# Capacity inputs, all of them MEASURED (see CAPACITY in the header): the live-lane count, the largest
# lane env seen, and the verdict of the stated free-disk floor. `?`/empty means "could not read", never
# "zero" or "fine".
LANES_LIVE=0
LANE_VENV_KB_MAX=0
# The hard-link-aware readings (#2159). Every one of them is `?`/`unknown` when unmeasurable —
# never 0, which would read as "free".
LANE_VENV_REAL_KB_MAX=0
# ⛔ A MEASURED ZERO IS NOT AN UNKNOWN (#2159 review, P2). A perfectly-shared env reports
# private_kb == 0 — that is the IDEAL reading, and printing `?` for it beside `venv_dedupe=ok`
# tells a reader the probe is broken on a box that is working exactly as intended. Only a failed
# or timed-out probe is `?`, so the two states get their own flag.
LANE_VENV_REAL_MEASURED=0
VENV_DEDUPE="unknown"
VENV_DEGRADED=0
CAPACITY_FLOOR_OK="unknown"
# The floor ACTUALLY asserted by the pass (validated, defaulted). The audit row must carry this, not the
# raw environment value: with `REAP_VENV_FREE_FLOOR_MB=abc` the comparison uses 2048 and an operator
# grepping the incident line must not read `abc`.
CAPACITY_FLOOR_MB=""
ABORTED=0
SELF_CWD_CANON=""
MAIN_CANON=""

# ⛔ THE HEREDOC BELOW IS UNQUOTED (<<EOF) ON PURPOSE — $SCRIPT_NAME must expand in it — and that makes
# a BACKTICK IN THE HELP TEXT COMMAND SUBSTITUTION, not markup (review of PR #1949): an unescaped
# `disk-reaper.sh` made --help print "note that  does not currently propagate that code" with the word
# gone, and would have EXECUTED a `disk-reaper.sh` found on PATH instead of naming it. Every backtick
# inside the heredoc is escaped, and the suite pins both the rendered word and that --help executes
# nothing.
usage() {
    cat <<EOF
$SCRIPT_NAME — reclaim a lane's .venv when the lane is provably gone ($ISSUE_REF)

Usage:
  $SCRIPT_NAME --worktree PATH [--apply]        lane-exit teardown (ONE worktree, known dead)
  $SCRIPT_NAME [--gc] [--repo PATH] [--apply]   orphan GC over PATH's worktrees (default: \$PWD)
  $SCRIPT_NAME --help

  (no mode flag)  dry-run: classify + report, remove NOTHING (default)
  --dry-run       explicit dry-run (wins over an armed env)
  --apply         armed pass (or env REAP_VENV_DRY_RUN=0)
  --min-age S     GC age floor in seconds (default 1800)

A venv is removed ONLY when no live holder can be found: no tmux pane inside the worktree, no process
whose cwd is inside it, no process whose command line names it. The reaper's own ancestry is excluded.
Fail-closed: an unreadable ps/tmux/cwd probe removes NOTHING (exit 3). The uv download cache is never
touched — deleting it re-spends the space whether or not this box shares blocks with it (see the header).

Every pass that COMPLETES prints a capacity line — lanes_live (measured), lane_venv_max (measured),
free_after, the STATED floor REAP_VENV_FREE_FLOOR_MB (default 2048), the floor_ok verdict
(yes|no|unknown) and lanes_headroom (how many more lane envs fit above the floor). Below the floor is
exit 5, and \`disk-reaper.sh\` KEEPS that code and ranks it fail-closed in an apply pass (#2156), so a
breach is a red pass with \`verdict_venv=fail-closed\` — never \`ok\`.
A FAIL-CLOSED abort (exit 3) prints NO capacity line: an estate it could not measure is never
summarised, so it reports no floor verdict at all.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────────────────────────────
log_line() { printf '%s\n' "$*"; log "$*"; }
log() { [ -n "$REAP_VENV_LOG" ] && printf '%s\n' "$*" >>"$REAP_VENV_LOG" 2>/dev/null; return 0; }

now_epoch() {
    if [ -n "${REAP_VENV_NOW_EPOCH:-}" ]; then printf '%s\n' "$REAP_VENV_NOW_EPOCH"; return 0; fi
    /bin/date +%s 2>/dev/null || date +%s
}

is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# canonicalize <path> — physical path, or "" when it cannot be resolved. EVERY comparison in this
# script uses the canonical form: git records resolved paths while a caller's argv keeps what was
# typed, and on a cell that difference is routine (`/tmp` is a symlink to `/private/tmp` on macOS,
# `$TMPDIR` paths carry `//`). An uncanonicalized compare silently misses live holders.
canonicalize() {
    local p="$1" out
    [ -n "$p" ] || { printf ''; return 0; }
    out="$(cd "$p" 2>/dev/null && pwd -P)" || out=""
    printf '%s\n' "$out"
}

# inside <canon> <path> — true when <path> is <canon> or below it, on a path boundary.
inside() {
    local canon="$1" p="$2"
    [ -n "$canon" ] && [ -n "$p" ] || return 1
    case "$p" in
        "$canon"|"$canon"/*) return 0 ;;
    esac
    return 1
}

is_self_pid() {
    case " ${SELF_PIDS:-} " in *" $1 "*) return 0 ;; esac
    return 1
}

# ── bounded execution (macOS has no GNU `timeout`) ─────────────────────────────────────────────
# A reaper that hangs is worse than no reaper: every probe below touches the process table, the
# filesystem, or another user's `lsof`, and each of those can block. 0 = no watchdog.
WATCHDOGS=""
BOUND_N=0
scratch_dir() {
    [ -n "$SCRATCH" ] && return 0
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/reap-lane-venvs.XXXXXX" 2>/dev/null)" || SCRATCH=""
    [ -n "$SCRATCH" ] || return 1
    return 0
}
cleanup() {
    # ⛔ THE SCRATCH **PARENT** CREATED IS THE ONE THIS REMOVES — that is the leak fix, and it is in
    # `probes_ready` (it now calls `scratch_dir` before any probe runs). Previously `bound_file` created
    # the directory inside a COMMAND SUBSTITUTION, so the parent's SCRATCH stayed empty and this `rm -rf`
    # removed only a second directory the parent made later; one `reap-lane-venvs.XXXXXX` survived every
    # pass. (An earlier version of this comment blamed `run_bounded`'s watchdog subshell for deleting the
    # parent's scratch. That is FALSE — bash does not run an inherited EXIT trap in a subshell — and it
    # was removed after it was disproved by execution. The ~7.5%-under-load flake it claimed to explain
    # is UNEXPLAINED and pre-existing; the pass fails CLOSED there, so nothing is removed.)
    local w
    # ⛔ OWNER GUARD (#1932, found while re-running this suite under load): `cleanup` is an EXIT trap, and
    # the watchdog subshell forked by `run_bounded` INHERITED it on the bash the flake was measured on; a
    # child that ran it deleted the PARENT's scratch dir (`rm -rf "$SCRATCH"`) while the parent was still
    # reading the probe it had just written: `ps probe unavailable` / `reports no worktrees at all`, exit
    # 3, on a healthy box, at random (~1 run in 3 here). `$$` is the same in a subshell; `$BASHPID` is
    # not, so BASHPID is the exact owner test. `trap - EXIT` in the watchdog is the other half.
    #
    # ⛔ BASH 3.2 (#1949 review): `BASHPID` is bash >= 4.0. `/bin/bash` on macOS is 3.2.57 and this
    # reaper is invoked PATH-resolved (`bash "$reaper"`, spawn-gate.sh), so on a PATH without a newer
    # bash an unguarded `$BASHPID` is an UNBOUND VARIABLE under `set -u` — and an unbound expansion in an
    # EXIT trap ABORTS THE REST OF THE TRAP (measured: the watchdog kill loop and the scratch removal
    # below would never run, leaking a scratch dir per pass). So test only what can be POSITIVELY known:
    # skip when BASHPID EXISTS and differs from `$$`. With no BASHPID the pre-#1932 behaviour is
    # restored, which is what a 3.2 box had before and leaks nothing new — a child that cannot be
    # identified must not be assumed to be one.
    #
    # ⛔ THE GUARD IS INERT ON 3.2 BY CONSTRUCTION, AND THAT IS WHY EVERY DESTRUCTIVE SUBSHELL ALSO
    # CLEARS THE TRAP (review of PR #1949): where BASHPID does not exist, no child can be identified and
    # this test cannot fire — so the guard CANNOT be the fix on the very bash that has the problem. The
    # load-bearing half is `trap - EXIT` inside the subshells whose exit must not run this function (the
    # watchdog at run_bounded(), and the removal subshell in remove_one()); this guard is the redundant
    # second half on bash >= 4. Removing the trap resets nothing on a bash that never ran an inherited
    # EXIT trap anyway — it is the only line that covers 3.2.
    if [ -n "${BASHPID:-}" ] && [ "$BASHPID" != "$$" ]; then return 0; fi
    for w in $WATCHDOGS; do kill -TERM "$w" 2>/dev/null; done
    WATCHDOGS=""
    [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
    SCRATCH=""
    return 0
}

# run_probe <seconds> <outfile> <cmd...> — run_bounded, but the probed command starts in `/`.
# ⛔ LOAD-BEARING, not tidiness: in `--worktree` mode the reaper's cwd IS the worktree, so a probe
# child inherits that cwd — and `lsof` reports ITSELF. MEASURED (cell-2, before this): the cwd witness
# matched the reaper's own `lsof` child as a live lane and every exit-mode reap was refused. A probe
# that cannot see itself is the only way the witness means what it says.
run_probe() {
    local secs="$1" out="$2"; shift 2
    run_bounded "$secs" "$out" bash -c 'cd / && exec "$@"' _ "$@"
}

# run_bounded <seconds> <outfile> <cmd...> — 0 ok, 124 timed out, else the command's status.
# stdout AND stderr are merged into <outfile>: a caller that needs to tell "tmux has no server" (a
# KNOWN zero) from "tmux failed" (an unsound pass) can only do that from stderr text.
run_bounded() {
    local secs="$1" out="$2"; shift 2
    local pid wd="" s rc=0 sentinel="" done_flag=""
    BOUND_N=$((BOUND_N + 1))
    if scratch_dir; then
        sentinel="$SCRATCH/s.$BOUND_N"
        done_flag="$SCRATCH/d.$BOUND_N"
    fi
    : >"$out" 2>/dev/null || { : ; }
    "$@" >"$out" 2>&1 &
    pid=$!
    # ⛔ NORMALISE AND RANGE-CHECK HERE, NOT ONLY AT ONE CALL SITE (#2159 review, rounds 3-4). The
    # predicate below parses with strtoimax: an all-digit value above 2^63-1 makes the COMPARISON ITSELF
    # error, `if` then takes the else branch and NO WATCHDOG IS ARMED — silently, on every one of the
    # six bound seams (ps/cwd/tmux/git/remove/cost), not just the one that got a per-seam check. Leading
    # zeros are stripped first (`00` is zero, which is already the documented "no watchdog" spelling, so
    # it means exactly what `0` means), the digit count is capped at 9 (~31 years), and an over-range
    # value falls back LOUDLY rather than being handed to a comparison that would abort.
    _bnd_norm="${secs#"${secs%%[!0]*}"}"
    case "$secs" in
        ''|*[!0-9]*) _bnd_norm="" ;;
    esac
    if [ -n "${_bnd_norm:-}" ] && [ "${#_bnd_norm}" -gt 9 ]; then
        echo "warn: probe bound '$secs' is out of range (at most 9 digits) — using 120s instead of arming no watchdog" >&2
        log "warn: probe bound '$secs' out of range — fell back to 120s"
        secs=120
    elif [ -n "${_bnd_norm:-}" ]; then
        secs="$_bnd_norm"
    fi
    if is_pos_int "$secs" && [ "$secs" -gt 0 ]; then
        (
            # ⛔ `cd /` IS LOAD-BEARING (#1932). This watchdog is a CHILD of the reaper and inherits its
            # cwd — in `--worktree` mode that is the worktree itself — and it lives for the whole probe,
            # i.e. exactly while `lsof` is scanning. It is dead again by the time the `ps` table is read,
            # so the self-tree cannot identify it, and MEASURED (cell-2) it was reported as a live lane's
            # cwd, refusing every exit-mode reap. The watchdog needs no cwd; it must not have one here.
            cd / 2>/dev/null || true
            # ⛔ The parent's EXIT trap (`cleanup`) MUST NOT run here — this subshell exits after EVERY
            # probe (run_bounded TERMs it), and cleanup deletes the parent's scratch dir. See cleanup().
            trap - EXIT
            trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
            sleep "$secs" &
            s=$!
            wait "$s" 2>/dev/null
            [ -n "$done_flag" ] && [ -e "$done_flag" ] && exit 0
            if kill -0 "$pid" 2>/dev/null; then
                [ -n "$sentinel" ] && : >"$sentinel"
                kill -9 "$pid" 2>/dev/null
            fi
        ) >/dev/null 2>&1 &
        wd=$!
        WATCHDOGS="$WATCHDOGS $wd"
    fi
    wait "$pid" 2>/dev/null || rc=$?
    if [ -n "$wd" ]; then
        [ -n "$done_flag" ] && : >"$done_flag"
        kill -TERM "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
    fi
    # The sentinel is the only way to tell "the watchdog killed it" from a command that died with 137.
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then rc=124; fi
    [ -n "$sentinel" ] && rm -f "$sentinel"
    [ -n "$done_flag" ] && rm -f "$done_flag"
    return $rc
}

bound_file() { # bound_file <name> — a scratch path, or "" when no scratch dir could be made
    scratch_dir || return 1
    printf '%s/%s\n' "$SCRATCH" "$1"
}

# ── probe: ps (the argv witness, and the ancestry table) ───────────────────────────────────────
# An EMPTY or failed table is a probe FAILURE, not "no live processes": reading it as clean would
# silently disable the live-reference gate — the fail-open this whole script exists to avoid.
ps_load() {
    local out rc
    out="$(bound_file ps)" || return 1
    run_bounded "$REAP_VENV_PS_TIMEOUT" "$out" "$PS_BIN" -axo pid=,ppid=,command=
    rc=$?
    [ "$rc" = 0 ] || return 1
    [ -s "$out" ] || return 1
    PS_TABLE="$out"
    return 0
}

# self_load — the reaper's own process tree, ANCESTORS AND DESCENDANTS, excluded from every witness.
#
# Ancestors, because `--worktree` mode is called from INSIDE the lane it is reaping: the lane script is
# an ancestor, its cwd is the worktree, and the tmux pane it runs under is an ancestor too.
# Descendants, because every probe here forks (`$(…)` subshells, `awk`, the bounded watchdog) and a
# forked subshell carries the PARENT'S argv and cwd — i.e. `bash reap-lane-venvs.sh --worktree <wt>`
# with cwd `<wt>`. MEASURED on cell-2 before this fix: a dry run classified its own probe subshell as
# `live-argv` and kept every env, so the reaper never removed anything while reporting itself correct.
# No legitimate child of the reaper is a lane; the only things it spawns are its own probes.
self_load() {
    local pid="$$" ppid depth=0 more
    SELF_PIDS=" $$ "
    [ -s "$PS_TABLE" ] || return 0
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
        ppid="$(awk -v p="$pid" '$1==p {print $2; exit}' "$PS_TABLE" 2>/dev/null)"
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        SELF_PIDS="$SELF_PIDS$ppid "
        pid="$ppid"; depth=$((depth + 1))
    done
    more="$(awk -v root="$$" '
        { ppid[$1] = $2; kids[$2] = kids[$2] " " $1 }
        END {
            n = split(kids[root], q, " "); seen[root] = 1
            for (i = 1; i <= n; i++) {
                p = q[i]
                if (p == "" || (p in seen)) continue
                seen[p] = 1; print p
                m = split(kids[p], r, " ")
                for (j = 1; j <= m; j++) if (r[j] != "" && !(r[j] in seen)) { n++; q[n] = r[j] }
            }
        }' "$PS_TABLE" 2>/dev/null)"
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        SELF_PIDS="$SELF_PIDS$pid "
    done <<<"$more"
    return 0
}

# argv_witness_for <canon> — a pid whose command line names the worktree.
argv_witness_for() { # <canon> [<exclude-pids>]
    local canon="$1" base="${1##*/}" tok d pid line
    local exclude="${2:-}"
    [ -n "$canon" ] && [ -s "$PS_TABLE" ] || return 1
    # Exact path-boundary match first (the common case: an absolute path in argv).
    #
    # ⛔ EVERY OCCURRENCE IS TESTED, NOT JUST THE FIRST (review of PR #1949, P1). The matcher used to
    # stop at `index(line, needle)` — the FIRST occurrence — and a `ps` line that named a string-prefix
    # SIBLING before the real path dropped the whole line: `/repo/lane-x-review/copy.py` earlier on the
    # line made `hits()` see the needle inside `lane-x-review`, read `-` at the boundary, return 0, and
    # the live holder became invisible. `--apply` then deleted a LIVE lane's env — the exact inversion
    # the three-witness design exists to prevent — and any multi-worktree `ps` line (a hygiene sweep,
    # `for wt in $(git worktree list …)`) is enough to trigger it whenever one lane's path is a prefix
    # of another's. The canonicalized-token arm below cannot rescue it (it only examines tokens ending
    # in `/$base`), so the boundary check has to be right HERE.
    while IFS= read -r line; do
        pid="${line%% *}"
        [ -n "$pid" ] || continue
        is_self_pid "$pid" && continue
        case " $exclude " in *" $pid "*) continue ;; esac
        printf 'pid=%s argv=%s\n' "$pid" "$(printf '%s' "$line" | cut -c1-140)"
        return 0
    done <<<"$(awk -v a="$canon" '
        # 1 when ANY occurrence of `needle` on the line ends at a real path boundary. On a miss the
        # scan advances one character past the occurrence START (not past the occurrence end), so
        # overlapping and back-to-back occurrences are all examined.
        function hits(line, needle,   i, c, rest, n) {
            n = length(needle)
            rest = line
            while ((i = index(rest, needle)) > 0) {
                c = substr(rest, i + n, 1)
                if (c == "" || c == "/" || c == " " || c == "\t") return 1
                rest = substr(rest, i + 1)
            }
            return 0
        }
        { if (hits($0, a)) print $0 }' "$PS_TABLE" 2>/dev/null)"
    # Then the canonicalized-token arm: a symlinked or relative spelling of the same path. Only lines
    # carrying a token with the worktree's basename are considered, so this stays bounded by ps.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid="${line%% *}"
        is_self_pid "$pid" && continue
        case " $exclude " in *" $pid "*) continue ;; esac
        for tok in $line; do
            case "$tok" in *"/$base") ;; *) continue ;; esac
            case "$tok" in "$canon"|"$canon"/*) printf 'pid=%s argv=%s\n' "$pid" "$(printf '%s' "$line" | cut -c1-140)"; return 0 ;; esac
            if [ -d "$tok" ]; then d="$tok"; else d="$(dirname "$tok" 2>/dev/null)"; fi
            [ -n "$d" ] && [ -d "$d" ] || continue
            d="$(canonicalize "$d")"
            [ -n "$d" ] || continue
            if inside "$canon" "$d"; then printf 'pid=%s argv=%s\n' "$pid" "$(printf '%s' "$line" | cut -c1-140)"; return 0; fi
        done
    done <<<"$(grep -F -- "/$base" "$PS_TABLE" 2>/dev/null)"
    return 1
}

# ── probe: process cwd ─────────────────────────────────────────────────────────────────────────
# The witness argv cannot see: `bash -c 'cd <wt> && python -m pytest'` names the worktree, but a
# process that `cd`s in afterwards and runs a bare `python` does not.
# lsof is used where it exists (macOS always, most Linux images); `/proc/*/cwd` is the fallback so a
# slim container is not left unable to prove anything. Either way the result is ONE table of
# `pid<TAB>cwd` rows, so the two sources share every line of matching logic below.
cwd_load() {
    local out rc lsof_ok=0
    out="$(bound_file cwd)" || { CWD_STATE="degraded"; return 1; }
    if command -v "$LSOF_BIN" >/dev/null 2>&1; then
        lsof_ok=1
        run_probe "$REAP_VENV_CWD_TIMEOUT" "$out.raw" "$LSOF_BIN" -a -d cwd -Fpn
        rc=$?
        if [ "$rc" = 0 ] && [ -s "$out.raw" ]; then
            awk '/^p[0-9]+$/ {pid = substr($0, 2); next}
                 /^n/ && pid != "" {print pid "\t" substr($0, 2)}' "$out.raw" >"$out" 2>/dev/null
        fi
        rm -f "$out.raw"
    fi
    if [ ! -s "$out" ] && [ -d "$REAP_VENV_PROC_ROOT" ]; then
        local d p ln
        : >"$out"
        for d in "$REAP_VENV_PROC_ROOT"/[0-9]*/cwd; do
            [ -e "$d" ] || [ -L "$d" ] || continue
            p="${d#"$REAP_VENV_PROC_ROOT"/}"; p="${p%/cwd}"
            ln="$(readlink "$d" 2>/dev/null)" || continue
            # ⛔ ABSOLUTE ONLY: a `readlink` that cannot read the link may print its ERROR to stdout
            # (measured: `/proc/1/cwd (readlink: Permission denied)`), and a non-path row would be
            # compared against worktrees as if it were one.
            case "$ln" in /*) ;; *) continue ;; esac
            printf '%s\t%s\n' "$p" "$ln" >>"$out"
        done
    fi
    if [ ! -s "$out" ]; then
        CWD_STATE="degraded"
        rm -f "$out"
        return 1
    fi
    CWD_STATE="ok"
    CWD_TABLE="$out"
    [ "$lsof_ok" = 1 ] || log "cwd probe: lsof absent — used /proc/*/cwd"
    return 0
}

cwd_witness_for() { # <canon> [<exclude-pids>] — pids this classification has already DEMOTED
    local canon="$1" exclude="${2:-}" pid path
    [ -n "$canon" ] && [ -s "${CWD_TABLE:-}" ] || return 1
    while IFS="$TAB" read -r pid path; do
        [ -n "$pid" ] && [ -n "$path" ] || continue
        is_self_pid "$pid" && continue
        case " $exclude " in *" $pid "*) continue ;; esac
        inside "$canon" "$path" || continue
        printf 'pid=%s cwd=%s\n' "$pid" "$path"
        return 0
    done <"$CWD_TABLE"
    return 1
}

# ── probe: tmux ────────────────────────────────────────────────────────────────────────────────
# The fleet spawns every lane into its own tmux session, so a pane whose current path is the worktree
# is positive evidence the lane is ALIVE — including between turns, when no agent process is running.
# A tmux that is not INSTALLED means no tmux sessions exist (a known zero, not a failure). A tmux that
# is installed but cannot list its panes is a FAILED probe: it could be hiding the live lane.
tmux_load() {
    local out rc
    if ! command -v "$TMUX_BIN" >/dev/null 2>&1; then TMUX_STATE="absent"; return 0; fi
    out="$(bound_file tmux)" || { TMUX_STATE="failed"; return 1; }
    run_probe "$REAP_VENV_TMUX_TIMEOUT" "$out" "$TMUX_BIN" list-panes -a -F "#{pane_pid}$TAB#{pane_current_path}"
    rc=$?
    if [ "$rc" = 0 ]; then TMUX_STATE="ok"; TMUX_TABLE="$out"; return 0; fi
    # Distinguish "there is no server" (no sessions can exist => a KNOWN zero) from "the probe failed".
    if grep -qE 'no server running|error connecting to|no sessions' "$out" 2>/dev/null; then
        TMUX_STATE="absent"; rm -f "$out"; return 0
    fi
    TMUX_STATE="failed"
    log "tmux probe FAILED (rc=$rc): $(head -3 "$out" 2>/dev/null | tr '\n' ' ')"
    return 1
}

tmux_witness_for() { # <canon> [<exclude-pids>]
    local canon="$1" exclude="${2:-}" pid path cpane
    [ "$TMUX_STATE" = "ok" ] && [ -s "${TMUX_TABLE:-}" ] || return 1
    while IFS="$TAB" read -r pid path; do
        [ -n "$pid" ] && [ -n "$path" ] || continue
        is_self_pid "$pid" && continue
        case " $exclude " in *" $pid "*) continue ;; esac
        cpane="$(canonicalize "$path")"
        [ -n "$cpane" ] || cpane="$path"
        inside "$canon" "$cpane" || continue
        printf 'pane_pid=%s pane_path=%s\n' "$pid" "$cpane"
        return 0
    done <"$TMUX_TABLE"
    return 1
}

# live_witness <canon> — "<witness>\t<evidence>" when a live holder exists, nothing when none.
#
# ── THE IDLE-SHELL RULE (agent-infra#2721) ───────────────────────────────────────────────────
# WHY. The cwd and tmux-pane witnesses answer "is a process sitting in this worktree?" — and a shell
# that `cd`'d in and never exited answers YES for ever. That is not a hypothetical: the reclaim logs
# quoted in #2721 recorded `KEEP … (a live process has it as cwd)` for nearly every worktree on a
# wedged cell while 59 checkouts carrying a lane env each (5-6 GB `du`) accumulated and the box lost
# its disk. A shell at a prompt is not a lane: the lane's agent is the shell's CHILD, so a shell with
# no children is a process nobody is using.
#
# THE RULE, and it is deliberately narrow:
#   a cwd / tmux-pane holder is LIVE EVIDENCE unless it is a SHELL whose START TIME is before the
#   worktree's HEAD commit AND which has no child process.
# "Started before the last commit" is the brief's own phrasing of "never did anything here": a lane
# between turns still holds its `pi`/test child, so it does not match; a lane that finished and left
# its pane or its `cd` behind does. Every OTHER gate is untouched — `dirty`/`ignored-artifact`/`open-pr`/
# `too-recent`/`detached-unreachable` and the shared-store rule all still KEEP — so the blast radius of
# a wrong reading here is a re-created environment, never uncommitted or unpushed work.
# ⛔ FAIL CLOSED ON EVERY UNKNOWABLE: a pid missing from the process table, a start time that cannot be
# read, a HEAD that cannot be dated, or any probe that cannot answer all leave the witness LIVE.
# ⛔ AND IT IS SWITCHABLE (`REAP_VENV_IDLE_SHELL=0`) so an operator can restore the strict reading
# without editing a shipped script; when it demotes a holder it NAMES it in the pass log.
IDLE_SHELL="${REAP_VENV_IDLE_SHELL:-1}"

# proc_start_epoch <pid> -> epoch seconds the process started ("" when unreadable).
# Linux needs no fork: the `/proc/<pid>` DIRECTORY's mtime is set at process creation (measured).
# Elsewhere fall back to `ps -o etimes=` (elapsed seconds) and then to `ps -o etime=`'s
# `[[dd-]hh:]mm:ss` form, which BSD ps has. An unreadable value is "" — never 0, which would compare
# as "started at the epoch" and mis-classify every holder as stale.
proc_start_epoch() {
    local pid="${1:-}" v e rest
    [ -n "$pid" ] && is_pos_int "$pid" || return 1
    # ⛐ THE ROOT IS `$REAP_VENV_PROC_ROOT`, NOT A LITERAL `/proc` (review round 5, P2). The variable
    # already means "where the process table lives" (the cwd scan reads it), and leaving this one read
    # pinned to `/proc` made the fallback UNTESTABLE on a Linux host: a fixture pid that happens to be
    # live takes this branch, so an arm for the `10#` parse below passes (or fails) on whatever process
    # owns that pid — it discriminates only in a fresh container. With the seam honoured, a fixture
    # root that does not contain the pid falls through to `ps` deterministically, in production it is
    # still `/proc`, and the arm pins the parse it claims to pin.
    if [ -r "$REAP_VENV_PROC_ROOT/$pid" ]; then
        v="$(stat -c '%Y' "$REAP_VENV_PROC_ROOT/$pid" 2>/dev/null)"
        case "$v" in ''|*[!0-9]*) v="" ;; esac
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    fi
    v="$("$PS_BIN" -o etimes= -p "$pid" 2>/dev/null | tr -d ' \t')"
    case "$v" in ''|*[!0-9]*) v="" ;; esac
    [ -n "$v" ] && { printf '%s\n' "$(( $(now_epoch) - v ))"; return 0; }
    e="$("$PS_BIN" -o etime= -p "$pid" 2>/dev/null | tr -d ' \t')"
    [ -n "$e" ] || return 1
    case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
    # ⛔ EVERY FIELD IS FORCED TO BASE 10 (review round 1, P2-falsified-in-part): `ps -o etime` prints
    # zero-padded components, so a perfectly ordinary `1:08:30` reaches the arithmetic as `08` and bash
    # rejects it as a bad OCTAL constant, and the expansion ABORTS: `proc_start_epoch` returns NOTHING,
    # the rule could not prove the holder predated HEAD, and the holder stayed LIVE — an INERT
    # enforcer, never a false reap, on every host that reaches this fallback (on macOS it is the
    # PRIMARY path). `10#` makes the parse literal decimal.
    v=0
    case "$e" in
        *-*) v=$(( 10#${e%%-*} * 86400 )); e="${e#*-}" ;;
    esac
    local f1 f2 f3 rest
    case "$e" in
        *:*:*) f1="${e%%:*}"; rest="${e#*:}"; f2="${rest%%:*}"; f3="${rest#*:}" ;;
        *:*)   f1=0; f2="${e%%:*}"; f3="${e#*:}" ;;
        *)     f1=0; f2=0; f3="$e" ;;
    esac
    is_pos_int "$f1" && is_pos_int "$f2" && is_pos_int "$f3" || return 1
    v=$(( v + 10#$f1 * 3600 + 10#$f2 * 60 + 10#$f3 ))
    printf '%s\n' "$(( $(now_epoch) - v ))"
}

# is_shell_pid <pid> — the process's COMMAND WORD is a shell (its argv[0], from the ps table).
is_shell_pid() {
    local pid="${1:-}" cmd base
    [ -n "$pid" ] && [ -s "${PS_TABLE:-}" ] || return 1
    cmd="$(awk -v p="$pid" '$1==p { $1=""; $2=""; sub(/^[ \t]+/, ""); print; exit }' "$PS_TABLE" 2>/dev/null)"
    [ -n "$cmd" ] || return 1
    cmd="${cmd%% *}"
    base="${cmd##*/}"
    base="${base#-}"
    case "$base" in bash|sh|dash|zsh|ksh|ksh93|mksh|ash|fish) return 0 ;; esac
    return 1
}

# has_child <pid> — a pid with a live child in the table is DOING something (a prompt has none).
# The reaper's own probe tree is excluded, the same way every other witness excludes it: the reaper
# forks from the shell it is called by, and that shell's cwd may well be the worktree it is reaping.
has_child() {
    local pid="${1:-}"
    [ -n "$pid" ] && [ -s "${PS_TABLE:-}" ] || return 1
    awk -v p="$pid" -v self=" ${SELF_PIDS:-} " '
        $2==p { if (index(self, " " $1 " ") == 0) { found=1; exit } }
        END { exit !found }' "$PS_TABLE" 2>/dev/null
}

# head_epoch_for <worktree> -> epoch of the worktree's HEAD commit ("" when git cannot date it).
# Bounded like every other git call here. ⛔ NO CACHE, DELIBERATELY (review round 1, P2): every caller
# runs inside `$( )` (`live="$(live_witness …)"`), so a shell-variable cache set here is born and dies
# in the same subshell — an earlier version claimed "cached per pass" and did not cache at all. A cache
# that only APPEARS to exist is worse than none: it makes the next reader believe the cost is paid. The
# probe runs ONLY when a shell holder was actually found, so it is one bounded `git log` per demotion
# candidate, not per worktree.
head_epoch_for() {
    local wt="${1:-}" out rc v
    [ -n "$wt" ] || return 1
    out="$(bound_file headep)" || return 1
    run_bounded "$REAP_VENV_GIT_TIMEOUT" "$out" "$GIT_BIN" -C "$wt" log -1 --format=%ct
    rc=$?
    v="$(head -1 "$out" 2>/dev/null | tr -d ' \t')"
    rm -f "$out"
    [ "$rc" = 0 ] || return 1
    is_pos_int "$v" || return 1
    printf '%s\n' "$v"
}

# stale_shell_holder <pid> <worktree-canon> — 0 when this holder is an IDLE SHELL predating HEAD.
# Fail-closed in every branch: anything we cannot prove leaves the holder LIVE.
stale_shell_holder() {
    local pid="${1:-}" canon="${2:-}" head start
    [ "$IDLE_SHELL" = 1 ] || return 1
    [ -n "$pid" ] && is_pos_int "$pid" || return 1
    is_shell_pid "$pid" || return 1
    has_child "$pid" && return 1
    head="$(head_epoch_for "$canon")" || return 1
    start="$(proc_start_epoch "$pid")" || return 1
    [ "$start" -lt "$head" ] || return 1
    return 0
}

# live_witness <canon> — "<witness>\t<evidence>" when a live holder exists, nothing when none.
#
# ⛔ EVERY HOLDER IS EXAMINED, AND THE SCAN IS BOUNDED BY CONSTRUCTION (review round 1, P1+P2). A
# worktree routinely holds an idle shell left over from an earlier lane AND a live lane's own shell, so
# stopping at the first hit decides the whole worktree from whichever pid the probe happened to list
# first. The first version advanced the scan by REWRITING THE PROBE TABLE — a loop with no bound: the
# `awk`/`mv` result was never checked, so a failed write (ENOSPC on a full cell — the exact state this
# reaper runs in) left the same row in place, the same pid came back, and the pass never terminated.
# It also leaked across worktrees: a pid inside a NESTED worktree matches both canons, so demoting it
# for the inner one removed the evidence the outer one needed.
# The scan therefore carries its own EXCLUDE LIST (pid-scoped, per classification) and a hard
# iteration cap four greater than the probe tables' total row count: a demotion that somehow fails to
# advance the cursor ends the loop instead of spinning it, and one worktree's demotion cannot affect
# another's.
live_witness() {
    local canon="$1" hit pid seen="" cap n=0
    # The cap is a RUNAWAY GUARD, not a schedule: it must exceed the number of DISTINCT holders any
    # probe could report, so it counts EVERY table — including PS, which the argv arm reads (review
    # round 2, P2: counting only cwd+tmux made the cap collapse to 4 on a host with no lsof and no
    # tmux server, and a worktree with five holders was then truncated and read as unheld).
    cap=$(( $(wc -l <"${CWD_TABLE:-/dev/null}" 2>/dev/null || echo 0) + $(wc -l <"${TMUX_TABLE:-/dev/null}" 2>/dev/null || echo 0) + $(wc -l <"${PS_TABLE:-/dev/null}" 2>/dev/null || echo 0) + 4 ))
    [ "$cap" -ge 4 ] || cap=4
    # ⛐ THE CAP HAS A TEST SEAM (`REAP_VENV_SCAN_CAP`), because its EXHAUSTION BRANCH is otherwise
    # unreachable: the default is rows(cwd)+rows(tmux)+rows(ps)+4 and every iteration consumes a distinct
    # pid, so "n > cap" cannot fire in a healthy pass — which meant the branch's POLARITY (a truncated
    # scan is a LIVE holder, never "no holder") had no arm at all, and reverting it to `return 1` kept the
    # suite green while a truncated scan would read as "every holder was demoted" and the env deleted
    # (review round 8, P2). Production never sets this; a suite does, to drive the backstop.
    if is_pos_int "${REAP_VENV_SCAN_CAP:-}" && [ "${REAP_VENV_SCAN_CAP}" -ge 1 ]; then cap="$REAP_VENV_SCAN_CAP"; fi
    while hit="$(tmux_witness_for "$canon" "$seen")"; do
        n=$((n + 1))
        if [ "$n" -gt "$cap" ]; then
            log "stale-shell-scan TRUNCATED at $cap holders — treating this one as LIVE (fail-closed); report it"
            printf 'live-tmux-pane\t%s\n' "$hit"; return 0
        fi
        pid="$(printf '%s' "$hit" | sed -n 's/^pane_pid=\([0-9][0-9]*\).*/\1/p')"
        if [ -n "$pid" ] && stale_shell_holder "$pid" "$canon"; then
            log "stale-shell: pid=$pid(tmux-pane) — an idle shell predating HEAD is not a live lane (#2721); the other gates still decide"
            seen="$seen$pid "
        else
            printf 'live-tmux-pane\t%s\n' "$hit"; return 0
        fi
    done
    while hit="$(cwd_witness_for "$canon" "$seen")"; do
        n=$((n + 1))
        if [ "$n" -gt "$cap" ]; then
            log "stale-shell-scan TRUNCATED at $cap holders — treating this one as LIVE (fail-closed); report it"
            printf 'live-cwd\t%s\n' "$hit"; return 0
        fi
        pid="$(printf '%s' "$hit" | sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p')"
        if [ -n "$pid" ] && stale_shell_holder "$pid" "$canon"; then
            log "stale-shell: pid=$pid(cwd) — an idle shell predating HEAD is not a live lane (#2721); the other gates still decide"
            seen="$seen$pid "
        else
            printf 'live-cwd\t%s\n' "$hit"; return 0
        fi
    done
    while hit="$(argv_witness_for "$canon" "$seen")"; do
        n=$((n + 1))
        if [ "$n" -gt "$cap" ]; then
            log "stale-shell-scan TRUNCATED at $cap holders — treating this one as LIVE (fail-closed); report it"
            printf 'live-argv\t%s\n' "$hit"; return 0
        fi
        pid="$(printf '%s' "$hit" | sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p')"
        if [ -n "$pid" ] && stale_shell_holder "$pid" "$canon"; then
            log "stale-shell: pid=$pid(argv) — an idle shell predating HEAD is not a live lane (#2721); the other gates still decide"
            seen="$seen$pid "
        else
            printf 'live-argv\t%s\n' "$hit"; return 0
        fi
    done
    # A DEMOTED HOLDER IS NAMED, never silent — and named AT THE DEMOTION (review round 1): an
    # aggregate line emitted at the END of this function never ran whenever a live holder was found
    # after a demoted one, because that branch returns early. Measured: an idle shell demoted and a
    # working shell keeping the same worktree logged NO demotion at all, i.e. the one case an operator
    # most needs to read was the silent one. The pass log is where a KEEP is explained, so each
    # demotion is written where it happens.
    return 1
}

# ── probe: age, size ──────────────────────────────────────────────────────────────────────────
STAT_MODE=""
stat_mode() {
    [ -n "$STAT_MODE" ] && { printf '%s\n' "$STAT_MODE"; return 0; }
    if stat -f '%m' "$0" >/dev/null 2>&1; then STAT_MODE=bsd; else STAT_MODE=gnu; fi
    printf '%s\n' "$STAT_MODE"
}
file_mtime() {
    if [ "$(stat_mode)" = bsd ]; then stat -f '%m' -- "$1" 2>/dev/null; else stat -c '%Y' -- "$1" 2>/dev/null; fi
}

# venv_newest_mtime <venv> — the newest mtime among a BOUNDED probe set (never a tree walk: the venv
# holds tens of thousands of files). `.lock` is uv's own lock file, `.pyvenv.cfg` is written at
# creation, and the three directories change while `uv sync` populates them — so a sync in progress
# keeps at least one of these fresh, which is exactly what the age floor needs to see.
venv_newest_mtime() {
    local venv="$1" c mt best=""
    for c in "$venv" "$venv/pyvenv.cfg" "$venv/.lock" "$venv/lib" "$venv/bin"; do
        [ -e "$c" ] || [ -L "$c" ] || continue
        mt="$(file_mtime "$c")"
        is_pos_int "$mt" || continue
        [ -n "$best" ] || best="$mt"
        [ "$mt" -gt "$best" ] && best="$mt"
    done
    printf '%s\n' "$best"
}

du_kb() { "$DU_BIN" -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}'; }

# venv_real_cost <path> — the HARD-LINK-AWARE cost of one env (#2159), as
# "private_kb<TAB>fair_kb<TAB>total_kb<TAB>dedupe", or "" when it cannot be measured.
#
# ⛔ WHY A SECOND NUMBER, WHEN `du` ALREADY RUNS. `du` answers "how many blocks are under this
# path"; it does NOT answer "how many bytes does a lane cost the filesystem". Where `uv` links
# packages out of its cache they diverge by more than an order of magnitude, and the headroom
# arithmetic below was built on the first question. MEASURED on cell-1 (2026-10-31, tortoise):
#     du -sk <wt>/.venv   5,940,904 KB
#     private blocks         101,404 KB   <- what reaping it actually frees
# and the SAME checkout held an env with 5,935,940 private KB (nlink==1 throughout: hardlinking
# had degraded to a full copy). So the two classes are 58x apart and `du` cannot tell them apart.
#
# ⛔ THE HEADROOM DIVISOR IS *NOT* CHANGED TO THIS VALUE. `du` is the UPPER BOUND — sound for a cold
# cache, which is exactly the case a lane that follows this one lands in — so it remains the gate.
# What this adds is the measurement the bound was hiding: `lane_venv_real` names the real marginal
# cost, and `venv_dedupe=degraded` names the class that genuinely does cost the full figure. A
# reader can then see a box that is 20x less full than `du` implies WITHOUT the pass becoming
# optimistic about a cache it cannot prove is warm.
venv_real_cost() {
    [ -n "${PYTHON_BIN:-}" ] && [ -r "${VENV_REAL_BIN:-}" ] || return 1
    # ⛔ BOUNDED LIKE EVERY OTHER PROBE (#2159 review, P2). This walk touches the filesystem, and a
    # stale or unresponsive mount blocks it — an unbounded probe inside the reaper turns "the pass is
    # slow" into "the pass never returns", which is the failure mode `run_bounded` exists for. The
    # watchdog kills it and the rc is non-zero, so the caller reads `?`/`unknown` rather than a number.
    local out
    out="$(bound_file costout)" || return 1
    run_bounded "$REAP_VENV_VENV_COST_TIMEOUT" "$out" "$PYTHON_BIN" "$VENV_REAL_BIN" --tsv "$1" || return 1
    awk -F"$TAB" 'NF==4 && $1 ~ /^[0-9]+$/ {print; found=1} END {exit !found}' "$out"
}
df_free_kb() { "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

# ── classification ───────────────────────────────────────────────────────────────────────────
# checkout_kind <path> — main | linked | unknown.
# Asked of git, not of the path shape: `--git-dir` equals `--git-common-dir` only for the MAIN
# checkout (a linked worktree's git dir lives under <repo>/.git/worktrees/<name>), so the comparison
# identifies the main checkout without knowing the repo. Anything git cannot answer is `unknown`,
# which is a KEEP in classify(): the main-checkout guard must never be reachable by a failed probe.
checkout_kind() {
    local wt="$1" gd common gd_abs common_abs
    gd="$("$GIT_BIN" -C "$wt" rev-parse --git-dir 2>/dev/null)" || { printf 'unknown\n'; return 0; }
    common="$("$GIT_BIN" -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || { printf 'unknown\n'; return 0; }
    if [ -z "$gd" ] || [ -z "$common" ]; then printf 'unknown\n'; return 0; fi
    case "$gd" in /*) gd_abs="$gd" ;; *) gd_abs="$(canonicalize "$wt/$gd")" ;; esac
    case "$common" in /*) common_abs="$common" ;; *) common_abs="$(canonicalize "$wt/$common")" ;; esac
    if [ -n "$gd_abs" ] && [ "$gd_abs" = "$common_abs" ]; then printf 'main\n'; else printf 'linked\n'; fi
    return 0
}

# classify <worktree-path> <mode: exit|gc>
# Emits "<verdict>\t<reason>\t<evidence>\t<kb>\t<path>" — one row per decision, evidence always named.
classify() {
    local wt="$1" mode="$2" canon venv mt now age kb live
    canon="$(canonicalize "$wt")"
    if [ -z "$canon" ]; then
        printf 'keep\tunresolvable-worktree\t\t\t%s\n' "$wt"; return 0
    fi
    venv="$canon/.venv"
    { [ -e "$venv" ] || [ -L "$venv" ]; } || return 0            # no venv: not a row at all
    # NOT counted here: classify() runs inside a command substitution, so any counter it touched would
    # be lost. Every row is counted once, in report_row().

    if [ -L "$venv" ]; then
        printf 'keep\tsymlinked-venv\t.venv is a symlink — never followed (a delete must not leave the worktree)\t\t%s\n' "$canon"; return 0
    fi
    if [ ! -d "$venv" ]; then
        printf 'keep\tnot-a-directory\t.venv exists but is not a directory\t\t%s\n' "$canon"; return 0
    fi
    case "$(checkout_kind "$canon")" in
        main)    printf 'keep\tmain-checkout\tthe repo main checkout is the controller\x27s, not a lane\x27s\t\t%s\n' "$canon"; return 0 ;;
        unknown) printf 'keep\tunknown-checkout\tgit cannot say whether this is a linked worktree\t\t%s\n' "$canon"; return 0 ;;
    esac
    # GC-only, and load-bearing: a GC run FROM a lane worktree would otherwise reap the env of the lane
    # running it (that lane's own processes are SELF-excluded from every witness, so it reads as dead).
    # `--worktree` mode deliberately does NOT apply this — its caller's cwd IS the worktree by design,
    # because the lane runner calls it from inside the lane on the way out.
    if [ "$mode" = gc ] && [ -n "$SELF_CWD_CANON" ] && inside "$canon" "$SELF_CWD_CANON"; then
        printf 'keep\tself-ancestor\tthe reaper itself runs inside this worktree (%s)\t\t%s\n' "$SELF_CWD_CANON"; return 0
    fi

    kb="$(du_kb "$venv")"
    is_pos_int "$kb" || kb=""

    if live="$(live_witness "$canon")"; then
        printf 'keep\t%s\t%s\t%s\t%s\n' "${live%%$TAB*}" "${live#*$TAB}" "${kb:-}" "$canon"; return 0
    fi

    if [ "$mode" = gc ]; then
        mt="$(venv_newest_mtime "$venv")"
        if ! is_pos_int "$mt"; then
            printf 'keep\tunreadable-age\tno statable mtime in .venv — cannot apply the age floor\t%s\t%s\n' "${kb:-}" "$canon"; return 0
        fi
        now="$(now_epoch)"
        age=$((now - mt))
        if [ "$age" -lt "$REAP_VENV_MIN_AGE_SECONDS" ]; then
            printf 'keep\ttoo-recent\tnewest venv mtime %ss old < floor %ss\t%s\t%s\n' "$age" "$REAP_VENV_MIN_AGE_SECONDS" "${kb:-}" "$canon"; return 0
        fi
        printf 'reap\tdead-lane\tno-tmux-pane,no-proc-cwd,no-proc-argv; age %ss\t%s\t%s\n' "$age" "${kb:-}" "$canon"
        return 0
    fi
    printf 'reap\tlane-exited\tno-tmux-pane,no-proc-cwd,no-proc-argv (runner declared the lane done)\t%s\t%s\n' "${kb:-}" "$canon"
    return 0
}

# ── removal ──────────────────────────────────────────────────────────────────────────────────
# remove_one <canon> — delete `<canon>/.venv`, by BASENAME, from inside the verified worktree.
# Three things are re-asserted at the moment of deletion, because classification and removal are
# separated by several forks:
#   * the reaper is still not inside the worktree, and it is still not the main checkout;
#   * a FRESH liveness read still finds no holder (a lane that started between classify and remove
#     keeps its env);
#   * `.venv` is still a real directory and `<canon>` still resolves to itself — then the delete runs
#     in the shell's own cwd as `rm -rf -- .venv`, so a symlink swapped in for the PATH cannot
#     redirect it. That is also what makes the `uv` cache unreachable from this code path.
remove_one() {
    local canon="$1" mode="${2:-gc}" rc=0 live out
    # The same gc-only self rule classify() applies (never a second, weaker one): in `--worktree` mode
    # the caller's cwd IS the worktree, so applying it there would make exit-mode reaping impossible.
    if [ "$mode" = gc ] && [ -n "$SELF_CWD_CANON" ] && inside "$canon" "$SELF_CWD_CANON"; then
        log_line "SKIP $canon/.venv — the reaper's own cwd is inside it"
        return 2
    fi
    if [ -L "$canon/.venv" ] || [ ! -d "$canon/.venv" ]; then
        log_line "SKIP $canon/.venv — no longer a real directory"
        return 2
    fi
    # A fresh read of ALL THREE witnesses: the pass table may be minutes old on a large estate.
    # The same probe order as the pass level: cwd + tmux first, `ps` last so the self-tree sees it.
    if ! cwd_load; then
        # The SAME policy as the pass-level probe (never a second, weaker one): a degraded cwd read is
        # abortive unless the operator has explicitly accepted tmux+argv-only evidence.
        if [ "$REAP_VENV_ALLOW_DEGRADED_CWD" = "1" ]; then
            log_line "warn: cwd probe DEGRADED at removal time — tmux+argv evidence only (REAP_VENV_ALLOW_DEGRADED_CWD=1)"
        else
            log_line "FAIL-CLOSED: cwd probe unavailable before removal of $canon/.venv"; return 1
        fi
    fi
    tmux_load || { log_line "FAIL-CLOSED: tmux probe failed before removal of $canon/.venv"; return 1; }
    ps_load || { log_line "FAIL-CLOSED: ps unavailable before removal of $canon/.venv"; return 1; }
    self_load
    if live="$(live_witness "$canon")"; then
        log_line "SKIP $canon/.venv — went live before removal: ${live//$TAB/ }"
        return 2
    fi
    out="$(bound_file rmout)" || { log_line "SKIP $canon/.venv — no scratch dir"; return 1; }
    # ⛔ THE REMOVAL SUBSHELL MUST NOT INHERIT THE EXIT TRAP EITHER (review of PR #1949): `cleanup`
    # deletes the SHARED `$SCRATCH`, and on a bash that runs an inherited EXIT trap in a subshell (3.2 —
    # exactly the bash where cleanup()'s BASHPID guard cannot fire) that would delete the parent's
    # scratch dir MID-PASS: `$out` vanishes, so every removal AFTER the first reads
    # `REMOVE-FAILED ... rc=1` and the pass exits 4 reporting a reap that failed. `trap - EXIT` here is
    # the half that covers 3.2; the BASHPID guard in cleanup() is the redundant half on bash >= 4.
    if ( trap - EXIT; cd "$canon" 2>/dev/null && [ "$(pwd -P)" = "$canon" ] && run_bounded "$REAP_VENV_REMOVE_TIMEOUT" "$out" "$RM_BIN" -rf -- .venv ); then
        rc=0
    else
        rc=$?
    fi
    if [ -d "$canon/.venv" ] || [ -L "$canon/.venv" ]; then
        log_line "REMOVE-FAILED $canon/.venv (rc=$rc) $(head -2 "$out" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    log_line "REAPED $canon/.venv"
    return 0
}

# ── modes ────────────────────────────────────────────────────────────────────────────────────
parse_args() {
    local a
    # ⛔ `run_bounded` arms NO watchdog unless its bound is a positive integer, so a misconfigured
    # timeout silently makes the probe UNBOUNDED — the exact failure the call site claims to
    # prevent (measured: `0` and `abc` both ran a 30 s probe to completion). Validated here, where
    # the other seams are, with a loud fallback rather than a silent one.
    # ⛔ A RANGE CHECK, NOT "DIGITS AND NOT ZERO" (review round 3): `is_pos_int` accepts any digit
    # string, and `[ <huge> -eq 0 ]` ERRORS rather than returning false — so an all-digit value above
    # intmax skipped the fallback entirely and left the probe UNBOUNDED, the exact fail-open this
    # validation was added to prevent (the same class #2158 fixed for the age floor). String compare
    # for the zero test, and a length cap before any numeric comparison, so the check cannot itself
    # emit an arithmetic error.
    # ⛔ LEADING ZEROS ARE NORMALISED FIRST, exactly as the age floor does it (#2158): a string compare
    # against "0" refuses only that spelling, so `00`/`000` would pass and then mean zero to
    # `run_bounded`'s numeric test — no watchdog, no warning: the same fail-open in a different spelling.
    # Strip them, then range-check the NORMALISED form (so `000060` is a valid 60s, not a false refusal).
    _vct="${REAP_VENV_VENV_COST_TIMEOUT:-}"
    _vct_norm="${_vct#"${_vct%%[!0]*}"}"
    _vct_ok=0
    case "$_vct" in
        ''|*[!0-9]*) _vct_ok=0 ;;
        *) [ "${#_vct_norm}" -ge 1 ] && [ "${#_vct_norm}" -le 5 ] && [ "$_vct_norm" != "0" ] && _vct_ok=1 ;;
    esac
    if [ "$_vct_ok" = "0" ]; then
        echo "warn: REAP_VENV_VENV_COST_TIMEOUT='${REAP_VENV_VENV_COST_TIMEOUT:-}' is not a positive integer — using 60s; an invalid bound in run_bounded arms no watchdog at all" >&2
        log "warn: REAP_VENV_VENV_COST_TIMEOUT invalid ('${REAP_VENV_VENV_COST_TIMEOUT:-}') — fell back to 60s"
        REAP_VENV_VENV_COST_TIMEOUT=60
    else
        REAP_VENV_VENV_COST_TIMEOUT="$_vct_norm"
    fi
    while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
            --worktree)   shift; WORKTREE="${1:-}"; [ -n "$WORKTREE" ] || { usage >&2; exit 2; }; MODE=exit ;;
            --gc)         MODE=gc ;;
            --repo)       shift; REPO="${1:-}"; [ -n "$REPO" ] || { usage >&2; exit 2; } ;;
            --min-age)    shift; REAP_VENV_MIN_AGE_SECONDS="${1:-}"; is_pos_int "$REAP_VENV_MIN_AGE_SECONDS" || { echo "bad --min-age: ${1:-}" >&2; exit 2; } ;;
            --apply)      REAP_VENV_DRY="0" ;;
            --dry-run)    REAP_VENV_DRY="1" ;;
            --help|-h)    usage; exit 0 ;;
            *)            usage >&2; exit 2 ;;
        esac
        shift
    done
    [ -n "$MODE" ] || MODE=gc
    if [ "$MODE" = exit ] && [ -n "$REPO" ]; then usage >&2; exit 2; fi
    if [ "$MODE" = gc ] && [ -n "$WORKTREE" ]; then usage >&2; exit 2; fi
    # --apply/--dry-run explicit wins; otherwise the env seam (dry-run by default) decides.
    if [ -n "$REAP_VENV_DRY" ]; then
        APPLY=0; [ "$REAP_VENV_DRY" = "0" ] && APPLY=1
    else
        APPLY=0; [ "${REAP_VENV_DRY_RUN:-1}" = "0" ] && APPLY=1
    fi
    # ⛔ THE AGE FLOOR IS VALIDATED BEFORE IT IS EVER COMPARED (#2158). `--min-age` was checked at
    # parse time and the ENV form was not, so `REAP_VENV_MIN_AGE_SECONDS=30m` (any typo) made the
    # `[ "$age" -lt "$REAP_VENV_MIN_AGE_SECONDS" ]` test ERROR, take the else branch under
    # `set -uo pipefail` (no `-e`), and fall straight through to reaping: the floor that covers the
    # window between `git worktree add` and the first process binding to the new lane was silently
    # DISABLED, in the direction that destroys a live lane's env. It failed OPEN.
    # The fix is the check `--min-age` ALREADY applied at parse time, moved to the final value (env or
    # argv) so no path into this script can skip it. EXIT 2 — a misconfiguration the OPERATOR can fix —
    # never 3: a delegate's 3 is the pass's fail-closed code (a RED unit), and a typo must not be able
    # to reach any code whose meaning is other than "this is wrong, fix it". Nothing is removed: this
    # runs before any probe or sweep.
    if ! is_pos_int "${REAP_VENV_MIN_AGE_SECONDS:-}"; then
        echo "FAIL-CLOSED abort: REAP_VENV_MIN_AGE_SECONDS='${REAP_VENV_MIN_AGE_SECONDS:-}' is not a whole number of seconds (set it from the environment or --min-age; default 1800). Nothing removed (exit 2)." >&2
        log "FAIL-CLOSED abort: invalid age floor '${REAP_VENV_MIN_AGE_SECONDS:-}'"
        exit 2
    fi
    # ✅ AND BOUNDED, not just all-digits (#2158 residual). `is_pos_int` accepts any digit string, but
    # `[ -lt ]` parses with strtoimax: a value above 2^63-1 makes the COMPARISON ITSELF error and take
    # the else branch — the same fail-open, one size class up (measured: 99999999999999999999 passes
    # `is_pos_int`, then `[` prints "integer expression expected" and control falls through to REAP).
    # Leading zeros are harmless to `[` (base 10), so they are stripped before the length test rather
    # than refused. Nine digits is 31 years: no real floor can exceed it.
    floor_norm="${REAP_VENV_MIN_AGE_SECONDS#"${REAP_VENV_MIN_AGE_SECONDS%%[!0]*}"}"
    [ -n "$floor_norm" ] || floor_norm=0
    if [ "${#floor_norm}" -gt 9 ]; then
        echo "FAIL-CLOSED abort: REAP_VENV_MIN_AGE_SECONDS='$REAP_VENV_MIN_AGE_SECONDS' is out of range — at most 9 digits (~31 years). Nothing removed (exit 2)." >&2
        log "FAIL-CLOSED abort: out-of-range age floor '$REAP_VENV_MIN_AGE_SECONDS'"
        exit 2
    fi
    return 0
}

# ⛔ ONE VALIDATOR FOR THE AGE FLOOR, AND IT LIVES IN parse_args (#2173 merge artifact).
# This file used to carry a second validator here (`validate_config`) that re-tested the SAME predicate
# on the SAME variable and exited **3**. It was unreachable (parse_args is the only path into `main`
# and its tail already refuses the floor), and it stated the OPPOSITE contract to the reachable one:
# a typo must reach exit 2 ("this is wrong, fix it"), never a delegate's 3 (the pass's fail-closed code,
# which paints the unit RED). Two mutually exclusive rules for one seam is the state that must not
# ship, so the dead copy is deleted rather than left as documentation that contradicts the code.
# The live contract, pinned by reap-lane-venvs.test.sh §J and disk-reaper.test.sh T13: exit 2.

# probes_ready — ONE read of each witness for the whole pass, with the fail-closed policy applied.
probes_ready() {
    # ⛔ CREATE THE SCRATCH DIR HERE, IN THE PARENT, BEFORE ANY PROBE RUNS. `bound_file` is called from
    # inside COMMAND SUBSTITUTIONS (subshells), so a lazily-created SCRATCH was created in the CHILD and
    # the parent's `cleanup` trap then removed only a SECOND dir it made later — one
    # `reap-lane-venvs.XXXXXX` directory survived every pass (~8.7k/year at the hourly cadence), i.e. the
    # reaper leaked unboundedly into the very sink it exists to drain. A subshell inherits the parent's
    # variable, so making it here means every probe reuses THIS directory and `cleanup` can reap it.
    # (Same root as the `bounded.*` leak fixed in `disk-reaper.sh`.)
    scratch_dir || echo "warn: no writable TMPDIR — probes will run without a scratch dir" >&2
    # ⛔ ORDER IS LOAD-BEARING: the cwd and tmux probes run FIRST, the `ps` table LAST. The self-tree is
    # computed from that table, so a probe child still alive has to be IN it — and a probe that has
    # already exited cannot contribute a matching row anyway, because it ran from `/` (run_probe).
    if ! cwd_load; then
        if [ "$REAP_VENV_ALLOW_DEGRADED_CWD" = "1" ]; then
            echo "warn: cwd probe DEGRADED (no working lsof or /proc) — liveness rests on tmux + argv only, because REAP_VENV_ALLOW_DEGRADED_CWD=1" >&2
            log "warn: cwd probe degraded; proceeding on tmux+argv (explicitly allowed)"
        else
            echo "FAIL-CLOSED abort: cannot read any process cwd (LSOF_BIN=$LSOF_BIN, /proc unreadable) — a lane could be mid-test invisibly, nothing removed (exit 3). Set REAP_VENV_ALLOW_DEGRADED_CWD=1 to accept tmux+argv evidence only." >&2
            log "FAIL-CLOSED abort: cwd probe unavailable"
            return 1
        fi
    fi
    if ! tmux_load; then
        echo "FAIL-CLOSED abort: tmux is installed but cannot list panes ($TMUX_BIN) — it could be hiding a live lane, nothing removed (exit 3)" >&2
        log "FAIL-CLOSED abort: tmux probe failed"
        return 1
    fi
    if ! ps_load; then
        echo "FAIL-CLOSED abort: ps probe unavailable (PS_BIN=$PS_BIN) — cannot prove any lane is dead, nothing removed (exit 3)" >&2
        log "FAIL-CLOSED abort: ps probe unavailable ($PS_BIN)"
        return 1
    fi
    self_load
    return 0
}

report_row() {
    local row="$1"
    local verdict reason evidence kb path
    verdict="${row%%$TAB*}"
    row="${row#*$TAB}"; reason="${row%%$TAB*}"
    row="${row#*$TAB}"; evidence="${row%%$TAB*}"
    row="${row#*$TAB}"; kb="${row%%$TAB*}"
    path="${row#*$TAB}"
    printf '%-4s %-20s %8s  %s\n' "$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')" "$reason" \
        "$( [ -n "$kb" ] && printf '%sMB' "$((kb / 1024))" || printf '?')" "$path"
    [ -n "$evidence" ] && printf '       evidence: %s\n' "$evidence"
    log "$(printf '%s\t%s\t%s\t%s\t%s' "$verdict" "$reason" "$evidence" "${kb:-}" "$path")"
    FOUND=$((FOUND + 1))
    case "$reason" in live-*) LANES_LIVE=$((LANES_LIVE + 1)) ;; esac
    # The per-lane figure the headroom below divides by: the LARGEST env this pass saw, so the answer
    # is "how many lanes fit if they are all this expensive" rather than an average that under-budgets.
    is_pos_int "${kb:-}" && [ "$kb" -gt "$LANE_VENV_KB_MAX" ] && LANE_VENV_KB_MAX="$kb"
    # The real cost of THIS env (#2159). Measured per row, not derived: the private-block count is
    # the one number `du` cannot produce, and it is what separates a 99 MB env from a 5.6 GB one
    # that `du` prices identically. Tracked as a MAX over the pass, like the `du` figure above, so
    # the reported per-lane cost is the worst env seen rather than a mean.
    if [ -d "$path/.venv" ] && real_row="$(venv_real_cost "$path/.venv")"; then
        real_priv="${real_row%%$TAB*}"; real_rest="${real_row#*$TAB}"
        real_dedupe="${real_rest##*$TAB}"
        if is_pos_int "$real_priv"; then
            LANE_VENV_REAL_MEASURED=1
            [ "$real_priv" -gt "$LANE_VENV_REAL_KB_MAX" ] && LANE_VENV_REAL_KB_MAX="$real_priv"
        fi
        case "$real_dedupe" in
            degraded) VENV_DEGRADED=$((VENV_DEGRADED + 1)); VENV_DEDUPE="degraded" ;;
            ok) [ "$VENV_DEDUPE" = "degraded" ] || VENV_DEDUPE="ok" ;;
            *)  : ;;
        esac
    fi
    if [ "$verdict" = reap ]; then
        REAPABLE=$((REAPABLE + 1))
        is_pos_int "$kb" && DU_KB=$((DU_KB + kb))
    else
        KEPT=$((KEPT + 1))
    fi
    return 0
}

run_gc() {
    local repo="${REPO:-$PWD}" canon list wt row outf rrc
    canon="$(canonicalize "$repo")"
    if [ -z "$canon" ]; then
        echo "FAIL-CLOSED abort: --repo '$repo' cannot be resolved (exit 3)" >&2; exit 3
    fi
    if ! "$GIT_BIN" -C "$canon" rev-parse --git-dir >/dev/null 2>&1; then
        echo "FAIL-CLOSED abort: '$canon' is not a git checkout, so its worktrees cannot be enumerated (exit 3)" >&2
        exit 3
    fi
    DF_BEFORE="$(df_free_kb "$canon")"
    # Enumeration is `git worktree list` (admin files only) — never a directory walk, never `find`.
    # A listing that cannot be produced is an ABORT, not an empty population: "no worktrees" and
    # "could not look" must never read the same, or the GC reports a clean pass over nothing.
    outf="$(bound_file wtlist)" || { echo "FAIL-CLOSED abort: no scratch dir for the worktree listing (exit 3)" >&2; exit 3; }
    if ! run_bounded "$REAP_VENV_GIT_TIMEOUT" "$outf" "$GIT_BIN" -C "$canon" worktree list --porcelain; then
        echo "FAIL-CLOSED abort: git could not list the worktrees of $canon (exit 3)" >&2; exit 3
    fi
    list="$(awk '/^worktree /{print substr($0,10)}' "$outf" 2>/dev/null)"
    if [ -z "$list" ]; then
        echo "FAIL-CLOSED abort: $canon reports no worktrees at all — that cannot be true of a checkout (exit 3)" >&2; exit 3
    fi
    while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        row="$(classify "$wt" gc)"
        [ -n "$row" ] || continue
        report_row "$row"
        case "$row" in
            reap"$TAB"*)
                if [ "$APPLY" = 1 ]; then
                    remove_one "$(canonicalize "$wt")" gc; rrc=$?
                    case "$rrc" in
                        0) REAPED=$((REAPED + 1)) ;;
                        2) RECHECK_KEPT=$((RECHECK_KEPT + 1)) ;;
                        *) FAILED=$((FAILED + 1)) ;;
                    esac
                fi ;;
        esac
    done <<<"$list"
    return 0
}

run_exit() {
    local canon row rrc
    canon="$(canonicalize "$WORKTREE")"
    if [ -z "$canon" ]; then
        echo "FAIL-CLOSED abort: --worktree '$WORKTREE' cannot be resolved (exit 3)" >&2; exit 3
    fi
    DF_BEFORE="$(df_free_kb "$canon")"
    row="$(classify "$canon" exit)"
    if [ -z "$row" ]; then
        log_line "[$SCRIPT_NAME] no .venv in $canon — nothing to reap"
        return 0
    fi
    report_row "$row"
    case "$row" in
        reap"$TAB"*)
            if [ "$APPLY" = 1 ]; then
                remove_one "$canon" exit; rrc=$?
                case "$rrc" in
                    0) REAPED=$((REAPED + 1)) ;;
                    2) RECHECK_KEPT=$((RECHECK_KEPT + 1)) ;;
                    *) FAILED=$((FAILED + 1)) ;;
                esac
            fi ;;
    esac
    return 0
}

# ── capacity: how many more lanes this box can take (the stated floor, asserted) ───────────
# Called with the post-pass free reading so the capacity line and the reclamation line cannot disagree
# about the same filesystem. Sets CAPACITY_FLOOR_OK for the exit code; prints every input it used, so a
# reader can re-do the division rather than trust it (#1932 acceptance: "N measured, floor asserted,
# both printed").
report_capacity() { # report_capacity <free_kb_after>
    local free_kb="${1:-}" floor="$REAP_VENV_FREE_FLOOR_MB" free_mb="" per_lane_mb="" headroom="?"
    local floor_ok="unknown" why=""
    if ! is_pos_int "$floor"; then
        why="REAP_VENV_FREE_FLOOR_MB='$REAP_VENV_FREE_FLOOR_MB' is not a positive integer — asserting the default 2048MB instead"
        floor=2048
    fi
    if is_pos_int "${free_kb:-}"; then
        free_mb=$((free_kb / 1024))
        if [ "$free_mb" -lt "$floor" ]; then floor_ok="no"; else floor_ok="yes"; fi
    else
        why="${why:+$why; }df cannot read free space on ${REPO:-${WORKTREE:-$PWD}} — free space is UNKNOWN, so the floor is NOT claimed satisfied"
    fi
    if [ "${LANE_VENV_KB_MAX:-0}" -gt 0 ]; then
        per_lane_mb=$((LANE_VENV_KB_MAX / 1024))
        [ "$per_lane_mb" -ge 1 ] || per_lane_mb=1
        if is_pos_int "${free_mb:-}"; then
            headroom=0
            [ "$free_mb" -gt "$floor" ] && headroom=$(( (free_mb - floor) / per_lane_mb ))
        fi
    fi
    # The real-cost pair (#2159): `lane_venv_real` is the LARGEST private-block count seen (what
    # reaping one such env actually frees), and `venv_dedupe` says whether this box's link regime is
    # in force. `?`/`unknown` when the probe could not run — never 0.
    # Gated on MEASURED, not on `> 0`: a shared env legitimately reports 0 private KB.
    local real_mb="?"
    if [ "${LANE_VENV_REAL_MEASURED:-0}" = "1" ]; then
        real_mb=$((LANE_VENV_REAL_KB_MAX / 1024))
    fi
    log_line "[$SCRIPT_NAME] capacity: lanes_live=$LANES_LIVE lane_venv_max=${per_lane_mb:-?}MB lane_venv_real=${real_mb}MB venv_dedupe=$VENV_DEDUPE venv_degraded=$VENV_DEGRADED free_after=${free_mb:-?}MB floor=${floor}MB floor_ok=$floor_ok lanes_headroom=$headroom"
    [ -n "$why" ] && log_line "[$SCRIPT_NAME] capacity: $why"
    log "$(printf 'capacity\tlanes_live=%s\tper_lane_mb=%s\tlane_venv_real_mb=%s\tvenv_dedupe=%s\tvenv_degraded=%s\tfree_after_mb=%s\tfloor_mb=%s\tfloor_ok=%s\tlanes_headroom=%s' \
        "$LANES_LIVE" "${per_lane_mb:-}" "${real_mb}" "$VENV_DEDUPE" "$VENV_DEGRADED" "${free_mb:-}" "$floor" "$floor_ok" "$headroom")"
    CAPACITY_FLOOR_OK="$floor_ok"
    CAPACITY_FLOOR_MB="$floor"
    return 0
}

main() {
    local mode_label df_after freed_kb reclaimed_mb
    parse_args "$@"   # validates AND bounds REAP_VENV_MIN_AGE_SECONDS (exit 2) — see its tail

    SELF_CWD_CANON="$(canonicalize "$PWD")"
    if [ "$MODE" = exit ]; then mode_label="exit (lane teardown)"; else mode_label="gc"; fi
    if [ "$APPLY" = 1 ]; then
        mkdir -p "$(dirname "$REAP_VENV_LOG")" 2>/dev/null || true
        if ! : >>"$REAP_VENV_LOG" 2>/dev/null; then
            echo "FAIL-CLOSED abort: REAP_VENV_LOG unwritable ($REAP_VENV_LOG) — an armed pass must not delete without an audit trail (exit 3)" >&2
            exit 3
        fi
    fi

    probes_ready || exit 3

    log_line "[$SCRIPT_NAME] mode=$mode_label apply=$APPLY repo=${REPO:-$PWD} worktree=${WORKTREE:--}"
    case "$TMUX_STATE" in
        ok) log_line "[$SCRIPT_NAME] witnesses: tmux panes + process cwd + process argv" ;;
        absent) log_line "[$SCRIPT_NAME] witnesses: process cwd + process argv (no tmux server on this host)" ;;
    esac
    [ "$CWD_STATE" = "ok" ] || log_line "[$SCRIPT_NAME] warn: cwd witness DEGRADED (see above)"

    if [ "$MODE" = exit ]; then run_exit; else run_gc; fi

    df_after="$(df_free_kb "${REPO:-${WORKTREE:-$PWD}}")"
    freed_kb=""
    if is_pos_int "${DF_BEFORE:-}" && is_pos_int "${df_after:-}"; then
        freed_kb=$((df_after - DF_BEFORE))
        [ "$freed_kb" -lt 0 ] && freed_kb=0
    fi
    reclaimed_mb="?"
    is_pos_int "${freed_kb:-}" && reclaimed_mb=$((freed_kb / 1024))

    log_line "[$SCRIPT_NAME] venvs_found=$FOUND reapable=$REAPABLE reaped=$REAPED kept=$KEPT recheck_kept=$RECHECK_KEPT failed=$FAILED"
    # The two numbers answer different questions — see the header. `du` is the APPARENT size: it
    # counts blocks shared with the uv cache once per link, so it over-states ONLY on a box where
    # such sharing exists (hardlink OR clonefile — measured PER MACHINE; the old universal hardlink
    # claim was falsified 2026-10-16, #1851). `df` is what the filesystem actually got back.
    log_line "[$SCRIPT_NAME] reclaimed_du=$((DU_KB / 1024))MB reclaimed_df=${reclaimed_mb}MB (du counts blocks SHARED with the uv cache once per link and over-counts only where that sharing exists — per machine, measure it with the sibling worktree-disk-probe.sh (beside this script); df is the real figure)"
    report_capacity "${df_after:-}"
    [ "$APPLY" = 1 ] || log_line "[$SCRIPT_NAME] DRY-RUN — nothing was removed (pass --apply or REAP_VENV_DRY_RUN=0)"

    # Severity order matches disk-reaper.sh's own INTENT (3 abort > 4 removal failed > 5 over-bound),
    # so the fleet entry point's worst-code rule keeps the most severe verdict instead of this pass
    # inventing a second ordering. (disk-reaper.sh now KEEPS a delegate 5 and ranks it fail-closed in
    # an apply pass — the gap this ordering was written for is closed, #2156.)
    #
    # ⛔ THE BREACH IS NAMED AND LOGGED BEFORE THE LADDER, NOT INSIDE THE `exit 5` ARM (review of PR
    # #1949): when a removal ALSO failed, exit 4 preempts exit 5, and the old placement meant the
    # `over-bound` audit row was never written — so the one pass shape where the floor is breached AND
    # the pass is already degraded was the one shape with no audit record of the breach. A breach an
    # operator cannot find because a removal failed first is a silent breach. The EXIT CODE order is
    # unchanged (4 still wins); only the record's survival is fixed.
    if [ "$CAPACITY_FLOOR_OK" = "no" ]; then
        log_line "[$SCRIPT_NAME] ⛔ free space is BELOW the stated floor: a lane starting now can fill the disk. Refusing nothing — a live lane's env is never deleted to make room (exit 5, or exit 4 if a removal also failed — a failed removal outranks a breach)"
        log "over-bound\tfree_below_floor_mb=${CAPACITY_FLOOR_MB:-$REAP_VENV_FREE_FLOOR_MB}"
    fi
    [ "$FAILED" -gt 0 ] && exit 4
    [ "$CAPACITY_FLOOR_OK" = "no" ] && exit 5
    exit 0
}

trap cleanup EXIT
main "$@"
