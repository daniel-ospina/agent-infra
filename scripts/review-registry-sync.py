#!/usr/bin/env python3
"""review-registry-sync.py — converge the per-machine review registry without losing a record.

WHY THIS EXISTS
---------------
`~/.pi/agent/reviews/` is what `extensions/review-enforcer/index.ts::reviewsDir()` reads and what
`scripts/record-review.sh` writes, and nothing replicates it. So the fleet's review evidence is
fragmented per box: measured 2026-10-22, 134 records existed only on the machine that minted them,
and of 104 open PRs only 55 were visible from any one box — which is why `scripts/admin-merge.sh`
printed `🚫 Admin-merge evidence gate blocked — no reviewers dispatched` for PRs that had in fact
been fully reviewed. The union was assembled by hand once; this script makes that repeatable.

VERBS
-----
    pull    registry -> union      (this box's records enter the shared union)
    push    union -> registry      (the union's records become visible on this box)
    sync    pull, then push        (converge both ways)
    status  report only; change nothing

THE UNION
---------
`--union DIR` (default `$REVIEW_UNION`, else `<state>/review-registry-union`). It is a plain
directory, and this script deliberately owns NO transport: `pull`/`push` take any two directories,
so a box moves the union with whatever it already has (a shared mount, `rsync`, or a `git` clone
the caller pulls before and commits after).

⛔ WHY THERE IS NO BUILT-IN `--union-git`: an earlier draft wrapped `git pull/push` around the
merge. That path could not be exercised on the only box this was built on (a session with no PR is
correctly refused a `git push` by the review gate), and an UNTESTED transport inside the tool that
is meant to be the fleet's crossing mechanism is exactly the "invisible local truth" this file
exists to prevent. The tested contract is the directory.

THE FOUR INTEGRITY RULES (each one exists because breaking it silently destroys evidence)
-----------------------------------------------------------------------------------------
1. THE KEY IS THE FILENAME. `<owner>-<name>-<pr>.json` (repo-qualified) and `<pr>.json` (legacy)
   are DIFFERENT keys even for the same PR number, and are NEVER renamed, merged or collapsed.
   Measured on this box: PR 900201 carries three records in three repos; PR 1823 carries both a
   legacy and a qualified record. A "dedupe by PR number" sync destroys that.
2. NEVER DELETE. There is no unlink path for a record in this file. A record that cannot be adopted
   stays exactly where it is.
3. NEVER OVERWRITE A NEWER `reviewed_at` — AND NEVER GUESS WHEN ORDER IS UNKNOWN. A differing pair
   where EITHER side has no usable clock (absent, or non-ISO) is a CONFLICT: the target is left
   untouched, the source is preserved, and the run exits 1. Conflicting is the only truthful answer,
   because a dateless or non-ISO record is frequently the NEWER one (real case: the non-ISO string
   `2026-10-22 03:35:39 UTC` is newer than an ISO `2026-01-01T00:00:00Z` that would replace it).
   "No usable clock" means absent, non-ISO, OR NAIVE (no UTC offset — `datetime.timestamp()` would
   read it in the executing box's local zone, so the same pair would order one way in New York and
   the other way in Madrid, and both runs would report success). And an EQUAL clock is not
   automatically a conflict: `record-review.sh`'s CARRY arm keeps `reviewed_at` while changing
   head_sha, so the carried record is ordered after the record it was carried from (`carried_at`,
   then the `mint: carried` marker) — otherwise every carried PR would deadlock its key for ever.
   ⛔ A NON-ISO `reviewed_at` is NOT an invalid record: the gate never parses it (it only echoes it
   into audit events), so such a record is real evidence and must still cross boxes — it simply
   cannot be ORDERED, which is a conflict, not a refusal to sync it.
4. NEVER PROPAGATE A RECORD THE GATE WOULD REJECT. A same-key pair whose embedded `repo` fields
   DISAGREE is a COLLISION (the enforcer's #426 cross-check fails closed on it): the target is left
   untouched and the source copy is preserved under `<union>/conflicts/`. ⛔ AND ON A NUMBER-KEYED
   FILE (`<pr>.json`) ONE SIDE NAMING A REPO WHILE THE OTHER NAMES NONE IS A COLLISION TOO: the
   enforcer hands a repo-less record to EVERY repo as acceptable evidence, and `reviewRecordFile`
   maps `a-b/c` and `a/b-c` to the SAME filename, so the embedded `repo` is the gate's only defence
   there — so ONE SIDE NAMING A REPO WHILE THE OTHER NAMES NONE IS A COLLISION ON EVERY KEY, legacy
   or repo-qualified. The filename does NOT prove the repo. The clock orders only records that
   agree on whether they are attributed at all.
   Unparseable records, records missing `head_sha`/`verdict`, records whose `repo` fails the gate's
   charset, and records with an EXPLICIT `"repo": null` (the gate's test is `!== undefined`, so null
   is rejected, not treated as repo-less) are reported and never adopted — a corrupt record must not
   be laundered into another box's registry. A target the gate would read as absent is the one case
   where adoption REPLACES it: that is a repair, and nothing is deleted.

Codes 0/1/3/2 below. Bytes are copied VERBATIM (never re-serialized): a record can carry a
`sig=`-bearing marker written by `record-review.sh`, and re-dumping the JSON would rewrite it. The
decode is deliberately EXACTLY AS LOSSY as the gate (`utf-8` with replacement, then the JSON must
parse and must not use `NaN`/`Infinity`) — stricter would make gate-valid evidence un-syncable,
looser would propagate evidence the gate reads as absent.

CONCURRENCY — AND ITS STATED RESIDUAL. `record-review.sh` takes no lock, so a merge can race a fresh
mint. Every write re-reads the target, re-decides, and `os.replace`s only while the bytes it merged
against are still the bytes on disk; on a race it re-decides once and reports `RACED` rather than
claiming the write, and a write that did not land is never counted as `changed`. Writes are atomic
(same-dir temp + fsync + replace), so a reader never sees a partial record. ⛔ THE RESIDUAL IS REAL
AND IS NOT CLAIMED AWAY: read-compare and replace are not one atomic operation, so a mint landing in
that few-millisecond window can still be replaced. Closing it needs the WRITER to take the same lock,
which is `record-review.sh`'s change to make — pinned as a known gap, not silently assumed closed.

EXIT CODES (0 is the ONLY pass)
    0  converged, nothing needs a human
    1  converged, but CONFLICTS / COLLISIONS / INVALID records remain (data preserved)
    2  usage error
    3  UNKNOWN — a store or the lock could not be read, or a write failed
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Mirrors record-review.sh / the enforcer: an invalid repo makes the record invisible to the gate,
# so it earns a loud report rather than a silent copy.
# ⛔ `\Z`, NEVER `$` (review cycle 5 P1): Python's `$` ALSO matches immediately BEFORE a trailing
# newline, so `"a/b\n"` passed a `^…$` charset test that the gate's JavaScript `/^…$/` REJECTS (JS `$`
# has no pre-newline match). That made this tool ACCEPT a gate-invisible record — the dangerous
# direction — and a `"1823.json\n"` filename read as a record key the gate never looks up. `\Z` is the
# end-of-string anchor on both sides. repo-QUALIFIED/LEGACY checks use `fullmatch` for the same reason.
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
PR_QUALIFIED_RE = re.compile(r"[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]+-\d+\.json\Z")
PR_LEGACY_RE = re.compile(r"\d+\.json\Z")

EXIT_OK, EXIT_CONFLICT, EXIT_USAGE, EXIT_UNKNOWN = 0, 1, 2, 3


C = {"add": "\033[32m", "replace": "\033[36m", "keep": "\033[2m", "conflict": "\033[33m",
     "collision": "\033[31m", "invalid": "\033[35m", "dim": "\033[2m", "off": "\033[0m"}


def paint(kind: str, text: str, tty: bool) -> str:
    return f"{C[kind]}{text}{C['off']}" if tty and kind in C else text


_STDERR_OK = [True]


def note(msg: str) -> None:
    """Write a diagnostic to stderr WITHOUT ever letting it change the run's verdict.

    ⛔ CYCLE 6 P1: CPython's shutdown `flush_std_files` sets exit 120 when EITHER standard stream
    fails to flush. Defusing fd 1 alone left the identical defect on fd 2 — `… >>LOG 2>&1` on a full
    disk turned a converged 0, a usage 2 and an UNKNOWN 3 all into 120. So every diagnostic goes
    through here, and a failed write defuses fd 2 instead of escaping.
    """
    if not _STDERR_OK[0]:
        return
    try:
        sys.stderr.write(msg if msg.endswith("\n") else msg + "\n")
        sys.stderr.flush()
    except Exception:                                     # noqa: BLE001 — the verdict is computed
        _STDERR_OK[0] = False
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), 2)
        except OSError:
            pass


def flush_out(out: list[str]) -> None:
    """Write the buffered report. ⛔ A TRUNCATED PIPE MUST NOT REWRITE THE VERDICT (review cycle 3 P1):
    swallowing `BrokenPipeError` and exiting 0 turned every conflict into a pass under `| head -1`, and
    for `sync` it could return 0 after the pull half printed while the push half never ran. The exit
    code is decided from the transfer results, and this write can only ever fail to DISPLAY them."""
    if not out:
        return
    # ⛔ NOT ONLY BrokenPipeError (review cycle 4): the labels carry `→`, so a non-UTF-8 stdout
    # (`LC_ALL=C`, `PYTHONIOENCODING=ascii`) raised UnicodeEncodeError OUT of the flush and turned a
    # converged run into exit 1 (and `--json` into zero bytes). Degrade the ENCODING first, and treat
    # any remaining write failure as "could not display" — never as the run's verdict.
    try:
        sys.stdout.reconfigure(errors="backslashreplace")     # 3.7+; degrades, never raises
    except (AttributeError, OSError):
        pass
    try:
        sys.stdout.write("".join(out))
        sys.stdout.flush()
    except BrokenPipeError:
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
    except Exception as e:                                    # noqa: BLE001 — the verdict is computed
        # ⛔ DEFUSE THE STREAM, do not just apologise (review cycle 5): the buffered report is still
        # queued in sys.stdout, so leaving it there made CPython's SHUTDOWN flush fail and force exit
        # 120 (a full/quota'd filesystem, EIO) — overriding the computed verdict in both directions.
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
        note(f"review-registry-sync: could not write the report ({type(e).__name__}); "
             "the exit code is the verdict")


def is_record_key(name: str) -> bool:
    return bool(PR_QUALIFIED_RE.fullmatch(name) or PR_LEGACY_RE.fullmatch(name))


def default_union_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME")
    root = Path(base) if base else Path.home() / ".pi" / "agent" / "state"
    return root / "review-registry-union"


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class Record:
    """One record file, validated the way the enforcer validates it (fail-closed)."""

    __slots__ = ("key", "raw", "repo", "reviewed_at", "verdict", "problem", "stamp_note",
                 "carried_stamp", "is_carried")

    def __init__(self, key: str, raw: bytes):
        self.key, self.raw = key, raw
        self.repo = self.reviewed_at = self.verdict = None
        self.problem: str | None = None          # the GATE itself would read this as absent
        self.stamp_note: str | None = None       # valid to the gate, but cannot be ordered
        self.carried_stamp: float | None = None
        self.is_carried = False
        # ⛔ THE GATE'S LEXER, NOT PYTHON'S. The enforcer reads the file as UTF-8 and hands the TEXT to
        # `JSON.parse` (index.ts:1580-1595). Python's `json.loads(bytes)` is MORE permissive: it
        # auto-detects UTF-16/32 BOMs and accepts the non-standard `NaN`/`Infinity` constants, so a
        # record the GATE reads as ABSENT would have been accepted here as valid and could then replace
        # (and destroy) the only gate-visible evidence for that key (review cycle 3 P0). Decode
        # strictly, refuse BOMs, and reject the non-standard constants.
        def _no_constants(value: str):
            raise ValueError(f"non-standard JSON constant {value}")
        try:
            # ⛔ EXACTLY AS LOSSY AS THE GATE, NOT STRICTER (review cycle 4). The enforcer decodes with
            # `fs.readFileSync(path, "utf8")`, which REPLACES invalid bytes with U+FFFD and then lets
            # `JSON.parse` succeed — so a record with a stray 0xFF is VALID evidence to the gate. A
            # strict decode here made that evidence un-syncable and mislabelled it "unparseable".
            # UTF-16/32 bodies still fail at `json.loads` below, which is what the gate does too.
            text = raw.decode("utf-8", errors="replace")
            if text.startswith("\ufeff"):
                raise ValueError("leading UTF-8 BOM — JSON.parse refuses it too")
            d = json.loads(text, parse_constant=_no_constants)
        except Exception as e:                                   # noqa: BLE001 — any parse failure
            self.problem = f"unparseable ({type(e).__name__})"
            return
        if not isinstance(d, dict):
            self.problem = "not a JSON object"
            return
        if not isinstance(d.get("head_sha"), str) or not isinstance(d.get("verdict"), str):
            self.problem = "missing string head_sha/verdict (the gate would read it as absent)"
            return
        self.verdict = d["verdict"]
        # ⛔ AN EXPLICIT `"repo": null` IS NOT THE SAME AS AN ABSENT KEY. The enforcer's charset test
        # is `rec.repo !== undefined && !REPO_RE.test(rec.repo)` (review-enforcer/index.ts:1588) —
        # `null !== undefined`, `String(null)` fails the charset, so the GATE reads such a record as
        # ABSENT while `.get("repo")` here read it as repo-less. That divergence let a newer
        # gate-invisible record replace a gate-VALID one (review P2).
        if "repo" in d and d["repo"] is None:
            self.problem = 'repo field is null — the gate reads this record as absent'
            return
        repo = d.get("repo")
        if repo is not None:
            if not isinstance(repo, str):
                # The gate compares the embedded `repo` to the resolved repo by IDENTITY
                # (`qualified.repo !== repo`), and only a string can equal one — so a non-string
                # `repo` never matches and the gate reads the record as absent wherever a repo is
                # known. (Its charset test alone would coerce, e.g. `["a/b"]` → "a/b", which is why
                # this says what it says rather than calling it a charset failure.)
                self.problem = (f"repo field {repo!r} is not a string — it cannot equal any resolved "
                                "repo, so the gate reads this record as absent")
                return
            if not REPO_RE.fullmatch(repo):
                self.problem = f"repo field {repo!r} fails the gate's charset (gate reads it as absent)"
                return
            self.repo = repo
        ra = d.get("reviewed_at")
        if isinstance(ra, str):
            self.reviewed_at = ra
            try:
                parsed = datetime.fromisoformat(ra.replace("Z", "+00:00"))
            except ValueError:
                parsed = None
            # ⛔ NOT a `problem`. The gate never parses `reviewed_at` (it only echoes it into audit
            # events), so a record with a non-ISO stamp IS valid evidence and must still cross boxes;
            # it simply cannot be ORDERED. Made into an `invalid` record it made the tool overwrite a
            # gate-valid NEWER record with an older one, and made a gate-valid record un-syncable.
            if parsed is None:
                self.stamp_note = f"reviewed_at {ra!r} is not ISO-8601 — cannot be ordered"
            elif parsed.tzinfo is None:
                # ⛔ A NAIVE stamp (no offset — `2026-10-22 01:00:00`, a date-only `2026-10-22`, a
                # plain dotted format) is AMBIGUOUS: `datetime.timestamp()` reads it in THIS BOX'S
                # local zone, so the same pair orders one way in New York and the other way in Madrid,
                # and both runs exit 0. Never guess a zone (review P1): no offset = no usable clock.
                self.stamp_note = f"reviewed_at {ra!r} carries no UTC offset — cannot be ordered"
        # Optional ordering tiebreak for equal `reviewed_at` (see decide()): `record-review.sh`'s CARRY
        # arm preserves `reviewed_at` while changing head_sha and adding `mint: carried` / `carried_at`
        # / `carried_from` (record-review.sh:2263-2276), so the carried record IS the later one even
        # though the clock is unchanged.
        ca = d.get("carried_at")
        self.carried_stamp = None
        if isinstance(ca, str):
            try:
                parsed_ca = datetime.fromisoformat(ca.replace("Z", "+00:00"))
            except ValueError:
                parsed_ca = None
            # ⛔ PARSED, never string-compared (review cycle 3): `"…T10:00:00+02:00"` (08:00Z) sorted
            # AFTER `"…09:00:00Z"` as a string, and a junk `"zzz"` beat a real stamp. A carried_at that
            # cannot be placed on the clock is no ordering evidence at all.
            self.carried_stamp = parsed_ca.timestamp() if parsed_ca and parsed_ca.tzinfo else None
        # ⛔ THE CONTRACT'S MARKER IS `mint: "carried"` (what record-review.sh writes). A bare
        # `carried_at` on a hand-edited record is not a mint claim.
        self.is_carried = d.get("mint") == "carried"

    @property
    def stamp(self) -> float | None:
        """Epoch seconds, or None when the record cannot be placed on the clock (see stamp_note)."""
        if not self.reviewed_at:
            return None
        try:
            parsed = datetime.fromisoformat(self.reviewed_at.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return None
        return parsed.timestamp()

    @property
    def digest(self) -> str:
        return sha256(self.raw)[:12]


def load_store(path: Path) -> tuple[dict[str, Record], list[tuple[str, str]]]:
    """Read a store → (records, ignored). Raises OSError when unreadable (never a pass)."""
    out: dict[str, Record] = {}
    ignored: list[tuple[str, str]] = []
    with os.scandir(path) as it:
        for ent in it:
            if not ent.is_file():
                continue
            if not is_record_key(ent.name):
                ignored.append((ent.name, "not a review-record key"))
                continue
            out[ent.name] = Record(ent.name, Path(ent.path).read_bytes())
    return out, ignored


def is_legacy_key(name: str) -> bool:
    return bool(PR_LEGACY_RE.match(name))


def decide(src: Record, dst: Record) -> tuple[str, str]:
    """(action, why) where action ∈ {add, replace, keep, conflict, collision, invalid}."""
    if src.problem:
        return "invalid", src.problem
    if dst.problem:
        # The target is one the GATE would read as absent, and the source is valid for the same key:
        # adopting is a repair, not a loss (nothing is deleted) — but say so, it is not silent.
        return "replace", f"target is unreadable to the gate ({dst.problem}); adopting the valid source"
    if src.raw == dst.raw:
        return "keep", "identical"
    if src.repo and dst.repo and src.repo != dst.repo:
        return "collision", f"same key, different repos ({dst.repo} vs {src.repo}) — #426 cross-check"
    # ⛔ ONE SIDE NAMING A REPO WHILE THE OTHER NAMES NONE IS A COLLISION ON EVERY KEY (review cycle 4).
    # A repo-less record answers for EVERY repo at the gate: `readReviewRecord` hands a repo-less
    # legacy `<pr>.json` to any caller (`index.ts:1708-1715`), and a repo-less record on a QUALIFIED
    # key is accepted there too — which matters because `reviewRecordFile` maps `a-b/c-<pr>.json` and
    # `a/b-c-<pr>.json` to the SAME filename (`index.ts:1573-1577`), so the embedded `repo` is the
    # ONLY thing that stops one repo's evidence answering for another. Ordering those two by clock
    # would delete that field and widen one repo's evidence to a name-colliding peer. The clock can
    # only decide between records that agree on whether they are attributed at all.
    if (src.repo is None) != (dst.repo is None):
        return "collision", (f"one record names a repo ({dst.repo or src.repo}) and the other names "
                             "none — a repo-less record answers for EVERY repo")
    s, d = src.stamp, dst.stamp
    if s is None or d is None:
        # ⛔ CANNOT ORDER ⇒ NEVER GUESS (review P1). A missing or non-ISO `reviewed_at` means the
        # order is UNKNOWN, and "unknown" must not be resolved in the travelling record's favour: a
        # dateless record can easily be the newer one (real case: `reviewed_at: "2026-10-22 03:35:39
        # UTC"` is newer than an ISO `2026-01-01T00:00:00Z` that would replace it). So a differing
        # pair where EITHER side has no usable clock is a CONFLICT — target untouched, source
        # preserved, exit 1 — instead of a silent loss in either direction.
        return "conflict", ("cannot order: " + ("source" if s is None else "target") +
                            " carries no usable reviewed_at")
    if s > d:
        return "replace", f"source newer ({src.reviewed_at} > {dst.reviewed_at})"
    if s < d:
        return "keep", f"target newer ({dst.reviewed_at} > {src.reviewed_at})"
    # EQUAL CLOCK. Refusing outright is wrong for a class the fleet's own writer MINTS: a CARRY
    # (record-review.sh:2263-2276) keeps `reviewed_at` and changes head_sha, so the pre-carry copy in
    # the union would conflict with the carried copy on every sync, for ever, and the union could
    # never advance past it (review P1). Order the carried record strictly LATER — that is the one
    # ordering the writer itself asserts — and conflict only when nothing distinguishes the pair.
    if src.carried_stamp is not None and dst.carried_stamp is not None:
        if src.carried_stamp > dst.carried_stamp:
            return "replace", "equal reviewed_at; source was carried later"
        if src.carried_stamp < dst.carried_stamp:
            return "keep", "equal reviewed_at; target was carried later"
    if src.is_carried != dst.is_carried:
        if src.is_carried:
            return "replace", "equal reviewed_at; source is the CARRIED re-mint of this review"
        return "keep", "equal reviewed_at; target is the CARRIED re-mint of this review"
    return "conflict", (f"equal reviewed_at ({src.reviewed_at}), no carry marker and the records differ "
                        "— a human must pick")


def atomic_write(dst: Path, raw: bytes, expect: bytes | None, retries: int = 5) -> bool:
    """CAS write: replace `dst` only while its bytes are still `expect` (None = must be absent).

    True when written; False when a concurrent writer won the race on every attempt.
    """
    for _ in range(retries):
        try:
            cur = dst.read_bytes()
        except FileNotFoundError:
            cur = None
        if cur != expect:
            return False                            # a fresh mint landed; the caller re-decides
        tmp = dst.parent / f".{dst.name}.tmp-sync-{os.getpid()}-{int(time.time() * 1e6)}"
        try:
            with open(tmp, "wb") as fh:
                fh.write(raw)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, dst)
            return True
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
    return False


def preserve(union_dir: Path, rec: Record, store_name: str) -> Path:
    """Keep a non-adoptable source copy under <union>/conflicts/ — never deleted, never in the gate's dir."""
    d = union_dir / "conflicts"
    d.mkdir(parents=True, exist_ok=True)
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", store_name).strip("-") or "store"
    out = d / f"{rec.key}.{slug}.{rec.digest}.json"
    if not out.exists():
        atomic_write(out, rec.raw, None)
    return out


def preserve_safely(union_dir: Path, rec: Record, store_name: str, stats: dict,
                    lines: list[str], tty: bool) -> Path | None:
    """preserve(), but an un-creatable conflicts dir is a counted FAILURE, never a traceback."""
    try:
        return preserve(union_dir, rec, store_name)
    except OSError as e:
        stats["failed"] += 1
        lines.append(f"  {paint('collision', 'FAILED', tty)}  {rec.key}: could not preserve the source "
                     f"({e}) — the target was left untouched")
        return None


def transfer(src_dir: Path, dst_dir: Path, label: str, dry_run: bool, union_dir: Path,
             tty: bool, verbose: bool, out: list[str], human: bool = True) -> dict:
    stats = {"add": 0, "replace": 0, "keep": 0, "conflict": 0, "collision": 0, "invalid": 0,
             "raced": 0, "unachieved": 0, "failed": 0, "ignored": 0}
    lines: list[str] = []

    try:
        src_records, src_ignored = load_store(src_dir)
    except OSError as e:
        note(f"UNKNOWN: cannot read the SOURCE store {src_dir} ({e}) — this is NOT a pass")
        raise SystemExit(EXIT_UNKNOWN)
    try:
        dst_records, _ = load_store(dst_dir)
    except FileNotFoundError:
        dst_records = {}                # a destination that does not exist yet is empty, not UNKNOWN
    except OSError as e:
        note(f"UNKNOWN: cannot read the TARGET store {dst_dir} ({e}) — this is NOT a pass")
        raise SystemExit(EXIT_UNKNOWN)

    for name, why in src_ignored:
        stats["ignored"] += 1
        if verbose:
            lines.append(f"  {paint('dim', 'skip', tty)}      {name}: {why}")

    if not dry_run:
        dst_dir.mkdir(parents=True, exist_ok=True)

    for key in sorted(src_records):
        src = src_records[key]
        dst = dst_records.get(key)
        if src.problem:
            action, why = "invalid", src.problem
        elif dst is None:
            action, why = "add", "absent in target"
        else:
            action, why = decide(src, dst)

        if action == "invalid":
            stats["invalid"] += 1
            lines.append(f"  {paint('invalid', 'INVALID', tty)}   {key}: {why} — not adopted, nothing removed")
            continue
        if action == "collision":
            stats["collision"] += 1
            kept = None if dry_run else preserve_safely(union_dir, src, label, stats, lines, tty)
            lines.append(f"  {paint('collision', 'COLLISION', tty)} {key}: {why}"
                         + (f" — source preserved at {kept}" if kept else " — (preserved copy not written)"))
            continue
        if action == "conflict":
            stats["conflict"] += 1
            kept = None if dry_run else preserve_safely(union_dir, src, label, stats, lines, tty)
            lines.append(f"  {paint('conflict', 'CONFLICT', tty)}  {key}: {why}"
                         + (f" — source preserved at {kept}" if kept else " — (preserved copy not written)"))
            continue
        if action == "keep":
            stats["keep"] += 1
            if verbose:
                lines.append(f"  {paint('dim', 'keep', tty)}      {key}: {why}")
            continue

        lines.append(f"  {paint(action, action.upper(), tty)}     {key}: {why}")
        if dry_run:
            stats[action] += 1              # a dry run reports what it WOULD do; nothing was written
            continue
        try:
            ok = atomic_write(dst_dir / key, src.raw, dst.raw if dst is not None else None)
        except OSError as e:
            stats["failed"] += 1
            lines.append(f"  {paint('collision', 'FAILED', tty)}  {key}: write failed ({e}) — target untouched")
            continue
        if ok:
            stats[action] += 1              # ⛔ counted only AFTER the write landed (review P2): a
            continue                        # write lost to the race must never inflate `changed`
        # A concurrent mint landed between decision and write. Re-decide against the bytes on disk:
        # the fresh record may be newer than ours, in which case ours loses.
        cur = dst_dir / key
        try:
            now: Record | None = Record(key, cur.read_bytes())
        except OSError:
            now = None
        again, why2 = ("add", "raced; target now absent") if now is None else decide(src, now)
        if again in ("add", "replace"):
            try:
                landed = atomic_write(cur, src.raw, now.raw if now else None)
            except OSError as e:      # the store turned unwritable between the two attempts → UNKNOWN
                stats["failed"] += 1
                lines.append(f"  {paint('collision', 'FAILED', tty)}  {key}: re-decision write failed ({e})"
                             " — target untouched")
                continue
            if landed:
                stats[again] += 1     # counted only because THIS write landed (review cycle 3 P1)
                lines.append(f"  {paint(again, 'RACED', tty)}   {key}: adopted on re-decision ({why2})")
            else:
                # The second CAS lost too: nothing was written, so this is NOT `changed`. The reader is
                # told the truth and the run cannot report a convergence it did not achieve.
                # ⛔ NOT `raced`: a benign race leaves the target holding the NEWER record, which is
                # convergence. Here the record we decided to write is still missing — the sync did not
                # achieve what it reported, so this is UNKNOWN and cannot exit 0 (review cycle 4).
                stats["unachieved"] += 1
                lines.append(f"  {paint('collision', 'UNACHIEVED', tty)} {key}: still racing — NOT written, "
                             f"{again} not achieved ({why2})")
        elif again == "keep":
            stats["raced"] += 1                  # benign: the newer record is already there
            lines.append(f"  {paint('dim', 'RACED', tty)}     {key}: a concurrent writer won — left as is ({why2})")
        else:
            # ⛔ A CONFLICT / COLLISION / INVALID DISCOVERED AT RE-DECIDE TIME MUST NOT BE SWALLOWED AS
            # "RACED" (review P1): it is the same evidence condition the first pass treats as exit 1
            # with a preserved copy. Counted in its own bucket, preserved, and fed to the exit code.
            stats[again] += 1
            kept = preserve_safely(union_dir, src, label, stats, lines, tty)
            lines.append(f"  {paint(again, again.upper(), tty)}  {key}: discovered at re-decision — {why2}"
                         + (f" — source preserved at {kept}" if kept else " — (preserved copy not written)"))

    changed = stats["add"] + stats["replace"]
    head = (f"{label}: {changed} changed ({stats['add']} added, {stats['replace']} replaced), "
            f"{stats['keep']} unchanged")
    if (stats["conflict"] or stats["collision"] or stats["invalid"] or stats["failed"]
            or stats["raced"] or stats["unachieved"]):
        head += (f"  ⚠ {stats['conflict']} conflict · {stats['collision']} collision · "
                 f"{stats['invalid']} invalid · {stats['failed']} failed · "
                 f"{stats['unachieved']} unachieved · {stats['raced']} raced")
    if human:
        out.append(head + "\n")
        out.extend(ln + "\n" for ln in lines)
    return stats


def status(registry: Path, union: Path, tty: bool, as_json: bool, out: list[str]) -> int:
    try:
        reg, _ = load_store(registry)
    except OSError as e:
        note(f"UNKNOWN: cannot read the registry {registry} ({e}) — not a pass")
        return EXIT_UNKNOWN
    try:
        uni, _ = load_store(union)
    except FileNotFoundError:
        uni = {}
    except OSError as e:
        note(f"UNKNOWN: cannot read the union {union} ({e}) — not a pass")
        return EXIT_UNKNOWN

    only_reg = sorted(set(reg) - set(uni))
    only_uni = sorted(set(uni) - set(reg))
    diverged = sorted(k for k in set(reg) & set(uni) if reg[k].raw != uni[k].raw)
    if as_json:
        out.append(json.dumps({"registry": len(reg), "union": len(uni), "only_registry": only_reg,
                               "only_union": only_uni, "diverged": diverged}, indent=1) + "\n")
        return EXIT_OK if not only_reg and not only_uni and not diverged else EXIT_CONFLICT
    out.append(f"registry {registry}: {len(reg)} records\n")
    out.append(f"union    {union}: {len(uni)} records\n")
    out.append(f"only in registry: {len(only_reg)} · only in union: {len(only_uni)} · "
               f"same key/different bytes: {len(diverged)}\n")
    for k in only_reg[:40]:
        out.append(f"  {paint('dim', 'registry-only', tty)} {k}  (run `pull` to publish it to the union)\n")
    for k in only_uni[:40]:
        out.append(f"  {paint('add', 'union-only', tty)}    {k}  (run `push` to make it visible here)\n")
    for k in diverged[:40]:
        a, b = reg[k].stamp, uni[k].stamp
        who = "union newer" if (b or 0) > (a or 0) else ("registry newer" if (a or 0) > (b or 0) else "no clock")
        out.append(f"  {paint('conflict', 'diverged', tty)}      {k}: {who} "
                   f"({reg[k].reviewed_at} vs {uni[k].reviewed_at})\n")
    # ⛔ BOTH DIRECTIONS ARE FRAGMENTATION (review P1). A registry holding records the union lacks is
    # the exact 134-records-on-one-box state this tool exists to detect, so it cannot exit 0 — a
    # monitor polling `status` would read green over the incident.
    return EXIT_OK if not only_reg and not only_uni and not diverged else EXIT_CONFLICT


def main(argv: list[str]) -> int:
    # ⛔ A CLOSED STREAM IS NOT A CRASH (review cycle 5): with fd 1 closed `sys.stdout` is None and
    # `isatty()` raises; with fd 2 closed `print(file=sys.stderr)` falls back to STDOUT, which would
    # put a diagnostic where `--json` promised JSON. Both are answered here, once.
    if sys.stdout is None:
        try:
            sys.stdout = open(os.devnull, "w")
        except OSError:
            pass
    if sys.stderr is None or not _STDERR_OK[0]:
        try:
            sys.stderr = open(os.devnull, "w")
        except OSError:
            pass
        _STDERR_OK[0] = False
    try:
        tty = bool(sys.stdout.isatty()) and not os.environ.get("NO_COLOR")
    except (AttributeError, ValueError):
        tty = False
    ap = argparse.ArgumentParser(
        prog="review-registry-sync.py",
        description="Converge the per-machine review registry (~/.pi/agent/reviews) with a shared union.",
    )
    ap.add_argument("verb", choices=["pull", "push", "sync", "status"])
    ap.add_argument("--registry", default=os.environ.get("REVIEW_REGISTRY") or
                    str(Path.home() / ".pi" / "agent" / "reviews"),
                    help="the machine-local registry the enforcer reads (default ~/.pi/agent/reviews)")
    ap.add_argument("--union", default=os.environ.get("REVIEW_UNION") or str(default_union_dir()),
                    help="the shared union directory (default $REVIEW_UNION or <state>/review-registry-union)")
    ap.add_argument("--dry-run", action="store_true", help="report what would change; change nothing")
    ap.add_argument("--verbose", "-v", action="store_true", help="show unchanged records too")
    ap.add_argument("--json", action="store_true", help="machine-readable summary on stdout")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        # ⛔ ARGPARSE'S OWN EXIT MUST NOT BE REWRITTEN EITHER (review cycle 6): a usage error writes to
        # stderr, and on an unwritable stderr that buffered write fails at interpreter shutdown and
        # turns the documented 2 into 120. Flush here; if the flush is what fails, defuse fd 2.
        try:
            sys.stderr.flush()
        except Exception:                                 # noqa: BLE001
            _STDERR_OK[0] = False
            try:
                os.dup2(os.open(os.devnull, os.O_WRONLY), 2)
            except OSError:
                pass
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else EXIT_USAGE)
        return code if code in (EXIT_OK, EXIT_USAGE) else EXIT_USAGE

    try:
        registry = Path(args.registry).expanduser()
        union = Path(args.union).expanduser()
    except RuntimeError as e:   # `~nosuchuser/...` → usage error, never a traceback on the conflict code
        note(f"usage error: cannot resolve a path ({e})")
        return EXIT_USAGE

    out: list[str] = []
    if args.verb == "status":
        code = status(registry, union, tty, args.json, out)
        flush_out(out)
        return code

    if not registry.is_dir():
        if args.verb in ("push", "sync"):         # the target of push must exist to be answered about
            note(f"UNKNOWN: registry {registry} is not a directory — cannot answer")
            return EXIT_UNKNOWN
    if not args.dry_run:
        try:
            union.mkdir(parents=True, exist_ok=True)
        except OSError as e:            # e.g. --union names an existing FILE: UNKNOWN, never a traceback
            note(f"UNKNOWN: cannot create the union {union} ({e}) — not a pass")
            return EXIT_UNKNOWN

    lock_fh = None
    if not args.dry_run:
        try:
            lock_fh = open(union / ".sync.lock", "w")
            fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_fh.write(f"{os.getpid()} {datetime.now(timezone.utc).isoformat()}\n")
            lock_fh.flush()
        except OSError as e:
            note(f"UNKNOWN: another sync holds the lock ({e}) — not a pass")
            return EXIT_UNKNOWN

    try:
        results: dict[str, dict] = {}
        if args.verb in ("pull", "sync"):
            results["pull"] = transfer(registry, union, "pull registry→union", args.dry_run, union, tty,
                                       args.verbose, out, human=not args.json)
        if args.verb in ("push", "sync"):
            results["push"] = transfer(union, registry, "push union→registry", args.dry_run, union, tty,
                                       args.verbose, out, human=not args.json)
        if args.json:
            out.append(json.dumps(results, indent=1) + "\n")
        if any(r.get("failed") or r.get("unachieved") for r in results.values()):
            code = EXIT_UNKNOWN
        elif any(r.get("conflict") or r.get("collision") or r.get("invalid") for r in results.values()):
            code = EXIT_CONFLICT
        else:
            code = EXIT_OK
    finally:
        if lock_fh is not None:
            try:
                fcntl.flock(lock_fh, fcntl.LOCK_UN)
                lock_fh.close()
            except OSError:
                pass
    flush_out(out)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
