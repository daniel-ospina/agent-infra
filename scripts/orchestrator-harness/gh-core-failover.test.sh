#!/usr/bin/env bash
# gh-core-failover.test.sh — offline checks for the core->GraphQL failover, the TTL read cache and
# the NAMED health state (the 2026-10-22 `core: 0 remaining` incident).
#
# No network, no credentials, no real gh: a STUB gh answers from a scenario name and appends every
# invocation to a log, so the assertions pin the four properties the incident demands:
#
#   (a) core=0 + GraphQL available  => the read SUCCEEDS and the failover is LOGGED;
#   (b) core=0 + GraphQL refused    => the NAMED state, never a generic failure and NEVER an empty
#                                      body (an empty read is what a lane reads as “nothing is
#                                      required” — a red tree mistaken for a green one);
#   (c) N identical reads inside the TTL => ONE upstream request (asserted against the stub's log);
#   (d) mutations: GH_LIMIT_READ_CACHE=0 makes (c) fail; GH_LIMIT_FAILOVER=0 makes (a) fail.
#
# ⛔ NO REAL SLEEP: every path asserted here fails fast or answers immediately, so the suite needs no
# fake clock. `GH_LIMIT_NO_WAIT=1` is set for the refusal cases so a real backoff cannot turn this
# file into a 7-minute run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/gh-limit.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
[ -f "$HELPER" ] || { echo "helper missing: $HELPER" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required by the --jq projection path" >&2; exit 1; }

STUB_LOG="$TMP/stub.log"
NOW="$(date +%s)"
RESET="$((NOW + 720))"

# ── the stub "real" gh ─────────────────────────────────────────────────────────────────────────────
# Scenario decides what the BUDGET meter says and whether GraphQL answers; everything else is a fixed
# REST/GraphQL payload, so a difference in the output can only come from the layer under test.
cat >"$TMP/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GH_TEST_LOG"
case "\$1 \$2" in
  "api rate_limit")
    # core: EMPTY (the incident). graphql: 4745 of 5000 (the headroom that existed and went unused).
    if [ "\${GH_TEST_SCENARIO:-}" = "coreok" ]; then
      printf '{"resources":{"core":{"limit":5000,"remaining":3000,"reset":$RESET,"used":2000},"graphql":{"limit":5000,"remaining":4000,"reset":$RESET,"used":1000}}}\n'
    else
      printf '{"resources":{"core":{"limit":5000,"remaining":0,"reset":$RESET,"used":5000},"graphql":{"limit":5000,"remaining":4745,"reset":$RESET,"used":255}}}\n'
    fi
    ;;
  "api graphql")
    if [ "\${GH_TEST_SCENARIO:-}" = "graphqldead" ]; then
      printf 'API rate limit exceeded for user ID 81560491.\n' >&2
      exit 1
    fi
    printf '{"data":{"repository":{"pullRequest":{"number":7,"state":"OPEN","isDraft":false,"merged":false,"mergeable":"MERGEABLE","headRefOid":"abc123","baseRefName":"main","title":"t","url":"https://example/pull/7","updatedAt":"2026-10-22T00:00:00Z","author":{"login":"daniel-ospina"}}}}}\n'
    ;;
  "api repos/o/r/pulls/7")
    # core is EMPTY in every scenario but `coreok`: a REST read is REFUSED, exactly like 14:03Z.
    if [ "\${GH_TEST_SCENARIO:-}" != "coreok" ]; then
      printf 'API rate limit exceeded for user ID 81560491.\n' >&2
      exit 1
    fi
    printf '{"number":7,"state":"open","head":{"sha":"restsha"},"base":{"ref":"main"},"merged":false,"mergeable":true}\n'
    ;;
  "api repos/o/r/branches/main/protection/required_status_checks")
    printf '{"contexts":["pipeline-compliance"]}\n'
    ;;
  "pr view")
    # A GraphQL SUBCOMMAND: no ETag exists for it, so the TTL cache is the only saving it can have.
    printf '{"headRefOid":"graphqlsha"}\n'
    ;;
  "run list")
    # The FIRST-CHECKS poll: byte-identical argv, ~15 times per merge cycle (measured 30 of 41 calls).
    printf '[{"databaseId":39786847846,"status":"completed","conclusion":"success"}]\n'
    ;;
  "api --include")
    # `conditional_fetch` frames its GETs (`--include`); a framed 200 with an ETag is what it expects.
    printf 'HTTP/2.0 200 OK\r\nETag: "e1"\r\nContent-Type: application/json\r\n\r\n{"number":7,"state":"open"}\r\n'
    ;;
  *)
    printf 'stub gh: unexpected argv: %s\n' "\$*" >&2
    exit 42
    ;;
esac
STUB
chmod +x "$TMP/gh"

# isolated state dir per scenario: no scenario can inherit another's cache, budget snapshot or health
reset_env() {
  export GH_LIMIT_DIR="$TMP/state-$1"
  rm -rf "$GH_LIMIT_DIR"; mkdir -p "$GH_LIMIT_DIR"
  : > "$STUB_LOG"
  export GH_TEST_LOG="$STUB_LOG"
  # The ETag round trip is a DIFFERENT optimisation with its own suite (gh-limit.test.sh). Turning it
  # off here is what makes “N reads => 1 request” a statement about the READ CACHE rather than a
  # 304 that still spends a request.
  export GH_LIMIT_CONDITIONAL=0
  export GH_LIMIT_NO_WAIT=1
  unset GH_LIMIT_READ_CACHE GH_LIMIT_FAILOVER 2>/dev/null || true
  export GH_TEST_SCENARIO="$2"
}

run() {  # run <scenario> args… ; stdout/stderr in $OUT/$ERR, rc in $RC
  GH_TEST_SCENARIO="$1" python3 "$HELPER" --real-gh "$TMP/gh" -- "${@:2}" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}

reqs() { grep -c -- "$1" "$STUB_LOG" 2>/dev/null || true; }

health() {  # the --health VERB takes no gh argv, so it is NOT passed after `--`
  GH_TEST_SCENARIO="$1" python3 "$HELPER" --health >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}

budget() {  # the --budget VERB: ONE exempt read of both pools, recorded for every later call
  GH_TEST_SCENARIO="$1" python3 "$HELPER" --real-gh "$TMP/gh" --budget >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}

echo "── (a) core=0 + GraphQL available: the read SUCCEEDS and the failover is LOGGED ──────────────"
reset_env a core0
# ONE exempt read of BOTH pools — the burst's own meter call, which is what a dispatcher does before
# it fans out. Every call after this reads the shared snapshot instead of probing.
budget core0
ck "(a) --budget names BOTH pools and their windows" \
   $(printf '%s' "$OUT" | grep -q '^core=0/5000 resets_in=12m graphql=4745/5000' && echo 0 || echo 1)
ck "(a) --budget exits 0" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
: > "$STUB_LOG"                    # counters start after the meter call: they describe the READ
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(a) exit 0"                         $([ "$RC" -eq 0 ] && echo 0 || echo 1)
ck "(a) the caller's own --jq is applied to the GraphQL-derived body (abc123)" \
   $([ "$OUT" = "abc123" ] && echo 0 || echo 1)
ck "(a) the request went to __graphql__, not to the REST pool" \
   $([ "$(reqs 'api graphql')" -eq 1 ] && [ "$(reqs 'pulls/7')" -eq 0 ] && echo 0 || echo 1)
ck "(a) the failover is RECORDED (events.log names it)" \
   $(grep -q 'failover:' "$GH_LIMIT_DIR/events.log" && grep -q 'GraphQL pool' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)
ck "(a) nothing on the caller's stderr (the streams stay sacred on success)" $([ -s "$TMP/err" ] && echo 1 || echo 0)
health core0
ck "(a) --health still reports the core pool as EMPTY after a GraphQL-served read" \
   $(printf '%s' "$OUT" | grep -q '^gh-core-exhausted resets_in=12m$' && echo 0 || echo 1)
ck "(a) --health exits 3 (a NAMED state, not a generic failure)" $([ "$RC" -eq 3 ] && echo 0 || echo 1)

echo "── (a2) the fleet LEARNS: ONE refusal + ONE exempt probe makes every later lane fail over ────"
# The property that makes this survivable at 2am. Lane A is a controller-like caller (it may defer),
# so on its refusal the layer spends ONE exempt `/rate_limit` read and records BOTH pools. Lane B is a
# bounded caller and must spend NO probe of its own: it reads the record and fails over. If every lane
# had to probe to discover the pool was empty, the failover would cost the budget it exists to save.
reset_env a2 core0
unset GH_LIMIT_NO_WAIT
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7                  # lane A: refused, then the documented deferral
ck "(a2) lane A's read was REFUSED" $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(a2) the refusal cost exactly ONE exempt meter read, which recorded both pools" \
   $([ "$(reqs 'api rate_limit')" -eq 1 ] && [ -f "$GH_LIMIT_DIR/budget.json" ] && echo 0 || echo 1)
ck "(a2) lane A did NOT wait out a 12-minute reset (the in-call bound holds)" \
   $(printf '%s' "$ERR" | grep -q 'beyond the 300s in-call bound' && echo 0 || echo 1)
export GH_LIMIT_NO_WAIT=1                        # lane B is bounded: it may not sleep, and need not
run core0 api repos/o/r/pulls/7 --jq .head.sha   # lane B: same box, later process
ck "(a2) lane B's read SUCCEEDED from GraphQL" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "abc123" ] && echo 0 || echo 1)
ck "(a2) lane B spent NO meter call of its own (still 1 for the whole box)" \
   $([ "$(reqs 'api rate_limit')" -eq 1 ] && echo 0 || echo 1)

echo "── (b) core=0 + GraphQL ALSO refused: the NAMED state, never an empty answer ────────────────"
reset_env b graphqldead
budget graphqldead
run graphqldead api repos/o/r/pulls/7
ck "(b) the call FAILS (never a green tree)" $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(b) stdout is EMPTY (no empty body that a lane could read as data)" $([ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(b) stderr carries the NAMED state gh-core-exhausted resets_in=<Nm>" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=' && echo 0 || echo 1)
ck "(b) stderr also keeps the classifier's marker ('rate limit')" \
   $(printf '%s' "$ERR" | grep -qi 'rate limit' && echo 0 || echo 1)
ck "(b) the message says it is NOT a broken repo/token (no false diagnosis)" \
   $(printf '%s' "$ERR" | grep -q 'not a broken repo' && echo 0 || echo 1)

echo "── (b2) a read with NO exact GraphQL equivalent is REFUSED, not approximated ─────────────────"
reset_env b2 core0
budget core0
: > "$STUB_LOG"
run core0 api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(b2) the protection read FAILS instead of answering an empty context set" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(b2) it was NEVER SENT (no request for a call that cannot succeed)" $([ "$(reqs 'protection')" -eq 0 ] && echo 0 || echo 1)
ck "(b2) stderr NAMES the state and says why it was not approximated" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted' && printf '%s' "$ERR" | grep -q 'NO exact GraphQL equivalent' && echo 0 || echo 1)

echo "── (b3) a WRITE is never failed over and never retried into the empty pool ───────────────────"
reset_env b3 core0
budget core0
: > "$STUB_LOG"
run core0 api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(b3) the merge attempt FAILS, named, with no request spent" \
   $([ "$RC" -ne 0 ] && [ "$(reqs 'merge')" -eq 0 ] && printf '%s' "$ERR" | grep -q 'gh-core-exhausted' && echo 0 || echo 1)
ck "(b3) it says the call WRITES and was not retried" \
   $(printf '%s' "$ERR" | grep -q 'WRITES' && echo 0 || echo 1)

echo "── (c) N identical reads inside the TTL => ONE upstream request ──────────────────────────────"
reset_env c coreok
for i in 1 2 3 4 5; do run coreok api repos/o/r/pulls/7 ; done
ck "(c) 5 identical reads made 1 request" $([ "$(reqs 'pulls/7')" -eq 1 ] && echo 0 || echo 1)
ck "(c) every one of the 5 returned the answer" $([ "$OUT" = '{"number":7,"state":"open","head":{"sha":"restsha"},"base":{"ref":"main"},"merged":false,"mergeable":true}' ] && echo 0 || echo 1)
ck "(c) the hit is RECORDED in events.log" $(grep -q 'read-cache: pr-state hit' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)

echo "── (c2) the GraphQL SUBCOMMAND path is cached too (it has no ETag at all) ───────────────────"
reset_env c2 coreok
for i in 1 2 3; do run coreok pr view 7 --json headRefOid ; done
ck "(c2) 3 identical 'gh pr view' reads made 1 request" $([ "$(reqs 'pr view 7')" -eq 1 ] && echo 0 || echo 1)
ck "(c2) all 3 got the answer" $([ "$OUT" = '{"headRefOid":"graphqlsha"}' ] && echo 0 || echo 1)

# ⛔ ONE CACHE PER SHAPE: an ETag-covered GET is NOT TTL-cached, because the 304 path is free, fresher,
# and its “the second poll sends if-none-match” guarantee is pinned by gh-limit.test.sh".
reset_env c3 coreok
export GH_LIMIT_CONDITIONAL=1
run coreok api repos/o/r/pulls/7 >/dev/null 2>&1
run coreok api repos/o/r/pulls/7 >/dev/null 2>&1
ck "(c3) an ETag-eligible GET is still revalidated (2 requests, not 1) — no double cache" \
   $([ "$(reqs 'pulls/7')" -eq 2 ] && echo 0 || echo 1)
unset GH_LIMIT_CONDITIONAL

echo "── (c4) the measured hotspot: the FIRST-CHECKS poll loop ─────────────────────────────────────"
# 30 of the 41 calls in a measured merge cycle were this one loop. 15 identical polls must cost ONE.
reset_env c4 coreok
i=0
while [ "$i" -lt 15 ]; do
  run coreok run list --commit abc123 --limit 100 --workflow python-ci.yml --json databaseId,status,conclusion
  i=$((i + 1))
done
ck "(c4) 15 polls of identical argv made 1 request (measured loop: 30 of 41 calls)" \
   $([ "$(reqs 'run list')" -eq 1 ] && echo 0 || echo 1)
ck "(c4) every poll got the run list" $(printf '%s' "$OUT" | grep -q '39786847846' && echo 0 || echo 1)

echo "── (d) MUTATION: GH_LIMIT_READ_CACHE=0 must make (c) fail ────────────────────────────────────"
reset_env d coreok
export GH_LIMIT_READ_CACHE=0
for i in 1 2 3 4 5; do run coreok api repos/o/r/pulls/7 ; done
n="$(reqs 'pulls/7')"
ck "(d) with the cache disabled the same 5 reads make 5 requests (was 1) — n=$n" \
   $([ "$n" -eq 5 ] && echo 0 || echo 1)
unset GH_LIMIT_READ_CACHE

echo "── (e) MUTATION: GH_LIMIT_FAILOVER=0 must make (a) fail ──────────────────────────────────────"
reset_env e core0
export GH_LIMIT_FAILOVER=0
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(e) with the failover disabled the core-exhausted read fails" $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(e) and it says the right thing (named state, not a generic unreadable)" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=' && echo 0 || echo 1)
unset GH_LIMIT_FAILOVER

echo "── (f) the healthy path is unchanged and clears the named state ──────────────────────────────"
reset_env f coreok
run coreok api repos/o/r/pulls/7
ck "(f) a normal core read still succeeds through the plain path" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
health coreok
ck "(f) --health reports gh-ok and exits 0" $(printf '%s' "$OUT" | grep -q '^gh-ok$' && [ "$RC" -eq 0 ] && echo 0 || echo 1)

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
