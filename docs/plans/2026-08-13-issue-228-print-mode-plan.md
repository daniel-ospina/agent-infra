---
title: "Issue #228 — shared isPrintMode() helper: replace 17 raw PI_MODE checks"
type: engineering
domain: capability
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-13
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-228, pi-extensions
---

<!-- research-path: none (in-repo audit; #227 precedent verified) -->

# fix(extensions): shared isPrintMode() helper (#228)

**Team:** organisation-design-team
**Status:** PLANNED + IMPLEMENTED (PR #258)

## Goal
Replace 17 raw `process.env.PI_MODE` checks across 13 production extensions with a shared argv-aware `isPrintMode()` helper. pi never sets PI_MODE — every raw check was dead code in bare `pi -p` runs (the #227 class).

## Design
1. `extensions/shared/print-mode.ts`: `isPrintMode(env, argv)` — env-first (builtin-tools spawns), argv `-p`/`--print` fallback with value-taking-flag walk (no false positives); `isPrintModeEnv(env)` env-only variant for sequence-enforcer's #201 semantic sites (gate/warn, park/pop — shell-spawned bare `pi -p` keeps gate).
2. Specifier per file shape: flat → `./shared/print-mode.js`; nested → `../shared/print-mode.js` (empirically verified; #5611 stale for jiti/static).
3. `print-mode.test.ts` (helper logic + argv false-positives) + `print-mode-wiring.test.ts` (repo-wide 0-raw-reads gate) + CI wiring (incl. auto-sync.test.ts for the flat import path).
4. builtin-tools.test.ts:210 re-asserts `!isPrintMode()`; task-heartbeat excluded (env-param, fail-closed).

## Verification
- 0 raw `process.env.PI_MODE` reads in production (was 17)
- helper + wiring + auto-sync + builtin-tools (132) + loop-enforcer/mcp-client/slack-bridge suites pass
- VGATE confirmed both previously-failing extensions load cleanly in pi's runtime

## Learnings
- The refactor script's `"print-mode" in s` import guard tripped on COMMENTS mentioning print-mode → 2 files shipped without imports (caught by VGATE's runtime load). Import guards must match the import statement, not a substring of the file.
- A commit after a VGATE PASS must re-stage the fixed files — committing from a stale index re-shipped the bug (P0 in review).
- argv `.includes("-p")` false-positives on value-taking flag args (`pi --model -p`): walk argv skipping flag values.
