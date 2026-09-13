---
name: project-workflow
description: Fractal planning pipeline for projects (standard/complex issues). Routes through 6 stages with proportional depth — inherits Align from parent Epic, runs proportional review gates.
type: Workflow
domain: capability
subjects.team: organisation-design-team
status: live
tags: [pipeline, project, planning, fractal, orchestrator]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
summary: "Workflow skill that routes a project through the 6-stage pipeline at proportional depth."
created: 2026-07-07
updated: 2026-08-08
steps:
  - name: inherit_align
    type: skill
    gate: auto
  - name: research
    type: skill
    gate: verifier
    requires: [inherit_align]
  - name: scope
    type: skill
    gate: human_approval
    requires: [research]
  - name: plan
    type: skill
    gate: human_approval
    requires: [scope]
  - name: decompose
    type: skill
    gate: verifier
    requires: [plan]
  - name: verify
    type: skill
    gate: verifier
    requires: [decompose]
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

# Project Workflow

Routes a project (standard/complex issue) through the 6-stage pipeline at proportional depth. Sub-skills are the same as epic-workflow — the Workflow determines the depth.

## Branch Isolation (runs BEFORE Phase 1)

> ⛔ **Every issue gets its own branch.** This prevents the 2026-08-06 incident where #74's work committed onto #73's branch.

Before any work begins, verify branch isolation:

```bash
ISSUE_NUMBER="<N>"              # from the issue being worked
SLUG="<kebab-slug>"             # brief slug from issue title
EXPECTED_BRANCH="feat/${ISSUE_NUMBER}-${SLUG}"
CURRENT=$(git branch --show-current)

[ "$CURRENT" = "$EXPECTED_BRANCH" ] && exit 0   # already on correct branch

if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  # #626: in-hub `git checkout -b` is BLOCKED (every repo). Create an isolated
  # worktree instead, cd into it, then re-run this gate from there.
  echo "ℹ️ On $CURRENT (hub): create an isolated worktree first, then re-run this gate from it."
  echo "   agent-infra: bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\""
  echo "   other repos: using-git-worktrees skill (git worktree add -b \"$EXPECTED_BRANCH\" <path> origin/main)"
  echo "⛔ In-hub 'git checkout -b' is BLOCKED (#626) — do not attempt it here."
  exit 1
fi

# Detached HEAD? ABORT — no branch to verify
if [ -z "$CURRENT" ]; then
  echo "⛔ ABORT: Detached HEAD. Create an isolated worktree: agent-infra → 'bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\"'; other repos → using-git-worktrees skill."
  exit 1
fi

# ABORT: on a DIFFERENT issue's branch (boundary match prevents #76 matching #760)
if ! echo "$CURRENT" | grep -qE "(^|/)$ISSUE_NUMBER(-|\$)"; then
  echo "⛔ ABORT: On branch $CURRENT (different issue). Create an isolated worktree for THIS issue: agent-infra → 'bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\"'; other repos → using-git-worktrees skill."
  exit 1
fi
```

> When dispatching parallel subagents, each must get its own worktree — see `skills/issue-workflow/SKILL.md` Branch+Worktree Isolation section for the full pattern.

## Pipeline

> Sub-skills live under `../planning/shared/`. The shared routing stubs exist and dispatch to the underlying skills (e.g. `shared/plan` routes epics to `epic-plan`).

1. **Align** — Inherited from parent Epic. Only runs if standalone.
2. **Research** — `shared/research/SKILL.md` — Targeted research (appends to epic brief if exists)
3. **Scope** — `shared/scope/SKILL.md` — Scope + E2E proportional to project size
4. **Plan** — `shared/plan/SKILL.md` — Proportional substeps (skip prototype if no GUI; 2-3 reviewers vs 1-3)
5. **Decompose** — `shared/decompose/SKILL.md` — MECE-first + wiring + verification (if project has child issues). Uses `issue-creation` skill.
6. **Verify** — `shared/verify/SKILL.md` — Proportional verification

## Human Gates (if standalone)

Same 2-gate pattern as epic, but proportional — faster review cycles:

### Approval Routing (inlined from human-input-framework v2.1.1)

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
request_approval('product-implementer', artifact='<doc-name>.md', context='<stage> approval for project <name>')
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
a project stage approval does not reach a human unless an escalation keyword happens to appear in the
artifact/context (agent-infra #964). Raising it to `requires_human=True` is a deliberate behaviour
change needing its own review; this excerpt documents the current truth.

1. After Scope — docs committed, GitHub URL presented
2. After Planning coherence — docs committed, GitHub URL presented

> **Decomposition gate** is now an AI review gate (not human) — same review+fix loop pattern as other stages.

### UX Design Gate (between Scope and Plan)

After Scope approval and before Plan (Stage 4): invoke `ux-design-review` skill when `UX_RATING ≥ medium`. Proportional — lighter review than epic-level.

> **ponytail:** wired inline. `shared/plan/SKILL.md` exists — it routes epics to `epic-plan` and keeps project planning inline here.

## Align Inheritance

When the project is linked to an Epic (issue body has `**Epic:** docs/epics/...`):
- The Align gate is **skipped** — the parent Epic's Align Decision covers this project
- If the parent Epic has no Align Decision, the Align gate runs for the project

When the project is standalone (no parent Epic):
- Full Align gate runs via `shared/align/SKILL.md` — adversarial test + Eisenhower matrix

## Proportional Rules

| Epic Depth | Project Depth |
|------------|--------------|
| Full adversarial + Eisenhower | Adversarial lite (2 challenges) |
| Full research brief (6+ queries) | Targeted research (2-3 queries) |
| 8 planning substeps | Proportional substeps (skip irrelevant) |
| 4 parallel reviewers | 2-3 reviewers |
| Full E2E test suite | Key-journey E2E only |

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
