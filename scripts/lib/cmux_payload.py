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
The **tail** is what a prefix truncation loses, so a send is `VERIFIED` only
when the payload's tail marker is present on the recipient's surface. Anything
else — a tail that is absent, an empty payload, or a surface we could not read —
is `UNVERIFIED`, and `UNVERIFIED` must never be reported to a caller as a
delivered order. The check is deliberately fail-closed: a false `UNVERIFIED`
costs a re-read, a false `VERIFIED` is how a lane ends up running a fragment of
its brief (the measured failure on #1187).

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
import os
import re
import subprocess
import sys
import time

_WS_RE = re.compile(r"\s+")

DEFAULT_TAIL_CHARS = 80
DEFAULT_SCREEN_LINES = 200
DEFAULT_VERIFY_TIMEOUT_S = 30.0
DEFAULT_POLL_S = 3.0

VERIFIED = "VERIFIED"
UNVERIFIED = "UNVERIFIED"
# ⛔ A THIRD VERDICT, because two could not express three states (#1881 review P0). The pane shows
# the composer's CONTENT, submitted or not: a payload typed into the lane's input box and never
# submitted renders its tail exactly like a delivered message. Reporting that as VERIFIED is the
# false pass this module exists to prevent, so "the tail is visible but submission is not proven"
# gets its own loud name instead of being folded into either neighbour.
PANE_ONLY = "PANE_ONLY"


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


def normalize(text: str) -> str:
    """Whitespace-collapsed, stripped text (readable form)."""
    return _WS_RE.sub(" ", text or "").strip()


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


def screen_has_payload(screen: str | None, sent_text: str,
                       tail_chars: int = DEFAULT_TAIL_CHARS) -> bool:
    """True iff the payload's tail marker appears on `screen`.

    Fail-closed: an empty payload, an empty marker, or an unreadable screen is
    NOT a positive match.
    """
    marker = tail_marker(sent_text, tail_chars)
    if not marker:
        return False
    return marker in compact(screen)


def resolve_session_file(workspace: str, run) -> str | None:
    """The recipient lane's live session `.jsonl`, resolved from the PANE.

    Best-effort second source for delivery evidence (the transcript is where a
    submitted message is durably written). Returns None when the pane has no
    session binding — never guess a file. Mirrors `ask-owner.py`'s
    `lane_session_file`.
    """
    try:
        proc = run(["cmux", "surface", "resume", "show", "--workspace", workspace],
                   timeout=45)
        out = getattr(proc, "stdout", "") or ""
    except Exception:                                          # noqa: BLE001
        return None
    sid = None
    for tok in out.replace("'", " ").split():
        if len(tok) == 36 and tok.count("-") == 4:
            sid = tok
            break
    if not sid:
        return None
    home = os.path.expanduser("~")
    hits = glob.glob(f"{home}/.pi/agent/sessions/*/*{sid}*.jsonl")
    return max(hits, key=os.path.getmtime) if hits else None


def transcript_has_payload(path: str, sent_text: str,
                           tail_chars: int = DEFAULT_TAIL_CHARS,
                           tail_bytes: int = 2_000_000,
                           since_offset: int | None = None) -> bool:
    """True iff the payload's tail marker appears in the session transcript.

    Reads only the tail of the file: a session `.jsonl` can be tens of MB.

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
            tail = fh.read().decode("utf-8", "replace")
    except Exception:                                          # noqa: BLE001
        return False
    return marker in compact(tail)


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

    Returns ``(VERIFIED|PANE_ONLY|UNVERIFIED, last_screen)``. Never raises on a clean
    send failure — a non-zero `cmux` exit or an unreadable surface folds into
    ``UNVERIFIED``, which is the loud verdict the caller must surface.

    ``VERIFIED`` requires SUBMISSION evidence (the tail marker appended to the lane's transcript after
    the pre-send baseline). ``PANE_ONLY`` means the tail is visible on the surface but nothing proves
    it was submitted — a dropped Enter, or a pane that still shows an earlier message with the same
    body. It is NOT a delivery verdict, and a caller that treats it as one re-opens #1187.

    `run` and `sleep` are seams so the send/verify loop can be exercised without
    a live cmux.
    """
    run = run or _default_run

    def cmux(*args):
        return run(["cmux", *args], timeout=45)

    # ⛔ THE TRANSCRIPT BASELINE IS TAKEN BEFORE THE SEND (#1881 review P1). Resolving it afterwards
    # would leave the size AFTER the bytes we are trying to attribute, so `since_offset` could only
    # certify nothing. This is the one read that must precede the act it observes.
    session_file = resolve_session_file(workspace, run)
    session_base = transcript_offset(session_file)

    try:
        cmux("send", "--workspace", workspace, text)
    except Exception:                                          # noqa: BLE001
        return UNVERIFIED, ""

    sleep(2)
    entered = True
    try:
        # The terminating Enter. Sent as its own call so a payload that itself
        # ends in a newline does not submit the message twice.
        cmux("send", "--workspace", workspace, "\n")
    except Exception:                                          # noqa: BLE001
        # ⛔ AN ENTER THAT DID NOT HAPPEN IS NOT A DETAIL (#1881 review P0). This used to be
        # swallowed, and the loop below then found the payload ON THE PANE — the composer renders
        # its content whether or not it was submitted — and returned VERIFIED. The lane never got
        # the order and the orchestrator recorded it delivered: the exact false pass this module
        # exists to prevent. Record the failure and let it decide the verdict.
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
        # SUBMISSION EVIDENCE, in order of strength. The transcript is where a submitted message is
        # durably written, so it is the only source that can certify the act; the pane can only show
        # that the text reached the composer. Checking the pane FIRST (as this did) let the weaker
        # source short-circuit the stronger one.
        if session_file and transcript_has_payload(session_file, text, tail_chars,
                                                   since_offset=session_base):
            return VERIFIED, screen
        if time.monotonic() >= deadline:
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
        return 0 if ok else 3

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
