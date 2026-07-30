> ⚠️ **El Dato-specific.** This file only applies to the El Dato repo. When deploying this skill to another repo, create a `repo-conventions.md` file instead. See `repo-conventions.md` for the template.

# Eldato Conventions — test-integration

## Tooling
- **DB:** Supabase (`supabase start` for local instance)
- **Test runner:** Vitest (`npm run test:integration`)
- **Config:** `vitest.integration.config.ts` (pool: forks, sequential)
- **External API mocking:** msw (`setupServer` from `msw/node`)

## File Paths
- Test files: `src/__tests__/integration/<feature>.integration.test.ts`
- Setup: `src/__tests__/integration/setup.ts`
- Seed data: `src/__tests__/integration/seed.ts`

## Pipeline
- **Invoked by:** `test-routing` when code domain has DB/API surfaces
- **Reviewed by:** `test-review` (quality gate)
- **Verified by:** `executing-plans` verifier (`npm run test:integration`)
