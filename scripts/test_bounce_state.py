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
import ast
import importlib.util
import os
import re
import subprocess
import warnings

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
te = _load("turn_end_bounce_under_test", "turn-end.py")


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
    is preserved here — it is the ATTRIBUTION that changed, not the arithmetic.

    ⛔ THE STATE ASSERTION IS NOT DECORATION. This fixture is the shape the review (finding
    2) showed the guard silently accepting as SUPERSEDED: it asserted only the count, so a
    derivation that read the gate's own removal as movement passed unnoticed."""
    rows = [("unlabeled", "owner-decision", "2026-10-01T09:00:00Z"),   # earlier: not ours
            ("labeled", "question-bounced", "2026-10-01T10:00:00Z"),
            ("unlabeled", "owner-decision", "2026-10-01T11:00:00Z"),   # after: candidate
            ("unlabeled", "owner-decision", "2026-10-01T12:00:00Z")]
    v = bs.parse(rows)
    assert v.removals_after_bounce == 2
    assert v.state == bs.CURRENT, (
        "two `unlabeled owner-decision` events and NOTHING else newer than the bounce: "
        "that is the gate's own write, and it cannot supersede the bounce (%r)" % (v,))
    assert v.stale is False


# tortoise#7988, verbatim from `gh api .../timeline` — the case that exposed finding 2.
GATE_OWN_WRITE = [
    ("commented", "", "2026-10-11T22:55:49Z"),
    ("labeled", "question-bounced", "2026-10-11T22:55:51Z"),
    ("unlabeled", "owner-decision", "2026-10-11T22:56:28Z"),   # 37 s LATER — the gate
]


def test_the_gates_own_bounce_write_cannot_supersede_the_bounce():
    """⛔ FINDING 2. `ask-owner.py` writes both bounce paths as ONE `gh issue edit`
    (`--add-label question-bounced --remove-label owner-decision`), but gh applies the add
    and the remove as SEPARATE mutations, so the removal can land AFTER the label it
    belongs to. Measured on `tortoise#7988`: label 22:55:51, removal 22:56:28, nothing in
    between.

    Pre-fix this returned SUPERSEDED with moved_by "a `unlabeled` event on
    `owner-decision`" — the gate's own write reported as a candidate owner answer (the
    #1903 mis-attribution), and the lane dropped out of `holds`, i.e. the false
    `question_no_protocol` nudge this PR exists to remove."""
    v = bs.parse(GATE_OWN_WRITE)
    assert v.state == bs.CURRENT, (v,)
    assert v.stale is False
    # ...and the removal is still COUNTED: the number is evidence, only the supersession
    # claim needs authorship the timeline cannot supply.
    assert v.removals_after_bounce == 1


def test_a_comment_still_supersedes_when_a_queue_removal_is_also_newer():
    """The other half of finding 2: excluding the queue removal must not weaken the rule.
    A real movement still supersedes, and it is the comment — not the unattributable
    removal — that is cited as the reason."""
    v = bs.parse(GATE_OWN_WRITE + [("commented", "", "2026-10-11T23:10:00Z")])
    assert v.state == bs.SUPERSEDED, (v,)
    assert v.moved_by == "a comment", v.moved_by
    assert v.moved_at == "2026-10-11T23:10:00Z", v.moved_at


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
# ⛔ THE SCAN'S POPULATION IS PART OF THE GUARANTEE, SO IT IS THE WIDE ONE. The claim is
# "a second writer ANYWHERE IN THE TREE fails the suite" — and this fleet has two writer
# surfaces that are not `.py`/`.sh`:
#   * a WORKFLOW STEP (`run: gh issue edit … --add-label …`) in a `.yml`/`.yaml` file, and
#   * a SKILL INSTRUCTION — `skills/**/*.md` is a live label-writing surface here
#     (`skills/issue-creation/SKILL.md`, `skills/issue-scoping/SKILL.md`,
#     `skills/commit-workflow/workflow/02-commit-pr.md` all tell a lane to run
#     `gh issue edit … --add-label`).
# Both were outside the pre-fix population, so a writer added there passed the very guard
# the module cites as mechanical enforcement (a false PASS in a new gate). Markdown has no
# AST, so it takes the LINE scan — which is the right reading anyway: a skill that tells a
# lane to write the label IS a writer of the label.
_CODE = (".py", ".sh", ".mjs", ".cjs", ".js", ".ts", ".bash", ".yml", ".yaml")
# `skills/` is NOT skipped: its prose is scanned as calls (see `_CODE`). `docs/` stays out —
# it is a record of what was decided, never an instruction a lane executes.
_SKILL_DOCS = ("skills/",)
_SKIP_DIRS = ("tests/", "node_modules/", ".worktrees/", "docs/")


def _tracked_code_files():
    """Every tracked file a `question-bounced` write could plausibly live in.

    Three classes, and all three are load-bearing: code (`.py`/`.sh`/`.mjs`/`.js`/`.ts`/
    `.bash`), workflows (`.yml`/`.yaml`), and skill instructions (`skills/**/*.md`).
    """
    out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True,
                         text=True, timeout=60).stdout
    for rel in out.splitlines():
        skill_doc = rel.startswith(_SKILL_DOCS) and rel.endswith(".md")
        if rel.startswith(_SKIP_DIRS) or "/test_" in rel or rel.startswith("test_") \
                or "_test." in rel or ".test." in rel:
            continue
        if rel.endswith(_CODE) or skill_doc:
            yield rel


def _argv_literal(node):
    """The string a positional argv element denotes, when it is STATICALLY knowable.

    Three shapes appear in real call sites: a plain Constant (`"--add-label"`), a NAME
    (`BOUNCE_LABEL` — returned as its identifier, which is how the guard recognises the
    label without importing the gate), and a `+` of those
    (`ANSWERED_LABEL + "," + DELIVERED_LABEL`). Anything else is None: unknown is not a
    hit, and the guard must never guess a write into existence.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _argv_literal(node.left), _argv_literal(node.right)
        if left is not None and right is not None:
            return left + right
    return None


def _argv_sequences(node):
    """Every argument sequence this call could be passing, as element lists.

    A call site builds its argv either as ONE list/tuple literal (`sh(["gh", …])` — every
    site in this tree) or as separate positional args (`sh("gh", …)`), so both are
    scanned. Nested literals are included, so a `sh(base + ["--add-label", X])` shape is
    read element-wise too.
    """
    seqs = [list(sub.elts) for sub in ast.walk(node)
            if isinstance(sub, (ast.List, ast.Tuple))]
    if not seqs:
        seqs = [list(node.args)]
    return seqs


def _is_bounce_write_call(node):
    """True iff this call ADDS the bounce label — i.e. the ref is the `--add-label`
    OPERAND, not merely somewhere in the call.

    ⛔ THE OPERAND TEST IS THE WHOLE POINT. `ask-owner.py`'s PASS path writes
    `--add-label owner-decision --remove-label BOUNCE_LABEL` — it REMOVES the bounce, and
    a scan over "any atom in the call" counted it as a bounce WRITER. That inflated the
    count to 3, so the `>= 2` assertion still passed with STEP 1's real write deleted:
    the guard was vacuous against the exact regression it names (#2844 review, finding 3).
    """
    for seq in _argv_sequences(node):
        for i, arg in enumerate(seq):
            flag = _argv_literal(arg)
            if flag is None:
                continue
            if flag.startswith("--add-label="):
                operand = flag.split("=", 1)[1]
            elif flag == "--add-label":
                operand = _argv_literal(seq[i + 1]) if i + 1 < len(seq) else None
            else:
                continue
            if operand and ("question-bounced" in operand
                            or any(r in operand for r in _BOUNCE_REFS)):
                return True
    return False


def _py_write_lines(src):
    """Line numbers of CALLS whose `--add-label` OPERAND is the bounce label.

    Parsed, not grepped: `scripts/_bounce_state.py` DOCUMENTS the gate's write
    ("`gh issue edit --add-label question-bounced`") in the paragraph that names the
    single writer, and a text scan would read that required sentence as a second
    writer. Only a CALL can write a label, so only a call is scanned.

    A call counts only when the bounce ref is added — see `_is_bounce_write_call`; a call
    that only REMOVES it is the opposite of a writer.
    """
    hits = []
    with warnings.catch_warnings():
        # ask-owner.py carries `"\(...)"` jq filters in plain strings (a pre-existing
        # SyntaxWarning on 3.12). Parsing it must not turn that into test noise.
        warnings.simplefilter("ignore", SyntaxWarning)
        tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _is_bounce_write_call(node):
            hits.append(node.lineno)
    return hits


def _shell_write_lines(src):
    """Same question for non-Python sources, on non-comment lines only.

    Same operand rule as the Python scan: `--add-label` must be followed by the bounce
    ref on that line, so `--add-label owner-decision --remove-label question-bounced`
    (a REMOVAL) is not miscounted as a write.
    """
    hits = []
    for i, line in enumerate(src.splitlines(), 1):
        s = line.strip()
        if s.startswith("#") or s.startswith("//") or s.startswith("*"):
            continue
        for m in re.finditer(r"--add-label(?:=|\s+)(\S*)", s):
            operand = m.group(1)
            if "question-bounced" in operand or any(r in operand for r in _BOUNCE_REFS):
                hits.append(i)
                break
    return hits


def test_one_writer_is_named():
    """⛔ THE INVARIANT, NOT THE COMMENT. The issue's item 3 asks that if the label stays
    authoritative, its single writer is NAMED. Naming it in prose is a note; this is the
    enforcement — a second writer appearing anywhere in the tree fails the suite.

    Scans tracked code, workflows AND skill instructions (tests excluded — this file
    necessarily contains what it searches for), and reads CALLS for Python sources, so a
    constant-based write (`--add-label, BOUNCE_LABEL`) is caught while the documentation
    that names the writer is not mistaken for one.
    """
    writers = {}
    for rel in _tracked_code_files():
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        hits = _scan(rel, src)
        if hits:
            writers[rel] = hits
    assert set(writers) == {"scripts/ask-owner.py"}, (
        "`question-bounced` must have exactly ONE writer (scripts/ask-owner.py); found %s. "
        "A second writer of this label is the defect class agent-infra#2844 is about — if "
        "the new write is deliberate, the shared derivation in scripts/_bounce_state.py and "
        "all THREE of its readers have to be widened with it" % sorted(writers))
    # ...and the writer must really be the gate's TWO BOUNCE PATHS — STEP 1 (no
    # declaration) and STEP 2 (failed marks) — not one write that happens to satisfy the
    # set. ⛔ A bare COUNT is not enough: the PASS path also names the label (it REMOVES
    # it), so under a "ref anywhere in the call" scan this read 3 and survived STEP 1's
    # deletion. Count AND region, so a lost write cannot hide behind a removal.
    hits = writers["scripts/ask-owner.py"]
    assert len(hits) == 2, ("ask-owner.py must carry exactly TWO bounce writes (STEP 1 and "
                            "STEP 2); the PASS path REMOVES the label and is not a writer. "
                            "Found hits at %s" % hits)
    step1, step2 = _bounce_region_bounds()
    assert [1 for h in hits if step1 <= h < step2] == [1], (
        "STEP 1 must own exactly one bounce write; hits at %s, STEP 1 region is "
        "lines %d-%d" % (hits, step1, step2 - 1))
    assert [1 for h in hits if h >= step2] == [1], (
        "STEP 2 must own exactly one bounce write; hits at %s, STEP 2 region starts at "
        "line %d" % (hits, step2))


def _bounce_region_bounds():
    """ask-owner.py's (STEP 1 start, STEP 2 start) line numbers, read from the source.

    The regions are located by the gate's own STEP markers rather than by hardcoded line
    numbers, so the assertion survives ordinary edits above them and still fails if a
    whole path's write disappears.
    """
    with open(os.path.join(ROOT, "scripts", "ask-owner.py"), encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    def _marker(name):
        hit = [i for i, ln in enumerate(lines, 1) if ln.strip().startswith(name)]
        assert len(hit) == 1, ("ask-owner.py must carry exactly one %r marker (the regions "
                              "this guard reads); found %s" % (name, hit))
        return hit[0]
    step1, step2 = _marker("# STEP 1"), _marker("# STEP 2")
    assert step1 < step2, (step1, step2)
    return step1, step2


def test_the_writer_scan_ignores_a_call_that_only_REMOVES_the_label():
    """NON-VACUITY, proven against a synthetic call site. This is the PASS path's exact
    shape; the pre-fix scan (any bounce ref anywhere in the call) counted it as a WRITER,
    which is how `>= 2` survived deleting a real write."""
    assert _py_write_lines(
        'sh(["gh", "issue", "edit", "--add-label", "owner-decision",'
        ' "--remove-label", BOUNCE_LABEL])') == []
    # ...and the write it must count, in both shapes the gate actually uses.
    assert _py_write_lines(
        'sh(["gh", "issue", "edit", "--add-label", BOUNCE_LABEL, '
        '"--remove-label", "owner-decision"])') == [1]
    assert _py_write_lines(
        'sh(["gh", "issue", "edit", "--add-label=question-bounced"])') == [1]
    # a NON-bounce add is not a bounce writer either
    assert _py_write_lines(
        'sh(["gh", "issue", "edit", "--add-label", ANSWERED_LABEL])') == []


def test_the_writer_scan_catches_the_missing_STEP_1_write():
    """NON-VACUITY, replayed against the REAL file — the exact regression the assertion
    names. Deleting STEP 1's bounce write leaves PASS (a removal) and STEP 2; the pre-fix
    scan still returned 2 hits and the `>= 2` assertion passed (measured: [1598, 1578])."""
    with open(os.path.join(ROOT, "scripts", "ask-owner.py"), encoding="utf-8") as fh:
        lines = fh.read().splitlines(True)
    step1, step2 = _bounce_region_bounds()
    hits = _py_write_lines("".join(lines))
    victim = next(h for h in hits if step1 <= h < step2)
    assert victim + 1 < step2, "the STEP 1 write must be a two-line call for this replay"
    mutant = "".join(ln for i, ln in enumerate(lines, 1) if i not in (victim, victim + 1))
    assert len(_py_write_lines(mutant)) == 1, (
        "deleting STEP 1's bounce write must leave ONE writer, not two — a removal is not "
        "a writer")


def _scan(rel, src):
    """The ONE dispatch `test_one_writer_is_named`'s loop uses — AST for Python, the line
    scan for everything else (shell, workflows, skill instructions).

    Factored out so the file-class coverage can be exercised directly: a class the loop
    never yields is a class the guarantee does not reach, and that is exactly what was
    wrong before FINDING 2.
    """
    return _py_write_lines(src) if rel.endswith(".py") else _shell_write_lines(src)


def test_the_writer_scan_reaches_a_WORKFLOW_step_and_a_SKILL_instruction():
    """⛔ FINDING 2. The docstring above says a second writer "anywhere in the tree" fails
    the suite, but the pre-fix population was code extensions only and `skills/` was
    skipped — so the TWO writer surfaces this fleet has outside code sat outside the guard:
    a workflow `run:` step, and a skill telling a lane to run `gh issue edit … --add-label`
    (three skills do exactly that today, for other labels). A second writer added there
    passed the very check the module cites as mechanical enforcement — a false PASS in a
    new gate."""
    assert _scan(".github/workflows/ci.yml",
                 "      - run: gh issue edit 1 --repo o/r --add-label question-bounced\n") == [1]
    assert _scan("skills/issue-creation/SKILL.md",
                 "```\ngh issue edit 12 --add-label question-bounced "
                 "--remove-label owner-decision\n```\n") == [2]
    # ...and the anti-over-fix half: a REMOVAL in either class is not a writer, and a
    # non-bounce add is not a bounce writer.
    assert _scan(".github/workflows/ci.yml",
                 "      - run: gh issue edit 1 --add-label owner-decision "
                 "--remove-label question-bounced\n") == []
    assert _scan("skills/x/SKILL.md",
                 "gh issue edit 1 --remove-label question-bounced\n") == []
    assert _scan("skills/x/SKILL.md",
                 "gh issue edit 1 --add-label needs-triage\n") == []


def test_the_scanned_population_includes_workflows_and_skills():
    """...and the population the loop actually WALKS must contain those classes.

    Without this leg the leg above is only a unit test of a helper, and a future narrowing
    of `_CODE`/`_SKIP_DIRS` would silently shrink the guarantee back to code files while
    `test_one_writer_is_named` stayed green — the failure mode FINDING 2 named."""
    paths = set(_tracked_code_files())
    assert any(p.endswith((".yml", ".yaml")) for p in paths), \
        "no workflow file is in the writer scan's population"
    assert any(p.startswith("skills/") and p.endswith(".md") for p in paths), \
        "no skill instruction is in the writer scan's population (skills/ is skipped)"
    assert "scripts/ask-owner.py" in paths
    assert not any(p.startswith("docs/") for p in paths), \
        "docs/ is a RECORD of decisions, never an instruction a lane executes — it must " \
        "stay out or every plan doc quoting the write becomes a false writer"


def test_the_shell_scan_applies_the_same_operand_rule():
    """The shell half had the identical hole: `--add-label owner-decision
    --remove-label question-bounced` matched on "both strings are on the line"."""
    assert _shell_write_lines(
        'gh issue edit 1 --add-label owner-decision --remove-label question-bounced\n') == []
    assert _shell_write_lines(
        'gh issue edit 1 --add-label question-bounced --remove-label owner-decision\n') == [1]


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


# ── reader 3: turn-end.py — a stale bounce may not silence the FALLBACK nudge ─────────
# This is the reader the harness reviewer found still on the presence-only rule (FINDING 1):
# `SKIP_IF_QUESTION = True` + `issue_label in holds_question` → the lane is never nudged, in
# the nudger that runs exactly when `turn-classify.py` does not.
_TE_ISSUES = [{"number": 7, "labels": [{"name": "lane:L1"},
                                        {"name": "question-bounced"}]}]


def _wire_turn_end(monkeypatch, issues, view, owner=None):
    """Serve turn-end's issue-list reads and the shared view; nothing else runs.

    `issues` answers the `question-bounced` query and `owner` the `owner-decision` one, so a
    leg can target either branch without the other leaking its lane into the set.
    """
    def fake_sh(argv, timeout=120):
        argv = [str(a) for a in argv]
        label = argv[argv.index("--label") + 1] if "--label" in argv else ""
        payload = (owner or []) if label == "owner-decision" else \
            (issues if label == bs.BOUNCE else [])
        return 0, __import__("json").dumps(payload)
    monkeypatch.setattr(te, "REPOS", ("fake/repo",))
    monkeypatch.setattr(te, "sh", fake_sh)
    monkeypatch.setattr(te, "log", lambda *a, **k: None)
    # ⛔ PATCH THE MODULE TURN-END HOLDS, not the one this test loaded (same file, different
    # module object under `importlib`) — otherwise the code under test reads the real API.
    monkeypatch.setattr(te.bs, "bounce_view", lambda _r, _n, _run: view)


def test_turn_end_does_not_treat_a_SUPERSEDED_bounce_as_a_held_question(monkeypatch):
    """THE DEFECT. Pre-fix the label's PRESENCE returned the lane and `main()` skipped its
    `WIP-IDLE` continue-nudge, so a bounce the thread had overtaken silenced the fallback
    nudger for a lane holding NO question — 22 of the 26 measured label-carriers were stale."""
    _wire_turn_end(monkeypatch, _TE_ISSUES, bs.parse(INCIDENT))
    assert "lane:L1" not in te.lanes_with_open_question()


def test_turn_end_still_skips_a_CURRENT_bounce(monkeypatch):
    """Control that makes the leg above mean something: same harness, same lane, only the
    bounce's currency differs. The owner's rule — do not nudge a lane that HOLDS a question
    — still applies, and this change must not weaken it."""
    _wire_turn_end(monkeypatch, _TE_ISSUES, bs.parse(INCIDENT[:9]))
    assert "lane:L1" in te.lanes_with_open_question()


def test_turn_end_keeps_the_label_when_the_timeline_could_not_be_read(monkeypatch):
    """A nudger that messages on a read it could not perform is asserting state it does not
    have. UNKNOWN behaves exactly like CURRENT, as it does in the other readers."""
    _wire_turn_end(monkeypatch, _TE_ISSUES, bs.View(bs.UNKNOWN))
    assert "lane:L1" in te.lanes_with_open_question()


def test_turn_end_treats_owner_decision_as_membership_not_a_projection(monkeypatch):
    """`owner-decision` is the queue's LIVE MEMBERSHIP — the thread moving on does not
    contradict it — so it is reported on presence and spends no timeline read. Only
    `question-bounced` is a projection that needs re-validating."""
    read = []
    _wire_turn_end(monkeypatch, [], bs.parse(INCIDENT),
                   owner=[{"number": 9, "labels": [{"name": "lane:L2"},
                                                    {"name": "owner-decision"}]}])
    monkeypatch.setattr(te, "bounce_still_current", lambda r, n: read.append(n) or False)
    assert te.lanes_with_open_question() == {"lane:L2"}
    assert read == [], "owner-decision spent a timeline read"


def test_turn_end_bounds_its_timeline_reads_by_count(monkeypatch):
    """The cost bound. One read per bounced issue is affordable at today's 26, but the
    heartbeat's `run_bounded` allowance is 90 s for the whole tick, so the count is capped —
    and an issue past the cap is treated as CURRENT (fail CLOSED), never dropped, because
    this set is also the log line that says a question is queued."""
    issues = [{"number": n, "labels": [{"name": "lane:L%d" % n},
                                        {"name": "question-bounced"}]}
              for n in range(1, 6)]
    read = []
    _wire_turn_end(monkeypatch, issues, bs.parse(INCIDENT))
    monkeypatch.setattr(te, "MAX_BOUNCE_READS", 2)
    monkeypatch.setattr(te, "bounce_still_current", lambda r, n: read.append(n) or False)
    holds = te.lanes_with_open_question()
    # read ⇒ STALE ⇒ excluded (the fix working); past the cap ⇒ kept, fail closed.
    assert read == [1, 2], read
    assert holds == {"lane:L3", "lane:L4", "lane:L5"}, holds


def test_turn_end_bounds_its_timeline_reads_by_WALL_CLOCK(monkeypatch):
    """...the other bound, which the count alone cannot supply: a gh that HANGS spends the
    tick even at 40 reads. A spent budget therefore reads nothing at all, and every lane
    keeps the label's authority."""
    issues = [{"number": 1, "labels": [{"name": "lane:L1"},
                                        {"name": "question-bounced"}]}]
    read = []
    _wire_turn_end(monkeypatch, issues, bs.parse(INCIDENT))
    monkeypatch.setattr(te, "BOUNCE_BUDGET_S", -1)          # deadline already spent
    monkeypatch.setattr(te, "bounce_still_current", lambda r, n: read.append(n) or False)
    assert te.lanes_with_open_question() == {"lane:L1"}
    assert read == [], read


def test_turn_end_actually_NUDGES_a_lane_whose_bounce_went_stale(monkeypatch, tmp_path,
                                                                 capsys):
    """THE END-TO-END LEG, on the behaviour the finding is about: does the message go out?

    `main()` in `--dry-run` over one `WIP-IDLE` lane carrying a stale bounce. Pre-fix this
    printed nothing at all — the lane was skipped as "holds a question" from the label's
    presence. The control directly below reverses only the bounce's currency."""
    def sh(argv, timeout=120):
        argv = [str(a) for a in argv]
        if any(str(a).endswith("lane-status.py") for a in argv):
            return 0, __import__("json").dumps([{
                "lane": "L1", "ws": "WS1", "sid": "sid-1", "size": 10,
                "verdict": "WIP-IDLE", "stale_s": 3600,
                "issue_label": "lane:L1"}])
        label = argv[argv.index("--label") + 1] if "--label" in argv else ""
        return 0, __import__("json").dumps(_TE_ISSUES if label == bs.BOUNCE else [])
    monkeypatch.setattr(te, "REPOS", ("fake/repo",))
    monkeypatch.setattr(te, "sh", sh)
    monkeypatch.setattr(te, "log", lambda *a, **k: None)
    monkeypatch.setattr(te, "NUDGE_KILL", str(tmp_path / "LANE-NUDGE-OFF-nope"))
    monkeypatch.setattr(te, "read_marker", lambda _lane: {})
    monkeypatch.setattr(te, "session_path", lambda _sid: None)
    monkeypatch.setattr(te.bs, "bounce_view",
                        lambda _r, _n, _run: bs.parse(INCIDENT))
    assert te.main(["--dry-run"]) == 0
    assert "WOULD NUDGE L1" in capsys.readouterr().out


def test_turn_end_still_withholds_the_nudge_for_a_CURRENT_bounce(monkeypatch, tmp_path,
                                                                capsys):
    """...and the control for the leg above: only the bounce's currency differs, and the
    owner's rule (skip a lane that holds a question) must still hold."""
    def sh(argv, timeout=120):
        argv = [str(a) for a in argv]
        if any(str(a).endswith("lane-status.py") for a in argv):
            return 0, __import__("json").dumps([{
                "lane": "L1", "ws": "WS1", "sid": "sid-1", "size": 10,
                "verdict": "WIP-IDLE", "stale_s": 3600,
                "issue_label": "lane:L1"}])
        label = argv[argv.index("--label") + 1] if "--label" in argv else ""
        return 0, __import__("json").dumps(_TE_ISSUES if label == bs.BOUNCE else [])
    monkeypatch.setattr(te, "REPOS", ("fake/repo",))
    monkeypatch.setattr(te, "sh", sh)
    monkeypatch.setattr(te, "log", lambda *a, **k: None)
    monkeypatch.setattr(te, "NUDGE_KILL", str(tmp_path / "LANE-NUDGE-OFF-nope"))
    monkeypatch.setattr(te, "read_marker", lambda _lane: {})
    monkeypatch.setattr(te, "session_path", lambda _sid: None)
    monkeypatch.setattr(te.bs, "bounce_view",
                        lambda _r, _n, _run: bs.parse(INCIDENT[:9]))
    assert te.main(["--dry-run"]) == 0
    assert "WOULD NUDGE" not in capsys.readouterr().out


def test_turn_end_reads_the_timeline_through_ITS_OWN_gh_layer(monkeypatch):
    """⛔ #1988 AT THE THIRD READER. `_bounce_state.bounce_view` emits `["gh", "api", …]`
    and its docstring says the CALLER owns the resolution. Passing that argv through
    unchanged would run the bare `gh` from PATH — past the seeded shims, unserialised,
    against the account four boxes share — and this is a per-tick, per-bounced-issue path.
    The sibling reader's slip of exactly this kind was an earlier review finding."""
    seen = []

    def fake(argv, timeout=None):
        seen.append(list(argv))
        return 0, ("commented\t\t2026-10-11T22:00:00Z\n"
                   "labeled\tquestion-bounced\t2026-10-11T22:00:05Z\n")

    monkeypatch.setattr(te, "GH", "/opt/orch/gh-limit/gh")
    monkeypatch.setattr(te, "sh", lambda *_a, **_k: pytest.fail(
        "the bare-name path was taken — `bounce_view`'s argv must be rebound to GH"))
    monkeypatch.setattr(te, "sh_stdout", fake)
    monkeypatch.setattr(te, "log", lambda *a, **k: None)
    assert te.bounce_still_current("o/r", 7) is True
    assert seen == [[
        "/opt/orch/gh-limit/gh", "api",
        "repos/o/r/issues/7/timeline?per_page=100",
        "--paginate", "--jq", bs.TIMELINE_JQ]], seen


def test_turn_end_sh_stdout_keeps_stderr_out_of_the_parse():
    """`turn-end.sh` merges stderr (right for diagnostics, wrong for a parser): a warning
    gh wrote to stderr would be handed to the reduction as if it were a row. This is the
    leg that says the bounce read uses the STDOUT-ONLY variant."""
    rc, out = te.sh_stdout(["/bin/sh", "-c", "echo out; echo err >&2"])
    assert rc == 0
    assert out.strip() == "out", out


# ── the gh seam at reader 2 (#1988), and the jq filter nothing exercised ──────────────
def test_turn_classify_reads_the_timeline_through_ITS_OWN_gh_layer(monkeypatch):
    """⛔ FINDING 1. `_bounce_state.bounce_view` emits `["gh", "api", …]` and its docstring
    says the CALLER owns the resolution — `turn-classify.py`'s ⛔ #1988 header states the
    rule for this very file. Passing the argv through unchanged runs the bare `gh` from
    PATH, which `heartbeat-loop.sh`'s pinned PATH resolves to the REAL gh, past the
    seeded shims: this file's only unserialised call, on a per-tick, per-bounced-issue
    path, against the account four boxes share."""
    seen = []

    def fake(argv, timeout=None):
        seen.append(list(argv))
        return 0, ("commented\t\t2026-10-11T22:00:00Z\n"
                   "labeled\tquestion-bounced\t2026-10-11T22:00:05Z\n")

    monkeypatch.setattr(tc, "GH", "/opt/orch/gh-limit/gh")
    monkeypatch.setattr(tc, "sh", fake)          # the bare-name path must not be taken
    monkeypatch.setattr(tc, "sh_stdout", fake)
    assert tc.bounce_still_current("o/r", 7) is True
    assert seen == [[
        "/opt/orch/gh-limit/gh", "api",
        "repos/o/r/issues/7/timeline?per_page=100",
        "--paginate", "--jq", bs.TIMELINE_JQ]], seen


def test_sh_stdout_keeps_stderr_out_of_the_parse():
    """The second facet of finding 1: `sh` returns stdout+stderr, which is right for the
    diagnostics that print it and wrong for a parser — a warning on stderr would be handed
    to the reduction as a row. `sh_stdout` returns stdout only, and NOTHING on failure."""
    assert tc.sh_stdout(["/bin/sh", "-c", "echo out; echo err >&2"]) == (0, "out\n")
    assert tc.sh_stdout(["/bin/sh", "-c", "exit 3"]) == (3, "")
    assert tc.sh_stdout(["/nonexistent-binary-for-2844"]) == (1, "")


def test_the_real_timeline_jq_filter_still_produces_rows_the_parser_can_read():
    """`TIMELINE_JQ` is a string nobody executes in the suite: `bounce_view` was only ever
    driven with a raising or `rc != 0` fake `run`, so a filter break (a wrong label, a lost
    tab, `|length` coming back) would have been INVISIBLE. Executed here under the real `jq`
    against a real timeline — the same shape `gh api …/timeline` returns."""
    import json
    import shutil
    if not shutil.which("jq"):                                   # pragma: no cover
        pytest.skip("jq not installed")
    timeline = [
        {"event": "commented", "created_at": "2026-10-11T22:55:49Z",
         "body": "has\ta raw tab\tand a %"},
        {"event": "labeled", "label": {"name": "question-bounced"},
         "created_at": "2026-10-11T22:55:51Z"},
        {"event": "labeled", "label": {"name": "lane:L5"},
         "created_at": "2026-10-11T22:55:52Z"},          # not of interest
        {"event": "closed", "created_at": "2026-10-11T22:55:53Z"},   # not of interest
        {"event": "unlabeled", "label": {"name": "owner-decision"},
         "created_at": "2026-10-11T22:56:28Z"},
    ]
    p = subprocess.run(["jq", "-r", bs.TIMELINE_JQ], input=json.dumps(timeline),
                       capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    out = p.stdout
    # one line per event of interest, real tabs, `label=""` for a comment — exactly what
    # `bounce_view` splits on
    assert out.splitlines() == [
        "commented\t\t2026-10-11T22:55:49Z",
        "labeled\tquestion-bounced\t2026-10-11T22:55:51Z",
        "unlabeled\towner-decision\t2026-10-11T22:56:28Z",
    ], repr(out)

    # ...and through `bounce_view` end to end: the parse of REAL jq output is CURRENT,
    # i.e. the gate's own removal landing 37 s after its label does not supersede it.
    v = bs.bounce_view("o/r", 7988, lambda _a: (0, out))
    assert v.state == bs.CURRENT, (v,)
    assert v.bounce_at == "2026-10-11T22:55:51Z"
    assert v.removals_after_bounce == 1
