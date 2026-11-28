#!/usr/bin/env python3
"""code-identity.py — is the CODE of two revisions of one file identical?

agent-infra#4105. `scripts/record-review.sh`'s stale-sha guard refuses to record a
verdict at a sha that is not the PR's current head, because three prior arms
(diff / patch / lane) could only prove that the *rendered artifact* was unchanged.
MEASURED on tortoise#13104: 12 commits, 4 of them docstring-only, 3 fresh-context
reviews discarded (each refused by that guard), and a diff between the reviewed
code head and the final head that was one file, docstring-only,
`AST_IDENTICAL_AFTER_DOCSTRING_STRIP: True`. The verdict was about the CODE; the
delta was about prose. This helper is the measurement that lets the recorder bind
the verdict to the substance it actually attests.

WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT
  * `.py` — parse with `ast`, strip every docstring node (module/class/function),
    compare `ast.dump(...)`. Comments are not in the AST at all, so a
    comment-only delta normalises away too. The `#!` line is NOT an AST node,
    and it is not prose either: it selects the interpreter AND its flags
    (`-OO` strips docstrings and assertions at import time), so a shebang delta
    is executable content — it IS compared (the same predicate the shell
    normaliser already applies), and a pair that differs only there reports
    DIFFERENT. A file that does not parse is NOT "identical" — it is
    un-normalisable and the caller must refuse.
  * `.sh` / `.bash` — strip whole-line comments, conservatively: a line is only
    dropped when it is *entirely* a comment (first non-blank character is `#`,
    and the line is not a shebang), the line's quotes are BALANCED (a line that
    ends inside a string is refused — that is a multi-line string, where a `#`
    line may be DATA), the line takes no part in a BACKSLASH LINE-CONTINUATION
    (see the next bullet), and a heredoc BODY is emitted verbatim, so a `#` line
    inside one is never dropped. Inline/trailing comments are NOT stripped:
    keeping them can only make the comparison say "different", which is the
    fail-closed direction.
  * BACKSLASH CONTINUATIONS ARE REFUSED, NEVER GUESSED. POSIX.1-2017 XCU §2.2.1
    removes the backslash+newline pair BEFORE the input is split into tokens, so
    comment recognition happens AFTER the splice: a `#` line that follows a
    continued line is not a standalone comment (it becomes part of the previous
    command's tokens), and a whole-line comment that itself ends in a trailing
    backslash swallows the NEXT physical line as comment text. Stripping either
    one changes the program, and the pre-fix helper reported such a pair as
    IDENTICAL: a line ending in a backslash, then `# c`, then `bar`, against the
    same first line followed by `bar` (measured rc 0; the first prints `foo` and
    then fails on `bar`, the second prints `foo bar`). Both shapes now return
    `cannot normalise` (exit 2), which the caller treats as CHANGED — the
    fail-closed direction, and cheaper than a false carry.
  * ARITHMETIC `<<` IS NOT A HEREDOC. `n=$(( 1 << 4 ))` is a left shift inside
    an arithmetic expansion, not an operator with a delimiter; the scanner tracks
    `((`/`))` so a shift cannot make an ordinary script un-normalisable, while a
    real `<<EOF` on the same line still opens a heredoc body.
  * EVERYTHING ELSE — refused (exit 2). A `.ts`/`.js` normaliser without a real
    parser cannot tell a comment from a regex literal or a template string, and
    a wrong "identical" here would carry a verdict across code nobody reviewed.
    So the caller treats the file as CHANGED, which is exactly today's
    behaviour; the fix is a no-op where it cannot be confident, never a guess.

CALLING CONTRACT (the recorder depends on this and nothing else)
    code-identity.py <repo-relative-path> <file-a> <file-b>
    exit 0 — the two files normalise to the SAME code
    exit 1 — they normalise to DIFFERENT code
    exit 2 — cannot normalise (unknown language, parse failure, unterminated
             heredoc/quote, a comment spliced by a line continuation,
             binary/NUL, over-size, unreadable) — the caller MUST treat this as
             CHANGED. Never as "identical".
No stdout on success/failure beyond diagnostics on stderr; the recorder only
reads the exit code, so a future refactor cannot mistake wording for a verdict.
"""

import ast
import os
import re
import sys

# A file larger than this is refused rather than normalised: the largest source
# files a review verdict is meaningfully bound to are orders of magnitude below
# it, and a multi-megabyte blob is a sign this is not the file it claims to be.
# (Spelled as a multiplication, not a left shift: `check-portability-traps.sh`
# reads this file with a SHELL lexer, where a doubled `<` opens a heredoc — a
# false positive it cannot be talked out of, and one the operator should not have
# to grandfather on a NEW file.)
MAX_BYTES = 1024 * 1024

_SHELL_EXTS = (".sh", ".bash", ".bash5")
_PYTHON_EXTS = (".py",)
# The heredoc operator (a doubled `<`), optional `-` (strip leading tabs),
# optional quote around a shell word. Captured groups are (strip-tabs, quote, word).
_HEREDOC_RE = re.compile(r"<<(-?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
_SHEBANG_PY_RE = re.compile(r"\bpython[0-9.]*\b")
_SHEBANG_SH_RE = re.compile(r"\b(?:ba|da)?sh\b")


def refuse(msg):
    sys.stderr.write("code-identity: %s\n" % msg)
    raise SystemExit(2)


def read_text(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        refuse("cannot read %s: %s" % (path, exc))
    if len(data) > MAX_BYTES:
        refuse("%s is larger than %d bytes — refusing to normalise it" % (path, MAX_BYTES))
    # A NUL byte means this is not text: there is no comment syntax in a binary,
    # so "identical after stripping comments" is undefined. Fail closed.
    if b"\x00" in data:
        refuse("%s looks binary (NUL byte) — refusing to normalise it" % path)
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        refuse("%s is not valid UTF-8 (%s) — refusing to normalise it" % (path, exc))


def language_of(path, text):
    """The normaliser for this file, or None when we cannot be confident."""
    ext = os.path.splitext(os.path.basename(path))[1].lower()
    if ext in _PYTHON_EXTS:
        return "python"
    if ext in _SHELL_EXTS:
        return "shell"
    if ext:
        # A KNOWN extension that is not in the set above is a deliberate refusal
        # (.ts/.js/.md/.json/…), not an oversight — see the module docstring.
        return None
    # Extensionless: a shebang is the only confident signal, and it must be
    # unambiguous (a `#!/usr/bin/env python3` is; a `#!/bin/sh` is; anything
    # else is refused).
    first = text.split("\n", 1)[0]
    if not first.startswith("#!"):
        return None
    if _SHEBANG_PY_RE.search(first):
        return "python"
    if _SHEBANG_SH_RE.search(first):
        return "shell"
    return None


def _is_str_expr(value):
    """True for a string-literal expression node (a docstring candidate).

    `ast.Constant` is the ONLY spelling used: `ast.Str` is deprecated since 3.12
    (it emits a `DeprecationWarning` the first time the name is resolved, and the
    recorder no longer swallows this helper's stderr — #4105 review, P3) and is
    scheduled for removal in 3.14. Every string literal is a `Constant` on the
    interpreters this runs on, so the alias bought nothing.
    """
    return isinstance(value, ast.Constant) and isinstance(value.value, str)


def _strip_docstrings(tree):
    """Blank every docstring node's slot, in place.

    ⛔ THE TRAVERSAL IS NOT WHAT THIS MUTATION DEPENDS ON. `ast.walk` is
    breadth-first and enqueues a node's children BEFORE yielding it, so the
    nodes this loop will visit were fixed before the body slot was replaced —
    which is fine, because what must be blank at the end is the SLOT in `body`,
    not the traversal. Every candidate node is still yielded (the old children
    remain queued and are harmless), so no docstring can survive into the dump.
    The one thing that WOULD break it is walking a tree that was copied after the
    strip and dumping the copy's ancestor — there is no copy here.
    """
    targets = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
    for node in ast.walk(tree):
        if not isinstance(node, targets):
            continue
        body = node.body
        if body and isinstance(body[0], ast.Expr) and _is_str_expr(body[0].value):
            # A body that becomes EMPTY gets `pass`, not an empty list: a
            # docstring-only function body and an explicit `pass` are the same
            # program, so they must normalise the same way.
            node.body = body[1:] or [ast.Pass()]
    return tree


def _shebang(text):
    """The `#!` line when the file starts with one, else the empty string.

    Kept OUT of the AST deliberately: `ast` drops it as a comment, but it is
    executable content (it picks the interpreter and its flags), and the shell
    normaliser already preserves `#!` for exactly that reason (`is_shebang`).
    Both language paths must agree on this predicate or a shebang-only delta
    would be a false `identical` on one side of the extension split.
    """
    first = text.split("\n", 1)[0]
    return first if first.startswith("#!") else ""


def normalise_python(text, label):
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        refuse("%s does not parse as Python (%s) — refusing to treat it as identical" % (label, exc))
    dumped = ast.dump(_strip_docstrings(tree), annotate_fields=True, include_attributes=False)
    # The shebang takes part in the comparison (see the module docstring): a head
    # move that only swaps `#!/usr/bin/env python3` for `#!/usr/bin/env -S
    # python3 -OO` changes what the interpreter does, so it must NOT be carried
    # as "docstring/comment-only" (review of #4105, P2).
    return _shebang(text) + "\n" + dumped


def _line_scan(line):
    """Scan one shell line.

    Returns (state_at_eol, heredocs) where `heredocs` is a list of
    (terminator, strip_leading_tabs). `state_at_eol` is None when every quote on
    the line closed. Raises SystemExit(2) on anything this scanner cannot read
    confidently — an unterminated heredoc operator, or more than one heredoc on a
    line (the order the bodies appear in is not local to the line).
    """
    state = None
    heredocs = []
    arithmetic = 0
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if state is None:
            if ch == "\\":
                i += 2
                continue
            # ARITHMETIC CONTEXT (`$(( … ))` / bash's `(( … ))`), tracked so a
            # left shift is never read as a heredoc operator: `n=$(( 1 << 4 ))`
            # used to refuse as "unparseable heredoc operator", which made every
            # script containing a shift permanently un-normalisable. `((` is only
            # arithmetic at a token START, so an escaped/quoted `((` cannot open
            # the region, and the region cannot contain a real heredoc.
            if ch == "(" and line[i:i + 2] == "((" and (i == 0 or line[i - 1] in " \t;|&($"):
                arithmetic += 1
                i += 2
                continue
            if arithmetic and ch == ")" and line[i:i + 2] == "))":
                arithmetic -= 1
                i += 2
                continue
            if arithmetic and ch == "<" and line[i:i + 2] == "<<":
                i += 2          # a shift, not an operator with a delimiter
                continue
            if ch == "'":
                state = "single"
                i += 1
                continue
            if ch == '"':
                state = "double"
                i += 1
                continue
            if ch == "#" and (i == 0 or line[i - 1] in " \t;|&("):
                # A comment runs to end of line: nothing after it is code, so
                # heredoc operators inside it are not operators at all. ⛔ THE
                # POSITION TEST IS LOAD-BEARING, not tidiness: `#` is also a
                # parameter-length operator (`${#x}`) and appears inside words
                # (`a#b`), and a bare `break` there would stop scanning BEFORE a
                # real `<<EOF` later on the same line — the heredoc body would
                # then be treated as code and a `#` line inside it could be
                # stripped, which is the one false-identical this scanner exists
                # to prevent.
                break
            if ch == "<" and line[i:i + 3] == "<<<":
                i += 3          # here-string (`<<<`), NOT a heredoc
                continue
            if ch == "<" and line[i:i + 2] == "<<":
                match = _HEREDOC_RE.match(line, i)
                if not match:
                    refuse("unparseable heredoc operator")
                heredocs.append((match.group(3), match.group(1) == "-"))
                i = match.end()
                continue
            i += 1
            continue
        if state == "single":
            if ch == "'":
                state = None
            i += 1
            continue
        # state == "double"
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            state = None
        i += 1
        continue
    if len(heredocs) > 1:
        refuse("more than one heredoc operator on one line")
    return state, heredocs


def _ends_with_continuation(line):
    """True when the line's last character is an UNESCAPED backslash.

    POSIX.1-2017 XCU §2.2.1: "If a <newline> follows the <backslash>, the shell
    shall interpret this as line continuation. The <backslash> and <newline>
    shall be removed BEFORE splitting the input into tokens." Splice first, then
    tokenise — which is precisely the ordering that makes comment stripping
    unsafe across a continuation, and the reason `normalise_shell` refuses when
    a whole-line comment sits on either side of one.
    """
    n = 0
    i = len(line) - 1
    while i >= 0 and line[i] == "\\":
        n += 1
        i -= 1
    return n % 2 == 1          # an EVEN run is escaped backslashes, not a splice


def normalise_shell(text, label):
    out = []
    pending = []            # stack of (terminator, strip_leading_tabs)
    prev_continued = False  # did the previous CODE line splice onto this one?
    for lineno, line in enumerate(text.split("\n"), 1):
        if pending:
            # A heredoc body is DATA (or code for an interpreter) — a line that
            # begins with `#` inside it is not a comment. Emit verbatim.
            out.append(line)
            terminator, strip_tabs = pending[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == terminator:
                pending.pop(0)
            prev_continued = False
            continue
        if line.strip() == "":
            out.append(line)
            prev_continued = False
            continue
        state, heredocs = _line_scan(line)
        if state is not None:
            refuse("%s:%d ends inside a quoted string — refusing to strip comments confidently"
                   % (label, lineno))
        if heredocs:
            pending.extend(heredocs)
        stripped = line.strip()
        is_shebang = lineno == 1 and line.startswith("#!")
        continued = _ends_with_continuation(line)
        if stripped.startswith("#") and not is_shebang:
            # ⛔ A COMMENT ON EITHER SIDE OF A LINE CONTINUATION IS NOT A COMMENT
            # WE CAN DROP (see the module docstring). Both directions change the
            # program, and the pre-fix helper called them identical:
            #   * `prev_continued` — the `#` line was spliced onto the previous
            #     command, so it and what follows are part of that command;
            #   * `continued` — the comment itself swallows the NEXT physical
            #     line, which this loop would otherwise compare as code.
            if prev_continued:
                refuse("%s:%d is a comment line spliced onto the previous line by a "
                       "trailing backslash (the continuation is removed before "
                       "tokenising, so this is part of that command) — refusing "
                       "to strip comments confidently" % (label, lineno))
            if continued:
                refuse("%s:%d is a comment line that CONTINUES onto the next physical "
                       "line (trailing backslash), so the following line is comment "
                       "text — refusing to strip comments confidently" % (label, lineno))
            prev_continued = False
            continue            # whole-line comment: nothing to keep
        out.append(line)
        prev_continued = continued
    if pending:
        refuse("%s has an unterminated heredoc (expected %r) — refusing to strip comments"
               % (label, pending[0][0]))
    return "\n".join(out)


_NORMALISERS = {"python": normalise_python, "shell": normalise_shell}


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: code-identity.py <repo-relative-path> <file-a> <file-b>\n")
        return 2
    path, file_a, file_b = argv[1], argv[2], argv[3]
    text_a = read_text(file_a)
    text_b = read_text(file_b)
    lang_a = language_of(path, text_a)
    lang_b = language_of(path, text_b)
    # The language is a property of the PATH, so both sides must agree; a shebang
    # that appears or disappears between revisions is itself a content change we
    # will not paper over.
    if lang_a is None or lang_a != lang_b:
        refuse("no confident normaliser for %s — treating it as CHANGED" % path)
    normalise = _NORMALISERS[lang_a]
    norm_a = normalise(text_a, "%s a-side" % path)
    norm_b = normalise(text_b, "%s b-side" % path)
    return 0 if norm_a == norm_b else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as exc:                       # noqa: BLE001 — fail closed
        # An unexpected error must never read as "identical": the caller only
        # ever refuses on a non-zero status, so this stays on the safe side.
        sys.stderr.write("code-identity: unexpected failure on %s: %s\n" % (sys.argv[1:2], exc))
        sys.exit(2)
