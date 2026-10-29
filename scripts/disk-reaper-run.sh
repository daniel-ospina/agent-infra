#!/usr/bin/env bash
# disk-reaper-run.sh — the scheduled pass's WRAPPER: the environment a systemd timer does not inherit.
#
# WHY THIS EXISTS (#2354). A timer-started `disk-reaper.sh --apply` inherits nothing from the lane
# shell it was written for, and it produced ZERO reclaimed bytes on a cell at 99% used:
#
#   MODE=apply WORKTREES=101 REMOVE=0 PRESERVE=0 REMOVED=0 GH=unavailable
#   FAIL-CLOSED abort: gh unavailable or the origin-remote probe failed (exit 3)
#
# Three separable causes, all of them environment:
#
#   1. NO HOME. `gh` keeps its auth under $HOME; with none the open-PR query cannot run and the
#      worktree class fails closed (correctly — it must never guess at an open PR).
#   2. THE WRONG `gh`. The interactive PACING shim (`gh-shim/gh`) was first on PATH. Its admission
#      queue is a courtesy to a shared account: a slot can be held for `ACQUIRE_TIMEOUT` (300 s) by
#      another caller, and a BOUNDED hourly sweep must never enter an unbounded queue. `gh pr list`
#      is a READ; it needs the real binary, not the admin-merge interposer. (The shim is still on
#      PATH below, so any tool that WANTS the pacing layer still gets it.)
#   3. A POISONED `AGENT_GH_REAL`. That env value is documented as "set by an outer invocation so a
#      nested call cannot recurse" — but an inherited value that IS the shim makes every generation
#      re-exec the shim, and the ladder deadlocks on its own children. The shim now refuses such a
#      value (agent-infra #2266/#2295); the `unset` here is belt-and-braces for a farmed copy that
#      predates the fix, which is exactly what a cell runs until its next sync.
#
# THE VETO IS NOT WEAKENED. If no real `gh` can be resolved the pass still FAILS CLOSED and removes
# nothing: an unreadable open-PR list is a deployment defect to fix, never a licence to skip the veto.
#
# Usage: disk-reaper-run.sh [--dry-run|--apply]   (default --apply; the unit's arming decision)
#        Any other arguments are forwarded to disk-reaper.sh.

set -uo pipefail

# ── HOME: the caller's if it is real, else the cell's ──────────────────────────────────────────────
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    if [ -d "$CELL_HOME" ]; then
        HOME="$CELL_HOME"
    else
        echo "disk-reaper-run: REFUSING — no usable HOME (got '${HOME:-<unset>}', and '$CELL_HOME' does not exist)." >&2
        echo "  gh auth lives under HOME; without it the open-PR gate fails closed and nothing is reaped." >&2
        exit 3
    fi
fi
export HOME

# The cell's keys/env (PATH, provider keys). Optional: absent on a box that does not use one.
if [ -r "$HOME/keys.env" ]; then
    # shellcheck disable=SC1090
    . "$HOME/keys.env"
fi

# ── AGENT_GH_REAL: never inherit a value that is an interposer ─────────────────────────────────────
# The seam exists so a NESTED call does not recurse; a poisoned value does the opposite. Unset
# unconditionally: this process resolves the real binary itself, below, and exports its own value.
unset AGENT_GH_REAL

# ── gh: the REAL binary for the read-only PR query ────────────────────────────────────────────────
# Resolved by absolute path on purpose: a PATH search is what found the shim, and the whole point is
# that this pass must not inherit the interactive pacing queue. A `gh-shim`/`gh-limit` path is
# rejected explicitly — a wrapper named `gh` in one of those dirs is an interposer, not gh.
resolve_real_gh() {
    local c
    # `GH_REAL` is an OPERATOR SEAM (an explicit absolute path, e.g. a nix store binary). It is
    # validated by file magic like every other candidate, so a compiled interposer still passes —
    # that is the operator asserting it. The INHERITANCE seam (`AGENT_GH_REAL`) is unset above.
    for c in "${GH_REAL:-}" /usr/bin/gh /bin/gh /usr/local/bin/gh /opt/homebrew/bin/gh \
             /opt/local/bin/gh "${HOME:-}/.local/bin/gh"; do
        [ -n "$c" ] || continue
        [ -x "$c" ] || continue
        case "$c" in
            *gh-shim*|*gh-limit*|*harness*gh*) continue ;;
        esac
        # A shell wrapper is not the real gh either: the real one is a binary (Go ELF / Mach-O).
        # `-x` alone accepted a shim script; this rejects a non-binary without needing `file`.
        if [ "$(head -c 4 "$c" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
            printf '%s\n' "$c"; return 0
        fi
        # macOS Mach-O (64-bit, little endian) and the universal binary magic.
        case "$(head -c 4 "$c" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
            cffaedfe|cefaedfe|cafebabe) printf '%s\n' "$c"; return 0 ;;
        esac
    done
    return 1
}

GH_REAL="$(resolve_real_gh)" || GH_REAL=""
if [ -n "$GH_REAL" ]; then
    export GH_BIN="$GH_REAL"
else
    # ⛔ AN UNSET GH_BIN IS NOT A REFUSAL (review of #2354): the reaper defaults
    # `GH_BIN="${GH_BIN:-gh}"` — a PATH LOOKUP — and on a cell the only `gh` on PATH is the pacing
    # shim this wrapper exists to avoid. The pass would park in the shim's admission queue and be
    # killed at REAP_WT_GH_TIMEOUT: #2354 reproduced, with only a stderr warning to show it.
    # A path that cannot exist makes the probe fail at once (rc=127), so the class exits 3 and the
    # status file records GH=failed — the honest, bounded, loud outcome.
    export GH_BIN="/nonexistent/no-real-gh-for-disk-reaper"
    echo "disk-reaper-run: WARNING — no real gh binary resolved; the worktree class will fail closed (open-PR veto unverifiable)." >&2
fi

# Never sleep inside a bounded sweep. The shim documents this seam for exactly this caller class:
# a caller that declared its own bound must not be parked in a shared cooldown.
export AGENT_GH_GATE_NO_WAIT=1
# The reaper's own bound for the read-only query. The real gh answers in well under a second; the
# unit's 300 s default existed to clear the SHIM's backoff, which is no longer on this path.
export REAP_WT_GH_TIMEOUT="${REAP_WT_GH_TIMEOUT:-120}"

# The pacing shim stays available to anything else that runs under this wrapper, but LAST: nothing
# here may resolve `gh` through it.
SHIM_DIR="${AGENT_GH_SHIM_DIR:-}"
[ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] || SHIM_DIR=""
case ":$PATH:" in
    *":$SHIM_DIR:"*) : ;;
    *) [ -n "$SHIM_DIR" ] && export PATH="$PATH:$SHIM_DIR" ;;
esac

# ⛔ THE REAPER IS RESOLVED BESIDE THIS WRAPPER, NOT VIA $HOME (review of #2354).
# This wrapper is the entry point the installer renders into `ExecStart` / `--script`, and the
# installer validates the directory it lives in (refuse_transient_target). Resolving
# $HOME/.pi/agent/scripts/disk-reaper.sh here DISCARDED that pin: the unit exec'd the pinned wrapper,
# which then ran whatever farm copy was in HOME — the stale-copy failure the pin exists to prevent
# (measured: a farm copy ran while the pinned copy sat beside the wrapper).
# ⛔ AND THE SIBLING FALLBACK DOES NOT EXIST ON DARWIN: the launchd launcher pipes this file to
# `/bin/bash -s`, where `BASH_SOURCE` is UNSET, so a wrapper that trusted it alone would refuse on
# every tick — #2354's zero-reclaim reproduced by its own fix (caught in review). The templates pin
# `DISK_REAPER` for exactly that reason; the sibling lookup is only a convenience for a manual run.
# An explicit DISK_REAPER therefore WINS, and an empty name is refused rather than resolving to $PWD.
# NOTE: gate on BASH_SOURCE BEING SET, not on the resulting dir — `dirname ""` is `.`, so a bare
# `cd -- "$(dirname "")"` resolves to the CWD (under `bash -s` that meant / and /tmp) instead of
# failing. An unset source must leave WRAPPER_DIR EMPTY so the refusal below can fire.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    WRAPPER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
else
    WRAPPER_DIR=""
fi
REAPER="${DISK_REAPER:-}"
if [ -z "$REAPER" ]; then
    if [ -z "$WRAPPER_DIR" ]; then
        echo "disk-reaper-run: REFUSING — cannot resolve this wrapper's own directory (BASH_SOURCE is unset, e.g. under 'bash -s'), and DISK_REAPER is not set. The unit must pin DISK_REAPER=/path/to/disk-reaper.sh." >&2
        exit 3
    fi
    REAPER="$WRAPPER_DIR/disk-reaper.sh"
fi
if [ ! -f "$REAPER" ]; then
    echo "disk-reaper-run: REFUSING — $REAPER is missing (the farmed scripts are not installed)." >&2
    exit 3
fi

# Arming: the unit decides, this wrapper only supplies a default when the caller gave no mode.
case " $* " in
    *" --dry-run "*|*" --apply "*) : ;;
    *) set -- --apply "$@" ;;
esac

exec /bin/bash "$REAPER" "$@"
