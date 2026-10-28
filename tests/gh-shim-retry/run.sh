#!/usr/bin/env bash
# tests/gh-shim-retry/run.sh — the TRANSPORT retry in `scripts/gh-shim/gh` (#2148).
#
# THE FAILURE THIS PINS. Measured 2026-10-24: two lanes on cell-3 died to ONE network blip
# (`Connection error.` -> rc=1 -> lane EXIT, work lost), and three IDENTICAL `gh api rate_limit`
# calls two seconds apart on cell-1 returned ok / ok / `error connecting to api.github.com` with
# 2431 of 5000 requests still in hand. Intermittent per call — a single-shot `gh` cannot survive it,
# a retry can. The shim already retried a RATE-LIMIT refusal; it did not retry a dropped socket.
#
# WHAT IS ASSERTED, AND WHY EACH ASSERTION IS THE EFFECT AND NOT THE SEND:
#   §1 a transport blip then a real answer  -> rc 0, stdout BYTE-EXACT, the fake really ran twice.
#   §1b a blip AFTER partial stdout         -> the discarded attempt's bytes never reach the caller
#                                              (a streamed retry returns rc=0 with duplicated,
#                                              unparseable JSON — the P1 of this PR's own review).
#   §1c an EXHAUSTED call                   -> still replays its own final attempt's stdout ONCE
#                                              (a failing `gh pr checks` table must survive).
#   §2 three transport failures             -> the transport rc, three invocations, a named
#                                              exhaustion and a BOUNDED total (no unbounded loop);
#                                              and a transport blip followed by a 422 does NOT claim
#                                              a transport cause (no false diagnosis).
#   §3 a `HTTP 422`                         -> one invocation, no retry line: one honest refusal
#                                              must not become three. A `502` whose BODY says
#                                              `connection reset by peer` is likewise not a blip.
#   §4 a MUTATION on a TRANSPORT failure    -> one invocation (`-X POST`, bare `-f`, `pr merge`,
#                                              `issue comment`): a dropped write may have SUCCEEDED;
#                                              a READ control on the identical blip IS retried, so
#                                              the negatives are not vacuous, and neither a flag
#                                              VALUE (`-H 'Accept: …'`) nor a GLOBAL flag before the
#                                              subcommand (`gh -R o/r pr view 1`) hides the read.
#   §5 the admin-merge refusal              -> still REFUSES, and no merge reaches the real gh.
#   §6 a rate-limit refusal                 -> handled by the PACING gate (its own arm), never
#                                              reclassified as transport; and an exhausted
#                                              rate-limit budget does not spill into the new arm.
#   §7 `gh api graphql`                     -> never retried in ANY spelling: bare `api graphql` (a
#                                              `-f` fixture alone would be green with the guard
#                                              deleted), `/graphql`, and an absolute `https://api.github.com/graphql` URL.
#   §8 rc 1 with EMPTY stderr               -> is NOT retried: gh's `SilentError` (a FAILED `pr checks`
#                                              verdict) is a decision, and the reads the fleet makes
#                                              hottest must not be re-run three times on every red PR.
#
# ⛔ THE RETRY LINE IS NOT ON A SUCCESSFUL CALL'S STDERR, AND THAT IS THE DESIGN, NOT AN OVERSIGHT.
# `gh-rest/gh` (and `gh-limit.py`) merge `2>&1` and PARSE the merged bytes as JSON, so one stray
# line turns `pr view --json` into a JSONDecodeError and a performed `pr merge` into a reported
# failure. §1 therefore asserts BOTH halves of the contract: the line IS recorded (events.log, on
# every retry, greppable) and the call that recovers leaves stderr byte-clean. §2 asserts the other
# half — a call that FINALLY fails replays the retry lines to stderr, which is the case that kills a
# lane. `tests/gh-shim/run.sh` §14(a) pins the same invariant from the pacing side.
#
# Hermetic: a fake `gh` FIRST on PATH serves every call and records its argv. No network, no creds.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM="$ROOT/scripts/gh-shim/gh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-shim-retry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "   ❌ $1"; }

# ── the fake real-gh ─────────────────────────────────────────────────────────────────────────────
# It records EVERY invocation (so "was it retried?" is answered by the fake's own record, not by our
# logs), then plays the next scripted behaviour: one line of `$SCEN/behaviour` per invocation, the
# last line repeating. The marker line of the harness layers is deliberately ABSENT — the shim's
# resolver skips anything carrying it, and this fake must be RESOLVED, not skipped.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SCEN:?}/calls"
n=$(( $(cat "$SCEN/count" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$n" > "$SCEN/count"
beh="$(sed -n "${n}p" "$SCEN/behaviour" 2>/dev/null)"
[ -n "$beh" ] || beh="$(tail -n 1 "$SCEN/behaviour" 2>/dev/null)"
case "$beh" in
  ok)          printf '{"number":1,"title":"ok"}\n'; exit 0 ;;
  # Answers correctly but slowly, so a test can inspect the gate dir WHILE the call is in flight
  # (the capture files exist only for the duration of a call).
  slowok)      sleep 1.5; printf 'secret-envelope-payload\n'; exit 0 ;;
  connect)     printf 'error connecting to api.github.com\n' >&2; exit 1 ;;
  connerr)     printf 'Connection error.\n' >&2; exit 1 ;;
  timeout)     printf 'Post "https://api.github.com/graphql": dial tcp 140.82.116.6:443: i/o timeout\n' >&2; exit 1 ;;
  silent)      exit 1 ;;
  # A transport failure AFTER bytes were already on stdout: `connection reset` / `unexpected eof` are
  # exactly the signatures that leave a half-written body behind, so this is the fixture the P1 of
  # #2768's review needed (the first version of this suite wrote nothing before failing, so a
  # duplicated-stdout bug passed it).
  partial)     printf '{"number":1},{"num'; printf 'connection reset by peer\n' >&2; exit 1 ;;
  e422)        printf 'gh: Unprocessable Entity (HTTP 422)\n{"message":"Validation Failed"}\n' >&2; exit 1 ;;
  e403)        printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 1 ;;
  # A REAL SHAPE: a gateway error whose body explains itself with a transport word. GitHub ANSWERED
  # (a 502 is a response), so nothing here may be retried — this is the case the HTTP-response
  # guard exists for, and a transport-SIGNATURE test on its own would wrongly grab it.
  mixed)       printf 'gh: Server Error (HTTP 502): connection reset by peer\n' >&2; exit 1 ;;
  ratelimit)   printf 'API rate limit exceeded for user ID 1.\n' >&2; exit 1 ;;
  *)           printf 'fake-gh: unscripted behaviour %s\n' "$beh" >&2; exit 99 ;;
esac
GHEOF
chmod +x "$BIN/gh"

# scen_init <name> <behaviour line>…  — a private scenario dir (its own call record + gate state).
scen_init() {
  local name="$1"; shift
  SCEN="$TMP/$name"
  mkdir -p "$SCEN/gate"
  printf '%s\n' "$@" > "$SCEN/behaviour"
  : > "$SCEN/calls"
  rm -f "$SCEN/count"
}

# shim <argv…> — run the shim against the fake on PATH. `AGENT_GH_REAL` is UNSET (env -u) so the
# PATH resolution is exercised too; a fake that the resolver skipped would fail every case here.
shim() {
  env -u AGENT_GH_REAL \
    PATH="$BIN:$PATH" SCEN="$SCEN" \
    AGENT_GH_GATE_DIR="$SCEN/gate" AGENT_GH_GATE_INTERVAL_MS=0 \
    bash "$SHIM" "$@"
}
calls() { wc -l < "$SCEN/calls" | tr -d ' '; }
events() { cat "$SCEN/gate/events.log" 2>/dev/null; }
# ⛔ `grep -c` PRINTS `0` *and* exits 1 when nothing matched, so a bare `|| printf 0` emits `0\n0`
# — which is a broken integer, not a zero. Coerce to one number.
retry_lines() {
  local n
  n="$(grep -c 'gh-shim: transport retry' "$SCEN/gate/events.log" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ── §1: ONE transport blip, then a real answer ───────────────────────────────────────────────────
echo "== 1. a transport blip is retried, and the caller gets the real answer =="
scen_init blip connect ok
out="$(shim pr view 1 --json number 2>"$TMP/err1")"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "rc=0 after one transport failure (was rc=1 — a dead lane)" \
  || fail "rc=$rc after a single transport blip"
[ "$out" = '{"number":1,"title":"ok"}' ] \
  && pass "stdout is EXACTLY the real command's output" \
  || fail "stdout was corrupted by the retry: $(printf '%s' "$out" | head -1)"
[ ! -s "$TMP/err1" ] \
  && pass "stderr stayed byte-clean on the call that RECOVERED (the gh-rest \`2>&1 | jq\` invariant)" \
  || fail "a recovered call contaminated stderr: $(head -1 "$TMP/err1")"
[ "$(calls)" -eq 2 ] \
  && pass "the real gh really ran TWICE (the fake's own record, not our log)" \
  || fail "expected 2 invocations, the fake recorded $(calls)"
grep -q 'gh-shim: transport retry 1/3 (error connecting)' "$SCEN/gate/events.log" 2>/dev/null \
  && pass "the retry is RECORDED and greppable: \`gh-shim: transport retry 1/3 (error connecting)\`" \
  || fail "the retry was silent — no \`transport retry 1/3\` line in events.log"

# ⛔ §1b THE P1 OF THE REVIEW: stdout must survive a retry EXACTLY ONCE. The fake writes a
# partial body and THEN fails with `connection reset`; with stdout streamed straight through, the
# caller received the fragment followed by the whole (successful) answer — rc=0 with duplicated,
# unparseable JSON. `atomic-land.sh`'s per-page count would double, and a `--json` reader would get a
# JSONDecodeError from a call that SUCCEEDED.
scen_init partial partial ok
out="$(shim api /repos/o/r/pulls 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '{"number":1,"title":"ok"}' ] \
  && pass "a failed attempt's PARTIAL stdout is discarded — the caller gets exactly one well-formed answer" \
  || fail "stdout carried a discarded attempt's bytes (rc=$rc): $(printf '%s' "$out" | head -c 120)"
[ "$(calls)" -eq 2 ] \
  && pass "  …and it really was retried (2 invocations)" \
  || fail "the partial-stdout case was not retried ($(calls) invocations)"
# ⛔ §1c THE OTHER HALF OF THE STDOUT RULE (review of #2768, P2): a call that EXHAUSTS its retries
# still delivers ITS OWN final attempt's output — once. That is load-bearing for a caller reading a
# failing `gh pr checks` table (the names/states of the failed checks arrive on stdout with rc=1);
# gating the replay on rc=0 would silently drop it for every red PR.
scen_init partialfail partial
out="$(shim api /repos/o/r/pulls 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] \
  && pass "an exhausted call returns the failing rc (rc=$rc)" \
  || fail "a call whose every attempt failed returned rc=0"
[ "$out" = '{"number":1},{"num' ] \
  && pass "  …and replays the FINAL attempt's stdout EXACTLY ONCE (not 3 copies, not nothing)" \
  || fail "a failing call replayed $(printf '%s' "$out" | grep -c . ) line(s) / wrong bytes: $(printf '%s' "$out" | head -c 80)"

# ── §2: three transport failures — bounded, named, and the TRANSPORT rc ──────────────────────────
echo "== 2. transport failures exhaust a BOUNDED budget and the caller gets the real rc =="
scen_init exhaust connect connerr timeout
t0="$(date +%s)"
shim issue view 5 >/dev/null 2>"$TMP/err2"; rc=$?
t1="$(date +%s)"
[ "$rc" -ne 0 ] \
  && pass "a call that never got an answer FAILS (rc=$rc) instead of inventing success" \
  || fail "rc=0 on a call whose every attempt failed"
[ "$(calls)" -eq 3 ] \
  && pass "exactly 3 attempts (TRANSPORT_ATTEMPTS), no more" \
  || fail "expected 3 attempts, the fake recorded $(calls)"
[ "$(retry_lines)" -eq 2 ] \
  && pass "two retries were recorded (attempts 1 and 2 of 3), none invented" \
  || fail "expected 2 recorded retries, events.log has $(retry_lines)"
grep -q 'transport retry 1/3' "$TMP/err2" && grep -q 'transport retry 2/3' "$TMP/err2" \
  && pass "a call that FINALLY fails replays both retry lines to stderr (the lane-log case)" \
  || fail "a failing call did not surface its retries on stderr"
grep -q 'transport failure persisted after 3 attempt' "$TMP/err2" \
  && pass "  …and names the exhaustion WITH the attempt count that really happened" \
  || fail "the exhaustion was not named on the failing call"
# ⛔ THE COUNT MUST INCLUDE THE RATE-LIMIT ARM'S ATTEMPTS (review of #2768, P2). The arms share one
# loop, so `ratelimit, connect, connect, connect` is FOUR invocations; reporting 3 understates it on
# the surface the runbook tells operators to read. MAX_ATTEMPTS=2 gives the rate-limit arm exactly
# one retry, and RETRY_BASE=1 keeps the case fast.
scen_init mixedcount ratelimit connect connect connect
AGENT_GH_GATE_MAX_ATTEMPTS=2 AGENT_GH_GATE_RETRY_BASE=1 shim api rate_limit >/dev/null 2>"$TMP/err2c"
[ "$(calls)" -eq 4 ] \
  && pass "  …a rate-limit retry then 3 transport attempts is 4 invocations" \
  || fail "the mixed-arm sequence took $(calls) invocations, expected 4"
grep -q 'transport failure persisted after 4 attempt' "$TMP/err2c" \
  && pass "  …and the note counts ALL FOUR, not just the transport ones" \
  || fail "the exhaustion note understated the attempts: $(grep -o 'after [0-9]* attempt' "$TMP/err2c" | head -1)"
# ⛔ THE FALSE-CAUSE CASE (review of #2768, P2): a transport blip followed by an honest `HTTP 422`.
# The call must NOT claim transport exhaustion — the last attempt was GitHub ANSWERING, and reporting
# "3 attempts" for a 2-attempt call is a false cause on the surface an operator debugs with.
scen_init mixedfail connect e422
shim api /repos/o/r/pulls >/dev/null 2>"$TMP/err2b"
[ "$(calls)" -eq 2 ] \
  && pass "  …a transport blip then a 422 is TWO attempts, not a retried refusal" \
  || fail "the transport-then-422 sequence took $(calls) invocations"
grep -q 'transport failure persisted' "$TMP/err2b" \
  && fail "an HTTP 422 was reported as transport exhaustion" \
  || pass "  …and NO transport-exhaustion cause is claimed for it"
[ $(( t1 - t0 )) -le 10 ] \
  && pass "the whole backoff stayed bounded ($(( t1 - t0 ))s for 1 s + 3 s)" \
  || fail "the retry backoff overran its 4 s budget ($(( t1 - t0 ))s)"

# ── §3: an HTTP response is never a transport failure ────────────────────────────────────────────
echo "== 3. a GitHub RESPONSE (HTTP 422) is never retried =="
scen_init e422 e422
shim api /repos/o/r/pulls >/dev/null 2>"$TMP/err3"; rc=$?
[ "$rc" -ne 0 ] && pass "a 422 exits non-zero (rc=$rc)" || fail "a 422 exited 0"
[ "$(calls)" -eq 1 ] \
  && pass "ONE honest refusal stays one refusal (1 invocation)" \
  || fail "a 422 was retried ($(calls) invocations) — one refusal became $(calls)"
[ "$(retry_lines)" -eq 0 ] && ! grep -q 'transport retry' "$TMP/err3" \
  && pass "no retry line anywhere — a response is an ANSWER, not a blip" \
  || fail "a 422 produced a transport retry"

# ⛔ A RESPONSE THAT *CONTAINS* A TRANSPORT WORD. `connection reset by peer` inside a 502 body is the
# one case a transport-SIGNATURE test grabs on its own, so it is the case that pins the HTTP guard.
scen_init mixed502 mixed
shim pr view 1 >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "a 502 whose body says 'connection reset by peer' is NOT retried (1 invocation)" \
  || fail "an HTTP response was reclassified as transport ($(calls) invocations)"
scen_init read403 e403
shim pr view 1 >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "a READ refused with 403: 1 invocation (a permissions 403 is not a burst)" \
  || fail "a 403 on a read was retried ($(calls) invocations)"

# ── §4: mutations are single-shot on a TRANSPORT failure; the read control proves the difference ──
echo "== 4. a mutation is NEVER retried on a transport failure =="
# ⛔ THE FAILURE IS A TRANSPORT ONE, not a 403. A 403 is already refused by the HTTP-response guard,
# so an e403 fixture would pass with the mutation guard DELETED — it would pin nothing.
# ⛔ THE METHOD GUARD NEEDS A BODY-LESS FIXTURE (review of #2768, round 3). `-X POST … -f body=x`
# satisfies the BODY rule too, so deleting the method rule left the suite green while a plain
# `-X POST /repos/…/lock` ran twice. Bare writes (`--lock`, `--unlock`, `--pin`) carry no field flag
# at all, which is exactly the shape that slipped through.
scen_init mutbare connect ok
shim api -X POST /repos/o/r/issues/1/lock >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`-X POST\` with NO field flag on a dropped connection: 1 invocation" \
  || fail "a body-less \`-X POST\` was retried ($(calls) invocations) — a write could run twice"
scen_init mutattached connect ok
shim api -XDELETE /repos/o/r/issues/1/lock >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "the ATTACHED spelling \`-XDELETE\`: 1 invocation" \
  || fail "\`-XDELETE\` was retried ($(calls) invocations)"
scen_init mutmethod connect ok
shim api --method=PATCH /repos/o/r/issues/1 >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`--method=PATCH\`: 1 invocation" \
  || fail "\`--method=PATCH\` was retried ($(calls) invocations)"
scen_init mutfield connect ok
shim api /repos/o/r/issues/1/comments -f body=hi >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`-f\` alone implies POST: 1 invocation (no \`-X\` needed to be a write)" \
  || fail "a field flag without \`-X\` was retried ($(calls) invocations)"
# ⛔ THE POSITIVE CONTROL. Without it, a shim that never retries ANYTHING passes every assertion
# above — the whole arm could be deleted and this section would stay green.
scen_init readctl connect ok
out="$(shim pr view 7 --json number 2>/dev/null)"
[ "$(calls)" -eq 2 ] && [ "$out" = '{"number":1,"title":"ok"}' ] \
  && pass "the READ control (same blip, same argv shape) IS retried — so the two above discriminate" \
  || fail "the read control was not retried ($(calls) invocations) — the mutation assertions prove nothing"
# ⛔ A FLAG'S VALUE IS NOT A POSITIONAL. `-H 'Accept: …'` before the path used to consume the
# positional slot and read as "not a gh api call", so the fix silently did not cover the commonest
# harness read. Asserted end to end, not on the parser.
scen_init headerflag connect ok
shim api -H 'Accept: application/vnd.github+json' /repos/o/r/pulls/1 2>/dev/null >/dev/null
[ "$(calls)" -eq 2 ] \
  && pass "\`gh api -H 'Accept: …' …\` IS retried (a flag value does not hide the read)" \
  || fail "a header flag hid the read from the retry ($(calls) invocations)"
# ⛔ A GLOBAL FLAG BEFORE THE SUBCOMMAND IS THE CASE THAT MATTERS, AND IT NEEDS ITS OWN ASSERTION
# (review of #2768, P2): with `-R/--repo` missing from the skip list, `gh -R o/r pr view 1` puts
# `o/r` in the w1 slot and is silently never retried — a shape the fleet actually issues.
scen_init repoflag connect ok
shim -R o/r pr view 1 >/dev/null 2>/dev/null
[ "$(calls)" -eq 2 ] \
  && pass "\`gh -R o/r pr view 1\` IS retried (a leading global flag does not hide the verb)" \
  || fail "a leading \`-R\` hid the read from the retry ($(calls) invocations)"
# ⛔ THE NON-`api` VERB WHITELIST, WHICH §5 DOES NOT COVER (review of #2768, P2). The admin path
# refuses BEFORE `run_paced`, so `read_only_call` is never reached there: turning `pr) return 0`
# (retry EVERY pr verb, `merge` included) used to leave the whole suite green.
scen_init prmerge connect ok
shim pr merge 9 >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`pr merge\` (no --admin, so it really runs) is NOT retried into a second merge" \
  || fail "\`pr merge\` was retried ($(calls) invocations) — a merge could run twice"
scen_init issuecomment connect ok
shim issue comment 9 -b hi >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`issue comment\` is NOT retried (it writes)" \
  || fail "\`issue comment\` was retried ($(calls) invocations)"

# ── §5: the admin-merge refusal is UNCHANGED (it is not this shim's payload) ─────────────────────
echo "== 5. the admin-merge refusal still refuses, and no real gh runs =="
scen_init admin ok
shim pr merge 123 --admin >/dev/null 2>"$TMP/err5"; rc=$?
[ "$rc" -ne 0 ] && pass "--admin without head-bound evidence is still REFUSED (rc=$rc)" \
  || fail "an unjustified admin merge was ALLOWED"
grep -q 'REFUSED' "$TMP/err5" \
  && pass "  …and says so" || fail "the refusal was silent"
# ⛔ NOT "zero invocations": the evidence VERIFIER shells out to gh (that is how it reads the
# certificate), and those reads are expected. The effect that matters is that no MERGE was issued.
_grep_merge="$(grep -c 'merge' "$SCEN/calls" 2>/dev/null)"; case "$_grep_merge" in ''|*[!0-9]*) _grep_merge=0 ;; esac
[ "$_grep_merge" -eq 0 ] \
  && pass "no merge was ever issued to the real gh (decided before the call, retry or not)" \
  || fail "a REFUSED admin merge still reached gh: $(grep 'merge' "$SCEN/calls" | head -1)"

# ── §6: a pacing/rate-limit refusal belongs to the PACING arm, never to this one ─────────────────
echo "== 6. a rate-limit refusal is a DECISION — the pacing gate owns it, transport never does =="
scen_init ratelimit ratelimit
AGENT_GH_GATE_NO_WAIT=1 shim api rate_limit >/dev/null 2>"$TMP/err6"
[ "$(calls)" -eq 1 ] \
  && pass "a rate-limit refusal is not re-run by the transport arm" \
  || fail "a rate-limit refusal was re-run ($(calls) invocations)"
[ "$(retry_lines)" -eq 0 ] \
  && pass "  …and no transport retry was recorded for it" \
  || fail "a rate-limit refusal was reclassified as a transport failure"
grep -q 'rate limit' "$TMP/err6" || grep -q 'NO_WAIT' "$TMP/err6" \
  && pass "  …the pacing gate still reports the refusal itself" \
  || fail "the pacing gate's own refusal vanished"
# An EXHAUSTED rate-limit budget must not spill into the transport arm either: with MAX_ATTEMPTS=1
# the pacing arm breaks at once, and the transport arm must NOT pick the refusal up afterwards.
scen_init rlexhaust ratelimit
AGENT_GH_GATE_MAX_ATTEMPTS=1 shim api rate_limit >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] && [ "$(retry_lines)" -eq 0 ] \
  && pass "an exhausted rate-limit budget does not spill into the transport arm" \
  || fail "a spent rate-limit refusal was retried as transport ($(calls) invocations, $(retry_lines) retry lines)"

# ── §7: `gh api graphql` is never retried (it can BE the merge mutation) ─────────────────────────
echo "== 7. \`gh api graphql\` is never retried =="
# ⛔ BOTH SHAPES, AND THE FIRST ONE IS THE DISCRIMINATING ONE. A `-f` field flag alone already marks
# the call as a body/POST, so a `-f query=…` fixture stays green with the `graphql*` guard DELETED
# (found in review of #2768). A bare `api graphql` is the shape only that guard can stop.
scen_init graphqlnofield connect ok
shim api graphql >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "bare \`api graphql\` on a transport failure: 1 invocation (a query can BE \`mergePullRequest\`)" \
  || fail "bare \`api graphql\` was retried ($(calls) invocations) — a mutation could run twice"
# ⛔ THE OTHER TWO SPELLINGS (review of #2768, P2): a PREFIX test let the path and URL forms through,
# contradicting the header's "any graphql spelling is refused".
for _gq in /graphql https://api.github.com/graphql; do
  # A counter, not `$RANDOM`: a `$` in a path the suite later `rm`s is exactly the shell-expansion
  # form the repo's worktree guard refuses to verify (it false-blocks the whole suite on it).
  _gqn=$(( ${_gqn:-0} + 1 ))
  scen_init "gq$_gqn" connect ok
  shim api "$_gq" >/dev/null 2>/dev/null
  [ "$(calls)" -eq 1 ] \
    && pass "  …and \`api $_gq\` is not retried either" \
    || fail "the graphql spelling \`$_gq\` was retried ($(calls) invocations)"
done
scen_init graphql connect ok
shim api graphql -f 'query={viewer{login}}' >/dev/null 2>/dev/null
[ "$(calls)" -eq 1 ] \
  && pass "\`api graphql -f query=…\`: 1 invocation" \
  || fail "graphql with a field flag was retried ($(calls) invocations)"

# ── §8: rc=1 with an EMPTY stderr is gh's SILENT DECISION, not a blip ──────────────────────────
echo "== 8. rc=1 with an EMPTY stderr is NOT retried (gh's SilentError is a verdict) =="
# `gh pr checks` exits 1 with NO message precisely when checks FAILED (`cmdutil.SilentError`), and it
# is one of the fleet's hottest reads. Retrying it would re-run every red PR three times, add 4 s and
# write a false `transport retry …` into events.log. Every transport failure we MEASURED prints text.
scen_init silent silent ok
out="$(shim pr checks 1 --json name 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$(calls)" -eq 1 ] \
  && pass "an empty-stderr rc=1 (a failed-check verdict) is NOT retried: 1 invocation, rc=$rc" \
  || fail "a silent rc=1 was retried (rc=$rc, $(calls) invocations) — every red PR would pay 3 runs"
[ -z "$out" ] \
  && pass "  …and it invents no output" \
  || fail "a silent rc=1 produced stdout: $(printf '%s' "$out" | head -1)"
[ "$(retry_lines)" -eq 0 ] \
  && pass "  …and records no transport retry for it" \
  || fail "a silent rc=1 was recorded as a transport failure"

# ── §9: the capture is OWNER-ONLY while it exists ───────────────────────────────────
echo "== 9. the stdout capture is 0600 for the life of the call (a secret-printing read touches disk) =="
# ⛔ REVIEW OF #2768, ROUND 4: the `0600` was stated and unpinned. It is the ONLY protection when the
# gate dir is unusable and `WORKDIR` falls back to a plain (often 1777) `$TMPDIR`. Asserted from
# OUTSIDE, on the real file the shim is holding: the fake answers slowly so the capture exists while
# we look.
scen_init mode slowok
# ⛔ THE WRAPPER'S UMASK MUST NOT BE ABLE TO SATISFY THIS. Under `umask 077` a file created with no
# `chmod` is ALREADY `0600`, so the assertion passed on a shim with the `chmod` deleted — a false
# CLEAN on any runner whose umask is strict (review of #2768, round 5). The call runs under an
# explicit permissive umask, so the shim's own `chmod 600` is the only thing that can make it 0600.
( umask 022; shim issue view 3 >"$TMP/mode-out" 2>/dev/null ) &
_mode_pid=$!
_modes=""
_i=0
while [ "$_i" -lt 30 ]; do
  _modes="$(ls -l "$SCEN/gate"/out.* 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [ -n "$_modes" ] && break
  sleep 0.1; _i=$(( _i + 1 ))
done
wait "$_mode_pid"; _mode_rc=$?
case "$_modes" in
  '-rw------- '*) pass "the in-flight stdout capture is owner-only (0600)" ;;
  '')            fail "never observed the capture file — the 0600 claim is untested here" ;;
  *)             fail "the capture file was not owner-only: $_modes" ;;
esac
[ "$_mode_rc" -eq 0 ] && pass "  …and the call still answered (the mode check did not disturb it)" \
  || fail "the mode check's call failed (rc=$_mode_rc)"

# ── §10: a transport blip is NOT a shared window, and NO_WAIT does not suppress it ─────────────
echo "== 10. no cooldown is written, and a NO_WAIT caller still gets the transport retry =="
# ⛔ TWO REVIEW FINDINGS FROM ROUND 4, both unpinned: inserting `no_wait_wanted && break` into the
# transport arm (bounded callers silently lose the fix) or a `set_cooldown_ms` (a dropped socket parks
# every lane on the box) left BOTH suites green.
# The cooldown is asserted WHILE THE CALL RUNS: a 3 s window is expired by exit, so a post-hoc `ls`
# sees nothing even when the arm parked the box (measured on the mutant — the false CLEAN). The fake
# answers the retried attempt slowly, so the probe spans the window.
scen_init nocool connect slowok
shim pr view 11 >"$TMP/nocool-out" 2>/dev/null &
_nc_pid=$!
_nc_saw=""
_i=0
while kill -0 "$_nc_pid" 2>/dev/null && [ "$_i" -lt 80 ]; do
  [ -n "$(ls "$SCEN/gate"/cooldown.* 2>/dev/null)" ] && { _nc_saw=1; break; }
  sleep 0.1; _i=$(( _i + 1 ))
done
wait "$_nc_pid" 2>/dev/null
[ -z "$_nc_saw" ] \
  && pass "a transport retry writes NO shared cooldown (a blip is not a rate-limit window)" \
  || fail "a transport retry parked the whole box behind a cooldown"
scen_init nowait connect ok
AGENT_GH_GATE_NO_WAIT=1 shim pr view 12 >/dev/null 2>/dev/null
[ "$(calls)" -eq 2 ] \
  && pass "a NO_WAIT caller STILL gets the transport retry (1 s/3 s is not the wait it declared)" \
  || fail "NO_WAIT suppressed the transport retry ($(calls) invocations) — bounded callers lose the fix"

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks gh-shim transport-retry test(s) failed"
  exit 1
fi
echo "✅ all $checks gh-shim transport-retry tests passed"
