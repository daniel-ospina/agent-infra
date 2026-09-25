import sys, importlib.util, os
ROOT = "/tmp/rev4625"
sys.path.insert(0, ROOT)
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location("thrn", ROOT + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    m.test_onboarding_blocking_helpers_are_offloaded_or_declared()
    print("PASS  test_onboarding_blocking_helpers_are_offloaded_or_declared")
except AssertionError as e:
    print("FAIL ", str(e)[:400])
