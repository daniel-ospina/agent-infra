# Research Brief — #387: reusable unit-test workflow + drift-check contract

> Issue: https://github.com/daniel-ospina/agent-infra/issues/387
> Scoping Phase 1.5 (issue-scoping v5.1) — 2026-08-30

## Axis Research

### Config axis — reusable workflow inputs (canonical)
- GitHub Docs (reuse-workflows): `workflow_call` defines `inputs`/`secrets`; callers pass via `with`; **cannot add steps after calling a reusable workflow** — reusable workflows fit orchestration-level logic, not partial step reuse. Env vars from the caller do NOT carry over — inputs must be explicit. Secrets inherit down the call chain only. Cross-repo refs use `{owner}/{repo}/...@{ref}` where ref = SHA (safest), release tag, or branch (release tag wins over same-named branch). Source: https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows

### Config axis — reusable workflow versioning at org scale (pitfalls)
- DevOpsNess 2026-07 (org-scale reusable workflows): pinning internal reusable workflows to a semver tag and bumping per change **reintroduces the "60-PR problem"** — every change becomes a coordinated tag + bump of every caller. Org-scale practice: internal workflows pinned to a **moving major tag** (@v3 re-pointed for backward-compatible fixes → one commit updates the fleet), third-party actions pinned to SHAs; central repo **self-tests the reusable workflow against a sample service pre-merge**; major-tag moves rolled to a **canary set** first. Source: https://www.devopsness.com/blog/github-actions-reusable-workflows-org-scale
- **Implication for the #303 semver-pin contract:** the tag-per-change ceremony is the friction cost of centralization. Workflow additions must be rare and additive (new inputs with defaults, never breaking changes), or the contract makes agents prefer inline jobs (path of least resistance). Precedent for additive inputs already exists in agent-infra: `python-ci.yml` takes `test-command`/`lint-command`/`typecheck-command` inputs (D4 — generic skeleton + repo-specific invocation via inputs).

### Config axis — pin drift auditing (pitfalls)
- SystemShardening 2026-05 (reusable workflow pinning + drift audit): mutable tags in a reusable workflow's transitive graph = compromise vector; org-level SHA-pinning policy is necessary but not sufficient (doesn't verify reusable-workflow `uses:` recursively). Drift audits catch force-pushed/rotated tags. Agent-infra's drift-check (#303 pin compare + symlink sweep) is the same class of control, currently inactive on tortoise/premise-labs due to stale exemptions (verified in code: bin/agent-infra.js `_checkCI` early-returns on `templates/.github/workflows/` exemption). Source: https://www.systemshardening.com/articles/cicd/github-actions-reusable-workflow-pinning-audit/

## Raw Notes
- Findings date: 2026-08-30
- Controller-verified facts (not from sub-agents): `dashboard-js-tests` IS on tortoise origin/main (merged PR #2044, commit 0762928b); manifest.json exemptions (`templates/.github/workflows/`) apply to tortoise + premise-labs + eldato-outreach; `_checkCI` (bin/agent-infra.js:720) returns 0 before the symlink/pin checks when exempted → the #303 pin contract has never run on tortoise or premise-labs.
- Demand scan: only tortoise has a `node --test` job across consumer repos; eldato/dmer/dmeer use vitest (would need npm-ci inputs); premise-labs/swarm/eldato have zero node --test occurrences.
- Billing: caller-billed — centralization is budget-neutral for the daniel-ospina account; tortoise is public (free either way).
