# Epic Plan — Post-Deploy Clickthrough Verification

**Epic:** Post-commit clickthrough verification protocol
**Repo:** agent-infra (canonical), symlinked to eldato, eldato-dmer
**Complexity:** UX=medium, Architecture=high, Ontology=low
**Plan date:** 2026-07-31

---

## 1. User Journeys

The "user" is the **agent** running commit-workflow. Three primary journeys:

### Journey 1: Web App PR Merged → Clickthrough Passes

| Step | Action | State |
|------|--------|-------|
| 1 | Agent completes commit-workflow Steps 3.6-3.75 (deploy, verify migrations, journey smoke) | Post-merge |
| 2 | commit-workflow Step 3.8: calls `post-deploy-verify` skill | Entry |
| 3 | Router detects surface: `web` (PR diff contains src/, pages/, components/) | Detection |
| 4 | Dispatches `web-clickthrough` sub-skill | Routing |
| 5 | Sub-skill runs `npx playwright test --project=critical-paths --grep @clickthrough` against deployed app | Execution |
| 6 | All specs pass: pages load, buttons click, forms submit, expected outcomes occur | Pass |
| 7 | Screenshots captured at key journey states | Evidence |
| 8 | Agent reports: "✅ Web clickthrough: 3/3 journeys passed" | Exit |

**Edge cases:**
- No @clickthrough specs exist → warn, skip (graceful degradation)
- Playwright not installed → error, ask user to install
- Deployed app not reachable → BLOCK, auto-file issue

### Journey 2: Web App → Clickthrough Fails

| Step | Action | State |
|------|--------|-------|
| 1-4 | Same as Journey 1 | |
| 5 | Playwright runs specs, one fails (element not found / unexpected redirect / visible API error) | Failure |
| 6 | Failure screenshots + error traces captured | Evidence |
| 7 | GitHub issue auto-filed with: journey name, failure step, screenshot path, PR link, timestamp | Auto-file |
| 8 | Issue labeled: `bug`, `clickthrough-failure` | Tracking |
| 9 | Agent reports: "⚠️ Web clickthrough: 2/3 passed, 1 FAILED → issue #N" | Exit |

**Edge cases:**
- GitHub API unavailable → log locally, report failure, proceed
- Multiple failures → group by journey, one issue per failed journey

### Journey 3: Desktop App PR Merged → Clickthrough Protocol

| Step | Action | State |
|------|--------|-------|
| 1 | Agent completes commit-workflow (DMeer repo) | Post-merge |
| 2 | commit-workflow Step 3.8: calls `post-deploy-verify` | Entry |
| 3 | Router detects surface: `desktop` (PR diff contains daemon-src/, src/main.ts, electron/) | Detection |
| 4 | Dispatches `desktop-clickthrough` sub-skill | Routing |
| 5 | Sub-skill prompts agent: "Desktop deploy detected. Run clickthrough? [y/n]" | Human gate |
| 6 | Agent says yes → follows protocol: pkill old → download DMG → install → launch via CDP | Setup |
| 7 | Verifies: welcome screen, config UI, add profiles | Check 1 |
| 8 | Asks user for steps agent can't do: magic link sign-in, OAuth login | Human assist |
| 9 | Verifies: daemon launches, platform tabs, agent actions (follow, like, DM) | Check 2 |
| 10 | Reports with screenshots per step | Exit |

**Edge cases:**
- User says "n" → record skip, proceed
- DMG download fails → BLOCK, auto-file issue
- App crashes during test → capture crash log, auto-file issue

### Journey 4: Infra PR Merged → Validation Passes

| Step | Action | State |
|------|--------|-------|
| 1 | Agent completes commit-workflow (agent-infra repo) | Post-merge |
| 2 | commit-workflow Step 3.8: calls `post-deploy-verify` | Entry |
| 3 | Router detects surface: `infra` (PR diff contains skills/, scripts/, templates/, .github/) | Detection |
| 4 | Dispatches `infra-verify` sub-skill | Routing |
| 5 | Sub-skill runs: script validation (`node --check`), skill lint, deploy verification | Execution |
| 6 | All checks pass | Pass |
| 7 | Agent reports: "✅ Infra verification: 5/5 checks passed" | Exit |

### Journey 5: Mixed Surface PR

| Step | Action | State |
|------|--------|-------|
| 1-2 | Same entry | |
| 3 | Router detects surfaces: `web` + `infra` | Detection |
| 4 | Dispatches BOTH `web-clickthrough` AND `infra-verify` in parallel | Routing |
| 5 | Each runs independently, collects own results | Execution |
| 6 | Agent reports combined results | Exit |

---

## 2. Workflows

### Workflow: Surface Detection

```
INPUT: PR diff (from commit-workflow context)
  │
  ├─ grep for src/, pages/, components/, .tsx, .ts → has_web
  ├─ grep for daemon-src/, src/main.ts, electron/, package.json (electron) → has_desktop
  └─ grep for skills/, scripts/, templates/, .github/workflows/ → has_infra
  │
OUTPUT: surface_mask = {web: bool, desktop: bool, infra: bool}
```

Script: `scripts/detect-deploy-surface.sh` — called by post-deploy-verify Step 1.

### Workflow: post-deploy-verify Router

```
1. Read surface detection output
2. Dispatch ALL matching sub-skills in parallel via task sub-agents
   - web → web-clickthrough/SKILL.md
   - desktop → desktop-clickthrough/SKILL.md
   - infra → infra-verify/SKILL.md
3. Collect results from all dispatched sub-skills (fan-in)
4. Report combined status:
   - ALL pass → "✅ Post-deploy verification: all surfaces passed"
   - SOME fail → "⚠️ Post-deploy verification: N/M surfaces passed. Failures: <list>"
   - ALL fail → "❌ Post-deploy verification: 0/M surfaces passed"
5. Auto-file issues for failures (dedup by check name)
6. Return status to commit-workflow (warn-only — deploy already done)
```

### Workflow: web-clickthrough Sub-skill

```
1. Detect environment: staging URL or production URL
2. Check for @clickthrough-tagged specs:
     npx playwright test --project=critical-paths --grep @clickthrough --list
3. IF no specs found:
     warn "No @clickthrough specs — skipping web clickthrough"
     exit (graceful degradation)
4. Run specs:
     npx playwright test --project=critical-paths --grep @clickthrough
5. Collect results:
   - Passed specs → screenshots at key states
   - Failed specs → error messages, traces, screenshots
6. Report per-spec: PASS/FAIL with evidence paths
7. Auto-file issue per failed spec (dedup by spec name)
```

### Workflow: desktop-clickthrough Sub-skill

```
1. Prompt agent: "Desktop deploy detected. Run post-deploy clickthrough?"
   Options: [y] run, [n] skip, [l] list steps first
2. IF skip: record skip, exit
3. Setup:
   a. pkill -9 old Electron process
   b. Clean app data: rm -rf ~/Library/Application Support/<app>/
   c. Download latest DMG (from R2 or build artifact)
   d. Mount DMG, copy .app to /Applications
   e. Launch with --remote-debugging-port=9243
   f. Wait for CDP readiness: curl http://127.0.0.1:9243/json/version
4. Step 1 — Welcome/Login:
   a. Screenshot: welcome screen
   b. If magic link auth: "👉 Please sign in via magic link. Press Enter when done."
   c. Wait for user, then verify: config window visible
5. Step 2 — Core Functionality:
   a. Clickthrough key flows (adapted per app, from SKILL.md checklist)
   b. Use cliclick for real clicks, CDP for screenshots
   c. Verify each step with screenshot + DOM assertion
6. Step 3 — Agent Actions (desktop-only):
   a. Verify daemon launches with correct platform tabs
   b. Ask user for OAuth if needed: "👉 Please log in to <platform>. Press Enter when done."
   c. Trigger agent action (follow, DM, etc.)
   d. Verify action completed (screenshot)
7. Report: checklist with screenshot per step, PASS/FAIL per step
8. Cleanup: pkill Electron, unmount DMG
```

### Workflow: infra-verify Sub-skill

```
1. Detect repo type from PR context
2. Run applicable checks:
   a. Script validation: node --check scripts/*.mjs scripts/*.cjs
   b. Skill lint: node scripts/check-skill-lint.mjs (if exists)
   c. Template validity: check template files parse correctly
   d. CI config validity: validate .github/workflows/*.yml
   e. Drift check: any repo-specific drift checks
3. For each check: PASS or FAIL with output
4. Report: "✅ Infra verification: N/M checks passed"
5. Auto-file issue for failures (dedup by check name)
```

---

## 3. Prototype

Since this is a non-GUI feature (agent skill + scripts), the prototype is the **skill interface**:

### post-deploy-verify/SKILL.md (interface)

```yaml
---
name: post-deploy-verify
description: "Post-deploy clickthrough verification. Detects deploy surface (web/desktop/infra) and dispatches appropriate clickthrough protocol. Invoked by commit-workflow Step 3.8 after merge."
domain: engineering
type: Bounded
allowed-tools: read write edit bash grep find task
steps:
  - name: detect_surface
    type: script
    gate: auto
    produces: [surface_mask]
  - name: dispatch_verification
    type: parallel
    gate: auto
    requires: [detect_surface]
    produces: [verification_results]
  - name: report_and_file_issues
    type: skill
    gate: auto
    requires: [dispatch_verification]
    produces: [final_report]
---
```

### Sub-skill interfaces

**web-clickthrough/SKILL.md:**
```yaml
---
name: web-clickthrough
description: "Playwright @clickthrough specs — walks full user journeys against deployed app."
type: Bounded
allowed-tools: read bash grep find
---
```

**desktop-clickthrough/SKILL.md:**  
```yaml
---
name: desktop-clickthrough  
description: "cliclick + CDP clickthrough protocol for Electron desktop apps."
type: Bounded
allowed-tools: read write edit bash
---
```

**infra-verify/SKILL.md:**
```yaml
---
name: infra-verify
description: "Script-based verification for infrastructure/skills/config changes."
type: Bounded
allowed-tools: read bash grep find
---
```

### Script interface

**detect-deploy-surface.sh:**
```bash
#!/bin/bash
# Input: PR diff via stdin or file
# Output: JSON surface mask
# Usage: gh pr diff $PR | bash detect-deploy-surface.sh
# Output: {"web": true, "desktop": false, "infra": false}
```

---

## 4. Data Model

No new database entities. The data flows through files and GitHub issues:

### Surface Detection Result
```typescript
type SurfaceMask = {
  web: boolean;      // src/, pages/, components/, .tsx
  desktop: boolean;  // daemon-src/, electron/, main.ts
  infra: boolean;    // skills/, scripts/, templates/, .github/
};
```

### Verification Result (per surface)
```typescript
type VerificationResult = {
  surface: 'web' | 'desktop' | 'infra';
  status: 'pass' | 'fail' | 'skip' | 'error';
  checks: CheckResult[];
  evidence: EvidenceItem[];
  issue_number?: number;  // if auto-filed
};

type CheckResult = {
  name: string;           // spec name, step name, check name
  status: 'pass' | 'fail';
  error?: string;         // failure message
  screenshot?: string;    // path to screenshot
  duration_ms: number;
};

type EvidenceItem = {
  type: 'screenshot' | 'log' | 'trace' | 'dom_snapshot';
  path: string;
  description: string;
};
```

### Auto-Filed Issue
```
Title: "clickthrough-failure: <journey/check name> — <timestamp>"
Labels: bug, clickthrough-failure
Body: {
  surface: web|desktop|infra,
  pr_number: N,
  journey: name,
  failure_step: description,
  error: message,
  screenshot: path,
  timestamp: ISO8601
}
```

---

## 5. Architecture

### Component Diagram

```
commit-workflow/04-merge-deploy.md (Step 3.8)
  │
  ▼
post-deploy-verify/SKILL.md          ← thin router
  │
  ├─ Step 1: scripts/detect-deploy-surface.sh
  │
  ├─ Step 2: dispatch (parallel task sub-agents)
  │   ├─ web-clickthrough/SKILL.md
  │   │   └─ playground.config.ts (existing)
  │   │       └─ e2e/critical-paths/*.clickthrough.spec.ts
  │   │
  │   ├─ desktop-clickthrough/SKILL.md
  │   │   └─ local-app-testing/SKILL.md (existing, wraps)
  │   │       ├─ cliclick (macOS)
  │   │       └─ CDP (remote-debugging-port)
  │   │
  │   └─ infra-verify/SKILL.md
  │       └─ scripts/check-*.sh (existing)
  │
  └─ Step 3: collect results → report → auto-file issues
```

### Cross-Repo Layout

```
agent-infra/                           ← canonical (write once)
├── skills/
│   ├── post-deploy-verify/            ← NEW
│   │   ├── SKILL.md                   ← router
│   │   ├── web-clickthrough/SKILL.md  ← sub-skill
│   │   ├── desktop-clickthrough/SKILL.md ← sub-skill
│   │   └── infra-verify/SKILL.md      ← sub-skill
│   ├── commit-workflow/workflow/
│   │   └── 04-merge-deploy.md         ← UPDATED (+Step 3.8)
│   └── local-app-testing/SKILL.md     ← existing (used by desktop-clickthrough)
├── scripts/
│   └── detect-deploy-surface.sh       ← NEW
└── templates/e2e/
    └── clickthrough.spec.ts           ← NEW (template)

eldato/                                ← consumes (symlinks)
├── operations/skills/ → agent-infra/skills/  (91 symlinks exist)
└── e2e/critical-paths/
    └── *.clickthrough.spec.ts         ← instantiated from template

eldato-dmer/                           ← consumes
└── (uses agent-infra skills directly — symlink infra TBD)
```

### Key Insight: Agent Context Management

**This skill follows the `test-routing`/`code-review` pattern of thin router + focused sub-skills.**

Each sub-skill is a **separate focused file** invoked via `task` sub-agent — not a monolith. This mirrors:
- `test-routing` → `test-integration`, `test-e2e`, `ux-verification` (separate sub-skills)
- `code-review` → Agent #1, #2a, #2b, #3, #4, #5-10 (separate sub-agents)
- The split between Agent #2a (shallow/diff-only) and #2b (deep/caller-callee) in code-review exists specifically to manage agent context

For `post-deploy-verify`, the router SKILL.md is thin (~50 lines: detect + dispatch + report). Each sub-skill (~100-200 lines) fits in one agent context read. The **task sub-agent pattern** gives each sub-skill a fresh isolated context — the router doesn't load all protocols into memory.

### Failure Modes & Mitigations

| Failure | Detection | Mitigation |
|---------|-----------|------------|
| Playwright not installed | web-clickthrough Step 2 fails | Error message with install command, skip |
| @clickthrough specs missing | web-clickthrough lists 0 specs | Warn, skip (graceful degradation) |
| cliclick not installed (desktop) | desktop-clickthrough setup fails | Error message with `brew install cliclick`, skip |
| CDP port occupied | curl check fails | Try alternate port, kill stale process |
| GitHub API down | issue creation fails | Log locally, report failure, proceed |
| Deployed app unreachable | page.goto() times out | BLOCK, auto-file issue |
| Agent handler crashes | sub-agent returns error | Catch, log, report as ERROR surface |
| User declines desktop clickthrough | prompt response | Record skip, proceed normally |

### Non-Functional Constraints

- **Graceful degradation MANDATORY:** Post-deploy-verify is a WARN-ONLY gate. Failure must never block the pipeline. Deploy is already done.
- **Context budget per sub-skill:** Each sub-skill SKILL.md must fit in one agent context read (~50KB). No sub-skill should import another sub-skill's full content.
- **Evidence must be observable:** Screenshots, logs, DOM snapshots — not just "I checked and it works."
- **Issue dedup:** Auto-filed issues check for existing open issues with same title prefix before creating new ones.
- **macOS-only for desktop:** Desktop clickthrough is agent-executed (local macOS), not CI. Skill must clearly state this constraint.

---

## 6. Interfaces

### Router → Sub-skill Contract

Each sub-skill is invoked as a `task` sub-agent. The router passes:

```
Prompt:
  Run the {surface} clickthrough verification protocol.
  
  PR: #{N}
  Branch: {name}
  Deploy URL: {url}           (web only)
  App path: {/Applications/...} (desktop only)
  Repo root: {path}            (infra only)
  
  Follow the protocol in {skill_path}/SKILL.md.
  
  Return JSON:
  {
    "surface": "{web|desktop|infra}",
    "status": "{pass|fail|skip|error}",
    "checks": [
      {"name": "...", "status": "pass|fail", ...}
    ],
    "evidence": [
      {"type": "screenshot", "path": "...", "description": "..."}
    ],
    "issues_filed": [123, 124]
  }
```

### Sub-skill → Router Response

Parsed by the router to produce the final report. Each sub-skill returns the JSON structure above via stdout or a result file.

### Router → GitHub Issues

```
POST /repos/{owner}/{repo}/issues
{
  "title": "clickthrough-failure: {journey} — {date}",
  "body": "<structured failure report>",
  "labels": ["bug", "clickthrough-failure"]
}
```

---

## 7. Detailed E2E Test Cases

### E2E-1: Web Clickthrough Passes

**Given:**
- A PR touching `src/pages/deals.tsx` and `src/components/DealCard.tsx` has been merged to main
- The web app is deployed and reachable at production URL
- `e2e/critical-paths/deals.clickthrough.spec.ts` exists with 2 @clickthrough specs:
  - "Browse deals → view deal → reserve"
  - "Search → filter by category → view deal"

**When:**
- commit-workflow Step 3.8 calls `post-deploy-verify`
- Router detects surface: `web=true, desktop=false, infra=false`
- Router dispatches `web-clickthrough` sub-skill

**Then:**
1. Sub-skill detects `@clickthrough` specs (2 found)
2. Playwright runs both specs against production URL
3. Spec 1 passes: homepage loads, deal cards visible, click deal → detail page loads, click Reserve → QR modal appears
4. Spec 2 passes: search input visible, type "pizza" → results filter, click category "Italian" → correct deals shown
5. Screenshots captured: homepage.png, deal-detail.png, qr-modal.png, search-results.png
6. Router receives: `{"surface":"web","status":"pass","checks":[...],"evidence":[...]}`
7. Agent reports: `✅ Web clickthrough: 2/2 journeys passed`
8. No issues filed

**Assertions:**
- `web-clickthrough` sub-skill returns status "pass"
- 2 checks return status "pass"
- 4+ evidence items (screenshots) present
- No GitHub issues created

---

### E2E-2: Web Clickthrough Fails → Auto-Files Issue

**Given:**
- Same setup as E2E-1
- But the merged PR introduced a bug: clicking "Reserve" on deal detail navigates to 404

**When:**
- Same dispatch as E2E-1

**Then:**
1. Spec 1 runs, reaches "click Reserve" step
2. Playwright navigates to `/ofertas/123/reservar` → returns 404
3. Playwright assertion `expect(page).not.toHaveURL(/404/)` fails
4. Failure screenshot captured: reserve-404.png
5. Playwright trace captured
6. Sub-skill returns: `{"status":"fail","checks":[{"name":"Browse→reserve","status":"fail","error":"Expected URL not to match /404/ but got /404"}],...}`
7. Router auto-files issue:
   - Title: `clickthrough-failure: Browse→reserve — 2026-07-31`
   - Labels: `bug, clickthrough-failure`
   - Body includes: journey name, failure step, error message, screenshot path, PR link
8. Agent reports: `⚠️ Web clickthrough: 1/2 passed, 1 FAILED → issue #N`

**Assertions:**
- Sub-skill returns status "fail"
- At least 1 check returns status "fail"
- GitHub issue created with correct labels
- Report includes both pass AND fail results

---

### E2E-3: Desktop Clickthrough Protocol

**Given:**
- A PR touching `daemon-src/linkedin/agent.ts` has been merged in DMeer
- New DMG built and available at R2 download URL
- macOS machine with cliclick installed

**When:**
- commit-workflow Step 3.8 calls `post-deploy-verify`
- Router detects surface: `web=false, desktop=true, infra=false`
- Router dispatches `desktop-clickthrough` sub-skill
- Agent responds "y" to clickthrough prompt

**Then:**
1. Sub-skill kills existing Electron: `pkill -9 Electron`
2. Cleans app data: `rm -rf ~/Library/Application Support/dmeer/`
3. Downloads latest DMG from R2
4. Mounts DMG, copies to /Applications
5. Launches with CDP port: `npx electron . --remote-debugging-port=9243`
6. Waits for CDP readiness (curl check, up to 15s)
7. Screenshots welcome screen
8. Detects auth requirement → prompts: "👉 Please sign in via magic link. Press Enter when done."
9. User signs in, presses Enter
10. Verifies config window rendered (screenshot + DOM assertion: `.profile-row` exists)
11. Clicks "Add Profile" via cliclick → verifies platform modal opens
12. Adds LinkedIn profile via cliclick typing + click
13. Prompts: "👉 Please log in to LinkedIn in the daemon window. Press Enter when done."
14. Verifies daemon launched LinkedIn tab (screenshot)
15. Triggers connect-request action → verifies action executed (DOM check)
16. Reports: checklist with 8 steps, 8/8 passed, 8 screenshots
17. Cleans up: pkill Electron, unmount DMG

**Assertions:**
- Sub-skill returns status "pass"
- 8+ checks return status "pass"
- 8+ evidence items (screenshots) present
- User prompts correctly issued at auth/OAuth steps
- Cleanup completed without errors
- No issues filed

---

### E2E-4: Desktop Clickthrough Skipped

**Given:**
- Same setup as E2E-3

**When:**
- Router dispatches `desktop-clickthrough`
- Agent responds "n" to "Run post-deploy clickthrough? [y/n]"

**Then:**
1. Sub-skill records skip
2. Sub-skill returns: `{"surface":"desktop","status":"skip","checks":[],"evidence":[]}`
3. Router reports: `⏭️ Desktop clickthrough: skipped by user`
4. No issues filed
5. Pipeline proceeds normally

**Assertions:**
- Sub-skill returns status "skip"
- Report includes skip indicator
- Pipeline does not block

---

### E2E-5: Infra Verification Passes

**Given:**
- A PR touching `skills/post-deploy-verify/SKILL.md` has been merged in agent-infra
- No deploy needed (skill changes take effect on next agent session)

**When:**
- commit-workflow Step 3.8 calls `post-deploy-verify`
- Router detects surface: `web=false, desktop=false, infra=true`
- Router dispatches `infra-verify` sub-skill

**Then:**
1. Sub-skill runs script validation: `node --check scripts/detect-deploy-surface.sh` → passes
2. Sub-skill runs skill lint: `node scripts/check-skill-lint.mjs` → passes
3. Sub-skill validates skill YAML frontmatter → all present
4. Sub-skill checks symlink integrity (if applicable) → passes
5. Sub-skill returns: `{"surface":"infra","status":"pass","checks":["script-validate","skill-lint","frontmatter","symlinks"],...}`
6. Agent reports: `✅ Infra verification: 4/4 checks passed`

**Assertions:**
- Sub-skill returns status "pass"
- 4 checks return status "pass"
- No issues filed

---

### E2E-6: Mixed Surface — Web + Infra

**Given:**
- A PR touching both `src/pages/` (web) and `skills/` (infra) has been merged

**When:**
- Router detects: `web=true, desktop=false, infra=true`
- Router dispatches BOTH sub-skills in parallel

**Then:**
1. web-clickthrough and infra-verify run independently
2. Both collect results
3. Router receives both result objects
4. Agent reports combined:
   ```
   ✅ Web clickthrough: 2/2 passed
   ✅ Infra verification: 4/4 passed
   ```
5. No issues filed

**Edge case — one passes, one fails:**
- Router reports: `⚠️ Post-deploy verification: 1/2 surfaces passed`
- Failed surface auto-files issue
- Pipeline continues (warn-only)

---

## 8. Coherence Review + Risk Analysis

### Cross-Substep Consistency Check

| Check | Status | Notes |
|-------|--------|-------|
| User Journeys ↔ Workflows | ✅ Consistent | Journeys map 1:1 to workflow branches |
| Workflows ↔ Architecture | ✅ Consistent | Workflow branches correspond to sub-skill components |
| Architecture ↔ Interfaces | ✅ Consistent | Router → sub-skill contract matches architecture diagram |
| Data Model ↔ Interfaces | ✅ Consistent | VerificationResult type matches router output JSON |
| Detailed E2E ↔ High-Level E2E | ✅ Consistent | 6 detailed tests cover all 5 high-level scenarios + mixed surface |
| Prototype ↔ Architecture | ✅ Consistent | Skill frontmatter interfaces match component structure |
| Context management | ✅ Pattern-matched | Thin router + focused sub-skills via task sub-agents — follows test-routing/code-review pattern |

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| @clickthrough specs never written | HIGH | Web surface always skips | Template + example spec shipped with skill; commit-workflow PR template includes spec reminder |
| cliclick not installed | MEDIUM | Desktop surface always errors | Install check at sub-skill start with clear install command |
| Agent skips Step 3.8 (same as it skips verification-before-completion) | MEDIUM | Entire epic wasted | Wire into commit-workflow as mandatory step (like pre-flight); VGATE extension could enforce |
| Playwright @clickthrough specs break on UI changes | HIGH | High maintenance burden | Use resilient selectors (data-testid, role); keep specs focused on critical journeys only |
| Desktop clickthrough too slow/fragile for practical use | MEDIUM | Agent won't run it | Start with 3-step smoke (launch → sign-in → verify), expand later |
| Auto-filed issues create noise | LOW | Team ignores clickthrough-failure label | Label-based filtering; issues auto-close when @clickthrough spec passes on next run |
| Multiple surfaces cause context overflow | LOW | Router sub-agent runs out of context | Parallel dispatch; each sub-skill is isolated in its own task sub-agent |
| Detection script misses a surface | LOW | Wrong protocol runs or skips | Comprehensive grep patterns; default to infra if uncertain (safe fallback) |

### Improvement Opportunities (Deferred)

1. **Auto-healing @clickthrough specs:** If a spec fails, the agent could attempt to fix it (like code-review fixer loop). Defer to future epic.
2. **Clickthrough result dashboard:** Track pass/fail rates over time. Defer — use GitHub issue search for now.
3. **Pre-merge clickthrough:** Run @clickthrough against staging BEFORE merge. Defer — existing E2E covers this partially.
4. **Screenshot diff on regression:** Compare screenshots to baseline. Defer — Playwright visual regression exists in config but unused.

### Decision: Plan Ready for Decomposition

All 8 substeps are internally consistent. Risks are identified with mitigations. The plan follows existing patterns (`test-routing` for routing, `code-review` for sub-agent dispatch, `local-app-testing` for desktop protocol). Agent context is managed via the thin-router + focused-sub-skills pattern.

**Proceed to epic-decompose.**
