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
#   * SYMLINK-SAFE: only UUID-named child dirs inside the canonical root are
#     ever considered; symlinked entries are skipped and every unlink/rmdir is
#     containment-checked against the canonical root (a planted
#     `$ROOT/<name> -> ~/.ssh` can never make the sweep delete outside it).
#     #783 review: the containment verdict for an unlink is re-asserted
#     ATOMICALLY with the unlink — see the apply loop — because the loop's
#     top-of-iteration check is separated from its `rm` by two forks, and a
#     path-based `rm` would follow an intermediate symlink planted in that
#     window. The unlink now runs by BASENAME from inside the verified parent.
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
# ROOT is resolved in resolve_root() (after --help parsing) so `--help` works
# even when HOME is unset; see the normalization note there.
ROOT=""
ROOT_REAL=""
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

# Trim leading/trailing whitespace (bash 3.2 — no external tools).
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# resolve_root — normalize TASK_SESSION_ROOT with the same trim + leading-`~`
# expansion as the JS side (extensions/shared/session-id.ts
# resolveTaskSessionRoot), so the pruner points at the SAME tree task children
# write to. A mismatch would make it report "absent — nothing to do" and exit 0
# even on --apply, so the bound would never bind.
# NOTE (#783 review): this is parity on TRIM + TILDE only, NOT byte-exact path
# normalization. The JS side `path.join()`s the root when minting --session-dir
# (collapsing repeated/trailing separators); this shell builds "$ROOT/$1"
# verbatim, so TASK_SESSION_ROOT=/x/y/ compares as /x/y//<uuid>. Liveness still
# matches because child_is_live also matches the always-emitted --session-id
# (provider-independent), and the unlink path is containment-checked via
# `pwd -P`. Do not claim byte-exactness here. FAIL CLOSED
# (exit 3) when the root cannot be resolved; never operate on a guessed path.
resolve_root() {
    local raw
    raw="$(trim "${TASK_SESSION_ROOT:-}")"
    if [ -z "$raw" ]; then
        if [ -z "${HOME:-}" ]; then
            echo "FAIL-CLOSED abort: TASK_SESSION_ROOT unset and HOME unset — cannot resolve the session root (exit 3)" >&2
            exit 3
        fi
        raw="$HOME/.pi/agent/task-sessions"
    fi
    case "$raw" in
        "~"|"~/"*)
            if [ -z "${HOME:-}" ]; then
                echo "FAIL-CLOSED abort: TASK_SESSION_ROOT is under '~' but HOME is unset (exit 3)" >&2
                exit 3
            fi
            ;;
    esac
    case "$raw" in
        "~") ROOT="$HOME" ;;
        "~/"*) ROOT="$HOME/${raw#\~/}" ;;
        *) ROOT="$raw" ;;
    esac
    if [ -z "$ROOT" ]; then
        echo "FAIL-CLOSED abort: resolved TASK_SESSION_ROOT is empty (exit 3)" >&2
        exit 3
    fi
}

# is_session_dir_name <name> — the session-id grammar's concrete mint: a UUID.
# Requiring the name shape stops the sweep from ever considering arbitrary
# top-level entries (e.g. a planted directory).
is_session_dir_name() {
    case "$1" in
        *[!0-9a-fA-F-]*) return 1 ;;
    esac
    grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' <<<"$1"
}

# safe_child_dir <dir> — a legitimate per-child session dir: NOT a symlink,
# named with the session-id grammar, and canonically INSIDE the session root.
# The symlink guard is load-bearing: `[ -d ]` follows symlinks (and a trailing
# slash defeats even `test -L`), so without it a planted `$ROOT/x -> ~/.ssh`
# would make the sweep inventory — and delete — files outside the root.
safe_child_dir() {
    local d="$1" cid parent
    [ -n "$d" ] || return 1
    [ -L "$d" ] && return 1
    [ -d "$d" ] || return 1
    cid="$(basename "$d")"
    is_session_dir_name "$cid" || return 1
    parent="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
    case "$parent" in
        "$ROOT_REAL"|"$ROOT_REAL"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# path_inside_root <path> — the canonical PARENT of <path> is the session root
# or a descendant. `pwd -P` so a symlinked parent cannot fake containment.
path_inside_root() {
    local parent
    [ -n "$ROOT_REAL" ] || return 1
    parent="$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
    case "$parent" in
        "$ROOT_REAL"|"$ROOT_REAL"/*) return 0 ;;
        *) return 1 ;;
    esac
}

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
    grep -qE '^[0-9]+$' <<<"$MAX_AGE_DAYS" || { echo "bad TASK_SESSION_MAX_AGE_DAYS: $MAX_AGE_DAYS" >&2; exit 2; }
    grep -qE '^[0-9]+$' <<<"$MAX_BYTES" || { echo "bad TASK_SESSION_MAX_BYTES: $MAX_BYTES" >&2; exit 2; }

    resolve_root

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
    # Canonicalize the root ONCE. Every unlink/rmdir below is containment-
    # checked against this real path, so a symlinked parent cannot escape.
    ROOT_REAL="$(cd "$ROOT" 2>/dev/null && pwd -P)" || ROOT_REAL=""
    if [ -z "$ROOT_REAL" ]; then
        echo "FAIL-CLOSED abort: cannot canonicalize TASK_SESSION_ROOT ($ROOT) (exit 3)" >&2
        log "FAIL-CLOSED abort: cannot canonicalize TASK_SESSION_ROOT ($ROOT)"
        exit 3
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
        d="${d%/}"
        safe_child_dir "$d" || continue
        cid="$(basename "$d")"
        if child_is_live "$cid"; then
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                path_inside_root "$f" || continue
                sz="$(file_size "$f")"
                case "$sz" in ''|*[!0-9]*) continue ;; esac
                total=$(( total + sz ))
            done < <(find -P "$d" -mindepth 1 -maxdepth 1 -type f -not -type l 2>/dev/null)
            continue
        fi
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            path_inside_root "$f" || { log "SKIP outside session root: $f"; continue; }
            mt="$(file_mtime "$f")"
            sz="$(file_size "$f")"
            case "$mt" in ''|*[!0-9]*) log "SKIP unstatable mtime: $f"; continue ;; esac
            case "$sz" in ''|*[!0-9]*) log "SKIP unstatable size: $f"; continue ;; esac
            printf '%s\t%s\t%s\t%s\n' "$mt" "$sz" "$cid" "$f" >>"$INVENTORY"
            total=$(( total + sz ))
        done < <(find -P "$d" -mindepth 1 -maxdepth 1 -type f -not -type l 2>/dev/null)
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
            path_inside_root "$f" || { log "SKIP outside session root: $f"; continue; }
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
            # #783 review (TOCTOU): re-assert containment ATOMICALLY with the
            # unlink. The check at the top of this iteration is separated from
            # the `rm` below by two forks (probe_ps, child_is_live); swapping
            # `$ROOT/<uuid>` for an outside-pointing symlink in that window would
            # make a path-based `rm` follow the new intermediate component out of
            # the root — the header's "can never delete outside it" would be
            # false. So: cd into the file's parent, then require the RESOLVED cwd
            # (`pwd -P`, which follows any planted symlink) to still be inside
            # the canonical root, then unlink by BASENAME — the shell's cwd is a
            # real directory, so a later swap of the PATH cannot redirect a
            # basename unlink. NOTE: the comparison is against `$ROOT_REAL`, not
            # against the literal `$(dirname "$f")` — `pwd -P` collapses `//`
            # and other redundant separators, so a literal comparison would
            # reject every legitimate path under a root whose env value ends in
            # a slash.
            if ( cd -- "$(dirname -- "$f")" 2>/dev/null \
                 && case "$(pwd -P)" in "$ROOT_REAL"/*) true ;; *) false ;; esac \
                 && rm -f -- "$(basename -- "$f")" ) 2>/dev/null; then
                printf '%s\n' "$f" >>"$DELETED"
                pruned_count=$(( pruned_count + 1 ))
                freed_bytes=$(( freed_bytes + sz ))
            else
                log "SKIP unlink failed or parent no longer inside the canonical root: $f"
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
                d="${d%/}"
                if [ -L "$d" ]; then
                    log "SKIP symlink child dir $d — never followed (symlink-escape guard)"
                    continue
                fi
                safe_child_dir "$d" || continue
                cid="$(basename "$d")"
                if child_is_live "$cid"; then
                    [ "$MODE" = dry-run ] && log "KEEP dir $d — child $cid is live"
                    continue
                fi
                if [ -z "$(find -P "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
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
