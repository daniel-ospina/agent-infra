#!/usr/bin/env python3
"""Per-PR verdict from check-runs: newest attempt per (app.slug, workflow, job name)."""
import json, subprocess, sys, re

REPO = "daniel-ospina/agent-infra"
GREEN = {"success", "neutral", "skipped"}


def api(path):
    out = subprocess.run(["gh", "api", path, "--paginate"], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"gh api failed {path}: {out.stderr[:300]}")
    # --paginate emits one JSON doc per page
    dec = json.JSONDecoder()
    s = out.stdout
    docs, i = [], 0
    while i < len(s):
        while i < len(s) and s[i] in " \n\r\t":
            i += 1
        if i >= len(s):
            break
        obj, i = dec.raw_decode(s, i)
        docs.append(obj)
    return docs


def main(prs):
    wf_cache = {}
    for pr in prs:
        j = api(f"repos/{REPO}/pulls/{pr}")[0]
        sha = j["head"]["sha"]
        merge_state = j["mergeable_state"] if "mergeable_state" in j else "?"
        docs = api(f"repos/{REPO}/commits/{sha}/check-runs?per_page=100&filter=all")
        runs = []
        for d in docs:
            runs.extend(d.get("check_runs", []))
        groups = {}
        for r in runs:
            app = (r.get("app") or {}).get("slug") or "none"
            m = re.match(r"https://github\.com/[^/]+/[^/]+/actions/runs/(\d+)", r.get("details_url") or "")
            wf = "no-actions"
            if m:
                rid = m.group(1)
                if rid not in wf_cache:
                    try:
                        wf_cache[rid] = subprocess.run(
                            ["gh", "api", f"repos/{REPO}/actions/runs/{rid}", "--jq", ".name"],
                            capture_output=True, text=True).stdout.strip() or f"run{rid}"
                    except Exception:
                        wf_cache[rid] = f"run{rid}"
                wf = wf_cache[rid]
            groups.setdefault((app, wf, r["name"]), []).append(r)
        red, inflight, green = [], [], []
        for (app, wf, name), rs in groups.items():
            rs.sort(key=lambda r: r["id"])
            r = rs[-1]
            st = r.get("status")
            cc = r.get("conclusion")
            label = f"{wf} / {name}" + (f" [{cc}]" if cc else f" [{st}]")
            if st != "completed":
                inflight.append(label)
            elif cc in GREEN:
                green.append(label)
            else:
                red.append(label)
        verdict = "RED" if red else ("IN FLIGHT" if inflight else ("GREEN" if groups else "NO CHECKS"))
        print(f"PR {pr} sha={sha[:10]} mergeable={j.get('mergeable')} state={merge_state} -> {verdict}")
        for x in sorted(red):
            print(f"    RED      {x}")
        for x in sorted(inflight):
            print(f"    pending  {x}")
        print(f"    ({len(green)} green groups)")


if __name__ == "__main__":
    main(sys.argv[1:])
