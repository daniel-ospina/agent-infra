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
#   LAND_LOG_DIR   where this CLI remembers WHICH run it started
#                  ($LAND_LOG_DIR/rail-<hex(identity)>-<pr>.run — keyed by identity AND PR, because
#                  rail-run's own store is), so a `wait` polls its own run and never a newer one, on
#                  any repo (default: $TMPDIR/pi-landing-lane)
#   RAIL_RUN_SH    the rail-run.sh to delegate to (default: the one beside this script's repo)
#
# Exit: 0 = landed · 2 = usage or environment error · 3 = a live run already holds <pr> · 5 = the
#       launch did not start (rail-run could not record a pid) · 78 = rail-run's identity library is
#       missing (it refuses to guess liveness) · otherwise rail-run's own state code (10 running ·
#       20 refused · 21 killed · 22 gone-without-verdict · 23 exited-zero · 24 no-run · 25 unknown).
#       `start`/`wait` exit with rail-run's own code, with two stated divergences:
#         (i) a RETRACTION — a row exists but the code and its state disagree — exits 25 (rail-run's own
#             abstention), never the retracted 0/20;
#        (ii) rail-run exiting with NO row at all (`2`/`3`/`5`/`78`) is reported as `ERROR` and keeps
#             ITS code, so a partial install (78 = pid-identity.sh missing) still names itself.
#       `poll` exits with the MOST PESSIMISTIC of the per-PR codes — a multi-item answer needs one code,
#       and the most pessimistic is the only one where a single abstention cannot be masked by a landing
#       beside it. Read the printed CONFIRMED/RECOMMEND lines as well as the code.
#
#   The repo identity is LAND_REPO and nothing else: `start` refuses a `--repo` argument, because the
#   identity keys rail-run's run state and `wait`/`poll` take no `--repo` — so two ways to spell it
#   would let `start` and `wait` disagree about which run is being polled.
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
# ⛔ THE KEY MUST BE NO COARSER THAN THE RECORD IT NAMES (fresh-review finding F2 on #3923, #729's
# lesson). rail-run keys its run state on (repo, PR); a PR-only filename here shared ONE binding
# between two identities on a box whose `LAND_LOG_DIR` is the shared default, so `wait` polled repo B's
# run id under repo A's identity and printed `NO-RUN (nothing was started for this PR)` while A's rail
# was running. The slug is HEX-encoded rather than `/`→`-` mapped because that mapping is NOT
# injective (`a/b-c` and `a-b/c` collide) and this key has to be.
run_file() {
  printf '%s/rail-%s-%s.run' "$LAND_LOG_DIR" "$(printf '%s' "$REPO" | od -An -tx1 | tr -d ' \n')" "$1"
}
recorded_run() { local f; f="$(run_file "$1")"; [ -s "$f" ] && tr -d '\r\n' < "$f" 2>/dev/null || true; }

# The run id from rail-run's `started pr=<n> run=<id> …` line. Scanned over the WHOLE stream, not
# `NR==1`: rail-run's output is merged with stderr, so a warning printed before the start line would
# otherwise cost the id (fresh-review note on #3923). Absent stays ABSENT — an unparsed id leaves
# `wait` on rail-run's documented "newest run" behaviour rather than inventing one.
parse_run_id() {
  printf '%s\n' "$1" | awk '/^started pr=/{for(i=1;i<=NF;i++){if(index($i,"run=")==1){print substr($i,5); exit}}}'
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
# RETURNS THE EFFECTIVE EXIT CODE. Normally that is rail-run's `$rc`, unchanged. Two cases diverge, and
# they must not be confused with each other (fresh-review findings F1/F2 on #3923, round 4):
#   * NO ROW AT ALL — rail-run exited before printing one (its own `78` for a missing
#     `scripts/lib/pid-identity.sh`, `2`/`3`/`5` for a refused invocation or a dead launch). There is
#     nothing to transcribe, so the code is NOT retracted: it is reported as an `ERROR` line naming
#     what that code means, and returned as itself. Calling this a "code and row disagree" blamed the
#     tool for the caller's environment and collapsed `78` to `25`, on the one path a partial install
#     is supposed to be named.
#   * A RETRACTION — a row exists but the code and its state disagree, or the code is outside
#     rail-run's table. Then `25` (rail-run's own abstention) is returned, never the retracted 0/20:
#     exiting `LANDED`/`REFUSED` while printing UNKNOWN is the false-PASS and #2412 abandon shape in
#     the signal lanes actually branch on.
report() {
  local pr="$1" rc="$2" out="$3" state want merged prstate confirmed reason why
  state="$(row_state "$out")"
  merged="$(row_field "$out" merged)"
  prstate="$(row_field "$out" pr_state)"
  want="$(state_for_rc "$rc")"

  printf '%s\n' "$out"

  # ⛔ ABSENCE IS NOT A VERDICT (AGENTS.md) — and it is not a disagreement either. Checked BEFORE the
  # transcription, because a missing row means there is no `merged=`/`pr_state=` to read at all.
  if [ -z "$state" ]; then
    case "$rc" in
      2)  why="rail-run reported a usage/configuration error" ;;
      3)  why="a live run already holds this PR" ;;
      5)  why="the launch did not start (rail-run could not record a pid)" ;;
      78) why="rail-run refused to guess liveness: scripts/lib/pid-identity.sh is missing" ;;
      *)  why="rail-run produced no state row, so there is nothing to transcribe" ;;
    esac
    printf 'RECOMMEND: %s ERROR (rc=%s — %s)\n' "$pr" "$rc" "$why"
    case "$rc" in
      2|3|5|78) return "$rc" ;;
      *) return 25 ;;
    esac
  fi

  # ⛔ ONE TRANSCRIPTION, ONE VALUE, USED BY BOTH LINES BELOW — so `CONFIRMED` and `RECOMMEND`
  # cannot disagree. An earlier version hardcoded the recommendation's `merged=true`, which meant a
  # row whose `merged=` field was absent or unreadable printed `CONFIRMED merged=UNREADABLE` directly
  # above `RECOMMEND: … LANDED "merged=true"`: the one value a merge-duty lane is told to count on was
  # the one value never read (fresh-review finding F1 on #3923, the false-PASS direction #1549 exists
  # to prevent).
  # ⛔ AND `MERGED` AS A *PR STATE* IS AN OBSERVED MERGE. `merged=` is `.mergedAt // "-"`, which is
  # schema-nullable, so `pr_state=MERGED` with `merged=-` is legal — and reading that pair as
  # `merged=false` inverted the answer (finding F2). A state that says MERGED is `true`, never `false`.
  confirmed=""; reason=""
  case "$merged" in
    [0-9][0-9][0-9][0-9]-*) confirmed=true ;;
    -) case "$prstate" in
         MERGED) confirmed=true ;;
         OPEN|CLOSED) confirmed=false ;;
         *) confirmed=UNREADABLE; reason=pr-state-unread ;;
       esac ;;
    '') confirmed=UNREADABLE; reason=no-read ;;
    *) confirmed=UNREADABLE; reason=unexpected-field ;;
  esac
  if [ "$confirmed" = UNREADABLE ]; then
    printf 'CONFIRMED merged=UNREADABLE reason=%s\n' "$reason"
  else
    printf 'CONFIRMED merged=%s\n' "$confirmed"
  fi

  # ⛔ THE RECOMMENDATION IS A RENAME OF RAIL-RUN'S VERDICT, NEVER A SECOND OPINION. A row that
  # disagrees with the code, or a code that is not in rail-run's table, is UNKNOWN — it can never land
  # here as LANDED/REFUSED.
  if [ -z "$want" ] || [ "$state" != "$want" ]; then
    printf 'RECOMMEND: %s UNKNOWN (rc=%s state=%s — rail-run'"'"'s code and row disagree; resolve before acting)\n' \
      "$pr" "$rc" "${state:-absent}"
    return 25
  fi
  case "$want" in
    landed)  printf 'RECOMMEND: %s LANDED "merged=%s"\n' "$pr" "$confirmed" ;;
    running) printf 'RECOMMEND: %s PENDING (rail still running — no outcome yet, NOT a refusal)\n' "$pr" ;;
    refused) printf 'RECOMMEND: %s REFUSED\n' "$pr" ;;
    killed)  printf 'RECOMMEND: %s KILLED (signal death — never a refusal; read the row'"'"'s rc)\n' "$pr" ;;
    gone-without-verdict) printf 'RECOMMEND: %s NO-VERDICT (this run produced no verdict and is not a landing; re-run the rail)\n' "$pr" ;;
    exited-zero) printf 'RECOMMEND: %s EXITED-ZERO-NOT-LANDED (the PR is not merged)\n' "$pr" ;;
    no-run)  printf 'RECOMMEND: %s NO-RUN (nothing was started for this PR)\n' "$pr" ;;
    *)       printf 'RECOMMEND: %s UNKNOWN (an evidence read abstained — read the reason lines above, then re-poll)\n' "$pr" ;;
  esac
  # A landing whose own recorded read does not confirm it is reported, not smoothed over: the state
  # word is rail-run's, the `merged=` value is what the artifact read actually said, and the lane is
  # told which one to count on.
  if [ "$want" = landed ] && [ "$confirmed" != true ]; then
    printf 'NOTE: rail-run reports `landed` but its recorded merged= field does not read true (%s) — count a landing only on an observed merged=true\n' "$confirmed"
  fi
  return "$rc"
}

cmd_start() {
  local pr="${1:-}"; shift || true
  [ -n "$pr" ] || die_usage "start needs a PR number"
  is_numeric "$pr" || die_usage "PR must be numeric (got '$pr')"
  # ⛔ ONE IDENTITY, AND THIS CLI OWNS IT. rail-run keys its run state on the `--repo` it is given, so
  # a caller-supplied `--repo` here would key the run under THAT slug while `wait`/`poll` — which have
  # no `--repo` argument — resolve `LAND_REPO` and poll a different key, answering `no-run` for a run
  # this CLI just started (fresh-review finding F2 on #3923). Refusing the override keeps identity in
  # one place instead of recording a second copy of it.
  local a
  for a in "$@"; do
    case "$a" in
      --) break ;;
      --repo|--repo=*)
        die_usage "start does not take --repo: this CLI's identity comes from LAND_REPO (and keys the run state, so start and wait cannot disagree). Set LAND_REPO=<owner/repo> instead" ;;
    esac
  done
  [ -f "$RAIL" ] || die "no rail at $RAIL — set LAND_DIR to the checkout holding scripts/atomic-land.sh, or LAND_RAIL"
  [ -f "$RAIL_RUN" ] || die "no rail-run.sh at $RAIL_RUN — set RAIL_RUN_SH to the fleet's scripts/rail-run.sh"
  REPO="$(resolve_repo)" || die "cannot tell which repository PR $pr belongs to — set LAND_REPO owner/repo (gh repo view in $LAND_DIR returned nothing)"
  mkdir -p "$LAND_LOG_DIR" || die "cannot create $LAND_LOG_DIR"

  local out rc runid
  # RAIL_RUN_RAIL points rail-run at the FULL landing unit #1549 asks for. `--repo "$REPO"` is the ONE
  # identity (see the refusal above), so `start` and `wait` key the same run by construction.
  out="$(RAIL_RUN_RAIL="$RAIL" bash "$RAIL_RUN" start "$pr" --repo "$REPO" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  # A launch that did not happen must not leave an EARLIER run's id bound to this PR: `wait` would
  # then poll that run and report it under this call's name. Clear it FIRST, write it only on success
  # (fresh-review findings on #3923; both halves are pinned by the suite).
  rm -f "$(run_file "$pr")"
  [ "$rc" -eq 0 ] || return "$rc"
  runid="$(parse_run_id "$out")"
  if [ -n "$runid" ]; then
    printf '%s\n' "$runid" > "$(run_file "$pr")"
  else
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
      return $?
    fi
    sleep 15
  done
  printf '── rail-run state after %ss ──\n' "$(( SECONDS - start ))"
  report "$pr" "$rc" "$out"
  return $?
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

  local start=$SECONDS pr out rc rrc alive worst=0
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
    # The per-PR EFFECTIVE code (a retracted one is 25), and the aggregate is the MOST PESSIMISTIC of
    # them: a multi-item answer needs one code, and any other rule lets one abstention be masked by a
    # landing beside it. (An earlier version attributed this to a `gh pr checks` convention — `gh pr
    # checks` takes ONE PR, so there is no such convention; the rationale was right, the citation was
    # not. Fresh-review finding F2, round 5.)
    report "$pr" "$rc" "$out"; rrc=$?
    [ "$rrc" -gt "$worst" ] && worst="$rrc"
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
