#!/usr/bin/env python3
"""turn-end.py — act on a lane that has FINISHED A TURN, instead of waiting for
a human to notice.

WHAT IT DOES
    For every lane whose verdict is `WIP-IDLE` (the lane stopped mid-work: work in
    flight, nothing running) and whose session file has NOT grown since we last
    spoke to it, send one nudge telling it to continue.

    Nothing else. It does NOT touch `DONE-IDLE` (a lane that finished: choosing the
    next issue needs the lane->label->rank judgement the orchestrator holds, and
    auto-nudging there manufactures work), `WEDGED` (recovering a wedged lane is a
    diagnosis, not a message), `WAITING-CHILD` (its child is still writing) or
    `LONG-TOOL` (a declared budget is still running).

WHY THE `WIP-IDLE`-ONLY SCOPE
    The owner's own words were "mid WIP and have no question => nudge to continue".
    "Mid WIP" is exactly what `WIP-IDLE` names, and it is the one verdict where the
    next action is unambiguous: the lane has work in flight, so `continue` is right
    whoever is right about anything else. Every other verdict needs a judgement
    this script cannot make from a session file.

THE MEMORY IS A FILE SIZE, NOT A DATABASE
    The dedup key is the session file's byte length, recorded in a small marker
    file per lane. A lane that has taken a turn has a BIGGER file; a lane sitting
    still has the same number. So the marker goes stale on its own the moment the
    lane does anything, with no TTL to tune and no state to migrate. This is the
    same trick as the question gate's label: the cheapest durable fact that already
    exists is the state.

    A lane that is nudged and answers "I am blocked" grows its file, so it becomes
    eligible again after the next quiet period. That is intended: a lane that keeps
    stopping mid-work is a lane the orchestrator should keep prodding. The blast
    radius is bounded instead by MAX_PER_TICK and by LANE-NUDGE-OFF.

WHY IT SKIPS A LANE HOLDING A QUESTION
    A lane that has already posted a question carries a `RESEARCH:` declaration in
    its transcript. Detecting that is MECHANICAL — it reads a declared field, it
    does not judge prose — so it is text matching, not a "does this feel readable"
    classifier. When it fires, the scan in ask-owner.py owns that lane and this
    script stays quiet, which is the owner's stated rule.

    NOTE the tension, deliberately recorded: the beta plan's §5 says a question
    never stalls the lane, so a lane holding a question SHOULD arguably be nudged
    to carry on with the unblocked part. This script honours the owner's literal
    instruction instead (skip), because a skipped nudge is the safe direction — the
    lane waits for the owner exactly as it does today, and the question is queued
    where the owner will see it. Flip SKIP_IF_QUESTION to change that.

USAGE
    python3 turn-end.py [--dry-run] [--limit-seconds 30]

EXIT
    0 always when it ran; 1 only for a usage/lock problem. A nudge that cannot be
    delivered is logged and NOT marked, so the next tick retries it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATE = f"{HOME}/.pi/agent/state"
SCRIPTS = f"{HOME}/.pi/agent/scripts"
LOG = f"{STATE}/turn-end.log"
MARK_DIR = f"{STATE}/turn-end"
KILL = f"{STATE}/HEARTBEAT-OFF"
NUDGE_KILL = f"{STATE}/LANE-NUDGE-OFF"
LOCK = f"{STATE}/turn-end.lock"
CMUX_DISPATCH = (f"{HOME}/Documents/GitHub/tortoise/tools/cmux_dispatch.py")

# A lane must have been quiet this long before we speak. Below it, a lane that has
# simply paused between tool calls would be interrupted.
REPOS = ("daniel-ospina/tortoise",
         "daniel-ospina/premise-labs",
         "daniel-ospina/agent-infra")

IDLE_MIN_S = 600
# Per tick. The loop runs every 5 minutes; a quiet fleet nudges nobody.
MAX_PER_TICK = 3
# Never nudge the same lane more often than this, even if its file changed. A lane
# that answers and immediately goes quiet again should not be spoken to twice in
# one sitting.
MIN_GAP_S = 900
# See the module docstring: this implements the owner's literal rule.
SKIP_IF_QUESTION = True

# ⛔ THE TRANSCRIPT GUARD WAS DEAD CODE - DO NOT RESURRECT IT.
# `DECL_RE = ^\s*RESEARCH:\s*skill=` matched **0** times against a session tail that
# contained the substring **26** times (measured on 2c Pack compile). In a .jsonl the
# declaration is inside a JSON string on one physical line, so re.M's ^ never lands on
# it; decoding the records does not save it either, because the lane's own text carries
# the line as `` `RESEARCH: ...` `` (backtick-prefixed). The guard now reads the ISSUE'S
# LABEL - the gate's own output - which is authoritative and needs no prose parsing.
DECL_RE = re.compile(r"^\s*RESEARCH:\s*skill=", re.M)   # kept for reference only
DECL_RE = re.compile(r"^\s*RESEARCH:\s*skill=", re.M)

# ⛔ DELIVERY IS VERIFIED AGAINST THE ARTIFACT, NOT THE DISPATCHER'S EXIT CODE.
# `cmux_dispatch.py send` returned rc=1 with
#   "not consumed (not-at-the-head-of-latest-submitted-message) — recovery: release-only"
# while the lane's session file demonstrably contained the brief verbatim and the
# lane had started working on it (measured 2026-09-25, lane `7 Instrumentation`).
# That is the #5204 false-negative class, and it is fatal to a naive caller: rc!=0
# means "do not record this as delivered", so the next tick would send the SAME
# brief again, forever. So the exit code is only a HINT — the verdict comes from
# the transcript, which is where the message actually has to appear.
NUDGE_SENTINEL = "ORCHESTRATOR — automatic dispatch"
# How long to poll the transcript when the dispatcher says the send was not
# consumed. Measured cost of the NEGATIVE path: a full timeout. With MAX_PER_TICK
# lanes that is 3 x this, on top of lane-status's own sample window — so it must
# stay comfortably under the loop's 300 s interval, because a tick that overruns
# its interval is a tick that silently skips. 45 s leaves ~150 s of margin.
LAND_TIMEOUT_S = 45
LAND_POLL_S = 3


def log(msg: str) -> None:
    try:
        with open(LOG, "a") as fh:
            fh.write(f"{time.strftime('%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def sh(argv: list[str], timeout: int = 120) -> tuple[int, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:                                   # noqa: BLE001
        return 999, f"{type(exc).__name__}: {exc}"


def tail_text(path: str, nbytes: int = 400_000) -> str:
    """The last `nbytes` of a session file.

    A session file is read from the TAIL because these files reach tens of MB and
    the only question here is what the lane did recently. Reading 400 KB costs
    nothing; reading 24 MB per lane per tick does not.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > nbytes:
                fh.seek(size - nbytes)
            return fh.read().decode("utf-8", "replace")
    except Exception:
        return ""


def session_path(sid: str) -> str | None:
    import glob
    hits = glob.glob(f"{HOME}/.pi/agent/sessions/*/*{sid}*.jsonl")
    if not hits:
        return None
    return max(hits, key=os.path.getmtime)


def marker_path(lane: str) -> str:
    slug = hashlib.sha1(lane.encode()).hexdigest()[:12]
    return f"{MARK_DIR}/{slug}.json"


def read_marker(lane: str) -> dict:
    try:
        with open(marker_path(lane)) as fh:
            return json.load(fh)
    except Exception:
        return {}


def write_marker(lane: str, **kw) -> None:
    cur = read_marker(lane)
    cur.update(kw)
    try:
        os.makedirs(MARK_DIR, exist_ok=True)
        tmp = marker_path(lane) + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(cur, fh)
        os.replace(tmp, marker_path(lane))
    except Exception as exc:                                   # noqa: BLE001
        log(f"ERR could not write marker for {lane}: {exc}")


def wait_for_landing(f: str, before_size: int | None) -> bool:
    """Did the brief actually become part of the lane's transcript?

    Both halves are required. `grew` catches "the file moved at all", and the
    sentinel catches "it moved because of OUR message" rather than because the lane
    happened to be mid-turn. The pre-send size comes from the same lane-status
    sample that decided to nudge, so `grew` is measured against a real floor and
    not against a value read after the send.
    """
    deadline = time.time() + LAND_TIMEOUT_S
    while time.time() < deadline:
        try:
            if (before_size is None or os.path.getsize(f) > before_size) \
                    and NUDGE_SENTINEL in tail_text(f):
                return True
        except Exception:
            pass
        time.sleep(LAND_POLL_S)
    return False


def build_wip_nudge(lane: str, label: str, quiet_min: int, recent: list[str]) -> str:
    label_line = (f"Your lane label is `{label}` — its open issues are "
                  f"`gh issue list --state open --label {label} --limit 40`."
                  if label else
                  "This lane has no GitHub label; your issue is named on the "
                  "issue you were working.")
    last = "\n".join(f"  - {r}" for r in recent) or "  - (nothing readable)"
    return f"""[ORCHESTRATOR — automatic; no reply needed unless it changes what you do]

Your session has not moved for {quiet_min} minutes and nothing is running in this
lane, so you appear to have stopped mid-work. Your last recorded activity:

{last}

Work is in flight, so the next action is unambiguous: CONTINUE IT. Do not stop to
ask whether to proceed — the default is GO.

If instead you are waiting on the owner, do not wait. A question never stalls the
lane. Put the question on your issue as ONE comment whose FIRST line is:

    RESEARCH: skill=<yes|no> sources=<internal|web|perplexity|none> refs=<file:line, url, issue#>

The gate reads that comment and either queues it for the owner or sends it back
with a template. Then, in the same turn, carry on with the part of the work that
is NOT blocked by it. Before asking anything, check the canon in this repo —
`docs/ONTOLOGY.md` records what we WANT, not what is current, plus
`docs/architecture/EXTRACTOR-V4-ARCHITECTURE.md` and
`docs/architecture/STORAGE-ARCHITECTURE.md`.

{label_line}

Reply with one line saying what you are doing next, then do it.
"""


def lanes_with_open_question() -> set:
    """Lane labels whose open issues carry `owner-decision` or `question-bounced`.

    A question is ONE comment on an ISSUE, so the issue's labels are the fact and the
    lane's transcript is not. Attribution is by the issue's own `lane:*` label; an
    issue with no lane label is REPORTED (never guessed) — same rule as
    ask-owner.py's lane_workspace().
    """
    out = set()
    for repo in REPOS:
        for label in ("owner-decision", "question-bounced"):
            rc, txt = sh(["gh", "issue", "list", "--repo", repo, "--state", "open",
                          "--label", label, "--limit", "100",
                          "--json", "number,labels"], timeout=90)
            if rc != 0:
                # Fail LOUD: an unreadable surface must never read as "no questions".
                log(f"ERR guard: {repo} --label {label} rc={rc} :: {txt.strip()[:120]}")
                continue
            try:
                rows = json.loads(txt)
            except Exception:
                log(f"ERR guard: {repo} --label {label} was not JSON")
                continue
            for r in rows:
                ls = [l["name"] for l in r.get("labels", [])]
                mine = [l for l in ls if l.startswith("lane:")]
                if not mine:
                    log(f"NOTE guard: {repo}#{r['number']} holds a question but has "
                        f"no lane:* label - cannot attribute, not guessing")
                    continue
                out.update(mine)
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--sample", type=float, default=12.0)
    a = ap.parse_args(argv)

    if os.path.exists(NUDGE_KILL):
        log("SKIP lane-nudge kill file present")
        return 0

    # One tick at a time. A tick can spend a minute in cmux delivery, and the loop
    # interval is 5 minutes, so overlap is possible on a slow box — and two ticks
    # racing would double-nudge.
    if os.path.exists(LOCK) and not a.dry_run:
        try:
            age = time.time() - os.path.getmtime(LOCK)
        except Exception:
            age = 0
        if age < 900:
            log(f"SKIP lock held ({int(age)}s old)")
            return 0
    if not a.dry_run:
        try:
            with open(LOCK, "w") as fh:
                fh.write(str(os.getpid()))
        except Exception:
            pass

    try:
        rc, out = sh(["/usr/bin/python3", f"{SCRIPTS}/lane-status.py",
                      "--json", "--sample", str(a.sample)], timeout=300)
        if rc != 0:
            log(f"ERR lane-status rc={rc} :: {out.strip()[:140]}")
            return 0
        try:
            rows = json.loads(out)
        except Exception:
            log("ERR lane-status output was not JSON")
            return 0

        now = time.time()
        sent = 0
        holds_question = lanes_with_open_question()
        if holds_question:
            log(f"guard: {len(holds_question)} lane(s) hold a question: "
                + ", ".join(sorted(holds_question)))
        for r in rows:
            if r.get("verdict") != "WIP-IDLE":
                continue
            lane = r["lane"]
            issue_label = r.get("issue_label") or ""
            stale = r.get("stale_s") or 0
            if stale < IDLE_MIN_S:
                continue
            sid, size = r.get("sid"), r.get("size")
            if not sid or size is None:
                continue
            m = read_marker(lane)
            if m.get("sid") == sid and m.get("size") == size:
                continue                      # already spoken to this exact state
            if now - (m.get("last") or 0) < MIN_GAP_S:
                continue                      # spoke recently; let it breathe
            if sent >= MAX_PER_TICK:
                log(f"CAP reached at {MAX_PER_TICK}; {lane} deferred to next tick")
                break

            f = session_path(sid)
            if SKIP_IF_QUESTION and issue_label in holds_question:
                log(f"SKIP {lane} holds a question ({issue_label} carries "
                    f"owner-decision/question-bounced)")
                continue

            msg = build_wip_nudge(lane, r.get("issue_label") or "",
                                  int(stale // 60), r.get("recent") or [])
            if a.dry_run:
                print(f"--- WOULD NUDGE {lane} (quiet {int(stale//60)}m, "
                      f"size {size}) ---\n{msg}")
                sent += 1
                continue

            os.makedirs(STATE, exist_ok=True)
            brief = f"/tmp/turn-end-{os.getpid()}.txt"
            with open(brief, "w") as fh:
                fh.write(msg)
            pre = None
            if f:
                try:
                    pre = os.path.getsize(f)
                except Exception:
                    pre = None
            # ── DELIVERY MECHANISM ────────────────────────────────────────────
            # QUEUEING send, NOT tools/cmux_dispatch.py. Third instance of the same
            # defect (see turn-classify.py and ask-owner.py, both fixed 2026-09-27):
            # the dispatcher requires the message to become the pane's latest
            # SUBMITTED message, which needs a FREE COMPOSER, so on a lane that is
            # mid-turn -- i.e. every lane that is actually working -- it waits out
            # its 180s timeout and returns non-zero. A plain `cmux send` QUEUES and
            # pi consumes it when the turn ends, which is what a nudge wants.
            # MEASURED: after the turn-classify fix, the queueing send delivered to
            # `1 Capture` (+27.8 KB, 0.0 min) and `8 Hosted` (+31.8 KB, 0.1 min)
            # where the dispatcher had reported SENT-BUT-NOT-CONFIRMED and delivered
            # nothing (46 min / 277 min unchanged).
            # ⛔ ONE LINE ONLY: a newline in the payload IS Enter; a multi-line
            # message would be submitted as several turns and arrive as fragments.
            flat = " ".join(msg.split())
            rc2, out2 = sh(["cmux", "send", "--workspace", r["ws"], flat + "\n"],
                           timeout=45)
            try:
                os.unlink(brief)
            except Exception:
                pass
            # The exit code is a HINT; the transcript is the verdict (see
            # NUDGE_SENTINEL). A lane that did not really receive the brief must
            # not be recorded as woken, or it is never spoken to again; a lane that
            # did receive it must be, or it is spoken to twice.
            ok = rc2 == 0 or (f is not None and wait_for_landing(f, pre))
            if ok:
                landed_size = size
                if f:
                    try:
                        landed_size = os.path.getsize(f)
                    except Exception:
                        pass
                write_marker(lane, sid=sid, size=landed_size, last=int(now))
                note = "" if rc2 == 0 else " (dispatcher false-negative; transcript confirmed)"
                log(f"NUDGE {lane} delivered (quiet {int(stale//60)}m){note}")
                sent += 1
            else:
                log(f"ERR nudge {lane} rc={rc2} :: {out2.strip()[:140]}")
        if sent == 0:
            log("OK no lane to nudge")
        return 0
    finally:
        if not a.dry_run:
            try:
                os.unlink(LOCK)
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
