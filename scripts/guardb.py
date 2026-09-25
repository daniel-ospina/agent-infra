import sys, importlib.util, os
ROOT = "/tmp/rev4625"
sys.path.insert(0, ROOT)
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location("trrlr", ROOT + "/tests/test_read_routes_loop_responsiveness.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for n in sys.argv[1:]:
    try:
        getattr(m, n)()
        print("PASS ", n)
    except AssertionError as e:
        print("FAIL ", n, ":", str(e)[:500])
