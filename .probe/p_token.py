"""'ONE clock bounds the WHOLE phase' -- except `_token()`, whose `gh auth token` child carries
its own flat 5 s, and which is re-read (un-memoised) once per REST read."""
import importlib.util, pathlib, os, tempfile
os.environ.pop("GH_TOKEN", None); os.environ.pop("GITHUB_TOKEN", None)
os.environ["GH_CONFIG_DIR"] = tempfile.mkdtemp()        # no hosts.yml -> gh auth token branch
spec = importlib.util.spec_from_file_location("bp", pathlib.Path("mut/beta-progress.py"))
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)

spawned = []
def fake_run(argv, **kw):
    spawned.append((os.path.basename(argv[0]), " ".join(argv[1:3]), kw.get("timeout")))
    import subprocess as sp
    raise sp.TimeoutExpired(argv, kw.get("timeout"))     # a slow `gh auth token`
bp.subprocess.run = fake_run
bp.gh = lambda *a: None                                  # every GraphQL read refused
bp.PHASE_BUDGET_S = 2
bp.compute()
print("token children: %d" % len(spawned))
for s in spawned: print("   ", s)
print("=> %d x %ss of child timeout OUTSIDE the phase clock (%ss)"
      % (len(spawned), {t for *_, t in spawned}, bp.PHASE_BUDGET_S))
