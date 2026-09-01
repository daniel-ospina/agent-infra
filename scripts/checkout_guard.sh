#!/usr/bin/env bash
# checkout_guard.sh — pre-launch guard: defer daemon agents that would collide
# with active interactive sessions or branch state in shared checkouts.
#
# Researched and designed per: agent-infra/docs/research/2026-08-07-multi-agent-git-coordination.md
# GitHub issue: daniel-ospina/swarm#70
#
# CHECKS:
#   1. git worktree list --porcelain  → non-main branches checked out?
#   2. git symbolic-ref --short HEAD   → main checkout HEAD ≠ main?
#   3. git diff-index --quiet HEAD     → main checkout dirty?
#   4. agent_events.jsonl              → recent (<5 min) claim/start_work events?
#   5. git rev-list --count HEAD..origin/main → checkout behind origin/main?
#      (stale base — swarm #4905; this guard is the single owner of the
#      start-time stale verdict; parallel_work_check.sh C1 delegates here)
#
# VERDICT OUTPUT (stdout, machine-parseable — one line, always emitted):
#   checkout-guard VERDICT: CLEAR  checkout up-to-date
#   checkout-guard VERDICT: STALE behind origin/main (HEAD..origin/main > 0)
#   checkout-guard VERDICT: DEFER  checkout collision detected
# Consumers grep stdout for '^checkout-guard VERDICT: (STALE|CLEAR|DEFER)'.
#
# SAFETY INVARIANT: this guard is detection-only. It NEVER modifies a working
# tree — no fetch, reset, clean, checkout, or stash. A dirty + behind checkout
# is reported (DEFER/STALE) and left fully intact (data-loss safety, #4905).
#
# ENV VARS:
#   CHECKOUT_GUARD_ENFORCE=1   — actually defer on collision (default: dry-run, log only)
#   CHECKOUT_GUARD_REPOS       — space-separated repo paths (default: the swarm repo root)
#   CHECKOUT_GUARD_SWARM_ROOT  — resolved swarm repo root for per-repo policy
#                                (default: the script's own repo root, ../.. of
#                                operations/coordination; override for worktree installs)
#   HEARTBEAT_EVENTS_FILE      — path to agent_events.jsonl (default: heartbeats/agent_events.jsonl)
#   CHECKOUT_GUARD_LOG         — log file path (default: heartbeats/checkout_guard.log)
#   CHECKOUT_GUARD_GRACE_SECS  — heartbeat recency threshold in seconds (default: 300)
#
# USAGE:
#   source operations/coordination/checkout_guard.sh
#   if checkout_guard_check; then
#       echo "Safe to proceed"
#   else
#       echo "Deferred — active session collision detected"
#       exit 0
#   fi
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"

# Resolve guard script directory (works whether sourced or executed)
CHECKOUT_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── Default configuration ────────────────────────────────────
CHECKOUT_GUARD_REPOS="${CHECKOUT_GUARD_REPOS:-$(cd "$CHECKOUT_GUARD_DIR/../.." && pwd)}"
CHECKOUT_GUARD_SWARM_ROOT="${CHECKOUT_GUARD_SWARM_ROOT:-$(cd "$CHECKOUT_GUARD_DIR/../.." && pwd -P)}"
HEARTBEAT_EVENTS_FILE="${HEARTBEAT_EVENTS_FILE:-$CHECKOUT_GUARD_DIR/heartbeats/agent_events.jsonl}"
CHECKOUT_GUARD_LOG="${CHECKOUT_GUARD_LOG:-$CHECKOUT_GUARD_DIR/heartbeats/checkout_guard.log}"
CHECKOUT_GUARD_GRACE_SECS="${CHECKOUT_GUARD_GRACE_SECS:-300}"
# Epic #5260: the cycle-start guard runs INSIDE the daemon, which writes the
# event stream itself — checking events there would self-DEFER every cycle.
# Cron wrappers (the original consumers) set CHECKOUT_GUARD_CHECK_EVENTS=1.
CHECKOUT_GUARD_CHECK_EVENTS="${CHECKOUT_GUARD_CHECK_EVENTS:-0}"

_guard_log() {
    local level="$1"
    local msg="$2"
    mkdir -p "$(dirname "$CHECKOUT_GUARD_LOG")" 2>/dev/null || true
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[$ts] checkout-guard $level: $msg" | tee -a "$CHECKOUT_GUARD_LOG" >&2
}

# ── Git worktree checks ──────────────────────────────────────

# _guard_is_swarm_root <repo_path>
# 0 if <repo_path> resolves to the swarm repo root (per-repo policy, epic #5260
# WF-4), 1 otherwise (foreign checkout). Compares resolved physical paths so
# symlinked / worktree installs match their canonical swarm root.
_guard_is_swarm_root() {
    local repo="$1"
    local resolved_repo resolved_swarm
    resolved_repo="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
    resolved_swarm="$(cd "$CHECKOUT_GUARD_SWARM_ROOT" 2>/dev/null && pwd -P)" || return 1
    [ "$resolved_repo" = "$resolved_swarm" ]
}

# _guard_check_worktree <repo_path>
# Returns 1 (collision). Per-repo policy (epic #5260 WF-4): the main-branch
# HEAD + worktree-branch checks apply ONLY to the swarm repo root; every repo
# (swarm or foreign) gets the dirty-worktree check.
_guard_check_worktree() {
    local repo="$1"
    [ -e "$repo/.git" ] || return 0  # repo doesn't exist — safe (.git is a FILE in worktrees)

    # Main-branch / worktree-branch checks are swarm-root-only. A foreign
    # checkout (e.g. a tortoise PR branch like pr-994) must never be DEFERed
    # just because its HEAD is not `main`.
    if _guard_is_swarm_root "$repo"; then
        local main_branch
        main_branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "")

        # Check if main checkout HEAD is not 'main' (someone working there)
        if [ -n "$main_branch" ] && [ "$main_branch" != "main" ]; then
            _guard_log "DEFER" "repo=$repo main checkout is on '$main_branch' (not main)"
            return 1
        fi

        # Check worktree list for non-main branches
        local worktree_branches
        worktree_branches=$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^branch ' | sed 's/^branch refs\/heads\///' | sort -u || echo "")
        if [ -n "$worktree_branches" ]; then
            local non_main
            non_main=$(echo "$worktree_branches" | grep -v '^main$' || echo "")
            if [ -n "$non_main" ]; then
                _guard_log "DEFER" "repo=$repo active worktree branches: $(echo "$non_main" | tr '\n' ' ' | sed 's/ $//')"
                return 1
            fi
        fi
    fi

    # Dirty-worktree check applies to ALL repos (swarm + foreign).
    if ! git -C "$repo" diff-index --quiet HEAD -- 2>/dev/null; then
        _guard_log "DEFER" "repo=$repo checkout has uncommitted changes"
        return 1
    fi

    return 0
}

# ── Stale-base check (behind origin/main) ─────────────────────

# _guard_check_stale_base <repo>
# Returns 1 (stale) if the checkout is behind origin/main, i.e.
# `git rev-list --count HEAD..origin/main` > 0 (origin has commits HEAD lacks).
#
# Detection-only (swarm #4905): never resets/cleans — a dirty tree is
# reported and preserved as-is. Fails open (return 0) when the behind-count
# is undeterminable (no origin/main ref) so a missing ref never wedges agents.
_guard_check_stale_base() {
    local repo="$1"
    [ -e "$repo/.git" ] || return 0  # repo doesn't exist — safe (.git is a FILE in worktrees)

    # Behind-origin check is swarm-root-only (epic #5260 WF-4). A foreign
    # checkout on a PR branch is legitimately behind origin/main — a normal PR
    # state, not a stale base — and must never spurious-DEFER.
    if ! _guard_is_swarm_root "$repo"; then
        return 0
    fi

    local behind
    behind=$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null || echo "")
    if [ -z "$behind" ]; then
        _guard_log "WARN" "repo=$repo behind-count undeterminable (origin/main ref missing) — skipping stale-base check"
        return 0
    fi
    if [ "$behind" -gt 0 ] 2>/dev/null; then
        _guard_log "STALE" "repo=$repo checkout is $behind commit(s) behind origin/main — stale base (working tree untouched)"
        return 1
    fi
    return 0
}

# ── Heartbeat event checks ────────────────────────────────────

# _guard_check_foreign_activity <repo_path>
# 1 (collision) if the FOREIGN checkout has commits newer than the grace
# window — a live agent (e.g. the tortoise pi workflow) actively committing.
# Per-checkout signal for E2E-6's active-agent case (the global swarm event
# stream cannot see foreign sessions).
_guard_check_foreign_activity() {
    local repo="$1"
    local recent
    recent=$(git -C "$repo" log --since="$CHECKOUT_GUARD_GRACE_SECS seconds ago" --oneline 2>/dev/null | head -1)
    if [ -n "$recent" ]; then
        _guard_log "DEFER" "repo=$repo active foreign checkout (recent commits: $recent)"
        return 1
    fi
    return 0
}

# _guard_check_heartbeats
# Returns 1 (collision) if a recent claim/start_work event exists in the event log.
_guard_check_heartbeats() {
    [ -f "$HEARTBEAT_EVENTS_FILE" ] || return 0

    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - CHECKOUT_GUARD_GRACE_SECS))

    export HEARTBEAT_EVENTS_FILE CUTOFF_EPOCH="$cutoff_epoch"

    local recent
    recent=$("$PYTHON_BIN" -c "
import json, os, sys
events_file = os.environ.get('HEARTBEAT_EVENTS_FILE', '')
cutoff = int(os.environ.get('CUTOFF_EPOCH', '0'))
if not events_file or not os.path.exists(events_file):
    sys.exit(0)
try:
    with open(events_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
                event = evt.get('event', '')
                # Any recent lifecycle event = agent activity (events.py writes
                # 'claimed' | 'phase_changed' | 'completed' | 'tool_call').
                # Previously matched only 'claim'/'start_work' — never matched.
                # Time: events.py writes 'iso' (ISO string) + 'ts' (float epoch);
                # parse the ISO field (fromisoformat on the float raises).
                iso = evt.get('iso', '')
                if iso and event:
                    from datetime import datetime
                    dt = datetime.fromisoformat(iso)
                    epoch = dt.timestamp()
                    if epoch >= cutoff:
                        print(json.dumps({'agent': evt.get('agent','?'),
                                          'event': event,
                                          'card_id': evt.get('card_id',''),
                                          'role': evt.get('role',''),
                                          'ts': iso}))
                        sys.exit(0)
            except (json.JSONDecodeError, ValueError, KeyError):
                continue
except Exception as e:
    # Fail closed on I/O errors — can't verify safety, assume collision
    print(json.dumps({'error': 'heartbeat_read_failed', 'detail': str(e)[:200]}))
    sys.exit(1)
sys.exit(0)
" 2>/dev/null || echo "")

    if [ -n "$recent" ]; then
        _guard_log "DEFER" "recent agent activity: $recent"
        return 1
    fi

    return 0
}

# ── Main guard function ──────────────────────────────────────

# checkout_guard_check [repo_override]
# Checks all repos in CHECKOUT_GUARD_REPOS (or a single override).
# Returns 0 if safe to proceed, 1 if collision detected (and enforce mode is on).
#
# In dry-run mode (default): logs DEFER but returns 0 (proceed anyway).
# In enforce mode (CHECKOUT_GUARD_ENFORCE=1): logs DEFER and returns 1.
checkout_guard_check() {
    local repo_override="${1:-}"
    local enforce="${CHECKOUT_GUARD_ENFORCE:-0}"
    local had_collision=0
    local had_stale=0

    # Determine which repos to check (safe split — no glob expansion)
    local repo_arr
    if [ -n "$repo_override" ]; then
        repo_arr=("$repo_override")
    else
        IFS=' ' read -ra repo_arr <<< "$CHECKOUT_GUARD_REPOS"
    fi

    # Check each repo's worktree state and staleness (behind origin/main)
    for repo in "${repo_arr[@]}"; do
        [ -z "$repo" ] && continue
        if ! _guard_check_worktree "$repo"; then
            had_collision=1
        fi
        if ! _guard_check_stale_base "$repo"; then
            had_collision=1
            had_stale=1
        fi
    done

    # Check heartbeat events (opt-in: cron path only, epic #5260 — the daemon
    # writes its own event stream and would self-DEFER; cron wrappers set
    # CHECKOUT_GUARD_CHECK_EVENTS=1 to preserve the original semantics)
    if [ "${CHECKOUT_GUARD_CHECK_EVENTS:-0}" = "1" ] && ! _guard_check_heartbeats; then
        had_collision=1
    fi

    # Foreign-checkout activity (epic #5260 WF-4): non-swarm checkouts only —
    # recent commits mean an agent is actively working there.
    for repo in "${repo_arr[@]}"; do
        [ -z "$repo" ] && continue
        if _guard_is_swarm_root "$repo"; then
            continue
        fi
        if ! _guard_check_foreign_activity "$repo"; then
            had_collision=1
        fi
    done

    # ── Machine-parseable verdict on stdout ────────────────────
    # Always exactly one verdict line; parallel_work_check.sh C1 (swarm #4904)
    # delegates the start-time stale verdict here and greps this output.
    # STALE reports only the behind-origin condition; other collisions DEFER.
    if [ "$had_stale" -eq 1 ]; then
        echo "checkout-guard VERDICT: STALE behind origin/main (HEAD..origin/main > 0)"
    elif [ "$had_collision" -eq 1 ]; then
        echo "checkout-guard VERDICT: DEFER checkout collision detected"
    else
        echo "checkout-guard VERDICT: CLEAR checkout up-to-date"
    fi

    if [ "$had_collision" -eq 1 ]; then
        if [ "$enforce" = "1" ]; then
            _guard_log "SKIP" "collision detected — deferring agent launch (enforce mode)"
            return 1
        else
            if [ "$had_stale" -eq 1 ]; then
                _guard_log "WARN" "stale base detected — dry-run (CHECKOUT_GUARD_ENFORCE=0): NOT deferring, working tree untouched (never reset/clean)"
            fi
            _guard_log "DRY-RUN" "collision detected but dry-run — proceeding (set CHECKOUT_GUARD_ENFORCE=1 to enforce)"
            return 0
        fi
    fi

    _guard_log "OK" "no collision detected — safe to launch"
    return 0
}
