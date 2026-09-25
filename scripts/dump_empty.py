import sys, importlib.util, pathlib, os
repo = "/Users/danielospina/Documents/GitHub/tortoise/.worktrees/4625-read-legs"
sys.path.insert(0, repo)
os.chdir(repo)
spec = importlib.util.spec_from_file_location("thrn", repo + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
HOSTED = m.HOSTED_API.name
hits = m._onboarding_inline_calls()
m._KNOWN_ONBOARDING_INLINE_RESIDUAL = frozenset()
offenders = [h for h in hits if not (h[0] == HOSTED and h[1] in m._KNOWN_ONBOARDING_INLINE_RESIDUAL)]
print("hits:", len(hits), "offenders_empty_residual:", len(offenders))
bodies = sorted({h[1] for h in hits})
print("unique bodies:", len(bodies))
print(bodies)
