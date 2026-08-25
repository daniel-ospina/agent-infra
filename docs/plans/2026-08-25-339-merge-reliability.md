---
title: "Plan: #339 — recurring 'main broken by merge' (18 issues) — post-merge CI blind-spot analysis + fix design"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-25
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-339, ci-main.yml, node-ci.yml, github-actions, post-merge-validation
---

# Plan: #339 — "main broken by merge" cluster — research note + fix design

> Research phase only. No CI changes implemented. Design options + recommendation below.

## TL;DR

All 18 auto-filed "main broken by merge" issues trace to **4 root causes, not 18 bugs** — and every
one of them is a **check that exists only in the post-merge workflow (`ci-main.yml`) and never runs
pre-merge**. The pre-merge required gate (`ci.yml` → `node-ci.yml`) was green on every sampled
breaking PR because the failing assertions are in the post-merge-only check set. This is a
**coverage asymmetry** (post-merge runs a strict superset of repo-wide invariant checks), not
merge-base drift, not flakiness, not dependency churn. The auto-file bot then re-filed the same
latent reds on every subsequent push — the I4 text drift alone accounts for 16 of the 18 issues;
a second invariant (raw `PI_MODE` read) co-failed on ~15 of those.

The cluster is already fixed on main (`34c40c2` #330, 2026-08-21; ci-main green 7/7 since). The
open work is systemic: **align the pre-merge check set with the post-merge invariants, and make the
auto-file bot dedupe by failure signature**.

## 1. Failure cluster table

Evidence: 18 auto-filed issues (all still open), sampled 17/18 via `gh run view <run> --log-failed`.
Each issue body is boilerplate ("Post-merge CI failed on main at <sha>", run URL) — the failing job
and assertion were extracted from the run logs.

Note on co-failing assertions: the raw-`PI_MODE`-read wiring violation (#325) red'd **every**
extension-tests run from `7ccce2e` (08-14) through `5ddf572` (08-20) — i.e. 16 runs — so most
Class-A rows also carried the wiring assertion. The table lists the *distinct* assertion classes per
row; see §2 for the per-window timeline.

| Issue | Merge sha | Date | Failing job(s) | Failing assertion | Class |
|---|---|---|---|---|---|
| #259 | bef7989 | 08-13 | extension-tests | auto-sync.test.ts: `git commit` failed in temp clone | **C′** |
| #275 | 7ccce2e | 08-14 | extension-tests | print-mode-wiring: raw `process.env.PI_MODE` read remains in `verification-gate/index.ts` | **C** |
| #276 | 09fbe77 | 08-14 | extension-tests | I4 "found 2" + wiring raw-read (2 files failed) | **A+C** |
| #278 | — | 08-14 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #283 | — | 08-15 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #288 | — | 08-15 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #290 | — | 08-16 | extension-tests | I4 "found 2" + wiring raw-read (verified) | **A+C** |
| #294 | — | 08-16 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #297 | — | 08-17 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #300 | — | 08-17 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #302 | 3071dbb | 08-19 | extension-tests | I4 "found 2" + wiring raw-read (verified) | **A+C** |
| #312 | fa720b8 | 08-19 | extension-tests | I4 "found 2" + wiring raw-read | **A+C** |
| #313 | 18744a2 | 08-19 | extension-tests + script-validate | I4 "found 2" + wiring raw-read + 2 bash failures (verified) | **A+B+C** |
| #314 | 3e8bdb6 | 08-19 | extension-tests + script-validate | I4 "found 2" + wiring raw-read + bash/installer | **A+B+C** |
| #315 | c03da2c | 08-19 | extension-tests + script-validate | I4 "found 2" + wiring raw-read + 2 bash failures | **A+B+C** |
| #319 | 1f34bb0 | 08-20 | extension-tests + script-validate | I4 "found 2" + wiring raw-read + bash/installer | **A+B+C** |
| #322 | 5ddf572 | 08-20 | extension-tests + script-validate | I4 "found 2" + wiring raw-read + 2 bash failures | **A+B+C** |
| #328 | 5273695 | 08-20 | extension-tests + script-validate | I4 "found 2" + 1 bash failure (wiring already fixed by #327) | **A+B** |

`skill-lint` was green in **8/8 sampled runs** — it is the only post-merge job whose check set also
runs pre-merge with identical assertions (`node-ci.yml` skill-lint → `check-skill-lint.mjs`), and it
is never the failure. That one data point is the diagnosis.

The extraction pipeline eventually root-caused the cluster into 4 micro issues, all closed by
#327/#330: **#324** (daily-backup.sh bash syntax, fixed #327), **#325** (print-mode-wiring, fixed
#327), **#326** (I4 drift, fixed #330), **#329** (install-launchd.test.sh on Ubuntu, fixed #330).

## 2. Root-cause hypothesis per class

### Class A — I4 content drift (16 issues, #276→#328) — the dominant signal

- `extensions/shared/test-never-unbounded.mjs` asserts each launch-path skill contains **exactly one**
  `Never launch an unbounded nested pi` rule block (I4 of #206).
- Drift: `skills/using-git-worktrees/SKILL.md` accumulated a **2nd occurrence** — PR #270's merge
  (`09fbe77`, 08-14) added the heading `### Never launch an unbounded nested pi (#206) — hard rule`
  while the blockquote rule already existed (`a79537c` did NOT touch the rule text; verified via
  diff). #330's commit message names it: "the section heading + the blockquote rule".
- **Why pre-merge was green:** no pre-merge workflow runs `test-never-unbounded.mjs` (or any
  `extensions/*/test*.mjs`). `check-skill-lint.mjs` (the pre-merge skill check) is frontmatter-only
  and never inspects rule-block count. The drift lived in PR #270's own content — running the test on
  that PR head would have red'd it.
- **Why 16 issues:** the red sat on main from 08-14 → 08-21 (6 days). `auto-file-on-failure` files a
  fresh issue on **every** push to main; no dedupe by signature; the issue body carries only a run
  URL. 16 pushes → 16 identical issues.

### Class B — bash validation + installer test (6 issues, #313→#328)

- Added post-merge-only by #304 (`2eda35d`, 08-19): `bash -n scripts/*.sh` + `install-launchd.test.sh`
  in `ci-main.yml`'s script-validate step. Pre-merge `node-ci.yml` runs `node --check` only.
- Sub-failures: **#329** — `install-launchd.test.sh` used BSD-only `sed -i ''` syntax (5 sites); on
  Ubuntu (GNU sed) the empty arg is treated as the script → crash → `set -e` abort. The test passes
  40/40 on macOS. **Environment/portability failure, deterministic on the Ubuntu runner.**
- Sub-failures: **#324** — daily-backup.sh bash syntax error.
- **Why pre-merge was green:** the step (and the test file) simply never ran pre-merge. The test was
  authored and validated on macOS only; the first-ever Ubuntu execution was the post-merge run.

### Class C — repo-wide wiring invariant, regressed mid-PR (16 runs, #275→#322)

- `print-mode-wiring.test.ts` enforces a repo-wide invariant: **zero** raw `process.env.PI_MODE`
  reads (`#228` acceptance). The #258 sweep (merged `bef7989`) left the tree green; the raw read in
  `verification-gate/index.ts` was **re-introduced by review-fix `673d580` inside PR #264** (merged
  `7ccce2e`, 08-14) — a regression, not refactor incompleteness. It red'd **every** extension-tests
  run until `5273695` (#327, 08-20) fixed it — 16 runs, co-occurring with Class A from #276 on.
- `#259` (auto-sync.test.ts temp-clone `git commit` failure) is a **separate, isolated** class-C′
  event — it did not recur; exact cause not root-caused in this pass (candidate: fresh-runner git
  identity or a transient in the merged tree).
- Both invariants are enforced **only** by extension tests that run **only** post-merge.

## 3. The blind spot (unifying mechanism)

Two workflows with different check sets:

| Job | Pre-merge (`node-ci.yml` via `ci.yml`) | Post-merge (`ci-main.yml`) |
|---|---|---|
| script-validate | `node --check` only | `node --check` + `bash -n` + `install-launchd.test.sh` |
| skill-lint | `check-skill-lint.mjs` (frontmatter) | `check-skill-lint.mjs` (identical assertions) |
| extension tests | **none** | ci-ref-check + `extensions/*/test*.mjs` glob + print-mode + wiring + auto-sync |
| typecheck/lint | yes (tsconfig/eslint-gated) | no |

- Every check that exists **only** in `ci-main.yml` is a deterministic post-merge red zone: content
  drift (A), bash portability (B), wiring regression (C).
- The auto-file bot converts each push during a red window into a new issue, so **one latent drift =
  N issues**. Issue bodies lack the failing job/assertion, making the cluster unactionable until
  manually audited.
- **Tortoise contrast (per mandate):** tortoise's polarity is inverted-by-design and sound —
  `python-ci.yml` runs the full matrix (fast + `slow_files` from `config/ci-surfaces.yml`, #1371) on
  push:main, and `post-merge-validation.yml` dedups against that push-run (#1474) and falls open to a
  fast-gate subset when absent (#1439). Post-merge never runs a check pre-merge didn't — the class of
  blind spot here **cannot occur there**. agent-infra's `ci-main.yml` inverts this: post-merge runs
  MORE than pre-merge.

**Conclusion for the mandate:** the failures pass pre-merge (PR head) and fail on the merged tree
not because of merge-base drift, slow_files exclusion (#798/#1371/#1439 apply to tortoise's python
split, not agent-infra's node workflows), or env drift — but because the failing checks are
**structurally absent from the pre-merge gate**. Quantification: 18/18 issues came from
post-merge-only checks; every sampled breaking PR (#301/#306/#311/#318/#321/#330) had all required
`ci/*` jobs green at merge time (#301/#311 additionally merged with the non-blocking
`pipeline-compliance` check red).

## 4. Fix options

### Option 1 — Align the check sets (recommended, primary)

Move the post-merge-only invariant checks into the pre-merge gate:

- Add to `node-ci.yml` (or a new job in `ci.yml`): the `extensions/*/test*.mjs` glob +
  ci-ref-check + print-mode-wiring + auto-sync (the fast, deterministic invariant core), plus
  `bash -n` on `scripts/*.sh`.
- Keep env-specific checks (e.g. `install-launchd.test.sh` behavior on Ubuntu) post-merge-only, but
  with the #330 skip-guards so they cannot red deterministically.

**Trade-offs:** (+) closes the asymmetry at the source — every class-A/B/C failure would have red'd
the PR before merge (verified: the drift was in PR #270's own head content); (+) tests are seconds
each, PR CI cost ~+1–2 min. (−) requires a workflow change in the pinned template (#303 version
contract) and re-sync of consumers via `scripts/sync-ci-workflows.sh`; (−) post-merge still catches
true merge-interaction bugs (PR A + PR B) — alignment reduces, not eliminates, that residual.

### Option 2 — Auto-file bot: dedupe by signature + actionable body (recommended, secondary)

- In `ci-main.yml`'s `auto-file-on-failure`: fetch failing job + first failing assertion from the run
  (actions API), and **dedupe**: if an OPEN issue already exists with the same signature (workflow +
  job + assertion), comment the new run on it instead of filing a new issue (and optionally close the
  duplicate).
- Include the failing job/assertion in the issue body (today: run URL only).

**Trade-offs:** (+) collapses 16 duplicates → 1 issue; (+) makes each issue actionable; (+) cheap
(one `github-script` step). (−) does not stop main from going red — it stops the issue spam and
speeds convergence.

### Option 3 — Block-merge on red ci-main (tertiary safety net)

Add ci-main as a required status check / merge-block guard: if the latest ci-main run on main is
red, block further merges (or warn loudly).

**Trade-offs:** (+) prevents compounding a red window (would have frozen merges after the first red
on 08-14); (−) does not fix the underlying asymmetry — a red main stays red until a human fixes it;
(−) contradicts the #86 design intent (backstop that files, not a gate). Not recommended as the
primary fix; fine as a belt-and-suspenders guard after Option 1.

### Option 4 — slow_files-style realignment (mirror tortoise #1371/#1439)

Restructure ci-main to a defined invariant subset + keep the full check set on push:main elsewhere.
**Rejected for agent-infra:** the tortoise split exists to keep a 60-min-cap python suite fast;
agent-infra's node checks are seconds. The asymmetry fix here is the opposite direction (add to
pre-merge, Option 1), not carve-out.

## 5. Recommendation

1. **Option 1 (primary):** align the pre-merge gate with the post-merge invariant checks — extension
   tests (the `extensions/*/test*.mjs` glob + wiring/print-mode + auto-sync) + `bash -n` validation in
   `node-ci.yml`, env-specific installer test kept post-merge-only with skip-guards. This kills the
   mechanism that produced 18/18 issues (the A/C/B regressions were all present in the PR heads).
2. **Option 2 (secondary, independent):** dedupe + assert-detail the auto-file bot. Guarantees one
   latent failure = one issue, and makes the next cluster self-resolving.
3. **Cleanup (free):** close the 18 stale "main broken by merge" issues (fixed by #327/#330 since
   08-21; ci-main green 7/7) and link them to #339. Note also #301/#311 merged with
   `pipeline-compliance` red (non-blocking check) — a milder, separate gate weakness, out of scope.

Not in scope: tortoise python split (#798/#1371/#1439) — verified sound; no change needed there.

## Evidence trail

- 18 issue bodies: `gh issue view <n> --repo daniel-ospina/agent-infra` (boilerplate: run URL only)
- 17 run logs: `gh run view <id> --repo daniel-ospina/agent-infra --log-failed`
- Pre-merge PR CI green: PRs #306/#311/#318/#321/#330 (all `ci/*` jobs pass)
- Drift origin: `09fbe77` (#270) — added the rule-text heading alongside the blockquote rule; fixed
  `34c40c2` (#330). Wiring regression origin: `673d580` (review-fix in PR #264, merged `7ccce2e`),
  fixed `5273695` (#327)
- Post-fix ci-main: green 7/7 runs (2026-08-21 → 08-25)
- Root-cause issues: #324/#325/#326/#329 (all closed via #327/#330)
