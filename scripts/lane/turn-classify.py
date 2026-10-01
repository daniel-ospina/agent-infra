#!/usr/bin/env python3
"""turn-classify.py — at the end of a lane's turn, decide WHY it stopped, and act.

WHY THIS EXISTS
    A lane stops for four different reasons, and three of them look identical from
    the outside. Only two deserve a message, and the message differs.

        a question, protocol NOT used   -> tell it to use the protocol
        a question, protocol used       -> nothing (the queue has it)
        stopped with work left, no block-> remind it of the no-pause rule
        finished the work               -> nothing

    The old nudger branched on a VERDICT (`WIP-IDLE`) and always sent the same
    text. A verdict cannot tell "finished" from "gave up", and it cannot tell a
    question from a stall. This branches on WHAT THE TURN SAYS.

TWO MECHANISMS, DELIBERATELY SPLIT
    1. "Did it ask a question?" is PROSE -> Jev. One `choice` question over the
       turn's own last text. Measured $0.00017/call, and it discriminates
       ("asked_the_owner" 1.00 on a permission-ask vs "finished_the_work" 1.00 on
       a clean finish).
    2. "Did it use the protocol?" is a DECLARED FIELD -> plain code. The gate
       publishes it as an issue label (`owner-decision` / `question-bounced` /
       `owner-answered`), and GitHub labels are the canonical live list. No prose
       parsing, no regex.

    That split is the standing rule: mechanical is honest for a declared field,
    Jev for judgement about prose.

WHAT IT DELIBERATELY DOES NOT DO
    * Does NOT branch on CPU. Measured: 9 of 55 live `pi` processes have a flat
      own-CPU while a descendant subtree works. CPU is a load indicator, not a
      liveness one, and the fleet's recorded decision says so
      (`docs/ops/fleet-liveness.md` §5.1 — `task` deliberately absent from
      `CPU_LIVENESS_TOOL_NAMES`).
    * Does NOT act when the verdict cannot be read. Jev unreachable -> NO claim,
      NO message. `unknown` never nudges.

DEGRADES TO THE PREVIOUS BEHAVIOUR, NEVER TO SILENCE
    The marker directory is SHARED with turn-end.py, so a turn is claimed once.
    This script only claims a turn it actually CLASSIFIED — so if Jev is down,
    turn-end.py's cruder verdict-based nudge still runs as the fallback.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
STATE = f"{HOME}/.pi/agent/state"
SCRIPTS = f"{HOME}/.pi/agent/scripts"
REGISTRY = f"{STATE}/lane-registry.tsv"
CMUX_DISPATCH = f"{HOME}/Documents/GitHub/tortoise/tools/cmux_dispatch.py"

# SHARED with turn-end.py ON PURPOSE: one marker directory means one claim per
# turn, so the two nudgers cannot both speak to the same end-of-turn.
MARK_DIR = f"{STATE}/turn-end"
LOG = f"{STATE}/turn-classify.log"
LOCK = f"{STATE}/turn-classify.lock"
KILL = f"{STATE}/TURN-CLASSIFY-OFF"

SENTINEL = "ORCHESTRATOR — automatic"
LAND_TIMEOUT_S = 45
LAND_POLL_S = 3
LAND_TAIL_B = 2_000_000

MAX_PER_TICK = 3
MIN_GAP_S = 900
# How often a lane with NO work of its own may be told to pull the next item from the
# shared priority stack. Deliberately longer than the stall cadence: an idle lane nudged
# every tick is pure noise, and MAX_PER_TICK would then be spent on idle lanes instead of
# stalled ones. One hour per lane bounds that while still keeping the fleet fed.
IDLE_GAP_S = 3600
# Lanes that must NEVER be messaged, however idle they read. `HANG` is the owner's own
# interactive pane (`lane-hang-rootcause`): an automated nudge would inject text into a
# human's session. This path has no pid to walk back through, so the boundary is enforced
# by NAME here -- the same boundary the reaper's ancestry walk protects.
NEVER_NUDGE = {"HANG", "lane-hang-rootcause"}

# Jev's OWN uncertainty is a signal, and a low-confidence verdict is `unknown`.
# Acting on a coin-flip verdict is the "unknown must not authorise action" rule
# applied to the classifier itself.
#
# THRESHOLD CALIBRATION (small sample — re-derive as cases accumulate):
#   0.81  4a      stopped_with_work_left  -> GENUINE stop, message sent
#   0.69  2c      finished_the_work       -> correct (no action class anyway)
#   0.67  7 Instr stopped_with_work_left  -> FALSE POSITIVE, nudge sent; the lane
#                                             was running 5 child workspaces that
#                                             no status probe can see (#1478)
#   0.48  3 Onbrd stopped_with_work_left  -> FALSE POSITIVE, correctly withheld
#                                             (3 detached children, #1478)
#   0.42  3 Onbrd same lane, next sample  -> FALSE POSITIVE, withheld
#
# Every known false positive sits at or below 0.67; the one known genuine stop is
# 0.81. 0.75 separates them. This is a threshold on a JUDGEMENT, so it is stated
# with the cases it was derived from rather than as a round number — and the two
# false positives share one cause (#1478: detached/nested children are invisible),
# which means fixing that detector is what would let this come down.
MIN_CONFIDENCE = 0.60
TURN_BYTES = 600_000          # tail window we read the last turn out of
TURN_LIMIT = 8_000            # chars of turn text handed to Jev
SCAN_RECORDS = 500            # bound the walk back through the transcript

REPOS = ("daniel-ospina/tortoise",
         "daniel-ospina/premise-labs",
         "daniel-ospina/agent-infra")

JEV_URL = "https://jevtypesafeai.com/api/v1/decide"
JEV_MODEL = "jev-1.13.0"      # pinned, exactly as the gate pins it

# The three outcomes Jev chooses between. The FOURTH case the owner named —
# "a question, protocol used" — is not a Jev question: it is decided by the label.
OUTCOMES = ("asked_the_owner", "stopped_with_work_left", "finished_the_work")

# The harness's own in-flight bound for a `task`/`subagent` child is ~25 minutes
# (`lane-status.py` OVERDUE_S). A pending child older than this is DEAD, not
# waiting: the harness killed it and its call never received a result, so the
# record cannot clear on its own. Treating such a record as "still in flight"
# silently disabled auto-continue for every lane that had ever dispatched a
# child -- measured 2026-09-27 with ages of 19258s and 20224s (5.4 and 5.6 hours).
CHILD_LIVE_MAX_S = 1800

TURN_QUESTION = {
    "outcome": {
        "type": "choice",
        "instructions": (
            "This is the FINAL message of an agent's turn. Which of these best "
            "describes how the turn ended?\n"
            "Judge the ENDING, not the topic. A turn that reports finished work "
            "and then adds 'tell me if you want more' still ENDED by asking."
        ),
        "criteria": {
            "asked_the_owner": (
                "It ends by asking the reader to decide, approve, confirm, or "
                "choose something — including permission-flavoured asks such as "
                "'shall I…', 'want me to…', 'should I continue', 'let me know "
                "if…', 'say the word'."
            ),
            "stopped_with_work_left": (
                "It ends without finishing the task and without asking anything: "
                "it narrates progress and simply stops, or defers the remaining "
                "work to a later step it has not taken."
            ),
            "finished_the_work": (
                "It completed the task it set out to do and nothing it named "
                "remains to be done — reporting done work, evidence, and results."
            ),
        },
    }
}


def log(msg: str) -> None:
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(f"{time.strftime('%m-%d %H:%M:%S')} {msg}\n")
    except Exception:                                            # noqa: BLE001
        pass


def sh(argv: list[str], timeout: int = 120) -> tuple[int, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:                                     # noqa: BLE001
        return 1, str(exc)


def tail_text(path: str, nbytes: int = TURN_BYTES) -> str:
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > nbytes:
                fh.seek(size - nbytes)
            return fh.read().decode("utf-8", "replace")
    except Exception:                                            # noqa: BLE001
        return ""


def _role(rec: dict) -> str | None:
    return (rec.get("role")
            or (rec.get("message") or {}).get("role")
            or rec.get("type"))


def _text_of(rec: dict) -> str:
    m = rec.get("message") or rec
    c = m.get("content")
    if isinstance(c, list):
        return "".join(p.get("text", "") for p in c
                       if isinstance(p, dict) and p.get("type") == "text")
    return c if isinstance(c, str) else ""


def last_turn_text(path: str) -> str:
    """The lane's own final words for the turn it just ended.

    Walks BACKWARDS from EOF and collects the trailing assistant text, stopping at
    the first non-assistant record once it has something. That is the right
    boundary: a turn ends with the agent's prose, and what precedes it is the tool
    traffic that produced it.
    """
    txt = tail_text(path)
    parts, seen = [], 0
    for line in reversed(txt.splitlines()):
        seen += 1
        if seen > SCAN_RECORDS:
            break
        try:
            r = json.loads(line)
        except Exception:                                        # noqa: BLE001
            continue
        role = _role(r)
        if role == "assistant":
            t = _text_of(r)
            if t.strip():
                parts.append(t)
        elif parts:
            break
    out = "\n".join(reversed(parts))
    return out[-TURN_LIMIT:] if len(out) > TURN_LIMIT else out


def jev_key() -> str | None:
    k = os.environ.get("JEV_API_KEY")
    if k:
        return k
    try:
        return json.load(open(f"{HOME}/.pi/agent/jev-config.json")).get("apiKey")
    except Exception:                                            # noqa: BLE001
        return None


def jev_choice(state: str) -> tuple[str | None, dict]:
    """One call, one typed schema. Returns (choice, meta). None => unreadable."""
    key = jev_key()
    if not key:
        log("ERR no JEV key — cannot classify (this is NOT a pass)")
        return None, {}
    req = urllib.request.Request(
        JEV_URL,
        data=json.dumps({"model": JEV_MODEL, "state": state,
                         "questions": TURN_QUESTION}).encode(),
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        log(f"ERR jev http {e.code}: {e.read().decode()[:200]}")
        return None, {}
    except Exception as e:                                       # noqa: BLE001
        log(f"ERR jev call failed: {e}")
        return None, {}
    ans = (d.get("answers") or {}).get("outcome") or {}
    if ans.get("type") != "choice":
        log(f"ERR jev returned no choice: {str(d)[:200]}")
        return None, {}
    choice = ans.get("choice")
    if choice not in OUTCOMES:
        log(f"ERR jev choice not recognised: {choice!r}")
        return None, {}
    return choice, {"confidence": ans.get("confidence"),
                    "cost_usd": (d.get("usage") or {}).get("cost_usd")}


def lanes_with_open_question() -> tuple[set, bool]:
    """Lane labels whose open issues carry a question. (labels, ok)

    `ok=False` means a surface could not be read — the caller must NOT treat that
    as "no questions". A failing query reading as an empty set is the exact
    silent-negative this fleet has hit four times.
    """
    out, ok = set(), True
    for repo in REPOS:
        for label in ("owner-decision", "question-bounced", "owner-answered"):
            rc, txt = sh(["gh", "issue", "list", "--repo", repo, "--state", "open",
                          "--label", label, "--limit", "100",
                          "--json", "number,labels"], timeout=90)
            if rc != 0:
                log(f"ERR question scan {repo} --label {label} rc={rc}")
                ok = False
                continue
            try:
                rows = json.loads(txt)
            except Exception:                                    # noqa: BLE001
                log(f"ERR question scan {repo} --label {label} was not JSON")
                ok = False
                continue
            for r in rows:
                names = [l["name"] for l in r.get("labels", [])]
                out.update(n for n in names if n.startswith("lane:"))
    return out, ok


def registry() -> list[dict]:
    rows = []
    try:
        with open(REGISTRY) as fh:
            for line in fh:
                if not line.strip() or line.startswith("#"):
                    continue
                parts = [p.strip() for p in line.rstrip("\n").split("\t")]
                if len(parts) < 2:
                    continue
                rows.append({"lane": parts[0], "ws": parts[1],
                             "issue_label": parts[2] if len(parts) > 2 else ""})
    except Exception as exc:                                     # noqa: BLE001
        log(f"ERR registry unreadable: {exc}")
    return rows


def session_file_for(sid: str | None) -> str | None:
    """Resolve a session id to its transcript. lane-status.py does not expose the
    path, so it is recovered from the session-dir name mangling: /a/b.c -> --a-b-c--."""
    if not sid:
        return None
    root = f"{HOME}/.pi/agent/sessions"
    try:
        for cand in os.listdir(root):
            d = f"{root}/{cand}"
            if not os.path.isdir(d):
                continue
            for fn in os.listdir(d):
                if sid in fn:
                    return f"{d}/{fn}"
    except Exception:                                            # noqa: BLE001
        pass
    return None


def marker_path(lane: str) -> str:
    return f"{MARK_DIR}/{hashlib.sha1(lane.encode()).hexdigest()[:12]}.json"


def read_marker(lane: str) -> dict:
    try:
        with open(marker_path(lane)) as fh:
            return json.load(fh)
    except Exception:                                            # noqa: BLE001
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
    except Exception as exc:                                     # noqa: BLE001
        log(f"ERR could not write marker for {lane}: {exc}")


def wait_for_landing(f: str, before_size: int | None) -> bool:
    """Did OUR text become part of the transcript? Both halves required."""
    deadline = time.time() + LAND_TIMEOUT_S
    while time.time() < deadline:
        try:
            if (before_size is None or os.path.getsize(f) > before_size) \
                    and SENTINEL in tail_text(f, LAND_TAIL_B):
                return True
        except Exception:                                        # noqa: BLE001
            pass
        time.sleep(LAND_POLL_S)
    return False


def lane_cwd(session_file: str) -> str | None:
    """The lane's own working directory. Every session file's FIRST record carries
    `cwd` (and `id`), so this needs no guessing."""
    try:
        with open(session_file) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except Exception:                                # noqa: BLE001
                    continue
                c = r.get("cwd")
                if c:
                    return c
    except Exception:                                            # noqa: BLE001
        pass
    return None


def live_nested_pi(lane_root: str | None) -> list[tuple[int, str]]:
    """Live `pi` processes running UNDER the lane's directory, excluding the lane.

    This is the signal `lane-status.py` structurally cannot see (agent-infra
    #1478): a lane that launches work as a DETACHED `nohup pi -p` process, or in a
    nested cmux workspace at `<lane root>/.worktrees/<x>/.worktrees/<y>`, leaves no
    pending `task` call in its transcript and no process ancestry back to it -- so
    it reads as DONE-IDLE while five workstreams are running.

    The lane DOES own a stable fact about them: they run under its own root. One
    `ps` census plus one `lsof` is enough, and it needs no new state.
    """
    if not lane_root:
        return []
    root = lane_root.rstrip("/") + "/"
    try:
        out = subprocess.run(["/bin/ps", "-axo", "pid=,comm="],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:                                            # noqa: BLE001
        return []
    pids = [l.split()[0] for l in out.splitlines()
            if len(l.split()) == 2 and l.split()[1] == "pi"]
    if not pids:
        return []
    try:
        lf = subprocess.run(["/usr/sbin/lsof", "-a", "-p", ",".join(pids),
                             "-d", "cwd", "-Fn"],
                            capture_output=True, text=True, timeout=60).stdout
    except Exception:                                            # noqa: BLE001
        return []
    found, cur = [], None
    for line in lf.splitlines():
        if line.startswith("p"):
            cur = line[1:].strip()
        elif line.startswith("n") and cur:
            path = line[1:]
            if path.startswith(root) and path != lane_root:
                found.append((int(cur), path))
            cur = None
    return found


def issue_line(label: str) -> str:
    if label:
        return (f"Your lane label is `{label}` — its open issues are\n"
                f"    gh issue list --state open --label {label} --limit 40")
    return ("This lane has no GitHub label; use the issue you were working on, "
            "named in your own last report.")


PROTOCOL_NUDGE = """[ORCHESTRATOR — automatic; no reply needed unless it changes what you do]

Your turn ended by asking the owner something, and nothing on your issue shows it
went through the decision protocol. **A question asked inside this pane reaches
nobody** — the owner reads questions only from the queue.

Route it now. On your issue, post ONE comment whose FIRST line is exactly:

    RESEARCH: skill=<yes|no> sources=<internal|web|perplexity|none> refs=<what you checked>

and then, after that line, the four parts, in this order:

    context      — enough background that someone who has not seen your work understands
    options      — distinct, named options
    analysis     — what each option costs, or forecloses
    recommendation — which one you recommend

**The contradiction test comes FIRST, before those**: name the recorded decision
you checked the options against, or state plainly that none applies. An owner
decision outranks a convergent standard — if one applies, it is not a question at
all.

**Ground it in the map.** The crisis overview is the Tortoise graph, entered via the graph comment
on #4844 — read it before you frame the options, and add what you learn.

Then run the gate, which is what puts it in the owner's queue:

    /usr/bin/python3 ~/.pi/agent/scripts/ask-owner.py daniel-ospina/tortoise <ISSUE-NUMBER>

Write it plainly: no internal shorthand, no codenames, enough context that a
non-developer can decide. If the gate bounces it, the bounce names what is missing
— re-post once, corrected.

**A question never stalls your lane.** Post it, then carry on with whatever else is
unblocked. Do not sit waiting for an answer.

%s
""" % issue_line("")


NO_PAUSE_NUDGE = """[ORCHESTRATOR — automatic; no reply needed unless it changes what you do]

Your turn ended with work still in progress and nothing blocking it. That is the
one thing AGENTS.md forbids outright: **never pause without a reason.**

"Ready?", "Proceed?", "Want me to…?", "Shall I…?", "Should I continue?", "On to the
next step?", "Does that look right?" are all questions whose answer is trivially
"yes". **The default is GO**, and you already have the user's authorisation — the
session is the authorisation.

**Continue the work now.**

The only three reasons to stop are:

  1. a skill explicitly mandates a human gate (sign-off, approval, decision point);
  2. P0 consequence risk — data loss, security, unrecoverable cost;
  3. genuinely ambiguous — research was inconclusive and you need a decision.

If it is (3), do not ask in this pane. Put it on your issue through the protocol —
one comment, first line `RESEARCH: skill=… sources=… refs=…`, then context,
options, analysis, recommendation, with the contradiction test first — and then
carry on with whatever is unblocked.

If none of the three applies, keep going. You can be interrupted if the owner
disagrees.

**If you are NOT mid-task, find the next work yourself — in priority order:**

  1. READ THE MAP FIRST: the overview of the CI-and-merge crisis is the Tortoise graph
     (`docker://:@127.0.0.1:16379/tortoise`), entered via the graph comment on #4844 — read it,
     then the priority stack.
  2. Take the highest-ranked item that is NOT already held. Ownership lives in the
     graph and in the open PRs/branches — never in what a pane claims.
  3. Verify it is free BEFORE starting: `python3 tools/collision_preflight.py <N>
     --repo .` must exit 0. Exit 1 = someone holds it, take the next item.
     Exit 2 = the check could not be completed — do not start on a guess.
  4. Claim it (assignee + a claim comment), then work it through to a PR.
  5. Write what you learned back into the graph as an `evidence` point carrying its
     NUMBER, wired to the cause it bears on (`supports` / `refutes` / `measures` /
     `blocks`). A finding that lives only in your context dies with your session.

**And while you work — PROCESS WEIGHT: make the judgement explicit, don't default either way.**
Our verification machinery has grown into the critical path (4.5h of literal sleep; 489 slow
tests holding 75%% of gate time; a 10-job AND charging every diff the full surface; an
unsharded 17.5-min carve-out), so bureaucracy is a real cost we are actively solving for. But
OVER-COMPENSATING is a failure too: deleting a check that prevents a real failure is not
eliminating bureaucracy, it is removing a guard rail. The target is the LEAST machinery that
makes the behaviour genuinely trustworthy. So for any non-product artifact you add or remove,
say in one line WHICH FAILURE it prevents or caused (point at it happening), and whether
deleting it tomorrow would harm the PRODUCT or only the PROCESS. A lopsided ratio of
tests/guards/config around a small change is a SMELL pointing at a missing seam - sometimes
genuinely earned, in which case one line saying why is enough.

%s
""" % issue_line("")


def objective_line() -> str:
    """The owner's objective + live state, read from objective.py's cache (ZERO API cost).

    objective.py self-caches for 900s and the heartbeat refreshes it, so every nudge reads
    the file for free. A nudge that names the objective is the difference between "go find
    work" and "go find work that drains the queue" -- and the state also tells the lane when
    MAIN IS RED, which is the one condition no lane can fix from inside its own worktree.

    The numbers in the state line are INDICATORS (queue depth, main health, CI critical
    path), not pass/fail targets: the owner's ruling (#6792) is that the objective is
    qualitative, and CI time in particular is a guideline. `waiting < 10` is the one real
    target, and it is the queue depth itself.
    """
    try:
        with open(os.path.expanduser("~/.pi/agent/state/objective.last")) as fh:
            for ln in fh:
                ln = ln.strip()
                if ln.startswith("OBJECTIVE "):
                    return ln
    except Exception:
        pass
    return ""


def main_red_directive() -> str:
    """Make a red main OVERRIDE the lane's own next step, not just appear in its nudge.

    Without this the nudge only INFORMS: a lane reads 'main=RED' and still works its own
    backlog, while nothing can merge. The measured cost of that on 2026-09-29 was hours
    of lane work that could not land. The hedge matters as much as the directive -- telling
    every idle lane to fix main would put five lanes on one file, so it explicitly defers
    to whoever already holds it.
    """
    if "VERDICT=BLOCKED" not in objective_line():
        return ""
    return (
        "\n⛔ MAIN IS RED — THIS OVERRIDES YOUR NORMAL NEXT STEP. Nothing can merge while the\n"
        "required gate is red on main, so the highest-leverage work in the fleet is the FIX, not\n"
        "your lane's own backlog. FIRST check whether it is already held: look for an open PR\n"
        "touching the failing job's files, and for a lane whose last message names it. If nobody\n"
        "holds it, that IS your next item — read the failing job log on the sha in CURRENT STATE\n"
        "above, name the failing test, and fix the cause. If it IS held, do NOT duplicate it;\n"
        "take the highest-ranked unheld item instead and say which lane holds the fix.\n"
        "If you hold IN-FLIGHT merge/batch probes cut against this red main (branches testing a\n"
        "group of PRs on the red base), PARK them: they cannot land while main is red, and their\n"
        "queued runs spend the runner capacity the fix's required checks are waiting for. Measured\n"
        "2026-09-29: two such probes held ~24 of ~20-25 available job slots while the one-line fix\n"
        "sat with four required checks QUEUED, so the probes starved the very fix that would have\n"
        "let them land. Re-cut them once main is green -- do not delete the work.\n"
    )


def gh_blocked_directive() -> str:
    """GitHub's REST API is refusing the WHOLE fleet -- redirect lanes, never let them retry.

    WHY THIS EXISTS (measured 2026-09-29 05:00 UTC): 27 lanes plus the orchestrator share ONE
    GitHub account, so all REST calls draw on one budget. The fleet hit GitHub's SECONDARY
    (burst) limit -- invisible in `gh api rate_limit`, which still reported core 5000/5000 --
    and every `gh` call began failing with "API rate limit exceeded for user ID 81560491".
    The trap is that a secondary limit is RESET by continued requests: my own retries at t+45s,
    +75s and +105s each kept it alive. So the directive must be explicit that retrying is the
    harm, and it must name what still works -- the git protocol is untouched (fetch, rebase,
    push, ls-remote all returned rc=0 while every gh call failed), which is exactly the work
    the conflict slices need. Without this, GH-BLOCKED reads as "cannot work" and the fleet
    both stalls AND hammers the limit it is waiting on.
    """
    if "gh=RATE-LIMITED" not in objective_line():
        return ""
    return (
        "\n\u26d4 GITHUB IS RATE-LIMITING THE WHOLE FLEET \u2014 DO NOT RETRY `gh` IN A LOOP.\n"
        "All lanes share one account, so the calls are ONE budget, and a tight retry RESETS the\n"
        "cooldown \u2014 retrying is the harm, not the wait. The GIT protocol is NOT affected: fetch,\n"
        "rebase, push and ls-remote all still work. So do LOCAL work while this lasts \u2014 rebase,\n"
        "resolve conflicts, run tests \u2014 and do not poll PR or check state. Only a LAND needs the\n"
        "API, and the API will be there when it is done.\n"
    )


NEXT_WORK_NUDGE = """[ORCHESTRATOR — automatic; no reply needed unless it changes what you do]
THE OBJECTIVE (owner ruling #6792): DRAIN THE PR BACKLOG — land all the good work without
discarding useful work — and have a merge system fast and safe enough that this does not recur.
CI speed is a KEY COMPONENT of that, not the objective: the <10min figure is a GUIDELINE, not a
pass/fail target, and it must not outrank draining the queue.
CURRENT STATE: """ + (objective_line() or "objective.py has not run yet; the heartbeat refreshes it") + main_red_directive() + gh_blocked_directive() + """
You ended cleanly with nothing left in your lane. Do NOT idle — and do not invent work either.

1. READ THE MAP: the CI-and-merge overview is the Tortoise graph
   (`docker://:@127.0.0.1:16379/tortoise`), entered via the graph comment on #4844 — read it
   first, then the PRIORITY STACK (restated on #6134).
   ⚠️ PIN THE IPv4 LOOPBACK: `localhost` resolves `::1` FIRST on this box and port 16379 has a
   SECOND, near-empty FalkorDB there, so `localhost:16379` silently reads/writes the wrong graph
   (tortoise #6666 — the P0 that looked like data loss). `127.0.0.1` is the canonical instance.
2. TAKE THE HIGHEST-RANKED ITEM NOBODY HOLDS. Ownership lives in the graph plus open PRs and
   branches, NEVER in what a pane claims — including yours. Read the ranking from the graph
   (step 1); do NOT trust any list written here. This brief once HARD-CODED one ("the three
   live streams right now", 11 issue numbers) and when it was finally checked 6 of the 11
   were already CLOSED or MERGED — including one that was not a CI issue at all. A stale list
   is worse than none: it sends a lane to dead work AND it contradicts step 1, which is the
   authority. So there is no list here by design. If you want one, read it from the graph.
3. COLLISION PRE-FLIGHT and it must exit 0: `python3 tools/collision_preflight.py <N> --repo .`
   exit 1 = someone holds it, take the next; exit 2 = unverified, do NOT start on a guess.
4. CLAIM IT: assignee plus a one-line claim comment. Then work it to a PR.
5. NURTURE THE MAP: write back every finding as a point carrying its NUMBER, wired to the cause it
   bears on; if it contradicts a node, wire refutes and supersede it. A finding left in your
   session dies with it, and the next lane re-derives it.

PROCESS WEIGHT — a nudge, not a rule: we want LESS bureaucracy, not more. Where a root-cause fix
makes process unnecessary, DELETING it is a good outcome — report the removal as a deliverable.
Do not over-correct: removing verification that prevents a real observed failure is not
simplification, it is removing a guard rail. Evidence decides, not the count.

If nothing is unheld and unblocked, say so in ONE line and stop.

%s
""" % issue_line("")


def build_message(kind: str, label: str) -> str:
    if kind == "question_no_protocol":
        body = PROTOCOL_NUDGE
    elif kind == "idle_next_work":
        body = NEXT_WORK_NUDGE
    else:
        body = NO_PAUSE_NUDGE
    return body.replace(issue_line(""), issue_line(label))


# ── THE SEND-BOUNDARY GUARD ───────────────────────────────────────────────────
# `idle_next_work` is the ONE nudge in this file that ASSERTS the lane has nothing
# in flight; every other kind queues a continuation to a lane we believe is working,
# where queueing is the intended behaviour. So only this kind must be re-verified.
#
# WHY A SECOND CHECK IS NEEDED AT ALL: `st` is a REAL `lane-status.py --json` read
# (line ~770), so the verdict is not a stored snapshot -- but that ONE read costs
# ~88s, and the loop then makes a JEV call per lane BEFORE it reaches the send. A
# lane's verdict is therefore minutes old by the time its own nudge fires, and the
# classifier's own warning applies: "a lane running a long tool call writes nothing
# until it returns", so a lane that started a test suite after the snapshot still
# reads DONE-IDLE. That is exactly the 2026-10-01 incident -- a lane ACTIVELY
# WORKING was sidetracked -- just through this door instead of the dispatcher's.
#
# The fix reuses the proven guard rather than adding a second idle heuristic: ONE
# implementation of "is this lane consumable right now", used by every door. On an
# unestablished answer it WITHHOLDS (exit != 0), and it writes no marker, so the lane
# is simply re-considered on the next tick -- a nudge is never worth a sidetrack.
def consumable_now(ws: str, lane: str) -> tuple[bool, str]:
    guard = os.environ.get(
        "TURN_CLASSIFY_GUARD",
        os.path.join(HOME, ".pi", "agent", "scripts", "lane-guard.py"),
    )
    if not os.path.exists(guard):
        return False, "guard absent (%s) -- refusing to assert idleness" % guard
    try:
        rc, out = sh([
            "/usr/bin/python3", guard,
            "--ws", ws, "--label", lane,
        ], timeout=90)
    except Exception as exc:                                     # noqa: BLE001
        return False, "guard failed: %s" % exc
    return rc == 0, " ".join((out or "").split())[:160]


def send(lane: str, ws: str, msg: str, f: str | None,
         before_size: int | None, dry: bool) -> str:
    if dry:
        return "WOULD-SEND"
    brief = f"/tmp/turn-classify-{os.getpid()}.txt"
    try:
        with open(brief, "w") as fh:
            fh.write(msg)
    except Exception as exc:                                     # noqa: BLE001
        log(f"ERR could not write brief for {lane}: {exc}")
        return "BRIEF-WRITE-FAILED"
    # ── DELIVERY MECHANISM ────────────────────────────────────────────────────
    # The dispatcher above is the WRONG instrument for a working lane, and this is
    # the third instance of the same defect (see `ask-owner.py`, fixed 2026-09-27).
    # `cmux_dispatch` verifies delivery by requiring the message to become the
    # pane's latest SUBMITTED message, which needs a FREE COMPOSER — so on a lane
    # that is mid-turn (i.e. every lane that is actually working) it waits out its
    # full 180s timeout and returns non-zero. A plain `cmux send` QUEUES, and pi
    # consumes it when the current turn ends, which is exactly the desired
    # behaviour for an auto-continue nudge.
    #
    # MEASURED 2026-09-27 21:55: the STALE-CHILD fix below correctly classified
    # `1 Capture` (stopped_with_work_left, conf 0.67) and `8 Hosted` (conf 0.86),
    # reported SENT-BUT-NOT-CONFIRMED for both, and NEITHER lane's transcript moved
    # (46 min / 277 min unchanged). The classification was right and the delivery
    # silently ate it.
    #
    # ⛔ ONE LINE ONLY: a newline in the payload IS Enter, so a multi-line message
    # would be submitted as several separate turns and arrive as fragments.
    flat = " ".join(msg.split())
    rc, out = sh(["cmux", "send", "--workspace", ws, flat + "\n"], timeout=45)
    landed = bool(f) and wait_for_landing(f, before_size)
    if landed and rc != 0:
        return "SENT (transcript confirms despite rc=%d)" % rc
    if landed:
        return "SENT"
    # ── rc == 0 IS SUCCESS: THE SEND QUEUED ───────────────────────────────────
    # `cmux send` returns 0 once the text is handed to the pane. A message sent to
    # a MID-TURN lane is QUEUED and consumed only when that turn ends -- which can
    # be many minutes after LAND_TIMEOUT_S (45s) expires. Requiring the transcript
    # to move inside that window conflates "not yet consumed" with "not
    # delivered", which is the SAME defect that made the dispatcher's composer
    # check useless (#5979). `turn-end.py` already gets this right; this caller was
    # simply never given the same fix.
    #
    # MEASURED 2026-09-28 05:58: this path reported SENT-BUT-NOT-CONFIRMED for
    # `1 Capture` -- a STOPPED lane holding P0 work -- while the identical send
    # from `turn-end.py` succeeded. The ASYMMETRY, not the timeout, was the bug.
    if rc == 0:
        return "QUEUED (rc=0; not yet consumed)"
    return "SENT-FAILED (rc=%d) %s" % (rc, " ".join(out.split())[:140])


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--lane", help="classify only this lane (testing)")
    ap.add_argument("--print-turn", action="store_true",
                    help="print the extracted turn text and exit")
    a = ap.parse_args(argv)

    if os.path.exists(KILL):
        log("SKIP kill file present")
        return 0
    if not a.dry_run:
        try:
            os.makedirs(STATE, exist_ok=True)
            lk = open(LOCK, "w")
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:                                        # noqa: BLE001
            log("SKIP lock held")
            return 0

    # A failing question scan must NOT read as "no questions" — it makes every
    # lane look like it never used the protocol, which would nudge healthy lanes.
    holds, scan_ok = lanes_with_open_question()
    if not scan_ok:
        log("SKIP question scan incomplete — refusing to classify (fail closed)")
        return 0
    if holds:
        log("protocol used (queued): " + ", ".join(sorted(holds)))

    rows = registry()
    if a.lane:
        rows = [r for r in rows if r["lane"] == a.lane]
    if not rows:
        log("no lanes to classify")
        return 0

    # One lane-status sample gives sid/size/verdict for every lane at once.
    rc, out = sh(["/usr/bin/python3", f"{SCRIPTS}/lane-status.py",
                  "--json", "--sample", "0"], timeout=180)
    if rc != 0:
        log(f"ERR lane-status rc={rc}")
        return 0
    try:
        live = {r["lane"]: r for r in json.loads(out)}
    except Exception:                                            # noqa: BLE001
        log("ERR lane-status was not JSON")
        return 0

    sent = 0
    for r in rows:
        lane = r["lane"]
        st = live.get(lane) or {}
        sid, size = st.get("sid"), st.get("size")
        f = st.get("file")

        # ⛔ A LANE WAITING ON A CHILD HAS NOT STOPPED. Measured on the first dry
        # run: `1 Capture`, `2a` and `2b` all read `stopped_with_work_left` while
        # each had a child in flight -- three messages that would have been wrong.
        # A turn that ends because the lane dispatched work and is waiting is the
        # healthy case, and the standing rule is explicit: do not message a lane
        # whose child is still writing. A *parked* child is the reaper's problem,
        # not a nudge's.
        if st.get("child"):
            cage = (st.get("child") or {}).get("age")
            # A LIVE child is bounded by the harness's own ~25-minute in-flight
            # limit. Past that bound the child is DEAD -- the harness killed it --
            # and its call simply never received a result, so the pending record
            # can never clear by itself. Measured 2026-09-27: lanes were skipped
            # with "child in flight (age 19258s / 20224s)" -- 5.4 and 5.6 HOURS --
            # which disabled auto-continue for every lane that had EVER dispatched
            # a child, and is why lanes sat quiet for 11-15 hours while this
            # classifier ran clean every 5 minutes. A dead child is not a wait.
            if cage is not None and cage > CHILD_LIVE_MAX_S:
                log(f"STALE-CHILD {lane}: child age {cage}s > {CHILD_LIVE_MAX_S}s -- the "
                    f"harness killed it, so the lane is STOPPED, not waiting; classifying")
            else:
                log(f"SKIP {lane}: child in flight (age {cage}s) -- not stopped")
                continue
        # The signal lane-status cannot see: work running UNDER this lane's own
        # directory, detached or in a nested workspace. Without this, a lane at
        # five concurrent workstreams reads `DONE-IDLE` and gets told to continue.
        #
        # SCOPED TO A LANE IN ITS OWN WORKTREE, because a prefix rule is only true
        # there. Measured: `4a` sits in the MAIN checkout and so "contains" 22 live
        # pi processes that belong to other lanes -- a lane does not own other
        # lanes' worktrees. A lane under `.../.worktrees/<x>` does own what is under
        # it (measured: `7 Instrumentation` -> 13 live pi, its five workstreams).
        #
        # RESIDUAL, stated rather than hidden: a lane that launches detached
        # children OUTSIDE its root stays invisible here. Measured: `3 Onboarding`
        # runs three `nohup pi -p` children in `/private/tmp/b3-*` and reports 0.
        # It declares them itself in `/tmp/b3-<issue>.pid`, which is the field a
        # future detector should read (agent-infra #1478) rather than infer.
        cwd = lane_cwd(f)
        if cwd and "/.worktrees/" in cwd:
            nested = live_nested_pi(cwd)
            if nested:
                log(f"SKIP {lane}: {len(nested)} live pi process(es) under its own "
                    f"root (nested/detached) -- not stopped")
                continue
        if st.get("verdict") in ("EMPTY", "UNBOUND"):
            # Not "the lane is dead" -- the pane provides no session binding, so
            # this lane cannot be attributed and therefore cannot be messaged.
            # Stated as unattributable so a live lane is never dismissed as absent.
            log(f"SKIP {lane}: session unattributable (no cmux resume binding)")
            continue
        # ── BUSY VERDICTS ARE DECIDED BY lane-status, NOT BY AN LLM ────────────
        # A lane mid-turn or mid-tool has not stopped, so spending a classifier call
        # to have it tell us so is pure waste -- and it is not merely waste, it is
        # MISINFORMATION. The decline is logged as `stopped_with_work_left at
        # confidence 0.4x -- unknown, not acting`, which reads in the log like a stuck
        # lane that needs rescue. Measured 2026-09-28: that exact line is why `4a` and
        # `8 Hosted` were reported as needing rescue when BOTH WERE WORKING -- 4a was
        # running a 10-minute `sleep 600` CI poll on PR #5287 (verdict LONG-TOOL), and
        # 8 Hosted was waiting on a LIVE VGATE child under
        # `.worktrees/fix/6144-required-set-sync` (verdict WAITING-CHILD, child 548s with
        # a writing transcript and a live pid). The verdict is authoritative for
        # liveness; the classifier is only needed for the turn's INTENT. Pay it only then.
        if (st.get("verdict") or "").upper() in ("WORKING", "LONG-TOOL"):
            log(f"SKIP {lane}: verdict {st.get('verdict')} -- busy, not stopped "
                f"(no classifier call)")
            continue
        if not f:
            f = session_file_for(sid)
        if not f or not os.path.exists(f):
            continue
        if not sid or size is None:
            continue

        m = read_marker(lane)

        # ── STRUCTURAL IDLE PATH ──────────────────────────────────────────────
        # A lane with NO work of its own is the lane best placed to pull the next item
        # from the shared priority stack, and that is a STRUCTURAL fact rather than a
        # reading of its prose: no WIP verdict, no LIVE child (the block above already
        # continued on one), no nested or detached pi under its own root (also above).
        # So it is deliberately NOT routed through Jev or MIN_CONFIDENCE.
        #
        # MEASURED 2026-09-28 14:26 -- the reason this path exists. Every idle lane was
        # classified `stopped_with_work_left` at confidence 0.39-0.51, below the 0.60
        # gate, so the nudger logged "unknown, not acting" and declined EVERY time.
        # #6160 was filed and then sat with no assignee and zero comments while three
        # lanes read DONE-IDLE. A structural fact routed through an LLM confidence gate
        # is a structural fact that gets dropped.
        #
        # SECOND, INDEPENDENT BLOCK on exactly those lanes: the claimed-turn skip below
        # examines a lane ONCE PER TURN. An idle lane produces no new turn, so once its
        # last turn was claimed (as a no-action `finished_the_work`) it was never looked
        # at again -- permanent silence by construction. This path therefore runs BEFORE
        # that skip and gates on TIME, not on turn identity.
        verdict = (st.get("verdict") or "").upper()
        if verdict in ("DONE-IDLE", "WIP-IDLE") and lane not in NEVER_NUDGE:
            # The cooldown must key on the last NEXT-WORK nudge, not on the last claim
            # of ANY kind. `m` is a single per-lane marker overwritten by every decision,
            # including a no-action one -- so keying on `m.last` alone suppressed the
            # nudge for a full hour from an unrelated event. Measured 2026-09-28 14:29:
            # `3 Onboarding` (DONE-IDLE) logged "next-work nudge within 3600s" on its
            # FIRST eligible tick, because a no-action claim minutes earlier had set the
            # marker. Gate on the verdict that means "we sent this lane to look for work".
            last_idle = int(m.get("last") or 0) if m.get("verdict") == "idle_next_work" else 0
            if time.time() - last_idle < IDLE_GAP_S:
                log(f"SKIP {lane}: {verdict}, next-work nudge within {IDLE_GAP_S}s")
                continue
            if a.dry_run:
                log(f"{lane}: {verdict} -> WOULD-SEND idle_next_work")
                continue
            if sent >= MAX_PER_TICK:
                log(f"CAP {MAX_PER_TICK}: {lane} deferred")
                break
            # RE-VERIFY AT THE SEND BOUNDARY: the verdict was sampled up to minutes
            # ago (the --json read is ~88s, then a JEV call per preceding lane).
            ok, why = consumable_now(r["ws"], lane)
            if not ok:
                log(f"{lane}: {verdict} -> WITHHELD at send boundary: {why}")
                continue                       # no marker: re-considered next tick
            msg = build_message("idle_next_work", r.get("issue_label") or "")
            result = send(lane, r["ws"], msg, f, size, False)
            after = os.path.getsize(f) if f and os.path.exists(f) else size
            write_marker(lane, sid=sid, size=after, last=int(time.time()),
                         verdict="idle_next_work", acted=True, result=result)
            log(f"{lane}: {verdict} -> idle_next_work :: {result}")
            sent += 1
            continue

        if m.get("sid") == sid and m.get("size") == size:
            continue                       # this exact turn is already claimed

        turn = last_turn_text(f)
        if a.print_turn:
            print(f"=== {lane} ({sid[:8]}) ===")
            print(turn[-1500:] if turn else "(no assistant text found)")
            continue
        if not turn.strip():
            log(f"NOTE {lane}: no assistant text in this turn — not claimed")
            continue

        choice, meta = jev_choice(
            f"Lane: {lane}\nIssue label: {r['issue_label'] or '(none)'}\n\n"
            f"--- the turn's final message ---\n{turn}"
        )
        if choice is None:
            # fail closed AND do not claim: turn-end.py's cruder nudge remains the
            # fallback, so a Jev outage degrades rather than going silent.
            log(f"{lane}: verdict unreadable — not claimed")
            continue

        used_protocol = r["issue_label"] in holds
        if choice == "asked_the_owner" and used_protocol:
            kind = None                    # owner's class 2 — no automation
        elif choice == "asked_the_owner":
            kind = "question_no_protocol"
        elif choice == "stopped_with_work_left":
            kind = "no_pause"
        elif choice == "finished_the_work":
            # A lane that ENDS CLEANLY is the lane best placed to pull the next item from
            # the shared priority stack. Leaving this as `kind = None` is why finished
            # lanes sat DONE-IDLE indefinitely while the graph held unclaimed work:
            # #6160 was filed and then sat with zero comments and no assignee, and three
            # lanes the heartbeat listed as DONE-IDLE never saw it.
            kind = "idle_next_work"
        else:
            kind = None                    # unclassified — no automation

        conf = meta.get("confidence")
        if kind and conf is not None and conf < MIN_CONFIDENCE:
            log(f"SKIP {lane}: {choice} at confidence {conf} < {MIN_CONFIDENCE} "
                f"-- unknown, not acting (not claimed, so this turn stays open)")
            continue
        if kind and sent >= MAX_PER_TICK:
            log(f"CAP {MAX_PER_TICK}: {lane} deferred")
            break

        # Claim the turn in BOTH cases. A "no action" decision must be recorded,
        # or turn-end.py would second-guess it with its cruder verdict.
        # A dry run claims NOTHING: claiming it would make the real pass skip this
        # turn, which is how a dry run silently disables the thing it is testing.
        if not kind:
            if not a.dry_run:
                write_marker(lane, sid=sid, size=size, last=int(time.time()),
                             verdict=choice, acted=False)
            log(f"{lane}: {choice} -> no action "
                f"(protocol={'yes' if used_protocol else 'no'}, conf={conf})")
            continue

        now = time.time()
        gap = IDLE_GAP_S if kind == "idle_next_work" else MIN_GAP_S
        if now - (m.get("last") or 0) < gap and m.get("verdict") == choice:
            log(f"SKIP {lane}: {kind} already sent recently")
            if not a.dry_run:
                write_marker(lane, sid=sid, size=size, last=m.get("last", now),
                             verdict=choice, acted=True)
            continue

        msg = build_message(kind, r["issue_label"])
        result = send(lane, r["ws"], msg, f, size, a.dry_run)
        after = os.path.getsize(f) if os.path.exists(f) else size
        if not a.dry_run:
            write_marker(lane, sid=sid, size=after, last=int(now),
                         verdict=choice, acted=True, result=result)
        log(f"{lane}: {choice} -> {kind} :: {result} "
            f"(conf={conf}, cost=${meta.get('cost_usd')})")
        sent += 1

    if sent == 0 and not a.print_turn:
        log("OK no lane needed a message")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
