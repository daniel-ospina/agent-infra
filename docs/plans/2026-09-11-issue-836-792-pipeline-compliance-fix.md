---
title: "#836 + #792 — one PR: fix the pipeline-compliance broken-pipe false-negative and detect the artifact miss at preflight"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-836, issue-792, issue-823, issue-745, issue-488, check-pipeline-compliance, commit-workflow, pipeline-compliance
---

# Issues #836 + #792 — the `pipeline-compliance` gate: stop false-negating, and detect the miss earlier

**Issues:** [#836](https://github.com/daniel-ospina/agent-infra/issues/836) (bug) ·
[#792](https://github.com/daniel-ospina/agent-infra/issues/792) (improvement, `complexity:standard`)
· **Complexity:** standard · **Date:** 2026-09-11 · **Branch:** `fix/836-792-compliance`

One PR, because both issues are the **same mechanism**: `scripts/check-pipeline-compliance.sh`.
#836 fixes *what* the gate computes; #792 fixes *when* it is consulted. Splitting them would
produce two PRs editing the same hunks of the same script.

## Objective

1. **#836** — `check-pipeline-compliance.sh` never reports "no evidence" because of a broken
   pipe: when the evidence text contains a matching token, checks (c) and (e) PASS
   **deterministically**, regardless of how large the PR body + commit messages are.
2. **#792** — a `complexity:standard`/`complex` issue that was never scoped is detected **at
   preflight**, in seconds, instead of after the whole pipeline (tests + review loop + PR) has
   run and the merge has been blocked by the required status check.

## 1. #836 — root cause and fix

`run_checks`' evidence checks pipe a multi-KB string into `grep -q` under
`set -euo pipefail`:

```bash
if printf '%s' "$EVID_TEXT" | grep -qiE 'code-review|reviewer|...'; then   # check (c)
elif printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS" | grep -qiE 'tests...'; then  # check (e)
```

`grep -q` exits at the **first match** while `printf` is still writing. `printf` then gets
`SIGPIPE` (exit 141); with `pipefail` the **pipeline** status becomes 141, the `if` takes the
`else` branch, and the gate reports the evidence as **missing although it is present**.

It is a race, not a missing-token bug. Measured against the same revision (PR #823):
9 matches in the PR body / 6 in commits for (c), 16 / 33 for (e); a re-run of the identical job
passed; on a later run of the same PR (e) passed while (c) failed with the same
`line 410: printf: write error: Broken pipe`. Observed failure rate while merging #823: **3 of 4
runs**.

**Reproduced locally before the fix** (bash 3.2.57, 66 KB evidence text, 25 runs):

```
input bytes: 66022
OLD idiom (printf | grep -q): 20/25 runs reported 'no evidence'
NEW idiom (here-string):      0/25 runs reported 'no evidence'
```

and across input sizes (30 runs each):

| input | OLD false-negatives | NEW false-negatives |
|---|---|---|
| 1 KB | 0/30 | 0/30 |
| 8 KB | 0/30 | 0/30 |
| 64 KB | 0/30 | 0/30 |
| 256 KB | 30/30 | 0/30 |
| 1 MB | 30/30 | 0/30 |

**Fix:** a here-string has no reader process to close the write end — `grep -q` reads the
heredoc/here-string to EOF, so no `SIGPIPE` can reach the writer. The two patterns are hoisted
into single-source-of-truth constants (`REVIEW_EVIDENCE_RE`, `TEST_EVIDENCE_RE`) plus named
matcher functions (`has_review_evidence`, `has_test_evidence`) so the **regression test exercises
the production code path**, not a copy of the pattern.

### The same antipattern elsewhere in the script (fixed in the same pass)

Every `printf … | grep -q …` site is a latent race; the *direction* of the resulting error
differs per call site, which is why each is fixed rather than only (c)/(e):

| Site | Check | Old form | Error direction if it races |
|---|---|---|---|
| ~line 278 | `pr_is_docs_only` "all paths under docs/" | `! printf … \| grep -qvE '^docs/'` | **FAIL-OPEN** — non-docs path exists, `grep -qv` exits early, SIGPIPE → pipeline 141 → `!` → 0 → "docs-only" is TRUE, which unlocks check (a)'s non-closing traceability keyword for a **code** PR |
| ~line 390/391 | tier detection from labels | `printf … \| grep -qx/-qE` | fail-closed (micro) / fail-open (standard-complex → check d skipped) |
| ~line 400 | (b) scoping marker | `printf … \| grep -q` | false **BLOCK** (the #836 bug class) |
| ~line 410 | (c) review evidence | `printf … \| grep -qiE` | false **BLOCK** — #836 |
| ~line 424 | (c) `verdict=clean-micro` binding | `printf … \| grep -qE` | **FAIL-OPEN** — a matching marker reads as absent, so the #513 tier binding silently does not fire |
| ~line 439 | (d) `Wiring` in scoping comment | `printf … \| grep -qi` | false **BLOCK** |
| ~line 485 | (e) test evidence | `printf … \| grep -qiE` | false **BLOCK** — #836 |

Sites whose reader is `head -1` and whose pipeline is wrapped in `$( … || true)` (the
`parse_issue_ref` family, the plan-file and test-file `head -1` lookups) are **not** control-flow
hazards: the producer's `SIGPIPE` status is discarded by `|| true` and `head` has already printed
the line that command substitution captures. They are left as-is; the fix pass covers the
`grep -q` sites where the pipeline status **is** the verdict.

### Regression test (indicator 1–3 of #836)

Added to the script's `PIPELINE_COMPLIANCE_SELF_TEST=1` block (no `gh` calls):

1. **Functional, production path** — 25 repetitions of `has_review_evidence` /
   `has_test_evidence` on a **>64 KB** evidence string with the matching token on the **first
   line** (maximum race pressure: `grep` matches immediately while the writer is still writing).
   Every run must report present.
2. **Negative controls** — the same >64 KB filler with **no** token must report absent 25/25, so
   the positive assertion cannot pass vacuously.
3. **End-to-end through `run_checks`** — 25 repetitions of the real `run_checks` with a >64 KB
   `PR_BODY` and `COMMIT_MSGS` on a `complexity:standard` issue whose scoping comment carries the
   marker + `Wiring`; `FAILURES` must be 0 every time. Pre-fix this is RED at ~75–80 % per run.
4. **Static pin (indicator 2)** — the script source must contain **no live**
   `printf … | grep -q …` pipeline (comment lines excluded). If one is ever re-introduced, the
   self-test fails with the line number.
5. **Fixture size assertion** — the evidence fixture must exceed 65536 bytes, so the test cannot
   silently degrade to an input too small to race.

## 2. #792 — chosen option

**Option 1 — run the gate's issue-side checks in `01-preflight.md`, via a new
`--issue-only` mode on the script.** Option 2 (a bespoke 5-line assertion in the skill doc) was
rejected because it duplicates the gate's marker/tier/Wiring semantics in prose — two definitions
of "scoped" that drift, which is the failure mode this repo's guarded-path discipline exists to
prevent. Option 3 (documentation only) is enforcement-free and explicitly the weakest.

`--issue-only <N|owner/repo#N>` evaluates **exactly the checks that need no PR** and skips the
rest, reusing the same code and the same strings as the merge-time run:

| Check | Needs a PR? | Full PR run | `--issue-only` |
|---|---|---|---|
| (a) linked issue | yes (PR body) | enforced | skipped — the target issue is an *input*, not a parse |
| (b) scoping comment | no | enforced | **enforced** |
| (c) code-review evidence | yes (PR body/commits) | enforced | skipped |
| (d) plan doc | PARTLY — `docs/plans/*.md` needs the PR diff; the `Wiring` alternative does not | enforced | **enforced via the `Wiring` branch only**; absent wiring fails with the actionable message |
| (e) test-coverage evidence | yes (diff + body) | enforced | skipped |

Tier exemptions are identical (a `complexity:micro` issue passes with zero failures and b–e are
skipped; `d` still only applies to `complexity:standard`/`complex`). **The full-PR verdict logic
is untouched**: `ISSUE_ONLY=0` is the only path a PR takes, and the changed lines inside
`run_checks` are `if [[ "$ISSUE_ONLY" == "1" ]]` guards around, never within, the existing
verdict expressions.

Also added: `PIPELINE_COMPLIANCE_ISSUE_ONLY=1` as the env equivalent of the flag, `--issue-only`
in `usage()`, and an issue-only arm in the `DRY_RUN` plan output.

### Preflight wiring

`skills/commit-workflow/workflow/01-preflight.md`, immediately after **Tier Detection** (i.e.
after `ISSUE_NUMBER` is resolved and the tier is known, and before any implementation, commit,
review dispatch, or PR):

```bash
if [ "$ISSUE_NUMBER" != "none" ]; then
  bash scripts/check-pipeline-compliance.sh --issue-only "$ISSUE_NUMBER" || BLOCK
fi
```

A failure is **BLOCK** with the same remedy text the merge-time gate prints (post the scoping
comment; add the `Wiring` table / the plan doc), so the miss costs one script invocation instead
of a completed review loop plus an invalidated reviewed SHA.

## 3. Wiring

| Interface / artifact | Producer | Consumer | Verified by |
|---|---|---|---|
| `REVIEW_EVIDENCE_RE`, `TEST_EVIDENCE_RE`, `CLEAN_MICRO_MARKER_RE` constants | `scripts/check-pipeline-compliance.sh` (this PR) | `has_review_evidence` / `has_test_evidence` / the #513 binding inside `run_checks` checks (c) + (e) | SELF_TEST #836 block — production path, 25 reps, >64 KB positive + negative controls |
| `has_review_evidence()`, `has_test_evidence()` here-string matchers | same script (this PR) | check (c) and check (e) in `run_checks`; the SELF_TEST regression | SELF_TEST #836 block (functional) + SELF_TEST static pin |
| All `printf … \| grep -q` removals (8 sites) | same script (this PR) | every verdict in `run_checks` + `pr_is_docs_only` | `bash -n`, static pin assertion, SELF_TEST vector corpus, FAIL_ALL 5-pass simulation |
| `--issue-only <N\|owner/repo#N>` CLI mode | same script (this PR) | `skills/commit-workflow/workflow/01-preflight.md` Pipeline-Artifact Preflight step | SELF_TEST issue-only vectors (micro pass / standard-with-wiring pass / standard-without-wiring fail / unlabeled fail) |
| `PIPELINE_COMPLIANCE_ISSUE_ONLY=1` env seam | same script (this PR) | equivalent of the `--issue-only` flag; `DRY_RUN` plan arm | SELF_TEST env-seam assertion |
| Preflight BLOCK step (issue-side artifacts) | `01-preflight.md` (this PR) | every commit-workflow session, before implementation and review dispatch | manual run of `--issue-only 792` and `--issue-only 836` in the PR; documented exit-1 remedy |
| Merge-time verdict (checks a–e full-PR mode) | **unchanged** (this PR adds no verdict expression) | `.github/workflows/pipeline-compliance.yml` required check `pipeline-compliance` | FAIL_ALL 5-pass simulation output unchanged; SELF_TEST corpus unchanged |
| `docs/plans/2026-09-11-issue-836-792-pipeline-compliance-fix.md` | this PR | check (d) at merge time for issue #792 | `check-pipeline-compliance.sh` check (d) on this PR |

## 4. Tasks

1. Hoist the three evidence regexes into constants; add `has_review_evidence` /
   `has_test_evidence` / `has_clean_micro_marker` here-string matchers with the #836 rationale
   comment. — `scripts/check-pipeline-compliance.sh`
2. Replace all 8 `printf … | grep -q` sites (lines 278, 390, 391, 400, 410, 424, 439, 485) with
   here-strings; add the `ISSUE_ONLY` global. — same script
3. Add `--issue-only` parsing, mode-aware guards, issue-side fetch, the `DRY_RUN` issue-only arm,
   `usage()`, and the `ISSUE_ONLY` guards inside `run_checks` (a/c/e skipped, d via `Wiring`
   only). — same script
4. Add the SELF_TEST #836 regression block (functional 25-rep positive + negative controls, e2e
   `run_checks` 25-rep, static pin, fixture-size assertion) and the issue-only vectors. — same
   script
5. Wire the preflight BLOCK step into the issue-resolution/Tier-Detection area. —
   `skills/commit-workflow/workflow/01-preflight.md`
6. This plan doc + the scoping comments on #792 and #836.

## 5. Verification

- `bash -n scripts/check-pipeline-compliance.sh` → clean.
- `PIPELINE_COMPLIANCE_SELF_TEST=1 bash scripts/check-pipeline-compliance.sh` → all assertions
  pass, exit 0 (includes the #836 25-rep regression and the issue-only vectors).
- `PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 PR_NUMBER=1
  GH_REPO=daniel-ospina/agent-infra bash scripts/check-pipeline-compliance.sh` → the 5
  simulation passes unchanged (passes 4/4b/5 assert the #513 binding + micro exemption).
- `PIPELINE_COMPLIANCE_DRY_RUN=1 bash scripts/check-pipeline-compliance.sh --issue-only 792` →
  issue-only plan printed, exit 0.
- `bash scripts/check-pipeline-compliance.sh --issue-only 792` (live) → PASS for #792
  (scoping comment + Wiring); `--issue-only 836` → PASS for #836 (scoping comment).
- `bash scripts/check-pipeline-compliance.sh --issue-only 745`-class negative (a standard issue
  with no scoping marker) → exit 1 with the actionable remedy (checked against a fixture in the
  self-test, not against a live unscoped issue).
- Pre-fix RED evidence: the `/tmp/pipe-race-repro.sh` measurement above (20/25 false-negatives on
  the old idiom, 0/25 on the here-string).

## 6. Risks / non-goals

- **Non-goal:** no change to the gate's verdict expressions, to the required-check workflow, or to
  the #488 linked-issue invariant. `ISSUE_ONLY=0` is byte-identical in behaviour to the pre-PR
  script for checks a/c/e; the full-PR run and the FAIL_ALL simulation output are unchanged.
- **Non-goal:** #792's option 2/3 (duplicated assertion / docs-only) — rejected above.
- Risk: `--issue-only`'s plan-doc branch is unprovable pre-PR by construction, so preflight
  accepts the `Wiring` alternative only. This is stated in the mode's output, not silent; the
  docs/plans path is still enforced at merge time.
- Risk: the static no-`printf … | grep -q` pin could false-positive on a future intentional
  pipeline in a non-comment line; the failure message names the line number and the replacement
  idiom, so it is a one-line fix rather than a mystery block.
