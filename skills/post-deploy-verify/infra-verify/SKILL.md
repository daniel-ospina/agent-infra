---
name: infra-verify
description: "Script-based verification for infrastructure, skills, and config changes. Unlike web/desktop clickthrough, infra has no UI — verification is automated script validation. Invoked by post-deploy-verify router for infra surface PRs."
domain: engineering
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read bash grep find
version: 1.0.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Infra Verification

**Announce at start:** "I'm running infra verification — validating scripts, skills, and config."

## Purpose

Run infrastructure-level validation checks against merged infra changes. Unlike web/desktop surfaces, infra has no UI to click through — verification is **script-based validation**. This is intentional: infra changes (skills, scripts, templates, CI config) are validated by parsing, linting, and syntax-checking.

## Contract

**Input:** PR number, repo root
**Output:** JSON `VerificationResult`
**Gate:** WARN-ONLY

## Workflow

### Step 1 — Detect Available Checks

```bash
cd <REPO_ROOT>
CHECKS=()
ls scripts/*.mjs scripts/*.cjs scripts/*.js 2>/dev/null | head -1 >/dev/null && CHECKS+=("script-validate")
[ -f scripts/check-skill-lint.mjs ] && CHECKS+=("skill-lint")
[ -d templates ] && CHECKS+=("template-validity")
[ -d .github/workflows ] && CHECKS+=("ci-config")
```

### Step 2 — Run Checks

For each available check, run the command and capture result:

**script-validate:**
```bash
shopt -s nullglob; node --check scripts/*.mjs scripts/*.cjs scripts/*.js 2>&1
```
→ exit 0 = pass. Failures = syntax errors, missing imports.

**skill-lint:**
```bash
node scripts/check-skill-lint.mjs 2>&1
```
→ exit 0 = pass. Failures = YAML frontmatter issues, missing required fields.

**template-validity:**
```bash
errors=0
for f in templates/*.yaml templates/*.yml templates/*.json templates/*.md; do
  [ -f "$f" ] || continue
  python3 -c "import json; json.load(open('$f'))" 2>/dev/null || \
  python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null || \
  errors=$((errors+1))
done
[ $errors -eq 0 ]
```
→ All templates parse = pass. Failures = malformed config.

**ci-config:**
```bash
errors=0
for f in .github/workflows/*.yml; do
  [ -f "$f" ] || continue
  python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null || errors=$((errors+1))
done
[ $errors -eq 0 ]
```
→ All workflows parse = pass. Failures = invalid YAML.

### Step 3 — Return Result

```json
{
  "surface": "infra",
  "status": "pass",
  "checks": [
    {"name": "script-validate", "status": "pass", "duration_ms": 120},
    {"name": "skill-lint", "status": "pass", "duration_ms": 340},
    {"name": "template-validity", "status": "pass", "duration_ms": 80},
    {"name": "ci-config", "status": "pass", "duration_ms": 150}
  ],
  "evidence": [],
  "issues_filed": []
}
```

If no checks available: `{"surface":"infra","status":"skip","checks":[],"evidence":[],"issues_filed":[]}`

## Why Script-Based (Not Agent-Executed)

Unlike web and desktop surfaces, infra changes have no user interface to click through. A skill file, script, or CI config is validated by parsing and syntax-checking — not by "navigating." The agent runs deterministic validation tools and reports results.

## Failure Handling

- **Never exit non-zero** — always return JSON
- **Log check output as evidence** for failures
- **Available checks vary by repo** — missing = skip, not fail
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
