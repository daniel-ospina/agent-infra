#!/usr/bin/env python3
"""lane-status — multi-signal lane health. No single signal is definitive.

Signals combined (owner, 2026-09-25):
  1. SESSION file  — mtime/size DELTA over a sample window. The only reliable
                     liveness signal: the spinner animates while wedged.
  2. TRANSCRIPT    — the last 1-3 messages: tells WIP from DONE, which a
                     spinner cannot.
  3. UI            — the 'Working' indicator from cmux.
  4. CHILD         — does the lane have a sub-agent in flight, and is THAT
                     child alive? A parent waiting on a child writes nothing
                     to its own session file, so raw mtime reads "wedged" on a
                     lane that is working correctly. This is the HANG case.

The child signal is read from the parent's OWN transcript, which is the only
place it exists: a `subagent`/`task` toolCall with no matching toolResult is a
pending child, and the result's leading text is its verdict
("Agent timeout:", "Agent aborted:", "Agent failed:") .

Usage:
  lane-status.py                 # human table
  lane-status.py --json          # machine
  lane-status.py --sample 20     # seconds of file sampling (default 18)
"""
import json, os, re, subprocess, sys, time, glob, argparse
from collections import Counter

CMUX = dict(os.environ, CMUX_QUIET="1")
SD = os.path.expanduser("~/.pi/agent/sessions")
TASK_SD = os.path.expanduser("~/.pi/agent/task-sessions")
REG = os.path.expanduser("~/.pi/agent/state/lane-registry.tsv")

WORKING, WAITING, WIP_IDLE, DONE_IDLE, WEDGED, EMPTY, UNKNOWN, UNBOUND = (
    "WORKING", "WAITING-CHILD", "WIP-IDLE", "DONE-IDLE", "WEDGED", "EMPTY",
    "UNKNOWN", "UNBOUND")
CHILD_STUCK = "CHILD-STUCK"        # a persisted child gone quiet
WAITING_OVERDUE = "CHILD-OVERDUE"  # pending child past the harness's own silence bound
WAITING_OVERDUE = "CHILD-OVERDUE"  # pending child past the harness's own silence bound

TOOL_NAMES = ("subagent", "task")
# verdict prefixes pi writes into the toolResult text
RESULT_VERDICTS = ("Agent timeout:", "Agent aborted:", "Agent failed:", "Agent cut:")
# A third "parent writes nothing" case, alongside WAITING-CHILD: a direct tool call
# that is legitimately long. Observed live — lane `1 Capture write doors` ran
# `admin-merge.sh <PR>` with an explicit `timeout 3000s` and sat byte-identical for
# 38 minutes. The poll is bounded by the timeout DECLARED in the call, so a long
# tool is not mistaken for a wedge.
LONG_TOOL = "LONG-TOOL"
# A dispatch with no result older than this is ABANDONED, not pending — otherwise a
# call from days ago (whose result was never recorded) makes a healthy lane read
# CHILD-STUCK forever. Real children that run this long have already timed out.
ABANDON_S = 30 * 60          # == the harness's own in-flight bound (OVERDUE_S),
                              # plus a small margin. A `task`/`subagent` child CANNOT
                              # outlive it, so past this the child is DEAD and its
                              # still-open call is a stale record, not a wait.
                              # MEASURED 2026-09-27: this was 6*3600, so a child the
                              # harness had killed ~5.5 hours earlier was still returned
                              # as a live pending child and reported as `WAITING-CHILD
                              # child_age=106m`, which then made `turn-classify` SKIP
                              # that lane forever (it refuses to message a lane waiting
                              # on a child). One wrong constant disabled auto-continue.
# The `task` tool's own in-flight silence bound is stream_stall_ms, default 20 min.
# A pending child past this is either (a) legitimately in a long QUIET tool the
# dispatcher raised the bound for, or (b) the watchdog failed to fire — the #5195
# class. Either way it is the single most important thing to see.
OVERDUE_S = 25 * 60

# Lazy {pid: cwd} for every live `pi` process. Built once per run by
# _pi_pid_cwds() and reused by every lane's child_process_alive() probe, so the
# /usr/bin/python3 pgrep+lsof walk is paid once instead of once per lane.
_PI_MAP = None
_PI_PROCS = None
# NOTE: a child's own transcript is NOT inspectable. `task` children run `pi -p`
# and do not persist a session file anywhere under ~/.pi/agent/sessions, so the
# parent is blind to the child between dispatch and result. Only elapsed time and
# the child's on-disk effects are observable.


def sh(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, env=CMUX).stdout
    except Exception:
        return ""


def lane_child_prefixes():
    """Registry column 4 (optional): prefix of the lane's detached-child pid files.

    A lane may launch children OUTSIDE its own root. Every signal in this file
    looks inside the root, so such a lane reads DONE-IDLE while it is working --
    and DONE-IDLE's instruction is "dispatch it", which duplicates live work.
    """
    out = {}
    try:
        lines = open(REG, errors="ignore").read().splitlines()
    except OSError:
        return out
    for line in lines:
        if not line or line.startswith("#") or "\t" not in line:
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) > 3 and parts[3]:
            out[parts[0]] = parts[3]
    return out


def declared_children(label):
    """Live detached children the lane declared via /tmp/<prefix>-*.pid.

    A pid file OUTLIVES its process, so liveness is checked against the process
    and its command -- a stale file would otherwise invent a child that is gone.
    """
    prefix = lane_child_prefixes().get(label)
    if not prefix:
        return []
    found = []
    for path in sorted(glob.glob("/tmp/" + prefix + "-*.pid")):
        pid = sh(["cat", path]).strip()
        if not pid.isdigit():
            continue
        if sh(["ps", "-o", "comm=", "-p", pid]).strip() != "pi":
            continue
        cwd = None
        for ln in sh(["lsof", "-a", "-d", "cwd", "-p", pid, "-Fn"]).splitlines():
            if ln.startswith("n"):
                cwd = ln[1:]
                break
        found.append(dict(pid=int(pid), cwd=cwd, pidfile=os.path.basename(path)))
    return found


def registry():
    """`label<TAB>workspace<TAB>issue-label[<TAB>...]`

    The third column is the lane's GitHub issue label. It lives HERE, in the same
    row as the pane, because a lane's identity is its objective number and every
    consumer (the heartbeat, turn-end.py, a human) must read ONE mapping. A second
    copy of the lane->label map is exactly the two-names-for-one-lane defect the
    registry header describes. Trailing columns are ignored, and a missing third
    column yields "" rather than an error — a lane that owns no repo label
    (`HANG`, `A`) is a legitimate row.
    """
    rows = []
    for line in open(REG, errors="ignore"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or "\t" not in line:
            continue
        parts = [p.strip() for p in line.split("\t")]
        label, ws = parts[0], parts[1]
        issue_label = parts[2] if len(parts) > 2 else ""
        rows.append((label, ws, issue_label))
    # union with the LIVE fleet, so a workspace created after the roster was
    # written is still classified instead of silently sitting outside the monitor
    known = {ws.upper() for _, ws, _ in rows}
    for wsid, x in _live_workspaces():
        if wsid.upper() in known:
            continue
        known.add(wsid.upper())
        rows.append((_live_label(wsid, x), wsid, ""))
    return rows


# ── THE ROSTER IS NOT THE FLEET ────────────────────────────────────────────────
# registry() read lane-registry.tsv, a HAND-WRITTEN file. Measured 2026-09-28 23:05:
# 14 rows against 27 live cmux workspaces — 13 lanes the monitor could not see,
# including EVERY objective lane dispatched that evening (#4844, #2875, #3653, #6135)
# and both research streams. Because the heartbeat and turn-classify both iterate
# this list, an unlisted lane is never classified, never alerted and never nudged:
# it sits idle while the fleet reports itself healthy. The registry's own header
# says the authority is the PANE, so cmux is the source and the TSV only supplies
# the label<->issue-label mapping that cmux cannot know.
# FAILS OPEN: cmux unreachable -> the TSV rows alone, exactly as before.
# The orchestrator's own cmux workspace -- excluded from the lane registry; it is the
# reader, not a lane. ORCH_WS from the environment wins (the heartbeat exports it).
ORCH_WS = os.environ.get("ORCH_WS", "C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD")

_LIVE_CACHE = []


def _live_workspaces():
    if _LIVE_CACHE:
        return _LIVE_CACHE[0]
    rows = []
    try:
        out = subprocess.run(["cmux", "list-workspaces", "--json"],
                             capture_output=True, text=True, timeout=45).stdout
        data = json.loads(out)
        for x in (data if isinstance(data, list) else data.get("workspaces", [])):
            wsid = str(x.get("id") or "").strip()
            # ── THE ORCHESTRATOR IS NOT A LANE ────────────────────────────────
            # Its own workspace carries a lane-shaped title (measured 2026-09-29:
            # ORCH_WS was titled "Packs + Extractor"), so without this guard the
            # registry reports a phantom 28th lane, `turn-classify` will NUDGE THE
            # ORCHESTRATOR to go do lane work, and every content scan self-matches --
            # the orchestrator's transcript mentions every issue number it discusses,
            # which is exactly why a holder scan returned the orchestrator itself as
            # the top candidate for #6142. Excluded by id, never by title (titles are
            # user-facing and can be renamed at any time).
            if wsid.upper() == ORCH_WS.upper():
                continue
            if wsid:
                rows.append((wsid, x))
    except Exception:
        rows = []
    _LIVE_CACHE.append(rows)
    return rows


def _live_label(wsid, x):
    t = (x.get("custom_title") or "").strip()
    if t:
        return t
    cwd = (x.get("current_directory") or "").rstrip("/")
    base = os.path.basename(cwd) or "workspace"
    return f"{base} ({wsid[:8]})"


def _recorded_session(ws):
    """The lane->session mapping the recovery tooling writes (lane-sessions.json)."""
    try:
        p = os.path.join(os.path.dirname(REG), "lane-sessions.json")
        for L in json.load(open(p)):
            if L.get("uuid") == ws:
                return L.get("session")
    except Exception:
        pass
    return None


def resolve_session(ws):
    """Resolve from the PANE, never a pinned id — pins die on respawn.

    BUT (2026-09-27) the pane's cmux resume record is not authoritative after a
    MANUAL relaunch. Relaunching a lane by typing `pi --session <id>` into its
    pane (the documented recovery path — respawn-pane DELETES workspaces) leaves
    cmux with either NO record (read as UNBOUND) or the PRE-crash id. The stale
    id made a working lane read DONE-IDLE for hours: the file glob found the old
    session, saw no writes, and called the lane idle.

    So neither source is trusted blindly: both candidates are resolved to a real
    file and the one actually being WRITTEN wins. When only one resolves, it is
    used. This self-corrects in either direction and cannot pin a dead id while a
    live one exists.
    """
    out = sh(["cmux", "surface", "resume", "show", "--workspace", ws])
    m = re.search(r"--session' '([0-9a-f-]{36})", out) or \
        re.search(r"--session[= ]'?([0-9a-f-]{36})", out)
    pane = m.group(1) if m else None
    rec = _recorded_session(ws)

    if not pane:
        return rec
    if not rec or rec == pane:
        return pane
    pf, rf = session_file(pane), session_file(rec)
    if pf and rf:
        chosen = rec if os.path.getmtime(rf) > os.path.getmtime(pf) else pane
    elif rf and not pf:
        chosen = rec
    else:
        chosen = pane

    # LAST RESORT (2026-09-27, measured): everything above still assumes one of the
    # two ids is the LIVE one. After a manual relaunch a lane can be writing to a
    # THIRD session file that neither cmux nor lane-sessions.json knows, and then
    # every source is stale and a working lane reads DONE-IDLE. MEASURED at 04:15:
    # the classifier said active=0 while 12 of 14 lanes were writing. So when the
    # chosen file has gone quiet, look for a newer file in the same directory whose
    # FIRST USER MESSAGE names this lane — the fleet's own identity signal, and the
    # technique match-lanes.py uses to disambiguate a shared sessions directory.
    cf = session_file(chosen)
    if cf and (time.time() - os.path.getmtime(cf)) > 1800:
        label = next((l for l, w, _ in registry() if w == ws), "")
        alt = _content_session(label, cf)
        if alt:
            return os.path.basename(alt)[:-len(".jsonl")].split("_")[-1]
    return chosen


def _first_user_message(path):
    """The first user turn's text — how this fleet identifies a lane."""
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if not isinstance(o, dict):
                    continue
                if o.get("type") != "user" and o.get("role") != "user":
                    continue
                c = o.get("content")
                if c is None and isinstance(o.get("message"), dict):
                    c = o["message"].get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                if c:
                    return str(c)
    except Exception:
        pass
    return ""


def _content_session(label, stale_file):
    """Newest session file in the lane's dir whose first user message names the lane.

    Bounded to the last 6h of files and only consulted when the primary resolution
    is already known stale, so a quiet fleet costs nothing.
    """
    d = os.path.dirname(stale_file or "")
    if not (label and os.path.isdir(d)):
        return None
    stop = {"and", "the", "of", "for", "core", "keys", "lane"}
    toks = [t for t in re.split(r"[^a-z0-9]+", label.lower()) if len(t) > 2 and t not in stop]
    if not toks:
        return None
    need = max(1, (len(toks) + 1) // 2)
    try:
        base = os.path.getmtime(stale_file)
    except OSError:
        base = 0
    cutoff = time.time() - 6 * 3600
    best, bmt = None, 0
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        try:
            mt = os.path.getmtime(f)
        except OSError:
            continue
        if mt <= base or mt < cutoff:
            continue
        txt = _first_user_message(f).lower()
        if txt and sum(1 for t in toks if t in txt) >= need and mt > bmt:
            best, bmt = f, mt
    return best


def session_file(sid):
    if not sid:
        return None
    hits = glob.glob(f"{SD}/*/*{sid}*.jsonl")
    return max(hits, key=os.path.getmtime) if hits else None


def mangled(cwd):
    """cwd -> session directory name. `/a/b.c` -> `--a-b-c--`

    The wrapper supplies the two dashes and the ROOT slash is consumed by it, so
    the leading `/` must be stripped first — otherwise `/a` becomes `---a--` and
    every lookup misses.
    """
    return "--" + re.sub(r"[/.]", "-", cwd.strip("/")) + "--"


def records(path, limit=None):
    out = []
    try:
        with open(path, errors="ignore") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
                if limit and len(out) >= limit:
                    break
    except Exception:
        pass
    return out


def tail(path, want=8):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            back = min(size, 300_000)
            f.seek(size - back)
            chunk = f.read().decode("utf-8", "ignore")
        out = []
        for line in reversed([l for l in chunk.split("\n") if l.strip()]):
            try:
                out.append(json.loads(line))
            except Exception:
                continue
            if len(out) >= want:
                break
        return list(reversed(out))
    except Exception:
        return []


def describe(rec):
    m = rec.get("message") or {}
    role = m.get("role") or rec.get("type") or "?"
    content = m.get("content")
    if isinstance(content, str):
        return role, content[:200].replace("\n", " ")
    if isinstance(content, list):
        texts, tools = [], []
        for c in content:
            if not isinstance(c, dict):
                continue
            t = c.get("type")
            if t == "text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
            elif t in ("toolCall", "tool_use"):
                args = c.get("arguments") or c.get("input") or {}
                hint = args.get("task") or args.get("command") or args.get("file_path") or ""
                tools.append(f"{c.get('name','?')}({str(hint)[:40]})")
        if tools:
            return "tool", "tools: " + ",".join(tools[:4])
        if texts:
            return role, texts[0][:200].replace("\n", " ")
    return role, ""


def ts_epoch(ts):
    """ISO timestamp -> epoch seconds (UTC-aware)."""
    if not ts:
        return None
    try:
        import calendar
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None


def _pi_pid_cwds():
    """{pid: cwd} for every live `pi` process, built ONCE per run.

    NOTE 2026-09-27: this and child_process_alive() are DELIBERATELY UNUSED.
    The parentage technique below is correct and was measured working (HANG's
    child 64672 -> parent pi 33286; lane A's own session 1744 -> parent zsh
    1696), but a cwd/parentage rule CANNOT separate two sibling lanes that share
    one cwd: nine lanes rooted at the tortoise checkout each adopted pid 8167.
    Since the only available disambiguator is the lane's own issue list, which
    this function is not given, wiring it would trade a FALSE OVERDUE (a weak
    alarm, already documented) for a MISSED OVERDUE (a masked real stall) -- the
    worse error for a watchdog. Kept as the designed fix, not shipped.
    """
    global _PI_MAP
    if _PI_MAP is not None:
        return _PI_MAP
    m = {}
    try:
        pids = sh(["pgrep", "-x", "pi"]).split()
    except Exception:
        pids = []
    for p in pids:
        try:
            out = sh(["lsof", "-p", p, "-a", "-d", "cwd", "-Fn"])
        except Exception:
            continue
        for line in out.splitlines():
            if line.startswith("n"):
                m[p] = line[1:]
                break
    _PI_MAP = m
    return m


def child_process_alive(cwd):
    """UNUSED -- see _pi_pid_cwds() for why this was designed but not wired.

    The technique is sound and was measured (2026-09-27): a `task`/`subagent`
    child's parent IS a pi process (64672 -> 33286, at agent-infra), while a
    lane's OWN session was started from a shell (1744 -> 1696, zsh). The
    blocking defect is cwd-collision between sibling lanes, not the rule.

    What it would have fixed: HANG read `CHILD-OVERDUE child=344m` while pid
    64672 ran with CPU advancing 0:12.12 -> 0:14.62 over 45s, and ZERO session
    files existed under its worktree -- so every file-based probe in this file
    was blind to it by construction.

    To wire this safely it must be given the lane's issue numbers, so the
    child's cwd can be matched to THIS lane (e.g. `l59-3656` for c5-9) instead
    of to the shared repo root. That is a larger change than could be validated
    here.
    """
    root = os.path.abspath(cwd)
    for pid, pth in _pi_pid_cwds().items():
        try:
            p = os.path.abspath(pth)
        except Exception:
            continue
        if p.startswith(root + os.sep):
            return int(pid) if pid.isdigit() else True
    return None


def child_activity(cwd, minutes=20):
    """Newest write under the child's cwd in the last N minutes -> age in seconds.

    The only observable effect a `task` child has on the world, since its
    transcript is not persisted. Bounded depth and .git excluded for speed.
    """
    if not cwd or not os.path.isdir(cwd):
        return None
    newest = None
    now = time.time()
    try:
        for root, dirs, files in os.walk(cwd):
            if root.count(os.sep) - cwd.count(os.sep) > 3:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "node_modules", ".venv")]
            for fn in files:
                try:
                    mt = os.path.getmtime(os.path.join(root, fn))
                except Exception:
                    continue
                if mt > now - minutes * 60 and (newest is None or mt > newest):
                    newest = mt
            if newest and time.time() - newest < 60:
                break
    except Exception:
        return None
    return int(time.time() - newest) if newest else None


def last_tool_call(path):
    """(timestamp, declared_timeout_s, name) for the newest tool call, if it is the
    last thing and has no result yet — i.e. it is still in flight.
    """
    call = None
    result_ids = set()
    for r in records(path):
        m = r.get("message") or {}
        if m.get("role") == "assistant":
            for c in (m.get("content") or []):
                if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use"):
                    args = c.get("arguments") or c.get("input") or {}
                    call = (r.get("timestamp"), args, c.get("name"), c.get("id"))
        elif m.get("role") == "toolResult":
            result_ids.add(m.get("toolCallId"))
    if not call or call[3] in result_ids:
        return None
    ts, args, name, _ = call
    tmo = args.get("timeout") or args.get("timeout_seconds") or args.get("timeout_s")
    if tmo is None:
        cmd = str(args.get("command") or "")
        mt = re.search(r"timeout\s+(\d+)\s*s?\b", cmd)
        if mt:
            tmo = int(mt.group(1))
    try:
        tmo = int(float(tmo)) if tmo is not None else None
    except Exception:
        tmo = None
    return dict(ts=ts, name=name, timeout=tmo)


def parent_cwd(path):
    """The cwd a session was started in — first record carries it."""
    try:
        o = json.loads(open(path, errors="ignore").readline())
        return o.get("cwd")
    except Exception:
        return None


def pending_child(parent_file):
    """Newest unmatched child call, or None.

    Returns None for an ABANDONED call (older than ABANDON_S): a dispatch whose
    result was never recorded must not pin a lane as stuck forever.
    """
    calls = {}
    results = set()
    for r in records(parent_file):
        m = r.get("message") or {}
        if m.get("role") == "assistant":
            for c in (m.get("content") or []):
                if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use") \
                        and c.get("name") in TOOL_NAMES:
                    args = c.get("arguments") or c.get("input") or {}
                    calls[c.get("id")] = (r.get("timestamp"), args)
        elif m.get("role") == "toolResult" and m.get("toolName") in TOOL_NAMES:
            results.add(m.get("toolCallId"))
    open_calls = [(cid, v) for cid, v in calls.items() if cid not in results]
    if not open_calls:
        return None
    cid, (ts, args) = open_calls[-1]
    age = None
    if ts:
        e = ts_epoch(ts)
        if e:
            age = int(time.time() - e)
    if age is not None and age > ABANDON_S:
        return None
    # `subagent` passes `task`; the `task` tool passes `prompt`. Both carry `cwd`
    # only sometimes, so fall back to the parent's own cwd.
    hint = args.get("task") or args.get("prompt") or ""
    return dict(call_id=cid, ts=ts, age=age,
                cwd=args.get("cwd") or parent_cwd(parent_file),
                task=hint[:120],
                agent=args.get("agent") or "?")


def last_child_verdict(parent_file):
    """The verdict text of the most recent COMPLETED child, if it failed."""
    last = None
    for r in records(parent_file):
        m = r.get("message") or {}
        if m.get("role") == "toolResult" and m.get("toolName") in TOOL_NAMES:
            txt = " ".join(x.get("text", "") for x in (m.get("content") or [])
                           if isinstance(x, dict))
            for v in RESULT_VERDICTS:
                if txt.startswith(v):
                    last = (v, r.get("timestamp"))
    return last


def task_child_candidates(after_ts):
    """Child transcript dirs that could belong to a dispatch made at `after_ts`.

    Bounded by the dir's own mtime: a dispatch from 80 minutes ago cannot have
    produced a child dir last written before it. That prunes 14,900 dirs to a
    handful and keeps this cheap enough to run every tick.
    """
    out = []
    try:
        with os.scandir(TASK_SD) as it:
            for e in it:
                try:
                    if not e.is_dir(follow_symlinks=False):
                        continue
                    mt = e.stat(follow_symlinks=False).st_mtime
                except OSError:
                    continue
                if after_ts is not None and mt < after_ts - 120:
                    continue
                out.append((mt, e.path))
    except OSError:
        return []
    out.sort(reverse=True)
    return [p for _, p in out]


def _same_dir(a, b):
    """Compare two cwds, resolving symlinks.

    `/tmp/x` and `/private/tmp/x` are the SAME directory on macOS and both spellings
    occur (a brief says /tmp/…, the child records /private/tmp/…). Without realpath
    the match silently never fires -- the same class of always-None as the bug this
    function fixes.
    """
    if not a or not b:
        return False
    ra, rb = os.path.realpath(a), os.path.realpath(b)
    return ra == rb or ra.startswith(rb + os.sep) or rb.startswith(ra + os.sep)


def find_child_session(cwd, after_ts, exclude=None):
    """Locate a task child's transcript.

    ⛔ Two trees, and the child is only ever in the second one:
      · `SD`            -- parent sessions, keyed by mangled cwd (the OLD search)
      · `TASK_SD`       -- a `task` child's OWN transcript dir, keyed by child uuid

    Searching `SD` alone meant `child_file` was ALWAYS None, so `child_stale` and
    `child_grew` never carried a value: every lane blocked on a child read
    CHILD-OVERDUE with no evidence whether that child was parked or working.
    Measured 2026-09-25: 14,934 dirs in TASK_SD, 0 mentions of it in this file.

    TASK_SD is searched first (that is where children actually are); the parent
    tree is retained as a fallback for a child that genuinely shares its parent's
    cwd. Candidates must post-date the dispatch.
    """
    if not cwd:
        return None

    for d in task_child_candidates(after_ts):
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl")),
                        key=os.path.getmtime, reverse=True):
            try:
                if after_ts is not None and os.path.getmtime(f) < after_ts - 120:
                    continue
                o = json.loads(open(f, errors="ignore").readline())
            except Exception:
                continue
            if _same_dir(o.get("cwd"), cwd):
                return f

    d = os.path.join(SD, mangled(cwd))
    if not os.path.isdir(d):
        return None
    excl = os.path.abspath(exclude) if exclude else None
    best, fallback = None, None
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        if excl and os.path.abspath(f) == excl:
            continue
        mt = os.path.getmtime(f)
        if fallback is None or mt > os.path.getmtime(fallback):
            fallback = f
        if after_ts is not None and mt < after_ts - 120:
            continue
        if best is None or mt > os.path.getmtime(best):
            best = f
    best = best or (fallback if after_ts is None else None)
    if best is None:
        return None
    try:
        o = json.loads(open(best, errors="ignore").readline())
        if o.get("cwd") and os.path.abspath(o["cwd"]) != os.path.abspath(cwd):
            return None
    except Exception:
        pass
    return best


def read_screen(ws, lines=80):
    """The pane's text, in ONE cmux call -- shared by the spinner test and the
    child-line parse, so adding the child parse costs no extra round trip."""
    return sh(["cmux", "read-screen", "--workspace", ws, "--lines", str(lines)])


def ui_working(ws):
    return "Working" in read_screen(ws, 12)


# pi prints one of these per LIVE child: child id, transcript dir, parent session.
CHILD_LINE_RE = re.compile(r"\[task\]\s+child\s+session\s+(\S+?)\s*\u2192\s*(\S+)")


def parse_child_lines(screen):
    """Live `task` children read straight off the pane. Authoritative, and the
    only child source that sees children launched OUTSIDE the lane's own root --
    cwd matching structurally cannot, and that is what made a lane with two live
    children read DONE-IDLE (measured 2026-09-26, three lanes / five children).

    Freshness comes from the newest file INSIDE the child's transcript dir, never
    from the dir's own mtime: measured the same day, all five live children had a
    dir mtime of 11m (the dir is created once) while their transcripts were 0-11m.

    The pane scrolls, so absence means UNKNOWN -- never "no child".
    """
    kids = []
    for m in CHILD_LINE_RE.finditer(screen or ""):
        cid, path = m.group(1), m.group(2).rstrip("),")
        if not os.path.isdir(path):
            continue                      # the pane can outlive the child's dir
        try:
            newest = max(os.path.getmtime(os.path.join(path, x))
                         for x in os.listdir(path))
        except Exception:
            continue
        kids.append(dict(id=cid, path=path, age=int(time.time() - newest)))
    return kids


def classify(stale, grew, spinner, last_kind, child, child_stale, child_grew,
             child_activity_age, tool_inflight, last_stop=None):
    if last_kind is None:
        # No session binding (or no records) -- which is NOT the same as the
        # pane having no session. Reported as unattributable, not as absent.
        return UNBOUND
    if grew:
        return WORKING
    # ── a long DIRECT tool call is not a wedge ────────────────────────────
    if not child and tool_inflight and spinner:
        age = tool_inflight.get("age")
        tmo = tool_inflight.get("timeout")
        if age is not None and tmo and age < tmo:
            return LONG_TOOL          # inside its own declared budget
        if age is not None and age < 900:
            return LONG_TOOL          # no budget declared, but not yet a suspect
    # ── child awareness: the case raw mtime gets WRONG ────────────────────
    # ⛔ A CHILD-STUCK verdict is a claim about the CHILD, and a quiet child under
    # an INACTIVE parent is explained by the PARENT: the lane stopped. Measured
    # 2026-09-26: `2c Pack compile` read CHILD-STUCK on three consecutive ticks
    # (46m / 79m / 91m) while its pane carried NO spinner and its session had not
    # been written for 28 minutes — because the lane had deliberately stopped on
    # load and said so in the pane ("Why I stopped short of implementing Stage 2 —
    # not a gate, budget and load ... a claim ahead of its evidence"). A quiet
    # child under a stopped parent is not a wedge; it is a lane at rest.
    #
    # So when the parent shows no activity at all, SKIP the child inference and let
    # the parent-state logic below decide -- it already separates a completed turn
    # from a wedge, and it is the code path that has been tested. Evidence about
    # the parent outranks an inference about a child we cannot see.
    parent_stopped = bool(
        child and child_stale is not None and child_stale > 900
        and not spinner and stale is not None and stale > 600
    )
    if child and not parent_stopped:
        if child_grew:
            return WAITING                      # parent idle, child healthy — correct
        if child_stale is not None:
            # The child's OWN transcript answered the question. This is evidence,
            # and it outranks every proxy below it: a child that wrote 86s ago is
            # alive no matter how long ago it was dispatched. Before this branch
            # existed, a fresh child_stale matched nothing and fell through to
            # `age > OVERDUE_S`, so `5&9 MCP and SDK surface` read CHILD-OVERDUE
            # while its child was demonstrably writing.
            if child_stale > 900:
                # A quiet transcript is NOT evidence of a stall -- the heartbeat's
                # own WEDGED caveat says exactly this ("a long tool call writes
                # nothing until it returns"). Ask the child's on-disk effect
                # before asserting a diagnosis about it. Measured 2026-09-26: two
                # lanes read CHILD-STUCK (transcript quiet 101m / 125m) while
                # their children were writing a 112 KB test file and rotating
                # bash pids the entire time.
                if child_activity_age is not None and child_activity_age < 900:
                    return WAITING              # quiet transcript, but progress on disk
                return CHILD_STUCK              # persisted child, quiet AND idle on disk
            return WAITING                      # measured fresh — alive
        # No transcript to read: judge by the child's on-disk effect, then by
        # elapsed time against the harness's own 20-min in-flight bound. This is
        # the UNVERIFIABLE path -- the verdict is a guess about a child we cannot
        # see, so it must not be reported as a fact about the child.
        if child_activity_age is not None and child_activity_age < 900:
            return WAITING                      # the child is demonstrably still writing
        if child["age"] is not None and child["age"] > OVERDUE_S:
            return WAITING_OVERDUE              # past the watchdog's own bound
        return WAITING
    if spinner and stale is not None and stale < 90:
        return WORKING
    if stale is not None and stale > 600:
        # ── a COMPLETED turn is IDLE, never a wedge ──────────────────────────
        # The pane retains its last frame, spinner glyph included, so a static
        # glyph beside a quiet session is EXACTLY what a finished lane looks
        # like -- yet it produced WEDGED, whose meaning is "check the process".
        # `stopReason` is the discriminator the glyph cannot supply: "stop" is
        # the model ending its turn deliberately, "toolUse" is a call still
        # owed a result. Measured 2026-09-26: `2c Pack compile` and `5&9 MCP
        # and SDK surface` both read WEDGED off completed reports (4h37m and
        # 1h24m quiet) that read "Blocked on the owner" and "Lane report:" --
        # two lanes flagged for attention every tick of a shift for being done.
        if last_kind == "assistant" and last_stop == "stop":
            return WIP_IDLE if spinner else DONE_IDLE
        return WEDGED if spinner else DONE_IDLE
    if last_kind == "user":
        return WIP_IDLE
    if last_kind == "tool":
        return WORKING
    if last_kind == "assistant":
        return WIP_IDLE if spinner else DONE_IDLE
    return UNKNOWN


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--sample", type=float, default=18.0)
    a = ap.parse_args()

    rows = registry()
    snap = {}
    for label, ws, _il in rows:
        sid = resolve_session(ws)
        f = session_file(sid)
        child = pending_child(f) if f else None
        cf = find_child_session(child["cwd"], ts_epoch(child["ts"]), exclude=f) \
            if (child and child.get("cwd")) else None
        snap[label] = dict(ws=ws, sid=sid, file=f,
                           size=os.path.getsize(f) if f else None,
                           child=child, child_file=cf,
                           child_size=os.path.getsize(cf) if cf else None)
    time.sleep(a.sample)

    out = []
    for label, ws, ilabel in rows:
        s = snap[label]
        f = s["file"]
        grew, stale = False, None
        if f:
            try:
                grew = s["size"] is not None and os.path.getsize(f) > s["size"]
                stale = int(time.time() - os.path.getmtime(f))
            except Exception:
                pass
        # one screen read, used twice: the spinner and the child lines.
        # The spinner is judged on the BOTTOM 12 lines only -- reading the full
        # 80-line window for the child parse would match a stale "Working" left
        # higher in the scrollback and turn a DONE-IDLE lane into a WEDGED one.
        screen = read_screen(ws) if s["sid"] else ""
        spinner = "Working" in "\n".join((screen or "").splitlines()[-12:])
        # NOTE the 3600s bound. The pane line's PRESENCE is the liveness signal --
        # pi prints it while the child runs and redraws the screen as the spinner
        # animates. Filtering it on a 900s transcript age was wrong: a child inside
        # a long tool call writes nothing, so it was discarded exactly when we
        # needed it (measured 2026-09-26, `7 Instrumentation` read CHILD-STUCK off
        # a 28m-quiet pending child while its pane showed a live child and an
        # animating spinner). The bound is kept only to expire a genuinely stale
        # frame, which is why it is generous rather than tight.
        pane_kids = ([k for k in parse_child_lines(screen) if k["age"] < 3600]
                     if s["sid"] else [])
        recs = tail(f, 8) if f else []
        descs = [(k, t) for k, t in (describe(r) for r in recs) if k != "other"]
        last_kind, _ = descs[-1] if descs else (None, "")
        # The stop reason of the LAST record, and only when that record is the
        # assistant's own. A trailing toolResult must not inherit the stop
        # reason of the message that requested the call, so this is guarded on
        # the role rather than read from the last record unconditionally.
        last_stop = None
        if recs:
            _last_msg = recs[-1].get("message") or {}
            if _last_msg.get("role") == "assistant":
                last_stop = _last_msg.get("stopReason")

        # ── child: did it move during the SAME sample window as its parent? ──
        child = s["child"]
        child_file = s["child_file"]
        child_stale = child_grew = child_act = None
        if child_file:
            try:
                csz = os.path.getsize(child_file)
                child_stale = int(time.time() - os.path.getmtime(child_file))
                child_grew = csz > (s["child_size"] or 0)
            except Exception:
                child_file = None
        # On-disk effect is the only signal that survives a long tool call: a
        # child inside one writes nothing to its transcript until the call
        # returns, so transcript quiet alone cannot justify CHILD-STUCK. Computed
        # only where it can change the verdict (no transcript, or a quiet one),
        # because this walk is the most expensive thing in this file.
        if child and (not child_file or (child_stale is not None and child_stale > 900)):
            child_act = child_activity(child["cwd"])

        # a direct tool still in flight, with its own declared budget
        ti = None
        if f and not child:
            tc = last_tool_call(f)
            if tc:
                e = ts_epoch(tc["ts"])
                ti = dict(name=tc["name"], timeout=tc["timeout"],
                          age=int(time.time() - e) if e else None)

        verdict = classify(stale, grew, spinner, last_kind, child, child_stale,
                           child_grew, child_act, ti, last_stop=last_stop)
        # ── children the lane launched OUTSIDE its own root ──────────────────
        # Nothing inside the root moves while they work, so the lane reads
        # DONE_IDLE -- and DONE-IDLE tells the reader to dispatch it, which
        # duplicates live work. Measured 2026-09-25: `3 Onboarding` read
        # DONE-IDLE with three live declared `pi` children and two open PRs.
        declared = declared_children(label)
        # A lane with a LIVE child is waiting on it -- never idle, never wedged, and
        # never "stuck". The pane is authoritative and covers OUT-OF-ROOT children,
        # which is the case the cwd-based `pending_child` cannot see. CHILD_STUCK is
        # in this list deliberately: measured 2026-09-26, `5&9` read CHILD-STUCK off
        # a 27m-old pending child while its pane showed TWO live children (451s,
        # 554s) -- the lane was demonstrably waiting on live work, and the stale
        # pending entry was a different, older child.
        if (declared or pane_kids) and verdict in (
                DONE_IDLE, WIP_IDLE, WEDGED, CHILD_STUCK, WAITING_OVERDUE):
            verdict = WAITING
        # `size` is the session file's CURRENT byte length, and it is the
        # fingerprint turn-end.py keys on: a lane that has taken a turn has a
        # bigger file; one that is sitting still has the same number. That is
        # how "nudge once per idle episode" is enforced with no database — the
        # file size IS the memory (same trick as the label on the question gate).
        cur_size = None
        if f:
            try:
                cur_size = os.path.getsize(f)
            except Exception:
                cur_size = s["size"]
        out.append(dict(lane=label, verdict=verdict, stale_s=stale, grew=grew,
                       declared=declared, pane_children=pane_kids,
                        spinner=spinner, sid=s["sid"], ws=s["ws"], size=cur_size,
                        issue_label=ilabel,
                        last=(last_kind or "-"),
                        recent=[f"{k}:{t[:66]}" for k, t in descs[-3:]],
                        child=child, child_file=os.path.basename(child_file) if child_file else None,
                        child_stale=child_stale, child_grew=child_grew,
                        child_activity=child_act, tool=ti))

    if a.json:
        print(json.dumps(out, indent=2, default=str))
        return

    order = {CHILD_STUCK: 0, WAITING_OVERDUE: 1, WEDGED: 2, EMPTY: 3, UNBOUND: 3,
             WIP_IDLE: 4,
             LONG_TOOL: 5, WAITING: 6, DONE_IDLE: 7, WORKING: 8, UNKNOWN: 9}
    out.sort(key=lambda r: order.get(r["verdict"], 9))
    print(f"{'LANE':<26} {'VERDICT':<14} {'SELF':>7} {'UI':<8} CHILD / LAST")
    print("-" * 106)
    for r in out:
        st = "-" if r["stale_s"] is None else (
            f"{r['stale_s']//3600}h{(r['stale_s']%3600)//60:02d}m" if r["stale_s"] >= 3600
            else f"{r['stale_s']//60}m{r['stale_s']%60:02d}s" if r["stale_s"] >= 60
            else f"{r['stale_s']}s")
        ui = "Working" if r["spinner"] else "-"
        extra = r["last"]
        if r.get("tool") and not r["child"]:
            t = r["tool"]
            a = (t.get("age") or 0) // 60
            extra = f"{t['name']} in flight {a}m"
            if t.get("timeout"):
                extra += f" (declared {t['timeout']}s)"
        elif r["child"]:
            c = r["child"]
            age = c["age"] or 0
            bits = f"child {age//60}m"
            if r.get("child_activity") is not None:
                bits += f" disk-write={r['child_activity']//60}m ago"
            elif r.get("child_stale") is not None:
                bits += f" last-write={r['child_stale']//60}m"
            if age > OVERDUE_S:
                bits += " ⚠️ past 20m harness bound"
            extra = f"{bits} :: {c['task'][:40]}" if c["task"] else bits
        print(f"{r['lane']:<26} {r['verdict']:<14} {st:>7} {ui:<8} {extra}")
        for line in r["recent"]:
            print(f"{'':<26} {'':<12} {'':>7} {'':<8}   · {line}")
    print()
    print("  " + " · ".join(f"{k}={v}" for k, v in sorted(Counter(
        r["verdict"] for r in out).items())))


if __name__ == "__main__":
    main()
