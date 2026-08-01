---
name: app-test
description: "Automated E2E testing for desktop (Electron) and web apps. Launches app, runs test scenarios, screenshots, verifies logs and database state. Invoke when asked to test the app, verify a release, or smoke-test after deploy."
domain: engineering
type: Bounded
status: live
allowed-tools: read write edit bash grep find web_search web_fetch
tags: [testing, e2e, electron, playwright, desktop, web]
summary: "Automated E2E testing for desktop and web apps — Playwright CDP + cliclick."
created: 2026-07-11
updated: 2026-07-11
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# App Test — Automated E2E Testing

Tests desktop (Electron) and web apps end-to-end. Detects app type, sets up tools, runs scenarios, reports results with screenshots.

## When to Invoke

- User says "test the app", "verify the release", "smoke test", "does the app work"
- After a DMer release — verify daemon starts, UI works, analytics fire
- After a web app deploy — verify pages load, forms work, no console errors
- When setting up CI/CD for a new app

## Phase 0 — Detection & Setup

### 0.1 — Detect app type

| Signal | App type | Tools |
|--------|----------|-------|
| `dmer` in repo name, Electron app | Desktop (Electron) | Playwright CDP + cliclick |
| Next.js, React, web app | Web | Playwright browser |
| `ig-daemon-app`, DMer | Desktop (Electron) | Playwright CDP + cliclick |

### 0.2 — Install tools (once)

```bash
# osascript — built into macOS, no install needed (handles clicks, keystrokes, menus)
# Verify Playwright is available
npx playwright --version 2>/dev/null || npm install playwright
```

### 0.3 — Launch app for testing

**Option A: Development (source code)** — Playwright's native `electron.launch()`:
```typescript
const { _electron: electron } = require('playwright');
const electronApp = await electron.launch({ args: ['src/main.js'] });
const window = await electronApp.firstWindow();
```
No CDP port needed. Playwright manages lifecycle.

**Option B: Installed app (DMG)** — CDP + `connectOverCDP()`:

Add to `src/main.ts`:
```typescript
if (process.env.DMER_CDP_PORT) {
  app.commandLine.appendSwitch('remote-debugging-port', process.env.DMER_CDP_PORT);
}
```

Launch: `DMER_CDP_PORT=9222 /Applications/DMer.app/Contents/MacOS/DMer &`

Connect: `chromium.connectOverCDP('http://localhost:9222')`

## Phase 1 — Test Scenarios

### 1.1 — Desktop App (Electron)

Generic scenarios for any Electron desktop app:

| # | Scenario | Tool | Verification |
|---|----------|------|-------------|
| 1 | App launches, process is alive | Playwright CDP / `pgrep` | No crash logs in stderr |
| 2 | Main window opens | Playwright CDP | Window exists, title matches |
| 3 | Key UI elements render | Playwright CDP | Expected elements present in DOM |
| 4 | User interaction (click, type, submit) | Playwright CDP | Expected state change or navigation |
| 5 | Tray icon / menu (macOS) | osascript | Menu items clickable, tray responds |
| 6 | Close app cleanly | osascript / `pkill` | No crash logs, process exits 0 |

**DMer-specific example:**
| # | Scenario | Verification |
|---|----------|-------------|
| 2 | Config window renders profiles | `.profile-row` elements present, `.avatar-badge` corner badges visible |
| 3 | Add Profile opens form | Click `button:has-text("+ Add Profile")` → form with `input[placeholder="username"]` visible |
| 4 | Create profile with toggles | Fill username, toggle `[role="switch"]` behaviors, click `button:has-text("Create")` → new `.profile-row` appears |
| 5 | Delete profile with confirm | Click `button:has-text("🗑")` → dismiss dialog → `.profile-row` count decreases |
| 6 | Tray shows status | osascript clicks tray → checks daemon status label |

Adapt the generic scenarios to your app by replacing selectors, expected elements, and verification steps.

### 1.2 — Web App

| # | Scenario | Tool | Verification |
|---|----------|------|-------------|
| 1 | Page loads (200) | Playwright browser | No console errors |
| 2 | Critical path works (e.g., search → results) | Playwright browser | Expected elements visible |
| 3 | Forms submit | Playwright browser | Success toast or redirect |
| 4 | Mobile viewport | Playwright browser (375×812) | No layout breakage |

## Phase 2 — Execution

### Desktop App Test Script (template)

```typescript
// test/app-e2e.ts — adapt selectors and expected values to your app
import { chromium } from 'playwright';

async function testApp() {
  // Option A: Launch from source
  // const { _electron: electron } = require('playwright');
  // const electronApp = await electron.launch({ args: ['src/main.js'] });
  // const window = await electronApp.firstWindow();

  // Option B: Connect to running app via CDP
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const contexts = browser.contexts();
  const page = contexts[0].pages()[0];

  // Verify the app loaded
  const title = await page.title();
  console.log(`App title: ${title}`);

  // Check key elements (adapt selectors)
  const mainElements = await page.$$('.your-selector');
  console.log(`Elements found: ${mainElements.length}`);

  // Interact (adapt to your app)
  await page.click('button:has-text("Action")');

  // Screenshot
  await page.screenshot({ path: 'test-results/app.png' });

  console.log('All checks passed');
}

testApp().catch(console.error);
```

### DMer-specific example

```typescript
// test/dmer-e2e.ts
import { chromium } from 'playwright';

async function testDMer() {
  // Connect to Electron via CDP
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const contexts = browser.contexts();
  
  // Find the config window
  const configPage = contexts[0].pages().find(p => p.url().includes('config.html'));
  
  // Verify profiles render
  const profiles = await configPage.$$('.profile-row');
  console.log(`Profiles: ${profiles.length}`);
  
  // Check corner badges
  const badges = await configPage.$$('.avatar-badge');
  console.log(`Badges: ${badges.length}`);
  
  // Click "+ Add Profile"
  await configPage.click('button:has-text("+ Add Profile")');
  
  // Fill profile creation form
  const usernameInput = configPage.locator('input[placeholder="username"]');
  await usernameInput.fill('testuser');
  
  // Toggle behaviors (click first two switches)
  const switches = configPage.locator('[role="switch"]');
  const switchCount = await switches.count();
  console.log(`Behavior toggles: ${switchCount}`);
  if (switchCount >= 2) {
    await switches.nth(0).click();
    await switches.nth(1).click();
  }
  
  // Create the profile
  await configPage.click('button:has-text("Create")');
  
  // Verify new profile appeared
  const newCount = await configPage.locator('.profile-row').count();
  console.log(`Profiles after create: ${newCount}`);
  
  // Delete a profile (handle native confirm dialog)
  configPage.on('dialog', async dialog => {
    console.log(`Dialog: ${dialog.message()}`);
    await dialog.accept();
  });
  await configPage.click('button:has-text("🗑")');
  
  // Screenshot
  await configPage.screenshot({ path: 'test-results/dmer-config.png' });
  
  console.log('All checks passed');
}

testDMer().catch(console.error);
```

### Run

```bash
# Launch DMer with CDP in background
DMER_CDP_PORT=9222 /Applications/DMer.app/Contents/MacOS/DMer &

# Wait for app to start
sleep 5

# Run tests
npx tsx test/dmer-e2e.ts

# Check logs
cat ~/Library/Application\ Support/ig-daemon/logs/stderr.log | tail -20
```

## Phase 3 — Verification

### Database Verification

```bash
# Check analytics events were logged
curl -s "https://dqtxiulqbuxoprppfmir.supabase.co/rest/v1/feature_interest_events?limit=5" \
  -H "apikey: $NEXT_PUBLIC_SUPABASE_ANON_KEY" | python3 -m json.tool
```

### Log Verification

```bash
# No Supabase errors in daemon logs
grep -i "supabase\|error\|fatal" ~/Library/Application\ Support/ig-daemon/logs/stderr.log | grep -v "stability\|recycle"
```

## Phase 4 — Report

```
## App Test Report — DMer v0.2.3

| # | Scenario | Result | Evidence |
|---|----------|--------|----------|
| 1 | App launches | ✅ | No crash logs |
| 2 | Config window | ✅ | test-results/dmer-config.png |
| 3 | Corner badges | ✅ | 3 badges found |
| 4 | Add Profile form | ✅ | Username input + toggles visible |
| 5 | Create profile | ✅ | New `.profile-row` appeared |
| 6 | Delete profile | ✅ | Confirm dialog handled, row removed |
| 7 | Clean shutdown | ✅ | Process exited 0 |
```

## Cleanup

```bash
# Kill DMer after tests
pkill -f "DMer" 2>/dev/null
```
