#!/bin/bash
# ============================================================
# test-setup-no-nesting.sh — regression test for issue #93
#
# Verifies that pi-bootstrap/setup.sh:
#   (a) never NESTS cp -R copies into existing destination dirs
#       (BSD `cp -R SRC DEST` with an existing DEST creates
#        dest/agents/agents/... and never updates the active files);
#   (b) refreshes the ACTIVE ~/.pi/agent files on re-runs (repo
#       updates flow in, dest mutations get overwritten by source);
#   (c) preserves the extension/skills symlink farm regardless of
#       the repo's clone path (realpath comparison, not a
#       "/agent-infra" path substring).
#
# Runs the REAL setup.sh against a temp HOME. npm is stubbed so the
# test is hermetic and needs no network. The repo itself is only read
# (a single temporary marker file is added to pi-config and removed
# on exit via trap).
#
# Usage:  bash pi-bootstrap/tests/test-setup-no-nesting.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-setup-test.XXXXXX")"
HOME_DIR="$TMP/home"
CLONE="$TMP/repos/clone"          # symlink alias of the repo — no "agent-infra" in path
DEST="$HOME_DIR/.pi/agent"
RUNS_LOG="$TMP/runs.log"
FAILURES=0
SRC_MARKER=""                     # set later; guarded in cleanup

cleanup() {
  [ -n "$SRC_MARKER" ] && rm -f "$SRC_MARKER"
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

# --- hermetic environment -------------------------------------------------
mkdir -p "$HOME_DIR" "$TMP/bin" "$TMP/repos"
cat > "$TMP/bin/npm" <<'EOF'
#!/bin/bash
# Stub: setup.sh runs `npm install` per extension; keep the test offline.
exit 0
EOF
chmod +x "$TMP/bin/npm"
# #446 regression: this test runs the REAL setup.sh under a temp HOME, and
# setup.sh invokes scripts/install-launchd.sh (real launchd, real gui domain).
# Pre-fix, install-launchd bootstrapped the REAL domain with temp-home plists
# whose paths die with this test's TMP dir — observed: provider-latency-
# tripwire registered to a deleted pi-setup-test.*/home path, runs=0 (#446).
# Two-layer defense: (1) this shim shadows the real launchctl so ANY call is
# recorded (exit 99 — a call is a test failure by definition); (2) the
# installer's own temp-HOME guard refuses before calling launchctl, so the
# shim log stays empty. A non-empty log or a missing guard message fails the
# test. The installer happy-path stays covered hermetically by
# scripts/install-launchd.test.sh (fake HOME + shim + ELDATO_ALLOW_TEST_HOME=1).
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
# #446: real launchctl must NEVER be reachable from this temp-HOME setup test.
echo "UNEXPECTED launchctl call: $*" >> "${LAUNCHCTL_LOG:?}"
exit 99
EOF
chmod +x "$TMP/bin/launchctl"
export LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$LAUNCHCTL_LOG"
export PATH="$TMP/bin:$PATH"
export HOME="$HOME_DIR"

# Run setup.sh from a clone path that does NOT contain "agent-infra", proving
# farm-link recognition is realpath-based, not substring-based.
ln -s "$ROOT" "$CLONE"

# Pre-created farm links, both spellings:
#   1. target via the clone path (no "agent-infra" substring) — old code missed this
#   2. target via the physical repo path (like the live farm) — old code passed by luck
mkdir -p "$DEST/extensions"
ln -s "$CLONE/extensions/mcp-client" "$DEST/extensions/mcp-client"
ln -s "$ROOT/extensions/shared"      "$DEST/extensions/shared"

# --- helpers --------------------------------------------------------------
# Assert no directory exists whose basename equals its parent's basename
# (the `dest/agents/agents` nesting signature) under $1.
check_no_nesting() {
  local base="$1" label="$2" found d
  found="$(find "$base" -type d -print 2>/dev/null | while IFS= read -r d; do
    if [ "$(basename "$(dirname "$d")")" = "$(basename "$d")" ]; then
      echo "$d"
    fi
  done)"
  if [ -n "$found" ]; then
    fail "$label: self-nesting directories found under $base:"
    echo "$found" >&2
  else
    echo "ok: no self-nesting under $base"
  fi
}

# Assert every materialized extension under $1 matches extensions/ byte-for-byte
# (single source of truth, issue #95). Entries named after $2... are skipped
# (they are farm symlinks in this run, not materialized copies). Test files are
# never shipped (pi-config wires only real extensions).
check_content_matches() {
  local dest_ext="$1" label="$2" base e s
  shift 2
  for e in "$ROOT"/extensions/*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in
      *.test.ts) continue ;;
    esac
    for s in "$@"; do
      [ "$s" = "$base" ] && continue 2
    done
    [ -e "$dest_ext/$base" ] || { fail "$label: installed $base missing"; continue; }
    if diff -rq "$e" "$dest_ext/$base" >/dev/null 2>&1; then
      echo "ok: $label installed $base == extensions/$base"
    else
      fail "$label: installed $base differs from extensions/$base (stale copy!)"
    fi
  done
}

# Assert the #36/#101 fixes are present in the INSTALLED code (the exact drift
# issue #95 caught: fresh machines shipping pre-fix extensions).
check_fix_markers() {
  local ext="$1" label="$2"
  grep -q "getSubAgentPath" "$ext/subagent/index.ts" \
    || fail "$label: installed subagent missing getSubAgentPath (#101 fix not shipped)"
  grep -q "#36" "$ext/builtin-tools/index.ts" \
    || fail "$label: installed builtin-tools missing #36 PATH augmentation"
}

# #562 — merge-gate scripts farm parity: record-review.sh must be farmed to
# $DEST/scripts/ and byte-match the repo copy (the repo copy is CI-tested;
# production mints execute the ~/.pi copy — drift is a silent partial
# deployment of an enforcement-critical script).
check_record_review_farmed() {
  local label="$1"
  local dest="$DEST/scripts/record-review.sh"
  [ -f "$dest" ] \
    || { fail "$label: record-review.sh not farmed into scripts/ (merge-gate farm missing)"; return; }
  if diff -q "$ROOT/scripts/record-review.sh" "$dest" >/dev/null 2>&1; then
    echo "ok: $label farmed record-review.sh == repo copy (#562)"
  else
    fail "$label: farmed record-review.sh differs from scripts/record-review.sh (stale copy!)"
  fi
}

# #1178 — shared-library farm: scripts/lib/pid-identity.sh must land at
# $DEST/scripts/lib/pid-identity.sh, byte-identical to the repo copy, and the
# farmed reaper (which resolves the library from its OWN sibling directory) must
# actually load it. Farming the reaper without the library re-arms the hourly
# com.eldato.pi-session-reaper job with a fail-closed exit-3 abort on every pass.
check_identity_lib_farmed() {
  local label="$1"
  local dest="$DEST/scripts/lib/pid-identity.sh"
  local reaper="$DEST/scripts/pi-reap-idle.sh"
  [ -f "$dest" ] \
    || { fail "$label: lib/pid-identity.sh not farmed into scripts/lib/ (#1178 lib farm missing)"; return; }
  if diff -q "$ROOT/scripts/lib/pid-identity.sh" "$dest" >/dev/null 2>&1; then
    echo "ok: $label farmed lib/pid-identity.sh == repo copy (#1178)"
  else
    fail "$label: farmed lib/pid-identity.sh differs from scripts/lib/pid-identity.sh (stale copy!)"
  fi
  [ -f "$reaper" ] \
    || { fail "$label: pi-reap-idle.sh missing from the farm — cannot test its library resolution"; return; }
  # The farmed reaper sources the library BEFORE it parses argv, so a missing or
  # broken library IS the exit-3 "identity library missing" abort. `--help` is
  # the read-only mode: it signals nothing and touches no store.
  local out rc
  out="$(bash "$reaper" --help 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q "identity library missing" <<<"$out"; then
    echo "ok: $label farmed reaper resolves sibling lib/pid-identity.sh (--help rc=0)"
  else
    fail "$label: farmed reaper could not load its library (rc=$rc): $(head -1 <<<"$out")"
  fi
}

# #1178 unit 3 — fleet-tools farm: the scheduled lane-liveness report driver
# (tools/fleet/lane_liveness.py) and its sibling classifier
# (tools/fleet/liveness.py) must land under $DEST/tools/fleet/, byte-identical to
# the repo copies, in the layout that makes liveness.lib_path() resolve to the
# FARMED library (tools/fleet/ <-> scripts/lib/ preserved). Farming the driver
# without the classifier is the driver's loud exit-2 "cannot import" abort on
# every 30-minute pass; farming either into a repo symlink is the #427 TCC
# failure (launchd cannot read ~/Documents).
check_fleet_tools_farmed() {
  local label="$1"
  local driver="$DEST/tools/fleet/lane_liveness.py"
  local classifier="$DEST/tools/fleet/liveness.py"
  [ -f "$driver" ] \
    || { fail "$label: lane_liveness.py not farmed into tools/fleet/ (#1178 unit 3 farm missing)"; return; }
  [ -f "$classifier" ] \
    || { fail "$label: liveness.py not farmed beside the driver (the import would exit 2)"; return; }
  if diff -q "$ROOT/tools/fleet/lane_liveness.py" "$driver" >/dev/null 2>&1; then
    echo "ok: $label farmed lane_liveness.py == repo copy (#1178)"
  else
    fail "$label: farmed lane_liveness.py differs from tools/fleet/lane_liveness.py (stale copy!)"
  fi
  if diff -q "$ROOT/tools/fleet/liveness.py" "$classifier" >/dev/null 2>&1; then
    echo "ok: $label farmed liveness.py == repo copy (#1178)"
  else
    fail "$label: farmed liveness.py differs from tools/fleet/liveness.py (stale copy!)"
  fi
  # #1178 unit 4 — the two tools that lived ONLY as untracked files in
  # ~/.pi/agent/state/: the recovery primitive and the dead-lane reader.
  if diff -q "$ROOT/tools/fleet/fleet-health.py" "$DEST/tools/fleet/fleet-health.py" >/dev/null 2>&1; then
    echo "ok: $label farmed fleet-health.py == repo copy (#1178 unit 4)"
  else
    fail "$label: farmed fleet-health.py differs from (or is missing vs) tools/fleet/fleet-health.py"
  fi
  if diff -q "$ROOT/tools/fleet/map-sessions.py" "$DEST/tools/fleet/map-sessions.py" >/dev/null 2>&1; then
    echo "ok: $label farmed map-sessions.py == repo copy (#1178 unit 4)"
  else
    fail "$label: farmed map-sessions.py differs from (or is missing vs) tools/fleet/map-sessions.py"
  fi
  # The farmed driver must actually start from the farmed layout: it imports its
  # sibling classifier and forks the shared identity library. `--help` is the
  # read-only mode (no cmux call, no store read, no issue); the pinned
  # PI_PID_IDENTITY_LIB is the farmed library, never the repo's.
  local out rc
  out="$(cd "$TMP" && env HOME="$HOME_DIR" \
         PI_PID_IDENTITY_LIB="$DEST/scripts/lib/pid-identity.sh" \
         python3 "$driver" --help 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q "cannot import" <<<"$out"; then
    echo "ok: $label farmed driver imports its classifier (--help rc=0)"
  else
    fail "$label: farmed lane-liveness driver failed to start (rc=$rc): $(head -1 <<<"$out")"
  fi
}

# #1178 unit 4 — the PROMOTED liveness read in tools/fleet/fleet-health.py.
#
# Its `PID DEAD` used to come from `_alive(pid)` = a bare `os.kill(pid, 0)`: no
# start-time fence, no zombie rule. It now reads through the FARMED
# scripts/lib/pid-identity.sh via its sibling classifier's probe boundary (the
# same library the kill-path reaper sources). These controls pin both directions:
#
#   * the dead witness still FIRES — an absent pid, and a ZOMBIE. A zombie is the
#     crisp pre-fix failure: `os.kill(zombie, 0)` SUCCEEDS, so the bare existence
#     check read a defunct process as a live lane (no flag at all).
#   * an unresolvable read ABSTAINS as `PID ? (...)`, never `PID DEAD` — for pid
#     REUSE (off-fence), for a broken `ps`, for an unusable recorded start, and
#     when the canonical library is ABSENT. That last leg is the NEGATIVE control:
#     a "promotion" that fell back to a bare existence check prints `PID DEAD`
#     with no library on disk, and this test fails.
#   * an ABSTENTION must not SUPPRESS the quiet/CPU suspect ladder (#1178 A-class):
#     a stale lane whose identity could not be read is still a SUSPECT, never a
#     clean `✅ no suspects`. The same holds one level up: an unreadable or
#     shape-drifted HOOK STORE reports the scan INCOMPLETE with exit 1, and still
#     lists any suspect the ladder found.
#
# The positive legs are HERMETIC about the environment (see `run_promotion`), so a
# green pin also proves the tools/fleet/ <-> scripts/lib/ RELATIVE layout survived
# the farm: move the farmed library and they degrade to `PID ? (unreadable)`.
check_fleet_health_promotion() {
  local label="$1"
  local tool="$DEST/tools/fleet/fleet-health.py"
  local lib="$DEST/scripts/lib/pid-identity.sh"
  local phome="$TMP/prom-home"
  local sid="01a08ca6-3539-71ed-a0d7-7cee52feee03"   # lane B1 (the LANES hardcode)
  local store="$phome/.cmuxterm/pi-hook-sessions.json"
  local zpid_file="$TMP/zombie.pid" zparent="" zpid="" zstat="" out rc=0

  [ -f "$tool" ] || { fail "$label: farmed fleet-health.py missing — the promotion is unpinnable"; return; }
  [ -f "$lib" ]  || { fail "$label: farmed lib/pid-identity.sh missing — the promotion cannot load the rule"; return; }
  # fleet-health.py writes its CPU-delta cache to ~/.pi/agent/state/fleet-health-prev.json
  # and RAISES FileNotFoundError when that directory is absent (it does not create it).
  # A fresh HOME has no state/, so create the three directories the tool reads/writes.
  mkdir -p "$phome/.cmuxterm" "$phome/.pi/agent/state" "$phome/.pi/agent/sessions"
  rm -f "$zpid_file"

  # A ZOMBIE fixture: a child that exited and was never reaped, held by a live
  # parent for the duration of the checks. `os.kill(zpid, 0)` succeeds on it.
  python3 -c 'import os,sys,time
p = os.fork()
if p == 0:
    os._exit(0)
open(sys.argv[1], "w").write(str(p))
time.sleep(60)' "$zpid_file" &
  zparent=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$zpid_file" ] && { zpid="$(cat "$zpid_file")"; break; }
    sleep 0.2
  done
  # Pin the fixture's IDENTITY, not just its pid: a zombie that gets reaped before the
  # assertion degrades to plain `absent`, and the leg below would then pass for the wrong
  # reason (`PID DEAD` from absence, not from the zombie rule).
  [ -n "$zpid" ] && zstat="$(ps -o stat= -p "$zpid" 2>/dev/null | tr -d ' ')"

  # write_prom_store <pid> [startSeconds|__absent__] — one lane record. A start of
  # 1000000000 is deliberately far from any real start: it is only reached AFTER a
  # presence check, so an absent pid is still absent and a live pid is off-fence.
  write_prom_store() {
    local pid="$1" start="${2:-1000000000}"
    if [ "$start" = "__absent__" ]; then
      printf '{"sessions":{"%s":{"sessionId":"%s","pid":%s,"agentLifecycle":"running"}}}' \
        "$sid" "$sid" "$pid" > "$store"
    else
      printf '{"sessions":{"%s":{"sessionId":"%s","pid":%s,"pidStartSeconds":%s,"agentLifecycle":"running"}}}' \
        "$sid" "$sid" "$pid" "$start" > "$store"
    fi
  }
  # run_promotion [NAME=value ...] — HERMETIC by construction. PI_PID_IDENTITY_LIB,
  # PS_BIN and DATE_BIN are UNSET so the tool must resolve the FARMED library by
  # RELATIVE position (tools/fleet/ <-> scripts/lib/): liveness.lib_path() prefers the
  # env var, so an exported value (the lane-liveness plist pins it) would silently
  # replace the farmed library and make the whole layout pin vacuous. Extra NAME=value
  # arguments are applied on top — leg (d) uses that for its explicit override.
  run_promotion() {
    env -u PI_PID_IDENTITY_LIB -u PS_BIN -u DATE_BIN HOME="$phome" "$@" python3 "$tool" 2>&1
  }

  # (a) absent pid → the dead witness still fires.
  write_prom_store 999999
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    echo "ok: $label absent pid reads PID DEAD through the farmed library"
  else
    fail "$label: absent pid did NOT read PID DEAD — the promotion disabled the witness: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (b) pid REUSE: a live pid whose recorded start is off-fence → abstain.
  write_prom_store "$$"
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a LIVE pid with an off-fence start read PID DEAD (fence bypass)"
  elif grep -q "PID ? (off-fence)" <<<"$out"; then
    echo "ok: $label live-but-off-fence pid ABSTAINS as PID ? (off-fence), never PID DEAD"
  else
    fail "$label: off-fence pid neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (c) zombie → PID DEAD. The pre-fix bare existence check could not, and the probe
  # detail must be the ZOMBIE rule, not plain absence.
  if [[ "$zstat" == Z* ]]; then
    write_prom_store "$zpid"
    out="$(run_promotion)"
    if grep -q "PID DEAD" <<<"$out"; then
      echo "ok: $label zombie pid ($zpid, stat=$zstat) reads PID DEAD (no bare-existence read is possible)"
    else
      fail "$label: zombie pid read neither PID DEAD nor an abstention: $(grep -E '^B1 ' <<<"$out")"
    fi
  else
    fail "$label: the zombie fixture is not a zombie (stat='${zstat:-none}') — the A4 pin did not run"
  fi
  [ -n "$zparent" ] && kill "$zparent" 2>/dev/null || true

  # (d) NEGATIVE control — the canonical library absent.
  write_prom_store 999999
  out="$(run_promotion "PI_PID_IDENTITY_LIB=/nonexistent/pid-identity.sh")"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: NEGATIVE CONTROL FAILED — with the canonical library absent fleet-health.py still printed PID DEAD (bare-existence fallback)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label NEGATIVE CONTROL — library absent ⇒ PID ? (unreadable), never PID DEAD"
  else
    fail "$label: NEGATIVE CONTROL inconclusive — library absent yielded neither PID DEAD nor an abstention: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (e) the `ps` READ fails (live pid, valid start) → abstain, never PID DEAD.
  # `PS_BIN` is the library's own documented injection point for exactly this shape.
  write_prom_store "$$"
  out="$(run_promotion PS_BIN=/nonexistent/ps)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a failed ps read rendered PID DEAD (a read that did not happen is not a death witness)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label broken ps read ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: broken ps read neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (f)+(g) an UNUSABLE recorded start (absent / negative) with a LIVE pid → abstain.
  write_prom_store "$$" __absent__
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: a record with NO pidStartSeconds read PID DEAD (an unfenceable start must abstain)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label missing pidStartSeconds ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: missing pidStartSeconds neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi
  write_prom_store "$$" -1
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: pidStartSeconds=-1 read PID DEAD (an unusable start must abstain)"
  elif grep -q "PID ? (unreadable)" <<<"$out"; then
    echo "ok: $label pidStartSeconds=-1 ABSTAINS as PID ? (unreadable), never PID DEAD"
  else
    fail "$label: pidStartSeconds=-1 neither abstained nor read dead: $(grep -E '^B1 ' <<<"$out")"
  fi

  # (h) an ABSTENTION must not SUPPRESS the suspect ladder: off-fence + a STALE
  # transcript is still a suspect, never a clean report. The stale transcript is reused by
  # leg (i), which needs a lane to remain suspect while the STORE is unusable.
  local tfile="$phome/.pi/agent/sessions/--stale--/x_$sid.jsonl"
  mkdir -p "$(dirname "$tfile")"
  python3 -c 'import os,sys,time
open(sys.argv[1], "a").close()
os.utime(sys.argv[1], (time.time() - 1200, time.time() - 1200))' "$tfile"
  write_prom_store "$$"
  out="$(run_promotion)"
  if grep -q "PID DEAD" <<<"$out"; then
    fail "$label: off-fence + stale transcript read PID DEAD"
  elif grep -q "PID ? (off-fence)" <<<"$out" && grep -q "suspect(s)" <<<"$out"; then
    echo "ok: $label an abstaining lane with a stale transcript stays a SUSPECT (the abstention does not suppress the ladder)"
  else
    fail "$label: abstention SUPPRESSED the suspect ladder — a stale lane read as clean: $(grep -E '^B1 |no suspects' <<<"$out")"
  fi

  # (i) the DATA SOURCE abstains: an unreadable store and a shape-drifted store must each
  # report the scan INCOMPLETE with exit 1 — never `no suspects` — AND must still list a
  # suspect the ladder found (a failed read may not suppress it either). The exit code is
  # captured with `|| rc=$?` because `out="$(cmd)"; rc=$?` aborts the suite under `set -e`.
  printf '{"sessions":{' > "$store"
  rc=0; out="$(run_promotion)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q "INCOMPLETE" <<<"$out" && grep -q "suspect(s)" <<<"$out"; then
    echo "ok: $label unreadable hook store ⇒ INCOMPLETE (exit 1) and the stale lane is still a SUSPECT"
  else
    fail "$label: unreadable hook store did not abstain (rc=$rc): $(grep -E '^B1 |no suspects|INCOMPLETE' <<<"$out")"
  fi
  printf '{"sessions":{"drift":{"pid":%s}}}' "$$" > "$store"
  rc=0; out="$(run_promotion)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -q "INCOMPLETE" <<<"$out"; then
    echo "ok: $label shape-drifted hook store ⇒ INCOMPLETE (exit 1), never 'no suspects'"
  else
    fail "$label: shape-drifted hook store did not abstain (rc=$rc): $(grep -E '^B1 |no suspects|INCOMPLETE' <<<"$out")"
  fi
  write_prom_store 999999
  rm -f "$tfile"
}

run_setup() {
  echo "---- setup.sh run (HOME=$HOME_DIR) ----" >> "$RUNS_LOG"
  bash "$CLONE/pi-bootstrap/setup.sh" >> "$RUNS_LOG" 2>&1
}

# --- run 1: fresh install -------------------------------------------------
echo "== run 1: fresh install"
run_setup

[ -f "$DEST/agents/verifier.md" ] \
  || fail "agents not materialized (verifier.md missing)"
[ -f "$DEST/behavior-control/config.json" ] \
  || fail "behavior-control not materialized (config.json missing)"
if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: skills is a real folder"
else
  fail "skills should be a real folder after fresh install"
fi
[ -f "$DEST/extensions/subagent/index.ts" ] \
  || fail "subagent extension not materialized at top level"
[ -f "$DEST/extensions/audit-logger.ts" ] \
  || fail "single-file extension not copied (audit-logger.ts missing)"
check_no_nesting "$DEST" "dest"
check_no_nesting "$ROOT/extensions" "repo-extensions"
if [ -L "$DEST/extensions/mcp-client" ]; then
  echo "ok: farm link mcp-client kept"
else
  fail "farm link mcp-client was replaced by a materialized copy"
fi
if [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm link shared kept"
else
  fail "farm link shared was replaced by a materialized copy"
fi
[ "$(readlink "$DEST/extensions/mcp-client")" = "$CLONE/extensions/mcp-client" ] \
  || fail "mcp-client link target changed (now: $(readlink "$DEST/extensions/mcp-client" 2>/dev/null))"
[ "$(readlink "$DEST/extensions/shared")" = "$ROOT/extensions/shared" ] \
  || fail "shared link target changed (now: $(readlink "$DEST/extensions/shared" 2>/dev/null))"
grep -q "farm symlinks kept" "$RUNS_LOG" \
  || fail "run 1 did not report kept farm links"
check_content_matches "$DEST/extensions" "run1" mcp-client shared
check_fix_markers "$DEST/extensions" "run1"
check_record_review_farmed "run1"
check_identity_lib_farmed "run1"
check_fleet_tools_farmed "run1"
check_fleet_health_promotion "run1"
grep -q "scripts merge-gate farm: 1 copied (record-review.sh, #562)" "$RUNS_LOG" \
  || fail "run 1 did not report the merge-gate scripts farm copy (#562)"
grep -q "scripts lib farm: 1 copied (pid-identity.sh, #1178)" "$RUNS_LOG" \
  || fail "run 1 did not report the shared-library farm copy (#1178)"
grep -q "tools/fleet farm: 4 copied (lane-liveness + fleet-health + map-sessions, #1178)" "$RUNS_LOG" \
  || fail "run 1 did not report the fleet-tools farm copy (4 files, #1178)"

# --- run 2: re-run must refresh the ACTIVE files --------------------------
# (a) a dest mutation must be overwritten by the source (content-merge);
# (b) a NEW source file must propagate to the active dir.
echo "== run 2: re-run refresh"
echo "# machine-local mutation" >> "$DEST/agents/verifier.md"
echo "# stale farm mutation" >> "$DEST/scripts/record-review.sh"   # #562 farm refresh
if [ -f "$DEST/scripts/lib/pid-identity.sh" ]; then
  echo "# stale farm mutation" >> "$DEST/scripts/lib/pid-identity.sh"  # #1178 farm refresh
fi
if [ -f "$DEST/tools/fleet/lane_liveness.py" ]; then
  echo "# stale farm mutation" >> "$DEST/tools/fleet/lane_liveness.py"   # #1178 unit 3 farm refresh
fi
if [ -f "$DEST/tools/fleet/liveness.py" ]; then
  echo "# stale farm mutation" >> "$DEST/tools/fleet/liveness.py"        # #1178 unit 3 farm refresh
fi
if [ -f "$DEST/tools/fleet/fleet-health.py" ]; then
  echo "# stale farm mutation" >> "$DEST/tools/fleet/fleet-health.py"     # #1178 unit 4 farm refresh
fi
if [ -f "$DEST/tools/fleet/map-sessions.py" ]; then
  echo "# stale farm mutation" >> "$DEST/tools/fleet/map-sessions.py"     # #1178 unit 4 farm refresh
fi
SRC_MARKER="$ROOT/pi-bootstrap/pi-config/agents/zz-setup-test-marker.md"
echo "# issue-93 test marker" > "$SRC_MARKER"

run_setup

if [ -f "$DEST/agents/zz-setup-test-marker.md" ]; then
  echo "ok: new source file propagated to active dir on re-run"
else
  fail "new source file did not propagate to active dir on re-run"
fi
if grep -q "machine-local mutation" "$DEST/agents/verifier.md"; then
  fail "dest mutation survived re-run (active file was not refreshed)"
else
  echo "ok: dest mutation reverted by source on re-run"
fi
check_record_review_farmed "run2"
check_identity_lib_farmed "run2"
check_fleet_tools_farmed "run2"
if grep -q "stale farm mutation" "$DEST/tools/fleet/lane_liveness.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed lane_liveness.py was not refreshed)"
else
  echo "ok: farmed lane_liveness.py refreshed on re-run (#1178)"
fi
if grep -q "stale farm mutation" "$DEST/tools/fleet/liveness.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed liveness.py was not refreshed)"
else
  echo "ok: farmed liveness.py refreshed on re-run (#1178)"
fi
if grep -q "stale farm mutation" "$DEST/tools/fleet/fleet-health.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed fleet-health.py was not refreshed)"
else
  echo "ok: farmed fleet-health.py refreshed on re-run (#1178 unit 4)"
fi
if grep -q "stale farm mutation" "$DEST/tools/fleet/map-sessions.py" 2>/dev/null; then
  fail "stale farm mutation survived re-run (farmed map-sessions.py was not refreshed)"
else
  echo "ok: farmed map-sessions.py refreshed on re-run (#1178 unit 4)"
fi
if grep -q "stale farm mutation" "$DEST/scripts/record-review.sh"; then
  fail "stale farm mutation survived re-run (farmed record-review.sh was not refreshed)"
else
  echo "ok: farmed record-review.sh refreshed on re-run (#562)"
fi
if [ ! -f "$DEST/scripts/lib/pid-identity.sh" ]; then
  : # already reported by check_identity_lib_farmed "run2" (missing file is not "refreshed")
elif grep -q "stale farm mutation" "$DEST/scripts/lib/pid-identity.sh"; then
  fail "stale farm mutation survived re-run (farmed lib/pid-identity.sh was not refreshed)"
else
  echo "ok: farmed lib/pid-identity.sh refreshed on re-run (#1178)"
fi
[ ! -d "$DEST/agents/agents" ] || fail "nesting appeared after re-run"
check_no_nesting "$DEST" "dest-after-rerun"
check_no_nesting "$ROOT/extensions" "repo-extensions-after-rerun"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm links survived re-run"
else
  fail "farm links lost on re-run"
fi

# --- run 3: stale/foreign links are replaced, not followed -----------------
echo "== run 3: stale/foreign symlink replacement"
ln -s "/nonexistent/pi-93-target" "$DEST/extensions/tortoise-capture"   # broken
ln -s "$TMP/foreign-checkout/extensions" "$DEST/extensions/slack-bridge" # foreign

run_setup

if [ -d "$DEST/extensions/tortoise-capture" ] && [ ! -L "$DEST/extensions/tortoise-capture" ]; then
  echo "ok: broken symlink tortoise-capture replaced with a real folder"
else
  fail "broken symlink tortoise-capture was not replaced (still a link or missing)"
fi
if [ -d "$DEST/extensions/slack-bridge" ] && [ ! -L "$DEST/extensions/slack-bridge" ]; then
  echo "ok: foreign symlink slack-bridge replaced with a real folder"
else
  fail "foreign symlink slack-bridge was not replaced"
fi
[ -f "$DEST/extensions/tortoise-capture/index.ts" ] \
  || fail "replaced tortoise-capture is missing content"
check_no_nesting "$DEST" "dest-after-run3"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: good farm links still kept after run 3"
else
  fail "good farm links lost during stale-link replacement"
fi

# --- run 4: skills farm symlink preservation ---------------------------------
echo "== run 4: skills farm"
# Point the skills farm into this repo via the clone path (no "agent-infra") —
# the realpath comparison must keep it; the old substring grep would miss it.
rm -rf "$DEST/skills"
ln -s "$CLONE/skills" "$DEST/skills"

run_setup

if [ -L "$DEST/skills" ] && [ "$(readlink "$DEST/skills")" = "$CLONE/skills" ]; then
  echo "ok: skills farm symlink kept (clone-path target)"
else
  fail "skills farm symlink was not kept (now: $(readlink "$DEST/skills" 2>/dev/null || echo 'not a link'))"
fi

# Foreign skills symlink → must be replaced with a real folder.
rm -rf "$DEST/skills"
ln -s "$TMP/foreign-skills" "$DEST/skills"

run_setup

if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: foreign skills symlink replaced with a real folder"
else
  fail "foreign skills symlink was not replaced with a real folder"
fi
[ -d "$DEST/skills" ] && [ -n "$(ls -A "$DEST/skills" | head -1)" ] \
  || fail "replaced skills folder is empty"

# --- run 5: completely fresh extensions install (no pre-existing farm) --------
# The exact issue #95 acceptance: a machine with NO prior state must receive the
# CURRENT extension code, as real materialized copies (not links to a clone).
echo "== run 5: fresh extensions install, zero pre-existing links"
rm -rf "$DEST/extensions"
run_setup

links_found="$(find "$DEST/extensions" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
if [ "$links_found" -eq 0 ]; then
  echo "ok: fresh install materialized real copies (no symlinks)"
else
  fail "fresh install left $links_found symlink(s) in $DEST/extensions"
fi
check_content_matches "$DEST/extensions" "run5"
check_fix_markers "$DEST/extensions" "run5"
check_no_nesting "$DEST" "dest-after-run5"

# --- run 6: stale materialized copies self-heal on re-run ---------------------
# A previously-bootstrapped machine has real copies (possibly stale). Re-running
# setup.sh must refresh them to CURRENT extensions/ content.
echo "== run 6: stale DEST copies refreshed to current extensions/ content"
echo "# stale mutation" >> "$DEST/extensions/subagent/index.ts"
echo "# stale mutation" >> "$DEST/extensions/builtin-tools/index.ts"
run_setup
check_content_matches "$DEST/extensions" "run6"
check_fix_markers "$DEST/extensions" "run6"

# --- done -----------------------------------------------------------------
# #446: seven setup.sh runs happened under the temp HOME; the launchctl shim
# must be SILENT (no call escaped to any launchctl) and the installer's
# temp-HOME guard must have refused every time (message present per run).
# Darwin-only in practice (setup.sh reaches install-launchd only on Darwin);
# guarded so a hypothetical Linux CI run can't fail on these assertions.
if [[ "$(uname)" == "Darwin" ]]; then
  setup_runs="$(grep -c '^---- setup.sh run' "$RUNS_LOG")"
  if [ -s "$LAUNCHCTL_LOG" ]; then
    fail "launchctl was called $setup_runs setup-run(s) in: $(cat "$LAUNCHCTL_LOG" | head -1)"
  elif [ "$setup_runs" -ge 1 ]; then
    echo "ok: zero launchctl calls across $setup_runs setup runs (real domain untouched)"
  else
    fail "no setup.sh runs recorded — cannot verify launchctl isolation"
  fi
  guard_hits="$(grep -c 'refusing to manage launchd jobs' "$RUNS_LOG" || true)"
  if [ "$guard_hits" -eq "$setup_runs" ] && [ "$setup_runs" -ge 1 ]; then
    echo "ok: temp-HOME guard fired on all $setup_runs runs"
  else
    fail "temp-HOME guard fired $guard_hits/$setup_runs runs (expected every run)"
  fi
else
  echo "ok: launchctl-isolation assertions skipped (non-Darwin)"
fi
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILURES: $FAILURES — full output: $RUNS_LOG" >&2
  echo "---- last run log ----" >&2
  tail -40 "$RUNS_LOG" >&2 || true
  exit 1
fi
echo ""
echo "OK: no nesting, active files refreshed, farm links preserved (clone path: $CLONE)"
