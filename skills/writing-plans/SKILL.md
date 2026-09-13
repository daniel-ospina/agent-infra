---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code. Assumes requirements, priorities, and needs are already captured by `issue-scoping`. Focuses on design decisions and implementation steps.
domain: engineering
subjects.team: organisation-design-team
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
    # #4907: resolve `$AGENT_INFRA_PATH` — a required prerequisite per AGENTS.md
    # (NO `$HOME/agent-infra` default fiction; if unset, the pending-gate
    # guidance says to set it) — and run the absolute path
    # `…/scripts/parallel_work_check.sh plan` (C3). The pending-gate guidance
    # prints the resolved command — use that form (it is escape-regex-safe);
    # do NOT run `$PARALLEL_CHECK_BIN`/`env PARALLEL_CHECK_BIN=…` at the gate
    # (not in the escape allowlist); `.sh|.py` suffix required. CLEAR verdict
    # writes the PASS token; the gate blocks until
    # fresh. Set CHECKOUT_GUARD_ENFORCE=1. At the gate: read / loop_enforcer are
    # always allowed; operator force-pass via /tmp/parallel-check-force.json
    # (one-shot, 60-min TTL, repo-bound, human-only).
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

**Skip Step B of the research intake gate (`workflow/02`) — the multi-call Perplexity gate — when:**
- The plan touches **zero third-party dependencies** — Node stdlib only, type-only imports, or in-repo wrappers used 2+ times.
- Proceed directly to `workflow/03-integration-surface.md` **after Step A still runs**.

> **Step A always runs (all tiers):** the intake of prior research (epic brief, `### Axis Research` / `### Integration Docs` scoping blocks) is cheap and must never be zeroed by the zero-deps skip — standard+ plans consume the scoping artifact even when no fresh gate queries fire (issue #231 D4/T4).

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

> **Canonical:** `skills/human-input-framework/SKILL.md` → "Approval Routing — Canonical".
> Inlined operational excerpt — cross-session resilience: this skill must run in a fresh session
> without loading the framework skill first. Only the operational core is inlined; the status table,
> store/transport contract, and Slack enablement live canonically (restating them is how the original
> six copies drifted apart).

When a human gate fires, the agent MUST invoke the approval router to surface the request:

```bash
# Portable invocation (works from ANY repo checkout — swarm #1402 rollout):
python3 -c "
import os, sys
sys.path.insert(0, os.environ.get('SWARM_ROOT', os.path.expanduser('~/swarm')))
from operations.coordination.approval import request_approval
request_approval('product-implementer', artifact='<plan-doc>.md', context='plan-review <status> approval for plan <name>')
print('Approval request created')
"
```

⛔ **No dialog pops — do not wait for one.** A `pending` request fires a macOS *notification banner*
(`osascript … display notification`), which has no buttons and no answer path; it is best-effort and
silently no-ops on non-macOS/CI/SSH. Reaching a human on Slack needs more than `SLACK_BOT_TOKEN` +
`SLACK_APPROVAL_CHANNEL`: the bridge derives a **different** store slug than the router, so
`SLACK_APPROVAL_FILE` must be pinned to the router's store (agent-infra #956) or the request just
waits in `~/.swarm/approvals/<slug>.json`.

**Detect the answer — read the record, never infer from a shrinking list:**
```bash
SWARM="${SWARM_ROOT:-$HOME/swarm}/operations/coordination/approval.py"
python3 "$SWARM" --pending --role human    # still open
python3 "$SWARM" --status <req_id>         # this record's status + reviewer
```
A Slack thread reply sets `changes_requested`, which leaves `--pending` **without approving**;
`is_approved(..., requires_human=True)` also returns `False` after a Slack *button* approval (the
bridge overwrites `reviewer` with the clicking user's id — agent-infra #959). Trust `status == 'approved'`.

**Role-based escalation:** with `APPROVAL_AUTO_APPROVE=0`, omitting `requires_human=True` pends for
the requester's `reports_to` role — e.g. `product-strategist` for `product-implementer`; only
`chain[1]` is used, so nothing walks the chain further. Under the default (`APPROVAL_AUTO_APPROVE`
unset, which means `1`) such a request **auto-approves** and never reaches a human — **unless** an
escalation keyword (`deploy`/`delete`/`destroy`/`migrate`/`release`) appears in the artifact/context,
which pends for a human regardless. Pass `requires_human=True` for a real human checkpoint.

⚠️ **This gate currently passes no `requires_human`**, so under the default config it auto-approves —
the capped/stalled plan-review status does not reach the user unless an escalation keyword happens to
appear in the artifact/context (agent-infra #964). Raising it to `requires_human=True` is a
deliberate behaviour change needing its own review; this excerpt documents the current truth.

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
