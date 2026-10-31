#!/usr/bin/env bash
# gh-limit.test.sh — offline checks for the gh serialisation / backoff layer (#1988).
#
# No network, no credentials, no real gh: a STUB gh emits canned responses and appends every
# invocation to a log, so the assertions pin the BEHAVIOUR the issue prescribes — one call in
# flight per box, the documented backoff order, a bounded attempt count, the bucket named on
# failure, and conditional REST for polling.
#
# ⛔ THE CLOCK IS FAKE, AND THAT IS NOT A CONVENIENCE. The documented waits are 60s, 120s and 240s;
# a suite that really slept them would take 7 minutes and would therefore never run. `GH_LIMIT_NOW_CMD`
# and `GH_LIMIT_SLEEP_CMD` replace ONLY the clock and the sleep — the decision of HOW LONG to wait is
# the production code under test, recorded and asserted below.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/gh-limit.py"
SHIM="$HERE/gh-rest/gh"
WRAPPER="$HERE/gh-limit/gh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
[ -f "$HELPER" ] || { echo "helper missing: $HELPER" >&2; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" 2>/dev/null \
  || { echo "helper does not parse: $HELPER" >&2; exit 1; }

CLOCK="$TMP/clock"
SLEEPS="$TMP/sleeps"
STUB_LOG="$TMP/stub.log"
COUNT="$TMP/count"

# ── the fake clock ───────────────────────────────────────────────────────────────────────────────
# `GH_LIMIT_SLEEP_CMD` is split with shlex and handed ONE argument (the seconds), so the recording
# and the clock advance live in a wrapper that knows where those two paths are.
cat >"$TMP/fake-sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$GH_LIMIT_TEST_SLEEPS"
python3 - "$GH_LIMIT_TEST_CLOCK" "$1" <<'PY'
import sys
clock, add = sys.argv[1], float(sys.argv[2])
try: now = float(open(clock).read().strip() or 0)
except Exception: now = 0.0
open(clock, "w").write("%.3f\n" % (now + add))
PY
SLEEP
chmod +x "$TMP/fake-sleep"
export GH_LIMIT_TEST_SLEEPS="$SLEEPS" GH_LIMIT_TEST_CLOCK="$CLOCK"
export GH_LIMIT_SLEEP_CMD="$TMP/fake-sleep"
export GH_LIMIT_NOW_CMD="cat $CLOCK"

reset_env() {  # fresh state dir, clock, counters — one scenario per box
  export GH_LIMIT_DIR="$TMP/state-$1"
  rm -rf "$GH_LIMIT_DIR"; mkdir -p "$GH_LIMIT_DIR"
  printf '1700000000\n' > "$CLOCK"
  : > "$SLEEPS"; : > "$STUB_LOG"; printf '0\n' > "$COUNT"
  rm -f "$TMP/release"
  export GH_LIMIT_SCENARIO="$1"
}

# ── the stub "real" gh ──────────────────────────────────────────────────────────────────────────
# Every scenario answers from the count of PRIOR invocations, so "fail twice then succeed" is one
# line of state rather than a fixture per attempt. Each invocation is logged as `call|<argv>`, and
# the concurrency probe logs `start|`/`end|` timestamps so overlap can be MEASURED rather than
# inferred from a counter the stub is trusted to keep.
cat >"$TMP/stub-gh" <<'STUB'
#!/usr/bin/env bash
# ⛔ EVERY invocation is logged, INCLUDING the exempt `/rate_limit` probe and the arms that exit
# early — a test that counts requests must see all of them (the probe used to be invisible here).
printf 'call|%s\n' "$*" >>"$GH_LIMIT_TEST_STUBLOG"
# ⛔ THE EXEMPT METER IS NOT WORKLOAD (#2342). `gh-limit.py` spends ONE `/rate_limit` probe per box per
# TTL when it has no snapshot, so the floor guard can act at all. It is answered HERE, before the
# per-scenario counter below is incremented: that counter models "how many LOADS did this read take",
# and a lane that shifted every scenario's counter by one would make fixtures like `n<=1 => fail` mean
# something other than what they say. The call is still logged above, so `meter_calls()` can pin it.
case "$*" in
  *"api rate_limit"*)
    # It is a real invocation, so it emits the same start/end markers the in-flight assertions count.
    printf 'start|%s\n' "$(date +%s%N)" >>"$GH_LIMIT_TEST_STUBLOG"
    # The exempt endpoint, measured to report healthy headroom while another bucket is empty. Three
    # scenarios make it report something ELSE, which is what the account-scope tests revalidate
    # against: `probeempty` = the bucket really is out (a reset ~43 min away), `probehead` = the
    # bucket has headroom, so any marker claiming otherwise is stale, and `probereplace` = a
    # CONCURRENT WRITER replacing `last-limit` while the probe is in flight.
    case "${GH_LIMIT_SCENARIO:-}" in
      probeempty) _rem=0; _reset=1700002580 ;;
      probehead)  _rem=4573; _reset=1700003600 ;;
      # ⛔ A CONCURRENT WRITER, INSTRUMENTED. `record_limit` writes `last-limit` OUTSIDE the box lock,
      # so between the gate's read and its annotation another client can replace the record with a
      # FRESH genuine refusal. This arm does exactly that while the probe is in flight, which is the
      # only way to exercise the identity guard through the gate instead of at the function level.
      probereplace)
        _rem=4573; _reset=1700003600
        printf 'at=1700000500 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' \
          > "$GH_LIMIT_DIR/last-limit" ;;
      *)          _rem=4999; _reset=1700003600 ;;
    esac
    printf '{"resources":{"core":{"remaining":%d,"reset":%d},"graphql":{"remaining":%d,"reset":%d}}}' \
      "$_rem" "$_reset" "$_rem" "$_reset"
    printf 'end|%s\n' "$(date +%s%N)" >>"$GH_LIMIT_TEST_STUBLOG"
    exit 0 ;;
esac
n="$(cat "$GH_LIMIT_TEST_COUNT" 2>/dev/null || echo 0)"
n=$(( n + 1 )); printf '%s\n' "$n" >"$GH_LIMIT_TEST_COUNT"
case "$GH_LIMIT_SCENARIO" in
  converge|limited|coalesce|leaderfail|slow)
    printf 'start|%s\n' "$(date +%s%N)" >>"$GH_LIMIT_TEST_STUBLOG"
    case "$GH_LIMIT_SCENARIO" in
      converge|limited) sleep 0.1 ;;
      leaderfail) sleep 0.4 ;;
      coalesce) sleep 0.6 ;;
      slow)
        # PARKED until the test releases it (bounded, so a broken fixture cannot hang the suite).
        _pi=0
        while [ "$_pi" -lt 100 ] && [ ! -e "$GH_LIMIT_TEST_RELEASE" ]; do sleep 0.1; _pi=$(( _pi + 1 )); done ;;
    esac
    printf 'end|%s\n' "$(date +%s%N)" >>"$GH_LIMIT_TEST_STUBLOG" ;;
esac
case "$GH_LIMIT_SCENARIO" in
  coalesce)
    # ONE answer per INVOCATION, carrying the invocation count: five callers that each ran their own
    # request would produce five DIFFERENT bodies (n=1..5), so byte-identical output is proof that
    # they received one load, not that the assertion happened to look at the right line.
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true,"n":%s}' "$n"
    exit 0 ;;
  leaderfail)
    # The FIRST call fails with a distinctive error and every later one SUCCEEDS — so a follower that
    # did not learn the leader's failure reports a success, which the test must catch.
    if [ "$n" -le 1 ]; then
      printf '{"message":"leader failed"}'
      printf 'gh: LEADER-ERROR: the first read failed (HTTP 502)\n' >&2
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true,"n":%s}' "$n"
    exit 0 ;;
  slow)
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true,"fresh":1}'
    exit 0 ;;
  converge)
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true}'
    exit 0 ;;
  limitedout)
    # Refused AND with a body on stdout: the refusal must announce the bucket without subtracting
    # what the child printed.
    printf '{"message":"API rate limit exceeded"}'
    printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
    exit 1 ;;
  versionok)
    printf 'gh version 2.102.0 (2026-01-01)\n'
    exit 0 ;;
  nonl)
    # Real gh prints a bare body with NO trailing newline — the layer must not add one.
    printf 'HTTP/2.0 200 OK\r\nEtag: "nl1"\r\n\r\n{"ok":true}'
    exit 0 ;;
  limited)
    # A secondary limit with NO headers, so every attempt consults the /rate_limit probe.
    printf 'gh: API rate limit already exceeded for user ID 81560491. (HTTP 403)\n' >&2
    exit 1 ;;
esac
case "$GH_LIMIT_SCENARIO" in
  retry-after)
    # A REST GET refused with `retry-after` — the documented first rule.
    if [ "$n" -le 1 ]; then
      printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 30\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1700003600\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
      printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\nEtag: "e1"\r\n\r\n{"state":"OPEN","number":1}'
    exit 0 ;;
  retryafterlong)
    # The server names a delay BEYOND the one-minute floor: the record must carry it, or this box's
    # peers resume 240 s inside a cool-down this process is still honouring. Refuses ONCE so the
    # normal retry path writes the record (not the give-up path).
    if [ "$n" -le 1 ]; then
      printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 300\r\nX-RateLimit-Remaining: 45\r\nX-RateLimit-Reset: 1700003600\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
      printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\nEtag: "e2"\r\n\r\n{"state":"OPEN","number":1}'
    exit 0 ;;
  retryafterlongalways)
    # The same server delay, but it NEVER clears: exercises the give-up / NO_WAIT record, which reach
    # `record_window` with no `plan_wait` result to carry the header.
    printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 300\r\nX-RateLimit-Remaining: 45\r\nX-RateLimit-Reset: 1700003600\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
    printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
    exit 1 ;;
  retryzero)
    # `retry-after: 0` — a degenerate value that must not become a zero-wait burst.
    printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 0\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1700003600\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
    printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
    exit 1 ;;
  secondary|notfound)
    # GraphQL-shaped calls: gh reports the failure on STDERR with no response header at all.
    if [ "$GH_LIMIT_SCENARIO" = secondary ]; then
      err='gh: API rate limit already exceeded for user ID 81560491. (HTTP 403)'
    else
      err='gh: Not Found (HTTP 404)'
    fi
    printf '%s\n' "$err" >&2
    exit 1 ;;
  unclassified)
    # ⛔ THE MEASURED `status=?` SHAPE. A refusal gh reports in PROSE alone: no HTTP status, no
    # headers, and none of the secondary vocabulary — so neither the bucket nor the status can be
    # classified. This is the class that used to adopt a bucket reset (~43 min) as its wait.
    printf 'gh: API rate limit exceeded.\n' >&2
    exit 1 ;;
  nearreset)
    # A genuinely EXHAUSTED bucket whose reset is INSIDE the in-call bound: the documented
    # `x-ratelimit-reset` rule must still be honoured for a primary refusal.
    if [ "$n" -le 1 ]; then
      printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1700000120\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
      printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true}'
    exit 0 ;;
  checksfail)
    # `gh pr checks` prints EVERY check on stdout and signals the verdict with the exit code
    # (0 pass / 1 fail / 8 pending). Nothing here is a rate limit.
    printf '[{"name":"ai-review-gate","state":"PENDING"},{"name":"unit","state":"SUCCESS"}]'
    printf 'Some checks are still pending\n' >&2
    exit 8 ;;
  unprocessable)
    # A 422 whose text happens to mention a rate limit (gh echoes request content in validation
    # errors). Not a limit — retrying it costs the full 7-minute backoff and cannot succeed.
    printf 'HTTP/2.0 422 Unprocessable Entity\r\n\r\n{"message":"Validation Failed"}\r\n'
    printf 'gh: Validation Failed (HTTP 422)\ngh: title must not mention the rate limit\n' >&2
    exit 1 ;;
  bogus304)
    # A 304 to a request that carried NO validator (a proxy or a misbehaving server), with the
    # cache entry absent: the layer must re-run plainly, not report an unchanged resource as empty.
    case "$*" in
      *"--include"*) printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; exit 0 ;;
    esac
    printf '{"state":"OPEN","number":7}'
    exit 0 ;;
  forbidden)
    # A 403 with NO rate-limit corroboration: a permission/scope failure. Its headers are present
    # and say nothing about a limit, which is exactly the #1762 case that must not be deferred.
    printf 'HTTP/2.0 403 Forbidden\r\n\r\n{"message":"Resource not accessible by integration"}\r\n'
    printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
    exit 1 ;;
  far-reset)
    printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1700003600\r\n\r\n{"message":"API rate limit exceeded"}\r\n'
    printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
    exit 1 ;;
  noheaders)
    # An --include response this layer cannot frame (a proxy, a stub, a gh that changed its dump).
    printf '{"state":"OPEN"}'
    exit 0 ;;
  etag|cachebound)
    case "$*" in
      *"If-None-Match"*|*"if-none-match"*)
        printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
        printf 'gh: HTTP 304 (Not Modified)\n' >&2
        exit 1 ;;
    esac
    printf 'HTTP/2.0 200 OK\r\nEtag: "abc123"\r\n\r\n{"state":"OPEN","number":4242}'
    exit 0 ;;
  etag-bin)
    # A body that is NOT valid UTF-8 (a contents/blob endpoint), which a text-decoded cache would
    # silently corrupt on replay.
    case "$*" in
      *"If-None-Match"*|*"if-none-match"*)
        printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
        exit 0 ;;
    esac
    printf 'HTTP/2.0 200 OK\r\nEtag: "bin1"\r\n\r\n'
    printf '\xff\xfe\x00binary\r\n'
    exit 0 ;;
  *)
    printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true}'
    exit 0 ;;
esac
STUB
chmod +x "$TMP/stub-gh"
export GH_LIMIT_TEST_STUBLOG="$STUB_LOG" GH_LIMIT_TEST_COUNT="$COUNT" GH_LIMIT_REAL_GH="$TMP/stub-gh"
# The `slow`/coalescing fixtures PARK a request until the test releases it, so a "leader that is
# still in flight" can be held for as long as the assertion needs without killing anything (a killed
# leader's stub child would keep writing into the NEXT scenario's log). Created by the test to
# release; removed by `reset_env`.
export GH_LIMIT_TEST_RELEASE="$TMP/release"

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
run_helper() { python3 "$HELPER" --real-gh "$TMP/stub-gh" -- "$@"; }
# ⛔ THE EXEMPT METER IS NOT A "LOAD" (#2342). `gh-limit.py` spends ONE `/rate_limit` probe per box
# per `GH_LIMIT_BUDGET_TTL` when it has no snapshot to read, so the floor guard can act at all — it is
# exempt from the primary limit and it is SHARED by every lane. Counting it as an underlying call would
# make every coalescing assertion below measure the meter instead of the read. `meter_calls()` pins it
# separately, so the exclusion cannot hide an unbounded probe.
calls() { grep '^call|' "$STUB_LOG" 2>/dev/null | grep -vc 'api rate_limit' || true; }
meter_calls() { grep '^call|' "$STUB_LOG" 2>/dev/null | grep -c 'api rate_limit' || true; }
calls_for() { grep -c -- "^call|$1" "$STUB_LOG" 2>/dev/null || true; }
sleeps() { tr '\n' ' ' < "$SLEEPS" | sed 's/ *$//'; }
# A wait must be AT LEAST its documented floor (and below the floor + its jitter ceiling): asserting
# only ">= floor" would pass a ten-minute wait, only "== floor" would forbid the jitter.
sleep_at_least() { python3 -c 'import sys
v=[float(x) for x in sys.argv[1].split()]; i=int(sys.argv[2])
sys.exit(0 if len(v)>i and v[i]>=float(sys.argv[3]) else 1)' "$(sleeps)" "$1" "$2"; }
sleep_below() { python3 -c 'import sys
v=[float(x) for x in sys.argv[1].split()]; i=int(sys.argv[2])
sys.exit(0 if len(v)>i and v[i]<float(sys.argv[3]) else 1)' "$(sleeps)" "$1" "$2"; }
has() { grep -q -- "$1" <<<"$2"; }
# Peak overlap from the stub's own start/end timestamps. Only `start`/`end` rows are events: a
# `call|` row (the other scenarios' argv log) is evidence, not a concurrency event.
max_inflight() { python3 -c '
import sys
ev=[l.strip().split("|") for l in open(sys.argv[1]) if l.strip().startswith(("start|","end|"))]
ev.sort(key=lambda r:int(r[1]))
cur=hi=0
for kind,_ in ev:
    cur += 1 if kind=="start" else -1
    hi=max(hi,cur)
print(hi)' "$STUB_LOG"; }
limit_record() { cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null || true; }

echo "gh-limit (#1988) — serialisation, documented backoff, bucket naming, conditional REST"

# ── A. `retry-after` is honoured EXACTLY (the documented first rule) ────────────────────────────
reset_env retry-after
out="$(run_helper api repos/o/r/pulls/1 2>"$TMP/err-A")"; rc=$?
ck "retry-after: the refused call is retried and the retry SUCCEEDS (rc=0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "retry-after: the header is obeyed exactly — one wait, of 30s" \
   "$([ "$(sleeps)" = "30" ] && echo 0 || echo 1)"
ck "retry-after: the caller gets the SUCCESS body, not the rate-limit body" "$(has '"state":"OPEN"' "$out" && echo 0 || echo 1)"
ck "retry-after: exactly two attempts" "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
ck "retry-after: the streams stay clean on a call that eventually succeeded" \
   "$([ ! -s "$TMP/err-A" ] && echo 0 || echo 1)"
# ⛔ AND THE WINDOW IT RECORDS IS THE SERVER'S, NOT THE FLOOR. `plan_wait` honours `retry-after`
# exactly (bounded by MAX_WAIT); `marker_until` capped EVERY non-primary window at the 60 s floor, so
# a `Retry-After: 300` had this process sleeping 300 s while its own record told peers the box was
# free in 60 — 240 s of peer traffic inside a cool-down the layer itself was obeying. Sleeps are
# stubbed here; the assertion is on the durable record.
reset_env retryafter-window
GH_LIMIT_SLEEP_CMD=true GH_LIMIT_SCENARIO=retryafterlong \
  run_helper api repos/o/r >/dev/null 2>&1 || true
_win="$(python3 -c 'import re, sys
t = open(sys.argv[1]).read()
print(int(re.search(r"\buntil=(\d+)", t).group(1)) - int(re.search(r"\bat=(\d+)", t).group(1)))' \
        "$GH_LIMIT_DIR/last-limit")"
ck "retry-after: the recorded window is the server's 300s delay, not the 60s floor (got ${_win}s)" \
   "$([ "$_win" -gt 250 ] && echo 0 || echo 1)"
# ⛔ AND THE SAME MUST HOLD ON THE PATHS THAT NEVER CALL `plan_wait`. The give-up and NO_WAIT records
# reach `record_window` with `wait=None`, so the `limit.retry_after` fallback is what carries the
# header there — without it, the two paths that write the LAST record of a run would fall back to the
# 60 s floor (unpinned by the run above, which refuses only once and ends on the retry path).
reset_env retryafter-window-nowait
GH_LIMIT_NO_WAIT=1 GH_LIMIT_SCENARIO=retryafterlongalways \
  run_helper api repos/o/r >/dev/null 2>&1 || true
_win2="$(python3 -c 'import re, sys
t = open(sys.argv[1]).read()
print(int(re.search(r"\buntil=(\d+)", t).group(1)) - int(re.search(r"\bat=(\d+)", t).group(1)))' \
        "$GH_LIMIT_DIR/last-limit")"
ck "retry-after: the NO_WAIT/give-up record ALSO carries the server's 300s window (got ${_win2}s)" \
   "$([ "$_win2" -gt 250 ] && echo 0 || echo 1)"
# ⛔ AND THE TWO RECORDS OF ONE REFUSAL MUST AGREE ABOUT ITS AGE. `events.log` said `evidence_age=0s`
# while the same event's stderr said `marker_age=120s` (the borrowed reset's age), so an operator had
# two answers to "how old is what this decision rested on". A refusal with no reset header borrows the
# last record's, and that record's age IS the evidence age — in both places.
reset_env evidence-age-agreement
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=?\n' > "$GH_LIMIT_DIR/last-limit"
printf '1700000120\n' > "$CLOCK"
GH_LIMIT_NO_WAIT=1 GH_LIMIT_SCENARIO=unclassified run_helper api graphql -f query='{viewer{login}}' \
  >/dev/null 2>"$TMP/err-age" || true
_log_age="$(grep -oE 'evidence_age=[0-9]+s' "$GH_LIMIT_DIR/events.log" | tail -1 | grep -oE '[0-9]+')"
_err_age="$(grep -oE 'marker_age=[0-9]+s' "$TMP/err-age" | tail -1 | grep -oE '[0-9]+')"
ck "NO_WAIT: the log and the stderr agree on the borrowed record's AGE (log=${_log_age}s err=${_err_age}s)" \
   "$([ -n "$_log_age" ] && [ "$_log_age" -gt 0 ] && [ "$_log_age" = "$_err_age" ] && echo 0 || echo 1)"

# ── B. A secondary limit with NO headers: >=60s, doubling, bounded, then FAIL LOUDLY ──────────
# ⛔ THE VEHICLE IS A GRAPHQL READ, NOT A MUTATION, because a MUTATION is now recorded against `core`
# (a write has no second pool, and the REST adapter translates the GraphQL-shaped writes into REST
# ones — see `bucket_for`). The assertion is unchanged: the failure must name the bucket that was
# actually refused, never whichever counter happens to look healthy.
reset_env secondary
out="$(run_helper pr view 5 --repo o/r 2>"$TMP/err-B")"; rc=$?
ck "secondary: the 4th attempt is not retried — exactly 4 attempts, then a loud failure" \
   "$([ "$(calls_for 'pr view')" -eq 4 ] && echo 0 || echo 1)"
# and the rule that made this vehicle necessary is itself pinned: a WRITE is bucketed `core`.
ck "secondary: a MUTATION is bucketed core (a write has no second pool)" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.bucket_for(['pr','merge','7'])=='core' and m.bucket_for(['repo','delete','o/r','--yes'])=='core' and m.bucket_for(['pr','view','7'])=='graphql' else 1)" && echo 0 || echo 1)"
# ⛔ `repo`/`gist` ARE NOT `REST_SUBCOMMANDS` (#2342 review, P1). They were added "because their WRITES
# are REST calls", but `is_mutating` answers `core` BEFORE that set is consulted — so the entries could
# never affect a write, while their only reachable effect mislabelled `gh repo view`/`gh repo list`
# (GraphQL `RepositoryInfo` queries) as `core`. The consequence was measured on the landing path:
# inside a dated-empty core window `admin-merge.sh`'s `gh repo view --json nameWithOwner` was refused
# with ZERO requests, printed an empty slug, and the rail reported "the repo identity could not be
# resolved" while GraphQL had thousands of requests left. This pins BOTH directions.
ck "bucket_for: a GraphQL-only repo/gist READ is graphql, while their WRITES stay core" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.bucket_for(['repo','view','o/r','--json','nameWithOwner'])=='graphql' and m.bucket_for(['repo','list'])=='graphql' and m.bucket_for(['gist','list'])=='graphql' and m.bucket_for(['gist','create','-f','x=y'])=='core' and m.bucket_for(['repo','delete','o/r','--yes'])=='core' else 1)" && echo 0 || echo 1)"

ck "secondary: the failure is LOUD on stderr (never a silent success)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
ck "secondary: the message NAMES the bucket (graphql, not the REST counter that looks healthy)" \
   "$(has 'bucket=graphql' "$(cat "$TMP/err-B")" && echo 0 || echo 1)"
ck "secondary: the message names the reset it observed" \
   "$(grep -qE 'rate limit \(bucket=graphql reset=[0-9]+ kind=secondary\)' "$TMP/err-B" && echo 0 || echo 1)"
ck "secondary: wait 1 is >= 60s"   "$(sleep_at_least 0 60 && echo 0 || echo 1)"
ck "secondary: wait 2 is >= 120s (doubling)" "$(sleep_at_least 1 120 && echo 0 || echo 1)"
ck "secondary: wait 3 is >= 240s (doubling)" "$(sleep_at_least 2 240 && echo 0 || echo 1)"
ck "secondary: and jitter stays bounded (wait 1 < 80s)" "$(sleep_below 0 80 && echo 0 || echo 1)"
ck "secondary: the limit is RECORDED for the caller's cycle, with a bucket and a reset" \
   "$(has 'bucket=graphql' "$(limit_record)" && echo 0 || echo 1)"
ck "secondary: it also records the ATTEMPTS it spent" \
   "$(has 'attempts=4' "$(limit_record)" && echo 0 || echo 1)"
ck "secondary: RETRY announcements do NOT touch the caller's stderr (it is parsed by callers)" \
   "$([ "$(grep -c 'rate limit (' "$TMP/err-B")" -eq 1 ] && echo 0 || echo 1)"

# ── C. A reset beyond the in-call bound: fail FAST, do not hold the box for an hour ────────────
reset_env far-reset
run_helper api repos/o/r 2>"$TMP/err-C"; rc=$?
ck "a reset an hour away does NOT park the call for an hour (1 attempt, no wait)" \
   "$([ "$(calls)" -eq 1 ] && [ -z "$(sleeps)" ] && echo 0 || echo 1)"
ck "and it says why, naming the in-call bound" \
   "$(has 'in-call bound' "$(cat "$TMP/err-C")" && echo 0 || echo 1)"
ck "the fail-fast BACKOFF line carries its own evidence: kind, attempt, remaining, age" \
   "$(grep -qE 'reset beyond the in-call bound.*kind=[a-z]+ attempt=[0-9]+ remaining=[0-9?]+ evidence_age=0s' \
        "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)"

# ── D. Not every failure is a rate limit ───────────────────────────────────────────────────────
reset_env notfound
run_helper pr view 9 --repo o/r >"$TMP/out-D" 2>"$TMP/err-D"; rc=$?
ck "a 404 is passed through untouched: 1 invocation, no retry" "$([ "$(calls)" -eq 1 ] && echo 0 || echo 1)"
ck "a 404 keeps its exit code" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
ck "a 404 keeps gh's own words on stderr" "$(has 'Not Found (HTTP 404)' "$(cat "$TMP/err-D")" && echo 0 || echo 1)"
reset_env unprocessable
run_helper api repos/o/r/pulls/9 2>/dev/null; rc=$?
ck "a 422 that merely MENTIONS a rate limit is not retried (no 7-minute backoff on a dead call)" \
   "$([ "$(calls)" -eq 1 ] && [ -z "$(sleeps)" ] && [ "$rc" -eq 1 ] && echo 0 || echo 1)"
reset_env forbidden
run_helper api repos/o/r 2>/dev/null; rc=$?
ck "a bare 403 with NO rate-limit corroboration is NOT retried (it is a permission failure)" \
   "$([ "$(calls)" -eq 1 ] && [ -z "$(sleeps)" ] && echo 0 || echo 1)"

# ── E. Conditional REST for polling: the ETag round trip, and a free 304 ──────────────────────
reset_env etag
first="$(run_helper api repos/o/r/pulls/4242 2>/dev/null)"
second="$(run_helper api repos/o/r/pulls/4242 2>/dev/null)"; rc2=$?
ck "conditional: the first poll stores the ETag" \
   "$(python3 -c 'import glob,json,sys
p=glob.glob(sys.argv[1]+"/etag/*.json")
sys.exit(0 if p and json.load(open(p[0]))["etag"]=="\"abc123\"" else 1)' "$GH_LIMIT_DIR" && echo 0 || echo 1)"
ck "conditional: the second poll SENDS if-none-match" "$(has 'If-None-Match: "abc123"' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
ck "conditional: a 304 is a SUCCESS for the caller (gh's own 304 error is swallowed)" \
   "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
ck "conditional: and it replays the cached body, byte for byte" \
   "$([ "$first" = "$second" ] && [ -n "$first" ] && echo 0 || echo 1)"
ck "conditional: no response framing leaked into the output" "$(has 'HTTP/2.0' "$first" && echo 1 || echo 0)"
reset_env etag
# ⛔ `jq` IS OPTIONAL FOR THE LAYER (it leaves a `--jq` call unintercepted without it), so these
# two assertions must SKIP on a jq-less box instead of going red for a legitimate environment
# (review round 8). J6 below pins the no-jq behaviour itself.
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
v="$(run_helper api repos/o/r/pulls/4242 --jq .number 2>/dev/null)"
v2="$(run_helper api repos/o/r/pulls/4242 --jq .number 2>/dev/null)"
[ "$HAVE_JQ" -eq 1 ] || printf '  skip (no jq on this box) conditional: --jq projects identically\n'
[ "$HAVE_JQ" -eq 0 ] || ck "conditional: --jq projects identically on the 200 and the 304" \
   "$([ "$v" = "4242" ] && [ "$v2" = "4242" ] && echo 0 || echo 1)"
# ⛔ gh's OWN engine emits containers COMPACTLY (one line). A `jq -r` replay pretty-printed them,
# so a successful intercepted call returned different bytes from the plain one (review round 1).
reset_env etag
c1="$(run_helper api repos/o/r/pulls/4242 --jq . 2>/dev/null)"
c2="$(run_helper api repos/o/r/pulls/4242 --jq . 2>/dev/null)"
# ⛔ AND WITH THE KEYS SORTED, because that is what gh prints: gh's embedded gojq marshals through
# encoding/json, which sorts object keys. `jq` alone keeps document order, so this exact string —
# not merely "compact" — is the reference a real `gh api --jq .` produces (review round 8).
if [ "$HAVE_JQ" -eq 1 ]; then
  ck "conditional: a --jq replay is COMPACT and KEY-SORTED, exactly like gh" \
     "$([ "$(printf '%s\n' "$c1" | wc -l)" -eq 1 ] && [ "$c1" = '{"number":4242,"state":"OPEN"}' ] && [ "$c2" = "$c1" ] && echo 0 || echo 1)"
else
  printf '  skip (no jq on this box) conditional: --jq replay is compact and key-sorted\n'
fi
# `gh api -s` is NOT a gh flag (gh: "unknown shorthand flag: 's'"). Swallowing it turned a call
# that always failed into an empty rc-0 success — the B7 shape. It must be left alone.
reset_env dummshort
run_helper api -s repos/o/r >/dev/null 2>&1
ck "conditional: an unknown short flag (-s) is NOT intercepted, so gh's own error surfaces" \
   "$(has 'api -s repos/o/r' "$(cat "$STUB_LOG")" && ! has --include "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
reset_env etag-bin
run_helper api repos/o/r/contents/blob >"$TMP/bin-1" 2>/dev/null
run_helper api repos/o/r/contents/blob >"$TMP/bin-2" 2>/dev/null
ck "conditional: a 304 replay is BYTE-exact for a NON-UTF-8 body (base64, not a text decode)" \
   "$(python3 -c 'import sys
b=open(sys.argv[1],"rb").read(); r=open(sys.argv[2],"rb").read()
sys.exit(0 if b==r and b"\xff\xfe\x00binary" in b else 1)' "$TMP/bin-1" "$TMP/bin-2" && echo 0 || echo 1)"
reset_env cachebound
export GH_LIMIT_CACHE_MAX_ENTRIES=2
for _i in 1 2 3 4; do run_helper api "repos/o/r/thing/$_i" >/dev/null 2>&1; done
unset GH_LIMIT_CACHE_MAX_ENTRIES
_n="$(ls "$GH_LIMIT_DIR/etag" 2>/dev/null | grep -c '\.json$' || true)"
ck "conditional: the ETag cache is BOUNDED (oldest evicted, not an unbounded disk leak)" \
   "$([ "$_n" -eq 2 ] && echo 0 || echo 1)"
reset_env bogus304
out="$(run_helper api repos/o/r/pulls/7 2>/dev/null)"; rc=$?
ck "conditional: a 304 with NO cache entry re-runs plainly (an unchanged resource is not an error)" \
   "$([ "$rc" -eq 0 ] && [ "$out" = '{"state":"OPEN","number":7}' ] && echo 0 || echo 1)"
reset_env noheaders
: >"$STUB_LOG"
out="$(run_helper api repos/o/r/pulls/4242 2>"$TMP/err-nf")"
# ⛔ ONE REQUEST, NOT TWO. `gh` always frames `--include`, so a body without a status line means the
# request never reached the API — re-running it doubled the traffic during an outage and discarded
# the first failure's own text. The label used to assert the REMOVED behaviour ("falls back to a
# plain call") and passed under both designs.
ck "conditional: an unframed response is returned AS-IS — exactly one request, no re-run" \
   "$([ "$out" = '{"state":"OPEN"}' ] && [ "$(calls)" -eq 1 ] && echo 0 || echo 1)"
ck "conditional: … and it says the request did not reach the API (not 'unparsable')" \
   "$(has 'did not reach the API' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"
reset_env noheaders
run_helper api --paginate repos/o/r/pulls >/dev/null 2>&1
ck "conditional: --paginate is NOT intercepted (its framing is not ours to rewrite)" \
   "$(has --include "$(cat "$STUB_LOG")" && echo 1 || echo 0)"

# ── F. Mutative pacing: >= 1s between mutations on a box ───────────────────────────────────────
reset_env pacing
run_helper api -X POST repos/o/r/issues/1/comments -f body=x >/dev/null 2>&1
run_helper api -X POST repos/o/r/issues/1/comments -f body=y >/dev/null 2>&1
run_helper api -X POST repos/o/r/issues/1/comments -f body=z >/dev/null 2>&1
ck "mutative: the SECOND mutation waits out the 1s gap (0.9 <= wait <= 1.1)" \
   "$(sleep_at_least 0 0.9 && sleep_below 0 1.1 && echo 0 || echo 1)"
# The stamp is the time the request LEFT, and the gap is between SENDS: consecutive mutations are
# spaced by ONE gap each, so the third waits ~1s as well. A future-slot RESERVATION (round 2) made
# each attempt wait again and let a lock-holding competitor compress two sends below the gap.
ck "mutative: the THIRD wait is one gap too (the gap is between sends, one gap each)" \
   "$([ "$(sleeps | wc -w)" -eq 2 ] && sleep_at_least 1 0.9 && sleep_below 1 1.1 && echo 0 || echo 1)"
reset_env pacing2
run_helper api repos/o/r/pulls >/dev/null 2>&1
run_helper api repos/o/r/pulls >/dev/null 2>&1
ck "READS are not paced (no spurious delay on a poll)" "$([ -z "$(sleeps)" ] && echo 0 || echo 1)"
# ⛔ `gh api graphql -f query=…` is a READ whose `-f` is the payload. The heartbeat's objective
# refresh is ~513 of these inside a bounded 90 s run; pacing each one starved it (review round 1).
reset_env graphql
run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "mutative: a GraphQL QUERY is not paced (its -f is the payload, not a mutation)" \
   "$([ -z "$(sleeps)" ] && echo 0 || echo 1)"

# ── G. SINGLE FLIGHT: N concurrent callers, at most 1 gh call in flight ────────────────────────
reset_env converge
: >"$STUB_LOG"
for i in 1 2 3 4 5 6 7 8; do ( "$TMP/stub-gh" >/dev/null 2>&1 ) & done
wait
ck "CONTROL: 8 unserialised callers DO overlap (the probe can fail)" "$([ "$(max_inflight)" -gt 1 ] && echo 0 || echo 1)"
: >"$STUB_LOG"
for i in 1 2 3 4 5 6 7 8; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r >"$TMP/g1-$i" 2>&1 ) &
done
wait
ck "single flight: 8 concurrent callers never exceed 1 in flight" "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
# ⛔ THIS ASSERTION USED TO READ "all 8 still ran" AND COUNTED 8 INVOCATIONS. That was protecting
# "nothing is dropped", not "the same read runs eight times" — and #2243 makes the eight identical
# reads ONE load (the queued-duplicate cost: 0.676 s at 3 lane processes, 63 s at 13). The property is
# kept, in the form that matters: every caller still gets the ANSWER. The companion below pins the
# serialisation itself for requests that are NOT identical.
ck "single flight: all 8 callers still GOT the answer (coalesced into one load) [$(calls) load(s)]" \
   "$([ "$(calls)" -eq 1 ] && [ "$(cat "$TMP"/g1-* | grep -o '"ok":true' | wc -l | tr -d ' ')" -eq 8 ] && echo 0 || echo 1)"
: >"$STUB_LOG"
for i in 1 2 3 4 5 6 7 8; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api "repos/o/r/pulls/94$i" >/dev/null 2>&1 ) &
done
wait
ck "single flight: DIFFERENT reads are NOT collapsed — 8 requests, and never 2 in flight [#$(calls)/peak $(max_inflight)]" \
   "$([ "$(calls)" -eq 8 ] && [ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"

# The PROBE is the one gh request this layer issues outside an attempt (it runs while the caller is
# in backoff, when the rest of the box is busiest). It must be serialised too.
reset_env limited
: >"$STUB_LOG"
for i in 1 2 3 4; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r >/dev/null 2>&1 ) &
done
wait
ck "single flight: the /rate_limit PROBE is serialised too (it runs outside the attempt lock)" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
ck "single flight: … and that measurement really saw the probe (the leader's 4 attempts + 3 probes)" \
   "$([ "$(grep -c '^start|' "$STUB_LOG")" -gt 4 ] && echo 0 || echo 1)"

# ── G1b. A NO-REQUEST CALL NEVER TAKES THE BOX LOCK (#3138) ────────────────────────────────────
# ⛔ WHAT THIS PINS. The single-flight lock's invariant is "one gh REQUEST in flight per box". A call
# that makes NO request cannot overlap anyone, so it must not QUEUE for the lock either — and taking it
# anyway is what starved the review actuator: `worker-terminal.sh` runs `gh auth token` (offline
# hosts.yml/keyring read) under a 10 s alarm through the `gh-rest` shim, so on a busy box the local
# credential read waited behind API traffic and the alarm fired first. The probe then REFUSED the
# worker (rc=98) and no attestation was minted, i.e. 0 merges for 9 h on a controller that had
# diagnosed the PRs correctly. Measured on the mac 2026-10-30: 4.1 s shim vs 0.009 s real binary.
# ⛔ THE ASSERTION IS PEAK OVERLAP, NOT WALL TIME (corrected after review, 2026-10-30 — this header
# used to describe a wall-clock bound the arm no longer carries): `max_inflight` is computed from the
# stub's own `start|`/`end|` rows, so it is load-insensitive. The measured milliseconds are REPORTED in
# the assertion text as evidence and are never asserted — the pre-fix floor is >= 3.6 s for six 0.6 s
# holders, which is exactly why overlap (peak 6 vs peak 1) is the discriminator that cannot flake.
# The CONTROLs below re-pin the other direction — API reads, `api rate_limit` and a help-looking flag
# VALUE all still measure peak 1 — so deleting the fast path is the only way this pair stays green.
reset_env coalesce
: >"$STUB_LOG"
_t0="$(date +%s%N)"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- auth token >"$TMP/g1b-$i" 2>&1 ) &
done
wait
_t1="$(date +%s%N)"
_tms=$(( (_t1 - _t0) / 1000000 ))
# ⛔ THE DISCRIMINATOR IS `max_inflight`, NOT the wall clock: wall time on a loaded cell is the flake
# surface, and the overlap the stub itself logs is load-insensitive. The measured milliseconds are
# still REPORTED (never asserted).
ck "no-request: 6 concurrent \`gh auth token\` calls do NOT queue on the box lock [${_tms}ms, peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -gt 1 ] && echo 0 || echo 1)"
ck "no-request: … and every caller still got its own answer (nothing swallowed) [$(( $(calls) ))]" \
   "$([ "$(calls)" -eq 6 ] && [ "$(cat "$TMP"/g1b-* | grep -c 'ok')" -ge 6 ] && echo 0 || echo 1)"
# ⛔ THE OTHER DIRECTION, IN THE SAME SUITE RUN: a REQUEST still takes the lock. If the fast path were
# implemented as "skip the lock for everything" this stays green while the serialisation invariant
# (#1988/#2005 — one request in flight) is destroyed, which is the failure the lock exists to prevent.
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api "repos/o/r/pulls/7$i" >/dev/null 2>&1 ) &
done
wait
ck "CONTROL: … while 6 concurrent API READS are still SERIALISED (never 2 in flight) [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
# ⛔ AND THE TWO SHAPES A FAIL-OPEN PREDICATE WOULD HAVE UNSERIALISED (review finding, measured: peak 6
# before this arm existed). `makes_request()` answers False for BOTH — `api rate_limit` is exempt from
# the limit but is a real request, and `-t help` is a flag VALUE that the help matcher mistakes — so a
# lock keyed on the BUDGET predicate would have let them overlap. The lock is keyed on
# `makes_no_request_strictly`, whose whole purpose is that these two keep it.
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api rate_limit >/dev/null 2>&1 ) &
done
wait
ck "CONTROL: the EXEMPT \`api rate_limit\` still takes the box lock (exempt from the LIMIT, not from the lock) [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- issue create -t help -b x >/dev/null 2>&1 ) &
done
wait
ck "CONTROL: a help-LOOKING flag VALUE (\`issue create -t help\`) still takes the box lock [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"

# ⛔ THE `auth` CLAUSE IS ITS OWN FAIL-OPEN BOUNDARY (review finding, 2026-10-30): the predicate exempts
# `auth token` and NOTHING else under `auth`, because `gh auth status` VALIDATES the token against the
# API. Measured with the predicate widened to every `auth` form: this arm drops to peak 6. Without it,
# moving `auth status` onto the fast path left the suite green.
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- auth status >/dev/null 2>&1 ) &
done
wait
ck "CONTROL: auth status VALIDATES the token against the API, so it still takes the box lock [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
# ⛔ AND THE WRITE FORMS OF `config`/`alias`: they rewrite ~/.config/gh/config.yml, and the box lock was
# their ONLY serialiser (no pacing predicate covers them). `config set` keeps it although it makes no
# request; `config get` is read-only and stays on the fast path.
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- config set editor vim >/dev/null 2>&1 ) &
done
wait
ck "CONTROL: config set REWRITES config.yml with no request — it still takes the box lock [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
reset_env coalesce
: >"$STUB_LOG"
for i in 1 2 3 4 5 6; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- config get editor >/dev/null 2>&1 ) &
done
wait
ck "...while the READ-ONLY config get is exempt and overlaps [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -gt 1 ] && echo 0 || echo 1)"

# ── G2. COALESCING: identical concurrent READS share ONE load (agent-infra#2243) ────────────────
# ⛔ WHAT THIS SECTION IS FOR. Serialisation (#1988/#2005) decides WHO GOES NEXT; it does not decide
# whether the work is worth doing twice. Thirteen lanes asking for the SAME read queued thirteen
# times for one answer already known after the first (measured: `gh pr view` 0.676 s at 3 lane
# processes, 63 s at 13, while `curl /rate_limit` was 0.091 s on 4658/5000 quota — the cost was
# OURS). Each assertion below fails when its mechanism is disabled:
#   (a) drop the coalescing                => 5 loads, and the bodies differ (n=1..5)
#   (b) make the key ignore the request    => 1 load for 5 DIFFERENT reads
#   (c) do not publish a failure           => followers report the SECOND call's success
#   (d) allow mutating argv to be shared   => 1 load for 2 merges (a lost merge)
#   (e) remove the bound                   => a hang instead of BUSY (75) with the age
#   (f) remove the age label / serve stale by default => stale presented as current
#   (6) remove the takeover                 => a dead leader's key is never released

# (a) five concurrent IDENTICAL reads make exactly ONE underlying call.
reset_env g2a
for _i in 1 2 3 4 5; do
  ( GH_LIMIT_SCENARIO=coalesce python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 \
      >"$TMP/g2a-$_i" 2>/dev/null ) &
done
wait
ck "(a) 5 concurrent IDENTICAL reads make exactly ONE underlying gh call [$(calls)]" \
   "$([ "$(calls)" -eq 1 ] && echo 0 || echo 1)"
# Byte-identical bodies carrying `n:1` (the FIRST invocation's answer): a follower that re-ran the
# request would have produced n=2..5, so this proves SHARING rather than a lucky line count.
ck "(a) … and all 5 received THAT one answer, byte-identical [$(sort -u "$TMP"/g2a-* | tr '\n' ' ')]" \
   "$([ "$(sort -u "$TMP"/g2a-* | grep -c .)" -eq 1 ] && grep -q '"n":1' "$TMP/g2a-1" && echo 0 || echo 1)"

# (b) five concurrent DIFFERENT reads are five requests — nothing is over-collapsed.
reset_env g2b
for _i in 1 2 3 4 5; do
  ( GH_LIMIT_SCENARIO=converge python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api "repos/o/r/pulls/94$_i" \
      >/dev/null 2>&1 ) &
done
wait
ck "(b) 5 concurrent DIFFERENT reads make 5 calls (no over-collapsing) [$(calls)]" \
   "$([ "$(calls)" -eq 5 ] && echo 0 || echo 1)"
ck "(b) … and they are still SERIALISED, never 2 in flight (#2005 stands) [peak $(max_inflight)]" \
   "$([ "$(max_inflight)" -eq 1 ] && echo 0 || echo 1)"
# ⛔ THE EXCLUSION MUST NOT HIDE AN UNBOUNDED PROBE (#2342 review P2). `calls()` above stops counting
# the exempt `/rate_limit` meter so the coalescing assertions measure the READ; this is the assertion
# that keeps the meter honest — five different reads on a box with no snapshot cost AT MOST one probe
# (the TTL stamp), never one per call.
ck "(b) … and the box spent AT MOST ONE exempt meter probe for them [meter=$(meter_calls)]" \
   "$([ "$(meter_calls)" -le 1 ] && echo 0 || echo 1)"

# (c) a FAILING leader: every follower learns the failure, with the leader's error, and none reports
# the success a later call would have produced.
reset_env g2c
for _i in 1 2 3 4 5; do
  ( GH_LIMIT_SCENARIO=leaderfail python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 \
      >"$TMP/g2c-out-$_i" 2>"$TMP/g2c-err-$_i"; printf '%s' "$?" >"$TMP/g2c-rc-$_i" ) &
done
wait
ck "(c) a failing leader is shared: exactly ONE call [$(calls)]" \
   "$([ "$(calls)" -eq 1 ] && echo 0 || echo 1)"
_bad=""
for _i in 1 2 3 4 5; do
  [ "$(cat "$TMP/g2c-rc-$_i")" -ne 0 ] || _bad="$_bad rc$_i"
  grep -q 'LEADER-ERROR' "$TMP/g2c-err-$_i" || _bad="$_bad err$_i"
  grep -q '"ok":true' "$TMP/g2c-out-$_i" && _bad="$_bad fake-success$_i"
done
ck "(c) … every follower exits non-zero WITH the leader's own error, none reports success [${_bad# }]" \
   "$([ -z "$_bad" ] && echo 0 || echo 1)"

# (d) two concurrent MUTATIONS are two requests. 
# ⛔ THE SAME ARGV ON PURPOSE: `body=a` vs `body=b` would differ in the KEY and the test would pass
# with the mechanism disabled. Two callers asking for the same merge (or the same comment) are two
# requests, and coalescing one would DROP it.
reset_env g2d
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api -X POST repos/o/r/issues/1/comments -f body=x \
      >/dev/null 2>&1 ) &
done
wait
ck "(d) two concurrent MUTATIONS are two calls, never one [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
# ⛔ AND THE PREDICATE THAT GATES COALESCING MUST NOT BE `is_mutating`'s. That one is `MUTATING_PAIRS`
# plus "`api graphql` is a read", and it says of itself that it "errs wide rather than narrow" — a
# false MUTATION there costs one wasted 1 s pace. Reused here, an unlisted mutation (or a GraphQL
# MUTATION, which `api_is_mutating` calls a read outright) reads as a read and two concurrent identical
# calls collapse into ONE: the second is never executed and its caller gets the first one's rc 0.
# So the gate is a READ allowlist. Both directions are pinned here (review round 2).
reset_env g2d2
for _i in 1 2; do
  ( GH_LIMIT_SCENARIO=plain python3 "$HELPER" --real-gh "$TMP/stub-gh" \
      -- api graphql -f 'query=mutation { addComment(input:{body:"x"}) { id } }' >/dev/null 2>&1 ) &
done
wait
ck "(d) two concurrent GRAPHQL MUTATIONS are two calls (a payload starting with 'mutation' is not a read) [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
reset_env g2d3
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- run delete 12345 >/dev/null 2>&1 ) &
done
wait
ck "(d) an UNLISTED mutating subcommand is never coalesced (fail closed) [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
reset_env g2d4
for _i in 1 2 3; do
  ( GH_LIMIT_SCENARIO=coalesce python3 "$HELPER" --real-gh "$TMP/stub-gh" \
      -- pr view 9 --repo o/r >"$TMP/g2d4-$_i" 2>/dev/null ) &
done
wait
ck "(d) … while an ALLOWLISTED subcommand READ still coalesces (3 callers, one load) [$(calls)]" \
   "$([ "$(calls)" -eq 1 ] && cmp -s "$TMP/g2d4-1" "$TMP/g2d4-2" && cmp -s "$TMP/g2d4-1" "$TMP/g2d4-3" && [ -s "$TMP/g2d4-1" ] && echo 0 || echo 1)"
# ⛔ THE ENDPOINT CANNOT BE "THE FIRST TOKEN THAT DOES NOT START WITH `-`". With a value-taking flag
# before it, that token is the FLAG'S VALUE — so `gh api -H 'Accept: x' graphql -f 'query=mutation…'`
# skipped the GraphQL inspection and a MUTATION was coalesced (review round 3), `-H`-prefixed GraphQL
# refusals were pinned on the `core` bucket, and a `-H`-prefixed `/rate_limit` counted as recovery
# evidence. All four call sites now share `api_endpoint`; these are the argv shapes that broke it.
reset_env g2d5
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" \
      -- api -H 'Accept: application/json' graphql -f 'query=mutation { addComment(input:{body:"x"}) { id } }' \
      >/dev/null 2>&1 ) &
done
wait
ck "(d) a GraphQL MUTATION behind a value-taking flag is STILL not coalesced [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
reset_env g2d6
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api -H 'Accept: application/json' rate_limit >/dev/null 2>&1 ) &
done
wait
ck "(d) … and the exempt /rate_limit meter behind a flag is not coalesced either [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
reset_env g2d7
for _i in 1 2 3; do
  ( GH_LIMIT_SCENARIO=converge python3 "$HELPER" --real-gh "$TMP/stub-gh" \
      -- api -H 'Accept: application/json' repos/o/r/pulls/12678 >"$TMP/g2d7-$_i" 2>/dev/null ) &
done
wait
ck "(d) … while a flagged READ endpoint still coalesces (the fix narrowed nothing) [$(calls)]" \
   "$([ "$(calls)" -eq 1 ] && cmp -s "$TMP/g2d7-1" "$TMP/g2d7-2" && cmp -s "$TMP/g2d7-1" "$TMP/g2d7-3" && [ -s "$TMP/g2d7-1" ] && echo 0 || echo 1)"
_ep="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
H = ["-H", "Accept: application/json"]
bad = []
if m.api_endpoint(["api"] + H + ["graphql", "-f", "query={x}"]) != "graphql": bad.append("endpoint")
if m.bucket_for(["api"] + H + ["graphql"]) != "graphql": bad.append("bucket")
if m.makes_request(["api"] + H + ["rate_limit"]): bad.append("recovery-evidence")
if m.pass_cache_eligible(["api"] + H + ["rate_limit"]): bad.append("memoised-meter")
if m.api_endpoint(["api", "--frobnicate", "repos/o/r"]) is not None: bad.append("unknown-flag")
# ⛔ `--preview` is a real `gh api` VALUE flag; before it was in the vocabulary an unattributable
# argv fell through `makes_request` as "some non-meter endpoint" and a `/rate_limit` behind it counted
# as RECOVERY EVIDENCE — erasing a live limit (review round 5).
for pre in (["-p", "preview"], ["--preview=preview"]):
    if m.api_endpoint(["api"] + pre + ["rate_limit"]) != "rate_limit": bad.append("preview-endpoint")
    if m.makes_request(["api"] + pre + ["rate_limit"]): bad.append("preview-recovery-evidence")
if m.makes_request(["api", "--frobnicate", "rate_limit"]): bad.append("unattributable-recovery-evidence")
print("ok" if not bad else "BROKEN %s" % bad)' "$HELPER")"
ck "endpoint: bucket, recovery-evidence, memoisation and coalescing all attribute it the same way [$_ep]" \
   "$([ "$_ep" = ok ] && echo 0 || echo 1)"

# ⛔ A SHORT FLAG'S VALUE MAY BE ATTACHED (cobra/pflag): `-fbody=x`, `-Fbody=x`, `-f=body=x` are all
# `-f body=x`, and a field makes `gh api` infer POST. Only the SEPARATE and the LONG attached forms
# were recognised, so a create spelled `-fbody=x` classified as a READ and two concurrent identical
# creates were coalesced — one of them never happened (review round 4).
reset_env g2d8
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/issues/1/comments -fbody=hello >/dev/null 2>&1 ) &
done
wait
ck "(d) an ATTACHED short data flag (-fbody=x) is a mutation, never coalesced [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
reset_env g2d9
for _i in 1 2 3; do
  ( GH_LIMIT_SCENARIO=coalesce python3 "$HELPER" --real-gh "$TMP/stub-gh" \
      -- api graphql -fquery='{viewer{login}}' >/dev/null 2>&1 ) &
done
wait
ck "(d) … while a GraphQL QUERY written the same attached way still coalesces (3 callers, one load) [$(calls)]" \
   "$([ "$(calls)" -eq 1 ] && echo 0 || echo 1)"
# ⛔ A LOCAL SIDE EFFECT IS NOT A READ. `gh run download` writes artifact files into the CWD and its
# stdout is near-empty, so coalescing it would hand a follower the leader's rc 0 while its own files
# were never fetched (review round 6). The allowlist's criterion is "stdout IS the whole result".
reset_env g2d10
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- run download 12345 >/dev/null 2>&1 ) &
done
wait
ck "(d) a read-SHAPED command with a local side effect (gh run download) is never coalesced [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
_dfl="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
bad = []
for a in ("-fbody=x", "-Fbody=x", "-f=body=x", "--field=body=x", "--raw-field=q=1"):
    if not m._data_flag_value(a)[0]: bad.append(a)
for a in ("-f", "-F", "--field", "--input"):
    if not m._data_flag_value(a)[0]: bad.append("bare:" + a)
for a in ("-X", "--paginate", "repos/o/r"):
    if m._data_flag_value(a)[0]: bad.append("false-positive:" + a)
for shape in (["api", "ep", "-fbody=x"], ["api", "ep", "-Fbody=x"], ["api", "ep", "-f=body=x"]):
    if not m.api_is_mutating(shape) or m.flight_eligible(shape): bad.append("not-mutation:" + shape[-1])
if m.flight_key(["api", "x", "-X", "GET", "-fbody=x"]) == m.flight_key(["api", "x", "-fbody=x"]):
    bad.append("key-collapse")
print("ok" if not bad else "BROKEN %s" % bad)' "$HELPER")"
ck "data flags: attached short forms are mutations, a GET-with-data keeps its own key [$_dfl]" \
   "$([ "$_dfl" = ok ] && echo 0 || echo 1)"

# ⛔ TAKEOVER IS A COMPARE-AND-SWAP, NOT unlink-then-create. Two waiters must not both pass the
# staleness test and both become leader (a peer's fresh claim deleted by the loser), and a claim we did
# not judge must be PUT BACK, not destroyed — otherwise a takeover deletes a live peer's claim.
_tk="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" python3 -c 'import importlib.util,json,os,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
d, p = m.flight_dir(), None
p = os.path.join(d, "k.leader")
bad = []
def claim(fid, started):
    rec = {"pid": os.getpid(), "started_at": started, "flight": fid}
    open(p, "w").write(json.dumps(rec))
    return rec
# (1) two waiters race one stale claim: exactly ONE may win it
judged = claim("A", 1)
first = m._take_over(p, judged)
second = m._take_over(p, judged)
if not (first is True and second is False):
    bad.append("cas:%s/%s" % (first, second))
# (2) a claim we did NOT judge is a live peer: put it back, do not destroy it
stale = {"pid": 0, "started_at": 1, "flight": "A"}
claim("B", m._now())
if m._take_over(p, stale) is not False:
    bad.append("restore-verdict")
if (m._read_json(p) or {}).get("flight") != "B":
    bad.append("peer-claim-lost")
# (2b) identity is NOT "is one of them readable": judged UNREADABLE while a peer had written a GOOD
# claim, and judged GOOD while the peer claim is UNREADABLE, must BOTH back off and destroy nothing
claim("C", m._now())
if m._take_over(p, None) is not False or (m._read_json(p) or {}).get("flight") != "C":
    bad.append("unreadable-judged-ate-a-peer")
open(p, "w").write("")
if m._take_over(p, {"pid": os.getpid(), "started_at": 2, "flight": "C"}) is not False or not os.path.exists(p):
    bad.append("readable-judged-ate-an-unreadable-peer")
# (2c) and BOTH unreadable IS the claim we judged: that one is stale, so it goes
if m._take_over(p, None) is not True or os.path.exists(p):
    bad.append("same-unreadable-not-removed")
# (2d) and a claim with NO flight id (hand-written / older) is still ours to reclaim by content
open(p, "w").write(json.dumps({"pid": 999999999, "started_at": 1, "request": "gh api x"}))
if m._take_over(p, m._read_json(p)) is not True or os.path.exists(p):
    bad.append("no-flight-id-not-removed")
# (3) no moved-aside debris
left = [n for n in os.listdir(d) if ".stale-" in n]
if left:
    bad.append("debris:%s" % left)
# (4) `_unlink_claim` needs a POSITIVE identity match: an unreadable file may be a successor inside its
# own create/write window, so it must NOT be removed (round 6) — and a FRESH claim must survive the
# reaper sweep entirely.
open(p, "w").write("")
if m._unlink_claim(p, "OURS") is not False or not os.path.exists(p):
    bad.append("unlink-ate-an-unreadable-successor")
claim("D", m._now())
if m._unlink_claim(p, "SOMEONE-ELSE") is not False or (m._read_json(p) or {}).get("flight") != "D":
    bad.append("unlink-ate-a-peer")
m.prune_flights(d)
if not os.path.exists(p):
    bad.append("reaper-ate-a-fresh-claim")
try:
    os.unlink(p)
except OSError:
    pass
print("ok" if not bad else "BROKEN %s" % bad)' "$HELPER")"
ck "(6) takeover is atomic: ONE winner per stale claim, a live peer's claim put BACK, no debris [$_tk]" \
   "$([ "$_tk" = ok ] && echo 0 || echo 1)"

# (e) a waiter past the bound: a DISTINCT `busy` (EX_TEMPFAIL) naming the holder's age — never a hang
# and never an unbounded queue. The holder is parked in the stub, so it is genuinely in flight.
reset_env g2e
( GH_LIMIT_SCENARIO=slow python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 \
    >/dev/null 2>&1 ) &
_holder=$!
sleep 2.2                              # the flight ledger is REAL time, so the age is really earned
_t0=$(date +%s)
busy_out="$(GH_LIMIT_SCENARIO=slow GH_LIMIT_FLIGHT_WAIT=0.4 python3 "$HELPER" --real-gh "$TMP/stub-gh" \
              -- api repos/o/r/pulls/9426 2>"$TMP/err-busy")"; _busyrc=$?
_el=$(( $(date +%s) - _t0 ))
: > "$GH_LIMIT_TEST_RELEASE"; wait "$_holder" 2>/dev/null
ck "(e) a waiter past the bound returns BUSY at once, not a hang (rc=$_busyrc in ${_el}s)" \
   "$([ "$_busyrc" -eq 75 ] && [ "$_el" -le 5 ] && echo 0 || echo 1)"
ck "(e) … and the outcome is DISTINCT and minimal: no answer on stdout, the age on stderr" \
   "$([ -z "$busy_out" ] && grep -qE 'is being loaded by pid [0-9]+, 2s in flight' "$TMP/err-busy" && echo 0 || echo 1)"
# ⛔ THE CLASSIFIER'S MARKER MUST NOT APPEAR, NOT EVEN NEGATED. `scripts/objective.py` decides a gh
# failure is `RATE-LIMITED` with `if "rate limit" in low` over `TRANSPORT_MARKERS` — a plain substring
# scan — so "This is NOT a rate limit" contains the marker and a `busy` was classified as a quota
# refusal: the fleet waits out a limit that was never exhausted (review round 6). The markers are READ
# OFF objective.py here, so this assertion tracks the classifier instead of a copy of its vocabulary.
_marks="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("ob", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print("|".join(m.TRANSPORT_MARKERS))' "$HERE/../objective.py" 2>/dev/null)"
_hit=""
IFS='|' read -ra _ma <<<"$_marks"
for _m in "${_ma[@]}"; do [ -n "$_m" ] && grep -qiF "$_m" "$TMP/err-busy" && _hit="$_hit [$_m]"; done
ck "(e) … saying it is neither an answer nor quota exhaustion [classifier markers hit:${_hit:-none}]" \
   "$(grep -q 'NOT an answer and NOT quota exhaustion' "$TMP/err-busy" && [ -z "$_hit" ] && echo 0 || echo 1)"
ck "(e) … and it sent no request of its own [$(calls) load(s)]" \
   "$([ "$(calls)" -eq 1 ] && echo 0 || echo 1)"

# (f) STALE IS LABELLED. An answer from an earlier flight may be served while a refresh is in flight
# — but only when the caller asks, and then the AGE goes on stderr. Never presented as current.
reset_env g2f
GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 \
  >"$TMP/g2f-first" 2>/dev/null                       # 1. one COMPLETED flight, on record
( GH_LIMIT_SCENARIO=slow python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 \
    >/dev/null 2>&1 ) &                                # 2. … and an IDENTICAL read now in flight
_holder=$!
sleep 2.2
ck "(f) WITHOUT the opt-in the stale answer is NOT served (the caller waits, then goes BUSY)" \
   "$(GH_LIMIT_SCENARIO=slow GH_LIMIT_FLIGHT_WAIT=0.4 python3 "$HELPER" --real-gh "$TMP/stub-gh" \
        -- api repos/o/r/pulls/9426 >"$TMP/g2f-nostale" 2>/dev/null; [ "$?" -eq 75 ] && [ ! -s "$TMP/g2f-nostale" ] && echo 0 || echo 1)"
stale_out="$(GH_LIMIT_SCENARIO=slow GH_LIMIT_FLIGHT_WAIT=0.4 GH_LIMIT_FLIGHT_STALE_SERVE=1 \
               python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 2>"$TMP/err-stale")"
_stalerc=$?
: > "$GH_LIMIT_TEST_RELEASE"; wait "$_holder" 2>/dev/null
ck "(f) a cached value served during a refresh reports its AGE on stderr" \
   "$(grep -qE 'STALE — served a [0-9]+s-old answer' "$TMP/err-stale" && echo 0 || echo 1)"
ck "(f) … and it is the PREVIOUS answer, not a fresh read, and it says so [rc=$_stalerc]" \
   "$([ "$_stalerc" -eq 0 ] && [ "$stale_out" = "$(cat "$TMP/g2f-first")" ] && ! has 'fresh' "$stale_out" && echo 0 || echo 1)"

# (6) STALLED-HOLDER SAFETY: a leader that DIED leaves no orphan claim, and the next caller for that
# request runs and answers instead of waiting out the age bound.
reset_env g2g
_key="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.flight_key(["api", "repos/o/r/pulls/9426"]))' "$HELPER")"
mkdir -p "$GH_LIMIT_DIR/flights"
sleep 0.1 & _deadpid=$!; wait "$_deadpid" 2>/dev/null          # a pid that is DEAD by the time we use it
printf '{"pid":%s,"started_at":%s,"request":"gh api repos/o/r/pulls/9426"}' \
  "$_deadpid" "$(( $(date +%s) - 3 ))" > "$GH_LIMIT_DIR/flights/$_key.leader"
_out="$(GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 2>/dev/null)"; _rc=$?
ck "(6) a DEAD leader's key is taken over — the next caller answers (rc=$_rc)" \
   "$([ "$_rc" -eq 0 ] && [ -n "$_out" ] && echo 0 || echo 1)"
ck "(6) … no orphan claim survives it" \
   "$([ ! -e "$GH_LIMIT_DIR/flights/$_key.leader" ] && echo 0 || echo 1)"
ck "(6) … and the takeover is RECORDED, so a stalled holder is visible to an operator" \
   "$(has 'taking the key over' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# A DEGRADED flight dir must not break — or SLOW — a gh call: without this branch every eligible call
# would wait its whole bound for a leader that can never be created. Two shapes, because they fail in
# different places: `makedirs` (the path is not a directory) and `open(O_EXCL)` (it is one, unwritable).
reset_env g2h
: > "$GH_LIMIT_DIR/flights"                 # a FILE where the directory belongs
_t0=$(date +%s)
_nf="$(GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 2>/dev/null)"; _nrc=$?
_nel=$(( $(date +%s) - _t0 ))
ck "(6) an unusable flight dir neither fails nor SLOWS the call (rc=$_nrc in ${_nel}s)" \
   "$([ "$_nrc" -eq 0 ] && [ -n "$_nf" ] && [ "$_nel" -le 5 ] && echo 0 || echo 1)"
ck "(6) … and it records that this call ran UNSHARED (never a silent claim of coalescing)" \
   "$(has 'UNSHARED' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ AN UNREADABLE CLAIM MUST NOT BE IMMORTAL. A leader SIGKILLed between `os.open(O_EXCL)` and its
# `json.dump` leaves a ZERO-LENGTH claim; if nothing removes it, `flight_claim` answers EEXIST for ever
# and EVERY caller for that key gets `busy` — the orphan lock file #2243 forbids. Its age is the
# evidence that the holder is gone (a fresh unreadable claim is a leader about to write).
reset_env g2j
_key="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.flight_key(["api", "repos/o/r/pulls/9426"]))' "$HELPER")"
mkdir -p "$GH_LIMIT_DIR/flights"
: > "$GH_LIMIT_DIR/flights/$_key.leader"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-30, time.time()-30))' \
  "$GH_LIMIT_DIR/flights/$_key.leader"
_orc="$(GH_LIMIT_SCENARIO=etag GH_LIMIT_FLIGHT_LEADER_MAX_AGE=2 python3 "$HELPER" --real-gh "$TMP/stub-gh" \
         -- api repos/o/r/pulls/9426 2>/dev/null)"; _orc_r=$?
ck "(6) an UNREADABLE orphan claim is reclaimed by its AGE, so a key is never held for ever (rc=$_orc_r)" \
   "$([ "$_orc_r" -eq 0 ] && [ -n "$_orc" ] && [ ! -e "$GH_LIMIT_DIR/flights/$_key.leader" ] && echo 0 || echo 1)"
ck "(6) … and the removal is RECORDED, not silent" \
   "$(has 'UNREADABLE claim' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ NO FLAG VALUE IS EVER PERSISTED. The flight ledger writes a request name to disk (claim, result,
# events.log); a credential passed IN ARGV (`-H 'Authorization: Bearer …'`, a token in a query) must not
# reach those files — the key carries a credential DIGEST for exactly this reason, and the label must
# not undo it. The label stops at the first flag, so this cannot regress by a "first positional" scan.
reset_env g2k
GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" \
  -- api -H 'Authorization: Bearer S3CRET-TOKEN' repos/o/r/pulls/9426 >/dev/null 2>&1
ck "(6) a credential passed in argv is NOT written into the flight ledger" \
   "$(grep -rq 'S3CRET-TOKEN' "$GH_LIMIT_DIR" 2>/dev/null && echo 1 || echo 0)"
reset_env g2l
GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 >/dev/null 2>&1
ck "(6) … while a flag-free request IS still named in the ledger (subcommand + endpoint)" \
   "$(grep -rq 'gh api repos/o/r/pulls/9426' "$GH_LIMIT_DIR/flights" 2>/dev/null && echo 0 || echo 1)"
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip (root: an unwritable dir is writable) (6) an unwritable flights dir runs the call unshared\n'
else
  reset_env g2i
  mkdir -p "$GH_LIMIT_DIR/flights"; chmod 500 "$GH_LIMIT_DIR/flights"
  _t0=$(date +%s)
  _uf="$(GH_LIMIT_SCENARIO=etag python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 2>/dev/null)"; _urc=$?
  _uel=$(( $(date +%s) - _t0 ))
  chmod 700 "$GH_LIMIT_DIR/flights" 2>/dev/null || true
  ck "(6) an UNWRITABLE flights dir still answers, unshared, without spending the bound (rc=$_urc in ${_uel}s)" \
     "$([ "$_urc" -eq 0 ] && [ -n "$_uf" ] && [ "$_uel" -le 5 ] && echo 0 || echo 1)"
fi

# The KEY is the NORMALISED REQUEST: a decoration that cannot change the answer is not part of it, and
# one that can most certainly is (a shared entry across those would replay another request's body).
_keys="$(python3 -c 'import importlib.util, os, sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
k = m.flight_key
bad = []
if k(["api", "-X", "GET", "repos/o/r"]) != k(["api", "repos/o/r"]): bad.append("explicit-GET")
if k(["search", "code", "--", "--owner=x"]) == k(["search", "code", "--owner=x"]): bad.append("dashdash")
for f in (["--jq", ".state"], ["--paginate"], ["--limit", "5"], ["--json", "state"]):
    if k(["api", "repos/o/r"] + f) == k(["api", "repos/o/r"]): bad.append("dropped:%s" % f[0])
for var, vals in (("GH_REPO", ("o/r1", "o/r2")), ("GH_HOST", ("github.com", "ent.example"))):
    seen = set()
    for v in vals:
        os.environ[var] = v; seen.add(k(["pr", "view", "9"]))
    os.environ.pop(var, None)
    if len(seen) != 2: bad.append("env-not-in-key:%s" % var)
print("same" if not bad else "BROKEN %s" % bad)' "$HELPER")"
ck "key: explicit-GET collapses, -- and GH_REPO/GH_HOST do NOT (no wrong-repo replay) [$_keys]" \
   "$([ "$_keys" = same ] && echo 0 || echo 1)"
# ⛔ A MULTI-OPERATION DOCUMENT CAN SELECT A MUTATION BY NAME. `query Foo {…} mutation M {…}` with
# `-f operationName=M` starts with `query`, so a leading-keyword test called it a read (round 7).
reset_env g2d11
for _i in 1 2; do
  ( python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql \
      -f 'query=query Foo { viewer { login } } mutation M { addComment(input:{body:"x"}) { id } }' \
      -f operationName=M >/dev/null 2>&1 ) &
done
wait
ck "(d) a multi-operation document selecting a MUTATION is not coalesced [$(calls)]" \
   "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"
# ⛔ AND A CLAIM NOBODY CAN READ HAS NO AGE: `now - 0` is the epoch, not a holder age (round 7).
reset_env g2e2
_key2="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.flight_key(["api", "repos/o/r/pulls/9426"]))' "$HELPER")"
mkdir -p "$GH_LIMIT_DIR/flights"
: > "$GH_LIMIT_DIR/flights/$_key2.leader"          # a leader killed between create and write
_uage="$(GH_LIMIT_FLIGHT_WAIT=0.4 python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/9426 2>&1 >/dev/null)"
ck "(e) an UNREADABLE holder yields a real age (the claim MTIME), never the epoch [$(sed -n 's/.*holder, \([^,]*\),.*/\1/p' <<<"$_uage")]" \
   "$(sed -n 's/.*holder, \([0-9]*\)s in flight.*/\1/p' <<<"$_uage" | grep -qE '^[0-9]+$' && [ "$(sed -n 's/.*holder, \([0-9]*\)s in flight.*/\1/p' <<<"$_uage")" -lt 120 ] && echo 0 || echo 1)"

# ── H. Re-entrancy: a gh child that re-enters must not deadlock on the box lock ────────────────
reset_env reentrant
python3 - "$GH_LIMIT_DIR/gh.lock" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "w")
fcntl.flock(fh, fcntl.LOCK_EX)
time.sleep(3)
PY
holder=$!
sleep 0.3
start="$(date +%s)"
GH_LIMIT_LOCK_HELD=1 python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
ck "re-entrancy: a nested call does not wait for the holder (${elapsed}s)" "$([ "$elapsed" -lt 2 ] && echo 0 || echo 1)"

# ── I. WIRING: the shim every harness gh call already passes through uses the layer ────────────
# ⛔ THIS IS THE FAILING-THEN-PASSING CASE. Before #1988 the adapter called the real gh directly:
# a rate-limited translated call failed on the first attempt and the caller read it as no data.
reset_env retry-after
out="$(GH_REST_REAL_GH="$TMP/stub-gh" bash "$SHIM" pr view 1 --repo o/r --json state 2>"$TMP/err-I")"
rc=$?
ck "wiring: gh-rest retries a rate-limited call instead of reporting no data (rc=0)" \
   "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "wiring: … and the harness sees the translated REST answer" "$(has 'OPEN' "$out" && echo 0 || echo 1)"
ck "wiring: … after exactly one documented wait of 30s" "$([ "$(sleeps)" = "30" ] && echo 0 || echo 1)"
ck "wiring: … through the SAME helper (one implementation, no drift)" "$([ "$(calls)" -eq 2 ] && echo 0 || echo 1)"

# ── J. The CELL wrapper resolves the real gh without exec'ing itself ───────────────────────────
reset_env plain
mkdir -p "$TMP/pathdir"
ln -sf "$TMP/stub-gh" "$TMP/pathdir/gh"
out="$(GH_LIMIT_REAL_GH= PATH="$HERE/gh-limit:$TMP/pathdir:$PATH" bash "$WRAPPER" api repos/o/r 2>"$TMP/err-J")"
rc=$?
ck "cell wrapper: it runs the NEXT gh on PATH, not itself (no exec loop)" \
   "$([ "$rc" -eq 0 ] && has 'repos/o/r' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
ck "cell wrapper: a successful call is silent (no banner on the caller's streams)" \
   "$([ ! -s "$TMP/err-J" ] && echo 0 || echo 1)"
# A PATH with python3 but NO gh at all: the wrapper must say so rather than run nothing.
rm -f "$TMP/pathdir/gh"
mkdir -p "$TMP/onlypy"
for _t in python3 dirname basename; do ln -sf "$(command -v "$_t")" "$TMP/onlypy/$_t"; done
GH_LIMIT_REAL_GH= PATH="$HERE/gh-limit:$TMP/onlypy" "$(command -v bash)" "$WRAPPER" api repos/o/r >/dev/null 2>"$TMP/err-J2"
ck "cell wrapper: an unresolvable gh is a LOUD failure, not a silent pass" \
   "$(has 'cannot locate the real gh' "$(cat "$TMP/err-J2")" && echo 0 || echo 1)"

# ── J2. The shim SURVIVES the PATH rewrite every harness script performs (#1988) ────────────
# ⛔ THIS IS THE INERT-LAYER CASE. Every gh-calling harness script prepends
# `/opt/homebrew/bin:/usr/local/bin` to PATH, so a real gh there outranks the seeded shim and the
# layer is never resolved: it reports protection and provides none. Measured on a Mac, where gh IS
# /opt/homebrew/bin/gh. The stanzas are EXTRACTED from the shipped script and RUN, the technique
# selftest.sh uses for orch-loop blocks, so a rename fails here instead of silently unserialising.
# ⛔ POSITION IS ASSERTED IN THE SOURCE, not inferred from the extracted lines: pulling the two
# `if` lines out and running them proves they prepend, which they still do when they are moved
# ABOVE the tool-dir prepend — exactly the state where the prepend shadows them again (found in
# review round 1; the extracted-line form scored this PASS).
reset_env pathstanza
mkdir -p "$TMP/cell/gh-limit" "$TMP/realbin"
cp "$WRAPPER" "$TMP/cell/gh-limit/gh"
# A REAL gh the caller had already placed FIRST — the thing the stanza has to outrank. It prints a
# marker so the exec test proves the shim reached the real binary rather than re-entering itself.
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/realbin/gh"; chmod +x "$TMP/realbin/gh"
grep -E '^if \[ -d "\$O/gh-(limit|rest)" \]' "$HERE/orch-loop.sh" > "$TMP/stanza.sh"
ck "PATH: orch-loop.sh re-asserts BOTH seeded shim dirs after prepending the tool dirs" \
   "$([ "$(grep -c '^if ' "$TMP/stanza.sh")" -eq 2 ] && echo 0 || echo 1)"
_l_export="$(grep -n '^export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH' "$HERE/orch-loop.sh" | cut -d: -f1 | head -1)"
_l_limit="$(grep -n '^if \[ -d "\$O/gh-limit" \]' "$HERE/orch-loop.sh" | cut -d: -f1 | head -1)"
_l_rest="$(grep -n '^if \[ -d "\$O/gh-rest" \]' "$HERE/orch-loop.sh" | cut -d: -f1 | head -1)"
ck "PATH: the stanzas sit BELOW the tool-dir prepend (above it, the prepend shadows them again)" \
   "$([ -n "$_l_export" ] && [ -n "$_l_limit" ] && [ -n "$_l_rest" ] \
      && [ "$_l_export" -lt "$_l_limit" ] && [ "$_l_limit" -lt "$_l_rest" ] && echo 0 || echo 1)"
_pos="$(O="$TMP/cell" PATH="$TMP/realbin:$PATH" bash -c '. "$1"; printf "%s" "$PATH"' _ "$TMP/stanza.sh" \
        | python3 -c 'import sys
p=[d for d in sys.stdin.read().split(":") if d]
print(p.index(sys.argv[1]) if sys.argv[1] in p else -1)' "$TMP/cell/gh-limit")"
ck "PATH: and the shim ends up FIRST — ahead of a real gh the caller had already put first" \
   "$([ "$_pos" = "0" ] && echo 0 || echo 1)"
# ⛔ THE ORDER IS THE ASSERTION ABOVE (`_pos` = 0). An earlier version ran the stanza and THEN
# re-prepended the tool dirs — the inverse of the shipped order, i.e. it reconstructed the very state
# the fix removes. It passed only because `/opt/homebrew/bin/gh` does not exist on a Linux runner and
# the shim fail-opened to the stub; on the Mac, where that path IS the real gh, it was red for a
# reason that has nothing to do with this code. Removed rather than repaired: the position and the
# population assertions are the property.
pop=""
for _f in "$HERE"/*.sh; do
  _b="$(basename "$_f")"
  case "$_b" in *.test.sh) continue ;; esac
  grep -q '^export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH' "$_f" || continue
  # ANY gh invocation counts — `gh repo view`, `gh auth status`, `"$GH" …` included. A subcommand
  # allow-list let a new script that only called `gh repo view` opt out silently (round 1).
  grep -qE '(^|[^#[:alnum:]_])gh [a-z]|\$GH |"\$GH"' "$_f" || continue
  # ⛔ BOTH STANZAS. Asserting only `$O/gh-limit` left `$O/gh-rest` unprotected: deleting it from
  # merge-one.sh kept the suite green, i.e. #1959's REST adapter could vanish from the merge worker's
  # PATH (the state in which NO PR COULD MERGE) with nothing failing (found in review round 4).
  grep -q '^if \[ -d "\$O/gh-limit" \]' "$_f" || pop="$pop $_b:no-limit-stanza"
  grep -q '^if \[ -d "\$O/gh-rest" \]' "$_f" || pop="$pop $_b:no-rest-stanza"
done
# `nonblocking-dispatch.sh` calls no gh itself but SPAWNS a whole worker session in-process, so its
# PATH IS the worker's PATH — the same rule applies for a reason the loop above cannot see.
grep -q '^if \[ -d "\$O/gh-limit" \]' "$HERE/nonblocking-dispatch.sh" || pop="$pop nonblocking-dispatch.sh:no-limit-stanza"
grep -q '^if \[ -d "\$O/gh-rest" \]' "$HERE/nonblocking-dispatch.sh" || pop="$pop nonblocking-dispatch.sh:no-rest-stanza"
pop="${pop# }"
ck "PATH: every gh-calling (or worker-spawning) harness script re-asserts BOTH seeded dirs [$pop]" \
   "$([ -z "$pop" ] && echo 0 || echo 1)"

# ── J3. TWO SHIM DIRS ON ONE PATH must not resolve to EACH OTHER (#1988 round 1) ─────────────
# ⛔ THE MEASURED CATASTROPHE. Each interposer used to skip only ITSELF, so `$O/gh-rest` resolved to
# `$O/gh-limit/gh`, whose helper resolved back to `$O/gh-rest/gh`: 1,700 processes in 6 s and then
# `fork: Resource temporarily unavailable` — every lane, worker and the controller unable to spawn.
# Reachable whenever a box carries BOTH seeded dirs (install.sh + the cell supervisor). The walk now
# skips every shim (they all live beside ONE ../gh-limit.py) and a depth guard refuses a third hop.
reset_env shimchase
mkdir -p "$TMP/both/gh-rest" "$TMP/both/gh-limit" "$TMP/bothreal"
cp "$SHIM" "$TMP/both/gh-rest/gh"; cp "$WRAPPER" "$TMP/both/gh-limit/gh"
cp "$HELPER" "$TMP/both/gh-limit.py"; chmod +x "$TMP/both/gh-rest/gh" "$TMP/both/gh-limit/gh"
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/bothreal/gh"; chmod +x "$TMP/bothreal/gh"
_both="$(PATH="$TMP/both/gh-rest:$TMP/both/gh-limit:$TMP/bothreal:$PATH" HOME="$TMP/home" \
          GH_LIMIT_REAL_GH= timeout 25 gh --version 2>&1)"; _brc=$?
ck "shim chase: both seed dirs on one PATH resolve to the REAL gh, not to each other (rc=0)" \
   "$([ "$_brc" -eq 0 ] && has 'REAL-GH' "$_both" && echo 0 || echo 1)"
# The backstop, driven directly: a third hop is refused LOUDLY (one broken call) rather than recursed.
_deep="$(HARNESS_GH_SHIM_DEPTH=2 PATH="$TMP/bothreal:$PATH" bash "$WRAPPER" --version 2>&1)"; _drc=$?
ck "shim chase: a third hop is REFUSED loudly instead of recursing for ever" \
   "$([ "$_drc" -eq 127 ] && has 'third gh-shim hop' "$_deep" && echo 0 || echo 1)"

# ── J4. The FAIL-OPEN path must not poison a SUCCESSFUL call's streams (#1988 round 1) ────────
# ⛔ A missing helper is a reachable state (the adapter is installed before the helper), and the
# warning used to be written to stderr on EVERY call — while callers here merge stderr into the
# bytes they parse as JSON. Reproduced: `pr view --json` became a JSONDecodeError on a box whose
# helper copy had failed. The banner may accompany a FAILURE only.
reset_env nohelper
out="$(GH_REST_LIMIT_HELPER="$TMP/absent-helper.py" GH_REST_REAL_GH="$TMP/stub-gh" \
        bash "$SHIM" api repos/o/r 2>"$TMP/err-nh")"; rc=$?
ck "fail-open: a SUCCESSFUL call through a missing helper carries NO banner (2>&1 stays parseable)" \
   "$([ "$rc" -eq 0 ] && [ ! -s "$TMP/err-nh" ] && has 'ok' "$out" && echo 0 || echo 1)"
printf '#!/usr/bin/env bash\necho boom >&2; exit 1\n' > "$TMP/broken-gh"; chmod +x "$TMP/broken-gh"
GH_REST_LIMIT_HELPER="$TMP/absent-helper.py" GH_REST_REAL_GH="$TMP/broken-gh" \
  bash "$SHIM" api repos/o/r >/dev/null 2>"$TMP/err-nh2"
ck "fail-open: a FAILED call still says the layer is missing (loud, and next to the real error)" \
   "$(has 'no limit layer at' "$(cat "$TMP/err-nh2")" && has 'boom' "$(cat "$TMP/err-nh2")" && echo 0 || echo 1)"

# ── J5. A malformed knob must not stop EVERY gh call on the box (#1988 round 1) ───────────────
reset_env knobs
out="$(GH_LIMIT_MAX_ATTEMPTS=nan GH_LIMIT_CACHE_MAX_ENTRIES=inf run_helper api repos/o/r/pulls/1 2>"$TMP/err-k")"; rc=$?
ck "knobs: nan/inf values fall back to the documented defaults instead of killing the helper" \
   "$([ "$rc" -eq 0 ] && has '"ok":true' "$out" && [ ! -s "$TMP/err-k" ] && echo 0 || echo 1)"

# ── J6. `--jq` must not add a dependency gh does not have (#1988 round 1) ─────────────────────
# gh vendors its own projection engine; this layer shells out to `jq`. With jq absent, a `--jq`
# call is left UNINTERCEPTED so gh serves it itself.
reset_env nojq
mkdir -p "$TMP/nojqbin"
for _t in python3 bash sh sleep date cat mktemp rm grep env; do
  p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$p" "$TMP/nojqbin/$_t"
done
PATH="$TMP/nojqbin" GH_LIMIT_DIR="$GH_LIMIT_DIR" GH_LIMIT_NOW_CMD="cat $CLOCK" \
  python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r --jq .state >/dev/null 2>&1
ck "no jq: a --jq call is NOT intercepted, so gh's own engine serves it" \
   "$(has --jq "$(cat "$STUB_LOG")" && ! has --include "$(cat "$STUB_LOG")" && echo 0 || echo 1)"

# ── J7. A degraded STATE DIR must not silently unserialise the box (#1988 round 1) ───────────
# A READ-ONLY `$HOME` (a sudo context, a locked-down cell home) used to fall back to a PER-PROCESS
# temp dir: no process shared a lock with the next, and `last-limit` landed where the heartbeat
# could never read it — with nothing on any stream or log saying so. The fallback is now stable per
# user and the degradation is written to the evidence log there.
reset_env degraded
: > "$TMP/blocker"
mkdir -p "$TMP/tmpdir"
out="$(TMPDIR="$TMP/tmpdir" GH_LIMIT_DIR="$TMP/blocker/sub" \
        GH_LIMIT_SLEEP_CMD="$TMP/fake-sleep" GH_LIMIT_NOW_CMD="cat $CLOCK" GH_LIMIT_TEST_SLEEPS="$SLEEPS" \
        GH_LIMIT_TEST_CLOCK="$CLOCK" GH_LIMIT_TEST_STUBLOG="$STUB_LOG" GH_LIMIT_TEST_COUNT="$COUNT" \
        python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r 2>&1)"; rc=$?
_fb="$TMP/tmpdir/gh-limit-$(id -u)"
ck "state dir: an unusable primary does not fail the call (rc=0, real answer)" \
   "$([ "$rc" -eq 0 ] && has '"ok":true' "$out" && echo 0 || echo 1)"
ck "state dir: … the fallback is SHARED per user (a lock exists there, not a per-process temp dir)" \
   "$([ -f "$_fb/gh.lock" ] && echo 0 || echo 1)"
ck "state dir: … and the degradation is RECORDED (an operator can find out the layer is degraded)" \
   "$(has 'primary state dir unusable' "$(cat "$_fb/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# ── J8. The HEARTBEAT'S telemetry tools must reach the layer too (#1988 round 1) ──────────────
# ⛔ THE HIGHEST-VOLUME CALLER BYPASSED IT. `objective.py` (the heartbeat's refresh) and the queue
# telemetry resolve `gh` ABSOLUTELY — `~/bin/gh`, `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`
# — and never consult PATH, which was deliberate (#1872: a PATH `gh` is the agent shim and refuses
# in a minimal environment). So the layer was inert for the reads that spend the most quota. They
# now prefer `$O/gh-limit/gh` / `$O/gh-rest/gh` — derived from `$O`, never from PATH, so #1872
# cannot come back through them.
# ⛔ THE SET IS THREE, NOT FOUR: on main this loop named four telemetry tools and one of them,
# `queue-dispatch.py`, was RETIRED (agent-infra#1874). It now lives at
# `scripts/orchestrator-harness/retired/queue-dispatch.py` — not a live caller, so it cannot carry a
# resolver and must not be imported here. That is why the loop below has three entries and why the
# counts in the related headers moved five -> four -> three; a header that still says four while the
# loop has three is the same drift in miniature (measured in this file's own review).
reset_env resolvers
mkdir -p "$TMP/cell/gh-limit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/cell/gh-limit/gh"; chmod +x "$TMP/cell/gh-limit/gh"
_miss=""
for _f in objective merge-queue beta-progress; do
  _got="$(O="$TMP/cell" timeout 60 python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(getattr(m, 'GH_BIN', None) or getattr(m, 'GH', None) or '')" "$HERE/../$_f.py" 2>/dev/null)"
  [ "$_got" = "$TMP/cell/gh-limit/gh" ] || _miss="$_miss $_f"
done
ck "resolvers: the heartbeat's telemetry tools prefer the DEPLOYED layer, not a pinned real gh [${_miss# }]" \
   "$([ -z "$_miss" ] && echo 0 || echo 1)"

# ── K. The CYCLE reports it — orch-loop's heartbeat token, extracted and driven directly ───────
# The record is only worth writing if the thing an operator reads every cycle shows it. Extracting
# the function (rather than sourcing a 1,600-line loop) is the same technique selftest.sh uses for
# orch-loop blocks, and it fails loudly if the function is renamed or loses its age bound.
mkdir -p "$TMP/home"
{ printf 'is_num() { case "${1:-}" in %s|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }\n' "''"
  sed -n '/^GH_LIMIT_STALE_S=/,/^}$/p' "$HERE/orch-loop.sh"
  printf 'gh_limit_token\n'
} > "$TMP/token.sh"
ck "heartbeat: the token function is still extractable from orch-loop.sh" \
   "$([ -s "$TMP/token.sh" ] && grep -q 'GH_LIMIT_STALE_S' "$TMP/token.sh" && echo 0 || echo 1)"
reset_env token
n="$(date +%s)"
printf 'at=%s bucket=graphql reset=%s attempts=4 waited=420 status=403\n' "$n" "$(( n + 600 ))" > "$GH_LIMIT_DIR/last-limit"
tok="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" HOME="$TMP/home" "$(command -v bash)" "$TMP/token.sh")"
ck "heartbeat: a LIMITED cycle reports bucket + reset (not a bare UNREADABLE)" \
   "$(has 'gh=rate_limited(bucket=graphql reset=' "$tok" && echo 0 || echo 1)"
ck "heartbeat: … and it carries the age, so a frozen value cannot pass as a fresh one" \
   "$(grep -qE ' [0-9]+s\)$' <<<"$tok" && echo 0 || echo 1)"
printf 'at=%s bucket=graphql reset=%s attempts=4 waited=420 status=403\n' "$(( n - 1000 ))" "$(( n + 600 ))" > "$GH_LIMIT_DIR/last-limit"
tok="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" HOME="$TMP/home" "$(command -v bash)" "$TMP/token.sh")"
ck "heartbeat: an OLD limit is NOT reported (a record is not a state)" "$([ -z "$tok" ] && echo 0 || echo 1)"
printf 'at=%s bucket=graphql reset=0 attempts=1 waited=0 status=403\n' "$n" > "$GH_LIMIT_DIR/last-limit"
tok="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" HOME="$TMP/home" "$(command -v bash)" "$TMP/token.sh")"
ck "heartbeat: a record with no reset says '?', never a fabricated epoch" \
   "$(has 'reset=?' "$tok" && echo 0 || echo 1)"
# ⛔ AND IT NAMES THE WINDOW THE LAYER HONOURS (`until=`), BESIDE THE RESET. A secondary/unclassified
# refusal retries in ~60 s while the bucket reset is ~43 min out; a token carrying only `reset=` told
# the human reading the cycle line that the box was blocked for 43 minutes. `reset=` is kept — every
# existing reader of the token still works — but it is no longer the only window on the line.
printf 'at=%s bucket=graphql reset=%s until=%s attempts=1 waited=0 status=? kind=unclassified\n' \
   "$n" "$(( n + 2580 ))" "$(( n + 60 ))" > "$GH_LIMIT_DIR/last-limit"
tok="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" HOME="$TMP/home" "$(command -v bash)" "$TMP/token.sh")"
ck "heartbeat: the token names the WINDOW it honours (until=), not only the bucket's reset" \
   "$(has "until=$(( n + 60 ))" "$tok" && has "reset=$(( n + 2580 ))" "$tok" && echo 0 || echo 1)"

# ── K. ROUND-2 REGRESSIONS: identity without the helper, knob coercion, NO_WAIT, recovery ───────
# ⛔ K1. THE SHIM'S IDENTITY MUST NOT BE ITS HELPER'S PRESENCE. Both seed dirs are the reachable
# deployment (install.sh + the cell supervisor) and a HALF-INSTALLED box — adapter seeded, helper
# missing — is the fail-open state the shims exist for. Identifying a shim by `../gh-limit.py`
# therefore erased the identity exactly then: the two shims resolved into each other, the depth
# guard fired, and EVERY gh call on the box exited 127 (reproduced). Identity is now the file's own
# sentinel line, so the walk lands on the real gh with the helper absent.
reset_env shimchase-nomarker
mkdir -p "$TMP/nomark/gh-rest" "$TMP/nomark/gh-limit" "$TMP/nomarkreal"
cp "$SHIM" "$TMP/nomark/gh-rest/gh"; cp "$WRAPPER" "$TMP/nomark/gh-limit/gh"
chmod +x "$TMP/nomark/gh-rest/gh" "$TMP/nomark/gh-limit/gh"
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/nomarkreal/gh"; chmod +x "$TMP/nomarkreal/gh"
_nm="$(PATH="$TMP/nomark/gh-rest:$TMP/nomark/gh-limit:$TMP/nomarkreal:$PATH" HOME="$TMP/home" \
        GH_LIMIT_REAL_GH= GH_REST_REAL_GH= timeout 25 gh --version 2>&1)"; _nmrc=$?
ck "shim identity: with the HELPER ABSENT the two shims still reach the real gh (rc=0, not 127)" \
   "$([ "$_nmrc" -eq 0 ] && has 'REAL-GH' "$_nm" && echo 0 || echo 1)"

# ⛔ K1b. READING A CANDIDATE MUST BE SILENT, BECAUSE THE REAL gh IS A COMPILED BINARY (#10009).
# The walk reads every candidate that `-f -x` admits, and on a real box that candidate IS the genuine
# gh — an ELF/Mach-O full of NUL bytes. The form that leaks is the command substitution the helper used
# to read it (`_head="$(head -c 8192 "$1")"`): bash >= 4.4 then prints
# `warning: command substitution: ignored null byte in input` on the STDERR of a call that SUCCEEDS, and
# the adapter's callers merge stderr into the bytes they PARSE (`2>&1`). MEASURED on all three cloud
# cells: that warning became the reported output of every PR read —
# `NOCHECKS:READ-FAILED:transport … ignored null byte in input` — so the acting arms found no work
# while the PR queue sat there. The cell read as IDLE, not broken: the false green.
# Two assertions, because the fix has two halves: the read is silent, AND it still identifies the
# candidate correctly (a binary carrying the sentinel must be SKIPPED as a shim, so the walk lands on
# the real gh further down PATH — resolution must not be sacrificed for quiet).
# NOTE ON NON-VACUITY: the warning does not exist below bash 4.4, and macOS ships 3.2 (it strips NULs
# silently), so on that shell this case can only catch a change that BREAKS resolution. On Linux
# (bash >= 4.4 — CI, and the fleet's cells, where the defect was measured) reverting the helper to the
# command-substitution form fails the second assertion: rc stays 0 and the merged stream carries the
# warning (measured: 101 bytes against 8 with the fix — `REAL-GH ` plus a 93-byte warning line).
reset_env binwalk
mkdir -p "$TMP/binwalk/gh-rest" "$TMP/binwalk/bin" "$TMP/binwalk/real"
cp "$SHIM" "$TMP/binwalk/gh-rest/gh"; chmod +x "$TMP/binwalk/gh-rest/gh"
# A BINARY candidate: a real object header, NUL bytes, and the sentinel after them — so it is
# unmistakably a shim while still being exactly the shape that used to leak.
{ printf '\177ELF\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0'
  printf '# harness-gh-shim-marker\n'; head -c 64 /dev/zero; } > "$TMP/binwalk/bin/gh"
chmod +x "$TMP/binwalk/bin/gh"
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/binwalk/real/gh"; chmod +x "$TMP/binwalk/real/gh"
# No `timeout` bound here (unlike the neighbouring cases): the fixture cannot recurse, so there is
# nothing to bound. A walk that FAILS to skip it exec's a non-script and exits at once (measured rc=126
# "cannot execute binary file"), so an unbounded form cannot hang the suite.
_bw="$(PATH="$TMP/binwalk/gh-rest:$TMP/binwalk/bin:$TMP/binwalk/real:$PATH" HOME="$TMP/home" \
        GH_LIMIT_REAL_GH= GH_REST_REAL_GH= gh --version 2>&1)"; _bwrc=$?
ck "binary candidate: a binary shim on PATH is SKIPPED and the walk still lands on the real gh (rc=0)" \
   "$([ "$_bwrc" -eq 0 ] && has 'REAL-GH' "$_bw" && echo 0 || echo 1)"
ck "binary candidate: reading it leaves NO 'ignored null byte' on the caller's merged stream" \
   "$(has 'ignored null byte' "$_bw" && echo 1 || echo 0)"

# The CELL WRAPPER carries the same read on its FAIL-OPEN walk — the state a half-installed box is in
# (adapter seeded, helper missing), which is exactly the state that path exists for. Same fixture, so
# the class is pinned at BOTH entry points rather than only where it was measured.
mkdir -p "$TMP/binwalk/wrap"
cp "$WRAPPER" "$TMP/binwalk/wrap/gh"; chmod +x "$TMP/binwalk/wrap/gh"
_ww="$(PATH="$TMP/binwalk/wrap:$TMP/binwalk/bin:$TMP/binwalk/real:$PATH" HOME="$TMP/home" \
        GH_LIMIT_REAL_GH= gh --version 2>&1)"; _wwrc=$?
ck "binary candidate: … and the cell wrapper's fail-open walk is silent too (rc=0, real gh reached)" \
   "$([ "$_wwrc" -eq 0 ] && has 'REAL-GH' "$_ww" && ! has 'ignored null byte' "$_ww" && echo 0 || echo 1)"

# ⛔ K2. THE FLOAT KNOBS ARE BOUNDED TOO. `cfg_int` was bounded in round 1 while the four SECONDS
# knobs still took `nan`/`inf` verbatim, and each one dies differently: nan → a traceback from
# `int(nan)` instead of gh's message, inf LOCK_TIMEOUT → a lock wait that never expires, nan MAX_WAIT
# → the fail-fast disabled, inf MUTATION_GAP → OverflowError. One typo'd value would stop every gh
# call on the box rather than mis-tune it.
_imp() {  # <ENV assignment> <attribute>  -> the imported value
  env "$1" python3 -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
v=getattr(m, sys.argv[2]); print(int(v) if float(v)==int(v) else v)' "$HELPER" "$2"
}
ck "knobs: BASE_WAIT=nan falls back to 60 (not a traceback)" "$([ "$(_imp GH_LIMIT_BASE_WAIT=nan BASE_WAIT)" = 60 ] && echo 0 || echo 1)"
ck "knobs: LOCK_TIMEOUT=inf falls back to 600 (a wait that cannot expire is a hang)" "$([ "$(_imp GH_LIMIT_LOCK_TIMEOUT=inf LOCK_TIMEOUT)" = 600 ] && echo 0 || echo 1)"
ck "knobs: MAX_WAIT=nan falls back to 300 (the fail-fast cannot be disabled)" "$([ "$(_imp GH_LIMIT_MAX_WAIT=nan MAX_WAIT)" = 300 ] && echo 0 || echo 1)"
ck "knobs: MUTATION_GAP=inf falls back to 1 (not OverflowError)" "$([ "$(_imp GH_LIMIT_MUTATION_GAP=inf MUTATION_GAP)" = 1 ] && echo 0 || echo 1)"
ck "knobs: an over-range BASE_WAIT is CLAMPED to the documented bound, not honoured" \
   "$([ "$(_imp GH_LIMIT_BASE_WAIT=1e9 BASE_WAIT)" = 3600 ] && echo 0 || echo 1)"

# ⛔ K3. A CALLER WITH ITS OWN BOUND MUST GET THE LIMIT, NOT A TIMEOUT. The layer's first backoff is
# 60 s while the heartbeat kills its telemetry reads at 90 s, so an in-call wait outlived the caller
# and a rate-limited box reported UNKNOWN/STALL with no line at all. `GH_LIMIT_NO_WAIT=1` records the
# limit and returns at once — and the words must carry "rate limit", which is what objective.py's
# TRANSPORT_MARKERS match to produce VERDICT=GH-RATE-LIMITED.
reset_env nowait
out="$(GH_LIMIT_NO_WAIT=1 GH_LIMIT_SCENARIO=limited run_helper api graphql -f query='{viewer{login}}' 2>"$TMP/err-nw")"; rc=$?
ck "NO_WAIT: the call returns AT ONCE with the bucket named (it never sleeps in-process)" \
   "$([ "$rc" -ne 0 ] && [ -z "$(sleeps)" ] && has 'bucket=graphql' "$(cat "$TMP/err-nw")" && echo 0 || echo 1)"
ck "NO_WAIT: and the failure says 'rate limit', the token objective.py's classifier looks for" \
   "$(has 'rate limit' "$(cat "$TMP/err-nw")" && echo 0 || echo 1)"
ck "NO_WAIT: the limit is still RECORDED for the heartbeat (it is not hidden by returning early)" \
   "$(has 'bucket=graphql' "$(cat "$GH_LIMIT_DIR/last-limit")" && echo 0 || echo 1)"

# ⛔ K4. A RECOVERED LIMIT IS NOT A CURRENT ONE. Without the recovery mark, one refused call kept the
# heartbeat asserting `gh=rate_limited(…)` for 15 minutes while the same line showed a healthy queue
# — a token an operator learns to ignore. `retry-after` refuses once and succeeds on the retry; the
# real clock and a no-op sleep keep the record's `at` in wall time, which is what the token reads.
reset_env recover
GH_LIMIT_NOW_CMD= GH_LIMIT_SLEEP_CMD=true GH_LIMIT_SCENARIO=retry-after \
  python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/1 >/dev/null 2>&1
ck "recovery: a retry that SUCCEEDED marks the record recovered (the limit is history, not state)" \
   "$(has 'recovered=' "$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)" && echo 0 || echo 1)"
tok="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" HOME="$TMP/home" "$(command -v bash)" "$TMP/token.sh")"
ck "recovery: and the heartbeat says recovered, not rate_limited, for a limit already read past" \
   "$(has 'gh=recovered(bucket=core' "$tok" && ! has 'rate_limited' "$tok" && echo 0 || echo 1)"

# ⛔ K5. AN UNUSABLE LOCK MUST NOT BE A SILENT UNSERIALISATION. A `gh.lock` that cannot be opened (an
# fd-exhausted box, a /tmp fallback owned by another uid) left the box fully unserialised with
# nothing in events.log and a heartbeat reporting a healthy serialised box.
reset_env lockbroken
mkdir -p "$GH_LIMIT_DIR/gh.lock"
GH_LIMIT_DIR="$GH_LIMIT_DIR" python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/1 >/dev/null 2>&1
ck "lock: an unopenable gh.lock still runs the call AND records that it was UNSERIALISED" \
   "$(has 'UNSERIALISED' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# ── L. ROUND-3: marker in BOTH entry points, lock budget, bucket scoping, floors ──────────────
# ⛔ L1. THE SENTINEL MUST BE IN BOTH ENTRY POINTS, and inside the window the resolvers read. A
# wrapper whose only "marker" is the grep PATTERN inside its own source passes K1 by an accident of
# byte offsets: pad the file past the window and two helper-less shims chase each other again (127
# for every gh call on the box).
for _s in "$SHIM" "$WRAPPER"; do
  ck "shim identity: $(basename "$(dirname "$_s")")/gh carries the sentinel in its first 8 KiB" \
     "$(head -c 8192 "$_s" | grep -q 'harness-gh-shim-marker' && echo 0 || echo 1)"
done

# ⛔ L2. RESOLVER ORDER IS OBSERVABLE, and must agree with the shell call sites: gh-rest first.
# With only gh-limit seeded (the old J8) the order could not be seen at all, and flipping the tuple
# in objective.py kept the suite green.
reset_env resorder
mkdir -p "$TMP/cell2/gh-rest" "$TMP/cell2/gh-limit"
cp "$SHIM" "$TMP/cell2/gh-rest/gh"; cp "$WRAPPER" "$TMP/cell2/gh-limit/gh"
chmod +x "$TMP/cell2/gh-rest/gh" "$TMP/cell2/gh-limit/gh"
_ord="$(O="$TMP/cell2" python3 -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("ob", sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print(m.GH_BIN)' "$HERE/../objective.py")"
ck "resolvers: with BOTH dirs seeded the adapter (gh-rest) wins, matching every shell call site" \
   "$([ "$_ord" = "$TMP/cell2/gh-rest/gh" ] && echo 0 || echo 1)"

# ⛔ L3. A BOUNDED CALLER MUST NOT DIE IN THE LOCK QUEUE. NO_WAIT bounds the BACKOFF; the lock wait
# is the other wait the layer imposes, and 600 s of it outlives every bounded caller (the heartbeat's
# 90 s refresh) — a rate-limit verdict became a silent timeout with no record at all.
reset_env nowaitlock
python3 - "$GH_LIMIT_DIR/gh.lock" <<'HLD' &
import fcntl, sys, time
fd = open(sys.argv[1], "a+")
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(20)          # far beyond NO_WAIT_LOCK_S=5, so an unbudgeted wait CANNOT pass
HLD
_holder=$!
sleep 0.5
_t0=$(date +%s)
out="$(GH_LIMIT_NO_WAIT=1 GH_LIMIT_LOCK_TIMEOUT=600 run_helper api repos/o/r/pulls/1 2>&1)"; _rc=$?
_el=$(( $(date +%s) - _t0 ))
wait "$_holder" 2>/dev/null || true
ck "NO_WAIT: a held lock does not become a 600s queue behind a 90s caller (bounded lock budget)" \
   "$([ "$_el" -le 10 ] && [ "$_rc" -eq 0 ] && has '"ok":true' "$out" && echo 0 || echo 1)"
ck "NO_WAIT: … and the unserialised call is RECORDED, not silently overlapping" \
   "$(has 'UNSERIALISED' "$(cat "$GH_LIMIT_DIR/events.log" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ L4. A `retry-after: 0` must not become four back-to-back requests. The floor is the docs' own
# "wait at least one minute" reduced to the smallest honest gap; the cap still bounds the total.
reset_env retryzero
out="$(run_helper api repos/o/r 2>"$TMP/err-rz")"; rc=$?
ck "retry-after=0: floored to >= 1s per wait, never a zero-wait burst (4 attempts, then loud)" \
   "$([ "$rc" -ne 0 ] && sleep_at_least 0 1 && sleep_at_least 2 1 && echo 0 || echo 1)"

# ⛔ L5. THE BUCKET IS THE SUBCOMMAND, NOT ANY TOKEN IN argv. `gh api repos/o/graphql-tools/...` is a
# REST read; naming the graphql pool there sends an operator to the healthy bucket.
_bk="$(python3 -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.bucket_for(["api","repos/o/graphql-tools/pulls"]), m.bucket_for(["api","graphql","-f","query={x}"]))' "$HELPER")"
ck "bucket: a repo whose NAME contains graphql is core; 'api graphql' is graphql" \
   "$([ "$_bk" = "core graphql" ] && echo 0 || echo 1)"

# ⛔ L6. RECOVERY IS BUCKET-SCOPED. A REST success proves nothing about a GraphQL limit; marking it
# recovered reported the opposite of the truth for as long as the record lived.
reset_env recbucket
python3 - "$GH_LIMIT_DIR/last-limit" <<'REC'
import sys, time
open(sys.argv[1], "w").write("at=%d bucket=graphql reset=%d attempts=1 waited=0 status=403\n"
                             % (int(time.time()), int(time.time()) + 600))
REC
GH_LIMIT_NOW_CMD= GH_LIMIT_SLEEP_CMD=true python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api repos/o/r/pulls/1 >/dev/null 2>&1
ck "recovery: a CORE success does NOT mark a GRAPHQL limit recovered" \
   "$(has 'recovered=' "$(cat "$GH_LIMIT_DIR/last-limit")" && echo 1 || echo 0)"

# ⛔ L7. A last-mutation stamp from the FUTURE is invalid by construction (a clock that stepped back),
# and honouring it parked every mutation until wall-clock caught up.
reset_env futurestamp
printf '%.0f\n' "$(( $(date +%s) + 3600 ))" > "$GH_LIMIT_DIR/last-mutation"
run_helper api -X POST repos/o/r/issues/1/comments -f body=x >/dev/null 2>&1
ck "future stamp: a mutation is NOT parked for an hour by a stamp ahead of now" \
   "$([ -z "$(sleeps)" ] && has 'ahead of now' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"

# ⛔ L8. The deploy paths must install IN PLACE (stage + mv): a truncated shim answers "" with rc 0.
_inst="$HERE/install.sh"; _dep="$HERE/../deploy-crossbox.sh"; _sup="$HERE/../cloud-cell-supervisor.sh"
_miss=""
# Both entry points are EXECUTED by every gh call on a live box, so both must be staged and renamed.
grep -q '_ctmp=.*\.seed-gh-rest' "$_inst" && grep -q 'mv -f "\$_ctmp" "\$O/gh-rest/gh"' "$_inst" \
  || _miss="$_miss install.sh:gh-rest"
grep -q 'seed-gh-limit.py' "$_inst" && grep -q 'mv -f "\$_tmp" "\$O/gh-limit.py"' "$_inst" \
  || _miss="$_miss install.sh:gh-limit.py"
has '_seed_one "$H/gh-limit/gh"' "$(cat "$_dep")" && has '_seed_one "$H/gh-limit.py"' "$(cat "$_dep")" \
  || _miss="$_miss deploy-crossbox.sh"
# The CELL deployment is the one the issue names, and nothing exercised it: the supervisor's seeding
# AND its stale-layer removal are both promises the docs make.
has 'seed_one "$HARNESS/gh-limit/gh"' "$(cat "$_sup")" && has 'seed_one "$HARNESS/gh-limit.py"' "$(cat "$_sup")" \
  || _miss="$_miss supervisor:seed"
has 'removed the stale gh-limit layer' "$(cat "$_sup")" && has 'removed the stale gh-limit layer' "$(cat "$_dep")" \
  || _miss="$_miss stale-layer-removal"
_miss="${_miss# }"
ck "deploy: both entry points staged+renamed in install.sh/deploy/supervisor, stale layer removed [$_miss]" \
   "$([ -z "$_miss" ] && echo 0 || echo 1)"

# ⛔ L9. THE CALLERS THAT HAVE THEIR OWN BOUND MUST OPT IN. K3 proves the HELPER honours NO_WAIT; this
# pins the other half — the essential half of the round-2 P1, which an earlier suite could lose
# without a single assertion failing (all four `setdefault` lines deleted ⇒ 85/85 green).
_pop=""
for _f in "$HERE/../"{objective,merge-queue,beta-progress,turn-classify,turn-end,undelivered-answers,pr-doctor,ask-owner}.py; do
  # ⛔ PARSED, NOT GREPPED. A COMMENT containing the call satisfied the old grep (measured: replacing
  # pr-doctor's call with a comment kept this gate green), and reading the environment cannot
  # distinguish this file from a MODULE IT IMPORTS (`pr-doctor.py` pulls in `objective.py`, which sets
  # it too). An AST walk sees only real CALLS.
  python3 -c 'import ast,sys
tree = ast.parse(open(sys.argv[1]).read())
for n in ast.walk(tree):
    if (isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "setdefault" and len(n.args) >= 2
            and isinstance(n.args[0], ast.Constant) and n.args[0].value == "GH_LIMIT_NO_WAIT"
            and isinstance(n.args[1], ast.Constant) and str(n.args[1].value) == "1"):
        sys.exit(0)
sys.exit(3)' "$_f" 2>/dev/null || { _pop="$_pop $(basename "$_f")"; continue; }
  # … and it must still IMPORT: a `setdefault` above `import os` is a NameError that kills the tool.
  python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)' "$_f" 2>/dev/null || _pop="$_pop !import:$(basename "$_f")"
done
ck "NO_WAIT: every bounded caller sets it for the layer AND still imports [${_pop# }]" \
   "$([ -z "$_pop" ] && echo 0 || echo 1)"

# ⛔ L10. THE MUTATION STAMP MUST BE WRITTEN UNDER THE ATTEMPT LOCK, at the moment the request leaves.
# Measured, three concurrent processes: 1.014 s / 1.002 s gaps. Stamping outside the lock (or before
# it) is what let a lock-holding competitor compress two mutations below the gap.
# ⛔ THE RANGE IS `_dispatch`, NOT `dispatch` (rebased head, measured). `dispatch()` is the meter probe;
# it takes its own `acquire_lock(strict=True)` and `mark_mutation` lives in `_dispatch` — so the old
# `def dispatch(` range spanned BOTH functions and this pin passed only because the METER's lock happened
# to be spelled `lock = acquire_lock()`. Main now spells it `strict=True`, the anchor vanished, and the
# arm reported the invariant BROKEN while it held. It is anchored on the function the comment names.
_disp="$(sed -n '/^def _dispatch(/,/^def run_attempt/p' "$HELPER")"
# ⛔ AND ON THE NON-STRICT CALL, not on the assignment's spelling: #3138 made the attempt lock
# CONDITIONAL (`lock = None if makes_no_request_strictly(gh_argv) else acquire_lock()`), and an anchor of
# `lock = acquire_lock()` would have survived the LESS correct spelling only. The three
# `acquire_lock(strict=True)` meter probes are outside this range AND carry an argument; a `_dispatch`
# that takes no attempt lock at all still fails here (empty `_lock_at`).
_lock_at="$(printf '%s\n' "$_disp" | grep -n 'acquire_lock()' | head -1 | cut -d: -f1)"
_mark_at="$(printf '%s\n' "$_disp" | grep -n 'mark_mutation()' | head -1 | cut -d: -f1)"
ck "mutative: the send stamp is written AFTER the attempt lock, inside it (not at reservation time)" \
   "$([ -n "$_lock_at" ] && [ -n "$_mark_at" ] && [ "$_lock_at" -lt "$_mark_at" ] && echo 0 || echo 1)"

# ⛔ L11. THE FLOORS ARE THE ISSUE'S REQUIREMENTS. A floor of 0 on the gap or the lock, or 1 s on the
# base wait, would let the environment switch OFF ">= 1 s between mutations", serialisation, and
# "wait at least one minute" while the knob still looked clamped.
ck "knobs: MUTATION_GAP=0 is raised to the 1s the issue requires" "$([ "$(_imp GH_LIMIT_MUTATION_GAP=0 MUTATION_GAP)" = 1 ] && echo 0 || echo 1)"
ck "knobs: LOCK_TIMEOUT=0 is raised to a wait that can still serialise" "$([ "$(_imp GH_LIMIT_LOCK_TIMEOUT=0 LOCK_TIMEOUT)" = 1 ] && echo 0 || echo 1)"
ck "knobs: NO_WAIT_LOCK_S=0 is raised to a wait that can still serialise" "$([ "$(_imp GH_LIMIT_NO_WAIT_LOCK_S=0 NO_WAIT_LOCK_S)" = 1 ] && echo 0 || echo 1)"
ck "knobs: BASE_WAIT=5 is raised to the documented one-minute floor" "$([ "$(_imp GH_LIMIT_BASE_WAIT=5 BASE_WAIT)" = 60 ] && echo 0 || echo 1)"

# ⛔ L12. An abandoned cache staging file must be reaped, and the cache bounded in BYTES too: a
# killed `cache_put` (reachable now the helper is `exec`'d and the caller's timeout kills it) would
# otherwise leave one file per death, and 500 entries x 1 MiB is a disk-gate problem.
reset_env retry-after
mkdir -p "$GH_LIMIT_DIR/etag"
: > "$GH_LIMIT_DIR/etag/abcd.json.tmp-notapid"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))' \
  "$GH_LIMIT_DIR/etag/abcd.json.tmp-notapid"
run_helper api repos/o/r/pulls/1 >/dev/null 2>&1
ck "cache: an abandoned .tmp- staging file does not survive the next store" \
   "$([ -z "$(ls "$GH_LIMIT_DIR"/etag/*.tmp-* 2>/dev/null)" ] && echo 0 || echo 1)"

# ⛔ L13. `GH_HOST` IS PART OF THE CACHE IDENTITY. gh reads the host from the ENVIRONMENT when
# `--hostname` is absent, so keying on the flag alone let a box with two hosts (or two processes with
# different GH_HOST) replay one host's body for the other on a 304 — a wrong answer with rc 0.
reset_env hostkey
GH_LIMIT_SCENARIO=etag GH_HOST=github.com run_helper api repos/o/r/pulls/9 >/dev/null 2>&1
_n1="$(ls "$GH_LIMIT_DIR"/etag/*.json 2>/dev/null | wc -l | tr -d ' ')"
GH_LIMIT_SCENARIO=etag GH_HOST=enterprise.example run_helper api repos/o/r/pulls/9 >/dev/null 2>&1
_n2="$(ls "$GH_LIMIT_DIR"/etag/*.json 2>/dev/null | wc -l | tr -d ' ')"
ck "cache: a different GH_HOST is a DIFFERENT entry (no cross-host 304 replay) [$_n1 -> $_n2]" \
   "$([ "$_n1" = 1 ] && [ "$_n2" = 2 ] && echo 0 || echo 1)"

# ⛔ L14. NO PROBE ON A CALL THAT IS ALREADY FAILING. `/rate_limit` is one more request, on the bucket
# GitHub has just told us to stop hitting; the cap check and the NO_WAIT branch must precede
# `plan_wait`, which is what consults it. Round 4's reordering had no assertion: moving `plan_wait`
# back above both checks kept the suite green (found in review round 5).
# ⛔ THE SCENARIO MUST REFUSE ON EVERY ATTEMPT. An earlier version used a scenario the stub does not
# know, so it answered 200, nothing was refused, no probe was possible — and the assertion passed
# regardless of where `plan_wait` sat (found in review round 5).
reset_env givup
GH_LIMIT_SCENARIO=limited run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1 || true
_probes="$(grep -c 'rate_limit' "$STUB_LOG" 2>/dev/null || true)"
_probes="${_probes:-0}"
ck "probe: 4 refusals spend exactly 3 probes — the GIVE-UP attempt spends none [${_probes}]" \
   "$([ "$_probes" -eq 3 ] && echo 0 || echo 1)"
reset_env nowaitprobe
GH_LIMIT_NO_WAIT=1 GH_LIMIT_SCENARIO=limited run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1 || true
ck "probe: a NO_WAIT caller spends NO probe (it cannot use the reset it would fetch)" \
   "$(! grep -q 'rate_limit' "$STUB_LOG" 2>/dev/null && echo 0 || echo 1)"

# ⛔ L15. ALL THREE RESOLVERS, not just objective.py: each carries its own copy of the tuple, and the
# documented order is gh-rest first (the adapter is what serves a GraphQL refusal over REST, #1959).
# (Three, not four, since #1874 retired `queue-dispatch.py` — the fourth resolver it used to count.)
_bad=""
for _t in objective merge-queue beta-progress; do
  python3 - "$HERE/../$_t.py" <<'ORDPY' || _bad="$_bad $_t.py"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'for c in \(os\.path\.join\(o, "([^"]+)", "gh"\), os\.path\.join\(o, "([^"]+)", "gh"\)\)', src)
sys.exit(0 if (m and m.group(1) == "gh-rest" and m.group(2) == "gh-limit") else 3)
ORDPY
done
ck "resolvers: every tool prefers gh-rest over gh-limit (the shell call sites) [${_bad# }]" \
   "$([ -z "$_bad" ] && echo 0 || echo 1)"

# ⛔ L16. The fail-open path must replay a SUCCESSFUL call's stderr (a warning the child prints while
# succeeding is exactly what an operator needs) and still keep the banner failure-only.
reset_env failopenstderr
printf '#!/usr/bin/env bash\necho "child note" >&2\necho body\n' > "$TMP/warngh"; chmod +x "$TMP/warngh"
_o="$(GH_REST_LIMIT_HELPER="$TMP/absent.py" GH_REST_REAL_GH="$TMP/warngh" bash "$SHIM" api repos/o/r 2>"$TMP/err-w")"
ck "fail-open: a successful call's OWN stderr is replayed, the banner is not" \
   "$([ "$_o" = body ] && has 'child note' "$(cat "$TMP/err-w")" && ! has 'WARNING no limit layer' "$(cat "$TMP/err-w")" && echo 0 || echo 1)"

# ⛔ L17. A staging file written by a LIVE process must survive another process's reap, while a dead
# writer's file is collected — the reap runs on EVERY gh call, so over-reaping would delete the very
# `last-limit` write it exists to protect (found in review round 5).
reset_env reap
python3 - "$GH_LIMIT_DIR" <<'LIVE' &
import os, sys, time
d = sys.argv[1]
open(os.path.join(d, ".tmp-last-limit-%d" % os.getpid()), "w").write("x")
time.sleep(6)
LIVE
_live=$!
sleep 0.5
# An UNPARSEABLE pid is only reaped once it is old (no writer can be coming back); age it so the
# fixture cannot collide with a live pid on any host (`pid_max` differs), which made this flaky.
: > "$GH_LIMIT_DIR/.tmp-last-limit-notapid"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))' \
  "$GH_LIMIT_DIR/.tmp-last-limit-notapid"
run_helper api repos/o/r/pulls/1 >/dev/null 2>&1
_livereap=0; [ -f "$GH_LIMIT_DIR/.tmp-last-limit-$_live" ] && _livereap=1
_deadgone=0; [ -f "$GH_LIMIT_DIR/.tmp-last-limit-notapid" ] || _deadgone=1
wait "$_live" 2>/dev/null || true
ck "state: a LIVE writer's staging file survives the reap; a dead writer's is collected" \
   "$([ "$_livereap" = 1 ] && [ "$_deadgone" = 1 ] && echo 0 || echo 1)"

# ⛔ L18. THE CACHE IS BOUNDED IN BYTES TOO. Entries-only allowed ~0.5 GB (500 x 1 MiB) on a box whose
# disk gate then refuses dispatch; the byte bound had no assertion (setting it to 1e18 kept the suite
# green — found in review round 5).
reset_env cachebytesbound
mkdir -p "$GH_LIMIT_DIR/etag"
for _i in 1 2 3 4; do
  python3 -c 'import base64,sys
open(sys.argv[1],"w").write("{\"etag\":\"e\",\"body_b64\":\"" + base64.b64encode(b"x"*4000).decode() + "\"}")' \
    "$GH_LIMIT_DIR/etag/old$_i.json"
  touch -d "@$(( $(date +%s) - 100 + _i ))" "$GH_LIMIT_DIR/etag/old$_i.json" 2>/dev/null || true
done
GH_LIMIT_CACHE_MAX_BYTES=6000 GH_LIMIT_SCENARIO=etag run_helper api repos/o/r/pulls/31 >/dev/null 2>&1
_nb="$(ls "$GH_LIMIT_DIR"/etag/*.json 2>/dev/null | wc -l | tr -d ' ')"
ck "cache: the BYTE bound evicts old entries even when the ENTRY count is far below its cap [$_nb]" \
   "$([ "$_nb" -le 2 ] && echo 0 || echo 1)"

# ⛔ L19. A DIRECTORY named `gh` is not the real gh. `~/.pi/agent/shims/gh` is a documented state of
# this box; `-x` is true for a directory, so the fail-open walk exec'd it — rc 126 for every call,
# and the real gh one entry later was never reached.
reset_env dirgh
# A COPY with NO sibling helper, so the FAIL-OPEN walk is what runs (with the helper present the
# helper resolves and the bash walk is never consulted — which is why an earlier version of this
# assertion passed on the reverted code).
mkdir -p "$TMP/dirpos/gh-limit" "$TMP/dirpos/fakebin/gh" "$TMP/dirpos/real"
cp "$WRAPPER" "$TMP/dirpos/gh-limit/gh"; chmod +x "$TMP/dirpos/gh-limit/gh"
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/dirpos/real/gh"; chmod +x "$TMP/dirpos/real/gh"
_dir="$(PATH="$TMP/dirpos/fakebin:$TMP/dirpos/real:$PATH" GH_LIMIT_REAL_GH= timeout 20 \
        bash "$TMP/dirpos/gh-limit/gh" --version 2>&1)"; _drc=$?
ck "fail-open: a DIRECTORY named gh is skipped, the real one after it is used (rc=0, not 126)" \
   "$([ "$_drc" -eq 0 ] && has 'REAL-GH' "$_dir" && echo 0 || echo 1)"

# ⛔ L20. A LONG-LIVED RUN OWNS ITS PIN: the ask-owner pin must never be the TCC-refused shims path.
# Restoring `~/.pi/agent/shims/gh` as the first pin (the #1872 incident's rc=126 binary) kept the
# suite green — the P1 fix had no assertion (review round 6).
reset_env pinlist
mkdir -p "$TMP/fakehome/.pi/agent/shims" "$TMP/fakehome/bin" "$TMP/cellp/gh-rest"
printf '#!/usr/bin/env bash\nexit 126\n' > "$TMP/fakehome/.pi/agent/shims/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fakehome/bin/gh"
chmod +x "$TMP/fakehome/.pi/agent/shims/gh" "$TMP/fakehome/bin/gh"
cp "$SHIM" "$TMP/cellp/gh-rest/gh"; chmod +x "$TMP/cellp/gh-rest/gh"
_pin="$(HOME="$TMP/fakehome" O="$TMP/cellp" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.GH_LAYER_ENV.get("GH_REST_REAL_GH", ""))' "$HERE/../ask-owner.py")"
ck "resolvers: the ask-owner pin is ~/bin/gh, never the TCC-refused shims symlink [$_pin]" \
   "$([ "$_pin" = "$TMP/fakehome/bin/gh" ] && echo 0 || echo 1)"

# ⛔ L21. OBJECTIVE'S LARGEST READ GOES THROUGH GH_BIN. `queue()` built `["gh", "pr", "list", …]`
# verbatim — a bare PATH lookup for the beat's biggest GraphQL read, unserialised and unbacked-off.
_qbin="$(python3 -c 'import ast,sys
tree = ast.parse(open(sys.argv[1]).read())
for fn in tree.body:
    if isinstance(fn, ast.FunctionDef) and fn.name == "queue":
        for n in ast.walk(fn):
            if isinstance(n, ast.Assign) and isinstance(n.value, ast.List) and n.value.elts \
               and isinstance(n.value.elts[0], ast.Name):
                print(n.value.elts[0].id); sys.exit(0)
sys.exit(1)' "$HERE/../objective.py" 2>/dev/null)"
ck "resolvers: objective.queue() builds its argv from GH_BIN, not a bare 'gh' [$_qbin]" \
   "$([ "$_qbin" = "GH_BIN" ] && echo 0 || echo 1)"

# ⛔ L22. A JUNK PID IN A STAGING NAME MUST NOT TAKE THE BOX DOWN. `int()` is arbitrary precision,
# `os.kill` is not: one 24-digit name raised OverflowError out of state_dir(), i.e. every gh call on
# the box failed with a traceback (reproduced in review round 5/6).
reset_env junktmp
: > "$GH_LIMIT_DIR/.tmp-last-limit-999999999999999999999999"
out="$(run_helper api repos/o/r/pulls/1 2>"$TMP/err-junk")"; rc=$?
ck "state: an unparseable/oversized pid in a staging name cannot fail a gh call (rc=0)" \
   "$([ "$rc" -eq 0 ] && has '"ok":true' "$out" && [ ! -s "$TMP/err-junk" ] && echo 0 || echo 1)"

# ⛔ L23. THE ENTERPRISE CREDENTIAL IS PART OF THE CACHE KEY. gh reads the ENTERPRISE pair for a
# non-github.com host; digesting only GH_TOKEN/GITHUB_TOKEN shared an entry between two credentials.
reset_env enttoken
GH_LIMIT_SCENARIO=etag GH_HOST=ent.example GH_ENTERPRISE_TOKEN=TOKEN-A run_helper api repos/o/r/pulls/5 >/dev/null 2>&1
_e1="$(ls "$GH_LIMIT_DIR"/etag/*.json 2>/dev/null | wc -l | tr -d ' ')"
GH_LIMIT_SCENARIO=etag GH_HOST=ent.example GH_ENTERPRISE_TOKEN=TOKEN-B run_helper api repos/o/r/pulls/5 >/dev/null 2>&1
_e2="$(ls "$GH_LIMIT_DIR"/etag/*.json 2>/dev/null | wc -l | tr -d ' ')"
ck "cache: two ENTERPRISE credentials are two entries (no cross-credential 304 replay) [$_e1 -> $_e2]" \
   "$([ "$_e1" = 1 ] && [ "$_e2" = 2 ] && echo 0 || echo 1)"

# ⛔ L24. THE ADAPTER'S fail-open walk has the same directory trap as the wrapper's: `-x` is true for
# a DIRECTORY, and selecting one turns every gh call into rc 126 (review round 6: only the wrapper
# half was pinned).
reset_env dirgh-rest
mkdir -p "$TMP/adir/gh-rest" "$TMP/adir/fakebin/gh" "$TMP/adir/real"
cp "$SHIM" "$TMP/adir/gh-rest/gh"; chmod +x "$TMP/adir/gh-rest/gh"
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/adir/real/gh"; chmod +x "$TMP/adir/real/gh"
_dr="$(PATH="$TMP/adir/fakebin:$TMP/adir/real:$PATH" GH_REST_REAL_GH= GH_REST_LIMIT_HELPER="$TMP/absent.py" \
        timeout 20 bash "$TMP/adir/gh-rest/gh" api repos/o/r 2>&1)"; _drrc=$?
ck "fail-open(adapter): a DIRECTORY named gh is skipped, the real one after it is used (rc=0)" \
   "$([ "$_drrc" -eq 0 ] && has 'REAL-GH' "$_dr" && echo 0 || echo 1)"

# ⛔ L25. THE LAYER MAY NEVER SUBTRACT WHAT THE CHILD PRINTED. `gh pr checks` prints its whole
# surface on STDOUT and signals the verdict with the exit code. Replaying only stderr on a non-limit
# failure turned a red/pending PR into an EMPTY surface, which orch-loop reads as NOCHECKS — never
# green, never fixed, the sweep stalled with no error. (P1, review round 7: the D-section 404 case
# captured stdout and never asserted it, and its stub printed nothing.)
reset_env checksfail
run_helper pr checks 9 --repo o/r >"$TMP/out-checks" 2>"$TMP/err-checks"; rc=$?
ck "a non-limit failure keeps the child's STDOUT surface (checks: red/pending stays visible)" \
   "$(has 'ai-review-gate' "$(cat "$TMP/out-checks")" && has 'PENDING' "$(cat "$TMP/out-checks")" && echo 0 || echo 1)"
ck "and keeps the child's exit code (8 = pending is not 1)" "$([ "$rc" -eq 8 ] && echo 0 || echo 1)"
ck "and keeps its stderr" "$(has 'still pending' "$(cat "$TMP/err-checks")" && echo 0 || echo 1)"

# ⛔ L26. INVISIBLE MEANS BYTE-FOR-BYTE. gh prints a bare `gh api <path>` body with NO trailing
# newline; emit() added one (36 bytes became 37).
reset_env notfound
printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true}' >/dev/null
export GH_LIMIT_SCENARIO=nonl
run_helper api repos/o/r/pulls/1 >"$TMP/out-nl" 2>/dev/null
_tail="$(tail -c 1 "$TMP/out-nl" | od -An -c | tr -d ' \n')"
ck "a body with no trailing newline is reproduced byte-for-byte [last byte: $_tail]" \
   "$([ "$(wc -c < "$TMP/out-nl" | tr -d ' ')" -eq 11 ] && [ "$_tail" = '}' ] && echo 0 || echo 1)"

# ⛔ L27. THE ETag REAPER ALSO HOLDS OFF A LIVE WRITER. Round 6 gave `prune_cache` the `_dead_writer`
# guard but only the STATE-root half had an assertion (L12's aged name was reaped by BOTH the old and
# the new code), so the guard could be deleted silently. Also pins the other direction: a DEAD
# writer's staging file must actually go (otherwise the directory grows without bound).
reset_env etag                     # the `etag` stub answers a valid conditional 200
mkdir -p "$GH_LIMIT_DIR/etag"
# ⛔ `$$` and NOT `$BASHPID`: the assertion below runs inside `$( )`, where `$BASHPID` is the
# SUBshell's pid — a live file would then be looked for under a pid that no longer exists.
LIVEPID=$$
: > "$GH_LIMIT_DIR/etag/live.json.tmp-$LIVEPID"              # a writer that is alive RIGHT NOW
: > "$GH_LIMIT_DIR/etag/dead.json.tmp-notapid"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))' \
  "$GH_LIMIT_DIR/etag/dead.json.tmp-notapid"
run_helper api repos/o/r/pulls/7 >/dev/null 2>&1
ck "etag reap: a LIVE writer's staging file survives, a DEAD one is collected" \
   "$([ -e "$GH_LIMIT_DIR/etag/live.json.tmp-$LIVEPID" ] && [ ! -e "$GH_LIMIT_DIR/etag/dead.json.tmp-notapid" ] && echo 0 || echo 1)"

# ⛔ L28. THE GIVE-UP MESSAGE MUST NAME WHAT IT IS WAITING FOR. It said "the reset is %ds away" even
# when the wait was the exponential backoff (no reset involved), so an operator debugging a box with a
# raised cap was pointed at the wrong knob.
reset_env limited
GH_LIMIT_MAX_WAIT=1 run_helper api repos/o/r >/dev/null 2>"$TMP/err-why"; rc=$?
ck "the in-call-bound failure names WHY it would have waited (backoff, not a reset)" \
   "$(has 'in-call bound' "$(cat "$TMP/err-why")" && has '(backoff' "$(cat "$TMP/err-why")" && echo 0 || echo 1)"

# ⛔ L29. A DIRECTORY IS NOT A PIN EITHER. `_PIN` selects with isfile+access(X_OK); with
# `~/bin/gh` a DIRECTORY the resolver must hand the layer NOTHING rather than a path that raises
# from subprocess (the same trap L19/L24 pin inside the shims).
reset_env pinisdir
mkdir -p "$TMP/fakehome2/bin/gh" "$TMP/fakehome2/.pi/agent/shims" "$TMP/cellp2/gh-rest"
cp "$SHIM" "$TMP/cellp2/gh-rest/gh"; chmod +x "$TMP/cellp2/gh-rest/gh"
_pin2="$(HOME="$TMP/fakehome2" O="$TMP/cellp2" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.GH_LAYER_ENV.get("GH_REST_REAL_GH", ""))' "$HERE/../ask-owner.py")"
# The next candidate may legitimately win (this box has /usr/bin/gh); what must NOT happen is a
# DIRECTORY being handed over as the binary — subprocess would then raise on every call.
ck "resolvers: a DIRECTORY at ~/bin/gh is never selected as the pin [${_pin2:-<none>}]" \
   "$([ "$_pin2" != "$TMP/fakehome2/bin/gh" ] && { [ -z "$_pin2" ] || { [ -f "$_pin2" ] && [ -x "$_pin2" ]; }; } && echo 0 || echo 1)"

# ⛔ L30. A CALL THAT MAKES NO REQUEST IS NOT EVIDENCE OF RECOVERY. `gh --version` succeeds without
# touching the API, and `cloud-cell-supervisor.sh`'s `cmd_check` runs exactly that through this
# layer — so the operator's diagnostic ERASED the live limit it was run to read (review round 8).
reset_env limited
run_helper pr view 9 --repo o/r >/dev/null 2>&1 || true   # refusal recorded under `graphql`
_before="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
export GH_LIMIT_SCENARIO=versionok
run_helper --version >/dev/null 2>&1; _vrc=$?
_after="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
ck "a no-request call (gh --version) does not mark a live limit recovered" \
   "$([ "$_vrc" -eq 0 ] && [ "$_before" = "$_after" ] && ! has 'recovered' "$_after" && echo 0 || echo 1)"

# ⛔ L31. AN EXISTING BUT UNWRITABLE STATE DIR MUST NOT SILENTLY UNSERIALISE THE BOX. It passed
# `makedirs(exist_ok=True)` and then lost the lock AND every record, so nothing said the box was
# unserialised and no limit could be reported (review round 8).
reset_env ro
_ro="$TMP/state-ro-locked"; mkdir -p "$_ro"; chmod 500 "$_ro"
mkdir -p "$TMP/tdir"
roout="$(TMPDIR="$TMP/tdir" GH_LIMIT_DIR="$_ro" run_helper api repos/o/r/pulls/1 2>"$TMP/err-ro")"; rorc=$?
chmod 700 "$_ro" 2>/dev/null || true
ck "an unwritable state dir falls back to a stable per-user dir (still serialised, still recorded)" \
   "$([ "$rorc" -eq 0 ] && has '"ok":true' "$roout" \
      && [ -e "$TMP/tdir/gh-limit-$(id -u)/gh.lock" ] \
      && echo 0 || echo 1)"

# ⛔ L32. THE PIN IS NOT A DIRECTORY — for ALL FOUR resolvers, not just ask-owner. Round 7 hardened
# four pins and asserted one; reverting the other three kept the suite green (review round 8). (It
# was five until #1874 retired `queue-dispatch.py`, which was one of the five.)
reset_env pinall
mkdir -p "$TMP/ph/bin/gh" "$TMP/ph/.pi/agent/shims" "$TMP/cellA/gh-rest"
cp "$SHIM" "$TMP/cellA/gh-rest/gh"; chmod +x "$TMP/cellA/gh-rest/gh"
# Both directions, and a value that proves the module RAN: with a real file at `~/bin/gh` each
# resolver must hand THAT path through (a missing/empty pin is the #1872 regression); with a
# directory there it must hand over something else, never the directory. A module that fails to
# import prints nothing, which must count as a FAILURE — not as "no directory found".
_bad=""
for _m in objective merge-queue beta-progress ask-owner; do
  _p="$(HOME="$TMP/ph" O="$TMP/cellA" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s)
try: s.loader.exec_module(m)
except SystemExit: pass
v = getattr(m, "GH_LAYER_ENV", {}) or {}
print(v.get("GH_REST_REAL_GH") or "MISSING")' "$HERE/../$_m.py" 2>/dev/null)"
  # Acceptable: no pin at all, or another REAL file. Never the directory itself.
  _ok=0
  [[ "$_p" == MISSING || -z "$_p" ]] && _ok=1
  [[ -f "$_p" && -x "$_p" ]] && _ok=1
  [ "$_p" = "$TMP/ph/bin/gh" ] && _ok=0
  [ "$_ok" -eq 1 ] || _bad="$_bad $_m($_p)"
done
ck "resolvers: a DIRECTORY at ~/bin/gh is never selected by any of the four [${_bad:- none}]" \
   "$([ -z "$_bad" ] && echo 0 || echo 1)"
# and the positive half: with a REAL file at ~/bin/gh the pin is handed through by all four
rmdir "$TMP/ph/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/ph/bin/gh"; chmod +x "$TMP/ph/bin/gh"
_miss=""
for _m in objective merge-queue beta-progress ask-owner; do
  _p="$(HOME="$TMP/ph" O="$TMP/cellA" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s)
try: s.loader.exec_module(m)
except SystemExit: pass
print((getattr(m, "GH_LAYER_ENV", {}) or {}).get("GH_REST_REAL_GH") or "MISSING")' "$HERE/../$_m.py" 2>/dev/null)"
  [[ "$_p" == "$TMP/ph/bin/gh" ]] || _miss="$_miss $_m"
done
ck "resolvers: a REAL pin is handed through by all four (#1872 survives the detour)[${_miss:- none}]" \
   "$([ -z "$_miss" ] && echo 0 || echo 1)"

# ⛔ L33. THE HELPER VALIDATES ITS OWN --real-gh THE SAME WAY. `X_OK` is true for a directory, so a
# mis-set GH_LIMIT_REAL_GH=<dir> raised a traceback on EVERY call (review round 8).
reset_env realdir
# NOT run_helper: it passes `--real-gh`, which outranks the env pin this assertion is about.
mkdir -p "$TMP/dirgh"          # its OWN fixture: L32 above turns ~/bin/gh into a real file
GH_LIMIT_DIR="$GH_LIMIT_DIR" GH_LIMIT_REAL_GH="$TMP/dirgh" \
  python3 "$HELPER" -- api repos/o/r >/dev/null 2>"$TMP/err-rd"; _rdrc=$?
ck "the helper refuses a DIRECTORY as the real gh (clean 127, not a traceback)" \
   "$([ "$_rdrc" -eq 127 ] && ! has 'Traceback' "$(cat "$TMP/err-rd")" && echo 0 || echo 1)"

# ⛔ L34. A REFUSAL KEEPS THE CHILD'S STDOUT TOO. The "never subtract" rule is unconditional; the
# three refusal branches replayed stderr only (review round 8).
reset_env limitedout
run_helper api repos/o/r >"$TMP/out-lo" 2>"$TMP/err-lo"; _lorc=$?
ck "a refused call keeps the child's STDOUT body as well as the announcement" \
   "$([ "$_lorc" -ne 0 ] && has 'API rate limit exceeded' "$(cat "$TMP/out-lo")" \
      && has 'rate limit' "$(cat "$TMP/err-lo")" && echo 0 || echo 1)"

# ⛔ L35. `$O` MUST BE SET BY THE LAUNCHER, or the EIGHT tools never reach the layer. The heartbeat
# never exported `O`, so on the Mac objective.py's refresh (the heaviest gh reader) stayed
# unserialised while the cells had the layer (review round 8).
# Evaluated, not grepped: `export O="$O"` (a no-op) and `export O=""` both satisfy a token grep while
# restoring exactly the round-8 bug. The parent runs under a DIFFERENT HOME than the one it pins, so
# the default must be derived from the pinned HOME.
_oline="$(grep -E '^export O=' "$HERE/../heartbeat-loop.sh" | head -1)"
_oeval="$(O= HOME=/tmp/home-ambient bash -c "$_oline"'; printf '%s' "${O:-}"' 2>/dev/null)"
ck "heartbeat-loop.sh exports a WORKING O default (empty O= must still yield \`$HOME/orchestrator\`) [${_oeval}]" \
   "$([ "$_oeval" = "/tmp/home-ambient/orchestrator" ] && echo 0 || echo 1)"

# ⛔ L36. A HELP LOOKUP IS NOT EVIDENCE OF RECOVERY EITHER. `gh api --help`, `gh -h` and `<cmd> help`
# answer without a request; before this gate they erased a live limit record exactly as `gh --version`
# did (review round 9).
reset_env limited
run_helper pr view 9 --repo o/r >/dev/null 2>&1 || true
_before_h="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
export GH_LIMIT_SCENARIO=versionok
run_helper api --help >/dev/null 2>&1
run_helper -h >/dev/null 2>&1
run_helper pr list help >/dev/null 2>&1
run_helper auth token >/dev/null 2>&1          # OFFLINE, and run every refresh by the harness
_after_h="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
ck "no-request HELP forms cannot mark a live limit recovered" \
   "$([ "$_before_h" = "$_after_h" ] && ! has 'recovered' "$_after_h" && echo 0 || echo 1)"

# ⛔ L37. THE WRITABILITY PROBE'S FILE MUST BE A NAME THE REAPER UNDERSTANDS. As `.w-<pid>` a killed
# helper (a bounded caller's timeout kills the `exec`'d helper) leaked it forever, and no reaper
# select it. The reaper keys on `.tmp-`; the probe must therefore be named that way. Behaviour is
# not observable here (the file exists for microseconds), so this pins the NAME, and L12/L27 pin the
# reaping itself.
ck "the writability probe uses a reaper-visible (\`.tmp-\`) staging name" \
   "$(grep -q '\.tmp-wprobe-' "$HELPER" && echo 0 || echo 1)"
reset_env probe
: > "$GH_LIMIT_DIR/.tmp-wprobe-999999999999999999999999"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))' \
  "$GH_LIMIT_DIR/.tmp-wprobe-999999999999999999999999"
run_helper api repos/o/r/pulls/3 >/dev/null 2>&1
ck "an abandoned probe file is reaped by the ordinary staging reaper" \
   "$([ ! -e "$GH_LIMIT_DIR/.tmp-wprobe-999999999999999999999999" ] && echo 0 || echo 1)"

# ⛔ L38. A RECORD THAT CANNOT BE WRITTEN MUST SAY SO ON A CHANNEL THE FAILING DIRECTORY CANNOT EAT.
# `events.log` lives in that directory, so the old promise said nothing precisely when the directory
# was the failure (review round 9). Simulated by making the record path unwritable.
reset_env limited                           # a refusal path WRITES the record
mkdir -p "$GH_LIMIT_DIR/last-limit"          # a DIRECTORY where the record file belongs
run_helper pr view 9 --repo o/r >/dev/null 2>"$TMP/err-warn"; _wrc=$?
ck "a failed record write warns on stderr (not only into the failing dir)" \
   "$(has 'WARNING cannot write' "$(cat "$TMP/err-warn")" && echo 0 || echo 1)"

# ⛔ L39. THE NO_WAIT BRANCH KEEPS THE CHILD'S STDOUT TOO. NO_WAIT is the mode every bounded harness
# tool uses (and the whole Mac path), and it was the branch with no assertion — deleting its replay
# left the suite green (review round 9).
reset_env limitedout
nuw="$(GH_LIMIT_NO_WAIT=1 run_helper api repos/o/r 2>"$TMP/err-nuw")"; printf '%s' "$?" >"$TMP/rc-nuw"; printf '%s' "$nuw" >"$TMP/out-nuw"
ck "NO_WAIT refusal: the child's stdout body survives alongside the bucket announcement" \
   "$([ "$(cat "$TMP/rc-nuw")" -ne 0 ] && has 'API rate limit exceeded' "$(cat "$TMP/out-nuw")" \
      && has 'rate limit' "$(cat "$TMP/err-nuw")" && echo 0 || echo 1)"

# ⛔ L40. AND SO DOES THE MAX_WAIT (fail-fast) BRANCH.
reset_env limitedout
mw="$(GH_LIMIT_MAX_WAIT=1 run_helper api repos/o/r 2>"$TMP/err-mw")"; printf '%s' "$?" >"$TMP/rc-mw"; printf '%s' "$mw" >"$TMP/out-mw"
ck "MAX_WAIT fail-fast: the child's stdout body survives alongside the announcement" \
   "$([ "$(cat "$TMP/rc-mw")" -ne 0 ] && has 'API rate limit exceeded' "$(cat "$TMP/out-mw")" \
      && has 'in-call bound' "$(cat "$TMP/err-mw")" && echo 0 || echo 1)"

# ⛔ L41. THE EXEMPT `/rate_limit` ENDPOINT IS NOT RECOVERY EVIDENCE. It answers on a box where every
# `core` call is refused, and `res_line` calls it every cycle BEFORE the token is read — so counting it
# printed `gh=recovered(bucket=core)` for a box that was still refusing (review round 10).
reset_env limited
run_helper api repos/o/r >/dev/null 2>&1 || true            # a `core` refusal on record
_before_r="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
export GH_LIMIT_SCENARIO=versionok
run_helper api rate_limit >/dev/null 2>&1                    # exempt: succeeds, cannot be refused
_after_r="$(cat "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
ck "the exempt /rate_limit probe cannot mark a live core limit recovered" \
   "$([ "$_before_r" = "$_after_r" ] && ! has 'recovered' "$_after_r" && echo 0 || echo 1)"

# ⛔ L42. THE THIRD `gh` INTERPOSER IN THIS TREE MUST NOT RE-ENTER THE CHAIN. `scripts/gh-shim/gh`
# (#984's argv-level admin-merge guard) is installed machine-globally FIRST on an interactive PATH,
# and it does not carry the harness sentinel (deliberately: the harness layers still delegate
# mutations through it). It used to treat OUR layer as "the real gh", so wrapper -> gh-shim -> wrapper
# ... ended at the depth guard with rc 127 for EVERY gh call in the process tree — a reviewer could
# not post its evidence (review round 10). gh-shim now skips sentinel-carrying shims; this pins the
# whole chain end to end.
reset_env chain
mkdir -p "$TMP/chain/wrap" "$TMP/chain/shims" "$TMP/chain/real/bin"
cp "$WRAPPER" "$TMP/chain/wrap/gh"; cp "$HELPER" "$TMP/chain/gh-limit.py"
chmod +x "$TMP/chain/wrap/gh"
cp "$HERE/../gh-shim/gh" "$TMP/chain/shims/gh"; chmod +x "$TMP/chain/shims/gh"
# ⛔ `real/bin/gh` and NOT `real/gh`: a candidate sitting beside a `gh-limit.py` is classified as a
# harness shim (the sibling half of the sentinel rule), which would make this fixture recursive.
printf '#!/usr/bin/env bash\necho REAL-GH "$@"\n' > "$TMP/chain/real/bin/gh"; chmod +x "$TMP/chain/real/bin/gh"
# `GH_LIMIT_REAL_GH=`/`AGENT_GH_REAL=`: the suite exports the stub pin globally (line 193), and the
# whole point here is that NEITHER side may be told the answer — it has to come from the walk.
# ⛔ AND THE MACHINE-GLOBAL GATE DIR IS ISOLATED. Hop 2 is `scripts/gh-shim/gh`, whose courtesy gate
# reads `${AGENT_GH_GATE_DIR:-$HOME/.pi/agent/gh-gate}` — state this suite cannot fake (it is neither
# `GH_LIMIT_DIR` nor `GH_LIMIT_SLEEP_CMD`). Measured: while the box's account was in a live 60-120 s
# shared window, the shim slept 52 s, `timeout 30` killed the chain, and this assertion failed as if
# the delegation had broken (rc 124, empty output) — a host reading, not a code change. A fresh dir
# makes the assertion measure the CHAIN and not the host's quota.
CHAIN_GATE="$TMP/chain-gate"; mkdir -p "$CHAIN_GATE"
_chain="$(PATH="$TMP/chain/wrap:$TMP/chain/shims:$TMP/chain/real/bin:/usr/bin:/bin" \
          GH_LIMIT_REAL_GH= AGENT_GH_REAL= AGENT_GH_GATE_DIR="$CHAIN_GATE" GH_LIMIT_DIR="$GH_LIMIT_DIR" \
          timeout 30 gh pr view 9 --repo o/r 2>&1)"; _chainrc=$?
ck "a three-shim chain (layer -> gh-shim -> real) reaches the REAL gh (rc=0, not 127)" \
   "$([ "$_chainrc" -eq 0 ] && has 'REAL-GH' "$_chain" && ! has '127' "$_chain" && echo 0 || echo 1)"
ck "and #984's guard still runs for the commands it guards (gh-shim is not skipped by the layer)" \
   "$(has 'gh-shim' "$(PATH="$TMP/chain/wrap:$TMP/chain/shims:$TMP/chain/real/bin:/usr/bin:/bin" \
        GH_LIMIT_REAL_GH= AGENT_GH_REAL= AGENT_GH_GATE_DIR="$CHAIN_GATE" GH_LIMIT_DIR="$GH_LIMIT_DIR" \
        timeout 30 gh pr merge 9 --repo o/r --admin --squash 2>&1 | tr '\n' ' ')" && echo 0 || echo 1)"

# ── M. ACCOUNT SCOPE (agent-infra#2137): the budget and the block window belong to the ACCOUNT ──
# ⛔ WHY A WHOLE SECTION. Everything above bounds what THIS BOX sends. Four boxes act as ONE GitHub
# account, so the account's burst is ~4x a per-box budget and GitHub enforces its SECONDARY limit on
# the ACCOUNT. Measured 2026-10-20: `gh api rate_limit` reported graphql ~4573/5000 while every call
# was refused, and a `status=?` marker carrying a reset ~43 min ahead blocked every client on the box
# for the full window although the layer's own wait had never run. These assertions pin the three
# properties that fix it: a PARTITION derived from a declared fleet size, an UNCLASSIFIED refusal that
# can never claim a bucket reset as its window, and a marker that is revalidated and aged before it
# is allowed to block anything.

# ⛔ M1. THE SHARE IS THE ACCOUNT'S BUDGET DIVIDED BY THE DECLARED FLEET — not by the box's own
# measured rate, because a box cannot measure a peer it cannot reach. 5000/hr x 0.8 safety = 4000/hr
# for the fleet: 66/min for 1 box, 33 for 2, 16 for 4. A share that rounds to 0 would brick the box,
# so the floor is 1.
_share() {  # <ENV assignment>… -> "<per_window> <per_min as int>"
  env "$@" python3 -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
s=m.account_share(); print(s["per_window"], int(s["per_min"]))' "$HELPER"
}
ck "account: N=1 gets 66/min of the account's 5000/hr (x0.8 safety), N=2 gets 33" \
   "$([ "$(_share GH_LIMIT_ACCOUNT_FLEET_SIZE=1)" = "66 66" ] && [ "$(_share GH_LIMIT_ACCOUNT_FLEET_SIZE=2)" = "33 33" ] && echo 0 || echo 1)"
ck "account: N=4 (the default) gets 16/min — the account's budget split four ways" \
   "$([ "$(_share GH_LIMIT_ACCOUNT_FLEET_SIZE=4)" = "16 16" ] && echo 0 || echo 1)"
ck "account: a share that would round to ZERO is floored at 1 call/window, never a dead box" \
   "$([ "$(_share GH_LIMIT_ACCOUNT_FLEET_SIZE=64 GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR=60)" = "1 0" ] && echo 0 || echo 1)"
ck "account: the safety fraction and the budget are separate knobs (5000 x 1.0 / 4 = 20/min)" \
   "$([ "$(_share GH_LIMIT_ACCOUNT_FLEET_SIZE=4 GH_LIMIT_ACCOUNT_SAFETY=1.0)" = "20 20" ] && echo 0 || echo 1)"
# ⛔ A SPELLING MUST NOT SILENCE THE PARTITION. `bucket_for` returns lowercase literals, so an
# operator writing `GraphQL` in the bucket list made every call miss the partition — inert, silent.
_part="$(env GH_LIMIT_ACCOUNT_PARTITION_BUCKETS='GraphQL, CORE' python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(",".join(m.ACCOUNT_PARTITION_BUCKETS))' "$HELPER")"
ck "account: the partition bucket list is CASE-FOLDED (a spelling cannot silence the partition) [$_part]" \
   "$([ "$_part" = "graphql,core" ] && echo 0 || echo 1)"

# ⛔ M2. AND IT IS HONOURED ON THE WIRE, with the cap derived from the DECLARED FLEET SIZE. A budget of
# 120/hr at safety 1.0 is 2 calls/min for ONE declared box and 1/min for TWO, so the same second call
# is free under one declaration and paced under the other. That difference IS the partition, and it is
# the reason a box must declare its peers rather than measure them.
reset_env share1
_share_env="GH_LIMIT_ACCOUNT_FLEET_SIZE=1 GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR=120 GH_LIMIT_ACCOUNT_SAFETY=1.0"
env $_share_env python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
env $_share_env python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
_first_two="$(sleeps)"
env $_share_env python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "account: N=1 — two graphql calls fit its share, and neither waits" "$([ -z "$_first_two" ] && echo 0 || echo 1)"
ck "account: … and the THIRD waits out the window (it does not burst past the partition)" \
   "$(sleep_at_least 0 55 && sleep_below 0 90 && echo 0 || echo 1)"
ck "account: the wait is RECORDED with the share it enforced (an operator can see the partition)" \
   "$(has 'at this box' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"
reset_env share2
_share_env2="GH_LIMIT_ACCOUNT_FLEET_SIZE=2 GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR=120 GH_LIMIT_ACCOUNT_SAFETY=1.0"
env $_share_env2 python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
_one_call="$(sleeps)"
env $_share_env2 python3 "$HELPER" --real-gh "$TMP/stub-gh" -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "account: the SAME budget declared as a 2-box fleet paces the SECOND call (the share is N-derived)" \
   "$([ -z "$_one_call" ] && sleep_at_least 0 55 && echo 0 || echo 1)"
# A caller with its own subprocess bound cannot be paced without outliving it; it proceeds and the
# OVERDRAW is recorded rather than the box going blind (the #2137/NO_WAIT contract).
reset_env share3
for _i in 1 2 3; do
  GH_LIMIT_NO_WAIT=1 env $_share_env2 python3 "$HELPER" --real-gh "$TMP/stub-gh" \
    -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
done
ck "account: a NO_WAIT caller is never parked by the partition — it proceeds and says it overdrew" \
   "$([ -z "$(sleeps)" ] && has 'OVER the box' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"
# ⛔ AND THE OVERDRAW LINE CANNOT EAT THE RECORD. A ~500-call NO_WAIT refresh against a 16-call share
# would emit ~500 overdraw lines; past `EVENTS_MAX_BYTES` every one of them rewrites the log to its
# last 500 lines, so refusals, probes and marker decisions would be evicted by this feature's own
# noise — turning a limited box into a box that looks merely slow. One line per window per bucket.
for _i in $(seq 1 20); do
  GH_LIMIT_NO_WAIT=1 env $_share_env2 python3 "$HELPER" --real-gh "$TMP/stub-gh" \
    -- api graphql -f query='{viewer{login}}' >/dev/null 2>&1
done
ck "account: 20 over-share calls record the overdraw ONCE, not 20 times (the log stays evidence)" \
   "$([ "$(grep -c 'OVER the box' "$GH_LIMIT_DIR/events.log")" -eq 1 ] && echo 0 || echo 1)"

# ⛔ M3. AN UNCLASSIFIED REFUSAL (`status=?`) IS ITS OWN CLASS: >=1 min with jitter, doubling — and it
# must NOT adopt the bucket reset. The stub probes `remaining=4999, reset=+3600`, so a run that waited
# the reset would sleep ~3600s; the assertion is that every wait stays inside the documented curve.
reset_env unclassified
GH_LIMIT_SCENARIO=unclassified run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>"$TMP/err-M3" || true
_rec="$(limit_record)"
ck "unclassified: classified and RECORDED as kind=unclassified (the classification is evidence)" \
   "$(has 'kind=unclassified' "$_rec" && echo 0 || echo 1)"
ck "unclassified: waits >=60s then >=120s then >=240s — the documented curve, not the reset" \
   "$(sleep_at_least 0 60 && sleep_at_least 1 120 && sleep_at_least 2 240 && echo 0 || echo 1)"
ck "unclassified: NO wait is anywhere near the bucket reset (nothing >= 600s) [$(sleeps)]" \
   "$(python3 -c 'import sys
v=[float(x) for x in sys.argv[1].split()]
sys.exit(0 if v and max(v) < 600 else 1)' "$(sleeps)" && echo 0 || echo 1)"
_until="$(python3 -c 'import sys
d=dict(kv.split("=",1) for kv in open(sys.argv[1]).read().split() if "=" in kv)
print(d.get("until",""))' "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
_at="$(python3 -c 'import sys
d=dict(kv.split("=",1) for kv in open(sys.argv[1]).read().split() if "=" in kv)
print(d.get("at",""))' "$GH_LIMIT_DIR/last-limit" 2>/dev/null)"
ck "unclassified: the recorded BLOCK WINDOW is at most the one-minute floor past the record [at=$_at until=$_until]" \
   "$([ -n "$_until" ] && [ -n "$_at" ] && [ "$(( _until - _at ))" -gt 0 ] && [ "$(( _until - _at ))" -le 80 ] && echo 0 || echo 1)"
ck "unclassified: the refusal line names kind, the marker's AGE, the remaining count and the attempt" \
   "$(grep -qE 'kind=unclassified.*FAILED after 4 attempt.*remaining=[0-9?].*marker_age=[0-9]+s' "$TMP/err-M3" && echo 0 || echo 1)"

# ⛔ M4. THE MEASURED STALE MARKER, AS IT WAS FOUND ON DISK: `status=? attempts=1 waited=0` with a reset
# ~43 min in the future and NO kind/until (written before this change). The gate must bound it to the
# unclassified window (~60s) and never to that reset — and it must say what it is waiting on.
reset_env legacy-marker
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=?\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_SCENARIO=probeempty run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "marker: a legacy status=? marker waits ~60s (its classification's window), NOT the 43-min reset" \
   "$(sleep_at_least 0 55 && sleep_below 0 90 && echo 0 || echo 1)"
ck "marker: … and the call still ran afterwards (a window is a wait, not a refusal)" \
   "$(has 'api graphql' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
ck "marker: the backoff line states its own evidence — kind, AGE, remaining, attempt" \
   "$(grep -qE 'kind=unclassified marker_age=[0-9]+s remaining=0 attempt=preflight' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)"

# ⛔ M4b. THE REFUSAL LINE'S "waited" MUST INCLUDE THE GATE'S PAUSE. `waited` is the number the final
# line reports as the time this call spent; a 60-300 s gate window that the layer honoured but did not
# count made that evidence wrong by exactly the wait it claims to have observed (measured: 499 s of
# sleeps reported as "439s waited"). ⛔ THE GATE MUST ACTUALLY PAUSE HERE: with the default 30 s
# revalidate threshold the probe answers 4999 and CLEARS the marker, so the asserted wait came entirely
# from the backoff curve and the assertion passed with the `waited +=` deleted (found in review).
# Raising the threshold makes the 60 s window payable, so `waited` is ~60 s larger than the backoff
# alone.
reset_env gate-waited
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=?\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_GATE_REVALIDATE_S=600 GH_LIMIT_SCENARIO=unclassified \
  run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>"$TMP/err-M4b" || true
_sum="$(python3 -c 'import sys
print(int(sum(float(x) for x in sys.argv[1].split())))' "$(sleeps)")"
_w="$(grep -oE '[0-9]+s waited' "$TMP/err-M4b" | grep -oE '[0-9]+')"
_gate="$(python3 -c 'import sys
v=[float(x) for x in sys.argv[1].split()]
print(v[0] if v else 0)' "$(sleeps)")"
ck "marker: the gate pause is PAID here, so the 'waited' assertion is not vacuous [gate=${_gate}s]" \
   "$(python3 -c 'import sys
sys.exit(0 if float(sys.argv[1]) >= 55 else 1)' "$_gate" && echo 0 || echo 1)"
ck "marker: the refusal's 'waited' counts the gate pause too (reported ${_w}s of ${_sum}s slept)" \
   "$([ -n "$_w" ] && [ "$_sum" -gt 400 ] && [ "$_w" -ge "$(( _sum - 8 ))" ] && echo 0 || echo 1)"

# ⛔ M5. REQUIREMENT 3: REVALIDATE BEFORE A LONG WAIT. One REST `rate_limit` read is unmetered, so a
# marker claiming a 43-minute window is checked against the bucket before it is paid. The bucket has
# 4573 left => the marker is STALE => it is annotated (age kept, because the age is the evidence) and
# the call proceeds with NO wait.
reset_env stale-marker
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
out="$(GH_LIMIT_SCENARIO=probehead run_helper api graphql -f query='{viewer{login}}' 2>&1)"; _rc=$?
ck "revalidate: a marker contradicted by the live bucket does NOT block (zero waits)" \
   "$([ "$_rc" -eq 0 ] && [ -z "$(sleeps)" ] && echo 0 || echo 1)"
ck "revalidate: … and the bucket was actually READ (one exempt /rate_limit request)" \
   "$(has 'api rate_limit' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
ck "revalidate: the decision is RECORDED, with the remaining count that decided it" \
   "$(grep -qE 'STALE graphql marker.*remaining=4573' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)"
ck "revalidate: the record keeps its AGE and gains stale= + reval_remaining= (annotated, not deleted)" \
   "$(has 'at=1700000000' "$(limit_record)" && has 'stale=' "$(limit_record)" && has 'reval_remaining=4573' "$(limit_record)" && echo 0 || echo 1)"
# ⛔ AND THE ANNOTATION ITSELF MUST NOT CLAIM `recovered=`. The cycle token prints
# `gh=recovered(…)` for that field, and the ONLY honest source of it is a real request that succeeded
# (`record_recovery`). The exempt `/rate_limit` read is measured to say 4999/5000 while every GraphQL
# call is refused, so deriving it from that probe would make a box that is still being refused report
# itself recovered. Driven at the FUNCTION level, because in a full run the call that follows a cleared
# marker legitimately succeeds and would write the field for the right reason.
reset_env stale-annotation
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_DIR="$GH_LIMIT_DIR" GH_LIMIT_NOW_CMD="cat $CLOCK" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.mark_marker_stale(4573, "remaining-gt-0")' "$HELPER"
_ann="$(limit_record)"
ck "revalidate: the annotation records stale= + reval_remaining= and does NOT claim recovered=" \
   "$(has 'stale=' "$_ann" && has 'reval_remaining=4573' "$_ann" && ! has 'recovered=' "$_ann" && has 'at=1700000000' "$_ann" && echo 0 || echo 1)"
# ⛔ AND IT MUST NOT ANNOTATE A RECORD IT DID NOT READ. `record_limit` writes `last-limit` outside the
# box lock, so a concurrent client can replace the file between this gate's read and its write; a
# blind `stale=` would then clear a FRESH genuine refusal's window (the gate suppresses on `stale=`
# for good) — a silent, permanent fail-open. Stale writes require matching identity (at+bucket+kind).
reset_env stale-identity
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
_marker_json="$(GH_LIMIT_DIR="$GH_LIMIT_DIR" GH_LIMIT_NOW_CMD="cat $CLOCK" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
# a DIFFERENT observation than the one on disk (another attempt), then the real one
print(m.mark_marker_stale(4573, "remaining-gt-0", expect={"at": "1699999000", "bucket": "graphql", "kind": "primary"}))' "$HELPER")"
ck "revalidate: a REPLACED record is not annotated stale= (fail-open closed) — the write was refused" \
   "$([ "$_marker_json" = "False" ] && ! has 'stale=' "$(limit_record)" && echo 0 || echo 1)"
GH_LIMIT_DIR="$GH_LIMIT_DIR" GH_LIMIT_NOW_CMD="cat $CLOCK" python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("gl", sys.argv[1])
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.mark_marker_stale(4573, "remaining-gt-0", expect={"at": "1700000000", "bucket": "graphql", "kind": "primary"}))' "$HELPER" >/dev/null
ck "revalidate: … while the SAME record (same at+bucket+kind) is annotated as before" \
   "$(has 'stale=' "$(limit_record)" && echo 0 || echo 1)"
# ⛔ AND THE STALE ANNOTATION MUST ACTUALLY STOP THE GATE. `read_marker` returns a DICT, so a
# membership test spelled `"stale=" in marker` checks KEYS and is always false — the suppressor was
# inert and an annotated marker still blocked (and re-probed). ⛔ THE MARKER IS WRITTEN BY HAND here,
# WITHOUT `recovered=`: after a real run the record carries BOTH, and the `recovered` check would
# short-circuit first, so the assertion would pin the other spelling and pass with the `stale` check
# deleted (found in review).
reset_env stale-suppressor
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0 stale=1700000001 reval_remaining=4573 why=remaining-gt-0\n' > "$GH_LIMIT_DIR/last-limit"
run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "revalidate: a marker already annotated stale= does not block and spends NO probe" \
   "$([ -z "$(sleeps)" ] && ! has 'api rate_limit' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
# ⛔ BUT A `retry-after` WINDOW IS NEVER CLEARED BY HEADROOM. That wait is the SERVER'S instruction,
# and the primary counter does not contradict it (secondary limits strike while it looks healthy —
# the reason `plan_wait` honours the header verbatim). Clearing it put every later client back inside
# a cool-down the layer was still obeying.
reset_env retryafter-marker
printf 'at=1700000000 bucket=graphql reset=1700003600 attempts=1 waited=0 status=403 kind=retry-after until=1700000200 remaining=45\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_SCENARIO=probehead run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "revalidate: primary headroom does NOT clear a retry-after window — the server's delay stands" \
   "$(sleep_at_least 0 195 && sleep_below 0 210 && ! has 'stale=' "$(limit_record)" && echo 0 || echo 1)"
# ⛔ AND A RECORD REPLACED MID-GATE IS NOT ANNOTATED *AND* IS NOT CLAIMED AS CLEARED. `record_limit`
# writes `last-limit` outside the box lock, so the stub replaces it during the probe — the case the
# identity guard exists for. Logging "cleared it" over a refused write put two contradictory
# decisions in `events.log` and named a record that was still in force.
reset_env replaced-under-gate
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_SCENARIO=probereplace run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "revalidate: a record REPLACED under the gate is left alone AND the log says so (no false 'cleared')" \
   "$(grep -q 'NOT annotated' "$GH_LIMIT_DIR/events.log" && ! grep -q 'cleared it and proceeding' "$GH_LIMIT_DIR/events.log" && ! has 'stale=' "$(limit_record)" && echo 0 || echo 1)"

# ⛔ M6. REQUIREMENT 5: NEVER BLOCK ON A MARKER OLDER THAN THE WINDOW IT RECORDED. A record written 10
# minutes ago whose own 60s window has long expired is a fact about the past, not a state — and no
# request may be spent revalidating it.
reset_env old-window
printf 'at=1699999600 bucket=graphql reset=1700002580 attempts=1 waited=0 status=?\n' > "$GH_LIMIT_DIR/last-limit"
run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "stale-age: a marker whose recorded window ENDED blocks nothing and spends no probe" \
   "$([ -z "$(sleeps)" ] && ! has 'api rate_limit' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"
ck "stale-age: … and events.log says the window had ended (the reading is explainable)" \
   "$(has 'window ended' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"
# …and the absolute age bound, for a marker whose window was recorded absurdly far ahead.
reset_env old-age
printf 'at=1699999000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "stale-age: a marker older than MARKER_MAX_AGE is ignored even with a future window (>900s)" \
   "$([ -z "$(sleeps)" ] && has 'IGNORED a graphql marker aged' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"

# ⛔ M7. THE OLD BEHAVIOUR STILL HOLDS. A GENUINELY exhausted bucket (remaining 0, reset inside the
# in-call bound) is still waited out exactly as GitHub documents, and the classification says primary.
reset_env nearreset
out="$(GH_LIMIT_SCENARIO=nearreset run_helper api repos/o/r 2>"$TMP/err-M7")"; _rc=$?
ck "primary: an exhausted bucket still waits for its reset (121s) and then SUCCEEDS" \
   "$([ "$_rc" -eq 0 ] && sleep_at_least 0 120 && sleep_below 0 130 && echo 0 || echo 1)"
ck "primary: … and the record classifies it as primary with the remaining it read" \
   "$(has 'kind=primary' "$(limit_record)" && echo 0 || echo 1)"

# ⛔ M8. NO_WAIT IS NEVER PARKED BY THE MARKER GATE. The bounded callers are the ones whose blindness
# produced the measured `queue_read=BLIND` line; parking them behind a marker would turn a rate-limit
# verdict into a timeout, which is the failure #2137's NO_WAIT half exists to prevent.
reset_env gate-nowait
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=?\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_NO_WAIT=1 run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "marker: a NO_WAIT caller is not parked by a fresh marker (it keeps its own bound)" \
   "$([ -z "$(sleeps)" ] && echo 0 || echo 1)"

# ⛔ M8b. A MARKER WHOSE WINDOW IS BEYOND THE IN-CALL BOUND MUST NOT BE SLEPT AND THEN IGNORED. Sleeping
# MAX_WAIT and sending anyway pays the caller's whole bound for a request the marker says is doomed;
# the gate declines instead, so the refusal itself (which fails fast in the normal path) is the
# cheaper evidence. Pre-fix this slept 300s.
reset_env gate-farwindow
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700002580 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
GH_LIMIT_SCENARIO=probeempty run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>&1
ck "marker: a marker 2580s away does not park the caller for MAX_WAIT and then send anyway" \
   "$([ -z "$(sleeps)" ] && has 'beyond the 300s in-call bound' "$(cat "$GH_LIMIT_DIR/events.log")" && echo 0 || echo 1)"

# ⛔ M9. THE GATE IS BUCKET-SCOPED. A graphql marker must not park a REST read: the two pools are
# separate, and the REST path is what keeps dispatch alive while GraphQL is refused (#1962/#1939).
# ⛔ AND THE FIXTURE CARRIES A LIVE WINDOW ON PURPOSE — the merge with the #2342 floor made the old
# fixture VACUOUS in one direction. With a marker whose window has ENDED (or one older than
# MARKER_MAX_AGE) the gate ignores it for reasons that have nothing to do with the bucket, so "no wait"
# would pass with the scoping deleted. A 120 s window inside the age bound is one the gate WOULD pay
# (or revalidate) for a `graphql` call, so the reads below can tell the two apart.
reset_env gate-bucket
printf 'at=1700000000 bucket=graphql reset=1700002580 attempts=1 waited=0 status=403 kind=primary until=1700000120 remaining=0\n' > "$GH_LIMIT_DIR/last-limit"
run_helper api repos/o/r/pulls/1 >/dev/null 2>&1
ck "marker: a GRAPHQL marker does not block a CORE call (the pools are separate, no wait incurred)" \
   "$([ -z "$(sleeps)" ] && echo 0 || echo 1)"
# ⛔ AND THE FOREIGN MARKER IS NEVER CONSULTED — pinned on the ARTIFACT, not on the request count. A
# consulted marker with a live window is REVALIDATED, and that annotation writes `stale=` onto the
# record: the artifact is the direct evidence, and it stays meaningful however the floor's own meter
# probe is admitted later.
ck "marker: … and the foreign marker is NOT annotated stale= (it was never consulted for a core decision)" \
   "$(grep -q 'stale=' "$GH_LIMIT_DIR/last-limit" && echo 1 || echo 0)"
# ⛔ THE PROBE COUNT IS BOUNDED AT ONE, NOT ZERO, AND THAT IS A DELIBERATE CHANGE OF THE ASSERTION.
# The #2342 floor spends ONE exempt `/rate_limit` read per box per TTL so that it can act on a MEASURED
# `remaining` at all (its own suite pins exactly that: gh-core-failover.test.sh (p)/(p2)); a core call
# with nothing local known about `core` is exactly where it fires. A marker REVALIDATION is a different
# request on the same endpoint, so a SECOND meter read is the signature of a bucket leak — which is what
# this assertion is for.
ck "marker: … and only the FLOOR's own single exempt meter read was spent [meter=$(meter_calls)]" \
   "$([ "$(meter_calls)" -le 1 ] && echo 0 || echo 1)"

# ⛔ M10. A STAMP FROM THE FUTURE IS NOT PERMISSION TO REFUSE EVERY CALL. A clock that stepped back
# leaves `budget-<bucket>` entries ahead of `now`; honouring them made `next slot` hours away and
# refused EVERY graphql call with rc 75 until wall-clock caught up — the `last-mutation` future-stamp
# class, in the new file. Future stamps are DROPPED.
reset_env future-budget
mkdir -p "$GH_LIMIT_DIR"
for _i in $(seq 1 20); do printf '%s\n' "$(( 1700000000 + 3600 ))"; done > "$GH_LIMIT_DIR/budget-graphql"
out="$(run_helper api graphql -f query='{viewer{login}}' 2>"$TMP/err-M10")"; _rc=$?
ck "account: a budget file stamped in the FUTURE does not refuse every call (rc=0, no wait)" \
   "$([ "$_rc" -eq 0 ] && [ -z "$(sleeps)" ] && echo 0 || echo 1)"

# ⛔ M11. A BUDGET REFUSAL IS RECORDED WHERE IT CAN BE SEEN, BUT NOT AS GITHUB'S. `last-limit` is what
# the heartbeat prints as `gh=rate_limited(...)`, so a LOCAL partition refusal written there would be
# a false attribution; it gets its own file, and its text avoids the phrase objective.py maps to
# GH-RATE-LIMITED.
reset_env budget-record
# A 600 s window with a 1-call/min share (120/hr across a 2-box fleet) caps at 10 slots; filling it
# puts the next slot 600 s away, past the 300 s in-call bound => the fail-fast branch.
for _i in $(seq 1 10); do printf '%s\n' 1700000000; done > "$GH_LIMIT_DIR/budget-graphql"
GH_LIMIT_ACCOUNT_WINDOW_S=600 GH_LIMIT_ACCOUNT_FLEET_SIZE=2 GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR=120 \
  GH_LIMIT_ACCOUNT_SAFETY=1.0 run_helper api graphql -f query='{viewer{login}}' >/dev/null 2>"$TMP/err-M11"; _rc=$?
ck "account: a budget refusal RECORDS itself (next slot + the share it enforced) in last-budget" \
   "$(has 'next_slot=' "$(cat "$GH_LIMIT_DIR/last-budget" 2>/dev/null)" && has 'fleet=' "$(cat "$GH_LIMIT_DIR/last-budget" 2>/dev/null)" && echo 0 || echo 1)"
ck "account: … and it is NOT written to last-limit (a local refusal is not GitHub's rate limit)" \
   "$(! has 'bucket=graphql' "$(limit_record)" && ! has 'rate limit' "$(cat "$TMP/err-M11")" && echo 0 || echo 1)"
# ⛔ AND IT ACTUALLY REFUSES. The record alone is not the decision: with the `return 75` removed (or
# turned into 0) a locally-refused call was still SENT — the refusal's own record and the caller's
# SUCCESS agreed with each other while the partition was defeated (found in review; both assertions
# above stayed green). The exit code is the contract the caller reads, and no request may leave.
ck "account: the budget fail-fast exits 75 and sends NOTHING (the refusal is real, not just recorded)" \
   "$([ "$_rc" -eq 75 ] && ! has 'api graphql' "$(cat "$STUB_LOG")" && echo 0 || echo 1)"

echo
printf 'gh-limit: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
