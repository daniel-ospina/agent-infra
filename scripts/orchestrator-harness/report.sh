#!/usr/bin/env bash
# report.sh [<hours>] — what the orchestrator harness did in the last N hours (default 12).
#
#   O=/path/to/orchestrator REPO=/path/to/tortoise ./report.sh 6
#
# Reads ONLY durable artifacts — state/walltime.tsv, state/merged-*.done, state/parked-*,
# state/fixcount-*, state/needsreview-* (the open-PR stale-evidence queue, #2132),
# $O/logs/orch-loop.log, the recorded harness stamp, and `origin`. It is READ-ONLY (no `gh` write, no
# tmux, no lock), so it is safe to run while the loop is working.
# Dependency-free beyond bash + git + gh + python3 (the last two only for the sections that need
# them; a missing one makes its section say so, never abort the report).
#
# The harness's per-box constants are the same three the other shipped scripts use, so a shell
# that already exports them for orch-loop.sh/install.sh needs no extra setup.
#
# ⛔ `REPO` HAS NO DEFAULT HERE, AND THAT IS THE FIX. This line used to read
# `REPO="${REPO:-$HOME/eldato/tortoise}"` — ONE DEVELOPER'S HOME DIRECTORY, baked into a script every
# machine on the fleet runs. On any other box the default names a path that does not exist, and the
# failure surfaces far from the cause: the report prints a `cloud-cell-supervisor.sh` candidate that
# is not there and the sections it feeds read as "nothing to report" on a box that is busy (the same
# class refresh-candidates.sh closed for the QUEUE in #1935). `REPO` is set ONCE per box — the launchd
# plist on a Mac, `keys.env` on a cell — and `repo-slug.sh`'s `resolve_repo` is the ONE place that
# reads it: it refuses BY NAME when it is absent or is not a checkout, instead of guessing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${1:-12}"
# ⛔ `0[0-9]*` too: a leading zero is OCTAL to `$(( ))`. Measured pre-fix: `report.sh 08` printed
# "08: value too great for base" at the `FROM=` line below and then died at the first use of `$FROM`
# with "FROM: unbound variable", rc=1 — the report stopped partway. (Pre-existing; found by the same
# review that added the identical arm to the heartbeat guard, and closed here because this is the
# file being changed rather than filed as a peer.)
case "$H" in ''|*[!0-9]*|0[0-9]*) H=12 ;; esac
O="${O:-$HOME/orchestrator}"
# repo-slug.sh ships beside this script (both are in install.sh's copied set), so a deployed `$O` has
# it too; `$O` is the second candidate for an operator running a copy from elsewhere.
_REPO_LIB=""
for _cand in "$HERE/repo-slug.sh" "${O:-}/repo-slug.sh"; do
  [ -n "$_cand" ] && [ -f "$_cand" ] && { _REPO_LIB="$_cand"; break; }
done
[ -n "$_REPO_LIB" ] || { echo "report.sh: FATAL repo-slug.sh not found (looked in $HERE and \$O=${O:-<unset>}) — REPO cannot be resolved, and this script will not guess one" >&2; exit 78; }
# shellcheck source=repo-slug.sh
. "$_REPO_LIB"
command -v resolve_repo >/dev/null 2>&1 || { echo "report.sh: FATAL $_REPO_LIB is stale (no resolve_repo) — re-seed it: bash scripts/orchestrator-harness/deploy-harness.sh --src . --o ${O:-\$O}" >&2; exit 78; }
REPO="$(resolve_repo)" || exit $?
NOW=$(date +%s); FROM=$(( NOW - H * 3600 ))

# GNU `stat -c %Y` FIRST, then BSD `stat -f %m`. The reverse order is NOT safe: GNU `stat -f %m`
# treats `%m` as a second FILENAME, prints a whole filesystem-status block to stdout and only THEN
# errors, so `-f %m || -c %Y` captures that block CONCATENATED with the epoch — a multi-line value
# that `[ -ge ]` rejects, so every merge reads as outside the window. Each probe is validated
# numerically and empties on anything else, so a garbled value is "cannot judge", never a number.
mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then m="$(stat -f %m "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac; fi
  [ -n "$m" ] && printf '%s' "$m"
}

echo "════════ orchestrator report — last ${H}h ($(date '+%Y-%m-%d %H:%M')) ════════"
echo
echo "── controller ──────────────────────────────────────────────"
# ⛔ BRANCH ON THE PLATFORM, NOT ON WHETHER `launchctl` IS ON PATH. A Linux cell can carry a
# launchctl stub (this suite itself installs one for install.sh), and the macOS branch would then
# read a job list that does not exist and print a state about the wrong supervisor. `uname` answers
# the question the branch is actually about.
PLATFORM="$(uname -s 2>/dev/null || echo UNKNOWN)"
if [ "$PLATFORM" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  # ⛔ THE LABEL MUST BE THIS BOX'S ORCHESTRATOR, NOT ANY JOB CONTAINING "orchestrator" (review P1).
  # This arm was `awk '/orchestrator/{print $1}'` — a bare substring test on the LABEL — so ANOTHER
  # repo's job answered for this box. Measured with a stub `launchctl` listing
  # `com.tortoise.orchestrator-loop` RUNNING and this box's own `com.eldato.orchestrator-loop` LOADED
  # with no process: `UP (pid 999)   heartbeat age: 1792497232s` — a foreign pid wearing THIS box's
  # evidence, because the age is read from `$O/heartbeat` here. `bin/harness doctor` answers the same
  # fixture correctly (`supervisor: none` / `other-repo`), so the two instruments disagreed and this
  # one was wrong. The comment 26 lines below already states the rule for the process arm
  # (`pgrep -f orch-loop.sh` is deliberately NOT used, #1856/#1859); the launchd arm was its unfixed
  # twin — the PR closed that defect in `bin/harness` and left it standing in the SAME diff's hunk.
  #
  # ONE PATTERN, anchored: `HARNESS_UNIT_RE` is byte-identical to `bin/harness`'s, and
  # `selftest.sh` asserts the two literals agree so the twins cannot drift apart again. It is a
  # TWO-COPY constant rather than a sourced one because `bin/harness` ships from `bin/` while these
  # scripts ship to `$O` — the `install.sh` copier would not carry a shared file to both.
  HARNESS_UNIT_RE='^(com\.eldato\.)?(orchestrator|eldato-orchestrator)[-.]'
  # ⛔ THE PATTERN IS PASSED THROUGH THE ENVIRONMENT, NOT `-v`: a `-v` assignment is
  # ESCAPE-PROCESSED by awk, so on gawk/BSD awk `\.` becomes a bare `.` and the anchor degrades to
  # a wildcard — the very class this closes. `ENVIRON` is read verbatim.
  # `launchctl list` prints `PID\tStatus\tLabel`, and `-` in the PID column means LOADED but NOT
  # RUNNING, so the PID FIELD decides UP — never bare presence. Reading the whole list once and
  # branching on the field also closes the second half of the measured defect: with two matching
  # jobs `$pid` was a MULTI-LINE value, which `[ "$pid" = "-" ]` cannot read as "not running", so
  # `UP (pid 4242<newline>-)` was printed for a box with no controller.
  _ll="$(launchctl list 2>/dev/null | RE="$HARNESS_UNIT_RE" awk '$3 ~ ENVIRON["RE"] { print $1" "$3 }' || true)"
  pid="$(printf '%s\n' "$_ll" | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
  _job="$(printf '%s\n' "$_ll" | awk 'NF { print $2; exit }')"
  if [ -n "${pid:-}" ]; then
    hb=$(cat "$O/heartbeat" 2>/dev/null || echo 0)
    # ⛔ A non-numeric heartbeat is FATAL here, not cosmetic: `$(( NOW - abc ))` recurses into the
    # VARIABLE `abc`, and under `set -u` that is "abc: unbound variable" — so the whole report
    # aborted mid-way (everything after `── controller ──`: merges, wall-time, claims, queue health)
    # and the script still exited 0. Measured with `heartbeat` = `abc`: 3 lines of stdout, rc=0.
    # Validate exactly as the sibling paths already validate their numeric reads.
    # ⛔ `0[0-9]*` too: a leading zero is OCTAL to `$(( ))`, so `heartbeat=08` fails the expansion
    # with "value too great for base" and the status line is dropped silently — the same silent-drop
    # class this guard was added for. (The `case "$H"` guard at the top of this file had the
    # identical gap; it is closed there too.)
    case "$hb" in ''|*[!0-9]*|0[0-9]*) hb=0 ;; esac
    echo "  UP (pid $pid)   heartbeat age: $(( NOW - hb ))s"
  elif [ -n "${_job:-}" ]; then
    # LOADED BUT NOT RUNNING: the job is installed, launchd holds it, and there is no process — the
    # state an operator mistakes for a quiet box. Named separately from "no job at all" because the
    # next step differs (start it vs install it).
    echo "  ⚠️  NOT RUNNING (job ${_job} is LOADED but has no process — launchctl shows pid '-')"
  else
    echo "  ⚠️  NOT RUNNING (no orchestrator launchd job — launchctl holds no com.eldato.orchestrator-loop)"
  fi
else
  # ── LINUX: the platform branch, not a shrug ────────────────────────────────────────────────
  # The cloud cells are supervised by `scripts/cloud-cell-supervisor.sh` (systemd/tmux), whose OWN
  # `status` verb is the authoritative answer — it reads the per-role pass records and can tell a
  # dead loop from an idle one. Asking it keeps ONE definition of "is the controller up" instead of
  # growing a second one here; `pgrep -f orch-loop.sh` is deliberately NOT used (an unscoped match
  # counts another repo's controller that shares the harness path — the measured #1856/#1859 shape).
  # If the supervisor is not beside this copy (a bare deployed $O), say so and name the next step
  # rather than printing a state this script cannot see.
  SUP=""
  # Test seam: SUPERVISOR_SH pins the supervisor (the same idiom as the other seams in this suite,
  # so the Linux branch can be exercised on any host rather than only on a cloud cell).
  for _c in "${SUPERVISOR_SH:-}" "$HERE/../cloud-cell-supervisor.sh" "${REPO:-}/scripts/cloud-cell-supervisor.sh"; do
    [ -n "$_c" ] && [ -x "$_c" ] && { SUP="$_c"; break; }
  done
  if [ -n "$SUP" ]; then
    _st="$(O="$O" REPO="$REPO" "$SUP" status 2>&1 | head -4)"
    if [ -n "$_st" ]; then
      printf '%s\n' "$_st" | sed 's/^/  /'
    else
      echo "  ⚠️  UNKNOWN — cloud-cell-supervisor.sh status printed nothing (cannot verify, not a pass)"
    fi
  else
    echo "  no launchd (not macOS) and no cloud-cell-supervisor.sh beside this copy — cannot ask the supervisor"
    echo "  → on a cloud cell run: <repo>/scripts/cloud-cell-supervisor.sh status"
  fi
fi
# ⛔ The worker population is NOT the tmux session list any more (agent-infra#2210): on a cloud cell
# every worker is a cmux durable terminal, so `tmux ls | wc -l` printed `0` for a busy box. Read the
# launcher's census; UNKNOWN when it cannot answer, never a confident 0.
sessions=UNKNOWN
if [ -f "$O/worker-terminal.sh" ]; then
  # ⛔ CAPTURE FIRST, COUNT SECOND. A substitution that ends in `| wc -l` reports `wc`'s status, so a
  # `|| sessions=UNKNOWN` after it can never fire (no pipefail here) — a module that cannot source
  # printed a confident `sessions: 0`. And `wt_table` prints ONE newline for an empty table, so
  # `wc -l` said 1 on an idle box: exactly the count a single live worker produces. Count NON-BLANK
  # rows, and treat an empty capture as UNKNOWN rather than as zero.
  # `if cmd=$(…)` keeps the SUBSHELL's exit status (a plain assignment in a pipe reports `wc`):
  # rc 0 means the census ANSWERED, and an empty answer is then 0 workers — not UNKNOWN. Only a
  # module that cannot source / defines no `wt_table` / exits non-zero leaves UNKNOWN standing.
  if _wt_tbl=$( ( . "$O/worker-terminal.sh" >/dev/null 2>&1 && command -v wt_table >/dev/null 2>&1 && wt_table ) 2>/dev/null ); then
    # Count LIVE worker rows: `wt_table` also emits `dead` rows (a record whose surface is gone,
    # which the reap has not cleared yet), and "sessions" is a population, not a ledger size.
    sessions=$(printf '%s\n' "${_wt_tbl:-}" | awk -F'\t' 'NF && $2 != "dead"' | wc -l | tr -d ' ')
  fi
  case "${sessions:-}" in ''|*[!0-9]*) sessions=UNKNOWN ;; esac
fi
echo "  sessions: $sessions   load: $(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/')"
# ⛔ `wc -l < missing-file 2>/dev/null` still prints a bash REDIRECTION error: bash reports the
# failed `<` itself, before `wc` (and its `2>/dev/null`) runs. Guard the redirection instead.
queued=0; [ -r "$O/candidates.txt" ] && queued=$(wc -l < "$O/candidates.txt" | tr -d ' ')
dispatched=0; [ -r "$O/dispatched.txt" ] && dispatched=$(wc -l < "$O/dispatched.txt" | tr -d ' ')
echo "  backlog: $queued candidates queued   dispatched-to-date: $dispatched"
# Which harness commit this box runs (agent-infra#1745). Absent record reads UNKNOWN, never blank.
if [ -f "$O/.agent-infra-stamp.json" ]; then
  hc=$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)
  hr=$(sed -n 's/.*"relation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)
  # The source commit does NOT describe the deployed bytes when install.sh recorded a mismatch
  # (`deployedMatchesSource: false` — `$O` was synced from a different revision than the checkout
  # install.sh ran from). Printing `[current]` alone would headline a commit the box is not running.
  dm=$(sed -n 's/.*"deployedMatchesSource"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' "$O/.agent-infra-stamp.json" | tr -d ' "' | head -1)
  echo "  harness: ${hc:-UNKNOWN} [${hr:-unknown}]"
  if [ "$dm" = false ]; then
    echo "  ⚠️  the DEPLOYED copy at \$O differs from the recorded source commit — this box is NOT running those bytes"
    # ⛔ NOT A BARE DEPTH-1 `cp` (agent-infra#2041): this line is printed whenever the record disagrees
    # with the deployed bytes, so it is the single command an operator will paste. Name the verified
    # redeploy, not the unverified copy #2041 measured.
    echo "      re-sync and re-record: bash <checkout>/scripts/orchestrator-harness/deploy-harness.sh --repo <checkout> --o \"\$O\" && O=\"\$O\" bash <checkout>/scripts/orchestrator-harness/install.sh"
  fi
else
  echo "  harness: UNKNOWN (no $O/.agent-infra-stamp.json — run install.sh to record it)"
fi
echo

echo "── merges landed ───────────────────────────────────────────"
n=0; nums=""
for f in "$O"/state/merged-*.done; do
  [ -e "$f" ] || continue
  m=$(mtime "$f"); [ -n "$m" ] || continue
  if [ "$m" -ge "$FROM" ]; then
    n=$((n + 1)); nums="$nums $(basename "$f" | sed 's/merged-//; s/\.done//')"
  fi
done
[ -n "$nums" ] && printf '%s\n' $nums | sort -V | tr '\n' ' ' | fold -s -w 100 | sed 's/^/ /'
echo
echo "  → total in window: $n"
echo

echo "── agent wall-time (append-only series) ────────────────────"
python3 - "$O/state/walltime.tsv" "$FROM" <<'PY' 2>/dev/null || echo "  (python3 unavailable or the series is unreadable)"
import sys
path, frm = sys.argv[1], int(sys.argv[2])
try:
    rows = [l.split() for l in open(path) if l.strip()]
except (FileNotFoundError, PermissionError):
    print("  (no series yet)"); raise SystemExit
rows = [r for r in rows if len(r) >= 6 and r[0].isdigit() and r[3].isdigit() and r[4].isdigit() and int(r[0]) >= frm]
real = [r for r in rows if int(r[3]) > 100]
if not real:
    print("  (no agent runs in window)"); raise SystemExit
from collections import defaultdict
by = defaultdict(list)
for r in real:
    by[r[1]].append((int(r[3]), int(r[4])))
print(f"  {'kind':<9} {'n':>3} {'p50':>7} {'max':>7}  {'killed at cap':>14}")
for k in sorted(by):
    v = sorted(x[1] for x in by[k]); cap = by[k][0][0]
    hits = sum(1 for c, e in by[k] if e >= c - 2)
    print(f"  {k:<9} {len(v):>3} {v[len(v)//2]/60:>6.1f}m {max(v)/60:>6.1f}m  {hits:>4}/{len(v):<4} {100*hits/len(v):>3.0f}%")
tot = sum(len(v) for v in by.values()); hits = sum(1 for v in by.values() for c, e in v if e >= c - 2)
print(f"  → {hits}/{tot} runs ({100*hits/tot:.0f}%) ended at the cap = produced no result")
PY
echo

echo "── cross-box claims (what other machines can see) ─────────"
claims=0
if [ -d "$REPO" ] && command -v git >/dev/null 2>&1; then
  live=$(git -C "$REPO" ls-remote origin 'refs/claims/*' 2>/dev/null)
  claims=$(printf '%s\n' "$live" | grep -c 'refs/claims/' )
  printf '%s\n' "$live" | awk 'NF{print "  "$2}' | head -12
fi
echo "  → live: ${claims:-0}  (a claim with a live lease = a reviewer in flight on some box)"
echo

echo "── queue health ────────────────────────────────────────────"
# ⛔ TRI-STATE, NOT AN EXIT-CODE GUESS (review round 2, P1). The first form only set the failure flag
# INSIDE the "repo AND gh present" branch, so when either was missing the flag stayed 0 and BOTH
# lines printed a confident `0` — a blind read presented as a clean queue, on the very lines whose
# job is to detect a stall (and the `<needs a repo checkout and gh>` message became unreachable).
# ⛔ THE LISTING CARRIES THE LIVE HEAD (review round 7, P2). Asking it for numbers alone forced the
# parked/stale attribution below to INFER whether a park is current from the marker set — an inference
# that misfires both ways: a park with no marker at all was reported as "needs a human" even after a
# push re-armed it, and a park AT the live head whose only marker named an older head was reported as
# re-armed and dropped from BOTH queues. `number:headRefOid` is the same one `gh` read, and the park
# test is then exactly the controller's own (`parked-<PR>` == live head).
OPEN_STATE=unreadable; OPENNUMS=""
if [ ! -d "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
  OPEN_STATE=norepo
elif OPENNUMS="$(cd "$REPO" && gh pr list --state open --limit 300 --json number,headRefOid --jq '.[]|"\(.number):\(.headRefOid)"' 2>/dev/null)"; then
  OPEN_STATE=ok
fi
case "$OPEN_STATE" in
  norepo) echo "  open PRs: <needs a repo checkout and gh>" ;;
  ok)     echo "  open PRs: $(printf '%s' "$OPENNUMS" | grep -c ':')" ;;
  *)      echo "  open PRs: <could not read>" ;;
esac
# ⛔ SUPERSEDED PARKS ARE NOT "NEEDS A HUMAN" (review round 6, P3), AND THE LINE IS PRINTED EXACTLY
# ONCE (review round 6, P2 — the first form left the raw echo above AND the adjusted echo below, so an
# operator read two contradictory numbers for one quantity). A park whose recorded head is not the
# PR's LIVE head has been RE-ARMED by a push (the controller honours a park only when its content
# matches the live head), so that PR is being worked and belongs in neither queue.
# ⛔ BOTH LINES NOW WALK THE OPEN LISTING, NOT THE MARKER FILES (review round 7, P2): each open PR is
# classified exactly once from facts the listing supplies — its live head and its park file — so a PR
# with no marker and a re-armed park is no longer reported as a human's work, and a PR parked at its
# live head is no longer dropped from both queues. Marker files only decide whether an unparked PR has
# a verdict-less run recorded.
# ⛔ THE STALE-EVIDENCE COUNT IS ITS OWN LINE (agent-infra#2132), because it is a DIFFERENT queue with
# a DIFFERENT remedy: a parked PR needs a human, while a `needsreview-<PR>-<head>` PR needs to be
# re-reviewed. Indicator (b) of that issue is "the count of open PRs stalled on stale evidence stays
# at 0", and before this line nothing in the harness could answer it at all.
# ⛔ ON THE DEGRADED PATHS THE PARKED COUNT IS LABELLED RAW (landing-review note, P3). Attribution needs
# the OPEN LISTING — it is the only source of each PR's live head — so on a box with no checkout, or
# with an unreadable listing, a superseded park cannot be told apart from a current one. The readable
# path attributes both numbers; these two paths print the raw `parked-*` file count and MUST say so,
# because an unlabelled raw count presents an INFLATED human queue as a measured one. The direction is
# fail-closed either way (it over-reports attention, never under-reports), so the number is kept —
# only its provenance is named.
case "$OPEN_STATE" in
  norepo)
    echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')  (raw marker count — a superseded head cannot be told apart without a repo checkout and gh)"
    echo "  stale evidence (needs re-review): <needs a repo checkout and gh>" ;;
  ok)
    stale=0; superseded=0; parked_cur=0
    while IFS= read -r _row; do
      [ -n "$_row" ] || continue
      _pr="${_row%%:*}"; _lh="${_row#*:}"
      case "$_pr" in ''|*[!0-9]*) continue ;; esac
      _ph="$(cat "$O/state/parked-$_pr" 2>/dev/null)"
      if [ -n "$_ph" ]; then
        if [ "$_ph" = "$_lh" ]; then parked_cur=$(( parked_cur + 1 )); else superseded=$(( superseded + 1 )); fi
        continue
      fi
      # Not parked: is there a recorded verdict-less run at all? (An old-head marker still means no
      # head-bound clean evidence exists now — merge-one has not looked at the newer head yet.)
      _has=0
      for _g in "$O"/state/needsreview-"$_pr"-*; do [ -e "$_g" ] && { _has=1; break; }; done
      [ "$_has" = "1" ] && stale=$(( stale + 1 ))
    done <<EOF
$OPENNUMS
EOF
    if [ "$superseded" -gt 0 ]; then
      echo "  parked (needs a human): $parked_cur ($superseded at a superseded head — the loop has re-armed them)"
    else
      echo "  parked (needs a human): $parked_cur"
    fi
    echo "  stale evidence (needs re-review): $stale" ;;
  *) echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')  (raw marker count — a superseded head cannot be told apart from an unreadable listing)"
     echo "  stale evidence (needs re-review): <could not read, $(ls "$O"/state/needsreview-* 2>/dev/null | wc -l | tr -d ' ') marker(s) present>" ;;
esac
cap=3
[ -n "${MAX_FIX_TRIES:-}" ] && case "$MAX_FIX_TRIES" in ''|*[!0-9]*) ;; *) cap="$MAX_FIX_TRIES" ;; esac
atcap=0
for f in "$O"/state/fixcount-*; do
  [ -e "$f" ] || continue
  c=$(cat "$f" 2>/dev/null)
  [ -n "$c" ] && [ "$c" -ge "$cap" ] 2>/dev/null && atcap=$((atcap + 1))
done
echo "  at fix-tries cap:       $atcap"
echo

echo "── last 8 dispatch decisions ───────────────────────────────"
grep -a "dispatch\]" "$O/logs/orch-loop.log" 2>/dev/null | tail -8 | sed 's/^/  /'
