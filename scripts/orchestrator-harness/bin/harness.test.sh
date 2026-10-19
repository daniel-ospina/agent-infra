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

# ═══ §1b — "written but NOT enabled" is not a no-op ══════════════════════════════════════════
# Non-vacuity: fold `enable_failed` into the no-op branch and this arm reads rc=0 with "no-op" over a
# box whose units will not come back after a reboot — the false PASS this file exists to prevent.
mkdir -p "$TMP/bin-noenable"
cat >"$TMP/bin-noenable/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--user" ] && shift
verb="${1:-}"; shift || true
case "$verb" in
  show-environment|daemon-reload) exit 0 ;;
  is-enabled) exit 1 ;;            # -> unknown, so install attempts enable
  enable) exit 1 ;;                # and the attempt fails
  show) printf 'ActiveState=inactive\nExecMainStatus=1\nMainPID=0\n'; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$TMP/bin-noenable/systemctl"
rm -rf "$TMP/units-ne"; mkdir -p "$TMP/units-ne"
out="$(run_h env PATH="$TMP/bin-noenable:/usr/local/bin:/usr/bin:/bin" HARNESS_UNIT_DIR="$TMP/units-ne" \
        bash "$FH/bin/harness" install 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "install FAILS when the units are written but cannot be enabled" $rc
case "$out" in *"NOT ENABLED"*) rc=0 ;; *) rc=1 ;; esac
ck "install says the units will not start at boot" $rc
case "$out" in *"no-op"*) rc=1 ;; *) rc=0 ;; esac
ck "install never calls that a no-op" $rc

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
# Non-vacuity: make distinct_shas return only the first row and this reddens (count 1, no FAIL); drop
# the active-sha comparison and the SECOND arm below reddens (one version, wrong sha, read as healthy).
# Every component is UP first, so the ONLY possible finding in this arm is the version one — an arm
# that reads rc=1 for an unrelated reason proves nothing about the version check.
# HARNESS_PIN_ROOT names the pin this box OWNS: the version verdict is scoped to it, so a foreign sha
# under it is this box's to reconcile (FAIL) while a peer checkout's is not (WARN, see §9b).
rm -f "$STUB_STATE"/*.state
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
for c in diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 4242 bash $PIN/$ACTIVE/scripts/orchestrator-harness/bin/harness run orch" \
         " 9999 bash $PIN/bbbbbbbbbbbb/scripts/orchestrator-harness/orch-loop.sh"
out="$(run_h env HARNESS_PIN_ROOT="$PIN" bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
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

# (c2) ONE component's unit gone while its code is present — `enabled but not running` cannot catch
# this (`is-enabled` fails on a nonexistent unit, which reads as "not enabled" and is skipped).
run_h bash "$FH/bin/harness" install >/dev/null 2>&1
rm -f "$TMP/units/harness-fix.service"
rm -f "$STUB_STATE"/*.state; write_ps
for c in orch diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS a component whose unit was never installed" $rc
case "$out" in *"required component fix has NO supervisor unit"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor names the component and the unit file that is missing" $rc
run_h bash "$FH/bin/harness" install >/dev/null 2>&1

# (d) an AD-HOC controller (running, but no unit owns it) is a WARN, not a silent pass.
run_h bash "$FH/bin/harness" install >/dev/null 2>&1
rm -f "$STUB_STATE"/*.state
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
for c in diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 7777 bash $FH/orch-loop.sh"
out="$(run_h bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
case "$out" in
  *"DOCTOR WARN: a harness process is running OUTSIDE the supervisor (pid 7777"*) rc1=0 ;;
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

# ── §7b — the ENV FILE reaches the component, and the per-component ARGS override ────────────
# Two arms, because the same seam produced two silent no-ops:
#  (a) `load_env_file` eval'd `export -p`'s `declare -x …` output INSIDE a function, where bash makes
#      it LOCAL — so the component inherited NOTHING from keys.env while the code claimed the hand
#      launch's environment was reproduced. Measured before the fix: a `FOO=fromenvfile` env file
#      read as `FOO=[MISSING]` in the component. Reverting the `export` rewrite reddens this arm.
#  (b) the README promises `HARNESS_ARGS_<COMPONENT>` can arm a dry-run-by-default tool (diskreaper);
#      delete the `args_override` application in `cmd_run` and the armed arm reddens. Read the
#      override BEFORE `load_env_file` and it reddens too: a systemd unit does not carry the
#      operator's shell, so the env file is the only place a supervised component could find it.
printf 'FOO=fromenvfile\nHARNESS_ARGS_ORCH=--armed\n' >"$TMP/comp.env"
printf '#!/usr/bin/env bash\nprintf "FOO=[%%s] args=[%%s]" "${FOO:-MISSING}" "$*" > %s\n' "$MARK" >"$FH/orch-loop.sh"
out="$(run_h env HARNESS_ENV_FILE="$TMP/comp.env" bash "$FH/bin/harness" run orch 2>&1)"; rc=$?
seen="$(cat "$MARK" 2>/dev/null)"
[ "$rc" -eq 0 ] && [ "$seen" = "FOO=[fromenvfile] args=[--armed]" ]; rc=$?
ck "the env file REACHES the component, and HARNESS_ARGS_<COMPONENT> arms it" $rc
printf 'FOO=fromenvfile\nHARNESS_ARGS_ORCH=\n' >"$TMP/comp.env"
out="$(run_h env HARNESS_ENV_FILE="$TMP/comp.env" bash "$FH/bin/harness" run orch 2>&1)"; rc=$?
seen="$(cat "$MARK" 2>/dev/null)"
[ "$rc" -eq 0 ] && [ "$seen" = "FOO=[fromenvfile] args=[]" ]; rc=$?
ck "an EMPTY override keeps the inventory's args (the inventory stays the default authority)" $rc
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

# ═══ §10 — an UNDETERMINED active sha is never a reason to kill ══════════════════════════════
# Measured shape: a cloud pin `/tmp/cell-home/harness/<8hex>/` is NOT a git checkout and carries no
# .harness-sha, so `active_sha` answers `unknown`. Without the guard, EVERY live sha differs from
# `unknown`, so `start` TERM→KILLs the box's own components (a pool mid-job included) and calls it
# reconciliation. Non-vacuity: delete the `active = unknown` guard in `enforce_single_version` and the
# sleeping process below is killed and reported as "stopping pid … (active is unknown)".
PINU="$TMP/pin-undet"; HDU="$PINU/aaaaaaaaaaaa/scripts/orchestrator-harness"
make_harness "$PINU/aaaaaaaaaaaa"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$HDU/orch-loop.sh"; chmod +x "$HDU/orch-loop.sh"
bash "$HDU/orch-loop.sh" >/dev/null 2>&1 &
LPID=$!; SPAWNED="${SPAWNED:-} $LPID"
i=0; while [ "$i" -lt 50 ] && ! kill -0 "$LPID" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
rm -f "$STUB_STATE"/*.state
# install with NO usable sha: no git under $PINU and HARNESS_ACTIVE_SHA unset, so nothing records one.
run_h env -u HARNESS_ACTIVE_SHA HARNESS_ROOT="$HDU" HARNESS_UNIT_DIR="$TMP/units-undet" \
  bash "$HDU/bin/harness" install >/dev/null 2>&1
out="$(run_h env -u HARNESS_ACTIVE_SHA -u HARNESS_PS_FILE HARNESS_ROOT="$HDU" HARNESS_UNIT_DIR="$TMP/units-undet" \
        bash "$HDU/bin/harness" start 2>&1)"; rc=$?
case "$out" in *"version reconciliation SKIPPED"*) rc1=0 ;; *) rc1=1 ;; esac
ck "start NAMES the undetermined active sha and skips reconciliation" $rc1
kill -0 "$LPID" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ]; rc=$?
ck "an undetermined active sha does NOT kill a live component (a kill needs a measured version)" $rc
kill -KILL "$LPID" 2>/dev/null

# ═══ §11 — doctor: ONE running version that is not the active sha is a FAILURE ════════════════
# Non-vacuity: go back to testing only `count -gt 1` and this arm reads rc=0 with "doctor: OK" over a
# component running different bytes — a COUNT standing in for a comparison.
rm -f "$STUB_STATE"/*.state
for c in orch diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 4242 bash $PIN/bbbbbbbbbbbb/scripts/orchestrator-harness/bin/harness run orch"
out="$(run_h env HARNESS_PIN_ROOT="$PIN" bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS when the ONLY running version is not the active sha" $rc
case "$out" in *"the only running harness version is NOT the active one"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor says the single running version is not the active one" $rc
case "$out" in *"sha bbbbbbbbbbbb from $PIN/bbbbbbbbbbbb"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor names the wrong sha and its path (not just a count)" $rc

# ═══ §11b — ZERO attributable processes is unmeasurable, not healthy ══════════════════════════
# Non-vacuity: drop the count==0 branch and doctor prints "OK — ... all components supervised and
# running" off a read that measured nothing.
rm -f "$STUB_STATE"/*.state
for c in orch diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps
out="$(run_h env HARNESS_PIN_ROOT="$PIN" bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "doctor FAILS when no harness process could be attributed" $rc
case "$out" in *"the version state is unmeasurable, which is never a pass"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor says the zero-row read is unmeasurable" $rc

# ═══ §11c — a version from ANOTHER checkout is named, and NOT graded as this box's ═══════════
# Non-vacuity: grade every foreign row as a FAIL and this arm reds — with a remedy ("run harness
# start") that can never reach a peer lane's worktree, which is how a gate gets ignored.
rm -f "$STUB_STATE"/*.state
for c in orch diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 4242 bash $PIN/$ACTIVE/scripts/orchestrator-harness/bin/harness run orch" \
         " 9999 bash $TMP/peer-lane/scripts/orchestrator-harness/bin/harness run orch"
out="$(run_h env HARNESS_PIN_ROOT="$PIN" bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
[ "$rc" -eq 0 ]; rc=$?
ck "an out-of-pin checkout does not fail this box's doctor" $rc
case "$out" in *"OUTSIDE $PIN"*"does not reconcile it"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor names the out-of-pin version and says start will not reach it" $rc

# ═══ §12 — start REFUSES units rendered from a different harness root ═════════════════════════
# After a pin move the installed units still name the OLD bin/harness. Without this refusal `start`
# launches stale bytes, reports "6 started", and overwrites the recorded sha that doctor compares
# against — a false PASS that disarms its own detector.
# Non-vacuity: delete the stale-unit comparison and this arm reads rc=0.
OTHER="$TMP/other-pin/bbbbbbbbbbbb/scripts/orchestrator-harness"
make_harness "$TMP/other-pin/bbbbbbbbbbbb"
run_h bash "$FH/bin/harness" install >/dev/null 2>&1         # units rendered from $FH
rm -f "$STUB_STATE"/*.state
out="$(run_h env HARNESS_ROOT="$OTHER" HARNESS_ACTIVE_SHA=bbbbbbbbbbbb \
        bash "$OTHER/bin/harness" start 2>&1)"; rc=$?
[ "$rc" -eq 1 ]; rc=$?
ck "start REFUSES when the installed units name a different harness root" $rc
case "$out" in *"run 'harness install' first"*) rc=0 ;; *) rc=1 ;; esac
ck "start says the units are stale and what to run" $rc
case "$out" in *"started"*) rc=1 ;; *) rc=0 ;; esac
ck "start does not claim it started anything on stale units" $rc

# ═══ §13 — a keys.env that EXITS part-way is named, not silently half-applied ════════════════
# Non-vacuity: remove the HARNESS_ENV_STATUS sentinel and the warning disappears while BAR stays
# silently unset — the silent variant of the `exit 0` class (#1713).
printf 'FOO=one\nexit 0\nBAR=two\n' >"$TMP/exit.env"
printf '#!/usr/bin/env bash\nprintf "FOO=[%%s] BAR=[%%s]" "${FOO:-MISS}" "${BAR:-MISS}" > %s\n' "$MARK" >"$FH/orch-loop.sh"
out="$(run_h env HARNESS_ENV_FILE="$TMP/exit.env" bash "$FH/bin/harness" run orch 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$MARK" 2>/dev/null)" = "FOO=[one] BAR=[MISS]" ]; rc=$?
ck "a keys.env that exits part-way still applies what it declared BEFORE the exit" $rc
case "$out" in *"exited before it finished"*) rc=0 ;; *) rc=1 ;; esac
ck "run WARNS that the env file exited before it finished" $rc
printf '#!/usr/bin/env bash\nsleep 300\n' >"$FH/orch-loop.sh"

# ═══ §13b — status never FABRICATES the dir a component runs from ════════════════════════════
# Non-vacuity: restore the `[ -n "$procdir" ] || procdir="$HARNESS_ROOT"` fallback and the second arm
# reds: the line claims the ACTIVE harness dir for a pid whose argv was never read.
rm -f "$STUB_STATE"/*.state
printf 'active 4242 0\n' >"$STUB_STATE/harness-orch.service.state"
write_ps
out="$(run_h bash "$FH/bin/harness" status 2>&1)"; rc=$?
case "$out" in *"RUNNING(pid 4242, dir UNATTRIBUTABLE"*) rc1=0 ;; *) rc1=1 ;; esac
ck "status marks an unreadable pid UNATTRIBUTABLE instead of guessing" $rc1
case "$out" in *"RUNNING($FH)"*) rc=1 ;; *) rc=0 ;; esac
ck "status does not claim the active harness dir for a pid it could not read" $rc

# ═══ §14 — a pool RECORDS a failed job (the worker owns and removes its argv file) ═══════════
# Non-vacuity: go back to `[ -f "$job" ] && mv "$job" "$job.failed-$rc"` and no failed record appears
# at all, because merge-one.sh/fix-one.sh `rm` the argv file themselves before they return.
JQ="$TMP/state/queue/merge"; mkdir -p "$JQ"
printf 'repo\nor\n1\nbranch\n' >"$JQ/1.job"
printf '#!/usr/bin/env bash\nA="${2:-}"\n[ -f "$A" ] && rm -f "$A"\nexit 3\n' >"$FH/merge-one.sh"; chmod +x "$FH/merge-one.sh"
run_h bash "$FH/bin/harness" run merge >/dev/null 2>&1 &
RPID=$!; SPAWNED="${SPAWNED:-} $RPID"
i=0; while [ "$i" -lt 60 ] && [ ! -f "$JQ/1.job.failed-3" ]; do sleep 0.05; i=$((i + 1)); done
kill -TERM "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
[ -f "$JQ/1.job.failed-3" ]; rc=$?
ck "a pool records a failed job as .failed-<rc> even though the worker removed its argv file" $rc
printf '#!/usr/bin/env bash\nexit 0\n' >"$FH/merge-one.sh"; chmod +x "$FH/merge-one.sh"

# ═══ §15 — an EIGHT-hex pin counts as two versions, and a scripts/ entry is attributable ══════
# The live cells pin with 8 hex (`/tmp/cell-home/harness/2ddd5b5a`). A 12-hex-only pattern read every
# pin as `unknown`, collapsing two DIFFERENT versions into one row — the two-version check inert on
# the exact boxes it exists for. Non-vacuity: restore the 12-hex pattern and both arms red.
# The second row is `…/<sha>/scripts/heartbeat-loop.sh`: the components living in `scripts/` are
# exec'd from there, so their argv names `…/scripts`, not `…/scripts/orchestrator-harness`.
PIN8="$TMP/pin8"
rm -f "$STUB_STATE"/*.state
for c in orch diskreaper heartbeat pr-doctor merge fix; do printf 'active 6000 0\n' >"$STUB_STATE/harness-$c.service.state"; done
write_ps " 4242 bash $PIN8/aaaa1234/scripts/orchestrator-harness/bin/harness run orch" \
         " 9999 bash $PIN8/bbbb5678/scripts/heartbeat-loop.sh"
out="$(run_h env HARNESS_PIN_ROOT="$PIN8" HARNESS_ACTIVE_SHA=aaaa1234 bash "$FH/bin/harness" doctor 2>&1)"; rc=$?
rc1=1
[ "$rc" -eq 1 ] && case "$out" in *"2 harness versions are running"*) rc1=0 ;; esac
ck "doctor COUNTS two versions in two EIGHT-hex pins" $rc1
case "$out" in *"sha bbbb5678 from $PIN8/bbbb5678/scripts"*) rc=0 ;; *) rc=1 ;; esac
ck "doctor attributes an exec'd scripts/ entry to its own pin sha" $rc

echo "───────────────────────────────────────────────────────────────────"
echo "harness.test.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
