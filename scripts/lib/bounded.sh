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
#
# ⛔ THE TIMER KILLS THE PROCESS **GROUP**, NOT JUST THE DIRECT CHILD (review of PR #3399, P2 —
# REPRODUCED). `kill -9 "$pid"` reaps the command itself, but a command that FORKS a transport helper
# leaves the grandchild alive — and because every caller captures this function's output
# (`out="$(tb_timeout … 2>&1)"`, the shape this file's own tb_timeout note documents), the orphan keeps
# the capture PIPE open and the command substitution blocks on it for as long as the orphan lives. The
# bound then holds in SPELLING only: measured `tb_timeout 3` over a command that backgrounds a
# `sleep 8` → **8 s** when captured, 3 s when redirected. In the fleet that is `git push` against a
# black-holed transport hanging a dying lane for the full TCP connect timeout (measured 131 s against a
# declared 15 s) on exactly the hosts this file exists for — macOS, which has no GNU `timeout` to signal
# the group. Linux runners masked it, which is why only the internal path could see it.
# ⛔ SO THE JOB GETS ITS OWN PROCESS GROUP (`set -m`) AND THE TIMER SIGNALS `-pgid`, which is what GNU
# `timeout` does and why it never had this defect. The group is assigned at FORK, so job control is
# restored immediately after both launches — the caller's `set -m` state is left exactly as it was found
# (the same discipline `run_agent` records for its own `set -m`), and the negative-pid kill still reaches
# the group afterwards. A shell that refuses `set -m` falls back to the direct-child kill, so this is a
# strict improvement on every host rather than a new dependency.
# ⛔ ONE SHAPE THIS FIX DOES **NOT** BOUND, STATED BECAUSE THE PARAGRAPH ABOVE MEASURES IT (cycle-21
# verification of a reviewer's finding — REPRODUCED ON BOTH SIDES of this change, so it is NOT a
# regression of it). The timer only fires while `wait "$pid"` is still running. A command that FORKS a
# helper and then EXITS 0 without waiting for it returns from `wait` at once, so nothing here ever signals
# that group: the helper keeps the caller's capture pipe open and the `out="$(…)"` shape blocks for the
# helper's whole lifetime. Measured: `tb_timeout 2` over `bash -c 'sleep 30 & exit 0'` returns rc=0 in
# ~2 ms, while the CAPTURED form does not return for 30 s — and the same measurement is identical on the
# pre-fix helper (`origin/main`) and under GNU `timeout 2` (which has the same property). Closing it
# requires a group signal AFTER the direct child has been reaped, i.e. against a pid the shell has
# already released to reuse; that trade is not made here. The pre-fix paragraph's measurement still
# holds for the shape it names — a command that IS still running when the timer fires, where the
# direct-child kill left the transport helper alive — and that shape is what this change fixes.
# ⛔ THE GUARANTEE IS THE COMMAND'S OWN PROCESS GROUP, AND IT IS NOT TRANSITIVE (review cycle 20, P2 —
# MEASURED). A command that itself calls `tb_timeout` enables job control in ITS shell too, so the inner
# command is a NEW group leader and is not a member of the group this timer signals: measured
# `tb_timeout 2 bash -c '. bounded.sh; tb_timeout 30 bash -c "sleep 8 & sleep 8"'` returns at 8 s, not
# 2 s (identical before and after this fix). So the bound bounds the DIRECT command and everything that
# stays in its group — it does NOT bound a nested `tb_timeout`. No in-tree caller nests today (the
# reaper's delegates and `conflict-rebase-timer.sh`'s python do not re-enter it), so no caller currently
# reads a guarantee it does not hold; the residue is tracked rather than glossed.
# ⛔ AND THE GROUP IS A HANDLE THE **CALLER** KEEPS, NOT A PRISON (review of PR #3399, P1 — REPRODUCED).
# The first cut forked the command AND its watchdog under `set -m`, so BOTH became group leaders and the
# fleet's termination discipline could no longer reach either one: a lane is reaped with
# `kill -TERM -- "-$pgid"` (spawn-gate.sh, cell-lane-preflight.sh) precisely so nothing is left resident
# for the census to account for, and measured under `setsid` a caller group-TERM left the bounded command
# alive at ppid 1 until its own bound expired — the bound had become a floor. Only the COMMAND is
# ungrouped (it must be: that is what lets the timer reach a transport helper the command forked). The
# WATCHDOG is forked with job control OFF so it stays in the CALLER's group, where the caller's group
# signal reaches it, and its trap FORWARDS that TERM to the command's group — GNU `timeout`'s behaviour,
# which is what the header above says this replicates.
# ⛔ AND THE FORWARDED TERM IS ESCALATED, BECAUSE THE TWO-STAGE REAP IS THE FLEET'S CONTRACT (review of PR
# #3399, P2 — REPRODUCED). A reaper sends `kill -TERM -- -<pgid>`, waits a grace, then `kill -KILL --
# -<pgid>`. Ungrouping the command — which is what lets the TIMER reach a transport helper — means the
# second stage no longer has that command in the caller's group, so a command that IGNORES TERM would
# survive the whole reap. The watchdog survives a TERM (it traps it) and is still in the caller's group, so
# it is what carries the escalation: forward TERM, wait a bounded grace, then SIGKILL the command's group.
# The grace is deliberately short (2 s) so it lands inside the fleet's 5 s TERM→KILL gaps
# (`merge-one.sh`, `fix-one.sh`); `lane-reap.sh`'s 1 s gap may close first, and that residue is STATED
# below rather than glossed. ⛔ THE ONE RESIDUE NOTHING CAN CARRY: a KILL-ONLY reap — the watchdog is
# SIGKILLed with the group before any trap can run, so the command is left to its own bound. GNU `timeout`
# has the identical property, which is why the fleet reaps in two stages.
tb_watchdog() {
    local secs="$1"; shift
    local pid wd="" s rc=0 sentinel="" done_flag="" was_m=0 g=0
    TB_BOUND_N=$((TB_BOUND_N + 1))
    was_m=0; case $- in *m*) was_m=1 ;; esac
    # ⛔ THE FALLBACK IS THE `|| kill -9 "$pid"` AT EACH KILL SITE, NOT A FLAG.
    # `set -m` is best-effort: a shell that refuses it leaves the command in the CALLER's group, where the
    # negative-pid kill reaches nothing and the direct-child kill does the job — a strict improvement on
    # every host, with no new dependency. There used to be a `jobctl` variable recording whether `set -m`
    # took, assigned and NEVER READ, which invited a future reader to believe the fallback was gated on it.
    set -m 2>/dev/null || true
    # ⛔ STDIN IS REDIRECTED, SO THE BOUND DOES NOT GAIN AN INPUT. bash gives a background job `/dev/null`
    # as stdin only when job control is OFF; with `set -m` in effect (one line up) it INHERITS the caller's
    # stdin, so a bounded `cat` or an interactive `gh` would silently consume a pipe meant for the caller.
    # The redirection restores exactly the behaviour every existing caller had before `set -m` existed.
    "$@" </dev/null &
    pid=$!
    # ⛔ THE SENTINEL IS NAMED FROM THE COMMAND'S OWN PID, NOT FROM A SHELL COUNTER (review round 4, P2 —
    # MEASURED). `TB_BOUND_N` lives in the shell, but a CAPTURED bounded call runs this whole function in a
    # command-substitution SUBSHELL whose increment is discarded — so two concurrent calls in one shell both
    # minted `s.1`/`d.1`: one call's `done_flag` was visible to the other's timer (which then exited 0 and
    # SKIPPED ITS SIGKILL, i.e. the bound was defeated) and its `rm -f` could clear the other's flag. Latent
    # today — no in-tree caller runs two at once — but it is a fail-OPEN shape in the one mechanism every
    # caller trusts. `$pid` is unique per call in this shell AND across subshells, and costs no fork, which
    # a `mktemp` per sentinel would (fork economy is credited as a correctness property above). The counter
    # stays as a record only. It is named here, after the fork, because before it the command has no pid.
    if tb_bound_tmp; then
        sentinel="$TB_BOUND_TMP/s.$pid"
        done_flag="$TB_BOUND_TMP/d.$pid"
    fi
    # ⛔ JOB CONTROL OFF FOR THIS FORK, ON PURPOSE (see the paragraph above the function): the watchdog must
    # stay in the caller's group to receive the caller's group signal.
    set +m 2>/dev/null
    (
        # TERM means the caller is finished with this probe — either the parent reaped the command, or the
        # CALLER's own group-TERM arrived (the lane reaper's shape). Kill the timer; and when the command is
        # still running, FORWARD the TERM to its group, or a group-killed lane leaves the bounded command
        # resident for up to its whole bound — the very resident this function exists to not create.
        # ⛔ `done_flag` IS THE DISCRIMINATOR, NOT `kill -0` (which is the narrow fallback for the degraded
        # full-disk shape where no scratch dir could be made): the parent writes it BEFORE it signals this
        # watchdog, so its presence means "the command already finished — forward nothing", which also
        # closes the reap window in which `$pid` could have been reused by an unrelated process.
        # ⛔ AND THE FORWARD IS ESCALATED (see the paragraph above the function): TERM, a bounded 2 s grace,
        # then SIGKILL to the same group — otherwise a command that ignores TERM outlives a two-stage reap,
        # because it is no longer in the caller's group for the KILL stage to reach.
        trap 'kill "$s" 2>/dev/null
              if { [ -z "$done_flag" ] || [ ! -e "$done_flag" ]; } && kill -0 "$pid" 2>/dev/null; then
                  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                  g=0
                  while [ "$g" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.2 2>/dev/null || break; g=$((g + 1)); done
                  if kill -0 "$pid" 2>/dev/null; then kill -9 "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null; fi
              fi
              exit 0' TERM INT
        sleep "$secs" &
        s=$!
        wait "$s" 2>/dev/null
        [ -n "$done_flag" ] && [ -e "$done_flag" ] && exit 0
        if kill -0 "$pid" 2>/dev/null; then
            [ -n "$sentinel" ] && : >"$sentinel"
            # ⛔ THE GROUP FIRST, THE CHILD AS THE FALLBACK. A grandchild (git's transport helper) is what
            # holds a caller's capture pipe open; killing only `$pid` leaves it writing into that pipe.
            kill -9 "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        fi
    ) >/dev/null 2>&1 &
    wd=$!
    # The caller's job-control state is restored EXACTLY as it was found, after BOTH forks — so a caller
    # that runs with `set -m` gets it back for everything it runs while this probe is in flight.
    [ "$was_m" = "1" ] && set -m 2>/dev/null
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
