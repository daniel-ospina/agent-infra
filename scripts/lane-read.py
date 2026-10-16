#!/usr/bin/env python3
"""lane-read.py — the last N assistant messages of a lane, by PANE.

AGENTS.md: resolve a lane's session from the pane, never a pinned id, because pins
die on respawn. Reading the lane's own last messages is required before dispatching
to it — "idle" usually means mid-task, and a lane sitting on a question looks
identical to a wedged one from a status field.
"""
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
SD = f"{HOME}/.pi/agent/sessions"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
WS = sys.argv[1]


def sid_for(ws):
    out = subprocess.run(["cmux", "surface", "resume", "show", "--workspace", ws],
                         capture_output=True, text=True,
                         env={**os.environ, "CMUX_QUIET": "1"}).stdout
    for tok in out.replace("'", " ").split():
        if len(tok) == 36 and tok.count("-") == 4:
            return tok
    return None


def files_for(sid):
    import glob
    return sorted(glob.glob(f"{SD}/*/*{sid}*.jsonl"), key=os.path.getmtime)


sid = sid_for(WS)
print(f"workspace : {WS}\nsession   : {sid}")
fs = files_for(sid) if sid else []
if not fs:
    print("NO SESSION FILE — the pane has no session")
    sys.exit(0)
f = fs[-1]
print(f"file      : {os.path.basename(f)}")
print(f"size      : {os.path.getsize(f)}  mtime age: "
      f"{int(os.times()[4] and (__import__('time').time() - os.path.getmtime(f)))}s")

msgs = []
with open(f, errors="ignore") as fh:
    for line in fh:
        try:
            r = json.loads(line)
        except Exception:
            continue
        role = r.get("role") or (r.get("message") or {}).get("role")
        if role not in ("user", "assistant"):
            continue
        c = r.get("content") or (r.get("message") or {}).get("content")
        if isinstance(c, list):
            txt = " ".join(p.get("text", "") for p in c
                           if isinstance(p, dict) and p.get("type") == "text")
        else:
            txt = c if isinstance(c, str) else ""
        txt = (txt or "").strip()
        if txt:
            msgs.append((role, txt))

print(f"\n--- last {N} messages ---")
for role, txt in msgs[-N:]:
    print(f"\n[{role}] {txt[:1400]}")
