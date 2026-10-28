"""A bounce label is a PROJECTION; the thread is the record. These lines pin which one wins.

Regression guard for agent-infra#2844 — `question-bounced` has no single writer, and a
stale one makes a DELIVERED owner answer read as undelivered.

⚠️ THE ISSUE'S HEADLINE PREMISE IS CORRECTED HERE, NOT ENCODED. It claims "no script in
either tree writes this label", so a SECOND writer re-labelled an answered issue 8 minutes
after a lane cleared it. The timeline it cites refutes that: on
`tortoise#9964` every `labeled question-bounced` is preceded 2-3 s earlier by a `commented`
event (15:49:15->15:49:18, 17:09:02->17:09:05, 21:14:38->21:14:40), which is
`ask-owner.py`'s own comment-then-label sequence, three times running. The writer IS single,
and `test_one_writer_is_named` is what keeps it single.

What survives — and is what these tests are for — is the READER: a mutable current-state
projection read as authority while the durable record of how it got that way sat unread in
the same process. Measured 2026-10-29 across the three repos: of the 26 OPEN issues
carrying `question-bounced`, 22 had thread activity NEWER than the label's own event.

Every leg states the behaviour it would have had before the fix, so the guard is not
vacuous.
"""
import importlib.util
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bs = _load("bounce_state_under_test", "_bounce_state.py")
ua = _load("undelivered_answers_under_test", "undelivered-answers.py")
tc = _load("turn_classify_bounce_under_test", "turn-classify.py")


# ── fixtures: the real incident, and the shapes around it ─────────────────────────────
# tortoise#9964, verbatim from `gh api .../timeline` — the issue's own evidence, used as
# the fixture so the guard cannot drift away from the case that produced it.
INCIDENT = [
    ("commented", "", "2026-10-25T15:49:15Z"),
    ("labeled", "question-bounced", "2026-10-25T15:49:18Z"),
    ("commented", "", "2026-10-25T17:01:28Z"),
    ("unlabeled", "question-bounced", "2026-10-25T17:01:36Z"),
    ("commented", "", "2026-10-25T17:09:02Z"),
    ("labeled", "question-bounced", "2026-10-25T17:09:05Z"),
    ("unlabeled", "question-bounced", "2026-10-25T21:06:52Z"),
    ("commented", "", "2026-10-25T21:14:38Z"),
    ("labeled", "question-bounced", "2026-10-25T21:14:40Z"),
    # the thread then moved on a day later and the label never did:
    ("commented", "", "2026-10-26T02:39:47Z"),
    ("commented", "", "2026-10-26T13:56:11Z"),
]


# ── the definition itself ────────────────────────────────────────────────────────────
def test_a_comment_after_the_bounce_supersedes_the_label():
    """Pre-fix there was no such notion at all — the label's presence WAS the state."""
    v = bs.parse(INCIDENT)
    assert v.state == bs.SUPERSEDED, v
    assert v.bounce_at == "2026-10-25T21:14:40Z"
    assert v.moved_at == "2026-10-26T13:56:11Z"
    assert "comment" in v.moved_by
    assert v.stale is True


def test_an_untouched_bounce_is_current():
    """The anti-over-fix control: a bounce that IS the newest word must keep its authority,
    or every leg below would pass by treating all labels as stale."""
    v = bs.parse(INCIDENT[:9])           # up to and including the last `labeled`
    assert v.state == bs.CURRENT, v
    assert v.stale is False


def test_no_bounce_at_all_is_absent_not_an_error():
    v = bs.parse([("commented", "", "2026-10-25T15:49:15Z")])
    assert v.state == bs.ABSENT
    assert v.stale is False


def test_the_lane_clearing_the_label_also_supersedes_it():
    """`unlabeled question-bounced` is the handshake's own re-submit step. It is movement."""
    v = bs.parse([("labeled", "question-bounced", "2026-10-01T10:00:00Z"),
                  ("unlabeled", "question-bounced", "2026-10-01T10:05:00Z")])
    assert v.state == bs.SUPERSEDED
    assert "cleared" in v.moved_by


def test_removals_are_counted_only_after_the_newest_bounce():
    """`agent-infra#1903`: a bounce removes `owner-decision`, so a removal BEFORE the newest
    bounce is the gate's own and is not an answer. The count the old reader computed locally
    is preserved here — it is the ATTRIBUTION that changed, not the arithmetic."""
    rows = [("unlabeled", "owner-decision", "2026-10-01T09:00:00Z"),   # earlier: not ours
            ("labeled", "question-bounced", "2026-10-01T10:00:00Z"),
            ("unlabeled", "owner-decision", "2026-10-01T11:00:00Z"),   # after: candidate
            ("unlabeled", "owner-decision", "2026-10-01T12:00:00Z")]
    assert bs.parse(rows).removals_after_bounce == 2


def test_a_malformed_row_cannot_make_a_label_look_current():
    """Rows with no timestamp are DROPPED. Treating one as "now" would silently pin every
    label to CURRENT, i.e. re-arm the defect on a formatting bug."""
    rows = INCIDENT + [(None, None, None), ("commented", "", "   "), "not-a-row"]
    assert bs.parse(rows).state == bs.SUPERSEDED


@pytest.mark.parametrize("exc", [RuntimeError("gh vanished"), subprocess.TimeoutExpired("gh", 30)])
def test_a_failed_read_is_unknown_never_current(exc):
    def run(_argv):
        raise exc
    v = bs.bounce_view("o/r", 1, run)
    assert v.state == bs.UNKNOWN
    assert v.read is False
    assert v.stale is False            # staleness must never be inferred from a failure


def test_a_nonzero_rc_is_unknown():
    assert bs.bounce_view("o/r", 1, lambda _a: (1, "")).state == bs.UNKNOWN


# ── item 3 of the issue: ONE writer, named, and enforced ─────────────────────────────
_BOUNCE_REFS = ("BOUNCE_LABEL", "BOUNCE", "_bounce_state.BOUNCE")
_CODE = (".py", ".sh", ".mjs", ".cjs", ".js", ".ts", ".bash")
_SKIP_DIRS = ("tests/", "node_modules/", ".worktrees/", "skills/", "docs/")


def _tracked_code_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True,
                         text=True, timeout=60).stdout
    for rel in out.splitlines():
        if not rel.endswith(_CODE) or rel.startswith(_SKIP_DIRS) or "/test_" in rel \
                or rel.startswith("test_") or "_test." in rel or ".test." in rel:
            continue
        yield rel


def _py_write_lines(src):
    """Line numbers of CALLS that pass `--add-label` together with a bounce reference.

    Parsed, not grepped: `scripts/_bounce_state.py` DOCUMENTS the gate's write
    ("`gh issue edit --add-label question-bounced`") in the paragraph that names the
    single writer, and a text scan would read that required sentence as a second
    writer. Only a CALL can write a label, so only a call is scanned.
    """
    import ast
    import warnings
    hits = []
    with warnings.catch_warnings():
        # ask-owner.py carries `"\(...)"` jq filters in plain strings (a pre-existing
        # SyntaxWarning on 3.12). Parsing it must not turn that into test noise.
        warnings.simplefilter("ignore", SyntaxWarning)
        tree = ast.parse(src)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        atoms = set()
        for sub in ast.walk(node):
            if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                atoms.add(sub.value)
            elif isinstance(sub, ast.Name):
                atoms.add(sub.id)
            elif isinstance(sub, ast.Attribute):
                atoms.add(sub.attr)
        if not any("--add-label" in a for a in atoms):
            continue
        if any(ref in a or "question-bounced" in a for a in atoms for ref in _BOUNCE_REFS):
            hits.append(node.lineno)
    return hits


def _shell_write_lines(src):
    """Same question for non-Python sources, on non-comment lines only."""
    hits = []
    for i, line in enumerate(src.splitlines(), 1):
        s = line.strip()
        if s.startswith("#") or s.startswith("//") or s.startswith("*"):
            continue
        if "--add-label" in s and ("question-bounced" in s
                                    or any(r in s for r in _BOUNCE_REFS)):
            hits.append(i)
    return hits


def test_one_writer_is_named():
    """⛔ THE INVARIANT, NOT THE COMMENT. The issue's item 3 asks that if the label stays
    authoritative, its single writer is NAMED. Naming it in prose is a note; this is the
    enforcement — a second writer appearing anywhere in the tree fails the suite.

    Scans tracked code (tests excluded — this file necessarily contains what it searches
    for) and reads CALLS for Python sources, so a constant-based write
    (`--add-label, BOUNCE_LABEL`) is caught while the documentation that names the writer
    is not mistaken for one.
    """
    writers = {}
    for rel in _tracked_code_files():
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        hits = _py_write_lines(src) if rel.endswith(".py") else _shell_write_lines(src)
        if hits:
            writers[rel] = hits
    assert set(writers) == {"scripts/ask-owner.py"}, (
        "`question-bounced` must have exactly ONE writer (scripts/ask-owner.py); found %s. "
        "A second writer of this label is the defect class agent-infra#2844 is about — if "
        "the new write is deliberate, the shared derivation in scripts/_bounce_state.py and "
        "both its readers have to be widened with it" % sorted(writers))
    # ...and the writer must really be the gate's TWO bounce paths, not one write that
    # happens to satisfy the set. STEP 1 (no declaration) and STEP 2 (failed marks).
    assert len(writers["scripts/ask-owner.py"]) >= 2, writers


# ── reader 1: undelivered-answers.py — report the contradiction, do not resolve it ────
def _issue(number, labels):
    return {"number": number,
            "labels": [{"name": n} for n in labels],
            "state": "open", "title": "t", "updatedAt": "2026-10-29T00:00:00Z"}


def _wire_view(monkeypatch, view):
    monkeypatch.setattr(ua, "bounce_view", lambda _repo, _n: view)
    monkeypatch.setattr(ua, "declaration_count", lambda _repo, _n: 1)


def test_a_stale_bounce_is_reported_as_a_contradiction(monkeypatch):
    """THE INCIDENT. An issue carrying a recorded answer (`owner-answered`) whose bounce label
    was overtaken by the thread used to be reported as "question-bounced left on (the lane must
    clear it)" — a claim of fault made from a projection the record contradicts."""
    _wire_view(monkeypatch, bs.parse(INCIDENT))
    blockers, _lanes = ua.diagnose("o/r", _issue(9964, ["owner-answered", "question-bounced",
                                                       "lane:5"]))
    joined = " | ".join(blockers)
    assert "CONTRADICTION" in joined, joined
    assert "must clear it" not in joined, joined
    # the evidence it cites is the timeline's, not a guess
    assert "2026-10-25T21:14:40" in joined and "2026-10-26T13:56:11" in joined, joined


def test_a_current_bounce_keeps_the_original_claim(monkeypatch):
    """Anti-over-fix control: an untouched bounce IS the lane's to clear, and saying so is
    correct. Without this leg the one above would pass by never naming a fault at all."""
    _wire_view(monkeypatch, bs.parse(INCIDENT[:9]))
    blockers, _ = ua.diagnose("o/r", _issue(1, ["owner-answered", "question-bounced"]))
    assert "question-bounced left on (the lane must clear it)" in blockers, blockers
    assert not any("CONTRADICTION" in b for b in blockers), blockers


def test_a_removal_after_a_stale_bounce_is_not_blamed_on_the_gate(monkeypatch):
    """`agent-infra#1903`'s rule ("a removal while `question-bounced` is present is the gate's
    own bounce") was applied to the LABEL'S PRESENCE, so it held on a bounce about to be a day
    old. A removal that post-dates a superseded bounce is a candidate owner answer, and the
    honest report is that it is not countable — NOT that the gate wrote it, and NOT that the
    answer was delivered (that would be a false PASS: the gate still keys on the label)."""
    rows = INCIDENT + [("unlabeled", "owner-decision", "2026-10-26T14:00:00Z")]
    _wire_view(monkeypatch, bs.parse(rows))
    blockers, _ = ua.diagnose("o/r", _issue(2, ["owner-answered", "question-bounced"]))
    joined = " | ".join(blockers)
    assert "gate's own bounce" not in joined, joined
    assert "candidate owner answer" in joined, joined
    # ...and it must NOT be counted as delivered/pending, which would hide the row.
    assert blockers != ["DELIVERED"] and not blockers[0].startswith("PENDING"), blockers


def test_an_unreadable_timeline_still_refuses_to_judge(monkeypatch):
    """The fail-closed leg that must survive the change: UNKNOWN is not evidence."""
    _wire_view(monkeypatch, None)
    blockers, _ = ua.diagnose("o/r", _issue(3, ["owner-answered"]))
    assert "UNVERIFIED: could not read timeline" in blockers, blockers


def test_the_receipt_still_wins(monkeypatch):
    """`answer-delivered` is written only by the gate and is its own idempotency proof. A stale
    label on a DELIVERED issue is not an undelivered answer, and this tool must not say it is."""
    _wire_view(monkeypatch, bs.parse(INCIDENT))
    blockers, _ = ua.diagnose("o/r", _issue(4, ["answer-delivered", "question-bounced"]))
    assert blockers == ["DELIVERED"], blockers


# ── reader 2: turn-classify.py — a stale bounce may not silence a protocol nudge ──────
def _wire_lists(monkeypatch, issues, view):
    """Serve the issue-list reads (one repo) and the lane-status sample from one `sh`.

    The listing is served ONLY for the `question-bounced` query: every other label must come
    back empty, or `lanes_with_open_question` would add the lane from a different branch and
    every leg below would pass without testing the bounce path at all.
    """
    def fake_sh(argv, timeout=120):
        if any(str(a).endswith("lane-status.py") for a in argv):
            return 0, "[]"
        argv = [str(a) for a in argv]
        label = argv[argv.index("--label") + 1] if "--label" in argv else ""
        return 0, __import__("json").dumps(issues if label == bs.BOUNCE else [])
    monkeypatch.setattr(tc, "REPOS", ("fake/repo",))
    monkeypatch.setattr(tc, "sh", fake_sh)
    monkeypatch.setattr(tc, "log", lambda *a, **k: None)
    # ⛔ PATCH THE MODULE TURN-CLASSIFY HOLDS, not the one this test loaded. Both are the
    # same FILE, but `importlib` gives each loader its own module object, so patching the
    # test's copy would leave the code under test reading the real timeline — exactly the
    # kind of green that proves nothing.
    monkeypatch.setattr(tc.bs, "bounce_view", lambda _r, _n, _run: view)
    return fake_sh


_ISSUES = [{"number": 7, "labels": [{"name": "lane:L1"}, {"name": "question-bounced"}]}]


def test_a_superseded_bounce_is_not_counted_as_protocol_used(monkeypatch):
    """⛔ THE COST OF A STALE LABEL, CORRECTED. The issue says a stale label produces a
    duplicate owner question; it does not — `used_protocol` only ever SUPPRESSES the
    `question_no_protocol` nudge. The real cost is the opposite: a lane asking a FRESH
    question without the protocol is never told to use it, and the question stays in a
    conversation. Pre-fix, `holds` contained L1 here."""
    _wire_lists(monkeypatch, _ISSUES, bs.parse(INCIDENT))
    holds, ok = tc.lanes_with_open_question()
    assert ok is True
    assert "lane:L1" not in holds, holds


def test_a_current_bounce_is_still_counted(monkeypatch):
    """Anti-over-fix control: the handshake still works. A lane whose bounce IS the newest word
    did use the protocol, and must not be nagged for it."""
    _wire_lists(monkeypatch, _ISSUES, bs.parse(INCIDENT[:9]))
    holds, _ = tc.lanes_with_open_question()
    assert "lane:L1" in holds, holds


def test_an_unreadable_bounce_state_keeps_the_label(monkeypatch):
    """A nudger that messages on a read it could not perform is asserting state it does not
    have. UNKNOWN therefore behaves exactly like CURRENT."""
    _wire_lists(monkeypatch, _ISSUES, bs.View(bs.UNKNOWN))
    holds, _ = tc.lanes_with_open_question()
    assert "lane:L1" in holds, holds


def test_a_lane_the_registry_does_not_hold_costs_no_read(monkeypatch):
    """The bound. `used_protocol` is only ever consulted for a registry row, so an issue on a
    lane this pass cannot classify must not spend a timeline read — and must still report the
    label's answer, because `holds` is also the log line that says a question is queued."""
    read = []
    _wire_lists(monkeypatch, _ISSUES, bs.parse(INCIDENT))
    monkeypatch.setattr(tc, "bounce_still_current",
                        lambda repo, n: read.append(n) or False)
    holds, _ = tc.lanes_with_open_question({"lane:SOMETHING-ELSE"})
    assert read == [], "a lane outside the registry was still read"
    assert "lane:L1" in holds, holds


def test_a_registered_lane_is_read_and_excluded_when_stale(monkeypatch):
    """...and the control: same fixture, same lane, only the bound differs."""
    read = []
    _wire_lists(monkeypatch, _ISSUES, bs.parse(INCIDENT))
    monkeypatch.setattr(tc, "bounce_still_current",
                        lambda repo, n: read.append(n) or False)
    holds, _ = tc.lanes_with_open_question({"lane:L1"})
    assert read == [7], read
    assert "lane:L1" not in holds, holds


def _drive(monkeypatch, tmp_path, view):
    """Run `main()` over one stopped lane with the REAL `lanes_with_open_question`, so the
    coupling the fix changes — label state -> `used_protocol` -> nudge kind — is the thing
    exercised. Everything past that seam is stubbed."""
    sess = tmp_path / "session.jsonl"
    size = sess.write_text(
        __import__("json").dumps({"message": {"role": "assistant", "content": [
            {"type": "text", "text": "Should I use the older table or re-run the load?"}]}}) + "\n")
    fake = _wire_lists(monkeypatch, _ISSUES, view)

    def sh(argv, timeout=120):
        if any(str(a).endswith("lane-status.py") for a in argv):
            return 0, __import__("json").dumps([{
                "lane": "L1", "ws": "WS1", "sid": "sid-1", "size": size,
                "verdict": "WEDGED", "file": str(sess), "child": None}])
        return fake(argv, timeout)

    monkeypatch.setattr(tc, "sh", sh)
    monkeypatch.setattr(tc, "KILL", str(tmp_path / "TURN-CLASSIFY-OFF-nope"))
    monkeypatch.setattr(tc, "registry", lambda: [{"lane": "L1", "ws": "WS1",
                                                  "issue_label": "lane:L1"}])
    monkeypatch.setattr(tc, "lane_cwd", lambda _f: None)
    monkeypatch.setattr(tc, "read_marker", lambda _lane: {})
    monkeypatch.setattr(tc, "write_marker", lambda *a, **k: None)
    monkeypatch.setattr(tc, "jev_choice",
                        lambda _s: ("asked_the_owner", {"confidence": 0.95}))
    sent = []
    monkeypatch.setattr(tc, "send",
                        lambda lane, *a, **k: (sent.append(lane), "WOULD-SEND")[1])
    assert tc.main(["--dry-run", "--lane", "L1"]) == 0
    return sent


def test_a_lane_asking_a_fresh_question_is_told_to_use_the_protocol(monkeypatch, tmp_path):
    """THE END-TO-END LEG. A stale bounce used to make this lane read as "protocol used" and
    no message was sent at all. Pre-fix `sent == []`."""
    assert _drive(monkeypatch, tmp_path, bs.parse(INCIDENT)) == ["L1"]


def test_a_current_bounce_still_silences_the_nudge(monkeypatch, tmp_path):
    """...and the CONTROL that makes the leg above mean something: same harness, same lane,
    same turn — only the bounce's currency differs. The owner's class-2 lane (a question that
    used the protocol) must still be left alone."""
    assert _drive(monkeypatch, tmp_path, bs.parse(INCIDENT[:9])) == []
