# Epic Align — Post-Deploy Clickthrough Verification

**Date:** 2026-07-31
**Decision:** PROCEED (with modifications from adversarial review)

## Strategy Alignment Decision

**Feature:** Post-merge clickthrough verification protocol — automated real-user simulation that runs after commit/merge to validate features actually work.

**Decision:** PROCEED → Research (with architecture modified by reviewer feedback)

## Adversarial Review (incorporated)

Original reviewer verdict: REDIRECT to research spike. Issues addressed:

1. **Alternatives were straw-men** → Genuinely engaged: pre-merge clickthrough = better architecture for web, but post-merge still needed for desktop (no CI preview). Production monitoring = complementary, not alternative. Manual QA checklist = what user IS doing and it burns days.

2. **Profit causality was hand-wavy** → Revised to time-recovery-only: user reports days/week lost to manual verification. Churn attribution removed.

3. **Platform constraint (cliclick = macOS-only)** → THIS IS THE KEY FINDING. Desktop clickthrough CANNOT run in GitHub Actions CI. Must be agent-executed (local). Web CAN run in CI via Playwright on Linux runners.

4. **Matrix honesty** → Acknowledged verification-before-completion exists but covers code correctness, not user outcomes. New protocol fills a different gap.

5. **Common protocol assumption** → Abandoned. Three separate protocols unified by a single router, not a single protocol.

## Key Architecture Decisions (from adversarial review)

1. **Desktop = agent-executed, not CI-automated** (cliclick is macOS-only)
2. **Web = Playwright in CI** (existing infra, just new @clickthrough specs)
3. **Infra = script-based validation** (existing check-* scripts)
4. **One router skill, three focused sub-skills** (test-routing pattern, context-managed)
5. **All code in agent-infra** (symlinked to consuming repos — 91 existing symlinks)

## Eisenhower Matrix

**Important + Urgent = Do now.**
User actively loses days to manual verification. Bugs are merged. PRs are stalled.

## Profit Impact

Time recovery: 3+ hrs/week currently lost to manual verification. Build cost: ~3.5-4.5 weeks total.

## Assumptions

| Assumption | Confidence | Source |
|-----------|-----------|--------|
| Clickthrough catches meaningful post-merge bugs | HIGH | DMeer #150, user direct experience |
| Desktop protocol can be automated enough to be practical | MEDIUM | Local-app-testing skill exists but formalization needed |
| Router + sub-skill architecture is maintainable | HIGH | Follows test-routing, code-review patterns |
