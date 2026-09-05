---
disable-model-invocation: true
name: config-validation
description: "Thin wrapper that runs relevant check scripts based on changed files. Maps file types to validation scripts (migrations → check-migration-*, skills → check-skill-lint, etc.). Invoked by test-routing when domain=config."
domain: engineering
subjects.team: organisation-design-team
allowed-tools: read bash grep find
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Config Validation — Check Script Gate

## Overview

Runs the appropriate check scripts based on what files changed. Thin wrapper — delegates to existing `scripts/check-*`.

**Announce at start:** "I'm using the config-validation skill to run config checks."

Invoked by `test-routing` when domain=config is detected.

### When to Use

- Migration file changes
- Edge function changes
- Skill file changes (SKILL.md)
- Config/env changes
- CI/workflow changes

### When NOT to Use

- Pure code changes with no config impact → routed to code verification
- Documentation-only changes → skip

## Process

### Step 1 — Identify Changed Files

From the PR or feature diff, list changed files:

```bash
git diff --name-only origin/main...HEAD
```

### Step 2 — Map Files to Check Scripts

| File Pattern | Check Script | What It Validates |
|---|---|---|
| `supabase/migrations/*.sql` | `check-migration-order.cjs` | Timestamp ordering |
| `supabase/migrations/*.sql` | `check-migration-drift` *[planned — not yet ported]* | Schema consistency |
| `supabase/functions/**` | `check-edge-schema` *[planned — not yet ported]* | Edge function schemas |
| `supabase/functions/**` | `check-edge-function-selects` *[planned — not yet ported]* | Query patterns |
| `skills/**` | `check-skill-lint.mjs` | Skill file conventions |
| `docs/**` | `check-wiki-lint` *[planned — not yet ported]* | Wiki formatting |
| `src/**` (i18n) | `check-i18n-coverage` *[planned — not yet ported]* | Translation coverage |
| `*.test.*` changes | `check-test-regression.cjs` | Test flakiness |

> *[planned]* rows are tracked in the test-routing Skill Registry (Status `new (#NNNN)`) and are **not** yet in `scripts/` — running them reports missing-non-blocking per graceful degradation below. Do NOT remove them from the map when they land; port the script into `scripts/` (canonical tree) and drop the marker.

### Step 3 — Run Applicable Scripts

```bash
# ponytail: run each applicable check, collect results
for script in <applicable-scripts>; do
  if [ -f "scripts/$script" ]; then
    case "$script" in
      *.mjs|*.cjs|*.js) node "scripts/$script" 2>&1 ;;   # Node gates
      *.sh)             bash "scripts/$script" 2>&1 ;;  # shell gates
      *)                bash "scripts/$script" 2>&1 ;;  # extensionless → legacy bash
    esac
  else
    echo "⚠️  MISSING: scripts/$script not found — check not run (see Step 2 planned rows)"
  fi
  echo "EXIT:$?"  # capture exit code
  echo ""
done
```

### Step 4 — Return Report

```markdown
## Config Validation Report

**Files changed:** 3 (2 migrations, 1 skill)

### Script Results
| Script | Result | Output |
|--------|--------|--------|
| check-migration-order | ✅ PASS | All timestamps in order |
| check-migration-drift | ✅ PASS | No schema drift detected |
| check-skill-lint | ❌ FAIL | Missing frontmatter field: `domain` |

### Summary
**Passed:** 2/3 | **Failed:** 1/3
**Action:** Fix check-skill-lint failure before merge.
```

**Graceful degradation:** If a script is missing or errors, report the error, don't crash. Missing checks are not blocking — but they must be SEEN (a silently skipped gate is a no-op). Scripts marked *[planned]* in Step 2 are expected to be missing until ported.

## Pipeline Handoff

**Invoked by:** `test-routing` (domain=config)
**Dispatches to:** `scripts/check-*` based on file mapping
**Consumed by:** `code-review` (verification gate check)

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Migration order check | Deploy fails with timestamp collision |
| Migration drift check | Schema drifts from source of truth |
| Skill lint check | Malformed skill files break agent workflows |
| Test regression check | Flaky tests accumulate, CI becomes unreliable |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
