---
title: "#666 — parse the pin-gate wiring guard + split the pin guards into their own suite — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-666
---

<!-- research-path: inline — the parser decision research is §Decision record (every option's feasibility was probed locally, nothing assumed) -->

# #666 — parse the pin-gate wiring guard + split the pin guards into their own suite

## Confirmed Problem

Guard `(j)` (added by #637) answers "is the per-PR pin gate still wired?" from **normalized workflow
text**. Three generations of that approach were each defeated by YAML's own syntax, and each fix added
another hand-rolled normalizer to the guard:

| Generation | Defeated by (reproduced GREEN while the gate was unplugged) |
|---|---|
| presence checks | coverage collapse 6 pins → 1 (`matched > 0` stayed green) |
| text matching | `"paths-ignore":` quoted key, `continue-on-error : true`, `run: ${{ … }} \|\| true`, a decoy comment line carrying the expected `run:`, `pull_request.paths-ignore` |
| normalized structural matching (shipped) | a dead `- if: false` step carrying the expected `run:` text (fixed in-cycle), a `test-command:` line inside another mapping's block scalar, an injected fake `ci:` job inside a `run-name: \|` scalar, an unanchored `uses:` substring |

The residual work is the part a parsed structure fixes and text cannot:

1. every assertion becomes a node read, so a decoy line inside a scalar is **not a node** and cannot
   satisfy an assertion;
2. valid spellings stop being rejected (flow `on: [pull_request]`, parent-indent step sequences,
   block-scalar `run:`) — today they are fail-closed, i.e. a loud **spurious RED** on a healthy edit;
3. the guard stops needing a hand-maintained normalizer, which is itself unreviewed surface (the
   quote/block-scalar `stripComment` already had to be fixed once), and stops hand-maintaining two
   indents and three regex layers — the main reason the guard needed 10 review cycles.

Separately, `(h)`/`(i)`/`(j)` ride the #254 frontmatter-validator suite. That is why they could not be
left unwired by accident, but it also means a pin-drift failure and a frontmatter-validator regression
share one red signal, and `check-skill-lint.test.mjs`'s own header already named the split (plan
alternative F) as the durable fix.

## Plan

### Decision record — open decision 1 (which parser)

**Chosen: option (c′) — a small, dep-free, fail-closed YAML-SUBSET reader committed in-repo
(`scripts/workflow-yaml.mjs`).** Every option was probed, not assumed:

| Option | Probe result | Verdict |
|---|---|---|
| (a) `actions/setup-python` + PyYAML | PyYAML 6.0.3 **is** present on this dev box, but the per-PR leg is `node-ci.yml`'s `unit-test` job, which has no `setup-python`; ubuntu-latest's `python3` has no PyYAML — the repo's own `verify` job exists partly to `pip install … pyyaml`. Requires a network install + a non-node toolchain on a node-only path, and breaks local/CI parity unless the suite shells out to python. | rejected |
| (b) add `yaml` as a root devDependency + `npm ci` in `test-command` | `ls node_modules` → **ENOENT**; the root `package.json` declares **zero** dependencies and there **is no `package-lock.json`** — `npm ci` cannot run today at all. Adopting it adds a lockfile, a per-PR install, and reverses the "node-stdlib-only, no `npm ci`, ~4s" property #637 chose deliberately. | rejected |
| (c) vendor/author a workflow-subset parser | Feasible in-repo with no new dependency. The liability is real, so it is bounded by construction (below). | **chosen** |
| (d) keep text matching, delete every assertion only a parser can make sound | Deletes exactly the invariants #666's Indicators (1)–(2) ask to *close* (the `with:` key set, the step `run:` set, the job/step predicates) — the accepted-bound list would grow, not shrink. Assertions that only a general YAML parser could make sound were **not added** (the honest half of (d), respected here). | rejected |

`node -e "import('yaml')"` → `ERR_MODULE_NOT_FOUND`; `grep` for `"yaml"`/`"js-yaml"` across every
`package.json` in the repo → no hits. No framework parser is available.

**How the (c) liability is bounded (the "do not overclaim" contract):**

- the reader's **supported subset is stated in its header**, and it is *deliberately small* for a
  workflow reader (block mappings/sequences, compact mappings, flow collections, single-line scalars,
  block scalars, comments);
- anything outside the subset **throws** `WorkflowYamlError` with a line number and an actionable
  message ("extend that reader deliberately; do NOT fall back to text matching") — never a guess, so a
  mis-read workflow is impossible and the failure direction is a loud RED;
- the reader does **not** resolve scalar *types* (every scalar is a string), so `on` is always the key
  `on` (no YAML-1.1 `on`→boolean trap) and `continue-on-error: false` is the string `"false"`;
- the whole live workflow corpus (8 `.github/workflows/*.yml` + 4 `templates/.github/workflows/*.yml`)
  is asserted to parse, so the subset is proven adequate today and a future exotic construct becomes a
  deliberate update instead of a silent hole;
- the remaining bounds (block-scalar chomping/folding not modelled; multi-line plain scalars, anchors,
  aliases, tags, merge keys, `- - x`, multi-document streams throw; `no`/`off`/`0` are reported rather
  than treated as `false`) are listed in the reader header **and** the suite header, and repeated under
  §Accepted bounds — none is claimed closed.

**Open decision 2 (split first, or fold it in):** split first, in the same PR but as an independently
reviewable change. Guards `(h)` and `(i)` moved verbatim (their `test()` bodies are byte-identical to the
source suite's); guard `(j)` did **not** — its text-matching implementation was rewritten to node reads in
the same commit, so the wiring guard is reviewed as new code, not as a mechanical move (#675 P2-8).

**Open decision 3 (scope of what to parse):** only `ci.yml` + `node-ci.yml` are *asserted*. The reader is
generic, and its corpus test parses all twelve committed workflows (a subset-adequacy test, not eight
new guards).

### What changed

| File | Change |
|---|---|
| `scripts/workflow-yaml.mjs` | **NEW** — dep-free YAML-subset reader, fail-closed; supported subset + bounds documented in the header. Exports `parseWorkflowYaml(src)` and `WorkflowYamlError`. |
| `scripts/check-pi-pin-lockstep.mjs` | **NEW** — single-purpose suite holding guards `(h)` (extension pi-package pins), `(i)` (mirror version stamps), `(j)` (per-PR **and** post-merge wiring), plus the reader's subset tests. Same harness conventions as the source suite (`node:assert`, custom `test()`/`section()`, ✅/❌ markers, `process.exit(1)`). |
| `scripts/check-skill-lint.test.mjs` | `(h)`/`(i)`/`(j)` + their normalizer helpers removed (422 lines); header rewritten to state the reduced scope and where the pin guards live. 163 → **160/160**. |
| `.github/workflows/ci.yml` | `test-command` is now `a=0; node scripts/check-skill-lint.test.mjs \|\| a=$?; b=0; node scripts/check-pi-pin-lockstep.mjs \|\| b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]` (no `${{ }}`, per the documented `test-command` constraint); comment updated. Nothing was added to `with:`, so its key set stays exactly `["test-command"]`. |
| `.github/workflows/ci-main.yml` | the post-merge `extension-tests` accumulator runs the new suite too — the extraction must not silently drop the post-merge half of #637's contract. |
| `docs/plans/2026-09-10-issue-666-pin-guard-parse.md` | this plan. |

### Guard (j) — every assertion is now a node read

| Invariant | Node read (was: text match) |
|---|---|
| trigger is `pull_request`, unfiltered | `doc.on` — scalar / flow sequence / mapping; a mapping's `pull_request` child must carry none of `paths`, `paths-ignore`, `branches`, `branches-ignore`, `types` |
| caller self-calls `node-ci.yml@main` | `doc.jobs.ci.uses === "daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main"` (an unanchored `uses:` substring elsewhere can no longer satisfy it) |
| caller job cannot be disabled | `Object.hasOwn(doc.jobs.ci, "if")`, `…("needs")`, and a truthy `continue-on-error` |
| the binding exists, is non-empty, is exact | `doc.jobs.ci.with` key set is exactly `["test-command"]`, and its value equals the expected command string |
| the callee declares the input | `Object.hasOwn(doc.on.workflow_call.inputs, "test-command")` |
| the callee job cannot be disabled | `unit-test`'s `if` equals the known-good predicate exactly; no truthy `continue-on-error`; no `needs` |
| the step actually runs the suites | the step whose `if` is `inputs.test-command != ''` must have `run === "${{ inputs.test-command }}"`, **and** the set of every step's `run` must be exactly the two known values (a decoy dead step carrying the expected text is its own node, so it cannot satisfy this) |
| no step swallows a failure | no step's `continue-on-error` is truthy |

Two deliberate semantics decisions, stated rather than hidden:

- `continue-on-error` is reported only when it can be **truthy**; the literal `false` is a no-op and is
  accepted (it is a semantics-preserving edit, and flagging it with a "could fail silently" message
  would be an overclaim). `no`/`off`/`0` are reported — the reader does not resolve YAML scalar types.
  **Confirmed safe (#675 P3):** the reader cannot distinguish the boolean `false` from the quoted
  string `"false"`, but it does not need to — the canonical workflow schema types `continue-on-error`
  as a **boolean** at both levels (`actions/languageservices`
  `workflow-parser/src/workflow-v1.0.json`: `boolean-strategy-context` for `job`,
  `step-continue-on-error` for steps; the `actions/runner` `src/Sdk/DTPipelines/workflow-v1.0.json`
  copy is the same), and the runner-side converter asserts it
  (`PipelineTemplateConverter.ConvertToStepContinueOnError` → `AssertBoolean`). A quoted `"false"` is
  therefore a workflow-validation error, not a truthy coercion, so the job level is no weaker than the
  step level.
- an `if:` on the **callee** `unit-test` job is required (exact predicate); an `if:` on the **caller**
  `ci:` job is forbidden (any predicate can skip the reusable-workflow call).

### Split — wiring kept on both paths

`ci.yml` passes both suites in one `test-command` — a **failure accumulator**
(`a=0; node … || a=$?; b=0; node … || b=$?; [ $a -eq 0 ] && [ $b -eq 0 ]`), not `&&`. `&&` short-circuits,
so a #254 frontmatter-validator failure would skip the pin suite entirely and its verdict would never be
produced for that PR (#675 P2-2). The `||` form rather than `cmd; a=$?;` is required because the
runner's default Linux shell is `bash -e {0}`: under `set -e` a bare failing `node` aborts the script
before `a=$?` runs, which reintroduces exactly the short-circuit. One `with:` input is what keeps the key
set at exactly one, which `(j)` itself asserts. `ci-main.yml` runs the new suite in its post-merge
accumulator, and `(j)` asserts **both** wiring paths — the per-PR `test-command` string **and** a
post-merge `node scripts/check-pi-pin-lockstep.mjs || failures=$((failures+1))` line read from
`ci-main.yml`'s `extension-tests` job (#675 P1-5) — so "the split cannot leave the pin guards unwired by
accident" is checkable rather than aspirational. The suite header states plainly that both suites still
share one `ci / unit-test` signal (distinguishable in the log only; a separate check context is #673).

### Accepted bounds (unchanged or narrowed — none claimed closed)

- a **same-commit crafted edit** of both the guard and the workflow is out of scope for any test that
  reads repo files — branch protection is the control (#646). This is the bound #637 recorded; every
  *other* bypass it recorded is now covered by an automated fixture test.
- the `@main` seam: the guard reads the branch-local `node-ci.yml` while `ci.yml` executes `@main`; the
  live per-PR run is the only proof, and it expires at the next main-side `node-ci.yml` change.
- the split does **not** create a separate required check: both suites run inside one `test-command`
  (one `ci / unit-test` job), so pin-drift vs validator regression is distinguishable **in the log
  only** — the separability alternative F wanted at the check level still needs its own job. Filed
  separately (see §Out of Scope).

## Testing strategy

| Surface | Test layer | Verification | Result |
|---|---|---|---|
| `(h)` pins | unit + negative + **positive control** | `node scripts/check-pi-pin-lockstep.mjs`; mutation: drift one extension pin → RED; `pinFindings(entries, wrongPin)` → non-empty | ✅ 2 cases; RED (ported from #637, re-run); the positive control REDs a neutered comparison (#675 P1-3) |
| `(i)` mirror stamps | unit + negative + **positive control** | same suite; mutation: stale a mirror stamp → RED; `stampFindings([…], wrongPin)` → non-empty; a version literal outside stamp context is not a stamp | ✅ 2 cases; RED (ported from #637, re-run); positive control REDs a neutered comparison (#675 P1-3) |
| decoys / reader-bypass attempts | unit | a dead step carrying the clean `run:` text, a `test-command:` line in a block-scalar body, a job-shaped block inside a YAML scalar, a decoy comment line, an unanchored `uses:` substring → all RED | ✅ 5 cases RED |
| caller-job / binding bypasses | unit | `ci:` job gains `if:`/`needs:`/`continue-on-error :`; emptied / `\|\| true`-wrapped / shortened `test-command`; extra `with:` key → all RED | ✅ 7 cases RED |
| trigger bypasses | unit | trigger no longer `pull_request`; `pull_request:`-in-a-scalar; `pull_request:`-in-another-mapping; quoted / flow `paths-ignore`; `on: [push]` → all RED | ✅ 6 cases RED |
| callee job / step bypasses | unit | unsatisfiable `unit-test` predicate; rewired step predicate; `\|\| true` in the step `run:`; step / job `continue-on-error : true`; job `needs:`; renamed `test-command` input → all RED | ✅ 7 cases RED |
| escape-decoded guarded keys (#675 P1-1) | unit | `"paths\u002dignore"`, `"i\u0066"`, `"continu\u0075e-on-error"` decode to the real keys → guard (j) RED; an unmodelled escape THROWS | ✅ 3 cases RED + reader assertions |
| step execution shell / job defaults (#675 P1-2) | unit | `shell: 'true {0}'` on the custom-test step and `defaults.run.shell` on `unit-test` → RED; explicit `shell: bash` → GREEN | ✅ 2 RED + 1 GREEN |
| empty matrix (#675 P2-5) | unit | `strategy.matrix.os: []` and `strategy.matrix.include: []` → RED; a non-empty matrix → GREEN | ✅ 2 RED + 1 GREEN |
| post-merge wiring (#675 P1-5) | unit | `ci-main.yml`'s `extension-tests` `test-command` must invoke the suite with the failure accumulator; deleting the line, or dropping the accumulator → RED; an `echo` naming the suite is not an invocation; plus the live-file assertion | ✅ 2 RED + 1 baseline + 2 live assertions |
| valid reformats | unit | flow `on: [pull_request]`, scalar `on:`, empty `pull_request: {}`, quoted keys, trailing/full-line comments, whole-file reindent, a `with:` reindented with its job subtree, parent-indent steps, block-scalar `run:`, block-scalar `test-command:`, unrelated `workflow_dispatch.inputs.paths`, `continue-on-error: false`, `run-name: \|` + `concurrency:`, a non-empty `strategy.matrix`, an explicit `shell: bash` → all GREEN | ✅ 15/15 GREEN (the 15 `expectWired` cases) |
| reader subset & bounds | unit | subset parses + fail-closed throws (tabs, anchors/aliases/tags, `- - x`, multi-line plain scalars, duplicate keys, multi-doc, bad block header, unmodelled `\u` escape, a block scalar dedented below its first content line) + **escape decoding** + a 20 000-blank-line body parses in linear time (#675 P2-3) | ✅ 12/12 |
| reader corpus | unit | the live corpus parses, with **per-directory floors** (`.github/workflows` ≥ 8, `templates/.github/workflows` ≥ 4) rather than one loose total (#675 P2-6) | ✅ |
| wiring | integration | `(j)` asserts the accumulator `test-command` (per-PR) **and** the ci-main.yml post-merge invocation; the live proof is the PR's `ci / unit-test` showing **run** (not skipping) | ⏳ PR-run proof (Verification step 7) |
| split | unit | `check-skill-lint.test.mjs` 160/160 (163 minus the 3 moved tests) **and** the new suite standalone 71/71 | ✅ both |
| workflow YAML validity | static | `bash scripts/check-workflow-actionlint.sh` + `bash tests/actionlint/run.sh` | ✅ exit 0 |

**Case census (reconciled with the run output, #675 P1-6):** 71 tests = 23 plain `test()` (2 `(h)` + 2 `(i)`
+ 2 live wiring + 2 fixture baselines + 3 ci-main post-merge RED + 12 reader) + 15 `expectWired` + 33
`expectRed`. The 33 RED cases group as 5 decoys + 7 caller/binding + 6 trigger + 7 callee + 1
reader-subset + 3 escape + 2 shell/defaults + 2 matrix.

## Verification plan

1. `node scripts/check-skill-lint.test.mjs` → **160 passed, 0 failed** (was 163/163; the three moved
   tests account for the difference).
2. `node scripts/check-pi-pin-lockstep.mjs` → **71 passed, 0 failed**.
3. `node scripts/check-skill-lint.oracle.test.mjs` → **146 passed, 0 failed, fuzz 0/1000**.
4. `bash scripts/check-workflow-actionlint.sh` → exit 0 (workflows + templates, actionlint 1.7.12);
   `bash tests/actionlint/run.sh` → all cases pass.
5. `node scripts/ci-ref-check.test.mjs` → **183 passed, 0 failed**.
6. **Live-file negative-testing protocol** (backup with `cp` to `/tmp`, mutate, run, restore with `cp`
   — never a working-tree discard, #664; shasum verified identical after each restore):

   | Mutation of the live files | Verdict |
   |---|---|
   | `ci.yml` `test-command` loses the new suite | ❌ RED — ``ci.yml `test-command` must be exactly "a=0; node scripts/check-skill-lint.test.mjs …" … found "node scripts/check-skill-lint.test.mjs"`` |
   | `node-ci.yml` step `run` gains `\|\| true` | ❌ RED |
   | `ci.yml` `pull_request` gains `paths-ignore` | ❌ RED |
   | `ci.yml` `ci:` job gains `if: github.event_name == 'push'` | ❌ RED |
   | `ci.yml` `ci:` job gains `"continue-on-error" : true` (quoted key, spaced colon) | ❌ RED |
   | `ci-main.yml` loses the `node scripts/check-pi-pin-lockstep.mjs` accumulator line | ❌ RED (the post-merge assertion added by #675 P1-5) |

   All six restored byte-identical (shasum-equal before/after), then the suite re-run green (71/71).
7. PR opened on the branch; the per-PR `ci / unit-test` run must show **run** (not skipping) with the
   accumulator command in the log — the only real proof the `test-command` binding resolves.

### #675 fix-cycle verification (before → after, every run executed)

Each row was produced by running the pre-fix suite (HEAD scripts + HEAD workflows, in a throwaway
checkout at `/tmp/old666`) and the fixed suite against the same mutation, then restoring the live file
from a `cp` backup with a sha256 match check.

| # | Mutation / scenario | Before (HEAD) | After (this revision) |
|---|---|---|---|
| P1-1 | `ci.yml` `pull_request:` gains `"paths\u002dignore"` | ✅ 52/52 GREEN — gate unplugged | ❌ RED: “`pull_request:` gained `paths-ignore:`” |
| P1-2 | `node-ci.yml` custom step gains `shell: 'true {0}'` | ✅ 52/52 GREEN | ❌ RED: “sets `shell: "true {0}"` — a non-bash/sh shell can NO-OP the step” |
| P1-3 | `(h)` comparison rewritten to `if (false)` | ✅ GREEN (mutation survived) | ❌ RED (positive control) |
| P1-3 | `(i)` `offenders.push` deleted | ✅ GREEN (mutation survived) | ❌ RED (positive control) |
| P1-3 | `(h)`+`(i)` `test()` calls deleted | ✅ GREEN at 50/52 | ❌ RED (floor: 69 < 71) |
| P1-4 | `Requires Node 22.11.0 or newer.` appended to `docs/providers.md` | ❌ RED (false positive) | ✅ 71/71 GREEN |
| P1-5 | `ci-main.yml` loses the post-merge invocation | ✅ 52/52 GREEN | ❌ RED: “must invoke … exactly once … found 0 such line(s)” |
| P2-3 | ~120 KB block-scalar body (interior blank-line run) | 212 376 ms | 528 ms (linear) |

Reader-level before/after for P1-1: HEAD's `parseWorkflowYaml('on: { pull_request: { "paths\u002dignore": … } }')`
returns the key `pathsu002dignore`; the fixed reader returns `paths-ignore`.

## Acceptance criteria

- [x] `(h)`, `(i)`, `(j)` live in `scripts/check-pi-pin-lockstep.mjs`, whose header states its scope.
- [x] `check-skill-lint.test.mjs` passes 160/160 and no longer carries the pin guards or their
      normalizer.
- [x] The new suite passes standalone (71/71) and is wired into **both** the per-PR path (`ci.yml`,
      the failure accumulator) and the post-merge path (`ci-main.yml`, the accumulator line) — `(j)`
      asserts **both** (`ci.yml`'s `test-command` and `ci-main.yml`'s invocation).
- [x] `(j)`'s assertions read parsed nodes: no assertion infers a verdict from a raw line, and no
      message claims more than its assertion delivers (§Accepted bounds).
- [x] A decoy dead step, a `test-command:` line inside another mapping's block scalar, a job-shaped
      block inside a YAML scalar, and a decoy comment line are each **RED** (automated fixture tests,
      plus the live-file mutation round above).
- [x] Flow `on: [pull_request]`, a reindented `with:` (the whole-file reindent **and** a `with:`
      reindented with only its job subtree), a parent-indent step sequence, a block-scalar `run:`, a
      block-scalar `test-command:`, quoted keys, a non-empty `strategy.matrix` and an explicit
      `shell: bash` are all **GREEN**.
- [x] `node scripts/check-skill-lint.oracle.test.mjs` (146/146), `bash
      scripts/check-workflow-actionlint.sh` (exit 0) and `node scripts/ci-ref-check.test.mjs` (183/183)
      all pass.
- [ ] The PR's `ci / unit-test` shows as **run** with both suites chained (the @main binding proof —
      only observable after the PR opens).

## Review & negative-testing log

- **VGATE** — `[VGATE]` verification passes ran against successive revisions of this branch. Each pass
  re-ran every command, attacked the reader with its own mutations (block-scalar decoys, duplicate
  keys, unsupported constructs) and reported per-file sha256s. The pre-commit `verification-gate`
  extension additionally required an in-band pass over the frozen revision before the commit was
  allowed. (The earlier revision-history detail — "24 vs 25 RED tests", "a `13/13` label over a
  12-case list" — is not repeated here: the #675 review found the counts stale and they were corrected
  against a fresh run, so recording earlier corrections that nothing in the shipped file reflects
  would be an unsupported claim.)
- **code-review gate** — not run: the session's task instructions scope this work to "push the branch
  and open a PR … do NOT merge", and the PR body carries no `review recorded:` line. The gate is a
  merge-time gate, so nothing ships unreviewed by opening the PR.
- **negative testing** — 33 automated RED cases in the new suite (the 33 `expectRed` calls), plus 3
  post-merge RED cases and 6 live-file mutations in §Verification plan step 6 (all restored
  byte-identical via `cp`, #664). The run composition is reconciled in §Testing strategy (71 = 23 +
  15 + 33).
- **#675 review fixes (this revision)** — the escape-decoding bypass (P1-1), the `shell`/`defaults`
  bypass (P1-2), the missing positive controls for `(h)`/`(i)` (P1-3), the whole-file stamp sweep
  (P1-4), the unasserted post-merge wiring (P1-5), the stale counts in this doc (P1-6), the stale
  "section j" references (P2-1), the `&&` short-circuit (P2-2), the quadratic block-scalar trim
  (P2-3), the min-indent block scalar (P2-4), the empty matrix (P2-5), the corpus floor (P2-6), the
  `mutate`-less fixture (P2-7) and the two overclaims above (P2-8).
- **out-of-scope finding filed, not absorbed** — the split is check-opaque (both suites share one
  `test-command`), so pin drift is distinguishable in the log only; filed as **#673** rather than
  widening #666.

## Out of Scope

| Item | Owner / disposition |
|---|---|
| Making code CI blocking (a red `ci / unit-test` does not block a merge) | **#646** (unchanged; this PR does not touch branch protection) |
| A separate CI check context for pin drift (the split is log-distinguishable only while both suites share one `test-command`) | **#673** (filed from this session) |
| The `@main`-at-PR-time input-resolution seam | accepted, time-limited bound (#637 plan) |
| A nested/root `package.json` walk for extension pins | **#643** |
| Version-specific line refs in the mirror surfaces | **#651** |
| General YAML features outside the reader subset (folding/chomping semantics, multi-line plain scalars, anchors/aliases/tags, merge keys, multi-doc) | documented reader bound; the reader throws rather than guesses, so adding one is a deliberate edit |
