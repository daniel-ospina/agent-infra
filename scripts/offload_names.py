import sys, importlib.util, os
ROOT = "/tmp/rev4625"
sys.path.insert(0, ROOT)
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location("thrn", ROOT + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
import ast
tree = ast.parse(m.HOSTED_API.read_text())
names = m._offloaded_callable_names(tree)
print("offloaded_callable_names:", sorted(names))
print()
print("INTERSECT blocking helpers:", sorted(names & m._ONBOARDING_BLOCKING_HELPERS))
onloop = m._reachable_on_loop_functions(tree)
print("on_loop count:", len(onloop))
