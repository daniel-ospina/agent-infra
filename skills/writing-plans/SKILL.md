---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code. Assumes requirements, priorities, and needs are already captured by `issue-scoping`. Focuses on design decisions and implementation steps.
domain: engineering
allowed-tools: read write edit bash web_search web_fetch todo_write task grep find
steps:
  - name: read_workflow_files
    type: skill
    gate: auto
  - name: prerequisite_check
    type: skill
    gate: auto
    requires: [read_workflow_files]
  - name: ux_design_gate
    type: skill
    gate: auto
    requires: [prerequisite_check]
  - name: research_intake
    type: skill
    gate: auto
    requires: [ux_design_gate]
  - name: integration_surface
    type: skill
    gate: auto
    requires: [research_intake]
  - name: parallel_check_plan
    type: gate
    gate: checkpoint
    token_phase: plan
    requires: [integration_surface]
    # #4907: run `parallel_work_check plan` (C3) — CLEAR verdict writes the
    # PASS token; fail-closed gate blocks until fresh. Set CHECKOUT_GUARD_ENFORCE=1.
  - name: draft_implementation_plan
    type: skill
    gate: auto
    requires: [parallel_check_plan]
  - name: plan_review
    type: parallel
    gate: verifier
    requires: [draft_implementation_plan]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

# Writing Plans

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

> ⛔ **This file is an index — it describes WHAT the skill does, not HOW to execute it.**
> The actual workflow with mandatory quality gates (pre-flight checks, code review, migration safety, verification) is in the workflow/*.md files below.
> **Why:** This skill gates operations that mutate production state or bypass quality checks. Skipping the workflow files means those gates are silently skipped — commits may bypass tests, PRs may lack review, migrations may deploy unsafely.
> **What to do:** Read every file listed under "What you are missing" below before performing any operation this skill covers.

### Skip Rules

**Skip the research intake gate (`workflow/02`) entirely when:**
- The plan touches **zero third-party dependencies** — Node stdlib only, type-only imports, or in-repo wrappers used 2+ times.
- Proceed directly to `workflow/03-integration-surface.md`.

**Skip the integration surface map (`workflow/03`) when:**
- The plan has **no integration boundaries** — pure logic, pure config, documentation, or i18n changes.

These skip rules save ~5 min of file traversal when the gate would produce zero research queries.

## Research Discipline

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md). Tier 2 integration (protocol governs). The protocol governs research intake in `workflow/02-research-intake.md`.

**Domain detection:** Before the research intake gate, classify the task domain. Most planning tasks are Complicated (expert analysis works). Novel areas without precedent are Complex (probe first).

## What you are missing

- [ ] `workflow/01-prerequisite-check.md` — issue-scoping signature, epic doc alignment, tier detection
- [ ] `workflow/01.5-ux-design-gate.md` — UX design review classification (skip for Micro, no-UI, or UX_RATING=low)
- [ ] `workflow/02-research-intake.md` — prior research gathering, multi-call Perplexity verification gate
- [ ] `workflow/03-integration-surface.md` — test-design invocation, integration surface mapping
- [ ] `workflow/04-draft-plan.md` — plan header, task structure, tier-scaled execution, common mistakes
- [ ] `workflow/05-review-handoff.md` — plan-review gate, execution mode selection, handoff

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| All sub-files | No plan produced. No tasks. Nothing to execute. Implementation blocked. |
| `workflow/01` | Plan drafted without verifying issue-scoping ran. Epic architecture contract not checked. Plan silently diverges from approved design. |
| `workflow/02` | Third-party library versions not verified. Plan uses hallucinated API calls from training data. Perplexity gate skipped — no triangulation, stale syntax shipped. |
| `workflow/03` | Integration boundaries untested. SQL business logic gets TypeScript mocks instead of pgTAP. Production bugs from untested cross-system interactions. |
| `workflow/04` | Plan doc header missing research-path comment. Task structure not TDD. Micro/Standard/Complex tier path not selected. No bite-sized steps. |
| `workflow/05` | Plan-review gate skipped entirely — plan ships with no quality check. No review cycles, no reviewer feedback. `planned` label not applied. Execution mode not selected — handoff fails. |

## Plan Review Gate — Human Approval

The plan-review gate (`workflow/05-review-handoff.md`) runs the `plan-review` skill loop; its human point fires when the loop exits `capped` or `stalled`. A capped/stalled plan-review result is NOT clean — the plan must not proceed to Execution Handoff until the user fixes the remaining issues or explicitly approves the plan as-is.

### Approval Routing

When a human gate fires, the agent MUST invoke the approval router to surface the request:

```bash
# Role-based escalation (non-epic gates):
python3 -c "
from operations.coordination.approval import request_approval
request_approval('product-implementer', artifact='<plan-doc>.md', context='plan-review <status> approval for plan <name>')
print('Approval request created')
"
```

This triggers an osascript dialog on the human's machine. The pipeline advances after the human approves via `review_approval()`. If osascript is unavailable (non-macOS, CI, SSH), the approval is logged to the per-repo store `~/.swarm/approvals/<repo>.json` and must be checked manually.

**Response mechanism:** The human clicks "Open" or "Dismiss" on the dialog. The agent monitors `pending_approvals('human')` to detect the response. See `operations/coordination/approval.py` for the full API.

**Role-based escalation** (for non-epic gates): use without `requires_human=True` to route through the VSM hierarchy (product-implementer → product-strategist → team-strategist → human).

## Task Template Fields

Every task in a Standard or Complex plan MUST include these header fields before the step list:

```markdown
### Task N: [Component Name]

**Intent:** [One sentence — why this task exists; what problem it solves or what capability it enables]
**Acceptance:** [Observable criteria — what must be true after this task is done. Executing-plans Step 2.5 gates on this.]
**Files:**
- Create: ...
- Modify: ...
- Test: ...
```

**`Intent`** — Ties the task back to the issue's O/I/T or scoping plan. Answers "why are we building this?" so the implementer can judge whether a divergence still satisfies the goal.

**`Acceptance`** — Observable, verifiable criteria. Consumed by `executing-plans` Step 2.5 (Fidelity Gate) to mechanically compare planned files against `git diff` output. Missing or extra files that contradict Acceptance = flagged.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
