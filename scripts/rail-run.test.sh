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
# The interpreter is resolved ONCE and called by absolute path: one arm puts a `bash` stub first on
# PATH to make the launcher's own spawn fail, and that stub must not replace the test's interpreter.
BASH_BIN="${BASH:-$(command -v bash)}"

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
# The repo identity is PINNED, so the suite does not depend on this checkout's `origin`: it is a
# canonical part of the key (`start 5` and `start 5 --repo fake/repo` converge), and the gh double
# echoes it back as the URL that pr_state verifies.
export RAIL_RUN_REPO_SLUG="fake/repo"
export FAKE_RAIL_COUNT="$T/rail-count.txt"
export FAKE_RAIL_LOG="$T/rail-was-called.log"
mkdir -p "$T/bin"
: > "$FAKE_RAIL_COUNT"; : > "$FAKE_RAIL_LOG"

# ── the fake rail ─────────────────────────────────────────────────────────────
# FAKE_RAIL_SLEEP      seconds to spend "waiting on CI" (one log line per second: log GROWTH)
# FAKE_RAIL_RC         the exit status it finally returns (default 0)
# FAKE_RAIL_REFUSAL    when set, it prints the rail's own red-tree refusal sentence
# FAKE_RAIL_PIDFILE    where it records its own pid (so a test can signal the RAIL, not the recorder)
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
# GH_MODE: merged (default) | open | fail | wrongrepo
# It answers with the SAME shape the real `gh pr view --json state,mergedAt,url --jq` produces, and
# the URL names the (repo, PR) it was ASKED for — so the identity check in pr_state is exercised
# rather than bypassed. `wrongrepo` answers MERGED for a DIFFERENT repository: the case that must
# never read as this PR's landing (#2235).
cat > "$T/bin/gh" <<'GHD'
#!/usr/bin/env bash
repo=""; pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --json|--jq) shift 2 ;;
    pr|view) shift ;;
    *) [ -z "$pr" ] && pr="$1"; shift ;;
  esac
done
url="https://github.com/${repo:-ambient/ambient}/pull/${pr:-0}"
case "${GH_MODE:-merged}" in
  merged) printf 'MERGED 2026-10-27T03:56:04Z %s\n' "$url" ;;
  open)   printf 'OPEN - %s\n' "$url" ;;
  wrongrepo) printf 'MERGED 2026-10-27T03:56:04Z https://github.com/someone/else/pull/%s\n' "$pr" ;;
  otherhost) printf 'MERGED 2026-10-27T03:56:04Z https://ghe.example.com/%s/pull/%s\n' "${repo:-x/y}" "$pr" ;;
  fail)   printf 'HTTP 502: bad gateway\n' >&2; exit 1 ;;
esac
GHD
chmod +x "$T/bin/gh"

# ── helpers ───────────────────────────────────────────────────────────────────
call() { # <verb> [args...] -> "<rc>|<output>"
  local out rc=0
  out="$("$BASH_BIN" "$RR" "$@" 2>&1)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
poll() { call status "$@"; }
wait_state() { # <want-state> <pr> (--run id) — poll until the state word matches (bounded)
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
rundir() { printf '%s/fake-repo/pr-%s/%s' "$RAIL_RUN_DIR" "$1" "$2"; }
last_argv() { awk 'END{print}' "$FAKE_RAIL_LOG" 2>/dev/null; }
rd_field() { cat "$1/$2" 2>/dev/null | tr -d '\n'; }   # a run-dir field, empty when absent
rail_invocations() { awk -v p="$1" 'index($0, p " ") == 1 || $0 == p {n++} END{print n+0}' "$FAKE_RAIL_LOG" 2>/dev/null; }
craft() { # <pr> <run-name> [k=v ...] — a hand-built run dir, for states no launch can reach
  local pr="$1" name="$2"; shift 2
  local rd="$RAIL_RUN_DIR/fake-repo/pr-$pr/$name"
  mkdir -p "$rd"; printf 'fake/repo\n' > "$rd/repo"
  printf 'admin-merge: … hand-built fixture\n' > "$rd/log"
  printf '%s\n' "$name" > "$RAIL_RUN_DIR/fake-repo/pr-$pr/latest"
  local kv k v
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"; printf '%s\n' "$v" > "$rd/$k"; done
  printf '%s' "$rd"
}

printf '=== rail-run.sh — start/poll, first-class states (#2885) ===\n'

# ── usage ─────────────────────────────────────────────────────────────────────
OUT="$(call)"; assert_rc 2 "${OUT%%|*}" "USAGE: no verb exits 2"
OUT="$(poll abc)"; assert_rc 2 "${OUT%%|*}" "USAGE: a non-numeric PR is refused before it reaches a path"
OUT="$(call start 0)"; assert_rc 2 "${OUT%%|*}" "USAGE: PR 0 is refused"
OUT="$(poll 5 --bogus)"; assert_rc 2 "${OUT%%|*}" "USAGE: an unexpected status argument is refused, not ignored"
OUT="$(RAIL_RUN_RAIL=/nonexistent/rail call start 5)"; assert_rc 2 "${OUT%%|*}" "USAGE: a missing rail is refused before any state is written"

# ── A: start RETURNS IMMEDIATELY, and the run reads `running` ────────────────
SECONDS=0
OUT="$(FAKE_RAIL_SLEEP=8 call start 101)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
ELAPSED=$SECONDS
assert_rc 0 "$RC" "START: exits 0"
if [ "$ELAPSED" -lt 3 ]; then ok "START: returns at once while the rail waits 8s (elapsed ${ELAPSED}s)"
else bad "START: blocked for ${ELAPSED}s — it must not wait on the rail"; fi
assert_contains "$TXT" "session=own" "START: the recorder is in its OWN session (measured, not claimed)"
assert_contains "$TXT" "poll:" "START: prints the exact poll command"
assert_contains "$TXT" "--run" "START: the printed poll command pins the RUN ID (not merely the newest run)"
RUN1="$(run_id_of "$OUT")"
if [ -n "$RUN1" ] && [ -d "$(rundir 101 "$RUN1")" ]; then
  ok "START: records a run dir (run=$RUN1)"
else bad "START: no run dir for run='$RUN1'"; fi
for f in pid start rail railpid railstart repo started args log; do
  [ -s "$(rundir 101 "$RUN1")/$f" ] || bad "START: $f was not recorded"
done
# ⛔ THE RAIL'S OWN ARGV IS ASSERTED, not assumed. `start_rail` shifts the PR off `$@` before it
# spawns, and a spawn that forwards only the REMAINDER reaches the rail PR-less — it then logs
# "a PR number is required" and exits 2, so every run would analyse nothing while the state machine
# reported a clean refusal. Found by a real-rail smoke run; this arm is why it cannot come back.
RAIL_ARGV="$(last_argv)"
# The PR is the FIRST argument (it was shifted off `$@`, and forwarding only the remainder made the
# rail log `a PR number is required`), and the resolved identity rides along so the rail's TARGET and
# the run's RECORD are one value by construction.
if [ "$RAIL_ARGV" = "101 --repo fake/repo" ]; then
  ok "ARGV: the rail received the PR first AND the resolved identity"
else bad "ARGV: the rail received '$RAIL_ARGV' (want '101 --repo fake/repo')"; fi
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
assert_contains "$TXT" "may still be alive" "DUPLICATE: says the existing run may still be alive"
N="$(wc -l < "$FAKE_RAIL_COUNT" | tr -d '[:space:]')"
assert_rc 1 "$N" "DUPLICATE: exactly ONE rail invocation ever reached the rail"

# ── B2: two CONCURRENT starts still produce ONE rail (the claim is atomic) ───
# Without an atomic claim this is check-then-act: both probe, both see nothing, both launch, and the
# PR gets TWO merge attempts. Sequential arms cannot see that, so this one races the two starts.
( RAIL_RUN_RAIL="$T/bin/rail" "$BASH_BIN" "$RR" start 301 > "$T/c1.out" 2>&1; echo $? > "$T/c1.rc" ) &
( RAIL_RUN_RAIL="$T/bin/rail" "$BASH_BIN" "$RR" start 301 > "$T/c2.out" 2>&1; echo $? > "$T/c2.rc" ) &
wait
CONC="$(rail_invocations 301)"
assert_rc 1 "$CONC" "CONCURRENT: two racing starts reach the rail exactly ONCE"
C1="$(cat "$T/c1.rc" 2>/dev/null || echo x)"; C2="$(cat "$T/c2.rc" 2>/dev/null || echo x)"
if { [ "$C1" = 0 ] && [ "$C2" = 3 ]; } || { [ "$C1" = 3 ] && [ "$C2" = 0 ]; }; then
  ok "CONCURRENT: exactly one start won (rc=0) and the other refused (rc=3)"
else bad "CONCURRENT: want one rc=0 and one rc=3, got rc=$C1 and rc=$C2"; fi
RD301="$(rundir 301 "$(cat "$RAIL_RUN_DIR/fake-repo/pr-301/latest")")"
PIDS+=("$(cat "$RD301/pid" 2>/dev/null || true)" "$(cat "$RD301/railpid" 2>/dev/null || true)")

# ── C: refused — the rail's own words and its own exit status ────────────────
OUT="$(FAKE_RAIL_REFUSAL='python shards 3 of 8 failed' FAKE_RAIL_RC=1 call start 102)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "REFUSED: start exits 0 (the launch started; the verdict comes from status)"
OUT="$(GH_MODE=open wait_state refused 102)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 20 "$RC" "REFUSED: exit code 20"
assert_state "$TXT" refused "REFUSED: the state word is 'refused'"
assert_contains "$TXT" "python shards 3 of 8 failed" "REFUSED: quotes the rail's own refusal line"
assert_not_contains "$TXT" "landed" "REFUSED: never reported as landed"

# ── C2: rc=1 with NO refusal line is an ERROR, not a verdict about the head ──
# admin-merge.sh also exits 1 when it could not READ what it needed (an unreadable head/draft probe, a
# missing parser, a failed cd). Claiming "refused this head" there sends a lane hunting a code defect
# that was never analysed.
FAKE_RAIL_RC=1 call start 121 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 121)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" 'ERROR-RC: rc=1 with no `admin-merge: ✗` line ABSTAINS (25)'
assert_state "$TXT" unknown "ERROR-RC: the state word is 'unknown', not 'refused'"
assert_not_contains "$TXT" "it refused this head" "ERROR-RC: never claims a refusal it cannot show"

# ── D: killed — the rail died of a SIGNAL, which is neither a refusal nor a landing
FAKE_RAIL_PIDFILE="$T/rail-pid.txt" FAKE_RAIL_SLEEP=30 call start 103 >/dev/null
RD103="$(rundir 103 "$(cat "$RAIL_RUN_DIR/fake-repo/pr-103/latest")")"
PIDS+=("$(cat "$RD103/pid" 2>/dev/null || true)")
i=0; while [ ! -s "$T/rail-pid.txt" ] && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
RAILPID="$(cat "$T/rail-pid.txt" 2>/dev/null || true)"
PIDS+=("$RAILPID")
if [ -n "$RAILPID" ]; then kill -TERM "$RAILPID" 2>/dev/null; else bad "KILLED: the fake rail never recorded a pid"; fi
OUT="$(GH_MODE=open wait_state killed 103)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 21 "$RC" "KILLED: exit code 21"
assert_contains "$TXT" "SIGTERM" "KILLED: names the signal that ended it"
assert_not_contains "$TXT" "landed" "KILLED: never reported as landed"

# ── D2/D3: a SIGNAL DEATH with an unreadable PR state is NOT a verdict ───────
# `killed` is a claim about the rail; landing is a claim about the PR. If the artifact cannot be read
# the second is unknown, and asserting `killed` over a possibly-merged PR is the wrong direction.
OUT="$(craft 131 dead-rail rc=143)"; RAILDIR="$OUT"
OUT="$(GH_MODE=fail poll 131)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "KILL+UNREAD: rc=143 with an unreadable PR state ABSTAINS (25)"
assert_not_contains "$TXT" "killed" "KILL+UNREAD: never claims a kill verdict over an unread artifact"
OUT="$(craft 132 dead-err rc=1)"; 
OUT="$(GH_MODE=fail poll 132)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "REFUSE+UNREAD: rc=1 with an unreadable PR state ABSTAINS (25)"
assert_not_contains "$TXT" "refused" "REFUSE+UNREAD: never claims a refusal over an unread artifact"

# ── D4: rc≠0 + MERGED — the artifact outranks a written non-zero status ─────
craft 133 merged-nonzero rc=1 >/dev/null
OUT="$(GH_MODE=merged poll 133)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "NONZERO+MERGED: exit code 0 (the PR is merged)"
assert_contains "$TXT" "verdict=artifact" "NONZERO+MERGED: attributed to the artifact, not to a rail success"

# ── E: landed — the rail's OWN verdict (rc=0 AND the artifact agree) ─────────
OUT="$(GH_MODE=merged call start 104)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "LANDED: start exits 0"
OUT="$(GH_MODE=merged wait_state landed 104)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
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
assert_not_contains "$TXT" "verdict=rail" "UNKNOWN: an unread artifact is NOT a rail verdict"
assert_not_contains "$TXT" "verdict=artifact" "UNKNOWN: an unread artifact is NOT an artifact verdict"
assert_not_contains "$TXT" "it refused this head" "UNKNOWN: an unread artifact is NOT a refusal"

# ── H: the RECORDER dies, the RAIL lives → still `running` ──────────────────
# #2885's inversion: a SIGKILLed recorder writes nothing while the rail keeps running AND can still
# merge. "The recorder is gone" must never be read as "nothing is running".
FAKE_RAIL_PIDFILE="$T/rail-pid2.txt" FAKE_RAIL_SLEEP=30 call start 107 >/dev/null
RD107="$(rundir 107 "$(cat "$RAIL_RUN_DIR/fake-repo/pr-107/latest")")"
REC="$(cat "$RD107/pid" 2>/dev/null || true)"
PIDS+=("$REC" "$(cat "$T/rail-pid2.txt" 2>/dev/null || true)")
if [ -n "$REC" ]; then kill -9 "$REC" 2>/dev/null; fi
OUT="$(GH_MODE=open wait_state running 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 10 "$RC" "RECORDER-GONE: the RAIL is still alive, so the run is STILL RUNNING (10)"
assert_contains "$TXT" "RAIL is still running" "RECORDER-GONE: says the RAIL is what is still alive"

# ── H2: BOTH gone, no exit status → gone-without-verdict (the missing state) ─
if [ -s "$T/rail-pid2.txt" ]; then kill -9 "$(cat "$T/rail-pid2.txt")" 2>/dev/null; fi
OUT="$(GH_MODE=open wait_state gone-without-verdict 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 22 "$RC" "GONE: exit code 22"
assert_state "$TXT" gone-without-verdict "GONE: no exit status + recorder and rail gone is its OWN state"
assert_not_contains "$TXT" "landed" "GONE: never reported as landed"
assert_contains "$TXT" "NO VERDICT" "GONE: says plainly that this run produced no verdict"

# ── H1b: BOTH gone but the artifact UNREADABLE → unknown, never a terminal no-verdict ─
# `gone-without-verdict` is a terminal claim about the run, so it needs the artifact read to have
# succeeded. A poller branching on 22 must not record "no verdict" for a head it could not read.
OUT="$(GH_MODE=fail wait_state unknown 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "GONE+UNREAD: no exit status, nothing alive, artifact unread → unknown (25)"
assert_contains "$TXT" "artifact=unread" "GONE+UNREAD: says the artifact read abstained"
assert_not_contains "$TXT" "gone-without-verdict" "GONE+UNREAD: never a terminal no-verdict claim"

# ── H3: the same gone run, PR MERGED → landed=artifact ─────────────────────
# The artifact outranks the exit status: reporting 'gone' over a real merge is the wrong direction.
OUT="$(GH_MODE=merged poll 107)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "GONE+MERGED: exit code 0"
assert_contains "$TXT" "verdict=artifact" "GONE+MERGED: attributed to the ARTIFACT, not to this run"
assert_contains "$TXT" "no rail verdict" "GONE+MERGED: still says this run produced no rail verdict"

# ── R: THE IDENTITY OF THE ARTIFACT READ ──────────────────────────────────
# `gh pr view <N>` resolves a bare number against ambient GH_REPO or the caller's cwd, so a merged PR
# with the SAME NUMBER in ANOTHER repo can read as this one's landing. That is terminal news: it stops
# a lane driving a PR that is not merged. The read must name the repo AND the PR.
craft 150 wrongid rc=0 >/dev/null
OUT="$(GH_MODE=wrongrepo poll 150)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "IDENTITY: a MERGED read whose url names ANOTHER repo is not a landing"
assert_state "$TXT" unknown "IDENTITY: it abstains instead"
assert_contains "$TXT" "artifact=unread" "IDENTITY: and says the artifact read abstained"
# and the same run reads `landed` once the URL names this PR — the check discriminates, not the mode
OUT="$(GH_MODE=merged poll 150)"; assert_rc 0 "${OUT%%|*}" "IDENTITY: the SAME run reads landed when the url names this repo+PR"
# …and with NO identity ANYWHERE (no pin, no origin, no record) the read abstains: it cannot know
# which repo the number belongs to, and guessing is what produces a false `landed`.
# ⛔ THE ARM MUST DISCRIMINATE. Asserting only `no-run` passes for ANY key, including the single
# constant the old code hashed every non-git cwd to (`nogit`) — so TWO different directories are
# polled and the KEYS are compared: a per-directory hash gives two different `repo-…` keys.
mkdir -p "$T/scratch-id" "$T/scratch-id2"
ID_OUT="$(cd "$T/scratch-id" && RAIL_RUN_REPO_SLUG= "$BASH_BIN" "$RR" status 501 2>&1)"
ID_OUT2="$(cd "$T/scratch-id2" && RAIL_RUN_REPO_SLUG= "$BASH_BIN" "$RR" status 501 2>&1)"
assert_contains "$ID_OUT" "no-run" "IDENTITY: with no resolvable identity the key is a per-directory hash"
ID_KEY1="$(field "$ID_OUT" repo)"; ID_KEY2="$(field "$ID_OUT2" repo)"
case "$ID_KEY1" in repo-*) ok "IDENTITY: the key is a HASH, not a constant" ;; *) bad "IDENTITY: key='$ID_KEY1' (want repo-<hash>)" ;; esac
if [ -n "$ID_KEY1" ] && [ "$ID_KEY1" != "$ID_KEY2" ]; then ok "IDENTITY: two directories never share one key"
else bad "IDENTITY: both directories keyed '$ID_KEY1' — one constant for many repos"; fi

# ── S: a `✗` line can be a READ FAILURE, which is not a verdict about the head ──
cat > "$T/bin/rail-unreadable" <<'UNR'
#!/usr/bin/env bash
printf 'admin-merge: ✗ BLOCK [head_unreadable] [rate_limited] — could not READ the head of PR #152\n'
exit 1
UNR
chmod +x "$T/bin/rail-unreadable"
# ⛔ THE FIXTURE IS WRITTEN BEFORE THE START THAT NEEDS IT. This start used to run against a rail that
# did not exist yet, so it died "no rail at …" with its output discarded and nothing ever exercised
# PR 152 — a dead arm that read like coverage.
START_152="$(RAIL_RUN_RAIL="$T/bin/rail-unreadable" call start 152)"; RC="${START_152%%|*}"
assert_rc 0 "$RC" "READ-FAILURE: a run starts against a rail whose head read fails"
assert_contains "${START_152#*|}" "started pr=152" "READ-FAILURE: and it records a run for that PR"
START_OUT="$(RAIL_RUN_RAIL="$T/bin/rail-unreadable" call start 153)"; RC="${START_OUT%%|*}"
assert_rc 0 "$RC" "READ-FAILURE: the run starts against a rail that will fail to read"
# GH_MODE=open: with a MERGED artifact the merge wins over ANY rail failure, so the ✗ line only
# decides when the artifact is not already a landing.
OUT="$(GH_MODE=open wait_state unknown 153)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "READ-FAILURE: a ✗ BLOCK [head_unreadable] is NOT a refusal of this head"
assert_state "$TXT" unknown "READ-FAILURE: it abstains"
assert_contains "$TXT" "did not judge your change" "READ-FAILURE: and says the run never judged the change"
assert_not_contains "$TXT" "refused this head" "READ-FAILURE: never claims a refusal"

# ── T: the run-record bound — an abstaining record cannot block the PR forever ──
craft 154 oldfence pid=$$ start=0 >/dev/null
OUT="$(call start 154)"; assert_rc 3 "${OUT%%|*}" "RECORD: an abstaining (off-fence) record blocks a young start"
touch -t 202001010000 "$(rundir 154 oldfence)"
OUT="$(FAKE_RAIL_SLEEP=6 call start 154)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "RECORD: the same record past RAIL_RUN_RECORD_MAX does NOT block — no PR is un-startable forever"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-154/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── U: a recorder that abstains, with a RAIL that is provably alive → running ──
FAKE_RAIL_PIDFILE="$T/rail-pid3.txt" FAKE_RAIL_SLEEP=20 call start 155 >/dev/null
RD155="$(rundir 155 "$(cat "$RAIL_RUN_DIR/fake-repo/pr-155/latest")")"
printf '%s\n' "$$" > "$RD155/pid"; printf '0\n' > "$RD155/start"     # recorder fence unusable
PIDS+=("$(cat "$T/rail-pid3.txt" 2>/dev/null || true)")
OUT="$(wait_state running 155)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 10 "$RC" "RAIL-ALIVE: the recorder abstains but the RAIL is alive → running (10)"
assert_contains "$TXT" "recorder=abstained" "RAIL-ALIVE: says which incarnation carried the evidence"

# ── V: one PR, one key — the two documented spellings converge ───────────────
FAKE_RAIL_SLEEP=8 call start 156 --repo fake/repo >/dev/null
OUT="$(poll 156)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 10 "$RC" "CONVERGE: a poll WITHOUT --repo finds the run started WITH it (one key per repo)"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-156/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── W: no git, no pin — the fallback key is per-DIRECTORY, not one constant ──
mkdir -p "$T/scratch-a" "$T/scratch-b"
KEY_A="$(cd "$T/scratch-a" && RAIL_RUN_REPO_SLUG= "$BASH_BIN" "$RR" status 500 2>&1 | sed -n 's/.*repo=\([^ ]*\).*/\1/p')"
KEY_B="$(cd "$T/scratch-b" && RAIL_RUN_REPO_SLUG= "$BASH_BIN" "$RR" status 500 2>&1 | sed -n 's/.*repo=\([^ ]*\).*/\1/p')"
if [ -n "$KEY_A" ] && [ "$KEY_A" != "$KEY_B" ]; then
  ok "NOGIT: two non-git directories get DIFFERENT keys ($KEY_A vs $KEY_B)"
else bad "NOGIT: the fallback key is shared ($KEY_A vs $KEY_B) — one scratch run could be read as another's"; fi

# ── I: the incarnation fence — a LIVE pid alone is not "running" ────────────
# A reused pid (or a record with no usable start) must never read as running: 'running' is a claim
# about THIS run, not about a number. A MERGED artifact still wins over the abstention.
craft 108 fence pid="$$" start=0 >/dev/null
OUT="$(GH_MODE=open poll 108)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "FENCE: a live pid with an unusable incarnation ABSTAINS (25)"
assert_not_contains "$TXT" "running" "FENCE: a live pid alone never reads as running"
craft 118 fence-merged pid="$$" start=0 >/dev/null
OUT="$(GH_MODE=merged poll 118)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "FENCE+MERGED: the ARTIFACT wins over the liveness abstention (0)"
assert_contains "$TXT" "verdict=artifact" "FENCE+MERGED: attributed to the artifact"

# ── I2: no incarnation recorded at all → abstention, NOT a death witness ────
craft 119 empty-dir >/dev/null
OUT="$(GH_MODE=open poll 119)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "NO-INCARNATION: an absent record ABSTAINS instead of reading as gone (25)"
assert_not_contains "$TXT" "gone-without-verdict" "NO-INCARNATION: never a death witness"

# ── J: a corrupt exit-status file is not a verdict ──────────────────────────
craft 109 corrupt rc=not-a-number >/dev/null
OUT="$(GH_MODE=open poll 109)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "CORRUPT-RC: exit code 25"
assert_not_contains "$TXT" "landed" "CORRUPT-RC: never read as a landing"

# ── K: no-run is its own state ──────────────────────────────────────────────
OUT="$(poll 999)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 24 "$RC" "NO-RUN: exit code 24"
assert_state "$TXT" no-run "NO-RUN: nothing was ever started for this PR"
OUT="$(poll 999 --run nope)"; assert_rc 24 "${OUT%%|*}" "NO-RUN: an unknown --run id is no-run, not the newest run"

# ── L: --run pins ATTRIBUTION — an old run id never reports the newest run ──
GH_MODE=open FAKE_RAIL_RC=1 FAKE_RAIL_REFUSAL='run A refused' call start 110 >/dev/null
RID_A="$(cat "$RAIL_RUN_DIR/fake-repo/pr-110/latest")"
OUT="$(GH_MODE=open wait_state refused 110 --run "$RID_A")"; assert_rc 20 "${OUT%%|*}" "ATTRIBUTION: run A refuses"
GH_MODE=merged FAKE_RAIL_RC=0 call start 110 >/dev/null
OUT="$(GH_MODE=merged wait_state landed 110)"; assert_rc 0 "${OUT%%|*}" "ATTRIBUTION: run B (the newest) lands"
OUT="$(GH_MODE=open poll 110 --run "$RID_A")"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 20 "$RC" "ATTRIBUTION: polling run A still reports A's refusal"
assert_contains "$TXT" "run=$RID_A" "ATTRIBUTION: and names run A, not the newest run"
OUT="$(GH_MODE=open poll 110 --run="$RID_A")"; assert_rc 20 "${OUT%%|*}" "ATTRIBUTION: the --run=<id> spelling works too"

# ── M: session isolation is MEASURED — 'shared' is named, never assumed away ─
# The rail is made to WAIT, exactly as arm A does: the session word is measured from the RECORDER's
# process group, and a rail that exits instantly takes the recorder with it, so the honest answer is
# `unknown` (an abstention) rather than the `shared` this arm is about. Keep the recorder alive across
# the measurement so the arm discriminates the NO_SETSID path instead of racing process exit.
OUT="$(RAIL_RUN_NO_SETSID=1 FAKE_RAIL_SLEEP=3 call start 111)"; TXT="${OUT#*|}"
assert_contains "$TXT" "session=shared" "ISOLATION: RAIL_RUN_NO_SETSID=1 reports session=shared"
assert_contains "$TXT" "WILL reach it" "ISOLATION: the shared-group residual risk is named, not hidden"
OUT="$(GH_MODE=merged wait_state landed 111)"; assert_rc 0 "${OUT%%|*}" "ISOLATION: a shared-session run is still polled to a verdict"

# ── N: exit 5 — a spawn that dies without recording a pid is SAID, not reported as a run
mkdir -p "$T/badbash"
printf '#!/bin/sh\nexit 3\n' > "$T/badbash/bash"; chmod +x "$T/badbash/bash"
OUT="$(PATH="$T/badbash:$PATH" call start 114)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 5 "$RC" "LAUNCH: a spawn that records no pid exits 5"
assert_contains "$TXT" "no pid was recorded within 5s" "LAUNCH: says the launch FAILED (and calls it a timeout)"
OUT="$(poll 114)"; assert_rc 24 "${OUT%%|*}" "LAUNCH: and nothing is left claiming a live run (the claim was released)"

# ── O: --repo=<slug> inline form keys the state and reaches the rail ────────
OUT="$(FAKE_RAIL_SLEEP=6 call start 115 --no-rerun --repo=acme/widgets)"; TXT="${OUT#*|}"
assert_contains "$TXT" "repo=acme/widgets" "ARGS: the --repo=<slug> form is honoured and echoed"
RAIL_ARGV="$(last_argv)"
# THE RAIL ONLY PARSES THE TWO-TOKEN FORM: given the `=` spelling it forwards the token onward and
# resolves its TARGET from the checkout (measured against the real script), so the record would claim a
# repo the run never touched. The rewrite is what keeps the record and the rail's target the same repo.
if [ "$RAIL_ARGV" = "115 --no-rerun --repo acme/widgets" ]; then
  ok "ARGS: the rail received the PR, its own flags and --repo in order"
else bad "ARGS: the rail received '$RAIL_ARGV'"; fi
if [ -d "$RAIL_RUN_DIR/acme-widgets/pr-115" ]; then ok "ARGS: the run key follows the --repo slug"
else bad "ARGS: no run state under acme-widgets/pr-115"; fi
OUT="$(poll 115 --repo acme/widgets)"; assert_rc 10 "${OUT%%|*}" "ARGS: status finds the run by the SAME slug"
OUT="$(poll 115)"; assert_rc 24 "${OUT%%|*}" "ARGS: without --repo it is a DIFFERENT key (no silent cross-repo read)"

# ── P: the CLAIM window is in flight, not dead ─────────────────────────────
# The claim dir exists for a few instructions before its `pid` is written. Reading that window as
# "no owner" let a second start DELETE a live claim and launch a second rail — the race the claim
# exists to close, re-opened inside the guard.
CLAIMDIR="$RAIL_RUN_DIR/fake-repo/pr-140/.starting"
mkdir -p "$CLAIMDIR"
OUT="$(call start 140)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 3 "$RC" "CLAIM-WINDOW: a claim with no pid YET refuses the start (in flight)"
assert_contains "$TXT" "has just begun" "CLAIM-WINDOW: says the other start has just begun"
touch -t 202001010000 "$CLAIMDIR"
OUT="$(FAKE_RAIL_SLEEP=6 call start 140)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 0 "$RC" "CLAIM-STALE: a claim older than the bound is cleared and the start proceeds"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-140/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")
# a claim whose recorded pid is ALIVE and off-fence (rc 2) blocks while young, clears when old
CLAIMDIR="$RAIL_RUN_DIR/fake-repo/pr-141/.starting"
mkdir -p "$CLAIMDIR"; printf '%s\n' "$$" > "$CLAIMDIR/pid"; printf '0\n' > "$CLAIMDIR/start"
OUT="$(call start 141)"; assert_rc 3 "${OUT%%|*}" "CLAIM-FENCE: an UNVERIFIABLE young claim blocks"
touch -t 202001010000 "$CLAIMDIR"
OUT="$(FAKE_RAIL_SLEEP=6 call start 141)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "CLAIM-FENCE: an old unverifiable claim cannot block this PR forever"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-141/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")
# a run record that is LIVE but has recorded NO incarnation yet (launch in progress) blocks too
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-142/inflight"
printf '\n' > "$RAIL_RUN_DIR/fake-repo/pr-142/inflight/repo"
: > "$RAIL_RUN_DIR/fake-repo/pr-142/inflight/log"
printf 'inflight\n' > "$RAIL_RUN_DIR/fake-repo/pr-142/latest"
OUT="$(call start 142)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 3 "$RC" "IN-FLIGHT: a run whose launch has not recorded an incarnation yet blocks a second rail"
assert_contains "$TXT" "may still be alive" "IN-FLIGHT: and says so, rather than reporting no-run"
touch -t 202001010000 "$RAIL_RUN_DIR/fake-repo/pr-142/inflight"
OUT="$(FAKE_RAIL_SLEEP=6 call start 142)"; assert_rc 0 "${OUT%%|*}" "IN-FLIGHT: an abandoned record older than the bound does not block"

# ── AA: `--` stops identity capture, and the identity still reaches the rail exactly once ──────
OUT="$(FAKE_RAIL_SLEEP=6 call start 149 -- --repo=other/thing)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "DD: a --repo= AFTER -- is left for the rail, not taken as the identity"
RD149="$(rundir 149 "$(cat "$RAIL_RUN_DIR/fake-repo/pr-149/latest")")"
if [ "$(rd_field "$RD149" repo)" = "fake/repo" ]; then
  ok "DD: the identity stayed the pinned one (fake/repo), not other/thing"
else bad "DD: the identity became '$(rd_field "$RD149" repo)' — a rail-side --repo leaked into it"; fi
RAIL_ARGV="$(last_argv)"
# The identity is placed BEFORE any `--` (past it the rail refuses `--repo` by name), and the
# rail-side `--repo=other/thing` after it stays untouched.
if [ "$RAIL_ARGV" = "149 --repo fake/repo -- --repo=other/thing" ]; then
  ok "DD: the identity is forwarded BEFORE -- and the rail-side --repo is left alone"
else bad "DD: unexpected rail argv '$RAIL_ARGV' (want '149 --repo fake/repo -- --repo=other/thing')"; fi
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-149/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AB: the identity is CASE-insensitive, like GitHub's own repo names ─────────────────────────
# `ACME/Widgets` (what a clone URL may spell) must be the SAME run as `acme/widgets`, or `landed` is
# unreachable for ever and a case-sensitive filesystem gets two keys (two rails) for one PR.
OUT="$(FAKE_RAIL_SLEEP=6 call start 170 --repo ACME/Widgets)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "CASE: a mixed-case slug is accepted"
OUT="$(poll 170 --repo acme/widgets)"; RC="${OUT%%|*}"
assert_rc 10 "$RC" "CASE: and the canonical lower-case spelling finds the SAME run"
RD170="$RAIL_RUN_DIR/acme-widgets/pr-170/$(cat "$RAIL_RUN_DIR/acme-widgets/pr-170/latest" 2>/dev/null)"
if [ "$(rd_field "$RD170" repo)" = "acme/widgets" ]; then ok "CASE: the record is lower-cased"
else bad "CASE: the record kept its case ('$(rd_field "$RD170" repo)') — a canonical URL would never match it"; fi
OUT="$(poll 170 --repo ACME/Widgets)"; assert_rc 10 "${OUT%%|*}" "CASE: the mixed-case spelling also finds it (one key)"
PIDS+=("$(cat "$RAIL_RUN_DIR/acme-widgets/pr-170/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AC: a `--run` that names the CLAIM dir is `no-run`, not a terminal no-verdict ─────────────
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-149/.starting"
printf '%s\n' "$$" > "$RAIL_RUN_DIR/fake-repo/pr-149/.starting/pid"
OUT="$(poll 149 --run .starting)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 24 "$RC" "NONRUN: '--run .starting' (the claim dir) is no-run, not gone-without-verdict"
assert_not_contains "$TXT" "gone-without-verdict" "NONRUN: and never a terminal no-verdict claim"

# ── AE: the bound must not depend on a readable mtime ─────────────────────────────────────────
# `record_young` falls back to the record's mtime. If an unreadable age reads as "young", an
# abstaining record blocks the PR for ever again — the exact defect the bound exists to close. So the
# fallback is exercised with a `stat` that fails: the record must be judged STALE, not young.
mkdir -p "$T/bin-nostat"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin-nostat/stat"
chmod +x "$T/bin-nostat/stat"
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-172/oldabstain"
printf '%s\n' "$$" > "$RAIL_RUN_DIR/fake-repo/pr-172/oldabstain/pid"
printf '0\n' > "$RAIL_RUN_DIR/fake-repo/pr-172/oldabstain/start"
printf 'fake/repo\n' > "$RAIL_RUN_DIR/fake-repo/pr-172/oldabstain/repo"
: > "$RAIL_RUN_DIR/fake-repo/pr-172/oldabstain/log"
printf 'oldabstain\n' > "$RAIL_RUN_DIR/fake-repo/pr-172/latest"
OUT="$(PATH="$T/bin-nostat:$PATH" FAKE_RAIL_SLEEP=6 call start 172)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "AGE: an UNREADABLE age is not 'young' — the bound still bounds"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-172/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AE2: the no-incarnation branch is bounded by the same rule ────────────────────────────────
# `prev_in_flight` bounds a record that recorded NO incarnation by the age too. With no `created` and
# an UNREADABLE mtime, "young" would block the PR for ever; it must read as stale instead.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-174/halfdead"
printf 'fake/repo\n' > "$RAIL_RUN_DIR/fake-repo/pr-174/halfdead/repo"
: > "$RAIL_RUN_DIR/fake-repo/pr-174/halfdead/log"
printf 'halfdead\n' > "$RAIL_RUN_DIR/fake-repo/pr-174/latest"
OUT="$(PATH="$T/bin-nostat:$PATH" FAKE_RAIL_SLEEP=6 call start 174)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "AGE2: a no-incarnation record with no readable age does NOT block for ever"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-174/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AE3: the CLAIM path is bounded by the SAME helper, never an inline copy of it ─────────────
# A claim whose launcher died between `mkdir` and its `pid` write, carrying no `created`, is the one
# state that can refuse every later start with NOTHING in band to clear it: the claim reads as "just
# begun" for ever and each `start` exits 3 — #8175 exactly (a stale flag a human had to hand-edit
# away). `younger_than` treats an UNREADABLE age as NOT young, so the bound still fires.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-176/.starting"
OUT="$(PATH="$T/bin-nostat:$PATH" FAKE_RAIL_SLEEP=6 call start 176)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "AGE3: a pid-less claim with NO readable age does not block the PR for ever"
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-176/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")
# …and the discriminating half: a claim that IS young still REFUSES, which is the window the claim
# exists to close. Without this arm the bound could be deleted and the suite would still be green.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-177/.starting"
printf '%s\n' "$(date +%s)" > "$RAIL_RUN_DIR/fake-repo/pr-177/.starting/created"
OUT="$(call start 177)"; assert_rc 3 "${OUT%%|*}" "AGE3: a YOUNG pid-less claim still refuses a second start"

# ── AF: the recorded HOST comes from the SAME value as the recorded slug ──────────────────────
# `--repo [HOST/]OWNER/REPO` supplies a host and `normalize_slug` keeps only the last two components.
# When the host was still read from `origin`, a GHE target named that way was recorded as
# github.com/<slug> and its artifact check demanded a URL that host never serves — `landed`
# unreachable (fail-closed, but unleanable). Assert what was RECORDED, not what a poll prints.
OUT="$(FAKE_RAIL_SLEEP=6 call start 178 --repo ghe.example.com/acme/widgets)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "HOST: a HOST-prefixed --repo starts"
HOST_RID="$(printf '%s' "${OUT#*|}" | awk '/^started /{for(i=1;i<=NF;i++){if(index($i,"run=")==1){print substr($i,5)}}}')"
REC_HOST="$(cat "$RAIL_RUN_DIR/acme-widgets/pr-178/$HOST_RID/host" 2>/dev/null)"
if [ "$REC_HOST" = "ghe.example.com" ]; then ok "HOST: the run records the host its --repo value named"
else bad "HOST: recorded host='$REC_HOST' (want ghe.example.com)"; fi
PIDS+=("$(cat "$RAIL_RUN_DIR/acme-widgets/pr-178/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")
# …and a BARE owner/repo still takes the host from `origin`, so the arm above did not replace it.
OUT="$(FAKE_RAIL_SLEEP=6 RAIL_RUN_GH_HOST=git.example.com call start 179 --repo fake/repo)"; assert_rc 0 "${OUT%%|*}" "HOST: a bare --repo still resolves its host from origin"
BARE_RID="$(printf '%s' "${OUT#*|}" | awk '/^started /{for(i=1;i<=NF;i++){if(index($i,"run=")==1){print substr($i,5)}}}')"
BARE_HOST="$(cat "$RAIL_RUN_DIR/fake-repo/pr-179/$BARE_RID/host" 2>/dev/null)"
if [ "$BARE_HOST" = "git.example.com" ]; then ok "HOST: and records it (origin's host, not a constant)"
else bad "HOST: recorded host='$BARE_HOST' (want git.example.com)"; fi
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-179/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AG: `start` validates `latest` as a path component, exactly as `status` does ──────────────
# `start` joins `latest` into a directory and probes a pid out of it, so a hand-edited or half-written
# value must not aim that probe outside the run root. The escape target here is a directory
# `prev_in_flight` WOULD judge in flight (no `rc`, no incarnation, young) — so without the guard the
# start refuses with exit 3 about a directory that is not this PR's, and with it the start proceeds.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-180" "$RAIL_RUN_DIR/escape"
printf 'fake/repo\n' > "$RAIL_RUN_DIR/escape/repo"; : > "$RAIL_RUN_DIR/escape/log"
printf '%s\n' "$(date +%s)" > "$RAIL_RUN_DIR/escape/created"
printf '../../escape\n' > "$RAIL_RUN_DIR/fake-repo/pr-180/latest"
OUT="$(FAKE_RAIL_SLEEP=6 call start 180)"; assert_rc 0 "${OUT%%|*}" "LATEST: a traversing latest is ignored by start, not probed"
if [ ! -f "$RAIL_RUN_DIR/escape/rc" ] && [ ! -f "$RAIL_RUN_DIR/escape/latest" ]; then ok "LATEST: and nothing was written outside the run root"
else bad "LATEST: the start wrote into the directory the escape named"; fi
PIDS+=("$(cat "$RAIL_RUN_DIR/fake-repo/pr-180/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")

# ── AH: the two newly-listed stems are head verdicts, and a read failure still abstains ───────
# Each is a SINGLE template whose unreadable sibling deliberately avoids the wording (see
# `require_draft`), so `refused` is positive support rather than a phrase that happens to match.
craft 181 draft rc=1 >/dev/null
printf 'admin-merge: ✗ BLOCK — PR #181 is a DRAFT, and gh refuses to merge a draft\n' > "$RAIL_RUN_DIR/fake-repo/pr-181/draft/log"
OUT="$(GH_MODE=open poll 181)"; assert_rc 20 "${OUT%%|*}" "STEM: 'PR #N is a DRAFT' is a refusal of this head"
craft 182 survived rc=1 >/dev/null
printf 'admin-merge: ✗ BLOCK — 3 failure(s) SURVIVED the re-run:\n' > "$RAIL_RUN_DIR/fake-repo/pr-182/survived/log"
OUT="$(GH_MODE=open poll 182)"; assert_rc 20 "${OUT%%|*}" "STEM: 'SURVIVED the re-run' is a refusal of this head"

# ── AD: an unrecognised `✗` line is an ABSTENTION, not a refusal ──────────────────────────────
# `refused` is a claim about a HEAD, so it needs positive support: the rail's own phrases say whether
# it judged the head or merely never got to it. #2412: the rail said "no classification attempted"
# and the PR merged four minutes later.
cat > "$T/bin/rail-noclass" <<'NOC'
#!/usr/bin/env bash
printf 'admin-merge: ✗ BLOCK — precondition unmet: run still in_progress — no classification attempted.\n'
exit 1
NOC
chmod +x "$T/bin/rail-noclass"
RAIL_RUN_RAIL="$T/bin/rail-noclass" call start 171 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 171)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HEAD-VERDICT: 'no classification attempted' is NOT a refusal of this head"
assert_state "$TXT" unknown "HEAD-VERDICT: it abstains"
assert_contains "$TXT" "NOT a refusal" "HEAD-VERDICT: and says plainly that it is not a refusal"

# ── AF: the whole base-red family abstains — the rail calls it a RE-MEASUREMENT, not a verdict ──
# `admin-merge.sh:8485` says of this family, verbatim: "The refusal is a re-measurement request,
# never a verdict on the PR", and :8433 names the remedy ("RE-MEASURE against the current base, then
# re-run the rail"). So no line in it is a judgement of the head. `HAS NOT MEASURED IT` and
# `EVALUATED AGAINST AN OLDER BASE` were listed as head verdicts, so `refused` told a lane its HEAD was
# bad while its remedy was to update the branch and re-run — the #2412 cost (a lane abandoning a
# mergeable PR) re-bought through a stem. `BASE PARENT COULD NOT BE READ` is the read failure that
# proves the stem "base is red" admits one. All three abstain. Fixtures are the rail's own lines.
mk_rail() { printf '#!/usr/bin/env bash\nprintf "admin-merge: ✗ BLOCK — %s\\n" %s\nexit 1\n' "$2" "'$3'" > "$T/bin/rail-$1"; chmod +x "$T/bin/rail-$1"; }
mk_rail basesurface "THE BASE IS RED AND THIS PR HAS NOT MEASURED IT (a STALE surface)." x
mk_rail baselag "THE BASE IS RED AND THIS PR WAS EVALUATED AGAINST AN OLDER BASE (a LAGGING MERGE REF)." x
mk_rail baseunread "THE BASE IS RED AND THE MERGE REF'S BASE PARENT COULD NOT BE READ." x
RAIL_RUN_RAIL="$T/bin/rail-basesurface" call start 160 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 160)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "BASE-RED: 'HAS NOT MEASURED IT' is a RE-MEASUREMENT request, not a head verdict"
assert_contains "$TXT" "HAS NOT MEASURED IT" "BASE-RED: the abstention still prints the rail's own line (the reader can act on it)"
RAIL_RUN_RAIL="$T/bin/rail-baselag" call start 161 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 161)"; assert_rc 25 "${OUT%%|*}" "BASE-RED: 'EVALUATED AGAINST AN OLDER BASE' also abstains (re-measure, do not abandon)"
RAIL_RUN_RAIL="$T/bin/rail-baseunread" call start 162 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 162)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "BASE-RED: 'BASE PARENT COULD NOT BE READ' is NOT a head verdict"
assert_state "$TXT" unknown "BASE-RED: it abstains"

# ── AF2: a MISCONFIGURATION and a CALLER FLAG are not head verdicts either — and the TREE and the
# CONFLICT still are. Every kept stem is pinned here, so deleting one reddens this block (the doc
# claims exactly that, and before this block two of the eight stems had no arm at all).
mk_rail nevertestedmain "the lane 'ci' never TESTED main, so there is no baseline." x
RAIL_RUN_RAIL="$T/bin/rail-nevertestedmain" call start 167 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 167)"; assert_rc 25 "${OUT%%|*}" "STEM: 'never TESTED main' is a MISCONFIGURATION (invocation remedy), so it abstains"
mk_rail norerun "the base reproduction cleared the residual, but --no-rerun denies the E5 second sample the re-run would take. No merge." x
RAIL_RUN_RAIL="$T/bin/rail-norerun" call start 168 >/dev/null
OUT="$(GH_MODE=open wait_state unknown 168)"; assert_rc 25 "${OUT%%|*}" "STEM: '--no-rerun' is the CALLER's flag, so it abstains"
mk_rail treeisred "THE TREE THIS PR PRODUCES IS RED." x
RAIL_RUN_RAIL="$T/bin/rail-treeisred" call start 169 >/dev/null
OUT="$(GH_MODE=open wait_state refused 169)"; assert_rc 20 "${OUT%%|*}" "STEM: 'THE TREE THIS PR PRODUCES IS RED' IS a head verdict (kept)"
mk_rail conflicted "CONFLICTED — GitHub cannot compute a merge of head into the base (mergeable=false), so refs/pull/170/merge is ABSENT or STALE." x
RAIL_RUN_RAIL="$T/bin/rail-conflicted" call start 170 >/dev/null
OUT="$(GH_MODE=open wait_state refused 170)"; assert_rc 20 "${OUT%%|*}" "STEM: 'CONFLICTED' IS a head verdict (kept — no re-measurement clears it)"

# ── AF3: a knob that cannot be read must not DISARM the bound it feeds ─────────────────
# Both bounds are compared with `[ -le ]`, which ERRORS on a non-numeric operand — and an erroring
# test is false, so `younger_than` answers "not young", the claim is judged stale, and a SECOND rail
# starts on the same PR. Refused at load, naming the knob, and no rail is spawned.
n_before="$(rail_invocations 171)"
OUT="$(RAIL_RUN_CLAIM_MAX=abc call start 171)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" "KNOB: an unreadable RAIL_RUN_CLAIM_MAX is refused (it used to disable the one-rail guard)"
assert_contains "$TXT" "RAIL_RUN_CLAIM_MAX" "KNOB: and the refusal names the knob"
OUT="$(RAIL_RUN_RECORD_MAX=0 call start 171)"; assert_rc 2 "${OUT%%|*}" "KNOB: a zero bound is refused too (an all-stale bound is the fail-open direction)"
if [ "$(rail_invocations 171)" = "$n_before" ]; then ok "KNOB: and no rail was spawned for either"
else bad "KNOB: a rail was spawned despite an unreadable bound"; fi

# ── AG: another HOST holding the same owner/repo/number is not this PR ───────────────────────
craft 163 otherhost rc=0 >/dev/null
# A suffix test accepts this one: the PATH names this repo and this PR, the HOST does not.
OUT="$(GH_MODE=otherhost poll 163)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HOST: a MERGED read from another host is NOT a landing"
assert_state "$TXT" unknown "HOST: it abstains"
OUT="$(GH_MODE=merged poll 163)"; assert_rc 0 "${OUT%%|*}" "HOST: the same run lands when the host matches"

# ── AG1b: the abstention NAMES the host it compared, and the knob that pins it ─────────────────
# `unknown` is the correct state here, and on its own it is not actionable: the run RECORDS the host
# at `start`, so a line that omits it leaves a lane unable to tell "my origin names a mirror" from
# "the forge is down" — and it re-polls a run that can never resolve. The line names the recorded
# host and the override, so the reader's next action is visible in the same row.
craft 184 hostmismatch rc=0 host=ghe.example.com >/dev/null
OUT="$(GH_MODE=merged poll 184)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HOST-ABSTAIN: a github.com URL is not this run's landing"
assert_contains "$TXT" "on host ghe.example.com" "HOST-ABSTAIN: the abstention names the RECORDED host"
assert_contains "$TXT" "RAIL_RUN_GH_HOST" "HOST-ABSTAIN: and names the knob that pins it"

# ── AG1c: a run that recorded NO host spells out the default it actually compared ─────────────
# The tempting implementation is `sed 's/^$/github.com/'` over `file_or_empty "$rd/host"` — and it is
# WRONG: `file_or_empty` `tr -d`s every newline, so a missing/empty host file yields ZERO BYTES and sed
# emits NOTHING for empty input (a substitution needs a line to sit on). The row then reads `on host  —`
# with an empty host, in exactly the branch whose comment promises the default. `github.com` here is not
# decoration: it is the value `pr_url_names` compared with (`${4:-github.com}`), so a row that omits it
# tells the reader nothing about what failed. This arm reddens if the default is ever moved back into
# sed, which is how the empty-host rendering was found (#2959 review, P1).
# ⛔ `GH_MODE=otherhost`, NOT `fail`: a FAILING gh makes `pr_state` return at its `|| return 0` BEFORE
# `pr_url_names` is ever called, so an arm built on `fail` is satisfied without the comparison running
# at all (#2959 review, cycle 2, P2). `otherhost` serves `https://ghe.example.com/…`, so the abstention
# is CAUSED by the comparison against the `github.com` default.
# ⛔ WHAT THIS ARM PINS, STATED EXACTLY (#2959 review, cycle 3, P2): the MESSAGE's default. The
# comparator's own default is a SEPARATE literal (`pr_url_names` `${4:-github.com}`), so this arm alone
# would stay green if the two diverged. That second default is pinned by arm AG above — `craft 163
# otherhost rc=0` records no host, and `GH_MODE=merged poll 163` then LANDS against
# `https://github.com/fake/repo/pull/163`, which is only possible if the comparator defaulted to
# `github.com`. Two arms, one value each.
craft 185 nohost rc=0 >/dev/null   # no `host=` kv: this run recorded none
OUT="$(GH_MODE=otherhost poll 185)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HOST-DEFAULT: a URL on another host abstains, caused BY the default comparison"
assert_contains "$TXT" "on host github.com" "HOST-DEFAULT: the abstention spells out the DEFAULT host it compared"
assert_contains "$TXT" "start a new run" "HOST-DEFAULT: and the remedy names the action that can change a RECORDED host (a re-poll cannot)"
assert_contains "$TXT" "RAIL_RUN_REPO_SLUG" "HOST-DEFAULT: and names the identity pin that OUTRANKS the knob (else the advice is inert)"
# ⛔ THE ADVICE MUST NOT PRESCRIBE THE HOST REMEDY FOR A FAILED READ (#2959 review, cycle 3, P1).
# `pr_state` returns BEFORE any comparison when gh itself fails, so this cause needs a re-poll — and
# the note has to say so, or it prescribes a second merge attempt for a transient read.
assert_contains "$TXT" "read itself failed, re-poll" "HOST-DEFAULT: a FAILED read is pointed at a re-poll, not at a new run"
assert_contains "$TXT" "check --repo" "HOST-DEFAULT: and a same-host/different-repo mismatch is pointed at --repo, not at the host"

# ── AG1e: the reason line reaches the paths that ALREADY COMPUTED it ──────────────────────────
# `read_artifact` sets `abstain_why`, and the no-incarnation branch used to print `read <log> and
# re-poll` with NO cause — a `pr_state=not-read` row whose reader still cannot tell "my origin names a
# mirror" from "the forge is down". The datum was in hand and unread, which is the one failure mode
# this file's own doctrine calls out. Rendered before the fix: `unknown … liveness=unknown`, `no
# incarnation recorded — with no exit status this is an ABSTENTION…`, `read …/log and re-poll` — and
# nothing about the host. This arm reddens if `note_abstain` is dropped from that branch (#2959
# review, cycle 3, P2).
craft 188 noinc >/dev/null   # no rc, no pid: the liveness probe has NO incarnation to judge
OUT="$(GH_MODE=fail poll 188)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HOST/REASON: no incarnation + an unreadable artifact abstains"
assert_state "$TXT" unknown "HOST/REASON: it does not claim a death or a landing"
assert_contains "$TXT" "on host github.com" "HOST/REASON: the abstention's reason reaches the no-incarnation branch too"

# ── AG1d: a host-naming IDENTITY pin outranks the knob, and the note says so ──────────────────
# `start` writes `${host_hint:-$(resolve_host)}`, and `RAIL_RUN_GH_HOST` lives INSIDE `resolve_host`,
# so a host-naming `--repo`/`RAIL_RUN_REPO_SLUG` makes the knob UNREAD. ⛔ THAT PRECEDENCE PREDATES
# THIS PR (`#2912` round 7), so the recorded-host half below is a REGRESSION GUARD, not a discriminator
# of this diff — stated rather than implied, and `docs/ops/rail-run.md`'s "every arm names the guard it
# discriminates" is about the guard, which a regression guard names honestly too (#2959 review, cycle
# 3, P2 — a cycle-3 finding also claimed AG1b discriminates nothing; that half is FALSIFIED, AG1b
# reddens against `origin/main`: 209 passed / 4 failed, measured by cycle 2).
# The NOTE half IS this diff's: the sentence must name the pin that outranks the knob, or a lane does
# exactly what it is told and records the SAME pin host again.
PIN_DIR="$T/host-pin"; mkdir -p "$PIN_DIR"
git -C "$PIN_DIR" init -q >/dev/null 2>&1
git -C "$PIN_DIR" remote add origin 'https://github.com/acme/widgets.git' >/dev/null 2>&1
OUT="$(cd "$PIN_DIR" && RAIL_RUN_REPO_SLUG=pin.example.com/acme/widgets RAIL_RUN_GH_HOST=knob.example.com FAKE_RAIL_SLEEP=1 "$BASH_BIN" "$RR" start 186 2>&1)"
assert_rc 0 "$?" "HOST/PRECEDENCE: start with a host-naming identity pin AND the knob set"
PIN_ID="$(run_id_of "$OUT")"
PIDS+=("$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-186/$PIN_ID" pid)")
PIN_HOST="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-186/$PIN_ID" host)"
if [ "$PIN_HOST" = "pin.example.com" ]; then
  ok "HOST/PRECEDENCE: the identity pin outranks RAIL_RUN_GH_HOST (recorded pin.example.com, not knob.example.com)"
else
  bad "HOST/PRECEDENCE: recorded host='$PIN_HOST' (want pin.example.com) — the identity pin must outrank the knob"
fi
craft 187 pinhost rc=0 host=pin.example.com >/dev/null
OUT="$(GH_MODE=otherhost poll 187)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "HOST/PRECEDENCE: the pin's host is not this run's landing either"
assert_contains "$TXT" "on host pin.example.com" "HOST/PRECEDENCE: the abstention names the PIN's host"
assert_contains "$TXT" "outranks it" "HOST/PRECEDENCE: and says the pin outranks the knob, so the remedy is not inert"

# ── AG2: the host is RESOLVED from `origin`, not assumed to be github.com ────────────────────
# Every arm above PINS the host (`RAIL_RUN_GH_HOST` or a hand-built run dir), so `resolve_host` had
# no coverage at all — and it validated the host BEFORE stripping the `user@` prefix, so an ssh
# remote degraded to `github.com` and `landed` became UNREACHABLE on any non-github checkout while
# this suite stayed green. These two arms start a run in a real checkout whose `origin` carries a
# userinfo prefix and assert what the run RECORDED, which is the only thing the artifact check reads.
resolve_host_arm() { # <label> <remote-url> <pr>
  local label="$1" url="$2" pr="$3" dir out rc id got
  dir="$T/host-$pr"
  mkdir -p "$dir"; git -C "$dir" init -q >/dev/null 2>&1
  git -C "$dir" remote add origin "$url" >/dev/null 2>&1
  out="$(cd "$dir" && RAIL_RUN_REPO_SLUG= RAIL_RUN_GH_HOST= FAKE_RAIL_SLEEP=1 "$BASH_BIN" "$RR" start "$pr" 2>&1)"; rc=$?
  assert_rc 0 "$rc" "HOST/RESOLVE: start in a checkout whose origin is $label"
  id="$(run_id_of "$out")"
  PIDS+=("$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-$pr/$id" pid)")
  got="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-$pr/$id" host)"
  if [ "$got" = "ghe.example.com" ]; then
    ok "HOST/RESOLVE: $label records host=ghe.example.com (the userinfo prefix is not the host)"
  else
    bad "HOST/RESOLVE: $label recorded host='$got' (want ghe.example.com) — a @-prefixed remote must not degrade to github.com"
  fi
  got="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-$pr/$id" repo)"
  if [ "$got" = "acme/widgets" ]; then ok "HOST/RESOLVE: $label also records the repo identity (acme/widgets)"
  else bad "HOST/RESOLVE: $label recorded repo='$got' (want acme/widgets)"; fi
}
resolve_host_arm "an scp-form ssh remote (git@host:owner/repo)" 'git@ghe.example.com:acme/widgets.git' 164
resolve_host_arm "an https remote with userinfo (https://user@host/owner/repo)" 'https://user@ghe.example.com/acme/widgets.git' 165

# ── AF4: an ssh TRANSPORT port is not the host ─────────────────────────────────────────
# `ssh://git@host:22/…` records a port the artifact URL never carries, so `pr_url_names` demanded an
# https URL with `:22` and `landed` was unreachable. The https-with-port case must KEEP its port: a
# GHE on :8443 really does serve URLs that carry it.
resolve_host_arm "an ssh:// remote with its transport port (ssh://git@host:22/owner/repo)" 'ssh://git@ghe.example.com:22/acme/widgets.git' 172
HOST_PORT_DIR="$T/host-173"; mkdir -p "$HOST_PORT_DIR"
git -C "$HOST_PORT_DIR" init -q >/dev/null 2>&1
git -C "$HOST_PORT_DIR" remote add origin 'https://ghe.example.com:8443/acme/widgets.git' >/dev/null 2>&1
OUT="$(cd "$HOST_PORT_DIR" && RAIL_RUN_REPO_SLUG= RAIL_RUN_GH_HOST= FAKE_RAIL_SLEEP=1 "$BASH_BIN" "$RR" start 173 2>&1)"
RP_ID="$(run_id_of "$OUT")"
PIDS+=("$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-173/$RP_ID" pid)")
RP_HOST="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-173/$RP_ID" host)"
if [ "$RP_HOST" = "ghe.example.com:8443" ]; then ok "HOST/RESOLVE: an https remote KEEPS its port (the URL carries it)"
else bad "HOST/RESOLVE: https-with-port recorded host='$RP_HOST' (want ghe.example.com:8443)"; fi


# ── AG3: the PIN's host is the host, exactly as `--repo`'s is ──────────────
# `RAIL_RUN_REPO_SLUG` is the documented seam for a checkout whose `origin` does not name its repo, and
# it is spelled `[HOST/]OWNER/REPO` exactly as `--repo` is — but `raw_slug` was captured from ARGV
# alone, so the pin's host was discarded and `origin` (the one source a pinned identity says nothing
# about) was asked instead. A GHE pin in a remote-less checkout therefore recorded `github.com/<slug>`,
# whose artifact check demanded a URL that host never serves: fail-closed, but `landed` unreachable —
# the same unleanable run the `@`-prefix and `--repo` arms above exist to prevent. Assert what was
# RECORDED, then that the landing actually becomes reachable.
PIN_DIR="$T/host-pin"; mkdir -p "$PIN_DIR"
OUT="$(cd "$PIN_DIR" && RAIL_RUN_REPO_SLUG=ghe.example.com/acme/widgets RAIL_RUN_GH_HOST= FAKE_RAIL_SLEEP=1 "$BASH_BIN" "$RR" start 166 2>&1)"; RC=$?
assert_rc 0 "$RC" "HOST/PIN: a HOST-prefixed RAIL_RUN_REPO_SLUG starts"
PIN_RID="$(run_id_of "$RC|$OUT")"
PIDS+=("$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-166/$PIN_RID" pid)")
PIN_HOST="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-166/$PIN_RID" host)"
if [ "$PIN_HOST" = "ghe.example.com" ]; then ok "HOST/PIN: the run records the host its pin named"
else bad "HOST/PIN: recorded host='$PIN_HOST' (want ghe.example.com) — the pin's host must not be re-read from origin"; fi
PIN_REPO="$(rd_field "$RAIL_RUN_DIR/acme-widgets/pr-166/$PIN_RID" repo)"
if [ "$PIN_REPO" = "acme/widgets" ]; then ok "HOST/PIN: and the normalised repo identity (acme/widgets)"
else bad "HOST/PIN: recorded repo='$PIN_REPO' (want acme/widgets)"; fi
OUT="$(GH_MODE=otherhost wait_state landed 166 --repo acme/widgets --run "$PIN_RID")"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "HOST/PIN: a MERGED read ON THE PINNED HOST is a landing (the payoff: the run can be landed)"
OUT="$(GH_MODE=merged poll 166 --repo acme/widgets --run "$PIN_RID")"; RC="${OUT%%|*}"
assert_rc 25 "$RC" "HOST/PIN: the same path on github.com is NOT this run's landing"

# ── X: the recorder's own liveness blocks a start ─────────────────────────
# The recorder is the only incarnation for the first instants of every launch, so a record with a
# LIVE pid, an accurate `start` and NO `railpid` is the COMMON window — and starting a second rail
# there is exactly the double merge attempt the claim exists to prevent.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-145/live"
printf '%s\n' "$$" > "$RAIL_RUN_DIR/fake-repo/pr-145/live/pid"
printf '%s\n' "$( . "$SCRIPT_DIR/lib/pid-identity.sh"; pid_start_epoch "$$" 2>/dev/null || printf 0 )" \
  > "$RAIL_RUN_DIR/fake-repo/pr-145/live/start"
: > "$RAIL_RUN_DIR/fake-repo/pr-145/live/log"
printf 'fake/repo\n' > "$RAIL_RUN_DIR/fake-repo/pr-145/live/repo"
printf 'live\n' > "$RAIL_RUN_DIR/fake-repo/pr-145/latest"
OUT="$(call start 145)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 3 "$RC" "RECORDER-LIVE: a positively live recorder blocks a second start"
assert_contains "$TXT" "may still be alive" "RECORDER-LIVE: and says so"

# ── Y: the KEY is not the identity — an aliasing key must not answer for another repo ──────────
# repo_key maps `/` to `-`, which is not injective: a/b-c and a-b/c share one key.
RD146="$RAIL_RUN_DIR/a-b-c/pr-146/runcraft"
mkdir -p "$RD146"
printf 'a/b-c\n' > "$RD146/repo"
printf '0\n' > "$RD146/rc"
: > "$RD146/log"
printf '2026-10-27T07:00:00Z\n' > "$RD146/started"
printf 'runcraft\n' > "$RAIL_RUN_DIR/a-b-c/pr-146/latest"
OUT="$(poll 146 --repo a-b/c)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 25 "$RC" "ALIAS-KEY: a poll naming a repo this run did not record abstains (the key is shared)"
assert_contains "$TXT" "identity=mismatch" "ALIAS-KEY: and names the mismatch"
OUT="$(poll 146 --repo a/b-c)"; assert_rc 0 "${OUT%%|*}" "ALIAS-KEY: the recorded identity reads normally"

# ── Y2: `latest` is a path component — a hand-edited one cannot point outside the run root ────
# The escape target EXISTS and looks like a finished run, so a validator-free join would answer with
# it (rc=0 + MERGED ⇒ `landed`) instead of `no-run`: the arm can only pass by refusing the join.
mkdir -p "$RAIL_RUN_DIR/alias"
printf 'fake/repo\n' > "$RAIL_RUN_DIR/alias/repo"
printf '0\n' > "$RAIL_RUN_DIR/alias/rc"
: > "$RAIL_RUN_DIR/alias/log"
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-147"
printf '../../alias\n' > "$RAIL_RUN_DIR/fake-repo/pr-147/latest"
OUT="$(poll 147)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 24 "$RC" "LATEST: an unusable 'latest' is treated as absent, never joined into a path"
assert_not_contains "$TXT" "alias" "LATEST: and is not echoed back as a run"

# ── Y2b: a `latest` that names a NON-RUN directory is no-run, like `--run` ───────────────────
# The claim dir passes the path-component validation (it is a legal name), so only the is-a-run test
# stops it from being answered about.
mkdir -p "$RAIL_RUN_DIR/fake-repo/pr-173/.starting"
printf '%s\n' "$$" > "$RAIL_RUN_DIR/fake-repo/pr-173/.starting/pid"
printf '.starting\n' > "$RAIL_RUN_DIR/fake-repo/pr-173/latest"
OUT="$(poll 173)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 24 "$RC" "LATEST-NONRUN: a 'latest' naming the claim dir is no-run, not a state about nobody"
assert_not_contains "$TXT" "gone-without-verdict" "LATEST-NONRUN: never a terminal no-verdict claim"

# ── Y3: rc=2 is a claim about the INVOCATION, so it does not need the artifact ────────────────
craft 148 usage rc=2 >/dev/null
printf 'admin-merge: a PR number is required\n' > "$(rundir 148 usage)/log"
OUT="$(GH_MODE=fail poll 148)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 20 "$RC" "RC2: a usage refusal is refused (20) even when the artifact read abstains"
assert_state "$TXT" refused "RC2: it never analysed the head, so the PR read is irrelevant"

# ── Q: path components are validated, not joined ───────────────────────────
# `..` cannot name a repository, so the run refuses to begin at all (exit 2) instead of keying on a
# hashed spelling of it: an identity is REQUIRED to start, because no artifact read can be verified
# without one.
OUT="$(call start 143 --repo ..)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" "TRAVERSAL: --repo .. cannot name a repository, so the start is refused"
assert_contains "$TXT" "cannot tell which repository" "TRAVERSAL: and says why"
if [ -d "$(dirname "$RAIL_RUN_DIR")/pr-143" ]; then bad "TRAVERSAL: run state escaped the run root (~/pr-143)"
else ok "TRAVERSAL: nothing was written outside the run root"; fi
# a [HOST/]OWNER/REPO spelling is NORMALISED, so one repository cannot be reached through two
# identities (which would be two keys, and two rails)
OUT="$(FAKE_RAIL_SLEEP=6 call start 144 --repo github.com/acme/widgets)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "SLUG: a [HOST/]OWNER/REPO spelling is accepted"
OUT="$(poll 144 --repo acme/widgets)"; assert_rc 10 "${OUT%%|*}" "SLUG: and it is NORMALISED, so the short spelling finds the same run"
PIDS+=("$(cat "$RAIL_RUN_DIR/acme-widgets/pr-144/"*/pid 2>/dev/null | tr '\n' ' ' | awk '{print $1}')")
OUT="$(poll 5 --run ../../etc)"; assert_rc 2 "${OUT%%|*}" "TRAVERSAL: --run with a path separator is refused"
OUT="$(poll 5 --run ..)"; assert_rc 2 "${OUT%%|*}" "TRAVERSAL: --run .. is refused"
OUT="$(call start 5 --repo)"; assert_rc 2 "${OUT%%|*}" "ARGS: a dangling --repo is refused, not reinterpreted"
OUT="$(poll 5 --run)"; assert_rc 2 "${OUT%%|*}" "ARGS: a dangling --run is refused"
# …and so is a flag where a VALUE belongs. A repo slug cannot begin with `-`, so this shape is always a
# caller mistake — but it used to be SILENT: `start` took `--run` as the repo name (then fell back to
# `origin` for the identity, forwarding the mangled pair to the rail), and `status` let the second flag
# overwrite the still-pending `want`, answering about the NEWEST run for a caller who pinned run A.
OUT="$(call start 5 --repo --run --repo acme/widgets)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" "ARGS: a FLAG in --repo's value slot is refused by start (even when a later --repo would supply one)"
assert_contains "$TXT" "needs a value" "ARGS: and start names the flag that lost its value"
OUT="$(poll 7 --run --repo fake/repo)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" "ARGS: a FLAG in --run's value slot is refused by status"
assert_contains "$TXT" "--run needs a value" "ARGS: and status names --run (the pin that would have been lost)"
OUT="$(poll 7 --repo --run runA)"; assert_rc 2 "${OUT%%|*}" "ARGS: a FLAG in --repo's value slot is refused by status too"
# …and an EMPTY value is neither a flag nor an identity. `--repo "$REPO"` with `REPO` unset (or
# `--repo=`) used to pass both checks above, set `id_from_argv=1`, fall back to the pin/`origin` for the
# SLUG — and then SKIP the forward step because argv had "supplied" the identity, handing the rail an
# EMPTY `--repo` that `admin-merge.sh` reads as "not explicit" and resolves from the CHECKOUT. The run
# graded one repo while the rail merged another (the #2235/`--repo=X` class, through a third shape).
OUT="$(call start 5 --repo "")"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" "ARGS: an EMPTY --repo value is refused by start (not silently re-resolved)"
assert_contains "$TXT" "names no repository" "ARGS: and the refusal says the value named no repository"
n_before="$(rail_invocations 5)"
OUT="$(call start 5 --repo=)"; assert_rc 2 "${OUT%%|*}" 'ARGS: the EMPTY `--repo=` spelling is refused too'
if [ "$(rail_invocations 5)" = "$n_before" ]; then ok "ARGS: and no rail was spawned for either empty --repo"
else bad "ARGS: an empty --repo reached the rail (a run graded a repo it did not target)"; fi
# The same shape on the other side: `--run=` (or `--run "$RID"` with `RID` unset) was read as ABSENT, so a
# poller that pinned run A was silently shown the NEWEST run — `landed` included.
OUT="$(poll 5 --run=)"; RC="${OUT%%|*}"; TXT="${OUT#*|}"
assert_rc 2 "$RC" 'ARGS: an EMPTY --run value is refused (it used to follow `latest`)'
assert_contains "$TXT" "--run needs a value" "ARGS: and names --run"
OUT="$(poll 5 --run "")"; assert_rc 2 "${OUT%%|*}" "ARGS: the two-token EMPTY --run is refused too"
OUT="$(poll 5 --repo=)"; assert_rc 2 "${OUT%%|*}" "ARGS: an EMPTY --repo value is refused by status"
OUT="$(poll 5 --repo "")"; assert_rc 2 "${OUT%%|*}" "ARGS: the two-token EMPTY --repo is refused by status too"

# ── Z: a stale TERMINAL run does not block a new start ─────────────────────
OUT="$(GH_MODE=open call start 105)"; RC="${OUT%%|*}"
assert_rc 0 "$RC" "STALE: a finished earlier run does not block a new start (its dir is evidence, not a lock)"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
