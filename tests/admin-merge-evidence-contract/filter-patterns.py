#!/usr/bin/env python3
"""Extract the regex patterns the admin-merge clause filter hands to `test("…")`.

The LIVE path runs this filter through `gh … --jq` — gh's embedded gojq over
Go/RE2 — while the offline path (`--body-file`) runs the same string through the
system `jq` (Oniguruma). The two engines differ, and RE2 is the weaker one:

  * no lookaround (`(?=`, `(?!`, `(?<=`, `(?<!`) and no backreferences (`\1`);
  * no Oniguruma-only escapes: `\\K`, `\\R`, `\\Z`, `\\h`, `\\G`, `\\X`, `\\g<…>`.

A filter that uses any of them compiles offline and FAILS to compile live, where the
failure surfaces as `could not read the PR comments` (exit 1) for every certificate —
the six-day outage class, with every offline assertion green. That is why this script
exists: it reports the patterns as jq sees them, and flags the ones RE2 cannot take.

Printed, one record per line:

  N <count>                      how many `test("…")` patterns were found
  P <json-string>                the DECODED pattern (jq's view, not the file's text)
  OFFENDER <reason> <pattern>    a pattern the live engine would reject

Decoding matters: the file holds a jq STRING LITERAL, so a regex `\K` is written
`\\K`. Re-embedding the raw file text (`\\K`) makes jq parse a different regex
(`\K` becomes `\\K`, an escaped backslash), so a check built on the raw text compiles
patterns the filter never uses — a false PASS of exactly this outage class. Hence the
one decode below, through `json.loads`.
"""
import json
import re
import sys

# RE2 rejects these; the offline engine (Oniguruma) accepts them. `\b`, `\s`, `\d`,
# `\w`, `\x{…}` and POSIX classes are FINE on both and must not be flagged.
FORBIDDEN = [
    (r"\(\?[=!<]", "lookaround"),
    (r"\\[1-9]", "backreference"),
    (r"\\[KRZhGXk]", "Oniguruma-only escape"),
    (r"\\g<", "Oniguruma-only named backreference"),
]


def main() -> int:
    text = open(sys.argv[1], encoding="utf-8").read()
    try:
        start = text.index("CLAUSE_FILTER=")
        end = text.index("jq_program=", start)
    except ValueError:
        print("N 0")
        return 0
    # The assignment is a shell string that splices its own quoting for the head-bound
    # literals (`'"$HEAD"'` and an apostrophe splice); normalise the apostrophe splice
    # so a pattern containing `main's` stays one `test("…")` argument.
    seg = text[start:end].replace("'\"'\"'", "'")
    patterns = []
    for m in re.finditer(r'test\("([^"]*)"', seg):
        raw = m.group(1)
        try:
            # ONE decode: file text -> the jq string jq itself would build.
            patterns.append(json.loads('"' + raw + '"'))
        except json.JSONDecodeError:
            patterns.append(raw)
    print(f"N {len(patterns)}")
    for pat in patterns:
        print("P " + json.dumps(pat))
    for pat in patterns:
        for rx, reason in FORBIDDEN:
            if re.search(rx, pat):
                print(f"OFFENDER {reason} {pat[:120]}")
                break
    return 0


if __name__ == "__main__":
    sys.exit(main())
