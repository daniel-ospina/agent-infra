# CI Templates

Per-stack CI workflow templates deployed as symlinks into each repo.

## Deployment

CI templates are deployed via **symlinks** (same pattern as extensions and skills):

```
<repo>/.github/workflows/<template> → agent-infra/templates/.github/workflows/<template>
```

Updates to templates propagate automatically — no manual sync needed.

## Stack Detection

| Repo has... | Template | Stack |
|------------|----------|-------|
| `pyproject.toml` | `python-ci.yml` | Python |
| `package.json` | `node-ci.yml` | Node.js |
| Neither | `docs-ci.yml` | Docs/Markdown |

## Divergence

A repo that needs custom CI replaces the symlink with a local file:

```bash
rm .github/workflows/python-ci.yml
cp $AGENT_INFRA_PATH/templates/.github/workflows/python-ci.yml .github/workflows/python-ci.yml
# Edit the file locally
```

`agent-infra check` warns when it finds a local file where a symlink is expected.

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
