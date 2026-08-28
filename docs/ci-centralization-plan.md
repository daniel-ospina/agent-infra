---
title: CI Centralization Plan
subjects:
  team: organisation-design-team
type: engineering
domain: capability
doc_status: draft
created: 2026-07-30
updated: 2026-07-30 (hybrid: reusable workflows + symlinks)
aboutSubjects: agent-infra
aboutObjects: CI-templates
ownedBy: organisation-design-team
governingAgreement: eldato#7535
---

# CI Centralization Plan — agent-infra Issue #18

> **Epic:** [#7535](https://github.com/lil-lawyer/eldato/issues/7535) — Agent process infrastructure for epistemic repos
> **Phase:** 3 (replaces ad-hoc CI)
> **Design Direction (LOCKED, revised 2026-08-19 by #303):** CI execution via **GitHub reusable workflows** (`on: workflow_call`) hosted in `agent-infra/.github/workflows/`, called by thin `ci.yml` callers in each repo pinned to a **semver tag** (`@vX.Y.Z`). The reusable workflows are **REAL COMMITTED FILES** materialized from `agent-infra/templates/.github/workflows/` by `scripts/sync-ci-workflows.sh` — **no symlinks anywhere under `.github/workflows/`** (GitHub Actions reads symlinks as their link-target string, so a symlinked workflow fails every run at 0 jobs — #555 root cause, verified). The original symlink-based design below is kept as the historical record; locked decisions D1–D7 in [issue #303](https://github.com/daniel-ospina/agent-infra/issues/303) supersede it.

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

### Success Criteria (Definition of Done — revised 2026-08-19, #303 D7)

> The original DoD below (symlinked CI in consumer repos) is **impossible as designed**:
> any symlink under `.github/workflows/` is itself a broken-workflow entry to GitHub
> Actions (#555 — cross-repo, same-repo, and workflow-discovery variants all fail at
> 0 jobs). Superseded by the real-file/pin design:

1. `agent-infra/.github/workflows/{python,node,docs}-ci.yml` are **real committed files** (zero symlinks under any `.github/workflows/` in scope); agent-infra's own PR CI (thin caller, `@main` self-caller) runs real jobs — no "workflow file issue"/"error parsing called workflow" runs.
2. ≥2 consumers (tortoise, premise-labs) have a thin `ci.yml` calling `daniel-ospina/agent-infra/.github/workflows/<stack>-ci.yml@vX.Y.Z`; repo-specific jobs (test matrix, migrations, service containers) remain local siblings; no workflow symlinks in consumers.
3. A workflow change in agent-infra lands in consumers by **version bump** (tag + manifest `ci.ref` + pin edit) — no manual copying; `agent-infra check` (ci-ref surface) reports and **blocks** on a stale pin.
4. Pin-drift detection exists and fires on a stale pin: `agent-infra check` ci-ref compare vs `manifest.json ci.ref`, exit 1 on mismatch (composes with the #305 drift-check workflow).
5. Template ⇄ copy parity is CI-enforced (pipeline-compliance `workflow-drift` job).
6. `docs/ci-centralization-plan.md` DoD reflects the real-file/pin design (this section) and is met.

> **Known limitation (verified 2026-08-19):** the same-account access rule applies **only to private caller repos**. GitHub blocks public repositories from calling reusable workflows in private repos (agent-infra Actions → General → Access: "access is allowed only from private repositories"). tortoise is public → its thin caller fails with "workflow was not found" at 0 jobs; premise-labs (private) resolves the same `@v0.1.0` ref fine. tortoise migration unblocks when the owner chooses: make agent-infra public, move the reusable workflows to a dedicated public repo, or make tortoise private.

---

## Solution Design

### Hybrid Architecture: Reusable Workflows + Symlinks

Two mechanisms serve two different purposes:

| Purpose | Mechanism | Files |
|---------|-----------|-------|
| **CI execution** (GitHub Actions) | Reusable workflows (`on: workflow_call`) | `agent-infra/.github/workflows/*.yml` |
| **Local drift detection** (`agent-infra check`) | Symlinks | `<repo>/.github/workflows/<stack>-ci.yml` → `agent-infra/templates/.github/workflows/` |

**How it works:**

1. **Reusable workflows** live at `agent-infra/.github/workflows/python-ci.yml`, `node-ci.yml`, `docs-ci.yml` — exposed via `on: workflow_call` with per-stack inputs.
2. Each consumer repo has a **thin `ci.yml` caller**:
   ```yaml
   # tortoise/.github/workflows/ci.yml
   on: pull_request:
   jobs:
     ci:
       uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@main
       with:
         python-version: '3.11'
       secrets: inherit
   ```
3. Each consumer repo ALSO has a **symlink** from `<stack>-ci.yml` → `agent-infra/templates/.github/workflows/<stack>-ci.yml` for `agent-infra check` drift detection.
4. The reusable workflows in `agent-infra/.github/workflows/` are themselves symlinked to `templates/.github/workflows/` — a single source of truth.

**Key properties:**
- Template updates to `agent-infra/templates/.github/workflows/` propagate to reusable workflows immediately (same file via symlink).
- Consumer repos pull the reusable workflow at CI runtime — no stale copy problem.
- `agent-infra check` still uses the symlinks for local drift detection.
- `agent-infra update` refreshes broken symlinks.

**File layout:**
```
agent-infra/
├── templates/.github/workflows/    ← Source of truth (reusable workflow definitions)
│   ├── python-ci.yml
│   ├── node-ci.yml
│   └── docs-ci.yml
├── .github/workflows/              ← Reusable workflows (symlinked to templates)
│   ├── python-ci.yml → ../../templates/.github/workflows/python-ci.yml
│   ├── node-ci.yml → ../../templates/.github/workflows/node-ci.yml
│   ├── docs-ci.yml → ../../templates/.github/workflows/docs-ci.yml
│   └── ci.yml                      ← Thin caller for agent-infra's own CI

tortoise/.github/workflows/
├── ci.yml                          ← Thin caller: uses: agent-infra/.github/workflows/python-ci.yml@main
└── python-ci.yml → ../../../agent-infra/templates/.github/workflows/python-ci.yml  (symlink for check)

premise-labs/.github/workflows/
├── ci.yml                          ← Thin caller: uses: agent-infra/.github/workflows/docs-ci.yml@main
└── docs-ci.yml → ../../../../agent-infra/templates/.github/workflows/docs-ci.yml    (symlink for check)
```

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

### Why Hybrid

| Criterion | Pure Symlinks (v1) | Hybrid (current) |
|-----------|-------------------|-------------------|
| Template updates propagate | ✅ Automatic on CI run (same file) | ✅ Automatic — reusable workflow always fetches `@main` |
| Works on CI runners (cross-repo) | ❌ Dangling symlinks — agent-infra not cloned | ✅ Reusable workflow resolved by GitHub Actions |
| Local drift detection | ✅ `agent-infra check` via `lstat` | ✅ Same |
| Repos fork on customization | ✅ Replace symlink with local file | ✅ Replace thin caller + fork template |
| Matches extensions/skills pattern | ✅ Same mechanism | ✅ Same mechanism for checking |
| `agent-infra update` behavior | Refresh symlink | Refresh symlink + template stays source of truth |
| Divergence detection | `lstat` check (reliable) | `lstat` check (reliable) |
| Input parameterization | ❌ Hardcoded in template | ✅ `workflow_call` inputs per repo |

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
The **one deliberate exception** is the `skill-lint` job (#254, Task 11): since the frontmatter
validator is a required gate, a MISSING `scripts/check-skill-lint.mjs` now fails the job
(`❌ missing required gate, FAILING`) instead of skipping. This is a stated breaking change for
consumer repos that sync the new template without the script — propagation to consumer repos
(eldato, tortoise, worktrees) is tracked by issue #359 (soft dependency, can ship separately).

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

### Step 1: Convert templates to reusable workflows

Convert the 3 templates in `agent-infra/templates/.github/workflows/` to use `on: workflow_call` with input parameters. These become the source of truth for both reusable workflow execution and symlinked drift detection.

**Files to convert:**

```
agent-infra/templates/.github/
└── workflows/
    ├── python-ci.yml    ← on: workflow_call (was: on: pull_request)
    ├── node-ci.yml      ← on: workflow_call
    └── docs-ci.yml      ← on: workflow_call
```

See actual template files for current content — they define `workflow_call` inputs for `python-version`, `test-command`, `lint-command`, `typecheck-command`, `install-extras`, and `node-version`.

### (Reference) Update manifest.json

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

### Step 2: Expose reusable workflows in agent-infra/.github/workflows/

Symlink from `agent-infra/.github/workflows/` to `templates/.github/workflows/` so GitHub Actions can resolve `uses: daniel-ospina/agent-infra/.github/workflows/*@main`:

```bash
cd agent-infra/.github/workflows/
ln -s ../../templates/.github/workflows/python-ci.yml python-ci.yml
ln -s ../../templates/.github/workflows/docs-ci.yml docs-ci.yml
# node-ci.yml already symlinked
```

### (Reference) Update agent-infra.js

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

### Step 4: Create thin callers + symlinks in consumer repos

**tortoise:** Create `ci.yml` (thin caller) + keep `python-ci.yml` symlink:
```yaml
# tortoise/.github/workflows/ci.yml
on: pull_request:
jobs:
  ci:
    uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@main
    with:
      python-version: '3.11'
    secrets: inherit
```

**agent-infra:** Create `ci.yml` (thin caller) + keep `node-ci.yml` symlink:
```yaml
# agent-infra/.github/workflows/ci.yml
on: pull_request:
jobs:
  ci:
    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main
    secrets: inherit
```

**premise-labs:** Replace `ci.yml` with thin caller + create `docs-ci.yml` symlink:
```yaml
# premise-labs/.github/workflows/ci.yml
on: pull_request:
jobs:
  ci:
    uses: daniel-ospina/agent-infra/.github/workflows/docs-ci.yml@main
    secrets: inherit
```

### Step 5: Commit and push

All changes across all 3 repos + agent-infra, committed and pushed to their respective feature branches.

---

## Risks & Pre-Mortem Mitigations

| Pre-Mortem Scenario | Likelihood | Mitigation |
|---------------------|------------|------------|
| **Template too generic** — tortoise needs `.[embeddings]` not `.[dev]` | Low | Template installs base `.[]` + explicit tools (`pytest`, `mypy`). No extras assumed. |
| **GitHub Actions doesn't follow symlinks** | Very Low | GitHub Actions resolves symlinks at checkout time (proven by `scripts/` symlink in CI) |
| **Billing pause kills CI** | Medium | Templates are authoring work — zero runtime dependency. `agent-infra check` works offline. |
| **Repos fork and never re-align** | Medium | `agent-infra check` warns. `agent-infra update` only restores if local file was deleted first (won't destroy local changes). |
| **Self-referencing symlink (agent-infra)** — relative vs absolute | Low | Relative symlink `../../templates/.github/workflows/node-ci.yml` resolves correctly within checkout on any machine. Tested locally + CI-ready. |
| **Cross-repo symlinks (tortoise, premise-labs)** — dangling on CI runners | N/A | **Resolved.** Symlinks are used ONLY for local `agent-infra check` drift detection. Actual CI execution goes through reusable workflows (`uses: daniel-ospina/agent-infra/.github/workflows/*@main`), which GitHub Actions resolves independently. |

---

## Wiring Check

| Touch Point | Type | Covered By | Status |
|-------------|------|------------|--------|
| `agent-infra/templates/.github/workflows/` | Reusable workflow source | Step 1 (convert to workflow_call) | ✅ |
| `agent-infra/.github/workflows/python-ci.yml` | Reusable workflow (symlink to templates) | Step 2 (create symlinks) | ✅ |
| `agent-infra/.github/workflows/node-ci.yml` | Reusable workflow (symlink to templates) | Already existed | ✅ |
| `agent-infra/.github/workflows/docs-ci.yml` | Reusable workflow (symlink to templates) | Step 2 (create symlinks) | ✅ |
| `agent-infra/.github/workflows/ci.yml` | Thin caller (agent-infra self-CI) | Step 4 | ✅ |
| `tortoise/.github/workflows/ci.yml` | Thin caller | Step 4 | ✅ |
| `tortoise/.github/workflows/python-ci.yml` | Symlink for check | Already existed | ✅ |
| `premise-labs/.github/workflows/ci.yml` | Thin caller | Step 4 | ✅ |
| `premise-labs/.github/workflows/docs-ci.yml` | Symlink for check | Step 4 | ✅ |
| `agent-infra check` | Drift detection | Step 5 (test) | ✅ |
| GitHub Actions billing | Cost | Assumed available | ⚠️ |

---

## Rejected Alternatives

| Alternative | Why Rejected |
|-------------|-------------|
| **Pure symlinks only** (original design) | Cross-repo symlinks are dangling on CI runners — agent-infra is not cloned. Reusable workflows solve this by having GitHub Actions resolve the workflow at runtime. |
| **Copy-once-preserve-local** (original design) | Template fixes never propagate; requires content-comparison drift detection (fragile); different mechanism than extensions/skills. |
| **Single parameterized template** with `workflow_call` inputs | Over-engineered for 3 stacks with ~30 lines each. |
| **Monorepo CI** | Doesn't match the repo structure — repos are independent with different stacks. |
| **Do nothing** | premise-labs has ZERO CI. Future repos repeat the same bootstrap gap. |

---

## Future Phases (Out of Scope)

- **Phase 4 (CI health score):** `agent-infra check --ci-score` aggregates CI quality metrics across repos
- **Phase 5 (template CI):** CI workflow that tests template changes against all downstream repos before merge
- **eldato main repo CI extraction:** The 14-workflow CI audit identified extractable patterns — deferred until template system proves itself on epistemic repos.
