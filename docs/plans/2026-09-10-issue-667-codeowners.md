---
title: "#667 — CODEOWNERS for the enforcement surfaces — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-667, issue-637, issue-640, issue-646, issue-669, issue-713, codeowners
---

# #667 — CODEOWNERS for the enforcement surfaces — Scope & Plan

## Confirmed Problem

Verified 2026-09-09/10 while landing #640 (pi 0.85.1 bump):

```
$ ls .github/CODEOWNERS
ls: .github/CODEOWNERS: No such file or directory

$ gh api repos/daniel-ospina/agent-infra/branches/main/protection \
    --jq '{reviews:.required_pull_request_reviews, checks:.required_status_checks.contexts}'
{"reviews":null,"checks":["pipeline-compliance"]}
```

There is **no owner gate on any path** and no required review of any kind.
This is not theoretical: guard `(h)` (the pi pin-lockstep tripwire) was authored
inside the very PR it guards (#640) by the agent changing the files it checks,
and a later cycle found the guard could be satisfied by a decoy line while the
gate stayed unplugged — with the fix for that being another edit to the same
file. The #637 plan records the resulting bound honestly: a test that reads repo
files cannot defend against a commit that edits the guard and the workflow
together. That residue is the class #667 addresses (who may change the checker),
complementing #646 (does a red check block a merge).

## Decisions (issue open decisions 1–4)

1. **Owner — `@daniel-ospina`.** Verified sole maintainer via
   `gh api repos/daniel-ospina/agent-infra --jq .owner.login`. No team handle is
   invented (no team has write access). **Correction (review cycle 1, #669):**
   the working assumption that CODEOWNERS "still produces a visible requested
   review" is false here — GitHub does not request a review from the PR author,
   and the sole writer authors every PR. What this PR actually delivers is the
   ownership path list itself; the visible requested review is *not* observable
   until a second writer exists (#669). **Premise-correction pass:** the
   earlier wording called this an "ownership annotation" — GitHub has no such
   behaviour (its only two are auto-requesting a review and blocking when
   code-owner review is required), so the honest phrasing is **no observable
   effect today**.
2. **`required_pull_request_reviews` is NOT enabled.** It is a branch-protection
   change and is out of scope for #667; recorded as a follow-up in the PR body.
   CODEOWNERS is therefore inert now, and it stays inert after #646:
   #646 makes a code **status check** required — it does not touch
   `required_pull_request_reviews`. Making code-owner review binding needs (a)
   that setting enabled, (b) `require_code_owner_reviews` enabled within it,
   (c) a second approving identity, because the sole writer cannot approve
   their own PR (#669), **and (d) `enforce_admins: true`** — false today, so
   without it the sole admin's own PRs remain mergeable via "Merge without
   waiting for requirements". #646 is therefore neither necessary nor
   sufficient for CODEOWNERS to block. Corrected in review cycle 3; (d) added in
   the premise-correction pass, which also dropped the "hard deadlock" framing —
   with `enforce_admins: false` it is an every-merge admin override.
3. **Path list — enforcement surfaces only**, no catch-all:
   `.github/CODEOWNERS`, `.github/workflows/`, `templates/.github/workflows/`,
   `AGENTS.md`, the pipeline gate, the pin/version/frontmatter guard family,
   `scripts/record-review.sh` **and its test** `scripts/record-review.test.sh`
   (added in review cycle 1 — it runs in `ci-main.yml:189` and guards the verdict
   writer the pipeline gate depends on), and the review-enforcer /
   verification-gate sources + tests. `docs/plans/*` is **excluded**: it is the
   artifact the gate reads (check (d)), not the gate; guarding it is docs review
   by the back door. Full table + exclusions: `docs/ops/guarded-paths.md`.
4. **Bootstrap ordering — recorded.** GitHub reads CODEOWNERS from the PR's
   *base* branch, so this file's own PR is not covered; ownership starts with
   the next PR touching a guarded path after merge.

## Plan

1. Add `.github/CODEOWNERS` (GitHub syntax: gitignore-style patterns,
   last-match-wins, one owner per line, no `!`/`[ ]`/escaped `#`). Every entry
   is an explicit `/`-anchored path — no catch-all, per the #667 non-goal.
2. Add `docs/ops/guarded-paths.md` — the single documented list (guarded paths,
   explicit non-guarded paths with reasons, and the inertness/branch-protection
   boundary). `docs/ops/*.md` is the established policy home for this repo
   (see `docs/ops/cost-config-policy.md`, `docs/ops/session-lifecycle-contract.md`).
3. Add this plan doc.
4. Verify: local syntax sanity check of every CODEOWNERS line (a throwaway
   validator: every line is `<pattern> <owner…>`, no `!`/`[ ]`, every pattern
   resolves case-sensitively via `git ls-files`, and the pattern set equals the
   §1 table); every guarded path exists in the tree;
   `bash scripts/check-workflow-actionlint.sh`; `node scripts/ci-ref-check.test.mjs`;
   `node scripts/check-doc-affiliation.cjs --files docs/ops/guarded-paths.md docs/plans/2026-09-10-issue-667-codeowners.md`
   (`--all` is red on `main` for unrelated pre-existing docs — #671).
   No workflow or branch-protection change.

## Review Cycle Log

- **cycle 1** — 3 fresh-context dispatches (code-reviewer, bug-scanner, VGATE).
  VGATE `PASS`; code-reviewer `NEEDS-FIX` **0 P0 / 0 P1 / 4 P2**; bug-scanner
  `NEEDS-FIX` **0 P0 / 0 P1 / 1 P2** — **5 distinct P2 total** (all confidence ≥ 60):
  1. Requested-review claim unverifiable with one writer → docs corrected; filed **#669**.
     *(code-reviewer, conf 65; bug-scanner, conf 60)*
  2. `.husky/pre-commit` "every check is also in CI" was false (`check-agents-materialized.sh`,
     `check-staged-skill-frontmatter.mjs` are local-only) → row rewritten with the real split.
     *(code-reviewer, conf 72)*
  3. "checked against each other" asserted a check that does not exist → reworded; drift test filed **#670**.
     *(code-reviewer, conf 68)*
  4. `scripts/record-review.test.sh` omitted while the file states "a weakened test is a weakened guard"
     → added to CODEOWNERS + §1. *(code-reviewer, conf 72)*
  5. Plan step-4 command failed as written (`check-doc-affiliation.cjs` needs `--files`) → fixed.
     *(bug-scanner, conf 95 — reported outside the code-reviewer's 4)*
- **cycle 2** — 3 fresh-context dispatches (code-reviewer, bug-scanner, VGATE).
  VGATE `PASS`; bug-scanner `NO ISSUES FOUND`; code-reviewer `NEEDS-FIX`:
  **0 P0, 0 P1, 3 P2**. All three were the cycle-1 overclaim surviving in
  files the cycle-1 fix round had missed:
  1. `.github/CODEOWNERS` still said the file "only produces review requests" /
     "it requests a review" → replaced with the ownership-ANNOTATION wording + #669.
  2. `docs/ops/guarded-paths.md` §3 "the list itself cannot change without that
     same review" → now states the list can currently change in any PR, and the
     row is advisory.
  3. `docs/ops/guarded-paths.md` §2 `docs/**` row "would request owner review on
     every plan doc" → now says it would only *attribute* the change.
- **cycle 3** — 3 fresh-context dispatches (code-reviewer, VGATE; the cycle-2
  bug-scanner scope — pattern/path resolution — was unchanged with 0 findings).
  VGATE `PASS`; code-reviewer `NEEDS-FIX`: **0 P0, 0 P1, 2 P2**. Both were
  documentation-consistency defects introduced by the earlier fix rounds:
  1. The stale "advisory until #646 lands" claim in decision 2 and the Out-of-Scope
     bullet contradicted the corrected decision-1 text → both rewritten to state
     that #646 governs required *status checks* only and is neither necessary nor
     sufficient; blocking needs the reviews setting + a second identity (#669).
  2. This Review Cycle Log was a dangling placeholder (AGENTS.md exit condition)
     and mis-attributed #669/#670 to cycle 2 → replaced with this full log.
  Fix round applied; cycle 4 re-review below.
- **cycle 4** — final fresh-context re-review (code-reviewer + VGATE). VGATE `PASS`;
  code-reviewer `NEEDS-FIX`: **1 P2** (conf 60) — this log's cycle-1 entry declared
  `4 P2` while enumerating five findings (the bug-scanner's broken-command item was
  uncounted) → count corrected to 5 P2 with per-finding provenance; other cycles'
  counts were already item-for-item. ⚠️ **Reviewer cap (4 cycles) reached — 0 open
  findings remain**; the applied fix is a count/provenance correction inside this
  log only (no claim in CODEOWNERS or `guarded-paths.md` changed), so no cycle-5
  re-dispatch was made. Final VGATE `PASS` recorded over the frozen file set.
- **premise-correction pass (post-cycle-4, human premise review)** — three
  explanatory sentences were found factually wrong after the cycle cap and
  corrected directly (a factual correction to prose, not a new design cycle;
  no finding in cycles 1–4 is reopened and no new claim is introduced):
  1. *Inverted:* "renaming its job silently disables the check" — a required
     context that is never reported leaves GitHub at "Expected — Waiting for
     status to be reported" and **blocks** the merge. Renaming is **fail-closed**.
     The real quiet bypass is editing the job body or the script so it always
     exits 0. Reworded in `.github/CODEOWNERS` and `guarded-paths.md` §1.
  2. *Misleading:* "the check runs the committed, guarded `pipeline-compliance.yml`
     + `check-pipeline-compliance.sh`" — contradicted by the workflow's own
     header (`pipeline-compliance.yml:14-18`): the gate runs the **checked-out**
     copy, by design, no auto-fetch. On `pull_request` that is the **PR head**,
     so a PR that rewrites the gate is graded by its rewrite. Reworded in
     `guarded-paths.md` §2 and filed as **#713**.
  3. *Incomplete:* the binding-precondition list gave three settings and omitted
     **`enforce_admins: true`** (false today). Added as a fourth in
     `.github/CODEOWNERS`, `guarded-paths.md` §3, decision 2 above, and the
     Out-of-Scope section. The "deadlock" framing was softened with it: with
     `enforce_admins: false` the result is an every-merge admin override, not a
     hard deadlock — same net security effect, more friction.
  4. *Imprecise (optional):* "ownership ANNOTATION" / "attributed" described a
     behaviour GitHub does not have (its only two are auto-requesting a review
     and blocking when code-owner review is required) → replaced with "no
     observable effect today".

  Also corrected in this pass: the PR body's `Closes #667` → **`Refs #667`** with
  **blocked-by #669** (the Objective and Target are not observable today, so
  closing would record a governance control as delivered), and a rebase onto
  current `origin/main`. No gate was added: the deferred drift test (#670)
  asserts a genuinely failable property (pattern set == documented set) and is
  left as its own issue rather than bolted onto this chore PR.

Out-of-scope findings filed rather than absorbed: **#669** (single-writer
requested review — found cycle 1, confirmed cycles 2–3), **#670**
(doc↔CODEOWNERS drift test — cycle 1), **#671**
(`check-doc-affiliation.cjs --all` red on `main` — cycle 1 bug-scanner),
**#672** (agent-infra's own pre-commit hook never runs; `npx lint-staged` has
no config — cycle 1 verification), **#713** (the gate grades a PR with that
PR's own gate script — premise-correction pass).

## Out of Scope / Accepted Residual Gaps

- Enabling `required_pull_request_reviews` (branch protection) is out of scope
  and is **not** #646: #646 covers required *status checks* only. CODEOWNERS
  cannot become binding until that setting is enabled, a second approving
  identity exists, **and** `enforce_admins: true` is set — without the last, the
  sole admin overrides at every merge rather than hitting a hard deadlock. The
  identity half is tracked as **#669**; the admin-enforcement precondition was
  added in the premise-correction pass. Noted in the PR body as the follow-up.
- Reviewing docs/content paths generally (explicit #667 non-goal).
- `extensions/sequence-enforcer/**`, dependency manifests inside the guarded
  extension dirs, `sync-ci-workflows.sh` and friends, and `.husky/pre-commit`
  are deliberately unguarded — reasons table in `docs/ops/guarded-paths.md` §2.
- A doc↔CODEOWNERS drift test is deliberately **not** added here (no new CI
  surface in a chore PR); the pattern set is a genuinely assertable property,
  verified by inspection/probe in this PR, and the automated form is filed as
  **#670**.
- CODEOWNERS cannot produce a visible requested review while the sole owner
  authors every PR, and required code-owner review would — with
  `enforce_admins: false` — amount to an admin override on every merge rather
  than a hard deadlock → **#669** (not #646, which covers required *status
  checks* only).
- The gate grades a PR with that PR's own checked-out copy of
  `pipeline-compliance.yml` + `check-pipeline-compliance.sh` (the workflow's
  documented no-auto-fetch design), so a PR that rewrites the gate is graded by
  its rewrite → **#713**. Unaddressed here deliberately: fixing it changes the
  gate's execution model, which is not a chore-PR change.
- Unrelated pre-existing findings filed while verifying: **#671**, **#672**.
