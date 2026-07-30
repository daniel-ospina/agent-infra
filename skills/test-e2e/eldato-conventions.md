> ⚠️ **El Dato-specific.** This file only applies to the El Dato repo. When deploying this skill to another repo, create a `repo-conventions.md` file instead. See `repo-conventions.md` for the template.

# Eldato Conventions — test-e2e

## Tooling
- **Browser automation:** Playwright (`@playwright/test`)
- **Config:** `playwright.config.ts` → `critical-paths` project
- **Smoke:** `npm run test:e2e:smoke` (`--grep @smoke`)
- **Full:** `npm run test:e2e:critical`

## File Paths
- Smoke tests: `e2e/critical-paths/<feature>.smoke.spec.ts`
- Full tests: `e2e/critical-paths/<feature>.e2e.spec.ts`
- Visual baselines: auto-created by `toHaveScreenshot()`

## Selector Convention
- Use `data-testid` attributes (survive i18n/text changes)
- `page.locator('[data-testid="reserve-button"]')`

## Pipeline
- **Invoked by:** `test-routing` when critical paths detected
- **Reviewed by:** `test-review` (quality gate)
- **Verified by:** `executing-plans` verifier (`npm run test:e2e:smoke` or `test:e2e:critical`)
