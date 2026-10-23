#!/usr/bin/env bash
# ci-queue.test.sh — CI BACK-PRESSURE (measured 2026-10-22). Four acceptance arms, plus two that
# prove the others can go RED.
#
# ⛔ THE FAILURE THIS PREVENTS. 2026-10-22: after a batch of rebases the agent-infra queue went from
# 4 to 31 BLOCKED PRs at once, each needing a full CI pass, against 5 self-hosted runners. Measured
# at 13:40 UTC: tortoise queued=92 running=6 runners=5(busy); agent-infra queued=97 running=7.
# Nothing finished because everything started, and merges/hour went DOWN while the work went up.
#
# ⛔ WHAT EACH ARM IS FOR, AND WHY NONE IS REDUNDANT:
#   (a) a DEEP queue defers, and the ONE line carries the depth, the runner count and WHAT was
#       deferred — silence is what makes a deferral look like a bug;
#   (b) a SHALLOW queue is ALLOWED. A gate that always defers passes (a) and stops the fleet, so this
#       arm is what proves the threshold is not "always say no";
#   (c) the deferral is NOT STICKY. A rule that passes only by REMEMBERING that the queue was deep is
#       a defect: the same call, on the same state directory, must ALLOW the moment a fresh read says
#       shallow — and must defer again when it says deep;
#   (d) MUTATION. DISABLING the queue read (replaced by a constant, module still parses) must make
#       (a) fail. This is the only arm that proves the gate MEASURES the queue instead of
#       correlating with it; a deletion-shaped mutant cannot serve, see the arm itself;
#   (e) WIRING. The module is a gate only if the shipped callers call it; the call sites are asserted
#       by name so deleting one goes red instead of silently ungating a path.
#
# HERMETIC: a stub `gh` supplies the feed, `$T/state` stands in for `$O/state`, no network, nothing
# outside `$T` is written. The SHIPPED module is sourced (not copied), so the parsing and arithmetic
# under test are the bytes the daemon runs.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="${CIQ_MODULE:-$HERE/ci-queue.sh}"
LOOP="${LOOP:-$HERE/orch-loop.sh}"
FIX="${FIX:-$HERE/fix-one.sh}"
DISPATCH="${DISPATCH:-$HERE/dispatch-merge.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/ci-queue.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_LINES=""
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LINES="$FAILED_LINES$1
"; printf '  ❌ %s\n' "$1"; }
ck()  { if [ "${2:-1}" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

[ -f "$MOD" ] || { echo "❌ missing $MOD"; exit 2; }

# ── the stub feed ────────────────────────────────────────────────────────────────────────────────
# Answers exactly the three endpoints ci-queue.sh reads, from CIQ_TEST_*. A RUNNERS value of `-`
# means "the endpoint refuses", which is the measured agent-infra shape (404 on the org, an empty
# list on the repo while 7 runs were executing).
STUB="$T/gh"
cat > "$STUB" <<'STUBBODY'
#!/usr/bin/env bash
case "$2" in
  *status=queued*)
    printf '{"total_count":%s}\n' "${CIQ_TEST_QUEUED:-0}" ;;
  *status=in_progress*)
    printf '{"total_count":%s}\n' "${CIQ_TEST_RUNNING:-0}" ;;
  *actions/runners*)
    # ⛔ PRETTY-PRINTED ON PURPOSE (#2333 review P1). `gh api` formats JSON: the real output is
    # `"status": "online"`, with a space, one object per line. A stub that emitted only the compact
    # shape let a `'"status":"online"'` match pass HERE and find NOTHING in production — `runners`
    # then degraded silently to `~in_progress`, and the ceiling was derived from the wrong quantity
    # (3x too permissive on the measured box, i.e. exactly the over-dispatch this module exists to
    # stop). The feed below is the shape the reader actually meets.
    [ "${CIQ_TEST_RUNNERS:-0}" = "-" ] && exit 1
    n="${CIQ_TEST_RUNNERS:-0}"; i=0
    # CIQ_TEST_OFFLINE=1 emits a DECLARED-but-offline fleet (`total_count > 0`, nothing online) — the
    # shape that must NOT be confused with the hosted zero (ci-queue.sh, "two different zeroes").
    st=online; [ "${CIQ_TEST_OFFLINE:-0}" = "1" ] && st=offline
    printf '{\n  "total_count": %s,\n  "runners": [\n' "$n"
    while [ "$i" -lt "$n" ]; do
      [ "$i" -gt 0 ] && printf ',\n'
      printf '    {\n      "id": %s,\n      "name": "r%s",\n      "status": "%s",\n      "busy": %s\n    }' \
        "$i" "$i" "$st" "${CIQ_TEST_BUSY:-true}"
      i=$((i+1))
    done
    printf '\n  ]\n}\n' ;;
  *) exit 1 ;;
esac
STUBBODY
chmod +x "$STUB"

state() { rm -rf "$T/state"; mkdir -p "$T/state"; }

# ⛔ EXPLICIT ASSIGNMENT, NOT A `VAR=x func` PREFIX: bash's env-prefix behaviour differs between
# functions and external commands, so a test that relied on it would pass or fail by shell version.
qenv() { # <gh> <ttl> <stale_max>
  CIQ_GH="$1"; CIQ_TTL="$2"; CIQ_STALE_MAX="$3"
  export CIQ_GH CIQ_TTL CIQ_STALE_MAX
}

feed() { # <queued> <running> <runners> [busy] [offline]
  state
  qenv "$STUB" 0 900
  CIQ_STATE_DIR="$T/state"; export CIQ_STATE_DIR
  CIQ_TEST_QUEUED="${1:-0}"; CIQ_TEST_RUNNING="${2:-0}"
  CIQ_TEST_RUNNERS="${3:-0}"; CIQ_TEST_BUSY="${4:-true}"; CIQ_TEST_OFFLINE="${5:-0}"
  export CIQ_TEST_QUEUED CIQ_TEST_RUNNING CIQ_TEST_RUNNERS CIQ_TEST_BUSY CIQ_TEST_OFFLINE
  OR="daniel-ospina/agent-infra"; export OR
}

# has <haystack> <literal-needle> -> 0 when the needle is present
# ⛔ NO PIPE INTO A QUIET GREP (#841/#864): under `pipefail` a builtin writer piped into `grep -q`
# SIGPIPEs the writer, and `sigpipe-grep` refuses the idiom. The payload is one line, so a here-string
# is behaviour-identical.
has() { grep -F -q -- "${2:-}" <<<"${1:-}"; }

REC="$T/state/ci-queue-daniel-ospina_agent-infra"

# shellcheck source=/dev/null
. "$MOD" || { echo "❌ $MOD failed to source"; exit 2; }

printf '\n── (0) the derivation is arithmetic, not a constant ─────────────────────────\n'
# ceiling = ceil(runners * horizon / job_p90). 5 runners / 20m / 10m = 10 — the number the incident
# is measured against. If this changes, the header's derivation must change with it.
n="$(ciq_ceiling 5)";           ck "5 runners => ceiling 10 (ceil(5*20/10))"                 "$( [ "$n" = 10 ]; echo $? )"
n="$(ciq_ceiling 7)";           ck "7 executing runs (agent-infra measured) => ceiling 14"    "$( [ "$n" = 14 ]; echo $? )"
n="$(ciq_ceiling 1)";           ck "1 runner => ceiling 2 (a 0 ceiling defers every push for ever)" "$( [ "$n" = 2 ]; echo $? )"
ciq_ceiling x >/dev/null 2>&1;  ck "an unusable runner count derives NOTHING (rc 1), never a silent 0" "$( [ $? -eq 1 ]; echo $? )"
n="$(CIQ_HORIZON_MIN=40 ciq_ceiling 5)"
ck "the horizon is overridable (one place: ci-queue.sh's ciq_horizon_min)" "$( [ "$n" = 20 ]; echo $? )"
n="$(CIQ_HORIZON_MIN=abc ciq_ceiling 5)"
ck "a garbage horizon falls back to the measured default (no integer-expression crash)" "$( [ "$n" = 10 ]; echo $? )"

printf '\n── (a) DEEP queue => DEFERRED, with the depth, the runners and the WHAT ────\n'
# 31 queued = the incident's BLOCKED count; 5 runners = the real runner count.
feed 31 5 5
msg="$(ciq_defer_note "CONFLICTED fixer for #1234 (a push to fix/x invalidates head abc123)")"; rc=$?
ck "(a1) a deep queue defers (the note is produced)" "$( [ "$rc" -eq 0 ]; echo $? )"
has "$msg" 'queued=31';                ck "(a2) the line names the queue depth verbatim (31)" "$?"
has "$msg" 'runners=5';                ck "(a3) the line names the runner count (5)" "$?"
has "$msg" 'ceiling=10';               ck "(a4) the line names the ceiling it was measured against (10)" "$?"
has "$msg" 'CONFLICTED fixer for #1234'; ck "(a5) the line names WHAT was deferred" "$?"
ck "(a6) it is ONE line, not a paragraph — and never EMPTY (a silent deferral is the bug)" \
   "$( { [ -n "$msg" ] && [ "$(printf '%s' "$msg" | wc -l | tr -d ' ')" = 0 ]; } ; echo $? )"
# ⛔ THE MEASURED-FLEET TOKEN PRINTS `busy=`, WHICH ONLY HAPPENS WHEN THE PAGE WAS GENUINELY PARSED
# (#2333 review P1). Every arm that fed a readable runner page could still pass on a FAILED read —
# the inference path degrades to a plausible ceiling — so this single assertion is what pins the
# pretty-printed `"status": "online"` parse the gate's accuracy depends on.
has "$msg" 'busy=5';                    ck "(a8) the runner page was genuinely parsed (busy=5 in the token)" "$?"
ciq_read "$OR" >/dev/null 2>&1
ciq_ci_allowed "$OR"; d0=$?
ck "(a7) the predicate the wiring branches on refuses (ciq_ci_allowed = 1)" "$( [ "$d0" -eq 1 ]; echo $? )"

printf '\n── (b) SHALLOW queue => ALLOWED ────────────────────────────────────────────\n'
feed 4 2 5
ciq_ci_allowed "$OR"; d0=$?
ck "(b1) a shallow queue is allowed (ciq_ci_allowed = 0)" "$( [ "$d0" -eq 0 ]; echo $? )"
msg="$(ciq_defer_note "anything")"; rc=$?
ck "(b2) no deferral line is produced" "$( { [ "$rc" -eq 1 ] && [ -z "$msg" ]; } ; echo $? )"
feed 10 5 5
ciq_ci_allowed "$OR"; d0=$?
ck "(b3) AT the ceiling is still allowed (the threshold is > ceiling, not >=)" "$( [ "$d0" -eq 0 ]; echo $? )"
feed 11 5 5
ciq_ci_allowed "$OR"; d0=$?
ck "(b4) one run OVER the ceiling is deferred" "$( [ "$d0" -eq 1 ]; echo $? )"

printf '\n── (b5) HOSTED CI: no self-hosted runners must not collapse the ceiling ────\n'
# ⛔ agent-infra's MEASURED shape is `{"total_count":0,"runners":[]}` while runs execute — its jobs
# run on GitHub-HOSTED runners, which never appear in the repo endpoint. Inferring the runner count
# from `in_progress` there made the ceiling smallest exactly when the box was idle: queued=4
# running=1 => ceiling 2 => DEFERRED, i.e. "a rule that defers on 4 would be a fleet-wide stop" —
# the failure the module header names as unacceptable. The pre-incident baseline and the incident
# are the two arms that must BOTH hold.
feed 4 1 0
ciq_ci_allowed "$OR"; d0=$?
ck "(b5) hosted CI, zero repo runners: the PRE-INCIDENT baseline (4) is ALLOWED" "$( [ "$d0" -eq 0 ]; echo $? )"
feed 4 1 -
ciq_ci_allowed "$OR"; d0=$?
ck "(b6) a REFUSED runners read is NOT the hosted zero: it fails CLOSED (4 queued DEFERRED)" "$( [ "$d0" -eq 1 ]; echo $? )"
# ⛔ AND THE REFUSED READ MUST NOT OVERWRITE A GOOD RECORD WITH THE GUESS (#2333 review P1).
# Measured before the fix: one refused `actions/runners` call turned a 5-runner fleet's `queued=31`
# into `~20`/ceiling 40 => ALLOWED, and the poisoned record then served as `cache` for
# TTL+STALE_MAX (~16 min) — the one shape where the gate reported `fresh` while permitting 4x its
# true ceiling, allowing the incident's own queue in a queue nothing could drain.
feed 31 5 5
ciq_read "$OR" >/dev/null 2>&1
feed 31 5 -
ciq_read "$OR" >/dev/null 2>&1
v="$(ciq_eval)"
ck "(b6b) a refused runner read falls back to the measured floor, never the allowance (got: ${v})" \
   "$( case "$v" in *'ceiling=10'*) echo 0 ;; *) echo 1 ;; esac )"
# A garbled `running` must not become a ceiling the gate can never reach: 9 digits pass
# `ciq_is_count` and would yield ceiling ~2e9, switching back-pressure off silently. Driven on the
# UNMEASURED path (refused endpoint), where the floor is the only runner source.
feed 5 499999999 -
ciq_read "$OR" >/dev/null 2>&1
v="$(ciq_eval)"
ck "(b6c) an absurd `running` is bounded by the allowance, never made the ceiling (got: ${v})" \
   "$( case "$v" in *'runners=~1'*'ceiling=2'*) echo 0 ;; *) echo 1 ;; esac )"
feed 97 7 0
ciq_ci_allowed "$OR"; d0=$?
ck "(b7) hosted CI, zero repo runners: the MEASURED incident (97) is DEFERRED" "$( [ "$d0" -eq 1 ]; echo $? )"
feed 4 1 0
ciq_read "$OR" >/dev/null 2>&1
ck "(b8) an unmeasured runner count is DECLARED inferred in the record (runners=${CIQ_RUNNERS:-?})" \
   "$( case "${CIQ_RUNNERS:-}" in '~'*) echo 0 ;; *) echo 1 ;; esac )"
v="$(ciq_eval)"
ck "(b9) the ceiling comes from the allowance, not from `running` (ceiling=40, got: ${v})" \
   "$( case "$v" in *'ceiling=40'*) echo 0 ;; *) echo 1 ;; esac )"
# ⛔ A DECLARED FLEET THAT IS ENTIRELY OFFLINE IS NOT THE HOSTED ZERO (#2333 review P1). Collapsing
# `total_count>=1 with nothing online` into "no fleet" claims the allowance and ALLOWS the incident's
# own 31-deep queue with nothing able to drain it. Fail CLOSED: ceiling floors at 1 runner = 2.
feed 31 5 5 true 1
ciq_ci_allowed "$OR"; d0=$?
ck "(b10) a DECLARED-but-offline fleet defers a 31-deep queue (fail closed)" "$( [ "$d0" -eq 1 ]; echo $? )"
feed 0 0 5 true 1
ciq_read "$OR" >/dev/null 2>&1
ck "(b11) …and it is recorded as inferred from a fleet, never as the hosted allowance (runners=${CIQ_RUNNERS:-?})" \
   "$( [ "${CIQ_RUNNERS:-}" = '~1' ]; echo $? )"
# ⛔ THE OFFLINE FLEET MUST NOT DISCARD THE MEASURED FLOOR (#2333 review P1). A stale/decommissioned
# self-hosted runner entry on a repo that actually runs on hosted capacity pinned the ceiling at 2, so
# a 4-deep queue DEFERRED for ever — "a rule that defers on 4 would be a fleet-wide stop".
feed 4 7 5 true 1
ciq_ci_allowed "$OR"; d0=$?
ck "(b12) declared-but-offline still honours `running` (4 queued, 7 running => ceiling 14 => ALLOWED)" \
   "$( [ "$d0" -eq 0 ]; echo $? )"

printf '\n── (c) NOT STICKY: a fresh read decides, not a memory of the last one ──────\n'
feed 31 5 5
ciq_ci_allowed "$OR"; d1=$?
feed 4 2 5
ciq_ci_allowed "$OR"; d2=$?
ck "(c1) deep then shallow: deferred, then ALLOWED with no reset in between" \
   "$( { [ "$d1" -eq 1 ] && [ "$d2" -eq 0 ]; } ; echo $? )"
feed 31 5 5
ciq_ci_allowed "$OR"; d3=$?
ck "(c2) and shallow -> deep defers again (it tracks the queue, both directions)" \
   "$( [ "$d3" -eq 1 ]; echo $? )"
# ⛔ A DEFERRAL MUST NOT BE REMEMBERED AS A DECISION. The only artifact a deferral may leave is the
# queue RECORD (a measurement carrying an age), never a "we deferred" flag — a flag is exactly what
# would make this suite pass (a) and then keep deferring after the drain.
ck "(c3) the state dir holds the queue record and NO deferral marker" \
   "$( { [ "$(ls "$T/state" | grep -c 'ci-queue-')" -eq 1 ] \
        && [ "$(ls "$T/state" | grep -c 'defer')" -eq 0 ]; } ; echo $? )"
# The cache may answer for CIQ_TTL seconds; it must not outlive the staleness window.
# ⛔ THIS ARM USED TO BE TAUTOLOGICAL (#2333 review P2): it accepted `fresh` OR `cache` and never
# looked at the age, so it stayed green under the very defect it is titled for — a cached record
# presented as a fresh measurement. A TTL answer is `cache` WITH its age, IN THE TOKEN, or it fails.
feed 31 5 5
ciq_read "$OR" >/dev/null 2>&1
qenv "$STUB" 90 900
ciq_read "$OR" >/dev/null 2>&1
v="$(ciq_eval)"; rc=$?
ck "(c4) a TTL answer is labelled cache WITH its age (state=${CIQ_STATE:-?} age=${CIQ_AGE:-?})" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ] && has "$v" 'state=cache' && has "$v" 'age='; } ; echo $? )"
# ⛔ AND THE RECORD AN INFERRED READ WRITES MUST BE SERVABLE (#2333 review P1). `runners` is stored
# as `~<n>` when the endpoint did not answer, and the cache arms validated it with the SHAPE
# predicate — `ciq_is_num "~6"` is false — so an inferred record could NEVER be served: every call
# re-read live (defeating the documented one-read-per-burst) and a transient gh error became
# UNKNOWN. The NUMERIC PART is what must parse.
printf 'queued=31\nrunning=5\nrunners=~6\nbusy=\nat=%s\n' "$(date +%s)" > "$REC"
qenv /nonexistent-gh 0 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c4b) an INFERRED record (runners=~6) is served as cache, with age (rc=$rc state=${CIQ_STATE:-?})" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ] && [ "${CIQ_RUNNERS:-}" = '~6' ]; } ; echo $? )"
# ⛔ A FUTURE `at=` IS NOT A FRESH RECORD (#2333 review cycle 2, P2). The old clamp (`age<0 → 0`) made
# a record written under a forward-stepped clock answer `cache age=0s` FOR EVER — neither the TTL nor
# the staleness window could bind, so the one fail-open in this module was unbounded. A future stamp
# is unusable: the live read decides, and when it fails the verdict is UNKNOWN (fail closed).
future=$(( $(ciq_now) + 600 ))
printf 'queued=31\nrunning=5\nrunners=5\nbusy=5\nat=%s\n' "$future" > "$REC"
qenv /nonexistent-gh 900 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c4c) a FUTURE-stamped record is NOT served (rc=$rc state=${CIQ_STATE:-?}) — no unbounded cache" \
   "$( { [ "$rc" -eq 2 ] && [ "${CIQ_STATE:-}" = unknown ]; } ; echo $? )"
# A record stamped in 1970, past a 0-second staleness window, with the live read failing: the queue
# is UNREADABLE, and an unreadable queue is never "empty".
feed 31 5 5
ciq_read "$OR" >/dev/null 2>&1
printf 'queued=31\nrunning=5\nrunners=5\nbusy=5\nat=1\n' > "$REC"
qenv /nonexistent-gh 0 0
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c5) an unreadable queue PAST the staleness window is UNKNOWN (rc 2), never 'empty'" \
   "$( [ "$rc" -eq 2 ]; echo $? )"
now="$(date +%s)"; old=$(( now - 10 ))
printf 'queued=31\nrunning=5\nrunners=5\nbusy=5\nat=%s\n' "$old" > "$REC"
qenv /nonexistent-gh 0 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c6) an unreadable queue INSIDE the window falls back to the record and SAYS so (state=cache)" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ]; } ; echo $? )"

printf '\n── (c7) UNKNOWN defers (fail closed), and says which it was ───────────────\n'
state
qenv /nonexistent-gh 0 0
msg="$(ciq_defer_note "CI-red fixer for #9")"; rc=$?
ck "(c7) an unreadable queue DEFERS rather than opening the gate" "$( [ "$rc" -eq 0 ]; echo $? )"
has "$msg" 'unknown('
ck "(c8) and the line says UNKNOWN, not a made-up depth" "$?"

printf '\n── (d) MUTATION: remove the queue read => the gate OPENS, (a) goes RED ────\n'
mkdir -p "$T/mutant"
# The mutation REPLACES the queued read with a constant and leaves a module that still PARSES: that
# is the silent shape — "still installed, no longer measuring".
# ⛔ A DELETION IS NOT THAT SHAPE AND MUST NOT BE ACCEPTED AS ONE. The read is a `$( … )` spanning a
# continuation, so deleting its first line strands `| sed …  )` and bash rejects the whole FILE. A
# mutant that cannot be installed proves nothing about a silently-disabled gate — and worse, the
# driving subshell then silently falls back to the REAL functions it inherited and the arm reads
# GREEN on code it never executed. Both failure modes are excluded below: the mutant is parsed, and
# the namespace is cleared before it is sourced.
awk '
  /status=queued/        { print "  queued=0"; skip=1; next }
  skip && /^ *\| sed -n/ { skip=0; next }
  { print }
' "$MOD" > "$T/mutant/ci-queue.sh"
# ONE driver for both arms, in a CLEARED function namespace. `unset -f` is load-bearing, not tidying.
drive_arm() { # <module-path> -> the predicate's answer + the note (+ a marker when it never loaded)
  (
    unset -f ciq_is_num ciq_horizon_min ciq_job_p90_min ciq_ceiling ciq_slug ciq_state_dir \
             ciq_gh ciq_now ciq_read ciq_eval ciq_verdict ciq_defer_note ciq_ci_allowed 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    declare -f ciq_read ciq_ci_allowed ciq_defer_note >/dev/null 2>&1 \
      || { echo 'INTERFACE-MISSING'; exit 0; }
    feed 31 5 5
    ciq_ci_allowed "$OR"; printf 'allowed=%s\n' "$?"
    ciq_defer_note "CONFLICTED fixer for #1234 (a push to fix/x invalidates head abc123)"
  ) 2>/dev/null
}
if cmp -s "$MOD" "$T/mutant/ci-queue.sh"; then
  bad "(d0) the mutation did not apply — the queue read is not recognisable, so this arm proves nothing"
elif ! bash -n "$T/mutant/ci-queue.sh" 2>/dev/null; then
  bad "(d0) the mutant does not parse — a broken mutant proves nothing about a silently-disabled gate"
else
  ok "(d0) the mutation applied and the mutant still parses (the queued read becomes a constant)"
  real_out="$(drive_arm "$MOD")"
  mut_out="$(drive_arm "$T/mutant/ci-queue.sh")"
  ck "(d1) CONTROL: the shipped module, driven the same way, defers AND names the depth (31)" \
     "$( { has "$real_out" 'allowed=1' && has "$real_out" 'queued=31'; } ; echo $? )"
  ck "(d2) the mutant SOURCED — no inherited function stands in for it (that is what (d3) rests on)" \
     "$( { has "$mut_out" 'DID-NOT-SOURCE' || has "$mut_out" 'INTERFACE-MISSING'; } ; [ $? -ne 0 ]; echo $? )"
  ck "(d3) on the mutant the gate OPENS (allowed=0) where the shipped module refused (allowed=1)" \
     "$( { has "$mut_out" 'allowed=0' && has "$real_out" 'allowed=1'; } ; echo $? )"
  ck "(d4) and (a2) goes RED: the mutant's line no longer names the queue depth" \
     "$( has "$mut_out" 'queued=31'; [ $? -ne 0 ]; echo $? )"
fi

printf '\n── (e) WIRING: the shipped callers call it (a module nobody calls is not a gate) ──\n'
grep -q 'ci-queue.sh' "$LOOP" && grep -q 'ciq_read ciq_eval ciq_defer_note_here ciq_ci_allowed' "$LOOP"
ck "(e1) orch-loop.sh sources ci-queue.sh and guards it on the interface" "$?"
grep -q 'ciq_read "\${OR:-}"' "$LOOP" && grep -q 'CIQ_VER="\$(ciq_eval)"; CIQ_RC=\$?' "$LOOP"
ck "(e2) orch-loop.sh reads the queue ONCE per cycle, IN THIS SHELL (not a subshell)" "$?"
grep -F -q 'GATE_WHY="ci-queue($CIQ_VER)"' "$LOOP"
ck "(e3) the ISSUE path is gated on it (the ci-queue gate arm)" "$?"
n="$(grep -cF 'elif [ "$(wt_count fix-)" -lt "$MF" ] && can_spawn && ! ciq_push_ok; then' "$LOOP")"
ck "(e4) BOTH fixer push arms defer (the CONFLICTED and CI-red spawn sites)" "$( [ "$n" -eq 2 ]; echo $? )"
ck "(e4-eligibility) …and each defer arm carries the SPAWN arm's own eligibility, so a deep queue is never reported as the binding reason for a PR the capacity gate refused (#2333 cycle 7, P2)" \
   "$( { [ "$n" -eq 2 ] && [ "$(grep -c 'elif ! ciq_push_ok; then' "$LOOP")" -eq 0 ]; } ; echo $? )"
ck "(e4b) AND SO DOES THE THIRD PUSHER — the review-gate fixer arm (its product is a new head too)" \
   "$( grep -q '_fix_eligible" = "1" ] && ciq_push_ok' "$LOOP"; echo $? )"
ck "(e4c) …and its defer arm cannot fire for a PR that was simply not eligible (the guard is shared, not duplicated)" \
   "$( grep -q 'elif \[ "\$_fix_eligible" = "1" \]; then' "$LOOP"; echo $? )"
n="$(grep -c 'ciq_defer_note_here "CONFLICTED fixer' "$LOOP")"; m="$(grep -c 'ciq_defer_note_here "CI-red fixer' "$LOOP")"
ck "(e5) each push arm emits the deferral line" "$( { [ "$n" -eq 1 ] && [ "$m" -eq 1 ]; } ; echo $? )"
n="$(grep -c 'ci-queue(\${CIQ_VER:-unmeasured})' "$LOOP")"
ck "(e6) every CI-SPENDING arm (both fixer spawns + the review-gate fixer + the rerun) writes a wait disposition carrying the verdict — and says \`unmeasured\` when the cycle's own read has not run yet (n=$n)" "$( [ "$n" -eq 4 ]; echo $? )"
ck "(e6b) no push arm DEFAULTS the verdict to \`deep\` — a label the arm never measured" \
   "$( grep -q 'CIQ_VER:-deep' "$LOOP"; [ $? -ne 0 ]; echo $? )"
grep -q 'ci-queue.sh' "$FIX" && grep -q 'ciq_ci_allowed "\$OR"' "$FIX"
ck "(e7) fix-one.sh gates the lane that PUSHES" "$?"
grep -q 'fixbail-\$PR-\$HEAD' "$FIX"
ck "(e8) fix-one.sh's deferral writes the bail marker, so no attempt is consumed" "$?"
grep -q 'ci-queue.sh' "$DISPATCH" && grep -F -q 'ciq_defer_note_here "the whole batch' "$DISPATCH"
ck "(e9) dispatch-merge.sh (the batch stampede) reads the same module and defers the batch" "$?"
grep -qE 'LANES[^a-z]*-ge|MAX_LANES=' "$MOD"
ck "(e10) no LANE CAP is reintroduced in code (a queue read, per the owner ruling)" "$( [ $? -ne 0 ]; echo $? )"
# ⛔ THE NOTE MUST EVALUATE THE DECISION'S OWN READING (#2333 review P1). `ciq_defer_note` re-reads;
# on a queue that moved between the decision and the note it could DISAGREE and print NOTHING — a
# deferral with no line, the one failure the module exists to prevent — and it cost three extra `gh`
# calls per deferred PR. Every wiring site uses the in-shell entry point; this arm is what stops a
# future edit reverting one of them.
n="$(grep -c 'ciq_defer_note_here "' "$LOOP")"; m="$(grep -c 'ciq_defer_note_here "' "$FIX")"; p="$(grep -c 'ciq_defer_note_here "' "$DISPATCH")"
ck "(e11) every wiring deferral uses the IN-SHELL note (loop=$n fixer=$m batch=$p)" \
   "$( { [ "$n" -eq 4 ] && [ "$m" -eq 1 ] && [ "$p" -eq 1 ]; } ; echo $? )"
# ⛔ ONE READ PER CYCLE — INCLUDING WHEN THE READ FAILS (#2296 cycle 5, P2). The module's cache covers
# only a SUCCESSFUL read, so on the outage path every arm re-read live (measured: 15 `gh api` calls for
# 5 arms against a failing feed, versus 3 against a working one) — the gate's own cost then grew with
# the backlog, in the cycle where `gh-limit` is already the bottleneck. The predicate captures its
# verdict AND memoizes it, and the memo is reset with the rest of the per-cycle state.
ck "(e12) the gate's verdict is CAPTURED for the rows and MEMOIZED (one read per pass, even on failure)" \
   "$( { grep -q 'CIQ_ARM_RC="$CIQ_RC"; CIQ_ARM_VER="$CIQ_VER"' "$LOOP" && grep -q 'CIQ_ARM_RC=""' "$LOOP"; } ; echo $? )"

printf '\n── (h) THE PREDICATE ITSELF, DRIVEN (not grepped) ────────────────────────────\n'
# ⛔ WHY THIS SECTION EXISTS (#2296 cycle 6, P0). `(e12)` was two textual greps, and no arm anywhere
# EXECUTED the shipped predicate (`pr-dispatch.test.sh` replaces it wholesale). Commit `0690233d`
# therefore replaced the predicate's READ with a bare `ciq_eval` — evaluate-the-record — and every
# arm stayed green while the shipped code refused EVERY fixer and EVERY rerun on EVERY cycle, on a
# perfectly shallow queue: `ciq_eval` was reading a record that no read had populated, which is
# `unknown`, which is DEFER. That is the permanent stop this file exists to prevent, and only driving
# the shipped bytes can see it. The function is EXTRACTED from `orch-loop.sh` (not restated here), so
# this arm fails the moment the shipped predicate stops reading.
PRED="$T/pred.sh"
awk '/^  ciq_push_ok\(\) \{/{f=1} f{print} f&&/^  \}/{exit}' "$LOOP" > "$PRED"
ck "(h0) the shipped predicate was extracted from orch-loop.sh (not a restatement)" \
   "$( { [ -s "$PRED" ] && grep -q 'CIQ_ARM_RC' "$PRED" && ! grep -q 'known-deliberate' "$PRED"; } ; echo $? )"
# shellcheck source=/dev/null
. "$PRED"
# ⛔ THE RESET IS EXTRACTED TOO (#2333 cycle 6 review, P1). (h4) used to reset the memo with a
# RESTATEMENT written in this file, so a memo that LEAKED ACROSS CYCLES — the same permanent stop as
# the P0 above, one cycle later — passed every arm: moving the shipped reset OUT of the `while true`
# body left this suite 59/59 green, because (e12)'s `grep` matches a line ANYWHERE in the file and
# cannot see SCOPE. The shipped block is sourced, and its position inside the cycle body is asserted
# by line order — the only thing a text scan can see of scope.
RST="$T/reset.sh"
awk '/^  CIQ_RC=1; CIQ_VER=""; CIQ_STATE=/{f=1} f{print} f&&/^  CIQ_ARM_RC=""/{exit}' "$LOOP" > "$RST"
_whileln="$(grep -n '^while true; do' "$LOOP" | tail -1 | cut -d: -f1)"
_resetln="$(grep -n '^  CIQ_ARM_RC=""; CIQ_ARM_VER=""' "$LOOP" | head -1 | cut -d: -f1)"
ck "(h0b) the per-cycle reset was EXTRACTED from orch-loop.sh (record AND memo), not restated" \
   "$( { [ -s "$RST" ] && grep -q 'CIQ_ARM_RC=""' "$RST" && grep -q 'CIQ_VER=""' "$RST"; } ; echo $? )"
ck "(h0c) …and it sits INSIDE the cycle body (while@${_whileln:-?} < reset@${_resetln:-?}) — a hoisted reset re-pins cycle 1's verdict for ever" \
   "$( { [ -n "${_whileln:-}" ] && [ -n "${_resetln:-}" ] && [ "$_resetln" -gt "$_whileln" ]; } ; echo $? )"
# shellcheck source=/dev/null
reset_cycle() { . "$RST"; }
feed 1 0 3; reset_cycle      # SHALLOW: 1 queued, 3 runners => ceiling 6 => allowed
ciq_push_ok; rc=$?
ck "(h1) a SHALLOW queue ALLOWS through the SHIPPED predicate (rc=$rc) — the P0 refused here for ever" \
   "$( [ "$rc" -eq 0 ]; echo $? )"
feed 999 1 2; reset_cycle    # DEEP: ceiling 4
ciq_push_ok; rc=$?
ck "(h2) a DEEP queue DEFERS through the shipped predicate (rc=$rc) and carries the token" \
   "$( { [ "$rc" -eq 1 ] && has "${CIQ_VER:-}" 'deep('; } ; echo $? )"
v1="${CIQ_VER:-}"
# …and the SECOND call in the same cycle must reuse the memo: the feed flips shallow, so a re-read
# would allow, and only a memo can still refuse.
feed 1 0 3
ciq_push_ok; rc=$?
ck "(h3) the second call in the same cycle reuses the MEMO (rc=$rc, token unchanged) — exactly one read" \
   "$( { [ "$rc" -eq 1 ] && [ "${CIQ_VER:-}" = "$v1" ]; } ; echo $? )"
reset_cycle              # the per-cycle reset the loop performs at the top of each cycle
ciq_push_ok; rc=$?
ck "(h4) after that reset the predicate re-reads and ALLOWS (rc=$rc) — the memo is per-cycle, not per-process" \
   "$( [ "$rc" -eq 0 ]; echo $? )"
feed 5 1 3; reset_cycle      # UNREADABLE (no gh at all) => UNKNOWN => DEFER (fail closed)
qenv /nonexistent-gh 0 0
ciq_push_ok; rc=$?
ck "(h5) an UNREADABLE queue DEFERS through the shipped predicate (rc=$rc) — fail closed, and it SAYS unknown" \
   "$( { [ "$rc" -eq 1 ] && has "${CIQ_VER:-}" 'unknown('; } ; echo $? )"

printf '\n── (f) A READING THAT DOES NOT FIT IS NOT A READING (an errored [ ] is FALSE) ──\n'
# ⛔ `[ … -gt … ]` ERRORS above intmax, an errored test is FALSE, and a FALSE test here lands on the
# `ok(...)` branch — the gate OPENING on the one value it could not compare (#2333 review P2).
CIQ_STATE=fresh; CIQ_QUEUED=99999999999999999999; CIQ_RUNNING=0; CIQ_RUNNERS=5; CIQ_BUSY=""
CIQ_CEILING=10; CIQ_AGE=0
v="$(ciq_eval)"; rc=$?
ck "(f1) a queued count too large to compare is UNKNOWN (rc=$rc), never allowed" \
   "$( { [ "$rc" -eq 2 ] && has "$v" 'not a comparable reading'; } ; echo $? )"
CIQ_QUEUED=31; CIQ_CEILING=99999999999999999999
v="$(ciq_eval)"; rc=$?
ck "(f2) …and so is an uncomparable CEILING (rc=$rc) — the same direction" \
   "$( { [ "$rc" -eq 2 ] && has "$v" 'not a comparable reading'; } ; echo $? )"
CIQ_STATE=fresh; CIQ_QUEUED=31; CIQ_RUNNING=5; CIQ_RUNNERS=5; CIQ_CEILING=10
v="$(ciq_eval)"; rc=$?
ck "(f3) CONTROL: the same shape with in-range numbers is deep (rc=$rc) — (f1)/(f2) are not always-red" \
   "$( { [ "$rc" -eq 0 ] && has "$v" 'deep('; } ; echo $? )"

printf '\n── (g) the operator CLI: bounded, and its operand is honoured ─────────────────\n'
# ⛔ Both of these were wrong and neither suite noticed (#2333 review P2): `--repo` as the LAST
# argument left `shift 2` a no-op, so the option loop spun for ever (`timeout 5` → rc 124), and the
# `ceiling` verb read `${2:-1}` AFTER the loop had shifted the operand away, so it always answered
# for ONE runner — the one surface an operator has for sanity-checking the derivation.
# ⛔ The CLI is driven by REDIRECT, not by `$(bash "$MOD" …)`: an interpreter invoked with a
# variable path INSIDE a command substitution is exactly the shape the hub's script-backdoor guard
# must refuse (it cannot see what that script would run), and reading its output through a file keeps
# this arm honest without asking the guard to relax a rule that exists for a reason.
bash "$MOD" ceiling 5 > "$T/g1.out" 2>/dev/null; grc=$?
n="$(tr -d '\n' < "$T/g1.out")"
# ⛔ NO BACKTICKS INSIDE THESE DESCRIPTIONS (#2333 review cycle 2, P2): a backtick inside a
# double-quoted string is COMMAND SUBSTITUTION — measured `line 314: ceiling: command not found`, and
# the assertion text printed mangled (`(g1)  honours its operand`), destroying the suite's own record
# of which CLI form it pinned. Same class as the `git commit -m` rule in AGENTS.md.
ck "(g1) 'ceiling 5' honours its operand (ceil(5*20/10)=10, got '$n', rc=$grc)" "$( [ "$n" = 10 ]; echo $? )"
bash "$MOD" ceiling --runners 7 > "$T/g2.out" 2>/dev/null
n="$(tr -d '\n' < "$T/g2.out")"
ck "(g2) 'ceiling --runners 7' => 14 (got '$n')" "$( [ "$n" = 14 ]; echo $? )"
bash "$MOD" status --repo >/dev/null 2>&1; rc=$?
ck "(g3) '--repo' as the LAST word exits 64 instead of looping for ever (rc=$rc)" "$( [ "$rc" -eq 64 ]; echo $? )"

printf '\n──────────────────────────────────────────────────────────────────────\n'
printf 'ci-queue.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s' "$FAILED_LINES" | sed 's/^/  - /'; exit 1; fi
printf 'CLEAN\n'
exit 0
