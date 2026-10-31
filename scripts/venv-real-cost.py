#!/usr/bin/env python3
"""venv-real-cost.py — what a lane env ACTUALLY costs on disk, hardlink-aware (#2159).

WHY THIS EXISTS
`du` answers "how many blocks are under this path", not "how many bytes does this path
cost the filesystem". Where `uv` links packages out of its download cache
(`UV_LINK_MODE=hardlink`, or a reflink clonefile on APFS/btrfs/XFS), the two answers
diverge by an order of magnitude, and the fleet's capacity arithmetic was built on the
first one.

MEASURED on cell-1, 2026-10-31, tortoise checkout, `uv sync --extra embeddings --extra parity`:

    du -sk <worktree>/.venv          5,940,904 KB   <- what the reaper charged per lane
    private blocks (nlink == 1)        101,404 KB   <- what reaping it actually frees
    three fresh worktrees, df delta    880,408 KB   (~293 MB each; ~4-144 MB of it the venv)
    hardlinked to the cache            249 / 300 sampled files (nlink 5-6)

So a live lane env that `du` prices at 5.7 GB can cost 18-144 MB of real, non-shared
disk. The 5.7 GB figure is an UPPER BOUND (sound for a cold cache) and it is the wrong
divisor for "how many more lanes fit" — it under-reports headroom by ~20x, which is how
a box with 20 GB free came to be treated as a box with 3 lanes left.

And the failure class that DOES cost the full figure is real and visible here: one env in
the same checkout reported 5,935,940 private KB (`nlink=1` throughout) — a private copy,
zero sharing, because hardlinking silently degrades to a full copy when the cache is on
another filesystem or the link mode is not in force. That env costs 58x its neighbours.
This tool names that class instead of averaging it away. (The full table, with the commands,
is in docs/ops/lane-venv-reaper-policy.md.)

THE THREE NUMBERS, and which question each answers
  total_kb    every allocated block under the path, each INODE once and including the named
              directory's own blocks (== `du -sk`, the UPPER BOUND).
  private_kb  blocks whose every link lies INSIDE this tree (nlink == 1, or all links seen
              here): bytes that VANISH if this tree is deleted. This is what "reap it"
              actually frees, and the honest per-lane marginal cost when the cache is warm.
              It is 0 on a perfectly-shared env — a real, GOOD reading, not a missing one.
  fair_kb     blocks divided across their link count (sum(blocks / nlink)): this tree's
              share of everything it touches, for ATTRIBUTION between trees. It is NOT
              "the bytes freed if this tree is deleted" — while any other link survives
              (the uv cache holds one), the blocks stay allocated. `private_kb` is the
              freed-bytes figure.

`total_kb` counts each inode once and includes the named directory's own blocks, so it agrees
with `du -sk` on the same tree; a residual mismatch means the tree changed mid-walk (or `du`
crossed a mount), so both are reported and neither is silently preferred.

Portability: POSIX `os.lstat` + `st_blocks`/`st_nlink`. No `stat -c` (GNU) vs `stat -f`
(BSD) divergence, no `find -printf` (GNU only). Symlinks are never followed, so this can
never walk out of the tree it was given.

Usage:
  venv-real-cost.py PATH [PATH ...]        # human table
  venv-real-cost.py --tsv PATH             # "private_kb<TAB>fair_kb<TAB>total_kb<TAB>dedupe"
  venv-real-cost.py --json PATH [PATH ...] # one JSON object per path

Exit: 0 measured, 2 usage, 3 could not measure (unreadable path / no stat) — the caller
must read 3 as UNKNOWN, never as zero.
"""

from __future__ import annotations

import json
import os
import stat
import sys

# A tree is "degraded" when most of its bytes are private: the sharing that makes repeated
# `uv sync` nearly free is not in force, so this env costs its full `du` figure.
DEGRADED_PRIVATE_RATIO = 0.5
# Below this, the ratio is noise — a nearly-empty env (a sync in progress) has few files
# and is not evidence about the box's link regime either way.
DEGRADED_MIN_TOTAL_KB = 50 * 1024


def measure(root: str) -> dict:
    """Walk `root` without following symlinks and attribute allocated blocks."""
    st = os.lstat(root)
    if not stat.S_ISDIR(st.st_mode):
        raise NotADirectoryError(root)

    # `du` counts the NAMED directory's own blocks too, and the walk below only sees its entries —
    # seed it here, or `total_kb` is silently one directory short of the figure it claims to equal.
    root_kb = (getattr(st, "st_blocks", 0) * 512) // 1024

    total_kb = root_kb
    private_kb = fair_kb = 0
    files = shared_files = 0
    errors = 0
    # inode -> [blocks_kb, nlink, times_seen]. ⛔ COUNTS PER INODE, NOT PER NAME (review P2):
    # `du` counts a multiply-linked inode ONCE per invocation, and two names for one inode inside a
    # single tree (a hardlinked pair, which `uv` produces) would otherwise double `total_kb` —
    # measured 2x on a 20 MiB pair — and flatten the private/total ratio the verdict rests on.
    inodes: dict = {}
    denom = 1024  # st_blocks is in 512-byte units on every platform we run on

    stack = [root]
    while stack:
        path = stack.pop()
        try:
            entries = list(os.scandir(path))
        except OSError:
            # Unreadable directory: the walk is TRUNCATED, and a truncated walk must never be
            # reported as a measured number (review: 98.4% of a tree's bytes vanished from a
            # reading that still exited 0). Counted here, turned into `partial` + exit 3 below.
            errors += 1
            continue
        for entry in entries:
            try:
                s = entry.stat(follow_symlinks=False)
            except OSError:
                errors += 1
                continue
            mode = s.st_mode
            blocks = getattr(s, "st_blocks", 0) * 512
            if stat.S_ISDIR(mode):
                # ⛔ DIRECTORIES ARE NOT FILES (review P1). A directory's st_nlink is the number of
                # its SUBDIRECTORIES (>= 2), so letting it fall through made every directory count as
                # a "shared file" — a fully-private env reported 3,952 shared files and read as
                # "sharing is in force", the exact false signal this tool exists to prevent.
                # Its own blocks ARE part of the tree's cost and `du -sk` counts them, so they go into
                # `total_kb` only — never into `private_kb`/`fair_kb`, which attribute PACKAGE bytes.
                total_kb += blocks // denom
                stack.append(entry.path)
                continue
            elif stat.S_ISLNK(mode):
                # Never followed, and a symlink's own blocks are negligible.
                continue
            files += 1
            nlink = getattr(s, "st_nlink", 1)
            if nlink > 1:
                shared_files += 1
            # No getattr default: st_dev/st_ino exist on every CPython platform, so a default can
            # only ever mask a real failure — and a (0, 0) fallback would collapse every file into
            # ONE inode, under-reporting total_kb (#2159 review, round 3).
            key = (s.st_dev, s.st_ino)
            slot = inodes.get(key)
            if slot is None:
                inodes[key] = [blocks // denom, nlink, 1]
            else:
                slot[2] += 1

    for blocks_kb, nlink, seen in inodes.values():
        total_kb += blocks_kb
        # ⛔ "PRIVATE" MEANS THE BLOCKS CANNOT SURVIVE THIS TREE'S DELETION. `nlink == 1` is the
        # common case, but an inode whose EVERY link lives inside the tree is just as private even
        # though nlink > 1 — measured: a 20 MiB hardlinked PAIR inside one tree freed 20,484 KB on
        # `rm -rf`, and a bare `nlink > 1` test reported private=0 for it. Only a link we did not
        # see (nlink > seen) can be keeping the blocks alive afterwards.
        if seen >= nlink:
            private_kb += blocks_kb
            # This tree owns every link, so its share is the whole inode. Reporting 0 here would
            # tell a reader the private 5.9 GB env "touches nothing" (#2159 review, round 3).
            fair_kb += blocks_kb
        else:
            fair_kb += (blocks_kb * seen) // nlink

    if total_kb == 0:
        dedupe = "unknown"
    elif errors:
        dedupe = "partial"
    elif total_kb < DEGRADED_MIN_TOTAL_KB:
        dedupe = "small"
    elif private_kb / total_kb >= DEGRADED_PRIVATE_RATIO:
        dedupe = "degraded"
    else:
        dedupe = "ok"

    return {
        "path": os.path.abspath(root),
        "total_kb": total_kb,
        "private_kb": private_kb,
        "fair_kb": fair_kb,
        "files": files,
        "shared_files": shared_files,
        "errors": errors,
        "dedupe": dedupe,
    }


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(__doc__ or "")
        return 0 if argv else 2

    mode = "table"
    if argv[0] in ("--tsv", "--json"):
        mode = argv[0][2:]
        argv = argv[1:]
    if not argv:
        sys.stderr.write("venv-real-cost.py: no PATH given\n")
        return 2

    rows = []
    rc = 0
    for p in argv:
        try:
            rows.append(measure(p))
        except OSError as exc:
            sys.stderr.write(f"venv-real-cost.py: {p}: {exc}\n")
            rc = 3

    # A TRUNCATED walk is not a measurement: an unreadable subdirectory silently drops its bytes, and
    # a reading that omits most of a tree must not reach a caller as "measured" while exiting 0.
    # Exit 3 makes the reaper's guard fail closed and report `?` (#2159 review, P2).
    for r in rows:
        if r.get("errors"):
            sys.stderr.write(
                "venv-real-cost.py: %s: walk truncated by %d unreadable entr%s — "
                "the figure is a LOWER BOUND, not a measurement\n"
                % (r["path"], r["errors"], "y" if r["errors"] == 1 else "ies")
            )
            rc = 3

    if mode == "tsv":
        for r in rows:
            sys.stdout.write(
                "%d\t%d\t%d\t%s\n"
                % (r["private_kb"], r["fair_kb"], r["total_kb"], r["dedupe"])
            )
    elif mode == "json":
        for r in rows:
            sys.stdout.write(json.dumps(r, sort_keys=True) + "\n")
    else:
        sys.stdout.write(
            "%10s %10s %10s %8s %8s  %-9s %s\n"
            % ("private", "fair", "total", "files", "shared", "dedupe", "path")
        )
        for r in rows:
            sys.stdout.write(
                "%10d %10d %10d %8d %8d  %-9s %s\n"
                % (
                    r["private_kb"],
                    r["fair_kb"],
                    r["total_kb"],
                    r["files"],
                    r["shared_files"],
                    r["dedupe"],
                    r["path"],
                )
            )
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
