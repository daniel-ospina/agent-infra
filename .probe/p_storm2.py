"""F2 probe: an unreadable OPTIONAL fix repo, on a box whose tracker reads all succeed.

Measured against the shipped module and against `main` for the same tracker state.
`main` never reads the fix repo, so this state does not exist for it -- that is the point.
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


bp = load("bp", "mut/beta-progress.py")
bp.CACHE = os.path.join(tempfile.mkdtemp(), "beta-progress.json")
gh_calls, rest_urls = [], []


def gh(*a):
    gh_calls.append(a)
    if a[:2] == ("pr", "list"):
        repo = a[a.index("--repo") + 1]
        if repo != bp.REPO:
            return None                      # the fix repo is gone / refused
        return ([{"number": 900, "title": "t", "headRefName": "b"}]
                if a[a.index("--state") + 1] == "open" else [])
    return [{"number": 10114}]               # tracker issue list: fine


def rest(url, tok, timeout=None):
    rest_urls.append(url)
    return None if "agent-infra" in url else []   # the fix repo answers nothing


bp.gh, bp._token, bp._rest_get_json = gh, (lambda: "t"), rest

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    bp.main()
beat1 = (len(gh_calls), len(rest_urls))
with contextlib.redirect_stdout(buf):
    bp.main()
beat2 = (len(gh_calls) - beat1[0], len(rest_urls) - beat1[1])

print("printed: %s" % buf.getvalue().strip().splitlines()[-1])
print("beat 1: %d gh spawns, %d REST requests, cache written: %s"
      % (beat1[0], beat1[1], os.path.exists(bp.CACHE)))
print("beat 2: %d gh spawns, %d REST requests, cache written: %s"
      % (beat2[0], beat2[1], os.path.exists(bp.CACHE)))
print("(TTL is %ds: a SUCCESSFUL compute costs one 6-read phase per %d min)"
      % (bp.TTL, bp.TTL // 60))
print("tracker-derived values that WERE valid at the refusal point: "
      "open_prs=%d, merged_today=0, P0/P1 open counts known" % 1)
