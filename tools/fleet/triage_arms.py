#!/usr/bin/env python3
"""tools/fleet/triage_arms.py — the ARMS of the triage router (#4046), each proving its own effect.

`tools/fleet/triage.py` decides WHAT a waiting lane is. This module executes the decision, and its
whole reason for existing is one rule from the issue, made structural:

    ⛔ A `SENT` MARKER IS A CLAIM, NOT AN EFFECT.

Every arm therefore has to produce a `Proof` — a record of a reading taken FROM THE ARTIFACT after
the action, not a receipt for having asked. The artifact differs per arm and `triage.PROOFS` is the
table; an arm that cannot produce its artifact returns `verified=False` and says why, and the caller
must not record the lane as handled. That is the difference between "we typed 'continue'" and "the
lane's transcript grew inside the bound", and the fleet has already paid for the first being mistaken
for the second: `scripts/turn-end.py`'s own comment records two lanes whose nudge was reported SENT
while their transcripts did not move for 46 and 277 minutes.

WHY THE ARMS LIVE HERE AND NOT IN THE CLI
-----------------------------------------
So the end-to-end path can be driven by a FIXTURE. `Surface` is the only thing an arm may touch, and
the CLI supplies a real cmux implementation while the suite supplies a fake one. That is what lets
"a synthetic lane asks the owner a question, is routed to the question lane, and never receives
'continue'" be an assertion instead of a manual walkthrough.

THE QUESTION LANE (#4046 arm 1)
-------------------------------
Not a message and not a beat clause: a dedicated workspace in the cmux left-hand panel (index 0),
whose mandate is the `research` skill FIRST and then AGENTS.md's USER QUESTIONS PROTOCOL. The brief
this module composes is the mandate, and `QUESTION_MANDATE` is checked AT THE ARTIFACT — a question
forwarded raw has not been routed, it has been relayed.

Recorded decision honoured, not reversed: the owning lane **waits**. It is not nudged (the router
never emits `send-continue` for it) and not killed (no arm kills from unread evidence — see
`docs/ops/pi-idle-repl-reaper-policy.md`, "no proof ⇒ not idle ⇒ never kill").
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

from dataclasses import dataclass, field
from typing import Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import triage  # noqa: E402

# The workspace name the question lane carries. Deliberately a NAME and not an id: the lane is
# resolved by name so it survives cmux restarts, and created on first use.
QUESTION_LANE = "ask-owner"
QUESTION_LANE_INDEX = 0     # the cmux left-hand panel is index 0; `workspace move` is how it gets there

# ⛔ THE MANDATE IS CHECKED AT THE ARTIFACT, NOT ASSERTED HERE. These are the tokens the brief must
# carry for a question lane to be said to have received a ROUTED question rather than a relayed one.
# `research` first (a question asked before the research is one the lane could probably answer), then
# the four USER QUESTIONS PROTOCOL parts, then the contradiction test — which AGENTS.md puts FIRST.
QUESTION_MANDATE = (
    "RESEARCH FIRST",
    "CONTRADICTION TEST",
    "context",
    "options",
    "analysis",
    "recommendation",
)

# How long an idle lane has to prove it resumed. Deliberately a bound and not a guess: the point is
# that WITHOUT one, "sent" silently becomes "handled". 120 s is long enough for a pi turn to open
# (the first transcript write) and short enough that a lane which did not resume is escalated in the
# same pass rather than an hour later (`turn-classify.py`'s marker window is 3600 s — that window is
# what makes an unproven send read as BUSY, so the proof has to land inside a much smaller one).
RESUME_BOUND_S = 120.0


# ── the surface an arm may touch ────────────────────────────────────────────────────────────────
class Surface:
    """The cmux operations the arms need. The CLI implements it against `cmux`; the suite fakes it.

    A subclass must not invent behaviour: each method maps to one verb, and every failure to answer
    is `None`/`False` with a reason — never a default that reads as success.
    """

    def list_workspaces(self) -> Optional[list]:
        raise NotImplementedError

    def new_workspace(self, name: str) -> Optional[str]:
        raise NotImplementedError

    def move_workspace(self, ws: str, index: int) -> bool:
        raise NotImplementedError

    def send(self, ws: str, text: str) -> bool:
        raise NotImplementedError

    def transcript_size(self, ws: str) -> Optional[int]:
        raise NotImplementedError

    def screen_tail(self, ws: str, lines: int = 40) -> Optional[str]:
        raise NotImplementedError


@dataclass(frozen=True)
class Proof:
    """The reading an arm took at its artifact. `verified` is the only field a caller may act on."""

    action: str
    proof: str
    verified: bool
    detail: str = ""
    artifact: dict = field(default_factory=dict)
    sent: bool = False          # whether anything was typed — never a substitute for `verified`

    def as_dict(self) -> dict:
        return {"action": self.action, "proof": self.proof, "verified": self.verified,
                "detail": self.detail, "sent": self.sent, "artifact": self.artifact}


def _digest(text: str) -> str:
    return hashlib.sha256((text or "").encode("utf-8", "replace")).hexdigest()[:16]


# ── the question brief ──────────────────────────────────────────────────────────────────────────
def question_brief(lane: str, question: str, ws: str = "") -> str:
    """Compose the question-lane brief: the research mandate, the contradiction test, the four parts.

    One line per paragraph (a newline in a `cmux send` payload is a separate turn — the fleet's own
    recorded hazard), so this is a body the CLI can flatten without losing a section.
    """
    q = " ".join((question or "").split())
    return (
        "USER-QUESTION LANE — a lane is waiting on a decision, and you own getting it answered. "
        "Lane: %s%s. It is WAITING: do not tell it to continue, do not kill it, and do not count it "
        "as capacity. "
        "RESEARCH FIRST — mandatory, before the question reaches the owner: run the `research` skill. "
        "Internal first (this repo and its recorded decisions, the tracker, closed issues and PRs), "
        "external second. A question asked before the research is one the owning lane could probably "
        "answer itself. "
        "CONTRADICTION TEST FIRST, before anything else: name the recorded decision the options were "
        "checked against, or state plainly that none applies. An owner decision outranks a convergent "
        "standard — if one applies, it is not a question and the answer is to reopen that decision "
        "with evidence, not to ask. "
        "Then present it in the AGENTS.md USER QUESTIONS PROTOCOL shape, in this order: "
        "context (enough background that someone who has not seen the work understands) — "
        "options (distinct, named) — analysis (what each option costs, or forecloses) — "
        "recommendation (which one you recommend, and why). Plainly: no internal shorthand, no "
        "codenames. "
        "Then run the gate that puts it in the owner's queue: "
        "python3 ~/.pi/agent/scripts/ask-owner.py <owner>/<repo> <issue-number>. "
        "Finish by posting the ANSWERED decision back onto the waiting lane, so it can resume. "
        "The lane's own words: %s" % (lane, ("(%s)" % ws) if ws else "", q)
    )


def boot_brief(lane: str) -> str:
    """What a BOOT-PROMPT repair types: a resume line, never the question-lane mandate.

    ⛔ ONE PAYLOAD PER ROUTE (fresh-context review, #4046). The first version handed the
    `question_brief` to every arm, so repairing a boot-blocked pane TYPED THE QUESTION-LANE MANDATE
    into the lane being repaired — a lane that was never asked anything would have been ordered to run
    the research skill and raise a question with the owner. The two arms want opposite messages, so
    they get separate composers and a test pins that they differ.

    The original payload is genuinely lost (the boot prompt ate it), so this says what is true: pi
    booted, and the lane's own in-flight task stands.
    """
    return ("Lane %s — pi has finished booting and the send that was eaten by the boot prompt is gone. "
            "Continue the task already in flight; do not start a new one. If you were waiting on the "
            "owner, say so in one line and carry on with the part that is not blocked." % (lane,))


def payload_for(route, ev, ws: str = "") -> str:
    """The ONE payload a route's arm may type. Empty for the arms that type nothing at all.

    A single source so a route can never borrow another arm's message — the defect this function was
    extracted to remove, and the reason it is not inlined at the call site.
    """
    if route.action == "route-to-question-lane":
        return question_brief(ev.lane, ev.last_text, ws)
    if route.action == "repair-boot-prompt":
        return boot_brief(ev.lane)
    if route.action == "send-continue":
        return "continue"
    return ""


def mandate_missing(brief: str) -> list:
    """Which mandate tokens the brief does NOT carry. Empty list = the brief is routed, not relayed."""
    low = " ".join((brief or "").lower().split())
    return [tok for tok in QUESTION_MANDATE if tok.lower() not in low]


# ── arm 1: the user-question lane ──────────────────────────────────────────────────────────────
def arm_user_question(ws: str, lane: str, question: str, surface: Surface) -> Proof:
    """Route a waiting lane's question to the dedicated question lane, and prove it landed ROUTED.

    The proof is `question-lane-ack`, and it is taken at the artifact in three parts:
      1. the question lane EXISTS and sits at index 0 (the cmux left-hand panel);
      2. the brief the lane received carries the mandate — checked against the TEXT SENT, not against
         the text this function built (a transport that truncated it has not delivered the mandate);
      3. the owning lane received nothing from this arm. That is structural — `surface.send` is never
         called with the owning workspace in this arm — and the artifact records it, so a later
         change that "helpfully" nudges the owner lane is visible here rather than only in review.
    """
    brief = question_brief(lane, question, ws)
    missing = mandate_missing(brief)
    if missing:
        # Compose-time failure: never send a brief that cannot be shown to carry the mandate.
        return Proof("route-to-question-lane", triage.PROOFS["route-to-question-lane"], False,
                     "brief lacks mandate tokens: %s" % ", ".join(missing),
                     {"lane": lane, "owner_ws": ws, "mandate_missing": missing})

    spaces = surface.list_workspaces()
    if spaces is None:
        return Proof("route-to-question-lane", triage.PROOFS["route-to-question-lane"], False,
                     "could not list workspaces — a lane that cannot be resolved is not routed",
                     {"lane": lane, "owner_ws": ws})

    qws = None
    for sp in spaces:
        if (sp.get("name") or "") == QUESTION_LANE:
            qws = sp.get("id")
            break
    created = False
    if not qws:
        qws = surface.new_workspace(QUESTION_LANE)
        created = True
    if not qws:
        return Proof("route-to-question-lane", triage.PROOFS["route-to-question-lane"], False,
                     "could not resolve or create the question workspace %r" % QUESTION_LANE,
                     {"lane": lane, "owner_ws": ws})

    moved = surface.move_workspace(qws, QUESTION_LANE_INDEX)
    sent = surface.send(qws, brief)

    # (2) the mandate, read back at the artifact: the SENT text is what counts, and the surface
    # reports the text it typed (a transport that silently truncated is the #1187 class).
    # ⛔ THE RESIDUAL, STATED RATHER THAN IMPLIED (round 2, #4046 P2): this is a real read-back only for
    # a surface that records what it typed. `CmuxSurface.send` does (`last_sent`), so production takes
    # the honest path; a surface that keeps no record falls back to the composed brief, i.e. the check
    # degenerates to a self-check — which is why the surface is REQUIRED to record it and
    # `test_the_surface_records_what_it_typed` pins `CmuxSurface.send` to do so.
    sent_text = getattr(surface, "last_sent", {}).get(qws, brief)
    still_missing = mandate_missing(sent_text)
    verified = bool(sent and moved and not still_missing)
    reason = ("landed with the full mandate" if verified else
              "move failed" if not moved else
              "send failed" if not sent else
              "the text received lacks mandate tokens: %s" % ", ".join(still_missing))
    return Proof("route-to-question-lane", triage.PROOFS["route-to-question-lane"], verified, reason,
                 {"lane": lane, "owner_ws": ws, "question_ws": qws, "created": created,
                  "index": QUESTION_LANE_INDEX, "moved": moved, "sent": sent,
                  "brief_sha": _digest(brief), "mandate_missing": still_missing,
                  "owner_lane_sent_anything": False},
                 sent=sent)


# ── arm 2: idle-continue, with resumption proof ────────────────────────────────────────────────
def arm_continue(ws: str, lane: str, surface: Surface, bound_s: float = RESUME_BOUND_S,
                 poll=None) -> Proof:
    """Send `continue`, then PROVE the lane resumed: transcript growth inside the bound.

    ⛔ THE MARKER THIS REPLACES. `turn-classify.py` writes a marker on a send and `lane-status.py`
    reads it back as BUSY for an hour — so an unproven send makes a lane look handled for 3600 s.
    Here the reading is the lane's OWN transcript size before and after, and a lane that did not
    grow is escalated with the same evidence, in the SAME pass. "accepted" is not "advanced".
    """
    before = surface.transcript_size(ws)
    if before is None:
        # No baseline, no proof. Sending anyway would be the class this arm exists to remove.
        return Proof("send-continue", triage.PROOFS["send-continue"], False,
                     "no readable transcript before the send — a send could not be verified, so it "
                     "was not made", {"lane": lane, "ws": ws})
    sent = surface.send(ws, "continue")
    after = poll(ws, before, bound_s) if poll else surface.transcript_size(ws)
    grew = after is not None and after > before
    return Proof("send-continue", triage.PROOFS["send-continue"], bool(sent and grew),
                 ("transcript advanced %d -> %d bytes inside %ss" % (before, after, int(bound_s))
                  if grew else
                  "sent but the transcript did NOT advance inside %ss — escalate, do not mark BUSY"
                  % int(bound_s)),
                 {"lane": lane, "ws": ws, "before": before, "after": after}, sent=sent)


# ── arm 3: the wedged subcases ────────────────────────────────────────────────────────────────
def arm_boot_prompt(ws: str, lane: str, surface: Surface, dispatch) -> Proof:
    """The boot-prompt subcase: REUSE the dispatcher's own dismiss-and-resend, then read the pane.

    `cmux_dispatch.py` owns this repair (`R_DISMISS_RESEND` / `boot_blocked`) and its exit code is
    the delivery verdict. Re-deriving it here would be a second implementation of a 2,856-line
    tool's most delicate recovery, so `dispatch` is injected: it returns the dispatcher's exit
    status, and the PROOF is the pane no longer showing the prompt.
    """
    rc = dispatch(ws, lane)
    screen = surface.screen_tail(ws, 40)
    blocked = None if screen is None else ("press any key" in screen.lower()
                                           or "boot-block" in screen.lower())
    verified = bool(rc in (0, 4)) and blocked is False
    return Proof("repair-boot-prompt", triage.PROOFS["repair-boot-prompt"], verified,
                 ("dispatcher rc=%s and the prompt is gone" % (rc,)) if verified else
                 ("dispatcher rc=%s" % (rc,)) if blocked is None else
                 "the boot prompt is STILL on the pane",
                 {"lane": lane, "ws": ws, "dispatch_rc": rc, "boot_prompt": blocked},
                 # ⛔ `sent` IS A FACT, NOT A CONSTANT (round 2, #4046 P2). `3` is the dispatcher's
                 # REFUSED (nothing sent), so a hardcoded `True` made the record contradict its own
                 # detail — and `sent` is what a reader uses to tell "we tried" from "we did not".
                 sent=rc in (0, 4))


def arm_child(lane: str, child: dict) -> Proof:
    """The child subcases: name the child record and hand it to its own owner — never kill here.

    ⛔ THE KILL IS NOT THIS ARM'S. `lane-status.py`'s CHILD-STUCK is measured twice on record as a
    false positive (a merge rail, a nested-worktree child writing at 0.0m/0.1m), and the fleet's
    reaping rule is three gates plus *"report, do not reap"* when a read is unclear. So the remedy is
    a named hand-off: the child's own record, so `pi-done-not-exited.py` (the audited reaper) or the
    operator inherits a diagnosis instead of a mystery. The proof is that the record is READ and
    NAMED — an artifact, not an intention.

    ⛔ THE PRODUCER'S OWN KEY SET, NOT A GUESSED ONE (round 3, #4046 P1). `lane-status.py:1586-1590`
    emits `dict(call_id=…, ts=…, age=…, abandoned=…, cwd=…, task=…, agent=…)`. The first version read
    `pid` / `sid` / `name`, NONE of which the producer emits, so the arm answered "the child could not
    be named" 100% of the time on a record that DID name it — and its sibling path synthesised a name
    from the state word, which reported `verified=True` off `{'name': 'stuck'}`. `call_id` is the
    child's identity in the harness's own records, so it is the one that proves a record was READ.
    """
    # ⛔ ONLY THE KEYS THE PRODUCER ACTUALLY EMITS. `name` / `pid` / `sid` / `label` are NOT among
    # them, so accepting them left a false-PASS door open: measured after the round-3 fix,
    # `arm_child("L", {"name": "stuck"}).verified` was still `True` — the synthesis was gone from
    # `execute()`, but the arm would still certify a dict no producer can produce. The proof is that a
    # RECORD was read, so it must be keyed on a field only a real record carries.
    named = [k for k in ("call_id", "agent", "task") if (child or {}).get(k)]
    known = bool(named)
    who = ((child or {}).get("call_id") or (child or {}).get("agent") or (child or {}).get("task"))
    return Proof("repair-child", triage.PROOFS["repair-child"], known,
                 ("child record READ and handed over (%s; fields=%s) — this arm signals nothing"
                  % (who, ",".join(named))) if known else
                 "the child could not be named from the evidence — nothing to hand off, and no kill "
                 "is authorised on an unread child",
                 {"lane": lane, "child": dict(child or {}), "fields": named})


def arm_rerun(lane: str, ws: str, relaunch) -> Proof:
    """The rerun subcases: re-dispatch through `lane-relaunch.py`, whose EXIT CODE is the proof.

    `docs/ops/lane-recovery.md` records its verdicts — 0 CONFIRMED (sent AND the transcript advanced
    or a fresh session appeared), 3 REFUSED (a guard refused, nothing sent), 4 UNCONFIRMED (sent, the
    proof did not fire), 5 DRY-RUN. Reusing them is the point: this arm does not re-implement "did the
    lane come back", it reads the tool whose whole contract is that answer. A live-but-wedged lane
    will be REFUSED by that tool's own guards, and a refusal is a correct outcome here — the kill is
    not authorised from this evidence.
    """
    rc = relaunch(ws)
    verified = rc == 0
    why = {0: "CONFIRMED — the lane came back", 3: "REFUSED by lane-relaunch's own guard (nothing sent)",
           4: "UNCONFIRMED — sent, the proof did not fire", 5: "DRY-RUN — nothing sent",
           1: "ERROR — lane-relaunch raised"}.get(rc, "unrecognised exit %r" % (rc,))
    return Proof("rerun", triage.PROOFS["rerun"], verified, why,
                 {"lane": lane, "ws": ws, "relaunch_rc": rc}, sent=rc in (0, 4))


def arm_reading(action: str, reason: str, extra: Optional[dict] = None) -> Proof:
    """`wait` / `inspect` / `refuse` / `none` — nothing is executed, and the READING is the artifact.

    These are not "no-ops": each one owes a written reason, because a withheld arm that reads as
    "nothing to do" is how a lane sits un-nudged and unheard. `verified` is True when the reading was
    produced — it never asserts anything about the lane.
    """
    ok = bool((reason or "").strip())
    return Proof(action, triage.PROOFS.get(action, "written-reading"), ok,
                 (reason or "NO REASON GIVEN — a withheld arm must say why"),
                 dict(extra or {}))


def execute(route, ev, surface: Surface, *, ws: str = "", dispatch=None, relaunch=None,
            poll=None, bound_s: float = RESUME_BOUND_S, child: Optional[dict] = None) -> Proof:
    """Dispatch one Route to its arm. Total over `triage.REMEDIES` + the router's own actions."""
    if not route.complete:
        return arm_reading("refuse", "route is not executable: route=%r action=%r proof=%r"
                           % (route.route, route.action, route.proof))
    action = route.action
    if action == "route-to-question-lane":
        return arm_user_question(ws, ev.lane, ev.last_text, surface)
    if action == "send-continue":
        return arm_continue(ws, ev.lane, surface, bound_s=bound_s, poll=poll)
    if action == "repair-boot-prompt":
        return arm_boot_prompt(ws, ev.lane, surface, dispatch)
    if action == "repair-child":
        # ⛔ A STATE WORD IS NOT A CHILD RECORD (round 3, #4046 P1). This branch used to synthesise
        # `{"name": ev.child_state}` when the caller had no record, which made the arm report
        # `verified=True` off the literal string `'stuck'` — a false PASS on a proof (`child-record`)
        # that was never read. An absent record is now absent: the arm says so, and verification
        # requires a field the producer actually emits.
        return arm_child(ev.lane, child or {})
    if action == "rerun":
        return arm_rerun(ev.lane, ws, relaunch)
    return arm_reading(action, route.reason,
                       {"lane": ev.lane, "route": route.route, "subcase": route.subcase})


def record_path(state_dir: str, lane: str) -> str:
    safe = "".join(c if (c.isalnum() or c in "-_.") else "_" for c in (lane or "?"))
    return os.path.join(state_dir, "lane-route", safe + ".json")


def write_record(state_dir: str, lane: str, route, proof: Proof) -> str:
    """Durably record the decision AND the proof. Append-free: one file per lane, newest wins.

    The record carries `verified` so a reader can never mistake a send for an effect — the same
    distinction `liveness.py` draws between an answer and an abstention.
    """
    path = record_path(state_dir, lane)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    row = {"lane": lane, "route": route.route, "subcase": route.subcase,
           "action": route.action, "proof": route.proof, "reason": route.reason,
           "result": proof.as_dict()}
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(row, fh, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
    return path
