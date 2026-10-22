#!/usr/bin/env bash
# harness-unit.test.sh — the proofs behind "the harness is ONE system that tests and heals itself".
#
# Every assertion drives the SHIPPED `scripts/harness-up` (and the shipped shims beside it). A
# re-implementation of any check would pass on a broken copy, which is the defect these suites exist
# against. What is proven here, and why each one is RED on the tree that shipped before it:
#
#   (A) PLACEMENT READS FORK HEADROOM FIRST (agent-infra#2293). The capacity decision measured load
#       and disk only, so a box whose hard TASK limit was exhausted (fork: EAGAIN) reported a healthy
#       lane count — #2293's own measurement is a box at 0.32x load that could not spawn at all. The
#       arms drive: a tight fork limit BINDING the lane count; a generous one not binding; and an
#       UNMEASURABLE one REFUSING (never substituted with a fixed cap).
#   (B) THE THREE DIMENSIONS ARE PRINTED IN THE ORDER THEY FAIL — fork → disk → load — with the
#       number each contributed and the one that bound. A lane count alone cannot say "the box could
#       not fork" from "the box is busy".
#   (C) LANES ARE COUNTED **AND** JUDGED ADVANCING. Five lanes idle for four hours and five lanes
#       merging read identically as `lanes: 5`; the row reads the worker logs the controller's own
#       stale-worker reaper reads, so "advancing" here and "hung" there cannot disagree.
#   (D) `next` REPORTS THE CONTROLLER'S OWN DECISION LINE (`[select]`), never a second opinion — and
#       says LATE rather than presenting an old decision as the next one.
#   (E) SELF-TEST IS PART OF STATUS AND READS THE LIVE TREE: a syntax-broken script in the tree the
#       box would EXECUTE turns the row BROKEN. (A check that passes by remembering is a defect.)
#   (F) SELF-HEAL DOES THE TWO SAFE REPAIRS AND REFUSES THE UNSAFE ONES: a controller that is not
#       running is started; a pin that is BEHIND is re-pinned; a DUPLICATE or a live-but-LATE
#       controller is NEVER killed from a status verb; `restart-pending` is reported, not closed.
#   (G) THE macOS ARM IS EXERCISED, NOT TRUSTED: `HARNESS_UP_OS=Darwin` + BSD-shaped stubs
#       (`sysctl kern.maxproc*`, `ps -e -o`) drive the Darwin half of the fork probe, so the Mac's
#       limit source is proven on a Linux runner rather than discovered by an operator.
#
# Hermetic: fixture repo, throwaway HOME/CELL_HOME, stubbed ps/sysctl/tmux/gh, no network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/harness-up"
fails=0
assertions=0
ck() { # <name> <0|1>
  assertions=$((assertions + 1))
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
# ⛔ A BSD `mktemp` REQUIRES A TEMPLATE, so the suite passes one — while the launcher's own call is
# what (G) exercises.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-unit.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# ⛔ NO `GIT_Q() { git … "$@"; }` WRAPPER: the checkout guard classifies a function that forwards
# `"$@"` to git as an UNVERIFIABLE discard form and refuses to run this file at all — so the suite
# could not be run from the repo it lives in. Identity goes through the environment instead.
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
BRINGUP_LOG="$TMP/bringup.log"; REFRESH_LOG="$TMP/refresh.log"
: > "$BRINGUP_LOG"; : > "$REFRESH_LOG"

# ── the fixture: a repo, a pinned worktree carrying the SHIPPED launcher, and a state dir ────────
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO/scripts/orchestrator-harness/orch-loop.sh"
( cd "$REPO" && git init -q -b main . \
  && git add scripts/orchestrator-harness \
  && git commit -qm A \
  && git update-ref refs/remotes/origin/main refs/heads/main \
  && git remote add origin "$REPO" ) >/dev/null 2>&1
SHA="$(cd "$REPO" && git rev-parse HEAD)"
S12="${SHA:0:12}"

CELL="$TMP/cell"; PINROOT="$CELL/harness"
mkdir -p "$CELL/.pi/agent/state" "$CELL/orchestrator/state" "$CELL/orchestrator/logs" "$TMP/home" "$TMP/bin"
( cd "$REPO" && git worktree add -q --detach "$PINROOT/$S12" "$SHA" ) >/dev/null 2>&1
# ⛔ THE FIXTURE MIRRORS THE REPO'S OWN LAYOUT (`<scripts>/harness-up` beside `<scripts>/orchestrator-harness/`),
# because the launcher resolves its delegates through `SELF_PATH/orchestrator-harness/<tool>` and
# `SELF_PATH/orchestrator-bringup.sh`. A fixture that flattened that layout would test the fixture's
# own paths instead of the shipped ones — and did: the capacity RECORD arm silently fell back to the
# shim, so the "consumes capacity.sh's record" assertion was green about the wrong instrument.
SCRIPTS="$PINROOT/$S12/scripts"
HARNESS="$SCRIPTS/orchestrator-harness"
mkdir -p "$HARNESS"
# The box runs the SHIPPED launcher and shims (a copy, because a pin tree is what a cell executes).
cp "$UP" "$SCRIPTS/harness-up"; cp "$HERE/harness-status" "$SCRIPTS/harness-status"; cp "$HERE/harness-down" "$SCRIPTS/harness-down"
chmod +x "$SCRIPTS"/harness-up "$SCRIPTS"/harness-status "$SCRIPTS"/harness-down 2>/dev/null
# ⛔ capacity.sh IS KEPT OUT OF THE HARNESS DIR BY DEFAULT. The real probe measures THIS box (8 cpu,
# its own load), so its record would decide the fixture's lane count and the fork assertions would be
# about the runner. The shim path is driven by HU_FORK_LIMITS_FILE instead; the RECORD arm installs a
# stub producer below. (The Darwin arm needs it absent too — see (G).)
printf '#!/usr/bin/env bash\necho drift ok\n' > "$HARNESS/check-deployed-drift.sh"
printf '#!/usr/bin/env bash\necho selftest ok\n' > "$HARNESS/selftest.sh"
printf '#!/usr/bin/env bash\necho single source ok\n' > "$HARNESS/check-single-source.sh"
printf '#!/usr/bin/env bash\necho claims\n' > "$HARNESS/claims.sh"
chmod +x "$HARNESS"/* 2>/dev/null

# The platform authorities, STUBBED and COUNTING: the whole heal design is a claim about WHICH
# authority may be invoked, so every invocation is recorded rather than described.
cat > "$SCRIPTS/orchestrator-bringup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BRINGUP_LOG"
case "${1:-}" in
  start) echo "bringup: start (stub)"; exit "${BRINGUP_START_RC:-0}" ;;
  stop)  echo "bringup: stop (stub)";  exit 0 ;;
  *)     echo "bringup: $1 (stub)"; exit 0 ;;
esac
SH
cat > "$HARNESS/harness-refresh.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REFRESH_LOG"
# The refresh's own record shape: the row reads `relation=` and the `fetch=` freshness field.
printf 'relation=%s running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "${REFRESH_RELATION:-current}" x y z "$(date +%s)" > "$O/state/harness-refresh"
printf 'harness relation=%s at=%s\n' "${REFRESH_RELATION:-current}" "$(date +%s)"
exit 0
SH
chmod +x "$SCRIPTS/orchestrator-bringup.sh" "$HARNESS/harness-refresh.sh"
: > "$BRINGUP_LOG"; : > "$REFRESH_LOG"

printf '%s\n' "$SHA" > "$CELL/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$HARNESS" > "$CELL/.harness-path"
printf 'relation=current running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
printf 'claims=reachable at=%s\n' "$(date +%s)" > "$CELL/orchestrator/state/harness-claims"
: > "$CELL/orchestrator/heartbeat"

# The process table (`HU_PS`) and its table: `pid bash <script>` lines, exactly what hu_pids reads.
cat > "$TMP/bin/ps" <<'SH'
#!/bin/sh
case "$*" in
  *command=*) cat "$PS_TABLE" 2>/dev/null ;;
  *-p\ *) pid=""; while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
          awk -v p="$pid" '$1==p { sub(/^[^ ]+ +/, ""); print; exit }' "$PS_TABLE" 2>/dev/null ;;
  *uid=*) while read -r _l; do echo "${PS_UID:-1000}"; done < "$PS_TABLE" ;;
  *pid=*) awk 'NF { print $1 }' "$PS_TABLE" 2>/dev/null ;;
  *) cat "$PS_TABLE" 2>/dev/null ;;
esac
exit 0
SH
chmod +x "$TMP/bin/ps"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/tmux"          # the cell supervisor row reads a session
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/gh"            # `gh auth status` probe
chmod +x "$TMP/bin/tmux" "$TMP/bin/gh"
printf '4.00 1.00 0.50 1/100 4242\n' > "$TMP/load"
printf '1 bash /usr/bin/unrelated.sh\n' > "$TMP/ps-none"
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/cloud-cell-doctor.sh\n' "$HARNESS" "$HARNESS" > "$TMP/ps-live"

# One status run. Every knob is a seam that exists in the shipped file (nothing here is a mock of it).
run() { # <verb> [extra argv…]
  _v="$1"; shift
  OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
          HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
          HU_PS="$TMP/bin/ps" PS_TABLE="${PS_TABLE:-$TMP/ps-live}" PS_UID=1000 \
          HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 HARNESS_UP_OS="${OSV:-Linux}" \
          BRINGUP_LOG="$BRINGUP_LOG" REFRESH_LOG="$REFRESH_LOG" \
          REFRESH_RELATION="${REFRESH_RELATION:-current}" BRINGUP_START_RC="${BRINGUP_START_RC:-0}" \
          HU_FORK_LIMITS_FILE="${FORKFILE:-$TMP/fork-generous}" \
          CAP_FORK_LIMITS_FILE="${CAPFORK:-$TMP/fork-generous}" \
          HU_LANE_SILENT="${LANESILENT:-2400}" HU_NEXT_STALE="${NEXTSTALE:-900}" \
          bash "$SCRIPTS/harness-up" "$_v" --repo "$REPO" --harness "$HARNESS" --no-fetch "$@" 2>&1 )"
  RC=$?
}
row() { printf '%s\n' "$OUT" | grep -E "^$1 " | head -1; }

# Plate sighting: the tightest fork limits are a cgroup ceiling far below the rlimits — #2293's shape.
# Math, with HU_FORK_RESERVE=800 and HU_FORK_PER_LANE=40: headroom 1000 → 5 lanes (load would allow 9,
# disk far more), so FORK is the binding dimension; 3397 → 64 lanes, so load binds; 1 → 0 lanes.
printf 'cgroup-pids 1100 100\nrlimit-nproc 15641 2009\nthreads-max 31282 2493\n' > "$TMP/fork-tight"
printf 'cgroup-pids 4692 1295\nrlimit-nproc 15641 2009\nthreads-max 31282 2493\n' > "$TMP/fork-generous"
printf 'cgroup-pids 10000 9999\nrlimit-nproc 15641 2009\n' > "$TMP/fork-none"   # 1 task spare

# ══ (A)+(B) FORK HEADROOM IS READ FIRST, BINDS, AND IS PRINTED IN THE ORDER IT FAILS ════════════
FORKFILE="$TMP/fork-tight" run status
cap_row="$(row capacity)"
ck "(A) a tight fork limit BINDS the lane count (1000 spare / 40 per lane = 5 of load's 9) [$cap_row]" \
   "$(case "$cap_row" in *"lanes=5 "*"binding=fork"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(A) …and the row says a fork limit is what bound it, not load or disk" \
   "$(case "$cap_row" in *"binding=fork"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(B) the dimensions print in the order they FAIL: fork → disk → load" \
   "$(printf '%s' "$cap_row" | grep -q 'fork headroom=.*→ disk free=.*→ load=' && echo 0 || echo 1)"
ck "(B) …and the fork number is attributed to the LIMIT that produced it (cgroup≠rlimit here)" \
   "$(case "$cap_row" in *"fork headroom=1000 (cgroup-pids)"*|*"fork headroom=1000 (shim:cgroup-pids)"*) echo 0 ;; *) echo 1 ;; esac)"

# A box whose fork headroom is one task: no lane may be placed, and the verdict is DEGRADED (not OK).
FORKFILE="$TMP/fork-none" run status
cap_row="$(row capacity)"
ck "(A) 1 task of headroom places ZERO lanes and is DEGRADED, not a healthy lane count" \
   "$(case "$cap_row" in *"DEGRADED (no room"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(A) …and the verdict follows (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"

# A generous fork limit must NOT bind — load and disk decide, and fork is still REPORTED.
FORKFILE="$TMP/fork-generous" run status
cap_row="$(row capacity)"
ck "(A) a generous fork limit does not bind (binding is load/disk, not fork)" \
   "$(case "$cap_row" in *"binding=fork"*) echo 1 ;; *"binding=load"*|*"binding=disk"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(A) …and fork headroom is still printed with its number (reported, never omitted)" \
   "$(case "$cap_row" in *"fork headroom=3397 ("*) echo 0 ;; *) echo 1 ;; esac)"

# ⛔ UNMEASURABLE IS NOT UNLIMITED: neither the record nor the shim can answer → REFUSED.
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps" PS_TABLE="$TMP/ps-live" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HARNESS_UP_OS=Linux HU_FORK_LIMITS_FILE="$TMP/does-not-exist" \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch 2>&1 )"; RC=$?
cap_row="$(row capacity)"
ck "(A) an unmeasurable fork limit REFUSES the placement (never a fixed cap, never 0-by-omission)" \
   "$(case "$cap_row" in *REFUSED*fork/task" headroom"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(A) …and cannot-verify is BROKEN (rc=2, got $RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"

# The record path (capacity.sh, the fleet instrument) is consumed — including its fork fields, which
# an older writer may not have measured. The stub is the RECORD PRODUCER (it prints a record, it does
# not compute one), so what is asserted is the launcher's CONSUMPTION of fork_headroom.
cat > "$HARNESS/capacity.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=fixture ncpu=4 load1=400 lpc=100 lanes=0 disk_free_mb=9000 mem_free_mb=4000 fork_headroom=1000 fork_source=cgroup-pids at=%s\n' "$(date +%s)"
SH
chmod +x "$HARNESS/capacity.sh"
run status
ck "(A) the record's OWN fork fields are consumed (via names the fleet instrument, not the shim)" \
   "$(row capacity | grep -q 'via=capacity.sh' && echo 0 || echo 1)"
ck "(A) …and the record's fork reading — not a fresh shim probe — decides the placement" \
   "$(row capacity | grep -q 'fork headroom=1000 (cgroup-pids)' && echo 0 || echo 1)"
rm -f "$HARNESS/capacity.sh"

# ══ (C) LANES ARE COUNTED **AND** JUDGED ════════════════════════════════════════════════════════
L="$CELL/orchestrator/logs"; WS="$CELL/orchestrator/state"
: > "$L/lane-1.log"; : > "$L/lane-2.log"; : > "$L/merge-9.log"
printf '[]\n' > "$L/fix-4.log"
# ⛔ THE LIVE POPULATION IS THE LAUNCHER'S OWN WORKER RECORDS (`state/run-<name>.sh`), not the log
# directory: a week-old box has hundreds of finished logs and counting them as `silent lanes` is how
# the first version of this row reported `0/159 advancing` on a box with FIVE live lanes.
for w in lane-1 lane-2 merge-9 fix-4; do printf '#!/bin/sh\n' > "$WS/run-$w.sh"; done
# A FINISHED lane: a log with no worker record, which must be IGNORED (reported as retired, never
# judged). This is the arm that would have gone red without the fix above.
: > "$L/fix-1.log"; touch -t "$(date -v-30H +%Y%m%d%H%M 2>/dev/null || date -d '-30 hours' +%Y%m%d%H%M)" "$L/fix-1.log"
old="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)"
fresh="$(date -v-2M +%Y%m%d%H%M 2>/dev/null || date -d '-2 minutes' +%Y%m%d%H%M)"
touch -t "$fresh" "$L/lane-1.log" "$L/lane-2.log" "$L/merge-9.log"
touch -t "$old"   "$L/fix-4.log"
run status
lanes_row="$(row lanes)"
ck "(C) lanes are counted from the launcher's live worker RECORDS (4 here) [$lanes_row]" \
   "$(case "$lanes_row" in *"3/4 live and advancing"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(C) …and a lane SILENT past the controller's own bound is NAMED, with the bound [$lanes_row]" \
   "$(case "$lanes_row" in *"2400s"*"fix-4"*|*"fix-4"*"2400s"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(C) …and a FINISHED lane (a log whose worker record is gone) is IGNORED, not counted silent [$lanes_row]" \
   "$(case "$lanes_row" in *"1 finished log(s) ignored"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(C) …so the row is DEGRADED, and the verdict with it (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
touch -t "$fresh" "$L/fix-4.log"
run status
ck "(C) with every live lane inside the bound the row is OK ($(row lanes))" \
   "$(row lanes | grep -q '4/4 live and advancing' && echo 0 || echo 1)"

# ⛔ NO LIVE LANE IS NOT "EVERY LANE IS SILENT", and an ABSENT state dir is not "zero lanes": both
# would be a claim about a measurement nobody made.
rm -f "$WS"/run-*.sh
run status
ck "(C) with no live worker records the row says so plainly, and the finished logs stay ignored [$(row lanes)]" \
   "$(row lanes | grep -q 'no lane is live' && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$TMP/empty-state"; mkdir -p "$TMP/empty-state"
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps" PS_TABLE="$TMP/ps-live" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_FORK_LIMITS_FILE="$TMP/fork-generous" \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch -o "$TMP/empty-state" 2>&1 )"; RC=$?
ck "(C) an ABSENT state dir is SKIPPED-with-a-reason, never OK-0 and never judged [$(row lanes)]" \
   "$(row lanes | grep -q 'SKIPPED (no worker records' && echo 0 || echo 1)"

# ⛔ A CONTROLLER'S OWN REFRESH CHILD IS NOT A DUPLICATE (measured 2026-10-22 on the live cell: the
# per-cycle self-refresh child #2215 shares the controller's ARGV, the row said `DUPLICATE (3 live)` and
# the verdict was BROKEN on a box with ONE controller — a verdict that invites killing a controller's
# own child). The stubbed table carries a controller and its descendant with the SAME argv.
cat > "$TMP/bin/ps-ppid" <<'SH'
#!/bin/sh
case "$*" in
  *ppid=*)    printf '500 1\n501 500\n' ;;
  *command=*) printf '500 bash %s/orch-loop.sh\n501 bash %s/orch-loop.sh\n' "$P_SCRIPT" "$P_SCRIPT" ;;
  *-p\ *)    pid=""; while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
              [ "$pid" = 500 ] && printf 'bash %s/orch-loop.sh\n' "$P_SCRIPT" ;;
  *)          printf '500 bash %s/orch-loop.sh\n501 bash %s/orch-loop.sh\n' "$P_SCRIPT" "$P_SCRIPT" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/ps-ppid"
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps-ppid" P_SCRIPT="$HARNESS" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_FORK_LIMITS_FILE="$TMP/fork-generous" \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch --no-heal 2>&1 )"; RC=$?
loop_row="$(row loop)"
ck "(C') a controller AND its own refresh child read as ONE controller, not DUPLICATE [$loop_row]" \
   "$(case "$loop_row" in *DUPLICATE*) echo 1 ;; *"OK (heartbeat"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(C') …so the verdict is not BROKEN on a healthy single-controller box (rc=$RC)" \
   "$([ "$RC" -le 1 ] && echo 0 || echo 1)"

# ══ (D) `next` IS THE CONTROLLER'S OWN DECISION LINE ════════════════════════════════════════════
printf '[select] PR path: 6 acted, 2 named wait(s); issues BLOCKED — 16 un-owned PR(s) remain\n' >> "$L/orch-loop.log"
run status
ck "(D) the next action is the controller's own [select] line, quoted" \
   "$(row next | grep -q 'issues BLOCKED — 16 un-owned' && echo 0 || echo 1)"
touch -t "$old" "$L/orch-loop.log"
run status
ck "(D) …and a stale log is LATE, never presented as the next decision" \
   "$(row next | grep -q 'LATE' && echo 0 || echo 1)"
touch -t "$fresh" "$L/orch-loop.log"

# ══ (E) SELF-TEST IS PART OF STATUS AND READS THE LIVE TREE ═════════════════════════════════════
run status
ck "(E) the self-test row parses the live tree and names what it checked ($(row selftest))" \
   "$(row selftest | grep -q 'bash -n on' && echo 0 || echo 1)"
ck "(E) …and the platform probes were ASKED, not remembered" \
   "$(row selftest | grep -q 'shim probes answered:.*fork' && echo 0 || echo 1)"
printf 'if [ -z "$x" ; then\n' > "$HARNESS/zz-broken.sh"
run status
ck "(E) a syntax-broken script in the EXECUTED tree turns the row BROKEN" \
   "$(row selftest | grep -q 'BROKEN (failed: zz-broken.sh' && echo 0 || echo 1)"
ck "(E) …and the verdict is BROKEN, not a remembered pass (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
rm -f "$HARNESS/zz-broken.sh"

# ══ (F) SELF-HEAL: THE TWO SAFE REPAIRS, AND THE REFUSALS ═══════════════════════════════════════
# (F1) A controller that is NOT running is STARTED — and it is the only authority called.
: > "$BRINGUP_LOG"
PS_TABLE="$TMP/ps-none" run status
ck "(F1) a missing controller is HEALED (the authority's start ran once)" \
   "$([ "$(grep -c '^start' "$BRINGUP_LOG")" -eq 1 ] && echo 0 || echo 1)"
ck "(F1) …and the heal is SAID, so an operator can see what moved" \
   "$(printf '%s' "$OUT" | grep -q 'HEAL: started a controller' && echo 0 || echo 1)"
ck "(F1) …and no stop was issued (a heal never kills what is live)" \
   "$([ "$(grep -c '^stop' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"

# ⛔ `--no-heal` MUST BE A PURE READ. A status verb that repairs without being asked is a trap for the
# operator who ran it to find out what was wrong.
: > "$BRINGUP_LOG"
PS_TABLE="$TMP/ps-none" run status --no-heal
ck "(F1) --no-heal performs NO repair (0 starts)" "$([ "$(grep -c '^start' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F1) …and the row still reports the truth: MISSING, DEGRADED" \
   "$(row loop | grep -q MISSING && [ "$RC" -eq 1 ] && echo 0 || echo 1)"

# (F2) A pin that is BEHIND is re-pinned; the refresh advance is non-destructive (#2278).
: > "$REFRESH_LOG"
printf 'relation=behind running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
REFRESH_RELATION=behind run status
ck "(F2) a STALE pin (relation=behind) is re-pinned (refresh ran once)" \
   "$([ "$(wc -l < "$REFRESH_LOG")" -ge 1 ] && echo 0 || echo 1)"
ck "(F2) …and the heal is said" "$(printf '%s' "$OUT" | grep -q 'HEAL: re-pinned a stale harness' && echo 0 || echo 1)"

# (F3) restart-pending is REPORTED, never closed by a status verb: closing it means dropping the
# running controller, which is the operator's own down/up.
: > "$REFRESH_LOG"
printf 'relation=restart-pending running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
run status
ck "(F3) restart-pending is NOT healed (no refresh call: closing it would drop the live controller)" \
   "$([ "$(wc -l < "$REFRESH_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F3) …and the refusal names the deliberate remedy" \
   "$(printf '%s' "$OUT" | grep -q 'run .harness-down. then .harness-up.' && echo 0 || echo 1)"

printf 'relation=current running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"

# (F4) A DUPLICATE controller is never killed from a status verb.
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/orch-loop.sh\n' "$HARNESS" "$HARNESS" > "$TMP/ps-dup"
: > "$BRINGUP_LOG"
PS_TABLE="$TMP/ps-dup" run status
ck "(F4) a DUPLICATE is reported and NEVER killed by status (no start, no stop)" \
   "$([ "$(grep -cE '^(start|stop)' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F4) …and it says whose decision that is" \
   "$(printf '%s' "$OUT" | grep -q 'choosing which controller to kill is a human decision' && echo 0 || echo 1)"

# ══ (G) THE macOS ARM IS EXERCISED ═════════════════════════════════════════════════════════════
# BSD-shaped stubs: `sysctl -n kern.maxproc/hw.ncpu/vm.loadavg`. The fork probe on Darwin reads
# kern.maxprocperuid against the uid's process count, so the mac's limit SOURCE is what is asserted.
cat > "$TMP/bin/sysctl" <<'SH'
#!/bin/sh
case "$*" in
  "-n kern.maxproc") echo 5000 ;;
  "-n kern.maxprocperuid") echo "${MAC_MAXPROC_PERUID:-1200}" ;;
  "-n hw.ncpu") echo 4 ;;
  "-n vm.loadavg") echo "{ 4.00 1.00 0.50 }" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/sysctl"
# 300 processes for this uid; maxprocperuid 1200 → headroom 900 (Darwin's own limit, not a Linux file).
i=0; : > "$TMP/ps-mac"; while [ "$i" -lt 300 ]; do echo "$((1000+i)) bash /usr/bin/x" >> "$TMP/ps-mac"; i=$((i+1)); done
# ⛔ NO capacity.sh IN THE FIXTURE'S HARNESS DIR (see the note at the top): with the fleet instrument
# present the RECORD answers first and the Darwin shim would never run — the assertion would then be
# about the Linux probe wearing the mac's name.
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps" PS_TABLE="$TMP/ps-mac" PS_UID=1000 \
        HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 HARNESS_UP_OS=Darwin \
        HU_LANE_SILENT=2400 HU_NEXT_STALE=900 \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch 2>&1 )"; RC=$?
cap_row="$(row capacity)"
ck "(G) the Darwin arm measures fork headroom from kern.maxprocperuid, not a Linux path [$cap_row]" \
   "$(case "$cap_row" in *"fork headroom=900 ("*"kern-maxprocperuid"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(G) …and a macOS status run reaches a verdict (a BSD mktemp/stat death would end it earlier)" \
   "$(printf '%s' "$OUT" | grep -q '^VERDICT: ' && echo 0 || echo 1)"
ck "(G) …with the mac's launchd row present (not the cell arm)" \
   "$(printf '%s\n' "$OUT" | grep -q '^launchd ' && echo 0 || echo 1)"

# ── the suite's own non-vacuity floor (the #1890 class) ────────────────────────────────────────
ck "non-vacuity: at least 20 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 20 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-unit.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
