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
#   (n) the FLOOR (#2342): below `GH_LIMIT_CORE_FLOOR` a read that cannot fail over is refused BY
#       NAME — empty stdout, no request spent, no claim that the pool is empty — and a read that CAN
#       fail over is still served; `GH_LIMIT_ESSENTIAL=1` spends the reserve (the landing path).
#   (o) the INSTRUMENT (#2342): `--stats` reports the hits/misses coalesced shares the calls actually
#       wrote, and an empty box says `no-reads-counted` instead of inventing `averted=0`.
#   (p) the FLOOR CAN SEE (#2342 review P1): a core-only read with no snapshot and no durable record
#       spends ONE exempt `/rate_limit` probe, so a MEASURED-empty pool refuses it without sending it —
#       a healthy meter lets the same read through.
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
    elif [ "\${GH_TEST_SCENARIO:-}" = "floor" ]; then
      # 400 left: ABOVE the pre-#2342 reserve (100) and BELOW the #2342 floor (800) — exactly the
      # window in which the fleet used to spend the reserve on polling (#2342).
      printf '{"resources":{"core":{"limit":5000,"remaining":400,"reset":$RESET,"used":4600},"graphql":{"limit":5000,"remaining":4000,"reset":$RESET,"used":1000}}}\n'
    else
      printf '{"resources":{"core":{"limit":5000,"remaining":0,"reset":$RESET,"used":5000},"graphql":{"limit":5000,"remaining":4745,"reset":$RESET,"used":255}}}\n'
    fi
    ;;
  "api graphql")
    if [ "\${GH_TEST_SCENARIO:-}" = "graphqldead" ]; then
      printf 'API rate limit exceeded for user ID 81560491.\n' >&2
      exit 1
    fi
    # ⛔ THE REAL FAILURE SHAPE (#2342 review, P2). `gh api graphql` prints its ERROR DOCUMENT on
    # STDOUT, not stderr — so a fixture that only writes stderr (`graphqldead` above) cannot see a
    # failover arm that copies that body to the caller. This arm is the measured shape.
    if [ "\${GH_TEST_SCENARIO:-}" = "graphqldeadbody" ]; then
      printf '{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}\n'
      exit 1
    fi
    # Round-4 review: a CONNECTION that is absent, and one that is TRUNCATED, must not be answered as
    # if it were complete (a missing `reviews` key answered rc 0 with an empty list; 150 reviews
    # answered the first 100 as if that were all of them).
    if [ "\${GH_TEST_SCENARIO:-}" = "noreviews" ]; then
      printf '{"data":{"repository":{"pullRequest":{"number":7,"state":"OPEN"}}}}\n'
      exit 0
    fi
    if [ "\${GH_TEST_SCENARIO:-}" = "reviewsnext" ]; then
      printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":true},"nodes":[{"databaseId":1,"state":"APPROVED"}]}}}}}\n'
      exit 0
    fi
    if [ "\${GH_TEST_SCENARIO:-}" = "nopi" ]; then
      printf '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"databaseId":1,"state":"APPROVED"}]}}}}}\n'
      exit 0
    fi
    if [ "\${GH_TEST_SCENARIO:-}" = "reviewsok" ]; then
      printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":1,"state":"APPROVED","body":"b","submittedAt":"x","commit":{"oid":"c1"},"author":{"login":"daniel-ospina"}}]}}}}}\n'
      exit 0
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
          if [ "\${GH_TEST_SCENARIO:-}" = "etagchg" ]; then
            # the resource CHANGED, so the conditional GET is NOT free: this is the case that used to be
            # retried into the pool the layer had measured as empty
            printf 'HTTP/2.0 200 OK\r\nETag: "e2"\r\nContent-Type: application/json\r\n\r\n{"contexts":["pipeline-compliance"]}\r\n'
            exit 0
          fi
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
  unset GH_LIMIT_ESSENTIAL GH_LIMIT_CORE_FLOOR GH_LIMIT_CORE_LOW_WATER 2>/dev/null || true
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

stats() {  # the --stats VERB: local counters only — no request, no credentials, no quota
  python3 "$HELPER" --stats >"$TMP/out" 2>"$TMP/err"
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
   $(grep -q '^core=0/5000 resets_in=12m graphql=4745/5000' <<<"$OUT" && echo 0 || echo 1)
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
   $(grep -q '^gh-core-exhausted resets_in=12m$' <<<"$OUT" && echo 0 || echo 1)
ck "(a) --health exits 3 (a NAMED state, not a generic failure)" $([ "$RC" -eq 3 ] && echo 0 || echo 1)

echo "── (a2) the fleet LEARNS: ONE refusal + ONE exempt probe makes every later lane fail over ────"
# The property that makes this survivable at 2am. Lane A is a controller-like caller (it may defer),
# so on its refusal the layer spends ONE exempt `/rate_limit` read and records BOTH pools. Lane B is a
# bounded caller and must spend NO probe of its own: it reads the record and fails over. If every lane
# had to probe to discover the pool was empty, the failover would cost the budget it exists to save.
reset_env a2 core0
# ⛔ PRIME A HEALTHY SNAPSHOT ON PURPOSE (#2342). With no snapshot the layer now MEASURES the meter
# before a read that cannot fail over and refuses it instantly — which is the new, better behaviour,
# and it is pinned by (p) below. This case is about the OTHER path: a read that WAS SENT, refused, and
# then bounded by the in-call rule, so the snapshot is primed healthy and the pool unknown-to-empty.
budget coreok
unset GH_LIMIT_NO_WAIT
: > "$STUB_LOG"
run core0 api repos/o/r/pulls/7                  # lane A: refused, then the documented deferral
ck "(a2) lane A's read was REFUSED" $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(a2) the refusal cost exactly ONE exempt meter read, which recorded both pools" \
   $([ "$(reqs 'api rate_limit')" -eq 1 ] && [ -f "$GH_LIMIT_DIR/budget.json" ] && echo 0 || echo 1)
ck "(a2) lane A did NOT wait out a 12-minute reset (the in-call bound holds)" \
   $(grep -q 'beyond the 300s in-call bound' <<<"$ERR" && echo 0 || echo 1)
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
   $(grep -q 'gh-core-exhausted resets_in=' <<<"$ERR" && echo 0 || echo 1)
ck "(b) stderr also keeps the classifier's marker ('rate limit')" \
   $(grep -qi 'rate limit' <<<"$ERR" && echo 0 || echo 1)
ck "(b) the message says it is NOT a broken repo/token (no false diagnosis)" \
   $(grep -q 'not a broken repo' <<<"$ERR" && echo 0 || echo 1)

# ⛔ (b3) THE SAME CONTRACT AGAINST THE REAL FAILURE SHAPE (#2342 review, P2). `graphqldead` writes
# only to stderr, so it could never prove "empty stdout" for an arm that forwards the GraphQL child's
# stdout — and on the real CLI that stdout carries `{"data":null,"errors":[…]}`. A caller that reacts
# to emptiness/`-n` instead of the exit status (the pattern `record-review.sh::target_head_red` was
# fixed for) would be handed a foreign document. NON-VACUOUS: on the pre-fix arm this block's first
# assertion fails, because the error body IS written to stdout.
reset_env b3 graphqldeadbody
budget graphqldeadbody
run graphqldeadbody api repos/o/r/pulls/7 --jq .head.sha
ck "(b3) a GraphQL error body on the CHILD's stdout still fails the call (rc != 0)" \
   $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(b3) …and stdout is EMPTY — the caller's own --jq shape is never replaced by a foreign document" \
   $([ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(b3) …and the diagnosis is still on STDERR (the streams stay sacred, both ways)" \
   $(grep -q 'gh-core-exhausted resets_in=' <<<"$ERR" && echo 0 || echo 1)

echo "── (b2) a read with NO exact GraphQL equivalent is REFUSED, not approximated ─────────────────"
reset_env b2 core0
budget core0
: > "$STUB_LOG"
run core0 api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(b2) the protection read FAILS instead of answering an empty context set" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(b2) it was NEVER SENT (no request for a call that cannot succeed)" $([ "$(reqs 'required_status_checks')" -eq 0 ] && echo 0 || echo 1)
ck "(b2) stderr NAMES the state and says why it was not approximated" \
   $(grep -q 'gh-core-exhausted' <<<"$ERR" && grep -q 'NO exact GraphQL equivalent' <<<"$ERR" && echo 0 || echo 1)

echo "── (b3) a WRITE is never failed over and never retried into the empty pool ───────────────────"
reset_env b3 core0
budget core0
: > "$STUB_LOG"
run core0 api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash
ck "(b3) the merge attempt FAILS, named, with no request spent" \
   $([ "$RC" -ne 0 ] && [ "$(reqs 'merge')" -eq 0 ] && grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)
ck "(b3) it says the call WRITES and was not retried" \
   $(grep -q 'WRITES' <<<"$ERR" && echo 0 || echo 1)

echo "── (c) the ETag-free SUBCOMMAND surface is cached: N identical reads => ONE request ───────────"
# ⛔ THE CACHED CLASS IS A NON-DECISION ONE. `pr view --json headRefOid` is the head a merge and the
# review evidence are bound to, so it is NOT a TTL class (round 5) — the positive case here is the board
# listing, whose bounded staleness costs no verdict.
reset_env c coreok
for i in 1 2 3 4 5; do run coreok pr list --repo o/r ; done
ck "(c) 5 identical 'gh pr list' reads made 1 request" $([ "$(reqs 'pr list')" -eq 1 ] && echo 0 || echo 1)
ck "(c) every one of the 5 returned the answer" $(grep -q '"number":1' <<<"$OUT" && echo 0 || echo 1)
ck "(c) the hit is RECORDED in events.log" $(grep -q 'read-cache: pr-list hit' "$GH_LIMIT_DIR/events.log" && echo 0 || echo 1)
: > "$STUB_LOG"
for i in 1 2 3; do run coreok pr view 7 --json headRefOid ; done
ck "(c) while the HEAD (a decision input) is NOT cached: 3 reads => 3 requests" \
   $([ "$(reqs 'pr view 7')" -eq 3 ] && echo 0 || echo 1)

echo "── (c1) a read-modify-write surface is NEVER TTL-cached (round-5 lost update) ───────────────�"
# `record-review.sh:2356` reads `pulls/{n}`'s .body and PATCHes it back whole; a 10 s stale body would
# silently erase a marker another lane (or a human) wrote in that window, both lanes exiting 0. The
# cache therefore covers the ETag-free surface only, and this pins the boundary.
reset_env c1 coreok
run coreok api repos/o/r/pulls/7 --jq .body >/dev/null 2>&1
run coreok api repos/o/r/pulls/7 --jq .body >/dev/null 2>&1
ck "(c1) two .body reads make TWO requests (no stale body to write back)" \
   $([ "$(reqs 'pulls/7')" -eq 2 ] && echo 0 || echo 1)

printf '\n── (c2) the GraphQL SUBCOMMAND path is cached too, for the non-decision class ─────────────────\n'
reset_env c2 coreok
for i in 1 2 3; do run coreok pr list --repo o/r ; done
ck "(c2) 3 identical 'gh pr list' reads made 1 request (GraphQL has no ETag at all)" \
   $([ "$(reqs 'pr list')" -eq 1 ] && echo 0 || echo 1)
ck "(c2) all 3 got the answer" $(grep -q '"number":1' <<<"$OUT" && echo 0 || echo 1)

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
ck "(c4) every poll got the run list" $(grep -q '39786847846' <<<"$OUT" && echo 0 || echo 1)

echo "── (d) MUTATION: GH_LIMIT_READ_CACHE=0 must make (c) fail ────────────────────────────────────"
reset_env d coreok
export GH_LIMIT_READ_CACHE=0
for i in 1 2 3 4 5; do run coreok pr list --repo o/r ; done
n="$(reqs 'pr list')"
ck "(d) with the cache disabled the same 5 reads make 5 requests (was 1) — n=$n" \
   $([ "$n" -eq 5 ] && echo 0 || echo 1)
unset GH_LIMIT_READ_CACHE

echo "── (e) MUTATION: GH_LIMIT_FAILOVER=0 must make (a) fail ──────────────────────────────────────"
reset_env e core0
# a DATED-EMPTY snapshot: the pool is MEASURED empty, which is what makes the pre-emptive refusal
# (and therefore the "nothing was sent" assertion below) meaningful.
budget core0
export GH_LIMIT_FAILOVER=0
run core0 api repos/o/r/pulls/7 --jq .head.sha
ck "(e) with the failover disabled the core-exhausted read fails" $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(e) and it says the right thing (named state, not a generic unreadable)" \
   $(grep -q 'gh-core-exhausted resets_in=' <<<"$ERR" && echo 0 || echo 1)
# ⛔ (review P2) THE POINT OF THE KILL-SWITCH FIX IS THAT NOTHING IS SENT. Before it, turning the
# failover off ALSO disabled the floor and the dated-empty write guard, so this read went into a
# measured-empty pool — and since the stub refuses it too, "rc!=0 + named state" cannot tell the two
# versions apart. Assert the REQUESTS, or that regression passes the whole suite.
ck "(e) … and NOTHING was sent into the measured-empty pool" \
   $([ "$(reqs 'pulls/7')" -eq 0 ] && echo 0 || echo 1)
ck "(e) … and no failover was attempted" $([ "$(reqs 'api graphql')" -eq 0 ] && echo 0 || echo 1)
unset GH_LIMIT_FAILOVER

echo "── (f) the healthy path is unchanged and clears the named state ──────────────────────────────"
reset_env f coreok
run coreok api repos/o/r/pulls/7
ck "(f) a normal core read still succeeds through the plain path" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
run coreok --health >/dev/null 2>&1 || true
health coreok
ck "(f) --health reports gh-ok and exits 0" $(grep -q '^gh-ok$' <<<"$OUT" && [ "$RC" -eq 0 ] && echo 0 || echo 1)

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
   $([ "$RC" -eq 0 ] && grep -q 'basesha' <<<"$OUT" && grep -q 'prbody' <<<"$OUT" && echo 0 || echo 1)

echo "── (h) BOTH pools empty keeps the NAMED state (review finding 2) ─────────────────────────────"
reset_env h graphqldead
budget graphqldead
run graphqldead api repos/o/r/pulls/7
ck "(h) the both-pools refusal still names the state" \
   $(grep -q 'gh-core-exhausted resets_in=' <<<"$ERR" && echo 0 || echo 1)
health graphqldead
ck "(h) --health does NOT report gh-ok while the core record is still live" \
   $(grep -q '^gh-core-exhausted resets_in=12m$' <<<"$OUT" && [ "$RC" -eq 3 ] && echo 0 || echo 1)
run graphqldead api repos/o/r/pulls/7 --jq .head.sha
ck "(h) the SECOND core read still fails over rather than being sent to the empty pool" \
   $([ "$(reqs 'api graphql')" -ge 1 ] && echo 0 || echo 1)

echo "── (i) a GraphQL-served read must NOT mark the CORE bucket recovered (finding 3) ──────────────"
reset_env i core0
budget coreok                            # a primed snapshot: the read is SENT and refused on its own
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
   $(grep -q '^gh-ok$' <<<"$OUT" && echo 0 || echo 1)
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
ck "(g2) record-review.sh:1117 projection is served" $([ "$RC" -eq 0 ] && grep -q 'basesha' <<<"$OUT" && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv'
ck "(g2) record-review.sh:2143 projection (with a jq FUNCTION) is served" \
   $([ "$RC" -eq 0 ] && grep -q '3' <<<"$OUT" && echo 0 || echo 1)
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
ck "(g3) while an ALLOWED bracketed name is still served" $([ "$RC" -eq 0 ] && grep -q 'prbody' <<<"$OUT" && echo 0 || echo 1)

echo "── (h2) a refusal that carried NO reset is still a named state (review finding 4) ────────────"
# Every GH_LIMIT_NO_WAIT caller skips the probe, so the give-up path can record reset=0. Deriving
# “healthy” from that made --health say gh-ok exactly while the pool was spent and nothing failed over.
reset_env h2 core0
unset GH_LIMIT_NO_WAIT
export GH_LIMIT_NO_WAIT=1
run core0 api repos/o/r/pulls/7
ck "(h2) the headerless refusal is REFUSED by name" \
   $(grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)
health core0
ck "(h2) --health does NOT report gh-ok for an undated refusal" \
   $(grep -q '^gh-core-exhausted resets_in=' <<<"$OUT" && [ "$RC" -eq 3 ] && echo 0 || echo 1)
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
   $(grep -q '^gh-ok$' <<<"$OUT" && echo 0 || echo 1)
unset GH_TEST_SCENARIO
reset_env j3 low
budget low
run graphqldead api repos/o/r/pulls/7 --jq .head.sha
ck "(j3) band + GraphQL refused => the failure names GRAPHQL, not an empty core pool" \
   $(grep -q 'gh-graphql-unavailable' <<<"$ERR" && echo 0 || echo 1)
health low
ck "(j3) and it does NOT claim the pool is exhausted" \
   $(grep -q '^gh-ok$' <<<"$OUT" && echo 0 || echo 1)
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
   $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
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
ck "(b4) … with the named state" $(grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)

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
   $(grep -q 'gh-secondary-rate-limited remaining=3200' <<<"$ERR" && echo 0 || echo 1)
ck "(k) and it does NOT claim gh-core-exhausted" \
   $(grep -q 'gh-core-exhausted' <<<"$ERR" && echo 1 || echo 0)
health secondary
ck "(k) --health stays gh-ok (the pool was never empty)" \
   $(grep -q '^gh-ok$' <<<"$OUT" && echo 0 || echo 1)
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
ck "(l) the first read primes the ETag cache (1 request)" $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
# now make the budget say core is EMPTY, dated, and named
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(l) the cached validator is used (the request is SENT, not refused pre-emptively)" \
   $([ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
ck "(l) the answer is rc 0 (a 304 is a success for the caller)" $([ "$RC" -eq 0 ] && echo 0 || echo 1)
ck "(l) BUT the exhaustion evidence SURVIVES (health not unlinked)" \
   $([ -f "$GH_LIMIT_DIR/health" ] && echo 0 || echo 1)
health l
ck "(l) and --health still names it" $(grep -q '^gh-core-exhausted resets_in=' <<<"$OUT" && echo 0 || echo 1)
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
   $([ "$RC" -eq 0 ] && grep -qi 'open' <<<"$OUT" && echo 0 || echo 1)

# (m2) --health must agree with the meter IN BOTH DIRECTIONS. Reading only the durable record said
# `gh-ok` on a box whose own `--budget` probe had just measured core=0 — the incident's false-healthy
# line, printed by the verb an operator is told to trust.
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}, "graphql": {"remaining": 4000, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
rm -f "$GH_LIMIT_DIR/health"
health coreok
ck "(m2) a FRESH meter saying core=0 is named by --health (no refusal needed first)" \
   $([ "$RC" -eq 3 ] && grep -q '^gh-core-exhausted resets_in=[0-9]' <<<"$OUT" && echo 0 || echo 1)
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
   $([ "$RC" -eq 3 ] && grep -q '^gh-core-exhausted' <<<"$OUT" && echo 0 || echo 1)
ck "(m3) … and it does NOT print an invented resets_in=<Nm> (was 15m for a 12m window)" \
   $(grep -q 'resets_in=?$' <<<"$OUT" && echo 0 || echo 1)
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
   $([ "$RC" -eq 0 ] && grep -qi 'open' <<<"$OUT" && echo 0 || echo 1)

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
   $([ "$RC" -eq 0 ] && grep -q 'abc123' <<<"$OUT" && echo 0 || echo 1)

echo "── (m11) ROUND 4: the RAIL's own merge shape, and a list that is not the list ──────────────────"
# (m11) `bucket_for` labels `gh pr merge` as `graphql` (it is not in REST_SUBCOMMANDS), but
# `gh-rest/gh` TRANSLATES that command into a core REST write — and passes `--admin` through verbatim,
# which is exactly what `admin-merge.sh` sends. So the write guard, gated on `bucket == core`, never
# fired for the one write that matters: measured, the merge was SENT into a dated-empty core pool and
# the refusal was recorded against the wrong bucket, leaving no named state at all.
reset_env m11 coreok
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run coreok pr merge 7 --admin --squash --match-head-commit abc123
ck "(m11) the RAIL's merge shape is refused by name against a DATED empty core record" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)
ck "(m11) … and it spends NO request (was 1 request + a 64 s wait + a retry)" \
   $([ ! -s "$STUB_LOG" ] && echo 0 || echo 1)

# (m12) a MISSING connection is not an EMPTY one, and a TRUNCATED list is a different answer.
reset_env m12 core0
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
run noreviews api repos/o/r/pulls/7/reviews --jq '.[] | .state'
ck "(m12) a document with NO reviews connection is REFUSED (was rc 0, empty stdout)" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run reviewsnext api repos/o/r/pulls/7/reviews --jq '.[] | .state'
ck "(m12) a TRUNCATED reviews list is REFUSED (hasNextPage) rather than answered as complete" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run reviewsok api repos/o/r/pulls/7/reviews --jq '.[] | .state'
ck "(m12) … while a COMPLETE connection is still served" \
   $([ "$RC" -eq 0 ] && grep -q 'APPROVED' <<<"$OUT" && echo 0 || echo 1)

echo "── (m13) ROUND 6: the durable record, the container walk, and a verb nobody listed ─────────────"
# (m13) `--health` consulted the meter and the health file but NOT `last-limit` — the record every
# refused core call writes on EVERY attempt, which `core_pressure()` already trusts. So mid-backoff
# (the health file is written only when the layer gives up) a box refused every WRITE with zero
# requests and diverted every READ while `--health` printed `gh-ok` rc 0.
reset_env m13 coreok
printf 'at=%s bucket=core reset=%s attempts=1 waited=0 status=403 remaining=0\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/last-limit"
health coreok
ck "(m13) --health names the durable core refusal (was gh-ok while writes were refused)" \
   $([ "$RC" -eq 3 ] && grep -q '^gh-core-exhausted resets_in=[0-9]' <<<"$OUT" && echo 0 || echo 1)
printf 'at=%s bucket=core reset=%s recovered=%s remaining=0\n' \
  "$(( $(date +%s) - 5 ))" "$(( $(date +%s) + 700 ))" "$(( $(date +%s) - 1 ))" > "$GH_LIMIT_DIR/last-limit"
health coreok
ck "(m13) … while a RECOVERED record is not evidence (gh-ok)" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

# (m14) the allow-list is FLAT (root names), so walking THROUGH a partly-reproduced container reached a
# root name the container does not carry: `.user.html_url` answered `null` rc 0 where REST returns a URL.
reset_env m14 core0
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
for prog in '.user.html_url' '.head.user.login' '.base.user.login'; do
  run core0 api repos/o/r/pulls/7 --jq "$prog"
  ck "(m14) walking through a container to a name it does NOT carry is REFUSED: $prog" \
     $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
done
run core0 api repos/o/r/pulls/7 --jq '.user.login'
ck "(m14) … while a name the container DOES carry is served" \
   $([ "$RC" -eq 0 ] && grep -q 'daniel-ospina' <<<"$OUT" && echo 0 || echo 1)

# (m15) the bucket DEFAULT was `graphql` for any verb the tables had not listed, so an unlisted
# REST-backed write reached the core pool unguarded and its refusal was filed against a pool that was fine.
ck "(m15) an UNLISTED verb is bucketed core (the default is not 'graphql')" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.bucket_for(['codespace','delete','-c','x'])=='core' and m.bucket_for(['pr','view','7'])=='graphql' else 1)" && echo 0 || echo 1)"

# (m16) `if <path> then <literal> else <literal> end` is a projection and scripts/atomic-land.sh reads
# exactly that to turn `.merged` into MERGED/OPEN; refusing it made a LANDED PR read as still open for
# the whole confirmation wait.
run core0 api repos/o/r/pulls/7 --jq 'if .merged then "MERGED" else "OPEN" end'
ck "(m16) an if/then/else over a named field is SERVED" \
   $([ "$RC" -eq 0 ] && grep -q 'OPEN' <<<"$OUT" && echo 0 || echo 1)
run core0 api repos/o/r/pulls/7 --jq 'if .merge_commit_sha then "M" else "O" end'
ck "(m16) … and it cannot smuggle an unproducible field in" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)

# (m17) the connection window must be REST's page, not a wider one: REST's default page is 30, and the
# GraphQL window is now first:30 with the truncation guard, so the failover cannot answer 31-100 items
# where the read it replaces returned 30.
ck "(m17) the comments/reviews queries ask for REST's default page (first:30)" \
   "$(grep -q 'comments(first:30)' "$HELPER" && grep -q 'reviews(first:30)' "$HELPER" && echo 0 || echo 1)"

echo "── (m18) ROUND 7: an absent pageInfo, a passed meter window, and a write nobody listed ─────────"
# (m18) the truncation guard tested only `hasNextPage is True`, so an ABSENT/null `pageInfo` read as
# “complete” and a window truncated at first:30 was emitted as the whole list.
reset_env m18 core0
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
run nopi api repos/o/r/pulls/7/reviews --jq '.[] | .state'
ck "(m18) a connection with NO pageInfo is REFUSED (was served as complete)" \
   $([ "$RC" -ne 0 ] && [ ! -s "$TMP/out" ] && echo 0 || echo 1)
run reviewsok api repos/o/r/pulls/7/reviews --jq '.[] | .state'
ck "(m18) … while an explicit hasNextPage:false is still served" \
   $([ "$RC" -eq 0 ] && grep -q 'APPROVED' <<<"$OUT" && echo 0 || echo 1)

# (m19) a FRESH meter whose reset has already passed must still outrank an older dated record, or the
# operator's trusted verb announces a window the rail and the write guard both treat as closed.
reset_env m19 coreok
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) - 100 ))" > "$GH_LIMIT_DIR/budget.json"
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
health coreok
ck "(m19) a PASSED meter window outranks an older record (--health says gh-ok)" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

# (m20) a write whose verb the table did not know was diagnosed as a READ (“this READ has no exact
# GraphQL equivalent” about a mutation) and was not PACED, because pacing keys on the same predicate.
ck "(m20) secret/variable/cache/gist/codespace/ruleset writes are classified as MUTATIONS" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); bad=[a for a in (['secret','set','F','-b','x'],['variable','set','A','-b','1'],['cache','delete','-a'],['gist','create','f'],['codespace','delete','-c','x'],['ruleset','delete','1'],['repo','delete','o/r','--yes']) if not m.is_mutating(a)]; sys.exit(0 if not bad and not m.is_mutating(['pr','view','7']) else 1)" && echo 0 || echo 1)"

echo "── (m21) ROUND 8: an undated record that expires, an attached flag, and a null node ────────────"
# (m21) `record_core_exhausted` compared the meaning-carrying fields and excluded `at=`, so an UNDATED
# record (the shape every GH_LIMIT_NO_WAIT caller produces) kept its first stamp forever and aged out at
# at+900s — fifteen minutes into an ONGOING exhaustion `--health` said gh-ok, core_pressure said None,
# and the read was SENT into the empty pool with the rail back at “contract UNKNOWN”.
reset_env m21 coreok
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$(( $(date +%s) - 1000 ))" > "$GH_LIMIT_DIR/health"
ck "(m21) a repeated undated refusal RE-STAMPS the record (it must not age out mid-incident)" \
   "$(python3 -c "import importlib.util,os,sys,time; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.record_core_exhausted(None, None); line=open(os.path.join('$GH_LIMIT_DIR','health')).read().strip(); at=int(line.split('at=')[1].split()[0]); sys.exit(0 if abs(at-int(time.time()))<=3 else 1)" && echo 0 || echo 1)"
health coreok
ck "(m21) … so --health still names it instead of reporting gh-ok" \
   $([ "$RC" -eq 3 ] && grep -q '^gh-core-exhausted' <<<"$OUT" && echo 0 || echo 1)

# (m22) an ATTACHED short data flag before the endpoint (`gh api -fbody=x <path>`, a POST) made
# api_endpoint answer None, makes_request False, and the core-budget guard never ran: 7 requests and
# 439 s against a pool measured at zero, where the flag-after form spent nothing.
ck "(m22) an attached data flag before the endpoint still resolves the endpoint (and counts as a request)" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); a=['api','-fbody=x','repos/o/r/issues']; sys.exit(0 if m.api_endpoint(a)=='repos/o/r/issues' and m.makes_request(a) and m.is_mutating(a) else 1)" && echo 0 || echo 1)"

# (m23) GraphQL returns `null` for a node the viewer cannot see; `.get` on it raised and the caller got a
# Python traceback instead of the NAMED refusal (so objective.py could not read VERDICT=GH-RATE-LIMITED).
ck "(m23) a null node in a connection is REFUSED by name, not an AttributeError" \
   "$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('gl','$HELPER'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); _pi=dict(hasNextPage=False); _c=dict(pageInfo=_pi,nodes=[None]); _i=dict(comments=_c); d=dict(data=dict(repository=dict(issue=_i))); sys.exit(0 if m._enc_issue_comments(d) is None else 1)" && echo 0 || echo 1)"

# (m24) a HALF-WRITTEN budget.json is not a measurement: the sed parse read a torn document the layer's
# json.load rejects, so the rail announced an exhaustion `--health` called gh-ok.
reset_env m24 coreok
printf '{"at": %s, "core": {"remaining": 0, "reset": %s' "$(date +%s)" "$(( $(date +%s) + 600 ))" > "$GH_LIMIT_DIR/budget.json"
health coreok
ck "(m24) a TORN budget.json is not a measurement (--health is gh-ok)" \
   $([ "$RC" -eq 0 ] && [ "$OUT" = "gh-ok" ] && echo 0 || echo 1)

echo "── (m25) ROUND 9: an attributeless flag must not bypass the write guard, and a changed ───────"
echo "         resource must not be retried into the empty pool ────────────────────────────────────────"
# (m25) `makes_request` answers False for an argv `api_endpoint` cannot attribute (correct for the
# RECOVERY question: an unattributable call must be no evidence). Gating the BUDGET GUARD on it made a
# flag nobody listed a way to send a write into a pool measured at zero — measured: one request, and its
# headerless refusal rewrote the dated record as undated so every later write was sent too.
reset_env m25 coreok
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run coreok api --definitely-not-a-listed-flag -X POST repos/o/r/issues -f body=x
ck "(m25) a WRITE with an unattributable flag is refused by name" \
   $([ "$RC" -ne 0 ] && grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)
ck "(m25) … and it spends NO request" $([ ! -s "$STUB_LOG" ] && echo 0 || echo 1)

# (m26) a cached validator offers a POSSIBLE 304, not a free request: when the resource has CHANGED the
# conditional GET spends quota, and it must be the LAST thing spent — refused, never retried 4× with a
# 599 s wait (the measured cost on `branches/main/protection`, the read that broke during the incident).
reset_env m26 coreok
unset GH_LIMIT_CONDITIONAL
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(m26) the validator is primed (1 request)" $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
printf '{"at": %s, "core": {"remaining": 0, "reset": %s, "limit": 5000}}' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/budget.json"
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' \
  "$(date +%s)" "$(( $(date +%s) + 700 ))" > "$GH_LIMIT_DIR/health"
: > "$STUB_LOG"
run etagchg api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(m26) a CHANGED resource costs exactly ONE request, not 4 (never retried into the empty pool) [n=$(reqs 'required_status_checks')]" \
   $([ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
ck "(m26) … and the layer recorded that it stopped after one (no retry ladder)" \
   $(grep -q 'speculative conditional read' "$GH_LIMIT_DIR/events.log" 2>/dev/null && echo 0 || { [ "$(grep -c 'attempt=1/4' "$GH_LIMIT_DIR/events.log")" -le 1 ] && [ "$(wc -l < "$STUB_LOG")" -eq 1 ] && echo 0 || echo 1; })


echo "── (n) THE FLOOR (#2342): the reserve is not spent on reads, and nothing is called empty ─────"
# 400 remaining is ABOVE the pre-#2342 reserve (100) and BELOW the #2342 floor (800) — the window in
# which the fleet used to spend the reserve on polling and then lose every WRITE with it. Measured
# 2026-10-23 04:11Z: one identity, `core remaining=0` for the Mac and all three cells at once.
reset_env n floor
budget floor
: > "$STUB_LOG"
run floor api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts'
ck "(n) below the floor, a read with NO exact GraphQL equivalent is REFUSED" \
   $([ "$RC" -ne 0 ] && echo 0 || echo 1)
ck "(n) … BY NAME, carrying the measured remaining and the floor" \
   $(grep -q 'gh-core-floor remaining=400 floor=800' <<<"$ERR" && echo 0 || echo 1)
ck "(n) … and the classifier's marker survives (the cycle reads as limited, not idle)" \
   $(grep -qi 'gh rate limit' <<<"$ERR" && echo 0 || echo 1)
ck "(n) … and it spends NO request at all" $([ ! -s "$STUB_LOG" ] && echo 0 || echo 1)
ck "(n) … and STDOUT IS EMPTY — a refusal is never served as an empty list or object" \
   $([ ! -s "$TMP/out" ] && echo 0 || echo 1)
ck "(n) … and it does NOT claim exhaustion (the pool still has 400)" \
   $(grep -q 'gh-core-exhausted' <<<"$ERR" && echo 1 || echo 0)
health floor
ck "(n) … and --health stays gh-ok: a floor refusal is not a measurement of an empty pool" \
   $(grep -q '^gh-ok$' <<<"$OUT" && echo 0 || echo 1)
: > "$STUB_LOG"
run floor api repos/o/r/pulls/7 --jq .head.sha
ck "(n) … while a read WITH an exact equivalent is still SERVED (from GraphQL), never blocked" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'api graphql')" -eq 1 ] && echo 0 || echo 1)
: > "$STUB_LOG"
export GH_LIMIT_ESSENTIAL=1
run floor api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts'
ck "(n) GH_LIMIT_ESSENTIAL=1 spends the reserve — the escape hatch a LANDING needs" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
unset GH_LIMIT_ESSENTIAL
reset_env n2 coreok
budget coreok
: > "$STUB_LOG"
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts'
ck "(n) ABOVE the floor the same read is SENT — the guard must not block a healthy box" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)

echo "── (o) THE INSTRUMENT (#2342): --stats PROVES the saving instead of asserting it ──────────────"
reset_env o coreok
: > "$STUB_LOG"
for i in 1 2 3; do run coreok pr list --repo o/r; done
ck "(o) three reads inside the TTL made ONE request (the saving is real, not claimed)" \
   $([ "$(wc -l < "$STUB_LOG")" -eq 1 ] && echo 0 || echo 1)
stats
ck "(o) --stats exits 0 and names the class it counted" \
   $([ "$RC" -eq 0 ] && grep -q 'pr-list' <<<"$OUT" && echo 0 || echo 1)
ck "(o) … it reports the counters the calls actually wrote (2 hits, 1 miss)" \
   $(grep -q 'pr-list *hit=2 *miss=1' <<<"$OUT" && echo 0 || echo 1)
ck "(o) … and the averted REQUESTS (2), which is the number the brief asks to prove" \
   $(grep -q 'averted=2' <<<"$OUT" && echo 0 || echo 1)
ck "(o) … and reading the instrument itself spends no request" \
   $([ "$(wc -l < "$STUB_LOG")" -eq 1 ] && echo 0 || echo 1)
reset_env o2 coreok
stats
ck "(o) an EMPTY box says no-reads-counted — an invented averted=0 would be a measurement nobody made" \
   $(grep -q '^gh-read-cache no-reads-counted$' <<<"$OUT" && echo 0 || echo 1)
ck "(o) … and still exits 0 (nothing to report is not an error)" \
   $([ "$RC" -eq 0 ] && echo 0 || echo 1)
# ⛔ AN UNREADABLE INSTRUMENT IS NOT "NOTHING COUNTED" — AND IT MUST NOT EXIT 0 (review round 2, P2).
# A directory where the counters file belongs makes the read raise OSError, which is the real shape of
# a permission/remount failure. Returning 0 there told any caller gating on the exit status that the
# instrument was fine, which is the false-PASS polarity `--health` already refuses.
reset_env o3 coreok
rm -f "$GH_LIMIT_DIR/read-cache-stats.jsonl"
mkdir -p "$GH_LIMIT_DIR/read-cache-stats.jsonl"
stats
ck "(o3) an UNREADABLE instrument says UNREADABLE, not no-reads-counted" \
   $(grep -q '^gh-read-cache UNREADABLE ' <<<"$OUT" && echo 0 || echo 1)
ck "(o3) … and exits 3, so it can never read as green to a caller gating on rc" \
   $([ "$RC" -eq 3 ] && echo 0 || echo 1)

echo "── (p) THE FLOOR CAN SEE (#2342 review P1): a blind box MEASURES before it refuses ────────────"
# The floor acts on a MEASURED `remaining`, and before this the only writer of a non-zero one was the
# `--budget` verb — which NO harness script calls — plus the refusal path's own probe, which runs only
# once the pool is already empty. So the guard could never fire in production. A core-only read with no
# local evidence now spends ONE exempt meter read; a measured-empty pool is refused WITHOUT sending it.
reset_env p core0
: > "$STUB_LOG"
run core0 api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(p) the meter was READ exactly once (the blind box measures; it does not guess)" \
   $([ "$(reqs 'api rate_limit')" -eq 1 ] && echo 0 || echo 1)
ck "(p) … and the measured-empty pool refused the read WITHOUT sending it" \
   $([ "$RC" -ne 0 ] && [ "$(reqs 'required_status_checks')" -eq 0 ] && echo 0 || echo 1)
ck "(p) … by NAME (a measured empty pool, not a floor claim)" \
   $(grep -q 'gh-core-exhausted' <<<"$ERR" && echo 0 || echo 1)
ck "(p) … and the snapshot is recorded for every later lane, at no extra cost" \
   $([ -f "$GH_LIMIT_DIR/budget.json" ] && echo 0 || echo 1)
# … and a HEALTHY meter lets the same read through, with no pre-emptive refusal at all.
: > "$STUB_LOG"
# the window RESET: the durable evidence is gone too, so this is a box measuring afresh. A fresh
# meter outranks an old record by design (the layer states it both ways), so a fixture that keeps
# the stale empty record while the meter reads 3000 would be testing a contradiction, not the code.
rm -f "$GH_LIMIT_DIR/budget.json" "$GH_LIMIT_DIR/budget-probe-at" "$GH_LIMIT_DIR/health" "$GH_LIMIT_DIR/last-limit"
run coreok api repos/o/r/branches/main/protection/required_status_checks --jq '.contexts[]'
ck "(p2) a HEALTHY meter lets the same read through (1 request, rc 0)" \
   $([ "$RC" -eq 0 ] && [ "$(reqs 'required_status_checks')" -eq 1 ] && echo 0 || echo 1)
ck "(p2) … and the probe it spent is what makes the next lane's decision possible" \
   $([ "$(reqs 'api rate_limit')" -eq 1 ] && echo 0 || echo 1)

echo "── (q) the FLOOR's reserve is declared PER CALL, never at script scope (#2342 review, P1) ─────"
# The layer's own contract (`essential()`: "A poll is never essential") is only true if no caller hands
# a whole SCRIPT the exemption. Three rails did exactly that with a file-scope
# `export GH_LIMIT_ESSENTIAL=1`, which exempted every poll loop in them — the `gh run list`
# FIRST-CHECKS wait (30 of 41 core calls, 73 % of a merge cycle) and `atomic-land.sh::check_count`'s
# two paginated `check-runs` reads per verify iteration. These two assertions are the inverse pair:
# the blanket export must be GONE, and the one legitimate per-call declaration must SURVIVE.
_src="${HERE}/.."
_blanket="$(grep -rn '^[[:space:]]*export[[:space:]]\{1,\}GH_LIMIT_ESSENTIAL=' "$_src" --include='*.sh' --include='*.py' 2>/dev/null | grep -v '\.test\.sh' || true)"
ck "(q) no file-scope 'export GH_LIMIT_ESSENTIAL=1' anywhere in-tree (a script-wide exemption disables the floor on the script's POLLS) [${_blanket:-<none>}]" \
   $([ -z "$_blanket" ] && echo 0 || echo 1)
_percall="$(grep -c 'GH_LIMIT_ESSENTIAL=1 "\$gh" api' "${HERE}/repo-authority.sh" 2>/dev/null || true)"
ck "(q) …and the landing's ONE legitimate declaration survives, PER CALL, on the protection read" \
   $([ "${_percall:-0}" -ge 1 ] && echo 0 || echo 1)

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
