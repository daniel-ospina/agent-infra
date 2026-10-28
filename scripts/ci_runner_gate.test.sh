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
#   GH_QUEUE_OLDEST_AGE  how many seconds ago the oldest QUEUED run was created (default 30 — a
#                  queue that is about to be served). The stub renders it to a timestamp AT CALL
#                  TIME, because the gate computes a real age from it and a fixture written once
#                  would age out of (or into) the threshold as the suite runs. GH_QUEUE_OLDEST_AT
#                  overrides it with a literal timestamp, which is how the unparseable case is built.
#   GH_INPROGRESS  the in_progress count the absorption leg reads (default 2 — a repo being served)
#   GH_MODE        queued-null | queued-empty | inprog-null | inprog-fail | oldest-junk |
#                  enum-fail | enum-garbage | enum-badtab | ok
#   GH_FALLBACK_N  per-page count of fallback-labelled runners (current_mode → github|local)
#   GH_POOL_IDS    the ids the enumeration returns (default ARM64 pool members, see below)
#   GH_RUNNER_ROWS_FILE  a file of `<id>TAB<label>` rows — the REAL enumeration shape, used by the
#                  #2327 mixed-arch fixtures. When unset, each id in GH_POOL_IDS is emitted with
#                  the live ARM64 pool's label set, so every pre-#2327 case keeps its meaning.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
# ⛔ A WRAPPER'S DIAGNOSTIC ON STDERR, WHILE THE CALL SUCCEEDS — the measured shape (this box runs a
# `gh` wrapper that prints `gh-gate: the gate mutex is unavailable … running this call UNGATED
# (announced)`). A gate that captures `2>&1` reads that sentence as a COUNT (or as a census row), so
# the pass reports `mode=unknown` or raises a false BLIND alarm on a perfectly readable inventory.
if [ -n "${GH_NOISE:-}" ]; then
  printf 'gh-gate: the gate mutex is unavailable (lock_acquire spent 2000ms) — running this call UNGATED (announced)\n' >&2
fi
# The age fixture is rendered HERE, at call time: the gate turns it into a real age, so a timestamp
# minted when the suite starts would drift across (or into) the threshold while the suite runs.
queue_oldest_at() {
  if [ -n "${GH_QUEUE_OLDEST_AT:-}" ]; then printf '%s' "$GH_QUEUE_OLDEST_AT"; return; fi
  python3 -c '
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "${GH_QUEUE_OLDEST_AGE:-30}"
}
# ⛔ CONSUME `--input -` (the label PUT body), because the REAL gh does. The gate calls
# `printf '%s' "$body" | gh api -X PUT … --input -` under `set -o pipefail`, so a double that
# exits without reading stdin lets the writer take SIGPIPE the moment this process wins the race
# (measured: rc=141, `set_labels ok=1 fail=1`, a "relabel FAILED" from a PUT that never happened).
# Whether it fires depends on scheduling, so the suite was INTERMITTENTLY red — 3 of 10 local
# runs, on legs as unrelated as the healthy control and the cmux leg. Draining the pipe removes
# the race; it does not weaken an assertion, and a stalled writer still fails as it did before.
#
# The drained body is RECORDED, keyed by runner id: `PUT <id> BODY <json>` in GH_LOG. That is the
# artifact #2327 needs — "which labels did the API receive for WHICH runner" — and it is what the
# per-arch assertions read. A pool-wide stamp cannot satisfy them, which is the point.
if [[ "$*" == *"--input -"* ]]; then
  put_body="$(cat)"
  put_id=""
  for a in "$@"; do
    case "$a" in */runners/*/labels) put_id="${a#*/runners/}"; put_id="${put_id%%/*}" ;; esac
  done
  printf 'PUT %s BODY %s\n' "${put_id:-?}" "$put_body" >> "$GH_LOG"
fi
case "$*" in
  # ── `/actions/runs/{id}/jobs` serves TWO callers, told apart by the jq they ask for ────────
  #   demand (queue_demand)           → the `labels` of the queued jobs
  #   mode inference (mode_from_jobs) → `runner_group_name` of the executing jobs
  *"/jobs"*)
    case "$*" in
      *runner_group_name*)
        case "${GH_JOBS_MODE:-hosted}" in
          fail)   printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
          *)      printf '%s\n' "${GH_RUNNER_GROUP-GitHub Actions}" ;;
        esac
        exit 0 ;;
    esac
    case "${GH_DEMAND_MODE:-ok}" in
      fail) printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      none) exit 0 ;;
      *)    printf '%s\n' "${GH_DEMAND-ubuntu-latest}" ;;
    esac
    exit 0 ;;
  # The in-progress run ids the mode substitute inspects (a DIFFERENT read from the count above, and
  # deliberately not shaped as one: `per_page=20` with no status filter).
  *"per_page=20"*)
    case "${GH_JOBS_MODE:-hosted}" in
      fail|none) : ;;
      *)         printf '%s\n' "${GH_INFER_RUN_IDS:-5001}" ;;
    esac
    exit 0 ;;
  # ── THE CAPACITY CENSUS (agent-infra#2904 · #2897 · #2931) ──────────────────
  # The SAME endpoint as `current_mode`, a DIFFERENT jq — it asks for per-runner `status`/`busy`
  # rather than a count, so it is routed separately. `GH_CENSUS` is a comma list of runner tokens:
  #   idle / busy / off = a runner of the live pool (ARM64, carries ubuntu-latest)
  #   any other TOKEN   = emitted verbatim, which is how a malformed row is built
  # `GH_CENSUS_LABELS` replaces the label set, which is how "the pool does not carry the demand" is
  # built — the state that is CORRECT in mode=github and conclusive only in mode=local.
  # `GH_CENSUS_LABELCOUNT` emits the inventory's OPTIONAL 4th field (the runner's own label count),
  # which is the only way to build "a label contains the comma this pass splits on".
  *".status"*)
    case "${GH_CENSUS_MODE:-ok}" in
      forbidden)      printf '{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/actions/self-hosted-runners#list-self-hosted-runners-for-a-repository","status":"403"}\ngh: Resource not accessible by personal access token (HTTP 403)\n' >&2; exit 1 ;;
      forbidden-bare) printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' >&2; exit 1 ;;
      garbage)        printf 'null\n' ;;
      empty)          : ;;
      *)              _census="${GH_CENSUS:-busy}"; _census="${_census//,/ }"
                      _lc=""; [ -n "${GH_CENSUS_LABELCOUNT:-}" ] && _lc=$'\t'"$GH_CENSUS_LABELCOUNT"
                      for _c in $_census; do
                        case "$_c" in
                          idle) printf 'online\tfalse\t%s%s\n' "${GH_CENSUS_LABELS-self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest}" "$_lc" ;;
                          busy) printf 'online\ttrue\t%s%s\n'  "${GH_CENSUS_LABELS-self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest}" "$_lc" ;;
                          off)  printf 'offline\tfalse\t%s%s\n' "${GH_CENSUS_LABELS-self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest}" "$_lc" ;;
                          *)    printf '%s\n' "$_c" ;;
                        esac
                      done ;;
    esac
    exit 0 ;;
  *"-X PUT"*)
    # GH_PUT_FAIL_ID lets a case fail ONE runner's PUT, which is how a PARTIAL relabel is built.
    case "$*" in *"/runners/${GH_PUT_FAIL_ID:-none}/labels"*) exit 1 ;; esac
    exit 0 ;;
  # ⛔ THE TWO READS OF THE #2904 THROUGHPUT LEG ARE DISTINGUISHED BY URL, not by the jq flag:
  # the queue read carries `[.total_count, oldest created_at]` and the absorption read carries a
  # bare `.total_count`, and a double keyed on the FLAG would answer both with one shape.
  *"status=in_progress"*)
    case "${GH_MODE:-ok}" in
      inprog-fail) printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      inprog-null) printf 'null\n' ;;
      *)           printf '%s\n' "${GH_INPROGRESS:-2}" ;;
    esac
    exit 0 ;;
  *"status=queued"*)
    # The stub speaks the REAL jq shape: `<count> TAB <oldest created_at> TAB <oldest run id>`
    # (`@tsv`), with empty trailing fields when nothing is queued. The head run id is the third field
    # because the DEMAND read (`/actions/runs/{id}/jobs`, `actions:read`) hangs off it — agent-infra#2931.
    case "${GH_MODE:-ok}" in
      queued-null)  printf 'null\t\n' ;;
      queued-empty) printf '\n' ;;
      oldest-junk)  printf '%s\tWed Oct 27 13:00:00 2026\t%s\n' "${GH_QUEUED:-5}" "${GH_HEAD_RUN_ID-4001}" ;;
      *)
        if [ "${GH_QUEUED:-5}" = 0 ]; then
          printf '0\t\n'
        else
          printf '%s\t%s\t%s\n' "${GH_QUEUED:-5}" "$(queue_oldest_at)" "${GH_HEAD_RUN_ID-4001}"
        fi ;;
    esac
    exit 0 ;;
  *"--paginate"*)
    # current_mode asks for a COUNT (a --jq expression with `select(`); runner_rows asks for the
    # `<id>TAB<label>` pairs. Anything else is the pre-#2327 ids-only read.
    if [[ "$*" == *"select("* ]]; then
      printf '%s\n' "${GH_FALLBACK_N:-0}"
      exit 0
    fi
    case "${GH_MODE:-ok}" in
      enum-fail)    printf 'HTTP 500: upstream error\n' >&2; exit 1 ;;
      enum-garbage) printf 'null\n' ;;
      # a row with NO TAB: the id is then the whole line, so it cannot be read as `<id>TAB<label>`
      enum-badtab)  printf '101 self-hosted\n' ;;
      # `-` not `:-`: the empty-pool case below sets GH_POOL_IDS to the EMPTY string on purpose,
      # and `:-` would swallow that into the default, making the case vacuous.
      *)
        if [ -n "${GH_RUNNER_ROWS_FILE:-}" ]; then
          cat "$GH_RUNNER_ROWS_FILE"
        else
          for _id in ${GH_POOL_IDS-101 102}; do
            for _l in self-hosted Linux ARM64 self-hosted-arm64 ubuntu-latest; do
              printf '%s\t%s\n' "$_id" "$_l"
            done
          done
        fi ;;
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
# The gate under test is `$GATE` unless a case overrides it (the #2327 mutation runs a generated
# mutant). Seeded here, empty, so the name is ASSIGNED before it is ever used: a `bash "${VAR:-$GATE}"`
# whose variable is painted on for the first time further down reads to a static analyzer (the
# worktree guard's script-indirection arm) as an unresolvable script path, and it refuses to run
# this suite at all. Same idiom as scripts/disk-reaper.test.sh (`VENV_REAPER="${VENV_REAPER:-}"`).
GATE_UNDER_TEST="${GATE_UNDER_TEST:-}"
# ⛔ THE CALLER'S OVERRIDE IS REMEMBERED AND RESTORED, NOT CLEARED (#3002 review P2). The mutation
# blocks below reset the override to "" when they are done, and those resets sit BEFORE the
# capacity section — so passing a PRE-FIX gate to this suite quietly stopped applying at the
# first reset and every later arm ran the SHIPPED gate. Measured before this fix:
#   GATE_UNDER_TEST=/tmp/nonexistent -> 69 failures, 205 passed (the lever was dead past ~line 596)
# A before/after over the whole tree was therefore impossible to reproduce, which is exactly the
# evidence a "this arm is load-bearing" claim rests on. Restoring the caller's value makes the
# lever work end to end; for a normal run the value is empty, so nothing else changes.
GATE_UNDER_TEST_ORIG="$GATE_UNDER_TEST"
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
    bash "${GATE_UNDER_TEST:-$GATE}" "$@"
  ) > "$T/out-$name" 2>&1
  RC=$?
  OUT="$(cat "$T/out-$name")"
}

# put_body_for <id> — the label body the API actually received for THAT runner in the last run.
# The artifact, not the gate's own account of itself: a pool-wide stamp cannot produce two
# different bodies, so these assertions cannot be satisfied by one.
put_body_for() { sed -n "s|^PUT $1 BODY ||p" "$GH_LOG" | tail -1; }

# matches <label-set> <required label>… — the scheduler's rule, in miniature: a runner takes a job
# only when its label set is a SUPERSET of everything the job asks for. Used to prove that an
# arch-specific `runs-on:` still resolves to the right architecture after the gate acts.
matches() {
  local have=" $1 "; shift; local need
  for need in "$@"; do
    case "$have" in *" $need "*) ;; *) return 1 ;; esac
  done
  return 0
}

# json_labels '<{"labels":["a","b"]}>' — the body's labels as a space-padded set for `matches`.
json_labels() { printf ' %s ' "$(printf '%s' "$1" | sed -e 's/.*\[//' -e 's/\]}//' -e 's/","/ /g' -e 's/"//g')"; }

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

# ⛔ agent-infra#2904 — THE THROUGHPUT (ABSORPTION) LEG. The measured defect: a run sat QUEUED for 3 h
# while the component was operational, there was no Actions incident, and the queue was under the
# length threshold — so every leg the gate had read HEALTHY while nothing could take the work. The
# leg is a CONJUNCTION (work queued + queue head past the stuck-after floor + NOTHING executing) and
# these arms pin all three halves, plus the measured false-positive guard that motivated the conjunction:
# on 2026-10-27 the live repo held a queue HEAD 3,943-12,583 s old while hosted was serving 2..14 runs, so
# an age-only leg would have fired continuously on a healthy repo.
echo "── #2904: a STALLED queue (healthy component, nothing executing) takes the fallback path ──"
run_gate stall GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a stalled queue with a healthy component still exits 0 (it ACTS, it does not fail)"
assert_contains "$OUT" "oldest_queued_s=36" "the probe reports the queue-wait age in SECONDS"
assert_contains "$OUT" "in_progress=0" "the probe reports the absorption field it branched on"
assert_contains "$OUT" "queue_stuck_after_s=1800" "the probe reports the floor it compared against"
assert_contains "$OUT" "not absorbing" "the run NAMES the leg that failed, not just that something did"
assert_contains "$OUT" "TRANSITION unknown -> local" "a stalled queue engages the script's OWN fallback path"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a stalled queue records mode=local"
assert_contains "$(cat "$GH_LOG")" "-X PUT" "a stalled queue actually relabels the pool onto ubuntu-latest"

# The measured FALSE-POSITIVE GUARD, and the reason the leg is not an age test: 54 queued with a queue
# head 12,583 s (3 h 29 m) old is what the live repo looked like while 13 runs were executing. Hosted was
# absorbing; the gate must stay on github.
echo "── #2904: a DEEP BUT SERVING queue (old head, runs executing) leaves mode=github ──"
run_gate serving GH_QUEUED=54 GH_INPROGRESS=13 GH_QUEUE_OLDEST_AGE=12400 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a deep but serving queue exits 0"
assert_contains "$OUT" "in_progress=13" "the probe reports the runs that ARE executing"
assert_not_contains "$OUT" "not absorbing" "a deep but serving queue is NOT read as a stall"
assert_contains "$OUT" "TRANSITION unknown -> github" "a deep but serving queue keeps the gate on GitHub-hosted"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "a deep but serving queue records mode=github"

# …and the age floor is load-bearing for the OTHER direction: a push creates runs a few seconds before
# the scheduler dispatches them, so `in_progress == 0` on its own is a normal transient, not a stall.
echo "── #2904: a queue younger than the floor (nothing executing yet) is NOT a stall ──"
run_gate young GH_QUEUED=5 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=30 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a young queue with nothing executing yet exits 0"
assert_contains "$OUT" "oldest_queued_s=3" "the young queue's age is a real measurement, in seconds"
assert_not_contains "$OUT" "not absorbing" "a young queue is not a stall (the age floor is load-bearing)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "a young queue records mode=github"

# The negative control for the whole leg: an EMPTY queue with nothing executing is a readable state
# (the repo is idle), not a stall and not a failed read. Conflating "no queue" with "stalled queue"
# would route CI to the pool on an idle repo.
echo "── #2904: an EMPTY queue with nothing executing is a readable zero, not a stall ──"
run_gate idle GH_QUEUED=0 GH_INPROGRESS=0 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "an idle repo exits 0"
assert_contains "$OUT" "queued=0" "an idle repo reports the zero it read"
assert_not_contains "$OUT" "UNREADABLE" "an empty queue is a readable zero, not an unreadable one"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "an idle repo records mode=github"

# ⛔ A LEG THAT ERRORS is neither healthy NOR unhealthy-but-act (#2904): every unreadable input below
# must exit 2, leave the mode alone, notify nothing and relabel nothing.
echo "── #2904: an unreadable absorption read must FAIL CLOSED (no action either way) ──"
run_gate stalled-inprog-fail GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  GH_MODE=inprog-fail --
assert_eq "$RC" "2" "a failed in-progress read → exit 2 (could-not-measure)"
assert_contains "$OUT" "in-progress probe FAILED" "the failure NAMES the read that failed"
assert_contains "$OUT" "HTTP 500" "the failure carries gh's reason (not swallowed)"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a failed in-progress read advanced no state file"
assert_not_contains "$OUT" "TRANSITION" "a failed in-progress read sent no transition notification"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a failed in-progress read relabelled no runner"

run_gate inprog-null GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  GH_MODE=inprog-null --
assert_eq "$RC" "2" "a null in-progress count → exit 2 (never 'nothing executing')"
assert_contains "$OUT" "in_progress count UNREADABLE" "a null in-progress count names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a null in-progress count advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a null in-progress count relabelled no runner"

# A queue head whose timestamp cannot be parsed (a schema change, a truncated body) is a FAILED read of
# the queue, never "a young queue": reading it as young would silently disarm the leg.
run_gate oldest-junk GH_MODE=oldest-junk GH_QUEUED=18 GH_INPROGRESS=0 GH_FALLBACK_N=0 --
assert_eq "$RC" "2" "an unparseable queue-head timestamp → exit 2 (never 'young queue')"
assert_contains "$OUT" "oldest queued timestamp UNREADABLE" "an unparseable queue head names the read failure"
assert_absent "$STATE_DIR/ci-runner-gate.state" "an unparseable queue head advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unparseable queue head relabelled no runner"

# The stuck-after floor is the other operand of the same numeric test, so it gets the same guard the
# queue threshold got in #1704 — a non-numeric floor would error the comparison, which reads as
# HEALTHY.
run_gate stall-junk-threshold GH_QUEUED=18 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=3600 GH_FALLBACK_N=0 \
  CI_GATE_QUEUE_STUCK_AFTER_S=abc --
assert_eq "$RC" "2" "an unreadable queue stuck-after floor → exit 2 (the comparison cannot run)"
assert_contains "$OUT" "queue stuck-after floor UNREADABLE" "an unreadable queue stuck-after floor names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "an unreadable queue stuck-after floor relabelled no runner"

# ⛔ review P2 — A QUEUE DEEPER THAN THE READ PAGE IS UNMEASURABLE, NOT HEALTHY. The page is
# newest-first, so its `min(created_at)` is only a LOWER BOUND on the head's age; the length leg
# normally decides first (a queue past QUEUE_THRESHOLD returns unhealthy before the age matters),
# but an operator who RAISES the threshold above the page size left the leg deciding on a lower
# bound and certifying a 150-deep stalled queue as healthy. Could-not-measure (2) is this script's
# answer for every other unread operand, so it is the answer here, and it names both values.
echo "── #2904 (P2): a queue deeper than the read page refuses the pass, it does not read healthy ──"
run_gate page-saturated GH_QUEUED=150 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=60 GH_FALLBACK_N=0 \
  CI_GATE_QUEUE_THRESHOLD=200 --
assert_eq "$RC" "2" "a queue deeper than the page (threshold above the page size) → exit 2"
assert_contains "$OUT" "DEEPER than the read page" "the refusal NAMES the saturation, not just a count"
assert_contains "$OUT" "lower bound" "the refusal says WHY the head age is unusable"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a saturated queue read advanced no state file"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a saturated queue read relabelled no runner"
# …and the saturation is NOT a new way to red the normal path: with the SHIPPED threshold the length
# leg decides a 150-deep queue first (unhealthy -> fallback), which is the state it always was.
run_gate page-saturated-shipped GH_QUEUED=150 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=60 GH_FALLBACK_N=0 --
assert_eq "$RC" "0" "a 150-deep queue at the shipped threshold still ACTS (rc 0), it does not fail"
assert_contains "$OUT" "queue/component/incident leg" "the LENGTH leg is the one that decides it"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a 150-deep queue engages the pool"

# ⛔ review P1 — THE ABSORPTION FIGURES ARE NOT A HOSTED READING WHILE THE POOL IS ENGAGED. In
# fallback mode the pool the gate itself engaged is what holds `in_progress` above zero, so counting
# it as "hosted is absorbing" is a claim the script cannot support. The DENY direction still holds
# in both modes (`in_progress == 0` with a stuck head ⇒ stay on the pool); only the CERTIFY wording
# is suppressed. The strip back to `github` on the drained queue below is the PRE-EXISTING
# drain-then-restore cycle (#2327: the pool serves only while hosted is unhealthy, and health is
# re-tested every tick by the legs that existed before this one) — it is pinned here so nobody
# reads it as this leg's verdict.
echo "── #2904 (P1): while the pool is engaged, the reason never claims hosted is absorbing ──"
run_gate fallback-attribution GH_QUEUED=16 GH_INPROGRESS=2 GH_QUEUE_OLDEST_AGE=4000 GH_FALLBACK_N=2 --
assert_eq "$RC" "0" "a drained queue with the pool serving exits 0"
assert_contains "$OUT" "absorption NOT attributable in mode=local" "the reason says the reading cannot be attributed to hosted"
assert_contains "$OUT" "in_progress=2" "the reason still QUOTES the figures it read"
assert_not_contains "$OUT" "queue absorbing" "the reason never claims hosted absorption while the pool is executing"
# The deny direction is unchanged in fallback mode: pool engaged, nothing executing, stuck head ⇒ stay.
run_gate fallback-deny GH_QUEUED=16 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=4000 GH_FALLBACK_N=2 --
assert_eq "$RC" "0" "a stuck queue with nothing executing exits 0 in fallback mode too"
assert_contains "$OUT" "not absorbing" "and it is still named as not absorbing (the deny holds in both modes)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "a stuck queue with nothing executing keeps the pool engaged"

# ⛔ MUTATION: each half of the conjunction must be load-bearing. Weakening the leg to EITHER half
# alone must redden an arm above — otherwise the arms would pass for a leg that is one of the two
# signals it is supposed to combine, and the measured false positive (age alone) or the measured
# transient (in_progress alone) would come back with a green suite.
echo "── #2904: MUTATIONS — both halves of the leg are load-bearing ──"
MUT_ANCHOR='  if [ "$queued" -gt 0 ] && [ "$in_progress" -eq 0 ] && [ "$oldest_queued_s" -gt "$QUEUE_STUCK_AFTER_S" ]; then'
mutant_gate() { # <out> <replacement if-line>
  python3 - "$GATE" "$1" "$MUT_ANCHOR" "$2" <<'PY'
import sys
src, dst, anchor, repl = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if anchor not in text:
    sys.exit("mutation anchor not found — the throughput leg moved, so this mutation is stale")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, repl, 1))
PY
}

MUT1="$T/ci_runner_gate.mutant-ageonly.sh"
if mutant_gate "$MUT1" '  if [ "$oldest_queued_s" -gt "$QUEUE_STUCK_AFTER_S" ]; then'; then
  ok "(m1) the age-only mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT1"
  run_gate mutant-ageonly GH_QUEUED=54 GH_INPROGRESS=13 GH_QUEUE_OLDEST_AGE=12400 GH_FALLBACK_N=0 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m1) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m1) MUTATION SURVIVED: with the absorption conjunct gone, a SERVING queue still reads healthy — the 'deep but serving' arm is not load-bearing"
  else
    ok "(m1) mutation killed: a serving queue (in_progress=13) is now read as a stall and routed to the pool"
  fi
else
  bad "(m1) the mutant gate could not be generated (the mutation anchor moved) — the conjunction is unproven"
fi

MUT2="$T/ci_runner_gate.mutant-nofoor.sh"
if mutant_gate "$MUT2" '  if [ "$queued" -gt 0 ] && [ "$in_progress" -eq 0 ]; then'; then
  ok "(m2) the no-age-floor mutant was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT2"
  run_gate mutant-nofoor GH_QUEUED=5 GH_INPROGRESS=0 GH_QUEUE_OLDEST_AGE=5 GH_FALLBACK_N=0 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m2) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m2) MUTATION SURVIVED: with the age floor gone, a 5-second-old queue still reads healthy — the 'young queue' arm is not load-bearing"
  else
    ok "(m2) mutation killed: a queue that is 5 s old (a push ahead of its dispatch) is now read as a stall"
  fi
else
  bad "(m2) the mutant gate could not be generated (the mutation anchor moved) — the age floor is unproven"
fi

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

# The #2327 read is `<id>TAB<label>` rows, so a row WITHOUT a tab has no readable runner id: the
# split yields the whole line as the id and an EMPTY label. Without the row shape check that empty
# label would fall through the old `*[!0-9[:space:]]*` id check (the line starts with digits) and
# the runner would be relabelled from a field that was never read.
run_gate enum-badtab GH_MODE=enum-badtab GH_QUEUED=5 GH_FALLBACK_N=0 CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a row with no TAB → exit 2 (no readable runner id)"
assert_contains "$OUT" "runner enumeration unreadable" "a tabless row names the read failure"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "a tabless row relabels nothing"

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

echo "── #2327: a runner's labels describe THAT runner, not the pool it joined first ──"
# The live pool, read from `gh api repos/daniel-ospina/tortoise/actions/runners` on 2026-10-22:
#   30/31 pi-runner-vm-*   self-hosted,Linux,ARM64,self-hosted-arm64,ubuntu-latest   ← serving the queue
#   33/34 pi-runner-x64-*  self-hosted,Linux,X64,  self-hosted-x64,  ubuntu-latest   ← tonight's capacity
# `ARM64` / `X64` are HOST-derived by GitHub at registration: the only per-runner statement of arch
# this gate can branch on. The two ARM64 runners are the ones the queue is being served by, so a
# change to THEIR bodies is the regression these byte-comparisons exist to catch.
MIXED="$T/rows-mixed.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tARM64\n30\tself-hosted-arm64\n30\tubuntu-latest\n33\tself-hosted\n33\tLinux\n33\tX64\n33\tself-hosted-x64\n33\tubuntu-latest\n' > "$MIXED"

# want=local ⇒ the fallback label is added to every managed runner.
run_gate mixed-on GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "mixed pool: engaging the fallback exits 0"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
  "(b) the ARM64 runner's body is BYTE-IDENTICAL to today's fallback_on body"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(a) the x86_64 runner gets ITS OWN arch label, from its host label — not the pool's"
assert_not_contains "$(put_body_for 33)" "self-hosted-arm64" \
  "(a) and the ARM64 body is NOT stamped onto the x86 runner"
# The summary line no longer claims one body for the whole pool: it reports the engagement, and the
# per-runner bodies are logged individually — otherwise one `body=` could describe every runner.
assert_contains "$OUT" "set_labels ok=2 fail=0 engagement=on" "the summary reports the engagement, not a pool-wide body"
assert_contains "$OUT" "set_labels runner=33 body={\"labels\":[\"self-hosted-x64\",\"ubuntu-latest\"]}" \
  "the body written to EACH runner is in the log, attributable to that runner"

# want=github ⇒ the fallback label comes off; each runner KEEPS the marker for its own arch, so an
# x86 runner leaves the queue's view rather than silently leaving the pool.
run_gate mixed-off GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" --
assert_eq "$RC" "0" "mixed pool: disengaging the fallback exits 0"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64"]}' \
  "(b) the ARM64 runner's body is BYTE-IDENTICAL to today's fallback_off body"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64"]}' \
  "(a) the x86_64 runner KEEPS self-hosted-x64 when the fallback is disengaged"

# (c) An arch-specific job must still resolve to the right architecture. Model the scheduler's own
# rule (a runner takes a job only when its labels are a SUPERSET of `runs-on:`) over the label set
# each runner actually ends up with: the host labels it was registered with, plus the body the gate
# PUT (this endpoint REPLACES the custom set; host labels are not custom and cannot be removed).
ARM_SET=" self-hosted Linux ARM64 $(json_labels "$(put_body_for 30)")"
X64_SET=" self-hosted Linux X64 $(json_labels "$(put_body_for 33)")"
if matches "$ARM_SET" self-hosted self-hosted-arm64; then
  ok "(c) runs-on [self-hosted, self-hosted-arm64] MATCHES the ARM64 runner"
else
  bad "(c) runs-on [self-hosted, self-hosted-arm64] no longer matches the ARM64 runner — the queue's own pool is stranded"
fi
if matches "$X64_SET" self-hosted self-hosted-arm64; then
  bad "(c) runs-on [self-hosted, self-hosted-arm64] matches the x86 runner — ARM-only work would be routed to x86"
else
  ok "(c) runs-on [self-hosted, self-hosted-arm64] does NOT match the x86 runner"
fi
if matches "$X64_SET" self-hosted self-hosted-x64; then
  ok "(c) runs-on [self-hosted, self-hosted-x64] matches the x86 runner"
else
  bad "(c) runs-on [self-hosted, self-hosted-x64] does not match the x86 runner — x86-only work has no runner"
fi
if matches "$ARM_SET" self-hosted self-hosted-x64; then
  bad "(c) runs-on [self-hosted, self-hosted-x64] matches the ARM64 runner — x86-only work would be routed to ARM"
else
  ok "(c) runs-on [self-hosted, self-hosted-x64] does NOT match the ARM64 runner"
fi

# Two doors the derivation must keep shut, each a way the gate could still touch a runner it does
# not own or guess an architecture it cannot read.
#
# (i) A runner that is NOT in this pool (no marker) is not the gate's to relabel. Enumerating every
#     runner in the repo and putting a body to it was half of #2327; a stranger's labels must survive
#     a gate tick untouched.
STRANGER="$T/rows-stranger.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tARM64\n30\tself-hosted-arm64\n30\tubuntu-latest\n99\tself-hosted\n99\tLinux\n99\tX64\n99\tubuntu-latest\n' > "$STRANGER"
run_gate mixed-stranger GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STRANGER" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "a pool that contains a stranger still relabels cleanly (rc=0)"
assert_eq "$(put_body_for 99)" "" "a runner carrying no pool marker is NOT relabelled (it is not this gate's)"
assert_eq "$(put_body_for 30)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
  "…and the pool member in the same read IS relabelled (the selection is not just 'relabel nothing')"

# (ii) A managed runner whose own host label is unreadable cannot be classified, so it must be
#     REFUSED — counted as a failure, exit 2, no state advanced. Guessing the pool's arch here is
#     how an x86 box gets stamped ARM64 in the first place.
NOARCH="$T/rows-noarch.tsv"
printf '30\tself-hosted\n30\tLinux\n30\tself-hosted-arm64\n30\tubuntu-latest\n' > "$NOARCH"
run_gate mixed-noarch GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$NOARCH" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "2" "a managed runner with NO host arch label → exit 2 (could-not-classify)"
assert_contains "$OUT" "runner 30 is not classifiable from its own host label" \
  "the refusal NAMES the runner it could not classify"
assert_eq "$(put_body_for 30)" "" "and nothing was PUT to it"
assert_absent "$STATE_DIR/ci-runner-gate.state" "a partial classification advanced no state file"

# (iii) THE HEADLINE REPAIR, PINNED: a runner the LEGACY gate already stamped carries BOTH
# markers (self-hosted-arm64 from the old pool-wide body, self-hosted-x64 from its registration).
# The HOST label must decide, so the stamped marker is dropped and the runner heals. This is the
# state the live pool is one legacy tick away from (the farmed copy at ~/.pi/agent/scripts/ still
# has the pool-wide stamp), and a fixture without the CONFLICT — where the marker agrees with the
# host, or is absent — cannot tell host-precedence from marker-precedence: a mutant that lets the
# marker win survives it (measured: suite green 131/131 with that mutation, before this case).
STAMPED="$T/rows-stamped.tsv"
printf '33\tself-hosted\n33\tLinux\n33\tX64\n33\tself-hosted-arm64\n33\tubuntu-latest\n' > "$STAMPED"
run_gate mixed-stamped GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STAMPED" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "(iii) a runner carrying a conflicting ARM64 marker still relabels cleanly"
assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(iii) the HOST label wins: the stamped self-hosted-arm64 is dropped, self-hosted-x64 is restored"
assert_not_contains "$(put_body_for 33)" "self-hosted-arm64" \
  "(iii) and the false architecture claim is not re-written"

# …and the answer must not depend on the ORDER gh happens to list the labels in. A derivation that
# let the first or the last label win would pass one ordering and fail the other, so both are
# pinned: here the marker comes BEFORE the host label.
STAMPED_REV="$T/rows-stamped-rev.tsv"
printf '34\tself-hosted\n34\tLinux\n34\tself-hosted-arm64\n34\tX64\n34\tubuntu-latest\n' > "$STAMPED_REV"
run_gate mixed-stamped-rev GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$STAMPED_REV" CI_GATE_QUEUE_THRESHOLD=1 --
assert_eq "$RC" "0" "(iii) the same conflicts relabel cleanly with the marker listed FIRST"
assert_eq "$(put_body_for 34)" '{"labels":["self-hosted-x64","ubuntu-latest"]}' \
  "(iii) host-precedence is ORDER-INDEPENDENT: marker-first still derives self-hosted-x64"

# (d) MUTATION: restore the pool-wide stamp and (a) must FAIL. Without this the assertions above
# could be satisfied by a constant body that happens to be right for today's pool — the exact shape
# of the defect, which was harmless only while every runner really was ARM64.
echo "── #2327 (d): MUTATION — restoring the pool-wide stamp must make (a) fail ──"
MUT="$T/ci_runner_gate.mutant.sh"
if python3 - "$GATE" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
anchor = '  local rows="$1" id="$2" eng="$3" rid name arch="" extra="" out="" l json=""'
if anchor not in text:
    sys.exit("mutation anchor not found — the per-runner derivation moved, so this mutation is stale")
mutant = anchor + (
    '\n  # MUTANT::2327d - the pre-#2327 POOL-WIDE stamp: one body for every runner, no host read.\n'
    '  if [ "$eng" = on ]; then printf %s \'{"labels":["self-hosted-arm64","ubuntu-latest"]}\';\n'
    '  else printf %s \'{"labels":["self-hosted-arm64"]}\'; fi\n'
    '  return 0'
)
open(dst, "w", encoding="utf-8").write(text.replace(anchor, mutant, 1))
PY
then
  ok "(d) the mutant gate was generated from the SHIPPED gate (anchor present)"
  GATE_UNDER_TEST="$MUT"
  run_gate mutant-on GH_QUEUED=5 GH_FALLBACK_N=0 GH_RUNNER_ROWS_FILE="$MIXED" CI_GATE_QUEUE_THRESHOLD=1 --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(d) the mutant still RUNS (rc=0) — so the red below is the property, not a crash"
  if [ "$(put_body_for 33)" = '{"labels":["self-hosted-x64","ubuntu-latest"]}' ]; then
    bad "(d) MUTATION SURVIVED: with the pool-wide stamp back, (a) still passes — (a) is not load-bearing"
  else
    ok "(d) mutation killed: (a) FAILS on the mutant (runner 33 received $(put_body_for 33))"
  fi
  assert_eq "$(put_body_for 33)" '{"labels":["self-hosted-arm64","ubuntu-latest"]}' \
    "(d) and it fails EXACTLY as the defect did: the x86 runner is stamped ARM64 and loses its own marker"
else
  bad "(d) the mutant gate could not be generated (the mutation anchor moved) — (a) is unproven"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# THE CAPACITY INSTRUMENT — agent-infra#2904 · #2897 · #2931
#
# One defect, three faces: the instrument could not MEASURE, so the fleet read healthy while running
# at 2 of 8, and the shortage was rediscovered by hand every few hours.
#
#   #2904 — the gate certified hosted as healthy from component status + queue length, none of which
#           can observe ABSORPTION or CAPACITY. (The throughput leg that landed for it still cannot
#           see the pool: `in_progress` is a REPO count, not a per-runner one.)
#   #2897 — the gate probed an admin-only endpoint with a token that cannot have that scope, so it
#           never measured, never alarmed, and `launchctl` showed exit 2 for hours.
#   #2931 — with the inventory unreadable, the fallback could neither read nor write labels, so a
#           deep queue had no route onto the idle pool.
#
# What is pinned below, in the order the fleet needs it:
#   (1) the THREE STATES come from the API per runner — online-idle, online-busy, and
#       registered-but-OFFLINE (the read reports `status`, never "has it EVER been online"). A count of registrations cannot tell them apart, and conflating
#       them is how "9 online" was read while 7 were idle.
#   (2) IDLE WHILE WORK WAITS is never certified. The verdict says what it measured.
#   (3) AN UNREADABLE CAPACITY READ IS `UNKNOWN`, ALARMS, AND IS NOT A GUESS. The token is never
#       widened; the MODE question falls back to a readable substitute (jobs), the CAPACITY question
#       does not, and it says so.
#   (4) the pool being STRIPPED IN mode=github is CORRECT (#2327) and must never trip the deny — the
#       arm that keeps this fix from re-engaging the fallback on every healthy tick.
#
# The fixtures are the live measurements of 2026-10-28 12:42-12:57Z, not inventions:
#   daniel-ospina/agent-infra : 8 registrations, 2 online (both busy), 6 offline, 52-56 queued
#   daniel-ospina/tortoise    : 9 online, all busy, 73-78 queued; head job asked `ubuntu-latest`
#   daniel-ospina/agent-infra : census read → 200 HERE, 403 on the cell boxes (same script, other token)
echo "── #2904/#2897/#2931: the census reports the THREE STATES per runner (a count cannot) ──"
run_gate census-2of8 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
  GH_CENSUS="busy,busy,off,off,off,off,off,off" --
assert_eq "$RC" "0" "(1) a readable census with work queued and every ONLINE runner busy exits 0"
assert_contains "$OUT" "busy=2" "(1) online-busy is counted from the API's per-runner busy flag"
assert_contains "$OUT" "offline=6" "(1) registered-but-OFFLINE is its OWN state, not 'not busy' (and NOT 'never online' — the API reports status, not history)"
assert_contains "$OUT" "online_idle=0" "(1) online-idle is reported even when it is zero"
assert_contains "$OUT" "2 of 8 online" "(1) the human form says how much of the pool is actually up"
assert_contains "$OUT" "capacity=saturated" "(1) work waiting + every online runner busy is SATURATED (busy is real)"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(1) the mode file keeps its single-word shape"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "offline=6" \
  "(1) the verdict file carries the per-runner counts a fleet report can branch on"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "capacity=saturated" \
  "(1) and the current capacity verdict"

# ⛔ THE MEASURED MISREADING. 9 online, 7 of them IDLE, 54 queued. The pre-fix gate had no reading at
# all that could distinguish this from "9 busy" — so it certified the state that keeps the pool out of
# the queue while seven runners sat unused.
echo "── #2904: IDLE CAPACITY WHILE WORK WAITS is measured, named, and NEVER certified ──"
run_gate census-idle-unused GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" --
assert_eq "$RC" "0" "(2) idle capacity is a report, not an action — the pass still completes"
assert_contains "$OUT" "online_idle=7" "(2) the SEVEN IDLE runners are counted, per runner"
assert_contains "$OUT" "online_busy=2" "(2) …separately from the two that are busy"
assert_contains "$OUT" "capacity=idle-unused" "(2) the verdict names the state instead of hiding behind a count"
assert_contains "$OUT" "CAPACITY NOT CERTIFIED" "(2) the reason refuses to certify capacity"
assert_not_contains "$OUT" "GitHub Actions healthy" "(2) and never prints the word 'healthy' over it"

# ⛔ THE FALL-THROUGH RE-CREATED THE MISREADING (#3002 review P1). The arm above is mode=local with a
# READABLE demand; when the demand cannot be measured (a space-bearing label `queue_demand` rejects, or
# any mode=github tick) the verdict used to fall through to `saturated` whenever ANY runner was busy —
# so 7 IDLE runners and 2 busy ones printed `capacity=saturated … (idle=7 busy=2)` and, because
# `saturated` is a CERTIFYING word, the reason read "GitHub Actions healthy". Same census, same queue,
# demand unmeasurable: the pool's own state still decides, and it has idle capacity.
echo "── #3002 P1: an UNMEASURABLE demand must not turn 7 idle runners into 'saturated' ──"
run_gate census-mixed-demand-unknown GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_DEMAND_MODE=fail \
  GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" --
assert_eq "$RC" "0" "(2b) the pass completes (idle capacity is a report, not a deny)"
assert_contains "$OUT" "demand=unknown" "(2b) the demand really was unmeasured in this state"
assert_contains "$OUT" "online_idle=7" "(2b) seven online runners are idle"
assert_contains "$OUT" "capacity=idle-unused" "(2b) the verdict is idle-unused, NOT saturated"
assert_not_contains "$OUT" "capacity=saturated" "(2b) 'saturated' means EVERY online runner is busy — never this"
assert_contains "$OUT" "CAPACITY NOT CERTIFIED" "(2b) and the certifying branch is not entered"
assert_not_contains "$OUT" "GitHub Actions healthy" "(2b) the words 'healthy' never appear over idle capacity"

# The third state, and the ONLY place it is conclusive: in mode=local the pool is SUPPOSED to serve,
# so "not one online runner can accept the queue's demand" is a fault the gate can act on.
echo "── #2931: in mode=local, a pool that cannot accept the queue's demand is STRANDED (a deny) ──"
run_gate census-stranded GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64" --
assert_eq "$RC" "0" "(3) a stranded pool still completes the pass (it ACTS, it does not crash)"
assert_contains "$OUT" "demand=ubuntu-latest" "(3) the queue's OWN demand is read from the jobs endpoint (actions:read)"
assert_contains "$OUT" "demanding_idle=0" "(3) no idle runner carries the demanded label"
assert_contains "$OUT" "capacity=stranded" "(3) the verdict is stranded, not 'healthy'"
assert_contains "$OUT" "capacity leg" "(3) the leg that decided is NAMED, as every other leg here is"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "local" "(3) the pool stays engaged"

# ⛔ THE ANTI-FLAPPER (#2327's decision). In mode=github the pool is stripped ON PURPOSE, so "no online
# runner offers ubuntu-latest" is the CORRECT state. Denying on it would re-engage the fallback on
# every healthy tick and fight the recorded decision forever. Same census as above, opposite mode.
echo "── #2327 GUARD: a STRIPPED pool in mode=github is CORRECT, never stranded ──"
run_gate census-stripped-pool GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
  GH_CENSUS="off,off,off,off" --
assert_eq "$RC" "0" "(4) a stripped, dark pool in mode=github exits 0"
assert_contains "$OUT" "capacity=all-offline" "(4) the state is still REPORTED (registrations exist, none online)"
assert_not_contains "$OUT" "capacity leg" "(4) and it does NOT deny — that would fight the fallback-only decision"
assert_eq "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" "github" "(4) mode stays github"

# ── #2897: THE BLIND PASS ─────────────────────────────────────────────────────────────────────────
# The measured failure: `403 Resource not accessible by personal access token` from the launchd-run
# copy, every ~5 min, exiting 2 with ONE log line. The fail-closed exit was right; the SILENCE was the
# defect. An unreadable capacity read is now `UNKNOWN` — a verdict, with the missing capability named
# from the response body, an alarm that REPEATS, and no claim anywhere.
echo "── #2897: an unreadable capacity census is UNKNOWN + an ALARM, never a guess ──"
run_gate census-403 GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(5) a 403 on the census → exit 2 (could-not-measure), as before"
assert_contains "$OUT" "capacity=unknown" "(5) the verdict is UNKNOWN — the word the gate could never say"
assert_contains "$OUT" "capability=runner_inventory:needs-admin" "(5) the MISSING CAPABILITY is named (#2931 indicator 2)"
assert_contains "$OUT" "Resource not accessible" "(5) the 403 body is carried, not swallowed"
assert_contains "$OUT" "endpoint=repos/test-org/test-repo/actions/runners" "(5) the ENDPOINT is named"
assert_contains "$OUT" "BLIND alarm SENT" "(5) the pass ALARMS — silence was the defect"
assert_contains "$(cat "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null)" "BLIND" "(5) the alarm reached the durable inbox"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(5) a blind pass advances no mode"
assert_not_contains "$(cat "$GH_LOG")" "-X PUT" "(5) and relabels nothing"
assert_not_contains "$OUT" "healthy" "(5) a blind pass never says healthy"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "verdict=unknown" \
  "(5) a scheduler reading the verdict file sees UNKNOWN, not a green word"

# …and the alarm REPEATS but does not spam: suppressed inside the window, re-sent once past it. A
# one-shot alarm on a condition that lasts hours is the same silence one step later.
echo "── #2897: the blind alarm repeats WITHOUT spamming (dedupe window + re-arm) ──"
KEEP_STATE=1
run_gate census-403 GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(6) the second blind pass still refuses"
assert_contains "$OUT" "BLIND alarm SUPPRESSED" "(6) inside the window the alarm does not re-send"
assert_eq "$(grep -c BLIND "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null || echo 0)" "1" \
  "(6) exactly one inbox record so far"
run_gate census-403 ReAlarm GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden CI_GATE_BLIND_ALARM_EVERY_S=0 --
assert_contains "$OUT" "BLIND alarm SENT" "(6) past the window the alarm re-sends (a lasting condition is not silenced)"
assert_eq "$(grep -c BLIND "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null || echo 0)" "2" \
  "(6) two records — repeating, bounded"

# An unreadable capacity read must also be distinguished from a READABLE ZERO: a body that is not rows
# (a schema change, `null`, a proxy) is not "no runners", which would be a measured fact.
echo "── #2904: a non-row census body is UNREADABLE, not 'zero runners' ──"
run_gate census-garbage GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=garbage --
assert_eq "$RC" "2" "(7) a null census body → exit 2"
assert_contains "$OUT" "census UNREADABLE" "(7) the failure is named as a body/schema problem"
assert_not_contains "$OUT" "offline=0" "(7) 'no runners' is never invented from an unreadable body"
run_gate census-empty GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=empty --
assert_eq "$RC" "0" "(7) an EMPTY census is a readable zero, not a failed read"
assert_contains "$OUT" "runners=0" "(7) and it says so"

# ── #3002 review fixes — each one is a defect this pass's own artifacts could not answer ────────
# ⛔ (11) THE BLIND REPORT COULD NOT SAY HOW DEEP THE QUEUE WAS. `queued` is declared `local` INSIDE
# `evaluate`, so every `${queued:-unmeasured}` at top level took the default — structurally ALWAYS. The
# alarm and the verdict file, the two things this change exists to produce, could not tell a 0-deep
# queue from an 80-deep one on exactly the path that needs it.
echo "── #3002: the blind alarm and verdict carry the MEASURED queue, not a constant ──"
run_gate blind-queued GH_QUEUED=54 GH_INPROGRESS=6 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_eq "$RC" "2" "(11) the blind pass still refuses"
assert_contains "$(cat "$STATE_DIR/orchestrator-inbox.log" 2>/dev/null)" "queued=54" \
  "(11) the ALARM names the queue depth that was actually measured"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "queued=54" \
  "(11) …and so does the verdict file a scheduler branches on"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "in_progress=6" \
  "(11) FIELD PARITY with the success verdict — same keys, not missing ones"
assert_not_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "queued=unmeasured" \
  "(11) the old bug, pinned: a measured 54 rendered as the 'unmeasured' default"
# ⛔ (11b) THE CENSUS KEYS WERE STILL MISSING ON THIS PATH (#3002 review P2). The comment claimed "same
# keys, same order, in both writers" while the blind line carried nine keys and the success line
# seventeen, so a strict parser saw ABSENT census fields rather than an explicit `unmeasured`.
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "runners=unmeasured" \
  "(11b) an unread census is RECORDED as unmeasured, not omitted"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "demand=unmeasured" \
  "(11b) …including the demand key"
assert_contains "$(cat "$STATE_DIR/ci-runner-gate.verdict" 2>/dev/null)" "label_ambiguity=unmeasured" \
  "(11b) …and the ambiguity key: parity is a property of the surface, not of a comment"

# ⛔ (12) `--dry-run` DOCUMENTS "change nothing" AND USED TO MUTATE. `evaluate` runs BEFORE the DRY
# gate, so a blind dry-run sent a real alarm, wrote the stamp file and overwrote the verdict — and the
# next SCHEDULED pass then logged `SUPPRESSED (sent 1s ago)`, i.e. an operator triaging a blind box
# silenced the alarm for half an hour. That is #2897's silence, reintroduced by poking the gate.
echo "── #3002: --dry-run is a READ verb — a blind census must not alarm or consume the window ──"
run_gate dry-blind GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden -- --dry-run
assert_eq "$RC" "2" "(12) --dry-run still reports the blind refusal"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(12) …and sends NO alarm"
assert_absent "$STATE_DIR/ci-runner-gate.blind" "(12) …and writes no alarm stamp (the window is intact)"
assert_absent "$STATE_DIR/ci-runner-gate.verdict" "(12) …and overwrites no verdict"
assert_contains "$OUT" "BLIND alarm SUPPRESSED: --dry-run" "(12) and it SAYS it would have alarmed"
KEEP_STATE=1
run_gate dry-blind Scheduled GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden --
assert_contains "$OUT" "BLIND alarm SENT" "(12) the next SCHEDULED pass still alarms — the dry-run did not silence it"

# ⛔ (13) A LABEL'S CONTENT IS NOT ROW STRUCTURE. The census reads EVERY runner in the repo, so one
# runner labelled `my gpu box` used to make the whole inventory UNREADABLE — exit 2 forever, the
# fleet's only CI routing instrument frozen, with an alarm blaming a permission problem on a read that
# answered perfectly.
echo "── #3002: a runner label this gate cannot spell does not brick the census ──"
run_gate census-odd-label GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,my gpu box" --
assert_eq "$RC" "0" "(13) a space in a label does NOT make the inventory unreadable"
assert_contains "$OUT" "runners=2" "(13) the runners are still COUNTED"
assert_contains "$OUT" "online_idle=2" "(13) …and still classified by state"
run_gate census-slash-label GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
  GH_CENSUS="idle" GH_CENSUS_LABELS="self-hosted,gpu/a100" --
assert_eq "$RC" "0" "(13) …and neither does a slash"

# …but a label carrying the COMMA this pass splits on makes every demand MATCH untrustworthy, and an
# untrustworthy match must never become the evidence for a deny. Detected from the inventory's own
# label count, and it NARROWS (no deny) instead of voiding the pass.
echo "── #3002: an ambiguous label set NARROWS the claim — it never bricks, and never denies ──"
run_gate census-ambiguous GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64" GH_CENSUS_LABELCOUNT=2 --
assert_eq "$RC" "0" "(13b) a label containing the delimiter does not refuse the pass"
assert_contains "$OUT" "label_ambiguity=1" "(13b) the ambiguity is REPORTED, not hidden"
assert_not_contains "$OUT" "capacity=stranded" "(13b) and NEVER becomes the evidence for a stranded deny"
assert_contains "$OUT" "capacity=idle-unused" "(13b) the state reading — which is still sound — is what remains"

# ⛔ (14) THE ALARM'S OWN FLOOR was the one bound in the script never shape-checked: a non-numeric value
# ERRORS `[ -lt ]`, the `if` reads that as FALSE, and the alarm fires on EVERY pass — the unbounded
# alarm the bound exists to prevent.
echo "── #3002: the alarm floor is a bound like every other — garbage refuses, it does not alarm forever ──"
run_gate blind-floor-garbage GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=forbidden CI_GATE_BLIND_ALARM_EVERY_S=abc --
assert_eq "$RC" "2" "(14) a non-numeric alarm floor is a could-not-measure"
assert_contains "$OUT" "blind-alarm floor UNREADABLE" "(14) and it NAMES the bad operand"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(14) no alarm was sent on an unvalidated floor"

# ⛔ (15) GITHUB'S LABEL MATCHING IS CASE-INSENSITIVE. Compared literally, a workflow writing
# `runs-on: Ubuntu-Latest` selected exactly the runners the gate said offered nothing — and in
# mode=local that is a FALSE `stranded` deny claiming no runner could take a job they would have taken.
echo "── #3002: a capitalisation difference is not a missing runner ──"
run_gate census-demand-case GH_QUEUED=5 GH_FALLBACK_N=2 GH_INPROGRESS=2 \
  GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64,Ubuntu-Latest" --
assert_eq "$RC" "0" "(15) the pass completes"
assert_contains "$OUT" "demanding_idle=2" "(15) BOTH runners labelled 'Ubuntu-Latest' satisfy a 'ubuntu-latest' demand (case-insensitive)"
assert_not_contains "$OUT" "capacity=stranded" "(15) …so a capitalisation difference never becomes a FALSE deny"
assert_contains "$OUT" "capacity=idle-unused" "(15) and the pool's own idle capacity is what the verdict reports"

# ── #2897 option B: the MODE question HAS a readable substitute; the CAPACITY one does not ───────
echo "── #2897: an inventory-blind box still reports a REAL mode (jobs inference), narrowed ──"
run_gate status-inferred-local GH_FALLBACK_N=null GH_RUNNER_GROUP="Default" -- --status
assert_eq "$RC" "2" "(8) --status with no inventory read exits 2 (a narrowed claim is never 0)"
assert_contains "$OUT" "mode=local" "(8) the mode is still resolved — from runner_group_name (actions:read)"
assert_contains "$OUT" "source=jobs-inference" "(8) and it SAYS the answer is inferred, not read"
run_gate status-inferred-github GH_FALLBACK_N=null GH_RUNNER_GROUP="GitHub Actions" -- --status
assert_contains "$OUT" "mode=github" "(8) the same substitute resolves github when only hosted is serving"
run_gate status-inferred-none GH_FALLBACK_N=null GH_JOBS_MODE=none -- --status
assert_contains "$OUT" "mode=unknown source=none" "(8) with nothing executing there is nothing to infer — UNKNOWN, not a guess"

# `--status` is a READ verb: it reports the three states and the capability, and it does not alarm.
echo "── #2904: --status reports the census (the three states) without acting or alarming ──"
run_gate status-census GH_FALLBACK_N=1 GH_CENSUS="busy,off,off" -- --status
assert_eq "$RC" "0" "(9) --status with both reads available exits 0"
assert_contains "$OUT" "capacity=unmeasured" "(9) --status computes no verdict, and says so in the SAME vocabulary the verdict file uses"
assert_not_contains "$OUT" "capacity=measured" "(9) and never invents a seventh word a scheduler would have to special-case"
assert_contains "$OUT" "online_busy=1" "(9) …with the per-runner states"
assert_contains "$OUT" "offline=2" "(9) …including the registered runners that are offline"
assert_absent "$STATE_DIR/ci-runner-gate.state" "(9) --status advances no mode"
assert_absent "$STATE_DIR/orchestrator-inbox.log" "(9) --status alarms nobody"
run_gate status-blind GH_FALLBACK_N=1 GH_CENSUS_MODE=forbidden -- --status
assert_eq "$RC" "2" "(9) --status with an unreadable census exits 2"
assert_contains "$OUT" "capacity=unknown" "(9) and says UNKNOWN rather than reporting a count it did not read"
assert_contains "$OUT" "capability=runner_inventory:needs-admin" "(9) naming the capability"

# ── MUTATIONS — each arm must be load-bearing ────────────────────────────────────────────────────
# Without these, (1)-(9) could be satisfied by a script that prints the right words. Each mutation
# restores a specific PRE-FIX behaviour and must redden a specific arm above.
echo "── MUTATIONS: every arm of the capacity instrument is load-bearing ──"
mutate_gate() { # <out> <exact anchor (must be unique)> <replacement>
  python3 - "$GATE" "$1" "$2" "$3" <<'PY'
import sys
src, dst, anchor, repl = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(anchor) != 1:
    sys.exit("mutation anchor is not unique (or is absent) — the code moved, so this mutation is stale")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, repl, 1))
PY
}

# (m1) THE OLD READING: `busy` collapsed into a count, so an idle runner is indistinguishable.
MUT1="$T/ci_runner_gate.mutant-count.sh"
if mutate_gate "$MUT1" \
  '      if [ "$busy" = true ]; then CENSUS_ON_BUSY=$((CENSUS_ON_BUSY+1)); else CENSUS_ON_IDLE=$((CENSUS_ON_IDLE+1)); fi
      if offers_all "$labels" "$DEMAND_LABELS"; then' \
  '      CENSUS_ON_BUSY=$((CENSUS_ON_BUSY+1))   # MUTANT::m1 — a count, not a state
      if false; then                          # MUTANT::m1 — and no demand match either'; then
  ok "(m1) the count-not-state mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT1"
  run_gate mutant-count GH_QUEUED=54 GH_FALLBACK_N=0 GH_INPROGRESS=2 \
    GH_CENSUS="idle,idle,idle,idle,idle,idle,idle,busy,busy" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m1) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "capacity=idle-unused" <<<"$OUT"; then
    bad "(m1) MUTATION SURVIVED: with per-runner state collapsed to a count, 7 idle runners still read idle-unused"
  else
    ok "(m1) mutation killed: 7 idle runners read as busy — the '9 busy / 7 idle' misreading, restored"
  fi
else
  bad "(m1) the mutant could not be generated (anchor moved) — the three-state split is unproven"
fi

# (m2) THE OLD FAILURE MODE: an unreadable body read as "no rows", i.e. as a measured zero.
MUT2="$T/ci_runner_gate.mutant-zerofill.sh"
if mutate_gate "$MUT2" \
  '    case "$row" in *$'"'"'\t'"'"'*) ;; *) return 1 ;; esac
    st="${row%%$'"'"'\t'"'"'*}"' \
  '    case "$row" in *$'"'"'\t'"'"'*) ;; *) continue ;; esac   # MUTANT::m2 — an unreadable body is read as zero rows
    st="${row%%$'"'"'\t'"'"'*}"'; then
  ok "(m2) the zero-fill mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT2"
  run_gate mutant-zerofill GH_QUEUED=5 GH_FALLBACK_N=0 GH_CENSUS_MODE=garbage --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  # ⛔ A CRASH IS NOT A KILL (#3002 review P2). Without this guard a mutant that died before printing
  # anything scored as "killed", because the kill test only asked whether "census UNREADABLE" was
  # ABSENT — and a mutant that crashed never printed it. Same guard m1 already had; m2/m3/m4 lacked it.
  assert_eq "$RC" "0" "(m2) the mutant still RUNS — so the red below is the property, not a crash"
  if grep -qF "census UNREADABLE" <<<"$OUT"; then
    bad "(m2) MUTATION SURVIVED: a null census body still refused — the readable-zero distinction is not load-bearing"
  else
    ok "(m2) mutation killed: a null body is now read as 'zero runners' (rc=$RC) — a measured fact invented from an unreadable read"
  fi
else
  bad "(m2) the mutant could not be generated (anchor moved) — the readable-zero distinction is unproven"
fi

# (m3) THE FLAPPER: the mode gate dropped, so a pool stripped BY DESIGN reads as stranded and the
# fallback is re-engaged on every healthy tick — fighting #2327's recorded decision.
MUT3="$T/ci_runner_gate.mutant-flap.sh"
if mutate_gate "$MUT3" \
  '  if [ "$m" = local ] && [ "$demand_usable" = 1 ]; then
    if [ "$CENSUS_DEMAND_IDLE" -eq 0 ]' \
  '  if [ "$demand_usable" = 1 ]; then   # MUTANT::m3 — no mode gate: the pool stripped by design reads as stranded
    if [ "$CENSUS_DEMAND_IDLE" -eq 0 ]'; then  ok "(m3) the flapper mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT3"
  run_gate mutant-flap GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=6 \
    GH_CENSUS="idle,idle" GH_CENSUS_LABELS="self-hosted,Linux,ARM64,self-hosted-arm64" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m3) the mutant still RUNS — so the red below is the property, not a crash"
  if [ "$(cat "$STATE_DIR/ci-runner-gate.state" 2>/dev/null)" = "github" ]; then
    bad "(m3) MUTATION SURVIVED: without the mode gate, a correctly-stripped pool in mode=github still stayed github"
  else
    ok "(m3) mutation killed: the fallback is re-engaged on a healthy tick — exactly the fight with #2327 the gate must not pick"
  fi
else
  bad "(m3) the mutant could not be generated (anchor moved) — the mode gate is unproven"
fi

# ── A WRAPPER'S STDERR IS NOT A MEASUREMENT ───────────────────────────────────────────────────────
# Every read above is a VALUE; the noise below is commentary. Captured together they are
# indistinguishable, and the measured consequence was a gate that reported `mode=unknown` (and, against
# the census, a FALSE blind alarm) while the API answered perfectly.
echo "── #2897: a wrapper diagnostic on stderr never becomes a measured value ──"
run_gate noise GH_NOISE=1 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy,off" --
assert_eq "$RC" "0" "(10) a diagnostic on stderr does not fail a readable pass"
assert_contains "$OUT" "TRANSITION unknown -> github" "(10) the MODE is still read (the count survived the noise)"
assert_contains "$OUT" "offline=1" "(10) the CENSUS is still read"
assert_contains "$OUT" "capacity=saturated" "(10) and the capacity verdict is a measurement"
assert_not_contains "$OUT" "BLIND" "(10) noise never raises a blind alarm — that alarm means 'unreadable', nothing else"
assert_not_contains "$OUT" "mode=unknown" "(10) and the mode is never degraded to unknown by commentary"
assert_not_contains "$OUT" "mode INFERRED" "(10) the mode was READ from the inventory, not inferred around it"
run_gate noise-status GH_NOISE=1 GH_FALLBACK_N=1 GH_CENSUS="idle,busy" -- --status
assert_eq "$RC" "0" "(10) --status is not degraded by noise either"
assert_contains "$OUT" "mode=local" "(10) --status still resolves the mode"
assert_contains "$OUT" "online_idle=1" "(10) --status still reports the per-runner states"

# (m4) THE OLD CAPTURE: `2>&1` merges the diagnostic into the value.
MUT4="$T/ci_runner_gate.mutant-stderr.sh"
if mutate_gate "$MUT4" \
  '--jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>"$GH_ERR")" || {' \
  '--jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>&1)" || {   # MUTANT::m4'; then
  ok "(m4) the merged-stderr mutant was generated from the SHIPPED gate"
  GATE_UNDER_TEST="$MUT4"
  run_gate mutant-stderr GH_NOISE=1 GH_QUEUED=5 GH_FALLBACK_N=0 GH_INPROGRESS=2 GH_CENSUS="busy,busy,off" --
  GATE_UNDER_TEST="$GATE_UNDER_TEST_ORIG"
  assert_eq "$RC" "0" "(m4) the mutant still RUNS — so the red below is the property, not a crash"
  # The mutant still reaches `mode=github` — via the jobs SUBSTITUTE, which is the point of having one.
  # What must change is that the inventory read is no longer usable: the pass has to INFER instead of
  # read, and it says so. (Without the substitute it would be `unknown`; either way the read is lost.)
  if grep -qF "mode INFERRED" <<<"$OUT"; then
    ok "(m4) mutation killed: one wrapper diagnostic on stderr makes the inventory UNREADABLE — the mode has to be inferred instead of read"
  else
    bad "(m4) MUTATION SURVIVED: with stderr merged into the count, the mode was still READ from the inventory"
  fi
else
  bad "(m4) the mutant could not be generated (anchor moved) — the stderr split is unproven"
fi

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
