"""The `isinstance(rows, list)` gate in `_repo_prs`: does removing it change behaviour?
`gh()` returns `json.loads` of stdout, so a non-iterable payload (a bare JSON number) is reachable.
"""
import importlib.util, pathlib


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


for label, path in (("as shipped   ", "mut/bp_ship.py"),
                    ("gate removed ", "mut/bp_M10.py")):
    bp = load(label.strip(), path)
    for payload in (5, True, "not a list", {"message": "Not Found"}):
        bp.gh = lambda *a, _p=payload: _p
        bp._rest_prs = lambda *a, **k: None
        try:
            r = bp._repo_prs("x/y", "open", 10, None)
            print("%s payload=%-20r -> %r" % (label, payload, r))
        except Exception as exc:
            print("%s payload=%-20r -> RAISES %s: %s"
                  % (label, payload, type(exc).__name__, exc))
