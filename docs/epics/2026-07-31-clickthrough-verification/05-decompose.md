# Epic Decompose — Post-Deploy Clickthrough Verification

**Date:** 2026-07-31
**Parent:** 04-plan.md
**Child issues:** 8

## Dependency Graph

```
FOUNDATION (parallel — no deps)
├─ #1: detect-deploy-surface.sh           [low]
├─ #2: web-clickthrough/SKILL.md          [standard]
├─ #3: desktop-clickthrough/SKILL.md      [standard]
└─ #4: infra-verify/SKILL.md              [low]
         │
INTEGRATION
└─ #5: post-deploy-verify/SKILL.md        [standard]
         │
WIRING
├─ #6: templates/e2e/clickthrough.spec.ts  [low]
└─ #7: Update 04-merge-deploy.md          [standard]
         │
INSTANTIATION
└─ #8: Example @clickthrough spec (eldato) [low]
```

## MECE Verification

| Check | Status |
|-------|--------|
| Mutually Exclusive | ✅ Each issue produces a distinct file or file set |
| Collectively Exhaustive | ✅ Covers all plan deliverables |
| Dependency integrity | ✅ 4 parallel → 1 integration → 2 wiring → 1 instantiation |

## Issue Summaries

| # | Title | Complexity | Delivers |
|---|-------|-----------|----------|
| 1 | `detect-deploy-surface` script | low | Bash script classifying PR diff → {web, desktop, infra} |
| 2 | `web-clickthrough` sub-skill | standard | SKILL.md: Playwright @clickthrough protocol |
| 3 | `desktop-clickthrough` sub-skill | standard | SKILL.md: cliclick+CDP desktop protocol (DMeer #150 pattern) |
| 4 | `infra-verify` sub-skill | low | SKILL.md: script validation + skill lint protocol |
| 5 | `post-deploy-verify` router | standard | SKILL.md: thin router — detect → dispatch → report |
| 6 | `clickthrough.spec.ts` template | low | Template Playwright spec with @clickthrough tag |
| 7 | commit-workflow Step 3.8 | standard | Wire post-deploy-verify into 04-merge-deploy.md |
| 8 | Example @clickthrough spec | low | Real spec: "Browse deals → reserve → QR" against production |
