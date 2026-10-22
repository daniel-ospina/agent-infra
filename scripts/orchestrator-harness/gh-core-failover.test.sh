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
    elif [ "\${GH_TEST_SCENARIO:-}" = "shl" ]; then
      printf '{"resources":{"core":{"limit":5000,"remaining":3000,"reset":$RESET,"used":2000},"graphql":{"limit":5000,"remaining":4000,"reset":$RESET,"used":1000}}}\n'
    elif [ "\${GH_TEST_SCENARIO:-}" = "secondary" ]; then
      printf '{"resources":{"core":{"limit":5000,"remaining":3200,"reset":$RESET,"used":1800},"graphql":{"limit":5000,"remaining":4000,"reset":$RESET,"used":1000}}}\n'
    elif [ "\${GH_TEST_SCENARIO:-}" = "low" ]; then
      # 50 left: inside the low-water band, NOT empty.
      printf '{"resources":{"core":{"limit":5000,"remaining":50,"reset":$RESET,"used":4950},"graphql":{"limit":5000,"remaining":4000,"reset":$RESET,"used":1000}}}\n'
    else
      printf '{"resources":{"core":{"limit":5000,"remaining":0,"reset":$RESET,"used":5000},"graphql":{"limit":5000,"remaining":4745,"reset":$RESET,"used":255}}}\n'
    fi
    ;;
  "api graphql")
    if [ "\${GH_TEST_SCENARIO:-}" = "graphqldead" ]; then
      printf 'API rate limit exceeded for user ID 81560491.\n' >&2
      exit 1
    fi
    printf '{"data":{"repository":{"pullRequest":{"number":7,"state":"OPEN","isDraft":false,"merged":false,"mergeable":"MERGEABLE","headRefOid":"abc123","headRefName":"feat","baseRefOid":"basesha","baseRefName":"main","title":"t","body":"prbody","url":"https://example/pull/7","updatedAt":"2026-10-22T00:00:00Z","createdAt":"2026-10-21T00:00:00Z","closedAt":null,"mergedAt":null,"changedFiles":3,"additions":10,"deletions":2,"comments":{"totalCount":4},"mergeCommit":null,"author":{"login":"daniel-ospina"}}}}}\n'
    ;;
  "api repos/o/r/pulls/7")
    # core is EMPTY in every scenario but coreok: a REST read is REFUSED, exactly like 14:03Z.
    # NOTE: no backticks anywhere inside this heredoc — it is UNQUOTED, so they would be
    # command-substituted and the stub's comment would lose the span (measured: a stray
    # "coreok: command not found" on stderr at generation time).
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
  "pr list")
    # The board read: a `pr-list` TTL class (5 s). Without this arm the stub exits 42, so a
    # "3 reads => 1 request" assertion would be measuring a FAILURE rather than a cache hit.
    printf '[{"number":1,"title":"t"}]\n'
    ;;
  "pr checks")
    # DELIBERATELY NOT a TTL class (see READ_SUBCOMMAND_CLASSES): its answer is a merge decision.
    printf '[{"name":"pipeline-compliance","state":"SUCCESS"}]\n'
    ;;
  "api --include")
    # conditional_fetch frames its GETs with --include. The "secondary" scenario answers a BURST
    # refusal the way GitHub does: 403, a phrase, and x-ratelimit-remaining still ABOVE zero.
    # "shl" is the same burst WITHOUT a remaining counter at all — absent must read as UNKNOWN.
    # NOTE: no backticks in this heredoc — it is unquoted, so they would be command-substituted.
    if [ "\${GH_TEST_SCENARIO:-}" = "secondary" ] || [ "\${GH_TEST_SCENARIO:-}" = "shl" ]; then
      # AND IT MUST EXIT NON-ZERO: a real gh fails on a 403, and a 0-exit stub would be read as a
      # SUCCESS (the body emitted, rc 0) — the exact “a refusal looks like an answer” shape.
      if [ "\${GH_TEST_SCENARIO:-}" = "shl" ]; then
        printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 1\r\nX-RateLimit-Reset: %s\r\n\r\n{"message":"You have exceeded a secondary rate limit"}\r\n' "$RESET"
      else
        printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 3200\r\nX-RateLimit-Reset: %s\r\n\r\n{"message":"You have exceeded a secondary rate limit"}\r\n' "$RESET"
      fi
      # a real gh ALSO writes its own error line to stderr; classify() reads the PHRASE from there
      printf 'gh: You have exceeded a secondary rate limit (HTTP 403)\n' >&2
      exit 1
    else
      case "\$*" in
        *If-None-Match*)
          # the ETag path's free revalidation: an unchanged resource costs NO quota
          printf 'HTTP/2.0 304 Not Modified\r\nETag: "e1"\r\n\r\n'
          ;;
        *)
          printf 'HTTP/2.0 200 OK\r\nETag: "e1"\r\nContent-Type: application/json\r\n\r\n{"contexts":["pipeline-compliance"]}\r\n'
          ;;
      esac
    fi
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

echo "── (c) the ETag-free SUBCOMMAND surface is cached: N identical reads => ONE request ───────────"
reset_env c coreok
for i in 1 2 3 4 5; do run coreok pr view 7 --json headRefOid ; done
ck "(c) 5 identical 'gh pr view' reads made 1 request" $([ "$(reqs 'pr view 7')" -eq 1 ] && echo 0 || echo 1)
ck "(c) every one of the 5 returned the answer" $([ "$OUT" = '{"headRefOid":"graphqlsha"}' ] && echo 0 || echo 1)
ck "(c) the hit is RECORDED in events.log" $(grep -q 'read-cache: pr-state hit' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)

echo "── (c1) a read-modify-write surface is NEVER TTL-cached (round-5 lost update) ───────────────�"
# `record-review.sh:2356` reads `pulls/{n}`'s .body and PATCHes it back whole; a 10 s stale body would
# silently erase a marker another lane (or a human) wrote in that window, both lanes exiting 0. The
# cache therefore covers the ETag-free surface only, and this pins the boundary.
reset_env c1 coreok
run coreok api repos/o/r/pulls/7 --jq .body >/dev/null 2>&1
run coreok api repos/o/r/pulls/7 --jq .body >/dev/null 2>&1
ck "(c1) two .body reads make TWO requests (no stale body to write back)" \
   $([ "$(reqs 'pulls/7')" -eq 2 ] && echo 0 || echo 1)

printf '\n── (c2) the GraphQL SUBCOMMAND path is cached too (it has no ETag at all) ───────────────────\n'
reset_env c2 coreok
for i in 1 2 3; do run coreok pr view 7 --json headRefOid ; done
ck "(c2) 3 identical 'gh pr view' reads made 1 request" $([ "$(reqs 'pr view 7')" -eq 1 ] && echo 0 || echo 1)
ck "(c2) all 3 got the answer" $([ "$OUT" = '{"headRefOid":"graphqlsha"}' ] && echo 0 || echo 1)

# ⛔ AND THIS HOLDS EVEN WITH THE ETag PATH OFF: the boundary is the API SURFACE, not the switch.
reset_env c3b coreok
unset GH_LIMIT_CONDITIONAL
run coreok api repos/o/r/pulls/7 >/dev/null 2>&1
run coreok api repos/o/r/pulls/7 >/dev/null 2>&1
ck "(c3b) with conditional OFF an api GET is still NOT TTL-cached (2 requests)" \
   $([ "$(reqs 'pulls/7')" -eq 2 ] && echo 0 || echo 1)

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
for i in 1 2 3 4 5; do run coreok pr view 7 --json headRefOid ; done
n="$(reqs 'pr view 7')"
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
run coreok --health >/dev/null 2>&1 || true
health coreok
ck "(f) --health reports gh-ok and exits 0" $(printf '%s' "$OUT" | grep -q '^gh-ok$' && [ "$RC" -eq 0 ] && echo 0 || echo 1)

echo "── (g) a PARTIAL equivalence must never answer with null+0 (review finding 1) ─────────────────"
# `jq` prints null for a field that is absent and exits 0, so a partly-reproduced REST body is an
# EMPTY ANSWER WITH A SUCCESS STATUS. A projection outside the encoder's field set must not be served.
reset_env g core0
budget core0
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7 --jq .requested_reviewers
ck "(g) an unreproducible projection is REFUSED, not answered as null" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(g) … and NO failover request was spent on it" $([ "$(reqs 'api graphql')" -eq 0 ] && echo 0 || echo 1)
ck "(g) … and it says why (the field is not reproducible)" \
   $(grep -q 'encoder cannot' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '[.base.sha,.head.sha,.base.ref,.body]|@tsv'
ck "(g) the DEEP fields in-tree callers read (.base.sha/.base.ref/.body) ARE reproduced" \
   $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'basesha' && printf '%s' "$OUT" | grep -q 'prbody' && echo 0 || echo 1)

echo "── (h) BOTH pools empty keeps the NAMED state (review finding 2) ─────────────────────────────"
reset_env h graphqldead
budget graphqldead
run graphqldead api repos/o/r/pulls/7
ck "(h) the both-pools refusal still names the state" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=' && echo 0 || echo 1)
health graphqldead
ck "(h) --health does NOT report gh-ok while the core record is still live" \
   $(printf '%s' "$OUT" | grep -q '^gh-core-exhausted resets_in=12m$' && [ "$RC" -eq 3 ] && echo 0 || echo 1)
run graphqldead api repos/o/r/pulls/7 --jq .head.sha
ck "(h) the SECOND core read still fails over rather than being sent to the empty pool" \
   $([ "$(reqs 'api graphql')" -ge 1 ] && echo 0 || echo 1)

echo "── (i) a GraphQL-served read must NOT mark the CORE bucket recovered (finding 3) ──────────────"
reset_env i core0
unset GH_LIMIT_NO_WAIT
run core0 api repos/o/r/pulls/7          # lane A: refusal + the one exempt probe records core
run core0 api repos/o/r/pulls/7 --jq .head.sha   # lane B: served from GraphQL
ck "(i) lane B was served from GraphQL" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
ck "(i) the core record is NOT annotated recovered by it" \
   $(grep -q 'bucket=core' "$GH_LIMIT_DIR/last-limit" && ! grep -q 'recovered=' "$GH_LIMIT_DIR/last-limit" && echo 0 || echo 1)
export GH_LIMIT_NO_WAIT=1

: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7 --jq .head.sha   # a LATER lane, budget snapshot expired by design
ck "(i) a later lane still fails over (the evidence survived)" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "abc123" ] && [ "$(reqs 'pulls/7')" -eq 0 ] && echo 0 || echo 1)

echo "── (j) the LOW-WATER band reserves the pool for WRITES and never claims exhaustion ─────────────"
# core=50: reads move to GraphQL to keep the tail, writes SPEND it (that is what the reserve is for),
# and nothing asserts “exhausted” while 50 requests of budget exist.
reset_env j low
budget low
: > "$STUB_LOG"
run low api repos/o/r/pulls/7 --jq .head.sha
ck "(j) a read in the band moves to GraphQL (the tail is preserved)" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'api graphql')" -eq 1 ] && echo 0 || echo 1)
health low
ck "(j) and it does NOT claim the pool is exhausted" \
   $(printf '%s' "$OUT" | grep -q '^gh-ok$' && echo 0 || echo 1)
run low api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(j) a WRITE in the band is SENT (the reserve is spent by writes)" \
   $([ "$(reqs 'pulls/7/merge')" -eq 1 ] && echo 0 || echo 1)

echo "── (g2) the projections REAL in-tree callers use ──────────────────────────────────────────────"
# Pinned by READING the call sites, so a future tightening of PULL_NAMES cannot silently disable the
# failover for the review recorder, and a future loosening cannot serve a WRONG field to the rail:
#   record-review.sh:1117  [.base.sha,.head.sha,.base.ref]|@tsv              -> served
#   record-review.sh:2143  [(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv -> served
#   admin-merge.sh:2085    "\(.mergeable)" + "\t" + (.merge_commit_sha // "")  -> REFUSED
#   admin-merge.sh:7459    .merge_commit_sha // ""                          -> REFUSED
# ⛔ The rail's two are refused ON PURPOSE. REST's `merge_commit_sha` for an UNMERGED PR is the
# tentative test-merge commit and GraphQL's `mergeCommit` is null there, so reproducing the name from
# that field would report the merge ref as ABSENT for every open PR and the rail would BLOCK with
# “no CI run has evaluated the merge of this PR into its base” — a fabricated CI diagnosis.
reset_env g2 core0
budget core0
run core0 api repos/o/r/pulls/7 --jq '[.base.sha,.head.sha,.base.ref]|@tsv'
ck "(g2) record-review.sh:1117 projection is served" $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'basesha' && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv'
ck "(g2) record-review.sh:2143 projection (with a jq FUNCTION) is served" \
   $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '3' && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '"\(.mergeable)" + "\t" + (.merge_commit_sha // "")'
ck "(g2) the rail's merge-ref read is REFUSED (no faithful GraphQL source) rather than answered null" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '.merge_commit_sha // ""'
ck "(g2) … and so is the bare .merge_commit_sha projection" $([ "$RC" -ne 0 ] && echo 0 || echo 1)

echo "── (g3) the projection gate cannot be escaped by a clever jq ────────────────────────────────"
# Round-2 finding: the first scan only saw `.name`, so all of these returned null/subsets with rc 0.
reset_env g3 core0
budget core0
i=0
for prog in '.["requested_reviewers"]' ".[\"url\"]" 'getpath(["requested_reviewers"])' 'keys' 'to_entries' '..|.body' '.' '.|.' '.head' '.user' '. | select(.state=="open")' '.body, .' 'select(.merged)' 'first.body'; do
  i=$((i + 1))
  run core0 api repos/o/r/pulls/7 --jq "$prog"
  ck "(g3) escaped projection #$i is REFUSED: $prog" \
     $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
done
run core0 api repos/o/r/pulls/7 --jq '.["body"]'
ck "(g3) while an ALLOWED bracketed name is still served" $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'prbody' && echo 0 || echo 1)

echo "── (h2) a refusal that carried NO reset is still a named state (review finding 4) ────────────"
# Every GH_LIMIT_NO_WAIT caller skips the probe, so the give-up path can record reset=0. Deriving
# “healthy” from that made --health say gh-ok exactly while the pool was spent and nothing failed over.
reset_env h2 core0
unset GH_LIMIT_NO_WAIT
export GH_LIMIT_NO_WAIT=1
run core0 api repos/o/r/pulls/7
ck "(h2) the headerless refusal is REFUSED by name" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted' && echo 0 || echo 1)
health core0
ck "(h2) --health does NOT report gh-ok for an undated refusal" \
   $(printf '%s' "$OUT" | grep -q '^gh-core-exhausted resets_in=' && [ "$RC" -eq 3 ] && echo 0 || echo 1)
reset_env h2b core0
budget core0
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(h2) … and a later read still fails over from it" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'api graphql')" -eq 1 ] && echo 0 || echo 1)

echo "── (j2) the low-water band + a GraphQL failure must NOT fake exhaustion ──────────────────────"
# Round-2 finding: the failover-FAILURE branch wrote `gh-core-exhausted remaining=0` in the band, so
# every WRITE on the box was then refused without spending a request while 50 calls remained.
reset_env j2 low
budget low
run low api repos/o/r/pulls/7 --jq .head.sha >/dev/null 2>&1 || true
health low
ck "(j2) a read in the band never writes an exhaustion record" \
   $(printf '%s' "$OUT" | grep -q '^gh-ok$' && echo 0 || echo 1)
unset GH_TEST_SCENARIO
reset_env j3 low
budget low
run graphqldead api repos/o/r/pulls/7 --jq .head.sha
ck "(j3) band + GraphQL refused => the failure names GRAPHQL, not an empty core pool" \
   $(printf '%s' "$ERR" | grep -q 'gh-graphql-unavailable' && echo 0 || echo 1)
health low
ck "(j3) and it does NOT claim the pool is exhausted" \
   $(printf '%s' "$OUT" | grep -q '^gh-ok$' && echo 0 || echo 1)
: > "$STUB_LOG"
run low api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(j3) so a WRITE in the band is still SENT" $([ "$(reqs 'pulls/7/merge')" -eq 1 ] && echo 0 || echo 1)

echo "── (h3) UNDATED evidence DIVERTS a read but must never REFUSE one ────────────────────────────"
# A refusal that carried no reset cannot say when the window ends. Letting it refuse pre-emptively
# parks the box for the whole fallback window with no way back: no core call is attempted, so
# `record_core_ok` never fires and the record cannot clear itself. Attempting the read IS the cure —
# one request re-records the truth, and a success clears the state.
reset_env h3 core0
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run core0 api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(h3) a read with NO equivalent is still ATTEMPTED (1 request), not refused pre-emptively" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'protection')" -eq 1 ] && echo 0 || echo 1)
ck "(h3) … and its success CLEARS the undated record (the box can recover itself)" \
   $([ ! -f "$GH_LIMIT_DIR/health" ] && echo 0 || echo 1)
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(h3) while a read WITH an equivalent is still DIVERTED to GraphQL" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'api graphql')" -eq 1 ] && [ "$(reqs 'pulls/7')" -eq 0 ] && echo 0 || echo 1)

echo "── (b4) a RAW body (no --jq) is not served: a subset is an absent-field answer ────────────────"
# Round-3 finding: with no projection the encoder's subset went straight to a raw-body consumer, and
# `gh-rest/gh` projects `labels`/`assignees`/`mergeStateStatus` — a labelled PR read back as `[]` with
# rc 0. A body we cannot make complete is refused, not approximated.
reset_env b4 core0
budget core0
run core0 api repos/o/r/pulls/7
ck "(b4) a --jq-less read is REFUSED (no subset body with rc 0)" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(b4) … with the named state" $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted' && echo 0 || echo 1)

echo "── (h4) a DIVERTED read must not promote an UNDATED record into a dated one (round-3 B1) ──────"
# `health_state` returns a synthetic window end so undated evidence can EXPIRE; persisting it turned
# “I was refused once” into “core is empty until T+15m”, and nothing could clear it (a success is the
# only cure, and no core call was being attempted).
reset_env h4 core0
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(h4) the read is diverted to GraphQL" $([ "$RC" -eq 0 ] && [ "$(reqs 'api graphql')" -eq 1 ] && echo 0 || echo 1)
ck "(h4) the record is STILL undated (no invented reset was written)" \
   $(grep -q 'reset=0' "$GH_LIMIT_DIR/health" && echo 0 || echo 1)
: > "$STUB_LOG"
run core0 api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(h4) so a WRITE is still SENT rather than refused pre-emptively" \
   $([ "$(reqs 'pulls/7/merge')" -eq 1 ] && echo 0 || echo 1)

echo "── (k) a SECONDARY refusal on the core bucket is not “exhausted” (round-3 B2) ────────────────"
# A burst refusal carries `x-ratelimit-remaining: 3200`. Naming it gh-core-exhausted froze every write
# for up to an hour on a pool with thousands of requests left.
reset_env k secondary
export GH_LIMIT_CONDITIONAL=1
export GH_LIMIT_NO_WAIT=1
: > "$STUB_LOG"
run secondary api repos/o/r/pulls/7
ck "(k) the burst refusal FAILS loudly" $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(k) it is named as a SECONDARY limit, not as an empty pool" \
   $(printf '%s' "$ERR" | grep -q 'gh-secondary-rate-limited remaining=3200' && echo 0 || echo 1)
ck "(k) and it does NOT claim gh-core-exhausted" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted' && echo 1 || echo 0)
health secondary
ck "(k) --health stays gh-ok (the pool was never empty)" \
   $(printf '%s' "$OUT" | grep -q '^gh-ok$' && echo 0 || echo 1)
: > "$STUB_LOG"
run secondary api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(k) so the next WRITE is still SENT" $([ "$(reqs 'pulls/7/merge')" -eq 1 ] && echo 0 || echo 1)
unset GH_LIMIT_CONDITIONAL

echo "── (k2) an ABSENT remaining counter is UNKNOWN, not zero (round-4 B2) ────────────────────────"
# A secondary refusal may carry a reset and NO remaining counter. Persisting that reset as a dated
# “pool is empty” claim refused writes for up to an hour on a pool with 3000 requests left.
reset_env k2 shl
export GH_LIMIT_CONDITIONAL=1
export GH_LIMIT_NO_WAIT=1
: > "$STUB_LOG"
run shl api repos/o/r/pulls/7
ck "(k2) the headerless-counter refusal FAILS loudly" $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(k2) the durable record carries NO invented reset (undated evidence)" \
   $(grep -q 'reset=0' "$GH_LIMIT_DIR/health" && echo 0 || echo 1)
: > "$STUB_LOG"
run shl api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(k2) so the next WRITE is still SENT" $([ "$(reqs 'pulls/7/merge')" -eq 1 ] && echo 0 || echo 1)
unset GH_LIMIT_CONDITIONAL

echo "── (l) a 304 must NOT clear the exhaustion evidence (round-5 B1) ──────────────────────────────"
# A revalidated 304 is exempt from the primary limit BY DESIGN, so it is not a successful core call.
# Counting it as one unlinked the health record and marked the record recovered — after which no lane
# on the box failed over and --health said gh-ok on a spent pool.
reset_env l coreok
unset GH_LIMIT_CONDITIONAL              # exercise the ETag path
: > "$STUB_LOG"
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(l) the first read primes the ETag cache (1 request)" $([ "$RC" -eq 0 ] && [ "$(reqs 'protection')" -eq 1 ] && echo 0 || echo 1)
# now make the budget say core is EMPTY, dated, and named
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(l) the cached validator is used (the request is SENT, not refused pre-emptively)" \
   $([ "$(reqs 'protection')" -eq 1 ] && echo 0 || echo 1)
ck "(l) the answer is rc 0 (a 304 is a success for the caller)" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
ck "(l) BUT the exhaustion evidence SURVIVES (health not unlinked)" \
   $([ -f "$GH_LIMIT_DIR/health" ] && echo 0 || echo 1)
health l
ck "(l) and --health still names it" $(printf '%s' "$OUT" | grep -q '^gh-core-exhausted resets_in=' && echo 0 || echo 1)
ck "(l) the durable core record is NOT annotated recovered" \
   $( { [ ! -f "$GH_LIMIT_DIR/last-limit" ] || ! grep -q 'recovered=' "$GH_LIMIT_DIR/last-limit"; } && echo 0 || echo 1)

echo "── (m) ROUND 6: three spellings, two modelled — and a health verb that ignored the meter ──"
# ⛔ A REGRESSION SUITE FOR THE DEFECTS FOUND AFTER THE FOUR REQUIRED CASES PASSED. Each one below was
# reproduced against the layer before it was fixed; the failure each prevents is named in the
# assertion, because a test whose failure message is the label survives being made vacuous.
reset_env m core0
budget core0

# (m1) jq's THIRD key spelling. `.name` and `.["name"]` were modelled; `."name"` set no leaf and
# refused nothing, so a program naming ONE allowed leaf alongside it was admitted and jq printed null
# with rc 0 — the confident wrong answer, in the shape of a successful read.
run core0 api repos/o/r/pulls/7 --jq '[.state, ."requested_reviewers"]'
ck "(m1) the dot-quoted key is REFUSED (it used to answer [\"open\",null] rc 0)" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '"\(.mergeable)" + "\t" + (."merge_commit_sha" // "")'
ck "(m1) … so the rail's merge-ref read cannot be reached by QUOTING it (was rc 0 with an empty ref)" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '."requested_reviewers"'
ck "(m1) … and a quoted UNKNOWN key alone is refused, not silently null" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '."state"'
ck "(m1) while a quoted ALLOWED key is still served (the refusal is not blanket)" \
   $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'open' && echo 0 || echo 1)

# (m2) --health must agree with the meter IN BOTH DIRECTIONS. Reading only the durable record said
# `gh-ok` on a box whose own `--budget` probe had just measured core=0 — the incident's false-healthy
# line, printed by the verb an operator is told to trust.
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}, "graphql": {"remaining": 4000, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
rm -f "$GH_LIMIT_DIR/health"
health coreok
ck "(m2) a FRESH meter saying core=0 is named by --health (no refusal needed first)" \
   $([ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^gh-core-exhausted resets_in=[0-9]' && echo 0 || echo 1)
printf '{"at": %s, "core": {"remaining": 3000, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 3000 ))" > "$GH_LIMIT_DIR/budget.json"
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
health coreok
ck "(m2) … and a meter with headroom OUTRANKS a stale record (was a false 'exhausted')" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)
printf '{"at": %s, "core": {"remaining": 50, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
health coreok
ck "(m2) … and the LOW-WATER BAND (50 left) is not called exhausted" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

# (m3) an UNDATED record names a state WITHOUT a number nobody measured.
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
rm -f "$GH_LIMIT_DIR/budget.json"
health coreok
ck "(m3) an undated record is STILL a named state (was gh-ok for the 8 NO_WAIT callers' shape)" \
   $([ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^gh-core-exhausted' && echo 0 || echo 1)
ck "(m3) … and it does NOT print an invented resets_in=<Nm> (was 15m for a 12m window)" \
   $(printf '%s' "$OUT" | grep -q 'resets_in=?$' && echo 0 || echo 1)
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(( $(date +%s) - 1000 ))" > "$GH_LIMIT_DIR/health"
health coreok
ck "(m3) … but an undated record outlives its bound, like every other record here" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

# (m4) a DIVERTED read must not rewrite `remaining=?` to an observed `remaining=0`.
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
run core0 api repos/o/r/pulls/7 --jq '.state'
ck "(m4) the diverted read is still SERVED from GraphQL" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
ck "(m4) … and the record still says remaining=? (no number invented by the failover path)" \
   $(grep -q 'remaining=?' "$GH_LIMIT_DIR/health" && echo 0 || echo 1)

# (m5) READ_UNCACHEABLE_FLAGS was declared, documented and never read.
reset_env m5 coreok
for i in 1 2 3; do run coreok pr list --repo o/r --template '{{.number}}'; done
ck "(m5) a --template read is NOT cached (3 reads => 3 requests; was 1)" \
   $([ "$(reqs 'pr list')" -eq 3 ] && echo 0 || echo 1)
: > "$STUB_LOG"                       # count the two classes separately: they share one argv prefix
for i in 1 2 3; do run coreok pr list --repo o/r; done
ck "(m5) … while the plain shape still coalesces (3 reads => 1 request) [count=$(reqs 'pr list')]" \
   $([ "$(reqs 'pr list')" -eq 1 ] && echo 0 || echo 1)

echo "── (m6) ROUND 2: a DATED record must still REFUSE a write, and the SHORTHAND must not escape ──"
# (m6) The round-1 fix over-applied: returning `None` for BOTH arms removed the one durable record
# that survives a GraphQL refusal overwriting `last-limit`, so a known-empty DATED pool started
# SENDING writes into it (measured: 1 request spent against a record saying remaining=0).
reset_env m6 core0
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run core0 api -X POST repos/o/r/issues/7/comments -f body=hi
ck "(m6) a WRITE against a DATED empty record is refused by name" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(m6) … and it spends NO request (never retried into the empty pool)" \
   $([ "$(wc -l < "$STUB_LOG")" -eq 0 ] && echo 0 || echo 1)

# (m7) object-construction SHORTHAND `{name}` is `{name: .name}` — a key read with no dot, bracket
# or quote, so none of the three scans saw it (round-2 finding).
reset_env m7 core0
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
for prog in '[.state, {labels}]' '[{merge_commit_sha}, .state]' '.state, ([tostream])' '.state, [recurse]'; do
  run core0 api repos/o/r/pulls/7 --jq "$prog"
  ck "(m7) shorthand/stream escape is REFUSED: $prog" \
     $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
done
run core0 api repos/o/r/pulls/7 --jq '{a: .state}'
ck "(m7) while a real object construction is still served" \
   $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi 'open' && echo 0 || echo 1)

# (m8) “I could not read the record” is not “the pool is fine”.
reset_env m8 coreok
printf 'gh-core-exhausted at=%s\n' "$(date +%s)" > "$GH_LIMIT_DIR/health"
health coreok
ck "(m8) an UNPARSEABLE record fails closed with its own name (was gh-ok rc 0)" \
   $([ "$RC" -eq 3 ] && [ "$OUT" = "gh-health-unknown" ] && echo 0 || echo 1)
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) - 60 ))" > "$GH_LIMIT_DIR/health"
health coreok
ck "(m8) … while a DATED record whose window has PASSED is still gh-ok (that is an answer)" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

echo "── (m9) ROUND 3: a merge DECISION is not TTL-cached, and an aggregate is not a projection ────"
# (m9) `gh pr checks` used to be a 10 s class. Its answer AUTHORISES a merge (`merge-one.sh` breaks on
# SUCCESS and then merges unpinned), the cache key carries no head sha, so a stale SUCCESS could be
# served for a head that had already gone PENDING (measured: two reads 1 s apart across the flip both
# returned SUCCESS on ONE request).
reset_env m9 coreok
run coreok pr checks 7 --repo o/r --json name,state
a="$(reqs 'pr checks')"
run coreok pr checks 7 --repo o/r --json name,state
b="$(reqs 'pr checks')"
ck "(m9) two reads 1 s apart make TWO requests (was 1 — a stale SUCCESS for a new head)" \
   $([ "$a" -eq 1 ] && [ "$b" -eq 2 ] && echo 0 || echo 1)

# (m10) an AGGREGATE or a serialiser applied to the whole answer is an identity read spelled as
# arithmetic: `[.state, length]` answered 19 where the REST body answers 27, with rc 0.
reset_env m10 core0
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
for prog in '[.state, [.]]' '[.state, @json]' '[.state, tostring]' '[.state, length]' '.state, .[]'; do
  run core0 api repos/o/r/pulls/7 --jq "$prog"
  ck "(m10) aggregate/identity escape is REFUSED: $prog" \
     $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
done
run core0 api repos/o/r/pulls/7 --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv'
ck "(m10) while record-review.sh:2143's real projection is still served" \
   $([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'abc123' && echo 0 || echo 1)

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
