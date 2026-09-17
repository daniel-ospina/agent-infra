#!/usr/bin/env python3
"""ci_exemption.py — THE canonical FAILED-id parser (#3756, rail extractor).

This module holds the ONE definition of "is this a test id" and the ONE rule for
reading the ``FAILED <token>`` position out of a raw ``gh run view --log-failed``
capture. Everything that needs to know which failures a run reported goes
through it, so the shell rail and the decision can never disagree about the id
universe.

Two defects motivated it (the rail-extractor PR carries defect 1 and the
identity-motion rule for defect 2; the rate/signature/decision engine lives in
``#3756``/PR #1147 and is built ON TOP of this parser — never beside it):

* **DEFECT 1 — an unparseable token must not become a failure id.** The shell
  rail used to print whatever token followed a bare ``FAILED`` field, so English
  prose (``may``) entered the failure set as if it were a nodeid. A garbage id
  matches nothing on main: it can never be subtracted or verified, so it reads as
  "unique to this PR" on EVERY rail run for EVERY PR whose log contains that
  fragment — a permanent false refusal. A candidate that is not a test id is
  **DROPPED, COUNTED and REPORTED** as UNATTRIBUTABLE, never carried, never read
  as "no failures".
* **DEFECT 2 — a MOVING identity is not an attribution.** Within one concluded
  cycle the same head's failure ids can shift across the re-run boundary (one id
  replaced by another). :func:`detect_rotating_identity` names the class that was
  red across runs with a NON-CONSTANT id, so a decision sees UNATTRIBUTABLE
  rather than a PR-unique failure (or a silent exemption) it cannot justify.

Pure functions only: no I/O, no network, no git — except :func:`_read` and the
``ids`` CLI, which read the caller's own capture file.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Strict parsing — the failure set is evidence, so junk must not enter it
# --------------------------------------------------------------------------

# An ANSI SGR/CSI escape — the shell rail strips these, so the parser must too
# or the two disagree on what a line says.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# ``<job>\t<step>\t\ufeff<ISO-8601>Z <content>`` — the gh ``--log-failed`` prefix.
# ``.*`` is greedy up to the LAST tab before the timestamp so a tab inside a job
# or step name cannot break the strip; a tab inside pytest CONTENT followed by a
# timestamp-shaped token would, which is vanishingly unlikely and fails closed
# (the content would not parse, so the id is unsigned).
_LOG_PREFIX_RE = re.compile(
    r"^.*\t\ufeff?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z[ \t]"
)

# A LOOSE nodeid: the file/class part stays strict, the ``::`` tail is allowed
# to carry spaces/brackets because pytest parameter ids legitimately do
# (``::test_x[chromium-Claude Desktop]``). Dropping a real id here would be
# fail-OPEN (an undecided id is an unblocked id), which is why this path is
# deliberately the permissive one.
_NODEID_LOOSE_RE = re.compile(r"^[A-Za-z0-9_./\-]+\.py::[^\t]+$")

#: The tokens that open a failure record. One list, so the shell can never
#: disagree with the module about which lines are records at all.
_FAILED_FIELDS = ("FAILED", "ERROR")


def _failed_candidate(line: str) -> str | None:
    """The token following the FIRST ``FAILED``/``ERROR`` whitespace field.

    This is the exact position the retired shell ``awk`` read
    (``if ($i == "FAILED") { print $(i+1) }``), so no real id is lost by
    routing through this module. The return is deliberately three-valued:

    * ``None`` — no such field on the line: it is NOT a failure record (raw logs
      are mostly prose), and it is NOT a rejection either;
    * ``''``  — the field was the last token: a truncated record, which IS a
      rejection;
    * ``<token>`` — the candidate, which the caller MUST shape-check before use.
    """
    fields = line.split()
    for index, token in enumerate(fields):
        if token in _FAILED_FIELDS:
            return fields[index + 1] if index + 1 < len(fields) else ""
    return None


@dataclass
class ParseResult:
    """Parsed failure ids plus the candidates that were REJECTED, and why.

    ``rejected`` is not diagnostics — it is evidence. A non-zero count means the
    set was filtered, and the reader is entitled to see it rather than take a
    silently-trimmed set on trust.
    """

    ids: list[str] = field(default_factory=list)
    rejected: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """False when the input yielded NO usable id at all.

        Fail-closed: an unreadable failure set must never present as an empty one.
        """
        return bool(self.ids)


def parse_failed_ids(lines: str, *, raw_log: bool = False) -> ParseResult:
    """Extract test ids from failure records — THE canonical id parser.

    Two input shapes, ONE candidate rule (:func:`_failed_candidate`) and ONE
    definition of "is this a test id" (``_NODEID_LOOSE_RE``), so the shell cannot
    keep a second, weaker notion of a failure id:

    * ``raw_log=False`` (default) — a file of ``FAILED <nodeid>`` / ``ERROR
      <nodeid>`` records. A non-blank line that carries no ``FAILED``/``ERROR``
      field is **rejected**: in an id file, prose IS a defect (nothing else
      belongs there).
    * ``raw_log=True`` — a raw ``gh run view --log-failed`` capture. ANSI SGR
      escapes and the ``<job>\\t<step>\\t<ts>Z `` prefix are stripped, then the
      candidate after the first ``FAILED``/``ERROR`` field is shape-checked. A
      line with no such field is not a failure record and is skipped — a raw log
      is mostly prose, and rejecting every prose line would drown the signal.

    In BOTH shapes a candidate that is not a test id is **DROPPED, COUNTED and
    REPORTED** (``rejected``) and never enters ``ids``. This is the #3756 ``may``
    leak: an English word in the candidate position used to be emitted verbatim
    as a failure id, and a garbage id matches nothing on main — it cannot be
    subtracted or verified, so it reads as "unique to this PR" on EVERY rail run
    for EVERY PR whose log contains that fragment. A permanent false refusal.

    This is the fail-closed rule: unknown resolves to *"not exempt"*, never to
    *"exempt"*. Silent permissiveness here is a zero-evidence pass — and a
    silently-CARRIED token is the permanent false refusal above.
    """
    ids: list[str] = []
    rejected: list[str] = []
    for raw in lines.splitlines():
        if raw_log:
            line = _strip_log_prefix(_ANSI_RE.sub("", raw)).strip()
            if not line:
                continue
            candidate = _failed_candidate(line)
            if candidate is None:
                # Not a failure record. Skipped, NOT rejected.
                continue
            unit = candidate
        else:
            line = raw.strip()
            if not line:
                continue
            candidate = _failed_candidate(line)
            if candidate is None:
                rejected.append(line)
                continue
            unit = line
        if not _NODEID_LOOSE_RE.match(candidate):
            # The unit reported is the offending TOKEN in log mode (the line may
            # be a whole megabyte of prose prefixed by a stray `FAILED`), and the
            # offending LINE in id-file mode (where the line IS the record).
            rejected.append(unit)
            continue
        ids.append(candidate)
    return ParseResult(ids=sorted(set(ids)), rejected=rejected)


# --------------------------------------------------------------------------
# The identity-motion rule — a MOVED identity is not an attribution
# --------------------------------------------------------------------------


def _strip_log_prefix(line: str) -> str:
    """Remove the gh ``--log-failed`` ``<job>\\t<step>\\t<ts>Z `` prefix, if present."""
    return _LOG_PREFIX_RE.sub("", line, count=1)


def class_key(nodeid: str) -> str:
    """The FILE/CLASS prefix — the unit that stays red while the IDENTITY moves."""
    parts = nodeid.split("::")
    return "::".join(parts[:2]) if len(parts) >= 2 else parts[0]


def detect_rotating_identity(runs: list[frozenset[str]]) -> dict[str, frozenset[str]]:
    """Keys whose failing IDENTITY changed between runs (required class E5).

    **An identity that changes across runs is NOT novel.** The baseline observed
    the CLASS; the id provably will not be the same next run. Measured on a real
    refusal (B6 on #3577): the rail reported ONE unique failure in a class that
    was red in three runs with THREE DIFFERENT ids inside it — run 1 two ids,
    runs 2-3 another. The class stayed red; the identity moved.

    The old re-run heuristic assumes a flake **passes** on retry and has no
    representation for "the failure moved", so the verdict became a function of
    which run you happened to sample. Both directions are in-surface:

    * **false-block** — a changed id is labelled "a NEW failure this PR
      introduces";
    * **false-PASS** — PR-minus-main compares SETS OF IDS from different samples,
      so an order-dependent flake can move OUT of the PR's set and INTO main's
      between runs and be exempted silently.

    Returns ``{class_key: union of ids seen red in that key}`` for every key that
    was red in >= 2 runs with a NON-CONSTANT id set. A class red in a single run
    is not reported (one sample cannot distinguish "moved" from "not yet moved").
    """
    per_key: dict[str, list[frozenset[str]]] = {}
    for r in runs:
        keys = {class_key(n) for n in r}
        for k in keys:
            per_key.setdefault(k, []).append(frozenset(n for n in r if class_key(n) == k))
    out: dict[str, frozenset[str]] = {}
    for k, sets in per_key.items():
        if len(sets) >= 2 and len({frozenset(x) for x in sets}) > 1:
            out[k] = frozenset().union(*sets)
    return out


# --------------------------------------------------------------------------
# The CLI door — `ids --log <capture>`
# --------------------------------------------------------------------------


def _read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


def _cmd_ids(args: argparse.Namespace) -> int:
    """`ids --log <capture>` — the canonical FAILED-id extraction (the shell's door).

    stdout: the test ids, sorted and unique, one per line (possibly empty).
    stderr: every rejected candidate, tagged UNATTRIBUTABLE, plus counts.

    Exits 0 whenever the capture was READ — an empty id set is a legitimate
    answer (the caller's `examined > extracted` gate owns "a failing run that
    yielded nothing"). A non-zero exit therefore means exactly one thing: the
    input could not be read. Reading that as "no failures" is the vacuous pass.
    """
    parsed = parse_failed_ids(_read(args.log), raw_log=True)
    for nodeid in parsed.ids:
        print(nodeid)
    for token in parsed.rejected:
        print(
            "ci-exemption: UNATTRIBUTABLE: FAILED token is not a test id and was "
            f"DROPPED (never in the failure set): {token}",
            file=sys.stderr,
        )
    print(
        f"ci-exemption: ids={len(parsed.ids)} "
        f"unattributable={len(parsed.rejected)}",
        file=sys.stderr,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    """``python3 ci_exemption.py <ids> …`` — the shell rail's door."""
    parser = argparse.ArgumentParser(
        prog="python3 ci_exemption.py",
        description=(
            "THE canonical FAILED-id parser (#3756): the id universe the rail and "
            "the exemption decision both read."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    ids = sub.add_parser(
        "ids",
        help="THE canonical FAILED-id extraction from a raw `gh run view --log-failed` capture",
    )
    ids.add_argument("--log", required=True, help="raw --log-failed file")
    ids.set_defaults(func=_cmd_ids)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":  # pragma: no cover — exercised via main() in tests
    raise SystemExit(main())
