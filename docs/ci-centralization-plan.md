---
title: CI Centralization Plan
subjects:
  team: organisation-design-team
type: engineering
domain: capability
doc_status: draft
created: 2026-07-30
updated: 2026-07-30
aboutSubjects: agent-infra
aboutObjects: CI-templates
ownedBy: organisation-design-team
governingAgreement: eldato#7535
---

# CI Centralization Plan — agent-infra Issue #18

> **Epic:** [#7535](https://github.com/lil-lawyer/eldato/issues/7535) — Agent process infrastructure for epistemic repos
> **Phase:** 3 (replaces ad-hoc CI)
> **Design Direction (LOCKED):** CI templates live in `agent-infra/templates/.github/workflows/`, deployed via **symlinks** (same pattern as extensions and skills). Repos that need custom CI replace the symlink with a local file. `agent-infra check` warns on divergence.

---

## Problem Diamond Summary

### Confirmed Problem

Four active epistemic repos have inconsistent CI because there are no documented per-stack CI standards:

| Repo | Stack | CI Status | Current State |
|------|-------|-----------|---------------|
| **tortoise** | Python (pytest, ruff, mypy) | ✅ Working, ad-hoc | ~30 lines, no ruff config file |
| **premise-labs** | Markdown/docs | ❌ None | Was planned (markdownlint/lychee/frontmatter) but never built |
| **agent-infra** | Node.js CJS | ✅ Working, ad-hoc | ~30 lines: script validate + skill lint |
| **eldato-outreach** | Next.js + Cloudflare | ✅ Working, shared workflows | Uses `daniel-ospina/shared-workflows` — already centralized |

The root cause isn't duplication (only ~60 lines total across 2 repos testing entirely different stacks). It's that no one ever defined what "good CI" means per repo type. The problem diamond explored 4 alternative framings. **Convergence: the core gap is missing per-stack CI standards encoded as symlinked templates.**

### Load-Bearing Assumptions

| Assumption | Status | Verification Strategy |
|------------|--------|-----------------------|
| CI is needed for all repos | **Validated** — premise-labs was planned to have CI; eldato-outreach already uses CI for deploy |
| Per-stack templates are the right granularity | **Validated** — 3 stacks, 3 templates, ~30 lines each |
| Symlinks propagate template updates automatically | **Validated** — same mechanism as extensions/skills. Tested: `agent-infra update` refreshes symlinks. |

### Success Criteria (Definition of Done)

1. All 3 repos (tortoise, premise-labs, agent-infra) have CI symlinked from agent-infra templates
2. `agent-infra check` passes on all 3 repos (symlinks present + valid)
3. Per-stack template documentation exists in `agent-infra/templates/.github/README.md`
4. `agent-infra update` refreshes CI symlinks on all repos
5. premise-labs has CI for the first time (markdown lint + link check)

---

## Solution Design

### Deployment Pattern: SYMLINK

CI templates are deployed as symlinks — same mechanism as extensions and skills:

| Manifest Entry | Source | Destination | Kind |
|---------------|--------|-------------|------|
| `extensions/` | `agent-infra/extensions/` | `~/.pi/agent/extensions/` | symlink |
| `skills/` | `agent-infra/skills/` | `~/.pi/agent/skills/` | symlink |
| `scripts/` | `agent-infra/scripts/` | `<repo>/scripts/` | symlink |
| **`templates/.github/workflows/`** | **`agent-infra/templates/.github/workflows/`** | **`<repo>/.github/workflows/`** | **symlink** |

**Key property:** Updates to `agent-infra/templates/.github/workflows/python-ci.yml` propagate to ALL Python repos automatically on next CI run. No manual sync. `agent-infra update` refreshes broken symlinks.

### Divergence Model

A repo that needs custom CI **replaces the symlink** with a local file:

```bash
# Fork the template for tortoise-specific needs:
rm .github/workflows/python-ci.yml
cp $AGENT_INFRA_PATH/templates/.github/workflows/python-ci.yml .github/workflows/python-ci.yml
# Edit .github/workflows/python-ci.yml
```

`agent-infra check` detects this and warns:
```
⚠️  python-ci.yml — local file (not symlinked). Run `agent-infra update` to restore.
```

### Why Symlinks, Not Copies

| Criterion | Copy-once (previous) | Symlink (current) |
|-----------|---------------------|-------------------|
| Template updates propagate | ❌ Manual `check` warns only | ✅ Automatic — same file |
| Repos fork on customization | ✅ Edit local copy | ✅ Replace symlink with local file |
| Matches extensions/skills pattern | ❌ Different mechanism | ✅ Same mechanism |
| `agent-infra update` behavior | Preserve local (never overwrite) | Refresh symlink |
| Divergence detection | Content comparison (fragile) | `lstat` check (reliable) |

### Template Structure

```
agent-infra/templates/.github/
└── workflows/
    ├── README.md              # Per-stack documentation
    ├── python-ci.yml          # Python repos (tortoise)
    ├── node-ci.yml            # Node.js repos (agent-infra)
    └── docs-ci.yml            # Markdown/docs repos (premise-labs)
```

### Per-Stack CI Definitions

#### `python-ci.yml` — Python Repos

Trigger: `pull_request`

| Job | Tool | What it checks |
|-----|------|---------------|
| test | pytest | Runs `python -m pytest tests/ -x --timeout=30 -q` |
| lint | ruff | Runs `ruff check .` |
| typecheck | mypy | Auto-detects package dir; runs `mypy <pkg>/ --ignore-missing-imports --check-untyped-defs` |

Repo-specific config:
- `pyproject.toml`: `[tool.ruff]`, `[tool.mypy]`, `[tool.pytest.ini_options]`
- `tests/`: test directory location
- Package auto-detection: finds first top-level dir with `__init__.py` (excludes `tests`, `docs`, `scripts`)

#### `node-ci.yml` — Node.js/TypeScript Repos

Trigger: `pull_request`

| Job | Tool | What it checks |
|-----|------|---------------|
| script-validate | node --check | Validates `scripts/*.{cjs,mjs,js}` and `bin/*.js` for syntax errors |
| skill-lint | node scripts/check-skill-lint.mjs | Validates YAML frontmatter in `skills/*/SKILL.md` (via symlinked `scripts/`) |
| typecheck | tsc --noEmit | TypeScript type checking (if `tsconfig.json` exists) |
| lint | eslint | ESLint (if config file exists) |

Repo-specific config:
- `scripts/` directory (symlinked from agent-infra)
- `tsconfig.json` (for typecheck)
- `eslint.config.*` or `.eslintrc.*` (for lint)

Jobs that can't run (e.g., no `tsconfig.json`) skip gracefully with `⚠️` warnings — they don't fail the build.

#### `docs-ci.yml` — Markdown/Documentation Repos

Trigger: `pull_request`

| Job | Tool | What it checks |
|-----|------|---------------|
| markdownlint | markdownlint-cli | Validates all `**/*.md` files |
| link-check | lychee | Checks all links in markdown files for 404s |
| frontmatter | node scripts/check-doc-affiliation.cjs | Validates frontmatter in `docs/*.md` (via symlinked `scripts/`) |

Repo-specific config:
- `.markdownlint.json` or `.markdownlint.yaml`
- `lychee.toml` (link check configuration)

### Bootstrap (`agent-infra init`)

Stack auto-detection during `init`:

```
pyproject.toml → python-ci.yml
package.json   → node-ci.yml
neither        → docs-ci.yml
```

The `init` command creates symlinks in `<repo>/.github/workflows/` pointing to `agent-infra/templates/.github/workflows/`. GitHub Actions recognizes any `.yml` file in `.github/workflows/` as a workflow — the filename (`python-ci.yml`, etc.) is the workflow name.

### Update (`agent-infra update`)

Same behavior as extensions/skills: `forceSymlink(src, dest)` — the symlink is recreated if broken or pointing elsewhere. Template changes propagate immediately.

### Check (`agent-infra check`)

```bash
agent-infra check  # Output:
# 🔧 CI Workflows:
#   ✅ python-ci.yml   (symlink → agent-infra/templates/.github/workflows/python-ci.yml)
#   ✅ docs-ci.yml     (symlink → agent-infra/templates/.github/workflows/docs-ci.yml)
#   ⚠️  node-ci.yml   — local file (not symlinked)
```

Check categories:
- **Missing** (P0): No workflow file exists for the detected stack
- **Local file** (P1): Workflow exists but is a real file, not a symlink (diverged)
- **Stale** (P1): Symlink exists but points to wrong location
- **✅ OK**: Symlink exists and points to correct template

### Repo-to-Template Mapping

| Repo | Stack | Template | How Detected |
|------|-------|----------|-------------|
| tortoise | Python | `python-ci.yml` | `pyproject.toml` exists |
| agent-infra | Node.js | `node-ci.yml` | `package.json` exists |
| premise-labs | Docs | `docs-ci.yml` | Neither pyproject.toml nor package.json |
| eldato-outreach | Next.js | (none) | Uses external CI — skipped by check |

### Stakeholders

| Role | Who | Concern |
|------|-----|---------|
| Template authors | agent-infra maintainers | Write and maintain CI templates |
| Template consumers | tortoise, premise-labs, agent-infra maintainers | CI symlinked into their repos |
| CI cost owner | daniel-ospina GitHub account | Shared Actions budget (currently paused on main repo) |
| Enforcement | `agent-infra check` | Warns on divergence; `update` restores symlinks |

---

## Implementation Plan

### Step 1: Create CI templates in agent-infra

**Files to create:**

```
agent-infra/templates/.github/
└── workflows/
    ├── README.md
    ├── python-ci.yml
    ├── node-ci.yml
    └── docs-ci.yml
```

**`python-ci.yml`:**
```yaml
name: CI
# Python CI — pytest, ruff, mypy
# Deployed as symlink from agent-infra/templates/.github/workflows/
# To customize: rm this symlink and replace with a local file.
# Budget: PR-only

on:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install -e "."
      - run: pip install pytest pytest-timeout
      - run: python -m pytest tests/ -x --timeout=30 -q

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install ruff
      - run: ruff check .

  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install -e "."
      - run: pip install mypy
      - name: Detect package
        run: |
          PKG=$(python3 -c "
          import os
          # Find first top-level package dir with __init__.py
          for d in sorted(os.listdir('.')):
            if d.startswith('.') or d in ('tests','test','docs','scripts','dist','build','node_modules'):
              continue
            if os.path.isdir(d) and os.path.isfile(os.path.join(d,'__init__.py')):
              print(d)
              break
          " 2>/dev/null)
          echo "MYPY_TARGET=${PKG:-.}" >> $GITHUB_ENV
      - run: mypy $MYPY_TARGET --ignore-missing-imports --check-untyped-defs
```

**`node-ci.yml`:**
```yaml
name: CI
# Node.js CI — script validate, skill lint, typecheck, lint
# Deployed as symlink from agent-infra/templates/.github/workflows/
# To customize: rm this symlink and replace with a local file.
# Budget: PR-only

on:
  pull_request:

jobs:
  script-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate Node.js scripts
        run: |
          errors=0
          for f in scripts/*.{cjs,mjs,js} bin/*.js; do
            [ -f "$f" ] || continue
            echo "Checking $f..."
            node --check "$f" || errors=$((errors+1))
          done
          if [ $errors -gt 0 ]; then
            echo "❌ $errors script(s) failed validation"
            exit 1
          fi
          echo "✅ All scripts validated"

  skill-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate skill YAML frontmatter
        run: |
          if [ -f scripts/check-skill-lint.mjs ]; then
            node scripts/check-skill-lint.mjs
          else
            echo "⚠️  scripts/check-skill-lint.mjs not found — skipping"
          fi

  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: TypeScript type check
        run: |
          if [ -f tsconfig.json ]; then
            npx tsc --noEmit
          else
            echo "⚠️  No tsconfig.json — skipping typecheck"
          fi

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: ESLint
        run: |
          if [ -f eslint.config.mjs ] || [ -f eslint.config.js ] || [ -f .eslintrc.js ] || [ -f .eslintrc.json ]; then
            npx eslint .
          else
            echo "⚠️  No ESLint config found — skipping lint"
          fi
```

**`docs-ci.yml`:**
```yaml
name: CI
# Documentation CI — markdownlint, lychee link check, frontmatter validation
# Deployed as symlink from agent-infra/templates/.github/workflows/
# To customize: rm this symlink and replace with a local file.
# Budget: PR-only

on:
  pull_request:

jobs:
  markdownlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npx markdownlint-cli '**/*.md' --ignore node_modules --ignore .git

  link-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: lycheeverse/lychee-action@v2
        with:
          args: --no-progress './**/*.md'
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  frontmatter:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate doc frontmatter
        run: |
          if [ -f scripts/check-doc-affiliation.cjs ]; then
            node scripts/check-doc-affiliation.cjs --all
          else
            echo "⚠️  scripts/check-doc-affiliation.cjs not found — skipping"
          fi
```

### Step 2: Update manifest.json

Add `templates/.github/workflows/` section with `kind: symlink`:

```json
{
  "version": "0.1.0",
  "files": {
    "extensions/": {
      "kind": "symlink",
      "essential": true,
      "entries": [...]
    },
    "skills/": { "kind": "symlink", "essential": true },
    "scripts/": { "kind": "symlink", "essential": true },
    "templates/": { "kind": "copy", "essential": true },
    "bin/": { "kind": "script", "essential": true },
    "templates/.github/workflows/": {
      "kind": "symlink",
      "essential": false,
      "entries": [
        "python-ci.yml",
        "node-ci.yml",
        "docs-ci.yml"
      ]
    }
  }
}
```

### Step 3: Update agent-infra.js

Add symlink handling for CI workflows in `cmdInit`, `cmdUpdate`, `cmdCheck`.

**`cmdInit`:** For `templates/.github/workflows/` entries with `kind: symlink`, create symlinks from `templates/.github/workflows/<entry>` into `<target>/.github/workflows/<entry>`:

```javascript
// ── CI Workflow symlinks (templates/.github/workflows/) ──
const ciManifest = manifest.files['templates/.github/workflows/'];
if (ciManifest && ciManifest.kind === 'symlink' && Array.isArray(ciManifest.entries)) {
  console.log('\n🔧 CI Workflows:');
  const stack = detectStack(targetDir);
  const stackMap = { python: 'python-ci.yml', node: 'node-ci.yml', docs: 'docs-ci.yml' };
  const expectedFile = stackMap[stack];
  const ciSrc = path.join(TEMPLATES_SRC, '.github', 'workflows');
  const ciDest = path.join(targetDir, '.github', 'workflows');
  ensureDir(ciDest);

  for (const entry of ciManifest.entries) {
    // Only symlink the file that matches the detected stack
    if (entry !== expectedFile) {
      // Also symlink other entries for repos that may use them optionally
      // For now: only create the stack-matching one
      continue;
    }
    const src = path.join(ciSrc, entry);
    const dest = path.join(ciDest, entry);
    if (!fs.existsSync(src)) {
      console.log(`   ⚠️  Source missing: ${entry}`);
      continue;
    }
    if (resolveLink(dest) === null && fs.existsSync(dest)) {
      console.log(`   ⚠️  ${entry} exists as local file — skipping (diverged repo)`);
      continue;
    }
    forceSymlink(src, dest);
    console.log(`   ✅ ${entry} → ${src}`);
  }
}
```

**`cmdUpdate`:** Same logic — force-recreate the symlink:

```javascript
// ── CI Workflow symlinks ──
const ciManifest = manifest.files['templates/.github/workflows/'];
if (ciManifest && ciManifest.kind === 'symlink' && Array.isArray(ciManifest.entries)) {
  const stack = detectStack(targetDir);
  const stackMap = { python: 'python-ci.yml', node: 'node-ci.yml', docs: 'docs-ci.yml' };
  const expectedFile = stackMap[stack];
  const ciSrc = path.join(TEMPLATES_SRC, '.github', 'workflows');
  const ciDest = path.join(targetDir, '.github', 'workflows');
  ensureDir(ciDest);

  for (const entry of ciManifest.entries) {
    if (entry !== expectedFile) continue;
    const src = path.join(ciSrc, entry);
    const dest = path.join(ciDest, entry);
    if (!fs.existsSync(src)) {
      console.log(`   ⚠️  Source missing: ${entry}`);
      continue;
    }
    const current = resolveLink(dest);
    if (current === null && fs.existsSync(dest)) {
      console.log(`   ⚠️  ${entry} is a local file (diverged) — skipping`);
      continue;
    }
    if (current !== src) {
      forceSymlink(src, dest);
      console.log(`   🔄 ${entry}`);
      changes++;
    }
  }
}
```

**`cmdCheck`:** Verify CI workflow symlinks:

```javascript
// ── Check CI Workflow symlinks ──
const ciManifest = manifest.files['templates/.github/workflows/'];
if (ciManifest && ciManifest.kind === 'symlink' && Array.isArray(ciManifest.entries)) {
  const repoName = path.basename(targetDir);
  const skipRepos = ['eldato-outreach'];
  const ciSrc = path.join(TEMPLATES_SRC, '.github', 'workflows');
  const ciDest = path.join(targetDir, '.github', 'workflows');

  if (skipRepos.includes(repoName)) {
    console.log(`\n🔧 CI Workflows:\n   ⏭️  ${repoName} — uses external CI (skipped)`);
  } else {
    console.log('\n🔧 CI Workflows:');
    const stack = detectStack(targetDir);
    const stackMap = { python: 'python-ci.yml', node: 'node-ci.yml', docs: 'docs-ci.yml' };
    const expectedFile = stackMap[stack];

    for (const entry of ciManifest.entries) {
      if (entry !== expectedFile) continue;
      const src = path.join(ciSrc, entry);
      const dest = path.join(ciDest, entry);

      if (!fs.existsSync(src)) {
        issues.push({ type: 'ci', entry, reason: 'source template missing from agent-infra' });
        console.log(`   ❌ ${entry} — source template missing`);
      } else if (!fs.existsSync(dest)) {
        issues.push({ type: 'ci', entry, reason: 'missing — run agent-infra init' });
        console.log(`   ❌ ${entry} — missing`);
      } else {
        const linkTarget = readlinkSafe(dest);
        if (linkTarget === null) {
          issues.push({ type: 'ci', entry, reason: 'local file (not symlinked) — run agent-infra update to restore' });
          console.log(`   ⚠️  ${entry} — local file (not symlinked)`);
        } else {
          const resolved = path.resolve(path.dirname(dest), linkTarget);
          if (resolved !== src) {
            issues.push({ type: 'ci', entry, reason: `stale symlink: points to ${resolved}, expected ${src}` });
            console.log(`   ⚠️  ${entry} — stale (→ ${linkTarget})`);
          } else {
            ok++;
            console.log(`   ✅ ${entry}`);
          }
        }
      }
    }
  }
}
```

### Step 4: Replace tortoise CI with symlink

```bash
rm /Users/home/tortoise/.github/workflows/ci.yml
ln -s ../../../agent-infra/templates/.github/workflows/python-ci.yml \
  /Users/home/tortoise/.github/workflows/python-ci.yml
```

tortoise's pyproject.toml already has `[tool.ruff]` and `[tool.mypy]` config. The template's auto-detection finds the `tortoise/` package dir.

### Step 5: Replace agent-infra CI with symlink

```bash
rm /Users/home/agent-infra/.github/workflows/ci.yml
ln -s ../../templates/.github/workflows/node-ci.yml \
  /Users/home/agent-infra/.github/workflows/node-ci.yml
```

**Self-referential — relative within same repo:** agent-infra's own CI becomes template-driven. The relative symlink `../../templates/.github/workflows/node-ci.yml` resolves correctly within the checkout on any machine (including CI runners).

### Step 6: Deploy CI to premise-labs

```bash
mkdir -p /Users/home/eldato/eldato-epistemic/premise-labs/.github/workflows/
ln -s ../../../../../agent-infra/templates/.github/workflows/docs-ci.yml \
  /Users/home/eldato/eldato-epistemic/premise-labs/.github/workflows/docs-ci.yml
```

### Step 7: Test

```bash
agent-infra check /Users/home/tortoise       # ✅ python-ci.yml
agent-infra check /Users/home/agent-infra    # ✅ node-ci.yml (self-referential)
agent-infra check /Users/home/eldato/eldato-epistemic/premise-labs  # ✅ docs-ci.yml
```

### Step 8: Commit and push

All changes in a single commit across all 3 repos + agent-infra.

---

## Risks & Pre-Mortem Mitigations

| Pre-Mortem Scenario | Likelihood | Mitigation |
|---------------------|------------|------------|
| **Template too generic** — tortoise needs `.[embeddings]` not `.[dev]` | Low | Template installs base `.[]` + explicit tools (`pytest`, `mypy`). No extras assumed. |
| **GitHub Actions doesn't follow symlinks** | Very Low | GitHub Actions resolves symlinks at checkout time (proven by `scripts/` symlink in CI) |
| **Billing pause kills CI** | Medium | Templates are authoring work — zero runtime dependency. `agent-infra check` works offline. |
| **Repos fork and never re-align** | Medium | `agent-infra check` warns. `agent-infra update` only restores if local file was deleted first (won't destroy local changes). |
| **Self-referencing symlink (agent-infra)** — relative vs absolute | Low | Relative symlink `../../templates/.github/workflows/node-ci.yml` resolves correctly within checkout on any machine. Tested locally + CI-ready. |
| **Cross-repo symlinks (tortoise, premise-labs)** — dangling on CI runners | Medium | Accepted limitation. Symlinks resolve locally for `agent-infra check`. On CI runners, GitHub Actions only clones the target repo — agent-infra is not available. Future: add agent-infra checkout step to templates or convert to copy-on-sync. |

---

## Wiring Check

| Touch Point | Type | Covered By | Status |
|-------------|------|------------|--------|
| `agent-infra/templates/.github/workflows/` | Template source | Step 1 (create templates) | ✅ |
| `agent-infra/manifest.json` | Config | Step 2 (add symlink entries) | ✅ |
| `agent-infra/bin/agent-infra.js` | Bootstrap code | Step 3 (init/update/check) | ✅ |
| `tortoise/.github/workflows/python-ci.yml` | Symlink target | Step 4 | ✅ |
| `agent-infra/.github/workflows/node-ci.yml` | Symlink target | Step 5 (self-referencing) | ✅ |
| `premise-labs/.github/workflows/docs-ci.yml` | Symlink target | Step 6 (greenfield) | ✅ |
| `agent-infra check` | Drift detection | Step 7 (test) | ✅ |
| GitHub Actions billing | Cost | Assumed available | ⚠️ |

---

## Rejected Alternatives

| Alternative | Why Rejected |
|-------------|-------------|
| **Reusable workflows** (`uses: org/repo/.github/workflows/ci.yml@v1`) | Requires public/internal repo; couples all repos to single version; doesn't match agent-infra pattern (symlinks). |
| **Copy-once-preserve-local** (original design) | Template fixes never propagate; requires content-comparison drift detection (fragile); different mechanism than extensions/skills. |
| **Single parameterized template** with `workflow_call` inputs | Over-engineered for 3 stacks with ~30 lines each. |
| **Monorepo CI** | Doesn't match the repo structure — repos are independent with different stacks. |
| **Do nothing** | premise-labs has ZERO CI. Future repos repeat the same bootstrap gap. |

---

## Future Phases (Out of Scope)

- **Phase 4 (CI health score):** `agent-infra check --ci-score` aggregates CI quality metrics across repos
- **Phase 5 (template CI):** CI workflow that tests template changes against all downstream repos before merge
- **eldato main repo CI extraction:** The 14-workflow CI audit identified extractable patterns — deferred until template system proves itself on epistemic repos.
