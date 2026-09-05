---
name: content-reviewer-breadth
version: 1.0.0
description: Use when reviewing editorial, guide, or deal content to ensure nothing essential from the research brief was dropped during writing. Checks neighborhood coverage, cuisine/experience types, price tiers, and partner completeness. Returns structured issues and specific fixes. Part of content pipeline v2 post-writing review — run in parallel with other reviewers.
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Reviewer — Breadth

> **Sync note:** Canonical copy at `agent-infra/skills/content-reviewer-breadth/SKILL.md`. Product repos hard-link into `operations/skills/content-reviewer-breadth/SKILL.md`; Pi reads via `~/.pi/agent/skills`. Edit the agent-infra copy only.

Verify the draft covers all essential dimensions from the research brief. Writers sometimes drop neighborhoods, cuisines, or partners in the interest of flow. This reviewer catches those gaps before they reach publish.

## Inputs Required

**For editorial/guide (page_type = "editorial" or "guide"):**
- **Draft content** (intro, body, FAQs, meta_title, meta_description)
- **Research brief** — neighborhood list, cuisine/experience types, price tiers, partner list, Places Search local gems

**For deals (page_type = "deal"):**
- Deal content: title, title_es, description, description_es, how_to_book, how_to_book_es (post-synthesis)
- Deal Research Brief (from deal-content-writer Step 0.5, with confidence tags updated by content-fact-checker-research D3)
- deal_id, language

## Output Format

```
ISSUE #N
Dimension: Breadth
Severity: P0 | P1 | P2
Location: [location in draft where addition should go, or "missing section"]
Problem: [what's missing and why it matters]
Fix: [exact text to add, or specific instruction for where/how to add it]
```

End with:
```
BREADTH REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Missing neighborhoods: [list]
Missing cuisine/experience types: [list]
Missing partners: [list]
```

## Step 0: Fresh DB Deal Audit (Always First — editorial/guide only)

**Do NOT rely solely on the research brief's partner list.** The research brief may have missed deals due to geography hierarchy or query mismatches. Before running any checks, independently query the DB to get the authoritative deal list for this page:

```sql
-- Primary: exact match
SELECT d.business_name, d.title, d.title_es, d.category_id, d.subcategory_id,
       d.geography_id, d.discount_percentage, d.value_mechanism
FROM deals_with_ontology d
WHERE d.status = 'LIVE'
  AND d.geography_id = '[geography_id from page metadata]'
  AND d.category_id = '[category_id from page metadata]'
ORDER BY d.discount_percentage DESC NULLS LAST;

-- Broader: catch geography hierarchy mismatches
SELECT d.business_name, d.geography_id, d.category_id, d.subcategory_id
FROM deals_with_ontology d
WHERE d.status = 'LIVE'
  AND d.geography_id ILIKE '%[city-keyword]%'
  AND d.category_id = '[category_id]';
```

**Reconcile DB results vs. research brief partner list:**
- Deals in DB but **not** in the research brief → mark as `⚠️ BRIEF MISSED THIS DEAL` and add to your working partner list
- These missed deals are treated the same as any other partner for all checks below — BR1 will flag them if absent from content

**Use the DB query results as the authoritative partner list for all checks below, not the research brief.**

> **Skip Step 0 for deal page_type** — deal mode checks (B-D1–B-D4) do not require a DB audit; proceed directly to Deal Scope section.

---

## Checks to Run

### P0 — Must Fix

**BR1 — No active partner entirely absent**
- Cross-reference draft against all partners in research brief
- A partner with an active deal who gets zero mention is always P0
- Fix: suggest the shortest acceptable mention — one sentence with their key quality + deal callout — and specify where it fits (e.g., "add to the [Italian restaurants] section after [La Famiglia]")

### P1 — Should Fix

**BR2 — Key neighborhoods covered**
- From research brief, list the major neighborhoods/areas mentioned
- Check each appears at least once in the draft (even a brief mention is sufficient)
- Fix: for each missing neighborhood, suggest a one-sentence addition that fits naturally

**BR3 — Price tier coverage**
- Draft should reference all three price tiers:
  - Budget: tacos, street food, comida corrida (20–120 MXN range)
  - Mid-range: sit-down restaurants (150–400 MXN per person)
  - Premium/fine dining: Michelin, cave restaurants, tasting menus (400+ MXN)
- Fix: if a tier is completely absent, suggest the most natural partner or non-partner to represent it

**BR4 — Cuisine/experience type coverage**
- From research brief's subcategory breakdown, identify the major cuisine or experience types present in the partner list
- Check that each major type with at least one partner appears in the draft
- Fix: for each missing type, suggest a one-sentence addition mentioning the relevant partner(s)

**BR5 — Places Search local gems included**
- Research brief should include local Places Search gems (high rating, low review count — local credibility signals)
- Check that at least 1–2 appear in the draft as non-partner mentions
- Fix: suggest adding the highest-rated local gem (fewest reviews / highest stars) as a brief non-partner mention

### P2 — Should Fix (blocks merge)

**BR6 — Comparison table coverage**
- If a comparison table exists, check it includes the highest-discount partners in the top rows
- Fix: suggest swapping a low-discount table row for a missing high-discount partner

**BR7 — Seasonal or timing context**
- If research brief mentioned seasonal variations (high season, low season, specific events), check if the draft mentions them
- Fix: suggest adding a one-sentence practical tip if seasonality is relevant to the category

---

## Deal Scope (page_type = "deal")

Skip all editorial/guide checks above. Run only:

**B-D1 [P1]:** Does the description include at least 2 `specialty_facts` from the Deal Research Brief?
- Count specialty_facts tagged ✓ or ~ in the brief; count how many appear (verbatim or paraphrased) in description
- Issue if < 2: "Missing specialty facts from research brief: [list missing ✓ items]"
- If `research_confidence = LOW`: downgrade to P2 (description correctly relies on DB facts only)

**B-D2 [P1]:** Does the description include at least 1 `vibe_descriptor` from the research brief?
- Issue if none: "No vibe descriptor from research brief found in description"
- If `research_confidence = LOW`: downgrade to P2

**B-D3 [P1]:** If `local_angle = "local-favorite"` in the research brief, does the description reflect this?
- Issue if absent: "Research found this is a local-favorite venue — description doesn't reflect it"

**B-D4 [P2]:** Are `practical_tips` from the research brief incorporated (in description or how_to_book)?
- Soft check — P2 only

**Output:** Issue list + "Research coverage: X/Y specialty facts used, X/Y vibe descriptors used"

## Logging

After producing the review output above, append one JSONL entry per issue found to `operations/logs/content-review-errors.jsonl`. Log all three severity levels (P0, P1, P2) — do not skip P2 issues. Only omit a log entry if a check produced zero issues.

For each issue, run:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'content-reviewer-breadth',
  'version': '1.0.0',
  'page_type': 'PAGE_TYPE_HERE',
  'page_slug': 'PAGE_SLUG_HERE',
  'cycle': 1,  # replace with actual cycle number as bare integer (no quotes)
  'dimension': 'Breadth',
  'check_id': 'CHECK_ID_HERE',
  'severity': 'SEVERITY_HERE',
  'location': 'LOCATION_HERE',
  'problem': 'PROBLEM_HERE',
  'fix': 'FIX_HERE',
  'snippet': 'SNIPPET_HERE',
  'writer_skill': 'WRITER_SKILL_HERE'
}
print(json.dumps(entry, ensure_ascii=False))
")
curl -sf -X POST \
  'https://axaeagulqhanatyoxrdv.supabase.co/rest/v1/content_review_errors' \
  -H 'apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=minimal' \
  -d "[$JSON]" \
|| (mkdir -p operations/logs && echo "$JSON" >> operations/logs/content-review-errors.jsonl)
```

**Field values — populate from context:**
- `skill`: this skill's `name` from frontmatter
- `version`: this skill's `version` from frontmatter
- `page_type`: as received from orchestrator (editorial / guide / deal)
- `page_slug`: the URL slug or identifier for the content being reviewed (e.g., `restaurantes-cancun/mariscos`); use `null` if not provided
- `cycle`: integer review cycle number as received from orchestrator; use `1` if not provided
- `dimension`: the Dimension label from the issue (e.g., `SEO-GEO`, `GEO`, `Commercial`, `Breadth`, `Depth`, `FactCheck`)
- `check`: the check ID from the issue (e.g., `K3`, `DP4`, `BR2`, `FC1`)
- `severity`: `P0`, `P1`, or `P2`
- `location`: the Location field from the issue
- `problem`: the Problem field from the issue (truncate to 200 chars if longer)
- `fix`: the Fix field from the issue (truncate to 200 chars if longer)
- `snippet`: the shortest excerpt of offending text from the content that illustrates the problem (≤150 chars); use `null` if the issue is structural (e.g., a missing element)
- `writer_skill`: the skill that wrote the content (e.g., `editorial-content-writer`, `guide-content-writer`, `deal-content-writer`, `content-refresh`); use `null` if not provided
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
