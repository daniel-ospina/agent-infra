#!/usr/bin/env bash
# orphaned-harness.sh — READ-ONLY report of orphaned harness surfaces on a box (agent-infra#2867).
#
# WHY THIS EXISTS. The claim registry fences DISPATCH and (with claim_action_proof) ACTION, but
# neither NAMES the dead harness: the issue measured a box whose `merge-*` tmux sessions still
# named four PRs while running no agent at all, and whose systemd units were pinned to paths that
# no longer exist. This tool is the report half — on demand, for THIS box, list every surface
# whose pinned path is missing or whose lane is dead, WITH the PRs its name claims, so the finding
# is visible without waiting for an action to be refused.
#
# READ-ONLY. This script never stops a unit, never kills a session, never deletes anything, and
# never writes state (the only side effect is stdout). It reads `systemctl`, `tmux`, and `ps`.
# A missing `systemctl`/`tmux` is REPORTED as a coverage gap (that surface is UNREADABLE), never
# read as "nothing to report" — an absence this tool cannot see must not read as an absence of
# orphans.
#
# THE LANE-LIVENESS SPLIT, STATED. The harness lanes this report is about (`merge-*`, `fix-*`,
# `chain-*`) run `pi -p --no-session`, so they write no transcript and have no session id — the
# single verdict function (tools/fleet/liveness.py) cannot be fed them. Their "lane is dead" is
# therefore read from the ONE signal they do leave: the process tree. A session whose panes have
# NO live `pi` descendant (a bare bash wrapper, no agent) is a dead lane. Cmux-session liveness
# (transcript growth + pid) is covered by tools/fleet/lane_liveness.py, which feeds liveness.py —
# this script does NOT re-derive that verdict and does not form a second opinion.
#
# OUTPUT. One line per orphan, machine-readable:
#   orphan:kind=tmux name=<session> prs=<pr1,pr2|-> age_s=<n> reason=no-live-agent-child
#   orphan:kind=unit name=<unit> path=<path> prs=<-> reason=missing|non-durable
# Plus a header naming the host and the surfaces read. Exit 0 after reporting (even if nothing is
# orphaned); exit 2 when neither surface could be read at all.

set -u

# ── seams for the test harness (hermetic, no live systemctl/tmux/ps) ──
TMUX_BIN="${TMUX_BIN:-tmux}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
PS_BIN="${PS_BIN:-ps}"
# A non-durable ExecStart root is one of these prefixes (the #2697 class): a unit pinned to a
# lane worktree / scratch checkout — /tmp/wt-*, .worktrees/, /tmp/fix-*, /tmp/merge-*, /tmp/fence,
# /tmp/chain-* — whose entry point a lane end or a reaper can delete. A unit pinned to a durable
# install path (/usr/local/bin, the repo) is not flagged.
SCRATCH_ROOTS="${SCRATCH_ROOTS:-/tmp/wt- .worktrees/ /tmp/fix- /tmp/merge- /tmp/fence /tmp/chain-}"
# Only units whose name carries a harness prefix are judged; stock OS units (dbus, ssh, systemd-*)
# are out of scope and never read as orphans.
HARNESS_UNIT_PREFIXES="${HARNESS_UNIT_PREFIXES:-eldato- cell- pi- orchestrator harness-}"
# A session whose lane is dead is reported only past this age (seconds), so a freshly-spawned
# worker still launching its agent is not named. Default 600s = 10 min.
MIN_SESSION_AGE_S="${MIN_SESSION_AGE_S:-600}"

host() { printf '%s' "${CLAIM_OWNER_HOST:-$(hostname -s 2>/dev/null || echo box)}"; }

# pr_from_name <name> -> comma-separated PR numbers claimed by the name ("" when none).
# The harness session naming: merge-<PR>, fix-<PR>, chain-<N> (N is a PR on the merge chain).
pr_from_name() {
  local n="$1" pr=""
  pr="$(printf '%s' "$n" | sed -n 's/^\(merge\|fix\|chain\)-\([0-9][0-9]*\).*$/\2/p')"
  printf '%s' "$pr"
}

# live_pi_under <root-pid> -> 0 if a live `pi` process exists in the descendant tree, 1 otherwise.
# Bounded by the `seen` set (a process tree is acyclic; the guard is belt-and-braces). A `pi`
# process is one whose COMM is exactly `pi` (the harness lanes spawn `pi -p --no-session`).
live_pi_under() {
  local root="${1:-}" frontier seen pid child next
  [ -n "$root" ] || return 1
  frontier="$root"; seen=" "
  while [ -n "${frontier// /}" ]; do
    next=""
    for pid in $frontier; do
      case "$seen" in *" $pid "*) continue ;; esac
      seen="$seen$pid "
      if [ "$("$PS_BIN" -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')" = "pi" ]; then
        return 0
      fi
      child="$("$PS_BIN" -eo pid,ppid 2>/dev/null | awk -v p="$pid" '$2==p {print $1}' | tr '\n' ' ')"
      next="$next $child"
    done
    frontier="$next"
  done
  return 1
}

# session_age_s <name> -> seconds since the session was created ("" when unreadable).
session_age_s() {
  local created
  created="$("$TMUX_BIN" list-sessions -F '#{session_created}' -f "#{==:#{session_name},$1}" 2>/dev/null)"
  case "$created" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$(( $(date +%s) - created ))" ;;
  esac
}

# report_tmux — one orphan line per dead-lane session.
report_tmux() {
  local out name pr age rc
  out="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null)" || return 1
  while read -r name; do
    [ -n "$name" ] || continue
    pr="$(pr_from_name "$name")"
    age="$(session_age_s "$name")"
    # A dead lane: NO pane in this session has a live `pi` descendant.
    local pane_pids p dead=1
    pane_pids="$("$TMUX_BIN" list-panes -t "$name" -F '#{pane_pid}' 2>/dev/null)"
    for p in $pane_pids; do
      if live_pi_under "$p"; then dead=0; break; fi
    done
    if [ "$dead" -eq 1 ] && [ -n "$age" ] && [ "$age" -ge "${MIN_SESSION_AGE_S}" ]; then
      printf 'orphan:kind=tmux name=%s prs=%s age_s=%s reason=no-live-agent-child\n' \
        "$name" "${pr:--}" "$age"
    fi
  done <<< "$out"
}

# is_harness_unit <name> -> 0 when the unit name carries a harness prefix.
is_harness_unit() {
  local n="$1" p
  for p in ${HARNESS_UNIT_PREFIXES}; do
    case "$n" in "$p"*) return 0 ;; esac
  done
  return 1
}

# execstart_path <unit> -> the pinned script path ("" when not a bash/script entry point).
# Harness units take one of two ExecStart forms:
#   path=/bin/bash ; argv[]=/bin/bash /abs/script [args]        (bash-wrapped -> the 2nd argv)
#   path=/abs/script ; argv[]=/abs/script [args]                (direct script -> the path= value)
# A direct BINARY ExecStart (argv[]=/usr/bin/foo --flag) has no pinned script and is not judged.
execstart_path() {
  # ⛔ SPLIT DECLARATION, DELIBERATELY: `local v="$(…)"` DISCARDS the substitution's exit status, so a
  # FAILED `systemctl show` and an EMPTY ExecStart are indistinguishable — and every caller reads an
  # empty result as "no pinned script, not judgeable", i.e. a failed read silently EXONERATES every
  # unit on the box while the report still reads clean. Capture, check, then decide.
  local v p=""
  v="$("$SYSTEMCTL_BIN" show "$1" -p ExecStart --value 2>/dev/null)" || return 2
  # Bash-wrapped: the token following `argv[]=/bin/bash` (or /bin/sh) is the script.
  p="$(printf '%s' "$v" | awk '
    { for (i=1; i<=NF; i++) {
        if ($i == "argv[]=/bin/bash" || $i == "argv[]=/bin/sh" || $i == "argv[]=/usr/bin/bash") {
          if ($(i+1) ~ /^\//) { print $(i+1); exit }
        }
      } }')"
  if [ -z "$p" ]; then
    # Direct script: the path= value is the script, and argv[0] (== path) is itself an /abs/script.
    p="$(printf '%s' "$v" | sed -n 's/.* path=\(\/[^ ;{}]*\) ; .*/\1/p')"
  fi
  # Only an absolute filesystem path is judgeable as a pinned entry point.
  case "$p" in /*) printf '%s' "$p" ;; *) printf '' ;; esac
}

# report_units — one orphan line per harness unit whose pinned path is missing or scratch-pinned.
report_units() {
  local units name path root
  units="$("$SYSTEMCTL_BIN" list-units --type=service --all --no-legend 2>/dev/null)" || return 1
  while read -r line; do
    name="$(printf '%s' "$line" | awk '{print $1}')"
    [ -n "$name" ] || continue
    is_harness_unit "$name" || continue
    if ! path="$(execstart_path "$name")"; then
      # rc 2 = the read FAILED. Reporting it as "not judgeable" would turn a broken instrument into a
      # clean report; it is named instead, and the unit is still not called an orphan (we did not read it).
      printf 'unreadable:kind=unit name=%s reason=execstart-unreadable\n' "$name"
      continue
    fi
    [ -n "$path" ] || continue   # no pinned script path: not judgeable, not an orphan here
    if [ ! -e "$path" ]; then
      printf 'orphan:kind=unit name=%s path=%s prs=- reason=missing\n' "$name" "$path"
      continue
    fi
    for root in ${SCRATCH_ROOTS}; do
      case "$path" in
        "$root"*)
          printf 'orphan:kind=unit name=%s path=%s prs=- reason=scratch-pinned\n' "$name" "$path"
          break ;;
      esac
    done
  done <<< "$units"
}

# ── main ──
printf 'orphaned-harness: host=%s (read-only report)\n' "$(host)"
printf 'orphaned-harness: surfaces tmux=%s systemctl=%s min_session_age_s=%s\n' \
  "$([ -n "$(command -v "$TMUX_BIN" 2>/dev/null)" ] && echo readable || echo unreadable)" \
  "$([ -n "$(command -v "$SYSTEMCTL_BIN" 2>/dev/null)" ] && echo readable || echo unreadable)" \
  "${MIN_SESSION_AGE_S}"

TMUX_READ=1; UNIT_READ=1
[ -n "$(command -v "$TMUX_BIN" 2>/dev/null)" ] || TMUX_READ=0
[ -n "$(command -v "$SYSTEMCTL_BIN" 2>/dev/null)" ] || UNIT_READ=0

[ "$TMUX_READ" -eq 1 ] && { report_tmux || TMUX_READ=0; }
[ "$UNIT_READ" -eq 1 ] && { report_units || UNIT_READ=0; }

if [ "$TMUX_READ" -eq 0 ] && [ "$UNIT_READ" -eq 0 ]; then
  printf 'orphaned-harness: ERROR — neither tmux nor systemctl could be read; no verdict (exit 2)\n' >&2
  exit 2
fi
exit 0
