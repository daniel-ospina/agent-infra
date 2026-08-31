#!/usr/bin/env bash
# sweep-orphans.sh — flag and (with --apply) kill orphaned pi dispatch
# process trees left by SIGKILLed parents (issue #385, class-9 bridge).
#
# When a pi orchestrator is SIGKILLed (macOS Jetsam or any cause), its
# in-flight task sub-agents + their MCP grandchildren reparent to PID 1 and
# accumulate (the memory death spiral). The primary fix is the child-side
# orphan watchdog in extensions/task-heartbeat.ts (self-termination on
# ppid→1). THIS script is the warn-first session-start BRIDGE for
# pre-existing orphans and the backstop for orphans whose watchdog could not
# fire (sync-blocked children, pre-fix accumulation).
#
# Classification (all must hold for a candidate):
#   ppid == 1                        (reparented — orphaned by definition for
#                                     dispatch children; fail-open otherwise)
#   stat != Z                        (zombie: no memory, cannot be killed)
#   env contains EXACT token         TASK_HEARTBEAT=1 (the dispatch identity
#                                     pair — set ONLY by the task tool and the
#                                     subagent extension, inherited by MCP
#                                     grandchildren; hard fail-closed gate:
#                                     unreadable env → skip with a visible ⚠️)
#   ORPHAN_WATCHDOG != 0             (opt-out valve parity with the watchdog)
#   age >= cutoff                    (etime — elapsed time, D-HH:MM:SS /
#                                     HH:MM:SS on macOS + Linux, zero calendar
#                                     parsing; 0 disables the gate)
#   pgid != sweep's own pgid         (never signal the orchestrator's group)
#
# Kill primitive (--apply only): group TERM → 3s → group KILL ONLY when
# pgid == pid (detached/leader case — the group contains only the orphan +
# its descendants); pgid != pid (non-detached spawn sharing the parent's
# session group) → per-pid TERM → 3s → KILL, NEVER a group signal (a live
# terminal session could be in that group). Settle re-verify (ppid + env)
# immediately before every kill — pid-recycling insurance.
#
# Documented limits (see plan Step 3 header):
#   - Linux subreaper adoption: pre-existing orphans adopted by a non-1
#     subreaper are NOT classified by the ppid==1 gate (the watchdog's
#     changed-ppid arm covers NEW orphans; subreaper-class sweep = follow-up).
#   - interactive-pi MCP transports / session orphans carry no pair env →
#     excluded (declared residual, env-agnostic classifier = follow-up).
#   - macOS `ps eww` env readability is version-sensitive (verified on
#     25.5.0); unreadable env → fail-closed skip with a visible ⚠️ line.
#   - etime is suspend-insensitive (kernel ticks pause during sleep); the
#     in-child watchdog is wall-clock and still reaps — documented divergence.
#
# Notification-first: dry-run by default. --apply kills confirmed orphans.
# Exit 0 always (warn-only surface; failures are attribution notes, never a
# hard error — a degraded sweep MUST still print a visible ⚠️ line).
#
# Usage:
#   bash scripts/sweep-orphans.sh [--apply] [--cutoff N] [--help]
#   (dry-run default; --cutoff 0 disables the age gate — test/settle override)

set -euo pipefail

APPLY=false
CUTOFF_HOURS=24

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --cutoff) CUTOFF_HOURS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash scripts/sweep-orphans.sh [--apply] [--cutoff N] [--help]"
            echo "  dry-run by default; --apply kills confirmed orphans"
            echo "  --cutoff N: hours (default 24); 0 disables the age gate"
            exit 0 ;;
        *) echo "Unknown arg: $1 (use --help)" >&2; exit 1 ;;
    esac
done

if ! [[ "$CUTOFF_HOURS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --cutoff must be a non-negative integer (hours)" >&2; exit 1
fi

# ── Helpers ────────────────────────────────────────────────────

now_epoch() { date +%s; }

# etime_to_seconds — parse `[D-]HH:MM:SS` or `MM:SS` (ps -o etime, same shape
# on macOS and Linux) into seconds. 0 on parse failure (fail-closed: a
# malformed value never classifies a process as old enough to kill).
etime_to_seconds() {
    local e="$1"
    case "$e" in
        *-*) # D-HH:MM:SS
            local d="${e%%-*}" rest="${e#*-}"
            local h="${rest%%:*}" mrest="${rest#*:}"
            local m="${mrest%%:*}" s="${mrest#*:}"
            echo $(( d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
            ;;
        *:*:*) # HH:MM:SS
            local h="${e%%:*}" mrest="${e#*:}"
            local m="${mrest%%:*}" s="${mrest#*:}"
            echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
            ;;
        *:*) # MM:SS
            local m="${e%%:*}" s="${e#*:}"
            echo $(( 10#$m * 60 + 10#$s ))
            ;;
        *) echo 0 ;;
    esac
}

# env_has_pair — <pid> → 1 when the process env carries the EXACT token
# TASK_HEARTBEAT=1 (word-boundary — never a substring match like
# TASK_HEARTBEAT=10). macOS: `ps eww -p`; Linux: /proc/<pid>/environ.
# 0 / unreadable / empty → fail-closed (caller emits the ⚠️ line).
env_has_pair() {
    local pid="$1" envout
    if [ -r "/proc/$pid/environ" ]; then
        envout="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)"
    else
        envout="$(ps eww -p "$pid" 2>/dev/null | tail -n +2 || true)"
        # macOS ps eww appends env AFTER the command — match the exact token
        # anywhere in the line (the env section is the only place the
        # dispatchers' vars can appear; a false positive would need
        # TASK_HEARTBEAT=1 as a literal argv token, which dispatch children
        # never carry).
    fi
    printf '%s\n' "$envout" | grep -qx 'TASK_HEARTBEAT=1'
}

CUTOFF_SECONDS=$(( CUTOFF_HOURS * 3600 ))
OWN_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo 0)"

echo "=== Orphan process sweep $( [ "$APPLY" = true ] && echo '[--apply]' ) (cutoff ${CUTOFF_HOURS}h, own-pgid ${OWN_PGID}) ==="

# ── Whole-run degradation visibility ───────────────────────────
if ! command -v ps >/dev/null 2>&1; then
    echo "⚠️ ps unavailable — sweep degraded, no classification performed"
    exit 0
fi

# ── Classification pass ─────────────────────────────────────────
ORPHANS=0
SKIPPED=0
# ps axww: unbounded command width (GNU ps truncates at 80 cols without ww —
# a trailing -p would be lost; the classifier is env-only so this is
# belt-and-suspenders, but attribution must not be truncated either).
while IFS= read -r line; do
    [ -z "$line" ] && continue
    PID="$(printf '%s' "$line" | awk '{print $1}')"
    PARENT_PID="$(printf '%s' "$line" | awk '{print $2}')"
    PGID="$(printf '%s' "$line" | awk '{print $3}')"
    STAT="$(printf '%s' "$line" | awk '{print $4}')"
    ETIME="$(printf '%s' "$line" | awk '{print $5}')"
    CMD="$(printf '%s' "$line" | cut -d' ' -f6-)"
    [ "$PID" = "PID" ] && continue # header (defensive)
    case "$PID" in ''|*[!0-9]*) continue ;; esac
    [ "$PID" -le 1 ] && continue
    [ "$PARENT_PID" = "1" ] || continue        # 1. reparented
    case "$STAT" in Z*) continue ;; esac # 2. zombie — no memory
    # 3. env hard gate (fail-closed + visible ⚠️)
    if ! env_has_pair "$PID"; then
        echo "⚠️ env unreadable/absent for pid $PID — skipped, cannot classify (${CMD:0:60})"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    # ORPHAN_WATCHDOG=0 valve parity with the watchdog
    if ps eww -p "$PID" 2>/dev/null | tail -n +2 | grep -qx 'ORPHAN_WATCHDOG=0'; then
        echo "⚠️ pid $PID skipped — ORPHAN_WATCHDOG=0 (opt-out valve)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    # 4. age gate (etime; 0 disables)
    if [ "$CUTOFF_HOURS" -gt 0 ]; then
        AGE_S="$(etime_to_seconds "$ETIME")"
        [ "$AGE_S" -ge "$CUTOFF_SECONDS" ] || continue
    fi
    # 5. own-pgid REFUSED — never signal the orchestrator's group
    [ "$PGID" = "$OWN_PGID" ] && [ -n "$OWN_PGID" ] && [ "$OWN_PGID" != "0" ] && continue

    ORPHANS=$((ORPHANS + 1))
    CWD=""
    if command -v lsof >/dev/null 2>&1; then
        CWD="$(lsof -a -p "$PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
    fi
    echo "🧹 ORPHAN: pid=$PID pgid=$PGID elapsed=$ETIME ppid=$PARENT_PID argv=${CMD:0:100}${CWD:+ cwd=$CWD}"
    [ "$ORPHANS" -gt 20 ] && { echo "⚠️ sweep capped at 20 flagged orphans — re-run for more"; break; }

    # ── --apply: settle re-verify + kill ────────────────────────
    if [ "$APPLY" = true ]; then
        # settle re-verify: pid-recycling insurance — ppid AND env must still
        # hold immediately before the kill; failure → skip, never kill blind.
        CUR_PARENT_PID="$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ' || echo '')"
        [ "$CUR_PARENT_PID" = "1" ] || { echo "⚠️ pid $PID no longer ppid==1 — skipped (recycled?)"; continue; }
        env_has_pair "$PID" || { echo "⚠️ pid $PID env no longer carries the pair — skipped"; continue; }

        if [ "$PGID" = "$PID" ]; then
            # detached/leader — the group is the orphan + its descendants
            kill -TERM -- "-$PGID" 2>/dev/null || true
            sleep 3
            kill -KILL -- "-$PGID" 2>/dev/null || true
            echo "    killed group $PGID (TERM→KILL)"
        else
            # shared session group — per-pid only, NEVER a group signal
            kill -TERM "$PID" 2>/dev/null || true
            sleep 3
            kill -KILL "$PID" 2>/dev/null || true
            echo "    killed pid $PID per-pid (shared group $PGID untouched)"
        fi
    fi
done < <(ps axww -o pid=,ppid=,pgid=,stat=,etime=,command= 2>/dev/null)

# ── Summary ────────────────────────────────────────────────────
echo "── Summary ──"
echo "  Orphans flagged: $ORPHANS | Skipped (unclassifiable): $SKIPPED"
if [ "$APPLY" = false ]; then
    echo "  DRY-RUN: nothing killed (re-run with --apply to kill confirmed orphans)"
fi
if [ "$ORPHANS" -eq 0 ]; then
    echo "  No orphaned dispatch processes found"
fi
exit 0
