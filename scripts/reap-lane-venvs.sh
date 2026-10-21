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
#   REAP_VENV_REMOVE_TIMEOUT REAP_VENV_ALLOW_DEGRADED_CWD REAP_VENV_PROC_ROOT
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
say() { printf '%s\n' "$*"; log "$*"; }
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
argv_witness_for() {
    local canon="$1" base="${1##*/}" tok d pid line
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

cwd_witness_for() {
    local canon="$1" pid path
    [ -n "$canon" ] && [ -s "${CWD_TABLE:-}" ] || return 1
    while IFS="$TAB" read -r pid path; do
        [ -n "$pid" ] && [ -n "$path" ] || continue
        is_self_pid "$pid" && continue
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

tmux_witness_for() {
    local canon="$1" pid path cpane
    [ "$TMUX_STATE" = "ok" ] && [ -s "${TMUX_TABLE:-}" ] || return 1
    while IFS="$TAB" read -r pid path; do
        [ -n "$pid" ] && [ -n "$path" ] || continue
        is_self_pid "$pid" && continue
        cpane="$(canonicalize "$path")"
        [ -n "$cpane" ] || cpane="$path"
        inside "$canon" "$cpane" || continue
        printf 'pane_pid=%s pane_path=%s\n' "$pid" "$cpane"
        return 0
    done <"$TMUX_TABLE"
    return 1
}

# live_witness <canon> — "<witness>\t<evidence>" when a live holder exists, nothing when none.
live_witness() {
    local canon="$1" hit
    if hit="$(tmux_witness_for "$canon")"; then printf 'live-tmux-pane\t%s\n' "$hit"; return 0; fi
    if hit="$(cwd_witness_for "$canon")"; then printf 'live-cwd\t%s\n' "$hit"; return 0; fi
    if hit="$(argv_witness_for "$canon")"; then printf 'live-argv\t%s\n' "$hit"; return 0; fi
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
        say "SKIP $canon/.venv — the reaper's own cwd is inside it"
        return 2
    fi
    if [ -L "$canon/.venv" ] || [ ! -d "$canon/.venv" ]; then
        say "SKIP $canon/.venv — no longer a real directory"
        return 2
    fi
    # A fresh read of ALL THREE witnesses: the pass table may be minutes old on a large estate.
    # The same probe order as the pass level: cwd + tmux first, `ps` last so the self-tree sees it.
    if ! cwd_load; then
        # The SAME policy as the pass-level probe (never a second, weaker one): a degraded cwd read is
        # abortive unless the operator has explicitly accepted tmux+argv-only evidence.
        if [ "$REAP_VENV_ALLOW_DEGRADED_CWD" = "1" ]; then
            say "warn: cwd probe DEGRADED at removal time — tmux+argv evidence only (REAP_VENV_ALLOW_DEGRADED_CWD=1)"
        else
            say "FAIL-CLOSED: cwd probe unavailable before removal of $canon/.venv"; return 1
        fi
    fi
    tmux_load || { say "FAIL-CLOSED: tmux probe failed before removal of $canon/.venv"; return 1; }
    ps_load || { say "FAIL-CLOSED: ps unavailable before removal of $canon/.venv"; return 1; }
    self_load
    if live="$(live_witness "$canon")"; then
        say "SKIP $canon/.venv — went live before removal: ${live//$TAB/ }"
        return 2
    fi
    out="$(bound_file rmout)" || { say "SKIP $canon/.venv — no scratch dir"; return 1; }
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
        say "REMOVE-FAILED $canon/.venv (rc=$rc) $(head -2 "$out" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    say "REAPED $canon/.venv"
    return 0
}

# ── modes ────────────────────────────────────────────────────────────────────────────────────
parse_args() {
    local a
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
        say "[$SCRIPT_NAME] no .venv in $canon — nothing to reap"
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
    say "[$SCRIPT_NAME] capacity: lanes_live=$LANES_LIVE lane_venv_max=${per_lane_mb:-?}MB free_after=${free_mb:-?}MB floor=${floor}MB floor_ok=$floor_ok lanes_headroom=$headroom"
    [ -n "$why" ] && say "[$SCRIPT_NAME] capacity: $why"
    log "$(printf 'capacity\tlanes_live=%s\tper_lane_mb=%s\tfree_after_mb=%s\tfloor_mb=%s\tfloor_ok=%s\tlanes_headroom=%s' \
        "$LANES_LIVE" "${per_lane_mb:-}" "${free_mb:-}" "$floor" "$floor_ok" "$headroom")"
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

    say "[$SCRIPT_NAME] mode=$mode_label apply=$APPLY repo=${REPO:-$PWD} worktree=${WORKTREE:--}"
    case "$TMUX_STATE" in
        ok)     say "[$SCRIPT_NAME] witnesses: tmux panes + process cwd + process argv" ;;
        absent) say "[$SCRIPT_NAME] witnesses: process cwd + process argv (no tmux server on this host)" ;;
    esac
    [ "$CWD_STATE" = "ok" ] || say "[$SCRIPT_NAME] warn: cwd witness DEGRADED (see above)"

    if [ "$MODE" = exit ]; then run_exit; else run_gc; fi

    df_after="$(df_free_kb "${REPO:-${WORKTREE:-$PWD}}")"
    freed_kb=""
    if is_pos_int "${DF_BEFORE:-}" && is_pos_int "${df_after:-}"; then
        freed_kb=$((df_after - DF_BEFORE))
        [ "$freed_kb" -lt 0 ] && freed_kb=0
    fi
    reclaimed_mb="?"
    is_pos_int "${freed_kb:-}" && reclaimed_mb=$((freed_kb / 1024))

    say "[$SCRIPT_NAME] venvs_found=$FOUND reapable=$REAPABLE reaped=$REAPED kept=$KEPT recheck_kept=$RECHECK_KEPT failed=$FAILED"
    # The two numbers answer different questions — see the header. `du` is the APPARENT size: it
    # counts blocks shared with the uv cache once per link, so it over-states ONLY on a box where
    # such sharing exists (hardlink OR clonefile — measured PER MACHINE; the old universal hardlink
    # claim was falsified 2026-10-16, #1851). `df` is what the filesystem actually got back.
    say "[$SCRIPT_NAME] reclaimed_du=$((DU_KB / 1024))MB reclaimed_df=${reclaimed_mb}MB (du counts blocks SHARED with the uv cache once per link and over-counts only where that sharing exists — per machine, measure it with scripts/worktree-disk-probe.sh; df is the real figure)"
    report_capacity "${df_after:-}"
    [ "$APPLY" = 1 ] || say "[$SCRIPT_NAME] DRY-RUN — nothing was removed (pass --apply or REAP_VENV_DRY_RUN=0)"

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
        say "[$SCRIPT_NAME] ⛔ free space is BELOW the stated floor: a lane starting now can fill the disk. Refusing nothing — a live lane's env is never deleted to make room (exit 5, or exit 4 if a removal also failed — a failed removal outranks a breach)"
        log "over-bound\tfree_below_floor_mb=${CAPACITY_FLOOR_MB:-$REAP_VENV_FREE_FLOOR_MB}"
    fi
    [ "$FAILED" -gt 0 ] && exit 4
    [ "$CAPACITY_FLOOR_OK" = "no" ] && exit 5
    exit 0
}

trap cleanup EXIT
main "$@"
