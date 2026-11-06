"""Does PHASE == 2*REST guarantee the REST arm is NOT clipped by the phase clock?

The comment at PHASE_BUDGET_S says: 'it is exactly 2x `REST_BUDGET_S`, so the REST arm fits
inside it rather than being clipped by it.'  The test pins only the CONSTANT relation.
Probe: keep PHASE = 2*REST, spend part of the phase in a gh read (a timeout on a slow box),
then measure the budget the REST arm is actually handed.
"""
import importlib.util, pathlib, time
spec = importlib.util.spec_from_file_location("bp", pathlib.Path("mut/beta-progress.py"))
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)

bp.PHASE_BUDGET_S = 2       # exactly 2 x REST_BUDGET_S below
bp.REST_BUDGET_S = 1
real_clock_s = bp.PHASE_BUDGET_S

def slow_gh(*a):
    if a[:2] == ("pr", "list"):
        time.sleep(1.2)     # ONE gh read eats 60% of a 2 s phase (a 45 s read of a 60 s phase)
        return None
    return []

handed = []
bp.gh = slow_gh
bp._token = lambda: "t"
bp._rest_get_json = lambda url, tok, timeout=None: []          # REST answers fine
def fake_rest(state, limit=100, deadline=None, repo=None):
    handed.append((state, repo, None if deadline is None else round(deadline - time.time(), 2)))
    return [] if state == "open" else []
bp._rest_prs = fake_rest

t0 = time.time()
bp.compute()
print("PHASE_BUDGET_S=%s  REST_BUDGET_S=%s  (PHASE == 2*REST: %s)"
      % (bp.PHASE_BUDGET_S, bp.REST_BUDGET_S, bp.PHASE_BUDGET_S == 2 * bp.REST_BUDGET_S))
for state, repo, left in handed:
    print("REST read %-7s repo=%-22r handed %.2fs of a %.0fs REST budget"
          % (state, repo, left if left is not None else -1, bp.REST_BUDGET_S))
print("CLIPPED BELOW REST_BUDGET_S:", any(l is not None and l < bp.REST_BUDGET_S - 0.05 for _, _, l in handed))
