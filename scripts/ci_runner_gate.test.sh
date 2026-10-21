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
CMUX_LOG="$T/cmux.log"

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
# ⛔ CONSUME `--input -` (the label PUT body), because the REAL gh does. The gate calls
# `printf '%s' "$body" | gh api -X PUT … --input -` under `set -o pipefail`, so a double that
# exits without reading stdin lets the writer take SIGPIPE the moment this process wins the race
# (measured: rc=141, `set_labels ok=1 fail=1`, a "relabel FAILED" from a PUT that never happened).
# Whether it fires depends on scheduling, so the suite was INTERMITTENTLY red — 3 of 10 local
# runs, on legs as unrelated as the healthy control and the cmux leg. Draining the pipe removes
# the race; it does not weaken an assertion, and a stalled writer still fails as it did before.
case "$*" in *"--input -"*) cat >/dev/null 2>&1 || true ;; esac
case "$*" in
  *"-X PUT"*)
    # GH_PUT_FAIL_ID lets a case fail ONE runner's PUT, which is how a PARTIAL relabel is built.
    case "$*" in *"/runners/${GH_PUT_FAIL_ID:-none}/labels"*) exit 1 ;; esac
    exit 0 ;;
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

printf '%s' '{"components":[{"name":"Actions","status":"operational"}],"incidents":[]}' > "$T/status-default.json"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# The githubstatus summary, read from a FILE: the default is Actions operational with no incidents,
# so the queue threshold is the only unhealthy lever this suite pulls. CURL_BODY (handled in
# run_gate) points CURL_STATUS_FILE at a different body — a null or empty component status, a
# newline in the status, a live incident — without any nested quoting in the stub.
cat "${CURL_STATUS_FILE:?}"
STUB
chmod +x "$BIN/curl"

# ⛔ The cmux leg MUST be stubbed (review E1). `notify()` calls `cmux agent message <ORCH_WS>` when
# `cmux` is on PATH, and `CI_GATE_ORCH_WS=""` only disables it because the gate reads
# `${CI_GATE_ORCH_WS-…}` (dash, not `:-`). Before that fix — and for ANY box that reverts it to
# `:-` — this suite invoked the REAL cmux against the live ORCHESTRATOR lane ("never dispatch
# here"), waking that agent and writing production state from a test. The stub makes it impossible
# to reach the real binary, and CMUX_LOG is asserted empty so the disable path is pinned too.
cat > "$BIN/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CMUX_LOG:?}"
exit 0
STUB
chmod +x "$BIN/cmux"

RC=0
OUT=""
STATE_DIR=""
KEEP_STATE=0
GH_THRESHOLD_DEFAULT=60

# run_gate <case> [ENV=…]... -- [gate args] — one hermetic invocation.
# CI_GATE_ORCH_WS="" keeps the cmux leg out of the picture: the durable inbox file is the
# deterministic notification sink, so "did it notify?" has one readable answer. That claim is only
# true because the gate reads `${CI_GATE_ORCH_WS-…}`; CMUX_LOG (asserted empty at the end) is what
# catches a regression to `:-`, and the cmux stub is what stops such a regression reaching the
# live orchestrator lane at all.
run_gate() {
  local name="$1"; shift
  local home="$T/home-$name"
  STATE_DIR="$T/state-$name"
  # KEEP_STATE=1 makes the next call a REPEAT pass against the SAME home + state dir, for cases
  # whose whole point is what the NEXT tick does (a retried relabel). It is one-shot.
  if [ "$KEEP_STATE" = 1 ]; then KEEP_STATE=0; else mkdir -p "$STATE_DIR" "$home"; fi
  : > "$GH_LOG"
  # ⛔ CMUX_LOG is NOT truncated per run (review: the truncation made the suite's closing
  # "no run invoked cmux" assertion VACUOUS — every invocation wiped the previous run's line, and
  # the last four runs exit before `notify()`, so the count was always 0 even with the leg enabled).
  # It is truncated ONCE, before the first run, so the closing count spans the whole suite.
  (
    export HOME="$home"
    export PATH="$BIN:$PATH"
    export GH_LOG
    export CMUX_LOG
    export CI_GATE_STATE_DIR="$STATE_DIR"
    export CI_GATE_REPO="test-org/test-repo"
    export CI_GATE_QUEUE_THRESHOLD="$GH_THRESHOLD_DEFAULT"
    export CI_GATE_ORCH_WS=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      export "$1"
      shift
    done
    if [ "${1:-}" = "--" ]; then shift; fi
    if [ -n "${CURL_BODY:-}" ]; then
      printf '%s' "$CURL_BODY" > "$T/status-$name.json"
      export CURL_STATUS_FILE="$T/status-$name.json"
    else
      export CURL_STATUS_FILE="$T/status-default.json"
    fi
    bash "$GATE" "$@"
  ) > "$T/out-$name" 2>&1
  RC=$?
  OUT="$(cat "$T/out-$name")"
}

echo "── control: a numeric queue + a readable pool takes the normal path ──"
: > "$CMUX_LOG"   # ONE truncation for the whole suite — see run_gate
run_gate healthy GH_QUEUED=5 GH_FALLBACK_N=0 GH_MODE=ok --
assert_eq "$RC" "0" "healthy run exits 0 (numeric queue stays a real measurement)"
assert_contains "$OUT" "queued=5" "healthy run logs the value it read"
assert_contains "$OUT" "TRANSITION unknown -> github" "healthy run records the transition into github"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "healthy run records mode=github"
assert_not_contains "$OUT" "WARNING" "healthy run raises no warning"
# A FRESH box (no recorded mode) CONVERGES the pool before recording, even when the observed mode
# already equals the desired one (review B2-3): the state file is the record of convergence, so its
# absence is the trigger to converge. The `steady` control below is the no-churn case.
assert_contains "$(cat "$GH_LOG")" "-X PUT" "a fresh box converges the labels before recording the transition"

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

# ⛔ A digit string longer than `intmax` passes a character-class guard and STILL errors the `-ge`
# comparison (review B2-2), and the `||` chain reads that error as false — HEALTHY — relabelling the
# pool, advancing the state file and notifying, exit 0, on a comparison that never ran.
echo "── #1704(3): an unreadable or out-of-range queue THRESHOLD must FAIL CLOSED ──"
run_gate qt-junk GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=abc --
assert_eq "$RC" "2" "a non-numeric threshold → exit 2 (could-not-measure)"
assert_contains "$OUT" "queue threshold UNREADABLE" "a non-numeric threshold names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a non-numeric threshold advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a non-numeric threshold sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a non-numeric threshold relabelled no runner"

run_gate qt-huge GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=99999999999999999999999999 --
assert_eq "$RC" "2" "an over-intmax threshold → exit 2 (the comparison cannot run)"
assert_contains "$OUT" "queue threshold OUT OF RANGE" "an over-intmax threshold names the range failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an over-intmax threshold advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an over-intmax threshold sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an over-intmax threshold relabelled no runner"

run_gate q-huge GH_QUEUED=99999999999999999999999999 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an over-intmax queue count → exit 2 (the other operand)"
assert_contains "$OUT" "queued count OUT OF RANGE" "an over-intmax queue count names the range failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an over-intmax queue count relabelled no runner"

# ⛔ `[:space:]` alone admitted a pool read containing NO number at all (review B2-1): the `awk`
# reduction summed nothing to 0, the mode resolved `github`, and the run exited 0 with a recorded
# transition — a verdict from a read with no value in it.
echo "── #1704(5): a pool read containing no count must FAIL CLOSED ──"
run_gate pages-blank GH_FALLBACK_N=' ' -- --status
assert_eq "$RC" "2" "a whitespace-only pool read → exit 2 (--status never guesses a mode)"
assert_contains "$OUT" "NO COUNT" "a count-free pool read names the read failure"

# ⛔ The status summary's TWO fields are what `evaluate` actually branches on (review B1). The inline
# python prints them space-separated, so a `null`/empty component status became `comp="None"` /
# `comp="0"` — past the shape check and read as "not operational", i.e. UNHEALTHY, i.e. the gate
# RELABELLED the pool on a status it never read. And `incident` was never shape-checked at all:
# `${incident:-0}` read an EMPTY count as "0 incidents" — a fail-open to HEALTHY while an Actions
# incident was live.
echo "── #1704(4): an unreadable status-summary field must FAIL CLOSED ──"
run_gate comp-null CURL_BODY='{"components":[{"name":"Actions","status":null}],"incidents":[]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an Actions status of null → exit 2 (never 'not operational')"
assert_contains "$OUT" "actions component UNREADABLE" "a null Actions status names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a null Actions status advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a null Actions status sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a null Actions status relabelled no runner"

run_gate comp-empty CURL_BODY='{"components":[{"name":"Actions","status":""}],"incidents":[]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an EMPTY Actions status → exit 2 (the leading-space case the old check missed)"
assert_contains "$OUT" "actions component UNREADABLE" "an empty Actions status names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an empty Actions status relabelled no runner"

# The summary's SECOND field must reduce to a bare count. `${incident:-0}` read an empty or
# unreadable count as "0 incidents" — a fail-open to HEALTHY with an Actions incident live — and
# then took the pool OFF `ubuntu-latest` exactly when GitHub-hosted was degraded. Here the status
# itself is allow-listed, so the incident guard is the one that has to catch it.
run_gate incident-junk CURL_BODY='{"components":[{"name":"Actions","status":"operational x"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an unreadable incident count → exit 2 (never '0 incidents')"
assert_contains "$OUT" "incident count UNREADABLE" "an unreadable incident count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unreadable incident count advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an unreadable incident count sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unreadable incident count relabelled no runner"

# A status the summary cannot be consumed from at all (a newline truncates the line) is refused by
# the summary SHAPE check, before either field is trusted — the stricter counterpart of the guard
# above, and the case the pre-fix `[:space:]` admitted.
run_gate status-newline CURL_BODY='{"components":[{"name":"Actions","status":"operational\n"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "a status carrying a newline → exit 2 (the summary is not consumable)"
assert_contains "$OUT" "status summary unreadable" "an unconsumable summary names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unconsumable summary advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "an unconsumable summary sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unconsumable summary relabelled no runner"

# The negative control: a real Actions incident still routes to the local pool.
run_gate incident-real CURL_BODY='{"components":[{"name":"Actions","status":"operational"}],"incidents":[{"name":"Actions incident"}]}' \
  GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a live Actions incident still exits 0 (the fix is not 'always fail')"
assert_contains "$OUT" "TRANSITION unknown -> local" "a live Actions incident routes CI to the local pool"

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

# ⛔ A PARTIAL relabel must be RETRIED, not silently recorded (review B2-3). Run 1 fails one PUT, so
# it exits 2 without advancing state — correct. But one runner now carries the label, so the next
# pass reads `mode == want` and, before the fix, skipped the relabel entirely and recorded the
# transition: the runner whose PUT failed was never retried and never mentioned. The re-converge
# condition (`prev != want`) makes pass 2 re-apply the idempotent labels before recording.
echo "── #1704(6): a PARTIAL relabel is retried until the transition is recorded ──"
run_gate partial GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=0 GH_POOL_IDS="101 102" GH_PUT_FAIL_ID=101 \
  CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a partial relabel → exit 2 (not recorded as done)"
assert_contains "$OUT" "set_labels ok=1 fail=1" "a partial relabel counts the failure"
assert_contains "$OUT" "relabel FAILED" "a partial relabel names the failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a partial relabel advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a partial relabel sent no transition notification"

# pass 2: the pool now reads `local` (one labelled runner), so `mode == want` — the re-converge path.
KEEP_STATE=1
run_gate partial GH_MODE=ok GH_QUEUED=5 GH_FALLBACK_N=1 GH_POOL_IDS="101 102" \
  CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "the retry pass exits 0"
assert_contains "$OUT" "set_labels ok=2 fail=0" "the retry pass re-applies the labels to the WHOLE pool"
assert_contains "$OUT" "TRANSITION unknown -> local" "the retry pass records the transition once it converged"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "the retry pass records mode=local"

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
#
# ⛔ Both assertions read the STRUCTURAL element, not the whole file (review E2-1/E2-2). A
# whole-file `grep -F` for the basename is satisfied by this PR's own explanatory COMMENT in
# setup.sh, and a whole-file grep for the template path is satisfied by the template's own comment —
# so deleting the farm entry, or retargeting ProgramArguments, left both GREEN while the gate was
# once again wired to nothing. Both were reproduced by mutation.
TEMPLATE="$REPO_ROOT/templates/launchd/com.tortoise.ci-runner-gate.plist"
if [ ! -f "$TEMPLATE" ]; then
  bad "no templates/launchd/com.tortoise.ci-runner-gate.plist — the gate is wired to nothing (#1719)"
elif ! command -v python3 >/dev/null 2>&1; then
  # FAIL, never skip: the assertions below PARSE with python3, so without it they cannot run at all —
  # a skip would be a false PASS on the only assertions that catch "wired to nothing".
  # ⛔ Do NOT justify this with "python3 is a hard requirement of install-launchd.sh": it is not
  # (that installer falls back to PlistBuddy, `plist_program_args`), and stating it as fact hid a real
  # hole in that fallback (filed as its own issue). The gate SCRIPT does require python3 at runtime
  # (`need gh; need curl; need python3`), which is the true and sufficient reason.
  bad "python3 absent — the launchd template was NOT parsed (wiring assertions did not run)"
else
  ok "launchd template exists for the runner gate (#1719)"
  # ⛔ Parse the plist and read KEYS+VALUES; never grep it (reviews E2-1/E2-2, E3-3). A whole-file
  # grep is satisfied by this PR's own explanatory COMMENTS, and a `sed` RANGE keyed on a
  # content-derived start token is satisfied by a comment naming that token — both left this GREEN
  # while the gate was wired to nothing, and renaming `<key>HOME</key>` to `<key>HOMEDIR</key>` left
  # the old value-only grep green too. All three were reproduced by mutation.
  GATE_PLIST="$(python3 - "$TEMPLATE" <<'PY'
import json, plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print("ARGS=" + json.dumps(d.get("ProgramArguments", []), separators=(",", ":")))
print("ENVKEYS=" + json.dumps(sorted(d.get("EnvironmentVariables", {})), separators=(",", ":")))
for k, v in sorted(d.get("EnvironmentVariables", {}).items()):
    print("ENV=%s=%s" % (k, v))
PY
)" || GATE_PLIST=""
  GATE_ARGS="$(printf '%s\n' "$GATE_PLIST" | sed -n 's/^ARGS=//p')"
  # ⛔ EQUALITY on the whole argument list, and JSON so the encoding is INJECTIVE (review B4-1/E4-2,
  # hardened after B5-1). A `|`-joined line is not: an element CONTAINING `|` or a newline could
  # forge the expected string, and a single-element list could join to exactly two elements' worth of
  # text — each left the suite GREEN on a job wired to nothing. `json.dumps` escapes both, so the
  # COUNT and every element are pinned and no element's content can re-encode into the comparison.
  # The old containment form was weaker still: a SUFFIX-renamed target (`…ci_runner_gate.sh.old`)
  # contains the needle, and `/bin/echo` for the interpreter left the path untouched — both passed.
  WANT_ARGS="[\"/bin/bash\",\"{{HOME}}/.pi/agent/scripts/$(basename "$GATE")\"]"
  assert_eq "$GATE_ARGS" "$WANT_ARGS" \
    "ProgramArguments IS exactly [/bin/bash, the farmed path] — retargeted interpreter, renamed path, extra element and forged delimiter all fail"
  assert_eq "$(printf '%s\n' "$GATE_PLIST" | sed -n 's/^ENVKEYS=//p')" '["HOME","PATH"]' \
    "EnvironmentVariables is exactly {HOME, PATH} — an ADDED key is as wrong as a renamed one"
  assert_contains "$GATE_PLIST" "ENV=HOME={{HOME}}" \
    "EnvironmentVariables.HOME pins HOME for the job (the KEY, not just the value)"
  assert_contains "$GATE_PLIST" "ENV=PATH={{PATH}}" \
    "EnvironmentVariables.PATH takes the installer's shim-filtered renderer output (parsed plist)"
fi
SETUP="$REPO_ROOT/pi-bootstrap/setup.sh"
# The farm LINE, not the file: `fleet_srcs=(…)` is the declaration that delivers the script. Match the
# entry as a WHOLE WORD (review B4-1): a plain `grep -F` for the basename is also satisfied by
# `ci_runner_gate.sh.old`, i.e. by the exact rename that leaves the farm delivering a file the plist
# does not execute. `tr` splits the array on whitespace, `grep -x` requires the whole entry.
FARM_LINE="$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$SETUP")"
FARM_ENTRY="$(printf '%s\n' "$FARM_LINE" | tr -s ' ' '\n' | grep -x -- "$(basename "$GATE")" || true)"
assert_eq "$FARM_ENTRY" "$(basename "$GATE")" \
  "the fleet_srcs ARRAY carries the gate as a whole entry (exact membership, not a substring)"

# ⛔ HERMETICITY: the whole suite must never reach the real cmux / the live orchestrator lane
# (review E1). Every run above sets CI_GATE_ORCH_WS="", and the gate reads it with `${VAR-…}` so an
# empty value disables the leg. CMUX_LOG was truncated ONCE (before the first run) and never since,
# so this count covers every notifying run in the suite — a revert to `${VAR:-…}` re-enables the
# default lane for each of them and this assertion goes red. The stub is the belt to this braces:
# even on a revert, the real binary is unreachable.
echo "── hermeticity: the suite never touched the cmux / orchestrator lane ──"
assert_eq "$(wc -l < "$CMUX_LOG" | tr -d ' ')" "0" "no run invoked cmux (CI_GATE_ORCH_WS='' disables the leg)"

# Positive control — without it the assertion above could pass because the stub is broken or the
# leg never fires at all. With a lane configured the message MUST go out exactly once.
echo "── control: the cmux leg DOES fire when it is not disabled (the stub is live) ──"
run_gate cmux-enabled GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_ORCH_WS="TEST-LANE-UUID" --
assert_eq "$RC" "0" "a run with a configured lane exits 0"
assert_eq "$(wc -l < "$CMUX_LOG" | tr -d ' ')" "1" "exactly one cmux message is sent when the leg is enabled"
assert_contains "$(cat "$CMUX_LOG")" "TEST-LANE-UUID" "the cmux message names the configured lane"

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ ci_runner_gate suite: $FAIL failure(s), $PASS passed"
  exit 1
fi
echo "✅ ci_runner_gate suite: all $PASS assertions passed"
exit 0
