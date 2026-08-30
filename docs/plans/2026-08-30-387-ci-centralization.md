---
title: "#387 — CI Centralization (unit-test capability + enforcement activation) — Implementation Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-30
aboutSubjects: node-ci.yml, drift-check, manifest.json, sync-ci-workflows.sh
aboutObjects: agent-infra, tortoise, premise-labs, issue-387
---

<!-- research-path: docs/research/2026-08-30-387-ci-centralization.md -->

# CI Centralization: reusable unit-test workflow + #303 enforcement activation — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Ship a reusable `unit-test` job in node-ci.yml, migrate tortoise's hand-rolled `dashboard-js-tests` to it, and activate the #303 pin/symlink drift-check non-vacuously on premise-labs + tortoise.

**Team:** organisation-design-team
**Architecture:** Approach A (scoping: docs/scoping/2026-08-30-issue-387-ci-centralization-plan.md) — extend node-ci.yml with a 5th `unit-test` job (inputs node-version/working-directory/test-glob/test-command; job-level skip + step-level if: branch selection, NO shell interpolation) + boolean `script-validate`/`skill-lint` skip inputs (`default: true` — load-bearing: tortoise's scripts/ is a broken-on-runner symlink → #254 fail-closed red otherwise) + dogfood ci-main `extension-tests` (name kept) + one-commit manifest ci.ref/check.ci.ref co-bump + drift fixture co-bump + `_checkCI` sync guard + drift-check.yml:12 doc fix. Release: mechanical job-level verify-before-tag gate → tag v0.1.1 → premise-labs bump → tortoise bump/wiring/migration → exemption lift (both-consumers-merged preflight) → non-vacuous verify. Rejected: B sibling workflow, C composite action, D lift-first (rationale in scoping plan §Rejected alternatives).

### Pattern Research
Skipped — plan touches zero third-party dependencies. GitHub Actions `workflow_call` inputs semantics, `node --test`, and the D4 `'' = skip` + `if:`-guard pattern are in-repo precedents (python-ci.yml test-command/lint-command/typecheck-command; ci-main failure accumulator; #254 fail-closed). External findings (GitHub docs inputs contract; DevOpsNess 60-PR ceremony pitfall; SystemShardening drift audit) consumed in the scoping Phase 1.5 artifact (docs/research/2026-08-30-387-ci-centralization.md) with reconciliation notes in the scoping plan.

### Integration Surface Map
| Surface | Consumer | Change | Test layer |
|---|---|---|---|
| node-ci.yml unit-test job (templates/ + materialized) | tortoise dashboard-js-tests; ci-main dogfood | add job + inputs | workflow-drift diff + tortoise PR CI + ci-main post-merge run |
| `_checkCI` pin compare + sync guard | premise-labs, tortoise (post-lift), agent-infra self | exemption lift; guard | tests/drift/run.sh case 9 (new, negative path) |
| manifest ci.ref / check.ci.ref | all consumers | v0.1.0 → v0.1.1 co-bump | run.sh cases 2/7/8 (fixture pin parity) |
| drift-check.yml header doc | consumers | :12 doc fix | run.sh case 1 (YAML validity) |
| sync-ci-workflows.sh | agent-infra | no change (node-ci in 3-file list) | pipeline-compliance workflow-drift |
| ci-ref-check.cjs REUSABLE_WORKFLOWS | agent-infra | no change (A: node-ci already allowlisted) | ci-ref-check.test.mjs |

**Tech Stack:** GitHub Actions (workflow_call), Node 22 (node --test, npx tsx for dogfood tsx suites), bash (run.sh fixture harness), zero-dep CJS.

---

### Task 1: `_checkCI` sync guard (test-first)

**Intent:** Enforce the manifest `ci.ref === check.ci.ref` invariant so the release axis can never drift apart (the nested field is dead in code but documented as the contract; a two-commit bump would otherwise silently break parity).
**Acceptance:** run.sh case 9 exists and asserts the guard FIRES on mismatch (tamper check.ci.ref → v9.9.9 → exit 1 + guard message); cases 1-8 unchanged green; manifest.json restored by the existing single `cleanup()` trap.
**Files:**
- Modify: `bin/agent-infra.js` (guard after `const ci = manifest.ci;` ~:748; null-safe fail-closed)
- Modify: `tests/drift/run.sh` (case 9 LAST after case 8; node -e JSON round-trip tamper targeting `manifest.check.ci.ref` — NOT sed, two identical refs; cp-back restore in the existing single trap — no second trap, bash replaces; preflight extended to manifest.json; case enumeration header line 9)

**Step 1:** Write failing case 9 in run.sh (tamper → run_check 1 --ci → grep guard message → restore via trap).
**Step 2:** Run `AGENT_INFRA_PATH=$PWD bash tests/drift/run.sh` → case 9 FAILS (guard absent, exit 0).
**Step 3:** Implement guard: `const checkCi = manifest.check && manifest.check.ci; if (ci && ci.ref && checkCi && checkCi.ref && checkCi.ref !== ci.ref) { issues.push({type:'ci-ref', entry:'manifest.json', tier:'fail', reason:\`check.ci.ref ≠ ci.ref (#387)\`}); console.log(...); }`
**Step 4:** Re-run run.sh → 9/9 green.
**Step 5:** Commit.

### Task 2: unit-test capability (templates → materialize)

**Intent:** Deliver the reusable unit-test job — the capability that makes hand-rolling unnecessary (the #2044 root cause).
**Acceptance:** `templates/.github/workflows/node-ci.yml` has the `unit-test` job with the 4 inputs + 2 boolean skip inputs (`default: true` explicit — GitHub boolean inputs default false); materialized copy identical; both YAML files parse clean (block-style `with:` only).
**Files:**
- Modify: `templates/.github/workflows/node-ci.yml` (new inputs + `unit-test` job + job-level if: guards on script-validate/skill-lint + extended #254 message + header contract docs)
- Modify: `.github/workflows/node-ci.yml` (via `bash scripts/sync-ci-workflows.sh`)

**Step 1:** Edit template per the verified YAML sketch (scoping plan §file-by-file) — job-level `if: inputs.script-validate` / `if: inputs.skill-lint`; `unit-test` job with `if: inputs.test-command != '' || inputs.test-glob != ''` and TWO steps (Custom test command `if: inputs.test-command != ''` → `run: ${{ inputs.test-command }}`; Glob-based node --test `if: inputs.test-command == '' && inputs.test-glob != ''` → `run: node --test ${{ inputs.test-glob }}`); block-style `with:`; input `description:`s (test-command: overrides test-glob when both set; MUST NOT contain `${{`).
**Step 2:** Run `bash scripts/sync-ci-workflows.sh`.
**Step 3:** Verify `diff templates/.github/workflows/node-ci.yml .github/workflows/node-ci.yml` empty AND `python3 -c "import yaml; yaml.safe_load(open('templates/.github/workflows/node-ci.yml'))"` parses.
**Step 4:** Commit.

### Task 3: dogfood in ci-main.yml

**Intent:** Prove the capability in the workflow-owning repo before consumers pin it (first real run of the `test-command` path; verify-before-tag gate's subject).
**Acceptance:** `extension-tests` job name KEPT (auto-file-on-failure `needs:` at :116 stays valid); body swapped to the node-ci.yml@main call with the full accumulator as `test-command` + `script-validate: false` + `skill-lint: false`; no test suite dropped (grep invocation counts match).
**Files:**
- Modify: `.github/workflows/ci-main.yml` (extension-tests body → uses: call; auto-file-on-failure needs: untouched)

**Step 1:** Replace the inline extension-tests steps with the `uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main` call per the verified snippet (scoping plan §file-by-file — accumulator verbatim: 8 suites, `$((failures+1))`, terminal `✅ All extension tests passed`; no `${{`).
**Step 2:** Verify YAML parses; grep-count `node ` + `npx tsx` invocations before/after → identical.
**Step 3:** Commit.

### Task 4: release axis (ONE commit — manifest + fixture + docs)

**Intent:** The coordinated ci.ref bump that makes the new job visible to version-pinned consumers; every consumer-facing surface moves in one commit so no drift-check can red mid-sequence.
**Acceptance:** manifest ci.ref AND check.ci.ref → v0.1.1; fixture docs-ci.yml:11 → @v0.1.1; drift-check.yml:12 doc fixed (manifest.ci.ref); run.sh header stale-symlink comment fixed; `"version": "0.1.0"` unchanged (grep-asserted); run.sh 9/9 + ci-ref-check.test.mjs green.
**Files:**
- Modify: `manifest.json`, `tests/fixtures/drift/current/.github/workflows/docs-ci.yml:11`, `.github/workflows/drift-check.yml:12`, `tests/drift/run.sh` (header)

**Step 1:** Apply the four edits (co-bump + fixture + doc fix + header) in one commit.
**Step 2:** Verify `bash tests/drift/run.sh` → 9/9; `node scripts/ci-ref-check.test.mjs` → green; `grep -q '"version": "0.1.0"' manifest.json`.
**Step 3:** Copy scoping/research artifacts (docs/scoping/*, docs/research/2026-08-30-387*) into the commit; Commit → PR #1 (commit-workflow).

### Task 5: gate + tag v0.1.1

**Intent:** Release the capability to consumers only after the dogfood provably ran green (kills the tag-race).
**Acceptance:** tag v0.1.1 exists at the step-1 merge commit; gate assertions all pass.
**Files:** none (release ops)

**Step 1:** Merge PR #1 (commit-workflow).
**Step 2:** JOB-LEVEL gate: `gh run list --workflow=ci-main.yml --commit <merge-sha> --json databaseId,headSha,status,conclusion` → select run with headSha == merge-sha (latest; empty = HARD ABORT) → `gh run view <id> --json jobs --jq '.jobs[] | select(.name=="extension-tests") | {status,conclusion}'` == completed/success; `gh run view <id> --log` contains `✅ All extension tests passed`.
**Step 3:** Assert `[ "$(git rev-parse origin/main)" = "<merge-sha>" ]` (is-ancestor also checked).
**Step 4:** `git tag v0.1.1 <merge-sha> && git push origin v0.1.1`; verify `git ls-remote --tags origin`.

### Task 6: premise-labs pin bump (step 3)

**Intent:** Move the wired consumer onto the new ref so the post-lift pin compare is green.
**Acceptance:** docs-ci@v0.1.1 + python-ci@v0.1.1 in premise-labs ci.yml; drift-check@main untouched; stale exemption-claim comment reworded; PR green (vacuous).
**Files:**
- Modify: `premise-labs/.github/workflows/ci.yml`

### Task 7: tortoise wiring + migration (step 4)

**Intent:** Remove the #2044 drift instance (inline dashboard-js-tests) and wire drift-check — the migration deliverable.
**Acceptance:** `dashboard-js-tests` uses node-ci.yml@v0.1.1 (no inline job); agent-infra-ci → python-ci@v0.1.1; drift-check job added (drift-guard.yml disambiguation comment); stale "Self-contained CI" header corrected; local `node --test src/*.test.js` in website/apps/dashboard passes; PR CI green.
**Files:**
- Modify: `tortoise/.github/workflows/ci.yml` (base on FRESH origin/main — local main is 137 behind; `git fetch origin main && git reset --hard origin/main` first)

### Task 8: exemption lift (step 5 — activation moment)

**Intent:** Activate the #303 pin/symlink enforcement on the two wired consumers — the enforcement half of the confirmed root cause.
**Acceptance:** preflight (both consumer PRs merged — `git fetch <consumer> main && git show FETCH_HEAD:.github/workflows/ci.yml | grep @v0.1.1`) passes; exemptions removed for tortoise + premise-labs (JSON-safe `_note` keys on remaining entries incl. eldato-outreach); local sanity `node bin/agent-infra.js check <repo> --ci` shows `✅ ci-ref — all agent-infra pins @v0.1.1`.
**Files:**
- Modify: `manifest.json` (exemptions)

### Task 9: non-vacuous verify (step 6)

**Intent:** Prove the contract is genuinely live (not an exemption skip).
**Acceptance:** both consumers' next PR drift-check logs show CI-surface lines clean: `✅ ci-ref — all agent-infra pins @v0.1.1` + D3 symlink-sweep green + no `⏭️ exempted` for templates/.github/workflows/; ls-remote shows v0.1.1; manifest.version still 0.1.0.
**Files:** none (verification)

## Review record (plan-review gate)
This plan is the formalized output of issue-scoping #387 (v5.1 double diamond), which passed: problem-verify 5 cycles, solution-verify 3 cycles, second-model coherence (deepseek-v4-pro), and Phase 7 parallel review gates 3 cycles (codebase/docs + devil's advocate + workflow mechanics) — all converging to NO P0/P1 across 8+ verified review cycles. The plan-review gate is documented as satisfied by that record (proportional-gates: judgment-based gating; the content was re-reviewed by fresh-context agents at every cycle).
