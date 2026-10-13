#!/bin/bash
# cloud-cell-supervisor.sh — run the orchestrator harness on a Linux cloud cell.
#
# The harness's macOS-specific parts are (a) how the CONTROLLER is started — install.sh
# renders a launchd plist — and (b) three OS primitives inside orch-loop.sh (stat -f, sysctl
# vm.loadavg, sysctl vm.swapusage) that are BSD-only. The lanes themselves were never
# launchd's: orch-loop.sh spawns them with `tmux new-session`, and tmux is on the devbox
# already. So a Linux cell needs this supervisor for (a), plus the portable-primitive fix
# tracked by agent-infra#1702 for (b). Until #1702 lands the cell controller aborts on its
# first cycle once a worker log exists, and the load/swap gates never bind — treat a cell as
# a MERGE ACTOR with incomplete back-pressure, not as a full peer of the laptop.
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
# $REPO/operations/orchestrator-harness path becomes a stub pointer in a follow-up tortoise PR
# (agent-infra#1700 / tortoise#8432), so it is no longer a valid default here. An unresolvable
# path fails loudly in cmd_check, never silently.
HARNESS="${HARNESS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/orchestrator-harness" 2>/dev/null && pwd)}"
SESSION="${SESSION:-orch}"
LOCK="$O/.orch.lock"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

export HOME="$CELL_HOME"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

# SCOPE (see orch-loop.sh): UNSET -> auto; anything SET, including a set-but-EMPTY value, is
# validated in cmd_start and forwarded verbatim. Presence, not emptiness — `${SCOPE:-auto}` here
# would coerce a blank keys.env entry to auto and evaporate the pin this override exists for.
[ -z "${SCOPE+x}" ] && SCOPE=auto

# ── check: can this cell actually run a controller? ─────────────────────────────
cmd_check() {
  [ -d "$CELL_HOME" ] && [ -w "$CELL_HOME" ] || die "HOME=$CELL_HOME missing or not writable"
  [ -d "$HARNESS" ] || die "harness not found at $HARNESS (clone the repo first)"
  [ -f "$HARNESS/orch-loop.sh" ] || die "$HARNESS/orch-loop.sh missing"
  command -v tmux >/dev/null 2>&1 || die "tmux missing (the lanes depend on it)"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run cloud-cell-bringup.sh --check"
  [ -d "$REPO/.git" ] || die "no git repo at $REPO"
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  # orch-loop.sh spawns its workers as `bash '$O/<script>'` (fix-one.sh, merge-one.sh, …), NOT
  # from $HARNESS. cmd_start seeds $O from $HARNESS; assert it, so a stale/empty $O is a loud
  # failure rather than a controller that runs the inline sweep but can never review, fix or
  # dispatch — a false "CELL CAN RUN A CONTROLLER".
  say "ok: HOME, harness, tmux, gh auth, repo, state dir"
  local missing="" w
  for w in orch-loop.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
    [ -f "$O/$w" ] || missing="$missing $w"
  done
  [ -z "$missing" ] || die "worker scripts missing from $O:$missing — run 'start' (it seeds $O) or: cp '$HARNESS'/*.sh '$O'/"

  if [ -n "${AI_REVIEW_GATE_KEY:-}" ] || [ -s "$HOME/.pi/agent/.ai-review-gate-key" ]; then
    say "ok: merge authority key present"
  else
    say "warn: no AI_REVIEW_GATE_KEY and no ~/.pi/agent/.ai-review-gate-key."
    say "      ⛔ This does NOT make the cell safe to co-run: absence of the key does not stop"
    say '         `gh pr merge --auto` (measured: it armed auto-merge on #8425/#8420). A started'
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
  # Refuse a bad SCOPE before anything starts or is written: a typo, or a set-but-BLANK keys.env
  # entry, must not silently become `auto` (the default above applies only when SCOPE is UNSET).
  case "$SCOPE" in
    auto|own|broad) ;;
    *) die "SCOPE must be auto|own|broad (got '$SCOPE')" ;;
  esac
  # Guard BEFORE seeding. $O is the controller's working copy and `start` on a live cell would
  # otherwise replace the worker scripts its next spawn executes (and race a half-copied script).
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "already running (tmux session '$SESSION') — use: status | logs | stop"
    return 0
  fi
  # Seed the running copy: orch-loop.sh spawns its workers from $O, not from $HARNESS, so a
  # cell whose $O is empty runs the inline sweep but can never review, fix or dispatch.
  # Idempotent; mirrors install.sh's deploy step. cmd_check below then asserts the seed landed.
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  cp -p "$HARNESS"/*.sh "$O/" || die "cannot seed \$O from $HARNESS"
  cmd_check >/dev/null || exit 1
  # The harness's own single-instance lock is per-cell ($O/.orch.lock), so this tmux guard
  # is what stops two controllers on THIS cell; cross-cell duplication is a separate
  # problem (#5052) and is NOT solved here.
  # ⛔ The tmux SERVER supplies a new session's environment, not this shell: once a server exists
  # (normal after `stop`, or while lanes run) an exported HOME/key/tunable is silently dropped —
  # measured for SCOPE, and the same mechanism applies to every other variable (a rotated
  # key in $ENV_FILE would be ignored, and a pinned MAX_LANES would revert to its default). So the
  # session re-sources $ENV_FILE itself and the values below are set inside the session, AFTER it.
  # Put any other tunable in $ENV_FILE rather than exporting it in an operator shell.
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "set -a; . '$ENV_FILE' 2>/dev/null; set +a; HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='${OR:-daniel-ospina/tortoise}' SCOPE='$SCOPE' bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
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
  say "lanes: $(tmux ls 2>/dev/null | grep -c '^lane-')"
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
