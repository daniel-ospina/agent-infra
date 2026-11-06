"""Band probe: at 12 s per `gh` read (well above the measured 0.7-3.3 s, below the 63 s
13-lane worst case), what does each version print?
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import time

LAT = 12.0


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


for label, path in (("main", "mut/bp_main.py"), ("PR  ", "mut/bp_ship.py")):
    bp = load(label.strip(), path)
    bp.CACHE = os.path.join(tempfile.mkdtemp(), "c.json")

    def gh(*a, _lat=LAT):
        time.sleep(_lat)
        if a[:2] == ("pr", "list"):
            return ([{"number": 900, "title": "t", "headRefName": "b"}]
                    if a[a.index("--state") + 1] == "open" else [])
        return [{"number": 10114}]

    bp.gh = gh
    bp._rest_prs = lambda *a, **k: None
    buf = io.StringIO()
    t0 = time.time()
    with contextlib.redirect_stdout(buf):
        bp.main()
    print("%s  %5.1fs  %s" % (label, time.time() - t0,
                              buf.getvalue().strip().splitlines()[-1][:78]))
