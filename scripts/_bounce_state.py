"""The ONE definition of "is `question-bounced` still the truth about this issue?"

WHY THIS MODULE EXISTS (agent-infra#2844)
    `question-bounced` is a GitHub label, i.e. a mutable current-state projection of a
    fact that the issue's TIMELINE already records durably. Two readers were treating the
    projection as authority without ever looking at the record it projects:

      * `undelivered-answers.py` turned "the label is present" into the flat claim
        "question-bounced left on (the lane must clear it)" — a claim about WHO IS AT FAULT,
        asserted from state nobody re-validates, on an issue whose thread may have moved on
        minutes after the bounce.
      * `turn-classify.py` folded the same label into `lanes_with_open_question()`, which
        `main()` reads as `used_protocol`, which SUPPRESSES the `question_no_protocol`
        nudge. A stale label therefore silences the nudge for a lane asking a FRESH
        question, and the question stays in a conversation and never reaches the queue.

    So the drift is not "the label is written twice" (see THE WRITER, below — it is not).
    It is that a projection was read as the record. This module reads the record.

THE WRITER, NAMED (item 3 of the issue, and the half of its framing that was right)
    Exactly ONE writer exists in this tree: `scripts/ask-owner.py`. Its two bounce paths —
    STEP 1 (a question with no `RESEARCH:` declaration, `ask-owner.py` `main()` STEP 1) and
    STEP 2 (a question that failed the marks) — each post the bounce body and THEN run
    `gh issue edit --add-label question-bounced`. Nothing else writes it, and
    `scripts/test_bounce_state.py` asserts that mechanically (`test_one_writer_is_named`),
    so a new writer cannot appear silently.

    ⛔ THE ISSUE'S HEADLINE PREMISE — "no script in either tree writes this label", so a
    SECOND writer re-labelled an answered issue — is FALSIFIED by the very timeline it
    cites, and this module does not encode it. Measured from
    `gh api repos/daniel-ospina/tortoise/issues/9964/timeline`, every
    `labeled question-bounced` is preceded 2-3 s earlier by a `commented` event:
    15:49:15 comment -> 15:49:18 label; 17:09:02 -> 17:09:05; 21:14:38 -> 21:14:40. That is
    ask-owner.py's own comment-then-label sequence, three times running. Nobody else wrote
    it. What survives is the READER defect above — which needs no rogue writer at all, and
    which this module fixes by making the label a cross-check instead of a verdict.

    The other reader, `ask-owner.py::owner_answered_at`, keys the WRITE predicate on the
    same label (`bounced -> ""`). That rule is agent-infra#1969's *declared* gap and is
    deliberately NOT changed here: `answer-delivered` is a permanent skip, and widening when
    the gate may write it is a different blast radius from making two readers honest. It is
    named in the comment there, not silently fixed here.

THE RULE (one line)
    A bounce is CURRENT only while its own `labeled` event is the NEWEST thing in the
    thread. Anything newer — a comment, the lane clearing the label, a later pass that
    re-queued the question, or an `owner-answered`/`answer-delivered` receipt — SUPERSEDES
    it. Callers report that disagreement; nobody auto-heals it, because removing the label
    on a guess would be a second writer of the same state, which is the class of defect
    this whole module exists to end (and §item 2 of the issue asks for exactly that).

    Outside evidence for reading the log rather than the projection: Fowler, *Event
    Sourcing* (2005) — "all changes to application state are stored as a sequence of
    events … we can also use the event log to reconstruct past states". And the recorded
    decision this rests on: `docs/research/2026-10-21-issue-2273-founder-comms-research.md`
    §R1 ("one writer per record … the issue … never owns state" — i.e. a label is a copy
    for attention) and §R3 ("no duplicated derivation … One definition, in agent-infra,
    exercised by a test that crosses the boundary" — the reason the fetch and the parse
    live HERE and not in each reader).

CONTRACT FOR CALLERS
    `bounce_view(...)` never raises and never guesses. `state == UNKNOWN` means the read
    failed and the caller MUST keep its previous behaviour — no new claim, no blind
    message. A projection this module cannot read is not evidence of anything.
"""
from __future__ import annotations

BOUNCE = "question-bounced"      # written only by ask-owner.py — see THE WRITER
QUEUE = "owner-decision"         # "a decision is still owed"
ANSWERED = "owner-answered"      # the human-facing record that an answer exists
DELIVERED = "answer-delivered"   # written ONLY by ask-owner.py — the delivery receipt

# ── the four states. ABSENT is not an error: an issue that never bounced is fine. ──
ABSENT = "absent"           # no `labeled question-bounced` event at all
CURRENT = "current"         # its `labeled` event is the newest thing in the thread
SUPERSEDED = "superseded"   # something in the thread is NEWER than that event
UNKNOWN = "unknown"         # the timeline could not be read — the caller must not claim

# ── ONE fetch, ONE parse: no reader re-derives this filter (R3) ────────────────
# Emits one line per event of interest. ⛔ Never `|length` — under `--paginate`, `--jq`
# runs PER PAGE, so a count would come back as one number per page and the caller cannot
# sum it (it would land in the UNKNOWN branch and silently disarm the check). One line
# per event is pagination-safe; the reduction happens in `parse`.
TIMELINE_JQ = (
    '.[]'
    '| select('
    '  ((.event=="labeled" or .event=="unlabeled")'
    '   and ((.label.name // "") == "%s" or (.label.name // "") == "%s"'
    '        or (.label.name // "") == "%s" or (.label.name // "") == "%s"))'
    '  or .event == "commented")'
    '| "\\(.event)\\t\\((.label.name) // "")\\t\\(.created_at)"'
) % (BOUNCE, QUEUE, ANSWERED, DELIVERED)

# What a "moved" event is called in a human sentence. Anything not named here is still
# counted as movement — an unrecognised event newer than the bounce is, by definition,
# not the bounce, and inventing a reason to ignore it is how a stale flag survives.
_MOVED_BY = {
    ("commented", ""): "a comment",
    ("unlabeled", BOUNCE): "the `question-bounced` label being cleared",
    ("labeled", QUEUE): "a later pass that re-queued the question",
    ("labeled", ANSWERED): "an `owner-answered` receipt",
    ("labeled", DELIVERED): "an `answer-delivered` receipt",
}


class View:
    """What the timeline says about one issue's bounce label.

    Deliberately a plain object with five readable fields rather than a dict: every
    consumer reads exactly these, and a missing attribute is an error at the call site
    instead of a None that silently reads as "not stale".
    """

    __slots__ = ("state", "bounce_at", "moved_at", "moved_by",
                 "removals_after_bounce")

    def __init__(self, state, bounce_at="", moved_at="", moved_by="",
                 removals_after_bounce=0):
        self.state = state
        self.bounce_at = bounce_at
        self.moved_at = moved_at
        self.moved_by = moved_by
        # `unlabeled owner-decision` events NEWER than the newest bounce label. This is
        # the one number `undelivered-answers.py` previously computed itself, and it
        # computed it from a jq filter that could not tell a stale bounce from a current
        # one — which is how a post-bounce removal got attributed to "the gate's own
        # bounce" on an issue whose bounce was hours old.
        self.removals_after_bounce = removals_after_bounce

    # both readers only ever ask these two questions, so they get names
    @property
    def read(self):
        return self.state != UNKNOWN

    @property
    def stale(self):
        """True only when the timeline POSITIVELY shows the label was overtaken.

        `UNKNOWN` is False here on purpose: an unreadable timeline is not evidence that
        the label is stale, and a caller that nudged on it would be messaging a lane on a
        read it could not perform.
        """
        return self.state == SUPERSEDED

    def __repr__(self):                                          # pragma: no cover
        return ("View(state=%s bounce_at=%s moved_at=%s moved_by=%r removals=%d)"
                % (self.state, self.bounce_at or "-", self.moved_at or "-",
                   self.moved_by, self.removals_after_bounce))


def parse(rows):
    """Reduce `(event, label, created_at)` rows to a View. Pure — this is the definition.

    Lexical timestamp comparison is the house convention here (`owner_answered_at`,
    `undelivered_event_count` both already compare ISO strings directly) and is sound for
    GitHub's fixed `%Y-%m-%dT%H:%M:%SZ` shape. Rows with no readable timestamp are
    DROPPED, not treated as "now": a malformed line is the pagination/format bug this
    whole layer has been bitten by, and it must not be able to make a label look current.
    """
    bounce_ats, removals, events = [], [], []
    for row in rows or ():
        try:
            ev, lab, at = row
        except (TypeError, ValueError):                          # noqa: BLE001
            continue
        ev, lab, at = (ev or "").strip(), (lab or "").strip(), (at or "").strip()
        if not at:
            continue
        if ev == "labeled" and lab == BOUNCE:
            bounce_ats.append(at)
        elif ev == "unlabeled" and lab == QUEUE:
            removals.append(at)
        events.append((at, ev, lab))

    if not bounce_ats:
        return View(ABSENT, removals_after_bounce=len(removals))

    bounce_at = max(bounce_ats)
    removals_after = len([at for at in removals if at > bounce_at])
    moved = [(at, ev, lab) for (at, ev, lab) in events if at > bounce_at]
    if not moved:
        return View(CURRENT, bounce_at=bounce_at,
                    removals_after_bounce=removals_after)

    moved_at, ev, lab = max(moved)
    return View(SUPERSEDED, bounce_at=bounce_at, moved_at=moved_at,
                moved_by=_MOVED_BY.get((ev, lab)) or ("a `%s` event on `%s`"
                                                      % (ev, lab or "no label")),
                removals_after_bounce=removals_after)


def bounce_view(repo, number, run):
    """Fetch + parse one issue's bounce state. `run(argv) -> (rc, stdout)`.

    `run` is injected rather than imported so each caller keeps its OWN `gh` resolution:
    these two readers sit behind different rate-limit layers (`$O/gh-limit` in
    `undelivered-answers.py`, `_gh_layer()` in `turn-classify.py`), and quietly
    re-pointing either at the other's wrapper would change which process serialises the
    shared account — a side effect nobody reading this change would expect from it.

    A failed read is `UNKNOWN`, never `ABSENT` and never `CURRENT`: the whole point of the
    two readers is that a broken read must not read as a verdict.
    """
    try:
        rc, out = run(["gh", "api",
                       "repos/%s/issues/%d/timeline?per_page=100" % (repo, number),
                       "--paginate", "--jq", TIMELINE_JQ])
    except Exception:                                            # noqa: BLE001
        return View(UNKNOWN)
    if rc != 0:
        return View(UNKNOWN)
    rows = []
    for ln in (out or "").splitlines():
        if not ln.strip():
            continue
        parts = ln.split("\t", 2)
        rows.append((parts + ["", "", ""])[:3])
    return parse(rows)
