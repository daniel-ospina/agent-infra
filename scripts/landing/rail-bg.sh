#!/usr/bin/env bash
# rail-bg.sh — run the sanctioned landing rail (`scripts/atomic-land.sh`) in the
# BACKGROUND, then read its real result back from the API.
#
# WHY IN THE BACKGROUND. A foreground rail run outlives a tool-call timeout:
# measured runs of the full unit are 741 s and 43 min (base update → terminal-CI
# wait → record carry-forward → admin-merge). Kicking it off in the background
# and polling keeps the lane responsive while the rail works.
#
# WHY THE `merged=` READ. **A rail exit code is not proof that a landing
# happened.** `atomic-land.sh` once printed "merged" while the PR was still open
# (#1359), and a merge can complete server-side while the command exits non-zero
# (#193). The only proof is `gh api repos/<o>/<r>/pulls/<n> --jq .merged`, which
# is what `wait` and `poll` print.
#
# USAGE
#   rail-bg.sh start <pr> [rail args...]
#       Launch the rail for <pr> with nohup; writes
#       $LAND_LOG_DIR/rail-<pr>.log and $LAND_LOG_DIR/rail-<pr>.pid.
#       Extra args are passed through to atomic-land.sh (e.g. --dry-run --no-wait,
#       or `-- --squash` for admin-merge.sh).
#   rail-bg.sh wait <pr> [max_s]
#       Block until that pid is gone (or max_s, default 1500), print the log tail
#       and the API-confirmed merged state.
#   rail-bg.sh poll [--max s] <pr> [pr...]
#       Wait for every listed rail, then print each one's tail and merged state.
#
# ENV
#   LAND_DIR       the checkout the rail runs in (default: the git top level of
#                  this script's directory). The rail is $LAND_DIR/scripts/atomic-land.sh.
#   LAND_LOG_DIR   where rail logs/pids live (default: $TMPDIR/pi-landing-lane).
#   LAND_REPO      owner/name for the merged-state read (default: `gh repo view`
#                  in LAND_DIR).
#   LAND_POLL_MAX  default max_s for `poll` and `wait` (default: 1500).
#
# Exit: 0 = the requested wait/start completed (this is NOT a landing verdict —
#       read the printed merged= value); 2 = usage or environment error.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAND_DIR="${LAND_DIR:-$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"
LAND_LOG_DIR="${LAND_LOG_DIR:-${TMPDIR:-/tmp}/pi-landing-lane}"
LAND_POLL_MAX="${LAND_POLL_MAX:-1500}"
RAIL="scripts/atomic-land.sh"

usage() {
  # The header comment block, minus the shebang — one place owns the docs.
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} /^[[:space:]]*$/{print; next} {exit}' "$0"
}

die() { printf 'rail-bg: %s\n' "$*" >&2; exit 2; }
# An ARGV-shape error prints the usage too; an environment error (no rail, no log
# dir, no repo) does not — it names the fix instead.
die_usage() { printf 'rail-bg: %s\n\n' "$*" >&2; usage >&2; exit 2; }

log_file() { printf '%s/rail-%s.log' "$LAND_LOG_DIR" "$1"; }
pid_file() { printf '%s/rail-%s.pid' "$LAND_LOG_DIR" "$1"; }

is_numeric() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

resolve_repo() {
  if [ -n "${LAND_REPO:-}" ]; then printf '%s' "$LAND_REPO"; return 0; fi
  local r
  r="$(cd "$LAND_DIR" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  case "$r" in
    */*) printf '%s' "$r" ;;
    *) return 1 ;;
  esac
}

# The ONLY proof of a landing: the API's own merged flag. A failed read is
# UNREADABLE, never "false" — an empty field reads as whatever the parser wants.
merged_value() { # <pr>
  gh api "repos/$1/pulls/$2" --jq .merged 2>/dev/null
}

confirm() { # <pr>
  local repo merged
  repo="$(resolve_repo)" || { printf 'CONFIRMED merged=UNREADABLE reason=unresolved-repo\n'; return 1; }
  merged="$(merged_value "$repo" "$1")"
  case "$merged" in
    true|false) printf 'CONFIRMED merged=%s\n' "$merged" ;;
    *) printf 'CONFIRMED merged=UNREADABLE reason=api-read-failed (repo=%s pr=%s)\n' "$repo" "$1"; return 1 ;;
  esac
  if [ "$merged" = "true" ]; then
    printf 'RECOMMEND: %s LANDED "merged=true %s"\n' "$1" "$(date -u +%H:%M:%SZ)"
  else
    printf 'RECOMMEND: %s REFUSED\n' "$1"
  fi
}

cmd_start() {
  local pr="${1:-}"; shift || true
  [ -n "$pr" ] || die_usage "start needs a PR number"
  is_numeric "$pr" || die_usage "PR must be numeric (got '$pr')"
  [ -f "$LAND_DIR/$RAIL" ] || die "no $RAIL in $LAND_DIR — set LAND_DIR to the checkout holding the rail"
  mkdir -p "$LAND_LOG_DIR" || die "cannot create $LAND_LOG_DIR"
  local log pidf
  log="$(log_file "$pr")"; pidf="$(pid_file "$pr")"
  : > "$log" || die "cannot write $log"
  (
    cd "$LAND_DIR" || exit 2
    nohup bash "$RAIL" "$pr" "$@" >"$log" 2>&1 &
    echo $! >"$pidf"
  )
  printf 'launched rail for %s pid=%s log=%s\n' "$pr" "$(cat "$pidf")" "$log"
}

pid_alive() { # <pr>
  local f
  f="$(pid_file "$1")"
  [ -f "$f" ] || return 1
  kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null
}

cmd_wait() {
  local pr="${1:-}" max="${2:-}"
  [ -n "$pr" ] || die_usage "wait needs a PR number"
  is_numeric "$pr" || die_usage "PR must be numeric (got '$pr')"
  [ -z "$max" ] && max="$LAND_POLL_MAX"
  is_numeric "$max" || die_usage "max_s must be numeric (got '$max')"
  local log start
  log="$(log_file "$pr")"
  start=$SECONDS
  while pid_alive "$pr"; do
    if [ $(( SECONDS - start )) -ge "$max" ]; then
      printf 'STILL RUNNING after %ss — %s\n' "$max" "$(tail -2 "$log" 2>/dev/null | tr '\n' ' ')"
      confirm "$pr" || true
      return 0
    fi
    sleep 15
  done
  printf '── rail finished after %ss ──\n' "$(( SECONDS - start ))"
  tail -30 "$log" 2>/dev/null
  printf 'NOTE: the rail process ending (and its exit code) is NOT proof of a landing — the API read below is.\n'
  confirm "$pr" || true
}

cmd_poll() {
  local max="$LAND_POLL_MAX" prs=() a
  while [ $# -gt 0 ]; do
    case "$1" in
      --max) [ -n "${2:-}" ] || die_usage "--max needs a value"; is_numeric "$2" || die_usage "max_s must be numeric (got '$2')"; max="$2"; shift 2 ;;
      --max=*) a="${1#--max=}"; is_numeric "$a" || die_usage "max_s must be numeric (got '$a')"; max="$a"; shift ;;
      *) prs+=("$1"); shift ;;
    esac
  done
  [ "${#prs[@]}" -gt 0 ] || die_usage "poll needs at least one PR number"
  for a in "${prs[@]}"; do is_numeric "$a" || die_usage "PR must be numeric (got '$a')"; done
  local start alive pr
  start=$SECONDS
  while :; do
    alive=""
    for pr in "${prs[@]}"; do pid_alive "$pr" && alive="$alive $pr"; done
    [ -z "$alive" ] && { printf 'ALL DONE after %ss\n' "$(( SECONDS - start ))"; break; }
    if [ $(( SECONDS - start )) -ge "$max" ]; then
      printf 'STILL RUNNING:%s after %ss\n' "$alive" "$max"
      break
    fi
    sleep 20
  done
  for pr in "${prs[@]}"; do
    printf '════ PR %s ════\n' "$pr"
    tail -14 "$(log_file "$pr")" 2>/dev/null
    confirm "$pr" || true
  done
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  wait)  shift; cmd_wait "$@" ;;
  poll)  shift; cmd_poll "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) printf 'rail-bg: unknown subcommand %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
