#!/usr/bin/env bash
# harness.test.sh — the starter's gates: status tells the truth about a dead component, doctor
# refuses two harness versions, start is idempotent, and ONE unit template renders on both platforms.
#
#   bash scripts/orchestrator-harness/bin/harness.test.sh
#
# HERMETIC BY CONSTRUCTION: temp HOME, temp state/unit dirs, a stateful `systemctl` stub and a
# `launchctl` stub on PATH, and a FAKE harness root built from this checkout's bin/ + templates/. No
# real unit is installed, no real service is started and the host's own supervisor is never read.
#
# ⛔ NON-VACUITY is asserted per arm, not assumed: each arm below is coupled to the line it guards,
# and the mutation that reddens it is named in the arm's comment. A suite whose arms pass against a
# neutered tool protects nothing (agent-infra#2026's suite header makes the same promise).
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SELF/harness"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

[ -f "$HARNESS" ] || { echo "FAIL harness not found at $HARNESS"; exit 1; }
if bash -n "$HARNESS"; then ok "the entry point parses (bash -n)"; else bad "the entry point does not parse"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")"
cleanup() {
  # Kill only children this suite started, by exact pid, never a pattern.
  for p in ${SPAWNED:-}; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

STUB="$TMP/bin"; STUB_STATE="$TMP/stub-state"; STUB_LOG="$TMP/stub.log"
mkdir -p "$STUB" "$STUB_STATE"
: >"$STUB_LOG"
export STUB_STATE STUB_LOG

# ── a stateful supervisor stub ────────────────────────────────────────────────────────────────
# `show` answers from $STUB_STATE/<unit>.state ("<ActiveState> <MainPID> <ExecMainStatus>"), which
# `start`/`stop` mutate. State, not a canned reply: the idempotency arm checks that the SECOND start
# issues no `start` call, and a stub that always answers "inactive" would make both runs look alive.
cat >"$STUB/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUB_LOG"
[ "${1:-}" = "--user" ] && shift
verb="${1:-}"; shift || true
unit="${1:-}"
name="${unit#harness-}"; name="${name%.service}"
state="$STUB_STATE/$unit.state"
case "$verb" in
  show-environment) exit 0 ;;
  daemon-reload|enable) exit 0 ;;
  is-enabled) printf 'enabled\n'; exit 0 ;;
  show)
    if [ -f "$state" ]; then read -r act pid ex <"$state"; else act=inactive; pid=0; ex=1; fi
    printf 'ActiveState=%s\nExecMainStatus=%s\nMainPID=%s\n' "$act" "$ex" "$pid"
    exit 0 ;;
  start)  printf 'active 6000 0\n' >"$state"; exit 0 ;;
  stop)   printf 'inactive 0 0\n' >"$state"; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/systemctl"

# launchd stub: `print` answers only for units whose state file exists, with launchd's OWN wording
# for "not found" — the tri-state arm depends on that exact text.
cat >"$STUB/launchctl" <<'STUBEOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$STUB_LOG"
verb="${1:-}"; shift || true
case "$verb" in
  print)
    target="${1:-}"; label="${target##*/}"; name="${label#com.eldato.harness.}"
    state="$STUB_STATE/$name.darwin"
    if [ -f "$state" ]; then
      read -r act pid ex <"$state"
      printf 'gui/501/%s = {\n\tstate = %s\n\tpid = %s\n\tlast exit code = %s\n}\n' "$label" "$act" "$pid" "$ex"
    else
      printf 'Could not find service "%s" in domain for user gui: 501\n' "$label"
      exit 113
    fi ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/launchctl"
export PATH="$STUB:/usr/local/bin:/usr/bin:/bin"

# ── a fake harness root (this checkout's bin/ + templates/, stub entries) ────────────────────
make_harness() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts/orchestrator-harness/bin" "$d/scripts"
  cp "$HARNESS" "$d/scripts/orchestrator-harness/bin/harness"
  cp -R "$SELF/../templates" "$d/scripts/orchestrator-harness/templates"
  local c
  for c in orch-loop.sh; do
    printf '#!/usr/bin/env bash\nsleep 300\n' >"$d/scripts/orchestrator-harness/$c"
    chmod +x "$d/scripts/orchestrator-harness/$c"
  done
  for c in disk-reaper.sh heartbeat-loop.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/scripts/$c"
    chmod +x "$d/scripts/$c"
  done
  printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$d/scripts/pr-doctor.py"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$d/scripts/orchestrator-harness/merge-one.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$d/scripts/orchestrator-harness/fix-one.sh"
  chmod +x "$d/scripts/orchestrator-harness/merge-one.sh" "$d/scripts/orchestrator-harness/fix-one.sh"
  mkdir -p "$d/scripts/orchestrator-harness"
  printf '%s\n' "$d" >"$TMP/fake-root"
}

FAKE="$(mktemp -d "$TMP/fake.XXXXXX")"
make_harness "$FAKE"
FH="$FAKE/scripts/orchestrator-harness"
ACTIVE="aaaaaaaaaaaa"

# Every arm runs the FAKE harness with the sealed environment below. HARNESS_ACTIVE_SHA is pinned
# because a temp dir has no git identity: the derived answer would be `unknown`, and an arm that
# only ever sees `unknown` cannot distinguish "matches" from "does not".
run_h() {
  env -u HARNESS_ENV_FILE \
    HARNESS_ROOT="$FH" \
    HARNESS_STATE_DIR="$TMP/state" \
    HARNESS_UNIT_DIR="$TMP/units" \
    HARNESS_ACTIVE_SHA="$ACTIVE" \
    HARNESS_PLATFORM=linux \
    HARNESS_ALLOW_FOREIGN_PLATFORM=1 \
    HARNESS_PS_FILE="$TMP/ps" \
    "${@}"
}
# write_ps <lines...> — a REALISTIC snapshot: a box always has processes, and the tool treats an
# EMPTY snapshot as an unreadable read (fail-closed, not "nothing is running"). So every arm starts
# from a snapshot that contains an unrelated process, and appends only the rows it is about.
write_ps() { printf '    1 /sbin/init\n' >"$TMP/ps"; for l in "$@"; do printf '%s\n' "$l" >>"$TMP/ps"; done; }
write_ps

# ═══ §1 — ONE template, TWO platforms: it RENDERS and the result PARSES ══════════════════════
# Non-vacuity: delete the `Restart=always` line from the linux template and this arm reddens; give
# the plist an unclosed <dict> and the plistlib parse raises.
rm -rf "$TMP/units"; mkdir -p "$TMP/units"
out="$(run_h bash "$FH/bin/harness" install 2>&1)"; rc=$?
ck "install renders the six linux units (rc=$rc)" $rc
unit="$TMP/units/harness-orch.service"
[ -f "$unit" ]; rc=$?; ck "the linux unit is named harness-<component>.service" $rc
grep -q '^Restart=always$' "$unit" 2>/dev/null; rc=$?
ck "the linux unit carries Restart=always" $rc
grep -q '^WantedBy=default.target$' "$unit" 2>/dev/null; rc=$?
ck "the linux unit is installable (WantedBy=default.target)" $rc
grep -q '^ExecStart="/.*/bin/harness" run orch$' "$unit" 2>/dev/null; rc=$?
ck "ExecStart is ABSOLUTE and launches the entry point (never a component script directly)" $rc
grep -q '__[A-Z_][A-Z_]*__' "$unit" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ]; rc=$?; ck "no unfilled template placeholder survives rendering" $rc
grep -q '^\[Service\]$' "$unit" 2>/dev/null && grep -q '^\[Install\]$' "$unit" 2>/dev/null; rc=$?
ck "the rendered unit has the [Service] and [Install] sections a parser requires" $rc
# The real parser when this host has one. A user manager is often unavailable in CI (`Failed to
# initialize manager`), so that specific inability is SKIPPED LOUDLY — it is not a unit defect.
if command -v systemd-analyze >/dev/null 2>&1; then
  verr="$(systemd-analyze verify --user "$unit" 2>&1)"
  case "$verr" in
    *"Failed to initialize manager"*|*"Failed to lookup RuntimeDirectory"*)
      echo "  ⏭  skip: systemd-analyze cannot initialise a manager on this host — structural parse above stands" ;;
    *)
      [ -z "$verr" ]; rc=$?
      ck "systemd-analyze verify accepts the rendered unit" $rc ;;
  esac
else
  echo "  ⏭  skip: no systemd-analyze on this host — structural parse above stands"
fi

rm -rf "$TMP/darwin"; mkdir -p "$TMP/darwin"
out="$(run_h env HARNESS_UNIT_DIR="$TMP/darwin" HARNESS_PLATFORM=darwin bash "$FH/bin/harness" install 2>&1)"; rc=$?
ck "install renders the six launchd plists on darwin (rc=$rc)" $rc
plist="$TMP/darwin/com.eldato.harness.orch.plist"
[ -f "$plist" ]; rc=$?; ck "the launchd unit is named com.eldato.harness.<component>.plist" $rc
if command -v python3 >/dev/null 2>&1; then
  python3 - "$plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
assert d["Label"] == "com.eldato.harness.orch", d["Label"]
assert d["KeepAlive"] is True, "KeepAlive must be true (the launchd form of Restart=always)"
assert d["RunAtLoad"] is True, "RunAtLoad must be true or the component never starts"
assert d["ProgramArguments"][1:] == ["run", "orch"], d["ProgramArguments"]
assert d["ProgramArguments"][0].endswith("/bin/harness"), d["ProgramArguments"][0]
assert not any("__" in str(v) for v in d.get("EnvironmentVariables", {}).values())
PY
  rc=$?; ck "plistlib PARSES the rendered plist and its keys are the contract's" $rc
else
  bad "no python3 to parse the plist — the darwin half of this gate is unexecuted"
fi

# ═══ §2 — status: a DEAD component reads DEAD, not RUNNING ═══════════════════════════════════
# Non-vacuity: collapse `DOWN)` into the `RUN)` arm in cmd_status and this reddens.
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
printf 'failed 0 2\n'   >"$STUB_STATE/harness-pr-doctor.service.state"
mkdir -p "$TMP/state/logs"
printf 'pr-doctor: objective.py failed to import\n' >"$TMP/state/logs/pr-doctor.log"
PIN="$TMP/pin"
mkdir -p "$PIN/$ACTIVE/scripts/orchestrator-harness"
write_ps " 4242 bash $PIN/$ACTIVE/scripts/orchestrator-harness/bin/harness run orch"

out="$(run_h bash "$FH/bin/harness" status 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "status exits 1 when a component is not OK (rc=$out)" $rc
case "$out" in
  *"orch        RUNNING($PIN/$ACTIVE/scripts/orchestrator-harness)"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "status reports the live component as RUNNING(<the dir it runs from>)" $rc
case "$out" in
  *'pr-doctor   DEAD(last exit 2, "pr-doctor: objective.py failed to import")'*) rc=0 ;;
  *) rc=1 ;;
esac
ck "status reports a dead component as DEAD(last exit, last log line)" $rc
case "$out" in
  *'pr-doctor   RUNNING'*) rc=1 ;;
  *) rc=0 ;;
esac
ck "a dead component is NEVER rendered RUNNING (the shell-pipe trap this arm exists for)" $rc
case "$out" in
  *"ACTIVE HARNESS SHA  $ACTIVE"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "status prints the ACTIVE HARNESS SHA" $rc
case "$out" in
  *"HARNESS VERSIONS    1 running"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "status prints how many harness versions are running" $rc

# ═══ §3 — doctor: two harness versions is a FAILURE, and both are NAMED ══════════════════════
# Non-vacuity: make distinct_shas return only the first row and this reddens (count 1, no FAIL).
# Every component is UP first, so the ONLY possible finding in this arm is the version one — an arm
# that reads rc=1 for an unrelated reason proves nothing about the version check.
rm -f "$STUB_STATE"/*.state
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
for c in diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 4242 bash $PIN/$ACTIVE/scripts/orchestrator-harness/bin/harness run orch" \
         " 9999 bash $PIN/bbbbbbbbbbbb/scripts/orchestrator-harness/orch-loop.sh"
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS with two harness shas running" $rc
case "$out" in
  *"2 harness versions are running"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "doctor says how many versions are running" $rc
case "$out" in
  *"sha $ACTIVE from"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "doctor names the ACTIVE sha and its path" $rc
case "$out" in
  *"sha bbbbbbbbbbbb from $PIN/bbbbbbbbbbbb"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "doctor names the OTHER sha and its path" $rc

# ═══ §4 — start twice is idempotent ══════════════════════════════════════════════════════════
# Non-vacuity: drop the `already running` arm and the second start issues six more `start` calls.
rm -f "$STUB_STATE"/*.state; : >"$STUB_LOG"; write_ps
out1="$(run_h bash "$FH/bin/harness" start 2>&1)"; rc1=$?
n1="$(grep -c '^systemctl --user start ' "$STUB_LOG" || true)"
out2="$(run_h bash "$FH/bin/harness" start 2>&1)"; rc2=$?
n2="$(grep -c '^systemctl --user start ' "$STUB_LOG" || true)"
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; rc=$?
ck "start exits 0 on the first AND second run (rc1=$rc1 rc2=$rc2)" $rc
[ "$n1" -eq 6 ] && [ "$n2" -eq 6 ]; rc=$?
ck "the second start issues NO new supervisor start calls (6 then $n2)" $rc
case "$out2" in
  *"already running"*"no-op"*) rc=0 ;;
  *) rc=1 ;;
esac
ck "the second start says it was a no-op, verbatim" $rc
# and install is idempotent too
: >"$STUB_LOG"
i2="$(run_h bash "$FH/bin/harness" install 2>&1)"
case "$i2" in *"already current"*"no-op"*) rc=0 ;; *) rc=1 ;; esac
ck "install twice is a no-op with a clear message" $rc

# ═══ §5 — version discipline: start STOPS the foreign sha and reports it ═════════════════════
# Non-vacuity: delete the `enforce_single_version` call from cmd_start and the process survives.
FOREIGN="$PIN/bbbbbbbbbbbb/scripts/orchestrator-harness/orch-loop.sh"
mkdir -p "${FOREIGN%/*}"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$FOREIGN"
bash "$FOREIGN" >/dev/null 2>&1 &
FPID=$!
SPAWNED="${SPAWNED:-} $FPID"
i=0; while [ "$i" -lt 50 ] && ! kill -0 "$FPID" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
rm -f "$STUB_STATE"/*.state            # use the REAL ps for this arm: it must see a real process
out="$(run_h env -u HARNESS_PS_FILE HARNESS_PIN_ROOT="$PIN" bash "$FH/bin/harness" start 2>&1)"; rc=$?
case "$out" in
  *"version-discipline: stopping pid $FPID from $PIN/bbbbbbbbbbbb"*) rc1=0 ;;
  *) rc1=1 ;;
esac
ck "start NAMES the foreign-version pid and its path before stopping it" $rc1
sleep 0.3
kill -0 "$FPID" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "start actually STOPPED the process running a different harness sha" $rc

# ═══ §6 — doctor: the other silent-death states are loud too ═════════════════════════════════
# (a) enabled but not running — non-vacuity: drop the sup_enabled branch and this arm reads clean.
rm -f "$STUB_STATE"/*.state; write_ps
mkdir -p "$TMP/state/logs"; printf 'boom\n' >"$TMP/state/logs/heartbeat.log"
printf 'failed 0 1\n' >"$STUB_STATE/harness-heartbeat.service.state"
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS a service that is enabled but not running" $rc
case "$out" in *"heartbeat is ENABLED but not running"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor names the enabled-but-down component" $rc

# (b) a required component's code is missing — non-vacuity: the `-e "$entry"` test is the guard.
mv "$FAKE/scripts/orchestrator-harness/fix-one.sh" "$TMP/fix-one.sh.away"
rm -f "$STUB_STATE"/*.state; write_ps
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS a MISSING required component" $rc
case "$out" in *"required component fix is MISSING"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor names the missing component and its path" $rc
mv "$TMP/fix-one.sh.away" "$FAKE/scripts/orchestrator-harness/fix-one.sh"

# (c) no supervisor at all — a box where systemctl cannot answer must never read healthy.
rm -rf "$TMP/units"
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS when no supervisor units are installed" $rc
case "$out" in *"no supervisor units installed"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor says the units are not installed, and what to run" $rc

# (d) an AD-HOC controller (running, but no unit owns it) is a WARN, not a silent pass.
run_h bash "$FH/bin/harness" install >/dev/null 2>&1
rm -f "$STUB_STATE"/*.state
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
for c in diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 7777 bash $FH/orch-loop.sh"
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
case "$out" in
  *"DOCTOR WARN: a controller is running OUTSIDE the supervisor (pid 7777"*) rc1=0 ;;
  *) rc1=1 ;;
esac
ck "doctor WARNS about a controller launched outside the supervisor" $rc1
[ "$rc" -eq 0 ]; rc=$?
ck "the ad-hoc warning alone does not fail the box (migration is legitimate)" $rc

# ═══ §7 — `run` is the ONE launch path, and it refuses what it does not know ═════════════════
out="$(run_h bash "$FH/bin/harness" run nope 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "run REFUSES an unknown component (rc=1)" $rc
case "$out" in *"unknown component 'nope'"*) rc=0 ;; *) rc=1 ;; esac
ck "run names the unknown component" $rc
# The declared entry is what actually executes: replace it with a marker write and run the row.
MARK="$TMP/ran.marker"
printf '#!/usr/bin/env bash\nprintf ran > %s\n' "$MARK" >"$FH/orch-loop.sh"
out="$(run_h bash "$FH/bin/harness" run orch 2>&1)"; rc=$?
[ -f "$MARK" ]; rc=$?
ck "run executes the DECLARED entry for the component (the inventory is the authority)" $rc
printf '#!/usr/bin/env bash\nsleep 300\n' >"$FH/orch-loop.sh"

# ═══ §8 — a unit whose path would break the version read is REFUSED at install time ══════════
# Non-vacuity: drop the whitespace guard and this arm exits 0, installing a unit whose processes the
# version read can never attribute.
mkdir -p "$TMP/with space"
out="$(run_h env HARNESS_ROOT="$TMP/with space" bash "$FH/bin/harness" install 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "install REFUSES a HARNESS_ROOT containing whitespace (the version read could not see it)" $rc

# ═══ §8b — CANNOT-DETERMINE is its own verdict, never green and never DEAD ══════════════════
# (a) an UNREADABLE supervisor: collapsing this into DOWN would report a component as crashed on the
# strength of a failed read; collapsing it into RUNNING would be a false pass. It is 2.
mkdir -p "$TMP/bin-fail"; printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin-fail/systemctl"; chmod +x "$TMP/bin-fail/systemctl"
write_ps
out="$(run_h env PATH="$TMP/bin-fail:/usr/local/bin:/usr/bin:/bin" bash "$FH/bin/harness" status 2>&1)"; rc=$?
[ "$rc" -eq 2 ]; rc=$?
ck "status exits 2 (cannot determine) when the supervisor cannot answer" $rc
case "$out" in *UNKNOWN*) rc=0 ;; *) rc=1 ;; esac
ck "status renders the unanswerable component as UNKNOWN, not DEAD and not RUNNING" $rc

# (b) an UNREADABLE process list makes the version statement unmeasurable — exit 2, not 0.
: >"$TMP/ps-empty"
out="$(run_h env HARNESS_PS_FILE="$TMP/ps-empty" bash "$FH/bin/harness" status 2>&1)"; rc=$?
[ "$rc" -eq 2 ]; rc=$?
ck "status exits 2 when ps cannot be read (an empty snapshot is not 'nothing is running')" $rc

# (c) the RECORDED start sha vs the harness's own sha — the one skew the process read cannot see,
# because a `git pull` under a running controller leaves its argv path (and therefore its derived
# sha) unchanged while its BYTES are older.
printf 'ffffffffffff\n' >"$TMP/state/active-sha"
write_ps
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
case "$out" in *"DOCTOR WARN: the supervisor was last started from sha ffffffffffff"*) rc1=0 ;; *) rc1=1 ;; esac
ck "doctor WARNS when the supervisor was last started from a different sha" $rc1
run_h bash "$FH/bin/harness" start >/dev/null 2>&1    # a supervised start re-records the sha
[ "$(cat "$TMP/state/active-sha" 2>/dev/null)" = "$ACTIVE" ]; rc=$?
ck "a supervised start re-records the active sha (the warning is self-healing)" $rc

# ═══ §9 — stop is idempotent, and stop-then-start is a restart ═══════════════════════════════
: >"$STUB_LOG"
run_h bash "$FH/bin/harness" start >/dev/null 2>&1    # everything UP, so restart has work to do
run_h bash "$FH/bin/harness" stop >/dev/null 2>&1
o2="$(run_h bash "$FH/bin/harness" stop 2>&1)"; rc=$?
[ "$rc" -eq 0 ]; rc=$?
ck "stop twice exits 0" $rc
case "$o2" in *"already stopped"*"no-op"*) rc=0 ;; *) rc=1 ;; esac
ck "the second stop says it was a no-op" $rc
run_h bash "$FH/bin/harness" start >/dev/null 2>&1    # back UP, so restart has both halves to do
: >"$STUB_LOG"
run_h bash "$FH/bin/harness" restart >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; rc=$?
ck "restart exits 0" $rc
grep -q '^systemctl --user stop ' "$STUB_LOG" && grep -q '^systemctl --user start ' "$STUB_LOG"; rc=$?
ck "restart stops AND starts through the supervisor" $rc

echo "───────────────────────────────────────────────────────────────────"
echo "harness.test.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
