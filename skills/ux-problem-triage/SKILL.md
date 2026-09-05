---
name: ux-problem-triage
description: "Reads audit-report.json produced by ux-path-auditor, classifies each finding as UX-change-required or tech-change-required using a structured rule table, and writes ux-issues.json and tech-issues.json for the ux-qa orchestrator"
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Sync note:** Canonical copy at `agent-infra/skills/ux-problem-triage/SKILL.md`. Product repos hard-link into `operations/skills/ux-problem-triage/SKILL.md`; Pi reads via `~/.pi/agent/skills`. Edit the agent-infra copy only.

# UX Problem Triage

## Purpose

Read `audit-report.json` (produced by `ux-path-auditor`), classify each finding as either **UX-change-required** or **tech-change-required**, generate human-readable issue records from each finding, and write `ux-issues.json` and `tech-issues.json`. These two output files are consumed by the `ux-qa` orchestrator (Phase 5) to create GitHub issues.

This skill does not browse the app and does not use Playwright. It works entirely with JSON files on disk.

---

## Inputs

You will receive these parameters when invoked:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `audit_report` | string | yes | Absolute or repo-relative path to `audit-report.json` produced by `ux-path-auditor` |
| `output_dir` | string | yes | Directory path to write `ux-issues.json` and `tech-issues.json` |

The `output_dir` is always an absolute path or relative to the repo root. The output directory is pre-created by the `ux-qa` orchestrator. If running standalone, create it: `mkdir -p {output_dir}`.

---

## Step-by-Step Process

### Step 0: Initialization

1. Read and parse `audit-report.json` from the `audit_report` path.
2. Validate that the file contains a `findings` array. If missing or unparseable, halt with:
   ```
   BLOCKED: audit-report.json at {path} is missing required field: findings. Re-run ux-path-auditor first.
   ```
3. If `findings` is an empty array, write both output files with empty `issues` arrays, print the completion summary, and exit — this is a valid zero-finding run.
4. Announce: `Starting UX problem triage — {N} findings to classify`

---

### Step 1: Classify Each Finding

For each finding in `findings`, apply the classification rules below to assign a `classification` of `"ux"` or `"tech"`.

#### Primary Classification Rules

| Signal | Classification |
|---|---|
| Missing or wrong copy, label, or heading | `ux` |
| Layout problem, hierarchy issue, or missing navigation element | `ux` |
| Inconsistent visual or interaction pattern | `ux` |
| Dead end — no obvious back or continue path | `ux` |
| Missing empty state or loading state where the absence is a design decision | `ux` |
| JS console error (present in `evidence.console_errors`) | `tech` |
| Network 4xx or 5xx (present in `evidence.network_failures`) | `tech` |
| Form submit not triggering validation logic | `tech` |
| Missing empty state where the component receives data but fails to render it | `tech` |
| Auth-gated content without signal | Start as `ux` (design problem). Additionally check: if `evidence.console_errors` or `evidence.network_failures` are non-empty, create a **second issue** classified as `tech` for the same finding. Both issues reference the same `finding_id`. |

#### Using `classification_hint`

Each finding carries a `classification_hint` field (`"ux"`, `"tech"`, or `"ambiguous"`) set by `ux-path-auditor`. Use it as a starting point, but apply the rule table above to override it when the evidence points clearly to a different classification.

Override cases:
- If `classification_hint` is `"ux"` but `evidence.console_errors` or `evidence.network_failures` are non-empty → reclassify as `tech`. **Exception:** when the finding `check` is `"auth-signal-missing"` AND errors are present, do NOT apply this override — apply the dual-issue rule instead (one `ux` issue for the missing auth signal, one `tech` issue for the underlying error). See the [Dual Classification section](#dual-classification-auth-signal-missing) below.
- If `classification_hint` is `"tech"` but evidence contains no errors and only layout/copy symptoms → reclassify as `ux`.
- If `classification_hint` is `"ambiguous"` → apply the rule table. If still unclear after applying the table → apply the ambiguity tie-breaker below.

#### Ambiguity Tie-Breaker

When the rule table does not yield a clear classification and the hint is `"ambiguous"`:

**Classify as `ux`.**

Human judgment on a UX issue is cheaper than silently skipping a real problem. A false `ux` classification surfaces to a human who can redirect it. A false `tech` classification may disappear into a backlog without UX attention.

---

### Step 2: Generate Issue Records

For each classified finding, generate one issue record (or two, in the auth-signal case described above) using the structure below.

#### Issue Record Structure

```json
{
  "finding_id": "F001",
  "title": "Concise issue title under 60 chars",
  "description": "What the problem is and the supporting evidence.",
  "severity": "high | medium | low",
  "affected_routes": ["/path"],
  "evidence_summary": "One-sentence summary of the key evidence.",
  "classification": "ux | tech",
  "suggested_scope": "Single component | Route | System-wide"
}
```

#### Title Generation Rules

Titles must be:

- **Under 60 characters** — count carefully; trim if needed.
- **Action-oriented** — start with a verb or a noun describing the gap, never with "Issue:", "Bug:", or "Finding:".
- **Route-contextual** — include the route or page name so the reader knows where this occurs without opening the full description. Use the human-readable route (e.g. `/oferta/:id`) not the node ID (e.g. `oferta__123-auth`).
- **Plain language** — no jargon, no check IDs. Write for a product designer or developer who hasn't read the audit.

Good examples:
- `Dead end on /oferta/:id after deal expires`
- `Missing back navigation on mobile /categoria`
- `Login required signal absent on /mi-cuenta`
- `Form submits without validation on /registro`
- `JS error crashing /dashboard on load`
- `Mixed Spanish/English labels on /buscar results`

Bad examples (do not generate titles like these):
- `dead-end check failure on node oferta__123-auth` — uses check ID and node ID
- `Issue: missing empty state` — starts with "Issue:", no route context
- `UX problem found during audit on the deal detail page at the path /oferta/:id` — over 60 chars, verbose
- `Form validation gap` — no route context, not action-oriented

When the same finding affects multiple routes (via `occurrences`), use the primary route from the finding's `route` field. If there are 2–3 affected routes, you may append `(+2 routes)` after the primary route — only if the title still fits within 60 characters.

#### Description Generation Rules

The description field is a paragraph (2–4 sentences) covering:
1. What the problem is and where it appears.
2. What the user experiences as a result.
3. Key evidence: which console errors, network failures, or DOM patterns were observed.

Do not repeat the title verbatim. Write prose, not bullet points. Keep it under 200 words.

Example:
> The deal detail page at `/oferta/:id` has no back link and no visible CTA when the deal has expired. A user who lands on this page via a shared link has no way to navigate to other deals or back to the category listing. No console errors or network failures were observed — the issue is purely a missing navigation affordance in the expired-deal state.

#### Evidence Summary Rules

One sentence only. Summarize the most diagnostic piece of evidence. Examples:
- `DOM shows no CTA or back-navigation element in the expired-deal state.`
- `console_errors: ["Uncaught TypeError: Cannot read property 'id' of undefined"]`
- `network_failures: [GET /api/deals/123 → 404]`
- `Accessibility tree shows 3 icon-only buttons with no aria-label.`

#### Suggested Scope Rules

Assign one of three values based on where the fix needs to happen:

| Value | When to use |
|---|---|
| `Single component` | Fix is isolated to one UI component or one function — the problem does not recur across routes |
| `Route` | Fix requires changes across the entire page/route (layout, data loading, auth guard) but is confined to one route |
| `System-wide` | Same root cause appears in `occurrences` across 3+ distinct routes, OR the fix requires a global pattern change (e.g. a shared component, a global CSS rule, an auth middleware) |

Use the `occurrences` array length and the `check` ID to inform this judgment. A `copy-inconsistency` finding with 1 occurrence is `Single component`. The same check with occurrences on 5 routes is `System-wide`. A `broken-nav` on one route due to a missing route guard is `Route`.

---

### Step 3: Split Into Output Lists

After generating all issue records:

1. Partition records into two lists:
   - `ux_issues`: all records with `classification: "ux"`
   - `tech_issues`: all records with `classification: "tech"`

2. Within each list, sort by severity: `high` first, then `medium`, then `low`. Within the same severity, preserve the original finding order from `audit-report.json`.

---

### Step 4: Write Output Files

Write both files to `output_dir`.

#### `ux-issues.json`

```json
{
  "generated": "<ISO 8601 timestamp>",
  "audit_report_ref": "<absolute path to audit-report.json>",
  "issues": [
    {
      "finding_id": "F001",
      "title": "Dead end on /oferta/:id after deal expires",
      "description": "The deal detail page at /oferta/:id has no back link or CTA when a deal has expired. A user who lands via a shared link has no path forward or back. No console errors or network failures were observed — the issue is a missing navigation affordance in the expired-deal state.",
      "severity": "high",
      "affected_routes": ["/oferta/:id"],
      "evidence_summary": "DOM shows no CTA or back-navigation element in the expired-deal container.",
      "classification": "ux",
      "suggested_scope": "Single component"
    }
  ]
}
```

#### `tech-issues.json`

Same structure as `ux-issues.json`, with `classification: "tech"` records.

If a list is empty, write the file with `"issues": []` — do not skip writing the file.

---

### Step 5: Print Completion Summary

After writing both files, print:

```
Triage complete
  Input:       {N} findings from audit-report.json
  UX issues:   {N} → {output_dir}/ux-issues.json  (N high, N medium, N low)
  Tech issues: {N} → {output_dir}/tech-issues.json (N high, N medium, N low)
  Dual-classified (auth-signal): {N} findings produced both a UX and Tech issue
```

---

## Dual Classification: Auth-Signal-Missing

The `auth-signal-missing` check may warrant two issues from a single finding — one UX and one Tech — when both conditions are true:

1. The finding `check` is `"auth-signal-missing"`.
2. `evidence.console_errors` or `evidence.network_failures` are non-empty.

When this applies:
- Generate a `ux` issue: title focuses on the missing design signal (e.g. `Login required signal absent on /mi-cuenta`).
- Generate a `tech` issue: title focuses on the underlying error (e.g. `JS error on /mi-cuenta when unauthenticated`).
- Both records share the same `finding_id`.
- Count this finding once in the input count and once each in the respective output lists.
- Derive `suggested_scope` independently for each issue — the UX issue scope is based on design impact (usually `Route`), the Tech issue scope is based on the underlying error's spread (check `occurrences` array length).

When only one condition is true (evidence is empty OR check is not `auth-signal-missing`), generate a single issue using the standard classification rules.

---

## Error Handling

| Situation | Action |
|---|---|
| `audit-report.json` is missing or unreadable | Halt with BLOCKED message (see Step 0) |
| `findings` field is present but not an array | Halt with: `BLOCKED: audit-report.json findings field is not an array. File may be corrupted.` |
| A finding is missing required fields (`id`, `check`, `severity`, `route`) | Log `WARN: skipping finding {id or index} — missing required field(s): {list}` and continue |
| A finding has an unrecognized `check` ID | Apply the rule table based on available evidence and `classification_hint`; do not halt |
| Output directory does not exist | Create it: `mkdir -p {output_dir}`. Do not halt. |
| Both output files already exist in `output_dir` | Overwrite them — this skill is idempotent |

---

## Standalone Invocation

When invoked directly (not by `ux-qa`), accept arguments in this format:

```
/ux-problem-triage audit_report=docs/ux-qa/2026-03-22-full/audit-report.json output_dir=docs/ux-qa/2026-03-22-full/
```

If `audit_report` is not provided, halt with:
```
BLOCKED: audit_report parameter is required. Provide the path to an audit-report.json file.
Example: /ux-problem-triage audit_report=docs/ux-qa/2026-03-22-full/audit-report.json output_dir=docs/ux-qa/2026-03-22-full/
```

If `output_dir` is not provided, default to the same directory as the `audit_report` file.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
