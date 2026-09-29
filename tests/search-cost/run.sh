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
mkdir -p "$HUB/.worktrees/w/node_modules" "$HUB/src" "$FIX/mutant" "$FIX/fixture" "$FIX/clean"
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
# Exit codes are the contract: 1 = a rule violation was found, 2 = the scan itself
# could not run — which must NEVER be read as "caught".
#
# Both fixture checks below also assert the VIOLATION TEXT, not just the exit code.
# A single-file fixture carries no `## Search` anchors, so the (iii)/(iv)
# non-vacuity rules would fire for ANY input — the pre-fix harness read that exit 1
# as "caught", so its positive control and its fails-if-removed pin both passed on
# a file the guard had not actually refused (and would have passed on an innocuous
# one). `--require-anchors` now scopes (iii)/(iv) to the corpus scan, and this
# helper requires the catch itself: rule (ii), naming the command.
scan_has_violation() { # scan_has_violation <dir> <expected substring>
  local out rc
  out="$(node tests/search-cost/scan.mjs "$1" --cwd "$HUB" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ]; then bad "scan of $1 could not run (exit 2) — not a pass"; return 1; fi
  if [ "$rc" -ne 1 ]; then bad "scan of $1 did not flag a violation (rc=$rc)"; return 1; fi
  if ! printf '%s' "$out" | grep -qF '(ii) taught command is REFUSED'; then
    bad "scan of $1 exited 1 without rule (ii) — a non-vacuity exit is not a catch"; return 1
  fi
  if ! printf '%s' "$out" | grep -qF "$2"; then
    bad "scan of $1 flagged a violation that does not name \`$2\`"; return 1
  fi
  return 0
}
if scan_has_violation "$FIX/fixture" 'grep -rn p .'; then
  ok "positive control: an untagged fence carrying \`grep -rn p .\` is caught by rule (ii)"
fi

# ...and the SAME scan of an innocuous file must be clean, or the exit code the
# controls read is not discriminating at all.
printf '# Fixture skill\n```\necho hello\n```\n' > "$FIX/clean/SKILL.md"
if node tests/search-cost/scan.mjs "$FIX/clean" --cwd "$HUB" >/dev/null 2>&1; then
  ok "negative control: an innocuous fixture scans clean (the exit code discriminates)"
else
  bad "negative control: an innocuous fixture was flagged — the fixture controls are vacuous"
fi

# ── the scanner's own argv contract (D4) ───────────────────────────────────
# `--cwd` FIRST must be honoured (the pre-fix `cwdAt > 0` fell back to the repo
# root) and with no `--cwd` at all argv[0] must NOT be dropped (the pre-fix target
# filter read `i !== cwdAt + 1` ⇒ `i !== 0`, so `scan.mjs <dir>` scanned nothing).
if node tests/search-cost/scan.mjs --cwd "$HUB" "$FIX/clean" >/dev/null 2>&1; then
  ok "scanner argv: a leading \`--cwd\` is honoured (the clean fixture stays clean)"
else
  bad "scanner argv: a leading \`--cwd\` was ignored — the cwd fell back to the repo root"
fi
out="$(node tests/search-cost/scan.mjs "$FIX/fixture" 2>&1)"
if printf '%s' "$out" | grep -q 'scanned 1 commands in 1 files'; then
  ok "scanner argv: a single target with no \`--cwd\` is scanned (argv[0] not dropped)"
else
  bad "scanner argv: a single target with no \`--cwd\` was not scanned — $(printf '%s' "$out" | grep -m1 scanned)"
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
# The contract is asserted from a REPO cwd (the fixture hub). The `### Use`
# primitives are bounded — by the index, an explicit non-root start point, or an
# explicit exclusion — and R1 deliberately refuses the same shapes from `$HOME` or
# `/`: a home-wide recursive walk is the very habit this guards (`~/Library`,
# `~/.cache`, every checkout). A session whose cwd is `$HOME` gets the block
# reason naming a bounded replacement; the R1 exemption is not on the table.
SCAN=(skills templates/AGENTS.base.md AGENTS.md)
if node tests/search-cost/scan.mjs "${SCAN[@]}" --cwd "$HUB" --require-anchors; then
  ok "corpus scan: every taught command is allowed off the \`### Avoid\` block"
else
  bad "corpus scan: a taught command is refused by the guard"
fi

# ── acceptance (b): the pin must FAIL if the teaching is removed ─────────────
# The mutant is a MECHANICAL INVERSION of the live rewrite — the exact shape the
# #1069 corpus pass replaced (`git grep -n -e P -- 'g'` → `grep -rn P --include='g'`).
# Deriving it from the live file keeps the pin from going stale, and the inversion
# is asserted non-empty: if the site stops teaching the rewritten shape the pin
# FAILS (exit 3) instead of passing vacuously. The pre-fix version copied `HEAD:`,
# which after the rewrite IS the clean file — so its "mutant" was never a mutant.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  const src = readFileSync(process.argv[1], "utf8");
  const out = [];
  for (const line of src.split("\n")) {
    const m = /^git grep -n -e (.*?) -- (.*)$/.exec(line);
    if (!m) continue;
    const globs = m[2].split(" ").filter(Boolean).map((g) => `--include=${g}`).join(" ");
    out.push(`grep -rn ${m[1]} ${globs}`);
  }
  if (out.length < 4) {
    console.error(`pin: the site no longer teaches a rewritable \`git grep\` line (found ${out.length})`);
    process.exit(3);
  }
  writeFileSync(process.argv[2], "```bash\n" + out.join("\n") + "\n```\n");
' skills/security-review/references/injection.md "$FIX/mutant/SKILL.md"
if [ $? -eq 3 ]; then
  bad "fails-if-removed: could not derive a mutant — the site no longer teaches the rewritten shape"
elif scan_has_violation "$FIX/mutant" 'grep -rn'; then
  ok "fails-if-removed: the pre-rewrite shape is flagged by rule (ii) (the pin bites)"
fi
# ...and the live site scanning CLEAN is what makes that a differential pin.
if node tests/search-cost/scan.mjs skills/security-review/references/injection.md --cwd "$HUB" >/dev/null 2>&1; then
  ok "reverse direction: the rewritten site scans clean (only the inversion is refused)"
else
  bad "reverse direction: the rewritten injection.md does not scan clean"
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
