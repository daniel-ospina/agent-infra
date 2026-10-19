#!/usr/bin/env bash
# portable.sh — THE portability shim (agent-infra#2046, agent-infra#2048).
#
# WHY THIS FILE EXISTS. A GNU-only flag is not a style problem, it is a DEPLOYMENT defect: the
# component installs cleanly, the schedule fires, and the work silently does not happen on one
# platform. That is exactly how the consolidated disk reaper behaved on the laptop (#2046): macOS
# ships neither `timeout` nor `gtimeout`, so every class died with `timeout: command not found`
# (rc=127 -> fail-closed) while the pass COMPLETED and printed `verdict=fail-closed`. Nothing was
# reaped, and the report looked like a considered decision.
#
# The same class of defect hides in three more flags that look portable and are not:
#   `nproc`      GNU coreutils; macOS has `sysctl -n hw.ncpu`
#   `stat -c`    GNU coreutils; the BSDs use `stat -f` with different letters (`%s`/`%z`)
#   `date -d`    GNU coreutils; the BSDs parse with `date -j -f <fmt> <str>`
# Each helper below resolves the platform ONCE, returns a usable value, or returns EMPTY with a
# non-zero status. ⛔ None of them fabricates a default: a made-up `1` CPU, a `0` age or a `0` size
# reads downstream as a healthy answer, which is the false PASS this repo keeps removing.
#
# Contract (asserted by scripts/lib/portable.test.sh on whatever platform runs it):
#   _portable_platform      darwin | linux | <uname -s lowercased>   (never empty)
#   _timeout <secs> <cmd…>  wall-clock bound; 124 on timeout, 125 on a non-integer bound, 0 = unbounded
#   _nproc                  positive integer CPU count, or empty + rc 1
#   _stat_size <path>       exact size in BYTES, or empty + rc 1
#   _stat_mtime <path>      epoch seconds of mtime, or empty + rc 1
#   _stat_dev <path>        device id (both stat(1)s spell it %d)
#   _date …                 --epoch | --iso | --parse <str> | --add <secs> | --fmt <epoch> <fmt> | <date(1)> args
#
# ONE IMPLEMENTATION OF EACH RULE. `_timeout` delegates to scripts/lib/bounded.sh (the resolver merged
# for #2046: `timeout` -> `gtimeout` -> an internal background watchdog, same 124 contract) instead of
# carrying a second copy that can drift. This file is the front door; bounded.sh is the engine.
#
# ⛔ A MISSING ENGINE IS A REFUSAL AT SOURCE TIME, not a degraded shim. Half a shim is precisely the
# #2046 defect: the component starts, and every bounded call fails closed while the pass completes.
# Callers that cannot tolerate that (the reapers) already treat a failed source as fatal; this file
# makes the refusal explicit and NAMES what is missing.
#
# Usage:  . "$(dirname "${BASH_SOURCE[0]}")/lib/portable.sh"
#
# Env seams (tests):
#   PORTABLE_BOUNDED_LIB   pin the engine (a SET-but-missing value is a refusal, never a silent
#                          different file — the same rule as BOUNDED_LIB in disk-reaper.sh)
#   PORTABLE_PLATFORM      override detection: linux | darwin (tests)
set -uo pipefail

# ── platform ───────────────────────────────────────────────────────────────────────────────────
# Lowercased `uname -s` so a caller can compare against `darwin`/`linux` without re-deriving it.
# The override exists because a test must be able to render/assert the OTHER platform's branch.
_portable_platform() {
    if [ -n "${PORTABLE_PLATFORM:-}" ]; then
        printf '%s\n' "$PORTABLE_PLATFORM"
        return 0
    fi
    local s
    s="$(uname -s 2>/dev/null)" || { printf 'unknown\n'; return 0; }
    printf '%s\n' "$s" | tr '[:upper:]' '[:lower:]'
}

# ── the bounded-execution engine ───────────────────────────────────────────────────────────────
_PORTABLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PORTABLE_BOUNDED_LIB="${PORTABLE_BOUNDED_LIB:-}"
if [ -z "$PORTABLE_BOUNDED_LIB" ]; then
    for _cand in "$_PORTABLE_DIR/bounded.sh" "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$_cand" ] || continue
        [ -f "$_cand" ] && { PORTABLE_BOUNDED_LIB="$_cand"; break; }
    done
fi
if [ ! -f "${PORTABLE_BOUNDED_LIB:-}" ]; then
    printf 'portable.sh: ⛔ FAIL-CLOSED — the bounded-execution engine is missing (%s).\n' \
        "${PORTABLE_BOUNDED_LIB:-not at $_PORTABLE_DIR/bounded.sh and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    printf 'portable.sh: refusing to load, because a shim without it lets every bounded call fail closed while the pass completes (#2046)\n' >&2
    # ⛔ EXIT, not `return`: a caller that continues after a failed source has NO helpers defined, and
    # every `_timeout` call in it then fails closed while the component completes — the exact #2046
    # shape. Refusing to start is the only fail-closed answer. (Tests source this in a subshell.)
    exit 1
fi
# shellcheck source=lib/bounded.sh
. "$PORTABLE_BOUNDED_LIB"

# _timeout <secs> <cmd…> — the ONE public name for a wall-clock bound. `tb_timeout` is the engine's
# name and stays callable, so the #2046 call sites and their tests did not have to move.
_timeout() { tb_timeout "$@"; }

# ── CPU count ─────────────────────────────────────────────────────────────────────────────────
# `nproc` is GNU coreutils. Resolution order is platform-first, and `nproc` is only ever consulted
# last: on a Linux box that has it, `nproc` and `getconf` agree (asserted in the test), and on a BSD
# `nproc` may exist from a Homebrew coreutils install with a DIFFERENT meaning under a cgroup.
_nproc() {
    local n=""
    case "$(_portable_platform)" in
        darwin) n="$(sysctl -n hw.ncpu 2>/dev/null || true)" ;;
    esac
    if [ -z "$n" ]; then n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"; fi
    if [ -z "$n" ]; then n="$(nproc 2>/dev/null || true)"; fi
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -gt 0 ] 2>/dev/null || return 1
    printf '%s\n' "$n"
}

# ── stat: size and mtime ──────────────────────────────────────────────────────────────────────
# A leading `-` in a filename would be read as a flag by GNU stat; BSD stat has no `--` terminator.
# Prefixing `./` is the one form both accept. Every value is validated as digits before it is
# printed, so a locale-decorated or error-message answer is never mistaken for a measurement.
_portable_stat() { # _portable_stat <gnu-fmt> <bsd-fmt> <path>
    local gfmt="$1" bfmt="$2" p="$3" v=""
    case "$p" in '' ) return 1 ;; -*) p="./$p" ;; esac
    case "$(_portable_platform)" in
        darwin|*bsd*) v="$(stat -f "$bfmt" "$p" 2>/dev/null || true)" ;;
        *)            v="$(stat -c "$gfmt" "$p" 2>/dev/null || true)" ;;
    esac
    # The platform guess can be wrong (a GNU stat on a BSD userland, or vice versa); fall back to the
    # other spelling rather than reporting "unmeasurable" on a box that can plainly measure.
    if [ -z "$v" ]; then
        v="$(stat -f "$bfmt" "$p" 2>/dev/null || stat -c "$gfmt" "$p" 2>/dev/null || true)"
    fi
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$v"
}

_stat_size()  { _portable_stat '%s' '%z' "$1"; }   # bytes
_stat_mtime() { _portable_stat '%Y' '%m' "$1"; }   # epoch seconds
_stat_dev()   { _portable_stat '%d' '%d' "$1"; }   # device id (same letter both stat(1)s)

# ── date ──────────────────────────────────────────────────────────────────────────────────────
# The single GNU-ism that breaks scheduled work hardest is `date -d`, which the BSDs do not have at
# all. `_date` accepts the shapes the harness actually uses and answers in epoch seconds, so a caller
# never has to know which date(1) it is holding:
#   _date --epoch                 now
#   _date --iso                   now, UTC, %Y-%m-%dT%H:%M:%SZ (the pass-record / stamp format)
#   _date --parse '2026-10-18T17:27:01Z'
#   _date --parse '2026-10-18'    (midnight UTC)
#   _date --parse '@1792345000'   (already an epoch)
#   _date --parse '10 minutes ago' | '10 minutes' | '-10 minutes'
#   _date --add 3600              now + 3600
#   _date --fmt 1792345000 '%Y-%m-%d'   format an EPOCH portably (BSD date needs -r, GNU needs -d @)
#   _date -u +%Y-%m-%d            anything else is handed to date(1) unchanged (already portable)
# ⛔ An unparseable input returns EMPTY + rc 1. A zero is a real timestamp, so it must never be the
# failure value.
_date() {
    case "${1:-}" in
        --epoch) shift; date +%s; return $? ;;
        --iso)   shift; date -u +%Y-%m-%dT%H:%M:%SZ; return $? ;;
        --add)
            local delta now
            delta="${2:-}"
            case "$delta" in ''|*[!0-9-]*) return 1 ;; esac
            # ⛔ `$(( $(date +%s) + delta ))` with a BROKEN `date` is `0 + delta` — a plausible epoch
            # (60) returned with rc=0, indistinguishable from a real answer. That is the one fail-OPEN
            # shape in this shim and it contradicts the rule above: the failure value may never be a
            # value a caller would believe.
            now="$(date +%s 2>/dev/null)" || return 1
            case "$now" in ''|*[!0-9]*) return 1 ;; esac
            printf '%s\n' "$(( now + delta ))"
            return 0
            ;;
        --parse) shift; _date_parse "${1:-}" ;;
        --fmt)
            # An epoch is formatted with `date -r` on the BSDs and `date -d @` on GNU; neither exists
            # on the other platform. One place, so a caller never branches on the host.
            local ep="${2:-}" f="${3:-}"; shift 3 2>/dev/null || true
            case "$ep" in ''|*[!0-9]*) return 1 ;; esac
            [ -n "$f" ] || f='%Y-%m-%dT%H:%M:%SZ'
            if [ "$(_portable_platform)" = darwin ]; then
                date -u -r "$ep" "+$f" 2>/dev/null
            else
                date -u -d "@$ep" "+$f" 2>/dev/null
            fi
            ;;
        *)       date "$@" ;;
    esac
}

# _date_parse <string> — epoch seconds, or empty + rc 1.
_date_parse() {
    local s="${1:-}" nums units sign n u off now
    case "$s" in
        '') return 1 ;;
        @*) # an epoch, handed straight back
            s="${s#@}"
            case "$s" in ''|*[!0-9]*) return 1 ;; esac
            printf '%s\n' "$s"; return 0 ;;
        # "2026-10-18T17:27:01Z" and "2026-10-18T17:27:01+00:00" — the forms our records and stamps use
        ????-??-??T??:??:??Z)
            if [ "$(_portable_platform)" = darwin ]; then
                date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null || return 1
            else
                date -u -d "$s" +%s 2>/dev/null || return 1
            fi
            return 0 ;;
        ????-??-??T??:??:??+??:??|????-??-??T??:??:??-??:??)
            if [ "$(_portable_platform)" = darwin ]; then
                # BSD `date -f %z` wants +HHMM, not +HH:MM (measured: the colon form parses to a
                # DIFFERENT instant, silently). Normalise the offset before handing it over.
                off="${s: -6}"
                # `${off%:??}` keeps the sign and drops the minutes; `${off#??:??}` never matched, so the
                # pair produced `+02+02:00` — a string BSD `date` can never parse, in a branch that
                # looked like it worked because the failure is a clean rc 1. `%:*` / `#*:` is the form.
                case "$off" in +??:??|-??:??) s="${s%??????}${off%:*}${off#*:}" ;; esac
                date -j -f '%Y-%m-%dT%H:%M:%S%z' "$s" +%s 2>/dev/null || return 1
            else
                date -u -d "$s" +%s 2>/dev/null || return 1
            fi
            return 0 ;;
        ????-??-??)
            if [ "$(_portable_platform)" = darwin ]; then
                # ⛔ BSD `date -j -f '%Y-%m-%d'` fills the TIME-OF-DAY FROM THE CURRENT CLOCK — measured
                # 2026-10-19: '1970-01-01' parsed to 4016, not 0. A date-only value must mean midnight
                # UTC, so the time is pinned explicitly instead of inherited from "now".
                date -j -u -f '%Y-%m-%d %H:%M:%S' "$s 00:00:00" +%s 2>/dev/null || return 1
            else
                date -u -d "$s" +%s 2>/dev/null || return 1
            fi
            return 0 ;;
    esac

    # "<N> <unit>[/s] [ago]" and "-<N> <unit>[/s]" — the `date -d '10 minutes ago'` idiom, resolved
    # WITHOUT date(1) so both platforms take one code path and cannot disagree about DST or units.
    # The COMPACT forms are accepted too (`-7d`, `7d`): a migrated `date -d '-7d'` call site must not
    # be silently refused on both platforms, which reads exactly like "there is nothing that old".
    # (no SPACE anywhere in the string, and the last char a unit letter, and the rest digits)
    case "$s" in
        '') : ;;
        *' '*) : ;;
        *)
            n="${s#[-+]}"; u="${n#"${n%?}"}"; n="${n%?}"
            case "$n" in
                ''|*[!0-9]*) : ;;
                *)
                    case "$u" in
                        s) nums=1 ;; m) nums=60 ;; h) nums=3600 ;; d) nums=86400 ;; w) nums=604800 ;;
                        *) nums="" ;;
                    esac
                    if [ -n "$nums" ]; then
                        sign=1; case "$s" in -*) sign=-1 ;; esac
                        now="$(date +%s 2>/dev/null)" || return 1
                        case "$now" in ''|*[!0-9]*) return 1 ;; esac
                        printf '%s\n' "$(( now + sign * n * nums ))"
                        return 0
                    fi ;;
            esac ;;
    esac
    set -- $s
    sign=1
    case "${1:-}" in
        -*) sign=-1; n="${1#-}"; shift ;;
        +*) n="${1#+}"; shift ;;
        *)  n="${1:-}"; shift ;;
    esac
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    u="${1:-}"; shift 2>/dev/null || true
    case "${1:-}" in
        ago|before) sign=$(( sign * -1 )) ;;
    esac
    case "$u" in
        s|sec|secs|second|seconds)  nums=1 ;;
        m|min|mins|minute|minutes)  nums=60 ;;
        h|hr|hrs|hour|hours)        nums=3600 ;;
        d|day|days)                 nums=86400 ;;
        w|week|weeks)               nums=604800 ;;
        *) return 1 ;;
    esac
    now="$(date +%s 2>/dev/null)" || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$(( now + sign * n * nums ))"
    return 0
}
