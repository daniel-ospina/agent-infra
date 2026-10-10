#!/usr/bin/env python3
"""lane-guard.py — is this lane PROVABLY not working right now?

WHY THIS EXISTS (incident 2026-10-01, measured)
    queue-dispatch.py decided to send on the strength of ONE field, `verdict == DONE-IDLE`,
    read from a bulk `lane-status.py` run. Two things were wrong with that:

    1. THE VERDICT IS A SAMPLE, NOT A STATE. `DONE-IDLE` is computed from a short sample
       window. A lane that started a turn one second after the read is indistinguishable
       from one that stayed idle — measured: a lane read DONE-IDLE and was WORKING seconds
       later, and it was SIDETRACKED onto a different PR while its own WIP was in flight.
    2. THE GUARD COULD NOT BE RE-RUN AT SEND TIME. `lane-status.py --json` classifies every
       lane (27 of them, each with a pgrep/lsof walk) and MEASURED 88s. A guard you cannot
       afford to re-run is not a guard, and at a 240s outer timeout on a box where a single
       cmux call takes 13-15s at load, it reported `rc=None (timeout)` instead of refusing.

    So this probe is LANE-LOCAL and BRACKETED. It imports lane-status.py's own resolution
    and probe primitives -- it does not re-implement or re-run the classifier -- and it
    asks a different question with the opposite polarity:

        NOT "is the verdict DONE-IDLE?"          (a sample that can be stale)
        BUT "is there POSITIVE evidence that nothing is in flight?"  (a bracket)

    POSITIVE EVIDENCE OF NO WORK = ALL of:
      * the lane's session resolves to a real file            (unknown is NOT idle)
      * the pane is readable                                  (unknown is NOT idle)
      * no `Working` spinner in the pane                      (the turn-in-flight signal)
      * no pending child in the transcript, no declared child, no pane child
                                                              (work happening off-root)
      * the session file does not move during the probe        (bracketed double-read)
      * no spinner/child APPEARS during the probe              (re-verified, not assumed)
      * the last write is at least --min-idle seconds old      (a turn is not mid-flight)

    A bracket, not a snapshot: the file is read again AFTER the other probes, so a turn
    that begins DURING the probe is caught rather than missed.

USAGE
    lane-guard.py --ws <workspace-uuid> [--label <lane-label>]
                  [--window 3] [--min-idle 120] [--budget 45] [--json]
EXIT
    0  CONSUMABLE  — positive evidence of no work in flight
    3  REFUSED     — busy, or the lane's state is UNKNOWN (never read as idle)
    2  usage error
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import time

SCRIPTS = os.path.dirname(os.path.abspath(__file__))

# A hung cmux must become a FAST refusal, not a slow non-answer. safe-send.sh raises this
# ceiling for its own calls (60s); the GUARD deliberately keeps a tighter one, because its
# job is to answer "may I send?" promptly — an answer of UNKNOWN at 20s is more useful to a
# caller than a real answer at 90s, and the caller's remedy (retry next tick) is the same.
os.environ.setdefault("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", "20")


def _load_lane_status():
    """Import lane-status.py by path (its filename has a dash, so not a normal import)."""
    path = os.path.join(SCRIPTS, "lane-status.py")
    spec = importlib.util.spec_from_file_location("lane_status", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def probe(ws: str, label: str, window: float, min_idle: float, budget: float) -> dict:
    """Return the observation dict. Every field is a MEASURED fact, never an inference."""
    t0 = time.time()
    ls = _load_lane_status()

    def over() -> bool:
        return (time.time() - t0) > budget

    obs: dict = {"ws": ws, "label": label, "ok": False, "reason": "", "elapsed_s": 0.0}

    # ── 1. the session must RESOLVE. Unresolvable is UNKNOWN, and UNKNOWN is never idle.
    try:
        sid = ls.resolve_session(ws)
    except Exception as exc:  # noqa: BLE001
        obs["reason"] = f"session resolve FAILED ({exc.__class__.__name__}) — state UNKNOWN, not idle"
        return obs
    path = ls.session_file(sid) if sid else None
    if not path or not os.path.exists(path):
        obs["reason"] = "session UNRESOLVED — state UNKNOWN, not idle"
        return obs
    obs["sid"] = sid
    obs["session_file"] = path

    def st():
        s = os.stat(path)
        return s.st_mtime, s.st_size

    # ── 2. bracket OPEN: read the file BEFORE the other probes.
    m0, s0 = st()
    obs["size_start"] = s0
    obs["stale_s_start"] = round(time.time() - m0, 1)

    if over():
        obs["reason"] = f"probe budget {budget}s exhausted before probing — refusing unanswered"
        return obs

    # ── 3. the pane must be READABLE and must not be mid-turn.
    screen = ls.read_screen(ws, lines=14) or ""
    if not screen.strip():
        obs["reason"] = "pane UNREADABLE — busy/idle UNKNOWN, not idle"
        return obs
    if ls.ui_working(ws):
        obs["reason"] = "pane shows `Working` — mid-turn; a message would QUEUE unread"
        obs["spinner"] = True
        return obs

    # ── 4. children — the SAME three signals the classifier wires, and only those.
    #
    # ⛔ DO NOT use `child_process_alive(cwd)` here. It is marked UNUSED in
    # lane-status.py for a measured reason, and this guard REPRODUCED that defect on its
    # first run: it matches a `pi` process whose cwd is under the lane's root, so on a
    # shared checkout EVERY idle lane matches a SIBLING's process and reads
    # `live_child=True`. Measured here 2026-10-01: both genuinely idle lanes
    # (`1 Capture write doors`, `6 Durability core`) were wrongly REFUSED with
    # `live_child=True`. The file's own note says it must first be given the lane's issue
    # numbers so a cwd can be matched to THIS lane; it is not validated, so it is not used.
    #
    # The wired signals are: the transcript's own unmatched child call (`pending_child`),
    # the out-of-root declared children, and the children visible on the pane.
    try:
        declared = ls.declared_children(label) or []
    except Exception:  # noqa: BLE001
        declared = []
    pane_kids = ls.parse_child_lines(screen) or []
    try:
        pc = ls.pending_child(path)
    except Exception:  # noqa: BLE001
        pc = None
    obs.update(declared_children=len(declared), pane_children=len(pane_kids),
               pending_child=(pc or {}).get("age") if pc else None)
    if declared or pane_kids or pc:
        detail = f"age={pc['age']}s task={pc['task'][:60]!r}" if pc else f"declared={len(declared)} pane={len(pane_kids)}"
        obs["reason"] = f"waiting on its OWN child — {detail}; not idle"
        return obs

    # ── 5. the WINDOW: let the lane move if it is going to.
    time.sleep(max(0.0, window))

    # ── 6. re-verify EVERYTHING at the moment of sending (the stale-verdict fix).
    m1, s1 = st()
    obs["size_end"] = s1
    obs["stale_s_end"] = round(time.time() - m1, 1)
    if (m1, s1) != (m0, s0):
        obs["reason"] = (
            f"session MOVED during the probe (size {s0}->{s1}, mtime {m0:.0f}->{m1:.0f}) "
            f"— work is in flight NOW")
        return obs
    screen2 = ls.read_screen(ws, lines=14) or ""
    if ls.ui_working(ws) or "Working" in (screen2 or ""):
        obs["reason"] = "a `Working` spinner APPEARED during the probe — a turn started while we checked"
        return obs
    if (ls.parse_child_lines(screen2) or []):
        obs["reason"] = "a child process APPEARED during the probe — work started while we checked"
        return obs

    # ── 7. closing read: the bracket must still be closed at the instant we return.
    m2, s2 = st()
    if (m2, s2) != (m1, s1):
        obs["reason"] = "session moved again at the closing read — a turn is in flight"
        return obs

    # ── 8. a floor on stillness: a lane that took a turn a moment ago is NOT idle evidence.
    idle_for = time.time() - m2
    obs["idle_for_s"] = round(idle_for, 1)
    if idle_for < min_idle:
        obs["reason"] = (
            f"only quiet {idle_for:.0f}s (< {min_idle}s) — too recently active to call idle; "
            f"retry next tick")
        return obs

    obs["ok"] = True
    obs["reason"] = f"no work in flight — quiet {idle_for:.0f}s, no spinner, no child, session still"
    return obs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ws", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--window", type=float, default=3.0)
    ap.add_argument("--min-idle", type=float, default=120.0)
    ap.add_argument("--budget", type=float, default=45.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    t0 = time.time()
    try:
        obs = probe(a.ws, a.label, a.window, a.min_idle, a.budget)
    except Exception as exc:  # noqa: BLE001
        obs = {"ws": a.ws, "ok": False, "reason": f"probe raised {exc.__class__.__name__}: {exc}"}
    obs["elapsed_s"] = round(time.time() - t0, 1)

    if a.json:
        print(json.dumps(obs, indent=2))
    else:
        print(("CONSUMABLE" if obs.get("ok") else "REFUSED") + f" [{obs.get('elapsed_s')}s] {obs.get('reason','')}")
    return 0 if obs.get("ok") else 3


if __name__ == "__main__":
    sys.exit(main())
