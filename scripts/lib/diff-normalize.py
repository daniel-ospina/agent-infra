#!/usr/bin/env python3
"""diff-normalize.py — THE single implementation of the review-evidence diff
normalization (agent-infra #1362, unit D1; owner ruling 2026-09-23).

Reads the raw bytes of a GitHub `application/vnd.github.v3.diff` response on
stdin and writes the NORMALIZED bytes on stdout. The review-evidence digest is
`sha256` over the normalized bytes, so a base-only update (a rebase, or
`gh pr update-branch`) that rewrites only *derived rendering* cannot manufacture
a fresh review obligation.

Normalization (drop / rewrite; every other line passes through UNCHANGED):

  1. DROP a line matching::

         ^index [0-9a-f]+\\.[0-9a-f]+( [0-7]{6})?$

     (git's `index <old>..<new> <mode>` line. The mode group is absent when the
     mode changed, because then `old mode` / `new mode` lines are emitted.)

  2. REWRITE a line matching::

         ^@@ -([0-9]+)(,([0-9]+))? \\+([0-9]+)(,([0-9]+))? @@(.*)$

     to ``@@ -0,<B> +0,<D> @@<REST>`` where <B> is the old line count (group 3)
     and <D> the new line count (group 6), each DEFAULTING TO 1 when its count
     group is absent (`@@ -5 +5 @@` means one line each, per the unified-diff
     format), and <REST> is group 7 verbatim — the optional section heading.

  3. Every other line is emitted unchanged.

Explicitly NOT normalized: hunk CONTENT, hunk COUNTS, the
`diff --git` / `---` / `+++` / mode / rename / binary lines, and the hunk
section heading. Counts are derived from content, so they move only when
content moves.

WHY sha256 AND NOT `git patch-id`: `--stable` and the default both IGNORE
whitespace (a false ACCEPT — a whitespace-only edit would carry a verdict it
does not deserve), and a SHA-1 sum is weaker than a sha256. `--verbatim` closes
the whitespace hole but not the primitive's weakness. Normalizing keeps sha256,
keeps whitespace-sensitivity, and adds no dependency.

WHY THIS IS A CROSS-REPO CONTRACT: the consumer (`tortoise`
`.github/workflows/ai-review-gate.yml`) verifies the same digest. If the two
sides normalize differently, one produces a digest the other cannot verify and
every freshly-signed marker stops matching fleet-wide (the #3076 shape).

Line splitting is `str.split("\\n")` and re-joining with `"\\n"`, over the
bytes decoded 1:1 (latin-1) — so the final line is preserved EXACTLY, including
the presence or absence of a trailing newline, and non-ASCII bytes round-trip
byte-for-byte (the regexes are ASCII-only and cannot match them).
"""

from __future__ import annotations

import re
import sys

_INDEX_RE = re.compile(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$")
_HUNK_RE = re.compile(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$")


def normalize_diff(raw: bytes) -> bytes:
    """Return the normalized rendering of a raw unified-diff byte stream."""
    out = []
    for line in raw.decode("latin-1").split("\n"):
        if _INDEX_RE.match(line):
            continue
        m = _HUNK_RE.match(line)
        if m is not None:
            old_count = m.group(3) if m.group(3) is not None else "1"
            new_count = m.group(6) if m.group(6) is not None else "1"
            line = f"@@ -0,{old_count} +0,{new_count} @@{m.group(7)}"
        out.append(line)
    return "\n".join(out).encode("latin-1")


def main() -> int:
    sys.stdout.buffer.write(normalize_diff(sys.stdin.buffer.read()))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
