---
title: "CI Audit — El Dato Repo (extraction reference)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-07-30
aboutSubjects: organisation-design-team
aboutObjects: eldato, agent-infra, ci-audit
---

# CI Audit — El Dato Repo

> **Issue:** [#7554](https://github.com/lil-lawyer/eldato/issues/7554)
> **Epic:** [#7535](https://github.com/lil-lawyer/eldato/issues/7535) — Agent process infrastructure for epistemic repos
> **Phase:** 1
> **Date:** 2026-07-30
>
> **Scope (issue #239):** this document is the **eldato** CI audit, kept in agent-infra as an extraction reference. Of the workflows listed in §3, only `ci.yml` and the compliance gate exist in agent-infra (eldato's `compliance-gate.yml` §3.1 — ported/renamed as `pipeline-compliance.yml`, dogfood copy per its header); all others (including `check-drift.yml`, `enforce-skills.yml`, `replay-smoke-test.yml`) describe eldato — rows struck through are explicitly not ported. agent-infra has **zero cron-scheduled workflows**.

Full inventory of CI components in `/Users/home/eldato` with classification:
- **modular**: repo-agnostic, ready to share via `agent-infra`
- **specific**: El Dato-only, needs extraction/parameterization to be modular
- **unused**: safe to drop

---

## 1. Husky Hooks (`.husky/`)

### 1.1 `pre-commit`

**What it does:**
1. Checks that flat-file pi extensions under `operations/pi-config/extensions/` don't import sibling modules (pi's extension loader can't resolve sibling imports from flat files — see #5611).
2. Runs `npx lint-staged` (eslint --fix on staged `*.{ts,tsx}` and extension files).

**Classification:** **specific** (references `operations/pi-config/extensions/` path — El Dato-specific).

**Modularization path:** The sibling-import check is generic for any repo using pi extensions; parameterize the extension directory path. The lint-staged step is standard.

**`lint-staged` config** (from `package.json`):
```json
{
  "*.{ts,tsx}": ["eslint --fix"],
  "!ig-daemon-app/daemon-src/**": [],
  "operations/pi-config/extensions/*.ts": ["eslint --fix"]
}
```
→ Specific (excludes `ig-daemon-app/daemon-src/**`, targets `operations/pi-config/extensions/`).

### 1.2 `pre-push`

**What it does:** Local CI gate (GitHub Actions is paused for billing). Runs sequentially:
1. `npm audit --audit-level=high --production` — blocks CVEs
2. `npm run typecheck:fast` — TypeScript check with `--incremental`
3. `npm run check:deno-edge` (conditionally — only if `supabase/functions/` TypeScript files staged)
4. `npm run check:migrations` — blocks duplicate/out-of-order Supabase migration timestamps
5. `npm run check:wiki-lint` — validates wiki document formatting
6. `npm run check:skill-lint` — validates skill YAML frontmatter
7. `npm run check:skill-steps -- --strict` — validates skill step references
8. `npm run typecheck:extensions` — TypeScript check for pi extensions
9. `node scripts/check-test-regression.cjs` — blocks NEW test failures vs baseline

**Classification:** **specific** — references El Dato-specific npm scripts, paths, and conventions.

**Modularization path:** Extract to a configurable pre-push hook that runs a subset of these checks based on repo type. `check:skill-lint`, `check:skill-steps`, and `check:test-regression` are already in `agent-infra/scripts/`.

---

## 2. npm Scripts (`package.json`)

### 2.1 Modular (repo-agnostic, ready to share)

| Script | Tool | Notes |
|--------|------|-------|
| `lint` | `eslint .` | Standard; depends on `.eslintrc` |
| `check:merge-collision` | node script | Detects merge conflict markers in files. Generic. |
| `check:coverage-pruning` | node script | Detects when coverage thresholds are being lowered. |
| `check:skill-lint` | node script | ✅ **Already in `agent-infra/scripts/`** |
| `check:skill-steps` | python3 script | Validates skill `steps:` arrays reference valid skills. |
| `check:test-regression` | node script | ✅ **Already in `agent-infra/scripts/`** |
| `check:test-regression:auto-file` | node script | Auto-files GitHub issues for test regressions. |
| `check:test-debt` | node script | Reports test debt status. |
| `check:test-baseline:refresh` | node script | Refreshes the test baseline snapshot. |
| `check:untested-modules` | node script | ✅ **Already in `agent-infra/scripts/`** |
| `check:artifact-ownership` | node script | Verifies artifact ownership metadata. |
| `check:docs` | bash script | Validates `docs/00_index.md` is up to date. |
| `check:research-handoff` | bash script | Validates research handoff completeness. |
| `check:self-tests` | compound script | Runs all check-script self-tests. |

**Not yet in agent-infra, candidates for extraction:**
- `check:skill-steps` — depends on PyYAML being installed
- `check:merge-collision` — small, self-contained
- `check:coverage-pruning` — small, self-contained
- `check:artifact-ownership` — depends on doc conventions (ONTOLOGY, WIKI_SCHEMA)
- `check:docs` — depends on doc conventions
- `check:research-handoff` — depends on research workflow conventions
- `check:self-tests` — depends on all check scripts existing

### 2.2 Specific (El Dato-only, needs parameterization)

| Script | Why specific | Extraction path |
|--------|-------------|-----------------|
| `check:migrations` | Supabase migration path `supabase/migrations/` | ✅ Already in `agent-infra/scripts/` as `check-migration-order.cjs` |
| `check:drift` | Supabase-specific schema drift detection | Extract with project ID/config parameter |
| `check:edge-drift` | Supabase edge function drift | Extract with project ID parameter |
| `check:edge-schema` | Edge function schema validation | Extract with edge function path parameter |
| `check:deno-edge` | Hardcoded `supabase/functions/` path | Generic: replace path |
| `check:reconciled-functions` | Compares local vs deployed edge functions | Supabase-specific |
| `check:i18n` | i18n coverage for El Dato locales | Repo-specific locales |
| `check:assetlinks` | Android `assetlinks.json` validation | El Dato scanner-specific |
| `check:wiki-lint` | Wiki document linting to El Dato conventions | Extract with convention config |
| `check:template-schema` | Carousel/report template schema | El Dato content pipeline |
| `check:template-schema:test` | Tests for template schema checker | Same as above |
| `typecheck` | Project-specific `tsconfig.app.json`, `tsconfig.functions.json`, `tsconfig.extensions.json` | Standard; tsconfig varies per repo |
| `typecheck:fast` | Project-specific `tsconfig.app.json` | Standard; tsconfig varies per repo |
| `typecheck:extensions` | Project-specific `tsconfig.extensions.json` | Generic: works with any tsconfig |
| `test` | Vitest with project-specific config | Standard; config varies per repo |
| `test:run` | Vitest with project-specific config | Standard |
| `test:coverage` | Vitest with project-specific config | Standard |
| `test:db` | `supabase test db` — Supabase-specific | Supabase-specific |
| `test:e2e:critical` | Playwright with project-specific paths | Extract with path parameter |
| `test:e2e:smoke` | Playwright smoke-tagged tests | Extract with path parameter |
| `test:edge` | Vitest edge config | Standard |
| `test:integration` | Vitest integration config | Standard |
| `check:arch` | `npx depcruise src operations` — project paths | Generic: replace paths |
| `check:arch:changed` | Same, against `origin/main` | Generic: replace paths |
| `check:mutation` | `npx stryker run` — project config | Standard; config varies |
| `validate:og` | `VITE_BASE_URL=https://eldato.com.mx` — hardcoded URL | Extract with URL param |
| `generate:types` | `--project-id axaeagulqhanatyoxrdv` — hardcoded ID | Extract with project ID param |

### 2.3 Unused

None identified. All scripts are referenced from `.husky/pre-push`, GitHub Actions workflows, or `check:self-tests`.

---

## 3. GitHub Actions (`.github/workflows/`)

All 14 workflows (eldato inventory; see scope banner) contain El Dato-specific references. **None are currently modular.** Breakdown:

### 3.1 PR-triggered (blocking)

| Workflow | Trigger | Specific references | Modularization feasibility |
|----------|---------|---------------------|---------------------------|
| `ci.yml` (13.8KB) | `pull_request` → main | Uses `dorny/paths-filter` on groups: `code` (src/**, supabase/functions/**, e2e/**, scripts/**, config files), `app_src`, `edge_functions`, `e2e`, `supabase_db`. Scripts: `typecheck`, `lint`, `check:migrations`, `test`, `build`, `test:e2e:critical`, pgTAP, deno edge check. | **Medium** — most steps are standard lint/typecheck/test. Paths and npm script names would need parameterization. |
| `compliance-gate.yml` | `pull_request` | Runs `scripts/ci/check-pipeline-compliance.sh` — El Dato pipeline rules | **Low** — thin wrapper. Could be generic if the compliance script is parameterized. |
| `extension-tests.yml` | `pull_request` (paths: `operations/pi-config/extensions/**`) | TypeScript check for extensions, runs `scripts/run-extension-tests.sh` | **Medium** — pi extensions are generic, but paths are El Dato-specific. |
| `e2e-critical-smoke.yml` | `pull_request` (paths: e2e/**, supabase/functions/**, config files) + `schedule` (weekly) + `workflow_dispatch` + `repository_dispatch` (deploy-to-staging) | Playwright `@smoke`-tagged E2E tests against local Supabase. Uses `SUPABASE_PROJECT_ID`, `SUPABASE_DB_URL`. Also runs on cron and staging deploy events. | **Low** — Supabase-specific test infrastructure; complex multi-trigger. |

### 3.2 Push-triggered (post-merge / deploy)

| Workflow | Trigger | Specific references | Modularization feasibility |
|----------|---------|---------------------|---------------------------|
| `deploy-edge-functions.yml` | `push` → main, paths: `supabase/functions/**` | Supabase project ID, `supabase functions deploy` | **Low** — Supabase-specific deploy pipeline. |
| `deploy-migrations.yml` | `push` → main, paths: `supabase/migrations/**` | Supabase project ID, migration conventions, recovery checklist linked to El Dato docs | **Low** — Supabase-specific. |
| `typecheck-canary.yml` | `push` → main | TypeScript check on main, Cloudflare Pages false-green detection | **Medium** — Generic typecheck pattern. Cloudflare Pages note is El Dato-specific. |
| `build-ig-daemon.yml` | `push` → main (paths: `ig-daemon-app/**`) + `workflow_dispatch` | Electron builder, Apple notarization, IG Daemon DMG | **Low** — App-specific build. |
| `log-admin-merges.yml` | `pull_request` (closed, merged) | Writes to `operations/logs/commit-workflow-bypass.jsonl` | **High** — Generic pattern. Paths would need parameterization but logic is repo-agnostic. |

### 3.3 Scheduled (cron)

| Workflow | Trigger | Specific references | Modularization feasibility |
|----------|---------|---------------------|---------------------------|
| `check-drift.yml` | Daily 06:00 UTC | Schema drift vs production Supabase + docs drift (4:5 canvas dimension references in carousel skills) | **Low** — Supabase + El Dato docs conventions. |
| ~~`enforce-skills.yml`~~ | ~~Daily 06:00 UTC~~ | **NOT PRESENT in agent-infra** — eldato-only history; the script was ported in #239 and runs only as a pre-flight check (no CI workflow). | **Medium** — port the nightly cron as a follow-up (issue #239 D5). |
| ~~`replay-smoke-test.yml`~~ | ~~Weekly Mon 09:00 UTC + `workflow_dispatch`~~ | **NOT PRESENT in agent-infra** — eldato-only; agent-infra has no supabase/ dir (Replay Smoke Gate deleted from pre-flight in #239). | **Low** — Supabase-specific. |

### 3.4 Manual-only (`workflow_dispatch`)

| Workflow | Trigger | Specific references | Modularization feasibility |
|----------|---------|---------------------|---------------------------|
| `arch-check.yml` | Manual | `npx depcruise src operations` — project paths | **High** — Generic; just needs path parameters. |
| `mutation-test.yml` | Manual | `npx stryker run`, uploads to `reports/mutation/` | **High** — Generic; Stryker config varies per repo. |

### 3.5 Summary

| Classification | Count | Details |
|----------------|-------|---------|
| **modular** (ready to share) | 0 | — |
| **specific** (needs extraction) | 14 | All workflows |
| **unused** (safe to drop) | 0 | All serve a purpose |

**Highest modularization priority** (most repo-agnostic, highest reuse value):
1. `log-admin-merges.yml` — Generic PR bypass detection
2. `arch-check.yml` — Generic architecture fitness check (manual)
3. `mutation-test.yml` — Generic mutation testing (manual)
4. ~~`enforce-skills.yml`~~ — Skill protocol enforcement (eldato-only; not present in agent-infra — #239)
5. `ci.yml` — PR CI pipeline (most complex, highest value if modularized)

---

## 4. GitHub Actions Budget

**Budget check:** Manual only. The GitHub Billing API (`/repos/:owner/:repo/actions/billing/usage`) returned 404 — this endpoint requires organization-level access and is only available for GitHub Team/Enterprise plans.

**To check manually:**
1. Go to [Settings > Billing & plans](https://github.com/organizations/lil-lawyer/settings/billing) in the `lil-lawyer` org
2. Check **Actions** → included minutes, used minutes, overage

**Note from pre-push hook:** GitHub Actions is currently **paused for billing** reasons — the pre-push hook serves as the local CI gate. Per CLAUDE.md § "CI/CD — GitHub Actions paused".

**Threshold:** If < 1000 minutes remaining, CI should be PR-triggered only (no cron, no post-merge).

---

## 5. Extraction Roadmap

### Already extracted (in `agent-infra/`)
| Component | agent-infra path |
|-----------|-----------------|
| `check-test-regression` | `scripts/check-test-regression.cjs` |
| `check-migration-order` | `scripts/check-migration-order.cjs` |
| `check-skill-lint` | `scripts/check-skill-lint.mjs` |
| `check-untested-modules` | `scripts/check-untested-modules.cjs` |
| `check-doc-affiliation` | `scripts/check-doc-affiliation.cjs` |

### High-priority extraction (Phase 1)
| Component | Type | Rationale |
|-----------|------|-----------|
| `check:skill-steps` | npm script | Generic skill validation, needed by any repo with skills |
| `check:merge-collision` | npm script | Generic merge conflict detection |
| Husky `pre-commit` (sibling import check) | Hook | Generic pi extension safety check |
| `log-admin-merges.yml` | GHA workflow | Generic PR bypass detection pattern |
| ~~`enforce-skills.yml`~~ | GHA workflow (eldato) | Skill protocol enforcement — not present in agent-infra (#239); ported script is pre-flight-only |

### Medium-priority extraction (Phase 2)
| Component | Type | Rationale |
|-----------|------|-----------|
| Husky `pre-push` skeleton | Hook | Configurable pre-push gate structure |
| `ci.yml` (modular version) | GHA workflow | Path-parameterized PR CI pipeline |
| `typecheck-canary.yml` | GHA workflow | Post-merge type safety canary |
| ~~`replay-smoke-test.yml`~~ | GHA workflow (eldato) | Migration replay — not present in agent-infra (no supabase/ dir; #239) |

### Low-priority / El Dato only
| Component | Type | Rationale |
|-----------|------|-----------|
| Supabase workflows | GHA | Tightly coupled to Supabase API and project ID |
| Android deploy | GHA | App-specific build pipeline |
| Content pipeline scripts | npm | Specific to El Dato carousel/content pipeline |

---

## 6. Obsolescence Notes

- **Husky `_/husky.sh`**: The `_/husky.sh` file is deprecated and prints a warning. It is included by Husky's own `.husky/_/h` dispatcher but the v10 deprecation warning is cosmetic for now. All stub hooks in `_/` (applypatch-msg, commit-msg, post-*, pre-*) are default Husky pass-throughs — they source `_/h` which delegates to the actual hook files in `.husky/`. Only `pre-commit` and `pre-push` have real implementations.
- **`arch-check.yml` and `mutation-test.yml`**: Intentionally manual-only to save Actions costs. Both have documented local equivalents via npm scripts.
