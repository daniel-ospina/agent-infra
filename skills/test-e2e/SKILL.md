---
name: test-e2e
description: "Use when writing Playwright end-to-end tests. Two depths: smoke (single session, @smoke tag, <30s, key journeys only) and full (multi-page flows, visual regression, @e2e tag). Uses existing critical-paths Playwright project. Invoked by test-routing when critical paths need e2e coverage."
domain: engineering
allowed-tools: read write edit bash grep find
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Multi-repo:** Universal patterns. For repo-specific tooling (Playwright config, file paths, pipeline skills), see `repo-conventions.md`.

# Test E2E — Playwright

## Overview

Guides agents through writing Playwright e2e tests. Two depth modes controlled by a parameter, not separate skill files.

**Announce at start:** "I'm using the test-e2e skill to write e2e tests (depth: smoke|full)."

Invoked by `test-routing` when critical paths are detected. Uses the existing `critical-paths` Playwright project — no new config needed.

### When to Use

- **Smoke (depth=smoke):** Key user journeys, single session, fast feedback. Tag: `@smoke`. Runs via `npm run test:e2e:smoke`.
- **Full (depth=full):** Multi-page flows, visual regression, comprehensive coverage. Tag: `@e2e`. Runs via `npm run test:e2e:critical`.

### When NOT to Use

- DB/API testing without browser → use test-integration
- Pure unit logic → use test-writing
- No critical path changes → skip e2e

## Setup

Already configured in your Playwright project. Verify:

```bash
npx playwright test --project=<your-project> --list
```

See `repo-conventions.md` for project name, tags, and npm scripts.

## Process

### Step 1 — Read Critical Paths

From the verification plan (test-routing output), extract critical paths:

```
Critical paths:
- reservation-flow: auth → browse → book → confirm (depth=smoke)
- profile-payment: profile → payment → upgrade (depth=full)
```

### Step 2 — Create Test File

Name convention: `<feature>.<mode>.spec.ts` in your e2e directory.

- Smoke: `reservation.smoke.spec.ts`
- Full: `profile-payment.e2e.spec.ts`

See `repo-conventions.md` for directory paths.

### Step 3 — Write Tests by Depth

#### Smoke Mode (depth=smoke)

Single session, key journeys only. Each test < 10s. Full suite < 30s.

```typescript
import { test, expect } from '@playwright/test';

test.describe('reservation flow', () => {
  test('completes reservation from deal page', { tag: '@smoke' }, async ({ page }) => {
    // Login
    await page.goto('/login');
    await page.fill('[data-testid="email-input"]', 'test@example.com');
    await page.fill('[data-testid="password-input"]', 'password');
    await page.click('[data-testid="login-button"]');
    await expect(page).toHaveURL('/');

    // Browse to deal
    await page.goto('/deals/test-deal');
    await expect(page.locator('[data-testid="deal-title"]')).toBeVisible();

    // Book
    await page.click('[data-testid="reserve-button"]');
    await expect(page.locator('[data-testid="booking-confirmation"]')).toBeVisible();

    // Confirm
    await page.click('[data-testid="confirm-booking"]');
    await expect(page.locator('[data-testid="success-page"]')).toBeVisible();
    await expect(page.locator('[data-testid="reservation-id"]')).not.toBeEmpty();
  });

  test('unauthenticated user redirected to login', { tag: '@smoke' }, async ({ page }) => {
    await page.goto('/deals/test-deal');
    await page.click('[data-testid="reserve-button"]');
    await expect(page).toHaveURL(/\/login/);
  });
});
```

#### Full Mode (depth=full)

Multi-page flows, visual regression, comprehensive.

```typescript
import { test, expect } from '@playwright/test';

test.describe('profile to payment upgrade', () => {
  test('updates profile and upgrades plan', { tag: '@e2e' }, async ({ page }) => {
    // Login
    await page.goto('/login');
    await page.fill('[data-testid="email-input"]', 'test@example.com');
    await page.fill('[data-testid="password-input"]', 'password');
    await page.click('[data-testid="login-button"]');

    // Update profile
    await page.goto('/profile');
    await page.fill('[data-testid="name-input"]', 'New Name');
    await page.click('[data-testid="save-profile"]');
    await expect(page.locator('[data-testid="success-toast"]')).toBeVisible();

    // Navigate to payment — verify profile data carried over
    await page.goto('/payment/upgrade');
    await expect(page.locator('[data-testid="user-name"]')).toHaveText('New Name');
    
    // Visual regression
    await expect(page).toHaveScreenshot('payment-form.png');

    // Submit payment
    await page.fill('[data-testid="card-number"]', '4242424242424242');
    await page.click('[data-testid="submit-payment"]');
    await expect(page.locator('[data-testid="upgrade-success"]')).toBeVisible();
  });

  test('shows error on declined card', { tag: '@e2e' }, async ({ page }) => {
    await page.goto('/payment/upgrade');
    await page.fill('[data-testid="card-number"]', '4000000000000002'); // decline card
    await page.click('[data-testid="submit-payment"]');
    await expect(page.locator('[data-testid="payment-error"]')).toBeVisible();
    await expect(page.locator('[data-testid="card-number"]')).toBeEditable(); // form still usable
  });
});
```

### Step 4 — Visual Regression (depth=full only)

```typescript
// Baseline auto-created on first run. Update with --update-snapshots.
await expect(page.locator('.pricing-card')).toHaveScreenshot('pricing-card.png', {
  maxDiffPixels: 100  // tolerate minor anti-aliasing differences
});
```

### Step 5 — Selector Rules

Prefer `data-testid` selectors — survive text/translation changes:

```typescript
// ✅ Good — survives i18n, text changes
page.locator('[data-testid="reserve-button"]')
page.locator('[data-testid="booking-confirmation"]')

// ❌ Bad — breaks on translation
page.locator('text=Reservar ahora')
page.locator('button:has-text("Confirmar")')
```

## Pipeline Handoff

**Invoked by:** your routing/planning pipeline when critical paths detected
**Dispatches to:** test files written, then your test review/quality gate
**Consumed by:** your CI/verification step (see conventions for repo commands)

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Smoke tests | Critical path breaks ship to production — auth, booking, payment failures |
| Visual regression | UI regressions invisible — layout breaks, missing elements, style corruption |
| Selector rules | Tests break on every i18n change or CTA text update — maintenance burden |
| @smoke tag | Smoke suite runs full e2e — CI slows down, developers skip tests |
