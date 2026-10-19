#!/usr/bin/env bash
# scripts/lib/bounded.sh — ONE bounded-execution helper for the reaper family (#2046).
#
# WHY THIS FILE EXISTS. `timeout` is GNU coreutils: macOS ships it nowhere, and `gtimeout` only when
# Homebrew's coreutils is installed. `scripts/disk-reaper.sh` called `timeout` at every one of its
# bounding sites, so on a Mac EVERY class died with `timeout: command not found` (rc=127 -> mapped to
# fail-closed, rc=3) and the pass still ran to completion printing `verdict=fail-closed` for each
# class — the false-PASS shape the reaper exists to remove (agent-infra#2046, measured 2026-10-18).
#
# RESOLUTION — ONE PLACE, ONE ORDER: `timeout` -> `gtimeout` -> the internal watchdog below.
# `scripts/pi-reap-worktrees.sh` already carried the watchdog (#1095): a background timer plus a
# sentinel file, so a real SIGKILL is distinguishable from a command that exited 137 on its own. That
# implementation MOVED here rather than being copied a second time — two copies is how they drift, and
# drift here means one reaper bounds a probe the other does not. `scripts/reap-lane-venvs.sh` still
# carries its own copy (it is a delegate that already works on macOS); folding it in is a separate,
# behaviour-neutral change, recorded in the report for #2046.
#
# SEAMS (tests, and an operator pinning a path):
#   TB_TIMEOUT_BIN=<path|name>    an explicit binary. UNUSABLE => TB_TIMEOUT_KIND=invalid and
#                                 tb_resolve_timeout returns 1; callers REFUSE at startup, they do not
#                                 silently fall back (a pin that is wrong must be named, not ignored).
#   TB_TIMEOUT_FORCE_INTERNAL=1   skip resolution entirely (exercise the fallback on a Linux host).
#   TB_BOUND_TMP_PREFIX           scratch-dir prefix (default "bounded").
# After source: TB_TIMEOUT_KIND is `timeout` | `gtimeout` | `internal` | `invalid`, and a pass records
# it, so "which mechanism bounded this pass" is answerable from the pass record.
#
# CONTRACT
#   tb_timeout <secs> <cmd...>        GNU-`timeout`-compatible: the command's own exit status is what
#                                     the caller sees; a TIMEOUT is 124, the code every caller already
#                                     treats as fail-closed. `<secs>` 0 = no bound. A non-integer
#                                     returns 125 WITHOUT running the command (GNU timeout's answer
#                                     too) — never "unbounded because the bound was unparseable",
#                                     which would turn a typo into a fail-OPEN pass.
#   tb_run <secs> <outfile> <cmd...>  stdout to <outfile>, stderr discarded, same statuses. The
#                                     outfile shape the worktree reaper's probes use.
#   tb_watchdogs_reap                 TERM every live watchdog timer (callers' EXIT trap).
#   tb_bound_cleanup                  remove the per-run probe scratch dir (callers' EXIT trap).
#
# This file is sourced. It never exits, sets no shell options, and defines no policy: the CALLER
# decides what a non-zero or 124 status means.

# ── resolution ───────────────────────────────────────────────────────────────────────────────────
# NB: TB_TIMEOUT_BIN is NOT reset here — an inherited value is the caller's pin (see SEAMS above).
TB_TIMEOUT_KIND=""

tb_resolve_timeout() {
    if [ "${TB_TIMEOUT_FORCE_INTERNAL:-0}" = "1" ]; then
        TB_TIMEOUT_BIN=""
        TB_TIMEOUT_KIND=internal
        return 0
    fi
    if [ -n "${TB_TIMEOUT_BIN:-}" ]; then
        # An explicit pin is authoritative, INCLUDING when it is wrong (same rule disk-reaper.sh's
        # find_delegate applies to a delegate override): falling back from it would mean the operator
        # pinned one thing and the pass ran with another, silently.
        if command -v -- "$TB_TIMEOUT_BIN" >/dev/null 2>&1; then
            TB_TIMEOUT_BIN="$(command -v -- "$TB_TIMEOUT_BIN")"
            case "${TB_TIMEOUT_BIN##*/}" in
                *gtimeout*) TB_TIMEOUT_KIND=gtimeout ;;
                *)          TB_TIMEOUT_KIND=timeout ;;
            esac
            return 0
        fi
        TB_TIMEOUT_KIND=invalid
        return 1
    fi
    if command -v -- timeout >/dev/null 2>&1; then
        TB_TIMEOUT_BIN="$(command -v -- timeout)"
        TB_TIMEOUT_KIND=timeout
        return 0
    fi
    if command -v -- gtimeout >/dev/null 2>&1; then
        TB_TIMEOUT_BIN="$(command -v -- gtimeout)"
        TB_TIMEOUT_KIND=gtimeout
        return 0
    fi
    TB_TIMEOUT_BIN=""
    TB_TIMEOUT_KIND=internal
    return 0
}

tb_resolve_timeout

# A one-line, human-facing description of the mechanism, for a pass report or a refusal message.
tb_watchdog_description() {
    case "${TB_TIMEOUT_KIND:-}" in
        timeout)  printf 'GNU timeout (%s)' "${TB_TIMEOUT_BIN:-?}" ;;
        gtimeout) printf 'gtimeout (%s) — GNU timeout absent' "${TB_TIMEOUT_BIN:-?}" ;;
        internal) printf 'internal watchdog (no GNU timeout/gtimeout on PATH)' ;;
        *)        printf 'UNRESOLVED (bad TB_TIMEOUT_BIN=%s)' "${TB_TIMEOUT_BIN:-}" ;;
    esac
}

# ── the internal fallback ───────────────────────────────────────────────────────────────────────
# Ported verbatim from pi-reap-worktrees.sh's `run_bounded` (#1095), which is why it already behaves
# the way every caller expects on a Mac.
#
# Fork economy is a correctness property here, not a micro-optimization: the reaper family runs
# ~10 bounded probes per pass on a host it exists to UNLOAD, and each probe used to cost two `mktemp`
# forks plus a `pkill -P` (an exec plus a full process-table scan). The scratch files now come from
# ONE per-run directory, and the watchdog holds its own timer as a child so a TERM tears the timer
# down — the `pkill` was only ever papering over the leak its predecessor created.
TB_WATCHDOGS=""
TB_BOUND_TMP=""
TB_BOUND_N=0

tb_is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

tb_bound_tmp() { # lazily create the per-run probe scratch dir; non-zero => degrade (no sentinel)
    [ -n "$TB_BOUND_TMP" ] && return 0
    TB_BOUND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/${TB_BOUND_TMP_PREFIX:-bounded}.XXXXXX" 2>/dev/null)" || TB_BOUND_TMP=""
    [ -n "$TB_BOUND_TMP" ] || return 1
    return 0
}

tb_bound_cleanup() { [ -n "$TB_BOUND_TMP" ] && rm -rf "$TB_BOUND_TMP"; TB_BOUND_TMP=""; return 0; }

tb_watchdogs_reap() {
    local w
    for w in $TB_WATCHDOGS; do kill -TERM "$w" 2>/dev/null; done
    TB_WATCHDOGS=""
}

# tb_watchdog <secs> <cmd...> — run <cmd> with a SIGKILL timer; 124 when the timer fired.
tb_watchdog() {
    local secs="$1"; shift
    local pid wd="" s rc=0 sentinel="" done_flag=""
    TB_BOUND_N=$((TB_BOUND_N + 1))
    if tb_bound_tmp; then
        sentinel="$TB_BOUND_TMP/s.$TB_BOUND_N"
        done_flag="$TB_BOUND_TMP/d.$TB_BOUND_N"
    fi
    "$@" &
    pid=$!
    (
        # TERM means the parent finished with this probe: kill the timer and leave without signalling
        # anything. No orphaned `sleep`, so no `pkill -P` sweep is needed.
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
    TB_WATCHDOGS="$TB_WATCHDOGS $wd"
    wait "$pid" 2>/dev/null || rc=$?
    if [ -n "$wd" ]; then
        [ -n "$done_flag" ] && : >"$done_flag"
        kill -TERM "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
    fi
    # The sentinel is the only way to tell "the watchdog killed it" from "the command died with 137 on
    # its own" — the exit status alone cannot.
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then rc=124; fi
    [ -n "$sentinel" ] && rm -f "$sentinel"
    [ -n "$done_flag" ] && rm -f "$done_flag"
    return $rc
}

# ── the two call shapes ────────────────────────────────────────────────────────────────────────

# tb_timeout <secs> <cmd...> — stdout/stderr are INHERITED (so `$(tb_timeout … 2>&1)` captures both).
tb_timeout() {
    local secs="${1:-}"
    [ $# -gt 0 ] || return 125
    shift
    [ $# -gt 0 ] || return 125
    # A bound that does not parse is a REFUSAL, never "run it unbounded": the same answer GNU
    # `timeout` gives (125), so a typo'd DISK_REAPER_CLASS_TIMEOUT cannot make a pass fail OPEN.
    if ! tb_is_pos_int "$secs"; then return 125; fi
    secs=$((10#$secs))
    if [ "$secs" -eq 0 ]; then "$@"; return $?; fi
    if [ -n "$TB_TIMEOUT_BIN" ]; then "$TB_TIMEOUT_BIN" "$secs" "$@"; return $?; fi
    tb_watchdog "$secs" "$@"
}

# tb_run <secs> <outfile> <cmd...> — stdout to <outfile>, stderr discarded.
tb_run() {
    local secs="${1:-}" out="${2:-}"
    [ $# -ge 2 ] || return 125
    shift 2
    [ $# -gt 0 ] || return 125
    : >"$out" 2>/dev/null || return 125
    tb_timeout "$secs" "$@" >"$out" 2>/dev/null
}
