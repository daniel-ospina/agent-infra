#!/usr/bin/env bash
# tests/search-cost/run.sh — the repo-contract harness for #1069.
#
# The invariant under test (both directions):
#   the corpus teaches only primitives the guard allows;
#   the guard refuses only the shape the corpus no longer teaches.
#
# A forward-only check would be satisfied vacuously by a classify() that
# returns null for everything, so (iii)/(iv) assert the reverse direction too.
#
# Everything runs through the REAL classifier: `extensions/search-guard/index.ts`
# is loaded by `--classify` (module-load-hooks.mjs, the #744 harness), never a
# copy — a suite that imports a helper stays green while index.ts is broken.
#
# Primitives: find/grep/awk/sed/node only. `rg`/`fd` are absent on ubuntu-latest
# and are never used here (they are guidance-only in the corpus).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
ok()   { echo "   ✅ $1"; }
bad()  { echo "   ❌ $1"; fails=$((fails + 1)); }

echo "== search-cost harness (#1069) =="

# ── fixture: a hub that carries the vendored/parallel trees ─────────────────
FIX="$(mktemp -d)"
trap 'chmod -R u+rwX "$FIX" 2>/dev/null; rm -rf "$FIX"' EXIT
HUB="$FIX/hub"   # one level BELOW the mktemp root: on Linux, `mktemp -d` itself
                 # is /tmp/tmp.XXXX — a direct child of /tmp, i.e. an R1 root.
mkdir -p "$HUB/.worktrees/w/node_modules" "$HUB/src" "$FIX/mutant" "$FIX/fixture"
printf 'MARKER\n' > "$HUB/.worktrees/w/node_modules/dep.js"

classify() { # classify <command> [cwd]
  node extensions/search-guard/test.mjs --classify "$1" --cwd "${2:-$HUB}" 2>/dev/null
  return $?
}

# ── (vii) fixture controls, before the corpus scan ──────────────────────────
# An untagged fence (2 of the rewritten sites sit in one) must be scanned.
cat > "$FIX/fixture/SKILL.md" <<'MD'
# Fixture skill
```
grep -rn p .
```
MD
# Exit codes are the contract: 1 = a violation was found (the expected red),
# 2 = the scan itself could not run — which must NEVER be read as "caught".
node tests/search-cost/scan.mjs "$FIX/fixture" --cwd "$HUB" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "positive control: an untagged fence carrying \`grep -rn p .\` is caught"
elif [ "$rc" -eq 2 ]; then
  bad "positive control: the scan could not run (exit 2) — not a pass"
else
  bad "positive control: an untagged fence carrying \`grep -rn p .\` was NOT caught"
fi

# A resolvable, vendored-free multi-operand grep is a false-positive control.
if classify "grep -rE '/Users/x' skills/ extensions/ scripts/" >/dev/null; then
  ok "scope control: a resolvable non-vendored multi-operand grep is ALLOW"
else
  bad "scope control: a resolvable non-vendored multi-operand grep was blocked"
fi

# A gitignored .npmrc-style file operand must survive (no traversal to bound).
if classify "grep -n -e '_authToken' .npmrc .pypirc" >/dev/null; then
  ok "scope control: a file-operand grep (no traversal) is ALLOW"
else
  bad "scope control: a file-operand grep was blocked"
fi

# ── (ii)–(v) the corpus scan ────────────────────────────────────────────────
SCAN=(skills templates/AGENTS.base.md AGENTS.md)
if node tests/search-cost/scan.mjs "${SCAN[@]}" --cwd "$HUB"; then
  ok "corpus scan: every taught command is allowed off the \`### Avoid\` block"
else
  bad "corpus scan: a taught command is refused by the guard"
fi

# ── acceptance (b): the pin must FAIL if the teaching is removed ─────────────
# Revert one rewritten file to HEAD in a scratch dir — never in the working tree
# (the main-worktree-guard refuses in-place discards, by design).
git show HEAD:skills/security-review/references/injection.md > "$FIX/mutant/SKILL.md"
node tests/search-cost/scan.mjs "$FIX/mutant" --cwd "$HUB" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "fails-if-removed: the pre-rewrite injection.md is flagged (the pin bites)"
elif [ "$rc" -eq 2 ]; then
  bad "fails-if-removed: the scan could not run (exit 2) — not a pass"
else
  bad "fails-if-removed: the pre-rewrite injection.md was NOT flagged"
fi

# ── (v) the contract is present in both AGENTS files ────────────────────────
for f in templates/AGENTS.base.md AGENTS.md; do
  if grep -q '^## Search' "$f" && grep -q 'git grep' "$f" && grep -q 'rg -n' "$f"; then
    ok "contract: \`## Search\` (naming rg + git grep) present in $f"
  else
    bad "contract: \`## Search\` missing or incomplete in $f"
  fi
  for h in '### Use' '### Avoid'; do
    if grep -q "^$h" "$f"; then ok "contract: $h in $f"; else bad "contract: $h missing in $f"; fi
  done
done

echo
if [ "$fails" -eq 0 ]; then
  echo "✅ search-cost harness: all checks passed"
  exit 0
fi
echo "❌ search-cost harness: $fails check(s) failed"
exit 1
