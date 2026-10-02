"""Shared text scanner for the record-review suite.

`executable_text()` was previously defined inside the `bare_gh_count` heredoc. It is
promoted here so the qualification guard can use the SAME blanker instead of a second,
weaker lexer — a hand-rolled second copy is how this suite has repeatedly produced a guard
blind to a case the original handled.

`unqualified_invocations()` is a TRIPWIRE ON A REVERT, and its scope is stated here rather
than left to inference, because FOUR successive designs of it were measured unsound and the
honest thing is to name the limit instead of widening it a fifth time:

  * It matches the command word through `^`, `|`, `&`, `;`, `(` and a normalised `$(`. A
    reviewer MEASURED that this is not the shell's command-position grammar: `\\tail`, a
    continuation right after the name, `tail""`, `{ tail ...; }`, `case x in x) tail`,
    `then`/`do`/`else`, a backtick substitution, a quoted command word, `v=1 tail`, and
    `! tail` are ALL executed by bash and NONE is counted. That list is given as a WARNING,
    not as an inventory: it is the shape of the gap, and there is no reason to think it is
    complete. NO enumeration of it is attempted below.
  * It over-counts: a heredoc BODY, an array element and a `case` pattern are reported as
    invocations. (Loud, hence fail-closed.)

Therefore it does NOT establish "no unqualified invocation exists", and no text scan can:
the property is about the shell's grammar, which is not a regular language. What it does
establish is the regression this lane actually pays for — a `command ` prefix DELETED from
one of the spellings the script uses today, which is how this vector was reintroduced
before. A rewrite of the command word is a different act, and the guard does not see it.
Anything it reports is confirmed by READING THE LINE, which is why the failure text says so.
"""

import re


def executable_text(s):  # noqa: D103 (docstring is the module header above)
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
                    k0, depth, k, qq = k, 0, k + 2, None
                    while k < n:
                        ch = s[k]
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
    """Count sightings of `name` in command position that are not `command`-qualified.

    See the module header: this is a REVERT tripwire, it over-counts non-invocations, and
    it is blind to every rewrite of the command word that reaches it through a construct
    outside `^ | & ; ( $(`. It does not prove the absence of an unqualified invocation.
    """
    code = executable_text(src).replace("$(", "|")
    rx = re.compile(r"(?:^|[|&;(])\s*" + re.escape(name) + r"(?=[\s;|&)<>]|$)", re.MULTILINE)
    return len(rx.findall(code))
