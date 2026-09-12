---
name: issue-workflow
description: Entry-point router for any GitHub issue. Detects Level (Epic/Project/Task) from fractal fields and dispatches to the correct workflow skill. Use when asked to implement, fix, work on, or close any issue.
domain: capability
subjects.team: organisation-design-team
type: Workflow
status: live
tags: [pipeline, issue, routing, fractal, orchestrator, entry-point]
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
summary: "Fractal entry-point router — detects Level + complexity and dispatches to epic-workflow, project-workflow, task-workflow (micro), or task-workflow-standard (gated)."
created: 2026-07-07
updated: 2026-08-08
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

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

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

**Pre-dispatch collision gate (#3061 — fail-closed).** Before dispatching ANY work for an issue (worktree, branch, sub-agent, or parallel workstream), run the collision pre-flight from the target repo root:

```bash
python3 tools/collision_preflight.py <N>   # ONLY exit 0 authorizes dispatch
```

| Exit | Verdict | Action |
|------|---------|--------|
| `0` | CLEAN | every surface queried, no in-flight work — proceed |
| `1` | COLLISION | a worktree/branch/PR/claim already covers #N — **do NOT dispatch** |
| `2` | INCOMPLETE | a surface could not be queried — **NOT clean**; fix `gh` auth/network and re-run |
| `3` | usage/internal error | **stop** |

**Any non-zero exit stops the dispatch. There is no "warn and proceed."** If `gh` is unavailable the tool returns INCOMPLETE (2) by construction — that is a stop, not a degradation path. If the repo carries no `tools/collision_preflight.py`, record that fact in the dispatch log rather than silently skipping the gate.

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

### 0. Worktree-first rule (#265/#615 — enforced, not advisory)

**Every repo — agent-infra included:** primary sessions AND write-capable sub-agent dispatches MUST run in an isolated worktree — never on the shared main checkout. The main-worktree-guard enforces this mechanically for ALL repos: branch-state changes in any main checkout are BLOCKED (agent-infra included since #615 removed the #99 in-main-work exemption), commits off the session baseline are BLOCKED, and sub-agents carry no `AGENT_ALLOW_MAIN_EDITS` — #617/#623: the hatch is **stripped by default** from `task`/`subagent` children, so even a HATCHED controller dispatches an UNHATCHED fleet unless the dispatch passes `allow_main_edits: true`; never rely on the child env for isolation — always pass a worktree `cwd`. If the Branch Gate below detects you are in a main checkout, create a worktree first (using-git-worktrees skill; agent-infra: `hub-worktree.sh <branch>`) and run the gate from there.

**Agent-infra has NO in-main-work exemption.** Extensions/skills/config are read from committed state (pi loads skills from `~/.pi/agent`, extensions at startup — a copy synced post-merge; `MEMORY.md` is a repo file read by agents on demand, not an auto-loaded copy), so shared-state edits do NOT need the shared main checkout: they land via worktree → merge → sync, exactly like every other repo. A one-line MEMORY.md/skill append is a low-risk `complexity:micro` change, but micro is a review-scope tier — it does NOT exempt the worktree rule: it still runs through the same worktree → commit → merge → sync ceremony. The agent-infra hub stays main + clean; in-main `git checkout -b <branch>` is BLOCKED there like any other hub (the M3 create-new carve-out was removed in #626).

### 1. Branch Gate (runs first — before edits or dispatch)

```bash
ISSUE_NUMBER="76"              # extract from the issue being worked
SLUG="branch-isolation"        # brief kebab-case slug from the issue title
EXPECTED_BRANCH="feat/${ISSUE_NUMBER}-${SLUG}"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Already on the correct branch — proceed
[ "$CURRENT_BRANCH" = "$EXPECTED_BRANCH" ] && echo "✅ On correct branch: $CURRENT_BRANCH" && exit 0

# On main/master — you are in the HUB, where an in-place branch flip is BLOCKED
# (#626; agent-infra included since #615 removed the #99 exemption). Create an
# ISOLATED WORKTREE instead (using-git-worktrees skill; agent-infra:
# `bash scripts/checkout-hygiene/hub-worktree.sh "$EXPECTED_BRANCH"`), cd into it,
# and RE-RUN this gate there. The worktree branch is created from FRESH origin
# state by the worktree command (#178/#179: never branch from stale local main).
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  echo "ℹ️ On $CURRENT_BRANCH (hub): create an isolated worktree first, then re-run this gate from it."
  echo "   agent-infra: bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\""
  echo "   other repos: using-git-worktrees skill (git worktree add -b \"$EXPECTED_BRANCH\" <path> origin/main)"
  echo "⛔ In-hub 'git checkout -b' is BLOCKED (#626) — do not attempt it here."
  exit 1
fi

# Detached HEAD? ABORT — no branch to verify
if [ -z "$CURRENT_BRANCH" ]; then
  echo "⛔ ABORT: Detached HEAD. Create an isolated worktree: agent-infra → 'bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\"'; other repos → using-git-worktrees skill."
  exit 1
fi

# ABORT: on a DIFFERENT issue's branch (boundary match prevents #76 matching #760)
if ! echo "$CURRENT_BRANCH" | grep -qE "(^|/)$ISSUE_NUMBER(-|\$)"; then
  echo "⛔ ABORT: You are on branch \"$CURRENT_BRANCH\" which belongs to a DIFFERENT issue."
  echo "   This is how #74's work committed onto #73's branch (incident 2026-08-06)."
  echo "   → Commit or stash your changes on $CURRENT_BRANCH first."
  echo "   → Then create an isolated worktree for THIS issue: agent-infra → 'bash scripts/checkout-hygiene/hub-worktree.sh \"$EXPECTED_BRANCH\"'; other repos → using-git-worktrees skill."
  exit 1
fi

# Branch contains this issue number — proceed (already on a matching branch with different slug)
echo "✅ On matching branch: $CURRENT_BRANCH"
```

### 2. Worktree Gate (runs for parallel subagent dispatch)

When dispatching multiple subagents that write to the same repo, each subagent MUST get its own worktree. The dispatcher creates them and passes the path via `cwd` — never dispatch two subagents to the same checkout. **After #265/#615 this extends to EVERY write-capable implementer sub-agent in EVERY repo (agent-infra included):** the sub-agent env no longer carries `AGENT_ALLOW_MAIN_EDITS` (#617/#623 — the hatch is default-stripped from `task`/`subagent` children, so even a hatched controller dispatches an unhatched fleet unless the dispatch opts in with `allow_main_edits: true`; never rely on the child env for isolation — always pass a worktree `cwd`), so a write-capable sub-agent dispatched with `cwd` = a main checkout (any repo — the #99 agent-infra exemption was removed by #615) is blocked on write/edit + destructive git. Read-only sub-agents (reviewers, researchers) need no worktree — the guard only blocks writes.

```bash
# Dispatcher creates an isolated worktree for each subagent:
WORKTREE_PATH=".worktrees/subagent-${SUBAGENT_ID}"
git worktree add --detach "$WORKTREE_PATH" HEAD

# Then dispatch the subagent with cwd = $WORKTREE_PATH
# After the subagent completes, clean up:
git worktree remove --force "$WORKTREE_PATH"
```

> **Orchestrator rule:** Parallel subagents → each gets `git worktree add` + unique `cwd`. Never reuse the same checkout. See `skills/using-git-worktrees/SKILL.md` for symlink setup and `skills/parallel-orchestrator/SKILL.md` for dispatch patterns.

#### Teardown ownership — who cleans up when the dispatch dies (#195)

> ⛔ **Teardown is RECORD-FIRST.** The 2026-08-12 incident: an aborted 6-task dispatch left 3 orphaned worktrees + 3 `fix/*` branches (one pushed upstream later), and `.worktrees/` accumulated 60+ dead entries — because the dispatcher created the artifacts but nothing owned teardown when the dispatch was aborted mid-run.

1. **The dispatcher owns teardown** — not the sub-agent, not the worktree gate. Sub-agents die with the abort; only the dispatcher (or the record it left) survives.
2. **Record before dispatch, always** — each artifact the sub-agent will create (branch, worktree) is written to the teardown manifest BEFORE the sub-agent starts:
   ```bash
   bash scripts/record-worktree.sh add --branch fix/NNN-slug --worktree ".worktrees/subagent-${SUBAGENT_ID}" --dispatch d-<dispatch-id>
   ```
3. **Clean completion** → remove records: `bash scripts/record-worktree.sh done --dispatch d-<dispatch-id>`
4. **Abort/crash/hang** → leave the records. They are the teardown manifest; do not half-clean.
5. **Sweep** → `bash scripts/scan-orphans.sh` (dry-run) / `--apply` (remove) flags stale records whose branch is local-only with no open PR, plus dirty worktrees (manual review), ghosts, and unrecorded worktrees (informational). See the script header for the full contract.

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
- `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d`

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
