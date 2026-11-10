#!/usr/bin/env python3
"""Publish the live cmux workspace set to state/live-workspaces.txt for the beat to consume.

WHY THIS EXISTS: the beat runs under launchd, and cmux REFUSES it --
    "ERROR: Access denied - only processes started inside cmux can connect"
-- so `scripts/lane-actions.py` cannot discover the live fleet from the beat's context. Any process
started INSIDE cmux (a lane's pi, or the orchestrator) CAN. So the knowledge is published here and read
there. Run this from inside cmux; it is a no-op failure otherwise (which is the honest outcome).

The file is freshness-checked by the consumer (LIVE_WS_MAX_AGE_S = 900 s). If it goes stale, the
workspace-existence filter goes INERT and SAYS SO on stderr -- it never silently pretends to work.

Usage:  /usr/bin/python3 scripts/publish-live-workspaces.py [--quiet]
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, os.pardir, "state", "live-workspaces.txt")
CMUX_CANDIDATES = (
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
    "/usr/local/bin/cmux",
    "/opt/homebrew/bin/cmux",
)


def main() -> int:
    quiet = "--quiet" in sys.argv
    cmux = next((p for p in CMUX_CANDIDATES if os.path.isfile(p) and os.access(p, os.X_OK)), "cmux")
    p = subprocess.run([cmux, "workspace", "list", "--json", "--id-format", "both"],
                       capture_output=True, text=True)
    if p.returncode != 0 or not (p.stdout or "").strip():
        sys.stderr.write(
            "publish-live-workspaces: cmux unusable (rc=%s): %r\n"
            "  This process is NOT inside cmux, so it cannot publish. The beat's filter will stay\n"
            "  INERT (and will say so). Run this from a lane or the orchestrator instead.\n"
            % (p.returncode, (p.stderr or "").strip()[:200]))
        return 1

    d = json.loads(p.stdout)
    ws = d if isinstance(d, list) else d.get("workspaces", [])
    # ⛔ PUBLISH THE TITLE TOO (2026-10-10, #7957 H4). A workspace UUID OUTLIVES the NAME it was
    # created for, so a UUID-only list cannot tell a live lane from a renamed one. Measured
    # 2026-10-10: three of the six lanes the beat offered as IDLE had a live UUID under a DIFFERENT
    # title -- `land-6260` was `P1 data-loss`, `Merigng PR` was `PR 2`, `\u03c0 - land-lane-1` was
    # `5285 Decision`. The consumer's UUID-existence filter passed all three, so the beat spent
    # dispatches on lanes that no longer exist. The title is the identity; the UUID is only the key.
    rows = sorted({((w.get("id") or "").strip().upper(), (w.get("title") or "").strip())
                   for w in ws if w.get("id")})

    # Atomic: a half-written list must never be published, because the consumer treats a fresh file
    # as authoritative -- a truncated one would silently DROP live lanes.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(OUT)))
    with os.fdopen(fd, "w") as fh:
        fh.write("# live cmux workspaces, published %s by %s\n"
                 % (subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                                   capture_output=True, text=True).stdout.strip(),
                    os.environ.get("USER", "?")))
        fh.write("# UUID<TAB>title per line; consumed by scripts/lane-actions.py "
                 "(LIVE_WS_MAX_AGE_S=900)\n")
        fh.write("# the TITLE is required, not decoration: a UUID alone cannot tell a live lane from\n"
                 "# one that was renamed out from under it (#7957 H4). A missing title reads as\n"
                 "# UNKNOWN and is never filtered on.\n")
        for i, t in rows:
            fh.write("%s\t%s\n" % (i, t))
    os.replace(tmp, OUT)

    if not quiet:
        print("published %d live workspaces -> %s" % (len(ids), os.path.normpath(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
