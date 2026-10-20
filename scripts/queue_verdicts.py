#!/usr/bin/env python3
"""queue_verdicts.py — a TERMINAL verdict on a queue item stays terminal (#1563).

WHY THIS FILE EXISTS
--------------------
`claim.py` resolves `CLAIMS.tsv` **last write wins per PR**, and it treats `SKIPPED` as
non-terminal on every queue (its source comment: *"a skip means 'not now', not 'done'"*). The
consequence is not what that sentence intends: a `SKIPPED` (or `FREE`, or any unenumerated
word) written by **any** lane **resurrects an item another lane already terminated** as
`FIXED`/`BLOCKED`/`LANDED`/`REFUSED`. The terminated row is still in the file; it just stops
being the effective one, so `next` re-serves the item.

MEASURED, 2026-10-01/06 (seven instances recorded on #1563, each a terminal row overwritten
by a later non-terminal one from a *different* lane):

    #3419  FIXED    -> SKIPPED    ("NO REBASE NEEDED — the queue's CONFLICTING label is stale")
    #5453  BLOCKED  -> SKIPPED
    #5461  BLOCKED  -> SKIPPED    -> FIXED -> NEEDS-REBASE   (an unenumerated word)
    #5667  FIXED    -> SKIPPED x2
    #5696  FIXED    -> SKIPPED
    #6234  BLOCKED  -> SKIPPED    (re-served twice)
    #5630  BLOCKED  -> SKIPPED    (the BLOCKED row is the ONLY record of a STANDING OWNER
                                   DIRECTIVE — "do not start #5630 or #5651" — and the skip
                                   handed it to a lane as fresh work)
    #6119  BLOCKED  -> FREE       (the resurrecting row was a claim-release by __orchestrator__)
    #7413  BLOCKED  -> REFUSED    (on REMEDY, where REFUSED is a work order, not a verdict)

THE RULE THIS FILE ENCODES
--------------------------
**A terminal verdict stays terminal.** Once an item has reached a terminal state on the queue
being served, no later non-terminal observation may become the effective verdict. The later
observation is *recorded as an annotation* — what was seen, who saw it, and when — and the
verdict is unchanged.

THE OTHER DIRECTION IS GUARDED TOO, BECAUSE IT IS THE WORSE DEFECT. A verdict that can never
be reset freezes the queue permanently, and it stays invisible until somebody needs the reset.
So there are two explicit ACTS, and only acts move a terminal item:

  * ``REVIVED`` / ``REOPENED`` — re-opens a terminal item. The row MUST carry a reason; an
    act without a reason is refused (and reported), because an unexplained reset is how a
    queue silently un-terminates itself again. (`REVIVED` is `claim.py`'s own existing word —
    its `CLEAR_LANDING = ("REVIVED", "FIXED")` — so the reset path needs no new tool.)
  * ``LIFTED`` — the OWNER act that lifts a ``PROHIBITED`` row. `PROHIBITED` is a *permission*
    verdict, not a lifecycle stage: an owner prohibition is recorded once and is explicitly
    excluded from every revival rule, so an ordinary ``REOPENED`` must not un-bury it.

A genuinely new item (no terminal verdict yet), and an item whose only history is provisional
(``CLAIMED``/``FREE``/``SKIPPED``), move exactly as before — last write wins. The change is
confined to the case where a terminal verdict already exists.

CLASS-DEPENDENT TERMINALITY, PRESERVED. `claim.py` makes the terminal set a property of the
queue (`LANDABLE.tsv` vs `CONFLICTS.tsv`/`REMEDY.tsv`), and that distinction is load-bearing:
``FIXED`` on a CONFLICTS row means *"conflict cleared, pushed"* and must still be LANDABLE, so
it is terminal on CONFLICTS/REMEDY and provisional on LANDABLE. This module keeps claim.py's
sets and adds only stickiness, so it cannot break the two-stage pipeline.

UNRECOGNISED VERDICTS ARE LOUD, NEVER QUIETLY RE-SERVABLE. claim.py decides with
``if v in terminal: continue``, an allow-list — so every word outside it is silently
non-terminal (`NEEDS-REBASE` resurrected a `FIXED` row in the measured #5461 history). Here an
unknown word is reported in `Resolution.unknown` and in the dispatch note. It still cannot
override a terminal verdict.

WHO CALLS THIS. `scripts/queue-dispatch.py` — the last gate before a lane is handed an item —
replays `CLAIMS.tsv` with these semantics and refuses to serve a resurrected item, re-affirming
the terminal verdict in claim.py's own vocabulary (see `Guard.reaffirm`) so the queue stops
offering it to the next lane as well. `claim.py` itself is not versioned in this repo
(agent-infra#1552/#1567); until it is, this seam is the versioned half of the fix and it is
gated, tested and farmed.

CLI (read-only — this module never writes a queue):

    python3 scripts/queue_verdicts.py <CLAIMS.tsv> --queue LANDABLE.tsv
    python3 scripts/queue_verdicts.py <CLAIMS.tsv> --queue REMEDY.tsv --pr 7413

Exit codes: 0 = the PR is servable, 4 = a terminal verdict is in force, 2 = the file could not
be read (an unreadable queue is UNKNOWN, never empty).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field

# ── the vocabulary ────────────────────────────────────────────────────────────────────────────
# Provisional: last write wins, and a provisional row can always become the effective verdict
# for an item that has NOT been terminated. `SKIPPED` is provisional by claim.py's own design
# ("not now"), and stays that way here — the fix is that it can no longer *clear* a terminal row.
PROVISIONAL = ("CLAIMED", "FREE", "SKIPPED")

# Terminal, per queue class. These are claim.py's own sets (`claim.py:191-194`); do not widen
# them without changing the deployed tool in lockstep, or `Guard.reaffirm` below would write a
# word the running queue does not read as terminal and the item would loop anyway.
_LAND_TERMINAL = ("LANDED", "REFUSED", "BLOCKED")
_WORK_TERMINAL = ("LANDED", "FIXED", "BLOCKED")

# The queue classes, keyed by the file the dispatcher is serving from. An UNKNOWN queue gets the
# intersection of the two lives: everything terminal on BOTH classes. `REFUSED` is deliberately
# NOT in it — on a work-order queue REFUSED is the work order, and wrongly calling it terminal
# freezes a row, which is the failure this module exists to prevent in the other direction.
QUEUE_CLASSES = {
    "landable.tsv": ("land", _LAND_TERMINAL),
    "ci-prs.tsv": ("ci", _LAND_TERMINAL),
    "conflicts.tsv": ("conflict", _WORK_TERMINAL),
    "remedy.tsv": ("remedy", _WORK_TERMINAL),
}
UNKNOWN_QUEUE = ("unknown", ("LANDED", "FIXED", "BLOCKED"))

# Permission verdicts. `PROHIBITED` is sticky against EVERYTHING — including a later terminal
# verdict, because a work-completion word is not a permission decision. Only `LIFTED` clears it.
PROHIBITED = "PROHIBITED"
LIFTABLE = ("LIFTED", "UNPROHIBITED")

# Explicit re-open acts (the reset path). Both need a reason; see `_is_act`.
REOPEN_ACTS = ("REVIVED", "REOPENED", "REOPEN")

KNOWN = frozenset(PROVISIONAL + _LAND_TERMINAL + _WORK_TERMINAL + (PROHIBITED,) + LIFTABLE + REOPEN_ACTS)

# timestamp shapes claim.py writes into the reason column for CLAIMED/FREE rows
_TIME_RE = re.compile(r"^\d{1,2}:\d{2}(:\d{2})?$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?Z?$")
_DIGITS_RE = re.compile(r"^\d+$")

MAX_REASON = 600


def queue_class(queue: str | None):
    """(class name, terminal set) for a queue path/name. Never raises."""
    base = os.path.basename((queue or "").strip()).lower()
    return QUEUE_CLASSES.get(base, UNKNOWN_QUEUE)


# ── rows ──────────────────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Row:
    """One CLAIMS.tsv row. The shape claim.py writes is ``pr<TAB>lane<TAB>verdict<TAB>rest``,
    where ``rest`` is a REASON for `done` rows and a HH:MM:SS STAMP for CLAIMED/FREE rows — the
    two are told apart here, so an annotation can say *what* was seen and, when the row carries
    it, *when*.

    A LEADING LINE NUMBER IS TOLERATED. Every measured history on #1563 was quoted through a
    numbered viewer (`1578  6244  4a Retrieval and traversal  SKIPPED  …`), and a consumer that
    echoes such a row back must not read `1578` as the PR.
    """
    pr: str
    lane: str
    verdict: str
    reason: str
    at: str | None
    index: int

    def describe(self, limit: int = 120) -> str:
        what = self.reason or (self.at or "")
        if len(what) > limit:
            what = what[: limit - 1].rstrip() + "…"
        when = f" at {self.at}" if self.at else ""
        return f"{self.lane or '(no lane)'} {self.verdict}{when}: {what}".strip()


def parse_rows(text: str):
    """Parse CLAIMS.tsv text -> (rows, malformed). Order is preserved: resolution is ORDERED."""
    rows, malformed = [], []
    for i, raw in enumerate(text.splitlines()):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        # a leading line number (numbered-viewer paste) is not a PR
        if len(fields) > 3 and _DIGITS_RE.match(fields[0].strip()) and _DIGITS_RE.match(fields[1].strip()):
            fields = fields[1:]
        if len(fields) < 3 or not _DIGITS_RE.match(fields[0].strip()):
            malformed.append(f"line {i + 1}: {line[:80]}")
            continue
        pr, lane, verdict = fields[0].strip(), fields[1].strip(), fields[2].strip().upper()
        rest = "\t".join(fields[3:]).strip()
        if not verdict:
            malformed.append(f"line {i + 1}: no verdict field — {line[:80]}")
            continue
        at = None
        if _TIME_RE.match(rest) or _ISO_RE.match(rest):
            at, rest = rest, ""
        rows.append(Row(pr, lane, verdict, rest[:MAX_REASON], at, len(rows)))
    return rows, malformed


# ── resolution ───────────────────────────────────────────────────────────────────────────────
@dataclass
class Resolution:
    """What the queue history MEANS, under sticky-terminal semantics."""
    queue: str
    queue_class: str
    terminal_set: tuple
    governing: dict = field(default_factory=dict)      # pr -> Row that currently decides
    terminal: dict = field(default_factory=dict)       # pr -> Row (terminal verdict in force)
    prohibition: dict = field(default_factory=dict)    # pr -> Row (PROHIBITED, owner directive)
    annotations: dict = field(default_factory=dict)    # pr -> [Row] observed after the verdict
    acts: dict = field(default_factory=dict)           # pr -> [Row] REVIVED/REOPENED/LIFTED
    refused_acts: list = field(default_factory=list)   # [Row] an act with no reason
    unknown: list = field(default_factory=list)        # [Row] verdict word nobody recognises
    malformed: list = field(default_factory=list)

    # the row that is in force, if any: an owner prohibition outranks every lifecycle verdict
    def in_force(self, pr: str):
        pr = str(pr)
        return self.prohibition.get(pr) or self.terminal.get(pr)

    def verdict_of(self, pr: str):
        row = self.in_force(pr)
        return row.verdict if row else None

    def servable(self, pr: str) -> bool:
        """True when no terminal verdict (and no owner prohibition) is in force."""
        return self.in_force(pr) is None

    def annotations_for(self, pr: str):
        return list(self.annotations.get(str(pr), ()))

    def unknown_for(self, pr: str):
        return [r for r in self.unknown if r.pr == str(pr)]

    def why(self, pr: str) -> str:
        pr = str(pr)
        row = self.in_force(pr)
        if row is None:
            n = len(self.unknown_for(pr))
            extra = f"; {n} UNRECOGNISED verdict(s) on this item" if n else ""
            return f"PR {pr}: no terminal verdict — servable{extra}"
        notes = "; ".join(r.describe() for r in self.annotations_for(pr))
        what = "PROHIBITED (owner directive)" if row is self.prohibition.get(pr) else row.verdict
        return (f"PR {pr}: {what} in force (lane {row.lane or '?'}"
                f"{' at ' + row.at if row.at else ''})"
                + (f" — later observations recorded as annotations: {notes}" if notes else ""))


def resolve(text: str, queue: str | None) -> Resolution:
    """Replay CLAIMS.tsv text under sticky-terminal semantics for `queue`.

    ORDERED, and one row can never do two things. Per PR, in file order:

      * ``LIFTED`` (owner act, reason required)  -> clears the prohibition AND the terminal
        verdict: the owner is not only un-prohibiting the item, they are returning it to work.
      * ``PROHIBITED``                          -> binds. Nothing later clears it but LIFTED;
        not even a later terminal verdict.
      * ``REVIVED``/``REOPENED`` (reason req.)  -> clears the terminal verdict (never a
        prohibition) and starts a new epoch. A later non-terminal row can then take effect.
      * a terminal verdict for this queue class -> if nothing is in force, it becomes the
        effective verdict. If something IS in force, it is an annotation (a re-affirmation).
        THE FIRST terminal verdict binds: a later one is RECORDED, not applied. The item is
        already terminated, so servability cannot change; `verdict_of` names why it first left
        the queue and the annotations name everything observed after that.
      * any other row                           -> if something is in force it is an annotation
        (the resurrection this module removes); otherwise it is the effective (provisional)
        verdict, exactly as last-write-wins did.

    AN ANNOTATION BELONGS TO AN EPOCH. `LIFTED`, `PROHIBITED` and a successful `REVIVED`/
    `REOPENED` all start a new one, and the previous epoch's observations are dropped from
    `annotations` — otherwise a revived item's fresh terminal verdict would be reported
    alongside observations that predate it, which is a false account of the same kind this
    module exists to remove.
    """
    cls, terminal_set = queue_class(queue)
    res = Resolution(queue or "", cls, tuple(terminal_set))
    rows, res.malformed = parse_rows(text)

    for row in rows:
        pr, v = row.pr, row.verdict
        if v not in KNOWN:
            res.unknown.append(row)

        if v in LIFTABLE:
            if not row.reason:
                res.refused_acts.append(row)
                _annotate(res, row, pr)
                continue
            res.prohibition.pop(pr, None)
            res.terminal.pop(pr, None)
            res.annotations.pop(pr, None)
            res.governing[pr] = row
            res.acts.setdefault(pr, []).append(row)
            continue

        if v == PROHIBITED:
            res.prohibition[pr] = row
            res.annotations.pop(pr, None)
            res.governing[pr] = row
            continue

        if v in REOPEN_ACTS:
            if not row.reason:
                # An act without a reason is not an act. Refuse it LOUDLY (caller prints
                # `refused_acts`) — an unexplained reset is how the queue un-terminates itself.
                res.refused_acts.append(row)
                _annotate(res, row, pr)
                continue
            if pr in res.prohibition:
                # An owner prohibition is not a lifecycle stage; only LIFTED lifts it.
                _annotate(res, row, pr)
                res.acts.setdefault(pr, []).append(row)
                continue
            res.terminal.pop(pr, None)
            res.annotations.pop(pr, None)
            res.governing[pr] = row
            res.acts.setdefault(pr, []).append(row)
            continue

        if res.in_force(pr) is not None:
            _annotate(res, row, pr)
            continue

        if v in terminal_set:
            # no epoch to clear: annotations exist only WHILE a verdict is in force (see
            # `_annotate`), and this branch runs only when nothing is in force.
            res.terminal[pr] = row
            res.governing[pr] = row
            continue

        res.governing[pr] = row        # provisional (or unrecognised): last write wins

    return res


def _annotate(res: Resolution, row: Row, pr: str) -> None:
    """Record an observation OF A VERDICT THAT IS IN FORCE.

    A row arriving with nothing in force is not an annotation — it is the effective verdict
    (`governing`) and behaves exactly as last-write-wins did. Enforcing the invariant here is
    what keeps `Resolution.annotations` an honest account of a live verdict rather than a log of
    every row that ever followed the first one.
    """
    if res.in_force(pr) is not None:
        res.annotations.setdefault(pr, []).append(row)


# ── the dispatch seam ────────────────────────────────────────────────────────────────────────
# The word a terminal verdict is RE-AFFIRMED with, so the item stops being served by claim.py
# as well. PROHIBITED is not in claim.py's vocabulary, so a prohibition is re-affirmed with the
# queue's own word for "attempted, and the answer is a decision no other lane can make" — the
# prohibition itself survives in history and in `Resolution.prohibition`, so the BLOCKED this
# writes can never be mistaken for a generic park (`Resolution` reports PROHIBITED as in force).
REAFFIRM_WORD = {PROHIBITED: "BLOCKED"}


@dataclass(frozen=True)
class Guard:
    """The decision for one item at the moment of dispatch."""
    servable: bool
    pr: str
    verdict: str | None
    note: str
    reaffirm: str | None = None
    reaffirm_reason: str | None = None


def guard(res: Resolution, pr: str) -> Guard:
    """Should this item be served? If not, what terminal row must be re-affirmed?"""
    pr = str(pr)
    if res.servable(pr):
        return Guard(True, pr, None, res.why(pr))

    row = res.in_force(pr)
    prohibited = row is res.prohibition.get(pr)
    word = REAFFIRM_WORD.get(row.verdict, row.verdict)
    seen = "; ".join(r.describe() for r in res.annotations_for(pr)) or "none"
    unknown = res.unknown_for(pr)
    reason = (
        f"STICKY {row.verdict} — terminal verdict stands"
        + (f" (owner directive, recorded by {row.lane})" if prohibited else f" (recorded by {row.lane})")
        + f"; {row.reason[:200] + '; ' if row.reason else ''}"
        + f"later non-terminal observation(s) recorded as annotations: {seen}. "
        + ("An owner prohibition is lifted only by an explicit LIFTED row. "
           if prohibited else
           "To re-open deliberately, record REOPENED with a reason — an act, not a skip. ")
        + (f"UNRECOGNISED verdict word(s) on this item: "
           f"{', '.join(sorted({r.verdict for r in unknown}))}. " if unknown else "")
    )
    return Guard(False, pr, row.verdict, res.why(pr), word, reason[:MAX_REASON])


def verdict_menu(queue: str | None):
    """The verdicts a lane can reach on THIS queue's rows, for the dispatch instruction.

    #1563's second measured route into the root: the dispatcher emitted ONE unconditional menu
    (`LANDED|REFUSED|SKIPPED`) while claim.py's terminal set is class-dependent, so a
    `conflict` row's menu contained no verdict that terminates the row — `REFUSED` is a work
    order there. A compliant lane therefore could not dispose of its own row, and the loop
    needed no second lane at all. The menu must be the queue's, not a constant.
    """
    _, terminal_set = queue_class(queue)
    return tuple(terminal_set) + ("SKIPPED",)


def reopen_hint() -> str:
    return "REOPENED (with a reason)"


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Replay CLAIMS.tsv under sticky-terminal semantics (#1563).")
    ap.add_argument("claims", help="path to CLAIMS.tsv")
    ap.add_argument("--queue", default="LANDABLE.tsv", help="the queue being served (default LANDABLE.tsv)")
    ap.add_argument("--pr", help="report only this PR")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    try:
        with open(args.claims, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"READ-FAILED {args.claims}: {exc} — UNKNOWN, not empty", file=sys.stderr)
        return 2

    res = resolve(text, args.queue)
    prs = [args.pr] if args.pr else sorted({r.pr for r in parse_rows(text)[0]} | set(res.governing))

    if args.json:
        print(json.dumps({
            "queue": res.queue, "queue_class": res.queue_class, "terminal_set": list(res.terminal_set),
            "items": [{"pr": pr, "servable": res.servable(pr), "verdict": res.verdict_of(pr),
                       "why": res.why(pr),
                       "annotations": [r.__dict__ for r in res.annotations_for(pr)],
                       "acts": [r.__dict__ for r in res.acts.get(pr, ())]}
                      for pr in prs],
            "unknown": [r.__dict__ for r in res.unknown],
            "refused_acts": [r.__dict__ for r in res.refused_acts],
            "malformed": res.malformed,
        }, indent=2))
        return 0 if (not args.pr or res.servable(args.pr)) else 4

    for pr in prs:
        print(("SERVABLE   " if res.servable(pr) else "TERMINAL   ") + res.why(pr))
    for r in res.refused_acts:
        print(f"REFUSED-ACT {r.describe()} — an act needs a reason; the verdict is unchanged", file=sys.stderr)
    for line in res.malformed:
        print(f"MALFORMED  {line}", file=sys.stderr)
    return 0 if (not args.pr or res.servable(args.pr)) else 4


if __name__ == "__main__":
    sys.exit(main())
