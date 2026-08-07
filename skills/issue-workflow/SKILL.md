---
name: issue-workflow
description: Entry-point router for any GitHub issue. Detects Level (Epic/Project/Task) from fractal fields and dispatches to the correct workflow skill. Use when asked to implement, fix, work on, or close any issue.
domain: capability
type: Workflow
status: live
tags: [pipeline, issue, routing, fractal, orchestrator, entry-point]
summary: "Fractal entry-point router — detects Level + complexity and dispatches to epic-workflow, project-workflow, task-workflow (micro), or task-workflow-standard (gated)."
created: 2026-07-07
updated: 2026-08-07
steps:
  - name: classify_ask
    type: skill
    gate: auto
    produces: [level, domain]
  - name: detect_level
    type: skill
    gate: auto
    requires: [classify_ask]
    produces: [routing_decision]
  - name: align_inheritance_check
    type: skill
    gate: auto
    requires: [detect_level]
  - name: oit_validation
    type: skill
    gate: auto
    requires: [detect_level]
  - name: label_lifecycle
    type: skill
    gate: auto
    requires: [detect_level]
  - name: dispatch
    type: skill
    gate: auto
    requires: [align_inheritance_check, oit_validation, label_lifecycle]
    produces: [routed_to_workflow]
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Issue Workflow

Entry-point router for the fractal planning pipeline. Detects the issue's Level from its fractal fields and dispatches to the correct workflow skill.

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Routing

```
ISSUE IN (#N)
      │
      ▼
issue-workflow (entry-point router)
      │
      ├── Level: epic  ──────────────▶ epic-workflow (6 stages, full depth)
      ├── Level: project ────────────▶ project-workflow (6 stages, proportional)
      └── Level: task ────────────────▶ complexity:micro ───────────▶ task-workflow (6 stages, inline)
                                     └── complexity:standard/complex ─▶ task-workflow-standard
                                         (or unknown — fail-closed)      (gated: verifier gates at scope + plan)
```

## Level Detection

```bash
ISSUE_BODY=$(gh issue view $ISSUE_NUMBER --json body -q '.body')
LEVEL=$(echo "$ISSUE_BODY" | grep -oP 'Level:\s*\K\w+' || echo "")

# Fallback: derive from complexity label
if [ -z "$LEVEL" ]; then
  LABELS=$(gh issue view $ISSUE_NUMBER --json labels -q '.labels[].name')
  if echo "$LABELS" | grep -q 'complexity:micro'; then LEVEL="task"
  elif echo "$LABELS" | grep -qE 'complexity:(standard|complex)'; then LEVEL="project"
  else LEVEL="epic"
  fi
fi
```

> **Fallback is a heuristic only.** Issues created via `issue-creation` always carry explicit `**Level:**` + `complexity:<tier>` fields — the explicit `Level:` field always wins. The fallback above is for legacy/unfielded issues: `complexity:micro` → task, `complexity:standard|complex` → project.

**Align Inheritance:** If the issue has a parent Epic (`**Epic:** docs/epics/...`), the parent's Align Decision covers this issue. Check before dispatching.

**O/I/T Validation:** Verify the issue has Objective/Indicator/Target fields. If missing and no parent to inherit from, warn — consider running `issue-creation` first.

## Dispatch

| Level | Complexity | Dispatches to | Depth |
|-------|-----------|--------------|-------|
| `epic` | any | `epic-workflow` | Full: 6 stages, all review gates, 3 human gates |
| `project` | any | `project-workflow` | Proportional: shared sub-skills, reduced depth |
| `task` | `micro` (or all-low) | `task-workflow` | Inline: all 6 stages, no sub-skill dispatch |
| `task` | `standard` \| `complex` (or missing/unknown) | `task-workflow-standard` | Gated: 2 parallel verifiers at scope AND plan before implementation |

**Task complexity routing rules:**

- `Level: task` + `complexity:micro` → `task-workflow` (the micro pipeline).
- `Level: task` + `complexity:standard` or `complexity:complex` → `task-workflow-standard` — **never** the micro pipeline. This is the fix for #97: all task-level issues used to run micro, skipping the verifier gates standard/complex tasks need.
- `Level: task` with **missing/unknown complexity** → fail-closed to `task-workflow-standard` (gated is safer than skipping gates). The agent validates complexity during Scope — `issue-scoping` may downgrade to micro if the work is trivial.

**Reconciliation with project-workflow:** a standard/complex issue that is `Level: task` stays in `task-workflow-standard` while it remains a single atomic deliverable (no decomposition). If Scope reveals the task needs **MECE decomposition into child issues, wiring, or E2E** → escalate to `project-workflow` instead. Conversely, issues declared `Level: project` always go to `project-workflow`. The Level-detection fallback below (standard/complex → project) is a heuristic for issues missing fractal fields — an explicit `Level:` field always wins.

## Label Lifecycle

Prevent concurrent agent collisions on the same issue.

**Before dispatch:**
```bash
# 1. Self-cleanup stale label from crashed prior run
gh issue view $ISSUE --json labels -q '.labels[].name' | grep -q '^implementing$' \
  && gh issue edit $ISSUE --remove-label implementing

# 2. Warn if other agent has in-progress label
OTHER=$(gh issue view $ISSUE --json labels -q '.labels[].name' \
  | grep -E '^(scoping|planning|implementing)$' | grep -v '^implementing$' || true)
[ -n "$OTHER" ] && echo "⚠️ Issue #$ISSUE has in-progress label(s): $OTHER — another agent may be working on it."

# 3. Apply implementing label
gh issue view $ISSUE --json labels -q '.labels[].name' | grep -q '^implementing$' \
  || gh issue edit $ISSUE --add-label implementing
```

**After completion** (in the workflow skill that finishes the work):
```bash
gh issue edit $ISSUE --remove-label implementing
gh issue edit $ISSUE --add-label implemented
```

**On early exit:** Remove `implementing` — don't leave orphaned in-progress labels.
```bash
gh issue edit $ISSUE --remove-label implementing || true
```

## Branch + Worktree Isolation

> ⛔ **This gate runs BEFORE any work on the issue.** Every issue gets its own branch. Every parallel subagent gets its own worktree. This prevents the 2026-08-06 incident where parallel agents collided in the shared main checkout and #74's work landed on #73's branch (PR #75 contained both).

### 1. Branch Gate (runs first — before edits or dispatch)

```bash
ISSUE_NUMBER="76"              # extract from the issue being worked
SLUG="branch-isolation"        # brief kebab-case slug from the issue title
EXPECTED_BRANCH="feat/${ISSUE_NUMBER}-${SLUG}"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Already on the correct branch — proceed
[ "$CURRENT_BRANCH" = "$EXPECTED_BRANCH" ] && echo "✅ On correct branch: $CURRENT_BRANCH" && exit 0

# On main — create the dedicated branch
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  git checkout -b "$EXPECTED_BRANCH"
  echo "✅ Created and switched to: $EXPECTED_BRANCH"
  exit 0
fi

# Detached HEAD? ABORT — no branch to verify
if [ -z "$CURRENT_BRANCH" ]; then
  echo "⛔ ABORT: Detached HEAD. Checkout main first: git checkout main && git checkout -b $EXPECTED_BRANCH"
  exit 1
fi

# ABORT: on a DIFFERENT issue's branch (boundary match prevents #76 matching #760)
if ! echo "$CURRENT_BRANCH" | grep -qE "(^|/)$ISSUE_NUMBER(-|\$)"; then
  echo "⛔ ABORT: You are on branch \"$CURRENT_BRANCH\" which belongs to a DIFFERENT issue."
  echo "   This is how #74's work committed onto #73's branch (incident 2026-08-06)."
  echo "   → Stash or commit your changes on $CURRENT_BRANCH first."
  echo "   → Then: git checkout main && git checkout -b $EXPECTED_BRANCH"
  exit 1
fi

# Branch contains this issue number — proceed (already on a matching branch with different slug)
echo "✅ On matching branch: $CURRENT_BRANCH"
```

### 2. Worktree Gate (runs for parallel subagent dispatch)

When dispatching multiple subagents that write to the same repo, each subagent MUST get its own worktree. The dispatcher creates them and passes the path via `cwd` — never dispatch two subagents to the same checkout.

```bash
# Dispatcher creates an isolated worktree for each subagent:
WORKTREE_PATH=".worktrees/subagent-${SUBAGENT_ID}"
git worktree add --detach "$WORKTREE_PATH" HEAD

# Then dispatch the subagent with cwd = $WORKTREE_PATH
# After the subagent completes, clean up:
git worktree remove --force "$WORKTREE_PATH"
```

> **Orchestrator rule:** Parallel subagents → each gets `git worktree add` + unique `cwd`. Never reuse the same checkout. See `skills/using-git-worktrees/SKILL.md` for symlink setup and `skills/parallel-orchestrator/SKILL.md` for dispatch patterns.

<HARD-GATE>
Do NOT write code, edit files, or form an implementation plan until the correct workflow skill has been invoked and its Align stage is complete.
</HARD-GATE>

## Auto-Continue

After dispatching, the workflow skill handles all phase transitions. Do NOT pause between phases unless the workflow skill mandates a human gate.

## Rationalizations That Are Always Wrong

| Thought | Reality |
|---|---|
| "I know what Level this is — I'll skip detection" | Wrong Level = wrong pipeline = missing gates. |
| "Level: task always means the micro pipeline" | Task dispatch depends on complexity: `micro` → task-workflow, `standard/complex` → task-workflow-standard (gated). |
| "complexity:micro means I can skip the pipeline" | Task-workflow still runs all 6 stages inline. |
| "This issue has no fractal fields — I'll just start coding" | No fields → run issue-creation first, then route. |

## Red Flags

- Reaching for a code file before detecting Level
- Invoking a workflow skill directly instead of through issue-workflow
- Any thought starting with "I already know what to do..."

## References

- `../epic-workflow/SKILL.md`
- `../project-workflow/SKILL.md`
- `../task-workflow/SKILL.md`
- `../task-workflow-standard/SKILL.md`
- `../issue-creation/SKILL.md`
- `docs/teams/organisation-design-team/data/ONTOLOGY.md`

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
