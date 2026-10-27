#!/usr/bin/env python3
"""diff-normalize.py — THE single implementation of the review-evidence diff
normalization (agent-infra #1362, unit D1; owner ruling 2026-09-23, amended
2026-09-23 by the issue's "AMENDMENT to the 2026-09-23 ruling" comment).

Reads the raw bytes of a GitHub `application/vnd.github.v3.diff` response on
stdin and writes the NORMALIZED bytes on stdout. The review-evidence digest is
`sha256` over the normalized bytes, so a base-only update (a rebase, or
`gh pr update-branch`) that rewrites only *derived rendering* cannot manufacture
a fresh review obligation.

CONTRACT (amended rule): **drop the `index` line exactly when the hunk content
already carries the change.** The judgement is made ENTRY-SCOPED, because a
binary entry has NO hunk and its `index` line is therefore its only
content-bearing field.

Entry boundaries are lines matching::

    ^diff --git

Process each entry independently; within an entry:

  1. If the entry contains at least one hunk line (`^@@ `) — the change is
     carried by hunk content — DROP every line matching::

         ^index [0-9a-f]+\\.[0-9a-f]+( [0-7]{6})?$

     (git's `index <old>..<new> <mode>` line. The mode group is absent when the
     mode changed, because then `old mode` / `new mode` lines are emitted.)

  2. If the entry contains NO hunk line — a binary marker (`^Binary files .*
     differ$` / `^GIT binary patch$`), or a hunk-less empty-file add/delete —
     KEEP the `index` line VERBATIM, with no reformatting. The `index` line is
     the entry's ONLY content-bearing field there, so dropping it would make two
     entirely different binaries normalize to the SAME digest: a fail-open in a
     required merge gate (review binary v1, sign the marker, swap in binary v2,
     and the digest no longer moves).

     The predicate is HUNK PRESENCE, never binary-marker presence: an empty-file
     add/delete (`index e69de29..0000000`) carries no marker and must still keep
     its `index` line. This mirrors `git patch-id`, which hashes the blob-OID
     strings parsed from the `index` line for a binary entry and ignores the
     line entirely for a text entry.

  3. REWRITE a hunk header matching::

         ^@@ -([0-9]+)(,([0-9]+))? \\+([0-9]+)(,([0-9]+))? @@(.*)$

     to ``@@ -0,<B> +0,<D> @@<REST>`` where <B> is the old line count (group 3)
     and <D> the new line count (group 6), each DEFAULTING TO 1 when its count
     group is absent (`@@ -5 +5 @@` means one line each, per the unified-diff
     format), and <REST> is group 7 verbatim — the optional section heading.

  4. Every other line is emitted unchanged.

The `index` abbreviation width is NOT truncated or canonicalized. It is a
repository property, not a content property (measured 9 hex here, 13 hex at
`microsoft/vscode` scale), so truncating to a canonical width would trade a rare
fail-closed for a sub-40-bit fail-open. Recorded residual, not an oversight.

Explicitly NOT normalized: hunk CONTENT, hunk COUNTS, the
`diff --git` / `---` / `+++` / mode / rename / binary lines, and the hunk
section heading. Counts are derived from content, so they move only when
content moves.

WHY sha256 AND NOT `git patch-id`: `--stable` and the default both IGNORE
whitespace (a false ACCEPT — a whitespace-only edit would carry a verdict it
does not deserve), and a SHA-1 sum is weaker than a sha256. `--verbatim` closes
the whitespace hole but not the primitive's weakness. Normalizing keeps sha256,
keeps whitespace-sensitivity, and adds no dependency.

=== `--patch-only`: THE PATCH PROJECTION (agent-infra #1377) ===

The DEFAULT mode above is the EVIDENCE BINDING: its sha256 is what a signed
marker carries as `diff=`, and the cross-repo consumer (tortoise's
`.github/workflows/ai-review-gate.yml`) verifies it. Do not change what it
emits.

`--patch-only` is a SECOND PROJECTION of the same bytes, used for a different
question: *is the change a reviewer approved still the change in this branch?*
It drops exactly three fields, all of which a REBASE rewrites even when the
reviewed change is untouched — and keeps everything else verbatim:

  * `index <old>..<new>` lines (blob ids are rewritten by every rebase);
  * `@@ … @@` hunk headers (line numbers move);
  * hunk CONTEXT lines (a leading single space) — the lines AROUND the change,
    which move whenever the base lands work in the same file. This is the field
    the default mode deliberately keeps, and the one that made a rebase onto a
    moved base look like a changed artifact (agent-infra #1377).

KEPT, verbatim and in order: the `diff --git` / `---` / `+++` lines (so the PATCH
IDENTITY includes the PATH, which `git patch-id` does not commit to), every
mode / rename / copy / similarity line, every `+`/`-` line (BYTE-EXACT,
including whitespace), and `\\ No newline at end of file` markers. An entry with
NO hunk is emitted whole — for a binary or hunk-less entry the `index` line is
the content (the 2026-09-23 amendment), so dropping anything there would make
two different binaries project identically.

WHY A PROJECTION AND NOT `git patch-id --stable`: `--stable` "ignores all
whitespace within the patch" (git-patch-id(1)), which is the false-ACCEPT
#1362's decision (D1) rejected — a whitespace-only edit would project
identically to its parent and carry a verdict it does not deserve. `--verbatim`
closes that hole but stays SHA-1 and ignores paths. This projection keeps
sha256, keeps whitespace byte-exact, keeps paths, and adds no dependency — so it
carries BOTH objections of #1362 D1 forward rather than reversing them.

It is NOT a second definition of "the reviewed artifact": a patch-match is only
ever consulted AFTER the evidence binding has been reconstructed and verified
against the marker's own `diff=` (see `patch_dimension_carry` in
record-review.sh). A patch match can never mint a marker on its own.

WHY THIS IS A CROSS-REPO CONTRACT: the consumer (`tortoise`
`.github/workflows/ai-review-gate.yml`) verifies the same digest. If the two
sides normalize differently, one produces a digest the other cannot verify and
every freshly-signed marker stops matching fleet-wide (the #3076 shape). The
amendment above was adopted on the ruling's own home issue precisely so both
halves change together.

Line splitting is `str.split("\\n")` and re-joining with `"\\n"`, over the
bytes decoded 1:1 (latin-1) — so the final line is preserved EXACTLY, including
the presence or absence of a trailing newline, and non-ASCII bytes round-trip
byte-for-byte (the regexes are ASCII-only and cannot match them).
"""

from __future__ import annotations

import re
import sys

_ENTRY_RE = re.compile(r"^diff --git ")
_INDEX_RE = re.compile(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$")
_HUNK_RE = re.compile(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$")


def _patch_only_entry(entry: list[str]) -> list[str]:
    """Project ONE diff entry onto its PATCH identity (`--patch-only`)."""
    # Same predicate shape as the binding: hunk PRESENCE decides. With no hunk
    # the entry is all content (binary / empty-file add-delete), so it is
    # emitted whole — including its `index` line, which is then the only thing
    # that distinguishes two different binaries.
    if not any(line.startswith("@@ ") for line in entry):
        return list(entry)
    out = []
    for line in entry:
        if _INDEX_RE.match(line):
            continue              # blob ids are rewritten by every rebase
        if _HUNK_RE.match(line):
            continue              # line numbers move; the counts derive from content
        if line.startswith(" "):
            # CONTEXT. The only field here that a BASE MOVE rewrites without the
            # reviewed change moving — dropped for the patch identity alone.
            continue
        out.append(line)
    return out


def _normalize_entry(entry: list[str]) -> list[str]:
    """Normalize ONE diff entry (its lines, `diff --git` line included)."""
    # Hunk presence is decided over the WHOLE entry before any line is emitted,
    # because the `index` line precedes the first hunk in the entry. `^@@ ` is
    # the predicate the amendment names; a hunk-body line is prefixed with
    # ` `/`+`/`-`, and a `GIT binary patch` data line is length-prefixed with a
    # letter, so neither can satisfy it.
    has_hunk = any(line.startswith("@@ ") for line in entry)
    out = []
    for line in entry:
        if _INDEX_RE.match(line):
            if has_hunk:
                # The hunk content already carries the change — derived
                # rendering only.
                continue
            # No hunk to carry it: this is the entry's only content-bearing
            # field. Keep it VERBATIM.
            out.append(line)
            continue
        m = _HUNK_RE.match(line)
        if m is not None:
            old_count = m.group(3) if m.group(3) is not None else "1"
            new_count = m.group(6) if m.group(6) is not None else "1"
            line = f"@@ -0,{old_count} +0,{new_count} @@{m.group(7)}"
        out.append(line)
    return out


def _project(raw: bytes, entry_projector) -> bytes:
    """Split on entry boundaries and project each entry with `entry_projector`."""
    lines = raw.decode("latin-1").split("\n")
    # Entry boundaries at every `^diff --git ` line; `len(lines)` terminates the
    # LAST entry. Lines before the first boundary form a leading segment (a real
    # diff has none) and are processed by the same rule, so the function is
    # total and deterministic on any byte stream.
    bounds = [i for i, line in enumerate(lines) if _ENTRY_RE.match(line)]
    bounds.append(len(lines))
    out: list[str] = []
    start = 0
    for end in bounds:
        out.extend(entry_projector(lines[start:end]))
        start = end
    return "\n".join(out).encode("latin-1")


def normalize_diff(raw: bytes) -> bytes:
    """Return the normalized rendering of a raw unified-diff byte stream."""
    return _project(raw, _normalize_entry)


def patch_only_diff(raw: bytes) -> bytes:
    """Return the PATCH-identity projection of a raw unified-diff byte stream."""
    return _project(raw, _patch_only_entry)


def main(argv: list[str]) -> int:
    # Default (no flag) is the BINDING projection — the cross-repo contract. The
    # flag is additive and never changes the default output.
    if argv:
        if argv == ["--patch-only"]:
            out = patch_only_diff(sys.stdin.buffer.read())
        else:
            sys.stderr.write(
                "diff-normalize.py: unknown argument(s) %r — the only accepted form "
                "is no argument (the evidence BINDING projection) or --patch-only "
                "(the PATCH identity projection). Refusing rather than silently "
                "emitting the wrong projection: a caller that asked for one and got "
                "the other would compare unlike digests.\n" % (argv,)
            )
            return 2
    else:
        out = normalize_diff(sys.stdin.buffer.read())
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
