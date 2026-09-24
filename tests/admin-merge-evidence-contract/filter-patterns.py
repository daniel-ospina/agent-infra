#!/usr/bin/env python3
"""Extract every regex the admin-merge clause filter hands to a regex function.

WHY THIS IS NOT A SOURCE-TEXT SCAN. An earlier version regexed the shell FILE for
`test("…")`. That is a proxy, and a verifier pass showed it can be defeated while the
production path breaks: `test((…))`, `test ( "…" )`, a pattern built with the file's own
shell splice (`test("abc'"$HEAD"'(?!x)")`), or a pattern held in a variable are all
skipped by a text scan — and the LIVE path then fails to compile the filter (gojq/RE2)
while the suite reports green. So this script takes the RUNTIME filter — the string the
verifier actually evaluates, after the shell has expanded it — and requires every regex
call argument to be a single JSON string literal. Anything else is reported as
`UNCHECKABLE` and the suite fails closed on it: a pattern it cannot decode is a pattern
it cannot clear.

That matters because the two paths run different engines:

  offline (`--body-file`, and every assertion in the suite): system `jq` — Oniguruma
  LIVE    (`gh pr view … --jq`, what the shim calls):     gh's embedded gojq — Go/RE2

RE2 is the weaker one, and a filter it rejects compiles offline and fails live, where the
failure presents as `could not read the PR comments` (exit 1) for EVERY certificate: the
fleet-wide refusal this lane exists to prevent, reachable with every offline test green.

Records, one per line:

  N <count>                      how many regex-call arguments were found
  P <json-string>                a DECODED pattern (jq's view, not the file's text)
  OFFENDER <reason> <pattern>    a construct RE2 rejects
  UNCHECKABLE <reason>           an argument that is not a single literal
"""
import json
import re
import sys

# RE2 rejects these; the offline engine (Oniguruma) accepts them. `\b`, `\s`, `\d`,
# `\w`, `\x{…}`, `\Q…\E` and POSIX classes are fine on BOTH and are not flagged.
FORBIDDEN = [
    (r"\(\?[=!<]", "lookaround"),
    (r"\(\?[>~#]", "atomic group / comment group / absent operator"),
    (r"\\[1-9]", "backreference"),
    (r"\\[KRZhHGXk]", "Oniguruma-only escape"),
    (r"\\C", "Oniguruma-only single-byte escape"),
    (r"\\g<", "Oniguruma-only named backreference"),
    (r"\\p\{In", "Oniguruma-only Unicode block property"),
    (r"(?:[*+?]|\{\d+(?:,\d*)?\})\+", "possessive quantifier"),
]
# `match`/`test`/`capture`/`scan`/`split`/`sub`/`gsub` all take a regex first argument.
REGEX_FUNCS = r"(?:test|match|capture|scan|split|splits|sub|gsub)"


def unescaped_backslashes_ok(pat: str, letters: str) -> bool:
    """True when `pat` contains an ODD-length run of backslashes before one of `letters`.

    `\\\\K` (a regex for a literal backslash followed by `K`) must NOT be flagged: the
    backslash that matters is the ESCAPING one, and counting only the last backslash
    flagged a legitimate pattern. Walk each run and test parity instead.
    """
    i = 0
    while i < len(pat):
        if pat[i] == "\\":
            run = 0
            while i < len(pat) and pat[i] == "\\":
                run += 1
                i += 1
            if i < len(pat) and pat[i] in letters and run % 2 == 1:
                return True
        else:
            i += 1
    return False


def unescaped_escape(pat: str, letters: str) -> bool:
    """True when `letters` appears as an escape (`\\K`) rather than a literal (`\\\\K`)."""
    return unescaped_backslashes_ok(pat, letters)


def check(pat: str):
    for rx, reason in FORBIDDEN:
        if rx == r"\\[KRZhHGXk]":
            if unescaped_escape(pat, "KRZhHGXk"):
                return reason
            continue
        if re.search(rx, pat):
            return reason
    return None


def extract_arg(text: str, open_paren: int):
    """Return (literal_or_None, reason). The argument must be one JSON string."""
    i = open_paren + 1
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i >= len(text):
        return None, "a regex call with an empty argument list"
    if text[i] != '"':
        head = text[i : i + 20].replace("\n", " ")
        return None, f"a regex argument that is not a string literal ({head!r})"
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == '"':
            break
        j += 1
    if j >= len(text):
        return None, "an unterminated regex argument"
    raw = text[i : j + 1]
    try:
        return json.loads(raw), None
    except json.JSONDecodeError as exc:
        return None, f"an undecodable regex argument ({exc.msg})"


def main() -> int:
    text = open(sys.argv[1], encoding="utf-8").read()
    count = 0
    offenders = []
    uncheckable = []
    for m in re.finditer(REGEX_FUNCS + r"[ \t]*\(", text):
        open_paren = m.end() - 1
        value, reason = extract_arg(text, open_paren)
        if value is None:
            uncheckable.append(reason)
            continue
        count += 1
        print("P " + json.dumps(value))
        hit = check(value)
        if hit:
            offenders.append(f"{hit} {value[:120]}")
    print(f"N {count}")
    for off in offenders:
        print("OFFENDER " + off)
    for bad in uncheckable:
        print("UNCHECKABLE " + bad)
    return 0


if __name__ == "__main__":
    sys.exit(main())
