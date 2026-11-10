#!/usr/bin/env bash
# scripts/landing/rail-bg.test.sh — the regression pin for scripts/landing/rail-bg.sh.
#
# WHY THIS EXISTS (agent-infra#2905). `rail-bg.sh` used to be a SECOND background-rail instrument: its
# own pid file, its own `kill -0` liveness test, its own `gh api … .merged` read, and its own
# `RECOMMEND: REFUSED|LANDED` verdicts. `scripts/rail-run.sh` answers the same question from richer
# evidence, so the fleet had two verdict rules for one question — the shape AGENTS.md's recorded rule
# forbids ("One verdict function, never a second"). #2905 left exactly that one item open.
#
# The delegation is only worth anything if it is PINNED, so half the arms below are the "a second
# rule came back" direction:
#   * `rail-bg.sh` must not read liveness itself (`kill -0`), must not make its own merged read
#     (`gh api`), and must not carry its own `pid_alive`/`merged_value` derivation;
#   * every recommendation must be a RENAME of rail-run's exit code — an exit code and a state row
#     that DISAGREE, or a code outside rail-run's table, must never surface as LANDED or REFUSED
#     (that is the false-PASS direction #1549 exists to prevent);
#   * `running` at the caller's bound must report PENDING, never REFUSED (the #2412 shape: a lane told
#     "refused" abandons a PR that merges minutes later).
#
# HERMETIC: no network, no `gh`, no rail, no real rail-run. A fixture `rail-run.sh` is supplied via
# RAIL_RUN_SH and all state lives in a temp dir.
#
# Run:  bash scripts/landing/rail-bg.test.sh
# Exit: 0 when every assertion passes, 1 on any failure, 2 when the interpreter is missing.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RB="$DIR/rail-bg.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
assert_rc() { # <want> <got> <label>
  if [ "$2" = "$1" ]; then ok "$3"; else bad "$3 (want rc=$1, got rc=$2)"; fi
}
assert_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | awk -v s="$2" 'index($0,s){f=1} END{exit(f?0:1)}'; then ok "$3"
  else bad "$3 (missing: $2)"; fi
}
assert_not_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | awk -v s="$2" 'index($0,s){f=1} END{exit(f?0:1)}'; then bad "$3 (unexpected: $2)"
  else ok "$3"; fi
}
assert_eq() { # <want> <got> <label>
  if [ "$2" = "$1" ]; then ok "$3"; else bad "$3 (want '$1', got '$2')"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rail-bg-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

export HOME="$T/home"; mkdir -p "$HOME"
export LAND_DIR="$T/land"; mkdir -p "$LAND_DIR/scripts"
: > "$LAND_DIR/scripts/atomic-land.sh"
export LAND_LOG_DIR="$T/logs"
export LAND_REPO="fake/repo"
export FIXTURE_ARGV="$T/argv.txt"; : > "$FIXTURE_ARGV"
export FIXTURE_STATUS="$T/status.txt"; : > "$FIXTURE_STATUS"

# ── the fixture delegate ───────────────────────────────────────────────────────
# It is a spy, not an implementation: it records the argv it was handed (including the rail it was
# pointed at) and replays a canned state row + exit code. FIXTURE_START_RC lets an arm make `start`
# fail without a rail.
cat > "$T/rail-run-fixture.sh" <<'FIX'
#!/usr/bin/env bash
printf 'argv: %s\n' "$*" >> "$FIXTURE_ARGV"
printf 'rail: %s\n' "${RAIL_RUN_RAIL:-<unset>}" >> "$FIXTURE_ARGV"
case "${1:-}" in
  start)
    [ "${FIXTURE_START_RC:-0}" = "0" ] || { printf 'rail-run: ✗ refused to start\n' >&2; exit "${FIXTURE_START_RC}"; }
    printf 'started pr=%s run=run-1 pid=4242 session=own repo=fake/repo\n' "${2:-}"
    printf '  log:    %s\n' "$FIXTURE_STATUS"
    ;;
  status) cat "$FIXTURE_STATUS"; exit "${FIXTURE_RC:-10}" ;;
  *) printf 'fixture: unexpected verb %s\n' "${1:-}" >&2; exit 98 ;;
esac
FIX
chmod +x "$T/rail-run-fixture.sh"
export RAIL_RUN_SH="$T/rail-run-fixture.sh"

status_row() { printf '%s\n' "$1" > "$FIXTURE_STATUS"; }
rb() { bash "$RB" "$@" 2>&1; }

echo "rail-bg.test.sh — one verdict function, delegated to rail-run.sh (#2905)"

# ── 1. the single-source guards: this file derives NOTHING ────────────────────
BODY="$(cat "$RB")"
# The guards below are about CODE, and the header comment deliberately NAMES the reads this file no
# longer makes — so full-line comments are stripped first. A needle inside an inline trailing comment
# still fails the guard, which is the safe direction (it sends a human to look).
CODE="$(printf '%s\n' "$BODY" | awk '/^[[:space:]]*#/{next} {print}')"
assert_not_contains "$CODE" 'gh api' "no own merged read (gh api) in rail-bg.sh"
assert_not_contains "$CODE" '--jq .merged' "no own .merged projection in rail-bg.sh"
assert_not_contains "$CODE" 'kill -0' "no own liveness read (kill -0) in rail-bg.sh"
assert_not_contains "$CODE" 'merged_value' "no own merged_value() derivation in rail-bg.sh"
assert_not_contains "$CODE" 'pid_alive' "no own pid_alive() liveness derivation in rail-bg.sh"
assert_contains "$CODE" 'rail-run.sh' "rail-bg.sh names rail-run.sh as its verdict source"
assert_contains "$CODE" 'RAIL_RUN_RAIL' "rail-bg.sh points rail-run at the full landing unit"

# ── 2. usage / environment errors ─────────────────────────────────────────────
out="$(rb --help)"; rc=$?
assert_rc 0 "$rc" "--help exits 0"
assert_contains "$out" 'rail-run' "--help states that rail-run owns the verdict"
assert_contains "$out" 'LAND_REPO' "--help documents the identity variable"

out="$(rb)"; rc=$?
assert_rc 2 "$rc" "no subcommand is a usage error"
out="$(rb nonsense)"; rc=$?
assert_rc 2 "$rc" "unknown subcommand is a usage error"
out="$(rb wait abc)"; rc=$?
assert_rc 2 "$rc" "a non-numeric PR is a usage error"

# no identity: LAND_REPO unset AND `gh repo view` yields nothing — an environment error, not a guess
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
chmod +x "$T/bin/gh"
out="$(env -u LAND_REPO PATH="$T/bin:$PATH" bash "$RB" start 42 2>&1)"; rc=$?
assert_rc 2 "$rc" "an unresolvable repo identity is refused (exit 2)"
assert_contains "$out" 'LAND_REPO' "that refusal names LAND_REPO as the fix"

# no rail in LAND_DIR
out="$(env LAND_RAIL="$T/nope/atomic-land.sh" bash "$RB" start 42 2>&1)"; rc=$?
assert_rc 2 "$rc" "a missing rail is refused (exit 2)"
assert_contains "$out" 'LAND_DIR' "that refusal names LAND_DIR as the fix"

# ── 3. start: delegation, identity, run-id bookkeeping ───────────────────────
: > "$FIXTURE_ARGV"
status_row 'running pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=- pr_state=OPEN merged=- started=2026-11-01T00:00:00Z log_bytes=10 log_age_s=1'
out="$(rb start 42 --dry-run)"; rc=$?
assert_rc 0 "$rc" "start exits 0 on a successful launch"
assert_contains "$out" 'started pr=42 run=run-1' "start prints rail-run's own start block"
ARGV="$(cat "$FIXTURE_ARGV")"
assert_contains "$ARGV" 'argv: start 42 --repo fake/repo --dry-run' "start forwards the PR, the identity and the rail args"
assert_contains "$ARGV" "rail: $LAND_DIR/scripts/atomic-land.sh" "start points rail-run at atomic-land.sh (the full landing unit)"
assert_eq 'run-1' "$(cat "$LAND_LOG_DIR/rail-42.run" 2>/dev/null)" "start records WHICH run it created"

# a caller-supplied --repo comes AFTER ours, so rail-run's left-to-right scan lets it win
: > "$FIXTURE_ARGV"
out="$(rb start 7 --repo other/repo)"; rc=$?
assert_rc 0 "$rc" "start accepts a caller-supplied --repo"
assert_contains "$(cat "$FIXTURE_ARGV")" 'argv: start 7 --repo fake/repo --repo other/repo' \
  "the caller's --repo is forwarded after the shim's (so it wins)"

# a failed launch propagates rail-run's code and records no run
: > "$FIXTURE_ARGV"
out="$(env FIXTURE_START_RC=3 bash "$RB" start 8 2>&1)"; rc=$?
assert_rc 3 "$rc" "a refused launch propagates rail-run's exit code (3 = a live run holds the PR)"
assert_eq '' "$(cat "$LAND_LOG_DIR/rail-8.run" 2>/dev/null)" "a failed launch records no run id"

# ── 4. wait: the recommendation is a RENAME of rail-run's verdict ─────────────
# The arm helper: <pr> <rail-run rc> <state row>
wait_arm() { # <pr> <rc> <row>
  status_row "$3"
  env FIXTURE_RC="$2" bash "$RB" wait "$1" 0 2>&1
}

out="$(wait_arm 42 0 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1 verdict=rail')"; rc=$?
assert_rc 0 "$rc" "landed → exit 0"
assert_contains "$out" 'RECOMMEND: 42 LANDED' "landed → RECOMMEND LANDED"
assert_contains "$out" 'CONFIRMED merged=true' "landed → CONFIRMED merged=true from the recorded read"
assert_contains "$out" 'landed pr=42' "the rail-run row is printed verbatim (evidence, not a summary)"

# ── 4b. the transcription must be TRANSCRIBED (fresh-review findings F1/F2 on #3923) ─────────
# The recommendation's merged= is not a hardcoded literal: it carries the SAME value the CONFIRMED
# line resolved, so a row whose merged read failed can never be reported as `LANDED "merged=true"`.
confirm_val() { printf '%s\n' "$1" | awk '/^CONFIRMED merged=/{sub(/^CONFIRMED merged=/,""); sub(/ .*/,""); print; exit}' ; }
recommend_val() { printf '%s\n' "$1" | sed -n 's/.*RECOMMEND: [0-9]* LANDED "merged=\([^"]*\)".*/\1/p' | head -1; }
assert_agree() { # <output> <label>
  local c r; c="$(confirm_val "$1")"; r="$(recommend_val "$1")"
  if [ -n "$r" ] && [ "$c" != "$r" ]; then bad "$2 (CONFIRMED merged=$c but RECOMMEND merged=$r)"
  else ok "$2"; fi
}

out="$(wait_arm 42 0 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1') "; rc=$?
assert_contains "$out" 'RECOMMEND: 42 LANDED "merged=true"' "landed with an observed merge → LANDED merged=true"
assert_agree "$out" "…and the LANDED value equals the CONFIRMED value (they cannot disagree)"

# F2: pr_state=MERGED with merged=- is a merge (mergedAt is nullable) — never `merged=false`
out="$(wait_arm 42 0 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=- started=x log_bytes=10 log_age_s=1') "; rc=$?
assert_contains "$out" 'CONFIRMED merged=true' "pr_state=MERGED with merged=- reads merged=true (mergedAt is nullable)"
assert_not_contains "$out" 'CONFIRMED merged=false' "…and never merged=false for a MERGED PR state"
assert_contains "$out" 'RECOMMEND: 42 LANDED "merged=true"' "…and the LANDED line agrees with it"

# F1: a landed row whose merged= field is ABSENT must not produce a `merged=true` claim
out="$(wait_arm 42 0 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED started=x log_bytes=10 log_age_s=1') "; rc=$?
assert_rc 0 "$rc" "landed with no merged= field still exits 0 (rail-run's verdict)"
assert_contains "$out" 'CONFIRMED merged=UNREADABLE reason=no-read' "a row with no merged= field is UNREADABLE, never false"
assert_not_contains "$out" 'LANDED "merged=true"' "…and the LANDED line does not claim merged=true (the F1 false-PASS arm)"
assert_not_contains "$out" 'CONFIRMED merged=true' "…nor does the CONFIRMED line"
assert_contains "$out" 'RECOMMEND: 42 LANDED "merged=UNREADABLE"' "…the LANDED line carries the value actually read"
assert_contains "$out" 'count a landing only on an observed merged=true' "…and the reader is told which value to count on"

out="$(wait_arm 42 0 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=bogus-field started=x log_bytes=10 log_age_s=1') "; rc=$?
assert_contains "$out" 'CONFIRMED merged=UNREADABLE reason=unexpected-field' "an unparseable merged= value abstains"
assert_not_contains "$out" 'LANDED "merged=true"' "…and never becomes a merged=true claim"
assert_not_contains "$out" 'CONFIRMED merged=true' "…in either transcribed line"

out="$(wait_arm 42 10 'running pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=- pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_rc 10 "$rc" "still running at the bound → exit 10"
assert_contains "$out" 'RECOMMEND: 42 PENDING' "still running at the bound → PENDING"
assert_not_contains "$out" 'REFUSED' "a run that is still going is NEVER reported REFUSED (#2412 shape)"

out="$(wait_arm 42 20 'refused pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=1 pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_rc 20 "$rc" "refused → exit 20"
assert_contains "$out" 'RECOMMEND: 42 REFUSED' "refused → RECOMMEND REFUSED"
assert_contains "$out" 'CONFIRMED merged=false' "refused → CONFIRMED merged=false (the read did succeed)"

out="$(wait_arm 42 21 'killed pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=143 pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 KILLED' "a signal death → KILLED"
assert_not_contains "$out" 'REFUSED' "a signal death is NEVER reported REFUSED"

out="$(wait_arm 42 22 'gone-without-verdict pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=none pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 NO-VERDICT' "gone-without-verdict → NO-VERDICT"
assert_not_contains "$out" 'LANDED' "no verdict is NEVER reported as a landing"

out="$(wait_arm 42 23 'exited-zero pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=0 pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'EXITED-ZERO-NOT-LANDED' "rc=0 with an unmerged PR is NOT a landing"

out="$(wait_arm 42 24 'no-run pr=42 run=- repo=? pid=none rail_pid=none rc=none pr_state=not-read merged=- started=- log_bytes=0 log_age_s=-')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 NO-RUN' "no-run → NO-RUN"
assert_contains "$out" 'CONFIRMED merged=UNREADABLE' "no-run → merged is UNREADABLE, never false"

out="$(wait_arm 42 25 'unknown pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=- pr_state=not-read merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "unknown → UNKNOWN"
assert_not_contains "$out" 'REFUSED' "an abstained read is NEVER reported REFUSED"

# ── 5. the false-PASS arms: a code/row disagreement can never land ────────────
out="$(wait_arm 42 0 'unknown pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=- pr_state=not-read merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "rc=0 with an unknown row → UNKNOWN (codes are cross-checked)"
assert_not_contains "$out" 'LANDED' "a code/row DISAGREEMENT is never resolved in favour of LANDED"

out="$(wait_arm 42 60 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "an exit code outside rail-run's table → UNKNOWN"
assert_not_contains "$out" 'RECOMMEND: 42 LANDED' "an unrecognised code can never produce LANDED"

out="$(wait_arm 42 20 'redacted pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=1 pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "an unrecognised state word → UNKNOWN"
assert_not_contains "$out" 'REFUSED' "an unrecognised state word can never produce REFUSED"

# ── 6. wait polls THE run it started, never a newer one ──────────────────────
: > "$FIXTURE_ARGV"
status_row 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1'
env FIXTURE_RC=0 bash "$RB" wait 42 0 >/dev/null 2>&1
assert_contains "$(cat "$FIXTURE_ARGV")" 'argv: status 42 --repo fake/repo --run run-1' \
  "wait polls the recorded run id, not whatever is newest"
rm -f "$LAND_LOG_DIR/rail-42.run"
: > "$FIXTURE_ARGV"
env FIXTURE_RC=0 bash "$RB" wait 42 0 >/dev/null 2>&1
assert_contains "$(cat "$FIXTURE_ARGV")" 'argv: status 42 --repo fake/repo' \
  "with no recorded run id, wait uses rail-run's documented newest-run behaviour (no invented id)"

# ── 7. poll: several PRs, each reported from a fresh read ────────────────────
status_row 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1'
out="$(env FIXTURE_RC=0 bash "$RB" poll --max 0 42 2>&1)"; rc=$?
assert_rc 0 "$rc" "poll over a settled PR exits with its state code (0)"
assert_contains "$out" 'ALL SETTLED' "poll says when every PR settled"
assert_contains "$out" '════ PR 42 ════' "poll prints one section per PR"

status_row 'running pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=- pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1'
out="$(env FIXTURE_RC=10 bash "$RB" poll --max 0 42 2>&1)"; rc=$?
assert_rc 10 "$rc" "poll exits 10 while a PR is still running"
assert_contains "$out" 'STILL RUNNING: 42 after 0s' "poll names the PRs still running"
assert_contains "$out" 'RECOMMEND: 42 PENDING' "poll's per-PR report is the same transcription (PENDING)"

out="$(rb poll --max nope 42)"; rc=$?
assert_rc 2 "$rc" "poll refuses a non-numeric bound (a bound that cannot fire is not a bound)"
out="$(rb poll)"; rc=$?
assert_rc 2 "$rc" "poll with no PRs is a usage error"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
