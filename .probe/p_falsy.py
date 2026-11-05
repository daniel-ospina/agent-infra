import importlib.util, pathlib, time
spec = importlib.util.spec_from_file_location("bp", pathlib.Path("mut/beta-progress.py"))
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)
urls = []
bp._token = lambda: "t"
bp._rest_get_json = lambda url, tok, timeout=None: (urls.append(url) or [])
for bad in ("", False, 0, "agent-infra", "a/b/c", "daniel-ospina/", "/x", None):
    r = bp._rest_prs("open", limit=100, deadline=time.time()+5, repo=bad)
    print("repo=%-24r -> %-6r requests=%d" % (bad, r, len(urls)))
    if bad is None:
        print("   url:", urls[-1] if urls else None)
        urls.clear()
