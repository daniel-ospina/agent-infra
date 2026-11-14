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
import re
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


# ⛔ THE FARMED COPY MUST FIND ITS DEPENDENCIES (round 6, #4046 P1). `pi-bootstrap/setup.sh` farms
# `triage.py`/`triage_arms.py`/`liveness.py` into `$SCRIPTS/fleet`, and `AGENT_INFRA_PATH` is UNSET in
# the population that runs this (measured on this box, and absent from both the launchd plist template
# and `heartbeat-loop.sh`). Without this entry a farmed CLI died at import with
# `ModuleNotFoundError: No module named 'liveness'` and routed nothing.
if os.path.join(SCRIPTS, "fleet") not in sys.path:
    sys.path.insert(0, os.path.join(SCRIPTS, "fleet"))
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
        # ⛔ WHAT WAS ACTUALLY TYPED, PER WORKSPACE (round 2 review, #4046 P2). `triage_arms`
        # verifies the QUESTION MANDATE against the text the lane received, not against the text the arm
        # composed — a transport that silently truncated is the #1187 class. Without this record that
        # check degenerates into a self-check in production while reading as a property.
        # The payload is the FLATTENED form (one line: a newline in `cmux send` submits its own turn).
        self.last_sent = {}


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
        if rc == 0:
            # Recorded only on a successful send: a refused send typed nothing, and claiming a record
            # for it would let the mandate check read text the lane never received.
            self.last_sent[ws] = flat
        return rc == 0

    def transcript_size(self, ws):
        path = self.sessions.get(ws)
        if not path:
            return None
        try:
            return os.path.getsize(path)
        except OSError:
            return None

    def _terminal_for(self, ws):
        """Resolve a workspace to the TERMINAL id of its active pane. `read-screen` takes no workspace.

        ⛔ THE REAL SHAPE, MEASURED (round 5/6, #4046 P0). `cmux tree --json` on this build carries
        `workspaces[]` as `{focused,id,index,name,session_id}` — it has NO `terminal`/`tabs`/`panes`
        field, so the first version of this method answered `None` for every workspace on the box,
        which made `screen_tail` permanently unreadable: the question arm could never verify, the
        dedupe never armed (the same brief was re-sent every tick), and `boot-prompt` was unreachable
        from the only acquirer. The join that does exist — and that `cloud-cell-supervisor.test.sh`'s
        fixture models — is
            workspaces[].id → screens[].workspace_id → screens[].layout.active_pane_id
            → tabs[].pane_id → tabs[].content_id (content_kind == "terminal")
        resolved here against the SAME blob, never a cached id (a workspace's active pane moves).
        """
        rc, out, _ = _cmux(["tree", "--json"])
        if rc != 0 or not out.strip():
            return None
        try:
            blob = json.loads(out)
        except ValueError:
            return None
        if not isinstance(blob, dict):
            return None

        # a workspace already exposing a terminal (older/newer shapes) is taken at its word
        for space in (blob.get("workspaces") or []):
            if isinstance(space, dict) and space.get("id") == ws:
                for key in ("terminal", "terminal_id"):
                    if isinstance(space.get(key), str) and space.get(key):
                        return space[key]

        tab_by_id = {}
        for tab in (blob.get("tabs") or []):
            if isinstance(tab, dict) and tab.get("id"):
                tab_by_id[tab["id"]] = tab
        pane_ids = set()
        for tab in tab_by_id.values():
            if tab.get("pane_id"):
                pane_ids.add(tab["pane_id"])

        for screen in (blob.get("screens") or []):
            if not isinstance(screen, dict) or screen.get("workspace_id") != ws:
                continue
            layout = screen.get("layout") or {}
            root = layout.get("root") or {}
            # the active pane first, then any pane the layout names, then any tab the screen owns
            candidates = [layout.get("active_pane_id"), root.get("active_pane_id"),
                          root.get("pane_id"), layout.get("zoomed_pane_id")]
            for pid in candidates:
                if not pid:
                    continue
                for tab in tab_by_id.values():
                    if tab.get("pane_id") == pid and tab.get("content_kind") == "terminal" \
                            and tab.get("content_id"):
                        return tab["content_id"]
            for tid in (root.get("tab_ids") or []):
                tab = tab_by_id.get(tid)
                if tab and tab.get("content_kind") == "terminal" and tab.get("content_id"):
                    return tab["content_id"]
        return None

    def screen_tail(self, ws, lines=40):
        term = self._terminal_for(ws)
        if not term:
            return None
        rc, out, _ = _cmux(["read-screen", "--terminal", term, "--lines", str(lines)])
        if rc != 0:
            return None
        # ⛔ AN EMPTY CAPTURE IS NOT A BLANK PANE. rc=0 with no output is what this build returns when
        # the argv is a near-miss; reading it as "" made `_boot_blocked` answer `False` ("no prompt")
        # from a read that produced nothing. `None` is the unread answer, and the arms treat it as
        # unverified.
        if not (out or "").strip():
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
    # ⛔ `row["tool"]` IS A DICT, NOT A `liveness.Tool` (fresh-context review, #4046).
    # `lane-status.py:in_flight_tool()` returns `dict(name=…, timeout=…, age=…)`, so the first version's
    # `getattr(tool, "tools_in_flight", 0)` / `getattr(tool, "hard_cap_ms", None)` were reading
    # ATTRIBUTES a dict does not have: `tool_in_flight` was permanently `False` and the
    # `tool-in-flight`/`wait` subcase was UNREACHABLE from the only acquirer — a subcase that existed
    # in the router, had a fixture, and could never fire in production. `timeout` is the call's own
    # DECLARED budget (lane-status's LONG-TOOL note: `timeout 3000s` observed sitting 38 minutes).
    tool = row.get("tool") if isinstance(row.get("tool"), dict) else None
    tool_in_flight = bool(tool)
    age = tool.get("age") if tool else None
    cap_s = tool.get("timeout") if tool else None
    # `timeout` is declared in SECONDS and `age` in seconds too — compare like with like.
    budget_read = bool(tool_in_flight and isinstance(age, int)
                       and isinstance(cap_s, (int, float)) and cap_s > 0)
    budget_open = bool(budget_read and age < cap_s)
    child = row.get("child") or {}
    child_state = ""
    if row.get("verdict") == "CHILD-STUCK":
        child_state = "stuck"
    elif row.get("verdict") == "CHILD-OVERDUE":
        child_state = "overdue"
    boot = None
    if read_screen and surface is not None and row.get("ws"):
        # ⛔ ORDER, NOT PRESENCE (round 4, #4046 P1) — the SAME rule the arm applies, imported from the
        # module that owns it rather than re-derived. The first version tested presence of "press any
        # key", which `cmux_dispatch.boot_blocked` explicitly documents as wrong (a satisfied prompt
        # stays in scrollback for the life of the session), and it also looked for "boot-block", a
        # string pi never prints. A presence test here classifies every healthy lane as blocked.
        boot = triage_arms._boot_blocked(surface.screen_tail(row["ws"], 60))
        if boot is None:
            boot = None
    last_text = triage.last_text_from_jsonl(path) if read_text else ""
    return triage.Evidence(
        lane=row.get("lane") or "",
        turn=turn,
        last_text=last_text,
        lane_verdict=row.get("verdict") or "",
        child_state=child_state,
        # ⛔ (sid, ws, path) — the THREE-PART probe. The argv-only form returned `None` for every
        # ordinary lane (a live `pi` has argv exactly `pi`, measured), which would have made
        # `turn-end.py` nudge nobody. See `triage.steerable`'s docstring.
        steerable=triage.steerable(sid, ws=row.get("ws"), session_path=path),
        boot_prompt=boot,
        # The `model-retry` subcase's PRODUCER — a declared subcase with no producer is a fixture
        # certifying a reachability production cannot supply (fresh-context review, #4046).
        model_retry=triage.retry_signature(last_text),
        tool_in_flight=tool_in_flight,
        tool_budget_open=budget_open,
        tool_budget_read=budget_read,
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
            # ⛔ `None`, NOT `3` (round 6, #4046 P2). `3` is lane-relaunch's OWN "my guard refused"
            # verdict, so an absent tool was recorded as a refusal by a tool that was never run — a
            # false cause in a durable record. `None` is "could not even find it", and `arm_rerun`
            # reports UNAVAILABLE.
            return None
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
    # ⛔ (round 6, #4046 P2): a BATCHED caller hands over rows for one purpose. Applying anything else
    # they happen to earn (a `send-continue` whose arm polls for up to 120 s) would outlive the
    # caller's own budget. An empty value means "no filter", which is the operator default.
    ap.add_argument("--only-route", default="")
    # ⛔ REPEATABLE (round 5, #4046 P2): `turn-end.py` routes every asking lane in ONE call, so a
    # tick pays for ONE `lane-status.py` scan rather than one per asking lane.
    ap.add_argument("--lane", action="append", default=[])
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
        wanted = set(a.lane)
        rows = [r for r in rows if (r.get("lane") or "") in wanted]

    surface = CmuxSurface(sessions=_session_paths(rows)) if a.apply else None
    out = []
    suppressed = {}
    for row in rows:
        ev, extra = evidence_for(row, read_screen=a.apply, surface=surface)
        r = triage.route(ev)
        if a.only_route and r.route != a.only_route:
            continue
        item = r.as_dict()
        item["lane"] = ev.lane
        item["verdict"] = ev.lane_verdict
        if r.action == "refuse":
            suppressed[r.reason.split(" — ")[0]] = suppressed.get(r.reason.split(" — ")[0], 0) + 1
        if a.apply:
            # ⛔ ONE PAYLOAD PER ROUTE, NOT ONE BRIEF FOR ALL OF THEM (fresh-context review, #4046).
            # The first version always wrote the USER-QUESTION brief and handed it to every arm, so a
            # BOOT-PROMPT repair typed the question-lane mandate into the lane being repaired. The
            # question arm is the only one that needs a brief at all; the boot repair needs a resume
            # line, because what it is recovering is a lane, not a decision.
            os.makedirs(os.path.join(a.state, "lane-route"), exist_ok=True)
            payload = triage_arms.payload_for(r, ev, extra["ws"])
            # ⛔ A ROUTE IS APPLIED ONCE, NOT ONCE PER TICK (round 4, #4046 P1). `turn-end.py` now
            # invokes this CLI for a lane that asked, and it ticks — so without this guard the same
            # brief would be typed into the question lane every tick, and the owner's panel would
            # fill with duplicates of one question. The record on disk is the guard: same lane, same
            # route, same payload digest => already routed, and the second call says so.
            prev = triage_arms.record_path(a.state, ev.lane)
            if r.action == "route-to-question-lane" and os.path.exists(prev):
                try:
                    with open(prev) as fh:
                        old = json.load(fh)
                except (OSError, ValueError):
                    old = {}
                old_res = (old.get("result") or {})
                # ⛔ AND THE PRIOR ROUTE MUST HAVE BEEN VERIFIED (round 5, #4046 P1). The artifact
                # carries `brief_sha` on EVERY path after workspace resolution, including a FAILED
                # send — so matching on route+digest alone replayed an unverified attempt as
                # `already-routed, verified: true` forever: the question was never re-sent and the
                # record asserted it had been delivered. A prior `verified: false` is a RETRY.
                if (old.get("route") == r.route
                        and old_res.get("verified") is True
                        and (old_res.get("artifact") or {}).get("brief_sha")
                        == triage_arms._digest(payload)):
                    item["result"] = {"action": "already-routed", "proof": r.proof,
                                      "verified": True, "asserts_lane": False,
                                      "detail": "this exact brief is already on the question lane "
                                                "(%s) — not re-sent" % (old_res.get("detail") or ""),
                                      "sent": False, "artifact": {"dedupe": "brief_sha"}}
                    out.append(item)
                    continue
            # ⛔ ONE PAYLOAD FILE PER LANE PER PROCESS (round 5, #4046 P2). This was a single shared
            # `payload.txt` handed to `cmux_dispatch.py` (420 s timeout), so a `turn-end` tick and an
            # operator run could overwrite it between write and read and type ONE lane's boot brief
            # into ANOTHER lane. Lane- and pid-keyed like `record_path`/`handoff_path`.
            brief = os.path.join(a.state, "lane-route",
                                 "payload-%s-%d.txt" % (re.sub(r"[^A-Za-z0-9_.-]", "_",
                                                               ev.lane or "lane"), os.getpid()))
            with open(brief, "w") as fh:
                fh.write(payload)
            try:
                proof = triage_arms.execute(
                    r, ev, surface, ws=extra["ws"], child=extra["child"],
                    dispatch=_make_dispatch(brief), relaunch=_make_relaunch(),
                    poll=_make_poll(surface), state_dir=a.state,
                )
            finally:
                try:
                    os.unlink(brief)
                except OSError:
                    pass
            triage_arms.write_record(a.state, ev.lane, r, proof)
            item["result"] = proof.as_dict()
        out.append(item)

    if suppressed:
        # ⛔ A WITHHELD ARM MUST BE COUNTED, NOT PER-LANE ONLY. A per-lane SKIP line is invisible in a
        # beat, and a fleet-wide refusal reads as a quiet fleet — the same defect the router exists to
        # remove, one layer up. One line, with the reasons.
        print("router=refuse:%d (%s)" % (sum(suppressed.values()),
                                         "; ".join("%s x%d" % (k, v)
                                                   for k, v in sorted(suppressed.items()))),
              file=sys.stderr)

    if a.json:
        print(json.dumps(out, indent=2, default=str))
        return 0

    for item in out:
        line = "%-26s %-13s %-22s %s" % (
            (item["lane"] or "?")[:26], item["route"],
            (item.get("subcase") or "-"), item["action"])
        if "result" in item:
            res = item["result"]
            # ⛔ `verified` ON A READING ARM IS NOT AN EFFECT (round 6, #4046 P2).
            if res.get("asserts_lane") is False:
                line += "  [READ]"
            else:
                line += "  [%s%s]" % ("VERIFIED" if res["verified"] else "unverified",
                                      "" if res["verified"] else (": " + res["detail"][:90]))
        print(line)
    print(triage.summary(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
