"""Same scenario (tracker healthy) on `main`: the line is printed and CACHED, so the next beat
spawns nothing. Against the PR, the same tracker data is discarded and every beat pays again."""
import importlib.util, pathlib, os, tempfile
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

for label, path in (("main", "base/beta-progress.py"), ("PR  ", "mut/beta-progress.py")):
    bp = load("bp_" + label.strip(), path)
    bp.CACHE = os.path.join(tempfile.mkdtemp(), "c.json")
    calls = []
    def gh(*a, _c=calls):
        _c.append(a)
        if a[:2] == ("pr", "list"):
            return ([{"number": 900, "title": "t", "headRefName": "b"}]
                    if a[a.index("--state") + 1] == "open" else [])
        return [{"number": 10114}]
    bp.gh = gh
    bp._rest_prs = lambda *a, **k: None
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        bp.main(); n1 = len(calls); bp.main(); n2 = len(calls) - n1
    print("%s beat1=%s beat2=%s cache=%s | %s"
          % (label, n1, n2, os.path.exists(bp.CACHE), buf.getvalue().strip().splitlines()[-1][:70]))
