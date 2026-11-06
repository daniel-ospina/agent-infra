"""Band probe with the REAL `gh()` (clock + child timeout), faking only `subprocess.run`.

Per read latency LAT: main's ceiling is one 120 s read; the PR's is 60 s for the WHOLE phase.
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile
import time

LAT = float(os.environ.get("LAT", "12"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class R:
    returncode = 0


for label, path in (("main", "mut/bp_main.py"), ("PR  ", "mut/bp_ship.py")):
    bp = load(label.strip(), path)
    bp.CACHE = os.path.join(tempfile.mkdtemp(), "c.json")
    bp._rest_prs = lambda *a, **k: None

    def fake_run(argv, **kw):
        time.sleep(LAT)                                   # the latency of ONE gh read
        if LAT > (kw.get("timeout") or 1e9):
            raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
        payload = ([{"number": 900, "title": "t", "headRefName": "b"}]
                   if argv[1:3] == ("pr", "list") and "open" in argv else
                   [{"number": 10114}])
        r = R()
        r.stdout = json.dumps(payload)
        return r

    bp.subprocess.run = fake_run
    buf = io.StringIO()
    t0 = time.time()
    with contextlib.redirect_stdout(buf):
        bp.main()
    line = buf.getvalue().strip().splitlines()[-1]
    print("%s LAT=%4.1fs/read  %5.1fs  %s"
          % (label, LAT, time.time() - t0, line[:70]))
