#!/usr/bin/env bash
# rail-run.test.sh — hermetic suite for scripts/rail-run.sh (agent-infra#2885).
#
# Run:  bash scripts/rail-run.test.sh
# Exit: 0 when every assertion passes, 1 on any failure. NO network, NO real `gh`, NO real rail:
#       the rail and `gh` are executables in a temp bin/ and all state lives under a temp
#       RAIL_RUN_DIR with a temp HOME.
#
# WHAT THIS SUITE HAS TO PROVE (the defect, not the happy path). #2885's whole failure was that a
# rail STILL WAITING and a rail that produced NO VERDICT looked identical to the caller: the process
# was killed at a tool call's 1800s cap while the rail's own ceiling is 18064s, so a HEALTHY run
# read as a failure and no verdict existed for that head. So most arms below are NEGATIVE — a
# `running` run must never read as landed/refused, `gone-without-verdict` must never read as landed,
# `rc=0` must not be a landing when the artifact disagrees, and an UNREADABLE liveness or PR read
# must abstain instead of guessing in either direction. Each arm names the guard it discriminates:
# remove that guard and the arm fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR="$SCRIPT_DIR/rail-run.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
assert_rc() { # <want> <got> <label>
  if [ "$2" = "$1" ]; then ok "$3"; else bad "$3 (want rc=$1, got rc=$2)"; fi
}
assert_state() { # <output> <want> <label>
  local got; got="$(printf '%s' "$1" | cut -d' ' -f1)"
  if [ "$got" = "$2" ]; then ok "$3"; else bad "$3 (want state=$2, got '$got' from: $1)"; fi
}
assert_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | awk -v s="$2" 'index($0,s){f=1} END{exit(f?0:1)}'; then ok "$3"
  else bad "$3 (missing: $2)"; fi
}
assert_not_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | awk -v s="$2" 'index($0,s){f=1} END{exit(f?0:1)}'; then bad "$3 (unexpected: $2)"
  else ok "$3"; fi
}
field() { # <output> <key> -> the value of key= on the state row
  printf '%s' "$1" | awk -v k="$2" '/^[a-z-]+ pr=/{for(i=1;i<=NF;i++){if(index($i,k"=")==1){print substr($i,length(k)+2)}}}'
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rail-run-test.XXXXXX")"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

export HOME="$T/home"; mkdir -p "$HOME"
export RAIL_RUN_DIR="$T/state"
export RAIL_RUN_RAIL="$T/bin/rail"
export RAIL_RUN_GH="$T/bin/gh"
export FAKE_RAIL_COUNT="$T/rail-count.txt"
export FAKE_RAIL_LOG="$T/rail-was-called.log"
mkdir -p "$T/bin"
: > "$FAKE_RAIL_COUNT"

# ── the fake rail ─────────────────────────────────────────────────────────────
# FAKE_RAIL_SLEEP      seconds to spend "waiting on CI" (one log line per second: log GROWTH)
# FAKE_RAIL_RC         the exit status it finally returns (default 0)
# FAKE_RAIL_REFUSAL    when set, it prints the rail's own red-tree refusal sentence
# FAKE_RAIL_PIDFILE    where it records its own pid (so a test can signal the RAIL, not the wrapper)
cat > "$T/bin/rail" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_RAIL_LOG"
printf 'x\n' >> "$FAKE_RAIL_COUNT"
[ -n "${FAKE_RAIL_PIDFILE:-}" ] && printf '%s\n' "$$" > "$FAKE_RAIL_PIDFILE"
if [ -n "${FAKE_RAIL_REFUSAL:-}" ]; then
  printf 'admin-merge: ✗ THE TREE THIS PR PRODUCES IS RED — %s\n' "$FAKE_RAIL_REFUSAL"
fi
i=0
while [ "$i" -lt "${FAKE_RAIL_SLEEP:-0}" ]; do
  printf 'admin-merge: … FIRST-CHECKS wait: still RUNNING and PROGRESSING (change #%s)\n' "$((i + 1))"
  sleep 1; i=$((i + 1))
done
printf 'admin-merge: last words before exiting %s\n' "${FAKE_RAIL_RC:-0}"
exit "${FAKE_RAIL_RC:-0}"
FAKE
chmod +x "$T/bin/rail"

# ── the `gh` double ───────────────────────────────────────────────────────────
# GH_MODE: merged (default) | open | fail
cat > "$T/bin/gh" <<'GHD'
#!/usr/bin/env bash
case "${GH_MODE:-merged}" in
  merged) printf 'MERGED 2026-10-27T03:56:04Z\n' ;;
  open)   printf 'OPEN -\n' ;;
  fail)   printf 'HTTP 502: bad gateway\n' >&2; exit 1 ;;
esac
GHD
chmod +x "$T/bin/gh"

# ── helpers ───────────────────────────────────────────────────────────────────
call() { # <verb> [args...] -> "<rc>|<output>"
  local out rc=0
  out="$(bash "$RR" "$@" 2>&1)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
poll() { call status "$@"; }
wait_state() { # <want-state> <pr> [--run id] — poll until the state word matches (bounded)
  local want="$1"; shift
  local i=0 out
  while [ "$i" -lt 150 ]; do
    out="$(poll "$@")"
    case "${out#*|}" in "$want "*) printf '%s' "$out"; return 0 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  printf '%s' "$out"; return 1
}
run_id_of() { field "${1#*|}" run; }
rundir() { # <pr> <run-id> -> the run dir
  printf '%s/agent-infra/pr-%s/%s' "$RAIL_RUN_DIR" "$1" "$2"
}

printf '=== rail-run.sh — start/poll, first-class states (#2885) ===\n'

# ── usage ─────────────────────────────────────────────────────────────────────
OUT="$(call)"; assert_rc 2 "${OUT%%|*}" "USAGE: no verb exits 2"
OUT="$(poll abc)"; assert_rc 2 "${OUT%%|*}" "USAGE: a non-numeric PR is refused before it reaches a path"
OUT="$(call start 0)"; assert_rc 2 "${OUT%%|*}" "USAGE: PR 0 is refused"

# ── A: start RETURNS IMMEDIATELY, and the run reads `running` ────────────────
SECONDS=0
OUT="$(FAKE_RAIL_SLEEP=8 call start 101)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
ELAPSED=$SECONDS
assert_rc 0 "$RC" "START: exits 0"
if [ "$ELAPSED" -lt 3 ]; then ok "START: returns at once while the rail waits 8s (elapsed ${ELAPSED}s)"
else bad "START: blocked for ${ELAPSED}s — it must not wait on the rail"; fi
assert_contains "$TXT" "session=own" "START: the recorder is in its OWN session (measured, not claimed)"
assert_contains "$TXT" "poll:" "START: prints the exact poll command"
RUN1="$(run_id_of "$OUT")"
if [ -n "$RUN1" ] && [ -d "$(rundir 101 "$RUN1")" ]; then
  ok "START: records a run dir (run=$RUN1)"
else bad "START: no run dir for run='$RUN1'"; fi
for f in pid start rail repo started args log; do
  [ -s "$(rundir 101 "$RUN1")/$f" ] || bad "START: $f was not recorded"
done
# ⛔ THE RAIL'S OWN ARGV IS ASSERTED, not assumed. `start_rail` shifts the PR off `$@` before it
# spawns, and a spawn that forwards only the REMAINDER reaches `admin-merge.sh` PR-less — it then
# logs "a PR number is required" and exits 2, so every run would analyse nothing while the state
# machine reported a clean refusal. Found by a real-rail smoke run; this arm is why it cannot
# come back.
RAIL_ARGV="$(awk 'NR==1' "$FAKE_RAIL_LOG" 2>/dev/null)"
if [ "$RAIL_ARGV" = "101" ]; then ok "ARGV: the rail received the PR as its first argument"
else bad "ARGV: the rail received '$RAIL_ARGV' (want '101')"; fi
PIDS+=("$(cat "$(rundir 101 "$RUN1")/pid" 2>/dev/null || true)")

OUT="$(poll 101)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 10 "$RC" "RUNNING: exit code 10 (still running is its own code, not an error)"
assert_state "$TXT" running "RUNNING: the state word is 'running'"
assert_not_contains "$TXT" "landed" "RUNNING: never reported as landed"
assert_not_contains "$TXT" "gone-without-verdict" "RUNNING: never reported as no-verdict"
B1="$(field "$TXT" log_bytes)"
sleep 1.3
OUT="$(poll 101)"; TXT="${OUT#*|}"; B2="$(field "$TXT" log_bytes)"
if [ "${B2:-0}" -gt "${B1:-0}" ]; then
  ok "RUNNING: the poll shows LOG GROWTH (${B1} -> ${B2} bytes), not a cached verdict"
else bad "RUNNING: log_bytes did not grow (${B1:-?} -> ${B2:-?})"; fi
assert_state "$TXT" running "RUNNING: still 'running' after the log grew"

# ── B: a LIVE run blocks a second start (one rail per PR), decided on evidence
OUT="$(call start 101)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 3 "$RC" "DUPLICATE: a second start while one is live exits 3"
assert_contains "$TXT" "already LIVE" "DUPLICATE: names the live run"
N="$(wc -l < "$FAKE_RAIL_COUNT" | tr -d '[:space:]')"
assert_rc 1 "$N" "DUPLICATE: exactly ONE rail invocation ever reached the rail"

# ── C: refused — the rail's own words and its own exit status ────────────────
OUT="$(FAKE_RAIL_REFUSAL='python shards 3 of 8 failed' FAKE_RAIL_RC=1 call start 102)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "REFUSED: start exits 0 (the launch started; the verdict comes from status)"
OUT="$(GH_MODE=open wait_state refused 102)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 20 "$RC" "REFUSED: exit code 20"
assert_state "$TXT" refused "REFUSED: the state word is 'refused'"
assert_contains "$TXT" "python shards 3 of 8 failed" "REFUSED: quotes the rail's own refusal line"
assert_not_contains "$TXT" "landed" "REFUSED: never reported as landed"

# ── D: killed — the rail died of a SIGNAL, which is neither a refusal nor a landing
FAKE_RAIL_PIDFILE="$T/rail-pid.txt" FAKE_RAIL_SLEEP=30 call start 103 >/dev/null
PIDS+=("$(cat "$(rundir 103 "$(cat "$RAIL_RUN_DIR/agent-infra/pr-103/latest")")/pid" 2>/dev/null || true)")
i=0; while [ ! -s "$T/rail-pid.txt" ] && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
RAILPID="$(cat "$T/rail-pid.txt" 2>/dev/null || true)"
PIDS+=("$RAILPID")
if [ -n "$RAILPID" ]; then kill -TERM "$RAILPID" 2>/dev/null; else bad "KILLED: the fake rail never recorded a pid"; fi
OUT="$(GH_MODE=open wait_state killed 103)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 21 "$RC" "KILLED: exit code 21"
assert_contains "$TXT" "SIGTERM" "KILLED: names the signal that ended it"
assert_not_contains "$TXT" "landed" "KILLED: never reported as landed"

# ── E: landed — the rail's OWN verdict (rc=0 AND the artifact agree) ─────────
OUT="$(GH_MODE=merged call start 104)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "LANDED: start exits 0"
OUT="$(wait_state landed 104)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "LANDED: exit code 0"
assert_contains "$TXT" "verdict=rail" "LANDED: counted as the RAIL's verdict (rc=0 and the artifact agree)"

# ── F: rc=0 is NOT a landing — the artifact has to agree ────────────────────
OUT="$(GH_MODE=open call start 105)"; RC="${OUT%%|*}"
OUT="$(GH_MODE=open wait_state exited-zero 105)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 23 "$RC" "EXITED-ZERO: exit code 23"
assert_state "$TXT" exited-zero "EXITED-ZERO: rc=0 with an UNMERGED PR is not a landing"
assert_not_contains "$TXT" "landed" "EXITED-ZERO: never reported as landed"

# ── G: rc=0 + an UNREADABLE PR state abstains instead of claiming a landing ─
GH_MODE=fail call start 106 >/dev/null
OUT="$(GH_MODE=fail wait_state unknown 106)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "UNKNOWN: exit code 25"
assert_not_contains "$TXT" "landed" "UNKNOWN: an unread artifact is NOT a landing"
assert_not_contains "$TXT" "refused" "UNKNOWN: an unread artifact is NOT a refusal"

# ── H: gone-without-verdict — the recorder died with no exit status ─────────
# #2885's missing state: a SIGKILLed recorder writes nothing, so the poll must SAY so.
FAKE_RAIL_PIDFILE="$T/rail-pid2.txt" FAKE_RAIL_SLEEP=30 call start 107 >/dev/null
RUNDIR107="$(rundir 107 "$(cat "$RAIL_RUN_DIR/agent-infra/pr-107/latest")")"
REC="$(cat "$RUNDIR107/pid" 2>/dev/null || true)"
PIDS+=("$REC" "$(cat "$T/rail-pid2.txt" 2>/dev/null || true)")
if [ -n "$REC" ]; then kill -9 "$REC" 2>/dev/null; fi
OUT="$(GH_MODE=open wait_state gone-without-verdict 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 22 "$RC" "GONE: exit code 22"
assert_state "$TXT" gone-without-verdict "GONE: no exit status + recorder gone is its OWN state"
assert_not_contains "$TXT" "landed" "GONE: never reported as landed"
assert_contains "$TXT" "NO VERDICT" "GONE: says plainly that this run produced no verdict"

# ── H2: the same gone run, PR MERGED → landed=artifact ──────────────────────
# The artifact outranks the exit status: reporting 'gone' over a real merge is the wrong direction.
OUT="$(GH_MODE=merged poll 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "GONE+MERGED: exit code 0"
assert_contains "$TXT" "verdict=artifact" "GONE+MERGED: attributed to the ARTIFACT, not to this run"
assert_contains "$TXT" "no rail verdict" "GONE+MERGED: still says this run produced no rail verdict"

# ── I: the incarnation fence — a LIVE pid alone is not "running" ────────────
# A reused pid (or a record with no usable start) must never read as running: 'running' is a claim
# about THIS run, not about a number.
RD="$RAIL_RUN_DIR/agent-infra/pr-108/$(date -u +%Y%m%dT%H%M%SZ)-fence"
mkdir -p "$RD"; printf '%s\n' "$$" > "$RD/pid"; printf '%s\n' "0" > "$RD/start"
printf '\n' > "$RD/repo"; : > "$RD/log"
printf '%s\n' "$(basename "$RD")" > "$RAIL_RUN_DIR/agent-infra/pr-108/latest"
OUT="$(GH_MODE=open poll 108)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "FENCE: a live pid with an unusable incarnation ABSTAINS (25)"
assert_not_contains "$TXT" "running" "FENCE: a live pid alone never reads as running"

# ── J: a corrupt exit-status file is not a verdict ──────────────────────────
RD="$RAIL_RUN_DIR/agent-infra/pr-109/$(date -u +%Y%m%dT%H%M%SZ)-corrupt"
mkdir -p "$RD"; printf '\n' > "$RD/repo"; : > "$RD/log"; printf 'not-a-number\n' > "$RD/rc"
printf '%s\n' "$(basename "$RD")" > "$RAIL_RUN_DIR/agent-infra/pr-109/latest"
OUT="$(GH_MODE=open poll 109)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "CORRUPT-RC: exit code 25"
assert_not_contains "$TXT" "landed" "CORRUPT-RC: never read as a landing"

# ── K: no-run is its own state ──────────────────────────────────────────────
OUT="$(poll 999)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 24 "$RC" "NO-RUN: exit code 24"
assert_state "$TXT" no-run "NO-RUN: nothing was ever started for this PR"
OUT="$(poll 999 --run nope)"; assert_rc 24 "${OUT%%|*}" "NO-RUN: an unknown --run id is no-run, not the newest run"

# ── L: --run pins ATTRIBUTION — an old run id never reports the newest run ──
GH_MODE=open FAKE_RAIL_RC=1 call start 110 >/dev/null
RID_A="$(cat "$RAIL_RUN_DIR/agent-infra/pr-110/latest")"
OUT="$(GH_MODE=open wait_state refused 110 --run "$RID_A")"; assert_rc 20 "${OUT%%|*}" "ATTRIBUTION: run A refuses"
GH_MODE=merged FAKE_RAIL_RC=0 call start 110 >/dev/null
OUT="$(GH_MODE=merged wait_state landed 110)"; assert_rc 0 "${OUT%%|*}" "ATTRIBUTION: run B (the newest) lands"
OUT="$(GH_MODE=open poll 110 --run "$RID_A")"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 20 "$RC" "ATTRIBUTION: polling run A still reports A's refusal"
assert_contains "$TXT" "run=$RID_A" "ATTRIBUTION: and names run A, not the newest run"

# ── M: session isolation is MEASURED — 'shared' is named, never assumed away ─
OUT="$(RAIL_RUN_NO_SETSID=1 call start 111)"; TXT="${OUT#*|}"
assert_contains "$TXT" "session=shared" "ISOLATION: RAIL_RUN_NO_SETSID=1 reports session=shared"
assert_contains "$TXT" "WILL reach it" "ISOLATION: the shared-group residual risk is named, not hidden"
OUT="$(GH_MODE=merged wait_state landed 111)"; assert_rc 0 "${OUT%%|*}" "ISOLATION: a shared-session run is still polled to a verdict"

# ── Z: a stale TERMINAL run does not block a new start ─────────────────────
OUT="$(GH_MODE=open call start 105)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "STALE: a finished earlier run does not block a new start (its dir is evidence, not a lock)"

# ── Y: PASS-THROUGH and --repo reach the rail verbatim, and --repo keys the state ───────────────
# The rail needs its args intact (`--repo owner/repo` is how a lane merges another repo), and the
# run key must follow that same slug so `status` from another checkout finds this run.
OUT="$(FAKE_RAIL_SLEEP=6 call start 112 --no-rerun --repo acme/widgets)"; TXT="${OUT#*|}"
assert_contains "$TXT" "repo=acme/widgets" "ARGS: --repo is honoured and echoed"
# END, not NR==1: the fake rail's log accumulates across arms, so only the LAST line is this run's.
RAIL_ARGV="$(awk 'END{print}' "$FAKE_RAIL_LOG" 2>/dev/null)"
if [ "$RAIL_ARGV" = "112 --no-rerun --repo acme/widgets" ]; then
  ok "ARGS: the rail received the PR, its own flags and --repo in order"
else bad "ARGS: the rail received '$RAIL_ARGV'"; fi
if [ -d "$RAIL_RUN_DIR/acme-widgets/pr-112" ]; then ok "ARGS: the run key follows the --repo slug"
else bad "ARGS: no run state under acme-widgets/pr-112"; fi
OUT="$(poll 112 --repo acme/widgets)"; assert_rc 10 "${OUT%%|*}" "ARGS: status finds the run by the SAME slug"
OUT="$(poll 112)"; assert_rc 24 "${OUT%%|*}" "ARGS: without --repo it is a DIFFERENT key (no silent cross-repo read)"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
