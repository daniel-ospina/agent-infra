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
                        per item through `nonblocking-dispatch.sh` — LANDED in #1894 (#1890):
                        `pr-doctor.py` points `NONBLOCKING_DISPATCH` at that helper, starts a
                        fresh worker in the PR's own worktree, and no longer has an
                        `idle_lanes()` function at all. (This header said the spawn half was NOT
                        WIRED and that `pr-doctor` still gated on its idle roster, from the day
                        the retirement was written until #1894 merged. #1894 is merged; a live
                        claim that contradicts the tree is the defect this file's own
                        `test_no_live_claim_surface_states_the_retired_dispatcher_as_live`
                        pins for the retired name, so it is corrected here too.)
                        This file does NOT assert the spawn path itself — #1890's own suites do
                        — only that the beat has ONE dispatch entry point and this is it.

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

THREAT SURFACE — what `_launch_subshell_span` claims, and what it does not (adversarial bound).
  IN SCOPE, each covered by a fixture in `test_the_detached_shape_is_pinned_not_inferred`:
    1. the launch left in the pass's OWN shell (no pinned pair at all — the opener removed and the
       closer's `&` stripped — or the launch moved below its closer) — a pass that returns before
       pr-doctor has even started;
    2. the pair turned SYNCHRONOUS (its `&` dropped, or the pair closed before the pinned closer)
       — a pass that blocks ~280-390s on a full dispatch cycle;
    3. a STRAY PAIR re-binding the pinned closer (`( : ) &`, `true; ( : …`,
       `[ -d … ] && ( : …`, a quoted `#` hiding the close, a compound `( : ) ; … )`);
    4. a correct beat false-REDded by a spelling (`)&`, `2>/dev/null)`, `2> /dev/null`, a trailing
       comment after the closer, a bare `(`, an opener on the launch line, `&&` above the launch,
       a `&` inside the block, a finished `( : )` above AND below the launch, `$(…)`, `<(…)`).
  OUT OF SCOPE — no test here claims these, and a text scan cannot settle them. Each was BUILT and
  MEASURED (cycle-7 review), so none is hypothetical:
    * a `set -m`/`coproc`/`exec` carrier that backgrounds or detaches the pair from OUTSIDE the
      block, or moving the launch into a sourced lib the reachability checks are not told about.
      (The comment-supplied-depth hole that USED to be listed here was CLOSED by the scanner's
      quote-aware `#` skip — measured: `( : ) # ( ) )` scans as `(0, 1, False)`, so a trailing
      comment can neither supply nor delete a paren.)
    * a QUOTED-STRING carrier (`X='start` … `end'` around the launch) disables the block while every
      pin and every reachability pin still matches. The heredoc analogue has a whole test and a
      scanner view (`_heredoc_free_lines`); the string analogue has neither.
    * a one-line function definition in the block (`f() { …; }`) or a `case … in x)` arm REDs a
      correct beat: both put a `)` where the scanner counts a closer (fail-closed — the cost is a
      RED, never a green block).
  Residuals are recorded, not chased: coverage of the classes above is the acceptance criterion —
  nine review cycles each bought exactly one more spelling, which is what a spelling test buys —
  and the fail-open shapes that remain all need a DELIBERATE rewrite of the block, not the ordinary
  edit this gate exists to catch.

Run:  python3 -m pytest scripts/test_dispatch_wiring.py -q
"""
from __future__ import annotations

import ast
import pathlib
import re
import subprocess


# ⛔ A GATE THAT CAN BE SILENCED IS NOT A GATE (review of the head, MEASURED). pytest exits 0 when
# every test in a file is skipped, and CI runs this file with `-x --timeout=60 -q` — so TWO lines at
# the top of this file turn "the beat has exactly one detached dispatch entry point" into
# "32 skipped" and a green check. Nothing in the repo reads skip counts, so the silencing has to be
# refused HERE, at import time: a collection error is a non-zero exit, which is the only signal CI
# carries.
#
# ⛔ DETECTED ON THE PARSE TREE, NOT ON THE TEXT. A text scan fires on the docstring that documents
# this very rule (measured: the first version of this check refused its own file), and stripping
# strings/comments by hand is the same spelling race as everything else in this file. A marker is an
# EXPRESSION here — a `pytestmark` assignment, or a `pytest.mark.skip`/`xfail`/`skipif` decorator or
# `pytest.skip(...)` call — so the AST is the right surface, and prose cannot match it.
_SILENCING_CALLS = frozenset({
    "pytest.mark.skip", "pytest.mark.skipif", "pytest.mark.xfail",
    "pytest.skip", "pytest.importorskip",
})


def _dotted(node: ast.AST) -> str:
    """`pytest.mark.skip` from the Attribute/Name chain, or "" when the chain is not plain names."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return ""
    parts.append(node.id)
    return ".".join(reversed(parts))


def _silencing_markers(tree: ast.AST) -> list[str]:
    """Names of the skip/xfail constructs in a parsed module — empty for a module that runs."""
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name) and target.id == "pytestmark":
                    found.add("pytestmark")
        elif isinstance(node, ast.Attribute):
            # An ATTRIBUTE, not a Call: `@pytest.mark.skip` as a decorator is never called, and
            # `pytest.mark.xfail` is routinely used bare — both silence the test all the same
            # (measured: a Call-only detector missed the bare form).
            name = _dotted(node)
            if name in _SILENCING_CALLS:
                found.add(name)
    return sorted(found)


_SELF_TEXT = pathlib.Path(__file__).read_text()
_SILENCED = _silencing_markers(ast.parse(_SELF_TEXT))
if _SILENCED:
    raise RuntimeError(
        "this gate refuses to be silenced: %s in %s. A skipped gate exits 0 and reads as a pass "
        "(pytest reports 'N skipped' and CI is green), so the skip IS the defect. Delete the "
        "construct — if a test is genuinely obsolete, delete the test and say why in the commit."
        % (", ".join(_SILENCED), __file__))

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
# ⛔ STRUCTURAL, NOT A REDIRECT REGEX (cycle-2 review, P2). A pattern like `\S+` for the redirect
# target absorbs a GLUED argument: `2>&1--dry-run` matched as `2>&1` + target, and bash rejects
# that line at runtime (`ambiguous redirect`), so pr-doctor never starts while the pass prints
# "launched detached" and this gate says the invocation is exactly right. So the remainder is
# consumed token by token with a small validator instead of one permissive regex.
_LAUNCH_PREFIX = re.compile(
    r'^(?:\(\s*)?nohup\s+/usr/bin/python3\s+"\$SCRIPTS/pr-doctor\.py"(?=\s|$)')
# ⛔ THE LEADING `(` IS OPTIONAL HERE AND DETACHMENT IS ASSERTED STRUCTURALLY INSTEAD (#1954). The
# beat used to open the subshell ON the launch line — `( nohup /usr/bin/python3 "$SCRIPTS/
# pr-doctor.py" \` (measured: `git show c30117d0^:scripts/heartbeat-loop.sh`, lines 496-498, which
# close on the `rmdir … ) &` line) — so a leading `(` in this prefix was the only thing saying
# "subshell". It now OPENS the subshell on its own line — `( # <why this is
# a subshell> …  nohup …  ) &`, from #1954's rc-carrier work — so the launch's own line starts at
# `nohup` and requiring a paren here would red a correct beat. Dropping it would let a mutant run
# the launch in the pass's FOREGROUND (a pass that blocks on a full dispatch cycle — the exact
# thing detaching exists to prevent), so the paren moved to `_launch_is_in_backgrounded_subshell`
# below rather than being deleted.
_LAUNCH_SUBSHELL_HINT = 'nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py"'
# `[n]>&m` (fd duplication) must be its own token; `[n]>`/`[n]>>`/`&>`/`&>>` take a TARGET that
# must not begin with `&` — `>&word` is an ambiguous redirect to bash, not a redirection.
_FD_DUP = re.compile(r"^([12]?>&[0-9]+)(?=\s|$)")
_FILE_REDIRECT = re.compile(r"^(?:[12]?>>?|&>>?)\s*(\S+)")


# ⛔ THE TWO BRACKETS THAT MAKE THE LAUNCH **DETACHED**, PINNED — NOT INFERRED (#1940 rebase,
# THREE review cycles, EACH defeat MEASURED). The launch must sit inside a subshell that is
# BACKGROUNDED (`( … ) &`); a launch in the pass's own shell blocks the pass on a full dispatch
# cycle (~280-390s), which is the property detaching exists to give. `nohup` alone does not
# background a command.
#
# Every attempt to DERIVE the bracket pair from the text was defeated, because deriving it is a
# bash parser, and this repo has already paid for text-scans that model the language:
#   * "nearest `(` above / next `) &` below" borrowed an unrelated `( sleep …` from a helper 500
#     lines up;
#   * bounding that walk by indentation still let the launch be moved BELOW its own closer and take
#     a later `( : ) &` as its end — a foreground launch, green;
#   * a same-indent opener spelling (`(` alone, launch on the next line) was invisible;
#   * and requiring `endswith(") &")` RED on two correct spellings (`)&`, `) &  # backgrounded`).
# So the brackets are PINNED, exactly like the launch line itself: an opener line that is NOTHING
# BUT `(` (a trailing comment allowed), and the block's own closer, recognised by the command it
# runs. Moving or re-spelling either is a deliberate edit to this pin, which is the file's contract
# for the launch line too.
_SUBSHELL_OPEN = re.compile(r"^\(\s*(?:#.*)?$")
# ⛔ THE REDIRECT'S SPELLING IS NOT THE PROPERTY (cycle-4 review, measured): `rmdir … 2>/dev/null) &`
# and `rmdir … 2> /dev/null ) &` are both valid bash and both backgrounded, and refusing them reddened
# a correct beat. What this pins is WHICH command closes the subshell, so the spacing is free.
_SUBSHELL_CLOSE = re.compile(
    r'^rmdir\s+"\$STATE/pr-doctor\.lock"\s+2>\s*/dev/null\s*\)\s*&\s*(?:#.*)?$')


def _code_of(line: str) -> str:
    """The line, or "" when it is a comment — prose is not a subshell boundary.

    ⛔ MEASURED (cycle-6 review): the beat's own comments carry `(` and `)` in prose — `# DISARM:
    touch $STATE/PR-DOCTOR-OFF  (the loop's HEARTBEAT-OFF still stops everything).` and `# sibling
    started by the stale-lock takeover) is moved to …` — and reading those as parens made the walk
    refuse the SHIPPED beat (four fixtures reported "anchor missing").

    ⛔ AND NOTHING MORE THAN THAT (cycle-6 review, P1, measured): an earlier version also TRUNCATED
    at a trailing `  # `, "quote-balanced" — which DELETED a real `)` from
    `printf '%s\n' "probe  # x" ; rmdir … )` and turned a blocking launch green. A truncation can
    only ever remove evidence, so it is gone: whole-line comments are skipped and every other byte
    is read as code.
    """
    s = line.strip()
    return "" if s.startswith("#") else s


def _scan_subshell_depth(s: str) -> tuple[int, int, bool]:
    r"""`(final_depth, zero_crossings, went_negative)` for a region of shell code.

    ⛔ THE DEPTH IS COUNTED PER CHARACTER, NOT PER LINE (cycle-8 review, MEASURED P1). A per-line
    per-line depth that is only checked at line ends cannot see a line with NET ZERO change that
    closes the launch's pair and re-opens another one: `_rc=$? ) ; ( : > "$STATE/probe.tmp"` is
    valid bash (rc=0), keeps the line's delta at +0, and the pinned closer then matches the STRAY
    pair. Measured with a runtime oracle (the launch replaced by `sleep 3`): the block returns in
    3008 ms instead of 5 ms — the pass blocks on a full dispatch cycle, which is exactly class 2 —
    while the predicate said DETACHED. A depth is a property of the whole region, so it is read as
    one region.

    `final_depth` must be 0 (the pinned closer closes the pair) and `zero_crossings` must be
    exactly 1 (nothing else ever closed it), which is what rejects the close-and-reopen spellings.

    ⛔ AND THE DISTINCTION IS SYNTAX, NOT SPELLING. Two earlier revisions graded boundaries by
    spelling — first "the line starts with `(`", then "a paren in command position" — and each lost
    the next spelling (`true; ( : …`, `[ -d … ] && ( : …`). Both also LIED in the other direction:
    `)` in closing position matched the `)` of `_now=$(date)`, and a finished `( : ) &` above the
    launch counted while the identical line below it was "neutral" — false REDs on a correct beat.
    So the scanner skips what bash does not count as a subshell:
      * `$(…)`, `${…}`, `$((…))`, `<(…)`, `>(…)` — EXPANSIONS (the opener is skipped with its
        matching close, tracked by `skip`);
      * quoted text (`'…'`, `"…"`, `\x`) moves nothing;
      * a `(` in COMMAND position (start of a line or after whitespace/`;`/`&`/`|`/`(`/`{`/`!`)
        opens a subshell; every other `)` closes one.
    A `case … in a)` pattern reads as a closer here, and so does a one-line `f() { …; }` definition;
    this block has neither, and both failure modes produce a FALSE None (a RED), never a false True.
    A paren in PROSE is no longer one of them — the quote-aware `#` skip above covers an inline
    comment as well as a whole-line one (measured: `nohup x  # done )` scans as `(0, 0, False)`),
    which is the same fix that closed the out-of-scope comment-supplied-depth bullet.
    """
    depth = 0
    zeros = 0
    negative = False
    i, n = 0, len(s)
    sq = dq = False
    skip = 0  # depth INSIDE a `$( … )` / `${ … }` / `<( … )` expansion
    while i < n:
        c = s[i]
        if skip:
            if c in "({":
                skip += 1
            elif c in ")}":
                skip -= 1
            elif c == "'" and not dq:
                sq = not sq
            elif c == '"' and not sq:
                dq = not dq
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if sq:
            if c == "'":
                sq = False
            i += 1
            continue
        if dq:
            if c == '"':
                dq = False
            elif c == "$" and i + 1 < n and s[i + 1] in "({":
                skip = 1
                i += 2
                continue
            i += 1
            continue
        # A `#` that STARTS a comment (first char, or after whitespace/`;`/`&`/`|`/`(`) ends the
        # line's code — `( # only when no carrier is waiting` would otherwise leave its prose `"`
        # open and swallow the rest of the region (measured on the SHIPPED beat). A `#` INSIDE
        # quotes is not a comment, which is exactly the case a naive `  # ` truncation got wrong.
        if c == "#" and (i == 0 or s[i - 1] in " \t\n;&|("):
            j = s.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        if c == "'":
            sq = True
        elif c == '"':
            dq = True
        elif c in "$<>" and i + 1 < n and s[i + 1] in "({":
            if c == "$" or s[i + 1] == "(":
                skip = 1
                i += 2
                continue
            i += 1
            continue
        elif c == "(":
            if i == 0 or s[i - 1] in " \t\n;&|({!":
                depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                zeros += 1
            elif depth < 0:
                negative = True
        i += 1
    return depth, zeros, negative


def _launch_subshell_span(lines: list[str]) -> tuple[int, int] | None:
    """`(opener_idx, closer_idx)` of the launch's OWN subshell, or None.

    The bracket pair is PINNED — a line that is nothing but `(` (trailing comment allowed), or an
    opener on the launch line, and the block's own `rmdir … ) &` closer — because deriving it from
    text is a bash parser and three derived revisions were each defeated. What IS derived,
    between those two pinned ends, is the DEPTH of the whole region, read CHARACTER BY CHARACTER:
    it must close exactly once — at the pinned closer — and never go negative. That is what refuses
    a pair that closed early (synchronous: a pass that blocks ~280-390s on a full dispatch cycle),
    a stray pair that re-bound the closer, and a close-and-reopen inside a single line, whose
    net-zero line delta is invisible to any per-line check.
    """
    hints = [i for i, l in enumerate(lines) if _LAUNCH_SUBSHELL_HINT in l]
    if len(hints) != 1:
        # ZERO launches is not a span; MORE THAN ONE means the "span" would describe the first and
        # say nothing about the rest (review of the head: a second launch was green). Ambiguous.
        return None
    launch = hints[0]
    # The opener may sit ON the launch line. That is not a hypothetical spelling: it is exactly the
    # PRE-#1954 shape — `git show c30117d0^:scripts/heartbeat-loop.sh` lines 496-498 open with
    # `( nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" \` and close on the `rmdir … ) &` line —
    # and `_LAUNCH_PREFIX` accepts it, so this check must find the span for it or a correct beat
    # REDs.
    opener = launch if _code_of(lines[launch]).startswith("(") else None
    if opener is None:
        for j in range(launch - 1, -1, -1):
            s = _code_of(lines[j])
            if not s:
                continue
            if _SUBSHELL_OPEN.match(s):
                opener = j
                break
    if opener is None:
        return None
    closer = None
    for k in range(launch + 1, len(lines)):
        s = _code_of(lines[k])
        if not s:
            continue
        if _SUBSHELL_CLOSE.match(s):
            closer = k
            break
    if closer is None:
        return None
    region = "\n".join(_code_of(l) for l in lines[opener:closer + 1])
    final, zeros, negative = _scan_subshell_depth(region)
    if final != 0 or zeros != 1 or negative:
        # Either the pair closed before the pinned closer (a synchronous subshell, or a stray pair
        # that re-bound the closer — including the close-and-reopen spelling inside ONE line), or
        # something opened inside it that the pinned closer does not close. Either way the launch is
        # not inside a backgrounded pair.
        return None
    return opener, closer


def _launch_is_in_backgrounded_subshell(path: pathlib.Path) -> bool:
    """True when the launch sits inside a `( … ) &` subshell — the DETACHED shape.

    This is the half of the old `^\\(`-prefixed launch pin that the optional paren gave up: the pin
    now accepts a launch line whose `(` sits on the line above (as #1954 spelled it), so the
    detachment has to be asserted separately. Graded on `_executable_raw` so comments are excluded
    and nesting is intact.
    """
    return _launch_subshell_span(_executable_raw(path)) is not None


def _is_pinned_launch(logical_line: str) -> bool:
    """True when the LOGICAL line is exactly the pinned launch and nothing else.

    Everything after the script path must be a well-formed redirection; any argument, env
    assignment or glued token refuses. See `_LAUNCH_PREFIX` for why this is a validator rather
    than a regex.
    """
    m = _LAUNCH_PREFIX.match(logical_line)
    if not m:
        return False
    rest = logical_line[m.end():].strip()
    while rest:
        dup = _FD_DUP.match(rest)
        if dup:
            rest = rest[dup.end():].strip()
            continue
        redir = _FILE_REDIRECT.match(rest)
        if not redir:
            return False
        if redir.group(1).startswith("&"):
            return False
        rest = rest[redir.end():].strip()
    return True
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
    # ⛔ THE ARM IS PART OF THE PIN (agent-infra#1940 rebase). The launch sits in the `else` arm of
    # the lock-held check — the arm that TAKES the lock — not in the arm that skips the pass. The
    # frames are arm-aware because an arm is closed by its `if`'s own `fi` (see `_switch_arm`), and
    # the arm is what makes "the launch in the guard's `then` arm" distinguishable from "the launch
    # in a flag-gated `elif` arm", which is cycle-3 T3's defeat.
    ("else", '[ -d "$STATE/pr-doctor.lock" ] && \\'),
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
    # ⛔ BUT THE PREFIX IS PINNED TO WHERE A SUITE LIVES, not to any basename starting with `test_`
    # (adversarial review, cycle 6): the loose rule exempted a LIVE file named e.g.
    # `tools/test_dispatch_feed.py` from BOTH scanners — including `_live_code_referencing`, the
    # rename-proof half — so a renamed re-arm placed there read as a record. A suite is
    # `scripts/test_*.py` or `tests/**/test_*.py`; everything else is graded as code.
    # RESIDUAL, stated: a live copy placed at `scripts/test_*dispatch*.py` is still text-exempt; a
    # BEAT launch of it is still caught by the launch enumeration, so the gap is a non-beat
    # (launchd/cron) launch from a file named like a test, which no test file does.
    is_suite = name.startswith("scripts/test_") or (
        name.startswith("tests/") and base.startswith("test_"))
    if is_suite and base.endswith(".py") and "dispatch" in base:
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


# A here-doc DELIMITER is any shell word, not an identifier: bash accepts `<<'1'`, `<<\W`, `<<$X`
# and `<<-END` alike. Matching only `[A-Za-z_][\w-]*` (an earlier revision) left `: <<'1'` and
# `: <<\W` UNRECOGNISED — both are real heredocs, both swallow the launch, and both stayed green
# (cycle-3 review, T4). The delimiter is therefore PARSED, not regexed.
_DELIM_BARE_END = set(" \t;&|()<>")


def _parse_heredoc_delimiter(line: str, i: int):
    """Parse the delimiter starting at `i` (just past `<<[-]`). Returns `(word, next_index)`.

    Handles `'…'`, `"…"`, `\\X`, and a bare word. Returns None when it is not a usable delimiter.
    """
    n = len(line)
    while i < n and line[i] in " \t":
        i += 1
    if i >= n:
        return None
    if line[i] in "'\"":
        q = line[i]
        end = line.find(q, i + 1)
        if end < 0:
            return None
        return line[i + 1:end], end + 1
    if line[i] == "\\":
        i += 1
        if i >= n:
            return None
    j = i
    while j < n and line[j] not in _DELIM_BARE_END:
        j += 1
    if j == i:
        return None
    return line[i:j], j


def _heredoc_opener(line: str):
    """`(strip_tabs, word)` when `line` opens a here-doc, else None.

    ⛔ THE `<<` MUST BE AN UNQUOTED SHELL OPERATOR (measured 2026-10-19, cycle-2 adversarial
    review — a P0 this file introduced). A naive text search for `<<WORD` treats
    `printf '%s\n' "<<PROSE"` and `echo hi  # cat <<EOF` as openers, sets a terminator that never
    arrives, and DELETES EVERY FOLLOWING LINE from both views. One plausible `printf` then hides
    the whole file from every scan it feeds — the retired-name check, the second-dispatch-step
    enumeration and the capacity check all read `_executable_lines` — so a single line re-arms
    the retired dispatcher and every test passes (measured: 180 -> 110 executable lines, 16/16
    green). So the operator is found by walking quotes and comments, never by regex alone.

    ⛔ AND THE DELIMITER IS PARSED, NOT PATTERN-MATCHED (cycle-3 review, T4): `<<'1'` and `<<\\W`
    are real heredocs that an identifier-shaped regex does not see, so their bodies stayed
    scannable and the disabled launch read as live code.
    """
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#":
            # An unquoted `#` starts a comment: nothing after it is an operator.
            return None
        elif line.startswith("<<<", i):
            i += 3          # a here-STRING carries no body
            continue
        elif line.startswith("<<", i):
            j = i + 2
            strip_tabs = False
            if j < len(line) and line[j] == "-":
                strip_tabs = True
                j += 1
            parsed = _parse_heredoc_delimiter(line, j)
            if parsed is None:
                return None
            return strip_tabs, parsed[0]
        i += 1
    return None


def _heredoc_free_lines(path: pathlib.Path) -> list[str]:
    """Every physical line, with HEREDOC BODIES REMOVED — one implementation, both views.

    ⛔ A HEREDOC BODY IS NOT CODE (measured 2026-10-19, adversarial review). Wrapping the dispatch
    in `: <<'UNUSED_PROSE' … UNUSED_PROSE` leaves every byte of the launch in place while bash
    executes none of it, and no construct list can see it — "comment out the step with a heredoc"
    is a normal way to disable a shell block. Stripping it HERE means both views agree: the
    launch is absent from the code view (so its ABSENCE reds) instead of being present in one
    view and absent from the other.

    ⛔ THE TERMINATOR RULE IS BASH'S, NOT `strip()`'s (cycle-2 review, P1). A plain `<<'WORD'`
    terminates only on a line that IS the word at COLUMN 0; `<<-WORD` strips leading TABS only.
    Matching with `strip()` ends the body EARLY on an indented copy of the word, so bash keeps
    treating the following lines as body while this scanner treats them as code — a disabled
    launch that the gate reads as live (measured: `: <<'PROSE'` / `  PROSE` / *launch* / `PROSE`
    is valid bash, never dispatches, and the suite stayed green).
    """
    out: list[str] = []
    opener = None
    for line in path.read_text().splitlines():
        if opener is not None:
            strip_tabs, word = opener
            if (line.lstrip("\t") if strip_tabs else line) == word:
                opener = None
            continue
        out.append(line)
        # A COMMENT is never a here-doc opener, however it is spelled
        # (`_heredoc_opener` enforces it; this cheap check keeps the common case fast).
        if line.strip().startswith("#"):
            continue
        opener = _heredoc_opener(line)
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
# ⛔ `elif` IS AN ARM, NOT A FRAME (agent-infra#1940 rebase, MEASURED) — see `_switch_arm` below,
# which is the ONE place an arm is consumed. An earlier revision pushed the arm as its own
# `("elif", condition)` frame, to catch `elif [ -n "$FLAG" ]; then <the whole launch block> fi`
# (cycle-3 review). The catch was right; the model was not: **one `fi` closes the `if` AND every
# `elif` arm**, so pushing an `elif` frame leaves its `if` frame on the stack forever and every
# later closer pops the wrong entry. Measured on the beat main landed in #1954:
# `report_detached_rc()` contains one `elif`, the phantom `if` frame made the FUNCTION read as
# still-open, and the dispatch launch came back enclosed by `('func', 'report_detached_rc')` — a
# false RED on a correct beat (and, one matching closer later, the same drift hides a real
# enclosing construct: a false GREEN). The launch inside an `elif` arm is still caught, by the
# ARM frame `_switch_arm` writes — pinned by
# `test_a_defeated_gate_an_elif_branch_around_the_block_is_refused`.
_OPEN_LOOP = re.compile(r"^(while|until)\s+(.+?)(?:\s*;\s*do)?$")
_OPEN_FOR = re.compile(r"^for\s+(.+?)(?:\s*;\s*do)?$")
# `select` is a `done`-terminated loop like `for`; without this it opened nothing (cycle-3 review).
_OPEN_SELECT = re.compile(r"^select\s+(.+?)(?:\s*;\s*do)?$")
_OPEN_CASE = re.compile(r"^case\s+(.+?)\s+in\b")
_OPEN_FUNC = re.compile(r"^(?:function\s+)?([A-Za-z_][\w-]*)\s*(?:\(\s*\))?\s*\{")
_CLOSER = re.compile(r"^(?:fi|done|esac)\b|^\}")


def _opened_construct(s: str):
    """The construct `s` opens, as `(kind, subject)`, or None.

    ⛔ ONE IMPLEMENTATION FOR BOTH REACHABILITY READERS. The chain used to be copied into
    `_enclosing_constructs` and `_early_transfers`, which is precisely how two scanners drift:
    a construct one of them sees is a construct the other reports as pinned, so the launch can sit
    inside it and still read as reachable. Both now call this.

    A construct we did not enumerate is never silently ignored: an unrecognised line ending in `{`
    opens an anonymous group, so it changes the list and reads RED (cycle-2 review, P0).
    """
    m = _OPEN_CASE.match(s)
    if m:
        return ("case", m.group(1))
    m = _OPEN_FUNC.match(s)
    if m and "}" not in s[m.end():]:
        return ("func", m.group(1))
    m = _OPEN_LOOP.match(s)
    if m:
        return ("loop", "%s %s" % (m.group(1), m.group(2)))
    m = _OPEN_FOR.match(s)
    if m:
        return ("for", m.group(1))
    m = _OPEN_SELECT.match(s)
    if m:
        return ("select", m.group(1))
    m = _OPEN_IF.match(s)
    if m:
        # A ONE-LINER (`if …; then …; fi`) opens and closes on its own line.
        return None if re.search(r";\s*fi$", s) else ("if", m.group(1))
    # ⛔ AN `elif`/`else` ARM IS DELIBERATELY ABSENT FROM THIS TABLE, and it is not an oversight:
    # an arm is closed by its `if`'s OWN `fi`, so it is consumed by `_switch_arm` (which REPLACES
    # the top frame's subject rather than pushing) and never by this opener table. Grading the
    # arm's CONDITION is `_IF_CONDITION`'s job in `test_the_beat_has_no_dead_branch_around_the_dispatch`
    # (it accepts `elif`), which is where `if [ 1 -eq 0 ]`-shaped arms die.
    if s.endswith("{"):
        return ("group", s)
    return None


_ARM_ELIF = re.compile(r"^elif\s+(.+?)(?:\s*;\s*then)?$")
# An arm may carry a trailing comment (`else  # take the lock`); losing it moved the pin's arm
# frame back to `("if", …)` and reddened a correct beat (cycle-3 review, measured).
_ARM_ELSE = re.compile(r"^else\s*(?:#.*)?$")


def _switch_arm(stack: list, s: str) -> bool:
    """Consume an `elif`/`else` line as an ARM of the enclosing `if` (True when it was one).

    ⛔ AN ARM IS NOT A FRAME — ONE IMPLEMENTATION FOR BOTH REACHABILITY READERS (measured on
    #1954's `report_detached_rc()`, whose body has one `elif`). `fi` closes the `if` AND every arm
    under it, so PUSHING an arm leaves its `if` frame on the stack forever and every later closer
    pops the wrong entry: the function read as still-open and the launch came back enclosed by
    `('func', 'report_detached_rc')`, a false RED — and the same drift in the other direction hides
    a real enclosing construct, a false GREEN.

    ⛔ AND IT MUST NOT BE A NO-OP EITHER. Ignoring arms made the launch in
    `if <guard>; then :; elif [ -n "$PR_DOCTOR_ENABLE" ]; then <whole block> fi` byte-identical to
    the launch in the guard's own `then` arm — the pinned list came out EXACTLY equal while the
    beat dispatched only when a flag was set (cycle-3 T3, re-measured here). REPLACING the top
    frame's subject keeps the stack balanced AND keeps the arm distinguishable.
    """
    if not stack:
        return False
    m = _ARM_ELIF.match(s)
    if m:
        kind, subj = "elif", m.group(1)
    elif _ARM_ELSE.match(s):
        kind, subj = "else", stack[-1][1]
    else:
        return False
    if stack[-1][0] in ("if", "elif", "else"):
        stack[-1] = (kind, subj)
    return True


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
        if _switch_arm(stack, s):
            if found:
                return list(stack)
            continue
        opened = _opened_construct(s)
        if found:
            return list(stack)
        if opened:
            stack.append(opened)
    return None


_TRANSFER_WORD = re.compile(r"(?:exit|continue|break|return)\b")
# A statement separator, split on OUTSIDE quotes: `;`, `&&`, `||`, `|`, `&`, brace/paren, and the
# shell keywords that put a command in command position (`then`, `do`, `else`, `elif`).
# ⛔ SPLIT INTO STATEMENTS, THEN TEST EACH ONE'S PREFIX. The previous revision instead scanned for
# the word ANYWHERE and tried to decide "is this really command position?" from the preceding
# characters — and its separator test was `stripped[-1] not in ";&|(){}then do else"`, a CHARACTER
# test against a concatenated CHARSET, so any preceding word ending in t/h/e/n/d/o/l/s counted as a
# separator (cycle-2 review, measured): `not continue` read as a transfer, and a log line reading
# `… did not return` reded the gate on a correct beat. It also carried
# `_STMT_BOUNDARY.search(head)`, whose `^` alternative is truthy at position 0, making half the
# condition dead. Splitting first has neither failure mode: a statement's PREFIX is the command.
_STMT_SPLIT = re.compile(r";|&&|\|\||\||&|\{|\}|\(|\)|\bthen\b|\bdo\b|\belse\b|\belif\b")


def _statements(s: str) -> list[str]:
    """`s` split at statement separators, with quotes and `$()` left intact."""
    parts: list[str] = []
    buf: list[str] = []
    quote = None
    depth = 0
    i = 0
    while i < len(s):
        ch = s[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "$" and i + 1 < len(s) and s[i + 1] == "(":
            # `$( … )` is one word, not a subshell statement list.
            depth += 1
            buf.append("$(")
            i += 2
            continue
        if ch == ")" and depth:
            depth -= 1
            buf.append(ch)
            i += 1
            continue
        m = None if depth else _STMT_SPLIT.match(s, i)
        if m:
            parts.append("".join(buf))
            buf = []
            i = m.end()
            continue
        buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


def _leading_statement(s: str) -> str | None:
    """The first statement on `s` whose COMMAND is a control transfer, if any.

    A transfer is a transfer only in command position. `echo "continue"`, a flag named
    `--continue`, and a message containing the word are not transfers, so matching the word
    anywhere would red a legitimate beat — but matching only at the START of the line missed the
    ONE-LINE forms, which are exactly the shape that silently ends the pass
    (`if [ -f "$STATE/x" ]; then continue; fi`, `[ … ] && exit 0`, `{ … && continue; }`) — measured
    2026-10-19: all four left the pinned transfer list, the enclosing-construct list and the
    function list BYTE-IDENTICAL and the suite green.

    ⛔ AND A PREFIX DOES NOT STOP IT (cycle-3 review, T2). `! continue`, `\\continue`,
    `command continue`, `builtin continue`, `eval continue`, `time continue` and
    `PD_X=1 continue` are all real transfers — bash runs them — and an anchored match saw none of
    them (verified behaviourally: the loop never reached the launch, transfers list byte-identical,
    23/23 green). A prefix IS command position, so the transparent prefixes are stripped first.
    """
    for stmt in _statements(s):
        if _TRANSFER_WORD.match(_strip_command_prefixes(stmt)):
            return stmt
    return None


# Prefixes that do not change WHICH command runs: negation, escaping, env assignments, and the
# shell's own transparent wrapper builtins. `eval`/`exec` are included because they still execute
# the named command, so a transfer behind them is a transfer.
_CMD_PREFIX = re.compile(
    r"^(?:[!\\\\]\s*|[A-Za-z_]\w*=\S*\s*|(?:command|builtin|eval|exec|time|nohup)\s+)")


def _strip_command_prefixes(stmt: str) -> str:
    """Strip transparent command prefixes, repeatedly (`ENV=1 time ! continue`)."""
    prev = None
    while prev != stmt:
        prev = stmt
        stmt = _CMD_PREFIX.sub("", stmt, count=1).lstrip()
    return stmt


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
        if _switch_arm(stack, s):
            continue
        opened = _opened_construct(s)
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
# ⛔ ANY ROOT, AND ABSOLUTE PATHS TOO (review of the head, MEASURED P2). The set of roots below was
# `SCRIPTS|STATE|HOME`, so a second dispatcher spelled `"$O/scripts/lane-feed.py"` (the beat's own
# orchestrator root) or `/usr/local/bin/lane-feed.py` contributed nothing to the enumeration and
# `undeclared` stayed empty — a second dispatch step on every pass, green. The root is now any
# variable, plus a bare absolute path.
_EXEC_PATH_REF = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?/([\w./-]+)')
_ABS_PATH_REF = re.compile(r'(?<![\w$}/.-])(/[\w.-]+/[\w./-]*)')
# Paths whose LAST segment is one of these are data, never a program; and a bare absolute path is
# only a candidate when it names a program (an extension we know, or an extensionless file under a
# `bin`/`scripts` directory) — otherwise every log path in the beat would join the population.
_NON_PROGRAM_SUFFIXES = (".log", ".lock", ".pid", ".tsv", ".json", ".txt", ".md", ".out")
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


def test_the_record_exemption_is_pinned_to_the_test_directories():
    """A LIVE copy named like a test is not a record (cycle-6 adversarial review).

    ⛔ PRE-FIX THIS WAS TRUE OF ANY PATH: `_is_record()` exempted every basename starting with
    `test_` and containing `dispatch`, so a re-armed copy placed at `tools/test_dispatch_feed.py`
    vanished from BOTH scanners — not only the mention scan but `_live_code_referencing`, the
    rename-proof half that exists precisely because the retired NAME can be reassembled. The suite
    stayed green over it. A suite is `scripts/test_*.py` or `tests/**/test_*.py`; nothing else.
    """
    for suite in ("scripts/test_dispatch_wiring.py", "tests/pi-bootstrap/test_dispatch_notes.py"):
        assert _is_record(suite), "%s is a suite and must be able to name what it asserts" % suite
    for live in ("tools/test_dispatch_feed.py", "extensions/test_dispatch.py",
                 "scripts/orchestrator-harness/test_dispatch_feed.sh",
                 "scripts/test_dispatch_feed.sh"):
        assert not _is_record(live), (
            "%s is LIVE code that happens to be named like a test; exempting it hides a re-arm "
            "from `_rearming_files()` and from `_live_code_referencing()` alike" % live)


# The LIVE-CLAIM surfaces: files whose prose states what the fleet currently runs. #1874 corrected
# this claim in `scripts/heartbeat-loop.sh`, `lane-status.py`, `cadence-nudge.sh` and `setup.sh` and
# MISSED these, so the repo held two different answers to "does anything read `issue_work` / is
# the dispatcher part of the beat" (cycle-6 review; the third entry was missed by THAT review's own
# fix — cycle 7). A retired tool may be named here — as RETIRED.
#
# ⛔ WHY THE HARNESS README IS LISTED EVEN THOUGH IT IS ALSO IN `_RECORD_FILES`: those are two
# different questions. `_RECORD_FILES` says "the mention/invocation scanners must not red a record",
# and the README legitimately quotes retired paths while documenting the harness. THIS list says
# "the prose in here describes what RUNS", which is exactly what the README is for — it is the
# largest live-claim surface in the repo. Keeping it out of this list (it was out until cycle 7)
# meant `_tracked_text_files()` dropped it before every scanner AND this test never read it, so the
# gate reported "no live-claim surface presents it as live" while the harness README presented
# `queue-dispatch.py` as `issue_work`'s live consumer and as one of the beat's gh tools.
_LIVE_CLAIM_FILES = ("scripts/pr-doctor.py", "docs/ops/gh-rate-limits.md",
                     "scripts/orchestrator-harness/README.md")


def test_no_live_claim_surface_states_the_retired_dispatcher_as_live():
    """Nothing that describes the RUNNING fleet may present the retired dispatcher as a live part.

    ⛔ THE FAILURE THIS PINS IS NOT A BROKEN BUILD, IT IS A FALSE RECORD: `pr-doctor.py` told its own
    reader that the dispatcher consumes and enforces `issue_work`, `gh-rate-limits.md` counted it
    among the beat's NINE tools and its SIX pinned-candidate resolvers, and the harness README — the
    largest live-claim surface in the repo — did both at once (:390 in the beat's gh tool list, and
    :1120 as `issue_work`'s live consumer and gate). All were true before #1874 and false after it,
    and a reader who trusts any of them concludes the owner's PR-first rule is still enforced by the
    thing that used to enforce it.

    The rule is one line: a mention is allowed only where it is marked as retired.

    ⛔ THE COVERAGE IS PINNED, not left to the tuple's contents: `scripts/orchestrator-harness/README.md`
    is in `_RECORD_FILES` too, so `_tracked_text_files()` drops it before EVERY other scanner —
    deleting it from `_LIVE_CLAIM_FILES` would leave the gate green while the biggest live-claim
    surface went unread, which is the cycle-7 regression this assertion exists to make loud.
    """
    required = ("scripts/pr-doctor.py", "docs/ops/gh-rate-limits.md",
                "scripts/orchestrator-harness/README.md")
    missing_surfaces = [n for n in required if n not in _LIVE_CLAIM_FILES]
    assert missing_surfaces == [], (
        "these live-claim surfaces are not graded: %s. They sit in `_RECORD_FILES`, so no other "
        "scanner reads them — dropping one here makes this test pass by not looking, which is "
        "exactly the false green #1940's cycle-7 review found." % missing_surfaces)
    offenders: list[str] = []
    for name in _LIVE_CLAIM_FILES:
        p = _REPO / name
        assert p.is_file(), "the live-claim surface %s is missing — fix the list, not the silence" % name
        for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            if "queue-dispatch.py" in line and "retired" not in line.lower():
                offenders.append("%s:%d: %s" % (name, i, line.strip()))
    assert offenders == [], (
        "these live-claim lines state the retired dispatcher as a live consumer/tool (mark it "
        "RETIRED, name the location under `retired/`, and state what runs instead):\n  %s"
        % "\n  ".join(offenders))


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
    # ⛔ EXACTLY ONE, AND EVERY ONE PINNED (review of the head, MEASURED P1). `any(...)` graded
    # "at least one launch is pinned", so a SECOND launch appended beside the pinned block was
    # green — and a second launch is the shape the header calls out: one more `pr-doctor.py` line
    # with `--dry-run` decides nothing, and a foreground one blocks the pass. MEASURED on a
    # mutant: `nohup ... pr-doctor.py --dry-run ... &` appended after the block left every
    # beat-side test passing (`assert any(...)` true, the detachment check reads the first launch).
    assert len(launches) == 1, (
        "the beat launches %s on %d lines: %r. There must be exactly ONE dispatch entry point "
        "(#1890) — a second launch is either a duplicate dispatch or a competing dispatcher. "
        "Delete it, or make it the one pinned launch." % (_DISPATCH_STEP, len(launches), launches))
    assert _is_pinned_launch(launches[0]), (
        "the beat's dispatch launch is not the pinned detached invocation. Got: %r\n"
        "Expected exactly: nohup /usr/bin/python3 \"$SCRIPTS/pr-doctor.py\" + redirects"
        " (optionally after a leading `(`, which #1954 moved onto its own line)\n"
        "Arguments are a way to make the pass a no-op (`--dry-run`, `--status`, `--max 0`), and so "
        "is an env prefix (`MAX_FIX=0 MAX_REVIEW=0`). The match is against the LOGICAL line, so an "
        "argument on a continuation line reds too. Change this pin WITH the launch, deliberately."
        % launches)
    # ⛔ AND IT MUST STILL BE DETACHED (#1954 follow-through). The pin above no longer requires a
    # leading `(` because the beat opens the subshell on its own line; without THIS assertion the
    # paren could be deleted from the prefix and a foreground launch would read as pinned while it
    # blocked the pass on a full dispatch cycle. The block is located structurally, so moving the
    # launch inside the subshell (as #1954 did) cannot silently disarm the check.
    assert _launch_is_in_backgrounded_subshell(_BEAT), (
        "the beat's dispatch launch is no longer inside a `( … ) &` subshell. A launch run in the "
        "pass's own shell BLOCKS the pass (~280-390s per dispatch), which is the property "
        "detaching exists to give; `nohup` alone does not background a command.")
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


def test_the_detached_shape_is_pinned_not_inferred(tmp_path):
    """The launch's `( … ) &` brackets are PINNED, and every shape that defeated a DERIVATION is
    graded here deliberately.

    ⛔ THREE REVIEW CYCLES, EACH ONE A MEASURED DEFEAT OF THE PREVIOUS REVISION:
      1. "nearest `(` above / next `) &` below" borrowed an unrelated `( sleep …` from a helper
         500 lines up — a foreground launch read as detached;
      2. bounding that walk by INDENTATION still let the launch be moved BELOW its own closer and
         take a later `( : ) &` as the span's end — again a foreground launch, green;
      3. a same-indent opener (`(` alone, launch on the next line) was invisible, while `)&` and
         `) &  # backgrounded` closers were false REDs on a correctly detached beat.
    Deriving the pair from the text IS a bash parser, and this repo has paid for text-scans that
    model the language; so the pair is pinned (see `_SUBSHELL_OPEN`) and the pin is exercised in
    both directions below — a shape that must be REFUSED, and a detached spelling that must be
    ACCEPTED. Half a matrix would let the next lane "fix" a false RED by loosening the pin.
    """
    def _span_of(text):
        lines = text.splitlines()
        return lines, _launch_subshell_span(lines)

    def _with(fn):
        mutated = _beat_mutated(tmp_path, fn)
        assert mutated is not None, "anchor missing: the launch's pinned subshell was not found"
        assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
            "the fixture %r is not valid bash, so it is not the shape it claims to test" % fn.__name__)
        return mutated

    # (1) the pair the beat ships.
    assert _launch_is_in_backgrounded_subshell(_BEAT), (
        "the shipped beat's dispatch launch is not inside a pinned `( … ) &` subshell")

    # ── shapes that MUST be refused: the launch is not in a backgrounded subshell ────────────────
    def _borrow_a_distant_pair(text):
        # ⛔ THE CLAIM IS "NO PINNED PAIR", NOT "a distant `(` is borrowed" (cycle-6 review): the
        # earlier derivation this fixture originally killed is gone from the code, so the number
        # that matters is that the launch is refused with the opener commented out and the closer's
        # `&` stripped — the launch is then in the pass's OWN shell, and the stray `( : ) &` planted
        # after it must not be adopted as its pair.
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        lines[o] = lines[o].replace("(", "", 1)
        lines[c] = lines[c].replace(") &", "")
        lines.insert(c + 1, "  ( : ) &")
        return "\n".join(lines) + "\n"

    def _move_the_launch_below_its_closer(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        launch = [i for i in range(o, c + 1) if _LAUNCH_SUBSHELL_HINT in lines[i]]
        if len(launch) != 1:
            return None
        li = launch[0]
        cont = [lines[li], lines[li + 1]] if lines[li].rstrip().endswith("\\") else [lines[li]]
        rest = [l for i, l in enumerate(lines[o:c + 1], start=o) if l not in cont]
        ind = " " * (len(lines[li]) - len(lines[li].lstrip()))
        return "\n".join(lines[:o] + rest + cont + [ind + "( : ) &"] + lines[c + 1:]) + "\n"

    def _sync_the_subshell_and_add_a_pair(text):
        # The enclosing subshell loses its `&` (it now runs SYNCHRONOUSLY, blocking the pass) and a
        # separate `( : ) &` is placed between the launch and it.
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        lines[c] = lines[c].replace(") &", ")")
        ind = " " * (len(lines[c]) - len(lines[c].lstrip()))
        lines.insert(c, ind + "( : ) &")
        return "\n".join(lines) + "\n"

    def _stray_pair_whose_closer_is_the_pinned_one(text):
        # The block's own closer loses its `&` (synchronous subshell = a blocking pass) and a
        # TWO-LINE pair is added below it whose closer IS the pinned `rmdir … ) &`.
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        lines[c] = lines[c].replace(") &", ")")
        ind = " " * (len(lines[c]) - len(lines[c].lstrip()))
        lines[c + 1:c + 1] = [ind + '( : > "$STATE/probe.tmp"',
                              ind + 'rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &']
        return "\n".join(lines) + "\n"

    def _close_and_reopen_within_one_line(text):
        # Cycle-8 review, MEASURED P1 and the reason the scan is per character: this line's NET
        # delta is +0, so a per-line depth walk never sees the pair close. The pinned closer then
        # matches the stray pair, and the launch — which bash runs SYNCHRONOUSLY in the opener's
        # pair — reads as detached. Runtime oracle on the mutant: 3008 ms until the block returned,
        # against 5 ms on the shipped beat (the launch stubbed with `sleep 3`).
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        i = next(i for i in range(launch, span[1]) if lines[i].strip() == "_rc=$?")
        lines[i] = lines[i].replace("_rc=$?", '_rc=$? ) ; ( : > "$STATE/probe.tmp"')
        return "\n".join(lines) + "\n"

    def _a_quoted_hash_hides_nothing(text):
        # Cycle-6 review, MEASURED: an inline-comment truncation cut at `  # ` inside the QUOTED
        # `"probe  # x"`, deleting the closing `)` from the line — a synchronous close read as
        # detached. Nothing is truncated now, so the `)` is visible where it is.
        lines, span = _span_of(text)
        if span is None:
            return None
        c = span[1]
        ind = " " * (len(lines[c]) - len(lines[c].lstrip()))
        lines[c:c + 1] = [
            ind + 'printf \'%s\\n\' "probe  # x" ; rmdir "$STATE/pr-doctor.lock" 2>/dev/null )',
            ind + '( : > "$STATE/probe.tmp"',
            ind + 'rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &',
        ]
        return "\n".join(lines) + "\n"

    def _a_compound_line_looks_finished(text):
        # Cycle-6 review, MEASURED: a finished `( : )` followed by the REAL synchronous close on
        # one line read as "neutral" under a per-line finishes-on-itself rule.
        lines, span = _span_of(text)
        if span is None:
            return None
        c = span[1]
        ind = " " * (len(lines[c]) - len(lines[c].lstrip()))
        lines[c] = ind + '( : ) ; rmdir "$STATE/pr-doctor.lock" 2>/dev/null )'
        lines.insert(c + 1, ind + '( : ) ; ( : > "$STATE/probe.tmp"')
        lines.insert(c + 2, ind + 'rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &')
        return "\n".join(lines) + "\n"

    def _stray_pair_opened_mid_line(text, opener='true; ( : > "$STATE/probe.tmp"'):
        # Cycle-5's measured defeat of a LINE-START-ONLY boundary test: a `(` in COMMAND POSITION
        # that does not begin the line opens a subshell just the same.
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        lines[c] = lines[c].replace(") &", ")")
        ind = " " * (len(lines[c]) - len(lines[c].lstrip()))
        lines[c + 1:c + 1] = [ind + opener,
                              ind + 'rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &']
        return "\n".join(lines) + "\n"

    def _stray_pair_opened_after_and_and(text):
        return _stray_pair_opened_mid_line(
            text, opener='[ -d "$STATE" ] && ( : > "$STATE/probe.tmp"')

    for fn, why in (
        (_borrow_a_distant_pair,
         "the opener commented out and the closer's `&` stripped leaves NO pinned pair: the "
         "launch is in the pass's own shell, and a stray `( : ) &` after it must not adopt it"),
        (_close_and_reopen_within_one_line,
         "a line whose NET depth change is zero that closes the pair and opens a stray one "
         "(`_rc=$? ) ; ( : …`) read as detached — the depth is read per character, not per line"),
        (_a_quoted_hash_hides_nothing,
         "a synchronous close on a line whose quoted text contains `  #  ` read as detached — a "
         "comment cut must never delete evidence"),
        (_a_compound_line_looks_finished,
         "a line that BOTH finishes one pair and closes ours (`( : ) ; rmdir … )`) read as "
         "neutral — the depth, not the line, is what gets counted"),
        (_stray_pair_opened_mid_line,
         "a SYNCHRONOUS subshell plus a stray pair opened mid-line (`true; ( : …`) read as "
         "detached — a boundary is a `(` in COMMAND POSITION, not a `(` at column 0"),
        (_stray_pair_opened_after_and_and,
         "the same with the opener after `&&` — another non-line-start spelling"),
        (_stray_pair_whose_closer_is_the_pinned_one,
         "a SYNCHRONOUS subshell plus a stray pair whose closer carries the pinned `rmdir … ) &` "
         "read as detached — any line starting with `(` after the launch ends the search"),
        (_move_the_launch_below_its_closer,
         "a launch moved BELOW its own closer read as detached: the walk borrowed a later pair"),
        (_sync_the_subshell_and_add_a_pair,
         "a SYNCHRONOUS subshell (closer lost its `&`) plus a stray `( : ) &` read as detached, so "
         "the pass would block on a full dispatch cycle (~280-390s)"),
    ):
        mutated = _with(fn)
        assert not _launch_is_in_backgrounded_subshell(mutated), "%s (%s)" % (why, fn.__name__)

    # ── detached spellings that MUST be accepted, or a correct beat REDs ────────────────────────
    def _ampersand_without_a_space(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        lines[span[1]] = lines[span[1]].replace(") &", ")&")
        return "\n".join(lines) + "\n"

    def _closer_with_a_trailing_comment(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        lines[span[1]] = lines[span[1]].rstrip() + "  # backgrounded"
        return "\n".join(lines) + "\n"

    def _bare_paren_on_its_own_line(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        lines[span[0]] = " " * (len(lines[span[0]]) - len(lines[span[0]].lstrip())) + "("
        return "\n".join(lines) + "\n"

    def _opener_on_the_launch_line(text):
        # ⛔ THIS IS THE PRE-#1954 SPELLING, not an invented hybrid (cycle-5 review, MEASURED).
        # `git show c30117d0^:scripts/heartbeat-loop.sh` lines 496-498 open the subshell on the
        # launch line (`( nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" \`) and close it on the
        # `rmdir … ) &` line — which is exactly what this fixture builds. It stays in the ACCEPTED
        # half because `_LAUNCH_PREFIX` accepts it and `_is_pinned_launch` accepts it. (A one-line
        # `( nohup … ) &` never shipped here; it ends the logical line with `) &`, which
        # `_is_pinned_launch` refuses as a non-redirection.)
        lines, span = _span_of(text)
        if span is None:
            return None
        o, c = span
        launch = next(i for i in range(o, c + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        indent = " " * (len(lines[o]) - len(lines[o].lstrip()))
        lines[launch] = indent + "( " + lines[launch].strip()
        del lines[o]
        return "\n".join(lines) + "\n"

    def _no_space_before_the_paren(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        lines[span[1]] = lines[span[1]].replace("2>/dev/null )", "2>/dev/null)")
        return "\n".join(lines) + "\n"

    def _spaced_redirect(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        lines[span[1]] = lines[span[1]].replace("2>/dev/null )", "2> /dev/null )")
        return "\n".join(lines) + "\n"

    def _finished_pair_above_the_launch(text):
        # Cycle-6 review, MEASURED false RED: a self-contained `( : ) &` ABOVE the launch counted
        # as "the pair already closed", while the identical line BELOW it was neutral.
        lines, span = _span_of(text)
        if span is None:
            return None
        o = span[0]
        ind = " " * (len(lines[o]) - len(lines[o].lstrip()))
        lines[o:o] = [ind + '( : ) &']
        return "\n".join(lines) + "\n"

    def _command_substitution_above_the_launch(text):
        # Cycle-6 review, MEASURED false RED: `$(…)` is an EXPANSION, and its `)` in closing
        # position used to be read as the subshell's own.
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch:launch] = [ind + "_now=$(date '+%H:%M:%S')"]
        return "\n".join(lines) + "\n"

    def _command_substitution_inside_the_block(text):
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch + 2:launch + 2] = [ind + "_stamp=$(date)"]
        return "\n".join(lines) + "\n"

    def _process_substitution_inside_the_block(text):
        # Class 4's `<(…)` item, which the declaration claimed and no fixture exercised (cycle-7
        # review, measured: deleting the scanner's process-substitution branch left the suite
        # green). `<(cmd)` is an expansion; its `)` is not the subshell's.
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch + 2:launch + 2] = [ind + "diff <(printf a) <(printf b) >/dev/null"]
        return "\n".join(lines) + "\n"

    def _and_and_above_the_launch(text):
        # `&&` is a CONTINUATION, not a background operator; a guard that read it as "the pair
        # already closed" reddened a correct beat (cycle-5 review, measured B1).
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch:launch] = [ind + '[ -d "$STATE" ] &&']
        return "\n".join(lines) + "\n"

    def _background_job_inside_the_block(text):
        # Backgrounding ONE command inside the subshell does not end it (cycle-5 review, measured
        # B2): the `&` belongs to the sleep, not to the pair.
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch:launch] = [ind + "/bin/sleep 0.01 &"]
        return "\n".join(lines) + "\n"

    def _self_contained_pair_below_the_launch(text):
        # A `( … )` that opens AND closes on one line is a finished pair: it neither opens nor
        # closes the launch's, so it must not be read as "the launch is not in this one".
        lines, span = _span_of(text)
        if span is None:
            return None
        launch = next(i for i in range(span[0], span[1] + 1) if _LAUNCH_SUBSHELL_HINT in lines[i])
        ind = " " * (len(lines[launch]) - len(lines[launch].lstrip()))
        lines[launch + 2:launch + 2] = [ind + '( : > "$STATE/probe.tmp" )']
        return "\n".join(lines) + "\n"

    for fn, why in (
        (_finished_pair_above_the_launch,
         "a finished `( : ) &` above the launch is a pair of its own; it must not be read as the "
         "launch's pair having closed"),
        (_command_substitution_above_the_launch,
         "`$(date …)` above the launch is an expansion, not a subshell boundary"),
        (_command_substitution_inside_the_block,
         "`$(date)` inside the block is an expansion, not a boundary"),
        (_process_substitution_inside_the_block,
         "`<(…)` inside the block is an expansion too; its `)` is not the subshell's"),
        (_and_and_above_the_launch,
         "`&&` above the launch is a continuation, not the end of the pair"),
        (_background_job_inside_the_block,
         "a `&` INSIDE the subshell backgrounds one command; the pair is still backgrounded"),
        (_self_contained_pair_below_the_launch,
         "a self-contained `( … )` below the launch is a finished pair of its own"),
        (_no_space_before_the_paren,
         "`2>/dev/null)` is valid bash and still backgrounded; refusing it reds a correct beat"),
        (_spaced_redirect,
         "`2> /dev/null` is the same redirect; refusing it reds a correct beat"),
        (_ampersand_without_a_space,
         "`( … )&` is the same backgrounding with no space; refusing it reds a correct beat"),
        (_closer_with_a_trailing_comment,
         "a comment after the closer does not change what bash runs; refusing it reds a correct beat"),
        (_bare_paren_on_its_own_line,
         "the opener on its own line (``(` alone) is the ordinary spelling; refusing it reds a "
         "correct beat"),
        (_opener_on_the_launch_line,
         "an opener ON the launch line is a spelling `_LAUNCH_PREFIX` accepts, so this check must "
         "see the span or a correct beat reds"),
    ):
        mutated = _with(fn)
        assert _launch_is_in_backgrounded_subshell(mutated), "%s (%s)" % (why, fn.__name__)


def test_the_gate_refuses_to_be_silenced():
    """Two lines can turn every assertion in this file into "N skipped" and a green check.

    ⛔ MEASURED (review of the head): a `pytestmark = pytest.mark.skip(...)` assignment at the top of
    this file makes CI's own invocation (`-x --timeout=60 -q`) exit 0 with "32 skipped", and nothing
    in the repo reads skip counts. The refusal is at IMPORT time — a collection error is the only
    non-zero exit CI carries — and it is graded here through the detector, because a test cannot
    observe its own skipped module.
    """
    def marks(src: str) -> list[str]:
        return _silencing_markers(ast.parse(src))

    assert marks("pytestmark = None\n") == ["pytestmark"]
    for call in ("pytest.mark.skip(reason='x')", "pytest.mark.skipif(True, reason='x')",
                 "pytest.mark.xfail", "pytest.skip('x')", "pytest.importorskip('x')"):
        src = "import pytest\n\n@pytest.mark.parametrize('a', [1])\ndef t(a):\n    return %s\n" % call
        assert marks(src) == [call.split("(")[0]], (
            "the detector missed %r (got %r)" % (call, marks(src)))
    # A DOCSTRING that documents the rule is not a marker — the first version of this check refused
    # its own file on exactly that (measured), which is why the surface is the parse tree.
    assert marks('"""Never write pytestmark = pytest.mark.skip(...)."""\n') == []
    assert not marks("def t():\n    return 1\n"), (
        "the detector fires on an ordinary module — a false refusal would block a legitimate run")
    # …and the LIVE module is not silenced, which is the property, not the detector.
    assert _SILENCED == [], "this module is silenced: %r" % (_SILENCED,)


def test_an_else_arm_with_a_trailing_comment_is_still_the_arm(tmp_path):
    r"""`else  # take the lock` is the same arm — losing it moved the frame back to `("if", …)`.

    ⛔ MEASURED (cycle-3 review): `_ARM_ELSE` matched `^else\s*$` only, so a commented arm was not
    consumed at all and `_enclosing_constructs` returned the `if` frame instead of the `else` one —
    a correct beat red, and the arm distinction the frame exists for silently disappearing for that
    spelling. The mutant below is that exact edit on the shipped beat.
    """
    # ⛔ ANCHORED ON THE LOCK ARM ITSELF (cycle-4 review, MEASURED). A bare `"    else\n"` pattern
    # matched INSIDE `report_detached_rc()`'s `      else` first, so the mutant commented the wrong
    # arm and the test passed with `_ARM_ELSE` reverted — it graded nothing. The anchor is the
    # line that follows the arm, which appears exactly once.
    _LOCK_ELSE = '    else\n      rmdir "$STATE/pr-doctor.lock" 2>/dev/null'

    def _comment_the_else(text):
        if _LOCK_ELSE not in text:
            return None
        return text.replace(
            _LOCK_ELSE, '    else  # take the lock\n      rmdir "$STATE/pr-doctor.lock" 2>/dev/null', 1)

    mutated = _beat_mutated(tmp_path, _comment_the_else)
    assert mutated is not None, "anchor missing: the lock check's `else` moved"
    assert not subprocess.run(["bash", "-n", str(mutated)]).returncode, (
        "the fixture is not valid bash")
    # …and the mutation really is ON THE LOCK ARM: the beat has exactly one such comment, and the
    # arm's own body is still beside it.
    assert mutated.read_text().count("# take the lock") == 1, (
        "the mutant did not apply to exactly one arm — the fixture is grading the wrong `else`")
    assert _enclosing_constructs(mutated, _DISPATCH_STEP) == _DISPATCH_ENCLOSING, (
        "a commented `else` arm changed the enclosing-construct list to %r — the arm frame must "
        "survive a trailing comment" % (_enclosing_constructs(mutated, _DISPATCH_STEP),))


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
            if not base or base.endswith(_NON_PROGRAM_SUFFIXES):
                continue
            # `$STATE` carries logs and lock files, so there only an explicit interpreter file
            # counts. Every other root is a program directory.
            if root == "STATE" and not base.endswith(_EXEC_SUFFIXES):
                continue
            launched.add(base)
        for name in _ABS_PATH_REF.findall(flat):
            base = name.rsplit("/", 1)[-1]
            # An absolute path is a launch candidate only when it names a FILE WE COULD OWN — a
            # `.py`/`.sh`. An extensionless absolute path is nearly always an interpreter or a
            # coreutil (`/bin/bash`, `/usr/bin/python3`), and enumerating those turned every beat
            # into an "undeclared step" (measured while fixing this). Extensionless steps live under
            # a `$VAR` root in this repo, and that branch has no suffix requirement.
            if not base.endswith(_EXEC_SUFFIXES) or base.endswith(_NON_PROGRAM_SUFFIXES):
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
    assert not any(_is_pinned_launch(l) for l in launches), (
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
    ('if true; then continue; fi', "a dead-branch one-line"),
]
# ⛔ NOT A DEFEAT, AND DELIBERATELY ABSENT: `while :; do break; done` was in an earlier revision of
# this matrix because the transfer scanner reports a `break` in it. It does NOT stop the pass — the
# pass loop is a DIFFERENT `while :; do`, so this one runs once and falls through to the guard
# (cycle-2 review, verified). Pinning it would assert a FALSE POSITIVE, which is the opposite of
# what this matrix is for: a matrix that demands the gate red a correct beat teaches the next lane
# to loosen the gate.


def test_the_transfer_scanner_does_not_red_a_correct_beat():
    """The other half of the property: no false positives on ordinary shell text.

    A reachability gate that reds correct code gets loosened by whoever hits it next — so "it
    detects the defeat" is only half a gate. `_word_prefixed` in an earlier revision tested a
    single CHARACTER against a concatenated CHARSET (`";&|(){}then do else"`), so any word ending in
    t/h/e/n/d/o/l/s counted as a separator and these read as transfers (cycle-2 review, measured).
    """
    not_transfers = [
        'not continue',
        'echo "continue"',
        '--continue',
        'x-continue',
        "printf '%s step did not return\\n' x",
        'echo "no exit"',
        'log "$rc"',
        'continue_flag=1',
    ]
    wrong = [(s, _leading_statement(s)) for s in not_transfers if _leading_statement(s)]
    assert not wrong, (
        "these are not control transfers but were read as one, so a correct beat would be "
        "blocked: %r" % wrong)
    # And the shapes that ARE transfers, so the negative above is not passing by refusing all input.
    for s in ('continue', 'exit 0', 'foo; continue', '[ -n "$X" ] && exit 3',
              'if [ -f "$X" ]; then return 1; fi'):
        assert _leading_statement(s) is not None, (
            "%r is a control transfer in command position but was not detected" % s)


def test_the_heredoc_stripper_does_not_swallow_the_file(tmp_path):
    """A `<<` that is not a shell operator must not delete the rest of the file.

    ⛔ A P0 THIS FILE INTRODUCED (cycle-2 review). The first stripper regexed for `<<WORD`
    anywhere, so a quoted `printf '%s\n' "<<PROSE"` — or a comment mentioning `<<EOF` — opened a
    body whose terminator never arrived and DELETED EVERY FOLLOWING LINE from both views. One such
    line hid the retired dispatcher, a second dispatch step and `MAX_FIX=0` from every scan that
    reads `_executable_lines`, and the suite stayed green (measured: 180 -> 110 lines).
    """
    body = "\n".join([
        "#!/bin/bash",
        'printf \'%s\\n\' "<<PROSE"',
        "echo hi  # usage: cat <<EOF",
        'echo "a <<B b"',
        "orchestrator-launch-marker",  # the line that must survive every one of the above
    ]) + "\n"
    p = tmp_path / "_heredoc_guard.sh"
    p.write_text(body)
    lines = _executable_lines(p)
    assert "orchestrator-launch-marker" in lines, (
        "a `<<` inside a QUOTED string or a comment swallowed the rest of the file, so every scan "
        "that reads this view is silently looking at nothing. Got: %r" % lines)
    # The positive control: a REAL opener still strips its body.
    real = "\n".join([
        "#!/bin/bash",
        ": <<'PROSE'",
        "this-is-body",
        "PROSE",
        "orchestrator-launch-marker",
    ]) + "\n"
    p.write_text(real)
    lines = _executable_lines(p)
    assert "this-is-body" not in lines, "a real heredoc body is still scanned as code"
    assert "orchestrator-launch-marker" in lines, (
        "the terminator did not end the body, so real code after a heredoc is dropped")


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
def _wrap_launch_block_in_heredoc(text, opener, terminator, fake_terminator=None):
    """Insert `<opener>` before the launch's subshell and `<terminator>` after it.

    ⛔ THE ANCHORS ARE STRUCTURAL, NOT LITERAL (#1954 moved the launch inside the subshell). The
    mutant must be valid bash — the terminator at COLUMN 0 — so the wrapped span is the whole
    `( … ) &` subshell, never the launch line alone: an opener before `nohup` and a terminator after
    `) &` would leave the subshell's `(` outside the heredoc with its matching `)` inside it.
    """
    lines = text.splitlines()
    span = _launch_subshell_span(lines)
    if span is None:
        return None
    o, c = span
    body = [fake_terminator] if fake_terminator is not None else []
    return "\n".join(lines[:o] + [opener] + body + lines[o:c + 1] + [terminator] + lines[c + 1:]) + "\n"


def _heredoc_wrap_the_launch(text):
    # `<<'WORD'` (no `-`) requires the terminator at COLUMN 0 — an indented one is not a terminator
    # to bash, and a fixture bash would reject proves nothing about a shape bash would run.
    return _wrap_launch_block_in_heredoc(text, ": <<'UNUSED_PROSE'", "UNUSED_PROSE")


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
    assert any(_is_pinned_launch(l) for l in launches), (
        "the pinned launch does not match the UNMUTATED beat — the pin is wrong, not the mutants")
    assert _early_transfers(baseline, _DISPATCH_STEP) == _ALLOWED_EARLY_TRANSFERS, (
        "the unmutated beat does not produce the pinned transfer list")
    assert [l for l in _executable_lines(baseline) if _DISPATCH_STEP in l], (
        "the unmutated beat's launch is not seen as executable code")


# ⛔ THE INDENTED FAKE TERMINATOR (cycle-2 review, P1). Bash ends a plain `<<'WORD'` body only on a
# line that IS the word at COLUMN 0. A stripper that matches with `strip()` ends the body early on
# an indented copy, so it reads the launch as live code while bash keeps treating it as body.
def _heredoc_indented_fake_terminator(text):
    # opener, then an INDENTED copy of the word (not a terminator to bash), then the launch block,
    # then the real terminator at column 0 — so bash never executes the launch.
    return _wrap_launch_block_in_heredoc(text, ": <<'PROSE'", "PROSE", fake_terminator="  PROSE")


def test_a_defeated_gate_an_indented_fake_terminator_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _heredoc_indented_fake_terminator)
    assert mutated is not None, "anchor missing: the launch's first or printf line moved"
    assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
        "the fixture is not valid bash, so it is not the shape it claims to test")
    assert not [l for l in _executable_lines(mutated) if _DISPATCH_STEP in l], (
        "an INDENTED copy of the heredoc word was accepted as the terminator, so this scanner saw "
        "the launch as live code while bash treats it as heredoc body — the beat dispatches "
        "nothing and this gate reports the launch present")


# ⛔ THE ANONYMOUS BRACE GROUP (cycle-2 review, P0). `[ -n \"$X\" ] && {` opens a group no named
# opener matches, so an env feature flag around the whole dispatch — the exact "added but not
# switched on" inversion #1890 exists to remove — left every reachability list BYTE-IDENTICAL.
def _brace_group_around_the_block(text):
    if _GUARD not in text:
        return None
    marker = "  # ⛔ THE EXIT STATUS IS READ FROM A RECORD"
    if marker not in text:
        return None
    return text.replace(
        _GUARD, '  [ -n "${PR_DOCTOR_ENABLE}" ] && {\n  ' + _GUARD, 1).replace(
        marker, "  }\n" + marker, 1)


def test_a_defeated_gate_an_anonymous_brace_group_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _brace_group_around_the_block)
    assert mutated is not None, "anchor missing: the arm guard or the exit-status note moved"
    assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
        "the fixture is not valid bash, so it is not the shape it claims to test")
    assert _enclosing_constructs(mutated, _DISPATCH_STEP) != _DISPATCH_ENCLOSING, (
        "the launch is inside a brace group opened by `[ -n \"$PR_DOCTOR_ENABLE\" ] && {` and the "
        "enclosing-construct list is UNCHANGED, so an env feature flag around the whole dispatch "
        "reads as green — the launch runs only when the flag is set, which is the inversion #1890 "
        "exists to remove")


# ⛔ THE GLUED REDIRECT (cycle-2 review, P2). `2>&1--dry-run` is not valid bash (ambiguous
# redirect), so pr-doctor never starts while the pass prints "launched detached". A redirect regex
# with a `\\S+` target absorbs the glued argument and calls the line pinned.
def _glue_an_argument_to_the_redirect(text):
    # ⛔ ANCHORED ON THE REDIRECTIONS, NOT ON A SHARED `$STERR` NAME (#1954). The launch now writes
    # the child's OWN stderr file (`2>>"$STATE/pr-doctor.stderr"`), not the shared `$STERR`; a
    # fixture anchored on the old text would report "anchor missing" and prove nothing.
    old = '>>"$STATE/pr-doctor.log" 2>>"$STATE/pr-doctor.stderr"'
    if old not in text:
        return None
    return text.replace(old, '2>&1--dry-run ' + old, 1)


def test_a_defeated_gate_a_glued_redirect_argument_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _glue_an_argument_to_the_redirect)
    assert mutated is not None, "anchor missing: the launch's redirection changed"
    launches = [l for l in _logical_lines(mutated) if _DISPATCH_STEP in l]
    assert launches, "the mutation removed the launch; the fixture is wrong, not the gate"
    assert not any(_is_pinned_launch(l) for l in launches), (
        "`2>&1--dry-run` was accepted as a redirection, but bash rejects it as an ambiguous "
        "redirect: the launch never starts and the gate says the invocation is exactly right")


# ⛔ THE POPULATION FLOOR ON THE SCANNER ITSELF. Every assertion in this file reads one of the two
# views, so a filter that silently drops most of the beat makes ALL of them vacuous at once. This
# is the check that turns "the scan found nothing" into RED instead of clean.
def test_the_beat_scans_are_not_silently_empty():
    # Compare against NON-COMMENT lines: the beat is mostly prose (626 non-blank, 180 code), so a
    # floor against all non-blank lines would red a healthy file and teach the next lane to delete
    # the guard. The property is "nothing but real heredoc bodies may be dropped".
    raw = [l for l in _BEAT.read_text().splitlines()
           if l.strip() and not l.strip().startswith("#")]
    assert len(_executable_lines(_BEAT)) >= 0.9 * len(raw), (
        "the executable view kept only %d of %d non-comment lines of the beat — a filter is "
        "swallowing the file, and every scan that reads this view is looking at almost nothing"
        % (len(_executable_lines(_BEAT)), len(raw)))
    assert len(_executable_raw(_BEAT)) >= 0.9 * len(raw), (
        "the raw view kept only %d of %d non-comment lines"
        % (len(_executable_raw(_BEAT)), len(raw)))


# ═══════════════════════════════════════════════════════════════════════════════════════════════
# Cycle 3: the same property, spelled through a PREFIX, an `elif`, and an odd heredoc word
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# Every shape below was reproduced against the cycle-2 revision: `bash -n` clean, the launch never
# executed, and the gate's lists BYTE-IDENTICAL to their pinned values with the suite green.
# Pinned now so the next widening of a matcher cannot quietly reopen one.

# ⛔ T2 — A PREFIXED TRANSFER. Anchoring `_TRANSFER_WORD.match` at the START of a statement misses
# `! continue`, `\continue`, `command continue`, `builtin continue`, `eval continue`,
# `time continue` and `PD_X=1 continue` — all of which bash executes as a `continue`. A prefix IS
# command position.
_PREFIXED_TRANSFERS = [
    "! continue",
    "\\continue",
    "command continue",
    "builtin continue",
    "eval continue",
    "time continue",
    "PR_DOCTOR_SKIP=1 continue",
    "PR_DOCTOR_SKIP=1 time ! continue",
]


def test_a_defeated_gate_every_prefixed_early_transfer_is_refused(tmp_path):
    survivors = []
    for stmt in _PREFIXED_TRANSFERS:
        mutated = _beat_mutated(tmp_path, _insert_before_guard(stmt))
        assert mutated is not None, "anchor missing: the arm guard line moved"
        assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
            "the fixture %r is not valid bash, so it is not the shape it claims to test" % stmt)
        transfers = _early_transfers(mutated, _DISPATCH_STEP)
        if transfers is None or transfers == _ALLOWED_EARLY_TRANSFERS:
            survivors.append(stmt)
    assert not survivors, (
        "these are real `continue`s (bash runs them, so the pass ends before the launch) but were "
        "not recorded as transfers, leaving the pinned list unchanged and this gate green: %r"
        % survivors)


# ⛔ T3 — AN UNPINNED `elif` BRANCH. `_OPEN_IF` matches only `^if`, so an `elif` opened nothing and
# sat at the same stack depth; the guard line, construct list, transfer list, function list and
# launch pin all stayed byte-identical while the launch ran only when the flag was set.
def _elif_branch_around_the_block(text):
    if _GUARD not in text:
        return None
    marker = "  # ⛔ THE EXIT STATUS IS READ FROM A RECORD"
    if marker not in text:
        return None
    # Turn the arm guard into an `if` that does nothing, with the ORIGINAL block moved into an
    # `elif` on an env flag — the "added but not switched on" inversion, spelled as an elif.
    return text.replace(
        _GUARD,
        _GUARD + "\n    :\n  elif [ -n \"${PR_DOCTOR_ENABLE}\" ]; then", 1)


def test_a_defeated_gate_an_elif_branch_around_the_block_is_refused(tmp_path):
    mutated = _beat_mutated(tmp_path, _elif_branch_around_the_block)
    assert mutated is not None, "anchor missing: the arm guard moved"
    # This mutant is intended as valid bash; if the insertion does not balance its `fi`, the
    # fixture is wrong and the test must say so rather than pass on a rejected input.
    assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
        "the elif fixture is not valid bash — fix the fixture, not the gate")
    assert _enclosing_constructs(mutated, _DISPATCH_STEP) != _DISPATCH_ENCLOSING, (
        "the launch sits inside an `elif` branch and the enclosing-construct list is UNCHANGED: "
        "the beat dispatches only when the flag is set, which is the inversion #1890 removes")


def test_the_opener_table_opens_if_select_and_groups_but_not_elif():
    """The opener table itself, so a new opener cannot be added for one reader and not the other.

    The name says NOT `elif`: an arm is not an opener. `_switch_arm` consumes it by REPLACING the
    top frame's subject, and the assertions below pin that split in both directions.
    """
    # ⛔ AN `elif` ARM OPENS NOTHING — its `fi` is the SAME `fi` as the enclosing `if`'s (measured:
    # pushing it left the `if` frame on the stack forever and reddened a correct beat, because
    # #1954's `report_detached_rc()` contains one). The `elif` arm is still GRADED: `_switch_arm`
    # records the arm it selects, and the dead-branch scan reads its condition (`_IF_CONDITION`
    # accepts `elif`); `test_a_defeated_gate_an_elif_branch_around_the_block_is_refused` runs that
    # case end to end on the beat.
    assert _opened_construct('elif [ -n "$FLAG" ]; then') is None
    # …and the OTHER direction, so "the arm is graded" is an assertion and not a sentence: the arm
    # is CONSUMED by `_switch_arm`, which REPLACES the top frame's subject (never pushes), so the
    # stack stays balanced and the arm is still visible in the enclosing list.
    arm_stack = [("loop", "while :"), ("if", "A")]
    assert _switch_arm(arm_stack, 'elif [ -n "$FLAG" ]; then') is True
    assert arm_stack == [("loop", "while :"), ("elif", '[ -n "$FLAG" ]')], arm_stack
    assert _switch_arm(arm_stack, "else") is True
    assert arm_stack == [("loop", "while :"), ("else", '[ -n "$FLAG" ]')], arm_stack
    # An arm line with no `if` above it is still consumed (it is not a construct), never pushed.
    assert _switch_arm([], 'elif [ -n "$FLAG" ]; then') is False
    assert _opened_construct('select x in 1; do') is not None
    assert _opened_construct('if false; then') == ("if", "false")
    # A one-liner opens AND closes on its own line, so it opens nothing.
    assert _opened_construct('if [ -f "$X" ]; then continue; fi') is None
    # Any unpinned `{` opener is a group, whatever precedes it.
    assert _opened_construct('[ -n "$X" ] && {') == ("group", '[ -n "$X" ] && {')


def test_an_elif_inside_a_function_does_not_leave_a_phantom_frame(tmp_path):
    """The MEASURED regression: an `elif` inside a function made the function read as open.

    #1954 landed `report_detached_rc()`, whose body has one `elif`. Under the frame-pushing model
    the `fi` that closes the `elif` left the enclosing `if` frame behind, so the function's own
    `}` popped THAT frame and the launch two hundred lines later came back enclosed by
    `('func', 'report_detached_rc')` — a false RED. The same one-frame drift in the other
    direction hides a real enclosing construct, which is a false GREEN, so the property is pinned
    here on a minimal fixture rather than left to the beat's current incidental shape.
    """
    p = tmp_path / "elif_balance.sh"
    p.write_text(
        "#!/bin/bash\n"
        "f() {\n"
        "  if [ -n \"$1\" ]; then\n"
        "    :\n"
        "  elif [ -n \"$2\" ]; then\n"
        "    :\n"
        "  fi\n"
        "}\n"
        "dispatch-marker\n")
    assert _enclosing_constructs(p, "dispatch-marker") == [], (
        "an `elif` arm left a phantom frame open, so every closer after it pops the wrong entry: "
        "the enclosing-construct list stops describing what actually encloses the launch")


# ⛔ T4 — A HEREDOC DELIMITER THE REGEX COULD NOT SEE. `<<'1'` (a digit-leading word) and `<<\W`
# (a backslash-escaped word) are both real heredocs — `bash -n` clean and the launch never runs —
# but an identifier-shaped pattern matched neither, so the body stayed scannable and the disabled
# launch read as live code.
def _heredoc_with_odd_delimiter(text, delimiter):
    return _wrap_launch_block_in_heredoc(text, ": <<%s" % delimiter,
                                         delimiter.strip("'\"\\"))


def test_a_defeated_gate_odd_heredoc_delimiters_are_refused(tmp_path):
    survivors = []
    for delimiter in ("'1'", "\\W", "'a-b.c'", "END_2"):
        mutated = _beat_mutated(tmp_path, lambda t, d=delimiter: _heredoc_with_odd_delimiter(t, d))
        assert mutated is not None, "anchor missing: the launch's first or last line moved"
        assert subprocess.run(["bash", "-n", str(mutated)]).returncode == 0, (
            "the fixture with delimiter %r is not valid bash, so it is not the shape it claims "
            "to test" % delimiter)
        if [l for l in _executable_lines(mutated) if _DISPATCH_STEP in l]:
            survivors.append(delimiter)
    assert not survivors, (
        "a heredoc opened with these delimiters was NOT stripped, so this scanner treated the "
        "launch as live code while bash treated it as heredoc body (the beat dispatches nothing): "
        "%r" % survivors)
