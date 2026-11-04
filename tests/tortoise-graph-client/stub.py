#!/usr/bin/env python3
"""Stub MCP server for tests/tortoise-graph-client/run.sh — no network, no key, no real graph.

Serves `tools/call` with the SHAPES the hosted Tortoise surface actually returns, and records every
call so the suite can assert WHAT was called, not merely that something was:

  - `retired`  the real #3883 shape: the answer arrives as TWO text blocks, the second being a
               `RETIRED TOOL: …` notice. Folding both is what made `get`/`health`/`stats` print
               their JSON *plus* a paragraph while every exit code stayed 0.
  - `empty`    the server's not-found convention: `{}` with `isError: false`.
  - `poison`   a healthy result whose CONTENT mentions "RETIRED TOOL:" mid-line — the false-block
               direction: a read of such a point must still succeed.

usage: stub.py <control-dir> <port>
  reads   <control-dir>/mode   before each reply
  appends <control-dir>/calls.jsonl  (one JSON body per line)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CTL, PORT = sys.argv[1], int(sys.argv[2])

# The ADVERTISED tool list, as `tools/list` reports it (measured 2026-11-04: 69 tools). The suite
# asserts every call the client makes is a member — that is R5, stated as data instead of prose.
ADVERTISED = {
    "tortoise_get_entity",
    "tortoise_overview",
    "tortoise_search",
    "tortoise_create_point",
}

OK_POINT = '{"id":"pt_abc","content":"a point","pointKind":"statement"}'


def reply_for(body):
    mode = open(os.path.join(CTL, "mode")).read().strip()
    method, rid = body.get("method"), body.get("id")
    if method == "tools/list":
        result = {"tools": [{"name": n} for n in sorted(ADVERTISED)]}
    elif mode == "retired":
        result = {"content": [
            {"type": "text", "text": OK_POINT},
            {"type": "text", "text": "RETIRED TOOL: `tortoise_get_point` has been retired from the "
                                     "Tortoise MCP surface. It still answers, but it is no longer "
                                     "advertised. Call `tortoise_get_entity(id, type=\"point\")` "
                                     "instead (#3883)."},
        ], "isError": False}
    elif mode == "empty":
        result = {"content": [{"type": "text", "text": "{}"}], "isError": False}
    elif mode == "empty_list":
        result = {"content": [{"type": "text", "text": "[]"}], "isError": False}
    elif mode == "poison":
        result = {"content": [{"type": "text", "text":
                               '{"id":"pt_abc","content":"a point about RETIRED TOOL: handling"}'}],
                  "isError": False}
    elif mode == "budget":
        result = {"content": [{"type": "text",
                               "text": "The server's wait budget for this request was exceeded"}],
                  "isError": True}
    else:                                                    # "ok"
        result = {"content": [{"type": "text", "text": OK_POINT}], "isError": False}
    return {"jsonrpc": "2.0", "id": rid, "result": result}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):                               # silence the access log
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        with open(os.path.join(CTL, "calls.jsonl"), "a") as fh:
            fh.write(json.dumps(body) + "\n")
        payload = json.dumps(reply_for(body)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
