---
disable-model-invocation: true
name: desktop-clickthrough
description: "cliclick + CDP clickthrough protocol for Electron desktop apps. Uses real mouse clicks and common-sense navigation (human-emulation pattern). Adds pipeline contract, human gate, and structured JSON output. Invoked by post-deploy-verify router for desktop surface PRs."
domain: engineering
type: Bounded
subjects.team: dmer-app-team
allowed-tools: read write edit bash
version: 1.0.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Desktop Clickthrough Verification

**Announce at start:** "I'm running desktop clickthrough verification. This requires macOS with cliclick."

## Purpose

Agent-executed clickthrough protocol for desktop (Electron) apps. Uses real mouse clicks via `cliclick` and CDP screenshots — exactly what a human user generates. The agent navigates with common sense: finding buttons by position and text, filling forms, verifying outcomes via screenshots. Not a deterministic script — each interaction uses real system-level mouse events.

Pattern: get window position (osascript) → find element (CDP getBoundingClientRect) → calculate coordinates → click (cliclick) → screenshot (CDP captureScreenshot) → verify (read tool).

## When This Runs

Dispatched by `post-deploy-verify` router when surface detection returns `desktop=true`. Runs **sequentially BEFORE** web+infra sub-skills (has a human gate). **Agent-executed only** — cliclick is macOS-only.

## Contract

**Input:** PR number, app path or DMG URL
**Output:** JSON `VerificationResult`
**Gate:** WARN-ONLY
**Human required:** Yes — for OAuth/login steps

## Workflow

### Step 1 — Environment Check

```bash
[[ "$(uname)" != "Darwin" ]] && {
  echo '{"surface":"desktop","status":"error","checks":[{"name":"platform-check","status":"fail","error":"Desktop clickthrough requires macOS"}],"evidence":[],"issues_filed":[]}'
  exit 0
}
which cliclick 2>/dev/null || {
  echo '{"surface":"desktop","status":"error","checks":[{"name":"cliclick-check","status":"fail","error":"cliclick not installed. Run: brew install cliclick"}],"evidence":[],"issues_filed":[]}'
  exit 0
}
```

### Step 2 — Human Gate

```
📱 Desktop app deploy detected. Run post-deploy clickthrough?

This will:
  1. Kill running instances of the app
  2. Clean app data (~/Library/Application Support/<app>/)
  3. Download and install the latest DMG
  4. Launch and verify: welcome screen, config UI, daemon, agent actions
  5. Ask you to sign in when needed (magic link, OAuth)

[y] Run   [n] Skip   [l] List steps first
```

If user chooses [l]: print the checklist from Step 4, then re-prompt with [y] Run / [n] Skip.

If user says "n" or "skip": return `{"surface":"desktop","status":"skip",...}`

### Step 3 — Setup

```bash
pkill -9 Electron 2>/dev/null || true
rm -rf ~/Library/Application\ Support/<app>/
# Download + mount + install DMG (app-specific)
# Launch with CDP: <APP>_CDP_PORT=9243 /Applications/<App>.app/Contents/MacOS/<App> &
# Wait for CDP: curl http://127.0.0.1:9243/json/version (up to 15s)
```

### Step 4 — Clickthrough Protocol

For each interaction step:

1. Get window position: `osascript -e 'tell application "System Events" to get position of window 1 of process "Electron"'`
2. Find element via CDP `Runtime.evaluate` with `getBoundingClientRect()`
3. Calculate absolute coordinates: `WIN_X + ELEMENT_X + ELEMENT_W / 2`, `WIN_Y + ELEMENT_Y + ELEMENT_H / 2`
4. Click: `cliclick c:$X,$Y`
5. Screenshot via CDP `Page.captureScreenshot`
6. Verify via `read` tool

**Standard checklist (adapt per app):**

| Step | Action | Verification |
|------|--------|-------------|
| 1 | App launches | No crash, CDP reachable, window exists |
| 2 | Welcome/sign-in screen | Screenshot + `read` tool confirms expected content |
| 3 | 🔑 Human: sign in | Prompt user → wait for Enter → verify config UI |
| 4 | Config UI renders | Key elements present |
| 5 | Add profile/entity | Form opens, fields fillable, submit works |
| 6 | Core feature 1 | Click through → verify outcome |
| 7 | Core feature 2 | Click through → verify outcome |
| 8 | 🔑 Human: OAuth (if needed) | Prompt user → wait → verify connected |
| 9 | Agent/daemon behavior | Daemon launches, actions execute |

### Step 5 — Human Assistance

The agent MUST ask the user for:
- Magic link / email sign-in
- OAuth login (Instagram, Twitter/X, LinkedIn, Google) — CAPTCHAs, 2FA
- Anything requiring vision beyond screenshots

The agent should NEVER ask the user to click things the agent can click with cliclick.

### Step 6 — Cleanup + Return

```bash
pkill -9 Electron 2>/dev/null || true
hdiutil detach /Volumes/<AppName> -quiet 2>/dev/null || true
```

```json
{
  "surface": "desktop",
  "status": "pass",
  "checks": [
    {"name": "app-launch", "status": "pass", "screenshot": "test-results/desktop/step1.png", "duration_ms": 3000},
    {"name": "sign-in", "status": "pass", "screenshot": "test-results/desktop/step3.png", "duration_ms": 15000}
  ],
  "evidence": [
    {"type": "screenshot", "path": "test-results/desktop/step1.png", "description": "App launched, welcome screen visible"}
  ],
  "issues_filed": []
}
```

## DMeer-Specific Protocol

Follows DMeer #150 checklist: uninstall → download → install → sign in → add profiles (Twitter, Instagram, LinkedIn) → verify daemon per-platform tabs → verify agent actions → verify license enforcement.

## Failure Handling

- **Never exit non-zero** — always return JSON
- **Each step independent** — one failure doesn't stop the protocol
- **Screenshots required for failures** — visual evidence for issues
- **Cleanup MUST run even on failure**
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
