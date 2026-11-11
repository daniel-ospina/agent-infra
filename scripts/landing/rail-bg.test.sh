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
    # FIXTURE_PRELUDE=1 puts a stderr-ish line BEFORE the start line (the parse must not depend on NR==1)
    [ "${FIXTURE_PRELUDE:-0}" = "1" ] && printf 'rail-run: ⚠ a warning printed before the start line\n'
    # FIXTURE_START_RUN_THEN_FAIL=1 emits a run line and STILL fails — the arm that pins "write the run
    # id only on success" (a failure path that prints no run line cannot exercise that gate at all).
    if [ "${FIXTURE_START_RUN_THEN_FAIL:-0}" = "1" ]; then
      printf 'started pr=%s run=run-ZZZ pid=4242 session=own repo=fake/repo\n' "${2:-}"
      exit "${FIXTURE_START_RC:-5}"
    fi
    if [ "${FIXTURE_START_NO_RUNLINE:-0}" = "1" ]; then printf 'rail-run: started (this line carries no run id)\n'; exit 0; fi
    [ "${FIXTURE_START_RC:-0}" = "0" ] || { printf 'rail-run: ✗ refused to start\n' >&2; exit "${FIXTURE_START_RC}"; }
    printf 'started pr=%s run=run-1 pid=4242 session=own repo=fake/repo\n' "${2:-}"
    printf '  log:    %s\n' "$FIXTURE_STATUS"
    ;;
  status)
    # per-PR overrides so one `poll` can see two different answers (row-<pr>.txt / rc-<pr>.txt)
    _d="${FIXTURE_STATUS%/*}"; _pr="${2:-}"
    if [ -f "$_d/row-$_pr.txt" ]; then cat "$_d/row-$_pr.txt"; else cat "$FIXTURE_STATUS"; fi
    if [ -f "$_d/rc-$_pr.txt" ]; then exit "$(cat "$_d/rc-$_pr.txt")"; fi
    exit "${FIXTURE_RC:-10}" ;;
  *) printf 'fixture: unexpected verb %s\n' "${1:-}" >&2; exit 98 ;;
esac
FIX
chmod +x "$T/rail-run-fixture.sh"
export RAIL_RUN_SH="$T/rail-run-fixture.sh"

status_row() { printf '%s\n' "$1" > "$FIXTURE_STATUS"; }
# The CLI keys its run-id file on (identity, PR) — mirror that here rather than hardcoding a path, so
# the arms exercise the real key and a change to it cannot silently pass.
runf() { # <pr> [identity]
  printf '%s/rail-%s-%s.run' "$LAND_LOG_DIR" \
    "$(printf '%s' "${2:-$LAND_REPO}" | od -An -tx1 | tr -d ' \n')" "$1"
}
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
assert_eq 'run-1' "$(cat "$(runf 42)" 2>/dev/null)" "start records WHICH run it created"

# ⛔ ONE IDENTITY: a caller-supplied --repo is REFUSED, not forwarded (fresh-review finding F2 on
# #3923). Forwarded, it keys rail-run's run state under another slug while `wait`/`poll` — which take
# no --repo — poll LAND_REPO, so a run this CLI started answered `no-run`. Refusal is also the
# cheaper property to pin: there is no second spelling to keep in sync.
: > "$FIXTURE_ARGV"
out="$(rb start 7 --repo other/repo)"; rc=$?
assert_rc 2 "$rc" "start REFUSES a caller-supplied --repo (identity is LAND_REPO alone)"
assert_contains "$out" 'LAND_REPO' "…and the refusal names LAND_REPO as the knob"
assert_eq '' "$(cat "$FIXTURE_ARGV")" "…and nothing was launched (the refusal precedes the spawn)"
out="$(rb start 7 --repo=other/repo)"; rc=$?
assert_rc 2 "$rc" "the --repo=VALUE spelling is refused too"

# a failed launch propagates rail-run's code and records no run
: > "$FIXTURE_ARGV"
out="$(env FIXTURE_START_RC=3 bash "$RB" start 8 2>&1)"; rc=$?
assert_rc 3 "$rc" "a refused launch propagates rail-run's exit code (3 = a live run holds the PR)"
out="$(env FIXTURE_START_RC=5 bash "$RB" start 8 2>&1)"; rc=$?
assert_rc 5 "$rc" "rail-run's 'launch did not start' (5) is propagated, not remapped"

# ⛔ BOTH HALVES OF "a failed launch leaves no run id" ARE PINNED (fresh-review finding F1 on #3923:
# the earlier arm asserted a file that could not have existed on either path, so no mutant reddened it).
# Half 1 — a PREVIOUS run's id must be cleared, not merely not-overwritten.
printf 'run-OLD\n' > "$(runf 9)"
out="$(env FIXTURE_START_RC=3 bash "$RB" start 9 2>&1)"; rc=$?
assert_rc 3 "$rc" "a refused start on a PR with a recorded run exits with rail-run's code"
assert_eq '' "$(cat "$(runf 9)" 2>/dev/null)" \
  "a refused start CLEARS the earlier run's id (so wait cannot report that run under this call)"
# Half 2 — a failure path that DOES print a run line must still record nothing.
out="$(env FIXTURE_START_RUN_THEN_FAIL=1 FIXTURE_START_RC=5 bash "$RB" start 10 2>&1)"; rc=$?
assert_rc 5 "$rc" "a launch that printed a run line and still failed propagates its code"
assert_contains "$out" 'started pr=10 run=run-ZZZ' "…the run line really was printed (the arm can discriminate)"
assert_eq '' "$(cat "$(runf 10)" 2>/dev/null)" \
  "…and its run id is NOT recorded (the rc gate is what pins it)"

# parse_run_id does not depend on the start line being FIRST in the merged 2>&1 stream
: > "$FIXTURE_ARGV"
out="$(env FIXTURE_PRELUDE=1 bash "$RB" start 11 2>&1)"; rc=$?
assert_rc 0 "$rc" "a prelude line before the start line does not break start"
assert_eq 'run-1' "$(cat "$(runf 11)" 2>/dev/null)" \
  "the run id is parsed from the start LINE, not from line 1 of the stream"


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
assert_rc 25 "$rc" "…and the RETRACTED code is not what the shell exits with (25, rail-run's abstention) — not 0/LANDED"
assert_not_contains "$out" 'LANDED' "a code/row DISAGREEMENT is never resolved in favour of LANDED"

out="$(wait_arm 42 60 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "an exit code outside rail-run's table → UNKNOWN"
assert_rc 25 "$rc" "…and exits 25 rather than propagating the unrecognised code"
assert_not_contains "$out" 'RECOMMEND: 42 LANDED' "an unrecognised code can never produce LANDED"

out="$(wait_arm 42 20 'redacted pr=42 run=run-1 repo=fake/repo pid=none rail_pid=none rc=1 pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 UNKNOWN' "an unrecognised state word → UNKNOWN"
assert_rc 25 "$rc" "…and exits 25, not the retracted 20/REFUSED (#2412 shape via the code)"
assert_not_contains "$out" 'REFUSED' "an unrecognised state word can never produce REFUSED"

# ── 6. wait polls THE run it started, never a newer one ──────────────────────
: > "$FIXTURE_ARGV"
status_row 'landed pr=42 run=run-1 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1'
env FIXTURE_RC=0 bash "$RB" wait 42 0 >/dev/null 2>&1
assert_contains "$(cat "$FIXTURE_ARGV")" 'argv: status 42 --repo fake/repo --run run-1' \
  "wait polls the recorded run id, not whatever is newest"
rm -f "$(runf 42)"
: > "$FIXTURE_ARGV"
env FIXTURE_RC=0 bash "$RB" wait 42 0 >/dev/null 2>&1
# ⛔ THE NEEDLE MUST DISTINGUISH THE BRANCHES. `argv: status 42 --repo fake/repo` is a strict
# PREFIX of the `--run` form, so it matches both and pins nothing; asserting the ABSENCE of
# `--run` reddens under an invented id AND under an unconditional `--run` (round-4 finding F1).
assert_not_contains "$(cat "$FIXTURE_ARGV")" '--run' \
  "with no recorded run id, no --run is passed (rail-run's newest-run behaviour, no invented id)"

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

# ── 8. the run-id bookkeeping is keyed by IDENTITY, not by PR alone (round-3 finding F2) ───────
# rail-run keys its state on (repo, PR); a PR-only filename here shared one binding between two repos'
# PR 42 on a box with the shared LAND_LOG_DIR, so `wait` polled one repo's run under another's identity.
: > "$FIXTURE_ARGV"
status_row 'running pr=42 run=run-1 repo=other/repo pid=1 rail_pid=2 rc=- pr_state=OPEN merged=- started=x log_bytes=10 log_age_s=1'
out="$(env LAND_REPO=other/repo bash "$RB" start 42 2>&1)"; rc=$?
assert_rc 0 "$rc" "start under one identity succeeds"
assert_eq 'run-1' "$(cat "$(runf 42 other/repo)" 2>/dev/null)" "…and records its run id under THAT identity"
assert_eq '' "$(cat "$(runf 42 repo-a/x)" 2>/dev/null)" "…and NOT under another identity's key (the PR-only key collided)"
: > "$FIXTURE_ARGV"
env LAND_REPO=repo-a/x FIXTURE_RC=10 bash "$RB" wait 42 0 >/dev/null 2>&1
assert_not_contains "$(cat "$FIXTURE_ARGV")" '--run run-1' \
  "a wait under another identity never polls the first identity's run id"

# ── 9. poll aggregates by WORST per-PR code (round-3 finding F3) ───────────────────────────────
# The fixture supports per-PR rows/codes, so this arm can give two PRs two different answers.
printf 'landed pr=7 run=r7 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1\n' > "$T/row-7.txt"
printf '0\n' > "$T/rc-7.txt"
printf 'unknown pr=8 run=r8 repo=fake/repo pid=none rail_pid=none rc=- pr_state=not-read merged=- started=x log_bytes=10 log_age_s=1\n' > "$T/row-8.txt"
printf '25\n' > "$T/rc-8.txt"
out="$(bash "$RB" poll --max 0 7 8 2>&1)"; rc=$?
assert_contains "$out" 'RECOMMEND: 7 LANDED' "poll reports the landed PR as LANDED"
assert_contains "$out" 'RECOMMEND: 8 UNKNOWN' "…and the abstaining PR as UNKNOWN"
assert_rc 25 "$rc" "poll exits with the WORST per-PR code (a landing beside an abstention is NOT exit 0)"
rm -f "$T/row-7.txt" "$T/rc-7.txt" "$T/row-8.txt" "$T/rc-8.txt"

# ── 10. a NO-ROW exit is an ERROR that keeps its code (round-4 finding F2) ─────────────────────
# A code outside rail-run's state table used to fall into the "code and row disagree" arm even when
# there was no row at all — so rail-run's 78 (pid-identity.sh missing, printed before any row) was
# mislabelled a disagreement and collapsed to 25, on the one path a partial install must name itself.
out="$(wait_arm 42 78 '')"; rc=$?
assert_contains "$out" 'RECOMMEND: 42 ERROR (rc=78' "a no-row 78 is an ERROR, not a disagreement"
assert_contains "$out" 'pid-identity.sh is missing' "…and the reason names the missing library"
assert_rc 78 "$rc" "…and 78 is KEPT (a partial install still names itself), not collapsed to 25"
assert_not_contains "$out" 'disagree' "…and it is NOT called a code/row disagreement (there was no row)"

out="$(wait_arm 43 0 '')"; rc=$?
assert_contains "$out" 'RECOMMEND: 43 ERROR (rc=0' "rc=0 with NO row at all is an ERROR, not a landing"
assert_rc 25 "$rc" "…and exits 25: absence is not a verdict"
assert_not_contains "$out" 'LANDED' "…never LANDED on an empty read"

out="$(wait_arm 44 5 '')"; rc=$?
assert_rc 5 "$rc" "a no-row 5 (the launch did not start) keeps its code too"

# ── 11. poll pins WORST, not LAST ─────────────────────────────────────────────────────────
# The earlier poll arm used `7 8`, where the worst is also the last — so a "last code" mutant survived.
# The reversed order is the discriminating one.
printf 'landed pr=7 run=r7 repo=fake/repo pid=1 rail_pid=2 rc=0 pr_state=MERGED merged=2026-11-01T00:00:00Z started=x log_bytes=10 log_age_s=1\n' > "$T/row-7.txt"
printf '0\n' > "$T/rc-7.txt"
printf 'unknown pr=8 run=r8 repo=fake/repo pid=none rail_pid=none rc=- pr_state=not-read merged=- started=x log_bytes=10 log_age_s=1\n' > "$T/row-8.txt"
printf '25\n' > "$T/rc-8.txt"
out="$(bash "$RB" poll --max 0 8 7 2>&1)"; rc=$?
assert_rc 25 "$rc" "poll over 8(25) then 7(0) exits 25 — the WORST, not the last"
rm -f "$T/row-7.txt" "$T/rc-7.txt" "$T/row-8.txt" "$T/rc-8.txt"

# ── 12. a success whose start line carries no run id says so ─────────────────────────────────
out="$(env FIXTURE_START_NO_RUNLINE=1 bash "$RB" start 45 2>&1)"; rc=$?
assert_rc 0 "$rc" "a launch that printed no run id still succeeds"
assert_contains "$out" 'will read its NEWEST run' "…and says the follow-up poll will read the newest run"
assert_eq '' "$(cat "$(runf 45)" 2>/dev/null)" "…and records no invented id"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
