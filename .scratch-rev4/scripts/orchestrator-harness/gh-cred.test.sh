#!/usr/bin/env bash
# gh-cred.test.sh — offline checks for the credential decision layer (#3429).
#
# No network, no real GitHub, no real private key: `GH_CRED_MINT_CMD` and `GH_CRED_PROBE_CMD` replace
# the two HTTP calls, `GH_CRED_APP_KEY` points at a throwaway file, and `GH_CRED_NOW_CMD` is a fake
# clock. The DECISION, the cache/refresh logic and the wiring into `gh-limit.py` are the production
# code under test — only the network is substituted, so a test cannot pass on a re-implementation.
#
# ⛔ EVERY ARM IS PROVEN NON-VACUOUS BY MUTATION. An assertion like "a write never gets the app
# token" is worth exactly nothing until you have watched it fail with the arm removed, and the
# removal is the only thing that distinguishes a gate from a comment. So §2 deletes each arm from a
# COPY of the helper — with an exact-string replacement that REFUSES if the text is not there, so a
# refactor cannot silently retire the mutation — and asserts the copy now gives the wrong answer
# while the real file gives the right one. §5 does the same to `gh-limit.py`'s injection, because the
# decision can be perfect and still be wired to nothing.
#
# ⛔ AND THE REGRESSION ASSERTION IS ITS OWN TEST (§6). A read served by the user credential with no
# named arm behind it IS the bug this change exists to prevent (#3429: `core` reached `0/5000` three
# times in one day; #3584: reads ate the budget the controller needed, dispatch stopped, DRAIN
# DEADLOCK — no PR merged in 360m). It is counted, `--stats` exits non-zero on it, and §6 shows the
# counter actually moving.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED="$HERE/gh-cred.py"
LIMIT="$HERE/gh-limit.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
ok() { [ "$1" -eq 0 ] && echo 0 || echo 1; }

[ -f "$CRED" ] || { echo "helper missing: $CRED" >&2; exit 1; }
[ -f "$LIMIT" ] || { echo "helper missing: $LIMIT" >&2; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$CRED" 2>/dev/null \
  || { echo "gh-cred.py does not parse" >&2; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$LIMIT" 2>/dev/null \
  || { echo "gh-limit.py does not parse" >&2; exit 1; }

# ── the fake clock, key, mint and probe ─────────────────────────────────────────────────────────
CLOCK="$TMP/clock"
printf '1700000000\n' >"$CLOCK"
cat >"$TMP/now" <<'NOW'
#!/usr/bin/env bash
cat "$GH_CRED_TEST_CLOCK"
NOW
chmod +x "$TMP/now"

KEY="$TMP/app.pem"
printf 'not-a-real-key\n' >"$KEY"
chmod 600 "$KEY"

MINT_N="$TMP/mint.count"
PROBE_N="$TMP/probe.count"
printf '0\n' >"$MINT_N"
printf '0\n' >"$PROBE_N"

# The mint answers in the API's own shape, so the cache/refresh logic under test is the production
# one. Each call issues a distinguishable token (tok-1, tok-2, …) with a 1-hour expiry, and bumps a
# counter so reuse-vs-remint is OBSERVED, not inferred.
cat >"$TMP/mint" <<'MINT'
#!/usr/bin/env bash
n=$(cat "$GH_CRED_TEST_MINT_N")
n=$((n + 1))
printf '%s\n' "$n" >"$GH_CRED_TEST_MINT_N"
if [ -n "${GH_CRED_TEST_MINT_FAIL:-}" ]; then echo "boom: installation revoked" >&2; exit 1; fi
now=$(cat "$GH_CRED_TEST_CLOCK")
printf '{"token":"tok-%s","expires_at":%s}\n' "$n" "$((now + 3600))"
MINT
chmod +x "$TMP/mint"

cat >"$TMP/probe" <<'PROBE'
#!/usr/bin/env bash
n=$(cat "$GH_CRED_TEST_PROBE_N")
printf '%s\n' "$((n + 1))" >"$GH_CRED_TEST_PROBE_N"
printf '{"remaining":%s,"reset":%s,"limit":5000}\n' "${GH_CRED_TEST_REMAINING:-4000}" \
  "$(( $(cat "$GH_CRED_TEST_CLOCK") + 3600 ))"
PROBE
chmod +x "$TMP/probe"

export GH_CRED_TEST_CLOCK="$CLOCK" GH_CRED_TEST_MINT_N="$MINT_N" GH_CRED_TEST_PROBE_N="$PROBE_N"
export GH_CRED_NOW_CMD="$TMP/now"
export GH_CRED_MINT_CMD="$TMP/mint"
export GH_CRED_PROBE_CMD="$TMP/probe"
export GH_CRED_APP_KEY="$KEY"
export GH_CRED_CACHE_DIR="$TMP/cred"

# The ambient credential this box has today. Every fallback must land on exactly this.
AMB="usertoken-ambient"
export GH_TOKEN="$AMB"

# One isolated credential state per scenario: the cache is the thing under test, so reusing it across
# scenarios would make each scenario's first assertion a test of the previous one.
fresh() { rm -rf "$TMP/cred"; mkdir -p "$TMP/cred"; printf '0\n' >"$MINT_N"; printf '0\n' >"$PROBE_N"; }
explain() { python3 "$CRED" --explain "$@" 2>&1; }
armof() { explain "$@" | sed -n 's/.*arm=\([^ ]*\).*/\1/p'; }
credoff() { explain "$@" | sed -n 's/.*credential=\([^ ]*\).*/\1/p'; }

# ── §1 the arm table (pure `decide()`) ─────────────────────────────────────────────────────────
echo "§1 the arm table — which credential, and why"
fresh
ck "a READ takes the app credential when everything is healthy" \
   "$([ "$(armof --kind read --key present --token ok --remaining 4000)" = app ] && echo 0 || echo 1)"

# ⛔ ARM (a) — A WRITE NEVER GOES TO THE APP. Every other input is app-favourable on purpose: a huge
# app budget and a minted token must not be able to move a write. The installation is read-only BY
# PERMISSION, so a write sent there can only 403 — on the rail's merge path.
ck "a WRITE never takes the app credential, even with budget to spare" \
   "$([ "$(armof --kind write --key present --token ok --remaining 99999)" = write ] && echo 0 || echo 1)"
ck "  …and it resolves to the USER credential" \
   "$([ "$(credoff --kind write --key present --token ok --remaining 99999)" = user ] && echo 0 || echo 1)"

# ⛔ ARM (b) — BELOW THE FLOOR.
ck "an app bucket AT the floor falls back (arm=floor)" \
   "$([ "$(armof --kind read --key present --token ok --remaining 500)" = floor ] && echo 0 || echo 1)"
ck "an app bucket BELOW the floor falls back" \
   "$([ "$(armof --kind read --key present --token ok --remaining 499)" = floor ] && echo 0 || echo 1)"
ck "one request ABOVE the floor still uses the app" \
   "$([ "$(armof --kind read --key present --token ok --remaining 501)" = app ] && echo 0 || echo 1)"

# ⛔ ARM (c) — MINT FAILURE, and its two neighbours, each NAMED so an operator can tell "turned off"
# from "broken" from "this box was never given the key".
ck "a mint failure falls back (arm=mint-failed)" \
   "$([ "$(armof --kind read --key present --token fail --remaining 4000)" = mint-failed ] && echo 0 || echo 1)"
ck "no private key falls back, NAMED (arm=no-key)" \
   "$([ "$(armof --kind read --key absent --token ok --remaining 4000)" = no-key ] && echo 0 || echo 1)"
ck "GH_CRED_APP=0 falls back, NAMED (arm=disabled)" \
   "$([ "$(armof --kind read --enabled no --key present --token ok --remaining 4000)" = disabled ] && echo 0 || echo 1)"

# ⛔ THE PACING GUARD — #3429's contradiction test, expressed as an assertion. The meter and the
# credential introspection keep the USER credential, or the fix disarms the layer it sits inside:
# `gh api rate_limit` read through the app would report the APP's remaining and tell the pacing layer
# the USER bucket is healthy, clearing a live limit.
ck "the METER (gh api rate_limit) keeps the user credential" \
   "$([ "$(armof --kind read --purpose meter --key present --token ok --remaining 99999)" = purpose:meter ] && echo 0 || echo 1)"
ck "gh auth … introspection keeps the user credential" \
   "$([ "$(armof --kind read --purpose introspect --key present --token ok --remaining 99999)" = purpose:introspect ] && echo 0 || echo 1)"
ck "an unknown app budget resolves toward the APP, not the user bucket" \
   "$([ "$(armof --kind read --key present --token ok)" = app ] && echo 0 || echo 1)"

# ⛔ THE FAIL-CLOSED ARM. `MUTATING_PAIRS` is a PARTIAL table on purpose, so "not in the write table"
# must never mean "safe for the app". Measured in review: `gh issue lock`, `gh run delete`,
# `gh workflow disable` and `gh issue pin` were ALL routed to the installation token. Nothing checks
# that the installation is read-only (a DEPLOYMENT assumption), so an install carrying any write
# permission would have executed those as the App bot, unattributable.
ck "an UNPROVEN verb keeps the user credential (arm=not-provably-read)" \
   "$([ "$(armof --kind unproven --key present --token ok --remaining 99999)" = not-provably-read ] && echo 0 || echo 1)"
ck "  …and it resolves to the USER credential" \
   "$([ "$(credoff --kind unproven --key present --token ok --remaining 99999)" = user ] && echo 0 || echo 1)"

# ── §2 non-vacuity: REMOVE each arm and watch the assertion fail ───────────────────────────────
echo "§2 non-vacuity — each arm deleted from a copy must break its own assertion"
mutate() {  # <src> <out> <oldtext> <newtext>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src_p, out_p, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = open(src_p).read()
if src.count(old) != 1:
    sys.stderr.write("mutation target present %d times: %r\n" % (src.count(old), old[:90]))
    sys.exit(3)
open(out_p, "w").write(src.replace(old, new, 1))
PY
}

mut() {  # <label> <mutated-src> <explain args> <arm expected WITHOUT the arm>
  local label="$1" src="$2" args="$3" want="$4" got
  # shellcheck disable=SC2086
  got="$(python3 "$src" --explain $args 2>&1 | sed -n 's/.*arm=\([^ ]*\).*/\1/p')"
  ck "$label — with the arm removed the copy answers '$got', so the assertion bites" \
     "$([ "$got" = "$want" ] && echo 0 || echo 1)"
}

MUT="$TMP/mut"
mkdir -p "$MUT"
# ⛔ THE HELPER MUST SIT BESIDE EVERY MUTANT OF `gh-limit.py`. It resolves `gh-cred.py` as a SIBLING
# (the deployment contract), so a mutant in a bare directory loads no helper, takes the `no-helper`
# arm, and every read falls back to the USER credential — which made the very first fallback mutation
# below pass for the wrong reason (the read succeeded because nothing was deciding, not because the
# predicate survived). Copying it here keeps each mutation testing the ONE thing it removes.
cp "$CRED" "$MUT/gh-cred.py"
body() { cat; }

if mutate "$CRED" "$MUT/nowrite.py" '    if kind == "write":
        return Decision("write", "user",
                        "a write is never sent to a read-only installation token")' \
        '    if False:
        pass'; then
  mut "write-arm" "$MUT/nowrite.py" "--kind write --key present --token ok --remaining 99999" app
else fail=$((fail+1)); echo "  FAIL write-arm mutation target missing"; fi

if mutate "$CRED" "$MUT/nofloor.py" \
    '    if app_remaining is not None and int(app_remaining) <= floor:' '    if False:'; then
  mut "floor-arm" "$MUT/nofloor.py" "--kind read --key present --token ok --remaining 100" app
else fail=$((fail+1)); echo "  FAIL floor-arm mutation target missing"; fi

if mutate "$CRED" "$MUT/nomint.py" '    if not token_ok:' '    if False:'; then
  mut "mint-failed-arm" "$MUT/nomint.py" "--kind read --key present --token fail --remaining 4000" app
else fail=$((fail+1)); echo "  FAIL mint-failed-arm mutation target missing"; fi

if mutate "$CRED" "$MUT/nometer.py" '    if purpose != "request":' '    if False:'; then
  mut "meter-pin-arm" "$MUT/nometer.py" \
      "--kind read --purpose meter --key present --token ok --remaining 99999" app
else fail=$((fail+1)); echo "  FAIL meter-pin-arm mutation target missing"; fi

if mutate "$CRED" "$MUT/nokey.py" '    if not key_present:' '    if False:'; then
  mut "no-key-arm" "$MUT/nokey.py" "--kind read --key absent --token ok --remaining 4000" app
else fail=$((fail+1)); echo "  FAIL no-key-arm mutation target missing"; fi

# ── §3 the token cache: mint once, reuse, and re-mint an expired token TRANSPARENTLY ──────────
echo "§3 the token cache — one mint, then a transparent re-mint at expiry"
fresh
t1="$(python3 "$CRED" --token 2>&1)"; rc1=$?
ck "--token mints an installation token" "$([ "$rc1" -eq 0 ] && [ "$t1" = tok-1 ] && echo 0 || echo 1)"
mode="$(stat -c %a "$GH_CRED_CACHE_DIR/token.json" 2>/dev/null || stat -f %Lp "$GH_CRED_CACHE_DIR/token.json" 2>/dev/null)"
ck "the cached token file is mode 0600 (got ${mode:-?})" "$([ "$mode" = 600 ] && echo 0 || echo 1)"

t2="$(python3 "$CRED" --token 2>&1)"
ck "a second call REUSES the cached token (same token, no second mint)" \
   "$([ "$t2" = tok-1 ] && [ "$(cat "$MINT_N")" = 1 ] && echo 0 || echo 1)"

# ⛔ ARM (d) — THE EXPIRY IS NEVER SURFACED. Move the clock inside the 5-minute retire margin: the
# next call must mint a NEW token and SUCCEED. A cached-but-expiring token handed to a caller fails
# mid-call, and the 1-hour ceiling is not configurable — so this behaviour is what replaces a cron,
# i.e. it is the whole "short-lived token, zero scheduled maintenance" claim, asserted.
now="$(cat "$CLOCK")"
printf '%s\n' "$((now + 3600 - 120))" >"$CLOCK"     # 2 minutes of life left: inside the margin
t3="$(python3 "$CRED" --token 2>&1)"; rc3=$?
ck "an EXPIRING cached token is re-minted BEFORE it is used" \
   "$([ "$rc3" -eq 0 ] && [ "$t3" = tok-2 ] && echo 0 || echo 1)"
ck "  …and the re-mint is not surfaced as an error to the caller" "$(ok "$rc3")"
# ⛔ FORWARD past the expiry, never backwards: the fake clock only moves forward in production, and a
# test that rewound it would pass on a cache that never expires. The re-mint above happened at
# now+3480 with a 3600 s life, so now+7200 is past ITS expiry.
printf '%s\n' "$((now + 7200))" >"$CLOCK"
t4="$(python3 "$CRED" --token 2>&1)"
ck "a FULLY EXPIRED cached token is re-minted transparently" \
   "$([ "$t4" = tok-3 ] && echo 0 || echo 1)"
ck "exactly three mints happened across the three refreshes" \
   "$([ "$(cat "$MINT_N")" = 3 ] && echo 0 || echo 1)"

fresh
ck "a failing mint makes --token exit non-zero (an operator must see it)" \
   "$([ "$(GH_CRED_TEST_MINT_FAIL=1 python3 "$CRED" --token >/dev/null 2>&1; echo $?)" != 0 ] && echo 0 || echo 1)"

# ── §4 the JWT is really signed by the static key ─────────────────────────────────────────────
echo "§4 the App JWT — RS256, verified against the key's public half"
if command -v openssl >/dev/null 2>&1; then
  openssl genrsa -out "$TMP/real.pem" 2048 >/dev/null 2>&1 \
    && openssl rsa -in "$TMP/real.pem" -pubout -out "$TMP/real.pub" >/dev/null 2>&1
  jwt_out="$(GH_CRED_APP_KEY="$TMP/real.pem" python3 "$CRED" --jwt 2>&1)"
  # Decode with python, not `awk`/`base64`: awk terminates every record with a newline, so the
  # signing input would gain a byte the signature was never computed over — and the test would fail
  # on a CORRECT JWT (this is how the first draft of this section was wrong).
  python3 - "$jwt_out" "$TMP/jwt.in" "$TMP/jwt.sig" "$TMP/jwt.claims" <<'PY'
import base64, sys
tok, inp, sig, claims = sys.argv[1:5]
parts = tok.split(".")
if len(parts) != 3:
    sys.exit(1)
def dec(x):
    return base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
open(inp, "wb").write((parts[0] + "." + parts[1]).encode())
open(sig, "wb").write(dec(parts[2]))
open(claims, "wb").write(dec(parts[1]))
PY
  ck "the JWT is three dot-separated parts (a malformed one is rejected by GitHub)" "$(ok $?)"
  openssl dgst -sha256 -verify "$TMP/real.pub" -signature "$TMP/jwt.sig" "$TMP/jwt.in" >/dev/null 2>&1
  ck "the JWT's RS256 signature verifies against the static key's public half" "$(ok $?)"
  ck "the JWT carries iss/iat/exp — GitHub rejects a claim-less JWT" \
     "$(grep -q '"iss"' "$TMP/jwt.claims" && grep -q '"exp"' "$TMP/jwt.claims" && echo 0 || echo 1)"
else
  printf '  SKIP openssl is not on PATH — the JWT arm cannot be verified here\n'
fi

# ── §5 the wiring: every arm, through the REAL gh-limit.py ────────────────────────────────────
echo "§5 the wiring — gh-limit.py is what actually picks the credential"
# A stub "real gh" that records the credential it was handed. This is the only thing that proves the
# decision REACHES the child: asserting on `--explain` alone would pass with the injection removed.
cat >"$TMP/stub-gh" <<'STUB'
#!/usr/bin/env bash
printf '%s ARGV=%s\n' "${GH_TOKEN:-<none>}|${GH_CRED_SERVED_ARM:-<none>}" "$*" >>"$GH_CRED_TEST_LOG"
if [ -n "${GH_CRED_TEST_REFUSE_APP:-}" ]; then
  # ⛔ THE REAL WORDING, NOT A CONVENIENT ONE. An installation token whose bucket is empty answers
  # `API rate limit exceeded for installation ID <id>.` — an earlier version of this layer only
  # matched `resource not accessible by integration`, so THIS case never fell back: the read hung
  # through four backoff attempts and then failed, on the box that holds the key (found in review).
  case "${GH_TOKEN:-}" in
    tok-*) echo "API rate limit exceeded for installation ID 179404600. (HTTP 403)" >&2; exit 1 ;;
  esac
fi
printf '{"ok":true}\n'
STUB
chmod +x "$TMP/stub-gh"
export GH_CRED_TEST_LOG="$TMP/calls.log"

# `viah` runs ONE gh argv through the real layer with an isolated credential AND pacing state, and
# prints the arm the child saw for THE CALL ITSELF. ⛔ `tail -1`, NOT `head -1`: a mutation makes this
# layer send its own `api rate_limit` meter probe first, and that probe's line is `purpose:meter` —
# taking the first line would silently assert on the probe instead of on the call under test
# (measured while writing this suite: the write case appeared to fail because it was reading the
# probe's credential).
VSEQ=0
viah() {
  VSEQ=$((VSEQ + 1))
  : >"$GH_CRED_TEST_LOG"
  GH_LIMIT_DIR="$TMP/limit$VSEQ" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 \
    GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_MUTATION_GAP=1 \
    GH_LIMIT_REAL_GH="$TMP/stub-gh" \
    python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- "$@" >/dev/null 2>&1
  tail -1 "$GH_CRED_TEST_LOG" 2>/dev/null
}

fresh
ck "a READ through the layer is served by the INSTALLATION token" \
   "$([ "$(viah pr view 7 | cut -d' ' -f1)" = "tok-1|app" ] && echo 0 || echo 1)"
# ⛔ THE CLASSIFIER ITSELF, PINNED. An unlisted mutating verb must keep the user credential — the
# review measured four of them being served by the installation token because the gate was
# `is_mutating()`'s partial table instead of a positive read allow-list.
ck "an UNLISTED mutating verb (issue lock) keeps the user credential" \
   "$([ "$(viah issue lock 42 | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "an UNLISTED mutating verb (run delete) keeps the user credential" \
   "$([ "$(viah run delete 5 | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "an UNLISTED mutating verb (workflow disable) keeps the user credential" \
   "$([ "$(viah workflow disable ci.yml | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a PROVEN write (api -X POST) keeps the user credential" \
   "$([ "$(viah api -X POST repos/o/r/issues/1/comments -f body=x | cut -d' ' -f1)" = "$AMB|write" ] && echo 0 || echo 1)"
ck "a PROVEN read (api GET) is served by the app — the allow-list is not so narrow it kills the fix" \
   "$([ "$(viah api repos/o/r/pulls/1 | cut -d' ' -f1)" = "tok-1|app" ] && echo 0 || echo 1)"

# ⛔ GRAPHQL IS NOT DECIDED BY `api_is_mutating`, WHICH RETURNS False FOR EVERY `api graphql` CALL.
# Found in review cycle 2, reproduced end-to-end: a GraphQL MUTATION was served by the installation
# token through three different shapes. The fail-closed predicate already existed one function away
# (`_graphql_query_is_read`), so these rows pin that the classifier asks it.
ck "a GraphQL MUTATION keeps the user credential" \
   "$([ "$(viah api graphql -f 'query=mutation{addComment(input:{body:\"x\"}){clientMutationId}}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a GraphQL SUBSCRIPTION keeps the user credential" \
   "$([ "$(viah api graphql -f 'query=subscription{onEvent}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a multi-operation document selected by operationName keeps the user credential" \
   "$([ "$(viah api graphql -f operationName=M -f 'query=query Foo{a} mutation M{b}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a payload we cannot read (-F query=@file) keeps the user credential" \
   "$([ "$(viah api graphql -F 'query=@/tmp/nope.graphql' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a PROVEN GraphQL QUERY is still served by the app (the guard is not a blanket refusal)" \
   "$([ "$(viah api graphql -f 'query=query{viewer{login}}' | cut -d' ' -f1)" = "tok-1|app" ] && echo 0 || echo 1)"

# ⛔ THE GRAPHQL ENDPOINT MUST BE ATTRIBUTED, NOT SCANNED. The first repair used `argv[1:2]`, a
# SECOND-TOKEN scan, so any FLAG before the endpoint hid it and the fall-through served the mutation
# from the installation token — a P0 on this change's own invariant (review cycle 3: the reviewer
# enumerated 162 of 231 write-payload shapes as read-classified). These rows are those bypasses.
ck "a FLAG before the graphql endpoint (-H) does not hide it — the mutation stays on the user credential" \
   "$([ "$(viah api -H 'Accept: application/json' graphql -f 'query=mutation{addComment(input:{body:\"x\"})}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "--hostname before the graphql endpoint does not hide it" \
   "$([ "$(viah api --hostname api.github.com graphql -f 'query=mutation{x}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a -- separator before the graphql endpoint does not hide it" \
   "$([ "$(viah api -- graphql -f 'query=mutation{x}' | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "--input behind a flag before the endpoint stays unproven" \
   "$([ "$(viah api -H 'Accept: x' graphql --input=/tmp/nope.json | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "a FLAG before a REST GET is still a read (the guard is not a blanket refusal)" \
   "$([ "$(viah api -H 'Accept: application/json' repos/o/r/pulls/1 | cut -d' ' -f1)" = "tok-1|app" ] && echo 0 || echo 1)"
ck "a WRITE through the layer keeps the USER credential" \
   "$([ "$(viah pr merge 7 --squash | cut -d' ' -f1)" = "$AMB|not-provably-read" ] && echo 0 || echo 1)"
ck "the METER through the layer keeps the USER credential" \
   "$([ "$(viah api rate_limit | cut -d' ' -f1)" = "$AMB|purpose:meter" ] && echo 0 || echo 1)"
ck "credential INTROSPECTION through the layer keeps the USER credential" \
   "$([ "$(viah auth token | cut -d' ' -f1)" = "$AMB|purpose:introspect" ] && echo 0 || echo 1)"

fresh
ck "an app bucket below the floor falls back THROUGH the layer (arm=floor)" \
   "$([ "$( (export GH_CRED_TEST_REMAINING=10; viah pr view 8) | cut -d' ' -f1)" = "$AMB|floor" ] && echo 0 || echo 1)"

fresh
ck "a mint failure falls back THROUGH the layer (arm=mint-failed)" \
   "$([ "$( (export GH_CRED_TEST_MINT_FAIL=1; viah pr view 9) | cut -d' ' -f1)" = "$AMB|mint-failed" ] && echo 0 || echo 1)"

# ⛔ ARM 4/6 — THE APP'S REAL FAILURE MUST FALL BACK, AND THE CALL MUST STILL ANSWER.
# This is the review-found P1, pinned: an installation bucket that is empty answers
# `API rate limit exceeded for installation ID <id>. (HTTP 403)`, which matches no credential-shaped
# phrase. The layer must retry ONCE on the user credential, the call must SUCCEED, and the app budget
# must be corrected so the NEXT call takes the `floor` arm instead of repeating the failure all hour.
fresh
rc_refused=$( export GH_CRED_TEST_REFUSE_APP=1 2>/dev/null
  GH_LIMIT_DIR="$TMP/lr" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 GH_LIMIT_CONDITIONAL=0 \
  GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
  python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- pr view 10 >/dev/null 2>&1; echo $? )
fresh
( export GH_CRED_TEST_REFUSE_APP=1; viah pr view 10 >/dev/null )
ck "a dry installation bucket RETRIES once on the user credential (arm=app-dry)" \
   "$([ "$(tail -1 "$GH_CRED_TEST_LOG" | cut -d' ' -f1)" = "$AMB|app-dry" ] && echo 0 || echo 1)"
ck "  …and the read still returns a SUCCESSFUL answer (it does not hang or fail)" "$(ok "$rc_refused")"
ck "  …and the app budget is RECORDED as dry, so the next call takes the floor arm" \
   "$([ "$(sed -n 's/.*"remaining": *\([0-9]*\).*/\1/p' "$GH_CRED_CACHE_DIR/app-budget.json" 2>/dev/null)" = 0 ] && echo 0 || echo 1)"

# ⛔ THE 404 SHAPE. GitHub answers `Not Found` for a resource outside an installation's granted
# scope — no credential-shaped phrase at all — so a text allowlist left the read permanently failing
# with "Not Found", which callers read as "the resource does not exist" (#3584's class).
fresh
STUB_404=1
cat >"$TMP/stub-404" <<'S404'
#!/usr/bin/env bash
printf '%s ARGV=%s\n' "${GH_TOKEN:-<none>}|${GH_CRED_SERVED_ARM:-<none>}" "$*" >>"$GH_CRED_TEST_LOG"
case "${GH_TOKEN:-}" in tok-*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;; esac
printf '{"ok":true}\n'
S404
chmod +x "$TMP/stub-404"
: >"$GH_CRED_TEST_LOG"
rc_404=$( GH_LIMIT_DIR="$TMP/l404" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 \
  GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-404" \
  python3 "$LIMIT" --real-gh "$TMP/stub-404" -- pr view 12 >/dev/null 2>&1; echo $? )
ck "an installation 404 (repo outside its scope) falls back and the read SUCCEEDS" "$(ok "$rc_404")"
ck "  …named arm=app-refused, so the failure is attributable to the credential" \
   "$([ "$(tail -1 "$GH_CRED_TEST_LOG" | cut -d' ' -f1)" = "$AMB|app-refused" ] && echo 0 || echo 1)"

# ⛔ AND THE ANSWER PRODUCED BY THE RETRY IS STAMPED WITH THE CREDENTIAL THAT PRODUCED IT. It was
# stamped `app` while the bytes came from the user credential — defeating T3 on the one path where the
# two PROVABLY differ in visibility. The pass cache is inspected directly because that is the entry a
# later caller would have replayed.
fresh
cat >"$TMP/readstub" <<'RS'
#!/usr/bin/env bash
printf '%s ARGV=%s\n' "${GH_TOKEN:-<none>}|${GH_CRED_SERVED_ARM:-<none>}" "$*" >>"$GH_CRED_TEST_LOG"
case "${GH_TOKEN:-}" in tok-*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;; esac
printf '{"ok":true}\n'
RS
chmod +x "$TMP/readstub"
: >"$GH_CRED_TEST_LOG"
PASSD="$TMP/pass1"
GH_LIMIT_DIR="$TMP/lstamp" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE="$PASSD" \
  GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/readstub" \
  python3 "$LIMIT" --real-gh "$TMP/readstub" -- api user >/dev/null 2>&1 || true
_stamp="$(cat "$PASSD"/*.json 2>/dev/null | sed -n 's/.*"cred": *"\([a-z]*\)".*/\1/p' | head -1)"
ck "an answer produced by the post-fallback retry is cached as cred=user, not cred=app (got '${_stamp:-none}')" \
   "$([ "${_stamp:-none}" = user ] && echo 0 || echo 1)"

# ⛔ AND ALL FOUR CREDENTIAL NAMES ARE SET, not `GH_TOKEN` alone: on a non-github.com host `gh`
# reads the ENTERPRISE pair, so a single-name injection would serve that box from the user credential
# while the arm, `_CRED_CLASS` and `--stats` all said `app` — a false PASS of the regression assertion.
fresh
cat >"$TMP/envstub" <<'ES'
#!/usr/bin/env bash
printf 'TOK=%s ENT=%s ENT2=%s\n' "${GH_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}" >>"$GH_CRED_TEST_LOG"
printf '{"ok":true}\n'
ES
chmod +x "$TMP/envstub"
: >"$GH_CRED_TEST_LOG"
GH_LIMIT_DIR="$TMP/lenv" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 GH_LIMIT_CONDITIONAL=0 \
  GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/envstub" \
  python3 "$LIMIT" --real-gh "$TMP/envstub" -- pr view 13 >/dev/null 2>&1 || true
_envline="$(grep '^TOK=' "$GH_CRED_TEST_LOG" | tail -1)"
ck "the app token is set for ALL four credential names (enterprise hosts read the pair, not GH_TOKEN)" \
   "$(grep -q '^TOK=tok-.*ENT=tok-.*ENT2=tok-' <<<"$_envline" && echo 0 || echo 1)"

# ⛔ THE CLASS IS SET PER CALL, NOT ONCE PER PROCESS. `run()` can be called more than once in one
# process (the dispatch retry loop calls it per attempt) and the fallback mutates the global, so a
# LATER app-served call was writing its bytes stamped `cred: user` — a narrower app-side answer
# replayed as a HIT with rc 0 to user-credentialed callers, i.e. T3 failing in the reverse direction
# (found in review cycle 2). This pins the invariant directly: after an APP-served call, whatever the
# global said before, it says `app`.
cat >"$TMP/classprobe.py" <<'CP'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gh_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class D(object):
    arm = "app"
    credential = "app"
    token = "tok-seeded"

# Seed the per-(kind,purpose) decision cache so no mint and no helper is needed.
m._CRED_CACHE[("read", "request")] = D()
m._CRED_CLASS = "user"                      # the state a previous fallback leaves behind
m.run(sys.argv[2], ["pr", "view", "1"])
sys.stdout.write(m._CRED_CLASS)
CP
ck "after an APP-served call the stamped class is 'app' even if a previous call left it 'user'" \
   "$([ "$(python3 "$TMP/classprobe.py" "$LIMIT" "$TMP/stub-gh" 2>/dev/null)" = app ] && echo 0 || echo 1)"

# ⛔ AND THE FALLBACK MUST NOT MUTATE THE CACHED DECISION. `credential_for()` caches it per
# (kind, purpose), so `cred.arm = arm` rewrote a SHARED object and the NEXT `run()` in the same process
# injected `GH_CRED_SERVED_ARM=app-dry` for a call the app actually served — a successful, app-served
# attempt attributed as a fallback (review cycle 3).
cat >"$TMP/armprobe.py" <<'AP'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gh_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class D(object):
    arm = "app"
    credential = "app"
    token = "tok-1"

d = D()
m._CRED_CACHE[("read", "request")] = d
m.run(sys.argv[2], ["pr", "view", "1"])          # the app is refused -> a fallback happens
sys.stdout.write(d.arm)                            # the CACHED decision's arm, after that fallback
AP
_arm_after="$(GH_CRED_TEST_REFUSE_APP=1 python3 "$TMP/armprobe.py" "$LIMIT" "$TMP/stub-gh" 2>/dev/null)"
ck "a fallback does not rewrite the CACHED decision's arm (got '${_arm_after}')" \
   "$([ "$_arm_after" = app ] && echo 0 || echo 1)"

# ⛔ NON-VACUITY: with the fallback predicate removed, the SAME read must FAIL. If this row passed
# with the predicate gone, the three assertions above would be proven by nothing.
if mutate "$LIMIT" "$MUT/nofallback.py" 'def _app_failed(res):
    """The app served this call and the call did not succeed. Fall back on the user credential."""
    return res.rc != 0' 'def _app_failed(res):
    return False'; then
  fresh
  rc_nofb=$( export GH_CRED_TEST_REFUSE_APP=1 2>/dev/null
    GH_LIMIT_DIR="$TMP/lrnf" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 GH_LIMIT_CONDITIONAL=0 \
    GH_LIMIT_FLIGHT=0 GH_LIMIT_NO_WAIT=1 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
    timeout 120 python3 "$MUT/nofallback.py" --real-gh "$TMP/stub-gh" -- pr view 11 >/dev/null 2>&1; echo $? )
  ck "  …and removing the fallback predicate makes the same read FAIL (the arm is load-bearing)" \
     "$([ "$rc_nofb" -ne 0 ] && echo 0 || echo 1)"
else fail=$((fail+1)); echo "  FAIL fallback-predicate mutation target missing"; fi

# ⛔ NON-VACUITY OF THE WIRING ITSELF: with the injection deleted from a copy of gh-limit.py, the
# same read must be served by the USER credential. Without this row §5 could pass on a gh-cred.py
# that nothing calls. The helper is copied beside the mutant because `gh-limit.py` resolves
# `gh-cred.py` as a SIBLING — the deployment contract, which this test therefore also pins.
if mutate "$LIMIT" "$MUT/noinject.py" '    if cred.token:' '    if False:'; then
  cp "$CRED" "$MUT/gh-cred.py"
  fresh
  : >"$GH_CRED_TEST_LOG"
  GH_LIMIT_DIR="$TMP/limitmut" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 \
    GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
    python3 "$MUT/noinject.py" --real-gh "$TMP/stub-gh" -- pr view 11 >/dev/null 2>&1
  ck "with the token injection removed the read falls back to the user credential (wiring is load-bearing)" \
     "$([ "$(tail -1 "$GH_CRED_TEST_LOG" | cut -d' ' -f1)" = "$AMB|app" ] && echo 0 || echo 1)"
else fail=$((fail+1)); echo "  FAIL gh-limit.py injection mutation target missing"; fi

# ── §6 the regression assertion: a read on the user credential is a DEFECT ────────────────────
echo "§6 the regression assertion — reads served by the user credential are counted"
fresh
VSEQ=$((VSEQ + 1))
GH_LIMIT_DIR="$TMP/limit6" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 GH_LIMIT_CONDITIONAL=0 \
  GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
  python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- pr view 12 >/dev/null 2>&1
stats="$(python3 "$CRED" --stats 2>&1)"; src=$?
ck "a healthy read is counted on the app arm" "$(grep -q 'arm app' <<<"$stats" && echo 0 || echo 1)"
ck "  …and the read-on-user regression count stays 0" \
   "$(grep -q 'reads-on-user-unjustified: 0' <<<"$stats" && echo 0 || echo 1)"
ck "  …and --stats exits 0 when nothing is unjustified" "$(ok "$src")"

# The DEFECT, reproduced: force the user credential onto a read. This is what "the layer is not
# wired" looks like, and it must be VISIBLE — counted, named, and a non-zero exit.
fresh
GH_CRED_ARM_OVERRIDE=user GH_LIMIT_DIR="$TMP/limit7" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 \
  GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
  python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- pr view 13 >/dev/null 2>&1
stats="$(python3 "$CRED" --stats 2>&1)"; src=$?
ck "a READ forced onto the user credential IS counted as unjustified" \
   "$(grep -q 'READS-ON-USER-UNJUSTIFIED n=1' <<<"$stats" && echo 0 || echo 1)"
ck "  …and --stats then exits non-zero, so a caller can gate on it" \
   "$([ "$src" -ne 0 ] && echo 0 || echo 1)"

# ── §7 the two credentials must not share a cache entry ───────────────────────────────────────
echo "§7 the response caches refuse an answer produced by the OTHER credential"
# ⛔ THE INSTALLATION TOKEN AND THE USER CREDENTIAL CAN SEE DIFFERENT REPOSITORIES. A body — or a
# 404 — produced under one and replayed to the other is a wrong answer with rc 0, i.e. "the call
# failed and the caller read the failure as no data" (#3584's own class), and it is SILENT.
#
# ⛔ AND THE FIRST ATTEMPT AT THIS WAS WRONG, WHICH IS WHY THE TEST LOOKS LIKE THIS. Mixing the served
# arm into `_cred_digest()` made `cache_key`/`flight_key` depend on process state that only exists
# after `main()` runs, so the key stopped being computable from the invocation — gh-limit.test.sh
# caught it with three failures (its takeover and orphan-reclaim arms plant a claim by computing
# `flight_key(argv)` out-of-process, and the claim landed on a different path). The fix keeps keys
# PURE and puts the credential on the ENTRY; this asserts the entry-level guard, and mutating it
# proves the guard is what stands between the two credentials.
cat >"$TMP/credprobe.py" <<'CP'
import importlib.util, os, sys
os.environ.setdefault("GH_LIMIT_DIR", sys.argv[2])
spec = importlib.util.spec_from_file_location("gh_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
key = "probe|" + sys.argv[3]
if sys.argv[4] == "write-app":
    m._CRED_CLASS = "app"
    m.cache_put(key, '"etag-a"', b'{"who":"app"}')
else:
    m._CRED_CLASS = "app" if sys.argv[4] == "read-app" else "user"
    sys.stdout.write("hit" if m.cache_get(key) else "miss")
CP
_probe() { python3 "$TMP/credprobe.py" "$1" "$2" "$3" "$4" 2>&1; }

rm -rf "$TMP/cachep"; mkdir -p "$TMP/cachep"
_probe "$LIMIT" "$TMP/cachep" k1 write-app >/dev/null
ck "an answer produced by the app credential is a HIT for the app credential" \
   "$([ "$(_probe "$LIMIT" "$TMP/cachep" k1 read-app)" = hit ] && echo 0 || echo 1)"
ck "  …and a MISS for the user credential (an answer never crosses credentials)" \
   "$([ "$(_probe "$LIMIT" "$TMP/cachep" k1 read-user)" = miss ] && echo 0 || echo 1)"

if mutate "$LIMIT" "$MUT/nocredguard.py" '            if not _cred_class_ok(d):
                return None' '            if False:
                return None'; then
  rm -rf "$TMP/cachep2"; mkdir -p "$TMP/cachep2"
  _probe "$MUT/nocredguard.py" "$TMP/cachep2" k2 write-app >/dev/null
  ck "  …and removing the guard makes the app's answer visible to the user credential (it bites)" \
     "$([ "$(_probe "$MUT/nocredguard.py" "$TMP/cachep2" k2 read-user)" = hit ] && echo 0 || echo 1)"
else fail=$((fail+1)); echo "  FAIL credential-guard mutation target missing"; fi

# ── §8 a failing mint is NEGATIVELY CACHED ─────────────────────────────────────────────────────
echo "§8 a failed mint is cooled down — a revoked key costs ONE attempt, not one per call"
# ⛔ WITHOUT THIS, EVERY gh CALL PAYS A MINT. `resolve()` runs once per invocation, so a rotated key
# on the controller (the only box that holds one) adds a JWT sign plus a network attempt — up to
# GH_CRED_MINT_TIMEOUT seconds — to every read, on the path that gates dispatch. Measured in review:
# three reads, three mint attempts, 2.09 s of pure mint latency on one read.
fresh
for _i in 1 2 3; do
  GH_CRED_TEST_MINT_FAIL=1 python3 "$CRED" --token >/dev/null 2>&1 || true
done
ck "three sequential reads against a FAILING mint attempt it only ONCE (cooldown absorbs the rest)" \
   "$([ "$(cat "$MINT_N")" = 1 ] && echo 0 || echo 1)"
fresh
ck "…and a FAILING mint still reports failure to the caller (the cooldown hides no error)" \
   "$([ "$(GH_CRED_TEST_MINT_FAIL=1 python3 "$CRED" --token >/dev/null 2>&1; echo $?)" != 0 ] && echo 0 || echo 1)"

# ── §9 the guard has a DEFAULT, and the diagnostic does not count ─────────────────────────────────
echo "§9 a guard with no default, and a diagnostic that leaves no trace"
# ⛔ `_CRED_CLASS` is read by EVERY cache consumer (`_cred_class_ok`, `cache_put`, `pass_cache_put`,
# `flight_publish`, `read_cache_put`) and used to exist only after `main()`/`run()` bound it via
# `global` — so a consumer reached first raised NameError, which no handler in those functions catches.
# The PR's own §7 had to plant the attribute by hand, which is the same defect from the other side.
ck "_CRED_CLASS has a module-level default (an unlabelled entry is 'user', and no NameError)" \
   "$(python3 - "$LIMIT" <<'PY'
import importlib.util, sys, tempfile, os
os.environ.setdefault("GH_LIMIT_DIR", tempfile.mkdtemp())
spec = importlib.util.spec_from_file_location("gl_default_probe", sys.argv[1])
gl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gl)
if getattr(gl, "_CRED_CLASS", None) != "user":
    print(1); raise SystemExit
try:
    gl.cache_put("default-probe", '"e"', b'{"x":1}')
except NameError:
    print(1); raise SystemExit
print(0)
PY
)"

# ⛔ A DIAGNOSTIC MUST NOT MOVE THE COUNTER IT EXPLAINS. `--which` runs the real decision path
# (including a mint) and used to RECORD it too: that inflated the `app` arm in `--stats`, and under
# `GH_CRED_ARM_OVERRIDE=user` a single `--which` made `--stats` exit 3 with READS-ON-USER-UNJUSTIFIED.
fresh
for _i in 1 2 3; do python3 "$CRED" --which -- pr view "$_i" >/dev/null 2>&1; done
ck "three --which runs record NO decision (the diagnostic cannot move the counter)" \
   "$([ ! -s "$TMP/cred/decisions.log" ] && echo 0 || echo 1)"
fresh
( export GH_CRED_ARM_OVERRIDE=user
  for _i in 1 2 3; do python3 "$CRED" --which -- pr view "$_i" >/dev/null 2>&1; done
  python3 "$CRED" --stats >/dev/null 2>&1; echo $? >"$TMP/wrc" )
ck "  …so --which under ARM_OVERRIDE=user leaves --stats exiting 0 (not the 3 it used to cause)" \
   "$([ "$(cat "$TMP/wrc")" -eq 0 ] && echo 0 || echo 1)"

# ⛔ THE EXPIRY PARSE IS DST-INSENSITIVE, AND THE JULY STAMP IS THE ONE THAT PROVES IT. `mktime() -
# time.timezone` has no DST term, so on a DST host a cached expiry was an hour out for part of the year.
# ⛔ NOVEMBER ALONE IS NOT A TEST: under `TZ=Europe/Madrid` the winter offset IS `time.timezone`, so the
# two terms cancel and the old expression returns the right number — a November-only assertion passes
# on the pre-fix code and certifies a fix it never exercises (measured: July 1783375200 vs true
# 1783378800; November 1794006000, correct either way). Both stamps are asserted, July last.
ck "_epoch() is DST-insensitive (the JULY Z stamp is the one the old mktime form got wrong)" \
   "$(TZ=Europe/Madrid python3 - "$CRED" <<'PY'
import importlib.util, sys, os, time
time.tzset()
# ⛔ THE PROBE ITSELF NEEDS A GUARD. This assertion discriminates the fix ONLY on a DST-observing
# zone: with no `Europe/Madrid` tzdata (scratch/distroless images, reduced tzdata) `time.timezone`
# falls back to 0, the two terms stop cancelling, and the PRE-FIX `mktime() - time.timezone` form
# returns the correct 1783378800 — i.e. the row would silently certify a fix it never exercised, which
# is exactly the failure it was added to kill, relocated to a host property (measured: TZ=Nope/Nowhere
# → old == new == 1783378800). Fail LOUDLY instead of vacuously.
if time.timezone != -3600:
    print(1); raise SystemExit
spec = importlib.util.spec_from_file_location("gc_epoch_probe", sys.argv[1])
gc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gc)
# Independently computed: date -u -d 2026-11-06T23:00:00Z → 1794006000
#                       date -u -d 2026-07-06T23:00:00Z → 1783378800 (the old form gave 1783375200)
ok = gc._epoch("2026-11-06T23:00:00Z") == 1794006000 and gc._epoch("2026-07-06T23:00:00Z") == 1783378800
print(0 if ok else 1)
PY
)"

# ── §10 the argv-attribution family, ENUMERATED ─────────────────────────────────────────────────
echo "§10 the argv-attribution family — an enumerated cross-product, not one-off rows"
# ⛔ THREE REVIEW CYCLES FOUND THREE SPELLINGS OF THE SAME BUG: a flag before `graphql`; `-t graphql`
# as a flag VALUE tripping `api_is_mutating`'s `graphql = True` shortcut; a query string on `rate_limit`
# defeating the meter pin. One-off rows never close a family — an enumeration does, and it is the
# method the reviewers used, so it belongs here rather than in a review transcript.
cat >"$TMP/enumerate.py" <<'EN'
import importlib.util, itertools, sys
spec = importlib.util.spec_from_file_location("gh_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

prefixes = [[], ["-H", "Accept: x"], ["--hostname", "api.github.com"], ["--"], ["--paginate"],
            ["-q", "."], ["-t", "graphql"], ["-i"], ["--silent"], ["-p", "x"],
            ["--cache", "60m"], ["-H", "Accept: x", "-H", "Y: z"]]
gql_endpoints = [["graphql"], ["/graphql"], ["GRAPHQL"], ["graphql?x=1"], ["graphql#f"]]
rest_endpoints = [["repos/o/r/issues"], ["/repos/o/r/issues/"]]
write_payloads = [
    ["-f", "query=mutation{addComment(input:{body:\"x\"}){clientMutationId}}"],
    ["-f", "query=subscription{onEvent}"],
    ["-f", "operationName=M", "-f", "query=query Q{a} mutation M{b}"],
    ["-F", "query=@/tmp/m.graphql"],
    ["-f", "query=MUTATION M{addComment(input:{body:\"x\"}){clientMutationId}}"],
]
rest_writes = [["-f", "title=x"], ["-F", "body=@/tmp/b"], ["--input", "/tmp/b"],
               ["-X", "PATCH"], ["--method=DELETE"]]

bypass = []
checked = 0
for pre, ep, pl in itertools.product(prefixes, gql_endpoints, write_payloads):
    argv = ["api"] + pre + ep + pl
    checked += 1
    if m.cred_kind(argv) == "read":
        bypass.append(" ".join(argv))
for pre, ep, pl in itertools.product(prefixes, rest_endpoints, rest_writes):
    argv = ["api"] + pre + ep + pl
    checked += 1
    if m.cred_kind(argv) == "read":
        bypass.append(" ".join(argv))
# And the meter pin, under the same spellings.
# ⛔ INCLUDING THE COMBINED ONES. Varying each axis separately missed `checkpoint+trailing slash +
# query/fragment`: `/rate_limit/?x=1`, `rate_limit/#f`, `rate_limit/?x=1#f` and `/RATE_LIMIT/?x=1`
# normalised to `rate_limit/` (the query was stripped AFTER the slashes) and answered `request`, so the
# pacing layer's own meter was served from the INSTALLATION's remaining. A family closed per-axis
# survives in the cross-product (review).
meter_bad = []
for pre in prefixes:
    for ep in (["rate_limit"], ["/rate_limit"], ["RATE_LIMIT"], ["rate_limit?x=1"], ["rate_limit#f"],
               ["/rate_limit/?x=1"], ["rate_limit/#f"], ["rate_limit/?x=1#f"], ["/RATE_LIMIT/?x=1"],
               ["rate_limit/#f?x=1"], ["/rate_limit/#f"]):
        argv = ["api"] + pre + ep
        checked += 1
        if m.cred_purpose(argv) != "meter":
            meter_bad.append(" ".join(argv))
# ⛔ AND THE ENUMERATION MUST NOT BE ALL-REFUSALS. If every shape answered `unproven`, the loop above
# would pass while the fix was useless — so legitimate reads must still classify `read`.
reads_ok = 0
for pre, ep in itertools.product(prefixes, [["graphql"], ["/repos/o/r/pulls"]]):
    argv = ["api"] + pre + ep + (["-f", "query=query{viewer{login}}"] if "graphql" in ep else [])
    checked += 1
    if m.cred_kind(argv) == "read":
        reads_ok += 1

sys.stdout.write("checked=%d bypass=%d meter_bad=%d reads_ok=%d\n"
                 % (checked, len(bypass), len(meter_bad), reads_ok))
for b in bypass[:5]:
    sys.stdout.write("  BYPASS: %s\n" % b)
for b in meter_bad[:5]:
    sys.stdout.write("  METER: %s\n" % b)
sys.exit(0 if (not bypass and not meter_bad and reads_ok > 0) else 1)
EN
_enum="$(python3 "$TMP/enumerate.py" "$LIMIT" 2>&1)"; _enum_rc=$?
ck "no enumerated write shape classifies as a read, and the meter pin holds ($(printf '%s' "$_enum" | head -1))" "$(ok "$_enum_rc")"
printf '%s\n' "$_enum" | sed -n 's/^  /     /p' | head -6

echo
printf '%s\n' "----------------------------------------"
printf 'gh-cred: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

