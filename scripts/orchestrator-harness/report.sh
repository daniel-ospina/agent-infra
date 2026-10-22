#!/usr/bin/env bash
# report.sh [<hours>] — what the orchestrator harness did in the last N hours (default 12).
#
#   O=/path/to/orchestrator REPO=/path/to/tortoise ./report.sh 6
#
# Reads ONLY durable artifacts — state/walltime.tsv, state/merged-*.done, state/parked-*,
# state/fixcount-*, $O/logs/orch-loop.log, the recorded harness stamp, and `origin`. It is
# READ-ONLY (no `gh` write, no tmux, no lock), so it is safe to run while the loop is working.
# Dependency-free beyond bash + git + gh + python3 (the last two only for the sections that need
# them; a missing one makes its section say so, never abort the report).
#
# The harness's per-box constants are the same three the other shipped scripts use, so a shell
# that already exports them for orch-loop.sh/install.sh needs no extra setup. `REPO` defaults to
# the tortoise checkout this box drains; override it for any other target.
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
REPO="${REPO:-$HOME/eldato/tortoise}"
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
if [ -d "$REPO" ] && command -v gh >/dev/null 2>&1; then
  open=$(cd "$REPO" && gh pr list --state open --limit 300 --json number --jq length 2>/dev/null)
  echo "  open PRs: ${open:-<could not read>}"
else
  echo "  open PRs: <needs a repo checkout and gh>"
fi
echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')"
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
