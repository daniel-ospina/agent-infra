#!/usr/bin/env python3
"""cmux payload-integrity helper for lane dispatch (#1187).

WHY THIS EXISTS
---------------
`cmux send` types a payload into a recipient TUI's pty and returns `OK` without
certifying how much of it arrived. Measured 2026-09-29 and recorded on #1187:

  * a 1,962-byte message arrived as **only its first sentence**;
  * a 1,404-byte message arrived **only through its first numbered item**;
  * **a 5,464-byte message arrived COMPLETE.**

All three returned `OK`. Length is therefore NOT the cause — the sender cannot
infer delivery from the payload size, from `cmux`'s exit code, or from a turn
having started (a truncated prefix starts a turn too). The defect class is the
one #1187 names: *a success signal that does not certify the thing it is read as
certifying.* An 8-byte `/reload` that vanished entirely (same issue, same week)
shows the loss is not even limited to truncation.

THE RULE THIS ENFORCES
----------------------
The **tail** is what a prefix truncation loses, so the tail is the thing to look
for. But a tail that is VISIBLE is not a tail that was SUBMITTED: the pane renders
the composer's content, typed or delivered alike. So there are **four** verdicts
(`VERIFIED`, `PANE_ONLY`, `UNVERIFIED`, `SUBMIT_FAILED` — the last added when a
raised Enter turned out to need its own remedy), and only one of them is a
delivery verdict:

  * `VERIFIED`    — the payload's tail was appended to the lane's **session
transcript** after the pre-send baseline. The transcript is where a submitted
message is durably written, so it is the only source that certifies the ACT.
  * `PANE_ONLY`   — the tail is visible on the surface but no SUBMISSION evidence
was found: the transcript shows no such message after this send, or no transcript
could be consulted at all (no session binding, or a file that never appeared).
That is the composer state (a dropped Enter, or an earlier message with the same
body). **NOT a delivery verdict.**
  * `UNVERIFIED`  — no tail anywhere: a truncated prefix, an empty payload, or a
surface we could not read.
  * `SUBMIT_FAILED` — the terminating Enter FAILED (it raised, or `cmux` exited non-zero), so
submission was never attempted; distinct from `PANE_ONLY` because the remedy differs (submit in
that pane; do NOT re-send).

Neither `PANE_ONLY` nor `UNVERIFIED` nor `SUBMIT_FAILED` may ever be reported to a
caller as a delivered order. The check is deliberately fail-closed: a false
`UNVERIFIED` costs a re-read, a false `VERIFIED` is how a lane ends up running a
fragment of its brief (the measured failure on #1187).

WHITESPACE INSENSITIVITY
------------------------
A long line is wrapped by the TUI at a column boundary and rendered by
`cmux read-screen` with the break rendered as a newline, a space, or nothing at
all depending on the surface. The marker and the screen are therefore compared
with ALL whitespace removed, so a wrap inside the tail cannot manufacture a
false `UNVERIFIED`.

NOT THE ROOT FIX
----------------
The byte loss happens inside cmux's own pty write (`cmux-tui`'s
`terminal write`, reached from `/usr/local/libexec/cmux-cloud-adapter`), which
lives outside this repo — see #1187. This helper is the caller-side half the
issue asks for: make the loss *visible* instead of returning `OK` over a prefix.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

_WS_RE = re.compile(r"\s+")

DEFAULT_TAIL_CHARS = 80
DEFAULT_SCREEN_LINES = 200
# ⛔ 90 s, NOT 30 (#1881 review P2). The transcript is not written synchronously: `ask-owner.py`
# measured a send at T landing at **T+53 s** on an ~18 MB session and concluded 45 s was too short,
# which is why its `LAND_TIMEOUT_S` is 90 and `turn-end.py`/`turn-classify.py` use 45. A 30 s window
# answered the same question about the SAME file with less patience than the code that measured it,
# so a send that did arrive was reported "SENT BUT NOT SUBMITTED" — a verdict whose remedy invites
# the operator to re-send, i.e. to duplicate an order that had already arrived.
DEFAULT_VERIFY_TIMEOUT_S = 90.0
DEFAULT_POLL_S = 3.0

VERIFIED = "VERIFIED"
UNVERIFIED = "UNVERIFIED"
# ⛔ A THIRD VERDICT, because two could not express three states (#1881 review P0). The pane shows
# the composer's CONTENT, submitted or not: a payload typed into the lane's input box and never
# submitted renders its tail exactly like a delivered message. Reporting that as VERIFIED is the
# false pass this module exists to prevent, so "the tail is visible but submission is not proven"
# gets its own loud name instead of being folded into either neighbour.
PANE_ONLY = "PANE_ONLY"
# The terminating Enter itself FAILED, so submission was never attempted. Distinct from PANE_ONLY: a
# pane-only send may have been submitted and merely not yet flushed, while this one demonstrably was
# not — and the remedy is "press Enter in that pane", never "re-send" (#1881 review P2).
SUBMIT_FAILED = "SUBMIT_FAILED"


def flatten(text: str) -> str:
    """Collapse every whitespace run to a single space.

    A newline in a `cmux send` payload is an Enter, so a multi-line payload is
    submitted one line at a time and arrives as FRAGMENTS (#1799) — each line its
    own independent chance at the #1187 loss, while the tail marker can only ever
    certify the LAST one. So `verify` FLATTENS before it sends (see `_main`): one
    message, one submission, one thing to verify. This is the same normalisation
    the lane nudge paths already apply.
    """
    return " ".join((text or "").split())


def compact(text: str) -> str:
    """Text with ALL whitespace removed, for wrap-tolerant comparison."""
    return _WS_RE.sub("", text or "")


def tail_marker(text: str, tail_chars: int = DEFAULT_TAIL_CHARS) -> str:
    """The last `tail_chars` non-whitespace characters of `text`.

    Whitespace-stripped so that a line wrap inside the marker does not break the
    match. Returns the empty string for an empty payload (nothing to verify).
    """
    compacted = compact(text)
    if not compacted or tail_chars <= 0:
        return ""
    return compacted[-tail_chars:]


# ⛔ A SHORT MARKER IS A WHOLE VALUE, NOT A SUBSTRING (#1881 review, rounds 4 and 5). `tail_marker`
# returns the WHOLE compacted payload when it is shorter than `tail_chars`, and the comparison used to
# be a bare `marker in compact(...)`. So a payload of `ok` was certified by any appended text that
# contained it — the lane writing "checking the token now" made "token" certify it, a truncated
# `Retry` was certified by `Retrying…`, and a boundary-only rule was still fooled by the lane's own
# prose (`ok` by "ok, moving on to the tests"; `continue` by "I will continue with the next item").
# The docstring's own defect class includes an 8-byte payload that vanished entirely, so short
# payloads are in scope. Below this length the marker must EQUAL a whole candidate value — the message
# IS the value — never sit inside a longer text.
#
# ⛔ AND IT MUST NOT GO THE OTHER WAY EITHER (#1881 review, round 5 P1). A boundary test run against
# WHITESPACE-PRESERVING text could never match a whitespace-STRIPPED marker with an internal space,
# so `resume it` / `do it now` / `check pane` became permanently unverifiable: every short multi-word
# order would be reported not-confirmed, with a remedy that invites a re-send of an order that
# arrived. Equality in the COMPACTED domain fixes both directions at once — the whitespace is gone
# from both sides, so the same rule cannot manufacture a false PASS or a false FAIL.
MIN_WHOLE_VALUE_MARKER = 16


def _marker_matches(text: str | None, marker: str) -> bool:
    """Whether `marker` identifies a WHOLE value in `text` (short) or a run inside it (long).

    Long markers (>= MIN_WHOLE_VALUE_MARKER) are a whitespace-insensitive substring: a TUI wrap must
    not manufacture a false negative, and 16+ characters of a payload are not something a lane's
    unrelated output contains by accident. Short markers must equal the whole candidate, because a
    shorter string is a common word and any `in` / boundary test over prose certifies it.
    """
    if not marker or not text:
        return False
    if len(marker) >= MIN_WHOLE_VALUE_MARKER:
        return marker in compact(text)
    return compact(text) == marker


def screen_has_payload(screen: str | None, sent_text: str,
                       tail_chars: int = DEFAULT_TAIL_CHARS) -> bool:
    """True iff the payload's tail marker appears on `screen`.

    Fail-closed: an empty payload, an empty marker, or an unreadable screen is
    NOT a positive match.
    """
    marker = tail_marker(sent_text, tail_chars)
    if not marker:
        return False
    return _marker_matches(screen, marker)


def resolve_session_id(workspace: str, run) -> str | None:
    """The pane's bound session id, or None when the pane does not NAME one.

    ⛔ SPLIT FROM THE FILE LOOKUP (#1881 review P1). `resolve_session_file` used to answer None for
    three different things — cmux errored, the pane printed no id YET, and the id is known but no
    file exists for it — and the send loop treated all three as "the file did not exist when the send
    began", so it reopened the transcript search at offset 0. For the first two that window is the
    last 2 MB of a transcript that may hold DAYS of history, so an earlier message with a matching
    body certified a send whose tail was never submitted: the occurrence-identity false pass,
    reopened by the fix that closed it. "No id" and "no file for that id" are different facts and
    only the second one can establish that a file appearing later was written by this send.
    """
    try:
        proc = run(["cmux", "surface", "resume", "show", "--workspace", workspace],
                   timeout=45)
        out = getattr(proc, "stdout", "") or ""
    except Exception:                                          # noqa: BLE001
        return None
    for tok in out.replace("'", " ").split():
        if len(tok) == 36 and tok.count("-") == 4:
            return tok
    return None


def session_file_hits(session_id: str | None) -> list[str]:
    """Every transcript path that exists for a KNOWN session id (glob only — no stat).

    ⛔ "NO FILE EXISTS" AND "NO FILE COULD BE NAMED" ARE DIFFERENT FACTS (#1881 review, round 4 P1).
    `session_file_for` answers None for both, and the send loop used that None as proof that the
    transcript did not exist before the send — so one transient `getmtime` error on a pre-existing
    18 MB transcript reopened the search at offset 0 and let a days-old identical message certify a
    send that appended nothing.

    ⛔ AND NEITHER IS "I COULD NOT LOOK" (#1881 review, round 5 P2). `glob.glob` swallows OSError
    and returns [], so an unreadable directory read exactly like an empty one; `session_files_state`
    is the read that answers existence, and it reports unreadability instead of a convenient [].
    """
    if not session_id:
        return []
    home = os.path.expanduser("~")
    return glob.glob(f"{home}/.pi/agent/sessions/*/*{session_id}*.jsonl")


def session_files_state(session_id: str | None) -> bool | None:
    """Whether any transcript EXISTS for a known session id: True / False / None (unreadable).

    ⛔ THIS IS THE ONLY READ THAT MAY LICENSE OFFSET 0, SO IT MUST NOT FAIL OPEN (#1881 review,
    round 5 P2). A glob cannot tell "no match" from "the directory could not be read", and the two
    baseline reads used to be the same glob back-to-back — so one short filesystem stall covered
    both, "no file" was inferred, and the search reopened at offset 0 over a pre-existing transcript.
    An existence read that ERRORED is `None` here, and `None` never licenses the 2 MB window.
    """
    if not session_id:
        return False
    root = os.path.join(os.path.expanduser("~"), ".pi", "agent", "sessions")
    try:
        with os.scandir(root) as it:
            project_dirs = [entry.path for entry in it if entry.is_dir()]
    except OSError:
        return None
    unknown = False
    for directory in project_dirs:
        try:
            with os.scandir(directory) as it:
                for entry in it:
                    if session_id in entry.name and entry.name.endswith(".jsonl"):
                        return True
        except OSError:
            unknown = True                     # a directory we cannot read could hold it
    return None if unknown else False


def session_file_for(session_id: str | None) -> str | None:
    """The newest transcript for a KNOWN session id, or None when none can be NAMED.

    None means "no path I can vouch for" — no file exists, or the stat failed, or the glob failed.
    Callers that need to distinguish existence must ask `session_files_state`.

    Takes the id rather than the workspace on purpose: the caller resolves the id ONCE, before the
    send, so a later lookup can only answer "does the file exist now", never "is this a different
    session".
    """
    hits = session_file_hits(session_id)
    if not hits:
        return None
    try:
        # ⛔ THE STAT IS INSIDE THE GUARD (#1881 review P2). A session file can vanish between the
        # glob and the stat (a reaped session, a pruned worktree), and outside the try that OSError
        # escaped this function, escaped `send_verified`, and killed the helper BEFORE the verdict
        # was printed — so the caller saw an empty stdout and reported "SENT BUT NOT VERIFIED" for a
        # send that may well have landed. A file we cannot stat is a file we cannot name.
        return max(hits, key=os.path.getmtime)
    except OSError:
        return None


def resolve_session_file(workspace: str, run) -> str | None:
    """The recipient lane's live session `.jsonl`, resolved from the PANE.

    Best-effort second source for delivery evidence (the transcript is where a
    submitted message is durably written). Returns None when the pane has no
    session binding — never guess a file. Mirrors `ask-owner.py`'s
    `lane_session_file`.
    """
    return session_file_for(resolve_session_id(workspace, run))



def _json_strings(node) -> list[str]:
    """Every string value inside a decoded JSON value, at any depth."""
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        out: list[str] = []
        for key, value in node.items():
            out.extend(_json_strings(value))
        return out
    if isinstance(node, (list, tuple)):
        out = []
        for value in node:
            out.extend(_json_strings(value))
        return out
    return []


def _json_strings_of(line: str) -> list[str]:
    """Every string value in one JSONL record, or [] when the line is not JSON."""
    s = (line or "").strip()
    if not s or s[0] not in "{[\"":
        return []
    try:
        return _json_strings(json.loads(s))
    except Exception:                                          # noqa: BLE001
        return []


def transcript_has_payload(path: str, sent_text: str,
                           tail_chars: int = DEFAULT_TAIL_CHARS,
                           tail_bytes: int = 2_000_000,
                           since_offset: int | None = None) -> bool:
    """True iff the payload's tail marker appears in the session transcript.

    Reads only the tail of the file: a session `.jsonl` can be tens of MB.

    ⛔ THE TRANSCRIPT IS JSONL, SO THE MARKER IS COMPARED AGAINST DECODED TEXT (#1881 review
    P1/P2). A raw-byte comparison of a marker containing `"` or `\\` can NEVER match: inside a JSON
    string a quote is written `\\"`, so the branch is unreachable for any payload whose tail quotes
    something — which is the shape `orch-send.sh`'s own header recommends (`@file`). Each appended
    line is therefore also parsed and compared as its decoded string values, and the raw bytes are
    kept as a candidate so a plain-text transcript still matches.

    ⛔ `since_offset` IS THE POINT (#1881 review P1). Without it this function answered "is the marker
    anywhere in the last 2 MB", which on a live lane can span DAYS — so an earlier message with the
    same body (a standing order, a nudge, the retry that `orch-send.sh 165` tells the operator to
    send) certifies a LATER, truncated send. The caller records the transcript's size BEFORE sending
    and passes it here, so only bytes APPENDED BY THIS SEND can match. Omitting it keeps the old
    behaviour for a caller that has no pre-send reading — which is weaker, not stronger, and says so.
    """
    marker = tail_marker(sent_text, tail_chars)
    if not marker:
        return False
    try:
        size = os.path.getsize(path)
        start = max(0, size - tail_bytes)
        if since_offset is not None:
            if size < since_offset:
                # The transcript rolled/truncated between the two readings, so the positions are
                # not comparable. Fail CLOSED: a rewrite means this send's bytes cannot be located.
                return False
            start = max(start, since_offset)
        with open(path, "rb") as fh:
            fh.seek(start)
            chunk = fh.read().decode("utf-8", "replace")
    except Exception:                                          # noqa: BLE001
        return False
    if _marker_matches(chunk, marker):
        return True
    # Decode the JSONL records the send appended. A fragment at either edge of the window may not
    # parse; that is fine, a partial line can only ever ADD candidates, never remove one.
    # ⛔ EACH STRING VALUE IS ITS OWN CANDIDATE — NEVER A JOINED ONE (#1881 review, round 5 P1). The
    # joined form (`"\n".join(...)`) is a SUPERSET of the record's fields, so a substring rule on it
    # matched ACROSS two unrelated fields: `{"content":"so we should check","note":"the pane first"}`
    # certified the payload `check the pane first`, which the lane never sent. A whole-value rule on
    # the join can never match at all, so the join was wrong in both directions and is gone. Each
    # string value is offered separately, which is what a message actually is.
    candidates = [chunk, *chunk.splitlines()]
    for line in chunk.splitlines():
        candidates.extend(_json_strings_of(line))
    return any(_marker_matches(candidate, marker) for candidate in candidates)


def transcript_offset(path: str | None) -> int | None:
    """The transcript's size right now, or None — the pre-send baseline for `since_offset`."""
    if not path:
        return None
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def _default_run(argv, timeout=45):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def send_verified(workspace: str, text: str, *, run=None, sleep=time.sleep,
                  tail_chars: int = DEFAULT_TAIL_CHARS,
                  screen_lines: int = DEFAULT_SCREEN_LINES,
                  timeout_s: float = DEFAULT_VERIFY_TIMEOUT_S,
                  poll_s: float = DEFAULT_POLL_S) -> tuple[str, str]:
    """Send `text` to `workspace`, then verify its tail on the pane.

    Returns ``(VERIFIED|PANE_ONLY|SUBMIT_FAILED|UNVERIFIED, last_screen)``. Never raises on a clean
    send failure — a non-zero `cmux` exit or an unreadable surface folds into
    ``UNVERIFIED``, which is the loud verdict the caller must surface.

    ``VERIFIED`` requires SUBMISSION evidence (the tail marker appended to the lane's transcript after
    the pre-send baseline). ``PANE_ONLY`` means the tail is visible on the surface but nothing proves
    it was submitted — a pane that still shows an earlier message with the same body, or a transcript
    that could not be consulted. It is NOT a delivery verdict, and a caller that treats it as one
    re-opens #1187. ``SUBMIT_FAILED`` means the terminating Enter failed (it raised, or `cmux` exited
    non-zero): submission was never attempted, and the remedy is to submit in that pane, never to
    re-send. A non-zero exit from the PAYLOAD send itself folds into ``UNVERIFIED`` — nothing was
    typed, so there is no submission to reason about.

    `run` and `sleep` are seams so the send/verify loop can be exercised without
    a live cmux.
    """
    run = run or _default_run

    def cmux(*args):
        return run(["cmux", *args], timeout=45)

    # ⛔ THE TRANSCRIPT BASELINE IS TAKEN BEFORE THE SEND (#1881 review P1). Resolving it afterwards
    # would leave the size AFTER the bytes we are trying to attribute, so `since_offset` could only
    # certify nothing. This is the one read that must precede the act it observes.
    #
    # ⛔ AND "THE FILE WAS NOT THERE" IS A FACT, NOT AN ABSENCE (#1881 review P1). The id is resolved
    # ONCE, here; a file that does not exist for a KNOWN id, and appears after the send, was written
    # by this send (or later) — only that case may reopen the search at offset 0. An id this read
    # could not obtain says nothing about whether a transcript existed, so it must never license the
    # 2 MB window: without a baseline the verdict stays below VERIFIED (PANE_ONLY at best).
    session_id = resolve_session_id(workspace, run)
    # ⛔ EXISTENCE IS A READ, NOT AN INFERENCE (#1881 review, rounds 4 and 5): `session_file_for`
    # answers None for "no file", "stat failed" AND "could not look", and only the FIRST of those may
    # reopen the search at offset 0. `session_files_state` reports unreadability as None, which never
    # licenses the 2 MB window.
    session_had_file = session_files_state(session_id)
    session_file = session_file_for(session_id)
    session_base = transcript_offset(session_file)
    may_await_new_file = bool(session_id) and session_had_file is False

    try:
        sent = cmux("send", "--workspace", workspace, text)
    except Exception:                                          # noqa: BLE001
        return UNVERIFIED, ""
    # ⛔ A NON-ZERO `cmux` EXIT IS NOT A SEND (#1881 review P2). `_default_run` does not raise on a
    # non-zero status, so the module's own docstring ("a non-zero `cmux` exit … folds into
    # UNVERIFIED") described a branch that did not exist: the payload send's status was never read,
    # and the Enter's was not either. A status we cannot read (None) is treated as non-zero-safe:
    # only an explicit 0 passes.
    if getattr(sent, "returncode", 0) != 0:
        return UNVERIFIED, ""

    sleep(2)
    entered = True
    try:
        # The terminating Enter. Sent as its own call so a payload that itself
        # ends in a newline does not submit the message twice.
        enter = cmux("send", "--workspace", workspace, "\n")
        # ⛔ A NON-ZERO EXIT FROM THE ENTER IS A DROPPED ENTER (#1881 review P2). Only the raised
        # case used to clear `entered`, so a `cmux` that exited 2 instead of raising left the flag
        # True and the verdict PANE_ONLY — whose remedy is the re-send this flag exists to forbid.
        if getattr(enter, "returncode", 0) != 0:
            entered = False
    except Exception:                                          # noqa: BLE001
        # ⛔ AN ENTER THAT DID NOT HAPPEN IS NOT A DETAIL (#1881 review P0). This used to be
        # swallowed, and the loop below then found the payload ON THE PANE — the composer renders
        # its content whether or not it was submitted — and returned VERIFIED. The lane never got
        # the order and the orchestrator recorded it delivered: the exact false pass this module
        # exists to prevent. Record the failure and let it decide the verdict.
        #
        # ⛔ AND IT MUST ACTUALLY DECIDE SOMETHING (#1881 review P2). This flag decides the final
        # verdict — but only THIS arm used to clear it, so a `cmux` that exited non-zero (rather
        # than raising) left it True. The stale claim that it was "assigned and never read" is
        # corrected here: the residual defect was the missing non-zero arm above, and the pin in
        # the suite predates this round (it fails on the FIRST pre-fix bytes, not on round 3).
        entered = False
    sleep(2)

    deadline = time.monotonic() + timeout_s
    screen = ""
    saw_tail = False
    while True:
        try:
            proc = cmux("read-screen", "--workspace", workspace,
                        "--lines", str(screen_lines))
            screen = getattr(proc, "stdout", "") or ""
        except Exception:                                      # noqa: BLE001
            screen = ""
        if screen_has_payload(screen, text, tail_chars):
            saw_tail = True
        # ⛔ A TRANSCRIPT THAT DID NOT EXIST BEFORE THE SEND CAN STILL BE THE ONE THIS SEND WROTE
        # (#1881 review P2). pi creates the session file on the first user message, so resolving the
        # path only BEFORE the send made VERIFIED unreachable for a lane whose transcript this very
        # send created — a permanent PANE_ONLY. Re-open ONLY for the sound case: the pane named a
        # session id BEFORE the send and that id had no file yet, so every byte in a file that
        # appears now is this send's or later (baseline 0). The id is NOT re-resolved: a newly
        # appearing id could be a different session, and offset 0 there would search its history.
        if may_await_new_file and session_file is None:
            session_file = session_file_for(session_id)
            if session_file:
                session_base = 0
        # SUBMISSION EVIDENCE, in order of strength. The transcript is where a submitted message is
        # durably written, so it is the only source that can certify the act; the pane can only show
        # that the text reached the composer. Checking the pane FIRST (as this did) let the weaker
        # source short-circuit the stronger one.
        # ⛔ NO BASELINE, NO DELIVERY VERDICT (#1881 review P1). `transcript_offset` returns None
        # when the transcript cannot be stat'ed, and `transcript_has_payload` treats a None
        # `since_offset` as "search the last 2 MB" — which on a live lane can span DAYS, so an
        # EARLIER message with the same body (a standing order, a nudge, the retry the recovery text
        # prescribes) certified a LATER, truncated send. Passing None is the weaker read, and this is
        # the one call site where the weaker read is a false PASS, so it is refused here rather than
        # merely documented. Without a pre-send baseline the best available verdict is PANE_ONLY.
        if (session_file and session_base is not None
                and transcript_has_payload(session_file, text, tail_chars,
                                           since_offset=session_base)):
            return VERIFIED, screen
        if time.monotonic() >= deadline:
            # A dropped Enter is reported as its own verdict: submission was never ATTEMPTED, so this
            # must not read like "typed but not yet flushed" — the operator's remedy is to press
            # Enter in that pane, not to re-send a message that is already sitting in the composer.
            if not entered:
                return SUBMIT_FAILED, screen
            if saw_tail:
                return PANE_ONLY, screen
            return UNVERIFIED, screen
        sleep(poll_s)


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="cmux payload-integrity helper (#1187)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("verify", help="send a payload, then verify its tail landed")
    p.add_argument("--workspace", required=True)
    p.add_argument("--text", default=None)
    p.add_argument("--file", default=None)
    p.add_argument("--tail-chars", type=int, default=DEFAULT_TAIL_CHARS)
    p.add_argument("--screen-lines", type=int, default=DEFAULT_SCREEN_LINES)
    p.add_argument("--timeout", type=float, default=DEFAULT_VERIFY_TIMEOUT_S)

    p2 = sub.add_parser("check", help="verify a payload tail against a saved screen")
    p2.add_argument("--screen-file", required=True)
    p2.add_argument("--text", default=None)
    p2.add_argument("--file", default=None)
    p2.add_argument("--tail-chars", type=int, default=DEFAULT_TAIL_CHARS)

    args = parser.parse_args(argv)
    text = args.text
    if text is None and getattr(args, "file", None):
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()
    if text is None:
        parser.error("give --text or --file")

    if args.cmd == "check":
        # A saved screen answers ONLY the pane question, which is not a delivery verdict (#1881
        # review P0): the surface cannot distinguish a submitted message from one sitting in the
        # composer. Report PANE_ONLY for a match so the distinction is unmissable.
        with open(args.screen_file, encoding="utf-8", errors="replace") as fh:
            screen = fh.read()
        ok = screen_has_payload(screen, text, args.tail_chars)
        print(PANE_ONLY if ok else UNVERIFIED)
        # ⛔ PANE_ONLY IS NOT A SUCCESS (#1881 review P2). Exit 0 is the machine-readable success
        # channel: `cmux_payload.py check … && record_delivered` would have recorded a delivery out
        # of a surface match — the same false PASS this module exists to remove, reintroduced on the
        # second subcommand. Distinct from 3 (nothing matched) so a caller can tell the two apart.
        return 4 if ok else 3

    # ⛔ FLATTEN BEFORE SENDING (#1881 review P1). `flatten` was dead code while every caller passed
    # the raw body: a `cmux send` payload's newlines are individual Enters, so a multi-line order is
    # submitted line by line, each line an independent chance at the #1187 truncation, and the tail
    # marker certifies only the last one — a lost MIDDLE line verifies. One message, one submission.
    text = flatten(text)
    verdict, screen = send_verified(args.workspace, text, tail_chars=args.tail_chars,
                                    screen_lines=args.screen_lines,
                                    timeout_s=args.timeout)
    print(verdict)
    return 0 if verdict == VERIFIED else 3


if __name__ == "__main__":
    sys.exit(_main())
