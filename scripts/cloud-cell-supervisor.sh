#!/bin/bash
# cloud-cell-supervisor.sh — run the orchestrator harness on a Linux cloud cell.
#
# The harness's ONLY macOS-specific part is how the CONTROLLER is started: install.sh
# renders a launchd plist. The lanes were never launchd's — orch-loop.sh spawns them with
# `tmux new-session`, and tmux is on the devbox already. So a Linux cell needs one
# substitution: launchd → tmux for the controller, and nothing else.
#
# Runs ON THE CELL (Linux). Usage:
#   bash cloud-cell-supervisor.sh start|stop|status|logs|check
#
# Prereqs on the cell (see cloud-cell-bringup.sh --check):
#   HOME writable · repo cloned · gh authenticated with push · provider key valid
#   + the merge authority key (AI_REVIEW_GATE_KEY) if this cell is to MERGE.
#
# ⛔ MEASURED 2026-10-13 — A CELL WITHOUT THE MERGE KEY IS **NOT** MERGE-INERT.
# An earlier draft of this file claimed a keyless cell was a safe "producer cell"
# that "will refuse every merge". That is FALSE, and the first run disproved it:
# within ~25s the controller armed AUTO-MERGE on #8425 and #8420 (`gh pr merge --auto`),
# which does NOT go through the gate key. So removing the key does not confine a cell
# to producing — it can still cause merges. Treat every started cell as a MERGE ACTOR.

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
REPO="${REPO:-/tmp/cell}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
# The harness is a SIBLING of this script inside agent-infra (scripts/orchestrator-harness/),
# not inside the target repo ($REPO) — resolve it from this script's own location, and let an
# explicit HARNESS override win. It moved out of tortoise's operations/ on 2026-10-13; the old
# $REPO/operations/orchestrator-harness path is now only a stub pointer, so it is no longer a
# valid default here. An unresolvable path fails loudly in cmd_check, never silently.
HARNESS="${HARNESS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/orchestrator-harness" 2>/dev/null && pwd)}"
SESSION="${SESSION:-orch}"
LOCK="$O/.orch.lock"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

export HOME="$CELL_HOME"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

# ── check: can this cell actually run a controller? ─────────────────────────────
cmd_check() {
  [ -d "$CELL_HOME" ] && [ -w "$CELL_HOME" ] || die "HOME=$CELL_HOME missing or not writable"
  [ -d "$HARNESS" ] || die "harness not found at $HARNESS (clone the repo first)"
  [ -f "$HARNESS/orch-loop.sh" ] || die "$HARNESS/orch-loop.sh missing"
  command -v tmux >/dev/null 2>&1 || die "tmux missing (the lanes depend on it)"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run cloud-cell-bringup.sh --check"
  [ -d "$REPO/.git" ] || die "no git repo at $REPO"
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  say "ok: HOME, harness, tmux, gh auth, repo, state dir"

  if [ -n "${AI_REVIEW_GATE_KEY:-}" ] || [ -s "$HOME/.config/ai-review-gate/key" ]; then
    say "ok: merge authority key present"
  else
    say "warn: no AI_REVIEW_GATE_KEY."
    say "      ⛔ This does NOT make the cell safe to co-run: absence of the key does not stop"
    say "         `gh pr merge --auto` (measured: it armed auto-merge on #8425/#8420). A started"
    say "         cell is a MERGE ACTOR regardless of the key."
  fi
  say "⛔ COLLISION: orch-loop.sh takes BROAD scope above 10 open PRs, so an UNPINNED cell drains"
  say "   the SHARED queue. Measured 2026-10-13: a fresh cell logged '[scope] open=14 -> BROAD' and"
  say "   began re-recording/auto-arming within ~25s. Fix: pin every cell but ONE with SCOPE=own"
  say "   (orch-loop.sh's SCOPE override), or fix #5052, BEFORE starting a second controller."
  say "   ⛔ The pin is a PARTITION, not a fix for the root: ownership is still inferred from LOCAL"
  say "      branches/worktrees (#4256), invisible across machines, so two OWN-pinned cells can still"
  say "      race the same PR."
  say "CELL CAN RUN A CONTROLLER"
}

# ── start: controller under tmux (the launchd substitution) ─────────────────────
cmd_start() {
  cmd_check >/dev/null || exit 1
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "already running (tmux session '$SESSION') — use: status | logs | stop"
    return 0
  fi
  # The harness's own single-instance lock is per-cell ($O/.orch.lock), so this tmux guard
  # is what stops two controllers on THIS cell; cross-cell duplication is a separate
  # problem (#5052) and is NOT solved here.
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "REPO='$REPO' O='$O' OR='${OR:-daniel-ospina/tortoise}' bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
  sleep 3
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "controller started (tmux '$SESSION'), state=$O"
  else
    die "controller exited immediately — read $O/logs/controller.log"
  fi
}

cmd_stop() {
  tmux has-session -t "$SESSION" 2>/dev/null || { say "not running"; return 0; }
  tmux kill-session -t "$SESSION" && say "controller stopped (tmux '$SESSION')"
  rm -f "$LOCK" && say "released lock $LOCK"
}

cmd_status() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then say "controller: RUNNING (tmux '$SESSION')"
  else say "controller: STOPPED"; fi
  say "state dir: $O"
  # the loop's own view of itself
  tail -3 "$O/logs/orch-loop.log" 2>/dev/null | sed 's/^/  /' || say "  (no orch-loop.log yet)"
  say "lanes: $(tmux ls 2>/dev/null | grep -c '^lane-' || echo 0)"
}

cmd_logs() { tail -30 "$O/logs/orch-loop.log" 2>/dev/null || say "no log yet at $O/logs/orch-loop.log"; }

case "${1:-status}" in
  check)  cmd_check ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  *)      say "usage: $0 check|start|stop|status|logs"; exit 2 ;;
esac
