#!/usr/bin/env bash
# ci_runner_cell1_bringup.test.sh — hermetic guards for ci_runner_cell1_bringup.sh.
#
# It asserts the REFUSALS and the two FALSE-PASS controls, because each one is a failure that
# already happened on a real box:
#   · disk below the floor      → the ENOSPC that killed both cell-1 listeners (15:22:51Z) and the
#                                 reason a listener that dies never comes back
#   · awk not GNU awk           → mawk 1.3.4's `REcompile() - panic` turned a hosted-green step
#                                 FALSE RED (#2637)
#   · an install with no .runner → starting it serves nothing (#2502)
#   · an install for ANOTHER repo → started here, its jobs would be reported as this cell's capacity
#   · a START that died          → must NOT read a `_diag` log that predates it as `Listening for Jobs`
#   · a listener already live    → a second listener on ONE install double-claims jobs
# A guard nobody can demonstrate refusing is a wish with a semicolon, so every case runs the real
# script and reads its exit code — never a reimplementation of its logic.
#
# ⛔ EVERY CASE PINS ALL THREE READINGS. A case that pins only the floor it is testing reads the
# AMBIENT value of the others, so it asserts the wrong refusal on any box that happens to trip them
# (measured: with mawk on PATH, the "not-configured" case reported `why=awk-not-gawk`).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/ci_runner_cell1_bringup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '   ❌ %s\n' "$1"; }
expect_rc() { [ "$1" = "$2" ] && ok "$3 (rc=$2)" || bad "$3 — wanted rc=$1, got rc=$2"; }
expect_in() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — output did not contain '$1'" ;; esac; }
expect_not_in() { case "$2" in *"$1"*) bad "$3 — output unexpectedly contained '$1'" ;; *) ok "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root" "$TMP/bin"
# A stub gh: every read is answered from the call shape, so the suite never touches GitHub.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# ORDER MATTERS: the rows read's jq expression itself contains the word `labels`, so a
# `*labels*` arm placed first would answer the LIST read with a label string and no tab fields.
case "$*" in
  *'select(.name=='*) printf '%s\n' "${FAKE_ID:-21}" ;;
  *total_count*)      printf '%s\n' "${FAKE_QUEUED:-3}" ;;
  # Drain stdin FIRST: a real `gh --input -` reads the body, and a stub that ignores it closes the
  # pipe under `set -o pipefail` — which is how the SIGPIPE false refusal was found. Modelled, not
  # papered over: the stub behaves like the tool it stands in for.
  *'-X PUT'*)         cat >/dev/null; printf '%s\n' 'self-hosted,Linux,X64,self-hosted-x64,agent-infra,ubuntu-latest' ;;
  *)                  printf '%s\n' "${FAKE_GH_OUT:-21	fake-1	online	busy=true	self-hosted}" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CI_RUNNER_ROOT="$TMP/root" CI_RUNNER_PREFIX=fake CI_RUNNER_REPO=o/r
# Every reading pinned; each case overrides only what it is testing.
FLOORS_OK=(CI_RUNNER_MEM_MIN_MB=0 CI_RUNNER_DISK_MIN_GB=0 CI_RUNNER_AWK_VERSION='GNU Awk 5.2.1')

# 1. status mode reads only the artifact, and the row it prints is the API's own row
out="$(FAKE_GH_OUT=$'21\tfake-1\tonline\tbusy=true\tself-hosted' env "${FLOORS_OK[@]}" "$SUT" --status 2>&1)"; rc=$?
expect_rc 0 "$rc" "status mode succeeds"
# ⛔ Asserted on the ROW SHAPE, not on the name: `dir=…/fake-1 state=NOT-CONFIGURED` also contains
# the name and is printed whether or not the API answered, so a name-only grep can never fail.
printf '%s\n' "$out" | awk -F'\t' '$1=="21" && $2=="fake-1" && $3=="online"{f=1} END{exit !f}' \
  && ok "status prints the API row (id/name/status fields)" || bad "status did not print the API row"

# 2. disk floor
out="$(env "${FLOORS_OK[@]}" CI_RUNNER_DISK_MIN_GB=100000 "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "disk below the floor REFUSES"
expect_in 'why=disk-below-floor' "$out" "disk refusal names the reason"

# 3. memory floor (#2387)
out="$(env "${FLOORS_OK[@]}" CI_RUNNER_MEM_MIN_MB=10000000 "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "memory below the floor REFUSES"
expect_in 'why=mem-below-floor' "$out" "memory refusal names the reason"

# 4. the awk arm must not fail open once both floors are cleared (#2637)
out="$(env "${FLOORS_OK[@]}" CI_RUNNER_AWK_VERSION='mawk 1.3.4 20240123' "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "awk that is not GNU awk REFUSES (#2637)"
expect_in 'why=awk-not-gawk' "$out" "awk refusal names the reason"

# 4b. the escape hatch announces itself — a silent policy change leaves no trace
out="$(env "${FLOORS_OK[@]}" CI_RUNNER_AWK_VERSION='mawk 1.3.4 20240123' "$SUT" --skip-awk-check --dry-run 2>&1)"; rc=$?
expect_in 'why=awk-check-skipped' "$out" "--skip-awk-check prints the warning"

# 5. no .runner → refuse, never "start"
out="$(env "${FLOORS_OK[@]}" "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "install with no .runner REFUSES"
expect_in 'why=not-configured' "$out" "unconfigured refusal names the reason"

# 6. a .runner registered to ANOTHER repo → refuse (its jobs would be reported as this cell's)
mkdir -p "$TMP/root/fake-1"
printf '%s\n' '{ "agentName": "fake-1", "gitHubUrl": "https://github.com/someone/else" }' > "$TMP/root/fake-1/.runner"
out="$(env "${FLOORS_OK[@]}" "$SUT" --count 1 2>&1)"; rc=$?
expect_rc 3 "$rc" "install for another repo REFUSES"
expect_in 'why=wrong-repo' "$out" "wrong-repo refusal names the reason"

# 7. a listener already live → never a second one on the same install
printf '%s\n' '{ "agentName": "fake-1", "gitHubUrl": "https://github.com/o/r" }' > "$TMP/root/fake-1/.runner"
printf '#!/bin/sh\nexit 0\n' > "$TMP/root/fake-1/run.sh"; chmod +x "$TMP/root/fake-1/run.sh"
printf '#!/bin/sh\nprintf "%%s\\n" 4242\n' > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"
out="$(env "${FLOORS_OK[@]}" "$SUT" --count 1 2>&1)"; rc=$?
expect_in 'already-live' "$out" "an already-live listener is not restarted"
expect_not_in 'started name=' "$out" "no second start is claimed for a live install"

# 8. ⛔ THE FALSE-PASS CONTROL: a start that died must not inherit a PREVIOUS run's log
mkdir -p "$TMP/root/fake-1/_diag"
printf '%s\n' '2026-10-23 15:22:51Z: Listening for Jobs' > "$TMP/root/fake-1/_diag/Runner_20261023-152247-utc.log"
printf '#!/bin/sh\nprintf "boom\\n" >&2\nexit 1\n' > "$TMP/root/fake-1/run.sh"; chmod +x "$TMP/root/fake-1/run.sh"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"
out="$(env "${FLOORS_OK[@]}" CI_RUNNER_SETTLE_S=2 "$SUT" --count 1 2>&1)"; rc=$?
expect_rc 2 "$rc" "a start that died is cannot-act, not success"
expect_not_in 'started name=' "$out" "a stale _diag log is NOT read as Listening for Jobs"
expect_in 'why=no-new-listening-log' "$out" "the dead start names the reason"

# 9. dry-run plans and changes nothing
rm -rf "$TMP/root/fake-1/_diag" "$TMP/root/fake-1/run.sh"
out="$(env "${FLOORS_OK[@]}" "$SUT" --count 1 --dry-run 2>&1)"; rc=$?
expect_rc 0 "$rc" "dry-run exits 0"
expect_in 'nothing changed' "$out" "dry-run says it changed nothing"

# 10. ⛔ THE OPPOSITE FALSE RED: an EMPTY queue must not be diagnosed as the #2589 label defect,
#     and it must not print a mangled sentence (backticks inside a double-quoted message used to run
#     `online` as a command). `queued_before=0` is the measured-empty case; UNREADABLE is the other.
printf '#!/bin/sh\nprintf "%%s\\n" 4242\n' > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"
for q in 0 UNREADABLE; do
  out="$(FAKE_GH_OUT=$'21\tfake-1\tonline\tbusy=false\tself-hosted' FAKE_QUEUED="$q" \
        env "${FLOORS_OK[@]}" CI_RUNNER_VERIFY_WAIT_S=1 "$SUT" --count 1 2>&1)"; rc=$?
  expect_rc 4 "$rc" "empty/unreadable queue ($q) is UNPROVEN, not OK"
  expect_in 'why=no-queued-job' "$out" "empty queue ($q) names why=no-queued-job"
  expect_not_in 'the #2589 failure' "$out" "empty queue ($q) is NOT diagnosed as #2589"
  expect_not_in 'command not found' "$out" "empty queue ($q) message is not mangled by command substitution"
done

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
