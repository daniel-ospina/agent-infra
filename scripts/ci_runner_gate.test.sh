#!/usr/bin/env bash
# ci_runner_gate.test.sh — hermetic suite for scripts/ci_runner_gate.sh + its wiring.
#
# Run: bash scripts/ci_runner_gate.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. NO network, NO real `gh`, NO real state:
# `gh` and `curl` are stubs on PATH and every sink under test is a temp dir
# (CI_GATE_STATE_DIR / HOME). Runs as a bash shard in BOTH CI lanes
# (scripts/run-bash-shards.sh).
#
# WHY (agent-infra#1704) — the gate RELABELS the local runner pool, so every value it branches on
# must be a value it actually READ. Two fail-opens were measured, both reported as success:
#
#   1. the queue comparison. `queued` was never shape-checked (unlike `comp`), so a successful probe
#      yielding `null`/empty made `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR (status 2), and the
#      `||` chain reads a failed test as false — HEALTHY. "Healthy" means want=github ->
#      `fallback_off`, i.e. a relabel taken on a value that was never read.
#   2. `set_labels`. `runner_ids()` discarded its status and its output was consumed by
#      `for id in $(runner_ids)`, so a failed enumeration iterated zero runners, left ok=0 fail=0,
#      and `[ "$fail" -eq 0 ]` returned SUCCESS — after which `main` wrote the new mode to
#      ci-runner-gate.state and sent a TRANSITION notification as if the pool had been relabelled.
#
# Both must FAIL CLOSED (exit 2, "could-not-measure", changing nothing) with the failure NAMED, and
# neither may advance the state file or notify. The cases below include the negative controls: a
# numeric queue still acts, a successful enumeration still relabels.
#
# Also pins the #1719 AGREEMENT: the scheduled job, the farm list and the script must name the SAME
# landed path — the defect was two surfaces (plist + farm) that never agreed and were never called.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/ci_runner_gate.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}
assert_absent() { # <path> <label>
  if [ -e "$1" ]; then bad "$2 (exists: $1)"; else ok "$2"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-gate-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
GH_LOG="$T/gh.log"

# ── `gh` test double ────────────────────────────────────────────────────────
# Behavior is driven by env only, so the suite never touches the real gh. Three call shapes reach
# the gate: the queue probe, the per-page fallback count (current_mode), the id enumeration
# (runner_ids), and the label PUT.
#   GH_QUEUED      queue probe .total_count (default 5)
#   GH_MODE        queued-null | queued-empty | enum-fail | enum-garbage | ok
#   GH_FALLBACK_N  per-page count of fallback-labelled runners (current_mode → github|local)
#   GH_POOL_IDS    the ids the enumeration returns
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  *"-X PUT"*) exit 0 ;;
  *"--jq .total_count"*)
    case "${GH_MODE:-ok}" in
      queued-null)  printf 'null\n' ;;
      queued-empty) printf '\n' ;;
      *)            printf '%s\n' "${GH_QUEUED:-5}" ;;
    esac
    exit 0 ;;
  *"--paginate"*)
    # current_mode asks for a COUNT (a --jq expression with `select(`); runner_ids asks for the ids.
    if [[ "$*" == *"select("* ]]; then
      printf '%s\n' "${GH_FALLBACK_N:-0}"
      exit 0
    fi
    case "${GH_MODE:-ok}" in
      enum-fail)    printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      enum-garbage) printf 'null\n' ;;
      # `-` not `:-`: the empty-pool case below sets GH_POOL_IDS to the EMPTY string on purpose,
      # and `:-` would swallow that into the default, making the case vacuous.
      *)            printf '%s\n' "${GH_POOL_IDS-101 102}" ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# The githubstatus summary: Actions operational, no incidents — so the queue threshold is the only
# unhealthy lever this suite pulls.
printf '%s' '{"components":[{"name":"Actions","status":"operational"}],"incidents":[]}'
STUB
chmod +x "$BIN/curl"

RC=0
OUT=""
STATE_DIR=""
GH_THRESHOLD_DEFAULT=60

# run_gate <case> [ENV=…]... -- [gate args] — one hermetic invocation.
# CI_GATE_ORCH_WS="" keeps the cmux leg out of the picture: the durable inbox file is the
# deterministic notification sink, so "did it notify?" has one readable answer.
run_gate() {
  local name="$1"; shift
  local home="$T/home-$name"
  STATE_DIR="$T/state-$name"
  mkdir -p "$STATE_DIR" "$home"
  : > "$GH_LOG"
  (
    export HOME="$home"
    export PATH="$BIN:$PATH"
    export GH_LOG
    export CI_GATE_STATE_DIR="$STATE_DIR"
    export CI_GATE_REPO="test-org/test-repo"
    export CI_GATE_QUEUE_THRESHOLD="$GH_THRESHOLD_DEFAULT"
    export CI_GATE_ORCH_WS=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      export "$1"
      shift
    done
    if [ "${1:-}" = "--" ]; then shift; fi
    bash "$GATE" "$@"
  ) > "$T/out-$name" 2>&1
  RC=$?
  OUT="$(cat "$T/out-$name")"
}

echo "── control: a numeric queue + a readable pool takes the normal path ──"
run_gate healthy GH_QUEUED=5 GH_FALLBACK_N=0 GH_MODE=ok --
assert_eq "$RC" "0" "healthy run exits 0 (numeric queue stays a real measurement)"
assert_contains "$OUT" "queued=5" "healthy run logs the value it read"
assert_contains "$OUT" "TRANSITION unknown -> github" "healthy run records the transition into github"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "healthy run records mode=github"
assert_not_contains "$OUT" "WARNING" "healthy run raises no warning"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "healthy run (mode==want) relabels nothing"

echo "── no-change control: the recorded mode is not re-notified ──"
seed_state() { # <case> <mode> — pre-record a mode so the next run sees prev == want
  mkdir -p "$T/state-$1"
  printf '%s\n' "$2" > "$T/state-$1/ci-runner-gate.state"
}
seed_state steady github
run_gate steady GH_QUEUED=5 GH_FALLBACK_N=0 GH_MODE=ok --
assert_eq "$RC" "0" "steady run exits 0"
assert_contains "$OUT" "no change (mode=github want=github)" "steady run reports no change"
assert_not_contains "$OUT" "TRANSITION" "steady run re-notifies nothing"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "steady run writes no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "steady run relabels nothing"

echo "── #1704(1): an unreadable queue count must FAIL CLOSED ──"
run_gate q-null GH_MODE=queued-null GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "queued=null → exit 2 (could-not-measure)"
assert_contains "$OUT" "queued=null" "queued=null reports the value it could not read"
assert_contains "$OUT" "UNREADABLE" "queued=null names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "queued=null advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "queued=null sent no transition notification"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "queued=null wrote no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "queued=null relabelled no runner"

run_gate q-empty GH_MODE=queued-empty GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an EMPTY queue count → exit 2 (could-not-measure)"
assert_contains "$OUT" "UNREADABLE" "empty queue count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "empty queue count advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "empty queue count sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "empty queue count relabelled no runner"

echo "── #1704(2): a failed runner enumeration must FAIL CLOSED ──"
# threshold 1 + queued 5 + a readable pool reading `github` ⇒ want=local, so the gate DOES attempt a
# relabel: that is the path on which a failed enumeration used to be recorded as success.
run_gate enum-fail GH_MODE=enum-fail GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "failed enumeration → exit 2 (fail-closed)"
assert_contains "$OUT" "WARNING: runner enumeration FAILED" "failed enumeration is named as a failure"
assert_contains "$OUT" "HTTP 500" "failed enumeration carries gh's reason (not swallowed)"
assert_absent "$STATE_DIR/ci-runner-gate.state" "failed enumeration advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "failed enumeration sent no transition notification"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "failed enumeration wrote no inbox record"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "failed enumeration relabelled no runner"

run_gate enum-garbage GH_MODE=enum-garbage GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a non-numeric enumeration payload → exit 2 (never iterated as ids)"
assert_contains "$OUT" "runner enumeration unreadable" "a non-numeric enumeration payload is named"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a non-numeric enumeration payload relabels nothing"

echo "── control: a readable enumeration still relabels (the fix is not 'always fail') ──"
run_gate relabel GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="101 102" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "successful relabel exits 0"
assert_contains "$OUT" "set_labels ok=2 fail=0" "successful relabel counts both runners"
assert_contains "$OUT" "TRANSITION unknown -> local" "successful relabel records the transition"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "successful relabel records mode=local"

# The distinction #1704 names: "the pool has zero runners" is a READABLE zero, not a failed read.
# A successful, EMPTY enumeration must stay a success — conflating it with the API failure above
# would make the gate refuse a state it can actually see (the plan's rejected "treat an empty
# enumeration as a failure"). This is the negative control for the two cases above: it passes on the
# pre-fix tree TOO, which is the point — the fix must not convert every empty iteration into a fail.
run_gate relabel-empty GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS= CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a successful EMPTY enumeration exits 0 (a readable zero is not a failed read)"
assert_contains "$OUT" "set_labels ok=0 fail=0" "empty pool counts zero relabels, not a swallow"
assert_not_contains "$OUT" "WARNING" "empty pool raises no enumeration warning"

echo "── --dry-run and --status stay read-only ──"
run_gate dry GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 -- --dry-run
assert_eq "$RC" "0" "dry-run exits 0"
assert_contains "$OUT" "dry-run: mode=github want=local" "dry-run reports the decision it would take"
assert_absent "$STATE_DIR/ci-runner-gate.state" "dry-run advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "dry-run relabelled nothing"

run_gate status GH_MODE=ok GH_FALLBACK_N=2 -- --status
assert_eq "$RC" "0" "--status exits 0"
assert_contains "$OUT" "mode=local repo=test-org/test-repo" "--status reports the read mode"
assert_absent "$STATE_DIR/ci-runner-gate.state" "--status advanced no state file"

run_gate status-fail GH_MODE=ok GH_FALLBACK_N=null -- --status
assert_eq "$RC" "2" "--status with an unreadable pool read exits 2 (never a guessed mode)"
assert_contains "$OUT" "non-numeric" "--status names the unreadable pool read"

run_gate usage -- --bogus
assert_eq "$RC" "1" "an unknown flag is a usage error"

echo "── #1719: the scheduled job, the farm and the script must agree ──"
# The #1719 defect was two surfaces that never met: a template nothing rendered and a farm list the
# repo copy was absent from. Assert the AGREEMENT (same basename at the same land path), which
# neither the installer suite nor the setup suite can see on its own.
TEMPLATE="$REPO_ROOT/templates/launchd/com.tortoise.ci-runner-gate.plist"
if [ -f "$TEMPLATE" ]; then
  ok "launchd template exists for the runner gate (#1719)"
  assert_contains "$(cat "$TEMPLATE")" "{{HOME}}/.pi/agent/scripts/$(basename "$GATE")" \
    "template executes the path the pi-bootstrap farm lands"
  assert_contains "$(cat "$TEMPLATE")" "{{PATH}}" \
    "template takes PATH from the installer's (shim-filtered) renderer"
  assert_not_contains "$(cat "$TEMPLATE")" "/shims" \
    "template hardcodes no shim directory (launchd cannot exec into ~/Documents, #427)"
else
  bad "no templates/launchd/com.tortoise.ci-runner-gate.plist — the gate is wired to nothing (#1719)"
fi
SETUP="$REPO_ROOT/pi-bootstrap/setup.sh"
assert_contains "$(cat "$SETUP")" "$(basename "$GATE")" \
  "pi-bootstrap farm list carries the gate (#1719)"

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ ci_runner_gate suite: $FAIL failure(s), $PASS passed"
  exit 1
fi
echo "✅ ci_runner_gate suite: all $PASS assertions passed"
exit 0
