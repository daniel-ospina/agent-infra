---
name: tortoise-verify-chain
title: "tortoise-verify-chain"
doc_status: live
subjects.team: epistemic-team
created: 2026-07-18
description: Verify chain integrity across all product strategy gates. Runs the chain-integrity check (tortoise_check_structure), surfaces violations, and offers fix options.
type: capability
domain: capability
status: live
allowed-tools: mcp__tortoise__tortoise_check_structure, mcp__tortoise__tortoise_summarize_structure, mcp__tortoise__tortoise_create_point, mcp__tortoise__tortoise_query
---

# tortoise:verify-chain

Verify that the product strategy chain (JTBD → useCase → userJourney → workflow → requirement) has no violations.

> **Tool surface (synced 2026-08-13, #1168):** the chain-verify tools live
> on the in-repo MCP surface as `tortoise_check_structure` (Gate 0→4 chain
> integrity — orphans/dangling refs) and `tortoise_summarize_structure`
> (per-gate counts). The previously documented `tortoise_verify_chain` /
> `tortoise_get_chain_status` tools do NOT exist in tool_registry.py and
> will error with tool-not-found. (After #405 lands, `tortoise_validate_domain`
> is the richer domain-validation surface — prefer it once available.)

## Steps

1. Call `tortoise_summarize_structure()` to get summary counts per gate.
2. Call `tortoise_check_structure()` to get detailed chain violations
   (Gate 0→4 orphans, dangling references).
3. If clean: report "all chain integrity rules pass."
4. If violations found, for each violation:
   - Surface the affected Point ID and the rule that failed.
   - Offer to fix: create missing parent JTBD, add covered_use_cases, link requirement to workflow.
5. Optionally apply fixes via `tortoise_create_point` or other tools.

## Quality Gates

- **G1 (Static):** Verify that the graph context exists and has Points (`tortoise_query`).
- **G2 (Semantic):** If violations are found, classify severity: P0 (orphan useCase without JTBD parent) vs P2 (missing optional metadata).

## Error Handling

- If `tortoise_check_structure` fails, report the error. Do not attempt fixes on a broken query.
