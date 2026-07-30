---
name: commit-workflow
description: MANDATORY before any git commit, push, or merge. Runs pre-flight (typecheck, tests, pgTAP), creates PR, code-review gate, auto-merge. Skipping bypasses ALL quality gates.
domain: engineering
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: preflight_checks
    type: skill
    gate: auto
    produces: [typecheck_ok, tests_ok]
  - name: stage_and_commit
    type: skill
    gate: auto
    requires: [preflight_checks]
    produces: [commit_hash]
  - name: create_pr
    type: skill
    gate: auto
    requires: [stage_and_commit]
    produces: [pr_number]
  - name: code_review_gate
    type: skill
    gate: verifier
    requires: [create_pr]
    produces: [review_approved]
  - name: merge_and_deploy
    type: skill
    gate: human_approval
    requires: [code_review_gate]
    produces: [merged]
  - name: cleanup
    type: skill
    gate: auto
    requires: [merge_and_deploy]
    produces: [worktree_removed]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Human approval gate:** presents output for user review. Pipeline advances after approval.
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.



> ⛔ **When you don't follow this skill fully, push will stall and commit will fail. That's the guard we designed. You must follow the skill.**

# Commit Workflow

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

> ⛔ **This file is an index — it describes WHAT the skill does, not HOW to execute it.**
> The actual workflow with mandatory quality gates (pre-flight checks, code review, migration safety, verification) is in the workflow/*.md files below.
> **Why:** This skill gates operations that mutate production state or bypass quality checks. Skipping the workflow files means those gates are silently skipped — commits may bypass tests, PRs may lack review, migrations may deploy unsafely.
> **What to do:** Read every file listed under "What you are missing" below before performing any operation this skill covers.


## Extension-Enforced Gates (apply regardless of tier)

Two Pi extensions block git operations and are NOT tier-gated — they apply to every commit:

### Review Enforcer (`review-enforcer`)
Blocks `git commit/push` and `gh pr create/merge` unless at least one `task` sub-agent was dispatched this session.

- **What it wants:** ≥1 `task` dispatch before any git op
- **What to do:** Dispatch a reviewer sub-agent (even a trivial one-line reviewer). It doesn't need to find issues — it just needs to have run.
- **Bypass:** `AGENT_SKIP_REVIEW_GATE=1` (emergency only)

### Verification Gate (`verification-gate`)
Blocks `git commit` unless every staged file has been verified by a `[VGATE]` sub-agent.

- **What it wants:** A `task` dispatch with `[VGATE] verify files:<paths>` in the prompt
- **Response format:** Must include `PASS` on its own line, or valid JSON: `{"status": "PASS", "failures": [], "verified_files": [{"path": "...", "hash": "..."}]}`
- **Gotcha:** Prompt must say `verify files:` (plural), not `verify file:` (singular) — the regex won't match singular.
- **Bypass:** `AGENT_SKIP_VGATE=1` at session start (disables the gate entirely). `AGENT_ALLOW_MAIN_EDITS=1` no longer disables VGATE — it is the worktree-guard bypass only (#7470)

## What you are missing

- [ ] `workflow/01-preflight.md` — git lock check, integration tests, typecheck, build, pgTAP, issue/branch/tier detection
- [ ] `workflow/02-commit-pr.md` — staging, commit message, draft PR, tier fallback classification
- [ ] `workflow/03-code-review.md` — code review gate, fix loop, NVIDIA pattern scan, tier scaling
- [ ] `workflow/04-merge-deploy.md` — merge, edge function deploy, migration safety verification
- [ ] `workflow/05-cleanup.md` — branch cleanup, worktree teardown, documentation update

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| All sub-files | Raw git commit runs without lock check, tests, or typecheck. No PR created. No review gate. |
| `workflow/01` | Stale .git/index.lock blocks commit with exit 128. Integration tests skipped — broken code merged. Type errors pass through. pgTAP not run on migrations. Review enforcer and verification gate steps skipped — commit blocked with no clue why. |
| `workflow/02` | No issue link in commit message. Draft PR not created. Tier misclassified — complex migrations get micro treatment (code review skipped). |
| `workflow/03` | Code review entirely skipped. P0 bugs in PR diff undetected. No fix loop runs. Standard+Complex projects ship unreviewed. |
| `workflow/04` | Merge fails because branch not ready. Edge functions not deployed to Supabase. Migration safety checks skipped. |
| `workflow/05` | Stale branches accumulate on remote. Worktrees not cleaned up — disk space leaks. Design docs not synced to repo mirror. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
