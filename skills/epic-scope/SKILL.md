---
disable-model-invocation: true
name: epic-scope
description: "Bounded skill for epic scoping. Takes strategy decision + research brief and produces scoped boundaries, high-level E2E test cases (BEFORE user journeys), and complexity ratings. Includes review gate with fresh-context reviewer. Invoked by epic-plan after research."
domain: planning
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

# Epic Scoping

**Announce at start:** "I'm using the epic-scope skill for boundary definition."

## Purpose

Bounded skill that defines what the epic includes and excludes. Takes the strategy decision (`epic-align`) and research brief (`epic-research`) and produces scoped boundaries with high-level E2E test cases — written BEFORE user journeys, not after.

## Workflow

### Step 0 — Granular Axis Research (issue #231 D11)

When the research brief is **too broad for boundary decisions** (a complexity axis **expected to rate `medium+`** — preliminary assessment performed here, formalized in Step 3 below; the Review Gate validates the final ratings against the `### Axis Research Notes` output), fire granular per-axis queries — canonical / competitor-precedent / pitfalls framing, ≤ 4 total, deduped against the brief (deduplicated questions never count). Output `### Axis Research Notes` in the scope doc with a `> **Findings date:**` stamp + provenance, and append each finding to the epic brief's `## Raw Notes` via `bash scripts/_research_append.sh --epic-path <brief-path> --append "<text>" --source-tag <framing>`. Under `EXECUTION_INTENT=Budget`: defer to the brief (zero external queries). The Review Gate (below) checks `### Axis Research Notes` present-or-justified-skip for each final `medium+` axis (justified = cited brief section).

> **Disambiguation:** `### Axis Research Notes` (epic tier, scope doc) is distinct from issue-scoping's `### Axis Research` (issue tier, issue comment — D5 artifact) — different levels, never merge.

### Step 1 — Scope Boundaries

Define what is IN and OUT of scope:

```markdown
## Scope Boundaries

### In Scope
- <concrete deliverable 1>
- <concrete deliverable 2>

### Out of Scope
- <explicitly excluded 1> — defer to <future epic/issue>
- <explicitly excluded 2> — defer to <future epic/issue>

### Boundary Rationale
<why these boundaries — what principle guides the cut>
```

### Step 2 — Map End-to-End Customer Value

**Before scope converges**, enumerate the user-visible value each scoped capability delivers. One line per capability — what the end user gets, not what the system does internally. This anchors the boundary cut to outcomes and feeds the test-design gate downstream (integration surfaces are mapped from these capabilities).

```markdown
## Customer Value Map

| Scoped Capability | User-Visible Value |
|-------------------|--------------------|
| <capability from In Scope> | <one line: what the user can now do / pain removed> |
```

Rules:
- **One line per capability.** If you can't state the value in one line, the capability is either not understood or not user-visible — reconsider its place in scope.
- **User-visible only.** Outcomes, not internals ("merchant can approve a payout in 2 taps", not "add payout ORM layer").
- **Complete coverage.** Every In Scope item appears; Out of Scope items do not.
- **Output lives in the scope doc**, appended directly under Scope Boundaries.

### Step 3 — Complexity Ratings

Rate each complexity axis per the standard 3-tier system:

| Axis | Rating | Rationale |
|------|--------|-----------|
| UX | low/medium/high | <1 sentence> |
| Architecture | low/medium/high | <1 sentence> |
| Ontology | low/medium/high | <1 sentence> |
| Accessibility | low/medium/high | <1 sentence> |

### Step 4 — High-Level E2E Test Cases

**CRITICAL:** Write these BEFORE user journeys are drafted. High-level E2E tests describe what the app must do end-to-end — not how, not with specific UI elements.

Each test case format:

```markdown
### E2E-<N>: <short title>
**Given:** <precondition state>
**When:** <trigger action>
**Then:** <expected outcome 1>
**And:** <expected outcome 2>
```

Aim for 3-8 test cases that cover the full scope. These anchor the detailed E2E tests written later in `epic-plan`.

### Step 5 — Human Approval Gate

**HARD STOP.** Present the scope boundaries + high-level E2E tests:

```
## Epic Scope Ready for Review

**Scope:** <in/out summary>
**Customer value map:** <count> capabilities mapped
**E2E test cases:** <count> drafted
**Complexity:** <ratings>

Review the scope boundaries, customer value map, and E2E test cases.
Reply "proceed" to continue to detailed planning, or give feedback.
```

Do NOT proceed until user confirms.

## Review Gate

After human approval, dispatch a fresh-context reviewer via `task` sub-agent:

```
Review this epic scope for:

1. BOUNDARY COMPLETENESS: Are in-scope items concrete and verifiable? Are out-of-scope items explicitly deferred?
2. VALUE MAPPING: Does every in-scope item have a one-line user-visible value statement? Is any capability justified only by internal convenience ("easier for us") rather than user value?
3. E2E COVERAGE: Do the high-level test cases cover all in-scope items? Any gaps?
4. E2E TESTABILITY: Can each test case be verified without knowing UI details? (Should be behavioral, not presentational)
5. COMPLEXITY HONESTY: Are complexity ratings justified by the scope and research?
6. RESEARCH CHECK (issue #231 D11): For each complexity axis rated `medium+`, is `### Axis Research Notes` present in the scope doc, OR a justified skip (cited brief section covering the boundary question at sufficient granularity)?

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until "NO ISSUES FOUND" or convergence; safety cap: 10 cycles.

### Duplication & Architecture Reviewer (#688) — controller dispatch

After the scope reviewer above is clean, the **controller** (not the reviewer) dispatches a **second, separate** `task` sub-agent. This is a second dispatch, not a dimension of the first — the scope reviewer has no `task` tool and must not be told to nest one.

⚠️ **Run this check under a distinct heading in the gate report.** Both reviewers return `NO ISSUES FOUND`; a bare token from the duplication reviewer out of context reads as the scope gate passing.

```
Read skills/reviewers/duplication-architecture/SKILL.md IN FULL — the file is the
specification, not this prompt. Then run both halves against the epic scope:

DUPLICATION (D1–D9): does this epic duplicate a capability, a write path into
state we already write, a vocabulary defined elsewhere, or a pattern already in
the repo? Note explicitly that improvement-opportunities IO3 asks the same class
of question at epic-Coherence-Review time — state what this check adds beyond it.
ARCHITECTURE (A1–A6): is the WHOLE still coherent once this lands?

REQUIRED OUTPUT — use the skill's own output block verbatim, including its
Evidence / Writers / Shared contract / Verdict lines. Do not invent a shorter
schema; the gate parser reads the skill's field names.
A finding that is incomplete by the skill's own definition is an open issue.

VERDICT (three-valued, on every duplication finding — not just D2/D5):
  unify | keep separate | unify-contract-keep-drivers

ADVISORY, never blocking — but see the disposition rule below.
Tortoise is ONE source among several, never the only one. If a source was
checked and found stale/unreachable, the finding is DEGRADED and must report
which source was unavailable. A DEGRADED result is not a clean pass.

Return the skill's summary block, then:
  NO ISSUES FOUND — CLEAN
  or  NO ISSUES FOUND — DEGRADED (<source> unavailable)
  or  ISSUES: <list using the skill's output block>
```

**Disposition (this is what keeps it advisory without creating a spin loop):**

| Result | Action |
|---|---|
| `CLEAN` | Record the verdict in the scope doc. Proceed. |
| `DEGRADED` | Record + name the unavailable source. **Do not** treat as clean, **do not** block. Proceed with the caveat carried into the scope doc. |
| `ISSUES` with a verdict | Record each verdict in the scope doc. `unify` → fold into the boundary decision. `keep separate` / `unify-contract-keep-drivers` → record the reason; an unjustified `keep separate` is a scope item, not a pass. |
| `ISSUES` with **no** verdict | Not a valid result. Re-dispatch once; if it repeats, record `⚠️ reviewer returned unverdict findings` and proceed. |

**This reviewer never fails the gate and never enters the 10-cycle fix-loop above.** P0 here is advisory severity, not blocking severity — record it and proceed. Concretely: do not re-dispatch the *scope* reviewer because the duplication reviewer found something, and do not hold the gate open on it.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Scope boundaries | Feature creep — "while we're at it" additions without explicit decisions |
| Customer value map | Scope converges on capabilities nobody can state the value of — downstream test-design and acceptance criteria drift to implementation details instead of user outcomes |
| High-level E2E tests | User journeys designed without testable outcomes — detailed tests discover missing flows too late |
| Human approval gate | User sees full epic plan and wants changes — rework cascades through all downstream phases |
| Complexity ratings | Downstream phases don't scale review gates correctly |

## Integration

**Called by:** `epic-plan` (pipeline step 3, after `epic-research`)
**Hands off to:** `epic-plan` (detailed planning phase)
**Input:** Strategy decision (`epic-align`) + research brief (`epic-research`)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
