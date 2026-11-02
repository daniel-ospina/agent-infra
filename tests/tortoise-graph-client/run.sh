#!/bin/bash
# tests/tortoise-graph-client/run.sh — the graph client's reply-selection contract.
#
# WHY THIS SUITE EXISTS. `scripts/tortoise_graph_client.py` is the ONLY way a lane reads
# and writes the hosted Tortoise graph (owner mandate 2026-11-02, agent-infra#3253). Its
# fail-closed promise — "an empty answer is never read as OK" — was FALSE on the SSE path:
# `select_reply` matched the frame whose id equals the request and, when nothing matched,
# fell back to `frames[-1]`, i.e. the LAST `data:` frame REGARDLESS OF WHOSE IT WAS. A
# streamable-HTTP server that answers with another call's id (or whose reply is preceded by
# a foreign frame) made `tortoise-graph.sh health` PRINT THAT FRAME AND EXIT 0. Measured
# against the pre-fix client: `rc=0 out=WRONG FRAME`. This is a false PASS on the primitive
# the graph mandate's read/write path rests on, so it is pinned here rather than described.
#
# The arms below are the whole contract:
#   1 a frame carrying THIS call's id                      → that frame
#   2 a STRINGIFIED id (a server echoing "2" for 2)        → that frame (the one tolerance)
#   3 a notification that arrives LAST after the reply     → the REPLY, not the notification
#   4 a frame naming a DIFFERENT id, and nothing else      → exit 4, GRAPH-FRAME-MISMATCH
#   5 a foreign-id frame plus an id-less notification      → exit 4, GRAPH-FRAME-MISMATCH
#   6 an ALL-id-less stream (a bare JSON-RPC reply)        → tolerated, last such frame
#   7 no parsable frame at all                             → exit 4, GRAPH-BAD-RESPONSE
#   8 the wrapper with NEITHER key name set                → exit 3, GRAPH-UNREACHABLE(NO-KEY)
#
# Arm 8 is the other half of "never a silent skip": the client must refuse loudly rather
# than degrade to some other graph, and it must do so without a network call.
#
# ⛔ NO NETWORK, NO `gh`, NO KEY. Every arm above runs against synthetic frames handed
# straight to `select_reply`, so this suite stays inside the shard list's hermetic
# contract. Arms 4-7 are the regression; arm 6/2 are the tolerances that must NOT be
# lost while closing it (a fix that simply deleted the fallback would break real servers).
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
CLIENT="$ROOT/scripts/tortoise_graph_client.py"
WRAPPER="$ROOT/scripts/tortoise-graph.sh"

failures=0
pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

[ -f "$CLIENT" ] || { echo "❌ missing $CLIENT"; exit 1; }
[ -f "$WRAPPER" ] || { echo "❌ missing $WRAPPER"; exit 1; }

echo "== §1 select_reply — the frame that answers THIS call =="
# A tiny driver. It imports the client module (the two module-level env reads are
# satisfied with dummies that are never dialled) and calls `select_reply` directly.
driver() {  # <python-expression-returning-json>
  TORTOISE_GRAPH_EP="http://127.0.0.1:1/mcp/" TORTOISE_GRAPH_KEY="unused" \
    python3 - "$CLIENT" "$1" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("tgc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

try:
    got = m.select_reply(eval(sys.argv[2]), 2, "RAW-FIXTURE")
except SystemExit as e:
    print("EXIT\t%s" % e.code)
else:
    print("FRAME\t%s" % json.dumps(got, sort_keys=True))
PY
}

check() {  # <label> <expr> <expected-line>
  local label="$1" expr="$2" want="$3" got
  got="$(driver "$expr" | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$got" = "$want" ]; then pass "$label"
  else fail "$label — got [$got], want [$want]"; fi
}

REPLY='{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"REAL"}]}}'
FOREIGN='{"jsonrpc":"2.0","id":999,"result":{"content":[{"type":"text","text":"WRONG"}]}}'
NOTIF='{"jsonrpc":"2.0","method":"notifications/progress","params":{}}'

# 1 — the plain match.
check "1 a frame with THIS call's id is the reply" \
  "[$REPLY]" \
  "FRAME	$(printf '%s' "$REPLY" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')"

# 2 — the stringified-id tolerance must survive.
check "2 a stringified id is still matched (\"2\" for 2)" \
  "[{'jsonrpc':'2.0','id':'2','result':{'content':[{'type':'text','text':'REAL'}]}}]" \
  "FRAME	$(printf '%s' "$REPLY" | python3 -c 'import json,sys;d=json.load(sys.stdin);d["id"]="2";print(json.dumps(d,sort_keys=True))')"

# 3 — the notification arriving last must not be taken.
check "3 a notification arriving LAST does not win" \
  "[$REPLY,$NOTIF]" \
  "FRAME	$(printf '%s' "$REPLY" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')"

# 4 — THE REGRESSION. Pre-fix this returned the foreign frame at exit 0.
check "4 a frame naming a DIFFERENT id is refused, never taken" \
  "[$FOREIGN]" \
  "EXIT	4"

# 5 — a foreign id must not be laundered by a neighbouring notification.
check "5 a foreign-id frame + an id-less notification is refused" \
  "[$FOREIGN,$NOTIF]" \
  "EXIT	4"

# 6 — the all-id-less tolerance (a bare JSON-RPC reply that omits the id).
check "6 an all-id-less stream keeps its reply" \
  "[{'jsonrpc':'2.0','result':{'content':[{'type':'text','text':'X'}]}}]" \
  "FRAME	{\"jsonrpc\": \"2.0\", \"result\": {\"content\": [{\"text\": \"X\", \"type\": \"text\"}]}}"

# 7 — nothing parsable at all.
check "7 an unparsable/empty frame set is a bad response" \
  "[]" \
  "EXIT	4"

echo
echo "== §2 the wrapper — fail CLOSED on a missing key, with no network =="
OUT="$(env -u TORTOISE_MCP_API_KEY -u TORTOISE_API_KEY bash "$WRAPPER" health 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && grep -q 'GRAPH-UNREACHABLE(NO-KEY)' <<<"$OUT"; then
  pass "8 no key ⇒ exit 3 GRAPH-UNREACHABLE(NO-KEY) (never a silent skip)"
else
  fail "8 no key must exit 3 GRAPH-UNREACHABLE(NO-KEY); got rc=$RC [$OUT]"
fi
if grep -q 'Do NOT silently fall back to another graph' <<<"$OUT"; then
  pass "9 the refusal names the rule, so a lane cannot read it as 'no graph, carry on'"
else
  fail "9 the NO-KEY refusal must name the no-fallback rule; got [$OUT]"
fi

# 10 — a key that IS set must not be echoed back to the caller (the output is pasted into
# issues and postmortems; the fleet has already leaked one keys.env line, #2235).
OUT="$(TORTOISE_MCP_API_KEY='SECRET-SENTINEL-DO-NOT-PRINT' TORTOISE_API_URL='http://127.0.0.1:1' \
       bash "$WRAPPER" health 2>&1)"
if grep -q 'SECRET-SENTINEL-DO-NOT-PRINT' <<<"$OUT"; then
  fail "10 the key VALUE must never be printed; it appeared in the output"
else
  pass "10 the key value never reaches stdout/stderr, even on a transport failure"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "❌ tortoise-graph-client: $failures failure(s)"
  exit 1
fi
echo "✅ tortoise-graph-client: all arms pass"
