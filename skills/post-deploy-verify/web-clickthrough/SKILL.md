---
name: web-clickthrough
description: "Agent-executed clickthrough protocol for web apps. Reads Tortoise graph for relevant user journeys, then walks them using Playwright with common sense — clicking by text, filling by label, verifying visually. Not a deterministic script. Invoked by post-deploy-verify router for web surface PRs."
domain: engineering
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read bash grep find web_fetch
version: 1.0.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Web Clickthrough Verification

**Announce at start:** "I'm running web clickthrough verification — walking user journeys like a real user via Playwright."

## Philosophy

**Agent-executed protocol, not deterministic spec.** The agent reads the Tortoise graph to know WHAT journeys to walk, then navigates the app with common sense — finding buttons by their text, filling forms by their labels, verifying outcomes by what's visible on screen. No fixed CSS selectors, no brittle XPaths.

This is the same human-emulation pattern as desktop clickthrough (cliclick + CDP), adapted for web via Playwright: real browser interactions, screenshots at key states, visual verification via the `read` tool.

**Requires:** Playwright MCP server available in the sub-agent context (inherited from parent).

## When This Runs

Dispatched by `post-deploy-verify` router when surface detection returns `web=true`. Runs in parallel with `infra-verify` (after `desktop-clickthrough` if present).

## Contract

**Input:** PR number, deploy URL, changed files list
**Output:** JSON `VerificationResult`
**Gate:** WARN-ONLY

## Workflow

### Step 1 — Find Relevant Journeys

Query the Tortoise graph for user journeys related to the changed code. If Tortoise has no relevant data, use a default smoke journey.

**Default smoke journey (fallback):**
1. Navigate to deploy URL → page loads, key elements visible
2. Find and click the main CTA → next page/section loads
3. Complete one core flow (search, sign up, browse) → expected outcome
4. Verify outcome → success state visible

### Step 2 — Walk Each Journey

For each journey from Tortoise (or default smoke):

```
FOR each journey:
  1. Start at deploy URL with fresh browser context
  2. Read journey steps from Tortoise (start → actions → expected outcomes)
  3. For each step, use common sense:
     - "Click button that says 'Reservar'" → find by text, role, or aria-label
     - "Fill in the search field" → find by placeholder, label, or input type
     - "Verify deal detail appears" → look for expected text, headings, images
  4. Screenshot at each key state
  5. Use the `read` tool to visually verify screenshots
  6. If stuck (element not found after reasonable attempts) → screenshot, mark FAIL, continue
  7. Test edge cases where relevant: empty state, invalid input, error page
```

**Agent heuristics for finding elements:**

| What to find | Look for (in order) |
|-------------|-------------------|
| A button | `role="button"` + matching text, `button` tag, element with `onclick` |
| A text input | `placeholder` attribute, associated `label`, `input[type="text"]` |
| A link | `role="link"`, `a` tag with matching href/text |
| A heading | `h1`-`h6` tags with matching text |
| Search results | Container with repeated card/list items |
| Success message | Text containing "éxito", "success", "confirmado" |
| Error state | Text containing "error", 404, 500, empty message |

### Step 3 — Screenshot Evidence

For EVERY step (pass or fail):

```bash
# Take screenshot via Playwright MCP (use whatever screenshot/browser tool is available)
# e.g., browser_take_screenshot or page.screenshot depending on MCP server
await page.screenshot({ path: 'test-results/clickthrough/step<N>-<name>.png' })
```

Then use `read` tool to visually verify:
```bash
read('test-results/clickthrough/step<N>-<name>.png')
```

The `read` tool (with image support) provides visual verification — the agent describes what it sees and confirms it matches the expected outcome.

### Step 4 — Report

```
Journey: Primera Visita (from Tortoise J1)
  ✅ Step 1: Homepage loaded — deals visible, search bar present
     📸 test-results/clickthrough/j1-step1.png
  ✅ Step 2: Clicked "Ver oferta" on first deal
     📸 test-results/clickthrough/j1-step2.png
  ✅ Step 3: Deal detail loaded — title, description, CTA visible
     📸 test-results/clickthrough/j1-step3.png
  ✅ Step 4: Clicked "Reservar" — QR modal appeared
     📸 test-results/clickthrough/j1-step4.png
  Result: 4/4 passed
```

### Step 5 — Return Result

```json
{
  "surface": "web",
  "status": "pass",
  "checks": [
    {"name": "Journey: Primera Visita — Step 1: Homepage", "status": "pass", "screenshot": "test-results/clickthrough/j1-step1.png", "duration_ms": 2500},
    {"name": "Journey: Primera Visita — Step 4: Reservar", "status": "pass", "screenshot": "test-results/clickthrough/j1-step4.png", "duration_ms": 1800}
  ],
  "evidence": [
    {"type": "screenshot", "path": "test-results/clickthrough/j1-step1.png", "description": "Homepage with deal cards visible"},
    {"type": "screenshot", "path": "test-results/clickthrough/j1-step4.png", "description": "QR code modal after reservation"}
  ],
  "issues_filed": []
}
```

## Tortoise Integration

Tortoise encodes user journeys as graph points. When a PR changes files, query Tortoise for journeys touching those components. If no Tortoise data exists (early adoption), fall back to default smoke journey.

## Why Agent-Executed, Not Deterministic Specs

1. **Specs break on every UI change** — button text changes, layout shifts → test fails even though app works
2. **Specs test selectors, not outcomes** — "is `.reserve-button` clickable?" vs "can a user reserve a deal?"
3. **Agent adapts** — recovers from unexpected modals, cookie banners, A/B test variants
4. **No maintenance overhead** — same protocol works across UI changes

## Failure Handling

- **Each step is independent** — one failure doesn't stop the journey
- **Screenshots required for ALL failures** — visual evidence for auto-filed issues
- **Agent retries with variation** — try by text, then by role, then partial text, then fail
- **Never exit non-zero** — always return JSON result
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
