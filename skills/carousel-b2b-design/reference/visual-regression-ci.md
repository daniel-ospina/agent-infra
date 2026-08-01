# Visual Regression CI Setup

This documents the carousel visual regression testing setup for CI.

## Local Usage

```bash
# Run visual regression tests (compare against baselines)
npx playwright test --project=carousel-vr

# Update baselines after intentional CSS/template changes
npx playwright test --project=carousel-vr --update-snapshots
```

## CI Setup (GitHub Actions)

When adding this to CI, use the Playwright Docker image for deterministic rendering:

```yaml
# .github/workflows/carousel-vr.yml
name: Carousel Visual Regression
on:
  pull_request:
    paths:
      - '.agents/skills/carousel-b2b-design/scripts/build_carousel.cjs'
      - '.agents/skills/carousel-b2b-design/scripts/render.cjs'
      - '.agents/skills/carousel-b2b-design/scripts/visual-regression.spec.ts'
      - '.agents/skills/carousel-b2b-design/scripts/visual-regression-fixture.html'
      - '.agents/skills/carousel-b2b-design/scripts/visual-regression.spec.ts-snapshots/**'
      - 'playwright.config.ts'

jobs:
  carousel-vr:
    runs-on: ubuntu-latest
    container:
      image: mcr.microsoft.com/playwright:v1.59.1-jammy
    steps:
      - uses: actions/checkout@v5
      - run: npm ci
      - run: npx playwright test --project=carousel-vr
      - name: Upload diff artifacts on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: carousel-vr-diffs
          path: test-results/
          retention-days: 7
```

### Design Decisions

- **Playwright `toHaveScreenshot()`** — zero new dependencies, built into our existing Playwright setup
- **Docker-locked environment** (`mcr.microsoft.com/playwright:v1.59.1-jammy`) — deterministic rendering regardless of runner OS
- **Generous thresholds** (`maxDiffPixelRatio: 0.01, threshold: 0.2`) — prevents anti-aliasing flakes
- **`animations: 'disabled'`** — eliminates animation-driven false positives
- **`deviceScaleFactor: 2`** — retina-quality baselines, catches sub-pixel rendering issues

### Baseline Management

- Baselines live in `visual-regression.spec.ts-snapshots/` (alongside the test file)
- First run auto-creates baselines (Playwright default behavior)
- To update baselines after intentional changes: `--update-snapshots`
- Baselines must be regenerated when Playwright or Chrome version changes

### Failure Handling

- False positive rate above 20% → document issues and ABANDON (per issue #4296 spec)
- Flaky tests are worse than no tests — if persistent anti-aliasing noise cannot be resolved with threshold tuning, increase threshold or use blur pre-processing
