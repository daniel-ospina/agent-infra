#!/usr/bin/env bash
# mutation harness: each mutant patches ONE claim, then runs the suite.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/mut/beta-progress.py.orig"
cp "$ROOT/mut/beta-progress.py" "$SRC"

run_one() {
  local name="$1" py="$2"
  cp "$SRC" "$ROOT/mut/beta-progress.py"
  python3 - "$ROOT/mut/beta-progress.py" <<PY
import sys, io
p = sys.argv[1]
s = open(p).read()
$py
open(p, "w").write(s)
PY
  local out
  out=$(cd "$ROOT/mut" && timeout 300 uv run --with pytest --python 3.12 python -m pytest \
        test_beta_progress.py -q --confcutdir "$ROOT/mut" --rootdir "$ROOT/mut" \
        -p no:cacheprovider 2>&1 | tail -2 | tr '\n' ' ')
  printf '%-58s %s\n' "$name" "$out"
  cp "$SRC" "$ROOT/mut/beta-progress.py"
}

run_one "M1 drop tmo=min(tmo,left)" '
old = "        tmo = min(tmo, left)\n"
assert old in s, "anchor M1"
s = s.replace(old, "        pass  # MUTANT\n")
'

run_one "M2 drop mergedAt shape branch" '
old = """        if state != "open" and r.get("mergedAt") is not None \\
                and not isinstance(r.get("mergedAt"), str):
            return None
"""
assert old in s, "anchor M2"
s = s.replace(old, "")
'

run_one "M3 drop rest_deadline phase clamp" '
old = "        rest_deadline = min(rest_deadline, _PHASE_DEADLINE)\n"
assert old in s, "anchor M3"
s = s.replace(old, "")
'

run_one "M4 drop spent-clock refusal" '
old = """        if left <= 0:
            return None
"""
assert old in s, "anchor M4"
s = s.replace(old, "")
'

run_one "M5 _repo_prs REST call without repo=" '
old = "        rows = _rest_prs(state, limit=limit, deadline=deadline, repo=repo)\n"
assert old in s, "anchor M5"
s = s.replace(old, "        rows = _rest_prs(state, limit=limit, deadline=deadline)\n")
'

run_one "M6 drop fix-repo dedupe" '
old = """        if _repo == REPO or _repo in seen:
            continue      # dedupe: a repo listed twice is ONE read, never two
        seen.append(_repo)
"""
assert old in s, "anchor M6"
s = s.replace(old, "        seen.append(_repo)\n")
'

run_one "M7 drop phase-clock restore" '
old = """        global _PHASE_DEADLINE
        _PHASE_DEADLINE = self._prev
        return False"""
assert old in s, "anchor M7"
s = s.replace(old, """        global _PHASE_DEADLINE
        return False""")
'

run_one "M8 drop FIX_REPOS validation" '
old = """        if not isinstance(_repo, str) or _repo.count("/") != 1 or not all(_repo.split("/")):
            return None
"""
assert old in s, "anchor M8"
s = s.replace(old, "")
'

run_one "M9 revert falsy-repo refusal to repo or REPO" '
old = """    if repo is None:
        repo = REPO
    elif not isinstance(repo, str) or repo.count("/") != 1 or not all(repo.split("/")):
        return None
"""
assert old in s, "anchor M9"
s = s.replace(old, "    repo = repo or REPO\n")
'

run_one "M10 drop isinstance(rows, list) in _repo_prs" '
old = """    if not isinstance(rows, list):
        return None
    for r in rows:"""
assert old in s, "anchor M10"
s = s.replace(old, """    for r in rows:""")
'

run_one "M11 drop title/headRefName str gate in _repo_prs" '
old = """        for key in ("title", "headRefName"):
            if r.get(key) is not None and not isinstance(r.get(key), str):
                return None
"""
assert old in s, "anchor M11"
s = s.replace(old, "")
'

run_one "M12 fix-repo reads OPEN window only" '
old = """        for _state, _limit in (("open", 500), ("merged", 400)):"""
assert old in s, "anchor M12"
s = s.replace(old, """        for _state, _limit in (("open", 500),):""")
'

run_one "M13 open_prs counts fix-repo rows too" '
old = """    out = {"ts": int(time.time()), "open_prs": len(openpr), "merged_today": merged_today}"""
assert old in s, "anchor M13"
s = s.replace(old, """    out = {"ts": int(time.time()), "open_prs": len(openpr) + len(fix_prs),
           "merged_today": merged_today}""")
'

run_one "M14 compute() never opens the clock" '
old = """    with _phase_clock():
        return _compute()"""
assert old in s, "anchor M14"
s = s.replace(old, """    return _compute()""")
'

run_one "M15 covered() ignores fix-repo rows" '
old = """        for p in openpr + merged + fix_prs:"""
assert old in s, "anchor M15"
s = s.replace(old, """        for p in openpr + merged:""")
'
