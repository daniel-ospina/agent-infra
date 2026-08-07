#!/usr/bin/env python3
"""
Test isolation CI check (#102) — scan test files for dangerous patterns.

Fails if a test file:
  1. Runs `DETACH DELETE n` (destructive teardown) AND
  2. Defaults TORTOISE_DB_URI to a production-looking graph
     (docker://host:6379|6380|16379/tortoise)

This prevents the class of incident where test teardowns wiped the
production graph (5,748 points lost, 2026-08-05).
"""
import re
import sys
from pathlib import Path

# Scan the repo we were run FROM, not the repo the script file lives in.
# .resolve() follows the scripts/ symlink (manifest.json kind: symlink) that
# product repos use, so __file__ would resolve into agent-infra/scripts →
# agent-infra/tests (nonexistent) → scans nothing → CI false-pass.
# Like every sibling check, this script is invoked from the repo root, so
# cwd-based resolution is correct whether or not scripts/ is a symlink.
TESTS_DIR = Path.cwd() / "tests"
PRODUCTION_PORTS = {"6379", "6380", "16379"}

# Patterns
DETACH_DELETE_RE = re.compile(r"DETACH\s+DELETE\s+n")
PROD_URI_RE = re.compile(
    r"docker://[^@\s]*@?[^/\s]*:(\d+)/tortoise[\"'\s]"
)


def check_file(path: Path) -> list[str]:
    issues = []
    text = path.read_text()
    has_detach = bool(DETACH_DELETE_RE.search(text))
    prod_uris = set()
    for m in PROD_URI_RE.finditer(text):
        port = m.group(1)
        if port in PRODUCTION_PORTS:
            prod_uris.add(f":{port}/tortoise")
    if has_detach and prod_uris:
        issues.append(
            f"{path.name}: destructive teardown (DETACH DELETE n) + "
            f"production URI(s) {sorted(prod_uris)} — use an isolated test graph"
        )
    return issues


def main() -> int:
    issues = []
    for path in sorted(TESTS_DIR.glob("*.py")):
        if path.name == "conftest.py":
            continue
        issues.extend(check_file(path))
    if issues:
        print("⛔ Test isolation violations found:")
        for i in issues:
            print(f"  - {i}")
        print("\nFix: point tests at an isolated graph (test_<name>) "
              "or set ALLOW_DESTRUCTIVE_TESTS=1 explicitly.")
        return 1
    print("✅ No test isolation violations.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
