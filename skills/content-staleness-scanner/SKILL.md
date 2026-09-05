---
name: content-staleness-scanner
version: 1.0.0
description: Use when scanning for stale editorial content that needs refreshing, when asked to "check for stale content", "find pages that need refreshing", "run staleness scan", or "what content needs a refresh". Queries the DB, outputs a prioritized refresh queue, and optionally triggers content-refresh for each item.
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Staleness Scanner

> **Sync note:** Canonical copy at `agent-infra/skills/content-staleness-scanner/SKILL.md`. Product repos hard-link into `operations/skills/content-staleness-scanner/SKILL.md`; Pi reads via `~/.pi/agent/skills`. Edit the agent-infra copy only.

Proactively detects stale `category_content` pages that qualify for a `content-refresh` run. This skill is the automated counterpart to the manual staleness check embedded in `content-strategy-agent` — run it on a schedule or on-demand to surface the full refresh queue rather than checking a single page.

**Use this skill when:** You want to know which pages are stale across the whole site, or when preparing a batch refresh sprint.

**Design reference:** `docs/teams/organisation-design-team/domains (S1)/capability/2026-02-18-content-skill-system-design.md` (eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)

## Staleness Triggers

Identical to `content-refresh`:

| Trigger | Condition | Staleness reason |
|---|---|---|
| Age | `cc.updated_at < now() - interval '6 months'` | `age` |
| Deal growth | `current_deal_count >= ceil(deal_count_at_publish * 1.4)` | `deal_growth` |
| Both | Age AND deal growth both true | `both` |

## Phase 1 — Detection

Run the staleness query against `category_content` joined with `deals_with_ontology`:

```sql
SELECT
  cc.id,
  cc.geography_id,
  cc.category_id,
  cc.subcategory_id,
  cc.language,
  cc.updated_at,
  cc.deal_count_at_publish,
  COUNT(d.id) AS current_deal_count,
  CASE
    WHEN cc.updated_at < now() - interval '6 months'
      AND cc.deal_count_at_publish IS NOT NULL
      AND COUNT(d.id) >= ceil(cc.deal_count_at_publish * 1.4) THEN 'both'
    WHEN cc.updated_at < now() - interval '6 months' THEN 'age'
    WHEN cc.deal_count_at_publish IS NOT NULL
      AND COUNT(d.id) >= ceil(cc.deal_count_at_publish * 1.4) THEN 'deal_growth'
  END AS staleness_reason,
  now()::date - cc.updated_at::date AS days_since_refresh,
  CASE
    WHEN cc.deal_count_at_publish IS NOT NULL AND cc.deal_count_at_publish > 0
      THEN ROUND(
        (COUNT(d.id)::numeric - cc.deal_count_at_publish) / cc.deal_count_at_publish * 100,
        1
      )
    ELSE NULL
  END AS deal_growth_pct
FROM category_content cc
LEFT JOIN deals_with_ontology d
  ON d.effective_city = cc.geography_id
  AND cc.category_id = ANY(d.category_ids)
  AND d.status = 'LIVE'
WHERE cc.intro IS NOT NULL
GROUP BY
  cc.id, cc.geography_id, cc.category_id, cc.subcategory_id,
  cc.language, cc.updated_at, cc.deal_count_at_publish
HAVING
  cc.updated_at < now() - interval '6 months'
  OR (
    cc.deal_count_at_publish IS NOT NULL
    AND COUNT(d.id) >= ceil(cc.deal_count_at_publish * 1.4)
  )
ORDER BY
  -- Prioritize: both triggers > age > deal_growth, then oldest/most-stale first
  CASE
    WHEN cc.updated_at < now() - interval '6 months'
      AND cc.deal_count_at_publish IS NOT NULL
      AND COUNT(d.id) >= ceil(cc.deal_count_at_publish * 1.4) THEN 1
    WHEN cc.updated_at < now() - interval '6 months' THEN 2
    ELSE 3
  END,
  cc.updated_at ASC;
```

> **Query execution:** The Supabase anon key only allows PostgREST table/view access — this multi-table aggregation query cannot be run via the REST API. Use one of:
> - **Supabase SQL Editor** (Dashboard > SQL Editor): paste the SQL above and run directly
> - **MCP tool** (`mcp__seo-intelligence__*` Supabase query tool if available in context)

## Phase 2 — Output: Prioritized Refresh Queue

After running the query, present results as a table. Sort order: `both` triggers first, then `age`, then `deal_growth`; within each group, oldest `updated_at` first.

```
## Staleness Scan — [date]

Total stale pages found: [N]

| # | Page path | Language | Staleness reason | Days since refresh | Deal count at publish | Current deal count | Deal growth % | Last refreshed |
|---|---|---|---|---|---|---|---|---|
| 1 | /[geography_id]/[category_id] | es | both | 312 | 8 | 14 | +75.0% | 2025-03-10 |
| 2 | /[geography_id]/[category_id]/[subcategory_id] | es | age | 245 | 5 | 6 | +20.0% | 2025-05-22 |
| 3 | /[geography_id]/[category_id] | en | deal_growth | 48 | 5 | 8 | +60.0% | 2025-12-30 |
...

### Summary by trigger
- both (age + deal_growth): [N] pages
- age only: [N] pages
- deal_growth only: [N] pages

### Pages with NULL deal_count_at_publish
[List any pages where deal_count_at_publish IS NULL — these cannot trigger deal_growth staleness and should have the column populated after their next refresh.]
```

**Field definitions:**

| Field | Source |
|---|---|
| Page path | `/[geography_id]/[category_id]` or `/[geography_id]/[category_id]/[subcategory_id]` |
| Language | `cc.language` |
| Staleness reason | `age` / `deal_growth` / `both` |
| Days since refresh | `now()::date - cc.updated_at::date` |
| Deal count at publish | `cc.deal_count_at_publish` (NULL = column not yet set) |
| Current deal count | `COUNT(d.id)` from query |
| Deal growth % | `(current - at_publish) / at_publish * 100`, NULL if at_publish IS NULL |
| Last refreshed | `cc.updated_at` |

## Phase 3 — Optional Execution

After presenting the queue, ask:

```
Refresh queue is ready. Options:
  A) Refresh all [N] pages automatically (no confirmation per page)
  B) Step through the queue one at a time (confirm before each)
  C) Refresh a specific page — enter the # or page path
  D) Export queue only — no refresh now

Which option? (A/B/C/D)
```

### Option A — Batch (automatic)

Invoke `content-refresh` for each item in queue order without pausing. After each completes, log the result (see Phase 4) and move to the next. Present a summary at the end.

### Option B — Step-through (confirm per page)

For each item in the queue:

1. Show the item details:
   ```
   Next: /[path] ([language]) — [staleness_reason], [days_since_refresh] days stale, [deal_growth_pct]% deal growth
   Refresh this page? (yes / skip / stop)
   ```
2. If `yes` → invoke `content-refresh` for this item, then proceed to next
3. If `skip` → mark as skipped in the run summary, proceed to next
4. If `stop` → halt, output the run summary for pages processed so far

### Option C — Single page

Parse the user's input (number from table or page path) to identify the `category_content` row. Invoke `content-refresh` for that single item. Output the result.

### Option D — Export only

Output the queue table from Phase 2 with no further action. User can paste the queue into another session or use it for sprint planning.

### Invoking content-refresh

When triggering a refresh, pass:

```
geography_id:       [cc.geography_id]
category_id:        [cc.category_id]
subcategory_id:     [cc.subcategory_id or NULL]
language:           [cc.language]
staleness_reason:   [age / deal_growth / both]
current_deal_count: [COUNT(d.id) from scan query]
```

The `content-refresh` skill fetches the existing content and new deals itself — the scanner only passes the staleness context.

## Phase 4 — Run Summary

After all items are processed (batch or step-through), output:

```
## Staleness Scanner — Run Summary
Scan date: [date]
Pages in queue: [N]
Pages refreshed: [N]
Pages skipped: [N]
Pages failed: [N]

### Refreshed
[For each: - /[path] ([language]) — [staleness_reason] — DONE]

### Skipped
[For each: - /[path] ([language]) — skipped by user]

### Failed
[For each: - /[path] ([language]) — [brief error or reason]]

### Still NULL deal_count_at_publish (no deal_growth tracking)
[List pages that had NULL at scan time — recommend populating after refresh]
```

## Phase 4 — Logging

After completing the scan (Phase 2), append one JSONL entry per stale page found to `operations/logs/content-review-errors.jsonl`. If 0 stale pages were found, skip logging.

For each stale page in the queue, run:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'content-staleness-scanner',
  'version': '1.0.0',
  'page_slug': 'PAGE_SLUG_HERE',
  'language': 'LANGUAGE_HERE',
  'staleness_reason': 'STALENESS_REASON_HERE',
  'days_since_refresh': DAYS_SINCE_REFRESH_HERE,
  'deal_count_at_publish': DEAL_COUNT_AT_PUBLISH_HERE,
  'current_deal_count': CURRENT_DEAL_COUNT_HERE,
  'deal_growth_pct': DEAL_GROWTH_PCT_HERE
}
print(json.dumps(entry, ensure_ascii=False))
")
curl -sf -X POST \
  'https://axaeagulqhanatyoxrdv.supabase.co/rest/v1/content_staleness_scans' \
  -H 'apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=minimal' \
  -d "[$JSON]" \
|| (mkdir -p operations/logs && echo "$JSON" >> operations/logs/content-staleness-scans.jsonl)
```

**Field values — populate from scan results:**
- `page_slug`: the URL path of the stale page (e.g., `cancun/restaurantes` or `playa-del-carmen/restaurantes/mariscos`)
- `language`: `cc.language` from the scan query
- `staleness_reason`: `age` / `deal_growth` / `both`
- `days_since_refresh`: integer — `now()::date - cc.updated_at::date` from the scan query
- `deal_count_at_publish`: integer or `null` — `cc.deal_count_at_publish`
- `current_deal_count`: integer — `COUNT(d.id)` from the scan query
- `deal_growth_pct`: float or `null` — computed deal growth percentage; `null` if `deal_count_at_publish IS NULL`

## Notes

- This skill is **read-only in Phase 1 and 2** — it does not modify any DB rows until `content-refresh` is explicitly triggered in Phase 3.
- Pages with `cc.intro IS NULL` are excluded — they have no published content and need `content-strategy-agent` (full write), not a refresh.
- Pages with `deal_count_at_publish IS NULL` can only trigger the `age` staleness reason; they appear in the queue if age-stale. After `content-refresh` runs, `deal_count_at_publish` is set, enabling future deal-growth tracking.
- If the query returns 0 rows, report "No stale pages found — all published content is within staleness thresholds." and stop.
- For pages where `staleness_reason = 'both'`, pass `staleness_reason: 'both'` to `content-refresh`; that skill treats `both` with the broader `age` scope (spot-check price data + integrate new partners).
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
