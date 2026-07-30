> **Step 5/5** | ← requires: `04-draft-plan.md`

## Plan Review Gate (Standard and Complex Tiers) — Gate Loop — MANDATORY

After saving the plan doc, invoke the `plan-review` skill to validate plan quality:

```
plan-review docs/plans/YYYY-MM-DD-<feature-name>.md [--issue <ISSUE_NUMBER>] [--epic <epic-doc-path>] --tier <TIER>
```

Pass the issue number and epic path if available. Wait for the skill to complete.

**The `plan-review` skill runs each review cycle in FRESH `task` sub-agents** —
reviewers have no memory of prior cycles, preventing confirmation bias.
See `.pi/APPEND_SYSTEM.md` → Review Loop Protocol for the full protocol.

- **If `status=clean`:** proceed to Execution Handoff
- **If `status=capped` or `status=stalled`:** surface the remaining issues to the user. Do NOT proceed to Execution Handoff until the user either fixes the issues or explicitly approves the plan as-is.

**FORBIDDEN — these bypass the quality gate entirely:**

- ❌ Skip `plan-review` because the plan "looks good"
  Every Standard+Complex plan MUST pass plan-review before execution.

- ❌ Accept a capped/stalled plan-review result as clean
  `capped` and `stalled` are NOT clean — they require human approval.

- ❌ Run plan-review and ignore its output
  The review cycle IS the quality gate. Skipping it = no quality gate.

## Execution Handoff

**Pre-check (Standard/Complex only):** Before proceeding, verify the plan doc contains a clean review signature:

Search for `<!-- plan-review:` in the plan doc. If:
- Signature is absent → stop. Run `plan-review` first.
- `status=clean` → proceed.
- `status=capped` or `status=stalled` → stop. Surface issues to user.

After saving the plan, apply the `planned` label to the GitHub issue (if applicable):

```bash
# Remove planning, then apply planned (idempotent)
gh issue edit <number> --remove-label planning || true
gh issue view <number> --json labels --jq '.labels[].name' | grep -q '^planned$' || gh issue edit <number> --add-label planned
```

**Status transition:** Plan `doc_status`: draft → live (plan-review passed clean). Issue: scoped → planned.

Then select execution mode automatically:

**≤ 8 tasks → Subagent-Driven (this session)**
- Stay in this session
- Fresh subagent per task + code review

**> 8 tasks → Parallel Session (separate)**
Output this message (substituting actual values) and stop:

```
Plan ready: `docs/plans/YYYY-MM-DD-<feature-name>.md` (N tasks)

Open a new session in the `<branch>` worktree and paste:

> Use the `executing-plans` skill to implement this plan:
> `docs/plans/YYYY-MM-DD-<feature-name>.md`
> Issue: #<ISSUE_NUMBER>
> Branch: <branch>
```

> **Rationale:** 8 tasks is the threshold where context window pressure in a single session makes a separate session worthwhile. Below that, the overhead of context-switching between sessions exceeds the cost of staying in one.

Announce the selected mode with a one-line note: "Using [subagent-driven/parallel session] for [N] tasks — [brief reason]."

If the user prefers the other mode, switch without argument.

## Label Cleanup

If this skill exits early (error, user abort, or any non-completion path), remove the `planning` label:

```bash
gh issue edit <ISSUE_NUMBER> --remove-label planning || true
```

Do not leave `planning` on issues where work is not actively progressing.
