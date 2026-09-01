#!/usr/bin/env bash
# parallel_work_check.sh — deterministic C1-C5 parallel-work / duplicate /
# stale checks (epic #4902, issue #4904).
#
# INTERFACE (plan §6):
#   parallel_work_check.sh <start|scope|plan|implement|merge> \
#       [--repo PATH] [--symbol STRING]
#
# stdout: ONE machine-parseable verdict line — callers parse it, the exit
# code is ALWAYS 0 (including timeouts and infra failures):
#   <C#>: <CLEAR|STALE|OVERLAP|DUP_FIX|UNKNOWN>  [details]  options=<a|b>
#
#   C1 start     fetch → behind-origin via checkout_guard.sh (issue #4905)
#                → closed-issue DUP_FIX → board scan of running cards
#   C2 scope     write touched_paths (#4903 helper) → advisory 72h git
#                history overlap (blocking only with shared-symbol booster,
#                Gate A noise caveat) → blocking LIVE touched_paths overlap
#   C3 plan      open-PR search on touched files → OVERLAP
#   C4 implement fetch + ahead/behind → base_commit ancestry drift →
#                `git log -S` re-check (14d) → DUP_FIX
#   C5 merge     release lease + touched_paths, notify overlapping owners
#                (release_and_notify/release_paths #4903 helpers), write
#                checkpoint_pass + overlap_decision events, advance_phase
#
# UNKNOWN = infra/timeout. The PASS token (default
# /tmp/parallel-check-token.json) is written ONLY on a CLEAR verdict —
# UNKNOWN at a gated checkpoint means NO token and the enforcer gate
# (issue #5039) blocks with retry(2)+override. Phase gates never silently
# pass; advisory reads fail open to CLEAR.
#
# ENV (all injectable — GitHub REST via GH_API_BASE/GH_TOKEN, NEVER the gh
# CLI; board via injectable Supabase REST URL):
#   GH_API_BASE GH_TOKEN PARALLEL_CHECK_REPO_SLUG GH_REPOSITORY
#   PARALLEL_CHECK_SB_URL|SUPABASE_URL_ORG_DATA|SUPABASE_URL
#   PARALLEL_CHECK_SB_KEY|SUPABASE_SERVICE_ROLE_KEY_ORG_DATA|...
#   SWARM_CARD_ID|CARD_ID  AGENT_ID|SWARM_AGENT_ID
#   SWARM_TOUCHED_PATHS|TOUCHED_PATHS  PARALLEL_CHECK_SYMBOL
#   PARALLEL_CHECK_TIMEOUT_SECS (budget, default 2 — overrun → UNKNOWN)
#   PARALLEL_CHECK_TOKEN_FILE (default /tmp/parallel-check-token.json)
#   PARALLEL_CHECK_REPO (repo fallback for --repo)
#   CHECKOUT_GUARD_* passthrough (checkout_guard.sh config)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

phase=""
repo=""
symbol=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        start|scope|plan|implement|merge)
            phase="$1"
            ;;
        --repo)
            repo="${2:-}"
            shift
            ;;
        --symbol)
            symbol="${2:-}"
            shift
            ;;
        *)
            echo "parallel_work_check.sh: unknown argument: $1" >&2
            ;;
    esac
    shift
done

if [ -z "$phase" ]; then
    echo "C?: UNKNOWN  missing-phase  options="
    exit 0
fi

case "$phase" in
    start)     code="C1" ;;
    scope)     code="C2" ;;
    plan)      code="C3" ;;
    implement) code="C4" ;;
    merge)     code="C5" ;;
    *)         code="C?" ;;
esac

# Budget: python enforces PARALLEL_CHECK_TIMEOUT_SECS internally and emits
# UNKNOWN on overrun; this shell watchdog is the hard backstop for a hung
# subprocess (bounded, env-overridable — swarm #196 pattern).
# #383 patch: the watchdog budget is CLAMPED to PARALLEL_CHECK_BUDGET_MAX
# (env, default 60) so an unbounded or non-finite value (inf/nan/1e309)
# cannot stall the watchdog indefinitely (GNU `sleep inf` sleeps forever).
# This .sh clamp is the HARD BACKSTOP and deliberately DIVERGES from the
# python side (which clamps python's OWN deadline — min(float(raw),
# BUDGET_MAX), except (ValueError, OverflowError) → default 60): the regex
# gate maps non-finite raw strings to the default 2.0 (python: inf → 60.0,
# nan → immediate UNKNOWN), the min clamp floors "0" at 0.05 (python: 0.0),
# and a cap > 86400 resets to 60 (python accepts it verbatim). Every
# divergence is fail-closed: the watchdog always fires within a bounded
# window (≤ cap+2s), so a HUNG python is SIGKILLed → fail-closed UNKNOWN,
# never a stall and never a wrongly-passing gate.
budget="${PARALLEL_CHECK_TIMEOUT_SECS:-2}"
budget_max="${PARALLEL_CHECK_BUDGET_MAX:-60}"
budget="$(awk -v b="$budget" -v m="$budget_max" 'BEGIN {
    # Regex-gate the raw strings first: one-true-awk (macOS) leaves "nan"/
    # "inf" as STRINGS that compare lexically ("nan" >= "0" is true), so
    # the numeric NaN test (x != x) is unreliable across awk impls. Only a
    # plain finite decimal literal is accepted; anything else → default.
    # The max cap (m) gets the same gate + a hard ceiling: a non-finite or
    # absurd cap would otherwise let x escape as inf through the compare
    # and re-open the indefinite-stall class.
    if (b ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/) x = b + 0;
    else x = -1;                       # non-numeric → default below
    if (m ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/) m = m + 0;
    else m = 60;                       # non-numeric cap → default
    if (!(m > 0) || m > 86400) m = 60; # inf/overflow/negative/absurd cap → default
    if (!(x >= 0) || x > m) x = (x > 0) ? m : 2;  # NaN/negative → default; overflow → max
    if (x < 0.05) x = 0.05;            # min clamp ("0" → fast watchdog)
    printf "%.1f", x }' 2>/dev/null || echo "2.0")"
watchdog_s="$(awk -v b="$budget" 'BEGIN { printf "%.1f", b + 2.0 }' 2>/dev/null \
    || echo "4.0")"

# #383 patch: the token path must be resolved here too — the error branch
# unlinks it (see below).
token_file="${PARALLEL_CHECK_TOKEN_FILE:-/tmp/parallel-check-token.json}"

tmp_out="$(mktemp "${TMPDIR:-/tmp}/parallel-check-out.XXXXXX")"

args=("$phase")
[ -n "$repo" ] && args+=(--repo "$repo")
[ -n "$symbol" ] && args+=(--symbol "$symbol")

set +e
# #383 patch: run python in its own process group (setsid, Linux/CI) so the
# watchdog can kill the WHOLE tree — a hung `git fetch` subprocess must die
# with python instead of orphaning (macOS lacks setsid → plain kill; the
# orphan corner is documented in VENDOR.md).
# #391: each watchdog subshell redirects its stdio to /dev/null — on macOS
# bash 3.2 `kill "$watchdog_pid"` below kills the subshell but ORPHANS its
# `sleep` child, which would otherwise hold the caller's stdout/stderr pipe
# open until the full watchdog timer (budget+2.0s) elapses, so every
# invocation under pipe capture blocked for budget+2.0s. Redirecting the
# subshell's fds means the orphaned `sleep` holds /dev/null instead, and the
# caller's pipe closes as soon as the script exits.
if command -v setsid >/dev/null 2>&1; then
    setsid "$PYTHON_BIN" "$SCRIPT_DIR/parallel_work_check.py" "${args[@]}" \
        >"$tmp_out" 2>/dev/null &
    pid=$!
    ( sleep "$watchdog_s"; kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
else
    "$PYTHON_BIN" "$SCRIPT_DIR/parallel_work_check.py" "${args[@]}" \
        >"$tmp_out" 2>/dev/null &
    pid=$!
    ( sleep "$watchdog_s"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
fi
watchdog_pid=$!
wait "$pid"
rc=$?
kill "$watchdog_pid" 2>/dev/null || true
set -e

out="$(head -n 1 "$tmp_out" 2>/dev/null || true)"
rm -f "$tmp_out"

if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # #383 patch: a watchdog SIGKILL skips python's own cleanup — a stale
    # CLEAR token would otherwise survive and the enforcer's marker advance
    # would pass a check the operator just saw fail. Unlink the token AND
    # the checker's own tmp files, scoped to the token's prefix — an
    # unscoped `*.tmp.*` glob in /tmp would delete unrelated same-user tmp
    # files and a concurrent invocation's in-flight unique tmp.
    rm -f "$token_file" "$(dirname "$token_file")/$(basename "$token_file")"*.tmp.* 2>/dev/null || true
    echo "$code: UNKNOWN  check-timeout-or-error rc=$rc  options="
else
    # #383 patch: UNKNOWN verdicts exit 0 by design — the token must not
    # survive a non-CLEAR verdict either (the enforcer marker advance reads
    # only the token file, never the verdict line).
    case "$out" in
        *": CLEAR"*) ;;
        *) rm -f "$token_file" 2>/dev/null || true ;;
    esac
    echo "$out"
fi

# Callers parse the verdict line, never the exit code.
exit 0
