"""What does an unreadable FIX repo cost, versus main?

The whole line is refused (by design, per the comment) -- but `main()` does not write the cache
when `compute()` returns None, so the refusal is not cached: every beat (~2 min) pays all six
`gh` reads again, against a bucket that is rate-limited in exactly the state the REST fallback
exists for. Probes: (1) tracker data IS in hand at the refusal point, (2) no cache is written,
(3) the next beat repeats every read.
"""
import importlib.util, pathlib, json, os, tempfile
spec = importlib.util.spec_from_file_location("bp", pathlib.Path("mut/beta-progress.py"))
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)

tmp = tempfile.mkdtemp()
bp.CACHE = os.path.join(tmp, "beta-progress.json")
calls = []

def gh(*a):
    calls.append(a)
    if a[:2] == ("pr", "list"):
        repo = a[a.index("--repo") + 1]
        if repo == bp.REPO:
            return [{"number": 900, "title": "t", "headRefName": "b"}] if a[a.index("--state")+1] == "open" else []
        return []                       # the fix repo ANSWERS, empty
    return [{"number": 10114}]          # tracker issue list
bp.gh = gh
bp._rest_prs = lambda *a, **k: None

# now make ONLY the fix repo unreadable (both sources), as a renamed/private repo would be
def gh2(*a):
    calls.append(a)
    if a[:2] == ("pr", "list") and a[a.index("--repo") + 1] != bp.REPO:
        return None                     # GraphQL refused / repo gone
    return gh(*a)
bp.gh = gh2

print("beat 1: exit=%r" % bp.main())
n1 = len(calls)
print("  gh spawns: %d   cache written: %s" % (n1, os.path.exists(bp.CACHE)))
print("beat 2 (2 min later): exit=%r" % bp.main())
n2 = len(calls) - n1
print("  gh spawns: %d   cache written: %s" % (n2, os.path.exists(bp.CACHE)))
print("cost per beat while an OPTIONAL repo is unreadable: %d gh reads "
      "(main: 4 reads, cached 30 min once it succeeds)" % n2)
