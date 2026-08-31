---
name: commit-workflow
description: MANDATORY before any git commit, push, or merge. Runs pre-flight (typecheck, tests, pgTAP), creates PR, code-review gate, auto-merge. Skipping bypasses ALL quality gates.
domain: engineering
version: 1.1.0
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: preflight_checks
    type: skill
    gate: auto
    produces: [typecheck_ok, tests_ok]
  - name: parallel_check_implement
    type: gate
    gate: checkpoint
    token_phase: implement
    requires: [preflight_checks]
    # #4907: before committing, resolve `$AGENT_INFRA_PATH` — a required
    # prerequisite per AGENTS.md (NO `$HOME/agent-infra` default fiction; if
    # unset, the pending-gate guidance says to set it) — and run the absolute
    # path `…/scripts/parallel_work_check.sh implement` (C4 — pre-merge symbol
    # re-check + base-drift). The pending-gate guidance prints the resolved
    # command — use that form (it is escape-regex-safe); do NOT run
    # `$PARALLEL_CHECK_BIN`/`env PARALLEL_CHECK_BIN=…` at the gate (not in the
    # escape allowlist); `.sh|.py` suffix required. Fail-closed gate; read /
    # loop_enforcer are the in-session escape; operator force-pass via
    # /tmp/parallel-check-force.json.
  - name: stage_and_commit
    type: skill
    gate: auto
    requires: [parallel_check_implement]
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
    gate: verifier
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

**AI review gate (merge):** merge proceeds when the review APPROPRIATE TO THE ISSUE
CONTENT is clean (0 P0, 0 P1, 0 P2 — all findings with confidence ≥ 50 resolved) AND pre-flight tests passed (per `01-preflight.md` risk tier —
regression check for code PRs) AND the verification gate verified the staged files. The review
is surface-dispatched from the PR diff (issue complexity ratings scale review depth, per
`code-review` Step 0.8 infra detection + Step 3.6 surface matrix, and `test-routing` domain dispatch):
always-on: bug scan (shallow+deep), guidance compliance, history, prior-PR comments, and SECURITY
(security-review skill discipline — HIGH-confidence findings only, research-before-report);
plus domain reviewers as applicable: skills/extensions/.mcp.json/ontology → Skill Infrastructure /
Ontology & Templates / Extension Safety; UX → ux-consistency/ux-coverage/ux-realism (code-review) + ux-verification (test-routing); config → Agent #12 config review;
research/docs → proportional review. No human approval required for technical merges.
**Human escalation (only):** P0 findings requiring an architectural or security decision
(irreversible ops, data loss, security breach) — and only after the code-review fixer loop
escalation is exhausted (per the `code-review` skill, Step 6.5 Orchestrator Escalation).
**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.



> ⛔ **When you don't follow this skill fully, push will stall and commit will fail. That's the guard we designed. You must follow the skill.**

# Commit Workflow

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

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
