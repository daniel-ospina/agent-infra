---
name: content-fact-checker-writing
version: 1.1.0
description: Use after the text reviewer cycle is clean, before final delivery. Cross-checks all factual claims in the written content against the verified research brief. No Perplexity calls — only cross-references against verified research. Returns issues in standard P0/P1/P2 reviewer format.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Fact Checker — Writing

> **Sync note:** Canonical copy at `agent-infra/skills/content-fact-checker-writing/SKILL.md`. Product repos hard-link into `operations/skills/content-fact-checker-writing/SKILL.md`; Pi reads via `~/.pi/agent/skills`. Edit the agent-infra copy only.

Cross-check the written content against the verified source to catch invented facts, hallucinated details, or claims that drifted during writing or revision cycles.

## Page Type

Receive `page_type` from the orchestrator: **"editorial"**, **"guide"**, **"deal"**, or **"refresh"**.

**If page_type = "deal":** Run deal DB cross-check (Steps D1–D5 below). The source of truth is the deal DB record, not a research brief. Skip the standard editorial/guide process.

**If page_type = "editorial" or "guide":** Run the standard process below.

**If page_type = "refresh":** Run the standard process below — refresh uses the same checks as editorial. Refresh content uses the same checks as editorial — this branch exists to make the routing explicit and prevent silent breakage if the editorial branch changes.

## When to Use

- After the text reviewer cycle exits clean (synthesis editor reports `is_clean: true`)
- Before final delivery

## Inputs Required

**For editorial/guide:**
- Final content (intro, body, FAQs, meta_title, meta_description — post-synthesis)
- Verified research brief (annotated output from `content-fact-checker-research`)
- Language (es/en)

**For deals:**
- Final content (title, title_es, seo_meta_title, seo_meta_title_es, seo_meta_description, seo_meta_description_es, seo_faq_json, description, description_es, how_to_book, how_to_book_es — post-synthesis)
- Deal DB record (`value_mechanism`, `access_conditions`, `business.name`, `category`)
- Language (es/en)

## Why Facts Drift

Facts can drift during writing and revision in several ways:

| Drift type | Example |
|---|---|
| Hallucinated detail | Writer says "open since 2010" — not in research brief |
| Superlative upgrade | Research says "popular" — writing says "best in Mexico" |
| Price fabrication | Research brief has no price — writing invents a range |
| Location drift | Research says "5th Ave area" — writing says "beachfront" |
| Partner confusion | Wrong specialty attributed to wrong business |
| Revision drift | A fix applied during reviewer cycle inadvertently changed a fact |

## Process

### Step 1: Extract claims from written content

Read the full content (intro, body, FAQs) and extract every specific factual claim:

- Business-specific: quality, vibe, specialty, price, location, features
- Statistical: counts, rankings, superlatives ("el mejor", "único", "más de X")
- Geographic: neighborhood, distance, zone descriptions
- Temporal: hours, seasons, best-time recommendations

### Step 1.5: Verify deal embed UUIDs (guide page type only)

**Skip this step if `page_type` is not "guide".**

Guide content may contain `<deal-embed deal-id="uuid">` tags that were valid at research time but may have expired before delivery. Before proceeding to Step 2, verify every embedded UUID is still active in the DB.

**1. Extract all deal embed UUIDs** from the content using this pattern:

```
<deal-embed deal-id="([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})">
```

If no `<deal-embed>` tags are found, note "No deal embeds found — Step 1.5 skipped" and proceed to Step 2.

**2. For each UUID found**, run a live DB lookup:

```bash
curl -sf \
  'https://axaeagulqhanatyoxrdv.supabase.co/rest/v1/deals_with_ontology?id=eq.UUID_HERE&status=eq.active&select=id,status' \
  -H 'apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4YWVhZ3VscWhhbmF0eW94cmR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk4ODAxMzgsImV4cCI6MjA4NTQ1NjEzOH0.8qrQ6wIBNvSI7yW8QHoF_2XcPWLAT8zQlcF8RsmaDRs' \
  -H 'Accept: application/json'
```

**3. Interpret results:**

| Result | Meaning | Action |
|---|---|---|
| Returns 1 row (`status = active`) | Deal is live | PASS — no issue |
| Returns 0 rows | UUID not found or deal inactive | Flag as FCE issue (P0) |

**4. Flag invalid UUIDs as P0 issues** using the `FCE` prefix (separate counter from FC issues in Steps 2–3):

```
FCE1 [P0] — <deal-embed deal-id="3f2a1b4c-..."> (body, section 2)
  Problem: UUID not found in deals_with_ontology with status=active — deal may be expired or deleted
  Fix: Remove the <deal-embed> tag or replace with a currently active deal UUID from the same category
```

- FCE issues are always P0 — an expired deal embed in published content is a broken user experience
- Include FCE issues in the P0 count in Step 4 output; log them with `check_id: FCEn` in the Logging section

### Step 2: Map each claim to the research brief

For each extracted claim, locate the supporting source in the verified research brief:

| Status | Meaning | Issue level |
|---|---|---|
| SUPPORTED | Claim appears in or is consistent with verified research | None |
| PLAUSIBLE | Not in brief but logically consistent with context | P2 |
| UNSUPPORTED | Specific claim with no basis in research brief | P1 |
| CONTRADICTS_RESEARCH | Claim contradicts a ✓ VERIFIED finding in the brief | P0 |

Map "~ UNVERIFIED" claims from the brief as potential UNSUPPORTED sources — treat carefully.

### Step 3: Build issues list

Format issues identically to the 5 text reviewers (P0/P1/P2, location, problem, fix):

```
FC1 [P0] — "El Camello es el único con acceso directo a la playa" (body, para 3)
  Problem: Brief (Step 0.5) notes 2 other beach-access options; fact-checker marked CONTRADICTED
  Fix: Remove "único" or qualify: "uno de los pocos con acceso directo"

FC2 [P1] — "precios desde $80 MXN" for La Lupita (body, para 5)
  Problem: Research brief contains no price data for La Lupita
  Fix: Remove price claim or replace with qualifier ("precios accesibles")

FC3 [P2] — "ambiente perfecto para niños" for Cenotes XYZ (FAQ #2)
  Problem: Research mentions family-friendly but "perfecto para niños" not confirmed
  Fix: Optional — consider qualifying or leave as editorial judgment
```

### Step 4: Output

```
## Writing Fact-Check Results

**Content:** [page path] ([language])
**Verified against:** Research brief (fact-checked, [date])

| Issue | Severity | Location | Problem | Fix |
|---|---|---|---|---|
| FC1 | P0 | ... | ... | ... |

**Summary:**
- P0 issues: X (block delivery)
- P1 issues: Y (should fix before delivery)
- P2 issues: Z (optional)

**Verdict:**
- ✓ CLEAN: No P0 or P1 issues — content passes fact-check, proceed to delivery
- ✗ NEEDS FIXES: [count] issues require correction before delivery
```

## Handling Issues Found

**The fact-check is a gate, not a one-shot check.** When issues are found, they are fed back to the writer for a fix cycle, then the fact-check runs again. This loop continues until the fact-checker returns 0 issues, then the gate opens.

**Refinement loop pattern:**
1. Run fact-check → get issues list
2. If issues > 0: feed issues + current content back to the writer for targeted fixes
3. Writer fixes ONLY the flagged claims — does not rewrite whole sections
4. Re-run fact-check on the revised content
5. Repeat until issues = 0 **or** max iterations reached (max 10 refinement rounds)

**After max iterations with remaining issues:**
- P0 issues remaining → gate stays closed; surface for human review before delivery
- Only P1/P2 remaining → P1s should be addressed; P2s are advisory (proceed with note)
- Do not silently drop content — always surface what remains

**Automated pipeline** (`generate-deal-content` edge function): The refinement loop runs automatically. The response includes `refinement_rounds` tracking iterations. P0 issues after max iterations block the write.

**Manual pipeline** (editorial/guide content agent): After this skill returns issues, the orchestrator routes back to the writer skill for targeted fixes, then re-dispatches this skill. The `content-synthesis-editor` `is_clean` signal controls the outer reviewer cycle; the fact-check loop runs independently within that.

**If only P2 issues:** Proceed to delivery. Note P2s in the delivery package for human consideration.

## What It Does NOT Do

- Does not call Perplexity — relies entirely on the already-verified research brief (or deal DB record for deals)
- Does not re-check SEO/disclosure/commercial alignment (text reviewers cover this)
- Does not re-run the text reviewer cycle — fact accuracy only
- Does not verify subjective editorial language ("romántico", "animado") — only objective claims

---

## Deal Mode Process (page_type = "deal" only)

When `page_type = "deal"`, skip Steps 1–4 above. Run these 4 checks against the deal DB record.

### Step D1: Discount amount matches value_mechanism

- Extract the discount amount/type stated in `title` and `title_es`
- Compare against `value_mechanism` in the DB record
- P0 if the percentage, ratio, or discount type conflicts with the DB value

### Step D2: Business name matches DB

- Extract the business name as written in `title` and `title_es`
- Compare against `business.name` in the DB record
- P0 if a different name is used (common drift: informal nickname vs. registered name)

### Step D3: Access condition framing matches DB

- Check `access_conditions` in the DB record
- If `EVERYONE`: title must NOT include "for Locals" / "para Locales" — P0 if present
- If any other value: title must include "for Locals" (EN) or "para Locales" (ES) — P0 if absent
- P1 if the access framing is ambiguous without being technically wrong
- **Note:** This mirrors DT5 in `content-reviewer-seo-geo` (which is P1 there). The escalation to P0 here is intentional — any unresolved access framing error that survived the reviewer cycle is a delivery blocker at this stage.

### Step D4: No invented details in description or how_to_book

- Scan `description` / `description_es` and `how_to_book` / `how_to_book_es` for specific claims not in the deal DB record (invented prices, invented hours, invented locations, invented conditions)
- P1 per invented specific claim
- Note: gated fields allow full detail — check only that details are grounded in the DB record, not invented

### Step D5: Meta Field Accuracy

Scan `seo_meta_title` / `seo_meta_title_es` and `seo_meta_description` / `seo_meta_description_es` (skip if NULL/empty):

- Extract the discount amount/type stated in `seo_meta_title` and compare against `value_mechanism` in the DB record — P0 if the percentage or type conflicts
- Verify `seo_meta_title` ≤60 chars — P1 if over limit
- Verify `seo_meta_description` 130–155 chars — P1 if outside range
- Verify `seo_meta_description` contains a CTA verb — P1 if absent
- Verify no gated data present in either meta field — P0 if specific ID types or exact MXN amounts found

### Deal Mode Output

```
## Deal Fact-Check Results

**Deal:** [business.name] ([language])
**Verified against:** Deal DB record

| Check | Status | Issue |
|---|---|---|
| D1: Discount vs value_mechanism | PASS / FAIL | [detail if fail] |
| D2: Business name | PASS / FAIL | [detail if fail] |
| D3: Access condition framing | PASS / FAIL | [detail if fail] |
| D4: Invented details | PASS / FAIL | [detail if fail] |
| D5: Meta field accuracy | PASS / FAIL | [detail if fail] |

**Summary:**
- P0 issues: X (block delivery)
- P1 issues: Y (should fix before delivery)

**Verdict:**
- ✓ CLEAN: All checks pass — proceed to delivery
- ✗ NEEDS FIXES: [count] issues require correction
```

## Logging

After producing the review output above, append one JSONL entry per issue found to `operations/logs/content-review-errors.jsonl`. Skip categories that had no issues — only log actual issues.

For each issue, run:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'content-fact-checker-writing',
  'version': '1.1.0',  # matches frontmatter version
  'page_type': 'PAGE_TYPE_HERE',
  'page_slug': 'PAGE_SLUG_HERE',
  'cycle': 1,  # replace with actual cycle number as bare integer (no quotes)
  'dimension': 'FactCheck',
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
