#!/usr/bin/env python3
"""scripts/lane-route.py — route every waiting lane to the remedy its situation earns (#4046).

The decision is `tools/fleet/triage.py`; the arms are `tools/fleet/triage_arms.py`. This file is the
ACQUISITION and the cmux/harness I/O, and nothing else — the same split the liveness surface uses
(`tools/fleet/liveness.py` decides, `lane_liveness.py` drives), for the same reason: a decision that
cannot be driven by a fixture cannot be tested, and a decision that cannot be tested gets reviewed
instead of pinned.

WHAT IT READS (one owner per field, never a second opinion)
    lane-status.py --json   the verdict (WEDGED / CHILD-STUCK / LONG-TOOL / WIP-IDLE / …), the
                            child record, the in-flight tool, the session id, the workspace id
    liveness.turn_from_jsonl the #1254 open-turn contract — the ONLY source of "positively open"
    the session tail's last assistant text   what the lane last SAID (question detection reads this)
    pid argv (print mode)   whether the incarnation can be steered AT ALL. A `pi -p` lane cannot:
                            one turn, no stdin, exits — so a "continue" typed at it is a no-op that
                            still writes a SENT marker and makes the lane read BUSY for an hour.
    cmux read-screen        the boot prompt, and the pane after a repair (`--apply` only)

Usage:
    lane-route.py                    # route only: one line per lane + the beat clause
    lane-route.py --json             # the routes as JSON (fixtures, tests, other tools)
    lane-route.py --apply            # route AND execute each arm, recording the proof
    lane-status.py --json | lane-route.py --stdin -
    lane-route.py --apply --lane 'lane-7'    # one lane (operator debugging)

Exit: 0 always. A router that fails the pass on one unreadable lane would lose the whole fleet's
routing to a single blind read — the same reason `lane-actions.py` reports rather than raises. An
unreadable read routes to `refuse`/`inspect`, which is a ROUTE, not a crash.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".pi", "agent", "scripts")
STATE = os.path.join(HOME, ".pi", "agent", "state")
# ⛔ `lane-status.py` IS NOT FARMED, AND ITS ABSENCE FROM `$SCRIPTS` IS A RECORDED DECISION, NOT A BUG:
# `pi-bootstrap/setup.sh` deliberately withholds it (#1553 — farming the repo copy would overwrite the
# live classifier with an older one), so a reader that only looks in `$SCRIPTS` reads "no lane-status"
# on every box and routes NOTHING — a silent total no-op that looks like an idle fleet. MEASURED on
# this box: `$HOME/.pi/agent/scripts/lane-status.py` does not exist while the repo copy runs fine.
# So the candidates are ordered repo-first and the resolver reports WHICH one it used.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _resolve(name):
    """First existing candidate for a sibling tool, repo/`$AGENT_INFRA_PATH` before the farm."""
    for base in (os.environ.get("AGENT_INFRA_PATH", ""), _REPO, SCRIPTS):
        if not base:
            continue
        path = os.path.join(base, "scripts", name) if not base.endswith("scripts") else \
            os.path.join(base, name)
        if os.path.exists(path):
            return path
    return ""


FLEET = os.path.join(os.environ.get("AGENT_INFRA_PATH", ""), "tools", "fleet")
if not os.path.isdir(FLEET):
    # A lane runs from a checkout. Fall back to this file's own repo so a worktree run works too.
    FLEET = os.path.join(_REPO, "tools", "fleet")
if FLEET not in sys.path:
    sys.path.insert(0, FLEET)

import liveness       # noqa: E402
import triage         # noqa: E402
import triage_arms    # noqa: E402


# ── the real surface ───────────────────────────────────────────────────────────────────────────
def _cmux(argv, timeout=45):
    try:
        p = subprocess.run(["cmux"] + argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except (OSError, subprocess.SubprocessError):
        return 1, "", "cmux-unavailable"


class CmuxSurface(triage_arms.Surface):
    """The real surface. Every failure to answer is `None`/`False` — never a success-shaped default.

    `sessions` maps a workspace id to its transcript path. It is SUPPLIED by the caller from the
    `lane-status.py` rows (which already resolved `sid`/`cwd` per lane) rather than re-resolved
    here: a second resolution is a second answer to "whose transcript is this", and the fleet has
    already paid for two answers to that question disagreeing.
    """

    def __init__(self, sessions=None):
        self.sessions = dict(sessions or {})


    def list_workspaces(self):
        rc, out, _ = _cmux(["tree", "--json"])
        if rc != 0 or not out.strip():
            return None
        try:
            blob = json.loads(out)
        except ValueError:
            return None
        spaces = blob.get("workspaces")
        if not isinstance(spaces, list):
            return None
        return [{"id": s.get("id"), "name": s.get("name"), "index": s.get("index")}
                for s in spaces if isinstance(s, dict)]

    def new_workspace(self, name):
        rc, out, _ = _cmux(["workspace", "new", "--name", name, "--json"])
        if rc != 0:
            return None
        try:
            return (json.loads(out) or {}).get("id")
        except ValueError:
            return None

    def move_workspace(self, ws, index):
        rc, _, _ = _cmux(["workspace", "move", ws, "--index", str(index), "--json"])
        return rc == 0

    def send(self, ws, text):
        # ⛔ ONE LINE ONLY: a newline in the payload IS Enter, so a multi-line body arrives as
        # several separate turns (`cadence-nudge.sh` records the owner's "it's a mess" report).
        flat = " ".join((text or "").split())
        rc, _, _ = _cmux(["send", "--workspace", ws, flat + "\n"])
        return rc == 0

    def transcript_size(self, ws):
        path = self.sessions.get(ws)
        if not path:
            return None
        try:
            return os.path.getsize(path)
        except OSError:
            return None

    def screen_tail(self, ws, lines=40):
        rc, out, _ = _cmux(["read-screen", "--workspace", ws, "--lines", str(lines)])
        if rc != 0:
            return None
        return out


# ── acquisition ────────────────────────────────────────────────────────────────────────────────
# ⛔ NO TEXT EXTRACTOR AND NO STEERABILITY PROBE HERE. Both live in `tools/fleet/triage.py`
# (`last_text_from_jsonl`, `steerable`) because `scripts/turn-end.py` needs them too, and two readers
# of "what did this lane last say" would eventually disagree about a question mark — which is the
# one disagreement this whole change exists to prevent.


def _session_paths(rows):
    """ws -> transcript path, from the rows' own `sid`/`cwd` (one resolution, by the producer)."""
    out = {}
    for row in rows:
        sid, cwd, ws = row.get("sid"), row.get("cwd") or "", row.get("ws")
        if sid and ws:
            path = liveness.session_file_for(sid, cwd)
            if path:
                out[ws] = path
    return out


def evidence_for(row, read_text=True, read_screen=False, surface=None):
    """Build one `triage.Evidence` from a `lane-status.py --json` row.

    Every field comes from an owner named in the module docstring. The two lookups that can be slow
    (`turn`, `last_text`) are ONE tail read; the two that need cmux (`boot_prompt`) happen only when
    `read_screen` — a routing-only pass must not pay for a pane read per lane.
    """
    sid = row.get("sid")
    cwd = row.get("cwd") or ""
    path = liveness.session_file_for(sid, cwd) if sid else None
    turn = liveness.turn_from_jsonl(path) if path else None
    tool = row.get("tool")
    tool_in_flight = bool(tool and getattr(tool, "tools_in_flight", 0))
    age = getattr(tool, "tool_age_ms", None) if tool else None
    cap = getattr(tool, "hard_cap_ms", None) if tool else None
    budget_open = bool(tool_in_flight and isinstance(age, int) and isinstance(cap, int) and age < cap)
    child = row.get("child") or {}
    child_state = ""
    if row.get("verdict") == "CHILD-STUCK":
        child_state = "stuck"
    elif row.get("verdict") == "CHILD-OVERDUE":
        child_state = "overdue"
    boot = None
    if read_screen and surface is not None and row.get("ws"):
        screen = surface.screen_tail(row["ws"], 40)
        if screen is not None:
            low = screen.lower()
            boot = ("press any key" in low) or ("boot-block" in low)
    return triage.Evidence(
        lane=row.get("lane") or "",
        turn=turn,
        last_text=triage.last_text_from_jsonl(path) if read_text else "",
        lane_verdict=row.get("verdict") or "",
        child_state=child_state,
        steerable=triage.steerable(sid),
        boot_prompt=boot,
        tool_in_flight=tool_in_flight,
        tool_budget_open=budget_open,
    ), {"ws": row.get("ws") or "", "child": child, "sid": sid}


# ── arms' injected helpers ────────────────────────────────────────────────────────────────────
def _dispatch_path():
    """`cmux_dispatch.py`'s location, resolved by the fleet's own resolver — never a literal (#1957)."""
    lib = os.path.join(SCRIPTS, "lib", "cmux-dispatch-path.sh")
    if not os.path.exists(lib):
        return None
    try:
        p = subprocess.run(["bash", "-c", '. "$1"; cmux_dispatch_resolve', "_", lib],
                           capture_output=True, text=True, timeout=30)
        out = (p.stdout or "").strip()
        return out if p.returncode == 0 and out else None
    except (OSError, subprocess.SubprocessError):
        return None


def _make_dispatch(brief):
    """Repair a boot-blocked pane by REUSING the dispatcher's own dismiss-and-resend (#4046)."""
    path = _dispatch_path()
    if not path:
        return lambda ws, lane: 3            # 3 = refused, nothing sent — the safe answer
    py = sys.executable or "python3"

    def _run(ws, lane):
        try:
            p = subprocess.run([py, path, "send", "--workspace", ws, "--label", lane or "",
                                "--file", brief, "--json"],
                               capture_output=True, text=True, timeout=420)
            return p.returncode
        except (OSError, subprocess.SubprocessError):
            return 1
    return _run


def _make_relaunch():
    tool = os.path.join(os.environ.get("AGENT_INFRA_PATH", ""), "scripts", "lane-relaunch.py")
    if not os.path.exists(tool):
        tool = os.path.join(SCRIPTS, "lane-relaunch.py")

    def _run(ws):
        if not os.path.exists(tool):
            return 3                        # refused: no relaunch tool on this box
        try:
            p = subprocess.run([sys.executable or "python3", tool, "--ws", ws],
                               capture_output=True, text=True, timeout=600)
            return p.returncode
        except (OSError, subprocess.SubprocessError):
            return 1
    return _run


def _make_poll(surface, interval=3.0):
    """Poll the lane's transcript for growth inside the arm's bound — the resumption proof."""
    def _poll(ws, before, bound_s):
        end = time.time() + bound_s
        while time.time() < end:
            time.sleep(interval)
            now = surface.transcript_size(ws)
            if now is not None and now > before:
                return now
        return surface.transcript_size(ws)
    return _poll


# ── main ──────────────────────────────────────────────────────────────────────────────────────
def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdin", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--lane", default="")
    ap.add_argument("--state", default=STATE)
    a = ap.parse_args(argv)

    if a.stdin == "-":
        raw = sys.stdin.read()
    elif a.stdin:
        with open(a.stdin) as fh:
            raw = fh.read()
    else:
        ls = _resolve("lane-status.py")
        if not ls:
            print("lane-route: lane-status.py not found (looked in $AGENT_INFRA_PATH, this checkout, "
                  "and $SCRIPTS) — NOTHING IS ROUTED", file=sys.stderr)
            return 0
        cmd = [sys.executable or "python3", ls, "--json"]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as exc:
            print("lane-route: lane-status unavailable (%s) — NOTHING IS ROUTED, and absence is not "
                  "idleness" % exc.__class__.__name__, file=sys.stderr)
            return 0
        raw = p.stdout or ""
        if p.returncode != 0 or not raw.strip():
            print("lane-route: lane-status rc=%s — nothing routed (an unread fleet is not an idle one)"
                  % p.returncode, file=sys.stderr)
            return 0
    try:
        rows = json.loads(raw)
    except ValueError:
        print("lane-route: lane-status output was not JSON — nothing routed", file=sys.stderr)
        return 0

    if a.lane:
        rows = [r for r in rows if (r.get("lane") or "") == a.lane]

    surface = CmuxSurface(sessions=_session_paths(rows)) if a.apply else None
    out = []
    for row in rows:
        ev, extra = evidence_for(row, read_screen=a.apply, surface=surface)
        r = triage.route(ev)
        item = r.as_dict()
        item["lane"] = ev.lane
        item["verdict"] = ev.lane_verdict
        if a.apply:
            brief = os.path.join(a.state, "lane-route", "brief.txt")
            os.makedirs(os.path.dirname(brief), exist_ok=True)
            with open(brief, "w") as fh:
                fh.write(triage_arms.question_brief(ev.lane, ev.last_text, extra["ws"]))
            proof = triage_arms.execute(
                r, ev, surface, ws=extra["ws"], child=extra["child"],
                dispatch=_make_dispatch(brief), relaunch=_make_relaunch(),
                poll=_make_poll(surface),
            )
            triage_arms.write_record(a.state, ev.lane, r, proof)
            item["result"] = proof.as_dict()
        out.append(item)

    if a.json:
        print(json.dumps(out, indent=2, default=str))
        return 0

    for item in out:
        line = "%-26s %-13s %-22s %s" % (
            (item["lane"] or "?")[:26], item["route"],
            (item.get("subcase") or "-"), item["action"])
        if "result" in item:
            res = item["result"]
            line += "  [%s%s]" % ("VERIFIED" if res["verified"] else "unverified",
                                  "" if res["verified"] else (": " + res["detail"][:90]))
        print(line)
    print(triage.summary(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
