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
#                    SHA is reachable from some ref. A detached SHA on no ref
#                    would be ORPHANED => preserve — including when the
#                    checkout's directory is already gone, because the admin
#                    record's HEAD is the last thing holding that commit.
#   * aged         — HEAD commit strictly older than REAP_WT_AGED_DAYS (7)
# Anything failing clean / reachable / unreferenced is SURFACED with its
# deciding reason and NEVER auto-removed.
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
# reproducible-from-manifest artifact at the worktree ROOT. Anything else
# ignored (`!! path`) is `ignored-artifact` => PRESERVE. This matters because
# `git worktree remove` does NOT refuse ignored files (verified): without the
# ignored half of the gate, a worktree holding only a gitignored `.env` or
# experiment output would look "clean" and be silently destroyed.
#   Allowlisted UNTRACKED (`??`) entries are deleted explicitly before removal
# because git WILL refuse on them; a refusal is reported, never swallowed.
#   `--force` is never passed and `git branch -D` is never called.
#
# DISK-SAVINGS HONESTY: per-worktree `.venv`s are hardlinked to the uv cache,
# so `du` over-reports them (measured: 84 GB `du` delta vs 22 GB actually
# freed). This script therefore NEVER calls `du` and NEVER claims a byte
# saving. The real, deliverable win is FILE COUNT — the amplification that
# produced the 10-18 minute repo-wide searches.
#
# BOUNDEDNESS (a reaper that hangs the fleet is worse than no reaper):
#   * enumeration is `git worktree list --porcelain [-z]` (admin files only) —
#     never `find .worktrees`, never a directory walk
#   * the clean gate uses --untracked-files=normal, so an untracked dir
#     (`.venv/`, `node_modules/`) collapses to ONE entry — git never recurses
#     into it (verified: 60 files under an ignored node_modules = one line)
#   * EVERY subprocess that can block runs under a watchdog (list / status /
#     ps / lsof / gh / rm / git worktree remove) — no GNU `timeout` needed on
#     macOS. `rm` is in that list because the allowlisted-ephemeral pre-delete
#     (remove_one) is a recursive filesystem delete over a checkout the operator
#     does not control: a huge or NFS-locked `.venv` can block it exactly as it
#     can block `git worktree remove`. It is the LAST fork on the removal path
#     and it runs under REAP_WT_REMOVE_TIMEOUT, so the script has no unbounded
#     subprocess anywhere.
#   * a GLOBAL wall-clock budget (REAP_WT_BUDGET_SECONDS, 300) bounds the
#     per-worktree work (classification AND removal); unprocessed worktrees are
#     reported `deferred` and preserved. The budget deliberately does NOT start
#     until the per-worktree loop begins: enumeration/ps/lsof already have their
#     own watchdogs, and charging their latency to the budget made a slow host
#     defer EVERY worktree on every pass — a reaper that silently never reaps.
#   * no `find`, `rg -r`, `du`, `lsof +D`, or recursive glob is executed
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
#   unreadable-path        exists but cannot be resolved (perm/unmount) — NOT
#                          prunable; deregistering it would drop a live record
#   prunable               checkout directory already gone, commits survive
#   worktree-locked        `git worktree lock` is set
#   detached-unreachable   deleting the checkout (or pruning the record) would
#                          leave the HEAD commit on no ref at all
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
#   REAP_WT_AGED_DAYS REAP_WT_MAX_DAYS REAP_WT_MAIN_REF REAP_WT_NOW_EPOCH
#   REAP_WT_LIST_TIMEOUT REAP_WT_STATUS_TIMEOUT REAP_WT_PS_TIMEOUT
#   REAP_WT_CWD_TIMEOUT REAP_WT_GH_TIMEOUT REAP_WT_REMOVE_TIMEOUT
#   REAP_WT_BUDGET_SECONDS REAP_WT_STATE_DIR REAP_WT_LOCK_STALE_SECONDS
#   REAP_WT_REPO_SLUG REAP_WT_PR_LIMIT
# Exit codes: 0 pass completed with nothing failed, 2 usage, 3 fail-closed
# abort (nothing trusted), 4 pass completed but >=1 removal FAILED.

set -uo pipefail

SCRIPT_NAME="pi-reap-worktrees.sh"
ISSUE_REF="#1095"

GIT_BIN="${GIT_BIN:-git}"
GH_BIN="${GH_BIN:-gh}"
PS_BIN="${PS_BIN:-/bin/ps}"
LSOF_BIN="${LSOF_BIN:-lsof}"
# Only the ephemeral pre-delete in remove_one uses this; the script's own
# scratch/log cleanup keeps the real `rm` (it must not be defeated by a seam).
RM_BIN="${RM_BIN:-rm}"
STATE_DIR="${REAP_WT_STATE_DIR:-${HOME:-}/.pi/agent/state}"
REAP_WT_LOG="${REAP_WT_LOG:-$STATE_DIR/pi-reap-worktrees.log}"
LOCK_DIR="$STATE_DIR/pi-reap-worktrees.lock"
REAP_WT_AGED_DAYS="${REAP_WT_AGED_DAYS:-7}"
REAP_WT_MAX_DAYS="${REAP_WT_MAX_DAYS:-1000000}"
REAP_WT_DRY_RUN="${REAP_WT_DRY_RUN:-1}"
REAP_WT_LIST_TIMEOUT="${REAP_WT_LIST_TIMEOUT:-30}"
REAP_WT_STATUS_TIMEOUT="${REAP_WT_STATUS_TIMEOUT:-20}"
REAP_WT_PS_TIMEOUT="${REAP_WT_PS_TIMEOUT:-20}"
REAP_WT_CWD_TIMEOUT="${REAP_WT_CWD_TIMEOUT:-5}"
REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-20}"
REAP_WT_REMOVE_TIMEOUT="${REAP_WT_REMOVE_TIMEOUT:-120}"
REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-300}"
REAP_WT_LOCK_STALE_SECONDS="${REAP_WT_LOCK_STALE_SECONDS:-1800}"
REAP_WT_PR_LIMIT="${REAP_WT_PR_LIMIT:-1000}"
REAP_WT_MAIN_REF="${REAP_WT_MAIN_REF:-}"
REAP_WT_REPO_SLUG="${REAP_WT_REPO_SLUG:-}"

# Declared-disposable, reproducible-from-manifest artifacts tolerated at the
# worktree ROOT. Deliberately narrow — `dist/`, `build/`, `target/`, `.next/`
# are NOT allowlisted (over-preserving is the safe direction, and the operator
# sees the offending path in the reason).
# NO trailing slashes: the match is against a path's basename (`${p%/}` then
# `##*/`), and a slash here silently disables the whole allowlist.
EPHEMERAL=" .venv node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .cache .DS_Store "

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
CWD_DEGRADED=0
REMOVED=0
FAILED=0
DEFERRED=0
WT_TOTAL=0
REMOVE_C=0
PRESERVE_C=0
GH_STATE=unknown
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

`git worktree remove` deletes the CHECKOUT, never the branch — named-branch
worktrees lose no commits, and this script never runs \`git branch -D\`.
No disk-savings figure is ever reported (see the header comment).

Run this from a terminal, from launchd, or from a session whose working
directory is a worktree — a session rooted in the shared main checkout is
blocked by the agent harness's script-content walker (#1484).
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "REAP $*"; }
log() { printf '%s\n' "$*" >>"$REAP_WT_LOG" 2>/dev/null || true; }

now_epoch() {
    if [ -n "${REAP_WT_NOW_EPOCH:-}" ]; then printf '%s\n' "$REAP_WT_NOW_EPOCH"; return 0; fi
    /bin/date +%s 2>/dev/null || date +%s
}

is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# run_bounded <seconds> <outfile> <cmd...>
# 0 = ok, 124 = timed out, other = the command's own status. `<seconds>` 0 means
# "no watchdog". macOS has no GNU `timeout`; a watchdog subshell writes a
# sentinel so a real SIGKILL is distinguishable from a command that exited 137.
#
# Fork economy is a correctness property here, not a micro-optimization: this
# tool runs ~10 bounded probes per pass on a host it exists to UNLOAD, and each
# probe used to cost two `mktemp` forks plus a `pkill -P` (an exec plus a full
# process-table scan). The scratch files now come from ONE per-run directory,
# and the watchdog holds its own timer as a child so a TERM tears the timer down
# — the `pkill` was only ever papering over the leak its predecessor created.
WATCHDOGS=""
BOUND_TMP=""
BOUND_N=0
bound_tmp() { # lazily create the per-run probe scratch dir; "" => degrade
    [ -n "$BOUND_TMP" ] && return 0
    BOUND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-wt.XXXXXX" 2>/dev/null)" || BOUND_TMP=""
    [ -n "$BOUND_TMP" ] || return 1
    return 0
}
bound_cleanup() { [ -n "$BOUND_TMP" ] && rm -rf "$BOUND_TMP"; BOUND_TMP=""; return 0; }

run_bounded() {
    local secs="$1" out="$2"; shift 2
    local pid wd="" s rc=0 sentinel="" done_flag=""
    BOUND_N=$((BOUND_N + 1))
    if bound_tmp; then
        sentinel="$BOUND_TMP/s.$BOUND_N"
        done_flag="$BOUND_TMP/d.$BOUND_N"
    fi
    : >"$out"
    "$@" >"$out" 2>/dev/null &
    pid=$!
    if is_pos_int "$secs" && [ "$secs" -gt 0 ]; then
        (
            # TERM means the parent finished with this probe: kill the timer and
            # leave without signalling anything. No orphaned `sleep`, so no
            # `pkill -P` sweep is needed.
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
    # The sentinel is the only way to tell "the watchdog killed it" from "the
    # command died with 137 on its own" — the exit status alone cannot.
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then rc=124; fi
    [ -n "$sentinel" ] && rm -f "$sentinel"
    [ -n "$done_flag" ] && rm -f "$done_flag"
    return $rc
}

watchdogs_reap() {
    local w
    for w in $WATCHDOGS; do kill -TERM "$w" 2>/dev/null; done
    WATCHDOGS=""
}

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
    r="$("$GIT_BIN" -C "$REPO_CANON" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"
    if [ -n "$r" ] && "$GIT_BIN" -C "$REPO_CANON" rev-parse --verify -q "$r" >/dev/null 2>&1; then
        printf '%s\n' "$r"; return 0
    fi
    for r in refs/remotes/origin/main refs/heads/main refs/remotes/origin/master refs/heads/master; do
        if "$GIT_BIN" -C "$REPO_CANON" rev-parse --verify -q "$r" >/dev/null 2>&1; then
            printf '%s\n' "$r"; return 0
        fi
    done
    printf ''
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

live_process_for() { # <canon> <recorded> -> matching pid ("" when none)
    local canon="$1" recorded="$2" pid line
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
        printf '%s\n' "$pid"
        return 0
    done
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid="${line%% *}"
        case "$SELF_PIDS" in *" $pid "*) continue ;; esac
        case "$line" in *"/${canon##*/}"*) ;; *) continue ;; esac
        if canonical_token_match "$line" "$canon"; then printf '%s\n' "$pid"; return 0; fi
    done <<<"$(grep -F -- "/${canon##*/}" "$PS_OUT" 2>/dev/null)"
    return 1
}

# cwd_probe_load — ONE bounded `lsof -a -d cwd` pass (never the `+D` directory
# walk, which would be unbounded). Best-effort by design: a missing or slow
# lsof sets CWD_DEGRADED and the pass falls back to the argv probe — reported in
# the footer and the log, never a silent pass.
cwd_probe_load() {
    CWD_OUT="$(mktemp "${TMPDIR:-/tmp}/pi-reap-cwd.XXXXXX")" || { CWD_OUT=""; CWD_DEGRADED=1; return 0; }
    if ! command -v "$LSOF_BIN" >/dev/null 2>&1; then
        CWD_DEGRADED=1; log "CWD probe degraded: $LSOF_BIN not found — argv-only live-reference check"; return 0
    fi
    run_bounded "$REAP_WT_CWD_TIMEOUT" "$CWD_OUT" "$LSOF_BIN" -a -d cwd -Fpn
    if [ $? != 0 ] || [ ! -s "$CWD_OUT" ]; then
        CWD_DEGRADED=1; log "CWD probe degraded: lsof failed/empty — argv-only live-reference check"
    fi
    return 0
}

live_cwd_for() { # <canon> <recorded> -> pid whose cwd is inside ("" when none)
    local canon="$1" recorded="$2" pid="" last=""
    [ -s "$CWD_OUT" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            p*) pid="${line#p}" ;;
            n*)
                last="${line#n}"
                case "$last" in
                    "$canon"|"$canon"/*|"$recorded"|"$recorded"/*)
                        case "$SELF_PIDS" in *" $pid "*) ;; *) printf '%s\n' "$pid"; return 0 ;; esac ;;
                    *"/${canon##*/}"*)
                        if canonical_token_match "$last" "$canon"; then
                            case "$SELF_PIDS" in *" $pid "*) ;; *) printf '%s\n' "$pid"; return 0 ;; esac
                        fi ;;
                esac ;;
        esac
    done <"$CWD_OUT"
    return 1
}

# clean_gate <path> -> "<verdict>\t<payload>"
# verdict: clean | dirty | ignored-artifact | status-timeout | status-error.
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
                # ROOT-level ephemeral allowlist only: `src/.cache/` is NOT
                # tolerated (nested ignored artifacts are operator data).
                if [ "${p%/}" = "$base" ] && is_ephemeral_name "$base"; then
                    eph="$eph$p "
                elif [ "$xy" = '!!' ]; then
                    n=$((n + 1)); [ "$n" -le 3 ] && ignored="$ignored$p "
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

# pr_head_refs_load — ONE batched call for the whole pass, with an explicit
# limit: `gh pr list` defaults to --limit 30, so a branch whose open PR sits
# beyond the first 30 would be a FALSE PASS on the exact class the issue
# preserved. Only a github.com origin can have PRs; anything else is N/A.
GH_OK=0
PR_APPLICABLE=0
PR_REFS=""
github_slug() {
    local url="$1"
    case "$url" in
        *github.com[:/]*)
            printf '%s\n' "$url" | sed -E 's#^[^/]*//##; s#^git@##; s#github\.com[:/]##; s#\.git$##' ;;
        *) printf '' ;;
    esac
}
pr_head_refs_load() {
    local slug="" out rc
    if [ -n "$REAP_WT_REPO_SLUG" ]; then
        slug="$REAP_WT_REPO_SLUG"
    else
        slug="$(github_slug "$("$GIT_BIN" -C "$REPO_CANON" remote get-url origin 2>/dev/null)")"
    fi
    case "$slug" in
        */*) ;;
        *) PR_APPLICABLE=0; GH_OK=1; GH_STATE="na"; return 0 ;;
    esac
    PR_APPLICABLE=1
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-pr.XXXXXX")" || { GH_OK=0; GH_STATE="unavailable"; return 1; }
    run_bounded "$REAP_WT_GH_TIMEOUT" "$out" \
        "$GH_BIN" pr list --repo "$slug" --state open --limit "$REAP_WT_PR_LIMIT" \
        --json headRefName --jq '.[].headRefName'
    rc=$?
    if [ "$rc" != 0 ]; then
        rm -f "$out"; GH_OK=0; GH_STATE="unavailable"
        log "GH pr-list failed (rc=$rc) for $slug — fail-closed"
        return 1
    fi
    PR_REFS="$(cat "$out")"
    rm -f "$out"
    GH_OK=1; GH_STATE="ok"
    return 0
}

# commits_survive <sha> <branch> -> prints the survival mechanism, or "" when
# deleting the checkout could orphan the commit. This is the REACHABLE gate and
# it is applied to EVERY removal path, including the vanished-directory one:
# the admin record's HEAD is itself the last ref holding a detached commit, so
# pruning it can orphan that commit (verified).
commits_survive() {
    local sha="$1" branch="$2" merged=0 containing=""
    if [ -n "$MAIN_REF" ] && [ -n "$sha" ] && \
       "$GIT_BIN" -C "$REPO_CANON" merge-base --is-ancestor "$sha" "$MAIN_REF" >/dev/null 2>&1; then
        merged=1
    fi
    if [ "$branch" = "-" ]; then
        if [ "$merged" = 1 ]; then printf 'merged\n'; return 0; fi
        containing="$("$GIT_BIN" -C "$REPO_CANON" for-each-ref --contains="$sha" --count=1 \
            --format='%(refname)' 2>/dev/null | head -1)"
        if [ -z "$containing" ]; then printf ''; return 0; fi
        printf 'reachable-from:%s\n' "$containing"; return 0
    fi
    if [ "$merged" = 1 ]; then printf 'merged\n'; else printf 'branch-retained:%s\n' "${branch#refs/heads/}"; fi
}

# ── classification ─────────────────────────────────────────────────────
# classify_one <path> <sha> <branch> <flags> <now>
# Emits one row: "<verdict>\t<reason>\t<ephemeral>\t<detail>" (ephemeral is
# third so the free-text detail, which may embed a path containing a tab, is
# absorbed by cut -f4-).
classify_one() {
    local path="$1" sha="$2" branch="$3" flags="$4" now="$5"
    local canon detail crumb cverdict cpay eph="" exists=0 refs=""
    case ",$flags," in *,poison,*)  printf 'preserve\tunparseable-path\t\trecord had a tab/newline in the path — abstaining (fail-closed)\n'; return 0 ;; esac
    if [ "$branch" = "BARE" ]; then printf 'preserve\tbare\t\tbare repository\n'; return 0; fi
    { [ -e "$path" ] || [ -L "$path" ]; } && exists=1
    canon="$(canonicalize "$path")"

    if [ -n "$canon" ] && [ "$canon" = "$MAIN_CANON" ]; then
        printf 'preserve\tmain-checkout\t\t%s\n' "$canon"; return 0
    fi
    if [ -n "$canon" ] && is_self_or_ancestor "$canon"; then
        printf 'preserve\tself-checkout\t\tcontains the reaper cwd (%s)\n' "$SELF_CWD_CANON"; return 0
    fi
    # `locked` is checked BEFORE the gone-directory branch, deliberately: git
    # itself refuses to prune a locked record, so a locked worktree whose
    # checkout has vanished is still a PRESERVE — classifying it `prunable`
    # would claim (and count) a removal git will not perform.
    case ",$flags," in *,locked,*) printf 'preserve\tworktree-locked\t\tgit worktree lock is set\n'; return 0 ;; esac
    if [ -z "$canon" ]; then
        # `canonicalize` failing means "cannot resolve", NOT "directory gone":
        # an existing-but-inaccessible checkout must never be treated as prunable
        # (that would deregister a live worktree and could orphan a detached
        # commit). Only a truly absent path is prunable — and even then the
        # commits must survive.
        if [ "$exists" = 1 ]; then
            printf 'preserve\tunreadable-path\t\texists but cannot be resolved (permissions?)\n'; return 0
        fi
        refs="$(commits_survive "$sha" "$branch")"
        if [ -z "$refs" ]; then
            printf 'preserve\tdetached-unreachable\t\tsha %s is on no ref (checkout already gone) — pruning the record would ORPHAN it\n' "${sha:-?}"
            return 0
        fi
        printf 'remove\tprunable\t\tcheckout already absent; commits survive via %s\n' "$refs"
        return 0
    fi

    if detail="$(live_process_for "$canon" "$path")"; then
        printf 'preserve\tlive-process\t\tpid %s holds the path\n' "$detail"; return 0
    fi
    if detail="$(live_cwd_for "$canon" "$path")"; then
        printf 'preserve\tlive-cwd\t\tpid %s has cwd inside the path\n' "$detail"; return 0
    fi

    crumb="$(clean_gate "$path")"
    cverdict="${crumb%%$'\t'*}"
    cpay="${crumb#*$'\t'}"
    case "$cverdict" in
        clean) eph="$cpay" ;;
        dirty)            printf 'preserve\tdirty\t\t%s\n' "$cpay"; return 0 ;;
        ignored-artifact) printf 'preserve\tignored-artifact\t\t%s\n' "$cpay"; return 0 ;;
        status-timeout)   printf 'preserve\tstatus-timeout\t\t%s\n' "$cpay"; return 0 ;;
        *)                printf 'preserve\tstatus-error\t\t%s\n' "$cpay"; return 0 ;;
    esac

    refs="$(commits_survive "$sha" "$branch")"
    if [ -z "$refs" ]; then
        printf 'preserve\tdetached-unreachable\t\tsha %s is on no ref — removing would orphan it\n' "${sha:-?}"
        return 0
    fi

    if [ "$PR_APPLICABLE" = 1 ] && [ "$branch" != "-" ]; then
        local bn="${branch#refs/heads/}"
        if [ -n "$PR_REFS" ] && grep -qxF -- "$bn" <<<"$PR_REFS"; then
            printf 'preserve\topen-pr\t\tbranch %s is an open PR head\n' "$bn"; return 0
        fi
    fi

    local head_ts
    head_ts="$("$GIT_BIN" -C "$REPO_CANON" log -1 --format=%ct "$sha" 2>/dev/null)"
    case "$head_ts" in
        ''|*[!0-9]*) printf 'preserve\tunreadable-head\t\tcannot date HEAD %s\n' "${sha:-?}"; return 0 ;;
    esac
    if [ "$((now - head_ts))" -le "$((REAP_WT_AGED_DAYS * 86400))" ]; then
        printf 'preserve\ttoo-recent\t\tHEAD age %sd ≤ %sd\n' "$(((now - head_ts) / 86400))" "$REAP_WT_AGED_DAYS"
        return 0
    fi

    printf 'remove\treclaimable\t%s\trefs=%s age=%sd clean=ephemeral-only unref=no-proc,no-pr\n' \
        "$eph" "$refs" "$(((now - head_ts) / 86400))"
    return 0
}

# ── removal ────────────────────────────────────────────────────────────
# remove_one <path> <ephemeral-list>
# Never --force. Deletes ONLY declared-ephemeral UNTRACKED (??) entries first
# (git refuses a worktree containing untracked files); ignored (`!!`)
# ephemerals are handled by git itself. A refusal/timeout is REPORTED as
# REMOVE-FAILED, never swallowed.
#
# The pre-delete is a recursive filesystem delete over a checkout this script
# does not control, so it runs under the SAME watchdog as the removal — it was
# the last unbounded fork on the removal path. A failure (including a timeout)
# returns 1 => REMOVE-FAILED rather than continuing: an ephemeral that survived
# its deletion is a directory `git worktree remove` will refuse on anyway
# (untracked), so the honest report is available without a second unbounded
# attempt against the same block. The admin record is left intact either way.
remove_one() {
    local path="$1" eph="$2" entry target out rc
    out="$(mktemp "${TMPDIR:-/tmp}/pi-reap-rm.XXXXXX")" || return 1
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
    log "MODE=$MODE NOW=$1 AGED_DAYS=$REAP_WT_AGED_DAYS WORKTREES=$WT_TOTAL REMOVE=$REMOVE_C PRESERVE=$PRESERVE_C REMOVED=$REMOVED FAILED=$FAILED DEFERRED=$DEFERRED GH=$GH_STATE CWD_PROBE=$([ "$CWD_DEGRADED" = 1 ] && printf degraded || printf ok) PRUNE_BLOCKED=$PRUNE_BLOCKED"
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
    trap 'watchdogs_reap; bound_cleanup; rm -f "$PS_OUT" "$CWD_OUT"; lock_release' EXIT
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
             REAP_WT_REMOVE_TIMEOUT:"$REAP_WT_REMOVE_TIMEOUT" REAP_WT_BUDGET_SECONDS:"$REAP_WT_BUDGET_SECONDS" \
             REAP_WT_LOCK_STALE_SECONDS:"$REAP_WT_LOCK_STALE_SECONDS" REAP_WT_PR_LIMIT:"$REAP_WT_PR_LIMIT" \
             REAP_WT_MAX_DAYS:"$REAP_WT_MAX_DAYS"; do
        is_pos_int "${v#*:}" || { echo "bad ${v%%:*}: ${v#*:} (want a non-negative integer)" >&2; exit 2; }
    done
    awk -v a="$REAP_WT_AGED_DAYS" -v m="$REAP_WT_MAX_DAYS" 'BEGIN{exit !(a >= 0 && a <= m)}' \
        || { echo "bad --aged-days: out of range (0..$REAP_WT_MAX_DAYS)" >&2; exit 2; }

    REPO="${REPO:-$PWD}"
    REPO_CANON="$(canonicalize "$REPO")"
    [ -n "$REPO_CANON" ] || { echo "not a directory: $REPO" >&2; exit 2; }
    local common
    common="$("$GIT_BIN" -C "$REPO_CANON" rev-parse --git-common-dir 2>/dev/null)"
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
    MAIN_CANON="$(printf '%s\n' "$WT_LIST" | head -1 | cut -f1 | while IFS= read -r p; do canonicalize "$p"; done)"
    [ -n "$MAIN_CANON" ] || MAIN_CANON="$REPO_CANON"
    SELF_CWD_CANON="$(canonicalize "$PWD")"
    now="$(now_epoch)"
    MAIN_REF="$(resolve_main_ref)"

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

    local need_pr=0 p h b f
    while IFS=$'\t' read -r p h b f; do
        [ -n "$p" ] || continue
        [ "$b" = "-" ] || [ "$b" = "BARE" ] || { need_pr=1; break; }
    done <<<"$WT_LIST"
    if [ "$need_pr" = 1 ]; then
        if ! pr_head_refs_load; then
            echo "FAIL-CLOSED abort: gh unavailable — cannot verify the open-PR gate (exit 3)" >&2
            echo "   set REAP_WT_REPO_SLUG, install/auth gh, or run against a repo with no GitHub remote" >&2
            log "FAIL-CLOSED abort: gh unavailable with candidates (exit 3)"
            print_footer "$now"
            exit 3
        fi
    else
        GH_STATE="na"; GH_OK=1; PR_APPLICABLE=0
    fi

    if ! ps_load; then
        echo "FAIL-CLOSED abort: ps enumeration failed or empty — cannot verify the live-reference gate (exit 3)" >&2
        log "FAIL-CLOSED abort: ps enumeration failed/empty (exit 3)"
        print_footer "$now"
        exit 3
    fi
    self_pid_tree_load
    cwd_probe_load

    say "note: \`git worktree remove\` deletes the CHECKOUT only — branch refs are never deleted by this tool."
    say "note: no byte-savings figure is reported — per-worktree .venv dirs are hardlinked to the uv cache"
    say "      (measured 84 GB du delta vs 22 GB actual). The deliverable win is FILE COUNT."
    say ""

    local elapsed=0 crumb verdict reason detail ephemeral
    # The budget clock starts HERE, not at `now`: see the BOUNDEDNESS note in
    # the header. `now` stays the single ageing reference for the whole pass.
    START_EPOCH="$(now_epoch)"
    while IFS=$'\t' read -r p h b f; do
        [ -n "$p" ] || continue
        elapsed="$(( $(now_epoch) - START_EPOCH ))"
        if [ "$REAP_WT_BUDGET_SECONDS" -gt 0 ] && [ "$elapsed" -ge "$REAP_WT_BUDGET_SECONDS" ]; then
            say "preserve $p"
            say "         reason=deferred  pass budget ${REAP_WT_BUDGET_SECONDS}s exhausted — not classified"
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
        ephemeral="$(printf '%s' "$crumb" | cut -f3)"
        detail="$(printf '%s' "$crumb" | cut -f4- | tr '\n' ' ')"
        report_row "$verdict" "$p" "$reason" "$detail"
        if [ "$verdict" = "remove" ]; then
            REMOVE_C=$((REMOVE_C + 1))
            log "CLASSIFY remove $p reason=$reason $detail"
            if [ "$reason" = "prunable" ] && [ "$MODE" = apply ]; then PRUNE_WANTED=$((PRUNE_WANTED + 1)); fi
            if [ "$MODE" = apply ]; then
                elapsed="$(( $(now_epoch) - START_EPOCH ))"
                if [ "$REAP_WT_BUDGET_SECONDS" -gt 0 ] && [ "$elapsed" -ge "$REAP_WT_BUDGET_SECONDS" ]; then
                    say "         NOT REMOVED (pass budget exhausted) — will be re-classified next pass"
                    log "DEFERRED-REMOVE $p (budget)"
                    # Its removal did not happen, so the end-of-pass prune must
                    # not run either: for a `prunable` row the prune IS the
                    # removal, and it has no path filter.
                    PRUNE_BLOCKED=1
                    DEFERRED=$((DEFERRED + 1))
                    continue
                fi
                if [ "$reason" = "prunable" ]; then
                    # Deferred to the single end-of-pass `git worktree prune`
                    # below: prune has no path filter, so it must not run while
                    # any unclassified (deferred) or preserved record could
                    # also be prunable. REMOVED is incremented ONLY if the
                    # prune actually ran — otherwise the report would claim a
                    # removal that never happened.
                    say "         REMOVES — pending the end-of-pass \`git worktree prune\` (a global prune has no path filter)"
                    log "PRUNE-PENDING $p"
                elif remove_one "$p" "$ephemeral"; then
                    say "         REMOVED — branch/refs survive: $(printf '%s' "$detail" | sed -n 's/.*refs=\([^ ]*\).*/\1/p')"
                    REMOVED=$((REMOVED + 1))
                    log "REMOVED $p"
                else
                    say "         REMOVE-FAILED — see the log ($REAP_WT_LOG)"
                    FAILED=$((FAILED + 1))
                fi
            fi
        else
            PRESERVE_C=$((PRESERVE_C + 1))
            log "CLASSIFY preserve $p reason=$reason $detail"
            # A preserved record that git may ALSO deem prunable (unresolvable
            # path, broken admin link) must not be swept up by a global prune.
            case "$reason" in
                unreadable-path|status-error|status-timeout|unparseable-path|worktree-locked) PRUNE_BLOCKED=1 ;;
                detached-unreachable) PRUNE_BLOCKED=1 ;;
            esac
        fi
    done <<<"$WT_LIST"

    if [ "$MODE" = apply ] && [ "$PRUNE_WANTED" -gt 0 ]; then
        if [ "$PRUNE_BLOCKED" = 1 ]; then
            say ""
            say "⚠️  skipped \`git worktree prune\`: ${PRUNE_WANTED} reclaimable gone-checkout record(s) were"
            say "    left registered, because a record this pass did not classify (deferred) — or did"
            say "    preserve — could also be prunable and a global prune has no path filter."
            say "    Nothing was lost: those records are re-classified on the next pass."
            log "PRUNE-SKIPPED wanted=$PRUNE_WANTED (a deferred or preserved record may be prunable)"
        elif "$GIT_BIN" -C "$REPO_CANON" worktree prune >/dev/null 2>&1; then
            REMOVED=$((REMOVED + PRUNE_WANTED))
            log "PRUNED $PRUNE_WANTED gone-checkout record(s)"
        else
            FAILED=$((FAILED + PRUNE_WANTED))
            log "PRUNE-FAIL (gone-checkout records left registered)"
        fi
    fi

    say ""
    if [ "$MODE" = dry-run ]; then
        say "DRY-RUN — nothing removed. Re-run with --apply to remove the 'remove' rows."
    else
        say "armed pass complete: REMOVED=$REMOVED FAILED=$FAILED"
    fi
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
