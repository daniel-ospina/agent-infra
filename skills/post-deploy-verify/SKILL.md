---
name: post-deploy-verify
description: "Post-deploy clickthrough verification. Detects deploy surface (web/desktop/infra) from PR diff and dispatches the appropriate agent-executed clickthrough protocol. Invoked by commit-workflow Step 3.8 after merge. WARN-ONLY gate — deploy already done."
domain: engineering
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find task
version: 1.0.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Post-Deploy Verification

**Announce at start:** "I'm using the post-deploy-verify skill for post-merge clickthrough verification."

## Purpose

After a PR merges and deploys, verify that the changes actually work for a real user — not just that they deployed correctly. All verification is **agent-executed** (not deterministic scripts): the agent reads the Tortoise graph for relevant journeys, then walks the app with common sense — finding buttons by text, filling forms by label, verifying outcomes visually.

## Gate

**WARN-ONLY.** The deploy is already done. This verification detects problems and auto-files issues but never blocks the pipeline.

## Architecture

Thin router → dispatch to focused sub-skills via `task` sub-agents. Follows the `test-routing` / `code-review` pattern. Each sub-skill is agent-executed (common-sense navigation), not deterministic scripts.

```
post-deploy-verify/SKILL.md (this file — router)
  ├─ Step 1: detect-deploy-surface.sh   ← classify PR diff
  ├─ Step 2: dispatch
  │   ├─ [sequential] desktop-clickthrough  ← human gate first (prompts user)
  │   └─ [parallel]   web-clickthrough      ← agent + Playwright MCP
  │                    infra-verify          ← script validation
  └─ Step 3: collect → report → file issues
```

**Context management:** Each sub-skill runs in an isolated `task` sub-agent with only its own SKILL.md loaded — the router never loads all protocols into memory.

## Workflow

### Step 1 — Detect Deploy Surface

```bash
gh pr diff $PR_NUMBER | bash scripts/detect-deploy-surface.sh
```

Parse JSON: `HAS_WEB`, `HAS_DESKTOP`, `HAS_INFRA`.

If none detected: log "No deploy surface detected — skipping" and exit clean.

### Step 2 — Dispatch Verification

**Desktop FIRST (sequential — has human gate), then web + infra (parallel).**

```
IF HAS_DESKTOP:
  task(
    prompt: "Run desktop clickthrough verification. PR #$PR_NUMBER. App path: <APP_PATH>.
             Read and follow skills/post-deploy-verify/desktop-clickthrough/SKILL.md.
             Return JSON as specified in the sub-skill contract.",
    cwd: <REPO_ROOT>
  )
  Wait for result (pass/fail/skip). If user skips, record skip and continue.

IF HAS_WEB AND HAS_INFRA:
  Dispatch web-clickthrough AND infra-verify IN PARALLEL:
    task(
      prompt: "Run the web clickthrough verification. PR #$PR_NUMBER. Deploy URL: <url>.
               Read and follow skills/post-deploy-verify/web-clickthrough/SKILL.md.
               Query Tortoise for relevant user journeys, then walk the app with common sense via Playwright.
               Return JSON as specified in the sub-skill contract.",
      cwd: <REPO_ROOT>
    )
    task(
      prompt: "Run the infra verification. PR #$PR_NUMBER. Repo root: <REPO_ROOT>.
               Read and follow skills/post-deploy-verify/infra-verify/SKILL.md.
               Return JSON as specified in the sub-skill contract.",
      cwd: <REPO_ROOT>
    )

IF HAS_WEB AND NOT HAS_INFRA:
  Dispatch web-clickthrough alone (same task() as above).

IF HAS_INFRA AND NOT HAS_WEB:
  Dispatch infra-verify alone (same task() as above).
```

**Playwright MCP:** If Playwright MCP is not available in the parent agent context, skip web surface with message "Playwright MCP not available — skipping web clickthrough." The `task` call MUST pass `mcp_servers` explicitly (e.g. `mcp_servers: "playwright-browser"`) — since #286 sub-agents default to `PI_MCP_SERVERS=none` (zero eager connects), they no longer inherit the parent's MCP servers. Load Playwright mid-run via `mcp_load` if you prefer lazy loading.

### Step 3 — Collect Results & Report

Each sub-skill returns JSON:

```json
{
  "surface": "web|desktop|infra",
  "status": "pass|fail|skip|error",
  "checks": [
    {
      "name": "Journey: Primera Visita — Step 1",
      "status": "pass|fail",
      "error": "only if fail",
      "screenshot": "path (optional)",
      "duration_ms": 0
    }
  ],
  "evidence": [
    {"type": "screenshot|log", "path": "...", "description": "..."}
  ],
  "issues_filed": [123]
}
```

**Report format:**

```
## Post-Deploy Verification

| Surface | Status | Checks | Issues |
|---------|--------|--------|--------|
| desktop | ⏭️ skip | —      | —      |
| web     | ✅ pass | 4/4    | —      |
| infra   | ✅ pass | 3/3    | —      |
```

**All pass:** "✅ Post-deploy verification: all surfaces passed."
**Some fail:** "⚠️ Post-deploy verification: N/M surfaces passed. Failures: <list>"
**All fail/skip:** "⏭️ Post-deploy verification: no verification run"

### Step 4 — File Issues for Failures

Dedup by checking for existing open issues with title prefix `clickthrough-failure:`.

```bash
gh issue create \
  --title "clickthrough-failure: <check name> — $(date -u +%Y-%m-%d)" \
  --body "...PR #$PR_NUMBER, error details, screenshot path..." \
  --label "bug"
```

## Failure Modes

| Failure | Handling |
|---------|----------|
| `detect-deploy-surface.sh` missing | Warn, skip all verification |
| No surfaces detected | Log, skip, exit clean |
| Sub-agent crash/timeout | Log as "error" surface, proceed |
| Playwright MCP not available (web) | Skip web surface with "Playwright not available" |
| cliclick not installed (desktop) | Skip desktop with install instructions |
| All sub-skills skip | Report "no verification run", proceed |

## Integration

**Called by:** `commit-workflow` Step 3.8 (04-merge-deploy.md)
**Dispatches to:** `web-clickthrough`, `desktop-clickthrough`, `infra-verify`
**References:** Tortoise graph (journey definitions); desktop sub-skill uses cliclick + CDP (human-emulation pattern, not deterministic scripts)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
