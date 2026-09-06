---
title: "Issue #476 s6 — balance/auth endpoint shapes for the restore-authority poller"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, deepseek-balance-watch
aboutObjects: agent-infra, pi, api.deepseek.com, openrouter.ai, issue-476
---

# Issue #476 s6 — Balance/Auth Endpoint Shapes for the Restore-Authority Poller

- **Date:** 2026-09-05
- **Spike:** s6 (issue #476 — provider-exhaustion failover)
- **Question:** DeepSeek `/user/balance` endpoint + auth + shape (zero-token probe preferred); OpenRouter `/auth/key`; per-provider `action_url` for notices.
- **Method:** Live zero-token probes against api.deepseek.com and openrouter.ai with real API keys (2026-09-05T23:1xZ). No chat/completion tokens consumed (balance + auth-key endpoints only). Response bodies below are balance metadata — no secret material is echoed except OpenRouter's own masked key label (`sk-or-v1-a40...688`).

## Findings

### 1. DeepSeek `GET /user/balance` — 200, no tokens consumed
- Endpoint: `https://api.deepseek.com/user/balance`
- Auth: `Authorization: Bearer $DEEPSEEK_API_KEY`
- Live response (2026-09-05T23:1xZ):
```json
{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"91.43","granted_balance":"0.00","topped_up_balance":"91.43"}]}
```
- Shape notes for the poller:
  - `is_available` — boolean; account usable.
  - `balance_infos[]` — one entry per currency. **`total_balance`/`granted_balance`/`topped_up_balance` are JSON STRINGS, not numbers** — the poller must parse them with `printf %s | awk`/python float conversion, not treat them as numeric JSON.
  - Multi-currency: `balance_infos` may contain multiple entries (e.g. CNY + USD) — a taxonomy needs a per-currency total (select the currency matching the provider's spend currency; report all).
  - DeepSeek official is prepaid-credit (topped_up_balance tracks top-ups; granted tracks promos).
- Invalid-key shape (probe with a bad key): HTTP 401 with body
```json
{"error":{"message":"Authentication Fails, Your api key: ****-123 is invalid","type":"authentication_error","param":null,"code":"invalid_request_error"}}
```
  → poller SKIP class on 401/403 (auth is broken, not balance); matches the 401/403 permanent auth class in the exhaustion signature (do NOT latch, do NOT clear).

### 2. OpenRouter `GET /auth/key` — 200, no tokens consumed
- Endpoint: `https://openrouter.ai/api/v1/auth/key`
- Auth: `Authorization: Bearer $OPENROUTER_API_KEY`
- Live response (2026-09-05T23:1xZ), key fields:
```json
{"data":{"label":"sk-or-v1-a40...688","is_management_key":false,"limit":60,"limit_reset":"monthly","limit_remaining":58.930615993,"include_byok_in_limit":true,"usage":93.266100275,"usage_daily":0.23591321,"usage_monthly":1.069384007,"is_free_tier":false,"expires_at":null,"rate_limit":{...}}}
```
- Shape notes:
  - `data.limit` — monthly credit limit (USD); `data.limit_remaining` — **remaining credit (number, not string)**; `data.usage` — lifetime usage.
  - `data.is_free_tier` — false for paid keys.
  - This endpoint is the zero-token "probe all latched legs" mechanism for the openrouter leg: a 200 with `limit_remaining` = leg alive; 401 = auth dead.
  - OpenRouter credits are spend-limit (postpaid-style limit) rather than prepaid — the poller's clear condition on the openrouter leg is `limit_remaining` above threshold, not a prepaid balance.
- Per-provider `action_url` candidates for notices (documented, not probed): DeepSeek `https://platform.deepseek.com/top_up` (billing/top-up); OpenRouter `https://openrouter.ai/settings/credits`.

### 3. Probe budget (capped)
- Both endpoints are zero-token GETs; the poller may hit them every interval without token cost. Chat probes (the plan's "chat-probe pass" before CLEAR) are the only token spend and should be minimal (5-token reply cap, mirroring provider-latency-tripwire.sh) and only after a balance read passes.

## Verdicts
- DeepSeek `/user/balance` reachable + shape captured (zero-token): **YES** — `{"is_available": bool, "balance_infos": [{currency, total_balance (STRING), granted_balance (STRING), topped_up_balance (STRING)}]}`; 401 shape on bad key captured.
- OpenRouter `/auth/key` reachable + shape captured (zero-token): **YES** — `{"data": {limit, limit_remaining (number), usage, is_free_tier, ...}}`.
- Poller parse hazards: DeepSeek balances are string-typed; multi-currency entries exist; 401/403 = SKIP (auth class), 5xx/timeout = defer+escalate.

## Implications for the #476 design (Phase 5 poller)
- `deepseek-balance-watch.sh` parses `balance_infos` with float conversion of string totals, keys the threshold on the USD entry (deepseek official spend currency), and treats 401/403 as SKIP (never SET on auth failure — the SET-on-~0 decision must come from a 200 with parsed ~0 balance or the documented exhaustion signature, not from an auth error).
- OpenRouter leg probe = `/auth/key` 200 + `limit_remaining` above threshold.
- Notices carry per-provider action_url (deepseek top-up page; openrouter credits page).
