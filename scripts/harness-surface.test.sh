#!/usr/bin/env bash
# harness-surface.test.sh — the four proofs the ONE launcher owes, each one RED on the tree that
# shipped before it. Every assertion drives the SHIPPED `scripts/harness-up` (and the SHIPPED shim
# block, extracted by its own `>>> shim` markers) — a re-implementation would pass on the broken copy.
#
#   (a) STATUS IS RED WHEN THE EXECUTED SHA IS NOT THE PIN, GREEN WHEN IT IS.
#       The `exec` row reads the RUNNING controller's argv, resolves the tree that path lives in and
#       compares its COMMIT with the pin. Green: a worktree at the pinned commit -> HEALTHY. Red: the
#       same box with the controller executing an OLDER tree (the restart-pending state a pin advance
#       legitimately creates) -> DEGRADED, both shas named. Nothing on the pre-change screen could see
#       the difference: every other row reads a record or the CONFIGURED dir.
#
#   (b) `up` TWICE LEAVES ONE CONTROLLER, AND THE SECOND RUN IS A NO-OP — NOT A RESTART.
#       The authority stub refuses a second start exactly as `orchestrator-bringup.sh` does, so the old
#       code's second `up` called it again and reported FAILED on a healthy box. The assertions are
#       BOTH halves: one controller, and the authority invoked ONCE with the second run saying
#       ALREADY UP. (A count alone would pass on the old tree — the refusal also left one controller.)
#
#   (c) THE CAPACITY DECISION IS A MEASUREMENT, AND IT REFUSES A FIXED-CAP ANSWER.
#       The lane ceiling comes from load and free disk read at the moment of the decision, printed with
#       the numbers. A configured fixed cap is REPORTED AND IGNORED as a ceiling; when the box cannot
#       be measured the decision REFUSES (and `up` refuses with it) rather than substituting the cap.
#
#   (d) THE macOS ARM IS EXERCISED, NOT TRUSTED. `HARNESS_UP_OS=Darwin` plus BSD-shaped stubs
#       (`mktemp` that REQUIRES a template, `sysctl vm.loadavg`, `launchctl print`, BSD `stat`) drive
#       the shim and a full `status` run. The pre-change tree dies here: `mktemp -d` with no template
#       is a usage error on macOS, so every Apple run failed at its last line while Linux stayed green.
#
# Hermetic: fixture repos, throwaway HOME/CELL_HOME, stubbed tools, no network, no real process read.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/harness-up"
fails=0
assertions=0
ck() { # <name> <0|1>
  assertions=$((assertions + 1))
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
# ⛔ A BSD `mktemp` REQUIRES A TEMPLATE — the platform fact this suite exists to keep exercised. The
# suite passes one so that it runs on both platforms; the LAUNCHER's own call is what (d) tests.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-surface.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── the fixture repo: two commits, an old worktree, and a harness at each ──────────────────────
REPO_FIX="$TMP/repo"
mkdir -p "$REPO_FIX/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO_FIX/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho claims\n' > "$REPO_FIX/scripts/orchestrator-harness/claims.sh"
( cd "$REPO_FIX" && git init -q -b main . && git add scripts/orchestrator-harness \
  && git -c user.email=t@example.com -c user.name=t commit -qm A \
  && git update-ref refs/remotes/origin/main refs/heads/main \
  && git remote add origin "$REPO_FIX" ) >/dev/null 2>&1
SHA_A="$(cd "$REPO_FIX" && git rev-parse HEAD)"
# …the OLD tree: a linked worktree at A, which is what a controller left behind by a pin advance runs.
OLD="$TMP/old-tree"
( cd "$REPO_FIX" && git worktree add -q --detach "$OLD" "$SHA_A" ) >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO_FIX/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho fix\n' >> "$REPO_FIX/scripts/orchestrator-harness/claims.sh"
( cd "$REPO_FIX" && git add -A scripts/orchestrator-harness \
  && git -c user.email=t@example.com -c user.name=t commit -qm B \
  && git update-ref refs/remotes/origin/main refs/heads/main ) >/dev/null 2>&1
SHA_B="$(cd "$REPO_FIX" && git rev-parse HEAD)"
A12="${SHA_A:0:12}"; B12="${SHA_B:0:12}"

# The PIN: commit B, materialised under the pin root in the shape `hu_verify_pin` requires.
CELL="$TMP/cell"
PINROOT="$CELL/harness"
( cd "$REPO_FIX" && git worktree add -q --detach "$PINROOT/$B12" "$SHA_B" ) >/dev/null 2>&1
PIN_TREE="$PINROOT/$B12/scripts/orchestrator-harness"
mkdir -p "$PINROOT/$B12/scripts/orchestrator-harness" "$CELL/.pi/agent/state" "$CELL/orchestrator/state" "$CELL/orchestrator/logs"
[ -f "$PIN_TREE/orch-loop.sh" ] || cp "$REPO_FIX/scripts/orchestrator-harness"/*.sh "$PIN_TREE/" 2>/dev/null
printf '%s\n' "$SHA_B" > "$CELL/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$PIN_TREE" > "$CELL/.harness-path"
printf 'relation=current running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$B12" "$B12" "$B12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
printf 'claims=reachable at=%s\n' "$(date +%s)" > "$CELL/orchestrator/state/harness-claims"
: > "$CELL/orchestrator/heartbeat"
# A harness dir carrying what the launcher delegates to (stubs: this suite tests the LAUNCHER).
for d in "$PIN_TREE" "$OLD/scripts/orchestrator-harness"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/check-deployed-drift.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/selftest.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/check-single-source.sh"
  printf '#!/usr/bin/env bash\nprintf "harness relation=current running=x ref=y pin=z action=none fetch=ok\\n"\nexit 0\n' > "$d/harness-refresh.sh"
  chmod +x "$d"/*.sh 2>/dev/null
done

# The process table seam (`HU_PS`): `-eo` answers the whole table, `-p <pid> -o command=` one process.
cat > "$TMP/ps-probe" <<'SH'
#!/bin/sh
case "$*" in
  *-p\ *|*-p=*) pid=""
    while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "$pid" ] && awk -v p="$pid" '$1==p { sub(/^[^ ]+ +/, ""); print; exit }' "$PS_TABLE" 2>/dev/null ;;
  *) cat "$PS_TABLE" 2>/dev/null ;;
esac
exit 0
SH
chmod +x "$TMP/ps-probe"
# ⛔ A TABLE WITH ONE UNRELATED PROCESS, NOT AN EMPTY FILE: an empty census is UNREADABLE to `hu_pids`
# (a real `ps` always lists itself), and an unreadable census is a different case from "no controller".
printf '1 launchd\n9 bash /usr/bin/unrelated.sh\n' > "$TMP/ps-none"
# tmux: the cell's supervisor row reads a SESSION, so it is stubbed to answer "present".
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"
# A load fixture: `HU_LOADAVG_FILE` is the seam (a suite cannot change the box's load).
printf '4.00 1.00 0.50 1/100 4242\n' > "$TMP/load"

run_status() { # <harness-dir>; knobs via the exported shell vars read below
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
          HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="${PS_TABLE:-$TMP/ps-none}" \
          HU_LOADAVG_FILE="${LOADFILE-$TMP/load}" HU_NCPU="${NCPUV:-4}" \
          HARNESS_UP_MAX_LANES="${MAXL:-}" HARNESS_UP_OS="${OSV:-}" \
          HU_DISK_FLOOR_MB="${DISKFLOOR:-500}" HU_DISK_PER_LANE_MB="${DISKCOST:-3000}" \
          bash "$UP" status --repo "$REPO_FIX" --harness "$1" --no-fetch 2>&1 )"
  RC=$?
}

# ══ (a) THE EXEC ROW: RED when the executed sha is not the pin, GREEN when it is ════════════════
# GREEN: the controller executes the PIN's worktree (B), so the screen agrees with itself.
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/cloud-cell-doctor.sh\n' "$PIN_TREE" "$PIN_TREE" > "$TMP/ps-pinned"
PS_TABLE="$TMP/ps-pinned" run_status "$PIN_TREE"
ck "(a) GREEN control: controller on the PIN's tree is HEALTHY (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
case "$OUT" in
  *"exec"*"OK (executing $PIN_TREE/orch-loop.sh @ $B12"*) ck "(a) GREEN: the exec row names the resolved path AND the sha it executes" 0 ;;
  *) ck "(a) GREEN: the exec row names the resolved path AND the sha it executes [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-200)]" 1 ;;
esac
case "$OUT" in *"VERDICT: HEALTHY"*) ck "(a) GREEN: the verdict is HEALTHY" 0 ;; *) ck "(a) GREEN: the verdict is HEALTHY [$(printf '%s' "$OUT" | grep '^VERDICT')]" 1 ;; esac

# RED: the SAME box, one fact changed — the controller executes the OLD tree (A) while the pin is B.
# This is the real restart-pending state a pin advance creates (#2216/#2278), and the state the screen
# reported OK about before this row existed.
printf '4242 bash %s/scripts/orchestrator-harness/orch-loop.sh\n4243 bash %s/scripts/orchestrator-harness/cloud-cell-doctor.sh\n' "$OLD" "$OLD" > "$TMP/ps-old"
PS_TABLE="$TMP/ps-old" run_status "$OLD/scripts/orchestrator-harness"
ck "(a) RED control: a controller executing a tree that is NOT the pin is DEGRADED (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"VERDICT: HEALTHY"*) ck "(a) RED: the verdict is NOT HEALTHY" 1 ;; *) ck "(a) RED: the verdict is NOT HEALTHY" 0 ;; esac
case "$OUT" in
  *"exec"*"DIFFERS"*"$A12"*"$B12"*) ck "(a) RED: the exec row says DIFFERS and names BOTH shas ($A12 vs $B12)" 0 ;;
  *) ck "(a) RED: the exec row says DIFFERS and names BOTH shas ($A12 vs $B12) [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
case "$OUT" in
  *"exec"*"BEHIND"*) ck "(a) RED: the row says WHICH disagreement it is (BEHIND — one restart away)" 0 ;;
  *) ck "(a) RED: the row says WHICH disagreement it is (BEHIND — one restart away) [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac

# ══ (b) `up` TWICE: ONE CONTROLLER, ONE START, AND THE SECOND RUN SAYS ALREADY UP ═══════════════
# The fixture is a checkout-shaped copy of the shipped launcher with its SIBLINGS stubbed, because the
# launcher drives the platform authorities by path — and the authority stub REFUSES a second start the
# way the real one does (`registry_claim_or_refuse`).
# ⛔ THE FIXTURE'S HARNESS DIR IS A WORKTREE AT THE PINNED COMMIT INSIDE ITS OWN PIN ROOT, so the pin
# gate is satisfied by PATHS (all that gate compares on this tree) and the run actually reaches the
# components. Anything looser would test the pin gate instead of the start.
FIXCELL="$TMP/fixcell"
FIXPIN="$FIXCELL/harness"
( cd "$REPO_FIX" && git worktree add -q --detach "$FIXPIN/$B12" "$SHA_B" ) >/dev/null 2>&1
FIX="$FIXPIN/$B12/scripts"
mkdir -p "$FIX/orchestrator-harness" "$FIXCELL/.pi/agent/state" "$FIXCELL/orchestrator/state"
cp "$UP" "$FIX/harness-up"; chmod +x "$FIX/harness-up"
printf '%s\n' "$SHA_B" > "$FIXCELL/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$FIX/orchestrator-harness" > "$FIXCELL/.harness-path"
cat > "$FIX/orchestrator-bringup.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  start)
    printf 'start\n' >> "$FIX_LOG"
    # The REAL authority refuses a second controller for the same repo+state dir.
    if [ -s "$FIX_LIVE" ]; then
      echo "bringup: REFUSED: already running on this machine (pid 4242 at this state dir) — use: status | stop" >&2
      exit 1
    fi
    exit 0 ;;
  stop) printf 'stop\n' >> "$FIX_LOG"; exit 0 ;;
  *) printf '%s\n' "$*" >> "$FIX_LOG"; exit 0 ;;
esac
SH
cat > "$FIX/cloud-cell-supervisor.sh" <<'SH'
#!/usr/bin/env bash
printf 'supervisor %s\n' "${1:-}" >> "$FIX_LOG"; exit 0
SH
chmod +x "$FIX/orchestrator-bringup.sh" "$FIX/cloud-cell-supervisor.sh"
FH="$FIX/orchestrator-harness"
# Every delegate the launcher drives is a stub here: `selftest.sh`/`check-single-source.sh` exit 0,
# `check-deployed-drift.sh` exits 0, and the refresh records a current relation.
for t in selftest.sh check-single-source.sh check-deployed-drift.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FH/$t"
done
printf '#!/usr/bin/env bash\nprintf "harness relation=current running=x ref=y pin=z action=none fetch=ok\\n"\nexit 0\n' > "$FH/harness-refresh.sh"
printf '#!/usr/bin/env bash\n: # the controller the authority starts\n' > "$FH/orch-loop.sh"
chmod +x "$FH"/*.sh
run_up() { # <ps-table>
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
          HOME="$TMP/home" CELL_HOME="$FIXCELL" \
          HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="$1" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
          HU_CLAIMS_TIMEOUT=5 \
          bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"
  RC=$?
}
# First start: the census is readable and holds no controller, so the authority is asked ONCE.
run_up "$TMP/ps-none"
n1="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b) first 'up' asks the authority to start exactly once (n=$n1)" "$([ "$n1" -eq 1 ] && echo 0 || echo 1)"
# …then the box IS up: the control file and the census now both say so, exactly as after a real start.
: > "$FIXCELL/live"
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/cloud-cell-doctor.sh\n' "$FH" "$FH" > "$TMP/ps-up"
: > "$FIXCELL/orchestrator/heartbeat"
run_up "$TMP/ps-up"
n2="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b) the second 'up' does NOT start a second controller (authority started $n2 time(s), want 1)" "$([ "$n2" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"loop: ALREADY UP"*) ck "(b) the second 'up' SAYS ALREADY UP (a no-op, not a silent restart)" 0 ;;
  *) ck "(b) the second 'up' SAYS ALREADY UP (a no-op, not a silent restart) [$(printf '%s' "$OUT" | grep -E 'loop:' | cut -c1-200)]" 1 ;;
esac
ck "(b) the second 'up' does not report a failed start (rc=$RC, not 1-from-a-refusal)" "$([ "$RC" -le 1 ] && echo 0 || echo 1)"
live_n="$(grep -c 'orch-loop.sh' "$TMP/ps-up" | tr -d ' ')"
ck "(b) exactly ONE controller exists after two 'ups' (n=$live_n)" "$([ "$live_n" -eq 1 ] && echo 0 || echo 1)"
# …and the no-op did not cycle ANYTHING: a restart would have logged a stop.
ck "(b) the second 'up' killed nothing (no stop in the authority log)" "$(grep -q '^stop$' "$FIXCELL/fix.log" 2>/dev/null && echo 1 || echo 0)"

# ══ (c) CAPACITY: MEASURED, NEVER A FIXED CAP ══════════════════════════════════════════════════
# ncpu=4 -> ceiling 40.00 load units; 4 load units per lane; load 4.00 -> (40-4)/4 = 9 lanes.
# ⛔ THE EXPECTED NUMBER IS DERIVED FROM THE PRINTED READING, so the assertion is about the RULE and
# not about this box: a fixed `max_lanes` (8, say) cannot satisfy it.
PS_TABLE="$TMP/ps-none" run_status "$PIN_TREE"
cap_line="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the capacity row prints the MEASURED load it used (load=4.00) [$cap_line]" "$(case "$cap_line" in *"load=4.00"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) the capacity row prints the lane ceiling it derived (lanes=9 from ncpu=4, load=4.00)" "$(case "$cap_line" in *"lanes=9 "*) echo 0 ;; *) echo 1 ;; esac)"
MAXL=8 PS_TABLE="$TMP/ps-none" run_status "$PIN_TREE"
cap_fixed="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a configured fixed cap does NOT become the ceiling (still lanes=9, not 8) [$cap_fixed]" "$(case "$cap_fixed" in *"lanes=9 "*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and the fixed cap is REPORTED as IGNORED, not silently discarded" "$(case "$cap_fixed" in *"fixed cap '8'"*"IGNORED as a ceiling"*) echo 0 ;; *) echo 1 ;; esac)"
# A SATURATED box is a measured answer (0 lanes), not a refusal and not a blank.
printf '39.00 1.00 0.50 1/100 4242\n' > "$TMP/load-hot"
LOADFILE="$TMP/load-hot" PS_TABLE="$TMP/ps-none" run_status "$PIN_TREE"
cap_hot="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a saturated box answers lanes=0 WITH the load it read [$cap_hot]" "$(case "$cap_hot" in *"load=39.00"*) case "$cap_hot" in *"lanes=0 "*) echo 0 ;; *) echo 1 ;; esac ;; *) echo 1 ;; esac)"
# ⛔ THE REFUSAL: an unmeasurable box + a fixed cap must NOT answer with the cap.
# A Darwin-shaped arm with a `sysctl` that cannot read the load: the probe has nowhere left to go.
mkdir -p "$TMP/noload"
printf '#!/bin/sh\nexit 1\n' > "$TMP/noload/sysctl"; chmod +x "$TMP/noload/sysctl"
OUT="$( cd "$TMP" && PATH="$TMP/noload:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HARNESS_UP_OS=Darwin \
        HARNESS_UP_MAX_LANES=8 bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
cap_ref="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) an UNMEASURABLE box REFUSES the capacity answer [$cap_ref]" "$(case "$cap_ref" in *REFUSED*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and it never prints the fixed cap as a lane count" "$(case "$cap_ref" in *"lanes=8"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(c) …and the screen is BROKEN, not healthy (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
OUT="$( cd "$TMP" && PATH="$TMP/noload:$TMP:$PATH" FIX_LOG="$FIXCELL/fix2.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HARNESS_UP_OS=Darwin HARNESS_UP_MAX_LANES=8 \
        bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(c) 'up' on an unmeasurable box REFUSES to launch (rc=$RC, documented 3)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"not a measurement"*) ck "(c) the refusal says WHY (a fixed cap is not a measurement)" 0 ;; *) ck "(c) the refusal says WHY (a fixed cap is not a measurement) [$(printf '%s' "$OUT" | grep -iE 'refus' | cut -c1-200)]" 1 ;; esac

# ══ (d) THE macOS ARM: BSD userland, exercised rather than trusted ═════════════════════════════
# The shim is EXTRACTED from the shipped launcher by its own markers — one copy of it, driven here.
sed -n '/^# ══ >>> shim /,/^# ══ <<< shim /p' "$UP" > "$TMP/shim.sh"
ck "(d) the shim block is extractable from the shipped launcher by its own markers" "$([ -s "$TMP/shim.sh" ] && echo 0 || echo 1)"
mkdir -p "$TMP/darwinbin"
# ⛔ BSD mktemp: a TEMPLATE is required. This is the exact shape that killed every Apple run.
cat > "$TMP/darwinbin/mktemp" <<'SH'
#!/bin/sh
case "${1:-}" in -d) shift ;; esac
case "${1:-}" in ''|*X*) ;; esac
[ -n "${1:-}" ] || { echo "usage: mktemp [-d] template" >&2; exit 1; }
printf '%s\n' "$1" >> "$SHIM_LOG.mktemp"
d="$(printf '%s' "$1" | sed 's/X*$//')$$"
mkdir -p "$d" && printf '%s\n' "$d"
SH
# BSD stat: `-f %m` answers; `-c %Y` is a usage error (the reverse of GNU, which is why the shim
# tries GNU first and GUARDS the answer rather than trusting the order).
cat > "$TMP/darwinbin/stat" <<'SH'
#!/bin/sh
case "$1" in
  -f) [ "$2" = "%m" ] && { /usr/bin/stat -c %Y "$3" 2>/dev/null || echo 1700000000; exit 0; }
      echo "stat: illegal option" >&2; exit 1 ;;
  *)  echo "stat: illegal option" >&2; exit 1 ;;
esac
SH
cat > "$TMP/darwinbin/sysctl" <<'SH'
#!/bin/sh
case "$*" in
  *vm.loadavg*) printf '{ 2.50 1.00 0.50 }\n' ;;
  *hw.ncpu*)    printf '4\n' ;;
  *)            exit 1 ;;
esac
SH
# launchctl print: rc 0 + `state = running`; LOADED_NO_PID drops the pid line; ABSENT fails.
cat > "$TMP/darwinbin/launchctl" <<'SH'
#!/bin/sh
case "${LAUNCHD_MODE:-running}" in
  absent) exit 113 ;;
  loaded-no-pid) printf '\tstate = spawn scheduled\n\tlast exit code = 78\n'; exit 0 ;;
  *) printf '\tstate = running\n\tpid = 4242\n'; exit 0 ;;
esac
SH
chmod +x "$TMP/darwinbin"/*
SHIM_LOG="$TMP/shim" HARNESS_UP_OS=Darwin PATH="$TMP/darwinbin:$PATH" \
  bash -c '. "$1/shim.sh"; hu_bounded(){ local s="$1"; shift; "$@"; }; os="$(hp_os)"; m="$(hp_mktemp_d)"
    printf "os=%s\nmktmp=%s\nload=%s\nncpu=%s\ndisk=%s\n" "$os" "$m" "$(hp_load1_c)" "$(hp_ncpu)" "$(hp_disk_free_mb "$1")"
    hp_launchd_loaded com.test.job; printf "launchd_running=%s\n" "$?"
    LAUNCHD_MODE=loaded-no-pid hp_launchd_loaded com.test.job; printf "launchd_dead=%s\n" "$?"
    LAUNCHD_MODE=absent hp_launchd_loaded com.test.job; printf "launchd_absent=%s\n" "$?"' \
  _ "$TMP" > "$TMP/darwin-out" 2>&1
ck "(d) hp_os answers Darwin from the seam" "$(grep -qx 'os=Darwin' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_mktemp_d SUCCEEDS under a BSD mktemp (a template was passed)" "$(case "$(sed -n 's/^mktmp=//p' "$TMP/darwin-out")" in /*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) the BSD mktemp stub RECORDED the templated call (nothing ran untemplated)" "$([ -s "$TMP/shim.mktemp" ] && echo 0 || echo 1)"
ck "(d) hp_load1_c reads sysctl's curly-braced vm.loadavg (2.50 -> 250)" "$(grep -qx 'load=250' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_ncpu reads hw.ncpu (4)" "$(grep -qx 'ncpu=4' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_disk_free_mb answers a number through BSD/POSIX df" "$(sed -n 's/^disk=//p' "$TMP/darwin-out" | grep -qE '^[0-9]+$' && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: running -> 0" "$(grep -qx 'launchd_running=0' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: loaded with NO process -> 1 (the state 'ps' alone cannot name)" "$(grep -qx 'launchd_dead=1' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: not loaded -> 2" "$(grep -qx 'launchd_absent=2' "$TMP/darwin-out" && echo 0 || echo 1)"

# …and the WHOLE launcher on the macOS arm: it must reach a verdict at all (the untemplated mktemp
# used to end the run at its last line), and the launchd row must be a REAL answer, not SKIPPED.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
n_v="$(printf '%s\n' "$OUT" | grep -c '^VERDICT:')"
ck "(d) a macOS-arm 'status' RUNS TO A VERDICT (a BSD mktemp/temp-dir death would end it earlier)" "$([ "$n_v" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"launchd"*"OK (com.eldato.orchestrator-loop is loaded and has a process"*) ck "(d) the launchd row answers LOADED+RUNNING on the macOS arm" 0 ;;
  *) ck "(d) the launchd row answers LOADED+RUNNING on the macOS arm [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac
LAUNCHD_MODE=loaded-no-pid OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=loaded-no-pid HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
case "$OUT" in
  *"launchd"*"LOADED-NO-PROCESS"*) ck "(d) a job loaded with NO process is NAMED as such (not 'MISSING')" 0 ;;
  *) ck "(d) a job loaded with NO process is NAMED as such (not 'MISSING') [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac
# …and the cell arm still says SKIPPED with its reason: not-applicable is a pass, never a fake OK.
PS_TABLE="$TMP/ps-pinned" OSV="" run_status "$PIN_TREE"
case "$OUT" in
  *"launchd"*"SKIPPED (no launchd on this platform"*) ck "(d) the Linux arm SKIPS launchd with its reason (never OK)" 0 ;;
  *) ck "(d) the Linux arm SKIPS launchd with its reason (never OK) [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac

# ── the suite's own non-vacuity floor (the #1890 class) ────────────────────────────────────────
ck "non-vacuity: at least 20 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 20 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-surface.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
