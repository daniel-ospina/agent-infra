#!/usr/bin/env bash
# rail-bg.sh — the landing-lane CLI over the fleet's ONE background-rail instrument.
#
# WHAT CHANGED AND WHY (agent-infra#2905, and AGENTS.md's recorded rule)
# ──────────────────────────────────────────────────────────────────────
# This script used to DERIVE a rail verdict itself: it kept its own pid file per PR, decided liveness
# with `kill -0`, read `gh api …/pulls/<n> --jq .merged` itself, and printed
# `RECOMMEND: <pr> REFUSED|LANDED` from those reads. `scripts/rail-run.sh` derives the same question
# from richer evidence (the recorded exit status, the recorder's and the rail's incarnations via
# `scripts/lib/pid-identity.sh`, the log, and the PR's own state) and answers it with eight states and
# distinct exit codes.
#
# Two instruments answering one question with two verdict rules is the defect — AGENTS.md:
# *"One verdict function, never a second."* So this file is now a THIN CLI: it launches the rail
# through `rail-run.sh`, polls `rail-run.sh status`, and prints a recommendation TRANSCRIBED from
# rail-run's own exit code and state row. It derives no verdict, reads no liveness, and makes no API
# call of its own — `scripts/landing/rail-bg.test.sh` fails if any of those come back.
#
# The capability #1549 introduced is preserved, not dropped: this CLI still drives
# `scripts/atomic-land.sh` (the full landing unit — base update, CI wait, record carry-forward, then
# admin-merge), which is why it exists at all, and it still prints the API-confirmed `merged=` value —
# read from rail-run's recorded artifact, never invented here.
#
# WHY IN THE BACKGROUND. A foreground rail run outlives a tool-call timeout: measured runs of the full
# unit are 741 s and 43 min. `rail-run.sh` starts it in its own session and returns immediately.
#
# USAGE
#   rail-bg.sh start <pr> [rail args...]
#       Launch atomic-land.sh for <pr> through rail-run.sh; prints rail-run's own start block (run id,
#       log path, the exact status command). Returns at once.
#   rail-bg.sh wait <pr> [max_s]
#       Poll rail-run until the run leaves `running` (or max_s, default 1500), then print rail-run's
#       row verbatim plus CONFIRMED/RECOMMEND lines. A bound is not a verdict: `running` at the bound
#       is reported PENDING, never REFUSED.
#   rail-bg.sh poll [--max s] <pr> [pr...]
#       The same over several PRs.
#
# ENV
#   LAND_DIR       the checkout the rail runs in (default: the git top level of this script's
#                  directory). The rail is $LAND_DIR/scripts/atomic-land.sh (or LAND_RAIL).
#   LAND_REPO      [HOST/]owner/name — the identity passed to rail-run with `--repo`, which also keys
#                  its run state. Default: `gh repo view` in LAND_DIR. A failed resolve is an
#                  environment error, never a guess.
#   LAND_RAIL      the rail executable (default: $LAND_DIR/scripts/atomic-land.sh)
#   LAND_POLL_MAX  default max_s for `wait`/`poll` (default: 1500); must be numeric
#   LAND_LOG_DIR   where this CLI remembers WHICH run it started ($LAND_LOG_DIR/rail-<pr>.run), so a
#                  `wait` polls its own run and never a newer one (default: $TMPDIR/pi-landing-lane)
#   RAIL_RUN_SH    the rail-run.sh to delegate to (default: the one beside this script's repo)
#
# Exit: 0 = landed · 2 = usage or environment error · 3 = a live run already holds <pr> · otherwise
#       rail-run's own state code (10 running · 20 refused · 21 killed · 22 gone-without-verdict ·
#       23 exited-zero · 24 no-run · 25 unknown). Read the printed CONFIRMED/RECOMMEND lines; the
#       exit code IS rail-run's, unmodified.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAND_DIR="${LAND_DIR:-$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"
LAND_POLL_MAX="${LAND_POLL_MAX:-1500}"
LAND_LOG_DIR="${LAND_LOG_DIR:-${TMPDIR:-/tmp}/pi-landing-lane}"
RAIL="${LAND_RAIL:-$LAND_DIR/scripts/atomic-land.sh}"
# The delegate. Default: the rail-run.sh in this repo (scripts/landing/../rail-run.sh). The seam
# exists because the suite must exercise the delegation without a real rail or a real `gh`.
RAIL_RUN="${RAIL_RUN_SH:-$SELF_DIR/../rail-run.sh}"
# Resolved once per invocation by resolve_repo; empty until then (never read before it is set).
REPO=""

usage() {
  # The header comment block, minus the shebang — one place owns the docs.
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} /^[[:space:]]*$/{print; next} {exit}' "$0"
}

die() { printf 'rail-bg: %s\n' "$*" >&2; exit 2; }
# An ARGV-shape error prints the usage too; an environment error (no rail, no identity, no delegate)
# does not — it names the fix instead.
die_usage() { printf 'rail-bg: %s\n\n' "$*" >&2; usage >&2; exit 2; }

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

# WHICH RUN THIS CLI STARTED. Bookkeeping only — no verdict lives here. rail-run already refuses a
# second live run for the same PR, so this is what keeps `wait` pointed at the run it launched rather
# than at whatever is newest when it happens to poll.
run_file() { printf '%s/rail-%s.run' "$LAND_LOG_DIR" "$1"; }
recorded_run() { local f; f="$(run_file "$1")"; [ -s "$f" ] && tr -d '\r\n' < "$f" 2>/dev/null || true; }

# The run id from rail-run's `started pr=<n> run=<id> …` line. Absent is ABSENT — an unparsed id
# leaves `wait` on rail-run's documented "newest run" behaviour rather than inventing one.
parse_run_id() {
  printf '%s\n' "$1" | awk 'NR==1{for(i=1;i<=NF;i++){if(index($i,"run=")==1){print substr($i,5); exit}}}'
}

# rr_status <pr> — one `rail-run.sh status` call. Prints rail-run's output verbatim on stdout; the
# return value is rail-run's state code, which is the ONLY thing this script classifies by.
rr_status() {
  local pr="$1" runid
  runid="$(recorded_run "$pr")"
  if [ -n "$runid" ]; then
    bash "$RAIL_RUN" status "$pr" --repo "$REPO" --run "$runid"
  else
    bash "$RAIL_RUN" status "$pr" --repo "$REPO"
  fi
}

# ── reading rail-run's own row (transcription, not derivation) ─────────────────
row_state() { # <rail-run output> -> the state word
  printf '%s\n' "$1" | awk '/^[a-z][a-z-]* pr=/{print $1; exit}'
}
row_field() { # <rail-run output> <key>
  printf '%s\n' "$1" | awk -v k="$2" '/^[a-z][a-z-]* pr=/{for(i=1;i<=NF;i++){if(index($i,k"=")==1){print substr($i,length(k)+2); exit}}}'
}

# The state each exit code MEANS, per rail-run.sh's own documented contract. Used only to check that
# the code and the row agree — a disagreement is reported as UNKNOWN, never resolved in favour of the
# friendlier side (a false PASS is the failure #1549 exists to prevent).
state_for_rc() {
  case "$1" in
    0) printf 'landed' ;; 10) printf 'running' ;; 20) printf 'refused' ;; 21) printf 'killed' ;;
    22) printf 'gone-without-verdict' ;; 23) printf 'exited-zero' ;; 24) printf 'no-run' ;;
    25) printf 'unknown' ;; *) printf '' ;;
  esac
}

# report <pr> <rail-run rc> <rail-run output> — the row verbatim, then two transcribed lines.
report() {
  local pr="$1" rc="$2" out="$3" state want merged prstate
  state="$(row_state "$out")"
  merged="$(row_field "$out" merged)"
  prstate="$(row_field "$out" pr_state)"
  want="$(state_for_rc "$rc")"

  printf '%s\n' "$out"

  # ⛔ THE API-CONFIRMED MERGED VALUE, FROM RAIL-RUN'S RECORDED READ. `true` only for a merge the
  # artifact read observed; `false` only when the read returned a PR state; anything else is
  # UNREADABLE, because an empty field would read as whatever the caller's parser wants (#1549).
  case "$merged" in
    [0-9][0-9][0-9][0-9]-*) printf 'CONFIRMED merged=true\n' ;;
    -) case "$prstate" in
         MERGED|OPEN|CLOSED) printf 'CONFIRMED merged=false\n' ;;
         *) printf 'CONFIRMED merged=UNREADABLE reason=pr-state-unread\n' ;;
       esac ;;
    '') printf 'CONFIRMED merged=UNREADABLE reason=no-read\n' ;;
    *) printf 'CONFIRMED merged=UNREADABLE reason=unexpected-field merged=%s\n' "$merged" ;;
  esac

  # ⛔ THE RECOMMENDATION IS A RENAME OF RAIL-RUN'S VERDICT, NEVER A SECOND OPINION. A code and a row
  # that disagree, or a code that is not in rail-run's table, is UNKNOWN — it can never land here as
  # LANDED/REFUSED. (Code 3 = "a live run already holds this PR"; 2 = usage.)
  if [ -z "$want" ] || { [ -n "$state" ] && [ "$state" != "$want" ]; }; then
    printf 'RECOMMEND: %s UNKNOWN (rc=%s state=%s — rail-run'"'"'s code and row disagree; resolve before acting)\n' \
      "$pr" "$rc" "${state:-absent}"
    return 0
  fi
  case "$want" in
    landed)  printf 'RECOMMEND: %s LANDED "merged=true"\n' "$pr" ;;
    running) printf 'RECOMMEND: %s PENDING (rail still running — no outcome yet, NOT a refusal)\n' "$pr" ;;
    refused) printf 'RECOMMEND: %s REFUSED\n' "$pr" ;;
    killed)  printf 'RECOMMEND: %s KILLED (signal death — never a refusal; read the row'"'"'s rc)\n' "$pr" ;;
    gone-without-verdict) printf 'RECOMMEND: %s NO-VERDICT (this run produced no verdict and is not a landing; re-run the rail)\n' "$pr" ;;
    exited-zero) printf 'RECOMMEND: %s EXITED-ZERO-NOT-LANDED (the PR is not merged)\n' "$pr" ;;
    no-run)  printf 'RECOMMEND: %s NO-RUN (nothing was started for this PR)\n' "$pr" ;;
    *)       printf 'RECOMMEND: %s UNKNOWN (an evidence read abstained — read the reason lines above, then re-poll)\n' "$pr" ;;
  esac
}

cmd_start() {
  local pr="${1:-}"; shift || true
  [ -n "$pr" ] || die_usage "start needs a PR number"
  is_numeric "$pr" || die_usage "PR must be numeric (got '$pr')"
  [ -f "$RAIL" ] || die "no rail at $RAIL — set LAND_DIR to the checkout holding scripts/atomic-land.sh, or LAND_RAIL"
  [ -f "$RAIL_RUN" ] || die "no rail-run.sh at $RAIL_RUN — set RAIL_RUN_SH to the fleet's scripts/rail-run.sh"
  REPO="$(resolve_repo)" || die "cannot tell which repository PR $pr belongs to — set LAND_REPO owner/repo (gh repo view in $LAND_DIR returned nothing)"
  mkdir -p "$LAND_LOG_DIR" || die "cannot create $LAND_LOG_DIR"

  local out rc runid
  # `--repo` FIRST, so a caller that passes its own later value wins (rail-run scans left to right and
  # forwards every pair). RAIL_RUN_RAIL points rail-run at the FULL landing unit #1549 asks for.
  out="$(RAIL_RUN_RAIL="$RAIL" bash "$RAIL_RUN" start "$pr" --repo "$REPO" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || return "$rc"
  runid="$(parse_run_id "$out")"
  if [ -n "$runid" ]; then
    printf '%s\n' "$runid" > "$(run_file "$pr")"
  else
    rm -f "$(run_file "$pr")"
    printf 'NOTE: rail-run printed no run id, so `wait`/`poll` will read its NEWEST run for %s.\n' "$pr" >&2
  fi
  return 0
}

cmd_wait() {
  local pr="${1:-}" max="${2:-}"
  [ -n "$pr" ] || die_usage "wait needs a PR number"
  is_numeric "$pr" || die_usage "PR must be numeric (got '$pr')"
  [ -z "$max" ] && max="$LAND_POLL_MAX"
  is_numeric "$max" || die_usage "max_s must be numeric (got '$max')"
  REPO="$(resolve_repo)" || die "cannot tell which repository PR $pr belongs to — set LAND_REPO owner/repo"

  local out rc start state
  start=$SECONDS
  # One status read BEFORE the bound is checked, so `max_s=0` means "read once", not "never read".
  while :; do
    out="$(rr_status "$pr" 2>&1)"; rc=$?
    state="$(row_state "$out")"
    # Only rail-run's own `running` continues the wait. Every other state — including `unknown` — is
    # an answer this CLI has no business extending.
    if [ "$state" != "running" ] && [ "$rc" != "10" ]; then break; fi
    if [ $(( SECONDS - start )) -ge "$max" ]; then
      printf 'STILL RUNNING after %ss\n' "$max"
      report "$pr" "$rc" "$out"
      return "$rc"
    fi
    sleep 15
  done
  printf '── rail-run state after %ss ──\n' "$(( SECONDS - start ))"
  report "$pr" "$rc" "$out"
  return "$rc"
}

cmd_poll() {
  local max="$LAND_POLL_MAX" prs=() a
  is_numeric "$max" || die_usage "LAND_POLL_MAX must be numeric (got '$max')"
  while [ $# -gt 0 ]; do
    case "$1" in
      --max) [ -n "${2:-}" ] || die_usage "--max needs a value"; is_numeric "$2" || die_usage "max_s must be numeric (got '$2')"; max="$2"; shift 2 ;;
      --max=*) a="${1#--max=}"; is_numeric "$a" || die_usage "max_s must be numeric (got '$a')"; max="$a"; shift ;;
      *) prs+=("$1"); shift ;;
    esac
  done
  [ "${#prs[@]}" -gt 0 ] || die_usage "poll needs at least one PR number"
  for a in "${prs[@]}"; do is_numeric "$a" || die_usage "PR must be numeric (got '$a')"; done
  REPO="$(resolve_repo)" || die "cannot tell which repository these PRs belong to — set LAND_REPO owner/repo"

  local start=$SECONDS pr out rc alive worst=0
  while :; do
    alive=""
    for pr in "${prs[@]}"; do
      out="$(rr_status "$pr" 2>&1)"; rc=$?
      if [ "$(row_state "$out")" = "running" ] || [ "$rc" = "10" ]; then alive="$alive $pr"; fi
    done
    [ -z "$alive" ] && { printf 'ALL SETTLED after %ss\n' "$(( SECONDS - start ))"; break; }
    if [ $(( SECONDS - start )) -ge "$max" ]; then
      printf 'STILL RUNNING:%s after %ss\n' "$alive" "$max"
      break
    fi
    sleep 20
  done
  # Report EVERY PR, including the settled ones, from a fresh read at report time — a value carried
  # over from the loop above would be a stale sample described as current.
  for pr in "${prs[@]}"; do
    printf '════ PR %s ════\n' "$pr"
    out="$(rr_status "$pr" 2>&1)"; rc=$?
    report "$pr" "$rc" "$out"
    [ "$rc" -gt "$worst" ] && worst="$rc"
  done
  return "$worst"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  wait)  shift; cmd_wait "$@" ;;
  poll)  shift; cmd_poll "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) printf 'rail-bg: unknown subcommand %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
