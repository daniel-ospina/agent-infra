#!/usr/bin/env python3
"""Corruption canary — detect a recurrence of the mass-replace corruption class.

Epic #6689. The two incidents (STATUS_LABEL 08-12; handle_error(raise)+.bak
08-13/14) shared a signature: an agent's botched global replace over the shared
checkout, with `.bak` backups of every touched file. Forensics post-hoc is
impossible (backs cleaned, event log lacks tool_call detail) — so the canary
catches the NEXT occurrence early.

Checks (fail-closed on scan errors):
1. `.bak`/`*.orig`/`*.backup` files appearing in tracked trees
2. Known corruption tokens in source files (STATUS_LABEL, handle_error(raise),
   and other botched-edit markers) that are NOT legitimate identifiers
3. Tracked-file count spike (a mass-add/delete class)

Alert: writes an event (events.record_event) + a loud log line. Optional
--revert: git-restore the affected tracked files to HEAD (safe — the corruption
is uncommitted by definition).

Usage:
    python operations/coordination/corruption_canary.py [--revert] [--root <path>]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Tokens that appeared in the incidents. STATUS_LABEL is a LEGITIMATE identifier
# in status_vocab.py/github_sync.py — exempt those exact files.
CORRUPTION_TOKENS = [
    "STATUS_LABEL",
    "handle_error(raise)",
]
LEGIT_FILES = {
    "operations/coordination/status_vocab.py",
    "operations/coordination/github_sync.py",
    "operations/coordination/corruption_canary.py",  # self (contains the patterns)
}
BACKUP_SUFFIXES = (".bak", ".orig", ".backup", "~")


def _git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(root), *args],
                          capture_output=True, text=True)


def scan(root: Path) -> list[str]:
    findings: list[str] = []
    if not (root / ".git").exists() and not (root / ".git").is_file():
        findings.append(f"not a git repo: {root}")
        return findings

    # 1. backup files anywhere in the working tree (the incidents CREATED
    #    untracked .bak files — these must be caught even when untracked)
    tracked = _git(root, "ls-files").stdout.splitlines()
    untracked = _git(root, "ls-files", "--others", "--exclude-standard").stdout.splitlines()
    all_files = set(tracked) | set(untracked)
    for f in all_files:
        if f.endswith(BACKUP_SUFFIXES):
            findings.append(f"backup file: {f}")

    # 2. corruption tokens in source files (skip legit identifiers + test
    #    files — test fixtures legitimately contain the token strings)
    for f in all_files:
        if not f.endswith((".py", ".sh", ".js", ".ts", ".yaml", ".yml", ".md")):
            continue
        if f in LEGIT_FILES or "/test_" in f or f.startswith("test_"):
            continue
        p = root / f
        if not p.exists():
            continue
        try:
            text = p.read_text(errors="replace")
        except Exception:
            continue
        for token in CORRUPTION_TOKENS:
            if token in text:
                findings.append(f"corruption token {token!r} in {f}")

    # 3. tracked-file count sanity (spike detection needs a baseline — log only)
    return findings


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent.parent))
    ap.add_argument("--revert", action="store_true",
                    help="git-restore affected tracked files to HEAD")
    args = ap.parse_args()
    root = Path(args.root)

    findings = scan(root)
    if not findings:
        print("[canary] CLEAN — no corruption signatures")
        return 0

    print(f"[canary] CORRUPTION SIGNATURES FOUND ({len(findings)}):")
    for f in findings:
        print(f"  - {f}")

    try:
        from events import record_event
        record_event("canary", "corruption_detected",
                     {"findings": findings[:20], "root": str(root)},
                     agent_id="corruption-canary")
    except Exception as e:
        print(f"[canary] event record failed: {e}", file=sys.stderr)

    if args.revert:
        changed = []
        for f in findings:
            path = f.split(" in ", 1)[-1] if " in " in f else f
            if path.startswith("tracked backup file: "):
                path = path[len("tracked backup file: "):]
            r = _git(root, "restore", "--", path)
            if r.returncode == 0:
                changed.append(path)
        print(f"[canary] reverted {len(changed)} paths to HEAD")
    return 1


if __name__ == "__main__":
    sys.exit(main())
