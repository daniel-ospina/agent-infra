---
name: test-integration
description: "Use when writing integration tests for DB surfaces, API calls, or auth flows. Guides agents through Supabase local setup, Vitest configuration, transaction isolation, and RLS verification. Invoked by test-routing when integration surfaces are detected."
domain: engineering
allowed-tools: read write edit bash grep find
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Multi-repo:** Universal patterns. For repo-specific tooling (Supabase, file paths, pipeline skills), see `repo-conventions.md`.

# Test Integration — Supabase + Vitest

## Overview

Guides agents through writing integration tests against real infrastructure. No mocks for the database — tests run against a local Supabase instance with production schema and RLS policies.

**Announce at start:** "I'm using the test-integration skill to write integration tests."

Invoked by `test-routing` when the surface map has DB surfaces, API calls, or auth flows.

### When to Use

- DB reads/writes through Supabase client
- SQL business logic (transactions, RLS-guarded queries, Postgres functions)
- Auth flows (login, session, role checks)
- External API calls (HubSpot, Stripe) — use msw for these

### When NOT to Use

- Pure logic/transforms with no external deps → use test-writing (unit)
- Full browser user flows → use test-e2e
- No DB surfaces in the surface map → skip integration

## Setup

### One-Time Setup

Start your DB locally with production schema. See `repo-conventions.md` for the command and config.

### Per-Test Setup

```typescript
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_ANON_KEY!
);

// ponytail: service-role client for cleanup only
const adminClient = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!
);
```

## Process

### Step 1 — Read Surface Map

From the verification plan (test-routing output), extract DB surfaces:

```
DB surfaces to test:
- profiles (write) — RLS: users can only update own profile
- deals (read) — RLS: users can only see own deals
```

### Step 2 — Create Test File

Name convention: `src/__tests__/integration/<feature>.integration.test.ts`

### Step 3 — Write Tests

Follow these patterns per surface type:

#### DB Read Tests

```typescript
import { describe, it, expect, beforeAll, afterAll } from 'vitest';

describe('get_user_deals', () => {
  let userId: string;

  beforeAll(async () => {
    // Seed: create test user + 3 deals
    const { data: user } = await adminClient.auth.admin.createUser({
      email: 'test@integration.test',
      password: 'test123'
    });
    userId = user.id;
    await seedDeals(userId, 3);
  });

  afterAll(async () => {
    await adminClient.auth.admin.deleteUser(userId);
  });

  it('returns deals for authenticated user', async () => {
    const { data, error } = await supabase
      .rpc('get_user_deals', { p_user_id: userId });
    expect(error).toBeNull();
    expect(data).toHaveLength(3);
  });

  it('enforces RLS — cannot see other user deals', async () => {
    // Create second user, query as first user
    const { data: other } = await adminClient.auth.admin.createUser({
      email: 'other@integration.test',
      password: 'test123'
    });
    const { data, error } = await supabase
      .rpc('get_user_deals', { p_user_id: other.user.id });
    expect(data).toHaveLength(0); // RLS blocks
    await adminClient.auth.admin.deleteUser(other.user.id);
  });
});
```

#### DB Write Tests

```typescript
it('creates deal and returns it', async () => {
  const { data, error } = await supabase
    .rpc('create_deal', { p_title: 'Test Deal', p_price: 99 });
  expect(error).toBeNull();
  expect(data).toMatchObject({ title: 'Test Deal', price: 99 });
});

it('rejects deal without required title', async () => {
  const { error } = await supabase
    .rpc('create_deal', { p_title: null, p_price: 99 });
  expect(error).not.toBeNull(); // constraint violation
});
```

#### Transaction Atomicity Tests

```typescript
it('rolls back on failure — atomic writes', async () => {
  // ponytail: verify both operations roll back, not just the second one
  const before = await getDealCount(userId);
  
  // Force failure by passing invalid data for second operation
  const { error } = await supabase.rpc('create_deal_with_credits', {
    p_user_id: userId,
    p_title: 'Test',
    p_credits: -1  // invalid — should trigger rollback
  });
  
  expect(error).not.toBeNull();
  const after = await getDealCount(userId);
  expect(after).toBe(before); // no partial write
});
```

#### Race Condition Tests

```typescript
it('handles concurrent claims — only one wins', async () => {
  const dealId = await createDeal('Limited Deal');
  
  // ponytail: two concurrent claims, only one succeeds
  const [r1, r2] = await Promise.all([
    supabase.rpc('claim_deal', { p_deal_id: dealId, p_user_id: userA }),
    supabase.rpc('claim_deal', { p_deal_id: dealId, p_user_id: userB })
  ]);
  
  // Exactly one succeeded
  const successes = [r1, r2].filter(r => !r.error).length;
  expect(successes).toBe(1);
});
```

### Step 4 — External API Mocking (msw)

For non-DB external APIs (HubSpot, Stripe), use msw:

```typescript
import { http, HttpResponse } from 'msw';
import { setupServer } from 'msw/node';

const server = setupServer(
  http.post('https://api.hubspot.com/crm/v3/objects/contacts', () => {
    return HttpResponse.json({ id: '123', properties: {} });
  })
);

beforeAll(() => server.listen());
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

### Step 5 — Verify All Failure Modes

Per surface, test at minimum:
- ✅ Happy path
- ✅ Missing required fields (constraint violation)
- ✅ RLS enforcement (wrong user)
- ✅ Concurrent access (race condition)
- ✅ Transaction atomicity (if multiple writes)

## Vitest Config

Create an integration-specific Vitest config with sequential execution to avoid DB locking. See `repo-conventions.md` for the config file path and pool settings.

## Pipeline Handoff

**Invoked by:** your routing/planning pipeline when DB/API surfaces are detected
**Dispatches to:** test files written, then your test review/quality gate
**Consumed by:** your CI/verification step (see conventions for repo commands)

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Real DB (use mocks) | Mocked Supabase hides RLS violations, schema mismatches, trigger bugs |
| Transaction tests | Partial writes corrupt data — deal created but credits not deducted |
| RLS tests | Security vulnerabilities — users access other users' data |
| Race condition tests | Duplicate claims, lost updates under concurrent load |
