---
name: test-design
description: "Use before any feature implementation to map integration surfaces and assign test layers per surface. Produces a structured integration surface map that prevents integration bugs before code is written."
domain: engineering
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

<!-- ported from the primary repo -->
# Test Design — Integration Surface Mapping

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Overview

Map every integration surface a feature touches and decide the correct test layer for each — **before writing any code**. This is a planning-time skill; the TDD skill handles code-time test writing.

**Announce at start:** "I'm using the test-design skill to map integration surfaces before implementation. 💡 This skill runs fine on **Sonnet**."

**Design rationale:** Defects cluster at boundaries, not in the middle of valid ranges ([BVA principle](https://www.baeldung.com/cs/bva)). The [Testing Trophy](https://kentcdodds.com/blog/the-testing-trophy-and-testing-classifications) and [Testing Honeycomb](https://medium.com/@igani/unlocking-effective-testing-strategies-pyramid-diamond-honeycomb-and-more-bcdf7887334d) models argue that for integration-heavy systems, integration tests should be the largest layer — not unit tests. The traditional 70/20/10 pyramid ratio doesn't apply when most complexity lives at boundaries. As [Martin Fowler notes](https://martinfowler.com/articles/2021-test-shapes.html), the shape debate matters less than writing tests that "establish clear boundaries, run quickly & reliably, and only fail for useful reasons."

## When to Use

- Before implementing any feature, bugfix, or refactor that might touch integration boundaries
- During `issue-scoping` or `writing-plans` when identifying test strategy
- When reviewing a plan to verify test coverage is adequate

**When NOT to use:**
- Pure copy/label/i18n changes with no logic
- Documentation-only changes
- Changes entirely within a single function with no external calls

## Process

### Step 1 — Identify Integration Surfaces

For the feature being planned, scan for every boundary the code will cross. Fill in this table:

| Surface Type | Specific Surface | Data Flow | Contract |
|---|---|---|---|
| **External services** | Each service called (Supabase, HubSpot, Claude API, Stripe, Cloudinary, Meta CAPI, Resend, etc.) | In / Out / Bidirectional | Request/response shape (zod schema, TS interface, or prose) |
| **DB tables/views** | Each table/view touched + which columns | Read / Write / Both | Expected row shape, nullability, FK constraints |
| **Auth boundaries** | RLS policies crossed, role checks, `auth.uid()` usage | Guard (blocks access) | Who can access what, service-role vs user-role |
| **Events/webhooks** | Emitted or consumed | In / Out | Payload format, idempotency key, retry behavior |
| **State mutations** | Shared state changed (React state, closures, caches, localStorage) | Internal | State shape before/after, mutation trigger |
| **Concurrent access** | Parallel operations (queue processing, reservation claims, counter increments) | Contested | Lock mechanism, dedup strategy |

**Data flow direction matters** — it determines which side owns the test. Outbound surfaces need contract validation on the sender; inbound surfaces need validation + error handling on the receiver; bidirectional needs both.

### Step 2 — Assign Test Layer Per Surface

For each surface identified, assign the correct test layer using these rules:

| Surface | Test Layer | Rationale |
|---|---|---|
| Pure logic, transforms, utils | **Unit** (Vitest) | No external dependencies |
| SQL business logic (transactions, reward claims, referral processing, RLS-guarded lookups) | **pgTAP** (`npm run test:db`) | TS mocks cannot verify SQL logic — this has caused production bugs |
| DB reads/writes through Supabase client | **Integration** (Vitest, real Supabase) | Mocked Supabase hides RLS, trigger, and FK issues |
| Auth flows, RLS policies | **pgTAP** + **Integration** | pgTAP for policy logic, integration for end-to-end auth flow |
| External API calls (HubSpot, Stripe, Claude API) | **Integration** (real or sandbox API) | Mock only when API is expensive/slow; prefer sandbox |
| User-facing critical paths (auth, payments, reservations) | **E2E** (Playwright) | Full browser flow against real backend |
| Webhooks received | **Integration** | Real HTTP request to edge function, verify side effects |
| React state/closures | **Unit** + **Integration** | Unit for logic, integration for component interaction |

**Hard rule:** If a surface involves a Postgres function implementing business logic → pgTAP is **required**, not optional. TS mocks alone are a blocking issue.

**Layer allocation principle:** When most of a feature's complexity lives at integration boundaries (multiple services, DB operations, auth checks), weight the test effort toward integration tests — not unit tests. Follow the Testing Trophy: integration tests catch the bugs that actually ship to production. Reserve unit tests for pure logic and transforms.

### Test Selector Conventions

When writing or updating component tests, follow Testing Library's selector hierarchy to keep tests resilient:

1. **`getByRole`** — preferred. Matches user interaction patterns, survives text/translation changes.
2. **`getByLabelText` / `getByPlaceholderText`** — for form inputs.
3. **`getByText`** — use with i18n key resolution from `@/test/test-utils`:
   ```tsx
   import { t } from '@/test/test-utils';
   screen.getByText(t('subscription.tiers.solo.name'));  // survives tier renames
   ```
4. **`getByTestId`** — last resort for truly dynamic content.

**Anti-patterns** (caused 50+ test failures in #2551):
- ❌ `screen.getByText('Solo')` — breaks on tier rename
- ❌ `screen.getAllByRole('button', { name: /prueba gratis 14 días/i })` — breaks on CTA text change
- ❌ Hardcoded strings in any language — use i18n key resolution instead



> Also covered by test-design skill (#4694).
### Step 3 — Run Integration Checklist

For **each integration boundary** identified in Step 1, verify these questions are addressed in the test plan:

**Contract & Data Shape:**
- [ ] **Contract defined?** Request/response shape documented or typed (zod schema, TypeScript interface) — not just "calls the API"
- [ ] **Boundary values tested?** 0, 1, max-1, max for all numeric inputs and array lengths at the boundary
- [ ] **Empty vs null handled?** Empty array `[]` vs `null` vs `undefined` — each behaves differently at integration seams

**Failure Modes** (enumerate per surface — don't just say "handles errors"):
- [ ] **Timeout?** What happens when the service doesn't respond? Is there a timeout configured?
- [ ] **Rate limit (429)?** Does the caller back off or queue for retry?
- [ ] **Service down (503)?** Does the feature degrade gracefully or fail hard?
- [ ] **Bad request (400)?** Is the caller validating before sending, or relying on server validation?
- [ ] **Malformed response?** What if the response shape doesn't match the contract (missing fields, wrong types)?
- [ ] **Network error?** DNS failure, connection refused, TLS error — distinct from timeout

**Data Integrity:**
- [ ] **Atomic writes?** Multiple DB writes in a single operation use a transaction or are idempotent
- [ ] **Idempotent webhooks?** Receiving the same webhook twice produces the same result (not duplicate side effects)
- [ ] **Concurrent access safe?** Two simultaneous requests don't corrupt shared state or create duplicates
- [ ] **Ordering guaranteed?** If operations must happen in sequence, is the ordering enforced (not assumed)?

### Step 4 — Check Against Historical Bug Patterns

Scan the feature for these 6 known bug categories. If any pattern is detected, flag it explicitly in the surface map:

| Bug Pattern | Detection Signal | Required Verification |
|---|---|---|
| **Stale closures** | React hooks capturing values used in async callbacks or timers | Test that callback sees updated state, not stale captured value |
| **SQL business logic** | Any Postgres function with `INSERT`, `UPDATE`, transaction, or `RETURN QUERY` | pgTAP test — not TS mock. Verify edge cases: missing rows, wrong user, concurrent calls |
| **Silent function skips** | Function that generates/sends content (messages, emails, notifications) | Verify execution path reaches the real generation/send function — not a hardcoded fallback or early return |
| **Race conditions** | Concurrent access to shared resource (queue processing, reservation claims, counter increments) | Test with concurrent requests; verify no duplicates, no lost updates |
| **Conditional guards** | `if` statements guarding business logic (auth checks, feature flags, status transitions) | Boundary value tests for each guard condition; test both sides of every branch |
| **N+1 queries** | Loop that makes a DB query per item instead of a single batched query | Flag in surface map with join optimization note; test with N > 1 items and verify query count |

### Step 5 — Output the Surface Map

Produce the final output in this format:

```markdown
## Integration Surface Map

| # | Surface | Type | Data Flow | Test Layer | Contract | Key Failure Modes |
|---|---------|------|-----------|-----------|----------|-------------------|
| 1 | [specific surface] | [External service / DB / Auth / Event / State / Concurrent] | [In / Out / Both] | [Unit / Integration / E2E / pgTAP] | [shape reference or brief description] | [top 2-3 failure modes to test] |

### Bug Pattern Flags
- [List any historical bug patterns detected, with the required verification]

### Checklist Notes
- [Any integration checklist items that need special handling]
- [Failure modes that need explicit test cases]
```

## No Integration Boundaries

If the feature has **no integration surfaces** (pure logic, pure UI with no data, config-only changes):

> **No integration boundaries — unit TDD only.** No integration surface map needed. Proceed directly to TDD skill for unit-level test-first development.

This is a valid and expected output — not every feature crosses integration boundaries.

## Key Principles

- This skill runs at **planning time**, before any code is written
- The surface map is consumed by `writing-plans` and `executing-plans` to structure test steps
- Every surface must have an assigned test layer — "none" is not valid for an identified surface
- pgTAP for SQL business logic is non-negotiable — this is the #1 source of production bugs that mocks miss
- The integration checklist prevents the most common boundary bugs; skip items only when genuinely not applicable
- When in doubt about test layer, prefer the more thorough option (integration over unit, E2E over integration)
- Weight test effort toward integration boundaries, not pure logic — bugs ship at seams, not in utils
- Document contracts and failure modes per surface — "calls the API" is not a test plan

### When to Use PBT

Property-based testing (PBT) is a testing **technique** — not a separate test layer. It complements unit tests by generating random inputs and checking invariants (properties) that must hold for all inputs. PBT catches invariant violations and edge-case combinations that example-based tests miss.

**Recommended framework:** [`fast-check`](https://fast-check.dev/) + [`@fast-check/vitest`](https://fast-check.dev/docs/integrations/vitest/) for property-based tests in Vitest.

> **Install prerequisite:** `npm install --save-dev fast-check @fast-check/vitest`

#### PBT Applicability by Surface Type

| Surface Type | PBT? | Property Types |
|---|---|---|
| Pure logic, transforms, utils | ✓ | Idempotency, commutativity, roundtrip, model-based |
| SQL business logic | — | Use pgTAP instead; schema constraints cover invariants |
| DB reads/writes (Supabase client) | — | Use integration tests; DB state too complex for PBT |
| Auth boundaries (RLS, role checks) | — | Use pgTAP + integration; authorization is binary, not invariant-based |
| External API calls | — | Use integration tests with sandbox; PBT can't validate external contracts |
| React state/closures | ✓ | State invariants, reducer properties, action commutativity |
| Serialization/deserialization | ✓ | Roundtrip: `deserialize(serialize(x)) === x` |
| Sorting/filtering/search | ✓ | Idempotency: `sort(sort(arr)) === sort(arr)` |

#### Property Identification → Arbitrary Generation → Assertion

1. **Identify the property:** What must always be true? (idempotency, roundtrip, commutativity, invariant)
2. **Generate arbitraries:** Use `fc.integer()`, `fc.string()`, `fc.array()`, or compose custom arbitraries
3. **Assert the property:** Use `fc.assert` or `test.prop` (from `@fast-check/vitest`)

```typescript
// Example: idempotency of sort function
import { test } from 'vitest';
import { fc, test as fcTest } from '@fast-check/vitest';

fcTest.prop('sort is idempotent', [fc.array(fc.integer())], (arr) => {
  const once = sort([...arr]);
  const twice = sort([...once]);
  expect(twice).toEqual(once);
});
```

⚠️ **~50% false discovery rate:** LLM-generated property violations are often incorrect assertions or design choices, not real bugs. Verify each failure before changing production code.

## Pipeline Handoff

> ⚠️ **This surface map is NOT the final deliverable.**

If you are a sub-agent in a planning pipeline (running `issue-scoping` → `test-design` → `writing-plans`), the surface map is an **intermediate artifact**. The final deliverable is the **implementation plan document** produced by `writing-plans`.

**After producing this surface map, continue immediately to invoke `writing-plans` with this surface map as input.** Do NOT stop here — stopping after `test-design` without proceeding to `writing-plans` leaves the pipeline incomplete. A surface map alone is not a complete implementation plan.

**If you are a standalone agent** (not in a planning pipeline), the surface map is your deliverable. State clearly at the end: "Integration surface map complete. This is a standalone test-design artifact — no plan document was requested."
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
