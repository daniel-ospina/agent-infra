/**
 * @clickthrough — Post-deploy clickthrough verification spec template.
 *
 * Copy this file to e2e/critical-paths/<your-journey>.clickthrough.spec.ts
 * and customize the journeys.
 *
 * Conventions:
 *   1. Real browser, no mocks — no page.route() intercepts
 *   2. Cross-page journeys — walk multiple pages
 *   3. Resilient selectors — data-testid, role, text content (not CSS classes)
 *   4. Screenshots at key states
 *   5. Outcome assertions — user-visible results, not implementation details
 *   6. Error states covered — 404, 500, empty states
 */

import { test, expect } from '@playwright/test';

const DEPLOY_URL = process.env.STAGING_URL || process.env.PROD_URL || 'http://localhost:8080';

test.describe('Clickthrough: <Journey Name>', { tag: '@clickthrough' }, () => {
  test('<Step 1: e.g., Browse to homepage>', async ({ page }) => {
    // Navigate
    await page.goto(DEPLOY_URL);
    await page.waitForLoadState('networkidle');

    // Screenshot evidence
    await page.screenshot({ path: 'test-results/clickthrough/homepage.png', fullPage: false });

    // Outcome assertion — use resilient selectors
    // Prefer: data-testid, role, accessible name, text content
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('<Step 2: e.g., Interact with a feature>', async ({ page }) => {
    await page.goto(DEPLOY_URL);

    // Click a button (resilient)
    await page.getByRole('button', { name: /search|buscar/i }).click();

    // Fill a form
    await page.getByPlaceholder(/search|buscar/i).fill('test query');

    // Submit
    await page.keyboard.press('Enter');

    // Wait for results
    await page.waitForLoadState('networkidle');

    // Screenshot
    await page.screenshot({ path: 'test-results/clickthrough/search-results.png', fullPage: false });

    // Outcome assertion — results appeared
    await expect(page.getByTestId('search-results')).toBeVisible();
  });

  test('<Step 3: e.g., Complete the journey>', async ({ page }) => {
    await page.goto(DEPLOY_URL);

    // Navigate through full journey
    // ...

    await page.screenshot({ path: 'test-results/clickthrough/journey-complete.png', fullPage: false });

    // Final outcome
    // await expect(page.getByText('Success')).toBeVisible();
  });

  test('<Edge case: e.g., Error state>', async ({ page }) => {
    // Navigate to a known bad URL
    await page.goto(`${DEPLOY_URL}/nonexistent`);

    await page.screenshot({ path: 'test-results/clickthrough/404.png', fullPage: false });

    // Verify graceful error handling
    await expect(page.getByText(/not found|no encontrado|404/i)).toBeVisible();
  });
});
