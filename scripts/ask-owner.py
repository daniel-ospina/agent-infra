#!/usr/bin/env python3
"""
ask-owner — gate a lane's question before it reaches the owner.

The queue is the `owner-decision` label. This script decides whether a question
EARNED that label, and if not, posts back exactly what is missing.

Design rules (deliberate):
  * ONE Jev call. The STRUCTURAL marks only — no judge is asked to grade prose.
  * Jev is decision-only: it cannot return a value outside the schema below,
    so the schema IS the rubric and the gate cannot drift.
  * Fields and DECLARED SHAPES are mechanical; judgement is Jev's. The
    declaration is a field. The two LANGUAGE marks are declared shapes (bare
    paths, unexplained ticket references, unexplained identifiers, sentence
    length) — see THE LANGUAGE MARKS ARE MECHANICAL below for why they are no
    longer sent to Jev at all.
  * A bounce is a TEMPLATE keyed to a fixed choice, plus the exact occurrences
    the mechanical marks counted. Templates cannot be vague, so a bounce can
    never loop; naming the occurrence means a lane never has to guess which
    axis to fix.

Usage:
    python3 ask-owner.py <owner/repo> <issue-number> [--dry-run]
    python3 ask-owner.py --scan [--dry-run]
    python3 ask-owner.py --score-file <path> [--repeat N]   # offline; no labels,
                                             # no comments, no gh calls

Exit: 0 = passed and labelled · 1 = bounced (posted back to the lane) ·
      2 = could not check (no key / network) — NOT a pass.
"""

import json
import os
import re
import shutil
import subprocess
import time
import sys
import urllib.error
import urllib.request

JEV_URL = "https://jevtypesafeai.com/api/v1/decide"
JEV_MODEL = "jev-1.13.0"          # pin: thresholds must not shift under us
# ---------------------------------------------------------------------------
# CALIBRATION — measured, not guessed. One threshold for all seven marks was the
# first version, and it was wrong for the LANGUAGE marks: they do not have the
# dynamic range the structural marks have, so a single cut splits a homogeneous
# set of good questions instead of separating good from bad.
#
#   mark                  compliant text      non-compliant text      separation
#   --------------------  ------------------  ----------------------  ----------
#   has_options           0.97 - 0.99         (low on a no-options Q)
#   has_analysis          0.86 - 0.97
#   has_recommendation    0.97 - 0.99
#   contradiction_test    0.95                0.14  (asked "is there a
#                                                   decision?" instead of
#                                                   saying what was checked)
#   has_context           0.74 - 0.82         never below ~0.70
#   jargon_free           (MECHANICAL since agent-infra#1903 — see THE LANGUAGE
#   understandable         MARKS ARE MECHANICAL below; the Jev bands that used to
#                          sit here are quoted there, because they are the reason
#                          the two marks are no longer Jev's to grade)
#
# The three owner-approved briefs scored jargon_free 0.07 / 0.12 / 0.07 — which
# is why the language marks cannot sit at 0.80 with the structural ones: at 0.80
# those SAME briefs still bounce (correct, they are the reason this exists) but so
# does every well-written question (0.74-0.84), and a gate that bounces everything
# is a gate lanes route around.
#
# 0.70 keeps every observed bad text failing (max 0.36) and every observed good
# text passing (min 0.74), with the widest gap available. Structural marks keep
# 0.80 because there the gap is enormous and 0.80 sits dead centre.
#
# ONE NUMBER TO REVISIT AFTER ~10 REAL QUESTIONS: if language marks have never
# once failed for a lane that then fixed its text, the mark is not discriminating
# and the noul instruction needs sharpening rather than the threshold moving.
# ---------------------------------------------------------------------------
THRESHOLD = 0.80                  # structural marks: has_options, has_analysis,
                                  # has_recommendation, contradiction_test
THRESHOLD_LANGUAGE = 0.70         # has_context
# ── the bar the two LANGUAGE marks are scored against ────────────────────────
# `has_context` keeps 0.70: the owner's own reply on #5425 named BOTH problems —
# "too much jargon, NOT ENOUGH CONTEXT" — so loosening the context bar would
# contradict his feedback.
#
# ⛔ 0.55 IS NOW A BAR OVER MECHANICAL SCORES, NOT OVER JEV'S (agent-infra#1903).
# The Jev history is kept because it is the evidence for the move: 23 scored
# variants across 17 rewrites scored `jargon_free` in a **0.58-0.63** band, every
# added item cost ~0.05 of it, and the marks the gate REQUIRES
# (has_options / has_analysis / has_recommendation / contradiction_test) never
# fell below 0.89 — so satisfying the structural marks is what made the language
# mark fail. #5489 records that.
#
# #1903 recorded the other failure mode, on ONE question and ELEVEN gate runs:
# eight substantial rewrites of the same question scored jargon_free 0.48-0.58
# and understandable 0.43-0.59 — and the ONLY language PASS was the most
# TECHNICAL draft (0.56, still carrying `eval`, bare issue numbers and internal
# vocabulary), while the drafts written for a non-developer scored LOWER (0.48,
# 0.51). A mark whose signal is anti-correlated with its own definition cannot be
# recalibrated (moving a bar does not reverse a signal); it is replaced by what
# its own definition can actually be checked against. That is the block below.
#
# Scales differ, so the number is not comparable across the two estimators:
# * `jargon_free`      1.0 - 0.25 x (unexplained references)  → 2 references fail
# * `understandable`   1.0 - (avg words/sentence - 30) / 50   → avg > 52.5 fails
THRESHOLD_JARGON = 0.55
LANGUAGE_MARKS = {"has_context", "jargon_free", "understandable"}
MECHANICAL_MARKS = {"jargon_free", "understandable"}
# Kept as the name the rest of the file and its callers use; the two marks in it
# are no longer Jev's, but they still share one bar and one bounce template.
JARGON_MARKS = MECHANICAL_MARKS


def threshold_for(mark):
    if mark in JARGON_MARKS:
        return THRESHOLD_JARGON
    if mark in LANGUAGE_MARKS:
        return THRESHOLD_LANGUAGE
    return THRESHOLD

# ---------------------------------------------------------------------------
# THE RUBRIC. Five nouls are Jev's; two are MECHANICAL (below). Seven marks and
# one choice, i.e. the gate's SHAPE is unchanged by agent-infra#1903 — what
# changed is WHO grades the two language marks. Add or drop a mark and the gate
# changes shape; nothing else does.
# ---------------------------------------------------------------------------
QUESTIONS = {
    "has_context": {
        "type": "noul",
        "instructions": (
            "Does this give enough background that a reader who has NOT seen "
            "this lane's work understands what prompted the question?"
        ),
    },
    "has_options": {
        "type": "noul",
        "instructions": "Does it lay out distinct, named options?",
    },
    "has_analysis": {
        "type": "noul",
        "instructions": (
            "Does it say what each option costs, or what it forecloses?"
        ),
    },
    "has_recommendation": {
        "type": "noul",
        "instructions": "Does it state which option the author recommends?",
    },
    "contradiction_test": {
        "type": "noul",
        "instructions": (
            "Does it name a recorded decision it checked the options against, "
            "or state explicitly that no recorded decision applies?"
        ),
    },
    # `jargon_free` and `understandable` USED to live here. They are computed by
    # `language_marks()` below instead — see THE LANGUAGE MARKS ARE MECHANICAL.
}

# ═══════════════════════════════════════════════════════════════════════════
# THE LANGUAGE MARKS ARE MECHANICAL (agent-infra#1903)
#
# Owner ruling, 2026-10-17: "measure the gate's variance (score the SAME text
# twice — a null pair), then either recalibrate or replace the mark with a
# mechanical check (bare paths / unexplained ticket refs / unexplained
# identifiers)."
#
# MEASURED DEFECT this answers (agent-infra#1903, eleven gate runs on ONE
# question, 2026-10-17). Eight substantial rewrites of the same question scored
# `jargon_free` 0.48-0.58 and `understandable` 0.43-0.59 against a 0.55 bar, and
# the ONLY language PASS in the set was the MOST TECHNICAL draft (0.56 — it still
# carried `eval`, bare issue numbers, "lineage", "reconcile", "superseded"),
# while the drafts written for a non-developer scored LOWER (0.48 and 0.51). The
# signal was anti-correlated with the property the mark names, so every honest
# simplification moved a lane BACKWARDS.
#
# ⛔ THE NULL PAIR WAS NOT RUNNABLE HERE, AND THAT IS WHY THIS IS THE MECHANICAL
# PATH. Running it needs a JEV_API_KEY (paid calls) and a live `jev()`; the
# replacement below needs neither — which is the point. A mark computed from the
# text by plain code has EXACTLY ZERO run-to-run variance by construction, so the
# null pair is not a sample to be drawn, it is a property to be asserted:
# `test_ask_owner.py::test_null_pair_spread_is_zero` scores the same text 20
# times and asserts the marks are identical. For the Jev-graded marks the
# variance question is still open, and `--score-file --repeat N` now draws it
# offline (no issue comments, no labels) on a box that has a key.
#
# What replaced them — the properties the OLD mark's own definition named, made
# checkable instead of guessed:
#
#   jargon_free       bare file paths, ticket references with no sentence
#                     explaining them, single-token identifiers (`eval`) used
#                     without explanation.
#   understandable    sentence length: the mechanical half of readability. It
#                     cannot judge whether the CONTENT is comprehensible; it
#                     detects the shape that most often makes it not.
#
# Neither mark can invert: both are monotone in the defect they count, so adding
# jargon or adding words to a sentence can only LOWER the score. That is the
# property the old mark lacked and the reason it could not be recalibrated — a
# threshold cannot reverse a signal.
#
# Declared shape, declared residual: an "explained" reference is decided by a
# gloss cue inside a window around it (below). This is a heuristic, and the gate
# is honest about that rather than pretending a judge was needed — the bounce
# NAMES every occurrence it counted, so a lane fixes the text instead of reading
# this file to guess what the score meant.
# ═══════════════════════════════════════════════════════════════════════════

# A reference is a path, a ticket number, or a single-token code span. Fenced
# blocks are dropped first (they are code, not prose) and code spans are blanked
# before the path/ticket scan, so `` `scripts/ask-owner.py` `` counts ONCE.
_FENCE = re.compile(r"^```.*?^```", re.M | re.S)
# A URL in prose is a CITATION, not internal shorthand — the reader can open it,
# and the declaration's `refs=` field is where sources belong. Blanked so
# `https://example.com/docs/page.md` is not counted as a bare path.
_URL = re.compile(r"https?://\S+")
_CODE_SPAN = re.compile(r"`([^`\n]+)`")
_PATH = re.compile(
    r"(?<![\w/])~?(?:[\w.-]+/)+[\w.-]+\."
    r"(?:py|sh|cjs|mjs|js|ts|tsx|md|json|ya?ml|toml|plist|txt|cfg|ini)\b"
)
# `#1234`, `agent-infra#1903`, `tortoise#8519` — a bare number or a repo-prefixed
# one. NOT a markdown heading (`# 1234` has a space), and not inside a word.
_TICKET = re.compile(r"(?<![\w/#])(?:[A-Za-z][\w.-]*)?#\d+\b")

# A gloss is the phrase doing the explaining. English puts it AFTER the thing it
# explains ("scripts/ask-owner.py, the gate that…", "#1903 (the PR where…)") or
# immediately BEFORE it ("the gate `eval`…", "one ticket, agent-infra#1903,…").
# The window is deliberately TIGHT — punctuation plus a gloss phrase, adjacent —
# so an incidental "test" or "issue" twelve words later cannot launder a bare
# reference. A false PASS is the one direction this heuristic must not drift.
# ⛔ PUNCTUATION IS NOT A GLOSS. A bare `(`, `[` or em dash used to satisfy the
# AFTER-pattern on its own, so wrapping each reference in a bracket laundered the
# whole question: measured on this suite's own V3 draft, `reconciled (#1553) and
# re-run (`eval`)` scored jargon_free 1.0 — against 0.25 for the identical text
# without brackets, i.e. the drain the mark exists to close, reopened by two
# keystrokes. Brackets and dashes are GAP characters (an opening for a gloss
# phrase, since the phrase follows them); only a real noun phrase explains.
# ⚠️ …AND A REAL NOUN PHRASE IS NOT ONLY THE 19 WORDS BELOW. The first version
# demanded `the|a|an|one|this|that` IMMEDIATELY followed by an allow-listed noun,
# so "#1553 — the database check" and "`eval` — our scoring script" were COUNTED
# (measured 0.50, below the 0.55 bar) — a well-explained question bounced, which is
# the #1903 symptom this whole mark exists to end. The determiner set now includes
# possessives and up to two words may sit between it and the head noun, so
# "the database check" / "our scoring script" / "the superseded rows check"
# explain. What still does NOT explain is punctuation alone or a bracket holding
# only a token — `(#1553)`, `[`eval`]` — because there is no noun phrase there.
_NUMBER_NOUN = (
    r"(?:file|script|gate|check|issue|ticket|row|function|module|command|doc"
    r"|document|PR|pull request|label|flag|mark|test|suite|rule|table|path|line"
    r"|patch|branch|commit)"
)
_DET = r"(?:the|a|an|one|this|that|its|our|their|my|your)"
_NP = _DET + r"\s+(?:[\w.'\u2019-]+\s+){0,2}" + _NUMBER_NOUN + r"\b"
_GAP = r"[\s)\].,;:\u2014\u2013(\[-]{0,3}"
_GLOSS_AFTER = re.compile(
    r"^" + _GAP + r"(?:which\b|that is\b|i\.e\.|means\b"
    r"|called\b|named\b|" + _NP + r")",
    re.I,
)
_GLOSS_BEFORE = re.compile(
    r"(?:" + _NP + r")\W{0,3}$",
    re.I,
)
_GLOSS_WINDOW = 60                 # characters either side, not words

STEP_PER_REFERENCE = 0.25          # 2 unexplained references fail the 0.55 bar
AVG_SENTENCE_COMFORT = 30.0        # words/sentence at which the score is 1.0
AVG_SENTENCE_SPAN = 50.0           # words/sentence at which the score reaches 0.0


def _sentences(text):
    """Prose sentences, one per list item or line.

    A bullet is a sentence, not a fragment of the previous one: splitting only on
    `[.!?]` would weld an options list into one 200-word sentence and fail a
    question that is perfectly readable. Headings and blank lines are skipped.
    """
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue                      # a heading is not a prose sentence
        line = line.strip().lstrip("-*+> ").strip()
        if not line:
            continue
        for s in re.split(r"(?<=[.!?])\s+", line):
            if s.strip():
                out.append(s.strip())
    return out


def _explained(text, start, end):
    """Is a gloss phrase adjacent to this reference (tight window, either side)?"""
    before = text[max(0, start - _GLOSS_WINDOW):start]
    after = text[end:end + _GLOSS_WINDOW]
    return bool(_GLOSS_BEFORE.search(before)) or bool(_GLOSS_AFTER.search(after))


def unexplained_references(text):
    """[(kind, token)] in document order — every reference with no gloss near it.

    `text` is the PROSE (the declaration line is already stripped by
    `prose_only`), so the `refs=...` field the protocol forces every question to
    carry is never counted — the same reason `prose_only()` exists.
    """
    body = _FENCE.sub(lambda m: " " * len(m.group(0)), text)
    body = _URL.sub(lambda m: " " * len(m.group(0)), body)
    found = []
    blanked = list(body)
    for m in _CODE_SPAN.finditer(body):
        token = m.group(1).strip()
        # A path or ticket INSIDE backticks is the path/ticket rule's business
        # (one count, its own gloss window) — so that span is left in the flat
        # text and counted there. Anything else in backticks that is a single
        # token with a letter in it is a bare identifier (`eval`, `MAX_LANES`);
        # multi-word spans are quoted commands or output, not identifiers.
        is_ref = bool(_TICKET.fullmatch(token) or _PATH.fullmatch(token))
        if not is_ref:
            for i in range(m.start(), m.end()):
                blanked[i] = " "
            if (token and len(token) <= 60 and not re.search(r"\s", token)
                    and re.search(r"[A-Za-z]", token)
                    and not _explained(text, m.start(), m.end())):
                found.append((m.start(), "bare identifier", token))
    flat = "".join(blanked)
    for kind, rx in (("bare file path", _PATH), ("bare issue number", _TICKET)):
        for m in rx.finditer(flat):
            if not _explained(text, m.start(), m.end()):
                found.append((m.start(), kind, m.group(0)))
    found.sort(key=lambda t: t[0])
    return [(kind, token) for _, kind, token in found]


def jargon_free_score(text):
    """1.0 minus 0.25 per unexplained reference — monotone, so jargon can only
    lower it. (kind, token) findings are returned for the bounce message."""
    refs = unexplained_references(text)
    return max(0.0, 1.0 - STEP_PER_REFERENCE * len(refs)), refs


def understandable_score(text):
    """Average words per sentence, mapped so the 0.55 bar fails above ~52 words.

    Monotone in sentence length: padding a sentence can only lower it. Returns
    the longest sentence too, so a bounce can quote the shape it counted.
    """
    sents = _sentences(text)
    if not sents:
        return 1.0, []
    avg = sum(len(s.split()) for s in sents) / len(sents)
    score = max(0.0, 1.0 - max(0.0, avg - AVG_SENTENCE_COMFORT) / AVG_SENTENCE_SPAN)
    findings = []
    if score < THRESHOLD_JARGON:
        longest = max(sents, key=lambda s: len(s.split()))
        n = len(longest.split())
        findings.append(
            f"average sentence length {avg:.0f} words (longest {n}): {longest[:160]}"
            + ("…" if len(longest) > 160 else ""))
    return score, findings


def language_marks(text):
    """The two language marks, computed from the text. No Jev, no network, no cost.

    Same answer every time it is called on the same text — which is the property
    the null pair in agent-infra#1903 was looking for and the old Jev-graded mark
    could not promise.
    """
    prose = prose_only(text)
    jf, jf_findings = jargon_free_score(prose)
    un, un_findings = understandable_score(prose)
    answers = {
        "jargon_free": {"type": "noul", "noul": jf},
        "understandable": {"type": "noul", "noul": un},
    }
    return answers, {"jargon_free": (jf, jf_findings),
                     "understandable": (un, un_findings)}

# Which template answers which failed check. The problem is DERIVED from the
# failing nouls in plain code — never asked as a separate Jev question, because
# Jev evaluates questions in parallel and cannot see its own other answers.
CHECK_TO_PROBLEM = {
    "has_context": "missing_context",
    "has_options": "missing_options",
    "has_analysis": "missing_analysis",
    "has_recommendation": "missing_recommendation",
    "contradiction_test": "contradiction_skipped",
    "jargon_free": "jargon",
    "understandable": "jargon",
}

# ---------------------------------------------------------------------------
# BOUNCE TEMPLATES. One per non-'none' choice. Deliberately specific: the point
# of a fixed choice set is that the message can never say "unclear".
# ---------------------------------------------------------------------------
TEMPLATES = {
    "missing_context": (
        "Sent back: **not enough context.** A reader has not seen this lane's "
        "work and does not know what prompted the question. Add, in plain "
        "language: what happened, why it needs a decision now, and what is "
        "blocked until it is made."
    ),
    "missing_options": (
        "Sent back: **no distinct options.** The question needs named, "
        "separate choices someone can pick between — not a description of the "
        "problem with an implicit 'what should I do?'."
    ),
    "missing_analysis": (
        "Sent back: **options listed without analysis.** For each option, say "
        "what it costs and what it forecloses — what you give up by choosing "
        "it that you would have kept by choosing another."
    ),
    "missing_recommendation": (
        "Sent back: **no recommendation.** Options alone are not a question. "
        "State which one you recommend and why, so the default is a decision "
        "rather than a choice handed back unexamined."
    ),
    "contradiction_skipped": (
        "Sent back: **no contradiction check.** Name the recorded decision you "
        "checked the options against — an owner ruling, a decision in a plan "
        "doc, a decision comment, or a Tortoise point. If none applies, say so "
        "explicitly. Check the canon first: `docs/ONTOLOGY.md`, "
        "`docs/architecture/EXTRACTOR-V4-ARCHITECTURE.md`, "
        "`docs/architecture/STORAGE-ARCHITECTURE.md`."
    ),
    "jargon": (
        "Sent back: **internal shorthand.** Rewrite without codenames, ticket "
        "abbreviations and terms invented inside this project. Assume the "
        "reader is a non-developer who has not read this lane."
    ),
}

DECLARATION = "RESEARCH:"
NO_RESEARCH = (
    "Sent back: **this question does not record whether research was done for "
    "it.** Add the declaration as the FIRST line of the question:\n\n"
    "```\nRESEARCH: skill=<the method you ran for THIS question, or none> "
    "sources=<internal|web|perplexity|none> refs=<file:line, url, issue#>\n"
    "```\n\n"
    "Answer it about this question alone, and answer it honestly. If the honest "
    "answer is `skill=none`, do NOT post the question — the research comes "
    "first. AGENTS.md makes the research skill MANDATORY before asking the "
    "owner anything, so `because=<reason>` is NOT an exemption from it: it only "
    "records why you believed the skill did not apply, and this gate reads that "
    "as a question that skipped its own protocol and sends it back to you.\n\n"
    "'This is a decision about our own product' is NOT a reason to skip "
    "research — it is the case where research is MOST available, because the "
    "repo's own canon is a source. Read the ontology, the architecture docs, "
    "the recorded decisions and the Tortoise graph first, and run the "
    "contradiction test before anything else. Research a question about our "
    "own product exactly as you would a question about someone else's: the "
    "answer is often already written down, and a question the canon can settle "
    "is not a question for the owner.\n\n"
    "The rule, in order: (1) research the question, starting with this repo's "
    "own canon (the ontology and the two architecture docs) and the graph, "
    "before the tracker or the web; (2) if the research settles it, ACT on it "
    "and do not ask; (3) only if the answer is still genuinely non-obvious "
    "after that research, ask — and declare the research you did to reach that "
    "point."
)


HOME = os.path.expanduser("~")


def _find_gh():
    """`gh` resolved EXPLICITLY, not left to PATH.

    The gate runs from three contexts — an interactive lane, the detached heartbeat
    loop, and a sub-agent — and they do NOT share a PATH. On this box `gh` is
    `~/.pi/agent/shims/gh`, a directory that was absent from the loop's PATH, and
    the first live heartbeat tick therefore logged "NOTE ask-owner scan produced
    nothing usable": the gate was dead while the tick still read as a green.
    Resolving the binary here means no caller has to know where it lives.
    """
    found = shutil.which("gh")
    if found:
        return found
    for cand in (f"{HOME}/.pi/agent/shims/gh", "/opt/homebrew/bin/gh",
                 "/usr/local/bin/gh", "/usr/bin/gh"):
        if os.path.exists(cand):
            return cand
    return "gh"          # last resort: the caller sees FileNotFoundError and says so


GH = _find_gh()


# ⛔ A SUBPROCESS WITH NO TIMEOUT IS AN UNBOUNDED STEP (2026-10-12).
# `timeout=None` was the default for BOTH helpers below, and it WEDGED THE HEARTBEAT. The `--scan`
# step lists issues with `--json number,comments,labels` and filters CLIENT-SIDE with --jq, so it
# must download every comment body for up to 1000 issues per repo — minutes of network on a warm
# cache, and UNBOUNDED on a cold one. MEASURED after the 2026-10-12 reboot: the scan ran **63
# minutes** inside a synchronous command substitution in orchestrator-heartbeat.sh (a bare
# `ASK_ALL=$(... ask-owner.py --scan)`, which the script's own comment budgets at ~250-390s), so a
# 540s pass took **8515s** and the loop emitted no log line for 55 minutes — indistinguishable from
# a dead heartbeat.
# The bound is set ABOVE the healthy whole-scan cost (~250-390s) so a slow-but-working gh never
# trips it, and a trip is reported as FAILURE (rc=124), never as EMPTY — which is precisely the
# distinction sh_status exists to preserve.
GH_TIMEOUT_S = int(os.environ.get("ASK_OWNER_GH_TIMEOUT_S", "420"))
# ⛔ PER-CALL BOUNDS ARE NOT ENOUGH — THE SCAN MUST FIT THE CADENCE. Three repos at the per-call
# bound is a ~21-minute pass against a 9-minute target, so the invariant that actually matters is
# enforced on the scan itself. Measured healthy cost of the whole scan: 79s (2026-10-12), so the
# budget is ~4x that and a slow-but-working gh never trips it. A trip counts as scan_failed — an
# ALERT — never a silent zero.
SCAN_BUDGET_S = int(os.environ.get("ASK_OWNER_SCAN_BUDGET_S", "300"))


def sh(args, timeout=GH_TIMEOUT_S):
    if args and args[0] == "gh":
        args = [GH] + list(args[1:])
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


def sh_status(args, timeout=GH_TIMEOUT_S):
    """(rc, stdout, stderr) — for callers that must not mistake FAILURE for EMPTY.

    `sh` returns stdout and drops everything else, so a gh invocation that FAILS is
    indistinguishable from one that found nothing. That is how the scan reported
    `pending=0` while an open issue carried a declaration: the jq filter was
    rejected, gh exited non-zero, and the empty string read as "no questions
    waiting". A green from a command that never ran is exactly the defect the rest
    of this file exists to prevent, so the scan checks the exit code.
    A timeout is the same class of event and returns rc=124, for the same reason.
    """
    if args and args[0] == "gh":
        args = [GH] + list(args[1:])
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", f"TIMEOUT after {timeout}s: {' '.join(args[:6])}"
    return p.returncode, p.stdout, p.stderr


DECL_MARK = "RESEARCH:"


def fetch_question(repo, number):
    """THE QUESTION — one comment, and it starts with its declaration.

    A question is ONE comment whose FIRST LINE is the declaration. That is the
    rule, and it is deliberately strict, because auto-detecting "which text is
    the question" from an unstructured thread does not work:

      * scoring the whole thread means a FIXED question fails on its own earlier
        drafts (measured: a rewrite that removed every internal term moved
        jargon_free only 0.07 -> 0.09);
      * scoring only the declaring comment ignores a follow-up answer
        (measured: contradiction_test stayed 0.10 after the test was posted);
      * scoring from the newest declaration to end-of-thread picks up unrelated
        later comments, so the same brief scored options 0.98 and then 0.34
        depending purely on what else was in the thread.

    One comment, starting with the declaration, no guessing. It also happens to
    be the shape a reader wants: one coherent question, not a thread to
    reassemble.

    Fallback: the issue body, if no comment qualifies.
    """
    raw = sh([
        "gh", "issue", "view", str(number), "--repo", repo,
        "--json", "body,comments",
    ])
    if not raw.strip():
        return None
    data = json.loads(raw)
    for c in reversed(data.get("comments") or []):
        body = (c.get("body") or "").lstrip()
        if body.upper().startswith(DECL_MARK):
            return body
    return data.get("body") or ""


def prose_only(text):
    """The comment WITHOUT its declaration line — the text Jev is asked to judge.

    MEASURED DEFECT this fixes (2026-09-25). The declaration is a REQUIRED field
    of every question, and it is full of exactly what `jargon_free` is told to
    count as jargon: a file path, a bare identifier, `skill=yes sources=internal`
    shorthand. Scoring it meant every question carried a penalty for the line the
    protocol forces it to carry, so `jargon_free` was pushed toward unpassable —
    a bounce the lane could never fix, because removing the line is itself a
    bounce (NO_RESEARCH). The rule the design already stated is the fix: mechanical
    is honest for a DECLARED FIELD, Jev for PROSE. The field is stripped; the prose
    is judged. Measured on one question: jargon_free 0.53 -> see the run below,
    with no other change.
    """
    lines = text.splitlines()
    kept, dropped = [], False
    for ln in lines:
        if not dropped and ln.strip().upper().startswith(DECLARATION):
            dropped = True
            continue
        kept.append(ln)
    return "\n".join(kept).strip()


def declaration_present(text):
    """The ONE mechanical check, and it is honest: a declaration is a field,
    not prose. No regex on meaning — just: did they declare anything?

    MEASURED DEFECT this fixes (2026-09-26). The predicate required BOTH
    `skill=no` AND `sources=none`, so `skill=no sources=internal` — the most
    natural way to write it — returned `declared`, i.e. was read as though
    research had been done. Measured across daniel-ospina/tortoise comments:
    123 declarations admitted `skill=no` against 57 that said `skill=yes`
    (~68% of declared questions recorded that the skill was NOT run), and the
    gate fired on almost none of them. The owner's framing: agents use the
    format diligently, but the honesty field was decorative — the field that
    recorded "no research" was, to the gate, identical to the field recording
    research.

    The `because=` carve-out is now CLOSED (2026-10-05). It let
    `skill=none because=<anything>` pass as `declared`, which made the excuse
    cheaper than the work: `skill=none because=this is a decision about our own
    product` reached the owner with no research done — and that reason names
    the one case where research is MOST available, since the repo's own canon,
    its recorded decisions and the graph are all sources. AGENTS.md makes the
    research skill mandatory before a question reaches the owner, so a
    declaration that the skill was not run is now always
    `declared_no_research`, whatever reason follows it: the question goes back
    to the agent with the protocol, and reaches the owner only once the
    research is done and the answer is still non-obvious. `skill=no` and
    `skill=none` are both accepted spellings.
    """
    for line in text.splitlines():
        if line.strip().upper().startswith(DECLARATION):
            flat = line.split(":", 1)[1].lower().replace(" ", "")
            if "skill=no" in flat or "skill=none" in flat:
                return "declared_no_research"
            return "declared"
    return "absent"


def _key():
    """Env first, then a 0600 config — so it works from launchd and any cwd."""
    k = os.environ.get("JEV_API_KEY")
    if k:
        return k
    try:
        p = os.path.expanduser("~/.pi/agent/jev-config.json")
        return json.load(open(p)).get("apiKey")
    except Exception:  # noqa: BLE001
        return None


def jev(state):
    key = _key()
    if not key:
        print("no JEV key (env JEV_API_KEY or ~/.pi/agent/jev-config.json)"
              " — cannot check (this is NOT a pass)")
        return None
    req = urllib.request.Request(
        JEV_URL,
        data=json.dumps({
            "model": JEV_MODEL, "state": state, "questions": QUESTIONS,
        }).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        print(f"jev http {e.code}: {e.read().decode()[:300]}")
        return None
    except Exception as e:  # noqa: BLE001
        print(f"jev call failed: {e}")
        return None


def verdict(answers):
    """Plain code branches on fixed types — no parsing.

    The problem is derived: the LOWEST-scoring failing check decides which
    template the lane gets, so the message always names the worst thing first.
    """
    scored = [
        (ans.get("noul", 0.0), name)
        for name, ans in answers.items()
        if ans.get("type") == "noul"
    ]
    failures = sorted([n for s, n in scored if s < threshold_for(n)])
    if not failures:
        return [], "none"
    # the worst FAILING mark decides the template, so the message always names the
    # biggest problem first
    bad = [t for t in scored if t[0] < threshold_for(t[1])]
    worst = min(bad)[1]
    return failures, CHECK_TO_PROBLEM.get(worst, failures[0])


REPOS = ["daniel-ospina/tortoise", "daniel-ospina/premise-labs",
         "daniel-ospina/agent-infra"]

# ── R5 DEPENDS ON THIS GATE (agent-infra#1905, owner ruling 2026-10-17) ─────────
# #1905's R5 says *"there is no blocked item: anything stuck is either fixed
# automatically or becomes a user question"*. That RETIRES `parked-*` as a
# terminal state, which leaves THIS gate as the only terminal path a stuck item
# has. The dependency is mechanical, not stylistic: while the gate could not pass
# an honest question — the 2026-10-17 defect (agent-infra#1903) in which every
# plain rewrite bounced and the densest draft passed — a stuck item would have
# been *refused by the gate and then left with no terminal state at all*, which is
# worse than `parked-*`: a park is a record a controller can see, silence is not.
#
# So, until #1905 lands:
#   * `parked-*` stays the RECORDED terminal state for anything this gate
#     refuses — the fallback must be visible, never silence;
#   * the two language marks are MECHANICAL (see THE LANGUAGE MARKS ARE
#     MECHANICAL), so a refusal is reproducible and names what failed. A lane can
#     act on the bounce instead of rewriting into a mark that rewards density.
BOUNCE_LABEL = "question-bounced"
# The OTHER half of the handshake. `question-bounced` stops the gate repeating
# itself; `owner-answered` stops it repeating ITSELF — and it is the reason this
# file can be idempotent without a database.
#
# WHY IT IS NEEDED AT ALL, in the owner's own workflow terms: the owner answers a
# question by leaving a comment and REMOVING the `owner-decision` label. That is the
# natural thing to do, and it is exactly what happened on premise-labs #479 and #467
# (timeline evidence: one `unlabeled owner-decision` event each). But removal takes
# the issue back to "a declaring comment with neither label" — the gate's own
# candidate state — so without this the answered question was re-scored on the next
# tick and pushed BACK INTO THE OWNER'S QUEUE. An answered question reappearing is
# worse than a question that never arrived.
ANSWERED_LABEL = "owner-answered"
# ⛔ THE SKIP PREDICATE READS ONLY THIS ONE. `owner-answered` is the human-facing
# record and a PERSON may set it; if the skip keyed on that, a human marking the
# issue answered would permanently hide it from delivery and the lane would never
# be told (measured: tortoise #5362/#5358, 2026-09-25). This label is written
# ONLY by this script, so "delivered" cannot be asserted by anyone else.
DELIVERED_LABEL = "answer-delivered"
# A single heartbeat tick must not spend unbounded time or money. The labels
# de-duplicate across ticks, so a backlog drains over successive 5-minute scans
# instead of stalling one. Five scored questions is a few cents and ~10 s.
MAX_SCAN = 5

# ── complete enumeration -------------------------------------------------------
# The candidate set used to come from `gh issue list --limit 200`. That silently
# truncated: measured 2026-09-27, tortoise#5025 had been ANSWERED — its
# owner-decision label removed, which is the delivery signal — and never
# delivered, because it sat at position 234 of 800+ open issues. A truncated
# candidate set does not read as truncated; it reads as "nothing pending".
#
# So we enumerate the SIGNAL instead of the ISSUES: repository-level `unlabeled`
# events for the queue label. Those are orders of magnitude fewer than the issues,
# and pagination makes them complete by construction.
EVENT_MAX_PAGES = 20          # safety cap; 100 events/page
EVENT_MAX_AGE_DAYS = 21       # stop paging once events are this old


def answer_events(repo):
    """{issue_number: newest_unlabeled_at} from repo-level issue events.

    Returns None when the read FAILED, which the caller must treat as UNKNOWN.
    Returning {} would be indistinguishable from "no answers" — the exact
    silent-negative shape this file has already been bitten by.
    """
    import datetime as _dt
    cutoff = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=EVENT_MAX_AGE_DAYS)
    found, page = {}, 1
    while page <= EVENT_MAX_PAGES:
        rc, raw, err = sh_status([
            "gh", "api",
            f"repos/{repo}/issues/events?per_page=100&page={page}",
            "--jq", '.[] | select(.event=="unlabeled" and .label.name=="owner-decision") '
                    '| "\(.issue.number)\t\(.created_at)"',
        ])
        if rc != 0:
            return None
        lines = [l for l in raw.strip().splitlines() if l.strip()]
        if not lines:
            break
        oldest = None
        for line in lines:
            n, _, at = line.partition("\t")
            if not n.isdigit() or not at:
                continue
            oldest = at
            if n not in found or at > found[n]:
                found[int(n)] = at
        if oldest:
            try:
                when = _dt.datetime.strptime(oldest, "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=_dt.timezone.utc)
                if when < cutoff:
                    break
            except ValueError:
                pass
        if len(lines) < 100:
            break
        page += 1
    return found
BOUNCE_TAIL = (
    "\n\n---\n*Fix this on the issue, then remove the `question-bounced` "
    "label to re-submit.*"
)


REGISTRY = f"{HOME}/.pi/agent/state/lane-registry.tsv"
CMUX_DISPATCH = f"{HOME}/Documents/GitHub/tortoise/tools/cmux_dispatch.py"


def _iso(e):
    return (e or "")[:19]


def owner_answered_at(repo, n):
    """When the owner last took a question OUT of the queue. `""` = not answered,
    `None` = the read FAILED (UNKNOWN — never "no answer").

    The signal is the label removal, because nothing else survives: every actor on
    this box authenticates as `daniel-ospina`, so a comment's AUTHOR cannot tell the
    owner from a lane, and the comment TEXT is the lane's own brief coming back. The
    timeline records the removal as an `unlabeled` event, and it is the one action
    the owner actually performs. ONE api call per candidate, and the candidate set
    is tiny (only issues carrying a declaring comment).

    ⛔ THE GATE ITSELF WRITES THAT EVENT. A bounce removes `owner-decision` (STEP 1
    and STEP 2) so the artifact stops reading as "live and returned at once"
    (#1553). That makes the removal AMBIGUOUS, and any ordering test is unsound:
    timestamp comparisons break on a bounce whose `--add-label question-bounced`
    was a NO-OP (the label was already there, so no `labeled` event is written and
    the removal looks newest), and on two events sharing one second. The invariant
    that does hold is the LABEL STATE: a bounced question is not in the owner's
    queue, so a removal while `question-bounced` is present is not an answer.
    Measured on the ordering rule: the legacy both-labels state (#1553's actual
    state) + one gate bounce was read as ANSWERED, stamped
    `owner-answered,answer-delivered` (a permanent skip) and cleared
    `question-bounced` — a question the gate had just bounced became a settled
    question nobody answered.

    ⚠️ DECLARED GAP (agent-infra#1969): because a bounce removes the queue label,
    an owner who answers a BOUNCED question leaves no removal to observe, so that
    answer is not detected by this signal — the question is re-scored instead. Pre-
    #1903 the label stayed on and that path worked. Closing it needs a signal the
    gate never writes (the bounce comment is identifiable by `BOUNCE_TAIL`, so a
    newer non-template comment is the candidate); it is NOT closed here, and it is
    not claimed to be.
    """
    rc, raw, _ = sh_status([
        "gh", "api", f"repos/{repo}/issues/{n}/timeline", "--paginate", "--jq",
        '[.[] | select(.event=="unlabeled" and .label.name=="owner-decision") '
        '| .created_at] | last // ""',
    ])
    if rc != 0:
        return None
    if not raw.strip():
        return ""
    bounced = has_label(repo, n, BOUNCE_LABEL)
    if bounced is None:
        return None                       # UNKNOWN, never "no answer"
    if bounced:
        return ""                        # the gate's own bounce, or a removed-then-bounced question
    return _iso(raw.strip().splitlines()[-1])


def newest_decl_at(repo, n):
    """When the newest declaring comment was posted.

    Compared against the label removal: a removal EARLIER than the newest
    declaration is a question asked AFTER the owner answered a previous one, i.e. a
    genuinely new question that must be scored. A removal LATER than it is the
    answer to THAT question. So a lane re-asking does not have to remove any label
    to be heard — it just posts the new question, which is what it would do anyway.
    """
    rc, raw, _ = sh_status([
        "gh", "issue", "view", str(n), "--repo", repo, "--json", "comments",
        "--jq", '[.comments[] | select((.body // "") | test("^ *RESEARCH:")) '
        '| .createdAt] | last // ""',
    ])
    if rc != 0:
        return None
    return _iso(raw.strip().splitlines()[-1]) if raw.strip() else None


def lane_workspaces(repo, n):
    """[(lane title, workspace uuid), ...] for every lane that owns this issue.

    The route is `lane:<x>` label -> registry row -> pane. A lane that owns no repo
    label (the HANG and A lanes) or an issue filed outside the beta lanes cannot be
    routed, and that is reported rather than guessed — a message sent to the wrong
    pane is worse than no message.

    RETURNS A LIST because an issue may legitimately carry SEVERAL lane labels.
    The previous version joined them into one string and compared that to a single
    registry field, so it could not match anything: measured 2026-09-27, 29 open
    issues carried two lane labels, including the P0s #5131/#5109/#5106 — which
    meant their answers were STRUCTURALLY undeliverable, not merely late.
    """
    rc, raw, _ = sh_status([
        "gh", "issue", "view", str(n), "--repo", repo, "--json", "labels",
        "--jq", '[.labels[].name | select(startswith("lane:"))] | join(",")',
    ])
    if rc != 0 or not raw.strip():
        return []
    want = raw.strip().splitlines()[-1]
    if not want:
        return []
    wants = {w.strip() for w in want.split(",") if w.strip()}
    out = []
    try:
        for line in open(REGISTRY, errors="ignore"):
            if line.startswith("#") or "\t" not in line:
                continue
            p = [x.strip() for x in line.rstrip("\n").split("\t")]
            if len(p) >= 3 and p[2] in wants:
                out.append((p[0], p[1]))
    except Exception:
        return out
    return out


def has_label(repo, n, label):
    """True when the issue currently carries `label`. Failure reads as ABSENT is
    wrong here, so an unreadable label set is reported as UNKNOWN (None)."""
    rc, raw, _ = sh_status([
        "gh", "issue", "view", str(n), "--repo", repo, "--json", "labels",
        "--jq", '[.labels[].name] | join(",")',
    ])
    if rc != 0:
        return None
    names = {x.strip() for x in (raw.strip().splitlines()[-1] if raw.strip() else "").split(",")}
    return label in names


def lane_session_file(ws):
    """The lane's live session `.jsonl`, resolved from the PANE (never a pinned id)."""
    import glob
    rc, out, _ = sh_status(["cmux", "surface", "resume", "show", "--workspace", ws])
    sid = None
    for tok in (out or "").replace("'", " ").split():
        if len(tok) == 36 and tok.count("-") == 4:
            sid = tok
            break
    if not sid:
        return None
    hits = glob.glob(f"{HOME}/.pi/agent/sessions/*/*{sid}*.jsonl")
    return max(hits, key=os.path.getmtime) if hits else None


# Two numbers, both learned the hard way on 2026-09-25.
#
# 1. 45 s is too short. The notification WAS delivered, and this check still said it
#    was not: the message took longer than 45 s to appear in the pane's session file
#    because pi flushes that file lazily (the heartbeat measured the same effect: a
#    send at T landed at T+53 s on an ~18 MB session). 90 s covers it.
# 2. A 400 KB tail is too small for a large session. A lane's file is normally 1-3 MB
#    so the tail IS the whole file, but the orchestrator's is ~20 MB and a single
#    appended record can push the message out of a small window. 2 MB it is.
#
# The consequence of getting this wrong is not cosmetic: a false negative here reads
# as "the answer never reached the lane", and a human then carries it by hand - a
# duplicate of a message that already arrived.
LAND_TIMEOUT_S = 90
LAND_POLL_S = 5
LAND_TAIL_B = 2_000_000


def lane_landed(ws, before_size, sentinel, timeout=LAND_TIMEOUT_S):
    """Did the notification actually become part of the lane's transcript?

    The dispatcher's exit code is NOT the verdict (#5204 reported
    `sent-but-not-consumed` for a message that had demonstrably arrived, and did so
    again for THIS notification). For this message the exit code is the difference
    between telling the lane ONCE and telling it every five minutes forever, so the
    artifact decides.
    """
    f = lane_session_file(ws)
    if not f:
        # A DIFFERENT failure from "the text is not there": the pane has no session
        # binding at all, so the transcript cannot be consulted. Measured on the
        # orchestrator's own pane, which reports `No resume binding` while every
        # registered lane resolves normally. Reporting these as the same thing is how
        # a verifier starts lying.
        return None
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(f, "rb") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - LAND_TAIL_B))
                tail = fh.read().decode("utf-8", "replace")
            if (before_size is None or size > before_size) and sentinel in tail:
                return True
        except Exception:
            pass
        time.sleep(LAND_POLL_S)
    return False


def notify_lane(title, ws, repo, n, dry):
    """Tell the lane the owner answered. Returns a short verdict string.

    Delivery goes through `tools/cmux_dispatch.py` rather than a bare `cmux send`,
    because a send that never becomes a turn is the failure mode that already cost a
    dispatch cycle (#5204) - and the caller here cannot see the pane.
    """
    sentinel = f"The owner has answered your question on {repo}#{n}"
    body = (
        "[ORCHESTRATOR - automatic]\n\n"
        f"**{sentinel}.**\n\n"
        "Read the comments on that issue that come AFTER your `RESEARCH:` line - that "
        "is the ruling. Then carry on: implement what it says, and if it changed the "
        "scope, say so in one line on the issue.\n\n"
        f"Do not re-ask it. The `{ANSWERED_LABEL}` label records that the answer was "
        "delivered to you.\n"
    )
    if dry:
        return f"WOULD NOTIFY {title}"
    before = None
    f = lane_session_file(ws)
    if f:
        try:
            before = os.path.getsize(f)
        except Exception:
            before = None
    brief = f"/tmp/owner-answer-{os.getpid()}.txt"
    with open(brief, "w") as fh:
        fh.write(body)
    # ── DELIVERY MECHANISM ────────────────────────────────────────────────────
    # Use the QUEUEING send, NOT tools/cmux_dispatch.py. The dispatcher verifies
    # delivery by requiring the message to become the pane's latest SUBMITTED
    # message, which needs a free composer — so on a lane that is mid-turn (i.e.
    # every lane that is actually working) it waits out its whole timeout and
    # returns non-zero. Measured 2026-09-27: it timed out after 180s on
    # `6 Durability core` while that lane was perfectly healthy, which converted an
    # answer the scan had just found into an answer the lane never got.
    # A plain send QUEUES, and pi consumes it when the current turn ends. The
    # verification below does not depend on the dispatcher, so nothing is lost.
    #
    # ⛔ ONE LINE ONLY: a newline in the payload IS Enter, so a multi-line body
    # would be submitted as several separate turns and arrive as fragments.
    flat = " ".join(body.split())
    rc, out, _ = sh_status(["cmux", "send", "--workspace", ws, flat + "\n"],
                           timeout=45)
    try:
        os.unlink(brief)
    except Exception:
        pass
    if rc == 0:
        return f"NOTIFIED {title}"
    landed = lane_landed(ws, before, sentinel)
    if landed:
        return f"NOTIFIED {title} (dispatcher said rc={rc}; transcript confirms)"
    if landed is None:
        return (f"NOTIFY-UNVERIFIABLE {title} rc={rc} - the pane has no session "
                f"binding, so delivery cannot be checked from here")
    # NOT "it did not arrive". The dispatcher's own check is known-unreliable (#5204),
    # and this branch has already produced one false negative on a message that had
    # demonstrably arrived. So the claim is limited to what is known: not confirmed
    # within the window. `owner-answered` is applied either way, because spamming the
    # lane every tick is worse than one human lookup.
    return (f"NOTIFY-UNCONFIRMED {title} rc={rc} {out.strip()[:60]} - not seen in "
            f"the lane's transcript within {LAND_TIMEOUT_S}s. Check that pane before "
            f"carrying it by hand; the dispatcher has reported this falsely before")


def scan(dry):
    """Every open issue carrying a pending question, across all repos.

    A pending question = an open issue with a comment starting with the
    declaration, carrying NEITHER `owner-decision` NOR `question-bounced`.

    The bounce label is the anti-spam guard, and it is load-bearing: without it
    this scan would post the same complaint every five minutes forever, because
    it has no memory. The labels ARE the memory — nothing is stored anywhere
    else. This is the whole automation: no hook, no webhook, no daemon. It is
    meant to be called by the heartbeat that already runs.
    """
    pending = []
    scan_failed = 0
    scan_deadline = time.time() + SCAN_BUDGET_S
    # PASS 1 — candidate questions, feeding the SCORING/posting path. Same shape as
    # before, but paginated to 1000 instead of `--limit 200`, so a question on an
    # older issue is still scored.
    for repo in REPOS:
        if time.time() > scan_deadline:
            scan_failed += 1
            print(f"  SCAN FAILED for {repo} rc=124 :: scan budget {SCAN_BUDGET_S}s exhausted")
            continue
        rc, raw, err = sh_status([
            "gh", "issue", "list", "--repo", repo, "--state", "open",
            "--limit", "1000", "--json", "number,comments,labels",
            "--jq", '.[] | select((.labels|map(.name)) '
                    '| (index("owner-decision") or index("' + BOUNCE_LABEL + '") '
                    '  or index("' + DELIVERED_LABEL + '")) | not) '
                    '| "\(.number)\\t\([.comments[]?.body // "" '
                    '| select(test("^ *RESEARCH:"))] | length)"',
        ])
        if rc != 0:
            scan_failed += 1
            print(f"  SCAN FAILED for {repo} rc={rc} :: {err.strip()[:200]}")
            continue
        for line in raw.strip().splitlines():
            n, cnt = (line.split("\t") + ["0"])[:2]
            if cnt.isdigit() and int(cnt) > 0:
                pending.append((repo, int(n)))

    # PASS 2 — ANSWERS, enumerated from the label-removal EVENTS rather than from
    # the issue listing. This is precisely what the truncated pass could not see: an
    # answer on an old issue, or on one the bounce label had excluded. Measured
    # 2026-09-27: tortoise#5025 was answered (label removed — the delivery signal)
    # and never delivered, because it sat at position 234 of 800+ open issues.
    # Issues already found by pass 1 are skipped here.
    seen = set(pending)
    ev_ans = {}
    for repo in REPOS:
        if time.time() > scan_deadline:
            scan_failed += 1
            print(f"  SCAN FAILED (events) for {repo} — scan budget {SCAN_BUDGET_S}s exhausted")
            continue
        answered = answer_events(repo)
        if answered is None:
            scan_failed += 1
            print(f"  SCAN FAILED (events) for {repo} — answer set is UNKNOWN")
            continue
        extra = []
        for n in sorted(answered):
            if (repo, n) in seen:
                continue
            # RE-ASK THE ISSUE'S OWN STATE, not the repo-wide event feed.
            # The feed cannot tell an owner removal from the gate's own bounce
            # removal (both are `unlabeled owner-decision`); the per-issue read
            # can, because it also sees the `question-bounced` label the bounce
            # writes (see `owner_answered_at`). Skipping a candidate here loses
            # nothing: the repo-wide event still exists, so the next tick
            # re-finds it. `None` is UNKNOWN — never deliver or fabricate on it.
            ua = owner_answered_at(repo, n)
            if ua is None:
                scan_failed += 1
                print(f"  SCAN FAILED (answer state) for {repo}#{n} — "
                      f"answer set is UNKNOWN for it")
                continue
            if not ua:
                continue
            nd = newest_decl_at(repo, n)
            if not (nd and ua >= nd):
                continue
            # Honour the idempotency marker. Pass 1 cannot see these issues (they
            # carry answer-delivered, so its filter skips them), which means an
            # already-delivered answer would be RE-NOTIFIED here — the one way this
            # pass could do harm. An unreadable label set (None) is treated as
            # already-delivered: silence is the safe failure mode for a re-notify.
            if has_label(repo, n, DELIVERED_LABEL) is not False:
                continue
            ev_ans[(repo, n)] = ua
            extra.append((repo, n))
        print(f"  {repo}: {len(answered)} answer-event(s), "
              f"{len(extra)} not already a candidate")
        pending.extend(extra)
    print(f"pending questions: {len(pending)}")
    rc = 0
    npass = nbounce = nans = 0
    for repo, n in pending[:MAX_SCAN]:
        # ── the other half of the handshake, checked BEFORE scoring ──────────
        # The owner answers by commenting and REMOVING `owner-decision`. Removing it
        # puts the issue straight back into the candidate set above — so without this
        # check an ANSWERED question is re-scored and pushed back into the queue,
        # which is worse than a question that never arrived. `owner-answered` is
        # applied once, so both the notification and the skip happen once.
        # An issue the EVENT pass already proved answered is NOT re-derived here.
        # Re-deriving it with a second live call means a transient read failure reads
        # as "not answered", which re-queues a question the owner has ALREADY
        # answered — the worst outcome available. Measured 2026-09-27: exactly that
        # turned tortoise#4155 into a BOUNCE minutes after it was found answered.
        # So: use the event pass's verdict when it has one, and when we DO have to
        # read, an unreadable answer state is UNKNOWN — never re-score on it.
        # (Plain `or` laundered that `None` into "not answered"; #1911 review.)
        if (repo, n) in ev_ans:
            ua = ev_ans[(repo, n)]
        else:
            ua = owner_answered_at(repo, n)
            if ua is None:
                scan_failed += 1
                print(f"  SCAN FAILED (answer state) for {repo}#{n} — "
                      f"answer set is UNKNOWN; not re-scoring it")
                continue
        nd = newest_decl_at(repo, n)
        if ua and nd and ua >= nd:
            routes = lane_workspaces(repo, n)
            if routes:
                verdict = "; ".join(
                    notify_lane(t, w, repo, n, dry) for t, w in routes)
            else:
                verdict = (f"NO LANE ROUTE for {repo}#{n} — none of its `lane:` labels "
                           f"resolve to a registry row, so the answer is reported to "
                           f"the orchestrator instead")
            if not dry:
                # BOTH. DELIVERED_LABEL is this script's own idempotency proof
                # and is the only one the scan consults; ANSWERED_LABEL is the
                # record the owner and the fleet read.
                args = ["gh", "issue", "edit", str(n), "--repo", repo,
                        "--add-label", ANSWERED_LABEL + "," + DELIVERED_LABEL]
                # Clear the bounce guard as well. Without this an answered-but-bounced
                # issue is invisible to the relay AND unclearable by the lane (only
                # the lane may remove that label), so the two wait on each other —
                # measured: tortoise#5199 sat that way 5h30m. A removal for a label
                # that is absent is a harmless no-op, so no pre-read is needed.
                args += ["--remove-label", BOUNCE_LABEL]
                sh(args)
            print(f"ANSWERED {repo}#{n} (owner replied {ua}) → {verdict}")
            nans += 1
            continue
        r = main([repo, str(n)] + (["--dry-run"] if dry else []))
        if r == 0:
            npass += 1
        elif r == 1:
            nbounce += 1
        rc = rc or r
    if len(pending) > MAX_SCAN:
        print(f"(capped at {MAX_SCAN} this tick; {len(pending) - MAX_SCAN} left "
              f"for the next)")
    # The LAST line is the machine-readable summary the heartbeat parses. It is
    # last on purpose: everything above it is for the log, and a caller that
    # takes tail -1 gets one stable line whether or not anything was pending.
    # A FAILED scan must never print a confident `pending=0`: that is the
    # silent-negative shape this file has already been bitten by twice. When a
    # repo could not be read, the count is UNKNOWN and says so. Measured
    # 2026-09-25: gh exit 127 from the loop (PATH) made this line read
    # `pending=0` for every tick while the scan was dead.
    if scan_failed:
        print(f"ASK pending=? pass={npass} bounce={nbounce} answered={nans}"
              f" scan_failed={scan_failed}")
    else:
        print(f"ASK pending={len(pending)} pass={npass} bounce={nbounce}"
              f" answered={nans}")
    return rc


def _bounce_detail(mech_findings, failures):
    """Name the exact occurrences a mechanical mark counted.

    The old bounce said only "internal shorthand", so a lane had to read this
    file to discover which axis (and, from 2026-10-17, which direction) the gate
    meant — measured on agent-infra#1553: eight rewrites, each fixing the wrong
    thing. The occurrences ARE the feedback: they are printed here, and they are
    the only thing the mark counted.
    """
    lines = []
    if "jargon_free" in failures:
        for kind, token in mech_findings.get("jargon_free", (0, []))[1]:
            lines.append(f"- `{token}` — {kind}, with no sentence explaining it. "
                         f"Say what it is in words, or drop it.")
    if "understandable" in failures:
        for finding in mech_findings.get("understandable", (0, []))[1]:
            lines.append(f"- {finding}. Split it into shorter sentences.")
    if not lines:
        return ""
    return "\n\n**Counted (this is the whole list — nothing else was measured):**\n" + \
        "\n".join(lines)


def score_text(text, repeat=1):
    """Offline scoring: no gh, no labels, no comments. Prints the marks.

    WHY IT EXISTS (agent-infra#1903). The only way to score a draft used to be to
    POST it to the PR as a `RESEARCH:` comment and run the gate — the issue's own
    measurement left seven question comments on one PR as a side effect of
    calibrating. `--score-file` is the offline path, and `--repeat N` is the NULL
    PAIR the owner ruling asks for: the same text scored N times, with the spread
    per mark printed. The mechanical marks are expected to show 0.00 spread by
    construction; a non-zero spread on a Jev mark is the variance that made the
    old language bar unusable.

    EXIT CODE IS THE GATE'S VERDICT, not "it ran" (#1911 review, P2): 0 = every
    mark clears its bar · 1 = this draft WOULD BOUNCE · 2 = could not check (no key /
    network), which is NOT a pass. It used to return 0 on every path, so a run that
    printed "this is NOT a pass" and a run that named a failing mark both exited
    green — the empty/UNKNOWN-read-as-success shape this file exists to refuse. A
    mechanical failure is definitive even when Jev is unreachable (that mark is
    computed from the text), so 1 outranks 2.

    ⛔ ONE STRIP, like the live gate: `language_marks` strips the declaration
    itself, so the raw text goes in here. Pre-stripping scored `prose_only(raw)`,
    i.e. the gate's text stripped TWICE, which disagrees with the gate whenever the
    question quotes a `RESEARCH:` line in its prose (a lane quoting the NO_RESEARCH
    template does exactly that) — an instrument that measures a text the gate never
    sees.
    """
    try:
        with open(text, errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        print(f"could not read {text}: {e}")
        return 2
    prose = prose_only(raw)
    runs, failed, unchecked = [], False, False
    for _ in range(max(1, repeat)):
        ans, findings = language_marks(raw)
        result = jev(prose)
        if result is not None:
            got = result.get("answers") or {}
            ans.update({k: v for k, v in got.items()})
            # A 200 with a PARTIAL body is not a check: `verdict()` only scores the
            # marks that are PRESENT, so an absent structural mark is silently
            # skipped and the draft reads PASS (#1911 review). Absence is UNKNOWN.
            missing = [m for m in QUESTIONS if m not in got]
            if missing:
                print("  jev returned no answer for " + ", ".join(missing)
                      + " — those marks were NOT evaluated")
                unchecked = True
        else:
            unchecked = True
        runs.append(ans)
        for name, a in ans.items():
            print(f"  {name:22} {a.get('noul')}")
        for name, (score, why) in findings.items():
            if score < threshold_for(name):
                print(f"    {name}: " + "; ".join(str(w) for w in why))
        fails, _ = verdict(ans)
        failed = failed or bool(fails)
        if fails:
            print("  failing (score<bar)    " + ", ".join(
                f"{n} {ans[n].get('noul')}<{threshold_for(n)}" for n in fails))
    if len(runs) > 1:
        print(f"null pair over {len(runs)} runs (spread = max - min):")
        for name in sorted({k for r in runs for k in r}):
            vals = [r[name]["noul"] for r in runs if name in r]
            if not vals:
                continue
            print(f"  {name:22} min={min(vals):.3f} max={max(vals):.3f} "
                  f"spread={max(vals) - min(vals):.3f}")
    if failed:
        print("VERDICT: this draft would BOUNCE.")
        return 1
    if unchecked:
        print("VERDICT: could not check (this is NOT a pass).")
        return 2
    print("VERDICT: this draft would PASS.")
    return 0


def main(argv):
    if len(argv) < 1:
        print(__doc__)
        return 2
    if argv[0] == "--scan":
        return scan("--dry-run" in argv)
    if argv[0] == "--score-file":
        # Offline path: a file, never an issue. See `score_text` for why.
        if len(argv) < 2 or argv[1].startswith("--"):
            print("--score-file needs a path")
            return 2
        rep = 1
        if "--repeat" in argv:
            i = argv.index("--repeat")
            rep = int(argv[i + 1]) if i + 1 < len(argv) and argv[i + 1].isdigit() else 1
        return score_text(argv[1], rep)
    repo, number = argv[0], int(argv[1])
    dry = "--dry-run" in argv
    skip_decl = "--skip-declaration" in argv  # calibration only

    text = fetch_question(repo, number)
    if text is None:
        print(f"could not read {repo}#{number}")
        return 2

    # STEP 0 — has the owner ALREADY answered this question?
    # A lane that re-runs the gate on an answered question must be told the answer
    # exists, not bounced over the wording of a question that is already settled.
    if not dry:
        ua = owner_answered_at(repo, number)
        if ua is None:
            # A failed read is UNKNOWN, never "not answered": scoring it could
            # bounce a question the owner has already answered, and (since
            # agent-infra#1903) the bounce would then remove the queue label.
            print(f"could not read the answer state for {repo}#{number} — "
                  f"UNKNOWN, this is NOT \"unanswered\". Nothing was scored; re-run.")
            return 2
        if ua and ua >= (newest_decl_at(repo, number) or ""):
            # BOTH labels: this path has told the lane too, so the scan must not
            # notify it a second time. DELIVERED_LABEL is the skip predicate.
            sh(["gh", "issue", "edit", str(number), "--repo", repo,
                "--add-label", ANSWERED_LABEL + "," + DELIVERED_LABEL])
            print(f"ANSWERED — the owner replied at {ua}. Read the comments after "
                  f"your `{DECL_MARK}` line on {repo}#{number}; not re-scored.")
            return 0

    # STEP 1 — the declaration (mechanical, deterministic).
    decl = declaration_present(text)
    if not skip_decl and decl in ("absent", "declared_no_research"):
        if not dry:
            body = NO_RESEARCH + BOUNCE_TAIL
            sh(["gh", "issue", "comment", str(number), "--repo", repo,
                "--body", body])
            # ⛔ A BOUNCE IS NOT A QUEUED QUESTION. Removing `owner-decision` is what
            # makes the pair readable: agent-infra#1553 carried BOTH
            # `owner-decision` (from a pass) and `question-bounced` (from later
            # bounces), so no reader — the owner, the heartbeat, or a lane picking
            # the PR up — could tell whether the question was live or returned
            # (agent-infra#1903). The bounce is authoritative; the pass re-adds the
            # queue label. `--remove-label` on an absent label is a no-op.
            sh(["gh", "issue", "edit", str(number), "--repo", repo,
                "--add-label", BOUNCE_LABEL, "--remove-label", "owner-decision"])
        print(f"BOUNCE ({decl}) → {repo}#{number}")
        return 1

    # STEP 2 — the judgement. ONE Jev call for the five STRUCTURAL marks; the two
    # language marks are computed here, from the text (agent-infra#1903).
    result = jev(prose_only(text))
    if result is None:
        return 2
    answers = result.get("answers", {})
    # ⛔ A PARTIAL Jev BODY IS NOT A CHECK. `verdict()` only scores the marks that are
    # PRESENT, so a 200 carrying none (or some) of the five structural marks used to
    # sail through as PASS while those marks were never evaluated — the same
    # empty-read-as-success shape this file exists to refuse (#1911 review). The two
    # language marks are computed below, so they are always present.
    missing = [m for m in QUESTIONS if m not in answers]
    if missing:
        print(f"jev returned no answer for {', '.join(missing)} — cannot check "
              f"(this is NOT a pass)")
        return 2
    mech, mech_findings = language_marks(text)
    answers.update(mech)
    failures, problem = verdict(answers)

    print(f"cost_usd={result.get('usage',{}).get('cost_usd')}")
    for name, ans in answers.items():
        if ans.get("type") == "noul":
            bar = "" if answers[name].get("noul", 0) >= threshold_for(name) else "  <-- below bar"
            print(f"  {name:22} {ans.get('noul')}{bar}")
    for name, (score, why) in mech_findings.items():
        if score < threshold_for(name):
            print(f"    {name}: " + "; ".join(str(w) for w in why))
    # ⛔ NAME THE FAILING MARK, NOT THE TEMPLATE — AND PRINT THE BAR BESIDE IT.
    # `jargon_free` and `understandable` share one bounce template ("jargon"), so
    # printing the template as the primary problem says "jargon" even when
    # `jargon_free` PASSED. Measured four times across 2026-10-07/08 (tortoise
    # #4932, #4667, and twice on #4764, where this line read `jargon` beside
    # `jargon_free 0.65`): a lane reading it chases the wrong axis. The bar is
    # printed because the thresholds are deliberately split — 0.80 structural,
    # 0.70 context, 0.55 for the two jargon marks — so a lane that must read this
    # file to learn which bar applies cannot act on the bounce it was handed.
    fails = ", ".join(
        f"{n} {answers[n].get('noul')}<{threshold_for(n)}" for n in failures
    ) or "none"
    worst = (min((answers[n].get("noul", 0.0), n) for n in failures)[1]
             if failures else "none")
    print(f"  primary_problem        {worst}")
    print(f"  failing (score<bar)    {fails}")
    print(f"  bounce_template        {problem}")

    if problem == "none" and not failures:
        if not dry:
            # ⛔ REMOVE THE STALE BOUNCE LABEL ON PASS. A question that bounces once and
            # then clears carries BOTH labels forever, and every reader that keys on
            # `question-bounced` (the heartbeat's ASK line, and the re-submission scan)
            # then reports `bounce=1 pass=0` — the OPPOSITE of the truth, on a question
            # that IS in the owner's queue. Measured 2026-10-04: #6234 bounced v1-v3,
            # passed v4, kept both labels, and the heartbeat reported pass=0 bounce=1.
            # `gh issue edit --remove-label` on an absent label is a no-op, so this is
            # safe for a first-try pass too.
            sh(["gh", "issue", "edit", str(number), "--repo", repo,
                "--add-label", "owner-decision",
                "--remove-label", BOUNCE_LABEL])
        print(f"PASS → labelled owner-decision: {repo}#{number}")
        return 0

    body = TEMPLATES.get(problem)
    if body is None:
        body = ("Sent back: the question did not clear these checks — "
                + ", ".join(failures) + ".")
    body += _bounce_detail(mech_findings, failures)
    body += BOUNCE_TAIL
    if not dry:
        sh(["gh", "issue", "comment", str(number), "--repo", repo,
            "--body", body])
        # Mark it, or the 5-minute scan repeats itself forever. The lane removes
        # this label to be re-checked; that is the entire handshake. As in STEP 1,
        # the bounce takes the question OUT of the queue: a bounced question is not
        # in the owner's queue, and leaving `owner-decision` on makes the artifact
        # unreadable (agent-infra#1903, agent-infra#1553).
        sh(["gh", "issue", "edit", str(number), "--repo", repo,
            "--add-label", BOUNCE_LABEL, "--remove-label", "owner-decision"])
    print(f"BOUNCE (primary={worst}"
          + (f"; failing: {fails}" if failures else "")
          + f"; template={problem}) → {repo}#{number}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
