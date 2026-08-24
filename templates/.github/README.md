# CI Templates

Per-stack reusable CI workflows (`on: workflow_call`) consumed by thin
`ci.yml` callers pinned to a semver tag (#303).

## Deployment

Templates in `templates/.github/workflows/` are the source of truth. The
published reusable workflows in `agent-infra/.github/workflows/` are REAL
COMMITTED FILES materialized from them by `scripts/sync-ci-workflows.sh`
(GitHub Actions CANNOT parse symlinked workflow files — #555). Consumers
call them pinned to a tag:

```
jobs:
  ci:
    uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@v0.1.0
    secrets: inherit
```

A workflow change lands in consumers by an explicit version bump (tag +
manifest `ci.ref`); `agent-infra check` blocks on a stale pin.

## Stack Detection

| Repo has... | Template | Stack |
|------------|----------|-------|
| `pyproject.toml` | `python-ci.yml` | Python |
| `package.json` | `node-ci.yml` | Node.js |
| Neither | `docs-ci.yml` | Docs/Markdown |

## Drift

Any symlink under a consumer's `.github/workflows/` is a broken workflow
entry to GitHub Actions (#555) — `agent-infra check` reports it as an issue.
In agent-infra itself, the `pipeline-compliance` `workflow-drift` job fails
CI when `.github/workflows/{python,node,docs}-ci.yml` drift from the
templates (run `scripts/sync-ci-workflows.sh` to materialize).

## Templates

### `python-ci.yml`

- **test** — pytest with timeout, expects `tests/`
- **lint** — ruff check
- **typecheck** — mypy, auto-detects package directory

### `node-ci.yml`

- **script-validate** — `node --check` on `scripts/*.{cjs,mjs,js}` and `bin/*.js`
- **skill-lint** — validates skill YAML frontmatter (requires `scripts/` symlink)
- **typecheck** — `tsc --noEmit` (skips if no `tsconfig.json`)
- **lint** — ESLint (skips if no config)

### `docs-ci.yml`

- **markdownlint** — validates all `**/*.md`
- **link-check** — lychee link checker
- **frontmatter** — validates doc frontmatter (requires `scripts/` symlink)
