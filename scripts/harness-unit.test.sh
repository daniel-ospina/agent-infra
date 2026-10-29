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
# ⛔ MATCHING IS DATA, NEVER SYNTAX — AND THIS FILE MUST PARSE ON bash 3.2 (macOS).
# This suite is added to `scripts/run-bash-shards.sh`, whose list BOTH lanes run, and one of them is
# a Mac fleet cell where `/bin/bash` is 3.2.57. On 3.2 an UNBALANCED `(` in a `case` PATTERN is a
# SYNTAX ERROR — `*"OK (heartbeat"*)` made `bash -n scripts/harness-unit.test.sh` fail outright and
# the run died at that line, so (F)/(G) never executed and `up` would have refused the tree the moment
# the sweep reached this file (measured 2026-10-24, bash 3.2.57: "syntax error near unexpected token
# `('" at the first such pattern; CI is ubuntu/bash 5 and cannot see it). A row's parentheses, `*`
# and `|` are EVIDENCE, not pattern syntax, so every assertion below asks `has`/`lacks` about the row
# as LITERAL TEXT — `"$2"` is quoted, so its contents never reach the parser.
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }
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
# ⛔ `-o "$CELL/orchestrator"` IS NOT DECORATION (fresh review, P1 — measured 2026-10-24): the launcher
# resolves its state dir as `O="${A_O:-${O:-}}"`, so an INHERITED `O` BEAT `CELL_HOME` and this suite
# read the LIVE box's state dir instead of the fixture. Measured on the fleet's own Mac with `O`
# exported (`O=/Users/home/orchestrator`, which the harness itself exports): the (C) arms read 2,869
# real logs and 10 assertions failed — and the (F2) arm's stub refresh writes
# `> "$O/state/harness-refresh"`, so a `relation=behind` run would have OVERWRITTEN THE LIVE CELL'S
# refresh record with a fabricated `relation=current`. The explicit `-o` (which OUTRANKS an inherited
# `O`) is what makes this suite hermetic on a box that is itself a controller.
run() { # <verb> [extra argv…]
  _v="$1"; shift
  OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
          HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
          HU_PS="$TMP/bin/ps" PS_TABLE="${PS_TABLE:-$TMP/ps-live}" PS_UID=1000 \
          HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 HARNESS_UP_OS="${OSV:-Linux}" \
          BRINGUP_LOG="$BRINGUP_LOG" REFRESH_LOG="$REFRESH_LOG" \
          REFRESH_RELATION="${REFRESH_RELATION:-current}" BRINGUP_START_RC="${BRINGUP_START_RC:-0}" \
          HU_FORK_LIMITS_FILE="${FORKFILE:-$TMP/fork-generous}" \
          HARNESS_UP_LANE_SILENT="${LANESILENT:-2400}" HARNESS_UP_NEXT_STALE="${NEXTSTALE:-900}" \
          bash "$SCRIPTS/harness-up" "$_v" --repo "$REPO" --harness "$HARNESS" --no-fetch -o "$CELL/orchestrator" "$@" 2>&1 )"
  RC=$?
}
row() { printf '%s\n' "$OUT" | grep -E "^$1 " | head -1; }

# Plate sighting: the tightest fork limits are a cgroup ceiling far below the rlimits — #2293's shape.
# Math, with the reserve at its DEFAULT — the fleet's own `CAP_MIN_FORK_HEADROOM` (200), which this
# launcher now reads from capacity.sh's `fork` verb instead of declaring a second one — and
# HU_FORK_PER_LANE=40: headroom 360 → 4 lanes (load would allow 9, disk far more), so FORK is the
# binding dimension; 3397 → 79 lanes, so load binds; 1 → 0 lanes.
printf 'cgroup-pids 460 100\nrlimit-nproc 15641 2009\nthreads-max 31282 2493\n' > "$TMP/fork-tight"
printf 'cgroup-pids 4692 1295\nrlimit-nproc 15641 2009\nthreads-max 31282 2493\n' > "$TMP/fork-generous"
printf 'cgroup-pids 10000 9999\nrlimit-nproc 15641 2009\n' > "$TMP/fork-none"   # 1 task spare

# ══ (A)+(B) FORK HEADROOM IS READ FIRST, BINDS, AND IS PRINTED IN THE ORDER IT FAILS ════════════
FORKFILE="$TMP/fork-tight" run status
cap_row="$(row capacity)"
ck "(A) a tight fork limit BINDS the lane count (360 spare / 40 per lane = 4 of load's 9) [$cap_row]" \
   "$(has "$cap_row" 'lanes=4 ' && has "$cap_row" 'binding=fork' && echo 0 || echo 1)"
ck "(A) …and the row says a fork limit is what bound it, not load or disk" \
   "$(has "$cap_row" 'binding=fork' && echo 0 || echo 1)"
ck "(B) the dimensions print in the order they FAIL: fork → disk → load" \
   "$(grep -q 'fork headroom=.*→ disk free=.*→ load=' <<<"$cap_row" && echo 0 || echo 1)"
ck "(B) …and the fork number is attributed to the LIMIT that produced it (cgroup≠rlimit here)" \
   "$({ has "$cap_row" 'fork headroom=360 (cgroup-pids)' || has "$cap_row" 'fork headroom=360 (shim:cgroup-pids)'; } && echo 0 || echo 1)"

# A box whose fork headroom is one task: no lane may be placed, and the verdict is DEGRADED (not OK).
FORKFILE="$TMP/fork-none" run status
cap_row="$(row capacity)"
ck "(A) 1 task of headroom places ZERO lanes and is DEGRADED, not a healthy lane count" \
   "$(has "$cap_row" 'DEGRADED (no room' && echo 0 || echo 1)"
ck "(A) …and the verdict follows (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"

# A generous fork limit must NOT bind — load and disk decide, and fork is still REPORTED.
FORKFILE="$TMP/fork-generous" run status
cap_row="$(row capacity)"
ck "(A) a generous fork limit does not bind (binding is load/disk, not fork)" \
   "$(! has "$cap_row" 'binding=fork' && { has "$cap_row" 'binding=load' || has "$cap_row" 'binding=disk'; } && echo 0 || echo 1)"
ck "(A) …and fork headroom is still printed with its number (reported, never omitted)" \
   "$(has "$cap_row" 'fork headroom=3397 (' && echo 0 || echo 1)"

# ⛔ `unbounded` IS A READING, NOT A ZERO. `procs_max=0` means NO CEILING WAS FOUND, and the row must
# say so: `by fork=0` would tell an operator that the box with no process limit can place zero lanes —
# a fabricated number in the one place this file forbids them. It must also NOT bind.
cat > "$HARNESS/capacity.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  probe) printf 'host=fixture ncpu=4 load1=400 lpc=100 lanes=0 disk_free_mb=90000 mem_free_mb=4000 procs=400 procs_max=0 fork=0 at=%s\n' "$(date +%s)" ;;
  fork)  printf 'procs=400 procs_max=0 fork=0 src=unbounded headroom=unbounded min_fork_headroom=200\n' ;;
  *)     exit 2 ;;
esac
SH
chmod +x "$HARNESS/capacity.sh"
run status
cap_row="$(row capacity)"
ck "(A) an UNBOUNDED fork ceiling prints unbounded, never 0 (a ceiling that does not exist cannot bind)" \
   "$(has "$cap_row" 'by fork=unbounded' && lacks "$cap_row" 'by fork=0' && echo 0 || echo 1)"
ck "(A) …and it does not bind (binding is load/disk, not fork)" \
   "$(lacks "$cap_row" 'binding=fork' && echo 0 || echo 1)"
rm -f "$HARNESS/capacity.sh"

# ⛔ UNMEASURABLE IS NOT UNLIMITED: neither the record nor the shim can answer → REFUSED.
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps" PS_TABLE="$TMP/ps-live" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HARNESS_UP_OS=Linux HU_FORK_LIMITS_FILE="$TMP/does-not-exist" \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch -o "$CELL/orchestrator" 2>&1 )"; RC=$?
cap_row="$(row capacity)"
ck "(A) an unmeasurable fork limit REFUSES the placement (never a fixed cap, never 0-by-omission)" \
   "$(has "$cap_row" 'REFUSED' && has "$cap_row" 'fork/task headroom' && echo 0 || echo 1)"
ck "(A) …and cannot-verify is BROKEN (rc=2, got $RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"

# ⛔ AND IT REFUSES ON THE FORK DIMENSION **EVEN WHEN LOAD IS ALSO UNREADABLE** (review round 1): the
# ordering was only half-applied — the capacity.sh `fork` verb sat first, but the SHIM's own fork read
# sat below the `load_unreadable`/`ncpu_unreadable` refusals, so on a box with no capacity.sh beside the
# launcher (the documented fallback) an unforkable box still answered "the load average could not be
# read" and pointed the operator at the loadavg — the misdiagnosis #2293 exists to end. Both unreadable
# at once is the arm that distinguishes the two orders: whichever refusal fires FIRST is the dimension
# the operator is sent to look at.
OUT="$( cd "$TMP" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/bin/ps" PS_TABLE="$TMP/ps-live" HU_LOADAVG_FILE="$TMP/no-such-load" HU_NCPU=4 \
        HARNESS_UP_OS=Linux HU_FORK_LIMITS_FILE="$TMP/does-not-exist" \
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch -o "$CELL/orchestrator" 2>&1 )"; RC=$?
cap_both="$(row capacity)"
ck "(A) with fork AND load unreadable the refusal is the FORK one, not the loadavg (the ordering, on the SHIM path) [$cap_both]" \
   "$(has "$cap_both" 'fork/task headroom' && lacks "$cap_both" 'load average' && echo 0 || echo 1)"
ck "(A) …and it is still BROKEN, never a lane count (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"

# The record path (capacity.sh, the fleet instrument) is consumed — including its fork reading, which
# comes from its OWN `fork` verb rather than from this launcher re-deriving `procs_max − procs`.
# ⛔ THE STUB SPEAKS THE LANDED SCHEMA (`procs=`/`procs_max=`/`fork=`/`src=`, and `headroom=` from the
# verb), because that schema is main's and this branch's short-lived `fork_headroom=` record field was
# dropped — two publishers under one `refs/boxes` namespace is the defect, not the field name.
cat > "$HARNESS/capacity.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  probe) printf 'host=fixture ncpu=4 load1=400 lpc=100 lanes=0 disk_free_mb=9000 mem_free_mb=4000 procs=400 procs_max=15641 fork=1 at=%s\n' "$(date +%s)" ;;
  fork)  printf 'procs=400 procs_max=15641 fork=1 src=uid headroom=15241 min_fork_headroom=200\n' ;;
  *)     exit 2 ;;
esac
SH
chmod +x "$HARNESS/capacity.sh"
run status
ck "(A) the record's OWN fork reading is consumed (via names the fleet instrument, not the shim)" \
   "$(row capacity | grep -q 'via=capacity.sh' && echo 0 || echo 1)"
ck "(A) …and the instrument's fork reading — not a fresh shim probe — decides the placement" \
   "$(row capacity | grep -q 'fork headroom=15241 (capacity.sh:uid)' && echo 0 || echo 1)"
ck "(A) …and the reserve it applied is the FLEET's 200, read from the verb, not a second declaration" \
   "$(row capacity | grep -q 'by fork=376 ' && echo 0 || echo 1)"
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
   "$(has "$lanes_row" '3/4 live and advancing' && echo 0 || echo 1)"
ck "(C) …and a lane SILENT past the controller's own bound is NAMED, with the bound [$lanes_row]" \
   "$(has "$lanes_row" '2400s' && has "$lanes_row" 'fix-4' && echo 0 || echo 1)"
ck "(C) …and a FINISHED lane (a log whose worker record is gone) is IGNORED, not counted silent [$lanes_row]" \
   "$(has "$lanes_row" '1 finished log(s) ignored' && echo 0 || echo 1)"
ck "(C) …so the row is DEGRADED, and the verdict with it (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
touch -t "$fresh" "$L/fix-4.log"
run status
ck "(C) with every live lane inside the bound the row is OK ($(row lanes))" \
   "$(row lanes | grep -q '4/4 live and advancing' && echo 0 || echo 1)"

# ⛔ `chain-*` IS A LIVE LANE TOO (review round 1): `dispatch-merge.sh:217` spawns its
# review→record→merge workers as `chain-<N>` via wt_spawn, and the controller's own census is
# `wt_count lane- chain-`. This row's population pattern spelled `lane-*|merge-*|fix-*` and therefore
# reported a live chain worker as `OK (no lane is live — 0 worker records …)` when it was the ONLY
# worker — a false pass on the exact row that exists to stop false passes.
printf '#!/bin/sh\n' > "$WS/run-chain-7.sh"; : > "$L/chain-7.log"; touch -t "$fresh" "$L/chain-7.log"
rm -f "$WS"/run-*.sh; printf '#!/bin/sh\n' > "$WS/run-chain-7.sh"
run status
ck "(C) a live \`chain-*\` worker (dispatch-merge's own) is COUNTED, not reported as 'no lane is live' [$(row lanes)]" \
   "$(row lanes | grep -q '1/1 live and advancing' && echo 0 || echo 1)"
rm -f "$WS/run-chain-7.sh" "$L/chain-7.log"

# ⛔ A NON-NUMERIC BOUND IS COERCED, NOT TRUSTED. `[ "$age" -le "$HU_LANE_SILENT" ]` with `abc` exits 2,
# so the `if` takes its ELSE branch and EVERY live lane reads SILENT — the row inventing a problem. The
# seam is the shipped name (`HARNESS_UP_LANE_SILENT`); the suite used to export `HU_LANE_SILENT`, which
# the launcher overwrites from the HARNESS_UP_ form, so every bound arm here could only ever see 2400.
for w in lane-1 merge-9; do printf '#!/bin/sh\n' > "$WS/run-$w.sh"; touch -t "$fresh" "$L/$w.log"; done
LANESILENT=abc run status
ck "(C) a non-numeric lane-silent bound falls back to the documented 2400 (live lanes stay ADVANCING) [$(row lanes)]" \
   "$(lacks "$(row lanes)" 'SILENT past abc' && row lanes | grep -q '2/2 live and advancing' && echo 0 || echo 1)"
LANESILENT=600 run status
ck "(C) …and the bound is a real seam: at 600s the same two fresh lanes are inside it, so 2400 is not hard-coded" \
   "$(row lanes | grep -q 'within 600s' && echo 0 || echo 1)"

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
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch --no-heal -o "$CELL/orchestrator" 2>&1 )"; RC=$?
loop_row="$(row loop)"
ck "(C') a controller AND its own refresh child read as ONE controller, not DUPLICATE [$loop_row]" \
   "$(lacks "$loop_row" 'DUPLICATE' && has "$loop_row" 'OK (heartbeat' && echo 0 || echo 1)"
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

# ⛔ A LOG WITH NO DECISION LINE **YET** IS NOT CANNOT-VERIFY (review round 1). `orch-loop.sh:334`
# appends `[startup] worker launcher=…` at boot, CYC (240 s) before the first `[select]` exists — so a
# freshly started box has an EXISTING log with no decision line, and the first version of this row
# answered UNKNOWN(2) there, which made `up` exit 2 AFTER A SUCCESSFUL START (measured: one `[startup]`
# line, every other row green → `VERDICT: BROKEN (rc=2)`). Cannot-verify stays reserved for a
# controller that SHOULD have decided.
: > "$L/orch-loop.log"; printf '[startup] worker launcher=tmux (cmux=no, uname=Linux)\n' > "$L/orch-loop.log"
touch -t "$fresh" "$L/orch-loop.log"
run status
ck "(D) a just-started controller (log carries only [startup]) reads STARTING — not the next decision [$(row next)]" \
   "$(row next | grep -q 'STARTING' && echo 0 || echo 1)"
ck "(D) …and that is not BROKEN: a successful start must never exit 2 because the log is young (rc=$RC)" \
   "$([ "$RC" -le 1 ] && echo 0 || echo 1)"
touch -t "$old" "$L/orch-loop.log"
run status
ck "(D) …while a log PAST the bound with still no decision line IS cannot-verify (a cycle should have decided) [$(row next)]" \
   "$(row next | grep -q 'UNKNOWN' && [ "$RC" -eq 2 ] && echo 0 || echo 1)"

# ⛔ AND THE BOUND ITSELF IS COERCED (review round 1): unvalidated, `[ "$age" -gt abc ]` exits 2, the `if`
# takes its ELSE branch, and a FIVE-HOUR-OLD `[select]` line prints `OK` — the row's polarity inverted in
# the fail-open direction, precisely when it should red.
printf '[select] PR path: 1 acted; issues BLOCKED\n' > "$L/orch-loop.log"
touch -t "$old" "$L/orch-loop.log"
NEXTSTALE=abc run status
# ⛔ CAPTURE, THEN MATCH AS DATA. `row next | grep -q …` is the SIGPIPE false-negative idiom
# (scripts/check-no-sigpipe-grep.sh, #841/#864): under pipefail a quiet grep exits at its first match
# while the producer is still writing, the producer takes SIGPIPE, and the PIPELINE status inverts the
# row's polarity. This file's own rule is that a row's text is EVIDENCE, not pattern syntax — so the
# row is captured once and asked about with `has`/`lacks`.
next_stale_row="$(row next)"
ck "(D) a non-numeric next-stale bound falls back to the documented 900 (a 2h-old line is still LATE, never OK) [$next_stale_row]" \
   "$(has "$next_stale_row" 'LATE' && lacks "$next_stale_row" 'OK:' && echo 0 || echo 1)"
ck "(D) …so the verdict stays DEGRADED rather than flipping to HEALTHY on a bad knob (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
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
   "$(grep -q 'HEAL: started a controller' <<<"$OUT" && echo 0 || echo 1)"
ck "(F1) …and no stop was issued (a heal never kills what is live)" \
   "$([ "$(grep -c '^stop' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"

# ⛔ THE START ARM MUST NOT MANUFACTURE THE DUPLICATE THE OTHER ARMS REFUSE TO HEAL (review round 1).
# The loop row's census is SCOPED to this box's state dir + harness path; a controller executing code
# the records never name — a hand-launched old worktree, `~/.cache/orc/main-orch-loop.sh` — is invisible
# to it and visible to the exec row's ANY census. `orchestrator-bringup.sh`'s registry claim cannot
# refuse it either (a hand-launched controller never registered). Starting on the MISSING arm alone
# therefore put TWO controllers on one repo — double dispatch, two lanes on one PR — from the operator's
# own "tell me the state" call. The heal must check the ANY census before it starts anything.
printf '7777 bash /opt/old-clone/scripts/orch-loop.sh\n' > "$TMP/ps-foreign"
: > "$BRINGUP_LOG"
PS_TABLE="$TMP/ps-foreign" run status
ck "(F1b) a controller live at a path the records do NOT name blocks the heal's start (no duplicate) [$(grep -c '^start' "$BRINGUP_LOG") start(s)]" \
   "$([ "$(grep -c '^start' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F1b) …and it says so, naming the pid and whose decision stopping it is" \
   "$(grep -q 'would DUPLICATE it' <<<"$OUT" && grep -q '7777' <<<"$OUT" && echo 0 || echo 1)"
ck "(F1b) …while the loop row is still the reason it was considered (MISSING by the SCOPED census)" \
   "$(row loop | grep -q 'MISSING' && echo 0 || echo 1)"

# ⛔ AND AN AGED `relation=behind` IS NOT EVIDENCE FOR A REPAIR (review round 1): the refresh row calls
# the same record LATE past `HU_REFRESH_STALE`, so the heal must apply the SAME test before it ACTS.
# Otherwise a days-old `behind` still triggers a fetch + pin advance on a record the row beside it is
# simultaneously calling stale — the "stale flag read as present-tense" class.
: > "$REFRESH_LOG"
printf 'relation=behind running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
touch -t "$(date -v-1d +%Y%m%d%H%M 2>/dev/null || date -d '-1 day' +%Y%m%d%H%M)" "$CELL/orchestrator/state/harness-refresh"
PS_TABLE="$TMP/ps-none" run status
ck "(F2b) an AGED relation=behind triggers NO pin advance (a recorded relation is not a live state) [$(wc -l < "$REFRESH_LOG") refresh call(s)]" \
   "$([ "$(wc -l < "$REFRESH_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F2b) …and the refusal says why, so an operator can tell it from 'nothing to do'" \
   "$(grep -q 'NOT HEALED: the refresh record says relation=behind' <<<"$OUT" && echo 0 || echo 1)"

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
ck "(F2) …and the heal is said" "$(grep -q 'HEAL: re-pinned a stale harness' <<<"$OUT" && echo 0 || echo 1)"

# (F3) restart-pending is REPORTED, never closed by a status verb: closing it means dropping the
# running controller, which is the operator's own down/up.
: > "$REFRESH_LOG"
printf 'relation=restart-pending running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
run status
ck "(F3) restart-pending is NOT healed (no refresh call: closing it would drop the live controller)" \
   "$([ "$(wc -l < "$REFRESH_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F3) …and the refusal names the deliberate remedy" \
   "$(grep -q 'run .harness-down. then .harness-up.' <<<"$OUT" && echo 0 || echo 1)"

printf 'relation=current running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$S12" "$S12" "$S12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"

# (F4) A DUPLICATE controller is never killed from a status verb.
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/orch-loop.sh\n' "$HARNESS" "$HARNESS" > "$TMP/ps-dup"
: > "$BRINGUP_LOG"
PS_TABLE="$TMP/ps-dup" run status
ck "(F4) a DUPLICATE is reported and NEVER killed by status (no start, no stop)" \
   "$([ "$(grep -cE '^(start|stop)' "$BRINGUP_LOG")" -eq 0 ] && echo 0 || echo 1)"
ck "(F4) …and it says whose decision that is" \
   "$(grep -q 'choosing which controller to kill is a human decision' <<<"$OUT" && echo 0 || echo 1)"

# ══ (G) THE macOS ARM IS EXERCISED ═════════════════════════════════════════════════════════════
# BSD-shaped stubs: `sysctl -n kern.maxproc/hw.ncpu/vm.loadavg`. The fork probe on Darwin reads
# kern.maxprocperuid against the uid's process count, so the mac's limit SOURCE is what is asserted.
# ⛔ `id` IS STUBBED TOO (2026-10-24): `hp_fork_headroom`/`cap_fork_headroom` read the CURRENT uid
# with `id -u` and compare it to what `ps -o uid=` reports. The ps stub answers with `PS_UID` (1000),
# so on any host whose real uid is not exactly 1000 the per-uid count matched ZERO rows, `n_uid` came
# back empty, `kern.maxprocperuid` was skipped, and the arm could never reach the 900 it asserts —
# it never showed because the suite died at the `case` parse error above before reaching (G). A stub
# that answers one half of a two-sided comparison has to answer the other half.
cat > "$TMP/bin/id" <<'SH'
#!/bin/sh
case "$*" in
  "-u") echo "${PS_UID:-1000}" ;;
  *)     exec /usr/bin/id "$@" ;;
esac
SH
chmod +x "$TMP/bin/id"
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
        bash "$SCRIPTS/harness-up" status --repo "$REPO" --harness "$HARNESS" --no-fetch -o "$CELL/orchestrator" 2>&1 )"; RC=$?
cap_row="$(row capacity)"
ck "(G) the Darwin arm measures fork headroom from kern.maxprocperuid, not a Linux path [$cap_row]" \
   "$(has "$cap_row" 'fork headroom=900 (' && has "$cap_row" 'kern-maxprocperuid' && echo 0 || echo 1)"
ck "(G) …and a macOS status run reaches a verdict (a BSD mktemp/stat death would end it earlier)" \
   "$(grep -q '^VERDICT: ' <<<"$OUT" && echo 0 || echo 1)"
ck "(G) …with the mac's launchd row present (not the cell arm)" \
   "$(grep -q '^launchd ' <<<"$OUT" && echo 0 || echo 1)"

# ── the suite's own non-vacuity floor (the #1890 class) ────────────────────────────────────────
ck "non-vacuity: at least 20 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 20 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-unit.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
