> **Step 5/5** | ← requires: workflow/02-walk-journeys.md (all journeys complete)

# Deduplicate & Write Output

---

## Step 6: Deduplicate Findings

After all journeys are walked and `findings_raw` is fully populated:

### Deduplication Rule

Two findings may be merged when they share the **same `check` ID** AND one of:
- (a) the same element class name appears in both `dom_excerpt` values
- (b) the same route-independent component name is referenced in both `description` values

**When uncertain whether two findings share the same root cause, do NOT merge.** Keep them as separate findings and add a `possible_duplicate_of` field referencing the other finding ID.

### Deduplication Procedure

1. Group `findings_raw` by `check` ID.
2. Within each check group, identify findings with the same root cause using the rule above.
3. For each group of same-root-cause findings:
   - Keep the **first** finding as the canonical record.
   - Set `occurrences` to an array of all node IDs where the issue was observed (including the primary screen).
   - Set `journey` and `step` to the primary (first) occurrence's values.
   - Merge `console_errors` and `network_failures` across all occurrences (union, deduplicated).
   - Set `viewport` to `"both"` if the issue appeared at both viewports across occurrences.
   - Discard the duplicate finding records.
4. If a finding is unique (only one occurrence), keep `occurrences` as `["<screen-node-id>"]`.

### ID Reassignment

After deduplication, reassign IDs sequentially in severity order: all `high` findings first, then `medium`, then `low`. Number from `F001`.

---

## Step 7: Write Output

Write `audit-report.json` to `{output_dir}/audit-report.json`:

```json
{
  "generated": "<ISO 8601 timestamp>",
  "path_map_ref": "<absolute path to path-map.json>",
  "findings": [
    {
      "id": "F001",
      "journey": "deal-discovery",
      "step": 2,
      "screen": "oferta__123-unauth",
      "route": "/oferta/123",
      "check": "dead-end",
      "severity": "high",
      "description": "Deal detail page has no back link and no visible CTA after the deal expires.",
      "evidence": {
        "dom_excerpt": "<div class=\"deal-expired\"><p>Esta oferta ya no está disponible.</p></div>",
        "console_errors": [],
        "network_failures": [],
        "viewport": "1280px"
      },
      "occurrences": ["oferta__123-unauth", "oferta__456-unauth"],
      "classification_hint": "ux"
    }
  ],
  "summary": {
    "total": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "by_journey": {
      "<journey-id>": { "total": N, "high": N, "medium": N, "low": N }
    }
  }
}
```

### Building the Summary

Count deduplicated findings for `total`, `high`, `medium`, `low`.

For `by_journey`: enumerate all journey IDs from the input `path-map.json` journeys array and count findings where `findings[].journey` matches that journey ID. Include every journey from the input even if the count is 0.

### Overwrite Rule

If `audit-report.json` already exists in `output_dir`, **overwrite it** (this skill is idempotent).

If the output directory does not exist and the skill is running standalone, create it: `mkdir -p {output_dir}`.

---

## Final Summary

After writing, print:

```
Audit complete → {output_dir}/audit-report.json
  Findings:  N total (N high, N medium, N low)
  Journeys:  N audited
  Screens:   N walked
  Warnings:  N (list any WARN lines)
  By journey:
    deal-discovery:        N findings (N high)
    new-user-onboarding:   N findings
    ...
```
