#!/usr/bin/env python3
"""Client half of tortoise-graph.sh — hosted Tortoise MCP over plain JSON-RPC.

Kept deliberately dumb: one POST per call, no state, no session reuse, no retries that could
turn a refusal into a wrong answer. Prints the tool result as JSON on stdout.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

EP = os.environ["TORTOISE_GRAPH_EP"]
KEY = os.environ["TORTOISE_GRAPH_KEY"]
HDRS = {
    "Authorization": "Bearer " + KEY,
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}

_id = 0

# The retirement notice a retired-but-still-answering tool appends to its payload (#3883).
# Matched at a LINE start (the notice arrives as its own text content block, joined by `\n`), never as
# a bare substring: a point whose CONTENT mentions retirement must not make a healthy read fail.
RETIRED = re.compile(r"(?m)^RETIRED TOOL:.*$")

# An SSE data line: `data:` at column 0, an optional single space, then the payload.
# RFC 9110 allows no space after the colon, so `startswith("data: ")` dropped legal frames.
SSE_DATA = re.compile(r"^data:[ \t]?")


def call(method, params, timeout=30):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode()
    req = urllib.request.Request(EP, data=body, headers=HDRS)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as f:
            raw = f.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        sys.stderr.write("GRAPH-UNREACHABLE(HTTP %s): %s\n" % (e.code, detail))
        sys.exit(3)
    except Exception as e:  # noqa: BLE001 - any transport failure is the same verdict
        sys.stderr.write("GRAPH-UNREACHABLE(%s): %s\n" % (type(e).__name__, str(e)[:300]))
        sys.exit(3)
    # streamable-http answers as SSE frames; take the frame for THIS call.
    # Detection is by LINE PREFIX, never by the substring `"data: "`: `"metadata: "`
    # contains it, so a substring test rejected valid JSON replies as unparseable.
    payload = raw
    sse_lines = [ln for ln in raw.splitlines() if SSE_DATA.match(ln)]
    if sse_lines:
        frames = []
        for ln in sse_lines:
            try:
                frames.append(json.loads(SSE_DATA.sub("", ln, count=1)))
            except Exception:  # noqa: BLE001 - a non-JSON frame cannot be the reply
                continue
        # The reply is the frame whose id matches the request; a notification
        # (progress/log) can arrive LAST and carries no result, so "the last
        # data: line" would silently answer this call with somebody else's frame.
        match = [f for f in frames if isinstance(f, dict) and f.get("id") == _id]
        if match:
            return match[-1]
        if not frames:
            sys.stderr.write("GRAPH-BAD-RESPONSE: %s\n" % raw[:400])
            sys.exit(4)
        payload = json.dumps(frames[-1])
    try:
        return json.loads(payload)
    except Exception:
        sys.stderr.write("GRAPH-BAD-RESPONSE: %s\n" % raw[:400])
        sys.exit(4)


def tool(name, args=None, allow_empty=True):
    r = call("tools/call", {"name": name, "arguments": args or {}})
    if "error" in r:
        sys.stderr.write("GRAPH-TOOL-ERROR(%s): %s\n" % (name, json.dumps(r["error"])[:400]))
        sys.exit(4)
    # ⛔ A 2xx that carries no `result` is NOT a success. "An empty answer read as a
    # fine graph" is the exact failure this primitive exists to prevent: a write that
    # never landed and a read of nothing both look identical to exit 0.
    if not isinstance(r.get("result"), dict):
        sys.stderr.write("GRAPH-EMPTY-RESULT(%s): HTTP 2xx with no result field: %s\n"
                         % (name, json.dumps(r)[:300]))
        sys.exit(4)
    res = r["result"]
    out = []
    for c in res.get("content", []) or []:
        if c.get("type") == "text":
            out.append(c.get("text", ""))
    text = "\n".join(out)
    if res.get("isError"):
        sys.stderr.write("GRAPH-TOOL-ERROR(%s): %s\n" % (name, text[:400]))
        sys.exit(4)
    if not text.strip():
        sys.stderr.write("GRAPH-EMPTY-RESULT(%s): the tool returned no text — never read as OK\n" % name)
        sys.exit(4)
    # ⛔ A RETIRED TOOL IS NOT A RESULT. The server keeps answering a retired tool AND appends a
    # `RETIRED TOOL: …` notice as a SECOND text content block, which the join above folds into the
    # payload — so `get`/`health`/`stats` printed their JSON *plus* a paragraph, and the documented
    # contract ("prints the tool result as JSON on stdout") silently stopped holding while every exit
    # code stayed 0 (#3883 retired `tortoise_get_point`, `tortoise_health` and
    # `tortoise_list_pointkinds` after the verbs below were written). ⛔ AND #3883 KEPT GOING: it also
    # retired `tortoise_overview`, the handler those first three were pointed AT, so the replacement
    # can itself be retired out from under this file. `tortoise_graph_overview(section=…)` is the
    # currently advertised orientation handler; verify with `tools/list`, never with this comment.
    # Failing CLOSED here, rather than
    # stripping the notice, is deliberate: stripping would hide the NEXT retirement behind a clean
    # exit 0, which is the failure this whole file exists to prevent. The verbs below call the
    # ADVERTISED handlers; this arm is what makes a future retirement loud instead of corrupt.
    if RETIRED.search(text):
        sys.stderr.write(
            "GRAPH-RETIRED-TOOL(%s): the server reports this tool as RETIRED and mixes the notice into "
            "the payload, so its answer is not the tool's result. Call the advertised handler instead "
            "(`tortoise_graph_overview`, `tortoise_get_entity`, `tools/list`). Refusing to print it.\n" % name
        )
        sys.stderr.write("  server notice: %s\n" % RETIRED.search(text).group(0)[:300])
        sys.exit(4)
    # ⛔ AN EMPTY OBJECT IS NOT AN ANSWER EITHER. The server's not-found convention is `{}` with
    # `isError: false` (measured on `tortoise_get_point` and `tortoise_get_entity`), so a mistyped id
    # printed `{}` and exited 0 — a lane asking "did the point land?" got a green from a call that
    # found nothing. `allow_empty=False` is set by the read-one-entity verb; a LIST verb may legally
    # answer `[]`, so this cannot be a blanket rule.
    if not allow_empty:
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        if parsed in ({}, []):
            sys.stderr.write(
                "GRAPH-EMPTY-RESULT(%s): the tool answered %s — nothing matched. Never read as OK\n"
                % (name, text.strip()[:40])
            )
            sys.exit(4)
    return text


def main(argv):
    if not argv:
        sys.stderr.write(__doc__ or "usage: tortoise-graph.sh <verb> …\n")
        return 2
    verb, rest = argv[0], argv[1:]

    if verb == "health":
        # ⛔ `tortoise_health` is RETIRED (#3883): it still answers, but is no longer advertised and
        # appends a retirement notice to its payload. `tortoise_graph_overview(section="health")` is
        # the advertised handler and returns the SAME object (measured live at a 31248-point graph
        # size — `tools/list` advertises `tortoise_graph_overview` and NOT `tortoise_overview`, which
        # #3883 also retired; calling the retired name made this verb exit 4 on every box).
        print(tool("tortoise_graph_overview", {"section": "health"}))
        return 0

    if verb == "search":
        q = " ".join(rest)
        if not q:
            sys.stderr.write("usage: tortoise-graph.sh search <text>\n")
            return 2
        print(tool("tortoise_search", {"query": q}))
        return 0

    if verb == "get":
        if not rest:
            sys.stderr.write("usage: tortoise-graph.sh get <point-id>\n")
            return 2
        # ⛔ The ADVERTISED handler is `tortoise_get_entity(id, type)` — `tortoise_get_point` is
        # RETIRED (#3883) and mixes its retirement notice into the payload, so this verb printed a
        # point object followed by a paragraph. `id` is the parameter name on both; `point_id` is not
        # a parameter of any tool on the surface (it fails argument validation), which is why this
        # verb was dead before. A `{}` answer means NOT FOUND, not "here is your point".
        print(tool("tortoise_get_entity", {"id": rest[0], "type": "point"}, allow_empty=False))
        return 0

    if verb == "stats":
        # also retired (#3883); the `pointkinds` section is the advertised equivalent and returns the
        # identical `[{"kind": …, "count": …}, …]` payload.
        print(tool("tortoise_graph_overview", {"section": "pointkinds"}))
        return 0

    if verb in ("evidence", "decision"):
        if not rest:
            sys.stderr.write("usage: tortoise-graph.sh %s '<text>' [--to ID] [--pred P]\n" % verb)
            return 2
        text, to, pred = None, None, "supports"
        i = 0
        while i < len(rest):
            if rest[i] == "--to":
                # A flag with no value must never be folded into the point's CONTENT:
                # that writes a wrong artifact and reports exit 0. An EMPTY value is the
                # same defect from the other side: `--to "$POINT"` with POINT unset is
                # `--to ''`, and truthiness would then silently write NO edge at exit 0.
                if i + 1 >= len(rest):
                    sys.stderr.write("usage: --to needs a point id\n")
                    return 2
                to = rest[i + 1]
                if not to.strip() or to.startswith("--"):
                    sys.stderr.write("usage: --to needs a point id (got %r)\n" % to)
                    return 2
                i += 2
            elif rest[i] == "--pred":
                if i + 1 >= len(rest):
                    sys.stderr.write("usage: --pred needs a predicate\n")
                    return 2
                pred = rest[i + 1]
                if not pred.strip() or pred.startswith("--"):
                    sys.stderr.write("usage: --pred needs a predicate (got %r)\n" % pred)
                    return 2
                i += 2
            else:
                text = (text + " " + rest[i]) if text else rest[i]
                i += 1
        if not text:
            sys.stderr.write("usage: tortoise-graph.sh %s '<text>' [--to ID]\n" % verb)
            return 2
        # ⛔ A finding needs a NUMBER or a SOURCE. Refuse to write a bare opinion.
        if verb == "evidence" and not any(ch.isdigit() for ch in text):
            sys.stderr.write(
                "REFUSED(NO-NUMBER): a finding needs a NUMBER or a SOURCE "
                "('tests are slow' is not a finding). Add the measurement or use 'decision'.\n"
            )
            return 2
        kind = "evidence" if verb == "evidence" else "decision"
        created = tool("tortoise_create_point", {"kind": kind, "content": text})
        print(created)
        if to:
            src = _first_id(created)
            if not src:
                # The point landed but the edge did not: exit 0 here would report a
                # linked finding that is not linked.
                sys.stderr.write("GRAPH-NO-ID: the point was created but no id could be read "
                                 "from the reply, so no edge to %s was written\n" % to)
                sys.exit(4)
            print(tool("tortoise_create_operator", {
                "op_type": "IMPL", "source_id": src,
                # ⛔ `tortoise_create_operator` takes
                # (op_type, source_id, target_ids, direction, semantics) — there is NO `label`
                # parameter on the tool, so passing one drops the predicate (or is rejected AFTER
                # the point was already written, which reports a partial success). The predicate
                # goes in `semantics`, whose closed vocabulary is what also resolves direction.
                "target_ids": [to], "semantics": pred, "direction": "unidirectional",
            }))
        return 0

    sys.stderr.write("unknown verb: %s\n" % verb)
    return 2


def _first_id(created):
    """Best-effort id extraction from the tool's text reply; the caller prints the raw JSON too."""
    import re
    m = re.search(r'"id"\s*:\s*"([^"]+)"', created) or re.search(r"\b(1a[0-9a-f]{8,}-[0-9a-f]{8,})\b", created)
    return m.group(1) if m else ""


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
