#!/usr/bin/env bash
# nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]
# nonblocking-dispatch.sh --status <name>
#
# Launches a headless worker in the BACKGROUND and RETURNS IMMEDIATELY, so an orchestrator can keep
# working instead of blocking on it. (The built-in `task`/`subagent` tools block the caller — that is
# agent-infra#1662, "non-blocking dispatch is the one remaining structural gap"; this is the harness's
# own version of the shape #206 sanctions, with the status seam #1662 names as the missing piece.)
#
# ⛔ IT CARRIES NO AGENT INVOCATION OF ITS OWN. It backgrounds `run_agent()` from spawn-gate.sh, so a
# background worker gets the SAME load gate (agent-infra#1720), the same wall-clock watchdog and the
# same #1709 walltime row as `lane.sh` and `fix-one.sh`. The local copy this is ported from spawned
# `pi` itself with NO load gate — i.e. it was a fourth, ungated launch path, exactly what
# spawn-gate.test.sh's two-scope census exists to refuse (it asserts the invoker SET as an equality).
# Routing through the helper is the whole point of the port; do not "simplify" it back to a direct
# spawn, or the census goes red and a background worker starts landing on a saturated box.
set -u
_MTIME_FLAVOUR=""
case "$(stat -f %m / 2>/dev/null)" in ''|*[!0-9]*) _MTIME_FLAVOUR=gnu ;; *) _MTIME_FLAVOUR=bsd ;; esac
f_mtime() { # f_mtime <path> → epoch seconds (0 when unreadable, never a guess)
  local m=""
  case "$_MTIME_FLAVOUR" in
    bsd) m="$(stat -f %m "$1" 2>/dev/null)" ;;
    gnu) m="$(stat -c %Y "$1" 2>/dev/null)" ;;
  esac
  case "${m:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$m" ;; esac
}

# ── the verdict (agent-infra#2045) ──────────────────────────────────────────────────────────
# ⛔ A LANE THAT PRODUCED NOTHING MUST NOT REPORT AS HEALTHY. Measured 2026-10-18 on eight background
# lanes: three produced nothing, and one of them was mid-work when its cap fired. The notifier said
# `worker finished: <name>: commits=0 PR=none` for it — byte-identical to a lane that had legitimately
# had nothing to do — so a supervisor reading that line sees a quiescent lane and never re-dispatches,
# and the work disappears from the fleet's accounting while seven modified files sit on disk. The
# DISTINGUISHABLE STATES ARE THE DELIVERABLE; `commits=0` is not a verdict.
#
#   killed-at-cap     the wall-clock cap ended it        FAILED  (work snapshotted, see the record)
#   lost              no exit status, pid gone           FAILED  (nothing recorded; may hold work)
#   failed            rc != 0                            FAILED  (it ran and failed)
#   no-report         the prompt's report file is absent FAILED  (the only reliable deliverable)
#   committed-nothing rc=0, commits=0, worktree DIRTY    FAILED  (it worked and never committed)
#   clean-no-work     rc=0, commits=0, tree clean        ok      (this is a legitimate outcome)
#   done              rc=0 with commit(s)                ok
#   running           no exit status, pid alive          ok
#   unverifiable      state present, worktree unreadable FAILED  (never guess a pass)
# ⛔ `killed-at-cap` is read from the CAP RECORD (`cap-bg-<name>.tsv`, written by run_agent at the
# cap), never inferred from a `.rc` value: 143 also arrives from a TERM the harness did not send, and
# a rc-only ladder would report those as `failed` while the snapshot directory goes unmentioned.
# ⛔ THE STATE IS THE VERDICT, AND THIS LIST IS ITS ONLY DEFINITION. The classifier is invoked inside
# `$( … )` (a SUBSHELL), so a `BG_FAILED=1` set inside it is DISCARDED — the first version did exactly
# that and `--verdict` exited 1 for EVERY state, including `done` (caught by this suite's OK arms,
# which exist precisely because "everything fails" is as useless as "everything passes").
BG_FAIL_STATES=" killed-at-cap lost failed no-report committed-nothing unverifiable "

# The report path the prompt names, if it names one. A placeholder (`REPORT-<name>.md`) is not a
# path, so it is resolved against its directory — comparing the candidate's mtime with the run's
# start, so a report left by an EARLIER run of the same name can never satisfy this one.
bg_report_present() { # <prompt> <start-epoch> → 0 present | 1 absent | 2 not required
  local p="$1" st="$2" c dir f any=0
  [ -f "$p" ] || return 2
  for c in $(grep -Eo '/[A-Za-z0-9._<>*/+-]*REPORT[A-Za-z0-9._<>*/+-]*\.md' "$p" 2>/dev/null | sort -u); do
    any=1
    case "$c" in
      *'<'*|*'>'*|*'*'*) dir="$(dirname "$c")"
        for f in "$dir"/REPORT-*.md; do
          [ -s "$f" ] || continue
          [ "$(f_mtime "$f")" -ge "$st" ] && return 0
        done ;;
      *) [ -s "$c" ] && return 0 ;;
    esac
  done
  [ "$any" = 0 ] && return 2
  return 1
}

# bg_classify <name> → one line `<STATE>\t<evidence>`; BG_FAILED=1 for a FAILED state.
bg_classify() {
  local name="$1" d="$O/bg" rc pid stamp wt prompt br commits dirty rep crec crows started=0 evidence
  rc="$(cat "$d/$name.rc" 2>/dev/null || true)"
  pid="$(cat "$d/$name.pid" 2>/dev/null || true)"
  stamp="$d/$name.started"
  wt=""; prompt=""
  if [ -f "$stamp" ]; then
    wt="$(sed -n 's/^worktree=//p' "$stamp" 2>/dev/null | head -1)"
    prompt="$(sed -n 's/^prompt=//p' "$stamp" 2>/dev/null | head -1)"
    started="$(sed -n 's/^started_epoch=//p' "$stamp" 2>/dev/null | head -1)"
    case "${started:-}" in ''|*[!0-9]*) started=0 ;; esac
  fi
  # ⛔ THE CAP RECORD IS FILTERED BY THE RUN'S START, not just read: `caps.tsv` and the per-name record
  # are APPEND-ONLY across runs, so the last row of a previous run of the same name would otherwise
  # classify a brand-new, healthy run as killed. Only rows at or after this run's start count.
  crec="$O/state/cap-bg-$name.tsv"; crows=""
  if [ -s "$crec" ]; then
    crows="$(awk -F'\t' -v s="$started" '($1+0) >= (s+0)' "$crec" 2>/dev/null)"
  fi
  # ── the ladder. ORDER IS THE CONTRACT: a recorded cap outranks an rc (the rc of a capped run is
  # 143/137, which is also what an unrelated TERM produces); "no exit status at all" outranks rc too.
  if [ -n "$crows" ]; then
    evidence="$(printf '%s' "$crows" | tail -1 | awk -F'\t' '{printf "cap=%ss source=%s elapsed=%ss phase=%s rc=%s snapshot=%s", $5,$6,$7,$2,$10,$8}')"
    printf 'killed-at-cap\t%s' "$evidence"; return 0
  fi
  if [ -z "$rc" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'running\tpid=%s cap=%ss' "$pid" "$(sed -n 's/^cap=\([0-9]*\)s/\1/p' "$stamp" 2>/dev/null | head -1)"
    return 0
  fi
  if [ -z "$rc" ]; then
    printf 'lost\tno exit status recorded and pid %s is gone log=%s' "${pid:-<unknown>}" "$d/$name.log"
    return 0
  fi
  if [ "$rc" != "0" ]; then
    printf 'failed\trc=%s' "$rc"; return 0
  fi
  # rc=0 from here. The worktree is the evidence, so an unreadable one is never a pass.
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'unverifiable\tworktree %s is not readable, so commits/uncommitted work cannot be counted' "${wt:-<unnamed>}"
    return 0
  fi
  br="$(git -C "$wt" branch --show-current 2>/dev/null)"
  commits="$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || true)"
  case "${commits:-}" in ''|*[!0-9]*) commits="" ;; esac
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  case "${dirty:-}" in ''|*[!0-9]*) dirty=0 ;; esac
  rep=2; [ -n "$prompt" ] && { bg_report_present "$prompt" "$started"; rep=$?; }
  if [ "$rep" = 1 ]; then
    printf 'no-report\trc=0 branch=%s commits=%s uncommitted=%s report=%s is ABSENT' \
      "${br:-?}" "${commits:-?}" "$dirty" "$(grep -Eo '/[A-Za-z0-9._<>*/+-]*REPORT[A-Za-z0-9._<>*/+-]*\.md' "$prompt" 2>/dev/null | head -1)"
    return 0
  fi
  if [ "${commits:-0}" -gt 0 ]; then
    printf 'done\trc=0 branch=%s commits=%s uncommitted=%s report=%s' "${br:-?}" "$commits" "$dirty" "$( [ "$rep" = 0 ] && echo yes || echo n/a)"
    return 0
  fi
  if [ "$dirty" -gt 0 ]; then
    printf 'committed-nothing\trc=0 branch=%s commits=0 uncommitted=%s report=%s' "${br:-?}" "$dirty" "$( [ "$rep" = 0 ] && echo yes || echo n/a)"
    return 0
  fi
  printf 'clean-no-work\trc=0 branch=%s commits=0 uncommitted=0 report=%s' "${br:-?}" "$( [ "$rep" = 0 ] && echo yes || echo n/a)"
}

NAME="${1:-}"; MODE=""
case "$NAME" in
  --status)  MODE=status;  NAME="${2:-}" ;;
  --verdict) MODE=verdict; NAME="${2:-}" ;;
esac
if [ -n "$MODE" ]; then
  [ -n "$NAME" ] || { echo "usage: nonblocking-dispatch.sh $([ "$MODE" = verdict ] && echo --verdict || echo --status) <name>" >&2; exit 2; }
  O="${O:-$HOME/orchestrator}"; D="$O/bg"
  # ⛔ `IFS=$'\t' read`, NOT `${line%%\t*}`: in bash that pattern's `\t` is an ESCAPED LETTER, not a
  # tab, so it truncates the state at the first `t` — `lost` was read as `los` and `done` as `done` only
  # by luck. A verdict field that silently loses characters is a verdict that silently mis-reports.
  line="$(bg_classify "$NAME")"
  state=""; evidence=""
  IFS="$(printf '\t')" read -r state evidence <<<"$line"
  BG_FAILED=0
  case "$BG_FAIL_STATES" in *" $state "*) BG_FAILED=1 ;; esac
  if [ "$MODE" = verdict ]; then
    printf '%s\n' "$state"
    # ⛔ THE EXIT CODE IS THE SEAM A SUPERVISOR GATES ON. A state that produced nothing must be
    # non-zero here, or the supervisor's `if` reads a lost lane as a completed one — which is the
    # whole defect. `running`, `done` and `clean-no-work` are the ONLY zero states.
    [ "$BG_FAILED" = "1" ] && exit 1
    exit 0
  fi
  # ⛔ LIVENESS IS NOT %CPU. `%CPU == 0` means WAITING, not finished — a lane blocked in a long tool
  # call sits at 0 % CPU (docs/ops/fleet-liveness.md). The authoritative signal is the worker's own
  # exit-status file; the pid probe only distinguishes running from vanished.
  printf '%s %s\n' "$NAME" "$line"
  exit 0
fi
WT="${2:-}"; PROMPT="${3:-}"; T="${4:-}"
if [ -z "$NAME" ] || [ -z "$WT" ] || [ -z "$PROMPT" ]; then
  echo "usage: nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]" >&2
  echo "       nonblocking-dispatch.sh --status <name> | --verdict <name>" >&2
  exit 2
fi
# ⛔ THE CAP IS DERIVED FROM THE JOB (#2045), so `$4` is now OPTIONAL: absent, the cap comes from the
# prompt's own `ESTIMATE:`/`CAP:` line (agent_cap_resolve), and only a job that declares nothing falls
# back to the default. A written-timeout is still the dispatcher's explicit override and wins.
if [ -n "${T:-}" ]; then
  case "$T" in *[!0-9]*) echo "nonblocking-dispatch.sh: timeout '$T' is not a positive integer" >&2; exit 2 ;; esac
fi

O="${O:-$HOME/orchestrator}"; D="$O/bg"; mkdir -p "$D" "$O/state"
# ⛔ PATH FIRST, then source — this part IS lane.sh/fix-one.sh's rule. spawn-gate.sh derives `_NCPU`
# at SOURCE time (sysctl/nproc/getconf), so sourcing it under a cell's pre-export PATH pins
# `_NCPU=4` / `MAX_LOAD=40` for every cell (agent-infra#1702). The two siblings carry the same ⛔.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ AND RE-ASSERT THE gh LIMIT LAYER AFTER IT (#1988) — the same rule lane.sh / fix-one.sh /
# merge-one.sh / chain-merge.sh carry. This script does not call `gh` itself, but it SPAWNS a whole
# worker session IN-PROCESS (`run_agent` inherits this environment), so without these two lines every
# `gh` that worker runs resolves to `/opt/homebrew/bin/gh` — the layer would be deployed and inert,
# which is exactly the state the issue exists to remove. Grouped so the population check in
# `gh-limit.test.sh` sees them.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The RESOLUTION, though, mirrors merge-one.sh's repo-authority.sh — NOT lane.sh/fix-one.sh, which
# source only `$SELF/spawn-gate.sh` and never consult `$O`. Prefer the daemon's copy at `$O`, fall
# back to the copy beside THIS script; an unresolved helper must never degrade into "the worker ran".
if [ -f "$O/spawn-gate.sh" ]; then . "$O/spawn-gate.sh"; HARNESS="$O"
else
  HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  . "$HARNESS/spawn-gate.sh" 2>/dev/null \
    || { echo "nonblocking-dispatch.sh: spawn-gate.sh not found (looked in $O and ${HARNESS:-<unresolved>}) — refusing to start an ungated worker" >&2; exit 78; }
fi
command -v run_agent >/dev/null 2>&1 \
  || { echo "nonblocking-dispatch.sh: spawn-gate.sh is stale (no run_agent) — refusing to start an ungated worker" >&2; exit 78; }

[ -d "$WT" ]     || { echo "nonblocking-dispatch.sh: no worktree $WT" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "nonblocking-dispatch.sh: no prompt file $PROMPT" >&2; exit 2; }

# ⛔ THE CAP IS RESOLVED HERE, ONCE, AND STAMPED — the dispatcher must be able to read back which
# number governed the run and WHERE IT CAME FROM (`explicit` | `prompt` | `default`). Before #2045 the
# cap was a single global default unrelated to the job: a lane told to verify (this repo's
# `selftest.sh` is 411 assertions, `install-launchd-durability.test.sh` 269) spent 35 minutes before it
# reached its commit and was killed mid-suite. The resolution lives in spawn-gate.sh so every caller
# agrees on what a declared `ESTIMATE:`/`CAP:` line means.
CAP_SRC=""
if [ -n "${T:-}" ]; then CAP_SRC=explicit; else
  read -r T CAP_SRC <<<"$(agent_cap_resolve "" "$PROMPT")"
  [ -n "${T:-}" ] || { T=3000; CAP_SRC=default; }
fi
LOG="$D/$NAME.log"; RC="$D/$NAME.rc"; PIDF="$D/$NAME.pid"; STAMP="$D/$NAME.started"
# The worker is a fleet lane in every respect except that nobody waits for it: the local review/VGATE
# gates are bypassed so the PARENT owns the review ceremony, and no MCP servers are started.
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 \
       SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
KIND=bg; TAG="$NAME"; export KIND TAG

rm -f "$RC"
: > "$LOG"
# `started_epoch` is not decoration: the cap record is append-only ACROSS runs, so `--verdict` filters
# it against this number. Without it a fresh run inherits a previous run's `killed-at-cap`.
printf 'name=%s\nworktree=%s\nbranch=%s\nprompt=%s\nstarted=%s\nstarted_epoch=%s\ncap=%ss\ncap_source=%s\n' \
  "$NAME" "$WT" "$(git -C "$WT" branch --show-current 2>/dev/null)" "$PROMPT" \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" "$T" "$CAP_SRC" > "$STAMP"

cd "$WT" || exit 2
# The worker itself — backgrounded, NOT waited on. `trap '' HUP` + `disown` let it outlive the
# orchestrator that dispatched it; `<&-` closes stdin so it cannot steal the parent's tty input.
( trap '' HUP; run_agent "$T" "$LOG" "$PROMPT" "bg $NAME"; echo "$?" > "$RC" ) <&- &
PID=$!
echo "$PID" > "$PIDF"
disown "$PID" 2>/dev/null || true

# Durable record, so a later session can see what was dispatched and when (and can find the exit
# status later via `--status`, rather than inferring it from a log tail).
mkdir -p "$O/state" "$D"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$NAME" "$(git branch --show-current 2>/dev/null)" "$PID" "$(date '+%H:%M:%S')" >> "$D/dispatch-log.tsv"

echo "launched $NAME  pid=$PID  branch=$(git branch --show-current 2>/dev/null)  cap=${T}s (source=$CAP_SRC)"
echo "  log:     $LOG"
echo "  status:  bash $0 --status $NAME     # killed-at-cap | lost | failed | no-report | committed-nothing | clean-no-work | done | running"
echo "  verdict: bash $0 --verdict $NAME    # one token, exit 1 unless done/clean-no-work/running"
echo "  worktree: $WT"
echo "NOTE: nothing reviews this worker's PR — AGENT_SKIP_REVIEW_GATE=1 is exported above, so the"
echo "      PARENT owns the review gate. Hand the PR to the chain when it appears:"
echo "  chain:   bash $HARNESS/chain-merge.sh <repo-path> <owner/repo> <issue> <branch>"
