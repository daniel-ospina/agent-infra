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
# OR is interpolated into the session command string, so it is defaulted here — the guard below reads
# it with `${!v}` under `set -u`, which errors on an unset name, and the string must not depend on
# the guard running first. `${OR:-…}` keeps today's default. (The merge key is NOT interpolated — a
# secret in an argv string is visible to ps/tmux; see the session command below.)
OR="${OR:-daniel-ospina/tortoise}"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

# A quote or shell metacharacter in any value interpolated into the session command string would
# break out of it — the string is handed to tmux, which runs it with sh -c. The harness applies
# exactly this guard to $O before every spawn; apply it here to EVERY interpolated value, so the
# supervisor cannot be the weak link. (Same class as orch-loop.sh:39-41 and install.sh:65-67.)
safe_argv() {
  case "${1:-}" in
    ''|*"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) return 1 ;;
  esac
  return 0
}

# The key FILE is authoritative (install.sh treats it so) — but test its CONTENT, not its size:
# record-review.sh strips whitespace and treats an empty result as absent, so a 1-byte newline file
# (exactly what `echo "$KEY" > file` writes for an unset var) would be blessed and then fail the
# gate. Same class as the empty keys.env assignment the ENV_FILE branch rejects.
# ⛔ Read $CELL_HOME, NOT $HOME: keys.env is sourced above and may set HOME, while the session
# forces HOME back to $CELL_HOME AFTER that source — so the verdict would inspect a home the
# session will never use (false present, or false absent, either way).
keyfile_has_key() {
  local kf="$CELL_HOME/.pi/agent/.ai-review-gate-key"
  [ -s "$kf" ] || return 1
  # `2>/dev/null` FIRST: redirections apply left to right, so with the input redirect first an
  # existing-but-UNREADABLE key file (chmod 000) failed at the shell's own open and printed
  # "Permission denied" to the shell's stderr — the verdict the preflight exists to deliver then
  # arrived under a raw bash error. Swapping the order is what actually suppresses it; `2>/dev/null`
  # after the `<` does not.
  [ -n "$(tr -d '[:space:]' 2>/dev/null < "$kf")" ]
}

# LOCK is recomputed AFTER $ENV_FILE is sourced (below): keys.env may set $O, and a lock derived
# from a stale $O makes `stop` release and announce the wrong path.
export HOME="$CELL_HOME"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
# ⛔ Re-assert HOME AFTER the source: keys.env may carry a HOME= line, and everything BELOW here —
# the gh-credential lookup in cmd_check (gh reads $HOME/.config/gh), and the session itself, which
# forces HOME=$CELL_HOME — must run under the cell's home. Sourcing first left cmd_check validating
# a home the session never uses: with credentials in the repointed home the preflight said "ok:
# gh auth" and the cell started, and then every gh call in the session failed.
export HOME="$CELL_HOME"
LOCK="$O/.orch.lock"
# Does the ENV FILE itself carry a NON-EMPTY merge key? cmd_check must judge what the SESSION will
# see, not what this shell holds: the session re-sources $ENV_FILE (so a keys.env key reaches it)
# while an ambient-only export does not (tmux serves a session from the server's environment).
# ⛔ Compute SET *inside* the subshell, never from the captured string: `$( )` strips trailing
# newlines, so a value of exactly "\n" would capture as EMPTY and be read as "no env value" —
# while the consumer's own raw test (`[ -z "$GATE_KEY"`) sees a non-empty value, takes the env
# branch, and never falls back to the file. That divergence blessed a keyless cell. The value is
# captured only for the NORMALIZED test, which does not care about its trailing newlines.
KEY_IN_FILE_RAW=""
KEY_IN_FILE_SET=0
if [ -f "$ENV_FILE" ]; then
  env -u AI_REVIEW_GATE_KEY bash -c 'set -a; . "$1" >/dev/null 2>&1; [ -n "${AI_REVIEW_GATE_KEY:-}" ]' _ "$ENV_FILE" 2>/dev/null && KEY_IN_FILE_SET=1
  KEY_IN_FILE_RAW="$(env -u AI_REVIEW_GATE_KEY bash -c 'set -a; . "$1" >/dev/null 2>&1; printf %s "${AI_REVIEW_GATE_KEY:-}"' _ "$ENV_FILE" 2>/dev/null || true)"
fi
KEY_IN_FILE="$(printf '%s' "$KEY_IN_FILE_RAW" | tr -d '[:space:]')"
# Raw-non-empty means the consumer takes the ENV value and never falls back to the key FILE (its
# fallback is `[ -z "$GATE_KEY" ]` on the raw value). If that value normalizes to empty, the file
# check is SHADOWED — so this state must be judged absent-and-dead, never present.

# SCOPE (see orch-loop.sh): UNSET -> auto; anything SET, including a set-but-EMPTY value, is
# validated by validate_scope() and forwarded verbatim. Presence, not emptiness — `${SCOPE:-auto}`
# here would coerce a blank keys.env entry to auto and evaporate the pin this override exists for.
[ -z "${SCOPE+x}" ] && SCOPE=auto

# Refuse a bad SCOPE wherever the cell is judged or started. `check` MUST run this too: its verdict is
# "CELL CAN RUN A CONTROLLER", and a cell whose preflight says YES while its `start` dies on the same
# config is a FALSE PASS on exactly the question that verdict answers. A typo, or a set-but-BLANK
# keys.env entry, must not silently become `auto` (the default applies only when SCOPE is UNSET).
validate_scope() {
  case "$SCOPE" in
    auto|own|broad) ;;
    *) die "SCOPE must be auto|own|broad (got '$SCOPE')" ;;
  esac
}

# ── check: can this cell actually run a controller? ─────────────────────────────
cmd_check() {
  validate_scope
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

  # Judge the key by what the SESSION will receive, not by what this shell happens to hold: the key
  # FILE is authoritative, and a key in $ENV_FILE reaches the session because the session re-sources
  # it. An ambient-only export does NOT — tmux serves a new session from the server's environment —
  # so it is named rather than silently counted as present.
  # ⛔ ORDER MATTERS. The consumer is env-FIRST: it takes $ENV_FILE's value when non-empty and only
  # then falls back to the key file. A whitespace-only value in keys.env therefore SHADOWS a valid
  # key file (the raw value is non-empty, so the fallback never runs, and the normalized value is
  # empty) — so that case must be checked BEFORE the file, and reported as a failure, not a "present".
  if [ -n "$KEY_IN_FILE" ]; then
    say "ok: merge authority key present in $ENV_FILE (the session re-sources it)"
  elif [ "$KEY_IN_FILE_SET" = 1 ]; then
    say "warn: AI_REVIEW_GATE_KEY in $ENV_FILE is WHITESPACE-ONLY. The consumer strips whitespace,"
    say "      so it resolves to EMPTY — and because the env value wins, it will NOT fall back to"
    say "      $CELL_HOME/.pi/agent/.ai-review-gate-key. Every review would be recorded UNSIGNED."
    say "      Fix: remove the key line from $ENV_FILE, or give it a real value."
  elif keyfile_has_key; then
    say "ok: merge authority key present ($CELL_HOME/.pi/agent/.ai-review-gate-key)"
  else
    if [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
      say "warn: AI_REVIEW_GATE_KEY is set in THIS shell but not in $ENV_FILE — the controller"
      say "      session will NOT receive it (tmux serves a new session the SERVER's environment)."
      say "      Write it to $ENV_FILE, or to $CELL_HOME/.pi/agent/.ai-review-gate-key."
    else
      say "warn: no AI_REVIEW_GATE_KEY and no $CELL_HOME/.pi/agent/.ai-review-gate-key."
    fi
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
  # Refuse a bad SCOPE before anything starts or is written (validate_scope is also the first thing
  # cmd_check does below — this call is what keeps the refusal ahead of the $O seed).
  validate_scope
  # Guard BEFORE seeding. $O is the controller's working copy and `start` on a live cell would
  # otherwise replace the worker scripts its next spawn executes (and race a half-copied script).
  # Nothing is started or written on this path, so a bad value below cannot hurt it.
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    say "already running (tmux session '$SESSION') — use: status | logs | stop"
    return 0
  fi
  # Every value below is interpolated into the session command string, so every one must be
  # metacharacter-free — refuse loudly here rather than let tmux's sh -c parse it. Empty values
  # are skipped (cmd_check reports an unresolvable HARNESS with its own message).
  local v
  for v in O REPO CELL_HOME ENV_FILE HARNESS OR; do
    [ -n "${!v}" ] || continue
    safe_argv "${!v}" || die "\$$v must not contain a quote or shell metacharacter: ${!v}"
  done
  # Seed the running copy: orch-loop.sh spawns its workers from $O, not from $HARNESS, so a
  # cell whose $O is empty runs the inline sweep but can never review, fix or dispatch.
  # Idempotent; mirrors install.sh's deploy step. cmd_check below then asserts the seed landed.
  mkdir -p "$O/logs" "$O/state" || die "cannot create state dir $O"
  cp -p "$HARNESS"/*.sh "$O/" || die "cannot seed \$O from $HARNESS"
  # The key verdict must NOT be swallowed on the only path that starts a cell: an operator who
  # exported the key ambiently (or left an empty assignment in keys.env) would otherwise get a
  # keyless cell with no signal. Run the check once, fail loudly, and surface its output on stderr.
  local chk
  if ! chk="$(cmd_check 2>&1)"; then printf '%s\n' "$chk" >&2; exit 1; fi
  # ⛔ Print the WHOLE verdict — do NOT filter it by matching the verdict prose. Line-matching was
  # tried and failed three times: each verdict is several lines, and any pattern keyed on the first
  # line silently drops the continuation — the remedy ("Fix: remove the key line…") and the warning
  # that a keyless cell is still a MERGE ACTOR. The block is printed verbatim; `die` already does the
  # same on the failure path.
  printf '%s\n' "$chk" >&2
  # The harness's own single-instance lock is per-cell ($O/.orch.lock), so this tmux guard
  # is what stops two controllers on THIS cell; cross-cell duplication is a separate
  # problem (#5052) and is NOT solved here.
  # ⛔ The tmux SERVER supplies a new session's environment, not this shell: once a server exists
  # (normal after `stop`, or while lanes run) an exported HOME/key/tunable is silently dropped —
  # measured for SCOPE, and the same mechanism applies to every other variable (a rotated
  # key in $ENV_FILE would be ignored, and a pinned MAX_LANES would revert to its default). So the
  # session re-sources $ENV_FILE itself and the values below are set inside the session, AFTER it.
  # The merge key is NOT passed on this command line: a secret in an argv string is visible to
  # `ps`/tmux, and it would have to be interpolated unguarded. It reaches the session through
  # $ENV_FILE instead — which is why cmd_check judges the key by the file, not by this shell's env.
  # Put any other tunable in $ENV_FILE rather than exporting it in an operator shell.
  tmux new-session -d -s "$SESSION" -c "$HARNESS" \
    "set -a; . '$ENV_FILE' 2>/dev/null; set +a; HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' bash '$HARNESS/orch-loop.sh' 2>&1 | tee -a '$O/logs/controller.log'"
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
