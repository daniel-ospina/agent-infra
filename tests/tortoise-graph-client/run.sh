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
# ⛔ THE SERVED SURFACE IS READ FROM THE SERVER THAT SERVES IT, NEVER RESTATED HERE (#3374 review P2).
# The set used to exist THREE times — in the stub, in the R5 arm below, and in an `advertised()`
# helper that nothing ever called — so the arm compared the client against a hand-written list that
# agreed with another hand-written list, not against the surface. That is how `tortoise_create_operator`
# (which the client's write path calls) stayed MISSING from the "advertised" set while R5 stayed green.
# One full list, owned by the stub, fetched here over the same loopback `tools/list` a client would use.
#
# `WRITE_TOOLS` is NOT a second copy of that list: it is this suite's REQUIREMENT of the surface (the
# two handlers the write path must be able to call), declared once and passed to every arm that needs
# it — the surface probe below and the non-vacuity check in the R5 python.
WRITE_TOOLS="tortoise_create_point tortoise_create_operator"
served_list() {   # served_list — POST tools/list, write the names to $TMP/served.json, print them
  python3 - "$PORT" "$TMP/served.json" <<'PY'
import json, sys, urllib.request
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
req = urllib.request.Request("http://127.0.0.1:%s/" % sys.argv[1], data=body,
                             headers={"Content-Type": "application/json"})
tools = json.load(urllib.request.urlopen(req, timeout=5))["result"]["tools"]
names = sorted(t["name"] for t in tools if isinstance(t, dict) and t.get("name"))
json.dump(names, open(sys.argv[2], "w"))
print(",".join(names))
PY
}

# The surface is fetched ONCE, before any arm, and asserted NON-EMPTY: an empty set makes every
# membership test below pass vacuously.
echo "== the SERVED surface: read from the server's own tools/list, which is what R5 asserts against"
SERVED="$(served_list)"
SERVED_N="$(printf '%s\n' "$SERVED" | awk -F, '{print NF}')"
[ -n "$SERVED" ] && [ "$SERVED_N" -gt 0 ] \
  && pass "tools/list answers with a non-empty surface (${SERVED_N} tools) — R5 has something to compare against" \
  || fail "tools/list returned NOTHING — an EMPTY served set makes every membership test pass, so R5 would certify a client that calls anything"
# NON-VACUITY OF THE SURFACE ITSELF: the two handlers the WRITE path calls must be advertised by the
# server, or R5's "every call is advertised" is a comparison against a set that omits the very tools
# the defect lived on.
for NEED in $WRITE_TOOLS; do
  printf '%s\n' "$SERVED" | tr ',' '\n' | grep -qx "$NEED" \
    && pass "…and the served surface advertises $NEED (the write handler R5 must be able to check)" \
    || fail "tools/list does not advertise $NEED — the surface R5 compares against is missing a handler the client calls, so the write path cannot be covered"
done

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

echo "== a server-side tool ERROR is a REFUSAL, not a result"
# The stub's `budget` mode is the real shape of a server-side tool error (`isError: true` + a text
# block). Before this arm NOTHING set that mode, so the client's `isError` branch was never driven by
# the suite: a timed-out write that answered `isError` could print its error text on stdout at exit 0
# and every arm stayed green.
mode budget
call get pt_abc
[ "$RC" -eq 4 ] && pass "an isError answer (the server's wait-budget shape) exits 4 — an error is not a result" \
  || fail "an isError answer exited $RC (must be 4): the tool's error text is then read as an answer, and a lane reports a value the server refused to produce"
printf '%s' "$ERR" | grep -q 'GRAPH-TOOL-ERROR' \
  && pass "…and NAMES it: GRAPH-TOOL-ERROR on stderr" \
  || fail "…but never named the tool error (stderr: $ERR)"
[ -z "$OUT" ] && pass "…and prints NOTHING on stdout (no error text dressed as data)" \
  || fail "…but still printed a payload on stdout: $(printf '%s' "$OUT" | head -c 120)"

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
# ⛔ THE WRITE PATH IS DRIVEN TOO (#3374 review P2). It used to cover only health/stats/search/get,
# i.e. exactly the READS — while the defect this suite exists for (`label` vs `semantics` on
# `tortoise_create_operator`) lived on the write path and stayed uncovered. A toolkit that calls an
# unadvertised WRITE handler is the worse half of R5: the read fails loudly, the write can half-land.
for verb in "health" "stats" "search attestation" "get pt_abc" \
            "evidence measured-42-things" "decision DECIDED-measured-42-things"; do
  # shellcheck disable=SC2086
  call $verb
  [ "$RC" -le 4 ] || fail "verb '$verb' exited $RC — not a documented exit (0/2/4)"
done
# ⛔ NON-VACUITY ON THE LOG ITSELF (#3374 review P2). There was no `[ -s … ]` guard, so a loop that
# made ZERO calls stayed green: `call get` with no id is a USAGE error (exit 2, which the `-le 4`
# above accepts) and never reaches the server, so the membership arm below compared an EMPTY log
# against the surface and printed `✅ every recorded tools/call is an ADVERTISED handler` for a client
# that called nothing. An empty log and a perfect log must not be indistinguishable.
[ -s "$TMP/calls.jsonl" ] \
  && pass "the R5 loop really drove the client ($(grep -c '"tools/call"' "$TMP/calls.jsonl") tools/call record(s) in the log) — the membership arm below is not vacuous" \
  || fail "the R5 loop recorded NO tools/call at all — every verb stopped before the server (a usage error still exits 2), so the membership arm below would pass against an empty log"
call evidence 'measured 42 things' --to pt_target
[ "$RC" -eq 0 ] || fail "evidence --to exited $RC (the write+edge path)"
# ⛔ THE WRITE CALLS ARE PINNED BY THEIR ARGUMENTS, NOT BY THEIR NAMES (#3374 review P1). Asserting
# names + exit codes let the defect this suite EXISTS FOR ship green: re-`label` for `semantics` on
# `tortoise_create_operator` and every arm still passed — the point lands, the predicate is dropped
# or rejected AFTER the write, the verb exits 0, and a lane reports "the finding is linked with
# supports" when it is not. The stub ignores `arguments` by design (it dispatches on mode), so the
# record in calls.jsonl is the only evidence — which is why it is asserted HERE, exactly as the read
# verbs do at their own arms.
python3 - "$TMP/calls.jsonl" <<'PY' && pass "the WRITE calls carry the SERVED arguments (semantics, not label; op_type/ids as served)" \
  || fail "a write call's arguments are not the served signature — on tortoise_create_operator that means the predicate is dropped AFTER the point was written and the verb still exits 0"
import json, sys
seen = {}
for line in open(sys.argv[1]):
    b = json.loads(line)
    if b.get("method") == "tools/call":
        p = b.get("params") or {}
        seen[p.get("name", "-")] = p.get("arguments") or {}
op = seen.get("tortoise_create_operator") or {}
pt = seen.get("tortoise_create_point") or {}
ok_op = op == {
    "op_type": "IMPL",
    "source_id": "pt_abc",
    "target_ids": ["pt_target"],
    "direction": "unidirectional",
    "semantics": "supports",
}
ok_pt = pt.get("kind") == "evidence" and bool((pt.get("content") or "").strip())
sys.exit(0 if ok_op and ok_pt else 1)
PY
# ⛔ THE HERE-DOC LIVES IN A FUNCTION BODY, NEVER INSIDE THE `$( )` (#2248, #2930). bash 3.2's
# substitution scanner walks the body as if it were code, so a here-doc nested in a command
# substitution desynchronises the parse state for the REST OF THE FILE. Measured on the real
# 3.2.57 parser (`bash:3.2@sha256:b6252c62…`): this suite reported `line 298: syntax error:
# unexpected end of file` — the EOF, 30 lines below the defect — while parsing fine under bash 5.
# `/bin/bash` on macOS IS 3.2.57, so the suite was unrunnable on the harness's own platform.
_r5_bad() { python3 - "$TMP/calls.jsonl" "$TMP/served.json" "$WRITE_TOOLS" <<'PY'
import json, sys
ADVERTISED = set(json.load(open(sys.argv[2])))
seen, bad = set(), []
for line in open(sys.argv[1]):
    b = json.loads(line)
    if b.get("method") == "tools/call":
        n = (b.get("params") or {}).get("name", "-")
        seen.add(n)
        if n not in ADVERTISED:
            bad.append(n)
# NON-VACUITY: a set that never names the WRITE tools is the defect this arm was blind to. The names
# are THIS SUITE'S requirement (argv[3]), passed in rather than restated — the surface itself is
# argv[2], read from the server.
missing = sorted(set(sys.argv[3].split()) - seen)
if missing:
    bad.append("(NOT EXERCISED: %s)" % ",".join(missing))
print(",".join(sorted(set(bad))))
PY
}
bad="$(_r5_bad)"
if [ $? -ne 0 ]; then
  # ⛔ AN UNREADABLE SURFACE IS A RED, NOT AN EMPTY `bad` (#3374 review P2 class). Before this, a
  # failed python wrote nothing to stdout, `bad` came back EMPTY, and the arm below printed
  # `✅ every recorded tools/call is an ADVERTISED handler` — the same vacuity the `[ -s … ]` guard
  # closes for the log, one file over.
  fail "could not evaluate R5: $TMP/served.json or $TMP/calls.jsonl is unreadable, so 'every call is advertised' was never actually checked"
else
  [ -z "$bad" ] && pass "every recorded tools/call is an ADVERTISED handler — and both WRITE tools were exercised" \
    || fail "the client calls UNadvertised handler(s), or the write path was never driven: $bad — the surface will append a retirement notice to each answer and the JSON contract breaks"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "OK: the fallback client calls the SERVED surface, prints parseable JSON, and never reads nothing as a result."
else
  echo "FAILURES=$failures of $checks"
fi
[ "$failures" -eq 0 ]
