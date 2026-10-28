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
    # ⛔ CIQ_TEST_NOTOTAL=1 answers 200 with a body that carries NO parseable `total_count` — the
    # ANSWERED-but-UNPARSEABLE shape (#2333 review cycle 12, P1). It is branch (c) and must fail
    # CLOSED to the measured floor; until cycle 12 the empty `declared` selected the hosted ALLOWANCE
    # here, i.e. a 200 with an unusable body quadrupled the ceiling (40 vs 10) on a repo with no
    # self-hosted runner online, and ALLOWED the incident's own 31-deep queue.
    [ "${CIQ_TEST_NOTOTAL:-0}" = "1" ] && { printf '{\n  "runners": []\n}\n'; exit 0; }
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

feed() { # <queued> <running> <runners> [busy] [offline] [no-total-count]
  state
  qenv "$STUB" 0 900
  CIQ_STATE_DIR="$T/state"; export CIQ_STATE_DIR
  CIQ_TEST_QUEUED="${1:-0}"; CIQ_TEST_RUNNING="${2:-0}"
  CIQ_TEST_RUNNERS="${3:-0}"; CIQ_TEST_BUSY="${4:-true}"; CIQ_TEST_OFFLINE="${5:-0}"
  CIQ_TEST_NOTOTAL="${6:-0}"
  export CIQ_TEST_QUEUED CIQ_TEST_RUNNING CIQ_TEST_RUNNERS CIQ_TEST_BUSY CIQ_TEST_OFFLINE CIQ_TEST_NOTOTAL
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
has "$v" 'ceiling=40'
ck "(b6b) a refused runner read never takes the hosted ALLOWANCE (the permissive direction)" "$( [ $? -ne 0 ]; echo $? )"
has "$v" 'runners=~1'
ck "(b6b2) …it takes the documented 1-runner floor (got: ${v})" "$?"
# A garbled `running` must not become a ceiling the gate can never reach: 9 digits pass
# `ciq_is_count` and would yield ceiling ~2e9, switching back-pressure off silently.
# ⛔ AND IT MUST NOT BECOME THE FLEET SIZE AT ALL (#2927). This arm replaces the old "clamped by the
# allowance" shape: with NOTHING measured, the in-progress count is DEMAND answering a SUPPLY
# question, so a garbled `running` now lands on the same 1-runner floor as any other number.
feed 5 499999999 -
ciq_read "$OR" >/dev/null 2>&1
v="$(ciq_eval)"
# ⛔ THE ORDER CONSTRAINT IS PART OF THIS ARM (#2969 review cycle 2, P2), carried onto #2927's
# VALUES. Two independent `has()` calls accept `ceiling=2 runners=~1` — the derivation BEFORE its
# input, which `ciq_eval` never emits (`runners=%s ceiling=%s`, input first) — where a single
# ordered glob refuses it. `[[ ]]`, not `case`, because this file must never reintroduce the
# `case`-in-`$( )` shape it exists to catch.
has "$v" 'ceiling=2'
ck "(b6c) an absurd \`running\` is never made the ceiling (got: ${v})" "$?"
has "$v" 'runners=~1'
ck "(b6c2) …and it is never made the FLEET either" "$?"
ck "(b6c1) …and the two tokens appear in DERIVATION order: input \`runners=\` before \`ceiling=\` (got: ${v})" "$( [[ $v == *'runners=~1'*'ceiling=2'* ]]; echo $? )"
# ⛔ THE MEASURED DEFECT, ARMS (b6d)/(b6e) — 2026-10-27, cell 4 (#2927). The live line was
# `runners=~2 => ceiling=4 => DEEP` with `queued=33 running=2` on a repo whose 8-registered fleet was
# all online and idle: the ceiling was derived from the jobs EXECUTING, so the gate read the box's own
# load as the world's capacity, and 41 consecutive PR-REPAIR dispatches were skipped by it.
# (b6d) is that exact reading: the fleet size was not read, so `running=2` must not become `~2`.
feed 33 2 -
v="$(ciq_read "$OR" >/dev/null 2>&1; ciq_eval)"
has "$v" 'runners=~2'
ck "(b6d) the measured 2026-10-27 shape: an unreadable fleet size is NOT reported as the in-progress count (got: ${v})" "$( [ $? -ne 0 ]; echo $? )"
has "$v" 'runners=~1'
ck "(b6d2) …it is reported as the documented floor, and the ceiling from it" "$?"
has "$v" 'fleet=unreadable(the actions/runners endpoint refused'
ck "(b6d3) …and the line NAMES the reading that failed, in the endpoint's own words" "$?"
# (b6e) the same queue numbers with a FLEET that can be read: the 8 online runners must decide, and
# the queue must then be deep. This is the arm that makes (b6d) a measurement of the FLEET and not a
# blanket "always small".
feed 33 2 8
v="$(ciq_read "$OR" >/dev/null 2>&1; ciq_eval)"
has "$v" 'runners=8'
ck "(b6e) a READABLE fleet is what the ceiling is derived from (got: ${v})" "$?"
has "$v" 'ceiling=16'
ck "(b6e2) …ceiling=ceil(8*20/10)=16, and 33 queued is over it (so new work still defers)" "$?"
feed 97 7 0
ciq_ci_allowed "$OR"; d0=$?
ck "(b7) hosted CI, zero repo runners: the MEASURED incident (97) is DEFERRED" "$( [ "$d0" -eq 1 ]; echo $? )"
feed 4 1 0
ciq_read "$OR" >/dev/null 2>&1
has "${CIQ_RUNNERS:-?}" '~'
ck "(b8) an unmeasured runner count is DECLARED inferred in the record (runners=${CIQ_RUNNERS:-?})" "$?"
v="$(ciq_eval)"
has "$v" 'ceiling=40'
ck "(b9) the ceiling comes from the allowance, not from \`running\` (ceiling=40, got: ${v})" "$?"
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
ck "(b12) declared-but-offline still honours \`running\` (4 queued, 7 running => ceiling 14 => ALLOWED)" \
   "$( [ "$d0" -eq 0 ]; echo $? )"
# ⛔ AN ANSWERED PAGE WITH NO PARSEABLE `total_count` IS BRANCH (c), NOT THE HOSTED ZERO (#2333 review
# cycle 12, P1). `declared` is EMPTY exactly when the answered body carried no readable count — the
# unparseable shape (c) says must fail CLOSED — and that emptiness used to select the ALLOWANCE, so a
# 200 with an unusable body on a repo with nothing online gave runners=~20 / ceiling 40 and ALLOWED the
# incident's own queue. Both arms below are red on the pre-fix tree (ceiling 40 => allowed).
feed 31 5 0 true 0 1
ciq_ci_allowed "$OR"; d0=$?
ck "(b13) an answered-but-UNPARSEABLE runners body fails CLOSED (31 queued => 1-runner floor => DEFERRED)" \
   "$( [ "$d0" -eq 1 ]; echo $? )"
feed 31 5 0 true 0 1
ciq_read "$OR" >/dev/null 2>&1
ck "(b14) …and the record carries the documented floor, never the allowance (runners=${CIQ_RUNNERS:-?})" \
   "$( [ "${CIQ_RUNNERS:-}" = '~1' ]; echo $? )"
v="$(ciq_eval)"
has "$v" 'fleet=unreadable(the actions/runners page carried no parseable total_count)'
ck "(b14b) …and the line says WHAT it could not read (got: ${v})" "$?"

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
# ⛔ EVERY HAND-MADE RECORD CARRIES `repo=` (#2333 review, P2). The record's identity is part of
# its SHAPE now that ciq_record_usable refuses a mismatch — an arm that omitted it would be testing
# the guard's refusal instead of the window it names. `$OR` is the repo these arms read.
printf 'repo=%s\nqueued=31\nrunning=5\nrunners=~6\nbusy=\nat=%s\n' "$OR" "$(date +%s)" > "$REC"
qenv /nonexistent-gh 0 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c4b) an INFERRED record (runners=~6) is served as cache, with age (rc=$rc state=${CIQ_STATE:-?})" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ] && [ "${CIQ_RUNNERS:-}" = '~6' ]; } ; echo $? )"
# ⛔ A FUTURE `at=` IS NOT A FRESH RECORD (#2333 review cycle 2, P2). The old clamp (`age<0 → 0`) made
# a record written under a forward-stepped clock answer `cache age=0s` FOR EVER — neither the TTL nor
# the staleness window could bind, so the one fail-open in this module was unbounded. A future stamp
# is unusable: the live read decides, and when it fails the verdict is UNKNOWN (fail closed).
future=$(( $(ciq_now) + 600 ))
printf 'repo=%s\nqueued=31\nrunning=5\nrunners=5\nbusy=5\nat=%s\n' "$OR" "$future" > "$REC"
qenv /nonexistent-gh 900 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c4c) a FUTURE-stamped record is NOT served (rc=$rc state=${CIQ_STATE:-?}) — no unbounded cache" \
   "$( { [ "$rc" -eq 2 ] && [ "${CIQ_STATE:-}" = unknown ]; } ; echo $? )"
# ⛔ THE TTL BOUND ITSELF WAS PINNED BY NOTHING (#2333 review round 2, P1 — a FALSE PASS). (c4) asserts
# that a TTL hit is LABELLED cache and carries an age; it never drives a record OLDER than the TTL, so
# deleting the `[ "$age" -le "$ttl" ]` bound left this suite 103 passed / 0 failed CLEAN while the
# module's ONE documented fail-open became UNBOUNDED: a record stamped 1000s ago with CIQ_TTL=90 kept
# answering `ok(...)` from the cache on a gh OUTAGE — back-pressure silently inert, and CIQ_TTL (a
# documented operator knob) inert with it. The stale record is driven, and the mutant below proves the
# arm can go red.
old=$(( $(ciq_now) - 1000 ))
# ⛔ THE RECORD CARRIES ITS REPO (#2333 review round 3, P2). Without `repo=` the wrong-surface guard
# refuses this record BEFORE the age is compared, so (c4d) was a FALSE PASS: deleting the TTL bound
# from the module left it green, because the arm was red-proof only for the guard it did not name.
printf 'repo=%s\nqueued=1\nrunning=0\nrunners=5\nbusy=5\nat=%s\n' "$OR" "$old" > "$REC"
qenv /nonexistent-gh 90 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c4d) a record OLDER than the TTL is NOT served (rc=$rc state=${CIQ_STATE:-?}) — the cache cannot outlive its bound" \
   "$( { [ "$rc" -eq 2 ] && [ "${CIQ_STATE:-}" = unknown ]; } ; echo $? )"
mutcad="$T/mutant-cache"
mkdir -p "$mutcad"
drive_read() { # <module> <state-dir> -> "<rc>|<state>" for a 1000s-old record with the live read failing
  ( unset -f ciq_is_num ciq_is_count ciq_horizon_min ciq_job_p90_min ciq_hosted_concurrency \
             ciq_ceiling ciq_slug ciq_state_dir ciq_gh ciq_now ciq_read ciq_eval ciq_verdict \
             ciq_defer_line ciq_defer_note ciq_defer_note_here ciq_ci_allowed 2>/dev/null
    mkdir -p "$2"
    CIQ_GH=/nonexistent-ciq-gh; CIQ_TTL=90; CIQ_STALE_MAX=900; CIQ_STATE_DIR="$2"
    export CIQ_GH CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
    printf 'repo=daniel-ospina/agent-infra\nqueued=1\nrunning=0\nrunners=5\nbusy=5\nat=%s\n' "$(( $(date +%s) - 1000 ))" \
      > "$2/ci-queue-daniel-ospina_agent-infra"
    # shellcheck source=/dev/null
    . "$1" >/dev/null 2>&1 || { printf 'NO-LOAD|'; return; }
    ciq_read "daniel-ospina/agent-infra" >/dev/null 2>&1; local rc=$?
    printf '%s|%s' "$rc" "${CIQ_STATE:-}"
  ) 2>/dev/null
}
got="$(drive_read "$MOD" "$T/cache-shipped")"
ck "(c4d2) CONTROL — the SHIPPED module answers '$got' through the same driver, so (c4e) is a mutation and not a restatement" \
   "$( [ "$got" = '2|unknown' ]; echo $? )"
# ⛔ THE MUTATION IS LINE-SHAPE INDEPENDENT (#2333 review). It used to `sed` the single-line
# `&& [ "$age" -le "$ttl" ]; then` form; when the condition grew a continuation (the wrong-surface
# guard on the next line) the pattern stopped matching, the mutant came out byte-identical and this
# arm went red for the WRONG reason — it proved nothing about the bound. The awk below replaces the
# WHOLE two-line condition with `if true; then`, so it survives any re-wrapping of the bound.
awk '
  /^      if \[ "\$age" -ge 0 \] && \[ "\$ttl" -ge 1 \] && \[ "\$age" -le "\$ttl" \] \\$/ {
    print "      if true; then"
    getline   # drop the continuation line (`&& ciq_record_usable …; then`)
    next
  }
  { print }
' "$MOD" > "$mutcad/ci-queue.sh"
# Fallback for a module whose condition is still ONE line: rewrite it in place.
if cmp -s "$MOD" "$mutcad/ci-queue.sh"; then
  sed 's/&& \[ "\$age" -le "\$ttl" \]; then/; then/' "$MOD" > "$mutcad/ci-queue.sh"
fi
if cmp -s "$MOD" "$mutcad/ci-queue.sh"; then
  bad "(c4e) the cache-bound mutation did not apply — this arm would prove nothing"
elif ! bash -n "$mutcad/ci-queue.sh" 2>/dev/null; then
  bad "(c4e) the cache-bound mutant does not parse — a broken mutant proves nothing"
else
  mgot="$(drive_read "$mutcad/ci-queue.sh" "$T/cache-mutant")"
  ck "(c4e) MUTANT — an UNBOUNDED ttl SERVES the stale record (got '$mgot'), so (c4d) is not always-green" \
     "$( [ "${mgot%%|*}" = 0 ]; echo $? )"
fi
# A record stamped in 1970, past a 0-second staleness window, with the live read failing: the queue
# is UNREADABLE, and an unreadable queue is never "empty".
feed 31 5 5
ciq_read "$OR" >/dev/null 2>&1
printf 'repo=%s\nqueued=31\nrunning=5\nrunners=5\nbusy=5\nat=1\n' "$OR" > "$REC"
qenv /nonexistent-gh 0 0
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c5) an unreadable queue PAST the staleness window is UNKNOWN (rc 2), never 'empty'" \
   "$( [ "$rc" -eq 2 ]; echo $? )"
now="$(date +%s)"; old=$(( now - 10 ))
printf 'repo=%s\nqueued=31\nrunning=5\nrunners=5\nbusy=5\nat=%s\n' "$OR" "$old" > "$REC"
qenv /nonexistent-gh 0 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
ck "(c6) an unreadable queue INSIDE the window falls back to the record and SAYS so (state=cache)" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ]; } ; echo $? )"

printf '\n── (c6b) the FLEET disclosure survives the cache ─────────────────────────\n'
# ⛔ A DISCLOSURE THAT LIVES ONLY IN MEMORY IS ABSENT ON THE PATH OPERATORS READ IT FROM (#2927 review,
# P3). `fleet=unreadable(...)` is the ONE place branch (c) says WHICH reading failed. It was printed
# from `CIQ_FLEET` and nothing else, while the record carried only repo/queued/running/runners/busy/at
# and both cache arms reset the field — so a TTL or staleness hit rendered `runners=~1 ceiling=2
# state=cache` with the *why* silently dropped, i.e. exactly the inference-presented-as-a-measurement
# the field exists to prevent, on the path (cache) the token exists for. `busy=` is the precedent: a
# disclosure field carried through the record. Pinned in three parts — the WRITER persists it, the
# READER restores it, and an OLDER record (no `fleet=` line) neither breaks nor invents one.
# ⛔ THE RECORD CARRIES THE VALUE, NOT THE KEY (#2927 review, P3). It used to read
# `fleet=fleet=unreadable(…)` on disk — the writer prefixed `fleet=` onto a value that already began
# with it. It round-tripped and (c6b) pinned the doubled form, so nothing broke; but an on-disk record
# is permanent text a human reads, so the writer now strips the key and the readers re-attach it
# (`ciq_fleet_restore`). (c6b) therefore pins the CORRECTED single-key form, and (c6d) pins that the
# restored token still names the failed reading.
feed 33 2 -
ciq_read "$OR" >/dev/null 2>&1
ck "(c6b) a branch-(c) read PERSISTS the fleet disclosure in the record, keyed ONCE" \
   "$(grep -q '^fleet=unreadable(' "$REC"; echo $?)"
ck "(c6b') …and the record does NOT carry the doubled key the writer used to emit" \
   "$([ "$(grep -c '^fleet=fleet=' "$REC")" = 0 ]; echo $?)"
qenv /nonexistent-gh 0 900
ciq_read "$OR" >/dev/null 2>&1; rc=$?
v="$(ciq_eval)"
ck "(c6c) …and the record is served as CACHE when the live read fails (rc=$rc state=${CIQ_STATE:-?})" \
   "$( { [ "$rc" -eq 0 ] && [ "${CIQ_STATE:-}" = cache ]; } ; echo $? )"
has "$v" 'fleet=unreadable(the actions/runners endpoint refused'
ck "(c6d) …and the CACHED token still NAMES the reading that failed (got: ${v})" "$?"
# An older record has no `fleet=` line at all: it must restore as EMPTY (no behaviour change), never
# as a disclosure the writer did not put there.
printf 'repo=%s\nqueued=4\nrunning=2\nrunners=~1\nbusy=\nat=%s\n' "$OR" "$(date +%s)" > "$REC"
ciq_read "$OR" >/dev/null 2>&1; rc=$?
v="$(ciq_eval)"
ck "(c6e) a record with NO fleet= line (an older record) still serves (rc=$rc)" \
   "$( [ "$rc" -eq 0 ]; echo $? )"
has "$v" 'fleet='
ck "(c6f) …and it INVENTS no disclosure (got: ${v})" "$( [ $? -ne 0 ]; echo $? )"
# ⛔ A RECORD WRITTEN BY THE PRE-FIX WRITER CAN STILL BE ON DISK (#2928 review, P3). The record is
# permanent text in a state dir shared with whatever else runs out of it, so the mixed-version
# direction a reader CAN close from its own side — an OLD record read by THIS reader — must be
# tolerated rather than stepped over: `ciq_fleet_restore` strips a stored `fleet=` before attaching
# its own, so both shapes restore keyed exactly ONCE. (c6g') is the assertion that goes red if that
# tolerance is dropped (the token would render `fleet=fleet=unreadable(…)` — the doubled form back).
printf 'repo=%s\nqueued=4\nrunning=2\nrunners=~1\nbusy=\nfleet=fleet=unreadable(the actions/runners endpoint refused: HTTP 404) fallback=runners=~1\nat=%s\n' \
  "$OR" "$(date +%s)" > "$REC"
ciq_read "$OR" >/dev/null 2>&1; rc=$?
v="$(ciq_eval)"
ck "(c6g) a PRE-FIX record (doubled key on disk) still serves as a reading (rc=$rc)" \
   "$( [ "$rc" -eq 0 ]; echo $? )"
has "$v" 'fleet=unreadable('
ck "(c6g') …and the key is restored exactly ONCE, not doubled (got: ${v})" \
   "$( [ $? -eq 0 ] && ! grep -q -F -- 'fleet=fleet=' <<<"$v"; echo $? )"

printf '\n── (c7) UNKNOWN defers (fail closed), and says which it was ───────────────\n'
state
qenv /nonexistent-gh 0 0
msg="$(ciq_defer_note "CI-red fixer for #9")"; rc=$?
ck "(c7) an unreadable queue DEFERS rather than opening the gate" "$( [ "$rc" -eq 0 ]; echo $? )"
has "$msg" 'unknown('
ck "(c8) and the line says UNKNOWN, not a made-up depth" "$?"
# ⛔ THE PREDICATE'S FAIL-CLOSED BRANCH WAS PINNED BY NOTHING (#2333 review, P1 — a FALSE PASS). (c7)
# drives `ciq_defer_note`, which goes through `ciq_verdict`; it never touches `ciq_ci_allowed` — the ONE
# predicate the shipping callers branch on (fix-one.sh:99, dispatch-merge.sh:119). Widening its
# whitelist from `1)` to `1|2)` therefore makes an UNREADABLE queue ALLOW every fixer and every batch —
# exactly the fail-open the module header forbids — while this suite stayed 91 passed / 0 failed CLEAN,
# because every other `ciq_ci_allowed` arm in this file runs against a READABLE feed. Driven here, and
# the mutant below proves the arm can go red.
ciq_ci_allowed "$OR"; prc=$?
ck "(c9) the PREDICATE the wiring branches on refuses an UNKNOWN queue (ciq_ci_allowed rc=$prc)" \
   "$( [ "$prc" -eq 1 ]; echo $? )"
mutp="$T/mutant-pred"
mkdir -p "$mutp"
# The mutant is a PARSED widening of that one line, driven in a CLEARED function namespace (a subshell
# inherits this suite's functions otherwise, and the arm would read green on code it never ran).
drive_pred() { # <module-path> <state-dir> -> the predicate's rc on an UNREADABLE queue
  ( unset -f ciq_is_num ciq_horizon_min ciq_job_p90_min ciq_ceiling ciq_slug ciq_state_dir \
             ciq_gh ciq_now ciq_read ciq_eval ciq_verdict ciq_defer_line ciq_defer_note \
             ciq_defer_note_here ciq_ci_allowed 2>/dev/null
    mkdir -p "$2"
    CIQ_GH=/nonexistent-ciq-gh; CIQ_TTL=0; CIQ_STALE_MAX=0; CIQ_STATE_DIR="$2"
    export CIQ_GH CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
    # shellcheck source=/dev/null
    . "$1" >/dev/null 2>&1 || { printf 'NO-LOAD'; return; }
    ciq_ci_allowed "daniel-ospina/agent-infra"; printf '%s' "$?"
  ) 2>/dev/null
}
sed 's/in 1) return 0 ;; \*) return 1 ;; esac/in 1|2) return 0 ;; *) return 1 ;; esac/' "$MOD" > "$mutp/ci-queue.sh"
if cmp -s "$MOD" "$mutp/ci-queue.sh"; then
  bad "(c10) the predicate mutation did not apply — this arm would prove nothing"
elif ! bash -n "$mutp/ci-queue.sh" 2>/dev/null; then
  bad "(c10) the predicate mutant does not parse — a broken mutant proves nothing"
else
  mprc="$(drive_pred "$mutp/ci-queue.sh" "$T/predstate-mutant")"
  ck "(c10) MUTANT — a whitelist widened to '1|2' ALLOWS an UNKNOWN queue (rc=$mprc), so (c9) is not always-green" \
     "$( [ "$mprc" = 0 ]; echo $? )"
fi

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
             ciq_gh ciq_now ciq_read ciq_eval ciq_verdict ciq_defer_note ciq_defer_note_here \
             ciq_ci_allowed 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    declare -f ciq_read ciq_ci_allowed ciq_defer_note ciq_defer_note_here >/dev/null 2>&1 \
      || { echo 'INTERFACE-MISSING'; exit 0; }
    feed 31 5 5
    ciq_ci_allowed "$OR"; printf 'allowed=%s\n' "$?"
    ciq_defer_note "CONFLICTED fixer for #1234 (a push to fix/x invalidates head abc123)"
  ) 2>/dev/null
}
# ⛔ THE WIRING'S OWN NOTE, DRIVEN (#2333 merge review, P2). `drive_arm` above drives
# `ciq_defer_note`, the STANDALONE entry point (it re-reads). Every shipping caller uses
# `ciq_defer_note_here` instead, and until this driver existed NO arm executed it — so a mutant whose
# body was `return 1` silenced every daemon deferral line while the suite reported CLEAN.
drive_note() { # <module-path> -> the predicate's answer + the IN-SHELL note (empty when silenced)
  (
    unset -f ciq_is_num ciq_horizon_min ciq_job_p90_min ciq_ceiling ciq_slug ciq_state_dir \
             ciq_gh ciq_now ciq_read ciq_eval ciq_verdict ciq_defer_note ciq_defer_note_here \
             ciq_ci_allowed ciq_defer_line 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    declare -f ciq_read ciq_ci_allowed ciq_defer_note_here >/dev/null 2>&1 \
      || { echo 'INTERFACE-MISSING'; exit 0; }
    feed 31 5 5
    ciq_ci_allowed "$OR"; printf 'allowed=%s\n' "$?"
    printf 'note='; ciq_defer_note_here "CONFLICTED fixer for #1234"
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
# ⛔ THE TWO READS ARE PINNED BY SHAPE *AND* BY COUNT (#2333 review, P1). This arm used to be two
# naked `grep -q`s, and BOTH literals also occur in the sweep predicate well above the dispatch
# block (`ciq_read "${OR:-}" >/dev/null 2>&1 || true` and the same eval pair), so the greps stayed
# satisfied with the DISPATCH block's own read DELETED. `CIQ_RC` is set to 1 just before that read,
# so the deletion leaves it 1 (= allowed) for ever: the issue-path arm
# (`[ "${CIQ_RC:-1}" != "1" ]`) can never fire, the fleet opens new PRs into a 92-deep queue, and
# ci-queue.test.sh plus product-floor.test.sh both read CLEAN — measured on a copy (116/0 and
# 213/0). The count is the pin: exactly TWO reads, exactly ONE of them the sweep's soft (`|| true`)
# form — which is what makes the SECOND one the dispatch block's — and the eval pair exactly twice.
ck "(e2) orch-loop.sh reads the queue IN THIS SHELL (not a subshell), once per PASS — at most two live reads a cycle, the sweep's and the dispatch block's (2 reads, 1 soft/sweep, 2 eval pairs)" \
   "$( { [ "$(grep -cF 'ciq_read "${OR:-}"' "$LOOP")" -eq 2 ] \
        && [ "$(grep -cF 'ciq_read "${OR:-}" >/dev/null 2>&1 || true' "$LOOP")" -eq 1 ] \
        && [ "$(grep -cF 'CIQ_VER="$(ciq_eval)"; CIQ_RC=$?' "$LOOP")" -eq 2 ]; } ; echo $? )"
# ⛔ THE SHIPPED FORM, NOT THE RENDERED VALUE (#2927): the gate VECTOR made every arm assign through
# `${GATE_WHY:-…}` so a later arm cannot overwrite the first one that fired. The rendered `GATE_WHY`
# is unchanged — `ci-queue($CIQ_VER)` — so this pin follows the assignment the module actually performs.
grep -F -q 'GATE_WHY="${GATE_WHY:-ci-queue($CIQ_VER)}"' "$LOOP"
ck "(e3) the ISSUE path is gated on it (the ci-queue gate arm)" "$?"
n="$(grep -cF 'if ciq_push_ok; then' "$LOOP")"
# ⛔ THE THREE FIXER SPAWN ARMS NO LONGER CONSULT THE QUEUE AT ALL (#2927). They are REPAIR — they act
# on a PR that already exists — and the class rule in ci-queue.sh's header says only work that ADDS a
# new CI run is queue-gated. ⛔ NOT because the pass is "already spent": a repair push DOES start a
# fresh run. The basis is #2927's decision plus the measurement below. Measured 2026-10-27: those calls were
# the last-line half of a gate that skipped 41 consecutive repair dispatches while 8 self-hosted
# runners and ~11 lane slots sat idle. This is a COUNT OF ZERO on purpose: a reintroduced gate on any
# fixer arm reddens here.
ck "(e4) NO fixer spawn arm consults the CI queue — a fixer is repair, not CI-spending work (found $n, expected 0)" \
   "$( [ "$n" -eq 0 ]; echo $? )"
# ⛔ COUNT CODE, NOT PROSE (the same false RED test-gates.sh carried — #2762 review): two COMMENTS in
# orch-loop.sh quote `-lt "$MF"` to explain the drain-aware ceiling, so a raw `grep -c` counted 5 and
# this arm was red on a correct tree. The pin (exactly one comparison per spawn site) is unchanged.
m="$(grep -F -- '-lt "$MF"' "$LOOP" | grep -vc '^[[:space:]]*#')"
ck "(e4-eligibility) …and every fixer spawn site still carries its own capacity/claim eligibility — exactly ONE \$MF comparison per site (found $m, expected 3, which is the count test-gates.sh asserts) with no sibling '! ciq_push_ok' defer arm left behind" \
   "$( { [ "$n" -eq 0 ] && [ "$m" -eq 3 ] && [ "$(grep -c 'elif ! ciq_push_ok; then' "$LOOP")" -eq 0 ]; } ; echo $? )"
ck "(e4b) …the review-gate fixer included — its eligibility predicate is no longer shared with a queue gate" \
   "$( grep -q '_fix_eligible" = "1" ] && ciq_push_ok' "$LOOP"; [ $? -ne 0 ]; echo $? )"
ck "(e4c) …and the hoisted predicate is still what the park/re-record chain asks, so a non-eligible PR is never reported as anything else" \
   "$( grep -q '_fix_eligible" = "1" ]; then' "$LOOP"; echo $? )"
n="$(grep -c 'ciq_defer_note_here "CONFLICTED fixer' "$LOOP")"; m="$(grep -c 'ciq_defer_note_here "CI-red fixer' "$LOOP")"
ck "(e5) neither fixer arm emits a queue deferral line any more (CONFLICTED=$n CI-red=$m, expected 0 0)" \
   "$( { [ "$n" -eq 0 ] && [ "$m" -eq 0 ]; } ; echo $? )"
n="$(grep -c 'ci-queue(${CIQ_VER:-unmeasured})' "$LOOP")"
# ⛔ WHAT THIS PINS, AND WHAT IT DOES NOT. It pins the ROW COUNT — the ONE arm still queue-gated in
# this block (the CI rerun, which genuinely adds a run to the queue) carries a wait disposition naming
# the verdict it decided on — and that no arm defaults to `deep` (e6b). It no longer pins the default
# `${…:-unmeasured}` on the FIXER rows, because those rows are gone with the gate.
ck "(e6) exactly ONE CI-SPENDING arm is still queue-gated in this block — the RERUN — and it writes a wait disposition carrying the verdict it decided on (n=$n)" \
   "$( [ "$n" -eq 1 ]; echo $? )"
ck "(e6b) no arm DEFAULTS the verdict to \`deep\` — a label the arm never measured" \
   "$( grep -q 'CIQ_VER:-deep' "$LOOP"; [ $? -ne 0 ]; echo $? )"
ck "(e6c) …and the rerun is the site that calls the predicate (one call site, measured)" \
   "$( [ "$(grep -cF '! ciq_push_ok' "$LOOP")" -eq 1 ]; echo $? )"
# ⛔ fix-one.sh IS ALSO REACHED DIRECTLY and by adopt-fix.sh, so its own gate had to go with the
# controller's — otherwise the last-line half of the gate survives on the paths nobody watches.
ck "(e7) fix-one.sh does NOT gate the lane that PUSHES (no module sourced, no predicate call)" \
   "$( { grep -q 'ciq_ci_allowed' "$FIX" || grep -qF '. "$SELF/ci-queue.sh"' "$FIX"; } ; [ $? -ne 0 ]; echo $? )"
grep -q 'fixbail-\$PR-\$HEAD' "$FIX"
ck "(e8) …and the refusals it DOES still make (cross-box CAS, load/disk) keep writing the refundable bail marker, so no attempt is consumed" "$?"
grep -q 'ci-queue.sh' "$DISPATCH" && grep -F -q 'ciq_defer_note_here "the whole batch' "$DISPATCH"
ck "(e9) dispatch-merge.sh (the batch stampede) reads the same module and defers the batch" "$?"
# ⛔ THE MODULE'S VERDICT IS PINNED BEHAVIOURALLY, NOT BY VOCABULARY (#2333 review, P1). The arm this
# replaces grepped the module for two literal substrings (`LANES…-ge`, `MAX_LANES=`). Measured in both
# directions and both were wrong: a lane cap under ANY other identifier stayed GREEN, while DOCUMENTING
# the ruling in the module header (a comment naming `MAX_LANES`) turned it RED, so the cheapest way to
# clear a red was to delete the explanation of the decision.
#
# ⛔ WHAT THESE ARMS ASSERT, EXACTLY — AND WHAT THEY DO NOT (#2333 review cycle 3, P2). They pin that
# THIS MODULE's verdict cannot be moved by a lane count, and that the module contains no lane-cap
# comparison in executable lines. They do NOT census the three WIRING files: a lane cap added to
# `orch-loop.sh`/`fix-one.sh`/`dispatch-merge.sh` stays green here, and so does a cap in this module that
# reads lanes through a name these stubs do not shim (`command tmux ls`, a lane-count FILE). Measured, not
# assumed: each of those three mutants is 79/79 CLEAN against these arms. Do NOT restate the coverage as
# "no lane cap can be reintroduced" — a lexical census of the wiring files cannot be written at all, since
# they legitimately contain `wt_count fix-` and `LANES…-ge` for the pre-existing `MAX_LANES` cap that the
# owner ruling of 2026-10-17 governs (orch-loop.sh: "MAX_LANES IS REPAIRED TO ITS OWN DERIVED DEFAULT").
# A behavioural pin on the DISPATCH DECISION itself (extract that block and drive it, the way (h0)/(h0b)
# drive `ciq_push_ok`) is the successor, and it is named as a residual rather than claimed here.
#
# The stubs are shell FUNCTIONS because the harness counts lanes with `wt_count` (a sourced function,
# invisible to a PATH stub) as well as `tmux ls`; they are unset immediately so no later arm can see them.
_lanestub() {
  wt_count() { echo 99; }
  tmux() { echo "fix-a"; echo "fix-b"; echo "merge-c"; }
}
feed 4 5 5
_lanestub
ciq_ci_allowed "$OR"; d0=$?
unset -f wt_count tmux
ck "(e10) an implausible LANE fleet does not defer a SHALLOW queue — THIS MODULE's verdict is the queue's" "$( [ "$d0" -eq 0 ]; echo $? )"
feed 97 5 5
_lanestub
ciq_ci_allowed "$OR"; d0=$?
unset -f wt_count tmux
ck "(e10b) …and the same lane stub cannot ALLOW a DEEP queue (the queue alone decides)" "$( [ "$d0" -eq 1 ]; echo $? )"
# The lexical tripwire is KEPT, RENAMED to what it actually checks, and scoped to EXECUTABLE lines so it
# can no longer red on the comment that documents the ruling.
_lex="$(grep -vE '^[[:space:]]*#' "$MOD" | grep -nE 'LANES[^a-z]*-ge|MAX_LANES=' || true)"
ck "(e10c) the module contains no lane-cap COMPARISON in executable lines (got '${_lex:-<none>}')" "$( [ -z "$_lex" ]; echo $? )"
# ⛔ THE NOTE MUST EVALUATE THE DECISION'S OWN READING (#2333 review P1). `ciq_defer_note` re-reads;
# on a queue that moved between the decision and the note it could DISAGREE and print NOTHING — a
# deferral with no line, the one failure the module exists to prevent — and it cost three extra `gh`
# calls per deferred PR. Every wiring site uses the in-shell entry point; this arm is what stops a
# future edit reverting one of them.
n="$(grep -c 'ciq_defer_note_here "' "$LOOP")"; m="$(grep -c 'ciq_defer_note_here "' "$FIX")"; p="$(grep -c 'ciq_defer_note_here "' "$DISPATCH")"
# ⛔ THE COUNTS ARE 2 AND 0, NOT 4 AND 1, AND THAT IS #2927: `orch-loop.sh` keeps the IN-SHELL note at
# the ONE arm still queue-gated (the CI rerun) and `fix-one.sh` has none because a fixer is repair.
# `dispatch-merge.sh` is unchanged (new-PR production). The invariant this arm exists for is unchanged
# too — every deferral that still exists uses the IN-SHELL entry point, and the sum is pinned so a
# gate deleted here cannot be replaced by a re-reading call site.
ck "(e11) every wiring deferral uses the IN-SHELL note (loop=$n fixer=$m batch=$p, expected 1 0 1)" \
   "$( { [ "$n" -eq 1 ] && [ "$m" -eq 0 ] && [ "$p" -eq 1 ]; } ; echo $? )"
# ⛔ THE RE-READING ENTRY POINT IS A REFERENCE, NOT A WIRING TARGET (#2333 merge review, P3). Every
# shipping site must call the IN-SHELL note. `ciq_defer_note` RE-READS, and a second read can
# DISAGREE with the decision it was handed — and on a disagreement it prints NOTHING, i.e. a
# deferral with no line, the single failure this module exists to prevent. The module keeps it only
# as the differential reference the (a)/(b)/(c) arms drive; an edit that "restores" it at a call
# site is precisely the regression this arm makes red.
_wired=""
for _wf in "$LOOP" "$FIX" "$DISPATCH"; do
  _hit="$(grep -nE 'ciq_defer_note([^_]|$)' "$_wf" || true)"
  [ -n "$_hit" ] && _wired="${_wired}${_wf}:${_hit} "
done
ck "(e15) no shipping file calls the RE-READING ciq_defer_note — the wiring uses the in-shell note (found:${_wired:- none})" \
   "$( [ -z "$_wired" ]; echo $? )"
# ⛔ ONE READ PER PASS — INCLUDING WHEN THE READ FAILS (#2296 cycle 5, P2). The module's cache covers
# only a SUCCESSFUL read, so on the outage path every arm re-read live (measured: 15 `gh api` calls for
# 5 arms against a failing feed, versus 3 against a working one) — the gate's own cost then grew with
# the backlog, in the cycle where `gh-limit` is already the bottleneck. The predicate captures its
# verdict AND memoizes it, and the memo is reset with the rest of the per-cycle state.
ck "(e12) the gate's verdict is CAPTURED for the rows and MEMOIZED (one read per pass, even on failure)" \
   "$( { grep -q 'CIQ_ARM_RC="$CIQ_RC"; CIQ_ARM_VER="$CIQ_VER"' "$LOOP" && grep -q 'CIQ_ARM_RC=""' "$LOOP"; } ; echo $? )"
# ⛔ THE INCOMPLETE DISCLOSURE MUST NAME EVERY FUNCTION ITS OWN GUARD REQUIRES (#2333 review cycle 12,
# P2). Cycle 10 widened the three guards from six names to ten and left the three messages naming six,
# so the one line an operator reads to decide whether to re-seed announced six functions that were all
# PRESENT and none of the one that was missing. The names are literal in each message (a stale copy is
# the case being reported, so they cannot be rendered from the module), which is exactly why they can
# drift — this arm is the pin that catches the next widening.
# ⛔ DERIVED FROM THE FILE, NEVER RESTATED HERE (#2333 review, P1). This arm used to iterate a
# HARDCODED ten-name list and only ask "does the message contain each of these ten", so a WIDENING —
# the guard gains an 11th name, the message untouched — left it GREEN: the cycle-10 recurrence this
# comment claims to catch, reproduced in the pin itself (measured: add a name to the guard, run this
# suite, 120/0 CLEAN). Both sides are now EXTRACTED from the file: the `declare -f` list the guard
# requires, and the "needs a/b/c" list the operator reads. Equality is asserted, in order, so the
# next widening is RED until the message follows it — and the derivation cannot silently find
# nothing, because (e14) fails if either side is empty in any file.
guard_names() { sed -n 's/.*declare -f \(ciq_[a-z0-9_ ]*\) >\/dev\/null.*/\1/p' "$1" | head -1 | sed 's/ *$//'; }
# Anchored on the CI-QUEUE message: orch-loop.sh carries FOUR "is present but INCOMPLETE" lines
# (live-ownership, rail-refusal, capacity, ci-queue) and the first one's names are not these.
msg_names()   { sed -n 's/.*is present but INCOMPLETE (needs \(ciq_[^)]*\)).*/\1/p' "$1" | head -1 | tr '/' ' ' | sed 's/ *$//'; }
_discrep=""; _derived=0
for _f in "$LOOP" "$DISPATCH"; do
  _g="$(guard_names "$_f")"; _m="$(msg_names "$_f")"
  [ -n "$_g" ] && [ -n "$_m" ] && _derived=$(( _derived + 1 ))
  [ "$_g" = "$_m" ] || _discrep="$_discrep $(basename "$_f")"
done
ck "(e13) each INCOMPLETE disclosure names exactly the functions its own \`declare -f\` guard requires, in order — both sides derived from the file (discrepant:${_discrep:- none})" \
   "$( [ -z "$_discrep" ]; echo $? )"
ck "(e14) …and the derivation is non-vacuous: a guard list AND a message list were found in BOTH files that still load the module (found in $_derived/2)" \
   "$( [ "$_derived" -eq 2 ]; echo $? )"
# …and the file that STOPPED loading it carries neither — the positive form of (e7), so "no gate in
# fix-one.sh" is asserted by the same derivation rather than by a separate grep that could rot.
ck "(e14b) fix-one.sh carries NO interface guard and NO INCOMPLETE disclosure (it loads no module)" \
   "$( { [ -z "$(guard_names "$FIX")" ] && [ -z "$(msg_names "$FIX")" ]; } ; echo $? )"

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
# ⛔ THE MODULE-ABSENT FALLBACK IS DRIVEN TOO (#2333 review, P2 — a FALSE PASS closed here). The
# body's third load-bearing property is "a missing module never becomes a permanent stop", and it
# was pinned by NOTHING: every arm above drives the CIQ=1 predicate, and (e13)/(e14) grep the
# INCOMPLETE message. Measured before this arm existed: flipping the shipped `else` arm from
# `return 0` to `return 1` — the exact P0 the body says was fixed, a box with no `$O/ci-queue.sh`
# deferring every fixer for ever while the [ci-queue] line calls the arm inert — left ci-queue 83/0,
# pr-dispatch 36/0, selftest 464/0 and test-gates 395/0 ALL GREEN. The bytes that decide it are
# EXTRACTED from orch-loop.sh (not restated), so this arm fails when the shipped polarity changes.
FB="$T/fallback.sh"
awk '/^  ciq_push_ok\(\) \{ return 0; \}$/{print; exit}' "$LOOP" > "$FB"
ck "(h0d) the module-absent fallback was EXTRACTED from orch-loop.sh (not a restatement)" \
   "$( { [ -s "$FB" ] && grep -q 'return 0' "$FB" && ! grep -q 'CIQ_ARM_RC' "$FB"; } ; echo $? )"
fb_rc() { # drive a fallback file in a NAMESPACE WITH NO MODULE: nothing from this suite may leak in
  ( unset -f ciq_push_ok 2>/dev/null; . "$1"; ciq_push_ok; printf '%s' "$?" )
}
fbrc="$(fb_rc "$FB")"
ck "(h0e) a box with NO module ALLOWS (rc=$fbrc) — the fallback is 'arm inert', never 'defer for ever'" \
   "$( [ "$fbrc" = 0 ]; echo $? )"
# …and the arm is not always-green: the OPPOSITE polarity must fail it.
sed 's/return 0/return 1/' "$FB" > "$T/fallback-mutant.sh"
if cmp -s "$FB" "$T/fallback-mutant.sh"; then
  bad "(h0f) the fallback mutation did not apply — this arm would prove nothing"
elif ! bash -n "$T/fallback-mutant.sh" 2>/dev/null; then
  bad "(h0f) the fallback mutant does not parse — a broken mutant proves nothing about polarity"
else
  mrc="$(fb_rc "$T/fallback-mutant.sh")"
  ck "(h0g) MUTANT — the inverted fallback returns $mrc, so (h0e) goes red instead of passing a permanent stop" \
     "$( [ "$mrc" != 0 ]; echo $? )"
fi
# …and the INERT disclosure an operator reads must sit INSIDE the CIQ=0 arm (the else of the guard),
# not anywhere in the file: a line about an unsourced module printed on the CIQ=1 path would be a
# false statement about the box's own state, which is the defect cycle 12 fixed for the other arm.
_ciq0ln="$(grep -n '^  CIQ=0$' "$LOOP" | head -1 | cut -d: -f1)"
_inertln="$(grep -n 'the CI-queue arm is INERT this cycle' "$LOOP" | head -1 | cut -d: -f1)"
_grdln="$(grep -n '^if \[ "\${CIQ:-0}" = "1" \]; then$' "$LOOP" | head -1 | cut -d: -f1)"
n_inert="$(grep -c 'the CI-queue arm is INERT this cycle' "$LOOP")"
ck "(h0h) the INERT disclosure sits INSIDE the CIQ=0 arm (CIQ=0@${_ciq0ln:-?} < INERT@${_inertln:-?} < guard@${_grdln:-?}, n=$n_inert)" \
   "$( { [ -n "${_ciq0ln:-}" ] && [ -n "${_inertln:-}" ] && [ -n "${_grdln:-}" ] \
        && [ "$_inertln" -gt "$_ciq0ln" ] && [ "$_inertln" -lt "$_grdln" ] && [ "$n_inert" -eq 1 ]; } ; echo $? )"
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
# ⛔ THE ISSUE-PATH ARM'S "UNKNOWN ALSO DEFERS" POLARITY WAS PINNED BY NOTHING (#2333 review, P1 — a FALSE
# PASS). `(e3)` greps for the literal `GATE_WHY="ci-queue($CIQ_VER)"`, which a POLARITY mutant preserves
# verbatim: changing the shipped `${CIQ_RC:-1}" != "1"` to `= "0"` opens the ISSUE path on an UNREADABLE
# queue — fail-open on the one cycle the fleet cannot see — and the suite stayed 91/0 CLEAN (`grep -n
# CIQ_RC` finds the variable only in orch-loop.sh and this file, and product-floor's P6 scans the
# dispatch BODY, where the mutant keeps the matched text). The arm is EXTRACTED (not restated) and
# driven in four states, the way (h0)/(h0b) drive the predicate and its reset.
printf '\n── (h6) the ISSUE-path gate ARM, EXTRACTED and driven in both polarities ──────\n'
ARM_RAW="$T/gatearm.raw"
# ⛔ EXTRACTED BY ITS OWN BOUNDARIES, NOT BY AN `elif` LINE (#2927). The arm was one `elif … then`
# before the gate VECTOR; it is a nested guard now (the outer `if` closes on its `else …; fi` line, so
# a `/^  fi$/` range would still be right — but an `elif` anchor matches NOTHING and this rig then
# graded an EMPTY file: (h6) and its three sisters went red while (h6a)/(h6d)/(h6f) passed vacuously
# on nothing, which is the shape a polarity pin must never have. The range is now the arm's OWN
# markers: this file's other `if [ "${CIQ:-0}" = "1" ]` is the READ, not the gate, so a bare pattern
# anchor cannot tell the two apart.
sed -n '/# \[ciq-arm:begin\]/,/# \[ciq-arm:end\]/p' "$LOOP" | sed '1d;$d' > "$ARM_RAW"
ck "(h6) the ISSUE-path ci-queue arm was EXTRACTED from orch-loop.sh (not a restatement)" \
   "$( { [ -s "$ARM_RAW" ] && grep -q 'CIQ_RC' "$ARM_RAW" && grep -qF 'ci-queue($CIQ_VER)' "$ARM_RAW" \
        && grep -qF 'GATE_VEC=' "$ARM_RAW"; } ; echo $? )"
mkarm() { # <raw arm block> <out> — run the shipped block with GATE_WHY pre-set empty
  { printf 'GATE_WHY=""\nGATE_VEC=""\n'; cat "$1"; printf '\nprintf "%%s" "$GATE_WHY"\n'; } > "$2"
}
ARM="$T/gatearm.sh"; mkarm "$ARM_RAW" "$ARM"
gaw() { # <arm-file> <CIQ> <CIQ_RC> -> GATE_WHY as the arm renders it
  ( CIQ="$2"; CIQ_RC="$3"; CIQ_VER="deep(queued=31 running=5 runners=5 busy=5 ceiling=10)"
    # shellcheck source=/dev/null
    . "$1" )
}
g="$(gaw "$ARM" 1 1)"
ck "(h6a) an ALLOWED (rc=1) queue leaves the ISSUE path OPEN (GATE_WHY='${g:-}')" "$( [ -z "$g" ]; echo $? )"
g="$(gaw "$ARM" 1 0)"
ck "(h6b) a DEEP queue CLOSES it and names ci-queue (GATE_WHY='${g:-}')" "$( { [ -n "$g" ] && has "$g" 'ci-queue('; } ; echo $? )"
g="$(gaw "$ARM" 1 2)"
ck "(h6c) an UNKNOWN queue CLOSES it too — an unreadable queue is not an empty one (GATE_WHY='${g:-}')" "$( [ -n "$g" ]; echo $? )"
g="$(gaw "$ARM" 0 0)"
ck "(h6d) with the arm INERT (CIQ=0) even a DEEP queue leaves it open (GATE_WHY='${g:-}')" "$( [ -z "$g" ]; echo $? )"
ARM_MUT="$T/gatearm-mutant.sh"
sed 's/\[ "\${CIQ_RC:-1}" != "1" \]/[ "${CIQ_RC:-1}" = "0" ]/' "$ARM" > "$ARM_MUT"
if cmp -s "$ARM" "$ARM_MUT"; then
  bad "(h6e) the polarity mutation did not apply — this arm would prove nothing"
elif ! bash -n "$ARM_MUT" 2>/dev/null; then
  bad "(h6e) the polarity mutant does not parse — a broken mutant proves nothing about polarity"
else
  g="$(gaw "$ARM_MUT" 1 2)"
  ck "(h6f) MUTANT — a polarity flip OPENS the path on UNKNOWN (GATE_WHY='${g:-}'), so (h6c) is not always-green" \
     "$( [ -z "$g" ]; echo $? )"
fi

printf '\n── (f) A READING THAT DOES NOT FIT IS NOT A READING (an errored [ ] is FALSE) ──\n'
# ⛔ `[ … -gt … ]` ERRORS above intmax, an errored test is FALSE, and a FALSE test here lands on the
# `ok(...)` branch — the gate OPENING on the one value it could not compare (#2333 review P2).
CIQ_STATE=fresh; CIQ_QUEUED=99999999999999999999; CIQ_RUNNING=0; CIQ_RUNNERS=5; CIQ_BUSY=""
CIQ_CEILING=10; CIQ_AGE=0
v="$(ciq_eval)"; rc=$?
ck "(f1) a queued count too large to compare is UNKNOWN (rc=$rc), never allowed" \
   "$( { [ "$rc" -eq 2 ] && has "$v" 'not a comparable reading'; } ; echo $? )"
# ⛔ THE BOUNDARY, NOT ONE FAR VALUE (#2333 review round 2, P2). `ciq_is_count`'s guard is `-le 9`
# digits and (f1) probed only a 20-digit value, so widening it to `-le 19` kept the suite 103/0 CLEAN
# while a 19-digit reading — above intmax, and producible from a garbled `total_count` — made `[ -gt ]`
# ERROR, which is FALSE, which printed `ok(...)`: the gate OPENING on the one value it could not compare.
CIQ_STATE=fresh; CIQ_QUEUED=9999999999999999999; CIQ_RUNNING=0; CIQ_RUNNERS=5; CIQ_BUSY=""
CIQ_CEILING=10; CIQ_AGE=0
v="$(ciq_eval)"; rc=$?
ck "(f1b) …and a 19-digit count (above intmax, one below the 20-digit probe) is UNKNOWN too (rc=$rc)" \
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
# ⛔ THE DOCUMENTED EXIT-CODE CONTRACT WAS EXERCISED BY NOTHING (#2333 review, P2 — a FALSE PASS). The
# header promises "exit code follows the verdict (0 deep, 1 ok, 2 unknown) so an operator (or a hook)
# can branch on it without parsing", and the (g) section above drove only `ceiling`/`--runners`/`--repo`.
# Replacing the shipped `return "$rc"` with `return 0` — every state reporting DEEP, which is the code
# an operator reads as "defer" — left this suite 91 passed / 0 failed CLEAN. The contract is driven here
# against the same stub feed, one FRESH state dir per state so no cache can stand in for a read.
cl() { # <state-dir> <gh> <queued> <running> <runners> -> the CLI's exit code
  mkdir -p "$1"
  CIQ_GH="$2" CIQ_TEST_QUEUED="$3" CIQ_TEST_RUNNING="$4" CIQ_TEST_RUNNERS="$5" CIQ_TEST_BUSY=true \
  CIQ_TTL=0 CIQ_STALE_MAX=0 \
    bash "$MOD" status --repo "$OR" --state-dir "$1" > "$T/cli.out" 2>/dev/null
  printf '%s' "$?"
}
rc="$(cl "$T/cli-deep" "$STUB" 31 5 5)"
ck "(g4) a DEEP queue exits 0 (rc=$rc) — the operator/hook contract, not just a printed line" "$( [ "$rc" -eq 0 ]; echo $? )"
rc="$(cl "$T/cli-shallow" "$STUB" 1 0 3)"
ck "(g5) a SHALLOW queue exits 1 (rc=$rc) — a CRUCIAL distinction for anything branching on it" "$( [ "$rc" -eq 1 ]; echo $? )"
rc="$(cl "$T/cli-unknown" /nonexistent-ciq-gh 0 0 0)"
ck "(g6) an UNREADABLE queue exits 2 (rc=$rc) — UNKNOWN is its own code, neither deep nor ok" "$( [ "$rc" -eq 2 ]; echo $? )"
mutc="$T/mutant-cli"
mkdir -p "$mutc"
sed 's/^      return "\$rc" ;;$/      return 0 ;;/' "$MOD" > "$mutc/ci-queue.sh"
if cmp -s "$MOD" "$mutc/ci-queue.sh"; then
  bad "(g7) the exit-code mutation did not apply — this arm would prove nothing"
elif ! bash -n "$mutc/ci-queue.sh" 2>/dev/null; then
  bad "(g7) the exit-code mutant does not parse — a broken mutant proves nothing about the contract"
else
  mc="$( CIQ_GH=/nonexistent-ciq-gh CIQ_TTL=0 CIQ_STALE_MAX=0 bash "$mutc/ci-queue.sh" status --repo "$OR" --state-dir "$T/cli-mut" >/dev/null 2>&1; echo $? )"
  ck "(g7) MUTANT — a hard-printed 'return 0' makes UNKNOWN report DEEP (rc=$mc), so (g4)-(g6) are not always-green" \
     "$( [ "$mc" = 0 ]; echo $? )"
fi
# ⛔ THE SANITY-CHECK VERB MUST NOT PRINT A CEILING THE ARITHMETIC DID NOT PRODUCE (#2333 review round 2,
# P2). `ciq_ceiling` validated the shape with the UNBOUNDED `ciq_is_num`, so `--runners 9223372036854775807`
# overflowed `r * h` and printed `-1` with rc 0; `--runners 4611686018427387904` printed `0`. Both are
# numbers an operator would believe, on the one surface that exists to verify the derivation. The fix is
# the MAGNITUDE predicate the gate paths already use, so this arm pins it from the operator side.
bash "$MOD" ceiling --runners 9223372036854775807 > "$T/g8.out" 2>/dev/null; rc=$?
n="$(tr -d '\n' < "$T/g8.out")"
ck "(g8) 'ceiling --runners <intmax>' is REFUSED (rc=$rc, printed '${n:-<nothing>}') — never a negative or zero ceiling" \
   "$( { [ "$rc" -ne 0 ] && [ -z "$n" ]; } ; echo $? )"
n="$(bash "$MOD" ceiling 5 2>/dev/null | tr -d '\n')"
ck "(g8b) CONTROL — a plausible runner count still derives 10 ('$n'), so (g8) is not a blanket refusal" \
   "$( [ "$n" = 10 ]; echo $? )"

printf '\n── (i) the note the WIRING calls is EXECUTED — and can go red ─────────────────\n'
# ⛔ EXECUTED, NOT GREPPED (#2333 merge review, P2). (a)/(b)/(c) drive `ciq_defer_note`, the
# STANDALONE entry point, which RE-READS; every shipping caller uses `ciq_defer_note_here`. Measured
# before this arm existed: a module whose `ciq_defer_note_here` body is `return 1` — silencing EVERY
# daemon deferral line, the single failure this module exists to prevent — reported 79 passed, 0
# failed, CLEAN. The execution arms could not see it and the wiring arms only grepped the call sites.
i1="$(drive_note "$MOD")"
ck "(i1) the IN-SHELL note the wiring calls defers AND prints its one line (depth named)" \
   "$( { has "$i1" 'allowed=1' && has "$i1" 'note=[ci-queue] DEFERRED'; } ; echo $? )"
mkdir -p "$T/mutant-note"
awk '
  /^ciq_defer_note_here\(\) \{/ { print; print "  return 1"; skip=1; next }
  skip && /^\}$/              { skip=0; print; next }
  skip                        { next }
  { print }
' "$MOD" > "$T/mutant-note/ci-queue.sh"
if cmp -s "$MOD" "$T/mutant-note/ci-queue.sh"; then
  bad "(i0) the note mutation did not apply — this arm would prove nothing"
elif ! bash -n "$T/mutant-note/ci-queue.sh" 2>/dev/null; then
  bad "(i0) the note mutant does not parse — a broken mutant proves nothing about a silenced note"
else
  ok "(i0) the note mutant applied and still parses (the in-shell note returns 1 without printing)"
  i2="$(drive_note "$T/mutant-note/ci-queue.sh")"
  ck "(i2) MUTANT — a SILENCED in-shell note keeps the same decision (allowed=1) and LOSES the line, so (i1) is not always-green" \
     "$( { has "$i2" 'allowed=1' && has "$i2" 'note=[ci-queue] DEFERRED'; [ $? -ne 0 ]; } ; echo $? )"
fi

printf '\n── (k) a RECORD names its repo (the wrong-surface guard, DRIVEN) ────────────────\n'
# ⛔ WHY (#2333 review, P2). `CIQ_REPO` was documented as "the wrong-surface guard" and read
# NOWHERE, so a record could decide a push for a repo it was never read against. The FILENAME is
# lossy — `ciq_slug` maps `/` to `_`, so `a/b_c` and `a_b/c` share ONE `ci-queue-*` file — meaning
# a collision is not hypothetical arithmetic, it is the identifier scheme. The guard is now real
# (the record carries `repo=`, ciq_record_usable refuses a mismatch) and these arms drive it.
drive_rec() { # <module> <repo> <state-dir> -> "rc=<rc> state=<CIQ_STATE> queued=<CIQ_QUEUED>"
  (
    unset -f ciq_is_num ciq_is_count ciq_horizon_min ciq_job_p90_min ciq_hosted_concurrency ciq_ceiling ciq_slug \
             ciq_state_dir ciq_gh ciq_now ciq_read ciq_eval ciq_record_usable ciq_verdict \
             ciq_defer_note ciq_defer_note_here ciq_ci_allowed ciq_defer_line 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    declare -f ciq_read ciq_record_usable >/dev/null 2>&1 || { echo 'INTERFACE-MISSING'; exit 0; }
    CIQ_GH="$STUB"; CIQ_TTL=300; CIQ_STALE_MAX=900; CIQ_STATE_DIR="$3"
    export CIQ_GH CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
    CIQ_TEST_QUEUED=7; CIQ_TEST_RUNNING=1; CIQ_TEST_RUNNERS=2; CIQ_TEST_BUSY=true
    CIQ_TEST_OFFLINE=0; CIQ_TEST_NOTOTAL=0
    export CIQ_TEST_QUEUED CIQ_TEST_RUNNING CIQ_TEST_RUNNERS CIQ_TEST_BUSY CIQ_TEST_OFFLINE CIQ_TEST_NOTOTAL
    ciq_read "$2" >/dev/null 2>&1; local rc=$?
    printf 'rc=%s state=%s queued=%s' "$rc" "${CIQ_STATE:-}" "${CIQ_QUEUED:-}"
  ) 2>/dev/null
}
mkdir -p "$T/recstate"
REC_A="$T/recstate/ci-queue-a_b_c"      # the SLUG for BOTH a/b_c and a_b/c
r="$(drive_rec "$MOD" "a/b_c" "$T/recstate")"
ck "(k1) a real read WRITES the repo into its record (the writer, not a hand-made file)" \
   "$( grep -q '^repo=a/b_c$' "$REC_A"; echo $? )"
# Make the record's NUMBER distinguishable from the stub's (7), so "used the record" is visible.
sed 's/^queued=.*/queued=99/' "$REC_A" > "$REC_A.tmp" && mv "$REC_A.tmp" "$REC_A"
r="$(drive_rec "$MOD" "a/b_c" "$T/recstate")"
ck "(k2) the SAME repo is answered from its record ((k2: $r) = state=cache queued=99)" \
   "$( { has "$r" 'state=cache' && has "$r" 'queued=99'; } ; echo $? )"
r="$(drive_rec "$MOD" "a_b/c" "$T/recstate")"
ck "(k3) a repo that COLLIDES on the slug is NOT answered from the other's record ((k3: $r) - it reads LIVE)" \
   "$( { has "$r" 'state=fresh' && has "$r" 'queued=7' && ! has "$r" 'queued=99'; } ; echo $? )"
# A record written by an OLDER module has no `repo=` - "cannot verify" must read as "not usable",
# never as "matches": the direction of the refusal is a live read, and a failing read is UNKNOWN.
printf 'queued=99\nrunning=1\nrunners=2\nbusy=true\nat=%s\n' "$(ciq_now)" > "$REC_A"
r="$(drive_rec "$MOD" "a_b/c" "$T/recstate")"
ck "(k4) an UNVERIFIABLE record (no repo= line) reads LIVE, never as a match ((k4: $r))" \
   "$( { has "$r" 'state=fresh' && has "$r" 'queued=7'; } ; echo $? )"
# ...and (k3)/(k4) are not always-green: without the guard the collided record WINS.
sed 's/&& ciq_record_usable "\$cached" "\$repo"//' "$MOD" > "$T/noguard.sh"
printf 'repo=a/b_c\nqueued=99\nrunning=1\nrunners=2\nbusy=true\nat=%s\n' "$(ciq_now)" > "$REC_A"
if cmp -s "$MOD" "$T/noguard.sh"; then
  bad "(k5) the guard mutation did not apply - this arm would prove nothing"
elif ! bash -n "$T/noguard.sh" 2>/dev/null; then
  bad "(k5) the guard mutant does not parse - a broken mutant proves nothing about the guard"
else
  r="$(drive_rec "$T/noguard.sh" "a_b/c" "$T/recstate")"
  ck "(k5) MUTANT - without ciq_record_usable the collided record WINS ((k5: $r) = state=cache queued=99), so (k3) is not always-green" \
     "$( { has "$r" 'state=cache' && has "$r" 'queued=99'; } ; echo $? )"
fi
# (k6)/(k7) THE STALENESS ARM'S GUARD, PINNED SEPARATELY (#2333 review round 3, P2). (k3) covers the
# TTL arm; REMOVING the staleness arm's `&& ciq_record_usable` left this suite 114/0 CLEAN, so the
# arm that must not answer for another repo was pinned by nothing - and it is the WORSE of the two,
# because the staleness fallback runs while the feed is FAILING: there is no live measurement to
# contradict a borrowed number. Driven with TTL=0 (so the TTL arm cannot answer) and a DEAD feed,
# reading a repo that collides with the record's owner on the slug.
drive_stale() { # <module> <repo> <state-dir> -> "rc=<rc> state=<state> queued=<queued>"
  (
    unset -f ciq_is_num ciq_is_count ciq_horizon_min ciq_job_p90_min ciq_hosted_concurrency ciq_ceiling ciq_slug \
             ciq_state_dir ciq_gh ciq_now ciq_read ciq_eval ciq_record_usable ciq_verdict \
             ciq_defer_note ciq_defer_note_here ciq_ci_allowed ciq_defer_line 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    declare -f ciq_read ciq_record_usable >/dev/null 2>&1 || { echo 'INTERFACE-MISSING'; exit 0; }
    CIQ_GH=/nonexistent-ciq-gh; CIQ_TTL=0; CIQ_STALE_MAX=900; CIQ_STATE_DIR="$3"
    export CIQ_GH CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
    ciq_read "$2" >/dev/null 2>&1; local rc=$?
    printf 'rc=%s state=%s queued=%s' "$rc" "${CIQ_STATE:-}" "${CIQ_QUEUED:-}"
  ) 2>/dev/null
}
mkdir -p "$T/recstale"
printf 'repo=a/b_c\nqueued=99\nrunning=1\nrunners=9\nbusy=true\nat=%s\n' "$(ciq_now)" \
  > "$T/recstale/ci-queue-a_b_c"
r="$(drive_stale "$MOD" "a_b/c" "$T/recstale")"
ck "(k6) the STALENESS fallback refuses another repo's record ((k6: $r) = rc=2 state=unknown) - no borrowed numbers while the feed is down" \
   "$( { has "$r" 'rc=2' && has "$r" 'state=unknown' && ! has "$r" 'queued=99'; } ; echo $? )"
# ...and (k6) is not always-green: disarming ONLY the staleness call site must make the borrow visible.
awk '
  /ciq_record_usable "\$cached"/ { n++; if (n == 2) sub(/ciq_record_usable/, "true") }
  { print }
' "$MOD" > "$T/noguard-stale.sh"
printf 'repo=a/b_c\nqueued=99\nrunning=1\nrunners=9\nbusy=true\nat=%s\n' "$(ciq_now)" \
  > "$T/recstale/ci-queue-a_b_c"
if cmp -s "$MOD" "$T/noguard-stale.sh"; then
  bad "(k7) the staleness-guard mutation did not apply - this arm would prove nothing"
elif ! bash -n "$T/noguard-stale.sh" 2>/dev/null; then
  bad "(k7) the staleness-guard mutant does not parse - a broken mutant proves nothing about the guard"
else
  r="$(drive_stale "$T/noguard-stale.sh" "a_b/c" "$T/recstale")"
  ck "(k7) MUTANT - without the staleness arm's guard the collided record is SERVED ((k7: $r)), so (k6) is not always-green" \
     "$( { has "$r" 'state=cache' && has "$r" 'queued=99'; } ; echo $? )"
fi

# ⛔ (j) THE DEFERRAL'S EFFECT, DRIVEN — NOT THE PRESENCE OF ITS LINES (#2333 review, P2).
# `(e7)`/`(e8)` grep for `ciq_ci_allowed "$OR"` and `fixbail-$PR-$HEAD`, which is how a deferral
# whose `exit 0` was replaced by `:` stayed green: the block PRINTS "DEFERRED … nothing pushed" and
# then FALLS THROUGH to the cross-box claim, runs the fixer and pushes — the log asserting the exact
# opposite of what the process did, and the bail marker making the controller refund an attempt that
# did work. The one suite that executes fix-one.sh (`test-crossbox.sh`) is excluded from
# run-bash-shards.sh by design (spawn-gate.test.sh pins the excluded set), so NO CI LANE ran it.
# Measured before this arm: the `exit 0` → `:` mutant left this file 83 passed, 0 failed, CLEAN.
# The shipped block is EXTRACTED (not restated) and driven under a stub module in both polarities.
printf '\n── (j) fix-one.sh does NOT gate a repair on the queue (#2927) ────────────────\n'
# ⛔ THIS SECTION USED TO DRIVE THE DELETED GATE. It extracted `if [ -f "$SELF/ci-queue.sh" ] … fi`
# from fix-one.sh and proved that a DEEP queue EXITED the fixer before any work — with its own
# `exit 0`-deleted mutant. That block no longer exists: a fixer is REPAIR, so there is no block to
# extract, no deferral to mutate, and no bail marker written for a queue. The invariant is now the
# ABSENCE of the call on the shipped bytes, asserted positively below (a reintroduced gate reddens
# (j1)/(j2)), together with the presence of the gate a fixer IS bounded by.
ck "(j1) fix-one.sh sources no CI-queue module (a fixer is bounded by this BOX's capacity, not by CI)" \
   "$( grep -qF '. "$SELF/ci-queue.sh"' "$FIX"; [ $? -ne 0 ]; echo $? )"
ck "(j2) …and never calls the queue predicate" \
   "$( grep -q 'ciq_ci_allowed' "$FIX"; [ $? -ne 0 ]; echo $? )"
ck "(j3) …while the LOAD/disk spawn gate it IS bounded by is still sourced (the bound was narrowed, not removed)" \
   "$( grep -q 'spawn-gate.sh' "$FIX"; echo $? )"
# ⛔ (m) THE CI-RERUN GATE — the one SWEEP act that ADDS queue (#2333 review round 4, P2). The PR
# names it as "the only other surface in the sweep that ADDS queue", and it was pinned by NOTHING:
# (e6) counts the `ci-queue(...)` token, and pr-dispatch.test.sh's T3 cycle never reaches this block
# at all (measured: `gh run rerun` appears in its spy on NEITHER an allowed NOR a refusing queue, so
# a drive there is vacuous — it was tried and removed rather than kept as decoration).
# Measured before this arm: replacing `&& ! ciq_push_ok` with `&& false` — the withhold branch
# becomes dead code, so a rerun enqueues unconditionally behind a backlog — left ci-queue 116/0 and
# pr-dispatch 36/0 GREEN. The shipped block is EXTRACTED and driven in both polarities.
printf '\n── (m) the CI-RERUN gate adds queue, so it is DRIVEN ──────────────────────────\n'
RERUN="$T/rerun.sh"
awk '/^          if \[ -n "\$\{RID:-\}" \] && \[ ! -f "\$O\/state\/rerun-\$PR-\$RID" \] && ! ciq_push_ok; then$/ {f=1}
     f{print}
     f&&/^          fi$/{exit}' "$LOOP" > "$RERUN"
ck "(m1) the CI-rerun gate was EXTRACTED from orch-loop.sh (not a restatement)" \
   "$( { [ -s "$RERUN" ] && grep -q 'run rerun' "$RERUN" && grep -q 'ciq_push_ok' "$RERUN"; } ; echo $? )"
rerun_drive() { # <block-file> <ciq_push_ok rc> -> "rerun=<yes|no> withheld=<yes|no>"
  (
    RID=98765; PR=4242; OR="daniel-ospina/agent-infra"; HEAD_N=abc1234; V=CLEAN
    O="$(mktemp -d "$T/rerunstate.XXXXXX")"; mkdir -p "$O/state"   # PER CALL: (m3) TOUCHES
    # `$O/state/rerun-<PR>-<RID>` on its successful rerun, so a shared dir made (m5) read "already
    # rerun" and skip both branches — the mutant then looked withheld and the arm proved nothing.
    LOG="$T/rerun.log"; PRDISP="$T/rerun.tsv"
    : > "$LOG"; : > "$PRDISP"
    GSPY="$T/rerun.gspy"; : > "$GSPY"
    _pushrc="$2"   # captured BEFORE the stub is defined: inside `ciq_push_ok`, `$2` is the FUNCTION's own
    ciq_push_ok() { return "$_pushrc"; }
    ciq_defer_note_here() { printf '[ci-queue] DEFERRED %s\n' "${1:-work}"; }
    ciq_verdict() { printf 'deep(queued=99 running=1 runners=2 ceiling=4 state=fresh age=0s)'; }
    dispreplace() { printf 'DISPREPLACE %s %s\n' "$1" "$5" >> "$LOG"; }
    gh() { printf 'GH %s\n' "$*" >> "$GSPY"; return 0; }
    # shellcheck disable=SC1090
    . "$1" >> "$LOG" 2>&1
    _rr=no; grep -q 'run rerun' "$GSPY" && _rr=yes
    _wh=no; grep -q 'rerun withheld' "$LOG" && _wh=yes
    printf 'rerun=%s withheld=%s' "$_rr" "$_wh"
  ) 2>/dev/null
}
r="$(rerun_drive "$RERUN" 1)"
ck "(m2) a DEEP/UNKNOWN queue WITHHOLDS the rerun ((m2: $r) = rerun=no withheld=yes) — a rerun would enqueue behind the backlog" \
   "$( { has "$r" 'rerun=no' && has "$r" 'withheld=yes'; } ; echo $? )"
r="$(rerun_drive "$RERUN" 0)"
ck "(m3) CONTROL — an ALLOWED queue DOES rerun ((m3: $r) = rerun=yes), so (m2) is a decision and not a constant withhold" \
   "$( { has "$r" 'rerun=yes'; } ; echo $? )"
# …and (m2) is not always-green. THE MUTANT IS `&& ! ciq_push_ok` → `&& false` — the withhold branch
# goes DEAD, so the rerun fires on a deep queue. (Replacing the WHOLE predicate with nothing turns the
# withholder into the unconditional branch instead — the opposite defect, and it still withholds, which
# is why the polarity of the mutation is stated here rather than left to the sed.)
sed 's/ && ! ciq_push_ok; then/ \&\& false; then/' "$RERUN" > "$T/rerun-mutant.sh"
if cmp -s "$RERUN" "$T/rerun-mutant.sh"; then
  bad "(m4) the rerun-gate mutation did not apply — this arm would prove nothing"
elif ! bash -n "$T/rerun-mutant.sh" 2>/dev/null; then
  bad "(m4) the rerun-gate mutant does not parse — a broken mutant proves nothing about the gate"
else
  r="$(rerun_drive "$T/rerun-mutant.sh" 1)"
  ck "(m5) MUTANT — without the predicate a deep queue reruns anyway ((m5: $r) = rerun=yes), so (m2) is not always-green" \
     "$( { has "$r" 'rerun=yes'; } ; echo $? )"
fi
# ⛔ (n) AN UNREADABLE QUEUE SAYS *WHY* AND *FOR HOW LONG* (#2333 review round 5, P2). The token
# was anonymous and unbounded: a transient 500 on cycle 3 and a permanently unanswerable endpoint on
# cycle 900 printed the identical line, so "is this a blip or is this stuck?" — the question an
# operator actually has — had no answer, and the header's "UNKNOWN costs a cycle" only ever justified
# the blip. The cause is the endpoint's own words (stderr, previously discarded by ciq_gh) and the
# streak is PERSISTED, so it counts rather than being a constant.
printf '\n── (n) an UNKNOWN names its cause and its streak ─────────────────────────────\n'
BAD="$T/gh404"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "gh: Not Found (HTTP 404)\\n" >&2\n'
  printf 'exit 1\n'
} > "$BAD"
chmod +x "$BAD"
drive_unknown() { # <module> <state-dir> <gh> -> "rc=<rc> state=<state> tok=<token>"
  (
    unset -f ciq_is_num ciq_is_count ciq_horizon_min ciq_job_p90_min ciq_hosted_concurrency ciq_ceiling ciq_slug \
             ciq_state_dir ciq_gh ciq_now ciq_read ciq_eval ciq_record_usable ciq_verdict \
             ciq_defer_note ciq_defer_note_here ciq_ci_allowed ciq_defer_line 2>/dev/null
    # shellcheck source=/dev/null
    . "$1" 2>/dev/null || { echo 'DID-NOT-SOURCE'; exit 0; }
    CIQ_GH="$3"; CIQ_TTL=0; CIQ_STALE_MAX=0; CIQ_STATE_DIR="$2"
    export CIQ_GH CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
    ciq_read "o/r" >/dev/null 2>&1; local rc=$?
    local tok; tok="$(ciq_eval)"
    printf 'rc=%s state=%s tok=%s' "$rc" "${CIQ_STATE:-}" "$tok"
  ) 2>/dev/null
}
mkdir -p "$T/unkstate"
r1="$(drive_unknown "$MOD" "$T/unkstate" "$BAD")"
ck "(n1) the FIRST unreadable read names the cause ((n1: $r1) — expects streak=1 cause=HTTP 404)" \
   "$( { has "$r1" 'rc=2' && has "$r1" 'streak=1' && has "$r1" 'cause=HTTP 404'; } ; echo $? )"
r2="$(drive_unknown "$MOD" "$T/unkstate" "$BAD")"
ck "(n2) a SECOND consecutive failure COUNTS ((n2: $r2) — expects streak=2, so it is persisted, not a constant)" \
   "$( { has "$r2" 'rc=2' && has "$r2" 'streak=2'; } ; echo $? )"
# A successful read must CLEAR the streak, or "how long has this been failing" would be a lifetime
# total rather than a current state — the same "a stale fact re-read as a live one" class this repo
# removes everywhere else.
r3="$(drive_unknown "$MOD" "$T/unkstate" "$STUB")"
ck "(n3) …and a SUCCESSFUL read clears the record of failure ((n3: ${r3%% tok=*}))" \
   "$( { has "$r3" 'rc=0'; } ; echo $? )"
# The success wrote a record; drop it so the next read MUST go live (the staleness arm serves a
# 0-second-old record at CIQ_STALE_MAX=0, which is a cache answer, not the failure this arm is about).
rm -f "$T/unkstate/ci-queue-o_r"
r4="$(drive_unknown "$MOD" "$T/unkstate" "$BAD")"
ck "(n4) …so the next failure starts again at 1 ((n4: $r4)) — the streak is a CURRENT state, not a lifetime total" \
   "$( { has "$r4" 'streak=1' && ! has "$r4" 'streak=3'; } ; echo $? )"
# …and (n2) is not always-green: without the persisted write the streak cannot advance.
grep -v 'printf .%s. "$CIQ_STREAK" > "$_sf"' "$MOD" > "$T/nostreak.sh"
if cmp -s "$MOD" "$T/nostreak.sh"; then
  bad "(n5) the streak-persistence mutation did not apply — this arm would prove nothing"
elif ! bash -n "$T/nostreak.sh" 2>/dev/null; then
  bad "(n5) the streak mutant does not parse — a broken mutant proves nothing about the streak"
else
  mkdir -p "$T/unkmut"
  m1="$(drive_unknown "$T/nostreak.sh" "$T/unkmut" "$BAD")"
  m2="$(drive_unknown "$T/nostreak.sh" "$T/unkmut" "$BAD")"
  ck "(n5) MUTANT — an unpersisted streak stays at 1 ($m2), so (n2) is not always-green" \
     "$( { has "$m1" 'streak=1' && has "$m2" 'streak=1'; } ; echo $? )"
fi



printf '\n── (o) THE RUNNERS READ ASKS FOR EVERY PAGE, AND ASKS AFTER THE ENDPOINT ─────\n'
# ⛔ THE FLAG AN EARLIER CYCLE CALLED A P1 WAS PINNED BY NOTHING (#2333 review, P3). The
# `actions/runners` endpoint answers ONE page (30 objects) by default, so without `--paginate` a fleet
# bigger than that is counted as 30, the ceiling is under-derived, and the gate DEFERS pushes and
# issue work the real fleet would have drained inside the horizon — a silent over-block on exactly
# the quantity the header derives from. The flag's POSITION matters too: every rig's `gh` stub
# dispatches on `$2`, so a LEADING flag shifts the URL into `$3` and every stub takes its `*) exit 1`
# arm. Measured before this arm existed: deleting ` --paginate` from the module left the whole suite
# GREEN (125/0) — the arm below reds on both the deletion and the move.
spy="$T/spy-gh"; args_f="$T/spy-args"
cat > "$spy" <<'SPYBODY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CIQ_SPY_ARGS"
exec "$CIQ_SPY_REAL" "$@"
SPYBODY
chmod +x "$spy"
# drive_spy <module>: one LIVE read (TTL 0, no record) through the recording wrapper.
drive_spy() {
  rm -rf "$T/spystate"; mkdir -p "$T/spystate"; : > "$args_f"
  CIQ_GH="$spy"; CIQ_SPY_ARGS="$args_f"; CIQ_SPY_REAL="$STUB"
  CIQ_TTL=0; CIQ_STALE_MAX=0; CIQ_STATE_DIR="$T/spystate"
  export CIQ_GH CIQ_SPY_ARGS CIQ_SPY_REAL CIQ_TTL CIQ_STALE_MAX CIQ_STATE_DIR
  CIQ_TEST_QUEUED=1; CIQ_TEST_RUNNING=0; CIQ_TEST_RUNNERS=5; CIQ_TEST_BUSY=true
  CIQ_TEST_OFFLINE=0; CIQ_TEST_NOTOTAL=0; OR="daniel-ospina/agent-infra"
  export CIQ_TEST_QUEUED CIQ_TEST_RUNNING CIQ_TEST_RUNNERS CIQ_TEST_BUSY
  export CIQ_TEST_OFFLINE CIQ_TEST_NOTOTAL OR
  # shellcheck source=/dev/null
  ( . "$1" >/dev/null 2>&1; ciq_read "$OR" >/dev/null 2>&1 || true )
}
drive_spy "$MOD"
line="$(grep -F 'actions/runners' "$args_f" | tail -1)"
ck "(o1) the runners read asks for EVERY page, and asks for it AFTER the endpoint (recorded: ${line:-<no such call>})" \
   "$( has "$line" 'actions/runners --paginate'; echo $? )"
ck "(o1b) …and every read is recorded, so the arm cannot pass on an empty spy file" \
   "$( { [ "$(grep -c . "$args_f")" -ge 3 ]; } ; echo $? )"
# …and (o1) is not always-green: strip the flag from a copy and the recorded invocation loses it.
sed 's|"repos/$repo/actions/runners" --paginate|"repos/$repo/actions/runners"|' \
    "$MOD" > "$T/nopaginate.sh"
if cmp -s "$MOD" "$T/nopaginate.sh"; then
  bad "(o2) the --paginate mutation did not apply — (o1) would prove nothing"
elif ! bash -n "$T/nopaginate.sh" 2>/dev/null; then
  bad "(o2) the --paginate mutant does not parse — a broken mutant proves nothing"
else
  drive_spy "$T/nopaginate.sh"
  mline="$(grep -F 'actions/runners' "$args_f" | tail -1)"
  ck "(o2) MUTANT — without the flag the invocation loses it (recorded: ${mline:-<no such call>}), so (o1) is not always-green" \
     "$( has "$mline" 'actions/runners --paginate'; [ $? -ne 0 ]; echo $? )"
fi

# ── (p) THE SHAPE `bash -n` CANNOT SEE: a `case` INSIDE `$( )` (#2969) ───────────────────────
# ⛔ WHY A `bash -n` ARM WOULD HAVE PROVED NOTHING. `bash -n` parses the OUTER script only, so it
# answered rc 0 on a module that could not run: the substitution is re-parsed at EXECUTION, and on
# bash 3.2 — macOS's `/bin/bash`, which is the interpreter `launchd` starts the controller with
# (`com.eldato.orchestrator-loop.plist` → `/bin/bash …/launchd-controller.sh`) — the `)` that closes
# a `case` PATTERN is read as the closer of the `$( )`. Measured on the box that filed the defect:
#
#   $ /bin/bash ci-queue.sh status --repo daniel-ospina/agent-infra
#   deep(queued=55 running=5 runners=2 busy=2 ceiling=4 derived=ceil(2*20/10) state=fresh)
#   ci-queue.sh: command substitution: line 596: syntax error near unexpected token `newline'
#   ci-queue.sh: command substitution: line 596: ` case "${CIQ_STATE}" in fresh'
#   repo=… state=fresh source= printf 'gh' ;; cache) printf 'record(cache)' ;; … esac ) age=0s
#   rc=0      ← a CORRUPTED field under a GREEN exit
#
# ⛔ AND WHY THE OBVIOUS FIX IS NOT A FIX, which is why this arm forbids the CONSTRUCT rather than one
# spelling of it. Every shape below measured with /bin/bash 3.2.57, the box's own interpreter:
#   in fresh)                  → the substitution closes at `fresh)`; `source=` is literal leftovers
#   in *fr*)                   → same
#   in (fresh) … *) …          → STILL FAILS: `(` shields only its own pattern, and the `*)`
#                                catch-all's `)` closes the substitution
#   in (fresh) … (*) …         → parses — but only while EVERY pattern stays parenthesised, which is
#                                a trap for the next editor rather than a rule
#   if/then/else, or hoisted   → parses, because no `)` in the text terminates a pattern
# A `case` is therefore allowed DIRECTLY in a shell script and NOT allowed inside a command
# substitution: hoist it into a variable first. (bash 4.4+ parse every shape above correctly, which
# is exactly why the defect could not be seen on the machine that wrote it — the failing population
# is bash 3.2, the version the controller actually runs.)
# ⛔ WHAT THIS ARM CAN AND CANNOT FIRE, DECLARED RATHER THAN IMPLIED: the DETECTOR (p1)-(p2) is
# portable and carries the red-proof on EVERY host, including CI's bash 5 where the runtime shape
# parses fine. The RUNTIME arm (p3)-(p4) needs a bash 3.x interpreter to fire, and on a box whose
# only bash is 4.4+ it reports a DECLARED notice instead of a pass — a runtime arm that silently
# cannot run is the same lie as a gate that cannot run.

# cis_in_comsub <file> -> "<file>:<line>" for every `case` that sits inside a `$( )`.
# THE RULE, PRECISELY: scan each line CHARACTER by character, keeping a running DEPTH of open `$(`
# substitutions, and report a line on which the `case` keyword appears while depth > 0.
# ⛔ DEPTH, NOT "is there a `)` before the `case` on this line" (review cycle 1, P2). The earlier
# LINE-SCOPED spelling — walk each `$(` on the line, report if no `)` precedes the `case` — had two
# blind spots, and BOTH are the defect this arm exists to catch, so it advertised a rule it did not
# enforce:
#   * MULTI-LINE: `x="$(` / `  case "$s" in` / `  esac` / `)"` — the line holding the `case` has no
#     `$(`, so nothing was reported. bash 3.2's paren counting is line-agnostic; the detector was not.
#   * NESTED: `$(printf %s "$(date)"; case "$s" in a) : ;; esac)` — the inner substitution's `)` was
#     consumed by the `*')'*` guard, so a genuinely broken `case` after it was skipped.
# Both were measured real in this repo, not hypothesised: the depth scanner reports 3 sites in
# scripts/harness-surface.test.sh that the line-scoped form missed — :1160 is
# `"$(if …; then case … esac; else … fi)"`, and :1287/:1307 are `"$(cmd; case … esac)"` — and 0 sites
# the line-scoped form found are lost. ⛔ NAMED EXACTLY, because the CHARACTERISATION is what a future
# editor acts on (#2969 review cycle 2, P2): calling all three "the if/then shape" told a reader that
# only `$(if … then case …)` is caught, when the missed class also includes the `$(cmd; case …)`
# spelling they would think safe to keep.
# ⛔ DECLARED LIMITS, not silently assumed: this skips FULL-LINE comments (prose here discusses `case`
# and `$( )`, and flagging prose would be a false positive), but it does NOT lex quotes — a literal
# `$(` inside a quoted string is counted as a substitution (can only over-report), and an unbalanced
# `)` inside a string can close a depth early (under-report). Neither shape exists in this module;
# they are stated so a future reader knows where the detector's confidence ends.
cis_in_comsub() {
  local f="$1" n=0 depth=0 line i len ch prev nxt first found
  while IFS= read -r line; do
    n=$((n + 1)); found=0
    first="${line#"${line%%[![:space:]]*}"}"
    case "$first" in '#'*) continue ;; esac
    len=${#line}; i=0
    while [ "$i" -lt "$len" ]; do
      ch="${line:$i:1}"
      case "$ch" in
        '$')
          nxt="${line:$((i + 1)):1}"
          if [ "$nxt" = '(' ]; then depth=$((depth + 1)); i=$((i + 2)); continue; fi
          ;;
        ')')
          [ "$depth" -gt 0 ] && depth=$((depth - 1))
          ;;
        'c')
          if [ "$depth" -gt 0 ] && [ "${line:$i:4}" = case ]; then
            # whole-word only: `discase`/`casey` are not the keyword
            prev=""; [ "$i" -gt 0 ] && prev="${line:$((i - 1)):1}"
            nxt="${line:$((i + 4)):1}"
            case "$prev" in ''|[!A-Za-z0-9_]) case "$nxt" in ''|[!A-Za-z0-9_]) found=1 ;; esac ;; esac
          fi
          ;;
      esac
      i=$((i + 1))
    done
    [ "$found" -eq 1 ] && printf '%s:%s\n' "$f" "$n"
  done < "$f"
}

hits="$(cis_in_comsub "$MOD")"
ck "(p1) the module carries NO \`case\` inside a \`\$( )\` (${hits:-none}) — the shape bash 3.2 re-parses at execution" \
   "$( [ -z "$hits" ]; echo $? )"

# ⛔ MUTANT: reinstate the CONSTRUCT by DERIVING it from the module's own hoisted block — the
# patterns and the values are READ OUT of the module, not restated here, so the control cannot drift
# from the code it guards. The relocation is exactly the pre-fix semantics: the same `case`, its same
# patterns and the same values, moved back inside the substitution as `printf`.
# ⛔ THE EARLIER SPELLING OF THIS ARM CLAIMED THAT AND DID NOT DO IT (review cycle 1, P2): its awk
# matched only the block's HEADER line and then emitted a hard-coded body, so changing the module's
# real `fresh) src='gh-live'` still produced a mutant saying `printf 'gh'`. The comment asserted a
# no-drift guarantee the code did not provide. Now the derivation is real: every `pattern) src='VALUE'`
# row is parsed, so a changed value changes the mutant, and a reindent no longer breaks it.
mutp="$T/mut-comsub"
mkdir -p "$mutp"
# ⛔ awk, NOT python3: this arm must not go RED on a host that merely lacks an interpreter, and the
# siblings that use python3 all live outside the bash suites. RULE: wherever the hoisted `case` block
# starts, emit the SAME case back inside a `$( )` and drop the block — the pre-fix semantics exactly.
awk '
  rebuilding {
    if ($0 ~ /^[[:space:]]*esac[[:space:]]*$/) { out = out " esac )\""; print out; rebuilding = 0; next }
    # a row of the hoisted block, e.g.   fresh) src=\047gh\047 ;;
    if (match($0, /^[[:space:]]*[^)]*\)[[:space:]]*src=\047[^\047]*\047[[:space:]]*;;[[:space:]]*$/)) {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      pat = line; sub(/\).*/, "", pat)
      rest = line; sub(/^[^)]*\)[[:space:]]*src=\047/, "", rest)
      val = rest; sub(/\047.*/, "", val)
      out = out pat ") printf \047" val "\047 ;; "
      next
    }
    bad = 1; exit 3
  }
  /^[[:space:]]*case "\$\{CIQ_STATE\}" in[[:space:]]*$/ {
    rebuilding = 1
    out = "      src=\"$( case \"${CIQ_STATE}\" in "
    next
  }
  { print }
  END { if (rebuilding || bad) exit 3 }
' "$MOD" > "$mutp/ci-queue.sh" 2>/dev/null
if [ $? -ne 0 ]; then
  bad "(p2) the mutant could not be DERIVED from the module's own hoisted block — its shape changed, so update this arm TOGETHER with the block (the control must not be restated here: a hand-written body drifts from the code it guards)"
elif cmp -s "$MOD" "$mutp/ci-queue.sh"; then
  bad "(p2) the shape mutation did not apply — (p1) would prove nothing"
elif ! bash -n "$mutp/ci-queue.sh" 2>/dev/null; then
  bad "(p2) the mutant does not pass \`bash -n\` — it must, because THAT blindness is the finding"
else
  mhits="$(cis_in_comsub "$mutp/ci-queue.sh")"
  ck "(p2) MUTANT — reinstating the construct is CAUGHT (${mhits:-<missed>}) while \`bash -n\` still exits 0, so (p1) is not always-green and is not a re-run of the parse gate" \
     "$( [ -n "$mhits" ]; echo $? )"
fi

# ── (p3)-(p4) the RUNTIME arm: the same bytes, on an interpreter that has the defect ─────────────
# Find a bash 3.x. `/bin/bash` is 3.2 on macOS (the affected population) and 5.x on the CI runners
# (where the shape parses, so the arm cannot fire there — declared, below).
# ⛔ `CIQ_BASH3` IS THE OVERRIDE, and it exists because a fixed path list makes these arms inert
# ANYWHERE ELSE: measured on this repo's own harness, a bash 3.2.57 built in a container reports
# "no bash 3.x on this host" unless the binary happens to sit at one of the four paths below. An arm
# that cannot run is not a passing arm (#2969's own lesson) — so the path is settable, and the arms
# can then be exercised anywhere, including CI.
B3=""
for c in ${CIQ_BASH3:-} /bin/bash /usr/bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash; do
  [ -x "$c" ] || continue
  case "$($c -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in 3.*) B3="$c"; break ;; esac
done
legal_source() { [ "${1:-}" = gh ] || [ "${1:-}" = 'record(cache)' ] || [ "${1:-}" = unknown ]; }
cli_source() { # <interpreter> <module> <state-dir> [<ttl>] [<gh>] -> the `source=` field of the status line, as printed
  mkdir -p "$3"
  CIQ_GH="${5:-$STUB}" CIQ_TEST_QUEUED=1 CIQ_TEST_RUNNING=0 CIQ_TEST_RUNNERS=5 CIQ_TEST_BUSY=true \
  CIQ_TEST_OFFLINE=0 CIQ_TEST_NOTOTAL=0 CIQ_TTL="${4:-0}" CIQ_STALE_MAX=0 \
    "$1" "$2" status --repo "$OR" --state-dir "$3" 2>/dev/null \
    | sed -n 's/.*source=\(.*\) age=[^ ]*$/\1/p' | head -1
}
# ⛔ THE VALUE ASSERTION IS NOT VERSION-GATED (review cycle 1, P2). `legal_source`/`cli_source` need no
# 3.x interpreter: the field this bug corrupted must be a DERIVED `source=` on ANY bash, and on a 4.4+
# host a regression of the hoisted block would still print something illegal. The earlier spelling hid
# this assertion inside `else` of `if [ -z "$B3" ]`, so on every CI runner (all bash 5) NOTHING asserted
# the `source=` value — only (p1)'s grep of the file ran. Only (p4)'s 3.2 corruption CONTROL is
# genuinely version-gated, because it needs an interpreter that has the defect.
gotp="$(cli_source "${B3:-bash}" "$MOD" "$T/rt-fixed")"
# ⛔ EXACT VALUE, NOT `legal_source` (#2969 review cycle 3, P2). `legal_source` asks "is this a MEMBER of
# {gh, record(cache), unknown}" — a set test, not the row's answer — so a `fresh)` row that returned
# `unknown`, or a `fresh) src='gh'` row DELETED entirely (the likely refactor accident: the catch-all
# then answers), certified as ✅ on every host: measured, both mutants green at 133/0 and 135/0 while
# the arm's own message printed ('unknown'). The field this bug corrupted is pinned to its ONE correct
# value on the state that corrupted it; `legal_source` stays only where (p4) asks the set question.
ck "(p3a) the CLI reports source=gh ('${gotp:-<none>}') on $(basename "${B3:-bash}") — never the literal remainder of the printf, never another state's value" \
   "$( [ "${gotp:-}" = gh ]; echo $? )"
# ⛔ ALL THREE VALUES THE HOIST MOVED, NOT ONE (#2969 review cycle 2, P2). (p3a) drove the CLI with
# CIQ_TTL=0 against an EMPTY state dir — i.e. state=fresh — so `src` was ALWAYS 'gh', and the hoisted
# `record(cache)` and `unknown` branches were executed by NO arm in this file: a typo in either would
# have been caught by nothing, in the one arm that exists to assert the VALUE of the field this bug
# corrupted. The two arms below drive the other two branches. They need no 3.x interpreter, for the
# same reason (p3a) does not: the value is version-independent even where the corruption is not.
seed_record() { # <state-dir> -> an in-TTL record the module serves as `cache` (no live read happens)
  mkdir -p "$1"
  printf 'repo=%s\nqueued=2\nrunning=1\nrunners=5\nbusy=1\nat=%s\n' \
    "$OR" "$(date +%s)" > "$1/ci-queue-daniel-ospina_agent-infra"
}
seed_record "$T/rt-cache"
gotc="$(cli_source "${B3:-bash}" "$MOD" "$T/rt-cache" 300)"
ck "(p3b) a TTL hit reports source=record(cache) ('${gotc:-<none>}') — the second value the hoist moved" \
   "$( [ "${gotc:-}" = 'record(cache)' ]; echo $? )"
gotu="$(cli_source "${B3:-bash}" "$MOD" "$T/rt-unknown" 0 /nonexistent-ciq-gh)"
ck "(p3c) a failed read reports source=unknown ('${gotu:-<none>}') — the catch-all the hoist moved" \
   "$( [ "${gotu:-}" = unknown ]; echo $? )"
if [ -z "$B3" ]; then
  printf '  ⚠️  (p3) DECLARED, NOT SKIPPED — no bash 3.x on this host (%s); bash 4.4+ parse this shape\n' \
    "$(bash --version 2>/dev/null | head -1)"
  printf '      correctly, so the 3.2 runtime CONTROL (p4) cannot fire here — it needs an interpreter\n'
  printf '      that HAS the defect. The detector (p1)/(p2) carries the red-proof on every host, and\n'
  printf '      (p3a) above asserts the source= VALUE on whatever bash this is.\n'
else
  got="$(cli_source "$B3" "$MOD" "$T/rt-fixed3")"
  ck "(p3) on bash 3.2 ($B3) the CLI reports source=gh ('${got:-<none>}')" \
     "$( [ "${got:-}" = gh ]; echo $? )"
  # ⛔ THE CONTROL NEEDS A MUTANT TO DRIVE. When (p2) could not build one — which is what a REVERTED
  # module looks like, since there is no hoisted block to relocate — this arm must go RED, not pass
  # because an absent file's empty output happens to be "not a legal source". Measured on the
  # reverted bytes: the earlier spelling of this arm reported ✅ for a mutant that did not exist.
  if [ ! -f "$mutp/ci-queue.sh" ] || cmp -s "$MOD" "$mutp/ci-queue.sh"; then
    bad "(p4) there is no mutant to drive — the runtime control would prove nothing (measured on a reverted module: this arm used to pass VACUOUSLY)"
  else
    mgot="$(cli_source "$B3" "$mutp/ci-queue.sh" "$T/rt-mut")"
    # ⛔ NO OUTPUT IS NOT A CORRUPTION (#2969 review cycle 2, P2 — a FALSE PASS). `legal_source` refuses
    # the EMPTY string, so the earlier spelling `{ legal_source "$mgot"; } ; [ $? -ne 0 ]` printed ✅ for
    # a mutant that emitted NOTHING: the arm certified "the construct CORRUPTS source=" while having
    # measured nothing at all, and the message even read ('<none>'). That is the same fail-closed
    # polarity the ABSENT-mutant guard above was added for, and the same one (p2)/(o1b) already use.
    if [ -z "$mgot" ]; then
      bad "(p4) the mutant produced NO status line, so the runtime control proves nothing — an empty value is not a corruption"
    else
      ck "(p4) MUTANT — on bash 3.2 the reinstated construct CORRUPTS source= ('${mgot}'), so (p3) is not always-green" \
         "$( { legal_source "$mgot"; } ; [ $? -ne 0 ]; echo $? )"
    fi
  fi
fi

printf '\n──────────────────────────────────────────────────────────────────────\n'
printf 'ci-queue.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s' "$FAILED_LINES" | sed 's/^/  - /'; exit 1; fi
printf 'CLEAN\n'
exit 0
