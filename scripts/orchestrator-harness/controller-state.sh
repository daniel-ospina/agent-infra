#!/bin/bash
# controller-state.sh — WHO this controller instance is, WHICH state directory it owns, WHETHER it is
# the only one, and WHERE its thresholds came from. Sourced by orch-loop.sh (agent-infra#2095).
#
# ── WHY THIS FILE EXISTS, MEASURED ───────────────────────────────────────────────────────────────
# A proof copy of the controller (`/tmp/orc-proof/orch-loop.sh`, parent `/tmp/live-cycle.sh`) ran for
# **5 h 15 m** beside the launchd controller. Both resolved `O="${O:-$HOME/orchestrator}"`, so the two
# co-ran against ONE state directory and ONE log, and the proof copy gated dispatch at its OWN
# derived `MAX_LOAD=100` while the plist said 250:
#
#     14121  05:15:21  bash /tmp/orc-proof/orch-loop.sh
#     [cap] load=158/100 lanes=0/25 …
#     [dispatch] skipped (load=158>=max_load=100) lanes=0 workers=3
#
# Three separate defects are in those two lines, and this file answers one each:
#   1. NO SINGLETON. The old `.orch.lock` refusal was `exit 0` and its evidence was a bare
#      `kill -0 <pid>` — a pid check with no identity, so a RECYCLED pid reads as a live controller
#      forever and a lock that refused quietly looks like a controller that did nothing.
#   2. NO STATE ISOLATION. A copy run from anywhere wrote the production state dir.
#   3. NO PROVENANCE ON THE CEILING. `[cap]` printed the value in force and never its source, so a
#      divergence between the plist and the running instance could only be INFERRED from arithmetic.
#
# ── THE RULES, AND WHERE THEIR SIBLINGS LIVE ────────────────────────────────────────────────────
# ⛔ The liveness/identity predicates here are the SAME RULES as `scripts/lib/pid-identity.sh`
# (`pid_start_epoch`, `pid_began_after`) and `scripts/lib/orchestrator-registry.sh`
# (`registry_pid_is_controller`). They are RESTATED, not sourced, because this file is deployed FLAT
# into `$O` by the harness's documented install (`cp "$HERE"/*.sh "$O"/`) — a flat copy has no
# `lib/` beside it, and a controller that cannot evaluate its own singleton must not run. The
# restatement is not left to trust: `controller-state.test.sh` drives BOTH copies over the same
# fixtures and fails if they ever disagree (the pinned-mirror pattern
# `cloud-cell-supervisor.sh` already uses for the same reason).
#
# ⛔ NOTHING HERE EXITS, SETS SHELL OPTIONS, OR DECIDES POLICY. The caller decides what a refusal
# means (orch-loop.sh exits 75 and says why). Every function returns a documented status instead.

# ── identity of this process ───────────────────────────────────────────────────────────────────
# One string, stable for the life of the process, that names the INSTANCE. `$$` alone is not one: two
# boxes (or two state dirs on one box) both have a pid 14121. host + state + start time make the
# value something an operator can grep for across a fleet's logs.
ORC_INSTANCE=""
ORC_STARTED=""

orc_hostname() { hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown'; }

# orc_self_describe <state-dir> — fills ORC_STARTED (ONCE) and ORC_INSTANCE, and prints the latter.
# ⛔ THE START TIME MUST BE SET OUTSIDE A SUBSHELL. Called as `$(orc_self_describe …)` it re-derived
# `started=` from `date +%s` on every call, so two lines in one run carried two different identities
# — the opposite of an instance id. The controller calls it as a STATEMENT and prints
# `$ORC_INSTANCE`; the printer stays for callers that only want the string.
orc_self_describe() {
  local state="${1:-}"
  [ -n "${ORC_STARTED:-}" ] || ORC_STARTED="$(date +%s)"
  ORC_INSTANCE="pid=$$ host=$(orc_hostname) started=$ORC_STARTED"
  [ -n "$state" ] && ORC_INSTANCE="$ORC_INSTANCE state=$state"
  printf '%s' "$ORC_INSTANCE"
}

# ── 1. the state directory: EXPLICIT wins, PRODUCTION only from the production install ─────────
# The precedence, and why each step is where it is:
#   ORC_STATE_DIR   the canonical name (agent-infra#2095). An operator (or a test) says where.
#   O               the LEGACY name, still set by every plist template and keys.env already deployed.
#                   Honoured, and named as legacy in the provenance so a reader can see it.
#   production      $HOME/orchestrator, but ONLY for the copy that LIVES there. This is the arm that
#                   removes the measured incident: a copy at /tmp/orc-proof/ has no way to reach the
#                   production state by DEFAULT, and a run that wanted to would have to say so.
#   isolated        ${TMPDIR:-/tmp}/orc-state-<dir of the copy>. Deterministic, so two runs of the
#                   same proof copy share a lock (which is what makes the singleton mean something)
#                   and two different copies do not.
#
# ⛔ THE ISOLATED DEFAULT IS NOT "SAFE" — IT IS NON-DESTRUCTIVE. It does not pretend to be correct
# state: a proof copy with no state is a copy that cannot merge or dispatch (its candidates/claims
# are empty), which is what a proof copy should be. It is reported as `derived:isolated(…)` in
# `[start]` and in every `[cap]` line, so nobody mistakes it for the production controller.
# ⛔ THE RESOLVER IS A GLOBAL-SETTING FUNCTION, NOT A PRINTER WITH A SIDE EFFECT (2026-10-19).
# `O="$(orc_state_resolve …)"` runs it in a COMMAND-SUBSTITUTION SUBSHELL, so `ORC_STATE_SRC` set
# inside it never reached the caller — every `[cap]`/`[start]` line printed `state_src=` empty, and
# the mkdir refusal named no source at all, on the one line an operator reads to find the copy that
# took the production directory. Mutating state inside `$( )` is the same defect class as the
# `MAX_LOAD` provenance (item 4): the value was computed and then thrown away.
# So the decision lands in globals (`ORC_STATE_RESOLVED`, `ORC_STATE_SRC`), and `orc_state_resolve`
# is a thin PRINTING wrapper for tests and one-shot callers. Both go through the same function, so
# they cannot disagree about the answer.
orc_state_pick() { # <script-path> -> sets ORC_STATE_RESOLVED + ORC_STATE_SRC; never prints
  local script="${1:-}" prod own base
  # `$HOME/orchestrator` IS the production path. An unset HOME cannot name it, and `` + `/orchestrator`
  # would quietly become `/orchestrator` — a path that does not exist but reads like an answer.
  prod="${HOME:-}/orchestrator"
  [ -n "${HOME:-}" ] || prod="/nonexistent-HOME/orchestrator"
  if [ -n "${ORC_STATE_DIR:-}" ]; then
    ORC_STATE_SRC="env:ORC_STATE_DIR"
    ORC_STATE_RESOLVED="$ORC_STATE_DIR"
    return 0
  fi
  if [ -n "${O:-}" ]; then
    ORC_STATE_SRC="env:O(legacy)"
    ORC_STATE_RESOLVED="$O"
    return 0
  fi
  own="$(cd "$(dirname "$script")" 2>/dev/null && pwd)" || own=""
  if [ -n "$own" ] && [ "$own" = "$prod" ]; then
    ORC_STATE_SRC="default:production-install"
    ORC_STATE_RESOLVED="$prod"
    return 0
  fi
  base="$(basename "${own:-proof}")"
  # A path is a directory NAME here, so anything that could break a shell word is folded to `_`.
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"
  ORC_STATE_SRC="derived:isolated(non-production copy at ${own:-<unresolved>})"
  ORC_STATE_RESOLVED="${TMPDIR:-/tmp}/orc-state-$base"
  return 0
}

# orc_state_resolve <script-path> — the printing form. ⛔ `ORC_STATE_SRC` is set in the CALLER's
# shell only when this is invoked WITHOUT `$( )` (e.g. `orc_state_resolve "$0" > /dev/null`); the
# controller calls `orc_state_pick` directly for exactly that reason.
orc_state_resolve() {
  orc_state_pick "${1:-}"
  printf '%s' "$ORC_STATE_RESOLVED"
}

# ── 2. the singleton: a pid file whose evidence is LIVENESS + IDENTITY + AGE ───────────────────
# The record is two lines of `key=value`, written by ONE `printf` under `set -o noclobber` (the
# create is the claim; the content follows immediately, and a reader that catches the empty window
# re-reads once and then fails CLOSED rather than assuming the lock is free):
#
#   orc-v1 pid=<pid> started=<epoch> host=<host>
#   state=<dir>
#
# Three outcomes for an existing record, and the middle one is the whole fix:
#   0  ACQUIRED   (no record, or a record whose owner is provably gone/recycled — reclaimed)
#   1  HELD       a LIVE process whose INVOCATION IS this controller -> refuse, loudly
#   2  UNJUDGED   the record exists and cannot be judged               -> refuse (fail CLOSED)
#
# ⛔ FAIL-CLOSED ON 2. "I could not read the evidence" is not "the lock is free": reclaiming an
# unreadable lock is how two controllers get to share one state dir, which is the incident.
# ⛔ THE ARGV PREDICATE IS STRICT — `${2##*/}` is `orch-loop.sh` — for the reason
# `registry_pid_is_controller` documents at length: matching ANY argv token (`*orch-loop.sh*`) accepts
# `bash -c "… /abs/orch-loop.sh"`, i.e. a shell that merely mentions the path.
ORC_HOLDER_PID=""
ORC_HOLDER_STARTED=""
ORC_HOLDER_STATE=""
ORC_HOLDER_WHY=""
ORC_LOCK_WRITTEN=0

# orc_pid_is_controller <pid> — 0 only for a live process whose INVOCATION is `orch-loop.sh`.
orc_pid_is_controller() {
  local p="${1:-}" c
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  c="$(ps -o command= -p "$p" 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "${2##*/}" in orch-loop.sh) return 0 ;; esac
  return 1
}

# orc_pid_start_epoch <pid> — when the process began, from `ps -o etime=` (the SAME shape on BSD and
# GNU ps, unlike etimes/lstart). rc 1 when it cannot be read. `10#` because etime ZERO-PADS and bash
# reads a leading zero as octal — `08:31` made the sibling copy fail, which turned "cannot tell" into
# "it began before the lock", i.e. into the strongest possible evidence of ownership.
orc_pid_start_epoch() {
  local p="${1:-}" e d h m s r
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  e="$(ps -o etime= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$e" ] || return 1
  d=0
  case "$e" in *-*) d="${e%%-*}"; r="${e#*-}" ;; *) r="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;           m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0})); d=$((10#${d:-0}))
  printf '%s' "$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))"
}

# orc_pid_began_after <pid> <epoch> — 0 after, 1 not after, 2 cannot tell. THREE outcomes, never two:
# folding "cannot tell" into "not after" makes an unreadable age the strongest evidence of ownership.
orc_pid_began_after() {
  local pe="${2:-}" ps
  case "$pe" in ''|*[!0-9]*) return 2 ;; esac
  ps="$(orc_pid_start_epoch "${1:-}")" || return 2
  [ "$ps" -gt "$(( pe + ${ORC_PID_START_SLACK_S:-5} ))" ]
}

# orc_lock_read <lockfile> — parse the record into ORC_HOLDER_*; rc 0 read, 1 absent, 2 unreadable.
orc_lock_read() {
  local lock="${1:-}" line magic pid started host
  ORC_HOLDER_PID=""; ORC_HOLDER_STARTED=""; ORC_HOLDER_STATE=""; ORC_HOLDER_WHY=""
  [ -e "$lock" ] || return 1
  [ -r "$lock" ] || { ORC_HOLDER_WHY="the lock file is not readable"; return 2; }
  line="$(sed -n '1p' "$lock" 2>/dev/null)" || { ORC_HOLDER_WHY="the lock file could not be read"; return 2; }
  # shellcheck disable=SC2086
  set -- $line
  magic="${1:-}"
  [ "$magic" = "orc-v1" ] || { ORC_HOLDER_WHY="the lock file is not an orc-v1 record"; return 2; }
  shift
  pid=""; started=""; host=""
  # shellcheck disable=SC2086
  for kv in "$@"; do
    case "$kv" in
      pid=*)     pid="${kv#pid=}" ;;
      started=*) started="${kv#started=}" ;;
      host=*)    host="${kv#host=}" ;;
    esac
  done
  case "$pid" in ''|*[!0-9]*) ORC_HOLDER_WHY="the lock record carries no usable pid"; return 2 ;; esac
  case "$started" in ''|*[!0-9]*) started="" ;; esac
  ORC_HOLDER_PID="$pid"; ORC_HOLDER_STARTED="$started"
  ORC_HOLDER_STATE="$(sed -n 's/^state=//p' "$lock" 2>/dev/null | head -1)"
  return 0
}

# _orc_lock_create <lockfile> <record> — the exclusive create. 0 = ours, 1 = somebody else's.
_orc_lock_create() {
  ( set -o noclobber; printf '%s\n' "$2" > "$1" ) 2>/dev/null
}

# orc_singleton_acquire <lockfile> <state-dir> — see the three outcomes above. On 0, ORC_LOCK_WRITTEN
# is 1 and the caller OWNS the release. On 1/2 the reason is in ORC_HOLDER_WHY.
orc_singleton_acquire() {
  local lock="${1:?}" state="${2:-}" rec pid started rc why
  ORC_LOCK_WRITTEN=0
  rec="$(printf 'orc-v1 pid=%s started=%s host=%s\nstate=%s' "$$" "$(date +%s)" "$(orc_hostname)" "$state")"
  if _orc_lock_create "$lock" "$rec"; then ORC_LOCK_WRITTEN=1; return 0; fi

  orc_lock_read "$lock"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # The empty/unwritten window: the holder is between `create` and `write`. One short re-read, then
    # fail CLOSED — an unreadable record is not evidence that the lock is free.
    sleep 1 2>/dev/null || true
    orc_lock_read "$lock"; rc=$?
    if [ "$rc" -ne 0 ]; then
      [ -n "${ORC_HOLDER_WHY:-}" ] || ORC_HOLDER_WHY="the lock record could not be read"
      return 2
    fi
  fi

  pid="${ORC_HOLDER_PID:-}"
  started="${ORC_HOLDER_STARTED:-}"
  if ! kill -0 "$pid" 2>/dev/null; then
    ORC_HOLDER_WHY="the recorded process is gone (pid $pid)"
    why="stale"
  elif ! orc_pid_is_controller "$pid"; then
    # Alive, but NOT a controller invocation. Two readings, and they differ:
    #   * pid RECYCLED — the record describes a controller that is gone and this pid merely inherited
    #     its number. Provable only by age (began AFTER the record was written), and then self-healing.
    #   * anything else — we cannot tell. REFUSE, never reclaim (this is the fail-closed arm).
    orc_pid_began_after "$pid" "$started"
    case $? in
      0) ORC_HOLDER_WHY="pid $pid is a RECYCLED pid (it began after the record was written)"; why="stale" ;;
      *) ORC_HOLDER_WHY="pid $pid is alive but is not an orch-loop.sh invocation, and its age cannot prove reuse"; why="held" ;;
    esac
  else
    ORC_HOLDER_WHY="pid $pid is a live orch-loop.sh invocation"
    why="held"
  fi

  if [ "$why" = "stale" ]; then
    # Re-check immediately before removing: between the judgement above and here the holder may have
    # released AND a third instance may have claimed. Removing blindly would delete a LIVE lock.
    local now_pid
    now_pid="$(sed -n 's/^orc-v1 pid=\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null | head -1)"
    if [ "${now_pid:-}" = "$pid" ]; then
      rm -f "$lock" 2>/dev/null
      if _orc_lock_create "$lock" "$rec"; then ORC_LOCK_WRITTEN=1; return 0; fi
      orc_lock_read "$lock" || true
      ORC_HOLDER_WHY="the stale record was reclaimed by another instance (${ORC_HOLDER_WHY:-lock race})"
      return 1
    fi
    ORC_HOLDER_WHY="the record changed while it was being judged (lock race)"
    return 1
  fi
  return 1
}

# orc_singleton_release <lockfile> — release ONLY a lock this process wrote. A release that removes
# somebody else's record is how a second controller starts believing it is the first.
orc_singleton_release() {
  local lock="${1:-}" pid
  [ -n "$lock" ] || return 0
  pid="$(sed -n 's/^orc-v1 pid=\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null | head -1)"
  [ "${pid:-}" = "$$" ] || return 0
  rm -f "$lock" 2>/dev/null || true
}

# ── 3. where a threshold's value CAME FROM ──────────────────────────────────────────────────────
# `[cap]` printed the ceiling in force and nothing about where it came from, so the incident's two
# values (100 and 250) were indistinguishable in the log from one box changing its mind. Three
# sources, and they are distinguishable by construction:
#   plist   the value is in the environment AND the environment says it was rendered from the plist
#           (`ORC_CONTROLLER_ORIGIN`, set by launchd.plist.template). This is the only way to tell a
#           plist value from a shell export — launchd passes both as ordinary environment variables,
#           so "MAX_LOAD is in the env" alone cannot answer the question the issue asks.
#   env     in the environment, no origin marker (a shell export, a cell's keys.env, a test).
#   derived the documented derivation from the core count (no value supplied).
#   default the derivation itself was out of range and the documented fallback applied.
# `(repaired)` is appended by the caller when a supplied value failed validation and was replaced.
orc_var_set() { # <VARNAME> — true when the variable is set AND non-empty (an empty MAX_LOAD=""
  eval "[ -n \"\${$1:-}\" ]" 2>/dev/null                 # means "not supplied": the derivation runs)
}

orc_limit_src() { # <VARNAME> <derived|default> -> plist(origin)|env|derived|default
  local var="${1:?}" fallback="${2:-derived}"
  if orc_var_set "$var"; then
    if [ -n "${ORC_CONTROLLER_ORIGIN:-}" ]; then
      printf 'plist(%s)' "$ORC_CONTROLLER_ORIGIN"
    else
      printf 'env'
    fi
  else
    printf '%s' "$fallback"
  fi
}

# ── 4. the lane count: LIVE PROCESSES, cross-checked against the session-name convention ───────
# ⛔ THE COUNT USED TO BE `tmux ls | grep -c '^lane-'`, and it read `lanes=0` while **48-50 `pi
# --model` processes were live**: any lane not started through that exact naming is invisible, so the
# controller believed it had 25 free slots on a box thrashing at load 170. A session NAME is a
# convention; a live process in a worktree is an observation.
#
# The census (`lane-census.sh`, beside this file) reports BOTH observations and the value to use:
#   src=worktrees  the process-table census read: N distinct worktrees held by live agent processes
#   src=tmux       the census was UNREADABLE, so the session convention answered (named as the
#                  fallback it is — the log says so instead of presenting it as a measurement)
# The value USED is `max(process-derived, tmux)` — deliberately the LARGER of two independent
# observations, because the failure being fixed is UNDER-counting, and a larger count can only ever
# REFUSE a dispatch (the safe direction). `[cap]` prints both, so a disagreement is never silent.
ORC_LANES=0
ORC_WORKERS=0
ORC_LANES_SRC=""
ORC_CENSUS_STATE=""
ORC_CENSUS_WHY=""
ORC_LANES_TMUX=""
ORC_WORKERS_TMUX=""
ORC_LANES_WT=""
ORC_WORKERS_WT=""
ORC_AGENT_PROCS=""
ORC_TAKEN=""

# orc_tmux_counts — the CONVENTION, read directly. Sets ORC_LANES_TMUX / ORC_WORKERS_TMUX (or leaves
# them empty when tmux cannot be read at all, which is not the same as zero sessions).
orc_tmux_counts() {
  local names
  ORC_LANES_TMUX=""; ORC_WORKERS_TMUX=""
  names="$(tmux ls -F '#{session_name}' 2>/dev/null)" || return 1
  ORC_LANES_TMUX="$(printf '%s\n' "$names" | grep -c '^lane-')" || true
  ORC_WORKERS_TMUX="$(printf '%s\n' "$names" | grep -cE '^(merge|fix)-')" || true
  return 0
}

# orc_census <census-script> <repo> — fills the ORC_* census fields above. Never fails: a census that
# cannot answer leaves ORC_CENSUS_STATE=UNREADABLE and the tmux fallback in place, both REPORTED.
orc_census() {
  local bin="${1:-}" repo="${2:-}" out tok k v
  ORC_CENSUS_STATE="UNREADABLE"; ORC_CENSUS_WHY=""
  ORC_LANES_WT=""; ORC_WORKERS_WT=""; ORC_AGENT_PROCS=""; ORC_TAKEN=""
  if orc_tmux_counts; then :; else
    ORC_LANES_TMUX=""; ORC_WORKERS_TMUX=""
  fi
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    ORC_CENSUS_WHY="no executable census at '${bin:-<none found>}'"
  else
    out="$("$bin" --repo "$repo" 2>/dev/null)" || out=""
    case "$out" in
      state=*) ;;
      *) ORC_CENSUS_WHY="the census produced no state token" ;;
    esac
    for tok in $out; do
      case "$tok" in
        state=*)      ORC_CENSUS_STATE="${tok#state=}" ;;
        why=*)        [ -n "$ORC_CENSUS_WHY" ] || ORC_CENSUS_WHY="${tok#why=}" ;;
        procs=*)      ORC_AGENT_PROCS="${tok#procs=}" ;;
        lanes_wt=*)   ORC_LANES_WT="${tok#lanes_wt=}" ;;
        workers_wt=*) ORC_WORKERS_WT="${tok#workers_wt=}" ;;
        lanes_tmux=*)   ORC_LANES_TMUX="${tok#lanes_tmux=}" ;;
        workers_tmux=*) ORC_WORKERS_TMUX="${tok#workers_tmux=}" ;;
        taken=*)      ORC_TAKEN="${tok#taken=}" ;;
        used=*|src=*) : ;;   # recomputed here from the fields above, so the two cannot disagree
      esac
    done
  fi
  # ── the value to use, and WHERE it came from ───────────────────────────────────────────────
  # A number that is not a number is NEVER used: `[ "$LANES" -ge "$MAX_LANES" ]` on a junk value is an
  # ERRORED test, which is FALSE, which OPENS the lane gate — the same fail-open class this file's
  # siblings guard every other threshold against.
  case "${ORC_LANES_TMUX:-}" in ''|*[!0-9]*) ORC_LANES_TMUX="" ;; esac
  case "${ORC_WORKERS_TMUX:-}" in ''|*[!0-9]*) ORC_WORKERS_TMUX="" ;; esac
  case "${ORC_LANES_WT:-}" in ''|*[!0-9]*) ORC_LANES_WT="" ;; esac
  case "${ORC_WORKERS_WT:-}" in ''|*[!0-9]*) ORC_WORKERS_WT="" ;; esac
  if [ -n "${ORC_LANES_WT:-}" ]; then
    ORC_LANES="$ORC_LANES_WT"; ORC_LANES_SRC="worktrees"
    ORC_WORKERS="${ORC_WORKERS_WT:-0}"; [ -n "${ORC_WORKERS_WT:-}" ] || ORC_WORKERS="${ORC_WORKERS_TMUX:-0}"
  else
    ORC_LANES="${ORC_LANES_TMUX:-0}"; ORC_LANES_SRC="tmux"
    ORC_WORKERS="${ORC_WORKERS_TMUX:-0}"
  fi
  # The larger of the two independent observations (see the header).
  if [ -n "${ORC_LANES_TMUX:-}" ] && [ "${ORC_LANES_TMUX}" -gt "${ORC_LANES:-0}" ]; then
    ORC_LANES="$ORC_LANES_TMUX"; ORC_LANES_SRC="tmux(census reported ${ORC_LANES_WT:-unreadable})"
  fi
  case "${ORC_LANES:-}" in ''|*[!0-9]*) ORC_LANES=0; ORC_LANES_SRC="UNREADABLE" ;; esac
  case "${ORC_WORKERS:-}" in ''|*[!0-9]*) ORC_WORKERS=0 ;; esac
  return 0
}

# orc_census_token — the ONE-LINE form `[cap]` prints: the value used, its source, and BOTH
# observations when they disagree. `src` is never omitted: a value with no provenance is exactly what
# made the incident's arithmetic-only inference necessary.
#
# ⛔ AND A PARTIAL READ SAYS SO, IN THE SAME TOKEN (agent-infra#2095 — the "confidently wrong zero").
# `lanes=0` was printed for a box running 48-50 agents because the count came from a convention that
# could not see them; the same shape comes back whenever the census fails HALF ITS READ: the process
# table answers, tmux does not (or the reverse), and the token printed a bare number that reads as a
# measurement. So every non-READ state now carries a state marker IN THE LINE AN OPERATOR GREPS:
#
#   state=READ        nothing appended — an unmarked token is a token that was MEASURED.
#   state=PARTIAL     `PARTIAL(taken=<n>)` — one observation answered, the other did not. `taken` is
#                     the worktree count the roster vocabulary uses, or `?` when even that is
#                     unknown: a zero from an unread cell is printed as `?`, never as 0.
#   state=UNREADABLE  `UNREADABLE(taken=<n|?>)` — nothing answered. `lanes=` still carries the value
#                     the GATE used (so the line explains the decision), but it can no longer be
#                     mistaken for a reading.
# The `why=` token names the failing read, so "partial" is actionable rather than merely honest.
orc_census_token() { # [max_lanes] — `lanes=<used>/<max>` keeps the shape operators already grep
  local tok max="${1:-}" taken why
  tok="lanes=${ORC_LANES:-0}${max:+/$max} lanes_src=${ORC_LANES_SRC:-UNKNOWN}"
  [ -n "${ORC_LANES_TMUX:-}" ] && tok="$tok tmux=${ORC_LANES_TMUX}"
  [ -n "${ORC_LANES_WT:-}" ]   && tok="$tok worktrees=${ORC_LANES_WT}"
  [ -n "${ORC_AGENT_PROCS:-}" ] && tok="$tok agent_procs=${ORC_AGENT_PROCS}"
  [ -n "${ORC_TAKEN:-}" ]      && tok="$tok taken=${ORC_TAKEN}"
  if [ -n "${ORC_LANES_TMUX:-}" ] && [ -n "${ORC_LANES_WT:-}" ] && [ "${ORC_LANES_TMUX}" -ne "${ORC_LANES_WT}" ]; then
    tok="$tok DISAGREE(tmux=${ORC_LANES_TMUX} worktrees=${ORC_LANES_WT} used=${ORC_LANES:-0})"
  fi
  # A `taken` that is not a number is `?`: an unread count must never be rendered as a zero.
  case "${ORC_TAKEN:-}" in ''|*[!0-9]*) taken="?" ;; *) taken="$ORC_TAKEN" ;; esac
  # `why` is sanitized to ONE space-free token: `orc_census` carries prose for a missing binary, and
  # a space inside a `key=value` token splits it into two fields for every `for tok in $line` reader.
  why="$(printf '%s' "${ORC_CENSUS_WHY:-}" | tr -c 'A-Za-z0-9._-' '_' 2>/dev/null)"
  case "${ORC_CENSUS_STATE:-}" in
    "") ;;
    READ) ;;
    PARTIAL) tok="$tok PARTIAL(taken=$taken)${why:+ why=$why}" ;;
    *) tok="$tok UNREADABLE(taken=$taken)${why:+ why=$why}" ;;
  esac
  printf '%s' "$tok"
}
