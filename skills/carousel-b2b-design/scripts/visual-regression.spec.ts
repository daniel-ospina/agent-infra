/**
 * Visual regression tests for carousel template rendering consistency.
 *
 * One test per template type. Baselines are auto-created on first run
 * via Playwright's `toHaveScreenshot()`. Regenerating baselines is a
 * manual step: delete the old PNGs and re-run.
 *
 * Run: npx playwright test --project=carousel-vr
 * Update baselines: npx playwright test --project=carousel-vr --update-snapshots
 */

import { test, expect } from '@playwright/test';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const FIXTURE = path.resolve(__dirname, 'visual-regression-fixture.html');
const FIXTURE_URL = `file://${FIXTURE}`;

test.describe('carousel visual regression', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(FIXTURE_URL, { waitUntil: 'networkidle' });
  });

  // Template: photo-hero (portada)
  test('photo-hero renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.photo-hero').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-photo-hero.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: photo-top (historia)
  test('photo-top renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.photo-top').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-photo-top.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: text-slide bg-purple
  test('text-slide purple renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.text-slide.bg-purple').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-text-purple.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: text-slide bg-deep
  test('text-slide deep renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.text-slide.bg-deep').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-text-deep.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: pilar
  test('pilar renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.text-slide.pilar').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-pilar.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: cta
  test('cta renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.cta').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-cta.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });
// Template: bento grid
  test('bento grid renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.bento').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-bento.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: comparison
  test('comparison renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.comparison').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-comparison.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: stat card
  test('stat card renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.stat').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-stat.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: glass card
  test('glass card renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.glass').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-glass.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: cheatsheet
  test('cheatsheet renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.cheatsheet').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-cheatsheet.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: tutorial
  test('tutorial renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.tutorial').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-tutorial.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });

  // Template: quote
  test('quote renders consistently', async ({ page }) => {
    const slide = page.locator('.slide.quote').first();
    await expect(slide).toBeVisible();
    await expect(slide).toHaveScreenshot('template-quote.png', {
      animations: 'disabled',
      maxDiffPixelRatio: 0.01,
      threshold: 0.2,
    });
  });
});
