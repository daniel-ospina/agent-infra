#!/usr/bin/env bash
# gh-gate.test.sh — agent-infra#1910, the LOOP/READ/INSTRUMENT half of the gh courtesy gate.
#
# The defect this suite pins is *not* the point budget. Measured 2026-10-18:
#
#     graphql 4690/5000 remaining, core 812/5000 remaining
#     gh api user                       -> succeeded in 1 s
#     the fleet's parallel reads        -> "API rate limit already exceeded for user ID 81560491"
#     13 concurrent gh clients, 54 pi lanes, 4 rail-when-green landers, 2 merge loops
#
# So `gh api rate_limit` showing headroom is a FALSE GREEN, and the refusal is the SECONDARY
# (concurrency) limit. Three behaviours follow, and each has a §:
#
#   §1-§2  INSTRUMENT — the verdict comes from a REAL read attempt, and it is named
#          `SECONDARY-LIMITED`, a term distinct from `BUDGET-EXHAUSTED` and from `UNREADABLE`.
#          A refusal must never be reported as an empty backlog or a healthy queue, and the
#          exempt `/rate_limit` counter is never consulted for the verdict (it cannot see this
#          limit at all).
#   §3     LOOP — N concurrent landers each running a gh read produce ONE request in flight at a
#          time (measured from the stub's OWN timestamps, so a lock that only *labels* itself
#          cannot pass), and every one of them reports `SECONDARY-LIMITED` — never `OK`, never
#          `UNREADABLE`, never an empty answer.
#   §4     READ — lanes read the PUBLISHED refresh snapshot instead of each calling the API (the
#          gh invocation count does not grow with the lane count), and a snapshot past its age
#          bound is labelled `STALE(...)`: a stale read can never pass as a fresh one.
#   §5     LEASE LIVENESS — the holder's pid AND its process start token are checked, so a lease
#          left by a killed lander is broken (loudly) instead of parking the box forever, while a
#          LIVE holder is respected. An over-age lease is broken too: one slow lander must not
#          stop the fleet (the same declared residual gh-limit.py's lock timeout carries).
#
# Hermetic: a stub `gh` (via GH_GATE_REAL_GH, never PATH) serves every call and records the argv,
# and every state directory is under $TMP. No network, no real credentials, no clock dependence
# beyond the stub's own start/end stamps.
#
#   bash scripts/orchestrator-harness/gh-gate.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/orchestrator-harness/gh-gate.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-gate-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "   ❌ $1"; }

now_us() { python3 -c 'import time;print(int(time.time()*1000000))'; }

# ── the stub `gh` ────────────────────────────────────────────────────────────────────────────
# It records `S <us>` before it does anything and `E <us>` after it answers, and it HOLDS the call
# open for STUB_MS so an overlapping second call is visible in the log rather than a same-millisecond
# coincidence. The scenario is read from a file at call time, so one stub serves every section.
STUB="$TMP/gh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
SCEN="${GH_GATE_SCEN:?}"
printf 'S %s\n' "$(python3 -c 'import time;print(int(time.time()*1000000))')" >> "$SCEN/calls.log"
printf 'ARGV %s\n' "$*" >> "$SCEN/calls.log"
sleep "${STUB_MS:-0.15}"
mode="$(cat "$SCEN/mode" 2>/dev/null || echo secondary)"
# ⛔ THE TWO POOLS CAN DISAGREE, AND THE STUB MUST BE ABLE TO SAY SO. #1959 is the measured
# incident where GraphQL was refused for minutes while REST answered normally — with a single
# global mode both reads answered identically, so a mutation republishing the GraphQL refusal as
# the REST verdict (the over-deferral this PR exists to prevent) stayed green 3/3.
case "$mode" in
  split-gql-bad)   # GraphQL refused, REST healthy — the #1959 shape
    case "$*" in *graphql*) mode=secondary ;; *) mode=ok ;; esac ;;
  split-rest-bad)  # REST refused, GraphQL healthy — the mirror image
    case "$*" in *" user") mode=budget ;; *) mode=ok ;; esac ;;
esac
case "$mode" in
  ok)
    # A real 200: headers, then the GraphQL body. The probe must read this as OK.
    printf 'HTTP/2.0 200 OK\nx-ratelimit-remaining: 4690\nx-ratelimit-reset: %s\n\n{"data":{"viewer":{"login":"stub"}}}\n' "$(( $(date +%s) + 900 ))"; rc=0 ;;
  secondary)
    # ⛔ THE MEASURED REFUSAL, verbatim — and the counter it disagrees with. `remaining` is
    # deliberately HEALTHY (4690) because that is exactly what the fleet saw while every read was
    # refused: a verdict derived from this number would say OK.
    printf 'HTTP/2.0 403 Forbidden\nx-ratelimit-remaining: 4690\nx-ratelimit-reset: %s\n\n' "$(( $(date +%s) + 900 ))"
    echo 'API rate limit already exceeded for user ID 81560491' >&2; rc=1 ;;
  budget)
    # The PRIMARY limit: the counter is genuinely empty and the message is GitHub's primary one.
    printf 'HTTP/2.0 403 Forbidden\nx-ratelimit-remaining: 0\nx-ratelimit-reset: %s\n\n' "$(( $(date +%s) + 600 ))"
    echo 'API rate limit exceeded for user ID 81560491 (https://api.github.com/rate_limit)' >&2; rc=1 ;;
  secondary429)
    # GitHub documents the secondary limit as 403 OR 429, and `retry-after` is the canonical
    # "do not retry before N" header. A probe that only speaks phrase-matching reports this as
    # UNREADABLE ("not a rate limit"), sending the operator to the token during pure burstiness.
    printf 'HTTP/2.0 429 Too Many Requests\nretry-after: 60\nx-ratelimit-remaining: 4690\n\n'
    rc=1 ;;
  ok-errors)
    # ⛔ THE FALSE GREEN gh ITSELF PRODUCES. GitHub answers a GraphQL rate limit with HTTP 200 and
    # an `errors[type:RATE_LIMIT]` body (measured on this account; a cached introspection body can
    # be replayed for 24 h). rc is 0, so a probe that trusts the exit code publishes `state=OK`
    # over a fleet that cannot read — the instrument emitting the very false green it exists to
    # remove.
    printf 'HTTP/2.0 200 OK\nx-ratelimit-remaining: 4690\n\n{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 81560491"}],"data":null}\n'
    rc=0 ;;
  secondary429nr)
    # The 429 ARM ALONE: no `retry-after`, no phrase. §1(f) carries BOTH a 429 and a retry-after,
    # so either arm satisfied it and neither was individually pinned (a mutation deleting the 429
    # arm stayed green).
    printf 'HTTP/2.0 429 Too Many Requests\nx-ratelimit-remaining: 4690\n\n'
    rc=1 ;;
  retry403)
    # The `retry-after` ARM ALONE: a 403 with no phrase in the body.
    printf 'HTTP/2.0 403 Forbidden\nretry-after: 60\nx-ratelimit-remaining: 4690\n\n'
    rc=1 ;;
  budgetnohdr)
    # The PRIMARY-PHRASE ARM ALONE: no headers at all, so no `remaining` hard fact to short-circuit.
    echo 'API rate limit exceeded for user ID 81560491 (https://api.github.com/rate_limit)' >&2
    rc=1 ;;
  gateway)
    # ⛔ A PHRASE IN THE WRONG RESPONSE IS NOT A LIMIT (the rule gh-limit.py:931 encodes after
    # measuring a 422 whose body echoed a PR title containing "rate limit"). A 502 error page must
    # be UNREADABLE — the remedy is "GitHub is down", not "stop arriving together".
    printf 'HTTP/2.0 502 Bad Gateway\nx-ratelimit-remaining: 4000\n\n<html>upstream rate limit</html>\n'
    rc=1 ;;
  hang)
    # The error ARM: a black-holed connection. The probe must return UNREADABLE inside its own
    # timeout, not block the controller's pass.
    sleep 5; rc=1 ;;
  ok-html)
    # rc=0 with no parseable body. "I could not find a JSON body" is not "the body was clean", so
    # this must NOT publish state=OK — the arm exists because an entry point that re-renders the
    # response would otherwise silently restore the false green.
    printf 'HTTP/2.0 200 OK\n\n<html><body>upstream ok</body></html>\n'
    rc=0 ;;
  authfail)
    # NOT a limit: an expired/absent credential. Classifying this as a rate limit would defer a
    # misconfigured box for hours and report the opposite of what stderr says.
    echo 'gh: To get started with GitHub CLI, please run:  gh auth login' >&2; rc=1 ;;
  *) echo "stub: unknown mode $mode" >&2; rc=9 ;;
esac
printf 'E %s\n' "$(python3 -c 'import time;print(int(time.time()*1000000))')" >> "$SCEN/calls.log"
exit "$rc"
STUBEOF
chmod +x "$STUB"

# ── the gate, always pointed at THIS section's state dir and THIS stub ───────────────────────
# ⛔ GH_GATE_REAL_GH, not PATH: a PATH lookup would find the box's real `gh` (or the seeded shim
# over it) and the suite would then read live GitHub state instead of the fixture — the
# silently-pass-for-the-wrong-reason failure #1988's suite documents.
scen() { # scen <name> -> echoes the fresh scenario dir
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d"
  printf 'secondary\n' > "$d/mode"
  printf '%s' "$d"
}
# O pins `_adapter_present()`, which decides WHICH pool the probe reads first. Without it the suite
# would read this box's own ~/orchestrator deployment and the primary path would depend on the
# machine the suite happens to run on.
gate() { # gate <scen-dir> <argv…>
  local d="$1"; shift
  GH_GATE_DIR="$d/state" GH_GATE_REAL_GH="${GATE_GH:-$STUB}" GH_GATE_SCEN="$d" O="${GATE_O:-$d/no-adapter}" \
    python3 "$GATE" "$@"
}
calls() { grep -c '^ARGV ' "$1/calls.log" 2>/dev/null || true; }
# max_inflight <calls.log> -> the largest number of stub calls that were open at the same time.
# Computed from the stub's own S/E stamps: +1 on S, -1 on E, in time order.
max_inflight() {
  awk '
    $1 == "S" { print $2, "+1" }
    $1 == "E" { print $2, "-1" }
  ' "$1" | sort -k1,1n -k2,2 | awk '
    { n += $2; if (n > max) max = n }
    END { print (max == "" ? 0 : max) }'
}

# ═══ §1 INSTRUMENT — the verdict is a REAL read, named in one of four terms ══════════════════
echo "§1 instrument: a real read attempt, and the refusal it reports"
D="$(scen s1)"
# 1(a) THE MEASURED CASE. `x-ratelimit-remaining: 4690` and yet the read is refused: the ONLY
# correct verdict is SECONDARY-LIMITED. A gate that prints OK here is the false green itself.
out="$(gate "$D" probe --publish 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'SECONDARY-LIMITED' <<<"$out"; then
  pass "1(a) a healthy counter + a refused read -> SECONDARY-LIMITED"
else
  fail "1(a) expected SECONDARY-LIMITED from a refused read with healthy remaining (rc=$rc): $out"
fi
# 1(b) …and it is NOT reported as any of the three ways a refusal can be laundered into an answer.
if grep -q 'SECONDARY-LIMITED' <<<"$out" && ! grep -qE 'GH-PROBE: (OK|UNREADABLE|EMPTY)' <<<"$out"; then
  pass "1(b) never reported as OK / UNREADABLE / EMPTY"
else
  fail "1(b) the secondary refusal was reported as something other than SECONDARY-LIMITED: $out"
fi
# 1(c) BUDGET-EXHAUSTED is a DIFFERENT verdict: remaining:0 and GitHub's primary message.
D="$(scen s1-budget)"; printf 'budget\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
if grep -q 'BUDGET-EXHAUSTED' <<<"$out" && ! grep -q 'SECONDARY-LIMITED' <<<"$out"; then
  pass "1(c) remaining:0 + the primary message -> BUDGET-EXHAUSTED (not SECONDARY-LIMITED)"
else
  fail "1(c) expected BUDGET-EXHAUSTED alone, got: $out"
fi
# 1(d) A credential failure is NOT a rate limit. Naming it one defers a misconfigured box for
# hours and tells the operator to look at GitHub's status instead of their token.
D="$(scen s1-auth)"; printf 'authfail\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
if grep -q 'UNREADABLE' <<<"$out" && ! grep -qE 'SECONDARY-LIMITED|BUDGET-EXHAUSTED' <<<"$out"; then
  pass "1(d) an auth failure -> UNREADABLE (never a rate limit)"
else
  fail "1(d) expected UNREADABLE for an auth failure, got: $out"
fi
# 1(e) A successful read is OK — the honest green, and the only one.
D="$(scen s1-ok)"; printf 'ok\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
if [ $? -eq 0 ] && grep -q 'GH-PROBE: OK' <<<"$out"; then
  pass "1(e) a read that succeeds -> OK"
else
  fail "1(e) expected OK for a successful read, got: $out"
fi

# 1(f) A 429 with `retry-after` and healthy remaining is BURSTINESS, not an unknown failure.
D="$(scen s1-429)"; printf 'secondary429\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
if grep -q 'SECONDARY-LIMITED' <<<"$out" && ! grep -q 'UNREADABLE' <<<"$out"; then
  pass "1(f) HTTP 429 + retry-after + headroom -> SECONDARY-LIMITED (not UNREADABLE)"
else
  fail "1(f) a 429 burst refusal was misnamed: $out"
fi
# 1(g) …AND THE HARDEST ONE: rc=0 with a GraphQL rate-limit body. Exit 0 is not a read.
D="$(scen s1-okerrors)"; printf 'ok-errors\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"; rc=$?
if ! grep -q 'GH-PROBE: OK' <<<"$out" && grep -q 'SECONDARY-LIMITED' <<<"$out" && [ "$rc" -ne 0 ]; then
  pass "1(g) HTTP 200 + errors[type=RATE_LIMIT] (rc=0) is NOT OK — the body decides"
else
  fail "1(g) a GraphQL rate-limit body with rc=0 was accepted as OK (rc=$rc): $out"
fi

# 1(h)-(k) EACH CLASSIFICATION ARM PINNED SEPARATELY. Round 1's lesson was "a mutation that deleted
# a guard stayed green"; the same standard applies to the arms that decide BUDGET vs SECONDARY, the
# distinction whose whole point is that a burst refusal is never sent to "wait for the reset".
D="$(scen s1-429nr)"; printf 'secondary429nr\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
grep -q 'SECONDARY-LIMITED' <<<"$out" && pass "1(h) HTTP 429 with NO retry-after and no phrase -> SECONDARY-LIMITED (the status arm)" \
  || fail "1(h) a bare 429 was not named a secondary limit: $out"
D="$(scen s1-retry403)"; printf 'retry403\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
grep -q 'SECONDARY-LIMITED' <<<"$out" && pass "1(i) 403 + retry-after and no phrase -> SECONDARY-LIMITED (the retry-after arm)" \
  || fail "1(i) a 403 with retry-after was not named a secondary limit: $out"
D="$(scen s1-budgetnohdr)"; printf 'budgetnohdr\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
grep -q 'BUDGET-EXHAUSTED' <<<"$out" && ! grep -q 'SECONDARY-LIMITED' <<<"$out" \
  && pass "1(j) the PRIMARY wording with no rate-limit header -> BUDGET-EXHAUSTED (the primary arm)" \
  || fail "1(j) a header-less primary refusal was misnamed: $out"
D="$(scen s1-gateway)"; printf 'gateway\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"
grep -q 'UNREADABLE' <<<"$out" && ! grep -qE 'SECONDARY-LIMITED|BUDGET-EXHAUSTED' <<<"$out" \
  && pass "1(k) a 502 page that merely MENTIONS rate limit -> UNREADABLE (a phrase is not a limit)" \
  || fail "1(k) a 5xx error page was reported as a rate limit: $out"

# ═══ §2 the exempt counter is never the evidence ═════════════════════════════════════════════
# `GET /rate_limit` is EXEMPT from the primary limit, so it answers on a box where every real call
# is refused. Using it as the probe is what produced `graphql 4690/5000` over a fleet that could not
# read. The probe must therefore issue a REAL read and must not consult it at all.
D="$(scen s2)"; printf 'secondary\n' > "$D/mode"
gate "$D" probe --publish >/dev/null 2>&1 || true
if [ "$(calls "$D")" -ge 1 ] && ! grep -q 'rate_limit' "$D/calls.log"; then
  pass "2(a) the probe issues a real read ($(calls "$D") call(s)) and never /rate_limit"
else
  fail "2(a) the probe consulted /rate_limit or issued no call at all: $(cat "$D/calls.log" 2>/dev/null)"
fi

# ═══ §3 LOOP — N concurrent landers serialise on the lease ═══════════════════════════════════
# This is the acceptance the issue states: a burst of N parallel lanes must not produce N
# concurrent requests. Each lane takes the box's gh lease, does its read, releases it.
D="$(scen s3)"; printf 'secondary\n' > "$D/mode"
N=5
for i in $(seq 1 "$N"); do
  (
    out="$(gate "$D" lease acquire --name "lane-$i" --pid $$ --stagger 0.4 --wait 60 2>&1)"
    case "$out" in
      ACQUIRED*) tok="$(sed -n 's/.*token=\([^ ]*\).*/\1/p' <<<"$out")"
                 gate "$D" probe --publish > "$D/probe-$i.out" 2>&1
                 gate "$D" lease release --token "$tok" > "$D/release-$i.out" 2>&1 ;;
      *)         printf '%s\n' "$out" > "$D/busy-$i.out" ;;
    esac
  ) &
done
wait
mi="$(max_inflight "$D/calls.log")"
if [ "$mi" = "1" ]; then
  pass "3(a) at most ONE gh read in flight across $N concurrent lanes (measured max=$mi)"
else
  fail "3(a) $N concurrent lanes overlapped: max in-flight=$mi (the lease did not serialise them)"
fi
if [ -z "$(ls "$D"/busy-*.out 2>/dev/null)" ]; then
  pass "3(b) every lane got its turn (no lane was refused the lease)"
else
  fail "3(b) a lane could not acquire the lease: $(cat "$D"/busy-*.out 2>/dev/null)"
fi
got=0
for i in $(seq 1 "$N"); do
  grep -q 'SECONDARY-LIMITED' "$D/probe-$i.out" 2>/dev/null && got=$((got + 1))
done
if [ "$got" = "$N" ]; then
  pass "3(c) every one of the $N lanes reports SECONDARY-LIMITED"
else
  fail "3(c) only $got/$N lanes reported SECONDARY-LIMITED: $(cat "$D"/probe-*.out 2>/dev/null)"
fi
# ⛔ TWO READS PER REFUSED LANE, NOT ONE — and that is deliberate (review round 2, P1): a GraphQL
# refusal is confirmed with ONE REST read, because REST and GraphQL are separate pools and #1959 is
# the measured incident where GraphQL was refused while REST answered. Publishing a GraphQL-only
# refusal as the fleet's state made every REST lander defer for the whole outage. The bound is what
# matters: no lane issues a THIRD read, i.e. no retry storm.
if [ "$(calls "$D")" = "$(( N * 2 ))" ]; then
  pass "3(d) exactly one read per lane per path ($(( N * 2 )) for $N refused lanes) — no retry storm"
else
  fail "3(d) expected $(( N * 2 )) reads ($N lanes x graphql+rest), got $(calls "$D")"
fi

# ═══ §4 READ — lanes share the PUBLISHED snapshot; a stale one is labelled stale ═════════════
# 4(a) the publishing pass makes the read ONCE; N readers cost ZERO gh calls.
D="$(scen s4)"; printf 'secondary\n' > "$D/mode"
gate "$D" probe --publish >/dev/null 2>&1 || true
before="$(calls "$D")"
reads=""
for i in $(seq 1 "$N"); do reads="$reads$(gate "$D" snapshot read 2>&1)"$'\n'; done
after="$(calls "$D")"
if [ "$before" -ge 1 ] && [ "$after" = "$before" ]; then
  pass "4(a) $N snapshot reads issued no gh call (shared read, not $N API calls)"
else
  fail "4(a) the publishing pass made $before read(s) and the $N snapshot reads made $((after - before)) more"
fi
if grep -q 'FRESH(SECONDARY-LIMITED' <<<"$reads"; then
  pass "4(b) a fresh snapshot carries the verdict and its age: FRESH(SECONDARY-LIMITED, …)"
else
  fail "4(b) a fresh snapshot did not read FRESH(SECONDARY-LIMITED, …): $reads"
fi
# 4(c) STALENESS. Backdate the snapshot past the bound: it must say STALE, never FRESH.
python3 - "$D/state/snapshot" <<'PY'
import sys, time
p = sys.argv[1]
lines = open(p).read().split()
out = []
for kv in lines:
    if kv.startswith("at="):
        kv = "at=%d" % (int(time.time()) - 7200)
    out.append(kv)
open(p, "w").write(" ".join(out) + "\n")
PY
out="$(gate "$D" snapshot read 2>&1)"
if grep -q 'STALE(' <<<"$out" && ! grep -q 'FRESH(' <<<"$out"; then
  pass "4(c) a snapshot past its age bound is labelled STALE, never FRESH: $out"
else
  fail "4(c) a stale snapshot was not labelled STALE: $out"
fi
# 4(d) …and a caller that must not read a stale snapshot is REFUSED (exit 3), so "use the shared
# read" can never silently become "use a two-hour-old answer".
# ⛔ THE FLAG MUST BE THE DIFFERENCE. Asserting only "rc=3 with --require-fresh" passed while the
# flag was inert (the flag-less path returned 3 too), so a strict-mode affordance that never worked
# shipped green. Both exit codes are compared here.
plain_out="$(gate "$D" snapshot read 2>&1)"; plain_rc=$?
strict_out="$(gate "$D" snapshot read --require-fresh 2>&1)"; strict_rc=$?
if [ "$plain_rc" -eq 0 ] && grep -q 'STALE(' <<<"$plain_out" \
   && [ "$strict_rc" -eq 3 ] && grep -q 'STALE(' <<<"$strict_out"; then
  pass "4(d) a stale reading is PRINTED (exit 0) and REFUSED only under --require-fresh (exit 3)"
else
  fail "4(d) --require-fresh is not what refuses a stale snapshot (plain rc=$plain_rc, strict rc=$strict_rc): $plain_out / $strict_out"
fi
# 4(e) ABSENCE IS NOT FRESHNESS. No snapshot at all reads UNKNOWN and --require-fresh refuses it.
D="$(scen s4-none)"
out="$(gate "$D" snapshot read 2>&1)"; rc=$?
if grep -q 'UNKNOWN' <<<"$out" && ! grep -q 'FRESH(' <<<"$out" && [ "$rc" -ne 0 ]; then
  pass "4(e) an absent snapshot reads UNKNOWN (exit $rc), never FRESH"
else
  fail "4(e) an absent snapshot read as '$out' (rc=$rc) — absence is not freshness"
fi

# 4(f) THE LANDER PREDICATE. This is the only thing in the change that can stop every landing on a
# box, so it is tested rather than left to a bash `case` inside merge-one.sh. A refusal on the
# lander's OWN path defers; a refusal on the OTHER path does not (that is the #1959 state the REST
# adapter exists for); a stale reading never does.
D="$(scen s4-lander)"; mkdir -p "$D/state"
printf 'state=SECONDARY-LIMITED rest=OK at=%d remaining=4690 bucket=graphql\n' "$(date +%s)" > "$D/state/snapshot"
out="$(gate "$D" lander-check --transport rest 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'PROCEED' <<<"$out" \
  && pass "4(f) a GraphQL-only refusal does NOT defer a REST lander (the adapter's whole purpose): $out" \
  || fail "4(f) a GraphQL refusal deferred a REST lander (rc=$rc): $out"
out="$(gate "$D" lander-check --transport graphql 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'DEFER(' <<<"$out" \
  && pass "4(f2) the same snapshot DOES defer a GraphQL lander: $out" \
  || fail "4(f2) a GraphQL lander was not deferred by a GraphQL refusal (rc=$rc): $out"
printf 'state=SECONDARY-LIMITED rest=SECONDARY-LIMITED at=%d remaining=4690 bucket=graphql\n' "$(( $(date +%s) - 7200 ))" > "$D/state/snapshot"
out="$(gate "$D" lander-check --transport rest 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'PROCEED' <<<"$out" \
  && pass "4(f3) a STALE refusal never defers a landing (an old reading is not evidence about now)" \
  || fail "4(f3) a stale snapshot deferred a landing (rc=$rc): $out"

# 4(f4) ⛔ THE DANGEROUS ARM: a NON-LIMIT failure must never defer. `UNREADABLE` means auth, a
# network fault or a 5xx — the docs are explicit that this is "chase the cause", NOT "wait an hour",
# and a 5xx burst would otherwise park every landing on the box. No case covered it, so
# `if verdict in (SECONDARY, BUDGET)` -> `if verdict != OK:` (defer on UNREADABLE) left the suite
# green: the one arm that can stop EVERY landing was unpinned in the direction that matters.
D="$(scen s4-unreadable)"; mkdir -p "$D/state"
printf 'state=UNREADABLE rest=UNREADABLE at=%d remaining=? bucket=graphql detail=auth_failed reset=?\n' \
  "$(date +%s)" > "$D/state/snapshot"
for _t in graphql rest; do
  out="$(gate "$D" lander-check --transport "$_t" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && grep -q 'PROCEED' <<<"$out" \
    && pass "4(f4) UNREADABLE never defers a $_t lander (a non-limit failure is not 'wait an hour')" \
    || fail "4(f4) an UNREADABLE reading deferred a $_t lander (rc=$rc): $out"
done

# 4(g) THE PRODUCER SIDE, END TO END. The consumer (§4(f)) can be pinned with a hand-written
# snapshot; the thing that FEEDS it cannot — and a one-token regression here (publishing the
# GraphQL refusal as the REST verdict) reinstates the over-deferral #1959 caused while every
# consumer check stays green. No adapter on this scenario, so the PRIMARY read is GraphQL.
D="$(scen s4-split)"; printf 'split-gql-bad\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"; rc=$?
pub="$(cat "$D/state/snapshot" 2>/dev/null)"
if [ "$rc" -ne 0 ] && grep -q 'state=SECONDARY-LIMITED' <<<"$pub" && grep -q 'rest=OK' <<<"$pub"; then
  pass "4(g) GraphQL refused + REST healthy publishes state=SECONDARY-LIMITED rest=OK (both pools named)"
else
  fail "4(g) the two pools were not reported separately (rc=$rc): $pub"
fi
out="$(gate "$D" lander-check --transport rest 2>&1)"
grep -q 'PROCEED' <<<"$out" && pass "4(g2) …and a REST lander PROCEEDs on that publication" \
  || fail "4(g2) a REST lander was deferred by a GraphQL-only refusal: $out"
# 4(h) THE MIRROR: with the adapter installed the landers read REST, so REST is the PRIMARY read.
D="$(scen s4-adapter)"; printf 'split-rest-bad\n' > "$D/mode"; mkdir -p "$D/box/gh-rest"
GATE_O="$D/box" gate "$D" probe --publish >/dev/null 2>&1 || true
pub="$(cat "$D/state/snapshot" 2>/dev/null)"
if grep -q 'rest=BUDGET-EXHAUSTED' <<<"$pub"; then
  pass "4(h) on an ADAPTER box the REST pool is measured first and published (rest=BUDGET-EXHAUSTED)"
else
  fail "4(h) the adapter box's own read path was not measured: $pub"
fi
out="$(GATE_O="$D/box" gate "$D" lander-check --transport rest 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'DEFER(' <<<"$out" \
  && pass "4(h2) …and a REST lander is deferred by a REFUSED REST pool" \
  || fail "4(h2) a refused REST pool did not defer a REST lander (rc=$rc): $out"

# 4(i) THE HEALTHY ADAPTER PATH. The probe measures REST and marks GraphQL `?`; if `?` is not a
# legal value, BOTH consumers call the snapshot corrupt and the box loses its instrument exactly
# when it is working (reproduced: `state=? rest=OK` -> UNKNOWN(snapshot is unparseable) on
# `snapshot read`, `--require-fresh`, and `cycle`). This is the check whose ABSENCE let a
# healthy-path regression through three review rounds: §4(h) only ever ran the REFUSED case.
D="$(scen s4-adapter-ok)"; printf 'ok\n' > "$D/mode"; mkdir -p "$D/box/gh-rest"
GATE_O="$D/box" gate "$D" probe --publish >/dev/null 2>&1 || true
out="$(GATE_O="$D/box" gate "$D" snapshot read 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^FRESH(' <<<"$out" \
  && pass "4(i) a HEALTHY adapter-box publication reads back FRESH (state=? rest=OK is not corrupt)" \
  || fail "4(i) the healthy adapter path published a snapshot its own reader rejected (rc=$rc): $out"
out="$(GATE_O="$D/box" gate "$D" snapshot read --require-fresh 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "4(i2) …and --require-fresh accepts it" \
  || fail "4(i2) --require-fresh refused a fresh, healthy adapter publication (rc=$rc): $out"
out="$(GATE_O="$D/box" gate "$D" cycle 2>&1)"
[ "$(grep -c . <<<"$out")" -eq 1 ] && grep -q '^FRESH(' <<<"$out" \
  && pass "4(i3) …and the cycle line reports it (one line, no UNKNOWN(unparseable))" \
  || fail "4(i3) the healthy adapter cycle line was not a single FRESH token: $out"
out="$(GATE_O="$D/box" gate "$D" lander-check --transport rest 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'PROCEED' <<<"$out" \
  && pass "4(i4) …and a REST lander PROCEEDs" || fail "4(i4) healthy adapter box did not PROCEED: $out"
out="$(GATE_O="$D/box" gate "$D" lander-check --transport graphql 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -qi 'UNMEASURED' <<<"$out" \
  && pass "4(i5) …while an unmeasured pool says UNMEASURED by name, not 'unparseable'" \
  || fail "4(i5) an unmeasured pool was not named (rc=$rc): $out"

# 4(j) THE COST GUARANTEE: a healthy pass is EXACTLY ONE call. Claimed in the PR body, both docs
# and the docstring — and until now nothing measured it (`2(a)` only asserted `>= 1`), so
# confirming unconditionally would have doubled every healthy pass on every box with 38/38 green.
calls_n() { grep -c '^ARGV ' "$1/calls.log" 2>/dev/null || echo 0; }
D="$(scen s4-cost)"; printf 'ok\n' > "$D/mode"
gate "$D" probe >/dev/null 2>&1 || true
n="$(calls_n "$D")"
[ "${n:-0}" -eq 1 ] && pass "4(j) a HEALTHY GraphQL probe costs exactly 1 call (got ${n:-0})" \
  || fail "4(j) a healthy probe cost ${n:-0} calls, expected exactly 1"
D="$(scen s4-cost-adapter)"; printf 'ok\n' > "$D/mode"; mkdir -p "$D/box/gh-rest"
GATE_O="$D/box" gate "$D" probe >/dev/null 2>&1 || true
n="$(calls_n "$D")"
[ "${n:-0}" -eq 1 ] && pass "4(j2) a HEALTHY adapter-box probe costs exactly 1 call (got ${n:-0})" \
  || fail "4(j2) a healthy adapter probe cost ${n:-0} calls, expected exactly 1"
D="$(scen s4-cost-bad)"; printf 'secondary\n' > "$D/mode"
gate "$D" probe >/dev/null 2>&1 || true
n="$(calls_n "$D")"
[ "${n:-0}" -eq 2 ] && pass "4(j3) a REFUSED probe costs 2 (the cross-pool confirmation, and only then)" \
  || fail "4(j3) a refused probe cost ${n:-0} calls, expected 2"

# ═══ §5 the lease is LIVENESS-CHECKED, and it cannot park the box ════════════════════════════
D="$(scen s5)"
# 5(a) A LIVE holder is respected: a second lander is told BUSY and does not steal the lease.
gate "$D" lease acquire --name holder-alive --pid $$ > "$D/live.out" 2>&1
tok="$(sed -n 's/.*token=\([^ ]*\).*/\1/p' "$D/live.out")"
out="$(gate "$D" lease acquire --name waiter --wait 0 2>&1)"; rc=$?
if [ "$rc" -eq 75 ] && grep -q 'BUSY' <<<"$out"; then
  pass "5(a) a live holder is respected: a second lander exits 75 BUSY"
else
  fail "5(a) a second lander was not told BUSY (rc=$rc): $out"
fi
# 5(b) A DEAD holder is broken, loudly, so a SIGKILLed lander cannot freeze the fleet.
python3 - "$D/state/lease" <<'PY'
import os, sys
p = sys.argv[1]
lines = open(p).read().split()
out = []
for kv in lines:
    if kv.startswith("pid="):
        # A pid that certainly is not running (and cannot be recycled into OUR test's children).
        kv = "pid=999999"
    if kv.startswith("start="):
        kv = "start=stale-start-token"
    out.append(kv)
open(p, "w").write(" ".join(out) + "\n")
PY
out="$(gate "$D" lease acquire --name after-death --wait 5 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'ACQUIRED' <<<"$out" && grep -q 'BROKE=' <<<"$out"; then
  pass "5(b) a dead holder's lease is broken and named (BROKE=…) instead of parking the box"
else
  fail "5(b) a dead holder was not broken (rc=$rc): $out"
fi
grep -q 'broke stale holder' "$D/state/events.log" 2>/dev/null \
  && pass "5(c) the break is recorded in events.log (a broken lease is never silent)" \
  || fail "5(c) breaking a stale lease left no events.log line: $(cat "$D/state/events.log" 2>/dev/null)"
# 5(d) An OVER-AGE lease is broken even though its pid is alive: one slow lander must not hold the
# box for ever. Same declared residual as gh-limit.py's lock timeout — a bound, stated out loud.
gate "$D" lease release --token "$tok" >/dev/null 2>&1
gate "$D" lease acquire --name slow-holder --pid $$ > "$D/slow.out" 2>&1
tok="$(sed -n 's/.*token=\([^ ]*\).*/\1/p' "$D/slow.out")"
python3 - "$D/state/lease" <<'PY'
import sys, time
p = sys.argv[1]
lines = open(p).read().split()
out = []
for kv in lines:
    if kv.startswith("at="):
        kv = "at=%d" % (int(time.time()) - 7200)
    out.append(kv)
open(p, "w").write(" ".join(out) + "\n")
PY
out="$(GH_GATE_LEASE_MAX_S=1800 gate "$D" lease acquire --name after-timeout --wait 5 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'ACQUIRED' <<<"$out"; then
  pass "5(d) an over-age lease is broken even though its holder pid is alive"
else
  fail "5(d) an over-age lease parked the box (rc=$rc): $out"
fi

# 5(e) PID REUSE. A lease whose recorded pid is ALIVE but whose recorded process START TOKEN
# differs belongs to a DEAD lander: pids are recycled, so `kill -0` alone says "something is running
# under this number", not "the lander that took the lease is running". Deleting the start-token
# compare left this suite green before this check existed.
D="$(scen s5-reuse)"
gate "$D" lease acquire --name recycled --pid $$ > "$D/reuse.out" 2>&1
python3 - "$D/state/lease" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split()
out = []
for kv in lines:
    if kv.startswith("start="):
        kv = "start=an_ENTIRELY_different_process_token"
    out.append(kv)
open(p, "w").write(" ".join(out) + "\n")
PY
st="$(gate "$D" lease status 2>&1)"
out="$(gate "$D" lease acquire --name after-reuse --wait 5 2>&1)"; rc=$?
if grep -q 'HELD-STALE' <<<"$st" && [ "$rc" -eq 0 ] && grep -q 'BROKE=recycled' <<<"$out"; then
  pass "5(e) a recycled pid (same pid, different start token) is broken — status says HELD-STALE"
else
  fail "5(e) a recycled pid was treated as a live holder (status='$st' rc=$rc out='$out')"
fi

# 5(f) A PID OUTSIDE C LONG MUST NOT WEDGE THE GATE. `os.kill` raises OverflowError for one, and
# this is the path that BREAKS a stale lease — so a single malformed record made acquire raise for
# ever, with a hand-`rm` as the only remedy (merge-one then logs UNREADABLE and lands UNSERIALISED
# on every landing).
D="$(scen s5-overflow)"
mkdir -p "$D/state"
printf 'token=abc holder=wedged pid=99999999999999999999 start=x host=h at=%d\n' "$(date +%s)" > "$D/state/lease"
out="$(gate "$D" lease acquire --name after-overflow --pid $$ --wait 5 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'ACQUIRED' <<<"$out" \
  && pass "5(f) an overflowing pid is treated as a stale holder, not a crash (BROKE path)" \
  || fail "5(f) an overflowing pid wedged the gate (rc=$rc): $out"

# ═══ §5b THE ERROR ARMS — the two paths that must still yield a VERDICT ═════════════════════
# These are the paths the instrument is FOR: a hung connection and a gh that cannot run at all.
# Both must publish `UNREADABLE` and exit 12 — never traceback, never exit 1 with no token. (A
# round-2 fix left these returning a shorter tuple than the caller unpacks, so both died with
# ValueError: the probe's own error handling was the only thing that did not survive an error.)
D="$(scen s5b-timeout)"; printf 'hang\n' > "$D/mode"
out="$(GH_GATE_PROBE_TIMEOUT_S=1 gate "$D" probe --publish 2>&1)"; rc=$?
[ "$rc" -eq 12 ] && grep -q 'GH-PROBE: UNREADABLE' <<<"$out" && ! grep -qi 'traceback' <<<"$out" \
  && pass "5b(a) a read that never answers -> UNREADABLE, exit 12 (no traceback)" \
  || fail "5b(a) the timeout arm did not yield a verdict (rc=$rc): $out"
# …and the publication ATTRIBUTES it. `state=? rest=?` names no failed pool, so the reader called
# the snapshot corrupt instead of reporting the broken pool.
pub="$(cat "$D/state/snapshot" 2>/dev/null)"
grep -q 'state=UNREADABLE' <<<"$pub" \
  && pass "5b(a2) …published as state=UNREADABLE (the pool it TRIED), not an unattributed '?'" \
  || fail "5b(a2) the error arm published no attributed state: $pub"
D="$(scen s5b-nogh)"; printf 'ok\n' > "$D/mode"
out="$(GATE_GH="$D/does-not-exist" gate "$D" probe --publish 2>&1)"; rc=$?
[ "$rc" -eq 12 ] && grep -q 'GH-PROBE: UNREADABLE' <<<"$out" && ! grep -qi 'traceback' <<<"$out" \
  && pass "5b(b) a gh that cannot be run -> UNREADABLE, exit 12 (no traceback)" \
  || fail "5b(b) the could-not-run arm did not yield a verdict (rc=$rc): $out"
pub="$(cat "$D/state/snapshot" 2>/dev/null)"
# BOTH error arms, not just the timeout one: an unattributed `state=? rest=?` names no failed pool,
# so the reader calls the snapshot corrupt instead of reporting the broken pool.
grep -q 'state=UNREADABLE' <<<"$pub" \
  && pass "5b(b2) …and it too publishes the pool it TRIED, named" \
  || fail "5b(b2) the could-not-run arm published no attributed state: $pub"
D="$(scen s5b-html)"; printf 'ok-html\n' > "$D/mode"
out="$(gate "$D" probe --publish 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'UNREADABLE' <<<"$out" && ! grep -q 'GH-PROBE: OK' <<<"$out" \
  && pass "5b(c) rc=0 with no parseable body -> UNREADABLE, never OK" \
  || fail "5b(c) an unparseable 200 was accepted as OK (rc=$rc): $out"

# ═══ §5c THE WIRING — the gate must be CALLED, not merely present and correct ════════════════
# ⛔ A HELPER NOBODY CALLS IS A DEPLOYED GATE NOTHING DESCRIBES. Measured: deleting
# `lander_read_blocked && exit 0` AND both `lander_lease` call sites from merge-one.sh left
# gh-gate 48/48, spawn-gate 97/0 and cloud-cell-record-dep 95/0 green — the PR's headline
# guarantee ("one lander at a time per box") regressed to zero with no red anywhere.
HARNESS="$(cd "$(dirname "$0")" && pwd)"
MO="$HARNESS/merge-one.sh"; OL="$HARNESS/orch-loop.sh"
has() { grep -qF -- "$1" "$2"; }
for pair in "lander_read_blocked && exit 0:the read-block check runs on the landing path" \
            'lander_lease "rail":the RAIL path takes the box lease' \
            'lander_lease "gate":the GATE path takes the box lease' \
            "lander_release:the EXIT trap gives the lease back"; do
  pat="${pair%%:*}"; why="${pair#*:}"
  has "$pat" "$MO" && pass "5c(1) merge-one.sh: $why" \
    || fail "5c(1) merge-one.sh no longer does this — $why ($pat)"
done
has 'trap ' "$MO" && grep -q 'trap .*lander_release' "$MO" \
  && pass "5c(2) the lease is released on the EXIT path (a lander that dies must not park the box)" \
  || fail "5c(2) the EXIT trap does not release the lease"
# The read-block check must precede the landing paths, or it cannot block anything.
_line_blk="$(grep -n 'lander_read_blocked && exit 0' "$MO" | head -1 | cut -d: -f1)"
_line_rail="$(grep -n 'lander_lease "rail"' "$MO" | head -1 | cut -d: -f1)"
_line_read="$(grep -n '^resolve_required_checks "\$OR"' "$MO" | head -1 | cut -d: -f1)"
if [ -n "$_line_blk" ] && [ -n "$_line_rail" ] && [ "$_line_blk" -lt "$_line_rail" ]; then
  pass "5c(3) the read-block check precedes the landing (checked once, before any landing path)"
else
  fail "5c(3) the read-block check does not precede the landing (blk=$_line_blk rail=$_line_rail)"
fi
# ⛔ AND IT MUST PRECEDE THE BRANCH-PROTECTION **READ**. That read is itself an API-read-dependent
# step: sitting after it, a bursted account died at the authority guard ("branch protection was
# UNREADABLE", exit 5) one line before the deferral could run, blaming the repo's authority for
# the account's concurrency cap. Nothing below depends on it, so the order is free.
if [ -n "$_line_blk" ] && [ -n "$_line_read" ] && [ "$_line_blk" -lt "$_line_read" ]; then
  pass "5c(3b) …and BEFORE the branch-protection read (a bursted account defers, never 'authority UNKNOWN')"
else
  fail "5c(3b) the read-block runs after the protection read (blk=$_line_blk read=$_line_read) — a bursted box refuses instead of deferring"
fi
has 'gh_gate_token' "$OL" && pass "5c(4) orch-loop.sh reports the gate's real-read token each cycle" \
  || fail "5c(4) orch-loop.sh no longer reports ghs= (the instrument is unwired)"
# ⛔ THE CALL SHAPE, not the definition: `has 'gh_gate_snapshot'` is satisfied by the function
# definition alone, so dropping the argument left this green (measured, round 13).
grep -qF 'else dispatch_funnel 0 "$(queue_state_token)" "" "" "$(gh_gate_snapshot)"' "$OL" \
  && pass "5c(5) …and the shared read is passed as the no-dispatch funnel line's OWN ghs= field" \
  || fail "5c(5) the shared read is not wired into the no-dispatch funnel line"
# ⛔ THE CELL DOCTOR IS A LANDER TOO. Its `merge` role executes the rail directly, is DEFAULT-ON
# (MERGE_INTERVAL, tmux `cell-doctor` on every started cell), and took only its own per-PR claim —
# which serialises the SAME PR, not the ACCOUNT. Two landers on one box is the burst #1910
# measured. (The docs claimed "every harness lander takes the lease": that claim was false here,
# which is why the false half was fixed in CODE rather than narrowed in prose.)
DOC="$HARNESS/cloud-cell-doctor.sh"
# ⛔ ORDER, NOT PRESENCE. Releasing immediately after the acquire (rail run unserialised) kept the
# presence-only form green — the guard was inert.
_d_acq="$(grep -n 'lease acquire --name "doctor-$pr"' "$DOC" | head -1 | cut -d: -f1)"
_d_rail="$(grep -n 'run_bounded "\$RAIL_TIMEOUT" bash "\$rail"' "$DOC" | head -1 | cut -d: -f1)"
_d_rel="$(grep -n 'lease release --token "\$lander_token"' "$DOC" | head -1 | cut -d: -f1)"
if [ -n "$_d_acq" ] && [ -n "$_d_rail" ] && [ -n "$_d_rel" ] \
   && [ "$_d_acq" -lt "$_d_rail" ] && [ "$_d_rail" -lt "$_d_rel" ]; then
  pass "5c(7) cloud-cell-doctor.sh holds the BOX lease ACROSS its rail run (acquire < rail < release)"
else
  fail "5c(7) the doctor's lease does not span the rail (acq=$_d_acq rail=$_d_rail rel=$_d_rel) — two landers can arrive together"
fi
# …and ALL THREE anchors for merge-one.sh's rail path. `acquire < release` alone was not enough:
# moving `lander_release` to just after the acquire (so the rail runs UNSERIALISED — the exact
# regression §5c(7) exists to catch) left one release above the rail and the check green.
_m_acq="$(grep -n 'lander_lease "rail"' "$MO" | head -1 | cut -d: -f1)"
_m_rail="$(grep -n 'bash "$RAIL" "$PR" --repo "$OR" -- --squash' "$MO" | head -1 | cut -d: -f1)"
# ⛔ WHITESPACE-INSENSITIVE. Anchored at `^  lander_release$` (two spaces) this matched only the
# exact indentation, so an identically-executing `    lander_release` inserted above the rail slipped
# through the very check written to catch it.
_m_rel="$(awk -v r="${_m_rail:-0}" 'NR > r && /^[[:space:]]*lander_release[[:space:]]*$/ {print NR; exit}' "$MO")"
# ⛔ AND NO RELEASE BETWEEN THEM. "acquire < the release after the rail" is still satisfied by an
# EXTRA release inserted immediately after the acquire — which IS the regression (the rail then runs
# UNSERIALISED). Measured: that mutation passed this check before this line existed.
_m_mid="$(awk -v a="${_m_acq:-0}" -v r="${_m_rail:-0}" 'NR > a && NR < r && /^[[:space:]]*lander_release[[:space:]]*$/ {print NR}' "$MO")"
if [ -n "$_m_acq" ] && [ -n "$_m_rail" ] && [ -n "$_m_rel" ] && [ -z "$_m_mid" ] \
   && [ "$_m_acq" -lt "$_m_rail" ] && [ "$_m_rail" -lt "$_m_rel" ]; then
  pass "5c(7b) merge-one.sh holds the lease ACROSS its rail call (acquire < rail < release)"
else
  fail "5c(7b) merge-one.sh does not hold the lease across the rail (acq=$_m_acq rail=$_m_rail rel=$_m_rel) — the landing runs UNSERIALISED"
fi
# ⛔ AND THE GATE-MODE ARM, which had PRESENCE checks only (5c(1)). Verified by mutation: inserting
# `lander_release` immediately after `lander_lease "gate"` — so the squash runs UNSERIALISED, the
# exact regression 5c(7b) exists for, one path over — left gh-gate 71/71, spawn-gate 97/0 and
# cloud-cell-record-dep 95/0 ALL green. Both docs state this lease "spans the squash"; that
# documented guarantee had no guard at all.
_g_acq="$(grep -n 'lander_lease "gate"' "$MO" | head -1 | cut -d: -f1)"
_g_sq="$(awk -v a="${_g_acq:-0}" 'NR > a && /gh pr merge|--admin|squash/ {print NR; exit}' "$MO")"
_g_rel="$(awk -v r="${_g_sq:-0}" 'NR > r && /^[[:space:]]*lander_release[[:space:]]*$/ {print NR; exit}' "$MO")"
_g_mid="$(awk -v a="${_g_acq:-0}" -v r="${_g_sq:-0}" 'NR > a && NR < r && /^[[:space:]]*lander_release[[:space:]]*$/ {print NR}' "$MO")"
if [ -n "$_g_acq" ] && [ -n "$_g_sq" ] && [ -n "$_g_rel" ] && [ -z "$_g_mid" ] \
   && [ "$_g_acq" -lt "$_g_sq" ] && [ "$_g_sq" -lt "$_g_rel" ]; then
  pass "5c(7e) merge-one.sh's GATE path holds the lease ACROSS the squash (acquire < squash < release)"
else
  fail "5c(7e) the gate-mode squash runs outside the lease (acq=$_g_acq squash=$_g_sq rel=$_g_rel mid=$_g_mid)"
fi

# 5c(7f) THE RESOLUTION'S ORDER: rail-abort guard -> lease -> squash. The guard is the only thing
# stopping a rail repo's PR from landing on its required checks alone via a raw merge
# (#1764/#1825), and it must decide BEFORE the lease is taken (a lease taken inside a step that
# aborts would be released by the EXIT trap, but the guard's whole point is that this code never
# runs in rail mode). Nothing pinned this order until the merge-resolution review.
_guard="$(grep -n 'rail mode reached the raw merge step' "$MO" | head -1 | cut -d: -f1)"
if [ -n "$_guard" ] && [ -n "$_g_acq" ] && [ -n "$_g_sq" ] \
   && [ "$_guard" -lt "$_g_acq" ] && [ "$_g_acq" -lt "$_g_sq" ]; then
  pass "5c(7f) the rail-authority abort guard runs BEFORE the gate lease, which precedes the squash"
else
  fail "5c(7f) the guard/lease/squash order is wrong (guard=$_guard acq=$_g_acq squash=$_g_sq) — a rail PR could land on a raw merge"
fi

# A deferral must RELEASE the per-PR claim: left behind, the doctor's own long-lived loop pid reads
# as a live foreign worker to merge-one.sh, to orch-loop.sh's claim_live and to its own next pass —
# a permanent silent stall, not a one-pass skip.
# ⛔ INSIDE THE DEFER BRANCH, not merely somewhere in the file: the same claim-release line also
# exists after the rail, so a whole-file grep stayed green with the defer copy deleted.
_defer_blk="$(awk '/_lg_rc" -eq 75/{f=1} f{print} f&&/continue/{exit}' "$DOC")"
{ grep -q 'rm -f "\$cl"' <<<"$_defer_blk" && grep -q 'DEFERRED' <<<"$_defer_blk"; } \
  && pass "5c(7c) a lease deferral releases the per-PR claim before it continues" \
  || fail "5c(7c) a deferral leaves the per-PR claim behind — the PR is then skipped for ever"
# Only BUSY (75) is contention. UNREADABLE/BAD-ARG must fail OPEN with a loud warning.
# ⛔ SHAPE, NOT WORDS. Grepping for the discriminator and the warning text only proved they EXIST:
# appending `skipped=…; continue` to the fail-open arm — i.e. turning a broken gate back into a
# permanent merge-role stall — left both greps matching and the suite green. `continue` must appear
# in the BUSY (75) arm and in NO OTHER arm of this block.
_lg_arms="$(awk '/_lg_rc" -eq 75/{f=1} f{print} f&&/^    fi$/{exit}' "$DOC")"
if [ -z "$_lg_arms" ]; then
  fail "5c(7d) the lease-acquire branch is missing entirely"
else
  n_75="$(awk '/-eq 75/{f=1} f&&/continue/{c++} /else/{f=0} END{print c+0}' <<<"$_lg_arms")"
  n_else="$(awk '/^      else$/{f=1} f&&/continue|break/{c++} f&&/^      fi$/{f=0} END{print c+0}' <<<"$_lg_arms")"
  if [ "${n_75:-0}" -ge 1 ] && [ "${n_else:-0}" -eq 0 ]; then
    pass "5c(7d) only BUSY (75) defers; the fail-open arm cannot skip the PR (a broken gate still rails)"
  else
    fail "5c(7d) the acquire branches are wrong (continue in BUSY arm=$n_75, in fail-open arm=$n_else) — a broken gate parks the merge role"
  fi
fi
# …and a lease it cannot get must DEFER, never park: the word that would park a head is absent.
grep -q 'DEFERRED' "$DOC" && ! grep -q 'parked-\$pr' "$DOC" \
  && pass "5c(8) …and defers (no cooldown/park written) when the lease is held" \
  || fail "5c(8) the doctor's lease contention does not defer cleanly"

# The controller's cycle line must actually PRINT the token, or the instrument is computed and lost.
# The token is computed once into GHS (line above) and printed as ghs=$GHS — both halves must
# survive, or the instrument is computed and thrown away.
grep -qE 'ghs=\$\{?GHS\}?' "$OL" && grep -q 'GHS="\$(gh_gate_token)"' "$OL" \
  && pass "5c(6) …on the cycle line itself (ghs=), where a bursted account is visible" \
  || fail "5c(6) the cycle line does not carry the gate token (ghs=<GHS> from gh_gate_token)"

# ═══ §5d a corrupt lease RECORD cannot park the box ════════════════════════════════════════
# `at` was the only field in the record with no validity guard: float() accepts nan/inf, the
# over-age test is False for nan, and int(age) then raised — BEFORE the break — so one corrupt
# byte left the box serialised against nothing, for ever.
# ⛔ THE HOLDER MUST LOOK ALIVE or the crash never happens: `int(age)` is only reached on the
# live-holder path, so a dead-looking holder is broken by the pid/token check first. Acquire a REAL
# lease (correct pid AND start token), then corrupt ONLY `at`.
for bad in nan inf -inf; do
  D="$(scen "s5d-$bad")"
  gate "$D" lease acquire --name "ghost" --pid $$ >/dev/null 2>&1 || true
  python3 - "$D/state/lease" "$bad" <<'PYX'
import sys
p, bad = sys.argv[1], sys.argv[2]
toks = open(p).read().split()
open(p, "w").write(" ".join(("at=%s" % bad) if t.startswith("at=") else t for t in toks) + "\n")
PYX
  out="$(gate "$D" lease acquire --name "merge-x" --pid $$ 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ! grep -qi 'traceback' <<<"$out" \
    && pass "5d($bad) a lease at=… is BROKEN, not a crash" \
    || fail "5d($bad) a corrupt lease age wedged the box (rc=$rc): $out"
done

# 5d2 THE OTHER VERB MUST AGREE. `status` is what an operator runs during a suspected wedge, and
# it reported `at=nan` as `HELD … age=0s` — a FRESH lease — while `acquire` broke the same record
# as past the bound; on `at=inf` it tracebacked. One reader, two answers, is a diagnostic that lies.
for bad in nan inf; do
  D="$(scen "s5d2-$bad")"
  gate "$D" lease acquire --name "ghost" --pid $$ >/dev/null 2>&1 || true
  python3 - "$D/state/lease" "$bad" <<'PYX'
import sys
p, bad = sys.argv[1], sys.argv[2]
toks = open(p).read().split()
open(p, "w").write(" ".join(("at=%s" % bad) if t.startswith("at=") else t for t in toks) + "\n")
PYX
  out="$(gate "$D" lease status 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! grep -qi 'traceback' <<<"$out" && grep -q 'age unreadable' <<<"$out" \
     && ! grep -q 'age=0s' <<<"$out"; then
    pass "5d2($bad) lease status reports an unreadable age, not age=0s and not a crash"
  else
    fail "5d2($bad) lease status disagreed with acquire about a corrupt at (rc=$rc): $out"
  fi
done

# 5d3 ⛔ A READABLE AGE PAST THE BOUND IS NOT A CORRUPT RECORD. `status` used to derive
# "unreadable" from `age > max_hold`, so an operator investigating a genuine 40-minute holder was
# told the record was corrupt — while `acquire` was correctly reporting "held for 2400s, past the
# 1800s bound". Both must name the SAME fact.
D="$(scen s5d3)"
gate "$D" lease acquire --name "holder" --pid $$ >/dev/null 2>&1 || true
python3 - "$D/state/lease" <<'PYX'
import sys
p = sys.argv[1]
old = [t for t in open(p).read().split() if t.startswith("at=")]
new = "at=%d" % (int(__import__("time").time()) - 2400)
toks = [new if t.startswith("at=") else t for t in open(p).read().split()]
open(p, "w").write(" ".join(toks) + "\n")
PYX
out="$(GH_GATE_LEASE_MAX_S=1800 gate "$D" lease status 2>&1)"; rc=$?
# ⛔ TOLERATE THE SPAWN GAP. `at` is written by one python process and read by another, so the true
# age is 2400 + Δ: asserting the literal `age=2400s` false-redded about once in eight full-suite runs
# (measured), on a guard wired into run-bash-shards.sh — i.e. an intermittently-refusing gate on every
# PR, which is the failure this repo's own AGENTS.md names as the throughput killer. Only the NUMBER
# is widened; the negative assertion and the bound phrase keep full discriminating power.
if [ "$rc" -eq 0 ] && grep -qE 'age=240[0-9]s' <<<"$out" && grep -q 'past the 1800s bound' <<<"$out" \
   && ! grep -q 'unreadable' <<<"$out"; then
  pass "5d3 an over-age but READABLE lease reports its real age and the bound, never 'unreadable'"
else
  fail "5d3 an over-age readable lease was misreported (rc=$rc): $out"
fi

# ═══ §5e the fallback state dir is never followed through a SYMLINK ═════════════════════════
# A plain local uid can pre-create "$TMPDIR/gh-gate-<uid>" as a link; makedirs swallows the
# collision (isdir follows links), and a chmod-before-validation would change the TARGET's mode
# and then write the lease into it. lstat refuses the link outright.
# ⛔ THE PRIMARY MUST BE GENUINELY UNUSABLE, or the fallback never runs: a world-writable
# PARENT still lets the primary state dir be CREATED (mode 700, ours), so `chmod 777` alone made
# this check pass with the guard deleted — a false green in the guard's own guard. A regular FILE
# in the path makes `makedirs` fail for certain, which is what routes us to the fallback.
D="$(scen s5e)"; mkdir -p "$D/primary/victim" "$D/tmp"; chmod 777 "$D/primary"
: > "$D/notadir"
ln -s "$D/primary/victim" "$D/tmp/gh-gate-$(id -u)"
before="$(ls -ld "$D/primary/victim" | awk '{print $1}')"
out="$(TMPDIR="$D/tmp" GH_GATE_DIR="$D/notadir/state" GH_GATE_REAL_GH="$STUB" GH_GATE_SCEN="$D" \
       python3 "$GATE" lease acquire --name "merge-x" --pid $$ 2>&1)"; rc=$?
after="$(ls -ld "$D/primary/victim" | awk '{print $1}')"
if [ "$before" = "$after" ] && [ ! -e "$D/primary/victim/lease" ] && ! grep -qi 'traceback' <<<"$out"; then
  pass "5e(a) a SYMLINKED fallback dir is refused — the link target is untouched and no lease is written"
else
  fail "5e(a) the symlinked fallback was followed (mode $before -> $after, victim/lease=$([ -e "$D/primary/victim/lease" ] && echo yes || echo no)): $out"
fi

# ═══ §6 the CYCLE token is ONE line, in the documented shape ═════════════════════════════════
# `orch-loop.sh` interpolates this into a `key=value` cycle record. Two lines put a newline inside
# that record, detached its `===` frame, and left `ghs=` holding prose instead of the token.
D="$(scen s6)"; printf 'secondary\n' > "$D/mode"
out="$(gate "$D" cycle 2>&1)"
lines_n="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$lines_n" = "1" ] && grep -qE '^(FRESH|STALE|UNKNOWN)\(' <<<"$out"; then
  pass "6(a) cycle prints exactly ONE line, in the documented FRESH(...) shape"
else
  fail "6(a) cycle printed $lines_n line(s), not one FRESH(...) token: $out"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "✅ gh-gate: $checks checks passed"
  exit 0
fi
echo "❌ gh-gate: $failures of $checks checks FAILED"
exit 1
