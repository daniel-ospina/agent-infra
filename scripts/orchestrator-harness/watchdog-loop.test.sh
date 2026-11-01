#!/usr/bin/env bash
# watchdog-loop.test.sh — the controller watchdog's contract, driven hermetically.
#
# ⛔ THE CASE THAT MATTERS IS THE MEASURED ONE (2026-10-21): a controller that is ALIVE and whose
# heartbeat has been frozen for an hour, while `launchctl` says loaded and `harness.sh verify` says
# GREEN. A pid-existence predicate reports that box healthy, so this suite exists to prove the
# watchdog does not — and to prove the assertion is not vacuous (last section).
#
# Everything here is scratch: $HOME and the state dir are throwaway, the controller is a `sleep` whose
# command line ends in `orch-loop.sh` (so the pid/identity check is exercised for real), and the
# platform restart is a STUB we count. No REAL launchctl, no systemctl, no real stack, no network.
# ⛔ "NO REAL launchctl" IS NOW A PRODUCT PROPERTY, NOT A PROMISE (§8b broke it, review P1 #1986).
# §8b is the one case that must enter the Darwin arm, so it reaches it only behind a launchctl SHIM on
# PATH *and* `WATCHDOG_LAUNCHCTL_PIN` — the resolved path the product is allowed to execute. A shim that
# failed to be written therefore REFUSES (case 8b(e) proves it) instead of falling through to the live
# `/bin/launchctl kickstart -k gui/501/…`: under `set -uo pipefail` with no `-e`, a failed stub write did
# exactly that, and `mk_darwin_bin`'s status was never checked.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WD="$SELF_DIR/watchdog-loop.sh"
[ -f "$WD" ] || { echo "FATAL: $WD not found" >&2; exit 1; }

# ⛔ THE WORK ROOT IS PHYSICAL. The product resolves its own directory with `pwd -P` (§5f's copy of the
# watchdog derives its SECOND scan pattern from `$SELF_DIR`), while `mktemp -d` under the macOS default
# TMPDIR hands back the `/var/folders/…` spelling of a `/private/var/folders/…` path. A fixture controller
# spawned from the unphysical spelling is therefore invisible to the physical pattern, and 5f read DOWN
# for a controller that WAS running — 3 reds on a correct implementation, measured 2026-11-01 and
# reproduced identically on a pristine `git worktree` of the same head with the default TMPDIR, green
# under `TMPDIR=/private/tmp`. Resolving the root ONCE here fixes every case that spawns a fixture by
# path; narrowing it to 5f would leave the next case to rediscover it.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/watchdog-loop-test.XXXXXX")" && pwd -P)"
# ⛔ The fake controllers are recorded in their case's .orch.lock (that is the file the watchdog reads),
# never in a *.ctrlpid this trap invented: the earlier trap killed nothing and every run leaked its
# fixture processes — `sleep 300`s whose argv ends in `orch-loop.sh`, i.e. exactly the noise the
# fleet's own process-table scanners have to tell apart from a real controller.
# ⛔ A SEPARATE PID LEDGER, not the lock: several cases deliberately overwrite `$O/.orch.lock` with a
# DEAD pid (that is the DOWN fixture), which loses the live controller's pid — and a trap that reads the
# lock therefore leaks every one of them. Measured: 11 strays per run before this line existed, each an
# `orch-loop.sh`-looking process the fleet's own process-table readers must then tell from a real one.
trap 'while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$WORK/pids" 2>/dev/null; rm -rf "$WORK"' EXIT
: > "$WORK/pids"
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'BAD  %s\n' "$*"; FAIL=$((FAIL+1)); }
FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (no '$2' in: $1)" ;; esac; }
assert_absent()  { case "$1" in *"$2"*) bad "$3 (found '$2' in: $1)" ;; *) ok "$3" ;; esac; }
# assert_age_between <text> <min> <max> <label> — LOAD-INDEPENDENT.
# ⛔ NOT `assert_contains "heartbeat=900s"`. The fixture writes `date +%s - 900` and the pass reads
# `date +%s` AGAIN, so the age is 900 only when both land in the same second. Measured by review: 2 of
# 6 concurrent runs read RED with `heartbeat=901s` under the 8-shard parallel runner — a false red on a
# correct implementation, which is the failure shape that gets a gate switched off. The property under
# test is "the decision line carries the age it used, which is the 900s the fixture set", not "the
# clock did not tick between two processes".
assert_age_between() { # <text> <min> <max> <label>
  local got
  got="$(printf '%s' "$1" | sed -n 's/.*heartbeat=\([0-9][0-9]*\)s.*/\1/p' | tail -1)"
  if [ -n "$got" ] && [ "$got" -ge "$2" ] && [ "$got" -le "$3" ]; then ok "$4 (${got}s)"
  else bad "$4 (heartbeat=${got:-absent}, want $2..$3)"; fi
}

N=0
# A fresh case: its own O / state dir / log / restart-stub counter, and its own fake controller.
newcase() {
  N=$((N+1)); C="$WORK/c$N"; mkdir -p "$C/o/logs" "$C/state"
  STUB="$C/restart.stub"; CALLS="$C/restart.calls"; : > "$CALLS"
  printf '#!/bin/sh\nprintf "restart\\n" >> "%s"\n' "$CALLS" > "$STUB"; chmod +x "$STUB"
}
# A live "controller": a sleeping process whose argv contains orch-loop.sh, recorded in the lock.
start_ctrl() {
  printf 'sleep 300\n' > "$C/o/fake-orch-loop.sh"
  bash "$C/o/fake-orch-loop.sh" >/dev/null 2>&1 &
  CPID=$!
  printf '%s\n' "$CPID" >> "$WORK/pids"
  printf '%s' "$CPID" > "$C/o/.orch.lock"
}
stop_ctrl() { [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null; CPID=""; : > "$C/o/.orch.lock"; }
hb_now()   { date +%s > "$C/o/heartbeat"; }
hb_stale() { echo $(( $(date +%s) - 900 )) > "$C/o/heartbeat"; }   # HB_STALE default 780 → stale
# run [extra env…] — one watchdog pass against the current case; prints the decision line.
# ⛔ NO PIPELINE INTO `grep -m1`. An earlier version read the pass through `grep -m1`, which closes the
# pipe after the first matching line and SIGPIPEs the watchdog mid-pass — so any assertion about what
# happens AFTER the decision line (the restart, the settle re-check, the next streak) was silently
# testing a TRUNCATED run, and pass counts drifted by one. The output goes to a file and is filtered
# from there: no reader can kill the writer.
run() {
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
      WATCHDOG_LOG="$C/state/controller-watchdog.log" \
      WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=780 MAX_CONSEC="${MAXC:-3}" \
      ${@:+"/usr/bin/env" "$@"} bash "${RUNSCRIPT:-$WD}" >"$C/pass.out" 2>&1
  grep -m1 -E 'verdict=(HEALTHY|UNCERTAIN|WEDGED|DOWN|WEDGED_STOPPED|DOWN_STOPPED|RECOVERED|STILL_NOT_CYCLING|PROBE_RESTART|RESTART-FAILED|RESTART-SUPPRESSED|RESTART-REFUSED|RESTART-UNAVAILABLE)' "$C/pass.out" || true
}
# runall — every line the pass emitted (the post-restart re-check is a SECOND line, and a case about
# recovery must read it; `run` returns the DECISION line, so a STILL_NOT_CYCLING follow-up cannot mask it).
runall() {
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
      WATCHDOG_LOG="$C/state/controller-watchdog.log" \
      WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=780 MAX_CONSEC=3 \
      bash "$WD" 2>&1 || true
}
restarts() { wc -l < "$CALLS" | tr -d ' '; }
crashes()  { [ -f "$C/state/controller-watchdog.crash" ] && echo 1 || echo 0; }

# ═══ 1. advancing heartbeat + live pid → HEALTHY, and the stub was NOT called ════════════════════
echo "── 1. healthy: a cycling controller is left alone"
newcase; start_ctrl; hb_now
out="$(run)"
assert_contains "$out" "verdict=HEALTHY" "a fresh heartbeat + live pid is HEALTHY"
assert_contains "$out" "pid=$CPID" "…and the line names the controller pid"
assert_eq "$(restarts)" "0" "…and the restart command was NOT called (proven, not assumed)"
assert_eq "$(crashes)" "0" "…and no crash record was written"
# ⛔ THE EARLIER VERSION OF THIS LINE COMPARED X TO X and could never fail; it also routed `--status`
# through `/usr/bin/env`, so the flag never reached the script (`env: illegal option -- s`) and both
# sides were empty. `--status` is the human surface the contract names, so it is driven DIRECTLY here.
stout="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
         WATCHDOG_LOG="$C/state/controller-watchdog.log" \
         WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 bash "$WD" --status 2>&1)"
assert_contains "$stout" "controller-watchdog:" "--status renders the state (a reader other than launchd can see it)"
assert_contains "$stout" "HEALTHY" "--status reprints the last decision"
assert_eq "$(restarts)" "0" "--status dispatches nothing"

# ═══ 2. THE MEASURED CASE: live pid + stale heartbeat → exactly ONE restart, WEDGED ══════════════
echo "── 2. WEDGED: pid alive, heartbeat stale (the measured hour)"
newcase; start_ctrl; hb_stale
out="$(run)"
assert_contains "$out" "verdict=WEDGED" "a live pid with a stale heartbeat is WEDGED, not healthy"
assert_age_between "$out" 900 910 "…and the line carries the heartbeat age the decision used"
assert_eq "$(restarts)" "1" "…and EXACTLY one restart was issued"
assert_contains "$(run)" "verdict=WEDGED" "a second pass re-observes the same state (no silent success)"

# 2b. the same, with a restart that actually cures it → RECOVERED, still exactly one restart
echo "── 2b. one restart that works is reported as RECOVERED"
newcase; start_ctrl; hb_stale
cat > "$STUB" <<EOF
#!/bin/sh
printf "restart\n" >> "$CALLS"
date +%s > "$C/o/heartbeat"
EOF
chmod +x "$STUB"
assert_contains "$(runall)" "verdict=RECOVERED" "a restart that restores cycling is reported RECOVERED"
assert_eq "$(restarts)" "1" "…with exactly one restart"

# ═══ 2c. THE P0 FROM REVIEW: a CYCLING controller whose pid cannot be found must not be killed ═════
echo "── 2c. a fresh heartbeat with no discoverable pid is UNCERTAIN, never a restart"
newcase; start_ctrl; hb_now
: > "$C/o/.orch.lock"        # the lock was removed/stale (the #1715 class)
# …and the scan cannot match this case's argv, so NO pid is discoverable while the loop IS cycling
mv "$C/o/fake-orch-loop.sh" "$C/o/detached-loop.sh" 2>/dev/null || true
out="$(run)"
assert_contains "$out" "verdict=UNCERTAIN" "fresh heartbeat + no pid is UNCERTAIN (a 0s-old heartbeat proves it IS cycling)"
assert_absent  "$out" "restart=1" "…and nothing in the line asks for a restart"
assert_eq "$(restarts)" "0" "…and the restart command was NOT called — killing a cycling controller on a bookkeeping miss is the P0"
assert_absent  "$out" "verdict=DOWN" "…and it is not DOWN either"

# ═══ 3. dead pid + stale heartbeat → DOWN → restart ═════════════════════════════════════════════
echo "── 3. DOWN: no pid, heartbeat stale"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale
out="$(run)"
assert_contains "$out" "verdict=DOWN" "a stale heartbeat with no pid is DOWN"
assert_eq "$(restarts)" "1" "…and it restarts"

# ═══ 4. missing heartbeat → DOWN, NEVER healthy (an absent datum is not a fresh one) ════════════
echo "── 4. a missing heartbeat is DOWN, never HEALTHY"
newcase; start_ctrl          # live pid, NO heartbeat file at all
out="$(run)"
assert_contains "$out" "verdict=DOWN" "a live pid with NO heartbeat file is DOWN"
assert_absent  "$out" "HEALTHY" "…and nothing in the line says HEALTHY"
assert_contains "$out" "no readable heartbeat" "…and it names the missing datum"
assert_eq "$(restarts)" "1" "…and it restarts"
# 4b. an empty / garbage heartbeat file is the same class — present but not a usable instant
newcase; start_ctrl; printf 'not-a-time' > "$C/o/heartbeat"; touch -t 202001010000 "$C/o/heartbeat"
# ⛔ A file whose content carries no instant is UNKNOWN, and UNKNOWN maps to DOWN — it must NOT be
# dated from its mtime: any `touch`/copy/restore would then renew "health" for HB_STALE seconds on a
# wedged box (the fail-open direction review found untested). DOWN sends the operator to a restart,
# which is the safe arm here; the alternative sends them to a green tick.
assert_contains "$(run)" "verdict=DOWN" "a heartbeat whose content is not an instant is DOWN (no mtime fallback), never healthy"
assert_absent "$(run)" "verdict=HEALTHY" "…and never HEALTHY"

# ═══ 4c. A NUMERIC-LOOKING HEARTBEAT IS STILL NOT AN INSTANT — the octal/zero hazard ════════════
# `tr -dc '0-9'` yields a digit run from ANY file, and `/bin/bash` 3.2 reads a leading-zero run as
# OCTAL inside `$(( ))`. So the filed value is not the instant that was read (the sibling
# `launchd-cycle.sh` already carries the three guards — `10#$v`, a plausible-epoch floor, a negative
# clamp — and this file had none of them), and an all-zero run reads as `now - 0`: a fabricated age of
# the whole epoch. An age is not a label here, it is a RESTART plus a durable crash record plus a later
# probe restart, so a leading-zero run must be read as the DECIMAL it is, and an implausible instant
# must be UNKNOWN like any other unreadable datum.
echo "── 4c. a leading-zero / all-zero heartbeat is UNKNOWN, never a fabricated age"
newcase; start_ctrl
echo 01760000000 > "$C/o/heartbeat"          # a DECIMAL instant, written with a leading zero
_t0="$(date +%s)"; out="$(run)"; _t1="$(date +%s)"
# The reading must be the DECIMAL one (~32.7M s ago), not the OCTAL one the old code produced
# (~1.5e9 s). Both are WEDGED, so the verdict alone cannot see the bug — the AGE can, and the age is
# what the crash record and the decision line report to whoever reads them.
assert_age_between "$out" "$(( _t0 - 1760000000 ))" "$(( _t1 - 1760000000 + 1 ))" \
  "a leading-zero run is read as DECIMAL (age = now - 1760000000), not as octal"
newcase; start_ctrl; printf '0000000000\n' > "$C/o/heartbeat"
out="$(run)"
assert_contains "$out" "verdict=DOWN" "an all-zero heartbeat run is DOWN (never `now - 0` = a fabricated epoch-old age)"
assert_absent  "$out" "verdict=WEDGED" "…and specifically NOT WEDGED, which would restart a cycling controller"
# …and a legitimately-shaped value in the tolerated future-skew band is CLAMPED, never negative
newcase; start_ctrl; echo $(( $(date +%s) + 30 )) > "$C/o/heartbeat"
out="$(run)"
assert_contains "$out" "verdict=HEALTHY" "a heartbeat inside the 60s future-skew band is still HEALTHY (a clock wobble is not corruption)"
case "$out" in *"heartbeat=-"*) bad "…the age went negative: $out" ;; *) ok "…and the age was clamped to a non-negative value" ;; esac

# ═══ 5. N consecutive wedges → restarting STOPS, ONE crash line, and it SURVIVES a restart ═══════
echo "── 5. a crash loop stops being restarted, and the crash is recorded ONCE"
newcase; start_ctrl; hb_stale; MAXC=2
printf 'orchestrator: starting\n' > "$C/o/logs/controller-stdout.log"
printf 'line: 412: syntax error near unexpected token `(`\n' >> "$C/o/logs/controller-stdout.log"
printf 'orchestrator: exiting 2\n' >> "$C/o/logs/controller-stdout.log"
o1="$(run)"; o2="$(run)"; o3="$(run)"
assert_contains "$o1" "verdict=WEDGED" "wedge 1/2 restarts"
assert_contains "$o2" "verdict=WEDGED" "wedge 2/2 restarts"
assert_contains "$o3" "verdict=WEDGED_STOPPED" "wedge 3 (> 2) STOPS restarting"
assert_contains "$o3" "restart=0" "…and says so in the same line"
assert_eq "$(restarts)" "2" "…and the restart count stopped at the limit (2), not 3"
assert_eq "$(crashes)" "1" "…and ONE crash record exists"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "syntax error" "…and it NAMES the crash from the controller's own stdout"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "verdict=WEDGED_STOPPED" "…using the SAME verdict token as the decision log (not WEDGED-STOPPED)"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "last 25 lines" "…and carries the tail of that log"
sig1="$(cksum < "$C/state/controller-watchdog.crash")"
# a SIMULATED restart: the stub runs, the controller is replaced, the wedge continues
stop_ctrl; start_ctrl; hb_stale
o4="$(run)"
assert_contains "$o4" "verdict=WEDGED_STOPPED" "after a restart the loop is STILL stopped"
assert_eq "$(restarts)" "2" "…and it did not restart again"
assert_eq "$(cksum < "$C/state/controller-watchdog.crash")" "$sig1" "…and the crash record SURVIVED the restart byte for byte (written once)"

# ═══ 5b. DOWN is CAPPED too: a controller that crashes on start is not restarted forever ═════════
echo "── 5b. a repeating DOWN stops being restarted, and each crash EPISODE is recorded"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=2
printf 'bash: line 412: syntax error near unexpected token `(`\n' > "$C/o/logs/controller-stdout.log"
d1="$(run)"; d2="$(run)"; d3="$(run)"
assert_contains "$d1" "verdict=DOWN" "DOWN 1 restarts"
assert_contains "$d2" "verdict=DOWN" "DOWN 2 restarts"
assert_contains "$d3" "verdict=DOWN_STOPPED" "DOWN 3 (> 2) STOPS restarting (crash-on-start cannot loop forever)"
assert_eq "$(restarts)" "2" "…and the DOWN restart count stopped at the limit"
assert_eq "$(crashes)" "1" "…and the crash WAS recorded (previously only the WEDGED arm recorded anything)"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "syntax error" "…naming the crash"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "episode=1" "…and its episode"

# a SECOND, DIFFERENT crash loop must be recorded too — the record is once PER EPISODE, not once ever
start_ctrl; hb_now; run >/dev/null                  # one healthy pass ends episode 1
stop_ctrl; printf '999999' > "$C/o/.orch.lock"; hb_stale
printf 'Traceback (most recent call last):\nKeyError: worker-missing\n' > "$C/o/logs/controller-stdout.log"
run >/dev/null; run >/dev/null; run >/dev/null
assert_eq "$(grep -c 'verdict=DOWN_STOPPED' "$C/state/controller-watchdog.crash")" "2" "a SECOND crash episode is appended, not swallowed by the first"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "KeyError: worker-missing" "…and it names the SECOND crash (the earlier record named only the first)"

# ═══ 5c. the STOPPED latch is BOUNDED: a dead box must not stay dead for ever ═════════════════════
echo "── 5c. after a second full budget of stopped observations, ONE probe restart and a new episode"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=2
: > "$C/o/logs/controller-stdout.log"
# ⛔ OBSERVED, NOT INDEXED. The first version hard-coded "the probe is observation 5" and was red for a
# reason that had nothing to do with the latch (one helper consumed an extra pass). The property under
# test is "STOPPED appears, then a probe appears, and the probe is ONE restart as a NEW episode" — so it
# is driven by a bounded loop and asserted on what the passes actually said.
seen=""
for _i in 1 2 3 4 5 6 7 8; do
  _o="$(run)"; seen="$seen$_o"$'\n'
  case "$_o" in *PROBE_RESTART*) break ;; esac
done
assert_contains "$seen" "verdict=DOWN_STOPPED" "the cap fires and restarting stops"
assert_contains "$seen" "verdict=PROBE_RESTART" "…and the latch is BOUNDED: a probe restart follows (a dead box must not stay dead for ever)"
assert_contains "$seen" "episode=1" "…continuing the SAME episode"
# ⛔ THE RATE ITSELF IS PINNED, not only the episode side-effect: re-arming the budget (`streak=1`)
# left every other assertion green while the measured cadence fell from one restart per 4 passes to one
# per 2 (verified by mutation in review). The probe line must carry the SPENT budget.
assert_contains "$seen" "verdict=PROBE_RESTART" "…and the probe is taken"
assert_eq "$(printf '%s' "$seen" | grep -o 'streak=[0-9]*/[0-9]*' | tail -1)" "streak=2/2" "…with the budget still SPENT (streak=MAX_CONSEC, so the next probe is N+1 passes away — one restart per 2 passes would mean the budget was re-armed)"
assert_eq "$(restarts)" "3" "…and exactly one probe was issued (2 capped + 1 probe)"
assert_eq "$(grep -c 'verdict=DOWN_STOPPED' "$C/state/controller-watchdog.crash")" "1" "…and the SAME episode is still recorded only once"

# ═══ 5d. a controller log line containing `episode=<n>` must not reopen the crash record ══════════
echo "── 5d. the crash-record dedupe parses its own header, not the controller's output"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=1
printf 'worker: starting episode=7\n' > "$C/o/logs/controller-stdout.log"
run >/dev/null; run >/dev/null; run >/dev/null       # 1 restarts; 2 is STOPPED (its block); 3 probes
assert_eq "$(grep -c 'verdict=DOWN_STOPPED' "$C/state/controller-watchdog.crash")" "1" "one episode produces exactly ONE block even when the controller's own log mentions episode=7"

# ═══ 5e. THE CRASH RECORD NAMES A LOG SOMETHING ACTUALLY WRITES ═════════════════════════════════
# The default evidence path used to be `$O/logs/controller-stdout.log`, which NO producer in this repo
# writes (the controller job renders to `logs/launchd.out`/`.err`, a cell supervisor tees
# `logs/controller.log`), and every earlier case here MANUFACTURED that file — so the contract was
# tested on a shape that ships nowhere. Two arms: the resolved path is one the producers write, and
# with NOTHING on disk the record still names the log it could not read.
echo "── 5e. the crash record's evidence path is resolved, and an absent log is NAMED not implied"
# (a) an explicit CTRL_STDOUT still wins verbatim — the seam an operator uses
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=1
printf 'orch-loop: fatal: unbound variable\n' > "$C/o/somewhere-else.log"
for _i in 1 2 3; do env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
    WATCHDOG_LOG="$C/state/controller-watchdog.log" CTRL_STDOUT="$C/o/somewhere-else.log" \
    WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 MAX_CONSEC=1 bash "$WD" >/dev/null 2>&1; done
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "somewhere-else.log" "an explicit CTRL_STDOUT is honoured verbatim"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "unbound variable" "…and its error is what the record names as the cause"
# (b) no file anywhere: launchd's own StandardErrorPath is what is NAMED, with the honest "unreadable"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=1
for _i in 1 2 3; do run >/dev/null; done
assert_eq "$(crashes)" "1" "the crash IS recorded even with no readable controller log"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "last 25 lines of $C/o/logs/launchd.err" \
  "…and it NAMES the log it could not read (launchd's stderr), instead of quoting a file nothing writes"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "(unreadable or absent)" "…and says plainly that the log could not be read"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "<no error-looking line" "…so the cause has no fabricated signature"
# (c) the shipped CELL shape: the supervisor's tee is $O/logs/controller.log — it must be preferred
# over a file that is not there, without any env pointing at it
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale; MAXC=1
printf 'controller: KeyError: worker-missing\n' > "$C/o/logs/controller.log"
for _i in 1 2 3; do run >/dev/null; done
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "last 25 lines of $C/o/logs/controller.log" \
  "the cell's controller.log (what cloud-cell-supervisor.sh tees) is resolved with NO configuration"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "KeyError: worker-missing" "…and its crash is quoted"

# ═══ 5f. A CELL'S CONTROLLER IS FOUND IN THE HARNESS SCOPE ══════════════════════════════════════
# A Mac launchd job runs `bash __O__/orch-loop.sh`; a cell supervisor runs
# `bash '<harness>/orch-loop.sh'` (cloud-cell-supervisor.sh:1985). A single $O-scoped pgrep therefore
# could not see a cell's controller at all, so a live-but-frozen one read DOWN — WEDGED was
# unreachable on the cell shape, and every pass would have issued a restart.
# ⚠ NO PRODUCT SEAM FOR THIS: the second pattern is derived from the script's OWN directory, so the
# arm runs a COPY of the watchdog beside a fixture `orch-loop.sh` — the real resolution, not a stub.
echo "── 5f. the controller is found when its argv carries the HARNESS path, not the state dir"
newcase
mkdir -p "$C/harness"
cp "$WD" "$C/harness/watchdog-loop.sh"
printf 'sleep 300\n' > "$C/harness/orch-loop.sh"
bash "$C/harness/orch-loop.sh" >/dev/null 2>&1 &
CPID=$!
printf '%s\n' "$CPID" >> "$WORK/pids"
: > "$C/o/.orch.lock"      # no lock: the process-table scan is the ONLY source of the pid
hb_stale
RUNSCRIPT="$C/harness/watchdog-loop.sh"
out="$(run)"
RUNSCRIPT=""
assert_contains "$out" "verdict=WEDGED" "a harness-scope controller with a stale heartbeat is WEDGED (it used to read DOWN)"
assert_contains "$out" "pid=$CPID" "…and the line names the pid the second pattern found"
assert_absent  "$out" "verdict=DOWN" "…and NOT DOWN, which is what the single-scope scan produced"
assert_eq "$(restarts)" "1" "…and exactly one restart was issued"

# ═══ 6. the decision log is bounded and rotated with a line saying so ═══════════════════════════
echo "── 6. the decision log cannot grow without bound"
newcase; start_ctrl; hb_now
head -c 2000 /dev/zero | tr '\0' 'x' > "$C/state/controller-watchdog.log"
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
    WATCHDOG_LOG="$C/state/controller-watchdog.log" WATCHDOG_LOG_MAX_BYTES=1024 \
    WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(cat "$C/state/controller-watchdog.log")" "LOG-ROTATED" "an over-bound log is rotated with a line naming it"
[ "$(wc -c < "$C/state/controller-watchdog.log")" -lt 1024 ] && ok "…and the log came back under the bound" || bad "…the log is still over its bound"

# ═══ 7. hostile bounds fall back instead of inverting the predicate ═════════════════════════════
echo "── 7. a non-numeric HB_STALE must not turn a healthy controller into a wedged one"
newcase; start_ctrl; hb_now
out="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
        WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=abc bash "$WD" >"$C/pass.out" 2>&1; grep -m1 -E 'verdict=(HEALTHY|WEDGED|DOWN)' "$C/pass.out")"
assert_contains "$out" "verdict=HEALTHY" "HB_STALE=abc falls back to 780 and the controller stays healthy"
assert_eq "$(restarts)" "0" "…and nothing was restarted"
# a zero HB_STALE is a legitimate (strict) setting: every non-zero age is stale
newcase; start_ctrl; echo $(( $(date +%s) - 5 )) > "$C/o/heartbeat"
out="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
        WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=0 bash "$WD" >"$C/pass.out" 2>&1; grep -m1 -E 'verdict=(HEALTHY|WEDGED|DOWN)' "$C/pass.out")"
assert_contains "$out" "verdict=WEDGED" "HB_STALE=0 is honoured (a 5s-old heartbeat is stale), not silently defaulted"

# 7b. an unvalidated LOG_MAX_BYTES used to truncate the decision log on EVERY pass
echo "── 7b. a non-numeric log bound falls back instead of erasing the verdict"
newcase; start_ctrl; hb_now
printf 'prior decision line\n' > "$C/state/controller-watchdog.log"
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/controller-watchdog.log" \
    WATCHDOG_LOG_MAX_BYTES=abc WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(cat "$C/state/controller-watchdog.log")" "prior decision line" "a typo'd LOG_MAX_BYTES does NOT truncate the log"
assert_contains "$(cat "$C/state/controller-watchdog.log")" "BOUND-FALLBACK" "…and the ignored bound is said out loud"
assert_eq "$(env O="$C/o" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" bash "$WD" --bogus >/dev/null 2>&1; echo $?)" "0" "even a mistyped verb exits 0 (the trap covers the parse)"
# MAX_CONSEC=0 used to be accepted and meant "never restart", which disabled the one action this job
# exists to take — while the cap fired on the FIRST observation and recorded a crash for a restart that
# was never attempted.
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 MAX_CONSEC=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(cat "$C/state/l")" "MAX_CONSEC=0(<1)" "MAX_CONSEC=0 falls back to 3 and is NAMED in BOUND-FALLBACK"
# ⛔ ASSERT WHAT THE BUG WOULD LOOK LIKE, not a word that the bug also produces: with MAX_CONSEC=0
# accepted, the cap fires on observation 1 and the first pass is STOPPED (or, after the bounded latch,
# a PROBE) — never an ordinary restart. It is the RESTART that must be present on pass 1.
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 MAX_CONSEC=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(grep -m1 -E 'verdict=(DOWN|WEDGED)' "$C/state/l")" "restart=1" "…and the first observation is an ordinary RESTART, not a cap fired at zero"
assert_eq "$(restarts)" "1" "…the stub proves it"

# ═══ 8. exit 0 always ══════════════════════════════════════════════════════════════════════════
echo "── 8. the watchdog always exits 0"
newcase; start_ctrl; hb_stale
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="/bin/false" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_eq "$?" "0" "a FAILED restart verb still exits 0 (the verdict is the output)"
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="/bin/false" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(grep -m1 RESTART-FAILED "$C/state/l")" "RESTART-FAILED" "…and it says the restart failed"
# ⛔ THE STUB IS NOT OPTIONAL, even here: the FIRST version of this case ran the real platform verb and
# issued `launchctl kickstart -k gui/501/com.eldato.orchestrator-stack` against the LIVE stack
# (measured — the job's pid changed). A unit test must never be able to do that.
assert_eq "$(env O=/nonexistent/xyz WATCHDOG_STATE_DIR="$C/state2" WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 WATCHDOG_LOG="$C/state2/l" SETTLE=0 bash "$WD" >/dev/null 2>&1; echo $?)" "0" "an unusable O still exits 0"
# ⛔ AND THE SUPPRESSION ITSELF IS ASSERTED, not assumed: the earlier version relied on the flag without
# ever checking it was taken, so a renamed/moved guard would be both invisible here and live-firing on
# the operator's box.
newcase; start_ctrl; hb_stale
# ⛔ BOTH PROBES. The first version of this case passed no WATCHDOG_RESTART_CMD, so `restarts()` could
# never move and the "no restart was issued" assertion was a tautology (measured in review: a
# `launchctl` shim on PATH recorded a real `kickstart -k` while the counter still read 0). The stub
# proves the SCRIPT's own seam was not taken; the shim proves the PLATFORM verb was not reached, which
# is the thing that actually matters.
mkdir -p "$C/bin"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$C/launchctl.calls" > "$C/bin/launchctl"
chmod +x "$C/bin/launchctl"
# NO stub here on purpose: the suppression branch sits AFTER the stub seam (a stub IS the restart under
# test), so this is the only invocation that can reach it — and the shim is what makes a REGRESSION safe.
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_NO_RESTART=1 SETTLE=0 PATH="$C/bin:$PATH" bash "$WD" >/dev/null 2>&1
assert_contains "$(grep -m1 RESTART-SUPPRESSED "$C/state/l")" "RESTART-SUPPRESSED" "WATCHDOG_NO_RESTART reaches the platform verb and is taken"
assert_eq "$([ -f "$C/launchctl.calls" ] && echo 1 || echo 0)" "0" "…and a launchctl shim on PATH records ZERO calls (the live verb was never reached, even though this run had no stub)"

# ═══ 8b. REMOVED vs LOADED — WHICH launchd verb, decided by a MEASURED state (#1986) ═══════════
echo "── 8b. a REMOVED controller job is BOOTSTRAPPED; a loaded one is KICKSTARTED"
# ⛔ WHAT THIS ARM EXISTS FOR. KeepAlive cannot restart a service that is no longer in the domain
# (`launchctl unload -w` / a `bootout` whose `bootstrap` failed: measured five times on 2026-10-17),
# and `kickstart -k` exits non-zero for ever on such a label — so before this arm the ONE restart the
# watchdog issues could never restore a REMOVED controller, and nothing said so. The recovery belongs
# HERE, in the tracked agent: `templates/launchd/RETIRED` retired the second launchd watchdog because
# two loaded watchdogs are two MUTATING actors on one controller, and `fleet-liveness` names this file
# as the replacement.
# ⛔ IT IS DRIVEN WITH NO `WATCHDOG_RESTART_CMD`: the stub seam returns BEFORE the platform arm, so a
# case that kept it would assert nothing about the verb — the vacuity case 8 records. `uname` is shimmed
# (this suite runs on Linux) and `launchctl` records every argv, so the assertions are about the verb
# that was actually issued.
mk_darwin_bin() { # <print-rc> <print-output> [non-print-rc] → $C/bin/{uname,launchctl}
  mkdir -p "$C/bin" 2>/dev/null
  printf '#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; exit 0; fi\nexec /usr/bin/uname "$@"\n' > "$C/bin/uname" 2>/dev/null
  {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$C/launchctl.calls"
    # `%b`, because a REAL `launchctl print` answer is often TWO lines — a not-found read is
    # `Bad request.` THEN `Could not find service …` — and the fixtures below carry that measured shape.
    printf 'if [ "$1" = print ]; then printf "%%b\\n" "%s"; exit %s; fi\nexit %s\n' "$2" "$1" "${3:-0}"
  } > "$C/bin/launchctl" 2>/dev/null
  chmod +x "$C/bin/uname" "$C/bin/launchctl" 2>/dev/null
  # ⛔ NO `set -e` HERE, SO NOBODY CHECKS THIS RETURN VALUE: the caller must, with `darwin_stub_ok`.
}
# ⛔ THE DARWIN ARM IS ENTERED ONLY BEHIND A PROVABLE SHIM. This is the precondition, not a comment: the
# shim must exist, be executable, and be the binary that `launchctl` actually resolves to on the fixture
# PATH. If any of that is false the case does NOT run — a failed stub write must never reach the host's
# real launchctl, which is the machine the suite is running on.
darwin_stub_ok() {
  [ -x "$C/bin/launchctl" ] || return 1
  [ -x "$C/bin/uname" ] || return 1
  [ "$(PATH="$C/bin:$PATH" command -v launchctl 2>/dev/null)" = "$C/bin/launchctl" ] || return 1
  return 0
}
removed_pass() { # <pass-output-file>
  if ! darwin_stub_ok; then
    bad "the launchctl/uname shim is NOT in place — the Darwin arm was NOT entered (a stub write that failed must never reach the real launchctl)"
    : > "$1"; return 1
  fi
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
      WATCHDOG_PLIST="$C/stack.plist" WATCHDOG_LAUNCHCTL_PIN="$C/bin/launchctl" SETTLE=0 \
      LAUNCHCTL_CALLS="$C/launchctl.calls" PATH="$C/bin:$PATH" bash "$WD" >"$1" 2>&1
}
# (a) ABSENT from both domains → enable + bootstrap from the plist, and NEVER a kickstart.
# ⚠ THE FIXTURE IS THE MEASURED ANSWER, NOT A TIDY ONE: a real not-found read is rc 113 and its FIRST
# line is `Bad request.` (verified on this box, gui/ and user/ alike). The old comment in the product
# called that first line the UNREADABLE marker — it is the not-found marker, and this fixture is what
# pins the difference (see (d) for the genuinely unreadable read).
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 113 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501'
removed_pass "$C/pass.out"
CALLS_OUT="$(cat "$C/launchctl.calls" 2>/dev/null)"
assert_contains "$CALLS_OUT" "bootstrap gui/$(id -u) $C/stack.plist" "a REMOVED job is BOOTSTRAPPED from its rendered plist"
assert_contains "$CALLS_OUT" "enable gui/$(id -u)/com.eldato.orchestrator-stack" "…after ENABLE, because a -w unload leaves a persistent Disabled override that makes bootstrap a silent no-op"
assert_absent "$CALLS_OUT" "kickstart" "…and NO kickstart was issued for a job launchd does not hold (it could only fail)"
assert_contains "$(grep -m1 -E 'verdict=(DOWN|WEDGED)' "$C/state/l")" "restart=1" "…the pass still reports the restart it attempted"
# (b) LOADED → the wedge-curing kickstart, and NO bootstrap (a second bootstrap is a no-op at best
#     and an error at worst; the state was MEASURED as present).
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 0 'com.eldato.orchestrator-stack = {\n\tactive count = 0\n\tlast exit code = 0\n}'
removed_pass "$C/pass.out"
CALLS_OUT="$(cat "$C/launchctl.calls" 2>/dev/null)"
assert_contains "$CALLS_OUT" "kickstart -k gui/$(id -u)/com.eldato.orchestrator-stack" "a LOADED job still takes kickstart -k"
assert_absent "$CALLS_OUT" "bootstrap" "…and is never re-bootstrapped underneath a live controller"
# (c) A REMOVED job with NO plist is REPORTED, not guessed at: there is nothing to bootstrap, and a
#     silent success here would claim a recovery that cannot happen.
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale
mk_darwin_bin 113 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501'
removed_pass "$C/pass.out"
assert_contains "$(cat "$C/pass.out")" "RESTART-UNAVAILABLE" "a REMOVED job with no plist on disk reports RESTART-UNAVAILABLE"
assert_absent "$(cat "$C/launchctl.calls" 2>/dev/null)" "bootstrap" "…and issues no bootstrap with nothing to load"
# (d) AN UNREADABLE READ IS NOT "ABSENT". ⚠ THE FIXTURE USED TO BE rc 1 `Bad request.`, WHICH IS NOT A
#     SHAPE launchd PRODUCES: `Bad request.` is the first line of a NOT-FOUND read (rc 113 — case (a)),
#     and the measured UNREADABLE read is `rc 64` + `Unrecognized target specifier.` for a malformed
#     target. So the old case pinned a fixture nobody could reproduce, and the comment above it taught
#     the wrong marker. The polarity under test is unchanged and still the point: an unreadable state
#     must take `kickstart` (which cannot double-load), never a bootstrap.
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 64 'Unrecognized target specifier.'
removed_pass "$C/pass.out"
CALLS_OUT="$(cat "$C/launchctl.calls" 2>/dev/null)"
assert_contains "$CALLS_OUT" "kickstart -k" "an UNREADABLE state (rc 64, a measured answer) takes kickstart, not bootstrap"
assert_absent "$CALLS_OUT" "bootstrap" "…never a bootstrap decided from an error message"

# ── 8b(e)-(h): THE THREE WAYS THIS ARM COULD STILL HURT THE BOX ──────────────────────────────────
# (e) THE GUARD REFUSES WHEN THE SHIM IT WAS PINNED TO IS NOT THERE (review P1, #1986). The pin names a
#     path; the shim answering on PATH is a DIFFERENT one. That is exactly the bookkeeping a failed stub
#     write leaves behind, and the run must issue NOTHING. ⛔ THE THING ON PATH IS A DECOY THAT RECORDS,
#     never the host's real launchctl — so if the guard did NOT refuse, this case shows the verb in the
#     decoy's log instead of mutating the machine running the suite.
echo "── 8b(e). a pin that is not the launchctl on PATH refuses every verb"
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 113 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501'
: > "$C/launchctl.calls"
if ! darwin_stub_ok; then
  bad "8b(e): the decoy shim could not be staged — case NOT run"
else
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
      WATCHDOG_PLIST="$C/stack.plist" WATCHDOG_LAUNCHCTL_PIN="$C/pinned-stub-that-is-not-there" SETTLE=0 \
      LAUNCHCTL_CALLS="$C/launchctl.calls" PATH="$C/bin:$PATH" bash "$WD" >"$C/pass.out" 2>&1
  assert_contains "$(cat "$C/state/l" 2>/dev/null)" "verdict=RESTART-REFUSED" "a mismatched WATCHDOG_LAUNCHCTL_PIN REFUSES instead of running the verb"
  assert_contains "$(grep -m1 RESTART-REFUSED "$C/state/l" 2>/dev/null)" "NO launchctl verb was issued" "…and says so in the line itself"
  assert_eq "$(cat "$C/launchctl.calls" 2>/dev/null | wc -l | tr -d ' ')" "0" "…and NOTHING ran — not even the state read (the decoy recorded zero calls)"
  assert_absent "$(cat "$C/state/l" 2>/dev/null)" "RESTART-FAILED" "…and the refusal is not reported as a FAILED verb (nothing was executed)"
fi

# (f) A REMOVED JOB OVER A **LIVING** CONTROLLER IS NEVER BOOTSTRAPPED (review P1, #1986). `WEDGED` is a
#     state of a LIVE controller — `pid_is_controller` proved the pid alive — so a `bootstrap` here puts a
#     SECOND controller beside it (`orch-loop.sh:1546-1551` only makes the newcomer defer while the first
#     is alive, so the repair leaves two processes on one PR queue), and over a job an operator
#     deliberately stopped it reverses that stop. The trigger must be "the controller is GONE".
echo "── 8b(f). a REMOVED job over a LIVE (wedged) controller is REFUSED, not bootstrapped"
newcase; start_ctrl; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 113 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501'
removed_pass "$C/pass.out"
assert_contains "$(cat "$C/pass.out")" "verdict=WEDGED" "the living controller is observed as WEDGED (its pid is alive)"
assert_absent "$(cat "$C/launchctl.calls" 2>/dev/null)" "bootstrap" "…and a REMOVED job is NOT bootstrapped beside a LIVE controller"
assert_absent "$(cat "$C/launchctl.calls" 2>/dev/null)" "kickstart" "…nor kickstarted: the job is not in the domain, so that verb could only fail"
assert_contains "$(grep -m1 RESTART-REFUSED "$C/state/l" 2>/dev/null)" "pid=$CPID" "…the refusal NAMES the live pid it refused to duplicate"
assert_absent "$(cat "$C/state/l" 2>/dev/null)" "STILL_NOT_CYCLING" "…and a refusal is not presented as a restart that did not work"
# and the contrast that makes it a TRIGGER and not a ban: the same REMOVED state with the controller GONE
# does bootstrap — case (a) above, whose lock names a dead pid.

# (g) A JOB LOADED IN `user/` IS KICKSTARTED IN `user/` (review P2, #1986). The read walks both domains,
#     so a job loaded from an SSH session is correctly NOT "REMOVED" — but a `gui/`-only VERB could never
#     reach it, which is the same defect from the other side.
echo "── 8b(g). a job loaded in user/<uid> is kickstarted in that domain"
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mkdir -p "$C/bin" 2>/dev/null
printf '#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; exit 0; fi\nexec /usr/bin/uname "$@"\n' > "$C/bin/uname" 2>/dev/null
cat > "$C/bin/launchctl" 2>/dev/null <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "${LAUNCHCTL_CALLS:-/dev/null}"
if [ "$1" = print ]; then
  case "$2" in
    user/*) printf 'com.eldato.orchestrator-stack = {\n\tpid = 4242\n\tlast exit code = 0\n}\n'; exit 0 ;;
  esac
  printf 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501\n'
  exit 113
fi
exit 0
EOS
chmod +x "$C/bin/uname" "$C/bin/launchctl" 2>/dev/null
removed_pass "$C/pass.out"
assert_contains "$(cat "$C/launchctl.calls" 2>/dev/null)" "kickstart -k user/$(id -u)/com.eldato.orchestrator-stack" "a user/<uid>-loaded job takes kickstart IN user/<uid>"
assert_absent "$(cat "$C/launchctl.calls" 2>/dev/null)" "bootstrap" "…and is never re-bootstrapped"
assert_absent "$(cat "$C/state/l" 2>/dev/null)" "RESTART-UNAVAILABLE" "…nor reported as unavailable"

# (h) A REFUSED `enable` IS RESTART-FAILED, NOT STILL_NOT_CYCLING (review P2, #1986). `enable … || true`
#     used to swallow the failure and fall through to a `bootstrap` of a label that may still be disabled —
#     a documented silent no-op that can exit 0 — so the pass reported "one restart did not restore
#     cycling" for a restart that never ran.
echo "── 8b(h). a failed enable stops the arm and is reported as RESTART-FAILED, naming the verb"
newcase; printf '999999\n' > "$C/o/.orch.lock"; hb_stale; : > "$C/stack.plist"
mk_darwin_bin 113 'Bad request.\nCould not find service "com.eldato.orchestrator-stack" in domain for user gui: 501' 1
removed_pass "$C/pass.out"
assert_contains "$(cat "$C/launchctl.calls" 2>/dev/null)" "enable " "the arm did try enable"
assert_absent "$(cat "$C/launchctl.calls" 2>/dev/null)" "bootstrap" "…and did NOT bootstrap a label that may still be disabled"
assert_contains "$(grep -m1 RESTART-FAILED "$C/state/l" 2>/dev/null)" "verb=launchctl enable" "…a failed enable is RESTART-FAILED, and the line NAMES the verb"
assert_absent "$(cat "$C/state/l" 2>/dev/null)" "STILL_NOT_CYCLING" "…instead of STILL_NOT_CYCLING, which claims a restart was attempted"

# ═══ 9. NON-VACUITY: remove the heartbeat check and the WEDGED arm MUST fail ═════════════════════
echo "── 9. non-vacuity: without the heartbeat check, a wedged controller reads healthy"
MUT="$WORK/mutant.sh"
sed 's|^  hb_is_fresh() {.*$|  hb_is_fresh() { return 0; }|' "$WD" > "$MUT"
if cmp -s "$WD" "$MUT"; then
  bad "mutation did not apply — the assertions below would be vacuous"
else
  newcase; start_ctrl; hb_stale
  mout="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
           WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$MUT" >"$C/pass.out" 2>&1; grep -m1 -E 'verdict=(HEALTHY|WEDGED|DOWN)' "$C/pass.out")"
  assert_contains "$mout" "verdict=HEALTHY" "MUTANT: with the heartbeat check gone, the wedged controller reads HEALTHY"
  assert_eq "$(restarts)" "0" "MUTANT: …and is never restarted — so case 2 is not passing by accident"
  # the shipped script, same fixture, must disagree
  newcase; start_ctrl; hb_stale
  sout="$(run)"
  assert_contains "$sout" "verdict=WEDGED" "the SHIPPED script on the same fixture says WEDGED (the mutation is the only difference)"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS — watchdog-loop: all cases ok"; exit 0; fi
echo "FAIL — $FAIL case(s)"; exit 1
