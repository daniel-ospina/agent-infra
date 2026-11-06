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
  case "${GH_TOKEN:-}" in tok-*) echo "Resource not accessible by integration (403)" >&2; exit 1 ;; esac
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
ck "a WRITE through the layer keeps the USER credential" \
   "$([ "$(viah pr merge 7 --squash | cut -d' ' -f1)" = "$AMB|write" ] && echo 0 || echo 1)"
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

# ⛔ ARM 4 — the App REFUSES a read. The call must still answer, on the USER credential, once.
fresh
( export GH_CRED_TEST_REFUSE_APP=1; viah pr view 10 >/dev/null )
ck "the App refusing a read retries ONCE on the USER credential" \
   "$([ "$(tail -1 "$GH_CRED_TEST_LOG" | cut -d' ' -f1)" = "$AMB|scope-403" ] && echo 0 || echo 1)"
fresh
rc_refused=$( export GH_CRED_TEST_REFUSE_APP=1
  GH_LIMIT_DIR="$TMP/lr" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 GH_LIMIT_CONDITIONAL=0 \
  GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
  python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- pr view 10 >/dev/null 2>&1; echo $? )
ck "  …and the refused call still returns a SUCCESSFUL answer (not an error)" "$(ok "$rc_refused")"

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
ck "a healthy read is counted on the app arm" "$(printf '%s' "$stats" | grep -q 'arm app' && echo 0 || echo 1)"
ck "  …and the read-on-user regression count stays 0" \
   "$(printf '%s' "$stats" | grep -q 'reads-on-user-unjustified: 0' && echo 0 || echo 1)"
ck "  …and --stats exits 0 when nothing is unjustified" "$(ok "$src")"

# The DEFECT, reproduced: force the user credential onto a read. This is what "the layer is not
# wired" looks like, and it must be VISIBLE — counted, named, and a non-zero exit.
fresh
GH_CRED_ARM_OVERRIDE=user GH_LIMIT_DIR="$TMP/limit7" GH_LIMIT_READ_CACHE=0 GH_LIMIT_PASS_CACHE=0 \
  GH_LIMIT_CONDITIONAL=0 GH_LIMIT_FLIGHT=0 GH_LIMIT_REAL_GH="$TMP/stub-gh" \
  python3 "$LIMIT" --real-gh "$TMP/stub-gh" -- pr view 13 >/dev/null 2>&1
stats="$(python3 "$CRED" --stats 2>&1)"; src=$?
ck "a READ forced onto the user credential IS counted as unjustified" \
   "$(printf '%s' "$stats" | grep -q 'READS-ON-USER-UNJUSTIFIED n=1' && echo 0 || echo 1)"
ck "  …and --stats then exits non-zero, so a caller can gate on it" \
   "$([ "$src" -ne 0 ] && echo 0 || echo 1)"

# ── §7 the two credentials must not share a cache entry ───────────────────────────────────────
echo "§7 the ETag/flight cache is credential-partitioned (a body must not cross arms)"
# ⛔ THE INSTALLATION TOKEN AND THE USER CREDENTIAL CAN SEE DIFFERENT REPOSITORIES. A body — or a
# 404 — cached under one and replayed to the other is a wrong answer with rc 0, i.e. "the call failed
# and the caller read the failure as no data" (#3584's own class), and it is SILENT. The arm is mixed
# into `_cred_digest()`, and this pins it: same host, same path, different arm, different key.
cat >"$TMP/keyprobe.py" <<'KP'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gh_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
plan = {"host": "github.com", "path": "repos/o/r/pulls/1"}
m._CRED_ARM = "app"
k_app = m.cache_key(plan)
m._CRED_ARM = "write"
k_write = m.cache_key(plan)
sys.stdout.write("same\n" if k_app == k_write else "differ\n")
KP
ck "the same path under two arms yields two different cache keys" \
   "$([ "$(python3 "$TMP/keyprobe.py" "$LIMIT")" = differ ] && echo 0 || echo 1)"

mutate "$LIMIT" "$MUT/nodigest.py" '    return "%s.%s" % (base, _CRED_ARM)' '    return base' \
  && ck "  …and removing the arm from the digest collapses them into ONE key (the partition bites)" \
         "$([ "$(python3 "$TMP/keyprobe.py" "$MUT/nodigest.py")" = same ] && echo 0 || echo 1)" \
  || { fail=$((fail+1)); echo "  FAIL digest mutation target missing"; }

echo
printf '%s\n' "----------------------------------------"
printf 'gh-cred: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
