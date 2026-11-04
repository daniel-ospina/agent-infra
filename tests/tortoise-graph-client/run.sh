#!/usr/bin/env bash
# tests/tortoise-graph-client/run.sh — R5: the fallback client calls the SERVED surface.
#
# WHY THIS SUITE EXISTS. The PR that delivered `scripts/tortoise-graph.sh` + its client shipped two
# call sites that did not match the served tool signatures (`point_id` for `id`; `label` for the
# predicate field). The lesson recorded from that was "verify calls against the served surface" —
# and then the surface RETIRED three of the handlers the client calls (#3883), which no arm noticed:
#
#   * `tortoise_get_point`, `tortoise_health`, `tortoise_list_pointkinds` are no longer advertised.
#     They still ANSWER, and every answer carries a SECOND text content block — a
#     `RETIRED TOOL: …` notice — which the client folds into the payload with `"\n".join`.
#   * So `get`/`health`/`stats` printed their JSON *plus* a paragraph, exit code 0, and the file's
#     own documented contract ("Prints the tool result as JSON on stdout") stopped holding.
#     `get <id> | python3 -c 'json.load(sys.stdin)'` fails. Nothing reddened.
#
# The arms below therefore assert three things, and the second is the one that would have caught it:
#   1. THE CALL: the recorded `tools/call` name is an ADVERTISED tool, with the right arguments.
#   2. THE PAYLOAD: stdout parses as JSON on its own — a retired-tool notice is a REFUSAL (exit 4),
#      not a commentary appended to the answer.
#   3. THE NOT-FOUND CASE: `{}` from the server is a failed read (exit 4), never a green.
#
# Hermetic: a local stub (`stub.py`) answers every call; no network, no key, no real graph.
# `TORTOISE_API_URL` points the wrapper at it — the same seam a self-hosted box uses.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$ROOT/scripts/tortoise-graph.sh"
STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stub.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/graph-client-suite.XXXXXX")"
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "$SRV_PID" ] && wait "$SRV_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "   ❌ $1"; }

[ -f "$WRAPPER" ] && [ -f "$STUB" ] || { echo "   ❌ missing $WRAPPER or $STUB"; echo "FAILURES=1"; exit 1; }

# A port nobody is on. Bound to loopback only, so the suite never listens on a routable address.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ -n "$PORT" ] || { echo "   ❌ could not allocate a loopback port"; echo "FAILURES=1"; exit 1; }

echo "== the stub MCP server"
python3 "$STUB" "$TMP" "$PORT" >"$TMP/stub.log" 2>&1 &
SRV_PID=$!
ok_server=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if python3 - "$PORT" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)
s.close()
PY
  then ok_server=1; break; fi
  sleep 0.1
done
if [ "$ok_server" -eq 1 ]; then
  pass "the stub is answering on 127.0.0.1:$PORT (loopback only; no network, no key)"
else
  fail "the stub never came up — every arm below would be unattributable"; cat "$TMP/stub.log"
  echo "FAILURES=$failures"; exit 1
fi

mode() { printf '%s' "$1" > "$TMP/mode"; : > "$TMP/calls.jsonl"; }
call() {   # call <desc-out-var-prefix> <args…>; sets OUT/ERR/RC
  OUT="$(TORTOISE_API_URL="http://127.0.0.1:$PORT" TORTOISE_MCP_API_KEY="stub-key" \
         bash "$WRAPPER" "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
# The name+arguments of the LAST tools/call the server received ("-" when there was none). This is
# what pins the CALL SITE — an assertion on stdout alone cannot tell a migrated client from one that
# still calls the retired handler (both would print a point, one of them with a notice appended).
last_call() {
  python3 - "$TMP/calls.jsonl" <<'PY'
import json, sys
name, args = "-", "-"
try:
    for line in open(sys.argv[1]):
        b = json.loads(line)
        if b.get("method") == "tools/call":
            name = (b.get("params") or {}).get("name", "-")
            args = json.dumps((b.get("params") or {}).get("arguments") or {}, sort_keys=True)
except FileNotFoundError:
    pass
print("%s\t%s" % (name, args))
PY
}
advertised() {   # is $1 a tool the served `tools/list` advertises?
  python3 - "$1" <<'PY'
import json, sys
# The stub's `tools/list` is the single source for "advertised" in this suite: the client is not
# allowed to call anything it does not serve. Kept in step with stub.ADVERTISED by construction —
# the STUB answers tools/list, so this arm reads the same list the client would.
print("yes" if sys.argv[1] in {
    "tortoise_get_entity", "tortoise_overview", "tortoise_search", "tortoise_create_point",
} else "no")
PY
}

echo "== get: the ADVERTISED handler, the right arguments, and nothing else on stdout"
mode ok
call get pt_abc
[ "$RC" -eq 0 ] && pass "get exits 0 against a healthy answer" \
  || fail "get exited $RC on a healthy answer (stderr: $ERR)"
name="$(last_call | cut -f1)"
args="$(last_call | cut -f2)"
[ "$name" = "tortoise_get_entity" ] && pass "get calls tortoise_get_entity (not the RETIRED tortoise_get_point)" \
  || fail "get called '$name' — #3883 RETIRED tortoise_get_point, so this verb reads a handler the surface no longer advertises"
[ "$args" = '{"id": "pt_abc", "type": "point"}' ] && pass "get passes {id, type:\"point\"} — the served signature" \
  || fail "get passed $args — the served signature is (id, type)"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("id")=="pt_abc" else 1)' 2>/dev/null \
  && pass "get PRINTS PARSEABLE JSON on stdout (the flag did not end up in the payload)" \
  || fail "get's stdout is not a JSON object — a lane doing 'get <id> | json.load' dies (got: $(printf '%s' "$OUT" | head -c 120))"

echo "== a RETIRED-tool notice is a REFUSAL, not a paragraph appended to the answer (#3883)"
mode retired
call get pt_abc
[ "$RC" -eq 4 ] && pass "a RETIRED TOOL notice exits 4 — the answer is not the tool's result" \
  || fail "a retired-tool answer exited $RC (must be 4): the payload is contaminated, so exit 0 reports 'a point' where the server said 'this tool is retired'"
printf '%s' "$ERR" | grep -q 'GRAPH-RETIRED-TOOL' \
  && pass "…and NAMES it: GRAPH-RETIRED-TOOL on stderr, with the server's own notice" \
  || fail "…but never named the retirement (stderr: $ERR)"
[ -z "$OUT" ] && pass "…and prints NOTHING on stdout, so a piped consumer sees no half-answer" \
  || fail "…but still printed a payload on stdout: $(printf '%s' "$OUT" | head -c 120)"
# ⛔ THE FALSE-BLOCK DIRECTION. A point whose CONTENT discusses retirement is a healthy read. The
# guard matches a LINE START of a notice block, never the substring anywhere in the document.
mode poison
call get pt_abc
[ "$RC" -eq 0 ] && pass "a point whose CONTENT mentions \"RETIRED TOOL:\" still READS (exit 0) — the guard is not a substring trap" \
  || fail "a healthy read was refused because the point's text mentions retirement (rc=$RC) — the guard is too broad"

echo "== get: the server's not-found convention is a FAILED read, not a green"
mode empty
call get pt_nope
[ "$RC" -eq 4 ] && pass "get '\{\}' → exit 4 (nothing matched is never OK)" \
  || fail "get on a nonexistent point exited $RC — a mistyped id reads as a landed write"
printf '%s' "$ERR" | grep -q 'GRAPH-EMPTY-RESULT' \
  && pass "…and says GRAPH-EMPTY-RESULT, not a silent success" \
  || fail "…without naming the empty result (stderr: $ERR)"
# …but a LIST verb may legally answer `[]`. The rule is scoped to the read-one-entity verb, so this
# arm exists to keep a later "reject empty" from becoming a false block on every list.
mode empty_list
call search 'nothing matches this'
[ "$RC" -eq 0 ] && pass "search '\[]' → exit 0 (an empty LIST is a legitimate answer, not an error)" \
  || fail "search exited $RC on a legitimate empty list — the empty-result rule leaked into a list verb"

echo "== health and stats call the ADVERTISED handlers"
mode ok
call health
name="$(last_call | cut -f1)"; args="$(last_call | cut -f2)"
[ "$RC" -eq 0 ] && [ "$name" = "tortoise_overview" ] && [ "$args" = '{"section": "health"}' ] \
  && pass "health calls tortoise_overview(section=\"health\") — tortoise_health is RETIRED (#3883)" \
  || fail "health called '$name' $args (rc=$RC) — tortoise_health is retired; the advertised handler is tortoise_overview"
mode ok
call stats
name="$(last_call | cut -f1)"; args="$(last_call | cut -f2)"
[ "$RC" -eq 0 ] && [ "$name" = "tortoise_overview" ] && [ "$args" = '{"section": "pointkinds"}' ] \
  && pass "stats calls tortoise_overview(section=\"pointkinds\") — tortoise_list_pointkinds is RETIRED" \
  || fail "stats called '$name' $args (rc=$RC) — tortoise_list_pointkinds is retired"

echo "== R5 as data: no verb calls a tool the surface does not advertise"
mode ok
for verb in "health" "stats" "search attestation" "get pt_abc"; do
  # shellcheck disable=SC2086
  call $verb
done
bad="$(python3 - "$TMP/calls.jsonl" <<'PY'
import json, sys
ADVERTISED = {"tortoise_get_entity", "tortoise_overview", "tortoise_search", "tortoise_create_point"}
bad = []
for line in open(sys.argv[1]):
    b = json.loads(line)
    if b.get("method") == "tools/call":
        n = (b.get("params") or {}).get("name", "-")
        if n not in ADVERTISED:
            bad.append(n)
print(",".join(sorted(set(bad))))
PY
)"
[ -z "$bad" ] && pass "every recorded tools/call is an ADVERTISED handler" \
  || fail "the client calls UNadvertised handler(s): $bad — the surface will append a retirement notice to each answer and the JSON contract breaks"

echo
if [ "$failures" -eq 0 ]; then
  echo "OK: the fallback client calls the SERVED surface, prints parseable JSON, and never reads nothing as a result."
else
  echo "FAILURES=$failures of $checks"
fi
[ "$failures" -eq 0 ]
