#!/usr/bin/env python3
"""map-sessions.py — the recovery primitive.

Prints every pi session touched recently, identified by its FIRST USER MESSAGE (ground truth of
what the session started as), newest first. Use this to find a thread after a restart, or to find
which session is holding an issue:

    python3 ~/.pi/agent/state/map-sessions.py                 # all recent sessions
    python3 ~/.pi/agent/state/map-sessions.py 3447            # which sessions touched #3447?
    python3 ~/.pi/agent/state/map-sessions.py --hours 4       # only the last 4 hours

WHY THIS EXISTS: `cmux surface resume show` can return a session ID with NO FILE ON DISK — a
dangling resume record (observed on the "Tests bloat" workspace, 2026-09-13: it was actively
working, yet its recorded ID `01a09c8e-...` exists nowhere in ~/.pi/agent/sessions). Always verify
a session ID against the filesystem before relying on it to resume a thread.
"""
import json, glob, os, sys, time, datetime

SESS = os.path.expanduser("~/.pi/agent/sessions")

def first_user_msg(path):
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                try: o = json.loads(line)
                except Exception: continue
                m = o.get("message", o)
                if m.get("role") != "user": continue
                c = m.get("content")
                if isinstance(c, list):
                    c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
                if isinstance(c, str) and c.strip():
                    return c.strip().replace("\n", " ")[:100]
    except Exception:
        pass
    return "(no user message)"

def repo_of(dirname):
    # dirname looks like: --Users-danielospina-Documents-GitHub-tortoise--
    d = dirname.strip("-")
    if "GitHub-" in d:
        d = d.split("GitHub-", 1)[1]
    return d.replace("-", "/")[:22]

def main():
    args = [a for a in sys.argv[1:]]
    hours = 30.0
    if "--hours" in args:
        i = args.index("--hours"); hours = float(args[i+1]); del args[i:i+2]
    needle = args[0] if args else None

    rows = []
    for f in glob.glob(os.path.join(SESS, "--*", "[0-9]*.jsonl")):
        try: st = os.stat(f)
        except OSError: continue
        age = (time.time() - st.st_mtime) / 3600
        if age > hours: continue
        sid = os.path.basename(f)[:-6].split("_", 1)[-1]
        label = first_user_msg(f)
        if needle:
            try:
                with open(f, errors="ignore") as fh:
                    if str(needle) not in fh.read():
                        continue
            except Exception:
                continue
        rows.append((st.st_mtime, age, sid, repo_of(os.path.basename(os.path.dirname(f))),
                     st.st_size / 1048576, label))
    rows.sort(reverse=True)

    if not rows:
        print(f"  (no sessions matching {needle!r} in the last {hours}h)")
        return
    print(f"  {'when':>5} {'age':>6} {'size':>7}  {'session':36} {'repo':22} lane (first user message)")
    print("  " + "─" * 150)
    for m, age, sid, repo, mb, label in rows:
        print(f"  {datetime.datetime.fromtimestamp(m):%H:%M} {age:5.1f}h {mb:6.1f}M  {sid:36} {repo:22} {label}")
    print(f"\n  {len(rows)} session(s). Resume with:  pi --session <id>   (partial UUID is accepted)")

if __name__ == "__main__":
    main()
