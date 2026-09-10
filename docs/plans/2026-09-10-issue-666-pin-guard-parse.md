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
reviewable change — the extraction is mechanical (the three `test()` bodies move verbatim) and the
parser rewrite is then reviewable against a stable file.

**Open decision 3 (scope of what to parse):** only `ci.yml` + `node-ci.yml` are *asserted*. The reader is
generic, and its corpus test parses all twelve committed workflows (a subset-adequacy test, not eight
new guards).

### What changed

| File | Change |
|---|---|
| `scripts/workflow-yaml.mjs` | **NEW** — dep-free YAML-subset reader, fail-closed; supported subset + bounds documented in the header. Exports `parseWorkflowYaml(src)` and `WorkflowYamlError`. |
| `scripts/check-pi-pin-lockstep.mjs` | **NEW** — single-purpose suite holding guards `(h)` (extension pi-package pins), `(i)` (mirror version stamps) and `(j)` (per-PR wiring), plus the reader's subset tests. Same harness conventions as the source suite (`node:assert`, custom `test()`/`section()`, ✅/❌ markers, `process.exit(1)`). |
| `scripts/check-skill-lint.test.mjs` | `(h)`/`(i)`/`(j)` + their normalizer helpers removed (422 lines); header rewritten to state the reduced scope and where the pin guards live. 163 → **160/160**. |
| `.github/workflows/ci.yml` | `test-command` is now `node scripts/check-skill-lint.test.mjs && node scripts/check-pi-pin-lockstep.mjs` (no `${{ }}`, per the documented `test-command` constraint); comment updated. Nothing was added to `with:`, so its key set stays exactly `["test-command"]`. |
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
- an `if:` on the **callee** `unit-test` job is required (exact predicate); an `if:` on the **caller**
  `ci:` job is forbidden (any predicate can skip the reusable-workflow call).

### Split — wiring kept on both paths

`ci.yml` passes both suites in one `test-command` (the `&&` form the issue offers — it keeps the `with:`
key set at exactly one input, which `(j)` itself asserts). `ci-main.yml` gained the new suite in its
post-merge accumulator. `(j)`'s expectations were updated to the chained command, which is what makes
"the split cannot leave the pin guards unwired by accident" checkable rather than aspirational.

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
| `(h)` pins | unit + negative | `node scripts/check-pi-pin-lockstep.mjs`; mutation: drift one extension pin → RED | ✅ 49/49; RED (ported from #637, re-run) |
| `(i)` mirror stamps | unit + negative | same suite; mutation: stale a mirror stamp → RED | ✅ RED (ported from #637, re-run) |
| decoy dead step | unit | fixture test — the real step carries `\|\| true`, a dead step carries the clean `run:` text → RED | ✅ RED ("step-level `run:` set changed") |
| decoy inside a block scalar | unit | fixture test — a `test-command:` line in a job-level `NOTES: \|` body cannot satisfy the binding check → RED | ✅ RED ("`test-command` must be exactly") |
| decoy job inside a scalar | unit | fixture test — a fake `ci:` job inside `run-name: \|` cannot hide the real job's `if:` → RED | ✅ RED ("gained an `if:`") |
| decoy comment line | unit | fixture test — `# historical: run: …` carries no node → RED | ✅ RED |
| valid reformats | unit | flow `on: [pull_request]`, scalar `on:`, quoted keys, trailing/full-line comments, whole-file reindent, a `with:` reindented with its job subtree, parent-indent steps, block-scalar `run:`, block-scalar `test-command:`, unrelated `workflow_dispatch.inputs.paths`, `continue-on-error: false`, `run-name: \|` + `concurrency:` → all GREEN | ✅ 12/12 GREEN (the 12 `expectWired` cases in this row) |
| reader subset | unit | subset parses + fail-closed throws (tabs, anchors/aliases/tags, `- - x`, multi-line plain scalars, duplicate keys, multi-doc, bad block header) + full corpus parse | ✅ 9/9 |
| wiring | integration | `(j)` asserts the chained `test-command`; the live per-PR proof is the PR's `ci / unit-test` showing **run** (not skipping) | ⏳ PR-run proof (Verification step 6) |
| split | unit | `check-skill-lint.test.mjs` 160/160 (163 minus the 3 moved tests) **and** the new suite standalone 49/49 | ✅ both |
| workflow YAML validity | static | `bash scripts/check-workflow-actionlint.sh` + `bash tests/actionlint/run.sh` | ✅ exit 0 |

## Verification plan

1. `node scripts/check-skill-lint.test.mjs` → **160 passed, 0 failed** (was 163/163; the three moved
   tests account for the difference).
2. `node scripts/check-pi-pin-lockstep.mjs` → **49 passed, 0 failed**.
3. `node scripts/check-skill-lint.oracle.test.mjs` → **146 passed, 0 failed, fuzz 0/1000**.
4. `bash scripts/check-workflow-actionlint.sh` → exit 0 (workflows + templates, actionlint 1.7.12);
   `bash tests/actionlint/run.sh` → all cases pass.
5. `node scripts/ci-ref-check.test.mjs` → **183 passed, 0 failed**.
6. **Live-file negative-testing protocol** (backup with `cp` to `/tmp`, mutate, run, restore with `cp`
   — never a working-tree discard, #664; shasum verified identical after each restore):

   | Mutation of the live files | Verdict |
   |---|---|
   | `ci.yml` `test-command` loses the new suite | ❌ RED — ``ci.yml `test-command` must be exactly "node scripts/check-skill-lint.test.mjs && node scripts/check-pi-pin-lockstep.mjs" … found "node scripts/check-skill-lint.test.mjs"`` |
   | `node-ci.yml` step `run` gains `\|\| true` | ❌ RED |
   | `ci.yml` `pull_request` gains `paths-ignore` | ❌ RED |
   | `ci.yml` `ci:` job gains `if: github.event_name == 'push'` | ❌ RED |
   | `ci.yml` `ci:` job gains `"continue-on-error" : true` (quoted key, spaced colon) | ❌ RED |

   All five restored byte-identical (shasum-equal before/after), then the suite re-run green (49/49).
7. PR opened on the branch; the per-PR `ci / unit-test` run must show **run** (not skipping) with the
   chained command in the log — the only real proof the `test-command` binding resolves.

## Acceptance criteria

- [x] `(h)`, `(i)`, `(j)` live in `scripts/check-pi-pin-lockstep.mjs`, whose header states its scope.
- [x] `check-skill-lint.test.mjs` passes 160/160 and no longer carries the pin guards or their
      normalizer.
- [x] The new suite passes standalone (49/49) and is wired into **both** the per-PR path (`ci.yml`,
      chained with `&&`) and the post-merge path (`ci-main.yml`) — `(j)` asserts the former.
- [x] `(j)`'s assertions read parsed nodes: no assertion infers a verdict from a raw line, and no
      message claims more than its assertion delivers (§Accepted bounds).
- [x] A decoy dead step, a `test-command:` line inside another mapping's block scalar, a job-shaped
      block inside a YAML scalar, and a decoy comment line are each **RED** (automated fixture tests,
      plus the live-file mutation round above).
- [x] Flow `on: [pull_request]`, a reindented `with:` (the whole-file reindent **and** a `with:`
      reindented with only its job subtree), a parent-indent step sequence, a block-scalar `run:`, a
      block-scalar `test-command:` and quoted keys are all **GREEN**.
- [x] `node scripts/check-skill-lint.oracle.test.mjs` (146/146), `bash
      scripts/check-workflow-actionlint.sh` (exit 0) and `node scripts/ci-ref-check.test.mjs` (183/183)
      all pass.
- [ ] The PR's `ci / unit-test` shows as **run** with both suites chained (the @main binding proof —
      only observable after the PR opens).

## Review & negative-testing log

- **VGATE** — four `[VGATE]` verification passes ran against successive revisions: pass 1 `PASS`
  with two non-blocking label flags; passes 2 and 3 `FAIL` on a count/label claim in *this plan doc*
  (24 vs 25 RED tests; a `13/13` label over a 12-case list); pass 4 `PASS`. Every flag was corrected
  before the next pass, and each pass re-ran every command, attacked the reader with its own mutations
  (block-scalar decoys, duplicate keys, unsupported constructs) and reported per-file sha256s. The
  pre-commit `verification-gate` extension additionally required an in-band pass over the frozen
  revision before the commit was allowed.
- **code-review gate** — not run: the session's task instructions scope this work to "push the branch
  and open a PR … do NOT merge", and the PR body carries no `review recorded:` line. The gate is a
  merge-time gate, so nothing ships unreviewed by opening the PR.
- **negative testing** — 24 automated RED tests in the new suite (24 `expectRed` cases; the run
  composition is 1 (h) + 1 (i) + 1 live-wiring + 1 fixture baseline + 12 GREEN reformats + 24 RED
  bypasses + 9 reader = 49), plus the 5 live-file
  mutations in §Verification plan step 6 (all restored byte-identical via `cp`, #664).
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
