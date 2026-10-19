#!/usr/bin/env python3
"""Proof that the beat has ONE dispatch entry point, and it is not the retired lane table.

WHY THIS FILE EXISTS (agent-infra#1874, the retirement half of agent-infra#1890).
The heartbeat used to run TWO independent dispatchers:

    queue-dispatch.py   a LANE-TABLE dispatcher — it could only feed a lane that already existed
                        and read DONE-IDLE, so it could not start work that had no lane. Measured
                        on the box: 8 conflicted PRs undrained while `lane-actions` read `idle=2`
                        (one of those a false idle, #1867), and it aborted ~48% of passes anyway
                        (#1876 — stderr glued into the roster JSON).
    pr-doctor.py        the drain. It sources its work from GitHub's branch-protection reality
                        instead of a queue row. Its SPAWN half — one load-gated background worker
                        per item through `nonblocking-dispatch.sh` — is PR #1894 (#1890) and is
                        NOT WIRED: the helper is in this tree (#1835) and called by nothing.
                        `pr-doctor` still gates on its `idle_lanes()` roster until #1894 merges.
                        This file does NOT assert the spawn — `#1890` owns wiring it.

Both paths live at once is the defect #1890 records, in its own words: *"a replacement that is
added but not switched on is indistinguishable from no replacement, except that it hides the old
one's flaws."* The lane table stayed the live one for a day because nothing asserted which path
the beat actually ran. These tests are that assertion, and they are written so that REMOVAL ALONE
CANNOT PASS: a suite that only asserts "queue-dispatch is not invoked" is green on an empty file,
on a renamed script, and on a beat that dispatches nothing at all. So every absence here is paired
with a positive — and with a POPULATION FLOOR, because a scan that examined nothing must never be
read as clean (the same rule `pi-bootstrap/tests/test-setup-no-nesting.sh` applies to its farm
count).

The rule these tests pin:
  * no live CODE re-arms the retired dispatcher. "Code" means: a string constant in a `.py` file
    (not a comment, not a docstring); an executable line in a shell script (extensionless
    included); a JS/TS source line outside its comments; a mention in a machine file (`.plist`,
    `.json`, `.template` — a rendered launchd template cannot carry a comment); a comment-stripped
    line in a `.yml`/`.toml`/`.conf`; and AN UNKNOWN SUFFIX, which fails closed rather than being
    skipped.
    PROSE is not code, but it IS executable in this repo (agents read `skills/*.md`,
    `docs/ops/*.md` and handoff notes and run what they say), so every document format — and every
    CLI-ish config — is scanned for a COMMAND SHAPE only (`python3 ...queue-dispatch.py`, the name
    followed by `--apply`) — never for a mention, so documenting the retirement cannot redden the
    gate that preserves it.
  * the beat does not run the retired dispatcher, and it does not run ANY second dispatch step:
    every executable path it names (`$SCRIPTS/x.py`, `${SCRIPTS}/x.py`, `"$SCRIPTS"/x.py`,
    `$STATE/.../x.py`) is either declared non-dispatch below or is the one dispatch entry point —
    with a POPULATION FLOOR on the enumeration;
  * the beat launches `pr-doctor.py` as the exact pinned detached invocation — NO arguments and NO
    env prefix, because `--dry-run`, `--status`, `--max 0` and `MAX_FIX=0 MAX_REVIEW=0` are each a
    way to make the pass decide nothing while reporting success;
  * the beat never assigns `MAX_FIX`/`MAX_REVIEW` anywhere — in the beat OR in a lib it sources
    into the same shell (the env is pr-doctor's capacity model, and an exported `0` is the same
    empty pass) — and no `if`/`elif` condition in the beat is LITERAL-ONLY (a branch that cannot
    observe the machine is dead, whatever it spells: `if false`, `if :`, `if [ 1 -eq 0 ]`), and the
    dispatch launch does not sit inside a shell function and is not guarded by an INVERTED disarm;
  * no farm array delivers the retired script and no launchd template schedules it;
  * the lane-table feeding vocabulary (the queue FILES) is gone from the beat's executable lines
    and from every live code file — which is the rename-proof half, since a copy of the retired
    dispatcher under a new name still reads those files;
  * the retired source is kept, annotated, and reachable from the note that retired it.

Run:  python3 -m pytest scripts/test_dispatch_wiring.py -q
"""
from __future__ import annotations

import ast
import pathlib
import re
import subprocess

_REPO = pathlib.Path(__file__).resolve().parent.parent
_BEAT = _REPO / "scripts" / "heartbeat-loop.sh"
_SETUP = _REPO / "pi-bootstrap" / "setup.sh"
_RETIRED = _REPO / "scripts" / "orchestrator-harness" / "retired" / "queue-dispatch.py"

# The retired script's basename, matched as a TOKEN inside a string/non-comment line. Deliberately
# NOT anchored to the whole string and NOT a bare substring: `queue-dispatch.py.bak` is not an
# invocation, and `"python3 queue-dispatch.py --apply"` is. IGNORECASE because the box is macOS
# (APFS is case-insensitive): `$SCRIPTS/Queue-Dispatch.py` resolves to the retired file and runs.
_TOKEN = re.compile(r"""(?<![\w.-])queue-dispatch\.py(?![\w.-])""", re.IGNORECASE)

# The files the lane-table design read. A RENAMED copy of the retired dispatcher does not carry its
# old name, but it still reads these — so this is the rename-proof half of the same property, and it
# is asserted over every live code file, not just the beat.
_QUEUE_TOKENS = ("LANE-ASSIGNMENTS", "CLAIMS.tsv", "LANDABLE.tsv", "REMEDY.tsv",
                 "CI-PRS.tsv", "CONFLICTS.tsv")

# Everything the beat launches from `$SCRIPTS`, EXCEPT the dispatch entry point. An ALLOWLIST: a new
# step (in any language) must be declared here, so a second dispatcher cannot arrive as "just
# another step". `lib` is sourced, not launched.
_NON_DISPATCH_STEPS = frozenset({
    "objective.py",               # reads the fleet's objective counters
    "lane-actions.py",            # classifies the lane roster
    "lane-watchdog.py",           # signals a frozen child
    "turn-classify.py",           # classifies why a turn ended
    "turn-end.py",                # nudges a lane turn-classify did not claim
    "orchestrator-heartbeat.sh",  # the fleet state tick
    "lane-scan-fallback.sh",      # detached roster scan when the tick has no fresh snapshot
    "beat-pair.sh",              # SOURCED into the beat's shell (beat-pair helpers), not launched
    "lib",                        # sourced helper directory (`$SCRIPTS/lib/...`)
})
_ASSIGNMENT_RUNS = re.compile(r"\$\(|`")
_DISPATCH_STEP = "pr-doctor.py"
# The EXACT detached launch the beat must use: a subshell, `nohup`, the absolute interpreter, the
# script path from `$SCRIPTS`, and then NOTHING BUT REDIRECTIONS — no argument of any kind
# (`--dry-run`, `--status`, `--max 0`) and no env prefix (`MAX_FIX=0 …`), because every one of
# those makes the pass dispatch nothing and return success.
# ⛔ GRADED ON THE LOGICAL (continuation-joined) COMMAND, NOT ON THE FIRST PHYSICAL LINE. Pinning
# a prefix of a backslash-continued command pins a prefix of it: an argument on the next line is
# the same argument to bash and was invisible here (measured 2026-10-19). `_logical_lines` is what
# makes the pin mean what its comment says.
_DISPATCH_LAUNCH = re.compile(
    r'^\(\s*nohup\s+/usr/bin/python3\s+"\$SCRIPTS/pr-doctor\.py"'
    r'(?:\s+(?:[12]?>>?|&>>?)\s*\S+)*\s*$')
# The ARM guard, pinned in its exact polarity: the kill file ABSENT is what makes the launch
# reachable. `-f` is the inverted polarity, refused STRUCTURALLY — on the condition that encloses
# the launch, read from `_enclosing_constructs` — never by matching this text anywhere in the file:
# the beat legitimately tests the same file to REPORT a disarmed dispatcher (#1933), and a text
# match graded that status branch as an inverted launch guard (measured 2026-10-19).
_DISPATCH_GUARD = 'if [ ! -f "$STATE/PR-DOCTOR-OFF" ]; then'
_DISPATCH_GUARD_INVERTED = re.compile(r'^\[\s*-f\s+"\$STATE/PR-DOCTOR-OFF"\s*\]$')
# The ONLY constructs allowed to enclose the launch: the pass loop and the three guards that make
# the launch both armed and single-instance. See `_enclosing_constructs`.
# ⛔ AN EARLY `continue` IS THE ONE SHAPE THAT DEFEATS EVERY OTHER REACHABILITY CHECK AT ONCE
# (measured 2026-10-19, adversarial review): `if [ -f "$STATE/pr-doctor.status.json" ]; then
# continue; fi` inserted just BEFORE the arm guard keeps the launch byte-identical; it opens AND
# closes its own construct (so `_enclosing_constructs` still returns exactly the pinned list), it
# sits deeper than the pass body (so an indentation-filtered skip scan never looks at it), and its
# condition contains a `$` (so the literal-condition check is silent). `pr-doctor.py` writes that
# sidecar on EVERY exit path, so the branch is true from the second pass on: the beat stops
# dispatching and keeps reporting healthy passes.
# So the control transfers that may appear between the pass header and the launch are PINNED, each
# with the construct it sits in. Any new `exit`/`continue`/`break`/`return` there — any
# indentation, any construct, including a brace group — changes this list and reads as RED.
_ALLOWED_EARLY_TRANSFERS = [
    ("exit 0", (("loop", "while :"), ("if", '[ -f "$STATE/HEARTBEAT-OFF" ]'))),
]
_DISPATCH_ENCLOSING = [
    ("loop", "while :"),
    ("if", '[ ! -f "$STATE/PR-DOCTOR-OFF" ]'),
    ("if", '[ -d "$STATE/pr-doctor.lock" ] && \\'),
    ("if", 'mkdir "$STATE/pr-doctor.lock" 2>/dev/null'),
]

_BINARY_SUFFIXES = frozenset({
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz", ".tgz",
    ".woff", ".woff2", ".ttf", ".otf", ".so", ".dylib", ".dll", ".pyc", ".db", ".sqlite",
})
# JS/TS sources: a launcher can be an ARGV ARRAY (`spawn("/usr/bin/python3", [".../x.py"])`), which
# a per-line interpreter-adjacency regex misses. Scanned with comments stripped.
_CODE_SUFFIXES = frozenset({".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"})
# Files with no comments: a mention anywhere in them is an invocation. `.template` is here on
# purpose — `scripts/orchestrator-harness/launchd.plist.template` is RENDERED into a live
# LaunchAgent by `scripts/orchestrator-harness/install.sh:72`, so a job added to it schedules itself on the box.
_RAW_MACHINE_SUFFIXES = frozenset({".plist", ".json", ".template", ".xml", ".service"})
# Files whose `#` comment lines are prose (CI workflows, crontab-shaped YAML, TOML). Graded like
# prose — a COMMAND SHAPE, not a mention — because a workflow that ASSERTS the retirement
# (`! grep -q queue-dispatch.py ...`) is a change that STRENGTHENS this gate, and reddening it
# teaches the next lane to edit this allowlist instead (#1897).
_HASH_COMMENT_SUFFIXES = frozenset({".yml", ".yaml", ".toml", ".conf"})
# Document formats. A MENTION in prose is the record; a COMMAND shape is an instruction — and in
# this repo prose is executable, because agents read `skills/*.md`, `docs/ops/*.md` and handoff
# notes and then run what they say. So every prose file is scanned, but only for `_INVOCATION`.
_PROSE_SUFFIXES = frozenset({".md", ".txt", ".rst", ".adoc"})
# The RECORD is allowed to name what was retired. ONE source of truth: `_is_record()` reads this
# tuple, so adding a record location here cannot silently leave the classifier on the old list.
_RECORD_PREFIXES = ("docs/", "scripts/orchestrator-harness/retired/")
_RECORD_FILES = ("scripts/test_dispatch_wiring.py", "AGENTS.md", "MEMORY.md",
                 "scripts/orchestrator-harness/README.md",
                 "scripts/orchestrator-harness/ARCHITECTURE.md")
# A prose mention is executable only when it reads as a COMMAND: an interpreter/binary in front of
# the name, or the name followed by its own flag. That is what an agent or an operator would run.
_INTERP = r"(?:[\w./-]*python[0-9.]*|bash|sh|node|exec|nohup|env)"
_INVOCATION = re.compile(
    r"(?:\b" + _INTERP + r"\s+[^\n]*queue-dispatch\.py)"
    r"|(?:queue-dispatch\.py\s+--(?:apply|status))", re.IGNORECASE)


def _invokes_retired(text: str) -> bool:
    """True when `text` carries a COMMAND that runs the dispatcher.

    Two normalisations, both measured against an earlier revision:
      * line continuations — `python3.12 x.py \\<newline>  --apply` is ONE command, and the
        adjacent-flag alternative cannot see it;
      * `python3.12` — the repo's own CI (`.github/workflows/ci.yml`) spells the interpreter that
        way, and `python3?` matched neither it nor `python3.12 -m`.
    A line that names the RETIRED LOCATION is the record, not an invocation: nothing farms
    `scripts/orchestrator-harness/retired/queue-dispatch.py` into a live scripts directory, so a CI
    or docs line asserting its existence must not redden the gate that preserves it.
    """
    joined = re.sub(r"\\\n", " ", text)
    for line in joined.splitlines():
        if "retired/" in line:
            continue
        if _INVOCATION.search(line):
            return True
    return False


def _is_record(name: str) -> bool:
    base = name.rsplit("/", 1)[-1]
    if name in _RECORD_FILES:
        return True
    # A TEST that asserts the retirement necessarily NAMES what was retired (in a string constant,
    # not a docstring). Grading it as a live armer reddens this gate on its own proof — measured:
    # adding `RETIRED = "queue-dispatch.py"` to a companion test failed, and the tempting fix was
    # to edit `_RECORD_FILES`, which is how a text-matching guard gets manufactured (#1897). Hence
    # a PREFIX rule, not a list of exact filenames.
    if base.startswith("test_") and "dispatch" in base:
        return True
    if not any(name.startswith(p) for p in _RECORD_PREFIXES):
        return False
    # `docs/` is the record, EXCEPT the ops runbooks — those are instructions and are scanned for
    # a command shape (not for a mention). `skills/**.md` is likewise an instruction to an agent.
    return not name.startswith("docs/ops/")


def _logical_lines(path: pathlib.Path) -> list[str]:
    """Bash's COMMAND view: a backslash-continued command is ONE command, so an argument written
    on the continuation line is that same command's argument.

    ⛔ MEASURED 2026-10-19 (adversarial review, two independent reviewers): the launch pin used to
    stop at the trailing backslash, so `--dry-run` written on the CONTINUATION line left the pin
    matching. `scripts/pr-doctor.py` honours `--dry-run`/`--status`/`--max 0`, and with the
    lane-table dispatcher retired it is the beat's ONLY dispatch entry point — so the fleet was
    fed nothing on every pass while the gate that exists to prove "it is really reachable"
    reported green. Presence of a pinned PREFIX is not the property; the whole COMMAND is.
    """
    out: list[str] = []
    pending = None
    for line in _executable_lines(path):
        if pending is not None:
            line = pending + " " + line
        if line.endswith("\\"):
            pending = line[:-1].rstrip()
            continue
        pending = None
        out.append(line)
    if pending is not None:
        out.append(pending)
    return out


_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][\w-]*)\1")


def _heredoc_free_lines(path: pathlib.Path) -> list[str]:
    """Every physical line, with HEREDOC BODIES REMOVED — one implementation, both views.

    ⛔ A HEREDOC BODY IS NOT CODE (measured 2026-10-19, adversarial review). Wrapping the dispatch
    in `: <<'UNUSED_PROSE' … UNUSED_PROSE` leaves every byte of the launch in place while bash
    executes none of it, and no construct list can see it — "comment out the step with a heredoc"
    is a normal way to disable a shell block. Stripping it HERE means both views agree: the
    launch is absent from the code view (so its ABSENCE reds) instead of being present in one
    view and absent from the other.

    The `<<'WORD'` / `<<"WORD"` / `<<WORD` / `<<-` forms all terminate on a line consisting of the
    word alone. A here-STRING (`<<<`) carries no body and is skipped.
    """
    out: list[str] = []
    terminator = None
    for line in path.read_text().splitlines():
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            continue
        out.append(line)
        # A COMMENT is never a here-doc opener, however it is spelled.
        if line.strip().startswith("#"):
            continue
        m = _HEREDOC.search(line)
        if m and "<<<" not in line:
            terminator = m.group(2)
    return out


def _executable_lines(path: pathlib.Path) -> list[str]:
    """The lines bash would actually RUN: heredoc bodies, comments and blank lines removed.

    This is the distinction the whole file rests on. A grep for `queue-dispatch` over the raw
    text finds the retirement note (and the two historical `QUEUE-DISPATCH FAILED` measurements
    that explain why TARGET is 540s) and would report a retired path as live — the same
    text-matching failure the repo has already paid for once (#1897: a hand-rolled guard "still
    matches every string a text-based wiring test greps for").
    """
    return [s for s in (line.strip() for line in _heredoc_free_lines(path))
            if s and not s.startswith("#")]


def _executable_raw(path: pathlib.Path) -> list[str]:
    """Same set of lines as `_executable_lines`, but with INDENTATION INTACT — reachability is a
    property of nesting, and stripping the indent throws it away."""
    return [line for line in _heredoc_free_lines(path)
            if line.strip() and not line.strip().startswith("#")]


_FUNC_DEF = re.compile(r"^([A-Za-z_][\w-]*)\s*\(\)\s*\{")


def _enclosing_functions(path: pathlib.Path, needle: str) -> list[str]:
    """Names of the shell functions whose body contains `needle`.

    A dispatch wrapped in `run_pr_doctor() { ... }` that is never called keeps every text
    assertion in this file green and dispatches nothing (measured). Two shapes matter here: a
    one-liner (`elapsed() { ...; }`, closed on its own line) and a multi-line body closed by a `}`
    at the definition's own indentation. Anything else stays OPEN on purpose — this helper fails
    closed, because the failure it guards is a dispatch that no caller reaches.
    """
    open_fns: list[tuple[int, str]] = []
    for line in _executable_raw(path):
        indent = len(line) - len(line.lstrip())
        m = _FUNC_DEF.match(line.strip())
        if m and "}" not in line.strip()[m.end():]:
            open_fns.append((indent, m.group(1)))
        if needle in line and any(fi < indent for fi, _ in open_fns):
            return [name for fi, name in open_fns if fi < indent]
        if open_fns and line.strip().startswith("}") and indent <= open_fns[-1][0]:
            open_fns.pop()
    return []


_OPEN_IF = re.compile(r"^if\s+(.+?)(?:\s*;\s*then)?$")
_OPEN_LOOP = re.compile(r"^(while|until)\s+(.+?)(?:\s*;\s*do)?$")
_OPEN_FOR = re.compile(r"^for\s+(.+?)(?:\s*;\s*do)?$")
_OPEN_CASE = re.compile(r"^case\s+(.+?)\s+in\b")
_OPEN_FUNC = re.compile(r"^(?:function\s+)?([A-Za-z_][\w-]*)\s*(?:\(\s*\))?\s*\{")
_CLOSER = re.compile(r"^(?:fi|done|esac)\b|^\}")


def _enclosing_constructs(path: pathlib.Path, needle: str):
    """The bash constructs that ENCLOSE `needle`, outermost first, as `(kind, subject)` pairs.

    ⛔ THIS IS THE REACHABILITY ASSERTION, AND IT IS WHY IT IS STRUCTURAL. Five review cycles each
    found a NEW spelling that defeated a pattern-matching reachability check: `if false`, then
    `if [ 1 -eq 0 ]`, then a quoted literal, then a one-liner, then `function name {`, then — the
    one that matters — `if [ -n "${PR_DOCTOR_ENABLE}" ]; then` around the whole dispatch, which is
    exactly how an env feature flag would be written and exactly the "added but not switched on"
    inversion #1890 exists to remove. Enumerating spellings loses that race by construction. So the
    assertion is not "does this condition look dead" but "is the launch inside ANY construct we did
    not pin" — a new `if`/`elif`/`while`/`until`/`for`/`case`/function of any wording, condition or
    indentation changes this list and reads as RED.
    """
    stack: list[tuple[str, str]] = []
    for line in _executable_raw(path):
        s = line.strip()
        found = needle in s
        if _CLOSER.match(s):
            if stack:
                stack.pop()
            continue
        opened = None
        m = _OPEN_CASE.match(s)
        if m:
            opened = ("case", m.group(1))
        else:
            m = _OPEN_FUNC.match(s)
            if m and "}" not in s[m.end():]:
                opened = ("func", m.group(1))
            else:
                m = _OPEN_LOOP.match(s)
                if m:
                    opened = ("loop", "%s %s" % (m.group(1), m.group(2)))
                else:
                    m = _OPEN_FOR.match(s)
                    if m:
                        opened = ("for", m.group(1))
                    else:
                        m = _OPEN_IF.match(s)
                        # A ONE-LINER (`if …; then …; fi`) opens and closes on its own line.
                        if m and not re.search(r";\s*fi$", s):
                            opened = ("if", m.group(1))
        if found:
            return list(stack)
        if opened:
            stack.append(opened)
    return None


_TRANSFER_WORD = re.compile(r"(?:exit|continue|break|return)\b")
# A statement boundary: start of line, then any of `;`, `&&`, `||`, `|`, `&`, or an opening
# brace/paren. `then`/`do`/`else` are separators too — `if …; then continue; fi` puts the transfer
# after `then`, and `while :; do break; done` after `do`.
_STMT_BOUNDARY = re.compile(r"(?:^|[;&|(){}\s]|\bthen\b|\bdo\b|\belse\b)\s*")


def _leading_statement(s: str) -> str | None:
    """The first command-position statement on `s` that is a control transfer, if any.

    A transfer is only a transfer in COMMAND POSITION. `echo "continue"`, a flag named
    `--continue`, and a message containing the word are not transfers, so matching the word
    anywhere would red a legitimate beat — which is why the earlier revision matched only at the
    start of the line. But that missed the ONE-LINE forms, which are exactly the shape that
    silently ends the pass (`if [ -f "$STATE/x" ]; then continue; fi`, `[ … ] && exit 0`,
    `{ … && continue; }`) — measured 2026-10-19: all four left the pinned transfer list, the
    enclosing-construct list and the function list BYTE-IDENTICAL and 13/13 green.
    So: walk the line's statements and test each one's COMMAND POSITION.
    """
    pos = 0
    while pos <= len(s):
        m = _TRANSFER_WORD.match(s, pos)
        if m:
            # Command position? Either the line start, or immediately after a boundary.
            head = s[:pos]
            if not head.strip() or _STMT_BOUNDARY.search(head) and not _word_prefixed(head):
                end = _stmt_end(s, pos)
                return s[pos:end].strip()
        # Advance to the next boundary.
        nxt = _STMT_BOUNDARY.match(s, pos)
        pos = nxt.end() if nxt and nxt.end() > pos else pos + 1
    return None


def _word_prefixed(head: str) -> bool:
    """True when the text just before a would-be transfer is a WORD, not a separator.

    `not continue` / `x-continue` must not read as a transfer; `foo; continue` must."""
    stripped = head.rstrip()
    if not stripped:
        return False
    return stripped[-1] not in ";&|(){}then do else".replace(" ", "") and not stripped.endswith(
        ("then", "do", "else"))


def _stmt_end(s: str, pos: int) -> int:
    """Index where the statement starting at `pos` ends — the next unquoted `;`, `&`, `|` or `}`."""
    depth = 0
    quote = None
    i = pos
    while i < len(s):
        ch = s[i]
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")" and depth:
            depth -= 1
        elif ch in ";&|}" and depth == 0:
            # `&&`/`||` continue the same command list, but the transfer ends at the operator.
            return i
        i += 1
    return len(s)


def _early_transfers(path: pathlib.Path, needle: str):
    """Every control transfer between the pass header and `needle`, with its enclosing constructs.

    The construct stack is maintained exactly as `_enclosing_constructs` does, but a transfer is
    recorded WHEREVER it sits — including inside a construct that opens and closes before the
    launch, which is the shape that makes the enclosing-stack assertion blind to it.

    Both the multi-line form (`continue` on its own line) and the ONE-LINE forms are recorded; see
    `_leading_statement`. A one-liner's construct opens AND closes on its line, so it is
    deliberately NOT pushed — the transfer is what makes it visible.
    """
    out = []
    stack: list[tuple[str, str]] = []
    started = False
    for line in _executable_raw(path):
        s = line.strip()
        if not started:
            if s != "while :; do":
                continue
            started = True
            stack.append(("loop", "while :"))
            continue
        if needle in s:
            return out
        transfer = _leading_statement(s)
        if transfer:
            out.append((transfer, tuple(stack)))
        if _CLOSER.match(s):
            if stack:
                stack.pop()
            continue
        opened = None
        m = _OPEN_CASE.match(s)
        if m:
            opened = ("case", m.group(1))
        else:
            m = _OPEN_FUNC.match(s)
            if m and "}" not in s[m.end():]:
                opened = ("func", m.group(1))
            else:
                m = _OPEN_LOOP.match(s)
                if m:
                    opened = ("loop", "%s %s" % (m.group(1), m.group(2)))
                else:
                    m = _OPEN_FOR.match(s)
                    if m:
                        opened = ("for", m.group(1))
                    else:
                        m = _OPEN_IF.match(s)
                        if m and not re.search(r";\s*fi$", s):
                            opened = ("if", m.group(1))
        if opened:
            stack.append(opened)
    return None


# `if`/`elif` conditions. `while`/`until` are handled separately: `while :; do` is this file's
# main loop, so a literal condition is only suspicious there when it is `false`/`true`.
_IF_CONDITION = re.compile(r"^(?:if|elif)\s+(.+?)(?:\s*;\s*then\b|$)")
_LITERAL_CONDITION = re.compile(r'^[A-Za-z0-9_:!<>=\[\]."\'\s-]+$')


def _is_literal_condition(condition: str) -> bool:
    """True when a branch condition cannot observe anything: no variable, no command
    substitution, no path. `false`, `:`, `1 -eq 0`, `0 -ne 0`, `[ x = x ]` all reduce to a
    constant, so the branch is dead (or its negation is). Generic on purpose — an earlier revision
    denied the literals `false` and `:` only, and `if [ 1 -eq 0 ]` around the whole dispatch kept
    every test green (measured)."""
    c = re.sub(r"^\[+\s*", "", condition.strip())
    c = re.sub(r"\s*\]+$", "", c).strip()
    if not c or "$" in c or "`" in c:
        return False
    return bool(_LITERAL_CONDITION.match(c))


# Every executable path the beat names, in EVERY spelling bash accepts: `$SCRIPTS/x.py`,
# `${SCRIPTS}/x.py`, `"$SCRIPTS"/x.py`, `$STATE/queues/x.py`. A literal `$SCRIPTS/` match missed
# braces and quoting (measured: `${SCRIPTS}/lane-feed.py` as a second dispatch step stayed green),
# and `$STATE/` is where the retired step's own companion lived, so it is a natural home for a
# re-grown one.
_EXEC_PATH_REF = re.compile(r'\$\{?(SCRIPTS|STATE|HOME)\}?"?/([\w./-]+)')
# Extensionless files are real executables in this repo (`sync`, `scripts/verify-cutover`), so a
# path handed to an interpreter is enumerated WHATEVER its suffix — `$SCRIPTS/lane-feed` was a
# measured defeat of a suffix-anchored enumerator. `$STATE` carries logs and lock files, so there
# only an explicit `.py`/`.sh` counts.
_EXEC_SUFFIXES = (".py", ".sh")


def _tracked_text_files() -> list[pathlib.Path]:
    """Every tracked + untracked-but-not-ignored file with no NUL byte in it.

    A hardcoded root tuple (or a suffix allowlist) is what left `templates/` and `tools/`
    unscanned in an earlier revision, and an extensionless launcher is invisible to a suffix
    allowlist; `git ls-files` also picks up a NEW directory nobody has added to any list yet —
    which is exactly where a re-armed scheduler would land.
    """
    try:
        raw = subprocess.run(["git", "-C", str(_REPO), "ls-files", "-z", "--cached", "--others",
                              "--exclude-standard"], capture_output=True, timeout=120)
        names = [n for n in raw.stdout.decode(errors="replace").split("\0") if n]
    except Exception:                                        # noqa: BLE001 - fall back, never skip
        names = [str(p.relative_to(_REPO)) for p in _REPO.rglob("*")
                 if p.is_file() and ".worktrees" not in p.parts]
    out = []
    for name in names:
        if _is_record(name):
            continue
        p = _REPO / name
        if not p.is_file() or p.suffix.lower() in _BINARY_SUFFIXES:
            continue
        try:
            head = p.open("rb").read(8192)
        except OSError:
            continue
        if b"\0" in head:
            continue
        out.append(p)
    return out


def _mentions(text: str) -> bool:
    return bool(_TOKEN.search(text))


def _strip_code_comments(text: str) -> str:
    """Remove `//` line comments and `/* ... */` blocks from a JS/TS-family source file."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in text.splitlines())


def _strip_hash_comments(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith("#"))


def _python_code_strings(path: pathlib.Path) -> list[str]:
    """Every string CONSTANT that is not a docstring — i.e. the strings a Python file actually
    uses as data (paths, argv elements, shell command lines)."""
    import warnings

    text = path.read_text(errors="replace")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(text)
    except SyntaxError:
        return [l for l in text.splitlines() if not l.strip().startswith("#")]
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", None) or []
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                docstrings.add(id(body[0].value))
    return [n.value for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docstrings]


def _python_rearms(path: pathlib.Path) -> bool:
    """True when a STRING CONSTANT (not a comment, not a docstring) names the retired script.

    Docstrings are prose and are skipped: `lane-guard.py`, `lane-status.py`, `lane-actions.py` and
    `orchestrator-heartbeat.sh` still DISCUSS the dispatcher, and that history is the reason the
    guards they describe exist. A docstring is a bare `Expr(Constant)` at the head of a
    module/class/function, so it is identified structurally rather than by guessing at prose.
    """
    return any(_mentions(chunk) for chunk in _python_code_strings(path))


def _rearming_files() -> list[pathlib.Path]:
    hits = []
    for p in _tracked_text_files():
        suffix = p.suffix.lower()
        text = p.read_text(errors="replace")
        if suffix == ".py":
            if _python_rearms(p):
                hits.append(p)
        elif suffix in (".sh", ".bash") or not suffix:
            if p.name.endswith(".test.sh"):
                # ⛔ A `.test.sh` IS A SHELL SCRIPT CI RUNS, so it is graded like one AND for a
                # command shape. Grading it on the command shape ALONE (an earlier revision) let a
                # test file `cp` the retired file out of `retired/` and run the copy, and let
                # `python3 …/retired/queue-dispatch.py --apply` pass because `_invokes_retired`
                # skips any line naming `retired/` — that skip exists so a DOC can assert the
                # retired location, and it does not apply to a line that executes it (both
                # measured 2026-10-19 by an adversarial review).
                if _invokes_retired(text) or any(_mentions(l) for l in _executable_lines(p)):
                    hits.append(p)
            elif any(_mentions(l) for l in _executable_lines(p)):
                hits.append(p)
        elif suffix in _CODE_SUFFIXES:
            if _mentions(_strip_code_comments(text)):
                hits.append(p)
        elif suffix in _RAW_MACHINE_SUFFIXES:
            if _mentions(text):
                hits.append(p)
        elif suffix in _HASH_COMMENT_SUFFIXES:
            if _invokes_retired(_strip_hash_comments(text)):
                hits.append(p)
        elif suffix in _PROSE_SUFFIXES:
            # Only a COMMAND shape counts. A gate that reds on a mention of what was retired
            # teaches the next lane to delete the record instead of the path.
            if _invokes_retired(text):
                hits.append(p)
        else:
            # ⛔ AN UNKNOWN SUFFIX FAILS CLOSED. Leaving it unscanned is how
            # `scripts/orchestrator-harness/launchd.plist.template` (`.template`) shipped a
            # scheduled job past this file: it matched no class above, so a re-armed job there
            # read as clean while `install.sh` rendered it into a LaunchAgent on every box.
            if _mentions(text):
                hits.append(p)
    return hits


def _live_code_referencing(tokens: tuple[str, ...]) -> dict[str, list[str]]:
    """{token: [paths]} over every live file's EXECUTABLE code — comments and docstrings excluded,
    because the record is allowed to name what was retired. Used for the queue FILES, whose
    appearance in live code is a feed even when the retired script's name is absent."""
    hits: dict[str, list[str]] = {}
    for p in _tracked_text_files():
        suffix = p.suffix.lower()
        if suffix == ".py":
            code = _python_code_strings(p)
        elif suffix in (".sh", ".bash") or not suffix:
            code = _executable_lines(p)
        else:
            continue                      # prose and machine files do not "read" a queue file
        for token in tokens:
            if any(token in chunk for chunk in code):
                hits.setdefault(token, []).append(str(p.relative_to(_REPO)))
    return hits


# ---------------------------------------------------------------------------
# Nothing live re-arms the retired dispatcher
# ---------------------------------------------------------------------------

def test_no_live_file_re_arms_the_retired_dispatcher():
    scanned = _tracked_text_files()
    assert len(scanned) >= 100, (
        "the scan examined only %d files — an empty or broken scan must never read as clean"
        % len(scanned))
    hits = _rearming_files()
    assert hits == [], (
        "the retired dispatcher is invoked or scheduled from live files (the record — `docs/`, "
        "`scripts/orchestrator-harness/retired/`, `scripts/test_*dispatch*.py`, and AGENTS.md — "
        "may name it): %s"
        % ", ".join(str(p.relative_to(_REPO)) for p in hits))


def test_no_launchd_template_schedules_the_retired_dispatcher():
    """The repo's scheduling surfaces are `templates/launchd/*.plist` (installed with no allowlist)
    AND `scripts/orchestrator-harness/launchd.plist.template`, which `install.sh` renders into a
    live LaunchAgent on the box. Graded on a mention: an XML job carries no way to comment one
    out."""
    templates = sorted((_REPO / "templates" / "launchd").glob("*.plist"))
    templates.append(_REPO / "scripts" / "orchestrator-harness" / "launchd.plist.template")
    missing = [p.name for p in templates if not p.is_file()]
    assert len(templates) > 1 and not missing, (
        "a launchd surface this test names is missing (%s) — fix the test, not the silence" % missing)
    assert any(p.parent.name == "launchd" for p in templates), (
        "no launchd template found — this test is looking at the wrong tree")
    offenders = [p.name for p in templates if _mentions(p.read_text(errors="replace"))]
    assert offenders == [], (
        "a launchd template schedules the retired dispatcher: %s. `install-launchd.sh` installs "
        "`templates/launchd/*.plist` with no allowlist, and the harness template is rendered into "
        "a live LaunchAgent, so this would re-arm it on every box."
        % ", ".join(offenders))


# ---------------------------------------------------------------------------
# The beat: the retired step is gone, the survivor is really invoked
# ---------------------------------------------------------------------------

def test_the_beat_does_not_run_the_lane_table_dispatcher():
    offenders = [l for l in _executable_lines(_BEAT) if "queue-dispatch" in l.lower()]
    assert not offenders, (
        "heartbeat-loop.sh still RUNS the retired lane-table dispatcher on: %r\n"
        "It was retired by #1874/#1890 because it can only feed a lane that already exists; "
        "`pr-doctor.py` is the replacement. Do not re-add a second dispatch path." % offenders)


def test_the_beat_still_runs_the_surviving_dispatcher():
    """The positive control: absence-only tests pass on a beat that dispatches nothing.

    ⛔ PINNED AS A WHOLE LINE, NOT FILTERED BY A LIST OF BAD FLAGS. Earlier revisions denied
    `--dry-run`/`--status`/`--only` and then a bare `--max 0` (and `MAX_FIX=0 MAX_REVIEW=0`, which
    `pr-doctor.py`'s `capacity()` accepts) walked past: every one of those makes the pass dispatch
    nothing and return success. A positive control that must enumerate the ways to make the pass a
    no-op loses the enumeration, so the whole launch line is the assertion.

    ⛔ AND PRESENCE IS NOT REACHABILITY. The launch text surviving in a branch nothing takes — the
    disarm guard inverted to `-f`, or the whole block wrapped in a function no one calls — is the
    same silent green. Both were measured against an earlier revision, which is why the guard is
    pinned in its exact polarity and the enclosing-function check exists.
    """
    lines = _logical_lines(_BEAT)
    launches = [l for l in lines if _DISPATCH_STEP in l]
    assert launches, (
        "heartbeat-loop.sh no longer invokes %s. The lane-table dispatcher is retired, so if this "
        "is gone the beat has NO dispatch entry point at all — a silent green, not a removal."
        % _DISPATCH_STEP)
    assert any(_DISPATCH_LAUNCH.match(l) for l in launches), (
        "the beat's dispatch launch is not the pinned detached invocation. Got: %r\n"
        "Expected exactly: ( nohup /usr/bin/python3 \"$SCRIPTS/pr-doctor.py\" ] redirects\n"
        "Arguments are a way to make the pass a no-op (`--dry-run`, `--status`, `--max 0`), and so "
        "is an env prefix (`MAX_FIX=0 MAX_REVIEW=0`). The match is against the LOGICAL line, so an "
        "argument on a continuation line reds too. Change this pin WITH the launch, deliberately."
        % launches)
    # The DISARM guard, in the polarity that actually dispatches. `-f` here means the beat feeds
    # PRs only once an operator has switched pr-doctor OFF — i.e. it never dispatches, and every
    # other assertion here stays green (measured).
    assert _DISPATCH_GUARD in lines, (
        "the beat no longer contains the guard %r as its own line. That line is what ARMS the "
        "dispatch (the kill file ABSENT); pinning it is what makes the launch reachable."
        % _DISPATCH_GUARD)
    # ⛔ THE REACHABILITY ASSERTION — STRUCTURAL, NOT A SPELLING MATCH. Whatever encloses the
    # launch must be EXACTLY the pass loop and the three guards below. A new `if`/`elif`/`while`/
    # `until`/`for`/`case`/function — an env feature flag (`if [ -n "${PR_DOCTOR_ENABLE}" ]`), a
    # `case` on a mode variable, a one-line `if [ 1 -eq 0 ]; then … fi`, `function name {` — adds a
    # construct to this list and reds, whatever its condition says. Five cycles of denylisting
    # spellings each lost the next one; this does not have spellings.
    constructs = _enclosing_constructs(_BEAT, _DISPATCH_STEP)
    # ⛔ THE DISARM POLARITY IS GRADED ON THE CONSTRUCT THAT ENCLOSES THE LAUNCH, NOT ON THE FILE.
    # (Rebase onto agent-infra#1933, measured 2026-10-19.) The beat now ALSO tests `PR-DOCTOR-OFF` to
    # REPORT a disarmed dispatcher — `if [ -f "$STATE/PR-DOCTOR-OFF" ]; then printf 'PR-DOCTOR
    # DISARMED …'` — which is a status branch, not a launch guard. A whole-file text scan reads that
    # reporting line as the arm guard inverted and reds a beat whose launch is correctly armed, so
    # the reading is taken from `_enclosing_constructs` (the same source as the reachability
    # assertion below) instead of from the file's text.
    inverted = [c for (kind, c) in (constructs or [])
                if kind == "if" and _DISPATCH_GUARD_INVERTED.match(c)]
    assert inverted == [], (
        "the dispatch's disarm guard is INVERTED (%r): with `-f`, pr-doctor runs only when an "
        "operator has disarmed it, so the beat dispatches nothing in its normal state."
        % inverted)
    assert constructs == _DISPATCH_ENCLOSING, (
        "the dispatch launch is enclosed by %r — expected exactly %r. Anything else here is a "
        "branch, loop, case or function that can make the launch unreachable while the pinned text "
        "survives (measured: `if [ -n \"${PR_DOCTOR_ENABLE}\" ]` around the whole block dispatched "
        "nothing and stayed green)." % (constructs, _DISPATCH_ENCLOSING))
    wrapped = _enclosing_functions(_BEAT, _DISPATCH_STEP)
    assert wrapped == [], (
        "the dispatch launch is inside the shell function(s) %r. A function that is never called "
        "keeps the pinned text and dispatches nothing — exactly the no-op this file refuses."
        % wrapped)
    # And the pass must not be EXITED or skipped before it reaches the launch. Graded as a PINNED
    # LIST rather than as an indentation-filtered search: the `if …; then continue; fi` shape closes
    # before the launch, so it never enters the enclosing stack, and its indent is not the pass's own
    # (measured 2026-10-19 — 13 green on a beat that never dispatches again).
    transfers = _early_transfers(_BEAT, _DISPATCH_STEP)
    assert transfers is not None, "the launch was not found while walking the pass — see above"
    assert transfers == _ALLOWED_EARLY_TRANSFERS, (
        "the pass contains control transfer(s) before the dispatch that are not declared: %r — "
        "expected exactly %r. A `continue`/`exit`/`break`/`return` anywhere between the pass header "
        "and the launch makes it unreachable while every pinned string survives; if the new transfer "
        "is legitimate, declare it in _ALLOWED_EARLY_TRANSFERS deliberately."
        % (transfers, _ALLOWED_EARLY_TRANSFERS))


def _sourced_libs() -> list[pathlib.Path]:
    """The libs the beat SOURCES into its own shell before the dispatch (`. "$SCRIPTS/lib/x.sh"`).

    A capacity export there is in the beat's environment even though the line lives in another
    file — and that is where an `export MAX_FIX=0` naturally belongs, because
    `scripts/lib/beat-pair.sh` is farmed to the box and sourced at the top of the beat (measured).
    """
    out = []
    for line in _executable_lines(_BEAT):
        # `. "$SCRIPTS/x.sh"`, `source "$SCRIPTS/x.sh"`, `. $SCRIPTS/x.sh` and the `$HOME` spelling
        # of the same directory are all the SAME act; matching only the first lost the capacity
        # export entirely (measured).
        m = re.search(r'(?:\bsource\b|(?<![\w.])\.)\s+"?\$\{?(?:SCRIPTS|HOME)\}?"?/?'
                      r'([\w./-]+)"?', line)
        if not m:
            continue
        rel = m.group(1)
        if "scripts/" in rel:
            rel = rel.split("scripts/", 1)[1]
        p = _REPO / "scripts" / rel
        if p.is_file():
            out.append(p)
    return out


def test_the_beat_cannot_zero_the_dispatch_capacity_it_launches():
    """`pr-doctor` reads MAX_FIX/MAX_REVIEW from the ENVIRONMENT first (`capacity()`), and accepts
    `0` — so an `export MAX_FIX=0` anywhere in the beat's shell is the same empty pass as
    `--max 0`, and it does not appear on the launch line at all. Measured: that spelling passed an
    earlier revision. Scanned over the beat AND every lib it sources into the same shell, because
    the export works from there too (measured)."""
    sources = [_BEAT] + _sourced_libs()
    assert _sourced_libs(), (
        "the sourced-lib scan found nothing — the beat sources its beat-pair lib, so a scan that "
        "examined only the beat must not read as clean")
    bad = ["%s: %s" % (p.name, l) for p in sources for l in _executable_lines(p)
           if re.search(r"\bMAX_(FIX|REVIEW)\s*=", l)
           # `printf -v MAX_FIX '%s' 0` is the same assignment with no `=` (measured 2026-10-19).
           or re.search(r"\bprintf\s+-v\s+MAX_(FIX|REVIEW)\b", l)]
    assert bad == [], (
        "the dispatch capacity is assigned on %r. pr-doctor reads MAX_FIX/MAX_REVIEW from the "
        "environment and accepts 0, so this silently empties every pass while the beat reports a "
        "healthy run. The capacity belongs to the machine's orchestrator plist (#1870), not to "
        "the beat." % bad)


def test_the_beat_has_no_dead_branch_around_the_dispatch():
    """`if false; then <launch> fi` keeps the pinned text and dispatches nothing. A launch the
    interpreter never reaches is the same silent green this file exists to refuse.

    ⛔ GRADED ON THE CONDITION, NOT ON A LITERAL DENYLIST. Matching the keywords `false`/`:` only
    let `if [ 1 -eq 0 ]; then` around the whole dispatch pass all 13 tests (measured), and that is
    the OVERWHELMINGLY more natural spelling — the beat's guards are all `[ ... ]` tests. Any
    `if`/`elif` whose condition cannot observe the machine is a dead branch.
    """
    bad = []
    for line in _executable_raw(_BEAT):
        s = line.strip()
        if re.match(r"^(?:while\s+false|until\s+true)\b", s):
            bad.append(s)
            continue
        m = _IF_CONDITION.match(s)
        if m and _is_literal_condition(m.group(1)):
            bad.append(s)
    assert bad == [], (
        "heartbeat-loop.sh contains a dead branch (%r). A pinned launch inside it never runs."
        % bad)


def test_pr_doctor_is_the_only_dispatch_step_the_beat_launches():
    """One dispatch path, named. A new step must be declared, not slipped in beside the old one.

    Enumerated over EVERY executable path the beat names — not just `.py` — because the beat's own
    normal launch shape is `run_bounded ... /bin/bash "$SCRIPTS/<step>"`, so a shell-script second
    dispatcher would otherwise be invisible (measured against an earlier revision). The spelling
    set is bash's whole vocabulary on purpose: a literal `$SCRIPTS/` match missed `${SCRIPTS}/`,
    `"$SCRIPTS"/` and `$STATE/`, and a second dispatch step written with any of those stayed green
    (measured — the retired step's own companion lived under `$STATE/queues/`).
    """
    launched = set()
    for line in _executable_lines(_BEAT):
        if re.match(r"^(?:export\s+)?[A-Z_][A-Z0-9_]*=", line) and not _ASSIGNMENT_RUNS.search(line):
            # An assignment (`SCRIPTS="$HOME/.../scripts"`) is not a launch. `export` is the same
            # assignment: the beat sets `export O="${O:-$HOME/orchestrator}"` (agent-infra#1988),
            # whose default is a DIRECTORY, and a scan that read it as a step enumerated the
            # basename `orchestrator` as an undeclared launch (measured 2026-10-19 on the rebase).
            #
            # ⛔ BUT A VALUE THAT COMMANDS IS NOT AN ASSIGNMENT, and `NAME=…` is how a step hides
            # from this enumeration: `export LANE_FEED="$(/usr/bin/python3 "$SCRIPTS/lane-feed.py"
            # --apply)"` ran a second dispatcher with every test green (measured 2026-10-19). A
            # command substitution or a backtick in the value means the line EXECUTES, so it is
            # enumerated like any other line instead of skipped.
            continue
        # Quote-strip first: `"$SCRIPTS"/"lane-feed.py"` is the same path with the quotes moved,
        # and it defeated a regex that required the basename to follow the slash directly
        # (measured). `$HOME/.pi/agent/scripts` is the same directory as `$SCRIPTS` — the beat
        # defines one from the other — so both roots are enumerated.
        flat = line.replace('"', "").replace("'", "")
        for root, name in _EXEC_PATH_REF.findall(flat):
            base = name.rsplit("/", 1)[-1]
            if not base or base.endswith((".log", ".lock", ".pid", ".tsv", ".json", ".txt")):
                continue
            if root == "STATE" and not base.endswith(_EXEC_SUFFIXES):
                continue
            launched.add(base)
    # POPULATION FLOOR: a regex that stopped matching must read as RED, never as "no undeclared
    # steps" — that is the same inverted-green this whole file exists to refuse.
    floor = {"pr-doctor.py", "turn-end.py", "turn-classify.py", "lane-actions.py"}
    assert floor <= launched, (
        "the launch enumeration saw only %s (expected at least %s). The beat still launches these, "
        "so an enumerator that cannot see them cannot see a second dispatch step either."
        % (sorted(launched), sorted(floor)))
    undeclared = launched - _NON_DISPATCH_STEPS - {_DISPATCH_STEP}
    assert undeclared == set(), (
        "the beat launches step(s) that are neither declared non-dispatch nor the dispatch entry "
        "point: %s. If it dispatches work, it is a SECOND dispatch path (#1890); if it does not, "
        "add it to _NON_DISPATCH_STEPS with the reason."
        % ", ".join(sorted(undeclared)))
    assert _DISPATCH_STEP in launched


def test_the_lane_table_feeding_vocabulary_is_gone_from_the_beat():
    """No re-grown feed on the retired files. The queue's names must not reach the beat's code."""
    lines = _executable_lines(_BEAT)
    for token in _QUEUE_TOKENS + ("refresh-queues",):
        assert not [l for l in lines if token in l], (
            "heartbeat-loop.sh still references the retired lane-table feed token %r — a feed "
            "that reads the old queue files directly is the same design under a new name" % token)


def test_no_live_code_reads_the_retired_queue_files_under_any_name():
    """The rename-proof half: a copy of the retired dispatcher under a NEW name still reads these.

    The name-based scan above cannot catch a renamed copy (measured: `cp queue-dispatch.py
    scripts/lane-feed.py` + a beat invocation of `lane-feed.py` passed the name-only assertions).
    This one pins the BEHAVIOUR instead: nothing live opens the lane-table's queue files.
    """
    scanned = _tracked_text_files()
    assert len(scanned) >= 100, (
        "the scan examined only %d files — an empty or broken scan must never read as clean, and "
        "this is the ONLY rename-proof assertion in the file: a scan regression here is the one "
        "that would let a copy of the retired dispatcher under a new name pass" % len(scanned))
    hits = _live_code_referencing(_QUEUE_TOKENS)
    assert hits == {}, (
        "live code still reads the retired lane-table queue files (a renamed dispatcher is still "
        "the retired design): %s" % "; ".join("%s in %s" % (t, ", ".join(p)) for t, p in hits.items()))


# ---------------------------------------------------------------------------
# Deployment: nothing delivers or schedules the retired script
# ---------------------------------------------------------------------------

def test_no_farm_array_delivers_the_retired_dispatcher():
    src = _SETUP.read_text()
    arrays = re.findall(r"^\w*srcs=\((.*)\)$", src, re.M)
    assert arrays, "pi-bootstrap/setup.sh has no farm array — this test is looking at the wrong file"
    for arr in arrays:
        assert "queue-dispatch.py" not in arr.split(), (
            "a farm array in pi-bootstrap/setup.sh still delivers the RETIRED queue-dispatch.py; "
            "a retired script that lands in $DEST/scripts is one `bash $DEST/scripts/...` away "
            "from re-inverting #1890")


def test_the_lane_table_source_is_gone_from_the_live_scripts_directory():
    assert not (_REPO / "scripts" / "queue-dispatch.py").exists(), (
        "scripts/queue-dispatch.py is back. The lane-table dispatcher was retired (#1874) — if it "
        "is genuinely needed again that is a design change against #1890, not a restore.")


# ---------------------------------------------------------------------------
# The record: retired, annotated, and findable from the note that retired it
# ---------------------------------------------------------------------------

def test_the_retired_copy_is_kept_and_annotated_in_place():
    assert _RETIRED.is_file(), "the retired source was deleted; the record is git history + this copy"
    head = "\n".join(_RETIRED.read_text().splitlines()[:40])
    assert "RETIRED" in head, "the retired copy must say so in its first 40 lines — it is executable"
    assert "#1874" in head and "#1890" in head, "the banner must name the issue that retired it"


def test_the_note_that_retired_it_names_the_record():
    """A retirement that does not say where the code went is indistinguishable from a deletion."""
    text = _BEAT.read_text()
    assert "orchestrator-harness/retired/queue-dispatch.py" in text, (
        "heartbeat-loop.sh's retirement note must point at the kept copy")
    assert "#1874" in text and "#1890" in text, (
        "the retirement note must name both issues: #1874 (this issue) and #1890 (the inversion "
        "it finishes undoing)")


# ---------------------------------------------------------------------------
# The defeat matrix: every shape a review cycle MEASURED walking past the gate
# ---------------------------------------------------------------------------
# ⛔ A DEFEAT THAT IS NOT RE-TESTED IS A DEFEAT WAITING TO RETURN. Six review cycles each lost a
# new spelling of the same silent green — a literal `if false`, a quoted literal, a one-liner, an
# uncalled `function name {`, an env feature flag around the block, and finally a `--dry-run` on a
# continuation line. Each was closed by widening a matcher, and a wider matcher is exactly the kind
# of fix that a later edit quietly narrows again, because the ONLY thing standing between the two
# is a comment. So every shape that has been measured is re-measured here against a MUTATED COPY of
# the real beat: the assertion is not "the code looks right", it is "this mutation is REFUSED".
#
# The cases below were added by the 2026-10-19 adversarial review, which reproduced all four
# against the shipped suite (13/13 green on a beat that dispatches nothing on every pass).

def _beat_mutated(tmp_path, mutate):
    """A copy of the REAL beat with `mutate(text)` applied, or None if the anchor is not found.

    Copies, never edits: the gate is graded on the artifact that ships, and a fixture that pinned
    a hand-written snippet would pass while `heartbeat-loop.sh` drifted away from it.
    """
    text = _BEAT.read_text()
    mutated = mutate(text)
    if mutated is None or mutated == text:
        return None
    dst = tmp_path / "heartbeat-loop.sh"
    dst.write_text(mutated)
    return dst


# The only line the mutants are inserted before: the arm guard that makes the launch reachable.
_GUARD = 'if [ ! -f "$STATE/PR-DOCTOR-OFF" ]; then'


# ⛔ THE CONTINUATION-LINE ARGUMENT. `--dry-run` is a real flag (`pr-doctor.py` accepts it and then
# dispatches nothing), and bash joins the continuation into the SAME command. A pin on the first
# physical line matches anyway — so the gate reported "the pinned launch is present and reachable"
# on a beat whose single dispatch entry point was a no-op.
def _add_dry_run_on_continuation(text):
    # Insert an argument on the line AFTER the launch's backslash continuation.
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "/usr/bin/python3" in line and "pr-doctor.py" in line and line.rstrip().endswith("\\"):
            lines.insert(i + 1, "            --dry-run \\")
            return "\n".join(lines) + "\n"
    return None


def test_a_defeated_gate_the_continuation_line_argument_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _add_dry_run_on_continuation)
    assert mutated is not None, "anchor missing: the launch no longer backslash-continues"
    launches = [l for l in _logical_lines(mutated) if _DISPATCH_STEP in l]
    assert launches, "the mutation removed the launch; the fixture is wrong, not the gate"
    assert not any(_DISPATCH_LAUNCH.match(l) for l in launches), (
        "an argument on the launch's CONTINUATION line was graded as the pinned launch. bash joins "
        "the continuation, so that argument is the command's argument — `--dry-run` there is the "
        "beat's only dispatch entry point deciding nothing, on every pass, while this gate says "
        "the launch is exactly right. Got: %r" % launches)


# ⛔ THE ONE-LINE TRANSFER. `if …; then continue; fi` starts with `if` (so a line-leading transfer
# matcher is blind) and closes on its own line (so `_enclosing_constructs` never sees it, and the
# enclosing-construct assertion stays byte-identical). It makes the launch unreachable from the
# second pass on while every pinned string survives.
_ONE_LINE_TRANSFERS = [
    ('if [ -n "$PR_DOCTOR_DISABLE" ]; then continue; fi', "a one-line if"),
    ('[ -n "$PR_DOCTOR_DISABLE" ] && continue', "a && guard"),
    ('[ -f "$STATE/PR-DOCTOR-BLOCK" ] && exit 0', "a && exit"),
    ('{ [ -n "$PR_DOCTOR_DISABLE" ] && continue; }', "a brace group"),
    ('while :; do break; done', "a one-line while"),
    ('if true; then continue; fi', "a dead-branch one-line"),
]


def _insert_before_guard(stmt):
    def _mutate(text):
        if _GUARD not in text:
            return None
        return text.replace(_GUARD, "  " + stmt + "\n  " + _GUARD, 1)
    return _mutate


def test_a_defeated_gate_every_one_line_early_transfer_is_refused(tmp_path):
    """A transfer in COMMAND POSITION anywhere on the line, not only at its start."""
    survivors = []
    for stmt, label in _ONE_LINE_TRANSFERS:
        mutated = _beat_mutated(tmp_path, _insert_before_guard(stmt))
        assert mutated is not None, "anchor missing: the arm guard line moved"
        transfers = _early_transfers(mutated, _DISPATCH_STEP)
        assert transfers is not None, "the launch vanished under mutation %r" % label
        if transfers == _ALLOWED_EARLY_TRANSFERS:
            survivors.append((label, stmt))
    assert not survivors, (
        "these shapes END the pass before the dispatch and left the pinned transfer list "
        "BYTE-IDENTICAL, so this gate reported green on a beat that never dispatches: %r. "
        "A transfer counts in command position, not only at the start of a line." % survivors)


# ⛔ THE HEREDOC-DISABLED BLOCK. `: <<'WORD' … WORD` keeps every byte of the launch and runs none
# of it. No construct list can see this, so the body must be removed before scanning — otherwise
# the code view and the text view disagree and only the text view contains the launch.
def _heredoc_wrap_the_launch(text):
    # `<<'WORD'` (no `-`) requires the terminator at COLUMN 0 — an indented one is not a terminator
    # to bash, and a fixture bash would reject proves nothing about a shape bash would run.
    start = '    ( nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" \\'
    end = '          rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &'
    if start not in text or end not in text:
        return None
    return text.replace(start, "    : <<'UNUSED_PROSE'\n" + start, 1).replace(
        end, end + "\nUNUSED_PROSE", 1)


def test_a_defeated_gate_a_heredoc_disabled_block_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _heredoc_wrap_the_launch)
    assert mutated is not None, "anchor missing: the launch's first or last line moved"
    # The fixture must be a beat BASH WOULD ACCEPT — a mutant bash rejects proves nothing.
    assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
        "the heredoc fixture is not valid bash, so it is not the shape it claims to test")
    assert not [l for l in _executable_lines(mutated) if _DISPATCH_STEP in l], (
        "the launch still counts as live CODE inside a `: <<'WORD' … WORD` block. bash runs none "
        "of it, so the beat dispatches nothing while this file reports the launch present.")
    # And the positive control must not survive on the RAW view either — one definition of "code".
    assert not [l for l in _executable_raw(mutated) if _DISPATCH_STEP in l], (
        "the indented view still sees the launch inside a heredoc; the two views must agree")


# ⛔ THE CONTROL: the fixtures must not be vacuous. An unmutated copy must PASS every assertion the
# mutated copies fail, or the matrix above proves only that the helpers dislike every input.
def test_the_defeat_matrix_does_not_red_the_real_beat(tmp_path):
    # Copy, not mutate: the control must be the beat EXACTLY as it ships.
    baseline = tmp_path / "heartbeat-loop.sh"
    baseline.write_text(_BEAT.read_text())
    launches = [l for l in _logical_lines(baseline) if _DISPATCH_STEP in l]
    assert any(_DISPATCH_LAUNCH.match(l) for l in launches), (
        "the pinned launch does not match the UNMUTATED beat — the pin is wrong, not the mutants")
    assert _early_transfers(baseline, _DISPATCH_STEP) == _ALLOWED_EARLY_TRANSFERS, (
        "the unmutated beat does not produce the pinned transfer list")
    assert [l for l in _executable_lines(baseline) if _DISPATCH_STEP in l], (
        "the unmutated beat's launch is not seen as executable code")
