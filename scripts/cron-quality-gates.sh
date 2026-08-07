#!/usr/bin/env bash
# cron-quality-gates.sh — periodic quality gates for agent-infra.
#
# Dispatched by skills/test-routing (Skill Registry) as:
#   scripts/cron-quality-gates.sh arch      # (#6463)
#   scripts/cron-quality-gates.sh mutation  # (#6460)
#
# Subcommands:
#   arch      — verify every script dispatched by pipeline skills exists in
#               scripts/ (the symlinked canonical tree). Missing scripts are
#               exactly the class of bug where a gate silently no-ops (issue
#               #100): a skill runs `bash scripts/foo.sh` → "No such file",
#               gate never runs, work ships unchecked. Explicitly known-planned
#               scripts and product-repo scripts are reported, not failed.
#   mutation  — run every extensions/*/test.mjs and reject tests that cannot
#               fail: a test with zero assertion markers is a mutation that
#               always survives — it proves nothing.
#
# Exit codes: 0 = clean, 1 = violations found, 2 = usage/script error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/cron-quality-gates.sh <arch|mutation>

  arch      Verify every `scripts/<name>` reference in skills/**/SKILL.md
            resolves to an existing file in scripts/. Fails on missing
            core-workflow scripts; reports known-planned and product-repo
            script references without failing.
  mutation  Run every extensions/*/test.mjs; fail on non-running or vacuous
            (assertion-free) tests.
  -h|--help Print this help.

Exit: 0 clean, 1 violations, 2 usage error.
EOF
}

# ── arch — skill → script dispatch integrity ────────────────────────────────
# Scripts referenced by pipeline skills that are intentionally NOT in the
# agent-infra canonical tree:
#   * Planned under a tracked issue (registry Status = "new (#NNNN)").
#   * Product-repo scripts referenced only by product-pipeline skills
#     (carousel/content pipeline) — they resolve in the product repo where
#     those pipelines run.
KNOWN_PLANNED="check-coverage-pruning.cjs:#6461 subjects-labels.cjs:superseded-by-swarm-Supabase-SOR(alignment-issue) subjects-labels.test.cjs:superseded-with-subjects-labels.cjs"
PRODUCT_PIPELINE_SKILL_PATTERNS=(
  '/carousel-' '/google-slides' '/art-director' '/carousel-designer' '/content-'
)

is_product_pipeline_skill() {
  local path="$1"
  local p
  for p in "${PRODUCT_PIPELINE_SKILL_PATTERNS[@]}"; do
    [[ "$path" == *"$p"* ]] && return 0
  done
  return 1
}

arch_gate() {
  local violations=0 planned=0 external=0 ok=0
  local -a violation_list=()
  local -a planned_list=() external_list=()
  local seen=()
  local skill_file ref token refs

  echo "=== cron-quality-gates arch ==="
  echo "Scanning skills/**/SKILL.md for scripts/ references…"

  while IFS= read -r skill_file; do
    [[ "$skill_file" == *"ARCHIVE"* || "$skill_file" == *"_deprecated"* ]] && continue
    local skill_dir
    skill_dir="$(dirname "$skill_file")"

    refs=$(grep -oE '(^|[^A-Za-z0-9_.-])scripts/[A-Za-z0-9_.-]+' "$skill_file" 2>/dev/null | sed -E 's/^[^A-Za-z0-9_.-]//' || true)
    [[ -n "$refs" ]] || continue

    for ref in $refs; do
      token="${ref#scripts/}"
      # Skip globs / variables / dangling dashes (e.g. `scripts/check-*` → `check-`)
      [[ "$token" == *"*"* || "$token" == *"\$"* || "$token" == *"-" ]] && continue
      [[ "$token" == *.sh || "$token" == *.cjs || "$token" == *.mjs || "$token" == *.js || "$token" == *.py ]] || continue

      local key="$token:$skill_dir"
      local k
      for k in "${seen[@]:-}"; do [[ "$k" == "$key" ]] && continue 2; done
      seen+=("$key")

      if [[ -f "scripts/$token" ]]; then
        ok=$((ok + 1))
        continue
      fi

      if [[ "$KNOWN_PLANNED" == *"$token:"* ]]; then
        planned=$((planned + 1))
        planned_list+=("$token ($skill_file) — known: ${KNOWN_PLANNED#*$token:}")
        continue
      fi

      if is_product_pipeline_skill "$skill_file"; then
        external=$((external + 1))
        external_list+=("$token ($skill_file) — product-repo script, resolves in product repo")
        continue
      fi

      violations=$((violations + 1))
      violation_list+=("$token ($skill_file) — MISSING from scripts/; gate will silently no-op")
    done
  done < <(find "$ROOT/skills" -name 'SKILL.md' -type f 2>/dev/null || true)

  echo ""
  echo "✅ ${ok} script reference(s) resolved."
  [[ $planned -gt 0 ]] && printf 'ℹ️  %d known-planned:\n' "$planned" && printf '   %s\n' "${planned_list[@]}"
  [[ $external -gt 0 ]] && printf 'ℹ️  %d product-repo (non-failing):\n' "$external" && printf '   %s\n' "${external_list[@]}"

  if [[ $violations -gt 0 ]]; then
    echo ""
    echo "❌ VIOLATIONS — pipeline skills dispatch missing scripts:"
    printf '   ❌ %s\n' "${violation_list[@]}"
    echo ""
    echo "Fix: create the script in scripts/ (canonical tree) or remove the reference."
    echo "A skill that dispatches a nonexistent script silently no-ops its gate."
    exit 1
  fi

  echo ""
  echo "✅ arch gate clean — every core-workflow script reference resolves."
  exit 0
}

# ── mutation — vacuous-test detection ───────────────────────────────────────
mutation_gate() {
  local failures=0 passed=0 vacuous=0
  local -a failure_list=() vacuous_list=()
  local test_file

  echo "=== cron-quality-gates mutation ==="
  echo "Running extensions/*/test.mjs (mutation-survival detection)…"

  while IFS= read -r test_file; do
    local name
    name="$(basename "$(dirname "$test_file")")"

    if node "$test_file" >/tmp/cron-mutation-out.$$ 2>&1; then
      : # test ran — check assertions below
    else
      local rc=$?
      failures=$((failures + 1))
      failure_list+=("$name — test run FAILED (exit $rc)")
      sed 's/^/     /' /tmp/cron-mutation-out.$$ | head -5
      continue
    fi

    # A passing test with no assertion markers is vacuous — a mutation of the
    # subject would survive it. It proves nothing.
    if ! grep -qE '✅|❌|\b(assert|expect|ok|fail|equal|deepEqual|throws|rejects)\b' "$test_file"; then
      vacuous=$((vacuous + 1))
      vacuous_list+=("$name — test.mjs has no assertion markers; cannot fail, mutations survive")
      continue
    fi

    passed=$((passed + 1))
  done < <(find "$ROOT/extensions" -name 'test.mjs' -type f 2>/dev/null || true)
  rm -f /tmp/cron-mutation-out.$$

  echo ""
  echo "✅ ${passed} test(s) ran with assertions."
  [[ $vacuous -gt 0 ]] && printf '❌ %d vacuous test(s):\n' "$vacuous" && printf '   %s\n' "${vacuous_list[@]}"
  [[ $failures -gt 0 ]] && printf '❌ %d failing test(s):\n' "$failures" && printf '   %s\n' "${failure_list[@]}"

  if [[ $failures -gt 0 || $vacuous -gt 0 ]]; then
    echo ""
    echo "❌ mutation gate failed — a passing-but-assertion-free (or broken) test"
    echo "   means mutations survive: coverage claims are meaningless."
    exit 1
  fi

  echo ""
  echo "✅ mutation gate clean — all extension tests can fail (real assertions)."
  exit 0
}

# ── dispatch ────────────────────────────────────────────────────────────────
case "${1:-}" in
  arch)     arch_gate ;;
  mutation) mutation_gate ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "Error: unknown subcommand '${1:-}'" >&2
    usage >&2
    exit 2
    ;;
esac
