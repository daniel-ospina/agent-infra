#!/usr/bin/env python3
"""bulk.py — landability for MANY pull requests at once (planning only).

Runs `landability.py`'s check over a list of PRs in parallel and prints one row
per PR. It answers "of the PRs I might land, which ones can the rail actually
take right now, and which need a fresh review" — nothing else.

THIS IS A REPORT, NOT A CLAIM. It does not claim, queue, record, or land
anything: claims still go through the queue tool. Crucially, it is not a
`collision_preflight.py` substitute — that is a DISPATCH-side gate answering
"is issue N already being worked?" (see landability.py's docstring).

NO QUEUE FORMAT IS REQUIRED. Give PR numbers on the command line, or point
--prs-file at any text file whose FIRST whitespace-separated column is a PR
number (`-` reads stdin). Blank lines and `#` comments are skipped, so this
accepts a hand-typed list, `gh pr list` output, or an existing TSV queue without
knowing anything about that queue's schema.

Usage:
  bulk.py [--repo owner/name] [--repo-dir PATH] [--jobs N] [--prs-file FILE] [pr...]

  --repo owner/name   repo for the gh calls (default: `gh repo view` in --repo-dir)
  --repo-dir PATH     checkout the diff normalizer is read from (default: .)
  --jobs N            concurrent PRs (default: 8)
  --prs-file FILE     read PR numbers from FILE (`-` = stdin)

Exit: 0 = every row is AT or CARRY; 1 = at least one row needs attention; 2 = it
      could not answer at all — usage, bad input, missing normalizer, or a gh
      failure that made EVERY row unreadable. One unreadable row among readable
      ones is reported as a row and exits 1, because the report itself succeeded.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import landability  # noqa: E402  (sibling import by absolute path above)

PR_COL = re.compile(r"^\s*(\d+)\b")


def read_targets(path):
    if path == "-":
        text = sys.stdin.read()
    else:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = PR_COL.match(line)
        if m:
            out.append(m.group(1))
    return out


def dedupe(seq):
    seen = set()
    out = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def build_parser():
    p = argparse.ArgumentParser(
        prog="bulk.py",
        description="Landability report over many PRs (planning only — claims go through the queue tool).",
    )
    p.add_argument("prs", nargs="*", help="PR numbers")
    p.add_argument("--repo", default=None, help="owner/name (default: gh repo view in --repo-dir)")
    p.add_argument("--repo-dir", default=".", help="checkout the diff normalizer is read from (default: .)")
    p.add_argument("--jobs", default="8", help="concurrent PRs (default: 8)")
    p.add_argument("--prs-file", default=None, help="file of PR numbers, first column ('-' = stdin)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        jobs = int(args.jobs)
    except ValueError:
        print(f"bulk: --jobs must be an integer (got {args.jobs!r})", file=sys.stderr)
        return 2
    if jobs < 1:
        print("bulk: --jobs must be >= 1", file=sys.stderr)
        return 2

    targets = list(args.prs)
    if args.prs_file:
        try:
            targets += read_targets(args.prs_file)
        except OSError as exc:
            print(f"bulk: cannot read --prs-file {args.prs_file}: {exc}", file=sys.stderr)
            return 2
    for t in targets:
        if not t.isdigit():
            print(f"bulk: PR must be numeric (got {t!r})", file=sys.stderr)
            return 2
    targets = dedupe(targets)
    if not targets:
        print("bulk: no PRs given — pass numbers, or --prs-file FILE", file=sys.stderr)
        return 2

    repo_dir = os.path.abspath(os.path.expanduser(args.repo_dir))
    try:
        if not os.path.isdir(repo_dir):
            raise landability.Failure(f"--repo-dir is not a directory: {repo_dir}")
        repo = landability.resolve_repo(args.repo, repo_dir)
        normalizer = landability.resolve_normalizer(repo_dir)
    except landability.Failure as exc:
        print(f"bulk: {exc}", file=sys.stderr)
        return 2

    def one(pr):
        try:
            return landability.check(pr, repo, repo_dir, normalizer)
        except landability.Failure as exc:
            return {"pr": pr, "verdict": "BLOCKED(unreadable)", "error": str(exc)}

    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        rows = list(ex.map(one, targets))

    hdr = f"{'pr':>8}  {'verdict':<26} {'binding':<26} {'head':<12} {'mergeState':<11} pending  failed  untested"
    print(f"repo={repo}  prs={len(rows)}")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        if "error" in r:
            print(f"{r['pr']:>8}  BLOCKED(unreadable)         {'-':<26} {'-':<12} {'-':<11} -        -       -")
            continue
        print(
            f"{r['pr']:>8}  {r['verdict']:<26} {r['binding']:<26} {r['head'][:12]:<12} "
            f"{str(r['merge_state']):<11} "
            f"{','.join(r['in_flight'])[:24] or '-':<24} "
            f"{','.join(r['failed'])[:24] or '-':<24} "
            f"{','.join(r['untested'])[:24] or '-'}"
        )
    for r in rows:
        if "error" in r:
            print(f"  {r['pr']}: {r['error']}", file=sys.stderr)

    counts = Counter(r["verdict"] for r in rows)
    print()
    print("verdicts:", dict(sorted(counts.items())))
    landable = sum(1 for r in rows if r["verdict"] in ("AT", "CARRY"))
    print(f"landable now (AT or CARRY): {landable}/{len(rows)}")
    # A row that could not be read is not a row that needs attention — it is a row
    # the report answered nothing about. If NOTHING could be read, this is exit 2
    # ("it could not answer"), so a caller branching on 2 is not silently handed a
    # report whose rows all look like failures. With at least one readable row the
    # report did its job, and 1 means "something needs attention".
    unreadable = sum(1 for r in rows if "error" in r)
    if unreadable == len(rows):
        print(f"bulk: no PR could be read ({unreadable}/{len(rows)} unreadable) — nothing was answered", file=sys.stderr)
        return 2
    return 0 if landable == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
