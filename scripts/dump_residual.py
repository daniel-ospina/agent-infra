import sys, importlib.util, pathlib
repo = "/Users/danielospina/Documents/GitHub/tortoise/.worktrees/4625-read-legs"
sys.path.insert(0, repo)
import os
os.chdir(repo)
spec = importlib.util.spec_from_file_location("thrn", repo + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
hits = m._onboarding_inline_calls()
print("TOTAL HITS:", len(hits))
resid = m._KNOWN_ONBOARDING_INLINE_RESIDUAL
for src, body, line, callee in hits:
    mark = "RESID" if (src.endswith("hosted_api.py") and body in resid) else "OFFENDER"
    print(f"{mark:9} {src.split('/')[-1]}:{line}  body={body}  callee={callee}")
