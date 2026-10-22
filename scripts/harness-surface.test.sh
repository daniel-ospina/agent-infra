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
    [ -n "${PS_P_EMPTY:-}" ] && exit 0
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
          HU_DISK_FLOOR_MB="${DISKFLOOR:-500}" HU_DISK_PER_LANE_MB="${DISKCOST:-1100}" \
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

# ⛔ AND THE MAC'S REAL LAYOUT IS NOT A GIT WORKTREE. `install.sh` deploys a FLAT COPY into `$O` and
# the plist execs `__O__/orch-loop.sh` (launchd.plist.template:10, install.sh:26), so `git -C` on that
# dir answers NOTHING. Three wrong answers were tried and rejected in two review rounds: `DIFFERS`
# (asserts the code IS different — nobody established that), `BROKEN`(2) (honest but makes `up` exit 2
# AFTER a successful start on the owner's own machine), `SKIPPED` (hides the state #2271 fixes). The
# row must NAME the layout, return DEGRADED, and never a false OK.
printf '4242 bash %s/orchestrator/orch-loop.sh\n' "$CELL" > "$TMP/ps-flat"
PS_TABLE="$TMP/ps-flat" run_status "$PIN_TREE"
case "$OUT" in
  *"exec"*"UNIDENTIFIED (executing $CELL/orchestrator/orch-loop.sh"*"flat copy with NO git identity"*) ck "(a-mac) a FLAT-copy controller (no .git) is NAMED, not silently OK" 0 ;;
  *) ck "(a-mac) a FLAT-copy controller (no .git) is NAMED, not silently OK [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
# ⛔ THE EXEC ROW ONLY: "SKIPPED" legitimately appears in OTHER rows on this platform (launchd,
# supervisor), so the whole-output substring test reddened on a healthy screen.
exec_row="$(printf '%s\n' "$OUT" | grep -E '^exec ' | head -1)"
ck "(a-mac) …and it is not SKIPPED away (the state #2271 fixes must stay visible) [$exec_row]" "$(case "$exec_row" in *SKIPPED*) echo 1 ;; *) echo 0 ;; esac)"
ck "(a-mac) …and never a false OK about a copy nobody can identify" "$(case "$exec_row" in *"OK (executing"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(a-mac) …so the screen is DEGRADED (rc=$RC) — red enough to act on, not a broken box" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"

# ⛔ A PIN THAT DOES NOT RESOLVE IS NOT "NO PIN" (found by review): falling through to the harness dir
# printed `OK` about a DIFFERENT reference while the pin named a commit nothing could read — a false
# OK about the wrong tree. Its own verdict has to be UNRESOLVABLE/cannot-verify.
cp "$CELL/.pi/agent/state/HARNESS-PIN" "$TMP/pin.hold"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$CELL/.pi/agent/state/HARNESS-PIN"
PS_TABLE="$TMP/ps-pinned" run_status "$PIN_TREE"
case "$OUT" in
  *"exec"*"UNRESOLVABLE"*) ck "(a) a pin naming a commit this repo does not have is UNRESOLVABLE, not a fall-through" 0 ;;
  *) ck "(a) a pin naming a commit this repo does not have is UNRESOLVABLE, not a fall-through [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
case "$OUT" in *"exec"*"OK (executing"*) ck "(a) …and it never reports OK against a reference the pin did not name" 1 ;; *) ck "(a) …and it never reports OK against a reference the pin did not name" 0 ;; esac
cp "$TMP/pin.hold" "$CELL/.pi/agent/state/HARNESS-PIN"

# ⛔ AND IT MUST SEE A CONTROLLER THAT IS NOT AT THIS BOX'S TWO PATHS (review round 3): the `loop` row's
# census is deliberately scoped to `$HARNESS`/`$O` ("is THIS deployment running"), but the `exec` row
# asks "WHAT is running" — so a controller executing a third tree (a hand-launched old worktree, the
# `~/.cache/orc` shape) must be RESOLVED AND COMPARED, not reported as `MISSING (no controller)`. That
# distinction is the whole reason this row exists, and the earlier arms all used an in-scope path.
printf '4242 bash %s/scripts/orchestrator-harness/orch-loop.sh\n' "$OLD" > "$TMP/ps-elsewhere"
PS_TABLE="$TMP/ps-elsewhere" run_status "$PIN_TREE"
exec_elsewhere="$(printf '%s\n' "$OUT" | grep -E '^exec ' | head -1)"
ck "(a) a controller from a THIRD tree is resolved and compared, not MISSING [$exec_elsewhere]" \
   "$(case "$exec_elsewhere" in *MISSING*) echo 1 ;; *"$A12"*) echo 0 ;; *) echo 1 ;; esac)"

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

# …and a STATUS runner over the same fixture. The FIX launcher has no `capacity.sh` beside it, so the
# capacity block drives the SHIM probe under scripted readings — the (c) arms below are about the
# RULE (a measured ceiling), while the reuse arm further down proves capacity.sh is consumed when it
# IS there.
run_status_fix() { # uses the caller's PS_TABLE (the fixture launcher)
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
          HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="${PS_TABLE:-$TMP/ps-none}" HU_LOADAVG_FILE="${LOADFILE-$TMP/load}" HU_NCPU="${NCPUV:-4}" \
          HARNESS_UP_MAX_LANES="${MAXL:-}" HARNESS_UP_OS="${OSV:-}" \
          HU_DISK_FLOOR_MB="${DISKFLOOR:-500}" HU_DISK_PER_LANE_MB="${DISKCOST:-1100}" \
          bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"
  RC=$?
}

# ⛔ THE MAC'S CONTROLLER RUNS FROM `$O`, NOT FROM `HARNESS` — and `up` deploys to `$O`
# (install.sh:26). An ALREADY-UP check that accepted only `$HARNESS` reported a healthy Mac's second
# `up` as a FAILED START, i.e. it re-created the defect this whole arm removes (found by review).
printf '4242 bash %s/orchestrator/orch-loop.sh\n' "$FIXCELL" > "$TMP/ps-up-o"
run_up "$TMP/ps-up-o"
n3="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b-mac) a controller executing the DEPLOYED \$O copy is ALREADY UP (authority starts still $n3)" "$([ "$n3" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"loop: ALREADY UP"*) ck "(b-mac) …and says so, instead of reporting a healthy Mac as a failed start" 0 ;;
  *) ck "(b-mac) …and says so, instead of reporting a healthy Mac as a failed start [$(printf '%s' "$OUT" | grep -E 'loop:|FAILED' | cut -c1-200)]" 1 ;;
esac
# ⛔ AND THE RUN'S EXIT CODE IS PART OF THE CONTRACT (review round 2): `up` ends with the status verb, so
# a row that returns BROKEN makes a SUCCESSFUL start exit 2. On this layout the exit must be DEGRADED at
# worst — the row is named, and nothing failed to run.
ck "(b-mac) …and 'up' on that layout exits DEGRADED at worst (rc=$RC), never 2-after-a-successful-start" "$([ "$RC" -le 1 ] && echo 0 || echo 1)"

# ⛔ AN UNREADABLE PATH IS NOT A FOREIGN ONE (review round 5): when the single-process read answers
# nothing (a pid that exited between the census and the read, a restricted /proc), `up` used to assert
# "NOT from this run's harness" — a fact nobody established — with a `down`/`up` remedy an operator
# should not follow on a healthy box. It must say only what is known and still fail closed.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix3.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-up" PS_P_EMPTY=1 HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(b) an UNREADABLE controller argv is reported as unknown, not as a foreign harness (rc=$RC, fail closed)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "(b) …and the message says it CANNOT TELL, rather than asserting 'NOT from this run'" \
   "$(case "$OUT" in *"CANNOT TELL"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(b) …and it never claims a foreign harness it did not observe" \
   "$(case "$OUT" in *"NOT from this run's harness"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(b) …and it still starts nothing and kills nothing (authority start count unchanged)" \
   "$([ "$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)" -eq 1 ] && echo 0 || echo 1)"

# ══ (c) CAPACITY: MEASURED, NEVER A FIXED CAP — AND THE PROBE IS capacity.sh's ═════════════════
# ncpu=4 -> ceiling 8.00 load/cpu = 32.00 load units; 4.00 load units per lane; load 4.00 ->
# (32.00-4.00)/4.00 = 7 lanes. ⛔ THE EXPECTED NUMBER IS DERIVED FROM THE PRINTED READING, so the
# assertion is about the RULE and not about this box: a fixed `max_lanes` (8, say) cannot satisfy it.
PS_TABLE="$TMP/ps-none" run_status_fix
cap_line="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the capacity row prints the MEASURED load it used (load=4.00) [$cap_line]" "$(case "$cap_line" in *"load=4.00"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) the capacity row prints the lane ceiling it derived (lanes=7 from ncpu=4, load=4.00)" "$(case "$cap_line" in *"lanes=7 "*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and it names WHICH probe answered (via=shim, this fixture has no capacity.sh)" "$(case "$cap_line" in *"via=shim"*) echo 0 ;; *) echo 1 ;; esac)"
MAXL=8 PS_TABLE="$TMP/ps-none" run_status_fix
cap_fixed="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a configured fixed cap does NOT become the ceiling (still lanes=7, not 8) [$cap_fixed]" "$(case "$cap_fixed" in *"lanes=7 "*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and the fixed cap is REPORTED as IGNORED, not silently discarded" "$(case "$cap_fixed" in *"fixed cap '8'"*"IGNORED as a ceiling"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ A LEADING ZERO IS OCTAL TO `$(( ))` (review round 3): `HU_LOAD_PER_LANE=0400` divided by 256 and
# reported 10 lanes where the reading supports 7 (a 43% over-report, in the direction that over-places
# work), and `HU_LOAD_PER_CPU=0800` did not parse at all. The same reading must give the same answer
# whichever spelling an operator uses.
NCPUV=4 LOADFILE="$TMP/load" PS_TABLE="$TMP/ps-none" run_status_fix
cap_plain="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
HU_LOAD_PER_LANE=0400 HU_LOAD_PER_CPU=0800 PS_TABLE="$TMP/ps-none" run_status_fix
cap_zero="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
# ⛔ `[[:space:]]` would be wrong here: the ROW renders `OK (lanes=7 …`, so the field is not preceded by
# a space (only the machine record is). Measured — the anchored form silently read nothing.
plain_lanes="$(printf '%s' "$cap_plain" | sed -n 's/.*lanes=\([0-9]*\) .*/\1/p' | head -1)"
zero_lanes="$(printf '%s' "$cap_zero" | sed -n 's/.*lanes=\([0-9]*\) .*/\1/p' | head -1)"
ck "(c) a leading-zero knob does not become OCTAL (0400/0800 -> lanes=${zero_lanes:-none}, plain=${plain_lanes:-none}) [$cap_zero]" \
   "$([ -n "$plain_lanes" ] && [ "$plain_lanes" = "$zero_lanes" ] && echo 0 || echo 1)"

# A SATURATED box is a measured answer (0 lanes), not a refusal and not a blank.
printf '39.00 1.00 0.50 1/100 4242\n' > "$TMP/load-hot"
LOADFILE="$TMP/load-hot" PS_TABLE="$TMP/ps-none" run_status_fix
cap_hot="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a saturated box answers lanes=0 WITH the load it read [$cap_hot]" "$(case "$cap_hot" in *"load=39.00"*) case "$cap_hot" in *"lanes=0 "*) echo 0 ;; *) echo 1 ;; esac ;; *) echo 1 ;; esac)"
# ⛔ THE PROBE IS REUSED, NOT RE-IMPLEMENTED. A `capacity.sh` beside the launcher answers with a load
# this box's own /proc does not carry, and the row must report THAT reading (via=capacity.sh): a second
# probe wearing the fleet instrument's name is exactly the duplication the house rule forbids.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CAPSH_ARGV"\nprintf "host=fixture ncpu=2 load1=1234 lpc=617 lanes=0 disk_free_mb=9000 mem_free_mb=10 at=%s\\n" "$(date +%%s)"\n' > "$FH/capacity.sh"
chmod +x "$FH/capacity.sh"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" CAPSH_ARGV="$TMP/capsh.argv" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
cap_sh="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the row CONSUMES capacity.sh's record, not its own probe (via=capacity.sh, load=12.34 ncpu=2) [$cap_sh]" \
   "$(case "$cap_sh" in *"via=capacity.sh"*) case "$cap_sh" in *"load=12.34"*"ncpu=2"*) echo 0 ;; *) echo 1 ;; esac ;; *) echo 1 ;; esac)"
# ⛔ AND IT IS HANDED THE PATH WHOSE VOLUME FILLS (review round 2): `capacity.sh probe` with no argument
# measures the CALLER's cwd, so a box whose cwd is on another volume than the state dir over-reports
# free disk — wrong in the direction this feature exists to prevent.
ck "(c) the probe is passed the state dir whose volume lanes fill (\$O), not the caller's cwd [$(cat "$TMP/capsh.argv" 2>/dev/null)]" \
   "$(case "$(cat "$TMP/capsh.argv" 2>/dev/null)" in *"$FIXCELL/orchestrator"*) echo 0 ;; *) echo 1 ;; esac)"
rm -f "$FH/capacity.sh"
# …and the default ceiling is PINNED EQUAL to that file's own, so the two instruments cannot drift.
cap_const="$(sed -n 's/^CAP_LPC_CEILING="${CAP_LPC_CEILING:-\([0-9]*\)}".*/\1/p' "$HERE/orchestrator-harness/capacity.sh" 2>/dev/null | head -1)"
up_const="$(sed -n 's/.*percpu="${HU_LOAD_PER_CPU:-\([0-9]*\)}".*/\1/p' "$UP" | head -1)"
ck "(c) the load ceiling default equals capacity.sh's CAP_LPC_CEILING (up=$up_const capacity=$cap_const)" "$([ -n "$cap_const" ] && [ "$cap_const" = "$up_const" ] && echo 0 || echo 1)"
# ⛔ THE REFUSAL: an unmeasurable box + a fixed cap must NOT answer with the cap. A Darwin-shaped arm
# with a `sysctl` that cannot read the load, and a launcher whose sibling harness dir has no
# capacity.sh (the fallback path), so the probe has nowhere left to go.
mkdir -p "$TMP/noload"
printf '#!/bin/sh\nexit 1\n' > "$TMP/noload/sysctl"; chmod +x "$TMP/noload/sysctl"
OUT="$( cd "$TMP" && PATH="$TMP/noload:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HARNESS_UP_OS=Darwin \
        HARNESS_UP_MAX_LANES=8 bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
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
  absent) printf 'Could not find service "com.test.job" in domain for user gui: 501\n' >&2; exit 113 ;;
  # ⛔ A DOMAIN-LEVEL REJECTION: non-zero, and it says NOTHING about the service (measured shape of
  # `launchctl print gui/0/x` under root, and of an SSH context with no gui domain).
  bad-domain) printf 'Bad request.\nCould not find domain for user gui: 0\n' >&2; exit 113 ;;
  loaded-no-pid) printf '\tstate = spawn scheduled\n\tlast exit code = 78\n'; exit 0 ;;
  # A recorded exit that keeps being followed by no process — with the cumulative launch count.
  crashloop) printf '\tstate = spawn scheduled\n\tlast exit code = 128\n\truns = 7\n'; exit 0 ;;
  # NO launch count at all: the row may print the code and must invent no count.
  died) printf '\tstate = spawn scheduled\n\tlast exit code = 128\n'; exit 0 ;;
  # A CLEAN exit with a climbing launch count: `orch-loop.sh`'s "already running" path does `exit 0`,
  # so KeepAlive relaunches it cleanly, for ever. This must NOT read as a crash.
  clean-exit) printf '\tstate = spawn scheduled\n\tlast exit code = 0\n\truns = 7\n'; exit 0 ;;
  # Loaded, no process, and launchd has NEVER launched it (runs = 0 settles "never kicked").
  never-started) printf '\tstate = spawn scheduled\n\truns = 0\n'; exit 0 ;;
  # ⛔ `last exit code = 0` IS launchd's CALLOC DEFAULT, so a job that never ran reports it too.
  # `runs = 0` is the decisive datum and must WIN over it (review round 3).
  default-clean) printf '\tstate = spawn scheduled\n\tlast exit code = 0\n\truns = 0\n'; exit 0 ;;
  # A SIGNED status (a signal death). A present datum must not be reported as absent.
  signed) printf '\tstate = spawn scheduled\n\tlast exit code = -15\n\truns = 3\n'; exit 0 ;;
  # NON-CANONICAL INTEGER: `00` must normalise to a clean 0, not read as a crash (round 5).
  zerozero) printf '\tstate = spawn scheduled\n\tlast exit code = 00\n\truns = 5\n'; exit 0 ;;
  # Loaded with no process AND no exit data at all: the row may not invent one.
  no-data) printf '\tstate = spawn scheduled\n'; exit 0 ;;
  *) printf '\tstate = running\n\tpid = 4242\n'; exit 0 ;;
esac
SH
chmod +x "$TMP/darwinbin"/*
SHIM_LOG="$TMP/shim" HARNESS_UP_OS=Darwin PATH="$TMP/darwinbin:$PATH" \
  bash -c '. "$1/shim.sh"; hu_bounded(){ local s="$1"; shift; "$@"; }; os="$(hp_os)"; m="$(hp_mktemp_d)"
    printf "os=%s\nmktmp=%s\nload=%s\nncpu=%s\ndisk=%s\n" "$os" "$m" "$(hp_load1_c)" "$(hp_ncpu)" "$(hp_disk_free_mb "$1")"
    hp_launchd_loaded com.test.job; printf "launchd_running=%s\n" "$?"
    LAUNCHD_MODE=loaded-no-pid hp_launchd_loaded com.test.job; printf "launchd_dead=%s\n" "$?"
    LAUNCHD_MODE=absent hp_launchd_loaded com.test.job; printf "launchd_absent=%s\n" "$?"
    LAUNCHD_MODE=bad-domain hp_launchd_loaded com.test.job; printf "launchd_baddomain=%s\n" "$?"' \
  _ "$TMP" > "$TMP/darwin-out" 2>&1
ck "(d) hp_os answers Darwin from the seam" "$(grep -qx 'os=Darwin' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_mktemp_d SUCCEEDS under a BSD mktemp (a template was passed)" "$(case "$(sed -n 's/^mktmp=//p' "$TMP/darwin-out")" in /*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) the BSD mktemp stub RECORDED the templated call (nothing ran untemplated)" "$([ -s "$TMP/shim.mktemp" ] && echo 0 || echo 1)"
ck "(d) hp_load1_c reads sysctl's curly-braced vm.loadavg (2.50 -> 250)" "$(grep -qx 'load=250' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_ncpu reads hw.ncpu (4)" "$(grep -qx 'ncpu=4' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_disk_free_mb answers a number through BSD/POSIX df" "$(sed -n 's/^disk=//p' "$TMP/darwin-out" | grep -qE '^[0-9]+$' && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: running -> 0" "$(grep -qx 'launchd_running=0' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: loaded with NO process -> 1 (the state 'ps' alone cannot name)" "$(grep -qx 'launchd_dead=1' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: launchd's own SERVICE-level not-found -> 2 (absent)" "$(grep -qx 'launchd_absent=2' "$TMP/darwin-out" && echo 0 || echo 1)"
# ⛔ rc IS NOT THE VERDICT (review round 4): a DOMAIN-level rejection is non-zero too, and calling it
# NOT LOADED answers a question nobody answered — with a re-install remedy. Same rule as launchd-cycle.sh
# `lc_probe` and orchestrator-bringup.sh `launchd_job_state`.
ck "(d) hp_launchd_loaded: a DOMAIN rejection -> 5 cannot-verify, NOT 'not loaded'" "$(grep -qx 'launchd_baddomain=5' "$TMP/darwin-out" && echo 0 || echo 1)"

# ⛔ "NO USABLE BOUND" IS NOT "launchctl IS ABSENT" (review round 2): `hu_bounded` returns 125 when perl
# is missing, and folding that into 3 made the row send the operator after a binary that is already
# there. A PATH holding launchctl (and nothing else that matters) but NO perl is the exact regime — the
# REAL helpers block is sourced, so the 125 is the shipped bound's own answer, not a test fixture's.
BASH_BIN="$(command -v bash)"
mkdir -p "$TMP/noperl"
cp "$TMP/darwinbin/launchctl" "$TMP/noperl/launchctl"; chmod +x "$TMP/noperl/launchctl"
printf '#!/bin/sh\nprintf "501\\n"\n' > "$TMP/noperl/id"; chmod +x "$TMP/noperl/id"
sed -n '/^# >>> helpers$/,/^# <<< helpers$/p' "$UP" > "$TMP/helpers.sh"
NOPERL="$( HARNESS_UP_OS=Darwin PATH="$TMP/noperl" "$BASH_BIN" -c '. "$1/helpers.sh"; hp_launchd_loaded com.test.job; printf "%s" "$?"' _ "$TMP" 2>/dev/null )"
ck "(d) an unbindable probe (launchctl present, perl absent) answers 125 — NOT 'launchctl absent' (got '${NOPERL:-nothing}')" "$([ "$NOPERL" = 125 ] && echo 0 || echo 1)"

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
  *"launchd"*"DIED (last exit 78"*) ck "(d) a job loaded with NO process NAMES launchd's own exit code (78), not a shrug" 0 ;;
  *) ck "(d) a job loaded with NO process NAMES launchd's own exit code (78) [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac
# ⛔ THE STATE THIS WHOLE ROW EXISTS FOR (2026-10-22). The Mac's `com.eldato.orchestrator-loop` sat at
# LAST EXIT 128 — a fork/spawn failure — and the row could only say "it is crashing or was never
# kicked". The exit code and launchd's own launch count are in the block the row already reads, so
# the row must CARRY them instead of dropping them.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=crashloop HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a NON-ZERO exit is NAMED DIED with launchd's own code (128) [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit 128"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and the launch count is carried as EVIDENCE (7 launch(es)) [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in *"7 launch(es)"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs` IS CUMULATIVE AND MAY NOT BECOME A VERDICT (review, 2026-10-22 and again cycle 2). Two
# assertions, because a vocabulary-only negation is defeatable: a re-add worded `CRASH-LOOP` or
# `LOOPING` would pass a check that only looked for the literal `PERSISTENT`. So: negate the whole
# verdict vocabulary in use, AND positively require the CONDITIONAL sentence that makes the count
# evidence rather than a diagnosis.
# ⛔ THE `""` ARM IS THE POINT (review round 4): without it an EMPTY row makes every negative
# assertion pass — the row could stop being emitted entirely and these would stay green.
ck "(d) …but a cumulative count is NOT turned into any crash/persistence verdict [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in ""|*CRASH*|*PERSIST*|*LOOP*|*"will not help"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(d) …and persistence is stated CONDITIONALLY, so the count is evidence not a verdict [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in *"if it STAYS here"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ A CLEAN EXIT IS NOT A CRASH (review cycle 2). `orch-loop.sh`'s lock path prints "already running"
# and `exit 0`; with KeepAlive that is a job that exits IMMEDIATELY and cleanly, every time. Calling
# it DIED and pointing at `launchd.err` (that message goes to STDOUT) is a named WRONG CAUSE — worse
# than the old agnostic wording.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=clean-exit HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a CLEAN exit (0) is NAMED EXITED-CLEAN, not DIED [$launchd_row]" \
   "$(case "$launchd_row" in *EXITED-CLEAN*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and it does NOT claim every attempt is failing [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in ""|*"every attempt is failing"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(d) …and it points at launchd.OUT, which is where 'already running' is written [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in *launchd.out*launchd.err*|*launchd.err*) echo 1 ;; *launchd.out*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs = 0` SETTLES "NEVER KICKED" even with no exit code — the count is not discarded when the
# code is absent (review cycle 2).
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=never-started HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) 'no exit code + 0 launches' is NAMED NEVER-STARTED, not 'crashing or never kicked' [$launchd_row]" \
   "$(case "$launchd_row" in *NEVER-STARTED*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs = 0` MUST BEAT A DEFAULT `last exit code = 0` (review round 3). launchd callocs
# last_exit_status to 0, so a never-launched job reports "last exit code = 0" too; branching on the
# code first named a lock-contention cause and hid the `kickstart` remedy for a job that never ran.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=default-clean HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) '0 launches' WINS over launchd's default 'last exit code = 0' — NEVER-STARTED, not EXITED-CLEAN [$launchd_row]" \
   "$(case "$launchd_row" in *NEVER-STARTED*) echo 0 ;; *EXITED-CLEAN*) echo 1 ;; *) echo 1 ;; esac)"
# ⛔ A SIGNED STATUS IS A PRESENT DATUM. Dropping it would report a signal death as "no exit code".
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=signed HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a SIGNED exit status is carried, not dropped as 'no exit code' [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit -15"*) echo 0 ;; *) echo 1 ;; esac)"

# ⛔ A NON-CANONICAL INTEGER IS NORMALISED, NOT ECHOED (review round 5): `00` is a clean exit, and
# a lax `[0-9]*` pattern would render `DIED (last exit 00)` — a clean exit named a crash.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=zerozero HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a non-canonical '00' normalises to a CLEAN exit, not a crash [$launchd_row]" \
   "$(case "$launchd_row" in *EXITED-CLEAN*) echo 0 ;; *) echo 1 ;; esac)"
# An exit with NO launch count still prints the code, and invents no count.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=died HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) an exit with NO launch count still prints the code [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit 128"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and invents no count when launchd published none [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in ""|*"launch(es)"*|*"0 launches"*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AN ABSENT DATUM IS NEVER RENDERED AS A VALUE. With neither an exit code nor a run count the row
# must fall back to LOADED-NO-PROCESS rather than claim "last exit 0" or "0 launches".
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=no-data HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) with NO exit data the row falls back to LOADED-NO-PROCESS (it never invents a status) [$launchd_row]" \
   "$(case "$launchd_row" in *LOADED-NO-PROCESS*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and invents neither a code nor a count [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in ""|*"last exit 0"*|*"0 launches"*) echo 1 ;; *) echo 0 ;; esac)"
# …and a DOMAIN-level rejection must not become a confident NOT LOADED + re-install remedy (review
# round 4): rc is not the verdict, the text is — the rule launchd-cycle.sh `lc_probe` and
# orchestrator-bringup.sh `launchd_job_state` both state.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=bad-domain HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) an unverifiable launchd read is UNKNOWN in the row [$launchd_row]" "$(case "$launchd_row" in *UNKNOWN*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and NOT 'NOT LOADED' with a re-install remedy" "$(case "$launchd_row" in *"NOT LOADED"*) echo 1 ;; *) echo 0 ;; esac)"
# …and the cell arm still says SKIPPED with its reason: not-applicable is a pass, never a fake OK.
PS_TABLE="$TMP/ps-pinned" OSV="" run_status "$PIN_TREE"
case "$OUT" in
  *"launchd"*"SKIPPED (no launchd on this platform"*) ck "(d) the Linux arm SKIPS launchd with its reason (never OK)" 0 ;;
  *) ck "(d) the Linux arm SKIPS launchd with its reason (never OK) [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac

# ══ (e) THE PIN RESOLVES IN THE HARNESS REPO, NEVER IN THE TARGET CHECKOUT ══════════════════════
# A cell's ambient `REPO` is the TARGET checkout — that is `orch-loop.sh`'s contract ("export REPO=<the
# target repo's checkout>"; it reads the backlog from it and `orchestrator-bringup.sh` verifies `$OR`
# against it). The launcher needs the AGENT-INFRA checkout, where the pin's commit is an object. Taking
# the ambient value first resolved the pin in the wrong repo, so a box whose pin and tree were the SAME
# tree refused with `pin: UNRESOLVABLE … is not an object in <target>` (measured 2026-10-22, on a box
# whose records were pin = tree = 1af06f52c2cd). RED on that tree: the same records + one exported
# variable. The fix must NOT weaken the gate: the bad-pin control below still refuses, and names the
# repo it checked.
TARGET_FIX="$TMP/target-repo"
mkdir -p "$TARGET_FIX"
( cd "$TARGET_FIX" && git init -q -b main . && printf 'x\n' > a && git add a \
  && git -c user.email=t@example.com -c user.name=t commit -qm target ) >/dev/null 2>&1
# The child's own REPO is the second half of the contract: the authority stub records what it received.
# ⛔ REWRITTEN (not appended): every arm of the stub ENDS on `exit 0`, so a line after the `esac` never
# runs — the record has to sit inside the START arm it is about to describe.
cat > "$FIX/orchestrator-bringup.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  start)
    printf 'start\n' >> "$FIX_LOG"
    # (e) the target checkout the launcher exported to the controller, recorded BEFORE the start.
    printf 'repo=%s\n' "${REPO:-}" >> "$FIX_LOG"
    if [ -s "$FIX_LIVE" ]; then
      echo "bringup: REFUSED: already running on this machine (pid 4242 at this state dir) — use: status | stop" >&2
      exit 1
    fi
    exit 0 ;;
  stop) printf 'stop\n' >> "$FIX_LOG"; exit 0 ;;
  *) printf '%s\n' "$*" >> "$FIX_LOG"; exit 0 ;;
esac
SH
run_pin_cell() { # <pin-file>; ambient REPO = a DIFFERENT (target) checkout, harness derived (NO --repo/HARNESS_REPO)
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix-e.log" FIX_LIVE="$FIXCELL/live-e" \
          HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$TARGET_FIX" \
          HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
          HU_CLAIMS_TIMEOUT=5 \
          bash "$FIX/harness-up" up --harness "$FH" --no-fetch 2>&1 )"
  RC=$?
}
rm -f "$FIXCELL/fix-e.log"
run_pin_cell "$FIXCELL/.pi/agent/state/HARNESS-PIN"
pin_all="$(printf '%s\n' "$OUT" | grep -E '^ *pin:' || true)"
ck "(e) the pin resolves and is OK while the ambient REPO is the target checkout [$(printf '%s' "$pin_all" | tr '\n' '|')]" \
   "$(case "$pin_all" in *"pin: OK"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and it is NOT reported UNRESOLVABLE/unreadable against that target" \
   "$(case "$pin_all" in *UNRESOLVABLE*|*UNREADABLE*) echo 1 ;; *) echo 0 ;; esac)"
ck "(e) …and 'up' got past the pin gate (rc=$RC, not the exit-3 refusal)" "$([ "$RC" -ne 3 ] && echo 0 || echo 1)"
tgt_line="$(printf '%s\n' "$OUT" | grep -E '^    target' | head -1)"
ck "(e) the banner names the TARGET checkout as what the controller grades [$tgt_line]" \
   "$(case "$tgt_line" in *"$TARGET_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND THE DERIVATION REALLY RAN: with no `--repo`/`HARNESS_REPO`, the harness repo came from the
# launcher's own main worktree. An arm that let `HARNESS_REPO` short-circuit the candidate loop would
# stay green while the production path (the cell in the PR's measured case has no HARNESS_REPO) rotted.
har_line="$(printf '%s\n' "$OUT" | grep -E '^==> harness-up' | head -1)"
ck "(e) …and the HARNESS repo was DERIVED, not passed in [$har_line]" \
   "$(case "$har_line" in *"$REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
child_repo="$(sed -n 's/^repo=//p' "$FIXCELL/fix-e.log" 2>/dev/null | head -1)"
ck "(e) the controller is handed the TARGET as REPO (got: ${child_repo:-<none>})" \
   "$([ "$child_repo" = "$TARGET_FIX" ] && echo 0 || echo 1)"
# …the RED CONTROL that keeps this a check and not a bypass: the same cell shape, a pin naming a
# commit that exists in NO repo, must still REFUSE before anything starts.
cp "$FIXCELL/.pi/agent/state/HARNESS-PIN" "$TMP/pin.e.hold"
printf '%040d\n' 1 > "$FIXCELL/.pi/agent/state/HARNESS-PIN"
: > "$FIXCELL/fix-e.log"
run_pin_cell "$FIXCELL/.pi/agent/state/HARNESS-PIN"
bad_line="$(printf '%s\n' "$OUT" | grep -E 'pin:' | head -1)"
ck "(e) RED control: a pin naming a commit no repo has is still UNRESOLVABLE [$bad_line]" \
   "$(case "$bad_line" in *"pin: UNRESOLVABLE"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) RED control: …and 'up' REFUSES with exit 3 before starting anything (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
ck "(e) RED control: …and nothing was started (no 'start' in the authority log)" \
   "$(grep -q '^start$' "$FIXCELL/fix-e.log" 2>/dev/null && echo 1 || echo 0)"
# …and the refusal names the repo it checked, so an operator is sent to the right checkout.
ck "(e) RED control: …and the message names the HARNESS repo it resolved in [$bad_line]" \
   "$(case "$bad_line" in *"$REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
cp "$TMP/pin.e.hold" "$FIXCELL/.pi/agent/state/HARNESS-PIN"

# ⛔ (e2) A CANDIDATE IS PROVEN BY WHAT IT CAN RESOLVE. Reordering the list is not enough: the machine's
# CONFIG file names a TARGET checkout too, so on a layout whose launcher derivation yields nothing (a
# flat, non-git copy — the macOS `$O` shape) the config's value would win and reproduce the exact
# wrong-repo refusal. Same records; the only thing that can identify the harness repo is what resolves
# the pin's commit.
FLAT="$TMP/flat-harness"
mkdir -p "$FLAT"
cp -a "$FIX"/. "$FLAT/" 2>/dev/null
printf 'REPO=%s\n' "$TARGET_FIX" > "$TMP/e2-keys.env"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix-e2.log" FIX_LIVE="$FIXCELL/live-e2" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" ENV_FILE="$TMP/e2-keys.env" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 \
        bash "$FLAT/harness-up" up --harness "$FH" --no-fetch 2>&1 )"; RC=$?
e2_pin="$(printf '%s\n' "$OUT" | grep -E '^ *pin:' || true)"
ck "(e2) a FLAT launcher + a config naming the TARGET still resolves the pin in the HARNESS repo [$(printf '%s' "$e2_pin" | tr '\n' '|')]" \
   "$(case "$e2_pin" in *"pin: OK"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e2) …and 'up' got past the pin gate (rc=$RC, not the exit-3 refusal)" "$([ "$RC" -ne 3 ] && echo 0 || echo 1)"
e2_har="$(printf '%s\n' "$OUT" | grep -E '^==> harness-up' | head -1)"
ck "(e2) …and it named the repo the pin's commit actually lives in [$e2_har]" \
   "$(case "$e2_har" in *"$REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"

# ── the suite's own non-vacuity floor (the #1890 class) ────────────────────────────────────────
ck "non-vacuity: at least 32 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 32 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-surface.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
