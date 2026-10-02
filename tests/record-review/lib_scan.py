"""Shared text scanner for the record-review suite.

`executable_text()` was previously defined inside the `bare_gh_count` heredoc. It is
promoted here so the qualification guard can use the SAME blanker instead of a second,
weaker lexer — a hand-rolled second copy is how this suite has three times produced a
guard that was blind to a case the original handled.
"""

import re


def executable_text(s):
    """A BEST-EFFORT text scan, NOT a shell parser. It is a REGRESSION TRIPWIRE, not a
    proof, and the SELF-TEST is its specification: the spellings it must count, and the
    non-invocations it must ignore, are the ones pinned there.

    Every absolute claim this docstring used to make — that it blanks exactly the text
    the shell does not execute, that comments are always cut, that only an unquoted `)`
    closes a substitution — was FALSIFIED by a reviewer with the shell as the oracle, so
    the claims are DELETED rather than reworded. It OVER-counts some non-invocations
    (loud, hence fail-closed) and some unusual spelling can still make it UNDER-count;
    anything it reports is confirmed by reading the line.

    What it is FOR: the head read is spelled HEAD="$(command gh api ...)", inside double
    quotes. A version that blanked quoted tokens wholesale reported 0 there while
    `command ` had been deleted from exactly that line. `$( ... )` and backticks are
    therefore kept inside double quotes, because they ARE executed."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "#" and (i == 0 or s[i - 1] in " \t\n"):
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            if j == -1:
                j = n - 1
            out.append("'gh'" if s[i:j + 1] == "'gh'" else " " * (j + 1 - i))
            i = j + 1
            continue
        if c == '"':
            parts, k = ['"'], i + 1
            while k < n:
                if s[k] == "\\" and k + 1 < n:
                    parts.append("  ")
                    k += 2
                    continue
                if s[k] == '"':
                    break
                if s.startswith("$(", k):
                    # QUOTE-AWARE. A reviewer measured `X="$(echo 'a)b'; gh api q)"`
                    # counting 0: the `)` inside the quoted run closed the substitution
                    # early, and the real `gh` after it was blanked as inert text while
                    # bash executed it. Skip quoted runs so only an unquoted `)` closes.
                    k0, depth, k, qq = k, 0, k + 2, None
                    while k < n:
                        ch = s[k]
                        # A BACKSLASH escapes the next char even OUTSIDE quotes, so `\)`
                        # does not close the substitution. Without this branch the scan
                        # closed early and blanked the real `gh` after it — the reviewer
                        # reintroduced a bare gh into the real file and the suite stayed
                        # GREEN. (Inside SINGLE quotes a backslash is literal, so the
                        # escape branch is skipped there.)
                        if ch == "\\" and qq != "'":
                            k += 2
                            continue
                        if qq is not None:
                            if ch == "\\" and qq == '"':
                                k += 2
                                continue
                            if ch == qq:
                                qq = None
                            k += 1
                            continue
                        if ch in ("'", '"'):
                            qq = ch
                            k += 1
                            continue
                        if ch == "(":
                            depth += 1
                        elif ch == ")":
                            if depth == 0:
                                break
                            depth -= 1
                        k += 1
                    parts.append(s[k0:k + 1])
                    k += 1
                    continue
                if s[k] == "`":
                    k2 = s.find("`", k + 1)
                    if k2 == -1:
                        k2 = n - 1
                    parts.append(s[k:k2 + 1])
                    k = k2 + 1
                    continue
                parts.append(s[k] if s[k] == "$" else " ")
                k += 1
            out.append('"gh"' if s[i:k + 1] == '"gh"' else "".join(parts) + '"')
            i = k + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def unqualified_invocations(src, name):
    """Count invocations of `name` in COMMAND POSITION that are not `command`-qualified.

    Command position = start of a line, or just after `|`, `&`, `;`, `(`, or a `$(` (which
    is normalised to `|` so `X="$(head -1)"` is seen, while `$head` — a VARIABLE read — is
    not). Matching the NAME rather than a literal also catches equivalent spellings
    (`head -n1`, `tail --lines=+2`), which a literal match missed entirely.

    Cannot see: a dynamically constructed invocation (`eval`, a variable holding the
    command word), and a function named `command`. Both are recorded as out of reach in
    the script's declared-boundary note; this is a tripwire on a REVERT, not a proof.
    """
    code = executable_text(src).replace("$(", "|")
    rx = re.compile(r"(?:^|[|&;(])\s*" + re.escape(name) + r"(?=[\s;|&)<>]|$)", re.MULTILINE)
    return len(rx.findall(code))
