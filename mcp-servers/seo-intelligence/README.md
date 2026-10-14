# seo-intelligence MCP server

The shared **`seo-intelligence`** MCP server — 24 tools covering Perplexity search/research, SERP
routing, Google Search Console, Google Places, HubSpot, and email.

**This is rung 1 of the `research` skill's search-tool ladder.** It hits the Perplexity **Search API**
(`https://api.perplexity.ai/search`) — a flat **~$0.005/query** — and deliberately never
`/chat/completions`, where the $5–40/call models (`sonar-deep-research`, `sonar-reasoning-pro`) live.
That is the whole point of the rung: cheap grounding, no token-priced synthesis.

> ⛔ The `research` skill (and `web_search`'s own tool description) has referenced
> `mcp__seo-intelligence__perplexity_search` / `perplexity_research` since 2026-09-17, but the server
> lived only in `eldato/operations/mcp-server` and was never wired into **pi**'s config —
> so `mcp_load seo-intelligence` returned *Unknown MCP server* on every machine that was not eldato.
> See `daniel-ospina/premise-labs#400`. Moving it here makes it available to every repo that uses
> agent-infra.

## Tools

| Group | Tools |
|---|---|
| Health | `ping` |
| **Perplexity** | `perplexity_search`, `perplexity_research` |
| SERP | `search_serp`, `search_serp_local`, `serp_usage` |
| Google Places | `places_search`, `places_details` |
| Search Console | `gsc_query_analytics`, `gsc_near_ranking`, `gsc_low_ctr`, `gsc_page_opportunities`, `gsc_inspect_url` |
| HubSpot | `hubspot_create_partner`, `hubspot_update_partner`, `hubspot_list_partners`, `hubspot_log_outreach`, `hubspot_create_customer`, `hubspot_update_customer`, `hubspot_list_customers`, `hubspot_log_customer_note`, `hubspot_create_task` |
| Email | `send_email`, `get_email_status` |

## Setup

```bash
cd "$AGENT_INFRA_PATH/mcp-servers/seo-intelligence"
npm install
cp .env.example .env      # then fill in the keys you need
```

`PERPLEXITY_API_KEY` is the only key required for the rung-1 research tools, and it is normally
already present in the environment. The other tool groups degrade independently — a missing
`GOOGLE_*` key disables only the `gsc_*` tools.

Generate the Search Console refresh token:

```bash
npm run auth:search-console
```

> **OAuth note:** the Google OAuth app's publishing status must be **"In production"**, not "Testing".
> Testing mode revokes the refresh token after 7 days.

## Running

The server speaks MCP over stdio. It is launched by pi from `.mcp.json`:

```json
"seo-intelligence": {
  "command": "${AGENT_INFRA_PATH}/mcp-servers/seo-intelligence/node_modules/.bin/tsx",
  "args": ["server.ts"],
  "cwd": "${AGENT_INFRA_PATH}/mcp-servers/seo-intelligence",
  "env": { "PERPLEXITY_API_KEY": "${PERPLEXITY_API_KEY}" },
  "lazy": true
}
```

It is registered `lazy: true` so its 24 tool definitions do not occupy context until a task actually
needs them.

## Tests

```bash
npm test
```
