"""The question gate's language marks must track the property they name.

Regression guard for the 2026-10-17 defect (agent-infra#1903): eleven gate runs on ONE
question, eight substantial rewrites of it, and the two language marks scored the whole
set inside 0.43-0.59 against a 0.55 bar. The ONLY language pass was the MOST TECHNICAL
draft (jargon_free 0.56, still carrying `eval` and bare issue numbers), while the drafts
written for a non-developer scored LOWER (0.48 and 0.51). The mark named `jargon_free`
rewarded density, so a lane that read the bounce and simplified was driven backwards.

The replacement is mechanical (bare paths / unexplained ticket references / unexplained
identifiers / sentence length). These tests pin the properties that make it usable:

  * the signal is MONOTONE — more jargon can only lower the score, so it cannot invert;
  * the null pair is ZERO by construction — the same text scored 20 times is identical,
    which is the measurement agent-infra#1903 asked for and the old mark could not give;
  * the bounce NAMES the occurrence it counted, so a lane fixes the text instead of
    guessing which axis the score meant;
  * a bounce takes the question out of the owner's queue, so an artifact can no longer
    read `owner-decision` + `question-bounced` at the same time.

Each test below fails on the pre-fix module: `language_marks` did not exist (the two
marks were Jev's `QUESTIONS` entries), `QUESTIONS` listed them, and a bounce did not
remove `owner-decision`.
"""
import importlib.util
import io
import os
from contextlib import redirect_stdout

SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ask-owner.py")
_spec = importlib.util.spec_from_file_location("ask_owner", SPEC)
ao = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ao)

BAR = ao.THRESHOLD_JARGON


# ── fixtures, reconstructed from the issue's own table ────────────────────────
V1 = """RESEARCH: skill=issue-scoping sources=internal refs=none

The lineage of the stored rows was reconciled and the superseded rows were re-run through
`eval`, see #1553 and agent-infra#1903.

Options: 1. Keep it. 2. Change it.

I recommend 2.
"""

# v3 is the draft that PASSED under the Jev mark: a background section was added, and it
# still carried `eval`, two bare ticket numbers and the internal vocabulary.
V3 = """RESEARCH: skill=issue-scoping sources=internal refs=none

## Background
The lineage of the stored rows was reconciled, and the superseded rows were re-run
through `eval`. The measurements are on #1553 and on agent-infra#1903.

Options: 1. Keep it. 2. Change it.

I recommend 2.
"""

# v9 is the draft written for a non-developer: no internal vocabulary, no invented names.
V9 = """RESEARCH: skill=issue-scoping sources=internal refs=none

## What happened
A check that is supposed to send badly written questions back is rejecting well written
ones instead.

## Options
1. Keep the check as it is.
2. Replace it with a plain rule anyone can follow.

## What each costs
Keeping it means the same rewrite-forever loop. Replacing it means the check can only
see what a rule can see.

I recommend 2.
"""

EXPLAINED = """RESEARCH: skill=issue-scoping sources=internal refs=none

The gate is scripts/ask-owner.py, the script that decides whether a question reaches you.
It was measured on the issue agent-infra#1903, where eight rewrites were scored.
"""


def _marks(text):
    answers, findings = ao.language_marks(text)
    return {k: v["noul"] for k, v in answers.items()}, findings


# ── the marks exist, are mechanical, and cover the declared shape ─────────────
def test_language_marks_are_not_jev_questions():
    """Jev is no longer asked to grade prose: the two marks left the rubric.

    Pre-fix: `QUESTIONS` contained `jargon_free` and `understandable`, so the
    non-discriminating judgement was still what decided the bounce.
    """
    assert "jargon_free" not in ao.QUESTIONS
    assert "understandable" not in ao.QUESTIONS
    # and the structural marks are untouched: the gate's shape did not change
    assert set(ao.QUESTIONS) == {
        "has_context", "has_options", "has_analysis", "has_recommendation",
        "contradiction_test",
    }


def test_the_draft_that_used_to_pass_now_fails():
    """v3 — the only Jev language PASS in the set — carries bare references.

    Pre-fix: `language_marks` did not exist; v3 scored jargon_free 0.56 and passed.
    Now: two bare issue numbers and a bare identifier are counted, and it fails.
    """
    marks, findings = _marks(V3)
    assert marks["jargon_free"] < BAR, marks
    counted = [tok for _, tok in findings["jargon_free"][1]]
    assert "`eval`" not in counted          # the token is reported bare, not pre-rendered
    assert "eval" in counted, counted
    assert "#1553" in counted and "agent-infra#1903" in counted, counted


def test_the_plain_draft_passes():
    """v9 — written for a non-developer — must pass, which is the whole point."""
    marks, _ = _marks(V9)
    assert marks["jargon_free"] >= BAR, marks
    assert marks["understandable"] >= BAR, marks


def test_plainest_beats_technical():
    """The inversion guard: the plain drafts must not score LOWER than the technical one.

    Pre-fix: v7/v9 scored 0.48/0.51 on jargon_free against v3's 0.56 — the signal was
    anti-correlated, so every honest simplification moved a lane backwards.
    """
    v3, _ = _marks(V3)
    v9, _ = _marks(V9)
    assert v9["jargon_free"] > v3["jargon_free"], (v3, v9)
    assert v9["understandable"] >= v3["understandable"], (v3, v9)


def test_the_first_draft_fails():
    marks, _ = _marks(V1)
    assert marks["jargon_free"] < BAR, marks


def test_an_explained_reference_is_not_counted():
    """A path or ticket introduced in words is exactly what the mark asks for."""
    marks, findings = _marks(EXPLAINED)
    assert findings["jargon_free"][1] == [], findings
    assert marks["jargon_free"] == 1.0


def test_only_references_without_a_gloss_are_counted():
    text = ("See #1553 for the measurement, then `eval` fails, "
            "while the issue agent-infra#1903 explains it.")
    counted = [tok for _, tok in ao.unexplained_references(text)]
    assert counted == ["#1553", "eval"], counted


def test_more_jargon_can_only_lower_the_score():
    """Monotone in the defect: the property the old mark lacked.

    Pre-fix: adding a background section RAISED jargon_free (v1 0.28 -> v3 0.56), which
    is what let a lane pass by padding instead of by simplifying.
    """
    plain, _ = ao.jargon_free_score("A short plain question with no references.")
    one, _ = ao.jargon_free_score("See #1234 for it.")
    two, _ = ao.jargon_free_score("See #1234 and `eval` for it.")
    assert plain > one > two, (plain, one, two)


def test_long_sentences_fail_understandable():
    long_sentence = " ".join(["word"] * 60) + "."
    marks, findings = _marks(long_sentence)
    assert marks["understandable"] < BAR, marks
    assert "average sentence length" in findings["understandable"][1][0]


def test_a_bullet_list_is_not_one_long_sentence():
    """Options are bullets; welding them into one sentence would fail a readable question."""
    options = "\n".join(
        f"- Option {i}: " + " ".join(["word"] * 40) + "." for i in range(3))
    marks, _ = _marks(options)
    assert marks["understandable"] >= BAR, marks


def test_null_pair_spread_is_zero():
    """THE MISSING MEASUREMENT (agent-infra#1903, suggested check 1).

    The same text scored 20 times: a mechanical mark has no run-to-run variance, so the
    null pair is an assertion, not a sample. Pre-fix there was nothing to assert — the
    mark was a paid judgement call, and its 0.48-0.58 spread over eight rewrites could
    not be told apart from run-to-run wobble.
    """
    runs = [_marks(V3)[0] for _ in range(20)]
    for name in ("jargon_free", "understandable"):
        values = {r[name] for r in runs}
        assert len(values) == 1, (name, values)


# ── the bounce: named, and it takes the question out of the queue ─────────────
class _Recorder:
    def __init__(self):
        self.calls = []

    def __call__(self, args, timeout=None):
        self.calls.append([str(a) for a in args])
        return ""

    def find(self, *needles):
        return [c for c in self.calls if all(n in c for n in needles)]


def _run_gate(monkeypatch, text, dry=False):
    rec = _Recorder()
    monkeypatch.setattr(ao, "sh", rec)
    monkeypatch.setattr(ao, "sh_status", lambda args, timeout=None: (0, "", ""))
    monkeypatch.setattr(ao, "fetch_question", lambda repo, n: text)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["daniel-ospina/agent-infra", "1903"] + (["--dry-run"] if dry else []))
    return rc, rec, out.getvalue()


def test_bounce_names_the_occurrence_and_clears_the_queue_label(monkeypatch):
    """One readable state: bounced means OUT of the owner's queue, and the lane is told
    exactly which token failed.

    Pre-fix: the comment said only "internal shorthand" (the lane guessed the axis), and
    the edit added `question-bounced` WITHOUT removing `owner-decision`, so one artifact
    could read as both live and returned (agent-infra#1553).
    """
    rc, rec, out = _run_gate(monkeypatch, V3)
    assert rc == 1, out
    comments = rec.find("issue", "comment")
    assert comments, rec.calls
    body = comments[0][-1]
    assert "eval" in body and "#1553" in body, body
    assert "bare identifier" in body, body
    edits = rec.find("issue", "edit")
    assert edits, rec.calls
    assert any("--remove-label" in c and "owner-decision" in c for c in edits), edits
    assert "primary_problem" in out


def test_a_plain_question_still_passes(monkeypatch):
    """The pass path is unchanged: label it into the queue, clear the stale bounce."""
    rc, rec, out = _run_gate(monkeypatch, V9)
    assert rc == 0, out
    edits = rec.find("issue", "edit")
    assert any("owner-decision" in c and "question-bounced" in c for c in edits), edits


def test_no_research_bounce_also_clears_the_queue_label(monkeypatch):
    """A question with no declaration is not in the queue either."""
    rc, rec, _ = _run_gate(monkeypatch, "No declaration here.")
    assert rc == 1
    edits = rec.find("issue", "edit")
    assert any("--remove-label" in c and "owner-decision" in c for c in edits), edits


# ── the offline scoring path (no gh, no issue comments) ──────────────────────
def test_score_file_repeat_reports_a_zero_spread(monkeypatch, tmp_path):
    """`--score-file --repeat N` is the null pair WITHOUT posting to the PR.

    Pre-fix: the only way to score a draft was to post it as a `RESEARCH:` comment and
    run the gate against the issue — one PR carried seven question comments as a side
    effect of calibrating (agent-infra#1903).

    The exit code is the draft's VERDICT (v3 bounces), not "it ran" — see
    `test_score_file_exits_one_for_a_draft_the_gate_would_bounce`.
    """
    p = tmp_path / "draft.md"
    p.write_text(V3)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    rec = _Recorder()
    monkeypatch.setattr(ao, "sh", rec)
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["--score-file", str(p), "--repeat", "3"])
    text = out.getvalue()
    assert rc == 1, text
    assert "null pair over 3 runs" in text, text
    assert "jargon_free" in text and "spread=0.000" in text, text
    assert rec.calls == [], rec.calls          # nothing was posted anywhere


# ── the gate's own bounce must not be read back as an owner answer ─────────────

def _stub_timeline(monkeypatch, events):
    """Stub the TRANSPORT only: return the rows a real `gh api .../timeline` emits.

    `owner_answered_at` still runs its real parse on them, so the exclusion under
    test is the one the gate actually applies. `events` = [(event, label, at)],
    oldest first.
    """
    rows = "\n".join(f"{ev}\t{at}" for ev, _label, at in events)

    def sh_status(args, timeout=None):
        call = " ".join(str(a) for a in args)
        if "timeline" in call:
            return (0, rows, "")
        if "/comments" in call or "issue view" in call:
            return (0, "2026-10-17T10:00:00Z", "")   # the declaration
        return (0, "", "")

    monkeypatch.setattr(ao, "sh_status", sh_status)


def _timeline_gate(monkeypatch, events, text=V3):
    """Run `main` against the FAKE issue timeline `events` (see `_stub_timeline`)."""
    _stub_timeline(monkeypatch, events)
    rec = _Recorder()
    monkeypatch.setattr(ao, "sh", rec)
    monkeypatch.setattr(ao, "fetch_question", lambda repo, n: text)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["daniel-ospina/agent-infra", "1553"])
    return rc, rec, out.getvalue()


def test_a_bounce_is_not_read_back_as_an_owner_answer(monkeypatch):
    """The bounce removes `owner-decision`; that removal must not BE the answer.

    Pre-fix (measured on the pre-fix module): a bounce writes `--remove-label
    owner-decision` in the same call as `question-bounced`, `owner_answered_at` read
    that `unlabeled` event as the owner's reply, and the NEXT tick printed `ANSWERED`,
    stamped `owner-answered,answer-delivered` (a permanent skip) and cleared
    `question-bounced` — a question the gate had just bounced became a settled
    question nobody answered, and the lane was told a ruling existed.
    """
    # What the timeline looks like one tick AFTER the gate bounced the question:
    # declaration 10:00, the gate's own bounce 10:05 (label added + queue label
    # removed in ONE api call, hence the same timestamp), no human action at all.
    events = [
        ("labeled", "owner-decision", "2026-10-17T09:00:00Z"),
        ("unlabeled", "owner-decision", "2026-10-17T10:05:00Z"),
        ("labeled", "question-bounced", "2026-10-17T10:05:00Z"),
    ]
    _stub_timeline(monkeypatch, events)
    assert ao.owner_answered_at("daniel-ospina/agent-infra", 1553) == "", \
        "the gate's own bounce removal must not read as an owner answer"
    rc, rec, out = _timeline_gate(monkeypatch, events)
    assert "ANSWERED" not in out, out
    assert rc == 1, out                       # still BOUNCED, not settled
    assert not [c for c in rec.find("edit") if "answer-delivered" in " ".join(c)], rec.calls


def test_an_answer_after_a_bounce_is_still_delivered(monkeypatch):
    """The exclusion must not swallow a REAL answer: a removal newer than the bounce."""
    events = [
        ("unlabeled", "owner-decision", "2026-10-17T10:05:00Z"),   # the gate's bounce
        ("labeled", "question-bounced", "2026-10-17T10:05:00Z"),
        ("unlabeled", "owner-decision", "2026-10-17T11:30:00Z"),   # the owner, later
    ]
    _stub_timeline(monkeypatch, events)
    assert ao.owner_answered_at("daniel-ospina/agent-infra", 1553) == "2026-10-17T11:30:00"
    rc, rec, out = _timeline_gate(monkeypatch, events)
    assert "ANSWERED" in out, out
    assert rc == 0, out
    assert [c for c in rec.find("edit") if "answer-delivered" in " ".join(c)], rec.calls


# ── punctuation is not a gloss ────────────────────────────────────────────────

def test_bracketing_a_reference_does_not_launder_it():
    """A bare `(`, `[` or em dash is not an explanation.

    Pre-fix: those punctuation marks satisfied the AFTER-gloss pattern on their own,
    so wrapping each reference laundered the text — measured on this suite's own V3
    draft, `reconciled (#1553) and re-run (`eval`)` scored jargon_free 1.0 against
    0.25 for the identical text unbracketed. Two keystrokes defeated the mark whose
    whole job is that a lane SIMPLIFIES instead of decorating.
    """
    for wrapped in (
        "The rows were reconciled (#1553) and re-run (`eval`). See (agent-infra#1903).",
        "The rows were reconciled [#1553] and re-run [`eval`]. See [agent-infra#1903].",
        "The rows were reconciled — #1553 — and re-run — `eval`. See — agent-infra#1903.",
    ):
        score, findings = ao.jargon_free_score(wrapped)
        counted = [tok for _, tok in findings]
        assert score < BAR, (wrapped, score)
        assert "#1553" in counted and "eval" in counted, (wrapped, counted)


def test_a_bracketed_explanation_still_counts_as_explained():
    """The same brackets OPEN a real gloss — "#1903 (the PR where …)" is explained.

    This is the half that makes the fix above a tightening and not a blanket ban: the
    reader who writes what the thing is still passes.
    """
    for text in (
        "See #1903 (the PR where eight rewrites were scored).",
        "See #1903 [the pull request where eight rewrites were scored].",
        "See #1903 — the ticket where eight rewrites were scored.",
        "It was measured on the script scripts/ask-owner.py, the script that scores.",
    ):
        score, findings = ao.jargon_free_score(text)
        assert findings == [], (text, findings)
        assert score == 1.0, (text, score)


# ── `--score-file` exits with the VERDICT, not "it ran" ──────────────────────

def test_score_file_exits_one_for_a_draft_the_gate_would_bounce(monkeypatch, tmp_path):
    """The offline pre-flight must not exit 0 for a draft that bounces.

    Pre-fix it returned 0 on every path, so `--score-file` — advertised as the
    replacement for "post it to the PR and run the gate" — told a lane (or a CI step
    branching on the exit code) that a failing draft was fine.
    """
    p = tmp_path / "draft.md"
    p.write_text(V3)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["--score-file", str(p)])
    assert rc == 1, out.getvalue()
    assert "would BOUNCE" in out.getvalue(), out.getvalue()


def test_score_file_exits_two_when_it_cannot_check(monkeypatch, tmp_path):
    """No Jev key = NOT a pass (exit 2), even when the mechanical marks clear.

    Pre-fix the run printed "this is NOT a pass" and then returned 0 — the
    empty/UNKNOWN-read-as-green failure this file is built to refuse.
    """
    p = tmp_path / "draft.md"
    p.write_text(V9)
    monkeypatch.setattr(ao, "jev", lambda state: None)
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["--score-file", str(p)])
    assert rc == 2, out.getvalue()
    assert "could not check" in out.getvalue(), out.getvalue()


def test_score_file_exits_zero_for_a_draft_that_passes(monkeypatch, tmp_path):
    """The pass path is unchanged: a clean draft with Jev reachable exits 0."""
    p = tmp_path / "draft.md"
    p.write_text(V9)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    out = io.StringIO()
    with redirect_stdout(out):
        rc = ao.main(["--score-file", str(p)])
    assert rc == 0, out.getvalue()


# ── the offline instrument scores the same TEXT the gate sees ─────────────────

def test_score_file_scores_the_same_text_as_the_gate(monkeypatch, tmp_path):
    """One strip, not two: `--score-file` must score the text the gate scores.

    Pre-fix `score_text` stripped the declaration and `language_marks` stripped it
    again, so a question whose PROSE quotes a `RESEARCH:` line (exactly what a lane
    does when it quotes the NO_RESEARCH template back) was scored with that line
    removed — a reference the gate counts disappeared in the offline run, including
    the null-pair run the owner ruling asks for.
    """
    # A second "RESEARCH:" line inside the prose: the declaration strip removes only
    # the FIRST one, so the quoted one must still be visible to the mark — and it
    # carries a reference that appears NOWHERE else, so its presence/absence in the
    # offline output is the whole signal (a token already in the text would make this
    # assertion pass either way).
    text = V9 + "\nRESEARCH: see agent-infra#1903 for the measurement.\n"
    live, _ = ao.language_marks(text)
    p = tmp_path / "draft.md"
    p.write_text(text)
    monkeypatch.setattr(ao, "jev", lambda state: {
        "answers": {m: {"type": "noul", "noul": 0.99} for m in ao.QUESTIONS},
        "usage": {"cost_usd": 0.0},
    })
    out = io.StringIO()
    with redirect_stdout(out):
        ao.main(["--score-file", str(p)])
    printed = out.getvalue()
    expected = [tok for _, tok in ao.language_marks(text)[1]["jargon_free"][1]]
    assert "agent-infra#1903" in expected, expected   # counted LIVE (one strip)
    live_score = live["jargon_free"]["noul"]
    assert live_score < 1.0, live
    offline = [ln for ln in printed.splitlines() if ln.strip().startswith("jargon_free")]
    assert offline, printed
    assert float(offline[0].split()[-1]) == live_score, (offline, live_score, printed)


def test_a_url_is_not_internal_shorthand():
    """A URL is a citation the reader can open; the declaration's `refs=` is its home."""
    counted = [tok for _, tok in ao.unexplained_references(
        "The measurement is in https://example.com/docs/measurements.md and that is all.")]
    assert counted == [], counted


def test_headings_do_not_dilute_the_sentence_average():
    """A heading is not a two-word sentence: counting it would quietly raise the score."""
    prose = "\n".join(["## What happened"] + [" ".join(["word"] * 55) + "."] * 2)
    marks, _ = _marks(prose)
    assert marks["understandable"] < BAR, marks
