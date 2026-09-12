#!/usr/bin/env bash
# pi-task-session-prune.sh — retention sweep for durable child session
# transcripts (#783 Task 6).
#
# Task 1 writes every task child's transcript to
#   $TASK_SESSION_ROOT/<childId>/<timestamp>_<childId>.jsonl
# (root mode 0700). Nothing bounded that tree, so it grows without limit.
# This sweep is the bound: age OR size, whichever binds first, evicting the
# OLDEST NON-LIVE transcript first.
#
# Liveness — the part that has to be right:
#   * There is NO pid in a session filename, and the #469 reaper's proof is
#     unusable here: pi-reap-idle.sh gates candidates on `tty ~ /^ttys/`, and
#     task children are spawned detached with stdio ["ignore","pipe","pipe"]
#     — no tty, so they are never candidates for it.
#   * Liveness is derived from `ps -axo pid=,command=` matching the child's
#     `--session-id <id>` / `--session-dir <path>` argv pair (Task 1 passes
#     both; the flag sits near the front of argv, before the long prompt, so
#     ps truncation of a long command line cannot hide it).
#   * FAIL CLOSED: if the ps probe errors, nothing is deleted.
#   * TOCTOU: liveness is re-probed immediately before EVERY unlink.
#   * FILES ONLY: a per-child directory can hold an in-flight write (and a
#     sibling incarnation may be starting), so a directory is never removed
#     with content; a per-child dir is rmdir'd ONLY when it is empty AND its
#     child is not live.
#
# Bounds (env-tunable, plan/scope contract):
#   TASK_SESSION_MAX_AGE_DAYS  default 7
#   TASK_SESSION_MAX_BYTES     default 2147483648 (2 GiB)
# Honest arithmetic: ~0.06–3.5 GB/day, so the size bound is generally what
# binds; the age floor is the backstop.
#
# Dry-run BY DEFAULT (TASK_SESSION_PRUNE_DRY_RUN defaults to 1). Arming is a
# separate, manual, OWNED step (the shipped plist carries DRY_RUN=1; see the
# plan Task 7.4 contract note and the plist header).
#
# Usage:
#   pi-task-session-prune.sh [--dry-run] [--apply] [--help]
# Env seams: PS_BIN TASK_SESSION_ROOT TASK_SESSION_MAX_AGE_DAYS
#   TASK_SESSION_MAX_BYTES TASK_SESSION_PRUNE_DRY_RUN TASK_SESSION_PRUNE_LOG
#   TASK_SESSION_PRUNE_NOW_EPOCH
# Exit codes: 0 completed pass, 2 usage, 3 fail-closed (ps probe / log).

set -uo pipefail

SCRIPT_NAME="pi-task-session-prune.sh"
ISSUE_REF="#783"
TAB="$(printf '\t')"

PS_BIN="${PS_BIN:-/bin/ps}"
ROOT="${TASK_SESSION_ROOT:-${HOME:-}/.pi/agent/task-sessions}"
MAX_AGE_DAYS="${TASK_SESSION_MAX_AGE_DAYS:-7}"
MAX_BYTES="${TASK_SESSION_MAX_BYTES:-2147483648}"
PRUNE_LOG="${TASK_SESSION_PRUNE_LOG:-${HOME:-}/.pi/agent/state/pi-task-session-prune.log}"

MODE=unknown

usage() {
    cat <<EOF
$SCRIPT_NAME — retention sweep for durable task-child session transcripts ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--help]

  (no mode flag)   dry-run: report what would be pruned, delete nothing
  --dry-run        explicit dry-run
  --apply          armed one-shot pass (or env TASK_SESSION_PRUNE_DRY_RUN=0)
  --help           this text

Bounds: TASK_SESSION_MAX_AGE_DAYS (default 7) OR TASK_SESSION_MAX_BYTES
(default 2 GiB), whichever binds first; oldest NON-LIVE transcript first.
Fail-closed: a ps-probe error deletes nothing (exit 3). Files only — a per-child
directory is rmdir'd only when empty AND its child is not live.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "$*"; }
log() { printf '%s\n' "$*" >>"$PRUNE_LOG" 2>/dev/null || true; }

now_epoch() {
    if [ -n "${TASK_SESSION_PRUNE_NOW_EPOCH:-}" ]; then
        printf '%s\n' "$TASK_SESSION_PRUNE_NOW_EPOCH"
        return 0
    fi
    /bin/date +%s 2>/dev/null || date +%s
}

# stat branch by capability probe (never uname): BSD `-f` succeeds here, GNU
# `-f` means "filesystem" and errors on a path operand.
STAT_MODE=""
stat_mode() {
    if [ -n "$STAT_MODE" ]; then printf '%s\n' "$STAT_MODE"; return 0; fi
    if stat -f '%m' "$0" >/dev/null 2>&1; then
        STAT_MODE=bsd
    else
        STAT_MODE=gnu
    fi
    printf '%s\n' "$STAT_MODE"
}

file_mtime() {
    if [ "$(stat_mode)" = bsd ]; then stat -f '%m' -- "$1" 2>/dev/null
    else stat -c '%Y' -- "$1" 2>/dev/null; fi
}

file_size() {
    if [ "$(stat_mode)" = bsd ]; then stat -f '%z' -- "$1" 2>/dev/null
    else stat -c '%s' -- "$1" 2>/dev/null; fi
}

# ── ps probe (fail-closed) ─────────────────────────────────────────────
# PS_TABLE: "pid command…" rows, leading whitespace stripped. An empty or
# failed probe is an ERROR, never "no live children" — what cannot be
# observed is never deleted.
PS_TABLE=""
probe_ps() {
    [ -n "$PS_TABLE" ] && rm -f "$PS_TABLE" "$PS_TABLE.raw" 2>/dev/null
    PS_TABLE="$(mktemp "${TMPDIR:-/tmp}/pi-task-prune-ps.XXXXXX" 2>/dev/null)" || { PS_TABLE=""; return 1; }
    if ! "$PS_BIN" -axo pid=,command= >"$PS_TABLE.raw" 2>/dev/null; then
        rm -f "$PS_TABLE" "$PS_TABLE.raw"
        PS_TABLE=""
        return 1
    fi
    sed 's/^ *//' "$PS_TABLE.raw" >"$PS_TABLE" 2>/dev/null
    rm -f "$PS_TABLE.raw"
    if [ ! -s "$PS_TABLE" ]; then
        rm -f "$PS_TABLE"
        PS_TABLE=""
        return 1
    fi
    return 0
}

# child_is_live <childId> — exact argv matching, no regex escaping needed:
# the field AFTER `--session-id` equals the id, or the field after
# `--session-dir` equals this root's dir for that id.
child_is_live() {
    [ -s "$PS_TABLE" ] || return 1
    awk -v id="$1" -v dir="$ROOT/$1" '
        {
            for (i = 2; i <= NF; i++) {
                if ($i == id && $(i-1) == "--session-id") { found = 1; exit }
                if ($i == dir && $(i-1) == "--session-dir") { found = 1; exit }
            }
        }
        END { exit !found }
    ' "$PS_TABLE"
}

# ── main ───────────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) MODE=dry-run; shift ;;
            --apply) MODE=apply; shift ;;
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
}

INVENTORY=""
PLAN=""
DELETED=""
cleanup() {
    [ -n "$INVENTORY" ] && rm -f "$INVENTORY" "$INVENTORY.sorted" 2>/dev/null
    [ -n "$PLAN" ] && rm -f "$PLAN" 2>/dev/null
    [ -n "$DELETED" ] && rm -f "$DELETED" 2>/dev/null
    [ -n "$PS_TABLE" ] && rm -f "$PS_TABLE" 2>/dev/null
    return 0
}

run() {
    local now cutoff total pruned_count freed_bytes remaining_bytes freed_mb rem_mb
    local cid d f mt sz dirs_pruned probe_failed

    if [ "$MODE" = unknown ]; then
        if [ "${TASK_SESSION_PRUNE_DRY_RUN:-1}" = "0" ]; then MODE=apply; else MODE=dry-run; fi
    fi
    case "$MODE" in dry-run|apply) ;; *) usage >&2; exit 2 ;; esac
    printf '%s' "$MAX_AGE_DAYS" | grep -qE '^[0-9]+$' || { echo "bad TASK_SESSION_MAX_AGE_DAYS: $MAX_AGE_DAYS" >&2; exit 2; }
    printf '%s' "$MAX_BYTES" | grep -qE '^[0-9]+$' || { echo "bad TASK_SESSION_MAX_BYTES: $MAX_BYTES" >&2; exit 2; }

    mkdir -p "$(dirname "$PRUNE_LOG")" 2>/dev/null || true
    # Fail-closed (ARMED only): an armed pass must never delete without an
    # audit trail. Dry-run keeps best-effort logging (its verdict is stdout).
    if [ "$MODE" = apply ] && ! : >>"$PRUNE_LOG" 2>/dev/null; then
        echo "FAIL-CLOSED abort: TASK_SESSION_PRUNE_LOG unwritable ($PRUNE_LOG) (exit 3)" >&2
        exit 3
    fi

    now="$(now_epoch)"
    cutoff=$(( now - MAX_AGE_DAYS * 86400 ))

    if [ ! -d "$ROOT" ]; then
        say "[task-session-prune] freed=0MB remaining=0MB pruned=0"
        say "MODE=$MODE NOW=$now ROOT=$ROOT (absent — nothing to do)"
        echo "[task-session-prune] MODE=$MODE pruned=0 freed=0B remaining=0B dirs=0 (root absent)"
        exit 0
    fi

    if ! probe_ps; then
        echo "FAIL-CLOSED abort: ps probe unavailable (PS_BIN=$PS_BIN) — nothing deleted (exit 3)" >&2
        log "FAIL-CLOSED abort: ps probe unavailable (PS_BIN=$PS_BIN) — nothing deleted"
        log "[task-session-prune] freed=0MB remaining=0MB pruned=0"
        exit 3
    fi

    INVENTORY="$(mktemp "${TMPDIR:-/tmp}/pi-task-prune-inv.XXXXXX")" || exit 3
    PLAN="$(mktemp "${TMPDIR:-/tmp}/pi-task-prune-plan.XXXXXX")" || exit 3
    : >"$INVENTORY"
    : >"$PLAN"

    # ── inventory: every regular file one level under the root's child dirs.
    # Live children count toward the tree size (their bytes occupy disk) but
    # never enter the evictable inventory.
    total=0
    for d in "$ROOT"/*/; do
        [ -d "$d" ] || continue
        cid="$(basename "$d")"
        if child_is_live "$cid"; then
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                sz="$(file_size "$f")"
                case "$sz" in ''|*[!0-9]*) continue ;; esac
                total=$(( total + sz ))
            done < <(find "$d" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
            continue
        fi
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            mt="$(file_mtime "$f")"
            sz="$(file_size "$f")"
            case "$mt" in ''|*[!0-9]*) log "SKIP unstatable mtime: $f"; continue ;; esac
            case "$sz" in ''|*[!0-9]*) log "SKIP unstatable size: $f"; continue ;; esac
            printf '%s\t%s\t%s\t%s\n' "$mt" "$sz" "$cid" "$f" >>"$INVENTORY"
            total=$(( total + sz ))
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
    done

    # ── selection: oldest non-live first; age OR size, whichever binds first.
    sort -t "$TAB" -k1,1n -k2,2n "$INVENTORY" >"$INVENTORY.sorted" 2>/dev/null
    pruned_count=0
    freed_bytes=0
    while IFS="$TAB" read -r mt sz cid f; do
        [ -n "$f" ] || continue
        evict=0
        if [ "$mt" -lt "$cutoff" ]; then evict=1; fi
        if [ $(( total - freed_bytes )) -gt "$MAX_BYTES" ]; then evict=1; fi
        if [ "$evict" = 1 ]; then
            printf '%s\t%s\t%s\n' "$cid" "$sz" "$f" >>"$PLAN"
            freed_bytes=$(( freed_bytes + sz ))
            pruned_count=$(( pruned_count + 1 ))
        fi
    done <"$INVENTORY.sorted"

    # ── execution (armed only): re-probe immediately before EVERY unlink.
    # The counters describe what ACTUALLY happened (a TOCTOU skip is not a
    # prune); dry-run reports the planned set instead.
    probe_failed=0
    if [ "$MODE" = apply ]; then
        DELETED="$(mktemp "${TMPDIR:-/tmp}/pi-task-prune-del.XXXXXX")" || exit 3
        : >"$DELETED"
        pruned_count=0
        freed_bytes=0
        while IFS="$TAB" read -r cid sz f; do
            [ -n "$f" ] || continue
            if ! probe_ps; then
                echo "FAIL-CLOSED abort: ps probe failed during unlink phase — remaining deletes suppressed (exit 3)" >&2
                log "FAIL-CLOSED abort: ps probe failed during unlink phase — remaining deletes suppressed"
                probe_failed=1
                break
            fi
            if child_is_live "$cid"; then
                log "SKIP $f — child $cid went live before unlink (TOCTOU re-probe)"
                continue
            fi
            if rm -f -- "$f" 2>/dev/null; then
                printf '%s\n' "$f" >>"$DELETED"
                pruned_count=$(( pruned_count + 1 ))
                freed_bytes=$(( freed_bytes + sz ))
            else
                log "SKIP unlink failed: $f"
            fi
        done <"$PLAN"
    fi

    # ── dirs: rmdir ONLY when empty AND the child is not live (fresh probe).
    dirs_pruned=0
    if [ "$probe_failed" = 0 ]; then
        if ! probe_ps; then
            log "FAIL-CLOSED: ps probe failed before rmdir phase — directories left in place"
        else
            for d in "$ROOT"/*/; do
                [ -d "$d" ] || continue
                cid="$(basename "$d")"
                if child_is_live "$cid"; then
                    [ "$MODE" = dry-run ] && log "KEEP dir $d — child $cid is live"
                    continue
                fi
                if [ -z "$(find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
                    if [ "$MODE" = apply ]; then
                        if rmdir -- "$d" 2>/dev/null; then dirs_pruned=$(( dirs_pruned + 1 )); fi
                    else
                        dirs_pruned=$(( dirs_pruned + 1 ))
                    fi
                fi
            done
        fi
    fi

    remaining_bytes=$(( total - freed_bytes ))
    freed_mb=$(( freed_bytes / 1048576 ))
    rem_mb=$(( remaining_bytes / 1048576 ))
    log "[task-session-prune] freed=${freed_mb}MB remaining=${rem_mb}MB pruned=${pruned_count}"
    log "MODE=$MODE NOW=$now ROOT=$ROOT MAX_AGE_DAYS=$MAX_AGE_DAYS MAX_BYTES=$MAX_BYTES bytes_freed=$freed_bytes bytes_remaining=$remaining_bytes dirs_rmdir=$dirs_pruned"

    if [ "$MODE" = dry-run ]; then
        echo "DRY-RUN — nothing deleted (TASK_SESSION_PRUNE_DRY_RUN=${TASK_SESSION_PRUNE_DRY_RUN:-1})"
    fi
    echo "[task-session-prune] MODE=$MODE pruned=$pruned_count freed=${freed_bytes}B remaining=${remaining_bytes}B dirs=$dirs_pruned"
    if [ "$pruned_count" -gt 0 ]; then
        printf 'WARNING: [task-session-prune] (%s) pruned %s transcript(s), freed %s bytes — abnormal exits are accumulating\n' \
            "$MODE" "$pruned_count" "$freed_bytes" >&2
    fi
    if [ "$probe_failed" = 1 ]; then
        exit 3
    fi
    exit 0
}

trap cleanup EXIT
parse_args "$@"
run
