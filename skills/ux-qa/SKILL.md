---
name: ux-qa
description: "Meta-orchestrator for end-to-end UX QA runs. Dispatches ux-path-mapper, ux-path-auditor, and ux-problem-triage in sequence, manages the human review gate for UX issues, and creates GitHub issues for all actionable findings."
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Sync note:** Local copy at `~/.claude/skills/ux-qa/SKILL.md`. Repo copy at `operations/skills/ux-qa/SKILL.md`. Keep in sync.

# UX QA — Meta-Orchestrator

## Purpose

Run a complete UX QA session against the live El Dato app. Orchestrates three sub-skills in sequence, manages artifact handoff between phases via JSON files on disk, gates UX design decisions with human review, and produces GitHub issues for every actionable finding.

Invoke with `/ux-qa [scope]`. Scope is optional; if omitted the full app is audited.

---

## Sub-Skills

| Skill | Phase | Produces |
|---|---|---|
| `ux-path-mapper` | Phase 2 | `path-map.json` |
| `ux-path-auditor` | Phase 3 | `audit-report.json` |
| `ux-problem-triage` | Phase 4 | `ux-issues.json`, `tech-issues.json` |
| `issue-creation` | Phase 6 | GitHub issues |
| `question-format` | Phases 2, 5 | Structured human-input prompts |

---

## Input

```
/ux-qa [scope]
```

| Argument | Description |
|---|---|
| _(empty)_ | Full app audit — scope slug: `full` |
| Route prefix (e.g. `/mi-negocio`) | Audit routes under that prefix — scope slug: `mi-negocio` |
| Journey name (e.g. `deal-discovery`) | Audit that named journey — scope slug: `deal-discovery` |

---

## Run Directory

All artifacts for a run live in:

```
docs/ux-qa/YYYY-MM-DD-<scope-slug>/
```

Example: `docs/ux-qa/2026-03-23-full/`

Files written during the run:
- `path-map.json` — Phase 2 output
- `audit-report.json` — Phase 3 output
- `ux-issues.json` — Phase 4 output
- `tech-issues.json` — Phase 4 output

---

## Human-Input Taxonomy

This skill pauses for human input when a UX finding requires a design decision:

1. **High-severity UX issues** — present options + recommendation, wait for approval (Phase 5, Pass A)
2. **Journey confirmation** — after path mapping, confirm scope before auditing (Phase 2)
3. **Medium/low UX issue batch** — batched multi-select gate before issue creation (Phase 5, Pass B)

All other decisions (tech issue creation) proceed autonomously.

Tie-breaking rule: when uncertain if a finding needs human input, treat it as taxonomy match (pause).

---

## Phases

### Phase 1 — Setup

1. Parse the scope argument:
   - Empty → scope = `"full"`, scope-slug = `full`
   - Route prefix → strip leading `/`, replace `/` with `-` for slug (e.g. `/mi-negocio` → `mi-negocio`)
   - Journey name → use as-is for slug (e.g. `deal-discovery` → `deal-discovery`)
2. Determine today's date in `YYYY-MM-DD` format.
3. Set `run_dir = docs/ux-qa/YYYY-MM-DD-<scope-slug>/`
4. Run `mkdir -p <run_dir>` via Bash.
5. Announce:
   ```
   📡 Starting UX QA run — scope: [scope] — artifacts: [run_dir]
   ```
6. **Resumability check:** If `path-map.json` already exists in `run_dir`, check what other artifacts are present, then ask:
   - Both `path-map.json` and `audit-report.json` exist → offer three options:
     1. Resume from Phase 4 (skip mapping + auditing — use existing artifacts)
     2. Resume from Phase 3 (re-run audit only — re-use path map, redo audit)
     3. Restart from Phase 2 (full re-run)
   - Only `path-map.json` exists (auditor did not complete) → offer two options:
     1. Resume from Phase 3 (re-run audit using existing path map)
     2. Restart from Phase 2 (full re-run)
   - On any resume path: load only the artifacts that exist and are needed for the chosen start phase.

---

### Phase 2 — Path Mapping

Invoke `ux-path-mapper` with:

```
entry_points: (all default entry points if scope=full; filtered to scope prefix otherwise)
auth_states: ["unauth", "auth"]
depth: 4
output_dir: [run_dir]
```

When `ux-path-mapper` completes, read `[run_dir]/path-map.json` and print a journey summary:

```
Path map complete:
  Screens:          N (N unauth + N auth)
  Journeys:         N — [journey-id, journey-id, ...]
  Edges:            N
  Skipped patterns: N
```

**Checkpoint — journey confirmation (human gate):**

Present the journey list via `question-format` / asking the user directly:

- Context: path map is complete, list each journey with its ID and a one-line description (derive from journey nodes)
- Question: proceed with all journeys, skip named journeys, or abort?
- Options:
  1. Proceed with all journeys (recommended)
  2. Skip specific journeys — user names them
  3. Abort run

Wait for response before proceeding.

- If proceed with all → continue to Phase 3 with full `path-map.json`
- If skip → write a filtered copy `[run_dir]/path-map-filtered.json` that excludes the named journeys (remove their nodes and edges from the JSON), then use `path-map-filtered.json` as the input to Phase 3. Note which journeys were skipped in the run summary.
- If abort → print `UX QA run aborted by user.` and stop

---

### Phase 3 — Audit

Pass `path-map-filtered.json` if it exists (user skipped journeys in Phase 2), otherwise pass `path-map.json`. Invoke `ux-path-auditor` with:

```
path_map: [run_dir]/path-map-filtered.json   (if journeys were skipped in Phase 2)
          [run_dir]/path-map.json             (if all journeys were kept)
output_dir: [run_dir]
```

When `ux-path-auditor` completes, read `[run_dir]/audit-report.json` and print:

```
Audit complete:
  Findings: N (N high, N medium, N low)
  By journey: [journey-id: N findings, ...]
  (filtered: N journeys skipped)   ← include only if journeys were skipped in Phase 2
```

---

### Phase 4 — Triage

Invoke `ux-problem-triage` with:

```
audit_report: [run_dir]/audit-report.json
output_dir: [run_dir]
```

When `ux-problem-triage` completes, announce:

```
Triage complete:
  UX issues (human review): N
  Tech issues (auto-create): N
  Dual-classified:           N
```

Dual-classified issues (both UX and tech) are treated as UX issues in Phase 5 — they receive human review before issue creation.

---

### Phase 5 — Human Review (UX Issues)

Read `[run_dir]/ux-issues.json`. Process issues in two passes.

#### Pass A — High-severity UX issues (one at a time)

For each high-severity UX issue:

1. Research comparable patterns via Perplexity:
   > How do similar consumer-facing deal/coupon apps handle [this UX problem]? What are the established patterns?
2. Derive 2–3 concrete solution options with trade-offs.
3. Invoke the `question-format` skill, then present via asking the user directly with:

   **Context block:**
   - What the problem is
   - Affected route(s)
   - Evidence summary (from audit finding)

   **Scope & Impact block:**
   - What would change to fix it
   - All affected routes

   **Options block:**
   - Option 1 (recommended): description + trade-offs
   - Option 2: description + trade-offs
   - Option 3 (if applicable): description + trade-offs
   - Option 4: "Research more before deciding"

   **Recommendation block:**
   - Which option + one-sentence rationale

4. Wait for user selection.
5. Record: `{ issue_id, approved_option, option_description }` — this becomes the issue spec for Phase 6.
6. If user selects "Research more" → run additional Perplexity queries and re-present with expanded options. Do not proceed until user makes a concrete selection.
7. If user declines to create an issue → mark as `skipped`, count toward Skipped total in Phase 7.

#### Pass B — Medium and low-severity UX issues (batched)

Invoke the `question-format` skill for the batch presentation. Present all medium/low UX issues as a single asking the user directly:

- Context: N medium/low severity UX issues found, list each with: title, severity, affected route
- Question: select which ones to create GitHub issues for; unselected = skip
- Present as a numbered list; user can say "all", "none", or list numbers

For selected issues: use triage description as issue spec (no per-issue options).
For unselected issues: mark as `skipped`.

---

### Phase 6 — Issue Creation

Invoke `issue-creation` skill once per issue — loop over all approved UX issues first, then all tech issues from `tech-issues.json`. Collect each created issue number as you go.

For each issue, invoke `issue-creation` with:

- **Title:** from triage JSON `title` field
- **Description:** structured body including:
  - Finding evidence (from audit report)
  - Affected route(s)
  - Classification (`ux` or `tech` or `dual`)
  - Approved option description (for UX issues only)
  - Link to run artifact: `docs/ux-qa/[run_dir]/`
- **Labels:**
  - UX issues: `ux` + severity label (`priority:high`, `priority:medium`, or `priority:low`)
  - Tech issues: `bug` + severity label
  - Dual-classified: `ux`, `bug` + severity label
- **No epic inheritance** — these are standalone QA issues

Collect all created issue numbers as they are returned. Track separately: UX issue numbers and tech issue numbers.

---

### Phase 7 — Delivery

Print the final run summary:

```
UX QA run complete — docs/ux-qa/YYYY-MM-DD-<scope>/
  Screens mapped:    N
  Findings total:    N (N high, N medium, N low)
  Issues created:    N
    UX issues:       #NNN, #NNN, ...
    Tech issues:     #NNN, #NNN, ...
  Skipped:           N (user declined)
```

If no issues were created (e.g. scope had no findings): print `No actionable findings for scope: [scope].`

### Implementing QA Issues

To implement any issues created by this run:

1. Run `issue-scoping` on the issue to produce a scoping plan with requirements, scope, and approach.
2. Then run `writing-plans` for the detailed implementation plan.
3. Then run `executing-plans` (or `subagent-driven-development` for smaller issues) to implement.

This is the same development pipeline used for all issues (`issue-creation` → `issue-scoping` → `writing-plans` → `execute`).

---

## Progressive Artifact Protocol

Each phase reads the previous phase's JSON output from disk before starting. Never pass in-memory data between phases — always write to disk and read from disk. This ensures:

1. Resumability — a run can be resumed from any phase
2. Debuggability — artifacts are inspectable at any point
3. Sub-skill isolation — sub-skills are self-contained

Disk read/write pattern:
- Before invoking a sub-skill: confirm the input file exists (error out clearly if not)
- After a sub-skill completes: read the output file to verify it was written before printing the summary
- If a sub-skill fails to produce its output file: surface the error to the user and offer to retry or abort

---

## Announce Line

At invocation, print:

```
I'm using the ux-qa skill to run a UX QA session. Pi uses DeepSeek v4 Pro by default. For complex UI review, dispatch sub-agents via the task tool.
Scope: [scope] | Run dir: [run_dir]
```
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
