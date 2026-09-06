---
title: "Issue #476 sC2 — qwen-tp rate basis + exhaustion signature: live probes deferred (401-blocked)"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, qwen-tp, check-cost-config
aboutObjects: agent-infra, pi, issue-476
---

# Issue #476 sC2 — qwen-tp (Aliyun Token Plan) Rate Basis + Exhaustion Signature: LIVE PROBES DEFERRED (401-blocked)

- **Date:** 2026-09-05
- **Spike:** sC2 (issue #476 — provider-exhaustion failover)
- **Question:** qwen-tp (when unblocked) real rate basis + exhaustion signature + fleet-scale (11-concurrent × full-context) capacity + child-death shape/latency per status code → pins N/W for 429-advance + rate-basis for cost metadata.
- **Method:** Live probe against the qwen-tp compatible-mode endpoint (`https://ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/models`, `Authorization: Bearer $QWEN_WS_API_KEY`/`$QWEN_TOKEN_PLAN_API_KEY`) — 2026-09-05T23:1xZ.

## Finding: qwen-tp remains 401-BLOCKED — live rate/exhaustion probes SKIPPED and DEFERRED

- Probe result: **HTTP 401** with body
```json
{"error":{"message":"Incorrect API key provided. For details, see: https://www.alibabacloud.com/help/en/model-studio/error-code#apikey-error","type":"invalid_request_error","param":null,"code":"invalid_api_key"},"request_id":"4ceacece-18e1-9027-9796-6778215bca40"}
```
- The issue-body context recorded the block as 401 "API-key is blocked" (Sep 5, earlier probe); today's live probe returns the standard Aliyun invalid-key body (`invalid_api_key`, message "Incorrect API key provided"). Either way: **the configured qwen-tp keys are rejected by the endpoint → qwen-tp is EXCLUDED-WITH-ALERT from the active failover chain**; the default chain is `deepseek → openrouter` while blocked.
- Note the signature value: qwen-tp's invalid-key class (`code: invalid_api_key`) is the SAME permanent-auth class family as the 401/403 permanent class in the exhaustion signature — a useful cross-check that "401 invalid_api_key" must be treated as PERMANENT (auth remediation needed), never as an exhaustion latch trigger and never as a transient connection error.
- ⚠️ Cross-provider field inversion (post-review P2): DeepSeek 401 bodies use `type: "authentication_error"` with `code: "invalid_request_error"` (s6), while Aliyun uses `type: "invalid_request_error"` with `code: "invalid_api_key"`. The providers INVERT which field carries the auth signal, and DeepSeek's invalid-key `code` collides with a generic request-error string. Classifiers MUST key on HTTP STATUS (401/403 → permanent auth class), never on `code`/`type` cross-provider.

## Deferred (recorded — re-open when credentials are remediated)
1. Real rate basis for qwen-tp deepseek legs (per-1M blended input/output/cache prices on the Aliyun token plan) → pins the `cost` metadata for the qwen-tp hop legs in models.json / extension registrations. Until then qwen-tp legs must carry either the known-official blended rates (same model, same token plan family) or an explicit costUnknown flag — never silent $0.
2. qwen-tp exhaustion signature (its own "insufficient balance"/quota text + status codes) for the signature table.
3. Fleet-scale capacity pin (11-concurrent × full-context) → N/W for the 429-advance policy.
4. Child-death shape/latency per status code on the Aliyun endpoint.

Credential remediation = separate follow-up (issue #476 body Context): do NOT block the implementation on it. Re-enable = config-only chain reorder once keys are live.

## Implications for the #476 design
- Active chain while blocked: `deepseek → openrouter` (per-primary state, per-model alias-family chains).
- qwen-tp remains registered as a chain member for when keys are remediated; hop selection excludes 401/403-blocked legs with an alert (excluded-with-alert class), matching the permanent-auth class handling.
- Any code path that would "probe" a latched leg must never probe 401-blocked legs (capped probe budget — s6).
