import sys, importlib.util, os, traceback
ROOT = sys.argv[1]
sys.path.insert(0, ROOT)
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location("thrn", ROOT + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
names = sys.argv[2:] if len(sys.argv) > 2 else [
    "test_onboarding_blocking_helpers_are_offloaded_or_declared",
    "test_capture_session_recording_gate_is_offloaded",
    "test_onboarding_offload_wrappers_are_used",
]
for n in names:
    fn = getattr(m, n)
    try:
        fn()
        print(f"PASS  {n}")
    except AssertionError as e:
        print(f"FAIL  {n}: {str(e)[:600]}")
    except Exception as e:
        print(f"ERROR {n}: {type(e).__name__}: {str(e)[:300]}")
