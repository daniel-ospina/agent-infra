---
name: qa-mission
description: "QA-mission runner for the product-verifier agent. Routes mission types — e2e-verify (app-test / local-app-testing for Electron + web clickthrough), bug-hunt (find-bugs / codebase-audit), coverage/integration-audit (test-e2e / test-integration / test-design / test-routing) — and enforces the default mission loop: pull card → identify mission type + target product → run mission → file scoped GitHub issues (file-don't-fix, max 5 per scan) → complete card → handoff."
domain: engineering
subjects.team: organisation-design-team
type: Bounded
status: live
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
tags: [qa, mission, verification, testing, bug-hunt, e2e, coverage]
summary: "QA mission router + default mission loop for the product-verifier agent. File-don't-fix, max 5 issues per scan."
created: 2026-08-12
updated: 2026-08-12
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# QA Mission — Mission Router + Default Loop

The single entry point for the product-verifier agent's QA missions. It classifies the card, routes to the right execution skills, and enforces the file-don't-fix loop that turns findings into scoped GitHub issues.

**Announce at start:** "I'm using the qa-mission skill to run a [mission-type] mission against [product]."

## When to Use

- A card lands on the product-verifier board (from product-strategist, product-implementer handoff, or cron)
- A user asks to "verify", "smoke test", "bug hunt", or "audit coverage" on a product
- The agent needs to route a QA request to the correct execution skill

## When NOT to Use

- Implementation or fixing → route to issue-workflow / the product-implementer (you are file-don't-fix)
- A card is already mid-flight with an explicit skill directive → follow that directive

## Default Mission Loop

Every card runs the same five-step loop. Do not skip a step.

1. **Pull** — take the highest-priority card from the `product-verifier` board (team `organisation-design-team`).
2. **Identify** — read the card title/description. Classify the mission type (table below) and name the target product (repo + app type: Electron / web).
3. **Run** — execute the routed skill(s) for that mission type. Collect evidence: logs, screenshots, test output, coverage numbers, stack traces.
4. **File** — turn each verified finding into a scoped GitHub issue via `/skill:issue-creation`. File-don't-fix: never modify source. Cap at **5 issues per scan**.
5. **Complete** — complete the card on the board. If fixes are needed, handoff to the product-implementer with links to the filed issues.

## Mission Type Routing

| Mission type | Trigger (card says…) | Execution skill(s) | Evidence produced |
|--------------|----------------------|--------------------|-------------------|
| **e2e-verify** | "verify", "smoke test", "does it work", "release check" | `app-test` (automated desktop/web E2E) or `local-app-testing` (cliclick + CDP clickthrough for local Electron / DMeer) | screenshots, log output, click-path results |
| **bug-hunt** | "find bugs", "review changes", "audit", "security" | `find-bugs` (shallow PR-diff scan) → `codebase-audit` (full audit with parallel specialists) for full scans | findings with file:line + severity |
| **coverage/integration-audit** | "coverage", "integration tests", "what's untested" | `test-routing` (dispatch) → `test-design` (surface map) → `test-e2e` (Playwright smoke/full) + `test-integration` (DB/API/auth) → `test-review` (review-fix loop) | coverage %, surface gaps, pass/fail counts |

## Mission Type Details

### e2e-verify

- **Electron / local desktop (DMeer):** `/skill:local-app-testing` — real mouse clicks via cliclick + CDP element positions/screenshots. Click through as a user, not a script.
- **Web / deploy smoke:** `/skill:app-test` — launch app, run scenarios, verify logs and DB state, screenshot each step.
- **Output:** a structured pass/fail report per journey + screenshots. Failures become P0/P1 issues.

### bug-hunt

- **Targeted (default):** `/skill:find-bugs` on `git diff main...HEAD`, or files changed in the last 7 days if on main.
- **Full scan (card explicitly requests):** `/skill:codebase-audit` — parallel security/bug/config/supply-chain/database specialists.
- Verify every finding is not a false positive before filing. Classify P0/P1/P2 with file:line + repro steps.

### coverage/integration-audit

- `/skill:test-routing` to determine required verification domains and depth.
- `/skill:test-design` to map integration surfaces and assign test layers.
- `/skill:test-e2e` for missing browser-journey coverage (smoke or full depth).
- `/skill:test-integration` for missing DB/API/auth coverage (Supabase local, RLS verification).
- File an issue per gap: file path, current coverage %, regression-vs-new, what needs testing.

## File-Don't-Fix Rules

- **Never modify source files.** You identify and document; the product-implementer fixes.
- **Never run destructive tests** against production DBs/APIs.
- **Never exceed 5 issues per scan** without human approval — batch large findings into one issue with a checklist.
- **Always use `/skill:issue-creation`** so each issue carries O/I/T, affiliation, and domain-aware complexity.
- **WARN-ONLY at CI gates.** Your findings never block deployments.

## Output Format

```
## Mission: [card title]
**Type:** e2e-verify | bug-hunt | coverage/integration-audit
**Target product:** [repo / app type]
**Scope:** [what was scanned]

### Findings
- P0: [n] — [summary]
- P1: [n] — [summary]
- P2: [n] — [summary]

### Issues Filed
- [repo]#N — [title]
- ...

### Metrics
- Test pass rate: [x]/[y]
- Coverage: [before] → [after]
- Scan duration: [time]

### Handoff
- Card completed; fixes needed → product-implementer ([links])
```

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
