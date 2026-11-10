#!/bin/bash
# enforce-protocol-table.sh — validate dangerous-ops manifest coverage (issue #239)
# Ported from daniel-ospina/eldato @ 49afc61f (the port is based on the default-branch
# version as of 2026-08-13; blob fb4c5357), adapted to agent-infra layout.
#
# Three passes:
#   1. PASS 1 (NEW gate — the original never had it): every dangerous-ops manifest skill
#      must resolve to a real SKILL.md file (`skills/<name>/SKILL.md` in agent-infra,
#      `operations/skills/<name>/SKILL.md` in consumer repos). Rationale: the skill-enforcer
#      extension gates on these skills — a missing file produces a permanent confusing block
#      (the agent cannot satisfy a gate for a file that does not exist), and a MISSING
#      MANIFEST is the truly silent failure (the extension loads an empty gate map and
#      enforces nothing), which this script covers fail-closed below.
#   2. PASS 2 (forward): manifest skills must appear in AGENTS.md's protocol table — runs
#      ONLY when AGENTS.md exists AND its table is populated (placeholder = contains
#      `| ... | ... | ... |` or a `...` consequence cell — see skip-message line numbers
#      for comment-block matches). Skip-with-note otherwise.
#   3. PASS 3 (reverse): populated-table rows naming skills not in the manifest are flagged
#      (all skill refs per row are checked).
#
# Exit-status parity with eldato's original where both run; documented divergences:
#   - missing AGENTS.md / placeholder table -> skip-with-note (original exits 1)
#   - Pass 1 (file existence) is a new gate
#   - missing manifest stays fail-closed (exit 1) ONLY when no manifest is resolvable at
#     ANY of the three locations (repo-local x2, then the agent-infra manifest actually in
#     force). A consumer repo without a repo-local manifest is NOT "the extension enforces
#     nothing" — skill-enforcer resolves its gate map from the extension's own install
#     location, i.e. agent-infra's manifest, for every repo (see below). Fail-closing there
#     guarded a failure mode that cannot occur, at the cost of failing closed on repos that
#     have no repo-local manifest. Which repos carry a repo-local manifest is deliberately NOT
#     asserted here — the set moves as worktrees come and go, and an earlier "27 of 30" figure
#     was wrong (it counted agent-infra's worktree dirs as org repos).
#     For a repo with NO repo-local manifest, location 3 now resolves the in-force manifest, so
#     the fail-closed branch no longer fires for it. Where a repo-local manifest exists, it
#     wins and location 3 is never consulted.
#
#     SCOPE — the fallback removes the FALSE block; it does not make every consumer pass.
#     Pass 1 still requires the in-force manifest's skills to resolve under the repo's skill
#     prefix. That is satisfied by the standard consumer layout (`skills/` symlinked to
#     agent-infra — how tortoise/premise-labs are set up) and deliberately NOT satisfied by a
#     consumer carrying a partial REAL `skills/` dir: such a repo cannot satisfy the gate at
#     all, which is precisely the permanent-confusing-block case Pass 1 exists to catch.
#     A silent pass would still be wrong — the audit keeps running, it just runs against the
#     manifest that is actually enforcing (#3462).
#
# Layout detection (independent, not coupled):
#   - manifest: `enforcement/dangerous-ops.txt` (agent-infra) -> `operations/enforcement/dangerous-ops.txt` (consumer)
#     -> `${AGENT_INFRA_PATH}/enforcement/dangerous-ops.txt` (in-force fallback, #3462)
#   - skill prefix: `skills/` (agent-infra) -> `operations/skills/` (consumer); prefer `skills/` when both exist
#
# Consumer-layout caveat: consumer repos may SYMLINK `operations/skills/<name>` to an
# external agent-infra checkout (mode 120000, absolute path). Where those targets are
# absent (e.g. a CI checkout), Pass 1 reports them MISSING — expected behavior, not a
# bug; treat Pass 1 results in symlinked consumer layouts accordingly.
#
# Usage: bash scripts/ci/enforce-protocol-table.sh [--help]
#   ROOT env override supported (external fixture harness): ROOT=/tmp/fix bash scripts/ci/enforce-protocol-table.sh
#   Exit: 0 = clean (or documented skip), 1 = audit failure, 2 = usage error.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/ci/enforce-protocol-table.sh [--help]

Validates the dangerous-ops manifest against real skill files (Pass 1) and the
AGENTS.md protocol table (Passes 2/3). ROOT env var overrides repo-root
resolution (fixture harness). Exit 0 = clean/skip, 1 = audit failure, 2 = usage.
EOF
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then usage; exit 0; fi
[[ $# -eq 0 ]] || { echo "Error: unknown argument(s): $*" >&2; usage >&2; exit 2; }

# ── ROOT resolution (ROOT override -> git rev-parse -> cd-up fallback) ─────────
# The `echo "$(cd ...)"` wrapper is REQUIRED: bare `git || cd && pwd` parses as
# `(git || cd) && pwd`, so `pwd` runs even when git succeeds and ROOT gets two lines.
ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")}"

# ── Layout detection (independent, decoupled) ─────────────────────────────────
# Resolution order:
#   1. $ROOT/enforcement/dangerous-ops.txt           (agent-infra layout)
#   2. $ROOT/operations/enforcement/dangerous-ops.txt (consumer layout)
#   3. ${AGENT_INFRA_PATH}/enforcement/dangerous-ops.txt — the manifest actually IN FORCE
#
# Why 3 exists (#3462): skill-enforcer resolves its gate map next to the REAL
# module file — `realpathSync(__filename)`, not `__dirname` (#1321), because pi
# loads extensions through jiti, which keeps the SYMLINK path in `__dirname`.
# So a consumer repo whose extension is symlinked in from agent-infra is enforced
# by agent-infra's manifest, and never reads the per-repo path. `${AGENT_INFRA_PATH}`
# is now only a FALLBACK, used when no manifest sits next to the module (a COPY
# rather than a symlink), and the extension announces that loudly. A consumer repo
# with no repo-local manifest is therefore enforced by the global one, and the
# audit must validate against it rather than fail-closed on its absence.
# Repo-local wins when present (a repo declaring its own manifest is audited against that).
# Fail-closed survives for the one genuinely dangerous case: NO manifest anywhere
# (e.g. a bare CI checkout with AGENT_INFRA_PATH unset), where the extension really would
# run with an empty gate map and enforce nothing.
MANIFEST=""
for _candidate in \
  "$ROOT/enforcement/dangerous-ops.txt" \
  "$ROOT/operations/enforcement/dangerous-ops.txt"; do
  if [ -f "$_candidate" ]; then
    MANIFEST="$_candidate"
    break
  fi
done
# The fallback probe is GUARDED, not concatenated into the loop above: with AGENT_INFRA_PATH
# unset/empty, "${AGENT_INFRA_PATH:-}/enforcement/dangerous-ops.txt" expands to the absolute
# path /enforcement/dangerous-ops.txt — a ROOT-LEVEL probe. On a root-owned CI container that
# path is plantable, and a planted manifest listing the repo's own skills would make the audit
# "pass" against a manifest that is not in force — converting the one branch this resolution
# order exists to keep CLOSED into a fail-open one (#3462 review, P2).
#
# Assumes AGENT_INFRA_PATH resolves to the same checkout the skill-enforcer extension is
# installed from (its realpath target), so that "the manifest in force" is literally true. If
# AGENT_INFRA_PATH points at a different worktree, this audits that worktree's manifest while
# the extension enforces the main checkout's — the two coincide in the standard environment.
if [ -z "$MANIFEST" ] && [ -n "${AGENT_INFRA_PATH:-}" ] \
   && [ -f "$AGENT_INFRA_PATH/enforcement/dangerous-ops.txt" ]; then
  MANIFEST="$AGENT_INFRA_PATH/enforcement/dangerous-ops.txt"
fi
if [ -z "$MANIFEST" ]; then
  echo "❌ No enforcement manifest resolvable (tried: $ROOT/enforcement/, $ROOT/operations/enforcement/, ${AGENT_INFRA_PATH:-<AGENT_INFRA_PATH unset>}/enforcement/)"
  echo "   Fail-closed: with no manifest anywhere skill-enforcer loads an empty gate map and"
  echo "   enforces nothing, and this audit has nothing to check (issue #239 D1)."
  exit 1
fi
case "$MANIFEST" in
  "$ROOT/enforcement/dangerous-ops.txt"|"$ROOT/operations/enforcement/dangerous-ops.txt") ;;
  *) echo "ℹ️  No repo-local manifest — auditing against the manifest in force: $MANIFEST" ;;
esac

SKILL_PREFIX="skills"
if [ ! -d "$ROOT/skills" ] && [ -d "$ROOT/operations/skills" ]; then
  SKILL_PREFIX="operations/skills"
fi
if [ ! -d "$ROOT/$SKILL_PREFIX" ]; then
  echo "❌ No skills directory found under $ROOT (tried skills/ and operations/skills/)"
  exit 2
fi
# Prefer agent-infra layout when both exist (D1 precedence).

AGENTS="$ROOT/AGENTS.md"

# ── Pass 1 — manifest entries must resolve to real skill files (NEW gate) ─────
errors=0
checked=0
skill_list=""
while IFS= read -r line || [ -n "$line" ]; do
  trimmed=$(printf '%s' "$line" | sed 's/#.*//' | xargs)
  [ -z "$trimmed" ] && continue
  skill_name=$(printf '%s' "$trimmed" | awk -F'#' '{print $1}' | xargs)
  [ -z "$skill_name" ] && continue
  skill_list="$skill_list$skill_name"$'\n'
done < "$MANIFEST"

# Dedupe (bash 3.2-safe — no declare -A). sed '/^$/d' exits 0 even with no lines
# (unlike grep -v '^$', whose exit 1 under set -e would silently kill the script).
unique_skills=$(printf '%s' "$skill_list" | sort -u | sed '/^$/d')

if [ -z "$unique_skills" ]; then
  echo "⚠️  Manifest has no entries (comment/empty only) — nothing to audit."
fi

while IFS= read -r skill_name; do
  [ -z "$skill_name" ] && continue
  checked=$((checked + 1))
  if [ ! -f "$ROOT/$SKILL_PREFIX/$skill_name/SKILL.md" ]; then
    echo "❌ MISSING SKILL FILE: $skill_name — manifest entry but no $SKILL_PREFIX/$skill_name/SKILL.md"
    errors=$((errors + 1))
  fi
done <<< "$unique_skills"

echo "Pass 1: checked $checked unique manifest skills, $errors missing files"

# ── Pass 2/3 — manifest <-> AGENTS.md protocol table (conditional) ────────────
# Runs ONLY when AGENTS.md exists AND its table is populated. Placeholder detection:
# the template-derived table contains `| ... | ... | ... |` or `...` consequence cells.
# NOTE: line-based grep also matches commented-out template rows — the skip message
# prints the matched lines so a comment-block match is identifiable.
table_checked=0
table_errors=0
if [ ! -f "$AGENTS" ]; then
  echo "Pass 2/3: skipped — AGENTS.md not found (untracked/generated; CI fresh checkouts lack it). Pass 1 still gated."
else
  placeholder_hits=$(grep -nE '\| \.\.\. \| \.\.\. \| \.\.\. \||^\s*\|[^|]*\|[^|]*\| \.\.\. \|' "$AGENTS" || true)
  if [ -n "$placeholder_hits" ]; then
    echo "Pass 2/3: skipped — AGENTS.md protocol table matches the template placeholder (matched lines):"
    printf '%s\n' "$placeholder_hits" | head -5
    echo "   (possibly inside a comment block). Pass 1 still gated."
  else
    run_table_passes=1
  fi
fi

if [ "${run_table_passes:-0}" = "1" ]; then
  # Pass 2 (forward): every manifest skill appears in the table (fixed-string match — -F)
  while IFS= read -r skill_name; do
    [ -z "$skill_name" ] && continue
    table_checked=$((table_checked + 1))
    if ! grep -qF "$SKILL_PREFIX/$skill_name/SKILL.md" "$AGENTS"; then
      echo "❌ MISSING: $skill_name not in AGENTS.md protocol table"
      table_errors=$((table_errors + 1))
    fi
  done <<< "$unique_skills"

  # Pass 3 (reverse): ALL skill refs per row must be in the manifest (grep -oE per row)
  reverse_errors=0
  reverse_checked=0
  sed_prefix=$(printf '%s' "$SKILL_PREFIX" | sed 's|/|\\/|g')
  while IFS= read -r md_line; do
    # extract every `SKILL_PREFIX/<name>/SKILL.md` occurrence in the row
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      skill=$(printf '%s' "$ref" | sed -n "s/.*${sed_prefix}\\/\\([^/]*\\)\\/SKILL\\.md.*/\\1/p")
      [ -z "$skill" ] && continue
      reverse_checked=$((reverse_checked + 1))
      if ! grep -Fqx "$skill" <<<"$unique_skills"; then
        echo "❌ REVERSE-MISSING: $skill — in AGENTS.md table but not in manifest"
        reverse_errors=$((reverse_errors + 1))
      fi
    done < <(printf '%s\n' "$md_line" | grep -oE "$SKILL_PREFIX/[^/]+/SKILL\.md" || true)
  done < <(grep -E '^\s*\|.*'"$SKILL_PREFIX"'/' "$AGENTS" || true)

  echo "Pass 2/3: $table_checked manifest skills checked in table, $table_errors missing; $reverse_checked table rows, $reverse_errors reverse-missing"
  errors=$((errors + table_errors + reverse_errors))
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
if [ "$errors" -gt 0 ]; then
  echo "❌ FAIL: $errors total error(s)"
  exit 1
fi
echo "✅ PASS: manifest → skills ($checked checked), AGENTS.md table ($table_checked checked, $table_errors errors)"
exit 0
