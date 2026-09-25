import sys, importlib.util, os, ast
ROOT = "/tmp/rev4625"
sys.path.insert(0, ROOT); os.chdir(ROOT)
spec = importlib.util.spec_from_file_location("thrn", ROOT + "/tests/test_health_ready_nonblocking.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tree = ast.parse(m.HOSTED_API.read_text())
helpers = m._ONBOARDING_BLOCKING_HELPERS
onloop = m._reachable_on_loop_functions(tree)   # module-level, on-loop

def scan_nested(outer):
    """Replicate Guard B's nested-def-on-loop walk, collect helper calls."""
    hits = []
    nested = {s.name for s in ast.walk(outer)
              if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef)) and s is not outer}
    # fixpoint of nested defs invoked on the loop
    def direct(stmts, descend):
        found = set()
        def w(cur):
            if isinstance(cur, ast.Call):
                if m._callee_name(cur.func) in m._ONBOARDING_OFFLOAD_BOUNDARIES:
                    return
                nm = m._callee_name(cur.func)
                if nm in nested:
                    found.add(nm)
            for ch in ast.iter_child_nodes(cur):
                if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    if getattr(ch, "name", None) in descend:
                        for st in ch.body: w(st)
                    continue
                w(ch)
        for st in stmts:
            if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if getattr(st, "name", None) in descend:
                    for inner in st.body: w(inner)
                continue
            w(st)
        return found
    onloop_nested = set()
    while True:
        inv = direct(outer.body, onloop_nested)
        new = inv - onloop_nested
        if not new: break
        onloop_nested |= new
    # now find helper calls inside on-loop nested defs
    def walk(cur):
        if isinstance(cur, ast.Call):
            if m._callee_name(cur.func) in m._ONBOARDING_OFFLOAD_BOUNDARIES:
                return
            nm = m._callee_name(cur.func)
            if nm in helpers:
                hits.append((nm, cur.lineno))
        for ch in ast.iter_child_nodes(cur):
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if getattr(ch, "name", None) in onloop_nested:
                    for st in ch.body: walk(st)
                continue
            walk(ch)
    for st in outer.body:
        if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if getattr(st, "name", None) in onloop_nested:
                for inner in st.body: walk(inner)
            continue
        walk(st)
    return hits

total = 0
for name, node in onloop.items():
    h = scan_nested(node)
    if h:
        total += len(h)
        print(f"{name}: {h}")
print("nested-def-on-loop helper hits MISSED by Guard A:", total)
