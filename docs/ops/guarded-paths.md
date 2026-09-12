---
title: "Guarded Paths — CODEOWNERS coverage of the enforcement surfaces (#667)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-667, issue-640, issue-646, issue-669, issue-713, codeowners, pipeline-compliance
---

# Guarded Paths — who owns the guards (#667)

One place that pins **which paths in `agent-infra` require an owner review**,
and why. The machine-readable copy is `.github/CODEOWNERS`; this table is the
reviewable contract and **must match it**. Plan: `docs/plans/2026-09-10-issue-667-codeowners.md`.

**The problem class (#667):** the repo's enforcement surfaces — the
pin/version guards, the pipeline gate, and the CI workflows that implement the
required `pipeline-compliance` check — had **no owner at all**. Guard `(h)`
(the pi pin-lockstep tripwire, #637) was authored inside the very PR it guards
(#640) by the agent changing the files it checks, and a later cycle found the
guard could be satisfied by a decoy line. A guard that any future PR can
silently retire is not a guard.

**Owner:** `@daniel-ospina` — the repo's sole maintainer
(`gh api repos/daniel-ospina/agent-infra --jq .owner.login`). No team handle is
invented; there is no team with write access to this repo.

---

## 1. Guarded paths

| Path (CODEOWNERS pattern) | What it is / why it is guarded |
|---|---|
| `/.github/CODEOWNERS` | Ownership of the guards. Documented by GitHub as required for full protection: "To protect a repository fully against unauthorized changes, you also need to define an owner for the CODEOWNERS file itself." |
| `/.github/workflows/` | All workflows. `pipeline-compliance.yml` implements the repo's **only required status check** (`pipeline-compliance`); renaming its job is **fail-closed** — the context is then never reported, so GitHub parks the PR at "Expected — Waiting for status to be reported" and blocks the merge. The quiet bypass is editing the job body, or the script it runs, so it always exits 0. `ci.yml` / `ci-main.yml` carry the pin-lockstep and frontmatter legs. |
| `/templates/.github/workflows/` | Materialization source for the reusable workflows (`node-ci.yml`, `python-ci.yml`, `docs-ci.yml`). `pipeline-compliance.yml`'s `workflow-drift` job diffs template ↔ committed copy, so the template is the real edit target. |
| `/scripts/check-pipeline-compliance.sh` | The pipeline gate. Decides **every** merge; a PR's edits to it are tested by the gate itself. |
| `/scripts/check-skill-lint.mjs` | Skill-frontmatter linter (fail-closed gate, #254). |
| `/scripts/check-skill-lint.test.mjs` | Carries the pin-lockstep guards `(h)`/`(i)`/`(j)` (#637) — the exact file #667's target names. |
| `/scripts/check-skill-lint.oracle.test.mjs` | Loader-parity oracle against a real pi bundle — the only gate comparing repo state to upstream pi. |
| `/scripts/frontmatter-validate.mjs` | Dependency-free frontmatter validator (the CI gate the hook defers to). |
| `/scripts/frontmatter-fixtures.mjs` | Fixture corpus **and** the canonical `PI_VERSION_PIN` literal. |
| `/scripts/probe-frontmatter-fixtures.mjs` | Regenerates the corpus and resolves the real pi bundle; the write-half of the frontmatter guard. |
| `/scripts/check-staged-skill-frontmatter.mjs` | Authoring-time pre-commit frontmatter gate (`.husky/pre-commit`). |
| `/scripts/record-review.sh`, `/scripts/record-review.test.sh` | Writes the review verdict the merge registry gate reads (production copy is refreshed from this repo copy); its test is guarded for the same reason as the other tests. |
| `/extensions/review-enforcer/index.ts`, `/extensions/review-enforcer/index.test.ts` | In-session merge-registry gate: refuses to merge without a recorded review verdict. The test is guarded too — a weakened test is a weakened guard. |
| `/extensions/verification-gate/index.ts`, `/extensions/verification-gate/index.test.ts`, `/extensions/verification-gate/index.e2e.test.ts` | Pass-contract gate (VGATE) that blocks premature completion claims. |
| `/AGENTS.md` | The behavioral contract the guards encode. |

## 2. Explicitly NOT guarded (and why)

| Path | Why not |
|---|---|
| `docs/**` (incl. `docs/plans/*`) | #667's open decision 3. `docs/plans/*` is the artifact `check-pipeline-compliance.sh` **reads** (check (d)), not the gate. Guarding it would name the owner on every plan-doc pattern — which, per §3, has no observable effect in a single-writer repo — while it cannot weaken the gate, since the check logic lives in the guarded script. #667 non-goal: "Reviewing docs or content paths generally." |
| `extensions/review-enforcer/{package.json,package-lock.json}` and the same for `verification-gate` | Dependency manifests. The pin-lockstep guard `(h)` *reads* `extensions/*/package.json`; the guarded artifact is the guard (`check-skill-lint.test.mjs`), not each manifest. Owner-reviewing every lockfile bump is noise without protection. |
| `extensions/sequence-enforcer/**` | Adjacent gate (skill-sequence discipline) but not a merge/verdict gate. Deliberately out of #667's named scope; add here if it starts judging PRs. |
| `.husky/pre-commit`, `templates/.husky/pre-commit` | Local hook, not the judge; it cannot weaken the required check. The merge-relevant checks it runs are mirrored in CI (`check-cost-config.sh` → `ci.yml` cost-config + `ci-main.yml`; `check-pi-config-extensions.sh` → `ci.yml` pi-config-extensions + `ci-main.yml`; the `.agent-infra-version` pin → `drift-check.yml`). Two legs are local-only — `check-agents-materialized.sh` and `check-staged-skill-frontmatter.mjs` — and are deliberately not CI-mirrored. (The hook is also currently dead in agent-infra: husky is not installed, so `core.hooksPath` is unset — #672.) |
| `scripts/sync-ci-workflows.sh`, `scripts/check-workflow-actionlint.sh`, `scripts/ci-ref-check.cjs` | Auxiliary CI plumbing. Owning these is not what protects the gate: the check runs the **PR's own checked-out copy** of `pipeline-compliance.yml` + `check-pipeline-compliance.sh` — a deliberate no-auto-fetch design recorded in the workflow header — so a PR that rewrites the gate is graded by its rewrite. That exposure is real and tracked as **#713**; it is not closed by owning these three files. |
| `templates/AGENTS.base.md` | Distribution source for consumer repos, not agent-infra's own rules. `AGENTS.md` (this repo's copy) is guarded. |
| `tests/fixtures/drift/current/AGENTS.md` | Drift-check fixture, not the rules. |
| Everything else | No catch-all `*` rule — #667 explicitly excludes general source/content review. |

## 3. What this does and does not enforce

- **Does (as of #667):** records the path list and names the owner on each pattern. In this repo that has **no observable effect today**. GitHub's only two CODEOWNERS behaviours are auto-requesting a review and blocking a merge when code-owner review is required; both are void here (next bullet), and there is no third "annotation" behaviour — nothing is attributed, displayed or enforced.
- **Does NOT (verified 2026-09-10):** produce a visible *requested reviewer* in this repo today. GitHub does not request a review from the PR author, and `@daniel-ospina` is the repo's only collaborator — so every PR is authored by the sole code owner. #667's indicator (2) is therefore **unmet as observable behaviour** and is tracked as **#669**. Consequently the list itself can currently be changed by any PR — the patterns are inert today, not advisory-with-a-report.
- **What would make it bind — all four settings, not three (verified 2026-09-10):**
  1. `required_pull_request_reviews` enabled — it is `null` today, so no review is ever required;
  2. `require_code_owner_reviews` enabled within it — otherwise any approval satisfies it;
  3. a **second approving identity** — the sole writer cannot approve their own PR (**#669**);
  4. **`enforce_admins: true`** — `false` today, so the sole admin's own PRs stay mergeable via "Merge without waiting for requirements".

  (4) is also why the earlier *deadlock* framing was wrong: with `enforce_admins: false` this is not a hard deadlock but an **every-merge admin override** — the same net security effect, with more friction. Conversely, resolving #669 without (4) would still leave the control self-overridable by the sole admin. #646 is unrelated throughout: it makes a code *status check* required, not a review.
- **Does not (yet):** *block* a merge, and it would not even with required code-owner review switched on while `enforce_admins: false`. Branch protection requires only the `pipeline-compliance` status check and `required_pull_request_reviews` is `null`. #667 deliberately pulls none of the four levers above.
- **Drift:** this list lives in two files (`.github/CODEOWNERS` and this table)
  and is currently kept in sync by **inspection only**; a deterministic
  doc↔CODEOWNERS drift test is scoped as **#670**.
- **Bootstrap ordering:** GitHub reads CODEOWNERS from the PR's **base**
  branch, so the file that adds ownership (#667's own PR) is not itself
  covered. Ownership starts with the next PR that touches a guarded path
  after this merges.
