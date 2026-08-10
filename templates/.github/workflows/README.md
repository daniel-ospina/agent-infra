# GitHub Actions workflow templates

Reusable workflow templates for agent-infra and consumer repos (eldato,
tortoise, premise-labs). Consumer repos symlink or copy these into their
`.github/workflows/`.

Templates:
- `docs-ci.yml` — markdownlint, lychee link check, doc frontmatter
- `node-ci.yml` — Node script validation, skill lint, typecheck, lint
- `python-ci.yml` — Python CI
- `pipeline-compliance.yml` — pipeline compliance gate (below)

---

## pipeline-compliance.yml — pipeline compliance gate

Deterministic (no-LLM) CI gate: verifies a PR followed the agent pipeline
before merge — scoping, plan, code-review, and test-coverage **evidence** —
instead of reviewing code quality. Backed by
[`scripts/check-pipeline-compliance.sh`](../../scripts/check-pipeline-compliance.sh).

### What it checks

For a PR it checks, in order (all failures printed, not just the first):

| # | Check | Evidence looked for | Produced by |
|---|-------|--------------------|-------------|
| a | Linked issue | PR body has a closing keyword (`Fixes #N` / `Closes #N` / `Resolves #N`; full GitHub keyword set accepted) | issue-scoping |
| b | Scoping comment | Linked issue has a comment with the `<!-- issue-scoping:` marker | issue-scoping |
| c | Code-review evidence | PR body or any PR commit message references review dispatch (`code-review`, `reviewer`, `[review]`, `VGATE`, `review recorded`, `review-enforcer`) | code-review |
| d | Plan doc | PR adds/modifies `docs/plans/*.md`, **or** scoping comment contains a `Wiring` section (wiring-check table) | writing-plans, issue-scoping |
| e | Test coverage evidence | PR touching runtime code (`extensions/**/*.ts` excl. `*.test.ts`, `extensions/**/*.js`, `bin/*.js`) must have new/updated `*.test.ts` / `*.test.js` in the diff **or** test-run markers in PR body/commits (`tests green`, `N passed`, `N/N`, `VGATE PASS`, `test suite`, `pytest`, `npm test`, `vitest`) | code-review (Step 0), test-writing |

### Tier × check matrix

| Issue label | a. Linked issue | b. Scoping | c. Review evidence | d. Plan doc | e. Test coverage |
|-------------|:---:|:---:|:---:|:---:|:---:|
| `complexity:micro` | ✅ required | ⏭️ skipped | ⏭️ skipped | ⏭️ skipped | ⏭️ skipped |
| `complexity:standard` | ✅ required | ✅ required | ✅ required | ✅ required | ✅ required |
| `complexity:complex` | ✅ required | ✅ required | ✅ required | ✅ required | ✅ required |
| (no complexity label) | ✅ required | ✅ required | ✅ required | ⏭️ skipped | ✅ required |

Check **e** only applies when the PR diff touches runtime code; PRs whose
changed files are only docs/skills/templates/config (no runtime code) skip it.

Exit codes: `0` compliant · `1` blocked · `2` usage/script error.

### Wiring option 1 — copy into a consumer repo (self-contained)

```sh
cp templates/.github/workflows/pipeline-compliance.yml <consumer>/.github/workflows/
cp scripts/check-pipeline-compliance.sh <consumer>/scripts/
```

The `pull_request` trigger then runs the gate on every PR with zero config.
Repo and PR number come from the GitHub context — nothing hardcoded.

### Wiring option 2 — reuse from agent-infra (no copy)

In the consumer repo, create a thin workflow:

```yaml
name: Pipeline Compliance
on:
  pull_request:
permissions:
  contents: read
  issues: read
  pull-requests: read
jobs:
  pipeline-compliance:
    uses: daniel-ospina/agent-infra/.github/workflows/pipeline-compliance.yml@main
    with:
      pr-number: ${{ github.event.pull_request.number }}
```

The script is auto-fetched from agent-infra when absent (override the source
with a `PIPELINE_COMPLIANCE_SCRIPT_URL` repo variable). Agent-infra itself
dogfoods the gate: `.github/workflows/pipeline-compliance.yml` is an adapted
copy (check context `pipeline-compliance`, required on main via branch
protection) that runs the in-repo script directly.

### Branch protection (recommended)

The gate only **reports** unless branch protection requires it. On the
default branch, require the **Pipeline Compliance** check — this is the step
that actually blocks merges without pipeline evidence.

### Emergency override

Pass `skip: true` to the workflow input, or set `PIPELINE_COMPLIANCE_SKIP=1`
in the workflow env. The script prints a loud warning and exits 0.

### Local testing (no GitHub access needed)

```sh
# Print what would be checked (no gh calls)
PIPELINE_COMPLIANCE_DRY_RUN=1 bash scripts/check-pipeline-compliance.sh 123

# Exercise every failure message path offline (simulated, exits 1)
PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
  bash scripts/check-pipeline-compliance.sh 123
```
