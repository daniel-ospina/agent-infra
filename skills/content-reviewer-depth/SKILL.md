---
name: content-reviewer-depth
version: 1.0.0
description: Use when reviewing editorial, guide, or deal content for local depth, unique insights, and audience consistency. Checks that content goes beyond generic travel blog coverage, incorporates unique research findings, and speaks consistently to the right audience (residents for ES, expats/tourists for EN). Returns structured issues and specific fixes. Part of content pipeline v2 post-writing review — run in parallel with other reviewers.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Reviewer — Depth & Relevance

> **Sync note:** Local copy at `~/.claude/skills/content-reviewer-depth/SKILL.md`. Repo copy at `operations/skills/content-reviewer-depth/SKILL.md`. Keep in sync.

Review content for two qualities:
1. **Local depth** — tips and facts that generic travel blogs wouldn't have
2. **Audience relevance** — consistent voice and angle for the target reader

## Inputs Required

**For editorial/guide (page_type = "editorial" or "guide"):**
- **Draft content** (intro, body, FAQs, meta_title, meta_description)
- **Research brief** — especially Reddit/forum signals, Places Search gems, Perplexity "poco conocido/secreto" findings, local knowledge facts, SERP landscape summary
- **Language** (es/en) — determines audience consistency checks

**For deals (page_type = "deal"):**
- Deal content: description, description_es (post-synthesis)
- Deal Research Brief (from deal-content-writer Step 0.5)
- deal_id, language

## Output Format

```
ISSUE #N
Dimension: Depth
Severity: P0 | P1 | P2
Location: [exact location]
Problem: [specific description]
Fix: [exact fix or instruction]
```

End with:
```
DEPTH REVIEW SUMMARY
P0 issues: [count] — none expected; depth is never a blocker
P1 issues: [count]
P2 issues: [count]
Unique findings from research used: [count] / [total available]
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
- These missed deals count as partners whose presence or absence in the content affects depth and coverage checks below

**Use the DB query results as the authoritative partner list for all checks below, not the research brief.**

> **Skip Step 0 for deal page_type** — deal mode checks (D-D1–D-D3) do not require a DB audit; proceed directly to Deal Scope section.

---

## Checks to Run

### P0

Depth issues are never P0. Content can publish with depth gaps — they improve quality but don't block.

### P1 — Should Fix

**DPT1 — Audience voice consistency**

For ES content:
- Scan for tourist-perspective phrasing: "tourists will love", "visitors can enjoy", "perfect for a vacation", "the perfect destination"
- Fix: rewrite to resident perspective — "los que vivimos aquí", "para los que somos de aquí", "si ya conoces la zona"

For EN content:
- Check that expat angle is present if research brief surfaced Reddit/expat forum signals
- Fix: if research had expat signals and draft doesn't use them, suggest where to add a brief expat-perspective sentence or FAQ

**DPT2 — Unique research findings incorporated**

From research brief, identify findings NOT commonly found in tourist blogs:
- Places Search gems (high rating, low reviews, absent from SERP results)
- Reddit/forum mentions (specific venue names, tips, experiences)
- Perplexity "poco conocido/secreto" findings
- Local knowledge facts (specific prices, neighborhood character, cultural context)

Check that at least 2–3 of these appear in the draft.
Fix: for each missing unique finding, suggest where and how to insert it (1–2 sentences maximum per insertion — keep surgical).

**DPT3 — Generic filler phrases**

Flag these patterns anywhere in the body:
- "hidden gem" without a specific follow-up fact (rating, review count, specific dish)
- "must-try" without a specific dish name or price
- "locals love" without saying WHAT locals specifically love about it
- "authentic experience" without sensory or specific detail
- "best in the city" without a citation, qualifier, or specific evidence
- "you won't be disappointed" / "not to be missed" — empty tourism language

**✗-tagged claims are automatic DPT3 flags:** Any claim drawn from a research brief item marked ✗ (unverified / not found) is by definition an unverified claim. Treat each such claim as a DPT3 issue regardless of whether it uses filler language — it must be investigated further, hedged with explicit uncertainty, or removed from the content.

Fix: for each instance, suggest rewriting with the specific fact from Partner Profiles or local knowledge section of research brief. For ✗-tagged claims, the fix is: "Remove or hedge — research brief marks this ✗ (not verified). Replace with a ✓ or ~ fact, or delete."

**DPT4 — Sensory and hyper-specific details: at least 3**

Good examples:
- "the al pastor trompo is visible from the street — a reliable freshness signal"
- "tables fill up by 8pm on weekends; arrive before 7:30 or expect a wait"
- "portions are big enough for two at 150–220 MXN"
- "the cenote cave keeps it cool even in August — bring a light layer"

Flag if fewer than 3 such details exist in the body.
Fix: suggest inserting one from Partner Profiles or the local knowledge section of the research brief.

### P2 — Should Fix (blocks merge)

**DPT5 — At least one tip not found in SERP top 5**

Quick check: does the content contain at least one claim or tip that does NOT appear in the top 5 SERP results summarized in the research brief?

If everything in the draft also appears in competitors' content, the page won't stand out to either readers or AI citation systems.

Fix: suggest pulling one unique fact from the research brief's Places Search or Perplexity "poco conocido" findings that isn't in competitor content.

---

## Deal Scope (page_type = "deal")

Skip all editorial/guide checks above. Run only:

**D-D1 [P1]:** Does the description contain any generic marketing descriptor without research backing?
- Flag each instance of: "world-class", "excellent", "amazing", "unforgettable", "unique", "outstanding", "best in", "truly" — IF not backed by a ✓ CONFIRMED item in the research brief
- Issue: "Generic descriptor '[X]' has no research backing — replace with specific claim from brief or remove"
- If `research_confidence = LOW`: note as "acceptable given low confidence" rather than raising issue

**D-D2 [P1]:** Does the description include at least 1 hyper-specific detail from the research brief?
- Hyper-specific = a named dish, a named feature, a named crowd type, a specific characteristic unique to this business
- Issue if none: "Description lacks any specific detail from research — reads like generic copy. Research brief has: [list ✓ items]"
- If `research_confidence = LOW`: downgrade to P2

**D-D3 [P2]:** Does the language read from a knowledgeable-local perspective or tourist-marketing perspective?
- Tourist-marketing flags: "paradise", "discover", "indulge", "luxury experience", "treat yourself"
- P2 only — soft flag

**Output:** Issue list + "Specificity: X generic / Y specific quality claims in description"

## Logging

After producing the review output above, append one JSONL entry per issue found to `operations/logs/content-review-errors.jsonl`. Log all three severity levels (P0, P1, P2) — do not skip P2 issues. Only omit a log entry if a check produced zero issues.

For each issue, run:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'content-reviewer-depth',
  'version': '1.0.0',
  'page_type': 'PAGE_TYPE_HERE',
  'page_slug': 'PAGE_SLUG_HERE',
  'cycle': 1,  # replace with actual cycle number as bare integer (no quotes)
  'dimension': 'Depth',
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
