#!/usr/bin/env bash
# lane-exec.sh — launch ONE lane so that NO WRAPPER SURVIVES it (#2163).
#
# WHY THIS EXISTS
# The measured launch shape was
#     bash -c 'export PATH=…; cd <repo>; … nohup pi --model … -p "$(cat brief)" > L-<slug>.log 2>&1 &'
# When the turn ends, the wrapper does not necessarily exit, and in every case the backgrounding
# leaves a process the harness cannot account for: on 2026-10-19 the Mac carried 76 `pi`-shaped
# processes for 14 working lanes, and the counting command (`ps | grep -c 'pi --model'`) counted the
# WRAPPER BASH, not `pi`. The fix at the launch site is to remove the wrapper entirely:
#
#     exec pi …            <- this process BECOMES pi; when pi exits there is nothing left to reap
#
# This launcher is the canonical replacement for an ad-hoc `bash -c '… nohup pi … &'`. For lanes that
# genuinely NEED a persistent wrapper (a teardown trap, post-run bookkeeping — that is `lane.sh`),
# the contract is the other half of this issue: the wrapper must `wait` for its child and `exit` on
# child exit (`spawn-gate.sh::run_agent` does exactly that, and reaps the agent's process group
# afterwards so a straggler cannot outlive the turn).
#
# USAGE
#   lane-exec.sh --log <logfile> --brief <promptfile> [-- pi args…]
#   lane-exec.sh --log <logfile> --prompt <text>     [-- pi args…]
#
# The defaults are the fleet's own: `pi -p --provider deepseek --model deepseek-v4-flash --no-session`
# (see spawn-gate.sh::run_agent). Extra args are appended AFTER the defaults, so an operator can add
# `--model …` without rewriting this file; nothing here re-parses `pi`'s flags.
#
# Exit: pi's own status (this shell is replaced by pi). Usage/env errors are 2.
set -u

PROG="lane-exec"
LOG=""
BRIEF=""
PROMPT=""
PI_EXTRA=()

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
lane-exec.sh — launch one lane with `exec pi`, so no wrapper process survives it (#2163).

  lane-exec.sh --log <logfile> --brief <promptfile> [-- <extra pi args…>]
  lane-exec.sh --log <logfile> --prompt <text>      [-- <extra pi args…>]

The process becomes `pi` (exec), so when the turn completes there is nothing left to reap. The
prompt is read from <promptfile> or given inline; the defaults are the fleet's headless invocation:
  pi -p --provider deepseek --model deepseek-v4-flash --no-session
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --log) [ $# -ge 2 ] || die "--log needs a path"; LOG="$2"; shift 2 ;;
    --brief) [ $# -ge 2 ] || die "--brief needs a path"; BRIEF="$2"; shift 2 ;;
    --prompt) [ $# -ge 2 ] || die "--prompt needs a value"; PROMPT="$2"; shift 2 ;;
    --) shift; PI_EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$LOG" ] || die "--log <logfile> is required — without it the lane leaves no evidence a counter or a reaper can read"
[ -n "$BRIEF" ] || [ -n "$PROMPT" ] || die "one of --brief <file> or --prompt <text> is required"
if [ -n "$BRIEF" ]; then
  [ -r "$BRIEF" ] || die "--brief file is not readable: $BRIEF"
fi
case "$LOG" in
  /*) ;;
  *) die "--log must be an ABSOLUTE path (the lane's cwd is the worktree, not the launch dir)" ;;
esac
mkdir -p "$(dirname "$LOG")" 2>/dev/null || die "cannot create the log directory for $LOG"

# The lane's own first line, written BEFORE exec, so the log exists even if pi refuses to start
# (a missing/refused spawn is otherwise indistinguishable from a lane that never launched).
printf '[lane-exec] %s cwd=%s brief=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "${BRIEF:-<inline>}" >> "$LOG"

# ⛔ `exec` IS THE WHOLE POINT — do not wrap this in a function or a subshell, and do not background
# it: either would introduce exactly the surviving wrapper this file exists to remove.
# ⛔ `${arr[@]+"${arr[@]}"}` — bash 3.2 (the interpreter the launchd plist invokes) treats an EMPTY
# array expansion under `set -u` as an unbound variable and aborts. The guard is what makes "no extra
# args" the common case rather than a crash.
if [ -n "$BRIEF" ]; then
  exec pi -p --provider deepseek --model deepseek-v4-flash --no-session ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} "$(cat "$BRIEF")" >> "$LOG" 2>&1 < /dev/null
else
  exec pi -p --provider deepseek --model deepseek-v4-flash --no-session ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} "$PROMPT" >> "$LOG" 2>&1 < /dev/null
fi
