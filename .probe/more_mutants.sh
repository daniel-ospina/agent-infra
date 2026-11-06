set -u
ROOT="$PWD"
SRC="$ROOT/mut/beta-progress.py.orig"
run_one() {
  local name="$1" py="$2"
  cp "$SRC" "$ROOT/mut/beta-progress.py"
  python3 - "$ROOT/mut/beta-progress.py" <<PY
import sys
p = sys.argv[1]; s = open(p).read()
$py
open(p, "w").write(s)
PY
  out=$(cd "$ROOT/mut" && timeout 300 uv run --with pytest --python 3.12 python -m pytest \
        test_beta_progress.py -q --confcutdir "$ROOT/mut" --rootdir "$ROOT/mut" \
        -p no:cacheprovider 2>&1 | tail -1)
  printf '%-56s %s\n' "$name" "$out"
  cp "$SRC" "$ROOT/mut/beta-progress.py"
}
run_one "M17 skip a failed fix repo instead of refusing" '
old = """            rows = _repo_prs(_repo, _state, _limit, rest_deadline)
            if rows is None:
                return None
            fix_prs.extend(rows)
"""
assert old in s, "anchor M17"
s = s.replace(old, """            rows = _repo_prs(_repo, _state, _limit, rest_deadline)
            if rows is None:
                continue
            fix_prs.extend(rows)
""")
'
run_one "M19 drop the REPO skip in dedupe (re-read tracker)" '
old = "        if _repo == REPO or _repo in seen:"
assert old in s, "anchor M19"
s = s.replace(old, "        if _repo in seen:")
'
run_one "M20 spent clock returns [] not None" '
old = """        if left <= 0:
            return None
"""
assert old in s, "anchor M20"
s = s.replace(old, """        if left <= 0:
            return []
""")
'
run_one "M21 REST fix-repo reads get a FRESH budget" '
old = "            rows = _repo_prs(_repo, _state, _limit, rest_deadline)"
assert old in s, "anchor M21"
s = s.replace(old, "            rows = _repo_prs(_repo, _state, _limit, time.time() + REST_BUDGET_S)")
'
run_one "M22 phase clock never bounds the child (flat 120)" '
old = """    tmo = 120.0
    if _PHASE_DEADLINE is not None:
        left = _PHASE_DEADLINE - time.time()
        if left <= 0:
            return None
        tmo = min(tmo, left)
"""
assert old in s, "anchor M22"
s = s.replace(old, """    tmo = 120.0
""")
'
