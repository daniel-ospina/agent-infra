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
# The defaults are the fleet's own, RESOLVED the way `spawn-gate.sh::run_agent` resolves them
# (`${PI_LANE_PROVIDER:-deepseek}` / `${PI_LANE_MODEL:-deepseek-flash}`) and logged before `exec`,
# so an ambient override cannot change which model ran without leaving a line that says so
# (agent-infra#2208). Extra args are appended AFTER the defaults, so an operator can add
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
prompt is read from <promptfile> or given inline; the defaults are the fleet's headless invocation,
resolved from `PI_LANE_PROVIDER`/`PI_LANE_MODEL` (defaults `deepseek` / `deepseek-flash`):
  pi -p --provider "$PI_LANE_PROVIDER" --model "$PI_LANE_MODEL" --no-session
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

# ⛔ THE RESOLVED MODEL IS NAMED IN THE LOG (agent-infra#2208). Resolve ONCE into locals here, for the
# SAME reason `spawn-gate.sh::run_agent` does: an ambient `PI_LANE_MODEL`/`PI_LANE_PROVIDER` (shell,
# `keys.env` sourced with `set -a`, the tmux server) otherwise changes the model for every lane with
# no log line that says so, and a lane must not run a different model than its reviewer (merge-one.sh
# resolves the identical pair). Resolving into locals also keeps the log and the argv from drifting.
lane_provider="${PI_LANE_PROVIDER:-deepseek}" lane_model="${PI_LANE_MODEL:-deepseek-flash}"
printf '[agent] provider=%s model=%s label=lane-exec\n' "$lane_provider" "$lane_model" >> "$LOG"

# ── THE UV PIN, BEFORE THE `exec` (agent-infra#2159) ────────────────────────────────────────────
# `lane-exec.sh` execs `pi` directly (it does NOT route through `run_agent()`), and it is a LANE
# launcher — the one such path that can materialise a per-worktree `.venv`. So it needs the pin in its
# own right: without it a lane here inherits `UV_LINK_MODE`/`UV_CACHE_DIR` from the ambient env, and
# `uv`'s default link mode is `clone` — a full copy on a filesystem that cannot clone. Measured
# 2026-11-03: both unset on pi-cell-1 and pi-cell-4, ambient and after `keys.env`.
# ⛔ NO BASE HOME, NO CACHE PIN. With `HOME` and `CELL_HOME` both empty, `uv_env_apply ""` resolves to
# `/.cache/uv` — a root-level cache nobody created. Skipping the apply leaves uv's own default, which
# is the pre-change behaviour.
# ⛔ AND IT MUST NOT BE ABLE TO CHANGE WHAT RUNS: every step degrades (`|| true`), because this file's
# contract is that it execs the agent — a missing helper is not a reason to fail a lane.
# ⛔ EVERY SKIP PATH IS LOUD, INCLUDING THE ONES THAT SKIP. The first cut of this block only logged on
# the SUCCESS path while its own comment claimed "the log says why" on the skip paths — a claim about a
# log line that did not exist, which is the defect class this file's neighbours name ("a comment
# claiming a guard that does not exist reads exactly like one that does"). Silence also cannot say
# WHICH cause fired, and from the operator's side silence is indistinguishable from an older harness
# that has no block at all. So each skip arm names itself, exactly as `spawn-gate.sh`'s seam does.
_uvdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _uvdir=""
_uvbase="${CELL_HOME:-${HOME:-}}"
if [ -z "$_uvdir" ] || [ ! -r "$_uvdir/uv-env.sh" ]; then
  printf '[uv-env] WARN lane-exec: uv-env.sh not readable beside this helper (looked in %s) — this lane runs with NO cache/link-mode pin, so a venv it creates may be a full copy (#2159). Redeploy the harness.\n' "${_uvdir:-unresolved}" >> "$LOG"
elif [ -z "$_uvbase" ]; then
  printf '[uv-env] WARN lane-exec: neither CELL_HOME nor HOME is set, so there is no base to resolve a cache under — this lane runs with NO pin (uv own default). Not applying a root-level /.cache/uv.\n' >> "$LOG"
else
  # shellcheck source=/dev/null
  . "$_uvdir/uv-env.sh" 2>/dev/null || true
  if command -v uv_env_apply >/dev/null 2>&1; then
    uv_env_apply "$_uvbase" 2>/dev/null || true
    export UV_CACHE_DIR UV_LINK_MODE
    printf '[uv-env] link_mode=%s cache_dir=%s defaulted=%s\n' "${UV_LINK_MODE:-<unset>}" "${UV_CACHE_DIR:-<unset>}" "${UV_ENV_DEFAULTED:-none}" >> "$LOG"
  else
    printf '[uv-env] WARN lane-exec: uv-env.sh is readable but defines no uv_env_apply (a truncated or version-skewed copy) — this lane runs with NO pin (#2159). Redeploy the harness.\n' >> "$LOG"
  fi
fi

# ⛔ `exec` IS THE WHOLE POINT — do not wrap this in a function or a subshell, and do not background
# it: either would introduce exactly the surviving wrapper this file exists to remove.
# ⛔ `${arr[@]+"${arr[@]}"}` — bash 3.2 (the interpreter the launchd plist invokes) treats an EMPTY
# array expansion under `set -u` as an unbound variable and aborts. The guard is what makes "no extra
# args" the common case rather than a crash.
if [ -n "$BRIEF" ]; then
  exec pi -p --provider "$lane_provider" --model "$lane_model" --no-session ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} "$(cat "$BRIEF")" >> "$LOG" 2>&1 < /dev/null
else
  exec pi -p --provider "$lane_provider" --model "$lane_model" --no-session ${PI_EXTRA[@]+"${PI_EXTRA[@]}"} "$PROMPT" >> "$LOG" 2>&1 < /dev/null
fi
