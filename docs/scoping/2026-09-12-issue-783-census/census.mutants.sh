#!/usr/bin/env bash
# census.mutants.sh — proves census.selftest.sh is not blind.
#
# Cycle-6 review finding: the artifact claimed "11 mutants, all caught" but committed
# no sweep script, so the count was unverifiable prose. This script IS the sweep.
#
# For every mutant it writes a broken copy of census.py to a temp dir, points the
# self-test at it, and requires a NON-ZERO exit. Then it requires the REAL census to
# pass. A mutant that survives is a blind spot and fails this script.
#
# Usage: bash census.mutants.sh [path/to/census.py]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="${1:-$SELF_DIR/census.py}"
SELFTEST="$SELF_DIR/census.selftest.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

python3 - "$CENSUS" "$T" <<'PY'
import sys
src = open(sys.argv[1]).read()
out = sys.argv[2]
GATE = '                if v.strip().startswith(PREFIX) and "Alive state:" in v:'
assert GATE in src, "admission gate not found — census.py changed shape; update this sweep"

def mut(name, s):
    assert s != src, f"mutant {name} is a NO-OP (pattern did not match) — sweep is stale"
    open(f"{out}/{name}.py", "w").write(s)

mut("m01_dead",      src.replace('        stack = [o]', '        stack = []'))
mut("m02_gate",      src.replace(GATE, '                if PREFIX in v and "Alive state:" in v:'))
mut("m03_files",     src.replace('        files.add(f)', '        files.add("x")'))
mut("m04_gitstate",  src.replace('            if re.search(r"(^|\\s)(branch|headSha|worktree|dirty)=", v):\n                        git_state += 1', '            pass'))
mut("m21_branch",    src.replace("stderr_mentions_branch += 1", "pass"))
mut("m24_branch_name", src.replace("stderr_names_branch += 1", "pass"))
mut("m22_branch_zero", src.replace("if re.search(BRANCH_TEXT, se):", "if False:"))
mut("m23_branch_narrow", src.replace("HUB DISCIPLINE|on branch", "XXNOMATCHXX"))
mut("m25_name_as_text", src.replace('r\'(?:baseline|current|on branch)\\s+"([^"]+)"|detached HEAD\'', 'r\'HUB DISCIPLINE\''))
mut("m05_inflight",  src.replace('if re.search(r"toolsInFlight=[1-9]", v):\n                        inflight += 1', 'pass'))
mut("m06_saw",       src.replace('if "everSawTool=true" in v:\n                        saw_true += 1\n                    elif "everSawTool=false" in v:\n                        saw_false += 1',
                                  'if "everSawTool=true" in v:\n                        saw_false += 1\n                    elif "everSawTool=false" in v:\n                        saw_true += 1'))
mut("m07_stdout",    src.replace('if len(tail) > 1 and tail[1].strip() == "":', 'if len(tail) > 1:'))
mut("m08_caps",      src.replace('caps[m.group(1)] += 1', 'caps["0"] += 1'))
mut("m09_trace",     src.replace('if "trace=[" in v:\n                        trace_present += 1', 'pass'))
mut("m10_abs",       src.replace('stderr_abs += 1', 'pass'))
mut("m11_worktree",  src.replace('stderr_worktree += 1', 'pass'))
mut("m12_nonempty",  src.replace("stderr_nonempty += 1", "pass"))
mut("m13_root",      src.replace('stderr_child_root += 1', 'pass'))
mut("m14_forroot",   src.replace('for r in found:', 'for r in found[:0]:'))
mut("m15_distinct",  src.replace("print(f\"  stderr_names_child_root={stderr_child_root} (distinct_roots={len(child_roots)})\")",
                                 "print(f\"  stderr_names_child_root={stderr_child_root} (distinct_roots={len(child_roots) + 1})\")"))
mut("m16_dup",       src.replace("duplicate_payload_strings = len(all_payloads) - len(set(all_payloads))", "duplicate_payload_strings = 0"))
mut("m17_prefix",    src.replace("alive_prefix_collision_files = sum(1 for c in alive_prefix.values() if max(c.values()) > 1)", "alive_prefix_collision_files = 0"))
mut("m18_perday",    src.replace("        per_day[day.group(1) if day else \"?\"] += 1", "        pass"))
mut("m19_payloads",  src.replace("                    total += 1\n                    yes = True", "                    total += 0\n                    yes = True"))
mut("m20_nonzero",   src.replace("total == 0", "total == 999999"))
print("mutants written")
PY

FAIL=0
COUNT=0
for f in "$T"/m*.py; do
  n="$(basename "$f" .py)"
  COUNT=$((COUNT + 1))
  if bash "$SELFTEST" "$f" >/dev/null 2>&1; then
    echo "  ❌ $n SURVIVED — the self-test is blind to this mutant"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $n caught"
  fi
done

if ! bash "$SELFTEST" "$CENSUS" >/dev/null 2>&1; then
  echo "  ❌ the REAL census failed its own self-test"
  FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "❌ MUTANT SWEEP FAILED — $FAIL problem(s) out of $COUNT mutants"
  exit 1
fi
echo "✅ mutant sweep clean — $COUNT/$COUNT mutants caught, real instrument passes"
