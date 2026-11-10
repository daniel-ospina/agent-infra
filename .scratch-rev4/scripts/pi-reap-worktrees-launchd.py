#!/usr/bin/env python3
"""launchd entry point for the worktree reaper (agent-infra #1311, #1095).

WHY THIS FILE EXISTS
--------------------
macOS TCC is per-binary, and it denies a launchd-spawned `bash` the read of a
script under `~/Documents` ("Operation not permitted") and a launchd-spawned
`git` the read of a repo there ("not a git repository"). The reaper's whole job
is `git -C <repo> ...` against the tortoise checkout, so an entry point of
`bash <script>` cannot work no matter WHERE the script lives: farming the script
out of `~/Documents` fixes the script read and nothing else.

The binary that DOES hold the access is the checkout's own interpreter — the
repo's `.venv/bin/python`, the same binary the already-working
com.tortoise.embedded-reaper agent runs. So launchd starts that interpreter
here, and this process performs the FILE READ (which it is allowed to do) and
hands the script to bash on stdin. bash, and the `git` it spawns, inherit the
access from this process.

This mirrors the configuration that is recorded as PROVEN working end-to-end
(`WORKTREES=454 ... GH=ok` in ~/.pi/agent/state/pi-reap-worktrees.log), rather
than a `bash <script>` entry point that the recorded control experiment already
falsified.

USAGE (every argument except `--script` is forwarded to the reaper):
    pi-reap-worktrees-launchd.py --script <reaper.sh> --repo <path> --dry-run

`--script` may appear anywhere; a `--` separator is accepted but not required,
and everything else is passed through untouched. The launcher is parsed by hand
rather than with argparse: `argparse.REMAINDER` does NOT absorb unknown
OPTIONALS, so `--script x --repo y` would abort with "unrecognized arguments:
--repo" (exit 2) — which is exactly the form the launchd template uses.

`--dry-run` is deliberately NOT hard-coded here: the template owns the arming
decision, so the flag lives in one place.
"""
from __future__ import annotations

import os
import subprocess
import sys


def _split(argv: list[str]) -> tuple[str | None, list[str]]:
    """Pull `--script` out; forward everything else verbatim."""
    script: str | None = None
    forward: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--script":
            i += 1
            if i < len(argv):
                script = argv[i]
        elif a.startswith("--script="):
            script = a.split("=", 1)[1]
        elif a == "--":
            forward.extend(argv[i + 1:])
            break
        else:
            forward.append(a)
        i += 1
    return script, forward


def main(argv: list[str] | None = None) -> int:
    script, forward = _split(list(sys.argv[1:] if argv is None else argv))
    if not script:
        print("pi-reap-worktrees-launchd: --script <path> is required",
              file=sys.stderr)
        return 2

    script = os.path.expanduser(script)
    try:
        with open(script, "rb") as fh:
            # `bash -s` consumes the script from stdin, so bash never has to
            # open the file itself — that read is the one TCC denies it.
            return subprocess.run(
                ["/bin/bash", "-s", "--", *forward], stdin=fh).returncode
    except OSError as exc:
        print(f"pi-reap-worktrees-launchd: cannot read {script}: {exc}",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
